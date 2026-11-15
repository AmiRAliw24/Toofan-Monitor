"""Panel security: server-side sessions, per-address login protection, two-factor codes (TOTP),
request rate limits and a security log. Standard library only.

Lost the authenticator? On the server delete data/panel/totp.json (2FA is then off).
Locked yourself out by mistake? Restart the panel container (locks live in memory only).
"""
import base64
import collections
import hashlib
import hmac
import json
import os
import secrets
import struct
import threading
import time
from pathlib import Path

DATA = Path(os.environ.get("DATA_DIR", "/data"))
SESSION_IDLE = 24 * 3600          # a session nobody used for a day ends
SESSION_MAX = 14 * 24 * 3600      # and every session ends after two weeks
LOCK_AFTER = 5                    # failed logins from one address ...
LOCK_WINDOW = 15 * 60             # ... within this window lock the address
LOCK_BASE, LOCK_MAX = 15 * 60, 24 * 3600   # first lock 15 min, doubling up to a day
FIREWALL_AFTER = 15               # failures after which the firewall bans the address outright
_lock = threading.RLock()


def _write_private(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, path)


def _read(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


# ------------------------------------------------------------------ sessions

class Sessions:
    """Random session tokens; only their SHA-256 is stored, so the file is useless to a reader."""

    def __init__(self):
        self.file = DATA / "sessions.json"
        self.items = _read(self.file, {})
        self._saved = 0

    @staticmethod
    def _key(token):
        return hashlib.sha256(token.encode()).hexdigest()

    def _save(self, force=False):
        if force or time.time() - self._saved > 60:
            self._saved = time.time()
            try:
                _write_private(self.file, self.items)
            except OSError:
                pass

    def create(self, ip, ua):
        token = secrets.token_urlsafe(32)
        now = time.time()
        with _lock:
            self._expire(now)
            self.items[self._key(token)] = {"id": secrets.token_hex(6), "created": now, "last": now, "ip": ip, "ua": (ua or "")[:160]}
            self._save(force=True)
        return token

    def get(self, token):
        if not token:
            return None
        now = time.time()
        with _lock:
            s = self.items.get(self._key(token))
            if not s:
                return None
            if now - s["last"] > SESSION_IDLE or now - s["created"] > SESSION_MAX:
                self.items.pop(self._key(token), None)
                self._save(force=True)
                return None
            if now - s["last"] > 30:
                s["last"] = now
                self._save()
            return s

    def touch_ip(self, token, ip):
        s = self.get(token)
        if s and s.get("ip") != ip:
            s["ip"] = ip

    def revoke_token(self, token):
        with _lock:
            self.items.pop(self._key(token or ""), None)
            self._save(force=True)

    def revoke(self, sid):
        with _lock:
            for k, v in list(self.items.items()):
                if v["id"] == sid:
                    del self.items[k]
            self._save(force=True)

    def revoke_all(self, keep_token=None):
        with _lock:
            keep = self._key(keep_token) if keep_token else None
            self.items = {k: v for k, v in self.items.items() if k == keep}
            self._save(force=True)

    def _expire(self, now):
        self.items = {k: v for k, v in self.items.items() if now - v["last"] <= SESSION_IDLE and now - v["created"] <= SESSION_MAX}

    def list(self, current_token=None):
        with _lock:
            self._expire(time.time())
            cur = self._key(current_token) if current_token else None
            return sorted(({**v, "current": k == cur} for k, v in self.items.items()), key=lambda r: -r["last"])


# ------------------------------------------------------------------ login protection

class Guard:
    def __init__(self):
        self.fails = collections.defaultdict(collections.deque)   # ip -> failure times
        self.locks = {}                                            # ip -> {"until", "count"}
        self.totals = collections.Counter()                        # ip -> failures since the panel started

    def locked(self, ip):
        with _lock:
            lk = self.locks.get(ip)
            if lk and lk["until"] > time.time():
                return int(lk["until"] - time.time())
            return 0

    def failed(self, ip):
        now = time.time()
        with _lock:
            q = self.fails[ip]
            q.append(now)
            while q and now - q[0] > LOCK_WINDOW:
                q.popleft()
            self.totals[ip] += 1
            if len(q) >= LOCK_AFTER:
                count = self.locks.get(ip, {}).get("count", 0) + 1
                self.locks[ip] = {"until": now + min(LOCK_MAX, LOCK_BASE * 2 ** (count - 1)), "count": count, "since": now}
                q.clear()
                return int(self.locks[ip]["until"] - now), self.totals[ip]
            return 0, self.totals[ip]

    def success(self, ip):
        with _lock:
            self.fails.pop(ip, None)
            self.locks.pop(ip, None)

    def unlock(self, ip):
        with _lock:
            self.locks.pop(ip, None)
            self.fails.pop(ip, None)

    def list(self):
        now = time.time()
        with _lock:
            return [{"ip": ip, "left": int(v["until"] - now), "count": v["count"], "failures": self.totals[ip]}
                    for ip, v in self.locks.items() if v["until"] > now]


# ------------------------------------------------------------------ two-factor codes (RFC 6238)

class TOTP:
    STEP, DIGITS = 30, 6

    def __init__(self):
        self.file = DATA / "totp.json"

    def _data(self):
        return _read(self.file, {})

    def enabled(self):
        return bool(self._data().get("enabled"))

    def setup(self):
        secret = base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")
        _write_private(self.file, {"secret": secret, "enabled": False, "last": 0})
        return secret

    @classmethod
    def code(cls, secret, counter):
        key = base64.b32decode(secret + "=" * (-len(secret) % 8))
        h = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
        o = h[-1] & 15
        return str((struct.unpack(">I", h[o:o + 4])[0] & 0x7FFFFFFF) % 10 ** cls.DIGITS).zfill(cls.DIGITS)

    def verify(self, code, pending=False):
        d = self._data()
        if not d.get("secret") or (not d.get("enabled") and not pending):
            return False
        code = "".join(ch for ch in str(code or "") if ch.isdigit())
        if len(code) != self.DIGITS:
            return False
        now = int(time.time() // self.STEP)
        for c in (now - 1, now, now + 1):
            if c > d.get("last", 0) and hmac.compare_digest(self.code(d["secret"], c), code):
                d["last"] = c          # a code works once
                _write_private(self.file, d)
                return True
        return False

    def enable(self, code):
        if not self.verify(code, pending=True):
            return False
        d = self._data()
        d["enabled"] = True
        _write_private(self.file, d)
        return True

    def disable(self):
        try:
            self.file.unlink()
        except FileNotFoundError:
            pass

    def uri(self, user, issuer):
        from urllib.parse import quote
        d = self._data()
        return f"otpauth://totp/{quote(issuer)}:{quote(user)}?secret={d.get('secret', '')}&issuer={quote(issuer)}&digits=6&period=30"


# ------------------------------------------------------------------ rate limits

class Limiter:
    """Token buckets per key: rate per minute with a burst."""

    def __init__(self):
        self.b = {}

    def allow(self, key, per_min, burst):
        now = time.time()
        with _lock:
            tokens, last = self.b.get(key, (burst, now))
            tokens = min(burst, tokens + (now - last) * per_min / 60)
            if tokens < 1:
                self.b[key] = (tokens, now)
                return False
            self.b[key] = (tokens - 1, now)
            if len(self.b) > 50000:
                self.b.clear()
            return True


# ------------------------------------------------------------------ security log and settings

class Log:
    def __init__(self):
        self.file = DATA / "security-log.json"
        self.rows = collections.deque(_read(self.file, []), maxlen=400)

    def add(self, kind, ip="", **data):
        with _lock:
            self.rows.append({"t": round(time.time(), 1), "kind": kind, "ip": ip, **data})
            try:
                _write_private(self.file, list(self.rows))
            except OSError:
                pass

    def list(self):
        with _lock:
            return list(self.rows)[-200:][::-1]

    def known_ip(self, ip, days=30):
        cutoff = time.time() - days * 86400
        return any(r["kind"] == "login" and r.get("ip") == ip and r["t"] > cutoff for r in list(self.rows)[:-1])


class Settings:
    def __init__(self):
        self.file = DATA / "security.json"

    def get(self):
        return {"notify_login": True, "notify_lock": True, **_read(self.file, {})}

    def set(self, **kw):
        cur = self.get()
        cur.update({k: bool(v) for k, v in kw.items() if k in ("notify_login", "notify_lock")})
        _write_private(self.file, cur)
        return cur


sessions = Sessions()
guard = Guard()
totp = TOTP()
limiter = Limiter()
log = Log()
settings = Settings()
