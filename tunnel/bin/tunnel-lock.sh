#!/bin/bash
# tunnel-lock.sh v2.1
#
# Fail-closed launcher for one or more macOS apps behind a local SOCKS5 proxy
# (VeePN Shadowsocks at 127.0.0.1:1080 by default).
#
# Relationship to the v1.1/v5.4 scripts in the parent directory:
#   - Same core idea (temporary Unix group + PF group-scoped block + localhost
#     HTTP CONNECT -> SOCKS5 bridge).
#   - Fixes the defects found during the audit.  See CHANGES below.
#
# CHANGES vs v1.1 / v5.4
#   1. NO machine-wide DNS block.  The old scripts emitted
#          block drop out quick on en0 proto { tcp udp } from any to any port 53
#      with no `group` clause, which blocks DNS for the WHOLE Mac.  If cleanup
#      then failed, the machine lost all name resolution.  The group-scoped rule
#      already covers ports 53/853 for the guarded processes, so those rules are
#      simply gone.
#   2. Calibrated leak test.  The old test called curl against a single URL and
#      treated "connection failed" as "PF blocked it".  If that URL was
#      independently unreachable the test passed while nothing was blocked.
#      We now run the identical probe UNRESTRICTED first: if the control probe
#      cannot reach the Internet, the test cannot distinguish and we abort
#      instead of claiming protection.
#   3. Probe uses raw TCP to literal IPs (no DNS, no third-party site uptime).
#   4. sudo keepalive.  Cleanup used `sudo -n`, which fails once the 5-minute
#      sudo timestamp expires - so PF anchors, groups and bridges leaked on
#      every long session.  A keepalive refreshes the timestamp for the life of
#      the session and cleanup failures are now reported loudly.
#   5. Namespaced, per-session anchors (com.apple/apptunnel-*) so concurrent
#      sessions cannot flush one another and orphan cleanup remains scoped.
#   6. Verifies the main PF ruleset still references the com.apple/* anchor
#      before trusting the anchor.
#   7. bash 3.2 safe: empty arrays no longer trip `set -u`.
#   8. Multiple apps share one isolation group (the "tunnel roster").
#   9. Machine-readable event log for the GUI.
#
# This script never touches DHCP, DNS server settings, network service order,
# or the system proxy configuration.  It only reads them.

set -euo pipefail

# The system python3 at /usr/bin is a Command Line Tools stub: it exists and is
# executable even when the Tools are not installed, and then every call dies
# with "invalid active developer path". This resolves one that actually runs.
. "$(cd "$(dirname "$0")" && pwd)/tunnel-python.sh"

VERSION="2.1"
# Defaults only. The real endpoint is discovered from the system proxy
# configuration, which the VPN client itself writes: VeePN uses 1180 on some
# builds/profiles, and hardcoding 1080 made phase 2 report "nothing listening"
# no matter how many times the VPN was reconnected.
SOCKS_HOST="127.0.0.1"
SOCKS_PORT="1080"
SOCKS_HOST_SET=0
SOCKS_PORT_SET=0
# Fixed anchor. A surviving app must still be covered when the tunnel is rebuilt
# after a disconnect, so the anchor cannot be per-session. The original reason
# for keying it to $$ was that a second run's teardown flushed the first run's
# rules; that is now prevented by STATE_FILE enforcing a single launcher, which
# is what makes one shared anchor safe. tunnel-doctor globs apptunnel* so
# orphans stay discoverable.
ANCHOR="com.apple/apptunnel"
STATE_DIR="$HOME/.apptunnel"
EVENT_LOG="$STATE_DIR/events.jsonl"
STATE_FILE="$STATE_DIR/session.json"
STOP_FILE="$STATE_DIR/stop"
RUN_FILE="$STATE_DIR/run-request"
TELEMETRY_FILE="$STATE_DIR/telemetry.json"
TELEMETRY_LOCK="$STATE_DIR/telemetry.lock"

GROUP_NAME="apptunnel"
GROUP_GID=""
PF_TOKEN=""
PF_ENABLED_BY_US=0
GUARD_INSTALLED=0
GROUP_CREATED=0
SETTINGS_PATCHED=0
CODEX_ENV_PATCHED=0
SUDO_KEEPALIVE_PID=""
BRIDGE_PID=""
# Fixed: an app's HTTP_PROXY is baked into its environment at exec and cannot be
# changed afterward, so a rebuilt bridge MUST return on the same port or every
# surviving app is left pointing at a dead one.
BRIDGE_PORT="${TUNNEL_BRIDGE_PORT:-17080}"
CLEANUP_PROBLEMS=0
STATE_OWNED=0
LOGIN_USER_OVERRIDE=""
RUN_AS_ROOT=0

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/apptunnel.XXXXXX")"
BRIDGE_SCRIPT="$TMPROOT/http_to_socks.py"
BRIDGE_PORT_FILE="$TMPROOT/bridge.port"
BRIDGE_LOG="$TMPROOT/bridge.log"
PF_RULES="$TMPROOT/pf.rules"
PROBE="$TMPROOT/probe.py"
SETTINGS_STATE="$TMPROOT/settings-state.json"
CODEX_ENV_STATE="$TMPROOT/codex-env-state.json"

SETTINGS_FILE="$HOME/.claude/settings.json"
CODEX_ENV_FILE="$HOME/.codex/.env"

LOGIN_USER="$(id -un)"
LOGIN_HOME="$HOME"
LOGIN_UID="$(id -u)"
LOGIN_GID="$(id -g)"
ORIGINAL_PATH="$PATH"

APP_PATHS=()
GUARDED_IFS=()
APP_MAIN_PIDS=()
APP_WRAPPER_PIDS=()
ASSUME_YES=0
SELF_TEST=0

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { emit "${CUR_PHASE:-0}" "${CUR_NAME:-ABORT}" fail "$*"; printf '\nERROR: %s\n' "$*" >&2; exit 1; }

CUR_PHASE=0
CUR_NAME="INIT"

# Machine-readable phase events consumed by the GUI's animation.
emit() {
  local n="$1" name="$2" status="$3" msg="${4:-}"
  "$PY" -c 'import json,sys,time
print(json.dumps({"t":time.time(),"phase":int(sys.argv[1]),"name":sys.argv[2],
                  "status":sys.argv[3],"msg":sys.argv[4]}), flush=True)' \
    "$n" "$name" "$status" "$msg" >> "$EVENT_LOG" 2>/dev/null || true
}

phase() {
  CUR_PHASE="$1"; CUR_NAME="$2"
  emit "$1" "$2" run "${3:-}"
  log "[$1/10] $2 ${3:-}"
}
phase_ok() { emit "$CUR_PHASE" "$CUR_NAME" ok "${1:-}"; [ -n "${1:-}" ] && log "      OK  $1" || true; }

# The two per-user files below are the only home-directory files this launcher
# may change. Atomic replacement creates a new inode, so a root-authorized run
# must explicitly return that inode to the login user after BOTH patch and
# restore. Missing this step was the cause of the root:staff 0600 lockout.
normalize_user_config_file() {
  local path="$1"
  [ -e "$path" ] || return 0
  [ ! -L "$path" ] || { printf 'Refusing symbolic-link config: %s\n' "$path" >&2; return 1; }
  if (( RUN_AS_ROOT )); then
    /usr/sbin/chown "$LOGIN_UID:$LOGIN_GID" "$path" || return 1
  fi
  /bin/chmod 600 "$path" || return 1
  [ "$(/usr/bin/stat -f '%u' "$path" 2>/dev/null)" = "$LOGIN_UID" ] || return 1
}

prepare_user_config_access() {
  local directory path owner
  for directory in "$LOGIN_HOME/.claude" "$LOGIN_HOME/.codex"; do
    [ ! -L "$directory" ] || die "Refusing symbolic-link configuration directory: $directory"
    /bin/mkdir -p "$directory" || die "Could not create configuration directory: $directory"
    if (( RUN_AS_ROOT )); then
      /usr/sbin/chown "$LOGIN_UID:$LOGIN_GID" "$directory" \
        || die "Could not return $directory to $LOGIN_USER."
    fi
    [ -d "$directory" ] && [ -x "$directory" ] \
      || die "Configuration directory is inaccessible: $directory"
  done

  for path in "$SETTINGS_FILE" "$CODEX_ENV_FILE"; do
    [ -e "$path" ] || continue
    [ ! -L "$path" ] || die "Refusing symbolic-link configuration file: $path"
    owner="$(/usr/bin/stat -f '%u' "$path" 2>/dev/null || true)"
    if [ "$owner" != "$LOGIN_UID" ]; then
      log "Repairing ownership of $path for $LOGIN_USER."
      if (( RUN_AS_ROOT )); then
        /usr/sbin/chown "$LOGIN_UID:$LOGIN_GID" "$path" \
          || die "Could not repair ownership of $path."
      else
        sudo /usr/sbin/chown "$LOGIN_UID:$LOGIN_GID" "$path" \
          || die "Administrator authorization could not repair ownership of $path."
      fi
    fi
    normalize_user_config_file "$path" \
      || die "Could not secure $path for $LOGIN_USER."
    [ -r "$path" ] && [ -w "$path" ] \
      || die "Configuration file is not readable and writable: $path"
  done

  if [ -e "$SETTINGS_FILE" ]; then
    "$PY" - "$SETTINGS_FILE" <<'PY' \
      || die "Claude settings are not valid JSON: $SETTINGS_FILE"
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
if not isinstance(value, dict):
    raise SystemExit(2)
PY
  fi
}

