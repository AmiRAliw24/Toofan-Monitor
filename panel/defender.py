"""Panel side of the Defender: talks to the agent (defender/agent.py) over its unix socket and sends
Telegram messages about attacks. The agent does the privileged work; the panel never touches the
firewall itself.
"""
import http.client
import json
import os
import socket
import threading
import time

import store

SOCK = os.environ.get("DEFENDER_SOCKET", "/defender/agent.sock")
GET_PATHS = {"status", "live", "bans", "ports", "audit", "talkers", "events", "rules", "ssh"}
POST_PATHS = {"config", "confirm", "revert", "block", "unblock", "allow", "unallow", "unban", "sysctl"}
NOT_RUNNING = ("The Defender agent is not running. On the server run: "
               "cd /opt/server-monitoring && docker compose up -d defender")


class AgentError(Exception):
    """The agent cannot be reached (not installed, stopped, starting)."""


class _Conn(http.client.HTTPConnection):
    def __init__(self, timeout):
        super().__init__("localhost", timeout=timeout)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(SOCK)


def call(method, path, body=None, params=None, timeout=30):
    qs = "&".join(f"{k}={v}" for k, v in (params or {}).items() if k in ("since",) and str(v).replace(".", "").isdigit())
    conn = _Conn(timeout)
    try:
        payload = json.dumps(body).encode() if body is not None else None
        conn.request(method, f"/{path}" + (f"?{qs}" if qs else ""), body=payload,
                     headers={"Content-Type": "application/json"} if payload else {})
        resp = conn.getresponse()
        data = json.loads(resp.read() or b"{}")
    except (FileNotFoundError, ConnectionRefusedError, PermissionError, socket.timeout, OSError) as e:
        raise AgentError(NOT_RUNNING if not isinstance(e, socket.timeout) else "The Defender agent did not answer in time") from e
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
    return call("POST", name, body=body)


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


def _message(e, host, enabled=True):
    k = e["kind"]
    if k == "attack_start":
        top = ", ".join(e.get("top") or []) or "-"
        return (f"🛡🚨 Defender · {host}\nAttack detected ({e.get('reason', '')}): {_fmt(e.get('pps'))} packets/s, "
                f"{_fmt(e.get('drop'))} blocked/s.\nTop sources: {top}\n"
                + ("حمله شناسایی شد؛ دیفندر در حال دفع آن است." if enabled else
                   "Protection is OFF. حمله شناسایی شد ولی محافظت خاموش است؛ از صفحه‌ی دیفندر روشنش کنید."))
    if k == "attack_end":
        peak = e.get("peak") or {}
        return (f"🛡✅ Defender · {host}\nAttack ended after {int(e.get('seconds', 0)) // 60} min "
                f"(peak {_fmt(peak.get('pps'))} packets/s, {_fmt(peak.get('drop'))} blocked/s).\nحمله تمام شد.")
    if k == "escalate":
        return f"🛡⚠️ Defender · {host}\n\"Under attack\" limits switched on automatically.\nحالت «زیر حمله» خودکار فعال شد."
    if k == "ssh_ban":
        return f"🛡 Defender · {host}\nSSH brute force from {e.get('ip')} ({e.get('failures')} failures): banned for {e.get('minutes')} min."
    return None


def notify_loop():
    last = None
    host = socket.gethostname()
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
                wanted = notify.get("attacks", True) if e["kind"] in ("attack_start", "attack_end", "escalate") else \
                    notify.get("bans", False) if e["kind"] == "ssh_ban" else False
                text = _message(e, host, st.get("enabled", False)) if wanted else None
                if text:
                    try:
                        _send(text)
                    except Exception as err:   # Telegram down or not configured: the panel keeps working
                        print("defender notify:", err, flush=True)
        except (AgentError, ValueError, RuntimeError):
            continue
        except Exception as err:
            print("defender notify loop:", type(err).__name__, err, flush=True)


def start():
    threading.Thread(target=notify_loop, name="defender-notify", daemon=True).start()
