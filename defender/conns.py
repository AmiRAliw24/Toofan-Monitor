"""Who is connected to this server, from where, to what: the live connections view.

Source: the kernel's connection tracking table (`conntrack -L`), which holds every connection the server
takes part in, also ones that never completed (a SYN flood leaves half-open entries there). Each entry is
classified as incoming (someone connects to this server), outgoing (this server or one of its containers
connects out) or internal, enriched with the remote address's country and network (ipdb), and the
service it reaches (the listening process, or the container Docker forwards the port to).

Identical connections (same remote address, same port, same state) are merged into one row with a
count: the remote side's random source port says nothing, and a flood of 300 000 entries becomes a few
thousand rows. Reading the table costs CPU in proportion to its size, so snapshots are only taken while
the page is open, at an interval that keeps that cost under about a tenth of one core.
"""
import collections
import ipaddress
import json
import os
import re
import socket
import subprocess
import threading
import time

import hostinfo
import ipdb

MAX_ENTRIES = 600_000          # never parse more than this many conntrack lines
TIMELINE = 30 * 60             # seconds of history kept while the page is watched
KEEP_REPORTS = 30
WELL_KNOWN = {20: "ftp-data", 21: "ftp", 22: "ssh", 23: "telnet", 25: "smtp", 53: "dns", 67: "dhcp", 80: "http", 110: "pop3",
              123: "ntp", 143: "imap", 161: "snmp", 389: "ldap", 443: "https", 465: "smtps", 587: "submission", 853: "dns-tls",
              993: "imaps", 995: "pop3s", 1194: "openvpn", 1433: "mssql", 1723: "pptp", 1883: "mqtt", 2049: "nfs", 3306: "mysql",
              3389: "rdp", 5060: "sip", 5432: "postgres", 5900: "vnc", 6379: "redis", 8080: "http-alt", 8443: "https-alt",
              9090: "prometheus", 9100: "node-exporter", 11211: "memcached", 27017: "mongodb", 51820: "wireguard"}
ACCT = "/proc/sys/net/netfilter/nf_conntrack_acct"

_lock = threading.Lock()
_snap = None                   # the last snapshot
_watched = 0.0
_timeline = collections.deque()
_first_seen = {}
_local = {"at": 0, "set": frozenset()}
_geo_cache = {}
_subnets = {}
_data = "/data"
_ip_status = None              # agent callback: ip -> {"banned": ..., "blocked": ..., "allowed": ..., "threat": [names]}
_on_report = None              # agent callback: a new attack report (for the event log and Telegram)
HISTORY = 48 * 3600            # background history kept (about 600 points)
HISTORY_EVERY = 300            # seconds between background points (more when the table is huge)
_history = collections.deque()
_hist_last = 0.0


def configure(data, ip_status, on_report=None):
    global _data, _ip_status, _on_report
    _data, _ip_status, _on_report = data, ip_status, on_report
    _load_history()
    threading.Thread(target=_housekeeping, daemon=True).start()
    threading.Thread(target=_history_loop, daemon=True).start()


def _housekeeping():
    global _snap
    while True:
        time.sleep(120)
        ipdb.unload_if_idle()
        if time.time() - _watched > 600:          # nobody looking: free the memory
            with _lock:
                _snap = None
                _timeline.clear()
                _first_seen.clear()
                _geo_cache.clear()
                _subnets.clear()


def _locals():
    if time.time() - _local["at"] > 60:
        addrs = set(hostinfo.local_addresses()) | {"127.0.0.1", "::1"}
        _local.update(at=time.time(), set=frozenset(addrs))
    return _local["set"]


def geo(ip):
    hit = _geo_cache.get(ip)
    if hit is None:
        if len(_geo_cache) > 300_000:
            _geo_cache.clear()
        try:
            a = ipaddress.ip_address(ip)
            if a.is_private or a.is_loopback or a.is_link_local:
                hit = ("LAN", None, None)
            else:
                g = ipdb.lookup(_data, ip)
                hit = (g["cc"], g["asn"], g["org"])
        except ValueError:
            hit = (None, None, None)
        _geo_cache[ip] = hit
    return hit


def acct_on():
    try:
        return open(ACCT).read().strip() == "1"
    except OSError:
        return False


def set_acct(on):
    with open(ACCT, "w") as f:
        f.write("1" if on else "0")


