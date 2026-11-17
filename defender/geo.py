"""Country ranges for the rules: from ipdeny.com, or when that fails from the country lists on GitHub
(herrbischoff/country-ip-blocks, ipverse/rir-ip, also through jsDelivr and GitHub proxies). Cached for a
week; a failed or empty download never replaces the copy that is already there."""
import ipaddress
import os
import re
import time
import sources

URLS = {
    4: ["https://www.ipdeny.com/ipblocks/data/aggregated/{cc}-aggregated.zone",
        "https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/{cc}.cidr",
        "https://raw.githubusercontent.com/ipverse/rir-ip/master/country/{cc}/ipv4-aggregated.txt"],
    6: ["https://www.ipdeny.com/ipv6/ipaddresses/aggregated/{cc}-aggregated.zone",
        "https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv6/{cc}.cidr",
        "https://raw.githubusercontent.com/ipverse/rir-ip/master/country/{cc}/ipv6-aggregated.txt"],
}
MAX_AGE = 7 * 86400
CC_RE = re.compile(r"^[a-z]{2}$")


def _dir(data):
    d = os.path.join(data, "geo")
    os.makedirs(d, exist_ok=True)
    return d


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
    for version in (4, 6):
        path = os.path.join(d, f"{cc}.{version}")
        fresh = os.path.exists(path) and time.time() - os.path.getmtime(path) < MAX_AGE
        if download and (refresh or not fresh):
            try:
                text = sources.fetch_any([u.format(cc=cc) for u in URLS[version]], check=lambda t, v=version: bool(_parse(t, v)), timeout=25)
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
