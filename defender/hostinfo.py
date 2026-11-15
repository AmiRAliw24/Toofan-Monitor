"""What the Defender knows about the host: open ports, SSH, kernel settings, and a security audit.

The agent runs with the host's network and PID namespaces, so /proc/net/* describes the host's
sockets and /proc/1/root is the host's filesystem (read-only use only).
"""
import glob
import ipaddress
import os
import re
import subprocess
import time

HOST = os.environ.get("HOST_ROOT", "/proc/1/root")

# ------------------------------------------------------------------ files on the host

def host_path(p):
    return os.path.join(HOST, p.lstrip("/"))


def read(p, limit=2_000_000):
    try:
        with open(host_path(p), "rb") as f:
            return f.read(limit).decode("utf-8", "replace")
    except OSError:
        return None


# ------------------------------------------------------------------ sockets

TCP_STATES = {"0A": "listen"}


def _hex_addr(h):
    if len(h) == 8:
        return str(ipaddress.IPv4Address(bytes.fromhex(h)[::-1]))
    b = bytes.fromhex(h)
    return str(ipaddress.IPv6Address(b"".join(b[i:i + 4][::-1] for i in range(0, 16, 4))))


def _inode_owners():
    """socket inode -> process name, by walking /proc/<pid>/fd (the host's PIDs)."""
    owners = {}
    for fd_dir in glob.glob("/proc/[0-9]*/fd"):
        pid = fd_dir.split("/")[2]
        try:
            names = os.listdir(fd_dir)
        except OSError:
            continue
        comm = None
        for n in names:
            try:
                target = os.readlink(f"{fd_dir}/{n}")
            except OSError:
                continue
            if target.startswith("socket:["):
                if comm is None:
                    try:
                        with open(f"/proc/{pid}/comm") as f:
                            comm = f.read().strip()
                    except OSError:
                        comm = "?"
                owners[target[8:-1]] = comm
    return owners


_ports_cache = {"at": 0, "rows": []}


def listening(max_age=20):
    """[{proto, port, addr, public, process}] for every listening TCP / bound UDP socket of the host."""
    if time.time() - _ports_cache["at"] < max_age:
        return _ports_cache["rows"]
    owners = _inode_owners()
    try:   # UDP sockets on ports the kernel hands out to clients are outgoing (e.g. VPN/proxy uplinks), not services
        lo, hi = (int(x) for x in open("/proc/sys/net/ipv4/ip_local_port_range").read().split())
    except (OSError, ValueError):
        lo, hi = 32768, 60999
    seen = {}
    for proto, files in (("tcp", ("/proc/net/tcp", "/proc/net/tcp6")), ("udp", ("/proc/net/udp", "/proc/net/udp6"))):
        for path in files:
            try:
                lines = open(path).read().splitlines()[1:]
            except OSError:
                continue
            for line in lines:
                parts = line.split()
                if len(parts) < 10:
                    continue
                local, state, inode = parts[1], parts[3], parts[9]
                if proto == "tcp" and state != "0A":
                    continue
                if proto == "udp" and parts[2].split(":")[1] != "0000":   # connected UDP sockets are clients
                    continue
                host_hex, port_hex = local.split(":")
                addr, port = _hex_addr(host_hex), int(port_hex, 16)
                if proto == "udp" and lo <= port <= hi:
                    continue
                ip = ipaddress.ip_address(addr)
                public = not (ip.is_loopback or (ip.version == 6 and ip.ipv4_mapped and ip.ipv4_mapped.is_loopback))
                key = (proto, port)
                row = seen.get(key)
                if row is None:
                    row = seen[key] = {"proto": proto, "port": port, "addrs": [], "public": False, "process": owners.get(inode, "")}
                row["addrs"].append(addr)
                row["public"] = row["public"] or public
                if not row["process"]:
                    row["process"] = owners.get(inode, "")
    rows = sorted(seen.values(), key=lambda r: (not r["public"], r["proto"], r["port"]))
    for r in rows:
        r["addrs"] = sorted(set(r["addrs"]))
    _ports_cache.update(at=time.time(), rows=rows)
    return rows


