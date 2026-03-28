#!/usr/bin/env bash
set -Euo pipefail

APP_NAME="3x-ui-outbound-switcher"
APP_VERSION="v1.0.3"
INSTALL_DIR="/opt/${APP_NAME}"
ENV_DIR="/etc/${APP_NAME}"
ENV_FILE="${ENV_DIR}/switcher.env"
STATE_DIR="/var/lib/${APP_NAME}"
LOG_DIR="/var/log/${APP_NAME}"
LOCK_FILE="/run/${APP_NAME}.lock"
COOKIE_JAR="${STATE_DIR}/panel.cookies"
STATE_FILE="${STATE_DIR}/state.json"
SCRIPT_LOG="${LOG_DIR}/switcher.log"
ACTION_LOG="${LOG_DIR}/actions.log"
TMP_BASE="/tmp/${APP_NAME}"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
TIMER_FILE="/etc/systemd/system/${APP_NAME}.timer"
SYMLINK_PATH="/usr/local/bin/${APP_NAME}"
DEFAULT_CONFIG_PATH="/usr/local/x-ui/bin/config.json"
DEFAULT_XRAY_BIN="/usr/local/x-ui/bin/xray-linux-amd64"
FALLBACK_RESTART_CMD="systemctl restart x-ui"

DEPS_UPDATED=0
LAST_ERROR=""
PANEL_PROBE_STATE="error"
PANEL_PROBE_DELAY=""
PANEL_PROBE_STATUS_CODE=""

mkdir -p "$STATE_DIR" "$LOG_DIR" "$TMP_BASE"

setup_colors() {
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    COL_RESET=$'\033[0m'
    COL_BLUE=$'\033[1;34m'
    COL_CYAN=$'\033[1;36m'
    COL_GREEN=$'\033[1;32m'
    COL_YELLOW=$'\033[1;33m'
    COL_RED=$'\033[1;31m'
    COL_BOLD=$'\033[1m'
  else
    COL_RESET=''
    COL_BLUE=''
    COL_CYAN=''
    COL_GREEN=''
    COL_YELLOW=''
    COL_RED=''
    COL_BOLD=''
  fi
}
setup_colors

log() {
  mkdir -p "$LOG_DIR"
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$SCRIPT_LOG"
}

action_log() {
  mkdir -p "$LOG_DIR"
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$ACTION_LOG"
}

say() { printf '%b\n' "$*"; }
info() { say "${COL_CYAN}[INFO]${COL_RESET} $*"; }
success() { say "${COL_GREEN}[OK]${COL_RESET} $*"; }
warn() { say "${COL_YELLOW}[WARN]${COL_RESET} $*"; }
err() { say "${COL_RED}[ERROR]${COL_RESET} $*"; }

die() {
  LAST_ERROR="$*"
  err "$*"
  log "ERROR: $*"
  return 1
}

pause() {
  read -r -p "Press Enter to continue..." _
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Please run as root."
}

cleanup_tmp() {
  find "$TMP_BASE" -maxdepth 1 -type d -name 'probe-*' -mmin +10 -exec rm -rf {} \; 2>/dev/null || true
}
trap cleanup_tmp EXIT

