#!/usr/bin/env python3
"""Defender agent: firewall, anti-DDoS, SSH brute-force guard and kernel hardening for this server.

Runs as root in its own container with the host's network and PID namespaces (see docker-compose.yml)
and is controlled by the panel through a unix socket (DATA_DIR/agent.sock). Standard library only;
nft and conntrack come from the image.

Safety rules, in order of importance:
  * protection is off until someone turns it on in the panel;
  * the SSH and panel ports are always reachable, loopback / Docker / VPN tunnels are never filtered,
    and the IPs of logged-in SSH users are never banned;
  * every change to the rules is undone after ROLLBACK_SECONDS unless the panel confirms it is still
    reachable (the browser does that by itself right after applying);
  * all rules sit in their own table (inet defender), so removing it restores the server exactly:
        nft delete table inet defender
"""
import collections
import copy
import ipaddress
import json
import os
import re
import signal
import socket
import socketserver
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler
from urllib.parse import unquote

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import f2b  # noqa: E402
import geo  # noqa: E402
import hostinfo  # noqa: E402
import nftrules  # noqa: E402

VERSION = "1.0"
DATA = os.environ.get("DATA_DIR", "/data")
SOCK = os.path.join(DATA, "agent.sock")
PANEL_GID = int(os.environ.get("PANEL_GID", "65534"))
PANEL_PORTS = sorted({int(p) for p in re.findall(r"\d+", os.environ.get("PANEL_PORTS", "3000"))})
def ROLLBACK_SECONDS():  # noqa: N802 - kept as a "constant" name; the value lives in the configuration
    return int(CFG.get("advanced", {}).get("rollback_seconds", 60))
KEEP = 300                     # live samples (5 minutes)
def ADV(key):  # noqa: N802
    return CFG.get("advanced", {}).get(key, DEFAULT["advanced"][key])
LOCK = threading.RLock()

DEFAULT = {
    "enabled": False,
    "profile": "normal",
    "limits": dict(nftrules.PROFILES["normal"]),
    "auto_escalate": True,
    "ddos": {"drop_invalid": True, "bad_flags": True},
    "firewall": {"mode": "open", "ports": [], "trusted_ifaces": ["wg*", "gre*", "tun*", "ipip*", "ppp*", "tailscale*", "zt*"]},
    "allow": [],
    "block": [],
    "ssh_guard": {"enabled": True, "l4": True, "failures": 5, "window": 10, "ban": 60, "exempt_private": True},
    "trust_logged_in": True,
    "trust_cdn": True,
    "geo": {"block": []},
    # Expert settings (Advanced tab). Everything that used to be fixed can be changed here.
    "advanced": {
        "rollback_seconds": 60,       # 0 = apply changes without the safety test
        "ssh_rate": 12,               # new SSH connections per minute and source before a ban (0 = off)
        "ssh_ban_minutes": 60,
        "autoban_factor": 3,          # ban a source going this many times over a limit (0 = never ban, only drop)
        "detect_drops": 300, "detect_cookies": 50, "detect_pps": 20000, "detect_conntrack": 90, "calm_seconds": 30,
        "deescalate_minutes": 10,
        "trust_docker": True,         # never filter traffic from Docker bridges / veth
        "lock_ports": True,           # SSH and panel ports stay open whatever the mode
        "panel_allow": [],            # only these addresses may open the panel (empty = everyone)
        "custom_rules": "",           # extra nftables statements for new connections
    },
    "sysctl": {"applied": [], "original": {}},
    "notify": {"attacks": True, "bans": False},
}


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


# ------------------------------------------------------------------ persistence

def _path(name):
    return os.path.join(DATA, name)


def load_json(name, default):
    try:
        with open(_path(name)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return copy.deepcopy(default)


def save_json(name, obj):
    tmp = _path(name + ".tmp")
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=1)
    os.replace(tmp, _path(name))


def merged_default(cfg):
    out = copy.deepcopy(DEFAULT)
    for k, v in (cfg or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k].update(v)
        else:
            out[k] = v
    return out


CFG = merged_default(load_json("config.json", {}))
BANS = load_json("bans.json", {})            # ip -> {until, reason, source}: bans the agent made (for the panel)
EVENTS = collections.deque(load_json("events.json", []), maxlen=400)
F2B = load_json("f2b.json", {"default": {}, "jails": {}})   # fail2ban settings the panel manages
STATE = {
    "applied": False, "error": "", "pending": None, "escalated": False, "escalated_at": 0,
    "attack": {"active": False, "since": 0, "ended": 0, "peak": {}, "reason": ""},
    "samples": collections.deque(maxlen=KEEP), "bans_count": 0, "started": time.time(),
}


def event(kind, **data):
    with LOCK:
        eid = (EVENTS[-1]["id"] + 1) if EVENTS else 1
        EVENTS.append({"id": eid, "t": round(time.time(), 1), "kind": kind, **data})
        save_json("events.json", list(EVENTS))
    log("event", kind, data)


# ------------------------------------------------------------------ nft

def nft(args, stdin=None, check=True):
    p = subprocess.run(["nft"] + args, input=stdin, capture_output=True, text=True, timeout=20)
    if check and p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout).strip()[-800:] or f"nft exited with {p.returncode}")
    return p.stdout


def table_exists():
    return subprocess.run(["nft", "list", "table", "inet", "defender"], capture_output=True, timeout=10).returncode == 0


def current_bans():
    """Elements of the ban sets with their remaining time, so a rebuild of the table keeps them."""
    out = {"ban4": [], "ban6": []}
    if not table_exists():
        return out
    for name in out:
        try:
            data = json.loads(nft(["-j", "list", "set", "inet", "defender", name]))
        except (RuntimeError, ValueError):
            continue
        for item in data.get("nftables", []):
            for el in (item.get("set") or {}).get("elem", []) or []:
                if isinstance(el, dict) and "elem" in el:
                    e = el["elem"]
                    left = e.get("expires", e.get("timeout", 0))
                    if isinstance(e.get("val"), str) and left and left > 1:
                        out[name].append((e["val"], left))
                elif isinstance(el, str):
                    out[name].append((el, 900))
    return out


