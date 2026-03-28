#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="3x-ui-outbound-switcher"
INSTALL_DIR="/opt/${APP_NAME}"
ENV_DIR="/etc/${APP_NAME}"
STATE_DIR="/var/lib/${APP_NAME}"
LOG_DIR="/var/log/${APP_NAME}"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
TIMER_FILE="/etc/systemd/system/${APP_NAME}.timer"
SYMLINK_PATH="/usr/local/bin/${APP_NAME}"
CONFIG_BACKUP_GLOB="/usr/local/x-ui/bin/config.json.bak.*"

say() { printf "%b\n" "$*"; }
info() { say "[INFO] $*"; }
success() { say "[OK] $*"; }
warn() { say "[WARN] $*"; }
err() { say "[ERROR] $*"; }
die() { err "$*"; exit 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Please run as root."
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local value
  while true; do
    read -r -p "$prompt [${default}/$( [[ "$default" == "Y" ]] && echo N || echo Y )]: " value
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

  warn "This will remove ${APP_NAME}, its service, timer, logs, state, and configuration files."
  if ! prompt_yes_no "Do you want to continue" "N"; then
    info "Uninstall cancelled."
    exit 0
  fi

  systemctl disable --now "${APP_NAME}.timer" >/dev/null 2>&1 || true
  systemctl stop "${APP_NAME}.service" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$TIMER_FILE"
  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true

  rm -f "$SYMLINK_PATH"
  rm -rf "$INSTALL_DIR" "$ENV_DIR" "$STATE_DIR" "$LOG_DIR"
  rm -f "/run/${APP_NAME}.lock"

  if compgen -G "$CONFIG_BACKUP_GLOB" > /dev/null; then
    if prompt_yes_no "Delete config backup files too (${CONFIG_BACKUP_GLOB})" "N"; then
      rm -f $CONFIG_BACKUP_GLOB
      success "Config backup files removed."
    else
      info "Config backup files kept."
    fi
  fi

  success "${APP_NAME} has been removed."
}

main "$@"
