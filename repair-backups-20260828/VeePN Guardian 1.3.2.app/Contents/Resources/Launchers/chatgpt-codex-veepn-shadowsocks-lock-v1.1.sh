#!/bin/bash
# chatgpt-codex-veepn-shadowsocks-lock-v1.sh
#
# Strict fail-closed launcher for the ChatGPT desktop app / Codex on macOS.
# Designed for VeePN Shadowsocks exposing SOCKS5 at 127.0.0.1:1080.
#
# Protection layers:
#   1. The desktop app receives HTTP(S)_PROXY pointing to a localhost
#      HTTP CONNECT -> VeePN SOCKS5 bridge.
#   2. ~/.codex/.env is temporarily patched with the same proxy variables so
#      Codex local sessions/subprocesses have an explicit supported proxy path.
#   3. The app is launched under a temporary effective Unix group.
#   4. PF blocks that group's direct TCP/UDP egress on physical interfaces.
#   5. The launcher verifies macOS system SOCKS points to VeePN for native
#      ChatGPT/Codex UI networking that may use CFNetwork/system proxy settings.
#   6. Physical DNS/DoT is blocked while the protected session is active; the
#      explicit bridge uses SOCKS5 remote DNS.
#
# The script restores ~/.codex/.env proxy keys, PF state, temporary group,
# and the local bridge when ChatGPT/Codex exits.
#
# IMPORTANT:
#   - Do not authorize sudo/root networking from Codex; root can escape the
#     temporary group firewall boundary.
#   - External apps deliberately launched by Codex (for example Chrome via
#     LaunchServices) are separate processes and are outside this process guard.
#     The ChatGPT built-in browser, when it remains in the app process tree,
#     is covered.
#   - Remote/cloud Codex execution happens off this Mac; only the desktop app's
#     local network traffic is governed by this Mac-local boundary.

set -euo pipefail

VERSION="1.1"
SOCKS_HOST="127.0.0.1"
SOCKS_PORT="1080"
CHECK_URL="https://api.ipify.org"
ANCHOR="com.apple/chatgpt-codex-vpn-$$"
GROUP_NAME="cgptvpn$$"
GROUP_GID=""
PF_TOKEN=""
PF_ENABLED_BY_US=0
GUARD_INSTALLED=0
GROUP_CREATED=0
CODEX_ENV_PATCHED=0
PATCH_CODEX_ENV=1
COMPATIBILITY_PROFILE=0
CURSOR_PROFILE=0
CURSOR_SETTINGS_PATCHED=0
APP_WRAPPER_PID=""
APP_MAIN_PID=""
BRIDGE_PID=""
BRIDGE_PORT=""
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/chatgpt-codex-vpn.XXXXXX")"
BRIDGE_SCRIPT="$TMPROOT/http_to_socks.py"
BRIDGE_PORT_FILE="$TMPROOT/bridge.port"
BRIDGE_LOG="$TMPROOT/bridge.log"
PF_RULES="$TMPROOT/pf.rules"
CODEX_ENV_STATE="$TMPROOT/codex-env-state.json"
CODEX_ENV_FILE="$HOME/.codex/.env"
CURSOR_SETTINGS_STATE="$TMPROOT/cursor-settings-state.json"
CURSOR_SETTINGS_BACKUP="$TMPROOT/cursor-settings-original.json"
CURSOR_SETTINGS_FILE="$HOME/Library/Application Support/Cursor/User/settings.json"
GUI_ROOT_MODE=0
if [ "$EUID" -eq 0 ] && [ "${VEEPN_GUARDIAN_GUI:-0}" = "1" ]; then
  GUI_ROOT_MODE=1
  LOGIN_USER="${VEEPN_GUARDIAN_LOGIN_USER:-}"
  LOGIN_UID="${VEEPN_GUARDIAN_LOGIN_UID:-}"
  LOGIN_GID="${VEEPN_GUARDIAN_LOGIN_GID:-}"
  [ -n "$LOGIN_USER" ] && [ -n "$LOGIN_UID" ] && [ -n "$LOGIN_GID" ] || {
    printf '\nERROR: Guardian login identity is incomplete.\n' >&2
    exit 1
  }
else
  LOGIN_USER="$(id -un)"
  LOGIN_UID="$(id -u)"
  LOGIN_GID="$(id -g)"
fi
LOGIN_HOME="$HOME"
ORIGINAL_PATH="$PATH"
GUARDED_IFS=()
APP_PATH=""
APP_EXEC=""
APP_NAME=""
APP_BUNDLE_ID=""
GUARDIAN_STOP_FILE="${VEEPN_GUARDIAN_STOP_FILE:-}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
guardian_stop_requested() { [ -n "$GUARDIAN_STOP_FILE" ] && [ -f "$GUARDIAN_STOP_FILE" ]; }
exit_if_guardian_stop_requested() {
  if guardian_stop_requested; then
    log "Authenticated cleanup request detected; stopping before the next launch phase."
    exit 0
  fi
}


# Return only the actual selected app main executable, not stale helpers.
app_main_pids() {
  ps -axo pid=,command= 2>/dev/null | awk -v exe="$APP_EXEC" '
    {
      pid=$1
      $1=""
      sub(/^[[:space:]]+/, "", $0)
      cmd=$0
      if (cmd == exe || index(cmd, exe " ") == 1) print pid
    }'
}

# Return processes whose executable command lives inside this app bundle.
# Because startup requires the app to be fully quit first, any such process
# appearing after launch should belong to the protected instance.
app_bundle_pids() {
  ps -axo pid=,command= 2>/dev/null | awk -v prefix="$APP_PATH/Contents/" '
    {
      pid=$1
      $1=""
      sub(/^[[:space:]]+/, "", $0)
      cmd=$0
      if (index(cmd, prefix) == 1) print pid
    }'
}

# Return every login-user process that still carries this launcher's temporary
# effective group. Electron crash handlers and Codex services can detach from
# the visible app process, so the main PID alone is not a complete cleanup
# boundary.
isolation_group_pids() {
  [ -n "${GROUP_GID:-}" ] || return 0
  ps -axo pid=,gid=,user= 2>/dev/null | awk \
    -v gid="$GROUP_GID" -v user="$LOGIN_USER" '
      $1 ~ /^[0-9]+$/ && $2 == gid && $3 == user { print $1 }
    '
}

# Terminate processes left inside the selected app bundle. Normally this runs
# only after the app's visible main process has quit. For the dedicated
# ChatGPT/Codex profile it is also the bounded fallback when that app ignores
# its normal quit request; pressing Connect explicitly authorizes its restart.
purge_stale_bundle_processes() {
  local pids=""
  local remaining=""
  local pid=""
  local i=0

  pids="$(app_bundle_pids)"
  [ -n "$pids" ] || return 0
  log "Stopping stale $APP_NAME bundle helper process(es): $(printf '%s\n' "$pids" | tr '\n' ' ')"

  for pid in $pids; do
    kill -TERM "$pid" 2>/dev/null || true
  done

  while [ "$i" -lt 30 ]; do
    remaining="$(app_bundle_pids)"
    [ -z "$remaining" ] && return 0
    sleep 0.1
    i=$((i+1))
  done

  # These are detached helpers after the main executable has already exited;
  # forcing them down cannot bypass app document-save confirmation.
  for pid in $remaining; do
    kill -KILL "$pid" 2>/dev/null || true
  done

  i=0
  while [ "$i" -lt 20 ]; do
    [ -z "$(app_bundle_pids)" ] && return 0
    sleep 0.1
    i=$((i+1))
  done

  log "Remaining bundle PID(s): $(app_bundle_pids | tr '\n' ' ')"
  return 1
}