def effective_limits():
    return dict(nftrules.PROFILES["attack"]) if STATE["escalated"] else dict(CFG["limits"])


def ruleset(cfg=None):
    cfg = cfg or CFG
    allow_extra = [{"ip": ip} for ip in admin_ips()] if cfg.get("trust_logged_in", True) else []
    view = dict(cfg, allow=cfg["allow"] + allow_extra)
    g4, g6, _ = geo.build(DATA, cfg.get("geo", {}).get("block", []), download=False)
    return nftrules.build(view, effective_limits(), current_bans(), hostinfo.ssh_ports(), PANEL_PORTS, g4, g6)


def apply(cfg=None):
    """Make the kernel match the configuration (atomic: the whole table is replaced at once)."""
    cfg = cfg or CFG
    with LOCK:
        if not cfg["enabled"]:
            if table_exists():
                nft(["delete", "table", "inet", "defender"])
            STATE["applied"] = False
            STATE["error"] = ""
            return
        text = ruleset(cfg)
        nft(["-c", "-f", "-"], stdin=text)      # dry run against the kernel first
        nft(["-f", "-"], stdin=text)
        STATE["applied"] = True
        STATE["error"] = ""


def change(mutator, rollback=True, what="config"):
    """Apply a configuration change. With rollback the old rules come back unless confirmed in time."""
    global CFG
    with LOCK:
        prev = copy.deepcopy(CFG)
        new = copy.deepcopy(CFG)
        mutator(new)
        validate(new)
        if new["enabled"] and new["geo"]["block"]:
            geo.build(DATA, new["geo"]["block"], download=True)   # raises before anything changes
        try:
            apply(new)
        except Exception as e:
            try:
                apply(prev)
            except Exception:
                pass
            raise ValueError(f"The new rules were rejected, nothing changed: {e}")
        CFG = new
        save_json("config.json", CFG)
        if rollback and ROLLBACK_SECONDS() > 0 and (new["enabled"] or prev["enabled"]):
            old_pending = STATE["pending"]
            STATE["pending"] = {"until": time.time() + ROLLBACK_SECONDS(),
                                "prev": old_pending["prev"] if old_pending else prev, "what": what}
        event("applied", what=what)
        return status()


def confirm():
    with LOCK:
        if STATE["pending"]:
            STATE["pending"] = None
            event("confirmed")
    return status()


def rollback(reason="timeout"):
    global CFG
    with LOCK:
        p = STATE["pending"]
        if not p:
            return status()
        STATE["pending"] = None
        CFG = p["prev"]
        save_json("config.json", CFG)
        try:
            apply(CFG)
        except Exception as e:
            STATE["error"] = str(e)
        event("rollback", reason=reason)
    return status()


# ------------------------------------------------------------------ validation

PORT_RE = re.compile(r"^\d{1,5}(-\d{1,5})?$")
IFACE_RE = re.compile(r"^[A-Za-z0-9_.\-]{1,15}\*?$")


def net_str(net):
    """1.2.3.4 for a single address, 10.0.0.0/8 for a network."""
    return str(net.network_address) if net.num_addresses == 1 else str(net)


def parse_net(value, allow_any=False):
    try:
        net = ipaddress.ip_network(str(value).strip(), strict=False)
    except ValueError:
        raise ValueError(f"Not an IP address or network: {value}")
    if not allow_any and net.prefixlen == 0:
        raise ValueError(f"{value} is the whole internet")
    return net


def validate(cfg):
    if cfg["profile"] not in list(nftrules.PROFILES) + ["custom"]:
        raise ValueError("unknown profile")
    for k, (lo, hi) in nftrules.LIMIT_KEYS.items():
        v = cfg["limits"].get(k)
        if not isinstance(v, (int, float)) or not lo <= v <= hi:
            raise ValueError(f"{k}: must be between {lo} and {hi}")
        cfg["limits"][k] = int(v)
    fw = cfg["firewall"]
    if fw["mode"] not in ("open", "strict"):
        raise ValueError("mode must be open or strict")
    seen = set()
    for p in fw["ports"]:
        p["port"] = str(p.get("port", "")).strip()
        if p.get("proto") not in ("tcp", "udp", "both") or not PORT_RE.match(p["port"]):
            raise ValueError(f"Invalid port: {p.get('port')}")
        a, _, b = p["port"].partition("-")
        if not (1 <= int(a) <= 65535) or (b and not int(a) < int(b) <= 65535):
            raise ValueError(f"Invalid port range: {p['port']}")
        if p.get("from"):
            p["from"] = net_str(parse_net(p["from"], allow_any=True))
        p["note"] = str(p.get("note", ""))[:80]
        key = (p["proto"], p["port"], p.get("from") or "")
        if key in seen:
            raise ValueError(f"Port {p['port']} is listed twice")
        seen.add(key)
    if len(fw["ports"]) > 5000:
        raise ValueError("too many ports")
    for i in fw["trusted_ifaces"]:
        if not IFACE_RE.match(i):
            raise ValueError(f"Invalid interface name: {i}")
    for lst in ("allow", "block"):
        for e in cfg[lst]:
            e["ip"] = net_str(parse_net(e["ip"], allow_any=(lst == "allow")))
            e["note"] = str(e.get("note", ""))[:80]
        if len(cfg[lst]) > 100000:
            raise ValueError("list too long")
    codes = sorted({str(c).strip().lower() for c in cfg["geo"].get("block", [])})
    if len(codes) > 300 or not all(geo.CC_RE.match(c) for c in codes):
        raise ValueError("invalid country list")
    cfg["geo"]["block"] = codes
    a = cfg["advanced"]
    for k, lo, hi in (("rollback_seconds", 0, 3600), ("ssh_rate", 0, 100000), ("ssh_ban_minutes", 1, 525600), ("autoban_factor", 0, 1000),
                      ("detect_drops", 1, 10**9), ("detect_cookies", 1, 10**9), ("detect_pps", 1, 10**10), ("detect_conntrack", 1, 100),
                      ("calm_seconds", 5, 86400), ("deescalate_minutes", 0, 10080)):
        v = a.get(k, DEFAULT["advanced"][k])
        if not isinstance(v, (int, float)) or isinstance(v, bool) or not lo <= v <= hi:
            raise ValueError(f"{k}: must be between {lo} and {hi}")
        a[k] = int(v)
    for k in ("trust_docker", "lock_ports"):
        a[k] = bool(a.get(k, True))
    a["panel_allow"] = [net_str(parse_net(x, allow_any=True)) for x in a.get("panel_allow", []) if str(x).strip()][:5000]
    a["custom_rules"] = nftrules.check_custom(a.get("custom_rules", ""))
    g = cfg["ssh_guard"]
    for k, lo, hi in (("failures", 1, 100000), ("window", 1, 525600), ("ban", 1, 5256000)):
        if not isinstance(g.get(k), (int, float)) or not lo <= g[k] <= hi:
            raise ValueError(f"SSH guard {k}: must be between {lo} and {hi}")
        g[k] = int(g[k])


