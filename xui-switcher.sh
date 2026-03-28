#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="3x-ui-outbound-switcher"
APP_TITLE="3X-UI Outbound Switcher"
APP_VERSION="v1.0.18"

INSTALL_DIR="/opt/${APP_NAME}"
ENV_DIR="/etc/${APP_NAME}"
STATE_DIR="/var/lib/${APP_NAME}"
LOG_DIR="/var/log/${APP_NAME}"
ENV_FILE="${ENV_DIR}/switcher.env"
STATE_FILE="${STATE_DIR}/state.json"
SCRIPT_LOG="${LOG_DIR}/switcher.log"
ACTION_LOG="${LOG_DIR}/actions.log"
LOCK_FILE="/run/${APP_NAME}.lock"
COOKIE_JAR="${STATE_DIR}/cookies.txt"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
TIMER_FILE="/etc/systemd/system/${APP_NAME}.timer"
SYMLINK_PATH="/usr/local/bin/${APP_NAME}"
TMP_BASE="/tmp/${APP_NAME}"

DEFAULT_PANEL_URL="http://127.0.0.1:2053"
DEFAULT_CONFIG_PATH="/usr/local/x-ui/bin/config.json"
DEFAULT_XRAY_BIN="/usr/local/x-ui/bin/xray-linux-amd64"
DEFAULT_FALLBACK_RESTART_CMD="systemctl restart x-ui"
DEFAULT_TIMER_SECONDS="20"

LAST_ERROR=""
PANEL_PROBE_STATE=""
PANEL_PROBE_DELAY=""
PANEL_PROBE_STATUS_CODE=""

COL_RESET="\033[0m"
COL_RED="\033[1;31m"
COL_GREEN="\033[1;32m"
COL_YELLOW="\033[1;33m"
COL_BLUE="\033[1;34m"
COL_CYAN="\033[1;36m"

say(){ printf '%b\n' "$*"; }
success(){ say "${COL_GREEN}[OK]${COL_RESET} $*"; }
warn(){ say "${COL_YELLOW}[WARN]${COL_RESET} $*"; }
info(){ say "${COL_BLUE}[INFO]${COL_RESET} $*"; }
err(){ LAST_ERROR="$*"; say "${COL_RED}[ERROR]${COL_RESET} $*" >&2; }
log(){ mkdir -p "$LOG_DIR"; : > "$SCRIPT_LOG"; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$SCRIPT_LOG"; }
action_log(){ mkdir -p "$LOG_DIR"; : > "$ACTION_LOG"; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$ACTION_LOG"; }
die(){ err "$*"; return 1; }

require_root(){ [[ "$(id -u)" -eq 0 ]] || die "Run this script as root."; }
command_exists(){ command -v "$1" >/dev/null 2>&1; }
service_active(){ systemctl is-active --quiet "${APP_NAME}.service"; }
timer_active(){ systemctl is-active --quiet "${APP_NAME}.timer"; }

ensure_dirs() {
  mkdir -p "$INSTALL_DIR" "$ENV_DIR" "$STATE_DIR" "$LOG_DIR" "$TMP_BASE"
  : > "$SCRIPT_LOG"
  : > "$ACTION_LOG"
}

cleanup() {
  local ec=$?
  if [[ -e "$LOCK_FILE" ]] && [[ "$(cat "$LOCK_FILE" 2>/dev/null || true)" == "$$" ]]; then
    rm -f "$LOCK_FILE"
  fi
  exit "$ec"
}
trap cleanup EXIT

ensure_lock() {
  mkdir -p "$(dirname "$LOCK_FILE")"
  if [[ -e "$LOCK_FILE" ]]; then
    local pid
    pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      die "${APP_TITLE} is already running. Wait for the current run to finish or stop the service first."
      return 1
    fi
    rm -f "$LOCK_FILE"
  fi
  printf '%s' "$$" > "$LOCK_FILE"
}

normalize_url(){ local u="${1%/}"; printf '%s' "$u"; }
trim_spaces(){ sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi
  PANEL_URL="$(normalize_url "${PANEL_URL:-$DEFAULT_PANEL_URL}")"
  PANEL_USERNAME="${PANEL_USERNAME:-admin}"
  PANEL_PASSWORD="${PANEL_PASSWORD:-}"
  CONFIG_PATH="${CONFIG_PATH:-$DEFAULT_CONFIG_PATH}"
  XRAY_BIN="${XRAY_BIN:-$DEFAULT_XRAY_BIN}"
  FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
  RECOVER_THRESHOLD="${RECOVER_THRESHOLD:-3}"
  MIN_SWITCH_GAP="${MIN_SWITCH_GAP:-60}"
  PROBE_TIMEOUT="${PROBE_TIMEOUT:-8}"
  PROBE_MODE="${PROBE_MODE:-panel}"
  PROBE_URLS="${PROBE_URLS:-https://cp.cloudflare.com/generate_204,http://connectivitycheck.gstatic.com/generate_204}"
  RESTART_WAIT_SECONDS="${RESTART_WAIT_SECONDS:-5}"
  PANEL_READY_TIMEOUT="${PANEL_READY_TIMEOUT:-90}"
  TIMER_SECONDS="${TIMER_SECONDS:-20}"
  FALLBACK_RESTART_CMD="${FALLBACK_RESTART_CMD:-$DEFAULT_FALLBACK_RESTART_CMD}"
}

save_env() {
  ensure_dirs
  cat > "$ENV_FILE" <<EOF
PANEL_URL="${PANEL_URL}"
PANEL_USERNAME="${PANEL_USERNAME}"
PANEL_PASSWORD="${PANEL_PASSWORD}"
CONFIG_PATH="${CONFIG_PATH}"
XRAY_BIN="${XRAY_BIN}"
FAIL_THRESHOLD="${FAIL_THRESHOLD}"
RECOVER_THRESHOLD="${RECOVER_THRESHOLD}"
MIN_SWITCH_GAP="${MIN_SWITCH_GAP}"
PROBE_TIMEOUT="${PROBE_TIMEOUT}"
PROBE_MODE="${PROBE_MODE}"
PROBE_URLS="${PROBE_URLS}"
RESTART_WAIT_SECONDS="${RESTART_WAIT_SECONDS:-5}"
PANEL_READY_TIMEOUT="${PANEL_READY_TIMEOUT:-90}"
TIMER_SECONDS="${TIMER_SECONDS:-20}"
FALLBACK_RESTART_CMD="${FALLBACK_RESTART_CMD}"
EOF
  chmod 600 "$ENV_FILE"
}

mask_secret() {
  local s="${1:-}" n=${#1}
  if (( n <= 4 )); then printf '%s' '****'; else printf '%s' "${s:0:2}****${s:n-2:2}"; fi
}

panel_login() {
  ensure_dirs
  rm -f "$COOKIE_JAR"
  local code body
  body="$(mktemp)"
  code="$({
    curl -sS -o "$body" -w "%{http_code}" -c "$COOKIE_JAR" \
      -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
      --data-urlencode "username=${PANEL_USERNAME}" \
      --data-urlencode "password=${PANEL_PASSWORD}" \
      -X POST "${PANEL_URL}/login"
  } || true)"
  if [[ "$code" != "200" && "$code" != "302" ]]; then
    rm -f "$body"
    return 1
  fi
  rm -f "$body"
  [[ -s "$COOKIE_JAR" ]]
}

extract_config_json() {
  local in_file="$1" out_file="$2"
  jq -ce '
    def cands:
      .,
      .obj?,
      .data?,
      .result?,
      .config?,
      .obj.data?,
      .obj.result?,
      .obj.config?,
      .data.obj?,
      .data.result?,
      .data.config?;
    def unwrap:
      if type == "string" then (try fromjson catch empty) else . end;
    [ cands | unwrap | select(type == "object" and has("outbounds") and has("routing")) ][0]
  ' "$in_file" > "$out_file" 2>/dev/null
}

panel_get_config() {
  local out="$1" raw tmp code
  raw="$(mktemp)"; tmp="$(mktemp)"
  code="$({
    curl -sS -o "$raw" -w "%{http_code}" -b "$COOKIE_JAR" \
      "${PANEL_URL}/panel/api/server/getConfigJson"
  } || true)"
  if [[ "$code" != "200" ]]; then rm -f "$raw" "$tmp"; return 1; fi
  if ! jq empty "$raw" >/dev/null 2>&1; then rm -f "$raw" "$tmp"; return 1; fi
  if ! extract_config_json "$raw" "$tmp"; then rm -f "$raw" "$tmp"; return 1; fi
  mv "$tmp" "$out"; rm -f "$raw"
}