# ------------------------------------------------------------------ reading the table

_svc_cache = {"at": 0, "map": {}}


def _services():
    """(proto, port) -> the process listening there (cached: listing sockets and Docker's forwards costs more than reading the table)."""
    if time.time() - _svc_cache["at"] > 30:
        out = {(r["proto"], r["port"]): r["process"] for r in hostinfo.listening()}
        for proto, port in hostinfo.docker_published():
            out.setdefault((proto, port), "docker")
        _svc_cache.update(at=time.time(), map=out)
    return _svc_cache["map"]


_proc_cache = {"at": 0, "map": {}}


def _client_procs():
    """(proto, local port) -> the program owning that socket, for this server's own outgoing connections
    (containers have their own network: those show the container's address instead)."""
    if time.time() - _proc_cache["at"] > 30:
        owners, out = hostinfo._inode_owners(), {}
        for proto, files in (("tcp", ("/proc/net/tcp", "/proc/net/tcp6")), ("udp", ("/proc/net/udp", "/proc/net/udp6"))):
            for path in files:
                try:
                    lines = open(path).read().splitlines()[1:]
                except OSError:
                    continue
                for line in lines:
                    p = line.split()
                    if len(p) > 9 and p[9] in owners:
                        out[(proto, int(p[1].rsplit(":", 1)[1], 16))] = owners[p[9]]
        _proc_cache.update(at=time.time(), map=out)
    return _proc_cache["map"]


def _parse(text, local, services, procs=None):
    """{key: [count, half_open, bytes_in, bytes_out, max_timeout]} with key =
    (dir, proto, remote, port, state, service, target)."""
    groups = {}
    procs = procs or {}
    n = loopback = 0
    for line in text.splitlines():
        n += 1
        if n > MAX_ENTRIES:
            break
        # the server talking to itself (often most of the table on proxy servers): counted, never parsed
        if "src=127.0.0.1 dst=127.0.0.1 " in line or "src=::1 dst=::1 " in line:
            loopback += 1
            continue
        p = line.split()
        if len(p) < 6:
            continue
        proto = p[2]
        try:
            timeout = int(p[4])
        except ValueError:
            timeout = 0
        state = p[5] if "=" not in p[5] and not p[5].startswith("[") else ""
        o, r = {}, {}
        cur, bytes_ = o, [0, 0]
        unreplied = False
        for tok in p[5:]:
            if tok == "[UNREPLIED]":
                unreplied = True
                continue
            k, eq, v = tok.partition("=")
            if not eq:
                continue
            if k == "src" and "src" in o:
                cur = r
            if k == "bytes":
                bytes_[0 if cur is o else 1] = int(v)
            elif k not in cur:
                cur[k] = v
        osrc, odst = o.get("src"), o.get("dst")
        if not osrc or not odst:
            continue
        rsrc, rdst = r.get("src", odst), r.get("dst", osrc)
        if odst in local:
            if osrc in local:
                d = "int"
            else:
                d = "in"
        elif osrc in local:
            d = "out"
        elif rdst in local:
            d = "out"                     # a container connecting out (masqueraded by the host)
        else:
            d = "int"
        if d == "in":
            remote, port = osrc, o.get("dport", "")
            target = f"{rsrc}:{r.get('sport', '')}" if rsrc != odst else ""      # Docker forwards it to a container
            svc = services.get((proto, int(port))) if port.isdigit() else None
            bin_, bout = bytes_[0], bytes_[1]
        elif d == "out":
            remote, port = odst, o.get("dport", "")
            target = osrc if osrc not in local else ""                          # the container that connects
            sp = o.get("sport", "")
            svc = procs.get((proto, int(sp))) if not target and sp.isdigit() else None   # the program that connects
            bin_, bout = bytes_[1], bytes_[0]
        else:
            remote, port, target, svc, bin_, bout = osrc, o.get("dport", ""), odst, None, bytes_[0], bytes_[1]
        if not svc and port.isdigit() and d != "out":
            svc = WELL_KNOWN.get(int(port))
        # half-open: an incoming TCP connection whose handshake never completed (what a SYN flood leaves)
        half = 1 if (proto == "tcp" and d == "in" and (state == "SYN_RECV" or unreplied)) else 0
        st = state or ("UNREPLIED" if unreplied else "ACTIVE")
        key = (d, proto, remote, port, st, svc or "", target)
        g = groups.get(key)
        if g is None:
            groups[key] = [1, half, bin_, bout, timeout]
        else:
            g[0] += 1; g[1] += half; g[2] += bin_; g[3] += bout
            if timeout > g[4]:
                g[4] = timeout
    return groups, n, loopback