def own_or_admin(ip):
    """True for addresses that must never be blocked: this server, logged-in users, the allowlist."""
    net = ipaddress.ip_network(ip, strict=False)
    for a in hostinfo.local_addresses() + admin_ips():
        try:
            if ipaddress.ip_address(a) in net:
                return True
        except ValueError:
            pass
    return any(net.subnet_of(parse_net(a["ip"], True)) for a in CFG["allow"]
               if ipaddress.ip_network(a["ip"], strict=False).version == net.version)


_admin = {"at": 0, "ips": []}
TRUST_DAYS = 7   # an address that logged in over SSH is trusted this long (whoever logs in is root anyway)


def admin_ips():
    """Never limited or banned: users logged in right now (utmp) and addresses with a successful SSH
    login in the last TRUST_DAYS (scripts and tools that run commands over SSH never show up in utmp)."""
    if time.time() - _admin["at"] > 15:
        now = time.time()
        recent = {ip for ip, t in list(GUARD["recent_ok"].items()) if now - t < TRUST_DAYS * 86400}
        _admin.update(at=now, ips=sorted(set(hostinfo.ssh_sessions()) | recent))
    return _admin["ips"]


def seed_recent_logins():
    """Successful logins already in the log (current and previous file) count as recent."""
    now = time.time()
    for name in ("/var/log/auth.log.1", "/var/log/auth.log"):
        for ip in OK_RE.findall(hostinfo.read(name, 50_000_000) or ""):
            try:
                ipaddress.ip_address(ip)
            except ValueError:
                continue
            GUARD["recent_ok"][ip] = now


# ------------------------------------------------------------------ bans

def ban(ip, minutes, reason, source):
    net = parse_net(ip)
    if net.num_addresses > 1:
        raise ValueError("Temporary bans are for single addresses; use the blocklist for networks")
    addr = str(net.network_address)
    if own_or_admin(addr):
        raise ValueError(f"{addr} is this server, a logged-in user or on the allowlist; it is never banned")
    if not STATE["applied"]:
        raise ValueError("Turn protection on first")
    name = "ban4" if net.version == 4 else "ban6"
    nft(["add", "element", "inet", "defender", name, f"{{ {addr} timeout {int(minutes)}m }}"])
    with LOCK:
        BANS[addr] = {"until": time.time() + minutes * 60, "reason": reason, "source": source}
        save_json("bans.json", BANS)
    return addr


def unban(ip):
    addr = str(parse_net(ip).network_address)
    if table_exists():
        name = "ban4" if ":" not in addr else "ban6"
        nft(["delete", "element", "inet", "defender", name, f"{{ {addr} }}"], check=False)
    with LOCK:
        BANS.pop(addr, None)
        save_json("bans.json", BANS)
    event("unban", ip=addr)


def ban_list():
    now = time.time()
    rows = []
    for name, items in current_bans().items():
        for ip, left in items:
            meta = BANS.get(ip, {})
            rows.append({"ip": ip, "left": int(left), "source": meta.get("source", "auto"), "reason": meta.get("reason", "rate")})
    with LOCK:   # forget metadata of bans that ended
        live = {r["ip"] for r in rows}
        for ip in [k for k, v in BANS.items() if v["until"] < now or (STATE["applied"] and ip not in live and v["until"] - now < 5)]:
            BANS.pop(ip, None)
    try:
        f2b_rows = f2b.all_bans()
        for r in f2b_rows:
            rows.append({"ip": r["ip"], "left": int(r["until"] - now) if r["until"] else None, "source": "fail2ban", "reason": r["jail"], "jail": r["jail"]})
    except Exception:
        f2b_rows = None
    if f2b_rows is None:
        for ip in hostinfo.fail2ban_bans():
            rows.append({"ip": ip, "left": None, "source": "fail2ban", "reason": "fail2ban"})
    return sorted(rows, key=lambda r: (r["source"] == "fail2ban", -(r["left"] or 0)))


# ------------------------------------------------------------------ SSH guard (auth.log)

