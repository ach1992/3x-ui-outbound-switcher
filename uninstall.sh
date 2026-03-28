#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="3x-ui-outbound-switcher"
LEGACY_NAMES=("3X-UI Outbound Switcher")
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
TIMER_FILE="/etc/systemd/system/${APP_NAME}.timer"

[[ "$(id -u)" -eq 0 ]] || { echo "[ERROR] Run as root."; exit 1; }

systemctl disable --now "${APP_NAME}.timer" 2>/dev/null || true
systemctl stop "${APP_NAME}.service" 2>/dev/null || true
rm -f "$SERVICE_FILE" "$TIMER_FILE"
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed >/dev/null 2>&1 || true

rm -f "/usr/local/bin/${APP_NAME}" "/run/${APP_NAME}.lock"
rm -rf "/opt/${APP_NAME}" "/etc/${APP_NAME}" "/var/lib/${APP_NAME}" "/var/log/${APP_NAME}" "/tmp/${APP_NAME}" "/tmp/${APP_NAME}_"*

for legacy in "${LEGACY_NAMES[@]}"; do
  systemctl disable --now "${legacy}.timer" >/dev/null 2>&1 || true
  systemctl stop "${legacy}.service" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${legacy}.service" "/etc/systemd/system/${legacy}.timer"
  rm -f "/usr/local/bin/${legacy}" "/run/${legacy}.lock"
  rm -rf "/opt/${legacy}" "/etc/${legacy}" "/var/lib/${legacy}" "/var/log/${legacy}" "/tmp/${legacy}" "/tmp/${legacy}_"*
done

echo "[OK] 3X-UI Outbound Switcher removed."