def snapshot(force=False):
    """The current table, at most as fresh as the cost allows (see the module docstring)."""
    global _snap
    now = time.time()
    with _lock:
        s = _snap
        if s and not force and now - s["at"] < s["interval"]:
            return s
        t0 = time.time()
        try:
            text = subprocess.run(["conntrack", "-L", "-o", "extended"], capture_output=True, text=True, timeout=60).stdout
        except (OSError, subprocess.TimeoutExpired) as e:
            raise ValueError(f"cannot read the connection table: {e}")
        groups, n, loopback = _parse(text, _locals(), _services(), _client_procs())
        del text
        took = time.time() - t0
        usage = hostinfo.conntrack_usage() or {}
        s = {"at": now, "took": round(took, 3), "interval": min(60.0, max(4.0, took * 12)), "groups": groups,
             "entries": n, "loopback": loopback, "max": usage.get("max"), "truncated": n > MAX_ENTRIES}
        _snap = s
        _record(s)
        return s


def _point(at, groups, seen=None):
    """One point of a timeline: incoming, outgoing, half-open, addresses, and incoming per country."""
    inbound, ips = collections.Counter(), set()
    half = out = total_in = 0
    for (d, _p, remote, *_r), g in groups.items():
        if d == "in":
            total_in += g[0]
            half += g[1]
            ips.add(remote)
            inbound[geo(remote)[0] or "?"] += g[0]
            if seen is not None and remote not in seen:
                seen[remote] = at
        elif d == "out":
            out += g[0]
    return {"t": round(at), "in": total_in, "out": out, "half": half, "ips": len(ips), "cc": dict(inbound.most_common(12))}


def _record(s):
    """Timeline point and first-seen times (only while the page is watched)."""
    p = _point(s["at"], s["groups"], _first_seen)
    _timeline.append(p)
    while _timeline and _timeline[0]["t"] < s["at"] - TIMELINE:
        _timeline.popleft()
    if len(_first_seen) > 200_000:
        _first_seen.clear()
    if history_on() and s["at"] - _hist_last >= HISTORY_EVERY:     # a watched snapshot also serves the history
        _add_history(p)


# ------------------------------------------------------------------ background history (48 hours)

def _hist_path():
    return os.path.join(_data, "conn_history.json")


def history_on():
    return not os.path.exists(os.path.join(_data, "conn_history_off"))


def set_history(on):
    flag = os.path.join(_data, "conn_history_off")
    if on and os.path.exists(flag):
        os.unlink(flag)
    elif not on:
        open(flag, "w").close()
        _history.clear()
        try:
            os.unlink(_hist_path())
        except OSError:
            pass


def _load_history():
    try:
        with open(_hist_path()) as f:
            pts = json.load(f)
        cut = time.time() - HISTORY
        _history.extend(p for p in pts if isinstance(p, dict) and p.get("t", 0) >= cut)
    except (OSError, ValueError):
        pass


def _add_history(p):
    global _hist_last
    _hist_last = p["t"]
    _history.append(p)
    while _history and _history[0]["t"] < p["t"] - HISTORY:
        _history.popleft()
    tmp = _hist_path() + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(list(_history), f, separators=(",", ":"))
        os.replace(tmp, _hist_path())
    except OSError:
        pass


def _history_loop():
    """Every few minutes, also when nobody has the page open, note where incoming connections come from.
    Reading the table costs ~0.2 s per 15 000 entries; the pace slows down when it is bigger."""
    time.sleep(90)
    every = HISTORY_EVERY
    while True:
        try:
            if history_on() and time.time() - _hist_last >= every and ipdb.meta(_data).get("built"):
                t0 = time.time()
                text = subprocess.run(["conntrack", "-L", "-o", "extended"], capture_output=True, text=True, timeout=60).stdout
                groups, _n, _lb = _parse(text, _locals(), _services())
                del text
                with _lock:
                    _add_history(_point(time.time(), groups))
                every = max(HISTORY_EVERY, (time.time() - t0) * 300)   # at most ~0.3% of one core
        except Exception as e:  # the next round tries again
            print(f"conns history: {type(e).__name__}: {e}", flush=True)
        time.sleep(60)


