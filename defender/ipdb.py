"""Country and network (ASN / provider) of any IP address, offline.

Two free databases, downloaded only once the connections view is used, refreshed monthly:
  * DB-IP "IP to Country Lite" (CC BY 4.0, https://db-ip.com): the country of every IPv4 range;
  * iptoasn.com (public domain): the AS number, its name and its registered country, IPv4 and IPv6
    (the country for IPv6 addresses comes from here).
Every source has mirrors (jsDelivr, GitHub, ...); the first that works is used. They are turned once into
compact binary tables in DATA/ipdb (sorted range starts for a binary search), which load in a few
milliseconds and take about 15 MB of memory; they are dropped from memory again after 20 idle minutes.
"""
import array
import bisect
import gzip
import json
import os
import socket
import threading
import time

import sources

COUNTRY4 = [f"https://{h}/npm/@ip-location-db/dbip-country/dbip-country-ipv4.csv"
            for h in ("cdn.jsdelivr.net", "fastly.jsdelivr.net", "gcore.jsdelivr.net", "testingcf.jsdelivr.net")] + \
    ["https://raw.githubusercontent.com/sapics/ip-location-db/main/dbip-country/dbip-country-ipv4.csv"]
ASN = ["https://iptoasn.com/data/ip2asn-combined.tsv.gz"]
# fallback for the AS data when iptoasn.com cannot be reached: the same kind of data as two CSV files
ASN_CSV = {v: [f"https://{h}/npm/@ip-location-db/asn/asn-ipv{v}.csv"
               for h in ("cdn.jsdelivr.net", "fastly.jsdelivr.net", "gcore.jsdelivr.net", "testingcf.jsdelivr.net")] for v in (4, 6)}
MAX_AGE = 30 * 86400
IDLE_UNLOAD = 20 * 60

_lock = threading.Lock()
_db = None            # the loaded tables
_used = 0.0           # last lookup
_job = {"state": "idle", "error": "", "at": 0}


def _dir(data):
    d = os.path.join(data, "ipdb")
    os.makedirs(d, exist_ok=True)
    return d


