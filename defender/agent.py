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
import concurrent.futures
import copy
import ipaddress
import json
import os
import re
import signal
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
import nftlib  # noqa: E402
import nftrules  # noqa: E402
import sshmgr  # noqa: E402
import sysfw  # noqa: E402
import threat  # noqa: E402

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
    "geo": {"block": []},     # replaced by "rules" (kept so old backups still import)
    "rules": [],              # user firewall rules, see validate_rule
    # threat-intelligence blocklists: the ones that are on, per list "block" (default) or "log" (only count),
    # also block this server connecting to them, the user's own lists, and how often to refresh them
    "threat": {"feeds": [], "mode": {}, "outbound": False, "custom": [], "refresh_hours": 12},
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
if CFG["geo"].get("block") and not CFG["rules"]:    # the old country blocklist becomes a rule
    CFG["rules"] = [{"id": "c0untr", "name": "Blocked countries", "enabled": True, "countries": list(CFG["geo"]["block"]),
                     "country_mode": "in", "ips": [], "ip_mode": "in", "proto": "any", "ports": "", "action": "block",
                     "limit": {"rate": 10, "burst": 20, "ban": 0}}]
    CFG["geo"]["block"] = []
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
        EVENTS.append({**data, "id": eid, "t": round(time.time(), 1), "kind": kind})   # data can never replace id/t/kind
        save_json("events.json", list(EVENTS))
    log("event", kind, data)


# ------------------------------------------------------------------ nft

def nft(args, stdin=None, check=True):
    """Runs an nft command. Simple commands (lists, adding and removing set elements) go through
    libnftables in this process; loading a whole ruleset (-f, -c) still uses the nft program."""
    if stdin is None and not any(a.startswith("-") for a in args[1:]) and (not args[0].startswith("-") or args[0] == "-j"):
        json_out = args[0] == "-j"
        res = nftlib.run(" ".join(args[1:] if json_out else args), json_out)
        if res is not None:
            ok, out, err = res
            if check and not ok:
                raise RuntimeError(err.strip()[-800:] or "nft command failed")
            return out
    p = subprocess.run(["nft"] + args, input=stdin, capture_output=True, text=True, timeout=20)
    if check and p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout).strip()[-800:] or f"nft exited with {p.returncode}")
    return p.stdout


def table_exists():
    """Only the table names: listing the table itself would print every element of the big sets."""
    try:
        return "table inet defender" in nft(["list", "tables", "inet"])
    except RuntimeError:
        return False


def current_bans(cfg=None):
    """Elements of every ban set: {set name: [(ip, whole ban seconds, seconds left)]}, so a rebuild of
    the table keeps them (with their real ban time) and the panel can show when and why."""
    out = {}
    if not table_exists():
        return out
    names = [f"{k}{v}" for k in nftrules.ban_sets(cfg or CFG) for v in ("4", "6")]
    names += [f"{k}{v}" for k in nftrules.ban_sets(CFG) for v in ("4", "6") if f"{k}{v}" not in names]
    for name in names:
        try:
            data = json.loads(nft(["-j", "list", "set", "inet", "defender", name]))
        except (RuntimeError, ValueError):
            continue
        rows = out.setdefault(name, [])
        for item in data.get("nftables", []):
            default = (item.get("set") or {}).get("timeout", 900)
            for el in (item.get("set") or {}).get("elem", []) or []:
                if isinstance(el, dict) and "elem" in el:
                    e = el["elem"]
                    total = e.get("timeout", default)
                    left = e.get("expires", total)
                    if isinstance(e.get("val"), str) and left and left > 1:
                        rows.append((e["val"], max(total, left), left))
                elif isinstance(el, str):
                    rows.append((el, default, default))
    return out


BAN_REASON = {"ban": None, "fban": "syn_flood", "cban": "conn_flood", "sban": "ssh_rate"}


def ban_kind(set_name):
    """("syn_flood" | "conn_flood" | "ssh_rate" | "rule" | None, rule) for a ban set name."""
    base = set_name[:-1]
    if base.startswith("rb_"):
        rule = next((r for r in CFG["rules"] if r.get("id") == base[3:]), None)
        return "rule", rule
    return BAN_REASON.get(base), None


def effective_limits():
    return dict(nftrules.PROFILES["attack"]) if STATE["escalated"] else dict(CFG["limits"])


def ruleset(cfg=None):
    cfg = cfg or CFG
    allow_extra = [{"ip": ip} for ip in admin_ips()] if cfg.get("trust_logged_in", True) else []
    view = dict(cfg, allow=cfg["allow"] + allow_extra)
    g4, g6, _ = geo.build(DATA, cfg.get("geo", {}).get("block", []), download=False)
    zones = {}
    for rule in cfg.get("rules") or []:
        if rule.get("enabled", True) and rule.get("countries"):
            z4, z6, _ = geo.build(DATA, rule["countries"], download=False)
            zones[rule["id"]] = (z4, z6)
    return nftrules.build(view, effective_limits(), current_bans(cfg), hostinfo.ssh_ports(), PANEL_PORTS, g4, g6, zones,
                          threat_lists(cfg), hostinfo.public_iface())


