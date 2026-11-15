#!/usr/bin/env python3
"""Monitoring panel backend: login, static files, a read-only JSON API over Prometheus, and the
management API (sites, servers, alert rules, Telegram, password), a live one-second stream (live.py) and
the Defender (firewall / anti-DDoS, proxied to its agent, see defender.py).

Standard library only. Anything that changes state needs the session cookie, a JSON body and the
X-Panel header (a cross-site page cannot send that header), and is checked against the Origin.
"""
import gzip
import hashlib
import json
import os
import secrets
import sys
import threading
import time
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import defender
import dockerapi
import health
import icons
import live
import monitor
import security
import store
from auth import Auth
from security import guard, limiter, sessions, totp
from security import log as seclog
from security import settings as secsettings

USER = os.environ.get("PANEL_USER", "admin")
PASSWORD = os.environ.get("PANEL_PASSWORD", "")
PORT = int(os.environ.get("PANEL_LISTEN_PORT", "8080"))
STATIC = Path(__file__).parent / "static"
_static_cache = {}
_static_lock = threading.Lock()


def static_file(name):
    """(version, raw, gzipped or None, etag) of a file in static/, cached in memory by mtime and size."""
    st = (STATIC / name).stat()
    version = (st.st_mtime_ns, st.st_size)
    hit = _static_cache.get(name)
    if hit and hit[0] == version:
        return hit
    with _static_lock:
        raw = (STATIC / name).read_bytes()
        packed = gzip.compress(raw, 9, mtime=0) if len(raw) > 1024 else None
        hit = _static_cache[name] = (version, raw, packed, '"%s"' % hashlib.sha256(raw).hexdigest()[:20])
        return hit
COOKIE = "panel_session"
VERSION = "2.2"
SESSION_TTL = security.SESSION_MAX
TRUST_PROXY = os.environ.get("PANEL_TRUST_PROXY", "0") == "1"   # behind your own reverse proxy: use X-Forwarded-For
BIG_BODY = {"/api/defender/import", "/api/defender/f2b/file", "/api/defender/config"}
LIVE_MAX_SECONDS = 15 * 60   # a live stream is closed after this long; the browser reconnects at once

if not PASSWORD:
    sys.exit("PANEL_PASSWORD must be set")

auth = Auth(USER, PASSWORD, store.DATA)

PUBLIC_FILES = {
    "/login": ("login.html", "text/html; charset=utf-8"),
    "/login.js": ("login.js", "text/javascript; charset=utf-8"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
    "/fonts.css": ("fonts.css", "text/css; charset=utf-8"),
    "/favicon.svg": ("favicon.svg", "image/svg+xml"),
    "/boot.js": ("boot.js", "text/javascript; charset=utf-8"),
}
PRIVATE_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/defender.js": ("defender.js", "text/javascript; charset=utf-8"),
    "/security.js": ("security.js", "text/javascript; charset=utf-8"),
}
# Generated icons, served without a login so a browser tab can always show them.
ICONS = {
    "/favicon.ico": (icons.ico, "image/x-icon"),
    "/favicon-32.png": (lambda: icons.png(32), "image/png"),
    "/apple-touch-icon.png": (lambda: icons.png(180), "image/png"),
}

