#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="3x-ui-outbound-switcher"
APP_TITLE="3X-UI Outbound Switcher"
APP_VERSION="v1.0.18"
INSTALL_DIR="/opt/${APP_NAME}"
SYMLINK_PATH="/usr/local/bin/${APP_NAME}"

[[ "$(id -u)" -eq 0 ]] || { echo "[ERROR] Run as root."; exit 1; }

mkdir -p "$INSTALL_DIR"
cp -f "$(dirname "$0")/xui-switcher.sh" "$INSTALL_DIR/xui-switcher.sh"
cp -f "$(dirname "$0")/install.sh" "$INSTALL_DIR/install.sh"
cp -f "$(dirname "$0")/uninstall.sh" "$INSTALL_DIR/uninstall.sh"
chmod +x "$INSTALL_DIR/"*.sh
ln -sf "$INSTALL_DIR/xui-switcher.sh" "$SYMLINK_PATH"

echo "[OK] ${APP_TITLE} ${APP_VERSION} installed to ${INSTALL_DIR}"
exec "$INSTALL_DIR/xui-switcher.sh"
