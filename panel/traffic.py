"""Upload / download totals for calendar days and calendar months, kept for years.

Prometheus keeps the raw counters only for its retention (30 days by default): too short for "last
month" late in a month, and for a monthly history. So every finished day (in the viewer's time zone)
is computed once from Prometheus and saved in DATA/traffic.json; a month is the sum of its saved days
plus today's running total. A background loop saves new days even when nobody opens the panel, and
missing days are filled in from Prometheus while it still has them.
"""
import calendar
import json
import os
import threading
import time
from pathlib import Path

from monitor import VIRTUAL_NICS, node_instances, node_selector, num, prom_get

DATA = Path(os.environ.get("DATA_DIR", "/data"))
FILE = DATA / "traffic.json"
KEEP_DAYS = 800          # a little over two years of days
BACKFILL_DAYS = 35       # how far back to look for days that are not saved yet
SETTLE = 120             # a day is final this long after midnight (the last scrape has landed)
TZ_FORGET = 45 * 86400   # stop keeping days for a time zone nobody has viewed in this long

_lock = threading.Lock()
_cache = {}
_earliest = {}


def _load():
    try:
        d = json.loads(FILE.read_text(encoding="utf-8"))
        if isinstance(d, dict) and isinstance(d.get("series"), dict):
            d.setdefault("tzs", {})
            return d
    except (OSError, ValueError):
        pass
    return {"version": 1, "series": {}, "tzs": {}}


_ledger = _load()


def _save():
    tmp = FILE.with_suffix(".tmp")
    try:
        FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_text(json.dumps(_ledger, separators=(",", ":")), encoding="utf-8")
        os.replace(tmp, FILE)
    except OSError as e:
        print(f"WARNING: cannot save {FILE}: {e}", flush=True)


# ------------------------------------------------------------------ calendar helpers (fixed UTC offset)

def _parts(ts, tz):
    t = time.gmtime(ts - tz * 60)
    return t.tm_year, t.tm_mon, t.tm_mday


def _midnight(y, m, d, tz):
    return calendar.timegm((y, m, d, 0, 0, 0)) + tz * 60


def _day_key(start, tz):
    y, m, d = _parts(start, tz)
    return f"{y:04d}-{m:02d}-{d:02d}"


def _prev_month(y, m):
    return (y - 1, 12) if m == 1 else (y, m - 1)


# ------------------------------------------------------------------ prometheus

def _metrics(instance):
    n = node_selector(instance, net=True)
    return f"node_network_receive_bytes_total{{{n},{VIRTUAL_NICS}}}", f"node_network_transmit_bytes_total{{{n},{VIRTUAL_NICS}}}"


def _instant(expr, at=None):
    params = {"query": expr}
    if at is not None:
        params["time"] = at
    rows = prom_get("/api/v1/query", params)["result"]
    return num(rows[0]["value"][1]) if rows else None


def _total(rxm, txm, secs, at=None):
    secs = max(60, int(secs))
    return {"rx": _instant(f"sum(increase({rxm}[{secs}s]))", at), "tx": _instant(f"sum(increase({txm}[{secs}s]))", at)}


def _earliest_sample(instance, rxm):
    """Time of the oldest network sample Prometheus still has (cached; it only moves slowly)."""
    hit = _earliest.get(instance)
    now = time.time()
    if hit and now - hit[0] < 1800:
        return hit[1]
    v = _instant(f"min(min_over_time(timestamp({rxm})[{BACKFILL_DAYS + 1}d:10m]))")
    _earliest[instance] = (now, v)
    return v


def _daily(expr, first_end, last_end):
    data = prom_get("/api/v1/query_range", {"query": expr, "start": first_end, "end": last_end, "step": 86400})
    return {int(float(t)): num(v) for t, v in data["result"][0]["values"]} if data["result"] else {}


# ------------------------------------------------------------------ the ledger

def _resolve(instance):
    if instance:
        node_selector(instance)          # validates the name
        return instance
    found = node_instances()
    return found[0] if found else ""


def _fill(instance, tz, now=None):
    """Save every finished day of the last BACKFILL_DAYS that is not saved yet. Returns the series."""
    now = int(now or time.time())
    key = f"{instance}|{tz}"
    with _lock:
        series = _ledger["series"].setdefault(key, {})
        today = _midnight(*_parts(now, tz), tz)
        if now - today < SETTLE:          # yesterday's last samples may still be on their way
            today -= 86400
        want = [today - k * 86400 for k in range(1, BACKFILL_DAYS + 1)]
        missing = [s for s in want if _day_key(s, tz) not in series]
        if not missing:
            return series
        rxm, txm = _metrics(instance)
        earliest = _earliest_sample(instance, rxm)
        if earliest is None:
            return series
        missing = [s for s in missing if s + 86400 > earliest]   # days Prometheus has nothing for stay unknown
        if not missing:
            return series
        first, last = min(missing) + 86400, max(missing) + 86400
        rx = _daily(f"sum(increase({rxm}[86400s]))", first, last)
        tx = _daily(f"sum(increase({txm}[86400s]))", first, last)
        changed = False
        for s in missing:
            e = s + 86400
            if e in rx or e in tx:
                series[_day_key(s, tz)] = [round(rx.get(e) or 0), round(tx.get(e) or 0), 1 if earliest <= s + 900 else 0]
                changed = True
        if changed:
            cutoff = _day_key(now - KEEP_DAYS * 86400, tz)
            for k in [k for k in series if k < cutoff]:
                del series[k]
            _save()
        return series


