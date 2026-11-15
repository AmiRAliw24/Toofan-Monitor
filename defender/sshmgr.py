"""SSH server management for the Firewall page: port, login options and root's authorized keys.

Every change is written to /etc/ssh/sshd_config.d/00-panel.conf (read first, so its values win), checked
with `sshd -t`, applied, and then every SSH port must answer with an SSH banner, or the previous files
come back at once. After that the change stays "pending" until the user confirms, from a new login,
that it works; without a confirmation it is undone after CONFIRM_SECONDS. Open sessions are never cut
(the ssh unit uses KillMode=process).
"""
import base64
import hashlib
import os
import re
import socket
import subprocess
import time

import hostinfo

HOSTCMD = ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "env",
           "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C"]
PANEL_CONF = "/etc/ssh/sshd_config.d/00-panel.conf"
MAIN_CONF = "/etc/ssh/sshd_config"
KEYS = "/root/.ssh/authorized_keys"
CONFIRM_SECONDS = int(os.environ.get("SSH_CONFIRM_SECONDS", "300"))   # time to log in again and keep a change
KEY_RE = re.compile(r"^(?:(?:[a-z0-9-]+(?:=\"[^\"]*\")?,?)+\s+)?((?:ssh-(?:ed25519|rsa|dss)|ecdsa-sha2-nistp(?:256|384|521)|sk-(?:ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com))\s+([A-Za-z0-9+/=]{40,})(?:\s+(.*))?$")
OPTIONS = {   # field -> (sshd keyword, allowed values or (min, max))
    "permit_root": ("PermitRootLogin", ("yes", "prohibit-password", "no")),
    "password": ("PasswordAuthentication", ("yes", "no")),
    "max_auth_tries": ("MaxAuthTries", (1, 50)),
    "login_grace": ("LoginGraceTime", (5, 600)),
    "idle_timeout": ("ClientAliveInterval", (0, 86400)),
    "x11": ("X11Forwarding", ("yes", "no")),
    "tcp_forwarding": ("AllowTcpForwarding", ("yes", "no", "local", "remote")),
}


def host(args, timeout=60):
    p = subprocess.run(HOSTCMD + args, capture_output=True, text=True, timeout=timeout)
    return p.returncode, (p.stdout + p.stderr).strip()


def _sshd(args, timeout=20):
    """sshd -t / -T need /run/sshd, which a socket-activated sshd only creates on its first connection."""
    host(["mkdir", "-p", "-m", "0755", "/run/sshd"], timeout=10)
    return host(["sshd"] + args, timeout=timeout)


def _read(rel):
    p = hostinfo.host_path(rel)
    return open(p).read() if os.path.exists(p) else None


def _write(rel, text):
    p = hostinfo.host_path(rel)
    if text is None:
        if os.path.exists(p):
            os.unlink(p)
        return
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(text)


# ------------------------------------------------------------------ state

def effective():
    """`sshd -T`: what sshd really uses after every file and default."""
    rc, out = _sshd(["-T"])
    if rc != 0:
        if "No such file" in out and "sshd" in out:
            raise ValueError("The OpenSSH server (sshd) is not installed on this server")
        raise ValueError(f"sshd -T failed: {out[-300:]}")
    conf = {}
    for line in out.splitlines():
        k, _, v = line.partition(" ")
        if k == "port":
            conf.setdefault("port", []).append(int(v))
        else:
            conf[k] = v
    return conf


def socket_mode():
    rc, out = host(["systemctl", "is-active", "ssh.socket"], timeout=10)
    return out.strip().splitlines()[-1:] == ["active"] if out else False


def keys():
    text = _read(KEYS) or ""
    out = []
    for i, line in enumerate(text.splitlines()):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = KEY_RE.match(line)
        if not m:
            out.append({"index": i, "type": "?", "comment": line[:40], "fingerprint": "", "valid": False})
            continue
        try:
            blob = base64.b64decode(m.group(2))
            fp = "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("=")
        except ValueError:
            fp = ""
        out.append({"index": i, "type": m.group(1), "comment": (m.group(3) or "").strip()[:80], "fingerprint": fp, "valid": bool(fp)})
    return out


def state(pending):
    try:
        eff = effective()
    except Exception as e:
        return {"error": str(e)}
    return {
        "ports": eff.get("port", [22]), "permit_root": eff.get("permitrootlogin"), "password": eff.get("passwordauthentication"),
        "max_auth_tries": int(eff.get("maxauthtries", 6)), "login_grace": int(eff.get("logingracetime", 120)),
        "idle_timeout": int(eff.get("clientaliveinterval", 0)), "x11": eff.get("x11forwarding"), "tcp_forwarding": eff.get("allowtcpforwarding"),
        "socket": socket_mode(), "keys": keys(), "panel_file": _read(PANEL_CONF) is not None,
        "pending": {"left": max(0, int(pending["until"] - time.time())), "ports": pending.get("ports")} if pending else None,
    }


# ------------------------------------------------------------------ applying

def render(settings):
    lines = ["# Managed by the Server Monitor panel (Firewall > SSH). Change these settings there.",
             "# Read before the other files, so these values win. Remove this file to go back to them."]
    for p in settings.get("ports") or []:
        lines.append(f"Port {int(p)}")
    for field, (kw, _) in OPTIONS.items():
        if settings.get(field) not in (None, ""):
            lines.append(f"{kw} {settings[field]}")
    if settings.get("password") == "no":
        lines.append("KbdInteractiveAuthentication no")
    return "\n".join(lines) + "\n"