IP = r"([0-9a-fA-F:.]+)"
FAIL_RE = re.compile("|".join([
    rf"Failed (?:password|publickey|none) for (?:invalid user )?\S+ from {IP}",
    rf"Invalid user \S* ?from {IP}",
    rf"maximum authentication attempts exceeded for (?:invalid user )?\S+ from {IP}",
    rf"(?:Connection closed by|Disconnected from) (?:authenticating|invalid) user \S* ?{IP} port \d+ \[preauth\]",
    rf"Did not receive identification string from {IP}",
    rf"banner exchange: Connection from {IP} port \d+: invalid format",
]))
OK_RE = re.compile(r"Accepted \S+ for \S+ from ([0-9a-fA-F:.]+)")
GUARD = {"failures": collections.defaultdict(collections.deque), "seen_24h": collections.deque(maxlen=200000),
         "available": False, "recent_ok": {}}


def ssh_guard_loop():
    path = hostinfo.host_path("/var/log/auth.log")
    f, inode = None, None
    while True:
        try:
            st = os.stat(path)
            if f is None or st.st_ino != inode or st.st_size < f.tell():
                if f:
                    f.close()
                f = open(path, errors="replace")
                if inode is None:
                    f.seek(0, os.SEEK_END)     # first start: only new lines count
                inode = st.st_ino
                GUARD["available"] = True
            for line in f.readlines():
                ssh_line(line)
        except OSError:
            GUARD["available"] = False
            f, inode = None, None
        time.sleep(1)


def ssh_line(line):
    m = OK_RE.search(line)
    if m:
        GUARD["recent_ok"][m.group(1)] = time.time()
        GUARD["failures"].pop(m.group(1), None)
        return
    m = FAIL_RE.search(line)
    if not m:
        return
    ip = next(g for g in m.groups() if g)
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return
    now = time.time()
    GUARD["seen_24h"].append((now, ip))
    g = CFG["ssh_guard"]
    if not g["enabled"] or not STATE["applied"]:
        return
    if g.get("exempt_private") and (addr.is_private or addr in ipaddress.ip_network("100.64.0.0/10")):
        return
    if now - GUARD["recent_ok"].get(ip, 0) < 86400:
        return   # logged in successfully from here today: a typo is not an attack
    q = GUARD["failures"][ip]
    q.append(now)
    while q and now - q[0] > g["window"] * 60:
        q.popleft()
    if len(q) >= g["failures"]:
        GUARD["failures"].pop(ip, None)
        try:
            ban(ip, g["ban"], "ssh", "ssh")
            event("ssh_ban", ip=ip, failures=len(q), minutes=g["ban"])
        except Exception as e:
            log("ssh guard: cannot ban", ip, e)


def ssh_stats():
    now = time.time()
    per = collections.Counter(ip for t, ip in GUARD["seen_24h"] if now - t < 86400)
    return {"available": GUARD["available"], "failures_24h": sum(per.values()),
            "top": [{"ip": ip, "n": n} for ip, n in per.most_common(10)]}


# ------------------------------------------------------------------ live statistics and attack detection

DROP_KEYS = ("block", "ban", "geo", "invalid", "badflags", "ssh", "policy", "syn", "conn", "conc", "udp", "icmp", "autoban")


def read_counters():
    if not STATE["applied"]:
        return {}
    try:
        data = json.loads(nft(["-j", "list", "counters", "table", "inet", "defender"]))
    except (RuntimeError, ValueError):
        return {}
    out = {}
    for item in data.get("nftables", []):
        c = item.get("counter")
        if c and c.get("name", "").startswith("c_"):
            out[c["name"][2:]] = c.get("packets", 0)
    return out


def stats_loop():
    prev, prev_t = None, None
    calm, hot, base = 0, 0, None
    last_bans = 0
    iface = hostinfo.public_iface()
    while True:
        t0 = time.time()
        try:
            cur = {"c": read_counters(), "dev": hostinfo.iface_counters(iface) if iface else None, "tcp": hostinfo.tcp_counters()}
            if prev:
                dt = max(0.2, t0 - prev_t)
                rate = lambda a, b: max(0, (a - b) / dt) if a is not None and b is not None else None
                drops = {k: rate(cur["c"].get(k), prev["c"].get(k)) or 0 for k in DROP_KEYS} if cur["c"] and prev["c"] else {}
                ct = hostinfo.conntrack_usage()
                s = {
                    "t": round(t0, 2),
                    "pps": rate((cur["dev"] or {}).get("rx_packets"), (prev["dev"] or {}).get("rx_packets")),
                    "bps": rate((cur["dev"] or {}).get("rx_bytes"), (prev["dev"] or {}).get("rx_bytes")),
                    "conns": rate(cur["tcp"]["passive_opens"], prev["tcp"]["passive_opens"]),
                    "cookies": rate(cur["tcp"]["syncookies_sent"], prev["tcp"]["syncookies_sent"]),
                    "new": rate(cur["c"].get("new"), prev["c"].get("new")) if cur["c"] and prev["c"] else None,
                    "drop": sum(drops.values()) if drops else 0,
                    "drops": {k: round(v, 1) for k, v in drops.items() if v},
                    "ct": round(ct["count"] / ct["max"] * 100, 1) if ct else None,
                    "estab": cur["tcp"]["curr_estab"],
                }
                if t0 - last_bans > 5:
                    last_bans = t0
                    STATE["bans_count"] = sum(len(v) for v in current_bans().values())
                s["bans"] = STATE["bans_count"]
                STATE["samples"].append(s)
                # attack detection with hysteresis
                pps = s["pps"] or 0
                if base is None:
                    base = pps
                signals = []
                if s["drop"] > ADV("detect_drops"):
                    signals.append("drops")
                if (s["cookies"] or 0) > ADV("detect_cookies"):
                    signals.append("syn_flood")
                if pps > ADV("detect_pps") and pps > 6 * max(base, 1000):
                    signals.append("traffic")
                if (s["ct"] or 0) > ADV("detect_conntrack"):
                    signals.append("conntrack")
                att = STATE["attack"]
                if signals:
                    hot, calm = hot + 1, 0
                else:
                    calm, hot = calm + 1, 0
                    base = base * 0.995 + pps * 0.005
                if att["active"]:
                    for k in ("pps", "drop", "conns", "cookies"):
                        att["peak"][k] = max(att["peak"].get(k, 0), s.get(k) or 0)
                if not att["active"] and hot >= 3:
                    att.update(active=True, since=t0, peak={k: s.get(k) or 0 for k in ("pps", "drop", "conns", "cookies")}, reason=",".join(signals))
                    event("attack_start", reason=att["reason"], pps=round(pps), drop=round(s["drop"]),
                          top=[r["ip"] for r in hostinfo.top_sources(5, 0)])
                    if CFG["auto_escalate"] and CFG["enabled"] and CFG["profile"] != "attack" and not STATE["escalated"]:
                        STATE.update(escalated=True, escalated_at=t0)
                        try:
                            apply()
                            event("escalate")
                        except Exception as e:
                            STATE["escalated"] = False
                            log("escalate failed", e)
                elif att["active"] and calm >= ADV("calm_seconds"):
                    att.update(active=False, ended=t0)
                    event("attack_end", seconds=round(t0 - att["since"]), peak={k: round(v) for k, v in att["peak"].items()})
                if STATE["escalated"] and not att["active"] and t0 - att["ended"] > ADV("deescalate_minutes") * 60:
                    STATE["escalated"] = False
                    try:
                        apply()
                        event("deescalate")
                    except Exception as e:
                        log("de-escalate failed", e)
            prev, prev_t = cur, t0
            p = STATE["pending"]
            if p and time.time() > p["until"]:
                rollback("timeout")
        except Exception as e:  # never let the loop die
            log("stats error", type(e).__name__, e)
        time.sleep(max(0.05, 1 - (time.time() - t0)))


