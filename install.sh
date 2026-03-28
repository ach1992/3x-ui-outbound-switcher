#!/usr/bin/env bash
set -Euo pipefail

APP_NAME="3x-ui-outbound-switcher"
APP_TITLE="3X-UI Outbound Switcher"
APP_VERSION="v1.0.8"
REPO_URL="https://github.com/ach1992/3x-ui-outbound-switcher"
RAW_BASE="https://raw.githubusercontent.com/ach1992/3x-ui-outbound-switcher/main"
INSTALL_DIR="/opt/${APP_NAME}"
TMP_DIR="/tmp/${APP_NAME}-install.$$"
OFFLINE_DIR="/root/${APP_NAME}"
LEGACY_NAMES=("3X-UI Outbound Switcher" "3x-ui outbound switcher")

say() { printf '%b\n' "$*"; }
info() { say "[INFO] $*"; }
warn() { say "[WARN] $*"; }
err() { say "[ERROR] $*"; }

die() { err "$*"; exit 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Please run install.sh as root."
}

command_exists() { command -v "$1" >/dev/null 2>&1; }


cleanup_legacy_artifacts() {
  local legacy
  for legacy in "${LEGACY_NAMES[@]}"; do
    systemctl disable --now "${legacy}.timer" >/dev/null 2>&1 || true
    systemctl stop "${legacy}.service" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${legacy}.service" "/etc/systemd/system/${legacy}.timer"
    rm -f "/usr/local/bin/${legacy}" "/run/${legacy}.lock" "/tmp/${legacy}_login_resp.json" "/tmp/${legacy}_restart_resp.json"
    rm -rf "/opt/${legacy}" "/etc/${legacy}" "/var/lib/${legacy}" "/var/log/${legacy}" "/tmp/${legacy}"
  done
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-Y}"
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

ensure_basic_tools() {
  command_exists apt-get || die "This installer supports Debian and Ubuntu only."
  if ! command_exists curl; then
    info "Installing curl..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl >/dev/null 2>&1 \
      || { apt-get update >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl >/dev/null 2>&1; } \
      || die "Failed to install curl."
  fi
}

copy_from_dir() {
  local src_dir="$1"
  mkdir -p "$INSTALL_DIR"
  cp -f "$src_dir/xui-switcher.sh" "$INSTALL_DIR/xui-switcher.sh"
  cp -f "$src_dir/uninstall.sh" "$INSTALL_DIR/uninstall.sh"
  chmod +x "$INSTALL_DIR/xui-switcher.sh" "$INSTALL_DIR/uninstall.sh"
}

install_online() {
  ensure_basic_tools
  mkdir -p "$TMP_DIR"
  info "Downloading ${APP_TITLE} ${APP_VERSION} from GitHub..."
  curl -fsSL "${RAW_BASE}/xui-switcher.sh" -o "$TMP_DIR/xui-switcher.sh" || die "Failed to download xui-switcher.sh"
  curl -fsSL "${RAW_BASE}/uninstall.sh" -o "$TMP_DIR/uninstall.sh" || die "Failed to download uninstall.sh"
  copy_from_dir "$TMP_DIR"
}

install_offline() {
  [[ -d "$OFFLINE_DIR" ]] || die "Offline directory not found: $OFFLINE_DIR"
  [[ -f "$OFFLINE_DIR/xui-switcher.sh" ]] || die "Offline file missing: $OFFLINE_DIR/xui-switcher.sh"
  [[ -f "$OFFLINE_DIR/uninstall.sh" ]] || die "Offline file missing: $OFFLINE_DIR/uninstall.sh"
  copy_from_dir "$OFFLINE_DIR"
}

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

main() {
  require_root
  cleanup_legacy_artifacts
  say "============================================================"
  say "  ${APP_TITLE} ${APP_VERSION}"
  say "============================================================"
  say "Repository : ${REPO_URL}"
  say "Install    : Online by default, optional offline from ${OFFLINE_DIR}"
  say "============================================================"

  local mode="online"
  if [[ -d "$OFFLINE_DIR" && -f "$OFFLINE_DIR/install.sh" && -f "$OFFLINE_DIR/xui-switcher.sh" && -f "$OFFLINE_DIR/uninstall.sh" ]]; then
    if ask_yes_no "Offline files detected in ${OFFLINE_DIR}. Install offline instead of online?" "Y"; then
      mode="offline"
    fi
  fi

  if [[ "$mode" == "offline" ]]; then
    install_offline
  else
    install_online
  fi

  ln -sf "$INSTALL_DIR/xui-switcher.sh" "/usr/local/bin/${APP_NAME}"
  success_msg="Installed successfully. Starting interactive setup..."
  say "[OK] ${success_msg}"
  exec "$INSTALL_DIR/xui-switcher.sh" install
}

main "$@"