# Drain all processes in the temporary isolation group before deleting it.
# This prevents detached crash reporters, app servers, and extension hosts from
# surviving with an orphaned numeric GID and breaking the next protected run.
drain_isolation_group() {
  local pids=""
  local remaining=""
  local pid=""
  local i=0

  pids="$(isolation_group_pids)"
  [ -n "$pids" ] || return 0
  log "Stopping remaining $APP_NAME isolation-group process(es): $(printf '%s\n' "$pids" | tr '\n' ' ')"

  for pid in $pids; do
    kill -TERM "$pid" 2>/dev/null || true
  done

  while [ "$i" -lt 30 ]; do
    remaining="$(isolation_group_pids)"
    [ -z "$remaining" ] && return 0
    sleep 0.1
    i=$((i+1))
  done

  for pid in $remaining; do
    kill -KILL "$pid" 2>/dev/null || true
  done

  i=0
  while [ "$i" -lt 20 ]; do
    [ -z "$(isolation_group_pids)" ] && return 0
    sleep 0.1
    i=$((i+1))
  done

  log "WARNING: isolation-group process(es) did not exit: $(isolation_group_pids | tr '\n' ' ')"
  return 1
}


# Print PID plus every descendant PID of a root process.
# This lets us audit only the process tree actually launched inside our
# protected boundary instead of every stale ChatGPT/Codex helper on the machine.
descendant_pids() {
  local root="$1"

  # On macOS/BSD ps, use separate -o arguments.  The previous
  # `pid=,ppid=` form produced malformed output on this Monterey machine.
  ps -A -o pid= -o ppid= 2>/dev/null | awk -v root="$root" '
    {
      p=$1
      parent=$2
      if (p ~ /^[0-9]+$/ && parent ~ /^[0-9]+$/) {
        pid[n]=p
        ppid[n]=parent
        n++
      }
    }
    END {
      wanted[root]=1
      changed=1
      while (changed) {
        changed=0
        for (i=0; i<n; i++) {
          if (wanted[ppid[i]] && !wanted[pid[i]]) {
            wanted[pid[i]]=1
            changed=1
          }
        }
      }
      for (i=0; i<n; i++) {
        if (wanted[pid[i]]) print pid[i]
      }
      if (wanted[root]) print root
    }' | awk 'NF && !seen[$0]++'
}

