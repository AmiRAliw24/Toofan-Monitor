#!/usr/bin/env bash
# Server monitoring installer - single self-contained file.
# Installs Docker (if missing), then deploys the monitoring panel + Prometheus + Alertmanager +
# node_exporter + container stats + Blackbox exporter under /opt/server-monitoring.
#
# Usage (as root):
#   curl -fsSL https://raw.githubusercontent.com/AmiRAliw24/Toofan-Monitor/HEAD/install.sh | sudo bash          # one-liner, interactive
#   curl -fsSL https://raw.githubusercontent.com/AmiRAliw24/Toofan-Monitor/HEAD/install.sh | sudo bash -s -- -y # one-liner, no questions (uses env vars)
#   # where GitHub is blocked, fetch it from the first source that works:
#   for u in https://raw.githubusercontent.com/AmiRAliw24/Toofan-Monitor/HEAD/install.sh https://ghfast.top/https://raw.githubusercontent.com/AmiRAliw24/Toofan-Monitor/HEAD/install.sh https://gh-proxy.com/https://raw.githubusercontent.com/AmiRAliw24/Toofan-Monitor/HEAD/install.sh; do curl -fsSL -m 120 "$u" -o install.sh && break; done; sudo bash install.sh
#   bash install.sh                 # interactive
#   bash install.sh -y              # non-interactive, uses env vars / defaults
#   bash install.sh --no-start      # write files only, don't start containers
#   bash install.sh --uninstall     # stop and remove containers (keeps data volumes)
#   bash install.sh --purge         # also delete data volumes and the install dir
#   bash install.sh --update        # download the newest installer (from the first source that works) and run it
#
# Optional env vars: INSTALL_DIR, PANEL_USER, PANEL_PASSWORD, PANEL_BIND, PANEL_PORT,
#   TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, TELEGRAM_API (a proxy / local Bot API server where api.telegram.org
#   is blocked), SITES (comma-separated URLs), PROMETHEUS_RETENTION, PROMETHEUS_RETENTION_SIZE (default 5GB),
#   DOCKER_MIRROR (comma-separated registry mirrors to use), ALPINE_MIRROR (Alpine package mirror),
#   and the fallback lists DOCKER_SCRIPT_URLS, DOCKER_CE_MIRRORS, GITHUB_PROXIES, REGISTRY_MIRRORS, ALPINE_MIRRORS
#
# Everything downloaded has several sources (official, GitHub proxies, ArvanCloud and other mirrors);
# when one fails (blocked, 403, timeout, bad checksum) the next is tried. So it also installs on
# servers where Docker's or GitHub's sites are blocked (Iran: get.docker.com and Docker Hub answer 403).
set -euo pipefail

# Everything lives in main() so bash parses the whole script before running anything.
# This keeps `curl ... | bash` safe: no command can swallow the rest of the script from stdin.
main() {

INSTALL_DIR=${INSTALL_DIR:-/opt/server-monitoring}
ASSUME_YES=0; NO_START=0; ACTION=install
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    --no-start) NO_START=1 ;;
    --uninstall) ACTION=uninstall ;;
    --purge) ACTION=purge ;;
    --update) ACTION=update ;;
    -h|--help) awk 'NR > 1 && /^set -euo/ { exit } NR > 1' "$0" 2>/dev/null || echo 'See the header of install.sh for usage.'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ask VAR "Prompt" "default"  - uses the env var if already set, otherwise prompts (tty only).
ask() {
  local var=$1 prompt=$2 default=${3:-} reply
  if [ -n "${!var:-}" ]; then return; fi
  if [ "$ASSUME_YES" = 1 ] || ! { : < /dev/tty; } 2>/dev/null; then printf -v "$var" '%s' "$default"; return; fi
  read -r -p "$prompt${default:+ [$default]}: " reply < /dev/tty || true
  printf -v "$var" '%s' "${reply:-$default}"
}

write_file() {  # write_file <relative path> [mode]  (content on stdin)
  local path="$INSTALL_DIR/$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path"
  chmod "${2:-644}" "$path"
}

compose() { docker compose --project-directory "$INSTALL_DIR" "$@"; }

[ "$(uname -s)" = Linux ] || die "This installer supports Linux only."
if [ "$NO_START" = 0 ] || [ "$ACTION" != install ]; then
  [ "$(id -u)" = 0 ] || die "Run as root (e.g. sudo bash $0)."
fi

if [ "$ACTION" = uninstall ] || [ "$ACTION" = purge ]; then
  [ -f "$INSTALL_DIR/docker-compose.yml" ] || die "No installation found in $INSTALL_DIR."
  # The Defender's firewall rules live in the kernel, not in a container: remove them too.
  if command -v nft >/dev/null 2>&1; then nft delete table inet defender 2>/dev/null || true
  else docker run --rm --network host --privileged server-monitoring-defender:1 nft delete table inet defender >/dev/null 2>&1 || true; fi
  if [ "$ACTION" = purge ]; then
    compose down -v --remove-orphans
    rm -rf "$INSTALL_DIR"
    log "Removed containers, data volumes and $INSTALL_DIR."
  else
    compose down --remove-orphans
    log "Containers stopped and removed. Data volumes and $INSTALL_DIR are kept (use --purge to delete)."
  fi
  exit 0
fi

# ---------------------------------------------------------------- embedded files
extract_files() {
  write_file docker-compose.yml 644 <<'__MONITORING_EOF__'
name: server-monitoring

# restart: always (not unless-stopped): the stack must come back after every reboot. Docker
# marks a container as "manually stopped" after any `docker kill`, even a harmless SIGHUP,
# and unless-stopped then leaves it down on the next boot; prometheus going missing that way
# shows up in the panel as a DNS error ("Try again") for the name prometheus.
# Container logs are capped (3 x 10 MB per service): left alone for years they would fill the disk.
x-logging: &logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

services:
  prometheus:
    image: prom/prometheus:v2.55.1
    restart: always
    logging: *logging
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=${PROMETHEUS_RETENTION:-30d}
      # and never more than this on disk, whatever the time limit says
      - --storage.tsdb.retention.size=${PROMETHEUS_RETENTION_SIZE:-5GB}
      - --web.enable-lifecycle
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./prometheus/rules:/etc/prometheus/rules:ro
      - ./prometheus/targets:/etc/prometheus/targets:ro
      - prometheus_data:/prometheus
    ports:
      - "127.0.0.1:9090:9090"
    networks: [monitoring]

  alertmanager:
    image: prom/alertmanager:v0.27.0
    restart: always
    logging: *logging
    command:
      - --config.file=/etc/alertmanager/alertmanager.yml
      - --storage.path=/alertmanager
    volumes:
      # The whole directory is mounted (not one file) so the panel can replace alertmanager.yml.
      - ./alertmanager:/etc/alertmanager:ro
      - alertmanager_data:/alertmanager
    ports:
      - "127.0.0.1:9093:9093"
    networks: [monitoring]

  node-exporter:
    image: prom/node-exporter:v1.8.2
    restart: always
    logging: *logging
    pid: host
    command:
      - --path.rootfs=/host
      # Only what the panel and its alerts use (about 40 collectors run by default). Network stats come
      # from node-net below: inside a container netdev would only see the container's own interface.
      - --collector.disable-defaults
      - --collector.cpu
      - --collector.cpu.info
      - --collector.meminfo
      - --collector.loadavg
      - --collector.filesystem
      - --collector.diskstats
      - --collector.stat
      - --collector.uname
      - --collector.os
      - --collector.time
      - --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)
    volumes:
      - /:/host:ro,rslave
    networks: [monitoring]

  # Reads the HOST's network namespace (via PID 1) so real NIC traffic is measured correctly.
  # Needs privileged: reading another namespace's /proc/1/net is blocked by the default
  # AppArmor/ptrace restrictions.
  node-net:
    image: prom/node-exporter:v1.8.2
    restart: always
    logging: *logging
    pid: host
    privileged: true
    user: root
    command:
      - --path.procfs=/host/proc/1
      - --path.sysfs=/host/sys
      - --collector.disable-defaults
      - --collector.netdev
      # netlink would ask the kernel about the exporter's OWN namespace and ignore --path.procfs
      - --no-collector.netdev.netlink
      - --collector.netclass
      - --no-collector.netclass.netlink
      - --collector.netdev.device-exclude=^(lo|veth.*|docker.*|br-.*|virbr.*|cni.*|cali.*|flannel.*|ifb.*)$$
      - --collector.netclass.ignored-devices=^(lo|veth.*|docker.*|br-.*|virbr.*|cni.*|cali.*|flannel.*|ifb.*)$$
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
    networks: [monitoring]

  # CPU and memory of each Docker container (for the container alerts), read from the kernel's cgroups
  # only when Prometheus asks. Replaces cAdvisor, which cannot see containers on current Docker versions.
  # Root only to read the container names in /var/lib/docker/containers; no capabilities, read-only.
  containers:
    image: python:3.12-alpine
    restart: always
    logging: *logging
    command: ["python", "-u", "/app/cstats.py"]
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    environment:
      PYTHONDONTWRITEBYTECODE: "1"
    volumes:
      - ./panel:/app:ro
      - /sys/fs/cgroup:/host/cgroup:ro
      - ${DOCKER_ROOT:-/var/lib/docker}/containers:/host/containers:ro
    networks: [monitoring]

  blackbox:
    image: prom/blackbox-exporter:v0.25.0
    restart: always
    logging: *logging
    command: --config.file=/etc/blackbox/blackbox.yml
    volumes:
      - ./blackbox/blackbox.yml:/etc/blackbox/blackbox.yml:ro
    networks: [monitoring]

  # Finds the server's public IPv4/IPv6 (shown on the overview page). Host networking so the
  # lookups use the real interfaces; set PUBLIC_IP_LOOKUP=0 in .env to disable.
  hostip:
    image: python:3.12-alpine
    restart: always
    logging: *logging
    command: ["python", "-u", "/app/hostip.py"]
    network_mode: host
    user: "65534:65534"
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    environment:
      PYTHONDONTWRITEBYTECODE: "1"
      PUBLIC_IP_LOOKUP: ${PUBLIC_IP_LOOKUP:-1}
      OUT: /data/public-ip.json
    volumes:
      - ./panel:/app:ro
      - ./data/panel:/data

  # Defender: firewall, anti-DDoS, SSH brute-force guard and kernel hardening, controlled from the panel.
  # It needs the host's network (nftables) and PIDs (open ports, logged-in users) and root, so it is the
  # only privileged part; the panel talks to it through a unix socket in ./data/defender. Protection is
  # off until it is turned on in the panel. Emergency off switch: nft delete table inet defender
  defender:
    build:
      context: ./defender
      args:
        ALPINE_MIRROR: ${ALPINE_MIRROR:-}
    image: server-monitoring-defender:1
    pull_policy: build
    restart: always
    logging: *logging
    network_mode: host
    pid: host
    privileged: true
    environment:
      PANEL_PORTS: ${PANEL_PORT:-3000}
      PANEL_GID: "65534"
      DATA_DIR: /data
    volumes:
      - ./defender:/app:ro
      - ./data/defender:/data

  panel:
    image: python:3.12-alpine
    restart: always
    logging: *logging
    command: ["python", "-u", "/app/server.py"]
    user: "65534:65534"
    # Group that owns /var/run/docker.sock (the installer sets DOCKER_GID); lets the panel manage containers.
    group_add: ["${DOCKER_GID:-65534}"]
    read_only: true
    tmpfs: [/tmp]
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    environment:
      PYTHONDONTWRITEBYTECODE: "1"
      PROMETHEUS_URL: http://prometheus:9090
      ALERTMANAGER_URL: http://alertmanager:9093
      BLACKBOX_URL: http://blackbox:9115
      PANEL_USER: ${PANEL_USER:-admin}
      PANEL_PASSWORD: ${PANEL_PASSWORD:?set PANEL_PASSWORD in .env}
      PANEL_LISTEN_PORT: "8080"
      PANEL_DOCKER_CONTROL: ${PANEL_DOCKER_CONTROL:-1}
      # Telegram's API, or a proxy / local Bot API server where api.telegram.org is blocked
      TELEGRAM_API: ${TELEGRAM_API:-https://api.telegram.org}
      CONFIG_DIR: /config
      DATA_DIR: /data
    volumes:
      - ./panel:/app:ro
      # Writable so the panel can add sites/servers, edit alert rules and connect Telegram.
      - ./prometheus/targets:/config/targets
      - ./prometheus/rules:/config/rules
      - ./alertmanager:/config/alertmanager
      - ./data/panel:/data
      # The Defender agent's socket (see the defender service).
      - ./data/defender:/defender
      # Docker control. Whoever can use this socket is root on the host: keep the panel password strong.
      # To switch it off set PANEL_DOCKER_CONTROL=0 in .env (and/or DOCKER_SOCKET=/dev/null).
      - ${DOCKER_SOCKET:-/var/run/docker.sock}:/var/run/docker.sock
    ports:
      - "${PANEL_BIND:-0.0.0.0}:${PANEL_PORT:-3000}:8080"
    healthcheck:
      # busybox wget: starting Python for every check cost more CPU than the panel itself when idle
      test: ["CMD", "wget", "-q", "-T", "3", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"]
      interval: 60s
      timeout: 5s
      retries: 3
    depends_on: [prometheus, alertmanager, blackbox]
    networks: [monitoring]

volumes:
  prometheus_data:
  alertmanager_data:

networks:
  monitoring:
__MONITORING_EOF__
  write_file .env.example 644 <<'__MONITORING_EOF__'
# Login for the web panel
PANEL_USER=admin
PANEL_PASSWORD=change-me

# 0.0.0.0   = panel reachable from any network on PANEL_PORT (open the port in your firewall)
# 127.0.0.1 = local only (use an SSH tunnel or a reverse proxy)
PANEL_BIND=0.0.0.0
PANEL_PORT=3000

PROMETHEUS_RETENTION=30d

# Optional first-time Telegram setup. After install, manage it in the panel (Notifications page).
TELEGRAM_BOT_TOKEN=123456:ABC-your-token
TELEGRAM_CHAT_ID=123456789

# Docker control from the panel (start/stop/create containers).
# DOCKER_GID is the group that owns /var/run/docker.sock; the installer fills it in (check: stat -c %g /var/run/docker.sock).
DOCKER_GID=999
# Set to 0 to make the container list read-only.
PANEL_DOCKER_CONTROL=1

# Show the server's public IPv4/IPv6 on the overview page. This asks api.ipify.org (or icanhazip.com / ident.me)
# for the address every 10 minutes; set to 0 to turn the lookups off.
PUBLIC_IP_LOOKUP=1
__MONITORING_EOF__
  write_file .gitignore 644 <<'__MONITORING_EOF__'
.env
alertmanager/alertmanager.yml
data/
__pycache__/
*.pyc
graphify-out/
__MONITORING_EOF__
  write_file README.md 644 <<'__MONITORING_EOF__'
<div align="center">

# 🛰️ مانیتورینگ کامل سرور

**یک پنل وب شیک و فارسی برای دیدن حال سرور و سایت‌ها و مدیریت همه‌چیز، بدون حتی یک بار رفتن به خط فرمان.**

![Docker Compose](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)
![Prometheus](https://img.shields.io/badge/Prometheus-2.55-E6522C?logo=prometheus&logoColor=white)
![Alertmanager](https://img.shields.io/badge/Alertmanager-Telegram-26A5E4?logo=telegram&logoColor=white)
![Python](https://img.shields.io/badge/Panel-Python%203.12-3776AB?logo=python&logoColor=white)
![Responsive](https://img.shields.io/badge/UI-Responsive%20%7C%20RTL%20%7C%20Dark%2FLight-2ee6a6)

<br>

<img src="docs/screenshots/overview-dark.png" alt="نمای کلی پنل (تم تیره)" width="92%">

</div>

<br>

## ✨ امکانات

<table>
<tr>
<td width="50%" valign="top">

### 📊 مانیتورینگ
- **وضعیت کلی** با یک نگاه: سالم / نیاز به توجه / مشکل
- ⚡ **آمار زنده، هر ثانیه**: CPU، رم، دیسک، I/O دیسک و ترافیک شبکه بدون رفرش و با حرکت نرم اعداد
- **گیج‌های حلقه‌ای** CPU، رم و دیسک با رنگ شدت
- **نمودارهای تعاملی** با خط راهنما، تولتیپ و نمای جدولی؛ بازه‌ی **«زنده (۵ دقیقه‌ی اخیر)»** ثانیه‌به‌ثانیه جلو می‌رود
- **ترافیک شبکه** کامل: دانلود و آپلود امروز، ۷ و ۳۰ روز
- **آی‌پی عمومی** IPv4 و IPv6 سرور (با یک کلیک کپی)

</td>
<td width="50%" valign="top">

### 🧰 مدیریت از پنل
- 🌐 افزودن و حذف **سایت** و **پورت TCP**
- 🖥️ افزودن **سرورهای دیگر**
- 🔔 اتصال **ربات تلگرام** و تست هشدار
- 🎚️ تغییر **آستانه‌ی هشدارها**
- 🔑 تغییر نام کاربری و رمز

</td>
</tr>
<tr>
<td width="50%" valign="top">

### 🩺 هوشمند
- 🛡️ **فایروال**: ضد DDoS، قوانین کشور/آدرس/پورت مثل Cloudflare، مدیریت کامل fail2ban، مدیریت SSH (پورت، کلیدها، ورود با رمز)، لیست‌های تهدید، قوانین خروجی و زمان‌دار، محافظ SSH و سخت‌سازی سرور با تشخیص خودکار حمله
- 🔍 **«چرا این سایت خراب است؟»** با توضیح ساده
- 🪄 **رفع خودکار** سایتی که چک استاندارد را رد می‌کند
- ⏳ هشدار **انقضای SSL**
- 🚨 هشدار تلگرام برای CPU، رم، دیسک، سایت و کانتینر

</td>
<td width="50%" valign="top">

### 🎨 طراحی
- 🌗 تم **تیره و روشن**
- 🇮🇷 **فارسی (راست‌به‌چپ)** و 🇬🇧 انگلیسی، با فونت وزیرمتن
- 📱 **ریسپانسیو کامل**: دسکتاپ، تبلت، گوشی
- ♿ رنگ‌ها همیشه با شکل و برچسب همراه‌اند، نه فقط رنگ

</td>
</tr>
</table>

<br>

## 🚀 نصب در یک دقیقه

> **نیازمندی:** یک سرور لینوکسی و دسترسی root (یا sudo). اگر Docker نباشد، نصب‌کننده خودش نصبش می‌کند.

### ⚡ نصب یک‌خطی

```bash
curl -fsSL https://raw.githubusercontent.com/AmiRAliw24/desktop-tutorial/HEAD/install.sh | sudo bash
```

چند سؤال ساده می‌پرسد (نام کاربری و رمز پنل، آدرس listen، توکن تلگرام و سایت‌ها، همه اختیاری)، بعد پنل روی `http://IP-SERVER:3000` بالا می‌آید. 🎉

<details>
<summary><b>🤖 نصب بدون سؤال (برای اسکریپت و اتوماسیون)</b></summary>

<br>

به `env` دقت کنید تا متغیرها به sudo برسند:

```bash
curl -fsSL https://raw.githubusercontent.com/AmiRAliw24/desktop-tutorial/HEAD/install.sh \
  | sudo env PANEL_PASSWORD='...' SITES='https://a.com' bash -s -- -y
```

یا با فایل کپی‌شده روی سرور:

```bash
sudo env PANEL_PASSWORD='...' PANEL_BIND=0.0.0.0 \
     TELEGRAM_BOT_TOKEN='...' TELEGRAM_CHAT_ID='...' \
     SITES='https://a.com,https://b.org' bash install.sh -y
```

</details>

<details>
<summary><b>📁 نصب تک‌فایل (اگر ریپو private است)</b></summary>

<br>

فقط فایل `install.sh` را روی سرور کپی کنید و اجرا کنید:

```bash
scp install.sh root@SERVER:
ssh root@SERVER 'bash install.sh'
```

نصب‌کننده همه فایل‌ها را در `/opt/server-monitoring` می‌سازد و استک را بالا می‌آورد.

</details>

<details>
<summary><b>🎛️ گزینه‌های نصب‌کننده</b></summary>

<br>

| گزینه | کار |
|---|---|
| `-y` | بدون سؤال، با متغیرهای محیطی و پیش‌فرض‌ها |
| `--no-start` | فقط فایل‌ها را بنویس، کانتینری بالا نیاور |
| `--uninstall` | کانتینرها را حذف کن (داده‌ها می‌مانند) |
| `--purge` | کانتینرها، داده‌ها و پوشه‌ی نصب را کامل حذف کن |

</details>

> 💡 **اجرای دوباره‌ی `install.sh` امن است.** کد آپدیت می‌شود و پنل ری‌استارت می‌شود، ولی `.env` و هر چیزی که از پنل تنظیم کرده‌اید (سایت‌ها، سرورها، تلگرام، قوانین، رمز) دست‌نخورده می‌ماند. برای گرفتن نسخه‌ی جدید همین دستور را دوباره بزنید.

> ℹ️ `HEAD` در آدرس همیشه به برنچ پیش‌فرض ریپو اشاره می‌کند. گیت‌هاب فایل‌های raw را تا چند دقیقه کش می‌کند، پس بعد از هر آپدیت ممکن است چند دقیقه نسخه‌ی قبلی را بدهد.

<br>

## 🧭 پنل وب

آدرس: **`http://IP-SERVER:3000`** · ورود با `PANEL_USER` و `PANEL_PASSWORD` از `.env` (بعد از تغییر رمز در پنل، رمز جدید معتبر است).

### 📍 صفحه‌ها

| | صفحه | چه چیزی نشان می‌دهد |
|:-:|---|---|
| 🏠 | **نمای کلی** | وضعیت کلی، گیج‌ها، کارت‌های آماری و نمودارهای CPU، رم، شبکه و load، همه زنده و هر ثانیه |
| 🌐 | **سایت‌ها** | آپتایم، زمان پاسخ، کد HTTP و انقضای SSL سایت‌ها و پورت‌ها |
| 💽 | **دیسک‌ها** | مصرف هر پارتیشن |
| 📡 | **شبکه** | کارت‌های شبکه و مصرف کامل آپلود/دانلود |
| 🎯 | **تارگت‌ها** | وضعیت منابعی که Prometheus از آن‌ها داده می‌گیرد |
| 🚨 | **هشدارها** | هشدارهای فعال و در انتظار |
| 🛡️ | **فایروال** | ضد DDoS، قوانین، لیست آی‌پی‌ها و لیست‌های تهدید، مدیریت SSH، fail2ban و امتیاز امنیت (پایین‌تر کامل توضیح داده شده) |
| 🖥️ | **سرورها** | افزودن و حذف سرورهای دیگر |
| 🔔 | **اعلان‌ها** | اتصال و تست تلگرام |
| 🎚️ | **قوانین هشدار** | روشن/خاموش و تغییر آستانه‌ها |
| ⚙️ | **تنظیمات** | رمز، رفع خودکار، وضعیت کنترل داکر |

<div align="center">
<img src="docs/screenshots/network-dark.png" alt="صفحه‌ی شبکه و مصرف ترافیک" width="92%">
<br><sub>📡 صفحه‌ی شبکه: کارت‌های شبکه، مصرف امروز / ۷ / ۳۰ روز / از زمان بوت و نمودار روزانه</sub>
</div>

<br>

### 🌐 سایت‌ها و پورت‌ها

افزودن و حذف سایت (HTTP/HTTPS) و پورت TCP برای چک آپتایم، زمان پاسخ و انقضای SSL.

- 🔍 **ذره‌بین کنار هر ردیف** چک را همان لحظه اجرا می‌کند و **دلیل ناموفق بودن** را به زبان ساده می‌گوید: قطع شدن handshake توسط سایت، پورت بسته، DNS، timeout، مشکل گواهی یا کد خطای HTTP.
- 🧪 برای سایتی که چک استاندارد را رد می‌کند، حالت‌های دیگر (TLS قدیمی ۱.۰/۱.۱، نادیده گرفتن خطای گواهی، HTTP ساده، فقط اتصال TCP) را هم امتحان می‌کند و می‌گوید کدام کار می‌کند. با **یک کلیک** همان حالت برای مانیتور آن سایت فعال می‌شود و کنار آدرس برچسب حالت دیده می‌شود.
- 🔀 اگر سایت فقط با HTTP ساده در دسترس باشد و HTTPS را برای این سرور رد کند، دکمه‌ی «مانیتور روی HTTP ساده» آدرس را (با حفظ نام) به `http://` تغییر می‌دهد.

<details>
<summary><b>🪄 رفع خودکار (پیش‌فرض روشن)</b></summary>

<br>

اگر سایتی که اضافه می‌کنید، یا سایتی که ۵ دقیقه خراب بوده، با چک استاندارد کار نکند، پنل خودش بهترین راه را پیدا و اعمال می‌کند:

1. حالت TLS دیگر
2. صفحه‌ای که آدرس `http://` سایت به آن ریدایرکت می‌شود
3. یا خود `http://`

✅ چکِ سالم **هرگز** تغییر نمی‌کند و سایتِ واقعاً خاموش دست‌نخورده می‌ماند.
📝 هر تغییر در بخش «Automatic adjustments» ثبت می‌شود و از **تنظیمات** قابل خاموش کردن است.

</details>

### 📡 ترافیک شبکه

زیر جدول کارت‌های شبکه، مصرف کامل آپلود و دانلود دیده می‌شود:

- 📅 **امروز** (به وقت مرورگر شما)، **۷ روز اخیر**، **۳۰ روز اخیر** و **از زمان بوت**
- 🟦🟧 نوار نسبت دانلود به آپلود در هر کارت
- ⚡ **اوج سرعت** ۲۴ ساعت اخیر
- 📊 **نمودار میله‌ای روزانه‌ی ۷ روز** با تولتیپ و نمای جدولی

آمار از Prometheus می‌آید و تا `PROMETHEUS_RETENTION` (پیش‌فرض ۳۰ روز) نگه داشته می‌شود. تا وقتی داده‌ی کافی جمع نشده، زیر هر کارت نوشته می‌شود چقدر داده وجود دارد.

### 🌍 آی‌پی عمومی

در کارت وضعیت کلی، **IPv4** و **IPv6** عمومی سرور نمایش داده می‌شود و با کلیک کپی می‌شود. یک کانتینر کوچک به نام `hostip` با شبکه‌ی خودِ سرور هر ۱۰ دقیقه آن را از `api.ipify.org` (و در صورت خطا `icanhazip.com` / `ident.me`) می‌پرسد. اگر سرور IPv6 ندارد «–» نشان داده می‌شود.

> 🔕 نمی‌خواهید به سایت بیرونی درخواست برود؟ در `.env` بنویسید `PUBLIC_IP_LOOKUP=0`.

### 🧰 مدیریت (همه از پنل)

| | بخش | کارها |
|:-:|---|---|
| 🖥️ | **سرورها** | افزودن و حذف سرورهای دیگر (با `node_exporter`)؛ دستور نصب روی سرور مقصد را همان‌جا می‌دهد |
| 🔔 | **اعلان‌ها** | اتصال ربات تلگرام (با دکمه‌ی «پیدا کردن Chat ID»)، پیام آزمایشی و هشدار آزمایشی |
| 🎚️ | **قوانین هشدار** | روشن/خاموش کردن هر قانون و تغییر آستانه و مدت پایداری (مثلاً CPU بالای ۷۰٪ به‌جای ۸۵٪)، با دکمه‌ی بازگشت به پیش‌فرض |
| ⚙️ | **تنظیمات** | تغییر نام کاربری و رمز، وضعیت دسترسی داکر، رفع خودکار |

### 📱 روی گوشی و تبلت

<div align="center">
<img src="docs/screenshots/phone-overview.png" alt="نمای کلی روی گوشی" width="26%">
&nbsp;&nbsp;
<img src="docs/screenshots/phone-websites.png" alt="لیست سایت‌ها روی گوشی" width="26%">
&nbsp;&nbsp;
<img src="docs/screenshots/overview-light.png" alt="تم روشن" width="40%">
</div>

<br>

| صفحه | چیدمان |
|---|---|
| 🖥️ دسکتاپ (۱۱۰۰px به بالا) | سایدبار کامل |
| 📲 تبلت (۷۰۰ تا ۱۰۹۹px) | نوار آیکون |
| 📱 گوشی (زیر ۷۰۰px) | نوار تب پایین + منوی «بیشتر»؛ جدول‌ها به کارت و پنجره‌ها به باتم‌شیت تبدیل می‌شوند |

<br>

## 🧱 سرویس‌ها

| سرویس | کار |
|---|---|
| 🧭 **پنل وب** | داشبورد و مدیریت کامل (پورت 3000) |
| 📈 **Prometheus** | جمع‌آوری و ذخیره‌ی متریک‌ها (۳۰ روز) |
| 🚨 **Alertmanager** | ارسال هشدار به تلگرام |
| 🖥️ **node_exporter** | متریک‌های سیستم: CPU، رم، دیسک، load |
| 📡 **node-net** | آمار واقعی کارت‌های شبکه‌ی سرور |
| 📦 **containers** | CPU و حافظه‌ی هر کانتینر Docker، مستقیم از cgroupهای کرنل (جایگزین cAdvisor که با داکر جدید کار نمی‌کند) |
| 🌐 **Blackbox exporter** | چک آپتایم سایت‌ها، پورت‌ها و انقضای SSL |
| 🌍 **hostip** | پیدا کردن IPv4 / IPv6 عمومی سرور |

<br>

## 🛡️ فایروال (ضد DDoS، قوانین، fail2ban)

صفحه‌ی **فایروال** در پنل، قوانین پورت، محافظت در برابر DDoS، قوانین کشور/آدرس/پورت، مدیریت fail2ban، محافظ حمله‌ی رمز SSH و سخت‌سازی سرور را یک جا جمع می‌کند. کار سطح پایین را یک سرویس جدا به نام `defender` انجام می‌دهد (nftables روی خود سرور) و پنل فقط از طریق یک سوکت با آن حرف می‌زند.

> 🟢 **بعد از نصب، محافظت خاموش است** و فایروال فقط نگاه می‌کند (آمار، بررسی امنیتی). از تب «نمای کلی» صفحه‌ی فایروال روشنش کنید.

### چه می‌کند

| | بخش | کار |
|:-:|---|---|
| 📊 | **نمای کلی** | وضعیت محافظت، بسته‌ها و ترافیک ورودی، اتصال‌های جدید، مسدودشده‌ها (هر ۲ ثانیه)، نمودار ۵ دقیقه‌ی اخیر، دلیل مسدودی‌ها، پرترافیک‌ترین آی‌پی‌ها با دکمه‌ی مسدود/مجاز، رویدادها |
| 🔥 | **پورت‌ها و قوانین** | **باز کردن پورت** با یک فرم (مثل `ufw allow`: هم در فایروال خود سرور — ufw، firewalld یا iptables، هر کدام روشن باشد — و هم در حالت سخت‌گیر)، ستون «فایروال سرور» برای هر سرویس با دکمه‌ی باز کردن، روشن/خاموش کردن ufw (پورت‌های در حال استفاده اول باز می‌شوند) و حذف قوانینش؛ حالت **باز** (فقط ترافیک مخرب بسته می‌شود) یا **سخت‌گیر** (فقط پورت‌های مجاز)، لیست سرویس‌هایی که از اینترنت باز هستند، قانون پورت با محدودیت منبع («این پورت فقط از این آی‌پی»)، اینترفیس‌های مورد اعتماد (VPN و تانل)، دیدن قوانین nftables قبل از اعمال |
| ⚡ | **ضد DDoS** | سه سطح آماده (عادی، سخت‌گیر، زیر حمله) و تنظیم دستی؛ برای هر آی‌پی: SYN فلاد، فلاد اتصال، اتصال هم‌زمان بیش از حد، UDP فلاد، پینگ فلاد، بسته‌های نامعتبر و اسکن پورت. هر کس ۳ برابر حد برود خودکار مسدود می‌شود |
| 🚨 | **تشخیص حمله** | با دیدن حمله، خودکار به حالت «زیر حمله» می‌رود و ۱۰ دقیقه بعد از پایان برمی‌گردد؛ پیام تلگرام شروع و پایان حمله |
| 🧭 | **قوانین** | قوانین فایروال مثل Cloudflare و ابر آروان: شرط بر اساس **کشور** (از / نه از این کشورها)، **آدرس** یا شبکه، **پروتکل** و **پورت**، و یکی از کارها: **اجازه** (حتی از محدودیت‌های فلاد رد شود)، **مسدود**، **محدود** با حساسیت کم/متوسط/زیاد/خیلی زیاد یا دلخواه و مسدودی خودکار، یا **فقط شمارش**. قوانین از بالا به پایین اجرا می‌شوند، هر قانون تعداد برخوردهایش را نشان می‌دهد و الگوهای آماده دارد (مسدود کردن کشورها، فقط چند کشور، محدودیت سخت برای کشورها، اجازه به یک آدرس، بستن یک پورت). لیست آی‌پی کشورها از ipdeny.com می‌آید و هر هفته بروز می‌شود؛ ادمین‌ها، لیست سفید و Cloudflare تحت تأثیر نیستند. هر قانون می‌تواند **ورودی یا خروجی** باشد (مثلاً بستن پورت‌های ایمیل خروجی یا ارتباط سرور با یک آدرس)، فقط در **روزها و ساعت‌های مشخص** فعال شود و **تاریخ انقضا** داشته باشد (۱ ساعت تا ۷ روز، بعد خودش خاموش می‌شود) |
| 📋 | **لیست آی‌پی‌ها** | مسدود موقت (۱ ساعت تا ۷ روز) یا همیشگی، لیست سفید، جدول همه‌ی مسدودها با **علت** (فلاد SYN، اتصال بیش از حد، اتصال SSH بیش از حد، رمز اشتباه SSH، نام قانون، دستی با یادداشت، جیل fail2ban)، **زمان مسدودی** و زمان باقی‌مانده، رفع مسدودی یا «مجاز کن» (رفع مسدودی و افزودن به لیست سفید) از همان‌جا؛ **بررسی آدرس** (این آی‌پی روی این پورت چه سرنوشتی دارد و کدام قانون تصمیم می‌گیرد، قدم به قدم) |
| 🛰️ | **لیست‌های تهدید** | ۹ لیست عمومی آدرس‌های مهاجم با یک کلید (Spamhaus DROP، FireHOL Level 1، abuse.ch Feodo Tracker، Emerging Threats، CINS Army، blocklist.de، IPsum، GreenSnow، نودهای خروجی Tor) و **لیست‌های خودتان** با آدرس https؛ برای هر لیست حالت **مسدود** یا **فقط نظارت** (می‌شمارد چه چیزی را مسدود می‌کرد، بدون مسدود کردن)، تعداد برخورد هر لیست، خطای آخرین دانلود و دکمه‌ی بروزرسانی؛ مسدود کردن **اتصال خود سرور** به آدرس‌های لیست (مثلاً سرورهای بات‌نت)؛ جدول **آدرس‌هایی که در یک ساعت اخیر** به لیست‌ها خورده‌اند با دکمه‌ی «مجاز کن»؛ بروزرسانی خودکار هر ۳ تا ۴۸ ساعت فقط وقتی محتوا عوض شده و بدون بازسازی فایروال؛ جواب اتصال‌هایی که خود سرور باز می‌کند هیچ‌وقت مسدود نمی‌شود |
| 🔑 | **SSH** | **مدیریت سرور SSH**: عوض کردن یا اضافه کردن پورت (تا ۵ پورت)، ورود root (آزاد / فقط با کلید / بسته)، خاموش کردن ورود با رمز، تعداد تلاش، زمان ورود، قطع نشست بی‌کار، فوروارد پورت و X11؛ **مدیریت کلیدهای SSH** کاربر root (افزودن، دیدن اثر انگشت، حذف)؛ و محافظ حمله‌ی رمز که آی‌پی‌هایی که مدام رمز اشتباه می‌زنند را مسدود می‌کند |
| 🚔 | **fail2ban** | نصب و حذف با یک کلیک، شروع/توقف/ری‌استارت و اجرا هنگام بوت؛ **ساخت، ویرایش کامل (همه‌ی گزینه‌ها: فیلتر، لاگ، پورت، backend، روش مسدودی، …) و حذف جیل‌ها**، و **ویرایشگر همه‌ی فایل‌های /etc/fail2ban** با بررسی و برگشت خودکار؛ هر جیل یک کارت با کلید روشن/خاموش، آمار مسدودها و تنظیمات ساده («۳ خطا در ۳۰ دقیقه ← ۱ ساعت مسدودی»)؛ محافظت‌های آماده (Nginx، Apache، ایمیل، FTP، MySQL، متخلفان تکراری) فقط وقتی آن سرویس هست؛ مسدودی تکراری طولانی‌تر، لیست «هرگز مسدود نشود»، مسدود/رفع مسدودی دستی و لاگ |
| 🧱 | **سخت‌سازی** | امتیاز امنیت و بررسی‌ها (ورود root با رمز، دیتابیس باز به اینترنت، آپدیت خودکار، ری‌بوت لازم، fail2ban متوقف، …) با راه رفع؛ تنظیمات شبکه‌ی کرنل با یک کلیک (و بازگشت به مقدار اصلی)؛ **پشتیبان‌گیری و بازگردانی** همه‌ی تنظیمات فایروال و fail2ban در یک فایل |
| 🧪 | **پیشرفته** | دسترسی کامل بدون محدودیت: قوانین دلخواه nftables، محدود کردن پنل به آی‌پی‌های خودتان، آستانه‌های تشخیص حمله، ضریب مسدودی خودکار، محدودیت SSH، مدت آزمایش تغییرات (یا خاموش)، اعتماد به داکر و کاربران SSH، باز ماندن اجباری پورت SSH و پنل (قابل خاموش کردن برای حرفه‌ای‌ها) و تنظیمات دلخواه کرنل |

### ایمنی (تا هرگز خودتان را بیرون نیندازید)

- پورت **SSH** و پورت **پنل** همیشه باز می‌مانند؛ لوپ‌بک، داکر و تانل‌ها (`wg*`، `gre*`، `tun*`، …) هرگز فیلتر نمی‌شوند.
- آی‌پی کسانی که با SSH وارد شده‌اند (الان یا در ۷ روز اخیر، از جمله اسکریپت‌ها و ابزارهایی که با SSH فرمان می‌زنند) خودکار مجاز است و آدرس خود سرور هرگز مسدود نمی‌شود.
- آی‌پی‌های **Cloudflare** از محدودیت هر آی‌پی معاف‌اند (قابل خاموش کردن در تب «پورت‌ها و قوانین»)، چون همه‌ی کاربران سایت یا پروکسی پشت Cloudflare از همین آی‌پی‌ها می‌آیند.
- هر تغییر فایروال **۶۰ ثانیه آزمایش** می‌شود؛ مرورگر بلافاصله تأیید می‌کند و اگر پنل دیگر در دسترس نباشد، تغییر خودش برمی‌گردد.
- تغییر **SSH** امن است: تنظیمات در فایل جدای `/etc/ssh/sshd_config.d/00-panel.conf` نوشته و با `sshd -t` بررسی می‌شود، پورت جدید پیش از ری‌استارت در فایروال باز می‌شود، پورت fail2ban هم هم‌زمان عوض می‌شود و نشست‌های باز قطع نمی‌شوند. اگر SSH روی همه‌ی پورت‌ها جواب ندهد همان لحظه برمی‌گردد؛ بعد از تغییر ۵ دقیقه فرصت دارید با تنظیمات جدید وارد شوید و «نگه دار» را بزنید، وگرنه خودکار به حالت قبل برمی‌گردد. خاموش کردن ورود با رمز بدون هیچ کلید SSH و حذف آخرین کلید در این حالت ممکن نیست.
  > ⚠️ اگر فایروال دیتاسنتر (مثل Hetzner Cloud Firewall) دارید، پورت جدید SSH را اول آن‌جا هم باز کنید.
- همه‌ی قوانین در یک جدول جدا (`inet defender`) هستند و فقط می‌توانند **محدود کنند** (قوانین خروجی هم فقط ترافیک خود سرور و کانتینرها به اینترنت را می‌بندند)؛ قوانین داکر، fail2ban و ufw دست نمی‌خورند.
- رفتن به حالت سخت‌گیر، همه‌ی پورت‌هایی که الان استفاده می‌شوند را از قبل در لیست مجاز می‌گذارد.
- تنظیمات fail2ban که از پنل عوض می‌شوند فقط در فایل جدای `/etc/fail2ban/jail.d/zzz-panel.local` نوشته می‌شوند (فایل‌های خودتان دست نمی‌خورند)؛ هر تغییر اول با `fail2ban-client -t` بررسی می‌شود، بعد از اعمال هم چک می‌شود که همه‌ی جیل‌های روشن واقعاً اجرا شده باشند، و اگر نه فایل‌های قبلی برمی‌گردند. قبل از ویرایش یا حذف هر فایل یک پشتیبان در `/etc/fail2ban/.panel-backup` ذخیره می‌شود.

**کلید اضطراری** (اگر هر اتفاقی افتاد، از کنسول سرور):

```bash
nft delete table inet defender
```

> ℹ️ فایروال فلاد شبکه (L3/L4) را دفع می‌کند. فلاد درخواست‌های معتبر HTTP (L7) و حمله‌هایی که از ظرفیت خود لینک شبکه بزرگ‌ترند را باید CDN یا سرویس ضد DDoS دیتاسنتر بگیرد.

### ⚡ سبک و بهینه

- وقتی کسی پنل را باز نکرده، کل پنل و فایروال روی هم کمتر از **۰٫۳٪ یک هسته** CPU مصرف می‌کنند.
- فایروال شمارنده‌ها را با کتابخانه‌ی nftables در همان پروسه می‌خواند (نه اجرای برنامه‌ی `nft` در هر ثانیه)، و وقتی صفحه‌ی فایروال باز نیست هر ۲ ثانیه نمونه می‌گیرد (در حمله یا وقتی صفحه باز است هر ثانیه).
- نمای زنده فقط اطلاعات لازم را از node_exporter می‌خواند (حدود ۱۰ برابر سبک‌تر) و فقط وقتی کسی آن را نگاه می‌کند.
- فایل‌های پنل یک بار فشرده و در حافظه نگه داشته می‌شوند؛ مرورگر آن‌ها را نگه می‌دارد و فقط تغییرشان را می‌پرسد.
- آمار کانتینرها را یک سرویس کوچک (به جای cAdvisor) فقط وقتی Prometheus می‌پرسد، هر ۳۰ ثانیه، از کرنل می‌خواند و healthcheck پنل به جای پایتون از `wget` استفاده می‌کند.

## 🔐 امنیت

> ⚠️ **مهم:** پنل به `/var/run/docker.sock` دسترسی دارد (فقط برای دیدن وضعیت کانتینرهای خود استک و ری‌استارت سرویس متوقف از صفحه‌ی «پیدا کردن دلیل»)، و **هر کسی که به این سوکت برسد روی کل سرور root است.** رمز قوی بگذارید و جلوی پنل HTTPS (مثلاً Caddy یا Nginx) قرار دهید؛ پنل روی HTTP ساده رمز را رمزنگاری نمی‌کند.

- 🔒 برای قطع کامل دسترسی پنل به داکر در `.env` بنویسید `PANEL_DOCKER_CONTROL=0` و `docker compose up -d` را بزنید (صفحه‌ی «پیدا کردن دلیل» آن‌وقت وضعیت کانتینرها را نشان نمی‌دهد).
- 🔑 **ورود دومرحله‌ای (2FA)** با Google Authenticator، Microsoft Authenticator، Authy و … از صفحه‌ی **امنیت پنل**؛ هر کد فقط یک بار کار می‌کند. گوشی گم شد؟ روی سرور فایل `data/panel/totp.json` را پاک کنید.
- 🚫 **قفل آدرس‌ها:** ۵ ورود اشتباه در ۱۵ دقیقه آن آدرس را قفل می‌کند (۱۵ دقیقه، هر بار دو برابر تا یک روز) و بعد از ۱۵ تلاش اشتباه، **فایروال** آن را یک ساعت مسدود می‌کند. قفل فقط همان آدرس را می‌بندد، نه شما را.
- 📱 **نشست‌های واقعی سمت سرور:** لیست دستگاه‌های واردشده با دکمه‌ی خروج، خروج واقعی با Logout، پایان نشست بعد از یک روز بی‌استفاده یا دو هفته، و خروج بقیه‌ی دستگاه‌ها با تغییر رمز یا روشن کردن 2FA. کوکی `HttpOnly` و `SameSite=Strict` است.
- 🧾 **گزارش امنیتی** (ورود، رمز اشتباه، قفل، تغییر رمز، 2FA) و پیام تلگرام برای ورود از آدرس جدید و قفل شدن یک آدرس.
- 🐢 **محدودیت درخواست:** درخواست‌های بدون ورود (اسکنرها و ربات‌ها) محدود به ۱۲۰ در دقیقه برای هر آدرس‌اند.
- 🧱 **فقط آدرس‌های خودتان:** در فایروال ← پیشرفته ← «چه کسی پنل را باز کند» می‌توانید پورت پنل را فقط برای آی‌پی‌های خودتان باز بگذارید؛ بقیه هیچ جوابی نمی‌گیرند.
- 🧢 هدرهای امنیتی: CSP سخت‌گیر، `X-Frame-Options`، `Permissions-Policy`، `Cross-Origin-Opener-Policy`، و `HSTS` و کوکی `Secure` وقتی پشت HTTPS هستید (`PANEL_TRUST_PROXY=1` در `.env` اگر پشت پروکسی خودتان هستید).
- 🛡️ همه‌ی عملیات تغییر (POST) هدر `X-Panel` و Origin درست می‌خواهند (محافظت CSRF).
- 👁️ داده‌ها را فقط‌خواندنی از Prometheus می‌گیرد؛ کوئری دلخواه از بیرون پذیرفته نمی‌شود.
- ✅ پنل فقط می‌تواند سرویس‌های همین استک را شروع یا ری‌استارت کند؛ ساختن، متوقف کردن یا حذف کانتینر از پنل ممکن نیست.
- 🧱 پورت پنل باید در فایروال سرور و پنل هاستینگ باز باشد. Prometheus و Alertmanager فقط روی `127.0.0.1` باز می‌شوند.
- 🔗 اگر پنل را روی `127.0.0.1` گذاشتید، از کامپیوتر خودتان با `ssh -L 3000:127.0.0.1:3000 root@SERVER` وصل شوید.

<details>
<summary><b>🔑 رمز را فراموش کرده‌اید؟</b></summary>

<br>

```bash
cd /opt/server-monitoring
rm data/panel/auth.json && docker compose restart panel
```

رمز به مقدار `PANEL_PASSWORD` در `.env` برمی‌گردد.

</details>

<br>

## 🎛️ تنظیمات

### 🧾 متغیرهای `.env`

| متغیر | پیش‌فرض | توضیح |
|---|---|---|
| `PANEL_USER` / `PANEL_PASSWORD` | `admin` / (الزامی) | ورود به پنل |
| `PANEL_PORT` | `3000` | پورت پنل (اگر اشغال باشد نصب‌کننده پورت آزاد پیدا می‌کند) |
| `PANEL_BIND` | `0.0.0.0` | آدرس listen؛ برای فقط‌محلی `127.0.0.1` |
| `PANEL_DOCKER_CONTROL` | `1` | `0` یعنی پنل اصلاً به داکر دسترسی ندارد |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | خالی | اتصال اولیه‌ی تلگرام (بعداً از صفحه‌ی اعلان‌ها هم می‌شود) |
| `PROMETHEUS_RETENTION` | `30d` | مدت نگهداری داده‌ها |
| `PROMETHEUS_RETENTION_SIZE` | `5GB` | بیشترین فضای دیسک برای داده‌ها، هر چه مدت نگهداری بگوید |
| `TELEGRAM_API` | `https://api.telegram.org` | آدرس API تلگرام؛ جایی که مسدود است، یک پراکسی یا Bot API Server محلی |
| `PUBLIC_IP_LOOKUP` | `1` | `0` یعنی نمایش آی‌پی عمومی خاموش |
| `DOCKER_GID` | خودکار | گروه صاحب `docker.sock` (نصب‌کننده پر می‌کند) |

> همه‌ی تنظیمات کاربری (سایت‌ها، سرورها، تلگرام، قوانین، رمز) را از خود پنل عوض کنید؛ `.env` فقط برای مقدارهای پایه است.

<details>
<summary><b>📂 فایل‌های تنظیمات (فقط وقتی پنل در دسترس نیست)</b></summary>

<br>

فایل‌ها را خود پنل می‌نویسد؛ دستی فقط وقتی ویرایش کنید که پنل در دسترس نیست:

- `prometheus/targets/{http,tcp,nodes}.json`: سایت‌ها، پورت‌ها و سرورها (قالب `file_sd` پرومتئوس؛ بعد از ذخیره خودکار اعمال می‌شود).
- `prometheus/rules/alerts.yml` و `alertmanager/alertmanager.yml`: از روی تنظیمات پنل تولید می‌شوند و ویرایش دستی‌شان بازنویسی می‌شود.
- `data/panel/settings.json`: توکن تلگرام و تنظیمات قوانین (مجوز 0600).

</details>

<details>
<summary><b>➕ اضافه کردن سرور دوم</b></summary>

<br>

1. روی آن سرور `node_exporter` اجرا کنید.
2. پورت `9100` را **فقط برای IP سرور مانیتورینگ** باز کنید.
3. در پنل، صفحه‌ی **سرورها** را باز کنید و آدرس را اضافه کنید. دستور نصب همان‌جا نوشته شده است.

</details>

<details>
<summary><b>🧑‍🔧 راه‌اندازی دستی (بدون نصب‌کننده)</b></summary>

<br>

```bash
cp .env.example .env                 # رمز پنل را بنویسید
echo "DOCKER_GID=$(stat -c %g /var/run/docker.sock)" >> .env
./scripts/render-config.sh           # پوشه‌ها، تنظیم اولیه‌ی Alertmanager و مجوزها (با sudo اجرا کنید)
docker compose up -d
```

- پنل وب: http://localhost:3000
- Prometheus: http://localhost:9090
- Alertmanager: http://localhost:9093

</details>

<br>

## 🔧 عیب‌یابی

### 🕰️ کار در درازمدت (بدون نگهداری)

- **به‌روزرسانی:** `bash install.sh --update` نسخه‌ی جدید نصب‌کننده را از اولین منبعی که جواب بدهد (GitHub یا پراکسی‌هایش) می‌گیرد، سالم بودنش را بررسی می‌کند و اجرا می‌کند؛ تنظیمات `.env` می‌مانند.
- **هر دانلود چند منبع دارد:** نصب Docker و Compose، ایمیج‌ها، بسته‌های Alpine، لیست کشورها (ipdeny ← دو لیست روی GitHub ← jsDelivr ← پراکسی‌ها)، لیست‌های تهدید و آدرس‌های Cloudflare. اگر منبعی از کار بیفتد یا مسدود شود، بعدی امتحان می‌شود و دانلود خالی یا صفحه‌ی خطا هیچ‌وقت جای نسخه‌ی سالم قبلی را نمی‌گیرد.
- **دیسک پر نمی‌شود:** لاگ هر کانتینر حداکثر ۳۰ مگابایت، داده‌های Prometheus حداکثر `PROMETHEUS_RETENTION_SIZE`، و همه‌ی فایل‌ها و جدول‌های داخلی (رویدادها، مسدودی‌ها، لاگ امنیت، محافظ SSH) سقف دارند.
- **نسخه‌ها ثابت‌اند:** ایمیج‌ها با نسخه‌ی مشخص و Compose با چک‌سام دانلود می‌شوند، پس یک نسخه‌ی جدید و ناسازگار ناخواسته نصب نمی‌شود. آدرس‌های Cloudflare هر هفته بروز می‌شوند و اگر نشد، لیست داخلی می‌ماند.

### 🇮🇷 نصب روی سرورهای ایران (خطای 403)

`get.docker.com` و Docker Hub به آی‌پی‌های ایران جواب `403` می‌دهند. نصب‌کننده برای هر چیزی که دانلود می‌کند چند منبع دارد و **اگر یکی خطا داد، سراغ بعدی می‌رود**:

| چه چیزی | منبع‌ها به ترتیب |
|---|---|
| اسکریپت نصب Docker | get.docker.com ← GitHub ← jsDelivr ← پراکسی GitHub (ghfast) |
| بسته‌های Docker | download.docker.com ← آینه‌ی آروان ← Aliyun ← Tsinghua ← بسته‌های خود سیستم‌عامل |
| Docker Compose | مخزن سیستم‌عامل ← GitHub ← پراکسی‌های GitHub (ghfast، gh-proxy، ghproxy)، با بررسی SHA-256 |
| ایمیج‌ها (Docker Hub) | Docker Hub ← آروان، ایران‌سرور، docker.ir، hamdocker، haiocloud، focker، mirror.gcr.io |
| بسته‌های Alpine (ایمیج فایروال) | CDN خود Alpine ← آروان ← dl-2 ← dl-4 ← Aliyun |

- فایل‌هایی که از پراکسی می‌آیند با چک‌سام رسمی بررسی می‌شوند؛ فایل دست‌کاری‌شده رد می‌شود و منبع بعدی امتحان می‌شود.
- از آینه‌های Docker Hub همه‌ی آن‌هایی که جواب می‌دهند به ترتیب تنظیم می‌شوند؛ اگر دانلود ایمیج‌ها شکست بخورد، هر آینه جداگانه امتحان می‌شود.
- هر لیست را می‌شود با متغیری به همان اسم عوض کرد (`DOCKER_SCRIPT_URLS`، `DOCKER_CE_MIRRORS`، `GITHUB_PROXIES`، `REGISTRY_MIRRORS`، `ALPINE_MIRRORS`)، یا یک آینه‌ی مشخص داد:

```bash
DOCKER_MIRROR=https://docker.arvancloud.ir ALPINE_MIRROR=https://mirror.arvancloud.ir/alpine bash install.sh
```

اگر خود GitHub هم باز نمی‌شود، `install.sh` را از اولین منبعی که جواب بدهد بگیرید:

```bash
for u in https://raw.githubusercontent.com/AmiRAliw24/Toofan-Monitor/HEAD/install.sh https://ghfast.top/https://raw.githubusercontent.com/AmiRAliw24/Toofan-Monitor/HEAD/install.sh https://gh-proxy.com/https://raw.githubusercontent.com/AmiRAliw24/Toofan-Monitor/HEAD/install.sh; do curl -fsSL -m 120 "$u" -o install.sh && break; done; sudo bash install.sh
```

<details>
<summary><b>⚡ آمار زنده چطور کار می‌کند؟</b></summary>

<br>

Prometheus هر ۱۵ ثانیه داده جمع می‌کند و نمودارها میانگین ۲ دقیقه را نشان می‌دهند، پس عددها کمی عقب‌اند. برای همین پنل وقتی صفحه‌ی **نمای کلی** یا **شبکه** باز است، خودش هر ثانیه از `node_exporter` همان سرور می‌خواند و با یک اتصال زنده (Server-Sent Events، مسیر `/api/live`) به مرورگر می‌فرستد. بالای صفحه «زنده · بروزرسانی هر ثانیه» با نقطه‌ی سبز یعنی اتصال برقرار است.

- فقط سرورهایی که Prometheus می‌شناسد قابل انتخاب‌اند و نمونه‌برداری حدود ۳۰ ثانیه بعد از بسته شدن صفحه خودش متوقف می‌شود.
- اگر داده‌ی زنده نرسد (مثلاً exporter سرور دیگر از پنل در دسترس نیست)، پنل خودش به داده‌های Prometheus برمی‌گردد و دلیل را بالای نمودارها می‌نویسد.
- اگر پنل پشت Nginx است، برای `/api/live` بافرینگ را خاموش کنید (`proxy_buffering off;`).

</details>


<details>
<summary><b>⚠️ بالای پنل نوشته «داده‌ها بارگذاری نشد»</b></summary>

<br>

روی دکمه‌ی **«پیدا کردن دلیل»** کنار پیام بزنید. پنل خودش سرویس‌ها (Prometheus، Alertmanager، Blackbox) را یکی‌یکی چک می‌کند (اول DNS، بعد HTTP)، وضعیت و کد خروج و تعداد ری‌استارت هر کانتینر، پر بودن دیسک و کار کردن DNS اینترنت را نشان می‌دهد، آخرین خط‌های لاگ کانتینرهای خراب را می‌آورد و کنار هر کانتینر متوقف دکمه‌ی ری‌استارت دارد. خطای `Temporary failure in name resolution` (`Errno -3`) یعنی DNS داخلی داکر جواب نمی‌دهد؛ معمولاً چون کانتینر Prometheus خاموش است یا resolver سرور خراب است.

اگر بعد از ری‌استارت سرور، Prometheus و Alertmanager و Blackbox با `Exited (0)` خاموش مانده‌اند، از نسخه‌های قدیمی نصب‌کننده است: آن نسخه‌ها برای خواندن دوباره‌ی تنظیمات `docker compose kill -s SIGHUP` می‌زدند و داکر این را «توقف دستی» حساب می‌کند، پس `unless-stopped` بعد از بوت آن‌ها را بالا نمی‌آورد. یک بار `install.sh` جدید را اجرا کنید (یا `docker compose up -d` و بعد `docker compose restart prometheus alertmanager blackbox` در `/opt/server-monitoring`) تا درست شود.

</details>

<details>
<summary><b>📡 جدول شبکه خالی است</b></summary>

<br>

`node_exporter` داخل کانتینر فقط شبکه‌ی خود کانتینر را می‌بیند، نه کارت‌های واقعی سرور. به همین دلیل سرویس جدای `node-net` (همان `node_exporter` با `privileged` و خواندن از `/proc/1`، یعنی namespace شبکه‌ی خود سرور) آمار واقعی کارت‌ها (مثل `eth0`) را می‌دهد و `node_exporter` اصلی آمار شبکه را نمی‌دهد تا دوبار شمرده نشود. پنل بالای جدول دلیل خالی بودن را می‌نویسد؛ برای جزئیات:

```bash
docker compose logs --tail 20 node-net
```

</details>

<details>
<summary><b>💾 پنل نمی‌تواند تنظیمات را ذخیره کند</b></summary>

<br>

پنل با کاربر `65534` اجرا می‌شود و باید روی این پوشه‌ها بنویسد. نصب‌کننده خودش مجوزها را درست می‌کند؛ دستی:

```bash
cd /opt/server-monitoring
sudo chown -R 65534:65534 data prometheus/targets prometheus/rules alertmanager
docker compose restart panel
```

</details>

<details>
<summary><b>🔌 نصب‌کننده با خطای 404 جواب می‌دهد</b></summary>

<br>

ریپو باید **public** باشد. اگر private است، فایل `install.sh` را با `scp` روی سرور کپی کنید و اجرا کنید.

</details>

<details>
<summary><b>⬆️ ارتقا از نسخه‌ی قدیمی</b></summary>

<br>

فقط `install.sh` را دوباره اجرا کنید:

- لاگین قدیمی (`GRAFANA_ADMIN_*`) به `PANEL_*` منتقل می‌شود.
- کانتینر Grafana حذف می‌شود.
- فایل‌های قدیمی سایت‌ها و سرورها (`prometheus/targets/*.yml`) خودکار به قالب جدید (`*.json`) مهاجرت می‌کنند (فایل قدیمی به `.migrated` تغییر نام می‌دهد).
- اگر قبلاً تلگرام را در `.env` گذاشته بودید، به پنل منتقل می‌شود.

داده‌های قدیمی Grafana روی دیسک می‌مانند؛ اگر لازم ندارید: `docker volume rm server-monitoring_grafana_data`.

</details>

<br>

## 🧑‍💻 برای توسعه‌دهنده‌ها

`install.sh` از روی فایل‌های همین ریپو ساخته می‌شود. بعد از تغییر هر فایل:

```bash
./scripts/build-installer.sh
```

```
.
├── docker-compose.yml        # کل استک
├── install.sh                # نصب‌کننده‌ی تک‌فایل (تولیدشده)
├── panel/                    # پنل وب (پایتون + HTML/CSS/JS ساده، بدون وابستگی)
│   ├── server.py             #   مسیرها، احراز هویت، امنیت
│   ├── store.py              #   سایت‌ها، سرورها، تلگرام، قوانین، رفع خودکار
│   ├── monitor.py            #   کوئری‌های فقط‌خواندنی Prometheus
│   ├── hostip.py             #   پیدا کردن آی‌پی عمومی
│   ├── live.py               #   آمار زنده‌ی هر ثانیه
│   ├── defender.py           #   رابط پنل با فایروال و اعلان تلگرام
│   └── static/               #   رابط کاربری
├── defender/                 # سرویس فایروال (nftables، ضد DDoS، قوانین، fail2ban، محافظ SSH، بررسی امنیتی)
├── prometheus/ blackbox/     # تنظیمات
├── scripts/                  # ساخت نصب‌کننده و ابزارها
└── docs/screenshots/         # تصاویر این صفحه
```

<br>

<div align="center">

با ❤️ برای کسی که می‌خواهد سرورش را بدون دردسر ببیند و مدیریت کند.

</div>
__MONITORING_EOF__
  write_file prometheus/prometheus.yml 644 <<'__MONITORING_EOF__'
global:
  # 30 s is plenty for history and alerts (the panel's rates use 2-minute windows); the live view reads
  # the exporters itself. Half the work of the default 15 s for Prometheus and every exporter.
  scrape_interval: 30s
  evaluation_interval: 30s

rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: [alertmanager:9093]

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: [localhost:9090]

  # Servers to monitor. Targets live in prometheus/targets/nodes.json, managed from the panel (reloaded automatically).
  # Each remote server runs its own node_exporter (with all default collectors, incl. network).
  - job_name: node
    file_sd_configs:
      - files: [/etc/prometheus/targets/nodes.json]
        refresh_interval: 15s

  # Real network-card stats of THIS server (see node-net in docker-compose.yml). Reported under
  # the same instance name as the main exporter so the panel shows them as one server.
  - job_name: node-net
    static_configs:
      - targets: [node-net:9100]
    relabel_configs:
      - target_label: instance
        replacement: node-exporter:9100

  # CPU and memory of each Docker container (see the containers service in docker-compose.yml).
  - job_name: containers
    static_configs:
      - targets: [containers:9338]

  # Uptime / SSL checks. Targets live in prometheus/targets/http.json, managed from the panel.
  - job_name: blackbox-http
    metrics_path: /probe
    file_sd_configs:
      - files: [/etc/prometheus/targets/http.json]
        refresh_interval: 15s
    relabel_configs:
      # Standard check, unless the site has a check_module label (set from the panel for sites that need
      # old TLS or must ignore certificate errors). A fixed `params: module` would override any label.
      - target_label: __param_module
        replacement: http_2xx
      - source_labels: [check_module]
        regex: (.+)
        target_label: __param_module
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115

  # TCP port checks (e.g. SSH, database). Targets live in prometheus/targets/tcp.json, managed from the panel.
  - job_name: blackbox-tcp
    metrics_path: /probe
    params:
      module: [tcp_connect]
    file_sd_configs:
      - files: [/etc/prometheus/targets/tcp.json]
        refresh_interval: 15s
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115
__MONITORING_EOF__
  write_file blackbox/blackbox.yml 644 <<'__MONITORING_EOF__'
modules:
  http_2xx:
    prober: http
    timeout: 10s
    http:
      preferred_ip_protocol: ip4
      follow_redirects: true

  # The variants below exist for sites that fail the normal check. The panel tries them for you
  # ("Test now / why?" on the Websites page) and can switch a single site to one of them.
  # Sites that only speak the outdated TLS 1.0 / 1.1:
  http_2xx_legacy:
    prober: http
    timeout: 10s
    http:
      preferred_ip_protocol: ip4
      follow_redirects: true
      tls_config:
        min_version: TLS10

  # Sites whose certificate is expired, self-signed or for another name:
  http_2xx_insecure:
    prober: http
    timeout: 10s
    http:
      preferred_ip_protocol: ip4
      follow_redirects: true
      tls_config:
        insecure_skip_verify: true

  http_2xx_legacy_insecure:
    prober: http
    timeout: 10s
    http:
      preferred_ip_protocol: ip4
      follow_redirects: true
      tls_config:
        min_version: TLS10
        insecure_skip_verify: true

  tcp_connect:
    prober: tcp
    timeout: 5s
__MONITORING_EOF__
  write_file scripts/render-config.sh 755 <<'__MONITORING_EOF__'
#!/usr/bin/env bash
# Prepares what the stack needs before it starts:
#  - alertmanager/alertmanager.yml: a minimal valid config. The panel replaces it as soon as
#    Telegram is connected (Notifications page), so this file is never edited by hand.
#  - data/panel/settings.json: seeds Telegram from TELEGRAM_* in .env, only if the panel has no settings yet.
#  - ownership of the directories the panel writes to (it runs as uid 65534).
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p alertmanager data/panel prometheus/rules prometheus/targets

if [ ! -f alertmanager/alertmanager.yml ]; then
  printf '%s\n' 'route:' '  receiver: none' 'receivers:' '  - name: none' > alertmanager/alertmanager.yml
fi

if [ -f .env ] && [ ! -f data/panel/settings.json ]; then
  set -a; . ./.env; set +a
  token=${TELEGRAM_BOT_TOKEN:-}; chat=${TELEGRAM_CHAT_ID:-}
  if [[ $token =~ ^[0-9]{5,15}:[A-Za-z0-9_-]{25,80}$ && $chat =~ ^-?[0-9]{1,20}$ ]]; then
    umask 077
    printf '{"telegram": {"token": "%s", "chat_id": "%s"}}\n' "$token" "$chat" > data/panel/settings.json
  fi
fi

if [ "$(id -u)" = 0 ]; then
  chown -R 65534:65534 data/panel prometheus/targets prometheus/rules alertmanager
fi
echo "Prepared alertmanager config and panel data directories"
__MONITORING_EOF__
  write_file panel/server.py 644 <<'__MONITORING_EOF__'
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
__MONITORING_EOF__
  write_file panel/store.py 644 <<'__MONITORING_EOF__'
"""Everything the panel can change: monitored sites/ports/servers, alert rules and Telegram.

State lives in plain files so the stack keeps working without the panel:
  CONFIG/targets/{http,tcp,nodes}.json   Prometheus file_sd targets (picked up automatically)
  CONFIG/rules/alerts.yml                generated from the rule settings below
  CONFIG/alertmanager/alertmanager.yml   generated from the Telegram settings
  DATA/settings.json                     panel settings (Telegram credentials, rule overrides)
Files are written atomically; Prometheus / Alertmanager are reloaded over HTTP afterwards.
"""
import json
import os
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urljoin, urlparse
from urllib.request import Request, urlopen

CONFIG = Path(os.environ.get("CONFIG_DIR", "/config"))
DATA = Path(os.environ.get("DATA_DIR", "/data"))
PROM_URL = os.environ.get("PROMETHEUS_URL", "http://prometheus:9090").rstrip("/")
AM_URL = os.environ.get("ALERTMANAGER_URL", "http://alertmanager:9093").rstrip("/")
TELEGRAM_API = os.environ.get("TELEGRAM_API", "https://api.telegram.org").rstrip("/")
BLACKBOX_URL = os.environ.get("BLACKBOX_URL", "http://blackbox:9115").rstrip("/")
LOCAL_NODE = "node-exporter:9100"
LOCK = threading.RLock()


class ConfigError(ValueError):
    """The request was invalid (shown to the user as-is)."""


class ApplyError(Exception):
    """The change was saved, but Prometheus/Alertmanager could not be reloaded."""


# ------------------------------------------------------------------ files and reloads

def atomic_write(path, text, mode=0o644):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")  # not matched by the *.json / *.yml globs
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def _write_if_changed(path, text, mode=0o644):
    try:
        if Path(path).read_text(encoding="utf-8") == text:
            return False
    except OSError:
        pass
    atomic_write(path, text, mode)
    return True


def _post(url, what):
    try:
        with urlopen(Request(url, data=b"", method="POST"), timeout=10):
            return
    except HTTPError as e:
        detail = e.read(300).decode("utf-8", "replace").strip()
        raise ApplyError(f"{what} rejected the new configuration: {detail or e.code}") from e
    except (URLError, OSError) as e:
        raise ApplyError(f"{what} is not reachable: {getattr(e, 'reason', e)}") from e


def reload_prometheus():
    _post(f"{PROM_URL}/-/reload", "Prometheus")


def reload_alertmanager():
    _post(f"{AM_URL}/-/reload", "Alertmanager")


def load_settings():
    try:
        data = json.loads((DATA / "settings.json").read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_settings(settings):
    atomic_write(DATA / "settings.json", json.dumps(settings, indent=2), 0o600)


# ------------------------------------------------------------------ targets (sites, ports, servers)

KINDS = {"http": "http.json", "tcp": "tcp.json", "nodes": "nodes.json"}
# How an HTTP(S) site is checked. Each mode is a blackbox module (see blackbox/blackbox.yml); a site that
# needs a non-default one gets a check_module label, which prometheus.yml relabels into the probe's module.
HTTP_MODES = {"default": "http_2xx", "legacy_tls": "http_2xx_legacy", "no_verify": "http_2xx_insecure",
              "legacy_no_verify": "http_2xx_legacy_insecure"}
MODE_BY_MODULE = {v: k for k, v in HTTP_MODES.items()}
MAX_TARGETS = 200
URL_RE = re.compile(r"^https?://[^\s\"'`<>\\]{1,500}$")
HOST_PORT_RE = re.compile(r"^(?:[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?|\[[0-9A-Fa-f:.]+\]):(\d{1,5})$")
NAME_RE = re.compile(r"^[^\x00-\x1f\"'`<>\\]{0,60}$")


def _targets_file(kind):
    if kind not in KINDS:
        raise ConfigError("unknown kind")
    return CONFIG / "targets" / KINDS[kind]


def validate_target(kind, target):
    target = str(target or "").strip()
    if kind == "http":
        parsed = urlparse(target)
        try:
            port_ok = parsed.port is None or 1 <= parsed.port <= 65535
        except ValueError:
            port_ok = False
        if (not URL_RE.match(target) or not parsed.hostname or not port_ok or parsed.netloc.endswith(":")
                or not re.match(r"^[A-Za-z0-9._-]+$|^[0-9A-Fa-f:.]+$", parsed.hostname)):
            raise ConfigError("Enter a full address such as https://example.com")
    else:
        m = HOST_PORT_RE.match(target)
        if not m or not 1 <= int(m.group(1)) <= 65535:
            raise ConfigError("Enter an address in the form host:port, for example 203.0.113.10:22")
    return target


def _read_groups(kind):
    try:
        data = json.loads(_targets_file(kind).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    return [g for g in data if isinstance(g, dict) and isinstance(g.get("targets"), list)] if isinstance(data, list) else []


def list_targets(kind):
    rows = []
    for g in _read_groups(kind):
        labels = g.get("labels") or {}
        for t in g["targets"]:
            rows.append({"target": t, "name": labels.get("name") or labels.get("instance_name") or "",
                         "locked": kind == "nodes" and t == LOCAL_NODE,
                         "mode": MODE_BY_MODULE.get(labels.get("check_module", ""), "default") if kind == "http" else "default",
                         "auto_from": labels.get("auto_from", "")})
    return rows


def _write_groups(kind, groups):
    atomic_write(_targets_file(kind), json.dumps(groups, indent=2, ensure_ascii=False))


def add_target(kind, target, name=""):
    target = validate_target(kind, target)
    name = str(name or "").strip()
    if not NAME_RE.match(name):
        raise ConfigError("The name contains characters that are not allowed")
    with LOCK:
        groups = _read_groups(kind)
        if any(target in g["targets"] for g in groups):
            raise ConfigError("This address is already being monitored")
        if sum(len(g["targets"]) for g in groups) >= MAX_TARGETS:
            raise ConfigError("Too many entries")
        label = "instance_name" if kind == "nodes" else "name"
        groups.append({"targets": [target], "labels": {label: name} if name else {}})
        _write_groups(kind, groups)
    if kind == "http":
        auto_fix_async(target)


def remove_target(kind, target):
    target = str(target or "").strip()
    if kind == "nodes" and target == LOCAL_NODE:
        raise ConfigError("This is the server the monitoring stack runs on; it cannot be removed")
    with LOCK:
        groups = _read_groups(kind)
        kept = [{**g, "targets": [t for t in g["targets"] if t != target]} for g in groups]
        kept = [g for g in kept if g["targets"]]
        if sum(len(g["targets"]) for g in kept) == sum(len(g["targets"]) for g in groups):
            raise ConfigError("Not found")
        _write_groups(kind, kept)


def _blackbox(module, target):
    query = urlencode({"module": module, "target": target, "debug": "true"})
    try:
        with urlopen(f"{BLACKBOX_URL}/probe?{query}", timeout=25) as resp:
            text = resp.read(200_000).decode("utf-8", "replace")
    except HTTPError as e:
        text = e.read(200_000).decode("utf-8", "replace")
    except (URLError, OSError) as e:
        raise ApplyError(f"The blackbox checker is not reachable: {getattr(e, 'reason', e)}") from e
    ok = re.search(r"^probe_success\s+1\b", text, re.M) is not None
    status = re.search(r"^probe_http_status_code\s+(\d+)", text, re.M)
    http_status = int(status.group(1)) if status and int(status.group(1)) else None
    reason = ""
    for line in text.splitlines():                          # the first error carrying err="..." is the real cause
        m = re.search(r'level=error.*?err="((?:[^"\\]|\\.)*)"', line)
        if m:
            reason = m.group(1).replace('\\"', '"')
            break
    redirects = [m.group(1).strip('"') for m in re.finditer(r'msg="Received redirect" location=("(?:[^"\\]|\\.)*"|\S+)', text)]
    return {"ok": ok, "reason": reason, "kind": "" if ok else classify_failure(reason, http_status), "http_status": http_status,
            "redirects": redirects, "log": "\n".join(l for l in text.splitlines() if not l.startswith("#"))[-20000:]}


def final_url(start, redirects):
    """Where a chain of (possibly relative) redirects ends. Empty if there were none."""
    url = start
    for location in redirects:
        url = urljoin(url, location)
    return url if redirects else ""


def _variant_plan(target, mode):
    """Other ways to check the same website: (id, blackbox module, address to probe)."""
    parsed = urlparse(target)
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    host = f"[{parsed.hostname}]" if ":" in (parsed.hostname or "") else parsed.hostname
    plan = [(m, HTTP_MODES[m], target) for m in HTTP_MODES if m != mode]
    if parsed.scheme == "https":
        plan.append(("plain_http", "http_2xx", "http://" + target[len("https://"):]))
    plan.append(("tcp", "tcp_connect", f"{host}:{port}"))
    return plan


def _run_variants(target, mode):
    """Probe every variant in parallel. Returns [(id, probed address, result)]."""
    plan = _variant_plan(target, mode)
    with ThreadPoolExecutor(max_workers=len(plan)) as pool:
        outcomes = list(pool.map(lambda p: _blackbox(p[1], p[2]), plan))
    return [(vid, vtarget, out) for (vid, _module, vtarget), out in zip(plan, outcomes)]


def probe_debug(kind, target):
    """Run one check right now and say why it failed. For a failing website also try the other modes
    (old TLS, ignoring certificate errors, plain HTTP, bare TCP) so the user can see what would work."""
    if kind not in ("http", "tcp"):
        raise ConfigError("unknown kind")
    target = str(target or "").strip()
    row = next((r for r in list_targets(kind) if r["target"] == target), None)
    if row is None:
        raise ConfigError("Only monitored addresses can be tested")
    mode = row["mode"]
    result = _blackbox(HTTP_MODES[mode] if kind == "http" else "tcp_connect", target)
    result["mode"] = mode
    result["variants"], result["suggest"] = [], ""
    if result["ok"] or kind != "http":
        return result
    for vid, vtarget, out in _run_variants(target, mode):
        result["variants"].append({"id": vid, "ok": out["ok"], "reason": out["reason"], "kind": out["kind"],
                                   "http_status": out["http_status"],
                                   "final_url": final_url(vtarget, out["redirects"]) if vid == "plain_http" else ""})
    result["suggest"] = next((v["id"] for v in result["variants"] if v["ok"] and v["id"] in HTTP_MODES), "")
    return result


def classify_failure(reason, http_status):
    """Map a blackbox error to a short code the UI turns into a plain-language explanation."""
    r = reason.lower()
    if "x509" in r or "certificate" in r:                  # checked first: these errors also contain "tls:"
        return "tls"
    if "handshake failure" in r or "protocol version" in r or "no cipher" in r or "remote error: tls" in r:
        return "handshake"
    if "connection reset" in r or "unexpected eof" in r or "eof" in r.split(":")[-1]:
        return "reset"
    if "connection refused" in r:
        return "refused"
    if "no such host" in r or "server misbehaving" in r or "lookup" in r:
        return "dns"
    if "timeout" in r or "deadline exceeded" in r:
        return "timeout"
    if "network is unreachable" in r or "no route" in r:
        return "unreachable"
    if http_status and not reason:
        return "status"
    return "status" if http_status else "other"


def replace_target(kind, old, new, extra_labels=None):
    """Swap one address for another, keeping its name (e.g. to monitor a site over http:// instead of https://)."""
    new = validate_target(kind, new)
    old = str(old or "").strip()
    with LOCK:
        groups = _read_groups(kind)
        match = next((g for g in groups if old in g["targets"]), None)
        if match is None:
            raise ConfigError("Not found")
        if old != new and any(new in g["targets"] for g in groups):
            raise ConfigError("This address is already being monitored")
        labels = {k: v for k, v in (match.get("labels") or {}).items() if k != "check_module"}   # new address: standard check
        labels.update(extra_labels or {})
        rest = [{**g, "targets": [t for t in g["targets"] if t != old]} for g in groups]
        rest = [g for g in rest if g["targets"]]
        rest.append({"targets": [new], "labels": labels})
        _write_groups(kind, rest)


def set_mode(kind, target, mode):
    if kind != "http":
        raise ConfigError("Only websites have a check mode")
    if mode not in HTTP_MODES:
        raise ConfigError("Unknown mode")
    target = str(target or "").strip()
    with LOCK:
        groups = _read_groups("http")
        hit = False
        for g in groups:
            if target in g["targets"]:
                labels = dict(g.get("labels") or {})
                labels.pop("check_module", None)
                if mode != "default":
                    labels["check_module"] = HTTP_MODES[mode]
                if len(g["targets"]) > 1:      # keep other targets of a shared group untouched
                    g["targets"] = [t for t in g["targets"] if t != target]
                    groups.append({"targets": [target], "labels": labels})
                else:
                    g["labels"] = labels
                hit = True
                break
        if not hit:
            raise ConfigError("Not found")
        _write_groups("http", groups)


# ------------------------------------------------------------------ automatic fixing of failing websites

AUTO_COOLDOWN = 1800          # seconds between automatic attempts for the same address
_auto_last, _auto_busy = {}, set()
SECURE_MODES = ("legacy_tls", "no_verify", "legacy_no_verify")


def auto_enabled():
    return bool(load_settings().get("auto_fix", True))


def set_auto_enabled(enabled):
    with LOCK:
        s = load_settings()
        s["auto_fix"] = bool(enabled)
        save_settings(s)


def auto_events(limit=10):
    return list(reversed(load_settings().get("auto_events", [])[-limit:]))


def _record_event(**event):
    with LOCK:
        s = load_settings()
        s["auto_events"] = (s.get("auto_events", []) + [{"t": int(time.time()), **event}])[-30:]
        save_settings(s)


def auto_fix(target):
    """Find the best way to monitor a website that fails its standard check, and apply it.

    Never touches a check that currently passes. Order of preference: another TLS mode on the same
    address, then the address the site's plain http:// version finally redirects to (if that passes a
    standard check), then the plain http:// address itself. Returns the recorded event or None."""
    row = next((r for r in list_targets("http") if r["target"] == target), None)
    if row is None:
        return None
    if _blackbox(HTTP_MODES[row["mode"]], target)["ok"]:
        return None
    outcomes = _run_variants(target, row["mode"])
    ok = {vid: (vtarget, out) for vid, vtarget, out in outcomes if out["ok"]}
    mode = next((m for m in SECURE_MODES if m in ok), None)
    if mode:
        set_mode("http", target, mode)
        event = {"action": "mode", "from": target, "mode": mode}
    elif "plain_http" in ok:
        plain_url, out = ok["plain_http"]
        new = plain_url
        landing = final_url(plain_url, out["redirects"])
        if landing.startswith("https://") and landing != target and _blackbox("http_2xx", landing)["ok"]:
            new = landing                                   # the page users really reach, with its real certificate
        event = {"action": "replace", "from": target, "to": new}
        existing = {r["target"] for r in list_targets("http")}
        if new in existing:                                 # already monitored: the failing entry is just a duplicate
            remove_target("http", target)
            event["action"] = "merge"
        else:
            replace_target("http", target, new, {"auto_from": target})
    else:
        return None
    _record_event(**event)
    return event


def auto_fix_async(target):
    """Run auto_fix in the background right after a site is added."""
    if not auto_enabled():
        return

    def run():
        try:
            _auto_last[target] = time.time()
            auto_fix(target)
        except Exception:        # background helper: a failure must never break adding a site
            pass
        finally:
            _auto_busy.discard(target)

    if target not in _auto_busy:
        _auto_busy.add(target)
        threading.Thread(target=run, daemon=True).start()


def auto_scan():
    """Called periodically: fix websites that have failed for the last five minutes."""
    if not auto_enabled():
        return
    import monitor
    down = {m.get("instance", "") for m, _ in monitor.vector('min_over_time(probe_success{job="blackbox-http"}[5m]) == 0')}
    managed = {r["target"] for r in list_targets("http")}
    for target in sorted(down & managed):
        if time.time() - _auto_last.get(target, 0) >= AUTO_COOLDOWN and target not in _auto_busy:
            _auto_last[target] = time.time()
            try:
                auto_fix(target)
            except Exception:
                pass


def auto_loop():
    time.sleep(90)
    while True:
        try:
            auto_scan()
        except Exception:
            pass
        time.sleep(300)


def _legacy_items(text):
    """Targets from the old hand-edited YAML files (simple lists, one item per line or inline)."""
    items = []
    for line in text.splitlines():
        line = line.split(" #")[0].rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = re.match(r"^\s*-\s*targets:\s*\[(.*)\]\s*$", line)
        if m:
            items += [x.strip().strip("'\"") for x in m.group(1).split(",") if x.strip()]
            continue
        if re.match(r"^\s*-\s*targets:\s*$", line):
            continue
        m = re.match(r"^\s{2,}-\s+(\S.*)$", line)
        if m:
            items.append(m.group(1).strip().strip("'\""))
    return items


def migrate_legacy():
    """Create the JSON target files, importing anything from the old *.yml files first."""
    for kind, fname in KINDS.items():
        json_file = CONFIG / "targets" / fname
        yml_file = json_file.with_suffix(".yml")
        if not json_file.exists():
            groups = []
            if yml_file.exists():
                for t in _legacy_items(yml_file.read_text(encoding="utf-8")):
                    try:
                        validate_target(kind, t)
                    except ConfigError:
                        continue
                    if not any(t in g["targets"] for g in groups):
                        groups.append({"targets": [t], "labels": {}})
            if kind == "nodes":
                local = next((g for g in groups if LOCAL_NODE in g["targets"]), None)
                if local is None:
                    groups.insert(0, {"targets": [LOCAL_NODE], "labels": {"instance_name": "this-server"}})
                elif not local["labels"]:
                    local["labels"] = {"instance_name": "this-server"}
            _write_groups(kind, groups)
        if yml_file.exists():
            yml_file.rename(yml_file.with_suffix(".yml.migrated"))


# ------------------------------------------------------------------ alert rules

HOST_FS = 'fstype!~"tmpfs|overlay|squashfs"'
DOCKER_CG = r'id=~".*docker[-/][a-f0-9]{64}(\\.scope)?"'   # Docker containers by their cgroup (see cstats.py)
CONTAINER = "{{ if $labels.name }}{{ $labels.name }}{{ else }}{{ $labels.id }}{{ end }}"
RULES = [
    {"name": "InstanceDown", "group": "host", "severity": "critical", "for": 2, "expr": "up == 0",
     "summary": "{{ $labels.job }} target {{ $labels.instance }} is down"},
    {"name": "HighCpuUsage", "group": "host", "severity": "warning", "for": 10,
     "expr": '100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > {t}',
     "t": {"default": 85, "unit": "%", "min": 1, "max": 100},
     "summary": 'CPU usage on {{ $labels.instance }} is {{ $value | printf "%.0f" }}%'},
    {"name": "HighMemoryUsage", "group": "host", "severity": "warning", "for": 10,
     "expr": "(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > {t}",
     "t": {"default": 90, "unit": "%", "min": 1, "max": 100},
     "summary": 'Memory usage on {{ $labels.instance }} is {{ $value | printf "%.0f" }}%'},
    {"name": "DiskSpaceLow", "group": "host", "severity": "warning", "for": 10,
     "expr": f"(1 - node_filesystem_avail_bytes{{{HOST_FS}}} / node_filesystem_size_bytes{{{HOST_FS}}}) * 100 > {{t}}",
     "t": {"default": 85, "unit": "%", "min": 1, "max": 100},
     "summary": 'Disk {{ $labels.mountpoint }} on {{ $labels.instance }} is {{ $value | printf "%.0f" }}% full'},
    {"name": "DiskWillFillIn24h", "group": "host", "severity": "critical", "for": 30,
     "expr": f"predict_linear(node_filesystem_avail_bytes{{{HOST_FS}}}[6h], {{t}} * 3600) < 0",
     "t": {"default": 24, "unit": "h", "min": 1, "max": 168},
     "summary": "Disk {{ $labels.mountpoint }} on {{ $labels.instance }} is predicted to fill up soon"},
    {"name": "HighLoad", "group": "host", "severity": "warning", "for": 10,
     "expr": 'node_load5 / count by (instance) (node_cpu_seconds_total{mode="idle"}) > {t}',
     "t": {"default": 2, "unit": "x cores", "min": 0.1, "max": 50},
     "summary": 'Load average on {{ $labels.instance }} is high ({{ $value | printf "%.1f" }}x cores)'},
    {"name": "HostRebooted", "group": "host", "severity": "info", "for": 0,
     "expr": "time() - node_boot_time_seconds < {t}",
     "t": {"default": 300, "unit": "s", "min": 60, "max": 3600},
     "summary": "{{ $labels.instance }} was rebooted recently"},
    {"name": "ContainerHighCpu", "group": "containers", "severity": "warning", "for": 10,
     "expr": f"sum by (id, name) (rate(container_cpu_usage_seconds_total{{{DOCKER_CG}}}[5m])) * 100 > {{t}}",
     "t": {"default": 90, "unit": "%", "min": 1, "max": 1000},
     "summary": f'Container {CONTAINER} CPU is {{{{ $value | printf "%.0f" }}}}%'},
    {"name": "ContainerHighMemory", "group": "containers", "severity": "warning", "for": 10,
     "expr": f"container_memory_working_set_bytes{{{DOCKER_CG}}} / (container_spec_memory_limit_bytes{{{DOCKER_CG}}} > 0) * 100 > {{t}}",
     "t": {"default": 90, "unit": "%", "min": 1, "max": 100},
     "summary": f'Container {CONTAINER} memory is {{{{ $value | printf "%.0f" }}}}% of its limit (or of the server memory if it has none)'},
    {"name": "EndpointDown", "group": "endpoints", "severity": "critical", "for": 2, "expr": "probe_success == 0",
     "summary": "{{ $labels.instance }} is unreachable"},
    {"name": "SslCertExpiringSoon", "group": "endpoints", "severity": "warning", "for": 60,
     "expr": "(probe_ssl_earliest_cert_expiry - time()) / 86400 < {t}",
     "t": {"default": 14, "unit": "days", "min": 1, "max": 90},
     "summary": 'SSL certificate for {{ $labels.instance }} expires in {{ $value | printf "%.0f" }} days'},
    {"name": "SlowEndpoint", "group": "endpoints", "severity": "warning", "for": 10,
     "expr": "probe_duration_seconds > {t}",
     "t": {"default": 3, "unit": "s", "min": 0.1, "max": 60},
     "summary": 'The response of {{ $labels.instance }} is slow ({{ $value | printf "%.1f" }}s)'},
]
RULE_BY_NAME = {r["name"]: r for r in RULES}


def _num(v):
    return str(int(v)) if float(v) == int(v) else repr(float(v))


def get_rules():
    overrides = load_settings().get("rules", {})
    out = []
    for r in RULES:
        o = overrides.get(r["name"], {})
        t = r.get("t")
        out.append({
            "name": r["name"], "group": r["group"], "severity": r["severity"],
            "enabled": o.get("enabled", True),
            "has_threshold": t is not None,
            "unit": t["unit"] if t else "", "min": t["min"] if t else None, "max": t["max"] if t else None,
            "default": t["default"] if t else None, "value": o.get("value", t["default"]) if t else None,
            "for": o.get("for", r["for"]), "default_for": r["for"],
        })
    return out


def render_rules(settings=None):
    overrides = (settings if settings is not None else load_settings()).get("rules", {})
    groups = {}
    for r in RULES:
        o = overrides.get(r["name"], {})
        if not o.get("enabled", True):
            continue
        expr = r["expr"]
        if "t" in r:
            expr = expr.replace("{t}", _num(o.get("value", r["t"]["default"])))
        minutes = int(o.get("for", r["for"]))
        lines = [f"      - alert: {r['name']}", f"        expr: '{expr}'"]
        if minutes:
            lines.append(f"        for: {minutes}m")
        lines += [f"        labels: {{severity: {r['severity']}}}",
                  "        annotations:", f"          summary: '{r['summary']}'"]
        groups.setdefault(r["group"], []).append("\n".join(lines))
    body = "".join(f"  - name: {g}\n    rules:\n" + "\n".join(rules) + "\n" for g, rules in groups.items())
    return "# Managed by the web panel (Alert rules page). Manual edits are overwritten.\ngroups:\n" + (body or "  []\n")


def apply_rules():
    _write_if_changed(CONFIG / "rules" / "alerts.yml", render_rules())
    reload_prometheus()


def set_rule(name, enabled, value, minutes):
    r = RULE_BY_NAME.get(name)
    if not r:
        raise ConfigError("Unknown rule")
    entry = {"enabled": bool(enabled)}
    if "t" in r:
        try:
            v = float(value)
        except (TypeError, ValueError):
            raise ConfigError("The threshold must be a number") from None
        if not r["t"]["min"] <= v <= r["t"]["max"]:
            raise ConfigError(f"The threshold must be between {r['t']['min']} and {r['t']['max']} {r['t']['unit']}")
        entry["value"] = v
    try:
        m = int(minutes)
    except (TypeError, ValueError):
        raise ConfigError("The duration must be a whole number of minutes") from None
    if not 0 <= m <= 1440:
        raise ConfigError("The duration must be between 0 and 1440 minutes")
    entry["for"] = m
    with LOCK:
        s = load_settings()
        s.setdefault("rules", {})[name] = entry
        save_settings(s)
        apply_rules()


def reset_rules():
    with LOCK:
        s = load_settings()
        s.pop("rules", None)
        save_settings(s)
        apply_rules()


# ------------------------------------------------------------------ Telegram + Alertmanager

TOKEN_RE = re.compile(r"^\d{5,15}:[A-Za-z0-9_-]{25,80}$")
CHAT_RE = re.compile(r"^-?\d{1,20}$")

AM_MINIMAL = "# Managed by the web panel. No notification channel is configured.\nroute:\n  receiver: none\nreceivers:\n  - name: none\n"
AM_TELEGRAM = """# Managed by the web panel (Notifications page). Manual edits are overwritten.
route:
  receiver: telegram
  group_by: [alertname, instance]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - matchers: [severity="critical"]
      receiver: telegram
      repeat_interval: 1h

receivers:
  - name: telegram
    telegram_configs:
      - bot_token: "@TOKEN@"
        chat_id: @CHAT@
        parse_mode: ""
        send_resolved: true
        message: |
          {{ range .Alerts }}{{ if eq .Status "firing" }}\U0001F525{{ else }}✅{{ end }} [{{ .Labels.severity }}] {{ .Annotations.summary }}
          {{ end }}

inhibit_rules:
  - source_matchers: [severity="critical"]
    target_matchers: [severity="warning"]
    equal: [alertname, instance]
"""


def mask_token(token):
    return f"{token.split(':')[0]}:••••{token[-4:]}" if token else ""


def telegram_status():
    t = load_settings().get("telegram") or {}
    return {"configured": bool(t.get("token") and t.get("chat_id")), "chat_id": t.get("chat_id", ""),
            "token_hint": mask_token(t.get("token", "")), "bot": t.get("bot", "")}


def render_alertmanager(settings=None):
    t = (settings if settings is not None else load_settings()).get("telegram") or {}
    if t.get("token") and t.get("chat_id") and TOKEN_RE.match(t["token"]) and CHAT_RE.match(str(t["chat_id"])):
        return AM_TELEGRAM.replace("@TOKEN@", t["token"]).replace("@CHAT@", str(t["chat_id"]))
    return AM_MINIMAL


def apply_alertmanager():
    # The directory is bind-mounted, so replacing the file (new inode) is visible to the container.
    _write_if_changed(CONFIG / "alertmanager" / "alertmanager.yml", render_alertmanager())
    reload_alertmanager()


def _telegram(token, method, params=None):
    url = f"{TELEGRAM_API}/bot{token}/{method}"
    try:
        with urlopen(Request(url, data=urlencode(params).encode() if params else None), timeout=15) as resp:
            body = json.load(resp)
    except HTTPError as e:
        try:
            body = json.load(e)
        except ValueError:
            body = {"ok": False, "description": f"HTTP {e.code}"}
    except (URLError, OSError) as e:
        raise ConfigError(f"Cannot reach Telegram: {getattr(e, 'reason', e)}".replace(token, "***")) from e
    if not body.get("ok"):
        raise ConfigError(f"Telegram says: {body.get('description', 'error')}".replace(token, "***"))
    return body["result"]


def _resolve_token(token):
    token = str(token or "").strip()
    if not token:
        token = (load_settings().get("telegram") or {}).get("token", "")
    if not TOKEN_RE.match(token):
        raise ConfigError("Enter the bot token you got from @BotFather (it looks like 123456789:AA...)")
    return token


def telegram_chats(token=""):
    """Chats that recently wrote to the bot, so the user can pick the chat id instead of typing it."""
    token = _resolve_token(token)
    chats = {}
    for u in _telegram(token, "getUpdates", {"limit": 100, "timeout": 0}):
        for key in ("message", "edited_message", "channel_post", "my_chat_member"):
            chat = (u.get(key) or {}).get("chat")
            if chat:
                title = chat.get("title") or chat.get("username") or " ".join(
                    x for x in (chat.get("first_name"), chat.get("last_name")) if x)
                chats[chat["id"]] = {"id": str(chat["id"]), "title": title or str(chat["id"]), "type": chat.get("type", "")}
    return list(chats.values())


def telegram_test(token="", chat_id=""):
    token = _resolve_token(token)
    chat_id = str(chat_id or (load_settings().get("telegram") or {}).get("chat_id", "")).strip()
    if not CHAT_RE.match(chat_id):
        raise ConfigError("Enter the chat id (a number, negative for groups)")
    _telegram(token, "sendMessage", {"chat_id": chat_id, "text": "✅ Server Monitor: this is a test message. Alerts will arrive here."})


def save_telegram(token, chat_id):
    token = _resolve_token(token)
    chat_id = str(chat_id or "").strip()
    if not CHAT_RE.match(chat_id):
        raise ConfigError("Enter the chat id (a number, negative for groups)")
    bot = _telegram(token, "getMe").get("username", "")  # proves the token works before saving it
    with LOCK:
        s = load_settings()
        s["telegram"] = {"token": token, "chat_id": chat_id, "bot": bot}
        save_settings(s)
        apply_alertmanager()
    return {"bot": bot}


def remove_telegram():
    with LOCK:
        s = load_settings()
        s.pop("telegram", None)
        save_settings(s)
        apply_alertmanager()


def send_test_alert():
    """Fire a synthetic alert through Alertmanager (delivered after its ~30s grouping delay)."""
    now = time.time()
    fmt = lambda ts: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))  # noqa: E731
    body = json.dumps([{"labels": {"alertname": "PanelTestAlert", "severity": "info"},
                        "annotations": {"summary": "Test alert sent from the web panel"},
                        "startsAt": fmt(now), "endsAt": fmt(now + 300)}]).encode()
    try:
        with urlopen(Request(f"{AM_URL}/api/v2/alerts", data=body, headers={"Content-Type": "application/json"}), timeout=10):
            pass
    except (URLError, OSError) as e:
        raise ApplyError(f"Alertmanager is not reachable: {getattr(e, 'reason', e)}") from e


# ------------------------------------------------------------------ startup

def bootstrap():
    """Create/migrate files and make Prometheus and Alertmanager pick them up (retries while they start)."""
    for sub in ("targets", "rules", "alertmanager"):
        (CONFIG / sub).mkdir(parents=True, exist_ok=True)
    DATA.mkdir(parents=True, exist_ok=True)
    migrate_legacy()
    settings = load_settings()
    changed_rules = _write_if_changed(CONFIG / "rules" / "alerts.yml", render_rules(settings))
    changed_am = _write_if_changed(CONFIG / "alertmanager" / "alertmanager.yml", render_alertmanager(settings))

    def reload_later():
        for _ in range(30):
            try:
                if changed_rules:
                    reload_prometheus()
                if changed_am:
                    reload_alertmanager()
                return
            except ApplyError:
                time.sleep(5)

    if changed_rules or changed_am:
        threading.Thread(target=reload_later, daemon=True).start()
__MONITORING_EOF__
  write_file panel/auth.py 644 <<'__MONITORING_EOF__'
"""Panel login: credentials from the environment, optionally replaced by a password changed in the panel.

A changed password is stored as a salted PBKDF2 hash in DATA/auth.json (mode 0600). Session cookies are
HMAC-signed with a key derived from the current credentials, so changing the password logs out every
other session. Forgot it? Delete DATA/auth.json to fall back to PANEL_USER / PANEL_PASSWORD from .env.
"""
import hashlib
import hmac
import json
import os
import secrets
import threading
import time
from pathlib import Path

SESSION_TTL = 7 * 24 * 3600
ITERATIONS = 200_000


def _hash(password, salt, iterations=ITERATIONS):
    return hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations).hex()


class Auth:
    def __init__(self, env_user, env_password, data_dir):
        self.env_user, self.env_password = env_user, env_password
        self.file = Path(data_dir) / "auth.json"
        self.lock = threading.Lock()
        self._load()

    def _load(self):
        self.stored = None
        try:
            data = json.loads(self.file.read_text(encoding="utf-8"))
            if all(k in data for k in ("user", "salt", "hash", "iterations")):
                self.stored = data
        except (OSError, ValueError):
            pass
        if self.stored:
            self.user = self.stored["user"]
            material = self.stored["hash"]
        else:
            self.user = self.env_user
            material = self.env_password
        self.secret = hashlib.sha256(f"panel-session:{self.user}:{material}".encode()).digest()

    # -- credentials
    def verify(self, user, password):
        ok_user = hmac.compare_digest(user.encode(), self.user.encode())
        if self.stored:
            digest = _hash(password, bytes.fromhex(self.stored["salt"]), int(self.stored["iterations"]))
            ok_pass = hmac.compare_digest(digest, self.stored["hash"])
        else:
            ok_pass = hmac.compare_digest(password.encode(), self.env_password.encode())
        return ok_user & ok_pass

    def change(self, current, new, new_user=None):
        new_user = (new_user or self.user).strip()
        if not self.verify(self.user, current):
            raise ValueError("The current password is wrong")
        if not 8 <= len(new) <= 128:
            raise ValueError("The new password must be 8 to 128 characters")
        if new == current and new_user == self.user:
            raise ValueError("The new password must differ from the current one")
        if not 1 <= len(new_user) <= 64 or any(c in new_user for c in "\x00\r\n:|"):
            raise ValueError("Invalid username")
        salt = secrets.token_bytes(16)
        data = {"user": new_user, "salt": salt.hex(), "iterations": ITERATIONS, "hash": _hash(new, salt)}
        with self.lock:
            self.file.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.file.with_name(f".{self.file.name}.tmp")
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump(data, f)
            os.replace(tmp, self.file)
            self._load()

    # -- sessions
    def make_token(self):
        payload = f"{self.user}|{int(time.time()) + SESSION_TTL}"
        sig = hmac.new(self.secret, payload.encode(), hashlib.sha256).hexdigest()
        return f"{payload}.{sig}"

    def valid_token(self, token):
        try:
            payload, sig = token.rsplit(".", 1)
            expected = hmac.new(self.secret, payload.encode(), hashlib.sha256).hexdigest()
            user, exp = payload.split("|")
            return hmac.compare_digest(sig, expected) and user == self.user and int(exp) > time.time()
        except (ValueError, AttributeError):
            return False
__MONITORING_EOF__
  write_file panel/dockerapi.py 644 <<'__MONITORING_EOF__'
"""Minimal Docker Engine API client over the unix socket (standard library only).

Mounting the Docker socket gives whoever controls it root on the host, so everything that reaches the
daemon is validated here. The panel only reads the state and logs of its own stack and can start or
restart a stopped service of that stack (from the self-diagnosis page); nothing else.
"""
import http.client
import json
import os
import re
import socket
from urllib.parse import urlencode

SOCKET = os.environ.get("DOCKER_SOCKET_PATH", "/var/run/docker.sock")
ENABLED = os.environ.get("PANEL_DOCKER_CONTROL", "1") != "0"
STACK_PROJECT = os.environ.get("COMPOSE_PROJECT_NAME", "server-monitoring")
SELF_ID = os.environ.get("PANEL_CONTAINER_ID") or socket.gethostname()  # a container's hostname is its short id by default

ID_RE = re.compile(r"^[a-f0-9]{12,64}$")
ACTIONS = {"start", "restart"}


class DockerError(Exception):
    pass


def _require():
    if not ENABLED:
        raise DockerError("Docker control is switched off (PANEL_DOCKER_CONTROL=0)")


class _UnixConnection(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__("localhost", timeout=timeout)
        self._path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self._path)


def _request(method, path, body=None, timeout=30):
    conn = _UnixConnection(SOCKET, timeout)
    try:
        payload = json.dumps(body).encode() if body is not None else None
        headers = {"Content-Type": "application/json"} if payload is not None else {}
        conn.request(method, path, body=payload, headers=headers)
        resp = conn.getresponse()
        return resp.status, resp.read()
    except OSError as e:
        raise DockerError(f"cannot reach Docker: {e}") from e
    finally:
        conn.close()


def _json(status, data, ok=(200, 201, 204)):
    if status in ok:
        return json.loads(data) if data else {}
    try:
        message = json.loads(data).get("message", "")
    except ValueError:
        message = data.decode("utf-8", "replace")[:300]
    raise DockerError(message or f"Docker returned HTTP {status}")


def available():
    if not ENABLED:
        return False
    try:
        status, _ = _request("GET", "/_ping", timeout=3)
        return status == 200
    except DockerError:
        return False


def _port_list(c):
    ports = []
    for p in c.get("Ports", []):
        if p.get("PublicPort"):
            ports.append(f"{p.get('IP', '')}:{p['PublicPort']}->{p['PrivatePort']}/{p['Type']}".lstrip(":"))
        else:
            ports.append(f"{p['PrivatePort']}/{p['Type']}")
    return sorted(set(ports))


def list_containers():
    _require()
    rows = []
    for c in _json(*_request("GET", "/containers/json?all=1")):
        labels = c.get("Labels") or {}
        cid = c["Id"]
        rows.append({
            "id": cid[:12],
            "name": (c.get("Names") or ["/?"])[0].lstrip("/"),
            "image": c.get("Image", ""),
            "state": c.get("State", ""),
            "status": c.get("Status", ""),
            "created": c.get("Created"),
            "ports": _port_list(c),
            "stack": labels.get("com.docker.compose.project") == STACK_PROJECT,
            "self": cid.startswith(SELF_ID) or SELF_ID.startswith(cid[:12]),
        })
    return sorted(rows, key=lambda r: (not r["stack"], r["name"]))


def _find(cid):
    if not ID_RE.match(cid or ""):
        raise ValueError("bad container id")
    for row in list_containers():
        if row["id"].startswith(cid[:12]):
            return row
    raise DockerError("container not found")


def revive(cid, action):
    """Start or restart a container of the monitoring stack (never the panel itself)."""
    _require()
    if action not in ACTIONS:
        raise ValueError("unknown action")
    row = _find(cid)
    if not row["stack"]:
        raise ValueError("only containers of the monitoring stack can be restarted here")
    if row["self"]:
        raise ValueError("the panel cannot control its own container")
    status, data = _request("POST", f"/containers/{row['id']}/{action}" + ("?t=10" if action == "restart" else ""), timeout=60)
    if status == 304:  # already in the requested state
        return {"ok": True, "unchanged": True}
    _json(status, data)
    return {"ok": True}


def _demux(data):
    """Docker multiplexes stdout/stderr into 8-byte-header frames unless the container has a TTY."""
    out, i = [], 0
    while i + 8 <= len(data) and data[i] in (0, 1, 2) and data[i + 1:i + 4] == b"\x00\x00\x00":
        size = int.from_bytes(data[i + 4:i + 8], "big")
        out.append(data[i + 8:i + 8 + size])
        i += 8 + size
    if i == 0:  # not framed (TTY container)
        return data.decode("utf-8", "replace")
    return b"".join(out).decode("utf-8", "replace")


def logs(cid, tail=200):
    _require()
    row = _find(cid)
    tail = max(1, min(int(tail), 2000))
    status, data = _request("GET", f"/containers/{row['id']}/logs?" + urlencode(
        {"stdout": 1, "stderr": 1, "tail": tail, "timestamps": 1}), timeout=30)
    if status != 200:
        _json(status, data)
    return {"name": row["name"], "text": _demux(data)[-200_000:]}


def stack_health():
    """State of every container of this compose project, including why a stopped one stopped."""
    _require()
    rows = []
    for c in _json(*_request("GET", "/containers/json?all=1")):
        labels = c.get("Labels") or {}
        if labels.get("com.docker.compose.project") != STACK_PROJECT:
            continue
        info = _json(*_request("GET", f"/containers/{c['Id'][:12]}/json"))
        st = info.get("State") or {}
        rows.append({
            "id": c["Id"][:12], "service": labels.get("com.docker.compose.service", ""),
            "name": (c.get("Names") or ["/?"])[0].lstrip("/"), "state": st.get("Status", c.get("State", "")),
            "status": c.get("Status", ""), "exit_code": st.get("ExitCode"), "restarts": info.get("RestartCount", 0),
            "oom": bool(st.get("OOMKilled")), "error": st.get("Error", ""), "health": (st.get("Health") or {}).get("Status", ""),
        })
    return sorted(rows, key=lambda r: r["service"])
__MONITORING_EOF__
  write_file panel/monitor.py 644 <<'__MONITORING_EOF__'
"""Read-only Prometheus queries behind the panel's dashboard pages. Only fixed queries are exposed."""
import json
import math
import os
import re
import time
from urllib.error import URLError
from urllib.parse import urlencode
from urllib.request import urlopen

PROM = os.environ.get("PROMETHEUS_URL", "http://prometheus:9090").rstrip("/")
PUBLIC_IP_FILE = os.path.join(os.environ.get("DATA_DIR", "/data"), "public-ip.json")


def public_ip():
    """Written by the hostip container; {} until its first lookup has finished."""
    try:
        with open(PUBLIC_IP_FILE) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return {}
    return {"v4": d.get("v4"), "v6": d.get("v6"), "disabled": bool(d.get("disabled")), "checked": d.get("checked")}


def prom_get(path, params=None):
    url = f"{PROM}{path}" + (f"?{urlencode(params)}" if params else "")
    for attempt in range(3):
        try:
            with urlopen(url, timeout=8) as resp:
                body = json.load(resp)
            break
        except URLError as e:   # EAI_AGAIN: Docker's DNS hiccups for a moment while a container restarts
            if getattr(e.reason, "errno", None) != -3 or attempt == 2:
                raise
            time.sleep(0.5)
    if body.get("status") != "success":
        raise RuntimeError(body.get("error", "query failed"))
    return body["data"]


def num(v):
    try:
        v = float(v)
    except (TypeError, ValueError):
        return None
    return v if math.isfinite(v) else None


def vector(expr):
    data = prom_get("/api/v1/query", {"query": expr})
    return [(s["metric"], num(s["value"][1])) for s in data["result"]]


def scalar(expr):
    rows = vector(expr)
    return rows[0][1] if rows else None


def by_label(expr, label):
    return {m.get(label, ""): v for m, v in vector(expr)}


INSTANCE_RE = re.compile(r"^[A-Za-z0-9_.:\-\[\]]{1,128}$")
VIRTUAL_NICS = 'device!~"lo|veth.*|docker.*|br-.*|virbr.*|cni.*|cali.*|flannel.*|ifb.*"'
FALLBACK_NICS = re.compile(r"^(gre0|gretap0|erspan0|ip6gre0|ip6tnl0|ip6_vti0|ip_vti0|sit0|tunl0)$")
REAL_FS = 'fstype!~"tmpfs|overlay|squashfs|devtmpfs|ramfs|fuse.*|nsfs|proc|sysfs|cgroup.*"'


def node_instances():
    return sorted({m.get("instance", "") for m, _ in vector('up{job="node"}')} - {""})


def node_selector(instance, net=False):
    """Label selector for one server. net=True also matches the node-net job (real NIC stats)."""
    if not instance:
        found = node_instances()
        instance = found[0] if found else ""
    if instance and not INSTANCE_RE.match(instance):
        raise ValueError("bad instance")
    job = 'job=~"node|node-net"' if net else 'job="node"'
    return f'{job},instance="{instance}"' if instance else job

# ------------------------------------------------------------------ api handlers

def api_instances(_q):
    rows = vector('up{job="node"}')
    names = {m.get("instance", ""): m.get("instance_name", "") for m, _ in rows}
    live = {m.get("instance", "") for m, v in rows if v}
    # Reachable servers first, so the panel opens on one that actually has data.
    order = sorted(set(names) - {""}, key=lambda i: (i not in live, i))
    return {"instances": order, "names": {k: v for k, v in names.items() if k and v}}


def api_overview(q):
    n = node_selector(q.get("instance"))
    nn = node_selector(q.get("instance"), net=True)
    info = (vector(f"node_uname_info{{{n}}}") or [({}, None)])[0][0]
    osinfo = (vector(f"node_os_info{{{n}}}") or [({}, None)])[0][0]
    cpuinfo = (vector(f"node_cpu_info{{{n}}}") or [({}, None)])[0][0]
    mem_total = scalar(f"node_memory_MemTotal_bytes{{{n}}}")
    mem_avail = scalar(f"node_memory_MemAvailable_bytes{{{n}}}")
    swap_total = scalar(f"node_memory_SwapTotal_bytes{{{n}}}")
    swap_free = scalar(f"node_memory_SwapFree_bytes{{{n}}}")
    disks = disk_rows(n)
    root = next((d for d in disks if d["mount"] == "/"), disks[0] if disks else None)
    alerts = prom_get("/api/v1/alerts")["alerts"]
    ssl_days = scalar("min((probe_ssl_earliest_cert_expiry > 0) - time()) / 86400")
    return {
        "host": {
            "name": info.get("nodename", ""),
            "os": osinfo.get("pretty_name", ""),
            "kernel": info.get("release", ""),
            "cpu_model": cpuinfo.get("model_name", ""),
            "cores": scalar(f"count(count by (cpu) (node_cpu_seconds_total{{{n}}}))"),
        },
        "public_ip": public_ip(),
        "cpu": scalar(f'100 - avg(rate(node_cpu_seconds_total{{{n},mode="idle"}}[2m])) * 100'),
        "mem": {"total": mem_total, "used": None if mem_total is None or mem_avail is None else mem_total - mem_avail},
        "swap": {"total": swap_total, "used": None if swap_total is None or swap_free is None else swap_total - swap_free},
        "disk": root,
        "load": [scalar(f"node_load{p}{{{n}}}") for p in (1, 5, 15)],
        "net": {
            "rx": scalar(f"sum(rate(node_network_receive_bytes_total{{{nn},{VIRTUAL_NICS}}}[2m]))"),
            "tx": scalar(f"sum(rate(node_network_transmit_bytes_total{{{nn},{VIRTUAL_NICS}}}[2m]))"),
        },
        "targets": {"up": scalar("sum(up)") or 0, "total": scalar("count(up)") or 0},
        "checks": {
            "up": scalar('sum(probe_success{job=~"blackbox.*"})') or 0,
            "total": scalar('count(probe_success{job=~"blackbox.*"})') or 0,
            "min_ssl_days": ssl_days,
        },
        "alerts": {
            "firing": sum(1 for a in alerts if a["state"] == "firing"),
            "pending": sum(1 for a in alerts if a["state"] == "pending"),
        },
    }


def disk_rows(n):
    size = {(m["mountpoint"], m.get("device", ""), m.get("fstype", "")): v
            for m, v in vector(f"node_filesystem_size_bytes{{{n},{REAL_FS}}}") if v}
    avail = {m["mountpoint"]: v for m, v in vector(f"node_filesystem_avail_bytes{{{n},{REAL_FS}}}")}
    rows, seen = [], set()
    for (mount, device, fstype), total in sorted(size.items()):
        if mount in seen or mount not in avail:
            continue
        seen.add(mount)
        used = total - avail[mount]
        rows.append({"mount": mount, "device": device, "fstype": fstype, "total": total, "used": used,
                     "pct": used / total * 100})
    return rows


def api_disks(q):
    return {"rows": disk_rows(node_selector(q.get("instance")))}


def net_exporter_status():
    """State of the node-net scrape target, so the UI can explain an empty network table."""
    for t in prom_get("/api/v1/targets", {"state": "active"})["activeTargets"]:
        if t["labels"].get("job") == "node-net":
            return {"present": True, "up": t["health"] != "down", "error": t.get("lastError", "")}
    return {"present": False, "up": False, "error": ""}


def api_network(q):
    n = node_selector(q.get("instance"), net=True)
    # Rows come from the counters so cards show up immediately; rates need ~30s of samples.
    rx_total = by_label(f"node_network_receive_bytes_total{{{n},{VIRTUAL_NICS}}}", "device")
    tx_total = by_label(f"node_network_transmit_bytes_total{{{n},{VIRTUAL_NICS}}}", "device")
    up = by_label(f"node_network_up{{{n},{VIRTUAL_NICS}}}", "device")
    rx = by_label(f"rate(node_network_receive_bytes_total{{{n},{VIRTUAL_NICS}}}[2m])", "device")
    tx = by_label(f"rate(node_network_transmit_bytes_total{{{n},{VIRTUAL_NICS}}}[2m])", "device")
    speed = by_label(f"node_network_speed_bytes{{{n},{VIRTUAL_NICS}}}", "device")
    # Tunnels (WireGuard, GRE, ...) report their state as "unknown", which node_network_up counts as down
    # although they carry traffic: treat "unknown" with traffic as up.
    unknown = set(by_label(f'node_network_info{{{n},{VIRTUAL_NICS},operstate="unknown"}}', "device"))

    def is_up(d):
        if up.get(d) == 1 or d not in up:
            return True
        return d in unknown and bool((rx_total.get(d) or 0) + (tx_total.get(d) or 0))

    rows = [{"device": d, "up": is_up(d), "rx": rx.get(d), "tx": tx.get(d),
             "rx_total": rx_total.get(d), "tx_total": tx_total.get(d),
             "speed": speed.get(d) if (speed.get(d) or 0) > 0 else None}
            for d in sorted(set(rx_total) | set(tx_total) | set(up))
            # the kernel's placeholder devices for tunnel modules (gre0, erspan0, ...) never carry traffic
            if not (FALLBACK_NICS.match(d) and not (rx_total.get(d) or 0) and not (tx_total.get(d) or 0))]
    out = {"rows": rows}
    if not rows:
        out["exporter"] = net_exporter_status()
    return out


_traffic_cache = {}


def _instant(expr, at=None):
    params = {"query": expr}
    if at is not None:
        params["time"] = at
    rows = prom_get("/api/v1/query", params)["result"]
    return num(rows[0]["value"][1]) if rows else None


def api_traffic(q):
    """Upload / download totals: calendar days in the browser's time zone, rolling 7/30 days, since boot."""
    instance = q.get("instance") or ""
    try:
        tz = max(-840, min(840, int(q.get("tz", "0"))))   # minutes, as Date.getTimezoneOffset() reports them
    except ValueError:
        tz = 0
    key = (instance, tz)
    hit = _traffic_cache.get(key)
    now = int(time.time())
    if hit and now - hit[0] < 60:
        return hit[1]
    n = node_selector(instance, net=True)
    rxm = f"node_network_receive_bytes_total{{{n},{VIRTUAL_NICS}}}"
    txm = f"node_network_transmit_bytes_total{{{n},{VIRTUAL_NICS}}}"

    def total(rng, at=None):
        return {"rx": _instant(f"sum(increase({rxm}[{rng}s]))", at), "tx": _instant(f"sum(increase({txm}[{rng}s]))", at)}

    local_midnight = (now - tz * 60) // 86400 * 86400 + tz * 60
    days = []
    for k in range(7):
        start = local_midnight - k * 86400
        end = now if k == 0 else start + 86400
        span = max(60, end - start)
        d = total(span, end)
        days.append({"start": start, "end": end, **d})
    out = {
        "days": days,
        "week": total(7 * 86400),
        "month": total(30 * 86400),
        "boot": {"rx": _instant(f"sum({rxm})"), "tx": _instant(f"sum({txm})")},
        "peak": {"rx": _instant(f"max_over_time(sum(rate({rxm}[2m]))[24h:1m])"),
                 "tx": _instant(f"max_over_time(sum(rate({txm}[2m]))[24h:1m])")},
        # how much history exists, so the UI can say "based on 3 days of data" for the longer periods
        "history": _instant(f"time() - min(min_over_time(timestamp({rxm})[30d:1m]))"),
    }
    _traffic_cache[key] = (now, out)
    if len(_traffic_cache) > 50:
        _traffic_cache.clear()
    return out


def api_websites(_q):
    def per(expr):
        return {(m.get("job", ""), m.get("instance", "")): v for m, v in vector(expr)}
    ok = per('probe_success{job=~"blackbox.*"}')
    dur = per('probe_duration_seconds{job=~"blackbox.*"}')
    code = per('probe_http_status_code{job=~"blackbox.*"}')
    ssl = per('(probe_ssl_earliest_cert_expiry{job=~"blackbox.*"} > 0) - time()')
    return {"rows": [{"job": j.replace("blackbox-", ""), "target": i, "up": ok[(j, i)] == 1,
                      "duration": dur.get((j, i)), "http": code.get((j, i)),
                      "ssl_days": None if ssl.get((j, i)) is None else ssl[(j, i)] / 86400}
                     for j, i in sorted(ok)]}


def api_targets(_q):
    rows = []
    for t in prom_get("/api/v1/targets", {"state": "active"})["activeTargets"]:
        rows.append({"job": t["labels"].get("job", ""), "instance": t["labels"].get("instance", ""),
                     "up": t["health"] == "up", "duration": num(t.get("lastScrapeDuration")),
                     "error": t.get("lastError", "")})
    return {"rows": sorted(rows, key=lambda r: (r["job"], r["instance"]))}


def api_alerts(_q):
    rows = []
    for a in prom_get("/api/v1/alerts")["alerts"]:
        labels = a.get("labels", {})
        rows.append({"name": labels.get("alertname", ""), "severity": labels.get("severity", ""),
                     "instance": labels.get("instance", ""),
                     "summary": a.get("annotations", {}).get("summary", ""),
                     "state": a["state"], "since": a.get("activeAt")})
    order = {"firing": 0, "pending": 1}
    return {"rows": sorted(rows, key=lambda r: (order.get(r["state"], 2), r["name"]))}


RANGES = {"1h": 3600, "6h": 6 * 3600, "24h": 24 * 3600, "7d": 7 * 24 * 3600}


def api_history(q):
    n = node_selector(q.get("instance"))
    nn = node_selector(q.get("instance"), net=True)
    span = RANGES.get(q.get("range", "1h"), 3600)
    queries = {
        "cpu": [("CPU", f'100 - avg(rate(node_cpu_seconds_total{{{n},mode="idle"}}[2m])) * 100')],
        "mem": [("Memory", f"(1 - node_memory_MemAvailable_bytes{{{n}}} / node_memory_MemTotal_bytes{{{n}}}) * 100")],
        "load": [(f"{p}m", f"node_load{p}{{{n}}}") for p in (1, 5, 15)],
        "net": [("rx", f"sum(rate(node_network_receive_bytes_total{{{nn},{VIRTUAL_NICS}}}[2m]))"),
                ("tx", f"sum(rate(node_network_transmit_bytes_total{{{nn},{VIRTUAL_NICS}}}[2m]))")],
    }.get(q.get("metric", ""))
    if not queries:
        raise ValueError("unknown metric")
    end = int(time.time())
    series = []
    for name, expr in queries:
        data = prom_get("/api/v1/query_range", {"query": expr, "start": end - span, "end": end,
                                                "step": max(15, span // 120)})
        pts = [[int(t), num(v)] for t, v in data["result"][0]["values"]] if data["result"] else []
        series.append({"name": name, "points": pts})
    return {"series": series}


READ_API = {"/api/instances": api_instances, "/api/overview": api_overview, "/api/disks": api_disks,
            "/api/network": api_network, "/api/traffic": api_traffic, "/api/websites": api_websites,
            "/api/targets": api_targets, "/api/alerts": api_alerts, "/api/history": api_history}
__MONITORING_EOF__
  write_file panel/icons.py 644 <<'__MONITORING_EOF__'
"""Renders the panel icon (shield with a pulse line) as PNG / ICO using only the standard library.

Browsers differ in which icon format they pick up (SVG, /favicon.ico, PNG, Apple touch icon), so the
panel serves all of them, generated here once and cached.
"""
import math
import struct
import zlib

BG = (14, 21, 32)      # card colour
FG = (46, 230, 166)    # accent colour

# Shapes in unit coordinates (0..1).
SHIELD = [(0.5, 0.15), (0.80, 0.27), (0.80, 0.52), (0.5, 0.85), (0.20, 0.52), (0.20, 0.27), (0.5, 0.15)]
PULSE = [(0.29, 0.50), (0.42, 0.50), (0.50, 0.34), (0.58, 0.64), (0.66, 0.50), (0.71, 0.50)]
_cache = {}


def _dist_to_segment(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    length2 = dx * dx + dy * dy
    t = 0.0 if length2 == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length2))
    cx, cy = ax + t * dx, ay + t * dy
    return math.hypot(px - cx, py - cy)


def _in_rounded_square(x, y, size, radius):
    half = size / 2
    qx, qy = abs(x - half) - (half - radius), abs(y - half) - (half - radius)
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) <= radius


def _png(size, rows):
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + bytes(row) for row in rows)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def png(size):
    """RGBA PNG of the icon at size x size pixels."""
    if size in _cache:
        return _cache[size]
    ss = 4 if size <= 64 else 2                      # supersampling factor for smooth edges
    stroke = max(1.2, size * 0.075)
    pulse_stroke = max(1.0, size * 0.06)
    shield = [(x * size, y * size) for x, y in SHIELD]
    pulse = [(x * size, y * size) for x, y in PULSE]
    radius = size * 0.22
    rows = []
    for py in range(size):
        row = bytearray()
        for px in range(size):
            r = g = b = a = 0
            for sy in range(ss):
                for sx in range(ss):
                    x, y = px + (sx + 0.5) / ss, py + (sy + 0.5) / ss
                    if not _in_rounded_square(x, y, size, radius):
                        continue
                    on_shield = any(_dist_to_segment(x, y, *shield[i], *shield[i + 1]) <= stroke / 2 for i in range(len(shield) - 1))
                    on_pulse = any(_dist_to_segment(x, y, *pulse[i], *pulse[i + 1]) <= pulse_stroke / 2 for i in range(len(pulse) - 1))
                    colour = FG if (on_shield or on_pulse) else BG
                    r, g, b, a = r + colour[0], g + colour[1], b + colour[2], a + 1
            total = ss * ss
            if a:
                row += bytes((r // a, g // a, b // a, round(255 * a / total)))
            else:
                row += b"\x00\x00\x00\x00"
        rows.append(row)
    _cache[size] = _png(size, rows)
    return _cache[size]


def ico():
    """A .ico wrapping a 32x32 PNG (supported by every current browser)."""
    data = png(32)
    header = struct.pack("<HHH", 0, 1, 1)
    entry = struct.pack("<BBBBHHII", 32, 32, 0, 0, 1, 32, len(data), 22)
    return header + entry + data
__MONITORING_EOF__
  write_file panel/hostip.py 644 <<'__MONITORING_EOF__'
"""Finds this server's public IPv4 / IPv6 address for the dashboard.

Runs in its own container with host networking, so the lookups leave through the server's real
interfaces (a bridged container usually has no IPv6 route). The result is written to a small JSON
file that the panel reads. Set PUBLIC_IP_LOOKUP=0 in .env to switch the lookups off.
"""
import ipaddress
import json
import os
import time
import urllib.request

OUT = os.environ.get("OUT", "/data/public-ip.json")
SOURCES = {
    4: ["https://api4.ipify.org", "https://ipv4.icanhazip.com", "https://v4.ident.me"],
    6: ["https://api6.ipify.org", "https://ipv6.icanhazip.com", "https://v6.ident.me"],
}


def lookup(version):
    for url in SOURCES[version]:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "server-monitor"})
            with urllib.request.urlopen(req, timeout=6) as resp:
                ip = ipaddress.ip_address(resp.read(100).decode().strip())
            if ip.version == version and ip.is_global:
                return str(ip)
        except Exception:
            continue
    return None


def write(data):
    tmp = OUT + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, OUT)


def main():
    if os.environ.get("PUBLIC_IP_LOOKUP", "1") == "0":
        write({"disabled": True})
        while True:
            time.sleep(86400)
    while True:
        v4, v6 = lookup(4), lookup(6)
        write({"v4": v4, "v6": v6, "checked": int(time.time())})
        time.sleep(600 if (v4 or v6) else 60)


if __name__ == "__main__":
    main()
__MONITORING_EOF__
  write_file panel/cstats.py 644 <<'__MONITORING_EOF__'
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
__MONITORING_EOF__
  write_file panel/health.py 644 <<'__MONITORING_EOF__'
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
__MONITORING_EOF__
  write_file panel/live.py 644 <<'__MONITORING_EOF__'
"""Live, one-second resolution numbers for the overview and network pages.

Prometheus scrapes every 15 s and the dashboard queries average over 2 minutes, so they lag behind
what the server is doing right now. For the live view the panel reads node_exporter itself once a
second and turns the counters into rates. One sampler thread runs per watched server, only while a
browser is watching it, and keeps the last few minutes so a page that opens has a chart at once.

Only servers Prometheus already knows (job="node") can be watched, so this cannot be used to make
the panel fetch arbitrary addresses.
"""
import collections
import os
import re
import threading
import time
from urllib.error import HTTPError
from urllib.request import urlopen

import monitor

INTERVAL = 1.0                     # default seconds between samples
CHOICES = (1, 3, 5, 10)            # what a viewer can pick; the sampler runs at the fastest one being watched
KEEP = 300                         # samples kept for a page that opens (5 minutes)
IDLE_STOP = 30                     # stop sampling a server nobody watched for this long
LOCAL_INSTANCE = os.environ.get("LOCAL_NODE_INSTANCE", "node-exporter:9100")
# This server's real NIC counters come from the node-net container (see docker-compose.yml).
LOCAL_NET_URL = os.environ.get("LOCAL_NODE_NET_URL", "http://node-net:9100/metrics")

VIRTUAL_NIC = re.compile(r"^(lo|veth.*|docker.*|br-.*|virbr.*|cni.*|cali.*|flannel.*|ifb.*)$")
VIRTUAL_DISK = re.compile(r"^(dm-|md|loop|ram|zram|sr|fd|nbd)")   # avoid counting the same bytes twice
REAL_FS = re.compile(r"^(?!(tmpfs|overlay|squashfs|devtmpfs|ramfs|fuse.*|nsfs|proc|sysfs|cgroup.*)$)")
WANTED = (
    "node_cpu_seconds_total", "node_memory_MemTotal_bytes", "node_memory_MemAvailable_bytes",
    "node_memory_SwapTotal_bytes", "node_memory_SwapFree_bytes", "node_load1", "node_load5", "node_load15",
    "node_network_receive_bytes_total", "node_network_transmit_bytes_total",
    "node_filesystem_size_bytes", "node_filesystem_avail_bytes",
    "node_disk_read_bytes_total", "node_disk_written_bytes_total",
)
# Only the collectors the live view needs: a full scrape is ~50 KB and runs every collector (tens of
# ms of CPU in node_exporter); this one is a few KB and ~3 ms. Disk sizes change slowly: every 10 s.
FAST = ("cpu", "meminfo", "loadavg", "diskstats")
DISK_EVERY = 10
LINE = re.compile(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})?\s+(\S+)")
LABEL = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"')


def parse(text):
    """Prometheus text format -> {metric: [(labels, value), ...]} for the metrics in WANTED only."""
    out = collections.defaultdict(list)
    for line in text.splitlines():
        if not line.startswith(WANTED):
            continue
        m = LINE.match(line)
        if not m or m.group(1) not in WANTED:
            continue
        try:
            value = float(m.group(3))
        except ValueError:
            continue
        out[m.group(1)].append((dict(LABEL.findall(m.group(2) or "")), value))
    return out


def fetch(url):
    with urlopen(url, timeout=2.5) as resp:
        return resp.read(8_000_000).decode("utf-8", "replace")


def first(metrics, name):
    rows = metrics.get(name)
    return rows[0][1] if rows else None


def counters(metrics):
    """The raw values a sample is computed from (counters need the previous reading)."""
    cpu_total = cpu_idle = 0.0
    for labels, v in metrics.get("node_cpu_seconds_total", []):
        cpu_total += v
        if labels.get("mode") == "idle":
            cpu_idle += v
    dev = {}
    for key, name in (("rx", "node_network_receive_bytes_total"), ("tx", "node_network_transmit_bytes_total")):
        for labels, v in metrics.get(name, []):
            d = labels.get("device", "")
            if d and not VIRTUAL_NIC.match(d):
                dev.setdefault(d, {})[key] = v
    io = {"r": 0.0, "w": 0.0}
    for key, name in (("r", "node_disk_read_bytes_total"), ("w", "node_disk_written_bytes_total")):
        for labels, v in metrics.get(name, []):
            if not VIRTUAL_DISK.match(labels.get("device", "")):
                io[key] += v
    return {"cpu": (cpu_total, cpu_idle) if cpu_total else None, "dev": dev, "io": io}


def root_disk(metrics):
    size = {l.get("mountpoint"): v for l, v in metrics.get("node_filesystem_size_bytes", [])
            if REAL_FS.match(l.get("fstype", "")) and v}
    avail = {l.get("mountpoint"): v for l, v in metrics.get("node_filesystem_avail_bytes", [])}
    mount = "/" if "/" in size else next(iter(sorted(size)), None)
    if mount is None or mount not in avail:
        return None
    return {"mount": mount, "total": size[mount], "used": size[mount] - avail[mount]}


def rate(now, before, dt):
    if now is None or before is None or dt <= 0 or now < before:   # counter reset (reboot, exporter restart)
        return None
    return (now - before) / dt


class Sampler:
    def __init__(self, instance):
        self.instance = instance
        local = instance == LOCAL_INSTANCE
        # (base url, collectors it should run); on this server network counters come from node-net
        self.sources = [(f"http://{instance}/metrics", FAST if local else FAST + ("netdev",))]
        if local:
            self.sources.append((LOCAL_NET_URL, ("netdev",)))
        self.unfiltered = set()      # exporters too old for collect[] (or with a collector switched off)
        self.tick = 0
        self.disk = None
        self.samples = collections.deque(maxlen=KEEP)
        self.error = ""
        self.cond = threading.Condition()
        self.watched = time.time()
        self.wants = {}              # interval -> last time a viewer asked for it
        self.prev = None
        threading.Thread(target=self._loop, name=f"live-{instance}", daemon=True).start()

    def _read(self):
        metrics = collections.defaultdict(list)
        with_disk = self.tick % DISK_EVERY == 0 or self.disk is None
        self.tick += 1
        for base, wanted in self.sources:
            if base in self.unfiltered:
                text = fetch(base)
            else:
                names = wanted + (("filesystem",) if with_disk and base != LOCAL_NET_URL else ())
                try:
                    text = fetch(base + "?" + "&".join(f"collect[]={c}" for c in names))
                except HTTPError as e:
                    if e.code != 400:
                        raise
                    self.unfiltered.add(base)      # "missing collector": ask for everything from now on
                    text = fetch(base)
            for k, v in parse(text).items():
                metrics[k].extend(v)
        return metrics

    def _sample(self, ts, metrics):
        c = counters(metrics)
        prev, self.prev = self.prev, (ts, c)
        if prev is None:
            return None
        dt = ts - prev[0]
        p = prev[1]
        cpu = None
        if c["cpu"] and p["cpu"]:
            d_total, d_idle = c["cpu"][0] - p["cpu"][0], c["cpu"][1] - p["cpu"][1]
            if d_total > 0:
                cpu = max(0.0, min(100.0, 100 * (1 - d_idle / d_total)))
        dev = {}
        for d, v in c["dev"].items():
            old = p["dev"].get(d, {})
            dev[d] = [rate(v.get("rx"), old.get("rx"), dt), rate(v.get("tx"), old.get("tx"), dt)]
        mem_total = first(metrics, "node_memory_MemTotal_bytes")
        mem_avail = first(metrics, "node_memory_MemAvailable_bytes")
        swap_total = first(metrics, "node_memory_SwapTotal_bytes")
        swap_free = first(metrics, "node_memory_SwapFree_bytes")

        def total(k):
            known = [x[k] for x in dev.values() if x[k] is not None]
            return sum(known) if known else None

        return {
            "t": round(ts, 3),
            "cpu": cpu,
            "mem": [mem_total - mem_avail, mem_total] if mem_total is not None and mem_avail is not None else None,
            "swap": [swap_total - swap_free, swap_total] if swap_total is not None and swap_free is not None else None,
            "load": [first(metrics, f"node_load{p}") for p in (1, 5, 15)],
            "rx": total(0), "tx": total(1), "dev": dev,
            "io": [rate(c["io"]["r"], p["io"]["r"], dt), rate(c["io"]["w"], p["io"]["w"], dt)],
            "disk": self._disk(metrics),
        }

    def _disk(self, metrics):
        if metrics.get("node_filesystem_size_bytes"):
            self.disk = root_disk(metrics)
        return self.disk

    def _loop(self):
        next_at = time.monotonic()
        while True:
            with _lock:   # decided under the lock, so a page that starts watching right now gets a new sampler
                if time.time() - self.watched >= IDLE_STOP:
                    if _samplers.get(self.instance) is self:
                        del _samplers[self.instance]
                    return
            try:
                ts = time.time()
                sample = self._sample(ts, self._read())
                self.error = ""
            except Exception as e:  # exporter unreachable, timeout, ...
                sample, self.prev = None, None
                self.error = f"{type(e).__name__}: {e}"
            with self.cond:
                if sample:
                    self.samples.append(sample)
                self.cond.notify_all()
            step = self.interval()
            next_at += step if not self.error else max(3, step)
            time.sleep(max(0.05, next_at - time.monotonic()))
            next_at = max(next_at, time.monotonic() - step)   # never try to "catch up" after a stall

    def interval(self):
        now = time.time()
        live_ = [e for e, at in list(self.wants.items()) if now - at < IDLE_STOP]
        if not live_:
            return INTERVAL
        step = min(live_)       # every viewer's pace must be a multiple of it (3 s and 5 s together -> 1 s)
        return step if all(e % step == 0 for e in live_) else INTERVAL

    def since(self, ts):
        with self.cond:
            return [s for s in self.samples if s["t"] > ts]

    def wait(self, timeout):
        with self.cond:
            self.cond.wait(timeout)


_samplers = {}
_lock = threading.Lock()
_known = {"at": 0.0, "list": []}


def resolve(instance):
    """The server to watch: one Prometheus already scrapes (cached for 30 s)."""
    if time.time() - _known["at"] > 30 or instance not in _known["list"]:
        _known["list"] = monitor.node_instances()
        _known["at"] = time.time()
    if not instance:
        instance = LOCAL_INSTANCE if LOCAL_INSTANCE in _known["list"] else (_known["list"] or [""])[0]
    if instance not in _known["list"]:
        raise ValueError("unknown server")
    return instance


def sampler(instance, every=INTERVAL):
    with _lock:
        s = _samplers.get(instance)
        if s is None:
            s = _samplers[instance] = Sampler(instance)
        s.watched = s.wants[every] = time.time()
        return s
__MONITORING_EOF__
  write_file panel/defender.py 644 <<'__MONITORING_EOF__'
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
             "f2b", "f2b/bans", "f2b/log", "f2b/jail", "f2b/files", "f2b/file", "geo", "export", "sshd", "threat", "brief"}
POST_PATHS = {"config", "confirm", "revert", "block", "unblock", "allow", "unallow", "unban", "sysctl",
              "f2b/service", "f2b/install", "f2b/uninstall", "f2b/jail", "f2b/jail/delete", "f2b/defaults", "f2b/ban", "f2b/unban",
              "f2b/file", "f2b/file/delete", "import", "sshd/apply", "sshd/confirm", "sshd/revert", "sshd/key/add",
              "sshd/key/remove", "test", "threat/refresh", "threat/custom/add", "threat/custom/remove", "port/open", "port/close", "sysfw/ufw"}
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
            st = call("GET", "brief", timeout=10)
            if last is None:
                last = st.get("last_event", 0)   # never re-send what happened before the panel started
                continue
            rows = call("GET", "events", params={"since": last}, timeout=10).get("rows", [])
            notify = st.get("notify") or {}
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
__MONITORING_EOF__
  write_file panel/static/defender.js 644 <<'__MONITORING_EOF__'
// Defender: firewall, anti-DDoS, SSH guard and hardening. The privileged work happens in the defender
// agent (defender/agent.py); this page only talks to it through /api/defender/*.
(() => {
  "use strict";
  const P = window.Panel;
  if (!P) return;
  const { t, esc, nf, num, fmtBytes, fmtRate, ago, icon, api, post, act, toast, openDialog, confirmBox, table, pill, field, btnIcon, drawChart, sparkline, tween, setHTML } = P;

  P.addIcons({
    zap: '<path d="M13 2 4 14h7l-1 8 9-12h-7l1-8z"/>',
    list: '<path d="M8 6h13M8 12h13M8 18h13M3.5 6h.01M3.5 12h.01M3.5 18h.01"/>',
    terminal: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="m7 9 3 3-3 3M13 15h4"/>',
    ban: '<circle cx="12" cy="12" r="9"/><path d="m5.6 5.6 12.8 12.8"/>',
    unlock: '<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 7.6-1.7"/>',
    eye: '<path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    power: '<path d="M12 3v9"/><path d="M6.4 6.4a8 8 0 1 0 11.2 0"/>',
    flame: '<path d="M12 22c4.4 0 7-3 7-7 0-3.6-2.5-5.7-3.6-8.6-1 1.9-2.2 2.9-3.4 3.1.2-2.6-.9-5.3-3-7.5.1 4.6-4 6.6-4 13 0 4 2.6 7 7 7z"/>',
  });

  // ---------------------------------------------------------------- strings
  const EN = {
    df_nav: "Firewall", df_desc: "Firewall, DDoS protection, SSH brute-force guard and server hardening, all in one place. Changes are tested for 60 seconds and undone by themselves if the panel stops answering.",
    df_t_overview: "Overview", df_t_firewall: "Ports & rules", df_t_ddos: "Anti-DDoS", df_t_lists: "IP lists", df_t_ssh: "SSH", df_t_hardening: "Hardening",
    df_missing_title: "The firewall service is not running", df_missing_sub: "It is part of the monitoring stack. Re-run install.sh, or on the server run:",
    df_off_title: "Protection is off", df_off_sub: "The firewall is only watching. Turn protection on to block floods, scans and brute force. Nothing is closed: every port that works now keeps working.",
    df_on_title: "Your server is protected", df_on_sub: "Floods, scans and brute force are blocked automatically. Normal traffic is not touched.",
    df_attack_title: "Under attack: mitigating", df_attack_sub: "Started {since}. Peak {pps} packets/s, {drop} blocked/s.",
    df_esc_title: "Heightened protection", df_esc_sub: "\"Under attack\" limits are active after an attack and switch back by themselves 10 minutes after it ends.",
    df_enable: "Turn on protection", df_disable: "Turn off", df_enable_confirm: "Turn on the Firewall? It starts in open mode: no port is closed, only abusive traffic is blocked. If the panel stops answering, the change is undone after 60 seconds.",
    df_disable_confirm: "Turn off protection? All Firewall rules are removed and bans are lifted; monitoring continues.",
    df_p_normal: "Normal", df_p_strict: "Strict", df_p_attack: "Under attack", df_p_custom: "Custom",
    df_p_normal_d: "For everyday use. Generous limits that a real visitor never reaches.", df_p_strict_d: "Tighter limits for servers that are attacked often.", df_p_attack_d: "Emergency: very tight limits while an attack is going on.", df_p_custom_d: "Your own limits (Advanced settings below).",
    df_mode_open: "Open", df_mode_strict: "Strict",
    df_m_pps: "Incoming packets", df_m_bps: "Incoming traffic", df_m_conns: "New connections", df_m_drop: "Blocked", df_m_bans: "Banned IPs", df_m_ct: "Connection table",
    df_per_s: "per second", df_chart: "Incoming vs. blocked (last 5 minutes)", df_in: "incoming", df_blocked: "blocked",
    df_reasons: "What was blocked (last 5 minutes)", df_reasons_none: "Nothing was blocked in the last 5 minutes.",
    df_r_block: "Blocklist", df_r_ban: "Banned IPs", df_r_invalid: "Invalid packets", df_r_badflags: "Port scans (bad TCP flags)", df_r_ssh: "SSH connection flood",
    df_r_policy: "Closed ports (strict mode)", df_r_syn: "SYN flood", df_r_conn: "Connection flood", df_r_conc: "Too many connections", df_r_udp: "UDP flood", df_r_icmp: "Ping flood", df_r_autoban: "Banned while flooding",
    df_talkers: "Top sources right now", df_talkers_sub: "Addresses with the most open connections to this server.", df_conns: "Connections", df_you: "you",
    df_events: "Activity", df_events_none: "No activity yet.",
    df_ban1h: "Ban 1 hour", df_allow: "Allow", df_unban: "Unban", df_remove: "Remove",
    df_e_applied: "Rules applied", df_e_confirmed: "Changes kept", df_e_rollback: "Changes undone ({reason})", df_e_attack_start: "Attack detected: {pps} packets/s, {drop} blocked/s",
    df_e_attack_end: "Attack ended after {min} min", df_e_escalate: "Switched to \"Under attack\" limits", df_e_deescalate: "Back to the normal limits", df_e_ban: "{ip} banned for {minutes} min",
    df_e_ssh_ban: "{ip} banned: {failures} failed SSH logins", df_e_unban: "{ip} unbanned", df_e_block: "{ip} added to the blocklist", df_e_allow: "{ip} added to the allowlist",
    df_e_sysctl: "Kernel settings: {action}", df_e_started: "Firewall started",
    df_pending: "Testing the new rules: they are undone in {n} s unless kept.", df_keep: "Keep", df_undo: "Undo", df_kept: "Applied and kept", df_undone: "Changes undone",
    df_lost: "The panel lost the connection after applying. If it stays unreachable, the change is undone by itself within 60 seconds.",
    // firewall
    df_fw_mode: "Firewall mode", df_fw_mode_sub: "Open blocks only abuse. Strict also closes every port that is not on the list below.",
    df_mode_open_d: "Every port stays reachable; floods, scans and banned IPs are blocked.", df_mode_strict_d: "Only the ports you allow are reachable (TCP and UDP). Tunnels and other protocols keep working.",
    df_always: "Always open:", df_ssh: "SSH", df_panel: "Panel",
    df_po_title: "Open a port", df_po_sub: "Like running ufw allow: the port is opened in the server's own firewall (ufw, firewalld or iptables, whichever is on) and in this firewall's strict mode. Use it when a panel or service listens but does not load.",
    df_po_port: "Port or range", df_po_proto: "Protocol", df_po_from: "Only from (optional)", df_po_from_ph: "any address", df_po_btn: "Open port",
    df_po_done: "Port {port}/{proto} is open", df_po_done_sys: "Port {port}/{proto} is open (also in {fw})", df_po_none: "No other firewall is filtering on this server, so the port was already open there.",
    df_po_nolisten: "Nothing is listening on port {port} yet: start the program first, or check the port it uses.",
    df_po_provider: "Still not loading? Check your hosting provider's firewall (for example the Hetzner Cloud Firewall): it sits in front of the server.",
    df_po_closed: "Port {port}/{proto} is closed again",
    df_sys_title: "Server firewall", df_sys_sub: "The firewall of the operating system. This firewall only blocks; it cannot open what the server's own firewall closes.",
    df_sys_none: "No other firewall is filtering incoming traffic on this server (ufw is off or missing, iptables lets everything in). Every listening port is reachable unless this firewall blocks it.",
    df_sys_ufw_on: "ufw is on", df_sys_ufw_off: "ufw is installed but off", df_sys_ufw_missing: "ufw is not installed", df_sys_incoming: "Incoming by default: {p}",
    df_sys_fwd_on: "firewalld is on", df_sys_ipt: "iptables drops incoming traffic by default (policy {p})",
    df_sys_enable: "Turn ufw on", df_sys_disable: "Turn ufw off",
    df_sys_enable_confirm: "Turn ufw on? Every port that is in use now (SSH, the panel and all listening services) is opened in ufw first, so nothing that works now stops working.",
    df_sys_disable_confirm: "Turn ufw off? Its rules are kept and come back when it is turned on again.",
    df_sys_rules: "ufw rules", df_sys_to: "To", df_sys_action: "Action", df_sys_from: "From", df_sys_del_confirm: "Delete the ufw rule \"{rule}\"?",
    df_sys_col: "Server firewall", df_sys_open: "open", df_sys_blocked: "blocked", df_sys_partly: "some addresses", df_sys_docker: "Docker (passes)", df_sys_open_btn: "Open",
    df_sys_fwd_ports: "Open in firewalld: {ports}",
    df_services: "Services reachable from the internet", df_services_sub: "Programs listening on a public address right now.",
    df_port: "Port", df_proto: "Protocol", df_process: "Program", df_state: "In strict mode", df_open: "Open", df_closed: "Closed", df_only_from: "Only from listed IPs", df_locked: "Always open",
    df_open_it: "Allow", df_close_it: "Close", df_rules: "Port rules", df_rules_sub: "Ports that stay open in strict mode. A source limits a port to one IP or network.", df_add_rule: "Add rule",
    df_from: "Source", df_any: "Anyone", df_note: "Note", df_from_hint: "Optional: an IP or network (203.0.113.7 or 203.0.113.0/24). Empty = anyone.", df_port_hint: "One port (443) or a range (8000-8100).",
    df_ifaces: "Trusted interfaces", df_ifaces_sub: "Traffic arriving on these is never filtered (VPNs and tunnels). Loopback and Docker are always trusted. A * at the end matches a prefix.",
    df_iface_add: "Add interface", df_review: "Review rules", df_discard: "Discard", df_apply: "Save and apply", df_dirty: "Unsaved changes",
    df_strict_prefill: "Every port in use right now was added to the list so nothing breaks. Remove the ones that should not be public, then apply.",
    df_rules_title: "nftables rules that will be applied",
    // ddos
    df_profiles: "Protection level", df_profiles_sub: "Limits are per source IP: one visitor, bot or proxy. Traffic below them is never touched.",
    df_auto_esc: "Switch to \"Under attack\" automatically", df_auto_esc_sub: "When an attack is detected, the tightest limits apply until 10 minutes after it ends.",
    df_adv: "Advanced settings", df_adv_sub: "Exceeding a limit drops the extra packets. Going 3x over it bans the source for the ban time.",
    df_l_syn: "New TCP connections (SYN) per second", df_l_conn: "New connections of any kind per second", df_l_conc: "Open TCP connections at once", df_l_udp: "New UDP flows per second", df_l_icmp: "Pings per second", df_l_ban: "Ban time (minutes)",
    df_drop_invalid: "Drop invalid packets", df_bad_flags: "Drop impossible TCP flags (port scans)", df_save: "Save and apply",
    df_covers: "What is blocked", df_cv_syn: "SYN floods and half-open connection floods", df_cv_conn: "Connection floods and slow-loris style connection hoarding", df_cv_udp: "UDP and ping floods",
    df_cv_scan: "Port scans with forged TCP flags and invalid packets", df_cv_ssh: "SSH brute force (connections and failed logins)", df_cv_l7: "Not covered: floods of valid HTTP requests (use a CDN or a reverse proxy with rate limits for that).",
    // lists
    df_add_ip: "Add an address", df_ip: "IP or network", df_action: "Action", df_a_block: "Block permanently", df_a_ban1h: "Ban for 1 hour", df_a_ban24h: "Ban for 24 hours", df_a_ban7d: "Ban for 7 days", df_a_allow: "Allow (never blocked)",
    df_admins: "Trusted because they logged in over SSH (now or in the last 7 days), so they are never limited or banned: {ips}",
    df_cdn: "Trust Cloudflare's addresses", df_cdn_sub: "For sites and proxies behind Cloudflare: all their visitors arrive from Cloudflare's IPs, so per-IP limits would hit everyone at once. The blocklist still applies.", df_bans: "Banned now", df_filter: "Filter…", df_source: "Banned by", df_left: "Time left",
    df_s_auto: "Flood", df_s_ssh: "SSH guard", df_s_manual: "Manual", df_s_fail2ban: "fail2ban", df_blocklist: "Blocklist", df_allowlist: "Allowlist", df_added: "Added",
    df_f2b_note: "fail2ban's bans are shown for reference; manage them with fail2ban-client.",
    // ssh
    df_ssh_title: "SSH brute-force guard", df_ssh_sub: "Reads the SSH login log and bans addresses that keep failing to log in. Logged-in users and addresses that logged in successfully today are never banned.",
    df_ssh_on: "Ban addresses with failed logins", df_ssh_l4: "Also limit new SSH connections (12 per minute per address)", df_ssh_private: "Never ban private networks",
    df_ssh_failures: "Failed logins before a ban", df_ssh_window: "Within (minutes)", df_ssh_ban: "Ban time (minutes)",
    df_ssh_24h: "Failed logins (since the agent started)", df_ssh_top: "Most failed logins", df_ssh_nolog: "The SSH log (/var/log/auth.log) is not readable, so only the connection limit is active.",
    df_f2b_present: "fail2ban is installed too. Both can run together; the firewall's guard also covers servers without it.", df_attempts: "Attempts",
    // hardening
    df_score: "Security score", df_checks: "Security checks", df_fix: "How to fix", df_kernel: "Kernel network hardening",
    df_kernel_sub: "Linux settings that make floods cheaper to absorb. They are re-applied after every reboot and can be restored to the original values.",
    df_setting: "Setting", df_current: "Current", df_recommended: "Recommended", df_apply_all: "Apply recommended", df_restore: "Restore originals",
    df_notify: "Telegram notifications", df_notify_attacks: "Attacks (started, ended, \"Under attack\" switched on)", df_notify_bans: "Every SSH brute-force ban",
    df_sev0: "OK", df_sev1: "Low", df_sev2: "Medium", df_sev3: "High",
    df_c_ssh_root_pw: ["Root can log in over SSH with a password", "Root login is restricted"], df_f_ssh_root_pw: "Set up SSH keys, then in /etc/ssh/sshd_config set PermitRootLogin prohibit-password and PasswordAuthentication no, and run systemctl restart ssh.",
    df_c_ssh_root: ["Root can log in over SSH", "Root cannot log in with a password"], df_f_ssh_root: "Set PermitRootLogin prohibit-password in /etc/ssh/sshd_config.",
    df_c_ssh_password: ["SSH accepts passwords", "SSH only accepts keys"], df_f_ssh_password: "Keys cannot be guessed. Add your key to ~/.ssh/authorized_keys, test it, then set PasswordAuthentication no.",
    df_c_ssh_port: ["SSH listens on the default port 22", "SSH listens on port {ports}"], df_f_ssh_port: "Another port only reduces automated noise; it is not a defence by itself. Keys and the SSH guard matter more.",
    df_c_ssh_bruteforce: ["{n} failed SSH logins in the log", "Few failed SSH logins ({n})"], df_f_ssh_bruteforce: "Keep the SSH guard on and switch to key-only logins.",
    df_c_fw_enabled: ["Firewall protection is off", "Firewall protection is on"], df_f_fw_enabled: "Turn protection on in the Overview tab.",
    df_c_internal_exposed: ["{name} (port {port}) is reachable from the internet", "No database or internal service is exposed"], df_f_internal_exposed: "Bind it to 127.0.0.1, or switch the firewall to strict mode and allow the port only from trusted IPs.",
    df_c_open_ports: ["{n} TCP ports are open to the internet", "{n} public TCP ports"], df_f_open_ports: "Strict mode closes everything you did not allow.",
    df_c_reboot: ["A reboot is needed to finish installing updates", "No reboot pending"], df_f_reboot: "Reboot the server at a quiet time; the whole stack starts again by itself.",
    df_c_auto_updates: ["Automatic security updates are off", "Automatic security updates are on"], df_f_auto_updates: "apt install unattended-upgrades && dpkg-reconfigure -plow unattended-upgrades",
    df_c_conntrack: ["Connection table {pct}% full", "Connection table {pct}% used"], df_f_conntrack: "Apply the kernel hardening below; it raises the limit.",
    df_c_kernel: ["{n} kernel network settings are not hardened", "Kernel network settings are hardened"], df_f_kernel: "Use \"Apply recommended\" below.",
    df_c_syncookies: ["SYN cookies are off", "SYN cookies are on"], df_f_syncookies: "Apply the kernel hardening below.",
    df_c_fail2ban: ["fail2ban is not installed", "fail2ban is installed"], df_f_fail2ban: "Optional: the firewall's SSH guard does the same job.",
    sc_syncookies: "Answers SYN floods without filling the connection queue", sc_synack: "Gives up on half-open connections sooner", sc_backlog: "Longer queue for connections being opened",
    sc_rfc1337: "Protects against TIME-WAIT assassination", sc_bcast: "Ignores pings to broadcast addresses (smurf attacks)", sc_bogus: "Ignores bogus ICMP error replies",
    sc_redirects: "Ignores ICMP redirects (route hijacking)", sc_send_redirects: "Does not send ICMP redirects", sc_source_route: "Rejects source-routed packets",
    sc_conntrack: "Room for more tracked connections during a flood", sc_ct_timeout: "Forgets idle connections after a day instead of five",
  };
  const FA = {
    df_nav: "فایروال", df_desc: "فایروال، محافظت در برابر DDoS، محافظ SSH و سخت‌سازی سرور در یک جا. هر تغییر ۶۰ ثانیه آزمایش می‌شود و اگر پنل دیگر جواب ندهد، خودش برمی‌گردد.",
    df_t_overview: "نمای کلی", df_t_firewall: "پورت‌ها و قوانین", df_t_ddos: "ضد DDoS", df_t_lists: "لیست آی‌پی‌ها", df_t_ssh: "SSH", df_t_hardening: "سخت‌سازی",
    df_missing_title: "سرویس فایروال اجرا نمی‌شود", df_missing_sub: "بخشی از استک مانیتورینگ است. install.sh را دوباره اجرا کنید یا روی سرور بزنید:",
    df_off_title: "محافظت خاموش است", df_off_sub: "فایروال فقط نگاه می‌کند. محافظت را روشن کنید تا فلاد، اسکن و حمله‌ی رمز بسته شود. هیچ پورتی بسته نمی‌شود و هر چیزی که الان کار می‌کند، کار می‌کند.",
    df_on_title: "سرور شما محافظت می‌شود", df_on_sub: "فلاد، اسکن و حمله‌ی رمز خودکار بسته می‌شوند. ترافیک عادی دست نمی‌خورد.",
    df_attack_title: "زیر حمله: در حال دفع", df_attack_sub: "شروع: {since}. اوج {pps} بسته در ثانیه، {drop} مسدود در ثانیه.",
    df_esc_title: "محافظت تشدیدشده", df_esc_sub: "محدودیت‌های «زیر حمله» بعد از حمله فعال‌اند و ۱۰ دقیقه بعد از پایان آن خودکار برمی‌گردند.",
    df_enable: "روشن کردن محافظت", df_disable: "خاموش", df_enable_confirm: "فایروال روشن شود؟ در حالت باز شروع می‌کند: هیچ پورتی بسته نمی‌شود و فقط ترافیک مخرب مسدود می‌شود. اگر پنل جواب ندهد، تغییر بعد از ۶۰ ثانیه برمی‌گردد.",
    df_disable_confirm: "محافظت خاموش شود؟ همه‌ی قوانین فایروال حذف و مسدودی‌ها برداشته می‌شوند؛ مانیتورینگ ادامه دارد.",
    df_p_normal: "عادی", df_p_strict: "سخت‌گیر", df_p_attack: "زیر حمله", df_p_custom: "سفارشی",
    df_p_normal_d: "برای استفاده‌ی روزانه. محدودیت‌هایی که هیچ بازدیدکننده‌ی واقعی به آن نمی‌رسد.", df_p_strict_d: "محدودیت‌های تنگ‌تر برای سرورهایی که زیاد حمله می‌خورند.", df_p_attack_d: "اضطراری: محدودیت‌های خیلی تنگ وقتی حمله در جریان است.", df_p_custom_d: "محدودیت‌های خودتان (تنظیمات پیشرفته پایین).",
    df_mode_open: "باز", df_mode_strict: "سخت‌گیر",
    df_m_pps: "بسته‌های ورودی", df_m_bps: "ترافیک ورودی", df_m_conns: "اتصال‌های جدید", df_m_drop: "مسدودشده", df_m_bans: "آی‌پی‌های مسدود", df_m_ct: "جدول اتصال‌ها",
    df_per_s: "در ثانیه", df_chart: "ورودی در برابر مسدودشده (۵ دقیقه‌ی اخیر)", df_in: "ورودی", df_blocked: "مسدود",
    df_reasons: "چه چیزی مسدود شد (۵ دقیقه‌ی اخیر)", df_reasons_none: "در ۵ دقیقه‌ی اخیر چیزی مسدود نشده.",
    df_r_block: "لیست سیاه", df_r_ban: "آی‌پی‌های مسدود", df_r_invalid: "بسته‌های نامعتبر", df_r_badflags: "اسکن پورت (فلگ‌های غلط TCP)", df_r_ssh: "فلاد اتصال SSH",
    df_r_policy: "پورت‌های بسته (حالت سخت‌گیر)", df_r_syn: "SYN فلاد", df_r_conn: "فلاد اتصال", df_r_conc: "اتصال‌های بیش از حد", df_r_udp: "UDP فلاد", df_r_icmp: "پینگ فلاد", df_r_autoban: "مسدود حین فلاد",
    df_talkers: "پرترافیک‌ترین منبع‌ها", df_talkers_sub: "آدرس‌هایی که بیشترین اتصال باز را به این سرور دارند.", df_conns: "اتصال‌ها", df_you: "شما",
    df_events: "رویدادها", df_events_none: "هنوز رویدادی نیست.",
    df_ban1h: "مسدود ۱ ساعت", df_allow: "مجاز", df_unban: "رفع مسدودی", df_remove: "حذف",
    df_e_applied: "قوانین اعمال شد", df_e_confirmed: "تغییرات ماند", df_e_rollback: "تغییرات برگشت ({reason})", df_e_attack_start: "حمله شناسایی شد: {pps} بسته در ثانیه، {drop} مسدود در ثانیه",
    df_e_attack_end: "حمله بعد از {min} دقیقه تمام شد", df_e_escalate: "محدودیت‌های «زیر حمله» فعال شد", df_e_deescalate: "بازگشت به محدودیت‌های عادی", df_e_ban: "{ip} برای {minutes} دقیقه مسدود شد",
    df_e_ssh_ban: "{ip} مسدود شد: {failures} ورود ناموفق SSH", df_e_unban: "مسدودی {ip} برداشته شد", df_e_block: "{ip} به لیست سیاه اضافه شد", df_e_allow: "{ip} به لیست سفید اضافه شد",
    df_e_sysctl: "تنظیمات کرنل: {action}", df_e_started: "فایروال شروع به کار کرد",
    df_pending: "قوانین جدید در حال آزمایش‌اند: اگر نگهشان ندارید {n} ثانیه‌ی دیگر برمی‌گردند.", df_keep: "نگه دار", df_undo: "برگردان", df_kept: "اعمال شد و ماند", df_undone: "تغییرات برگشت",
    df_lost: "پنل بعد از اعمال، ارتباط را از دست داد. اگر همچنان در دسترس نباشد، تغییر حداکثر تا ۶۰ ثانیه خودش برمی‌گردد.",
    df_fw_mode: "حالت فایروال", df_fw_mode_sub: "حالت باز فقط ترافیک مخرب را می‌بندد. حالت سخت‌گیر هر پورتی که در لیست پایین نیست را هم می‌بندد.",
    df_mode_open_d: "همه‌ی پورت‌ها در دسترس می‌مانند؛ فلاد، اسکن و آی‌پی‌های مسدود بسته می‌شوند.", df_mode_strict_d: "فقط پورت‌هایی که اجازه می‌دهید در دسترس‌اند (TCP و UDP). تانل‌ها و پروتکل‌های دیگر کار می‌کنند.",
    df_always: "همیشه باز:", df_ssh: "SSH", df_panel: "پنل",
    df_po_title: "باز کردن پورت", df_po_sub: "مثل زدن ufw allow: پورت در فایروال خود سرور (ufw، firewalld یا iptables، هر کدام روشن باشد) و در حالت سخت‌گیر این فایروال باز می‌شود. وقتی یک پنل یا سرویس گوش می‌دهد ولی لود نمی‌شود از این استفاده کنید.",
    df_po_port: "پورت یا بازه", df_po_proto: "پروتکل", df_po_from: "فقط از (اختیاری)", df_po_from_ph: "هر آدرسی", df_po_btn: "باز کردن پورت",
    df_po_done: "پورت {port}/{proto} باز است", df_po_done_sys: "پورت {port}/{proto} باز است (در {fw} هم)", df_po_none: "فایروال دیگری روی این سرور ترافیک را فیلتر نمی‌کند، پس پورت آن‌جا از قبل باز بود.",
    df_po_nolisten: "هنوز برنامه‌ای روی پورت {port} گوش نمی‌دهد: اول برنامه را اجرا کنید یا پورتش را بررسی کنید.",
    df_po_provider: "باز هم لود نمی‌شود؟ فایروال شرکت سرور را بررسی کنید (مثلاً Hetzner Cloud Firewall): آن جلوتر از سرور است.",
    df_po_closed: "پورت {port}/{proto} دوباره بسته شد",
    df_sys_title: "فایروال خود سرور", df_sys_sub: "فایروال سیستم‌عامل. این فایروال فقط مسدود می‌کند و نمی‌تواند چیزی را که فایروال خود سرور بسته باز کند.",
    df_sys_none: "فایروال دیگری روی این سرور ترافیک ورودی را فیلتر نمی‌کند (ufw خاموش یا نصب‌نشده است و iptables همه را راه می‌دهد). هر پورتی که برنامه‌ای رویش گوش دهد در دسترس است، مگر این فایروال مسدودش کند.",
    df_sys_ufw_on: "ufw روشن است", df_sys_ufw_off: "ufw نصب است ولی خاموش", df_sys_ufw_missing: "ufw نصب نیست", df_sys_incoming: "ورودی به طور پیش‌فرض: {p}",
    df_sys_fwd_on: "firewalld روشن است", df_sys_ipt: "iptables ترافیک ورودی را به طور پیش‌فرض دور می‌ریزد (سیاست {p})",
    df_sys_enable: "روشن کردن ufw", df_sys_disable: "خاموش کردن ufw",
    df_sys_enable_confirm: "ufw روشن شود؟ همه‌ی پورت‌هایی که الان استفاده می‌شوند (SSH، پنل و همه‌ی سرویس‌های در حال گوش دادن) اول در ufw باز می‌شوند تا چیزی که الان کار می‌کند قطع نشود.",
    df_sys_disable_confirm: "ufw خاموش شود؟ قوانینش می‌مانند و با روشن شدن دوباره برمی‌گردند.",
    df_sys_rules: "قوانین ufw", df_sys_to: "به", df_sys_action: "عمل", df_sys_from: "از", df_sys_del_confirm: "قانون ufw «{rule}» حذف شود؟",
    df_sys_col: "فایروال سرور", df_sys_open: "باز", df_sys_blocked: "بسته", df_sys_partly: "برای بعضی آدرس‌ها", df_sys_docker: "داکر (رد می‌شود)", df_sys_open_btn: "باز کن",
    df_sys_fwd_ports: "باز در firewalld: {ports}",
    df_services: "سرویس‌هایی که از اینترنت در دسترس‌اند", df_services_sub: "برنامه‌هایی که همین الان روی آدرس عمومی گوش می‌دهند.",
    df_port: "پورت", df_proto: "پروتکل", df_process: "برنامه", df_state: "در حالت سخت‌گیر", df_open: "باز", df_closed: "بسته", df_only_from: "فقط از آی‌پی‌های مشخص", df_locked: "همیشه باز",
    df_open_it: "اجازه", df_close_it: "بستن", df_rules: "قوانین پورت", df_rules_sub: "پورت‌هایی که در حالت سخت‌گیر باز می‌مانند. منبع، پورت را به یک آی‌پی یا شبکه محدود می‌کند.", df_add_rule: "افزودن قانون",
    df_from: "منبع", df_any: "همه", df_note: "توضیح", df_from_hint: "اختیاری: یک آی‌پی یا شبکه (203.0.113.7 یا 203.0.113.0/24). خالی = همه.", df_port_hint: "یک پورت (443) یا یک بازه (8000-8100).",
    df_ifaces: "اینترفیس‌های مورد اعتماد", df_ifaces_sub: "ترافیکی که از این‌ها می‌آید هرگز فیلتر نمی‌شود (VPN و تانل‌ها). لوپ‌بک و داکر همیشه مورد اعتمادند. * در آخر یعنی هر نامی که با آن شروع شود.",
    df_iface_add: "افزودن اینترفیس", df_review: "دیدن قوانین", df_discard: "لغو تغییرات", df_apply: "ذخیره و اعمال", df_dirty: "تغییرات ذخیره‌نشده",
    df_strict_prefill: "همه‌ی پورت‌هایی که الان استفاده می‌شوند به لیست اضافه شدند تا چیزی از کار نیفتد. آن‌هایی که نباید عمومی باشند را حذف کنید و بعد اعمال کنید.",
    df_rules_title: "قوانین nftables که اعمال می‌شوند",
    df_profiles: "سطح محافظت", df_profiles_sub: "محدودیت‌ها برای هر آی‌پی جداست: یک بازدیدکننده، ربات یا پروکسی. ترافیک زیر این حد هرگز دست نمی‌خورد.",
    df_auto_esc: "رفتن خودکار به حالت «زیر حمله»", df_auto_esc_sub: "وقتی حمله شناسایی شود، سخت‌ترین محدودیت‌ها تا ۱۰ دقیقه بعد از پایان آن فعال می‌شوند.",
    df_adv: "تنظیمات پیشرفته", df_adv_sub: "عبور از هر حد، بسته‌های اضافه را دور می‌ریزد. سه برابر عبور از آن، منبع را به مدت زمان مسدودی می‌بندد.",
    df_l_syn: "اتصال TCP جدید (SYN) در ثانیه", df_l_conn: "هر نوع اتصال جدید در ثانیه", df_l_conc: "اتصال TCP باز هم‌زمان", df_l_udp: "جریان UDP جدید در ثانیه", df_l_icmp: "پینگ در ثانیه", df_l_ban: "مدت مسدودی (دقیقه)",
    df_drop_invalid: "دور ریختن بسته‌های نامعتبر", df_bad_flags: "دور ریختن فلگ‌های ناممکن TCP (اسکن پورت)", df_save: "ذخیره و اعمال",
    df_covers: "چه چیزی مسدود می‌شود", df_cv_syn: "SYN فلاد و فلاد اتصال‌های نیمه‌باز", df_cv_conn: "فلاد اتصال و احتکار اتصال (مثل slow-loris)", df_cv_udp: "UDP فلاد و پینگ فلاد",
    df_cv_scan: "اسکن پورت با فلگ‌های جعلی و بسته‌های نامعتبر", df_cv_ssh: "حمله‌ی رمز به SSH (اتصال‌ها و ورودهای ناموفق)", df_cv_l7: "پوشش داده نمی‌شود: فلاد درخواست‌های HTTP معتبر (برای آن از CDN یا ریورس‌پروکسی با محدودیت نرخ استفاده کنید).",
    df_add_ip: "افزودن آدرس", df_ip: "آی‌پی یا شبکه", df_action: "کار", df_a_block: "مسدود همیشگی", df_a_ban1h: "مسدود ۱ ساعت", df_a_ban24h: "مسدود ۲۴ ساعت", df_a_ban7d: "مسدود ۷ روز", df_a_allow: "مجاز (هرگز مسدود نشود)",
    df_admins: "این آدرس‌ها چون با SSH وارد شده‌اند (الان یا در ۷ روز اخیر) مورد اعتمادند و هرگز محدود یا مسدود نمی‌شوند: {ips}",
    df_cdn: "اعتماد به آدرس‌های Cloudflare", df_cdn_sub: "برای سایت‌ها و پروکسی‌های پشت Cloudflare: همه‌ی کاربرانشان از آی‌پی‌های Cloudflare می‌آیند، پس محدودیت هر آی‌پی همه را با هم می‌بندد. لیست سیاه همچنان اعمال می‌شود.", df_bans: "مسدودهای فعلی", df_filter: "جستجو…", df_source: "مسدودکننده", df_left: "زمان باقی‌مانده",
    df_s_auto: "فلاد", df_s_ssh: "محافظ SSH", df_s_manual: "دستی", df_s_fail2ban: "fail2ban", df_blocklist: "لیست سیاه", df_allowlist: "لیست سفید", df_added: "افزوده‌شده",
    df_f2b_note: "مسدودی‌های fail2ban فقط برای اطلاع نمایش داده می‌شوند؛ با fail2ban-client مدیریتشان کنید.",
    df_ssh_title: "محافظ حمله‌ی رمز SSH", df_ssh_sub: "لاگ ورود SSH را می‌خواند و آدرس‌هایی که مدام ورود ناموفق دارند را مسدود می‌کند. کاربرهای واردشده و آدرس‌هایی که امروز موفق وارد شده‌اند هرگز مسدود نمی‌شوند.",
    df_ssh_on: "مسدود کردن آدرس‌های با ورود ناموفق", df_ssh_l4: "محدود کردن اتصال‌های جدید SSH (۱۲ در دقیقه برای هر آدرس)", df_ssh_private: "شبکه‌های خصوصی هرگز مسدود نشوند",
    df_ssh_failures: "ورود ناموفق قبل از مسدودی", df_ssh_window: "در مدت (دقیقه)", df_ssh_ban: "مدت مسدودی (دقیقه)",
    df_ssh_24h: "ورودهای ناموفق (از شروع سرویس)", df_ssh_top: "بیشترین ورود ناموفق", df_ssh_nolog: "لاگ SSH (/var/log/auth.log) خوانا نیست، پس فقط محدودیت اتصال فعال است.",
    df_f2b_present: "fail2ban هم نصب است. هر دو با هم کار می‌کنند؛ محافظ فایروال سرورهای بدون آن را هم پوشش می‌دهد.", df_attempts: "تلاش‌ها",
    df_score: "امتیاز امنیت", df_checks: "بررسی‌های امنیتی", df_fix: "راه رفع", df_kernel: "سخت‌سازی شبکه‌ی کرنل",
    df_kernel_sub: "تنظیمات لینوکس که تحمل فلاد را ارزان‌تر می‌کنند. بعد از هر ری‌بوت دوباره اعمال می‌شوند و قابل بازگشت به مقدار اصلی‌اند.",
    df_setting: "تنظیم", df_current: "فعلی", df_recommended: "پیشنهادی", df_apply_all: "اعمال پیشنهادها", df_restore: "بازگشت به اصلی",
    df_notify: "اعلان تلگرام", df_notify_attacks: "حمله‌ها (شروع، پایان، فعال شدن «زیر حمله»)", df_notify_bans: "هر مسدودی محافظ SSH",
    df_sev0: "خوب", df_sev1: "کم", df_sev2: "متوسط", df_sev3: "زیاد",
    df_c_ssh_root_pw: ["root می‌تواند با رمز از SSH وارد شود", "ورود root محدود است"], df_f_ssh_root_pw: "کلید SSH بسازید، بعد در /etc/ssh/sshd_config بگذارید PermitRootLogin prohibit-password و PasswordAuthentication no و بزنید systemctl restart ssh.",
    df_c_ssh_root: ["root می‌تواند از SSH وارد شود", "root با رمز وارد نمی‌شود"], df_f_ssh_root: "در /etc/ssh/sshd_config بگذارید PermitRootLogin prohibit-password.",
    df_c_ssh_password: ["SSH رمز عبور قبول می‌کند", "SSH فقط کلید قبول می‌کند"], df_f_ssh_password: "کلید حدس‌زدنی نیست. کلیدتان را در ~/.ssh/authorized_keys بگذارید، تست کنید، بعد PasswordAuthentication no.",
    df_c_ssh_port: ["SSH روی پورت پیش‌فرض ۲۲ است", "SSH روی پورت {ports} است"], df_f_ssh_port: "پورت دیگر فقط اسکن‌های خودکار را کم می‌کند و به‌تنهایی دفاع نیست. کلید و محافظ SSH مهم‌ترند.",
    df_c_ssh_bruteforce: ["{n} ورود ناموفق SSH در لاگ", "ورود ناموفق SSH کم است ({n})"], df_f_ssh_bruteforce: "محافظ SSH را روشن نگه دارید و به ورود فقط با کلید بروید.",
    df_c_fw_enabled: ["محافظت فایروال خاموش است", "محافظت فایروال روشن است"], df_f_fw_enabled: "از تب نمای کلی محافظت را روشن کنید.",
    df_c_internal_exposed: ["{name} (پورت {port}) از اینترنت در دسترس است", "هیچ دیتابیس یا سرویس داخلی‌ای باز نیست"], df_f_internal_exposed: "آن را روی 127.0.0.1 ببندید، یا فایروال را سخت‌گیر کنید و پورت را فقط برای آی‌پی‌های مورد اعتماد باز بگذارید.",
    df_c_open_ports: ["{n} پورت TCP به اینترنت باز است", "{n} پورت TCP عمومی"], df_f_open_ports: "حالت سخت‌گیر هر چیزی که اجازه نداده‌اید را می‌بندد.",
    df_c_reboot: ["برای تمام شدن نصب آپدیت‌ها ری‌بوت لازم است", "ری‌بوتی لازم نیست"], df_f_reboot: "در زمان خلوت سرور را ری‌بوت کنید؛ کل استک خودش بالا می‌آید.",
    df_c_auto_updates: ["آپدیت امنیتی خودکار خاموش است", "آپدیت امنیتی خودکار روشن است"], df_f_auto_updates: "apt install unattended-upgrades && dpkg-reconfigure -plow unattended-upgrades",
    df_c_conntrack: ["جدول اتصال‌ها {pct} درصد پر است", "{pct} درصد از جدول اتصال‌ها استفاده شده"], df_f_conntrack: "سخت‌سازی کرنل پایین را اعمال کنید؛ ظرفیت را بالا می‌برد.",
    df_c_kernel: ["{n} تنظیم شبکه‌ی کرنل سخت‌سازی نشده", "تنظیمات شبکه‌ی کرنل سخت‌سازی شده"], df_f_kernel: "از دکمه‌ی «اعمال پیشنهادها» پایین استفاده کنید.",
    df_c_syncookies: ["SYN cookie خاموش است", "SYN cookie روشن است"], df_f_syncookies: "سخت‌سازی کرنل پایین را اعمال کنید.",
    df_c_fail2ban: ["fail2ban نصب نیست", "fail2ban نصب است"], df_f_fail2ban: "اختیاری: محافظ SSH فایروال همین کار را می‌کند.",
    sc_syncookies: "بدون پر شدن صف، به SYN فلاد جواب می‌دهد", sc_synack: "اتصال‌های نیمه‌باز را زودتر رها می‌کند", sc_backlog: "صف بلندتر برای اتصال‌های در حال باز شدن",
    sc_rfc1337: "محافظت در برابر حمله‌ی TIME-WAIT", sc_bcast: "پینگ به آدرس broadcast را نادیده می‌گیرد (حمله‌ی smurf)", sc_bogus: "پاسخ‌های خطای جعلی ICMP را نادیده می‌گیرد",
    sc_redirects: "ICMP redirect را نادیده می‌گیرد (ربودن مسیر)", sc_send_redirects: "ICMP redirect نمی‌فرستد", sc_source_route: "بسته‌های source-routed را رد می‌کند",
    sc_conntrack: "جای بیشتر برای اتصال‌ها هنگام فلاد", sc_ct_timeout: "اتصال‌های بی‌کار را بعد از یک روز فراموش می‌کند نه پنج روز",
  };
  P.addStrings(EN, FA);
  const tt = (k, i, vars) => { const v = t(k); const s = Array.isArray(v) ? v[i] : v; return vars ? Object.entries(vars).reduce((a, [x, y]) => a.replace(`{${x}}`, y), s) : s; };

  // ---------------------------------------------------------------- state
  const TABS = [["overview", "grid"], ["firewall", "lock"], ["ddos", "zap"], ["rules", "rule"], ["lists", "list"], ["threat", "radar"], ["ssh", "terminal"], ["f2b", "jail"], ["hardening", "shield"], ["advanced", "sliders"]];
  const store = { get(k, d) { try { return localStorage.getItem(k) || d; } catch (e) { return d; } }, set(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* ignore */ } } };
  const D = { tab: store.get("df_tab", "overview"), st: null, err: "", samples: [], lastT: 0, timer: null, ticks: 0, fw: null, talkers: [], events: [], root: null, heroKey: "" };
  if (!TABS.some(([id]) => id === D.tab)) D.tab = "overview";
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const sev = (n) => pill(["ok", "", "warn", "bad"][n], t(`df_sev${n}`));
  const KEEP = 300;

  // ---------------------------------------------------------------- shell
  async function build() {
    D.tab = store.get("df_tab", D.tab);
    if (!TABS.some(([id]) => id === D.tab)) D.tab = "overview";
    try { D.st = await api("/api/defender/status"); D.err = ""; } catch (e) { D.st = null; D.err = e.message; }
    if (!D.st) {
      return `<div class="hero card warn df-hero"><div class="hero-icon">${icon("alert")}</div><div class="hero-text"><h2>${esc(t("df_missing_title"))}</h2>
        <p>${esc(t("df_missing_sub"))}</p><pre class="logs df-cmd">cd /opt/server-monitoring && docker compose up -d --build defender</pre><p class="muted">${esc(D.err)}</p></div></div>`;
    }
    const tabs = TABS.map(([id, ic]) => `<button type="button" role="tab" class="df-tab${id === D.tab ? " on" : ""}" aria-selected="${id === D.tab}" data-a="tab" data-tab="${id}">${icon(ic)}<span>${esc(t(`df_t_${id}`))}</span></button>`).join("");
    return `<div class="df-tabs" role="tablist" aria-label="${esc(t("df_nav"))}">${tabs}</div><div id="df-pending"></div><div id="df-body" class="df-body"><div class="skeleton"></div></div>`;
  }

  function bind(root) {
    D.root = root;
    root.addEventListener("click", onClick);
    root.addEventListener("change", onChange);
    root.addEventListener("submit", onSubmit);
    root.addEventListener("input", (e) => {
      if (e.target.id === "df-ban-filter") filterBans(e.target.value);
    });
    if (D.st) { paintPending(D.st.pending); showTab(D.tab); }
    clearInterval(D.timer);
    D.timer = setInterval(loop, pace());
    loop();
  }
  // the firewall page follows the live pace picked in the top bar (at least every 2 s: the agent samples that often)
  const pace = () => Math.max(2, P.state.liveEvery || 1) * 1000;
  window.addEventListener("live-every", () => {
    if (!D.timer) return;
    clearInterval(D.timer);
    D.timer = setInterval(loop, pace());
  });

  async function showTab(id) {
    D.tab = id;
    store.set("df_tab", id);
    D.root.querySelectorAll(".df-tab").forEach((b) => { const on = b.dataset.tab === id; b.classList.toggle("on", on); b.setAttribute("aria-selected", String(on)); });
    const body = D.root.querySelector("#df-body");
    if (!body) return;
    try {
      body.innerHTML = await RENDER[id]();
      if (id === "overview") paintLive();
    } catch (e) {
      if (e.message !== "unauthorized") body.innerHTML = `<div class="notice bad">${icon("bell")}<span>${esc(e.message)}</span></div>`;
    }
  }

  async function loop() {
    if (P.state.view !== "defender" || !document.body.contains(D.root)) { clearInterval(D.timer); D.timer = null; return; }
    if (document.hidden || !D.st) return;
    try {
      const live = await api("/api/defender/live", { since: D.lastT });
      for (const s of live.samples) if (s.t > D.lastT) D.samples.push(s);
      if (D.samples.length > KEEP) D.samples.splice(0, D.samples.length - KEEP);
      if (D.samples.length) D.lastT = D.samples[D.samples.length - 1].t;
      Object.assign(D.st, { attack: live.attack, escalated: live.escalated, applied: live.applied, bans: live.bans, pending: live.pending });
      paintPending(live.pending);
      D.ticks++;
      if (D.tab === "overview") {
        paintLive();
        if (D.ticks % 5 === 0) refreshOverviewSlow();
      }
      if (D.tab === "ssh" && D.sv && D.sv.pending) {
        D.sv.pending.left = Math.max(0, D.sv.pending.left - 2);
        if (D.sv.pending.left === 0 || D.ticks % 10 === 0) { const fresh = await api("/api/defender/sshd").catch(() => null); if (fresh) D.sv = fresh; }
        svFormToDraft();
        repaintSv();
      }
      if (D.tab === "rules" && D.ticks % 5 === 0 && !document.querySelector("dialog[open]")) {
        const fr = await api("/api/defender/fwrules").catch(() => null);
        if (fr && D.tab === "rules") { D.rules = fr.rules; D.ruleHits = fr.hits || {}; repaintRules(); }
      }
    } catch (e) { /* the next tick tries again */ }
  }

  // ---------------------------------------------------------------- applying changes safely
  function paintPending(p, lost = false) {
    const box = D.root && D.root.querySelector("#df-pending");
    if (!box) return;
    if (lost) { box.innerHTML = `<div class="notice bad">${icon("alert")}<span>${esc(t("df_lost"))}</span></div>`; return; }
    if (!p) { box.innerHTML = ""; return; }
    box.innerHTML = `<div class="notice warn df-pend">${icon("clock")}<span>${esc(t("df_pending", { n: p.left }))}</span>
      <button type="button" class="btn small primary" data-a="keep">${esc(t("df_keep"))}</button><button type="button" class="btn small" data-a="undo">${esc(t("df_undo"))}</button></div>`;
  }

  // POST a change; when the agent asks for confirmation, prove the panel is still reachable and keep it.
  async function apply(btn, path, body, okMsg) {
    const res = await act(btn, () => post(`/api/defender/${path}`, body));
    if (!res) return false;
    if (res.enabled !== undefined) D.st = Object.assign(D.st || {}, res);
    if (res.pending) {
      paintPending(res.pending);
      await sleep(1200);
      try {
        await api("/api/defender/status");
        D.st = await post("/api/defender/confirm", {});
        toast(okMsg || t("df_kept"));
      } catch (e) {
        paintPending(null, true);
        return false;
      }
    } else if (okMsg) toast(okMsg);
    paintPending(D.st && D.st.pending);
    return true;
  }

  // ---------------------------------------------------------------- overview
  // value -> HTML; the unit stays outside the left-to-right number so it reads right in Persian too
  const perSec = (v) => `${num(esc(nf(v, 0)))} <small>${esc(t("df_per_s"))}</small>`;
  const METRICS = [
    ["pps", "down", perSec],
    ["bps", "activity", (v) => num(esc(fmtRate(v)))],
    ["conns", "plus", perSec],
    ["drop", "ban", perSec],
    ["bans", "lock", (v) => num(esc(nf(v, 0)))],
    ["ct", "server", (v) => num(esc(`${nf(v, 1)}%`))],
  ];

  function heroState(st) {
    if (!st.enabled) return { tone: "warn", ic: "power", title: "df_off_title", sub: t("df_off_sub") };
    if (st.attack && st.attack.active) {
      const pk = st.attack.peak || {};
      return { tone: "bad", ic: "flame", title: "df_attack_title", sub: t("df_attack_sub", { since: ago(st.attack.since), pps: nf(pk.pps, 0), drop: nf(pk.drop, 0) }) };
    }
    if (st.escalated) return { tone: "warn", ic: "alert", title: "df_esc_title", sub: t("df_esc_sub") };
    return { tone: "", ic: "shield", title: "df_on_title", sub: t("df_on_sub") };
  }

  function heroHTML() {
    const st = D.st, h = heroState(st), fw = st.config.firewall;
    const chips = st.enabled ? [
      `<span class="chip">${icon("zap")}<b>${esc(t(`df_p_${st.escalated ? "attack" : st.profile}`))}</b></span>`,
      `<span class="chip">${icon("lock")}<b>${esc(t(fw.mode === "strict" ? "df_mode_strict" : "df_mode_open"))}</b></span>`,
      `<span class="chip">${icon("terminal")}${esc(t("df_t_ssh"))} <b>${esc(st.config.ssh_guard.enabled ? "✓" : "–")}</b></span>`,
    ].join("") : "";
    const profiles = st.enabled ? `<div class="df-seg" role="group" aria-label="${esc(t("df_profiles"))}">${["normal", "strict", "attack"].map((p) =>
      `<button type="button" class="${st.profile === p ? "on" : ""}" aria-pressed="${st.profile === p}" data-a="profile" data-p="${p}">${esc(t(`df_p_${p}`))}</button>`).join("")}</div>` : "";
    const cta = st.enabled
      ? `<button type="button" class="btn small ghost danger" data-a="disable">${icon("power")}<span>${esc(t("df_disable"))}</span></button>`
      : `<button type="button" class="btn primary df-cta" data-a="enable">${icon("shield")}<span>${esc(t("df_enable"))}</span></button>`;
    const err = st.error ? `<div class="notice bad">${icon("alert")}<span>${esc(st.error)}</span></div>` : "";
    return `<section class="card hero df-hero ${h.tone}"><div class="hero-icon">${icon(h.ic)}</div>
      <div class="hero-text"><h2 aria-live="polite">${esc(t(h.title))}</h2><p>${esc(h.sub)}</p><div class="hero-meta">${chips}</div></div>
      <div class="df-hero-act">${profiles}${cta}</div></section>${err}`;
  }

  async function renderOverview() {
    D.heroKey = "";
    const tiles = METRICS.map(([k, ic]) => `<div class="card stat" data-dm="${k}"><div class="label">${icon(ic)}${esc(t(`df_m_${k}`))}</div><div class="value"></div><div class="spark"></div></div>`).join("");
    const chart = `<div class="chart"><header><h3>${esc(t("df_chart"))}<span class="live-tag"><i></i>${esc(t("live_tag"))}</span></h3></header>
      <div class="legend"><span><i style="background:var(--c1)"></i>${esc(t("df_in"))}</span><span><i style="background:var(--c2)"></i>${esc(t("df_blocked"))}</span></div><div class="plot" id="df-plot"><div class="skeleton"></div></div></div>`;
    const [tk, ev] = await Promise.all([api("/api/defender/talkers").catch(() => ({ rows: [] })), api("/api/defender/events").catch(() => ({ rows: [] }))]);
    D.talkers = tk.rows; D.events = ev.rows;
    return `<div id="df-hero">${heroHTML()}</div><div class="tiles df-tiles">${tiles}</div>${chart}
      <div class="df-grid2"><section class="sec"><div class="sec-head"><h3>${icon("ban")}${esc(t("df_reasons"))}</h3></div><div id="df-reasons" class="df-bars"></div></section>
      <section class="sec"><div class="sec-head"><h3>${icon("eye")}${esc(t("df_talkers"))}</h3><p class="muted">${esc(t("df_talkers_sub"))}</p></div><div id="df-talkers">${talkersHTML()}</div></section></div>
      <section class="sec"><div class="sec-head"><h3>${icon("clock")}${esc(t("df_events"))}</h3></div><div id="df-events">${eventsHTML()}</div></section>`;
  }

  function talkersHTML() {
    const admins = new Set(D.st.admin_ips || []);
    return table([
      { h: "df_ip", cls: "strong", cell: (r) => `${num(esc(r.ip))}${admins.has(r.ip) ? `<span class="tag">${esc(t("df_you"))}</span>` : ""}` },
      { h: "df_conns", cell: (r) => num(nf(r.conns, 0)) },
      { h: "actions", cell: (r) => admins.has(r.ip) ? "–" : `<div class="row-actions">${btnIcon("ban", t("df_ban1h"), `data-a="ban" data-ip="${esc(r.ip)}" data-min="60"`, "danger")}${btnIcon("check", t("df_allow"), `data-a="allow" data-ip="${esc(r.ip)}"`)}</div>` },
    ], D.talkers.slice(0, 10));
  }

  const EVENT_IC = { f2b_ban: "jail", f2b_unban: "unlock", f2b_config: "sliders", f2b_service: "jail", attack_start: "flame", attack_end: "okmark", escalate: "alert", deescalate: "shield", ban: "ban", ssh_ban: "terminal", unban: "unlock", block: "ban", allow: "check", rollback: "refresh", applied: "sliders", confirmed: "okmark", sysctl: "gear", started: "power" };
  function eventText(e) {
    const p = { ...e };
    if (e.kind === "attack_start") { p.pps = nf(e.pps, 0); p.drop = nf(e.drop, 0); }
    if (e.kind === "attack_end") p.min = nf((e.seconds || 0) / 60, 0);
    return t(`df_e_${e.kind}`, p);
  }
  function eventsHTML() {
    const rows = D.events.slice(-14).reverse();
    if (!rows.length) return `<div class="empty">${esc(t("df_events_none"))}</div>`;
    return `<ol class="df-events">${rows.map((e) => `<li class="ev-${esc(e.kind)}"><span class="ev-ic">${icon(EVENT_IC[e.kind] || "bell")}</span><span class="ev-t">${esc(eventText(e))}</span><time>${esc(ago(e.t))}</time></li>`).join("")}</ol>`;
  }

  async function refreshOverviewSlow() {
    const [tk, ev] = await Promise.all([api("/api/defender/talkers").catch(() => null), api("/api/defender/events").catch(() => null)]);
    if (D.tab !== "overview") return;
    if (tk) { D.talkers = tk.rows; setHTML(D.root.querySelector("#df-talkers"), talkersHTML()); }
    if (ev) { D.events = ev.rows; setHTML(D.root.querySelector("#df-events"), eventsHTML()); }
  }

  function paintLive() {
    const root = D.root, S = D.samples;
    if (!root || !root.querySelector("#df-hero")) return;
    const h = heroState(D.st), key = [D.st.enabled, h.title, D.st.profile, D.st.escalated, D.st.error, D.st.config.firewall.mode, P.state.lang].join("|");
    if (key !== D.heroKey) { D.heroKey = key; root.querySelector("#df-hero").innerHTML = heroHTML(); }
    const last = S[S.length - 1] || {};
    for (const [k, , fmt] of METRICS) {
      const card = root.querySelector(`[data-dm="${k}"]`);
      if (!card) continue;
      const v = k === "bans" ? D.st.bans : last[k];
      tween(card.querySelector(".value"), v == null ? null : v, (x) => (x == null ? "–" : fmt(x)));
      card.classList.toggle("alert-on", k === "drop" && (last.drop || 0) > 50);
      setHTML(card.querySelector(".spark"), k === "bans" ? "" : sparkline(S.slice(-120).map((s) => [s.t, s[k]]), `var(${k === "drop" ? "--c2" : "--c1"})`));
    }
    const box = root.querySelector("#df-plot");
    if (box) {
      if (S.length >= 2) {
        const end = S[S.length - 1].t;
        drawChart(box, { title: "df_chart", fmt: (v) => nf(v, 0), colors: ["--c1", "--c2"], names: ["df_in", "df_blocked"] },
          [{ name: "in", points: S.map((s) => [s.t, s.pps]) }, { name: "drop", points: S.map((s) => [s.t, s.drop]) }], "df", [end - (KEEP - 1), end]);
      } else box.innerHTML = `<div class="empty">${esc(t("live_waiting"))}</div>`;
    }
    const totals = {};
    S.forEach((s, i) => {   // rates per second; samples are 1 s apart while watched, 2 s when idle
      const dt = i ? Math.min(5, Math.max(0.2, s.t - S[i - 1].t)) : 1;
      for (const [k, v] of Object.entries(s.drops || {})) totals[k] = (totals[k] || 0) + v * dt;
    });
    const rows = Object.entries(totals).filter(([, v]) => v >= 1).sort((a, b) => b[1] - a[1]);
    const max = rows.length ? rows[0][1] : 1;
    setHTML(root.querySelector("#df-reasons"), rows.length ? rows.map(([k, v]) => `<div class="df-bar"><span>${esc(t(`df_r_${k}`))}</span><b>${num(nf(v, 0))}</b><i style="width:${Math.max(2, (v / max) * 100).toFixed(1)}%"></i></div>`).join("")
      : `<div class="empty">${esc(t("df_reasons_none"))}</div>`);
  }

  // ---------------------------------------------------------------- firewall
  const clone = (o) => JSON.parse(JSON.stringify(o));
  async function renderFirewall() {
    if (!D.fw) D.fw = clone(D.st.config.firewall);
    const ports = await api("/api/defender/ports");
    D.ports = ports.rows;
    D.sysfw = ports.sysfw;
    return firewallHTML();
  }
  const portLabel = (p) => `${p.port}/${p.proto === "both" ? "tcp+udp" : p.proto}`;
  function ruleFor(r) { return D.fw.ports.findIndex((p) => !p.from && (p.proto === r.proto || p.proto === "both") && (() => { const [a, b] = String(p.port).split("-"); return +a <= r.port && r.port <= +(b || a); })()); }
  function firewallHTML() {
    const fw = D.fw, strict = fw.mode === "strict", st = D.st;
    const dirty = JSON.stringify(fw) !== JSON.stringify(st.config.firewall);
    const opt = (m) => `<button type="button" class="df-opt${fw.mode === m ? " on" : ""}" aria-pressed="${fw.mode === m}" data-a="fw-mode" data-mode="${m}">
      <span class="df-opt-ic">${icon(m === "open" ? "unlock" : "lock")}</span><b>${esc(t(`df_mode_${m}`))}</b><span>${esc(t(`df_mode_${m}_d`))}</span></button>`;
    const always = [...st.ssh_ports.map((p) => `<span class="chip">${icon("lock")}${esc(t("df_ssh"))} <b>${num(p)}</b></span>`), ...st.panel_ports.map((p) => `<span class="chip">${icon("lock")}${esc(t("df_panel"))} <b>${num(p)}</b></span>`)].join("");
    const services = table([
      { h: "df_port", cls: "strong", cell: (r) => `${num(esc(`${r.port}/${r.proto}`))}${r.docker ? '<span class="tag">docker</span>' : ""}` },
      { h: "df_process", cell: (r) => esc(r.process || "–") },
      { h: "df_sys_col", cell: sysCell },
      { h: "df_state", cell: (r) => r.always ? pill("ok", t("df_locked")) : ruleFor(r) >= 0 ? pill("ok", t("df_open")) : r.restricted ? pill("warn", t("df_only_from")) : strict ? pill("bad", t("df_closed")) : pill("", t("df_open")) },
      { h: "actions", cell: (r) => r.always ? "–" : ruleFor(r) >= 0
        ? `<button type="button" class="btn small" data-a="fw-close" data-proto="${r.proto}" data-port="${r.port}">${esc(t("df_close_it"))}</button>`
        : `<button type="button" class="btn small" data-a="fw-open" data-proto="${r.proto}" data-port="${r.port}" data-note="${esc(r.process)}">${esc(t("df_open_it"))}</button>` },
    ], D.ports || []);
    const rules = table([
      { h: "df_port", cls: "strong", cell: (p) => num(esc(portLabel(p))) },
      { h: "df_from", cell: (p) => (p.from ? num(esc(p.from)) : esc(t("df_any"))) },
      { h: "df_note", cell: (p) => esc(p.note || "") },
      { h: "actions", cell: (p, i) => btnIcon("trash", t("df_remove"), `data-a="fw-del" data-i="${D.fw.ports.indexOf(p)}"`, "danger") },
    ], fw.ports);
    const ifaces = fw.trusted_ifaces.map((n, i) => `<span class="chip">${num(esc(n))}<button type="button" class="chip-x" data-a="if-del" data-i="${i}" aria-label="${esc(t("df_remove"))} ${esc(n)}">${icon("x")}</button></span>`).join("");
    const known = (st.interfaces || []).map((n) => `<option value="${esc(n)}">`).join("");
    return `${openPortHTML()}<section class="sec"><div class="sec-head"><h3>${icon("lock")}${esc(t("df_fw_mode"))}</h3><p class="muted">${esc(t("df_fw_mode_sub"))}</p></div>
        <div class="df-choice">${opt("open")}${opt("strict")}</div><div class="chips df-always"><span class="muted">${esc(t("df_always"))}</span>${always}</div>
        ${D.prefilled ? `<div class="notice warn">${icon("bell")}<span>${esc(t("df_strict_prefill"))}</span></div>` : ""}</section>
      <section class="sec"><div class="sec-head"><h3>${icon("globe")}${esc(t("df_services"))}</h3><p class="muted">${esc(t("df_services_sub"))}</p></div>${services}</section>
      ${sysHTML()}
      <section class="sec"><div class="sec-head df-head-row"><div><h3>${icon("list")}${esc(t("df_rules"))}</h3><p class="muted">${esc(t("df_rules_sub"))}</p></div>
        <button type="button" class="btn small primary" data-a="fw-add">${icon("plus")}<span>${esc(t("df_add_rule"))}</span></button></div>${rules}</section>
      <section class="sec"><div class="sec-head"><h3>${icon("network")}${esc(t("df_ifaces"))}</h3><p class="muted">${esc(t("df_ifaces_sub"))}</p></div>
        <form data-f="cdn" class="df-cdn"><label class="df-switch"><span class="switch"><input type="checkbox" name="trust_cdn" ${st.config.trust_cdn !== false ? "checked" : ""}><span></span></span><span><b>${esc(t("df_cdn"))}</b><small>${esc(t("df_cdn_sub"))}</small></span></label></form>
        <div class="chips">${ifaces}</div><form class="inline-field df-inline" data-f="if-add"><input name="iface" dir="ltr" list="df-iflist" placeholder="wg0" autocomplete="off" aria-label="${esc(t("df_iface_add"))}" maxlength="16"><datalist id="df-iflist">${known}</datalist><button type="submit" class="btn small">${icon("plus")}<span>${esc(t("df_iface_add"))}</span></button></form></section>
      <div class="df-actions${dirty ? " dirty" : ""}"><span class="muted">${dirty ? esc(t("df_dirty")) : ""}</span>
        <button type="button" class="btn" data-a="rules">${icon("eye")}<span>${esc(t("df_review"))}</span></button>
        <button type="button" class="btn" data-a="fw-reset" ${dirty ? "" : "disabled"}>${esc(t("df_discard"))}</button>
        <button type="button" class="btn primary" data-a="fw-apply" ${dirty ? "" : "disabled"}>${icon("check")}<span>${esc(t("df_apply"))}</span></button></div>`;
  }
  function sysCell(r) {
    if (r.docker) return `<span class="muted">${esc(t("df_sys_docker"))}</span>`;
    if (r.sys == null) return `<span class="muted">–</span>`;
    if (r.sys === true) return pill("ok", t("df_sys_open"), false);
    const btn = `<button type="button" class="btn small" data-a="sys-open" data-port="${r.port}" data-proto="${r.proto}" data-note="${esc(r.process || "")}">${esc(t("df_sys_open_btn"))}</button>`;
    return `<span class="df-rowbtns">${pill(r.sys === "partly" ? "warn" : "bad", t(r.sys === "partly" ? "df_sys_partly" : "df_sys_blocked"), false)}${btn}</span>`;
  }
  function openPortHTML() {
    return `<section class="sec"><div class="sec-head"><h3>${icon("unlock")}${esc(t("df_po_title"))}</h3><p class="muted">${esc(t("df_po_sub"))}</p></div>
      <form class="subcard" data-f="port-open"><div class="df-form-grid">${field(t("df_po_port"), '<input name="port" dir="ltr" required placeholder="8080 / 8000-8100" inputmode="numeric" autocomplete="off" maxlength="11">')}
        ${field(t("df_po_proto"), '<select name="proto"><option value="tcp">TCP</option><option value="udp">UDP</option><option value="both">TCP + UDP</option></select>')}
        ${field(t("df_po_from"), `<input name="from" dir="ltr" placeholder="${esc(t("df_po_from_ph"))}" autocomplete="off">`)}
        ${field(t("df_note"), '<input name="note" maxlength="80" autocomplete="off">')}</div>
        <div class="actions-row"><button type="submit" class="btn primary">${icon("unlock")}<span>${esc(t("df_po_btn"))}</span></button></div><div id="df-po-out"></div></form></section>`;
  }
  function sysHTML() {
    const s = D.sysfw || {}, u = s.ufw || {}, f = s.firewalld || {};
    const lines = [];
    if (u.installed) lines.push(`<span class="chip">${pill(u.active ? "ok" : "", t(u.active ? "df_sys_ufw_on" : "df_sys_ufw_off"), true)}${u.active ? `<span class="muted">${esc(t("df_sys_incoming", { p: u.incoming }))}</span>` : ""}</span>`);
    else lines.push(`<span class="chip"><span class="muted">${esc(t("df_sys_ufw_missing"))}</span></span>`);
    if (f.active) lines.push(`<span class="chip">${pill("ok", t("df_sys_fwd_on"), true)}<span class="muted" dir="ltr">${esc(f.ports.join(", ") || "–")}</span></span>`);
    if (s.active === "iptables") lines.push(`<span class="chip">${pill("warn", t("df_sys_ipt", { p: s.iptables_policy }), true)}</span>`);
    const btn = u.installed ? (u.active
      ? `<button type="button" class="btn small" data-a="ufw" data-act="disable">${icon("power")}<span>${esc(t("df_sys_disable"))}</span></button>`
      : `<button type="button" class="btn small" data-a="ufw" data-act="enable">${icon("power")}<span>${esc(t("df_sys_enable"))}</span></button>`) : "";
    const rules = u.active && u.rules.length ? `<h4 class="fw-h">${esc(t("df_sys_rules"))}</h4>${table([
      { h: "df_sys_to", cls: "strong", cell: (r) => `<code dir="ltr">${esc(r.to)}</code>` },
      { h: "df_sys_action", cell: (r) => pill(r.action === "ALLOW" ? "ok" : r.action === "LIMIT" ? "warn" : "bad", `${r.action} ${r.dir}`, false) },
      { h: "df_sys_from", cell: (r) => `<span dir="ltr">${esc(r.from)}</span>` },
      { h: "actions", cell: (r) => btnIcon("trash", t("df_remove"), `data-a="ufw-del" data-text="${esc(r.text)}"`, "danger") },
    ], u.rules)}` : "";
    return `<section class="sec"><div class="sec-head df-head-row"><div><h3>${icon("shield")}${esc(t("df_sys_title"))}</h3><p class="muted">${esc(t("df_sys_sub"))}</p></div>${btn}</div>
      <div class="chips">${lines.join("")}</div>${s.active ? "" : `<p class="muted">${esc(t("df_sys_none"))}</p>`}${rules}</section>`;
  }
  async function openPort(btn, body) {
    const r = await act(btn, () => post("/api/defender/port/open", body));
    if (!r) return false;
    const label = { port: body.port, proto: body.proto === "both" ? "tcp+udp" : body.proto };
    toast(r.firewall ? t("df_po_done_sys", { ...label, fw: r.firewall }) : t("df_po_done", label));
    const out = D.root.querySelector("#df-po-out");
    if (out) {
      out.innerHTML = [r.firewall ? "" : `<div class="notice">${icon("check")}<span>${esc(t("df_po_none"))}</span></div>`,
        r.listening ? "" : `<div class="notice warn">${icon("bell")}<span>${esc(t("df_po_nolisten", { port: body.port }))}</span></div>`,
        `<div class="notice">${icon("globe")}<span>${esc(t("df_po_provider"))}</span></div>`].join("");
    }
    D.ports = r.rows; D.sysfw = r.sysfw;
    D.st = await api("/api/defender/status").catch(() => D.st);
    D.fw = clone(D.st.config.firewall);
    const keep = out ? out.innerHTML : "";
    repaintFw();
    const again = D.root.querySelector("#df-po-out");
    if (again) again.innerHTML = keep;
    return true;
  }
  const repaintFw = () => { const b = D.root.querySelector("#df-body"); if (b && D.tab === "firewall") b.innerHTML = firewallHTML(); };

  function addRuleDialog() {
    openDialog({
      title: t("df_add_rule"), submit: t("add"),
      body: `<div class="field-row">${field(t("df_port"), '<input name="port" dir="ltr" required placeholder="443" autocomplete="off" pattern="\\d{1,5}(-\\d{1,5})?">', t("df_port_hint"))}
        ${field(t("df_proto"), '<select name="proto"><option value="tcp">TCP</option><option value="udp">UDP</option><option value="both">TCP + UDP</option></select>')}</div>
        ${field(t("df_from"), '<input name="from" dir="ltr" placeholder="203.0.113.0/24" autocomplete="off">', t("df_from_hint"))}
        ${field(t("df_note"), '<input name="note" maxlength="80" autocomplete="off">')}`,
      onSubmit: async (form) => {
        const r = { proto: form.elements.proto.value, port: form.elements.port.value.trim(), from: form.elements.from.value.trim(), note: form.elements.note.value.trim() };
        if (!/^\d{1,5}(-\d{1,5})?$/.test(r.port)) throw new Error(t("df_port_hint"));
        D.fw.ports.push(r);
        repaintFw();
      },
    });
  }

  function rulesDialog() {
    openDialog({
      title: t("df_rules_title"), wide: true, hideSubmit: true, cancel: t("close"),
      body: `<pre class="logs df-rules" dir="ltr">…</pre>`,
      onOpen: async (dlg) => {
        try { dlg.querySelector("pre").textContent = (await api("/api/defender/rules")).text; } catch (e) { dlg.querySelector("pre").textContent = e.message; }
      },
    });
  }

  // ---------------------------------------------------------------- anti-DDoS
  const LIMITS = [["syn", 1, 100000], ["conn", 1, 100000], ["conc", 5, 1000000], ["udp", 1, 1000000], ["icmp", 1, 10000], ["ban", 1, 10080]];
  async function renderDdos() {
    const st = D.st;
    const card = (p) => {
      const L = p === "custom" ? st.limits : st.profiles[p];
      const on = st.profile === p;
      return `<button type="button" class="df-opt df-prof${on ? " on" : ""}" aria-pressed="${on}" data-a="profile" data-p="${p}" ${p === "custom" ? "disabled" : ""}>
        <b>${esc(t(`df_p_${p}`))}</b><span>${esc(t(`df_p_${p}_d`))}</span>
        <span class="df-nums">${num(`SYN ${nf(L.syn, 0)}/s · ${t("df_conns")} ${nf(L.conc, 0)} · ${t("df_l_ban").replace(/ \(.*/, "")} ${nf(L.ban, 0)}m`)}</span></button>`;
    };
    const inputs = LIMITS.map(([k, lo, hi]) => field(t(`df_l_${k}`), `<input type="number" name="${k}" min="${lo}" max="${hi}" step="1" required value="${esc(st.limits[k])}" dir="ltr" inputmode="numeric">`)).join("");
    const sw = (name, on, label, sub = "") => `<label class="df-switch"><span class="switch"><input type="checkbox" name="${name}" ${on ? "checked" : ""}><span></span></span><span><b>${esc(label)}</b>${sub ? `<small>${esc(sub)}</small>` : ""}</span></label>`;
    return `<section class="sec"><div class="sec-head"><h3>${icon("zap")}${esc(t("df_profiles"))}</h3><p class="muted">${esc(t("df_profiles_sub"))}</p></div>
        <div class="df-choice df-choice4">${["normal", "strict", "attack", "custom"].map(card).join("")}</div>
        <form data-f="esc">${sw("auto_escalate", st.config.auto_escalate, t("df_auto_esc"), t("df_auto_esc_sub"))}</form></section>
      <section class="sec"><div class="sec-head"><h3>${icon("sliders")}${esc(t("df_adv"))}</h3><p class="muted">${esc(t("df_adv_sub"))}</p></div>
        <form class="subcard" data-f="ddos"><div class="df-form-grid">${inputs}</div>
        ${sw("drop_invalid", st.config.ddos.drop_invalid, t("df_drop_invalid"))}${sw("bad_flags", st.config.ddos.bad_flags, t("df_bad_flags"))}
        <div class="actions-row"><button type="submit" class="btn primary">${icon("check")}<span>${esc(t("df_save"))}</span></button></div></form></section>
      <section class="sec"><div class="sec-head"><h3>${icon("shield")}${esc(t("df_covers"))}</h3></div>
        <ul class="df-covers">${["syn", "conn", "udp", "scan", "ssh"].map((k) => `<li>${icon("okmark")}<span>${esc(t(`df_cv_${k}`))}</span></li>`).join("")}<li class="no">${icon("alert")}<span>${esc(t("df_cv_l7"))}</span></li></ul></section>`;
  }

  // ---------------------------------------------------------------- IP lists
  async function renderLists() {
    const b = await api("/api/defender/bans");
    D.bans = b;
    const admins = b.admin_ips.length ? `<div class="notice ok">${icon("check")}<span>${esc(t("df_admins", { ips: b.admin_ips.join("، ") }))}</span></div>` : "";
    const bans = table([
      { h: "df_ip", cls: "strong", cell: (r) => `<code dir="ltr">${esc(r.ip)}</code>` },
      { h: "df_ban_reason", cell: banReason },
      { h: "df_ban_at", cell: (r) => (r.at ? `<span class="df-when"><b>${esc(clock(r.at))}</b><small class="muted">${esc(ago(r.at))}</small></span>` : "–") },
      { h: "df_left", cell: banLeft },
      { h: "actions", cell: (r) => `<span class="df-rowbtns">${r.source === "fail2ban"
        ? (r.jail ? `<button type="button" class="btn small" data-a="f2b-unban" data-ip="${esc(r.ip)}" data-jail="${esc(r.jail)}">${esc(t("df_unban"))}</button>` : "")
        : `<button type="button" class="btn small" data-a="unban" data-ip="${esc(r.ip)}">${esc(t("df_unban"))}</button>`}${btnIcon("check", t("df_ban_trust", { ip: r.ip }), `data-a="ban-allow" data-ip="${esc(r.ip)}" data-jail="${esc(r.jail || "")}"`)}</span>` },
    ], [...b.rows].sort((x, y) => (y.at || 0) - (x.at || 0)), (r) => `data-ip="${esc(r.ip)}"`);
    const listTable = (rows, kind) => table([
      { h: "df_ip", cls: "strong", cell: (r) => num(esc(r.ip)) },
      { h: "df_note", cell: (r) => esc(r.note || "") },
      { h: "df_added", cell: (r) => (r.added ? esc(ago(r.added)) : "–") },
      { h: "actions", cell: (r) => btnIcon("trash", `${t("df_remove")} ${r.ip}`, `data-a="un${kind}" data-ip="${esc(r.ip)}"`, "danger") },
    ], rows);
    const f2b = "";
    return `<section class="sec"><div class="sec-head"><h3>${icon("plus")}${esc(t("df_add_ip"))}</h3></div>${admins}
        <form class="subcard df-addip" data-f="list-add"><div class="df-form-grid">
          ${field(t("df_ip"), '<input name="ip" dir="ltr" required placeholder="203.0.113.7 / 203.0.113.0/24" autocomplete="off">')}
          ${field(t("df_action"), `<select name="action"><option value="ban60">${esc(t("df_a_ban1h"))}</option><option value="ban1440">${esc(t("df_a_ban24h"))}</option><option value="ban10080">${esc(t("df_a_ban7d"))}</option><option value="block">${esc(t("df_a_block"))}</option><option value="allow">${esc(t("df_a_allow"))}</option></select>`)}
          ${field(t("df_note"), '<input name="note" maxlength="80" autocomplete="off">')}</div>
          <div class="actions-row"><button type="submit" class="btn primary">${icon("plus")}<span>${esc(t("add"))}</span></button></div></form></section>
      <section class="sec"><div class="sec-head df-head-row"><h3>${icon("ban")}${esc(t("df_bans"))} <span class="badge">${num(b.rows.length)}</span></h3>
        <input type="search" id="df-ban-filter" class="df-filter" placeholder="${esc(t("df_filter"))}" aria-label="${esc(t("df_filter"))}" dir="ltr"></div><div id="df-bans">${bans}</div>${f2b}</section>
      <div class="df-grid2"><section class="sec"><div class="sec-head"><h3>${icon("ban")}${esc(t("df_blocklist"))}</h3></div>${listTable(b.block, "block")}</section>
      <section class="sec"><div class="sec-head"><h3>${icon("check")}${esc(t("df_allowlist"))}</h3></div>${listTable(b.allow, "allow")}</section></div>`;
  }
  const clock = (ts) => new Date(ts * 1000).toLocaleString(P.state.lang === "fa" ? "fa-IR" : "en-GB", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false });
  const dur = (s) => (s == null ? "–" : s >= 86400 ? t("df_d", { n: nf(s / 86400, s >= 864000 ? 0 : 1) }) : s >= 3600 ? t("df_h", { n: nf(s / 3600, s >= 36000 ? 0 : 1) }) : t("df_m", { n: nf(Math.max(1, s / 60), 0) }));
  function banReason(r) {   // why this address is banned, in words
    let kind = "", text;
    if (r.source === "fail2ban") text = t("df_br_f2b", { jail: r.jail || "fail2ban" });
    else if (r.reason === "syn_flood") { kind = "bad"; text = t("df_br_syn"); }
    else if (r.reason === "conn_flood") { kind = "bad"; text = t("df_br_conn"); }
    else if (r.reason === "ssh_rate") { kind = "warn"; text = t("df_br_sshrate"); }
    else if (r.reason === "rule") { kind = "warn"; text = t("df_br_rule", { name: r.rule || "?" }); }
    else if (r.source === "ssh") {
      kind = "warn";
      const [n, w] = String(r.detail || "").split("/");
      text = n && w ? t("df_br_ssh_n", { n, w }) : t("df_br_ssh");
    } else if (r.source === "manual") text = r.reason && r.reason !== "manual" ? t("df_br_manual_note", { note: r.reason }) : t("df_br_manual");
    else { kind = "bad"; text = t("df_br_flood"); }
    return pill(kind, text, false);
  }
  function banLeft(r) {
    if (r.left == null) return `<span class="muted">${esc(t("df_ban_forever"))}</span>`;
    const pct = r.total ? Math.max(2, Math.min(100, (r.left / r.total) * 100)) : null;
    return `<span class="df-left"><b>${num(esc(dur(r.left)))}</b>${r.total ? `<small class="muted">${esc(t("df_ban_of", { n: dur(r.total) }))}</small><i style="--w:${pct.toFixed(1)}%"></i>` : ""}</span>`;
  }
  function filterBans(q) {
    q = q.trim().toLowerCase();
    D.root.querySelectorAll("#df-bans tbody tr").forEach((tr) => { tr.hidden = !!q && !(tr.dataset.ip || "").toLowerCase().includes(q); });
  }

  // ---------------------------------------------------------------- SSH guard
  async function renderSsh() {
    const s = await api("/api/defender/ssh"), g = s.config;
    const sw = (name, on, label) => `<label class="df-switch"><span class="switch"><input type="checkbox" name="${name}" ${on ? "checked" : ""}><span></span></span><span><b>${esc(label)}</b></span></label>`;
    const top = table([
      { h: "df_ip", cls: "strong", cell: (r) => num(esc(r.ip)) },
      { h: "df_attempts", cell: (r) => num(nf(r.n, 0)) },
      { h: "actions", cell: (r) => btnIcon("ban", `${t("df_ban1h")} ${r.ip}`, `data-a="ban" data-ip="${esc(r.ip)}" data-min="60"`, "danger") },
    ], s.top);
    return `<section class="sec"><div class="sec-head"><h3>${icon("terminal")}${esc(t("df_ssh_title"))}</h3><p class="muted">${esc(t("df_ssh_sub"))}</p></div>
        ${s.available ? "" : `<div class="notice warn">${icon("bell")}<span>${esc(t("df_ssh_nolog"))}</span></div>`}
        ${s.fail2ban ? `<div class="notice">${icon("shield")}<span>${esc(t("df_f2b_present"))}</span></div>` : ""}
        <form class="subcard" data-f="ssh">${sw("enabled", g.enabled, t("df_ssh_on"))}${sw("l4", g.l4, t("df_ssh_l4"))}${sw("exempt_private", g.exempt_private, t("df_ssh_private"))}
          <div class="df-form-grid">${field(t("df_ssh_failures"), `<input type="number" name="failures" min="2" max="100" value="${g.failures}" dir="ltr" required>`)}
          ${field(t("df_ssh_window"), `<input type="number" name="window" min="1" max="1440" value="${g.window}" dir="ltr" required>`)}
          ${field(t("df_ssh_ban"), `<input type="number" name="ban" min="1" max="525600" value="${g.ban}" dir="ltr" required>`)}</div>
          <div class="actions-row"><button type="submit" class="btn primary">${icon("check")}<span>${esc(t("df_save"))}</span></button></div></form></section>
      <section class="sec"><div class="sec-head"><h3>${icon("alert")}${esc(t("df_ssh_top"))}</h3><p class="muted">${esc(t("df_ssh_24h"))}: <b>${num(nf(s.failures_24h, 0))}</b></p></div>${top}</section>`;
  }

  // ---------------------------------------------------------------- hardening
  async function renderHardening() {
    const a = await api("/api/defender/audit");
    const lv = a.score >= 85 ? "" : a.score >= 60 ? "warn" : "bad";
    const grade = a.score >= 90 ? "A" : a.score >= 75 ? "B" : a.score >= 60 ? "C" : a.score >= 40 ? "D" : "F";
    const C = 2 * Math.PI * 42;
    const ring = `<div class="ring ${lv} df-score-ring"><svg viewBox="0 0 104 104" aria-hidden="true"><circle class="track" cx="52" cy="52" r="42" fill="none" stroke-width="10"/><circle class="fill" cx="52" cy="52" r="42" fill="none" stroke-width="10" stroke-dasharray="${((C * a.score) / 100).toFixed(1)} ${C.toFixed(1)}"/></svg><div class="center"><span class="value num">${a.score}</span></div></div>`;
    const checks = [...a.checks].sort((x, y) => y.sev - x.sev);
    const items = checks.map((c) => {
      const p = c.params || {};
      const title = tt(`df_c_${c.id}`, c.sev ? 0 : 1, p);
      return `<li class="df-check s${c.sev}">${sev(c.sev)}<div><b>${esc(title)}</b>${c.sev ? `<p>${esc(t(`df_f_${c.id}`))}</p>` : ""}</div></li>`;
    }).join("");
    const sys = table([
      { h: "df_setting", cls: "wrap-cell", cell: (r) => `<code dir="ltr">${esc(r.key)}</code><div class="sub-line">${esc(t(r.why))}</div>` },
      { h: "df_current", cell: (r) => num(esc(r.current ?? "–")) },
      { h: "df_recommended", cell: (r) => num(esc(r.recommended)) },
      { h: "status", cell: (r) => (r.ok == null ? "–" : r.ok ? pill("ok", t("df_sev0")) : pill("warn", t("df_sev1"))) },
    ], a.sysctl);
    const n = D.st.config.notify;
    const sw = (name, on, label) => `<label class="df-switch"><span class="switch"><input type="checkbox" name="${name}" ${on ? "checked" : ""}><span></span></span><span><b>${esc(label)}</b></span></label>`;
    return `<section class="card df-score ${lv}">${ring}<div><h3>${esc(t("df_score"))} <span class="df-grade">${grade}</span></h3><p class="muted">${esc(tt(`df_c_fw_enabled`, D.st.enabled ? 1 : 0))}</p></div></section>
      <section class="sec"><div class="sec-head"><h3>${icon("check")}${esc(t("df_checks"))}</h3></div><ul class="df-checks">${items}</ul></section>
      <section class="sec"><div class="sec-head df-head-row"><div><h3>${icon("gear")}${esc(t("df_kernel"))}</h3><p class="muted">${esc(t("df_kernel_sub"))}</p></div>
        <div class="row-actions"><button type="button" class="btn small primary" data-a="sysctl" data-act="apply">${esc(t("df_apply_all"))}</button><button type="button" class="btn small" data-a="sysctl" data-act="restore" ${a.sysctl_applied.length ? "" : "disabled"}>${esc(t("df_restore"))}</button></div></div>${sys}</section>
      <section class="sec"><div class="sec-head"><h3>${icon("send")}${esc(t("df_notify"))}</h3></div><form class="subcard" data-f="notify">${sw("attacks", n.attacks, t("df_notify_attacks"))}${sw("bans", n.bans, t("df_notify_bans"))}</form></section>
      <section class="sec"><div class="sec-head"><h3>${icon("download")}${esc(t("df_backup"))}</h3><p class="muted">${esc(t("df_backup_sub"))}</p></div>
        <div class="row-actions"><button type="button" class="btn" data-a="export">${icon("download")}<span>${esc(t("df_export"))}</span></button>
        <label class="btn">${icon("upload")}<span>${esc(t("df_import"))}</span><input type="file" accept="application/json,.json" data-import hidden></label></div></section>`;
  }

  // ---------------------------------------------------------------- strings for countries, fail2ban, backup
  P.addStrings({
    df_t_countries: "Countries", df_t_f2b: "fail2ban", df_r_geo: "Blocked countries",
    // countries
    df_geo_title: "Block countries", df_geo_sub: "Drop every connection that comes from the selected countries. The address lists are downloaded from ipdeny.com and refreshed every week.",
    df_geo_warn: "Visitors from these countries will not reach any service on this server, including your VPN or sites. Logged-in admins, the allowlist and Cloudflare are not affected.",
    df_geo_selected: "Blocked countries", df_geo_none: "No country is blocked.", df_geo_search: "Search countries…", df_geo_ranges: "{n} ranges", df_geo_off: "Turn protection on (Overview) for country blocking to take effect.",
    df_geo_all: "All countries",
    // fail2ban
    df_f2b_what: "fail2ban reads the logs of your services and bans addresses that keep failing: wrong passwords, scanners, abusers. Each protection it runs is called a jail.",
    df_f2b_running: "fail2ban is running", df_f2b_stopped: "fail2ban is installed but stopped", df_f2b_missing: "fail2ban is not installed",
    df_f2b_stopped_sub: "Nothing is banned while it is stopped. Start it to protect your services again.",
    df_f2b_missing_sub: "Install it with one click: it watches SSH logins right away, and you can turn on more protections below.",
    df_f2b_nopm: "This server has no supported package manager (apt, dnf, yum), so fail2ban cannot be installed from here.",
    df_f2b_install: "Install fail2ban", df_f2b_uninstall: "Uninstall", df_f2b_start: "Start", df_f2b_stop: "Stop", df_f2b_restart: "Restart", df_f2b_reload: "Reload settings",
    df_f2b_boot_on: "Starts at boot", df_f2b_boot_off: "Does not start at boot", df_f2b_boot_enable: "Start at boot", df_f2b_boot_disable: "Do not start at boot",
    df_f2b_version: "Version", df_f2b_jails_n: "Protections", df_f2b_banned_now: "Banned now",
    df_f2b_install_confirm: "Install fail2ban with the system package manager? This takes a minute or two.",
    df_f2b_uninstall_confirm: "Uninstall fail2ban? Its bans are lifted.", df_f2b_purge: "Also delete its settings files",
    df_f2b_stop_confirm: "Stop fail2ban? Nobody is banned while it is stopped and current bans are lifted.",
    df_f2b_job_install: "Installing fail2ban…", df_f2b_job_uninstall: "Removing fail2ban…", df_f2b_job_ok: "Done", df_f2b_job_fail: "Failed; see the output below",
    df_f2b_jails: "Protections (jails)", df_f2b_jails_sub: "Each switch turns one protection on or off. Changes are checked by fail2ban before they are applied.",
    df_f2b_on: "On", df_f2b_off: "Off", df_f2b_failed: "Failing now", df_f2b_total: "Banned in total",
    df_f2b_rule: "{tries} failures within {window} → banned for {ban}", df_f2b_settings: "Settings", df_f2b_bans: "Banned IPs",
    df_f2b_custom: "Custom protection set up on this server.", df_f2b_source: "Reads", df_f2b_journal: "system journal",
    df_f2b_tries: "Failures allowed", df_f2b_window: "Within", df_f2b_bantime: "Ban for", df_f2b_forever: "forever",
    df_f2b_defaults: "General settings", df_f2b_defaults_sub: "Used by every protection that does not set its own value.",
    df_f2b_increment: "Ban repeat offenders for longer each time", df_f2b_increment_sub: "Every new ban of the same address lasts longer, up to the maximum below.", df_f2b_maxtime: "Longest ban",
    df_f2b_ignore: "Never ban these addresses", df_f2b_ignore_sub: "Your own IPs, office, monitoring. Networks like 10.0.0.0/8 work too.", df_f2b_add_trusted: "Add trusted SSH addresses",
    df_f2b_ban_ip: "Ban an address in this jail", df_f2b_no_bans: "Nobody is banned in this jail.", df_f2b_log: "fail2ban log", df_f2b_log_sub: "The latest lines of /var/log/fail2ban.log.",
    df_f2b_saved: "Saved and applied", df_f2b_ends: "Ends",
    f2bj_sshd: "SSH logins", f2bd_sshd: "Bans addresses that guess SSH passwords or users.",
    f2bj_recidive: "Repeat offenders", f2bd_recidive: "Addresses fail2ban had to ban again and again are banned from every port for a long time.",
    "f2bj_3x-ipl": "3x-ui IP limit", "f2bd_3x-ipl": "Made by 3x-ui: bans VPN users that connect from more devices than their plan allows.",
    "f2bj_nginx-http-auth": "Nginx password pages", "f2bd_nginx-http-auth": "Bans addresses that guess passwords of pages protected by Nginx.",
    "f2bj_nginx-botsearch": "Nginx vulnerability scanners", "f2bd_nginx-botsearch": "Bans bots that probe for admin pages and known weak spots.",
    "f2bj_nginx-bad-request": "Nginx malformed requests", "f2bd_nginx-bad-request": "Bans clients that send broken HTTP requests (usually scanners).",
    "f2bj_nginx-limit-req": "Nginx request floods", "f2bd_nginx-limit-req": "Bans clients Nginx had to throttle (needs limit_req in your Nginx config).",
    "f2bj_apache-auth": "Apache password pages", "f2bd_apache-auth": "Bans addresses that guess passwords of pages protected by Apache.",
    "f2bj_apache-badbots": "Apache bad bots", "f2bd_apache-badbots": "Bans known spam and e-mail harvesting bots.",
    f2bj_postfix: "Mail server (Postfix)", f2bd_postfix: "Bans addresses that abuse the mail server.",
    f2bj_dovecot: "Mailboxes (Dovecot)", f2bd_dovecot: "Bans addresses that guess mailbox passwords.",
    f2bj_vsftpd: "FTP logins", f2bd_vsftpd: "Bans addresses that guess FTP passwords.",
    "f2bj_mysqld-auth": "MySQL logins", "f2bd_mysqld-auth": "Bans addresses that guess database passwords.",
    df_e_f2b_ban: "fail2ban [{jail}] banned {ip}", df_e_f2b_unban: "fail2ban: {ip} unbanned", df_e_f2b_config: "fail2ban settings changed ({what})", df_e_f2b_service: "fail2ban: {action}",
    df_s_fail2ban_jail: "fail2ban · {jail}",
    df_ban_reason: "Why", df_ban_at: "Banned at", df_ban_forever: "until removed", df_ban_of: "of {n}", df_d: "{n} d", df_h: "{n} h", df_m: "{n} min",
    df_br_f2b: "fail2ban · {jail}", df_br_syn: "SYN flood", df_br_conn: "Too many new connections", df_br_sshrate: "Too many SSH connections",
    df_br_rule: "Rule «{name}»", df_br_ssh: "Wrong SSH passwords", df_br_ssh_n: "{n} wrong SSH passwords in {w} min", df_br_manual: "Manual",
    df_br_manual_note: "Manual · {note}", df_br_flood: "Flood",
    df_ban_trust: "Unban {ip} and add it to the allowlist", df_ban_trusted: "{ip} is unbanned and on the allowlist", df_ban_trusted_note: "trusted after a ban",
    df_c_fail2ban_stopped: ["fail2ban is installed but not running", "fail2ban is running"], df_f_fail2ban_stopped: "Start it in the fail2ban tab.",
    // backup
    df_backup: "Backup and restore", df_backup_sub: "Download every firewall setting (rules, lists, limits, countries, fail2ban) as a file, or load one from another server.",
    df_export: "Download backup", df_import: "Restore from file", df_import_confirm: "Replace the firewall settings with the ones in {name}? The rules are tested for 60 seconds like any other change.",
    df_import_bad: "This is not a firewall backup file.",
  }, {
    df_t_countries: "کشورها", df_t_f2b: "fail2ban", df_r_geo: "کشورهای مسدود",
    df_geo_title: "مسدود کردن کشورها", df_geo_sub: "هر اتصالی که از کشورهای انتخاب‌شده بیاید دور ریخته می‌شود. لیست آی‌پی‌ها از ipdeny.com دانلود و هر هفته بروز می‌شود.",
    df_geo_warn: "بازدیدکننده‌های این کشورها به هیچ سرویسی روی این سرور نمی‌رسند، از جمله VPN یا سایت‌هایتان. ادمین‌های واردشده، لیست سفید و Cloudflare تحت تأثیر نیستند.",
    df_geo_selected: "کشورهای مسدود", df_geo_none: "هیچ کشوری مسدود نیست.", df_geo_search: "جستجوی کشور…", df_geo_ranges: "{n} بازه", df_geo_off: "برای اثر کردن مسدودی کشورها، محافظت را (در نمای کلی) روشن کنید.",
    df_geo_all: "همه‌ی کشورها",
    df_f2b_what: "fail2ban لاگ سرویس‌هایتان را می‌خواند و آدرس‌هایی که مدام خطا می‌کنند را مسدود می‌کند: رمز اشتباه، اسکنر، سوءاستفاده. به هر محافظتش «جیل» می‌گویند.",
    df_f2b_running: "fail2ban در حال اجراست", df_f2b_stopped: "fail2ban نصب است ولی متوقف است", df_f2b_missing: "fail2ban نصب نیست",
    df_f2b_stopped_sub: "تا متوقف است هیچ‌کس مسدود نمی‌شود. برای محافظت دوباره روشنش کنید.",
    df_f2b_missing_sub: "با یک کلیک نصبش کنید: بلافاصله ورودهای SSH را زیر نظر می‌گیرد و محافظت‌های بیشتری را پایین می‌توانید روشن کنید.",
    df_f2b_nopm: "این سرور مدیر بسته‌ی پشتیبانی‌شده (apt، dnf، yum) ندارد، پس از اینجا نمی‌شود fail2ban را نصب کرد.",
    df_f2b_install: "نصب fail2ban", df_f2b_uninstall: "حذف", df_f2b_start: "شروع", df_f2b_stop: "توقف", df_f2b_restart: "ری‌استارت", df_f2b_reload: "بارگذاری دوباره‌ی تنظیمات",
    df_f2b_boot_on: "با روشن شدن سرور اجرا می‌شود", df_f2b_boot_off: "با روشن شدن سرور اجرا نمی‌شود", df_f2b_boot_enable: "اجرا هنگام بوت", df_f2b_boot_disable: "اجرا نشدن هنگام بوت",
    df_f2b_version: "نسخه", df_f2b_jails_n: "محافظت‌ها", df_f2b_banned_now: "مسدود فعلی",
    df_f2b_install_confirm: "fail2ban با مدیر بسته‌ی سیستم نصب شود؟ یکی دو دقیقه طول می‌کشد.",
    df_f2b_uninstall_confirm: "fail2ban حذف شود؟ مسدودی‌هایش برداشته می‌شوند.", df_f2b_purge: "فایل‌های تنظیماتش هم پاک شوند",
    df_f2b_stop_confirm: "fail2ban متوقف شود؟ تا متوقف است کسی مسدود نمی‌شود و مسدودی‌های فعلی برداشته می‌شوند.",
    df_f2b_job_install: "در حال نصب fail2ban…", df_f2b_job_uninstall: "در حال حذف fail2ban…", df_f2b_job_ok: "انجام شد", df_f2b_job_fail: "ناموفق؛ خروجی پایین را ببینید",
    df_f2b_jails: "محافظت‌ها (جیل‌ها)", df_f2b_jails_sub: "هر کلید یک محافظت را روشن یا خاموش می‌کند. هر تغییر قبل از اعمال توسط خود fail2ban بررسی می‌شود.",
    df_f2b_on: "روشن", df_f2b_off: "خاموش", df_f2b_failed: "خطای فعلی", df_f2b_total: "کل مسدودها",
    df_f2b_rule: "{tries} خطا در {window} ← مسدود به مدت {ban}", df_f2b_settings: "تنظیمات", df_f2b_bans: "آی‌پی‌های مسدود",
    df_f2b_custom: "محافظت سفارشی که روی این سرور تنظیم شده.", df_f2b_source: "می‌خواند", df_f2b_journal: "ژورنال سیستم",
    df_f2b_tries: "تعداد خطای مجاز", df_f2b_window: "در مدت", df_f2b_bantime: "مدت مسدودی", df_f2b_forever: "همیشه",
    df_f2b_defaults: "تنظیمات کلی", df_f2b_defaults_sub: "برای هر محافظتی که مقدار خودش را ندارد استفاده می‌شود.",
    df_f2b_increment: "مسدودی تکراری هر بار طولانی‌تر شود", df_f2b_increment_sub: "هر مسدودی جدید همان آدرس طولانی‌تر است، تا سقف پایین.", df_f2b_maxtime: "طولانی‌ترین مسدودی",
    df_f2b_ignore: "این آدرس‌ها هرگز مسدود نشوند", df_f2b_ignore_sub: "آی‌پی‌های خودتان، دفتر، مانیتورینگ. شبکه هم می‌شود مثل 10.0.0.0/8.", df_f2b_add_trusted: "افزودن آدرس‌های مورد اعتماد SSH",
    df_f2b_ban_ip: "مسدود کردن یک آدرس در این جیل", df_f2b_no_bans: "در این جیل کسی مسدود نیست.", df_f2b_log: "لاگ fail2ban", df_f2b_log_sub: "آخرین خط‌های /var/log/fail2ban.log.",
    df_f2b_saved: "ذخیره و اعمال شد", df_f2b_ends: "پایان",
    f2bj_sshd: "ورود SSH", f2bd_sshd: "آدرس‌هایی که رمز یا کاربر SSH را حدس می‌زنند مسدود می‌کند.",
    f2bj_recidive: "متخلفان تکراری", f2bd_recidive: "آدرس‌هایی که fail2ban بارها مسدودشان کرده، برای مدت طولانی از همه‌ی پورت‌ها مسدود می‌شوند.",
    "f2bj_3x-ipl": "محدودیت آی‌پی 3x-ui", "f2bd_3x-ipl": "ساخته‌ی 3x-ui: کاربران VPN که با دستگاه‌های بیشتر از پلنشان وصل شوند مسدود می‌شوند.",
    "f2bj_nginx-http-auth": "صفحه‌های رمزدار Nginx", "f2bd_nginx-http-auth": "آدرس‌هایی که رمز صفحه‌های محافظت‌شده با Nginx را حدس می‌زنند مسدود می‌کند.",
    "f2bj_nginx-botsearch": "اسکنرهای آسیب‌پذیری Nginx", "f2bd_nginx-botsearch": "ربات‌هایی که دنبال صفحه‌ی مدیریت و نقطه‌ضعف‌های شناخته‌شده می‌گردند مسدود می‌کند.",
    "f2bj_nginx-bad-request": "درخواست‌های خراب Nginx", "f2bd_nginx-bad-request": "کلاینت‌هایی که درخواست HTTP خراب می‌فرستند (معمولاً اسکنر) مسدود می‌کند.",
    "f2bj_nginx-limit-req": "فلاد درخواست Nginx", "f2bd_nginx-limit-req": "کلاینت‌هایی که Nginx محدودشان کرده مسدود می‌کند (به limit_req در تنظیمات Nginx نیاز دارد).",
    "f2bj_apache-auth": "صفحه‌های رمزدار Apache", "f2bd_apache-auth": "آدرس‌هایی که رمز صفحه‌های محافظت‌شده با Apache را حدس می‌زنند مسدود می‌کند.",
    "f2bj_apache-badbots": "ربات‌های بد Apache", "f2bd_apache-badbots": "ربات‌های اسپم و جمع‌کننده‌ی ایمیل را مسدود می‌کند.",
    f2bj_postfix: "سرور ایمیل (Postfix)", f2bd_postfix: "آدرس‌هایی که از سرور ایمیل سوءاستفاده می‌کنند مسدود می‌کند.",
    f2bj_dovecot: "صندوق‌های ایمیل (Dovecot)", f2bd_dovecot: "آدرس‌هایی که رمز صندوق ایمیل را حدس می‌زنند مسدود می‌کند.",
    f2bj_vsftpd: "ورود FTP", f2bd_vsftpd: "آدرس‌هایی که رمز FTP را حدس می‌زنند مسدود می‌کند.",
    "f2bj_mysqld-auth": "ورود MySQL", "f2bd_mysqld-auth": "آدرس‌هایی که رمز دیتابیس را حدس می‌زنند مسدود می‌کند.",
    df_e_f2b_ban: "fail2ban [{jail}] آدرس {ip} را مسدود کرد", df_e_f2b_unban: "fail2ban: مسدودی {ip} برداشته شد", df_e_f2b_config: "تنظیمات fail2ban تغییر کرد ({what})", df_e_f2b_service: "fail2ban: {action}",
    df_s_fail2ban_jail: "fail2ban · {jail}",
    df_ban_reason: "علت", df_ban_at: "زمان مسدودی", df_ban_forever: "تا وقتی برداشته شود", df_ban_of: "از {n}", df_d: "{n} روز", df_h: "{n} ساعت", df_m: "{n} دقیقه",
    df_br_f2b: "fail2ban · {jail}", df_br_syn: "فلاد SYN", df_br_conn: "اتصال جدید بیش از حد", df_br_sshrate: "اتصال SSH بیش از حد",
    df_br_rule: "قانون «{name}»", df_br_ssh: "رمز اشتباه SSH", df_br_ssh_n: "{n} رمز اشتباه SSH در {w} دقیقه", df_br_manual: "دستی",
    df_br_manual_note: "دستی · {note}", df_br_flood: "فلاد",
    df_ban_trust: "{ip} از مسدودی دربیاید و به لیست سفید برود", df_ban_trusted: "{ip} از مسدودی درآمد و در لیست سفید است", df_ban_trusted_note: "مورد اعتماد پس از مسدودی",
    df_c_fail2ban_stopped: ["fail2ban نصب است ولی اجرا نمی‌شود", "fail2ban در حال اجراست"], df_f_fail2ban_stopped: "از تب fail2ban روشنش کنید.",
    df_backup: "پشتیبان‌گیری و بازگردانی", df_backup_sub: "همه‌ی تنظیمات فایروال (قوانین، لیست‌ها، محدودیت‌ها، کشورها، fail2ban) را به‌صورت فایل دانلود کنید، یا فایل یک سرور دیگر را بارگذاری کنید.",
    df_export: "دانلود پشتیبان", df_import: "بازگردانی از فایل", df_import_confirm: "تنظیمات فایروال با تنظیمات {name} جایگزین شود؟ قوانین مثل هر تغییر دیگری ۶۰ ثانیه آزمایش می‌شوند.",
    df_import_bad: "این فایل پشتیبان فایروال نیست.",
  });
  P.addIcons({
    jail: '<rect x="4" y="3" width="16" height="18" rx="2"/><path d="M9 3v18M15 3v18M4 12h16"/>',
    download: '<path d="M12 4v11M7 10l5 5 5-5M5 20h14"/>',
    upload: '<path d="M12 20V9M7 14l5-5 5 5M5 4h14"/>',
  });

  // ---------------------------------------------------------------- countries
  const COUNTRIES = ("ad ae af ag ai al am ao aq ar as at au aw ax az ba bb bd be bf bg bh bi bj bl bm bn bo bq br bs bt bw by bz ca cd cf cg ch ci ck cl cm cn co cr cu cv cw cy cz de dj dk dm do dz ec ee eg er es et fi fj fk fm fo fr ga gb gd ge gf gg gh gi gl gm gn gp gq gr gt gu gw gy hk hn hr ht hu id ie il im in io iq ir is it je jm jo jp ke kg kh ki km kn kp kr kw ky kz la lb lc li lk lr ls lt lu lv ly ma mc md me mf mg mh mk ml mm mn mo mp mq mr ms mt mu mv mw mx my mz na nc ne nf ng ni nl no np nr nu nz om pa pe pf pg ph pk pl pm pr ps pt pw py qa re ro rs ru rw sa sb sc sd se sg si sk sl sm sn so sr ss st sv sx sy sz tc td tg th tj tk tl tm tn to tr tt tv tw tz ua ug us uy uz va vc ve vg vi vn vu wf ws ye yt za zm zw").split(" ");
  let regionNames = null;
  const ccName = (cc) => {
    try {
      if (!regionNames || regionNames._lang !== P.state.lang) { regionNames = new Intl.DisplayNames([P.state.lang === "fa" ? "fa" : "en"], { type: "region" }); regionNames._lang = P.state.lang; }
      return regionNames.of(cc.toUpperCase()) || cc.toUpperCase();
    } catch (e) { return cc.toUpperCase(); }
  };
  let enNames = null;
  const ccEnglish = (cc) => { try { enNames = enNames || new Intl.DisplayNames(["en"], { type: "region" }); return enNames.of(cc.toUpperCase()) || ""; } catch (e) { return ""; } };
  const flag = (cc) => String.fromCodePoint(...[...cc.toUpperCase()].map((c) => 0x1f1e6 - 65 + c.charCodeAt(0)));

  // ---------------------------------------------------------------- fail2ban
  const fmtSecs = (s) => {
    s = Number(s);
    if (s < 0) return t("df_f2b_forever");
    if (!(s >= 0)) return "–";
    const u = [[604800, "w"], [86400, "d"], [3600, "h"], [60, "m"], [1, "s"]].find(([n]) => s >= n && s % n === 0) || [1, "s"];
    return `${nf(s / u[0], 0)}${u[1]}`;
  };
  const DUR = { "1m": 60, "5m": 300, "10m": 600, "30m": 1800, "1h": 3600, "3h": 10800, "6h": 21600, "12h": 43200, "1d": 86400, "3d": 259200, "1w": 604800, "2w": 1209600, "4w": 2419200, "-1": -1 };
  const durSelect = (name, cur, keys) => {
    const curS = typeof cur === "number" ? cur : DUR[cur] ?? null;
    let found = false;
    const opts = keys.map((k) => { const on = DUR[k] === curS; found = found || on; return `<option value="${k}" ${on ? "selected" : ""}>${esc(k === "-1" ? t("df_f2b_forever") : fmtSecs(DUR[k]))}</option>`; }).join("");
    const extra = !found && cur != null ? `<option value="${esc(typeof cur === "number" ? `${cur}` : cur)}" selected>${esc(typeof cur === "number" ? fmtSecs(cur) : cur)}</option>` : "";
    return `<select name="${name}">${extra}${opts}</select>`;
  };
  const WINDOWS = ["1m", "5m", "10m", "30m", "1h", "3h", "6h", "12h", "1d"], BANS_T = ["10m", "30m", "1h", "3h", "6h", "12h", "1d", "3d", "1w", "2w", "4w", "-1"];
  const jailTitle = (n) => { const k = `f2bj_${n}`, v = t(k); return v === k ? n : v; };
  const jailDesc = (n) => { const k = `f2bd_${n}`, v = t(k); return v === k ? t("df_f2b_custom") : v; };

  async function renderF2b() {
    D.f2b = await api("/api/defender/f2b");
    schedJob();
    setTimeout(fillFiles, 0);
    return f2bHTML();
  }
  async function fillFiles() {
    const box = D.root && D.root.querySelector("#df-f2b-files");
    if (box && D.f2b && D.f2b.installed) box.innerHTML = await filesSection();
  }
  function schedJob() {
    clearTimeout(D.f2bJobT);
    if (D.f2b && D.f2b.job && D.f2b.job.running) D.f2bJobT = setTimeout(async () => { if (D.tab === "f2b") { D.f2b = await api("/api/defender/f2b").catch(() => D.f2b); paintF2b(); schedJob(); } }, 1500);
  }
  const paintF2b = () => { const b = D.root.querySelector("#df-body"); if (b && D.tab === "f2b") { b.innerHTML = f2bHTML(); fillFiles(); } };

  function f2bHTML() {
    const f = D.f2b, job = f.job || {};
    const jobBox = job.action && (job.running || Date.now() / 1000 - job.ended < 600)
      ? `<div class="notice ${job.running ? "warn" : job.ok ? "ok" : "bad"}">${icon(job.running ? "clock" : job.ok ? "okmark" : "alert")}<span>${esc(job.running ? t(`df_f2b_job_${job.action}`) : job.ok ? t("df_f2b_job_ok") : t("df_f2b_job_fail"))}</span></div>
         <pre class="logs df-joblog" dir="ltr">${esc(job.log || "…")}</pre>` : "";
    const busy = job.running ? "disabled" : "";
    if (!f.installed) {
      return `<section class="card hero warn df-hero"><div class="hero-icon">${icon("jail")}</div><div class="hero-text"><h2>${esc(t("df_f2b_missing"))}</h2><p>${esc(t("df_f2b_missing_sub"))}</p><p class="muted">${esc(t("df_f2b_what"))}</p></div>
        <div class="df-hero-act">${f.pm ? `<button type="button" class="btn primary df-cta" data-a="f2b-install" ${busy}>${icon("download")}<span>${esc(t("df_f2b_install"))}</span></button>` : ""}</div></section>
        ${f.pm ? "" : `<div class="notice bad">${icon("alert")}<span>${esc(t("df_f2b_nopm"))}</span></div>`}${jobBox}`;
    }
    const banned = (f.jails || []).reduce((a, j) => a + (j.banned || 0), 0);
    const tone = f.running ? "" : "bad";
    const svc = f.running
      ? `<button type="button" class="btn small" data-a="f2b-svc" data-act="restart" ${busy}>${icon("refresh")}<span>${esc(t("df_f2b_restart"))}</span></button>
         <button type="button" class="btn small" data-a="f2b-svc" data-act="reload" ${busy}>${icon("sliders")}<span>${esc(t("df_f2b_reload"))}</span></button>
         <button type="button" class="btn small ghost danger" data-a="f2b-svc" data-act="stop" ${busy}>${icon("stop")}<span>${esc(t("df_f2b_stop"))}</span></button>`
      : `<button type="button" class="btn primary" data-a="f2b-svc" data-act="start" ${busy}>${icon("play")}<span>${esc(t("df_f2b_start"))}</span></button>`;
    const boot = f.boot === "enabled"
      ? `<button type="button" class="btn small ghost" data-a="f2b-svc" data-act="disable" ${busy}>${esc(t("df_f2b_boot_disable"))}</button>`
      : `<button type="button" class="btn small" data-a="f2b-svc" data-act="enable" ${busy}>${esc(t("df_f2b_boot_enable"))}</button>`;
    const hero = `<section class="card hero df-hero ${tone}"><div class="hero-icon">${icon("jail")}</div>
      <div class="hero-text"><h2>${esc(t(f.running ? "df_f2b_running" : "df_f2b_stopped"))}</h2><p>${esc(f.running ? t("df_f2b_what") : t("df_f2b_stopped_sub"))}</p>
        <div class="hero-meta">${f.version ? `<span class="chip">${esc(t("df_f2b_version"))} <b>${num(esc(f.version))}</b></span>` : ""}
          <span class="chip">${icon("jail")}${esc(t("df_f2b_jails_n"))} <b>${num((f.jails || []).length)}</b></span>
          <span class="chip">${icon("ban")}${esc(t("df_f2b_banned_now"))} <b>${num(banned)}</b></span>
          <span class="chip">${icon(f.boot === "enabled" ? "okmark" : "alert")}${esc(t(f.boot === "enabled" ? "df_f2b_boot_on" : "df_f2b_boot_off"))}</span></div></div>
      <div class="df-hero-act"><div class="row-actions">${svc}</div><div class="row-actions">${boot}<button type="button" class="btn small ghost danger" data-a="f2b-uninstall" ${busy}>${icon("trash")}<span>${esc(t("df_f2b_uninstall"))}</span></button></div></div></section>`;
    const managed = f.managed || { default: {}, jails: {} };
    const running = new Map((f.jails || []).map((j) => [j.name, j]));
    const names = [...running.keys(), ...Object.keys(managed.jails).filter((n) => !running.has(n) && managed.jails[n].enabled === false), ...(f.available || []).map((a) => a.name).filter((n) => !running.has(n) && !(n in managed.jails && managed.jails[n].enabled === false))];
    const cards = [...new Set(names)].map((n) => jailCard(n, running.get(n))).join("");
    const d = managed.default || {}, ref = (f.jails || []).find((j) => j.name === "sshd") || (f.jails || [])[0] || {};
    const ignore = d.ignoreip || ref.ignoreip || [];
    D.f2bIgnore = D.f2bIgnore || [...ignore];
    const ignChips = D.f2bIgnore.map((ip, i) => `<span class="chip">${num(esc(ip))}<button type="button" class="chip-x" data-a="f2b-ign-del" data-i="${i}" aria-label="${esc(t("df_remove"))} ${esc(ip)}">${icon("x")}</button></span>`).join("");
    const defaults = `<section class="sec"><div class="sec-head"><h3>${icon("sliders")}${esc(t("df_f2b_defaults"))}</h3><p class="muted">${esc(t("df_f2b_defaults_sub"))}</p></div>
      <form class="subcard" data-f="f2b-defaults"><div class="df-form-grid">
        ${field(t("df_f2b_tries"), `<input type="number" name="maxretry" min="1" max="100" value="${esc(d.maxretry || ref.maxretry || 5)}" dir="ltr" required>`)}
        ${field(t("df_f2b_window"), durSelect("findtime", d.findtime || ref.findtime || 600, WINDOWS))}
        ${field(t("df_f2b_bantime"), durSelect("bantime", d.bantime || ref.bantime || 600, BANS_T))}
        ${field(t("df_f2b_maxtime"), durSelect("maxtime", d["bantime.maxtime"] || "4w", ["1d", "3d", "1w", "2w", "4w", "-1"]))}</div>
        <label class="df-switch"><span class="switch"><input type="checkbox" name="increment" ${d["bantime.increment"] ? "checked" : ""}><span></span></span><span><b>${esc(t("df_f2b_increment"))}</b><small>${esc(t("df_f2b_increment_sub"))}</small></span></label>
        <div class="field"><label>${esc(t("df_f2b_ignore"))}</label><p class="hint">${esc(t("df_f2b_ignore_sub"))}</p><div class="chips">${ignChips}</div>
          <div class="inline-field df-inline"><input name="newip" dir="ltr" placeholder="203.0.113.7" autocomplete="off" aria-label="${esc(t("df_f2b_ignore"))}"><button type="button" class="btn small" data-a="f2b-ign-add">${icon("plus")}<span>${esc(t("add"))}</span></button>
          ${(f.admin_ips || []).length ? `<button type="button" class="btn small" data-a="f2b-ign-trusted">${icon("check")}<span>${esc(t("df_f2b_add_trusted"))}</span></button>` : ""}</div></div>
        <div class="actions-row"><button type="submit" class="btn primary" ${busy}>${icon("check")}<span>${esc(t("df_save"))}</span></button></div></form></section>`;
    const logSec = f.log ? `<section class="sec"><details class="df-logbox"><summary data-a="f2b-log-open"><b>${icon("file")}${esc(t("df_f2b_log"))}</b> <span class="muted">${esc(t("df_f2b_log_sub"))}</span></summary>
      <div class="row-actions" style="margin:10px 0"><button type="button" class="btn small" data-a="f2b-log">${icon("refresh")}<span>${esc(t("refresh"))}</span></button></div><pre class="logs df-joblog" id="df-f2b-log" dir="ltr">…</pre></details></section>` : "";
    return `${hero}${f.error ? `<div class="notice bad">${icon("alert")}<span>${esc(f.error)}</span></div>` : ""}${jobBox}
      <section class="sec"><div class="sec-head df-head-row"><div><h3>${icon("shield")}${esc(t("df_f2b_jails"))}</h3><p class="muted">${esc(t("df_f2b_jails_sub"))}</p></div>
        <button type="button" class="btn small primary" data-a="f2b-jail-new" ${busy}>${icon("plus")}<span>${esc(t("df_j_new"))}</span></button></div><div class="f2b-grid">${cards}</div></section>
      ${defaults}<div id="df-f2b-files"></div>${logSec}`;
  }

  function jailCard(name, j) {
    const on = !!j;
    const rule = j ? t("df_f2b_rule", { tries: nf(j.maxretry, 0), window: fmtSecs(j.findtime), ban: fmtSecs(j.bantime) }) : "";
    const src = j ? (j.source === "journal" ? t("df_f2b_journal") : j.source) : "";
    return `<article class="f2b-jail${on ? " on" : ""}">
      <header><span class="f2b-ic">${icon(name === "sshd" ? "terminal" : name === "recidive" ? "clock" : "jail")}</span>
        <div class="f2b-name"><b>${esc(jailTitle(name))}</b><small dir="ltr">${esc(name)}</small></div>
        <label class="switch" title="${esc(t(on ? "df_f2b_on" : "df_f2b_off"))}"><input type="checkbox" data-jail-toggle="${esc(name)}" ${on ? "checked" : ""} aria-label="${esc(jailTitle(name))}"><span></span></label></header>
      <p class="f2b-desc">${esc(jailDesc(name))}</p>
      ${j ? `<div class="f2b-stats"><div class="${j.banned ? "hot" : ""}"><b>${num(nf(j.banned, 0))}</b><span>${esc(t("df_f2b_banned_now"))}</span></div><div><b>${num(nf(j.banned_total, 0))}</b><span>${esc(t("df_f2b_total"))}</span></div><div><b>${num(nf(j.failed, 0))}</b><span>${esc(t("df_f2b_failed"))}</span></div></div>
        <p class="f2b-rule">${icon("sliders")}<span>${esc(rule)}</span></p>${src ? `<p class="f2b-src muted">${esc(t("df_f2b_source"))}: <span dir="ltr">${esc(src)}</span></p>` : ""}
        <footer><button type="button" class="btn small" data-a="f2b-jail-set" data-jail="${esc(name)}">${icon("gear")}<span>${esc(t("df_f2b_settings"))}</span></button>
          <button type="button" class="btn small" data-a="f2b-jail-bans" data-jail="${esc(name)}">${icon("ban")}<span>${esc(t("df_f2b_bans"))} (${num(j.banned)})</span></button></footer>` : ""}
      <footer class="f2b-manage"><button type="button" class="btn small ghost" data-a="f2b-jail-edit" data-jail="${esc(name)}">${icon("sliders")}<span>${esc(t("df_j_edit"))}</span></button>
        <button type="button" class="btn small ghost danger" data-a="f2b-jail-del" data-jail="${esc(name)}">${icon("trash")}<span>${esc(t("df_j_delete"))}</span></button></footer>
    </article>`;
  }

  function jailSettingsDialog(name) {
    const j = (D.f2b.jails || []).find((x) => x.name === name) || {};
    openDialog({
      title: `${jailTitle(name)} · ${t("df_f2b_settings")}`, submit: t("df_save"),
      body: `<p class="muted">${esc(jailDesc(name))}</p><div class="field-row">
        ${field(t("df_f2b_tries"), `<input type="number" name="maxretry" min="1" max="100" value="${esc(j.maxretry || 5)}" dir="ltr" required>`)}
        ${field(t("df_f2b_window"), durSelect("findtime", j.findtime, WINDOWS))}</div>
        ${field(t("df_f2b_bantime"), durSelect("bantime", j.bantime, BANS_T))}`,
      onSubmit: async (form) => {
        D.f2b = await post("/api/defender/f2b/jail", { name, maxretry: +form.elements.maxretry.value, findtime: form.elements.findtime.value, bantime: form.elements.bantime.value });
        toast(t("df_f2b_saved"));
        paintF2b();
      },
    });
  }

  function jailBansDialog(name) {
    const left = (u) => (u ? `${fmtSecs(Math.max(0, Math.round(u - Date.now() / 1000)))}` : "–");
    const dlg = openDialog({
      title: `${jailTitle(name)} · ${t("df_f2b_bans")}`, wide: true, hideSubmit: true, cancel: t("close"),
      body: `<form class="inline-field df-inline" data-f="f2b-ban" style="margin:0 0 14px"><input name="ip" dir="ltr" required placeholder="203.0.113.7" autocomplete="off" aria-label="${esc(t("df_f2b_ban_ip"))}"><button type="submit" class="btn small danger">${icon("ban")}<span>${esc(t("df_f2b_ban_ip"))}</span></button></form><div id="df-jb"><div class="skeleton"></div></div>`,
      onOpen: async (d) => {
        const box = d.querySelector("#df-jb");
        const load = async () => {
          try {
            const r = await api("/api/defender/f2b/bans", { jail: name });
            box.innerHTML = r.rows.length ? table([
              { h: "df_ip", cls: "strong", cell: (x) => num(esc(x.ip)) },
              { h: "df_left", cell: (x) => num(esc(left(x.until))) },
              { h: "actions", cell: (x) => `<button type="button" class="btn small" data-unban="${esc(x.ip)}">${esc(t("df_unban"))}</button>` },
            ], r.rows) : `<div class="empty">${esc(t("df_f2b_no_bans"))}</div>`;
          } catch (e) { box.innerHTML = `<div class="notice bad">${esc(e.message)}</div>`; }
        };
        box.addEventListener("click", async (e) => {
          const b = e.target.closest("[data-unban]");
          if (b && await act(b, () => post("/api/defender/f2b/unban", { jail: name, ip: b.dataset.unban }), `${b.dataset.unban} ✓`)) load();
        });
        d.querySelector('[data-f="f2b-ban"]').addEventListener("submit", async (e) => {
          e.preventDefault();
          const ip = e.target.elements.ip.value.trim();
          if (await act(e.target.querySelector("button"), () => post("/api/defender/f2b/ban", { jail: name, ip }), `${ip} ✓`)) { e.target.reset(); load(); }
        });
        load();
      },
    });
    dlg.addEventListener("close", () => { if (D.tab === "f2b") showTab("f2b"); });
  }

  function uninstallDialog() {
    openDialog({
      title: t("df_f2b_uninstall"), submit: t("df_f2b_uninstall"), danger: true,
      body: `<p>${esc(t("df_f2b_uninstall_confirm"))}</p><label class="df-switch"><span class="switch"><input type="checkbox" name="purge"><span></span></span><span><b>${esc(t("df_f2b_purge"))}</b></span></label>`,
      onSubmit: async (form) => {
        const r = await post("/api/defender/f2b/uninstall", { purge: form.elements.purge.checked });
        D.f2b = { ...D.f2b, job: r.job };
        paintF2b();
        schedJob();
      },
    });
  }

  // ---------------------------------------------------------------- backup (hardening tab)
  async function exportBackup(btn) {
    const data = await act(btn, () => api("/api/defender/export"));
    if (!data) return;
    const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `firewall-backup-${new Date().toISOString().slice(0, 10)}.json`;
    document.body.appendChild(a);
    a.click();
    setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
  }
  async function importBackup(file) {
    let data;
    try { data = JSON.parse(await file.text()); } catch (e) { return toast(t("df_import_bad"), "bad"); }
    if (!data || data.app !== "server-monitor-firewall") return toast(t("df_import_bad"), "bad");
    if (!(await confirmBox({ message: t("df_import_confirm", { name: file.name }), label: t("df_import"), danger: false }))) return;
    if (await apply(null, "import", { data })) { D.fw = null; D.adv = null; rerender(); }
  }

  // ---------------------------------------------------------------- full control: jail editor, files, advanced
  P.addStrings({
    df_t_advanced: "Advanced",
    df_j_edit: "Edit", df_j_delete: "Delete", df_j_new: "New jail", df_j_name: "Jail name", df_j_name_hint: "Letters, digits, - _ . (for example my-app).",
    df_j_enabled: "Enabled", df_j_port: "Ports", df_j_port_hint: "ssh, http,https, 8080 or 1000:2000. Empty = the jail's default.", df_j_protocol: "Protocol",
    df_j_filter: "Filter", df_j_filter_hint: "Which patterns count as a failure (files in filter.d).", df_j_logpath: "Log files", df_j_logpath_hint: "One path per line. Not needed with the systemd backend.",
    df_j_backend: "How to read logs", df_j_banaction: "Ban action", df_j_banaction_hint: "How addresses are blocked (nftables, iptables-multiport, …).", df_j_action: "Actions (advanced)",
    df_j_ignoreip: "Never ban (this jail)", df_j_increment: "Longer bans for repeat offenders", df_j_inherit: "Like the general settings", df_j_on: "On", df_j_off: "Off",
    df_j_extra: "More settings", df_j_extra_hint: "Any other fail2ban option, one `key = value` per line.", df_j_from: "from {file}", df_j_defined: "Defined in: {files}",
    df_j_delete_confirm: "Delete the jail {name}? Its section is removed from the files under /etc/fail2ban (a backup is kept in /etc/fail2ban/.panel-backup).",
    df_j_deleted: "Jail deleted", df_j_stock_off: "This jail ships with fail2ban (jail.conf), so it was switched off and its overrides were removed.", df_j_saved: "Saved, checked and applied",
    df_files: "Configuration files", df_files_sub: "Every fail2ban file, for anything the forms do not cover. Each save is checked with fail2ban-client -t; on an error the file goes back to how it was.",
    df_file_new: "New file", df_file_path: "File", df_file_path_hint: "jail.d/name.local, filter.d/name.conf, action.d/name.conf, jail.local …", df_file_size: "Size", df_file_mtime: "Changed",
    df_file_panel: "Written by the panel: changes here are replaced the next time a form is saved.", df_file_deleted: "File deleted", df_file_delete_confirm: "Delete {path}? A backup is kept in /etc/fail2ban/.panel-backup.",
    df_file_bad: "Use a path like jail.d/name.local or filter.d/name.conf",
    df_adv_title: "Advanced settings", df_adv_sub: "Everything the other tabs keep fixed. Changes are tested like any other rule change.",
    df_adv_panel: "Who can open the panel", df_adv_panel_sub: "Only these addresses reach the panel port; everyone else gets no answer. Logged-in SSH users and the allowlist always can. Empty = everyone.",
    df_adv_my_ip: "Add my address ({ip})", df_adv_safety: "Safety", df_adv_rollback: "Test time before changes are kept", df_adv_rollback_off: "Off (apply at once)",
    df_adv_lock: "Keep SSH and panel ports always open", df_adv_lock_sub: "Off: they follow strict mode like any other port. A mistake can lock you out.",
    df_adv_docker: "Never filter Docker traffic", df_adv_docker_sub: "Off: traffic from containers is filtered like any other.", df_adv_logged: "Trust addresses that logged in over SSH", df_adv_logged_sub: "Off: they are limited like anyone else.",
    df_adv_detect: "Attack detection", df_adv_detect_sub: "An attack starts when one of these is passed for 3 seconds, and ends after the calm time.",
    df_adv_drops: "Blocked packets per second", df_adv_cookies: "SYN cookies per second", df_adv_pps: "Incoming packets per second", df_adv_ct: "Connection table full (%)", df_adv_calm: "Calm time (seconds)",
    df_adv_deesc: "Back to normal limits after (minutes)", df_adv_bans: "Bans", df_adv_factor: "Ban a source going this many times over a limit (0 = never ban)",
    df_adv_ssh_rate: "New SSH connections per minute before a ban (0 = no limit)", df_adv_ssh_ban: "SSH ban time (minutes)",
    df_adv_custom: "Custom nftables rules", df_adv_custom_sub: "Statements for new connections, one per line, run before the strict-mode and flood rules. For example: tcp dport 9000 ip saddr 203.0.113.0/24 accept",
    df_adv_sysctl: "Custom kernel settings", df_adv_sysctl_sub: "Any net.*, kernel.*, vm.* or fs.* setting. Applied now and after every reboot; removing one restores the original value.",
    df_adv_key: "Setting", df_adv_value: "Value", df_adv_set: "Set",
  }, {
    df_t_advanced: "پیشرفته",
    df_j_edit: "ویرایش", df_j_delete: "حذف", df_j_new: "جیل جدید", df_j_name: "نام جیل", df_j_name_hint: "حروف، عدد، - _ . (مثلاً my-app).",
    df_j_enabled: "فعال", df_j_port: "پورت‌ها", df_j_port_hint: "ssh، http,https، 8080 یا 1000:2000. خالی = پیش‌فرض جیل.", df_j_protocol: "پروتکل",
    df_j_filter: "فیلتر", df_j_filter_hint: "چه الگوهایی خطا حساب شوند (فایل‌های filter.d).", df_j_logpath: "فایل‌های لاگ", df_j_logpath_hint: "هر خط یک مسیر. با backend سیستم‌دی لازم نیست.",
    df_j_backend: "روش خواندن لاگ", df_j_banaction: "روش مسدودی", df_j_banaction_hint: "آدرس‌ها چطور بسته شوند (nftables، iptables-multiport، …).", df_j_action: "اکشن‌ها (پیشرفته)",
    df_j_ignoreip: "هرگز مسدود نشوند (این جیل)", df_j_increment: "مسدودی طولانی‌تر برای تکرار", df_j_inherit: "مثل تنظیمات کلی", df_j_on: "روشن", df_j_off: "خاموش",
    df_j_extra: "تنظیمات بیشتر", df_j_extra_hint: "هر گزینه‌ی دیگر fail2ban، هر خط یک `key = value`.", df_j_from: "از {file}", df_j_defined: "تعریف‌شده در: {files}",
    df_j_delete_confirm: "جیل {name} حذف شود؟ بخش آن از فایل‌های /etc/fail2ban پاک می‌شود (یک پشتیبان در /etc/fail2ban/.panel-backup می‌ماند).",
    df_j_deleted: "جیل حذف شد", df_j_stock_off: "این جیل همراه خود fail2ban است (jail.conf)، پس خاموش شد و تنظیمات اضافه‌اش پاک شد.", df_j_saved: "ذخیره، بررسی و اعمال شد",
    df_files: "فایل‌های تنظیمات", df_files_sub: "همه‌ی فایل‌های fail2ban، برای هر چیزی که فرم‌ها پوشش نمی‌دهند. هر ذخیره با fail2ban-client -t بررسی می‌شود و اگر خطا داشت فایل به حالت قبل برمی‌گردد.",
    df_file_new: "فایل جدید", df_file_path: "فایل", df_file_path_hint: "jail.d/name.local، filter.d/name.conf، action.d/name.conf، jail.local …", df_file_size: "حجم", df_file_mtime: "تغییر",
    df_file_panel: "این فایل را پنل می‌نویسد: تغییرات اینجا دفعه‌ی بعدی که فرمی ذخیره شود جایگزین می‌شود.", df_file_deleted: "فایل حذف شد", df_file_delete_confirm: "{path} حذف شود؟ یک پشتیبان در /etc/fail2ban/.panel-backup می‌ماند.",
    df_file_bad: "مسیری مثل jail.d/name.local یا filter.d/name.conf بنویسید",
    df_adv_title: "تنظیمات پیشرفته", df_adv_sub: "هر چیزی که تب‌های دیگر ثابت نگه می‌دارند. تغییرات مثل هر تغییر قانون دیگری آزمایش می‌شوند.",
    df_adv_panel: "چه کسی پنل را باز کند", df_adv_panel_sub: "فقط این آدرس‌ها به پورت پنل می‌رسند؛ بقیه هیچ جوابی نمی‌گیرند. کاربرهای واردشده با SSH و لیست سفید همیشه می‌توانند. خالی = همه.",
    df_adv_my_ip: "افزودن آدرس من ({ip})", df_adv_safety: "ایمنی", df_adv_rollback: "مدت آزمایش قبل از ماندن تغییرات", df_adv_rollback_off: "خاموش (فوری اعمال شود)",
    df_adv_lock: "پورت SSH و پنل همیشه باز بماند", df_adv_lock_sub: "خاموش: مثل بقیه‌ی پورت‌ها از حالت سخت‌گیر پیروی می‌کنند. یک اشتباه می‌تواند دسترسی شما را قطع کند.",
    df_adv_docker: "ترافیک داکر هرگز فیلتر نشود", df_adv_docker_sub: "خاموش: ترافیک کانتینرها مثل بقیه فیلتر می‌شود.", df_adv_logged: "اعتماد به آدرس‌هایی که با SSH وارد شده‌اند", df_adv_logged_sub: "خاموش: مثل بقیه محدود می‌شوند.",
    df_adv_detect: "تشخیص حمله", df_adv_detect_sub: "وقتی یکی از این‌ها ۳ ثانیه رد شود حمله شروع می‌شود و بعد از زمان آرامش تمام می‌شود.",
    df_adv_drops: "بسته‌ی مسدود در ثانیه", df_adv_cookies: "SYN cookie در ثانیه", df_adv_pps: "بسته‌ی ورودی در ثانیه", df_adv_ct: "پر شدن جدول اتصال (درصد)", df_adv_calm: "زمان آرامش (ثانیه)",
    df_adv_deesc: "بازگشت به محدودیت عادی بعد از (دقیقه)", df_adv_bans: "مسدودی‌ها", df_adv_factor: "منبعی که چند برابر حد برود مسدود شود (۰ = هرگز مسدود نکن)",
    df_adv_ssh_rate: "اتصال جدید SSH در دقیقه قبل از مسدودی (۰ = بدون محدودیت)", df_adv_ssh_ban: "مدت مسدودی SSH (دقیقه)",
    df_adv_custom: "قوانین دلخواه nftables", df_adv_custom_sub: "دستورهایی برای اتصال‌های جدید، هر خط یکی، قبل از قوانین حالت سخت‌گیر و فلاد. مثال: tcp dport 9000 ip saddr 203.0.113.0/24 accept",
    df_adv_sysctl: "تنظیمات دلخواه کرنل", df_adv_sysctl_sub: "هر تنظیم net.*، kernel.*، vm.* یا fs.*. همین الان و بعد از هر ری‌بوت اعمال می‌شود؛ حذفش مقدار اصلی را برمی‌گرداند.",
    df_adv_key: "تنظیم", df_adv_value: "مقدار", df_adv_set: "اعمال",
  });

  // ---- jail editor
  const BACKENDS = ["auto", "systemd", "polling", "pyinotify"];
  const BANACTIONS = ["nftables", "nftables[type=allports]", "nftables-multiport", "iptables-multiport", "iptables-allports", "ufw", "route"];
  async function jailEditor(name, create = false) {
    const d = create ? { values: {}, base: {}, panel: {}, sources: {}, defined: [], filters: (await api("/api/defender/f2b/jail", { jail: "sshd" }).catch(() => ({ filters: [] }))).filters }
      : await api("/api/defender/f2b/jail", { jail: name });
    const live = ((D.f2b && D.f2b.jails) || []).find((j) => j.name === name) || {};   // what the running jail really uses
    const cur = (k) => { const p = d.panel || {}; const v = p[k] !== undefined ? p[k] : d.values[k] !== undefined ? d.values[k] : ["maxretry", "findtime", "bantime"].includes(k) ? live[k] : undefined; return v === true ? "true" : v === false ? "false" : v ?? ""; };
    const inp = (k, label, hint = "", attrs = "") => field(label, `<input name="${k}" dir="ltr" value="${esc(cur(k))}" autocomplete="off" ${attrs}>`, hint) ;
    const area = (k, label, hint = "", rows = 3) => field(label, `<textarea name="${k}" dir="ltr" rows="${rows}" spellcheck="false">${esc(cur(k).replace(/\n\s+/g, "\n"))}</textarea>`, hint);
    const sel = (k, label, opts) => { const v = cur(k); const has = !v || opts.includes(v); return field(label, `<select name="${k}"><option value="">${esc(t("df_j_inherit"))}</option>${has ? "" : `<option selected value="${esc(v)}">${esc(v)}</option>`}${opts.map((o) => `<option value="${esc(o)}" ${o === v ? "selected" : ""}>${esc(o)}</option>`).join("")}</select>`); };
    const enabled = create ? true : String(cur("enabled")).toLowerCase() === "true";
    const extra = (d.panel || {}).extra || "";
    openDialog({
      title: create ? t("df_j_new") : `${jailTitle(name)} · ${t("df_j_edit")}`, submit: t("df_save"), wide: true,
      body: `${create ? field(t("df_j_name"), '<input name="name" dir="ltr" required pattern="[A-Za-z0-9_.\\-]{1,40}" autocomplete="off">', t("df_j_name_hint"))
        : `<p class="muted">${esc(t("df_j_defined", { files: (d.defined || []).join("، ") || "—" }))}</p>`}
        <label class="df-switch"><span class="switch"><input type="checkbox" name="enabled" ${enabled ? "checked" : ""}><span></span></span><span><b>${esc(t("df_j_enabled"))}</b></span></label>
        <div class="field-row">${field(t("df_j_filter"), `<input name="filter" dir="ltr" list="df-filters" value="${esc(cur("filter"))}" autocomplete="off" ${create ? "required" : ""}><datalist id="df-filters">${(d.filters || []).map((f) => `<option value="${esc(f)}">`).join("")}</datalist>`, t("df_j_filter_hint"))}
          ${sel("backend", t("df_j_backend"), BACKENDS)}</div>
        ${area("logpath", t("df_j_logpath"), t("df_j_logpath_hint"), 2)}
        <div class="field-row">${inp("port", t("df_j_port"), t("df_j_port_hint"))}${sel("protocol", t("df_j_protocol"), ["tcp", "udp", "all"])}</div>
        <div class="field-row">${inp("maxretry", t("df_f2b_tries"), "", 'inputmode="numeric"')}${inp("findtime", t("df_f2b_window"), "10m, 1h, 1d")}</div>
        <div class="field-row">${inp("bantime", t("df_f2b_bantime"), "10m, 1h, 1d, 1w, -1")}${field(t("df_j_increment"), `<select name="bantime.increment"><option value="">${esc(t("df_j_inherit"))}</option><option value="true" ${cur("bantime.increment") === "true" ? "selected" : ""}>${esc(t("df_j_on"))}</option><option value="false" ${cur("bantime.increment") === "false" ? "selected" : ""}>${esc(t("df_j_off"))}</option></select>`)}</div>
        ${field(t("df_j_banaction"), `<input name="banaction" dir="ltr" list="df-banactions" value="${esc(cur("banaction"))}" autocomplete="off"><datalist id="df-banactions">${BANACTIONS.map((b) => `<option value="${esc(b)}">`).join("")}</datalist>`, t("df_j_banaction_hint"))}
        ${area("ignoreip", t("df_j_ignoreip"), t("df_f2b_ignore_sub"), 2)}
        <details class="df-adv"><summary>${esc(t("df_j_extra"))}</summary>${area("action", t("df_j_action"), "", 3)}
          ${field(t("df_j_extra"), `<textarea name="extra" dir="ltr" rows="4" spellcheck="false" placeholder="usedns = no&#10;bantime.factor = 2">${esc(extra)}</textarea>`, t("df_j_extra_hint"))}</details>`,
      onSubmit: async (form) => {
        const el = form.elements, base = d.base || {};
        const body = { name: create ? el.name.value.trim() : name, replace: true };
        if (create) body.create = true;
        const baseEnabled = String(base.enabled ?? "false").toLowerCase() === "true";
        if (create || el.enabled.checked !== baseEnabled) body.enabled = el.enabled.checked;
        for (const k of ["filter", "backend", "logpath", "port", "protocol", "maxretry", "findtime", "bantime", "bantime.increment", "banaction", "ignoreip", "action"]) {
          const v = (el[k].value || "").trim();
          const b = String(base[k] ?? "").replace(/\n\s+/g, "\n").trim();
          if (v && v !== b) body[k] = v;
        }
        if (el.extra.value.trim()) body.extra = el.extra.value;
        D.f2b = await post("/api/defender/f2b/jail", body);
        toast(t("df_j_saved"));
        paintF2b();
      },
    });
  }

  async function deleteJail(name, btn) {
    if (!(await confirmBox({ message: t("df_j_delete_confirm", { name }), label: t("df_j_delete") }))) return;
    const r = await act(btn, () => post("/api/defender/f2b/jail/delete", { name }));
    if (!r) return;
    D.f2b = r;
    toast(r.disabled_only ? t("df_j_stock_off") : t("df_j_deleted"), r.disabled_only ? "warn" : "");
    paintF2b();
  }

  // ---- file editor
  const FILE_RE = /^(jail\.local|jail\.conf|fail2ban\.local|fail2ban\.conf|paths-[a-z]+\.conf|(jail\.d|filter\.d|action\.d|fail2ban\.d)\/[A-Za-z0-9_.\-]{1,80}\.(conf|local))$/;
  async function filesSection() {
    const r = await api("/api/defender/f2b/files").catch(() => ({ rows: [] }));
    const rows = table([
      { h: "df_file_path", cls: "strong", cell: (f) => `<code dir="ltr">${esc(f.path)}</code>${f.panel ? '<span class="tag">panel</span>' : ""}` },
      { h: "df_file_size", cell: (f) => num(esc(fmtBytes(f.size))) },
      { h: "df_file_mtime", cell: (f) => esc(ago(f.mtime)) },
      { h: "actions", cell: (f) => `<button type="button" class="btn small" data-a="f2b-file" data-path="${esc(f.path)}">${icon("file")}<span>${esc(t("df_j_edit"))}</span></button>` },
    ], r.rows);
    return `<section class="sec"><div class="sec-head df-head-row"><div><h3>${icon("file")}${esc(t("df_files"))}</h3><p class="muted">${esc(t("df_files_sub"))}</p></div>
      <button type="button" class="btn small" data-a="f2b-file-new">${icon("plus")}<span>${esc(t("df_file_new"))}</span></button></div>
      <details class="df-adv"><summary>${esc(t("df_files"))} (${num(r.rows.length)})</summary>${rows}</details></section>`;
  }
  async function fileEditor(path, isNew = false) {
    const f = isNew ? { path, text: "", exists: false } : await api("/api/defender/f2b/file", { path });
    const dlg = openDialog({
      title: path, submit: t("df_save"), wide: true,
      body: `${f.path.endsWith("zzz-panel.local") ? `<div class="notice warn">${icon("alert")}<span>${esc(t("df_file_panel"))}</span></div>` : ""}
        <textarea name="text" class="df-code" dir="ltr" spellcheck="false" rows="22">${esc(f.text)}</textarea>
        ${f.exists && !/^(jail|fail2ban)\.conf$/.test(f.path) ? `<p><button type="button" class="btn small danger" data-del>${icon("trash")}<span>${esc(t("df_j_delete"))}</span></button></p>` : ""}`,
      onSubmit: async (form) => {
        await post("/api/defender/f2b/file", { path, text: form.elements.text.value });
        toast(t("df_j_saved"));
        if (D.tab === "f2b") showTab("f2b");
      },
    });
    const del = dlg.querySelector("[data-del]");
    if (del) del.addEventListener("click", async () => {
      if (!(await confirmBox({ message: t("df_file_delete_confirm", { path }), label: t("df_j_delete") }))) return;
      if (await act(del, () => post("/api/defender/f2b/file/delete", { path }), t("df_file_deleted"))) { dlg.close(); if (D.tab === "f2b") showTab("f2b"); }
    });
  }
  function newFileDialog() {
    openDialog({
      title: t("df_file_new"), submit: t("df_j_edit"),
      body: field(t("df_file_path"), '<input name="path" dir="ltr" required placeholder="jail.d/my-app.local" autocomplete="off">', t("df_file_path_hint")),
      onSubmit: async (form) => {
        const p = form.elements.path.value.trim().replace(/^\/?etc\/fail2ban\//, "");
        if (!FILE_RE.test(p)) throw new Error(t("df_file_bad"));
        setTimeout(() => fileEditor(p, true), 50);
      },
    });
  }

  // ---- advanced tab
  async function renderAdvanced() {
    const [sec, au] = await Promise.all([api("/api/security").catch(() => ({ ip: "" })), api("/api/defender/audit").catch(() => ({ sysctl_custom: {} }))]);
    D.myIp = sec.ip;
    if (!D.adv) D.adv = JSON.parse(JSON.stringify(D.st.config.advanced));
    D.sysCustom = au.sysctl_custom || {};
    return advancedHTML();
  }
  function advancedHTML() {
    const a = D.adv, c = D.st.config;
    const num_ = (k, label, min = 0) => field(label, `<input type="number" name="${k}" min="${min}" value="${esc(a[k])}" dir="ltr" required>`);
    const sw = (name, on, label, sub) => `<label class="df-switch"><span class="switch"><input type="checkbox" name="${name}" ${on ? "checked" : ""}><span></span></span><span><b>${esc(label)}</b><small>${esc(sub)}</small></span></label>`;
    const chips = a.panel_allow.map((ip, i) => `<span class="chip">${num(esc(ip))}<button type="button" class="chip-x" data-a="adv-pa-del" data-i="${i}" aria-label="${esc(t("df_remove"))} ${esc(ip)}">${icon("x")}</button></span>`).join("");
    const sysRows = Object.entries(D.sysCustom).map(([k, v]) => `<span class="chip"><code dir="ltr">${esc(k)} = ${esc(v)}</code><button type="button" class="chip-x" data-a="adv-sys-del" data-key="${esc(k)}" aria-label="${esc(t("df_remove"))} ${esc(k)}">${icon("x")}</button></span>`).join("");
    const rb = [0, 30, 60, 120, 300, 600];
    return `<section class="sec"><div class="sec-head"><h3>${icon("sliders")}${esc(t("df_adv_title"))}</h3><p class="muted">${esc(t("df_adv_sub"))}</p></div></section>
      <form data-f="adv" class="df-body">
      <section class="sec"><div class="sec-head"><h3>${icon("lock")}${esc(t("df_adv_panel"))}</h3><p class="muted">${esc(t("df_adv_panel_sub"))}</p></div>
        <div class="chips">${chips}</div>
        <div class="inline-field df-inline"><input name="pa_new" dir="ltr" placeholder="203.0.113.7 / 203.0.113.0/24" autocomplete="off" aria-label="${esc(t("df_adv_panel"))}"><button type="button" class="btn small" data-a="adv-pa-add">${icon("plus")}<span>${esc(t("add"))}</span></button>
        ${D.myIp ? `<button type="button" class="btn small" data-a="adv-pa-me">${icon("check")}<span>${esc(t("df_adv_my_ip", { ip: D.myIp }))}</span></button>` : ""}</div></section>
      <section class="sec"><div class="sec-head"><h3>${icon("shield")}${esc(t("df_adv_safety"))}</h3></div><div class="subcard">
        ${field(t("df_adv_rollback"), `<select name="rollback_seconds">${rb.map((s) => `<option value="${s}" ${+a.rollback_seconds === s ? "selected" : ""}>${s ? `${s} s` : esc(t("df_adv_rollback_off"))}</option>`).join("")}</select>`)}
        ${sw("lock_ports", a.lock_ports, t("df_adv_lock"), t("df_adv_lock_sub"))}${sw("trust_docker", a.trust_docker, t("df_adv_docker"), t("df_adv_docker_sub"))}
        ${sw("trust_logged_in", a._logged ?? c.trust_logged_in !== false, t("df_adv_logged"), t("df_adv_logged_sub"))}${sw("trust_cdn", a._cdn ?? c.trust_cdn !== false, t("df_cdn"), t("df_cdn_sub"))}</div></section>
      <section class="sec"><div class="sec-head"><h3>${icon("flame")}${esc(t("df_adv_detect"))}</h3><p class="muted">${esc(t("df_adv_detect_sub"))}</p></div>
        <div class="subcard"><div class="df-form-grid">${num_("detect_drops", t("df_adv_drops"), 1)}${num_("detect_cookies", t("df_adv_cookies"), 1)}${num_("detect_pps", t("df_adv_pps"), 1)}${num_("detect_conntrack", t("df_adv_ct"), 1)}${num_("calm_seconds", t("df_adv_calm"), 5)}${num_("deescalate_minutes", t("df_adv_deesc"))}</div></div></section>
      <section class="sec"><div class="sec-head"><h3>${icon("ban")}${esc(t("df_adv_bans"))}</h3></div>
        <div class="subcard"><div class="df-form-grid">${num_("autoban_factor", t("df_adv_factor"))}${num_("ssh_rate", t("df_adv_ssh_rate"))}${num_("ssh_ban_minutes", t("df_adv_ssh_ban"), 1)}</div></div></section>
      <section class="sec"><div class="sec-head"><h3>${icon("terminal")}${esc(t("df_adv_custom"))}</h3><p class="muted">${esc(t("df_adv_custom_sub"))}</p></div>
        <textarea name="custom_rules" class="df-code" dir="ltr" rows="7" spellcheck="false" placeholder="tcp dport 9000 ip saddr 203.0.113.0/24 accept&#10;udp dport 27015 limit rate over 200/second drop">${esc(a.custom_rules)}</textarea></section>
      <div class="df-actions dirty"><span class="muted"></span><button type="button" class="btn" data-a="rules">${icon("eye")}<span>${esc(t("df_review"))}</span></button>
        <button type="submit" class="btn primary">${icon("check")}<span>${esc(t("df_apply"))}</span></button></div></form>
      <section class="sec"><div class="sec-head"><h3>${icon("gear")}${esc(t("df_adv_sysctl"))}</h3><p class="muted">${esc(t("df_adv_sysctl_sub"))}</p></div>
        <div class="chips">${sysRows}</div>
        <form class="inline-field df-inline" data-f="adv-sys"><input name="key" dir="ltr" placeholder="net.core.somaxconn" required autocomplete="off" aria-label="${esc(t("df_adv_key"))}"><input name="value" dir="ltr" placeholder="65535" required autocomplete="off" aria-label="${esc(t("df_adv_value"))}"><button type="submit" class="btn small">${esc(t("df_adv_set"))}</button></form></section>`;
  }
  const repaintAdv = () => { const b = D.root.querySelector("#df-body"); if (b && D.tab === "advanced") b.innerHTML = advancedHTML(); };
  function advFormToDraft(form) {
    if (!form) return;
    const el = form.elements;
    for (const k of ["rollback_seconds", "detect_drops", "detect_cookies", "detect_pps", "detect_conntrack", "calm_seconds", "deescalate_minutes", "autoban_factor", "ssh_rate", "ssh_ban_minutes"]) D.adv[k] = +el[k].value;
    D.adv.lock_ports = el.lock_ports.checked;
    D.adv.trust_docker = el.trust_docker.checked;
    D.adv.custom_rules = el.custom_rules.value;
    D.adv._logged = el.trust_logged_in.checked;
    D.adv._cdn = el.trust_cdn.checked;
  }

  // ---------------------------------------------------------------- firewall rules (country / address / port → action)
  P.addStrings({
    df_t_rules: "Rules", df_r_title: "Firewall rules",
    df_r_sub: "Decide what happens to new connections by country, address, protocol and port, like the firewall rules of Cloudflare or ArvanCloud. Rules run from top to bottom; the first Allow or Block that matches decides.",
    df_r_exempt: "Logged-in SSH users, the allowlist and Cloudflare (when trusted) are never affected by these rules.", df_r_off: "Protection is off, so the rules are saved but not active. Turn it on in the Overview tab.",
    df_r_new: "New rule", df_r_templates: "Start from a template", df_r_empty: "No rules yet. Pick a template above or create a rule.",
    df_r_tpl_block: "Block countries", df_r_tpl_only: "Allow only some countries", df_r_tpl_strict: "Strict limit for countries", df_r_tpl_allow: "Always allow an address", df_r_tpl_port: "Close a port to everyone else",
    df_r_name: "Rule name", df_r_when: "When the connection…", df_r_then: "Then", df_r_country: "Comes from", df_r_addr: "Comes from the address", df_r_proto: "Uses the protocol", df_r_ports: "Goes to ports",
    df_r_any_country: "any country", df_r_in: "one of these", df_r_not_in: "none of these", df_r_any_addr: "any address", df_r_any_proto: "any protocol", df_r_ping: "Ping (ICMP)",
    df_r_ports_hint: "For example 22 or 80,443 or 8000-8100. Empty = every port.", df_r_ips_hint: "One address or network per line (203.0.113.7, 203.0.113.0/24, 2001:db8::/32).",
    df_r_search: "Search countries…", df_r_selected: "{n} selected",
    df_r_a_allow: "Allow", df_r_a_block: "Block", df_r_a_limit: "Limit", df_r_a_log: "Count only",
    df_r_a_allow_d: "Always let it through, past the flood limits and strict mode.", df_r_a_block_d: "Drop it. The sender gets no answer.",
    df_r_a_limit_d: "Allow, but each address may only open a few new connections per second.", df_r_a_log_d: "Do nothing, only count the matching traffic (to test a rule first).",
    df_r_sens: "Sensitivity", df_r_s_low: "Low", df_r_s_medium: "Medium", df_r_s_high: "High", df_r_s_vhigh: "Very high", df_r_s_custom: "Custom",
    df_r_per_s: "new connections per second per address", df_r_burst: "Short bursts up to", df_r_ban: "Ban addresses that go over it", df_r_ban_no: "No, only slow them down",
    df_r_need_cond: "Pick at least one condition (country, address, protocol or port).", df_r_need_country: "Pick at least one country.", df_r_need_ip: "Enter at least one address.",
    df_r_hits: "{n} packets", df_r_hits_none: "no matches yet", df_r_up: "Move up", df_r_down: "Move down", df_r_dup: "Duplicate", df_r_delete_confirm: "Delete the rule \"{name}\"?", df_r_copy: "copy",
    df_r_if: "If", df_r_and: "and", df_r_country_is: "country is {list}", df_r_country_not: "country is not {list}", df_r_addr_is: "address is {list}", df_r_addr_not: "address is not {list}",
    df_r_proto_is: "protocol is {p}", df_r_ports_is: "port is {list}", df_r_arrow: "→", df_r_limit_sum: "limit to {rate}/s per address", df_r_ban_sum: "ban for {m} min",
    df_r_saved: "Rules applied", df_r_disabled: "Off",
    df_r_dir: "Direction", df_r_dir_in: "Incoming connections (to this server)", df_r_dir_out: "Outgoing connections (from this server, its containers and VPN users)",
    df_r_to_country: "Goes to country", df_r_to_addr: "Goes to address", df_r_out_badge: "outgoing", df_r_out_sum: "Outgoing:",
    df_r_when_active: "Active", df_r_always: "Always", df_r_sched: "Only at these times", df_r_days: "Days", df_r_sched_bad: "Pick at least one day and two different times.", df_r_from: "From", df_r_to: "To",
    df_r_tz: "Server time (UTC), now {now}.", df_r_expires: "Remove after", df_r_never: "Never (permanent)", df_r_exp_in: "ends in {left}", df_r_expired: "ended",
    df_r_sched_sum: "{days} {from}–{to}", df_r_every_day: "every day",
    df_r_tpl_mail: "Block outgoing mail (spam)", df_r_tpl_temp: "Block an address for 24 hours",
  }, {
    df_t_rules: "قوانین", df_r_title: "قوانین فایروال",
    df_r_sub: "تعیین کنید با اتصال‌های جدید بر اساس کشور، آدرس، پروتکل و پورت چه شود؛ مثل قوانین فایروال Cloudflare یا ابر آروان. قوانین از بالا به پایین اجرا می‌شوند و اولین «اجازه» یا «مسدود» که بخورد تصمیم می‌گیرد.",
    df_r_exempt: "کاربرهای واردشده با SSH، لیست سفید و Cloudflare (اگر مورد اعتماد باشد) هرگز تحت تأثیر این قوانین نیستند.", df_r_off: "محافظت خاموش است؛ قوانین ذخیره می‌شوند ولی فعال نیستند. از تب نمای کلی روشنش کنید.",
    df_r_new: "قانون جدید", df_r_templates: "شروع از یک الگو", df_r_empty: "هنوز قانونی نیست. یک الگو از بالا انتخاب کنید یا قانون جدید بسازید.",
    df_r_tpl_block: "مسدود کردن کشورها", df_r_tpl_only: "فقط چند کشور وصل شوند", df_r_tpl_strict: "محدودیت سخت برای کشورها", df_r_tpl_allow: "همیشه اجازه به یک آدرس", df_r_tpl_port: "بستن یک پورت برای بقیه",
    df_r_name: "نام قانون", df_r_when: "وقتی اتصال…", df_r_then: "آن‌وقت", df_r_country: "از کشور", df_r_addr: "از آدرس", df_r_proto: "با پروتکل", df_r_ports: "به پورت",
    df_r_any_country: "هر کشوری", df_r_in: "یکی از این‌ها", df_r_not_in: "هیچ‌کدام از این‌ها", df_r_any_addr: "هر آدرسی", df_r_any_proto: "هر پروتکلی", df_r_ping: "پینگ (ICMP)",
    df_r_ports_hint: "مثلاً 22 یا 80,443 یا 8000-8100. خالی = همه‌ی پورت‌ها.", df_r_ips_hint: "هر خط یک آدرس یا شبکه (203.0.113.7، 203.0.113.0/24، 2001:db8::/32).",
    df_r_search: "جستجوی کشور…", df_r_selected: "{n} انتخاب‌شده",
    df_r_a_allow: "اجازه", df_r_a_block: "مسدود", df_r_a_limit: "محدود", df_r_a_log: "فقط شمارش",
    df_r_a_allow_d: "همیشه رد شود، حتی از محدودیت‌های فلاد و حالت سخت‌گیر.", df_r_a_block_d: "دور ریخته شود. فرستنده هیچ جوابی نمی‌گیرد.",
    df_r_a_limit_d: "اجازه، ولی هر آدرس فقط چند اتصال جدید در ثانیه.", df_r_a_log_d: "کاری نکن، فقط ترافیک منطبق را بشمار (برای آزمایش یک قانون).",
    df_r_sens: "حساسیت", df_r_s_low: "کم", df_r_s_medium: "متوسط", df_r_s_high: "زیاد", df_r_s_vhigh: "خیلی زیاد", df_r_s_custom: "دلخواه",
    df_r_per_s: "اتصال جدید در ثانیه برای هر آدرس", df_r_burst: "جهش کوتاه تا", df_r_ban: "آدرس‌هایی که از آن رد شوند مسدود شوند", df_r_ban_no: "نه، فقط کندشان کن",
    df_r_need_cond: "حداقل یک شرط (کشور، آدرس، پروتکل یا پورت) انتخاب کنید.", df_r_need_country: "حداقل یک کشور انتخاب کنید.", df_r_need_ip: "حداقل یک آدرس وارد کنید.",
    df_r_hits: "{n} بسته", df_r_hits_none: "هنوز منطبقی نبوده", df_r_up: "بالاتر", df_r_down: "پایین‌تر", df_r_dup: "کپی", df_r_delete_confirm: "قانون «{name}» حذف شود؟", df_r_copy: "کپی",
    df_r_if: "اگر", df_r_and: "و", df_r_country_is: "کشور {list} باشد", df_r_country_not: "کشور {list} نباشد", df_r_addr_is: "آدرس {list} باشد", df_r_addr_not: "آدرس {list} نباشد",
    df_r_proto_is: "پروتکل {p} باشد", df_r_ports_is: "پورت {list} باشد", df_r_arrow: "←", df_r_limit_sum: "محدود به {rate} در ثانیه برای هر آدرس", df_r_ban_sum: "مسدودی {m} دقیقه",
    df_r_saved: "قوانین اعمال شد", df_r_disabled: "خاموش",
    df_r_dir: "جهت", df_r_dir_in: "اتصال‌های ورودی (به این سرور)", df_r_dir_out: "اتصال‌های خروجی (از این سرور، کانتینرها و کاربران VPN)",
    df_r_to_country: "به کشور", df_r_to_addr: "به آدرس", df_r_out_badge: "خروجی", df_r_out_sum: "خروجی:",
    df_r_when_active: "فعال بودن", df_r_always: "همیشه", df_r_sched: "فقط در این زمان‌ها", df_r_days: "روزها", df_r_sched_bad: "دست‌کم یک روز و دو ساعت متفاوت انتخاب کنید.", df_r_from: "از", df_r_to: "تا",
    df_r_tz: "به وقت سرور (UTC)، الان {now}.", df_r_expires: "حذف خودکار بعد از", df_r_never: "هرگز (دائمی)", df_r_exp_in: "{left} مانده", df_r_expired: "تمام شده",
    df_r_sched_sum: "{days} {from}–{to}", df_r_every_day: "هر روز",
    df_r_tpl_mail: "مسدود کردن ایمیل خروجی (اسپم)", df_r_tpl_temp: "مسدود کردن یک آدرس برای ۲۴ ساعت",
  });
  P.addIcons({ rule: '<path d="M4 5h16l-6 7.5V19l-4 1.5v-8L4 5z"/>', up: '<path d="m6 15 6-6 6 6"/>', down2: '<path d="m6 9 6 6 6-6"/>', dup: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V5a1 1 0 0 0-1-1H5a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h3"/>' });

  const SENS = { low: [100, 200], medium: [30, 60], high: [10, 20], vhigh: [3, 6] };
  const sensOf = (L) => Object.keys(SENS).find((k) => SENS[k][0] === L.rate && SENS[k][1] === L.burst) || "custom";
  const newId = () => Array.from(crypto.getRandomValues(new Uint8Array(3)), (b) => b.toString(16).padStart(2, "0")).join("");
  const blankRule = (over = {}) => ({ id: newId(), name: "", enabled: true, direction: "in", countries: [], country_mode: "in", ips: [], ip_mode: "in", proto: "any", ports: "", action: "block",
    limit: { rate: 10, burst: 20, ban: 0 }, schedule: null, expires: 0, ...over });
  const TEMPLATES = {
    block: () => blankRule({ name: t("df_r_tpl_block"), action: "block", _c: true }),
    only: () => blankRule({ name: t("df_r_tpl_only"), country_mode: "not_in", action: "block", _c: true }),
    strict: () => blankRule({ name: t("df_r_tpl_strict"), action: "limit", limit: { rate: 3, burst: 6, ban: 60 }, _c: true }),
    allow: () => blankRule({ name: t("df_r_tpl_allow"), action: "allow", _a: true }),
    port: () => blankRule({ name: t("df_r_tpl_port"), ip_mode: "not_in", proto: "tcp", action: "block", _a: true }),
    mail: () => blankRule({ name: t("df_r_tpl_mail"), direction: "out", proto: "tcp", ports: "25,465,587", action: "block" }),
    temp: () => blankRule({ name: t("df_r_tpl_temp"), action: "block", _a: true, expires: Math.floor(Date.now() / 1000) + 86400 }),
  };

  const shortList = (items, f = (x) => x) => (items.length > 3 ? `${items.slice(0, 3).map(f).join("، ")} +${items.length - 3}` : items.map(f).join("، "));
  function summary(r) {
    const c = [];
    if (r.countries.length) c.push(t(r.country_mode === "not_in" ? "df_r_country_not" : "df_r_country_is", { list: shortList(r.countries, ccName) }));
    if (r.ips.length) c.push(t(r.ip_mode === "not_in" ? "df_r_addr_not" : "df_r_addr_is", { list: shortList(r.ips) }));
    if (r.proto !== "any") c.push(t("df_r_proto_is", { p: r.proto === "icmp" ? t("df_r_ping") : r.proto.toUpperCase() }));
    if (r.ports) c.push(t("df_r_ports_is", { list: r.ports.replace(/,/g, "، ") }));
    let act = t(`df_r_a_${r.action}`);
    if (r.action === "limit") act = t("df_r_limit_sum", { rate: r.limit.rate }) + (r.limit.ban ? ` · ${t("df_r_ban_sum", { m: r.limit.ban })}` : "");
    let sum = `${r.direction === "out" ? `${t("df_r_out_sum")} ` : ""}${t("df_r_if")} ${c.join(` ${t("df_r_and")} `)} ${t("df_r_arrow")} ${act}`;
    if (r.schedule) sum += ` · ⏰ ${schedText(r.schedule)}`;
    return sum;
  }
  const dayName = (d) => { try { return new Intl.DateTimeFormat(P.state.lang === "fa" ? "fa" : "en", { weekday: "short" }).format(new Date(Date.UTC(2024, 0, 7 + d, 12))); } catch (e) { return String(d); } };
  const schedText = (sc) => t("df_r_sched_sum", { days: sc.days.length === 7 ? t("df_r_every_day") : sc.days.map(dayName).join("، "), from: sc.from, to: sc.to });
  const leftText = (ts) => { const s = ts - Date.now() / 1000; return s <= 0 ? t("df_r_expired") : t("df_r_exp_in", { left: s > 86400 ? `${nf(s / 86400, 1)}d` : s > 3600 ? `${nf(s / 3600, 1)}h` : `${Math.ceil(s / 60)}m` }); };
  const ACT_TONE = { allow: "ok", block: "bad", limit: "warn", log: "" };

  async function renderRules() {
    const r = await api("/api/defender/fwrules");
    D.rules = r.rules;
    D.ruleHits = r.hits || {};
    return rulesHTML();
  }
  function rulesHTML() {
    const tpl = Object.keys(TEMPLATES).map((k) => `<button type="button" class="btn small" data-a="r-tpl" data-tpl="${k}">${icon("plus")}<span>${esc(t(`df_r_tpl_${k}`))}</span></button>`).join("");
    const list = D.rules.length ? `<ol class="fw-rules">${D.rules.map((r, i) => {
      const hits = D.ruleHits[r.id];
      return `<li class="fw-rule${r.enabled ? "" : " off"}"><span class="fw-n">${num(i + 1)}</span>
        <div class="fw-main"><div class="fw-top"><b>${esc(r.name)}</b>${pill(ACT_TONE[r.action], t(`df_r_a_${r.action}`))}${r.direction === "out" ? `<span class="tag">↗ ${esc(t("df_r_out_badge"))}</span>` : ""}${r.expires ? `<span class="tag">⌛ ${esc(leftText(r.expires))}</span>` : ""}${r.enabled ? "" : pill("", t("df_r_disabled"), false)}</div>
          <p class="fw-sum">${esc(summary(r))}</p>
          <small class="muted">${hits && hits.packets ? esc(t("df_r_hits", { n: nf(hits.packets, 0) })) : esc(t("df_r_hits_none"))}</small></div>
        <div class="fw-act"><label class="switch" title="${esc(r.enabled ? t("df_f2b_on") : t("df_f2b_off"))}"><input type="checkbox" data-rule-toggle="${i}" ${r.enabled ? "checked" : ""} aria-label="${esc(r.name)}"><span></span></label>
          <div class="row-actions">${btnIcon("up", t("df_r_up"), `data-a="r-move" data-i="${i}" data-d="-1" ${i ? "" : "disabled"}`)}${btnIcon("down2", t("df_r_down"), `data-a="r-move" data-i="${i}" data-d="1" ${i < D.rules.length - 1 ? "" : "disabled"}`)}
          ${btnIcon("sliders", t("df_j_edit"), `data-a="r-edit" data-i="${i}"`)}${btnIcon("dup", t("df_r_dup"), `data-a="r-dup" data-i="${i}"`)}${btnIcon("trash", t("df_j_delete"), `data-a="r-del" data-i="${i}"`, "danger")}</div></div></li>`;
    }).join("")}</ol>` : `<div class="empty">${esc(t("df_r_empty"))}</div>`;
    return `<section class="sec"><div class="sec-head df-head-row"><div><h3>${icon("rule")}${esc(t("df_r_title"))}</h3><p class="muted">${esc(t("df_r_sub"))}</p></div>
        <button type="button" class="btn primary" data-a="r-new">${icon("plus")}<span>${esc(t("df_r_new"))}</span></button></div>
        <div class="notice">${icon("shield")}<span>${esc(t("df_r_exempt"))}</span></div>
        ${D.st.enabled ? "" : `<div class="notice warn">${icon("bell")}<span>${esc(t("df_r_off"))}</span></div>`}
        <h4 class="df-h4">${esc(t("df_r_templates"))}</h4><div class="row-actions fw-tpls">${tpl}</div></section>
      <section class="sec">${list}</section>`;
  }
  const repaintRules = () => { const b = D.root.querySelector("#df-body"); if (b && D.tab === "rules") b.innerHTML = rulesHTML(); };

  async function saveRules(btn, rules) {
    const ok = await apply(btn, "config", { rules, _what: "rules" }, t("df_r_saved"));
    if (ok) { D.rules = rules; if (D.tab === "rules") showTab("rules"); }
    return ok;
  }

  function ruleEditor(rule, index) {
    const r = JSON.parse(JSON.stringify(rule));
    const isNew = index == null;
    let picked = new Set(r.countries);
    const cmode = r.countries.length || r._c ? r.country_mode : "any";
    const amode = r.ips.length || r._a ? r.ip_mode : "any";
    delete r._c;
    delete r._a;
    const sens = sensOf(r.limit);
    const actCard = (a) => `<label class="fw-actopt ${a}"><input type="radio" name="action" value="${a}" ${r.action === a ? "checked" : ""}><span><b>${esc(t(`df_r_a_${a}`))}</b><small>${esc(t(`df_r_a_${a}_d`))}</small></span></label>`;
    const sensBtns = ["low", "medium", "high", "vhigh", "custom"].map((k) => `<label class="fw-sens"><input type="radio" name="sens" value="${k}" ${sens === k ? "checked" : ""}><span>${esc(t(`df_r_s_${k}`))}${SENS[k] ? `<small>${SENS[k][0]}/s</small>` : ""}</span></label>`).join("");
    const dlg = openDialog({
      title: isNew ? t("df_r_new") : `${r.name} · ${t("df_j_edit")}`, submit: t("df_save"), wide: true,
      body: `${field(t("df_r_name"), `<input name="name" maxlength="80" value="${esc(r.name)}" required autocomplete="off">`)}
        ${field(t("df_r_dir"), `<select name="direction"><option value="in">${esc(t("df_r_dir_in"))}</option><option value="out" ${r.direction === "out" ? "selected" : ""}>${esc(t("df_r_dir_out"))}</option></select>`)}
        <h4 class="fw-h">${esc(t("df_r_when"))}</h4>
        <div class="fw-cond"><div class="field-row">${field(t("df_r_country"), `<select name="cmode"><option value="any">${esc(t("df_r_any_country"))}</option><option value="in" ${cmode === "in" ? "selected" : ""}>${esc(t("df_r_in"))}</option><option value="not_in" ${cmode === "not_in" ? "selected" : ""}>${esc(t("df_r_not_in"))}</option></select>`)}
          <div class="field fw-cc-count"><label>&nbsp;</label><span class="muted" data-cc-count></span></div></div>
          <div class="fw-cc" ${cmode === "any" ? "hidden" : ""}><div class="chips" data-cc-chips></div>
            <input type="search" class="df-filter" data-cc-q placeholder="${esc(t("df_r_search"))}" aria-label="${esc(t("df_r_search"))}"><div class="geo-grid fw-cc-list" data-cc-list></div></div></div>
        <div class="fw-cond">${field(t("df_r_addr"), `<select name="amode"><option value="any">${esc(t("df_r_any_addr"))}</option><option value="in" ${amode === "in" ? "selected" : ""}>${esc(t("df_r_in"))}</option><option value="not_in" ${amode === "not_in" ? "selected" : ""}>${esc(t("df_r_not_in"))}</option></select>`)}
          <div class="fw-ips" ${amode === "any" ? "hidden" : ""}>${field("", `<textarea name="ips" dir="ltr" rows="3" spellcheck="false" placeholder="203.0.113.7&#10;198.51.100.0/24">${esc(r.ips.join("\n"))}</textarea>`, t("df_r_ips_hint"))}</div></div>
        <div class="fw-cond field-row">${field(t("df_r_proto"), `<select name="proto">${[["any", t("df_r_any_proto")], ["tcp", "TCP"], ["udp", "UDP"], ["icmp", t("df_r_ping")]].map(([v, l]) => `<option value="${v}" ${r.proto === v ? "selected" : ""}>${esc(l)}</option>`).join("")}</select>`)}
          ${field(t("df_r_ports"), `<input name="ports" dir="ltr" value="${esc(r.ports)}" placeholder="22, 80,443, 8000-8100" autocomplete="off">`, t("df_r_ports_hint"))}</div>
        <div class="fw-cond"><div class="field-row">${field(t("df_r_when_active"), `<select name="smode"><option value="always">${esc(t("df_r_always"))}</option><option value="sched" ${r.schedule ? "selected" : ""}>${esc(t("df_r_sched"))}</option></select>`)}
          ${field(t("df_r_expires"), `<select name="expires"><option value="0">${esc(t("df_r_never"))}</option>${[[3600, "1 h"], [21600, "6 h"], [86400, "24 h"], [259200, "3 d"], [604800, "7 d"]].map(([v, l]) => `<option value="+${v}">${l}</option>`).join("")}${r.expires ? `<option value="${r.expires}" selected>${esc(leftText(r.expires))}</option>` : ""}</select>`)}</div>
          <div class="fw-sched" ${r.schedule ? "" : "hidden"}><label class="fw-lbl">${esc(t("df_r_days"))}</label><div class="fw-days">${[0, 1, 2, 3, 4, 5, 6].map((d) => `<label class="fw-sens"><input type="checkbox" name="day" value="${d}" ${!r.schedule || r.schedule.days.includes(d) ? "checked" : ""}><span>${esc(dayName(d))}</span></label>`).join("")}</div>
            <div class="field-row">${field(t("df_r_from"), `<input type="time" name="tfrom" value="${esc(r.schedule ? r.schedule.from : "09:00")}" dir="ltr">`)}${field(t("df_r_to"), `<input type="time" name="tto" value="${esc(r.schedule ? r.schedule.to : "17:00")}" dir="ltr">`)}</div>
            <p class="hint">${esc(t("df_r_tz", { now: new Date().toISOString().slice(11, 16) }))}</p></div></div>
        <h4 class="fw-h">${esc(t("df_r_then"))}</h4><div class="fw-actions">${["allow", "block", "limit", "log"].map(actCard).join("")}</div>
        <div class="fw-limit" ${r.action === "limit" ? "" : "hidden"}><label class="fw-lbl">${esc(t("df_r_sens"))}</label><div class="fw-sensrow">${sensBtns}</div>
          <div class="field-row fw-custom" ${sens === "custom" ? "" : "hidden"}>${field(t("df_r_per_s"), `<input type="number" name="rate" min="1" value="${r.limit.rate}" dir="ltr">`)}${field(t("df_r_burst"), `<input type="number" name="burst" min="1" value="${r.limit.burst}" dir="ltr">`)}</div>
          ${field(t("df_r_ban"), `<select name="ban">${[[0, t("df_r_ban_no")], [10, "10 min"], [60, "1 h"], [360, "6 h"], [1440, "1 d"], [10080, "1 w"]].map(([v, l]) => `<option value="${v}" ${+r.limit.ban === v ? "selected" : ""}>${esc(l)}</option>`).join("")}</select>`)}</div>
        <p class="fw-preview" data-preview></p>`,
      onSubmit: async () => {
        const out = collect();
        if (!out.countries.length && !out.ips.length && out.proto === "any" && !out.ports) throw new Error(t("df_r_need_cond"));
        if (dlg.querySelector('[name="cmode"]').value !== "any" && !out.countries.length) throw new Error(t("df_r_need_country"));
        if (dlg.querySelector('[name="amode"]').value !== "any" && !out.ips.length) throw new Error(t("df_r_need_ip"));
        if (out.schedule && (!out.schedule.days.length || out.schedule.from === out.schedule.to)) throw new Error(t("df_r_sched_bad"));
        const rules = [...D.rules];
        if (isNew) rules.push(out); else rules[index] = out;
        if (!(await saveRules(null, rules))) throw new Error("");   // the reason is already shown as a message
      },
    });
    const $q = (s) => dlg.querySelector(s);
    function collect() {
      const el = $q("form").elements;
      const cm = el.cmode.value, am = el.amode.value, sens = el.sens.value;
      const lim = sens === "custom" ? { rate: +el.rate.value || 1, burst: +el.burst.value || (+el.rate.value || 1) * 2 } : { rate: SENS[sens][0], burst: SENS[sens][1] };
      const dayVals = [...$q("form").querySelectorAll('input[name="day"]:checked')].map((x) => +x.value);
      const exp = el.expires.value.startsWith("+") ? Math.floor(Date.now() / 1000) + +el.expires.value.slice(1) : +el.expires.value;
      return {
        ...r, name: el.name.value.trim() || t("df_r_new"), direction: el.direction.value,
        schedule: el.smode.value === "sched" ? { days: dayVals, from: el.tfrom.value || "00:00", to: el.tto.value || "23:59" } : null, expires: exp,
        countries: cm === "any" ? [] : [...picked], country_mode: cm === "not_in" ? "not_in" : "in",
        ips: am === "any" ? [] : el.ips.value.split(/[\s,]+/).map((x) => x.trim()).filter(Boolean), ip_mode: am === "not_in" ? "not_in" : "in",
        proto: el.proto.value, ports: el.proto.value === "icmp" ? "" : el.ports.value.replace(/\s+/g, ""),
        action: el.action.value, limit: { ...lim, ban: +el.ban.value },
      };
    }
    function paintCountries() {
      const q = ($q("[data-cc-q]").value || "").trim().toLowerCase();
      $q("[data-cc-chips]").innerHTML = [...picked].map((cc) => `<span class="chip">${flag(cc)} <b>${esc(ccName(cc))}</b><button type="button" class="chip-x" data-cc-del="${cc}" aria-label="${esc(t("df_remove"))} ${esc(ccName(cc))}">${icon("x")}</button></span>`).join("");
      $q("[data-cc-count]").textContent = picked.size ? t("df_r_selected", { n: picked.size }) : "";
      $q("[data-cc-list]").innerHTML = COUNTRIES.map((cc) => [cc, ccName(cc)]).filter(([cc, n]) => !q || cc.includes(q) || n.toLowerCase().includes(q) || ccEnglish(cc).toLowerCase().includes(q))
        .sort((a, b) => a[1].localeCompare(b[1], P.state.lang))
        .map(([cc, n]) => `<label class="geo-item${picked.has(cc) ? " on" : ""}"><input type="checkbox" data-cc="${cc}" ${picked.has(cc) ? "checked" : ""}><span class="geo-flag">${flag(cc)}</span><span>${esc(n)}</span><code>${cc.toUpperCase()}</code></label>`).join("");
    }
    function sync() {
      const el = $q("form").elements;
      $q(".fw-cc").hidden = el.cmode.value === "any";
      $q(".fw-ips").hidden = el.amode.value === "any";
      el.ports.disabled = el.proto.value === "icmp";
      const out = el.direction.value === "out";
      $q(".fw-sched").hidden = el.smode.value !== "sched";
      dlg.querySelector('.fw-actopt.limit').hidden = out;
      if (out && el.action.value === "limit") dlg.querySelector('input[name="action"][value="block"]').checked = true;
      dlg.querySelectorAll(".fw-cond")[0].querySelector("label").textContent = t(out ? "df_r_to_country" : "df_r_country");
      dlg.querySelectorAll(".fw-cond")[1].querySelector("label").textContent = t(out ? "df_r_to_addr" : "df_r_addr");
      $q(".fw-limit").hidden = el.action.value !== "limit";
      $q(".fw-custom").hidden = el.sens.value !== "custom";
      const preview = collect();
      $q("[data-preview]").textContent = preview.countries.length || preview.ips.length || preview.proto !== "any" || preview.ports ? summary(preview) : "";
    }
    $q("form").addEventListener("change", (e) => {
      if (e.target.dataset.cc) { if (e.target.checked) picked.add(e.target.dataset.cc); else picked.delete(e.target.dataset.cc); paintCountries(); }
      sync();
    });
    $q("form").addEventListener("input", (e) => { if (e.target.matches("[data-cc-q]")) paintCountries(); else if (["ips", "ports", "rate", "tfrom", "tto"].includes(e.target.name)) sync(); });
    $q("form").addEventListener("click", (e) => { const x = e.target.closest("[data-cc-del]"); if (x) { e.preventDefault(); picked.delete(x.dataset.ccDel); paintCountries(); sync(); } });
    paintCountries();
    sync();
  }

  // ---------------------------------------------------------------- SSH server, address tester, threat lists
  P.addStrings({
    df_sv_title: "SSH server", df_sv_sub: "Port, login options and keys of the SSH server itself. Every change is tested: if SSH does not answer on every port, the old settings come back at once; otherwise you have {m} minutes to log in again and keep it, or it is undone by itself. Open sessions stay connected.",
    df_sv_ports: "SSH ports", df_sv_ports_hint: "During a move keep both ports: add the new one, keep the change after you logged in through it, then remove the old one.",
    df_sv_add_port: "Add port", df_sv_root: "Root login", df_sv_root_yes: "Allowed (password or key)", df_sv_root_key: "Only with a key", df_sv_root_no: "Not allowed",
    df_sv_password: "Password login", df_sv_password_sub: "Off: only SSH keys work. Much safer; add your key below first.", df_sv_tries: "Wrong passwords per connection", df_sv_grace: "Seconds to log in",
    df_sv_idle: "Disconnect idle sessions after", df_sv_idle_never: "Never", df_sv_x11: "X11 forwarding", df_sv_tcpfwd: "TCP forwarding (tunnels)", df_sv_save: "Apply to SSH",
    df_sv_confirm: "Apply these SSH settings? SSH restarts (this session stays open). Ports: {ports}. If your hosting provider has its own firewall (for example the Hetzner Cloud Firewall), allow the new port there too.",
    df_sv_pending: "Log in again now with the new settings, for example: {cmd}. If it works press Keep; otherwise they are undone in {left}.", df_sv_kept: "SSH settings kept", df_sv_undone: "SSH settings undone",
    df_sv_applied: "Applied. SSH answers on every port; now test a new login.", df_sv_socket: "systemd socket", df_sv_last_port: "SSH needs at least one port",
    df_sv_keys: "SSH keys of root", df_sv_keys_sub: "Public keys that may log in as root (/root/.ssh/authorized_keys).", df_sv_key_add: "Add key", df_sv_key_ph: "ssh-ed25519 AAAA… you@laptop",
    df_sv_key_hint: "Paste the content of your id_ed25519.pub (or id_rsa.pub). On your computer: ssh-keygen -t ed25519 creates one.", df_sv_key_del: "Remove key {name}?", df_sv_no_keys: "No key yet: only passwords work.",
    df_sv_type: "Type", df_sv_comment: "Name", df_sv_fp: "Fingerprint",
    df_tt_title: "Check an address", df_tt_sub: "What happens to a connection from this address, step by step through every layer of the firewall.",
    df_tt_ip: "Address", df_tt_port: "Port (optional)", df_tt_check: "Check", df_tt_country: "Country: {c}", df_tt_country_unknown: "Country: unknown (no list downloaded for it)",
    df_tt_allow: "Allowed", df_tt_block: "Blocked", df_tt_limit: "Limited",
    df_tt_off: "Protection is off: everything is allowed.", df_tt_admin: "Trusted: it logged in over SSH.", df_tt_allowlist: "On the allowlist ({entry}).", df_tt_blocklist: "On the blocklist ({entry}).",
    df_tt_banned: "Banned by the firewall, {left} left.", df_tt_fail2ban: "Banned by fail2ban ({jail}).", df_tt_panel_allow: "Only the listed addresses may open the panel.", df_tt_cdn: "A Cloudflare address (trusted).",
    df_tt_threat: "Listed in: {feeds}.", df_tt_rule_allow: "Rule \"{name}\": allow.", df_tt_rule_block: "Rule \"{name}\": block.", df_tt_rule_limit: "Rule \"{name}\": limited to {rate}/s.", df_tt_rule_count: "Rule \"{name}\": counted.",
    df_tt_strict: "Strict mode: port {port} is not open.", df_tt_limits: "Allowed, within the flood limits ({syn} SYN/s, {conc} connections).", df_tt_sched: " (only at its scheduled times)",
  }, {
    df_sv_title: "سرور SSH", df_sv_sub: "پورت، گزینه‌های ورود و کلیدهای خود سرور SSH. هر تغییر آزمایش می‌شود: اگر SSH روی همه‌ی پورت‌ها جواب ندهد، تنظیمات قبلی فوراً برمی‌گردد؛ وگرنه {m} دقیقه وقت دارید دوباره وارد شوید و آن را نگه دارید، وگرنه خودش برمی‌گردد. نشست‌های باز وصل می‌مانند.",
    df_sv_ports: "پورت‌های SSH", df_sv_ports_hint: "هنگام جابه‌جایی هر دو پورت را نگه دارید: پورت جدید را اضافه کنید، بعد از ورود موفق با آن تغییر را نگه دارید، و بعد پورت قدیمی را حذف کنید.",
    df_sv_add_port: "افزودن پورت", df_sv_root: "ورود root", df_sv_root_yes: "مجاز (با رمز یا کلید)", df_sv_root_key: "فقط با کلید", df_sv_root_no: "ممنوع",
    df_sv_password: "ورود با رمز", df_sv_password_sub: "خاموش: فقط کلید SSH کار می‌کند. خیلی امن‌تر؛ اول کلیدتان را پایین اضافه کنید.", df_sv_tries: "رمز اشتباه در هر اتصال", df_sv_grace: "ثانیه برای ورود",
    df_sv_idle: "قطع نشست بی‌کار بعد از", df_sv_idle_never: "هرگز", df_sv_x11: "X11 forwarding", df_sv_tcpfwd: "TCP forwarding (تانل)", df_sv_save: "اعمال روی SSH",
    df_sv_confirm: "این تنظیمات روی SSH اعمال شود؟ SSH ری‌استارت می‌شود (این نشست باز می‌ماند). پورت‌ها: {ports}. اگر هاستینگ شما فایروال جدا دارد (مثل Hetzner Cloud Firewall)، پورت جدید را آن‌جا هم باز کنید.",
    df_sv_pending: "همین حالا با تنظیمات جدید دوباره وارد شوید، مثلاً: {cmd}. اگر کار کرد «نگه دار» را بزنید؛ وگرنه {left} دیگر خودش برمی‌گردد.", df_sv_kept: "تنظیمات SSH ماند", df_sv_undone: "تنظیمات SSH برگشت",
    df_sv_applied: "اعمال شد. SSH روی همه‌ی پورت‌ها جواب می‌دهد؛ حالا یک ورود جدید را امتحان کنید.", df_sv_socket: "systemd socket", df_sv_last_port: "SSH حداقل یک پورت لازم دارد",
    df_sv_keys: "کلیدهای SSH کاربر root", df_sv_keys_sub: "کلیدهای عمومی که می‌توانند با root وارد شوند (/root/.ssh/authorized_keys).", df_sv_key_add: "افزودن کلید", df_sv_key_ph: "ssh-ed25519 AAAA… you@laptop",
    df_sv_key_hint: "محتوای فایل id_ed25519.pub (یا id_rsa.pub) را بچسبانید. روی کامپیوترتان ssh-keygen -t ed25519 یکی می‌سازد.", df_sv_key_del: "کلید {name} حذف شود؟", df_sv_no_keys: "هنوز کلیدی نیست: فقط رمز کار می‌کند.",
    df_sv_type: "نوع", df_sv_comment: "نام", df_sv_fp: "اثر انگشت",
    df_tt_title: "بررسی یک آدرس", df_tt_sub: "با اتصالی از این آدرس چه می‌شود، قدم‌به‌قدم در همه‌ی لایه‌های فایروال.",
    df_tt_ip: "آدرس", df_tt_port: "پورت (اختیاری)", df_tt_check: "بررسی", df_tt_country: "کشور: {c}", df_tt_country_unknown: "کشور: نامعلوم (لیستی برایش دانلود نشده)",
    df_tt_allow: "مجاز", df_tt_block: "مسدود", df_tt_limit: "محدود",
    df_tt_off: "محافظت خاموش است: همه چیز مجاز است.", df_tt_admin: "مورد اعتماد: با SSH وارد شده.", df_tt_allowlist: "در لیست سفید ({entry}).", df_tt_blocklist: "در لیست سیاه ({entry}).",
    df_tt_banned: "توسط فایروال مسدود است، {left} مانده.", df_tt_fail2ban: "توسط fail2ban مسدود است ({jail}).", df_tt_panel_allow: "فقط آدرس‌های مشخص اجازه‌ی باز کردن پنل دارند.", df_tt_cdn: "آدرس Cloudflare (مورد اعتماد).",
    df_tt_threat: "در این لیست‌ها: {feeds}.", df_tt_rule_allow: "قانون «{name}»: اجازه.", df_tt_rule_block: "قانون «{name}»: مسدود.", df_tt_rule_limit: "قانون «{name}»: محدود به {rate} در ثانیه.", df_tt_rule_count: "قانون «{name}»: شمرده می‌شود.",
    df_tt_strict: "حالت سخت‌گیر: پورت {port} باز نیست.", df_tt_limits: "مجاز، در حد محدودیت‌های فلاد ({syn} SYN در ثانیه، {conc} اتصال).", df_tt_sched: " (فقط در زمان‌بندی‌اش)",
  });

  // ---- SSH server
  const portsChips = (ports, removable) => ports.map((p, i) => `<span class="chip">${icon("terminal")}<b>${num(p)}</b>${removable && ports.length > 1 ? `<button type="button" class="chip-x" data-a="sv-port-del" data-i="${i}" aria-label="${esc(t("df_remove"))} ${p}">${icon("x")}</button>` : ""}</span>`).join("");
  const fmtLeft = (s) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
  async function renderSshAll() {
    const sv = await api("/api/defender/sshd").catch((e) => ({ error: e.message }));
    D.sv = sv;
    if (!sv.error && !D.svDraft) D.svDraft = { ports: [...sv.ports], permit_root: sv.permit_root, password: sv.password, max_auth_tries: sv.max_auth_tries, login_grace: sv.login_grace, idle_timeout: sv.idle_timeout, x11: sv.x11, tcp_forwarding: sv.tcp_forwarding };
    return `<div id="df-sv">${svHTML()}</div>` + (await renderSsh());
  }
  function svHTML() {
    const sv = D.sv;
    if (sv.error) return `<div class="notice bad">${icon("alert")}<span>${esc(sv.error)}</span></div>`;
    const d = D.svDraft, ip = ((P.state.overview && P.state.overview.public_ip && P.state.overview.public_ip.v4) || location.hostname);
    const pend = sv.pending ? `<div class="notice warn df-pend">${icon("clock")}<span>${esc(t("df_sv_pending", { cmd: `ssh -p ${sv.pending.ports[sv.pending.ports.length - 1]} root@${ip}`, left: fmtLeft(sv.pending.left) }))}</span>
      <button type="button" class="btn small primary" data-a="sv-keep">${esc(t("df_keep"))}</button><button type="button" class="btn small" data-a="sv-undo">${esc(t("df_undo"))}</button></div>` : "";
    const sel = (name, opts) => `<select name="${name}">${opts.map(([v, l]) => `<option value="${v}" ${String(d[name]) === String(v) ? "selected" : ""}>${esc(l)}</option>`).join("")}</select>`;
    const keys = sv.keys.length ? table([
      { h: "df_sv_type", cell: (k) => `<code dir="ltr">${esc(k.type)}</code>` },
      { h: "df_sv_comment", cls: "strong", cell: (k) => esc(k.comment || "—") },
      { h: "df_sv_fp", cls: "wrap-cell", cell: (k) => `<code dir="ltr" class="muted">${esc(k.fingerprint)}</code>` },
      { h: "actions", cell: (k) => btnIcon("trash", `${t("df_remove")} ${k.comment}`, `data-a="sv-key-del" data-i="${k.index}" data-name="${esc(k.comment || k.type)}"`, "danger") },
    ], sv.keys) : `<div class="empty">${esc(t("df_sv_no_keys"))}</div>`;
    return `${pend}<section class="sec"><div class="sec-head"><h3>${icon("terminal")}${esc(t("df_sv_title"))}${sv.socket ? `<span class="tag">${esc(t("df_sv_socket"))}</span>` : ""}</h3><p class="muted">${esc(t("df_sv_sub", { m: Math.round(D.sv.confirm_seconds / 60) }))}</p></div>
      <form class="subcard" data-f="sv">
        <div class="field"><label>${esc(t("df_sv_ports"))}</label><div class="chips">${portsChips(d.ports, true)}</div>
          <div class="inline-field df-inline"><input name="newport" type="number" min="1" max="65535" dir="ltr" placeholder="2222" aria-label="${esc(t("df_sv_add_port"))}"><button type="button" class="btn small" data-a="sv-port-add">${icon("plus")}<span>${esc(t("df_sv_add_port"))}</span></button></div>
          <p class="hint">${esc(t("df_sv_ports_hint"))}</p></div>
        <div class="df-form-grid">
          ${field(t("df_sv_root"), sel("permit_root", [["yes", t("df_sv_root_yes")], ["prohibit-password", t("df_sv_root_key")], ["no", t("df_sv_root_no")]]))}
          ${field(t("df_sv_tries"), `<input type="number" name="max_auth_tries" min="1" max="50" value="${esc(d.max_auth_tries)}" dir="ltr">`)}
          ${field(t("df_sv_grace"), `<input type="number" name="login_grace" min="5" max="600" value="${esc(d.login_grace)}" dir="ltr">`)}
          ${field(t("df_sv_idle"), sel("idle_timeout", [[0, t("df_sv_idle_never")], [300, "5 min"], [900, "15 min"], [1800, "30 min"], [3600, "1 h"]].concat([[0, 300, 900, 1800, 3600].includes(+d.idle_timeout) ? [] : [[d.idle_timeout, `${d.idle_timeout} s`]]])))}
          ${field(t("df_sv_tcpfwd"), sel("tcp_forwarding", [["yes", t("df_j_on")], ["no", t("df_j_off")], ["local", "local"], ["remote", "remote"]]))}
          ${field(t("df_sv_x11"), sel("x11", [["yes", t("df_j_on")], ["no", t("df_j_off")]]))}</div>
        <label class="df-switch"><span class="switch"><input type="checkbox" name="password" ${d.password === "yes" ? "checked" : ""}><span></span></span><span><b>${esc(t("df_sv_password"))}</b><small>${esc(t("df_sv_password_sub"))}</small></span></label>
        <div class="actions-row"><button type="submit" class="btn primary" ${sv.pending ? "disabled" : ""}>${icon("check")}<span>${esc(t("df_sv_save"))}</span></button></div></form></section>
      <section class="sec"><div class="sec-head"><h3>${icon("key")}${esc(t("df_sv_keys"))}</h3><p class="muted">${esc(t("df_sv_keys_sub"))}</p></div>${keys}
        <form class="subcard" data-f="sv-key" style="margin-top:12px">${field(t("df_sv_key_add"), `<textarea name="key" dir="ltr" rows="3" spellcheck="false" placeholder="${esc(t("df_sv_key_ph"))}" required></textarea>`, t("df_sv_key_hint"))}
          <div class="actions-row"><button type="submit" class="btn">${icon("plus")}<span>${esc(t("df_sv_key_add"))}</span></button></div></form></section>`;
  }
  const repaintSv = () => { const box = D.root.querySelector("#df-sv"); if (box) box.innerHTML = svHTML(); };
  function svFormToDraft() {
    const f = D.root.querySelector('form[data-f="sv"]');
    if (!f) return;
    const el = f.elements;
    Object.assign(D.svDraft, { permit_root: el.permit_root.value, max_auth_tries: +el.max_auth_tries.value, login_grace: +el.login_grace.value,
      idle_timeout: +el.idle_timeout.value, tcp_forwarding: el.tcp_forwarding.value, x11: el.x11.value, password: el.password.checked ? "yes" : "no" });
  }

  // ---- address tester + threat lists (IP lists tab)
  function testerHTML() {
    return `<section class="sec"><div class="sec-head"><h3>${icon("search")}${esc(t("df_tt_title"))}</h3><p class="muted">${esc(t("df_tt_sub"))}</p></div>
      <form class="subcard" data-f="tt"><div class="df-form-grid">${field(t("df_tt_ip"), '<input name="ip" dir="ltr" required placeholder="203.0.113.7" autocomplete="off">')}
        ${field(t("df_tt_port"), '<input name="port" type="number" min="0" max="65535" dir="ltr" placeholder="443">')}
        ${field(t("df_r_proto"), '<select name="proto"><option value="tcp">TCP</option><option value="udp">UDP</option><option value="icmp">ICMP</option></select>')}</div>
        <div class="actions-row"><button type="submit" class="btn primary">${icon("search")}<span>${esc(t("df_tt_check"))}</span></button></div><div id="df-tt-out"></div></form></section>`;
  }
  function testResult(r) {
    const tone = { allow: "ok", block: "bad", limit: "warn", count: "" };
    const text = (s) => {
      if (s.kind === "rule") return t(`df_tt_rule_${s.result}`, { name: s.name, rate: s.limit ? s.limit.rate : "" }) + (s.schedule ? t("df_tt_sched") : "");
      if (s.kind === "banned") return t("df_tt_banned", { left: s.left ? fmtLeft(s.left) : "–" });
      if (s.kind === "fail2ban") return t("df_tt_fail2ban", { jail: s.jail || "fail2ban" });
      if (s.kind === "threat") return t("df_tt_threat", { feeds: s.feeds.join("، ") });
      if (s.kind === "threat_log") return t("df_tt_threat_log", { feeds: s.feeds.join("، ") });
      if (s.kind === "limits") return t("df_tt_limits", { syn: s.limits.syn, conc: s.limits.conc });
      return t(`df_tt_${s.kind}`, s);
    };
    return `<div class="tt-verdict ${tone[r.verdict] || ""}">${pill(tone[r.verdict] || "", t(`df_tt_${r.verdict === "count" ? "allow" : r.verdict}`))}
      <span dir="ltr"><b>${esc(r.ip)}</b>${r.port ? `:${r.port}/${r.proto}` : ""}</span><span class="muted">${esc(r.country ? t("df_tt_country", { c: `${flag(r.country)} ${ccName(r.country)}` }) : t("df_tt_country_unknown"))}</span></div>
      <ol class="tt-steps">${r.steps.map((s) => `<li class="${tone[s.result] || ""}">${pill(tone[s.result] || "", t(`df_tt_${s.result === "count" ? "allow" : s.result}`), false)}<span>${esc(text(s))}</span></li>`).join("")}</ol>`;
  }
  // ---------------------------------------------------------------- threat lists (own tab)
  P.addIcons({ radar: '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4.5"/><path d="M12 12 18.4 5.6"/>' });
  P.addStrings({
    df_t_threat: "Threat lists",
    df_th_title: "Threat lists", df_th_sub: "Public lists of attacking, hijacked and botnet addresses. Everything a listed address starts is dropped before any other check; replies to connections this server opens itself still pass. Private networks are always left out.",
    df_th_on: "Lists on", df_th_blocked_n: "Packets blocked", df_th_since: "since the rules were applied", df_th_kernel: "Entries in the firewall", df_th_cover: "IPv4 addresses covered",
    df_th_out_n: "Outgoing blocked", df_th_next: "Next check", df_th_now: "updating…",
    df_th_recommended: "Turn on the recommended lists", df_th_update_all: "Update all now", df_th_updated_n: "{n} list(s) had new content", df_th_up_to_date: "All lists are up to date",
    df_th_settings: "Settings", df_th_outbound: "Also block this server connecting to them", df_th_outbound_sub: "Stops malware or a hacked app on this server (or a VPN client) from reaching botnet servers. Only lists in block mode.",
    df_th_refresh: "Refresh every", df_th_hours: "{n} h", df_th_save: "Save",
    df_th_mode_block: "Block", df_th_mode_log: "Watch only", df_th_mode_hint: "Watch only counts what the list would block, without blocking: try a list this way first.",
    df_th_rec: "Recommended", df_th_risky: "may hit real users", df_th_entries: "{n} entries", df_th_v6: "{n} IPv6", df_th_addrs: "{n} IPv4 addresses",
    df_th_never: "not downloaded yet", df_th_hits: "{n} packets", df_th_err: "Last update failed: {e}", df_th_update: "Update now", df_th_remove: "Remove",
    df_th_k_hijacked: "Hijacked networks", df_th_k_mixed: "Mixed", df_th_k_botnet: "Botnet servers", df_th_k_compromised: "Compromised hosts", df_th_k_attackers: "Attackers",
    df_th_k_anonymizer: "Anonymizer", df_th_k_custom: "Your list",
    df_th_spamhaus: "Networks stolen by spammers and criminals. Practically never blocks a real user.", df_th_firehol: "A careful mix of the worst lists (attacks, malware, hijacked and unused networks).",
    df_th_feodo: "Command servers of banking trojans and botnets (abuse.ch). Best together with blocking outgoing connections.", df_th_et: "Compromised hosts tracked by Emerging Threats.",
    df_th_cins: "Addresses with a bad reputation from the CINS Army sensors.", df_th_blocklistde: "Addresses that attacked servers in the last 48 hours (SSH, mail, web). Large; shared home addresses can be in it.",
    df_th_ipsum: "Addresses reported by at least 3 different blocklists in the last day.", df_th_greensnow: "Addresses caught scanning and brute-forcing by the GreenSnow sensors.",
    df_th_tor: "Exit nodes of the Tor network. Not attackers as such: turn on only if you don't want anonymous visitors.", df_th_custom: "Your own list from {site}.",
    df_th_add: "Add your own list", df_th_add_sub: "Any https address of a plain list (one address, network or range per line; # and ; start comments). It starts in watch-only mode.",
    df_th_name: "Name", df_th_url: "List address (https)", df_th_add_btn: "Add list", df_th_added: "List added", df_th_removed: "List removed", df_th_remove_confirm: "Remove the list \"{name}\"?",
    df_th_recent: "Recently matched addresses", df_th_recent_sub: "Addresses that hit a list in the last hour. If a real user is among them, allow the address: the allowlist always wins.",
    df_th_none_recent: "No address hit the lists in the last hour.", df_th_r_ip: "Address", df_th_r_kind: "Result", df_th_r_lists: "Lists", df_th_r_when: "When",
    df_th_r_block: "blocked", df_th_r_log: "watched", df_th_allow: "Allow", df_th_allowed: "{ip} is now allowed",
    df_tt_threat_log: "In a watch-only list (not blocked): {feeds}.",
  }, {
    df_t_threat: "لیست‌های تهدید",
    df_th_title: "لیست‌های تهدید", df_th_sub: "لیست‌های عمومی آدرس‌های مهاجم، ربوده‌شده و بات‌نت. هر چیزی که یک آدرس لیست‌شده شروع کند قبل از هر بررسی دیگری دور ریخته می‌شود؛ جواب اتصال‌هایی که خود این سرور باز می‌کند رد می‌شود. شبکه‌های خصوصی همیشه کنار گذاشته می‌شوند.",
    df_th_on: "لیست‌های روشن", df_th_blocked_n: "بسته‌های مسدودشده", df_th_since: "از وقتی قوانین اعمال شده", df_th_kernel: "ردیف‌ها در فایروال", df_th_cover: "آدرس IPv4 پوشش داده‌شده",
    df_th_out_n: "خروجی مسدودشده", df_th_next: "بررسی بعدی", df_th_now: "در حال بروزرسانی…",
    df_th_recommended: "روشن کردن لیست‌های پیشنهادی", df_th_update_all: "بروزرسانی همه همین حالا", df_th_updated_n: "{n} لیست محتوای جدید داشت", df_th_up_to_date: "همه‌ی لیست‌ها بروز هستند",
    df_th_settings: "تنظیمات", df_th_outbound: "اتصال این سرور به آن‌ها هم مسدود شود", df_th_outbound_sub: "جلوی رسیدن بدافزار یا برنامه‌ی هک‌شده روی این سرور (یا کاربر VPN) به سرورهای بات‌نت را می‌گیرد. فقط لیست‌های حالت مسدود.",
    df_th_refresh: "بروزرسانی هر", df_th_hours: "{n} ساعت", df_th_save: "ذخیره",
    df_th_mode_block: "مسدود", df_th_mode_log: "فقط نظارت", df_th_mode_hint: "«فقط نظارت» چیزی را مسدود نمی‌کند، فقط می‌شمارد که لیست چه چیزهایی را مسدود می‌کرد: اول یک لیست را این‌طور امتحان کنید.",
    df_th_rec: "پیشنهادی", df_th_risky: "ممکن است کاربر واقعی را بگیرد", df_th_entries: "{n} ردیف", df_th_v6: "{n} IPv6", df_th_addrs: "{n} آدرس IPv4",
    df_th_never: "هنوز دانلود نشده", df_th_hits: "{n} بسته", df_th_err: "آخرین بروزرسانی ناموفق بود: {e}", df_th_update: "بروزرسانی", df_th_remove: "حذف",
    df_th_k_hijacked: "شبکه‌های ربوده‌شده", df_th_k_mixed: "ترکیبی", df_th_k_botnet: "سرورهای بات‌نت", df_th_k_compromised: "میزبان‌های آلوده", df_th_k_attackers: "مهاجم‌ها",
    df_th_k_anonymizer: "ناشناس‌ساز", df_th_k_custom: "لیست شما",
    df_th_spamhaus: "شبکه‌هایی که اسپمرها و مجرمان دزدیده‌اند. تقریباً هیچ‌وقت کاربر واقعی را نمی‌گیرد.", df_th_firehol: "ترکیب دقیق بدترین لیست‌ها (حمله، بدافزار، شبکه‌های ربوده‌شده و استفاده‌نشده).",
    df_th_feodo: "سرورهای فرمان تروجان‌های بانکی و بات‌نت‌ها (abuse.ch). بهترین حالت همراه با مسدود کردن اتصال خروجی است.", df_th_et: "میزبان‌های آلوده‌ای که Emerging Threats رصد می‌کند.",
    df_th_cins: "آدرس‌های بدنام از حسگرهای CINS Army.", df_th_blocklistde: "آدرس‌هایی که در ۴۸ ساعت اخیر به سرورها حمله کرده‌اند (SSH، ایمیل، وب). بزرگ است و ممکن است آدرس‌های مشترک خانگی در آن باشد.",
    df_th_ipsum: "آدرس‌هایی که در روز گذشته دست‌کم در ۳ لیست سیاه مختلف گزارش شده‌اند.", df_th_greensnow: "آدرس‌هایی که حسگرهای GreenSnow حین اسکن و حدس رمز گرفته‌اند.",
    df_th_tor: "نودهای خروجی شبکه‌ی Tor. خودشان مهاجم نیستند: فقط اگر بازدیدکننده‌ی ناشناس نمی‌خواهید روشن کنید.", df_th_custom: "لیست خودتان از {site}.",
    df_th_add: "افزودن لیست خودتان", df_th_add_sub: "هر آدرس https یک لیست ساده (در هر خط یک آدرس، شبکه یا بازه؛ # و ; شروع توضیح). اول در حالت «فقط نظارت» شروع می‌شود.",
    df_th_name: "نام", df_th_url: "آدرس لیست (https)", df_th_add_btn: "افزودن لیست", df_th_added: "لیست اضافه شد", df_th_removed: "لیست حذف شد", df_th_remove_confirm: "لیست «{name}» حذف شود؟",
    df_th_recent: "آدرس‌هایی که اخیراً منطبق شدند", df_th_recent_sub: "آدرس‌هایی که در یک ساعت اخیر به یکی از لیست‌ها خورده‌اند. اگر کاربر واقعی بین‌شان است، آن آدرس را مجاز کنید: لیست سفید همیشه مقدم است.",
    df_th_none_recent: "در یک ساعت اخیر هیچ آدرسی به لیست‌ها نخورده است.", df_th_r_ip: "آدرس", df_th_r_kind: "نتیجه", df_th_r_lists: "لیست‌ها", df_th_r_when: "زمان",
    df_th_r_block: "مسدود شد", df_th_r_log: "نظارت شد", df_th_allow: "مجاز کن", df_th_allowed: "{ip} حالا مجاز است",
    df_tt_threat_log: "در لیستی با حالت «فقط نظارت» (مسدود نمی‌شود): {feeds}.",
  });

  function threatCard(id, f) {
    const on = f.enabled;
    const desc = f.custom ? t("df_th_custom", { site: f.site }) : t(`df_th_${id}`);
    const stats = f.updated
      ? [t("df_th_entries", { n: nf(f.v4 + f.v6, 0) }), f.addresses ? t("df_th_addrs", { n: nf(f.addresses, 0) }) : "", f.v6 ? t("df_th_v6", { n: nf(f.v6, 0) }) : "", ago(f.updated)].filter(Boolean).join(" · ")
      : t("df_th_never");
    const mode = on ? `<div class="df-seg th-mode" role="group" aria-label="${esc(t("df_th_mode_hint"))}">${["block", "log"].map((m) =>
      `<button type="button" class="${f.mode === m ? "on" : ""}" aria-pressed="${f.mode === m}" data-a="th-mode" data-id="${esc(id)}" data-mode="${m}">${esc(t(`df_th_mode_${m}`))}</button>`).join("")}</div>` : "";
    return `<article class="th-feed${on ? " on" : ""}${on && f.mode === "log" ? " watch" : ""}">
      <label class="th-top"><span class="switch"><input type="checkbox" data-feed="${esc(id)}" ${on ? "checked" : ""}><span></span></span>
        <span class="th-body"><b>${esc(f.name)}</b><span class="th-tags">${pill("", t(`df_th_k_${f.kind}`), false)}${f.safe ? pill("ok", t("df_th_rec"), false) : `<small class="muted">${esc(t("df_th_risky"))}</small>`}</span></span></label>
      <small class="th-desc">${esc(desc)}</small>
      <small class="muted">${esc(stats)} · <span dir="ltr">${esc(f.site)}</span></small>
      ${f.error ? `<small class="th-err">${icon("alert")}<span>${esc(t("df_th_err", { e: f.error }))}</span></small>` : ""}
      <div class="th-foot">${mode}${on && f.hits ? `<span class="pill ${f.mode === "log" ? "warn" : "bad"}">${esc(t("df_th_hits", { n: nf(f.hits, 0) }))}</span>` : ""}
        <span class="th-btns">${on ? btnIcon("refresh", t("df_th_update"), `data-a="th-refresh" data-id="${esc(id)}"`) : ""}${f.custom ? btnIcon("trash", t("df_th_remove"), `data-a="th-del" data-id="${esc(id)}" data-name="${esc(f.name)}"`, "danger") : ""}</span></div>
    </article>`;
  }

  async function renderThreat() {
    const th = await api("/api/defender/threat");
    D.th = th;
    const ids = th.order.filter((id) => th.feeds[id]);
    const on = ids.filter((id) => th.feeds[id].enabled);
    const stat = (label, value, sub = "") => `<div class="th-stat"><span class="muted">${esc(label)}</span><b>${esc(value)}</b>${sub ? `<small class="muted">${esc(sub)}</small>` : ""}</div>`;
    const next = th.refreshing ? t("df_th_now") : th.next_check ? new Date(th.next_check * 1000).toLocaleTimeString(P.state.lang === "fa" ? "fa-IR" : "en-GB", { hour: "2-digit", minute: "2-digit" }) : "–";
    const stats = `<div class="th-stats">${stat(t("df_th_on"), `${nf(on.length, 0)} / ${nf(ids.length, 0)}`)}${stat(t("df_th_blocked_n"), th.blocked == null ? "–" : nf(th.blocked, 0), t("df_th_since"))}
      ${stat(t("df_th_kernel"), nf(th.entries, 0))}${stat(t("df_th_cover"), nf(th.addresses, 0))}${th.outbound ? stat(t("df_th_out_n"), th.blocked_out == null ? "–" : nf(th.blocked_out, 0)) : ""}${on.length ? stat(t("df_th_next"), next) : ""}</div>`;
    const recSafe = ids.filter((id) => th.feeds[id].safe && !th.feeds[id].enabled);
    const tools = `<div class="actions-row">${recSafe.length ? `<button type="button" class="btn primary" data-a="th-recommended">${icon("shield")}<span>${esc(t("df_th_recommended"))}</span></button>` : ""}
      ${on.length ? `<button type="button" class="btn" data-a="th-refresh">${icon("refresh")}<span>${esc(t("df_th_update_all"))}</span></button>` : ""}</div>`;
    const hours = [3, 6, 12, 24, 48].includes(th.refresh_hours) ? [3, 6, 12, 24, 48] : [3, 6, 12, 24, 48, th.refresh_hours].sort((a, b) => a - b);
    const settings = `<form class="subcard th-set" data-f="th-set"><h4>${icon("sliders")}${esc(t("df_th_settings"))}</h4>
      <label class="df-switch"><span class="switch"><input type="checkbox" name="outbound" ${th.outbound ? "checked" : ""}><span></span></span><span><b>${esc(t("df_th_outbound"))}</b><small>${esc(t("df_th_outbound_sub"))}</small></span></label>
      <div class="field-row">${field(t("df_th_refresh"), `<select name="hours">${hours.map((h) => `<option value="${h}" ${h === th.refresh_hours ? "selected" : ""}>${esc(t("df_th_hours", { n: nf(h, 0) }))}</option>`).join("")}</select>`)}
        <div class="field"><label>&nbsp;</label><button type="submit" class="btn">${icon("check")}<span>${esc(t("df_th_save"))}</span></button></div></div>
      <p class="hint">${esc(t("df_th_mode_hint"))}</p></form>`;
    const customN = ids.filter((id) => th.feeds[id].custom).length;
    const add = customN < th.custom_max ? `<form class="subcard" data-f="th-add"><h4>${icon("plus")}${esc(t("df_th_add"))}</h4><p class="muted">${esc(t("df_th_add_sub"))}</p>
      <div class="df-form-grid">${field(t("df_th_name"), '<input name="name" maxlength="60" required autocomplete="off">')}${field(t("df_th_url"), '<input name="url" type="url" dir="ltr" required placeholder="https://example.com/blocklist.txt" autocomplete="off">')}</div>
      <div class="actions-row"><button type="submit" class="btn primary">${icon("plus")}<span>${esc(t("df_th_add_btn"))}</span></button></div></form>` : "";
    const names = Object.fromEntries(ids.map((id) => [id, th.feeds[id].name]));
    const recent = th.recent.length ? table([
      { h: "df_th_r_ip", cell: (r) => `<code dir="ltr">${esc(r.ip)}</code>` },
      { h: "df_th_r_kind", cell: (r) => pill(r.kind === "block" ? "bad" : "warn", t(`df_th_r_${r.kind}`)) },
      { h: "df_th_r_lists", cell: (r) => esc(r.lists.map((x) => names[x] || x).join("، ") || "–") },
      { h: "df_th_r_when", cell: (r) => esc(ago(Date.now() / 1000 - r.ago)) },
      { h: "actions", cell: (r) => `<button type="button" class="btn small" data-a="th-allow" data-ip="${esc(r.ip)}">${icon("check")}<span>${esc(t("df_th_allow"))}</span></button>` },
    ], th.recent) : `<div class="empty">${esc(t("df_th_none_recent"))}</div>`;
    return `<section class="sec"><div class="sec-head"><h3>${icon("radar")}${esc(t("df_th_title"))}</h3><p class="muted">${esc(t("df_th_sub"))}</p></div>
        ${th.protection ? "" : `<div class="notice warn">${icon("bell")}<span>${esc(t("df_r_off"))}</span></div>`}
        ${stats}${tools}</section>
      <section class="sec"><div class="th-grid">${ids.map((id) => threatCard(id, th.feeds[id])).join("")}</div></section>
      <section class="sec"><div class="th-two">${settings}${add}</div></section>
      <section class="sec"><div class="sec-head"><h3>${icon("eye")}${esc(t("df_th_recent"))}</h3><p class="muted">${esc(t("df_th_recent_sub"))}</p></div>${recent}</section>`;
  }

  async function threatSave(el, patch, what) {
    const ok = await apply(el, "config", { threat: patch, _what: what }, t("df_r_saved"));
    if (D.tab === "threat") showTab("threat");
    return ok;
  }

  async function renderListsAll() {
    return testerHTML() + await renderLists();
  }

  const RENDER = { advanced: renderAdvanced, overview: renderOverview, firewall: renderFirewall, ddos: renderDdos, rules: renderRules, lists: renderListsAll, threat: renderThreat, ssh: renderSshAll, f2b: renderF2b, hardening: renderHardening };
  const rerender = () => showTab(D.tab);

  // ---------------------------------------------------------------- events
  async function onClick(e) {
    const b = e.target.closest("[data-a]");
    if (!b || b.disabled) return;
    const a = b.dataset.a;
    if (a === "tab") return showTab(b.dataset.tab);
    if (a === "th-mode") {
      if (b.classList.contains("on")) return;
      return threatSave(b, { mode: { ...D.th.feeds && Object.fromEntries(Object.entries(D.th.feeds).map(([id, f]) => [id, f.mode])), [b.dataset.id]: b.dataset.mode } }, "threat list mode");
    }
    if (a === "th-recommended") {
      const feeds = [...new Set([...D.th.enabled, ...D.th.order.filter((id) => D.th.feeds[id] && D.th.feeds[id].safe)])];
      return threatSave(b, { feeds }, "threat lists");
    }
    if (a === "th-refresh") {
      const r = await act(b, () => post("/api/defender/threat/refresh", b.dataset.id ? { id: b.dataset.id } : {}));
      if (r) {
        const failed = Object.values(r.feeds).filter((f) => f.enabled && f.error && f.error_at > Date.now() / 1000 - 300);
        if (failed.length) toast(t("df_th_err", { e: failed.map((f) => `${f.name}: ${f.error}`).join(" · ") }), "warn");
        else toast(r.changed.length ? t("df_th_updated_n", { n: r.changed.length }) : t("df_th_up_to_date"));
        if (D.tab === "threat") showTab("threat");
      }
      return;
    }
    if (a === "th-del") {
      if (!(await confirmBox({ message: t("df_th_remove_confirm", { name: b.dataset.name }), label: t("df_th_remove") }))) return;
      if (await act(b, () => post("/api/defender/threat/custom/remove", { id: b.dataset.id }), t("df_th_removed"))) showTab("threat");
      return;
    }
    if (a === "th-allow") {
      if (await act(b, () => post("/api/defender/allow", { ip: b.dataset.ip, note: "threat list" }), t("df_th_allowed", { ip: b.dataset.ip }))) showTab("threat");
      return;
    }
    if (a === "keep") { if (await act(b, () => post("/api/defender/confirm", {}), t("df_kept"))) paintPending(null); return; }
    if (a === "undo") { const r = await act(b, () => post("/api/defender/revert", {}), t("df_undone")); if (r) { D.st = r; D.fw = null; paintPending(null); rerender(); } return; }
    if (a === "enable") {
      if (!(await confirmBox({ message: t("df_enable_confirm"), label: t("df_enable"), danger: false }))) return;
      if (await apply(b, "config", { enabled: true, _what: "enable" })) rerender();
      return;
    }
    if (a === "disable") {
      if (!(await confirmBox({ message: t("df_disable_confirm"), label: t("df_disable") }))) return;
      if (await apply(b, "config", { enabled: false, _what: "disable", _rollback: false })) rerender();
      return;
    }
    if (a === "profile") { if (await apply(b, "config", { profile: b.dataset.p, _what: "profile" })) rerender(); return; }
    if (a === "ban") { if (await act(b, () => post("/api/defender/block", { ip: b.dataset.ip, minutes: +b.dataset.min }), `${b.dataset.ip} ✓`)) { D.st.bans++; if (D.tab !== "overview") rerender(); else refreshOverviewSlow(); } return; }
    if (a === "allow") { if (await act(b, () => post("/api/defender/allow", { ip: b.dataset.ip }), `${b.dataset.ip} ✓`)) refreshOverviewSlow(); return; }
    if (a === "sys-open") return openPort(b, { port: b.dataset.port, proto: b.dataset.proto, note: b.dataset.note });
    if (a === "ufw") {
      const enable = b.dataset.act === "enable";
      if (!(await confirmBox({ message: t(enable ? "df_sys_enable_confirm" : "df_sys_disable_confirm"), label: t(enable ? "df_sys_enable" : "df_sys_disable"), danger: !enable }))) return;
      const r = await act(b, () => post("/api/defender/sysfw/ufw", { action: b.dataset.act }), t("saved"));
      if (r) { D.ports = r.rows; D.sysfw = r.sysfw; repaintFw(); }
      return;
    }
    if (a === "ufw-del") {
      if (!(await confirmBox({ message: t("df_sys_del_confirm", { rule: b.dataset.text }), label: t("df_remove") }))) return;
      const r = await act(b, () => post("/api/defender/sysfw/ufw", { action: "delete", text: b.dataset.text }), t("saved"));
      if (r) { D.ports = r.rows; D.sysfw = r.sysfw; repaintFw(); }
      return;
    }
    if (a === "ban-allow") {   // a false positive: lift the ban and never limit this address again
      const ip = b.dataset.ip, jail = b.dataset.jail;
      const ok = await act(b, async () => {
        await post("/api/defender/allow", { ip, note: t("df_ban_trusted_note") });
        return jail ? post("/api/defender/f2b/unban", { ip, jail }) : post("/api/defender/unban", { ip });
      }, t("df_ban_trusted", { ip }));
      if (ok) rerender();
      return;
    }
    if (a === "unban") { if (await act(b, () => post("/api/defender/unban", { ip: b.dataset.ip }), `${b.dataset.ip} ✓`)) rerender(); return; }
    if (a === "unblock" || a === "unallow") { if (await act(b, () => post(`/api/defender/${a}`, { ip: b.dataset.ip }), `${b.dataset.ip} ✓`)) rerender(); return; }
    if (a === "fw-mode") {
      const m = b.dataset.mode;
      if (m === "strict" && D.fw.mode !== "strict") {   // pre-select every port in use so switching cannot break a service
        D.prefilled = false;
        for (const r of D.ports || []) if (!r.always && ruleFor(r) < 0 && !r.restricted) { D.fw.ports.push({ proto: r.proto, port: String(r.port), from: "", note: r.process || "" }); D.prefilled = true; }
      }
      D.fw.mode = m;
      return repaintFw();
    }
    if (a === "fw-open") { D.fw.ports.push({ proto: b.dataset.proto, port: b.dataset.port, from: "", note: b.dataset.note || "" }); return repaintFw(); }
    if (a === "fw-close") { const i = ruleFor({ proto: b.dataset.proto, port: +b.dataset.port }); if (i >= 0) D.fw.ports.splice(i, 1); return repaintFw(); }
    if (a === "fw-del") { D.fw.ports.splice(+b.dataset.i, 1); return repaintFw(); }
    if (a === "fw-add") return addRuleDialog();
    if (a === "if-del") { D.fw.trusted_ifaces.splice(+b.dataset.i, 1); return repaintFw(); }
    if (a === "fw-reset") { D.fw = clone(D.st.config.firewall); D.prefilled = false; return repaintFw(); }
    if (a === "rules") return rulesDialog();
    if (a === "fw-apply") {
      if (await apply(b, "config", { firewall: D.fw, _what: "firewall" })) { D.fw = null; D.prefilled = false; rerender(); }
      return;
    }
    if (a === "sv-port-add" || a === "sv-port-del") {
      svFormToDraft();
      if (a === "sv-port-del") D.svDraft.ports.splice(+b.dataset.i, 1);
      else {
        const v = +D.root.querySelector('form[data-f="sv"] [name="newport"]').value;
        if (v >= 1 && v <= 65535 && !D.svDraft.ports.includes(v)) D.svDraft.ports.push(v);
      }
      return repaintSv();
    }
    if (a === "sv-keep" || a === "sv-undo") {
      const r = await act(b, () => post(`/api/defender/sshd/${a === "sv-keep" ? "confirm" : "revert"}`, {}), t(a === "sv-keep" ? "df_sv_kept" : "df_sv_undone"));
      if (r) { D.sv = { ...D.sv, ...r }; D.svDraft = null; showTab("ssh"); }
      return;
    }
    if (a === "sv-key-del") {
      if (!(await confirmBox({ message: t("df_sv_key_del", { name: b.dataset.name }), label: t("df_remove") }))) return;
      const r = await act(b, () => post("/api/defender/sshd/key/remove", { index: +b.dataset.i }), t("saved"));
      if (r) { D.sv.keys = r.keys; svFormToDraft(); repaintSv(); }
      return;
    }
    if (a === "r-new") return ruleEditor(blankRule(), null);
    if (a === "r-tpl") return ruleEditor(TEMPLATES[b.dataset.tpl](), null);
    if (a === "r-edit") return ruleEditor(D.rules[+b.dataset.i], +b.dataset.i);
    if (a === "r-dup") {
      const src = D.rules[+b.dataset.i];
      const rules = [...D.rules];
      rules.splice(+b.dataset.i + 1, 0, { ...JSON.parse(JSON.stringify(src)), id: newId(), name: `${src.name} (${t("df_r_copy")})`, enabled: false });
      return saveRules(b, rules);
    }
    if (a === "r-move") {
      const i = +b.dataset.i, j = i + +b.dataset.d;
      if (j < 0 || j >= D.rules.length) return;
      const rules = [...D.rules];
      [rules[i], rules[j]] = [rules[j], rules[i]];
      return saveRules(b, rules);
    }
    if (a === "r-del") {
      const r = D.rules[+b.dataset.i];
      if (!(await confirmBox({ message: t("df_r_delete_confirm", { name: r.name }), label: t("df_j_delete") }))) return;
      return saveRules(b, D.rules.filter((_, k) => k !== +b.dataset.i));
    }
    if (a === "f2b-install") {
      if (!(await confirmBox({ message: t("df_f2b_install_confirm"), label: t("df_f2b_install"), danger: false }))) return;
      const r = await act(b, () => post("/api/defender/f2b/install", {}));
      if (r) { D.f2b = { ...D.f2b, job: r.job }; paintF2b(); schedJob(); }
      return;
    }
    if (a === "f2b-uninstall") return uninstallDialog();
    if (a === "f2b-svc") {
      const action = b.dataset.act;
      if (action === "stop" && !(await confirmBox({ message: t("df_f2b_stop_confirm"), label: t("df_f2b_stop") }))) return;
      const r = await act(b, () => post("/api/defender/f2b/service", { action }), t("df_f2b_job_ok"));
      if (r) { D.f2b = r; paintF2b(); }
      return;
    }
    if (a === "f2b-jail-set") return jailSettingsDialog(b.dataset.jail);
    if (a === "f2b-jail-edit") return jailEditor(b.dataset.jail).catch((x) => toast(x.message, "bad"));
    if (a === "f2b-jail-new") return jailEditor("", true).catch((x) => toast(x.message, "bad"));
    if (a === "f2b-jail-del") return deleteJail(b.dataset.jail, b);
    if (a === "f2b-file") return fileEditor(b.dataset.path).catch((x) => toast(x.message, "bad"));
    if (a === "f2b-file-new") return newFileDialog();
    if (a === "adv-pa-del" || a === "adv-pa-add" || a === "adv-pa-me") {
      const form = D.root.querySelector('form[data-f="adv"]');
      advFormToDraft(form);
      if (a === "adv-pa-del") D.adv.panel_allow.splice(+b.dataset.i, 1);
      else {
        const v = a === "adv-pa-me" ? D.myIp : form.elements.pa_new.value.trim();
        if (v && !D.adv.panel_allow.includes(v)) D.adv.panel_allow.push(v);
      }
      return repaintAdv();
    }
    if (a === "adv-sys-del") {
      const r = await act(b, () => post("/api/defender/sysctl", { action: "custom_del", key: b.dataset.key }), t("saved"));
      if (r) { D.sysCustom = r.custom || {}; advFormToDraft(D.root.querySelector('form[data-f="adv"]')); repaintAdv(); }
      return;
    }
    if (a === "f2b-jail-bans") return jailBansDialog(b.dataset.jail);
    if (a === "f2b-unban") { if (await act(b, () => post("/api/defender/f2b/unban", { ip: b.dataset.ip, jail: b.dataset.jail }), `${b.dataset.ip} ✓`)) rerender(); return; }
    if (a === "f2b-ign-del") { D.f2bIgnore.splice(+b.dataset.i, 1); return paintF2b(); }
    if (a === "f2b-ign-add" || a === "f2b-ign-trusted") {
      const add = a === "f2b-ign-trusted" ? D.f2b.admin_ips : [b.closest("form").elements.newip.value.trim()].filter(Boolean);
      for (const ip of add) if (!D.f2bIgnore.includes(ip)) D.f2bIgnore.push(ip);
      return paintF2b();
    }
    if (a === "f2b-log" || a === "f2b-log-open") {
      setTimeout(async () => {
        const pre = D.root.querySelector("#df-f2b-log");
        if (!pre || (a === "f2b-log-open" && !pre.closest("details").open)) return;
        try { pre.textContent = (await api("/api/defender/f2b/log")).text || "—"; pre.scrollTop = pre.scrollHeight; } catch (e) { pre.textContent = e.message; }
      }, 0);
      return;
    }
    if (a === "export") return exportBackup(b);
    if (a === "sysctl") {
      const r = await act(b, () => post("/api/defender/sysctl", { action: b.dataset.act }), t("saved"));
      if (r) rerender();
    }
  }

  async function onChange(e) {
    const el = e.target;
    if (el.dataset.feed) {
      const feeds = [...D.root.querySelectorAll("[data-feed]")].filter((x) => x.checked).map((x) => x.dataset.feed);
      D.root.querySelectorAll("[data-feed]").forEach((x) => { x.disabled = true; });
      if (!(await threatSave(el, { feeds }, "threat lists"))) el.checked = !el.checked;
      D.root.querySelectorAll("[data-feed]").forEach((x) => { x.disabled = false; });
      return;
    }
    if (el.dataset.ruleToggle !== undefined) {
      const rules = D.rules.map((r, k) => (k === +el.dataset.ruleToggle ? { ...r, enabled: el.checked } : r));
      el.disabled = true;
      if (!(await saveRules(el, rules))) { el.checked = !el.checked; el.disabled = false; }
      return;
    }
    if (el.dataset.jailToggle) {
      const name = el.dataset.jailToggle, on = el.checked;
      el.disabled = true;
      try { D.f2b = await post("/api/defender/f2b/jail", { name, enabled: on }); toast(t("df_f2b_saved")); paintF2b(); }
      catch (x) { el.checked = !on; el.disabled = false; if (x.message !== "unauthorized") toast(x.message, "bad"); }
      return;
    }
    if (el.matches("[data-import]")) { const f = el.files[0]; el.value = ""; if (f) importBackup(f); return; }
    const form = e.target.closest("form[data-f]");
    if (!form || e.target.type !== "checkbox" || form.dataset.f === "adv") return;
    const f = form.dataset.f, on = e.target.checked, name = e.target.name;
    if (f === "esc") { if (!(await apply(e.target, "config", { auto_escalate: on, _rollback: false }, t("saved")))) e.target.checked = !on; }
    if (f === "cdn") { if (!(await apply(e.target, "config", { trust_cdn: on, _what: "cdn" }, t("df_kept")))) e.target.checked = !on; }
    if (f === "notify") { if (!(await apply(e.target, "config", { notify: { [name]: on }, _rollback: false }, t("saved")))) e.target.checked = !on; }
  }

  async function onSubmit(e) {
    const form = e.target.closest("form[data-f]");
    if (!form) return;
    e.preventDefault();
    const f = form.dataset.f, btn = form.querySelector('[type="submit"]'), el = form.elements;
    if (f === "if-add") {
      const v = el.iface.value.trim();
      if (!/^[A-Za-z0-9_.\-]{1,15}\*?$/.test(v)) return toast(t("df_ifaces_sub"), "warn");
      if (!D.fw.trusted_ifaces.includes(v)) D.fw.trusted_ifaces.push(v);
      return repaintFw();
    }
    if (f === "ddos") {
      const limits = Object.fromEntries(LIMITS.map(([k]) => [k, +el[k].value]));
      if (await apply(btn, "config", { limits, ddos: { drop_invalid: el.drop_invalid.checked, bad_flags: el.bad_flags.checked }, _what: "limits" })) rerender();
      return;
    }
    if (f === "ssh") {
      const g = { enabled: el.enabled.checked, l4: el.l4.checked, exempt_private: el.exempt_private.checked, failures: +el.failures.value, window: +el.window.value, ban: +el.ban.value };
      if (await apply(btn, "config", { ssh_guard: g, _what: "ssh guard" }, t("saved"))) rerender();
      return;
    }
    if (f === "sv") {
      svFormToDraft();
      if (!D.svDraft.ports.length) return toast(t("df_sv_last_port"), "bad");
      if (!(await confirmBox({ message: t("df_sv_confirm", { ports: D.svDraft.ports.join(", ") }), label: t("df_sv_save"), danger: false }))) return;
      const r = await act(btn, () => post("/api/defender/sshd/apply", D.svDraft), t("df_sv_applied"));
      if (r) { D.sv = { ...D.sv, ...r }; D.svDraft = null; if (r.warning) toast(r.warning, "warn"); showTab("ssh"); }
      return;
    }
    if (f === "sv-key") {
      const r = await act(btn, () => post("/api/defender/sshd/key/add", { key: el.key.value }), t("saved"));
      if (r) { D.sv.keys = r.keys; svFormToDraft(); repaintSv(); }
      return;
    }
    if (f === "port-open") {
      const port = el.port.value.trim().replace(":", "-");
      if (await openPort(btn, { port, proto: el.proto.value, from: el.from.value.trim(), note: el.note.value.trim() })) {
        const ff = D.root.querySelector('form[data-f="port-open"]');
        if (ff) ff.reset();
      }
      return;
    }
    if (f === "th-set") {
      await threatSave(btn, { outbound: el.outbound.checked, refresh_hours: +el.hours.value }, "threat settings");
      return;
    }
    if (f === "th-add") {
      if (await act(btn, () => post("/api/defender/threat/custom/add", { name: el.name.value.trim(), url: el.url.value.trim() }), t("df_th_added"))) showTab("threat");
      return;
    }
    if (f === "tt") {
      const out = D.root.querySelector("#df-tt-out");
      const r = await act(btn, () => post("/api/defender/test", { ip: el.ip.value.trim(), port: +el.port.value || 0, proto: el.proto.value }));
      if (r && out) out.innerHTML = testResult(r);
      return;
    }
    if (f === "adv") {
      advFormToDraft(form);
      const { _logged, _cdn, ...advanced } = D.adv;
      if (await apply(btn, "config", { advanced, trust_logged_in: _logged, trust_cdn: _cdn, _what: "advanced" })) { D.adv = null; rerender(); }
      return;
    }
    if (f === "adv-sys") {
      const r = await act(btn, () => post("/api/defender/sysctl", { action: "custom_set", key: el.key.value.trim(), value: el.value.value.trim() }), t("saved"));
      if (r) { D.sysCustom = r.custom || {}; advFormToDraft(D.root.querySelector('form[data-f="adv"]')); repaintAdv(); }
      return;
    }
    if (f === "f2b-defaults") {
      const body = { maxretry: +el.maxretry.value, findtime: el.findtime.value, bantime: el.bantime.value,
        "bantime.maxtime": el.maxtime.value, "bantime.increment": el.increment.checked, ignoreip: D.f2bIgnore };
      const r = await act(btn, () => post("/api/defender/f2b/defaults", body), t("df_f2b_saved"));
      if (r) { D.f2b = r; D.f2bIgnore = null; paintF2b(); }
      return;
    }
    if (f === "list-add") {
      const ip = el.ip.value.trim(), action = el.action.value, note = el.note.value.trim();
      const call = action === "allow" ? () => post("/api/defender/allow", { ip, note })
        : action === "block" ? () => post("/api/defender/block", { ip, note })
        : () => post("/api/defender/block", { ip, note, minutes: +action.slice(3) });
      if (await act(btn, call, `${ip} ✓`)) rerender();
    }
  }

  P.registerView({ id: "defender", icon: "shield", label: "df_nav", desc: "df_desc", group: "monitor", static: true }, { build: async () => ({ html: await build(), tools: "" }), bind }, "overview");
  P.setTabs(["overview", "defender", "websites", "alerts"]);
})();
__MONITORING_EOF__
  write_file panel/static/security.js 644 <<'__MONITORING_EOF__'
// Panel security: two-factor sign-in, active sessions, login protection and the security log.
(() => {
  "use strict";
  const P = window.Panel;
  if (!P) return;
  const { t, esc, num, ago, icon, api, post, act, toast, openDialog, confirmBox, table, field } = P;

  P.addIcons({ key: '<circle cx="7.5" cy="15.5" r="4.5"/><path d="m10.7 12.3 8.8-8.8M16 6l3 3M14 8l2 2"/>', device: '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/>' });
  P.addStrings({
    sec_nav: "Panel security", sec_desc: "Who can sign in to this panel, from where, and what happened. Turn on two-factor sign-in for the strongest protection.",
    sec_score_good: "The panel is well protected", sec_score_warn: "The panel can be protected better",
    sec_2fa: "Two-factor sign-in", sec_2fa_on: "On: a code from your phone is needed at every sign-in.", sec_2fa_off: "Off: anyone who learns the password can sign in.",
    sec_2fa_enable: "Turn on", sec_2fa_disable: "Turn off", sec_2fa_step1: "Confirm with your password to start.", sec_2fa_step2: "Add this key to an authenticator app (Google Authenticator, Microsoft Authenticator, Authy, 2FAS …): choose \"Enter a setup key\", or open the link on your phone.",
    sec_2fa_key: "Setup key", sec_2fa_link: "Open in authenticator app", sec_2fa_code: "6-digit code from the app", sec_2fa_done: "Two-factor sign-in is on. Other devices were signed out.", sec_2fa_off_done: "Two-factor sign-in is off",
    sec_2fa_lost: "Lost the phone? On the server delete data/panel/totp.json to turn it off.", sec_password: "Password", sec_next: "Next", sec_confirm_disable: "Turn off two-factor sign-in",
    sec_sessions: "Signed-in devices", sec_sessions_sub: "Every browser that is signed in. A session ends after a day without use or after two weeks.", sec_device: "Device", sec_address: "Address",
    sec_started: "Signed in", sec_last: "Last active", sec_this: "this device", sec_revoke: "Sign out", sec_revoke_others: "Sign out all other devices", sec_revoked: "Signed out",
    sec_login: "Login protection", sec_login_sub: "{n} wrong attempts within 15 minutes lock the address (15 minutes, doubling up to a day). After {f} wrong attempts the firewall bans it for an hour.",
    sec_locked: "Locked addresses", sec_none_locked: "No address is locked.", sec_left: "Unlocks in", sec_attempts: "Wrong attempts", sec_unlock: "Unlock",
    sec_notify: "Telegram messages", sec_notify_login: "Sign-in from a new address", sec_notify_lock: "An address got locked out",
    sec_log: "Security log", sec_log_none: "Nothing yet.",
    sec_e_login: "Signed in", sec_e_login_failed: "Wrong password ({user})", sec_e_locked: "Locked out for {minutes} min", sec_e_logout: "Signed out", sec_e_password: "Password changed",
    sec_e_2fa_on: "Two-factor sign-in turned on", sec_e_2fa_off: "Two-factor sign-in turned off", sec_e_session_revoked: "A device was signed out", sec_e_sessions_revoked: "Other devices signed out",
    sec_e_unlocked: "{target} unlocked", sec_e_firewall_ban: "Banned by the firewall (login brute force)",
    sec_tips: "More protection", sec_tip_https: "Put HTTPS in front of the panel (Caddy or Nginx) so the password never travels in plain text.",
    sec_tip_ip: "Allow only your own addresses to open the panel: Firewall → Advanced → Who can open the panel.", sec_tip_pw: "Use a long password (12+ characters) that you use nowhere else: Settings → Change login.",
    sec_open_fw: "Open", sec_your_ip: "Your address now: {ip}",
  }, {
    sec_nav: "امنیت پنل", sec_desc: "چه کسی، از کجا وارد این پنل می‌شود و چه اتفاقی افتاده. برای قوی‌ترین محافظت ورود دومرحله‌ای را روشن کنید.",
    sec_score_good: "پنل خوب محافظت می‌شود", sec_score_warn: "پنل را می‌شود بهتر محافظت کرد",
    sec_2fa: "ورود دومرحله‌ای", sec_2fa_on: "روشن: در هر ورود کد گوشی لازم است.", sec_2fa_off: "خاموش: هر کس رمز را بداند می‌تواند وارد شود.",
    sec_2fa_enable: "روشن کردن", sec_2fa_disable: "خاموش کردن", sec_2fa_step1: "برای شروع رمز عبور را وارد کنید.", sec_2fa_step2: "این کلید را در یک برنامه‌ی احراز هویت (Google Authenticator، Microsoft Authenticator، Authy، 2FAS …) اضافه کنید: گزینه‌ی «وارد کردن کلید» را بزنید، یا لینک را روی گوشی باز کنید.",
    sec_2fa_key: "کلید راه‌اندازی", sec_2fa_link: "باز کردن در برنامه‌ی احراز هویت", sec_2fa_code: "کد ۶ رقمی برنامه", sec_2fa_done: "ورود دومرحله‌ای روشن شد. دستگاه‌های دیگر خارج شدند.", sec_2fa_off_done: "ورود دومرحله‌ای خاموش شد",
    sec_2fa_lost: "گوشی را گم کردید؟ روی سرور فایل data/panel/totp.json را پاک کنید تا خاموش شود.", sec_password: "رمز عبور", sec_next: "بعدی", sec_confirm_disable: "خاموش کردن ورود دومرحله‌ای",
    sec_sessions: "دستگاه‌های واردشده", sec_sessions_sub: "هر مرورگری که وارد شده. نشست بعد از یک روز بی‌استفاده یا بعد از دو هفته تمام می‌شود.", sec_device: "دستگاه", sec_address: "آدرس",
    sec_started: "ورود", sec_last: "آخرین فعالیت", sec_this: "همین دستگاه", sec_revoke: "خروج", sec_revoke_others: "خروج همه‌ی دستگاه‌های دیگر", sec_revoked: "خارج شد",
    sec_login: "محافظت ورود", sec_login_sub: "{n} تلاش اشتباه در ۱۵ دقیقه آدرس را قفل می‌کند (۱۵ دقیقه، هر بار دو برابر تا یک روز). بعد از {f} تلاش اشتباه، فایروال آن را یک ساعت مسدود می‌کند.",
    sec_locked: "آدرس‌های قفل‌شده", sec_none_locked: "هیچ آدرسی قفل نیست.", sec_left: "باز شدن تا", sec_attempts: "تلاش اشتباه", sec_unlock: "باز کردن",
    sec_notify: "پیام تلگرام", sec_notify_login: "ورود از آدرس جدید", sec_notify_lock: "قفل شدن یک آدرس",
    sec_log: "گزارش امنیتی", sec_log_none: "هنوز چیزی نیست.",
    sec_e_login: "ورود", sec_e_login_failed: "رمز اشتباه ({user})", sec_e_locked: "{minutes} دقیقه قفل شد", sec_e_logout: "خروج", sec_e_password: "رمز عوض شد",
    sec_e_2fa_on: "ورود دومرحله‌ای روشن شد", sec_e_2fa_off: "ورود دومرحله‌ای خاموش شد", sec_e_session_revoked: "یک دستگاه خارج شد", sec_e_sessions_revoked: "دستگاه‌های دیگر خارج شدند",
    sec_e_unlocked: "قفل {target} باز شد", sec_e_firewall_ban: "توسط فایروال مسدود شد (حمله به ورود)",
    sec_tips: "محافظت بیشتر", sec_tip_https: "جلوی پنل HTTPS بگذارید (Caddy یا Nginx) تا رمز هیچ‌وقت بدون رمزنگاری منتقل نشود.",
    sec_tip_ip: "فقط آدرس‌های خودتان اجازه‌ی باز کردن پنل را داشته باشند: فایروال ← پیشرفته ← چه کسی پنل را باز کند.", sec_tip_pw: "رمز طولانی (۱۲+ کاراکتر) که جای دیگری استفاده نمی‌کنید: تنظیمات ← تغییر اطلاعات ورود.",
    sec_open_fw: "باز کردن", sec_your_ip: "آدرس فعلی شما: {ip}",
  });

  let S = null, root = null;
  const device = (ua) => {
    ua = ua || "";
    const b = /Edg\//.test(ua) ? "Edge" : /OPR\//.test(ua) ? "Opera" : /Firefox\//.test(ua) ? "Firefox" : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : /curl|python|Go-http/i.test(ua) ? "Script" : "Browser";
    const o = /Android/.test(ua) ? "Android" : /iPhone|iPad/.test(ua) ? "iOS" : /Windows/.test(ua) ? "Windows" : /Mac OS/.test(ua) ? "macOS" : /Linux/.test(ua) ? "Linux" : "";
    return o ? `${b} · ${o}` : b;
  };
  const left = (s) => (s > 3600 ? `${(s / 3600).toFixed(1)}h` : `${Math.ceil(s / 60)}m`);
  const sw = (name, on, label) => `<label class="df-switch"><span class="switch"><input type="checkbox" name="${name}" ${on ? "checked" : ""}><span></span></span><span><b>${esc(label)}</b></span></label>`;

  function html() {
    const good = S.totp;
    const sessions = table([
      { h: "sec_device", cls: "strong", cell: (r) => `${icon("device")} ${esc(device(r.ua))}${r.current ? `<span class="tag">${esc(t("sec_this"))}</span>` : ""}` },
      { h: "sec_address", cell: (r) => num(esc(r.ip)) },
      { h: "sec_started", cell: (r) => esc(ago(r.created)) },
      { h: "sec_last", cell: (r) => esc(ago(r.last)) },
      { h: "actions", cell: (r) => (r.current ? "–" : `<button type="button" class="btn small" data-a="revoke" data-id="${esc(r.id)}">${esc(t("sec_revoke"))}</button>`) },
    ], S.sessions);
    const locks = S.locks.length ? table([
      { h: "sec_address", cls: "strong", cell: (r) => num(esc(r.ip)) },
      { h: "sec_attempts", cell: (r) => num(r.failures) },
      { h: "sec_left", cell: (r) => num(esc(left(r.left))) },
      { h: "actions", cell: (r) => `<button type="button" class="btn small" data-a="unlock" data-ip="${esc(r.ip)}">${esc(t("sec_unlock"))}</button>` },
    ], S.locks) : `<div class="empty">${esc(t("sec_none_locked"))}</div>`;
    const logRows = S.log.length ? `<ol class="df-events">${S.log.slice(0, 40).map((e) => {
      const ic = { login: "okmark", login_failed: "alert", locked: "lock", logout: "logout", password: "key", "2fa_on": "shield", "2fa_off": "alert", firewall_ban: "ban" }[e.kind] || "bell";
      const bad = ["login_failed", "locked", "firewall_ban", "2fa_off"].includes(e.kind);
      return `<li class="${bad ? "ev-attack_start" : e.kind === "login" ? "ev-allow" : ""}"><span class="ev-ic">${icon(ic)}</span><span class="ev-t">${esc(t(`sec_e_${e.kind}`, e))} <span class="muted" dir="ltr">${esc(e.ip || "")}</span></span><time>${esc(ago(e.t))}</time></li>`;
    }).join("")}</ol>` : `<div class="empty">${esc(t("sec_log_none"))}</div>`;
    return `<section class="card hero df-hero ${good ? "" : "warn"}"><div class="hero-icon">${icon(good ? "shield" : "alert")}</div>
        <div class="hero-text"><h2>${esc(t(good ? "sec_score_good" : "sec_score_warn"))}</h2><p>${esc(t(good ? "sec_2fa_on" : "sec_2fa_off"))}</p>
        <div class="hero-meta"><span class="chip">${icon("key")}${esc(t("sec_2fa"))} <b>${esc(good ? "✓" : "–")}</b></span><span class="chip">${icon("device")}${esc(t("sec_sessions"))} <b>${num(S.sessions.length)}</b></span>
          <span class="chip">${esc(t("sec_your_ip", { ip: S.ip }))}</span></div></div>
        <div class="df-hero-act"><button type="button" class="btn ${good ? "ghost danger small" : "primary df-cta"}" data-a="${good ? "2fa-off" : "2fa-on"}">${icon("key")}<span>${esc(t(good ? "sec_2fa_disable" : "sec_2fa_enable"))}</span></button></div></section>
      <section class="sec"><div class="sec-head df-head-row"><div><h3>${icon("device")}${esc(t("sec_sessions"))}</h3><p class="muted">${esc(t("sec_sessions_sub"))}</p></div>
        ${S.sessions.length > 1 ? `<button type="button" class="btn small" data-a="revoke-others">${esc(t("sec_revoke_others"))}</button>` : ""}</div>${sessions}</section>
      <section class="sec"><div class="sec-head"><h3>${icon("lock")}${esc(t("sec_login"))}</h3><p class="muted">${esc(t("sec_login_sub", { n: S.limits.lock_after, f: S.limits.firewall_after }))}</p></div>
        <h4 class="df-h4">${esc(t("sec_locked"))}</h4>${locks}</section>
      <section class="sec"><div class="sec-head"><h3>${icon("send")}${esc(t("sec_notify"))}</h3></div><form class="subcard" data-f="sec-notify">${sw("notify_login", S.settings.notify_login, t("sec_notify_login"))}${sw("notify_lock", S.settings.notify_lock, t("sec_notify_lock"))}</form></section>
      <section class="sec"><div class="sec-head"><h3>${icon("shield")}${esc(t("sec_tips"))}</h3></div><ul class="df-covers">
        <li>${icon("okmark")}<span>${esc(t("sec_tip_ip"))} <a href="#defender" data-a="open-fw">${esc(t("sec_open_fw"))}</a></span></li><li>${icon("okmark")}<span>${esc(t("sec_tip_pw"))}</span></li><li>${icon("okmark")}<span>${esc(t("sec_tip_https"))}</span></li></ul></section>
      <section class="sec"><div class="sec-head"><h3>${icon("clock")}${esc(t("sec_log"))}</h3></div>${logRows}</section>`;
  }

  async function build() {
    S = await api("/api/security");
    return { html: html(), tools: "" };
  }
  const repaint = () => { if (root) root.innerHTML = html(); };

  function enable2fa() {
    openDialog({
      title: t("sec_2fa"), submit: t("sec_next"),
      body: `<p>${esc(t("sec_2fa_step1"))}</p>${field(t("sec_password"), '<input type="password" name="password" required autocomplete="current-password">')}`,
      onSubmit: async (form) => {
        const r = await post("/api/security/2fa/setup", { password: form.elements.password.value });
        setTimeout(() => step2(r), 50);
      },
    });
  }
  function step2(r) {
    const key = r.secret.match(/.{1,4}/g).join(" ");
    openDialog({
      title: t("sec_2fa"), submit: t("sec_2fa_enable"),
      body: `<p>${esc(t("sec_2fa_step2"))}</p>
        <div class="field"><label>${esc(t("sec_2fa_key"))}</label><div class="sec-key" dir="ltr">${esc(key)}</div>
        <p class="row-actions"><button type="button" class="btn small" data-copy="${esc(r.secret)}">${icon("copy")}<span>${esc(t("copy"))}</span></button>
          <a class="btn small" href="${esc(r.uri)}">${icon("key")}<span>${esc(t("sec_2fa_link"))}</span></a></p></div>
        ${field(t("sec_2fa_code"), '<input name="code" inputmode="numeric" autocomplete="one-time-code" required pattern="[0-9 ]{6,7}" maxlength="7" dir="ltr">')}
        <p class="muted">${esc(t("sec_2fa_lost"))}</p>`,
      onSubmit: async (form) => {
        S = await post("/api/security/2fa/enable", { code: form.elements.code.value });
        toast(t("sec_2fa_done"));
        repaint();
      },
    });
  }
  function disable2fa() {
    openDialog({
      title: t("sec_confirm_disable"), submit: t("sec_2fa_disable"), danger: true,
      body: `${field(t("sec_password"), '<input type="password" name="password" required autocomplete="current-password">')}${field(t("sec_2fa_code"), '<input name="code" inputmode="numeric" required maxlength="7" dir="ltr">')}`,
      onSubmit: async (form) => {
        S = await post("/api/security/2fa/disable", { password: form.elements.password.value, code: form.elements.code.value });
        toast(t("sec_2fa_off_done"));
        repaint();
      },
    });
  }

  function bind(r) {
    root = r;
    r.addEventListener("click", async (e) => {
      const b = e.target.closest("[data-a]");
      if (!b) return;
      const a = b.dataset.a;
      if (a === "open-fw") { try { localStorage.setItem("df_tab", "advanced"); } catch (x) { /* ignore */ } return; }
      e.preventDefault();
      if (a === "2fa-on") return enable2fa();
      if (a === "2fa-off") return disable2fa();
      if (a === "revoke") { const x = await act(b, () => post("/api/security/revoke", { id: b.dataset.id }), t("sec_revoked")); if (x) { S = x; repaint(); } }
      if (a === "revoke-others") {
        if (!(await confirmBox({ message: t("sec_revoke_others"), label: t("sec_revoke") }))) return;
        const x = await act(b, () => post("/api/security/revoke-others", {}), t("sec_revoked")); if (x) { S = x; repaint(); }
      }
      if (a === "unlock") { const x = await act(b, () => post("/api/security/unlock", { ip: b.dataset.ip }), t("sec_unlock")); if (x) { S = x; repaint(); } }
    });
    r.addEventListener("change", async (e) => {
      if (!e.target.closest('form[data-f="sec-notify"]')) return;
      const x = await act(e.target, () => post("/api/security/settings", { [e.target.name]: e.target.checked }), t("saved"));
      if (x) S = x; else e.target.checked = !e.target.checked;
    });
  }

  P.registerView({ id: "security", icon: "key", label: "sec_nav", desc: "sec_desc", group: "manage", static: true }, { build, bind }, "settings");
})();
__MONITORING_EOF__
  write_file panel/static/boot.js 644 <<'__MONITORING_EOF__'
// Runs in <head> before the first paint: applies the saved theme and language so the page never
// flashes the wrong theme (or flips direction) while the main script is still loading.
(function () {
  var d = document.documentElement, theme = null, lang = null;
  try { theme = localStorage.getItem("theme"); lang = localStorage.getItem("lang"); } catch (e) { /* storage blocked */ }
  if (theme !== "light" && theme !== "dark") {
    theme = window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
  }
  if (lang !== "fa" && lang !== "en") lang = "en";
  d.setAttribute("data-theme", theme);
  d.setAttribute("lang", lang);
  d.setAttribute("dir", lang === "fa" ? "rtl" : "ltr");
  var meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.setAttribute("content", theme === "dark" ? "#070b12" : "#eef2f8");
})();
__MONITORING_EOF__
  write_file panel/security.py 644 <<'__MONITORING_EOF__'
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
        with _lock:   # called before this login is logged, so every earlier row counts
            return any(r["kind"] == "login" and r.get("ip") == ip and r["t"] > cutoff for r in self.rows)


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
__MONITORING_EOF__
  write_file defender/Dockerfile 644 <<'__MONITORING_EOF__'
# Defender agent: only the tools it drives. Its Python code is mounted from ./defender, so updating
# the code needs a restart, not a rebuild.
FROM python:3.12-alpine
# ALPINE_MIRROR: an Alpine package mirror for servers where Alpine's CDN is blocked (set by the installer)
ARG ALPINE_MIRROR=
RUN if [ -n "$ALPINE_MIRROR" ]; then sed -i "s#https\?://dl-cdn.alpinelinux.org/alpine#${ALPINE_MIRROR%/}#" /etc/apk/repositories; fi  && apk add --no-cache nftables conntrack-tools iproute2 util-linux-misc
ENV PYTHONDONTWRITEBYTECODE=1
CMD ["python", "-u", "/app/agent.py"]
__MONITORING_EOF__
  write_file defender/agent.py 644 <<'__MONITORING_EOF__'
#!/usr/bin/env python3
"""Defender agent: firewall, anti-DDoS, SSH brute-force guard and kernel hardening for this server.

Runs as root in its own container with the host's network and PID namespaces (see docker-compose.yml)
and is controlled by the panel through a unix socket (DATA_DIR/agent.sock). Standard library only;
nft and conntrack come from the image.

Safety rules, in order of importance:
  * protection is off until someone turns it on in the panel;
  * the SSH and panel ports are always reachable, loopback / Docker / VPN tunnels are never filtered,
    and the IPs of logged-in SSH users are never banned;
  * every change to the rules is undone after ROLLBACK_SECONDS unless the panel confirms it is still
    reachable (the browser does that by itself right after applying);
  * all rules sit in their own table (inet defender), so removing it restores the server exactly:
        nft delete table inet defender
"""
import collections
import concurrent.futures
import copy
import ipaddress
import json
import os
import re
import signal
import socketserver
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler
from urllib.parse import unquote

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import f2b  # noqa: E402
import geo  # noqa: E402
import hostinfo  # noqa: E402
import nftlib  # noqa: E402
import nftrules  # noqa: E402
import sources  # noqa: E402
import sshmgr  # noqa: E402
import sysfw  # noqa: E402
import threat  # noqa: E402

VERSION = "1.0"
DATA = os.environ.get("DATA_DIR", "/data")
SOCK = os.path.join(DATA, "agent.sock")
PANEL_GID = int(os.environ.get("PANEL_GID", "65534"))
PANEL_PORTS = sorted({int(p) for p in re.findall(r"\d+", os.environ.get("PANEL_PORTS", "3000"))})
def ROLLBACK_SECONDS():  # noqa: N802 - kept as a "constant" name; the value lives in the configuration
    return int(CFG.get("advanced", {}).get("rollback_seconds", 60))
KEEP = 300                     # live samples (5 minutes)
def ADV(key):  # noqa: N802
    return CFG.get("advanced", {}).get(key, DEFAULT["advanced"][key])
LOCK = threading.RLock()

DEFAULT = {
    "enabled": False,
    "profile": "normal",
    "limits": dict(nftrules.PROFILES["normal"]),
    "auto_escalate": True,
    "ddos": {"drop_invalid": True, "bad_flags": True},
    "firewall": {"mode": "open", "ports": [], "trusted_ifaces": ["wg*", "gre*", "tun*", "ipip*", "ppp*", "tailscale*", "zt*"]},
    "allow": [],
    "block": [],
    "ssh_guard": {"enabled": True, "l4": True, "failures": 5, "window": 10, "ban": 60, "exempt_private": True},
    "trust_logged_in": True,
    "trust_cdn": True,
    "geo": {"block": []},     # replaced by "rules" (kept so old backups still import)
    "rules": [],              # user firewall rules, see validate_rule
    # threat-intelligence blocklists: the ones that are on, per list "block" (default) or "log" (only count),
    # also block this server connecting to them, the user's own lists, and how often to refresh them
    "threat": {"feeds": [], "mode": {}, "outbound": False, "custom": [], "refresh_hours": 12},
    # Expert settings (Advanced tab). Everything that used to be fixed can be changed here.
    "advanced": {
        "rollback_seconds": 60,       # 0 = apply changes without the safety test
        "ssh_rate": 12,               # new SSH connections per minute and source before a ban (0 = off)
        "ssh_ban_minutes": 60,
        "autoban_factor": 3,          # ban a source going this many times over a limit (0 = never ban, only drop)
        "detect_drops": 300, "detect_cookies": 50, "detect_pps": 20000, "detect_conntrack": 90, "calm_seconds": 30,
        "deescalate_minutes": 10,
        "trust_docker": True,         # never filter traffic from Docker bridges / veth
        "lock_ports": True,           # SSH and panel ports stay open whatever the mode
        "panel_allow": [],            # only these addresses may open the panel (empty = everyone)
        "custom_rules": "",           # extra nftables statements for new connections
    },
    "sysctl": {"applied": [], "original": {}},
    "notify": {"attacks": True, "bans": False},
}


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


# ------------------------------------------------------------------ persistence

def _path(name):
    return os.path.join(DATA, name)


def load_json(name, default):
    try:
        with open(_path(name)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return copy.deepcopy(default)


def save_json(name, obj):
    tmp = _path(name + ".tmp")
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=1)
    os.replace(tmp, _path(name))


def merged_default(cfg):
    out = copy.deepcopy(DEFAULT)
    for k, v in (cfg or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k].update(v)
        else:
            out[k] = v
    return out


CFG = merged_default(load_json("config.json", {}))
if CFG["geo"].get("block") and not CFG["rules"]:    # the old country blocklist becomes a rule
    CFG["rules"] = [{"id": "c0untr", "name": "Blocked countries", "enabled": True, "countries": list(CFG["geo"]["block"]),
                     "country_mode": "in", "ips": [], "ip_mode": "in", "proto": "any", "ports": "", "action": "block",
                     "limit": {"rate": 10, "burst": 20, "ban": 0}}]
    CFG["geo"]["block"] = []
BANS = load_json("bans.json", {})            # ip -> {until, reason, source}: bans the agent made (for the panel)
EVENTS = collections.deque(load_json("events.json", []), maxlen=400)
F2B = load_json("f2b.json", {"default": {}, "jails": {}})   # fail2ban settings the panel manages
STATE = {
    "applied": False, "error": "", "pending": None, "escalated": False, "escalated_at": 0,
    "attack": {"active": False, "since": 0, "ended": 0, "peak": {}, "reason": ""},
    "samples": collections.deque(maxlen=KEEP), "bans_count": 0, "started": time.time(),
}


def event(kind, **data):
    with LOCK:
        eid = (EVENTS[-1]["id"] + 1) if EVENTS else 1
        EVENTS.append({**data, "id": eid, "t": round(time.time(), 1), "kind": kind})   # data can never replace id/t/kind
        save_json("events.json", list(EVENTS))
    log("event", kind, data)


# ------------------------------------------------------------------ nft

def nft(args, stdin=None, check=True):
    """Runs an nft command. Simple commands (lists, adding and removing set elements) go through
    libnftables in this process; loading a whole ruleset (-f, -c) still uses the nft program."""
    if stdin is None and not any(a.startswith("-") for a in args[1:]) and (not args[0].startswith("-") or args[0] == "-j"):
        json_out = args[0] == "-j"
        res = nftlib.run(" ".join(args[1:] if json_out else args), json_out)
        if res is not None:
            ok, out, err = res
            if check and not ok:
                raise RuntimeError(err.strip()[-800:] or "nft command failed")
            return out
    p = subprocess.run(["nft"] + args, input=stdin, capture_output=True, text=True, timeout=20)
    if check and p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout).strip()[-800:] or f"nft exited with {p.returncode}")
    return p.stdout


def table_exists():
    """Only the table names: listing the table itself would print every element of the big sets."""
    try:
        return "table inet defender" in nft(["list", "tables", "inet"])
    except RuntimeError:
        return False


def current_bans(cfg=None):
    """Elements of every ban set: {set name: [(ip, whole ban seconds, seconds left)]}, so a rebuild of
    the table keeps them (with their real ban time) and the panel can show when and why."""
    out = {}
    if not table_exists():
        return out
    names = [f"{k}{v}" for k in nftrules.ban_sets(cfg or CFG) for v in ("4", "6")]
    names += [f"{k}{v}" for k in nftrules.ban_sets(CFG) for v in ("4", "6") if f"{k}{v}" not in names]
    for name in names:
        try:
            data = json.loads(nft(["-j", "list", "set", "inet", "defender", name]))
        except (RuntimeError, ValueError):
            continue
        rows = out.setdefault(name, [])
        for item in data.get("nftables", []):
            default = (item.get("set") or {}).get("timeout", 900)
            for el in (item.get("set") or {}).get("elem", []) or []:
                if isinstance(el, dict) and "elem" in el:
                    e = el["elem"]
                    total = e.get("timeout", default)
                    left = e.get("expires", total)
                    if isinstance(e.get("val"), str) and left and left > 1:
                        rows.append((e["val"], max(total, left), left))
                elif isinstance(el, str):
                    rows.append((el, default, default))
    return out


BAN_REASON = {"ban": None, "fban": "syn_flood", "cban": "conn_flood", "sban": "ssh_rate"}


def ban_kind(set_name):
    """("syn_flood" | "conn_flood" | "ssh_rate" | "rule" | None, rule) for a ban set name."""
    base = set_name[:-1]
    if base.startswith("rb_"):
        rule = next((r for r in CFG["rules"] if r.get("id") == base[3:]), None)
        return "rule", rule
    return BAN_REASON.get(base), None


def effective_limits():
    return dict(nftrules.PROFILES["attack"]) if STATE["escalated"] else dict(CFG["limits"])


def ruleset(cfg=None):
    cfg = cfg or CFG
    allow_extra = [{"ip": ip} for ip in admin_ips()] if cfg.get("trust_logged_in", True) else []
    view = dict(cfg, allow=cfg["allow"] + allow_extra)
    g4, g6, _ = geo.build(DATA, cfg.get("geo", {}).get("block", []), download=False)
    zones = {}
    for rule in cfg.get("rules") or []:
        if rule.get("enabled", True) and rule.get("countries"):
            z4, z6, _ = geo.build(DATA, rule["countries"], download=False)
            zones[rule["id"]] = (z4, z6)
    return nftrules.build(view, effective_limits(), current_bans(cfg), hostinfo.ssh_ports(), PANEL_PORTS, g4, g6, zones,
                          threat_lists(cfg), hostinfo.public_iface())


def threat_feeds(cfg=None):
    return threat.all_feeds((cfg or CFG)["threat"].get("custom"))


def threat_lists(cfg):
    """[(id, v4, v6, mode)] for the lists that are on and downloaded."""
    t = cfg.get("threat") or {}
    out = []
    for fid, (v4, v6) in threat.lists(DATA, t.get("feeds") or []).items():
        if v4 or v6:
            out.append((fid, v4, v6, (t.get("mode") or {}).get(fid, "block")))
    return out


def threat_download(cfg, force=False, only=None):
    """Downloads the lists that are on (when old, or force); returns the ids whose content changed."""
    feeds = threat.all_feeds(cfg["threat"].get("custom"))
    max_age = int(cfg["threat"].get("refresh_hours", 12)) * 3600
    todo = [f for f in cfg["threat"]["feeds"] if f in feeds and (only is None or f in only)]

    def one(fid):
        try:
            return fid if threat.fetch(DATA, fid, feeds[fid], max_age, force=force) else None
        except ValueError as e:     # one list down must not stop the others; the error shows on its card
            log("threat list", fid, e)
            return None
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:    # a slow server does not hold up the rest
        return [fid for fid in pool.map(one, todo) if fid]


def apply(cfg=None):
    """Make the kernel match the configuration (atomic: the whole table is replaced at once)."""
    cfg = cfg or CFG
    with LOCK:
        if not cfg["enabled"]:
            if table_exists():
                nft(["delete", "table", "inet", "defender"])
            STATE["applied"] = False
            STATE["error"] = ""
            return
        text = ruleset(cfg)
        nft(["-c", "-f", "-"], stdin=text)      # dry run against the kernel first
        nft(["-f", "-"], stdin=text)
        STATE["applied"] = True
        STATE["error"] = ""


def change(mutator, rollback=True, what="config"):
    """Apply a configuration change. With rollback the old rules come back unless confirmed in time."""
    global CFG
    with LOCK:
        prev = copy.deepcopy(CFG)
        new = copy.deepcopy(CFG)
        mutator(new)
        validate(new)
        if new["enabled"]:
            codes = set(new["geo"]["block"])
            for rule in new["rules"]:
                if rule.get("enabled", True):
                    codes.update(rule.get("countries") or [])
            if codes:
                geo.build(DATA, sorted(codes), download=True)   # raises before anything changes
            if new["threat"]["feeds"]:
                threat_download(new)          # only lists that are missing or old; raises if a new one cannot be had
        try:
            apply(new)
        except Exception as e:
            try:
                apply(prev)
            except Exception:
                pass
            raise ValueError(f"The new rules were rejected, nothing changed: {e}")
        CFG = new
        save_json("config.json", CFG)
        if rollback and ROLLBACK_SECONDS() > 0 and (new["enabled"] or prev["enabled"]):
            old_pending = STATE["pending"]
            STATE["pending"] = {"until": time.time() + ROLLBACK_SECONDS(),
                                "prev": old_pending["prev"] if old_pending else prev, "what": what}
        event("applied", what=what)
        return status()


def confirm():
    with LOCK:
        if STATE["pending"]:
            STATE["pending"] = None
            event("confirmed")
    return status()


def rollback(reason="timeout"):
    global CFG
    with LOCK:
        p = STATE["pending"]
        if not p:
            return status()
        STATE["pending"] = None
        CFG = p["prev"]
        save_json("config.json", CFG)
        try:
            apply(CFG)
        except Exception as e:
            STATE["error"] = str(e)
        event("rollback", reason=reason)
    return status()


# ------------------------------------------------------------------ validation

PORT_RE = re.compile(r"^\d{1,5}(-\d{1,5})?$")
IFACE_RE = re.compile(r"^[A-Za-z0-9_.\-]{1,15}\*?$")


def net_str(net):
    """1.2.3.4 for a single address, 10.0.0.0/8 for a network."""
    return str(net.network_address) if net.num_addresses == 1 else str(net)


def parse_net(value, allow_any=False):
    try:
        net = ipaddress.ip_network(str(value).strip(), strict=False)
    except ValueError:
        raise ValueError(f"Not an IP address or network: {value}")
    if not allow_any and net.prefixlen == 0:
        raise ValueError(f"{value} is the whole internet")
    return net


def validate(cfg):
    if cfg["profile"] not in list(nftrules.PROFILES) + ["custom"]:
        raise ValueError("unknown profile")
    for k, (lo, hi) in nftrules.LIMIT_KEYS.items():
        v = cfg["limits"].get(k)
        if not isinstance(v, (int, float)) or not lo <= v <= hi:
            raise ValueError(f"{k}: must be between {lo} and {hi}")
        cfg["limits"][k] = int(v)
    fw = cfg["firewall"]
    if fw["mode"] not in ("open", "strict"):
        raise ValueError("mode must be open or strict")
    seen = set()
    for p in fw["ports"]:
        p["port"] = str(p.get("port", "")).strip()
        if p.get("proto") not in ("tcp", "udp", "both") or not PORT_RE.match(p["port"]):
            raise ValueError(f"Invalid port: {p.get('port')}")
        a, _, b = p["port"].partition("-")
        if not (1 <= int(a) <= 65535) or (b and not int(a) < int(b) <= 65535):
            raise ValueError(f"Invalid port range: {p['port']}")
        if p.get("from"):
            p["from"] = net_str(parse_net(p["from"], allow_any=True))
        p["note"] = str(p.get("note", ""))[:80]
        key = (p["proto"], p["port"], p.get("from") or "")
        if key in seen:
            raise ValueError(f"Port {p['port']} is listed twice")
        seen.add(key)
    if len(fw["ports"]) > 5000:
        raise ValueError("too many ports")
    for i in fw["trusted_ifaces"]:
        if not IFACE_RE.match(i):
            raise ValueError(f"Invalid interface name: {i}")
    for lst in ("allow", "block"):
        for e in cfg[lst]:
            e["ip"] = net_str(parse_net(e["ip"], allow_any=(lst == "allow")))
            e["note"] = str(e.get("note", ""))[:80]
        if len(cfg[lst]) > 100000:
            raise ValueError("list too long")
    validate_threat(cfg["threat"])
    rules = cfg.get("rules") or []
    if not isinstance(rules, list) or len(rules) > 300:
        raise ValueError("At most 300 rules")
    seen_ids = set()
    for i, rule in enumerate(rules):
        rules[i] = validate_rule(rule)
        if rules[i]["id"] in seen_ids:
            rules[i]["id"] = __import__("secrets").token_hex(3)
        seen_ids.add(rules[i]["id"])
    codes = sorted({str(c).strip().lower() for c in cfg["geo"].get("block", [])})
    if len(codes) > 300 or not all(geo.CC_RE.match(c) for c in codes):
        raise ValueError("invalid country list")
    cfg["geo"]["block"] = codes
    a = cfg["advanced"]
    for k, lo, hi in (("rollback_seconds", 0, 3600), ("ssh_rate", 0, 100000), ("ssh_ban_minutes", 1, 525600), ("autoban_factor", 0, 1000),
                      ("detect_drops", 1, 10**9), ("detect_cookies", 1, 10**9), ("detect_pps", 1, 10**10), ("detect_conntrack", 1, 100),
                      ("calm_seconds", 5, 86400), ("deescalate_minutes", 0, 10080)):
        v = a.get(k, DEFAULT["advanced"][k])
        if not isinstance(v, (int, float)) or isinstance(v, bool) or not lo <= v <= hi:
            raise ValueError(f"{k}: must be between {lo} and {hi}")
        a[k] = int(v)
    for k in ("trust_docker", "lock_ports"):
        a[k] = bool(a.get(k, True))
    a["panel_allow"] = [net_str(parse_net(x, allow_any=True)) for x in a.get("panel_allow", []) if str(x).strip()][:5000]
    a["custom_rules"] = nftrules.check_custom(a.get("custom_rules", ""))
    g = cfg["ssh_guard"]
    for k, lo, hi in (("failures", 1, 100000), ("window", 1, 525600), ("ban", 1, 5256000)):
        if not isinstance(g.get(k), (int, float)) or not lo <= g[k] <= hi:
            raise ValueError(f"SSH guard {k}: must be between {lo} and {hi}")
        g[k] = int(g[k])


RULE_ID = re.compile(r"^[a-z0-9]{6}$")
PORTS_RE = re.compile(r"^\d{1,5}(-\d{1,5})?$")


def validate_rule(r):
    """A firewall rule: conditions (countries, addresses, protocol, ports; all must match) and one action."""
    if not isinstance(r, dict):
        raise ValueError("invalid rule")
    import secrets as _s
    out = {"id": r.get("id") if RULE_ID.match(str(r.get("id", ""))) else _s.token_hex(3),
           "name": str(r.get("name") or "").strip()[:80] or "Rule", "enabled": bool(r.get("enabled", True))}
    codes = sorted({str(c).strip().lower() for c in r.get("countries") or [] if str(c).strip()})
    if not all(geo.CC_RE.match(c) for c in codes):
        raise ValueError(f"{out['name']}: unknown country code")
    out["countries"] = codes
    out["country_mode"] = "not_in" if r.get("country_mode") == "not_in" else "in"
    out["ips"] = [net_str(parse_net(x, allow_any=True)) for x in (r.get("ips") or []) if str(x).strip()][:20000]
    out["ip_mode"] = "not_in" if r.get("ip_mode") == "not_in" else "in"
    proto = r.get("proto", "any")
    if proto not in ("any", "tcp", "udp", "icmp"):
        raise ValueError(f"{out['name']}: unknown protocol")
    out["proto"] = proto
    ports = [p.strip() for p in str(r.get("ports") or "").replace(" ", "").split(",") if p.strip()]
    for p in ports:
        a, _, b = p.partition("-")
        if not PORTS_RE.match(p) or not 1 <= int(a) <= 65535 or (b and not int(a) < int(b) <= 65535):
            raise ValueError(f"{out['name']}: invalid port {p}")
    if ports and proto == "icmp":
        raise ValueError(f"{out['name']}: ping (ICMP) has no ports")
    out["ports"] = ",".join(ports[:200])
    if not (codes or out["ips"] or out["ports"] or proto != "any"):
        raise ValueError(f"{out['name']}: a rule needs at least one condition (country, address, protocol or port)")
    act = r.get("action", "block")
    if act not in ("allow", "block", "limit", "log"):
        raise ValueError(f"{out['name']}: unknown action")
    out["action"] = act
    out["direction"] = "out" if r.get("direction") == "out" else "in"
    if out["direction"] == "out" and act == "limit":
        raise ValueError(f"{out['name']}: outgoing rules can allow, block or count, not limit")
    sched = r.get("schedule")
    if sched:
        days = sorted({int(d) for d in sched.get("days") or [] if str(d).isdigit() and 0 <= int(d) <= 6})
        frm, to = str(sched.get("from", "00:00")), str(sched.get("to", "23:59"))
        if not days or not re.match(r"^([01]\d|2[0-3]):[0-5]\d$", frm) or not re.match(r"^([01]\d|2[0-3]):[0-5]\d$", to) or frm == to:
            raise ValueError(f"{out['name']}: pick days and two different times (HH:MM)")
        out["schedule"] = {"days": days, "from": frm, "to": to}
    else:
        out["schedule"] = None
    try:
        out["expires"] = max(0, int(r.get("expires") or 0))
    except (TypeError, ValueError):
        raise ValueError(f"{out['name']}: invalid expiry")
    lim = r.get("limit") or {}
    try:
        rate, burst, ban = int(lim.get("rate", 10)), int(lim.get("burst", 0) or 0), int(lim.get("ban", 0) or 0)
    except (TypeError, ValueError):
        raise ValueError(f"{out['name']}: invalid limit")
    if not 1 <= rate <= 1_000_000 or not 0 <= ban <= 525600:
        raise ValueError(f"{out['name']}: the limit must be 1 to 1000000 per second, the ban 0 to 525600 minutes")
    out["limit"] = {"rate": rate, "burst": max(1, min(burst or rate * 2, 10_000_000)), "ban": ban}
    return out


def own_or_admin(ip):
    """True for addresses that must never be blocked: this server, logged-in users, the allowlist."""
    net = ipaddress.ip_network(ip, strict=False)
    for a in hostinfo.local_addresses() + admin_ips():
        try:
            if ipaddress.ip_address(a) in net:
                return True
        except ValueError:
            pass
    return any(net.subnet_of(parse_net(a["ip"], True)) for a in CFG["allow"]
               if ipaddress.ip_network(a["ip"], strict=False).version == net.version)


_admin = {"at": 0, "ips": []}
TRUST_DAYS = 7   # an address that logged in over SSH is trusted this long (whoever logs in is root anyway)


def admin_ips():
    """Never limited or banned: users logged in right now (utmp) and addresses with a successful SSH
    login in the last TRUST_DAYS (scripts and tools that run commands over SSH never show up in utmp)."""
    if time.time() - _admin["at"] > 15:
        now = time.time()
        for ip in [ip for ip, t in list(GUARD["recent_ok"].items()) if now - t >= TRUST_DAYS * 86400]:
            GUARD["recent_ok"].pop(ip, None)     # trust ends after TRUST_DAYS; nothing piles up over the years
        recent = set(GUARD["recent_ok"])
        _admin.update(at=now, ips=sorted(set(hostinfo.ssh_sessions()) | recent))
    return _admin["ips"]


def seed_recent_logins():
    """Successful logins already in the log (current and previous file) count as recent."""
    now = time.time()
    for name in ("/var/log/auth.log.1", "/var/log/auth.log"):
        for ip in OK_RE.findall(hostinfo.read(name, 50_000_000) or ""):
            try:
                ipaddress.ip_address(ip)
            except ValueError:
                continue
            GUARD["recent_ok"][ip] = now


# ------------------------------------------------------------------ bans

def ban(ip, minutes, reason, source, detail=""):
    net = parse_net(ip)
    if net.num_addresses > 1:
        raise ValueError("Temporary bans are for single addresses; use the blocklist for networks")
    addr = str(net.network_address)
    if own_or_admin(addr):
        raise ValueError(f"{addr} is this server, a logged-in user or on the allowlist; it is never banned")
    if not STATE["applied"]:
        raise ValueError("Turn protection on first")
    name = "ban4" if net.version == 4 else "ban6"
    nft(["add", "element", "inet", "defender", name, f"{{ {addr} timeout {int(minutes)}m }}"])
    with LOCK:
        BANS[addr] = {"at": time.time(), "until": time.time() + minutes * 60, "reason": reason, "source": source, "detail": detail}
        save_json("bans.json", BANS)
    return addr


def unban(ip):
    addr = str(parse_net(ip).network_address)
    if table_exists():        # whatever banned it: every ban set of its family
        v = "6" if ":" in addr else "4"
        for kind in nftrules.ban_sets(CFG):
            nft(["delete", "element", "inet", "defender", f"{kind}{v}", f"{{ {addr} }}"], check=False)
    with LOCK:
        BANS.pop(addr, None)
        save_json("bans.json", BANS)
    event("unban", ip=addr)


def ban_list():
    now = time.time()
    rows = []
    for name, items in current_bans().items():
        kind, rule = ban_kind(name)
        for ip, total, left in items:
            meta = BANS.get(ip, {}) if kind is None else {}
            rows.append({"ip": ip, "left": int(left), "total": int(total), "at": round(now - (total - left)), "detail": meta.get("detail", ""),
                         "source": meta.get("source", "auto") if kind is None else "auto",
                         "reason": meta.get("reason", "rate") if kind is None else kind,
                         **({"rule": rule["name"] if rule else "?"} if kind == "rule" else {})})
    with LOCK:   # forget metadata of bans that ended
        live = {r["ip"] for r in rows}
        ended = [k for k, v in BANS.items() if v["until"] < now or (STATE["applied"] and k not in live and v["until"] - now < 5)]
        for k in ended:
            BANS.pop(k, None)
        if ended:
            save_json("bans.json", BANS)
    try:
        f2b_rows = f2b.all_bans()
        for r in f2b_rows:
            rows.append({"ip": r["ip"], "left": int(r["until"] - now) if r["until"] else None, "at": r.get("at"),
                         "source": "fail2ban", "reason": r["jail"], "jail": r["jail"]})
    except Exception:
        f2b_rows = None
    if f2b_rows is None:
        for ip in hostinfo.fail2ban_bans():
            rows.append({"ip": ip, "left": None, "source": "fail2ban", "reason": "fail2ban"})
    return sorted(rows, key=lambda r: (r["source"] == "fail2ban", -(r["left"] or 0)))


# ------------------------------------------------------------------ SSH guard (auth.log)

IP = r"([0-9a-fA-F:.]+)"
FAIL_RE = re.compile("|".join([
    rf"Failed (?:password|publickey|none) for (?:invalid user )?\S+ from {IP}",
    rf"Invalid user \S* ?from {IP}",
    rf"maximum authentication attempts exceeded for (?:invalid user )?\S+ from {IP}",
    rf"(?:Connection closed by|Disconnected from) (?:authenticating|invalid) user \S* ?{IP} port \d+ \[preauth\]",
    rf"Did not receive identification string from {IP}",
    rf"banner exchange: Connection from {IP} port \d+: invalid format",
]))
OK_RE = re.compile(r"Accepted \S+ for \S+ from ([0-9a-fA-F:.]+)")
GUARD = {"failures": collections.defaultdict(collections.deque), "seen_24h": collections.deque(maxlen=200000),
         "available": False, "recent_ok": {}}


def ssh_guard_loop():
    path = hostinfo.host_path("/var/log/auth.log")
    f, inode = None, None
    while True:
        try:
            st = os.stat(path)
            if f is None or st.st_ino != inode or st.st_size < f.tell():
                if f:
                    f.close()
                f = open(path, errors="replace")
                if inode is None:
                    f.seek(0, os.SEEK_END)     # first start: only new lines count
                inode = st.st_ino
                GUARD["available"] = True
            for line in f.readlines():
                ssh_line(line)
        except OSError:
            GUARD["available"] = False
            f, inode = None, None
        time.sleep(2)     # auth.log once every 2 s is plenty for a ban after N wrong passwords


def ssh_line(line):
    m = OK_RE.search(line)
    if m:
        GUARD["recent_ok"][m.group(1)] = time.time()
        GUARD["failures"].pop(m.group(1), None)
        return
    m = FAIL_RE.search(line)
    if not m:
        return
    ip = next(g for g in m.groups() if g)
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return
    now = time.time()
    GUARD["seen_24h"].append((now, ip))
    g = CFG["ssh_guard"]
    if not g["enabled"] or not STATE["applied"]:
        return
    if g.get("exempt_private") and (addr.is_private or addr in ipaddress.ip_network("100.64.0.0/10")):
        return
    if now - GUARD["recent_ok"].get(ip, 0) < 86400:
        return   # logged in successfully from here today: a typo is not an attack
    q = GUARD["failures"][ip]
    q.append(now)
    while q and now - q[0] > g["window"] * 60:
        q.popleft()
    if len(GUARD["failures"]) > 5000:     # years of scanners: drop addresses with nothing left in the window
        for k in [k for k, v in GUARD["failures"].items() if not v or now - v[-1] > g["window"] * 60]:
            GUARD["failures"].pop(k, None)
    if len(q) >= g["failures"]:
        GUARD["failures"].pop(ip, None)
        try:
            ban(ip, g["ban"], "ssh", "ssh", detail=f"{len(q)}/{g['window']}")
            event("ssh_ban", ip=ip, failures=len(q), minutes=g["ban"])
        except Exception as e:
            log("ssh guard: cannot ban", ip, e)


def ssh_stats():
    now = time.time()
    per = collections.Counter(ip for t, ip in GUARD["seen_24h"] if now - t < 86400)
    return {"available": GUARD["available"], "failures_24h": sum(per.values()),
            "top": [{"ip": ip, "n": n} for ip, n in per.most_common(10)]}


# ------------------------------------------------------------------ live statistics and attack detection

DROP_KEYS = ("block", "ban", "geo", "threat", "invalid", "badflags", "ssh", "policy", "syn", "conn", "conc", "udp", "icmp", "autoban")


def read_counters():
    if not STATE["applied"]:
        return {}
    try:
        data = json.loads(nft(["-j", "list", "counters", "table", "inet", "defender"]))
    except (RuntimeError, ValueError):
        return {}
    out = {}
    for item in data.get("nftables", []):
        c = item.get("counter")
        if c and c.get("name", "").startswith("c_"):
            out[c["name"][2:]] = c.get("packets", 0)
    mode = CFG["threat"]["mode"]
    out["threat"] = sum(v for k, v in out.items() if k.startswith("t_") and mode.get(k[2:], "block") == "block")
    return out


WATCH_SECONDS = 20     # the firewall page asked for live numbers this recently: sample every second


def stats_loop():
    """Samples traffic and the firewall's counters, and detects attacks. Every second while someone
    watches the firewall page or something looks wrong; every 3 seconds otherwise (a third of the work;
    the first sign of an attack switches back to every second)."""
    prev, prev_t = None, None
    calm, hot, base = 0, 0, None
    last_bans = last_expire = 0
    step = 1
    iface = hostinfo.public_iface()
    while True:
        t0 = time.time()
        try:
            cur = {"c": read_counters(), "dev": hostinfo.iface_counters(iface) if iface else None, "tcp": hostinfo.tcp_counters()}
            if prev:
                dt = max(0.2, t0 - prev_t)
                rate = lambda a, b: max(0, (a - b) / dt) if a is not None and b is not None else None
                drops = {k: rate(cur["c"].get(k), prev["c"].get(k)) or 0 for k in DROP_KEYS} if cur["c"] and prev["c"] else {}
                ct = hostinfo.conntrack_usage()
                s = {
                    "t": round(t0, 2),
                    "pps": rate((cur["dev"] or {}).get("rx_packets"), (prev["dev"] or {}).get("rx_packets")),
                    "bps": rate((cur["dev"] or {}).get("rx_bytes"), (prev["dev"] or {}).get("rx_bytes")),
                    "conns": rate(cur["tcp"]["passive_opens"], prev["tcp"]["passive_opens"]),
                    "cookies": rate(cur["tcp"]["syncookies_sent"], prev["tcp"]["syncookies_sent"]),
                    "new": rate(cur["c"].get("new"), prev["c"].get("new")) if cur["c"] and prev["c"] else None,
                    "drop": sum(drops.values()) if drops else 0,
                    "drops": {k: round(v, 1) for k, v in drops.items() if v},
                    "ct": round(ct["count"] / ct["max"] * 100, 1) if ct else None,
                    "estab": cur["tcp"]["curr_estab"],
                }
                if t0 - last_bans > (5 if step == 1 else 30):
                    last_bans = t0
                    STATE["bans_count"] = sum(len(v) for v in current_bans().values())
                s["bans"] = STATE["bans_count"]
                STATE["samples"].append(s)
                # attack detection with hysteresis
                pps = s["pps"] or 0
                if base is None:
                    base = pps
                signals = []
                if s["drop"] > ADV("detect_drops"):
                    signals.append("drops")
                if (s["cookies"] or 0) > ADV("detect_cookies"):
                    signals.append("syn_flood")
                if pps > ADV("detect_pps") and pps > 6 * max(base, 1000):
                    signals.append("traffic")
                if (s["ct"] or 0) > ADV("detect_conntrack"):
                    signals.append("conntrack")
                att = STATE["attack"]
                if signals:
                    hot, calm = hot + 1, 0
                else:
                    calm, hot = calm + dt, 0
                    base = base * 0.995 + pps * 0.005
                if att["active"]:
                    for k in ("pps", "drop", "conns", "cookies"):
                        att["peak"][k] = max(att["peak"].get(k, 0), s.get(k) or 0)
                if not att["active"] and hot >= 3:
                    att.update(active=True, since=t0, peak={k: s.get(k) or 0 for k in ("pps", "drop", "conns", "cookies")}, reason=",".join(signals))
                    event("attack_start", reason=att["reason"], pps=round(pps), drop=round(s["drop"]),
                          top=[r["ip"] for r in hostinfo.top_sources(5, 0)])
                    if CFG["auto_escalate"] and CFG["enabled"] and CFG["profile"] != "attack" and not STATE["escalated"]:
                        STATE.update(escalated=True, escalated_at=t0)
                        try:
                            apply()
                            event("escalate")
                        except Exception as e:
                            STATE["escalated"] = False
                            log("escalate failed", e)
                elif att["active"] and calm >= ADV("calm_seconds"):
                    att.update(active=False, ended=t0)
                    event("attack_end", seconds=round(t0 - att["since"]), peak={k: round(v) for k, v in att["peak"].items()})
                if STATE["escalated"] and not att["active"] and t0 - att["ended"] > ADV("deescalate_minutes") * 60:
                    STATE["escalated"] = False
                    try:
                        apply()
                        event("deescalate")
                    except Exception as e:
                        log("de-escalate failed", e)
            prev, prev_t = cur, t0
            p = STATE["pending"]
            if p and time.time() > p["until"]:
                rollback("timeout")
            if STATE.get("ssh_pending") and time.time() > STATE["ssh_pending"]["until"]:
                try:
                    ssh_revert("timeout")
                except Exception as e:
                    log("ssh revert", e)
            if t0 - last_expire >= 30:
                last_expire = t0
                expire_rules()
            busy = hot or STATE["attack"]["active"] or STATE["pending"] or STATE.get("ssh_pending")
            step = 1 if busy or t0 - STATE.get("watched", 0) < WATCH_SECONDS else 3
        except Exception as e:  # never let the loop die
            log("stats error", type(e).__name__, e)
        time.sleep(max(0.05, step - (time.time() - t0)))


def expire_rules():
    """Temporary rules switch themselves off when their time is up."""
    now = time.time()
    if not any(r.get("enabled", True) and r.get("expires") and r["expires"] < now for r in CFG["rules"]):
        return
    names = [r["name"] for r in CFG["rules"] if r.get("enabled", True) and r.get("expires") and r["expires"] < now]

    def mut(c):
        for r in c["rules"]:
            if r.get("enabled", True) and r.get("expires") and r["expires"] < now:
                r["enabled"] = False
    try:
        change(mut, rollback=False, what="rules expired")
        event("rule_expired", names=names)
    except Exception as e:
        log("expire rules", e)


def admin_refresh_loop():
    """Logged-in users' IPs are part of the allowlist in the kernel; refresh it when they change."""
    last = None
    while True:
        time.sleep(20)
        try:
            ips = tuple(admin_ips()) if CFG.get("trust_logged_in", True) else ()
            if ips != last and last is not None and STATE["applied"] and not STATE["pending"]:
                apply()
            last = ips
        except Exception as e:
            log("admin refresh", e)


# ------------------------------------------------------------------ status for the panel

def status():
    with LOCK:
        p = STATE["pending"]
        return {
            "version": VERSION, "enabled": CFG["enabled"], "applied": STATE["applied"], "error": STATE["error"],
            "pending": {"left": max(0, round(p["until"] - time.time())), "what": p["what"]} if p else None,
            "profile": CFG["profile"], "escalated": STATE["escalated"], "limits": CFG["limits"],
            "effective": effective_limits(), "profiles": nftrules.PROFILES,
            "attack": {k: v for k, v in STATE["attack"].items()},
            "config": {k: CFG[k] for k in ("auto_escalate", "ddos", "firewall", "ssh_guard", "trust_logged_in", "trust_cdn", "geo", "notify", "advanced", "rules", "threat")},
            "allow": CFG["allow"], "block": CFG["block"],
            "ssh_ports": hostinfo.ssh_ports(), "panel_ports": PANEL_PORTS, "admin_ips": admin_ips(),
            "iface": hostinfo.public_iface(), "interfaces": hostinfo.interfaces(),
            "bans": STATE["bans_count"], "fail2ban": hostinfo.fail2ban_present(),
            "last_event": EVENTS[-1]["id"] if EVENTS else 0, "uptime": round(time.time() - STATE["started"]),
        }


_sysfw_cache = {"at": 0, "st": None}


def sysfw_status(fresh=False):
    """The server's own firewall (ufw / firewalld / iptables), cached for 15 s (it runs host commands)."""
    if fresh or not _sysfw_cache["st"] or time.time() - _sysfw_cache["at"] > 15:
        try:
            _sysfw_cache.update(st=sysfw.status(), at=time.time())
        except Exception as e:  # nsenter or a tool missing: show no system firewall rather than failing the page
            log("system firewall:", e)
            _sysfw_cache.update(st={"active": None, "ufw": {"installed": False}, "firewalld": {"installed": False},
                                    "iptables_policy": None, "_input": ""}, at=time.time())
    return _sysfw_cache["st"]


def ports_view():
    sys_st = sysfw_status()
    published = hostinfo.docker_published()
    fw = CFG["firewall"]
    rows = []
    for r in hostinfo.listening():
        if not r["public"]:
            continue
        r = dict(r)
        r["docker"] = (r["proto"], r["port"]) in published or r["process"] == "docker-proxy"
        r["always"] = r["proto"] == "tcp" and (r["port"] in hostinfo.ssh_ports() or r["port"] in PANEL_PORTS)
        r["allowed"] = r["always"] or any(_port_match(p, r) for p in fw["ports"])
        r["restricted"] = not r["allowed"] and any(_port_match(dict(p, **{"from": ""}), r) for p in fw["ports"] if p.get("from"))
        # published Docker ports go around ufw/firewalld (Docker adds its own rules before them)
        r["sys"] = None if r["docker"] else sysfw.port_open(sys_st, r["proto"], r["port"])
        rows.append(r)
    for proto, port in sorted(published):
        if not any(r["proto"] == proto and r["port"] == port for r in rows):
            rows.append({"proto": proto, "port": port, "addrs": [], "public": True, "process": "docker", "docker": True,
                         "always": port in PANEL_PORTS and proto == "tcp",
                         "allowed": any(_port_match(p, {"proto": proto, "port": port}) for p in fw["ports"]), "sys": None})
    return {"rows": rows, "sysfw": {k: v for k, v in sys_st.items() if not k.startswith("_")}}


def api_open_port(b):
    """Opens a port everywhere it can be closed: our firewall (strict mode) and the server's own firewall
    (ufw / firewalld / iptables) - what `ufw allow 8080/tcp` does by hand."""
    port, src = sysfw._check(b.get("port"), b.get("proto", "tcp"), b.get("from", ""))
    src = net_str(parse_net(src, allow_any=True)) if src else ""     # the same spelling the config uses
    proto = b.get("proto", "tcp")
    note = str(b.get("note", ""))[:80]
    done = sysfw.allow(port, proto, src) if b.get("system", True) else {"done": [], "firewall": None}
    _sysfw_cache["at"] = 0

    def mut(c):
        ports = [p for p in c["firewall"]["ports"] if not (str(p["port"]) == port and p["proto"] == proto and p.get("from", "") == src)]
        c["firewall"]["ports"] = ports + [{"port": port, "proto": proto, "from": src, "note": note}]
    if CFG["firewall"]["mode"] == "strict" or src or b.get("ours"):
        change(mut, rollback=False, what=f"open port {port}")
    event("port_opened", port=port, proto=proto, src=src, system=done["firewall"])
    listening = any(r["public"] and (r["proto"] == proto or proto == "both") and _port_match({"proto": r["proto"], "port": port}, r)
                    for r in hostinfo.listening(max_age=0))
    return {**ports_view(), "done": done["done"], "firewall": done["firewall"], "listening": listening}


def api_close_port(b):
    port, src = sysfw._check(b.get("port"), b.get("proto", "tcp"), b.get("from", ""))
    src = net_str(parse_net(src, allow_any=True)) if src else ""     # the same spelling the config uses
    proto = b.get("proto", "tcp")
    done = sysfw.remove(port, proto, src)
    _sysfw_cache["at"] = 0

    def mut(c):
        c["firewall"]["ports"] = [p for p in c["firewall"]["ports"] if not (str(p["port"]) == port and p["proto"] == proto and p.get("from", "") == src)]
    if any(str(p["port"]) == port and p["proto"] == proto and p.get("from", "") == src for p in CFG["firewall"]["ports"]):
        change(mut, rollback=False, what=f"close port {port}")
    event("port_closed", port=port, proto=proto, src=src, system=done["firewall"])
    return {**ports_view(), "done": done["done"], "firewall": done["firewall"]}


def api_ufw(b):
    action = b.get("action")
    if action == "delete":
        sysfw.ufw_delete(str(b.get("text", "")))
    elif action == "enable":
        # everything that is reachable now stays reachable: SSH, the panel and every public port in use
        keep = set(hostinfo.ssh_ports()) | set(PANEL_PORTS)
        rows = [r for r in hostinfo.listening(max_age=0) if r["public"]]
        keep |= {r["port"] for r in rows if r["proto"] == "tcp"}
        sysfw.ufw_enable(sorted(keep))
        for r in rows:
            if r["proto"] == "udp":
                sysfw.allow(str(r["port"]), "udp")
    elif action == "disable":
        sysfw.ufw_disable()
    else:
        raise ValueError("Unknown action")
    _sysfw_cache["at"] = 0
    event("ufw", action=action)
    return ports_view()


def _port_match(p, r):
    if p["proto"] not in (r["proto"], "both") or p.get("from"):
        return False
    a, _, b = p["port"].partition("-")
    return int(a) <= r["port"] <= int(b or a)


# ------------------------------------------------------------------ API over the unix socket

def validate_threat(t):
    custom = []
    for c in (t.get("custom") or [])[:threat.MAX_CUSTOM]:
        cid, url = str(c.get("id", "")), str(c.get("url", "")).strip()
        if not threat.ID_RE.match(cid) or cid in threat.FEEDS or any(x["id"] == cid for x in custom):
            raise ValueError(f"Invalid list id: {cid}")
        if not url.startswith("https://") or len(url) > 400:
            raise ValueError("The list address must start with https://")
        custom.append({"id": cid, "name": str(c.get("name", "")).strip()[:60] or cid, "url": url})
    t["custom"] = custom
    known = threat.all_feeds(custom)
    t["feeds"] = [f for f in dict.fromkeys(t.get("feeds") or []) if f in known]
    t["mode"] = {k: v for k, v in (t.get("mode") or {}).items() if k in known and v in ("block", "log")}
    t["outbound"] = bool(t.get("outbound", False))
    try:
        t["refresh_hours"] = min(168, max(1, int(t.get("refresh_hours", 12))))
    except (TypeError, ValueError):
        raise ValueError("Refresh interval must be a number of hours")


def _cfg_patch(body):
    """Only known keys can be changed from the panel."""
    def mut(c):
        for k in ("enabled", "auto_escalate", "trust_logged_in", "trust_cdn"):
            if k in body:
                c[k] = bool(body[k])
        if "profile" in body:
            c["profile"] = str(body["profile"])
            if c["profile"] in nftrules.PROFILES:
                c["limits"] = dict(nftrules.PROFILES[c["profile"]])
        if "limits" in body:
            c["limits"] = {k: body["limits"].get(k, c["limits"][k]) for k in nftrules.LIMIT_KEYS}
            c["profile"] = next((n for n, v in nftrules.PROFILES.items() if v == c["limits"]), "custom")
        if "ddos" in body:
            c["ddos"].update({k: bool(body["ddos"][k]) for k in ("drop_invalid", "bad_flags") if k in body["ddos"]})
        if "firewall" in body:
            fw = body["firewall"]
            if "mode" in fw:
                c["firewall"]["mode"] = str(fw["mode"])
            if "ports" in fw:
                c["firewall"]["ports"] = [{"proto": str(p.get("proto", "tcp")), "port": str(p.get("port", "")),
                                           "from": str(p.get("from") or ""), "note": str(p.get("note") or "")} for p in fw["ports"]]
            if "trusted_ifaces" in fw:
                c["firewall"]["trusted_ifaces"] = [str(i).strip() for i in fw["trusted_ifaces"] if str(i).strip()]
        if "ssh_guard" in body:
            g = body["ssh_guard"]
            for k in ("enabled", "l4", "exempt_private"):
                if k in g:
                    c["ssh_guard"][k] = bool(g[k])
            for k in ("failures", "window", "ban"):
                if k in g:
                    c["ssh_guard"][k] = g[k]
        if "notify" in body:
            c["notify"].update({k: bool(v) for k, v in body["notify"].items() if k in ("attacks", "bans")})
        if isinstance(body.get("advanced"), dict):
            for k, v in body["advanced"].items():
                if k in DEFAULT["advanced"]:
                    c["advanced"][k] = v
        if isinstance(body.get("rules"), list):
            c["rules"] = body["rules"]
        if isinstance(body.get("threat"), dict) and isinstance(body["threat"].get("feeds"), list):
            c["threat"]["feeds"] = [str(f) for f in body["threat"]["feeds"]]
        if isinstance(body.get("threat"), dict):
            tb = body["threat"]
            if isinstance(tb.get("mode"), dict):
                c["threat"]["mode"] = {str(k): str(v) for k, v in tb["mode"].items()}
            for k in ("outbound", "refresh_hours"):
                if k in tb:
                    c["threat"][k] = tb[k]
        if "geo" in body and isinstance(body["geo"], dict) and "block" in body["geo"]:
            c["geo"]["block"] = [str(x) for x in body["geo"]["block"]][:200]
    return mut


def api_list_add(body, lst):
    net = parse_net(body.get("ip", ""), allow_any=(lst == "allow"))
    if lst == "block" and own_or_admin(net_str(net)):
        raise ValueError(f"{net_str(net)} includes this server, a logged-in user or an allowlisted address")
    minutes = body.get("minutes")
    if lst == "block" and minutes:
        addr = ban(net_str(net), int(minutes), str(body.get("note", "")) or "manual", "manual")
        event("ban", ip=addr, minutes=int(minutes))
        return status()

    def mut(c):
        c[lst] = [e for e in c[lst] if e["ip"] != net_str(net)] + [{"ip": net_str(net), "note": str(body.get("note", ""))[:80], "added": int(time.time())}]
    out = change(mut, rollback=False, what=lst)
    event("block" if lst == "block" else "allow", ip=net_str(net))
    return out


def api_list_remove(body, lst):
    ip = net_str(parse_net(body.get("ip", ""), allow_any=True))
    out = change(lambda c: c.__setitem__(lst, [e for e in c[lst] if e["ip"] != ip]), rollback=False, what=lst)
    if lst == "block" and "/" not in ip:
        unban(ip)
    return out


def api_sysctl(body):
    keys = [k for k, _, _ in hostinfo.SYSCTLS]
    want = [k for k in body.get("keys", keys) if k in keys]
    rec = {k: r for k, r, _ in hostinfo.SYSCTLS}
    with LOCK:
        sc = CFG["sysctl"]
        if body.get("action") in ("custom_set", "custom_del"):
            key = str(body.get("key", "")).strip()
            if not re.match(r"^(net|kernel|vm|fs)\.[A-Za-z0-9_.\-]{1,120}$", key) or ".." in key or not os.path.exists("/proc/sys/" + key.replace(".", "/")):
                raise ValueError(f"Unknown kernel setting: {key}")
            custom = sc.setdefault("custom", {})
            if body["action"] == "custom_set":
                value = str(body.get("value", "")).strip()
                if not value or len(value) > 200 or "\n" in value:
                    raise ValueError("Invalid value")
                sc["original"].setdefault(key, hostinfo.sysctl_get(key))
                try:
                    hostinfo.sysctl_set(key, value)
                except OSError as e:
                    raise ValueError(f"{key}: {e}")
                custom[key] = value
            else:
                custom.pop(key, None)
                if sc["original"].get(key) is not None:
                    try:
                        hostinfo.sysctl_set(key, sc["original"][key])
                    except OSError:
                        pass
            event("sysctl", action=body["action"].replace("custom_", "custom "), n=1)
        elif body.get("action") == "restore":
            for k in want:
                if k in sc["original"]:
                    try:
                        hostinfo.sysctl_set(k, sc["original"][k])
                    except OSError as e:
                        raise ValueError(f"{k}: {e}")
                sc["applied"] = [a for a in sc["applied"] if a != k]
            event("sysctl", action="restore", n=len(want))
        else:
            for k in want:
                cur = hostinfo.sysctl_get(k)
                if cur is None:
                    continue
                sc["original"].setdefault(k, cur)
                if not hostinfo.sysctl_ok(k, cur, rec[k]):
                    try:
                        hostinfo.sysctl_set(k, rec[k])
                    except OSError as e:
                        raise ValueError(f"{k}: {e}")
                if k not in sc["applied"]:
                    sc["applied"].append(k)
            event("sysctl", action="apply", n=len(want))
        save_json("config.json", CFG)
    return {"rows": hostinfo.sysctl_report(), "applied": CFG["sysctl"]["applied"], "custom": CFG["sysctl"].get("custom", {})}


def reapply_sysctl():
    for k, v in (CFG["sysctl"].get("custom") or {}).items():
        try:
            hostinfo.sysctl_set(k, v)
        except OSError as e:
            log("sysctl", k, e)
    rec = {k: r for k, r, _ in hostinfo.SYSCTLS}
    for k in CFG["sysctl"]["applied"]:
        try:
            if not hostinfo.sysctl_ok(k, hostinfo.sysctl_get(k), rec[k]):
                hostinfo.sysctl_set(k, rec[k])
        except (OSError, KeyError) as e:
            log("sysctl", k, e)


def api_audit():
    checks = hostinfo.audit({"enabled": STATE["applied"], "mode": CFG["firewall"]["mode"]})
    for c in checks:   # fail2ban: installed but stopped is worse than not installed (it looks like protection)
        if c["id"] == "fail2ban" and f2b.installed() and not f2b.running():
            c.update(id="fail2ban_stopped", sev=2)
    return {"checks": checks, "score": hostinfo.score(checks), "sysctl": hostinfo.sysctl_report(),
            "sysctl_applied": CFG["sysctl"]["applied"], "sysctl_custom": CFG["sysctl"].get("custom", {})}


def api_live(q):
    STATE["watched"] = time.time()      # someone has the firewall page open: sample every second
    since = float(q.get("since", 0) or 0)
    return {"samples": [s for s in STATE["samples"] if s["t"] > since], "attack": STATE["attack"],
            "escalated": STATE["escalated"], "applied": STATE["applied"], "bans": STATE["bans_count"],
            "pending": status()["pending"]}


# ------------------------------------------------------------------ fail2ban, countries, backup

def f2b_view(force=False):
    return {**f2b.overview(F2B, force), "admin_ips": admin_ips()}


def f2b_jail_name(name, must_run=False):
    name = str(name or "")
    if not f2b.NAME_RE.match(name):
        raise ValueError("invalid jail name")
    running = f2b.jail_names() if f2b.running() else []
    if must_run and name not in running:
        raise ValueError(f"The jail {name} is not running")
    if name not in running and name not in f2b.PRESETS and name not in F2B["jails"] and not f2b.jail_config(name)[1]:
        raise ValueError(f"Unknown jail: {name}")
    return name


def f2b_save(mutate, what):
    global F2B
    with LOCK:
        new = copy.deepcopy(F2B)
        mutate(new)
        f2b.validate(new)
        if not f2b.installed():
            raise ValueError("fail2ban is not installed")
        f2b.write_settings(new)
        F2B = new
        save_json("f2b.json", F2B)
    event("f2b_config", what=what)
    return f2b_view(force=True)


def api_f2b_jail(b):
    name = str(b.get("name") or "").strip()
    if b.get("create"):
        if not f2b.NAME_RE.match(name) or name.upper() == "DEFAULT":
            raise ValueError("Jail names use letters, digits, - _ . (up to 40)")
        if name in (f2b.jail_names() if f2b.running() else []) or name in F2B["jails"] or f2b.jail_config(name)[1]:
            raise ValueError(f"A jail named {name} already exists")
    else:
        name = f2b_jail_name(name)
    upd = {k: b[k] for k in f2b.JAIL_KEYS + ("extra",) if k in b}

    def mut(m):
        if b.get("replace") or b.get("create"):
            m["jails"][name] = upd
        else:
            m["jails"].setdefault(name, {}).update(upd)
    return f2b_save(mut, f"{'new ' if b.get('create') else ''}jail {name}")


def api_f2b_jail_delete(b):
    global F2B
    name = f2b_jail_name(b.get("name"))
    with LOCK:
        new = copy.deepcopy(F2B)
        res = f2b.delete_jail(name, new)
        F2B = new
        save_json("f2b.json", F2B)
    event("f2b_config", what=f"deleted jail {name}")
    return {**f2b_view(force=True), **res}


def api_f2b_defaults(b):
    upd = {k: b[k] for k in f2b.DEFAULT_KEYS if k in b}
    return f2b_save(lambda m: m["default"].update(upd), "defaults")


def api_f2b_ban(b):
    name = f2b_jail_name(b.get("jail"), must_run=True)
    addr = net_str(parse_net(b.get("ip", "")))
    if "/" in addr:
        raise ValueError("fail2ban bans single addresses")
    if own_or_admin(addr):
        raise ValueError(f"{addr} is this server, a logged-in user or on the allowlist; it is never banned")
    f2b.call("set", name, "banip", addr)
    event("f2b_ban", jail=name, ip=addr, manual=True)
    return {"ok": True}


def api_f2b_unban(b):
    addr = net_str(parse_net(b.get("ip", "")))
    if b.get("jail"):
        f2b.call("set", f2b_jail_name(b["jail"], must_run=True), "unbanip", addr)
    else:
        f2b.call("unban", addr)
    event("f2b_unban", ip=addr, jail=b.get("jail") or "")
    return {"ok": True}


def api_f2b_service(b):
    action = str(b.get("action", ""))
    f2b.service(action)
    event("f2b_service", action=action)
    time.sleep(1.5 if action in ("start", "restart") else 0)
    return f2b_view(force=True)


def api_f2b_install(b):
    job = f2b.install()
    event("f2b_service", action="install")
    return {"job": job}


def api_f2b_uninstall(b):
    job = f2b.uninstall(bool(b.get("purge")))
    event("f2b_service", action="purge" if b.get("purge") else "uninstall")
    return {"job": job}


def api_f2b_file_save(b):
    out = f2b.file_write(b.get("path"), b.get("text", ""))
    event("f2b_config", what=f"file {out['path']}")
    return out


def api_f2b_file_delete(b):
    out = f2b.file_delete(b.get("path"))
    event("f2b_config", what=f"deleted {b.get('path')}")
    return out


def api_f2b_bans(q):
    return {"rows": f2b.jail_bans(f2b_jail_name(q.get("jail"), must_run=True))}


def api_fwrules(q):
    """The rules with how many packets each one matched since the rules were last applied."""
    hits = {}
    if STATE["applied"]:
        try:
            data = json.loads(nft(["-j", "list", "counters", "table", "inet", "defender"]))
            for item in data.get("nftables", []):
                c = item.get("counter")
                if c and c.get("name", "").startswith("c_r_"):
                    hits[c["name"][4:]] = {"packets": c.get("packets", 0), "bytes": c.get("bytes", 0)}
        except (RuntimeError, ValueError):
            pass
    codes = sorted({c for r in CFG["rules"] for c in r.get("countries") or []})
    return {"rules": CFG["rules"], "hits": hits, "zones": geo.info(DATA, codes), "enabled": CFG["enabled"]}


# ------------------------------------------------------------------ SSH server management

def ssh_busy_ports():
    return {r["port"] for r in hostinfo.listening() if r["proto"] == "tcp" and r["process"] not in ("sshd", "systemd")}


def _f2b_ssh_ports(ports):
    """fail2ban's sshd jail bans on "port = ssh" (22): keep it on the real SSH ports."""
    try:
        if f2b.installed() and f2b.running() and "sshd" in f2b.jail_names():
            f2b_save(lambda m: m["jails"].setdefault("sshd", {}).update({"port": ",".join(str(p) for p in ports)}), "ssh port")
            return ""
    except Exception as e:
        return f"fail2ban could not be updated: {e}"
    return ""


def api_sshd(q):
    return {**sshmgr.state(STATE.get("ssh_pending")), "confirm_seconds": sshmgr.CONFIRM_SECONDS}


def api_sshd_apply(b):
    if STATE.get("ssh_pending"):
        raise ValueError("Keep or undo the previous SSH change first")
    before = sshmgr.effective()
    settings = sshmgr.validate(b, ssh_busy_ports())
    hostinfo._ports_cache["at"] = 0

    def open_ports():   # the firewall must let the new port in before sshd moves there
        hostinfo._ports_cache["at"] = 0
        if CFG["enabled"]:
            apply()
    with LOCK:
        old = sshmgr.apply(settings, before_restart=open_ports)
        STATE["ssh_pending"] = {"until": time.time() + sshmgr.CONFIRM_SECONDS, "old": old, "ports": settings["ports"],
                                "old_ports": before.get("port", [22])}
    warn = _f2b_ssh_ports(settings["ports"]) if settings["ports"] != before.get("port", [22]) else ""
    event("ssh_change", ports=settings["ports"])
    return {**api_sshd({}), "warning": warn}


def api_sshd_confirm(b):
    with LOCK:
        if STATE.get("ssh_pending"):
            STATE["ssh_pending"] = None
            event("ssh_confirmed")
    return api_sshd({})


def ssh_revert(reason="manual"):
    with LOCK:
        p = STATE.get("ssh_pending")
        if not p:
            return
        STATE["ssh_pending"] = None
        sshmgr.restore(p["old"])
        hostinfo._ports_cache["at"] = 0
        if CFG["enabled"]:
            apply()
    if p["ports"] != p["old_ports"]:
        _f2b_ssh_ports(p["old_ports"])
    event("ssh_reverted", reason=reason)


def api_sshd_revert(b):
    ssh_revert("manual")
    return api_sshd({})


def api_sshd_key_add(b):
    out = sshmgr.add_key(b.get("key", ""))
    event("ssh_key", action="added")
    return {"keys": out}


def api_sshd_key_remove(b):
    out = sshmgr.remove_key(int(b.get("index", -1)), sshmgr.effective().get("passwordauthentication"))
    event("ssh_key", action="removed")
    return {"keys": out}


# ------------------------------------------------------------------ threat lists

def _seen(name):
    """Addresses in one of the "recently matched" sets, with the seconds left of their hour."""
    rows = []
    if not STATE["applied"]:
        return rows
    for v in ("4", "6"):
        try:
            data = json.loads(nft(["-j", "list", "set", "inet", "defender", f"{name}{v}"]))
        except (RuntimeError, ValueError):
            continue
        for item in data.get("nftables", []):
            for el in (item.get("set") or {}).get("elem", []) or []:
                e = el.get("elem") if isinstance(el, dict) else None
                if e and isinstance(e.get("val"), str):
                    rows.append((e["val"], e.get("expires", 0)))
                elif isinstance(el, str):
                    rows.append((el, 0))
    return rows


def api_threat(q):
    t = CFG["threat"]
    feeds = threat_feeds()
    counters = read_counters()
    info = threat.info(DATA, feeds)
    on = t["feeds"]
    for fid, f in info.items():
        f.update(enabled=fid in on, mode=t["mode"].get(fid, "block"), hits=counters.get(f"t_{fid}"))
    recent = []
    for kind, name in (("block", "tseen"), ("log", "tlog")):
        for ip, left in sorted(_seen(name), key=lambda r: -r[1])[:100]:
            try:
                hit = threat.member(DATA, on, ip)
            except ValueError:
                hit = []
            recent.append({"ip": ip, "kind": kind, "ago": max(0, 3600 - int(left)), "lists": hit})
    recent.sort(key=lambda r: r["ago"])
    blocking = [f for f in on if t["mode"].get(f, "block") == "block"]
    return {"feeds": info, "order": list(feeds), "enabled": on, "protection": CFG["enabled"], "applied": STATE["applied"],
            "outbound": t["outbound"], "refresh_hours": t["refresh_hours"], "custom_max": threat.MAX_CUSTOM,
            "blocked": counters.get("threat"), "blocked_out": counters.get("tout"), "recent": recent[:150],
            "addresses": sum(info[f]["addresses"] for f in blocking if f in info),
            "entries": sum(info[f]["v4"] + info[f]["v6"] for f in blocking if f in info),
            "next_check": THREAT_STATE["next"], "refreshing": THREAT_STATE["busy"]}


THREAT_STATE = {"next": 0, "busy": False}


def threat_update_sets(changed):
    """New content of lists that are on goes into their sets in place, in one transaction: the
    table, counters, bans and live limits stay as they are (a full rebuild would reset them)."""
    if not changed or not CFG["enabled"] or not STATE["applied"] or STATE["pending"]:
        return
    lists_ = threat.lists(DATA, changed)
    cmds = []
    for fid in changed:
        v4, v6 = lists_.get(fid, ([], []))
        for v, items in (("4", v4), ("6", v6)):
            cmds.append(f"flush set inet defender t_{fid}{v}")
            for i in range(0, len(items), 5000):
                cmds.append(f"add element inet defender t_{fid}{v} {{ {', '.join(items[i:i + 5000])} }}")
    try:
        nft(["-f", "-"], stdin="\n".join(cmds) + "\n")
    except RuntimeError as e:      # a set is missing (the list was empty before): rebuild the table
        log("threat sets: in-place update failed, rebuilding:", str(e)[:200])
        apply()


def threat_refresh(force=False, only=None):
    with THREAT_LOCK:
        THREAT_STATE["busy"] = True
        try:
            changed = threat_download(CFG, force=force, only=only)
            if changed:
                event("threat_updated", lists=changed)
                with LOCK:
                    threat_update_sets(changed)
            return changed
        finally:
            THREAT_STATE["busy"] = False


THREAT_LOCK = threading.Lock()


def threat_refresh_loop():
    """Checks every 30 minutes which lists that are on are older than their refresh interval."""
    THREAT_STATE["next"] = int(time.time()) + 120
    time.sleep(120)
    while True:
        THREAT_STATE["next"] = int(time.time()) + 1800
        try:
            if CFG["threat"]["feeds"] and CFG["enabled"]:
                threat_refresh()
        except Exception as e:
            log("threat refresh", e)
        time.sleep(1800)


def api_threat_refresh(b):
    fid = b.get("id")
    if fid and fid not in CFG["threat"]["feeds"]:
        raise ValueError("That list is not on")
    if THREAT_STATE["busy"]:
        raise ValueError("The lists are being updated right now; try again in a moment")
    changed = threat_refresh(force=True, only=[fid] if fid else None)
    return {**api_threat({}), "changed": changed}


def api_threat_custom_add(b):
    name = str(b.get("name", "")).strip()[:60]
    if not name:
        raise ValueError("Give the list a name")
    url = threat.check_url(b.get("url"))
    if len(CFG["threat"]["custom"]) >= threat.MAX_CUSTOM:
        raise ValueError(f"At most {threat.MAX_CUSTOM} lists of your own")
    if any(c["url"] == url for c in CFG["threat"]["custom"]):
        raise ValueError("This list is already added")
    used = {c["id"] for c in CFG["threat"]["custom"]}
    cid = next(f"my{i}" for i in range(1, 100) if f"my{i}" not in used)
    feed = threat.all_feeds([{"id": cid, "name": name, "url": url}])[cid]
    threat.remove(DATA, cid)
    threat.fetch(DATA, cid, feed, 0, force=True)       # raises (with the reason) if it cannot be read

    def mut(c):
        c["threat"]["custom"].append({"id": cid, "name": name, "url": url})
        c["threat"]["mode"][cid] = "log"            # someone else's list: watch what it would block first
        c["threat"]["feeds"].append(cid)
    try:
        change(mut, rollback=False, what="threat list added")
    except Exception:
        threat.remove(DATA, cid)
        raise
    event("threat_list", action="added", name=name)
    return api_threat({})


def api_threat_custom_remove(b):
    cid = str(b.get("id", ""))
    if not any(c["id"] == cid for c in CFG["threat"]["custom"]):
        raise ValueError("No such list")

    def mut(c):
        c["threat"]["custom"] = [x for x in c["threat"]["custom"] if x["id"] != cid]
        c["threat"]["feeds"] = [f for f in c["threat"]["feeds"] if f != cid]
        c["threat"]["mode"].pop(cid, None)
    change(mut, rollback=False, what="threat list removed")
    threat.remove(DATA, cid)
    event("threat_list", action="removed", list=cid)
    return api_threat({})


# ------------------------------------------------------------------ "what happens to this address?"

def _in(ip, nets):
    a = ipaddress.ip_address(ip)
    for n in nets:
        try:
            if a in ipaddress.ip_network(n, strict=False):
                return n
        except ValueError:
            pass
    return None


def country_of(ip):
    """Country of an address, from the country lists already downloaded (None when not known)."""
    a = ipaddress.ip_address(ip)
    d = os.path.join(DATA, "geo")
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return None
    for n in names:
        if n.endswith(f".{a.version}"):
            for line in open(os.path.join(d, n)):
                line = line.strip()
                if line and a in ipaddress.ip_network(line):
                    return n.split(".")[0]
    return None


def api_test(b):
    ip = net_str(parse_net(b.get("ip", ""), allow_any=True))
    if "/" in ip:
        raise ValueError("Enter a single address")
    port = int(b.get("port") or 0)
    proto = b.get("proto") if b.get("proto") in ("tcp", "udp", "icmp") else "tcp"
    steps, verdict = [], None

    def step(kind, result, **kw):
        steps.append({"kind": kind, "result": result, **kw})
        return result

    cc = country_of(ip)
    if not CFG["enabled"]:
        return {"ip": ip, "country": cc, "verdict": "allow", "steps": [{"kind": "off", "result": "allow"}]}
    if CFG.get("trust_logged_in", True) and ip in admin_ips():
        verdict = step("admin", "allow")
    if not verdict and _in(ip, [a["ip"] for a in CFG["allow"]]):
        verdict = step("allowlist", "allow", entry=_in(ip, [a["ip"] for a in CFG["allow"]]))
    if not verdict and _in(ip, [x["ip"] for x in CFG["block"]]):
        verdict = step("blocklist", "block", entry=_in(ip, [x["ip"] for x in CFG["block"]]))
    if not verdict:
        ban = next((r for r in ban_list() if r["ip"] == ip), None)
        if ban:
            verdict = step("fail2ban" if ban["source"] == "fail2ban" else "banned", "block", left=ban["left"], jail=ban.get("jail"), source=ban["source"])
    adv = CFG["advanced"]
    if not verdict and port in PANEL_PORTS and proto == "tcp" and adv.get("panel_allow") and not _in(ip, adv["panel_allow"]):
        verdict = step("panel_allow", "block")
    if not verdict and CFG.get("trust_cdn", True) and _in(ip, list(nftrules.CDN4) + list(nftrules.CDN6)):
        verdict = step("cdn", "allow")
    if not verdict:
        names = threat_feeds()
        hits = threat.member(DATA, CFG["threat"]["feeds"], ip)
        blocking = [f for f in hits if CFG["threat"]["mode"].get(f, "block") == "block"]
        watching = [f for f in hits if f not in blocking]
        if watching:
            step("threat_log", "count", feeds=[names[f]["name"] for f in watching])
        if blocking:
            verdict = step("threat", "block", feeds=[names[f]["name"] for f in blocking])
    if not verdict:
        for r in CFG["rules"]:
            if not r.get("enabled", True) or r.get("direction") == "out":
                continue
            if r["countries"]:
                inside = cc in r["countries"] if cc else None
                if inside is None and r["country_mode"] == "in":
                    continue
                if inside is not None and inside != (r["country_mode"] == "in"):
                    continue
            if r["ips"] and bool(_in(ip, r["ips"])) != (r["ip_mode"] == "in"):
                continue
            if r["proto"] != "any" and r["proto"] != proto:
                continue
            if r["ports"] and not any(int(x.split("-")[0]) <= port <= int(x.split("-")[-1]) for x in r["ports"].split(",")):
                continue
            res = {"allow": "allow", "block": "block", "limit": "limit", "log": "count"}[r["action"]]
            step("rule", res, name=r["name"], schedule=r.get("schedule"), limit=r.get("limit") if r["action"] == "limit" else None)
            if res in ("allow", "block"):
                verdict = res
                break
    fw = CFG["firewall"]
    if not verdict and fw["mode"] == "strict" and proto in ("tcp", "udp") and port:
        locked = proto == "tcp" and adv.get("lock_ports", True) and (port in hostinfo.ssh_ports() or port in PANEL_PORTS)
        listed = any(_port_match(p, {"proto": proto, "port": port}) for p in fw["ports"]) or any(
            p.get("from") and _in(ip, [p["from"]]) and _port_match(dict(p, **{"from": ""}), {"proto": proto, "port": port}) for p in fw["ports"])
        if not (locked or listed):
            verdict = step("strict", "block", port=port)
    if not verdict:
        verdict = step("limits", "allow", limits=effective_limits())
    return {"ip": ip, "country": cc, "port": port, "proto": proto, "verdict": verdict, "steps": steps}


def api_geo(q):
    return {"block": CFG["geo"]["block"], "info": geo.info(DATA, CFG["geo"]["block"])}


def load_cdn(download=False):
    """Cloudflare's address ranges: the last downloaded copy (data/cdn.json), refreshed weekly from
    cloudflare.com; the list built into nftrules stays in use when nothing could ever be downloaded."""
    path = _path("cdn.json")
    cur = load_json("cdn.json", {})
    if download and time.time() - cur.get("at", 0) > 7 * 86400:
        try:
            def nets(text, version):
                out = []
                for line in text.split():
                    try:
                        n = ipaddress.ip_network(line.strip(), strict=False)
                    except ValueError:
                        continue
                    if n.version == version and n.prefixlen >= (8 if version == 4 else 16):
                        out.append(str(n))
                return out
            v4 = nets(sources.fetch(["https://www.cloudflare.com/ips-v4", "https://www.cloudflare.com/ips-v4/"],
                                    check=lambda t: len(nets(t, 4)) >= 5, timeout=20), 4)
            v6 = nets(sources.fetch(["https://www.cloudflare.com/ips-v6", "https://www.cloudflare.com/ips-v6/"],
                                    check=lambda t: len(nets(t, 6)) >= 3, timeout=20), 6)
            cur = {"at": time.time(), "v4": v4, "v6": v6}
            save_json("cdn.json", cur)
        except Exception as e:  # unreachable: keep the copy we have (or the built-in list)
            log("cloudflare ranges:", str(e)[:200])
    changed = False
    if cur.get("v4") and os.path.exists(path):
        new4, new6 = tuple(cur["v4"]), tuple(cur.get("v6") or nftrules.CDN6)
        changed = (new4, new6) != (nftrules.CDN4, nftrules.CDN6)
        nftrules.CDN4, nftrules.CDN6 = new4, new6
    return changed


def geo_refresh_loop():
    """Country lists change slowly; refresh them weekly and re-apply when one changed."""
    while True:
        time.sleep(6 * 3600)
        try:
            if load_cdn(download=True) and CFG["enabled"] and CFG.get("trust_cdn", True) and not STATE["pending"]:
                apply()
        except Exception as e:
            log("cloudflare refresh", e)
        try:
            codes = sorted(set(CFG["geo"]["block"]) | {c for r in CFG["rules"] if r.get("enabled", True) for c in r.get("countries") or []})
            if not codes or not CFG["enabled"]:
                continue
            before = geo.info(DATA, codes)
            geo.build(DATA, codes, download=True)
            if geo.info(DATA, codes) != before and not STATE["pending"]:
                apply()
        except Exception as e:
            log("geo refresh", e)


EXPORT_KEYS = ("enabled", "profile", "limits", "auto_escalate", "ddos", "firewall", "allow", "block", "ssh_guard",
               "trust_logged_in", "trust_cdn", "geo", "notify", "advanced", "rules", "threat")


def api_export(q):
    return {"app": "server-monitor-firewall", "version": 1, "exported": int(time.time()),
            "config": {k: CFG[k] for k in EXPORT_KEYS}, "fail2ban": F2B}


def api_import(b):
    data = b.get("data") or {}
    if data.get("app") != "server-monitor-firewall" or not isinstance(data.get("config"), dict):
        raise ValueError("This is not a firewall backup file")
    incoming = data["config"]

    def mut(c):
        for k in EXPORT_KEYS:
            if k in incoming:
                if isinstance(c.get(k), dict) and isinstance(incoming[k], dict):
                    c[k] = {**c[k], **incoming[k]}
                else:
                    c[k] = incoming[k]
    out = change(mut, rollback=True, what="import")
    if isinstance(data.get("fail2ban"), dict) and f2b.installed():
        try:
            f2b_save(lambda m: m.update({"default": data["fail2ban"].get("default", {}), "jails": data["fail2ban"].get("jails", {})}), "import")
        except ValueError as e:
            out = dict(out, warning=f"fail2ban settings not imported: {e}")
    return out


def on_f2b_ban(jail, ip):
    event("f2b_ban", jail=jail, ip=ip)


GET = {
    "/status": lambda q: status(),
    # what the panel's notifier polls every 10 s: no scanning of the host
    "/brief": lambda q: {"enabled": CFG["enabled"], "notify": CFG["notify"], "last_event": EVENTS[-1]["id"] if EVENTS else 0},
    "/live": api_live,
    "/bans": lambda q: {"rows": ban_list(), "block": CFG["block"], "allow": CFG["allow"], "admin_ips": admin_ips()},
    "/ports": lambda q: ports_view(),
    "/audit": lambda q: api_audit(),
    "/talkers": lambda q: {"rows": hostinfo.top_sources()},
    "/events": lambda q: {"rows": [e for e in EVENTS if e["id"] > int(q.get("since", 0) or 0)][-200:]},
    "/rules": lambda q: {"text": ruleset() if CFG["enabled"] else ruleset(dict(CFG, enabled=True))},
    "/ssh": lambda q: {**ssh_stats(), "config": CFG["ssh_guard"], "fail2ban": hostinfo.fail2ban_present()},
    "/f2b": lambda q: f2b_view(),
    "/f2b/bans": api_f2b_bans,
    "/f2b/log": lambda q: {"text": f2b.log_tail()},
    "/f2b/jail": lambda q: f2b.jail_detail(f2b_jail_name(q.get("jail")), F2B),
    "/f2b/files": lambda q: {"rows": f2b.files(), "backups": f2b.BACKUPS},
    "/f2b/file": lambda q: f2b.file_read(q.get("path")),
    "/geo": api_geo,
    "/fwrules": api_fwrules,
    "/sshd": api_sshd,
    "/threat": api_threat,
    "/export": api_export,
}
POST = {
    "/config": lambda b: change(_cfg_patch(b), rollback=bool(b.get("_rollback", True)), what=str(b.get("_what", "config"))[:40]),
    "/confirm": lambda b: confirm(),
    "/revert": lambda b: rollback("manual"),
    "/block": lambda b: api_list_add(b, "block"),
    "/unblock": lambda b: api_list_remove(b, "block"),
    "/allow": lambda b: api_list_add(b, "allow"),
    "/unallow": lambda b: api_list_remove(b, "allow"),
    "/unban": lambda b: (unban(b.get("ip", "")), status())[1],
    "/sysctl": api_sysctl,
    "/f2b/service": api_f2b_service,
    "/f2b/install": api_f2b_install,
    "/f2b/uninstall": api_f2b_uninstall,
    "/f2b/jail": api_f2b_jail,
    "/f2b/jail/delete": api_f2b_jail_delete,
    "/f2b/file": api_f2b_file_save,
    "/f2b/file/delete": api_f2b_file_delete,
    "/f2b/defaults": api_f2b_defaults,
    "/f2b/ban": api_f2b_ban,
    "/f2b/unban": api_f2b_unban,
    "/import": api_import,
    "/sshd/apply": api_sshd_apply,
    "/sshd/confirm": api_sshd_confirm,
    "/sshd/revert": api_sshd_revert,
    "/sshd/key/add": api_sshd_key_add,
    "/sshd/key/remove": api_sshd_key_remove,
    "/threat/refresh": api_threat_refresh,
    "/port/open": api_open_port,
    "/port/close": api_close_port,
    "/sysfw/ufw": api_ufw,
    "/threat/custom/add": api_threat_custom_add,
    "/threat/custom/remove": api_threat_custom_remove,
    "/test": api_test,
}


class Handler(BaseHTTPRequestHandler):
    server_version = "defender"

    def log_message(self, fmt, *args):
        pass

    def address_string(self):
        return "panel"

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _route(self, table, arg):
        path = self.path.split("?", 1)[0]
        fn = table.get(path)
        if not fn:
            return self._send(404, {"error": "not found"})
        try:
            return self._send(200, fn(arg))
        except ValueError as e:
            return self._send(400, {"error": str(e)})
        except Exception as e:
            log("api error", path, type(e).__name__, e)
            return self._send(500, {"error": f"{type(e).__name__}: {e}"})

    def do_GET(self):
        q = {}
        if "?" in self.path:
            for part in self.path.split("?", 1)[1].split("&"):
                k, _, v = part.partition("=")
                q[k] = unquote(v)
        self._route(GET, q)

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
            if n > 8_000_000:
                raise ValueError
            body = json.loads(self.rfile.read(n) or b"{}")
            if not isinstance(body, dict):
                raise ValueError
        except ValueError:
            return self._send(400, {"error": "bad request"})
        self._route(POST, body)


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def main():
    os.makedirs(DATA, exist_ok=True)
    os.chmod(DATA, 0o711)
    try:
        os.unlink(SOCK)
    except FileNotFoundError:
        pass
    srv = Server(SOCK, Handler)
    os.chown(SOCK, 0, PANEL_GID)
    os.chmod(SOCK, 0o660)
    reapply_sysctl()
    seed_recent_logins()
    load_cdn()      # the last downloaded copy of Cloudflare's ranges, if there is one
    try:
        apply()
        if CFG["enabled"]:
            event("started", protection="on")
    except Exception as e:
        STATE["error"] = str(e)
        log("cannot apply rules:", e)
    for target in (stats_loop, ssh_guard_loop, admin_refresh_loop, geo_refresh_loop, threat_refresh_loop):
        threading.Thread(target=target, daemon=True).start()
    threading.Thread(target=f2b.watch_log, args=(on_f2b_ban,), daemon=True).start()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))   # the rules stay in the kernel while the agent restarts
    log(f"defender {VERSION} ready on {SOCK}; protection {'on' if CFG['enabled'] else 'off'}, "
        f"ssh ports {hostinfo.ssh_ports()}, panel ports {PANEL_PORTS}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
__MONITORING_EOF__
  write_file defender/nftrules.py 644 <<'__MONITORING_EOF__'
"""Builds the nftables ruleset of the Defender from its configuration.

Everything lives in one table, `inet defender`, with one base chain on the prerouting hook at
priority -150: after conntrack (-200), before Docker's DNAT (-100). So it sees the original
destination port of traffic for the host *and* for published container ports, and it can only ever
drop packets: other tables (Docker, fail2ban, ufw) keep working exactly as before.

Order of the chain (first match wins):
  loopback / Docker bridges / trusted interfaces  -> accept   (never touched)
  allowlist                                        -> accept
  blocklist, temporary bans                        -> drop
  established / related                            -> accept   (only NEW traffic is limited below)
  invalid state, impossible TCP flag combinations  -> drop
  SSH: too many new connections per source         -> ban
  strict mode: TCP/UDP to a port that is not open  -> drop
  per source: SYN rate, new connection rate, concurrent connections, new UDP flows, ping rate
                                                   -> drop (and ban at 3x the limit)
"""
import ipaddress
import re

PROFILES = {
    # per source IP. syn/conn/udp/icmp: packets or new flows per second (burst = 2x). conc: open TCP connections.
    "normal": {"syn": 60, "conn": 100, "conc": 400, "udp": 300, "icmp": 20, "ban": 15},
    "strict": {"syn": 25, "conn": 40, "conc": 150, "udp": 120, "icmp": 6, "ban": 30},
    "attack": {"syn": 10, "conn": 15, "conc": 60, "udp": 40, "icmp": 2, "ban": 60},
}
LIMIT_KEYS = {"syn": (1, 100000), "conn": (1, 100000), "conc": (5, 1000000), "udp": (1, 1000000),
              "icmp": (1, 10000), "ban": (1, 10080)}
AUTOBAN_FACTOR = 3        # a source going this many times over a limit is banned, not just slowed down
SSH_NEW_PER_MIN = 12      # new SSH connections per source and minute before the source is banned
COUNTERS = ("allow", "block", "ban", "geo", "tout", "panel", "custom", "invalid", "badflags", "ssh", "policy", "syn", "conn", "conc",
            "udp", "icmp", "autoban", "new", "all")
ALWAYS_TRUSTED = ("lo", "docker*", "br-*", "veth*")
# Cloudflare's edge (https://www.cloudflare.com/ips/). A site or proxy behind Cloudflare receives all of its
# visitors from these addresses, so per-source limits would hit thousands of users at once.
CDN4 = ("173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22", "141.101.64.0/18", "108.162.192.0/18",
        "190.93.240.0/20", "188.114.96.0/20", "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
        "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22")
CDN6 = ("2400:cb00::/32", "2606:4700::/32", "2803:f800::/32", "2405:b500::/32", "2405:8100::/32", "2a06:98c0::/29", "2c0f:f248::/32")


FORBIDDEN = re.compile(r"^\s*(table|chain|flush|delete|include|define|add\s+(table|chain|rule)|insert|replace|reset|list)\b", re.I)


def check_custom(text):
    """Custom rules: nft statements, one per line, that run inside the Firewall's chain for new connections.
    They are checked by the kernel with the whole ruleset (nft -c) before anything is applied; here we only
    make sure a line cannot leave the chain (unbalanced braces, table/chain commands)."""
    out = []
    for raw in str(text or "").replace("\r", "").split("\n"):
        ln = raw.strip()
        if not ln or ln.startswith("#"):
            continue
        if FORBIDDEN.match(ln) or ln.count("{") != ln.count("}") or ";" in ln:
            raise ValueError(f"Not allowed in a custom rule: {ln[:80]}")
        out.append(ln)
    if len(out) > 500:
        raise ValueError("At most 500 custom rules")
    return "\n".join(out)


def ports_expr(items):
    """['22', '8000-8100'] -> '{ 22, 8000-8100 }' (nft set syntax)."""
    return "{ " + ", ".join(items) + " }"


def iface_rules(ifaces, trust_docker=True):
    out = []
    base = ALWAYS_TRUSTED if trust_docker else ("lo",)
    for name in list(base) + [i for i in ifaces if i not in base]:
        out.append(f'        iifname "{name}" accept')
    return out


def split_ips(items):
    v4, v6 = [], []
    for it in items:
        net = ipaddress.ip_network(it, strict=False)
        (v4 if net.version == 4 else v6).append(str(net) if net.num_addresses > 1 else str(net.network_address))
    return v4, v6


def set_block(name, family, items, extra=""):
    elements = f" elements = {{ {', '.join(items)} }};" if items else ""
    return f"    set {name} {{ type {family}_addr; flags interval;{extra}{elements} }}"


DAYS = ("Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday")


def schedule_parts(sched):
    """[[nft time matches], ...] for a rule's schedule; a range over midnight becomes two ranges."""
    if not sched:
        return [[]]
    day = f'meta day {{ {", ".join(f'"{DAYS[d]}"' for d in sched["days"])} }}' if sched.get("days") and len(sched["days"]) < 7 else ""
    a, b = sched.get("from", "00:00"), sched.get("to", "23:59")
    ranges = [(a, b)] if a < b else [(a, "23:59:59"), ("00:00", b)]
    out = []
    for x, y in ranges:
        hour = f'meta hour "{x}"-"{y}"' if (x, y) != ("00:00", "23:59") else ""
        out.append([m for m in (day, hour) if m])
    return out


def rule_parts(rule, zones):
    """Set declarations and chain lines for one user rule (see agent.validate_rule for its fields).
    Incoming rules match the source; outgoing rules (direction "out") match the destination."""
    rid = rule["id"]
    out_dir = rule.get("direction") == "out"
    who = "daddr" if out_dir else "saddr"
    sets, lines = [f"    counter c_r_{rid} {{ }}"], []
    c4, c6 = zones.get(rid, ([], []))
    i4, i6 = split_ips(rule.get("ips") or [])
    if rule.get("countries"):
        sets += [set_block(f"r_{rid}_c4", "ipv4", c4, " auto-merge;"), set_block(f"r_{rid}_c6", "ipv6", c6, " auto-merge;")]
    if rule.get("ips"):
        sets += [set_block(f"r_{rid}_i4", "ipv4", i4), set_block(f"r_{rid}_i6", "ipv6", i6)]
    act = rule["action"]
    if act == "limit":
        sets += [f"    set r_{rid}_m4 {{ type ipv4_addr; flags dynamic, timeout; timeout 2m; size 262144; }}",
                 f"    set r_{rid}_m6 {{ type ipv6_addr; flags dynamic, timeout; timeout 2m; size 262144; }}"]
    for fam, v, nfp, cset, iset in (("ip", "4", "ipv4", c4, i4), ("ip6", "6", "ipv6", c6, i6)):
        parts = [f"meta nfproto {nfp}"]
        skip = False
        for kind, items, mode in (("c", cset, rule.get("country_mode", "in")), ("i", iset, rule.get("ip_mode", "in"))):
            if not (rule.get("countries") if kind == "c" else rule.get("ips")):
                continue
            if not items:          # nothing of this family in the list
                if mode == "in":
                    skip = True    # "these" can never match this family
                continue           # "none of these" matches every address of this family
            parts.append(f"{fam} {who} {'!= ' if mode == 'not_in' else ''}@r_{rid}_{kind}{v}")
        if skip:
            continue
        proto, ports = rule.get("proto", "any"), rule.get("ports", "")
        if proto == "icmp":
            parts.append("meta l4proto icmp" if v == "4" else "meta l4proto ipv6-icmp")
        elif proto in ("tcp", "udp"):
            parts.append(f"meta l4proto {proto}")
        elif ports:
            parts.append("meta l4proto { tcp, udp }")
        if ports:
            parts.append(f"th dport {{ {', '.join(ports.split(','))} }}")
        tail = [f"counter name c_r_{rid}"]
        if act == "allow":
            tail.append("accept")
        elif act == "block":
            tail.append("drop")
        elif act == "limit":
            L = rule["limit"]
            tail.append(f"update @r_{rid}_m{v} {{ {fam} saddr limit rate over {L['rate']}/second burst {L['burst']} packets }}")
            if L.get("ban"):
                tail.append(f"add @rb_{rid}{v} {{ {fam} saddr timeout {L['ban']}m }}")
            tail.append("drop")
        for when in schedule_parts(rule.get("schedule")):
            lines.append("        " + " ".join(parts + when + tail))
    return sets, lines


# Bans live in one set per reason, so the panel can say why an address is banned:
#   ban   by the agent (manual, SSH login guard)   fban  SYN flood   cban  connection flood
#   sban  too many new SSH connections             rb_<rule id>  a firewall rule with "ban"
BAN_KINDS = ("ban", "fban", "cban", "sban")


def ban_sets(cfg):
    """Names (without the 4/6) of every ban set the ruleset declares."""
    out = list(BAN_KINDS)
    for rule in cfg.get("rules") or []:
        if rule.get("enabled", True) and rule.get("action") == "limit" and (rule.get("limit") or {}).get("ban"):
            out.append(f"rb_{rule['id']}")
    return out


def threat_parts(threat_lists, outbound):
    """Threat lists: one set pair and counter per list. A list in "block" mode drops everything the
    listed addresses start (replies to connections this server opened still pass); "log" mode only
    counts, to see what a list would block before trusting it. Recently matching addresses go to
    tseen (blocked) / tlog (monitored) for an hour so the panel can show them."""
    decl, pre, out = [], [], []
    if not threat_lists:
        return decl, pre, out
    for fam, v in (("ipv4", "4"), ("ipv6", "6")):
        decl += [f"    set tseen{v} {{ type {fam}_addr; flags dynamic, timeout; timeout 1h; size 4096; }}",
                 f"    set tlog{v} {{ type {fam}_addr; flags dynamic, timeout; timeout 1h; size 4096; }}"]
    ordered = sorted(threat_lists, key=lambda t: t[3] != "log")     # monitored lists first, so they count everything
    for fid, v4, v6, mode in ordered:
        decl.append(f"    counter c_t_{fid} {{ }}")
        decl += [set_block(f"t_{fid}4", "ipv4", list(v4), " auto-merge;"), set_block(f"t_{fid}6", "ipv6", list(v6), " auto-merge;")]
        for fam, v in (("ip", "4"), ("ip6", "6")):     # both, even if empty now: a refresh may fill the set in place
            if mode == "log":
                pre.append(f"        ct direction original {fam} saddr @t_{fid}{v} counter name c_t_{fid} update @tlog{v} {{ {fam} saddr }}")
            else:
                pre.append(f"        ct direction original {fam} saddr @t_{fid}{v} counter name c_t_{fid} update @tseen{v} {{ {fam} saddr }} drop")
                if outbound:
                    out.append(f"        {fam} daddr @t_{fid}{v} counter name c_tout drop")
    return decl, pre, out


def build(cfg, limits, ban_elements=None, ssh_ports=(), panel_ports=(), geo4=(), geo6=(), rule_zones=None,
          threat_lists=(), wan=None):
    """The complete ruleset as text, ready for `nft -f` (an atomic replace of the table).
    threat_lists: [(id, v4, v6, mode)] for the threat lists that are on."""
    fw = cfg["firewall"]
    adv = cfg.get("advanced") or {}
    allow4, allow6 = split_ips(a["ip"] for a in cfg["allow"])
    pallow4, pallow6 = split_ips(adv.get("panel_allow") or [])
    block4, block6 = split_ips(b["ip"] for b in cfg["block"] if not b.get("until"))
    ban_elements = ban_elements or {}
    ban_t = f"{int(limits['ban'])}m"
    lines = ["table inet defender", "delete table inet defender", "table inet defender {"]
    lines += [f"    counter c_{c} {{ }}" for c in COUNTERS]
    lines += [set_block("allow4", "ipv4", allow4), set_block("allow6", "ipv6", allow6),
              set_block("block4", "ipv4", block4), set_block("block6", "ipv6", block6),
              set_block("cdn4", "ipv4", list(CDN4) if cfg.get("trust_cdn", True) else []),
              set_block("cdn6", "ipv6", list(CDN6) if cfg.get("trust_cdn", True) else []),
              set_block("geo4", "ipv4", list(geo4), " auto-merge;"), set_block("geo6", "ipv6", list(geo6), " auto-merge;"),
              set_block("pallow4", "ipv4", pallow4), set_block("pallow6", "ipv6", pallow6)]
    t_decl, t_pre, t_out = threat_parts(threat_lists, (cfg.get("threat") or {}).get("outbound", False))
    lines += t_decl
    kinds = ban_sets(cfg)
    for kind in kinds:
        for fam, v in (("ipv4", "4"), ("ipv6", "6")):
            # elements keep their whole ban time and what is left of it, so "banned at" survives a rebuild
            els = ban_elements.get(f"{kind}{v}") or []
            body = f" elements = {{ {', '.join(f'{ip} timeout {int(total)}s expires {int(left)}s' for ip, total, left in els)} }};" if els else ""
            lines.append(f"    set {kind}{v} {{ type {fam}_addr; flags timeout; timeout {ban_t}; size 262144;{body} }}")
    for meter in ("syn", "synb", "conn", "connb", "udp", "udpb", "icmp", "icmpb", "ssh"):
        for fam, suffix in (("ipv4", "4"), ("ipv6", "6")):
            lines.append(f"    set m_{meter}{suffix} {{ type {fam}_addr; flags dynamic, timeout; timeout 2m; size 262144; }}")
    for fam, suffix in (("ipv4", "4"), ("ipv6", "6")):
        lines.append(f"    set m_conc{suffix} {{ type {fam}_addr; flags dynamic; size 262144; }}")

    ssh = sorted({str(p) for p in ssh_ports}) or ["22"]
    locked = ({str(p) for p in ssh} | {str(p) for p in panel_ports}) if adv.get("lock_ports", True) else set()
    open_tcp = sorted(locked |
                      {p["port"] for p in fw["ports"] if p["proto"] in ("tcp", "both") and not p.get("from")}, key=_port_key)
    open_udp = sorted({p["port"] for p in fw["ports"] if p["proto"] in ("udp", "both") and not p.get("from")}, key=_port_key)

    r = ["", "    chain pre {", "        type filter hook prerouting priority -150; policy accept;"]
    r += iface_rules(fw.get("trusted_ifaces", []), adv.get("trust_docker", True))
    r += ["        ip saddr @allow4 counter name c_allow accept",
          "        ip6 saddr @allow6 counter name c_allow accept",
          "        ip saddr @block4 counter name c_block drop",
          "        ip6 saddr @block6 counter name c_block drop",
          *[f"        {fam} saddr @{kind}{v} counter name c_ban drop" for kind in kinds for fam, v in (("ip", "4"), ("ip6", "6"))],
          *([f"        meta nfproto ipv4 tcp dport {ports_expr([str(p) for p in panel_ports])} ip saddr != @pallow4 counter name c_panel drop",
             f"        meta nfproto ipv6 tcp dport {ports_expr([str(p) for p in panel_ports])} ip6 saddr != @pallow6 counter name c_panel drop"]
            if adv.get("panel_allow") and panel_ports else []),   # panel only for listed addresses (admins pass above)
          "        ip saddr @cdn4 accept",   # blocklist and bans above still apply to the CDN
          "        ip6 saddr @cdn6 accept",
          *t_pre,                                            # threat-intelligence blocklists
          "        ip saddr @geo4 counter name c_geo drop",    # blocked countries (allowlist, admins, CDN pass above)
          "        ip6 saddr @geo6 counter name c_geo drop",
          "        counter name c_all",
          "        ct state established,related accept"]
    if cfg["ddos"].get("drop_invalid", True):
        r.append("        ct state invalid counter name c_invalid drop")
    if cfg["ddos"].get("bad_flags", True):
        for flags in ("& (fin|syn|rst|psh|ack|urg) == 0x0", "& (fin|syn) == fin|syn", "& (syn|rst) == syn|rst",
                      "& (fin|rst) == fin|rst", "& (fin|psh|urg) == fin|psh|urg", "& (fin|ack) == fin"):
            r.append(f"        tcp flags {flags} counter name c_badflags drop")
    r.append("        counter name c_new")
    for ln in (adv.get("custom_rules") or "").split("\n"):
        if ln.strip():
            r.append(f"        {ln.strip()}")
    out_lines = []
    for rule in cfg.get("rules") or []:      # the user's rules, top to bottom, for new connections
        if rule.get("enabled", True):
            rsets, rlines = rule_parts(rule, rule_zones or {})
            lines[3:3] = rsets               # declarations go into the table (after its opening lines)
            if rule.get("direction") == "out":
                out_lines += rlines
            else:
                r += rlines
    ssh_rate = int(adv.get("ssh_rate", SSH_NEW_PER_MIN))
    if cfg["ssh_guard"].get("l4", True) and ssh_rate > 0:
        for fam, suffix in (("ip", "4"), ("ip6", "6")):
            r.append(f"        tcp dport {ports_expr(ssh)} tcp flags syn update @m_ssh{suffix} {{ {fam} saddr limit rate over {ssh_rate}/minute burst {ssh_rate} packets }} "
                     f"add @sban{suffix} {{ {fam} saddr timeout {int(adv.get('ssh_ban_minutes', 60))}m }} counter name c_ssh drop")
    # Ports with a source restriction ("only from 1.2.3.0/24") are accepted for that source only.
    for p in fw["ports"]:
        if p.get("from"):
            fam = "ip6" if ":" in p["from"] else "ip"
            for proto in (("tcp", "udp") if p["proto"] == "both" else (p["proto"],)):
                r.append(f"        {fam} saddr {p['from']} {proto} dport {p['port']} accept")
    if fw.get("mode") == "strict":
        r.append(f"        tcp dport != {ports_expr(open_tcp)} counter name c_policy drop")
        r.append(f"        meta l4proto udp udp dport != {ports_expr(open_udp)} counter name c_policy drop" if open_udp
                 else "        meta l4proto udp counter name c_policy drop")
    L = limits
    F = int(adv.get("autoban_factor", AUTOBAN_FACTOR))
    for fam, suffix, icmp in (("ip", "4", "icmp type echo-request"), ("ip6", "6", "icmpv6 type echo-request")):
        nfp = "ipv4" if suffix == "4" else "ipv6"
        r += [
            *([f"        tcp flags & (syn|ack) == syn update @m_synb{suffix} {{ {fam} saddr limit rate over {L['syn'] * F}/second burst {L['syn'] * F * 2} packets }} add @fban{suffix} {{ {fam} saddr }} counter name c_autoban drop"] if F else []),
            f"        tcp flags & (syn|ack) == syn update @m_syn{suffix} {{ {fam} saddr limit rate over {L['syn']}/second burst {L['syn'] * 2} packets }} counter name c_syn drop",
            *([f"        meta nfproto {nfp} ct state new update @m_connb{suffix} {{ {fam} saddr limit rate over {L['conn'] * F}/second burst {L['conn'] * F * 2} packets }} add @cban{suffix} {{ {fam} saddr }} counter name c_autoban drop"] if F else []),
            f"        meta nfproto {'ipv4' if suffix == '4' else 'ipv6'} ct state new update @m_conn{suffix} {{ {fam} saddr limit rate over {L['conn']}/second burst {L['conn'] * 2} packets }} counter name c_conn drop",
            f"        meta l4proto tcp add @m_conc{suffix} {{ {fam} saddr ct count over {L['conc']} }} counter name c_conc drop",
            f"        meta l4proto udp update @m_udp{suffix} {{ {fam} saddr limit rate over {L['udp']}/second burst {L['udp'] * 2} packets }} counter name c_udp drop",
            f"        {icmp} update @m_icmp{suffix} {{ {fam} saddr limit rate over {L['icmp']}/second burst {L['icmp'] * 2} packets }} counter name c_icmp drop",
        ]
    r.append("    }")
    out_lines = t_out + out_lines
    if out_lines:   # outgoing rules: the server itself, and containers / VPN clients leaving through the internet side
        r += ["", "    chain local_out {", "        type filter hook output priority 0; policy accept;", '        oif "lo" accept',
              "        ct state established,related accept"] + out_lines + ["    }"]
        if wan:
            r += ["", "    chain fwd_out {", "        type filter hook forward priority 0; policy accept;",
                  "        ct state established,related accept", f'        oifname != "{wan}" accept'] + out_lines + ["    }"]
    lines += r
    lines.append("}")
    return "\n".join(lines) + "\n"


def _port_key(p):
    return int(str(p).split("-")[0])
__MONITORING_EOF__
  write_file defender/hostinfo.py 644 <<'__MONITORING_EOF__'
"""What the Defender knows about the host: open ports, SSH, kernel settings, and a security audit.

The agent runs with the host's network and PID namespaces, so /proc/net/* describes the host's
sockets and /proc/1/root is the host's filesystem (read-only use only).
"""
import glob
import ipaddress
import os
import re
import subprocess
import time

HOST = os.environ.get("HOST_ROOT", "/proc/1/root")

# ------------------------------------------------------------------ files on the host

def host_path(p):
    return os.path.join(HOST, p.lstrip("/"))


def read(p, limit=2_000_000):
    try:
        with open(host_path(p), "rb") as f:
            return f.read(limit).decode("utf-8", "replace")
    except OSError:
        return None


# ------------------------------------------------------------------ sockets

TCP_STATES = {"0A": "listen"}


def _hex_addr(h):
    if len(h) == 8:
        return str(ipaddress.IPv4Address(bytes.fromhex(h)[::-1]))
    b = bytes.fromhex(h)
    return str(ipaddress.IPv6Address(b"".join(b[i:i + 4][::-1] for i in range(0, 16, 4))))


def _inode_owners():
    """socket inode -> process name, by walking /proc/<pid>/fd (the host's PIDs)."""
    owners = {}
    for fd_dir in glob.glob("/proc/[0-9]*/fd"):
        pid = fd_dir.split("/")[2]
        try:
            names = os.listdir(fd_dir)
        except OSError:
            continue
        comm = None
        for n in names:
            try:
                target = os.readlink(f"{fd_dir}/{n}")
            except OSError:
                continue
            if target.startswith("socket:["):
                if comm is None:
                    try:
                        with open(f"/proc/{pid}/comm") as f:
                            comm = f.read().strip()
                    except OSError:
                        comm = "?"
                owners[target[8:-1]] = comm
    return owners


_ports_cache = {"at": 0, "rows": []}


def listening(max_age=20):
    """[{proto, port, addr, public, process}] for every listening TCP / bound UDP socket of the host."""
    if time.time() - _ports_cache["at"] < max_age:
        return _ports_cache["rows"]
    owners = _inode_owners()
    try:   # UDP sockets on ports the kernel hands out to clients are outgoing (e.g. VPN/proxy uplinks), not services
        lo, hi = (int(x) for x in open("/proc/sys/net/ipv4/ip_local_port_range").read().split())
    except (OSError, ValueError):
        lo, hi = 32768, 60999
    seen = {}
    for proto, files in (("tcp", ("/proc/net/tcp", "/proc/net/tcp6")), ("udp", ("/proc/net/udp", "/proc/net/udp6"))):
        for path in files:
            try:
                lines = open(path).read().splitlines()[1:]
            except OSError:
                continue
            for line in lines:
                parts = line.split()
                if len(parts) < 10:
                    continue
                local, state, inode = parts[1], parts[3], parts[9]
                if proto == "tcp" and state != "0A":
                    continue
                if proto == "udp" and parts[2].split(":")[1] != "0000":   # connected UDP sockets are clients
                    continue
                host_hex, port_hex = local.split(":")
                addr, port = _hex_addr(host_hex), int(port_hex, 16)
                if proto == "udp" and lo <= port <= hi:
                    continue
                ip = ipaddress.ip_address(addr)
                public = not (ip.is_loopback or (ip.version == 6 and ip.ipv4_mapped and ip.ipv4_mapped.is_loopback))
                key = (proto, port)
                row = seen.get(key)
                if row is None:
                    row = seen[key] = {"proto": proto, "port": port, "addrs": [], "public": False, "process": owners.get(inode, "")}
                row["addrs"].append(addr)
                row["public"] = row["public"] or public
                if not row["process"]:
                    row["process"] = owners.get(inode, "")
    rows = sorted(seen.values(), key=lambda r: (not r["public"], r["proto"], r["port"]))
    for r in rows:
        r["addrs"] = sorted(set(r["addrs"]))
    _ports_cache.update(at=time.time(), rows=rows)
    return rows


def docker_published():
    """Host ports Docker forwards to containers (they need to stay open in strict mode)."""
    out = set()
    try:
        text = subprocess.run(["nft", "list", "chain", "ip", "nat", "DOCKER"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return out
    for proto, port in re.findall(r"\b(tcp|udp) dport (\d+)\b.*\bdnat\b", text):
        out.add((proto, int(port)))
    return out


# ------------------------------------------------------------------ SSH

def sshd_config():
    text = read("/etc/ssh/sshd_config") or ""
    for f in sorted(glob.glob(host_path("/etc/ssh/sshd_config.d/*.conf"))):
        try:
            text = open(f, errors="replace").read() + "\n" + text   # included files come first and win
        except OSError:
            pass
    conf, ports = {}, []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.lower().startswith("match "):
            break   # settings after Match only apply to some users; the global ones are enough here
        k, _, v = line.partition(" ")
        k, v = k.lower(), v.strip()
        if k == "port":
            ports.append(int(v)) if v.isdigit() else None
        elif k not in conf:
            conf[k] = v.lower()
    return conf, ports


def ssh_ports():
    _, ports = sshd_config()
    # sshd's sockets change only when its settings do (the agent then clears the cache): a scan of every
    # process's open files every 2 minutes is plenty
    from_sockets = [r["port"] for r in listening(max_age=120) if r["proto"] == "tcp" and r["process"] == "sshd"]
    return sorted(set(ports + from_sockets)) or [22]


def ssh_sessions():
    """Source IPs of users that are logged in right now (from utmp, so only real logins: a brute-force
    attempt also holds an open TCP connection to sshd, but never shows up here)."""
    ips = set()
    try:
        with open(host_path("/run/utmp"), "rb") as f:
            data = f.read(4 * 1024 * 1024)
    except OSError:
        return []
    for off in range(0, len(data) - 383, 384):   # struct utmp on 64-bit Linux / glibc
        rec = data[off:off + 384]
        if int.from_bytes(rec[0:2], "little") != 7:   # USER_PROCESS
            continue
        host = rec[76:332].split(b"\0", 1)[0].decode("ascii", "replace")
        try:
            ip = ipaddress.ip_address(host)
        except ValueError:
            raw = rec[348:364]
            if not any(raw):
                continue
            ip = ipaddress.ip_address(raw[:4]) if not any(raw[4:]) else ipaddress.ip_address(raw)
        if not ip.is_loopback:
            ips.add(str(ip))
    return sorted(ips)


# ------------------------------------------------------------------ network interfaces and traffic

def public_iface():
    try:
        for line in open("/proc/net/route").read().splitlines()[1:]:
            p = line.split()
            if p[1] == "00000000" and p[7] == "00000000":
                return p[0]
    except OSError:
        pass
    return None


def iface_counters(name):
    try:
        for line in open("/proc/net/dev"):
            if ":" in line and line.split(":")[0].strip() == name:
                v = line.split(":")[1].split()
                return {"rx_bytes": int(v[0]), "rx_packets": int(v[1]), "rx_drop": int(v[3])}
    except OSError:
        pass
    return None


def interfaces():
    try:
        return sorted(n for n in os.listdir("/sys/class/net") if n != "lo")
    except OSError:
        return []


def _snmp(path):
    """/proc/net/snmp and /proc/net/netstat: 'Tcp: a b c' header line followed by a value line."""
    out = {}
    try:
        lines = open(path).read().splitlines()
    except OSError:
        return out
    for head, vals in zip(lines[::2], lines[1::2]):
        k, names = head.split(":", 1)
        for n, v in zip(names.split(), vals.split(":", 1)[1].split()):
            try:
                out[f"{k}.{n}"] = int(v)
            except ValueError:
                pass
    return out


def tcp_counters():
    a, b = _snmp("/proc/net/snmp"), _snmp("/proc/net/netstat")
    return {"passive_opens": a.get("Tcp.PassiveOpens", 0), "curr_estab": a.get("Tcp.CurrEstab", 0),
            "syncookies_sent": b.get("TcpExt.SyncookiesSent", 0), "listen_drops": b.get("TcpExt.ListenDrops", 0),
            "listen_overflows": b.get("TcpExt.ListenOverflows", 0)}


def conntrack_usage():
    try:
        count = int(open("/proc/sys/net/netfilter/nf_conntrack_count").read())
        maximum = int(open("/proc/sys/net/netfilter/nf_conntrack_max").read())
        return {"count": count, "max": maximum}
    except (OSError, ValueError):
        return None


_talk_cache = {"at": 0, "rows": []}


def top_sources(limit=15, max_age=4):
    """Remote addresses with the most tracked connections right now (who is talking to us most)."""
    if time.time() - _talk_cache["at"] < max_age:
        return _talk_cache["rows"]
    counts, local = {}, set(local_addresses())
    try:
        proc = subprocess.run(["conntrack", "-L", "-o", "extended"], capture_output=True, text=True, timeout=6)
        text = proc.stdout
    except (OSError, subprocess.TimeoutExpired):
        text = ""
    for line in text.splitlines():
        m = re.search(r"\bsrc=(\S+) dst=(\S+)", line)
        if not m:
            continue
        src, dst = m.group(1), m.group(2)
        if dst not in local or src in local:
            continue   # only connections made TO this server
        try:
            ip = ipaddress.ip_address(src)
        except ValueError:
            continue
        if ip.is_loopback or ip.is_private and src.startswith("172."):
            continue
        counts[src] = counts.get(src, 0) + 1
    rows = [{"ip": ip, "conns": n} for ip, n in sorted(counts.items(), key=lambda kv: -kv[1])[:limit]]
    _talk_cache.update(at=time.time(), rows=rows)
    return rows


def local_addresses():
    out = []
    try:
        text = subprocess.run(["ip", "-o", "addr"], capture_output=True, text=True, timeout=3).stdout
        out = [m.split("/")[0] for m in re.findall(r"inet6? (\S+)", text)]
    except (OSError, subprocess.TimeoutExpired):
        pass
    return out


# ------------------------------------------------------------------ kernel network hardening (sysctl)

SYSCTLS = [
    # key, recommended, why (i18n key on the panel side)
    ("net.ipv4.tcp_syncookies", "1", "sc_syncookies"),
    ("net.ipv4.tcp_synack_retries", "2", "sc_synack"),
    ("net.ipv4.tcp_max_syn_backlog", "8192", "sc_backlog"),
    ("net.ipv4.tcp_rfc1337", "1", "sc_rfc1337"),
    ("net.ipv4.icmp_echo_ignore_broadcasts", "1", "sc_bcast"),
    ("net.ipv4.icmp_ignore_bogus_error_responses", "1", "sc_bogus"),
    ("net.ipv4.conf.all.accept_redirects", "0", "sc_redirects"),
    ("net.ipv4.conf.default.accept_redirects", "0", "sc_redirects"),
    ("net.ipv6.conf.all.accept_redirects", "0", "sc_redirects"),
    ("net.ipv4.conf.all.send_redirects", "0", "sc_send_redirects"),
    ("net.ipv4.conf.all.accept_source_route", "0", "sc_source_route"),
    ("net.ipv6.conf.all.accept_source_route", "0", "sc_source_route"),
    ("net.netfilter.nf_conntrack_max", "262144", "sc_conntrack"),
    ("net.netfilter.nf_conntrack_tcp_timeout_established", "86400", "sc_ct_timeout"),
]
AT_LEAST = {"net.ipv4.tcp_max_syn_backlog", "net.netfilter.nf_conntrack_max"}   # a higher value is fine too


def _sysctl_path(key):
    return "/proc/sys/" + key.replace(".", "/")


def sysctl_get(key):
    try:
        return open(_sysctl_path(key)).read().strip()
    except OSError:
        return None


def sysctl_set(key, value):
    with open(_sysctl_path(key), "w") as f:
        f.write(str(value))


def sysctl_ok(key, current, recommended):
    if current is None:
        return None
    if key in AT_LEAST:
        try:
            return int(current) >= int(recommended)
        except ValueError:
            return False
    return current == recommended


def sysctl_report():
    rows = []
    for key, rec, why in SYSCTLS:
        cur = sysctl_get(key)
        rows.append({"key": key, "current": cur, "recommended": rec, "why": why, "ok": sysctl_ok(key, cur, rec)})
    return rows


# ------------------------------------------------------------------ security audit

INTERNAL_PORTS = {3306: "MySQL/MariaDB", 5432: "PostgreSQL", 6379: "Redis", 27017: "MongoDB", 9200: "Elasticsearch",
                  11211: "Memcached", 2375: "Docker API", 2376: "Docker API", 5984: "CouchDB", 9000: "PHP-FPM / MinIO",
                  8086: "InfluxDB", 15672: "RabbitMQ admin", 5672: "RabbitMQ", 25: "SMTP"}


def auth_failures(hours=24):
    text = read("/var/log/auth.log", 30_000_000)
    if text is None:
        return None
    return len(re.findall(r"Failed password|Invalid user|authentication failure", text))


def audit(state):
    """[{id, sev (0 ok, 1 low, 2 medium, 3 high), params}] - the texts live on the panel side (i18n)."""
    out = []
    add = lambda cid, sev, **p: out.append({"id": cid, "sev": sev, "params": p})
    conf, _ = sshd_config()
    root = conf.get("permitrootlogin", "prohibit-password")
    pw = conf.get("passwordauthentication", "yes")
    if root == "yes" and pw == "yes":
        add("ssh_root_pw", 3)
    elif root == "yes":
        add("ssh_root", 1)
    else:
        add("ssh_root", 0)
    add("ssh_password", 2 if pw == "yes" else 0)
    ports = ssh_ports()
    add("ssh_port", 1 if ports == [22] else 0, ports=",".join(map(str, ports)))
    fails = auth_failures()
    if fails is not None:
        add("ssh_bruteforce", 2 if fails > 100 else 1 if fails > 10 else 0, n=fails)
    add("fw_enabled", 0 if state["enabled"] else 3)
    exposed = [r for r in listening() if r["public"] and r["proto"] == "tcp" and r["port"] in INTERNAL_PORTS]
    for r in exposed:
        add("internal_exposed", 3, port=r["port"], name=INTERNAL_PORTS[r["port"]], process=r["process"])
    if not exposed:
        add("internal_exposed", 0)
    public_tcp = [r for r in listening() if r["public"] and r["proto"] == "tcp"]
    add("open_ports", 1 if state["mode"] == "open" and len(public_tcp) > 6 else 0, n=len(public_tcp))
    add("reboot", 2 if os.path.exists(host_path("/run/reboot-required")) else 0)
    auto = read("/etc/apt/apt.conf.d/20auto-upgrades") or ""
    if os.path.isdir(host_path("/etc/apt")):
        add("auto_updates", 0 if re.search(r'Unattended-Upgrade\s+"1"', auto) else 1)
    ct = conntrack_usage()
    if ct:
        pct = ct["count"] / ct["max"] * 100
        add("conntrack", 3 if pct > 85 else 1 if pct > 60 else 0, pct=round(pct), max=ct["max"])
    weak = [r for r in sysctl_report() if r["ok"] is False]
    add("kernel", 1 if weak else 0, n=len(weak))
    add("syncookies", 0 if sysctl_get("net.ipv4.tcp_syncookies") == "1" else 2)
    add("fail2ban", 0 if fail2ban_present() else 1)
    return out


def score(checks):
    weights = {0: 0, 1: 3, 2: 9, 3: 20}
    return max(0, 100 - sum(weights[c["sev"]] for c in checks))


# ------------------------------------------------------------------ fail2ban (read-only view of its bans)

def fail2ban_present():
    return os.path.exists(host_path("/etc/fail2ban/jail.conf")) or os.path.exists(host_path("/usr/bin/fail2ban-server"))


def fail2ban_bans():
    try:
        text = subprocess.run(["nft", "-j", "list", "table", "inet", "f2b-table"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    ips = []
    for m in re.finditer(r'"elem":\s*\[([^\]]*)\]', text):
        ips += re.findall(r'"((?:\d{1,3}\.){3}\d{1,3}|[0-9a-fA-F:]+:[0-9a-fA-F:]*)"', m.group(1))
    return sorted(set(ips))
__MONITORING_EOF__
  write_file defender/f2b.py 644 <<'__MONITORING_EOF__'
"""fail2ban management for the Firewall page: install / remove, service control, jails, bans, settings.

Reads and bans go straight to fail2ban's own control socket (the protocol fail2ban-client speaks), so
the page is fast. Installing, removing and the service itself run on the host through nsenter, with
fixed commands only. Settings the panel changes go to one file, jail.d/zzz-panel.local, which loads
after every other file and holds only the values changed here; each change is checked with
`fail2ban-client -t` first and the previous file is put back if the check fails.
"""
import configparser
import glob
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
JAIL_KEYS = ("enabled", "port", "protocol", "filter", "logpath", "backend", "maxretry", "findtime", "bantime",
             "banaction", "action", "ignoreip", "bantime.increment", "bantime.factor", "bantime.maxtime", "usedns", "mode")
KEY_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_.]{0,40}$")
ETC = "/etc/fail2ban"
FILE_RE = re.compile(r"^(jail\.local|jail\.conf|fail2ban\.local|fail2ban\.conf|paths-[a-z]+\.conf|"
                     r"(jail\.d|filter\.d|action\.d|fail2ban\.d)/[A-Za-z0-9_.\-]{1,80}\.(conf|local))$")
BACKUPS = ETC + "/.panel-backup"


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
                try:
                    at = time.mktime(time.strptime(m.group(2), "%Y-%m-%d %H:%M:%S"))
                except ValueError:
                    at = None
                rows.append({"ip": m.group(1), "until": until, "at": at})
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
        if not NAME_RE.match(name) or name.upper() == "DEFAULT":
            raise ValueError(f"invalid jail name: {name}")
        extra = j.pop("extra", None)
        for k in list(j):
            if k not in JAIL_KEYS:
                del j[k]
        for k, v in list(j.items()):
            if v is None or v == "":
                del j[k]          # empty field = use the value from the other files
        if "enabled" in j:
            j["enabled"] = bool(j["enabled"])
        if "bantime.increment" in j:
            j["bantime.increment"] = bool(j["bantime.increment"])
        for k in ("bantime", "findtime", "bantime.maxtime"):
            if k in j:
                j[k] = _dur(j[k])
        if "maxretry" in j:
            j["maxretry"] = str(max(1, min(100000, int(j["maxretry"]))))
        for k, v in list(j.items()):
            if isinstance(v, str):
                j[k] = _value(v, multiline=k in ("logpath", "action", "ignoreip"))
        if extra is not None:
            j["extra"] = _extra(extra)
    return managed


def _value(v, multiline=False):
    v = str(v).replace("\r", "")
    lines = [ln.strip() for ln in v.split("\n") if ln.strip()]
    if not multiline and len(lines) > 1:
        raise ValueError(f"Only one line allowed: {lines[0]}…")
    if any(ln.startswith("[") for ln in lines):
        raise ValueError("A value cannot start with [")
    return "\n".join(lines)[:4000]


def _extra(text):
    """Additional `key = value` lines for a jail, kept as written (validated so they cannot open a new section)."""
    out = []
    for ln in str(text).replace("\r", "").split("\n"):
        ln = ln.rstrip()
        if not ln.strip() or ln.strip().startswith(("#", ";")):
            continue
        if ln[:1].isspace():   # continuation of the previous value
            out.append(ln)
            continue
        k, sep, v = ln.partition("=")
        if not sep or not KEY_RE.match(k.strip()):
            raise ValueError(f"Not a `key = value` line: {ln[:60]}")
        out.append(f"{k.strip()} = {v.strip()}")
    return "\n".join(out)[:8000]


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
                v = "true" if v is True else "false" if v is False else str(v).replace("\n", "\n    ")
                lines.append(f"{k} = {v}")
        if j.get("extra"):
            lines.append(j["extra"])
        lines.append("")
    return "\n".join(lines) + "\n"


def write_settings(managed, also=None):
    """Write, test, reload. On a failed test every touched file comes back and nothing changes.
    `also`: extra {path: new text or None (delete)} changed in the same step (used when deleting a jail)."""
    changes = {PANEL_FILE: render(managed)}
    changes.update(also or {})
    _apply_files(changes)


def _apply_files(changes):
    old = {}
    for rel, text in changes.items():
        path = hostinfo.host_path(rel)
        old[rel] = open(path).read() if os.path.exists(path) else None
        if old[rel] is not None and rel != PANEL_FILE:
            _backup(rel, old[rel])
        if text is None:
            if os.path.exists(path):
                os.unlink(path)
        else:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(text if text.endswith("\n") else text + "\n")
    rc, out = host(["fail2ban-client", "-t"], timeout=60)
    if rc != 0:
        for rel, text in old.items():
            path = hostinfo.host_path(rel)
            if text is None:
                if os.path.exists(path):
                    os.unlink(path)
            else:
                with open(path, "w") as f:
                    f.write(text)
        lines = [re.sub(r"^\S+ \S+ fail2ban(\.\S+)?\s+\[\d+\]:\s*(ERROR\s*)?", "", ln).strip()
                 for ln in out.splitlines() if "ERROR" in ln or "rror" in ln] or out.splitlines()
        raise ValueError("fail2ban rejected the change, nothing changed: " + " / ".join(x for x in lines[-3:] if x)[-700:])
    _cache["at"] = 0
    if running():
        reload()
        # fail2ban accepts some broken jails (a missing filter, an unreadable log) and then silently does not
        # start them: check that every enabled jail runs, and undo the change if one does not.
        missing = sorted(expected_jails() - set(jail_names()))
        if missing:
            for rel, text in old.items():
                path = hostinfo.host_path(rel)
                if text is None:
                    if os.path.exists(path):
                        os.unlink(path)
                else:
                    with open(path, "w") as f:
                        f.write(text)
            reload()
            raise ValueError(f"fail2ban could not start {', '.join(missing)} with this change (check the filter, log path and backend). "
                             "The previous settings are back.")


def _backup(rel, text):
    d = hostinfo.host_path(BACKUPS)
    os.makedirs(d, exist_ok=True)
    name = rel.replace("/", "__") + time.strftime(".%Y%m%d-%H%M%S")
    with open(os.path.join(d, name), "w") as f:
        f.write(text)


# ------------------------------------------------------------------ what the files say about each jail

def _jail_files():
    """Configuration files in the order fail2ban reads them (later ones win)."""
    root = hostinfo.host_path(ETC)
    out = [f"{root}/jail.conf"]
    out += sorted(glob.glob(f"{root}/jail.d/*.conf"))
    out.append(f"{root}/jail.local")
    out += sorted(glob.glob(f"{root}/jail.d/*.local"))
    return [p for p in out if os.path.isfile(p)]


def _parser():
    return configparser.RawConfigParser(strict=False, interpolation=None, default_section="__none__",
                                        comment_prefixes=("#", ";"), inline_comment_prefixes=None)


def expected_jails():
    """Jails the configuration files switch on (what fail2ban should be running)."""
    merged = _parser()
    for path in _jail_files():
        try:
            merged.read(path, encoding="utf-8")
        except configparser.Error:
            continue
    default_on = merged.has_section("DEFAULT") and merged.get("DEFAULT", "enabled", fallback="false").strip().lower() in ("true", "yes", "1", "on")
    out = set()
    for sec in merged.sections():
        if sec in ("DEFAULT", "INCLUDES", "Definition", "Init"):
            continue
        val = merged.get(sec, "enabled", fallback=None)
        on = val.strip().lower() in ("true", "yes", "1", "on") if val is not None else default_on
        if on:
            out.add(sec)
    return out


def jail_config(name, skip_panel=False):
    """{key: (value, file)} for one jail across all files, plus where the jail is defined."""
    values, defined = {}, []
    root = hostinfo.host_path(ETC)
    for path in _jail_files():
        if skip_panel and path.endswith(PANEL_FILE[len(ETC):]):
            continue
        cp = _parser()
        try:
            cp.read(path, encoding="utf-8")
        except configparser.Error:
            continue
        if cp.has_section(name):
            rel = path[len(root) + 1:]
            defined.append(rel)
            for k, v in cp.items(name):
                values[k] = (v.strip(), rel)
    return values, defined


def jail_detail(name, managed):
    values, defined = jail_config(name)
    base, _ = jail_config(name, skip_panel=True)
    own = managed.get("jails", {}).get(name, {})
    return {"name": name, "values": {k: v for k, (v, _) in values.items()}, "base": {k: v for k, (v, _) in base.items()}, "sources": {k: f for k, (_, f) in values.items()},
            "defined": defined, "stock": "jail.conf" in defined, "panel": own,
            "filters": filters(), "running": running() and name in jail_names()}


def filters():
    d = hostinfo.host_path(ETC + "/filter.d")
    return sorted({os.path.basename(p).rsplit(".", 1)[0] for p in glob.glob(f"{d}/*.conf") + glob.glob(f"{d}/*.local")})


def delete_jail(name, managed):
    """Remove a jail everywhere the panel may: its own section, and the jail's section in jail.d / jail.local
    files (backed up first). A jail that only comes from jail.conf (shipped with fail2ban) is switched off."""
    _, defined = jail_config(name)
    managed["jails"].pop(name, None)
    also = {}
    root = hostinfo.host_path(ETC)
    for rel in defined:
        if rel in ("jail.conf", PANEL_FILE[len(ETC) + 1:]):
            continue
        path = f"{root}/{rel}"
        text = open(path).read()
        new = _drop_section(text, name)
        also[f"{ETC}/{rel}"] = new
        if not re.search(r"^\s*\[[^\]]+\]", new, re.M):
            also[f"{ETC}/{rel}"] = None     # nothing left in the file: remove it (a backup is kept)
    stock = "jail.conf" in defined
    if stock:
        managed["jails"][name] = {"enabled": False}
    write_settings(managed, also)
    return {"disabled_only": stock}


def _drop_section(text, name):
    out, skip = [], False
    for ln in text.splitlines(keepends=True):
        m = re.match(r"^\s*\[([^\]]+)\]", ln)
        if m:
            skip = m.group(1).strip() == name
        if not skip:
            out.append(ln)
    return "".join(out)


# ------------------------------------------------------------------ raw file editor

def files():
    root = hostinfo.host_path(ETC)
    rows = []
    for pattern in ("*.conf", "*.local", "jail.d/*", "fail2ban.d/*", "filter.d/*", "action.d/*"):
        for p in sorted(glob.glob(f"{root}/{pattern}")):
            rel = p[len(root) + 1:]
            if os.path.isfile(p) and FILE_RE.match(rel):
                st = os.stat(p)
                rows.append({"path": rel, "size": st.st_size, "mtime": int(st.st_mtime),
                             "group": rel.split("/")[0] if "/" in rel else "main", "panel": f"{ETC}/{rel}" == PANEL_FILE})
    return rows


def _rel(path):
    path = str(path or "").strip().lstrip("/")
    if path.startswith("etc/fail2ban/"):
        path = path[len("etc/fail2ban/"):]
    if not FILE_RE.match(path) or ".." in path:
        raise ValueError("Only files inside /etc/fail2ban (jail.d, filter.d, action.d, fail2ban.d, *.conf, *.local) can be edited")
    return path


def file_read(path):
    rel = _rel(path)
    p = hostinfo.host_path(f"{ETC}/{rel}")
    if not os.path.isfile(p):
        return {"path": rel, "text": "", "exists": False}
    with open(p, errors="replace") as f:
        return {"path": rel, "text": f.read(2_000_000), "exists": True}


def file_write(path, text):
    rel = _rel(path)
    if len(text) > 2_000_000:
        raise ValueError("file too large")
    _apply_files({f"{ETC}/{rel}": str(text).replace("\r\n", "\n")})
    return file_read(rel)


def file_delete(path):
    rel = _rel(path)
    if rel in ("jail.conf", "fail2ban.conf"):
        raise ValueError("The main files shipped with fail2ban cannot be deleted; edit jail.local instead")
    _apply_files({f"{ETC}/{rel}": None})
    return {"ok": True}


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
__MONITORING_EOF__
  write_file defender/geo.py 644 <<'__MONITORING_EOF__'
"""Country ranges for the rules: from ipdeny.com, or when that fails from the country lists on GitHub
(herrbischoff/country-ip-blocks, ipverse/rir-ip, also through jsDelivr and GitHub proxies). Cached for a
week; a failed or empty download never replaces the copy that is already there."""
import ipaddress
import os
import re
import time
import sources

URLS = {
    4: ["https://www.ipdeny.com/ipblocks/data/aggregated/{cc}-aggregated.zone",
        "https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/{cc}.cidr",
        "https://raw.githubusercontent.com/ipverse/rir-ip/master/country/{cc}/ipv4-aggregated.txt"],
    6: ["https://www.ipdeny.com/ipv6/ipaddresses/aggregated/{cc}-aggregated.zone",
        "https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv6/{cc}.cidr",
        "https://raw.githubusercontent.com/ipverse/rir-ip/master/country/{cc}/ipv6-aggregated.txt"],
}
MAX_AGE = 7 * 86400
CC_RE = re.compile(r"^[a-z]{2}$")


def _dir(data):
    d = os.path.join(data, "geo")
    os.makedirs(d, exist_ok=True)
    return d


def _parse(text, version):
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            net = ipaddress.ip_network(line, strict=False)
        except ValueError:
            continue
        if net.version == version:
            out.append(str(net))
    return out


def zones(data, cc, refresh=False, download=True):
    """(v4 list, v6 list) for one country; downloads when missing or older than a week."""
    if not CC_RE.match(cc):
        raise ValueError(f"unknown country code: {cc}")
    d = _dir(data)
    res = []
    for version in (4, 6):
        path = os.path.join(d, f"{cc}.{version}")
        fresh = os.path.exists(path) and time.time() - os.path.getmtime(path) < MAX_AGE
        if download and (refresh or not fresh):
            try:
                text = sources.fetch_any([u.format(cc=cc) for u in URLS[version]], check=lambda t, v=version: bool(_parse(t, v)), timeout=25)
                nets = _parse(text, version)
                tmp = path + ".tmp"
                with open(tmp, "w") as f:
                    f.write("\n".join(nets))
                os.replace(tmp, path)
            except Exception as e:
                if not os.path.exists(path):
                    if version == 6:   # some countries have no IPv6 list; IPv4 is what matters
                        res.append([])
                        continue
                    raise ValueError(f"Cannot download the address list of {cc.upper()}: {e}")
        if not os.path.exists(path):
            res.append([])
            continue
        with open(path) as f:
            res.append([ln for ln in f.read().splitlines() if ln])
    return res[0], res[1]


def build(data, codes, download=True):
    v4, v6, counts = [], [], {}
    for cc in codes:
        a, b = zones(data, cc, download=download)
        v4 += a
        v6 += b
        counts[cc] = len(a) + len(b)
    return v4, v6, counts


def info(data, codes):
    d = _dir(data)
    out = {}
    for cc in codes:
        p = os.path.join(d, f"{cc}.4")
        if os.path.exists(p):
            with open(p) as f:
                n = sum(1 for _ in f)
            out[cc] = {"ranges": n, "updated": round(os.path.getmtime(p))}
    return out
__MONITORING_EOF__
  write_file defender/sshmgr.py 644 <<'__MONITORING_EOF__'
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
__MONITORING_EOF__
  write_file defender/threat.py 644 <<'__MONITORING_EOF__'
"""Threat-intelligence blocklists: public lists of attacking, hijacked and botnet addresses.

Each list is downloaded, cleaned and merged into as few networks as possible, then stored on disk
(DATA/threat/<id>.4 and .6) with what is known about it in meta.json. A list is only written (and the
firewall only touched) when its content really changed. Private, loopback and other reserved ranges
are always removed, so Docker, VPN tunnels and the LAN are never affected.

Lookups for the panel (is this address listed? by which list?) use a sorted index of integer ranges,
built once per list version, so checking an address costs microseconds even with 100 000 entries.
"""
import bisect
import hashlib
import ipaddress
import json
import os
import re
import socket
import threading
import time
from urllib.parse import urlsplit

import sources

# kind: what the list contains. safe: almost no chance of blocking real users (turned on by "recommended").
FEEDS = {
    "spamhaus": {"name": "Spamhaus DROP", "site": "spamhaus.org", "kind": "hijacked", "safe": True,
                 "urls": ["https://www.spamhaus.org/drop/drop.txt", "https://www.spamhaus.org/drop/dropv6.txt"]},
    "firehol": {"name": "FireHOL Level 1", "site": "iplists.firehol.org", "kind": "mixed", "safe": True,
                "urls": ["https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset"]},
    "feodo": {"name": "abuse.ch Feodo Tracker", "site": "feodotracker.abuse.ch", "kind": "botnet", "safe": True,
              "urls": ["https://feodotracker.abuse.ch/downloads/ipblocklist.txt"]},
    "et": {"name": "Emerging Threats", "site": "emergingthreats.net", "kind": "compromised", "safe": True,
           "urls": ["https://rules.emergingthreats.net/blockrules/compromised-ips.txt"]},
    "cins": {"name": "CINS Army", "site": "cinsscore.com", "kind": "attackers", "safe": False,
             "urls": ["https://cinsscore.com/list/ci-badguys.txt"]},
    "blocklistde": {"name": "blocklist.de", "site": "blocklist.de", "kind": "attackers", "safe": False,
                    "urls": ["https://lists.blocklist.de/lists/all.txt"]},
    "ipsum": {"name": "IPsum (level 3)", "site": "github.com/stamparm/ipsum", "kind": "attackers", "safe": False,
              "urls": ["https://raw.githubusercontent.com/stamparm/ipsum/master/levels/3.txt"]},
    "greensnow": {"name": "GreenSnow", "site": "greensnow.co", "kind": "attackers", "safe": False,
                  "urls": ["https://blocklist.greensnow.co/greensnow.txt"]},
    "tor": {"name": "Tor exit nodes", "site": "torproject.org", "kind": "anonymizer", "safe": False,
            "urls": ["https://check.torproject.org/torbulkexitlist"]},
}
MAX_CUSTOM = 8
MAX_BYTES = 40_000_000           # per download
MAX_ENTRIES = 300_000            # per list, after merging (kernel memory stays small)
RESERVED = [ipaddress.ip_network(n) for n in (
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24",
    "192.0.2.0/24", "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/3",
    "::/8", "64:ff9b::/96", "2001:db8::/32", "fc00::/7", "fe80::/10", "ff00::/8")]
ID_RE = re.compile(r"^[a-z][a-z0-9]{1,15}$")
RANGE_RE = re.compile(r"^([0-9a-fA-F:.]+)\s*-\s*([0-9a-fA-F:.]+)$")
_lock = threading.RLock()
_cache = {}        # fid -> (mtime, v4, v6)
_index = {}        # fid -> (mtime, {4: (starts, ends), 6: (...)})


def _dir(data):
    d = os.path.join(data, "threat")
    os.makedirs(d, exist_ok=True)
    return d


def _meta_path(data):
    return os.path.join(_dir(data), "meta.json")


def load_meta(data):
    try:
        with open(_meta_path(data)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _save_meta(data, meta):
    tmp = _meta_path(data) + ".tmp"
    with open(tmp, "w") as f:
        json.dump(meta, f)
    os.replace(tmp, _meta_path(data))


def all_feeds(custom=()):
    """Built-in lists plus the user's own (custom: [{id, name, url}])."""
    out = {k: dict(v, custom=False) for k, v in FEEDS.items()}
    for c in custom or ():
        out[c["id"]] = {"name": c["name"], "site": urlsplit(c["url"]).hostname or "", "kind": "custom", "safe": False,
                        "urls": [c["url"]], "custom": True}
    return out


def check_url(url):
    """A list the user adds must be a public https address (the agent runs with the host's network)."""
    url = str(url or "").strip()
    parts = urlsplit(url)
    if parts.scheme != "https" or not parts.hostname or len(url) > 400 or parts.username or parts.password:
        raise ValueError("The list address must start with https:// and point to a public server")
    try:
        addrs = {ai[4][0] for ai in socket.getaddrinfo(parts.hostname, parts.port or 443, proto=socket.IPPROTO_TCP)}
    except OSError:
        raise ValueError(f"Cannot find the server {parts.hostname}")
    for a in addrs:
        ip = ipaddress.ip_address(a.split("%")[0])
        if not ip.is_global:
            raise ValueError(f"{parts.hostname} is a private or local address")
    return url


def parse(text):
    """Plain lists in any of the usual formats: one address, network or range per line, comments
    after # or ;, extra columns ignored. Returns merged (v4, v6) networks without reserved ranges."""
    nets = {4: [], 6: []}
    for line in text.splitlines():
        line = line.split("#")[0].split(";")[0].strip()
        if not line:
            continue
        m = RANGE_RE.match(line)
        try:
            if m:
                a, b = ipaddress.ip_address(m.group(1)), ipaddress.ip_address(m.group(2))
                found = list(ipaddress.summarize_address_range(a, b)) if a.version == b.version and a <= b else []
            else:
                token = line.replace(",", " ").split()[0]
                found = [ipaddress.ip_network(token, strict=False)]
        except ValueError:
            continue
        for net in found:
            if net.prefixlen == 0 or (net.version == 4 and net.prefixlen < 8) or (net.version == 6 and net.prefixlen < 16):
                continue          # a whole /0../7 is never a real entry
            if any(net.version == r.version and net.overlaps(r) for r in RESERVED):
                continue
            nets[net.version].append(net)
    return _merge(nets[4]), _merge(nets[6])


def _merge(nets):
    """As few networks as possible; single addresses without the /32 or /128."""
    return [str(n.network_address) if n.prefixlen == n.max_prefixlen else str(n) for n in ipaddress.collapse_addresses(nets)]


def _download(url):
    """The list from its URL, or when that fails from another copy (jsDelivr / proxies for GitHub files)."""
    return sources.fetch_any([url], check=_looks_like_list, timeout=40, limit=MAX_BYTES)


def _looks_like_list(text):
    """Cheap test that a download is an address list and not an error page: one of the first entries parses."""
    seen = 0
    for line in text.splitlines():
        line = line.split("#")[0].split(";")[0].strip()
        if not line:
            continue
        token = RANGE_RE.match(line).group(1) if RANGE_RE.match(line) else line.replace(",", " ").split()[0]
        try:
            ipaddress.ip_network(token, strict=False)
            return True
        except ValueError:
            seen += 1
            if seen > 50:
                return False
    return False


def fetch(data, fid, feed, max_age, force=False):
    """Downloads one list when it is older than max_age seconds (or force). Returns True when its
    content changed. A failed download keeps the previous copy and records the error."""
    with _lock:
        meta = load_meta(data)
        m = meta.get(fid, {})
        if not force and time.time() - m.get("fetched", 0) < max_age and os.path.exists(_file(data, fid, 4)):
            return False
    v4, v6, err = [], [], ""
    try:
        for url in feed["urls"]:
            a, b = parse(_download(url))
            v4 += a
            v6 += b
        if len(feed["urls"]) > 1:
            v4, v6 = _merge(ipaddress.ip_network(x) for x in v4), _merge(ipaddress.ip_network(x) for x in v6)
        if not v4 and not v6:
            raise ValueError("the list is empty or not in a known format")
        if len(v4) + len(v6) > MAX_ENTRIES:
            raise ValueError(f"the list has more than {MAX_ENTRIES} entries")
    except Exception as e:  # network error, HTTP error, bad content
        err = f"{type(e).__name__}: {e}"[:300] if not isinstance(e, ValueError) else str(e)[:300]
    with _lock:
        meta = load_meta(data)
        m = meta.setdefault(fid, {})
        now = int(time.time())
        if err:
            m.update(error=err, error_at=now)
            # try again later (15 min without any copy, an hour with one), not at every change of the settings
            m["fetched"] = now - max(0, max_age - (900 if not os.path.exists(_file(data, fid, 4)) else 3600))
            _save_meta(data, meta)
            if not os.path.exists(_file(data, fid, 4)):
                raise ValueError(f"Cannot download {feed['name']}: {err}")
            return False
        digest = hashlib.sha256(("\n".join(v4) + "|" + "\n".join(v6)).encode()).hexdigest()
        changed = digest != m.get("hash") or not os.path.exists(_file(data, fid, 4))
        if changed:
            for v, items in ((4, v4), (6, v6)):
                p = _file(data, fid, v)
                with open(p + ".tmp", "w") as f:
                    f.write("\n".join(items))
                os.replace(p + ".tmp", p)
            m.update(hash=digest, changed=now, v4=len(v4), v6=len(v6), addresses=_count(v4, v6))
        m.update(fetched=now, ok_at=now, error="", error_at=0)
        _save_meta(data, meta)
        return changed


def _file(data, fid, v):
    return os.path.join(_dir(data), f"{fid}.{v}")


def _count(v4, v6):
    """How many IPv4 addresses the list covers (IPv6 is shown as a number of networks)."""
    return sum(1 << (32 - int(x.split("/")[1])) if "/" in x else 1 for x in v4)


def cached(data, fid):
    """(v4, v6) from disk, kept in memory until the file changes."""
    p4, p6 = _file(data, fid, 4), _file(data, fid, 6)
    try:
        mtime = (os.path.getmtime(p4), os.path.getmtime(p6) if os.path.exists(p6) else 0)
    except OSError:
        return [], []
    with _lock:
        hit = _cache.get(fid)
        if hit and hit[0] == mtime:
            return hit[1], hit[2]
        out = []
        for p in (p4, p6):
            try:
                with open(p) as f:
                    out.append([ln for ln in f.read().splitlines() if ln])
            except OSError:
                out.append([])
        _cache[fid] = (mtime, out[0], out[1])
        _index.pop(fid, None)
        return out[0], out[1]


def remove(data, fid):
    with _lock:
        for v in (4, 6):
            try:
                os.remove(_file(data, fid, v))
            except OSError:
                pass
        meta = load_meta(data)
        if meta.pop(fid, None) is not None:
            _save_meta(data, meta)
        _cache.pop(fid, None)
        _index.pop(fid, None)


def lists(data, ids):
    """{fid: (v4, v6)} for the given lists, from disk."""
    return {fid: cached(data, fid) for fid in ids}


def _ranges(nets):
    pairs = []
    for n in nets:
        net = ipaddress.ip_network(n)
        pairs.append((int(net.network_address), int(net.broadcast_address)))
    pairs.sort()
    return [a for a, _ in pairs], [b for _, b in pairs]


def _idx(data, fid):
    v4, v6 = cached(data, fid)
    with _lock:
        hit = _index.get(fid)
        key = _cache.get(fid, (None,))[0]
        if hit and hit[0] == key:
            return hit[1]
        idx = {4: _ranges(v4), 6: _ranges(v6)}
        _index[fid] = (key, idx)
        return idx


def member(data, ids, ip):
    """Which of these lists contain the address (fast: a binary search per list)."""
    addr = ipaddress.ip_address(ip)
    n, hits = int(addr), []
    for fid in ids:
        starts, ends = _idx(data, fid)[addr.version]
        i = bisect.bisect_right(starts, n) - 1
        if i >= 0 and ends[i] >= n:     # lists are merged, so ranges never overlap
            hits.append(fid)
    return hits


def info(data, feeds):
    meta = load_meta(data)
    out = {}
    for fid, f in feeds.items():
        m = meta.get(fid, {})
        have = os.path.exists(_file(data, fid, 4))
        out[fid] = {"name": f["name"], "site": f["site"], "kind": f["kind"], "safe": f["safe"], "custom": f["custom"],
                    "url": f["urls"][0] if f["custom"] else "", "v4": m.get("v4", 0) if have else 0, "v6": m.get("v6", 0) if have else 0,
                    "addresses": m.get("addresses", 0) if have else 0, "updated": (m.get("ok_at") or None) if have else None,
                    "changed": m.get("changed") if have else None, "error": m.get("error", ""), "error_at": m.get("error_at", 0)}
    return out
__MONITORING_EOF__
  write_file defender/nftlib.py 644 <<'__MONITORING_EOF__'
"""nftables through libnftables in this process, instead of starting an `nft` program for every call.

The agent reads its counters every second; starting `nft` each time costs far more CPU than the work
itself. libnftables is the library the nft program is built on (it ships with the nftables package),
so the commands and their output are exactly the same. If the library cannot be loaded, run() returns
None and the caller falls back to the nft program.
"""
import ctypes
import threading

JSON = 1 << 4          # NFT_CTX_OUTPUT_JSON
_lock = threading.Lock()
_ctx = {"lib": None, "ctx": None, "failed": False}


def _load():
    if _ctx["lib"] or _ctx["failed"]:
        return _ctx["lib"]
    try:
        lib = ctypes.CDLL("libnftables.so.1")
        lib.nft_ctx_new.restype = ctypes.c_void_p
        lib.nft_ctx_new.argtypes = [ctypes.c_uint32]
        for name in ("nft_ctx_buffer_output", "nft_ctx_buffer_error"):
            getattr(lib, name).argtypes = [ctypes.c_void_p]
        for name in ("nft_ctx_get_output_buffer", "nft_ctx_get_error_buffer"):
            getattr(lib, name).argtypes = [ctypes.c_void_p]
            getattr(lib, name).restype = ctypes.c_char_p
        lib.nft_ctx_output_set_flags.argtypes = [ctypes.c_void_p, ctypes.c_uint]
        lib.nft_ctx_output_get_flags.argtypes = [ctypes.c_void_p]
        lib.nft_ctx_output_get_flags.restype = ctypes.c_uint
        lib.nft_run_cmd_from_buffer.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        lib.nft_run_cmd_from_buffer.restype = ctypes.c_int
        ctx = lib.nft_ctx_new(0)
        if not ctx or lib.nft_ctx_buffer_output(ctx) or lib.nft_ctx_buffer_error(ctx):
            raise OSError("nft_ctx_new failed")
        _ctx.update(lib=lib, ctx=ctx, base=lib.nft_ctx_output_get_flags(ctx))
    except (OSError, AttributeError):
        _ctx["failed"] = True
    return _ctx["lib"]


def run(cmd, json_out=False):
    """(ok, output, error) for one nft command line, or None when the library is not available."""
    with _lock:
        lib = _load()
        if not lib:
            return None
        ctx = _ctx["ctx"]
        lib.nft_ctx_output_set_flags(ctx, _ctx["base"] | (JSON if json_out else 0))
        rc = lib.nft_run_cmd_from_buffer(ctx, cmd.encode())
        out = (lib.nft_ctx_get_output_buffer(ctx) or b"").decode("utf-8", "replace")
        err = (lib.nft_ctx_get_error_buffer(ctx) or b"").decode("utf-8", "replace")
        return rc == 0, out, err
__MONITORING_EOF__
  write_file defender/sysfw.py 644 <<'__MONITORING_EOF__'
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
__MONITORING_EOF__
  write_file defender/sources.py 644 <<'__MONITORING_EOF__'
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
__MONITORING_EOF__
  write_file panel/static/index.html 644 <<'__MONITORING_EOF__'
<!doctype html>
<html lang="en" data-theme="dark">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>Server Monitor</title>
  <link rel="icon" href="data:image/svg+xml,%3Csvg%20xmlns=%22http://www.w3.org/2000/svg%22%20viewBox=%220%200%2032%2032%22%3E%3Crect%20width=%2232%22%20height=%2232%22%20rx=%228%22%20fill=%22%230e1520%22/%3E%3Cpath%20d=%22M16%205l9%203.5v7c0%205.4-3.7%209.2-9%2011.5-5.3-2.3-9-6.1-9-11.5v-7L16%205z%22%20fill=%22none%22%20stroke=%22%232ee6a6%22%20stroke-width=%222%22%20stroke-linejoin=%22round%22/%3E%3Cpath%20d=%22M10.5%2016h3l2-3.5%202.5%207%202-3.5h1.5%22%20fill=%22none%22%20stroke=%22%232ee6a6%22%20stroke-width=%221.8%22%20stroke-linecap=%22round%22%20stroke-linejoin=%22round%22/%3E%3C/svg%3E" type="image/svg+xml">
  <link rel="icon" href="/favicon-32.png" type="image/png" sizes="32x32">
  <link rel="shortcut icon" href="/favicon.ico">
  <link rel="apple-touch-icon" href="/apple-touch-icon.png">
  <meta name="theme-color" content="#0a0f16">
  <script src="/boot.js"></script>
  <link rel="stylesheet" href="/fonts.css">
  <link rel="stylesheet" href="/style.css">
  <script src="/app.js" defer></script>
  <script src="/defender.js" defer></script>
  <script src="/security.js" defer></script>
</head>
<body>
  <div class="app">
    <aside class="sidebar">
      <div class="brand">
        <div class="logo" id="logo"></div>
        <div class="brand-text">
          <h1 data-i18n="title">Server Monitor</h1>
          <small id="hostline">&nbsp;</small>
        </div>
      </div>
      <h2 data-i18n="monitors">Monitors</h2>
      <nav class="nav" id="nav"></nav>
      <h2 class="second" data-i18n="manage">Manage</h2>
      <nav class="nav" id="nav-manage"></nav>
    </aside>

    <div class="main">
      <header class="topbar">
        <div class="top-left">
          <div class="logo top-brand" id="top-logo"></div>
          <h2 class="top-title" id="page-title"></h2>
          <div class="live"><i class="pulse"></i><span id="foot"></span><select id="live-every" hidden></select></div>
        </div>
        <div class="actions">
          <button class="btn icon" id="theme" type="button" aria-label="Theme"></button>
          <button class="btn" id="lang" type="button"></button>
          <button class="btn" id="refresh" type="button"></button>
          <button class="btn danger" id="logout" type="button"></button>
        </div>
      </header>

      <div class="content">
        <div id="banner"></div>
        <section class="stats" id="stats"></section>
        <main class="card panel" id="panel"></main>
      </div>
    </div>
  </div>

  <nav class="tabbar" id="tabbar" aria-label="Main"></nav>
  <div class="toasts" id="toasts" aria-live="polite"></div>
</body>
</html>
__MONITORING_EOF__
  write_file panel/static/login.html 644 <<'__MONITORING_EOF__'
<!doctype html>
<html lang="en" data-theme="dark">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>Sign in - Server Monitor</title>
  <link rel="icon" href="data:image/svg+xml,%3Csvg%20xmlns=%22http://www.w3.org/2000/svg%22%20viewBox=%220%200%2032%2032%22%3E%3Crect%20width=%2232%22%20height=%2232%22%20rx=%228%22%20fill=%22%230e1520%22/%3E%3Cpath%20d=%22M16%205l9%203.5v7c0%205.4-3.7%209.2-9%2011.5-5.3-2.3-9-6.1-9-11.5v-7L16%205z%22%20fill=%22none%22%20stroke=%22%232ee6a6%22%20stroke-width=%222%22%20stroke-linejoin=%22round%22/%3E%3Cpath%20d=%22M10.5%2016h3l2-3.5%202.5%207%202-3.5h1.5%22%20fill=%22none%22%20stroke=%22%232ee6a6%22%20stroke-width=%221.8%22%20stroke-linecap=%22round%22%20stroke-linejoin=%22round%22/%3E%3C/svg%3E" type="image/svg+xml">
  <link rel="icon" href="/favicon-32.png" type="image/png" sizes="32x32">
  <link rel="shortcut icon" href="/favicon.ico">
  <link rel="apple-touch-icon" href="/apple-touch-icon.png">
  <meta name="theme-color" content="#0a0f16">
  <script src="/boot.js"></script>
  <link rel="stylesheet" href="/fonts.css">
  <link rel="stylesheet" href="/style.css">
  <script src="/login.js" defer></script>
</head>
<body>
  <div class="login-tools">
    <button type="button" class="btn small" id="lang"><svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.5 2.7 3.8 5.7 3.8 9s-1.3 6.3-3.8 9c-2.5-2.7-3.8-5.7-3.8-9S9.5 5.7 12 3z"/></svg><span></span></button>
    <button type="button" class="btn small icon" id="theme"></button>
  </div>
  <div class="login-page">
    <form class="card login-card" id="form" autocomplete="on">
      <div class="brand">
        <div class="logo">
          <svg class="ico" viewBox="0 0 24 24"><path d="M12 3l8 3v6c0 4.6-3.2 7.9-8 9.8C7.2 19.9 4 16.6 4 12V6l8-3z"/><path d="M8 12h2.5l1.5-3 2 6 1.5-3H17"/></svg>
        </div>
        <div>
          <h1 data-i18n="title">Server Monitor</h1>
          <small data-i18n="signin_sub">Sign in to continue</small>
        </div>
      </div>
      <div class="field">
        <label for="user" data-i18n="user">Username</label>
        <input id="user" name="username" autocomplete="username" required autofocus>
      </div>
      <div class="field">
        <label for="password" data-i18n="password">Password</label>
        <div class="pw-wrap"><input id="password" name="password" type="password" autocomplete="current-password" required>
          <button type="button" class="pw-toggle" id="pw-toggle" aria-pressed="false"></button></div>
      </div>
      <div class="field" id="otp-field" hidden>
        <label for="otp" data-i18n="otp">Code from your authenticator app</label>
        <input id="otp" name="otp" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9 ]{6,7}" maxlength="7" dir="ltr">
      </div>
      <div class="form-error" id="error" role="alert"></div>
      <button class="btn primary" type="submit" id="submit" data-i18n="signin">Sign in</button>
    </form>
  </div>
</body>
</html>
__MONITORING_EOF__
  write_file panel/static/app.js 644 <<'__MONITORING_EOF__'
(() => {
  "use strict";

  // ---------------------------------------------------------------- i18n
  const T = {
    en: {
      title: "Server Monitor", monitors: "Monitors", manage: "Manage", refresh: "Refresh", logout: "Logout",
      lang_switch: "فارسی", host: "Host",
      cpu: "CPU", memory: "Memory", disk: "Disk", load: "Load average",
      net_down: "Network in", net_up: "Network out", targets: "Targets up",
      websites: "Checks up", ssl: "SSL expires in", alerts: "Firing alerts", cores: "cores", of: "of", days: "days", running: "running",
      overview: "Overview", websites_nav: "Websites", disks: "Disks", network: "Network",
      targets_nav: "Targets", alerts_nav: "Alerts", servers_nav: "Servers", notifications_nav: "Notifications",
      rules_nav: "Alert rules", settings_nav: "Settings",
      d_overview: "Live resource usage of the selected server. Charts update automatically.",
      d_websites: "Websites and TCP ports that are checked for uptime, response time and SSL expiry. Add or remove them here.",
      d_disks: "Mounted filesystems and how full they are.",
      d_network: "Traffic on the physical network interfaces (virtual and Docker interfaces are hidden).",
      d_servers: "The servers whose CPU, memory, disk and network are monitored. Add another server to watch it too.",
      d_notifications: "Where alerts are sent. Connect a Telegram bot to get a message when something goes wrong.",
      d_rules: "When an alert fires. Change the thresholds, switch rules off, or restore the defaults.",
      d_settings: "Panel password, Docker access and information about this installation.",
      nx_nodata: "No network interface data yet. Rates need about 30 seconds of samples; if this stays empty, check the Targets tab.",
      nx_nojob: "The node-net exporter is not in Prometheus. Re-run install.sh, or run: docker compose up -d && docker compose restart panel prometheus",
      nx_down: "The node-net exporter is down, so network cards cannot be read. Error:",
      d_targets: "Everything Prometheus scrapes. A target that is down means its metrics are missing.",
      d_alerts: "Alerts that are firing or about to fire. Change when they fire on the Alert rules page.",
      server: "Server", range: "Range", r1h: "Last hour", r6h: "Last 6 hours", r24h: "Last 24 hours", r7d: "Last 7 days", rlive: "Live (last 5 minutes)",
      c_cpu: "CPU usage", c_mem: "Memory usage", c_net: "Network traffic", c_load: "Load average",
      rx: "in", tx: "out", no_data: "No data yet", empty: "Nothing to show yet.",
      name: "Name", cpu_h: "CPU", mem_h: "Memory", uptime_h: "Uptime", status: "Status", target: "Target", type: "Type",
      response: "Response", http: "HTTP", ssl_h: "SSL days left", mount: "Mount", device: "Device", fs: "Filesystem",
      usage: "Usage", used_total: "Used / Total", iface: "Interface", speed: "Link speed", rate_in: "In", rate_out: "Out", total_in: "Total in", total_out: "Total out",
      job: "Job", instance: "Instance", scrape: "Scrape time", error: "Error", severity: "Severity", alert: "Alert", summary: "Summary", state: "State", since: "Since",
      s_running: "Running", s_up: "Up", s_down: "Down", s_firing: "Firing", s_pending: "Pending", s_exited: "Stopped", s_paused: "Paused", s_created: "Created", s_restarting: "Restarting",
      no_alerts: "No active alerts. Everything looks healthy.", host_online: "Host online",
      h_ok: "Everything is healthy", h_ok_sub: "The server and all of your checks are working normally.", h_warn: "Needs your attention", h_bad: "Problems detected",
      i_alerts: "{n} active alert(s)", i_sites: "{n} website/port check(s) failing", i_targets: "{n} monitoring target(s) not responding",
      i_res: "{what} is high ({v}%)", i_pending: "{n} alert(s) about to fire", i_ssl: "an SSL certificate expires in {n} day(s)",
            net_ifaces: "Network interfaces", tr_title: "Traffic usage", tr_sub: "Everything this server has downloaded and uploaded through its real network cards.",
      tr_day: "Day", tr_today: "Today", tr_yesterday: "Yesterday", tr_7d: "Last 7 days", tr_30d: "Last 30 days", tr_boot: "Since boot", tr_total: "Total", tr_down: "Download", tr_up: "Upload",
      tr_daily: "Daily traffic", tr_peak_in: "Peak download (24h)", tr_peak_out: "Peak upload (24h)", tr_partial: "Only {d} of data collected so far",
            diag_btn: "Find out why", dg_title: "Why can't the panel load data?", diag_services: "Services", diag_containers: "Containers of the stack", diag_ok: "Reachable", diag_fail: "Failing",
      diag_dns: "Name not found", diag_http: "No valid answer", diag_detail: "Detail", diag_exit: "Exit code", diag_restarts: "Restarts", diag_logs: "Last log lines of {s}", service: "Service",
      diag_all_ok: "Every service answers now. Close this window and press Refresh.",
      hint_stopped: "{service} is not running: {detail}. Restart it with the button below; its last log lines further down show why it stopped.",
      hint_dns: "The panel cannot even resolve the name \u201c{service}\u201d ({detail}). Docker's internal DNS is not answering.",
      hint_svc: "{service} is reachable but does not answer correctly: {detail}",
      hint_disk: "The disk is {detail} full. Prometheus stops working when there is no free space left.",
      hint_dns_external: "DNS to the internet fails as well ({detail}). The server's resolver (/etc/resolv.conf) is broken or blocked by the firewall, and Docker uses it.",
      lv_ok: "Normal", lv_warn: "High", lv_bad: "Critical", address: "Address", more: "More", tbl_view: "Table view", time: "Time",
      err_api: "Cannot load data", last_update: "Last update", auto: "auto-refresh every 10s", ago: "ago",
      live_on: "Live · updates every", live_every: "How often live numbers update", live_sec: "{n} s", live_wait: "Connecting to live data…", live_waiting: "Waiting for live data…", live_tag: "Live",
      live_off_note: "Live data is not available ({e}), so the last hour is shown instead.", io_r: "read", io_w: "write", swap: "Swap",
      t_dark: "Switch to light theme", t_light: "Switch to dark theme",
      // generic UI
      add: "Add", cancel: "Cancel", close: "Close", save: "Save", saved: "Saved", remove: "Remove", working: "Working…", copy: "Copy", copied: "Copied",
      confirm: "Please confirm", actions: "Actions", minutes: "min", added: "Added", removed: "Removed", reset_defaults: "Restore defaults",
      // stack containers (self-diagnosis)
      a_restart: "Restart", c_done: "Done",
      c_docker_off: "Docker access is off, so the state of the stack's containers cannot be shown. Enable it by mounting the Docker socket (see Settings).",
      // websites + servers
      add_site: "Add website or port", type_http: "Website (HTTP / HTTPS)", type_tcp: "TCP port", f_target: "Address", f_name_opt: "Name (optional)",
      hint_http: "A full address, for example https://example.com", hint_tcp: "host:port, for example 203.0.113.10:22 (SSH) or db.internal:5432",
      probe: "Test now / why?", probe_title: "Check result", probe_running: "Checking now…", probe_ok: "This check passes from the server right now.",
      probe_fail: "This check fails from the server.", probe_reason: "Reason", probe_log: "Technical details", probe_status: "HTTP status",
      probe_k_reset: "The site (or the network in front of it) accepted the connection and then cut it off during the handshake. This is what a firewall or geo-block does: the site works for you but refuses this server's IP address.",
      probe_k_refused: "The server answered but nothing is listening on that port (or a firewall is actively rejecting it).",
      probe_k_dns: "The server cannot resolve this domain name. Check the spelling and the DNS settings of the server.",
      probe_k_timeout: "No answer in time. The host is down, or a firewall silently drops packets from this server.",
      probe_k_tls: "The site's certificate has a problem: expired, issued for another domain, or from an untrusted issuer.",
      probe_k_unreachable: "This server has no network route to the address.",
      probe_k_status: "The site answered but with an error status (4xx or 5xx), so it is not counted as healthy.",
      probe_k_other: "The check failed for another reason; see the technical details below.",
      probe_k_handshake: "The site rejected the secure connection during the TLS handshake. Usual causes: it only supports old TLS versions or ciphers, its certificate/SNI setup is broken, or its firewall refuses this server's IP address. The table below tries the alternatives for you.",
      v_legacy_tls: "Allow old TLS (1.0 / 1.1)", v_no_verify: "Ignore certificate errors", v_legacy_no_verify: "Old TLS and ignore certificate errors",
      v_plain_http: "Plain HTTP (no encryption)", v_tcp: "Only connect to the port (TCP)",
      diag_title: "What works from the server", diag_works: "Works", diag_fails: "Fails", diag_apply: "Monitor this site this way",
      diag_suggest: "The site passes in the mode marked below. Switch the check to it to monitor the site without false alarms.",
      diag_applied: "Check mode changed. The status updates within a minute.", mode_default: "standard",
      mode_legacy_tls: "old TLS", mode_no_verify: "no certificate check", mode_legacy_no_verify: "old TLS, no certificate check",
      diag_blocked: "The port accepts connections but every secure variant is rejected: the site or its firewall refuses this server specifically (typical for IP/geo blocking).",
      diag_plain: "Plain HTTP works, but every secure (HTTPS) attempt is rejected, whatever the TLS mode. The site is up; its HTTPS side refuses this server. You can monitor it over plain HTTP instead (if that address redirects to an HTTPS page, that page's certificate is still checked).",
      diag_use_http: "Monitor over plain HTTP instead", diag_replaced: "Now monitoring the plain HTTP address.",
      diag_closed: "Even a plain TCP connection fails: the address is unreachable from this server (down, wrong port, or blocked).",
      auto_title: "Automatic fixing of failing websites",
      auto_text: "When a website keeps failing, the panel tries other ways to check it (old TLS, ignoring certificate errors, the page its http:// address redirects to, plain http://) and switches to the first one that works. A check that works is never changed. Turn it off to keep your addresses exactly as typed.",
      auto_on: "Fix failing websites automatically", auto_off_saved: "Automatic fixing is off", auto_on_saved: "Automatic fixing is on",
      auto_log: "Automatic adjustments", auto_tag: "auto", auto_was: "was {from}",
      auto_ev_replace: "{from} is now monitored as {to}", auto_ev_mode: "{from} is now checked with: {mode}", auto_ev_merge: "{from} was removed: {to} is already monitored",
      auto_fix_btn: "Fix automatically", auto_done: "Done. The status updates within a minute.",
      auto_none: "Nothing better was found: no other way of checking this address works from the server.",
      added_auto: "Added. The panel is choosing the best way to monitor it automatically.", redirects_to: "redirects to",
      probe_hint: "If the address opens in your browser but fails here, the server's IP is probably blocked by the site or its network (common for sites hosted in Iran when the monitoring server is abroad), or the server has no route to it. Monitoring shows what the server sees, not what you see.",
      s_wait: "Waiting", w_confirm_remove: "Stop monitoring {n}?", w_hint: "New entries show \"Waiting\" until the first check completes (about a minute).",
      add_server: "Add server", f_srv_addr: "Server address", f_srv_hint: "IP or hostname with the node_exporter port, for example 203.0.113.10:9100",
      srv_local: "this server", srv_confirm_remove: "Stop monitoring server {n}?",
      srv_help_title: "How to add another server",
      srv_help_1: "1. On the other server, run node_exporter (needs Docker):",
      srv_help_2: "2. Allow port 9100 only from this monitoring server in that server's firewall, for example:",
      srv_help_3: "3. Click \"Add server\" and enter its address as IP:9100.",
      // notifications
      tg_title: "Telegram", tg_ok: "Connected", tg_no: "Not configured", tg_bot: "Bot",
      tg_s1: "Open Telegram, talk to @BotFather, send /newbot and copy the token it gives you.",
      tg_s2: "Open your new bot and press Start (or add it to a group and write any message).",
      tg_s3: "Paste the token below and press \"Find chat ID\". Pick the chat, then Save.",
      tg_token: "Bot token", tg_token_saved: "Saved: {h} (leave empty to keep it)", tg_chat: "Chat ID", tg_find: "Find chat ID",
      tg_found: "Click a chat to use it:", tg_none: "No chats found yet. Send your bot a message in Telegram, then try again.",
      tg_test: "Send test message", tg_test_ok: "Test message sent. Check Telegram.", tg_saved: "Telegram saved. Alerts will be sent there.",
      tg_remove: "Disconnect", tg_confirm_remove: "Stop sending alerts to Telegram?", tg_removed: "Telegram disconnected",
      at_title: "Test the whole alert pipeline", at_text: "Fires a harmless test alert through Alertmanager. If Telegram is connected, the message arrives within about 30 seconds.",
      at_btn: "Send test alert", at_ok: "Test alert fired. Telegram gets it in about 30 seconds.",
      // rules
      rl_rule: "Rule", rl_enabled: "On", rl_threshold: "Threshold", rl_for: "Must last", rl_reset_confirm: "Restore every rule to its default threshold and switch all rules on?",
      rl_saved: "Rule saved and applied", rl_reset_ok: "Defaults restored",
      rn_InstanceDown: "Target down", rn_HighCpuUsage: "High CPU", rn_HighMemoryUsage: "High memory", rn_DiskSpaceLow: "Disk almost full",
      rn_DiskWillFillIn24h: "Disk will fill up", rn_HighLoad: "High load", rn_HostRebooted: "Server rebooted", rn_ContainerHighCpu: "Container: high CPU",
      rn_ContainerHighMemory: "Container: high memory", rn_EndpointDown: "Site or port down", rn_SslCertExpiringSoon: "SSL certificate expiring",
      rn_SlowEndpoint: "Slow site", sev_critical: "critical", sev_warning: "warning", sev_info: "info",
      rd_InstanceDown: "A monitored target (server, exporter or checker) stopped responding.",
      rd_HighCpuUsage: "CPU usage stays above the threshold.",
      rd_HighMemoryUsage: "Memory usage stays above the threshold.",
      rd_DiskSpaceLow: "A disk is fuller than the threshold.",
      rd_DiskWillFillIn24h: "At the current rate a disk runs out of space within this many hours.",
      rd_HighLoad: "Load average per CPU core is above the threshold.",
      rd_HostRebooted: "A server restarted within this many seconds.",
      rd_ContainerHighCpu: "A container uses more CPU than the threshold.",
      rd_ContainerHighMemory: "A container uses more of its memory limit than the threshold.",
      rd_EndpointDown: "A website or port check fails.",
      rd_SslCertExpiringSoon: "An SSL certificate expires in fewer days than the threshold.",
      rd_SlowEndpoint: "A website needs longer than this to respond.",
      // settings
      st_pw_title: "Change login", st_user: "Username", st_current: "Current password", st_new: "New password (8+ characters)", st_repeat: "Repeat new password",
      st_change: "Change login", st_mismatch: "The two passwords do not match", st_pw_ok: "Login changed. Other devices are signed out.",
      st_docker_title: "Docker access", st_docker_on: "Enabled", st_docker_off: "Off",
      st_docker_hint_on: "The panel uses the Docker socket only for its own monitoring stack: to show why a service stopped and to restart it from the “Find out why” page. Whoever can reach the socket is root on the server, so keep the password strong and put HTTPS in front of the panel.",
      st_docker_hint_off: "The panel cannot see the state of its own stack. To enable it, make sure the docker.sock mount in docker-compose.yml is present and PANEL_DOCKER_CONTROL is not 0, then run: docker compose up -d",
      st_docker_unavail: "Enabled in settings, but the Docker socket is not reachable.",
      st_about: "About", st_version: "Panel version",
    },
    fa: {
      title: "مانیتورینگ سرور", monitors: "مانیتورها", manage: "مدیریت", refresh: "بروزرسانی", logout: "خروج",
      lang_switch: "English", host: "سرور",
      cpu: "پردازنده", memory: "حافظه (رم)", disk: "دیسک", load: "میانگین بار",
      net_down: "دریافت شبکه", net_up: "ارسال شبکه", targets: "تارگت‌های فعال",
      websites: "چک‌های سالم", ssl: "انقضای SSL", alerts: "هشدارهای فعال", cores: "هسته", of: "از", days: "روز", running: "در حال اجرا",
      overview: "نمای کلی", websites_nav: "سایت‌ها", disks: "دیسک‌ها", network: "شبکه",
      targets_nav: "تارگت‌ها", alerts_nav: "هشدارها", servers_nav: "سرورها", notifications_nav: "اعلان‌ها",
      rules_nav: "قوانین هشدار", settings_nav: "تنظیمات",
      d_overview: "مصرف زنده‌ی منابع سرور انتخاب‌شده. نمودارها خودکار بروز می‌شوند.",
      d_websites: "سایت‌ها و پورت‌های TCP که آپتایم، زمان پاسخ و انقضای SSL‌شان چک می‌شود. از اینجا اضافه یا حذف کنید.",
      d_disks: "فایل‌سیستم‌های مونت‌شده و میزان پر بودن هرکدام.",
      d_network: "ترافیک کارت‌شبکه‌های واقعی (کارت‌های مجازی و داکر پنهان هستند).",
      d_servers: "سرورهایی که پردازنده، رم، دیسک و شبکه‌شان مانیتور می‌شود. برای نظارت بر سرور دیگر، آن را اضافه کنید.",
      d_notifications: "هشدارها کجا فرستاده شوند. یک ربات تلگرام وصل کنید تا هر مشکلی پیام بگیرید.",
      d_rules: "هشدار چه زمانی فعال شود. آستانه‌ها را عوض کنید، قانونی را خاموش کنید یا پیش‌فرض‌ها را برگردانید.",
      d_settings: "رمز پنل، دسترسی داکر و اطلاعات این نصب.",
      nx_nodata: "هنوز داده‌ی کارت شبکه نرسیده. نرخ‌ها حدود ۳۰ ثانیه داده می‌خواهند؛ اگر خالی ماند تب تارگت‌ها را ببینید.",
      nx_nojob: "اکسپورتر node-net در Prometheus نیست. install.sh را دوباره اجرا کنید یا بزنید: docker compose up -d && docker compose restart panel prometheus",
      nx_down: "اکسپورتر node-net قطع است و کارت‌های شبکه خوانده نمی‌شوند. خطا:",
      d_targets: "همه‌ی چیزهایی که Prometheus از آن‌ها متریک می‌گیرد. تارگت قطع یعنی متریکش را نداریم.",
      d_alerts: "هشدارهایی که فعال هستند یا در شرف فعال شدن‌اند. زمان فعال شدنشان را در صفحه‌ی قوانین هشدار عوض کنید.",
      server: "سرور", range: "بازه", r1h: "یک ساعت اخیر", r6h: "۶ ساعت اخیر", r24h: "۲۴ ساعت اخیر", r7d: "۷ روز اخیر", rlive: "زنده (۵ دقیقه‌ی اخیر)",
      c_cpu: "مصرف پردازنده", c_mem: "مصرف حافظه", c_net: "ترافیک شبکه", c_load: "میانگین بار",
      rx: "دریافت", tx: "ارسال", no_data: "هنوز داده‌ای نیست", empty: "هنوز چیزی برای نمایش نیست.",
      name: "نام", cpu_h: "پردازنده", mem_h: "حافظه", uptime_h: "مدت اجرا", status: "وضعیت", target: "مقصد", type: "نوع",
      response: "پاسخ", http: "HTTP", ssl_h: "روز تا انقضای SSL", mount: "مسیر", device: "دستگاه", fs: "فایل‌سیستم",
      usage: "مصرف", used_total: "مصرف / کل", iface: "کارت شبکه", speed: "سرعت لینک", rate_in: "دریافت", rate_out: "ارسال", total_in: "کل دریافت", total_out: "کل ارسال",
      job: "گروه", instance: "نمونه", scrape: "زمان جمع‌آوری", error: "خطا", severity: "شدت", alert: "هشدار", summary: "خلاصه", state: "حالت", since: "از",
      s_running: "در حال اجرا", s_up: "فعال", s_down: "قطع", s_firing: "فعال", s_pending: "در انتظار", s_exited: "متوقف", s_paused: "مکث", s_created: "ساخته‌شده", s_restarting: "در حال ری‌استارت",
      no_alerts: "هشدار فعالی وجود ندارد. همه چیز سالم است.", host_online: "سرور آنلاین است",
      h_ok: "همه چیز سالم است", h_ok_sub: "سرور و تمام بررسی‌های شما عادی کار می‌کنند.", h_warn: "نیاز به توجه دارد", h_bad: "مشکل شناسایی شد",
      i_alerts: "{n} هشدار فعال", i_sites: "{n} بررسی سایت/پورت ناموفق است", i_targets: "{n} هدف مانیتورینگ پاسخ نمی‌دهد",
      i_res: "{what} بالا است ({v}٪)", i_pending: "{n} هشدار در آستانه‌ی فعال شدن", i_ssl: "گواهی SSL تا {n} روز دیگر منقضی می‌شود",
            net_ifaces: "کارت‌های شبکه", tr_title: "مصرف ترافیک", tr_sub: "کل چیزی که این سرور از طریق کارت‌های شبکه‌ی واقعی‌اش دانلود و آپلود کرده است.",
      tr_day: "روز", tr_today: "امروز", tr_yesterday: "دیروز", tr_7d: "۷ روز اخیر", tr_30d: "۳۰ روز اخیر", tr_boot: "از زمان بوت", tr_total: "مجموع", tr_down: "دانلود", tr_up: "آپلود",
      tr_daily: "ترافیک روزانه", tr_peak_in: "اوج دانلود (۲۴ ساعت)", tr_peak_out: "اوج آپلود (۲۴ ساعت)", tr_partial: "فقط {d} داده جمع‌آوری شده است",
            diag_btn: "پیدا کردن دلیل", dg_title: "چرا پنل داده‌ای نمی‌گیرد؟", diag_services: "سرویس‌ها", diag_containers: "کانتینرهای استک", diag_ok: "در دسترس", diag_fail: "خراب",
      diag_dns: "نام پیدا نشد", diag_http: "پاسخ درست نمی‌دهد", diag_detail: "جزئیات", diag_exit: "کد خروج", diag_restarts: "تعداد ری‌استارت", diag_logs: "آخرین خط‌های لاگ {s}", service: "سرویس",
      diag_all_ok: "همه‌ی سرویس‌ها الان جواب می‌دهند. این پنجره را ببندید و «بروزرسانی» را بزنید.",
      hint_stopped: "{service} در حال اجرا نیست: {detail}. با دکمه‌ی زیر ری‌استارتش کنید؛ آخرین خط‌های لاگ پایین‌تر دلیل متوقف شدنش را نشان می‌دهد.",
      hint_dns: "پنل اصلاً نام «{service}» را پیدا نمی‌کند ({detail}). DNS داخلی داکر جواب نمی‌دهد.",
      hint_svc: "{service} در دسترس است ولی درست جواب نمی‌دهد: {detail}",
      hint_disk: "دیسک {detail} پر است. وقتی جای خالی نباشد Prometheus از کار می‌افتد.",
      hint_dns_external: "DNS اینترنت هم کار نمی‌کند ({detail}). resolver سرور (/etc/resolv.conf) خراب است یا فایروال جلویش را گرفته و داکر از آن استفاده می‌کند.",
      lv_ok: "عادی", lv_warn: "بالا", lv_bad: "بحرانی", address: "آدرس", more: "بیشتر", tbl_view: "نمایش جدول", time: "زمان",
      err_api: "داده‌ها بارگذاری نشد", last_update: "آخرین بروزرسانی", auto: "بروزرسانی خودکار هر ۱۰ ثانیه", ago: "پیش",
      live_on: "زنده · بروزرسانی هر", live_every: "فاصله‌ی بروزرسانی عددهای زنده", live_sec: "{n} ثانیه", live_wait: "در حال اتصال به داده‌ی زنده…", live_waiting: "در انتظار داده‌ی زنده…", live_tag: "زنده",
      live_off_note: "داده‌ی زنده در دسترس نیست ({e})؛ برای همین یک ساعت اخیر نمایش داده می‌شود.", io_r: "خواندن", io_w: "نوشتن", swap: "Swap",
      t_dark: "تم روشن", t_light: "تم تیره",
      add: "افزودن", cancel: "انصراف", close: "بستن", save: "ذخیره", saved: "ذخیره شد", remove: "حذف", working: "در حال انجام…", copy: "کپی", copied: "کپی شد",
      confirm: "لطفاً تأیید کنید", actions: "عملیات", minutes: "دقیقه", added: "اضافه شد", removed: "حذف شد", reset_defaults: "بازگشت به پیش‌فرض",
      a_restart: "ری‌استارت", c_done: "انجام شد",
      c_docker_off: "دسترسی داکر خاموش است، پس وضعیت کانتینرهای استک را نمی‌شود نشان داد. برای فعال‌سازی سوکت داکر را مونت کنید (تنظیمات را ببینید).",
      add_site: "افزودن سایت یا پورت", type_http: "سایت (HTTP / HTTPS)", type_tcp: "پورت TCP", f_target: "آدرس", f_name_opt: "نام (اختیاری)",
      hint_http: "آدرس کامل، مثلاً https://example.com", hint_tcp: "host:port مثل 203.0.113.10:22 (SSH) یا db.internal:5432",
      probe: "آزمایش الان / چرا؟", probe_title: "نتیجه‌ی چک", probe_running: "در حال چک کردن…", probe_ok: "این چک همین الان از سرور موفق است.",
      probe_fail: "این چک از سرور ناموفق است.", probe_reason: "دلیل", probe_log: "جزئیات فنی", probe_status: "کد HTTP",
      probe_k_reset: "سایت (یا شبکه‌ی جلوی آن) اتصال را پذیرفت و وسط handshake قطعش کرد. این رفتار فایروال یا مسدودسازی جغرافیایی است: سایت برای شما باز می‌شود ولی IP این سرور را رد می‌کند.",
      probe_k_refused: "سرور پاسخ داد ولی روی آن پورت چیزی گوش نمی‌دهد (یا فایروال فعالانه رد می‌کند).",
      probe_k_dns: "سرور نمی‌تواند این نام دامنه را پیدا کند. املا و تنظیمات DNS سرور را بررسی کنید.",
      probe_k_timeout: "در زمان مقرر پاسخی نیامد. میزبان خاموش است یا فایروال بی‌صدا بسته‌های این سرور را دور می‌اندازد.",
      probe_k_tls: "گواهی سایت مشکل دارد: منقضی‌شده، برای دامنه‌ی دیگر یا از مرجع نامعتبر.",
      probe_k_unreachable: "این سرور مسیر شبکه‌ای به این آدرس ندارد.",
      probe_k_status: "سایت پاسخ داد ولی با کد خطا (4xx یا 5xx)، پس سالم حساب نمی‌شود.",
      probe_k_other: "چک به دلیل دیگری ناموفق بود؛ جزئیات فنی پایین را ببینید.",
      probe_k_handshake: "سایت اتصال امن را در مرحله‌ی TLS handshake رد کرد. علت‌های معمول: فقط نسخه‌ها یا رمزهای قدیمی TLS را می‌پذیرد، تنظیم گواهی/SNI خراب است، یا فایروالش IP این سرور را رد می‌کند. جدول پایین گزینه‌های جایگزین را برایتان امتحان می‌کند.",
      v_legacy_tls: "پذیرش TLS قدیمی (۱.۰ / ۱.۱)", v_no_verify: "نادیده گرفتن خطای گواهی", v_legacy_no_verify: "TLS قدیمی و نادیده گرفتن خطای گواهی",
      v_plain_http: "HTTP ساده (بدون رمزنگاری)", v_tcp: "فقط اتصال به پورت (TCP)",
      diag_title: "چه چیزی از سرور کار می‌کند", diag_works: "کار می‌کند", diag_fails: "ناموفق", diag_apply: "مانیتور سایت با این حالت",
      diag_suggest: "سایت در حالتی که پایین علامت خورده موفق است. چک را روی آن بگذارید تا بدون هشدار اشتباه مانیتور شود.",
      diag_applied: "حالت چک عوض شد. وضعیت تا یک دقیقه‌ی دیگر بروز می‌شود.", mode_default: "استاندارد",
      mode_legacy_tls: "TLS قدیمی", mode_no_verify: "بدون بررسی گواهی", mode_legacy_no_verify: "TLS قدیمی، بدون بررسی گواهی",
      diag_blocked: "پورت اتصال را می‌پذیرد ولی همه‌ی حالت‌های امن رد می‌شوند: سایت یا فایروالش مشخصاً این سرور را رد می‌کند (معمول در مسدودسازی IP یا جغرافیایی).",
      diag_plain: "HTTP ساده کار می‌کند ولی هر تلاش امن (HTTPS) با هر حالت TLS رد می‌شود. سایت بالاست؛ بخش HTTPS آن این سرور را رد می‌کند. می‌توانید به‌جای آن روی HTTP ساده مانیتورش کنید (اگر آن آدرس به یک صفحه‌ی HTTPS ریدایرکت شود، گواهی همان صفحه همچنان چک می‌شود).",
      diag_use_http: "مانیتور روی HTTP ساده", diag_replaced: "حالا آدرس HTTP ساده مانیتور می‌شود.",
      diag_closed: "حتی اتصال ساده‌ی TCP هم ناموفق است: آدرس از این سرور در دسترس نیست (خاموش، پورت اشتباه یا مسدود).",
      auto_title: "رفع خودکار سایت‌های خراب",
      auto_text: "وقتی سایتی مدام ناموفق است، پنل راه‌های دیگر چک را امتحان می‌کند (TLS قدیمی، نادیده گرفتن خطای گواهی، صفحه‌ای که آدرس http:// به آن ریدایرکت می‌شود، HTTP ساده) و روی اولین راهی که کار کند می‌رود. چکِ سالم هرگز تغییر نمی‌کند. برای اینکه آدرس‌ها دقیقاً همان‌طور که وارد کردید بمانند، خاموشش کنید.",
      auto_on: "سایت‌های خراب را خودکار درست کن", auto_off_saved: "رفع خودکار خاموش شد", auto_on_saved: "رفع خودکار روشن شد",
      auto_log: "تنظیمات خودکار", auto_tag: "خودکار", auto_was: "قبلاً {from}",
      auto_ev_replace: "{from} حالا به‌صورت {to} مانیتور می‌شود", auto_ev_mode: "{from} حالا با این حالت چک می‌شود: {mode}", auto_ev_merge: "{from} حذف شد: {to} از قبل مانیتور می‌شود",
      auto_fix_btn: "رفع خودکار", auto_done: "انجام شد. وضعیت تا یک دقیقه‌ی دیگر بروز می‌شود.",
      auto_none: "راه بهتری پیدا نشد: هیچ راه دیگری برای چک این آدرس از سرور کار نمی‌کند.",
      added_auto: "اضافه شد. پنل خودکار بهترین راه مانیتور آن را انتخاب می‌کند.", redirects_to: "ریدایرکت می‌شود به",
      probe_hint: "اگر آدرس در مرورگر شما باز می‌شود ولی اینجا ناموفق است، احتمالاً IP سرور توسط سایت یا شبکه‌اش مسدود است (برای سایت‌های میزبانی‌شده در ایران وقتی سرور مانیتورینگ خارج از ایران است رایج است) یا سرور مسیری به آن ندارد. مانیتورینگ همان چیزی را نشان می‌دهد که «سرور» می‌بیند، نه آنچه شما می‌بینید.",
      s_wait: "در انتظار", w_confirm_remove: "نظارت بر {n} متوقف شود؟", w_hint: "موارد جدید تا تکمیل اولین چک (حدود یک دقیقه) «در انتظار» نشان داده می‌شوند.",
      add_server: "افزودن سرور", f_srv_addr: "آدرس سرور", f_srv_hint: "آی‌پی یا نام سرور همراه پورت node_exporter، مثل 203.0.113.10:9100",
      srv_local: "همین سرور", srv_confirm_remove: "نظارت بر سرور {n} متوقف شود؟",
      srv_help_title: "چطور سرور دیگری را اضافه کنم",
      srv_help_1: "۱. روی سرور دیگر node_exporter را اجرا کنید (داکر لازم است):",
      srv_help_2: "۲. پورت 9100 را فقط برای همین سرور مانیتورینگ در فایروال آن سرور باز کنید، مثلاً:",
      srv_help_3: "۳. روی «افزودن سرور» بزنید و آدرسش را به شکل IP:9100 وارد کنید.",
      tg_title: "تلگرام", tg_ok: "متصل", tg_no: "تنظیم نشده", tg_bot: "ربات",
      tg_s1: "تلگرام را باز کنید، با @BotFather صحبت کنید، /newbot را بفرستید و توکنی که می‌دهد را کپی کنید.",
      tg_s2: "ربات جدیدتان را باز کنید و Start بزنید (یا آن را به گروه اضافه کنید و یک پیام بنویسید).",
      tg_s3: "توکن را پایین بچسبانید و «پیدا کردن Chat ID» را بزنید. چت را انتخاب کنید و ذخیره کنید.",
      tg_token: "توکن ربات", tg_token_saved: "ذخیره‌شده: {h} (برای نگه داشتن خالی بگذارید)", tg_chat: "Chat ID", tg_find: "پیدا کردن Chat ID",
      tg_found: "برای انتخاب روی یک چت بزنید:", tg_none: "هنوز چتی پیدا نشد. در تلگرام به ربات پیام بدهید و دوباره تلاش کنید.",
      tg_test: "ارسال پیام آزمایشی", tg_test_ok: "پیام آزمایشی فرستاده شد. تلگرام را ببینید.", tg_saved: "تلگرام ذخیره شد. هشدارها به آنجا می‌روند.",
      tg_remove: "قطع اتصال", tg_confirm_remove: "ارسال هشدار به تلگرام متوقف شود؟", tg_removed: "اتصال تلگرام قطع شد",
      at_title: "آزمایش کل مسیر هشدار", at_text: "یک هشدار آزمایشی بی‌خطر را از طریق Alertmanager می‌فرستد. اگر تلگرام وصل باشد، پیام تا حدود ۳۰ ثانیه می‌رسد.",
      at_btn: "ارسال هشدار آزمایشی", at_ok: "هشدار آزمایشی ارسال شد. تلگرام تا حدود ۳۰ ثانیه دیگر پیام می‌گیرد.",
      rl_rule: "قانون", rl_enabled: "روشن", rl_threshold: "آستانه", rl_for: "مدت پایداری", rl_reset_confirm: "همه‌ی قانون‌ها به آستانه‌ی پیش‌فرض برگردند و روشن شوند؟",
      rl_saved: "قانون ذخیره و اعمال شد", rl_reset_ok: "پیش‌فرض‌ها برگشتند",
      rn_InstanceDown: "تارگت قطع شده", rn_HighCpuUsage: "پردازنده‌ی بالا", rn_HighMemoryUsage: "حافظه‌ی بالا", rn_DiskSpaceLow: "دیسک تقریباً پر",
      rn_DiskWillFillIn24h: "دیسک به‌زودی پر می‌شود", rn_HighLoad: "بار زیاد", rn_HostRebooted: "سرور ری‌استارت شد", rn_ContainerHighCpu: "کانتینر: پردازنده‌ی بالا",
      rn_ContainerHighMemory: "کانتینر: حافظه‌ی بالا", rn_EndpointDown: "سایت یا پورت قطع", rn_SslCertExpiringSoon: "گواهی SSL رو به انقضا",
      rn_SlowEndpoint: "سایت کند", sev_critical: "بحرانی", sev_warning: "هشدار", sev_info: "اطلاع",
      rd_InstanceDown: "یکی از تارگت‌ها (سرور، اکسپورتر یا چک‌کننده) پاسخ نمی‌دهد.",
      rd_HighCpuUsage: "مصرف پردازنده مدتی بالاتر از آستانه می‌ماند.",
      rd_HighMemoryUsage: "مصرف رم مدتی بالاتر از آستانه می‌ماند.",
      rd_DiskSpaceLow: "یک دیسک بیشتر از آستانه پر شده است.",
      rd_DiskWillFillIn24h: "با روند فعلی، یک دیسک تا این تعداد ساعت دیگر پر می‌شود.",
      rd_HighLoad: "میانگین بار به ازای هر هسته بالاتر از آستانه است.",
      rd_HostRebooted: "یک سرور در این تعداد ثانیه‌ی اخیر ری‌استارت شده است.",
      rd_ContainerHighCpu: "یک کانتینر بیشتر از آستانه پردازنده مصرف می‌کند.",
      rd_ContainerHighMemory: "یک کانتینر بیشتر از آستانه‌ی سقف رم خودش مصرف می‌کند.",
      rd_EndpointDown: "چک یک سایت یا پورت ناموفق است.",
      rd_SslCertExpiringSoon: "گواهی SSL کمتر از این تعداد روز اعتبار دارد.",
      rd_SlowEndpoint: "پاسخ یک سایت بیشتر از این زمان طول می‌کشد.",
      st_pw_title: "تغییر اطلاعات ورود", st_user: "نام کاربری", st_current: "رمز فعلی", st_new: "رمز جدید (حداقل ۸ نویسه)", st_repeat: "تکرار رمز جدید",
      st_change: "تغییر اطلاعات ورود", st_mismatch: "دو رمز یکسان نیستند", st_pw_ok: "اطلاعات ورود عوض شد. دستگاه‌های دیگر خارج شدند.",
      st_docker_title: "دسترسی داکر", st_docker_on: "فعال", st_docker_off: "خاموش",
      st_docker_hint_on: "پنل از سوکت داکر فقط برای استک مانیتورینگ خودش استفاده می‌کند: نشان دادن دلیل متوقف شدن یک سرویس و ری‌استارت آن از صفحه‌ی «پیدا کردن دلیل». هر کسی به این سوکت برسد روی سرور root است؛ پس رمز قوی بگذارید و جلوی پنل HTTPS قرار دهید.",
      st_docker_hint_off: "پنل وضعیت کانتینرهای استک خودش را نمی‌بیند. برای فعال‌سازی، مطمئن شوید مونت docker.sock در docker-compose.yml هست و PANEL_DOCKER_CONTROL برابر 0 نیست، سپس بزنید: docker compose up -d",
      st_docker_unavail: "در تنظیمات فعال است ولی سوکت داکر در دسترس نیست.",
      st_about: "درباره", st_version: "نسخه‌ی پنل",
    },
  };
  // ---------------------------------------------------------------- state
  const store = {
    get(k, d) { try { return localStorage.getItem(k) || d; } catch (e) { return d; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* storage blocked */ } },
  };
  const state = {
    lang: T[store.get("lang", "en")] ? store.get("lang", "en") : "en",
    theme: document.documentElement.dataset.theme === "light" ? "light" : "dark",   // set by boot.js before the first paint
    range: store.get("range", "live"),
    instance: store.get("instance", ""),
    liveEvery: [1, 3, 5, 10].includes(+store.get("live_every", "1")) ? +store.get("live_every", "1") : 1,
    instances: [],
    names: {},
    view: "overview",
    overview: null,
    settings: null,
    renderId: 0,
  };
  const t = (k, vars) => {
    let s = T[state.lang][k] ?? T.en[k] ?? k;
    if (vars) for (const [a, b] of Object.entries(vars)) s = s.replace(`{${a}}`, b);
    return s;
  };

  // ---------------------------------------------------------------- helpers
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const nf = (n, d = 1) => (n == null ? "–" : Number(n).toLocaleString("en-US", { maximumFractionDigits: d, minimumFractionDigits: 0 }));
  const num = (html) => `<span class="num">${html}</span>`;

  function fmtBytes(n) {
    if (n == null) return "–";
    const u = ["B", "KB", "MB", "GB", "TB", "PB"];
    let i = 0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return `${nf(n, n >= 100 || i === 0 ? 0 : 1)} ${u[i]}`;
  }
  const fmtRate = (n) => (n == null ? "–" : `${fmtBytes(n)}/s`);
  function fmtDur(s) {
    if (s == null) return "–";
    s = Math.floor(s);
    const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
    if (d) return `${d}d ${h}h`;
    if (h) return `${h}h ${m}m`;
    return `${m}m ${s % 60}s`;
  }
  const fmtMs = (s) => (s == null ? "–" : s < 1 ? `${nf(s * 1000, 0)} ms` : `${nf(s, 2)} s`);
  const level = (pct) => (pct >= 90 ? "bad" : pct >= 75 ? "warn" : "");
  function ago(unixOrIso) {
    const ts = typeof unixOrIso === "number" ? unixOrIso : Date.parse(unixOrIso) / 1000;
    if (!ts) return "–";
    return `${fmtDur(Date.now() / 1000 - ts)} ${t("ago")}`;
  }

  const P = {
    logo: '<path d="M12 3l8 3v6c0 4.6-3.2 7.9-8 9.8C7.2 19.9 4 16.6 4 12V6l8-3z"/><path d="M8 12h2.5l1.5-3 2 6 1.5-3H17"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
    moon: '<path d="M21 13.5A8.5 8.5 0 1110.5 3a6.5 6.5 0 0010.5 10.5z"/>',
    globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3 3.3 3 14.7 0 18M12 3c-3 3.3-3 14.7 0 18"/>',
    refresh: '<path d="M20 11a8 8 0 10-2.3 5.7M20 4v7h-7"/>',
    logout: '<path d="M9 4H5a1 1 0 00-1 1v14a1 1 0 001 1h4M16 8l4 4-4 4M20 12H9"/>',
    cpu: '<rect x="5" y="5" width="14" height="14" rx="2"/><rect x="9" y="9" width="6" height="6"/><path d="M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3"/>',
    memory: '<rect x="2" y="7" width="20" height="10" rx="2"/><path d="M6 11v2M10 11v2M14 11v2M18 11v2M6 17v2M10 17v2M14 17v2M18 17v2"/>',
    disk: '<ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v14c0 1.7 3.6 3 8 3s8-1.3 8-3V5M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>',
    activity: '<path d="M3 12h4l3-8 4 16 3-8h4"/>',
    down: '<path d="M12 4v12M6 11l6 6 6-6M5 21h14"/>',
    up: '<path d="M12 20V8M6 13l6-6 6 6M5 3h14"/>',
    box: '<path d="M21 8l-9-5-9 5v8l9 5 9-5V8z"/><path d="M3 8l9 5 9-5M12 13v8"/>',
    check: '<circle cx="12" cy="12" r="9"/><path d="M8 12.5l2.7 2.7L16 9.5"/>',
    lock: '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 018 0v3"/>',
    bell: '<path d="M18 16v-5a6 6 0 10-12 0v5l-2 2h16l-2-2zM10 21h4"/>',
    server: '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01"/>',
    network: '<circle cx="12" cy="5" r="2.2"/><circle cx="5" cy="19" r="2.2"/><circle cx="19" cy="19" r="2.2"/><path d="M12 7.2v4M12 11.2L5.5 16.8M12 11.2l6.5 5.6"/>',
    grid: '<rect x="3" y="3" width="8" height="8" rx="2"/><rect x="13" y="3" width="8" height="5" rx="2"/><rect x="13" y="10" width="8" height="11" rx="2"/><rect x="3" y="13" width="8" height="8" rx="2"/>',
    okmark: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    trash: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a1 1 0 001 1h8a1 1 0 001-1l1-12M9 7V4h6v3"/>',
    play: '<path d="M7 4.5v15l12-7.5-12-7.5z"/>',
    stop: '<rect x="6" y="6" width="12" height="12" rx="2"/>',
    file: '<path d="M14 3H7a1 1 0 00-1 1v16a1 1 0 001 1h10a1 1 0 001-1V8l-4-5z"/><path d="M14 3v5h5M9 13h6M9 17h6"/>',
    send: '<path d="M21 3L10 14M21 3l-7 18-4-7-7-4 18-7z"/>',
    sliders: '<path d="M4 7h10M18 7h2M4 17h2M10 17h10"/><circle cx="16" cy="7" r="2"/><circle cx="8" cy="17" r="2"/>',
    gear: '<circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M4.9 19.1L7 17M17 7l2.1-2.1"/>',
    search: '<circle cx="11" cy="11" r="6.5"/><path d="M16 16l5 5"/>',
    x: '<path d="M6 6l12 12M18 6L6 18"/>',
    shield: '<path d="M12 3l8 3v6c0 4.6-3.2 7.9-8 9.8C7.2 19.9 4 16.6 4 12V6l8-3z"/><path d="M8.5 12.2l2.4 2.4 4.6-4.8"/>',
    alert: '<path d="M12 3.6l9.4 16.4H2.6L12 3.6z"/><path d="M12 10v4.4M12 17.4h.01"/>',
    octagon: '<path d="M8.2 3h7.6L21 8.2v7.6L15.8 21H8.2L3 15.8V8.2L8.2 3z"/><path d="M9.2 9.2l5.6 5.6M14.8 9.2l-5.6 5.6"/>',
    dots: '<circle cx="5" cy="12" r="1.3"/><circle cx="12" cy="12" r="1.3"/><circle cx="19" cy="12" r="1.3"/>',
    table: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18M9 4v16"/>',
    copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V5a1 1 0 00-1-1H5a1 1 0 00-1 1v10a1 1 0 001 1h3"/>',
  };
  const icon = (name) => `<svg class="ico" viewBox="0 0 24 24" aria-hidden="true">${P[name]}</svg>`;

  async function api(path, params = {}) {
    const qs = new URLSearchParams(params).toString();
    const r = await fetch(path + (qs ? `?${qs}` : ""), { credentials: "same-origin", cache: "no-store" });
    if (r.status === 401) { location.replace("/login"); throw new Error("unauthorized"); }
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(body.error || `HTTP ${r.status}`);
    return body;
  }
  async function post(path, body = {}) {
    const r = await fetch(path, {
      method: "POST", credentials: "same-origin", cache: "no-store",
      headers: { "Content-Type": "application/json", "X-Panel": "1" }, body: JSON.stringify(body),
    });
    if (r.status === 401) { location.replace("/login"); throw new Error("unauthorized"); }
    const data = await r.json().catch(() => ({}));
    if (!r.ok) { const e = new Error(data.error || `HTTP ${r.status}`); e.saved = !!data.saved; throw e; }
    return data;
  }
  const withInstance = (extra = {}) => (state.instance ? { instance: state.instance, ...extra } : extra);

  // ---------------------------------------------------------------- toasts, dialogs, small UI helpers
  function toast(message, kind = "") {
    const el = document.createElement("div");
    el.className = `toast ${kind}`;
    el.setAttribute("role", kind === "bad" ? "alert" : "status");
    el.textContent = message;
    const box = $("toasts");
    box.appendChild(el);
    while (box.children.length > 4) box.firstChild.remove();   // never pile up a long stack
    setTimeout(() => el.remove(), kind ? 8000 : 4000);
  }

  function openDialog(o) {
    const dlg = document.createElement("dialog");
    dlg.className = `modal${o.wide ? " wide" : ""}`;
    dlg.innerHTML = `<form class="modal-form">
      <header><h3>${esc(o.title)}</h3><button type="button" class="btn small icon ghost" data-close aria-label="${esc(t("close"))}">${icon("x")}</button></header>
      <div class="modal-body">${o.body}</div>
      <div class="form-error" role="alert"></div>
      <footer><button type="button" class="btn" data-close>${esc(o.cancel || t("cancel"))}</button>${o.hideSubmit ? "" : `<button type="submit" class="btn ${o.danger ? "danger solid" : "primary"}">${esc(o.submit || t("save"))}</button>`}</footer>
    </form>`;
    const form = dlg.querySelector("form"), err = dlg.querySelector(".form-error"), submitBtn = dlg.querySelector('[type="submit"]');
    dlg.querySelectorAll("[data-close]").forEach((b) => b.addEventListener("click", () => dlg.close()));
    dlg.addEventListener("close", () => dlg.remove());
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      err.textContent = "";
      if (!o.onSubmit) { dlg.close(); return; }
      const label = submitBtn.textContent;
      submitBtn.disabled = true;
      submitBtn.textContent = o.busy || t("working");
      try { await o.onSubmit(form, dlg); dlg.close(); }
      catch (x) { if (x.message !== "unauthorized") err.textContent = x.message; }
      finally { submitBtn.disabled = false; submitBtn.textContent = label; }
    });
    document.body.appendChild(dlg);
    dlg.showModal();
    if (o.onOpen) o.onOpen(dlg, form);
    return dlg;
  }

  function confirmBox({ message, label, danger = true }) {
    return new Promise((resolve) => {
      let answered = false;
      const dlg = openDialog({
        title: t("confirm"), body: `<p>${esc(message)}</p>`, submit: label, danger,
        onSubmit: async () => { answered = true; resolve(true); },
      });
      dlg.addEventListener("close", () => { if (!answered) resolve(false); });
    });
  }

  // Runs an action on a button: disables it, reports errors as toasts, optionally confirms success.
  async function act(btn, fn, okMessage) {
    if (btn) btn.disabled = true;
    try {
      const result = await fn();
      if (okMessage) toast(okMessage);
      return result ?? true;
    } catch (e) {
      if (e.message !== "unauthorized") toast(e.message, e.saved ? "warn" : "bad");
      return null;
    } finally { if (btn) btn.disabled = false; }
  }

  function copyText(text) {
    // navigator.clipboard only exists on HTTPS/localhost; the panel is often served over plain HTTP.
    const ta = document.createElement("textarea");
    ta.value = text; ta.style.position = "fixed"; ta.style.opacity = "0";
    document.body.appendChild(ta); ta.select();
    let ok = false;
    try { ok = document.execCommand("copy"); } catch (e) { /* ignore */ }
    ta.remove();
    toast(ok ? t("copied") : text, ok ? "" : "warn");
  }

  // ---------------------------------------------------------------- chrome (header, nav)
  const VIEWS = [
    { id: "overview", icon: "grid", label: "overview", desc: "d_overview", group: "monitor" },
    { id: "websites", icon: "globe", label: "websites_nav", desc: "d_websites", group: "monitor" },
    { id: "disks", icon: "disk", label: "disks", desc: "d_disks", group: "monitor" },
    { id: "network", icon: "network", label: "network", desc: "d_network", group: "monitor" },
    { id: "targets", icon: "check", label: "targets_nav", desc: "d_targets", group: "monitor" },
    { id: "alerts", icon: "bell", label: "alerts_nav", desc: "d_alerts", group: "monitor" },
    { id: "servers", icon: "server", label: "servers_nav", desc: "d_servers", group: "manage" },
    { id: "notifications", icon: "send", label: "notifications_nav", desc: "d_notifications", group: "manage", static: true },
    { id: "rules", icon: "sliders", label: "rules_nav", desc: "d_rules", group: "manage", static: true },
    { id: "settings", icon: "gear", label: "settings_nav", desc: "d_settings", group: "manage", static: true },
  ];

  function applyLocale() {
    document.documentElement.lang = state.lang;
    document.documentElement.dir = state.lang === "fa" ? "rtl" : "ltr";
    document.documentElement.dataset.theme = state.theme;
    document.title = t("title");
    document.querySelectorAll("[data-i18n]").forEach((el) => { el.textContent = t(el.dataset.i18n); });
    $("logo").innerHTML = icon("logo");
    $("top-logo").innerHTML = icon("logo");
    $("theme").innerHTML = icon(state.theme === "dark" ? "sun" : "moon");
    $("theme").setAttribute("aria-label", state.theme === "dark" ? t("t_dark") : t("t_light"));
    $("theme").title = $("theme").getAttribute("aria-label");
    $("lang").innerHTML = `${icon("globe")}<span class="txt">${esc(t("lang_switch"))}</span>`;
    $("refresh").innerHTML = `${icon("refresh")}<span class="txt">${esc(t("refresh"))}</span>`;
    $("logout").innerHTML = `${icon("logout")}<span class="txt">${esc(t("logout"))}</span>`;
    for (const id of ["lang", "refresh", "logout"]) $(id).title = $(id).textContent.trim();
    document.querySelector('meta[name="theme-color"]').setAttribute("content", state.theme === "dark" ? "#070b12" : "#eef2f8");
    renderNav();
  }

  function badgeFor(id) {
    const o = state.overview, s = state.settings;
    if (id === "notifications") return s && !s.telegram.configured ? '<span class="badge bad">!</span>' : "";
    if (id === "servers") return state.instances.length ? `<span class="badge">${state.instances.length}</span>` : "";
    if (!o) return "";
    if (id === "websites") return o.checks.total ? `<span class="badge${o.checks.up < o.checks.total ? " bad" : ""}">${o.checks.up}/${o.checks.total}</span>` : "";
    if (id === "targets") return `<span class="badge${o.targets.up < o.targets.total ? " bad" : ""}">${o.targets.up}/${o.targets.total}</span>`;
    if (id === "alerts") return o.alerts.firing ? `<span class="badge bad">${o.alerts.firing}</span>` : "";
    return "";
  }
  const TAB_IDS = ["overview", "websites", "network", "alerts"];   // the rest live behind "More" on phones
  function renderNav() {
    const link = (v) => `<a href="#${v.id}" class="${v.id === state.view ? "active" : ""}" ${v.id === state.view ? 'aria-current="page"' : ""} title="${esc(t(v.label))}">${icon(v.icon)}<span class="name">${esc(t(v.label))}</span>${badgeFor(v.id)}</a>`;
    $("nav").innerHTML = VIEWS.filter((v) => v.group === "monitor").map(link).join("");
    $("nav-manage").innerHTML = VIEWS.filter((v) => v.group === "manage").map(link).join("");
    const cur = VIEWS.find((v) => v.id === state.view) || VIEWS[0];
    $("page-title").textContent = t(cur.label);
    const firing = state.overview ? state.overview.alerts.firing : 0;
    const tab = (v) => `<button type="button" data-go="${v.id}" class="${v.id === state.view ? "active" : ""}" ${v.id === state.view ? 'aria-current="page"' : ""}>${icon(v.icon)}<span class="lbl">${esc(t(v.label))}</span>${v.id === "alerts" && firing ? `<span class="dot">${firing}</span>` : ""}</button>`;
    $("tabbar").innerHTML = TAB_IDS.map((id) => tab(VIEWS.find((v) => v.id === id))).join("")
      + `<button type="button" data-more class="${TAB_IDS.includes(cur.id) ? "" : "active"}">${icon("dots")}<span class="lbl">${esc(t("more"))}</span></button>`;
  }

  // Phones: every view that has no tab sits in a bottom sheet.
  function moreSheet() {
    const dlg = document.createElement("dialog");
    dlg.className = "sheet";
    dlg.innerHTML = `<div class="sheet-card"><h3>${esc(t("more"))}</h3><div class="sheet-grid">${VIEWS.filter((v) => !TAB_IDS.includes(v.id)).map((v) =>
      `<button type="button" data-go="${v.id}" class="${v.id === state.view ? "active" : ""}">${icon(v.icon)}<span>${esc(t(v.label))}</span></button>`).join("")}</div></div>`;
    dlg.addEventListener("click", (e) => { if (e.target === dlg || e.target.closest("[data-go]")) dlg.close(); });
    dlg.addEventListener("close", () => dlg.remove());
    document.body.appendChild(dlg);
    dlg.showModal();
  }

  // ---------------------------------------------------------------- live stream (one sample a second, see live.py)
  // Prometheus answers for history and for everything else; the gauges, tiles, network rates and the
  // "Live" chart range come from /api/live, which the panel reads from node_exporter every second.
  const LIVE_KEEP = 300;
  state.live = { status: "off", error: "", samples: [], es: null, instance: null, retry: 0 };
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const liveWanted = () => !document.hidden && ["overview", "network", "defender"].includes(state.view);
  function liveNow() {
    const L = state.live, s = L.samples[L.samples.length - 1];
    return L.status === "live" && s && Date.now() / 1000 - s.t < Math.max(8, state.liveEvery * 2.5) ? s : null;
  }
  function stopLive() {
    const L = state.live;
    clearTimeout(L.retry);
    if (L.es) { L.es.close(); L.es = null; }
    if (L.status !== "error") L.status = "off";
  }
  function startLive() {
    const L = state.live, inst = state.instance || "";
    if (!liveWanted() || !window.EventSource) { stopLive(); paintFoot(); return; }
    if (L.es && L.instance === inst) return;
    stopLive();
    if (L.instance !== inst) L.samples = [];
    L.instance = inst;
    L.status = "wait";
    L.startedAt = Date.now();
    const last = L.samples[L.samples.length - 1];
    const q = new URLSearchParams({ ...(inst ? { instance: inst } : {}), ...(last ? { since: String(last.t) } : {}), every: String(state.liveEvery) });
    const es = new EventSource(`/api/live?${q}`);
    L.es = es;
    es.addEventListener("s", (e) => {
      const batch = JSON.parse(e.data), top = L.samples.length ? L.samples[L.samples.length - 1].t : 0;
      for (const s of batch) if (s.t > top) L.samples.push(s);
      if (L.samples.length > LIVE_KEEP) L.samples.splice(0, L.samples.length - LIVE_KEEP);
      L.status = "live";
      L.error = "";
      beat();
      schedulePaint();
    });
    es.addEventListener("status", (e) => {
      L.error = JSON.parse(e.data).error || "";
      if (L.error) L.status = "error";
      else if (L.status === "error") L.status = "wait";
      schedulePaint();
    });
    es.onerror = () => {
      if (es.readyState === EventSource.CLOSED) {   // refused (unknown server, Prometheus down, logged out)
        if (L.es === es) L.es = null;
        L.status = "error";
        clearTimeout(L.retry);
        L.retry = setTimeout(startLive, 15000);
      } else if (L.status === "live") L.status = "wait";   // dropped; the browser reconnects by itself
      schedulePaint();
    };
    paintFoot();
  }
  let paintQueued = false;
  function schedulePaint() {   // next frame; the timer covers windows where frames are paused (e.g. an embedded, covered view)
    if (paintQueued) return;
    paintQueued = true;
    let done = false;
    const run = () => { if (done) return; done = true; paintQueued = false; paintLive(); };
    requestAnimationFrame(run);
    setTimeout(run, 250);
  }
  function paintLive() {
    paintFoot();
    if (state.view === "overview") {
      paintStats();
      if (state.range === "live") paintLiveCharts();
    } else if (state.view === "network") paintNetLive();
  }
  function beat() {
    const p = document.querySelector(".live .pulse");
    if (!p || reduceMotion.matches) return;
    p.classList.remove("beat");
    void p.offsetWidth;   // restart the animation
    p.classList.add("beat");
  }
  function paintFoot() {
    const L = state.live, box = document.querySelector(".live"), el = $("foot");
    const on = L.status === "live" && liveWanted(), wait = L.status === "wait" && liveWanted();
    box.classList.toggle("is-live", on);
    box.classList.toggle("is-wait", wait);
    const at = state.lastUpdate ? state.lastUpdate.toLocaleTimeString([], { hour12: false }) : "";
    el.textContent = on ? t("live_on") : wait ? t("live_wait") : `${t("last_update")}: ${at} · ${t("auto")}`;
    box.title = L.status === "error" && L.error ? L.error : "";
    const sel = $("live-every");
    sel.hidden = !on;
    const opts = [1, 3, 5, 10].map((n) => `<option value="${n}"${n === state.liveEvery ? " selected" : ""}>${esc(t("live_sec", { n: nf(n, 0) }))}</option>`).join("");
    if (sel._html !== opts) { sel._html = opts; sel.innerHTML = opts; sel.setAttribute("aria-label", t("live_every")); }
  }

  // Numbers jump straight to their new value (2 -> 4, never 2, 3, 4); the HTML is only touched when it changed.
  function tween(el, to, render) {
    if (!el) return;
    const bad = to == null || (Array.isArray(to) && to.some((x) => x == null));
    el._shown = bad ? null : to;
    const html = render(to);
    if (el._html !== html) { el._html = html; el.innerHTML = html; }
  }
  const setHTML = (el, html) => { if (el && el._html !== html) { el._html = html; el.innerHTML = html; } };

  // ---------------------------------------------------------------- overview: health hero, gauges, tiles
  state.hist = {};
  const SPARK_W = 120, SPARK_H = 34, SPARK_LIVE = 120;
  function sparkline(points, color) {
    const pts = (points || []).filter((p) => p[1] != null);
    if (pts.length < 2) return "";
    const xs = pts.map((p) => p[0]), vs = pts.map((p) => p[1]);
    const x0 = Math.min(...xs), x1 = Math.max(...xs), lo = Math.min(...vs), hi = Math.max(...vs), pad = (hi - lo) * 0.18 || 1;
    const X = (ts) => ((ts - x0) / Math.max(1, x1 - x0)) * SPARK_W;
    const Y = (v) => 4 + (1 - (v - (lo - pad * 0.2)) / (hi - lo + pad * 1.2)) * (SPARK_H - 8);
    const d = pts.map((p, i) => `${i ? "L" : "M"}${X(p[0]).toFixed(1)},${Y(p[1]).toFixed(1)}`).join("");
    const last = pts[pts.length - 1];
    return `<svg viewBox="0 0 ${SPARK_W} ${SPARK_H}" preserveAspectRatio="none" aria-hidden="true"><path d="${d}L${SPARK_W},${SPARK_H}L0,${SPARK_H}Z" fill="${color}" opacity=".11"/><path d="${d}" fill="none" stroke="${color}" stroke-width="2" vector-effect="non-scaling-stroke" stroke-linejoin="round" stroke-linecap="round"/></svg><i class="sd" style="top:${Y(last[1]).toFixed(1)}px;background:${color}"></i>`;
  }
  const memPctOf = (s) => (s.mem && s.mem[1] ? (s.mem[0] / s.mem[1]) * 100 : null);
  const LIVE_PICK = { cpu: [(s) => s.cpu], mem: [memPctOf], net: [(s) => s.rx, (s) => s.tx] };
  function sparkPoints(key, idx) {
    if (liveNow() && state.live.samples.length >= 2) return state.live.samples.slice(-SPARK_LIVE).map((s) => [s.t, LIVE_PICK[key][idx](s)]);
    return ((state.hist[key] || [])[idx] || {}).points;
  }
  const sparkBox = (key, idx, color) => `<div class="spark" data-spark="${key}" data-idx="${idx}" data-color="${color}">${sparkline(sparkPoints(key, idx), `var(${color})`)}</div>`;
  function refreshSparks() {
    document.querySelectorAll("[data-spark]").forEach((el) => setHTML(el, sparkline(sparkPoints(el.dataset.spark, +el.dataset.idx), `var(${el.dataset.color})`)));
  }

  function health(o, memPct) {
    const issues = [];
    let sev = 0;
    const bump = (n, msg) => { issues.push(msg); sev = Math.max(sev, n); };
    if (o.alerts.firing) bump(2, t("i_alerts", { n: o.alerts.firing }));
    if (o.checks.total > o.checks.up) bump(2, t("i_sites", { n: o.checks.total - o.checks.up }));
    if (o.targets.total > o.targets.up) bump(2, t("i_targets", { n: o.targets.total - o.targets.up }));
    for (const [what, v] of [[t("cpu"), o.cpu], [t("memory"), memPct], [t("disk"), o.disk ? o.disk.pct : null]]) {
      if (v == null) continue;
      if (v >= 90) bump(2, t("i_res", { what, v: nf(v, 0) }));
      else if (v >= 75) bump(1, t("i_res", { what, v: nf(v, 0) }));
    }
    if (o.alerts.pending) bump(1, t("i_pending", { n: o.alerts.pending }));
    const ssl = o.checks.min_ssl_days;
    if (ssl != null && ssl < 14) bump(ssl < 7 ? 2 : 1, t("i_ssl", { n: nf(ssl, 0) }));
    return { sev, issues };
  }

  // The overview numbers: Prometheus' snapshot, with this second's live sample on top when there is one.
  function merged() {
    const o = state.overview;
    if (!o) return null;
    const s = liveNow();
    if (!s) return o;
    return {
      ...o,
      cpu: s.cpu ?? o.cpu,
      mem: s.mem ? { used: s.mem[0], total: s.mem[1] } : o.mem,
      load: s.load && s.load[0] != null ? s.load : o.load,
      net: { rx: s.rx ?? o.net.rx, tx: s.tx ?? o.net.tx },
      disk: s.disk ? { ...(o.disk || {}), ...s.disk, pct: (s.disk.used / s.disk.total) * 100 } : o.disk,
      io: s.io,
    };
  }

  const RING_C = 2 * Math.PI * 42;
  const ringSvg = () => `<svg viewBox="0 0 104 104" aria-hidden="true"><circle class="track" cx="52" cy="52" r="42" fill="none" stroke-width="10"/><circle class="fill" cx="52" cy="52" r="42" fill="none" stroke-width="10" stroke-dasharray="0 ${RING_C.toFixed(1)}"/></svg>`;
  const LVL = { "": "lv_ok", warn: "lv_warn", bad: "lv_bad" };
  function gauge({ k, label, ic, go = "", spark = "" }) {
    return `<div class="card stat gauge" data-g="${k}" ${go ? `data-go="${go}" role="link" tabindex="0"` : ""}>
      <div class="ring">${ringSvg()}<div class="center"><span class="value num">–</span></div></div>
      <div class="g-title">${icon(ic)}${esc(label)}</div>
      <div class="g-main"></div>
      <div class="sub"><span class="lvl"></span><span class="g-sub"></span></div>
      ${spark}
    </div>`;
  }
  function tile({ k, label, ic, go = "", tight = false, spark = "" }) {
    return `<div class="card stat" data-t="${k}" ${go ? `data-go="${go}" role="link" tabindex="0"` : ""}><div class="label">${icon(ic)}${esc(label)}</div><div class="value${tight ? " tight" : ""}"></div><div class="sub" hidden></div>${spark}</div>`;
  }
  const pctHTML = (v) => (v == null ? "–" : `${nf(v, 0)}<small>%</small>`);
  function setGauge(k, pct, main, sub) {
    const g = document.querySelector(`[data-g="${k}"]`);
    if (!g) return;
    const lv = pct == null ? "" : level(pct);
    if (g._lv !== lv) {
      g._lv = lv;
      g.classList.remove("warn", "bad");
      g.querySelector(".ring").classList.remove("warn", "bad");
      if (lv) { g.classList.add(lv); g.querySelector(".ring").classList.add(lv); }
      g.querySelector(".lvl").textContent = t(LVL[lv]);
    }
    const v = Math.min(100, Math.max(0, pct || 0));
    g.querySelector(".fill").setAttribute("stroke-dasharray", `${((RING_C * v) / 100).toFixed(1)} ${RING_C.toFixed(1)}`);
    tween(g.querySelector(".value"), pct, pctHTML);
    setHTML(g.querySelector(".g-main"), main);
    setHTML(g.querySelector(".g-sub"), sub ? `<br>${sub}` : "");
  }
  const tileEl = (k) => document.querySelector(`[data-t="${k}"] .value`);

  // Built once per language / theme / server; after that only the values change (paintStats).
  function statsShape(o) {
    const ip = o.public_ip || {};
    return [state.lang, state.theme, state.instance, o.host.name, o.host.os, o.host.cores, o.host.cpu_model, ip.v4, ip.v6, ip.disabled, ip.checked].join("|");
  }
  function buildStats(o) {
    const ip = o.public_ip || {};
    const local = !state.instance || state.instance === "node-exporter:9100";
    const ipChip = (label, v, wait) => `<button type="button" class="chip copy${v ? "" : " off"}" ${v ? `data-copy="${esc(v)}" title="${esc(t("copy"))}"` : "disabled"}><b class="ipl">${label}</b>${num(esc(v || (wait ? "…" : "–")))}</button>`;
    const addr = state.instance ? state.instance.replace(/:\d+$/, "") : "";
    const chips = [
      local ? (ip.disabled ? "" : ipChip("IPv4", ip.v4, !ip.checked) + ipChip("IPv6", ip.v6, !ip.checked))
        : addr ? ipChip(t("address"), addr, false) : "",
      o.host.name ? `<span class="chip">${icon("server")}<b>${num(esc(o.host.name))}</b></span>` : "",
      o.host.os ? `<span class="chip">${num(esc(o.host.os))}</span>` : "",
      o.host.cores != null ? `<span class="chip">${icon("cpu")}<b>${num(nf(o.host.cores, 0))}</b> ${esc(t("cores"))}</span>` : "",
    ].join("");
    const hero = `<section class="card hero"><div class="hero-icon"></div>
      <div class="hero-text"><h2 aria-live="polite"></h2><p></p></div>
      <div class="hero-meta">${chips}</div></section>`;
    const gauges = [
      gauge({ k: "cpu", label: t("cpu"), ic: "cpu", spark: sparkBox("cpu", 0, "--c1") }),
      gauge({ k: "mem", label: t("memory"), ic: "memory", spark: sparkBox("mem", 0, "--c3") }),
      gauge({ k: "disk", label: t("disk"), ic: "disk", go: "disks" }),
    ].join("");
    const tiles = [
      tile({ k: "rx", label: t("net_down"), ic: "down", go: "network", spark: sparkBox("net", 0, "--c1") }),
      tile({ k: "tx", label: t("net_up"), ic: "up", go: "network", spark: sparkBox("net", 1, "--c2") }),
      tile({ k: "load", label: t("load"), ic: "activity", tight: true }),
      tile({ k: "targets", label: t("targets"), ic: "check", go: "targets" }),
      tile({ k: "checks", label: t("websites"), ic: "globe", go: "websites" }),
      tile({ k: "ssl", label: t("ssl"), ic: "lock", go: "websites" }),
      tile({ k: "alerts", label: t("alerts"), ic: "bell", go: "alerts" }),
    ].join("");
    $("stats").innerHTML = `${hero}<div class="gauges">${gauges}</div><div class="tiles">${tiles}</div>`;
  }

  state.statsShape = null;
  function paintStats() {
    const o = merged();
    if (!o || $("stats").hidden) return;
    const shape = statsShape(o);
    if (shape !== state.statsShape) { state.statsShape = shape; buildStats(o); }
    const memPct = o.mem.total ? (o.mem.used / o.mem.total) * 100 : null;
    const d = o.disk;
    const { sev, issues } = health(o, memPct);
    const hero = document.querySelector("#stats .hero");
    if (hero._sev !== sev) {
      hero._sev = sev;
      hero.classList.remove("warn", "bad");
      if (sev) hero.classList.add(["", "warn", "bad"][sev]);
      hero.querySelector(".hero-icon").innerHTML = icon(["shield", "alert", "octagon"][sev]);
    }
    setHTML(hero.querySelector("h2"), esc(t("h_" + ["ok", "warn", "bad"][sev])));
    setHTML(hero.querySelector("p"), esc(issues.length ? issues.join(" · ") : t("h_ok_sub")));

    // only the numbers are left-to-right: the words around them follow the page language
    const io = o.io && o.io[0] != null ? `${esc(t("io_r"))} ${num(esc(fmtRate(o.io[0])))} · ${esc(t("io_w"))} ${num(esc(fmtRate(o.io[1])))}` : "";
    setGauge("cpu", o.cpu, o.host.cores != null ? `${num(nf(o.host.cores, 0))} ${esc(t("cores"))}` : "", o.host.cpu_model ? num(esc(o.host.cpu_model)) : "");
    setGauge("mem", memPct, `${num(fmtBytes(o.mem.used))} ${esc(t("of"))} ${num(fmtBytes(o.mem.total))}`, o.swap && o.swap.total ? `${esc(t("swap"))} ${num(esc(`${fmtBytes(o.swap.used)} / ${fmtBytes(o.swap.total)}`))}` : "");
    setGauge("disk", d ? d.pct : null, d ? `${num(fmtBytes(d.used))} ${esc(t("of"))} ${num(fmtBytes(d.total))}` : "", d ? num(esc(d.mount)) + (io ? `<br>${io}` : "") : "");

    tween(tileEl("rx"), o.net.rx, (v) => num(fmtRate(v)));
    tween(tileEl("tx"), o.net.tx, (v) => num(fmtRate(v)));
    tween(tileEl("load"), o.load, (v) => num(v == null || v.some((x) => x == null) ? "–" : v.map((x) => nf(x, 2)).join(" / ")));
    setHTML(tileEl("targets"), num(`${o.targets.up} / ${o.targets.total}`));
    setHTML(tileEl("checks"), num(`${o.checks.up} / ${o.checks.total}`));
    setHTML(tileEl("ssl"), o.checks.min_ssl_days == null ? "–" : num(`${nf(o.checks.min_ssl_days, 0)} <small>${t("days")}</small>`));
    setHTML(tileEl("alerts"), o.alerts.firing ? num(o.alerts.firing) : `<span class="ok-mark">${icon("okmark")}</span>`);
    document.querySelector('[data-t="alerts"]').classList.toggle("alert-on", !!o.alerts.firing);
    refreshSparks();
    $("hostline").textContent = [o.host.name, o.host.os].filter(Boolean).join(" · ") || " ";
  }
  function renderStats() {   // full rebuild (language or theme changed, new data)
    state.statsShape = null;
    paintStats();
    renderNav();
  }

  // ---------------------------------------------------------------- tables
  function table(cols, rows, rowAttrs) {
    if (!rows.length) return `<div class="table-wrap"><div class="empty">${esc(t("empty"))}</div></div>`;
    const head = cols.map((c) => `<th>${c.raw ? c.h : esc(t(c.h))}</th>`).join("");
    const body = rows.map((r) => `<tr${rowAttrs ? " " + rowAttrs(r) : ""}>${cols.map((c) => `<td class="${c.cls || ""}${c.h === "actions" || c.raw ? " act" : ""}" data-label="${c.raw ? "" : esc(t(c.h))}">${c.cell(r)}</td>`).join("")}</tr>`).join("");
    return `<div class="table-wrap"><table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`;
  }
  const pill = (kind, text, dot = true) => `<span class="pill ${kind}${dot ? " dot" : ""}">${esc(text)}</span>`;
  const miniBar = (pct) => `<div class="mini-bar"><div class="bar ${level(pct)}"><i style="width:${Math.min(100, pct)}%"></i></div>${num(`${nf(pct, 0)}%`)}</div>`;
  const btnIcon = (ic, label, attrs, cls = "") => `<button type="button" class="btn small icon ${cls}" title="${esc(label)}" aria-label="${esc(label)}" ${attrs}>${icon(ic)}</button>`;
  const addButton = (id, label) => `<button type="button" class="btn small primary" id="${id}">${icon("plus")}<span>${esc(label)}</span></button>`;
  const statusPill = (up, known = true) => (!known ? pill("", t("s_wait")) : up ? pill("ok", t("s_up")) : pill("bad", t("s_down")));
  const val = (form, name) => form.elements[name].value;
  const field = (label, control, hint = "") => `<div class="field"><label>${esc(label)}</label>${control}${hint ? `<p class="hint">${esc(hint)}</p>` : ""}</div>`;

  const liveRate = (r, k) => { const s = liveNow(), d = s && s.dev[r.device]; return d && d[k] != null ? d[k] : k ? r.tx : r.rx; };
  function paintNetLive() {
    const s = liveNow();
    document.querySelectorAll("[data-live-only]").forEach((el) => { el.hidden = !s; });
    if (!s) return;
    document.querySelectorAll("[data-live-dev]").forEach((el) => {
      const d = s.dev[el.dataset.liveDev];
      if (d && d[+el.dataset.k] != null) tween(el, d[+el.dataset.k], (v) => num(esc(fmtRate(v))));
    });
  }

  // ---------------------------------------------------------------- views: each has build() and optional bind()
  const CONTAINER_STATE = { running: "ok", restarting: "warn", paused: "warn", created: "warn", exited: "bad", dead: "bad" };
  const stateLabel = (st) => { const k = `s_${st}`; const v = t(k); return v === k ? st : v; };

  const IMPL = {
    // ---- websites + TCP ports
    websites: {
      async build() {
        const checks = await api("/api/checks");
        let metrics = [];
        try { metrics = (await api("/api/websites")).rows; } catch (e) { /* metrics are optional here */ }
        const byTarget = new Map(metrics.map((m) => [m.target, m]));
        const managed = [...checks.http.map((x) => ({ ...x, kind: "http" })), ...checks.tcp.map((x) => ({ ...x, kind: "tcp" }))];
        const known = new Set(managed.map((m) => m.target));
        const extra = metrics.filter((m) => !known.has(m.target)).map((m) => ({ target: m.target, name: "", kind: m.job === "tcp" ? "tcp" : "http", fixed: true }));
        const rows = [...managed, ...extra].map((r) => ({ ...r, m: byTarget.get(r.target) }));
        const cols = [
          { h: "target", cls: "strong", cell: (r) => `${num(esc(r.target))}${r.mode && r.mode !== "default" ? `<span class="tag">${esc(t("mode_" + r.mode))}</span>` : ""}${r.auto_from ? `<span class="tag" title="${esc(t("auto_was", { from: r.auto_from }))}">${esc(t("auto_tag"))}</span>` : ""}${r.name ? `<div class="sub-line">${esc(r.name)}</div>` : ""}` },
          { h: "type", cell: (r) => pill("info", r.kind.toUpperCase(), false) },
          { h: "status", cell: (r) => statusPill(r.m && r.m.up, !!r.m) },
          { h: "response", cell: (r) => num(r.m ? fmtMs(r.m.duration) : "–") },
          { h: "http", cell: (r) => num(r.m && r.m.http ? r.m.http : "–") },
          { h: "ssl_h", cell: (r) => (!r.m || r.m.ssl_days == null ? "–" : pill(r.m.ssl_days < 7 ? "bad" : r.m.ssl_days < 14 ? "warn" : "ok", nf(r.m.ssl_days, 0), false)) },
          { h: "actions", cell: (r) => `<div class="row-actions">${btnIcon("search", t("probe"), `data-act="probe" data-kind="${esc(r.kind)}" data-target="${esc(r.target)}"`)}${r.fixed ? "" : btnIcon("trash", t("remove"), `data-act="del" data-kind="${r.kind}" data-target="${esc(r.target)}"`, "danger")}</div>` },
        ];
        const events = (checks.auto && checks.auto.events) || [];
        const evText = (e) => (e.action === "mode" ? t("auto_ev_mode", { from: e.from, mode: t("mode_" + e.mode) }) : e.action === "merge" ? t("auto_ev_merge", { from: e.from, to: e.to }) : t("auto_ev_replace", { from: e.from, to: e.to }));
        const log = events.length ? `<div class="subcard" style="margin-top:18px"><h3>${icon("check")}${esc(t("auto_log"))}</h3><ul class="steps">${events.slice(0, 5).map((e) => `<li><span class="muted">${esc(new Date(e.t * 1000).toLocaleString())}</span> · ${esc(evText(e))}</li>`).join("")}</ul></div>` : "";
        return { html: table(cols, rows) + `<p class="muted" style="margin-top:12px">${esc(t("w_hint"))}</p>` + log, tools: addButton("btn-add-site", t("add_site")) };
      },
      bind(root) {
        $("btn-add-site")?.addEventListener("click", addSiteDialog);
        root.addEventListener("click", async (e) => {
          const pb = e.target.closest('[data-act="probe"]');
          if (pb) return probeDialog(pb.dataset.kind, pb.dataset.target);
          const b = e.target.closest('[data-act="del"]');
          if (!b) return;
          if (!(await confirmBox({ message: t("w_confirm_remove", { n: b.dataset.target }), label: t("remove") }))) return;
          if (await act(b, () => post("/api/checks/remove", { kind: b.dataset.kind, target: b.dataset.target }), t("removed"))) renderView(false);
        });
      },
    },

    disks: {
      async build() {
        const { rows } = await api("/api/disks", withInstance());
        return table([
          { h: "mount", cls: "strong", cell: (r) => num(esc(r.mount)) },
          { h: "device", cls: "muted", cell: (r) => num(esc(r.device)) },
          { h: "fs", cell: (r) => esc(r.fstype) },
          { h: "usage", cell: (r) => miniBar(r.pct) },
          { h: "used_total", cell: (r) => num(`${fmtBytes(r.used)} / ${fmtBytes(r.total)}`) },
        ], rows);
      },
    },

    network: {
      async build() {
        const { rows, exporter } = await api("/api/network", withInstance());
        if (!rows.length) {
          const why = !exporter ? "nx_nodata" : !exporter.present ? "nx_nojob" : !exporter.up ? "nx_down" : "nx_nodata";
          const detail = exporter && exporter.error ? ` <code>${esc(exporter.error)}</code>` : "";
          return `<div class="notice bad">${icon("bell")}<span>${esc(t(why))}${detail}</span></div>` + table([], []);
        }
        try { state.traffic = await api("/api/traffic", withInstance({ tz: new Date().getTimezoneOffset() })); } catch (e) { state.traffic = null; }   // the totals are optional
        const ifaces = table([
          { h: "iface", cls: "strong", cell: (r) => num(esc(r.device)) },
          { h: "status", cell: (r) => (r.up ? pill("ok", t("s_up")) : pill("bad", t("s_down"))) },
          { h: "speed", cell: (r) => num(r.speed ? `${nf((r.speed * 8) / 1e6, 0)} Mbit/s` : "–") },
          { h: "rate_in", cell: (r) => `<span data-live-dev="${esc(r.device)}" data-k="0">${num(fmtRate(liveRate(r, 0)))}</span>` },
          { h: "rate_out", cell: (r) => `<span data-live-dev="${esc(r.device)}" data-k="1">${num(fmtRate(liveRate(r, 1)))}</span>` },
          { h: "total_in", cell: (r) => num(fmtBytes(r.rx_total)) },
          { h: "total_out", cell: (r) => num(fmtBytes(r.tx_total)) },
        ], rows);
        return `<section class="sec"><div class="sec-head"><h3>${icon("network")}${esc(t("net_ifaces"))}<span class="live-tag" data-live-only hidden><i></i>${esc(t("live_tag"))}</span></h3></div>${ifaces}</section>${state.traffic ? trafficSection(state.traffic) : ""}`;
      },
      bind() { paintBars(); paintNetLive(); },
    },

    targets: {
      async build() {
        const { rows } = await api("/api/targets");
        return table([
          { h: "job", cls: "strong", cell: (r) => esc(r.job) },
          { h: "instance", cell: (r) => num(esc(r.instance)) },
          { h: "status", cell: (r) => (r.up ? pill("ok", t("s_up")) : pill("bad", t("s_down"))) },
          { h: "scrape", cell: (r) => num(fmtMs(r.duration)) },
          { h: "error", cls: "wrap-cell", cell: (r) => (r.error ? `<span style="color:var(--s-bad)">${esc(r.error)}</span>` : "") },
        ], rows);
      },
    },

    alerts: {
      async build() {
        const { rows } = await api("/api/alerts");
        const sev = { critical: "bad", warning: "warn", info: "info" };
        const note = rows.length ? "" : `<div class="notice ok">${icon("okmark")}<span>${esc(t("no_alerts"))}</span></div>`;
        return note + (rows.length ? table([
          { h: "severity", cell: (r) => pill(sev[r.severity] || "", r.severity && T[state.lang]["sev_" + r.severity] ? t("sev_" + r.severity) : r.severity || "–", false) },
          { h: "alert", cls: "strong", cell: (r) => esc(r.name) },
          { h: "instance", cell: (r) => num(esc(r.instance || "–")) },
          { h: "summary", cls: "wrap-cell", cell: (r) => esc(r.summary) },
          { h: "state", cell: (r) => (r.state === "firing" ? pill("bad", t("s_firing")) : pill("warn", t("s_pending"))) },
          { h: "since", cell: (r) => num(ago(r.since)) },
        ], rows) : "");
      },
    },

    // ---- servers (node_exporter targets)
    servers: {
      async build() {
        const checks = await api("/api/checks");
        let targets = [];
        try { targets = (await api("/api/targets")).rows.filter((r) => r.job === "node"); } catch (e) { /* optional */ }
        const byInst = new Map(targets.map((r) => [r.instance, r]));
        const cols = [
          { h: "target", cls: "strong", cell: (r) => `${num(esc(r.target))}${r.locked ? `<span class="tag">${esc(t("srv_local"))}</span>` : ""}` },
          { h: "name", cell: (r) => esc(r.name || "–") },
          { h: "status", cell: (r) => { const m = byInst.get(r.target); return statusPill(m && m.up, !!m); } },
          { h: "actions", cell: (r) => (r.locked ? "–" : `<div class="row-actions">${btnIcon("trash", t("remove"), `data-act="del" data-target="${esc(r.target)}"`, "danger")}</div>`) },
        ];
        const cmd = "docker run -d --name node-exporter --restart unless-stopped \\\n  --net host --pid host -v /:/host:ro,rslave \\\n  prom/node-exporter:v1.8.2 --path.rootfs=/host";
        const fw = "ufw allow from <MONITORING-SERVER-IP> to any port 9100 proto tcp";
        const help = `<div class="subcard" style="margin-top:18px"><h3>${esc(t("srv_help_title"))}</h3>
          <p>${esc(t("srv_help_1"))}</p><div class="codebox">${esc(cmd)}</div><button type="button" class="btn small" data-copy="${esc(cmd)}">${icon("copy")}<span>${esc(t("copy"))}</span></button>
          <p>${esc(t("srv_help_2"))}</p><div class="codebox">${esc(fw)}</div><p>${esc(t("srv_help_3"))}</p></div>`;
        return { html: table(cols, checks.nodes) + help, tools: addButton("btn-add-server", t("add_server")) };
      },
      bind(root) {
        $("btn-add-server")?.addEventListener("click", addServerDialog);
        root.addEventListener("click", async (e) => {
          const c = e.target.closest("[data-copy]");
          if (c) return copyText(c.dataset.copy);
          const b = e.target.closest('[data-act="del"]');
          if (!b) return;
          if (!(await confirmBox({ message: t("srv_confirm_remove", { n: b.dataset.target }), label: t("remove") }))) return;
          if (await act(b, () => post("/api/checks/remove", { kind: "nodes", target: b.dataset.target }), t("removed"))) { state.instances = []; renderView(false); }
        });
      },
    },

    // ---- notifications (Telegram)
    notifications: {
      async build() {
        const s = (state.settings = await api("/api/settings"));
        const tg = s.telegram;
        const status = tg.configured ? pill("ok", t("tg_ok")) : pill("", t("tg_no"));
        const bot = tg.configured && tg.bot ? ` <span class="muted">${esc(t("tg_bot"))}: @${esc(tg.bot)}</span>` : "";
        const tokenHint = tg.configured ? t("tg_token_saved", { h: tg.token_hint }) : "";
        const html = `<div class="split">
          <section class="subcard"><h3>${icon("send")}${esc(t("tg_title"))} ${status}${bot}</h3>
            <ol class="steps"><li>${esc(t("tg_s1"))}</li><li>${esc(t("tg_s2"))}</li><li>${esc(t("tg_s3"))}</li></ol>
            <form id="tg-form" autocomplete="off">
              ${field(t("tg_token"), `<input name="token" type="password" dir="ltr" autocomplete="new-password" placeholder="123456789:AA…">`, tokenHint)}
              ${field(t("tg_chat"), `<input name="chat_id" dir="ltr" inputmode="numeric" value="${esc(tg.chat_id)}" placeholder="123456789">`)}
              <div id="tg-chats" class="chips" style="margin:-4px 0 14px"></div>
              <div class="actions-row">
                <button type="submit" class="btn primary">${esc(t("save"))}</button>
                <button type="button" class="btn" id="tg-find">${icon("search")}<span>${esc(t("tg_find"))}</span></button>
                <button type="button" class="btn" id="tg-test">${esc(t("tg_test"))}</button>
                ${tg.configured ? `<button type="button" class="btn danger" id="tg-remove">${esc(t("tg_remove"))}</button>` : ""}
              </div>
            </form></section>
          <section class="subcard"><h3>${icon("bell")}${esc(t("at_title"))}</h3><p>${esc(t("at_text"))}</p>
            <button type="button" class="btn" id="alert-test">${esc(t("at_btn"))}</button></section></div>`;
        return { html, tools: "" };
      },
      bind(root) {
        const form = root.querySelector("#tg-form");
        const creds = () => ({ token: val(form, "token").trim(), chat_id: val(form, "chat_id").trim() });
        form.addEventListener("submit", async (e) => {
          e.preventDefault();
          if (await act(form.querySelector('[type="submit"]'), () => post("/api/telegram/save", creds()), t("tg_saved"))) renderView(true);
        });
        root.querySelector("#tg-find").addEventListener("click", async (e) => {
          const box = root.querySelector("#tg-chats");
          const r = await act(e.currentTarget, () => post("/api/telegram/chats", { token: val(form, "token").trim() }));
          if (!r) return;
          box.innerHTML = r.chats.length
            ? `<span class="muted">${esc(t("tg_found"))}</span>` + r.chats.map((c) => `<button type="button" class="btn small" data-chat="${esc(c.id)}">${esc(c.title)} <code>${esc(c.id)}</code></button>`).join("")
            : `<span class="muted">${esc(t("tg_none"))}</span>`;
        });
        root.querySelector("#tg-chats").addEventListener("click", (e) => {
          const b = e.target.closest("[data-chat]");
          if (b) form.elements.chat_id.value = b.dataset.chat;
        });
        root.querySelector("#tg-test").addEventListener("click", (e) => act(e.currentTarget, () => post("/api/telegram/test", creds()), t("tg_test_ok")));
        root.querySelector("#tg-remove")?.addEventListener("click", async (e) => {
          if (!(await confirmBox({ message: t("tg_confirm_remove"), label: t("tg_remove") }))) return;
          if (await act(e.currentTarget, () => post("/api/telegram/remove"), t("tg_removed"))) renderView(true);
        });
        root.querySelector("#alert-test").addEventListener("click", (e) => act(e.currentTarget, () => post("/api/alerts/test"), t("at_ok")));
      },
    },

    // ---- alert rules
    rules: {
      async build() {
        const { rules } = await api("/api/rules");
        const sev = { critical: "bad", warning: "warn", info: "info" };
        const cols = [
          { h: "rl_enabled", cell: (r) => `<label class="switch"><input type="checkbox" data-f="enabled" ${r.enabled ? "checked" : ""} aria-label="${esc(r.name)}"><span></span></label>` },
          { h: "rl_rule", cls: "strong", cell: (r) => `${esc(T[state.lang]["rn_" + r.name] ? t("rn_" + r.name) : r.name)} <code class="rule-code" dir="ltr">${esc(r.name)}</code><div class="sub-line">${esc(t("rd_" + r.name))}</div>` },
          { h: "severity", cell: (r) => pill(sev[r.severity] || "", T[state.lang]["sev_" + r.severity] ? t("sev_" + r.severity) : r.severity, false) },
          { h: "rl_threshold", cell: (r) => (r.has_threshold ? `<span class="inline-field"><input type="number" data-f="value" step="any" min="${r.min}" max="${r.max}" value="${esc(r.value)}" aria-label="${esc(t("rl_threshold"))}"><small>${esc(r.unit)}</small></span>` : "–") },
          { h: "rl_for", cell: (r) => `<span class="inline-field"><input type="number" data-f="for" step="1" min="0" max="1440" value="${esc(r.for)}" aria-label="${esc(t("rl_for"))}"><small>${esc(t("minutes"))}</small></span>` },
          { h: "", raw: true, cell: () => `<button type="button" class="btn small primary" data-save disabled>${esc(t("save"))}</button>` },
        ];
        const html = table(cols, rules, (r) => `data-rule="${esc(r.name)}"`);
        return { html, tools: `<button type="button" class="btn small" id="btn-reset-rules">${esc(t("reset_defaults"))}</button>` };
      },
      bind(root) {
        root.addEventListener("input", (e) => { const row = e.target.closest("tr[data-rule]"); if (row) row.querySelector("[data-save]").disabled = false; });
        root.addEventListener("change", (e) => { const row = e.target.closest("tr[data-rule]"); if (row) row.querySelector("[data-save]").disabled = false; });
        root.addEventListener("click", async (e) => {
          const b = e.target.closest("[data-save]");
          if (!b) return;
          const row = b.closest("tr[data-rule]");
          const val = row.querySelector('[data-f="value"]');
          const body = { name: row.dataset.rule, enabled: row.querySelector('[data-f="enabled"]').checked, value: val ? val.value : null, for: row.querySelector('[data-f="for"]').value };
          if (await act(b, () => post("/api/rules/set", body), t("rl_saved"))) renderView(true);
        });
        $("btn-reset-rules")?.addEventListener("click", async (e) => {
          if (!(await confirmBox({ message: t("rl_reset_confirm"), label: t("reset_defaults"), danger: false }))) return;
          if (await act(e.currentTarget, () => post("/api/rules/reset"), t("rl_reset_ok"))) renderView(true);
        });
      },
    },

    // ---- settings
    settings: {
      async build() {
        const s = (state.settings = await api("/api/settings"));
        const d = s.docker;
        const dockerPill = d.enabled && d.available ? pill("ok", t("st_docker_on")) : d.enabled ? pill("warn", t("st_docker_unavail"), false) : pill("", t("st_docker_off"));
        const html = `<div class="split">
          <section class="subcard"><h3>${icon("lock")}${esc(t("st_pw_title"))}</h3>
            <form id="pw-form" autocomplete="off">
              ${field(t("st_user"), `<input name="user" dir="ltr" value="${esc(s.user)}" autocomplete="username" required>`)}
              ${field(t("st_current"), `<input name="current" type="password" dir="ltr" autocomplete="current-password" required>`)}
              ${field(t("st_new"), `<input name="new" type="password" dir="ltr" autocomplete="new-password" minlength="8" required>`)}
              ${field(t("st_repeat"), `<input name="repeat" type="password" dir="ltr" autocomplete="new-password" minlength="8" required>`)}
              <div class="actions-row"><button type="submit" class="btn primary">${esc(t("st_change"))}</button></div>
            </form></section>
          <div style="display:grid;gap:16px">
            <section class="subcard"><h3>${icon("box")}${esc(t("st_docker_title"))} ${dockerPill}</h3>
              <p>${esc(d.enabled ? t("st_docker_hint_on") : t("st_docker_hint_off"))}</p></section>
            <section class="subcard"><h3>${icon("check")}${esc(t("auto_title"))}</h3><p>${esc(t("auto_text"))}</p>
              <label style="display:flex;align-items:center;gap:12px;cursor:pointer"><span class="switch"><input type="checkbox" id="auto-toggle" ${s.auto_fix ? "checked" : ""}><span></span></span><b>${esc(t("auto_on"))}</b></label></section>
            <section class="subcard"><h3>${icon("server")}${esc(t("st_about"))}</h3>
              <p>${esc(t("st_version"))}: ${num(esc(s.version))}</p></section></div></div>`;
        return { html, tools: "" };
      },
      bind(root) {
        root.querySelector("#auto-toggle").addEventListener("change", async (e) => {
          const on = e.currentTarget.checked;
          if (await act(e.currentTarget, () => post("/api/settings/auto", { enabled: on }), t(on ? "auto_on_saved" : "auto_off_saved"))) state.settings = { ...state.settings, auto_fix: on };
          else e.currentTarget.checked = !on;
        });
        const form = root.querySelector("#pw-form");
        form.addEventListener("submit", async (e) => {
          e.preventDefault();
          if (val(form, "new") !== val(form, "repeat")) return toast(t("st_mismatch"), "bad");
          const ok = await act(form.querySelector('[type="submit"]'), () => post("/api/password", { user: val(form, "user").trim(), current: val(form, "current"), new: val(form, "new") }), t("st_pw_ok"));
          if (ok) { ["current", "new", "repeat"].forEach((n) => { form.elements[n].value = ""; }); }
        });
      },
    },
  };

  // ---------------------------------------------------------------- dialogs
  function probeDialog(kind, target) {
    openDialog({
      title: `${t("probe_title")}: ${target}`, wide: true, hideSubmit: true, cancel: t("close"),
      body: `<div id="probe-out"><div class="skeleton" style="height:70px"></div><p class="muted">${esc(t("probe_running"))}</p></div>`,
      onOpen: async (dlg) => {
        const out = dlg.querySelector("#probe-out");
        try {
          const r = await post("/api/checks/probe", { kind, target });
          const status = r.http_status ? ` · ${esc(t("probe_status"))}: ${num(r.http_status)}` : "";
          let diag = "";
          if (r.variants && r.variants.length) {
            const by = Object.fromEntries(r.variants.map((v) => [v.id, v]));
            const secureOk = r.variants.some((v) => v.ok && v.id in { legacy_tls: 1, no_verify: 1, legacy_no_verify: 1 });
            const note = secureOk ? t("diag_suggest")
              : by.plain_http && by.plain_http.ok ? t("diag_plain")
              : by.tcp && by.tcp.ok ? t("diag_blocked") : t("diag_closed");
            const rows = r.variants.map((v) => {
              const label = t(v.id === "tcp" ? "v_tcp" : `v_${v.id}`);
              const apply = v.ok && v.id in { legacy_tls: 1, no_verify: 1, legacy_no_verify: 1 }
                ? `<button type="button" class="btn small primary" data-mode="${v.id}">${esc(t("diag_apply"))}</button>` : "";
              return `<tr><td>${v.ok ? pill("ok", t("diag_works")) : pill("bad", t("diag_fails"))}</td><td class="strong" style="white-space:normal">${esc(label)}${apply ? `<div style="margin-top:8px">${apply}</div>` : ""}</td><td class="wrap-cell muted" style="min-width:300px">${v.ok ? (v.final_url ? `${esc(t("redirects_to"))} <code class="reason">${esc(v.final_url)}</code>` : "") : `<code class="reason">${esc(v.reason)}</code>`}</td></tr>`;
            }).join("");
            const httpFix = !secureOk && by.plain_http && by.plain_http.ok && target.startsWith("https://")
              ? `<p><button type="button" class="btn small primary" data-replace="http://${esc(target.slice(8))}">${esc(t("diag_use_http"))}</button></p>` : "";
            const autoBtn = r.variants.some((v) => v.ok && (v.id in { legacy_tls: 1, no_verify: 1, legacy_no_verify: 1 } || v.id === "plain_http"))
              ? `<p><button type="button" class="btn primary" data-autofix>${esc(t("auto_fix_btn"))}</button></p>` : "";
            diag = `<h4 style="margin:18px 0 8px">${esc(t("diag_title"))}</h4>${autoBtn}<p class="muted">${esc(note)}</p>${httpFix}<div class="table-wrap"><table><tbody>${rows}</tbody></table></div>`;
          }
          out.innerHTML = `<div class="notice ${r.ok ? "ok" : "bad"}">${icon(r.ok ? "okmark" : "bell")}<span><b>${esc(t(r.ok ? "probe_ok" : "probe_fail"))}</b>${status}</span></div>
            ${r.ok ? "" : `<p>${esc(t("probe_k_" + (r.kind || "other")))}</p>`}
            ${r.reason ? `<p><b>${esc(t("probe_reason"))}:</b> <code>${esc(r.reason)}</code></p>` : ""}
            ${diag}
            ${r.ok ? "" : `<p class="muted">${esc(t("probe_hint"))}</p>`}
            <details><summary>${esc(t("probe_log"))}</summary><pre class="logs" style="height:280px;margin-top:10px">${esc(r.log)}</pre></details>`;
          out.querySelectorAll("[data-autofix]").forEach((b) => b.addEventListener("click", async () => {
            const res = await act(b, () => post("/api/checks/autofix", { target }));
            if (!res) return;
            toast(res.event ? t("auto_done") : t("auto_none"), res.event ? "" : "warn");
            dlg.close(); renderView(false);
          }));
          out.querySelectorAll("[data-replace]").forEach((b) => b.addEventListener("click", async () => {
            if (await act(b, () => post("/api/checks/replace", { kind, target, new_target: b.dataset.replace }), t("diag_replaced"))) { dlg.close(); renderView(false); }
          }));
          out.querySelectorAll("[data-mode]").forEach((b) => b.addEventListener("click", async () => {
            if (await act(b, () => post("/api/checks/mode", { kind, target, mode: b.dataset.mode }), t("diag_applied"))) { dlg.close(); renderView(false); }
          }));
        } catch (e) { out.innerHTML = `<div class="notice bad">${icon("bell")}<span>${esc(e.message)}</span></div>`; }
      },
    });
  }

  function addSiteDialog() {
    openDialog({
      title: t("add_site"), submit: t("add"),
      body: `${field(t("type"), `<select name="kind"><option value="http">${esc(t("type_http"))}</option><option value="tcp">${esc(t("type_tcp"))}</option></select>`)}
        ${field(t("f_target"), `<input name="target" dir="ltr" required placeholder="https://example.com" autocomplete="off">`, t("hint_http"))}
        ${field(t("f_name_opt"), `<input name="name" maxlength="60" autocomplete="off">`)}`,
      onOpen: (dlg, form) => {
        const hint = dlg.querySelector(".hint");
        form.elements.kind.addEventListener("change", () => {
          const http = val(form, "kind") === "http";
          form.elements.target.placeholder = http ? "https://example.com" : "203.0.113.10:22";
          hint.textContent = t(http ? "hint_http" : "hint_tcp");
        });
        form.elements.target.focus();
      },
      onSubmit: async (form) => {
        let target = val(form, "target").trim();
        const kind = val(form, "kind");
        if (kind === "http" && target && !/^[a-z][a-z0-9+.-]*:\/\//i.test(target)) target = `https://${target}`;  // only when no scheme was typed
        await post("/api/checks/add", { kind, target, name: val(form, "name").trim() });
        toast(kind === "http" && state.settings && state.settings.auto_fix ? t("added_auto") : t("added"));
        renderView(false);
      },
    });
  }

  function addServerDialog() {
    openDialog({
      title: t("add_server"), submit: t("add"),
      body: `${field(t("f_srv_addr"), `<input name="target" dir="ltr" required placeholder="203.0.113.10:9100" autocomplete="off">`, t("f_srv_hint"))}
        ${field(t("f_name_opt"), `<input name="name" maxlength="60" autocomplete="off">`)}`,
      onOpen: (dlg, form) => form.elements.target.focus(),
      onSubmit: async (form) => {
        let target = val(form, "target").trim();
        if (target && !/:\d+$/.test(target)) target += ":9100";
        await post("/api/checks/add", { kind: "nodes", target, name: val(form, "name").trim() });
        toast(t("added"));
        state.instances = [];
        renderView(false);
      },
    });
  }

  // ---------------------------------------------------------------- charts
  // One categorical slot per series, in fixed order (blue, orange, aqua); text never wears a series colour.
  const CHARTS = [
    { m: "cpu", title: "c_cpu", fmt: (v) => `${nf(v)}%`, max: 100, colors: ["--c1"], now: true },
    { m: "mem", title: "c_mem", fmt: (v) => `${nf(v)}%`, max: 100, colors: ["--c3"], now: true },
    { m: "net", title: "c_net", fmt: fmtRate, colors: ["--c1", "--c2"], names: ["rx", "tx"] },
    { m: "load", title: "c_load", fmt: (v) => nf(v, 2), colors: ["--c1", "--c2", "--c3"] },
  ];
  const niceMax = (v) => {
    if (!(v > 0)) return 1;
    const p = 10 ** Math.floor(Math.log10(v));
    return [1, 2, 2.5, 5, 10].map((x) => x * p).find((x) => x >= v);
  };
  const seriesName = (cfg, s, i) => (cfg.names ? t(cfg.names[i]) : s.name);
  const hhmm = (d) => `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;

  function drawChart(box, cfg, series, uid, win) {
    // With a fixed time window only the points inside it count (older samples would be drawn left of the
    // axis, outside the card, and would also stretch the scale); the plot area is clipped as well.
    if (win) series = series.map((s) => ({ ...s, points: s.points.filter((p) => p[0] >= win[0] && p[0] <= win[1]) }));
    const all = series.flatMap((s) => s.points.filter((p) => p[1] != null));
    // A line needs at least two samples at different times; right after startup there is only one.
    if (new Set(all.map((p) => p[0])).size < 2) { box.innerHTML = `<div class="empty">${esc(t(win ? "live_waiting" : "no_data"))}</div>`; return; }
    const bw = Math.round(box.clientWidth) || 600, compact = bw < 420;
    const W = Math.max(240, bw), H = compact ? 170 : 190, L = compact ? 42 : 52, R = 10, TOP = 12, B = 24;
    const x0 = win ? win[0] : Math.min(...all.map((p) => p[0])), x1 = win ? win[1] : Math.max(...all.map((p) => p[0])) || x0 + 1;
    const ymax = cfg.max || niceMax(Math.max(...all.map((p) => p[1])) * 1.1);
    const X = (ts) => L + ((ts - x0) / Math.max(1, x1 - x0)) * (W - L - R);
    const Y = (v) => TOP + (1 - v / ymax) * (H - TOP - B);
    const colors = cfg.colors.map((c) => `var(${c})`);

    let grid = "";
    for (let i = 0; i <= 4; i++) {
      const v = (ymax * i) / 4, y = Y(v);
      grid += `<line x1="${L}" x2="${W - R}" y1="${y}" y2="${y}"/><text x="${L - 8}" y="${y + 4}" text-anchor="end">${esc(cfg.fmt(v).replace(/\.0+(?=\D|$)/, ""))}</text>`;
    }
    const span = x1 - x0, ticks = compact ? 3 : 4;
    for (let i = 0; i <= ticks; i++) {
      const ts = x0 + (span * i) / ticks, d = new Date(ts * 1000);
      const label = span > 2 * 86400 ? `${d.getMonth() + 1}/${d.getDate()}` : span < 900 ? `${hhmm(d)}:${String(d.getSeconds()).padStart(2, "0")}` : hhmm(d);
      grid += `<text x="${X(ts)}" y="${H - 6}" text-anchor="${i === 0 ? "start" : i === ticks ? "end" : "middle"}">${label}</text>`;
    }
    let paths = "", defs = "", dots = "";
    const lastOf = series.map((s) => [...s.points].reverse().find((p) => p[1] != null));
    series.forEach((s, i) => {
      let d = "", pen = false, first = null, last = null;
      s.points.forEach(([ts, v]) => {
        if (v == null) { pen = false; return; }
        d += `${pen ? "L" : "M"}${X(ts).toFixed(1)},${Y(v).toFixed(1)}`;
        if (first == null) first = ts;
        last = ts;
        pen = true;
      });
      if (!d) return;
      if (series.length <= 2) {   // area wash ~10%; with three lines it would only muddy the overlaps
        defs += `<linearGradient id="g${uid}${i}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${colors[i]}" stop-opacity=".2"/><stop offset="1" stop-color="${colors[i]}" stop-opacity=".02"/></linearGradient>`;
        paths += `<path d="${d}L${X(last).toFixed(1)},${Y(0)}L${X(first).toFixed(1)},${Y(0)}Z" fill="url(#g${uid}${i})" stroke="none"/>`;
      }
      paths += `<path d="${d}" fill="none" stroke="${colors[i]}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>`;
      const lp = lastOf[i];
      dots += `<circle r="4.5" fill="${colors[i]}" cx="${X(lp[0]).toFixed(1)}" cy="${Y(lp[1]).toFixed(1)}"/>`;
    });
    defs += `<clipPath id="c${uid}"><rect x="${L}" y="0" width="${W - L - R}" height="${H - B + 6}"/></clipPath>`;
    box.innerHTML = `<svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-label="${esc(t(cfg.title))}"><defs>${defs}</defs><g class="grid">${grid}</g><g clip-path="url(#c${uid})">${paths}</g><line class="cross" y1="${TOP}" y2="${H - B}" opacity="0"/><g class="dots">${dots}</g><rect class="hit" x="${L}" y="0" width="${W - L - R}" height="${H}" fill="transparent"/></svg><div class="tip" hidden></div>`;

    const svg = box.querySelector("svg"), tip = box.querySelector(".tip"), cross = box.querySelector(".cross");
    const dotEls = [...box.querySelectorAll(".dots circle")];
    const ref = series.reduce((a, b) => (b.points.length > a.points.length ? b : a), series[0]).points;
    const rest = () => {
      box._hover = null;
      tip.hidden = true; cross.setAttribute("opacity", "0");
      dotEls.forEach((c, i) => { const lp = lastOf[i]; c.setAttribute("cx", X(lp[0]).toFixed(1)); c.setAttribute("cy", Y(lp[1]).toFixed(1)); });
    };
    const show = (e) => {
      box._hover = { clientX: e.clientX };   // the live range redraws every second: keep the tooltip where it is
      const rect = svg.getBoundingClientRect();
      const px = ((e.clientX - rect.left) / rect.width) * W;
      const ts = x0 + ((px - L) / (W - L - R)) * (x1 - x0);
      let best = 0;
      ref.forEach((p, i) => { if (Math.abs(p[0] - ts) < Math.abs(ref[best][0] - ts)) best = i; });
      const at = ref[best][0], cx = X(at);
      cross.setAttribute("x1", cx); cross.setAttribute("x2", cx); cross.setAttribute("opacity", "1");
      const rows = series.map((s, i) => {
        const p = s.points.find((q) => q[0] === at);
        if (p && p[1] != null) { dotEls[i].setAttribute("cx", cx.toFixed(1)); dotEls[i].setAttribute("cy", Y(p[1]).toFixed(1)); }
        const name = series.length > 1 ? `<span>${esc(seriesName(cfg, s, i))}</span>` : "";
        return `<div class="r"><i style="background:${colors[i]}"></i><b>${esc(p && p[1] != null ? cfg.fmt(p[1]) : "–")}</b>${name}</div>`;
      }).join("");
      const dt = new Date(at * 1000);
      tip.innerHTML = `<div class="t">${esc(span > 2 * 86400 ? dt.toLocaleString() : dt.toLocaleTimeString([], { hour12: false }))}</div>${rows}`;
      tip.hidden = false;
      const cxPx = (cx / W) * rect.width, w = tip.offsetWidth;
      tip.style.left = `${Math.max(0, Math.min(rect.width - w, cxPx > rect.width / 2 ? cxPx - w - 14 : cxPx + 14))}px`;
      tip.style.top = "4px";
    };
    svg.addEventListener("pointermove", show);
    svg.addEventListener("pointerdown", show);
    svg.addEventListener("pointerleave", rest);
    svg.addEventListener("pointercancel", rest);
    if (box._hover) show(box._hover);
  }

  // Every chart has a table twin: the same numbers, readable without colour or hover.
  function chartTable(cfg, series) {
    const ref = series.reduce((a, b) => (b.points.length > a.points.length ? b : a), series[0]).points.filter((p) => p[1] != null);
    if (!ref.length) return `<div class="empty">${esc(t("no_data"))}</div>`;
    const step = Math.max(1, Math.floor(ref.length / 24));
    const rows = ref.filter((_, i) => (ref.length - 1 - i) % step === 0).reverse();
    const long = ref[ref.length - 1][0] - ref[0][0] > 2 * 86400;
    const head = `<th>${esc(t("time"))}</th>${series.map((s, i) => `<th>${esc(seriesName(cfg, s, i) || t(cfg.title))}</th>`).join("")}`;
    const body = rows.map(([ts]) => {
      const d = new Date(ts * 1000);
      return `<tr><td>${num(esc(long ? `${d.getMonth() + 1}/${d.getDate()} ${hhmm(d)}` : hhmm(d)))}</td>${series.map((s) => { const p = s.points.find((q) => q[0] === ts); return `<td>${num(esc(p && p[1] != null ? cfg.fmt(p[1]) : "–"))}</td>`; }).join("")}</tr>`;
    }).join("");
    return `<div class="chart-table table-wrap"><table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`;
  }
  state.charts = [];
  state.tv = {};

  state.chartWin = null;   // [from, to] while the charts show the live range
  function paintChart(root, i) {
    const c = CHARTS[i], got = state.charts[i];
    const box = root.querySelector(`#plot-${i}`);
    if (!box || !got) return;
    if (state.tv[i]) box.innerHTML = chartTable(c, got);
    else drawChart(box, c, got, i, state.chartWin);
    if (c.now) {
      const last = [...got[0].points].reverse().find((p) => p[1] != null);
      tween(root.querySelector(`#now-${i}`), last ? last[1] : null, (v) => (v == null ? "" : num(esc(c.fmt(v)))));
    }
  }

  function liveSeries(m) {
    const S = state.live.samples, pts = (f) => S.map((s) => [s.t, f(s)]);
    if (m === "cpu") return [{ name: "CPU", points: pts((s) => s.cpu) }];
    if (m === "mem") return [{ name: "Memory", points: pts(memPctOf) }];
    if (m === "net") return [{ name: "rx", points: pts((s) => s.rx) }, { name: "tx", points: pts((s) => s.tx) }];
    return [1, 5, 15].map((p, k) => ({ name: `${p}m`, points: pts((s) => (s.load ? s.load[k] : null)) }));
  }
  let tablesAt = 0;
  function paintLiveCharts() {
    const root = $("panel"), S = state.live.samples;
    if (root.dataset.view !== "overview" || !liveNow() || S.length < 2 || !root.querySelector("#plot-0")) return;
    const note = root.querySelector("#live-note");
    if (note) note.hidden = true;
    const end = S[S.length - 1].t;
    state.chartWin = [end - (LIVE_KEEP - 1), end];
    const tables = Date.now() - tablesAt > 10000;   // a table that rewrites itself every second cannot be read
    if (tables) tablesAt = Date.now();
    CHARTS.forEach((c, i) => {
      state.charts[i] = liveSeries(c.m);
      if (!state.tv[i] || tables) paintChart(root, i);
    });
  }

  async function buildOverview(root, id, rebuild) {
    const live = state.range === "live";
    if (rebuild) {
      state.charts = [];
      tablesAt = 0;
      const tag = live ? `<span class="live-tag"><i></i>${esc(t("live_tag"))}</span>` : "";
      root.querySelector("#body").innerHTML = `<div class="notice warn" id="live-note" hidden></div><div class="charts">${CHARTS.map((c, i) => {
        const names = c.names ? c.names.map((n) => t(n)) : c.colors.length > 1 ? ["1m", "5m", "15m"] : [];
        const legend = names.length > 1 ? `<div class="legend">${names.map((n, k) => `<span><i style="background:var(${c.colors[k]})"></i>${esc(n)}</span>`).join("")}</div>` : "";
        const tv = !!state.tv[i];
        return `<div class="chart"><header><h3>${esc(t(c.title))}${tag}</h3><span class="now" id="now-${i}"></span><button type="button" class="btn small icon ghost view-toggle" data-tv="${i}" aria-pressed="${tv}" title="${esc(t("tbl_view"))}" aria-label="${esc(t("tbl_view"))}">${icon("table")}</button></header>${legend}<div class="plot" id="plot-${i}"><div class="skeleton"></div></div></div>`;
      }).join("")}</div>`;
    }
    const L = state.live;
    // Only fresh samples count: after the source failed, old ones would freeze the charts on stale data.
    if (live && window.EventSource && (liveNow() || (L.status === "wait" && Date.now() - L.startedAt < 8000))) {
      paintLiveCharts();
      refreshSparks();
      return;
    }
    // Live data is not coming (exporter unreachable, old browser): show the last hour from Prometheus.
    state.chartWin = null;
    const note = root.querySelector("#live-note");
    if (note) { note.hidden = !live; note.textContent = live ? t("live_off_note", { e: L.error || t("live_wait") }) : ""; }
    await Promise.all(CHARTS.map(async (c, i) => {
      try {
        const { series } = await api("/api/history", withInstance({ metric: c.m, range: live ? "1h" : state.range }));
        if (id !== state.renderId || state.chartWin) return;   // live data arrived meanwhile
        state.charts[i] = series;
        state.hist[c.m] = series;
        paintChart(root, i);
      } catch (e) {
        if (id === state.renderId && !state.charts[i]) root.querySelector(`#plot-${i}`).innerHTML = `<div class="empty">${esc(e.message)}</div>`;
      }
    }));
    if (id === state.renderId) refreshSparks();
  }

  // ---------------------------------------------------------------- traffic usage (network page)
  state.traffic = null;
  state.trTable = false;
  const dayLabel = (d, k) => {
    if (k === 0) return t("tr_today");
    if (k === 1) return t("tr_yesterday");
    const x = new Date(d.start * 1000);
    return `${x.getMonth() + 1}/${x.getDate()}`;
  };
  function usageCard(label, d, note = "") {
    const rx = d.rx || 0, tx = d.tx || 0, sum = rx + tx, share = sum ? (rx / sum) * 100 : 0;
    const known = d.rx != null || d.tx != null;
    return `<div class="usage"><div class="u-label">${esc(label)}</div>
      <div class="u-total">${known ? num(esc(fmtBytes(sum))) : "–"}</div>
      <div class="u-split" aria-hidden="true"><i class="rx" style="width:${share.toFixed(1)}%"></i><i class="tx" style="width:${sum ? (100 - share).toFixed(1) : 0}%"></i></div>
      <div class="u-rows"><div><span class="k rx"></span>${icon("down")}<span>${esc(t("tr_down"))}</span><b>${num(esc(known ? fmtBytes(rx) : "–"))}</b></div>
      <div><span class="k tx"></span>${icon("up")}<span>${esc(t("tr_up"))}</span><b>${num(esc(known ? fmtBytes(tx) : "–"))}</b></div></div>
      ${note ? `<div class="u-note">${esc(note)}</div>` : ""}</div>`;
  }
  function trafficSection(tr) {
    const hist = tr.history, partial = (secs) => (hist != null && hist < secs * 0.95 ? t("tr_partial", { d: fmtDur(hist) }) : "");
    const cards = [
      usageCard(t("tr_today"), tr.days[0], partial(Math.max(60, tr.days[0].end - tr.days[0].start))),
      usageCard(t("tr_7d"), tr.week, partial(7 * 86400)),
      usageCard(t("tr_30d"), tr.month, partial(30 * 86400)),
      usageCard(t("tr_boot"), tr.boot),
    ].join("");
    const peak = (label, v) => `<span class="chip">${esc(label)} <b>${num(esc(fmtRate(v)))}</b></span>`;
    return `<section class="sec"><div class="sec-head"><h3>${icon("activity")}${esc(t("tr_title"))}</h3><p class="muted">${esc(t("tr_sub"))}</p></div>
      <div class="usage-grid">${cards}</div>
      <div class="chart tr-chart"><header><h3>${esc(t("tr_daily"))}</h3><button type="button" class="btn small icon ghost view-toggle" data-trtable aria-pressed="${state.trTable}" title="${esc(t("tbl_view"))}" aria-label="${esc(t("tbl_view"))}">${icon("table")}</button></header>
        <div class="legend"><span><i style="background:var(--c1)"></i>${esc(t("tr_down"))}</span><span><i style="background:var(--c2)"></i>${esc(t("tr_up"))}</span>
          ${tr.peak.rx != null ? peak(t("tr_peak_in"), tr.peak.rx) : ""}${tr.peak.tx != null ? peak(t("tr_peak_out"), tr.peak.tx) : ""}</div>
        <div class="plot" id="tr-plot"></div></div></section>`;
  }

  function barsTable(days) {
    const rows = days.map((d, k) => `<tr><td>${esc(dayLabel(d, k))}</td><td>${num(esc(fmtBytes(d.rx)))}</td><td>${num(esc(fmtBytes(d.tx)))}</td><td>${num(esc(fmtBytes((d.rx || 0) + (d.tx || 0))))}</td></tr>`).join("");
    return `<div class="chart-table table-wrap"><table><thead><tr><th>${esc(t("tr_day"))}</th><th>${esc(t("tr_down"))}</th><th>${esc(t("tr_up"))}</th><th>${esc(t("tr_total"))}</th></tr></thead><tbody>${rows}</tbody></table></div>`;
  }

  function paintBars() {
    const box = $("tr-plot"), tr = state.traffic;
    if (!box || !tr) return;
    if (state.trTable) { box.innerHTML = barsTable(tr.days); return; }
    const days = tr.days.map((d, k) => ({ ...d, label: dayLabel(d, k) })).reverse();   // oldest first
    const vals = days.flatMap((d) => [d.rx || 0, d.tx || 0]);
    if (!Math.max(...vals)) { box.innerHTML = `<div class="empty">${esc(t("no_data"))}</div>`; return; }
    const bw = Math.round(box.clientWidth) || 600, compact = bw < 420;
    const W = Math.max(260, bw), H = compact ? 190 : 220, L = compact ? 52 : 62, R = 8, TOP = 12, B = 26;
    const unit = 1024 ** Math.max(0, Math.floor(Math.log(Math.max(...vals)) / Math.log(1024))), ymax = niceMax((Math.max(...vals) * 1.08) / unit) * unit, plotW = W - L - R, gw = plotW / days.length;
    const Y = (v) => TOP + (1 - v / ymax) * (H - TOP - B);
    const barW = Math.max(6, Math.min(30, gw * 0.3));
    let grid = "", bars = "", hits = "";
    for (let i = 0; i <= 4; i++) {
      const v = (ymax * i) / 4, y = Y(v);
      grid += `<line x1="${L}" x2="${W - R}" y1="${y}" y2="${y}"/><text x="${L - 8}" y="${y + 4}" text-anchor="end">${esc(fmtBytes(v))}</text>`;
    }
    const topRound = (x, y, w, h, r) => {   // rounded data end, flat on the baseline
      r = Math.min(r, w / 2, h);
      return `M${x},${y + h}V${y + r}Q${x},${y} ${x + r},${y}H${x + w - r}Q${x + w},${y} ${x + w},${y + r}V${y + h}Z`;
    };
    days.forEach((d, i) => {
      const cx = L + gw * i + gw / 2;
      grid += `<text x="${cx}" y="${H - 7}" text-anchor="middle">${esc(d.label)}</text>`;
      [["rx", "--c1", -1], ["tx", "--c2", 1]].forEach(([k, col, side]) => {
        const v = d[k] || 0;
        if (v <= 0) return;
        const h = Math.max(2, (H - TOP - B) * (v / ymax)), x = side < 0 ? cx - barW - 1 : cx + 1;
        bars += `<path d="${topRound(x, Y(0) - h, barW, h, 4)}" fill="var(${col})"/>`;
      });
      hits += `<rect class="hit" data-i="${i}" x="${L + gw * i}" y="0" width="${gw}" height="${H}" fill="transparent"/>`;
    });
    box.innerHTML = `<svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-label="${esc(t("tr_daily"))}"><g class="grid">${grid}</g><rect class="hl" y="${TOP}" height="${H - TOP - B}" width="${gw}" opacity="0"/>${bars}${hits}</svg><div class="tip" hidden></div>`;
    const svg = box.querySelector("svg"), tip = box.querySelector(".tip"), hl = box.querySelector(".hl");
    const show = (e) => {
      const rect = svg.getBoundingClientRect();
      const px = ((e.clientX - rect.left) / rect.width) * W;
      const i = Math.max(0, Math.min(days.length - 1, Math.floor((px - L) / gw)));
      if (px < L) return;
      const d = days[i], cx = L + gw * i;
      hl.setAttribute("x", cx); hl.setAttribute("opacity", "1");
      const when = new Date(d.start * 1000);
      tip.innerHTML = `<div class="t">${esc(`${d.label} · ${when.getMonth() + 1}/${when.getDate()}`)}</div>
        <div class="r"><i style="background:var(--c1)"></i><b>${num(esc(fmtBytes(d.rx)))}</b><span>${esc(t("tr_down"))}</span></div>
        <div class="r"><i style="background:var(--c2)"></i><b>${num(esc(fmtBytes(d.tx)))}</b><span>${esc(t("tr_up"))}</span></div>
        <div class="r"><i></i><b>${num(esc(fmtBytes((d.rx || 0) + (d.tx || 0))))}</b><span>${esc(t("tr_total"))}</span></div>`;
      tip.hidden = false;
      const mid = ((cx + gw / 2) / W) * rect.width, w = tip.offsetWidth;
      tip.style.left = `${Math.max(0, Math.min(rect.width - w, mid > rect.width / 2 ? mid - w - gw * 0.35 : mid + gw * 0.35))}px`;
      tip.style.top = "4px";
    };
    const rest = () => { tip.hidden = true; hl.setAttribute("opacity", "0"); };
    svg.addEventListener("pointermove", show);
    svg.addEventListener("pointerdown", show);
    svg.addEventListener("pointerleave", rest);
    svg.addEventListener("pointercancel", rest);
  }

  // ---------------------------------------------------------------- self-diagnosis ("why can't the panel load data?")
  function healthDialog() {
    const dlg = openDialog({ title: t("dg_title"), wide: true, hideSubmit: true, cancel: t("close"), body: `<div id="diag"><div class="skeleton"></div></div>` });
    const box = dlg.querySelector("#diag");
    const render = (d) => {
      const hints = d.hints.map((h) => `<div class="notice ${h.kind === "dns_external" || h.kind === "disk" ? "warn" : "bad"}">${icon("bell")}<span>${esc(t("hint_" + h.kind, { service: h.service, detail: h.detail }))}</span></div>`).join("");
      const allOk = d.services.every((x) => x.ok);
      const svc = table([
        { h: "service", cls: "strong", cell: (r) => esc(r.service) },
        { h: "status", cell: (r) => (r.ok ? pill("ok", t("diag_ok")) : pill("bad", t(r.stage === "dns" ? "diag_dns" : "diag_http"))) },
        { h: "diag_detail", cls: "wrap-cell", cell: (r) => (r.error ? `<code class="reason">${esc(r.error)}</code>` : r.ms != null ? num(`${r.ms} ms`) : "") },
      ], d.services);
      const ctn = d.containers ? table([
        { h: "service", cls: "strong", cell: (r) => esc(r.service) },
        { h: "status", cell: (r) => pill(CONTAINER_STATE[r.state] || "", stateLabel(r.state)) },
        { h: "diag_exit", cell: (r) => num(r.state === "running" ? "–" : String(r.exit_code ?? "–")) + (r.oom ? ` <span class="tag">OOM</span>` : "") },
        { h: "diag_restarts", cell: (r) => num(String(r.restarts)) },
        { h: "actions", cell: (r) => (r.state === "running" ? "–" : `<div class="row-actions">${btnIcon("refresh", t("a_restart"), `data-diag-restart="${esc(r.id)}"`)}</div>`) },
      ], d.containers) : `<div class="notice">${icon("bell")}<span>${esc(t("c_docker_off"))}</span></div>`;
      const logs = Object.entries(d.logs).map(([name, text]) => `<h4>${esc(t("diag_logs", { s: name }))}</h4><pre class="logs short">${esc(text || "–")}</pre>`).join("");
      const extra = [d.disk ? `<span class="chip">${icon("disk")}${esc(t("disk"))} <b>${num(`${nf(d.disk.pct, 0)}%`)}</b></span>` : "", `<span class="chip">${icon("globe")}DNS <b>${esc(d.dns_external.ok ? t("diag_ok") : t("diag_fail"))}</b></span>`].join("");
      box.innerHTML = `${allOk ? `<div class="notice ok">${icon("okmark")}<span>${esc(t("diag_all_ok"))}</span></div>` : ""}${hints}
        <div class="diag-chips">${extra}</div><h4>${esc(t("diag_services"))}</h4>${svc}<h4>${esc(t("diag_containers"))}</h4>${ctn}${logs}`;
    };
    const load = async () => {
      try { render(await api("/api/health")); } catch (e) { if (e.message !== "unauthorized") box.innerHTML = `<div class="notice bad">${esc(e.message)}</div>`; }
    };
    box.addEventListener("click", async (e) => {
      const b = e.target.closest("[data-diag-restart]");
      if (!b) return;
      if (await act(b, () => post("/api/docker/action", { id: b.dataset.diagRestart, action: "restart" }), t("c_done"))) { box.innerHTML = `<div class="skeleton"></div>`; setTimeout(load, 4000); }
    });
    load();
  }

  // ---------------------------------------------------------------- view rendering
  function overviewTools() {
    const label = (i) => (state.names[i] ? `${state.names[i]} (${i})` : i);
    const inst = state.instances.length > 1
      ? `<label class="muted" for="sel-inst">${esc(t("server"))}</label><select id="sel-inst">${state.instances.map((i) => `<option ${i === state.instance ? "selected" : ""} value="${esc(i)}">${esc(label(i))}</option>`).join("")}</select>` : "";
    const range = `<label class="muted" for="sel-range">${esc(t("range"))}</label><select id="sel-range">${["live", "1h", "6h", "24h", "7d"].map((r) => `<option ${r === state.range ? "selected" : ""} value="${r}">${esc(t("r" + r))}</option>`).join("")}</select>`;
    return inst + range;
  }

  async function renderView(first) {
    const id = ++state.renderId;
    const v = VIEWS.find((x) => x.id === state.view) || VIEWS[0];
    const root = $("panel");
    $("stats").hidden = v.id !== "overview";
    if (v.id === "overview") paintStats();
    const hadShell = root.dataset.view === v.id && root.dataset.lang === state.lang;
    if (v.static && hadShell && !first) return;   // forms must not be wiped by the 10-second refresh
    if (!hadShell || first) {
      root.dataset.view = v.id;
      root.dataset.lang = state.lang;
      root.innerHTML = `<div class="panel-head"><h2>${icon(v.icon)}${esc(t(v.label))}</h2><div class="tools" id="tools">${v.id === "overview" ? overviewTools() : ""}</div></div><p class="desc">${esc(t(v.desc))}</p><hr><div id="body"><div class="skeleton"></div></div>`;
      const si = $("sel-inst"), sr = $("sel-range");
      if (si) si.onchange = () => { state.instance = si.value; store.set("instance", si.value); startLive(); tick(true); };
      if (sr) sr.onchange = () => { state.range = sr.value; store.set("range", sr.value); renderView(true); };
    }
    try {
      if (v.id === "overview") { await buildOverview(root, id, !hadShell || first); return; }
      const impl = IMPL[v.id];
      const res = await impl.build();
      if (id !== state.renderId) return;
      const html = typeof res === "string" ? res : res.html;
      const body = root.querySelector("#body");
      const fresh = body.cloneNode(false);              // drop handlers bound to the previous render
      fresh.innerHTML = html;
      body.replaceWith(fresh);
      if (typeof res !== "string") $("tools").innerHTML = res.tools || "";
      if (impl.bind) impl.bind(fresh);
    } catch (e) {
      if (id === state.renderId && e.message !== "unauthorized") root.querySelector("#body").innerHTML = `<div class="notice bad">${esc(t("err_api"))}: ${esc(e.message)}</div>`;
    }
  }

  async function loadStats() {
    try {
      const inst = await api("/api/instances");
      state.instances = inst.instances;
      state.names = inst.names || {};
      if (!state.instances.includes(state.instance)) state.instance = state.instances[0] || "";
      state.overview = await api("/api/overview", withInstance());
      $("banner").innerHTML = "";
      paintStats();
      renderNav();
    } catch (e) {
      if (e.message !== "unauthorized") $("banner").innerHTML = `<div class="notice bad">${icon("bell")}<span>${esc(t("err_api"))}: ${esc(e.message)}</span><button type="button" class="btn small" data-diag>${icon("search")}<span>${esc(t("diag_btn"))}</span></button></div>`;
    }
    try { state.settings = await api("/api/settings"); renderNav(); } catch (e) { /* the badge is optional */ }
    state.lastUpdate = new Date();
    paintFoot();
  }

  let ticking = false;
  async function tick(full) {
    if (ticking) return;
    ticking = true;
    try {
      await loadStats();
      startLive();   // no-op while already streaming the selected server
      await renderView(full === true);
    } finally { ticking = false; }
  }

  function route() {
    const id = location.hash.slice(1);
    state.view = VIEWS.some((v) => v.id === id) ? id : "overview";
    renderNav();
    window.scrollTo(0, 0);
    startLive();
    renderView(true);
  }

  // ---------------------------------------------------------------- boot
  $("theme").onclick = () => {
    // No transitions while the colours swap, so the two themes never blend for a moment.
    document.documentElement.classList.add("no-anim");
    state.theme = state.theme === "dark" ? "light" : "dark";
    store.set("theme", state.theme);
    applyLocale(); renderStats(); renderView(true);
    const done = () => document.documentElement.classList.remove("no-anim");
    requestAnimationFrame(() => requestAnimationFrame(done));
    setTimeout(done, 120);   // frames can be paused (hidden window): never leave transitions switched off
  };
  $("lang").onclick = () => { state.lang = state.lang === "en" ? "fa" : "en"; store.set("lang", state.lang); applyLocale(); renderStats(); renderView(true); };
  $("refresh").onclick = () => tick(true);
  $("logout").onclick = async () => { try { await fetch("/logout", { method: "POST" }); } catch (e) { /* ignore */ } location.replace("/login"); };
  window.addEventListener("hashchange", route);
  document.addEventListener("click", (e) => {
    const go = e.target.closest("[data-go]");
    if (go) { location.hash = go.dataset.go; return; }
    if (e.target.closest("[data-more]")) { moreSheet(); return; }
    if (e.target.closest("[data-trtable]")) {
      state.trTable = !state.trTable;
      e.target.closest("[data-trtable]").setAttribute("aria-pressed", String(state.trTable));
      paintBars();
      return;
    }
    if (e.target.closest("[data-diag]")) { healthDialog(); return; }
    const cp = e.target.closest("[data-copy]");
    if (cp) { copyText(cp.dataset.copy); return; }
    const tv = e.target.closest("[data-tv]");
    if (tv) {
      const i = +tv.dataset.tv;
      state.tv[i] = !state.tv[i];
      tv.setAttribute("aria-pressed", String(!!state.tv[i]));
      paintChart($("panel"), i);
    }
  });
  document.addEventListener("keydown", (e) => {
    if ((e.key === "Enter" || e.key === " ") && e.target.matches && e.target.matches('[data-go][role="link"]')) { e.preventDefault(); location.hash = e.target.dataset.go; }
  });
  $("live-every").addEventListener("change", (e) => {   // a new pace: reconnect the stream at once
    state.liveEvery = +e.target.value;
    store.set("live_every", String(state.liveEvery));
    stopLive();
    startLive();
    window.dispatchEvent(new CustomEvent("live-every", { detail: state.liveEvery }));
  });
  document.addEventListener("visibilitychange", () => {   // no stream (and no server work) for a hidden tab
    if (document.hidden) { stopLive(); paintFoot(); } else { startLive(); tick(false); }
  });
  let resizeTimer;
  window.addEventListener("resize", () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(() => { if (state.view === "overview" || state.view === "network") renderView(false); }, 300); });

  // ---------------------------------------------------------------- extension point (defender.js and future pages)
  window.Panel = {
    t, esc, nf, num, fmtBytes, fmtRate, fmtDur, ago, level, icon, api, post, act, toast, openDialog, confirmBox,
    table, pill, field, btnIcon, addButton, drawChart, sparkline, tween, setHTML, renderView, state,
    registerView(view, impl, after) {
      const i = VIEWS.findIndex((v) => v.id === after);
      VIEWS.splice(i < 0 ? VIEWS.length : i + 1, 0, view);
      IMPL[view.id] = impl;
    },
    addStrings(en, fa) { Object.assign(T.en, en); Object.assign(T.fa, fa); },
    addIcons(map) { Object.assign(P, map); },
    setTabs(ids) { TAB_IDS.splice(0, TAB_IDS.length, ...ids); },
  };

  // Boot once every deferred script (the extra pages) has registered itself.
  document.addEventListener("DOMContentLoaded", () => {
    applyLocale();
    state.view = VIEWS.some((v) => v.id === location.hash.slice(1)) ? location.hash.slice(1) : "overview";
    renderNav();
    tick(true);
    setInterval(() => { if (!document.hidden) tick(false); }, 10000);
  });
})();
__MONITORING_EOF__
  write_file panel/static/login.js 644 <<'__MONITORING_EOF__'
(() => {
  const T = {
    en: { title: "Server Monitor", signin_sub: "Sign in to continue", user: "Username", password: "Password", signin: "Sign in", otp: "Code from your authenticator app",
      otp_need: "Enter the 6-digit code from your authenticator app.", bad: "Wrong username or password", bad_otp: "Wrong username, password or code",
      locked: "Too many wrong attempts from this address. Try again in {m} minutes.", busy: "Too many requests. Wait a moment and try again.", net: "Could not reach the server",
      other: "فارسی", show: "Show password", hide: "Hide password", dark: "Dark theme (switch to light)", light: "Light theme (switch to dark)" },
    fa: { title: "مانیتورینگ سرور", signin_sub: "برای ادامه وارد شوید", user: "نام کاربری", password: "رمز عبور", signin: "ورود", otp: "کد برنامه‌ی احراز هویت",
      otp_need: "کد ۶ رقمی برنامه‌ی احراز هویت (مثل Google Authenticator) را وارد کنید.", bad: "نام کاربری یا رمز عبور اشتباه است", bad_otp: "نام کاربری، رمز یا کد اشتباه است",
      locked: "تلاش اشتباه زیادی از این آدرس شده. {m} دقیقه‌ی دیگر دوباره امتحان کنید.", busy: "درخواست زیاد است. کمی صبر کنید و دوباره امتحان کنید.", net: "ارتباط با سرور برقرار نشد",
      other: "English", show: "نمایش رمز", hide: "پنهان کردن رمز", dark: "تم تیره (تغییر به روشن)", light: "تم روشن (تغییر به تیره)" },
  };
  const save = (k, v) => { try { localStorage.setItem(k, v); } catch (e) { /* storage blocked */ } };
  let lang = null;
  try { lang = localStorage.getItem("lang"); } catch (e) { /* storage blocked */ }
  if (!T[lang]) lang = (navigator.language || "").toLowerCase().startsWith("fa") ? "fa" : "en";   // first visit: the browser's language
  let theme = document.documentElement.dataset.theme || "dark";   // chosen by boot.js before the first paint
  const t = (k, v = {}) => T[lang][k].replace(/\{(\w+)\}/g, (_, x) => v[x]);
  const SUN = '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>';
  const MOON = '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/></svg>';
  const EYE = '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>';
  const EYE_OFF = '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 3l18 18M10.6 5.1A10.7 10.7 0 0 1 12 5c6.4 0 10 7 10 7a17 17 0 0 1-3.2 4.1M6.6 6.6A17 17 0 0 0 2 12s3.6 7 10 7a9.8 9.8 0 0 0 5.4-1.6"/><path d="M9.9 9.9a3 3 0 0 0 4.2 4.2"/></svg>';
  const pw = document.getElementById("password"), pwBtn = document.getElementById("pw-toggle");
  function paint() {
    const d = document.documentElement;
    d.dataset.theme = theme;
    d.lang = lang;
    d.dir = lang === "fa" ? "rtl" : "ltr";
    document.querySelectorAll("[data-i18n]").forEach((el) => { el.textContent = T[lang][el.dataset.i18n]; });
    document.title = T[lang].signin + " - " + T[lang].title;
    document.querySelector("#lang span").textContent = t("other");
    const th = document.getElementById("theme");
    th.innerHTML = theme === "dark" ? SUN : MOON;
    th.setAttribute("aria-label", t(theme));
    th.title = t(theme);
    const shown = pw.type === "text";
    pwBtn.innerHTML = shown ? EYE_OFF : EYE;
    pwBtn.setAttribute("aria-label", t(shown ? "hide" : "show"));
    pwBtn.setAttribute("aria-pressed", String(shown));
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute("content", theme === "dark" ? "#070b12" : "#eef2f8");
  }
  paint();
  document.getElementById("lang").addEventListener("click", () => { lang = lang === "fa" ? "en" : "fa"; save("lang", lang); paint(); });
  document.getElementById("theme").addEventListener("click", () => { theme = theme === "dark" ? "light" : "dark"; save("theme", theme); paint(); });
  pwBtn.addEventListener("click", () => { pw.type = pw.type === "password" ? "text" : "password"; paint(); pw.focus(); });

  const form = document.getElementById("form"), err = document.getElementById("error"), btn = document.getElementById("submit");
  const otpBox = document.getElementById("otp-field"), otp = document.getElementById("otp");
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    err.textContent = "";
    btn.disabled = true;
    try {
      const r = await fetch("/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ user: form.user.value, password: form.password.value, otp: otp.value }),
      });
      if (r.ok) { location.replace("/"); return; }
      const d = await r.json().catch(() => ({}));
      if (d.otp && !otp.value) {             // password was right: now the second factor
        otpBox.hidden = false;
        err.textContent = t("otp_need");
        otp.focus();
      } else if (r.status === 429 && d.locked) {
        err.textContent = t("locked", { m: Math.max(1, Math.ceil(d.locked / 60)) });
      } else if (r.status === 429) {
        err.textContent = t("busy");
      } else {
        err.textContent = otpBox.hidden ? t("bad") : t("bad_otp");
        otp.value = "";
      }
    } catch (x) {
      err.textContent = t("net");
    }
    btn.disabled = false;
    if (otpBox.hidden) form.password.select();
  });
})();
__MONITORING_EOF__
  write_file panel/static/style.css 644 <<'__MONITORING_EOF__'
/* =====================================================================
   Server Monitor panel - design system
   Dark-first, glass-like layered surfaces, one mint accent.
   Layout: sidebar (>=1100px) -> icon rail (700-1099px) -> bottom tab bar (<700px).
   Chart colours are validated categorical slots (blue, orange, aqua); status colours are
   reserved for state and always come with a shape + label.
   ===================================================================== */
:root {
  --font: "Vazirmatn", ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, Tahoma, "Helvetica Neue", Arial, sans-serif;
  --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;

  --bg: #070b12;
  --glow-a: rgba(46, 230, 166, .09);
  --glow-b: rgba(77, 124, 255, .08);
  --surface: #0e1521;
  --surface-2: #121b2a;
  --surface-3: #18233a;
  --line: rgba(148, 172, 205, .13);
  --line-2: rgba(148, 172, 205, .24);
  --ink: #e9eff8;
  --muted: #8d9db3;
  --faint: #5f6f86;

  --accent: #2ee6a6;
  --accent-2: #17c58c;
  --accent-ink: #03271b;
  --accent-soft: rgba(46, 230, 166, .12);

  /* status: reserved for state, never reused as a series colour */
  --s-good: #22c55e;
  --s-warn: #fab219;
  --s-serious: #ec835a;
  --s-bad: #f0605d;

  /* categorical chart slots, validated for the dark surface */
  --c1: #3987e5;
  --c2: #d95926;
  --c3: #199e70;

  --shadow: 0 1px 0 rgba(255, 255, 255, .035) inset, 0 8px 24px -12px rgba(0, 0, 0, .55);
  --shadow-pop: 0 24px 70px rgba(0, 0, 0, .6);
  --radius: 16px;
  --side-w: 272px;
  --tab-h: 62px;
  color-scheme: dark;
}
:root[data-theme="light"] {
  --bg: #eef2f8;
  --glow-a: rgba(15, 160, 115, .09);
  --glow-b: rgba(60, 110, 230, .08);
  --surface: #ffffff;
  --surface-2: #f5f8fc;
  --surface-3: #e9eff7;
  --line: rgba(20, 45, 80, .10);
  --line-2: rgba(20, 45, 80, .2);
  --ink: #0d1a2b;
  --muted: #54667d;
  --faint: #8494a8;

  --accent: #0b8a62;
  --accent-2: #0a7a57;
  --accent-ink: #ffffff;
  --accent-soft: rgba(11, 138, 98, .10);

  --s-good: #0ca30c;
  --s-warn: #d99200;
  --s-serious: #d9622f;
  --s-bad: #d03b3b;

  --c1: #2a78d6;
  --c2: #e0561f;
  --c3: #14946a;

  --shadow: 0 1px 2px rgba(15, 35, 70, .05), 0 8px 24px -14px rgba(15, 35, 70, .25);
  --shadow-pop: 0 24px 70px rgba(15, 35, 70, .28);
  color-scheme: light;
}

* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
html, body { margin: 0; }
body {
  min-height: 100vh;
  min-height: 100dvh;
  background:
    radial-gradient(900px 480px at 88% -8%, var(--glow-a), transparent 62%),
    radial-gradient(800px 460px at -4% -6%, var(--glow-b), transparent 60%),
    var(--bg);
  background-attachment: fixed;
  color: var(--ink);
  font: 14.5px/1.55 var(--font);
  -webkit-font-smoothing: antialiased;
  -webkit-tap-highlight-color: transparent;
}
button, input, select, textarea { font: inherit; color: inherit; }
svg { display: block; flex: none; }
a { color: inherit; }
.ico { width: 18px; height: 18px; stroke: currentColor; fill: none; stroke-width: 1.9; stroke-linecap: round; stroke-linejoin: round; }
.num { direction: ltr; unicode-bidi: isolate; display: inline-block; }
code { font-family: var(--mono); font-size: 12.5px; direction: ltr; unicode-bidi: isolate; word-break: break-all; }
code.reason { word-break: normal; overflow-wrap: anywhere; line-height: 1.5; }
.muted { color: var(--muted); }
::selection { background: color-mix(in srgb, var(--accent) 35%, transparent); }
* { scrollbar-width: thin; scrollbar-color: var(--line-2) transparent; }

.card { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); box-shadow: var(--shadow); }

/* ================================================================== app shell */
.app { display: grid; grid-template-columns: var(--side-w) minmax(0, 1fr); min-height: 100vh; min-height: 100dvh; }

.sidebar {
  position: sticky; top: 0; height: 100vh; height: 100dvh; overflow-y: auto; overflow-x: hidden;
  padding: 22px 14px 18px; display: flex; flex-direction: column; gap: 4px;
  background: linear-gradient(180deg, color-mix(in srgb, var(--surface) 92%, transparent), color-mix(in srgb, var(--bg) 70%, transparent));
  border-inline-end: 1px solid var(--line);
  backdrop-filter: blur(14px);
}
.brand { display: flex; align-items: center; gap: 13px; padding: 0 8px 20px; min-width: 0; }
.logo {
  width: 42px; height: 42px; border-radius: 13px; display: grid; place-items: center; flex: none; color: var(--accent-ink);
  background: linear-gradient(145deg, var(--accent), var(--accent-2)); box-shadow: 0 8px 22px -8px var(--accent), 0 1px 0 rgba(255, 255, 255, .35) inset;
}
.logo .ico { width: 23px; height: 23px; stroke-width: 2.1; }
.brand-text { min-width: 0; }
.brand h1 { margin: 0; font-size: 17px; font-weight: 750; letter-spacing: .01em; line-height: 1.25; }
.brand small { display: block; color: var(--muted); font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

.sidebar h2 { margin: 14px 12px 8px; font-size: 11px; letter-spacing: .13em; color: var(--faint); font-weight: 700; text-transform: uppercase; }
.sidebar h2.second { margin-top: 22px; }
.nav { display: grid; gap: 3px; }
.nav a {
  position: relative; display: flex; align-items: center; gap: 12px; min-height: 44px; padding: 0 12px; border-radius: 12px;
  text-decoration: none; color: var(--muted); font-weight: 600; border: 1px solid transparent; cursor: pointer;
  transition: background .15s, color .15s, border-color .15s;
}
.nav a .ico { width: 19px; height: 19px; }
.nav a:hover { color: var(--ink); background: var(--surface-2); }
.nav a.active {
  color: var(--accent); background: var(--accent-soft); border-color: color-mix(in srgb, var(--accent) 28%, transparent);
}
.nav a.active::before {
  content: ""; position: absolute; inset-inline-start: -15px; top: 11px; bottom: 11px; width: 3px; border-radius: 3px; background: var(--accent);
  box-shadow: 0 0 12px var(--accent);
}
.nav a .name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.badge { font-size: 11.5px; font-weight: 700; padding: 1px 8px; border-radius: 999px; background: var(--surface-3); color: var(--muted); line-height: 1.7; }
.nav a.active .badge { background: color-mix(in srgb, var(--accent) 20%, transparent); color: var(--accent); }
.badge.bad { background: color-mix(in srgb, var(--s-bad) 18%, transparent); color: var(--s-bad); }
.side-foot { margin-top: auto; padding: 18px 10px 0; color: var(--faint); font-size: 11.5px; }

.main { min-width: 0; display: flex; flex-direction: column; }
.topbar {
  position: sticky; top: 0; z-index: 30; display: flex; align-items: center; justify-content: space-between; gap: 14px;
  padding: 12px clamp(14px, 3vw, 34px); min-height: 66px;
  background: color-mix(in srgb, var(--bg) 78%, transparent); backdrop-filter: blur(16px) saturate(1.3);
  border-bottom: 1px solid var(--line);
}
.top-left { display: flex; align-items: center; gap: 12px; min-width: 0; }
.top-brand { display: none; }
.top-title { margin: 0; font-size: 17px; font-weight: 750; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.live { display: inline-flex; align-items: center; gap: 9px; color: var(--muted); font-size: 12.5px; padding: 6px 12px; border-radius: 999px; background: var(--surface); border: 1px solid var(--line); min-width: 0; }
.live .pulse { width: 8px; height: 8px; border-radius: 50%; background: var(--s-good); flex: none; position: relative; }
.live .pulse::after { content: ""; position: absolute; inset: -4px; border-radius: 50%; border: 2px solid var(--s-good); opacity: 0; animation: pulse 2.4s ease-out infinite; }
@keyframes pulse { 0% { transform: scale(.5); opacity: .7; } 100% { transform: scale(1.5); opacity: 0; } }
.live span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.actions { display: flex; gap: 8px; align-items: center; flex: none; }

.content { padding: clamp(14px, 2.4vw, 30px) clamp(14px, 3vw, 34px) 60px; width: 100%; max-width: 1560px; margin: 0 auto; display: grid; gap: 18px; align-content: start; min-width: 0; }

/* ================================================================== buttons + forms */
.btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 8px; height: 40px; padding: 0 16px; border-radius: 12px;
  background: var(--surface-2); border: 1px solid var(--line-2); cursor: pointer; font-weight: 650; font-size: 13.5px;
  text-decoration: none; white-space: nowrap; transition: border-color .15s, background .15s, transform .06s, box-shadow .15s;
}
.btn:hover { border-color: color-mix(in srgb, var(--muted) 70%, transparent); background: var(--surface-3); }
.btn:active { transform: translateY(1px) scale(.99); }
.btn.icon { width: 40px; padding: 0; }
.btn.primary {
  background: linear-gradient(145deg, var(--accent), var(--accent-2)); border-color: transparent; color: var(--accent-ink);
  box-shadow: 0 6px 18px -8px var(--accent), 0 1px 0 rgba(255, 255, 255, .3) inset;
}
.btn.primary:hover { filter: brightness(1.07); background: linear-gradient(145deg, var(--accent), var(--accent-2)); }
.btn.danger { color: var(--s-bad); border-color: color-mix(in srgb, var(--s-bad) 42%, transparent); background: transparent; }
.btn.danger:hover { background: color-mix(in srgb, var(--s-bad) 12%, transparent); }
.btn.danger.solid { background: var(--s-bad); border-color: var(--s-bad); color: #fff; }
.btn.danger.solid:hover { filter: brightness(1.08); background: var(--s-bad); }
.btn.ghost { background: transparent; border-color: transparent; }
.btn.ghost:hover { background: var(--surface-2); }
.btn.small { height: 34px; padding: 0 13px; font-size: 12.5px; border-radius: 10px; }
.btn.small.icon { width: 34px; padding: 0; }
.btn:disabled { opacity: .5; cursor: not-allowed; }
.btn:focus-visible, select:focus-visible, input:focus-visible, textarea:focus-visible, .nav a:focus-visible, [data-go]:focus-visible {
  outline: 2px solid var(--accent); outline-offset: 2px;
}
.row-actions { display: flex; gap: 6px; flex-wrap: nowrap; }
.row-actions .btn.small.icon:hover { border-color: var(--accent); color: var(--accent); }
.row-actions .btn.small.icon.danger:hover { border-color: var(--s-bad); color: var(--s-bad); }

select {
  height: 36px; border-radius: 10px; background: var(--surface-2); border: 1px solid var(--line-2); padding: 0 12px; cursor: pointer; font-size: 13px; font-weight: 600;
}
.field { display: grid; gap: 7px; margin-bottom: 16px; }
.field.inline { margin: 0; }
.field label { font-size: 12.5px; color: var(--muted); font-weight: 650; }
.field input, .field select, .field textarea {
  width: 100%; border-radius: 12px; border: 1px solid var(--line-2); background: var(--surface-2); padding: 0 14px; color: var(--ink);
  transition: border-color .15s, box-shadow .15s;
}
.field input, .field select { height: 44px; }
.field textarea { padding: 11px 14px; min-height: 88px; resize: vertical; font-family: var(--mono); font-size: 13px; direction: ltr; text-align: left; }
.field input:focus, .field select:focus, .field textarea:focus { border-color: var(--accent); outline: none; box-shadow: 0 0 0 3px var(--accent-soft); }
.field .hint { color: var(--muted); font-size: 12px; margin: 0; }
.field-row { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
.inline-field { display: inline-flex; align-items: center; gap: 8px; }
.inline-field input {
  width: 96px; height: 36px; border-radius: 10px; border: 1px solid var(--line-2); background: var(--surface-2); padding: 0 10px; direction: ltr;
}
.inline-field input:focus { border-color: var(--accent); outline: none; box-shadow: 0 0 0 3px var(--accent-soft); }
.inline-field small { color: var(--muted); }
.form-error { color: var(--s-bad); font-size: 13px; min-height: 20px; margin-bottom: 8px; }

.switch { position: relative; display: inline-block; width: 44px; height: 26px; flex: none; }
.switch input { position: absolute; opacity: 0; inset: 0; width: 100%; height: 100%; margin: 0; cursor: pointer; z-index: 1; }
.switch span { position: absolute; inset: 0; border-radius: 999px; background: var(--line-2); transition: background .2s; }
.switch span::after { content: ""; position: absolute; top: 3px; inset-inline-start: 3px; width: 20px; height: 20px; border-radius: 50%; background: #fff; box-shadow: 0 1px 3px rgba(0, 0, 0, .35); transition: transform .2s; }
.switch input:checked + span { background: var(--accent-2); }
.switch input:checked + span::after { transform: translateX(18px); }
:root[dir="rtl"] .switch input:checked + span::after { transform: translateX(-18px); }
.switch input:focus-visible + span { outline: 2px solid var(--accent); outline-offset: 2px; }

/* ================================================================== overview: hero, gauges, tiles */
.stats { display: grid; gap: 14px; }
.stats[hidden] { display: none; }

.hero {
  position: relative; overflow: hidden; display: flex; align-items: center; gap: 20px; padding: 22px 26px; flex-wrap: wrap;
  --tone: var(--s-good);
  background: linear-gradient(115deg, color-mix(in srgb, var(--tone) 13%, var(--surface)) 0%, var(--surface) 62%);
  border-color: color-mix(in srgb, var(--tone) 32%, var(--line));
}
.hero.warn { --tone: var(--s-warn); }
.hero.bad { --tone: var(--s-bad); }
.hero::after {
  content: ""; position: absolute; inset-inline-end: -60px; top: -80px; width: 280px; height: 280px; border-radius: 50%;
  background: radial-gradient(circle, color-mix(in srgb, var(--tone) 22%, transparent), transparent 68%); pointer-events: none;
}
.hero-icon {
  width: 58px; height: 58px; border-radius: 18px; display: grid; place-items: center; flex: none; color: var(--tone);
  background: color-mix(in srgb, var(--tone) 16%, transparent); border: 1px solid color-mix(in srgb, var(--tone) 38%, transparent);
}
.hero-icon .ico { width: 28px; height: 28px; stroke-width: 2; }
.hero-text { flex: 1 1 280px; min-width: 0; position: relative; z-index: 1; }
.hero-text h2 { margin: 0; font-size: clamp(19px, 2.6vw, 25px); font-weight: 800; letter-spacing: -.005em; line-height: 1.3; }
.hero-text p { margin: 4px 0 0; color: var(--muted); overflow-wrap: anywhere; }
.hero-meta { display: flex; gap: 10px; flex-wrap: wrap; position: relative; z-index: 1; }
.chip { display: inline-flex; align-items: center; gap: 8px; padding: 7px 13px; border-radius: 12px; background: color-mix(in srgb, var(--surface-2) 80%, transparent); border: 1px solid var(--line); font-size: 12.5px; color: var(--muted); max-width: 100%; }
.chip .ico { width: 15px; height: 15px; color: var(--faint); }
.chip b { color: var(--ink); font-weight: 700; }

.gauges { display: grid; gap: 14px; grid-template-columns: repeat(3, minmax(0, 1fr)); }
.tiles { display: flex; flex-wrap: wrap; gap: 14px; }   /* the last row stretches: no empty slot after an odd number of tiles */
.tiles > * { flex: 1 1 196px; min-width: 0; }

.stat { position: relative; padding: 16px 18px; min-width: 0; transition: border-color .15s, transform .15s; }
.stat[data-go] { cursor: pointer; }
.stat[data-go]:hover { border-color: var(--line-2); transform: translateY(-1px); }
.stat .label { display: flex; align-items: center; gap: 9px; color: var(--muted); font-size: 13px; font-weight: 600; }
.stat .label .ico { width: 16px; height: 16px; color: var(--faint); }
.stat .value { margin-top: 8px; font-size: 27px; font-weight: 800; letter-spacing: -.015em; line-height: 1.15; }
.stat .value.tight { font-size: 20px; line-height: 31px; white-space: nowrap; }
.stat .value small { font-size: 13px; font-weight: 650; color: var(--muted); letter-spacing: 0; }
.stat .sub { margin-top: 8px; color: var(--muted); font-size: 12px; line-height: 1.55; overflow-wrap: anywhere; }
.stat.alert-on { border-color: color-mix(in srgb, var(--s-bad) 45%, var(--line)); background: linear-gradient(160deg, color-mix(in srgb, var(--s-bad) 10%, var(--surface)), var(--surface)); }
.stat.alert-on .value { color: var(--s-bad); }
.stat .ok-mark { color: var(--s-good); display: inline-flex; }
.stat .ok-mark .ico { width: 30px; height: 30px; stroke-width: 2.3; }
.spark { height: 34px; margin-top: 10px; direction: ltr; }
.spark svg { width: 100%; height: 34px; overflow: visible; }

/* ring gauge */
.stat.gauge { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 4px 18px; align-items: center; padding: 18px 20px; }
.ring { position: relative; width: 104px; height: 104px; --tone: var(--s-good); grid-row: span 3; }
.ring.warn { --tone: var(--s-warn); }
.ring.bad { --tone: var(--s-bad); }
.ring svg { width: 104px; height: 104px; transform: rotate(-90deg); }
.ring .track { stroke: color-mix(in srgb, var(--tone) 17%, transparent); }
.ring .fill { stroke: var(--tone); stroke-linecap: round; transition: stroke-dasharray .6s cubic-bezier(.3, .8, .3, 1); filter: drop-shadow(0 0 6px color-mix(in srgb, var(--tone) 45%, transparent)); }
.ring .center { position: absolute; inset: 0; display: grid; place-items: center; font-size: 24px; font-weight: 800; letter-spacing: -.02em; }
.ring .center small { font-size: 12px; font-weight: 700; color: var(--muted); margin-inline-start: 1px; }
.gauge .g-title { display: flex; align-items: center; gap: 8px; color: var(--muted); font-weight: 650; font-size: 13px; }
.gauge .g-title .ico { width: 16px; height: 16px; color: var(--faint); }
.gauge .g-main { font-size: 13px; color: var(--ink); overflow-wrap: anywhere; font-weight: 600; }
.gauge .sub { margin-top: 0; }
.lvl { display: inline-flex; align-items: center; gap: 6px; font-size: 11.5px; font-weight: 700; color: color-mix(in srgb, var(--tone, var(--s-good)) 60%, var(--ink)); }
.lvl::before { content: ""; width: 8px; height: 8px; background: var(--tone, var(--s-good)); border-radius: 50%; }
.ring.warn ~ .g-lvl .lvl::before, .gauge.warn .lvl::before { clip-path: polygon(50% 0, 100% 100%, 0 100%); border-radius: 0; }
.gauge.bad .lvl::before { clip-path: polygon(50% 0, 100% 50%, 50% 100%, 0 50%); border-radius: 0; }
.gauge { --tone: var(--s-good); }
.gauge.warn { --tone: var(--s-warn); }
.gauge.bad { --tone: var(--s-bad); }

/* linear meters (tables, small spaces): fill carries severity, track is the lighter same ramp */
.bar { height: 6px; border-radius: 6px; background: color-mix(in srgb, var(--s-good) 18%, transparent); margin-top: 10px; overflow: hidden; }
.bar > i { display: block; height: 100%; width: 0; border-radius: 6px; background: var(--s-good); transition: width .5s; }
.bar.warn { background: color-mix(in srgb, var(--s-warn) 20%, transparent); }
.bar.warn > i { background: var(--s-warn); }
.bar.bad { background: color-mix(in srgb, var(--s-bad) 20%, transparent); }
.bar.bad > i { background: var(--s-bad); }
.mini-bar { display: flex; align-items: center; gap: 10px; min-width: 190px; }
.mini-bar .bar { flex: 1; margin: 0; }

/* ================================================================== main panel */
.panel { padding: clamp(16px, 2.2vw, 28px); min-width: 0; }
.panel-head { display: flex; align-items: center; justify-content: space-between; gap: 14px; flex-wrap: wrap; }
.panel-head h2 { margin: 0; display: flex; align-items: center; gap: 12px; font-size: 21px; font-weight: 800; letter-spacing: -.005em; }
.panel-head h2 .ico {
  width: 38px; height: 38px; padding: 9px; border-radius: 12px; color: var(--accent); background: var(--accent-soft);
  border: 1px solid color-mix(in srgb, var(--accent) 25%, transparent);
}
.tools { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.panel .desc { color: var(--muted); margin: 12px 0 20px; max-width: 760px; }
.panel hr { display: none; }

.notice {
  display: flex; align-items: center; gap: 12px; padding: 13px 16px; border-radius: 12px; margin-bottom: 16px;
  background: color-mix(in srgb, var(--c1) 11%, transparent); border: 1px solid color-mix(in srgb, var(--c1) 30%, transparent); border-inline-start: 3px solid var(--c1);
}
.notice .ico { color: var(--c1); }
.notice.bad { background: color-mix(in srgb, var(--s-bad) 10%, transparent); border-color: color-mix(in srgb, var(--s-bad) 35%, transparent); border-inline-start-color: var(--s-bad); }
.notice.bad .ico { color: var(--s-bad); }
.notice.ok { background: color-mix(in srgb, var(--s-good) 10%, transparent); border-color: color-mix(in srgb, var(--s-good) 32%, transparent); border-inline-start-color: var(--s-good); }
.notice.ok .ico { color: var(--s-good); }
.notice.warn { background: color-mix(in srgb, var(--s-warn) 11%, transparent); border-color: color-mix(in srgb, var(--s-warn) 36%, transparent); border-inline-start-color: var(--s-warn); }
.notice.warn .ico { color: var(--s-warn); }

/* ---------- tables */
.table-wrap { overflow-x: auto; border: 1px solid var(--line); border-radius: 14px; background: color-mix(in srgb, var(--surface-2) 40%, transparent); }
table { width: 100%; border-collapse: collapse; min-width: 640px; }
th, td { text-align: start; padding: 14px 16px; white-space: nowrap; }
th { font-size: 12px; letter-spacing: .03em; color: var(--muted); font-weight: 700; background: color-mix(in srgb, var(--surface-2) 80%, transparent); border-bottom: 1px solid var(--line); }
td { border-bottom: 1px solid var(--line); }
tr:last-child td { border-bottom: 0; }
tbody tr { transition: background .12s; }
tbody tr:hover td { background: color-mix(in srgb, var(--surface-3) 55%, transparent); }
td .num, td code { font-variant-numeric: tabular-nums; }
td.strong { font-weight: 700; }
td.wrap-cell { white-space: normal; min-width: 240px; }
td.muted { color: var(--muted); }
.empty { padding: 36px 16px; text-align: center; color: var(--muted); }
.sub-line { color: var(--muted); font-size: 12px; font-weight: 400; margin-top: 2px; white-space: normal; max-width: 460px; }
.tag { display: inline-block; font-size: 11px; font-weight: 700; padding: 1px 8px; border-radius: 7px; background: var(--surface-3); border: 1px solid var(--line); color: var(--muted); margin-inline-start: 8px; vertical-align: middle; }
.chips { display: flex; flex-wrap: wrap; gap: 6px; }
.chips code { background: var(--surface-3); border: 1px solid var(--line); border-radius: 7px; padding: 1px 8px; font-size: 12px; }

/* ---------- status pills: colour + shape + label, never colour alone */
.pill {
  --tone: var(--muted);
  display: inline-flex; align-items: center; gap: 7px; padding: 3px 12px; border-radius: 999px; font-size: 12.5px; font-weight: 650;
  background: color-mix(in srgb, var(--tone) 13%, transparent); border: 1px solid color-mix(in srgb, var(--tone) 32%, transparent);
  color: color-mix(in srgb, var(--tone) 55%, var(--ink));
}
.pill.ok { --tone: var(--s-good); }
.pill.info { --tone: var(--c1); }
.pill.warn { --tone: var(--s-warn); }
.pill.bad { --tone: var(--s-bad); }
.pill.dot::before { content: ""; width: 8px; height: 8px; background: var(--tone); border-radius: 50%; flex: none; }
.pill.warn.dot::before { border-radius: 0; clip-path: polygon(50% 0, 100% 100%, 0 100%); width: 9px; height: 9px; }
.pill.bad.dot::before { border-radius: 0; clip-path: polygon(50% 0, 100% 50%, 50% 100%, 0 50%); width: 9px; height: 9px; }

/* ================================================================== charts */
.charts { display: grid; gap: 14px; grid-template-columns: repeat(2, minmax(0, 1fr)); }
.chart { border: 1px solid var(--line); border-radius: 16px; padding: 16px 18px 12px; background: var(--surface-2); position: relative; min-width: 0; }
.chart header { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-bottom: 4px; }
.chart h3 { margin: 0; font-size: 14px; font-weight: 700; flex: 1; min-width: 0; }
.chart .now { font-size: 22px; font-weight: 800; letter-spacing: -.01em; }
.chart .legend { display: flex; flex-wrap: wrap; gap: 6px 16px; color: var(--muted); font-size: 12px; margin: 2px 0 6px; }
.chart .legend span { display: inline-flex; align-items: center; }
.chart .legend i { display: inline-block; width: 10px; height: 10px; border-radius: 3px; margin-inline-end: 7px; }
.chart .view-toggle { color: var(--muted); }
.chart .view-toggle[aria-pressed="true"] { color: var(--accent); background: var(--accent-soft); }
.plot { direction: ltr; position: relative; min-height: 190px; }
.plot svg { width: 100%; height: 190px; overflow: visible; max-width: 100%; touch-action: pan-y; display: block; }
.plot .grid line { stroke: var(--line); stroke-width: 1; }
.plot text { fill: var(--muted); font-size: 11px; font-family: var(--font); }
.plot .cross { stroke: var(--line-2); stroke-width: 1; }
.plot .dots circle { stroke: var(--surface-2); stroke-width: 2; }
.chart-table { max-height: 190px; overflow: auto; border-radius: 10px; border: 1px solid var(--line); }
.chart-table table { min-width: 0; }
.chart-table th, .chart-table td { padding: 7px 12px; font-size: 12.5px; }
.chart-table th { position: sticky; top: 0; }
.tip {
  position: absolute; pointer-events: none; background: color-mix(in srgb, var(--surface) 94%, transparent); border: 1px solid var(--line-2);
  border-radius: 12px; padding: 8px 11px; font-size: 12px; white-space: nowrap; box-shadow: var(--shadow-pop); z-index: 3; backdrop-filter: blur(8px);
}
.tip .t { color: var(--muted); font-size: 11.5px; margin-bottom: 4px; }
.tip .r { display: flex; align-items: center; gap: 8px; line-height: 1.7; }
.tip .r i { width: 10px; height: 3px; border-radius: 2px; flex: none; }
.tip .r b { font-weight: 800; font-size: 13px; }
.tip .r span { color: var(--muted); }

.skeleton { height: 120px; border-radius: 14px; background: linear-gradient(90deg, var(--surface-2), var(--surface-3), var(--surface-2)); background-size: 200% 100%; animation: sk 1.3s infinite; }
@keyframes sk { to { background-position: -200% 0; } }

/* ================================================================== management UI */
.split { display: grid; gap: 16px; grid-template-columns: repeat(auto-fit, minmax(min(340px, 100%), 1fr)); align-items: start; }
.subcard { border: 1px solid var(--line); border-radius: 16px; background: var(--surface-2); padding: 22px 24px; }
.subcard h3 { margin: 0 0 4px; font-size: 16px; display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.subcard p { color: var(--muted); margin: 6px 0 14px; }
.subcard .field { margin-bottom: 14px; }
.subcard .actions-row { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 6px; }
.steps { margin: 8px 0 16px; padding-inline-start: 20px; color: var(--muted); }
.steps li { margin: 4px 0; }
.codebox { position: relative; background: var(--bg); border: 1px solid var(--line); border-radius: 12px; padding: 12px 14px; margin: 8px 0 12px; font-family: var(--mono); font-size: 12.5px; direction: ltr; text-align: left; overflow-x: auto; white-space: pre; }

/* ================================================================== dialogs + toasts */
dialog.modal {
  border: 1px solid var(--line-2); border-radius: 20px; background: var(--surface); color: var(--ink); padding: 0;
  width: min(560px, calc(100vw - 24px)); max-height: calc(100dvh - 32px); box-shadow: var(--shadow-pop); animation: pop .18s ease-out;
}
dialog.modal.wide { width: min(920px, calc(100vw - 24px)); }
dialog.modal::backdrop { background: rgba(3, 7, 12, .66); backdrop-filter: blur(4px); }
@keyframes pop { from { transform: translateY(10px) scale(.98); opacity: 0; } }
.modal-form { display: flex; flex-direction: column; max-height: calc(100dvh - 32px); }
.modal-form header { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 20px 24px 12px; }
.modal-form header h3 { margin: 0; font-size: 18px; font-weight: 800; }
.modal-body { padding: 4px 24px 8px; overflow-y: auto; overscroll-behavior: contain; }
.modal-body .field { margin-bottom: 14px; }
.modal-form .form-error { padding: 0 24px; min-height: 0; margin: 0; }
.modal-form .form-error:not(:empty) { padding-top: 6px; padding-bottom: 6px; }
.modal-form footer { display: flex; justify-content: flex-end; gap: 10px; padding: 14px 24px 22px; flex-wrap: wrap; }
pre.logs { margin: 0; background: var(--bg); border: 1px solid var(--line); border-radius: 12px; padding: 12px 14px; height: min(60vh, 520px); overflow: auto; font-size: 12px; line-height: 1.5; font-family: var(--mono); direction: ltr; text-align: left; white-space: pre-wrap; word-break: break-all; }

dialog.sheet { border: 0; padding: 0; background: transparent; margin: auto 0 0; max-width: none; width: 100%; max-height: 88dvh; color: var(--ink); }
dialog.sheet::backdrop { background: rgba(3, 7, 12, .6); backdrop-filter: blur(4px); }
.sheet-card {
  background: var(--surface); border: 1px solid var(--line-2); border-bottom: 0; border-radius: 22px 22px 0 0; padding: 10px 16px calc(18px + env(safe-area-inset-bottom, 0px));
  box-shadow: var(--shadow-pop); animation: rise .22s ease-out; max-height: 88dvh; overflow-y: auto;
}
.sheet-card::before { content: ""; display: block; width: 40px; height: 4px; border-radius: 4px; background: var(--line-2); margin: 0 auto 14px; }
.sheet-card h3 { margin: 4px 6px 12px; font-size: 13px; color: var(--faint); letter-spacing: .1em; text-transform: uppercase; }
.sheet-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px; }
.sheet-grid button {
  display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 8px; min-height: 84px; padding: 10px 6px; border-radius: 16px;
  background: var(--surface-2); border: 1px solid var(--line); color: var(--ink); font-weight: 650; font-size: 12.5px; cursor: pointer; text-align: center;
}
.sheet-grid button .ico { width: 22px; height: 22px; color: var(--accent); }
.sheet-grid button.active { border-color: color-mix(in srgb, var(--accent) 45%, transparent); background: var(--accent-soft); }
@keyframes rise { from { transform: translateY(40px); opacity: 0; } }

.toasts { position: fixed; inset-inline-end: 18px; bottom: 18px; display: grid; gap: 8px; z-index: 80; max-width: min(420px, calc(100vw - 32px)); }
.toast {
  display: flex; gap: 10px; align-items: flex-start; padding: 13px 16px; border-radius: 14px; background: var(--surface); border: 1px solid var(--line-2);
  border-inline-start: 3px solid var(--s-good); box-shadow: var(--shadow-pop); animation: toast-in .2s ease-out; overflow-wrap: anywhere;
}
.toast.bad { border-inline-start-color: var(--s-bad); }
.toast.warn { border-inline-start-color: var(--s-warn); }
@keyframes toast-in { from { transform: translateY(8px); opacity: 0; } }

/* ================================================================== bottom tab bar (phones) */
.tabbar { display: none; }

/* ================================================================== login */
.login-page { min-height: 100vh; min-height: 100dvh; display: grid; place-items: center; padding: 24px max(16px, env(safe-area-inset-left, 0px)) 24px max(16px, env(safe-area-inset-right, 0px)); }
.login-card { width: 100%; max-width: 420px; padding: 34px 32px 30px; position: relative; overflow: hidden; border-radius: 24px; }
.login-card::before {
  content: ""; position: absolute; inset-inline: 0; top: 0; height: 3px; background: linear-gradient(90deg, transparent, var(--accent), transparent);
}
.login-card .brand { flex-direction: column; text-align: center; padding: 0 0 26px; gap: 14px; }
.login-card .logo { width: 62px; height: 62px; border-radius: 20px; }
.login-card .logo .ico { width: 32px; height: 32px; }
.login-card .brand h1 { font-size: 22px; }
.login-card .brand small { font-size: 13.5px; white-space: normal; }
.login-card .btn.primary { width: 100%; height: 48px; font-size: 15px; }
.login-card .field input { height: 48px; }

/* ================================================================== responsive */
@media (max-width: 1280px) {
  .gauges { grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); }
}

/* icon rail */
@media (max-width: 1099px) {
  :root { --side-w: 82px; }
  .sidebar { padding: 18px 12px; align-items: stretch; }
  .brand { padding: 0 0 18px; justify-content: center; }
  .brand-text, .sidebar h2, .side-foot { display: none; }
  .nav a { justify-content: center; padding: 0; min-height: 48px; }
  .nav a .name { display: none; }
  .nav a .badge { position: absolute; top: 3px; inset-inline-end: 2px; min-width: 18px; padding: 0 5px; text-align: center; font-size: 10.5px; line-height: 17px; }
  .nav a.active::before { inset-inline-start: -13px; }
  .nav + .nav { margin-top: 14px; padding-top: 14px; border-top: 1px solid var(--line); }
  .charts { grid-template-columns: minmax(0, 1fr); }
}

/* phones */
@media (max-width: 699px) {
  :root { --side-w: 0px; }
  .app { display: block; }
  .sidebar { display: none; }
  .topbar { min-height: 58px; padding-block: 8px; padding-inline: max(14px, env(safe-area-inset-left, 0px)) max(14px, env(safe-area-inset-right, 0px)); top: 0; padding-top: calc(8px + env(safe-area-inset-top, 0px)); }
  .top-brand { display: grid; width: 36px; height: 36px; border-radius: 11px; }
  .top-brand .ico { width: 20px; height: 20px; }
  .live { padding: 10px; gap: 0; }   /* just the status dot; the text stays for screen readers */
  .live span { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }
  .actions { gap: 6px; }
  .actions .btn { width: 42px; height: 42px; padding: 0; }
  .btn .txt { display: none; }
  .content { padding-inline: max(14px, env(safe-area-inset-left, 0px)) max(14px, env(safe-area-inset-right, 0px)); padding-bottom: calc(var(--tab-h) + 34px + env(safe-area-inset-bottom, 0px)); gap: 14px; }
  .panel { padding: 16px 14px; }
  .panel-head h2 { font-size: 18px; }
  .hero { padding: 18px 16px; gap: 14px; }
  .hero-icon { width: 50px; height: 50px; border-radius: 16px; }
  .gauges { grid-template-columns: minmax(0, 1fr); }
  .stat.gauge { padding: 14px 16px; }
  .ring, .ring svg { width: 92px; height: 92px; }
  .ring .center { font-size: 21px; }
  .tiles { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
  .tiles > :last-child:nth-child(odd) { grid-column: 1 / -1; }
  .stat { padding: 14px; }
  .stat .value { font-size: 23px; }
  .stat .value.tight { font-size: 17px; }
  .field-row { grid-template-columns: minmax(0, 1fr); }
  .subcard { padding: 16px; }
  .plot svg, .plot { min-height: 170px; }
  .plot svg { height: 170px; }
  .chart { padding: 14px 12px 10px; }

  .tabbar {
    position: fixed; z-index: 40; inset-inline: 0; bottom: 0; display: grid; grid-template-columns: repeat(5, minmax(0, 1fr));
    padding: 6px max(8px, env(safe-area-inset-left, 0px)) calc(6px + env(safe-area-inset-bottom, 0px)) max(8px, env(safe-area-inset-right, 0px));
    background: color-mix(in srgb, var(--surface) 90%, transparent); backdrop-filter: blur(18px) saturate(1.4);
    border-top: 1px solid var(--line-2); box-shadow: 0 -10px 30px -18px rgba(0, 0, 0, .6);
  }
  .tabbar button {
    position: relative; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 3px; min-height: 50px;
    background: none; border: 0; border-radius: 14px; color: var(--muted); font-size: 11px; font-weight: 650; cursor: pointer; padding: 4px 2px;
  }
  .tabbar button .ico { width: 22px; height: 22px; }
  .tabbar button .lbl { max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .tabbar button.active { color: var(--accent); }
  .tabbar button.active::before { content: ""; position: absolute; top: -7px; width: 28px; height: 3px; border-radius: 0 0 4px 4px; background: var(--accent); box-shadow: 0 0 10px var(--accent); }
  .tabbar .dot { position: absolute; top: 5px; inset-inline-start: calc(50% + 6px); min-width: 16px; height: 16px; padding: 0 4px; border-radius: 999px; background: var(--s-bad); color: #fff; font-size: 10px; line-height: 16px; text-align: center; font-weight: 800; }

  /* tables become card lists */
  .table-wrap { border: 0; background: none; overflow: visible; }
  table, thead, tbody, tr, td { display: block; }
  table { min-width: 0; }
  thead { display: none; }
  tbody tr { border: 1px solid var(--line); border-radius: 16px; background: var(--surface-2); padding: 12px 14px; margin-bottom: 10px; }
  tbody tr:hover td { background: none; }
  td { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 7px 0; border: 0; white-space: normal; text-align: end; min-width: 0; }
  td::before { content: attr(data-label); color: var(--muted); font-size: 12px; font-weight: 600; text-align: start; flex: none; }
  td:first-child { display: block; text-align: start; padding-top: 0; padding-bottom: 8px; margin-bottom: 4px; border-bottom: 1px solid var(--line); font-size: 15px; }
  td:first-child::before { display: none; }
  td.wrap-cell { min-width: 0; }
  td .sub-line { max-width: none; }
  td .chips { justify-content: flex-end; }
  td .mini-bar { min-width: 0; width: 100%; max-width: 190px; }
  td[data-label=""]::before, td:not([data-label])::before { display: none; }
  td.act { justify-content: flex-end; padding-top: 10px; margin-top: 4px; border-top: 1px solid var(--line); }
  td.act::before { display: none; }
  .row-actions { gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
  .row-actions .btn.small.icon { width: 42px; height: 42px; }
  .btn.small { height: 40px; }
  .tools .btn.small { height: 40px; }
  .chart-table { max-height: 170px; }
  .chart-table td, .chart-table th { display: table-cell; }
  .chart-table table { display: table; }
  .chart-table thead { display: table-header-group; }
  .chart-table tbody { display: table-row-group; }
  .chart-table tr { display: table-row; padding: 0; border: 0; margin: 0; background: none; border-radius: 0; }
  .chart-table td::before { display: none; }
  .chart-table td { text-align: start; padding: 7px 12px; border-bottom: 1px solid var(--line); }
  .chart-table td:first-child { display: table-cell; font-size: 12.5px; margin: 0; }

  /* dialogs become bottom sheets */
  dialog.modal, dialog.modal.wide { width: 100%; max-width: none; margin: auto 0 0; border-radius: 22px 22px 0 0; border-bottom: 0; max-height: 92dvh; animation: rise .22s ease-out; }
  .modal-form { max-height: 92dvh; }
  .modal-form header, .modal-body, .modal-form footer, .modal-form .form-error { padding-inline: 16px; }
  .modal-form footer { padding-bottom: calc(18px + env(safe-area-inset-bottom, 0px)); }
  .modal-form footer .btn { flex: 1; height: 46px; }
  .field input, .field select { height: 48px; font-size: 16px; }   /* 16px stops iOS zooming into inputs */
  .field textarea { font-size: 16px; }
  .toasts { inset-inline: 12px; bottom: calc(var(--tab-h) + 16px + env(safe-area-inset-bottom, 0px)); max-width: none; }
  .login-card { padding: 28px 22px 24px; }
}

@media (max-width: 380px) {
  .tiles { display: grid; grid-template-columns: minmax(0, 1fr); }
  .top-title { font-size: 15px; }
}
@media (prefers-reduced-motion: reduce) { * { animation: none !important; transition: none !important; } }

/* sparklines inside tiles and gauges */
.spark { position: relative; }
.spark .sd { position: absolute; inset-inline-end: 0; width: 8px; height: 8px; margin-top: -4px; border-radius: 50%; transform: translateX(50%); box-shadow: 0 0 0 2px var(--surface); }
.spark:empty { display: none; }
.gauge .spark { grid-column: 1 / -1; }
#banner:empty { display: none; }
.gauge { align-content: center; }

/* public IP chips (click to copy) */
button.chip { font: inherit; cursor: pointer; color: var(--muted); text-align: start; overflow-wrap: anywhere; transition: border-color .15s, background .15s; }
button.chip:hover:not(:disabled) { border-color: var(--accent); background: var(--accent-soft); }
button.chip:disabled { cursor: default; opacity: .6; }
.chip .ipl { font-size: 10.5px; letter-spacing: .08em; color: var(--accent); background: var(--accent-soft); padding: 0 6px; border-radius: 6px; line-height: 1.7; }

/* ================================================================== network page: traffic usage */
.sec { display: grid; gap: 14px; }
.sec + .sec { margin-top: 26px; }
.sec-head { display: flex; align-items: baseline; gap: 6px 14px; flex-wrap: wrap; }
.sec-head h3 { margin: 0; display: flex; align-items: center; gap: 10px; font-size: 16px; font-weight: 800; }
.sec-head h3 .ico { color: var(--accent); width: 18px; height: 18px; }
.sec-head p { margin: 0; font-size: 12.5px; }

.usage-grid { display: grid; gap: 14px; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); }
.usage { border: 1px solid var(--line); border-radius: 16px; background: var(--surface-2); padding: 16px 18px 14px; min-width: 0; display: grid; gap: 10px; align-content: start; }
.u-label { color: var(--muted); font-size: 12.5px; font-weight: 700; letter-spacing: .03em; }
.u-total { font-size: 28px; font-weight: 800; letter-spacing: -.015em; line-height: 1.1; }
.u-split { display: flex; gap: 2px; height: 8px; border-radius: 6px; overflow: hidden; background: var(--surface-3); direction: ltr; }
.u-split i { display: block; height: 100%; min-width: 0; transition: width .5s; }
.u-split i.rx { background: var(--c1); border-radius: 6px 2px 2px 6px; }
.u-split i.tx { background: var(--c2); border-radius: 2px 6px 6px 2px; }
.u-rows { display: grid; gap: 6px; }
.u-rows > div { display: flex; align-items: center; gap: 8px; font-size: 13px; color: var(--muted); }
.u-rows .ico { width: 15px; height: 15px; color: var(--faint); }
.u-rows span:not(.k) { flex: 1; min-width: 0; }
.u-rows b { color: var(--ink); font-weight: 750; font-variant-numeric: tabular-nums; }
.u-rows .k { width: 10px; height: 10px; border-radius: 3px; flex: none; }
.u-rows .k.rx { background: var(--c1); }
.u-rows .k.tx { background: var(--c2); }
.u-note { font-size: 11.5px; color: var(--faint); line-height: 1.4; }

.tr-chart .legend { align-items: center; }
.tr-chart .legend .chip { padding: 3px 10px; font-size: 12px; margin-inline-start: auto; }
.tr-chart .legend .chip + .chip { margin-inline-start: 0; }
.plot .hl { fill: var(--line); }
.tip .r i:empty { background: none; }

@media (max-width: 699px) {
  .usage-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
  .usage { padding: 14px; }
  .u-total { font-size: 22px; }
  .tr-chart .legend .chip { margin-inline-start: 0; }
}
@media (max-width: 380px) { .usage-grid { grid-template-columns: minmax(0, 1fr); } }

/* diagnosis dialog */
#diag h4 { margin: 18px 0 8px; font-size: 13.5px; color: var(--muted); letter-spacing: .03em; }
#diag .diag-chips { display: flex; gap: 8px; flex-wrap: wrap; margin: 4px 0; }
#diag .notice .ico { flex: none; }
pre.logs.short { height: auto; max-height: 220px; }
.notice > .btn { margin-inline-start: auto; flex: none; }

/* ================================================================== live data (one sample a second) */
.live { transition: color .3s, border-color .3s; }
.live.is-live { color: var(--ink); border-color: color-mix(in srgb, var(--s-good) 38%, var(--line)); }
.live.is-wait .pulse { background: var(--s-warn); }
.live.is-wait .pulse::after { border-color: var(--s-warn); }
.live:not(.is-live):not(.is-wait) .pulse { background: var(--faint); }
.live:not(.is-live):not(.is-wait) .pulse::after { animation: none; }
.live .pulse.beat { animation: beat .6s cubic-bezier(.3, .8, .3, 1); }
@keyframes beat {
  0% { transform: scale(1.7); box-shadow: 0 0 0 0 color-mix(in srgb, var(--s-good) 55%, transparent); }
  100% { transform: scale(1); box-shadow: 0 0 0 7px transparent; }
}
.live-tag {
  display: inline-flex; align-items: center; gap: 6px; margin-inline-start: 10px; padding: 2px 9px; border-radius: 999px; vertical-align: middle;
  font-size: 11px; font-weight: 700; letter-spacing: .04em; color: var(--s-good); background: color-mix(in srgb, var(--s-good) 13%, transparent);
}
.live-tag i { width: 6px; height: 6px; border-radius: 50%; background: currentColor; animation: blink 1.6s ease-in-out infinite; }
@keyframes blink { 50% { opacity: .25; } }
.live-tag[hidden], #live-note[hidden] { display: none; }
#live-note { margin-bottom: 14px; }
/* numbers glide between values; equal-width digits keep them from jittering while they do */
.num, .stat .value, .ring .center, .chart .now { font-variant-numeric: tabular-nums; }
.hero { transition: border-color .5s, box-shadow .5s; }
.hero-icon { transition: color .5s, background-color .5s, border-color .5s; }
.stat.gauge { transition: border-color .5s, transform .15s; }
.lvl { transition: color .4s; }

/* ================================================================== Defender */
.df-tabs { display: flex; gap: 6px; padding: 5px; margin-bottom: 18px; border: 1px solid var(--line); border-radius: 14px; background: var(--surface-2); overflow-x: auto; scrollbar-width: none; }
.df-tabs::-webkit-scrollbar { display: none; }
.df-tab { display: inline-flex; align-items: center; gap: 8px; flex: 1 0 auto; justify-content: center; padding: 9px 14px; border-radius: 10px; border: 1px solid transparent; background: none; color: var(--muted); font: inherit; font-weight: 650; font-size: 13.5px; cursor: pointer; white-space: nowrap; transition: background .15s, color .15s, border-color .15s; }
.df-tab .ico { width: 17px; height: 17px; }
.df-tab:hover { color: var(--ink); background: var(--surface); }
.df-tab.on { color: var(--accent); background: var(--accent-soft); border-color: color-mix(in srgb, var(--accent) 28%, transparent); }
.df-tab:focus-visible, .df-opt:focus-visible, .df-seg button:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.df-body { display: grid; gap: 22px; }
.df-hero .hero-text .hero-meta { margin-top: 12px; }
.df-hero-act { display: flex; flex-direction: column; align-items: flex-end; gap: 10px; position: relative; z-index: 1; margin-inline-start: auto; }
.df-cta { padding: 12px 22px; font-size: 15px; }
.df-cmd { height: auto; margin: 10px 0; white-space: pre-wrap; }
.df-seg { display: inline-flex; padding: 4px; gap: 4px; border-radius: 12px; background: var(--surface-2); border: 1px solid var(--line); }
.df-seg button { border: 0; background: none; color: var(--muted); font: inherit; font-size: 13px; font-weight: 650; padding: 7px 13px; border-radius: 9px; cursor: pointer; white-space: nowrap; }
.df-seg button.on { background: var(--surface); color: var(--ink); box-shadow: 0 1px 0 var(--line-2), 0 2px 8px -4px rgba(0, 0, 0, .4); }
.df-seg button[data-p="attack"].on { color: var(--s-bad); }
.df-tiles { grid-template-columns: repeat(auto-fill, minmax(170px, 1fr)); }
.df-grid2 { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 22px; align-items: start; }
.df-grid2 > .sec + .sec { margin-top: 0; }   /* side by side: no gap above the second one */
.df-head-row { display: flex; align-items: flex-end; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
.df-head-row h3 { display: flex; align-items: center; gap: 8px; }
.df-bars { display: grid; gap: 9px; }
.df-bar { position: relative; display: flex; justify-content: space-between; gap: 10px; padding: 9px 12px; border-radius: 10px; background: var(--surface-2); border: 1px solid var(--line); overflow: hidden; font-size: 13px; }
.df-bar span, .df-bar b { position: relative; z-index: 1; }
.df-bar i { position: absolute; inset-block: 0; inset-inline-start: 0; background: color-mix(in srgb, var(--c2) 22%, transparent); transition: width .5s cubic-bezier(.3, .8, .3, 1); }
.df-events { list-style: none; margin: 0; padding: 0; display: grid; gap: 2px; }
.df-events li { display: grid; grid-template-columns: auto minmax(0, 1fr) auto; gap: 12px; align-items: center; padding: 9px 4px; border-bottom: 1px solid var(--line); font-size: 13.5px; }
.df-events li:last-child { border-bottom: 0; }
.df-events .ev-ic { width: 30px; height: 30px; border-radius: 9px; display: grid; place-items: center; background: var(--surface-2); border: 1px solid var(--line); color: var(--muted); }
.df-events .ev-ic .ico { width: 15px; height: 15px; }
.df-events .ev-t { overflow-wrap: anywhere; }
.df-events time { color: var(--faint); font-size: 12px; white-space: nowrap; }
.df-events .ev-attack_start .ev-ic, .df-events .ev-ssh_ban .ev-ic, .df-events .ev-ban .ev-ic, .df-events .ev-block .ev-ic { color: var(--s-bad); border-color: color-mix(in srgb, var(--s-bad) 35%, var(--line)); }
.df-events .ev-attack_end .ev-ic, .df-events .ev-confirmed .ev-ic, .df-events .ev-allow .ev-ic { color: var(--s-good); }
.df-events .ev-escalate .ev-ic, .df-events .ev-rollback .ev-ic { color: var(--s-warn); }
.df-choice { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
.df-choice4 { grid-template-columns: repeat(4, minmax(0, 1fr)); }
.df-opt { display: grid; gap: 6px; align-content: start; text-align: start; padding: 16px 18px; border-radius: 14px; border: 1px solid var(--line); background: var(--surface-2); color: var(--ink); font: inherit; cursor: pointer; transition: border-color .15s, background .15s, box-shadow .15s; }
.df-opt:hover:not(:disabled) { border-color: var(--line-2); }
.df-opt b { font-size: 15px; }
.df-opt > span { color: var(--muted); font-size: 13px; line-height: 1.55; }
.df-opt.on { border-color: var(--accent); background: color-mix(in srgb, var(--accent) 8%, var(--surface-2)); box-shadow: 0 0 0 3px var(--accent-soft); }
.df-opt:disabled { cursor: default; opacity: .75; }
.df-opt-ic { width: 34px; height: 34px; border-radius: 10px; display: grid; place-items: center; background: var(--surface); border: 1px solid var(--line); color: var(--accent); }
.df-opt .df-nums { font-size: 12px; color: var(--faint); margin-top: 4px; }
.df-prof[data-p="attack"].on { border-color: var(--s-bad); box-shadow: 0 0 0 3px color-mix(in srgb, var(--s-bad) 15%, transparent); }
.df-always { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-top: 4px; }
.chips { display: flex; flex-wrap: wrap; gap: 8px; }
.chip-x { border: 0; background: none; color: var(--faint); padding: 0; margin-inline-start: 2px; cursor: pointer; display: inline-grid; place-items: center; width: 20px; height: 20px; border-radius: 6px; }
.chip-x:hover { color: var(--s-bad); background: color-mix(in srgb, var(--s-bad) 12%, transparent); }
.chip-x .ico { width: 14px; height: 14px; }
.df-inline { margin-top: 10px; flex-wrap: wrap; }
.df-actions { position: sticky; bottom: 12px; z-index: 5; display: flex; gap: 10px; align-items: center; justify-content: flex-end; flex-wrap: wrap; padding: 12px 14px; border-radius: 14px; border: 1px solid var(--line); background: color-mix(in srgb, var(--surface) 92%, transparent); backdrop-filter: blur(8px); }
.df-actions > .muted { margin-inline-end: auto; }
.df-actions.dirty { border-color: color-mix(in srgb, var(--s-warn) 45%, var(--line)); }
.df-actions.dirty > .muted { color: var(--s-warn); font-weight: 650; }
.df-form-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 0 14px; }
.df-switch { display: flex; align-items: center; gap: 12px; margin: 0 0 14px; cursor: pointer; }
.df-switch b { font-weight: 650; }
.df-switch small { display: block; color: var(--muted); font-size: 12.5px; margin-top: 2px; }
.df-covers { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
.df-covers li { display: flex; gap: 10px; align-items: flex-start; }
.df-covers .ico { width: 18px; height: 18px; color: var(--s-good); flex: none; margin-top: 2px; }
.df-covers li.no .ico { color: var(--s-warn); }
.df-covers li.no { color: var(--muted); }
.df-filter { min-width: 0; width: 220px; max-width: 100%; padding: 8px 12px; border-radius: 10px; border: 1px solid var(--line); background: var(--surface-2); color: var(--ink); font: inherit; }
.df-filter:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 0 3px var(--accent-soft); }
.df-score { display: flex; align-items: center; gap: 22px; padding: 20px 24px; --tone: var(--s-good); }
.df-score.warn { --tone: var(--s-warn); }
.df-score.bad { --tone: var(--s-bad); }
.df-score h3 { margin: 0 0 4px; font-size: 18px; display: flex; align-items: center; gap: 10px; }
.df-score .ring { grid-row: auto; }
.df-grade { font-size: 13px; font-weight: 800; padding: 2px 10px; border-radius: 8px; background: color-mix(in srgb, var(--tone) 16%, transparent); color: var(--tone); }
.df-checks { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
.df-check { display: grid; grid-template-columns: 74px minmax(0, 1fr); gap: 12px; align-items: start; padding: 12px 14px; border-radius: 12px; border: 1px solid var(--line); background: var(--surface-2); }
.df-check .pill { justify-self: start; }
.df-check p { margin: 4px 0 0; color: var(--muted); font-size: 13px; overflow-wrap: anywhere; }
.df-check.s3 { border-color: color-mix(in srgb, var(--s-bad) 40%, var(--line)); }
.df-check.s2 { border-color: color-mix(in srgb, var(--s-warn) 40%, var(--line)); }
.df-pend { flex-wrap: wrap; }
.df-pend .btn { flex: none; }
.df-rules { height: min(60vh, 520px); font-size: 12px; }
@media (max-width: 1099px) {
  .df-choice4 { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .df-grid2 { grid-template-columns: minmax(0, 1fr); }
}
@media (max-width: 699px) {
  .df-tab { flex: 0 0 auto; padding: 9px 12px; }
  .df-hero-act { align-items: stretch; width: 100%; margin-inline-start: 0; }
  .df-seg { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); }
  .df-choice, .df-choice4 { grid-template-columns: minmax(0, 1fr); }
  .df-actions { bottom: calc(76px + env(safe-area-inset-bottom, 0px)); }
  .df-actions .btn { flex: 1 1 auto; justify-content: center; }
  .df-score { flex-direction: column; text-align: center; }
  .df-check { grid-template-columns: minmax(0, 1fr); gap: 6px; }
  .df-filter { width: 100%; }
}

/* firewall: countries, fail2ban, backup */
@media (min-width: 700px) { .df-tabs { flex-wrap: wrap; } }
.df-h4 { margin: 6px 0 2px; font-size: 13px; color: var(--muted); font-weight: 650; }
.chip small { margin-inline-start: 4px; }
.geo-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(210px, 1fr)); gap: 6px; max-height: 460px; overflow-y: auto; padding: 4px; border: 1px solid var(--line); border-radius: 14px; background: var(--surface-2); }
.geo-item { display: flex; align-items: center; gap: 9px; padding: 8px 10px; border-radius: 10px; cursor: pointer; border: 1px solid transparent; font-size: 13.5px; min-width: 0; }
.geo-item:hover { background: var(--surface); }
.geo-item.on { background: color-mix(in srgb, var(--s-bad) 10%, var(--surface)); border-color: color-mix(in srgb, var(--s-bad) 35%, var(--line)); }
.geo-item input { accent-color: var(--s-bad); width: 16px; height: 16px; flex: none; }
.geo-item span:not(.geo-flag) { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.geo-item code { font-size: 11px; color: var(--faint); }
.geo-flag { font-size: 18px; line-height: 1; }
.f2b-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(290px, 1fr)); gap: 14px; }
.f2b-jail { display: grid; gap: 10px; align-content: start; padding: 16px 18px; border-radius: 16px; border: 1px solid var(--line); background: var(--surface-2); transition: border-color .2s, box-shadow .2s; }
.f2b-jail.on { border-color: color-mix(in srgb, var(--accent) 35%, var(--line)); box-shadow: 0 0 0 1px color-mix(in srgb, var(--accent) 12%, transparent) inset; }
.f2b-jail header { display: flex; align-items: center; gap: 12px; }
.f2b-ic { width: 40px; height: 40px; border-radius: 12px; display: grid; place-items: center; flex: none; background: var(--surface); border: 1px solid var(--line); color: var(--muted); }
.f2b-jail.on .f2b-ic { color: var(--accent); background: var(--accent-soft); border-color: color-mix(in srgb, var(--accent) 30%, transparent); }
.f2b-name { flex: 1; min-width: 0; display: grid; }
.f2b-name b { font-size: 15px; }
.f2b-name small { color: var(--faint); font-size: 12px; text-align: start; }
.f2b-desc { margin: 0; color: var(--muted); font-size: 13px; line-height: 1.6; }
.f2b-stats { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px; }
.f2b-stats > div { padding: 8px 10px; border-radius: 10px; background: var(--surface); border: 1px solid var(--line); display: grid; gap: 2px; }
.f2b-stats b { font-size: 18px; font-weight: 800; }
.f2b-stats span { font-size: 11.5px; color: var(--muted); }
.f2b-stats .hot b { color: var(--s-bad); }
.f2b-rule { margin: 0; display: flex; gap: 8px; align-items: center; font-size: 13px; }
.f2b-rule .ico { width: 15px; height: 15px; color: var(--faint); flex: none; }
.f2b-src { margin: 0; font-size: 12px; overflow-wrap: anywhere; }
.f2b-jail footer { display: flex; gap: 8px; flex-wrap: wrap; }
.df-joblog { height: auto; max-height: 260px; font-size: 12px; white-space: pre-wrap; margin: 0; }
.df-logbox summary { cursor: pointer; display: flex; align-items: center; gap: 10px; flex-wrap: wrap; padding: 4px 0; }
.df-logbox summary b { display: inline-flex; align-items: center; gap: 8px; }
.df-logbox summary .ico { width: 17px; height: 17px; }
label.btn input[type="file"] { display: none; }
@media (max-width: 699px) {
  .geo-grid { grid-template-columns: minmax(0, 1fr); max-height: 380px; }
  .f2b-grid { grid-template-columns: minmax(0, 1fr); }
}

/* firewall: full control, panel security */
.field[hidden] { display: none; }
.df-code { width: 100%; min-height: 120px; padding: 12px 14px; border-radius: 12px; border: 1px solid var(--line); background: var(--surface-2); color: var(--ink);
  font: 12.5px/1.6 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; resize: vertical; tab-size: 4; }
.df-code:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 0 3px var(--accent-soft); }
.df-adv { margin-top: 6px; }
.df-adv > summary { cursor: pointer; font-weight: 650; color: var(--muted); padding: 6px 0; }
.f2b-jail .f2b-manage { border-top: 1px dashed var(--line); padding-top: 10px; }
.sec-key { font: 600 18px/1.4 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; letter-spacing: .08em; padding: 12px 14px; border-radius: 12px;
  background: var(--surface-2); border: 1px solid var(--line); overflow-wrap: anywhere; user-select: all; }

/* theme switch: colours change in one frame, nothing animates between the two themes */
.no-anim, .no-anim *, .no-anim *::before, .no-anim *::after { transition: none !important; }

/* firewall rules */
.fw-tpls { flex-wrap: wrap; }
.fw-rules { list-style: none; margin: 0; padding: 0; display: grid; gap: 10px; }
.fw-rule { display: grid; grid-template-columns: auto minmax(0, 1fr) auto; gap: 14px; align-items: center; padding: 14px 16px; border-radius: 14px; border: 1px solid var(--line); background: var(--surface-2); }
.fw-rule.off { opacity: .62; }
.fw-n { width: 30px; height: 30px; border-radius: 9px; display: grid; place-items: center; background: var(--surface); border: 1px solid var(--line); font-weight: 800; font-size: 13px; color: var(--muted); }
.fw-main { min-width: 0; display: grid; gap: 4px; }
.fw-top { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.fw-top b { font-size: 15px; }
.fw-sum { margin: 0; color: var(--muted); font-size: 13px; overflow-wrap: anywhere; }
.fw-act { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; justify-content: flex-end; }
.fw-act .btn:disabled { opacity: .35; }
.fw-h { margin: 18px 0 8px; font-size: 13px; letter-spacing: .02em; color: var(--muted); text-transform: uppercase; }
.fw-cond { padding: 12px 14px; border-radius: 12px; border: 1px solid var(--line); background: var(--surface-2); margin-bottom: 10px; }
.fw-cond .field { margin-bottom: 8px; }
.fw-cc[hidden], .fw-ips[hidden], .fw-limit[hidden], .fw-custom[hidden] { display: none; }
.fw-cc .chips { margin-bottom: 8px; }
.fw-cc .df-filter { width: 100%; margin-bottom: 8px; }
.fw-cc-list { max-height: 240px; }
.fw-cc-count { align-self: end; }
.fw-actions { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 8px; }
.fw-actopt { position: relative; display: block; cursor: pointer; }
.fw-actopt input { position: absolute; opacity: 0; inset: 0; cursor: pointer; }
.fw-actopt > span { display: grid; gap: 4px; height: 100%; padding: 12px; border-radius: 12px; border: 1px solid var(--line); background: var(--surface-2); --tone: var(--muted); }
.fw-actopt.allow > span { --tone: var(--s-good); }
.fw-actopt.block > span { --tone: var(--s-bad); }
.fw-actopt.limit > span { --tone: var(--s-warn); }
.fw-actopt b { color: var(--tone); font-size: 14px; }
.fw-actopt small { color: var(--muted); font-size: 12px; line-height: 1.5; }
.fw-actopt input:checked + span { border-color: var(--tone); background: color-mix(in srgb, var(--tone) 9%, var(--surface-2)); box-shadow: 0 0 0 3px color-mix(in srgb, var(--tone) 16%, transparent); }
.fw-actopt input:focus-visible + span { outline: 2px solid var(--accent); outline-offset: 2px; }
.fw-limit { margin-top: 12px; padding: 12px 14px; border-radius: 12px; border: 1px dashed color-mix(in srgb, var(--s-warn) 45%, var(--line)); }
.fw-lbl { display: block; font-size: 13px; font-weight: 650; margin-bottom: 8px; }
.fw-sensrow { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 6px; margin-bottom: 12px; }
.fw-sens { position: relative; cursor: pointer; }
.fw-sens input { position: absolute; opacity: 0; inset: 0; cursor: pointer; }
.fw-sens span { display: grid; gap: 2px; text-align: center; padding: 8px 4px; border-radius: 10px; border: 1px solid var(--line); background: var(--surface-2); font-size: 13px; font-weight: 650; }
.fw-sens small { color: var(--faint); font-weight: 500; font-size: 11px; }
.fw-sens input:checked + span { border-color: var(--s-warn); color: var(--ink); background: color-mix(in srgb, var(--s-warn) 12%, var(--surface-2)); }
.fw-sens input:focus-visible + span { outline: 2px solid var(--accent); outline-offset: 2px; }
.fw-preview { margin: 14px 0 0; padding: 10px 12px; border-radius: 10px; background: var(--accent-soft); color: var(--ink); font-size: 13px; }
.fw-preview:empty { display: none; }
@media (max-width: 699px) {
  .fw-rule { grid-template-columns: auto minmax(0, 1fr); }
  .fw-act { grid-column: 1 / -1; justify-content: space-between; }
  .fw-actions { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .fw-sensrow { grid-template-columns: repeat(3, minmax(0, 1fr)); }
}

/* address tester, threat lists, rule schedules */
.tt-verdict { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; margin-top: 14px; padding: 12px 14px; border-radius: 12px; border: 1px solid var(--line); background: var(--surface); }
.tt-verdict.ok { border-color: color-mix(in srgb, var(--s-good) 40%, var(--line)); }
.tt-verdict.bad { border-color: color-mix(in srgb, var(--s-bad) 45%, var(--line)); }
.tt-verdict.warn { border-color: color-mix(in srgb, var(--s-warn) 45%, var(--line)); }
.tt-steps { list-style: none; margin: 10px 0 0; padding: 0; display: grid; gap: 6px; counter-reset: s; }
.tt-steps li { display: flex; align-items: flex-start; gap: 10px; font-size: 13px; padding: 6px 2px; border-bottom: 1px dashed var(--line); }
.tt-steps li:last-child { border-bottom: 0; }
.tt-steps li .pill { flex: none; }
.th-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 10px; }
.th-feed { display: flex; flex-direction: column; gap: 8px; padding: 14px; border-radius: 14px; border: 1px solid var(--line); background: var(--surface-2); min-width: 0; }
.th-feed.on { border-color: color-mix(in srgb, var(--accent) 40%, var(--line)); }
.th-feed.on.watch { border-color: color-mix(in srgb, var(--s-warn) 45%, var(--line)); }
.th-top { display: flex; gap: 12px; align-items: flex-start; cursor: pointer; }
.th-body { display: grid; gap: 5px; min-width: 0; }
.th-tags { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
.th-feed > small { font-size: 12px; color: var(--muted); line-height: 1.6; overflow-wrap: anywhere; }
.th-feed > small.th-desc { color: var(--ink); opacity: .85; }
.th-err { display: flex; gap: 6px; align-items: flex-start; color: var(--s-bad) !important; }
.th-err .ico { flex: none; width: 14px; height: 14px; margin-top: 2px; }
.th-foot { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-top: auto; padding-top: 4px; }
.df-seg.th-mode { display: inline-flex; padding: 3px; }
.df-seg.th-mode button { padding: 5px 11px; font-size: 12.5px; }
.df-seg.th-mode button.on[data-mode="log"] { color: var(--s-warn); }
.th-btns { display: inline-flex; gap: 4px; margin-inline-start: auto; }
.th-stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; margin-bottom: 12px; }
.th-stat { display: grid; gap: 4px; padding: 12px 14px; border-radius: 12px; border: 1px solid var(--line); background: var(--surface-2); min-width: 0; }
.th-stat > span { font-size: 12px; }
.th-stat b { font-size: 20px; font-variant-numeric: tabular-nums; overflow-wrap: anywhere; }
.th-stat small { font-size: 11px; }
.th-two { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 12px; align-items: start; }
.th-two .subcard h4 { display: flex; gap: 8px; align-items: center; margin: 0 0 10px; }
.th-body small { font-size: 12px; color: var(--muted); line-height: 1.5; overflow-wrap: anywhere; }
.fw-sched[hidden] { display: none; }
.fw-sched { margin-top: 10px; }
.fw-days { display: grid; grid-template-columns: repeat(7, minmax(0, 1fr)); gap: 6px; margin-bottom: 10px; }
.fw-actopt[hidden] { display: none; }
@media (max-width: 699px) {
  .fw-days { grid-template-columns: repeat(4, minmax(0, 1fr)); }
  .th-grid, .th-two { grid-template-columns: minmax(0, 1fr); }
  .th-stats { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}

/* live update pace picker, inside the "Live" pill */
.live select { appearance: none; -webkit-appearance: none; flex: none; font: inherit; font-weight: 650; color: var(--ink); background: var(--surface-2); border: 1px solid var(--line); border-radius: 999px; padding: 2px 10px; margin-inline-start: -3px; cursor: pointer; line-height: 1.5; }
.live select:hover { border-color: var(--line-2); }
.live select:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.live select[hidden] { display: none; }
@media (max-width: 699px) {   /* phones: only the dot shows; tapping it opens the pace picker laid invisibly over it */
  .live { position: relative; }
  .live select { position: absolute; inset: 0; width: 100%; height: 100%; margin: 0; opacity: 0; font-size: 16px; }
}

/* bans: when and how long */
.df-when, .df-left { display: grid; gap: 2px; min-width: 0; }
.df-when small, .df-left small { font-size: 11.5px; }
.df-left i { display: block; height: 4px; border-radius: 4px; background: var(--line); position: relative; overflow: hidden; margin-top: 3px; min-width: 70px; }
.df-left i::after { content: ""; position: absolute; inset: 0 auto 0 0; width: var(--w); background: var(--s-warn); border-radius: 4px; }
[dir="rtl"] .df-left i::after { inset: 0 0 0 auto; }
.df-rowbtns { display: inline-flex; gap: 6px; align-items: center; }
.rule-code { font-size: 11px; color: var(--faint); background: none; padding: 0; margin-inline-start: 4px; }

/* login: language / theme switches and show-password */
.login-tools { position: fixed; top: max(16px, env(safe-area-inset-top, 0px)); inset-inline-end: 16px; display: flex; gap: 8px; z-index: 10; }
.pw-wrap { position: relative; }
.pw-wrap input { padding-inline-end: 48px; }
.pw-toggle { position: absolute; inset-inline-end: 4px; top: 50%; transform: translateY(-50%); width: 40px; height: 40px; display: grid; place-items: center;
  border: 0; border-radius: 10px; background: none; color: var(--muted); cursor: pointer; }
.pw-toggle:hover { color: var(--ink); background: var(--surface-2); }
.pw-toggle:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
.pw-toggle .ico { width: 18px; height: 18px; }

/* touch screens: buttons at least 40px so they are easy to hit */
@media (pointer: coarse) {
  .btn.small { height: 40px; }
  .btn.small.icon { width: 40px; }
  .df-seg button { padding: 9px 14px; }
}
__MONITORING_EOF__
  write_file panel/static/fonts.css 644 <<'__MONITORING_EOF__'
/* Vazirmatn (SIL Open Font License 1.1) - Latin + Persian/Arabic subset, embedded so the panel needs no external font host. */
@font-face {
  font-family: "Vazirmatn";
  font-style: normal;
  font-weight: 100 900;
  font-display: swap;
  src: url(data:font/woff2;base64,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) format("woff2");
}
__MONITORING_EOF__
  write_file panel/static/favicon.svg 644 <<'__MONITORING_EOF__'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="8" fill="#0e1520"/><path d="M16 5l9 3.5v7c0 5.4-3.7 9.2-9 11.5-5.3-2.3-9-6.1-9-11.5v-7L16 5z" fill="none" stroke="#2ee6a6" stroke-width="2" stroke-linejoin="round"/><path d="M10.5 16h3l2-3.5 2.5 7 2-3.5h1.5" fill="none" stroke="#2ee6a6" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>
__MONITORING_EOF__
}

# ---------------------------------------------------------------- docker
# ---------------------------------------------------------------- downloads with fallbacks
# Several sources for everything that is fetched from the internet: the first one that works is used,
# and when one fails (blocked, 403, timeout, wrong checksum) the next is tried. This matters on
# servers where Docker's or GitHub's own sites are blocked (Iran: get.docker.com and Docker Hub
# answer 403). Each list can be replaced with an env var of the same name (comma-separated).
DOCKER_SCRIPT_URLS=${DOCKER_SCRIPT_URLS:-"https://get.docker.com,https://raw.githubusercontent.com/docker/docker-install/master/install.sh,https://cdn.jsdelivr.net/gh/docker/docker-install@master/install.sh,https://ghfast.top/https://raw.githubusercontent.com/docker/docker-install/master/install.sh"}
DOCKER_CE_MIRRORS=${DOCKER_CE_MIRRORS:-"https://download.docker.com,https://mirror.arvancloud.ir/docker-ce,https://mirrors.aliyun.com/docker-ce,https://mirrors.tuna.tsinghua.edu.cn/docker-ce"}
GITHUB_PROXIES=${GITHUB_PROXIES:-",https://ghfast.top/,https://gh-proxy.com/,https://ghproxy.net/"}
REGISTRY_MIRRORS=${DOCKER_MIRROR:-${REGISTRY_MIRRORS:-"https://docker.arvancloud.ir,https://docker.iranserver.com,https://registry.docker.ir,https://hub.hamdocker.ir,https://docker.haiocloud.com,https://focker.ir,https://mirror.gcr.io"}}
ALPINE_MIRRORS=${ALPINE_MIRRORS:-"https://dl-cdn.alpinelinux.org/alpine,https://mirror.arvancloud.ir/alpine,https://dl-2.alpinelinux.org/alpine,https://dl-4.alpinelinux.org/alpine,https://mirrors.aliyun.com/alpine"}
COMPOSE_VERSION=v2.29.7
COMPOSE_SHA256_x86_64=383ce6698cd5d5bbf958d2c8489ed75094e34a77d340404d9f32c4ae9e12baf0
COMPOSE_SHA256_aarch64=6e9fbd5daa20dca5d7d89145081ae8155d68ef2928b497d9f85b54fe0f9dbb2c

# one item per line, ending with a newline (without it `read` would drop the last item)
split_list() { printf '%s\n' "$1" | tr ',' '\n' | sed 's/[[:space:]]//g'; }

# HTTP status of a URL ("000" when it cannot be reached at all).
http_code() { curl -s -o /dev/null --connect-timeout 8 -m 15 -w '%{http_code}' "$1" 2>/dev/null || true; }

# fetch_first <file> <sha256 or -> <url>...  Downloads from the first URL that works. With a checksum,
# a download that does not match counts as failed and the next URL is tried.
fetch_first() {
  local out=$1 sum=$2 u; shift 2
  for u in "$@"; do
    [ -n "$u" ] || continue
    if curl -fsSL --connect-timeout 10 -m 600 "$u" -o "$out.part" 2>/dev/null && [ -s "$out.part" ]; then
      if [ "$sum" = - ] || printf '%s  %s\n' "$sum" "$out.part" | sha256sum -c - >/dev/null 2>&1; then
        mv "$out.part" "$out"
        log "  downloaded from $u"
        return 0
      fi
      warn "  $u: the file does not match its checksum - skipped"
    else
      warn "  $u: not reachable - trying the next source"
    fi
  done
  rm -f "$out.part"
  return 1
}

# Docker with Docker's install script: the script and the packages each from the first source that works.
install_docker_script() {
  local script=/tmp/get-docker.$$.sh m urls=()
  while read -r m; do urls+=("$m"); done < <(split_list "$DOCKER_SCRIPT_URLS")
  fetch_first "$script" - "${urls[@]}" || return 1
  while read -r m; do
    [ -n "$m" ] || continue
    case "$(http_code "${m%/}/linux/")" in 200|301|302) ;; *) warn "  Docker packages: $m not reachable - trying the next mirror"; continue ;; esac
    log "  installing Docker packages from $m"
    if DOWNLOAD_URL=${m%/} sh "$script"; then rm -f "$script"; return 0; fi
    warn "  installing from $m failed - trying the next mirror"
  done < <(split_list "$DOCKER_CE_MIRRORS")
  rm -f "$script"
  return 1
}

# Docker from the distribution's own packages: they come from the distro mirrors, which stay
# reachable where download.docker.com is blocked.
install_docker_distro() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || true
    apt-get install -y -qq docker.io || return 1
    # Compose v2 is packaged as docker-compose-v2 (Ubuntu) or docker-compose-plugin (Docker's repo, mirrors)
    apt-get install -y -qq docker-compose-v2 >/dev/null 2>&1 || apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q moby-engine >/dev/null 2>&1 || dnf install -y -q docker >/dev/null 2>&1 || return 1
    dnf install -y -q docker-compose-plugin >/dev/null 2>&1 || dnf install -y -q docker-compose >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q docker >/dev/null 2>&1 || return 1
  else
    return 1
  fi
}

# The Compose v2 plugin binary from its GitHub release, directly or through a GitHub proxy; every
# copy is checked against the release's SHA-256, so a proxy cannot hand out a modified binary.
install_compose_plugin() {
  local arch sum dir=/usr/local/lib/docker/cli-plugins p urls=()
  case "$(uname -m)" in
    x86_64|amd64) arch=x86_64; sum=$COMPOSE_SHA256_x86_64 ;;
    aarch64|arm64) arch=aarch64; sum=$COMPOSE_SHA256_aarch64 ;;
    *) return 1 ;;
  esac
  while IFS= read -r p; do
    urls+=("${p}https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-linux-$arch")
  done < <(printf '%s\n' "$GITHUB_PROXIES" | tr ',' '\n')
  mkdir -p "$dir"
  fetch_first "$dir/docker-compose" "$sum" "${urls[@]}" || return 1
  chmod 755 "$dir/docker-compose"
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    command -v curl >/dev/null 2>&1 || die "curl is required to install Docker."
    log "Docker not found - installing it (trying each source until one works)"
    if install_docker_script; then :
    else
      warn "Docker's install script did not work from any source - installing Docker from the distribution's packages"
      install_docker_distro || die "Could not install Docker from any source. Install it by hand (e.g. apt-get install docker.io docker-compose-v2) and run this installer again."
    fi
  fi
  command -v systemctl >/dev/null 2>&1 && systemctl enable --now docker >/dev/null 2>&1 || true
  if ! docker compose version >/dev/null 2>&1; then
    log "Docker Compose plugin missing - installing it"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get install -y -qq docker-compose-v2 >/dev/null 2>&1 || apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 || true
    fi
    docker compose version >/dev/null 2>&1 || install_compose_plugin || true
    docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is missing and could not be downloaded from any source. Install 'docker-compose-v2' or 'docker-compose-plugin' and re-run."
  fi
  docker info >/dev/null 2>&1 || die "Docker daemon is not running."
  ensure_registry
}

# Registry mirrors that answer right now (an anonymous /v2/ request gets 200 or 401 from a live one).
live_mirrors() {
  local m out=""
  while read -r m; do
    [ -n "$m" ] || continue
    case "$(http_code "${m%/}/v2/")" in
      200|401) out="$out${out:+,}${m%/}" ;;
      *) warn "  registry mirror ${m%/} not reachable - skipped" >&2 ;;
    esac
  done < <(split_list "$REGISTRY_MIRRORS")
  printf '%s' "$out"
}

# Writes "registry-mirrors" into /etc/docker/daemon.json (merged with what is there) and restarts Docker.
set_mirrors() {
  mkdir -p /etc/docker
  if command -v python3 >/dev/null 2>&1; then
    MIRRORS="$1" python3 - <<'PY'
import json, os
path = "/etc/docker/daemon.json"
try:
    with open(path) as f:
        cfg = json.load(f)
except (OSError, ValueError):
    cfg = {}
cfg["registry-mirrors"] = [m for m in os.environ["MIRRORS"].split(",") if m]
with open(path + ".tmp", "w") as f:
    json.dump(cfg, f, indent=2)
os.replace(path + ".tmp", path)
PY
  elif [ ! -s /etc/docker/daemon.json ] || grep -q '^{[[:space:]]*"registry-mirrors"' /etc/docker/daemon.json; then
    printf '{\n  "registry-mirrors": ["%s"]\n}\n' "$(printf '%s' "$1" | sed 's/,/", "/g')" > /etc/docker/daemon.json
  else
    die "Add \"registry-mirrors\": [\"${1%%,*}\"] to /etc/docker/daemon.json by hand (python3 is missing to merge it) and run again."
  fi
  systemctl restart docker 2>/dev/null || service docker restart 2>/dev/null || true
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do docker info >/dev/null 2>&1 && return 0; sleep 2; done
  die "Docker did not come back after setting the registry mirrors; check /etc/docker/daemon.json."
}

# Docker Hub answers 401 to an anonymous /v2/ request when it is reachable; 403 (blocked, e.g. in
# Iran) or no answer means images have to come through mirrors. Every mirror that answers is set,
# in order: Docker itself moves on to the next one when a mirror fails during a pull.
ensure_registry() {
  local code mirrors
  code=$(http_code https://registry-1.docker.io/v2/)
  if [ "$code" = 401 ] || [ "$code" = 200 ]; then [ -z "${DOCKER_MIRROR:-}" ] && return 0; fi
  [ -n "${DOCKER_MIRROR:-}" ] || warn "Docker Hub is not reachable from this server (HTTP $code) - looking for registry mirrors"
  mirrors=$(live_mirrors)
  if [ -z "$mirrors" ]; then
    docker info 2>/dev/null | grep -q 'Registry Mirrors' && { warn "No mirror from the list answered; keeping the mirrors already set up."; return 0; }
    die "Docker Hub is blocked and no registry mirror answered. Set DOCKER_MIRROR=https://your.mirror and run again."
  fi
  log "Using registry mirror(s), in this order: $mirrors"
  set_mirrors "$mirrors"
}

# One pull of every image. Newer Compose has --ignore-buildable (skips the firewall image, which is
# built here); an older or a future one without it gets --ignore-pull-failures, then a plain pull.
pull_once() {
  compose pull --quiet --ignore-buildable < /dev/null 2>/dev/null && return 0
  compose pull --help 2>/dev/null | grep -q -- --ignore-buildable && return 1    # the flag exists: a real failure
  compose pull --quiet --ignore-pull-failures < /dev/null && return 0
  compose pull < /dev/null
}

# Pulls the images. When that fails with the mirrors all set, each mirror is tried on its own.
pull_images() {
  pull_once && return 0
  local m mirrors
  mirrors=$(live_mirrors)
  [ -n "$mirrors" ] || return 1
  for m in $(printf '%s' "$mirrors" | tr ',' ' '); do
    warn "Download failed - trying the registry mirror $m on its own"
    set_mirrors "$m"
    if pull_once; then
      set_mirrors "$mirrors"     # keep them all for later pulls
      return 0
    fi
  done
  set_mirrors "$mirrors"
  return 1
}

# The firewall image adds nftables with apk: use the first Alpine mirror that answers.
choose_alpine_mirror() {
  local m c
  [ -n "${ALPINE_MIRROR:-}" ] && { set_env_key ALPINE_MIRROR "$ALPINE_MIRROR"; return 0; }
  while read -r m; do
    [ -n "$m" ] || continue
    c=$(http_code "${m%/}/latest-stable/main/x86_64/APKINDEX.tar.gz")
    if [ "$c" = 200 ]; then
      case "$m" in https://dl-cdn.alpinelinux.org/*) set_env_key ALPINE_MIRROR "" ;;
        *) log "Alpine's CDN is not reachable; building the firewall image with the mirror $m"; set_env_key ALPINE_MIRROR "${m%/}" ;; esac
      return 0
    fi
    warn "  Alpine mirror ${m%/} not reachable - trying the next one"
  done < <(split_list "$ALPINE_MIRRORS")
  warn "No Alpine package mirror answered; building the firewall image may fail (set ALPINE_MIRROR=https://... and run again)."
}

# True if TCP port $1 is taken: something listens on it, a socket holds it without listening
# (Docker does that for published ports when its userland proxy is off), or another container
# publishes it. Reads /proc first, so no extra tools are needed.
port_in_use() {
  local hex f; hex=$(printf '%04X' "$1")
  if for f in /proc/net/tcp /proc/net/tcp6; do if [ -r "$f" ]; then cat "$f"; fi; done |
    awk -v h=":$hex" 'substr($2, length($2) - 4) == h && ($4 == "0A" || ($4 == "07" && $3 ~ /^0+:0000$/)) { found = 1 } END { exit !found }'
  then return 0; fi
  if command -v ss >/dev/null 2>&1 && ss -Htan "sport = :$1" 2>/dev/null | grep -q .; then return 0; fi
  command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null |
    grep -v '^server-monitoring-panel-' | grep -Eq ":$1->"
}

# compose up; if Docker still finds the panel's port taken (something grabbed it after the check,
# or the check could not see it), move the panel to the next free port and try again.
start_stack() {
  local out tries=0 rc
  out=$(mktemp)
  while :; do
    compose up -d --remove-orphans < /dev/null 2>&1 | tee "$out"
    rc=${PIPESTATUS[0]}
    [ "$rc" = 0 ] && { rm -f "$out"; return 0; }
    if grep -q "bind host port.*:${PANEL_PORT}/tcp: address already in use\|port is already allocated" "$out" && [ "$tries" -lt 20 ]; then
      tries=$((tries + 1))
      RESERVED+="$PANEL_PORT "
      local old=$PANEL_PORT p=$((PANEL_PORT + 1))
      while port_in_use "$p" || [[ $RESERVED == *" $p "* ]]; do p=$((p + 1)); done
      PANEL_PORT=$p
      set_env_key PANEL_PORT "$p"
      warn "Port $old is already taken by another program - starting the panel on port $p instead."
      continue
    fi
    rm -f "$out"
    return "$rc"
  done
}

RESERVED=" "
# choose_port VAR service container_port default
# Picks a free host port for a service and saves it in .env. A port held by this stack's own
# running container is fine (compose keeps it); a port held by anything else is skipped.
choose_port() {
  local var=$1 svc=$2 cport=$3 want p cur=""
  set -a; . "$INSTALL_DIR/.env"; set +a
  want=${!var:-$4}
  if command -v docker >/dev/null 2>&1; then
    cur=$(compose port "$svc" "$cport" 2>/dev/null | head -1 | sed 's/.*://' || true)
  fi
  p=$want
  if [ "$cur" != "$want" ]; then
    while port_in_use "$p" || [[ $RESERVED == *" $p "* ]]; do p=$((p + 1)); done
  fi
  RESERVED+="$p "
  if [ "$p" != "$want" ]; then warn "Port $want is already in use by another program - using $p for $svc instead."; fi
  if grep -q "^$var=" "$INSTALL_DIR/.env"; then sed -i "s/^$var=.*/$var='$p'/" "$INSTALL_DIR/.env"
  else echo "$var='$p'" >> "$INSTALL_DIR/.env"; fi
}

# Older installs kept the login under GRAFANA_* names and also ran Grafana, which is gone now.
# Copy the values to the PANEL_* names, move an old default panel port, drop the stale keys.
migrate_env() {
  local env="$INSTALL_DIR/.env"
  set -a; . "$env"; set +a
  add_key() { grep -q "^$1=" "$env" || echo "$1='$2'" >> "$env"; }
  if ! grep -q '^PANEL_PASSWORD=' "$env"; then
    [ -n "${GRAFANA_ADMIN_PASSWORD:-}" ] || die "No password found in $env - set PANEL_PASSWORD there and re-run."
    add_key PANEL_PASSWORD "$GRAFANA_ADMIN_PASSWORD"
  fi
  add_key PANEL_USER "${GRAFANA_ADMIN_USER:-admin}"
  add_key PANEL_BIND "${GRAFANA_BIND:-0.0.0.0}"
  if grep -q "^PANEL_PORT='8080'" "$env"; then sed -i "s/^PANEL_PORT=.*/PANEL_PORT='3000'/" "$env"; fi
  sed -i '/^GRAFANA_/d' "$env"
}

# Grafana was removed from the stack: drop its old container so its port is released.
remove_legacy_grafana() {
  local ids
  ids=$(docker ps -aq --filter "label=com.docker.compose.project=server-monitoring" --filter "label=com.docker.compose.service=grafana" 2>/dev/null || true)
  [ -z "$ids" ] && return 0
  log "Removing the old Grafana container (the panel replaces it)"
  docker rm -f $ids >/dev/null
}

# set_env_key KEY VALUE - add or update a single-quoted value in .env
set_env_key() {
  if grep -q "^$1=" "$INSTALL_DIR/.env"; then sed -i "s|^$1=.*|$1='$2'|" "$INSTALL_DIR/.env"
  else echo "$1='$2'" >> "$INSTALL_DIR/.env"; fi
}

# ---------------------------------------------------------------- self-update
# The newest installer from GitHub, or a copy of it (jsDelivr, GitHub proxies) when GitHub is blocked.
INSTALLER_URLS=${INSTALLER_URLS:-"https://raw.githubusercontent.com/AmiRAliw24/Toofan-Monitor/HEAD/install.sh,https://ghfast.top/https://raw.githubusercontent.com/AmiRAliw24/Toofan-Monitor/HEAD/install.sh,https://gh-proxy.com/https://raw.githubusercontent.com/AmiRAliw24/Toofan-Monitor/HEAD/install.sh"}
if [ "$ACTION" = update ]; then
  new=$(mktemp)
  urls=()
  while read -r u; do [ -n "$u" ] && urls+=("$u"); done < <(split_list "$INSTALLER_URLS")
  log "Downloading the newest installer"
  fetch_first "$new" - "${urls[@]}" || die "Could not download the installer from any source."
  # a broken or truncated download (or an error page) must never run
  bash -n "$new" 2>/dev/null && grep -q '^extract_files()' "$new" || die "The downloaded installer is not valid; nothing was changed."
  log "Running the new installer (your settings in $INSTALL_DIR/.env are kept)"
  exec bash "$new" -y
fi

# ---------------------------------------------------------------- main
FRESH=1; [ -f "$INSTALL_DIR/.env" ] && FRESH=0

if [ "$FRESH" = 1 ]; then
  log "New installation in $INSTALL_DIR"
  # Older docs used GRAFANA_* names for these; accept them as fallbacks.
  PANEL_USER=${PANEL_USER:-${GRAFANA_ADMIN_USER:-}}
  PANEL_PASSWORD=${PANEL_PASSWORD:-${GRAFANA_ADMIN_PASSWORD:-}}
  PANEL_BIND=${PANEL_BIND:-${GRAFANA_BIND:-}}
  ask PANEL_USER "Panel username" admin
  ask PANEL_PASSWORD "Panel password (empty = generate random)" ""
  if [ -z "$PANEL_PASSWORD" ]; then
    PANEL_PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)
    GENERATED_PW=1
  fi
  ask PANEL_BIND "Panel listen address (0.0.0.0 = reachable from any network, 127.0.0.1 = local only)" 0.0.0.0
  ask TELEGRAM_BOT_TOKEN "Telegram bot token for alerts (empty = skip)" ""
  TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}
  [ -n "$TELEGRAM_BOT_TOKEN" ] && ask TELEGRAM_CHAT_ID "Telegram chat id" ""
  ask SITES "Websites to monitor, comma-separated (empty = none)" ""
else
  log "Existing installation found - updating files, keeping your .env and targets"
fi

mkdir -p "$INSTALL_DIR"
extract_files

if [ "$FRESH" = 1 ]; then
  # Values are single-quoted: .env is read by both bash and Docker Compose, and single quotes
  # keep characters like $ and spaces literal in both.
  for v in PANEL_USER PANEL_PASSWORD PANEL_BIND PANEL_PORT TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID SITES; do
    case "${!v:-}" in *\'*|*$'\n'*) die "$v must not contain single quotes or newlines." ;; esac
  done
  [[ ${PANEL_PORT:-3000} =~ ^[0-9]{2,5}$ ]] || die "PANEL_PORT must be a number."
  umask 077
  cat > "$INSTALL_DIR/.env" <<ENV
PANEL_USER='$PANEL_USER'
PANEL_PASSWORD='$PANEL_PASSWORD'
PANEL_BIND='$PANEL_BIND'
PANEL_PORT='${PANEL_PORT:-3000}'
PROMETHEUS_RETENTION='${PROMETHEUS_RETENTION:-30d}'
TELEGRAM_BOT_TOKEN='${TELEGRAM_BOT_TOKEN:-}'
TELEGRAM_CHAT_ID='${TELEGRAM_CHAT_ID:-}'
ENV
  umask 022
  mkdir -p "$INSTALL_DIR/prometheus/targets"
  if [ -n "$SITES" ]; then
    first=1
    {
      printf '['
      IFS=',' read -ra urls <<< "$SITES"
      for u in "${urls[@]}"; do
        u=${u//[[:space:]]/}; [ -n "$u" ] || continue
        [[ $u =~ ^https?://[^[:space:]\"\'\`\<\>\\]+$ ]] || die "Not a valid website address: $u (use https://example.com)"
        [ "$first" = 1 ] || printf ','
        first=0
        printf '{"targets": ["%s"], "labels": {}}' "$u"
      done
      printf ']\n'
    } > "$INSTALL_DIR/prometheus/targets/http.json"
  fi
fi

if [ "$FRESH" = 0 ]; then migrate_env; fi
"$INSTALL_DIR/scripts/render-config.sh"

if [ "$NO_START" = 1 ]; then
  choose_port PANEL_PORT panel 8080 3000
  log "Files written to $INSTALL_DIR (--no-start given, containers not started)."
  exit 0
fi

ensure_docker
# The panel needs this group to use the Docker socket (container management).
docker_gid=$(stat -c %g /var/run/docker.sock 2>/dev/null || true)
[ -n "$docker_gid" ] && set_env_key DOCKER_GID "$docker_gid"
log "Pulling images and starting the stack"
# The defender image is built here (it only adds nftables to python:alpine), not pulled.
pull_images || die "Could not download the images from Docker Hub or any mirror. Set DOCKER_MIRROR=https://your.mirror and run again."
choose_alpine_mirror
compose build --quiet defender < /dev/null
remove_legacy_grafana
choose_port PANEL_PORT panel 8080 3000
PANEL_PORT=$(sed -n "s/^PANEL_PORT='\{0,1\}\([0-9]*\).*/\1/p" "$INSTALL_DIR/.env" | tail -1)
start_stack || die "The containers did not start (see the error above)."
# Config files are bind-mounted, so running containers need a nudge to re-read them.
# Restart, never `compose kill -s SIGHUP`: Docker records any kill (even a harmless HUP) as a
# manual stop, and the restart policy then leaves those containers down after the next reboot.
# A restart also clears that mark on installs that were reloaded with SIGHUP before.
compose restart prometheus alertmanager blackbox < /dev/null >/dev/null 2>&1 || true
# The panel's Python code is loaded once at start, so an updated server.py needs a restart.
compose restart panel < /dev/null >/dev/null 2>&1 || true
# Same for the Defender agent; its firewall rules stay in place while it restarts.
compose restart defender < /dev/null >/dev/null 2>&1 || true

set -a; . "$INSTALL_DIR/.env"; set +a
log "Waiting for the panel to become healthy"
healthy=0
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${PANEL_PORT:-3000}/healthz" >/dev/null 2>&1; then healthy=1; break; fi
  sleep 2
done
[ "$healthy" = 1 ] || warn "The panel did not respond in 2 minutes. Check: docker compose --project-directory $INSTALL_DIR logs panel"

ip=$(hostname -I 2>/dev/null | awk '{print $1}'); ip=${ip:-<server-ip>}
echo
log "Done."
PANEL_PORT=${PANEL_PORT:-3000}
if [ "${PANEL_BIND:-0.0.0.0}" = 127.0.0.1 ]; then
  echo "  The panel is local-only. From your computer run:  ssh -L $PANEL_PORT:127.0.0.1:$PANEL_PORT root@$ip"
  echo "  then open http://localhost:$PANEL_PORT"
else
  echo "  Panel:    http://$ip:$PANEL_PORT   (open TCP port $PANEL_PORT in your firewall; put HTTPS in front for production)"
fi
echo "  Login:    $PANEL_USER / ${GENERATED_PW:+$PANEL_PASSWORD}${GENERATED_PW:-(the password you chose)}"
[ -n "${GENERATED_PW:-}" ] && echo "  (saved in $INSTALL_DIR/.env)"
if docker volume inspect server-monitoring_grafana_data >/dev/null 2>&1; then
  echo "  Old Grafana data is still on disk; remove it with: docker volume rm server-monitoring_grafana_data"
fi
echo "  Everything else - websites, ports, servers, Telegram, alert rules, Docker containers - is managed inside the panel."
echo "  Manage:   docker compose --project-directory $INSTALL_DIR ps | logs | restart"
exit 0
}

main "$@"