def threat_feeds(cfg=None):
    return threat.all_feeds((cfg or CFG)["threat"].get("custom"))


def threat_lists(cfg):
    """[(id, v4, v6, mode)] for the lists that are on and downloaded."""
    t = cfg.get("threat") or {}
    out = []
    for fid, (v4, v6) in threat.lists(DATA, t.get("feeds") or []).items():
        if v4 or v6:
            out.append((fid, v4, v6, (t.get("mode") or {}).get(fid, "block")))
    return out


def threat_download(cfg, force=False, only=None):
    """Downloads the lists that are on (when old, or force); returns the ids whose content changed."""
    feeds = threat.all_feeds(cfg["threat"].get("custom"))
    max_age = int(cfg["threat"].get("refresh_hours", 12)) * 3600
    todo = [f for f in cfg["threat"]["feeds"] if f in feeds and (only is None or f in only)]

    def one(fid):
        try:
            return fid if threat.fetch(DATA, fid, feeds[fid], max_age, force=force) else None
        except ValueError as e:     # one list down must not stop the others; the error shows on its card
            log("threat list", fid, e)
            return None
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:    # a slow server does not hold up the rest
        return [fid for fid in pool.map(one, todo) if fid]


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
        if new["enabled"]:
            codes = set(new["geo"]["block"])
            for rule in new["rules"]:
                if rule.get("enabled", True):
                    codes.update(rule.get("countries") or [])
            if codes:
                geo.build(DATA, sorted(codes), download=True)   # raises before anything changes
            if new["threat"]["feeds"]:
                threat_download(new)          # only lists that are missing or old; raises if a new one cannot be had
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
    validate_threat(cfg["threat"])
    rules = cfg.get("rules") or []
    if not isinstance(rules, list) or len(rules) > 300:
        raise ValueError("At most 300 rules")
    seen_ids = set()
    for i, rule in enumerate(rules):
        rules[i] = validate_rule(rule)
        if rules[i]["id"] in seen_ids:
            rules[i]["id"] = __import__("secrets").token_hex(3)
        seen_ids.add(rules[i]["id"])
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


RULE_ID = re.compile(r"^[a-z0-9]{6}$")
PORTS_RE = re.compile(r"^\d{1,5}(-\d{1,5})?$")


def validate_rule(r):
    """A firewall rule: conditions (countries, addresses, protocol, ports; all must match) and one action."""
    if not isinstance(r, dict):
        raise ValueError("invalid rule")
    import secrets as _s
    out = {"id": r.get("id") if RULE_ID.match(str(r.get("id", ""))) else _s.token_hex(3),
           "name": str(r.get("name") or "").strip()[:80] or "Rule", "enabled": bool(r.get("enabled", True))}
    codes = sorted({str(c).strip().lower() for c in r.get("countries") or [] if str(c).strip()})
    if not all(geo.CC_RE.match(c) for c in codes):
        raise ValueError(f"{out['name']}: unknown country code")
    out["countries"] = codes
    out["country_mode"] = "not_in" if r.get("country_mode") == "not_in" else "in"
    out["ips"] = [net_str(parse_net(x, allow_any=True)) for x in (r.get("ips") or []) if str(x).strip()][:20000]
    out["ip_mode"] = "not_in" if r.get("ip_mode") == "not_in" else "in"
    proto = r.get("proto", "any")
    if proto not in ("any", "tcp", "udp", "icmp"):
        raise ValueError(f"{out['name']}: unknown protocol")
    out["proto"] = proto
    ports = [p.strip() for p in str(r.get("ports") or "").replace(" ", "").split(",") if p.strip()]
    for p in ports:
        a, _, b = p.partition("-")
        if not PORTS_RE.match(p) or not 1 <= int(a) <= 65535 or (b and not int(a) < int(b) <= 65535):
            raise ValueError(f"{out['name']}: invalid port {p}")
    if ports and proto == "icmp":
        raise ValueError(f"{out['name']}: ping (ICMP) has no ports")
    out["ports"] = ",".join(ports[:200])
    if not (codes or out["ips"] or out["ports"] or proto != "any"):
        raise ValueError(f"{out['name']}: a rule needs at least one condition (country, address, protocol or port)")
    act = r.get("action", "block")
    if act not in ("allow", "block", "limit", "log"):
        raise ValueError(f"{out['name']}: unknown action")
    out["action"] = act
    out["direction"] = "out" if r.get("direction") == "out" else "in"
    if out["direction"] == "out" and act == "limit":
        raise ValueError(f"{out['name']}: outgoing rules can allow, block or count, not limit")
    sched = r.get("schedule")
    if sched:
        days = sorted({int(d) for d in sched.get("days") or [] if str(d).isdigit() and 0 <= int(d) <= 6})
        frm, to = str(sched.get("from", "00:00")), str(sched.get("to", "23:59"))
        if not days or not re.match(r"^([01]\d|2[0-3]):[0-5]\d$", frm) or not re.match(r"^([01]\d|2[0-3]):[0-5]\d$", to) or frm == to:
            raise ValueError(f"{out['name']}: pick days and two different times (HH:MM)")
        out["schedule"] = {"days": days, "from": frm, "to": to}
    else:
        out["schedule"] = None
    try:
        out["expires"] = max(0, int(r.get("expires") or 0))
    except (TypeError, ValueError):
        raise ValueError(f"{out['name']}: invalid expiry")
    lim = r.get("limit") or {}
    try:
        rate, burst, ban = int(lim.get("rate", 10)), int(lim.get("burst", 0) or 0), int(lim.get("ban", 0) or 0)
    except (TypeError, ValueError):
        raise ValueError(f"{out['name']}: invalid limit")
    if not 1 <= rate <= 1_000_000 or not 0 <= ban <= 525600:
        raise ValueError(f"{out['name']}: the limit must be 1 to 1000000 per second, the ban 0 to 525600 minutes")
    out["limit"] = {"rate": rate, "burst": max(1, min(burst or rate * 2, 10_000_000)), "ban": ban}
    return out


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