usage() {
  cat <<'USAGE'
Usage:
  chatgpt-codex-veepn-shadowsocks-lock-v1.sh [options]

Options:
  --guard-if IFACE      Guard a specific interface. May be repeated.
  --physical-if IFACE   Alias for --guard-if.   Interface to guard. May be repeated; --guard-if is preferred.
  --socks-host HOST     VeePN SOCKS5 host (default 127.0.0.1)
  --socks-port PORT     VeePN SOCKS5 port (default 1080)
  --check-url URL       HTTPS URL used for protected-path verification.
  --app PATH            ChatGPT.app or Codex.app path.
  --generic-app         Protect --app without modifying ~/.codex/.env.
  --compatibility-profile
                        Force Electron/Node networking through the HTTP bridge.
  --cursor-profile      Use Cursor's explicit proxy and HTTP/1.1 compatibility profile.
  -h, --help            Show this help.

Normal use:
  1. Connect VeePN using Shadowsocks.
  2. Fully quit ChatGPT/Codex.
  3. Run this script and keep its Terminal window open.
  4. Use ChatGPT/Codex normally.

The launcher auto-detects, in order:
  /Applications/ChatGPT.app
  ~/Applications/ChatGPT.app
  /Applications/Codex.app
  ~/Applications/Codex.app

Cleanup is automatic when the protected app exits.
USAGE
}
bounded_kill() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; return 0; }
  kill -TERM "$pid" 2>/dev/null || true
  local i=0
  while [ "$i" -lt 25 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 0.1
    i=$((i+1))
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

restore_codex_env() {
  (( CODEX_ENV_PATCHED )) || return 0
  [ -f "$CODEX_ENV_STATE" ] || return 0

  /usr/bin/python3 - "$CODEX_ENV_FILE" "$CODEX_ENV_STATE" <<'PY' >/dev/null 2>&1 || true
import json, os, re, sys, tempfile

env_path, state_path = sys.argv[1:3]
try:
    with open(state_path, "r", encoding="utf-8") as f:
        state = json.load(f)
except Exception:
    raise SystemExit(0)

keys = set(state.get("keys", []))
try:
    with open(env_path, "r", encoding="utf-8") as f:
        current = f.readlines()
except FileNotFoundError:
    current = []

pat = re.compile(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=')
kept = []
for line in current:
    if line.rstrip("\n") == '# Temporary VeePN fail-closed proxy settings; restored by launcher.':
        continue
    m = pat.match(line)
    if m and m.group(1) in keys:
        continue
    kept.append(line)

# Restore the exact original target-key lines.
original_target_lines = state.get("original_target_lines", [])
if original_target_lines:
    if kept and not kept[-1].endswith("\n"):
        kept[-1] += "\n"
    kept.extend(original_target_lines)

if state.get("file_was_absent") and not kept:
    try:
        os.unlink(env_path)
    except FileNotFoundError:
        pass
    raise SystemExit(0)

os.makedirs(os.path.dirname(env_path), exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".env.restore.", dir=os.path.dirname(env_path))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.writelines(kept)
    os.replace(tmp, env_path)
finally:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
PY
  if [ "$GUI_ROOT_MODE" -eq 1 ] && [ -e "$CODEX_ENV_FILE" ]; then
    chown "$LOGIN_UID:$LOGIN_GID" "$CODEX_ENV_FILE" >/dev/null 2>&1 || true
  fi
}

patch_cursor_settings() {
  local proxy="$1"
  mkdir -p "$(dirname "$CURSOR_SETTINGS_FILE")"

  /usr/bin/python3 - "$CURSOR_SETTINGS_FILE" "$CURSOR_SETTINGS_BACKUP" \
    "$CURSOR_SETTINGS_STATE" "$proxy" <<'PY' || return 1
import hashlib, json, os, sys, tempfile

settings_path, backup_path, state_path, proxy = sys.argv[1:5]
keys = ("http.proxy", "http.proxySupport", "cursor.general.disableHttp2")

def parse_jsonc(raw):
    text = raw.decode("utf-8")
    out = []
    i = 0
    in_string = False
    escaped = False
    while i < len(text):
        ch = text[i]
        if in_string:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == "/" and i + 1 < len(text) and text[i + 1] == "/":
            i += 2
            while i < len(text) and text[i] not in "\r\n":
                i += 1
            continue
        if ch == "/" and i + 1 < len(text) and text[i + 1] == "*":
            i += 2
            while i + 1 < len(text) and text[i:i + 2] != "*/":
                if text[i] in "\r\n":
                    out.append(text[i])
                i += 1
            i = min(i + 2, len(text))
            continue
        if ch == ",":
            j = i + 1
            while j < len(text) and text[j].isspace():
                j += 1
            if j < len(text) and text[j] in "}]":
                i += 1
                continue
        out.append(ch)
        i += 1
    cleaned = "".join(out).strip()
    return json.loads(cleaned) if cleaned else {}

file_was_absent = not os.path.exists(settings_path)
raw = b"{}\n" if file_was_absent else open(settings_path, "rb").read()
if not file_was_absent:
    with open(backup_path, "wb") as f:
        f.write(raw)
data = parse_jsonc(raw)
if not isinstance(data, dict):
    raise SystemExit("Cursor settings root is not an object")

original = {}
for key in keys:
    original[key] = {"present": key in data, "value": data.get(key)}
data["http.proxy"] = proxy
data["http.proxySupport"] = "override"
data["cursor.general.disableHttp2"] = True
encoded = (json.dumps(data, ensure_ascii=False, indent=4) + "\n").encode("utf-8")

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix="settings.guardian.", dir=os.path.dirname(settings_path))
try:
    with os.fdopen(fd, "wb") as f:
        f.write(encoded)
    os.replace(temporary, settings_path)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass

state = {
    "file_was_absent": file_was_absent,
    "original": original,
    "patched_sha256": hashlib.sha256(encoded).hexdigest(),
}
with open(state_path, "w", encoding="utf-8") as f:
    json.dump(state, f)
PY
  if [ "$GUI_ROOT_MODE" -eq 1 ]; then
    chown "$LOGIN_UID:$LOGIN_GID" "$(dirname "$(dirname "$CURSOR_SETTINGS_FILE")")" >/dev/null 2>&1 || true
    chown "$LOGIN_UID:$LOGIN_GID" "$(dirname "$CURSOR_SETTINGS_FILE")" >/dev/null 2>&1 || true
    chown "$LOGIN_UID:$LOGIN_GID" "$CURSOR_SETTINGS_FILE" >/dev/null 2>&1 || true
  fi
  CURSOR_SETTINGS_PATCHED=1
}

restore_cursor_settings() {
  (( CURSOR_SETTINGS_PATCHED )) || return 0
  [ -f "$CURSOR_SETTINGS_STATE" ] || return 0

  if ! /usr/bin/python3 - "$CURSOR_SETTINGS_FILE" "$CURSOR_SETTINGS_BACKUP" \
    "$CURSOR_SETTINGS_STATE" <<'PY'
import hashlib, json, os, sys, tempfile

settings_path, backup_path, state_path = sys.argv[1:4]
with open(state_path, "r", encoding="utf-8") as f:
    state = json.load(f)

try:
    current = open(settings_path, "rb").read()
except FileNotFoundError:
    current = b""

if hashlib.sha256(current).hexdigest() == state.get("patched_sha256"):
    if state.get("file_was_absent"):
        try:
            os.unlink(settings_path)
        except FileNotFoundError:
            pass
    else:
        original = open(backup_path, "rb").read()
        fd, temporary = tempfile.mkstemp(prefix="settings.restore.", dir=os.path.dirname(settings_path))
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(original)
            os.replace(temporary, settings_path)
        finally:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
    raise SystemExit(0)

# Cursor or the user changed settings during the session. Preserve those
# changes and restore only Guardian's three temporary keys.
try:
    data = json.loads(current.decode("utf-8")) if current.strip() else {}
except Exception as exc:
    raise SystemExit("changed Cursor settings could not be parsed: %s" % exc)
if not isinstance(data, dict):
    raise SystemExit("changed Cursor settings root is not an object")
for key, item in state.get("original", {}).items():
    if item.get("present"):
        data[key] = item.get("value")
    else:
        data.pop(key, None)
encoded = (json.dumps(data, ensure_ascii=False, indent=4) + "\n").encode("utf-8")
fd, temporary = tempfile.mkstemp(prefix="settings.restore.", dir=os.path.dirname(settings_path))
try:
    with os.fdopen(fd, "wb") as f:
        f.write(encoded)
    os.replace(temporary, settings_path)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY
  then
    log "WARNING: Cursor settings changed unexpectedly; Guardian left the file untouched rather than risk overwriting it."
    return 0
  fi

  if [ "$GUI_ROOT_MODE" -eq 1 ] && [ -e "$CURSOR_SETTINGS_FILE" ]; then
    chown "$LOGIN_UID:$LOGIN_GID" "$CURSOR_SETTINGS_FILE" >/dev/null 2>&1 || true
  fi
  log "Restored Cursor's original proxy and HTTP compatibility settings."
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP

  if [ -n "${APP_MAIN_PID:-}" ] && kill -0 "$APP_MAIN_PID" 2>/dev/null; then
    log "Stopping protected $APP_NAME main process."
    bounded_kill "$APP_MAIN_PID"
  fi
  if [ -n "${APP_WRAPPER_PID:-}" ] && kill -0 "$APP_WRAPPER_PID" 2>/dev/null; then
    log "Stopping protected $APP_NAME process wrapper."
    bounded_kill "$APP_WRAPPER_PID"
  fi

  drain_isolation_group || true

  restore_codex_env
  restore_cursor_settings

  if [ -n "${BRIDGE_PID:-}" ]; then
    log "Stopping localhost HTTP->SOCKS bridge."
    bounded_kill "$BRIDGE_PID"
  fi

  if (( GUARD_INSTALLED )); then
    log "Removing PF anchor $ANCHOR."
    sudo -n pfctl -a "$ANCHOR" -F rules >/dev/null 2>&1 || true
  fi

  if (( PF_ENABLED_BY_US )); then
    if [ -n "$PF_TOKEN" ]; then
      sudo -n pfctl -X "$PF_TOKEN" >/dev/null 2>&1 || true
    else
      sudo -n pfctl -d >/dev/null 2>&1 || true
    fi
  fi

  if (( GROUP_CREATED )); then
    log "Removing temporary isolation group $GROUP_NAME."
    sudo -n /usr/sbin/dseditgroup -o edit -d "$LOGIN_USER" -t user "$GROUP_NAME" >/dev/null 2>&1 || true
    sudo -n /usr/sbin/dseditgroup -o delete "$GROUP_NAME" >/dev/null 2>&1 || true
  fi

  rm -rf "$TMPROOT" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT INT TERM HUP
exit_if_guardian_stop_requested

while [ "$#" -gt 0 ]; do
  case "$1" in
    --physical-if|--guard-if)
      [ "$#" -ge 2 ] || die "$1 requires an interface"
      GUARDED_IFS+=("$2"); shift 2 ;;
    --socks-host)
      [ "$#" -ge 2 ] || die "--socks-host requires a host"
      SOCKS_HOST="$2"; shift 2 ;;
    --socks-port)
      [ "$#" -ge 2 ] || die "--socks-port requires a port"
      SOCKS_PORT="$2"; shift 2 ;;
    --check-url)
      [ "$#" -ge 2 ] || die "--check-url requires a URL"
      CHECK_URL="$2"; shift 2 ;;
    --app)
      [ "$#" -ge 2 ] || die "--app requires an app bundle path"
      APP_PATH="$2"; shift 2 ;;
    --generic-app)
      PATCH_CODEX_ENV=0; shift ;;
    --compatibility-profile)
      COMPATIBILITY_PROFILE=1
      PATCH_CODEX_ENV=0
      shift ;;
    --cursor-profile)
      COMPATIBILITY_PROFILE=1
      CURSOR_PROFILE=1
      PATCH_CODEX_ENV=0
      shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "Unknown option: $1" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "This launcher is for macOS only."
