"""fail2ban management for the Firewall page: install / remove, service control, jails, bans, settings.

Reads and bans go straight to fail2ban's own control socket (the protocol fail2ban-client speaks), so
the page is fast. Installing, removing and the service itself run on the host through nsenter, with
fixed commands only. Settings the panel changes go to one file, jail.d/zzz-panel.local, which loads
after every other file and holds only the values changed here; each change is checked with
`fail2ban-client -t` first and the previous file is put back if the check fails.
"""
import ipaddress
import os
import pickle
import re
import socket
import subprocess
import threading
import time

import hostinfo

HOSTCMD = ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "env",
           "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "DEBIAN_FRONTEND=noninteractive", "LC_ALL=C"]
SOCK = hostinfo.host_path("/run/fail2ban/fail2ban.sock")
PANEL_FILE = "/etc/fail2ban/jail.d/zzz-panel.local"
LOG = "/var/log/fail2ban.log"
END, CLOSE = b"<F2B_END_COMMAND>", b"<F2B_CLOSE_COMMAND>"
NAME_RE = re.compile(r"^[A-Za-z0-9_.\-]{1,40}$")
DUR_RE = re.compile(r"^(-1|\d{1,7}(s|m|h|d|w|mo|y)?)$")

# Protections a beginner can turn on with one switch. `log` is where the service writes (only offered
# when it exists on this server); file-based jails need backend=auto (Debian defaults to systemd).
PRESETS = {
    "sshd": {"log": None, "auto": False},
    "recidive": {"log": "/var/log/fail2ban.log", "auto": True, "defaults": {"bantime": "1w", "findtime": "1d", "maxretry": "3"}},
    "nginx-http-auth": {"log": "/var/log/nginx/error.log", "auto": True},
    "nginx-botsearch": {"log": "/var/log/nginx/access.log", "auto": True},
    "nginx-bad-request": {"log": "/var/log/nginx/access.log", "auto": True},
    "nginx-limit-req": {"log": "/var/log/nginx/error.log", "auto": True},
    "apache-auth": {"log": "/var/log/apache2/error.log", "auto": True},
    "apache-badbots": {"log": "/var/log/apache2/access.log", "auto": True},
    "postfix": {"log": "/var/log/mail.log", "auto": True},
    "dovecot": {"log": "/var/log/mail.log", "auto": True},
    "vsftpd": {"log": "/var/log/vsftpd.log", "auto": True},
    "mysqld-auth": {"log": "/var/log/mysql/error.log", "auto": True},
}
DEFAULT_KEYS = ("bantime", "findtime", "maxretry", "bantime.increment", "bantime.maxtime", "ignoreip")
JAIL_KEYS = ("enabled", "bantime", "findtime", "maxretry")


def host(args, timeout=60):
    p = subprocess.run(HOSTCMD + args, capture_output=True, text=True, timeout=timeout)
    return p.returncode, (p.stdout + p.stderr).strip()


# ------------------------------------------------------------------ fail2ban's control socket

def call(*cmd, timeout=8):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(SOCK)
        s.sendall(pickle.dumps([str(c) for c in cmd], pickle.HIGHEST_PROTOCOL) + END)
        data = b""
        while not data.endswith(END):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
        try:
            s.sendall(CLOSE)
        except OSError:
            pass
    finally:
        s.close()
    code, result = pickle.loads(data[:-len(END)] if data.endswith(END) else data)   # the server is root on this host
    if code != 0:
        raise ValueError(str(result))
    return result


def running():
    try:
        return call("ping", timeout=3) == "pong"
    except (OSError, ValueError, pickle.UnpicklingError, EOFError):
        return False


def _pairs(x):
    """fail2ban's status answers are nested (key, value) lists; flatten them into a dict."""
    out = {}
    for item in x or []:
        if isinstance(item, (list, tuple)) and len(item) == 2:
            k, v = item
            if isinstance(v, list) and v and all(isinstance(i, (list, tuple)) and len(i) == 2 for i in v):
                out.update(_pairs(v))
            else:
                out[k] = v
    return out