# ------------------------------------------------------------------ the view

def _subnet(ip):
    hit = _subnets.get(ip)
    if hit is None:
        try:
            a = ipaddress.ip_address(ip)
            hit = str(ipaddress.ip_network(f"{ip}/{24 if a.version == 4 else 48}", strict=False))
        except ValueError:
            hit = ip
        if len(_subnets) > 300_000:
            _subnets.clear()
        _subnets[ip] = hit
    return hit


def _match(q, d, proto, remote, port, st, svc, target, cc, asn, org):
    if q["dir"] != "all" and d != q["dir"]:
        return False
    if q["proto"] and proto != q["proto"]:
        return False
    if q["state"] and q["state"] != "HALF" and st != q["state"]:
        return False
    if q["port"] and port != q["port"]:
        return False
    if q["cc"] and (cc or "?") != q["cc"]:
        return False
    if q["asn"] and str(asn or "") != q["asn"]:
        return False
    if q["ip"] and remote != q["ip"] and _subnet(remote) != q["ip"]:
        return False
    if q["text"]:
        hay = f"{remote} {port} {svc} {target} {cc or ''} {asn or ''} {org or ''} {st}".lower()
        if q["text"] not in hay and (cc or "") not in q["qcc"]:
            return False
    return True


def _query(params):
    def s(k, n=64):
        return str(params.get(k, "") or "").strip()[:n]
    d = s("dir") or "in"
    if d not in ("in", "out", "int", "all"):
        d = "in"
    try:
        limit = max(20, min(2000, int(params.get("limit", 300))))
    except ValueError:
        limit = 300
    return {"dir": d, "proto": s("proto").lower(), "state": s("state").upper(), "port": s("port"), "cc": s("cc").upper(),
            "asn": s("asn"), "ip": s("ip"), "text": s("q", 80).lower(), "limit": limit, "hist": s("hist") == "1",
            # countries whose name in the viewer's language matches the search text (the page sends their codes)
            "qcc": {c for c in s("qcc", 900).upper().split(",") if len(c) == 2 and c.isalpha()}}


