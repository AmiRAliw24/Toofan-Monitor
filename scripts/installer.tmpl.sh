#!/usr/bin/env bash
# Server monitoring installer - single self-contained file.
# Installs Docker (if missing), then deploys the monitoring panel + Prometheus + Alertmanager +
# node_exporter + container stats + Blackbox exporter under /opt/server-monitoring.
#
# Usage (as root):
#   curl -fsSL https://raw.githubusercontent.com/AmiRAliw24/Toofan-Monitor/HEAD/install.sh | sudo bash          # one-liner, interactive
#   curl -fsSL https://raw.githubusercontent.com/AmiRAliw24/Toofan-Monitor/HEAD/install.sh | sudo bash -s -- -y # one-liner, no questions (uses env vars)
#   # where GitHub is blocked, fetch it from the first source that works:
#   for u in https://raw.githubusercontent.com/AmiRAliw24/Toofan-Monitor/HEAD/install.sh https://ghfast.top/https://raw.githubusercontent.com/AmiRAliw24/Toofan-Monitor/HEAD/install.sh https://gh-proxy.com/https://raw.githubusercontent.com/AmiRAliw24/Toofan-Monitor/HEAD/install.sh; do curl -fsSL -m 300 "$u" -o install.sh && bash -n install.sh && tail -1 install.sh | grep -q "^main" && break; done; sudo bash install.sh
#   bash install.sh                 # interactive; where it is already installed, opens a menu
#                                   # (update, change port / login / listen address, 2FA off, status, uninstall)
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

# remove_install keep|purge - stop and remove the stack; purge also deletes the data and the install dir.
remove_install() {
  [ -f "$INSTALL_DIR/docker-compose.yml" ] || die "No installation found in $INSTALL_DIR."
  # The Defender's firewall rules live in the kernel, not in a container: remove them too.
  if command -v nft >/dev/null 2>&1; then nft delete table inet defender 2>/dev/null || true
  else docker run --rm --network host --privileged server-monitoring-defender:1 nft delete table inet defender >/dev/null 2>&1 || true; fi
  if [ "$1" = purge ]; then
    compose down -v --remove-orphans
    rm -rf "$INSTALL_DIR"
    log "Removed containers, data volumes and $INSTALL_DIR."
  else
    compose down --remove-orphans
    log "Containers stopped and removed. Data volumes and $INSTALL_DIR are kept (use --purge to delete)."
  fi
}

if [ "$ACTION" = uninstall ] || [ "$ACTION" = purge ]; then
  if [ "$ACTION" = purge ]; then remove_install purge; else remove_install keep; fi
  exit 0
fi

# True when someone can answer questions (no -y, and a terminal is attached even under curl | bash).
interactive() { [ "$ASSUME_YES" = 0 ] && { : < /dev/tty; } 2>/dev/null; }

# prompt_port <busy port> <suggested free port> - asks for another panel port, prints the answer.
prompt_port() {
  local busy=$1 sug=$2 reply
  while :; do
    read -r -p "Port $busy is already in use on this server. Panel port to use instead [$sug]: " reply < /dev/tty || reply=""
    reply=${reply:-$sug}
    if ! [[ $reply =~ ^[0-9]{1,5}$ ]] || [ "$reply" -lt 1 ] || [ "$reply" -gt 65535 ]; then echo "  Enter a number from 1 to 65535." > /dev/tty; continue; fi
    if [ "$reply" != "$sug" ] && port_in_use "$reply"; then echo "  Port $reply is in use too." > /dev/tty; continue; fi
    echo "$reply"
    return 0
  done
}