def jail_names():
    st = _pairs(call("status"))
    return [j.strip() for j in str(st.get("Jail list", "")).split(",") if j.strip()]


def jail_info(name):
    st = _pairs(call("status", name))
    info = {"name": name, "failed": st.get("Currently failed", 0), "failed_total": st.get("Total failed", 0),
            "banned": st.get("Currently banned", 0), "banned_total": st.get("Total banned", 0)}
    for k in ("maxretry", "findtime", "bantime"):
        try:
            info[k] = call("get", name, k)
        except Exception:
            info[k] = None
    try:
        info["ignoreip"] = [str(i) for i in call("get", name, "ignoreip")]
    except Exception:
        info["ignoreip"] = []
    files = st.get("File list") or []
    info["source"] = "journal" if "Journal matches" in st else ", ".join(files) if isinstance(files, list) else str(files)
    return info


def jail_bans(name):
    """[{ip, until}] - with the end time when fail2ban can tell it."""
    rows = []
    try:
        for line in call("get", name, "banip", "--with-time"):
            m = re.match(r"(\S+)\s+(\S+ \S+) \+ (-?\d+) = (\S+ \S+)", str(line))
            if m:
                until = time.mktime(time.strptime(m.group(4), "%Y-%m-%d %H:%M:%S")) if m.group(3) != "-1" else None
                rows.append({"ip": m.group(1), "until": until})
            else:
                rows.append({"ip": str(line).split()[0], "until": None})
    except Exception:
        st = _pairs(call("status", name))
        rows = [{"ip": ip, "until": None} for ip in (st.get("Banned IP list") or [])]
    return rows


def all_bans():
    out = []
    if not running():
        return out
    for j in jail_names():
        for r in jail_bans(j):
            out.append({**r, "jail": j})
    return out


# ------------------------------------------------------------------ installation and service

def package_manager():
    for pm, path in (("apt", "/usr/bin/apt-get"), ("dnf", "/usr/bin/dnf"), ("yum", "/usr/bin/yum")):
        if os.path.exists(hostinfo.host_path(path)):
            return pm
    return None


def installed():
    return any(os.path.exists(hostinfo.host_path(p)) for p in ("/usr/bin/fail2ban-client", "/usr/local/bin/fail2ban-client"))


JOB = {"id": 0, "action": "", "running": False, "ok": None, "log": "", "started": 0, "ended": 0}
_job_lock = threading.Lock()