def ban(ip, minutes, reason, source, detail=""):
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
        BANS[addr] = {"at": time.time(), "until": time.time() + minutes * 60, "reason": reason, "source": source, "detail": detail}
        save_json("bans.json", BANS)
    return addr


def unban(ip):
    addr = str(parse_net(ip).network_address)
    if table_exists():        # whatever banned it: every ban set of its family
        v = "6" if ":" in addr else "4"
        for kind in nftrules.ban_sets(CFG):
            nft(["delete", "element", "inet", "defender", f"{kind}{v}", f"{{ {addr} }}"], check=False)
    with LOCK:
        BANS.pop(addr, None)
        save_json("bans.json", BANS)
    event("unban", ip=addr)


def ban_list():
    now = time.time()
    rows = []
    for name, items in current_bans().items():
        kind, rule = ban_kind(name)
        for ip, total, left in items:
            meta = BANS.get(ip, {}) if kind is None else {}
            rows.append({"ip": ip, "left": int(left), "total": int(total), "at": round(now - (total - left)), "detail": meta.get("detail", ""),
                         "source": meta.get("source", "auto") if kind is None else "auto",
                         "reason": meta.get("reason", "rate") if kind is None else kind,
                         **({"rule": rule["name"] if rule else "?"} if kind == "rule" else {})})
    with LOCK:   # forget metadata of bans that ended
        live = {r["ip"] for r in rows}
        ended = [k for k, v in BANS.items() if v["until"] < now or (STATE["applied"] and k not in live and v["until"] - now < 5)]
        for k in ended:
            BANS.pop(k, None)
        if ended:
            save_json("bans.json", BANS)
    try:
        f2b_rows = f2b.all_bans()
        for r in f2b_rows:
            rows.append({"ip": r["ip"], "left": int(r["until"] - now) if r["until"] else None, "at": r.get("at"),
                         "source": "fail2ban", "reason": r["jail"], "jail": r["jail"]})
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
            ban(ip, g["ban"], "ssh", "ssh", detail=f"{len(q)}/{g['window']}")
            event("ssh_ban", ip=ip, failures=len(q), minutes=g["ban"])
        except Exception as e:
            log("ssh guard: cannot ban", ip, e)


def ssh_stats():
    now = time.time()
    per = collections.Counter(ip for t, ip in GUARD["seen_24h"] if now - t < 86400)
    return {"available": GUARD["available"], "failures_24h": sum(per.values()),
            "top": [{"ip": ip, "n": n} for ip, n in per.most_common(10)]}


# ------------------------------------------------------------------ live statistics and attack detection

DROP_KEYS = ("block", "ban", "geo", "threat", "invalid", "badflags", "ssh", "policy", "syn", "conn", "conc", "udp", "icmp", "autoban")


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
    mode = CFG["threat"]["mode"]
    out["threat"] = sum(v for k, v in out.items() if k.startswith("t_") and mode.get(k[2:], "block") == "block")
    return out


WATCH_SECONDS = 20     # the firewall page asked for live numbers this recently: sample every second


def stats_loop():
    """Samples traffic and the firewall's counters, and detects attacks. Every second while someone
    watches the firewall page or something looks wrong; every 2 seconds otherwise (half the work)."""
    prev, prev_t = None, None
    calm, hot, base = 0, 0, None
    last_bans = last_expire = 0
    step = 1
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
                if t0 - last_bans > (5 if step == 1 else 30):
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
                    calm, hot = calm + dt, 0
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
            if STATE.get("ssh_pending") and time.time() > STATE["ssh_pending"]["until"]:
                try:
                    ssh_revert("timeout")
                except Exception as e:
                    log("ssh revert", e)
            if t0 - last_expire >= 30:
                last_expire = t0
                expire_rules()
            busy = hot or STATE["attack"]["active"] or STATE["pending"] or STATE.get("ssh_pending")
            step = 1 if busy or t0 - STATE.get("watched", 0) < WATCH_SECONDS else 2
        except Exception as e:  # never let the loop die
            log("stats error", type(e).__name__, e)
        time.sleep(max(0.05, step - (time.time() - t0)))


