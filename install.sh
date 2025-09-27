#!/usr/bin/env bash
# WhatsApp Bot Advanced - Interactive Installer / Manager (root-based, pretty UI)
# One-liner idea (after you host this file on GitHub raw):
#   bash <(curl -fsSL https://raw.githubusercontent.com/SlCatProduct/wa-bot-installer/main/install.sh)
set -euo pipefail

APP_NAME="whatsapp-bot-advanced"
APP_DIR="/root/${APP_NAME}"           # install under /root
APP_SERVICE="wa-bot.service"
CONF_DIR="/etc/wa-bot"
CONF_FILE="${CONF_DIR}/config.env"

DEFAULT_PORT="3000"
DEFAULT_TZ="Asia/Colombo"
DEFAULT_SOURCE_URL="https://raw.githubusercontent.com/SlCatProduct/wa-bot-installer/main/whatsapp-bot-advanced.zip"
DEFAULT_LOG_TAIL="100"                # docker logs --tail=100 -f

# ------------ UI helpers ------------
green(){ printf "\033[32m%s\033[0m" "$*"; }
yellow(){ printf "\033[33m%s\033[0m" "$*"; }
red(){ printf "\033[31m%s\033[0m" "$*"; }
bold(){ printf "\033[1m%s\033[0m" "$*"; }
ok(){ printf "%s %s\n" "$(green ✔)" "$*"; }
warn(){ printf "%s %s\n" "$(yellow ⚠)" "$*"; }
err(){ printf "%s %s\n" "$(red ✘)" "$*"; }
die(){ err "$*"; exit 1; }

# progress bar (single line)
bar(){
  local pct=${1:-0} msg=${2:-""}
  local width=40
  ((pct<0)) && pct=0
  ((pct>100)) && pct=100
  local done=$(( pct * width / 100 ))
  local left=$(( width - done ))
  printf "\r\033[1m[%-*s%s]\033[0m %3d%%  %s" "$done" "$(printf '#%.0s' $(seq 1 $done))" "$(printf '.%.0s' $(seq 1 $left))" "$pct" "$msg"
  if [ "$pct" -ge 100 ]; then printf "\n"; fi
}

need_root(){ [ "$(id -u)" -eq 0 ] || die "Run as root (sudo)."; }

ensure_conf(){
  mkdir -p "$CONF_DIR"
  touch "$CONF_FILE"
  grep -q '^PORT=' "$CONF_FILE" 2>/dev/null || echo "PORT=${DEFAULT_PORT}" >> "$CONF_FILE"
  grep -q '^TZ=' "$CONF_FILE" 2>/dev/null || echo "TZ=${DEFAULT_TZ}" >> "$CONF_FILE"
  grep -q '^APP_SOURCE=' "$CONF_FILE" 2>/dev/null || echo "APP_SOURCE=${DEFAULT_SOURCE_URL}" >> "$CONF_FILE"
  grep -q '^LOG_TAIL=' "$CONF_FILE" 2>/dev/null || echo "LOG_TAIL=${DEFAULT_LOG_TAIL}" >> "$CONF_FILE"
  set -a; source "$CONF_FILE"; set +a
}

save_conf(){
  mkdir -p "$CONF_DIR"
  cat > "$CONF_FILE" <<EOF
PORT=${PORT:-${DEFAULT_PORT}}
TZ=${TZ:-${DEFAULT_TZ}}
APP_SOURCE=${APP_SOURCE:-${DEFAULT_SOURCE_URL}}
LOG_TAIL=${LOG_TAIL:-${DEFAULT_LOG_TAIL}}
EOF
  ok "Saved settings -> ${CONF_FILE}"
}

