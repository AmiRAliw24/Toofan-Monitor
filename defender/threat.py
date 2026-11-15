"""Threat-intelligence blocklists: public lists of attacking / hijacked addresses, refreshed every 12 hours.

Private, loopback and other reserved ranges are always removed from the lists (some include them as
"bogons"), so Docker, VPN tunnels and the LAN are never affected.
"""
import ipaddress
import os
import time
from urllib.request import Request, urlopen

FEEDS = {
    "spamhaus": {"name": "Spamhaus DROP", "urls": ["https://www.spamhaus.org/drop/drop.txt", "https://www.spamhaus.org/drop/dropv6.txt"],
                 "site": "spamhaus.org"},
    "firehol": {"name": "FireHOL Level 1", "urls": ["https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset"],
                "site": "iplists.firehol.org"},
    "blocklistde": {"name": "blocklist.de", "urls": ["https://lists.blocklist.de/lists/all.txt"], "site": "blocklist.de"},
    "et": {"name": "Emerging Threats", "urls": ["https://rules.emergingthreats.net/blockrules/compromised-ips.txt"], "site": "emergingthreats.net"},
    "cins": {"name": "CINS Army", "urls": ["https://cinsscore.com/list/ci-badguys.txt"], "site": "cinsscore.com"},
}
MAX_AGE = 12 * 3600
RESERVED = [ipaddress.ip_network(n) for n in ("0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
                                               "192.0.0.0/24", "192.168.0.0/16", "198.18.0.0/15", "224.0.0.0/3", "::/8", "fc00::/7", "fe80::/10", "ff00::/8")]


def _dir(data):
    d = os.path.join(data, "threat")
    os.makedirs(d, exist_ok=True)
    return d


def _clean(text):
    v4, v6 = [], []
    for line in text.splitlines():
        token = line.split(";")[0].split("#")[0].strip().split()
        if not token:
            continue
        try:
            net = ipaddress.ip_network(token[0], strict=False)
        except ValueError:
            continue
        if net.prefixlen == 0 or any(net.version == r.version and net.overlaps(r) for r in RESERVED):
            continue
        (v4 if net.version == 4 else v6).append(str(net))
    return v4, v6


def fetch(data, fid, force=False):
    """Download one feed when it is older than MAX_AGE; returns (v4, v6) from the cache."""
    feed = FEEDS[fid]
    path4, path6 = (os.path.join(_dir(data), f"{fid}.{v}") for v in (4, 6))
    fresh = os.path.exists(path4) and time.time() - os.path.getmtime(path4) < MAX_AGE
    if force or not fresh:
        v4, v6 = [], []
        for url in feed["urls"]:
            req = Request(url, headers={"User-Agent": "server-monitor-firewall/1.0"})
            try:
                with urlopen(req, timeout=30) as r:
                    a, b = _clean(r.read(30_000_000).decode("utf-8", "replace"))
            except Exception as e:
                if not os.path.exists(path4):
                    raise ValueError(f"Cannot download {feed['name']}: {e}")
                return cached(data, fid)
            v4 += a
            v6 += b
        for path, items in ((path4, v4), (path6, v6)):
            with open(path + ".tmp", "w") as f:
                f.write("\n".join(sorted(set(items))))
            os.replace(path + ".tmp", path)
    return cached(data, fid)


def cached(data, fid):
    out = []
    for v in (4, 6):
        p = os.path.join(_dir(data), f"{fid}.{v}")
        out.append([ln for ln in open(p).read().splitlines() if ln] if os.path.exists(p) else [])
    return out[0], out[1]


def build(data, ids, download=False):
    v4, v6 = set(), set()
    for fid in ids:
        if fid not in FEEDS:
            continue
        a, b = fetch(data, fid) if download else cached(data, fid)
        v4.update(a)
        v6.update(b)
    return sorted(v4), sorted(v6)


def info(data):
    out = {}
    for fid, f in FEEDS.items():
        p = os.path.join(_dir(data), f"{fid}.4")
        v4, v6 = cached(data, fid)
        out[fid] = {"name": f["name"], "site": f["site"], "entries": len(v4) + len(v6), "updated": round(os.path.getmtime(p)) if os.path.exists(p) else None}
    return out


def member(data, ids, ip):
    """Which of the enabled feeds list this address."""
    addr = ipaddress.ip_address(ip)
    hits = []
    for fid in ids:
        a, b = cached(data, fid)
        for n in (a if addr.version == 4 else b):
            if addr in ipaddress.ip_network(n):
                hits.append(FEEDS[fid]["name"])
                break
    return hits