panel_get_editable_xray_state() {
  local out="$1" raw tmp code
  raw="$(mktemp)"; tmp="$(mktemp)"
  code="$({
    curl -sS -o "$raw" -w "%{http_code}" -b "$COOKIE_JAR" \
      -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
      -X POST "${PANEL_URL}/panel/xray/"
  } || true)"
  if [[ "$code" != "200" ]]; then rm -f "$raw" "$tmp"; return 1; fi
  if ! jq -e '.success == true and (.obj | type == "string")' "$raw" >/dev/null 2>&1; then rm -f "$raw" "$tmp"; return 1; fi
  if ! jq -r '.obj' "$raw" | jq -c . > "$tmp" 2>/dev/null; then rm -f "$raw" "$tmp"; return 1; fi
  mv "$tmp" "$out"; rm -f "$raw"
}

extract_xray_setting_from_state() {
  local state_file="$1" out_file="$2"
  jq -ce '.xraySetting' "$state_file" > "$out_file" 2>/dev/null
}

panel_update_xray() {
  local cfg_file="$1" resp code
  resp="$(mktemp)"
  code="$({
    curl -sS -o "$resp" -w "%{http_code}" -b "$COOKIE_JAR" \
      -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
      --data-urlencode "xraySetting@${cfg_file}" \
      -X POST "${PANEL_URL}/panel/xray/update"
  } || true)"
  if [[ "$code" != "200" ]]; then rm -f "$resp"; return 1; fi
  if ! jq -e '.success == true' "$resp" >/dev/null 2>&1; then
    log "ERROR: panel update failed response: $(cat "$resp" 2>/dev/null)"
    rm -f "$resp"; return 1
  fi
  rm -f "$resp"
}

panel_restart_xray() {
  local code resp url
  resp="/tmp/${APP_NAME}_restart_resp.json"
  for url in \
    "${PANEL_URL}/panel/api/server/restartXrayService" \
    "${PANEL_URL}/panel/server/restartXrayService"
  do
    code="$({
      curl -sS -o "$resp" -w "%{http_code}" -b "$COOKIE_JAR" -X POST "$url"
    } || true)"
    if [[ "$code" == "200" ]]; then return 0; fi
  done
  return 1
}