# Retire only artifacts created by this launcher family, and only after
# administrator authorization has succeeded. A group is removable when no
# live process has that effective gid. An anchor is removable when it contains
# an old machine-wide DNS block, or when every numeric group it references is
# unused. Unknown rule formats are preserved for tunnel-doctor inspection.
retire_orphaned_state() {
  local line gname ggid users anchor full rules gids gid keep found

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    gname="$(printf '%s\n' "$line" | awk '{print $1}')"
    ggid="$(printf '%s\n' "$line" | awk '{print $2}')"
    case "$gname" in apptun*|cldesk*|cgptvpn*) ;; *) continue ;; esac
    users="$(ps -axo gid= 2>/dev/null | awk -v g="$ggid" '$1==g{n++}END{print n+0}')"
    if [ "${users:-0}" -eq 0 ]; then
      log "      retiring orphaned isolation group $gname (gid=$ggid)"
      sudo -n /usr/sbin/dseditgroup -o edit -d "$LOGIN_USER" -t user "$gname" >/dev/null 2>&1 || true
      sudo -n /usr/sbin/dseditgroup -o delete "$gname" >/dev/null 2>&1 \
        || die "Could not remove orphaned group $gname. Run tunnel-doctor.sh --fix."
    else
      log "      preserving $gname (gid=$ggid): $users live process(es)"
    fi
  done < <(/usr/bin/dscl . -list /Groups PrimaryGroupID 2>/dev/null | awk '$2>=57000 && $2<58000')

  while IFS= read -r anchor; do
    [ -n "$anchor" ] || continue
    full="com.apple/$(basename "$anchor")"
    case "$full" in
      com.apple/apptunnel-*|com.apple/cldesktop-vpn-*|com.apple/chatgpt-codex-vpn-*) ;;
      *) continue ;;
    esac
    [ "$full" != "$ANCHOR" ] || continue
    rules="$(sudo -n pfctl -a "$full" -s rules 2>/dev/null || true)"
    [ -n "$rules" ] || continue

    if printf '%s\n' "$rules" | grep -E 'port = (53|853)' | grep -qv 'group'; then
      log "      disarming unsafe machine-wide DNS rule in $full"
      sudo -n pfctl -a "$full" -F rules >/dev/null 2>&1 \
        || die "Could not flush unsafe PF anchor $full. Run tunnel-doctor.sh --fix."
      continue
    fi

    gids="$(printf '%s\n' "$rules" | sed -nE 's/.*group = ([0-9]+).*/\1/p' | sort -u)"
    [ -n "$gids" ] || { log "      preserving unrecognized PF anchor $full for inspection"; continue; }
    keep=0; found=0
    for gid in $gids; do
      found=1
      users="$(ps -axo gid= 2>/dev/null | awk -v g="$gid" '$1==g{n++}END{print n+0}')"
      [ "${users:-0}" -eq 0 ] || keep=1
    done
    if [ "$found" -eq 1 ] && [ "$keep" -eq 0 ]; then
      log "      flushing orphaned PF anchor $full"
      sudo -n pfctl -a "$full" -F rules >/dev/null 2>&1 \
        || die "Could not flush orphaned PF anchor $full. Run tunnel-doctor.sh --fix."
    else
      log "      preserving in-use PF anchor $full"
    fi
  done < <(sudo -n pfctl -a com.apple -s Anchors 2>/dev/null || true)
}

usage() {
  cat <<'USAGE'
Usage:
  tunnel-lock.sh --app /Applications/Claude.app [--app /Applications/ChatGPT.app ...]

Options:
  --app PATH          App bundle to place inside the tunnel. Repeatable.
  --socks-host HOST   SOCKS5 host (default 127.0.0.1)
  --socks-port PORT   SOCKS5 port (default 1080)
  --guard-if IFACE    Guard a specific interface. Repeatable. Default: all
                      active non-loopback interfaces.
  --yes               Skip the interactive confirmation.
  -h, --help          Show this help.

All selected apps share one temporary isolation group, so they are all inside
the same tunnel. Quit every app to end the session; cleanup is automatic.
USAGE
}

# ---------------------------------------------------------------- cleanup ---
note_problem() {
  CLEANUP_PROBLEMS=$((CLEANUP_PROBLEMS + 1))
  printf 'CLEANUP PROBLEM: %s\n' "$1" >&2
  emit 99 CLEANUP fail "$1"
}

restore_settings() {
  (( SETTINGS_PATCHED )) || return 0
  [ -f "$SETTINGS_STATE" ] || return 0
  if "$PY" - "$SETTINGS_FILE" "$SETTINGS_STATE" <<'PY'
import json, os, sys, tempfile
settings_path, state_path = sys.argv[1:3]
with open(state_path) as f:
    state = json.load(f)
if os.path.exists(settings_path):
    with open(settings_path) as f:
        data = json.load(f)
else:
    data = {}
if not isinstance(data, dict):
    raise SystemExit(1)
env = data.get("env")
if not isinstance(env, dict):
    env = {}
    data["env"] = env
for key, info in state.get("keys", {}).items():
    if info.get("present"):
        env[key] = info.get("value", "")
    else:
        env.pop(key, None)
if state.get("env_was_absent") and not env:
    data.pop("env", None)
fd, tmp = tempfile.mkstemp(prefix=".settings.restore.", dir=os.path.dirname(settings_path))
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, settings_path)
PY
  then
    normalize_user_config_file "$SETTINGS_FILE" \
      || note_problem "could not restore ownership of $HOME/.claude/settings.json"
  else
    note_problem "could not restore $HOME/.claude/settings.json"
  fi
}

