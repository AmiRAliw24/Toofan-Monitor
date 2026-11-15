"""The server's own firewall: ufw, firewalld or a plain iptables INPUT policy.

Our rules (table inet defender) only ever drop; they cannot open what another firewall on the server
closes. When a service does not load although it listens, the usual fix is `ufw allow 8080/tcp` (or the
firewalld equivalent). This module finds out which of them is active, whether a port is open in it, and
opens or closes ports there, so that can be done from the panel.

Commands run on the host through nsenter (see sshmgr.host). Nothing here changes a firewall that is off,
except turning ufw on, which always opens the SSH and panel ports first.
"""
import os
import re

import hostinfo
from sshmgr import host

UFW_RULE = re.compile(r"^\[\s*(\d+)\]\s+(.+?)\s+(ALLOW|DENY|REJECT|LIMIT)(?:\s+(IN|OUT|FWD))?\s+(.+?)\s*$")
# a few well-known ufw application profiles, so their ports count as open
UFW_APPS = {"openssh": [("tcp", 22, 22)], "nginx full": [("tcp", 80, 80), ("tcp", 443, 443)], "nginx http": [("tcp", 80, 80)],
            "nginx https": [("tcp", 443, 443)], "apache full": [("tcp", 80, 80), ("tcp", 443, 443)], "apache": [("tcp", 80, 80)],
            "apache secure": [("tcp", 443, 443)], "www": [("tcp", 80, 80)], "www secure": [("tcp", 443, 443)],
            "www full": [("tcp", 80, 80), ("tcp", 443, 443)]}
PORT_RE = re.compile(r"^(\d{1,5})(?:[-:](\d{1,5}))?$")
SRC_RE = re.compile(r"^[0-9a-fA-F:.]+(?:/\d{1,3})?$")


def _exists(*paths):
    return any(os.path.exists(hostinfo.host_path(p)) for p in paths)


def _ufw_ports(to):
    """[(proto, first, last)] a ufw "To" column opens, or None when it means every port."""
    to = re.sub(r"\s*\(v6\)$", "", to).strip()
    if to.lower().startswith("anywhere"):
        return None
    if to.lower() in UFW_APPS:
        return UFW_APPS[to.lower()]
    out = []
    spec, _, proto = to.partition("/")
    for part in spec.split(","):
        m = PORT_RE.match(part.strip())
        if m:
            a, b = int(m.group(1)), int(m.group(2) or m.group(1))
            for pr in ((proto,) if proto in ("tcp", "udp") else ("tcp", "udp")):
                out.append((pr, a, b))
    return out


def ufw_status():
    if not _exists("/usr/sbin/ufw", "/sbin/ufw", "/usr/bin/ufw"):
        return {"installed": False}
    rc, out = host(["ufw", "status", "verbose"], timeout=20)
    active = "Status: active" in out
    m = re.search(r"Default:\s*(\w+)\s*\(incoming\)", out)
    rules = []
    if active:
        _, numbered = host(["ufw", "status", "numbered"], timeout=20)
        for line in numbered.splitlines():
            r = UFW_RULE.match(line.strip())
            if r:
                rules.append({"n": int(r.group(1)), "to": r.group(2).strip(), "action": r.group(3), "dir": r.group(4) or "IN",
                              "from": r.group(5).strip(), "v6": "(v6)" in line, "text": line.split("]", 1)[1].strip()})
    return {"installed": True, "active": active, "incoming": (m.group(1).lower() if m else "deny"), "rules": rules,
            "error": out if rc and not active and "inactive" not in out else ""}


def firewalld_status():
    if not _exists("/usr/bin/firewall-cmd", "/bin/firewall-cmd"):
        return {"installed": False}
    rc, out = host(["firewall-cmd", "--state"], timeout=20)
    running = out.strip() == "running"
    ports, services = [], []
    if running:
        ports = host(["firewall-cmd", "--list-ports"], timeout=20)[1].split()
        services = host(["firewall-cmd", "--list-services"], timeout=20)[1].split()
    return {"installed": True, "active": running, "ports": ports, "services": services}


