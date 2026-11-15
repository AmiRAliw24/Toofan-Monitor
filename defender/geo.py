"""Country blocking: IP ranges per country from ipdeny.com (aggregated zones), cached for a week."""
import ipaddress
import os
import re
import time
from urllib.request import Request, urlopen

URL4 = "https://www.ipdeny.com/ipblocks/data/aggregated/{cc}-aggregated.zone"
URL6 = "https://www.ipdeny.com/ipv6/ipaddresses/aggregated/{cc}-aggregated.zone"
MAX_AGE = 7 * 86400
CC_RE = re.compile(r"^[a-z]{2}$")


def _dir(data):
    d = os.path.join(data, "geo")
    os.makedirs(d, exist_ok=True)
    return d


def _fetch(url):
    req = Request(url, headers={"User-Agent": "server-monitor-firewall/1.0"})
    with urlopen(req, timeout=25) as r:
        return r.read(20_000_000).decode("ascii", "replace")


def _parse(text, version):
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            net = ipaddress.ip_network(line, strict=False)
        except ValueError:
            continue
        if net.version == version:
            out.append(str(net))
    return out


def zones(data, cc, refresh=False, download=True):
    """(v4 list, v6 list) for one country; downloads when missing or older than a week."""
    if not CC_RE.match(cc):
        raise ValueError(f"unknown country code: {cc}")
    d = _dir(data)
    res = []
    for version, url in ((4, URL4), (6, URL6)):
        path = os.path.join(d, f"{cc}.{version}")
        fresh = os.path.exists(path) and time.time() - os.path.getmtime(path) < MAX_AGE
        if download and (refresh or not fresh):
            try:
                text = _fetch(url.format(cc=cc))
                nets = _parse(text, version)
                tmp = path + ".tmp"
                with open(tmp, "w") as f:
                    f.write("\n".join(nets))
                os.replace(tmp, path)
            except Exception as e:
                if not os.path.exists(path):
                    if version == 6:   # some countries have no IPv6 list; IPv4 is what matters
                        res.append([])
                        continue
                    raise ValueError(f"Cannot download the address list of {cc.upper()}: {e}")
        if not os.path.exists(path):
            res.append([])
            continue
        with open(path) as f:
            res.append([ln for ln in f.read().splitlines() if ln])
    return res[0], res[1]


def build(data, codes, download=True):
    v4, v6, counts = [], [], {}
    for cc in codes:
        a, b = zones(data, cc, download=download)
        v4 += a
        v6 += b
        counts[cc] = len(a) + len(b)
    return v4, v6, counts


def info(data, codes):
    d = _dir(data)
    out = {}
    for cc in codes:
        p = os.path.join(d, f"{cc}.4")
        if os.path.exists(p):
            with open(p) as f:
                n = sum(1 for _ in f)
            out[cc] = {"ranges": n, "updated": round(os.path.getmtime(p))}
    return out