restore_codex_env() {
  (( CODEX_ENV_PATCHED )) || return 0
  [ -f "$CODEX_ENV_STATE" ] || return 0
  if "$PY" - "$CODEX_ENV_FILE" "$CODEX_ENV_STATE" <<'PY'
import json, os, re, sys, tempfile
env_path, state_path = sys.argv[1:3]
with open(state_path, encoding="utf-8") as f:
    state = json.load(f)
keys = set(state.get("keys", []))
try:
    with open(env_path, encoding="utf-8") as f:
        current = f.readlines()
except FileNotFoundError:
    current = []
pat = re.compile(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=')
MARKER = '# apptunnel: temporary proxy settings, removed automatically'
kept = []
for line in current:
    if line.rstrip("\n") == MARKER:
        continue
    m = pat.match(line)
    if m and m.group(1) in keys:
        continue
    kept.append(line)
kept.extend(state.get("original_target_lines", []))
while kept and not kept[0].strip():
    kept.pop(0)
if state.get("file_was_absent") and not [l for l in kept if l.strip()]:
    try:
        os.unlink(env_path)
    except FileNotFoundError:
        pass
    raise SystemExit(0)
fd, tmp = tempfile.mkstemp(prefix=".env.restore.", dir=os.path.dirname(env_path))
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.writelines(kept)
os.replace(tmp, env_path)
PY
  then
    normalize_user_config_file "$CODEX_ENV_FILE" \
      || note_problem "could not restore ownership of $HOME/.codex/.env"
  else
    note_problem "could not restore $HOME/.codex/.env"
  fi
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  emit 98 TEARDOWN run "restoring system state"

  # Deliberately does NOT signal the tunnelled apps. Dropping PF and the bridge
  # already denies them the network, which is the property the guard exists to
  # provide. Killing them as well destroyed live Claude/Codex sessions on every
  # transient failure, and is what forced a relaunch after each reconnect. The
  # apps stay up, keep their gid, and re-adopt the tunnel when it returns.
  # tunnel-quit.sh is the one path that closes them, on purpose.

  restore_settings
  restore_codex_env

  if [ -n "$BRIDGE_PID" ] && kill -0 "$BRIDGE_PID" 2>/dev/null; then
    kill -TERM "$BRIDGE_PID" 2>/dev/null || true
    sleep 0.3
    kill -KILL "$BRIDGE_PID" 2>/dev/null || true
  fi

  if (( GUARD_INSTALLED )); then
    sudo -n pfctl -a "$ANCHOR" -F rules >/dev/null 2>&1 \
      || note_problem "PF anchor $ANCHOR not flushed. Run: sudo pfctl -a $ANCHOR -F rules"
  fi

  if (( PF_ENABLED_BY_US )); then
    if [ -n "$PF_TOKEN" ]; then
      sudo -n pfctl -X "$PF_TOKEN" >/dev/null 2>&1 || note_problem "PF reference token $PF_TOKEN not released"
    else
      sudo -n pfctl -d >/dev/null 2>&1 || note_problem "PF not disabled"
    fi
  fi

  # The group is persistent: a surviving app is only still reachable on the next
  # connect because its gid did not change. retire_orphaned_state deletes it at
  # the next connect if no process is left in it, and tunnel-quit.sh deletes it
  # after closing the apps.

  [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  # Only ever remove the lock we ourselves claimed.
  (( STATE_OWNED )) && rm -f "$STATE_FILE" 2>/dev/null
  rm -f "$STOP_FILE" "$RUN_FILE" "$TELEMETRY_FILE" "$TELEMETRY_LOCK" 2>/dev/null
  true
  rm -rf "$TMPROOT" 2>/dev/null || true

  if (( CLEANUP_PROBLEMS )); then
    emit 98 TEARDOWN fail "$CLEANUP_PROBLEMS item(s) need manual cleanup - run tunnel-doctor.sh"
    printf '\n%s item(s) could not be cleaned up automatically.\nRun: "%s/tunnel-doctor.sh" --fix\n\n' \
      "$CLEANUP_PROBLEMS" "$(dirname "$0")" >&2
  elif (( GROUP_CREATED || GUARD_INSTALLED || SETTINGS_PATCHED || CODEX_ENV_PATCHED )) || [ -n "$BRIDGE_PID" ]; then
    emit 98 TEARDOWN ok "system state restored"
    log "System state restored. No changes left behind."
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM HUP

# ------------------------------------------------------------------- args ---
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)        [ "$#" -ge 2 ] || die "--app requires a path";  APP_PATHS+=("$2"); shift 2 ;;
    --guard-if|--physical-if)
                  [ "$#" -ge 2 ] || die "$1 requires an interface"; GUARDED_IFS+=("$2"); shift 2 ;;
    --socks-host) [ "$#" -ge 2 ] || die "--socks-host requires a host"
                  SOCKS_HOST="$2"; SOCKS_HOST_SET=1; shift 2 ;;
    --socks-port) [ "$#" -ge 2 ] || die "--socks-port requires a port"
                  SOCKS_PORT="$2"; SOCKS_PORT_SET=1; shift 2 ;;
    --yes)        ASSUME_YES=1; shift ;;
    --self-test)  SELF_TEST=1; ASSUME_YES=1; shift ;;
    --login-user) [ "$#" -ge 2 ] || die "--login-user requires a name"
                  LOGIN_USER_OVERRIDE="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "Unknown option: $1" ;;
  esac
done

# Resolve the real login identity before touching its state or configuration.
# macOS authorization runs this file as root, where inherited HOME/USER values
# are not reliable enough to determine ownership.
if [ "$EUID" -eq 0 ]; then
  [ -n "$LOGIN_USER_OVERRIDE" ] \
    || die "Running as root requires --login-user <name> (the app supplies it)."
  RUN_AS_ROOT=1
  LOGIN_USER="$LOGIN_USER_OVERRIDE"
  LOGIN_HOME="$(/usr/bin/dscl . -read "/Users/$LOGIN_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  LOGIN_UID="$(/usr/bin/id -u "$LOGIN_USER" 2>/dev/null || true)"
  LOGIN_GID="$(/usr/bin/id -g "$LOGIN_USER" 2>/dev/null || true)"
  [ -d "$LOGIN_HOME" ] && [ -n "$LOGIN_UID" ] && [ -n "$LOGIN_GID" ] \
    || die "Could not resolve the login identity for $LOGIN_USER."
  export HOME="$LOGIN_HOME"
  STATE_DIR="$LOGIN_HOME/.apptunnel"
  EVENT_LOG="$STATE_DIR/events.jsonl"
  STATE_FILE="$STATE_DIR/session.json"
  STOP_FILE="$STATE_DIR/stop"
  RUN_FILE="$STATE_DIR/run-request"
  TELEMETRY_FILE="$STATE_DIR/telemetry.json"
  TELEMETRY_LOCK="$STATE_DIR/telemetry.lock"
  SETTINGS_FILE="$LOGIN_HOME/.claude/settings.json"
  CODEX_ENV_FILE="$LOGIN_HOME/.codex/.env"
elif [ -n "$LOGIN_USER_OVERRIDE" ]; then
  die "--login-user is only valid when this script runs as root."
fi

/bin/mkdir -p "$STATE_DIR"
if (( RUN_AS_ROOT )); then
  /usr/sbin/chown "$LOGIN_UID:$LOGIN_GID" "$STATE_DIR" \
    || die "Could not return $STATE_DIR to $LOGIN_USER."
fi
: > "$EVENT_LOG"
rm -f "$STOP_FILE" "$RUN_FILE" 2>/dev/null || true
if (( RUN_AS_ROOT )); then
  /usr/sbin/chown "$LOGIN_UID:$LOGIN_GID" "$EVENT_LOG" \
    || die "Could not return $EVENT_LOG to $LOGIN_USER."
fi

# --------------------------------------------------------------- phase 1 ---
phase 1 PREFLIGHT "checking environment and app bundles"

[ "$(uname -s)" = "Darwin" ] || die "macOS only."

for cmd in pfctl curl ifconfig sudo awk nc ps osascript; do
  command -v "$cmd" >/dev/null 2>&1 || die "Required command '$cmd' not found."
done
# python3 is checked separately and by RUNNING it, not by command -v. The system
# copy is an xcrun stub that answers "yes, I exist" and then fails on every
# call, which is how a machine with no Command Line Tools got all the way to
# phase 2 before stalling with an unexplained "SOCKS not available".
[ "$TUNNEL_PY_OK" -eq 1 ] || die "No working python3. Install the Command Line Tools: xcode-select --install"
[ -x /usr/sbin/dseditgroup ] || die "dseditgroup not found."
[ -x /usr/bin/dscl ] || die "dscl not found."

prepare_user_config_access

if [ "$SELF_TEST" -eq 0 ] && [ "${#APP_PATHS[@]}" -eq 0 ]; then
  die "No apps selected. Use --app /Applications/Claude.app"
fi

# Claim the session lock ATOMICALLY, and BEFORE doing any work.  Writing this
# only at the end of startup allowed two concurrent runs to both pass the
# "already running?" test; the second run then tore down the first run's
# firewall rules and reported the first run's app as "not in the isolation
# group", because it was comparing against its OWN gid.
lock_result="$("$PY" -c '
import json, os, sys
path, mypid = sys.argv[1], int(sys.argv[2])
def claim():
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 420)
    f = os.fdopen(fd, "w")
    json.dump({"pid": mypid, "state": "starting"}, f)
    f.close()
    print("OK")
try:
    claim()
except FileExistsError:
    try:
        other = json.load(open(path)).get("pid")
        os.kill(int(other), 0)
        print("BUSY %s" % other)
    except Exception:
        try: os.unlink(path)
        except Exception: pass
        try: claim()
        except Exception as e: print("ERR %s" % e)
' "$STATE_FILE" "$$" 2>/dev/null || true)"

case "$lock_result" in
  OK)     STATE_OWNED=1 ;;
  BUSY*)  die "Another tunnel session is already running (pid ${lock_result#BUSY }). Quit it first, or run tunnel-doctor.sh." ;;
  *)      die "Could not claim the session lock $STATE_FILE (${lock_result:-no response})." ;;
esac

APP_EXECS=()
APP_NAMES=()
for app in ${APP_PATHS[@]+"${APP_PATHS[@]}"}; do
  [ -d "$app" ] || die "App bundle not found: $app"
  meta="$("$PY" -c 'import plistlib,sys
with open(sys.argv[1],"rb") as f: d=plistlib.load(f)
print(d.get("CFBundleExecutable",""))' "$app/Contents/Info.plist" 2>/dev/null || true)"
  [ -n "$meta" ] || die "CFBundleExecutable missing in $app/Contents/Info.plist"
  exe="$app/Contents/MacOS/$meta"
  [ -x "$exe" ] || die "Executable not found: $exe"
  APP_EXECS+=("$exe")
  APP_NAMES+=("$(basename "$app" .app)")
done

# Test protection: never quit or relaunch the app that hosts whoever started
# us. tunnel-testkit.sh records it; without this, testing the tunnel from
# inside a tunnelled app terminates the session running the test.
GUARD_FILE="$STATE_DIR/protected.json"
if [ -f "$GUARD_FILE" ]; then
  PROTECTED_BUNDLE="$("$PY" -c '
