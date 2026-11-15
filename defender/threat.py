"""Threat-intelligence blocklists: public lists of attacking, hijacked and botnet addresses.

Each list is downloaded, cleaned and merged into as few networks as possible, then stored on disk
(DATA/threat/<id>.4 and .6) with what is known about it in meta.json. A list is only written (and the
firewall only touched) when its content really changed. Private, loopback and other reserved ranges
are always removed, so Docker, VPN tunnels and the LAN are never affected.

Lookups for the panel (is this address listed? by which list?) use a sorted index of integer ranges,
built once per list version, so checking an address costs microseconds even with 100 000 entries.
"""
import bisect
import hashlib
import ipaddress
import json
import os
import re
import socket
import threading
import time
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

# kind: what the list contains. safe: almost no chance of blocking real users (turned on by "recommended").
FEEDS = {
    "spamhaus": {"name": "Spamhaus DROP", "site": "spamhaus.org", "kind": "hijacked", "safe": True,
                 "urls": ["https://www.spamhaus.org/drop/drop.txt", "https://www.spamhaus.org/drop/dropv6.txt"]},
    "firehol": {"name": "FireHOL Level 1", "site": "iplists.firehol.org", "kind": "mixed", "safe": True,
                "urls": ["https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset"]},
    "feodo": {"name": "abuse.ch Feodo Tracker", "site": "feodotracker.abuse.ch", "kind": "botnet", "safe": True,
              "urls": ["https://feodotracker.abuse.ch/downloads/ipblocklist.txt"]},
    "et": {"name": "Emerging Threats", "site": "emergingthreats.net", "kind": "compromised", "safe": True,
           "urls": ["https://rules.emergingthreats.net/blockrules/compromised-ips.txt"]},
    "cins": {"name": "CINS Army", "site": "cinsscore.com", "kind": "attackers", "safe": False,
             "urls": ["https://cinsscore.com/list/ci-badguys.txt"]},
    "blocklistde": {"name": "blocklist.de", "site": "blocklist.de", "kind": "attackers", "safe": False,
                    "urls": ["https://lists.blocklist.de/lists/all.txt"]},
    "ipsum": {"name": "IPsum (level 3)", "site": "github.com/stamparm/ipsum", "kind": "attackers", "safe": False,
              "urls": ["https://raw.githubusercontent.com/stamparm/ipsum/master/levels/3.txt"]},
    "greensnow": {"name": "GreenSnow", "site": "greensnow.co", "kind": "attackers", "safe": False,
                  "urls": ["https://blocklist.greensnow.co/greensnow.txt"]},
    "tor": {"name": "Tor exit nodes", "site": "torproject.org", "kind": "anonymizer", "safe": False,
            "urls": ["https://check.torproject.org/torbulkexitlist"]},
}
MAX_CUSTOM = 8
MAX_BYTES = 40_000_000           # per download
MAX_ENTRIES = 300_000            # per list, after merging (kernel memory stays small)
RESERVED = [ipaddress.ip_network(n) for n in (
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24",
    "192.0.2.0/24", "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/3",
    "::/8", "64:ff9b::/96", "2001:db8::/32", "fc00::/7", "fe80::/10", "ff00::/8")]
ID_RE = re.compile(r"^[a-z][a-z0-9]{1,15}$")
RANGE_RE = re.compile(r"^([0-9a-fA-F:.]+)\s*-\s*([0-9a-fA-F:.]+)$")
_lock = threading.RLock()
_cache = {}        # fid -> (mtime, v4, v6)
_index = {}        # fid -> (mtime, {4: (starts, ends), 6: (...)})


def _dir(data):
    d = os.path.join(data, "threat")
    os.makedirs(d, exist_ok=True)
    return d


def _meta_path(data):
    return os.path.join(_dir(data), "meta.json")


