"""Exact counts per remote address over time: how many connections each address opened (its requests),
how many of them never completed, and how much traffic they carried.

The connections view (conns.py) reads the kernel's connection table, which only holds what is open at
that moment: a client that opens and closes 500 short connections a minute shows as two or three. This
module listens to the kernel's connection events instead (`conntrack -E`): every NEW event is one
connection opened, every DESTROY event closes one and, when per-connection accounting is on, carries its
final byte counters. So the counts are exact, not sampled.

They are kept in 5-minute buckets for the last hour and hourly buckets for the last day, per direction
and remote address, and saved every few minutes so a restart keeps them. A bucket holds at most CAP
addresses per direction: past that (a flood from spoofed addresses) the rest is added up under OTHER, so
memory stays bounded however many addresses there are.
"""
import collections
import json
import os
import subprocess
import threading
import time

FINE, FINE_KEEP = 300, 14          # 5-minute buckets, a little over an hour
COARSE, COARSE_KEEP = 3600, 26     # hourly buckets, a little over a day
CAP = 1000                         # addresses per direction and bucket
MAX_PORTS = 8                      # ports remembered per address and bucket (the rest under "")
OTHER = "*"
SAVE_EVERY = 300
CMD = ["conntrack", "-E", "-e", "NEW,DESTROY", "-o", "extended", "-b", str(16 << 20)]

_lock = threading.Lock()
_fine = collections.deque()        # [start, {"in": {ip: entry}, "out": {ip: entry}}]
_coarse = collections.deque()
# entry: [opened, bytes_in, bytes_out, failed, {"443/tcp": opened, ...}]
#   bytes_in is what the remote address sent, bytes_out what it received;
#   failed: incoming TCP connections closed before their handshake completed (scans, SYN floods)
_state = {"since": None, "running": False, "error": "", "lost": 0, "events": 0, "saved": 0.0}
_data = "/data"
_proc = None                       # the running `conntrack -E`
_local = lambda: frozenset()       # noqa: E731  (the server's own addresses, set by configure)


def configure(data, local_addresses, start=True):
    global _data, _local
    _data, _local = data, local_addresses
    _load()
    if start:
        threading.Thread(target=_run, daemon=True).start()


def _flag():
    return os.path.join(_data, "conn_activity_off")


def on():
    return not os.path.exists(_flag())


def set_on(enabled):
    if enabled and os.path.exists(_flag()):
        os.unlink(_flag())
    elif not enabled:
        open(_flag(), "w").close()
        if _proc:
            try:
                _proc.kill()
            except OSError:
                pass
        with _lock:
            _fine.clear()
            _coarse.clear()
            _state["since"] = None
        try:
            os.unlink(_path())
        except OSError:
            pass


def status():
    return {"on": on(), "running": _state["running"], "since": _state["since"], "error": _state["error"],
            "lost": _state["lost"]}


# ------------------------------------------------------------------ events

def parse(line, local):
    """One event line -> (dir, remote, port label, opened, bytes_in, bytes_out, failed), or None
    (the server talking to itself, traffic between two of its own addresses, other events)."""
    p = line.split()
    if len(p) < 6 or p[0] not in ("[NEW]", "[DESTROY]"):
        return None
    new = p[0] == "[NEW]"
    proto = p[3] if p[1] in ("ipv4", "ipv6") else p[1]
    o, r = {}, {}
    cur, byt = o, [0, 0]
    assured = False
    for tok in p[2:]:
        if tok == "[ASSURED]":
            assured = True
            continue
        k, eq, v = tok.partition("=")
        if not eq:
            continue
        if k == "src" and "src" in o:
            cur = r
        if k == "bytes":
            try:
                byt[0 if cur is o else 1] = int(v)
            except ValueError:
                pass
        elif k not in cur:
            cur[k] = v
    osrc, odst = o.get("src"), o.get("dst")
    if not osrc or not odst:
        return None
    if odst in local:
        if osrc in local:
            return None
        d, remote, bin_, bout = "in", osrc, byt[0], byt[1]
    elif osrc in local or r.get("dst", osrc) in local:      # this server, or a container masqueraded by it
        d, remote, bin_, bout = "out", odst, byt[1], byt[0]
    else:
        return None
    port = o.get("dport", "")
    label = f"{port}/{proto}" if port else proto
    failed = 1 if (not new and d == "in" and proto == "tcp" and not assured) else 0
    return d, remote, label, (1 if new else 0), bin_, bout, failed


