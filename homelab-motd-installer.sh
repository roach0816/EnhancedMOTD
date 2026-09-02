#!/usr/bin/env bash
# Homelab MOTD installer
# Supports Debian, Ubuntu, and Raspberry Pi OS systems using systemd and PAM MOTD.

set -Eeuo pipefail

readonly INSTALLER_VERSION="1.1.0"
readonly PROJECT_URL="https://github.com/roach0816/EnhancedMOTD"
readonly RUNTIME_PATH="/usr/local/libexec/homelab-motd"
readonly CONTROL_PATH="/usr/local/sbin/motdctl"
readonly CONFIG_PATH="/etc/default/homelab-motd"
readonly FRAGMENT_PATH="/etc/update-motd.d/00-homelab-motd"
readonly SERVICE_PATH="/etc/systemd/system/homelab-motd-refresh.service"
readonly TIMER_PATH="/etc/systemd/system/homelab-motd-refresh.timer"
readonly UPDATE_SERVICE_PATH="/etc/systemd/system/homelab-motd-update.service"
readonly UPDATE_TIMER_PATH="/etc/systemd/system/homelab-motd-update.timer"
readonly STATE_DIR="/var/lib/homelab-motd"
readonly CACHE_DIR="/var/cache/homelab-motd"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m OK\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Homelab MOTD self-contained installer

Usage:
  sudo bash homelab-motd-installer.sh [--install]
       bash homelab-motd-installer.sh --preview
  sudo bash homelab-motd-installer.sh --uninstall
       bash homelab-motd-installer.sh --self-test
       bash homelab-motd-installer.sh --version
       bash homelab-motd-installer.sh --help

Options:
  --install      Install or upgrade Homelab MOTD (default)
  --preview      Render a preview without changing the system
  --uninstall    Remove Homelab MOTD and restore the prior MOTD
  --self-test    Validate embedded scripts, units, and local rendering
  --version      Show the installer version
  --help         Show this help
EOF
}

require_root() {
  (( EUID == 0 )) || die "Run this operation with sudo."
}

check_install_requirements() {
  local -a missing_packages=()

  command -v systemctl >/dev/null 2>&1 || missing_packages+=(systemd)
  command -v systemd-analyze >/dev/null 2>&1 || missing_packages+=(systemd)
  command -v run-parts >/dev/null 2>&1 || missing_packages+=(debianutils)
  command -v ip >/dev/null 2>&1 || missing_packages+=(iproute2)
  command -v flock >/dev/null 2>&1 || missing_packages+=(util-linux)

  if ((${#missing_packages[@]} > 0)); then
    local packages
    packages=$(printf '%s\n' "${missing_packages[@]}" | LC_ALL=C sort -u | paste -sd' ' -)
    die "Missing required package(s): $packages. Install them with: apt-get update && apt-get install $packages"
  fi

  [[ -d /run/systemd/system ]] || die "systemd is not running. Install from a booted Debian-family host, not a chroot or build container."
}

write_runtime() {
  local destination=$1
  cat >"$destination" <<'RUNTIME_EOF'
#!/usr/bin/env bash

set -uo pipefail

readonly MOTD_VERSION="1.1.0"
readonly PROJECT_URL="https://github.com/roach0816/EnhancedMOTD"
readonly VERSION_URL="https://raw.githubusercontent.com/roach0816/EnhancedMOTD/main/VERSION"
readonly INSTALLER_URL="https://raw.githubusercontent.com/roach0816/EnhancedMOTD/main/homelab-motd-installer.sh"
readonly CONFIG_FILE="/etc/default/homelab-motd"
readonly CACHE_DIR="/var/cache/homelab-motd"
readonly CACHE_FILE="${CACHE_DIR}/apt-cache"
readonly RELEASE_CACHE_FILE="${CACHE_DIR}/release-cache"
readonly STATE_DIR="/var/lib/homelab-motd"
readonly DISABLED_FILE="${STATE_DIR}/disabled-fragments.tsv"
readonly DISABLED_SYMLINKS_FILE="${STATE_DIR}/disabled-symlinks.tsv"
readonly MOTD_FRAGMENT="/etc/update-motd.d/00-homelab-motd"
readonly RUNTIME_PATH="/usr/local/libexec/homelab-motd"
readonly CONTROL_PATH="/usr/local/sbin/motdctl"
readonly SERVICE_PATH="/etc/systemd/system/homelab-motd-refresh.service"
readonly TIMER_PATH="/etc/systemd/system/homelab-motd-refresh.timer"
readonly UPDATE_SERVICE_PATH="/etc/systemd/system/homelab-motd-update.service"
readonly UPDATE_TIMER_PATH="/etc/systemd/system/homelab-motd-update.timer"

# Defaults are intentionally useful even if an older configuration lacks a setting.
COLOR="auto"
UNICODE="auto"
DISPLAY_WIDTH=78
DISK_WARNING_PERCENT=80
DISK_CRITICAL_PERCENT=90
MEMORY_WARNING_PERCENT=85
MEMORY_CRITICAL_PERCENT=95
TEMPERATURE_WARNING_C=75
TEMPERATURE_CRITICAL_C=85
CACHE_STALE_HOURS=12
SECURITY_UPDATES_ARE_WARNING=1
REBOOT_REQUIRED_IS_WARNING=1
SHOW_DOWN_INTERFACES=1
SHOW_VIRTUAL_INTERFACES=0
SHOW_PROCESS_COUNT=1
CHECK_FOR_UPDATES=1
AUTO_UPDATE=0

load_config() {
  if [[ -r "$CONFIG_FILE" ]]; then
    # This root-owned file contains simple administrator-controlled shell assignments.
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi

  sanitize_integer DISPLAY_WIDTH 78 60 110
  sanitize_integer DISK_WARNING_PERCENT 80 1 100
  sanitize_integer DISK_CRITICAL_PERCENT 90 1 100
  sanitize_integer MEMORY_WARNING_PERCENT 85 1 100
  sanitize_integer MEMORY_CRITICAL_PERCENT 95 1 100
  sanitize_integer TEMPERATURE_WARNING_C 75 1 150
  sanitize_integer TEMPERATURE_CRITICAL_C 85 1 150
  sanitize_integer CACHE_STALE_HOURS 12 1 720
  sanitize_integer SECURITY_UPDATES_ARE_WARNING 1 0 1
  sanitize_integer REBOOT_REQUIRED_IS_WARNING 1 0 1
  sanitize_integer SHOW_DOWN_INTERFACES 1 0 1
  sanitize_integer SHOW_VIRTUAL_INTERFACES 0 0 1
  sanitize_integer SHOW_PROCESS_COUNT 1 0 1
  sanitize_integer CHECK_FOR_UPDATES 1 0 1
  sanitize_integer AUTO_UPDATE 0 0 1
}

sanitize_integer() {
  local name=$1 default=$2 minimum=$3 maximum=$4 value=${!1:-}
  if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < minimum || value > maximum )); then
    printf -v "$name" '%s' "$default"
  fi
}

load_config

supports_color() {
  case "$COLOR" in
    1|yes|true|always) return 0 ;;
    0|no|false|never) return 1 ;;
  esac
  [[ -z "${NO_COLOR:-}" ]] || return 1
  # pam_motd can run before sshd supplies TERM and locale variables.
  [[ "${HOMELAB_MOTD_LOGIN:-0}" == 1 || "${TERM:-dumb}" != "dumb" ]]
}

supports_unicode() {
  case "$UNICODE" in
    1|yes|true|always) return 0 ;;
    0|no|false|never) return 1 ;;
  esac
  [[ "${HOMELAB_MOTD_LOGIN:-0}" == 1 ]] || \
    [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" =~ ([Uu][Tt][Ff]-?8) ]]
}

if supports_color; then
  readonly RESET=$'\033[0m'
  readonly BOLD=$'\033[1m'
  readonly DIM=$'\033[2m'
  readonly GREEN=$'\033[38;5;71m'
  readonly YELLOW=$'\033[38;5;178m'
  readonly RED=$'\033[38;5;167m'
  readonly BLUE=$'\033[38;5;74m'
  readonly LABEL=$'\033[38;5;143m'
  readonly MUTED=$'\033[38;5;245m'
else
  readonly RESET="" BOLD="" DIM="" GREEN="" YELLOW="" RED="" BLUE="" LABEL="" MUTED=""
fi

if supports_unicode; then
  readonly TL="╭" TR="╮" BL="╰" BR="╯" H="─" V="│" LT="├" RT="┤"
  readonly HEALTHY_MARK="●" WARNING_MARK="!" CRITICAL_MARK="✕"
  readonly SEP=" • " DEGREE="°" TITLE_DASH="—"
