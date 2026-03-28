#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="3x-ui-outbound-switcher"
APP_VERSION="v1.0.0"
REPO_URL="https://github.com/ach1992/3x-ui-outbound-switcher"
RAW_BASE="https://raw.githubusercontent.com/ach1992/3x-ui-outbound-switcher/main"
INSTALL_DIR="/opt/${APP_NAME}"
SYMLINK_PATH="/usr/local/bin/${APP_NAME}"
OFFLINE_DIR="/root/${APP_NAME}"

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
  local default="${2:-Y}"
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

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

detect_mode() {
  if [[ -f "${OFFLINE_DIR}/xui-switcher.sh" && -f "${OFFLINE_DIR}/install.sh" && -f "${OFFLINE_DIR}/uninstall.sh" ]]; then
    warn "Offline package detected at ${OFFLINE_DIR}"
    if prompt_yes_no "Install from offline package" "Y"; then
      INSTALL_MODE="offline"
    else
      INSTALL_MODE="online"
    fi
  else
    INSTALL_MODE="online"
  fi
}

fetch_online() {
  mkdir -p "$INSTALL_DIR"
  need_cmd curl

  info "Downloading files from GitHub..."
  curl -fsSL "${RAW_BASE}/xui-switcher.sh" -o "${INSTALL_DIR}/xui-switcher.sh"
  curl -fsSL "${RAW_BASE}/uninstall.sh" -o "${INSTALL_DIR}/uninstall.sh"
  curl -fsSL "${RAW_BASE}/README.md" -o "${INSTALL_DIR}/README.md"
}

fetch_offline() {
  mkdir -p "$INSTALL_DIR"
  info "Copying files from offline package..."
  cp -f "${OFFLINE_DIR}/xui-switcher.sh" "${INSTALL_DIR}/xui-switcher.sh"
  cp -f "${OFFLINE_DIR}/uninstall.sh" "${INSTALL_DIR}/uninstall.sh"
  cp -f "${OFFLINE_DIR}/README.md" "${INSTALL_DIR}/README.md"
}

install_files() {
  chmod +x "${INSTALL_DIR}/xui-switcher.sh" "${INSTALL_DIR}/uninstall.sh"
  ln -sf "${INSTALL_DIR}/xui-switcher.sh" "$SYMLINK_PATH"
}

show_header() {
  cat <<HDR
============================================================
${APP_NAME} ${APP_VERSION}
Repository: ${REPO_URL}
============================================================
HDR
}

main() {
  require_root
  show_header
  detect_mode

  if [[ "$INSTALL_MODE" == "offline" ]]; then
    fetch_offline
  else
    fetch_online
  fi

  install_files
  success "Files installed to ${INSTALL_DIR}"
  success "Command installed: ${SYMLINK_PATH}"

  info "Launching ${APP_NAME}..."
  exec "$SYMLINK_PATH"
}

main "$@"
