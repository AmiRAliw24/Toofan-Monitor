"""Exact upload / download accounting per network card, kept across reboots (like vnStat).

Source: the kernel's byte counters of each network card (node_network_*_bytes_total, read every 30 s
from the host by node-net). Every new reading adds exactly what the counter moved since the previous
one, so nothing is estimated or extrapolated. A reboot (seen as a new boot time) or a counter that went
back starts counting again from zero: the totals keep growing, they are never reset. Only the traffic
between the last reading before a reboot and the reboot itself (at most one scrape interval) cannot be
known. Readings are summed into 15-minute buckets, so days and months follow the viewer's own time zone
(including zones like +03:30), and kept in DATA/traffic.json: 70 days in buckets, then per day for years.

Only physical cards are counted by default: tunnels (WireGuard, GRE, ...) and VLANs carry traffic that
also passes through the physical card, and adding them would count it twice. The choice can be changed
per server in the panel.
"""
import bisect
import calendar
import json
import os
import re
import threading
import time
from pathlib import Path

from monitor import VIRTUAL_NICS, node_instances, node_selector, num, prom_get

DATA = Path(os.environ.get("DATA_DIR", "/data"))
FILE = DATA / "traffic.json"
BUCKET = 900                  # seconds per bucket
KEEP_BUCKETS = 70 * 86400     # buckets this recent stay; older ones become days
KEEP_DAYS = 3660              # about ten years of days
CHUNK = 6 * 3600              # readings fetched per query while catching up
BACKFILL = 35 * 86400         # how far back a new server is read from Prometheus' history
FRESH = 45                    # the page triggers a catch-up when the last one is older than this
REBOOT_SLACK = 60             # boot time changes smaller than this are clock noise, not a reboot
LAG = 120                     # how much later node-exporter's boot time may be scraped than a card's counter
SETTLE_BOOT = 600             # after a counter reset, the boot time is taken as settled after this long
# names of interfaces that never are the physical card, when the kernel's own type is not known
NOT_PHYSICAL = re.compile(r"^(wg|tun|tap|gre|gretap|erspan|ip6gre|ip6tnl|ip_vti|ip6_vti|vti|sit|ipip|tunl|ppp|tailscale|zt|nebula|vxlan|geneve|kube|flannel|cali|cni|lxc|vnet|virbr|docker|br-|veth|ifb|dummy|bond.*\.|.*\.\d+$)")

_lock = threading.RLock()
_state_lock = threading.Lock()
_meta = {}                    # instance -> (time, {device: info})
_saved_at = 0.0
_syncing = set()


def _load():
    try:
        d = json.loads(FILE.read_text(encoding="utf-8"))
        if isinstance(d, dict) and d.get("version") == 4 and isinstance(d.get("servers"), dict):
            return d
    except (OSError, ValueError):
        pass
    # earlier versions kept estimated day totals that included tunnels: start over from the raw readings
    return {"version": 4, "tz": 0, "servers": {}}


_ledger = _load()


def _save(force=False):
    global _saved_at
    now = time.time()
    if not force and now - _saved_at < 60:
        return
    tmp = FILE.with_suffix(".tmp")
    try:
        FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_text(json.dumps(_ledger, separators=(",", ":")), encoding="utf-8")
        os.replace(tmp, FILE)
        _saved_at = now
    except OSError as e:
        print(f"WARNING: cannot save {FILE}: {e}", flush=True)


# ------------------------------------------------------------------ prometheus

def _selectors(instance):
    n = node_selector(instance, net=True)
    return (f"node_network_receive_bytes_total{{{n},{VIRTUAL_NICS}}}",
            f"node_network_transmit_bytes_total{{{n},{VIRTUAL_NICS}}}",
            f"node_boot_time_seconds{{{node_selector(instance)}}}")


def _matrix(expr, span, at):
    """Raw readings of `expr` in (at - span, at]: {(job, device): [(t, v), ...]}."""
    data = prom_get("/api/v1/query", {"query": f"{expr}[{int(span)}s]", "time": at})
    out = {}
    for r in data["result"]:
        key = (r["metric"].get("job", ""), r["metric"].get("device", ""))
        out[key] = [(float(t), float(v)) for t, v in r["values"]]
    return out


