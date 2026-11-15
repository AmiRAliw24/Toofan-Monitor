"""Live, one-second resolution numbers for the overview and network pages.

Prometheus scrapes every 15 s and the dashboard queries average over 2 minutes, so they lag behind
what the server is doing right now. For the live view the panel reads node_exporter itself once a
second and turns the counters into rates. One sampler thread runs per watched server, only while a
browser is watching it, and keeps the last few minutes so a page that opens has a chart at once.

Only servers Prometheus already knows (job="node") can be watched, so this cannot be used to make
the panel fetch arbitrary addresses.
"""
import collections
import os
import re
import threading
import time
from urllib.error import HTTPError
from urllib.request import urlopen

import monitor

INTERVAL = 1.0                     # seconds between samples
KEEP = 300                         # samples kept for a page that opens (5 minutes)
IDLE_STOP = 30                     # stop sampling a server nobody watched for this long
LOCAL_INSTANCE = os.environ.get("LOCAL_NODE_INSTANCE", "node-exporter:9100")
# This server's real NIC counters come from the node-net container (see docker-compose.yml).
LOCAL_NET_URL = os.environ.get("LOCAL_NODE_NET_URL", "http://node-net:9100/metrics")

VIRTUAL_NIC = re.compile(r"^(lo|veth.*|docker.*|br-.*|virbr.*|cni.*|cali.*|flannel.*|ifb.*)$")
VIRTUAL_DISK = re.compile(r"^(dm-|md|loop|ram|zram|sr|fd|nbd)")   # avoid counting the same bytes twice
REAL_FS = re.compile(r"^(?!(tmpfs|overlay|squashfs|devtmpfs|ramfs|fuse.*|nsfs|proc|sysfs|cgroup.*)$)")
WANTED = (
    "node_cpu_seconds_total", "node_memory_MemTotal_bytes", "node_memory_MemAvailable_bytes",
    "node_memory_SwapTotal_bytes", "node_memory_SwapFree_bytes", "node_load1", "node_load5", "node_load15",
    "node_network_receive_bytes_total", "node_network_transmit_bytes_total",
    "node_filesystem_size_bytes", "node_filesystem_avail_bytes",
    "node_disk_read_bytes_total", "node_disk_written_bytes_total",
)
# Only the collectors the live view needs: a full scrape is ~50 KB and runs every collector (tens of
# ms of CPU in node_exporter); this one is a few KB and ~3 ms. Disk sizes change slowly: every 10 s.
FAST = ("cpu", "meminfo", "loadavg", "diskstats")
DISK_EVERY = 10
LINE = re.compile(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})?\s+(\S+)")
LABEL = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"')


def parse(text):
    """Prometheus text format -> {metric: [(labels, value), ...]} for the metrics in WANTED only."""
    out = collections.defaultdict(list)
    for line in text.splitlines():
        if not line.startswith(WANTED):
            continue
        m = LINE.match(line)
        if not m or m.group(1) not in WANTED:
            continue
        try:
            value = float(m.group(3))
        except ValueError:
            continue
        out[m.group(1)].append((dict(LABEL.findall(m.group(2) or "")), value))
    return out


def fetch(url):
    with urlopen(url, timeout=2.5) as resp:
        return resp.read(8_000_000).decode("utf-8", "replace")


def first(metrics, name):
    rows = metrics.get(name)
    return rows[0][1] if rows else None


def counters(metrics):
    """The raw values a sample is computed from (counters need the previous reading)."""
    cpu_total = cpu_idle = 0.0
    for labels, v in metrics.get("node_cpu_seconds_total", []):
        cpu_total += v
        if labels.get("mode") == "idle":
            cpu_idle += v
    dev = {}
    for key, name in (("rx", "node_network_receive_bytes_total"), ("tx", "node_network_transmit_bytes_total")):
        for labels, v in metrics.get(name, []):
            d = labels.get("device", "")
            if d and not VIRTUAL_NIC.match(d):
                dev.setdefault(d, {})[key] = v
    io = {"r": 0.0, "w": 0.0}
    for key, name in (("r", "node_disk_read_bytes_total"), ("w", "node_disk_written_bytes_total")):
        for labels, v in metrics.get(name, []):
            if not VIRTUAL_DISK.match(labels.get("device", "")):
                io[key] += v
    return {"cpu": (cpu_total, cpu_idle) if cpu_total else None, "dev": dev, "io": io}


def root_disk(metrics):
    size = {l.get("mountpoint"): v for l, v in metrics.get("node_filesystem_size_bytes", [])
            if REAL_FS.match(l.get("fstype", "")) and v}
    avail = {l.get("mountpoint"): v for l, v in metrics.get("node_filesystem_avail_bytes", [])}
    mount = "/" if "/" in size else next(iter(sorted(size)), None)
    if mount is None or mount not in avail:
        return None
    return {"mount": mount, "total": size[mount], "used": size[mount] - avail[mount]}


def rate(now, before, dt):
    if now is None or before is None or dt <= 0 or now < before:   # counter reset (reboot, exporter restart)
        return None
    return (now - before) / dt