def expire_rules():
    """Temporary rules switch themselves off when their time is up."""
    now = time.time()
    if not any(r.get("enabled", True) and r.get("expires") and r["expires"] < now for r in CFG["rules"]):
        return
    names = [r["name"] for r in CFG["rules"] if r.get("enabled", True) and r.get("expires") and r["expires"] < now]

    def mut(c):
        for r in c["rules"]:
            if r.get("enabled", True) and r.get("expires") and r["expires"] < now:
                r["enabled"] = False
    try:
        change(mut, rollback=False, what="rules expired")
        event("rule_expired", names=names)
    except Exception as e:
        log("expire rules", e)


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
            "config": {k: CFG[k] for k in ("auto_escalate", "ddos", "firewall", "ssh_guard", "trust_logged_in", "trust_cdn", "geo", "notify", "advanced", "rules", "threat")},
            "allow": CFG["allow"], "block": CFG["block"],
            "ssh_ports": hostinfo.ssh_ports(), "panel_ports": PANEL_PORTS, "admin_ips": admin_ips(),
            "iface": hostinfo.public_iface(), "interfaces": hostinfo.interfaces(),
            "bans": STATE["bans_count"], "fail2ban": hostinfo.fail2ban_present(),
            "last_event": EVENTS[-1]["id"] if EVENTS else 0, "uptime": round(time.time() - STATE["started"]),
        }


_sysfw_cache = {"at": 0, "st": None}


def sysfw_status(fresh=False):
    """The server's own firewall (ufw / firewalld / iptables), cached for 15 s (it runs host commands)."""
    if fresh or not _sysfw_cache["st"] or time.time() - _sysfw_cache["at"] > 15:
        try:
            _sysfw_cache.update(st=sysfw.status(), at=time.time())
        except Exception as e:  # nsenter or a tool missing: show no system firewall rather than failing the page
            log("system firewall:", e)
            _sysfw_cache.update(st={"active": None, "ufw": {"installed": False}, "firewalld": {"installed": False},
                                    "iptables_policy": None, "_input": ""}, at=time.time())
    return _sysfw_cache["st"]


def ports_view():
    sys_st = sysfw_status()
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
        # published Docker ports go around ufw/firewalld (Docker adds its own rules before them)
        r["sys"] = None if r["docker"] else sysfw.port_open(sys_st, r["proto"], r["port"])
        rows.append(r)
    for proto, port in sorted(published):
        if not any(r["proto"] == proto and r["port"] == port for r in rows):
            rows.append({"proto": proto, "port": port, "addrs": [], "public": True, "process": "docker", "docker": True,
                         "always": port in PANEL_PORTS and proto == "tcp",
                         "allowed": any(_port_match(p, {"proto": proto, "port": port}) for p in fw["ports"]), "sys": None})
    return {"rows": rows, "sysfw": {k: v for k, v in sys_st.items() if not k.startswith("_")}}


def api_open_port(b):
    """Opens a port everywhere it can be closed: our firewall (strict mode) and the server's own firewall
    (ufw / firewalld / iptables) - what `ufw allow 8080/tcp` does by hand."""
    port, src = sysfw._check(b.get("port"), b.get("proto", "tcp"), b.get("from", ""))
    src = net_str(parse_net(src, allow_any=True)) if src else ""     # the same spelling the config uses
    proto = b.get("proto", "tcp")
    note = str(b.get("note", ""))[:80]
    done = sysfw.allow(port, proto, src) if b.get("system", True) else {"done": [], "firewall": None}
    _sysfw_cache["at"] = 0

    def mut(c):
        ports = [p for p in c["firewall"]["ports"] if not (str(p["port"]) == port and p["proto"] == proto and p.get("from", "") == src)]
        c["firewall"]["ports"] = ports + [{"port": port, "proto": proto, "from": src, "note": note}]
    if CFG["firewall"]["mode"] == "strict" or src or b.get("ours"):
        change(mut, rollback=False, what=f"open port {port}")
    event("port_opened", port=port, proto=proto, src=src, system=done["firewall"])
    listening = any(r["public"] and (r["proto"] == proto or proto == "both") and _port_match({"proto": r["proto"], "port": port}, r)
                    for r in hostinfo.listening(max_age=0))
    return {**ports_view(), "done": done["done"], "firewall": done["firewall"], "listening": listening}


def api_close_port(b):
    port, src = sysfw._check(b.get("port"), b.get("proto", "tcp"), b.get("from", ""))
    src = net_str(parse_net(src, allow_any=True)) if src else ""     # the same spelling the config uses
    proto = b.get("proto", "tcp")
    done = sysfw.remove(port, proto, src)
    _sysfw_cache["at"] = 0

    def mut(c):
        c["firewall"]["ports"] = [p for p in c["firewall"]["ports"] if not (str(p["port"]) == port and p["proto"] == proto and p.get("from", "") == src)]
    if any(str(p["port"]) == port and p["proto"] == proto and p.get("from", "") == src for p in CFG["firewall"]["ports"]):
        change(mut, rollback=False, what=f"close port {port}")
    event("port_closed", port=port, proto=proto, src=src, system=done["firewall"])
    return {**ports_view(), "done": done["done"], "firewall": done["firewall"]}