def iptables_policy():
    rc, out = host(["iptables", "-S", "INPUT"], timeout=20)
    m = re.search(r"^-P INPUT (\w+)", out, re.M)
    return m.group(1) if rc == 0 and m else None


def status():
    ufw, fwd = ufw_status(), firewalld_status()
    policy = iptables_policy()
    # which one decides: ufw or firewalld when on, else a DROP policy on iptables INPUT
    active = "ufw" if ufw.get("active") else "firewalld" if fwd.get("active") else "iptables" if policy in ("DROP", "REJECT") else None
    rules = host(["iptables", "-S", "INPUT"], timeout=20)[1] if active == "iptables" else ""
    return {"ufw": ufw, "firewalld": fwd, "iptables_policy": policy, "active": active, "_input": rules}


def port_open(st, proto, port):
    """True / False when the server's firewall lets this port in, None when there is none that filters."""
    if st["active"] == "ufw":
        u = st["ufw"]
        allowed = denied = False
        for r in u["rules"]:
            if r["dir"] != "IN":
                continue
            ports = _ufw_ports(r["to"])
            hit = ports is None or any(p == proto and a <= port <= b for p, a, b in ports)
            if hit and r["from"].lower().startswith("anywhere"):
                if r["action"] in ("ALLOW", "LIMIT"):
                    allowed = True
                else:
                    denied = True
            elif hit and r["action"] in ("ALLOW", "LIMIT"):
                allowed = allowed or "partly"
            if allowed is True or denied:
                break      # ufw uses the first matching rule
        if allowed is True:
            return True
        if denied:
            return False
        return u["incoming"] == "allow" or ("partly" if allowed else False)
    if st["active"] == "firewalld":
        f = st["firewalld"]
        for spec in f["ports"]:
            m = re.match(r"^(\d+)(?:-(\d+))?/(\w+)$", spec)
            if m and m.group(3) == proto and int(m.group(1)) <= port <= int(m.group(2) or m.group(1)):
                return True
        return ("ssh" in f["services"] and proto == "tcp" and port == 22) or \
               ("http" in f["services"] and proto == "tcp" and port == 80) or \
               ("https" in f["services"] and proto == "tcp" and port == 443)
    if st["active"] == "iptables":
        for m in re.finditer(r"-p (\w+)\b.*?--dport (\d+)(?::(\d+))?\b.*-j ACCEPT", st.get("_input", "")):
            if m.group(1) == proto and int(m.group(2)) <= port <= int(m.group(3) or m.group(2)):
                return True
        return False
    return None


def _check(port, proto, src):
    port = str(port).strip().replace(":", "-")
    m = PORT_RE.match(port)
    if not m or not (1 <= int(m.group(1)) <= 65535) or (m.group(2) and not int(m.group(1)) < int(m.group(2)) <= 65535):
        raise ValueError("Port must be 1-65535 or a range like 8000-8100")
    if proto not in ("tcp", "udp", "both"):
        raise ValueError("Protocol must be tcp, udp or both")
    src = str(src or "").strip()
    if src and not SRC_RE.match(src):
        raise ValueError("Source must be an IP address or network")
    return port, src


def _run(args):
    rc, out = host(args, timeout=60)
    if rc != 0:
        raise ValueError(f"{' '.join(args[:2])}: {out.strip()[-300:] or 'failed'}")
    return out