def _instant(expr, at=None):
    params = {"query": expr}
    if at is not None:
        params["time"] = at
    rows = prom_get("/api/v1/query", params)["result"]
    return num(rows[0]["value"][1]) if rows else None


def _devices_info(instance):
    """{device: {"physical": bool}} from the kernel's interface type (cached for 10 minutes)."""
    hit = _meta.get(instance)
    now = time.time()
    if hit and now - hit[0] < 600:
        return hit[1]
    n = f"{node_selector(instance, net=True)},{VIRTUAL_NICS}"
    info = {}

    def by_dev(expr):
        return {r["metric"].get("device", ""): num(r["value"][1]) for r in prom_get("/api/v1/query", {"query": expr})["result"]}
    kind, ifid, link = by_dev(f"node_network_protocol_type{{{n}}}"), by_dev(f"node_network_iface_id{{{n}}}"), by_dev(f"node_network_iface_link{{{n}}}")
    for d in set(by_dev(f"node_network_receive_bytes_total{{{n}}}")) | set(kind):
        if d in kind and d in ifid and d in link:
            # Ethernet (type 1) that is its own link: a real card. VLANs, macvlans and the kernel's
            # tunnel placeholders point at another interface; WireGuard, GRE, ... are not type 1.
            phys = kind[d] == 1 and ifid[d] == link[d] and bool(ifid[d]) and not NOT_PHYSICAL.match(d)
        else:
            phys = not NOT_PHYSICAL.match(d)
        info[d] = {"physical": phys}
    _meta[instance] = (now, info)
    return info


# ------------------------------------------------------------------ counting

def _resolve(instance):
    if instance:
        node_selector(instance)          # validates the name
        return instance
    found = node_instances()
    return found[0] if found else ""