def api_ufw(b):
    action = b.get("action")
    if action == "delete":
        sysfw.ufw_delete(str(b.get("text", "")))
    elif action == "enable":
        # everything that is reachable now stays reachable: SSH, the panel and every public port in use
        keep = set(hostinfo.ssh_ports()) | set(PANEL_PORTS)
        rows = [r for r in hostinfo.listening(max_age=0) if r["public"]]
        keep |= {r["port"] for r in rows if r["proto"] == "tcp"}
        sysfw.ufw_enable(sorted(keep))
        for r in rows:
            if r["proto"] == "udp":
                sysfw.allow(str(r["port"]), "udp")
    elif action == "disable":
        sysfw.ufw_disable()
    else:
        raise ValueError("Unknown action")
    _sysfw_cache["at"] = 0
    event("ufw", action=action)
    return ports_view()


def _port_match(p, r):
    if p["proto"] not in (r["proto"], "both") or p.get("from"):
        return False
    a, _, b = p["port"].partition("-")
    return int(a) <= r["port"] <= int(b or a)


# ------------------------------------------------------------------ API over the unix socket

def validate_threat(t):
    custom = []
    for c in (t.get("custom") or [])[:threat.MAX_CUSTOM]:
        cid, url = str(c.get("id", "")), str(c.get("url", "")).strip()
        if not threat.ID_RE.match(cid) or cid in threat.FEEDS or any(x["id"] == cid for x in custom):
            raise ValueError(f"Invalid list id: {cid}")
        if not url.startswith("https://") or len(url) > 400:
            raise ValueError("The list address must start with https://")
        custom.append({"id": cid, "name": str(c.get("name", "")).strip()[:60] or cid, "url": url})
    t["custom"] = custom
    known = threat.all_feeds(custom)
    t["feeds"] = [f for f in dict.fromkeys(t.get("feeds") or []) if f in known]
    t["mode"] = {k: v for k, v in (t.get("mode") or {}).items() if k in known and v in ("block", "log")}
    t["outbound"] = bool(t.get("outbound", False))
    try:
        t["refresh_hours"] = min(168, max(1, int(t.get("refresh_hours", 12))))
    except (TypeError, ValueError):
        raise ValueError("Refresh interval must be a number of hours")


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
        if isinstance(body.get("rules"), list):
            c["rules"] = body["rules"]
        if isinstance(body.get("threat"), dict) and isinstance(body["threat"].get("feeds"), list):
            c["threat"]["feeds"] = [str(f) for f in body["threat"]["feeds"]]
        if isinstance(body.get("threat"), dict):
            tb = body["threat"]
            if isinstance(tb.get("mode"), dict):
                c["threat"]["mode"] = {str(k): str(v) for k, v in tb["mode"].items()}
            for k in ("outbound", "refresh_hours"):
                if k in tb:
                    c["threat"][k] = tb[k]
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
    STATE["watched"] = time.time()      # someone has the firewall page open: sample every second
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


def api_fwrules(q):
    """The rules with how many packets each one matched since the rules were last applied."""
    hits = {}
    if STATE["applied"]:
        try:
            data = json.loads(nft(["-j", "list", "counters", "table", "inet", "defender"]))
            for item in data.get("nftables", []):
                c = item.get("counter")
                if c and c.get("name", "").startswith("c_r_"):
                    hits[c["name"][4:]] = {"packets": c.get("packets", 0), "bytes": c.get("bytes", 0)}
        except (RuntimeError, ValueError):
            pass
    codes = sorted({c for r in CFG["rules"] for c in r.get("countries") or []})
    return {"rules": CFG["rules"], "hits": hits, "zones": geo.info(DATA, codes), "enabled": CFG["enabled"]}


# ------------------------------------------------------------------ SSH server management

def ssh_busy_ports():
    return {r["port"] for r in hostinfo.listening() if r["proto"] == "tcp" and r["process"] not in ("sshd", "systemd")}


def _f2b_ssh_ports(ports):
    """fail2ban's sshd jail bans on "port = ssh" (22): keep it on the real SSH ports."""
    try:
        if f2b.installed() and f2b.running() and "sshd" in f2b.jail_names():
            f2b_save(lambda m: m["jails"].setdefault("sshd", {}).update({"port": ",".join(str(p) for p in ports)}), "ssh port")
            return ""
    except Exception as e:
        return f"fail2ban could not be updated: {e}"
    return ""


def api_sshd(q):
    return {**sshmgr.state(STATE.get("ssh_pending")), "confirm_seconds": sshmgr.CONFIRM_SECONDS}


def api_sshd_apply(b):
    if STATE.get("ssh_pending"):
        raise ValueError("Keep or undo the previous SSH change first")
    before = sshmgr.effective()
    settings = sshmgr.validate(b, ssh_busy_ports())
    hostinfo._ports_cache["at"] = 0

    def open_ports():   # the firewall must let the new port in before sshd moves there
        hostinfo._ports_cache["at"] = 0
        if CFG["enabled"]:
            apply()
    with LOCK:
        old = sshmgr.apply(settings, before_restart=open_ports)
        STATE["ssh_pending"] = {"until": time.time() + sshmgr.CONFIRM_SECONDS, "old": old, "ports": settings["ports"],
                                "old_ports": before.get("port", [22])}
    warn = _f2b_ssh_ports(settings["ports"]) if settings["ports"] != before.get("port", [22]) else ""
    event("ssh_change", ports=settings["ports"])
    return {**api_sshd({}), "warning": warn}