panel_get_xray_result() {
  local out="$1" code
  code="$({
    curl -sS -o "$out" -w "%{http_code}" -b "$COOKIE_JAR" \
      -X GET "${PANEL_URL}/panel/xray/getXrayResult"
  } || true)"
  [[ "$code" == "200" ]]
}

wait_for_xray_restart_result_best_effort() {
  local timeout="${1:-60}" i body obj
  body="$(mktemp)"
  for ((i=0;i<timeout;i++)); do
    if panel_get_xray_result "$body"; then
      obj="$(jq -r '.obj // empty' "$body" 2>/dev/null || true)"
      if [[ "$obj" == *"successfully relaunched"* ]]; then
        log "INFO: getXrayResult reported successful relaunch"
        rm -f "$body"; return 0
      fi
      if [[ -n "$obj" ]]; then
        log "WARN: getXrayResult reported: $obj"
      fi
    fi
    sleep 1
  done
  rm -f "$body"
  return 1
}

wait_for_panel_ready() {
  local timeout="${1:-$PANEL_READY_TIMEOUT}" i tmp_cfg
  for ((i=0;i<timeout;i++)); do
    if panel_login; then
      tmp_cfg="$(mktemp)"
      if panel_get_config "$tmp_cfg"; then rm -f "$tmp_cfg"; return 0; fi
      rm -f "$tmp_cfg"
    fi
    sleep 1
  done
  return 1
}