# ---------------------------------------------------------------- embedded files
extract_files() {
@@EMBEDDED@@
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
      if interactive; then p=$(prompt_port "$old" "$p")
      else warn "Port $old is already taken by another program - starting the panel on port $p instead."; fi
      PANEL_PORT=$p
      set_env_key PANEL_PORT "$p"
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
  if [ "$p" != "$want" ]; then
    if interactive; then p=$(prompt_port "$want" "$p")
    else warn "Port $want is already in use by another program - using $p for $svc instead."; fi
  fi
  RESERVED+="$p "
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

# set_env_key KEY VALUE - add or update a single-quoted value in .env. No sed on the value, so any
# character but ' and newline is safe; `cat >` keeps the file's mode (0600).
set_env_key() {
  local f="$INSTALL_DIR/.env" tmp
  tmp=$(mktemp)
  { grep -v "^$1=" "$f" 2>/dev/null || true; printf "%s='%s'\n" "$1" "$2"; } > "$tmp"
  cat "$tmp" > "$f"
  rm -f "$tmp"
}

# ---------------------------------------------------------------- management menu
# Running the installer again where it is already installed opens this menu (interactive runs only;
# -y, --update and the other flags skip it).
env_get() { sed -n "s/^$1=//p" "$INSTALL_DIR/.env" 2>/dev/null | tail -1 | sed "s/^'\(.*\)'\$/\1/"; }
server_ip() { local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}'); echo "${ip:-<server-ip>}"; }
panel_url() {
  local port; port=$(env_get PANEL_PORT)
  if [ "$(env_get PANEL_BIND)" = 127.0.0.1 ]; then echo "http://127.0.0.1:${port:-3000}  (this server only: ssh -L ${port:-3000}:127.0.0.1:${port:-3000} root@$(server_ip))"
  else echo "http://$(server_ip):${port:-3000}"; fi
}
wait_panel() {
  local port; port=$(env_get PANEL_PORT)
  for _ in $(seq 1 45); do
    if curl -fsS "http://127.0.0.1:${port:-3000}/healthz" >/dev/null 2>&1; then log "The panel is up: $(panel_url)"; return 0; fi
    sleep 2
  done
  warn "The panel did not answer yet. See: docker compose --project-directory $INSTALL_DIR logs panel"
}
apply_env() {   # recreate the containers whose settings changed
  PANEL_PORT=$(env_get PANEL_PORT)
  if start_stack; then wait_panel; else warn "The containers did not start (see the error above)."; fi
}
bad_value() { case "$1" in *\'*|*$'\n'*) return 0 ;; esac; return 1; }

menu_port() {
  local cur new
  cur=$(env_get PANEL_PORT); cur=${cur:-3000}
  read -r -p "New panel port (now $cur, empty = keep): " new < /dev/tty || return 0
  if [ -z "$new" ] || [ "$new" = "$cur" ]; then echo "  Unchanged."; return 0; fi
  if ! [[ $new =~ ^[0-9]{1,5}$ ]] || [ "$new" -lt 1 ] || [ "$new" -gt 65535 ]; then warn "Enter a number from 1 to 65535."; return 0; fi
  if port_in_use "$new"; then warn "Port $new is already in use on this server - choose another one."; return 0; fi
  set_env_key PANEL_PORT "$new"
  log "Moving the panel to port $new (the firewall keeps the new port open)"
  apply_env
}

menu_login() {
  local u p p2 gen=0 cur
  cur=$(env_get PANEL_USER)
  read -r -p "Username [${cur:-admin}]: " u < /dev/tty || return 0
  u=${u:-${cur:-admin}}
  if bad_value "$u" || [[ $u == *[:\|]* ]] || [ ${#u} -gt 64 ]; then warn "That username is not allowed - nothing changed."; return 0; fi
  read -r -s -p "New password (empty = generate a strong one): " p < /dev/tty || return 0; echo
  if [ -z "$p" ]; then
    p=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20); gen=1
  else
    read -r -s -p "Repeat the password: " p2 < /dev/tty || return 0; echo
    if [ "$p" != "$p2" ]; then warn "The passwords differ - nothing changed."; return 0; fi
    if [ ${#p} -lt 8 ] || bad_value "$p"; then warn "Use at least 8 characters and no single quote - nothing changed."; return 0; fi
  fi
  set_env_key PANEL_USER "$u"
  set_env_key PANEL_PASSWORD "$p"
  # a password changed inside the panel is kept there and would win over .env
  rm -f "$INSTALL_DIR/data/panel/auth.json"
  log "Login changed; other sessions are signed out"
  apply_env
  echo "  Login:    $u / $([ "$gen" = 1 ] && echo "$p  (saved in $INSTALL_DIR/.env)" || echo "(the password you typed)")"
}

menu_bind() {
  local c
  echo "  1) Any network (0.0.0.0)"
  echo "  2) This server only (127.0.0.1, open it through an SSH tunnel)"
  read -r -p "Choose [1-2, empty = keep $(env_get PANEL_BIND)]: " c < /dev/tty || return 0
  case "$c" in
    1) set_env_key PANEL_BIND 0.0.0.0 ;;
    2) set_env_key PANEL_BIND 127.0.0.1 ;;
    *) echo "  Unchanged."; return 0 ;;
  esac
  apply_env
}

manage_menu() {
  local c
  while :; do
    echo
    printf '\033[1m Server monitoring is installed in %s\033[0m\n' "$INSTALL_DIR"
    echo "   Panel:    $(panel_url)"
    echo "   User:     $(env_get PANEL_USER)"
    compose ps -a --format '{{.Service}} {{.State}}' 2>/dev/null < /dev/null | awk '
      { n++; if ($2 == "running") r++; else bad = bad " " $1 " (" $2 ")" }
      END { if (n) printf "   Services: %d of %d running%s\n", r, n, (bad != "" ? " - not running:" bad : "") }' || true
    echo
    echo "   1) Update / repair (write the files again, keep settings and data)"
    echo "   2) Download the newest version and install it"
    echo "   3) Change the panel port"
    echo "   4) Change the panel username and password"
    echo "   5) Change who can open the panel (any network / this server only)"
    echo "   6) Turn off two-step login (lost the authenticator app)"
    echo "   7) Status and the panel's recent log"
    echo "   8) Restart all services"
    echo "   9) Uninstall (keep the data)"
    echo "  10) Uninstall and delete all data"
    echo "   0) Exit"
    read -r -p "Choose [0-10]: " c < /dev/tty || exit 0
    case "$c" in
      1) return 0 ;;
      2) ACTION=update; return 0 ;;
      3) menu_port ;;
      4) menu_login ;;
      5) menu_bind ;;
      6) rm -f "$INSTALL_DIR/data/panel/totp.json"
         compose restart panel < /dev/null >/dev/null 2>&1 || true
         log "Two-step login is off; sign in with the password and turn it on again in the panel." ;;
      7) compose ps -a < /dev/null || true; echo; compose logs --tail 30 panel < /dev/null || true ;;
      8) log "Restarting all services (the firewall rules stay in place)"
         compose restart < /dev/null || true; wait_panel ;;
      9) remove_install keep; exit 0 ;;
      10) read -r -p "This deletes all monitoring data and $INSTALL_DIR. Type DELETE to confirm: " c < /dev/tty || c=""
          if [ "$c" = DELETE ]; then remove_install purge; exit 0; fi
          echo "  Nothing deleted." ;;
      0|q) exit 0 ;;
      "") ;;
      *) warn "Unknown choice: $c" ;;
    esac
  done
}

if [ "$ACTION" = install ] && [ "$NO_START" = 0 ] && [ "${NO_MENU:-0}" != 1 ] && interactive \
   && [ -f "$INSTALL_DIR/.env" ] && [ -f "$INSTALL_DIR/docker-compose.yml" ] && command -v docker >/dev/null 2>&1; then
  manage_menu
fi

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
start_stack || die "The containers did not start (see the error above). Run this installer again to change the port or other settings from its menu."
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
echo "  Manage:   run this installer again for the menu (port, login, update, uninstall), or"
echo "            docker compose --project-directory $INSTALL_DIR ps | logs | restart"
exit 0
}

main "$@"