def api_sshd_confirm(b):
    with LOCK:
        if STATE.get("ssh_pending"):
            STATE["ssh_pending"] = None
            event("ssh_confirmed")
    return api_sshd({})


def ssh_revert(reason="manual"):
    with LOCK:
        p = STATE.get("ssh_pending")
        if not p:
            return
        STATE["ssh_pending"] = None
        sshmgr.restore(p["old"])
        hostinfo._ports_cache["at"] = 0
        if CFG["enabled"]:
            apply()
    if p["ports"] != p["old_ports"]:
        _f2b_ssh_ports(p["old_ports"])
    event("ssh_reverted", reason=reason)


def api_sshd_revert(b):
    ssh_revert("manual")
    return api_sshd({})


def api_sshd_key_add(b):
    out = sshmgr.add_key(b.get("key", ""))
    event("ssh_key", action="added")
    return {"keys": out}


def api_sshd_key_remove(b):
    out = sshmgr.remove_key(int(b.get("index", -1)), sshmgr.effective().get("passwordauthentication"))
    event("ssh_key", action="removed")
    return {"keys": out}


# ------------------------------------------------------------------ threat lists

def _seen(name):
    """Addresses in one of the "recently matched" sets, with the seconds left of their hour."""
    rows = []
    if not STATE["applied"]:
        return rows
    for v in ("4", "6"):
        try:
            data = json.loads(nft(["-j", "list", "set", "inet", "defender", f"{name}{v}"]))
        except (RuntimeError, ValueError):
            continue
        for item in data.get("nftables", []):
            for el in (item.get("set") or {}).get("elem", []) or []:
                e = el.get("elem") if isinstance(el, dict) else None
                if e and isinstance(e.get("val"), str):
                    rows.append((e["val"], e.get("expires", 0)))
                elif isinstance(el, str):
                    rows.append((el, 0))
    return rows


def api_threat(q):
    t = CFG["threat"]
    feeds = threat_feeds()
    counters = read_counters()
    info = threat.info(DATA, feeds)
    on = t["feeds"]
    for fid, f in info.items():
        f.update(enabled=fid in on, mode=t["mode"].get(fid, "block"), hits=counters.get(f"t_{fid}"))
    recent = []
    for kind, name in (("block", "tseen"), ("log", "tlog")):
        for ip, left in sorted(_seen(name), key=lambda r: -r[1])[:100]:
            try:
                hit = threat.member(DATA, on, ip)
            except ValueError:
                hit = []
            recent.append({"ip": ip, "kind": kind, "ago": max(0, 3600 - int(left)), "lists": hit})
    recent.sort(key=lambda r: r["ago"])
    blocking = [f for f in on if t["mode"].get(f, "block") == "block"]
    return {"feeds": info, "order": list(feeds), "enabled": on, "protection": CFG["enabled"], "applied": STATE["applied"],
            "outbound": t["outbound"], "refresh_hours": t["refresh_hours"], "custom_max": threat.MAX_CUSTOM,
            "blocked": counters.get("threat"), "blocked_out": counters.get("tout"), "recent": recent[:150],
            "addresses": sum(info[f]["addresses"] for f in blocking if f in info),
            "entries": sum(info[f]["v4"] + info[f]["v6"] for f in blocking if f in info),
            "next_check": THREAT_STATE["next"], "refreshing": THREAT_STATE["busy"]}


THREAT_STATE = {"next": 0, "busy": False}


def threat_update_sets(changed):
    """New content of lists that are on goes into their sets in place, in one transaction: the
    table, counters, bans and live limits stay as they are (a full rebuild would reset them)."""
    if not changed or not CFG["enabled"] or not STATE["applied"] or STATE["pending"]:
        return
    lists_ = threat.lists(DATA, changed)
    cmds = []
    for fid in changed:
        v4, v6 = lists_.get(fid, ([], []))
        for v, items in (("4", v4), ("6", v6)):
            cmds.append(f"flush set inet defender t_{fid}{v}")
            for i in range(0, len(items), 5000):
                cmds.append(f"add element inet defender t_{fid}{v} {{ {', '.join(items[i:i + 5000])} }}")
    try:
        nft(["-f", "-"], stdin="\n".join(cmds) + "\n")
    except RuntimeError as e:      # a set is missing (the list was empty before): rebuild the table
        log("threat sets: in-place update failed, rebuilding:", str(e)[:200])
        apply()


def threat_refresh(force=False, only=None):
    with THREAT_LOCK:
        THREAT_STATE["busy"] = True
        try:
            changed = threat_download(CFG, force=force, only=only)
            if changed:
                event("threat_updated", lists=changed)
                with LOCK:
                    threat_update_sets(changed)
            return changed
        finally:
            THREAT_STATE["busy"] = False


