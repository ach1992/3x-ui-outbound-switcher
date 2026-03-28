#!/usr/bin/env bash
set -Euo pipefail

APP_NAME="3x-ui-outbound-switcher"
INSTALL_DIR="/opt/${APP_NAME}"
ENV_DIR="/etc/${APP_NAME}"
STATE_DIR="/var/lib/${APP_NAME}"
LOG_DIR="/var/log/${APP_NAME}"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
TIMER_FILE="/etc/systemd/system/${APP_NAME}.timer"
SYMLINK_PATH="/usr/local/bin/${APP_NAME}"

say() { printf '%b\n' "$*"; }
info() { say "[INFO] $*"; }
warn() { say "[WARN] $*"; }
err() { say "[ERROR] $*"; }

die() { err "$*"; exit 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Please run uninstall.sh as root."
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local value alt
  if [[ "${default^^}" == "Y" ]]; then alt="N"; else alt="Y"; fi
  while true; do
    read -r -p "$prompt [$default/$alt]: " value
    value="${value:-$default}"
    case "${value^^}" in
      Y|YES) return 0 ;;
      N|NO) return 1 ;;
      *) err "Please answer yes or no." ;;
    esac
  done
}

main() {
  require_root
  say "============================================================"
  say "  ${APP_NAME} uninstall"
  say "============================================================"

  if ! ask_yes_no "Remove ${APP_NAME} from this server?" "Y"; then
    warn "Uninstall cancelled."
    exit 0
  fi

  systemctl disable --now "${APP_NAME}.timer" >/dev/null 2>&1 || true
  systemctl stop "${APP_NAME}.service" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$TIMER_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true

  rm -f "$SYMLINK_PATH"
  rm -rf "$INSTALL_DIR" "$ENV_DIR" "$STATE_DIR" "$LOG_DIR"
  rm -f "/run/${APP_NAME}.lock"

  if ask_yes_no "Remove saved Xray config backups (*.bak.*) from /usr/local/x-ui/bin?" "N"; then
    rm -f /usr/local/x-ui/bin/config.json.bak.*
  fi

  say "[OK] ${APP_NAME} has been removed."
}

main "$@"