# ---------- APT resilient update ----------
apt_update_resilient() {
  export DEBIAN_FRONTEND=noninteractive
  mkdir -p /root/apt-disabled
  local tries=2
  for i in $(seq 1 $tries); do
    bar 5 "Updating apt cache... (try $i/$tries)"
    if apt-get update -o Acquire::Retries=3 -y >/dev/null 2>&1; then
      bar 8 "APT cache OK"
      return 0
    fi
    printf "\n"; warn "apt-get update failed (try $i). Diagnosing…"
    # auto-disable common broken lists (cloudsmith/caddy/unstable)
    local changed=0
    while read -r f; do
      [ -n "$f" ] || continue
      warn "Disabling repo: $f"
      mv "$f" "/root/apt-disabled/$(basename "$f").disabled" || true
      changed=1
    done < <(ls /etc/apt/sources.list.d/*.list 2>/dev/null | xargs -r grep -lEi 'cloudsmith|caddy|unstable|testing|bookworm .*ubuntu|ubuntu .*bookworm' || true)
    apt-get clean || true
    [ "$changed" = 1 ] || break
  done
  die "APT update failed. Check /root/apt-disabled for disabled repos and run again."
}

ensure_tools(){
  apt_update_resilient
  bar 10 "Installing base tools…"
  if ! apt-get install -y curl unzip ca-certificates rsync >/dev/null 2>&1; then
    printf "\n"; die "Failed to install base tools (curl/unzip/rsync)."
  fi
  bar 15 "Base tools ready"
}

install_docker(){
  if ! command -v docker >/dev/null 2>&1; then
    bar 18 "Installing Docker…"
    if ! curl -fsSL https://get.docker.com | sh >/dev/null 2>&1; then
      printf "\n"; die "Docker install failed."
    fi
  fi
  if ! docker compose version >/dev/null 2>&1; then
    bar 22 "Installing docker compose plugin…"
    if ! apt-get install -y docker-compose-plugin >/dev/null 2>&1; then
      printf "\n"; die "docker-compose-plugin install failed."
    fi
  fi
  bar 25 "Docker ready"
}

get_cid(){ (cd "$APP_DIR" && docker compose ps -q app 2>/dev/null || true); }

clean_stage(){ [ -n "${STAGE:-}" ] && [ -d "$STAGE" ] && rm -rf "$STAGE" || true; }
trap clean_stage EXIT

fetch_source(){
  STAGE="$(mktemp -d)"
  local src="${APP_SOURCE:-}"
  [ -n "$src" ] || die "Source URL not set. Go to Settings -> Set Source URL first."

  if [[ "$src" == local:* ]]; then
    local path="${src#local:}"
    [ -d "$path" ] || die "Local path not found: $path"
    bar 35 "Copying from local…"
    rsync -a "$path"/ "$STAGE/extract/" || { printf "\n"; die "Local copy failed"; }
  else
    bar 30 "Downloading artifact…"
    local zip="$STAGE/app.zip"
    if ! curl -fL --connect-timeout 20 --max-time 300 \
        --retry 5 --retry-delay 2 --retry-connrefused \
        -A "wa-installer" -o "$zip" "$src"; then
      printf "\n"; die "Download failed from: $src"
    fi
    bar 38 "Unpacking…"
    mkdir -p "$STAGE/extract"
    if ! unzip -q "$zip" -d "$STAGE/extract"; then
      printf "\n"; die "Unzip failed (corrupt ZIP?)"
    fi
    rm -f "$zip"
  fi

  # sanity check
  if ! find "$STAGE/extract" -maxdepth 2 -name Dockerfile | grep -q .; then
    printf "\n"; die "Artifact missing Dockerfile. Check APP_SOURCE."
  fi

  bar 45 "Source ready"
}

detect_root_dir(){
  local base="$1"
  local cand
  cand="$(find "$base" -maxdepth 2 -type f -name 'Dockerfile' -printf '%h\n' | head -n1)"
  if [ -z "$cand" ] && [ -d "$base/whatsapp-bot-advanced" ]; then
    cand="$base/whatsapp-bot-advanced"
  fi
  [ -n "$cand" ] || die "Could not detect project root inside artifact (Dockerfile missing)"
  echo "$cand"
}

deploy_files(){
  local root="$1"
  bar 48 "Deploying files…"
  rm -rf "${APP_DIR}.old" || true
  if [ -d "$APP_DIR" ]; then mv "$APP_DIR" "${APP_DIR}.old"; fi
  mkdir -p "$APP_DIR"
  rsync -a "$root"/ "$APP_DIR"/

  mkdir -p "$APP_DIR/backend/wa-auth"
  rm -rf "$APP_DIR/backend/data.sqlite" 2>/dev/null || true
  touch "$APP_DIR/backend/data.sqlite"
  chmod 666 "$APP_DIR/backend/data.sqlite"
  chmod -R 777 "$APP_DIR/backend/wa-auth"

  # Drop deprecated compose 'version:' line if present
  if grep -qE '^\s*version:' "$APP_DIR/docker-compose.yml" 2>/dev/null; then
    sed -i '/^\s*version:/d' "$APP_DIR/docker-compose.yml" || true
  fi
  bar 55 "Files deployed"
}

write_override(){
  cat > "$APP_DIR/docker-compose.override.yml" <<EOF
services:
  app:
    ports:
      - "${PORT}:3000"
    environment:
      - TZ=${TZ}
EOF
  bar 58 "Compose override written"
}

compose_up(){
  bar 62 "Building container…"
  (cd "$APP_DIR" && docker compose down >/dev/null 2>&1 || true)
  (cd "$APP_DIR" && docker compose up --build -d >/dev/null)
  bar 78 "Container started"
}

service_install(){
  bar 82 "Enabling service…"
  cat > "/etc/systemd/system/${APP_SERVICE}" <<EOF
[Unit]
Description=WA Bot (Docker Compose)
After=network-online.target docker.service
Requires=docker.service
[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null
  systemctl enable "${APP_SERVICE}" >/dev/null
  systemctl start  "${APP_SERVICE}" >/dev/null
  bar 90 "Service active"
}

finish_msg(){
  bar 100 "Done"
  echo
  ok "Open: http://$(curl -s ifconfig.me 2>/dev/null || echo '<SERVER-IP>'):${PORT}"
  ok "API:  curl -sS http://127.0.0.1:${PORT}/api/status"
}

action_install(){
  clear
  echo
  echo "$(bold "Installing ${APP_NAME}")"
  echo "----------------------------------------------"
  ensure_conf; save_conf
  ensure_tools
  install_docker
  fetch_source
  local root; root="$(detect_root_dir "$STAGE/extract")"
  deploy_files "$root"
  write_override
  compose_up
  service_install
  finish_msg
}

action_update(){
  clear
  echo
  echo "$(bold "Updating ${APP_NAME}")"
  echo "----------------------------------------------"
  ensure_conf
  fetch_source
  local root; root="$(detect_root_dir "$STAGE/extract")"
  deploy_files "$root"
  write_override
  compose_up
  systemctl restart "${APP_SERVICE}" 2>/dev/null || true
  ok "Updated."
}

action_uninstall(){
  ensure_conf
  systemctl disable --now "${APP_SERVICE}" 2>/dev/null || true
  (cd "$APP_DIR" && docker compose down || true)
  rm -f "/etc/systemd/system/${APP_SERVICE}"
  systemctl daemon-reload || true
  rm -rf "${APP_DIR}.old" "$APP_DIR"
  ok "Uninstalled."
}

action_status(){
  ensure_conf
  if systemctl is-active --quiet "${APP_SERVICE}" 2>/dev/null; then ok "Service: active"; else warn "Service: inactive"; fi
  if [ -d "$APP_DIR" ]; then (cd "$APP_DIR" && docker compose ps || true); else warn "App not installed."; fi
}

action_logs(){
  ensure_conf
  local cid; cid="$(get_cid)"
  [ -n "$cid" ] || die "No running container found."
  echo "Showing last ${LOG_TAIL} lines (follow). Change default via: 12) Change Log Tail"
  docker logs --tail="${LOG_TAIL}" -f "$cid"
}

action_restart(){
  ensure_conf
  (cd "$APP_DIR" && docker compose restart || true)
  ok "Restarted."
}

action_change_port(){
  ensure_conf
  read -rp "New port [current: ${PORT}]: " np
  PORT="${np:-$PORT}"
  save_conf
  write_override
  compose_up
}

action_change_tz(){
  ensure_conf
  read -rp "New timezone (IANA) [current: ${TZ}]: " ntz
  TZ="${ntz:-$TZ}"
  save_conf
  write_override
  compose_up
}

action_set_source(){
  ensure_conf
  echo "Current source: ${APP_SOURCE:-<unset>}"
  echo "Examples:"
  echo "  - GitHub raw ZIP: https://raw.githubusercontent.com/SlCatProduct/wa-bot-installer/main/whatsapp-bot-advanced.zip"
  echo "  - Local path    : local:/root/whatsapp-bot-advanced"
  read -rp "Enter new source URL/path: " ns
  [ -n "$ns" ] || die "No source provided."
  APP_SOURCE="$ns"
  save_conf
  ok "Source set."
}

action_change_log_tail(){
  ensure_conf
  read -rp "New default log tail lines [current: ${LOG_TAIL}]: " nl
  case "${nl:-}" in
    ''|*[!0-9]*) die "Please enter a positive integer";;
    *) LOG_TAIL="$nl"; save_conf; ok "Log tail set to ${LOG_TAIL}";;
  esac
}

action_backup(){
  ensure_conf
  local ts dest
  ts="$(date +%Y%m%d-%H%M%S)"
  dest="/root/wa-bot-backup-${ts}.tgz"
  tar -czf "$dest" -C "$APP_DIR" backend/data.sqlite backend/wa-auth || die "Backup failed"
  ok "Backup created: $dest"
}

action_restore(){
  ensure_conf
  read -rp "Path to backup .tgz: " bp
  [ -f "$bp" ] || die "File not found: $bp"
  (cd "$APP_DIR" && tar -xzf "$bp") || die "Restore failed"
  compose_up
  ok "Restore done."
}

menu(){
  clear
  echo "=============================="
  echo " $(bold "${APP_NAME} Manager")"
  echo "=============================="
  echo " Port      : ${PORT:-${DEFAULT_PORT}}"
  echo " Timezone  : ${TZ:-${DEFAULT_TZ}}"
  echo " Source    : ${APP_SOURCE:-<unset>}"
  echo " Log Tail  : ${LOG_TAIL:-${DEFAULT_LOG_TAIL}} lines"
  echo " App Dir   : ${APP_DIR}"
  echo "------------------------------"
  cat <<'M'
 1) Install
 2) Update
 3) Uninstall
 4) Status
 5) Logs (follow)
 6) Restart
 7) Change Port
 8) Change Timezone
 9) Set Source URL/Path
10) Backup
11) Restore
12) Change Log Tail
13) Exit
M
  read -rp "Select [1-13]: " ans
  case "${ans:-}" in
    1) action_install;;
    2) action_update;;
    3) action_uninstall;;
    4) action_status;;
    5) action_logs;;
    6) action_restart;;
    7) action_change_port;;
    8) action_change_tz;;
    9) action_set_source;;
    10) action_backup;;
    11) action_restore;;
    12) action_change_log_tail;;
    13) exit 0;;
    *) echo "Invalid";;
  esac
  read -rp "Press Enter to continue..." _
}

main(){
  need_root
  ensure_conf
  # ensure defaults are persisted the first time
  APP_SOURCE="${APP_SOURCE:-$DEFAULT_SOURCE_URL}"
  LOG_TAIL="${LOG_TAIL:-$DEFAULT_LOG_TAIL}"
  save_conf
  while true; do menu; done
}

main "$@"
