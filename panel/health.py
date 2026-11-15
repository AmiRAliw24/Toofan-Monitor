"""Self-diagnosis for the panel: why can't it load data? Answers with facts, not guesses.

Checks each backend service (DNS first, then HTTP), whether Docker's own DNS can reach the outside,
free disk space, and the state of every container of the stack (exit code, restarts, last log lines).
"""
import os
import shutil
import socket
import time
from urllib.parse import urlparse
from urllib.request import urlopen

import dockerapi
import store
import monitor

SERVICES = [
    ("prometheus", monitor.PROM, "/-/ready"),
    ("alertmanager", store.AM_URL, "/-/ready"),
    ("blackbox", store.BLACKBOX_URL, "/-/healthy"),
]


def _check(name, base, path):
    host = urlparse(base).hostname
    out = {"service": name, "url": base, "ok": False, "stage": "dns", "error": "", "ms": None}
    try:
        socket.getaddrinfo(host, None)
    except OSError as e:
        out["error"] = f"{e.errno}: {e.strerror or e}"
        return out
    out["stage"] = "http"
    t0 = time.time()
    try:
        with urlopen(base + path, timeout=5) as resp:
            out["ok"] = resp.status == 200
            out["error"] = "" if out["ok"] else f"HTTP {resp.status}"
    except Exception as e:
        out["error"] = f"{type(e).__name__}: {e}"
    out["ms"] = round((time.time() - t0) * 1000)
    return out


def _external_dns():
    try:
        socket.getaddrinfo("prometheus.io", 443)
        return {"ok": True, "error": ""}
    except OSError as e:
        return {"ok": False, "error": f"{e.errno}: {e.strerror or e}"}


def _disk():
    try:
        u = shutil.disk_usage(os.environ.get("DATA_DIR", "/data"))
        return {"total": u.total, "free": u.free, "pct": (u.total - u.free) / u.total * 100}
    except OSError:
        return None


def diagnose():
    services = [_check(*s) for s in SERVICES]
    out = {"services": services, "dns_external": _external_dns(), "disk": _disk(), "containers": None, "logs": {}, "hints": []}
    try:
        if dockerapi.available():
            out["containers"] = dockerapi.stack_health()
    except dockerapi.DockerError:
        pass
    by_service = {c["service"]: c for c in out["containers"] or []}
    for c in out["containers"] or []:
        if c["state"] != "running" and c["service"] != "hostip" or c["state"] == "restarting":
            try:
                out["logs"][c["service"]] = dockerapi.logs(c["id"], 25)["text"]
            except Exception:
                pass
    hints = out["hints"]
    for s in services:
        if s["ok"]:
            continue
        c = by_service.get(s["service"])
        if c and c["state"] != "running":
            why = f"exit code {c['exit_code']}" + (", killed for lack of memory (OOM)" if c["oom"] else "") + (f", {c['error']}" if c["error"] else "")
            hints.append({"kind": "stopped", "service": s["service"], "detail": f"{c['state']} ({why}), restarted {c['restarts']} time(s)"})
        elif s["stage"] == "dns":
            hints.append({"kind": "dns", "service": s["service"], "detail": s["error"]})
        else:
            hints.append({"kind": "svc", "service": s["service"], "detail": s["error"]})
    if out["disk"] and out["disk"]["pct"] >= 95:
        hints.append({"kind": "disk", "service": "", "detail": f"{out['disk']['pct']:.0f}%"})
    if any(h["kind"] == "dns" for h in hints) and not out["dns_external"]["ok"]:
        hints.append({"kind": "dns_external", "service": "", "detail": out["dns_external"]["error"]})
    return out