def load_meta(data):
    try:
        with open(_meta_path(data)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _save_meta(data, meta):
    tmp = _meta_path(data) + ".tmp"
    with open(tmp, "w") as f:
        json.dump(meta, f)
    os.replace(tmp, _meta_path(data))


def all_feeds(custom=()):
    """Built-in lists plus the user's own (custom: [{id, name, url}])."""
    out = {k: dict(v, custom=False) for k, v in FEEDS.items()}
    for c in custom or ():
        out[c["id"]] = {"name": c["name"], "site": urlsplit(c["url"]).hostname or "", "kind": "custom", "safe": False,
                        "urls": [c["url"]], "custom": True}
    return out


def check_url(url):
    """A list the user adds must be a public https address (the agent runs with the host's network)."""
    url = str(url or "").strip()
    parts = urlsplit(url)
    if parts.scheme != "https" or not parts.hostname or len(url) > 400 or parts.username or parts.password:
        raise ValueError("The list address must start with https:// and point to a public server")
    try:
        addrs = {ai[4][0] for ai in socket.getaddrinfo(parts.hostname, parts.port or 443, proto=socket.IPPROTO_TCP)}
    except OSError:
        raise ValueError(f"Cannot find the server {parts.hostname}")
    for a in addrs:
        ip = ipaddress.ip_address(a.split("%")[0])
        if not ip.is_global:
            raise ValueError(f"{parts.hostname} is a private or local address")
    return url


def parse(text):
    """Plain lists in any of the usual formats: one address, network or range per line, comments
    after # or ;, extra columns ignored. Returns merged (v4, v6) networks without reserved ranges."""
    nets = {4: [], 6: []}
    for line in text.splitlines():
        line = line.split("#")[0].split(";")[0].strip()
        if not line:
            continue
        m = RANGE_RE.match(line)
        try:
            if m:
                a, b = ipaddress.ip_address(m.group(1)), ipaddress.ip_address(m.group(2))
                found = list(ipaddress.summarize_address_range(a, b)) if a.version == b.version and a <= b else []
            else:
                token = line.replace(",", " ").split()[0]
                found = [ipaddress.ip_network(token, strict=False)]
        except ValueError:
            continue
        for net in found:
            if net.prefixlen == 0 or (net.version == 4 and net.prefixlen < 8) or (net.version == 6 and net.prefixlen < 16):
                continue          # a whole /0../7 is never a real entry
            if any(net.version == r.version and net.overlaps(r) for r in RESERVED):
                continue
            nets[net.version].append(net)
    return _merge(nets[4]), _merge(nets[6])


def _merge(nets):
    """As few networks as possible; single addresses without the /32 or /128."""
    return [str(n.network_address) if n.prefixlen == n.max_prefixlen else str(n) for n in ipaddress.collapse_addresses(nets)]


def _download(url):
    req = Request(url, headers={"User-Agent": "server-monitor-firewall/1.1", "Accept-Encoding": "identity"})
    with urlopen(req, timeout=40) as r:
        body = r.read(MAX_BYTES + 1)
    if len(body) > MAX_BYTES:
        raise ValueError("the list is larger than 40 MB")
    return body.decode("utf-8", "replace")


def fetch(data, fid, feed, max_age, force=False):
    """Downloads one list when it is older than max_age seconds (or force). Returns True when its
    content changed. A failed download keeps the previous copy and records the error."""
    with _lock:
        meta = load_meta(data)
        m = meta.get(fid, {})
        if not force and time.time() - m.get("fetched", 0) < max_age and os.path.exists(_file(data, fid, 4)):
            return False
    v4, v6, err = [], [], ""
    try:
        for url in feed["urls"]:
            a, b = parse(_download(url))
            v4 += a
            v6 += b
        if len(feed["urls"]) > 1:
            v4, v6 = _merge(ipaddress.ip_network(x) for x in v4), _merge(ipaddress.ip_network(x) for x in v6)
        if not v4 and not v6:
            raise ValueError("the list is empty or not in a known format")
        if len(v4) + len(v6) > MAX_ENTRIES:
            raise ValueError(f"the list has more than {MAX_ENTRIES} entries")
    except Exception as e:  # network error, HTTP error, bad content
        err = f"{type(e).__name__}: {e}"[:300] if not isinstance(e, ValueError) else str(e)[:300]
    with _lock:
        meta = load_meta(data)
        m = meta.setdefault(fid, {})
        now = int(time.time())
        if err:
            m.update(error=err, error_at=now)
            # try again later (15 min without any copy, an hour with one), not at every change of the settings
            m["fetched"] = now - max(0, max_age - (900 if not os.path.exists(_file(data, fid, 4)) else 3600))
            _save_meta(data, meta)
            if not os.path.exists(_file(data, fid, 4)):
                raise ValueError(f"Cannot download {feed['name']}: {err}")
            return False
        digest = hashlib.sha256(("\n".join(v4) + "|" + "\n".join(v6)).encode()).hexdigest()
        changed = digest != m.get("hash") or not os.path.exists(_file(data, fid, 4))
        if changed:
            for v, items in ((4, v4), (6, v6)):
                p = _file(data, fid, v)
                with open(p + ".tmp", "w") as f:
                    f.write("\n".join(items))
                os.replace(p + ".tmp", p)
            m.update(hash=digest, changed=now, v4=len(v4), v6=len(v6), addresses=_count(v4, v6))
        m.update(fetched=now, ok_at=now, error="", error_at=0)
        _save_meta(data, meta)
        return changed


def _file(data, fid, v):
    return os.path.join(_dir(data), f"{fid}.{v}")


def _count(v4, v6):
    """How many IPv4 addresses the list covers (IPv6 is shown as a number of networks)."""
    return sum(1 << (32 - int(x.split("/")[1])) if "/" in x else 1 for x in v4)


def cached(data, fid):
    """(v4, v6) from disk, kept in memory until the file changes."""
    p4, p6 = _file(data, fid, 4), _file(data, fid, 6)
    try:
        mtime = (os.path.getmtime(p4), os.path.getmtime(p6) if os.path.exists(p6) else 0)
    except OSError:
        return [], []
    with _lock:
        hit = _cache.get(fid)
        if hit and hit[0] == mtime:
            return hit[1], hit[2]
        out = []
        for p in (p4, p6):
            try:
                with open(p) as f:
                    out.append([ln for ln in f.read().splitlines() if ln])
            except OSError:
                out.append([])
        _cache[fid] = (mtime, out[0], out[1])
        _index.pop(fid, None)
        return out[0], out[1]


def remove(data, fid):
    with _lock:
        for v in (4, 6):
            try:
                os.remove(_file(data, fid, v))
            except OSError:
                pass
        meta = load_meta(data)
        if meta.pop(fid, None) is not None:
            _save_meta(data, meta)
        _cache.pop(fid, None)
        _index.pop(fid, None)


def lists(data, ids):
    """{fid: (v4, v6)} for the given lists, from disk."""
    return {fid: cached(data, fid) for fid in ids}


def _ranges(nets):
    pairs = []
    for n in nets:
        net = ipaddress.ip_network(n)
        pairs.append((int(net.network_address), int(net.broadcast_address)))
    pairs.sort()
    return [a for a, _ in pairs], [b for _, b in pairs]


def _idx(data, fid):
    v4, v6 = cached(data, fid)
    with _lock:
        hit = _index.get(fid)
        key = _cache.get(fid, (None,))[0]
        if hit and hit[0] == key:
            return hit[1]
        idx = {4: _ranges(v4), 6: _ranges(v6)}
        _index[fid] = (key, idx)
        return idx


def member(data, ids, ip):
    """Which of these lists contain the address (fast: a binary search per list)."""
    addr = ipaddress.ip_address(ip)
    n, hits = int(addr), []
    for fid in ids:
        starts, ends = _idx(data, fid)[addr.version]
        i = bisect.bisect_right(starts, n) - 1
        if i >= 0 and ends[i] >= n:     # lists are merged, so ranges never overlap
            hits.append(fid)
    return hits


def info(data, feeds):
    meta = load_meta(data)
    out = {}
    for fid, f in feeds.items():
        m = meta.get(fid, {})
        have = os.path.exists(_file(data, fid, 4))
        out[fid] = {"name": f["name"], "site": f["site"], "kind": f["kind"], "safe": f["safe"], "custom": f["custom"],
                    "url": f["urls"][0] if f["custom"] else "", "v4": m.get("v4", 0) if have else 0, "v6": m.get("v6", 0) if have else 0,
                    "addresses": m.get("addresses", 0) if have else 0, "updated": (m.get("ok_at") or None) if have else None,
                    "changed": m.get("changed") if have else None, "error": m.get("error", ""), "error_at": m.get("error_at", 0)}
    return out
