#!/usr/bin/env bash
# WhatsApp Bot Advanced - Interactive Installer / Manager
# One-liner style (after you host this file on GitHub raw):
#   bash <(curl -fsSL https://raw.githubusercontent.com/SlCatProduct/wa-bot-installer/main/install.sh)
set -euo pipefail

APP_NAME="whatsapp-bot-advanced"
APP_DIR="/opt/${APP_NAME}"
APP_SERVICE="wa-bot.service"
CONF_DIR="/etc/wa-bot"
CONF_FILE="${CONF_DIR}/config.env"

DEFAULT_PORT="3000"
DEFAULT_TZ="Asia/Colombo"
# Pre-set to your repo ZIP (direct raw link)
DEFAULT_SOURCE_URL="https://raw.githubusercontent.com/SlCatProduct/wa-bot-installer/main/whatsapp-bot-advanced.zip"

green(){ printf "\033[32m%s\033[0m" "$*"; }
yellow(){ printf "\033[33m%s\033[0m" "$*"; }
red(){ printf "\033[31m%s\033[0m" "$*"; }
ok(){ printf "%s %s\n" "$(green ✔)" "$*"; }
warn(){ printf "%s %s\n" "$(yellow ⚠)" "$*"; }
err(){ printf "%s %s\n" "$(red ✘)" "$*"; }
die(){ err "$*"; exit 1; }

need_root(){ [ "$(id -u)" -eq 0 ] || die "Run as root (sudo)."; }

ensure_conf(){
  mkdir -p "$CONF_DIR"
  touch "$CONF_FILE"
  grep -q '^PORT=' "$CONF_FILE" 2>/dev/null || echo "PORT=${DEFAULT_PORT}" >> "$CONF_FILE"
  grep -q '^TZ=' "$CONF_FILE" 2>/dev/null || echo "TZ=${DEFAULT_TZ}" >> "$CONF_FILE"
  grep -q '^APP_SOURCE=' "$CONF_FILE" 2>/dev/null || echo "APP_SOURCE=${DEFAULT_SOURCE_URL}" >> "$CONF_FILE"
  set -a; source "$CONF_FILE"; set +a
}

save_conf(){
  mkdir -p "$CONF_DIR"
  cat > "$CONF_FILE" <<EOF
PORT=${PORT:-${DEFAULT_PORT}}
TZ=${TZ:-${DEFAULT_TZ}}
APP_SOURCE=${APP_SOURCE:-${DEFAULT_SOURCE_URL}}
EOF
  ok "Saved settings -> ${CONF_FILE}"
}

ensure_tools(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl unzip ca-certificates rsync >/dev/null
}

install_docker(){
  if ! command -v docker >/dev/null 2>&1; then
    warn "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
  fi
  if ! docker compose version >/dev/null 2>&1; then
    warn "Installing docker compose plugin..."
    apt-get update -y && apt-get install -y docker-compose-plugin
  fi
  ok "Docker ready"
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
    ok "Copying from local: $path"
    rsync -a "$path"/ "$STAGE/extract/"
  else
    ok "Downloading artifact: $src"
    local zip="$STAGE/app.zip"
    curl -fL --connect-timeout 15 --retry 3 --retry-delay 2 -o "$zip" "$src" || die "Download failed"
    ok "Unpacking..."
    mkdir -p "$STAGE/extract"
    unzip -q "$zip" -d "$STAGE/extract"
    rm -f "$zip"
  fi
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
  rm -rf "${APP_DIR}.old" || true
  if [ -d "$APP_DIR" ]; then mv "$APP_DIR" "${APP_DIR}.old"; fi
  mkdir -p "$APP_DIR"
  rsync -a "$root"/ "$APP_DIR"/

  # Bind mounts/types
  mkdir -p "$APP_DIR/backend/wa-auth"
  rm -rf "$APP_DIR/backend/data.sqlite" 2>/dev/null || true
  touch "$APP_DIR/backend/data.sqlite"
  chmod 666 "$APP_DIR/backend/data.sqlite"
  chmod -R 777 "$APP_DIR/backend/wa-auth"

  # Optional: drop 'version:' line in compose to avoid warnings
  if grep -qE '^\s*version:' "$APP_DIR/docker-compose.yml" 2>/dev/null; then
    sed -i '/^\s*version:/d' "$APP_DIR/docker-compose.yml" || true
  fi

  ok "Deployed to ${APP_DIR}"
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
  ok "Compose override written (PORT=${PORT}, TZ=${TZ})"
}

compose_up(){
  (cd "$APP_DIR" && docker compose down || true)
  (cd "$APP_DIR" && docker compose up --build -d)
  ok "Container up"
}

service_install(){
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
  systemctl daemon-reload
  systemctl enable "${APP_SERVICE}"
  systemctl start  "${APP_SERVICE}"
  ok "Service enabled (${APP_SERVICE})"
}

action_install(){
  ensure_tools; install_docker; ensure_conf
  fetch_source
  local root; root="$(detect_root_dir "$STAGE/extract")"
  deploy_files "$root"
  write_override
  compose_up
  service_install
  ok "Open: http://$(curl -s ifconfig.me 2>/dev/null || echo '<SERVER-IP>'):${PORT}"
  ok "API:  curl -sS http://127.0.0.1:${PORT}/api/status"
}

action_update(){
  ensure_tools; install_docker; ensure_conf
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
  docker logs -f "$cid"
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
  echo " ${APP_NAME} Manager"
  echo "=============================="
  echo " Port      : ${PORT:-${DEFAULT_PORT}}"
  echo " Timezone  : ${TZ:-${DEFAULT_TZ}}"
  echo " Source    : ${APP_SOURCE:-<unset>}"
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
12) Exit
M
  read -rp "Select [1-12]: " ans
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
    12) exit 0;;
    *) echo "Invalid";;
  esac
  read -rp "Press Enter to continue..." _
}

main(){
  need_root
  ensure_conf
  while true; do menu; done
}

main "$@"