else
  readonly TL="+" TR="+" BL="+" BR="+" H="-" V="|" LT="+" RT="+"
  readonly HEALTHY_MARK="*" WARNING_MARK="!" CRITICAL_MARK="X"
  readonly SEP=" | " DEGREE="" TITLE_DASH="-"
fi

repeat_char() {
  local char=$1 count=$2 output=""
  (( count < 0 )) && count=0
  printf -v output '%*s' "$count" ''
  printf '%s' "${output// /$char}"
}

strip_ansi() {
  sed $'s/\033\\[[0-9;]*m//g' <<<"$1"
}

visible_length() {
  local clean
  clean=$(strip_ansi "$1")
  printf '%s' "$clean" | wc -m | tr -d ' '
}

clip_text() {
  local text=$1 max=$2
  if (( ${#text} <= max )); then
    printf '%s' "$text"
  elif (( max > 3 )); then
    printf '%s...' "${text:0:max-3}"
  else
    printf '%s' "${text:0:max}"
  fi
}

terminal_width() {
  local width=${COLUMNS:-0} tty_size=""
  if [[ -n "${SSH_TTY:-}" && -c "${SSH_TTY}" ]]; then
    tty_size=$(stty -F "$SSH_TTY" size 2>/dev/null || true)
    [[ "$tty_size" =~ ^[0-9]+[[:space:]]+([0-9]+)$ ]] && width=${BASH_REMATCH[1]}
  fi
  [[ "$width" =~ ^[0-9]+$ ]] || width=0
  (( width < 40 )) && width=$DISPLAY_WIDTH
  (( width > DISPLAY_WIDTH )) && width=$DISPLAY_WIDTH
  printf '%s' "$width"
}

WIDTH=$(terminal_width)
INNER=$((WIDTH - 2))

box_top() {
  local title=$1 max_title=$((INNER - 4)) plain_title
  plain_title=$(clip_text "$title" "$max_title")
  printf '%s%s %s %s%s\n' "$BLUE$TL" "$H" "$BOLD$plain_title$RESET$BLUE" \
    "$(repeat_char "$H" $((INNER - ${#plain_title} - 3)))" "$TR$RESET"
}

box_rule() {
  printf '%s%s%s%s\n' "$BLUE$LT" "$(repeat_char "$H" "$INNER")" "$RT" "$RESET"
}

box_section() {
  local title=$1 title_text remaining
  title_text=" $title "
  remaining=$((INNER - ${#title_text} - 1))
  (( remaining < 0 )) && remaining=0
  printf '%s%s%s%s%s%s\n' "$BLUE$LT" "$H" "$BOLD$title_text$RESET$BLUE" \
    "$(repeat_char "$H" "$remaining")" "$RT" "$RESET"
}

box_line() {
  local content=$1 len padding clean max_content=$((INNER - 2))
  len=$(visible_length "$content")
  if (( len > max_content )); then
    clean=$(strip_ansi "$content")
    content=$(clip_text "$clean" "$max_content")
    len=${#content}
  fi
  padding=$((INNER - len - 2))
  (( padding < 0 )) && padding=0
  printf '%s%s%s  %s%s%s\n' "$BLUE" "$V" "$RESET" "$content" \
    "$(repeat_char ' ' "$padding")" "$BLUE$V$RESET"
}

box_blank() { box_line ""; }

box_bottom() {
  printf '%s%s%s%s\n' "$BLUE$BL" "$(repeat_char "$H" "$INNER")" "$BR" "$RESET"
}

human_kib() {
  local kib=${1:-0}
  awk -v k="$kib" 'BEGIN {
    if (k >= 1073741824) printf "%.1f TiB", k/1073741824;
    else if (k >= 1048576) printf "%.1f GiB", k/1048576;
    else if (k >= 1024) printf "%.1f MiB", k/1024;
    else printf "%d KiB", k;
  }'
}

format_duration() {
  local total=${1:-0} days hours minutes
  days=$((total / 86400))
  hours=$(((total % 86400) / 3600))
  minutes=$(((total % 3600) / 60))
  if (( days > 0 )); then
    printf '%dd %02dh' "$days" "$hours"
  elif (( hours > 0 )); then
    printf '%dh %02dm' "$hours" "$minutes"
  else
    printf '%dm' "$minutes"
  fi
}

format_age() {
  local seconds=${1:-0} days hours minutes
  (( seconds < 0 )) && seconds=0
  days=$((seconds / 86400))
  hours=$(((seconds % 86400) / 3600))
  minutes=$(((seconds % 3600) / 60))
  if (( days > 0 )); then
    printf '%dd %dh ago' "$days" "$hours"
  elif (( hours > 0 )); then
    printf '%dh %dm ago' "$hours" "$minutes"
  elif (( minutes > 0 )); then
    printf '%dm ago' "$minutes"
  else
    printf 'just now'
  fi
}

read_os_release() {
  OS_PRETTY="Linux"
  OS_ID="linux"
  OS_VERSION=""
  OS_CODENAME=""
  if [[ -r /etc/os-release ]]; then
    while IFS='=' read -r key value; do
      value=${value%\"}; value=${value#\"}
      case "$key" in
        PRETTY_NAME) OS_PRETTY=$value ;;
        ID) OS_ID=$value ;;
        VERSION_ID) OS_VERSION=$value ;;
        VERSION_CODENAME|UBUNTU_CODENAME) [[ -z "$OS_CODENAME" ]] && OS_CODENAME=$value ;;
      esac
    done </etc/os-release
  fi
}

hardware_model() {
  local model=""
  if [[ -r /sys/firmware/devicetree/base/model ]]; then
    model=$(tr -d '\000' </sys/firmware/devicetree/base/model 2>/dev/null || true)
  elif [[ -r /sys/class/dmi/id/product_name ]]; then
    model=$(tr -d '\n' </sys/class/dmi/id/product_name 2>/dev/null || true)
  fi
  [[ -n "$model" ]] || model=$(uname -m)
  printf '%s' "$model"
}

read_temperature() {
  local raw="" zone type
  if command -v vcgencmd >/dev/null 2>&1; then
    raw=$(vcgencmd measure_temp 2>/dev/null | sed -n "s/.*=\([0-9.]*\).*/\1/p" || true)
  fi
  if [[ -z "$raw" ]]; then
    for zone in /sys/class/thermal/thermal_zone*; do
      [[ -r "$zone/temp" ]] || continue
      type=$(cat "$zone/type" 2>/dev/null || true)
      [[ "$type" =~ ([Cc][Pp][Uu]|[Ss][Oo][Cc]|x86_pkg|package) ]] || continue
      raw=$(<"$zone/temp")
      [[ "$raw" =~ ^[0-9]+$ ]] || { raw=""; continue; }
      (( raw > 1000 )) && raw=$(awk -v t="$raw" 'BEGIN { printf "%.1f", t/1000 }')
      break
    done
  fi
  [[ "$raw" =~ ^[0-9]+([.][0-9]+)?$ ]] && printf '%s' "$raw"
}

read_package_cache() {
  UPDATE_COUNT="?"
  SECURITY_COUNT="?"
  CACHE_LAST_SUCCESS=0
  CACHE_LAST_ATTEMPT=0
  CACHE_STATUS="missing"
  [[ -r "$CACHE_FILE" ]] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      UPDATE_COUNT) [[ "$value" =~ ^[0-9]+$ ]] && UPDATE_COUNT=$value ;;
      SECURITY_COUNT) [[ "$value" =~ ^[0-9]+$ ]] && SECURITY_COUNT=$value ;;
      LAST_SUCCESS_EPOCH) [[ "$value" =~ ^[0-9]+$ ]] && CACHE_LAST_SUCCESS=$value ;;
      LAST_ATTEMPT_EPOCH) [[ "$value" =~ ^[0-9]+$ ]] && CACHE_LAST_ATTEMPT=$value ;;
      REFRESH_STATUS) [[ "$value" =~ ^(ok|error|unsupported)$ ]] && CACHE_STATUS=$value ;;
    esac
  done <"$CACHE_FILE"
}