ensure_lock() {
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    die "Another ${APP_NAME} process is already running." || return 1
  fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

normalize_url() {
  local url="$1"
  url="${url%/}"
  printf '%s' "$url"
}

trim_spaces() {
  sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    PANEL_URL="$(normalize_url "${PANEL_URL:-}")"
    PROBE_MODE="${PROBE_MODE:-panel}"
    if [[ -n "${PROBE_URLS:-}" ]]; then
      PROBE_URLS="$(printf '%s' "$PROBE_URLS" | tr -d ' ' )"
    else
      PROBE_URLS="https://cp.cloudflare.com/generate_204,http://connectivitycheck.gstatic.com/generate_204,https://www.msftconnecttest.com/connecttest.txt"
    fi
  fi
}

save_env() {
  mkdir -p "$ENV_DIR"
  cat > "$ENV_FILE" <<ENVEOF
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
ENVEOF
  chmod 600 "$ENV_FILE"
}

mask_secret() {
  local s="$1"
  local n=${#s}
  if (( n <= 4 )); then
    printf '%s' '****'
  else
    printf '%s' "${s:0:2}****${s:n-2:2}"
  fi
}

header() {
  clear >/dev/null 2>&1 || true
  say "${COL_BLUE}============================================================${COL_RESET}"
  say "${COL_CYAN}  ${APP_NAME} ${APP_VERSION}${COL_RESET}"
  say "${COL_BLUE}============================================================${COL_RESET}"
  say "Repository : https://github.com/ach1992/3x-ui-outbound-switcher"
  say "Purpose    : Switch between outbound by your priority on 3X-UI"
  say "Priority   : Derived from outbound tags like A-..., B-..., C-..."
  say "Platform   : Ubuntu 22/24/25, Debian 11/12/13"
  say "${COL_BLUE}============================================================${COL_RESET}"
}

pkg_install_if_missing() {
  local pkg="$1"
  local bin="$2"
  if command_exists "$bin"; then
    return 0
  fi

  info "Installing missing dependency: ${pkg}"
  if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg" >/dev/null 2>&1; then
    return 0
  fi

  if (( DEPS_UPDATED == 0 )); then
    warn "Initial package install failed. Running apt-get update once and retrying."
    if ! apt-get update >/dev/null 2>&1; then
      return 1
    fi
    DEPS_UPDATED=1
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg" >/dev/null 2>&1 || return 1
    return 0
  fi

  return 1
}

ensure_dependencies() {
  require_root || return 1
  command_exists apt-get || die "This installer supports Debian and Ubuntu only." || return 1
  pkg_install_if_missing curl curl || die "Failed to install curl." || return 1
  pkg_install_if_missing jq jq || die "Failed to install jq." || return 1
  command_exists flock || pkg_install_if_missing util-linux flock || die "Failed to install util-linux / flock." || return 1
  command_exists timeout || die "The 'timeout' command is required but was not found." || return 1
  command_exists systemctl || die "systemctl is required but was not found." || return 1
}

validate_url() {
  [[ "$1" =~ ^https?://.+ ]]
}

validate_probe_urls() {
  local urls="$1"
  local url
  [[ -n "$urls" ]] || return 1
  IFS=',' read -r -a _probe_urls <<< "$urls"
  for url in "${_probe_urls[@]}"; do
    url="$(printf '%s' "$url" | trim_spaces)"
    [[ -n "$url" ]] || continue
    validate_url "$url" || return 1
  done
  return 0
}

prompt_nonempty() {
  local prompt="$1"
  local default="${2:-}"
  local value
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$prompt [$default]: " value
      value="${value:-$default}"
    else
      read -r -p "$prompt: " value
    fi
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    err "Value cannot be empty."
  done
}

prompt_number() {
  local prompt="$1"
  local default="$2"
  local value
  while true; do
    read -r -p "$prompt [$default]: " value
    value="${value:-$default}"
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 )); then
      printf '%s' "$value"
      return 0
    fi
    err "Please enter a valid positive number."
  done
}

prompt_yes_no() {
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

prompt_probe_mode() {
  local default="${1:-panel}"
  local value
  while true; do
    read -r -p "Probe mode [panel/tcp/http] [$default]: " value
    value="${value:-$default}"
    case "${value,,}" in
      panel|tcp|http)
        printf '%s' "${value,,}"
        return 0
        ;;
      *)
        err "Please enter panel, tcp, or http."
        ;;
    esac
  done
}

detect_defaults() {
  DETECTED_CONFIG_PATH="$DEFAULT_CONFIG_PATH"
  if [[ ! -f "$DETECTED_CONFIG_PATH" ]]; then
    DETECTED_CONFIG_PATH="$(find /usr/local /etc /opt -type f -name config.json 2>/dev/null | grep -E 'x-ui|3x-ui|xray' | head -n1 || true)"
  fi

  DETECTED_XRAY_BIN="$DEFAULT_XRAY_BIN"
  if [[ ! -x "$DETECTED_XRAY_BIN" ]]; then
    DETECTED_XRAY_BIN="$(find /usr/local /etc /opt -type f \( -name 'xray-linux-amd64' -o -name 'xray' \) 2>/dev/null | head -n1 || true)"
  fi
}

validate_local_paths() {
  [[ -f "$CONFIG_PATH" ]] || die "Config file not found: $CONFIG_PATH" || return 1
  [[ -x "$XRAY_BIN" ]] || die "Xray binary is not executable: $XRAY_BIN" || return 1
}

panel_login() {
  rm -f "$COOKIE_JAR"
  local code
  code="$({
    curl -sS -o "/tmp/${APP_NAME}_login_resp.json" -w "%{http_code}" \
      -c "$COOKIE_JAR" \
      -H "Content-Type: application/json" \
      -X POST "${PANEL_URL}/login" \
      -d "$(jq -nc --arg u "$PANEL_USERNAME" --arg p "$PANEL_PASSWORD" '{username:$u,password:$p}')"
  } || true)"

  [[ "$code" == "200" ]] || return 1
  [[ -s "$COOKIE_JAR" ]] || return 1
  return 0
}