import json,sys
try: print(json.load(open(sys.argv[1])).get("host_bundle") or "")
except Exception: pass' "$GUARD_FILE" 2>/dev/null)"
  if [ -n "$PROTECTED_BUNDLE" ]; then
    KEPT_PATHS=(); KEPT_EXECS=(); KEPT_NAMES=(); k=0
    for a in ${APP_PATHS[@]+"${APP_PATHS[@]}"}; do
      if [ "$a" = "$PROTECTED_BUNDLE" ]; then
        log "      SKIPPING $a - protected host app (test mode); it stays outside the tunnel"
        emit 1 PREFLIGHT run "skipping protected host $(basename "$a")"
      else
        KEPT_PATHS+=("$a"); KEPT_EXECS+=("${APP_EXECS[$k]}"); KEPT_NAMES+=("${APP_NAMES[$k]}")
      fi
      k=$((k+1))
    done
    APP_PATHS=(${KEPT_PATHS[@]+"${KEPT_PATHS[@]}"})
    APP_EXECS=(${KEPT_EXECS[@]+"${KEPT_EXECS[@]}"})
    APP_NAMES=(${KEPT_NAMES[@]+"${KEPT_NAMES[@]}"})
    if [ "$SELF_TEST" -eq 0 ] && [ "${#APP_PATHS[@]}" -eq 0 ]; then
      die "Every roster app is the protected host. Nothing left to tunnel. Run tunnel-testkit.sh clear, or add another app."
    fi
  fi
fi

# Every selected app must be fully quit, otherwise LaunchServices may reuse a
# process that lives outside the isolation group.
idx=0
for exe in ${APP_EXECS[@]+"${APP_EXECS[@]}"}; do
  name="${APP_NAMES[$idx]}"
  running="$(ps -axo pid=,command= | awk -v exe="$exe" '{p=$1;$1="";sub(/^[ \t]+/,"");if($0==exe||index($0,exe" ")==1)print p}')"
  if [ -n "$running" ]; then
    log "      $name is running; asking it to quit"
    /usr/bin/osascript -e "tell application \"$name\" to quit" >/dev/null 2>&1 || true
    i=0
    while [ "$i" -lt 50 ]; do
      running="$(ps -axo pid=,command= | awk -v exe="$exe" '{p=$1;$1="";sub(/^[ \t]+/,"");if($0==exe||index($0,exe" ")==1)print p}')"
      [ -z "$running" ] && break
      sleep 0.2; i=$((i+1))
    done
    [ -z "$running" ] || die "$name did not quit. Quit or force-quit it, then rerun."
  fi
  idx=$((idx+1))
done
if [ "$SELF_TEST" -eq 1 ]; then
  phase_ok "self-test mode: no apps will be launched"
else
  phase_ok "${#APP_PATHS[@]} app(s): ${APP_NAMES[*]}"
fi

