"""Downloads that keep working when one source goes away or is blocked.

Every list the firewall downloads (country ranges, threat lists, Cloudflare's addresses) is fetched
from the first source that answers with usable content; a source that fails (blocked, 403, gone,
timeout, or an error page instead of a list) is skipped and the next one tried. Files on GitHub also
get their jsDelivr copy and GitHub proxies as extra sources, for servers where GitHub is blocked.
GITHUB_PROXIES (comma-separated URL prefixes) replaces the default proxies.
"""
import os
import re
from urllib.request import Request, urlopen

GITHUB_PROXIES = [p.strip() for p in os.environ.get("GITHUB_PROXIES", "https://ghfast.top/,https://gh-proxy.com/").split(",") if p.strip()]
RAW_RE = re.compile(r"^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.+)$")
UA = "server-monitor-firewall/1.2"


def alternatives(url):
    """The URL itself, then other places the same file can be fetched from."""
    out = [url]
    m = RAW_RE.match(url)
    if m:
        owner, repo, branch, path = m.groups()
        out.append(f"https://cdn.jsdelivr.net/gh/{owner}/{repo}@{branch}/{path}")
        out += [(p if p.endswith("/") else p + "/") + url for p in GITHUB_PROXIES]
    return out


def fetch(urls, check=None, timeout=40, limit=40_000_000):
    """Text of the first URL that answers with content `check` accepts; ValueError with every reason."""
    errors = []
    for url in urls:
        try:
            req = Request(url, headers={"User-Agent": UA, "Accept-Encoding": "identity"})
            with urlopen(req, timeout=timeout) as r:
                body = r.read(limit + 1)
            if len(body) > limit:
                raise ValueError("too large")
            text = body.decode("utf-8", "replace")
            if check and not check(text):
                raise ValueError("not a usable list (maybe an error page)")
            return text
        except Exception as e:  # blocked, 403/404, timeout, bad content: try the next source
            errors.append(f"{url.split('/')[2]}: {type(e).__name__}: {e}"[:160])
    raise ValueError("; ".join(errors) or "no source")


def fetch_any(urls, **kw):
    """Like fetch(), with every URL expanded to its alternatives."""
    seen, all_urls = set(), []
    for u in urls:
        for a in alternatives(u):
            if a not in seen:
                seen.add(a)
                all_urls.append(a)
    return fetch(all_urls, **kw)