extract_config_json() {
  local in_file="$1"
  local out_file="$2"
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
  local out="$1"
  local raw tmp code
  raw="$(mktemp)"
  tmp="$(mktemp)"
  code="$({
    curl -sS -o "$raw" -w "%{http_code}" \
      -b "$COOKIE_JAR" \
      "${PANEL_URL}/panel/api/server/getConfigJson"
  } || true)"
  if [[ "$code" != "200" ]]; then
    rm -f "$raw" "$tmp"
    return 1
  fi
  if ! jq empty "$raw" >/dev/null 2>&1; then
    rm -f "$raw" "$tmp"
    return 1
  fi
  if ! extract_config_json "$raw" "$tmp"; then
    rm -f "$raw" "$tmp"
    return 1
  fi
  mv "$tmp" "$out"
  rm -f "$raw"
  return 0
}

panel_restart_xray() {
  local code
  code="$({
    curl -sS -o "/tmp/${APP_NAME}_restart_resp.json" -w "%{http_code}" \
      -b "$COOKIE_JAR" \
      -X POST "${PANEL_URL}/panel/api/server/restartXrayService"
  } || true)"
  [[ "$code" == "200" ]]
}

restart_xray_with_fallback() {
  if panel_restart_xray; then
    return 0
  fi
  warn "3x-ui API restart failed. Trying fallback: ${FALLBACK_RESTART_CMD}"
  bash -lc "$FALLBACK_RESTART_CMD"
}