def _add(srv, device, k, amount, t0, t1):
    """Add `amount` bytes, moved between t0 and t1, to the buckets of that period (k: 0 rx, 1 tx)."""
    if amount <= 0:
        return
    b = srv["b"].setdefault(device, {})
    t0 = min(t0, t1)
    first, last = int(t0 // BUCKET), int((t1 - 1e-6) // BUCKET) if t1 > t0 else int(t1 // BUCKET)
    if first >= last:
        b.setdefault(str(last), [0, 0])[k] += int(amount)
        return
    # spread over the buckets it spans, in proportion to the time in each (long gaps without readings)
    span, left = t1 - t0, int(amount)
    for i in range(first, last + 1):
        lo, hi = max(t0, i * BUCKET), min(t1, (i + 1) * BUCKET)
        part = left if i == last else int(amount * (hi - lo) / span)
        left -= part
        if part:
            b.setdefault(str(i), [0, 0])[k] += part


def _boot_at(boots, t):
    """Boot time in force at time t, from sorted [(t, boot)]."""
    i = bisect.bisect_right(boots, (t, float("inf"))) - 1
    return boots[i][1] if i >= 0 else None


def _advance(instance, until):
    """Count the next CHUNK of readings after the server's cursor (up to `until`).
    Returns True when there may be more to do."""
    rxm, txm, bootm = _selectors(instance)
    servers = _ledger["servers"]
    srv = servers.get(instance)
    if srv is None:
        earliest = _instant(f"min(min_over_time(timestamp({rxm})[{BACKFILL // 86400}d:5m]))")
        if earliest is None:
            return False
        start = max(earliest - 300, until - BACKFILL)
        srv = servers[instance] = {"start": start, "cursor": start, "job": None, "last": {}, "boot": None, "b": {}, "d": {}, "count": None}
    if srv["cursor"] >= until - 1:
        return False
    end = min(until, srv["cursor"] + CHUNK)
    span = end - srv["cursor"]
    series = {0: _matrix(rxm, span, end), 1: _matrix(txm, span, end)}
    boots = [p for pts in _matrix(bootm, span + 600, end).values() for p in pts]
    if srv["boot"]:
        boots.append(tuple(srv["boot"]))
    boots.sort()
    # One reader per server. node-net reads the host's own cards; the plain node job may also report
    # interfaces, but on the local server those were its container's own (another, smaller counter
    # under the same name). Once a server has node-net, only node-net counts, for good.
    if any(job == "node-net" for rows in series.values() for job, _d in rows):
        srv["job"] = "node-net"
    use = srv.get("job") or "node"
    for k, rows in series.items():
        for (job, dev), pts in rows.items():
            if job != use:
                continue
            key = f"{job}|{dev}|{k}"
            prev = srv["last"].get(key)      # [time, counter, boot time it belongs to (None: settling), reset at]
            for t, v in pts:
                if t <= srv["cursor"]:
                    continue
                # node-exporter's boot time may be scraped a little after this reading: look slightly ahead
                boot = _boot_at(boots, t + LAG)
                if prev is None:
                    # a card seen for the first time: its counter only belongs to us when it started
                    # (boot) after counting began; otherwise it is the starting point
                    if boot and boot >= srv["start"]:
                        _add(srv, dev, k, v, boot, t)
                    prev = [t, v, boot, 0]
                    continue
                pt, pv, pb, reset_at = prev
                if v < pv:
                    # the counter went back: a reboot or a re-created card. All of it is new traffic,
                    # moved since the boot if that is known and later, else since the last reading.
                    _add(srv, dev, k, v, boot if boot and pt < boot < t else pt, t)
                    prev = [t, v, None, t]       # the boot time belonging to the new counter settles first
                    continue
                if pb is None:
                    pb = boot if t - reset_at > SETTLE_BOOT else None
                    _add(srv, dev, k, v - pv, pt, t)
                elif boot and boot - pb > REBOOT_SLACK:
                    # rebooted and the counter already passed its old value (long downtime): all new
                    _add(srv, dev, k, v, max(pt, boot), t)
                    pb = boot
                else:
                    _add(srv, dev, k, v - pv, pt, t)
                prev = [t, v, pb, reset_at]
            if prev is not None:
                srv["last"][key] = prev
    if boots:
        srv["boot"] = list(boots[-1])
    srv["cursor"] = end
    _roll_up(srv)
    return srv["cursor"] < until - 1


def _roll_up(srv):
    """Buckets older than KEEP_BUCKETS become day totals (in the time zone last used to view them)."""
    tz = _ledger.get("tz") or 0
    cut = int((time.time() - KEEP_BUCKETS) // BUCKET)
    oldest_day = _day_key(time.time() - KEEP_DAYS * 86400, tz)
    for dev, b in srv["b"].items():
        old = [i for i in b if int(i) < cut]
        if not old:
            continue
        days = srv["d"].setdefault(dev, {})
        for i in old:
            v = b.pop(i)
            row = days.setdefault(_day_key(int(i) * BUCKET, tz), [0, 0])
            row[0] += v[0]; row[1] += v[1]
        for k in [k for k in days if k < oldest_day]:
            del days[k]


def sync(instance, until=None):
    """Bring a server's counts up to date (also catches up after downtime). The lock is taken per
    chunk, so the page stays responsive while weeks of history are read for a new server."""
    until = int(until or time.time())
    more = True
    while more:
        with _lock:
            more = _advance(instance, until)
            _save(force=not more)


# ------------------------------------------------------------------ calendar helpers (fixed UTC offset)

def _parts(ts, tz):
    t = time.gmtime(ts - tz * 60)
    return t.tm_year, t.tm_mon, t.tm_mday


def _midnight(y, m, d, tz):
    return calendar.timegm((y, m, d, 0, 0, 0)) + tz * 60


def _day_key(ts, tz):
    y, m, d = _parts(ts, tz)
    return f"{y:04d}-{m:02d}-{d:02d}"


def _prev_month(y, m):
    return (y - 1, 12) if m == 1 else (y, m - 1)


# ------------------------------------------------------------------ reading

def _counted(srv, info):
    chosen = srv.get("count")
    if chosen:
        return [d for d in chosen if d in info or d in srv["b"] or d in srv["d"]]
    return sorted(d for d, i in info.items() if i["physical"])


def _totals(srv, devices, tz):
    """{day key: [rx, tx]} and {(day key, hour): [rx, tx]} for the chosen cards, in time zone tz."""
    days, hours = {}, {}
    for dev in devices:
        for i, (rx, tx) in srv["b"].get(dev, {}).items():
            ts = int(i) * BUCKET
            key = _day_key(ts, tz)
            row = days.setdefault(key, [0, 0]); row[0] += rx; row[1] += tx
            hk = int((ts - tz * 60) // 3600)
            row = hours.setdefault(hk, [0, 0]); row[0] += rx; row[1] += tx
        for key, (rx, tx) in srv["d"].get(dev, {}).items():
            row = days.setdefault(key, [0, 0]); row[0] += rx; row[1] += tx
    return days, hours


def _sum(rows):
    rx = tx = 0
    seen = False
    for r in rows:
        if r:
            rx += r[0]; tx += r[1]; seen = True
    return {"rx": rx, "tx": tx} if seen else {"rx": None, "tx": None}


def api_traffic(q):
    instance = _resolve(q.get("instance") or "")
    try:
        tz = max(-840, min(840, int(q.get("tz", "0"))))   # minutes, as Date.getTimezoneOffset() reports them
    except ValueError:
        tz = 0
    now = int(time.time())
    with _state_lock:
        if _ledger.get("tz") != tz:
            _ledger["tz"] = tz
    srv = _ledger["servers"].get(instance)
    if srv is not None and now - 2 * CHUNK < srv["cursor"] < now - FRESH:
        sync(instance, now)                         # the last minute or so: quick
    elif (srv is None or srv["cursor"] <= now - 2 * CHUNK) and instance not in _syncing:
        _catch_up_later(instance)                   # a new server, or days of catching up: in the background
    srv = _ledger["servers"].get(instance)
    if srv is None:
        return {"preparing": True}

    info = _devices_info(instance)
    devices = _counted(srv, info)
    with _lock:
        days, hours = _totals(srv, devices, tz)
        per_dev_month = {}
        y, m, d = _parts(now, tz)
        py, pm = _prev_month(y, m)
        for dev in sorted(set(info) | set(srv["b"]) | set(srv["d"])):
            dd, _h = _totals(srv, [dev], tz)
            cur = _sum(v for k, v in dd.items() if k.startswith(f"{y:04d}-{m:02d}-"))
            prv = _sum(v for k, v in dd.items() if k.startswith(f"{py:04d}-{pm:02d}-"))
            per_dev_month[dev] = {"month": cur, "prev": prv}
        start, cursor = srv["start"], srv["cursor"]

    today_start = _midnight(y, m, d, tz)
    month_start = _midnight(y, m, 1, tz)

    def month(yy, mm, upto=None):
        n = calendar.monthrange(yy, mm)[1]
        last = upto or n
        daily = []
        for dd in range(1, last + 1):
            v = days.get(f"{yy:04d}-{mm:02d}-{dd:02d}")
            ds = _midnight(yy, mm, dd, tz)
            known = ds + 86400 > start
            daily.append({"day": dd, "rx": v[0] if v else (0 if known else None), "tx": v[1] if v else (0 if known else None),
                          "partial": ds < start < ds + 86400 or not known})
        tot = _sum([r["rx"], r["tx"]] if r["rx"] is not None else None for r in daily)
        ms = _midnight(yy, mm, 1, tz)
        return {"key": f"{yy:04d}-{mm:02d}", "days": n, **tot, "daily": daily, "start": ms,
                "complete": start <= ms + 300}

    cur = month(y, m, d)
    cur["daily"][-1]["today"] = True
    cur["elapsed"], cur["seconds"] = now - month_start, cur["days"] * 86400
    prev = month(py, pm)

    months, yy, mm = [], y, m
    for _ in range(24):
        row = cur if (yy, mm) == (y, m) else prev if (yy, mm) == (py, pm) else month(yy, mm)
        if row["rx"] is not None:
            months.append({"key": row["key"], "rx": row["rx"], "tx": row["tx"], "complete": row["complete"]})
        yy, mm = _prev_month(yy, mm)

    today = {"start": today_start, "end": now, **_sum([days.get(_day_key(today_start, tz))])}
    if today["rx"] is None and today_start + 86400 > start:
        today.update(rx=0, tx=0)
    yest = _sum([days.get(_day_key(today_start - 86400, tz))])
    first_hour = int((now - tz * 60) // 3600) - 23
    hourly = [{"start": (h * 3600) + tz * 60, "rx": (hours.get(h) or [0, 0])[0], "tx": (hours.get(h) or [0, 0])[1]}
              for h in range(first_hour, first_hour + 24)]
    week = _sum(v for k, v in days.items() if k >= _day_key(today_start - 6 * 86400, tz))
    alltime = _sum(days.values())

    # since boot: the counters themselves (they start at zero when the server boots)
    boot = {"rx": 0, "tx": 0}
    for key, last in srv["last"].items():
        job, dev, k = key.split("|")
        v = last[1]
        if dev in devices and job == (srv.get("job") or "node"):
            boot["rx" if k == "0" else "tx"] += v
    alt = "|".join(re.escape(x).replace("\\", "\\\\") for x in devices) or "none"    # a PromQL string: backslashes doubled
    n = f'{node_selector(instance, net=True)},device=~"{alt}"'
    peak = {"rx": _instant(f"max_over_time(sum(rate(node_network_receive_bytes_total{{{n}}}[2m]))[24h:1m])"),
            "tx": _instant(f"max_over_time(sum(rate(node_network_transmit_bytes_total{{{n}}}[2m]))[24h:1m])")}
    boot_time = _instant(f"node_boot_time_seconds{{{node_selector(instance)}}}")

    return {
        "today": today, "yesterday": yest, "week": week, "month": cur, "prev": prev, "months": months,
        "alltime": {**alltime, "since": start}, "boot": {**boot, "since": boot_time},
        "hourly": hourly, "peak": peak,
        "devices": [{"name": dv, "physical": info.get(dv, {}).get("physical", False), "counted": dv in devices,
                     **per_dev_month.get(dv, {})} for dv in sorted(set(info) | set(per_dev_month))],
        "auto": not srv.get("count"),
        "updated": cursor, "syncing": cursor < now - 2 * CHUNK,
        "history": now - start,
    }


def post_devices(b, _h=None):
    """Choose which cards are counted: {"instance": ..., "devices": [...]} or "devices": null for automatic."""
    instance = _resolve(str(b.get("instance") or ""))
    devices = b.get("devices")
    if devices is not None:
        if not isinstance(devices, list) or len(devices) > 64 or not all(isinstance(d, str) and re.match(r"^[\w.@:-]{1,32}$", d) for d in devices):
            raise ValueError("invalid interface list")
        devices = sorted(set(devices)) or None
    with _lock:
        srv = _ledger["servers"].get(instance)
        if srv is None:
            raise ValueError("no traffic data for this server yet")
        srv["count"] = devices
        _save(force=True)
    return {"ok": True}


def _catch_up_later(instance):
    def run():
        try:
            sync(instance)
        except Exception as e:
            print(f"traffic: {type(e).__name__}: {e}", flush=True)
        finally:
            _syncing.discard(instance)
    _syncing.add(instance)
    threading.Thread(target=run, daemon=True).start()


def loop():
    """Count new readings every few minutes, also when nobody has the panel open."""
    time.sleep(20)
    while True:
        try:
            for inst in node_instances():
                sync(inst)
            with _lock:
                _save(force=True)
        except Exception as e:  # Prometheus restarting, etc.: try again next round
            print(f"traffic: {type(e).__name__}: {e}", flush=True)
        time.sleep(300)