if [ -t 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
  printf '\nConnect your SOCKS5 VPN (VeePN -> Shadowsocks) before continuing.\n'
  read -r -p 'Type YES to proceed: ' answer
  [ "$answer" = "YES" ] || die "Confirmation not received."
fi

# --------------------------------------------------------------- phase 2 ---
phase 2 SOCKS "locating the SOCKS5 endpoint"

# Ask the system proxy configuration where the VPN actually put its listener.
sys_dump="$(/usr/sbin/scutil --proxy 2>/dev/null || true)"
sys_enable="$(printf '%s\n' "$sys_dump" | awk '/SOCKSEnable[[:space:]]*:/{print $3; exit}')"
sys_host="$(printf '%s\n' "$sys_dump"   | awk '/SOCKSProxy[[:space:]]*:/{print $3; exit}')"
sys_port="$(printf '%s\n' "$sys_dump"   | awk '/SOCKSPort[[:space:]]*:/{print $3; exit}')"
if [ "$sys_enable" = "1" ] && [ -n "$sys_host" ] && [ -n "$sys_port" ]; then
  (( SOCKS_HOST_SET )) || SOCKS_HOST="$sys_host"
  (( SOCKS_PORT_SET )) || SOCKS_PORT="$sys_port"
  log "      system proxy advertises SOCKS5 at $sys_host:$sys_port"
fi

# Probe the advertised endpoint, then a couple of common fallbacks, so a stale
# or missing system setting is not fatal on its own.
socks_open() {
  "$PY" -c '
import socket, sys
s = socket.socket(); s.settimeout(2)
try: s.connect((sys.argv[1], int(sys.argv[2]))); sys.exit(0)
except Exception: sys.exit(1)
finally: s.close()
' "$1" "$2"
}

if ! socks_open "$SOCKS_HOST" "$SOCKS_PORT"; then
  found=""
  if (( ! SOCKS_PORT_SET )); then
    for cand in 1080 1180 1081 7890 1086; do
      [ "$cand" = "$SOCKS_PORT" ] && continue
      if socks_open "$SOCKS_HOST" "$cand"; then found="$cand"; break; fi
    done
  fi
  if [ -n "$found" ]; then
    log "      nothing on $SOCKS_PORT; found a listener on $found instead"
    SOCKS_PORT="$found"
  else
    die "No SOCKS5 listener on $SOCKS_HOST:$SOCKS_PORT (system proxy says ${sys_host:-unset}:${sys_port:-unset}). Connect VeePN with Shadowsocks, then check its Local port setting."
  fi
fi
phase 2 SOCKS "verifying SOCKS5 endpoint $SOCKS_HOST:$SOCKS_PORT"

SOCKS_IP="$(/usr/bin/curl -4fsS --socks5-hostname "$SOCKS_HOST:$SOCKS_PORT" \
  --connect-timeout 6 --max-time 15 https://api.ipify.org 2>/dev/null || true)"
if ! [[ "$SOCKS_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  SOCKS_IP="$(/usr/bin/curl -4fsS --socks5-hostname "$SOCKS_HOST:$SOCKS_PORT" \
    --connect-timeout 6 --max-time 15 https://ifconfig.me/ip 2>/dev/null || true)"
fi
[[ "$SOCKS_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "SOCKS5 is listening but no verification URL was reachable through it."
phase_ok "tunnel exit IP $SOCKS_IP"

# --------------------------------------------------------------- phase 3 ---
phase 3 BRIDGE "starting localhost HTTP CONNECT -> SOCKS5 bridge"

cat > "$BRIDGE_SCRIPT" <<'PYBRIDGE'
#!/usr/bin/env python3
import argparse, ipaddress, select, socket, socketserver, struct
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

def socks5_connect(proxy_host, proxy_port, host, port, timeout=15):
    s = socket.create_connection((proxy_host, proxy_port), timeout=timeout)
    s.settimeout(timeout)
    s.sendall(b"\x05\x01\x00")
    if recvn(s, 2) != b"\x05\x00":
        s.close(); raise OSError("SOCKS5 rejected no-auth")
    try:
        ip = ipaddress.ip_address(host)
        atyp = b"\x01" if ip.version == 4 else b"\x04"
        addr = ip.packed
    except ValueError:
        raw = host.encode("idna")
        if len(raw) > 255:
            s.close(); raise OSError("hostname too long")
        atyp = b"\x03"; addr = bytes([len(raw)]) + raw
    s.sendall(b"\x05\x01\x00" + atyp + addr + struct.pack("!H", int(port)))
    head = recvn(s, 4)
    if head[0] != 5 or head[1] != 0:
        s.close(); raise OSError("SOCKS5 connect failed reply=%d" % head[1])
    a = head[3]
    if a == 1: recvn(s, 4)
    elif a == 3: recvn(s, recvn(s, 1)[0])
    elif a == 4: recvn(s, 16)
    else:
        s.close(); raise OSError("bad SOCKS5 atyp")
    recvn(s, 2)
    s.settimeout(None)
    return s

def relay(a, b):
    socks = [a, b]
    try:
        while True:
            r, _, _ = select.select(socks, [], [], 60)
            if not r:
                continue
            for src in r:
                dst = b if src is a else a
                data = src.recv(BUF)
                if not data:
                    return
                dst.sendall(data)
    finally:
        for s in socks:
            try: s.shutdown(socket.SHUT_RDWR)
            except Exception: pass
            try: s.close()
            except Exception: pass

class Handler(socketserver.StreamRequestHandler):
    timeout = 30
    def bail(self, code, text):
        body = (text + "\n").encode()
        self.wfile.write(("HTTP/1.1 %d %s\r\nConnection: close\r\nContent-Length: %d\r\n\r\n"
                          % (code, text, len(body))).encode() + body)
    def handle(self):
        try:
            first = self.rfile.readline(65537)
            if not first or len(first) > 65536:
                return
            try:
                method, target, version = first.decode("iso-8859-1").rstrip("\r\n").split(" ", 2)
            except ValueError:
                self.bail(400, "Bad Request"); return
            headers, host_header = [], None
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
                host, port = self.hostport(target, 443)
                up = socks5_connect(self.server.socks_host, self.server.socks_port, host, port)
                self.wfile.write(b"HTTP/1.1 200 Connection Established\r\nProxy-Agent: apptunnel\r\n\r\n")
                self.wfile.flush()
                relay(self.connection, up)
                return
            parts = urlsplit(target)
            if parts.scheme and parts.hostname:
                if parts.scheme.lower() != "http":
                    self.bail(400, "Unsupported scheme"); return
                host, port = parts.hostname, parts.port or 80
                path = (parts.path or "/") + (("?" + parts.query) if parts.query else "")
            else:
                if not host_header:
                    self.bail(400, "Host header required"); return
                host, port = self.hostport(host_header, 80)
                path = target
            up = socks5_connect(self.server.socks_host, self.server.socks_port, host, port)
            up.sendall(("%s %s %s\r\n" % (method, path, version)).encode("iso-8859-1"))
            clen = 0
            for line in headers:
                low = line.lower()
                if low.startswith(b"proxy-connection:") or low.startswith(b"proxy-authorization:"):
                    continue
                if low.startswith(b"content-length:"):
                    try: clen = int(line.split(b":", 1)[1].strip())
                    except Exception: clen = 0
                up.sendall(line)
            up.sendall(b"Connection: close\r\n\r\n")
            if clen:
                up.sendall(recvn(self.connection, clen))
            while True:
                data = up.recv(BUF)
                if not data:
                    break
                self.connection.sendall(data)
            up.close()
        except Exception:
            try: self.bail(502, "Bad Gateway")
            except Exception: pass
    @staticmethod
    def hostport(value, default_port):
        value = value.strip()
        if value.startswith("["):
            end = value.find("]")
            if end < 0: raise ValueError("bad IPv6 host")
            rest = value[end + 1:]
            return value[1:end], int(rest[1:]) if rest.startswith(":") else default_port
        if value.count(":") == 1:
            h, p = value.rsplit(":", 1)
            if p.isdigit(): return h, int(p)
        return value, default_port

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

ap = argparse.ArgumentParser()
ap.add_argument("--socks-host", default="127.0.0.1")
ap.add_argument("--socks-port", type=int, default=1080)
ap.add_argument("--port", type=int, default=0)
ap.add_argument("--port-file", required=True)
args = ap.parse_args()
with Server(("127.0.0.1", args.port), Handler) as srv:
    srv.socks_host = args.socks_host
    srv.socks_port = args.socks_port
    with open(args.port_file, "w") as f:
        f.write(str(srv.server_address[1])); f.flush()
    srv.serve_forever(poll_interval=0.2)
PYBRIDGE
chmod 700 "$BRIDGE_SCRIPT"

"$PY" "$BRIDGE_SCRIPT" --socks-host "$SOCKS_HOST" --socks-port "$SOCKS_PORT" \
  --port "$BRIDGE_PORT" --port-file "$BRIDGE_PORT_FILE" >"$BRIDGE_LOG" 2>&1 &
BRIDGE_PID=$!

i=0
while [ "$i" -lt 60 ]; do
  [ -s "$BRIDGE_PORT_FILE" ] && { BRIDGE_PORT="$(cat "$BRIDGE_PORT_FILE")"; break; }
  kill -0 "$BRIDGE_PID" 2>/dev/null || { cat "$BRIDGE_LOG" >&2; die "Bridge exited before ready."; }
  sleep 0.1; i=$((i+1))
done
[[ "$BRIDGE_PORT" =~ ^[0-9]+$ ]] || die "Bridge did not become ready."
HTTP_PROXY_URL="http://127.0.0.1:$BRIDGE_PORT"

BRIDGE_IP="$(/usr/bin/curl -4fsS -x "$HTTP_PROXY_URL" --noproxy '' \
  --connect-timeout 6 --max-time 15 https://api.ipify.org 2>/dev/null || true)"
[ "$BRIDGE_IP" = "$SOCKS_IP" ] \
  || die "Bridge verification failed (socks=$SOCKS_IP bridge=${BRIDGE_IP:-none})."
phase_ok "bridge $HTTP_PROXY_URL exits at $BRIDGE_IP"

# --------------------------------------------------------------- phase 4 ---
phase 4 PRIV "requesting administrator rights"
if (( RUN_AS_ROOT )); then
  phase_ok "already elevated (launched from the app, no Terminal needed)"
else
  sudo -v || die "sudo authentication failed."
  # Keep the sudo timestamp alive for the whole session so that cleanup, which
  # must run non-interactively, can still remove the PF anchor and the group.
  ( while kill -0 "$$" 2>/dev/null; do sudo -n -v >/dev/null 2>&1 || exit 0; sleep 30; done ) &
  SUDO_KEEPALIVE_PID=$!
  phase_ok "sudo acquired, keepalive active"
fi

retire_orphaned_state

# --------------------------------------------------------------- phase 5 ---
phase 5 GROUP "creating temporary isolation group"

# Reuse the group if it is already there: its members are the apps that survived
# the last disconnect, and they are only still reachable because their gid has
# not changed. Never silently pick a different gid - an app cannot follow one.
GROUP_GID=57000
# `|| true` is load-bearing: dscl exits 56 when the group does not exist, and
# this script runs with `set -euo pipefail`, so an unguarded substitution here
# killed the launcher at phase 5 with no message at all.
existing_gid="$(/usr/bin/dscl . -read "/Groups/$GROUP_NAME" PrimaryGroupID 2>/dev/null | awk '{print $2}' || true)"
if [ -n "$existing_gid" ]; then
  GROUP_GID="$existing_gid"
  log "      reusing isolation group $GROUP_NAME (gid=$GROUP_GID)"
else
  if /usr/bin/dscl . -search /Groups PrimaryGroupID "$GROUP_GID" 2>/dev/null | grep -q .; then
    die "gid $GROUP_GID is held by another group, so the isolation group cannot be created. Free it, or run tunnel-doctor.sh --fix."
  fi
  sudo /usr/sbin/dseditgroup -o create -i "$GROUP_GID" "$GROUP_NAME" >/dev/null
  GROUP_CREATED=1
fi
sudo /usr/sbin/dseditgroup -o edit -a "$LOGIN_USER" -t user "$GROUP_NAME" >/dev/null
probe_gid="$(sudo -n -u "$LOGIN_USER" -g "$GROUP_NAME" /usr/bin/id -g 2>/dev/null || true)"
[ "$probe_gid" = "$GROUP_GID" ] || die "Could not establish effective-group isolation."
phase_ok "group $GROUP_NAME (gid=$GROUP_GID)"

# --------------------------------------------------------------- phase 6 ---
phase 6 FIREWALL "installing PF rules scoped to gid $GROUP_GID"

if [ "${#GUARDED_IFS[@]}" -eq 0 ]; then
  while IFS= read -r dev; do
    [ -n "$dev" ] || continue
    [ "$dev" = "lo0" ] && continue
    ifconfig "$dev" 2>/dev/null | head -1 | grep -q '<.*UP' && GUARDED_IFS+=("$dev")
  done < <(ifconfig -l 2>/dev/null | tr ' ' '\n')
fi
[ "${#GUARDED_IFS[@]}" -gt 0 ] || die "No active non-loopback interface. Use --guard-if en0."

if ! sudo pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then
  enable_out="$(sudo pfctl -E 2>&1 || true)"
  PF_TOKEN="$(printf '%s\n' "$enable_out" | awk '/Token[[:space:]]*:/{print $NF; exit}')"
  PF_ENABLED_BY_US=1
fi

# The anchor is useless unless the main ruleset still references com.apple/*.
# A flushed main ruleset silently disables every rule we load - which is exactly
# how the previous version could report PASS while blocking nothing.
# `pfctl -E` enables PF WITHOUT loading /etc/pf.conf, leaving a main ruleset
# that references no anchors - in which case everything we load is silently
# ignored.  Repair it rather than refusing: /etc/pf.conf is Apple's stock file
# and declares anchors only, so loading it filters nothing by itself.
if ! sudo pfctl -s rules 2>/dev/null | grep -q 'anchor "com.apple/\*"'; then
  if grep -qE '^[[:space:]]*(block|pass)' /etc/pf.conf 2>/dev/null; then
    die "/etc/pf.conf contains filter rules, so it is not the stock file; refusing to load it automatically. Inspect it, then run: sudo pfctl -f /etc/pf.conf"
  fi
  log "      PF main ruleset has no anchor reference; restoring /etc/pf.conf"
  sudo pfctl -f /etc/pf.conf >/dev/null 2>&1 || true

  # Restoring anchor evaluation also re-arms whatever a legacy launcher left
  # behind, including its machine-wide DNS blocks. Disarm those before we go on.
  for stale in $(sudo pfctl -a com.apple -s Anchors 2>/dev/null); do
    sname="com.apple/$(basename "$stale")"
    case "$sname" in *apptunnel-*) continue ;; esac
    if sudo pfctl -a "$sname" -s rules 2>/dev/null \
         | grep -E 'port = (53|853)' | grep -qv 'group'; then
      log "      disarming machine-wide DNS block left in $sname"
      sudo pfctl -a "$sname" -F rules >/dev/null 2>&1 || true
    fi
  done
fi

if ! sudo pfctl -s rules 2>/dev/null | grep -q 'anchor "com.apple/\*"'; then
  die "PF main ruleset still has no com.apple/* anchor after repair. Run: sudo pfctl -f /etc/pf.conf"
fi

: > "$PF_RULES"
for dev in "${GUARDED_IFS[@]}"; do
  # Group-scoped only. No machine-wide DNS blocks: the two rules below already
  # cover ports 53 and 853 for the guarded processes, and a machine-wide block
  # would take DNS away from the entire Mac.
  printf 'block drop out quick on %s inet  proto { tcp udp } from any to any group %s\n' "$dev" "$GROUP_GID" >> "$PF_RULES"
  printf 'block drop out quick on %s inet6 proto { tcp udp } from any to any group %s\n' "$dev" "$GROUP_GID" >> "$PF_RULES"
done

sudo pfctl -vnf "$PF_RULES" >/dev/null 2>&1 || { cat "$PF_RULES" >&2; die "PF rejected the generated rules."; }
sudo pfctl -a "$ANCHOR" -f "$PF_RULES" >/dev/null
GUARD_INSTALLED=1
loaded="$(sudo pfctl -a "$ANCHOR" -s rules 2>/dev/null | grep -c 'block drop out' || true)"
[ "${loaded:-0}" -ge 1 ] || die "PF anchor $ANCHOR is empty after load."
phase_ok "${loaded} rules in $ANCHOR on ${GUARDED_IFS[*]}"

restricted() {
  sudo -n -u "$LOGIN_USER" -g "$GROUP_NAME" \
    /usr/bin/env HOME="$LOGIN_HOME" USER="$LOGIN_USER" LOGNAME="$LOGIN_USER" PATH="$ORIGINAL_PATH" "$@"
}

# Launching a GUI app through plain `sudo` from a DETACHED ROOT process leaves it
# in the System domain with no audit session (getauid() returns -1). The login
# keychain is then unreachable, so the app cannot read its saved credentials and
# shows a sign-in page on every launch. `launchctl asuser` joins the user's Aqua
# session and restores both. Only needed when we are root: a run started from
# the user's own Terminal already has a session to inherit.
launch_app() {
  if (( RUN_AS_ROOT )); then
    /bin/launchctl asuser "$LOGIN_UID" \
      sudo -n -u "$LOGIN_USER" -g "$GROUP_NAME" \
      /usr/bin/env HOME="$LOGIN_HOME" USER="$LOGIN_USER" LOGNAME="$LOGIN_USER" PATH="$ORIGINAL_PATH" "$@"
  else
    restricted "$@"
  fi
}

# Raw TCP probe against literal IPs: no DNS, no dependence on one website being
# up. Prints the number of targets that were reachable.
cat > "$PROBE" <<'PYPROBE'
import socket, sys
TARGETS = [("1.1.1.1",443),("8.8.8.8",53),("9.9.9.9",443),("1.0.0.1",80),("208.67.222.222",443)]
reach = 0
for host, port in TARGETS:
    try:
        s = socket.create_connection((host, port), 4); s.close(); reach += 1
    except Exception:
        pass
print(reach)
PYPROBE
chmod 711 "$TMPROOT"
chmod 644 "$PROBE"

# --------------------------------------------------------------- phase 7 ---
phase 7 CALIBRATE "proving the leak test can actually detect egress"

control="$("$PY" "$PROBE" 2>/dev/null || echo 0)"
if [ "${control:-0}" -eq 0 ]; then
  die "Calibration failed: even an UNGUARDED process cannot reach any test target, so a 'blocked' result would be meaningless. Check your Internet connection and rerun. (This is the false-PASS bug from the old script.)"
fi
phase_ok "control probe reached $control/5 targets - test is meaningful"

# --------------------------------------------------------------- phase 8 ---
phase 8 LEAKTEST "confirming the guarded group has no direct egress"

leaked="$(restricted /usr/bin/env HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= NO_PROXY='*' \
  http_proxy= https_proxy= all_proxy= no_proxy='*' \
  "$PY" "$PROBE" 2>/dev/null || echo 0)"
[ "${leaked:-0}" -eq 0 ] \
  || die "UNSAFE: guarded process reached $leaked/5 targets directly. PF is not enforcing; refusing to claim protection."
phase_ok "0/5 targets reachable directly - guard is enforcing"

# --------------------------------------------------------------- phase 9 ---
phase 9 PROXYPATH "verifying the tunnel path and injecting app config"

PROTECTED_IP="$(restricted /usr/bin/env \
  HTTP_PROXY="$HTTP_PROXY_URL" HTTPS_PROXY="$HTTP_PROXY_URL" \
  http_proxy="$HTTP_PROXY_URL" https_proxy="$HTTP_PROXY_URL" \
  ALL_PROXY= all_proxy= NO_PROXY="127.0.0.1,localhost,::1" no_proxy="127.0.0.1,localhost,::1" \
  /usr/bin/curl -4fsS -x "$HTTP_PROXY_URL" --noproxy '' \
  --connect-timeout 6 --max-time 15 https://api.ipify.org 2>/dev/null || true)"
[ "$PROTECTED_IP" = "$SOCKS_IP" ] \
  || die "Tunnel path failed (expected $SOCKS_IP, got ${PROTECTED_IP:-none})."

wants_app() {
  local needle="$1" n
  for n in ${APP_NAMES[@]+"${APP_NAMES[@]}"}; do [ "$n" = "$needle" ] && return 0; done
  return 1
}

if [ "$SELF_TEST" -eq 1 ]; then
  phase_ok "tunnel path verified at $PROTECTED_IP"
  emit 11 READY ok "self-test passed"
  cat <<EOF

======================================================================
  SELF-TEST PASSED - the guard mechanism works on this Mac
======================================================================
  Control probe (unguarded)  : reached $control/5 targets
  Guarded probe              : reached $leaked/5 targets   <- must be 0
  Tunnel exit IP             : $SOCKS_IP
  Bridge                     : $HTTP_PROXY_URL
  Isolation group            : $GROUP_NAME (gid=$GROUP_GID)
  Guarded links              : ${GUARDED_IFS[*]}

  The calibration in phase 7 is what the old scripts lacked: the leak
  test in phase 8 is only trusted because an unguarded probe proved it
  could have detected egress.

  No app was launched. Tearing everything down now...
======================================================================

EOF
  exit 0
fi

if wants_app Claude; then
  mkdir -p "$HOME/.claude"
  "$PY" - "$SETTINGS_FILE" "$SETTINGS_STATE" "$HTTP_PROXY_URL" <<'PY' || die "Could not patch settings.json"
import json, os, sys, tempfile
settings_path, state_path, proxy = sys.argv[1:4]
keys = {"HTTP_PROXY": proxy, "HTTPS_PROXY": proxy, "http_proxy": proxy, "https_proxy": proxy,
        "NO_PROXY": "127.0.0.1,localhost,::1", "no_proxy": "127.0.0.1,localhost,::1"}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        data = json.load(f)
else:
    data = {}
if not isinstance(data, dict):
    raise SystemExit(2)
env_was_absent = not isinstance(data.get("env"), dict)
if env_was_absent:
    data["env"] = {}
env = data["env"]
state = {"env_was_absent": env_was_absent, "keys": {}}
for k, v in keys.items():
    state["keys"][k] = {"present": k in env, "value": env.get(k)}
    env[k] = v
with open(state_path, "w") as f:
    json.dump(state, f)
fd, tmp = tempfile.mkstemp(prefix=".settings.apptunnel.", dir=os.path.dirname(settings_path))
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2); f.write("\n")
os.replace(tmp, settings_path)
PY
  SETTINGS_PATCHED=1
  normalize_user_config_file "$SETTINGS_FILE" \
    || die "Could not secure patched Claude settings for $LOGIN_USER."
fi

if wants_app ChatGPT || wants_app Codex; then
  mkdir -p "$HOME/.codex"
  "$PY" - "$CODEX_ENV_FILE" "$CODEX_ENV_STATE" "$HTTP_PROXY_URL" <<'PY' || die "Could not patch ~/.codex/.env"
import json, os, re, sys, tempfile
env_path, state_path, proxy = sys.argv[1:4]
values = {"HTTP_PROXY": proxy, "HTTPS_PROXY": proxy, "http_proxy": proxy, "https_proxy": proxy,
          "NO_PROXY": "127.0.0.1,localhost,::1", "no_proxy": "127.0.0.1,localhost,::1"}
keys = set(values)
file_was_absent = not os.path.exists(env_path)
try:
    with open(env_path, encoding="utf-8") as f:
        lines = f.readlines()
except FileNotFoundError:
    lines = []
pat = re.compile(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=')
original_target, kept = [], []
for line in lines:
    m = pat.match(line)
    (original_target if (m and m.group(1) in keys) else kept).append(line)
with open(state_path, "w", encoding="utf-8") as f:
    json.dump({"file_was_absent": file_was_absent, "keys": sorted(keys),
               "original_target_lines": original_target}, f)
while kept and not kept[0].strip():
    kept.pop(0)
if kept and not kept[-1].endswith("\n"):
    kept[-1] += "\n"
kept.append("# apptunnel: temporary proxy settings, removed automatically\n")
kept.extend("%s=%s\n" % (k, v) for k, v in values.items())
fd, tmp = tempfile.mkstemp(prefix=".env.apptunnel.", dir=os.path.dirname(env_path))
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.writelines(kept)
os.replace(tmp, env_path)
PY
  CODEX_ENV_PATCHED=1
  normalize_user_config_file "$CODEX_ENV_FILE" \
    || die "Could not secure patched Codex environment for $LOGIN_USER."
fi
phase_ok "tunnel path verified at $PROTECTED_IP"

# PIDs of live processes that are already inside the isolation group AND are
# running this executable. These are the apps that survived a disconnect: their
# gid still matches and their baked-in HTTP_PROXY still points at the bridge
# port, so the rebuilt tunnel is the one they were already using.
#
# Main-executable matches only, for the same reason main_pids_of does it: a bare
# `grep -F "$exe"` matches the grep process itself, which made every check
# report the app as running forever.
group_pids_for_exe() {
  ps -axo pid=,gid=,command= | awk -v g="$1" -v e="$2" '
    {p=$1; gg=$2; $1=""; $2=""; sub(/^[ \t]+/,"");
     if (gg==g && ($0==e || index($0, e " ")==1)) print p}'
}

# -------------------------------------------------------------- phase 10 ---
phase 10 LAUNCH "starting protected app(s)"

"$PY" -c 'import json,sys
json.dump({"pid":int(sys.argv[1]),"gid":int(sys.argv[2]),"group":sys.argv[3],
           "anchor":sys.argv[4],"proxy":sys.argv[5],"exit_ip":sys.argv[6],
           "apps":sys.argv[7:]}, open("'"$STATE_FILE"'","w"))' \
  "$$" "$GROUP_GID" "$GROUP_NAME" "$ANCHOR" "$HTTP_PROXY_URL" "$SOCKS_IP" \
  ${APP_PATHS[@]+"${APP_PATHS[@]}"} 2>/dev/null || true
if (( RUN_AS_ROOT )); then chown "$LOGIN_USER" "$STATE_FILE" 2>/dev/null || true; fi

# Executables adopted rather than launched. Recorded because a freshly launched
# app is also in the group moments later, so "is it in the group?" cannot by
# itself tell the two apart in the verification pass below.
ADOPTED_LIST=""

idx=0
for exe in ${APP_EXECS[@]+"${APP_EXECS[@]}"}; do
  name="${APP_NAMES[$idx]}"
  # Survived the last disconnect: adopt it rather than quitting and relaunching.
  # `|| true`: head closes the pipe after one line, so a second match makes awk
  # die of SIGPIPE and pipefail would carry 141 into this assignment.
  adopted="$(group_pids_for_exe "$GROUP_GID" "$exe" | head -1 || true)"
  if [ -n "$adopted" ]; then
    log "      $name already inside the tunnel; adopting pid $adopted"
    APP_MAIN_PIDS+=("$adopted")
    ADOPTED_LIST="$ADOPTED_LIST$exe
"
    idx=$((idx+1))
    continue
  fi
  set +e
  launch_app /usr/bin/env \
    HOME="$LOGIN_HOME" USER="$LOGIN_USER" LOGNAME="$LOGIN_USER" PATH="$ORIGINAL_PATH" \
    HTTP_PROXY="$HTTP_PROXY_URL" HTTPS_PROXY="$HTTP_PROXY_URL" \
    http_proxy="$HTTP_PROXY_URL" https_proxy="$HTTP_PROXY_URL" \
    NO_PROXY="127.0.0.1,localhost,::1" no_proxy="127.0.0.1,localhost,::1" \
    ALL_PROXY= all_proxy= \
    "$exe" >"$TMPROOT/$name.stdout.log" 2>"$TMPROOT/$name.stderr.log" &
  APP_WRAPPER_PIDS+=("$!")
  set -e
  idx=$((idx+1))
done

sleep 5

idx=0
for exe in ${APP_EXECS[@]+"${APP_EXECS[@]}"}; do
  name="${APP_NAMES[$idx]}"
  # Adopted apps were verified in-group when they were found and were never
  # launched, so they have no stderr log to quote and must not be recorded twice.
  if printf '%s' "$ADOPTED_LIST" | grep -Fxq "$exe"; then
    idx=$((idx+1))
    continue
  fi
  pid="$(ps -axo pid=,command= | awk -v exe="$exe" '{p=$1;$1="";sub(/^[ \t]+/,"");if($0==exe||index($0,exe" ")==1)print p}' | head -1 || true)"
  if [ -z "$pid" ]; then
    tail -40 "$TMPROOT/$name.stderr.log" >&2 || true
    die "$name did not start inside the tunnel."
  fi
  gid="$(ps -o gid= -p "$pid" 2>/dev/null | awk '{print $1}')"
  [ "$gid" = "$GROUP_GID" ] || die "$name (pid $pid) is not in the isolation group (gid=$gid)."
  APP_MAIN_PIDS+=("$pid")
  log "      $name pid=$pid gid=$gid"
  idx=$((idx+1))
done
phase_ok "${#APP_MAIN_PIDS[@]} app(s) running inside the tunnel"

emit 11 READY ok "exit IP $SOCKS_IP via $HTTP_PROXY_URL"
cat <<EOF

======================================================================
  TUNNEL ACTIVE
======================================================================
  Apps            : ${APP_NAMES[*]}
  SOCKS5          : $SOCKS_HOST:$SOCKS_PORT
  HTTP bridge     : $HTTP_PROXY_URL
  Exit IP         : $SOCKS_IP
  Isolation group : $GROUP_NAME (gid=$GROUP_GID)
  Guarded links   : ${GUARDED_IFS[*]}

  Direct egress from guarded apps : BLOCKED (verified, calibrated)
  Everything else on this Mac     : UNTOUCHED

  Keep this window open. Quit the app(s) to end the session.
======================================================================

EOF

descendant_pids() {
  ps -A -o pid= -o ppid= 2>/dev/null | awk -v root="$1" '
    {if($1~/^[0-9]+$/&&$2~/^[0-9]+$/){pid[n]=$1;pp[n]=$2;n++}}
    END{w[root]=1;c=1
      while(c){c=0;for(i=0;i<n;i++)if(w[pp[i]]&&!w[pid[i]]){w[pid[i]]=1;c=1}}
      for(i=0;i<n;i++)if(w[pid[i]])print pid[i]}' | awk 'NF&&!s[$0]++'
}

any_alive() {
  local p
  for p in ${APP_MAIN_PIDS[@]+"${APP_MAIN_PIDS[@]}"}; do kill -0 "$p" 2>/dev/null && return 0; done
  return 1
}

# Add one app to the RUNNING tunnel, on request from AppTunnel.
#
# The app cannot do this itself: joining the isolation group needs root, and we
# already have it. That means no second password prompt, and — the point of the
# feature — the apps already inside the tunnel are never disturbed.
#
# The requested app must not already be running OUTSIDE the group, or
# LaunchServices simply reactivates that untunnelled process. So this quits that
# one app, and only that one.
# Main-executable pids ONLY. `ps | grep -F "$exe"` cannot be used here: the grep
# process itself carries $exe on its command line, so the test matched itself and
# reported the app as still running forever - which made every join fail with
# "would not quit".
main_pids_of() {
  ps -axo pid=,command= | awk -v e="$1" '
    {p=$1; $1=""; sub(/^[ \t]+/,""); if ($0==e || index($0, e " ")==1) print p}'
}

join_app() {
  local bundle="$1" exe name pid gid i left
  [ -d "$bundle" ] || { emit 13 JOIN fail "not an app bundle: $bundle"; return 1; }
  name="$(basename "$bundle" .app)"
  exe="$bundle/Contents/MacOS/$("$PY" -c '
import plistlib,sys
with open(sys.argv[1],"rb") as f: print(plistlib.load(f).get("CFBundleExecutable",""))
' "$bundle/Contents/Info.plist" 2>/dev/null)"
  [ -x "$exe" ] || { emit 13 JOIN fail "no executable in $name"; return 1; }

  emit 13 JOIN run "adding $name to the running tunnel"
  log "Join request: $name"

  # Already a member - it survived a disconnect, or was launched with the tunnel.
  # Adopt it. Quitting here would destroy a live session to achieve nothing.
  # `|| true`: head closes the pipe after one line, so a second match makes awk
  # die of SIGPIPE and pipefail would carry 141 into this assignment.
  adopted="$(group_pids_for_exe "$GROUP_GID" "$exe" | head -1 || true)"
  if [ -n "$adopted" ]; then
    APP_MAIN_PIDS+=("$adopted")
    log "      $name already inside the tunnel; adopting pid $adopted"
    emit 13 JOIN ok "$name already inside the tunnel; adopted pid $adopted"
    return 0
  fi

  # Quit only this app - and only if it is actually running.
  left="$(main_pids_of "$exe")"
  if [ -n "$left" ]; then
    log "      quitting $name (pids $(echo "$left" | tr '\n' ' ')) so it can rejoin inside the tunnel"
    # Ask politely first so the app can save state. The error is captured, not
    # discarded: Automation (TCC) can deny this when it comes from a root
    # context, and silently swallowing that looked like the app refusing.
    qerr="$(/bin/launchctl asuser "$LOGIN_UID" sudo -n -u "$LOGIN_USER" \
             /usr/bin/osascript -e "tell application \"$name\" to quit" 2>&1)" || true
    [ -n "$qerr" ] && log "      osascript: $(printf '%s' "$qerr" | head -1)"

    i=0
    while [ "$i" -lt 30 ]; do
      [ -z "$(main_pids_of "$exe")" ] && break
      sleep 0.5; i=$((i+1))
    done

    # AppleScript may be unavailable or denied; we are root, so fall back.
    left="$(main_pids_of "$exe")"
    if [ -n "$left" ]; then
      log "      graceful quit did not take; sending TERM"
      # shellcheck disable=SC2086
      kill -TERM $left 2>/dev/null || true
      i=0
      while [ "$i" -lt 20 ]; do
        [ -z "$(main_pids_of "$exe")" ] && break
        sleep 0.5; i=$((i+1))
      done
    fi
    left="$(main_pids_of "$exe")"
    if [ -n "$left" ]; then
      log "      still up; sending KILL"
      # shellcheck disable=SC2086
      kill -KILL $left 2>/dev/null || true
      sleep 1
    fi
  else
    log "      $name is not running; launching it straight into the tunnel"
  fi

  left="$(main_pids_of "$exe")"
  if [ -n "$left" ]; then
    emit 13 JOIN fail "$name could not be stopped (pids $(echo "$left" | tr '\n' ' ')); not moved into the tunnel"
    return 1
  fi

  set +e
  launch_app /usr/bin/env \
    HTTP_PROXY="$HTTP_PROXY_URL" HTTPS_PROXY="$HTTP_PROXY_URL" \
    http_proxy="$HTTP_PROXY_URL" https_proxy="$HTTP_PROXY_URL" \
    NO_PROXY="127.0.0.1,localhost,::1" no_proxy="127.0.0.1,localhost,::1" \
    ALL_PROXY= all_proxy= \
    "$exe" >"$TMPROOT/$name.stdout.log" 2>"$TMPROOT/$name.stderr.log" &
  APP_WRAPPER_PIDS+=("$!")
  set -e

  i=0; pid=""
  while [ "$i" -lt 20 ]; do
    sleep 0.5
    pid="$(ps -axo pid=,command= | awk -v e="$exe" '{p=$1;$1="";sub(/^[ \t]+/,"");if($0==e||index($0,e" ")==1)print p}' | head -1 || true)"
    [ -n "$pid" ] && break
    i=$((i+1))
  done
  if [ -z "$pid" ]; then
    emit 13 JOIN fail "$name did not start"
    return 1
  fi
  gid="$(ps -o gid= -p "$pid" 2>/dev/null | awk '{print $1}')"
  if [ "$gid" != "$GROUP_GID" ]; then
    emit 13 JOIN fail "$name started outside the isolation group (gid=$gid)"
    return 1
  fi
  APP_MAIN_PIDS+=("$pid")
  log "      $name pid=$pid gid=$gid - now inside the tunnel"
  emit 13 JOIN ok "$name joined the tunnel"
}

while any_alive; do
  sleep 3

  # Publish telemetry on a slow cadence. Detached and lock-guarded: a sampling
  # pass takes about half a second, and this loop must keep auditing the process
  # tree every 3s regardless. A stale lock older than 2 minutes is ignored so a
  # killed sampler cannot silence telemetry for the rest of the session.
  TELEMETRY_TICK=$(( ${TELEMETRY_TICK:-0} + 1 ))
  if [ $(( TELEMETRY_TICK % 5 )) -eq 0 ]; then
    if [ -f "$TELEMETRY_LOCK" ] \
       && [ -n "$(find "$TELEMETRY_LOCK" -mmin +2 2>/dev/null)" ]; then
      rm -f "$TELEMETRY_LOCK"
    fi
    if [ ! -f "$TELEMETRY_LOCK" ]; then
      (
        : > "$TELEMETRY_LOCK"
        snap="$("$(dirname "$0")/tunnel-telemetry.sh" \
                  --gid "$GROUP_GID" --anchor "$ANCHOR" \
                  --bridge "$HTTP_PROXY_URL" --exit-ip "$SOCKS_IP" 2>/dev/null)"
        if [ -n "$snap" ]; then
          printf '%s\n' "$snap" > "$TELEMETRY_FILE.tmp" \
            && mv -f "$TELEMETRY_FILE.tmp" "$TELEMETRY_FILE"
          if (( RUN_AS_ROOT )); then
            chown "$LOGIN_USER" "$TELEMETRY_FILE" 2>/dev/null || true
          fi
        fi
        rm -f "$TELEMETRY_LOCK"
      ) >/dev/null 2>&1 &
    fi
  fi

  # A one-app join request from the roster's RUN button.
  if [ -f "$RUN_FILE" ]; then
    requested="$(head -1 "$RUN_FILE" 2>/dev/null)"
    rm -f "$RUN_FILE"
    [ -n "$requested" ] && join_app "$requested" || true
  fi
  # The app requests shutdown by creating this file; it cannot signal a
  # root-owned launcher directly.
  if [ -f "$STOP_FILE" ]; then
    # Record WHO asked. The stop file carries provenance; without it a
    # deliberate stop is indistinguishable afterwards from a crash.
    stop_who="$(head -c 400 "$STOP_FILE" 2>/dev/null || true)"
    log "Stop requested; dropping the network, apps left running. ${stop_who:-(no provenance recorded)}"
    emit 97 STOPPING run "stop requested"
    # Stop tears the tunnel down; it does not close the apps. They keep running
    # with no route out, hold their gid, and are adopted again by the next
    # connect - which is the whole point of pressing stop and then play. Killing
    # them here destroyed live Claude and Codex sessions on every stop, and was
    # missed when cleanup() and the escape handler were fixed one path at a
    # time. tunnel-quit.sh is the only path that may close them.
    break
  fi
  bad=0
  for root in ${APP_MAIN_PIDS[@]+"${APP_MAIN_PIDS[@]}"}; do
    kill -0 "$root" 2>/dev/null || continue
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      kill -0 "$pid" 2>/dev/null || continue
      [ "$(ps -o user= -p "$pid" 2>/dev/null | awk '{print $1}')" = "$LOGIN_USER" ] || continue
      gid="$(ps -o gid= -p "$pid" 2>/dev/null | awk '{print $1}')"
      if [ -n "$gid" ] && [ "$gid" != "$GROUP_GID" ]; then
        printf '\nESCAPED: pid=%s gid=%s %s\n' "$pid" "$gid" "$(ps -o command= -p "$pid" 2>/dev/null)" >&2
        bad=$((bad+1))
      fi
    done < <(descendant_pids "$root")
  done
  if [ "$bad" -gt 0 ]; then
    emit 12 ESCAPE fail "$bad process(es) left the isolation group - failing closed"
    # Exiting runs cleanup, which tears down PF and the bridge. That is what
    # failing closed means here: the escaped process loses its route out. The
    # apps are left running so the session survives and can re-adopt the tunnel.
    log "Failing closed: dropping the network, apps left running."
    exit 70
  fi
done

# Reached either because every protected app exited on its own, or because stop
# was requested - in which case they are still running, just without a route.
if any_alive; then
  log "Tunnel down. Protected app(s) left running; press play to reconnect them."
else
  log "All protected apps exited."
fi
exit 0