read_priority_tags_from_config() {
  local cfg="$1"
  mapfile -t PRIORITY_TAGS < <(
    jq -r '.outbounds[]?.tag // empty' "$cfg" | grep -E '^[A-Z]-' | sort
  )
  [[ ${#PRIORITY_TAGS[@]} -gt 0 ]]
}

init_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    local tags_json
    tags_json="$(printf '%s\n' "${PRIORITY_TAGS[@]}" | jq -R . | jq -s .)"
    jq -n --argjson tags "$tags_json" '
      {current:null,last_switch_ts:0,
       fail_counts:(reduce $tags[] as $t ({}; .[$t]=0)),
       success_counts:(reduce $tags[] as $t ({}; .[$t]=0))}
    ' > "$STATE_FILE"
  fi
}

sync_state_tags() {
  local tags_json tmp
  tags_json="$(printf '%s\n' "${PRIORITY_TAGS[@]}" | jq -R . | jq -s .)"
  tmp="$(mktemp)"
  jq --argjson tags "$tags_json" '
    .fail_counts = (reduce $tags[] as $t (.fail_counts // {}; .[$t] = (.[$t] // 0))) |
    .success_counts = (reduce $tags[] as $t (.success_counts // {}; .[$t] = (.[$t] // 0)))
  ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

state_get(){ jq -r "$@" "$STATE_FILE"; }
state_set(){ local tmp; tmp="$(mktemp)"; jq "$@" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"; }
inc_fail(){ local tag="$1"; state_set --arg t "$tag" '.fail_counts[$t] = ((.fail_counts[$t] // 0) + 1) | .success_counts[$t] = 0'; }
inc_success(){ local tag="$1"; state_set --arg t "$tag" '.success_counts[$t] = ((.success_counts[$t] // 0) + 1) | .fail_counts[$t] = 0'; }
get_fail_count(){ state_get --arg t "$1" '.fail_counts[$t] // 0'; }
get_success_count(){ state_get --arg t "$1" '.success_counts[$t] // 0'; }
get_current_state_tag(){ state_get '.current'; }
get_last_switch_ts(){ state_get '.last_switch_ts'; }
set_current(){ local tag="$1" now; now="$(date +%s)"; state_set --arg t "$tag" --argjson now "$now" '.current=$t | .last_switch_ts=$now'; }

priority_index() {
  local target="$1" i
  for i in "${!PRIORITY_TAGS[@]}"; do
    [[ "${PRIORITY_TAGS[$i]}" == "$target" ]] && { echo "$i"; return 0; }
  done
  echo "-1"
}

get_current_active_tag_from_config() {
  local cfg="$1"
  jq -r '.routing.rules | [ .[] | select(has("outboundTag") and has("network")) ] | last | .outboundTag // empty' "$cfg"
}

find_target_rule_index() {
  local cfg="$1"
  jq -r '.routing.rules | to_entries | map(select(.value.outboundTag != null and .value.network != null)) | last | .key // -1' "$cfg"
}

validate_config() {
  "$XRAY_BIN" run -test -config "$1" >/dev/null 2>&1
}

load_outbound_json() {
  local cfg="$1" tag="$2"
  jq -c --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$cfg"
}

all_outbounds_json() {
  local cfg="$1"
  jq -c '.outbounds' "$cfg"
}

panel_test_outbound() {
  local cfg="$1" tag="$2" outbound_json all_outbounds body_file http_code
  PANEL_PROBE_STATE="error"; PANEL_PROBE_DELAY=""; PANEL_PROBE_STATUS_CODE=""
  outbound_json="$(load_outbound_json "$cfg" "$tag")" || return 1
  [[ -n "$outbound_json" ]] || return 1
  all_outbounds="$(all_outbounds_json "$cfg")" || return 1
  [[ -n "$all_outbounds" ]] || return 1
  body_file="$(mktemp)"
  http_code="$({
    curl -sS -o "$body_file" -w "%{http_code}" -b "$COOKIE_JAR" \
      -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
      -X POST "${PANEL_URL}/panel/xray/testOutbound" \
      --data-urlencode "outbound=${outbound_json}" \
      --data-urlencode "allOutbounds=${all_outbounds}"
  } || true)"
  if [[ "$http_code" != "200" ]]; then rm -f "$body_file"; PANEL_PROBE_STATE="error"; return 1; fi
  if ! jq empty "$body_file" >/dev/null 2>&1; then rm -f "$body_file"; PANEL_PROBE_STATE="error"; return 1; fi
  PANEL_PROBE_DELAY="$(jq -r '.obj.delay // empty' "$body_file" 2>/dev/null || true)"
  PANEL_PROBE_STATUS_CODE="$(jq -r '.obj.statusCode // empty' "$body_file" 2>/dev/null || true)"
  if jq -e '.success == true and (.obj.success == true)' "$body_file" >/dev/null 2>&1; then PANEL_PROBE_STATE="success"; rm -f "$body_file"; return 0; fi
  if jq -e '.success == true and (.obj.success == false or .obj.success == null)' "$body_file" >/dev/null 2>&1; then PANEL_PROBE_STATE="fail"; rm -f "$body_file"; return 1; fi
  PANEL_PROBE_STATE="error"; rm -f "$body_file"; return 1
}

probe_tcp_endpoint() {
  local host="$1" port="$2"
  timeout "$PROBE_TIMEOUT" bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1
}

probe_tag() {
  local cfg="$1" tag="$2" address port
  case "${PROBE_MODE:-panel}" in
    panel)
      if panel_test_outbound "$cfg" "$tag"; then return 0; fi
      if [[ "$PANEL_PROBE_STATE" == "fail" ]]; then return 1; fi
      warn "Panel probe returned an internal error for ${tag}. Falling back to tcp."
      address="$(jq -r --arg tag "$tag" '.outbounds[] | select(.tag == $tag) | (.settings.address // .settings.vnext[0].address // empty)' "$cfg")"
      port="$(jq -r --arg tag "$tag" '.outbounds[] | select(.tag == $tag) | (.settings.port // .settings.vnext[0].port // empty)' "$cfg")"
      [[ -n "$address" && -n "$port" ]] || return 1
      probe_tcp_endpoint "$address" "$port"
      ;;
    tcp)
      address="$(jq -r --arg tag "$tag" '.outbounds[] | select(.tag == $tag) | (.settings.address // .settings.vnext[0].address // empty)' "$cfg")"
      port="$(jq -r --arg tag "$tag" '.outbounds[] | select(.tag == $tag) | (.settings.port // .settings.vnext[0].port // empty)' "$cfg")"
      [[ -n "$address" && -n "$port" ]] || return 1
      probe_tcp_endpoint "$address" "$port"
      ;;
    *)
      return 1
      ;;
  esac
}

post_switch_health_check() {
  local target_tag="$1" cfg="$2" attempts=5 i
  for ((i=1;i<=attempts;i++)); do
    if probe_tag "$cfg" "$target_tag"; then return 0; fi
    sleep 2
  done
  return 1
}

choose_best_available() {
  local tag s
  for tag in "${PRIORITY_TAGS[@]}"; do
    s="$(get_success_count "$tag")"
    if [[ "$s" =~ ^[0-9]+$ ]] && (( s >= 1 )); then echo "$tag"; return 0; fi
  done
  echo ""
}

apply_switch() {
  local api_cfg="$1" new_tag="$2"
  local editable_state editable_cfg backup_cfg tmp_cfg refreshed_api_cfg current_after
  editable_state="$(mktemp)"; editable_cfg="$(mktemp)"; backup_cfg="$(mktemp)"; tmp_cfg="$(mktemp)"; refreshed_api_cfg="$(mktemp)"

  if ! panel_get_editable_xray_state "$editable_state"; then
    rm -f "$editable_state" "$editable_cfg" "$backup_cfg" "$tmp_cfg" "$refreshed_api_cfg"
    die "Could not fetch editable xraySetting from panel." || return 1
  fi
  if ! extract_xray_setting_from_state "$editable_state" "$editable_cfg"; then
    rm -f "$editable_state" "$editable_cfg" "$backup_cfg" "$tmp_cfg" "$refreshed_api_cfg"
    die "Could not extract xraySetting from panel response." || return 1
  fi
  cp -f "$editable_cfg" "$backup_cfg"

  local idx
  idx="$(find_target_rule_index "$editable_cfg")"
  [[ "$idx" != "-1" ]] || {
    rm -f "$editable_state" "$editable_cfg" "$backup_cfg" "$tmp_cfg" "$refreshed_api_cfg"
    die "Target routing rule not found in editable xraySetting." || return 1
  }

  jq --argjson idx "$idx" --arg tag "$new_tag" '.routing.rules[$idx].outboundTag = $tag' "$editable_cfg" > "$tmp_cfg" || {
    rm -f "$editable_state" "$editable_cfg" "$backup_cfg" "$tmp_cfg" "$refreshed_api_cfg"
    die "Failed to build modified editable xraySetting." || return 1
  }

  if ! panel_update_xray "$tmp_cfg"; then
    rm -f "$editable_state" "$editable_cfg" "$backup_cfg" "$tmp_cfg" "$refreshed_api_cfg"
    die "Panel update request failed." || return 1
  fi

  if ! panel_restart_xray; then
    log "ERROR: panel restart request failed after switch to [$new_tag], restoring previous xraySetting"
    panel_update_xray "$backup_cfg" || true
    panel_restart_xray || true
    rm -f "$editable_state" "$editable_cfg" "$backup_cfg" "$tmp_cfg" "$refreshed_api_cfg"
    die "Switch failed and previous xraySetting was restored." || return 1
  fi

  log "INFO: waiting for final panel/API outcome after restart (initial=${RESTART_WAIT_SECONDS:-5}s, timeout=${PANEL_READY_TIMEOUT:-90}s)"
  sleep "${RESTART_WAIT_SECONDS:-5}"
  wait_for_xray_restart_result_best_effort "${PANEL_READY_TIMEOUT:-90}" || true

  local timeout end_ts
  timeout="${PANEL_READY_TIMEOUT:-90}"
  end_ts=$(( $(date +%s) + timeout ))
  while (( $(date +%s) <= end_ts )); do
    if panel_login && panel_get_config "$refreshed_api_cfg"; then
      current_after="$(get_current_active_tag_from_config "$refreshed_api_cfg" || true)"
      if [[ "$current_after" == "$new_tag" ]] && post_switch_health_check "$new_tag" "$refreshed_api_cfg"; then
        action_log "SWITCH OK: active outbound changed to [$new_tag] through panel xray/update API"
        set_current "$new_tag"
        rm -f "$editable_state" "$editable_cfg" "$backup_cfg" "$tmp_cfg" "$refreshed_api_cfg"
        return 0
      fi
    fi
    sleep 2
  done

  log "ERROR: final outcome after switch to [$new_tag] was not healthy/persisted, restoring previous xraySetting"
  panel_update_xray "$backup_cfg" || true
  panel_restart_xray || true
  wait_for_xray_restart_result_best_effort "${PANEL_READY_TIMEOUT:-90}" || true
  wait_for_panel_ready "${PANEL_READY_TIMEOUT:-90}" || true
  rm -f "$editable_state" "$editable_cfg" "$backup_cfg" "$tmp_cfg" "$refreshed_api_cfg"
  die "Switch outcome was not healthy after timeout; previous xraySetting restored." || return 1
}

validate_local_paths() {
  [[ -f "$CONFIG_PATH" ]] || { die "config.json path not found: $CONFIG_PATH"; return 1; }
  [[ -x "$XRAY_BIN" ]] || { die "xray binary not found or not executable: $XRAY_BIN"; return 1; }
  command_exists curl || { die "curl is required."; return 1; }
  command_exists jq || { die "jq is required."; return 1; }
}

self_test_summary() {
  require_root || return 1
  ensure_lock || return 1
  load_env
  local failures=0 api_cfg="" current_tag="" highest_healthy="" t
  local healthy_tags=() unhealthy_tags=()

  say ""
  say "${COL_BLUE}==================== Self-Test Summary ====================${COL_RESET}"

  if timer_active; then
    warn "Timer is active. Self-test is running with the switcher lock to avoid overlap."
  fi

  if panel_login; then success "Panel login: OK"; else err "Panel login: FAILED"; failures=$((failures+1)); fi

  api_cfg="$(mktemp)"
  if panel_get_config "$api_cfg"; then success "Config fetch from panel API: OK"; else err "Config fetch from panel API: FAILED"; failures=$((failures+1)); fi

  local editable_state editable_cfg
  editable_state="$(mktemp)"; editable_cfg="$(mktemp)"
  if panel_get_editable_xray_state "$editable_state" && extract_xray_setting_from_state "$editable_state" "$editable_cfg"; then
    success "Editable xraySetting fetch from panel UI API: OK"
  else
    err "Editable xraySetting fetch from panel UI API: FAILED"
    failures=$((failures+1))
  fi

  if [[ -f "$CONFIG_PATH" ]]; then
    if validate_config "$CONFIG_PATH"; then success "Local config validation: OK"; else warn "Local config validation: FAILED (diagnostic only)"; fi
  else
    err "Local config path missing: $CONFIG_PATH"; failures=$((failures+1))
  fi

  if [[ -f "$api_cfg" ]] && [[ -s "$api_cfg" ]]; then
    if read_priority_tags_from_config "$api_cfg"; then success "Prioritized outbound discovery: OK (${#PRIORITY_TAGS[@]} found)"; else err "Prioritized outbound discovery: FAILED"; failures=$((failures+1)); fi

    current_tag="$(get_current_active_tag_from_config "$api_cfg" || true)"
    if [[ -n "$current_tag" && "$current_tag" != "null" ]]; then success "Current routing outbound detected: ${current_tag}"; else err "Current routing outbound detection: FAILED"; failures=$((failures+1)); fi

    if [[ ${#PRIORITY_TAGS[@]} -gt 0 ]]; then
      for t in "${PRIORITY_TAGS[@]}"; do
        if probe_tag "$api_cfg" "$t"; then
          healthy_tags+=("$t")
          [[ -z "$highest_healthy" ]] && highest_healthy="$t"
        else
          unhealthy_tags+=("$t")
        fi
      done
      if [[ ${#healthy_tags[@]} -gt 0 ]]; then
        success "Healthy prioritized outbounds: ${healthy_tags[*]}"
        success "Highest-priority healthy outbound: ${highest_healthy}"
      else
        err "No healthy prioritized outbound found."
        failures=$((failures+1))
      fi
      if [[ ${#unhealthy_tags[@]} -gt 0 ]]; then warn "Unhealthy prioritized outbounds: ${unhealthy_tags[*]}"; fi
    fi
  fi

  if timer_active; then success "Timer status: active"; else info "Timer status: inactive"; fi
  if service_active; then info "Service status: active"; else info "Service status: inactive"; fi

  rm -f "$api_cfg" "$editable_state" "$editable_cfg"
  say "${COL_BLUE}===========================================================${COL_RESET}"
  if [[ "$failures" -eq 0 ]]; then success "Self-test passed."; return 0; else err "Self-test completed with ${failures} issue(s)."; return 1; fi
}

perform_failover_check() {
  require_root || return 1
  ensure_lock || return 1
  load_env
  ensure_dirs
  [[ -f "$ENV_FILE" ]] || die "Configuration not found. Run Install / Reconfigure first." || return 1
  validate_local_paths || return 1
  panel_login || die "3x-ui login failed. Check panel URL, username, or password." || return 1

  local api_cfg
  api_cfg="$(mktemp)"
  panel_get_config "$api_cfg" || { rm -f "$api_cfg"; die "Could not download config from 3x-ui API."; return 1; }

  read_priority_tags_from_config "$api_cfg" || { rm -f "$api_cfg"; die "No prioritized outbound tags found. Use tags like A-Main-Out, B-Backup-Out."; return 1; }
  init_state
  sync_state_tags

  local current_cfg_tag current_state_tag
  current_cfg_tag="$(get_current_active_tag_from_config "$api_cfg")"
  current_state_tag="$(get_current_state_tag)"

  if [[ -n "$current_cfg_tag" && "$current_cfg_tag" != "null" && "$current_cfg_tag" != "$current_state_tag" ]]; then
    if [[ -z "$current_state_tag" || "$current_state_tag" == "null" ]]; then
      log "state initialized from config: $current_cfg_tag"
    else
      log "state synchronized from config: $current_cfg_tag"
    fi
    set_current "$current_cfg_tag"
    current_state_tag="$current_cfg_tag"
  fi

  local tag
  for tag in "${PRIORITY_TAGS[@]}"; do
    if probe_tag "$api_cfg" "$tag"; then
      inc_success "$tag"
      log "probe success: $tag (mode=${PROBE_MODE}, delay=${PANEL_PROBE_DELAY:-}, statusCode=${PANEL_PROBE_STATUS_CODE:-}, success=$(get_success_count "$tag"))"
    else
      inc_fail "$tag"
      log "probe fail: $tag (mode=${PROBE_MODE}, state=${PANEL_PROBE_STATE:-fail}, fail=$(get_fail_count "$tag"))"
    fi
  done

  current_state_tag="$(get_current_state_tag)"
  local best desired_tag="" current_fail current_success best_success last_switch now current_idx best_idx
  best="$(choose_best_available)"
  current_fail="$(get_fail_count "$current_state_tag")"
  current_success="$(get_success_count "$current_state_tag")"
  best_success="$(get_success_count "$best")"
  last_switch="$(get_last_switch_ts)"
  now="$(date +%s)"
  current_idx="$(priority_index "$current_state_tag")"
  best_idx="$(priority_index "$best")"

  if [[ -z "$best" ]]; then
    log "no switch needed: current=[$current_state_tag]"
    rm -f "$api_cfg"
    return 0
  fi

  if [[ "$current_state_tag" == "$best" ]]; then
    log "no switch needed: current=[$current_state_tag]"
    rm -f "$api_cfg"
    return 0
  fi

  if (( now - last_switch < MIN_SWITCH_GAP )); then
    log "no switch needed: current=[$current_state_tag] (min switch gap active)"
    rm -f "$api_cfg"
    return 0
  fi

  if [[ -z "$current_state_tag" || "$current_state_tag" == "null" ]]; then
    desired_tag="$best"
  elif [[ "$current_fail" =~ ^[0-9]+$ ]] && (( current_fail >= FAIL_THRESHOLD )); then
    desired_tag="$best"
  elif [[ "$best_idx" =~ ^-?[0-9]+$ && "$current_idx" =~ ^-?[0-9]+$ ]] && (( best_idx >= 0 )) && (( current_idx >= 0 )) && (( best_idx < current_idx )) && (( best_success >= RECOVER_THRESHOLD )); then
    desired_tag="$best"
  fi

  if [[ -z "$desired_tag" || "$desired_tag" == "$current_state_tag" ]]; then
    log "no switch needed: current=[$current_state_tag]"
    rm -f "$api_cfg"
    return 0
  fi

  if apply_switch "$api_cfg" "$desired_tag"; then
    rm -f "$api_cfg"
    return 0
  fi

  rm -f "$api_cfg"
  return 1
}

write_systemd_files() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=${APP_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/xui-switcher.sh run-now
User=root
Group=root
EOF

  cat > "$TIMER_FILE" <<EOF
[Unit]
Description=${APP_NAME} timer

[Timer]
OnBootSec=30
OnUnitInactiveSec=${TIMER_SECONDS}
Unit=${APP_NAME}.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
}

show_current_config() {
  require_root || return 1
  load_env
  header
  [[ -f "$ENV_FILE" ]] || die "Configuration not found." || return 1
  cat <<EOF
Current settings
----------------
PANEL_URL          : ${PANEL_URL}
PANEL_USERNAME     : ${PANEL_USERNAME}
PANEL_PASSWORD     : $(mask_secret "$PANEL_PASSWORD")
CONFIG_PATH        : ${CONFIG_PATH}
XRAY_BIN           : ${XRAY_BIN}
FAIL_THRESHOLD     : ${FAIL_THRESHOLD}
RECOVER_THRESHOLD  : ${RECOVER_THRESHOLD}
MIN_SWITCH_GAP     : ${MIN_SWITCH_GAP}
PROBE_TIMEOUT      : ${PROBE_TIMEOUT}
PROBE_MODE         : ${PROBE_MODE}
RESTART_WAIT_SEC   : ${RESTART_WAIT_SECONDS}
PANEL_READY_TO     : ${PANEL_READY_TIMEOUT}
TIMER_SECONDS      : ${TIMER_SECONDS}
ENV_FILE           : ${ENV_FILE}
STATE_FILE         : ${STATE_FILE}
SCRIPT_LOG         : ${SCRIPT_LOG}
ACTION_LOG         : ${ACTION_LOG}
EOF
}

validate_current_config_menu() {
  require_root || return 1
  load_env
  if validate_config "$CONFIG_PATH"; then success "Current Xray config validation passed."; else err "Current Xray config validation failed."; fi
}

show_logs() {
  require_root || return 1
  if [[ -f "$SCRIPT_LOG" ]]; then tail -n 100 -f "$SCRIPT_LOG"; return 0; fi
  warn "No log file yet: $SCRIPT_LOG"
  if systemctl list-unit-files | grep -q "^${APP_NAME}\\.service"; then
    info "Showing recent journal output instead."
    journalctl -u "${APP_NAME}.service" -n 100 -f
  fi
}

show_status() {
  require_root || return 1
  systemctl status "${APP_NAME}.timer" --no-pager 2>/dev/null || true
  echo
  systemctl status "${APP_NAME}.service" --no-pager 2>/dev/null || true
}

start_service() { require_root || return 1; systemctl start "${APP_NAME}.service" >/dev/null 2>&1 || return 1; success "Service executed once."; }
stop_timer() { require_root || return 1; systemctl disable --now "${APP_NAME}.timer" >/dev/null 2>&1 || true; success "Timer stopped and disabled."; }
restart_timer() { require_root || return 1; systemctl restart "${APP_NAME}.timer" >/dev/null 2>&1 || return 1; success "Timer restarted."; }
enable_timer() { require_root || return 1; systemctl enable --now "${APP_NAME}.timer" >/dev/null 2>&1 || return 1; success "Timer enabled."; }
disable_timer() { require_root || return 1; systemctl disable --now "${APP_NAME}.timer" >/dev/null 2>&1 || true; success "Timer disabled."; }

prompt_nonempty() {
  local label="$1" def="${2:-}" ans
  while true; do
    read -r -p "${label} [${def}]: " ans || true
    ans="${ans:-$def}"
    if [[ -n "$ans" ]]; then printf '%s' "$ans"; return 0; fi
    err "Value cannot be empty."
  done
}

prompt_number() {
  local label="$1" def="$2" ans
  while true; do
    read -r -p "${label} [${def}]: " ans || true
    ans="${ans:-$def}"
    if [[ "$ans" =~ ^[0-9]+$ ]]; then printf '%s' "$ans"; return 0; fi
    err "Enter a valid number."
  done
}

prompt_yes_no() {
  local label="$1" def="${2:-Y}" ans
  while true; do
    read -r -p "${label} [${def}/N]: " ans || true
    ans="${ans:-$def}"
    case "${ans^^}" in
      Y|YES) return 0 ;;
      N|NO) return 1 ;;
      *) err "Please enter Y or N." ;;
    esac
  done
}

prompt_probe_mode() {
  local def="$1" ans
  while true; do
    read -r -p "Probe mode [panel/tcp] [${def}]: " ans || true
    ans="${ans:-$def}"
    case "$ans" in
      panel|tcp) printf '%s' "$ans"; return 0 ;;
      *) err "Please enter panel or tcp." ;;
    esac
  done
}

header() {
  clear || true
  say "${COL_BLUE}============================================================${COL_RESET}"
  say "${COL_CYAN}  ${APP_TITLE} ${APP_VERSION}${COL_RESET}"
  say "${COL_BLUE}============================================================${COL_RESET}"
  say "Repository : https://github.com/ach1992/3x-ui-outbound-switcher"
  say "Purpose    : Switch between outbound by your priority on 3X-UI"
  say "Priority   : Derived from outbound tags like A-..., B-..., C-..."
  say "Platform   : Ubuntu 22/24/25, Debian 11/12/13"
  say "${COL_BLUE}============================================================${COL_RESET}"
  say "1) Install / Reconfigure"
  say "2) Show current config"
  say "3) Validate current Xray config"
  say "4) Start one check now"
  say "5) Run self-test"
  say "6) Start service once"
  say "7) Stop auto-run timer"
  say "8) Restart auto-run timer"
  say "9) Show status"
  say "10) Show logs"
  say "11) Enable auto-run timer"
  say "12) Disable auto-run timer"
  say "13) Uninstall"
  say "0) Exit"
  echo
}

pause(){ read -r -p "Press Enter to continue..." _ || true; }

interactive_install_or_reconfigure() {
  require_root || return 1
  ensure_dirs
  load_env

  header
  say "Install / Reconfigure"
  say "Leave password empty to keep the current saved password."
  say "Default probe mode is panel, using the same outbound test endpoint as 3x-ui."
  echo

  PANEL_URL="$(prompt_nonempty '3x-ui panel base URL' "${PANEL_URL}")"
  PANEL_URL="$(normalize_url "$PANEL_URL")"
  PANEL_USERNAME="$(prompt_nonempty '3x-ui username' "${PANEL_USERNAME}")"

  local pw
  read -r -s -p "3x-ui password [leave empty to keep current if set]: " pw || true
  echo
  if [[ -n "$pw" ]]; then PANEL_PASSWORD="$pw"; fi
  if [[ -z "$PANEL_PASSWORD" ]]; then err "Password cannot be empty."; return 1; fi

  CONFIG_PATH="$(prompt_nonempty 'config.json path' "${CONFIG_PATH}")"
  XRAY_BIN="$(prompt_nonempty 'xray binary path' "${XRAY_BIN}")"
  FAIL_THRESHOLD="$(prompt_number 'Fail threshold (consecutive fails before switch)' "${FAIL_THRESHOLD}")"
  RECOVER_THRESHOLD="$(prompt_number 'Recover threshold (consecutive successes before switch back)' "${RECOVER_THRESHOLD}")"
  MIN_SWITCH_GAP="$(prompt_number 'Minimum seconds between switches' "${MIN_SWITCH_GAP}")"
  PROBE_TIMEOUT="$(prompt_number 'Probe timeout in seconds' "${PROBE_TIMEOUT}")"
  RESTART_WAIT_SECONDS="$(prompt_number 'Seconds to wait after restart' "${RESTART_WAIT_SECONDS}")"
  PANEL_READY_TIMEOUT="$(prompt_number 'Panel/API ready timeout after restart' "${PANEL_READY_TIMEOUT}")"
  TIMER_SECONDS="$(prompt_number 'Auto-run timer interval in seconds' "${TIMER_SECONDS}")"
  PROBE_MODE="$(prompt_probe_mode "${PROBE_MODE}")"

  save_env
  write_systemd_files
  ln -sf "${INSTALL_DIR}/xui-switcher.sh" "$SYMLINK_PATH"

  validate_local_paths || return 1
  panel_login || { err "Panel login failed."; return 1; }

  local api_cfg
  api_cfg="$(mktemp)"
  if ! panel_get_config "$api_cfg"; then rm -f "$api_cfg"; err "Could not fetch config from panel API."; return 1; fi
  if ! read_priority_tags_from_config "$api_cfg"; then rm -f "$api_cfg"; err "No prioritized outbound tags found."; return 1; fi
  success "Configuration saved."
  info "Detected prioritized outbounds from config:"
  local t
  for t in "${PRIORITY_TAGS[@]}"; do say " - ${t}"; done
  rm -f "$api_cfg"

  local timer_just_enabled=0
  if prompt_yes_no "Enable auto-run timer now?" "Y"; then
    if enable_timer; then
      timer_just_enabled=1
      if service_active || [[ -e "$LOCK_FILE" ]]; then
        info "Auto-run has already started. Skipping manual health check to avoid overlap."
      fi
    else
      warn "Could not enable timer."
      systemctl status "${APP_NAME}.timer" --no-pager || true
    fi
  else
    systemctl disable --now "${APP_NAME}.timer" >/dev/null 2>&1 || true
    warn "Timer left disabled."
  fi

  if [[ "$timer_just_enabled" -eq 0 ]]; then
    if prompt_yes_no "Run one health check now?" "Y"; then
      if perform_failover_check; then success "Health check finished."; else err "Health check failed. Review the log or configuration."; fi
    fi
  fi

  if prompt_yes_no "Run self-test now?" "Y"; then
    if self_test_summary; then success "Self-test finished successfully."; else warn "Self-test reported one or more issues."; fi
  fi
}

uninstall_app() {
  require_root || return 1
  if [[ -x "${INSTALL_DIR}/uninstall.sh" ]]; then exec "${INSTALL_DIR}/uninstall.sh"; fi
  die "uninstall.sh not found in ${INSTALL_DIR}"
}

main_menu() {
  local choice
  while true; do
    header
    read -r -p "Choose an option: " choice || true
    case "$choice" in
      1) interactive_install_or_reconfigure; pause ;;
      2) show_current_config; pause ;;
      3) validate_current_config_menu; pause ;;
      4) if perform_failover_check; then success "Check finished."; else err "Check failed."; fi; pause ;;
      5) if self_test_summary; then success "Self-test finished successfully."; else warn "Self-test reported one or more issues."; fi; pause ;;
      6) start_service; pause ;;
      7) stop_timer; pause ;;
      8) restart_timer; pause ;;
      9) show_status; pause ;;
      10) show_logs ;;
      11) enable_timer; pause ;;
      12) disable_timer; pause ;;
      13) uninstall_app ;;
      0) exit 0 ;;
      *) err "Invalid choice. Please enter a valid menu number."; sleep 1 ;;
    esac
  done
}

case "${1:-}" in
  run-now) perform_failover_check ;;
  self-test) self_test_summary ;;
  *) main_menu ;;
esac