if [ "$EUID" -eq 0 ] && [ "$GUI_ROOT_MODE" -ne 1 ]; then
  die "Root launch is accepted only through VeePN Guardian's macOS authorization flow."
fi

for cmd in pfctl curl networksetup ifconfig sudo id awk grep python3 nc ps pgrep osascript scutil sed; do
  command -v "$cmd" >/dev/null 2>&1 || die "Required command '$cmd' was not found."
done
[ -x /usr/sbin/dseditgroup ] || die "dseditgroup was not found."
[ -x /usr/bin/dscl ] || die "dscl was not found."

if [ -z "$APP_PATH" ]; then
  for candidate in \
    "/Applications/ChatGPT.app" \
    "$HOME/Applications/ChatGPT.app" \
    "/Applications/Codex.app" \
    "$HOME/Applications/Codex.app"
  do
    if [ -d "$candidate" ]; then
      APP_PATH="$candidate"
      break
    fi
  done
  [ -n "$APP_PATH" ] || die "ChatGPT.app/Codex.app was not found. Use --app /path/to/App.app."
fi

[ -d "$APP_PATH" ] || die "App bundle not found: $APP_PATH"

# Resolve CFBundleExecutable and CFBundleIdentifier instead of assuming names.
app_meta="$(/usr/bin/python3 - "$APP_PATH/Contents/Info.plist" <<'PY'
import plistlib, sys
p=sys.argv[1]
with open(p,'rb') as f:
    d=plistlib.load(f)
print(d.get('CFBundleExecutable',''))
print(d.get('CFBundleIdentifier',''))
PY
)" || die "Could not read app Info.plist."

APP_EXEC_NAME="$(printf '%s\n' "$app_meta" | sed -n '1p')"
APP_BUNDLE_ID="$(printf '%s\n' "$app_meta" | sed -n '2p')"
[ -n "$APP_EXEC_NAME" ] || die "CFBundleExecutable is missing from $APP_PATH/Contents/Info.plist."
APP_EXEC="$APP_PATH/Contents/MacOS/$APP_EXEC_NAME"
[ -x "$APP_EXEC" ] || die "App executable not found at: $APP_EXEC"
APP_NAME="$(basename "$APP_PATH" .app)"

if [ "$CURSOR_PROFILE" -eq 1 ] && [ "$APP_BUNDLE_ID" != "com.todesktop.230313mzl4w4u92" ]; then
  die "The Cursor optimized profile can be used only with the official Cursor.app bundle."
fi
if [ "$COMPATIBILITY_PROFILE" -eq 1 ] && [ "$APP_BUNDLE_ID" = "com.todesktop.230313mzl4w4u92" ]; then
  CURSOR_PROFILE=1
fi

log "ChatGPT/Codex VeePN Shadowsocks fail-closed launcher v$VERSION"
log "App: $APP_PATH"
log "Executable: $APP_EXEC"
log "Bundle ID: ${APP_BUNDLE_ID:-unknown}"
log "Login user: $LOGIN_USER (uid=$LOGIN_UID)"

cat <<EOF

Required state:
  VeePN protocol : Shadowsocks
  VeePN status   : Connected

This launcher protects the selected ChatGPT/Codex desktop process tree.

It will:
  * provide an explicit HTTP(S) proxy bridge to VeePN's SOCKS5 endpoint,
  * temporarily inject proxy variables into ~/.codex/.env for Codex,
  * require macOS system SOCKS to point to the same VeePN endpoint,
  * deny direct physical-interface TCP/UDP with PF,
  * block physical DNS/DoT while the protected session is active,
  * restore all temporary changes when the app exits.

Do NOT authorize sudo/root networking from Codex.
External apps launched outside this process tree are not covered.
EOF

if [ -t 0 ]; then
  read -r -p "Type YES after confirming VeePN Shadowsocks is connected: " answer
  [ "$answer" = "YES" ] || die "Confirmation not received."
fi

# The selected main executable must not already be running. Otherwise the app
# may reuse a process that was created outside our isolation group. Once the
# visible app has quit normally, purge detached helpers from the same bundle so
# the post-launch audit starts from an empty, deterministic process set.
if [ -n "$(app_main_pids)" ]; then
  log "$APP_NAME main process is already running; requesting a clean quit."
  if [ "$GUI_ROOT_MODE" -eq 1 ]; then
    /bin/launchctl asuser "$LOGIN_UID" /usr/bin/sudo -n -u "$LOGIN_USER" \
      /usr/bin/osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  else
    /usr/bin/osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  fi
  i=0
  while [ "$i" -lt 50 ]; do
    [ -z "$(app_main_pids)" ] && break
    sleep 0.2
    i=$((i+1))
  done
  if [ -n "$(app_main_pids)" ]; then
    log "Actual remaining main PID(s): $(app_main_pids | tr '\n' ' ')"
    if [ "$PATCH_CODEX_ENV" -eq 1 ]; then
      log "$APP_NAME did not respond to its normal quit request; forcing the explicitly authorized protected restart."
      if ! purge_stale_bundle_processes; then
        die "$APP_NAME could not be restarted cleanly. Restart macOS, then retry."
      fi
    else
      die "$APP_NAME did not quit. Save your work, quit/force-quit it, then rerun."
    fi
  fi
  log "Previous $APP_NAME main process fully exited."
else
  log "$APP_NAME main process is not running."
fi
[ -z "$(app_main_pids)" ] || die "$APP_NAME main executable is still running after the authorized restart."
if ! purge_stale_bundle_processes; then
  die "Stale $APP_NAME helper processes could not be stopped. Restart macOS, then retry."
fi
log "PASS: no stale $APP_NAME bundle processes remain."
exit_if_guardian_stop_requested

log "Checking VeePN SOCKS5 endpoint $SOCKS_HOST:$SOCKS_PORT."
if ! /usr/bin/nc -z -w 2 "$SOCKS_HOST" "$SOCKS_PORT" >/dev/null 2>&1; then
  die "Nothing is listening on $SOCKS_HOST:$SOCKS_PORT. Confirm VeePN Shadowsocks is connected."
fi

log "Verifying VeePN SOCKS5 with remote DNS."
SOCKS_IP="$(/usr/bin/curl -4fsS --socks5-hostname "$SOCKS_HOST:$SOCKS_PORT" \
  --connect-timeout 5 --max-time 12 "$CHECK_URL" 2>/dev/null || true)"
