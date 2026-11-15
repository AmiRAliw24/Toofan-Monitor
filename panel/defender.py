"""Panel side of the Firewall (the "defender" service): talks to its agent (defender/agent.py) over a
unix socket and sends Telegram messages about attacks and bans. The agent does the privileged work;
the panel never touches the firewall itself.
"""
import http.client
import json
import os
import re
import socket
import threading
import time
from urllib.parse import quote

import monitor
import store

SOCK = os.environ.get("DEFENDER_SOCKET", "/defender/agent.sock")
GET_PATHS = {"status", "live", "bans", "ports", "audit", "talkers", "events", "rules", "fwrules", "ssh",
             "f2b", "f2b/bans", "f2b/log", "f2b/jail", "f2b/files", "f2b/file", "geo", "export", "sshd", "threat"}
POST_PATHS = {"config", "confirm", "revert", "block", "unblock", "allow", "unallow", "unban", "sysctl",
              "f2b/service", "f2b/install", "f2b/uninstall", "f2b/jail", "f2b/jail/delete", "f2b/defaults", "f2b/ban", "f2b/unban",
              "f2b/file", "f2b/file/delete", "import", "sshd/apply", "sshd/confirm", "sshd/revert", "sshd/key/add",
              "sshd/key/remove", "test"}
NOT_RUNNING = ("The firewall service (defender) is not running. On the server run: "
               "cd /opt/server-monitoring && docker compose up -d --build defender")
JAIL_RE = re.compile(r"^[A-Za-z0-9_.\-]{1,40}$")
PATH_RE = re.compile(r"^[A-Za-z0-9_.\-/]{1,120}$")


class AgentError(Exception):
    """The agent cannot be reached (not installed, stopped, starting)."""


class _Conn(http.client.HTTPConnection):
    def __init__(self, timeout):
        super().__init__("localhost", timeout=timeout)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(SOCK)


def _query(params):
    """Only the query parameters the agent knows, checked here as well."""
    params = params or {}
    out = []
    if str(params.get("since", "")).replace(".", "", 1).isdigit():
        out.append(f"since={params['since']}")
    if JAIL_RE.match(str(params.get("jail", ""))):
        out.append(f"jail={params['jail']}")
    if PATH_RE.match(str(params.get("path", ""))):
        out.append(f"path={quote(params['path'], safe='')}")
    return "&".join(out)


def call(method, path, body=None, params=None, timeout=60):
    qs = _query(params)
    conn = _Conn(timeout)
    try:
        payload = json.dumps(body).encode() if body is not None else None
        conn.request(method, f"/{path}" + (f"?{qs}" if qs else ""), body=payload,
                     headers={"Content-Type": "application/json"} if payload else {})
        resp = conn.getresponse()
        data = json.loads(resp.read() or b"{}")
    except (FileNotFoundError, ConnectionRefusedError, PermissionError, socket.timeout, OSError) as e:
        raise AgentError(NOT_RUNNING if not isinstance(e, socket.timeout) else "The firewall service did not answer in time") from e
    finally:
        conn.close()
    if resp.status == 400:
        raise ValueError(data.get("error", "bad request"))
    if resp.status >= 300:
        raise RuntimeError(data.get("error", f"agent error {resp.status}"))
    return data


def get(name, params):
    if name not in GET_PATHS:
        raise KeyError("not found")
    return call("GET", name, params=params)


def post(name, body):
    if name not in POST_PATHS:
        raise KeyError("not found")
    return call("POST", name, body=body, timeout=120)


# ------------------------------------------------------------------ Telegram notifications

def _send(text):
    tg = store.load_settings().get("telegram") or {}
    if tg.get("token") and tg.get("chat_id"):
        store._telegram(tg["token"], "sendMessage", {"chat_id": tg["chat_id"], "text": text})


def _fmt(n):
    n = float(n or 0)
    for unit in ("", "K", "M"):
        if abs(n) < 1000:
            return f"{n:.0f}{unit}"
        n /= 1000
    return f"{n:.1f}G"


SHIELD = "\U0001F6E1"


def _message(e, host, enabled=True):
    k = e["kind"]
    head = f"{SHIELD} Firewall · {host}\n"
    if k == "attack_start":
        top = ", ".join(e.get("top") or []) or "-"
        return (f"{SHIELD}\U0001F6A8 Firewall · {host}\nAttack detected ({e.get('reason', '')}): {_fmt(e.get('pps'))} packets/s, "
                f"{_fmt(e.get('drop'))} blocked/s.\nTop sources: {top}\n"
                + ("حمله شناسایی شد؛ فایروال در حال دفع آن است." if enabled else
                   "Protection is OFF. حمله شناسایی شد ولی محافظت خاموش است؛ از صفحه‌ی فایروال روشنش کنید."))
    if k == "attack_end":
        peak = e.get("peak") or {}
        return (f"{SHIELD}✅ Firewall · {host}\nAttack ended after {int(e.get('seconds', 0)) // 60} min "
                f"(peak {_fmt(peak.get('pps'))} packets/s, {_fmt(peak.get('drop'))} blocked/s).\nحمله تمام شد.")
    if k == "escalate":
        return head + "\"Under attack\" limits switched on automatically.\nحالت «زیر حمله» خودکار فعال شد."
    if k == "ssh_ban":
        return head + f"SSH brute force from {e.get('ip')} ({e.get('failures')} failures): banned for {e.get('minutes')} min."
    if k == "f2b_ban" and not e.get("manual"):
        return head + f"fail2ban [{e.get('jail')}] banned {e.get('ip')}."
    return None


def _host_label():
    ip = (monitor.public_ip() or {}).get("v4")
    return ip or socket.gethostname()


def notify_loop():
    last = None
    while True:
        time.sleep(10)
        try:
            st = call("GET", "status", timeout=10)
            if last is None:
                last = st.get("last_event", 0)   # never re-send what happened before the panel started
                continue
            rows = call("GET", "events", params={"since": last}, timeout=10).get("rows", [])
            notify = (st.get("config") or {}).get("notify") or {}
            for e in rows:
                last = max(last, e["id"])
                if e["kind"] in ("attack_start", "attack_end", "escalate"):
                    wanted = notify.get("attacks", True)
                else:
                    wanted = notify.get("bans", False) and e["kind"] in ("ssh_ban", "f2b_ban")
                text = _message(e, _host_label(), st.get("enabled", False)) if wanted else None
                if text:
                    try:
                        _send(text)
                    except Exception as err:   # Telegram down or not configured: the panel keeps working
                        print("firewall notify:", err, flush=True)
        except (AgentError, ValueError, RuntimeError):
            continue
        except Exception as err:
            print("firewall notify loop:", type(err).__name__, err, flush=True)


def start():
    threading.Thread(target=notify_loop, name="firewall-notify", daemon=True).start()