def view(params):
    global _watched
    _watched = time.time()
    db = ipdb.status(_data)
    ipdb.ensure(_data)                  # first use: download the country / network data in the background
    snap = snapshot()
    q = _query(params)

    countries, ports, ips, asns, subnets = {}, {}, {}, {}, {}
    orgs = {}
    rows = []
    conns = half = bin_t = bout_t = 0
    by_proto, by_state = collections.Counter(), collections.Counter()
    dirs = collections.Counter({"int": snap.get("loopback", 0)})
    for key, g in snap["groups"].items():
        d, proto, remote, port, st, svc, target = key
        dirs[d] += g[0]
        if q["state"] == "HALF" and not g[1]:
            continue
        cc, asn, org = geo(remote)
        if not _match(q, d, proto, remote, port, st, svc, target, cc, asn, org):
            continue
        n, h, bi, bo, to = g
        conns += n; half += h; bin_t += bi; bout_t += bo
        by_proto[proto] += n
        by_state[st] += n
        if asn:
            orgs[asn] = org
        c = countries.setdefault(cc or "?", [0, 0, set()])
        c[0] += n; c[1] += h; c[2].add(remote)
        pk = (proto, port)
        pr = ports.setdefault(pk, [0, 0, set(), collections.Counter(), svc, set()])
        pr[0] += n; pr[1] += h; pr[2].add(remote); pr[3][cc or "?"] += n
        if target:
            pr[5].add(target)
        ir = ips.setdefault(remote, [0, 0, collections.Counter(), collections.Counter(), 0, 0, cc, asn])
        ir[0] += n; ir[1] += h; ir[2][f"{port}/{proto}" if port else proto] += n; ir[3][st] += n; ir[4] += bi; ir[5] += bo
        if asn:
            ar = asns.setdefault(asn, [0, set(), cc])
            ar[0] += n; ar[1].add(remote)
        net = _subnet(remote)
        sr = subnets.setdefault(net, [0, set(), cc])
        sr[0] += n; sr[1].add(remote)
        rows.append((key, g, cc, asn))

    def top(dct, n, fn, keyf=lambda kv: -kv[1][0]):
        return [fn(k, v) for k, v in sorted(dct.items(), key=keyf)[:n]]

    st_of = _ip_status or (lambda ip: {})
    ip_rows = top(ips, 150, lambda ip, v: {
        "ip": ip, "cc": v[6], "asn": v[7], "conns": v[0], "half": v[1], "ports": [p for p, _ in v[2].most_common(4)],
        "nports": len(v[2]), "states": dict(v[3].most_common(4)), "bytes_in": v[4], "bytes_out": v[5],
        "first": _first_seen.get(ip), "subnet": _subnet(ip), **st_of(ip)})
    # the busiest remote addresses first, then their rows
    rank = {ip: -v[0] for ip, v in ips.items()}
    rows.sort(key=lambda r: (rank[r[0][2]], -r[1][0]))
    out_rows = [{"dir": k[0], "proto": k[1], "ip": k[2], "port": k[3], "state": k[4], "svc": k[5], "target": k[6],
                 "n": g[0], "half": g[1], "bytes_in": g[2], "bytes_out": g[3], "ttl": g[4], "cc": cc, "asn": asn}
                for k, g, cc, asn in rows[:q["limit"]]]

    nips = len(ips)
    result = {
        "at": snap["at"], "took": snap["took"], "interval": snap["interval"], "entries": snap["entries"], "max": snap["max"],
        "truncated": snap["truncated"], "acct": acct_on(), "db": db, "query": {**q, "qcc": sorted(q["qcc"])},
        "dirs": dict(dirs),
        "summary": {"conns": conns, "ips": nips, "countries": len([c for c in countries if c not in ("?", "LAN")]), "asns": len(asns),
                    "half": half, "bytes_in": bin_t, "bytes_out": bout_t, "proto": dict(by_proto), "states": dict(by_state.most_common(12))},
        "countries": top(countries, 60, lambda cc, v: {"cc": cc, "conns": v[0], "half": v[1], "ips": len(v[2])}),
        "ports": top(ports, 40, lambda k, v: {"proto": k[0], "port": k[1], "svc": v[4], "conns": v[0], "half": v[1], "ips": len(v[2]),
                                             "ccs": [c for c, _ in v[3].most_common(4)], "targets": sorted(v[5])[:3]}),
        "ips": ip_rows,
        "asns": top(asns, 40, lambda a, v: {"asn": a, "org": orgs.get(a), "cc": v[2], "conns": v[0], "ips": len(v[1])}),
        "subnets": top(subnets, 40, lambda net, v: {"net": net, "cc": v[2], "conns": v[0], "ips": len(v[1])}),
        "rows": out_rows, "rows_total": len(rows),
        "orgs": {a: orgs[a] for a in {r["asn"] for r in out_rows if r["asn"]} | {r["asn"] for r in ip_rows if r["asn"]} if a in orgs},
        "timeline": list(_timeline),
        "history": list(_history) if q["hist"] else None, "history_on": history_on(),
        "insights": insights(conns, half, countries, subnets, ips, asns, q["dir"]),
        "reports": [{k: r[k] for k in ("id", "since", "ended", "reason", "conns", "top_cc", "top_port")} for r in reports()][::-1],
    }
    return result


def insights(conns, half, countries, subnets, ips, asns, d):
    """Plain findings for the top of the page ("82% of incoming connections come from Germany")."""
    out = []
    if d != "in" or conns < 50:
        return out
    real = {k: v for k, v in countries.items() if k not in ("?", "LAN")}
    if real:
        cc, v = max(real.items(), key=lambda kv: kv[1][0])
        share = v[0] / conns
        if share >= 0.5 and len(real) > 1:
            out.append({"kind": "country", "cc": cc, "share": round(share, 3), "conns": v[0], "ips": len(v[2])})
    if half / conns >= 0.25 and half >= 100:
        out.append({"kind": "half", "share": round(half / conns, 3), "conns": half})
    if subnets:
        net, v = max(subnets.items(), key=lambda kv: kv[1][0])
        if v[0] / conns >= 0.3 and len(v[1]) >= 3:
            out.append({"kind": "subnet", "net": net, "share": round(v[0] / conns, 3), "conns": v[0], "ips": len(v[1]), "cc": v[2]})
    if ips:
        ip, v = max(ips.items(), key=lambda kv: kv[1][0])
        if v[0] / conns >= 0.2 and v[0] >= 100:
            out.append({"kind": "ip", "ip": ip, "share": round(v[0] / conns, 3), "conns": v[0], "cc": v[6]})
    if asns:
        a, v = max(asns.items(), key=lambda kv: kv[1][0])
        if v[0] / conns >= 0.5 and len(asns) > 1:
            out.append({"kind": "asn", "asn": a, "share": round(v[0] / conns, 3), "conns": v[0], "ips": len(v[1])})
    return out


