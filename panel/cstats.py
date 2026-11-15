#!/usr/bin/env python3
"""CPU and memory of every Docker container, for Prometheus (replaces cAdvisor).

cAdvisor cannot talk to current Docker versions (the containerd image store), so it reported no
containers at all. This reads the same numbers straight from the kernel's cgroups, only when
Prometheus asks (every 30 s), with the metric names the container alerts already use:

  container_cpu_usage_seconds_total     CPU time used (counter)
  container_memory_working_set_bytes    memory in use, without reclaimable file cache
  container_memory_usage_bytes          memory in use, with file cache
  container_spec_memory_limit_bytes     the container's memory limit; the server's memory when it has none

Labels: id (the cgroup path, e.g. /system.slice/docker-<id>.scope) and name (the container name).
Works with cgroup v2 and v1, and with the systemd and cgroupfs drivers. Standard library only.
"""
import glob
import json
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CG = os.environ.get("CGROUP_ROOT", "/host/cgroup")
CONTAINERS = os.environ.get("DOCKER_CONTAINERS", "/host/containers")
PORT = int(os.environ.get("PORT", "9338"))
ID_RE = re.compile(r"docker[-/]([a-f0-9]{64})(?:\.scope)?$")
UNLIMITED = 1 << 60          # cgroup v1 reports "no limit" as a huge number
_names = {}


def read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def num(path):
    text = read(path)
    try:
        return int(text.strip()) if text and text.strip() != "max" else None
    except ValueError:
        return None


def stat(path, key):
    for line in (read(path) or "").splitlines():
        k, _, v = line.partition(" ")
        if k == key:
            return int(v)
    return None


def host_memory():
    m = re.search(r"^MemTotal:\s+(\d+) kB", read("/proc/meminfo") or "", re.M)
    return int(m.group(1)) * 1024 if m else 0


def name_of(cid):
    if cid not in _names:
        try:
            with open(os.path.join(CONTAINERS, cid, "config.v2.json")) as f:
                _names[cid] = json.load(f).get("Name", "").lstrip("/")
        except (OSError, ValueError):
            return ""
    return _names[cid]


def v2_containers():
    for pattern in ("system.slice/docker-*.scope", "docker/*"):
        for path in glob.glob(os.path.join(CG, pattern)):
            m = ID_RE.search(path)
            if m and os.path.isdir(path):
                rel = "/" + os.path.relpath(path, CG)
                usage = num(os.path.join(path, "memory.current"))
                yield {"id": rel, "cid": m.group(1), "cpu": (stat(os.path.join(path, "cpu.stat"), "usage_usec") or 0) / 1e6,
                       "usage": usage, "inactive": stat(os.path.join(path, "memory.stat"), "inactive_file") or 0,
                       "limit": num(os.path.join(path, "memory.max"))}


def v1_containers():
    cpu_root = next((d for d in ("cpuacct", "cpu,cpuacct", "cpu") if os.path.isdir(os.path.join(CG, d))), None)
    if not cpu_root:
        return
    for pattern in ("system.slice/docker-*.scope", "docker/*"):
        for path in glob.glob(os.path.join(CG, cpu_root, pattern)):
            m = ID_RE.search(path)
            if not (m and os.path.isdir(path)):
                continue
            rel = "/" + os.path.relpath(path, os.path.join(CG, cpu_root))
            mem = os.path.join(CG, "memory", rel.lstrip("/"))
            limit = num(os.path.join(mem, "memory.limit_in_bytes"))
            yield {"id": rel, "cid": m.group(1), "cpu": (num(os.path.join(path, "cpuacct.usage")) or 0) / 1e9,
                   "usage": num(os.path.join(mem, "memory.usage_in_bytes")),
                   "inactive": stat(os.path.join(mem, "memory.stat"), "total_inactive_file") or 0,
                   "limit": limit if limit and limit < UNLIMITED else None}


def esc(v):
    return v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def metrics():
    rows = list(v2_containers() if os.path.exists(os.path.join(CG, "cgroup.controllers")) else v1_containers())
    host = host_memory()
    out = {k: [] for k in ("cpu", "ws", "usage", "limit")}
    for r in rows:
        labels = f'{{id="{esc(r["id"])}",name="{esc(name_of(r["cid"]))}"}}'
        out["cpu"].append(f"container_cpu_usage_seconds_total{labels} {r['cpu']:.6f}")
        if r["usage"] is not None:
            out["usage"].append(f"container_memory_usage_bytes{labels} {r['usage']}")
            out["ws"].append(f"container_memory_working_set_bytes{labels} {max(0, r['usage'] - r['inactive'])}")
        limit = min(r["limit"], host) if r["limit"] and host else (r["limit"] or host)
        if limit:
            out["limit"].append(f"container_spec_memory_limit_bytes{labels} {limit}")
    live = {r["cid"] for r in rows}
    for cid in [c for c in _names if c not in live]:     # forget removed containers
        _names.pop(cid, None)
    head = [
        ("cpu", "container_cpu_usage_seconds_total", "counter", "CPU time used by the container, in seconds."),
        ("ws", "container_memory_working_set_bytes", "gauge", "Memory in use, without reclaimable file cache."),
        ("usage", "container_memory_usage_bytes", "gauge", "Memory in use, with file cache."),
        ("limit", "container_spec_memory_limit_bytes", "gauge", "Memory limit of the container (the server's memory when it has none)."),
    ]
    text = []
    for key, name, kind, help_ in head:
        text += [f"# HELP {name} {help_}", f"# TYPE {name} {kind}"] + out[key]
    text += ["# HELP container_exporter_containers Containers found.", "# TYPE container_exporter_containers gauge",
             f"container_exporter_containers {len(rows)}"]
    return "\n".join(text) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?")[0] not in ("/metrics", "/"):
            self.send_error(404)
            return
        body = metrics().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):   # Prometheus asks every 30 s: no log line for that
        pass


if __name__ == "__main__":
    print(f"container stats on :{PORT} (cgroups at {CG})", flush=True)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