class Sampler:
    def __init__(self, instance):
        self.instance = instance
        local = instance == LOCAL_INSTANCE
        # (base url, collectors it should run); on this server network counters come from node-net
        self.sources = [(f"http://{instance}/metrics", FAST if local else FAST + ("netdev",))]
        if local:
            self.sources.append((LOCAL_NET_URL, ("netdev",)))
        self.unfiltered = set()      # exporters too old for collect[] (or with a collector switched off)
        self.tick = 0
        self.disk = None
        self.samples = collections.deque(maxlen=KEEP)
        self.error = ""
        self.cond = threading.Condition()
        self.watched = time.time()
        self.prev = None
        threading.Thread(target=self._loop, name=f"live-{instance}", daemon=True).start()

    def _read(self):
        metrics = collections.defaultdict(list)
        with_disk = self.tick % DISK_EVERY == 0 or self.disk is None
        self.tick += 1
        for base, wanted in self.sources:
            if base in self.unfiltered:
                text = fetch(base)
            else:
                names = wanted + (("filesystem",) if with_disk and base != LOCAL_NET_URL else ())
                try:
                    text = fetch(base + "?" + "&".join(f"collect[]={c}" for c in names))
                except HTTPError as e:
                    if e.code != 400:
                        raise
                    self.unfiltered.add(base)      # "missing collector": ask for everything from now on
                    text = fetch(base)
            for k, v in parse(text).items():
                metrics[k].extend(v)
        return metrics

    def _sample(self, ts, metrics):
        c = counters(metrics)
        prev, self.prev = self.prev, (ts, c)
        if prev is None:
            return None
        dt = ts - prev[0]
        p = prev[1]
        cpu = None
        if c["cpu"] and p["cpu"]:
            d_total, d_idle = c["cpu"][0] - p["cpu"][0], c["cpu"][1] - p["cpu"][1]
            if d_total > 0:
                cpu = max(0.0, min(100.0, 100 * (1 - d_idle / d_total)))
        dev = {}
        for d, v in c["dev"].items():
            old = p["dev"].get(d, {})
            dev[d] = [rate(v.get("rx"), old.get("rx"), dt), rate(v.get("tx"), old.get("tx"), dt)]
        mem_total = first(metrics, "node_memory_MemTotal_bytes")
        mem_avail = first(metrics, "node_memory_MemAvailable_bytes")
        swap_total = first(metrics, "node_memory_SwapTotal_bytes")
        swap_free = first(metrics, "node_memory_SwapFree_bytes")

        def total(k):
            known = [x[k] for x in dev.values() if x[k] is not None]
            return sum(known) if known else None

        return {
            "t": round(ts, 3),
            "cpu": cpu,
            "mem": [mem_total - mem_avail, mem_total] if mem_total is not None and mem_avail is not None else None,
            "swap": [swap_total - swap_free, swap_total] if swap_total is not None and swap_free is not None else None,
            "load": [first(metrics, f"node_load{p}") for p in (1, 5, 15)],
            "rx": total(0), "tx": total(1), "dev": dev,
            "io": [rate(c["io"]["r"], p["io"]["r"], dt), rate(c["io"]["w"], p["io"]["w"], dt)],
            "disk": self._disk(metrics),
        }

    def _disk(self, metrics):
        if metrics.get("node_filesystem_size_bytes"):
            self.disk = root_disk(metrics)
        return self.disk

    def _loop(self):
        next_at = time.monotonic()
        while True:
            with _lock:   # decided under the lock, so a page that starts watching right now gets a new sampler
                if time.time() - self.watched >= IDLE_STOP:
                    if _samplers.get(self.instance) is self:
                        del _samplers[self.instance]
                    return
            try:
                ts = time.time()
                sample = self._sample(ts, self._read())
                self.error = ""
            except Exception as e:  # exporter unreachable, timeout, ...
                sample, self.prev = None, None
                self.error = f"{type(e).__name__}: {e}"
            with self.cond:
                if sample:
                    self.samples.append(sample)
                self.cond.notify_all()
            next_at += INTERVAL if not self.error else 3 * INTERVAL
            time.sleep(max(0.05, next_at - time.monotonic()))
            next_at = max(next_at, time.monotonic() - INTERVAL)   # never try to "catch up" after a stall

    def since(self, ts):
        with self.cond:
            return [s for s in self.samples if s["t"] > ts]

    def wait(self, timeout):
        with self.cond:
            self.cond.wait(timeout)


_samplers = {}
_lock = threading.Lock()
_known = {"at": 0.0, "list": []}


def resolve(instance):
    """The server to watch: one Prometheus already scrapes (cached for 30 s)."""
    if time.time() - _known["at"] > 30 or instance not in _known["list"]:
        _known["list"] = monitor.node_instances()
        _known["at"] = time.time()
    if not instance:
        instance = LOCAL_INSTANCE if LOCAL_INSTANCE in _known["list"] else (_known["list"] or [""])[0]
    if instance not in _known["list"]:
        raise ValueError("unknown server")
    return instance


def sampler(instance):
    with _lock:
        s = _samplers.get(instance)
        if s is None:
            s = _samplers[instance] = Sampler(instance)
        s.watched = time.time()
        return s