def _bucket(dq, size, keep, now):
    start = int(now // size * size)
    if dq and dq[-1][0] >= start:
        return dq[-1][1]                  # the current one (or the clock went back: keep adding to the last)
    dq.append([start, {"in": {}, "out": {}}])
    while len(dq) > keep:
        dq.popleft()
    return dq[-1][1]


def record(ev, now=None):
    """Add one parsed event to the buckets (the caller holds no lock)."""
    d, remote, label, opened, bi, bo, failed = ev
    now = now or time.time()
    with _lock:
        for dq, size, keep in ((_fine, FINE, FINE_KEEP), (_coarse, COARSE, COARSE_KEEP)):
            b = _bucket(dq, size, keep, now)[d]
            e = b.get(remote)
            if e is None:
                key = remote if len(b) < CAP else OTHER
                e = b.get(key)
                if e is None:
                    e = b[key] = [0, 0, 0, 0, {}]
            e[0] += opened; e[1] += bi; e[2] += bo; e[3] += failed
            if opened:
                pts = e[4]
                k = label if (label in pts or len(pts) < MAX_PORTS) else ""
                pts[k] = pts.get(k, 0) + 1
        _state["events"] += 1


def _stderr(proc):
    for line in proc.stderr:
        line = line.strip()
        if "ENOBUFS" in line or "No buffer space" in line:
            _state["lost"] += 1           # the kernel dropped events faster than they were read
        elif line and "flow events have been shown" not in line:
            _state["error"] = line[:200]


def _run():
    global _proc
    while True:
        if not on():
            time.sleep(20)
            continue
        try:
            proc = subprocess.Popen(CMD, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        except OSError as e:
            _state["error"] = f"conntrack: {e}"
            time.sleep(120)
            continue
        _proc = proc
        threading.Thread(target=_stderr, args=(proc,), daemon=True).start()
        _state.update(running=True, error="")
        if not _state["since"]:
            _state["since"] = int(time.time())
        local, local_at = _local(), time.time()
        try:
            for line in proc.stdout:
                if "src=127.0.0.1 dst=127.0.0.1 " in line or "src=::1 dst=::1 " in line:
                    continue
                now = time.time()
                if now - local_at > 60:
                    local, local_at = _local(), now
                    if not on():
                        break
                ev = parse(line, local)
                if ev:
                    record(ev, now)
                if now - _state["saved"] > SAVE_EVERY:
                    save()
        except Exception as e:  # noqa: BLE001  (restarted below)
            _state["error"] = f"{type(e).__name__}: {e}"[:200]
        finally:
            try:
                proc.kill()
                proc.wait(5)
            except Exception:  # noqa: BLE001
                pass
            _state["running"] = False
        save()
        time.sleep(10)


# ------------------------------------------------------------------ saving

def _path():
    return os.path.join(_data, "conn_activity.json")


def save():
    _state["saved"] = time.time()
    if not on():
        return
    with _lock:
        text = json.dumps({"since": _state["since"], "fine": list(_fine), "coarse": list(_coarse)}, separators=(",", ":"))
    tmp = _path() + ".tmp"
    try:
        with open(tmp, "w") as f:
            f.write(text)
        os.replace(tmp, _path())
    except OSError:
        pass


def _load():
    try:
        with open(_path()) as f:
            saved = json.load(f)
    except (OSError, ValueError):
        return
    now = time.time()
    with _lock:
        for key, dq, size, keep in (("fine", _fine, FINE, FINE_KEEP), ("coarse", _coarse, COARSE, COARSE_KEEP)):
            dq.clear()
            for b in saved.get(key) or []:
                if isinstance(b, list) and len(b) == 2 and isinstance(b[1], dict) and b[0] > now - size * keep:
                    dq.append([int(b[0]), {d: {ip: e for ip, e in (b[1].get(d) or {}).items() if isinstance(e, list) and len(e) == 5}
                                           for d in ("in", "out")}])
            while len(dq) > keep:
                dq.popleft()
        _state["since"] = saved.get("since") if (_fine or _coarse) else None


# ------------------------------------------------------------------ reading

def buckets(seconds, d="in"):
    """[(start, length, {ip: entry})] covering about the last `seconds` (a copy; d: "in", "out" or "all").
    The window starts at a bucket boundary: an hour is 60 to 65 minutes, a day 24 to 25 hours."""
    dq, size = (_fine, FINE) if seconds <= 3600 else (_coarse, COARSE)
    now = time.time()
    cut = now - seconds
    dirs = ("in", "out") if d == "all" else (d,)
    out = []
    with _lock:
        for start, b in dq:
            if start + size <= cut or start > now:
                continue
            merged = {}
            for dr in dirs:
                for ip, e in b.get(dr, {}).items():
                    m = merged.get(ip)
                    if m is None:
                        merged[ip] = [e[0], e[1], e[2], e[3], dict(e[4])]
                    else:
                        m[0] += e[0]; m[1] += e[1]; m[2] += e[2]; m[3] += e[3]
                        for k, n in e[4].items():
                            m[4][k] = m[4].get(k, 0) + n
            # the seconds this bucket really counted: not before counting started, not past now
            begin = max(start, _state["since"] or start)
            out.append((start, max(1, min(start + size, now) - begin), merged))
    return out


def total(bks):
    """The buckets added up: {ip: entry}."""
    out = {}
    for _s, _l, b in bks:
        for ip, e in b.items():
            m = out.get(ip)
            if m is None:
                out[ip] = [e[0], e[1], e[2], e[3], dict(e[4])]
            else:
                m[0] += e[0]; m[1] += e[1]; m[2] += e[2]; m[3] += e[3]
                for k, n in e[4].items():
                    m[4][k] = m[4].get(k, 0) + n
    return out


def ip_detail(ip):
    """One address over the last day: per hour, and its totals for the last hour and day (both directions)."""
    hours = [[s, e[0], e[1] + e[2], e[3]] for s, _l, b in buckets(86400, "all") for e in [b.get(ip, [0, 0, 0, 0, {}])]]
    h1 = total([(s, l, {ip: b[ip]}) for s, l, b in buckets(3600, "all") if ip in b]).get(ip)
    h24 = total([(s, l, {ip: b[ip]}) for s, l, b in buckets(86400, "all") if ip in b]).get(ip)
    pack = lambda e: {"req": e[0], "bytes_in": e[1], "bytes_out": e[2], "failed": e[3],   # noqa: E731
                      "ports": sorted(([k, n] for k, n in e[4].items() if k), key=lambda x: -x[1])[:8]} if e else None
    return {"since": _state["since"], "hours": hours, "h1": pack(h1), "h24": pack(h24)}