CSP = ("default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
       "img-src 'self' data:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
WRITE_HINT = ("The panel cannot write its configuration files (permission denied). On the server run: "
              "chown -R 65534:65534 /opt/server-monitoring/data /opt/server-monitoring/prometheus/targets "
              "/opt/server-monitoring/prometheus/rules /opt/server-monitoring/alertmanager")

# Failed logins are handled per address in security.py: a short random delay, a lock after 5 failures
# in 15 minutes (doubling up to a day), and a firewall ban for persistent guessers. Docker passes the real
# client address to published ports, so one attacker cannot lock the real user out.


class BadRequest(ValueError):
    pass


# ------------------------------------------------------------------ read API

def api_checks(_q):
    return {**{k: store.list_targets(k) for k in store.KINDS}, "auto": {"enabled": store.auto_enabled(), "events": store.auto_events()}}


def api_rules(_q):
    return {"rules": store.get_rules()}


def api_settings(_q):
    return {"user": auth.user, "version": VERSION, "auto_fix": store.auto_enabled(),
            "docker": {"enabled": dockerapi.ENABLED, "available": dockerapi.available()},
            "telegram": store.telegram_status()}


def api_health(_q):
    return health.diagnose()


GET_API = {**monitor.READ_API, "/api/checks": api_checks, "/api/rules": api_rules,
           "/api/settings": api_settings, "/api/health": api_health}


# ------------------------------------------------------------------ management API (POST)

def post_checks_add(b, _h):
    store.add_target(b.get("kind"), b.get("target"), b.get("name", ""))
    return {"ok": True}


def post_checks_remove(b, _h):
    store.remove_target(b.get("kind"), b.get("target"))
    return {"ok": True}


def post_checks_probe(b, _h):
    return store.probe_debug(b.get("kind"), b.get("target"))


def post_checks_mode(b, _h):
    store.set_mode(b.get("kind"), b.get("target"), b.get("mode"))
    return {"ok": True}


def post_checks_replace(b, _h):
    store.replace_target(b.get("kind"), b.get("target"), b.get("new_target"))
    return {"ok": True}


def post_checks_autofix(b, _h):
    target = str(b.get("target", "")).strip()
    if not any(r["target"] == target for r in store.list_targets("http")):
        raise store.ConfigError("Only monitored addresses can be fixed")
    return {"ok": True, "event": store.auto_fix(target)}


def post_auto_setting(b, _h):
    store.set_auto_enabled(b.get("enabled", True))
    return {"ok": True}


def post_telegram_save(b, _h):
    return {"ok": True, **store.save_telegram(b.get("token", ""), b.get("chat_id", ""))}


def post_telegram_test(b, _h):
    store.telegram_test(b.get("token", ""), b.get("chat_id", ""))
    return {"ok": True}


def post_telegram_chats(b, _h):
    return {"chats": store.telegram_chats(b.get("token", ""))}


def post_telegram_remove(_b, _h):
    store.remove_telegram()
    return {"ok": True}


def post_alert_test(_b, _h):
    store.send_test_alert()
    return {"ok": True}


def post_rules_set(b, _h):
    store.set_rule(b.get("name"), b.get("enabled", True), b.get("value"), b.get("for", 0))
    return {"ok": True}


def post_rules_reset(_b, _h):
    store.reset_rules()
    return {"ok": True}


def post_docker_action(b, _h):
    # Only used by the self-diagnosis page: bring a stopped service of the monitoring stack back.
    return dockerapi.revive(str(b.get("id", "")), str(b.get("action", "")))


def post_password(b, h):
    auth.change(str(b.get("current", "")), str(b.get("new", "")), b.get("user"))
    sessions.revoke_all(keep_token=h.token)     # signed out everywhere else
    seclog.add("password", h.ip)
    return {"ok": True, "user": auth.user}


# ------------------------------------------------------------------ security page

def api_security(_q, h=None):
    return {"sessions": sessions.list(h.token if h else None), "locks": guard.list(), "log": seclog.list(),
            "totp": totp.enabled(), "settings": secsettings.get(), "ip": h.ip if h else "",
            "limits": {"lock_after": security.LOCK_AFTER, "window": security.LOCK_WINDOW, "firewall_after": security.FIREWALL_AFTER}}


def post_session_revoke(b, h):
    sessions.revoke(str(b.get("id", "")))
    seclog.add("session_revoked", h.ip)
    return api_security({}, h)


def post_sessions_others(_b, h):
    sessions.revoke_all(keep_token=h.token)
    seclog.add("sessions_revoked", h.ip)
    return api_security({}, h)


def post_unlock(b, h):
    guard.unlock(str(b.get("ip", "")))
    seclog.add("unlocked", h.ip, target=str(b.get("ip", ""))[:64])
    return api_security({}, h)


def _need_password(b):
    if not auth.verify(auth.user, str(b.get("password", ""))):
        raise ValueError("The password is wrong")


def post_2fa_setup(b, h):
    _need_password(b)
    if totp.enabled():
        raise ValueError("Two-factor sign-in is already on; turn it off first")
    secret = totp.setup()
    return {"secret": secret, "uri": totp.uri(auth.user, "Server Monitor")}


def post_2fa_enable(b, h):
    if not totp.enable(b.get("code", "")):
        raise ValueError("The code is not right. Check the time on your phone and try the newest code.")
    sessions.revoke_all(keep_token=h.token)
    seclog.add("2fa_on", h.ip)
    return api_security({}, h)


def post_2fa_disable(b, h):
    _need_password(b)
    if totp.enabled() and not totp.verify(b.get("code", "")):
        raise ValueError("The code is not right")
    totp.disable()
    seclog.add("2fa_off", h.ip)
    return api_security({}, h)


def post_security_settings(b, h):
    secsettings.set(**{k: b[k] for k in ("notify_login", "notify_lock") if k in b})
    return api_security({}, h)


POST_API = {
    "/api/checks/add": post_checks_add, "/api/checks/remove": post_checks_remove, "/api/checks/probe": post_checks_probe, "/api/checks/mode": post_checks_mode, "/api/checks/replace": post_checks_replace, "/api/checks/autofix": post_checks_autofix, "/api/settings/auto": post_auto_setting,
    "/api/telegram/save": post_telegram_save, "/api/telegram/test": post_telegram_test,
    "/api/telegram/chats": post_telegram_chats, "/api/telegram/remove": post_telegram_remove,
    "/api/alerts/test": post_alert_test, "/api/rules/set": post_rules_set, "/api/rules/reset": post_rules_reset,
    "/api/docker/action": post_docker_action, "/api/password": post_password,
    "/api/security/revoke": post_session_revoke, "/api/security/revoke-others": post_sessions_others,
    "/api/security/unlock": post_unlock, "/api/security/2fa/setup": post_2fa_setup,
    "/api/security/2fa/enable": post_2fa_enable, "/api/security/2fa/disable": post_2fa_disable,
    "/api/security/settings": post_security_settings,
}


def _notify(text):
    """Telegram message about the panel's own security, sent in the background."""
    def send():
        try:
            defender._send(f"\U0001F510 Panel \u00b7 {defender._host_label()}\n{text}")
        except Exception as e:
            print("security notify:", e, flush=True)
    threading.Thread(target=send, daemon=True).start()


def _firewall_ban(ip):
    def ban():
        try:
            defender.post("block", {"ip": ip, "minutes": 60, "note": "panel login brute force"})
            seclog.add("firewall_ban", ip)
        except Exception as e:   # firewall off, agent missing, admin address: the login lock still applies
            print("panel brute force ban:", e, flush=True)
    threading.Thread(target=ban, daemon=True).start()

# ------------------------------------------------------------------ http

class Handler(BaseHTTPRequestHandler):
    server_version = "panel"
    sys_version = ""
    new_cookie = None

    def log_message(self, fmt, *args):  # one line per request on stderr
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    # -- helpers
    def _headers(self, status, ctype, length, extra=(), cache="no-store"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()")
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("X-Permitted-Cross-Domain-Policies", "none")
        if self._https():
            self.send_header("Strict-Transport-Security", "max-age=31536000")
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()

    def _json(self, status, obj, extra=()):
        body = json.dumps(obj).encode()
        self._headers(status, "application/json", len(body), extra)
        self.wfile.write(body)

    def _bytes(self, body, ctype):
        self._headers(200, ctype, len(body))
        self.wfile.write(body)

    def _file(self, name, ctype):
        """Static files: read and compressed once (until the file changes), then served from memory.
        The browser keeps them and only asks "changed?" (ETag), which costs a 304 with no body."""
        _, raw, packed, etag = static_file(name)
        extra = [("ETag", etag), ("Vary", "Accept-Encoding")]
        if self.headers.get("If-None-Match") == etag:
            return self._headers(304, ctype, 0, extra, cache="private, no-cache")
        body = raw
        if packed and "gzip" in self.headers.get("Accept-Encoding", ""):
            body = packed
            extra.append(("Content-Encoding", "gzip"))
        self._headers(200, ctype, len(body), extra, cache="private, no-cache")
        self.wfile.write(body)

    def _redirect(self, location):
        self._headers(302, "text/plain", 0, [("Location", location)])

    @property
    def ip(self):
        if TRUST_PROXY:
            fwd = self.headers.get("X-Forwarded-For", "").split(",")[0].strip()
            if fwd:
                return fwd[:64]
        return self.client_address[0]

    @property
    def token(self):
        try:
            c = SimpleCookie(self.headers.get("Cookie", ""))
        except Exception:
            return ""
        return c[COOKIE].value if COOKIE in c else ""

    def _https(self):
        return TRUST_PROXY and self.headers.get("X-Forwarded-Proto", "") == "https"

    def _cookie(self, value, max_age):
        return f"{COOKIE}={value}; Path=/; Max-Age={max_age}; HttpOnly; SameSite=Strict" + ("; Secure" if self._https() else "")

    def _authed(self):
        return sessions.get(self.token) is not None

    def _rate_ok(self):
        """Signed-in browsers get a generous budget; everything else (scanners, bots) a small one."""
        if self._authed():
            return limiter.allow(f"s:{self.token[:16]}", 3000, 600)
        return limiter.allow(f"ip:{self.ip}", 120, 60)

    def _run(self, fn, *args):
        """Call an API function and turn its exceptions into JSON error responses."""
        try:
            return self._json(200, fn(*args), [("Set-Cookie", self.new_cookie)] if self.new_cookie else ())
        except (ValueError, KeyError, TypeError) as e:  # ConfigError is a ValueError
            return self._json(400, {"error": str(e)})
        except store.ApplyError as e:
            return self._json(502, {"error": str(e), "saved": True})
        except dockerapi.DockerError as e:
            return self._json(502, {"error": str(e)})
        except defender.AgentError as e:
            return self._json(503, {"error": str(e), "agent": False})
        except PermissionError:
            return self._json(500, {"error": WRITE_HINT})
        except Exception as e:  # prometheus unreachable, bad response, ...
            return self._json(502, {"error": f"{type(e).__name__}: {e}"})

    # -- routes
    def do_GET(self):
        url = urlparse(self.path)
        path = url.path
        if path == "/healthz":
            return self._json(200, {"ok": True})
        if not self._rate_ok():
            return self._json(429, {"error": "too many requests"}, [("Retry-After", "30")])
        if path in ICONS:
            make, ctype = ICONS[path]
            return self._bytes(make(), ctype)
        if path in PUBLIC_FILES:
            if path == "/login" and self._authed():
                return self._redirect("/")
            return self._file(*PUBLIC_FILES[path])
        if not self._authed():
            if path.startswith("/api/"):
                return self._json(401, {"error": "unauthorized"})
            return self._redirect("/login")
        if path in PRIVATE_FILES:
            return self._file(*PRIVATE_FILES[path])
        if path == "/api/live":
            return self._live({k: v[0] for k, v in parse_qs(url.query).items()})
        if path.startswith("/api/defender/"):
            return self._run(defender.get, path[len("/api/defender/"):], {k: v[0] for k, v in parse_qs(url.query).items()})
        if path == "/api/security":
            return self._run(api_security, {}, self)
        if path in GET_API:
            params = {k: v[0] for k, v in parse_qs(url.query).items()}
            return self._run(GET_API[path], params)
        self._json(404, {"error": "not found"})

    def _live(self, params):
        """Server-Sent Events: one sample per second for the selected server (see live.py)."""
        try:
            instance = live.resolve(params.get("instance", ""))
        except ValueError as e:
            return self._json(400, {"error": str(e)})
        except Exception as e:  # Prometheus unreachable: the page falls back to its 10-second polling
            return self._json(502, {"error": f"{type(e).__name__}: {e}"})
        try:
            last = float(self.headers.get("Last-Event-ID") or params.get("since") or 0)
        except ValueError:
            last = 0.0
        try:
            every = int(params.get("every") or 1)
        except ValueError:
            every = 1
        every = every if every in live.CHOICES else 1
        token = self.token
        self.send_response(200)
        for k, v in (("Content-Type", "text/event-stream; charset=utf-8"), ("Cache-Control", "no-store"),
                     ("X-Accel-Buffering", "no"), ("X-Content-Type-Options", "nosniff"), ("Content-Security-Policy", CSP)):
            self.send_header(k, v)
        self.end_headers()
        self.close_connection = True

        def send(event, data, eid=None):
            msg = (f"id: {eid}\n" if eid is not None else "") + f"event: {event}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n"
            self.wfile.write(msg.encode())
            self.wfile.flush()

        error = None
        deadline = time.time() + LIVE_MAX_SECONDS   # the browser reconnects by itself, which re-checks the login
        try:
            self.wfile.write(b"retry: 3000\n\n")
            sampler = live.sampler(instance, every)
            send("hello", {"instance": instance, "interval": every, "keep": live.KEEP})
            while time.time() < deadline and sessions.get(token) is not None:
                new, sent = [], last
                for s in sampler.since(last):   # another viewer may sample faster: send this one's pace only
                    if not new and not sent or s["t"] - sent >= every - 0.3:
                        new.append(s)
                        sent = s["t"]
                if new:
                    last = new[-1]["t"]
                    send("s", new, last)
                if sampler.error != error:
                    error = sampler.error
                    send("status", {"error": error})
                if not new and not error:
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
                sampler.wait(15)
                sampler = live.sampler(instance, every)   # keeps it alive (or starts a new one if it stopped)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, TimeoutError):
            return

    def _body(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            limit = 4_000_000 if urlparse(self.path).path in BIG_BODY else 65536
            if length > limit or length < 0:
                raise BadRequest("request too large")
            data = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(data, dict):
                raise BadRequest("expected a JSON object")
            return data
        except (ValueError, TypeError) as e:
            raise BadRequest(str(e) or "bad request") from e

    def _same_origin(self):
        origin = self.headers.get("Origin")
        return origin is None or urlparse(origin).netloc == self.headers.get("Host")

    def do_POST(self):
        path = urlparse(self.path).path
        if not self._rate_ok():
            return self._json(429, {"error": "too many requests"}, [("Retry-After", "30")])
        if path == "/logout":
            if self.token and sessions.get(self.token):
                seclog.add("logout", self.ip)
            sessions.revoke_token(self.token)
            return self._json(200, {"ok": True}, [("Set-Cookie", self._cookie("", 0))])
        if path == "/login":
            if not self._same_origin():
                return self._json(403, {"error": "forbidden"})
            return self._login()
        fn = POST_API.get(path)
        if fn is None and path.startswith("/api/defender/") and path[len("/api/defender/"):] in defender.POST_PATHS:
            name = path[len("/api/defender/"):]
            fn = lambda body, _h: defender.post(name, body)  # noqa: E731
        if fn is None:
            return self._json(404, {"error": "not found"})
        if not self._authed():
            return self._json(401, {"error": "unauthorized"})
        if self.headers.get("X-Panel") != "1" or not self._same_origin():
            return self._json(403, {"error": "forbidden"})
        try:
            body = self._body()
        except BadRequest as e:
            return self._json(400, {"error": str(e)})
        self._run(fn, body, self)

    def _login(self):
        ip = self.ip
        left = guard.locked(ip)
        if left:
            return self._json(429, {"error": "locked", "locked": left})
        try:
            data = self._body()
            user, password, code = str(data.get("user", ""))[:200], str(data.get("password", ""))[:500], str(data.get("otp", ""))[:20]
        except BadRequest:
            return self._json(400, {"error": "bad request"})
        ok = auth.verify(user, password)
        if ok and totp.enabled():
            if not code:
                return self._json(401, {"error": "code required", "otp": True})   # right password: not a failure yet
            ok = totp.verify(code)
        if not ok:
            locked, total = guard.failed(ip)
            seclog.add("login_failed", ip, user=user[:64])
            time.sleep(0.6 + secrets.randbelow(600) / 1000)   # slows guessing without blocking other users
            if locked:
                seclog.add("locked", ip, minutes=locked // 60)
                if secsettings.get()["notify_lock"]:
                    _notify(f"{ip} was locked out of the panel for {locked // 60} min after repeated wrong logins.")
            if total >= security.FIREWALL_AFTER:
                _firewall_ban(ip)
            return self._json(429 if locked else 401, {"error": "locked" if locked else "invalid credentials", "locked": locked,
                                                       "otp": totp.enabled() and bool(code)})
        guard.success(ip)
        known = seclog.known_ip(ip)
        seclog.add("login", ip, ua=self.headers.get("User-Agent", "")[:120])
        if not known and secsettings.get()["notify_login"]:
            _notify(f"New sign-in from {ip}. If this was not you, change the password and revoke the session in Settings.")
        token = sessions.create(ip, self.headers.get("User-Agent", ""))
        self._json(200, {"ok": True}, [("Set-Cookie", self._cookie(token, SESSION_TTL))])


def main():
    try:
        store.bootstrap()
    except OSError as e:
        print(f"WARNING: cannot prepare configuration files ({e}). {WRITE_HINT}", flush=True)
    threading.Thread(target=store.auto_loop, daemon=True).start()
    defender.start()
    print(f"panel {VERSION} listening on :{PORT}, prometheus at {monitor.PROM}, docker control "
          f"{'on' if dockerapi.ENABLED else 'off'}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