read_priority_tags_from_config() {
  local cfg="$1"
  mapfile -t PRIORITY_TAGS < <(
    jq -r '.outbounds[]?.tag // empty' "$cfg" \
      | grep -E '^[A-Z]-' \
      | sort
  )
  [[ ${#PRIORITY_TAGS[@]} -gt 0 ]] || die "No prioritized outbound tags found. Use tags like A-Main-Out, B-Backup-Out, C-Node." || return 1
}

init_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    local tags_json
    tags_json="$(printf '%s\n' "${PRIORITY_TAGS[@]}" | jq -R . | jq -s .)"
    jq -n --argjson tags "$tags_json" '
      {
        current: null,
        last_switch_ts: 0,
        fail_counts: (reduce $tags[] as $t ({}; .[$t]=0)),
        success_counts: (reduce $tags[] as $t ({}; .[$t]=0))
      }' > "$STATE_FILE"
  fi
}

sync_state_tags() {
  local tags_json tmp
  tags_json="$(printf '%s\n' "${PRIORITY_TAGS[@]}" | jq -R . | jq -s .)"
  tmp="$(mktemp)"
  jq --argjson tags "$tags_json" '
    .fail_counts = (reduce $tags[] as $t (.fail_counts // {}; .[$t] = (.[$t] // 0)))
    | .success_counts = (reduce $tags[] as $t (.success_counts // {}; .[$t] = (.[$t] // 0)))
  ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

state_get() { jq -r "$@" "$STATE_FILE"; }

state_set() {
  local tmp
  tmp="$(mktemp)"
  jq "$@" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

priority_index() {
  local target="$1" i
  for i in "${!PRIORITY_TAGS[@]}"; do
    [[ "${PRIORITY_TAGS[$i]}" == "$target" ]] && { echo "$i"; return 0; }
  done
  echo "-1"
}

get_current_active_tag_from_config() {
  local cfg="$1"
  jq -r '
    .routing.rules
    | [ .[] | select(has("outboundTag") and has("network")) ]
    | last
    | .outboundTag // empty
  ' "$cfg"
}

find_target_rule_index() {
  local cfg="$1"
  jq -r '
    .routing.rules
    | to_entries
    | map(select(.value.outboundTag != null and .value.network != null))
    | last
    | .key // -1
  ' "$cfg"
}

validate_config() {
  "$XRAY_BIN" run -test -config "$1" >/dev/null 2>&1
}

backup_config() {
  local dst="${CONFIG_PATH}.bak.$(date +%F_%H-%M-%S)"
  cp -a "$CONFIG_PATH" "$dst"
  printf '%s' "$dst"
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
  local cfg="$1" tag="$2"
  local outbound_json all_outbounds body_file http_code
  PANEL_PROBE_STATE="error"
  PANEL_PROBE_DELAY=""
  PANEL_PROBE_STATUS_CODE=""

  outbound_json="$(load_outbound_json "$cfg" "$tag")" || return 1
  [[ -n "$outbound_json" ]] || return 1
  all_outbounds="$(all_outbounds_json "$cfg")" || return 1
  [[ -n "$all_outbounds" ]] || return 1

  body_file="$(mktemp)"
  http_code="$({
    curl -sS -o "$body_file" -w "%{http_code}" \
      -b "$COOKIE_JAR" \
      -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
      -X POST "${PANEL_URL}/panel/xray/testOutbound" \
      --data-urlencode "outbound=${outbound_json}" \
      --data-urlencode "allOutbounds=${all_outbounds}"
  } || true)"

  if [[ "$http_code" != "200" ]]; then
    rm -f "$body_file"
    PANEL_PROBE_STATE="error"
    return 1
  fi

  if ! jq empty "$body_file" >/dev/null 2>&1; then
    rm -f "$body_file"
    PANEL_PROBE_STATE="error"
    return 1
  fi

  PANEL_PROBE_DELAY="$(jq -r '.obj.delay // empty' "$body_file" 2>/dev/null || true)"
  PANEL_PROBE_STATUS_CODE="$(jq -r '.obj.statusCode // empty' "$body_file" 2>/dev/null || true)"

  if jq -e '.success == true and (.obj.success == true)' "$body_file" >/dev/null 2>&1; then
    PANEL_PROBE_STATE="success"
    rm -f "$body_file"
    return 0
  fi

  if jq -e '.success == true and (.obj.success == false or .obj.success == null)' "$body_file" >/dev/null 2>&1; then
    PANEL_PROBE_STATE="fail"
    rm -f "$body_file"
    return 1
  fi

  PANEL_PROBE_STATE="error"
  rm -f "$body_file"
  return 1
}

probe_tcp_endpoint() {
  local host="$1" port="$2"
  timeout "$PROBE_TIMEOUT" bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1
}

build_probe_config() {
  local cfg="$1" tag="$2" probe_dir="$3" port="$4"
  local outbound_json
  outbound_json="$(load_outbound_json "$cfg" "$tag")"
  [[ -n "$outbound_json" ]] || return 1

  jq -n \
    --argjson outbound "$outbound_json" \
    --arg tag "$tag" \
    --argjson port "$port" '
    {
      log: {access: "none", dnsLog: false, loglevel: "warning"},
      inbounds: [
        {
          tag: "probe-socks",
          listen: "127.0.0.1",
          port: $port,
          protocol: "socks",
          settings: {auth: "noauth", udp: false}
        }
      ],
      outbounds: [$outbound],
      routing: {
        domainStrategy: "AsIs",
        rules: [
          {type: "field", inboundTag: ["probe-socks"], outboundTag: $tag}
        ]
      }
    }
  ' > "${probe_dir}/config.json"
}

probe_url_through_proxy() {
  local port="$1" url="$2"
  timeout "$PROBE_TIMEOUT" curl -sS -o /dev/null \
    --proxy "socks5h://127.0.0.1:${port}" \
    --max-time "$PROBE_TIMEOUT" \
    -L -f "$url"
}

probe_http_through_xray() {
  local cfg="$1" tag="$2"
  local probe_dir port xpid rc url
  local -a urls

  probe_dir="$(mktemp -d "${TMP_BASE}/probe-XXXXXX")"
  port=$((RANDOM % 10000 + 20000))

  build_probe_config "$cfg" "$tag" "$probe_dir" "$port" || { rm -rf "$probe_dir"; return 1; }
  validate_config "${probe_dir}/config.json" || { rm -rf "$probe_dir"; return 1; }

  "$XRAY_BIN" run -config "${probe_dir}/config.json" >"${probe_dir}/stdout.log" 2>"${probe_dir}/stderr.log" &
  xpid=$!
  sleep 1

  rc=1
  IFS=',' read -r -a urls <<< "$PROBE_URLS"
  for url in "${urls[@]}"; do
    url="$(printf '%s' "$url" | trim_spaces)"
    [[ -n "$url" ]] || continue
    if probe_url_through_proxy "$port" "$url"; then
      rc=0
      break
    fi
  done

  kill "$xpid" >/dev/null 2>&1 || true
  wait "$xpid" >/dev/null 2>&1 || true
  rm -rf "$probe_dir"
  [[ $rc -eq 0 ]]
}

probe_tag() {
  local cfg="$1" tag="$2"
  local address port

  case "${PROBE_MODE:-panel}" in
    panel)
      if panel_test_outbound "$cfg" "$tag"; then
        return 0
      fi
      if [[ "$PANEL_PROBE_STATE" == "fail" ]]; then
        return 1
      fi
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
    http)
      probe_http_through_xray "$cfg" "$tag"
      ;;
    *)
      return 1
      ;;
  esac
}

inc_fail() {
  local tag="$1"
  state_set --arg t "$tag" '.fail_counts[$t] = ((.fail_counts[$t] // 0) + 1) | .success_counts[$t] = 0'
}

inc_success() {
  local tag="$1"
  state_set --arg t "$tag" '.success_counts[$t] = ((.success_counts[$t] // 0) + 1) | .fail_counts[$t] = 0'
}

reset_counts() {
  local tag="$1"
  state_set --arg t "$tag" '.success_counts[$t] = 0 | .fail_counts[$t] = 0'
}

get_fail_count() { state_get --arg t "$1" '.fail_counts[$t] // 0'; }
get_success_count() { state_get --arg t "$1" '.success_counts[$t] // 0'; }
get_current_state_tag() { state_get '.current'; }
get_last_switch_ts() { state_get '.last_switch_ts'; }

set_current() {
  local tag="$1" now
  now="$(date +%s)"
  state_set --arg t "$tag" --argjson now "$now" '.current = $t | .last_switch_ts = $now'
}

choose_best_available() {
  local tag s
  for tag in "${PRIORITY_TAGS[@]}"; do
    s="$(get_success_count "$tag")"
    if [[ "$s" =~ ^[0-9]+$ ]] && (( s >= 1 )); then
      echo "$tag"
      return 0
    fi
  done
  echo ""
}

apply_switch() {
  local api_cfg="$1" new_tag="$2"
  local idx tmp_cfg backup

  idx="$(find_target_rule_index "$api_cfg")"
  [[ "$idx" != "-1" ]] || die "Target routing rule not found." || return 1

  tmp_cfg="$(mktemp)"
  jq --argjson idx "$idx" --arg tag "$new_tag" '.routing.rules[$idx].outboundTag = $tag' "$api_cfg" > "$tmp_cfg" || {
    rm -f "$tmp_cfg"
    die "Failed to build modified config." || return 1
  }

  if ! validate_config "$tmp_cfg"; then
    rm -f "$tmp_cfg"
    die "Modified config failed validation." || return 1
  fi

  backup="$(backup_config)"
  cp -f "$tmp_cfg" "$CONFIG_PATH"
  rm -f "$tmp_cfg"

  if restart_xray_with_fallback; then
    action_log "SWITCH OK: active outbound changed to [$new_tag], backup=[$backup]"
    set_current "$new_tag"
    return 0
  fi

  log "ERROR: restart failed, restoring backup"
  cp -f "$backup" "$CONFIG_PATH"
  restart_xray_with_fallback || true
  die "Switch failed and backup was restored." || return 1
}

perform_failover_check() {
  require_root || return 1
  ensure_lock || return 1
  load_env

  [[ -f "$ENV_FILE" ]] || die "Configuration not found. Run Install / Reconfigure first." || return 1
  validate_local_paths || return 1

  panel_login || die "3x-ui login failed. Check PANEL_URL, username, or password." || return 1

  local api_cfg
  api_cfg="$(mktemp)"
  panel_get_config "$api_cfg" || { rm -f "$api_cfg"; die "Could not download config.json from 3x-ui API." || return 1; }

  read_priority_tags_from_config "$api_cfg" || { rm -f "$api_cfg"; return 1; }
  init_state
  sync_state_tags

  local current_cfg_tag current_state_tag
  current_cfg_tag="$(get_current_active_tag_from_config "$api_cfg")"
  [[ -n "$current_cfg_tag" && "$current_cfg_tag" != "null" ]] || { rm -f "$api_cfg"; die "Could not detect current active outboundTag from routing rules." || return 1; }

  current_state_tag="$(get_current_state_tag)"
  if [[ "$current_state_tag" == "null" || -z "$current_state_tag" ]]; then
    set_current "$current_cfg_tag"
    log "state initialized from config: $current_cfg_tag"
  elif [[ "$current_state_tag" != "$current_cfg_tag" ]]; then
    state_set --arg t "$current_cfg_tag" '.current = $t'
    log "state synchronized from config: $current_cfg_tag"
  fi

  local tag
  for tag in "${PRIORITY_TAGS[@]}"; do
    if load_outbound_json "$api_cfg" "$tag" >/dev/null; then
      if probe_tag "$api_cfg" "$tag"; then
        if [[ "${PROBE_MODE:-panel}" == "panel" && "$PANEL_PROBE_STATE" == "success" ]]; then
          inc_success "$tag"
          log "probe success: $tag (mode=panel, delay=${PANEL_PROBE_DELAY:-na}, statusCode=${PANEL_PROBE_STATUS_CODE:-na}, success=$(get_success_count "$tag"))"
        else
          inc_success "$tag"
          log "probe success: $tag (mode=${PROBE_MODE}, success=$(get_success_count "$tag"))"
        fi
      else
        inc_fail "$tag"
        if [[ "${PROBE_MODE:-panel}" == "panel" ]]; then
          log "probe fail: $tag (mode=panel, state=${PANEL_PROBE_STATE:-unknown}, fail=$(get_fail_count "$tag"))"
        else
          log "probe fail: $tag (mode=${PROBE_MODE}, fail=$(get_fail_count "$tag"))"
        fi
      fi
    fi
  done

  local now last_switch can_switch current_fail desired_tag curr_idx i candidate succ best
  now="$(date +%s)"
  last_switch="$(get_last_switch_ts)"
  can_switch=0
  (( now - last_switch >= MIN_SWITCH_GAP )) && can_switch=1

  current_fail="$(get_fail_count "$current_cfg_tag")"
  desired_tag="$current_cfg_tag"
  curr_idx="$(priority_index "$current_cfg_tag")"

  if (( curr_idx > 0 )); then
    for ((i=0; i<curr_idx; i++)); do
      candidate="${PRIORITY_TAGS[$i]}"
      succ="$(get_success_count "$candidate")"
      if (( succ >= RECOVER_THRESHOLD )); then
        desired_tag="$candidate"
        break
      fi
    done
  fi

  if (( current_fail >= FAIL_THRESHOLD )); then
    best="$(choose_best_available)"
    [[ -n "$best" ]] && desired_tag="$best"
  fi

  if [[ "$desired_tag" != "$current_cfg_tag" ]]; then
    if (( can_switch == 1 )); then
      action_log "switch requested: current=[$current_cfg_tag], desired=[$desired_tag], current_fail=[$current_fail]"
      apply_switch "$api_cfg" "$desired_tag" && reset_counts "$desired_tag"
    else
      log "switch suppressed by MIN_SWITCH_GAP: current=[$current_cfg_tag], desired=[$desired_tag]"
    fi
  else
    log "no switch needed: current=[$current_cfg_tag]"
  fi

  rm -f "$api_cfg"
  return 0
}

write_systemd_files() {
  cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=${APP_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/xui-switcher.sh run-now
User=root
Group=root
SERVICE

  cat > "$TIMER_FILE" <<TIMER
[Unit]
Description=Run ${APP_NAME} every 20 seconds

[Timer]
OnBootSec=20s
OnUnitActiveSec=20s
AccuracySec=1s
Unit=${APP_NAME}.service

[Install]
WantedBy=timers.target
TIMER

  systemctl daemon-reload >/dev/null 2>&1 || return 1
}

validate_install_inputs() {
  validate_url "$PANEL_URL" || die "Invalid PANEL_URL. Example: http://127.0.0.1:2090/ach" || return 1
  validate_local_paths || return 1
  case "${PROBE_MODE:-panel}" in
    panel|tcp) ;;
    http)
      validate_probe_urls "$PROBE_URLS" || die "Probe URLs must be comma-separated http/https URLs." || return 1
      ;;
    *)
      die "Unsupported probe mode: ${PROBE_MODE}" || return 1
      ;;
  esac
  panel_login || die "Login test failed. Verify panel URL, username, and password." || return 1

  local tmp_cfg
  tmp_cfg="$(mktemp)"
  panel_get_config "$tmp_cfg" || { rm -f "$tmp_cfg"; die "Could not fetch config via 3x-ui API. Check the panel URL and base path." || return 1; }
  read_priority_tags_from_config "$tmp_cfg" || { rm -f "$tmp_cfg"; return 1; }

  if [[ "${PROBE_MODE:-panel}" == "panel" ]]; then
    local first_tag
    first_tag="${PRIORITY_TAGS[0]}"
    if ! panel_test_outbound "$tmp_cfg" "$first_tag"; then
      if [[ "$PANEL_PROBE_STATE" == "error" ]]; then
        warn "3x-ui panel outbound test endpoint did not validate cleanly during setup. The switcher will fall back to tcp if panel probe errors later."
      fi
    fi
  fi

  rm -f "$tmp_cfg"
}

configure_probe_urls() {
  local default_urls="${PROBE_URLS:-https://cp.cloudflare.com/generate_204,http://connectivitycheck.gstatic.com/generate_204,https://www.msftconnecttest.com/connecttest.txt}"
  while true; do
    PROBE_URLS="$(prompt_nonempty 'HTTP probe URLs (comma-separated, reachable through outbounds)' "$default_urls")"
    PROBE_URLS="$(printf '%s' "$PROBE_URLS" | tr -d ' ')"
    if validate_probe_urls "$PROBE_URLS"; then
      break
    fi
    err "Please enter valid comma-separated http/https URLs."
  done
}

show_detected_tags() {
  local cfg="$1"
  read_priority_tags_from_config "$cfg" || return 1
  printf ' - %s\n' "${PRIORITY_TAGS[@]}"
}

interactive_install_or_reconfigure() {
  require_root || return 1
  ensure_dependencies || return 1
  detect_defaults
  load_env

  while true; do
    header
    say "${COL_GREEN}Install / Reconfigure${COL_RESET}"
    say "Leave password empty to keep the current saved password."
    say "Default probe mode is panel, using the same outbound test endpoint as 3x-ui."
    echo

    PANEL_URL="$(prompt_nonempty '3x-ui panel base URL' "${PANEL_URL:-http://127.0.0.1:2053}")"
    PANEL_URL="$(normalize_url "$PANEL_URL")"
    while ! validate_url "$PANEL_URL"; do
      err "Invalid URL. Example: http://193.242.125.37:2090/ach"
      PANEL_URL="$(prompt_nonempty '3x-ui panel base URL' "http://127.0.0.1:2053")"
      PANEL_URL="$(normalize_url "$PANEL_URL")"
    done

    PANEL_USERNAME="$(prompt_nonempty '3x-ui username' "${PANEL_USERNAME:-admin}")"
    while true; do
      read -r -s -p "3x-ui password [leave empty to keep current if set]: " input_password
      echo
      PANEL_PASSWORD="${input_password:-${PANEL_PASSWORD:-}}"
      if [[ -n "$PANEL_PASSWORD" ]]; then
        break
      fi
      err "Password cannot be empty."
    done

    CONFIG_PATH="$(prompt_nonempty 'config.json path' "${CONFIG_PATH:-${DETECTED_CONFIG_PATH:-$DEFAULT_CONFIG_PATH}}")"
    XRAY_BIN="$(prompt_nonempty 'xray binary path' "${XRAY_BIN:-${DETECTED_XRAY_BIN:-$DEFAULT_XRAY_BIN}}")"

    FAIL_THRESHOLD="$(prompt_number 'Fail threshold (consecutive fails before switch)' "${FAIL_THRESHOLD:-3}")"
    RECOVER_THRESHOLD="$(prompt_number 'Recover threshold (consecutive successes before switch back)' "${RECOVER_THRESHOLD:-2}")"
    MIN_SWITCH_GAP="$(prompt_number 'Minimum seconds between switches' "${MIN_SWITCH_GAP:-60}")"
    PROBE_TIMEOUT="$(prompt_number 'Probe timeout in seconds' "${PROBE_TIMEOUT:-8}")"
    PROBE_MODE="$(prompt_probe_mode "${PROBE_MODE:-panel}")"
    if [[ "$PROBE_MODE" == "http" ]]; then
      configure_probe_urls
    else
      PROBE_URLS="${PROBE_URLS:-https://cp.cloudflare.com/generate_204,http://connectivitycheck.gstatic.com/generate_204,https://www.msftconnecttest.com/connecttest.txt}"
    fi

    mkdir -p "$INSTALL_DIR" "$ENV_DIR" "$STATE_DIR" "$LOG_DIR"
    save_env
    write_systemd_files || { err "Could not write systemd files."; pause; continue; }
    load_env

    if validate_install_inputs; then
      ln -sf "${INSTALL_DIR}/xui-switcher.sh" "$SYMLINK_PATH"
      success "Configuration saved."
      local cfg
      cfg="$(mktemp)"
      if panel_get_config "$cfg"; then
        info "Detected prioritized outbounds from config:"
        show_detected_tags "$cfg" || true
      fi
      rm -f "$cfg"

      if prompt_yes_no "Enable auto-run timer now?" "Y"; then
        systemctl enable --now "${APP_NAME}.timer" >/dev/null 2>&1 && success "Timer enabled." || warn "Could not enable timer."
      else
        systemctl disable --now "${APP_NAME}.timer" >/dev/null 2>&1 || true
        warn "Timer left disabled."
      fi

      if prompt_yes_no "Run one health check now?" "Y"; then
        if perform_failover_check; then
          success "Health check finished."
        else
          err "Health check failed. Review the log or configuration."
        fi
      fi
      return 0
    fi

    err "Configuration validation failed. Please review your input and try again."
    if ! prompt_yes_no "Retry configuration now?" "Y"; then
      return 1
    fi
  done
}

show_current_config() {
  require_root || return 1
  load_env
  header
  [[ -f "$ENV_FILE" ]] || die "Configuration not found." || return 1

  cat <<OUT
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
PROBE_URLS         : ${PROBE_URLS}
ENV_FILE           : ${ENV_FILE}
STATE_FILE         : ${STATE_FILE}
SCRIPT_LOG         : ${SCRIPT_LOG}
ACTION_LOG         : ${ACTION_LOG}
OUT

  if [[ -f "$CONFIG_PATH" ]]; then
    echo
    echo "Current active outbound rule:"
    jq -r '.routing.rules | [ .[] | select(has("outboundTag") and has("network")) ] | last' "$CONFIG_PATH"
  fi

  echo
  echo "Detected prioritized tags from current config:"
  local cfg
  cfg="$(mktemp)"
  if panel_login && panel_get_config "$cfg"; then
    show_detected_tags "$cfg" || true
  else
    warn "Could not fetch tags from panel API right now."
  fi
  rm -f "$cfg"
  return 0
}

validate_current_config() {
  require_root || return 1
  load_env
  [[ -f "$ENV_FILE" ]] || die "Configuration not found." || return 1
  validate_local_paths || return 1
  if validate_config "$CONFIG_PATH"; then
    success "Xray config validation passed."
    return 0
  fi
  die "Xray config validation failed." || return 1
}

show_status() {
  require_root || return 1
  header
  systemctl status "${APP_NAME}.timer" --no-pager || true
  echo
  systemctl status "${APP_NAME}.service" --no-pager || true
}

show_logs() {
  require_root || return 1
  if [[ ! -f "$SCRIPT_LOG" ]]; then
    warn "No log file yet: $SCRIPT_LOG"
    return 0
  fi
  tail -n 100 -f "$SCRIPT_LOG"
}

start_service() {
  require_root || return 1
  systemctl start "${APP_NAME}.service" >/dev/null 2>&1 || return 1
  success "Service executed once."
}

stop_timer() {
  require_root || return 1
  systemctl disable --now "${APP_NAME}.timer" >/dev/null 2>&1 || true
  success "Timer stopped and disabled."
}

restart_timer() {
  require_root || return 1
  systemctl restart "${APP_NAME}.timer" >/dev/null 2>&1 || return 1
  success "Timer restarted."
}

enable_timer() {
  require_root || return 1
  systemctl enable --now "${APP_NAME}.timer" >/dev/null 2>&1 || return 1
  success "Timer enabled."
}

disable_timer() {
  require_root || return 1
  systemctl disable --now "${APP_NAME}.timer" >/dev/null 2>&1 || true
  success "Timer disabled."
}

uninstall_app() {
  require_root || return 1
  if [[ -x "${INSTALL_DIR}/uninstall.sh" ]]; then
    exec "${INSTALL_DIR}/uninstall.sh"
  fi
  die "uninstall.sh not found in ${INSTALL_DIR}" || return 1
}

menu_action() {
  local label="$1"
  shift
  LAST_ERROR=""
  if "$@"; then
    return 0
  fi
  err "${label} failed. ${LAST_ERROR:-Review the output above.}"
  return 1
}

menu() {
  while true; do
    header
    cat <<MENU
1) Install / Reconfigure
2) Show current config
3) Validate current Xray config
4) Start one check now
5) Start service once
6) Stop auto-run timer
7) Restart auto-run timer
8) Show status
9) Show logs
10) Enable auto-run timer
11) Disable auto-run timer
12) Uninstall
0) Exit
MENU
    echo
    read -r -p "Choose an option: " choice
    case "$choice" in
      1) menu_action "Install / Reconfigure" interactive_install_or_reconfigure; pause ;;
      2) menu_action "Show current config" show_current_config; pause ;;
      3) menu_action "Validate current Xray config" validate_current_config; pause ;;
      4) menu_action "Run health check" perform_failover_check && success "Check finished."; pause ;;
      5) menu_action "Start service once" start_service; pause ;;
      6) menu_action "Stop auto-run timer" stop_timer; pause ;;
      7) menu_action "Restart auto-run timer" restart_timer; pause ;;
      8) menu_action "Show status" show_status; pause ;;
      9) show_logs ;;
      10) menu_action "Enable auto-run timer" enable_timer; pause ;;
      11) menu_action "Disable auto-run timer" disable_timer; pause ;;
      12) uninstall_app ;;
      0) exit 0 ;;
      *) err "Invalid choice. Please enter a valid menu number."; sleep 1 ;;
    esac
  done
}

