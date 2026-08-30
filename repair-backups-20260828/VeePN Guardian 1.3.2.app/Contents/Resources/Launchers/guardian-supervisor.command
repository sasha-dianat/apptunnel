#!/bin/bash
# Multi-app supervisor for VeePN Guardian.
#
# It holds one shared PF reference while any selected protected application is
# active, delegates each application to a fail-closed launcher, and treats the
# launchers' post-start process audits as the only readiness authority.

set -u

LAUNCHER_DIR="$(cd "$(dirname "$0")" && pwd -P)"
CLAUDE_SCRIPT="$LAUNCHER_DIR/claude-desktop-veepn-shadowsocks-lock-v5.4.sh"
APP_SCRIPT="$LAUNCHER_DIR/chatgpt-codex-veepn-shadowsocks-lock-v1.1.sh"

LOG_DIR="$HOME/Library/Logs/VeePN-Protected-Launchers"
STAMP="$(date '+%Y%m%d-%H%M%S')"

LABELS=()
LOGS=()
PIDS=()
READY_PATTERNS=()
READY=()
DONE=()
MODES=()
APP_PATHS=()

PF_TOKEN=""
PF_OWNED=0
CLEANING=0
SUDO_KEEPALIVE_PID=""
GUI_MODE="${VEEPN_GUARDIAN_GUI:-0}"
GUI_LOGIN_UID="${VEEPN_GUARDIAN_LOGIN_UID:-}"
GUI_LOGIN_GID="${VEEPN_GUARDIAN_LOGIN_GID:-}"
PID_FILE="${VEEPN_GUARDIAN_PID_FILE:-}"
STOP_FILE="${VEEPN_GUARDIAN_STOP_FILE:-}"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
pid_alive() { local p="${1:-}"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
stop_requested() { [ -n "$STOP_FILE" ] && [ -f "$STOP_FILE" ]; }

signal_launcher_children() {
  local signal="$1"
  local i
  for ((i=0; i<${#PIDS[@]}; i++)); do
    if pid_alive "${PIDS[$i]:-}"; then
      kill -"$signal" "${PIDS[$i]}" 2>/dev/null || true
    fi
  done
}

wait_for_launcher_children() {
  local max_ticks="$1"
  local tick=0
  local i
  local any_alive
  while [ "$tick" -lt "$max_ticks" ]; do
    any_alive=0
    for ((i=0; i<${#PIDS[@]}; i++)); do
      if pid_alive "${PIDS[$i]:-}"; then
        any_alive=1
        break
      fi
    done
    [ "$any_alive" -eq 1 ] || return 0
    sleep 0.1
    tick=$((tick + 1))
  done
  return 1
}

usage() {
  cat <<'USAGE'
Usage:
  guardian-supervisor.command [--claude] [--chatgpt] [--cursor]
                              [--app /path/App.app]
                              [--compatibility-app /path/App.app]...

With no selection arguments, Claude and ChatGPT/Codex are both protected.
Custom applications use the generic fail-closed launcher and do not modify
~/.codex/.env.
Cursor uses an optimized fail-closed profile with an explicit localhost proxy.
Compatibility applications additionally force Electron/Node traffic through
the local proxy bridge for apps that ignore ordinary proxy configuration.
USAGE
}

die() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

safe_file_component() {
  printf '%s' "$1" | tr -cs '[:alnum:]_.-' '-'
}

add_target() {
  local mode="$1"
  local label="$2"
  local path="${3:-}"
  local index="${#LABELS[@]}"
  local safe
  safe="$(safe_file_component "$label")"
  LABELS[$index]="$label"
  MODES[$index]="$mode"
  APP_PATHS[$index]="$path"
  LOGS[$index]="$LOG_DIR/${safe}-${STAMP}-${index}.log"
  PIDS[$index]=""
  READY[$index]=0
  DONE[$index]=0
  if [ "$mode" = "claude" ]; then
    READY_PATTERNS[$index]='PASS: Claude Desktop main process and visible descendants are inside the isolation group.'
  elif [ "$mode" = "cursor" ]; then
    READY_PATTERNS[$index]='PASS: Cursor optimized proxy profile is active.'
  elif [ "$mode" = "compatibility" ]; then
    READY_PATTERNS[$index]="PASS: $label compatibility proxy profile is active."
  else
    READY_PATTERNS[$index]='main process, descendants, and visible bundle helpers are inside the isolation group.'
  fi
}

cleanup() {
  local rc=$?
  [ "$CLEANING" -eq 0 ] || exit "$rc"
  CLEANING=1
  trap - EXIT INT TERM HUP

  local i
  signal_launcher_children TERM
  if ! wait_for_launcher_children 100; then
    log "A launcher is taking too long to stop; retrying cleanup interrupt."
    signal_launcher_children INT
    if ! wait_for_launcher_children 50; then
      log "A launcher did not respond within 15 seconds; forcing its process wrapper to exit."
      signal_launcher_children KILL
    fi
  fi
  for ((i=0; i<${#PIDS[@]}; i++)); do
    [ -z "${PIDS[$i]:-}" ] || wait "${PIDS[$i]}" 2>/dev/null || true
  done

  if [ -n "$SUDO_KEEPALIVE_PID" ]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi

  if [ "$PF_OWNED" -eq 1 ] && [ -n "$PF_TOKEN" ]; then
    log "Releasing shared PF reference."
    sudo -n pfctl -X "$PF_TOKEN" >/dev/null 2>&1 || true
  fi
  [ -z "$STOP_FILE" ] || rm -f "$STOP_FILE" >/dev/null 2>&1 || true
  [ -z "$PID_FILE" ] || rm -f "$PID_FILE" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT INT TERM HUP

explicit=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --claude)
      add_target "claude" "Claude" ""
      explicit=1
      shift ;;
    --chatgpt)
      add_target "chatgpt" "ChatGPT-Codex" ""
      explicit=1
      shift ;;
    --cursor)
      cursor_path=""
      for candidate in "/Applications/Cursor.app" "$HOME/Applications/Cursor.app"; do
        if [ -d "$candidate" ]; then
          cursor_path="$candidate"
          break
        fi
      done
      [ -n "$cursor_path" ] || die "Cursor.app was not found."
      add_target "cursor" "Cursor" "$cursor_path"
      explicit=1
      shift ;;
    --app)
      [ "$#" -ge 2 ] || die "--app requires an application path"
      [ -d "$2" ] || die "Application bundle not found: $2"
      custom_name="$(basename "$2" .app)"
      add_target "generic" "$custom_name" "$2"
      explicit=1
      shift 2 ;;
    --compatibility-app)
      [ "$#" -ge 2 ] || die "--compatibility-app requires an application path"
      [ -d "$2" ] || die "Application bundle not found: $2"
      compatibility_name="$(basename "$2" .app)"
      add_target "compatibility" "$compatibility_name" "$2"
      explicit=1
      shift 2 ;;
    -h|--help)
      usage
      exit 0 ;;
    *)
      die "Unknown option: $1" ;;
  esac
done

if [ "$explicit" -eq 0 ]; then
  add_target "claude" "Claude" ""
  add_target "chatgpt" "ChatGPT-Codex" ""
fi
[ "${#LABELS[@]}" -gt 0 ] || die "Select at least one application."

[ -x "$CLAUDE_SCRIPT" ] || die "Claude protection script is missing."
[ -x "$APP_SCRIPT" ] || die "Application protection script is missing."

clear
cat <<'EOF'
======================================================================
                   VEEPN GUARDIAN — PROTECTED APPS
======================================================================

Required:
  • VeePN is connected using Shadowsocks
  • Keep VeePN connected while protected apps are running

Administrator approval is handled by the trusted macOS authorization dialog.
VeePN Guardian does not read or store the password.
EOF

echo
echo "Selected applications:"
for label in "${LABELS[@]}"; do printf '  • %s\n' "$label"; done

proxy_dump="$(/usr/sbin/scutil --proxy 2>/dev/null || true)"
socks_enable="$(printf '%s\n' "$proxy_dump" | awk '/SOCKSEnable[[:space:]]*:/ {print $3; exit}')"
socks_host="$(printf '%s\n' "$proxy_dump" | awk '/SOCKSProxy[[:space:]]*:/ {print $3; exit}')"
socks_port="$(printf '%s\n' "$proxy_dump" | awk '/SOCKSPort[[:space:]]*:/ {print $3; exit}')"
if [ "$socks_enable" != "1" ] || [ "$socks_host" != "127.0.0.1" ] || [ "$socks_port" != "1080" ]; then
  die "VeePN Shadowsocks is not detected at 127.0.0.1:1080. Connect VeePN using Shadowsocks and try again."
fi

if [ "$GUI_MODE" = "1" ]; then
  log "Protected launch confirmed in VeePN Guardian."
else
  echo
  read -r -p "Type YES to launch the selected apps protected: " answer
  [ "$answer" = "YES" ] || die "Confirmation not received."
fi

mkdir -p "$LOG_DIR"
log "VeePN system SOCKS verified at 127.0.0.1:1080."
if [ "$EUID" -eq 0 ] && [ "$GUI_MODE" = "1" ]; then
  log "Trusted macOS administrator authorization verified for ${#LABELS[@]} protected application(s)."
else
  log "Authenticating sudo once for ${#LABELS[@]} protected application(s)."
  sudo -v || die "sudo authentication failed."
fi

if [ "$EUID" -ne 0 ]; then
  (
    while true; do
      sleep 45
      sudo -n -v >/dev/null 2>&1 || exit 0
    done
  ) &
  SUDO_KEEPALIVE_PID=$!
fi

if ! sudo pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then
  enable_out="$(sudo pfctl -E 2>&1 || true)"
  PF_TOKEN="$(printf '%s\n' "$enable_out" | awk '/Token[[:space:]]*:/ {print $NF; exit}')"
  [ -n "$PF_TOKEN" ] || die "Could not obtain a PF reference token."
  PF_OWNED=1
  log "PF was disabled; Guardian holds the shared PF reference."
else
  log "PF was already enabled; existing PF state will be left untouched."
fi

for ((i=0; i<${#LABELS[@]}; i++)); do
  log "Starting protected ${LABELS[$i]}."
  : >"${LOGS[$i]}"
  if [ "$EUID" -eq 0 ] && [ -n "$GUI_LOGIN_UID" ] && [ -n "$GUI_LOGIN_GID" ]; then
    chown "$GUI_LOGIN_UID:$GUI_LOGIN_GID" "${LOGS[$i]}" 2>/dev/null || true
  fi
  case "${MODES[$i]}" in
    claude)
      /bin/bash "$CLAUDE_SCRIPT" </dev/null >"${LOGS[$i]}" 2>&1 & ;;
    chatgpt)
      /bin/bash "$APP_SCRIPT" </dev/null >"${LOGS[$i]}" 2>&1 & ;;
    cursor)
      /bin/bash "$APP_SCRIPT" --generic-app --cursor-profile --app "${APP_PATHS[$i]}" </dev/null >"${LOGS[$i]}" 2>&1 & ;;
    compatibility)
      /bin/bash "$APP_SCRIPT" --generic-app --compatibility-profile --app "${APP_PATHS[$i]}" </dev/null >"${LOGS[$i]}" 2>&1 & ;;
    generic)
      /bin/bash "$APP_SCRIPT" --generic-app --app "${APP_PATHS[$i]}" </dev/null >"${LOGS[$i]}" 2>&1 & ;;
  esac
  PIDS[$i]=$!
  sleep 1
done

echo
echo "Private protection logs:"
for ((i=0; i<${#LABELS[@]}; i++)); do printf '  %-22s %s\n' "${LABELS[$i]}:" "${LOGS[$i]}"; done
echo

while true; do
  if stop_requested; then
    log "Authenticated cleanup requested by VeePN Guardian."
    exit 0
  fi
  all_ready=1
  for ((i=0; i<${#LABELS[@]}; i++)); do
    if [ "${READY[$i]}" -eq 0 ]; then
      all_ready=0
      if grep -Fq "${READY_PATTERNS[$i]}" "${LOGS[$i]}" 2>/dev/null; then
        READY[$i]=1
        if [ "${MODES[$i]}" = "cursor" ]; then
          log "✓ Cursor optimized protection verified."
        elif [ "${MODES[$i]}" = "chatgpt" ]; then
          log "✓ ChatGPT/Codex protection verified."
        elif [ "${MODES[$i]}" = "compatibility" ]; then
          log "✓ ${LABELS[$i]} compatibility protection verified."
        else
          log "✓ ${LABELS[$i]} protection verified."
        fi
      elif ! pid_alive "${PIDS[$i]}"; then
        echo
        echo "${LABELS[$i]} exited before its isolation audit passed."
        echo "---- last log lines ----"
        tail -40 "${LOGS[$i]}" 2>/dev/null || true
        echo "------------------------"
        die "${LABELS[$i]} protected launch failed."
      fi
    fi
  done
  [ "$all_ready" -eq 1 ] && break
  sleep 1
done

cat <<'EOF'

======================================================================
                 SELECTED APPS ARE FAIL-CLOSED PROTECTED
======================================================================

Allowed: selected apps → localhost bridge → VeePN Shadowsocks
Blocked: direct TCP/UDP from their temporary isolation groups

Quit applications normally in any order. The shared firewall reference
remains active until every selected protected session has ended.
======================================================================
EOF

while true; do
  if stop_requested; then
    log "Authenticated cleanup requested by VeePN Guardian."
    exit 0
  fi
  all_done=1
  for ((i=0; i<${#LABELS[@]}; i++)); do
    if [ "${DONE[$i]}" -eq 0 ]; then
      all_done=0
      if ! pid_alive "${PIDS[$i]}"; then
        wait "${PIDS[$i]}" 2>/dev/null
        child_rc=$?
        DONE[$i]=1
        log "${LABELS[$i]} protected session ended (status $child_rc)."
      fi
    fi
  done
  [ "$all_done" -eq 1 ] && break
  sleep 1
done

if [ -n "$SUDO_KEEPALIVE_PID" ]; then
  kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
fi
SUDO_KEEPALIVE_PID=""
log "All protected sessions have ended."
log "Temporary proxy, group, bridge, and PF-anchor changes were restored."
exit 0