# ------------------------------------------------------------------ attack reports

def _reports_path():
    return os.path.join(_data, "attack_reports.json")


def reports():
    try:
        with open(_reports_path()) as f:
            return json.load(f)
    except (OSError, ValueError):
        return []


def report(rid):
    for r in reports():
        if r["id"] == rid:
            return r
    raise ValueError("no such report")


def record_attack(is_active, since, reason):
    """While an attack lasts, snapshot the incoming connections and keep the busiest one as its report."""
    def run():
        global _watched
        best, best_n, t_end = None, -1, time.time() + 3600
        while time.time() < t_end:
            _watched = time.time()          # keep the snapshot alive while recording
            try:
                v = view({"dir": "in", "limit": 20})
            except Exception:
                v = None
            if v and v["summary"]["conns"] > best_n:
                best, best_n = v, v["summary"]["conns"]
            if not is_active():
                break
            time.sleep(max(15.0, (v or {}).get("interval", 15)))
        if not best:
            return
        rep = {"id": int(since), "since": int(since), "ended": int(time.time()) if not is_active() else None, "reason": reason,
               "at": int(best["at"]), "conns": best["summary"]["conns"], "half": best["summary"]["half"], "ips": best["summary"]["ips"],
               "top_cc": best["countries"][0]["cc"] if best["countries"] else None,
               "top_port": (f"{best['ports'][0]['port']}/{best['ports'][0]['proto']}" if best["ports"][0]["port"] else best["ports"][0]["proto"]) if best["ports"] else None,
               "countries": best["countries"][:12], "ports": best["ports"][:8], "asns": best["asns"][:10], "subnets": best["subnets"][:10],
               "ip_list": [{k: r[k] for k in ("ip", "cc", "asn", "conns", "half")} for r in best["ips"][:25]], "orgs": best["orgs"]}
        all_ = [r for r in reports() if r["id"] != rep["id"]] + [rep]
        tmp = _reports_path() + ".tmp"
        with open(tmp, "w") as f:
            json.dump(all_[-KEEP_REPORTS:], f)
        os.replace(tmp, _reports_path())
        if _on_report:
            try:
                _on_report(rep)
            except Exception as e:
                print(f"conns report hook: {e}", flush=True)
    threading.Thread(target=run, daemon=True).start()


_SAFE = re.compile(r"^[0-9a-fA-F:.]{2,45}$")


def check_ip(ip):
    if not _SAFE.match(ip or ""):
        raise ValueError("invalid address")
    ipaddress.ip_address(ip)
    return ip


_ptr_cache = {}


def _ptr(ip):
    """The address's host name (reverse DNS), waiting at most 1.5 s."""
    if ip in _ptr_cache:
        return _ptr_cache[ip]
    res = {}

    def run():
        try:
            res["name"] = socket.gethostbyaddr(ip)[0]
        except (OSError, UnicodeError):
            res["name"] = None
    th = threading.Thread(target=run, daemon=True)
    th.start()
    th.join(1.5)
    if "name" in res:
        if len(_ptr_cache) > 5000:
            _ptr_cache.clear()
        _ptr_cache[ip] = res["name"]
    return res.get("name")


def detail(params):
    """Everything about one remote address: where it is, what it does here, every connection of it."""
    ip = check_ip(str(params.get("ip", "")))
    cc, asn, org = geo(ip)
    v = view({"ip": ip, "dir": "all", "limit": 500})
    return {"ip": ip, "cc": cc, "asn": asn, "org": org, "subnet": _subnet(ip), "first": _first_seen.get(ip), "ptr": _ptr(ip),
            "summary": v["summary"], "ports": v["ports"], "rows": v["rows"], **((_ip_status or (lambda i: {}))(ip))}