def meta(data):
    try:
        with open(os.path.join(_dir(data), "meta.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def status(data):
    m = meta(data)
    return {"ready": bool(m.get("built")), "updated": m.get("built"), "state": _job["state"], "error": _job["error"],
            "rows": m.get("rows", {}), "sources": m.get("sources", {})}


# ------------------------------------------------------------------ building

def _v4(s):
    return int.from_bytes(socket.inet_aton(s), "big")


def _v6(s):
    return socket.inet_pton(socket.AF_INET6, s)


def _build(data):
    d = _dir(data)
    tmp = os.path.join(d, "dl")
    os.makedirs(tmp, exist_ok=True)
    used = {}

    # countries (IPv4)
    path = os.path.join(tmp, "country4.csv")
    used["country"] = sources.fetch_file(COUNTRY4, path, check=lambda p: os.path.getsize(p) > 1_000_000 and open(p).readline().count(",") == 2)
    ccs, cidx = [], {}
    c_start, c_end, c_cc = array.array("L"), array.array("L"), array.array("H")
    with open(path) as f:
        for line in f:
            a, b, cc = line.rstrip("\n").split(",")
            if ":" in a or not cc:
                continue
            if cc not in cidx:
                cidx[cc] = len(ccs)
                ccs.append(cc)
            c_start.append(_v4(a)); c_end.append(_v4(b)); c_cc.append(cidx[cc])
    os.unlink(path)

    # networks (AS number, name, country), IPv4 and IPv6
    names, nidx = [], {}
    a4_start, a4_end, a4_asn, a4_name = array.array("L"), array.array("L"), array.array("L"), array.array("L")
    a6_start, a6_end = bytearray(), bytearray()
    a6_asn, a6_name, a6_cc = array.array("L"), array.array("L"), array.array("H")

    def add(start, end, asn, cc, name):
        if not asn or asn == "0":
            return
        key = f"{asn}\t{cc}\t{name}"
        if key not in nidx:
            nidx[key] = len(names)
            names.append(key)
        if ":" in start:
            a6_start.extend(_v6(start)); a6_end.extend(_v6(end))
            a6_asn.append(int(asn)); a6_name.append(nidx[key])
            if cc not in cidx:
                cidx[cc] = len(ccs)
                ccs.append(cc)
            a6_cc.append(cidx[cc])
        else:
            a4_start.append(_v4(start)); a4_end.append(_v4(end)); a4_asn.append(int(asn)); a4_name.append(nidx[key])

    gz = os.path.join(tmp, "asn.tsv.gz")
    try:
        used["asn"] = sources.fetch_file(ASN, gz, check=lambda p: os.path.getsize(p) > 1_000_000 and open(p, "rb").read(2) == b"\x1f\x8b")
        with gzip.open(gz, "rt", encoding="utf-8", errors="replace") as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) == 5:
                    add(p[0], p[1], p[2], "" if p[3] == "None" else p[3], p[4])
        os.unlink(gz)
    except ValueError as first:
        # the CSV variant: start,end,asn,"name" (no country: the IPv4 country table covers IPv4)
        import csv
        for v in (4, 6):
            path = os.path.join(tmp, f"asn{v}.csv")
            try:
                used[f"asn{v}"] = sources.fetch_file(ASN_CSV[v], path, check=lambda p: os.path.getsize(p) > 100_000)
            except ValueError:
                if v == 4:
                    raise ValueError(f"network data: {first}")
                continue
            with open(path, newline="", encoding="utf-8", errors="replace") as f:
                for row in csv.reader(f):
                    if len(row) >= 4:
                        add(row[0], row[1], row[2], "", row[3])
            os.unlink(path)

    # sorted by start (the sources are; sorting again costs little and makes sure)
    def save(name, arr):
        with open(os.path.join(d, name + ".tmp"), "wb") as f:
            if isinstance(arr, (bytes, bytearray)):
                f.write(arr)
            else:
                arr.tofile(f)
    for name, arr in (("c4s", c_start), ("c4e", c_end), ("c4c", c_cc), ("a4s", a4_start), ("a4e", a4_end), ("a4a", a4_asn), ("a4n", a4_name),
                      ("a6s", a6_start), ("a6e", a6_end), ("a6a", a6_asn), ("a6n", a6_name), ("a6c", a6_cc)):
        save(name, arr)
    # newline="\n": the reader splits on \n, also when this runs on Windows (tests)
    with open(os.path.join(d, "names.tmp"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(names))
    with open(os.path.join(d, "ccs.tmp"), "w", newline="\n") as f:
        f.write("\n".join(ccs))
    for name in ("c4s", "c4e", "c4c", "a4s", "a4e", "a4a", "a4n", "a6s", "a6e", "a6a", "a6n", "a6c", "names", "ccs"):
        os.replace(os.path.join(d, name + ".tmp"), os.path.join(d, name))
    m = {"built": int(time.time()), "sources": used,
         "rows": {"country4": len(c_start), "asn4": len(a4_start), "asn6": len(a6_asn), "networks": len(names)}}
    with open(os.path.join(d, "meta.json.tmp"), "w") as f:
        json.dump(m, f)
    os.replace(os.path.join(d, "meta.json.tmp"), os.path.join(d, "meta.json"))
    try:
        os.rmdir(tmp)
    except OSError:
        pass


def ensure(data, force=False):
    """Download / refresh in the background when missing or a month old. Returns at once."""
    m = meta(data)
    if not force and m.get("built") and time.time() - m["built"] < MAX_AGE:
        return
    if _job["state"] == "running" or (not force and _job["state"] == "error" and time.time() - _job["at"] < 900):
        return      # a failed download is retried after 15 minutes, not on every request

    def run():
        global _db
        _job.update(state="running", error="", at=time.time())
        try:
            _build(data)
            with _lock:
                _db = None          # the next lookup loads the new tables
            _job.update(state="done", at=time.time())
        except Exception as e:
            _job.update(state="error", error=str(e)[:300], at=time.time())
    threading.Thread(target=run, daemon=True).start()


# ------------------------------------------------------------------ lookups

def _load(data):
    d = _dir(data)

    def arr(name, code):
        a = array.array(code)
        with open(os.path.join(d, name), "rb") as f:
            a.frombytes(f.read())
        return a
    # 87 000 network names as one block of bytes and their offsets: a few MB, not a list of strings
    with open(os.path.join(d, "names"), "rb") as f:
        blob = f.read()
    offs, pos = array.array("L", [0]), blob.find(b"\n")
    while pos != -1:
        offs.append(pos + 1)
        pos = blob.find(b"\n", pos + 1)
    offs.append(len(blob) + 1)
    names = (blob, offs)
    with open(os.path.join(d, "ccs")) as f:
        ccs = f.read().split("\n")
    with open(os.path.join(d, "a6s"), "rb") as f:
        a6s = f.read()
    with open(os.path.join(d, "a6e"), "rb") as f:
        a6e = f.read()
    return {"c4s": arr("c4s", "L"), "c4e": arr("c4e", "L"), "c4c": arr("c4c", "H"), "a4s": arr("a4s", "L"), "a4e": arr("a4e", "L"),
            "a4a": arr("a4a", "L"), "a4n": arr("a4n", "L"), "a6s": a6s, "a6e": a6e, "a6a": arr("a6a", "L"), "a6n": arr("a6n", "L"),
            "a6c": arr("a6c", "H"), "names": names, "ccs": ccs}


def _get(data):
    global _db, _used
    _used = time.time()
    if _db is None:
        with _lock:
            if _db is None and meta(data).get("built"):
                try:
                    _db = _load(data)
                except (OSError, ValueError):
                    _db = None
    return _db


def unload_if_idle():
    global _db
    if _db is not None and time.time() - _used > IDLE_UNLOAD:
        with _lock:
            _db = None


def _name(db, i):
    blob, offs = db["names"]
    return blob[offs[i]:offs[i + 1] - 1].decode("utf-8", "replace")


def _find6(blob, n, key):
    """Index of the last 16-byte start <= key in a sorted blob of n starts (bytes compare = number compare)."""
    lo, hi = 0, n
    while lo < hi:
        mid = (lo + hi) // 2
        if blob[mid * 16:mid * 16 + 16] <= key:
            lo = mid + 1
        else:
            hi = mid
    return lo - 1


def lookup(data, ip):
    """{"cc": "DE", "asn": 24940, "org": "HETZNER-AS"} (None where not known)."""
    db = _get(data)
    out = {"cc": None, "asn": None, "org": None}
    if db is None:
        return out
    try:
        if ":" in ip:
            key = _v6(ip)
            n = len(db["a6a"])
            i = _find6(db["a6s"], n, key)
            if i >= 0 and db["a6e"][i * 16:i * 16 + 16] >= key:
                asn, cc, name = _name(db, db["a6n"][i]).split("\t", 2)
                out.update(asn=int(asn), org=name, cc=(db["ccs"][db["a6c"][i]] or cc or None))
            return out
        n = _v4(ip)
    except (OSError, ValueError):
        return out
    i = bisect.bisect_right(db["c4s"], n) - 1
    if i >= 0 and db["c4e"][i] >= n:
        out["cc"] = db["ccs"][db["c4c"][i]]
    i = bisect.bisect_right(db["a4s"], n) - 1
    if i >= 0 and db["a4e"][i] >= n:
        asn, cc, name = _name(db, db["a4n"][i]).split("\t", 2)
        out.update(asn=int(asn), org=name)
        if not out["cc"] and cc:
            out["cc"] = cc
    return out