def allow(port, proto, src=""):
    """Opens a port in whichever firewall of the server is active. Returns what was done."""
    port, src = _check(port, proto, src)
    st = status()
    protos = ("tcp", "udp") if proto == "both" else (proto,)
    done = []
    if st["active"] == "ufw":
        for pr in protos:
            spec = port.replace("-", ":")
            args = ["ufw", "allow", "from", src, "to", "any", "port", spec, "proto", pr] if src else ["ufw", "allow", f"{spec}/{pr}"]
            _run(args)
            done.append(" ".join(args))
    elif st["active"] == "firewalld":
        for pr in protos:
            if src:
                rule = f'rule family="{"ipv6" if ":" in src else "ipv4"}" source address="{src}" port port="{port}" protocol="{pr}" accept'
                _run(["firewall-cmd", "--permanent", f"--add-rich-rule={rule}"])
            else:
                _run(["firewall-cmd", "--permanent", f"--add-port={port}/{pr}"])
            done.append(f"firewall-cmd --permanent --add-port={port}/{pr}")
        _run(["firewall-cmd", "--reload"])
    elif st["active"] == "iptables":
        for pr in protos:
            for tool in ("iptables", "ip6tables"):
                if src and (":" in src) != (tool == "ip6tables"):
                    continue
                args = [tool, "-I", "INPUT", "-p", pr, "--dport", port.replace("-", ":"), "-j", "ACCEPT"]
                if src:
                    args[3:3] = ["-s", src]
                rc, out = host(args, timeout=30)
                if rc == 0:
                    done.append(" ".join(args))
    return {"done": done, "firewall": st["active"]}


def remove(port, proto, src=""):
    """Closes a port opened by allow() again (only in the firewall that is active)."""
    port, src = _check(port, proto, src)
    st = status()
    protos = ("tcp", "udp") if proto == "both" else (proto,)
    done = []
    if st["active"] == "ufw":
        for pr in protos:
            spec = port.replace("-", ":")
            args = ["ufw", "delete", "allow", "from", src, "to", "any", "port", spec, "proto", pr] if src else ["ufw", "delete", "allow", f"{spec}/{pr}"]
            rc, out = host(args, timeout=60)
            if rc == 0:
                done.append(" ".join(args))
    elif st["active"] == "firewalld":
        for pr in protos:
            rc, _ = host(["firewall-cmd", "--permanent", f"--remove-port={port}/{pr}"], timeout=60)
            if rc == 0:
                done.append(f"firewall-cmd --permanent --remove-port={port}/{pr}")
        host(["firewall-cmd", "--reload"], timeout=60)
    elif st["active"] == "iptables":
        for pr in protos:
            for tool in ("iptables", "ip6tables"):
                args = [tool, "-D", "INPUT", "-p", pr, "--dport", port.replace("-", ":"), "-j", "ACCEPT"]
                if src:
                    args[3:3] = ["-s", src]
                if host(args, timeout=30)[0] == 0:
                    done.append(" ".join(args))
    return {"done": done, "firewall": st["active"]}


def ufw_delete(text):
    """Deletes the ufw rule shown as `text` (numbers shift after each delete, so they are looked up now)."""
    st = ufw_status()
    if not st.get("active"):
        raise ValueError("ufw is not active")
    rule = next((r for r in st["rules"] if r["text"] == text), None)
    if not rule:
        raise ValueError("That ufw rule no longer exists")
    _run(["ufw", "--force", "delete", str(rule["n"])])
    # ufw keeps an IPv4 and an IPv6 copy of most rules: remove the twin too, as `ufw delete allow X` would
    bare = lambda v: re.sub(r"\s*\(v6\)", "", v).strip()   # noqa: E731
    twin = next((r for r in ufw_status()["rules"] if r["v6"] != rule["v6"] and bare(r["to"]) == bare(rule["to"])
                 and bare(r["from"]) == bare(rule["from"]) and r["action"] == rule["action"] and r["dir"] == rule["dir"]), None)
    if twin:
        _run(["ufw", "--force", "delete", str(twin["n"])])
    return ufw_status()


def ufw_enable(keep_tcp):
    """Turns ufw on, after opening the SSH and panel ports (and anything else in keep_tcp) in it."""
    st = ufw_status()
    if not st.get("installed"):
        raise ValueError("ufw is not installed")
    for port in sorted(set(keep_tcp)):
        _run(["ufw", "allow", f"{int(port)}/tcp"])
    _run(["ufw", "--force", "enable"])
    return ufw_status()


def ufw_disable():
    _run(["ufw", "disable"])
    return ufw_status()