def admin_refresh_loop():
    """Logged-in users' IPs are part of the allowlist in the kernel; refresh it when they change."""
    last = None
    while True:
        time.sleep(20)
        try:
            ips = tuple(admin_ips()) if CFG.get("trust_logged_in", True) else ()
            if ips != last and last is not None and STATE["applied"] and not STATE["pending"]:
                apply()
            last = ips
        except Exception as e:
            log("admin refresh", e)


# ------------------------------------------------------------------ status for the panel

def status():
    with LOCK:
        p = STATE["pending"]
        return {
            "version": VERSION, "enabled": CFG["enabled"], "applied": STATE["applied"], "error": STATE["error"],
            "pending": {"left": max(0, round(p["until"] - time.time())), "what": p["what"]} if p else None,
            "profile": CFG["profile"], "escalated": STATE["escalated"], "limits": CFG["limits"],
            "effective": effective_limits(), "profiles": nftrules.PROFILES,
            "attack": {k: v for k, v in STATE["attack"].items()},
            "config": {k: CFG[k] for k in ("auto_escalate", "ddos", "firewall", "ssh_guard", "trust_logged_in", "trust_cdn", "geo", "notify", "advanced")},
            "allow": CFG["allow"], "block": CFG["block"],
            "ssh_ports": hostinfo.ssh_ports(), "panel_ports": PANEL_PORTS, "admin_ips": admin_ips(),
            "iface": hostinfo.public_iface(), "interfaces": hostinfo.interfaces(),
            "bans": STATE["bans_count"], "fail2ban": hostinfo.fail2ban_present(),
            "last_event": EVENTS[-1]["id"] if EVENTS else 0, "uptime": round(time.time() - STATE["started"]),
        }


def ports_view():
    published = hostinfo.docker_published()
    fw = CFG["firewall"]
    rows = []
    for r in hostinfo.listening():
        if not r["public"]:
            continue
        r = dict(r)
        r["docker"] = (r["proto"], r["port"]) in published or r["process"] == "docker-proxy"
        r["always"] = r["proto"] == "tcp" and (r["port"] in hostinfo.ssh_ports() or r["port"] in PANEL_PORTS)
        r["allowed"] = r["always"] or any(_port_match(p, r) for p in fw["ports"])
        r["restricted"] = not r["allowed"] and any(_port_match(dict(p, **{"from": ""}), r) for p in fw["ports"] if p.get("from"))
        rows.append(r)
    for proto, port in sorted(published):
        if not any(r["proto"] == proto and r["port"] == port for r in rows):
            rows.append({"proto": proto, "port": port, "addrs": [], "public": True, "process": "docker", "docker": True,
                         "always": port in PANEL_PORTS and proto == "tcp",
                         "allowed": any(_port_match(p, {"proto": proto, "port": port}) for p in fw["ports"])})
    return {"rows": rows}


def _port_match(p, r):
    if p["proto"] not in (r["proto"], "both") or p.get("from"):
        return False
    a, _, b = p["port"].partition("-")
    return int(a) <= r["port"] <= int(b or a)


# ------------------------------------------------------------------ API over the unix socket