def docker_published():
    """Host ports Docker forwards to containers (they need to stay open in strict mode)."""
    out = set()
    try:
        text = subprocess.run(["nft", "list", "chain", "ip", "nat", "DOCKER"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return out
    for proto, port in re.findall(r"\b(tcp|udp) dport (\d+)\b.*\bdnat\b", text):
        out.add((proto, int(port)))
    return out


# ------------------------------------------------------------------ SSH

def sshd_config():
    text = read("/etc/ssh/sshd_config") or ""
    for f in sorted(glob.glob(host_path("/etc/ssh/sshd_config.d/*.conf"))):
        try:
            text = open(f, errors="replace").read() + "\n" + text   # included files come first and win
        except OSError:
            pass
    conf, ports = {}, []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.lower().startswith("match "):
            break   # settings after Match only apply to some users; the global ones are enough here
        k, _, v = line.partition(" ")
        k, v = k.lower(), v.strip()
        if k == "port":
            ports.append(int(v)) if v.isdigit() else None
        elif k not in conf:
            conf[k] = v.lower()
    return conf, ports


def ssh_ports():
    _, ports = sshd_config()
    # sshd's sockets change only when its settings do (the agent then clears the cache): a scan of every
    # process's open files every 2 minutes is plenty
    from_sockets = [r["port"] for r in listening(max_age=120) if r["proto"] == "tcp" and r["process"] == "sshd"]
    return sorted(set(ports + from_sockets)) or [22]


def ssh_sessions():
    """Source IPs of users that are logged in right now (from utmp, so only real logins: a brute-force
    attempt also holds an open TCP connection to sshd, but never shows up here)."""
    ips = set()
    try:
        with open(host_path("/run/utmp"), "rb") as f:
            data = f.read(4 * 1024 * 1024)
    except OSError:
        return []
    for off in range(0, len(data) - 383, 384):   # struct utmp on 64-bit Linux / glibc
        rec = data[off:off + 384]
        if int.from_bytes(rec[0:2], "little") != 7:   # USER_PROCESS
            continue
        host = rec[76:332].split(b"\0", 1)[0].decode("ascii", "replace")
        try:
            ip = ipaddress.ip_address(host)
        except ValueError:
            raw = rec[348:364]
            if not any(raw):
                continue
            ip = ipaddress.ip_address(raw[:4]) if not any(raw[4:]) else ipaddress.ip_address(raw)
        if not ip.is_loopback:
            ips.add(str(ip))
    return sorted(ips)


# ------------------------------------------------------------------ network interfaces and traffic

def public_iface():
    try:
        for line in open("/proc/net/route").read().splitlines()[1:]:
            p = line.split()
            if p[1] == "00000000" and p[7] == "00000000":
                return p[0]
    except OSError:
        pass
    return None


def iface_counters(name):
    try:
        for line in open("/proc/net/dev"):
            if ":" in line and line.split(":")[0].strip() == name:
                v = line.split(":")[1].split()
                return {"rx_bytes": int(v[0]), "rx_packets": int(v[1]), "rx_drop": int(v[3])}
    except OSError:
        pass
    return None


def interfaces():
    try:
        return sorted(n for n in os.listdir("/sys/class/net") if n != "lo")
    except OSError:
        return []


def _snmp(path):
    """/proc/net/snmp and /proc/net/netstat: 'Tcp: a b c' header line followed by a value line."""
    out = {}
    try:
        lines = open(path).read().splitlines()
    except OSError:
        return out
    for head, vals in zip(lines[::2], lines[1::2]):
        k, names = head.split(":", 1)
        for n, v in zip(names.split(), vals.split(":", 1)[1].split()):
            try:
                out[f"{k}.{n}"] = int(v)
            except ValueError:
                pass
    return out


def tcp_counters():
    a, b = _snmp("/proc/net/snmp"), _snmp("/proc/net/netstat")
    return {"passive_opens": a.get("Tcp.PassiveOpens", 0), "curr_estab": a.get("Tcp.CurrEstab", 0),
            "syncookies_sent": b.get("TcpExt.SyncookiesSent", 0), "listen_drops": b.get("TcpExt.ListenDrops", 0),
            "listen_overflows": b.get("TcpExt.ListenOverflows", 0)}


def conntrack_usage():
    try:
        count = int(open("/proc/sys/net/netfilter/nf_conntrack_count").read())
        maximum = int(open("/proc/sys/net/netfilter/nf_conntrack_max").read())
        return {"count": count, "max": maximum}
    except (OSError, ValueError):
        return None


_talk_cache = {"at": 0, "rows": []}


def top_sources(limit=15, max_age=4):
    """Remote addresses with the most tracked connections right now (who is talking to us most)."""
    if time.time() - _talk_cache["at"] < max_age:
        return _talk_cache["rows"]
    counts, local = {}, set(local_addresses())
    try:
        proc = subprocess.run(["conntrack", "-L", "-o", "extended"], capture_output=True, text=True, timeout=6)
        text = proc.stdout
    except (OSError, subprocess.TimeoutExpired):
        text = ""
    for line in text.splitlines():
        m = re.search(r"\bsrc=(\S+) dst=(\S+)", line)
        if not m:
            continue
        src, dst = m.group(1), m.group(2)
        if dst not in local or src in local:
            continue   # only connections made TO this server
        try:
            ip = ipaddress.ip_address(src)
        except ValueError:
            continue
        if ip.is_loopback or ip.is_private and src.startswith("172."):
            continue
        counts[src] = counts.get(src, 0) + 1
    rows = [{"ip": ip, "conns": n} for ip, n in sorted(counts.items(), key=lambda kv: -kv[1])[:limit]]
    _talk_cache.update(at=time.time(), rows=rows)
    return rows


def local_addresses():
    out = []
    try:
        text = subprocess.run(["ip", "-o", "addr"], capture_output=True, text=True, timeout=3).stdout
        out = [m.split("/")[0] for m in re.findall(r"inet6? (\S+)", text)]
    except (OSError, subprocess.TimeoutExpired):
        pass
    return out


# ------------------------------------------------------------------ kernel network hardening (sysctl)

SYSCTLS = [
    # key, recommended, why (i18n key on the panel side)
    ("net.ipv4.tcp_syncookies", "1", "sc_syncookies"),
    ("net.ipv4.tcp_synack_retries", "2", "sc_synack"),
    ("net.ipv4.tcp_max_syn_backlog", "8192", "sc_backlog"),
    ("net.ipv4.tcp_rfc1337", "1", "sc_rfc1337"),
    ("net.ipv4.icmp_echo_ignore_broadcasts", "1", "sc_bcast"),
    ("net.ipv4.icmp_ignore_bogus_error_responses", "1", "sc_bogus"),
    ("net.ipv4.conf.all.accept_redirects", "0", "sc_redirects"),
    ("net.ipv4.conf.default.accept_redirects", "0", "sc_redirects"),
    ("net.ipv6.conf.all.accept_redirects", "0", "sc_redirects"),
    ("net.ipv4.conf.all.send_redirects", "0", "sc_send_redirects"),
    ("net.ipv4.conf.all.accept_source_route", "0", "sc_source_route"),
    ("net.ipv6.conf.all.accept_source_route", "0", "sc_source_route"),
    ("net.netfilter.nf_conntrack_max", "262144", "sc_conntrack"),
    ("net.netfilter.nf_conntrack_tcp_timeout_established", "86400", "sc_ct_timeout"),
]
AT_LEAST = {"net.ipv4.tcp_max_syn_backlog", "net.netfilter.nf_conntrack_max"}   # a higher value is fine too


def _sysctl_path(key):
    return "/proc/sys/" + key.replace(".", "/")


def sysctl_get(key):
    try:
        return open(_sysctl_path(key)).read().strip()
    except OSError:
        return None


def sysctl_set(key, value):
    with open(_sysctl_path(key), "w") as f:
        f.write(str(value))


def sysctl_ok(key, current, recommended):
    if current is None:
        return None
    if key in AT_LEAST:
        try:
            return int(current) >= int(recommended)
        except ValueError:
            return False
    return current == recommended


def sysctl_report():
    rows = []
    for key, rec, why in SYSCTLS:
        cur = sysctl_get(key)
        rows.append({"key": key, "current": cur, "recommended": rec, "why": why, "ok": sysctl_ok(key, cur, rec)})
    return rows


# ------------------------------------------------------------------ security audit

INTERNAL_PORTS = {3306: "MySQL/MariaDB", 5432: "PostgreSQL", 6379: "Redis", 27017: "MongoDB", 9200: "Elasticsearch",
                  11211: "Memcached", 2375: "Docker API", 2376: "Docker API", 5984: "CouchDB", 9000: "PHP-FPM / MinIO",
                  8086: "InfluxDB", 15672: "RabbitMQ admin", 5672: "RabbitMQ", 25: "SMTP"}


def auth_failures(hours=24):
    text = read("/var/log/auth.log", 30_000_000)
    if text is None:
        return None
    return len(re.findall(r"Failed password|Invalid user|authentication failure", text))


def audit(state):
    """[{id, sev (0 ok, 1 low, 2 medium, 3 high), params}] - the texts live on the panel side (i18n)."""
    out = []
    add = lambda cid, sev, **p: out.append({"id": cid, "sev": sev, "params": p})
    conf, _ = sshd_config()
    root = conf.get("permitrootlogin", "prohibit-password")
    pw = conf.get("passwordauthentication", "yes")
    if root == "yes" and pw == "yes":
        add("ssh_root_pw", 3)
    elif root == "yes":
        add("ssh_root", 1)
    else:
        add("ssh_root", 0)
    add("ssh_password", 2 if pw == "yes" else 0)
    ports = ssh_ports()
    add("ssh_port", 1 if ports == [22] else 0, ports=",".join(map(str, ports)))
    fails = auth_failures()
    if fails is not None:
        add("ssh_bruteforce", 2 if fails > 100 else 1 if fails > 10 else 0, n=fails)
    add("fw_enabled", 0 if state["enabled"] else 3)
    exposed = [r for r in listening() if r["public"] and r["proto"] == "tcp" and r["port"] in INTERNAL_PORTS]
    for r in exposed:
        add("internal_exposed", 3, port=r["port"], name=INTERNAL_PORTS[r["port"]], process=r["process"])
    if not exposed:
        add("internal_exposed", 0)
    public_tcp = [r for r in listening() if r["public"] and r["proto"] == "tcp"]
    add("open_ports", 1 if state["mode"] == "open" and len(public_tcp) > 6 else 0, n=len(public_tcp))
    add("reboot", 2 if os.path.exists(host_path("/run/reboot-required")) else 0)
    auto = read("/etc/apt/apt.conf.d/20auto-upgrades") or ""
    if os.path.isdir(host_path("/etc/apt")):
        add("auto_updates", 0 if re.search(r'Unattended-Upgrade\s+"1"', auto) else 1)
    ct = conntrack_usage()
    if ct:
        pct = ct["count"] / ct["max"] * 100
        add("conntrack", 3 if pct > 85 else 1 if pct > 60 else 0, pct=round(pct), max=ct["max"])
    weak = [r for r in sysctl_report() if r["ok"] is False]
    add("kernel", 1 if weak else 0, n=len(weak))
    add("syncookies", 0 if sysctl_get("net.ipv4.tcp_syncookies") == "1" else 2)
    add("fail2ban", 0 if fail2ban_present() else 1)
    return out


def score(checks):
    weights = {0: 0, 1: 3, 2: 9, 3: 20}
    return max(0, 100 - sum(weights[c["sev"]] for c in checks))


# ------------------------------------------------------------------ fail2ban (read-only view of its bans)

def fail2ban_present():
    return os.path.exists(host_path("/etc/fail2ban/jail.conf")) or os.path.exists(host_path("/usr/bin/fail2ban-server"))


def fail2ban_bans():
    try:
        text = subprocess.run(["nft", "-j", "list", "table", "inet", "f2b-table"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    ips = []
    for m in re.finditer(r'"elem":\s*\[([^\]]*)\]', text):
        ips += re.findall(r'"((?:\d{1,3}\.){3}\d{1,3}|[0-9a-fA-F:]+:[0-9a-fA-F:]*)"', m.group(1))
    return sorted(set(ips))