def _comment_ports(text):
    """Other files' `Port` lines would add ports (they are cumulative), so they are commented out."""
    return re.sub(r"(?mi)^(\s*)(port\s+\d+)", r"\1# \2   # moved to 00-panel.conf by the panel", text)


def validate(settings, listening_ports):
    out = {}
    ports = sorted({int(p) for p in settings.get("ports") or []})
    if not ports or len(ports) > 5 or not all(1 <= p <= 65535 for p in ports):
        raise ValueError("Give one to five SSH ports between 1 and 65535")
    busy = [p for p in ports if p in listening_ports]
    if busy:
        raise ValueError(f"Port {busy[0]} is already used by another program")
    out["ports"] = ports
    for field, (_, allowed) in OPTIONS.items():
        v = settings.get(field)
        if v in (None, ""):
            continue
        if isinstance(allowed, tuple) and isinstance(allowed[0], int):
            v = int(v)
            if not allowed[0] <= v <= allowed[1]:
                raise ValueError(f"{field}: {allowed[0]} to {allowed[1]}")
        elif str(v) not in allowed:
            raise ValueError(f"{field}: one of {', '.join(allowed)}")
        out[field] = v
    if out.get("password") == "no" and not any(k["valid"] for k in keys()):
        raise ValueError("Add an SSH key first: without a key and without passwords nobody could log in")
    return out


def _restart():
    if socket_mode():   # Ubuntu 22.10+: ports live in ssh.socket, generated from sshd_config
        for cmd in (["systemctl", "stop", "ssh.service"], ["systemctl", "daemon-reload"], ["systemctl", "restart", "ssh.socket"]):
            rc, out = host(cmd, timeout=60)
            if rc != 0:
                return False, out
        return True, ""
    for unit in ("ssh", "sshd"):
        rc, out = host(["systemctl", "restart", unit], timeout=60)
        if rc == 0:
            return True, ""
    return False, out


def answers(port, timeout=8):
    """True when something on this port greets us like an SSH server."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=3) as s:
                if s.recv(64).startswith(b"SSH-"):
                    return True
        except OSError:
            pass
        time.sleep(0.5)
    return False


def apply(settings, before_restart=None):
    """Write + test + restart + check every port. Returns the files as they were (for a later undo)."""
    old = {rel: _read(rel) for rel in [PANEL_CONF, MAIN_CONF] + _dropins()}
    new = {PANEL_CONF: render(settings)}
    for rel in [MAIN_CONF] + _dropins():
        if old.get(rel) and re.search(r"(?mi)^\s*port\s+\d+", old[rel]):
            new[rel] = _comment_ports(old[rel])
    for rel, text in new.items():
        _write(rel, text)
    rc, out = _sshd(["-t"])
    if rc != 0:
        restore(old, restart=False)
        raise ValueError(f"sshd rejected the settings, nothing changed: {out[-400:]}")
    if before_restart:
        before_restart()    # the firewall opens the new ports first
    ok, err = _restart()
    bad = [p for p in settings["ports"] if not answers(p)] if ok else settings["ports"]
    if not ok or bad:
        restore(old)
        raise ValueError(f"SSH did not answer on port {bad[0] if bad else '?'} ({err[-200:] if err else 'no answer'}); "
                         "the previous settings are back")
    return old


def restore(old, restart=True):
    for rel, text in old.items():
        _write(rel, text)
    if restart:
        _restart()


def _dropins():
    d = hostinfo.host_path("/etc/ssh/sshd_config.d")
    try:
        return [f"/etc/ssh/sshd_config.d/{n}" for n in sorted(os.listdir(d)) if n.endswith(".conf") and n != "00-panel.conf"]
    except OSError:
        return []


# ------------------------------------------------------------------ authorized keys (root)

def add_key(line):
    line = " ".join(str(line).strip().split())
    m = KEY_RE.match(line)
    if not m:
        raise ValueError("This is not an SSH public key (it starts with ssh-ed25519, ssh-rsa or ecdsa-…)")
    try:
        base64.b64decode(m.group(2), validate=True)
    except ValueError:
        raise ValueError("The key is damaged (not valid base64)")
    text = _read(KEYS) or ""
    if m.group(2) in text:
        raise ValueError("This key is already there")
    d = hostinfo.host_path("/root/.ssh")
    os.makedirs(d, mode=0o700, exist_ok=True)
    _write(KEYS, (text if text.endswith("\n") or not text else text + "\n") + line + "\n")
    os.chmod(hostinfo.host_path(KEYS), 0o600)
    os.chmod(d, 0o700)
    return keys()


def remove_key(index, password_login):
    text = _read(KEYS) or ""
    lines = text.splitlines()
    if not 0 <= index < len(lines):
        raise ValueError("unknown key")
    remaining = [k for k in keys() if k["index"] != index and k["valid"]]
    if not remaining and password_login == "no":
        raise ValueError("This is the last key and password login is off: removing it would lock everyone out")
    del lines[index]
    _write(KEYS, "\n".join(lines) + ("\n" if lines else ""))
    return keys()