def _run_job(action, steps):
    with _job_lock:
        if JOB["running"]:
            raise ValueError("Another fail2ban task is still running")
        JOB.update(id=JOB["id"] + 1, action=action, running=True, ok=None, log="", started=time.time(), ended=0)

    def work():
        ok = True
        for args in steps:
            JOB["log"] += f"$ {' '.join(args)}\n"
            try:
                p = subprocess.Popen(HOSTCMD + args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                for line in p.stdout:
                    JOB["log"] = (JOB["log"] + line)[-20000:]
                rc = p.wait(timeout=900)
            except Exception as e:
                JOB["log"] += f"{type(e).__name__}: {e}\n"
                rc = 1
            if rc != 0:
                JOB["log"] += f"(exit code {rc})\n"
                ok = False
                break
        JOB.update(running=False, ok=ok, ended=time.time())
        _cache["at"] = 0   # installed / running changed: the next overview reads them again

    threading.Thread(target=work, daemon=True).start()
    return dict(JOB)


def has_systemd():
    return any(os.path.exists(hostinfo.host_path(p)) for p in ("/usr/bin/systemctl", "/bin/systemctl")) and         os.path.isdir(hostinfo.host_path("/run/systemd/system"))


def _start_step():
    return ["systemctl", "enable", "--now", "fail2ban"] if has_systemd() else ["fail2ban-client", "start"]


def install():
    pm = package_manager()
    if installed():
        raise ValueError("fail2ban is already installed")
    if pm == "apt":
        steps = [["apt-get", "update", "-q"], ["apt-get", "install", "-y", "-q", "fail2ban"], _start_step()]
    elif pm in ("dnf", "yum"):
        steps = [[pm, "install", "-y", "epel-release"], [pm, "install", "-y", "fail2ban"], _start_step()]
    else:
        raise ValueError("No supported package manager (apt, dnf, yum) on this server")
    return _run_job("install", steps)


def uninstall(purge=False):
    pm = package_manager()
    if not installed():
        raise ValueError("fail2ban is not installed")
    stop = ["systemctl", "disable", "--now", "fail2ban"] if has_systemd() else ["sh", "-c", "fail2ban-client stop || true"]
    if pm == "apt":
        steps = [stop, ["apt-get", "purge" if purge else "remove", "-y", "-q", "fail2ban"]]
    elif pm in ("dnf", "yum"):
        steps = [stop, [pm, "remove", "-y", "fail2ban"]]
    else:
        raise ValueError("No supported package manager on this server")
    return _run_job("uninstall", steps)


SERVICE_ACTIONS = {"start": ["systemctl", "start", "fail2ban"], "stop": ["systemctl", "stop", "fail2ban"],
                   "restart": ["systemctl", "restart", "fail2ban"], "enable": ["systemctl", "enable", "fail2ban"],
                   "disable": ["systemctl", "disable", "fail2ban"]}


def service(action):
    if action == "reload":
        if not running():
            raise ValueError("fail2ban is not running")
        reload()
        return
    if action not in SERVICE_ACTIONS:
        raise ValueError("unknown action")
    cmd = SERVICE_ACTIONS[action]
    if not has_systemd():   # containers and old init systems: drive the server directly
        if action in ("enable", "disable"):
            raise ValueError("Starting at boot needs systemd, which this server does not use")
        cmd = {"start": ["fail2ban-client", "start"], "stop": ["fail2ban-client", "stop"], "restart": ["fail2ban-client", "restart"]}[action]
    rc, out = host(cmd, timeout=90)
    if rc != 0:
        raise ValueError(out[-600:] or f"systemctl failed ({rc})")


def reload():
    """fail2ban-client reads the configuration itself and hands it to the server, so a reload has to go
    through it (the raw socket command needs the parsed configuration)."""
    rc, out = host(["fail2ban-client", "reload"], timeout=120)
    if rc != 0:
        raise ValueError(f"fail2ban could not reload: {out[-600:]}")


def unit_state():
    if not has_systemd():
        return ("active" if running() else "inactive"), "n/a"
    rc, active = host(["systemctl", "is-active", "fail2ban"], timeout=15)
    rc2, boot = host(["systemctl", "is-enabled", "fail2ban"], timeout=15)
    return active.splitlines()[-1] if active else "", boot.splitlines()[-1] if boot else ""


# ------------------------------------------------------------------ settings the panel manages

def _dur(v):
    v = str(v).strip().lower()
    if not DUR_RE.match(v):
        raise ValueError(f"Invalid duration: {v} (for example 10m, 1h, 1d, 1w or -1 for forever)")
    return v


def validate(managed):
    d = managed.setdefault("default", {})
    for k in list(d):
        if k not in DEFAULT_KEYS:
            del d[k]
    for k in ("bantime", "findtime", "bantime.maxtime"):
        if k in d:
            d[k] = _dur(d[k])
    if "maxretry" in d:
        d["maxretry"] = str(max(1, min(100, int(d["maxretry"]))))
    if "bantime.increment" in d:
        d["bantime.increment"] = bool(d["bantime.increment"])
    if "ignoreip" in d:
        ips = []
        for ip in d["ignoreip"]:
            ips.append(str(ipaddress.ip_network(str(ip).strip(), strict=False)))
        d["ignoreip"] = sorted(set(ips), key=lambda x: (":" in x, x))[:200]
    jails = managed.setdefault("jails", {})
    for name, j in list(jails.items()):
        if not NAME_RE.match(name):
            raise ValueError(f"invalid jail name: {name}")
        for k in list(j):
            if k not in JAIL_KEYS:
                del j[k]
        if "enabled" in j:
            j["enabled"] = bool(j["enabled"])
        for k in ("bantime", "findtime"):
            if k in j:
                j[k] = _dur(j[k])
        if "maxretry" in j:
            j["maxretry"] = str(max(1, min(100, int(j["maxretry"]))))
    return managed


def render(managed):
    lines = ["# Managed by the Server Monitor panel (Firewall > fail2ban). Change these settings there:",
             "# this file is rewritten on every save. Your other files in jail.d are left alone.", ""]
    d = managed.get("default", {})
    if d:
        lines.append("[DEFAULT]")
        for k in DEFAULT_KEYS:
            if k in d:
                v = d[k]
                v = "true" if v is True else "false" if v is False else " ".join(v) if isinstance(v, list) else v
                lines.append(f"{k} = {v}")
        lines.append("")
    for name, j in sorted(managed.get("jails", {}).items()):
        if not j:
            continue
        lines.append(f"[{name}]")
        preset = PRESETS.get(name, {})
        if j.get("enabled") and preset.get("auto"):
            lines.append("backend = auto")
            if preset.get("log"):
                lines.append(f"logpath = {preset['log']}")
            for k, v in (preset.get("defaults") or {}).items():
                if k not in j:
                    lines.append(f"{k} = {v}")
        for k in JAIL_KEYS:
            if k in j:
                v = j[k]
                lines.append(f"{k} = {'true' if v is True else 'false' if v is False else v}")
        lines.append("")
    return "\n".join(lines) + "\n"


def write_settings(managed):
    """Write, test, reload. On a failed test the previous file comes back and nothing changes."""
    path = hostinfo.host_path(PANEL_FILE)
    old = None
    if os.path.exists(path):
        with open(path) as f:
            old = f.read()
    with open(path, "w") as f:
        f.write(render(managed))
    rc, out = host(["fail2ban-client", "-t"], timeout=60)
    if rc != 0:
        if old is None:
            os.unlink(path)
        else:
            with open(path, "w") as f:
                f.write(old)
        lines = [ln for ln in out.splitlines() if "ERROR" in ln or "rror" in ln] or out.splitlines()
        raise ValueError("fail2ban rejected the settings, nothing changed: " + " / ".join(lines[-3:])[-600:])
    if running():
        reload()


# ------------------------------------------------------------------ overview for the panel

_cache = {"at": 0, "data": None}


def overview(managed, force=False):
    if not force and _cache["data"] and time.time() - _cache["at"] < 5:
        return {**_cache["data"], "job": dict(JOB)}
    inst = installed()
    data = {"installed": inst, "pm": package_manager(), "running": False, "active": "", "boot": "",
            "version": "", "jails": [], "available": [], "managed": managed, "log": os.path.exists(hostinfo.host_path(LOG))}
    if inst:
        data["active"], data["boot"] = unit_state()
        data["running"] = running()
    names = []
    if data["running"]:
        try:
            data["version"] = str(call("version"))
            names = jail_names()
            data["jails"] = [jail_info(n) for n in names]
        except Exception as e:
            data["error"] = str(e)
    if inst:
        for name, p in PRESETS.items():
            if name in names:
                continue
            if p["log"] is None or os.path.exists(hostinfo.host_path(p["log"])):
                data["available"].append({"name": name})
    _cache.update(at=time.time(), data=data)
    return {**data, "job": dict(JOB)}


def log_tail(lines=150):
    text = hostinfo.read(LOG, 5_000_000) or ""
    return "\n".join(text.splitlines()[-lines:])


BAN_LINE = re.compile(r"NOTICE\s+\[([^\]]+)\]\s+Ban\s+(\S+)")


def watch_log(on_ban):
    """Calls on_ban(jail, ip) for every new ban in fail2ban's log (for the activity feed)."""
    path = hostinfo.host_path(LOG)
    f, inode = None, None
    while True:
        try:
            st = os.stat(path)
            if f is None or st.st_ino != inode or st.st_size < f.tell():
                if f:
                    f.close()
                f = open(path, errors="replace")
                if inode is None:
                    f.seek(0, os.SEEK_END)
                inode = st.st_ino
            for line in f.readlines():
                m = BAN_LINE.search(line)
                if m:
                    on_ban(m.group(1), m.group(2))
        except OSError:
            f, inode = None, None
        time.sleep(2)