[[ "$SOCKS_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  die "VeePN SOCKS5 is listening but could not reach the verification URL."
log "VeePN SOCKS5 public IPv4: $SOCKS_IP"

log "Verifying macOS system SOCKS points to VeePN."
proxy_dump="$(/usr/sbin/scutil --proxy 2>/dev/null || true)"
sys_socks_enable="$(printf '%s\n' "$proxy_dump" | awk '/SOCKSEnable[[:space:]]*:/ {print $3; exit}')"
sys_socks_host="$(printf '%s\n' "$proxy_dump" | awk '/SOCKSProxy[[:space:]]*:/ {print $3; exit}')"
sys_socks_port="$(printf '%s\n' "$proxy_dump" | awk '/SOCKSPort[[:space:]]*:/ {print $3; exit}')"
[ "$sys_socks_enable" = "1" ] || \
  die "macOS system SOCKS proxy is not enabled. Reconnect VeePN using Shadowsocks."
[ "$sys_socks_host" = "$SOCKS_HOST" ] || \
  die "macOS system SOCKS host is ${sys_socks_host:-unset}, expected $SOCKS_HOST."
[ "$sys_socks_port" = "$SOCKS_PORT" ] || \
  die "macOS system SOCKS port is ${sys_socks_port:-unset}, expected $SOCKS_PORT."
log "PASS: macOS system SOCKS is $sys_socks_host:$sys_socks_port."
exit_if_guardian_stop_requested

# Guard every currently active non-loopback interface.  The protected process
# only needs lo0 to reach the localhost HTTP bridge / VeePN SOCKS endpoint.
# This closes alternate egress over Ethernet/Wi-Fi, bridge, awdl, or utun links.
if [ "${#GUARDED_IFS[@]}" -eq 0 ]; then
  while IFS= read -r dev; do
    [ -n "$dev" ] || continue
    [ "$dev" = "lo0" ] && continue
    if ifconfig "$dev" >/dev/null 2>&1 && \
       ifconfig "$dev" 2>/dev/null | head -1 | grep -q '<.*UP'; then
      GUARDED_IFS+=("$dev")
    fi
  done < <(ifconfig -l 2>/dev/null | tr ' ' '\n')
fi

tmp_if="$TMPROOT/interfaces"
printf '%s\n' "${GUARDED_IFS[@]}" | awk 'NF && $0 != "lo0" && !seen[$0]++' > "$tmp_if"
GUARDED_IFS=()
while IFS= read -r dev; do
  [ -n "$dev" ] && GUARDED_IFS+=("$dev")
done < "$tmp_if"
[ "${#GUARDED_IFS[@]}" -gt 0 ] || die "No active non-loopback interface found. Retry with --guard-if en0."
log "Non-loopback interface(s) guarded: ${GUARDED_IFS[*]}"

# Embedded HTTP CONNECT -> SOCKS5 bridge.
cat > "$BRIDGE_SCRIPT" <<'PYBRIDGE'
#!/usr/bin/env python3
import argparse
import ipaddress
import select
import socket
import socketserver
import struct
import sys
import threading
from urllib.parse import urlsplit

BUF = 65536

def recvn(sock, n):
    data = bytearray()
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise OSError("unexpected EOF")
        data.extend(chunk)
    return bytes(data)

def socks5_connect(proxy_host, proxy_port, host, port, timeout=12):
    s = socket.create_connection((proxy_host, proxy_port), timeout=timeout)
    s.settimeout(timeout)
    s.sendall(b"\x05\x01\x00")
    if recvn(s, 2) != b"\x05\x00":
        s.close()
        raise OSError("SOCKS5 proxy rejected no-authentication method")

    try:
        ip = ipaddress.ip_address(host)
        if ip.version == 4:
            atyp = b"\x01"
            addr = ip.packed
        else:
            atyp = b"\x04"
            addr = ip.packed
    except ValueError:
        raw = host.encode("idna")
        if len(raw) > 255:
            s.close()
            raise OSError("target hostname too long")
        atyp = b"\x03"
        addr = bytes([len(raw)]) + raw

    req = b"\x05\x01\x00" + atyp + addr + struct.pack("!H", int(port))
    s.sendall(req)

    head = recvn(s, 4)
    if head[0] != 5 or head[1] != 0:
        s.close()
        raise OSError("SOCKS5 connect failed, reply=%d" % (head[1],))

    atyp = head[3]
    if atyp == 1:
        recvn(s, 4)
    elif atyp == 3:
        ln = recvn(s, 1)[0]
        recvn(s, ln)
    elif atyp == 4:
        recvn(s, 16)
    else:
        s.close()
        raise OSError("invalid SOCKS5 address type")
    recvn(s, 2)
    s.settimeout(None)
    return s

def relay(a, b):
    sockets = [a, b]
    try:
        while True:
            r, _, _ = select.select(sockets, [], [], 60)
            if not r:
                continue
            for src in r:
                dst = b if src is a else a
                data = src.recv(BUF)
                if not data:
                    return
                dst.sendall(data)
    finally:
        for s in sockets:
            try:
                s.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
            try:
                s.close()
            except Exception:
                pass

class Handler(socketserver.StreamRequestHandler):
    timeout = 30

    def send_error_simple(self, code, text):
        body = (text + "\n").encode()
        self.wfile.write(
            ("HTTP/1.1 %d %s\r\nConnection: close\r\nContent-Length: %d\r\n\r\n"
             % (code, text, len(body))).encode() + body
        )

    def handle(self):
        try:
            first = self.rfile.readline(65537)
            if not first or len(first) > 65536:
                return
            try:
                method, target, version = first.decode("iso-8859-1").rstrip("\r\n").split(" ", 2)
            except ValueError:
                self.send_error_simple(400, "Bad Request")
                return

            headers = []
            host_header = None
            while True:
                line = self.rfile.readline(65537)
                if not line or len(line) > 65536:
                    return
                if line in (b"\r\n", b"\n"):
                    break
                headers.append(line)
                if line.lower().startswith(b"host:"):
                    host_header = line.split(b":", 1)[1].strip().decode("iso-8859-1")

            if method.upper() == "CONNECT":
                host, port = self.parse_hostport(target, 443)
                upstream = socks5_connect(self.server.socks_host, self.server.socks_port, host, port)
                self.wfile.write(b"HTTP/1.1 200 Connection Established\r\nProxy-Agent: clvpn-bridge\r\n\r\n")
                self.wfile.flush()
                relay(self.connection, upstream)
                return

            # Plain HTTP proxying. Keep DNS remote by giving the hostname directly
            # to SOCKS5 instead of resolving it locally.
            parts = urlsplit(target)
            if parts.scheme and parts.hostname:
                if parts.scheme.lower() != "http":
                    self.send_error_simple(400, "Unsupported absolute URI scheme")
                    return
                host = parts.hostname
                port = parts.port or 80
                path = parts.path or "/"
                if parts.query:
                    path += "?" + parts.query
            else:
                if not host_header:
                    self.send_error_simple(400, "Host header required")
                    return
                host, port = self.parse_hostport(host_header, 80)
                path = target

            upstream = socks5_connect(self.server.socks_host, self.server.socks_port, host, port)
            upstream.sendall(("%s %s %s\r\n" % (method, path, version)).encode("iso-8859-1"))
            for line in headers:
                # Remove hop-by-hop proxy headers; preserve everything else.
                lower = line.lower()
                if lower.startswith(b"proxy-connection:") or lower.startswith(b"proxy-authorization:"):
                    continue
                upstream.sendall(line)
            upstream.sendall(b"Connection: close\r\n\r\n")

            # Forward request body if Content-Length is present.
            content_length = 0
            for line in headers:
                if line.lower().startswith(b"content-length:"):
                    try:
                        content_length = int(line.split(b":",1)[1].strip())
                    except Exception:
                        content_length = 0
            if content_length:
                upstream.sendall(recvn(self.connection, content_length))

            # Stream the response.
            while True:
                data = upstream.recv(BUF)
                if not data:
                    break
                self.connection.sendall(data)
            upstream.close()
        except Exception as e:
            try:
                self.send_error_simple(502, "Bad Gateway")
            except Exception:
                pass

    @staticmethod
    def parse_hostport(value, default_port):
        value = value.strip()
        if value.startswith("["):
            end = value.find("]")
            if end < 0:
                raise ValueError("bad IPv6 host")
            host = value[1:end]
            rest = value[end+1:]
            port = int(rest[1:]) if rest.startswith(":") else default_port
            return host, port
        if value.count(":") == 1:
            host, p = value.rsplit(":", 1)
            if p.isdigit():
                return host, int(p)
        return value, default_port

class ThreadingServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen-host", default="127.0.0.1")
    ap.add_argument("--listen-port", type=int, default=0)
    ap.add_argument("--socks-host", default="127.0.0.1")
    ap.add_argument("--socks-port", type=int, default=1080)
    ap.add_argument("--port-file", required=True)
    args = ap.parse_args()

    with ThreadingServer((args.listen_host, args.listen_port), Handler) as srv:
        srv.socks_host = args.socks_host
        srv.socks_port = args.socks_port
        port = srv.server_address[1]
        with open(args.port_file, "w") as f:
            f.write(str(port))
            f.flush()
        print("HTTP bridge listening on %s:%d -> SOCKS5 %s:%d"
              % (args.listen_host, port, args.socks_host, args.socks_port), flush=True)
        srv.serve_forever(poll_interval=0.2)

if __name__ == "__main__":
    main()
PYBRIDGE
chmod 700 "$BRIDGE_SCRIPT"

log "Starting localhost HTTP CONNECT bridge -> VeePN SOCKS5."
/usr/bin/python3 "$BRIDGE_SCRIPT" \
  --listen-host 127.0.0.1 --listen-port 0 \
  --socks-host "$SOCKS_HOST" --socks-port "$SOCKS_PORT" \
  --port-file "$BRIDGE_PORT_FILE" >"$BRIDGE_LOG" 2>&1 &
BRIDGE_PID=$!
disown "$BRIDGE_PID" 2>/dev/null || true

i=0
while [ "$i" -lt 50 ]; do
  if [ -s "$BRIDGE_PORT_FILE" ]; then
    BRIDGE_PORT="$(cat "$BRIDGE_PORT_FILE")"
    break
  fi
  if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
    cat "$BRIDGE_LOG" >&2 || true
    die "HTTP bridge exited before becoming ready."
  fi
  sleep 0.1
  i=$((i+1))
done
[[ "$BRIDGE_PORT" =~ ^[0-9]+$ ]] || die "HTTP bridge did not become ready."

HTTP_PROXY_URL="http://127.0.0.1:$BRIDGE_PORT"
log "Local HTTP proxy bridge: $HTTP_PROXY_URL"

BRIDGE_IP="$(/usr/bin/curl -4fsS -x "$HTTP_PROXY_URL" --noproxy '' \
  --connect-timeout 5 --max-time 12 "$CHECK_URL" 2>/dev/null || true)"
[ "$BRIDGE_IP" = "$SOCKS_IP" ] || \
  die "HTTP bridge verification failed (SOCKS=$SOCKS_IP bridge=${BRIDGE_IP:-none})."
log "PASS: HTTP bridge exits through VeePN at $BRIDGE_IP."

log "Requesting sudo for temporary group/PF setup."
sudo -v

base_gid=$((57000 + ($$ % 500)))
GROUP_GID="$base_gid"
while /usr/bin/dscl . -search /Groups PrimaryGroupID "$GROUP_GID" 2>/dev/null | grep -q .; do
  GROUP_GID=$((GROUP_GID + 1))
  [ "$GROUP_GID" -lt 58000 ] || die "Could not find a free temporary group ID."
done

log "Creating temporary isolation group $GROUP_NAME (gid=$GROUP_GID)."
sudo /usr/sbin/dseditgroup -o create -i "$GROUP_GID" "$GROUP_NAME" >/dev/null
GROUP_CREATED=1
sudo /usr/sbin/dseditgroup -o edit -a "$LOGIN_USER" -t user "$GROUP_NAME" >/dev/null
probe_gid="$(sudo -n -u "$LOGIN_USER" -g "$GROUP_NAME" /usr/bin/id -g 2>/dev/null || true)"
[ "$probe_gid" = "$GROUP_GID" ] || die "Could not establish effective-group isolation."
log "Effective-group isolation verified."

if ! sudo pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then
  enable_out="$(sudo pfctl -E 2>&1 || true)"
  PF_TOKEN="$(printf '%s\n' "$enable_out" | awk '/Token[[:space:]]*:/ {print $NF; exit}')"
  PF_ENABLED_BY_US=1
  log "PF was disabled; enabled temporarily${PF_TOKEN:+ with reference token}."
else
  log "PF already enabled; existing rules remain intact."
fi

: > "$PF_RULES"
for dev in "${GUARDED_IFS[@]}"; do
  printf 'block drop out quick on %s inet proto { tcp udp } from any to any group %s\n' \
    "$dev" "$GROUP_GID" >> "$PF_RULES"
  printf 'block drop out quick on %s inet6 proto { tcp udp } from any to any group %s\n' \
    "$dev" "$GROUP_GID" >> "$PF_RULES"

  # Prevent OS resolver leakage on every guarded non-loopback interface.
  printf 'block drop out quick on %s inet proto { tcp udp } from any to any port 53\n' "$dev" >> "$PF_RULES"
  printf 'block drop out quick on %s inet6 proto { tcp udp } from any to any port 53\n' "$dev" >> "$PF_RULES"
  printf 'block drop out quick on %s inet proto { tcp udp } from any to any port 853\n' "$dev" >> "$PF_RULES"
  printf 'block drop out quick on %s inet6 proto { tcp udp } from any to any port 853\n' "$dev" >> "$PF_RULES"
done

sudo pfctl -vnf "$PF_RULES" >/dev/null 2>&1 || {
  cat "$PF_RULES" >&2
  die "macOS PF rejected the generated rules."
}
sudo pfctl -a "$ANCHOR" -f "$PF_RULES" >/dev/null
GUARD_INSTALLED=1
log "PF guard installed in anchor $ANCHOR."

restricted() {
  if [ "$GUI_ROOT_MODE" -eq 1 ]; then
    /bin/launchctl asuser "$LOGIN_UID" /usr/bin/sudo -n -u "$LOGIN_USER" -g "$GROUP_NAME" \
      /usr/bin/env HOME="$LOGIN_HOME" USER="$LOGIN_USER" LOGNAME="$LOGIN_USER" PATH="$ORIGINAL_PATH" \
      "$@"
  else
    sudo -n -u "$LOGIN_USER" -g "$GROUP_NAME" \
      /usr/bin/env HOME="$LOGIN_HOME" USER="$LOGIN_USER" LOGNAME="$LOGIN_USER" PATH="$ORIGINAL_PATH" \
      "$@"
  fi
}

for dev in "${GUARDED_IFS[@]}"; do
  if ! ifconfig "$dev" 2>/dev/null | grep -qE '^[[:space:]]*inet '; then
    log "PF guard active on $dev (no IPv4 leak test: interface has no IPv4 address)."
    continue
  fi
  log "PF leak test: restricted direct HTTPS on $dev must fail."
  if restricted /usr/bin/env \
      HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= NO_PROXY='*' \
      http_proxy= https_proxy= all_proxy= no_proxy='*' \
      /usr/bin/curl -4fsS --interface "$dev" --connect-timeout 3 --max-time 6 \
      "$CHECK_URL" >/dev/null 2>&1; then
    die "UNSAFE: restricted process reached the Internet directly on $dev."
  fi
  log "PASS: PF blocks restricted direct egress on $dev."
done

log "PF leak test: restricted direct HTTPS using the default route must fail."
if restricted /usr/bin/env \
    HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= NO_PROXY='*' \
    http_proxy= https_proxy= all_proxy= no_proxy='*' \
    /usr/bin/curl -4fsS --connect-timeout 3 --max-time 6 \
    "$CHECK_URL" >/dev/null 2>&1; then
  die "UNSAFE: restricted process reached the Internet directly via a non-loopback route."
fi
log "PASS: restricted default-route direct egress is blocked."
exit_if_guardian_stop_requested

log "Protected-path test: restricted group must still work through localhost/VeePN."
PROTECTED_IP="$(restricted /usr/bin/env \
  HTTP_PROXY="$HTTP_PROXY_URL" HTTPS_PROXY="$HTTP_PROXY_URL" \
  http_proxy="$HTTP_PROXY_URL" https_proxy="$HTTP_PROXY_URL" \
  ALL_PROXY= all_proxy= \
  NO_PROXY="127.0.0.1,localhost,::1" no_proxy="127.0.0.1,localhost,::1" \
  /usr/bin/curl -4fsS -x "$HTTP_PROXY_URL" --noproxy '' \
  --connect-timeout 5 --max-time 12 "$CHECK_URL" 2>/dev/null || true)"
[ "$PROTECTED_IP" = "$SOCKS_IP" ] || \
  die "Protected path failed (expected $SOCKS_IP, got ${PROTECTED_IP:-none})."
log "PASS: restricted process exits through VeePN at $PROTECTED_IP."
exit_if_guardian_stop_requested

# Temporarily inject proxy variables into ~/.codex/.env only for the dedicated
# ChatGPT/Codex target. Generic app bundles receive proxy variables solely in
# their launched process environment and never modify Codex configuration.
if [ "$PATCH_CODEX_ENV" -eq 1 ]; then
  log "Temporarily injecting protected proxy variables into $CODEX_ENV_FILE."
  mkdir -p "$HOME/.codex"
  if [ "$GUI_ROOT_MODE" -eq 1 ]; then
    chown "$LOGIN_UID:$LOGIN_GID" "$HOME/.codex" >/dev/null 2>&1 || true
  fi
  /usr/bin/python3 - "$CODEX_ENV_FILE" "$CODEX_ENV_STATE" "$HTTP_PROXY_URL" <<'PY'
import json, os, re, sys, tempfile

env_path, state_path, proxy = sys.argv[1:4]
values = {
    "HTTP_PROXY": proxy,
    "HTTPS_PROXY": proxy,
    "http_proxy": proxy,
    "https_proxy": proxy,
    "NO_PROXY": "127.0.0.1,localhost,::1",
    "no_proxy": "127.0.0.1,localhost,::1",
    "ALL_PROXY": "",
    "all_proxy": "",
}
keys = set(values)
file_was_absent = not os.path.exists(env_path)

try:
    with open(env_path, "r", encoding="utf-8") as f:
        lines = f.readlines()
except FileNotFoundError:
    lines = []

pat = re.compile(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=')
original_target = []
kept = []
for line in lines:
    m = pat.match(line)
    if m and m.group(1) in keys:
        original_target.append(line)
    else:
        kept.append(line)

state = {
    "file_was_absent": file_was_absent,
    "keys": sorted(keys),
    "original_target_lines": original_target,
}
with open(state_path, "w", encoding="utf-8") as f:
    json.dump(state, f)

if kept and not kept[-1].endswith("\n"):
    kept[-1] += "\n"
# Add a marker without forcing an extra leading blank into a previously empty file.
if kept and any(line.strip() for line in kept):
    if kept[-1].strip():
        kept.append("\n")
kept.append("# Temporary VeePN fail-closed proxy settings; restored by launcher.\n")
for k, v in values.items():
    kept.append(f"{k}={v}\n")

fd, tmp = tempfile.mkstemp(prefix=".env.chatgpt-vpn.", dir=os.path.dirname(env_path))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.writelines(kept)
    os.replace(tmp, env_path)
finally:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
PY
  if [ "$GUI_ROOT_MODE" -eq 1 ]; then
    chown "$LOGIN_UID:$LOGIN_GID" "$CODEX_ENV_FILE" >/dev/null 2>&1 || true
  fi
  CODEX_ENV_PATCHED=1
  ENV_STATUS="~/.codex/.env proxy keys temporarily patched"
  log "Codex proxy environment injected; original proxy keys will be restored on exit."
else
  ENV_STATUS="not modified (generic app mode)"
  log "Generic app mode: ~/.codex/.env will not be modified."
fi

if [ "$CURSOR_PROFILE" -eq 1 ]; then
  log "Temporarily configuring Cursor's explicit proxy and HTTP/1.1 compatibility profile."
  patch_cursor_settings "$HTTP_PROXY_URL" || die "Cursor's temporary proxy profile could not be configured."
  ENV_STATUS="Cursor proxy profile temporarily patched"
  log "Cursor proxy profile injected; original settings will be restored on exit."
elif [ "$COMPATIBILITY_PROFILE" -eq 1 ]; then
  ENV_STATUS="explicit Electron/Node compatibility proxy"
  log "$APP_NAME compatibility mode: explicit Electron/Node proxy controls enabled."
fi

cat <<EOF

======================================================================
PROTECTED CHATGPT / CODEX SESSION READY
======================================================================
VeePN SOCKS5        : $SOCKS_HOST:$SOCKS_PORT
HTTP proxy bridge   : $HTTP_PROXY_URL
Verified public IP  : $PROTECTED_IP
Guarded interfaces  : ${GUARDED_IFS[*]}
Isolation group     : $GROUP_NAME (gid=$GROUP_GID)
App-specific env    : $ENV_STATUS
System SOCKS        : $sys_socks_host:$sys_socks_port

Policy:
  ChatGPT/Codex -> localhost -> VeePN Shadowsocks              : ALLOWED
  Direct TCP/UDP on guarded non-loopback interfaces            : BLOCKED
  Child process ignoring HTTP_PROXY/HTTPS_PROXY                : BLOCKED
  Physical DNS/DoT while this launcher is active               : BLOCKED

Do NOT authorize sudo/root networking from Codex.
External applications launched outside this process tree are not covered.
Remote/cloud Codex jobs run off this Mac.

Launching $APP_NAME now...
======================================================================

EOF

# Launch the app executable directly so the effective-group boundary is inherited.
# Avoid `open -a`: LaunchServices could reuse/relaunch a process outside our group.
exit_if_guardian_stop_requested
set +e
APP_ENV=(
  "HOME=$LOGIN_HOME" "USER=$LOGIN_USER" "LOGNAME=$LOGIN_USER" "PATH=$ORIGINAL_PATH"
  "HTTP_PROXY=$HTTP_PROXY_URL" "HTTPS_PROXY=$HTTP_PROXY_URL"
  "http_proxy=$HTTP_PROXY_URL" "https_proxy=$HTTP_PROXY_URL"
  "NO_PROXY=127.0.0.1,localhost,::1" "no_proxy=127.0.0.1,localhost,::1"
  "ALL_PROXY=" "all_proxy="
)
APP_ARGS=()
if [ "$COMPATIBILITY_PROFILE" -eq 1 ]; then
  APP_ENV+=("NODE_USE_ENV_PROXY=1")
  APP_ARGS+=(
    "--proxy-server=$HTTP_PROXY_URL"
    "--proxy-bypass-list=localhost;127.0.0.1;[::1]"
    "--disable-quic"
    "--disable-http2"
  )
fi
if [ "${#APP_ARGS[@]}" -gt 0 ]; then
  restricted /usr/bin/env \
    "${APP_ENV[@]}" "$APP_EXEC" "${APP_ARGS[@]}" \
    >"$TMPROOT/chatgpt-codex.stdout.log" 2>"$TMPROOT/chatgpt-codex.stderr.log" &
else
  # Bash 3.2 on Monterey raises an unbound-variable error when an empty array
  # is expanded under `set -u`, so standard profiles use a separate argv path.
  restricted /usr/bin/env \
    "${APP_ENV[@]}" "$APP_EXEC" \
    >"$TMPROOT/chatgpt-codex.stdout.log" 2>"$TMPROOT/chatgpt-codex.stderr.log" &
fi
APP_WRAPPER_PID=$!
set -e

# Give the desktop app time to initialize.
sleep 4
if ! kill -0 "$APP_WRAPPER_PID" 2>/dev/null; then
  echo "--- $APP_NAME stderr ---" >&2
  tail -80 "$TMPROOT/chatgpt-codex.stderr.log" >&2 || true
  die "$APP_NAME exited during protected startup."
fi

# Resolve the real protected main process. The Bash background wrapper remains
# in the user's normal group and is intentionally outside the audited app tree.
APP_MAIN_PID=""
while IFS= read -r pid; do
  [ -n "$pid" ] || continue
  gid="$(ps -o gid= -p "$pid" 2>/dev/null | awk '{print $1}' || true)"
  if [ "$gid" = "$GROUP_GID" ]; then
    APP_MAIN_PID="$pid"
    break
  fi
done < <(app_main_pids)

if [ -z "$APP_MAIN_PID" ]; then
  echo "--- $APP_NAME stderr ---" >&2
  tail -80 "$TMPROOT/chatgpt-codex.stderr.log" >&2 || true
  die "Could not identify a protected $APP_NAME main process."
fi

main_gid="$(ps -o gid= -p "$APP_MAIN_PID" 2>/dev/null | awk '{print $1}' || true)"
[ "$main_gid" = "$GROUP_GID" ] || \
  die "$APP_NAME main process is not in the isolation group (pid=$APP_MAIN_PID gid=${main_gid:-unknown})."
log "Protected $APP_NAME main PID: $APP_MAIN_PID (gid=$main_gid)."
exit_if_guardian_stop_requested

# Build a union of true descendants plus any process whose executable lives
# inside this app bundle. The latter catches bundle helpers spawned through
# macOS service mechanisms rather than a simple parent-child chain.
protected_related_pids() {
  {
    descendant_pids "$APP_MAIN_PID"
    app_bundle_pids
  } | awk 'NF && !seen[$0]++'
}

audit_app_tree() {
  local verbose="${1:-0}"
  local bad=0
  local count=0
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    kill -0 "$pid" 2>/dev/null || continue
    proc_user="$(ps -o user= -p "$pid" 2>/dev/null | awk '{print $1}' || true)"
    count=$((count + 1))
    gid="$(ps -o gid= -p "$pid" 2>/dev/null | awk '{print $1}' || true)"
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    if [ "$verbose" = "1" ]; then
      ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | awk '{print $1}' || true)"
      printf '  pid=%s ppid=%s user=%s gid=%s %s\n' "$pid" "${ppid:-?}" "${proc_user:-?}" "${gid:-?}" "$cmd"
    fi
    if [ -n "$gid" ] && [ "$gid" != "$GROUP_GID" ]; then
      printf 'UNPROTECTED CHATGPT/CODEX PROCESS: pid=%s user=%s gid=%s command=%s\n' \
        "$pid" "${proc_user:-?}" "$gid" "$cmd" >&2
      bad=$((bad + 1))
    fi
  done < <(protected_related_pids)

  [ "$count" -gt 0 ] || return 2
  [ "$bad" -eq 0 ] || return 1
  return 0
}

log "Auditing protected ChatGPT/Codex process tree and app-bundle helpers."
log "Protected process snapshot (pid ppid user gid command):"
if ! audit_app_tree 1; then
  die "A ChatGPT/Codex process escaped the temporary group; refusing to claim fail-closed protection."
fi
log "PASS: $APP_NAME main process, descendants, and visible bundle helpers are inside the isolation group."
if [ "$CURSOR_PROFILE" -eq 1 ]; then
  log "PASS: Cursor optimized proxy profile is active."
fi
if [ "$COMPATIBILITY_PROFILE" -eq 1 ]; then
  log "PASS: $APP_NAME compatibility proxy profile is active."
fi

echo
if [ "$GUI_ROOT_MODE" -eq 1 ]; then
  log "$APP_NAME is running protected. VeePN Guardian is monitoring the hidden supervisor."
else
  log "$APP_NAME is running protected. Keep this Terminal window open."
fi
log "When you quit $APP_NAME, PF, the temporary group, bridge, and ~/.codex/.env proxy keys will be restored."

# Continuously fail closed if a later child/helper appears outside the group.
while kill -0 "$APP_MAIN_PID" 2>/dev/null; do
  if guardian_stop_requested; then
    log "Authenticated cleanup request detected; ending the protected $APP_NAME session."
    exit 0
  fi
  sleep 1
  if ! audit_app_tree 0; then
    log "Failing closed: a ChatGPT/Codex process escaped the isolation group."
    bounded_kill "$APP_WRAPPER_PID"
    exit 70
  fi
done

wait "$APP_WRAPPER_PID" 2>/dev/null
app_rc=$?
log "$APP_NAME exited with status $app_rc."
exit "$app_rc"