def _month(series, y, m, upto_day=None):
    """Sum of the saved days of a month (up to, not including, upto_day)."""
    days = calendar.monthrange(y, m)[1]
    last = (upto_day - 1) if upto_day else days
    prefix = f"{y:04d}-{m:02d}-"
    rx = tx = n = full = 0
    daily = []
    for d in range(1, last + 1):
        v = series.get(f"{prefix}{d:02d}")
        if v:
            rx += v[0]; tx += v[1]; n += 1; full += v[2]
            daily.append({"day": d, "rx": v[0], "tx": v[1], "partial": not v[2]})
        else:
            daily.append({"day": d, "rx": None, "tx": None, "partial": True})
    return {"key": f"{y:04d}-{m:02d}", "days": days, "rx": rx if n else None, "tx": tx if n else None,
            "complete": full == last, "daily": daily}


def api_traffic(q):
    instance = _resolve(q.get("instance") or "")
    try:
        tz = max(-840, min(840, int(q.get("tz", "0"))))   # minutes, as Date.getTimezoneOffset() reports them
    except ValueError:
        tz = 0
    now = int(time.time())
    ck = (instance, tz)
    hit = _cache.get(ck)
    if hit and now - hit[0] < 60:
        return hit[1]
    with _lock:
        seen = _ledger["tzs"].get(str(tz))
        _ledger["tzs"][str(tz)] = now
        if seen is None or now - seen > 86400:   # remember the time zone for the background loop
            _save()
    series = _fill(instance, tz, now)
    rxm, txm = _metrics(instance)

    y, m, d = _parts(now, tz)
    today_start = _midnight(y, m, d, tz)
    month_start = _midnight(y, m, 1, tz)
    today = {"start": today_start, "end": now, **_total(rxm, txm, now - today_start)}
    earliest = _earliest_sample(instance, rxm)

    cur = _month(series, y, m, upto_day=d)
    cur["rx"] = (cur["rx"] or 0) + (today["rx"] or 0) if cur["rx"] is not None or today["rx"] is not None else None
    cur["tx"] = (cur["tx"] or 0) + (today["tx"] or 0) if cur["tx"] is not None or today["tx"] is not None else None
    cur["complete"] = cur["complete"] and earliest is not None and earliest <= today_start + 900
    cur["daily"].append({"day": d, "rx": today["rx"], "tx": today["tx"], "partial": False, "today": True})
    cur["start"], cur["elapsed"] = month_start, now - month_start
    cur["seconds"] = cur["days"] * 86400
    py, pm = _prev_month(y, m)
    prev = _month(series, py, pm)
    prev["start"] = _midnight(py, pm, 1, tz)

    # month-by-month history from the saved days (this month and the 11 before it)
    months, yy, mm = [], y, m
    for _ in range(12):
        row = cur if (yy, mm) == (y, m) else prev if (yy, mm) == (py, pm) else _month(series, yy, mm)
        if row["rx"] is not None or row["tx"] is not None:
            months.append({"key": row["key"], "rx": row["rx"], "tx": row["tx"], "complete": row["complete"]})
        yy, mm = _prev_month(yy, mm)

    week = [today]
    for k in range(1, 7):
        s = today_start - k * 86400
        v = series.get(_day_key(s, tz))
        week.append({"start": s, "end": s + 86400, "rx": v[0] if v else None, "tx": v[1] if v else None})

    out = {
        "today": today,
        "days": week,                                   # today first, then the 6 days before it
        "week": _total(rxm, txm, 7 * 86400),
        "month": cur,
        "prev": prev,
        "months": months,
        "boot": {"rx": _instant(f"sum({rxm})"), "tx": _instant(f"sum({txm})")},
        "peak": {"rx": _instant(f"max_over_time(sum(rate({rxm}[2m]))[24h:1m])"),
                 "tx": _instant(f"max_over_time(sum(rate({txm}[2m]))[24h:1m])")},
        # how much raw history Prometheus has, so the UI can say "based on 3 days of data"
        "history": (now - earliest) if earliest else None,
    }
    _cache[ck] = (now, out)
    if len(_cache) > 50:
        _cache.clear()
    return out


def loop():
    """Save each finished day shortly after midnight, also when nobody has the panel open."""
    time.sleep(60)
    while True:
        try:
            now = time.time()
            with _lock:
                tzs = [int(t) for t, seen in _ledger["tzs"].items() if now - seen < TZ_FORGET]
            if tzs:
                for inst in node_instances():
                    for tz in tzs:
                        _fill(inst, tz)
        except Exception as e:  # Prometheus restarting, etc.: try again next round
            print(f"traffic: {type(e).__name__}: {e}", flush=True)
        time.sleep(1800)