def _cfg_patch(body):
    """Only known keys can be changed from the panel."""
    def mut(c):
        for k in ("enabled", "auto_escalate", "trust_logged_in", "trust_cdn"):
            if k in body:
                c[k] = bool(body[k])
        if "profile" in body:
            c["profile"] = str(body["profile"])
            if c["profile"] in nftrules.PROFILES:
                c["limits"] = dict(nftrules.PROFILES[c["profile"]])
        if "limits" in body:
            c["limits"] = {k: body["limits"].get(k, c["limits"][k]) for k in nftrules.LIMIT_KEYS}
            c["profile"] = next((n for n, v in nftrules.PROFILES.items() if v == c["limits"]), "custom")
        if "ddos" in body:
            c["ddos"].update({k: bool(body["ddos"][k]) for k in ("drop_invalid", "bad_flags") if k in body["ddos"]})
        if "firewall" in body:
            fw = body["firewall"]
            if "mode" in fw:
                c["firewall"]["mode"] = str(fw["mode"])
            if "ports" in fw:
                c["firewall"]["ports"] = [{"proto": str(p.get("proto", "tcp")), "port": str(p.get("port", "")),
                                           "from": str(p.get("from") or ""), "note": str(p.get("note") or "")} for p in fw["ports"]]
            if "trusted_ifaces" in fw:
                c["firewall"]["trusted_ifaces"] = [str(i).strip() for i in fw["trusted_ifaces"] if str(i).strip()]
        if "ssh_guard" in body:
            g = body["ssh_guard"]
            for k in ("enabled", "l4", "exempt_private"):
                if k in g:
                    c["ssh_guard"][k] = bool(g[k])
            for k in ("failures", "window", "ban"):
                if k in g:
                    c["ssh_guard"][k] = g[k]
        if "notify" in body:
            c["notify"].update({k: bool(v) for k, v in body["notify"].items() if k in ("attacks", "bans")})
        if isinstance(body.get("advanced"), dict):
            for k, v in body["advanced"].items():
                if k in DEFAULT["advanced"]:
                    c["advanced"][k] = v
        if "geo" in body and isinstance(body["geo"], dict) and "block" in body["geo"]:
            c["geo"]["block"] = [str(x) for x in body["geo"]["block"]][:200]
    return mut


def api_list_add(body, lst):
    net = parse_net(body.get("ip", ""), allow_any=(lst == "allow"))
    if lst == "block" and own_or_admin(net_str(net)):
        raise ValueError(f"{net_str(net)} includes this server, a logged-in user or an allowlisted address")
    minutes = body.get("minutes")
    if lst == "block" and minutes:
        addr = ban(net_str(net), int(minutes), str(body.get("note", "")) or "manual", "manual")
        event("ban", ip=addr, minutes=int(minutes))
        return status()

    def mut(c):
        c[lst] = [e for e in c[lst] if e["ip"] != net_str(net)] + [{"ip": net_str(net), "note": str(body.get("note", ""))[:80], "added": int(time.time())}]
    out = change(mut, rollback=False, what=lst)
    event("block" if lst == "block" else "allow", ip=net_str(net))
    return out


def api_list_remove(body, lst):
    ip = net_str(parse_net(body.get("ip", ""), allow_any=True))
    out = change(lambda c: c.__setitem__(lst, [e for e in c[lst] if e["ip"] != ip]), rollback=False, what=lst)
    if lst == "block" and "/" not in ip:
        unban(ip)
    return out


def api_sysctl(body):
    keys = [k for k, _, _ in hostinfo.SYSCTLS]
    want = [k for k in body.get("keys", keys) if k in keys]
    rec = {k: r for k, r, _ in hostinfo.SYSCTLS}
    with LOCK:
        sc = CFG["sysctl"]
        if body.get("action") in ("custom_set", "custom_del"):
            key = str(body.get("key", "")).strip()
            if not re.match(r"^(net|kernel|vm|fs)\.[A-Za-z0-9_.\-]{1,120}$", key) or ".." in key or not os.path.exists("/proc/sys/" + key.replace(".", "/")):
                raise ValueError(f"Unknown kernel setting: {key}")
            custom = sc.setdefault("custom", {})
            if body["action"] == "custom_set":
                value = str(body.get("value", "")).strip()
                if not value or len(value) > 200 or "\n" in value:
                    raise ValueError("Invalid value")
                sc["original"].setdefault(key, hostinfo.sysctl_get(key))
                try:
                    hostinfo.sysctl_set(key, value)
                except OSError as e:
                    raise ValueError(f"{key}: {e}")
                custom[key] = value
            else:
                custom.pop(key, None)
                if sc["original"].get(key) is not None:
                    try:
                        hostinfo.sysctl_set(key, sc["original"][key])
                    except OSError:
                        pass
            event("sysctl", action=body["action"].replace("custom_", "custom "), n=1)
        elif body.get("action") == "restore":
            for k in want:
                if k in sc["original"]:
                    try:
                        hostinfo.sysctl_set(k, sc["original"][k])
                    except OSError as e:
                        raise ValueError(f"{k}: {e}")
                sc["applied"] = [a for a in sc["applied"] if a != k]
            event("sysctl", action="restore", n=len(want))
        else:
            for k in want:
                cur = hostinfo.sysctl_get(k)
                if cur is None:
                    continue
                sc["original"].setdefault(k, cur)
                if not hostinfo.sysctl_ok(k, cur, rec[k]):
                    try:
                        hostinfo.sysctl_set(k, rec[k])
                    except OSError as e:
                        raise ValueError(f"{k}: {e}")
                if k not in sc["applied"]:
                    sc["applied"].append(k)
            event("sysctl", action="apply", n=len(want))
        save_json("config.json", CFG)
    return {"rows": hostinfo.sysctl_report(), "applied": CFG["sysctl"]["applied"], "custom": CFG["sysctl"].get("custom", {})}


def reapply_sysctl():
    for k, v in (CFG["sysctl"].get("custom") or {}).items():
        try:
            hostinfo.sysctl_set(k, v)
        except OSError as e:
            log("sysctl", k, e)
    rec = {k: r for k, r, _ in hostinfo.SYSCTLS}
    for k in CFG["sysctl"]["applied"]:
        try:
            if not hostinfo.sysctl_ok(k, hostinfo.sysctl_get(k), rec[k]):
                hostinfo.sysctl_set(k, rec[k])
        except (OSError, KeyError) as e:
            log("sysctl", k, e)


def api_audit():
    checks = hostinfo.audit({"enabled": STATE["applied"], "mode": CFG["firewall"]["mode"]})
    for c in checks:   # fail2ban: installed but stopped is worse than not installed (it looks like protection)
        if c["id"] == "fail2ban" and f2b.installed() and not f2b.running():
            c.update(id="fail2ban_stopped", sev=2)
    return {"checks": checks, "score": hostinfo.score(checks), "sysctl": hostinfo.sysctl_report(),
            "sysctl_applied": CFG["sysctl"]["applied"], "sysctl_custom": CFG["sysctl"].get("custom", {})}