THREAT_LOCK = threading.Lock()


def threat_refresh_loop():
    """Checks every 30 minutes which lists that are on are older than their refresh interval."""
    THREAT_STATE["next"] = int(time.time()) + 120
    time.sleep(120)
    while True:
        THREAT_STATE["next"] = int(time.time()) + 1800
        try:
            if CFG["threat"]["feeds"] and CFG["enabled"]:
                threat_refresh()
        except Exception as e:
            log("threat refresh", e)
        time.sleep(1800)


def api_threat_refresh(b):
    fid = b.get("id")
    if fid and fid not in CFG["threat"]["feeds"]:
        raise ValueError("That list is not on")
    if THREAT_STATE["busy"]:
        raise ValueError("The lists are being updated right now; try again in a moment")
    changed = threat_refresh(force=True, only=[fid] if fid else None)
    return {**api_threat({}), "changed": changed}


def api_threat_custom_add(b):
    name = str(b.get("name", "")).strip()[:60]
    if not name:
        raise ValueError("Give the list a name")
    url = threat.check_url(b.get("url"))
    if len(CFG["threat"]["custom"]) >= threat.MAX_CUSTOM:
        raise ValueError(f"At most {threat.MAX_CUSTOM} lists of your own")
    if any(c["url"] == url for c in CFG["threat"]["custom"]):
        raise ValueError("This list is already added")
    used = {c["id"] for c in CFG["threat"]["custom"]}
    cid = next(f"my{i}" for i in range(1, 100) if f"my{i}" not in used)
    feed = threat.all_feeds([{"id": cid, "name": name, "url": url}])[cid]
    threat.remove(DATA, cid)
    threat.fetch(DATA, cid, feed, 0, force=True)       # raises (with the reason) if it cannot be read

    def mut(c):
        c["threat"]["custom"].append({"id": cid, "name": name, "url": url})
        c["threat"]["mode"][cid] = "log"            # someone else's list: watch what it would block first
        c["threat"]["feeds"].append(cid)
    try:
        change(mut, rollback=False, what="threat list added")
    except Exception:
        threat.remove(DATA, cid)
        raise
    event("threat_list", action="added", name=name)
    return api_threat({})


def api_threat_custom_remove(b):
    cid = str(b.get("id", ""))
    if not any(c["id"] == cid for c in CFG["threat"]["custom"]):
        raise ValueError("No such list")

    def mut(c):
        c["threat"]["custom"] = [x for x in c["threat"]["custom"] if x["id"] != cid]
        c["threat"]["feeds"] = [f for f in c["threat"]["feeds"] if f != cid]
        c["threat"]["mode"].pop(cid, None)
    change(mut, rollback=False, what="threat list removed")
    threat.remove(DATA, cid)
    event("threat_list", action="removed", list=cid)
    return api_threat({})


# ------------------------------------------------------------------ "what happens to this address?"

def _in(ip, nets):
    a = ipaddress.ip_address(ip)
    for n in nets:
        try:
            if a in ipaddress.ip_network(n, strict=False):
                return n
        except ValueError:
            pass
    return None


def country_of(ip):
    """Country of an address, from the country lists already downloaded (None when not known)."""
    a = ipaddress.ip_address(ip)
    d = os.path.join(DATA, "geo")
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return None
    for n in names:
        if n.endswith(f".{a.version}"):
            for line in open(os.path.join(d, n)):
                line = line.strip()
                if line and a in ipaddress.ip_network(line):
                    return n.split(".")[0]
    return None


