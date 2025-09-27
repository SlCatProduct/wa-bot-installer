#!/usr/bin/env bash
# WhatsApp Bot Advanced - Interactive Installer / Manager (root-based, plain logs)
set -euo pipefail

APP_NAME="whatsapp-bot-advanced"
APP_DIR="/root/${APP_NAME}"
APP_SERVICE="wa-bot.service"
CONF_DIR="/etc/wa-bot"
CONF_FILE="${CONF_DIR}/config.env"

DEFAULT_PORT="3000"
DEFAULT_TZ="Asia/Colombo"
DEFAULT_SOURCE_URL="https://raw.githubusercontent.com/SlCatProduct/wa-bot-installer/main/whatsapp-bot-advanced.zip"
DEFAULT_LOG_TAIL="100"

green(){ printf "\033[32m%s\033[0m" "$*"; }
yellow(){ printf "\033[33m%s\033[0m" "$*"; }
red(){ printf "\033[31m%s\033[0m" "$*"; }
ok(){ echo "$(green ✔) $*"; }
warn(){ echo "$(yellow ⚠) $*"; }
err(){ echo "$(red ✘) $*"; }
die(){ err "$*"; exit 1; }

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
  cat > "$CONF_FILE" <<EOF
PORT=${PORT:-${DEFAULT_PORT}}
TZ=${TZ:-${DEFAULT_TZ}}
APP_SOURCE=${APP_SOURCE:-${DEFAULT_SOURCE_URL}}
LOG_TAIL=${LOG_TAIL:-${DEFAULT_LOG_TAIL}}
EOF
  ok "Saved settings -> ${CONF_FILE}"
}

apt_update_resilient() {
  export DEBIAN_FRONTEND=noninteractive
  mkdir -p /root/apt-disabled
  if ! apt-get update -y; then
    warn "apt-get update failed. Disabling suspicious repos…"
    while read -r f; do
      [ -n "$f" ] || continue
      warn "Disabled: $f"
      mv "$f" "/root/apt-disabled/$(basename "$f").disabled" || true
    done < <(ls /etc/apt/sources.list.d/*.list 2>/dev/null | xargs -r grep -lEi 'cloudsmith|caddy|unstable|testing' || true)
    apt-get clean
    apt-get update -y || die "APT update failed again."
  fi
}

ensure_tools(){
  echo ">> Installing base tools"
  apt_update_resilient
  apt-get install -y curl unzip ca-certificates rsync
}

install_docker(){
  echo ">> Installing Docker if missing"
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
  fi
  if ! docker compose version >/dev/null 2>&1; then
    apt-get install -y docker-compose-plugin
  fi
}

get_cid(){ (cd "$APP_DIR" && docker compose ps -q app 2>/dev/null || true); }

clean_stage(){ [ -n "${STAGE:-}" ] && [ -d "$STAGE" ] && rm -rf "$STAGE" || true; }
trap clean_stage EXIT

fetch_source(){
  STAGE="$(mktemp -d)"
  local src="${APP_SOURCE:-}"
  [ -n "$src" ] || die "Source URL not set."
  echo ">> Fetching source: $src"
  if [[ "$src" == local:* ]]; then
    local path="${src#local:}"
    [ -d "$path" ] || die "Local path not found: $path"
    rsync -a "$path"/ "$STAGE/extract/"
  else
    local zip="$STAGE/app.zip"
    curl -fL --retry 3 -o "$zip" "$src" || die "Download failed"
    mkdir -p "$STAGE/extract"
    unzip -q "$zip" -d "$STAGE/extract"
  fi
}

detect_root_dir(){
  local base="$1"
  local cand
  cand="$(find "$base" -maxdepth 2 -type f -name 'Dockerfile' -printf '%h\n' | head -n1)"
  [ -n "$cand" ] || die "Could not detect project root"
  echo "$cand"
}

deploy_files(){
  local root="$1"
  echo ">> Deploying files"
  rm -rf "${APP_DIR}.old" || true
  [ -d "$APP_DIR" ] && mv "$APP_DIR" "${APP_DIR}.old"
  mkdir -p "$APP_DIR"
  rsync -a "$root"/ "$APP_DIR"/
  mkdir -p "$APP_DIR/backend/wa-auth"
  touch "$APP_DIR/backend/data.sqlite"
  chmod 666 "$APP_DIR/backend/data.sqlite"
  chmod -R 777 "$APP_DIR/backend/wa-auth"
  sed -i '/^\s*version:/d' "$APP_DIR/docker-compose.yml" 2>/dev/null || true
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
}

compose_up(){
  echo ">> Building & starting container"
  (cd "$APP_DIR" && docker compose down || true)
  (cd "$APP_DIR" && docker compose up --build -d)
}

service_install(){
  echo ">> Enabling service"
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
}

finish_msg(){
  ok "Open: http://$(curl -s ifconfig.me || echo '<SERVER-IP>'):${PORT}"
  ok "API:  curl -sS http://127.0.0.1:${PORT}/api/status"
}

action_install(){
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

action_update(){ fetch_source; local root; root="$(detect_root_dir "$STAGE/extract")"; deploy_files "$root"; write_override; compose_up; systemctl restart "${APP_SERVICE}" || true; ok "Updated."; }
action_uninstall(){ systemctl disable --now "${APP_SERVICE}" || true; (cd "$APP_DIR" && docker compose down || true); rm -rf "$APP_DIR" "${APP_DIR}.old"; ok "Uninstalled."; }
action_status(){ systemctl is-active --quiet "${APP_SERVICE}" && ok "Service: active" || warn "Service: inactive"; (cd "$APP_DIR" && docker compose ps || true); }
action_logs(){ local cid; cid="$(get_cid)"; [ -n "$cid" ] || die "No running container"; docker logs --tail="${LOG_TAIL}" -f "$cid"; }
action_restart(){ (cd "$APP_DIR" && docker compose restart || true); ok "Restarted."; }
action_change_port(){ read -rp "New port [${PORT}]: " np; PORT="${np:-$PORT}"; save_conf; write_override; compose_up; }
action_change_tz(){ read -rp "New TZ [${TZ}]: " ntz; TZ="${ntz:-$TZ}"; save_conf; write_override; compose_up; }
action_set_source(){ read -rp "New source URL/path: " ns; APP_SOURCE="$ns"; save_conf; }
action_change_log_tail(){ read -rp "New log tail [${LOG_TAIL}]: " nl; LOG_TAIL="$nl"; save_conf; }
action_backup(){ local ts dest; ts="$(date +%Y%m%d-%H%M%S)"; dest="/root/wa-bot-backup-${ts}.tgz"; tar -czf "$dest" -C "$APP_DIR" backend/data.sqlite backend/wa-auth; ok "Backup: $dest"; }
action_restore(){ read -rp "Path to backup: " bp; [ -f "$bp" ] || die "File not found"; (cd "$APP_DIR" && tar -xzf "$bp"); compose_up; ok "Restored."; }

menu(){
  clear
  echo "=============================="
  echo " ${APP_NAME} Manager"
  echo "=============================="
  echo " Port      : ${PORT}"
  echo " Timezone  : ${TZ}"
  echo " Source    : ${APP_SOURCE}"
  echo " Log Tail  : ${LOG_TAIL} lines"
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
  case "$ans" in
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

main(){ need_root; ensure_conf; save_conf; while true; do menu; done; }
main "$@"