def api_live(q):
    since = float(q.get("since", 0) or 0)
    return {"samples": [s for s in STATE["samples"] if s["t"] > since], "attack": STATE["attack"],
            "escalated": STATE["escalated"], "applied": STATE["applied"], "bans": STATE["bans_count"],
            "pending": status()["pending"]}


# ------------------------------------------------------------------ fail2ban, countries, backup

def f2b_view(force=False):
    return {**f2b.overview(F2B, force), "admin_ips": admin_ips()}


def f2b_jail_name(name, must_run=False):
    name = str(name or "")
    if not f2b.NAME_RE.match(name):
        raise ValueError("invalid jail name")
    running = f2b.jail_names() if f2b.running() else []
    if must_run and name not in running:
        raise ValueError(f"The jail {name} is not running")
    if name not in running and name not in f2b.PRESETS and name not in F2B["jails"] and not f2b.jail_config(name)[1]:
        raise ValueError(f"Unknown jail: {name}")
    return name


def f2b_save(mutate, what):
    global F2B
    with LOCK:
        new = copy.deepcopy(F2B)
        mutate(new)
        f2b.validate(new)
        if not f2b.installed():
            raise ValueError("fail2ban is not installed")
        f2b.write_settings(new)
        F2B = new
        save_json("f2b.json", F2B)
    event("f2b_config", what=what)
    return f2b_view(force=True)


def api_f2b_jail(b):
    name = str(b.get("name") or "").strip()
    if b.get("create"):
        if not f2b.NAME_RE.match(name) or name.upper() == "DEFAULT":
            raise ValueError("Jail names use letters, digits, - _ . (up to 40)")
        if name in (f2b.jail_names() if f2b.running() else []) or name in F2B["jails"] or f2b.jail_config(name)[1]:
            raise ValueError(f"A jail named {name} already exists")
    else:
        name = f2b_jail_name(name)
    upd = {k: b[k] for k in f2b.JAIL_KEYS + ("extra",) if k in b}

    def mut(m):
        if b.get("replace") or b.get("create"):
            m["jails"][name] = upd
        else:
            m["jails"].setdefault(name, {}).update(upd)
    return f2b_save(mut, f"{'new ' if b.get('create') else ''}jail {name}")


def api_f2b_jail_delete(b):
    global F2B
    name = f2b_jail_name(b.get("name"))
    with LOCK:
        new = copy.deepcopy(F2B)
        res = f2b.delete_jail(name, new)
        F2B = new
        save_json("f2b.json", F2B)
    event("f2b_config", what=f"deleted jail {name}")
    return {**f2b_view(force=True), **res}


def api_f2b_defaults(b):
    upd = {k: b[k] for k in f2b.DEFAULT_KEYS if k in b}
    return f2b_save(lambda m: m["default"].update(upd), "defaults")


def api_f2b_ban(b):
    name = f2b_jail_name(b.get("jail"), must_run=True)
    addr = net_str(parse_net(b.get("ip", "")))
    if "/" in addr:
        raise ValueError("fail2ban bans single addresses")
    if own_or_admin(addr):
        raise ValueError(f"{addr} is this server, a logged-in user or on the allowlist; it is never banned")
    f2b.call("set", name, "banip", addr)
    event("f2b_ban", jail=name, ip=addr, manual=True)
    return {"ok": True}


def api_f2b_unban(b):
    addr = net_str(parse_net(b.get("ip", "")))
    if b.get("jail"):
        f2b.call("set", f2b_jail_name(b["jail"], must_run=True), "unbanip", addr)
    else:
        f2b.call("unban", addr)
    event("f2b_unban", ip=addr, jail=b.get("jail") or "")
    return {"ok": True}


def api_f2b_service(b):
    action = str(b.get("action", ""))
    f2b.service(action)
    event("f2b_service", action=action)
    time.sleep(1.5 if action in ("start", "restart") else 0)
    return f2b_view(force=True)


def api_f2b_install(b):
    job = f2b.install()
    event("f2b_service", action="install")
    return {"job": job}


def api_f2b_uninstall(b):
    job = f2b.uninstall(bool(b.get("purge")))
    event("f2b_service", action="purge" if b.get("purge") else "uninstall")
    return {"job": job}


def api_f2b_file_save(b):
    out = f2b.file_write(b.get("path"), b.get("text", ""))
    event("f2b_config", what=f"file {out['path']}")
    return out


def api_f2b_file_delete(b):
    out = f2b.file_delete(b.get("path"))
    event("f2b_config", what=f"deleted {b.get('path')}")
    return out


def api_f2b_bans(q):
    return {"rows": f2b.jail_bans(f2b_jail_name(q.get("jail"), must_run=True))}


def api_geo(q):
    return {"block": CFG["geo"]["block"], "info": geo.info(DATA, CFG["geo"]["block"])}


def geo_refresh_loop():
    """Country lists change slowly; refresh them weekly and re-apply when one changed."""
    while True:
        time.sleep(6 * 3600)
        try:
            codes = CFG["geo"]["block"]
            if not codes or not CFG["enabled"]:
                continue
            before = geo.info(DATA, codes)
            geo.build(DATA, codes, download=True)
            if geo.info(DATA, codes) != before and not STATE["pending"]:
                apply()
        except Exception as e:
            log("geo refresh", e)


EXPORT_KEYS = ("enabled", "profile", "limits", "auto_escalate", "ddos", "firewall", "allow", "block", "ssh_guard",
               "trust_logged_in", "trust_cdn", "geo", "notify", "advanced")