def api_test(b):
    ip = net_str(parse_net(b.get("ip", ""), allow_any=True))
    if "/" in ip:
        raise ValueError("Enter a single address")
    port = int(b.get("port") or 0)
    proto = b.get("proto") if b.get("proto") in ("tcp", "udp", "icmp") else "tcp"
    steps, verdict = [], None

    def step(kind, result, **kw):
        steps.append({"kind": kind, "result": result, **kw})
        return result

    cc = country_of(ip)
    if not CFG["enabled"]:
        return {"ip": ip, "country": cc, "verdict": "allow", "steps": [{"kind": "off", "result": "allow"}]}
    if CFG.get("trust_logged_in", True) and ip in admin_ips():
        verdict = step("admin", "allow")
    if not verdict and _in(ip, [a["ip"] for a in CFG["allow"]]):
        verdict = step("allowlist", "allow", entry=_in(ip, [a["ip"] for a in CFG["allow"]]))
    if not verdict and _in(ip, [x["ip"] for x in CFG["block"]]):
        verdict = step("blocklist", "block", entry=_in(ip, [x["ip"] for x in CFG["block"]]))
    if not verdict:
        ban = next((r for r in ban_list() if r["ip"] == ip), None)
        if ban:
            verdict = step("fail2ban" if ban["source"] == "fail2ban" else "banned", "block", left=ban["left"], jail=ban.get("jail"), source=ban["source"])
    adv = CFG["advanced"]
    if not verdict and port in PANEL_PORTS and proto == "tcp" and adv.get("panel_allow") and not _in(ip, adv["panel_allow"]):
        verdict = step("panel_allow", "block")
    if not verdict and CFG.get("trust_cdn", True) and _in(ip, list(nftrules.CDN4) + list(nftrules.CDN6)):
        verdict = step("cdn", "allow")
    if not verdict:
        names = threat_feeds()
        hits = threat.member(DATA, CFG["threat"]["feeds"], ip)
        blocking = [f for f in hits if CFG["threat"]["mode"].get(f, "block") == "block"]
        watching = [f for f in hits if f not in blocking]
        if watching:
            step("threat_log", "count", feeds=[names[f]["name"] for f in watching])
        if blocking:
            verdict = step("threat", "block", feeds=[names[f]["name"] for f in blocking])
    if not verdict:
        for r in CFG["rules"]:
            if not r.get("enabled", True) or r.get("direction") == "out":
                continue
            if r["countries"]:
                inside = cc in r["countries"] if cc else None
                if inside is None and r["country_mode"] == "in":
                    continue
                if inside is not None and inside != (r["country_mode"] == "in"):
                    continue
            if r["ips"] and bool(_in(ip, r["ips"])) != (r["ip_mode"] == "in"):
                continue
            if r["proto"] != "any" and r["proto"] != proto:
                continue
            if r["ports"] and not any(int(x.split("-")[0]) <= port <= int(x.split("-")[-1]) for x in r["ports"].split(",")):
                continue
            res = {"allow": "allow", "block": "block", "limit": "limit", "log": "count"}[r["action"]]
            step("rule", res, name=r["name"], schedule=r.get("schedule"), limit=r.get("limit") if r["action"] == "limit" else None)
            if res in ("allow", "block"):
                verdict = res
                break
    fw = CFG["firewall"]
    if not verdict and fw["mode"] == "strict" and proto in ("tcp", "udp") and port:
        locked = proto == "tcp" and adv.get("lock_ports", True) and (port in hostinfo.ssh_ports() or port in PANEL_PORTS)
        listed = any(_port_match(p, {"proto": proto, "port": port}) for p in fw["ports"]) or any(
            p.get("from") and _in(ip, [p["from"]]) and _port_match(dict(p, **{"from": ""}), {"proto": proto, "port": port}) for p in fw["ports"])
        if not (locked or listed):
            verdict = step("strict", "block", port=port)
    if not verdict:
        verdict = step("limits", "allow", limits=effective_limits())
    return {"ip": ip, "country": cc, "port": port, "proto": proto, "verdict": verdict, "steps": steps}


def api_geo(q):
    return {"block": CFG["geo"]["block"], "info": geo.info(DATA, CFG["geo"]["block"])}


def geo_refresh_loop():
    """Country lists change slowly; refresh them weekly and re-apply when one changed."""
    while True:
        time.sleep(6 * 3600)
        try:
            codes = sorted(set(CFG["geo"]["block"]) | {c for r in CFG["rules"] if r.get("enabled", True) for c in r.get("countries") or []})
            if not codes or not CFG["enabled"]:
                continue
            before = geo.info(DATA, codes)
            geo.build(DATA, codes, download=True)
            if geo.info(DATA, codes) != before and not STATE["pending"]:
                apply()
        except Exception as e:
            log("geo refresh", e)


EXPORT_KEYS = ("enabled", "profile", "limits", "auto_escalate", "ddos", "firewall", "allow", "block", "ssh_guard",
               "trust_logged_in", "trust_cdn", "geo", "notify", "advanced", "rules", "threat")


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
    # what the panel's notifier polls every 10 s: no scanning of the host
    "/brief": lambda q: {"enabled": CFG["enabled"], "notify": CFG["notify"], "last_event": EVENTS[-1]["id"] if EVENTS else 0},
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
    "/fwrules": api_fwrules,
    "/sshd": api_sshd,
    "/threat": api_threat,
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
    "/sshd/apply": api_sshd_apply,
    "/sshd/confirm": api_sshd_confirm,
    "/sshd/revert": api_sshd_revert,
    "/sshd/key/add": api_sshd_key_add,
    "/sshd/key/remove": api_sshd_key_remove,
    "/threat/refresh": api_threat_refresh,
    "/port/open": api_open_port,
    "/port/close": api_close_port,
    "/sysfw/ufw": api_ufw,
    "/threat/custom/add": api_threat_custom_add,
    "/threat/custom/remove": api_threat_custom_remove,
    "/test": api_test,
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
            if n > 8_000_000:
                raise ValueError
            body = json.loads(self.rfile.read(n) or b"{}")
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
    for target in (stats_loop, ssh_guard_loop, admin_refresh_loop, geo_refresh_loop, threat_refresh_loop):
        threading.Thread(target=target, daemon=True).start()
    threading.Thread(target=f2b.watch_log, args=(on_f2b_ban,), daemon=True).start()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))   # the rules stay in the kernel while the agent restarts
    log(f"defender {VERSION} ready on {SOCK}; protection {'on' if CFG['enabled'] else 'off'}, "
        f"ssh ports {hostinfo.ssh_ports()}, panel ports {PANEL_PORTS}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