read_release_cache() {
  LATEST_MOTD_VERSION=""
  MOTD_UPDATE_AVAILABLE=0
  RELEASE_CHECK_EPOCH=0
  RELEASE_CHECK_STATUS="missing"
  [[ -r "$RELEASE_CACHE_FILE" ]] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      LATEST_VERSION) [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && LATEST_MOTD_VERSION=$value ;;
      UPDATE_AVAILABLE) [[ "$value" =~ ^[01]$ ]] && MOTD_UPDATE_AVAILABLE=$value ;;
      CHECKED_EPOCH) [[ "$value" =~ ^[0-9]+$ ]] && RELEASE_CHECK_EPOCH=$value ;;
      CHECK_STATUS) [[ "$value" =~ ^(ok|error)$ ]] && RELEASE_CHECK_STATUS=$value ;;
    esac
  done <"$RELEASE_CACHE_FILE"
}

is_virtual_interface() {
  local name=$1
  [[ "$name" =~ ^(lo|docker[0-9]*|br-|veth|cni|flannel|kube|virbr|lxc|lxd|tun|tap|wg|tailscale|zt) ]]
}

declare -A IFACE_ALIAS=()
declare -a DISPLAY_INTERFACES=()

discover_interfaces() {
  local iface index=1
  local -a all=() enx=()
  [[ -d /sys/class/net ]] || return 0
  mapfile -t all < <(find /sys/class/net -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | LC_ALL=C sort)
  for iface in "${all[@]}"; do
    [[ "$iface" == lo ]] && continue
    if (( ! SHOW_VIRTUAL_INTERFACES )) && is_virtual_interface "$iface"; then
      continue
    fi
    if [[ "$iface" == enx* ]]; then
      enx+=("$iface")
    fi
  done
  for iface in "${enx[@]}"; do
    IFACE_ALIAS["$iface"]="enx${index}"
    ((index++))
  done
  for iface in "${all[@]}"; do
    [[ "$iface" == lo ]] && continue
    if (( ! SHOW_VIRTUAL_INTERFACES )) && is_virtual_interface "$iface"; then
      continue
    fi
    # Include conventional physical names. Interfaces with global addresses are also relevant.
    if [[ "$iface" =~ ^(eth|en|wl) ]] || ip -o -4 addr show dev "$iface" scope global 2>/dev/null | grep -q .; then
      IFACE_ALIAS["$iface"]=${IFACE_ALIAS[$iface]:-$iface}
      DISPLAY_INTERFACES+=("$iface")
    fi
  done
}

interface_alias() {
  local iface=$1
  printf '%s' "${IFACE_ALIAS[$iface]:-$iface}"
}

interface_ipv4() {
  local iface=$1 result
  result=$(ip -o -4 addr show dev "$iface" scope global 2>/dev/null | awk '{print $4}' | paste -sd, - | sed 's/,/, /g')
  [[ -n "$result" ]] && printf '%s' "$result" || printf 'No IPv4 address'
}

default_route() {
  local route gateway iface
  route=$(ip -4 route show default 2>/dev/null | head -n1 || true)
  gateway=$(awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' <<<"$route")
  iface=$(awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' <<<"$route")
  if [[ -n "$gateway" ]]; then
    printf '%s via %s' "$gateway" "$(interface_alias "$iface")"
  elif [[ -n "$iface" ]]; then
    printf 'direct via %s' "$(interface_alias "$iface")"
  fi
}

percent_color() {
  local value=$1 warning=$2 critical=$3
  if (( value >= critical )); then printf '%s' "$RED"
  elif (( value >= warning )); then printf '%s' "$YELLOW"
  else printf '%s' "$GREEN"
  fi
}

declare -a ALERTS=()
HEALTH_LEVEL=0

add_warning() {
  ALERTS+=("${YELLOW}${WARNING_MARK}${RESET} $1")
  (( HEALTH_LEVEL < 1 )) && HEALTH_LEVEL=1
}

add_critical() {
  ALERTS+=("${RED}${CRITICAL_MARK}${RESET} $1")
  HEALTH_LEVEL=2
}

collect_system_data() {
  read_os_release
  HOST_NAME=$(hostname 2>/dev/null || printf 'unknown-host')
  HARDWARE=$(hardware_model)
  KERNEL=$(uname -r)
  ARCH=$(uname -m)
  UPTIME_SECONDS=${UPTIME_SECONDS:-$(cut -d. -f1 /proc/uptime 2>/dev/null || printf 0)}
  UPTIME_TEXT=$(format_duration "$UPTIME_SECONDS")
  read -r LOAD_1 LOAD_5 LOAD_15 _ </proc/loadavg

  MEM_TOTAL_KIB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  MEM_AVAILABLE_KIB=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  [[ -n "$MEM_AVAILABLE_KIB" ]] || MEM_AVAILABLE_KIB=$(awk '/^MemFree:/ {print $2}' /proc/meminfo)
  MEM_USED_KIB=$((MEM_TOTAL_KIB - MEM_AVAILABLE_KIB))
  MEM_PERCENT=$((MEM_USED_KIB * 100 / MEM_TOTAL_KIB))

  SWAP_TOTAL_KIB=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
  SWAP_FREE_KIB=$(awk '/^SwapFree:/ {print $2}' /proc/meminfo)
  SWAP_USED_KIB=$((SWAP_TOTAL_KIB - SWAP_FREE_KIB))

  read -r ROOT_TOTAL_KIB ROOT_USED_KIB ROOT_PERCENT < <(df -Pk / | awk 'NR==2 {gsub(/%/,"",$5); print $2,$3,$5}')
  PROCESS_COUNT=$(find /proc -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | wc -l | tr -d ' ')
  TEMPERATURE=$(read_temperature)

  FAILED_COUNT="N/A"
  FAILED_NAMES=""
  if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    local failed_output
    failed_output=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null || true)
    if [[ -n "$failed_output" ]]; then
      FAILED_COUNT=$(grep -c . <<<"$failed_output")
      FAILED_NAMES=$(awk '{print $1}' <<<"$failed_output" | head -n3 | paste -sd, - | sed 's/,/, /g')
    else
      FAILED_COUNT=0
    fi
  fi

  REBOOT_REQUIRED=0
  [[ -e /run/reboot-required || -e /var/run/reboot-required ]] && REBOOT_REQUIRED=1
  read_package_cache
  read_release_cache
  discover_interfaces
  DEFAULT_ROUTE=$(default_route)
}

evaluate_health() {
  if (( ROOT_PERCENT >= DISK_CRITICAL_PERCENT )); then
    add_critical "Root filesystem usage is critical: ${ROOT_PERCENT}%"
  elif (( ROOT_PERCENT >= DISK_WARNING_PERCENT )); then
    add_warning "Root filesystem usage is elevated: ${ROOT_PERCENT}%"
  fi

  if (( MEM_PERCENT >= MEMORY_CRITICAL_PERCENT )); then
    add_critical "Memory usage is critical: ${MEM_PERCENT}%"
  elif (( MEM_PERCENT >= MEMORY_WARNING_PERCENT )); then
    add_warning "Memory usage is elevated: ${MEM_PERCENT}%"
  fi

  if [[ -n "$TEMPERATURE" ]]; then
    local temp_int=${TEMPERATURE%.*}
    if (( temp_int >= TEMPERATURE_CRITICAL_C )); then
      add_critical "Temperature is critical: ${TEMPERATURE}${DEGREE}C"
    elif (( temp_int >= TEMPERATURE_WARNING_C )); then
      add_warning "Temperature is elevated: ${TEMPERATURE}${DEGREE}C"
    fi
  fi

  if [[ "$FAILED_COUNT" =~ ^[0-9]+$ ]] && (( FAILED_COUNT > 0 )); then
    add_critical "Failed systemd unit(s): ${FAILED_NAMES:-$FAILED_COUNT}"
  fi

  (( REBOOT_REQUIRED_IS_WARNING && REBOOT_REQUIRED )) && add_warning "Reboot required to complete installed updates"

  if (( SECURITY_UPDATES_ARE_WARNING )) && [[ "$SECURITY_COUNT" =~ ^[0-9]+$ ]] && (( SECURITY_COUNT > 0 )); then
    add_warning "${SECURITY_COUNT} security update(s) available"
  fi

  local now age stale_seconds=$((CACHE_STALE_HOURS * 3600))
  now=$(date +%s)
  if (( CACHE_LAST_SUCCESS == 0 )); then
    add_warning "Package information has not been refreshed yet"
  else
    age=$((now - CACHE_LAST_SUCCESS))
    (( age > stale_seconds )) && add_warning "Package information is stale ($(format_age "$age"))"
  fi
  [[ "$CACHE_STATUS" == error ]] && add_warning "The most recent package refresh failed"
}

health_display() {
  case "$HEALTH_LEVEL" in
    0) printf '%s%s Healthy%s' "$GREEN" "$HEALTHY_MARK" "$RESET" ;;
    1) printf '%s%s Warning%s' "$YELLOW" "$WARNING_MARK" "$RESET" ;;
    *) printf '%s%s Critical%s' "$RED" "$CRITICAL_MARK" "$RESET" ;;
  esac
}