def api_export(q):
    return {"app": "server-monitor-firewall", "version": 1, "exported": int(time.time()),
            "config": {k: CFG[k] for k in EXPORT_KEYS}, "fail2ban": F2B}


def api_import(b):
    data = b.get("data") or {}
    if data.get("app") != "server-monitor-firewall" or not isinstance(data.get("config"), dict):
        raise ValueError("This is not a firewall backup file")
    incoming = data["config"]

    def mut(c):
        for k in EXPORT_KEYS:
            if k in incoming:
                if isinstance(c.get(k), dict) and isinstance(incoming[k], dict):
                    c[k] = {**c[k], **incoming[k]}
                else:
                    c[k] = incoming[k]
    out = change(mut, rollback=True, what="import")
    if isinstance(data.get("fail2ban"), dict) and f2b.installed():
        try:
            f2b_save(lambda m: m.update({"default": data["fail2ban"].get("default", {}), "jails": data["fail2ban"].get("jails", {})}), "import")
        except ValueError as e:
            out = dict(out, warning=f"fail2ban settings not imported: {e}")
    return out


def on_f2b_ban(jail, ip):
    event("f2b_ban", jail=jail, ip=ip)


GET = {
    "/status": lambda q: status(),
    "/live": api_live,
    "/bans": lambda q: {"rows": ban_list(), "block": CFG["block"], "allow": CFG["allow"], "admin_ips": admin_ips()},
    "/ports": lambda q: ports_view(),
    "/audit": lambda q: api_audit(),
    "/talkers": lambda q: {"rows": hostinfo.top_sources()},
    "/events": lambda q: {"rows": [e for e in EVENTS if e["id"] > int(q.get("since", 0) or 0)][-200:]},
    "/rules": lambda q: {"text": ruleset() if CFG["enabled"] else ruleset(dict(CFG, enabled=True))},
    "/ssh": lambda q: {**ssh_stats(), "config": CFG["ssh_guard"], "fail2ban": hostinfo.fail2ban_present()},
    "/f2b": lambda q: f2b_view(),
    "/f2b/bans": api_f2b_bans,
    "/f2b/log": lambda q: {"text": f2b.log_tail()},
    "/f2b/jail": lambda q: f2b.jail_detail(f2b_jail_name(q.get("jail")), F2B),
    "/f2b/files": lambda q: {"rows": f2b.files(), "backups": f2b.BACKUPS},
    "/f2b/file": lambda q: f2b.file_read(q.get("path")),
    "/geo": api_geo,
    "/export": api_export,
}
POST = {
    "/config": lambda b: change(_cfg_patch(b), rollback=bool(b.get("_rollback", True)), what=str(b.get("_what", "config"))[:40]),
    "/confirm": lambda b: confirm(),
    "/revert": lambda b: rollback("manual"),
    "/block": lambda b: api_list_add(b, "block"),
    "/unblock": lambda b: api_list_remove(b, "block"),
    "/allow": lambda b: api_list_add(b, "allow"),
    "/unallow": lambda b: api_list_remove(b, "allow"),
    "/unban": lambda b: (unban(b.get("ip", "")), status())[1],
    "/sysctl": api_sysctl,
    "/f2b/service": api_f2b_service,
    "/f2b/install": api_f2b_install,
    "/f2b/uninstall": api_f2b_uninstall,
    "/f2b/jail": api_f2b_jail,
    "/f2b/jail/delete": api_f2b_jail_delete,
    "/f2b/file": api_f2b_file_save,
    "/f2b/file/delete": api_f2b_file_delete,
    "/f2b/defaults": api_f2b_defaults,
    "/f2b/ban": api_f2b_ban,
    "/f2b/unban": api_f2b_unban,
    "/import": api_import,
}


class Handler(BaseHTTPRequestHandler):
    server_version = "defender"

    def log_message(self, fmt, *args):
        pass

    def address_string(self):
        return "panel"

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _route(self, table, arg):
        path = self.path.split("?", 1)[0]
        fn = table.get(path)
        if not fn:
            return self._send(404, {"error": "not found"})
        try:
            return self._send(200, fn(arg))
        except ValueError as e:
            return self._send(400, {"error": str(e)})
        except Exception as e:
            log("api error", path, type(e).__name__, e)
            return self._send(500, {"error": f"{type(e).__name__}: {e}"})

    def do_GET(self):
        q = {}
        if "?" in self.path:
            for part in self.path.split("?", 1)[1].split("&"):
                k, _, v = part.partition("=")
                q[k] = unquote(v)
        self._route(GET, q)

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(min(n, 1_000_000)) or b"{}")
            if not isinstance(body, dict):
                raise ValueError
        except ValueError:
            return self._send(400, {"error": "bad request"})
        self._route(POST, body)


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def main():
    os.makedirs(DATA, exist_ok=True)
    os.chmod(DATA, 0o711)
    try:
        os.unlink(SOCK)
    except FileNotFoundError:
        pass
    srv = Server(SOCK, Handler)
    os.chown(SOCK, 0, PANEL_GID)
    os.chmod(SOCK, 0o660)
    reapply_sysctl()
    seed_recent_logins()
    try:
        apply()
        if CFG["enabled"]:
            event("started", protection="on")
    except Exception as e:
        STATE["error"] = str(e)
        log("cannot apply rules:", e)
    for target in (stats_loop, ssh_guard_loop, admin_refresh_loop, geo_refresh_loop):
        threading.Thread(target=target, daemon=True).start()
    threading.Thread(target=f2b.watch_log, args=(on_f2b_ban,), daemon=True).start()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))   # the rules stay in the kernel while the agent restarts
    log(f"defender {VERSION} ready on {SOCK}; protection {'on' if CFG['enabled'] else 'off'}, "
        f"ssh ports {hostinfo.ssh_ports()}, panel ports {PANEL_PORTS}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