usage() {
  cat <<USAGE
${APP_NAME} ${APP_VERSION}
Usage:
  ${APP_NAME}                 Open interactive menu
  ${APP_NAME} install         Install or reconfigure interactively
  ${APP_NAME} show-config     Show current saved configuration
  ${APP_NAME} validate        Validate local Xray config
  ${APP_NAME} run-now         Run one failover check now
  ${APP_NAME} start           Start the systemd service once
  ${APP_NAME} stop            Stop and disable the timer
  ${APP_NAME} restart         Restart the timer
  ${APP_NAME} status          Show systemd status
  ${APP_NAME} logs            Tail the main log file
  ${APP_NAME} enable          Enable and start the timer
  ${APP_NAME} disable         Disable and stop the timer
  ${APP_NAME} uninstall       Uninstall the application
  ${APP_NAME} version         Show version
USAGE
}

main() {
  local cmd="${1:-menu}"
  case "$cmd" in
    menu) menu ;;
    install|reconfigure) interactive_install_or_reconfigure ;;
    show-config) show_current_config ;;
    validate) validate_current_config ;;
    run-now) perform_failover_check ;;
    start) start_service ;;
    stop) stop_timer ;;
    restart) restart_timer ;;
    status) show_status ;;
    logs) show_logs ;;
    enable) enable_timer ;;
    disable) disable_timer ;;
    uninstall) uninstall_app ;;
    version|--version|-v) echo "$APP_VERSION" ;;
    help|--help|-h) usage ;;
    *) usage; return 1 ;;
  esac
}

main "$@"