render_compact() {
  local health temp swap failed memory root line iface address state route_text update_text refresh_text reboot_text
  health=$(health_display)
  temp=${TEMPERATURE:+${TEMPERATURE}${DEGREE}C}
  [[ -n "$temp" ]] || temp="N/A"
  if (( SWAP_TOTAL_KIB > 0 )); then
    swap="$(human_kib "$SWAP_USED_KIB")/$(human_kib "$SWAP_TOTAL_KIB")"
  else
    swap="Not enabled"
  fi
  failed=$FAILED_COUNT
  memory="$(human_kib "$MEM_USED_KIB")/$(human_kib "$MEM_TOTAL_KIB")"
  root="$(human_kib "$ROOT_USED_KIB")/$(human_kib "$ROOT_TOTAL_KIB") (${ROOT_PERCENT}%)"

  box_top "$HOST_NAME"
  line="$(clip_text "$OS_PRETTY" 30)${SEP}$(clip_text "$HARDWARE" 25)${SEP}$(clip_text "$KERNEL" 20)${SEP}$ARCH"
  line=$(clip_text "$line" $((INNER - 2)))
  box_line "$MUTED$line$RESET"

  if ((${#ALERTS[@]} > 0)); then
    box_section "ATTENTION REQUIRED"
    local alert shown=0
    for alert in "${ALERTS[@]}"; do
      box_line "$alert"
      ((shown++))
      if (( shown == 5 && ${#ALERTS[@]} > shown )); then
        box_line "$YELLOW! $((${#ALERTS[@]} - shown)) additional warning(s)$RESET"
        break
      fi
    done
  fi

  box_rule
  printf -v line '%sHEALTH%s %-18s %sUPTIME%s %-10s %sTEMP%s %s' \
    "$LABEL" "$RESET" "$health" "$LABEL" "$RESET" "$UPTIME_TEXT" "$LABEL" "$RESET" "$temp"
  box_line "$line"
  printf -v line '%sLOAD%s   %-17s %sMEMORY%s %-16s' \
    "$LABEL" "$RESET" "$LOAD_1  $LOAD_5  $LOAD_15" "$LABEL" "$RESET" "$memory"
  if (( SHOW_PROCESS_COUNT )); then
    line+=" ${LABEL}PROCS${RESET} $PROCESS_COUNT"
  fi
  box_line "$line"
  printf -v line '%sROOT%s   %s%-18s%s %sSWAP%s %-16s %sFAILED%s %s' \
    "$LABEL" "$RESET" "$(percent_color "$ROOT_PERCENT" "$DISK_WARNING_PERCENT" "$DISK_CRITICAL_PERCENT")" \
    "$root" "$RESET" "$LABEL" "$RESET" "$swap" "$LABEL" "$RESET" "$failed"
  box_line "$line"

  box_section "NETWORK"
  if ((${#DISPLAY_INTERFACES[@]} == 0)); then
    box_line "$MUTED No relevant interfaces detected$RESET"
  else
    for iface in "${DISPLAY_INTERFACES[@]}"; do
      address=$(interface_ipv4 "$iface")
      state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || printf unknown)
      if [[ "$state" == down && "$SHOW_DOWN_INTERFACES" == 0 ]]; then
        continue
      fi
      printf -v line '%s%-8s%s %-35s %sLink%s %s' "$LABEL" "$(interface_alias "$iface")" "$RESET" \
        "$(clip_text "$address" 35)" "$LABEL" "$RESET" "${state^}"
      box_line "$line"
    done
  fi
  if [[ -n "$DEFAULT_ROUTE" ]]; then
    route_text=$(clip_text "$DEFAULT_ROUTE" 55)
    box_line "${LABEL}Gateway ${RESET}$route_text"
  fi

  box_section "MAINTENANCE"
  if [[ "$UPDATE_COUNT" =~ ^[0-9]+$ ]]; then
    update_text="$UPDATE_COUNT update(s) available"
    [[ "$SECURITY_COUNT" =~ ^[0-9]+$ ]] && update_text+="${SEP}$SECURITY_COUNT security"
  else
    update_text="Update information unavailable"
  fi
  if (( REBOOT_REQUIRED )); then reboot_text="Reboot required"; else reboot_text="No reboot required"; fi
  box_line "$update_text${SEP}$reboot_text"
  if (( CACHE_LAST_SUCCESS > 0 )); then
    refresh_text="Package information refreshed $(format_age "$(($(date +%s) - CACHE_LAST_SUCCESS))")"
  else
    refresh_text="Package information has not been refreshed"
  fi
  box_line "$MUTED$refresh_text$RESET"
  if (( MOTD_UPDATE_AVAILABLE )) && [[ -n "$LATEST_MOTD_VERSION" ]]; then
    box_line "${YELLOW}Homelab MOTD $LATEST_MOTD_VERSION available${SEP}sudo motdctl update${RESET}"
  fi
  box_bottom
}

render_narrow() {
  local iface
  printf '%s%s%s %s %s\n' "$BOLD" "$HOST_NAME" "$RESET" "$TITLE_DASH" "$(health_display)"
  printf '%s | %s | %s\n' "$OS_PRETTY" "$HARDWARE" "$ARCH"
  printf 'Uptime %s | Load %s %s %s | Memory %s%% | Root %s%%\n' \
    "$UPTIME_TEXT" "$LOAD_1" "$LOAD_5" "$LOAD_15" "$MEM_PERCENT" "$ROOT_PERCENT"
  for iface in "${DISPLAY_INTERFACES[@]}"; do
    printf '%s: %s\n' "$(interface_alias "$iface")" "$(interface_ipv4 "$iface")"
  done
  ((${#ALERTS[@]} == 0)) || printf 'ATTENTION: %s\n' "$(strip_ansi "${ALERTS[0]}")"
  if (( MOTD_UPDATE_AVAILABLE )) && [[ -n "$LATEST_MOTD_VERSION" ]]; then
    printf 'UPDATE: Homelab MOTD %s available; run sudo motdctl update\n' "$LATEST_MOTD_VERSION"
  fi
}

render() {
  collect_system_data
  evaluate_health
  if (( WIDTH < 68 )); then render_narrow; else render_compact; fi
}

refresh_packages() {
  (( EUID == 0 )) || { printf 'Run "sudo motdctl refresh".\n' >&2; return 1; }
  command -v apt-get >/dev/null 2>&1 || {
    install -d -m 0755 "$CACHE_DIR"
    printf 'REFRESH_STATUS=unsupported\nLAST_ATTEMPT_EPOCH=%s\n' "$(date +%s)" >"$CACHE_FILE"
    chmod 0644 "$CACHE_FILE"
    printf 'APT is not installed; package reporting disabled.\n'
    return 0
  }

  install -d -m 0755 "$CACHE_DIR" /run/lock
  local lock=/run/lock/homelab-motd-refresh.lock temp now status=ok previous_success=0 updates=0 security=0 simulation
  exec 9>"$lock"
  if ! flock -w 5 9; then
    printf 'Another Homelab MOTD refresh is already running.\n' >&2
    return 0
  fi
  now=$(date +%s)
  if [[ -r "$CACHE_FILE" ]]; then
    previous_success=$(awk -F= '$1=="LAST_SUCCESS_EPOCH" && $2~/^[0-9]+$/ {print $2}' "$CACHE_FILE")
    previous_success=${previous_success:-0}
  fi

  printf 'Refreshing APT package information...\n'
  if ! LC_ALL=C apt-get -qq -o Acquire::Retries=2 update; then
    status=error
    printf 'APT refresh failed; retaining the last successful timestamp.\n' >&2
  fi

  simulation=$(LC_ALL=C apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null || true)
  updates=$(awk '/^Inst / {count++} END {print count+0}' <<<"$simulation")
  security=$(awk 'BEGIN{IGNORECASE=1} /^Inst / && ($0 ~ /security/) {count++} END {print count+0}' <<<"$simulation")
  [[ "$status" == ok ]] && previous_success=$now

  temp=$(mktemp "${CACHE_DIR}/.apt-cache.XXXXXX")
  {
    printf 'CACHE_VERSION=1\n'
    printf 'LAST_ATTEMPT_EPOCH=%s\n' "$now"
    printf 'LAST_SUCCESS_EPOCH=%s\n' "$previous_success"
    printf 'UPDATE_COUNT=%s\n' "$updates"
    printf 'SECURITY_COUNT=%s\n' "$security"
    printf 'REFRESH_STATUS=%s\n' "$status"
  } >"$temp"
  chmod 0644 "$temp"
  mv -f "$temp" "$CACHE_FILE"
  printf 'Package cache updated: %s total, %s security; status: %s.\n' "$updates" "$security" "$status"
  return 0
}

fetch_url() {
  local url=$1 destination=$2
  if command -v curl >/dev/null 2>&1; then
    curl --fail --silent --show-error --location \
      --connect-timeout 10 --max-time 60 --output "$destination" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget --quiet --timeout=60 --output-document="$destination" "$url"
  else
    printf 'Update checks require curl or wget.\n' >&2
    return 127
  fi
}

write_release_cache() {
  (( EUID == 0 )) || return 0
  [[ "${HOMELAB_MOTD_NO_CACHE:-0}" != 1 ]] || return 0
  local status=$1 latest=${2:-} available=${3:-0} temp
  install -d -m 0755 "$CACHE_DIR"
  temp=$(mktemp "${CACHE_DIR}/.release-cache.XXXXXX")
  {
    printf 'CHECKED_EPOCH=%s\n' "$(date +%s)"
    printf 'CHECK_STATUS=%s\n' "$status"
    [[ -n "$latest" ]] && printf 'LATEST_VERSION=%s\n' "$latest"
    printf 'UPDATE_AVAILABLE=%s\n' "$available"
  } >"$temp"
  chmod 0644 "$temp"
  mv -f "$temp" "$RELEASE_CACHE_FILE"
}

version_is_newer() {
  local candidate=$1 current=$2 highest
  highest=$(printf '%s\n%s\n' "$candidate" "$current" | LC_ALL=C sort -V | tail -n1)
  [[ "$candidate" != "$current" && "$highest" == "$candidate" ]]
}

check_project_update() {
  local quiet=${1:-} temp latest
  LATEST_REMOTE_VERSION=""
  PROJECT_UPDATE_AVAILABLE=0
  temp=$(mktemp)
  if ! fetch_url "$VERSION_URL" "$temp"; then
    rm -f "$temp"
    write_release_cache error "" 0
    [[ "$quiet" == --quiet ]] || printf 'Could not check %s for updates.\n' "$PROJECT_URL" >&2
    return 1
  fi
  latest=$(tr -d '[:space:]' <"$temp")
  rm -f "$temp"
  if [[ ! "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    write_release_cache error "" 0
    printf 'The repository returned an invalid version: %s\n' "$latest" >&2
    return 1
  fi

  LATEST_REMOTE_VERSION=$latest
  if version_is_newer "$latest" "$MOTD_VERSION"; then
    PROJECT_UPDATE_AVAILABLE=1
  fi
  write_release_cache ok "$latest" "$PROJECT_UPDATE_AVAILABLE"

  if [[ "$quiet" != --quiet ]]; then
    if (( PROJECT_UPDATE_AVAILABLE )); then
      printf 'Homelab MOTD %s is available (installed: %s).\n' "$latest" "$MOTD_VERSION"
      printf 'Run "sudo motdctl update" to review and install it.\n'
    else
      printf 'Homelab MOTD %s is up to date.\n' "$MOTD_VERSION"
    fi
  fi
}

update_project() {
  (( EUID == 0 )) || { printf 'Run "sudo motdctl update".\n' >&2; return 1; }
  local assume_yes=${1:-} temp_dir installer downloaded_version answer result
  if ! check_project_update --quiet; then
    return 1
  fi
  if (( ! PROJECT_UPDATE_AVAILABLE )); then
    printf 'Homelab MOTD %s is already up to date.\n' "$MOTD_VERSION"
    return 0
  fi

  temp_dir=$(mktemp -d)
  installer="$temp_dir/homelab-motd-installer.sh"
  if ! fetch_url "$INSTALLER_URL" "$installer"; then
    rm -rf -- "$temp_dir"
    return 1
  fi
  if ! bash -n "$installer"; then
    printf 'Downloaded installer failed Bash syntax validation.\n' >&2
    rm -rf -- "$temp_dir"
    return 1
  fi
  downloaded_version=$(awk -F'"' '$1=="readonly INSTALLER_VERSION=" {print $2; exit}' "$installer")
  if [[ "$downloaded_version" != "$LATEST_REMOTE_VERSION" ]]; then
    printf 'Version mismatch: VERSION says %s but the installer says %s. Update aborted.\n' \
      "$LATEST_REMOTE_VERSION" "${downloaded_version:-unknown}" >&2
    rm -rf -- "$temp_dir"
    return 1
  fi

  if [[ "$assume_yes" != --yes && "$assume_yes" != -y ]]; then
    if [[ ! -t 0 ]]; then
      printf 'Interactive confirmation is unavailable; rerun with "sudo motdctl update --yes".\n' >&2
      rm -rf -- "$temp_dir"
      return 2
    fi
    printf 'Install Homelab MOTD %s from %s? [y/N] ' "$LATEST_REMOTE_VERSION" "$PROJECT_URL"
    read -r answer
    [[ "$answer" =~ ^[Yy]$ ]] || { printf 'Update cancelled.\n'; rm -rf -- "$temp_dir"; return 0; }
  fi

  printf 'Installing Homelab MOTD %s...\n' "$LATEST_REMOTE_VERSION"
  bash "$installer" --install
  result=$?
  rm -rf -- "$temp_dir"
  if (( result == 0 )); then
    "$RUNTIME_PATH" check-update --quiet >/dev/null 2>&1 || true
  fi
  return "$result"
}

scheduled_update() {
  if (( ! CHECK_FOR_UPDATES && ! AUTO_UPDATE )); then
    return 0
  fi
  if (( AUTO_UPDATE )); then
    update_project --yes || printf 'Automatic Homelab MOTD update failed; the timer will retry.\n' >&2
  else
    check_project_update --quiet || printf 'Homelab MOTD update check failed; the timer will retry.\n' >&2
  fi
  return 0
}

show_status() {
  printf 'Homelab MOTD version: %s\n' "$MOTD_VERSION"
  printf 'Configuration: %s\n' "$CONFIG_FILE"
  printf 'Package cache: %s\n' "$CACHE_FILE"
  printf 'Update checks: %s\n' "$([[ "$CHECK_FOR_UPDATES" == 1 ]] && printf enabled || printf disabled)"
  printf 'Automatic installation: %s\n' "$([[ "$AUTO_UPDATE" == 1 ]] && printf enabled || printf disabled)"
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    printf 'Refresh timer: %s\n' "$(systemctl is-active homelab-motd-refresh.timer 2>/dev/null || true)"
    printf 'Update timer: %s\n' "$(systemctl is-active homelab-motd-update.timer 2>/dev/null || true)"
    systemctl list-timers homelab-motd-refresh.timer homelab-motd-update.timer --no-pager 2>/dev/null || true
  fi
  if [[ -r "$CACHE_FILE" ]]; then
    printf '\nCached package information:\n'
    sed 's/^/  /' "$CACHE_FILE"
  fi
  if [[ -r "$RELEASE_CACHE_FILE" ]]; then
    printf '\nCached release information:\n'
    sed 's/^/  /' "$RELEASE_CACHE_FILE"
  fi
}

configure() {
  (( EUID == 0 )) || { printf 'Run "sudo motdctl configure".\n' >&2; return 1; }
  local editor=${SUDO_EDITOR:-${EDITOR:-}}
  if [[ -z "$editor" ]] && command -v sensible-editor >/dev/null 2>&1; then editor=sensible-editor; fi
  [[ -n "$editor" ]] || editor=vi
  "$editor" "$CONFIG_FILE"
  if ! bash -n "$CONFIG_FILE"; then
    printf 'Configuration contains a syntax error. Correct %s before login.\n' "$CONFIG_FILE" >&2
    return 1
  fi
  render
}

restore_prior_motd() {
  [[ -d "$STATE_DIR" ]] || return 0
  local original_type="missing" target="" preserved
  [[ -r "$STATE_DIR/original-motd.type" ]] && original_type=$(<"$STATE_DIR/original-motd.type")
  if [[ -e /etc/motd || -L /etc/motd ]]; then
    if [[ -s /etc/motd || -L /etc/motd ]]; then
      preserved="/etc/motd.homelab-motd-uninstall-$(date +%Y%m%d%H%M%S)"
      mv /etc/motd "$preserved"
      printf 'Preserved the current /etc/motd as %s.\n' "$preserved"
    else
      rm -f /etc/motd
    fi
  fi
  case "$original_type" in
    file)
      [[ -e "$STATE_DIR/original-motd" ]] && cp -a "$STATE_DIR/original-motd" /etc/motd
      ;;
    symlink)
      [[ -r "$STATE_DIR/original-motd.target" ]] && target=$(<"$STATE_DIR/original-motd.target")
      [[ -n "$target" ]] && ln -s "$target" /etc/motd
      ;;
    missing) ;;
  esac
}

restore_fragments() {
  [[ -r "$DISABLED_FILE" ]] || return 0
  local path mode
  while IFS=$'\t' read -r path mode; do
    [[ "$path" == /etc/update-motd.d/* && "$mode" =~ ^[0-7]{3,4}$ ]] || continue
    [[ -e "$path" && ! -L "$path" ]] && chmod "$mode" "$path"
  done <"$DISABLED_FILE"
}

restore_fragment_symlinks() {
  [[ -r "$DISABLED_SYMLINKS_FILE" ]] || return 0
  local path target current_target
  while IFS=$'\t' read -r path target; do
    [[ "$path" == /etc/update-motd.d/* && -n "$target" ]] || continue
    if [[ -L "$path" ]]; then
      current_target=$(readlink "$path")
      [[ "$current_target" == /dev/null ]] || continue
      rm -f "$path"
    elif [[ -e "$path" ]]; then
      continue
    fi
    ln -s "$target" "$path"
  done <"$DISABLED_SYMLINKS_FILE"
}

restore_legacy_timer() {
  local enabled="" active=""
  [[ -r "$STATE_DIR/legacy-timer.state" ]] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      ENABLED) enabled=$value ;;
      ACTIVE) active=$value ;;
    esac
  done <"$STATE_DIR/legacy-timer.state"
  [[ "$enabled" == enabled ]] && systemctl enable motd-update.timer >/dev/null 2>&1 || true
  [[ "$active" == active ]] && systemctl start motd-update.timer >/dev/null 2>&1 || true
}

restore_motd_news_timer() {
  local enabled="" active="" service_active=""
  [[ -r "$STATE_DIR/motd-news.state" ]] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      ENABLED) enabled=$value ;;
      ACTIVE) active=$value ;;
      SERVICE_ACTIVE) service_active=$value ;;
    esac
  done <"$STATE_DIR/motd-news.state"
  [[ "$enabled" == enabled ]] && systemctl enable motd-news.timer >/dev/null 2>&1 || true
  [[ "$active" == active ]] && systemctl start motd-news.timer >/dev/null 2>&1 || true
  [[ "$service_active" == active ]] && systemctl start motd-news.service >/dev/null 2>&1 || true
}

uninstall_motd() {
  (( EUID == 0 )) || { printf 'Run "sudo motdctl uninstall".\n' >&2; return 1; }
  printf 'Removing Homelab MOTD...\n'
  systemctl disable --now homelab-motd-refresh.timer >/dev/null 2>&1 || true
  systemctl disable --now homelab-motd-update.timer >/dev/null 2>&1 || true
  rm -f "$TIMER_PATH" "$SERVICE_PATH" "$UPDATE_TIMER_PATH" "$UPDATE_SERVICE_PATH" \
    "$MOTD_FRAGMENT" "$CONTROL_PATH"
  restore_fragment_symlinks
  restore_fragments
  restore_prior_motd
  systemctl daemon-reload >/dev/null 2>&1 || true
  restore_legacy_timer
  restore_motd_news_timer
  rm -rf "$CACHE_DIR"
  rm -f "$CONFIG_FILE"
  rm -f "$RUNTIME_PATH"
  rm -rf "$STATE_DIR"
  printf 'Homelab MOTD removed and the previous MOTD configuration restored.\n'
}

command=${1:-render}
case "$command" in
  render|preview) render ;;
  refresh) refresh_packages ;;
  check-update) check_project_update "${2:-}" ;;
  update) update_project "${2:-}" ;;
  scheduled-update) scheduled_update ;;
  status) show_status ;;
  configure) configure ;;
  uninstall) uninstall_motd ;;
  version|--version|-V) printf 'Homelab MOTD %s\n%s\n' "$MOTD_VERSION" "$PROJECT_URL" ;;
  --help|-h|help)
    cat <<'EOF'
Usage: motdctl {preview|refresh|check-update|update|status|configure|uninstall|version}

  preview      Render the current MOTD
  refresh      Refresh cached APT update information (requires sudo)
  check-update Check GitHub for a newer Homelab MOTD release
  update       Download, validate, and install an update (requires sudo)
  status       Show timer and cache status
  configure    Edit configuration and preview the result (requires sudo)
  uninstall    Remove Homelab MOTD and restore prior files (requires sudo)
  version      Show the installed version
EOF
    ;;
  *) printf 'Unknown command: %s\n' "$command" >&2; exit 2 ;;
esac
RUNTIME_EOF
  chmod 0755 "$destination"
}

write_config() {
  local destination=$1
  cat >"$destination" <<'CONFIG_EOF'
# Homelab MOTD configuration

# Color and box-drawing support: auto, always, or never
COLOR="auto"
UNICODE="auto"

# Maximum output width. Narrow terminals automatically use a compact fallback.
DISPLAY_WIDTH=78

# Health thresholds
DISK_WARNING_PERCENT=80
DISK_CRITICAL_PERCENT=90
MEMORY_WARNING_PERCENT=85
MEMORY_CRITICAL_PERCENT=95
TEMPERATURE_WARNING_C=75
TEMPERATURE_CRITICAL_C=85

# Package information older than this is shown as stale.
CACHE_STALE_HOURS=12
SECURITY_UPDATES_ARE_WARNING=1
REBOOT_REQUIRED_IS_WARNING=1

# Network display. Kernel interface names are not changed. Actual enx* names are
# shown as deterministic display aliases enx1, enx2, and so forth.
SHOW_DOWN_INTERFACES=1
SHOW_VIRTUAL_INTERFACES=0

SHOW_PROCESS_COUNT=1

# Check GitHub daily and cache whether a newer version is available.
CHECK_FOR_UPDATES=1

# Automatically install newer versions. Disabled by default because updates run
# repository code as root. Manual updates use: sudo motdctl update
AUTO_UPDATE=0
CONFIG_EOF
  chmod 0644 "$destination"
}

add_update_config_defaults() {
  local destination=$1
  if grep -Eq '^[[:space:]]*(CHECK_FOR_UPDATES|AUTO_UPDATE)=' "$destination"; then
    grep -Eq '^[[:space:]]*CHECK_FOR_UPDATES=' "$destination" && \
      grep -Eq '^[[:space:]]*AUTO_UPDATE=' "$destination" && return 0
  fi
  {
    printf '\n# EnhancedMOTD repository update settings\n'
    grep -Eq '^[[:space:]]*CHECK_FOR_UPDATES=' "$destination" || printf 'CHECK_FOR_UPDATES=1\n'
    if ! grep -Eq '^[[:space:]]*AUTO_UPDATE=' "$destination"; then
      printf '# Automatic installation runs downloaded repository code as root.\n'
      printf 'AUTO_UPDATE=0\n'
    fi
  } >>"$destination"
}

write_fragment() {
  local destination=$1
  cat >"$destination" <<'FRAGMENT_EOF'
#!/bin/sh
# pam_motd may not provide TERM or locale variables during early SSH login.
export HOMELAB_MOTD_LOGIN=1
# Character-aware padding requires a UTF-8 character type locale.
export LC_CTYPE=C.UTF-8
exec /usr/local/libexec/homelab-motd render
FRAGMENT_EOF
  chmod 0755 "$destination"
}

write_service() {
  local destination=$1
  cat >"$destination" <<'SERVICE_EOF'
[Unit]
Description=Refresh cached package information for Homelab MOTD
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/homelab-motd refresh
Nice=10
IOSchedulingClass=idle
PrivateTmp=true
ProtectHome=true
NoNewPrivileges=true
TimeoutStartSec=10min
SERVICE_EOF
  chmod 0644 "$destination"
}

write_timer() {
  local destination=$1
  cat >"$destination" <<'TIMER_EOF'
[Unit]
Description=Refresh Homelab MOTD package information every six hours

[Timer]
OnCalendar=*-*-* 00,06,12,18:00:00
RandomizedDelaySec=15min
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
TIMER_EOF
  chmod 0644 "$destination"
}

write_update_service() {
  local destination=$1
  cat >"$destination" <<'UPDATE_SERVICE_EOF'
[Unit]
Description=Check for Homelab MOTD updates
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/homelab-motd scheduled-update
Nice=10
IOSchedulingClass=idle
PrivateTmp=true
ProtectHome=true
NoNewPrivileges=true
TimeoutStartSec=30min
UPDATE_SERVICE_EOF
  chmod 0644 "$destination"
}

write_update_timer() {
  local destination=$1
  cat >"$destination" <<'UPDATE_TIMER_EOF'
[Unit]
Description=Check for Homelab MOTD updates daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=2h
Persistent=true
AccuracySec=15min

[Install]
WantedBy=timers.target
UPDATE_TIMER_EOF
  chmod 0644 "$destination"
}

detect_platform() {
  [[ -r /etc/os-release ]] || die "Cannot identify this operating system: /etc/os-release is missing."
  local id id_like pretty
  id=$(awk -F= '$1=="ID" {gsub(/"/,"",$2); print $2}' /etc/os-release)
  id_like=$(awk -F= '$1=="ID_LIKE" {gsub(/"/,"",$2); print $2}' /etc/os-release)
  pretty=$(awk -F= '$1=="PRETTY_NAME" {sub(/^[^=]*=/,""); gsub(/^"|"$/,"",$0); print}' /etc/os-release)
  if [[ "$id" != debian && "$id" != ubuntu && "$id" != raspbian && ! " $id_like " =~ [[:space:]]debian[[:space:]] ]]; then
    die "Unsupported platform: ${pretty:-$id}. This installer requires a Debian-family distribution."
  fi
  printf '%s' "${pretty:-$id}"
}

save_original_motd() {
  [[ -e "$STATE_DIR/original-motd.type" ]] && return 0
  if [[ -L /etc/motd ]]; then
    printf 'symlink\n' >"$STATE_DIR/original-motd.type"
    readlink /etc/motd >"$STATE_DIR/original-motd.target"
  elif [[ -f /etc/motd ]]; then
    printf 'file\n' >"$STATE_DIR/original-motd.type"
    cp -a /etc/motd "$STATE_DIR/original-motd"
  else
    printf 'missing\n' >"$STATE_DIR/original-motd.type"
  fi
}

suppress_static_motd() {
  local first_install=$1 original_type="missing" original_target="" current_target=""
  [[ -r "$STATE_DIR/original-motd.type" ]] && original_type=$(<"$STATE_DIR/original-motd.type")

  if (( first_install )); then
    rm -f /etc/motd
    install -m 0644 /dev/null /etc/motd
    return 0
  fi

  # Keep the managed empty file empty on upgrades. If the original symlink was
  # recreated by a package upgrade, suppress it again. Preserve other admin edits.
  if [[ -f /etc/motd && ! -s /etc/motd && ! -L /etc/motd ]]; then
    return 0
  fi
  if [[ "$original_type" == symlink && -L /etc/motd ]]; then
    [[ -r "$STATE_DIR/original-motd.target" ]] && original_target=$(<"$STATE_DIR/original-motd.target")
    current_target=$(readlink /etc/motd)
    if [[ -n "$original_target" && "$current_target" == "$original_target" ]]; then
      rm -f /etc/motd
      install -m 0644 /dev/null /etc/motd
      return 0
    fi
  fi
  warn "Preserving administrator-modified /etc/motd content. It will appear after the dashboard."
}

disable_legacy_timer() {
  local timer=/etc/systemd/system/motd-update.timer enabled active
  [[ -f "$timer" ]] || return 0
  grep -Eqi 'motd.*(upgradable|package count)|OnCalendar=.*00,02,04,06' "$timer" || return 0
  [[ -e "$STATE_DIR/legacy-timer.state" ]] && return 0
  enabled=$(systemctl is-enabled motd-update.timer 2>/dev/null || true)
  active=$(systemctl is-active motd-update.timer 2>/dev/null || true)
  {
    printf 'ENABLED=%s\n' "$enabled"
    printf 'ACTIVE=%s\n' "$active"
  } >"$STATE_DIR/legacy-timer.state"
  chmod 0600 "$STATE_DIR/legacy-timer.state"
  systemctl disable --now motd-update.timer >/dev/null 2>&1 || true
  ok "Disabled the legacy motd-update.timer; its prior state was recorded for uninstall."
}

disable_motd_news_timer() {
  local enabled active service_active state_file="$STATE_DIR/motd-news.state"
  systemctl cat motd-news.timer >/dev/null 2>&1 || return 0

  if [[ ! -e "$state_file" ]]; then
    enabled=$(systemctl is-enabled motd-news.timer 2>/dev/null || true)
    active=$(systemctl is-active motd-news.timer 2>/dev/null || true)
    service_active=$(systemctl is-active motd-news.service 2>/dev/null || true)
    {
      printf 'ENABLED=%s\n' "$enabled"
      printf 'ACTIVE=%s\n' "$active"
      printf 'SERVICE_ACTIVE=%s\n' "$service_active"
    } >"$state_file"
    chmod 0600 "$state_file"
  fi

  systemctl disable --now motd-news.timer >/dev/null 2>&1 || true
  systemctl stop motd-news.service >/dev/null 2>&1 || true
  systemctl reset-failed motd-news.service >/dev/null 2>&1 || true
  ok "Disabled Ubuntu motd-news; its prior state was recorded for uninstall."
}

should_disable_fragment() {
  local path=$1
  [[ "$path" == "$FRAGMENT_PATH" ]] && return 1
  return 0
}

disable_competing_fragments() {
  local path mode target recorded_path recorded_target already_recorded
  install -d -m 0755 /etc/update-motd.d
  touch "$STATE_DIR/disabled-fragments.tsv"
  touch "$STATE_DIR/disabled-symlinks.tsv"
  chmod 0600 "$STATE_DIR/disabled-fragments.tsv" "$STATE_DIR/disabled-symlinks.tsv"

  # Version 1.0.3 used /dev/null symlinks, which run-parts rejects as invalid.
  # Remove those managed placeholders; the original targets remain recorded.
  while IFS=$'\t' read -r recorded_path recorded_target; do
    [[ "$recorded_path" == /etc/update-motd.d/* && -n "$recorded_target" ]] || continue
    if [[ -L "$recorded_path" && "$(readlink "$recorded_path")" == /dev/null ]]; then
      rm -f "$recorded_path"
    fi
  done <"$STATE_DIR/disabled-symlinks.tsv"

  for path in /etc/update-motd.d/*; do
    [[ -f "$path" && -x "$path" ]] || continue
    should_disable_fragment "$path" || continue

    if [[ -L "$path" ]]; then
      target=$(readlink "$path")
      already_recorded=0
      grep -Fq "${path}"$'\t' "$STATE_DIR/disabled-symlinks.tsv" && already_recorded=1
      if (( ! already_recorded )); then
        printf '%s\t%s\n' "$path" "$target" >>"$STATE_DIR/disabled-symlinks.tsv"
      fi
      rm -f "$path"
      continue
    fi

    already_recorded=0
    grep -Fq "${path}"$'\t' "$STATE_DIR/disabled-fragments.tsv" && already_recorded=1
    if (( ! already_recorded )); then
      mode=$(stat -Lc '%a' "$path")
      printf '%s\t%s\n' "$path" "$mode" >>"$STATE_DIR/disabled-fragments.tsv"
    fi
    chmod a-x "$path"
  done
}

install_motd() {
  require_root
  check_install_requirements

  local platform temp_dir run_parts_output first_install=0
  platform=$(detect_platform)
  info "Installing Homelab MOTD $INSTALLER_VERSION on $platform"

  install -d -m 0755 /usr/local/libexec /usr/local/sbin /etc/update-motd.d "$CACHE_DIR"
  install -d -m 0700 "$STATE_DIR"
  [[ -e "$STATE_DIR/original-motd.type" ]] || first_install=1
  save_original_motd
  disable_motd_news_timer
  disable_legacy_timer
  disable_competing_fragments

  # Suppress the distribution's static MOTD without deleting its saved original.
  suppress_static_motd "$first_install"

  temp_dir=$(mktemp -d)
  trap "rm -rf -- '$temp_dir'" EXIT
  write_runtime "$temp_dir/homelab-motd"
  write_fragment "$temp_dir/00-homelab-motd"
  write_service "$temp_dir/homelab-motd-refresh.service"
  write_timer "$temp_dir/homelab-motd-refresh.timer"
  write_update_service "$temp_dir/homelab-motd-update.service"
  write_update_timer "$temp_dir/homelab-motd-update.timer"

  install -o root -g root -m 0755 "$temp_dir/homelab-motd" "$RUNTIME_PATH"
  ln -sfn "$RUNTIME_PATH" "$CONTROL_PATH"
  install -o root -g root -m 0755 "$temp_dir/00-homelab-motd" "$FRAGMENT_PATH"
  install -o root -g root -m 0644 "$temp_dir/homelab-motd-refresh.service" "$SERVICE_PATH"
  install -o root -g root -m 0644 "$temp_dir/homelab-motd-refresh.timer" "$TIMER_PATH"
  install -o root -g root -m 0644 "$temp_dir/homelab-motd-update.service" "$UPDATE_SERVICE_PATH"
  install -o root -g root -m 0644 "$temp_dir/homelab-motd-update.timer" "$UPDATE_TIMER_PATH"

  if [[ ! -e "$CONFIG_PATH" ]]; then
    write_config "$temp_dir/homelab-motd.conf"
    install -o root -g root -m 0644 "$temp_dir/homelab-motd.conf" "$CONFIG_PATH"
  else
    ok "Preserved existing configuration at $CONFIG_PATH"
  fi
  add_update_config_defaults "$CONFIG_PATH"
  rm -f "$CACHE_DIR/release-cache"
  printf '%s\n' "$INSTALLER_VERSION" >"$STATE_DIR/version"

  bash -n "$RUNTIME_PATH" || die "Installed renderer failed syntax validation."
  bash -n "$CONFIG_PATH" || die "Configuration failed syntax validation: $CONFIG_PATH"
  if ! run_parts_output=$(run-parts --test /etc/update-motd.d 2>&1); then
    die "run-parts validation failed: $run_parts_output"
  fi
  grep -Fxq "$FRAGMENT_PATH" <<<"$run_parts_output" || die "PAM MOTD fragment was not selected by run-parts."
  systemd-analyze verify "$SERVICE_PATH" "$TIMER_PATH" "$UPDATE_SERVICE_PATH" \
    "$UPDATE_TIMER_PATH" >/dev/null 2>&1 || die "systemd unit validation failed."

  systemctl daemon-reload
  systemctl enable --now homelab-motd-refresh.timer >/dev/null
  systemctl enable --now homelab-motd-update.timer >/dev/null
  "$RUNTIME_PATH" refresh || warn "Initial package refresh did not complete; the timer will retry."

  ok "Installed and enabled Homelab MOTD."
  printf '\nPreview:\n\n'
  "$RUNTIME_PATH" preview
  printf '\nUseful commands:\n'
  printf '  motdctl preview\n'
  printf '  sudo motdctl refresh\n'
  printf '  motdctl status\n'
  printf '  motdctl check-update\n'
  printf '  sudo motdctl update\n'
  printf '  sudo motdctl configure\n'
  printf '  sudo motdctl uninstall\n'
}

preview_uninstalled() {
  local temp_dir
  temp_dir=$(mktemp -d)
  trap "rm -rf -- '$temp_dir'" EXIT
  write_runtime "$temp_dir/homelab-motd"
  "$temp_dir/homelab-motd" preview
}

self_test() {
  local temp_dir output plain_output update_output service_test update_service_test line line_length
  temp_dir=$(mktemp -d)
  trap "rm -rf -- '$temp_dir'" EXIT
  write_runtime "$temp_dir/homelab-motd"
  write_config "$temp_dir/homelab-motd.conf"
  write_fragment "$temp_dir/00-homelab-motd"
  write_service "$temp_dir/homelab-motd-refresh.service"
  write_timer "$temp_dir/homelab-motd-refresh.timer"
  write_update_service "$temp_dir/homelab-motd-update.service"
  write_update_timer "$temp_dir/homelab-motd-update.timer"

  bash -n "$temp_dir/homelab-motd"
  bash -n "$temp_dir/homelab-motd.conf"
  grep -Fq "readonly MOTD_VERSION=\"$INSTALLER_VERSION\"" "$temp_dir/homelab-motd"
  grep -Fq 'CHECK_FOR_UPDATES=1' "$temp_dir/homelab-motd.conf"
  grep -Fq 'AUTO_UPDATE=0' "$temp_dir/homelab-motd.conf"
  grep -Fq 'export HOMELAB_MOTD_LOGIN=1' "$temp_dir/00-homelab-motd"
  grep -Fq 'export LC_CTYPE=C.UTF-8' "$temp_dir/00-homelab-motd"
  grep -Fq 'exec /usr/local/libexec/homelab-motd render' "$temp_dir/00-homelab-motd"

  if (( BASH_VERSINFO[0] >= 4 )); then
    install -d -m 0755 "$temp_dir/fake-bin"
    cat >"$temp_dir/fake-bin/curl" <<'FAKE_CURL_EOF'
#!/bin/sh
destination=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output" ]; then
    shift
    destination=$1
  fi
  shift
done
[ -n "$destination" ] || exit 2
printf '9.9.9\n' >"$destination"
FAKE_CURL_EOF
    chmod 0755 "$temp_dir/fake-bin/curl"
    update_output=$(HOMELAB_MOTD_NO_CACHE=1 PATH="$temp_dir/fake-bin:/usr/bin:/bin" \
      "$BASH" "$temp_dir/homelab-motd" check-update)
    grep -Fq 'Homelab MOTD 9.9.9 is available' <<<"$update_output"
  else
    warn "Updater behavior test skipped because this host has Bash ${BASH_VERSION}; Bash 4+ is required."
  fi

  if [[ -r VERSION ]]; then
    [[ "$(tr -d '[:space:]' <VERSION)" == "$INSTALLER_VERSION" ]] || die "VERSION does not match the installer."
  fi

  if command -v systemd-analyze >/dev/null 2>&1; then
    service_test="$temp_dir/homelab-motd-refresh.service"
    update_service_test="$temp_dir/homelab-motd-update.service"
    sed -i "s|ExecStart=/usr/local/libexec/homelab-motd refresh|ExecStart=$temp_dir/homelab-motd refresh|" "$service_test"
    sed -i "s|ExecStart=/usr/local/libexec/homelab-motd scheduled-update|ExecStart=$temp_dir/homelab-motd scheduled-update|" "$update_service_test"
    systemd-analyze verify "$service_test" "$temp_dir/homelab-motd-refresh.timer" \
      "$update_service_test" "$temp_dir/homelab-motd-update.timer" >/dev/null
  fi

  if [[ "$(uname -s)" == Linux && -r /proc/loadavg && -r /proc/meminfo ]]; then
    output=$(HOMELAB_MOTD_LOGIN=1 TERM=dumb LANG=C LC_CTYPE=C.UTF-8 COLUMNS=78 "$temp_dir/homelab-motd" preview)
    grep -Fq "$(hostname)" <<<"$output"
    grep -Fq 'NETWORK' <<<"$output"
    grep -Fq 'MAINTENANCE' <<<"$output"
    grep -Fq $'\033[' <<<"$output"
    grep -Fq '╭' <<<"$output"

    plain_output=$(HOMELAB_MOTD_LOGIN=1 NO_COLOR=1 TERM=dumb LANG=C LC_CTYPE=C.UTF-8 COLUMNS=78 "$temp_dir/homelab-motd" preview)
    if grep -Fq $'\033[' <<<"$plain_output"; then
      die "NO_COLOR did not disable color in login mode."
    fi
    while IFS= read -r line; do
      case "$line" in
        ╭*|├*|│*|╰*) ;;
        *) continue ;;
      esac
      line_length=$(printf '%s' "$line" | LC_CTYPE=C.UTF-8 wc -m | tr -d ' ')
      [[ "$line_length" == 78 ]] || die "Renderer produced a ${line_length}-column box row; expected 78."
    done <<<"$plain_output"
    ok "Embedded runtime, configuration, systemd units, and renderer passed validation."
  else
    warn "Renderer test skipped because Linux /proc data is unavailable on this host."
    ok "Embedded runtime, configuration, and generated files passed static validation."
  fi
}

uninstall_from_installer() {
  require_root
  [[ -x "$RUNTIME_PATH" ]] || die "Homelab MOTD is not installed."
  "$RUNTIME_PATH" uninstall
}

operation=${1:---install}
case "$operation" in
  --install|install) install_motd ;;
  --preview|preview) preview_uninstalled ;;
  --uninstall|uninstall) uninstall_from_installer ;;
  --self-test|self-test) self_test ;;
  --version|-V|version) printf 'Homelab MOTD installer %s\n%s\n' "$INSTALLER_VERSION" "$PROJECT_URL" ;;
  --help|-h|help) usage ;;
  *) usage >&2; die "Unknown option: $operation" ;;
esac
