#!/bin/bash
# tunnel-selfcheck.sh — regression suite for the whole toolkit.
#
# Runs WITHOUT sudo, launches no apps, quits no apps, and never touches a live
# tunnel session. Safe to run at any time, including from inside a tunnelled
# app. Every bug this project has shipped was found by a user losing a session;
# each one that could be caught mechanically is now a test below.
#
#   tunnel-selfcheck.sh          run everything
#   tunnel-selfcheck.sh --quick  skip the app build/render tests
#
# Exit code is the number of failures.

set -uo pipefail

# The system python3 at /usr/bin is a Command Line Tools stub: it exists and is
# executable even when the Tools are not installed, and then every call dies
# with "invalid active developer path". This resolves one that actually runs.
. "$(cd "$(dirname "$0")" && pwd)/tunnel-python.sh"

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$BIN")"
APPDIR="$(dirname "$ROOT")"
STATE_DIR="$HOME/.apptunnel"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/tunnel-selfcheck.XXXXXX")"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

PASS=0; FAIL=0; SKIP=0
C=$'\033[36m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; O=$'\033[0m'

hdr()  { printf '\n%s== %s ==%s\n' "$C" "$1" "$O"; }
pass() { PASS=$((PASS+1)); printf '   %sPASS%s  %s\n' "$G" "$O" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '   %sFAIL%s  %s\n' "$R" "$O" "$1"
         [ -n "${2:-}" ] && printf '         %s%s%s\n' "$D" "$2" "$O"; }
skip() { SKIP=$((SKIP+1)); printf '   %sskip%s  %s\n' "$Y" "$O" "$1"; }

# assert_contains "label" "expected substring" "actual"
assert_contains() {
  case "$3" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected to contain: $2" ;;
  esac
}
assert_not_contains() {
  case "$3" in
    *"$2"*) fail "$1" "must NOT contain: $2" ;;
    *) pass "$1" ;;
  esac
}

# ---- protect the user's real state ----------------------------------------
LIVE_SESSION=0
if [ -f "$STATE_DIR/session.json" ]; then
  pid="$("$PY" -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("pid",""))
except Exception: pass' "$STATE_DIR/session.json" 2>/dev/null)"
  [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1 && LIVE_SESSION=1
fi

# Record which files existed BEFORE we touch anything. The first version of
# this deleted the user's roster: it removed each file unconditionally and only
# restored ones it had backed up, so a file that existed but whose backup was
# lost (an earlier run killed mid-flight) was destroyed outright.
mkdir -p "$SANDBOX/backup"
for f in apps.json protected.json session.json; do
  if [ -f "$STATE_DIR/$f" ]; then
    cp -p "$STATE_DIR/$f" "$SANDBOX/backup/$f" && : > "$SANDBOX/backup/$f.existed"
  fi
done
restore_state() {
  local f
  for f in apps.json protected.json session.json; do
    if [ -f "$SANDBOX/backup/$f.existed" ]; then
      cp -p "$SANDBOX/backup/$f" "$STATE_DIR/$f" 2>/dev/null   # put the original back
    elif [ -f "$SANDBOX/marker/$f.created" ]; then
      rm -f "$STATE_DIR/$f"                                    # only remove what WE made
    fi
  done
  rm -rf "$SANDBOX"
}
mkdir -p "$SANDBOX/marker"
note_created() { : > "$SANDBOX/marker/$1.created"; }
trap restore_state EXIT INT TERM

printf '%stunnel-selfcheck%s  %s\n' "$C" "$O" "$([ "$LIVE_SESSION" = 1 ] && echo 'a live tunnel session is running - state-mutating tests will be skipped' || echo 'no live session')"

# =========================================================== static checks ==
hdr "1. Static"
for f in "$BIN"/tunnel-*.sh; do
  n="$(basename "$f")"
  if /bin/bash -n "$f" 2>/dev/null; then pass "$n parses"; else fail "$n parses" "$(/bin/bash -n "$f" 2>&1 | head -2)"; fi
  [ -x "$f" ] && pass "$n is executable" || fail "$n is executable"
done

# The defect that made the whole toolkit inert on a Mac with no Command Line
# Tools: /usr/bin/python3 is an xcrun stub, so `command -v python3` succeeded
# while every actual call died with "invalid active developer path". The SOCKS
# probe, the bridge, the JSON parsing and the telemetry sampler all went through
# it, so the app stalled on phase 2 and the analyser stayed blank.
# The pattern is assembled from pieces rather than written out, so that this
# test does not match its own source - the same trap the port-53 check fell
# into, where the comment explaining a bug was read as the bug.
STUB="/usr/bin/""python3"
for f in "$BIN"/tunnel-*.sh; do
  n="$(basename "$f")"
  [ "$n" = "tunnel-python.sh" ] && continue          # the resolver names it on purpose
  if grep -vE '^[[:space:]]*#' "$f" | grep -q "$STUB"; then
    fail "$n resolves python3 instead of hardcoding the stub" \
         "found a literal $STUB call"
  else
    pass "$n resolves python3 instead of hardcoding the stub"
  fi
done
if [ "${TUNNEL_PY_OK:-0}" -eq 1 ] && "$PY" -c 'import json,socket' >/dev/null 2>&1; then
  pass "a working python3 was resolved ($PY)"
else
  fail "a working python3 was resolved" \
       "none of the candidates ran - install the Command Line Tools: xcode-select --install"
fi
grep -q 'TUNNEL_PY_OK' "$BIN/tunnel-lock.sh" \
  && pass "the launcher preflight RUNS python3 rather than trusting command -v" \
  || fail "the launcher preflight RUNS python3 rather than trusting command -v"

# The defect that took the Mac's DNS away: an unscoped port-53 block.
# Comments must be excluded - the file documents the old bug, and matching that
# text made this test fail against its own explanation.
if grep -vE '^[[:space:]]*#' "$BIN/tunnel-lock.sh" | grep -q 'to any port 53'; then
  fail "tunnel-lock.sh emits no machine-wide DNS block" "found a 'to any port 53' rule"
else
  pass "tunnel-lock.sh emits no machine-wide DNS block"
fi
if grep -q 'group %s' "$BIN/tunnel-lock.sh"; then
  pass "tunnel-lock.sh scopes its PF rules to the isolation group"
else
  fail "tunnel-lock.sh scopes its PF rules to the isolation group"
fi

# The defect that killed the caller's own session.
if grep -q 'stamp "  protecting pid $p (hosts the session driving this run)" >&2' "$BIN/tunnel-connect.sh"; then
  pass "tunnel-connect.sh logs pid protection to stderr, not the kill list"
else
  fail "tunnel-connect.sh logs pid protection to stderr, not the kill list"
fi
grep -q 'only_pids' "$BIN/tunnel-connect.sh" \
  && pass "tunnel-connect.sh filters the kill list to bare pids" \
  || fail "tunnel-connect.sh filters the kill list to bare pids"

# Validate-after-destroy: the launcher retired the running session BEFORE
# tunnel-lock.sh reached its phase-2 SOCKS check, so pressing Run while the VPN
# was down killed a working tunnel and every app inside it, then failed anyway
# and left the user with nothing. Preconditions must be proven before the first
# kill signal, not after.
precheck_ln="$(grep -n 'require_socks_endpoint' "$BIN/tunnel-connect.sh" | head -1 | cut -d: -f1)"
firstkill_ln="$(grep -n 'kill -TERM' "$BIN/tunnel-connect.sh" | head -1 | cut -d: -f1)"
if [ -n "$precheck_ln" ] && [ -n "$firstkill_ln" ] && [ "$precheck_ln" -lt "$firstkill_ln" ]; then
  pass "tunnel-connect.sh proves the SOCKS endpoint before it kills anything"
else
  fail "tunnel-connect.sh proves the SOCKS endpoint before it kills anything"
fi

# Re-attach requires identity that survives a reconnect. Keying the group, the
# anchor or the bridge port to $$ built a tunnel the surviving app was not a
# member of and could not reach, so reconnecting forced a relaunch.
for pat in 'ANCHOR="com.apple/apptunnel-\$\$"' 'GROUP_NAME="apptun\$\$"' 'GROUP_GID=\$((57000 + (\$\$ % 500)))'; do
  if grep -q "$pat" "$BIN/tunnel-lock.sh"; then
    fail "tunnel-lock.sh does not key tunnel identity to \$\$ ($pat)"
  else
    pass "tunnel-lock.sh does not key tunnel identity to \$\$ ($pat)"
  fi
done
grep -q 'BRIDGE_PORT="\${TUNNEL_BRIDGE_PORT:-17080}"' "$BIN/tunnel-lock.sh" \
  && pass "tunnel-lock.sh pins the bridge to a fixed port" \
  || fail "tunnel-lock.sh pins the bridge to a fixed port"

# Teardown killed every tunnelled app on any exit, so one transient failure
# destroyed live Claude/Codex sessions. Fail-closed must mean no network, not
# no process.
if awk '/^cleanup\(\)/,/^}/' "$BIN/tunnel-lock.sh" | grep -qE 'APP_(WRAPPER|MAIN)_PIDS'; then
  fail "cleanup() does not signal tunnelled apps"
else
  pass "cleanup() does not signal tunnelled apps"
fi
if grep -q 'Failing closed: dropping the network, apps left running' "$BIN/tunnel-lock.sh"; then
  pass "escape handler cuts the network without killing apps"
else
  fail "escape handler cuts the network without killing apps"
fi

# Whole-file audit, not a per-path one. cleanup() and the escape handler were
# fixed individually and the STOP_FILE handler was missed, so pressing stop
# still killed every tunnelled app - the exact behaviour that was supposed to
# be gone. Only tunnel-quit.sh may close these apps. `kill -0` is a liveness
# test, not a signal, so any_alive is allowed.
kill_sites="$(grep -nE 'APP_(WRAPPER|MAIN)_PIDS' "$BIN/tunnel-lock.sh" \
              | grep -E 'kill +-(TERM|KILL|HUP|INT|QUIT|1|2|3|9|15)' || true)"
if [ -z "$kill_sites" ]; then
  pass "no path in tunnel-lock.sh signals the tunnelled apps"
else
  fail "no path in tunnel-lock.sh signals the tunnelled apps"
  printf '%s\n' "$kill_sites" | sed 's/^/          /'
fi

# A reconnect must adopt the processes that are already inside the group
# instead of quitting and relaunching them.
grep -q '^group_pids_for_exe()' "$BIN/tunnel-lock.sh" \
  && pass "tunnel-lock.sh can find live members of the isolation group" \
  || fail "tunnel-lock.sh can find live members of the isolation group"
grep -q 'already inside the tunnel; adopting' "$BIN/tunnel-lock.sh" \
  && pass "tunnel-lock.sh adopts a running app instead of relaunching it" \
  || fail "tunnel-lock.sh adopts a running app instead of relaunching it"
if awk '/^join_app\(\)/,/^}/' "$BIN/tunnel-lock.sh" | grep -q 'group_pids_for_exe'; then
  pass "join_app skips the quit for an app already in the group"
else
  fail "join_app skips the quit for an app already in the group"
fi

# PREFLIGHT (phase 1) quit every running roster app unconditionally, so a
# reconnect closed Claude and Codex before the adoption logic in phase 10 could
# ever see them - nothing was left in the group by then. Three teardown paths
# were fixed while this one, on the CONNECT side, kept doing it.
if awk '/^# Every selected app must be fully quit/,/^done$/' "$BIN/tunnel-lock.sh" \
     | grep -q 'PREFLIGHT_GID'; then
  pass "preflight leaves apps already inside the tunnel alone"
else
  fail "preflight leaves apps already inside the tunnel alone"
fi

# Stop leaves apps running so they can re-adopt; quitting AppTunnel is the one
# action that closes them.
if [ -x "$BIN/tunnel-quit.sh" ]; then
  pass "tunnel-quit.sh exists and is executable"
else
  fail "tunnel-quit.sh exists and is executable"
fi
bash -n "$BIN/tunnel-quit.sh" 2>/dev/null \
  && pass "tunnel-quit.sh parses" || fail "tunnel-quit.sh parses"
grep -q 'tunnel-quit.sh' "$BIN/../gui/tunneld.py" \
  && pass "the GUI closes tunnelled apps when it shuts down" \
  || fail "the GUI closes tunnelled apps when it shuts down"

# tunnel-lock.sh runs `set -euo pipefail`, which turns a command substitution
# that ends non-zero into a SILENT script death - no die(), no message, just
# teardown. Phase 5 died this way: `dscl -read` exits 56 when the group does not
# exist, and pipefail carried that out of the pipeline into the assignment.
# A pipeline ending in `head -1` is the same hazard via SIGPIPE (141) as soon as
# there is more than one match.
if grep -qE 'existing_gid="\$\(.*\|\| true\)"' "$BIN/tunnel-lock.sh"; then
  pass "the isolation-group lookup survives a missing group"
else
  fail "the isolation-group lookup survives a missing group"
fi
if grep -qE 'adopted="\$\(group_pids_for_exe[^)]*\| head -1\)"' "$BIN/tunnel-lock.sh"; then
  fail "adoption lookups survive SIGPIPE under pipefail"
else
  pass "adoption lookups survive SIGPIPE under pipefail"
fi
# Prove the idiom itself, not just its spelling: guarded, it must still yield the
# first line instead of killing the shell.
if bash -c 'set -euo pipefail; f() { printf "a\nb\nc\n"; }; x="$(f | head -1 || true)"; [ "$x" = a ]' 2>/dev/null; then
  pass "the guarded head -1 idiom returns the first match without dying"
else
  fail "the guarded head -1 idiom returns the first match without dying"
fi

# The VPN repair control was first added only to the web GUI, which the Swift
# app never loads, so it did not exist for the user who opens AppTunnel.app.
# Any control the user is told about must exist in the native panel.
SRC="$BIN/../app/AppTunnel/Sources/main.swift"
if grep -q 'Btn("VPN REPAIR"' "$SRC" 2>/dev/null; then
  pass "AppTunnel's native panel has a labelled VPN REPAIR button"
else
  fail "AppTunnel's native panel has a labelled VPN REPAIR button"
fi
grep -q 'tunnel-veepn-repair.sh' "$SRC" 2>/dev/null \
  && pass "the native VPN button is wired to tunnel-veepn-repair.sh" \
  || fail "the native VPN button is wired to tunnel-veepn-repair.sh"
# Running it as root would inherit root's HOME, find no VeePN config, and leave
# a root-owned proxy core behind.
if awk '/func repairVPN\(\)/,/^    }/' "$SRC" 2>/dev/null | grep -q 'Runner.user'; then
  pass "the VPN repair runs as the user, not as root"
else
  fail "the VPN repair runs as the user, not as root"
fi

# Attributing a disconnection afterwards is impossible unless the one fact that
# cannot be reconstructed - who asked for the stop - is written down at the time.
for f in tunnel-eventlog.sh tunnel-forensics.sh; do
  [ -x "$BIN/$f" ] && pass "$f exists and is executable" || fail "$f exists and is executable"
  bash -n "$BIN/$f" 2>/dev/null && pass "$f parses" || fail "$f parses"
done
# The UI animated at a flat 30fps forever, stepping four views and dirtying the
# title bar every tick even while the window was hidden. Each frame also cost a
# WindowServer composite, so an idle tunnel sat at ~18% + ~24% of a core.
if grep -q 'withTimeInterval: 1.0 / 30, repeats: true' "$SRC" 2>/dev/null; then
  fail "the UI does not animate at a flat 30fps regardless of state"
else
  pass "the UI does not animate at a flat 30fps regardless of state"
fi
grep -q 'didChangeOcclusionStateNotification' "$SRC" 2>/dev/null \
  && pass "the UI stops animating when nobody can see it" \
  || fail "the UI stops animating when nobody can see it"
if awk '/private func pulseLED/,/^    }/' "$SRC" 2>/dev/null | grep -q 'if v != tb.ledPulse'; then
  pass "the LED only forces a redraw when its value actually changed"
else
  fail "the LED only forces a redraw when its value actually changed"
fi

grep -q 'who.*AppTunnel stop button' "$SRC" 2>/dev/null \
  && pass "the stop button records who requested the stop" \
  || fail "the stop button records who requested the stop"
grep -q '"who": "AppTunnel web GUI' "$BIN/../gui/tunneld.py" 2>/dev/null \
  && pass "the web GUI stop records its provenance too" \
  || fail "the web GUI stop records its provenance too"
grep -q 'stop_who=' "$BIN/tunnel-lock.sh" \
  && pass "the launcher logs the stop provenance it was given" \
  || fail "the launcher logs the stop provenance it was given"
# The recorder runs forever, so its per-sample cost is multiplied by every
# interval for as long as the machine is on. At 1.24s per sample on a 3s
# interval it burned 41% of a core continuously - the sampler became the
# biggest CPU consumer on the Mac it was meant to be quietly observing.
# Measured as duty cycle, not as one snapshot: `once` always pays the cold path
# and would overstate the daemon's real cost. What matters is CPU per second of
# wall clock, which is what burned 41% of a core.
_duty="$("$BIN/tunnel-eventlog.sh" bench 8 2>/dev/null | awk '/duty cycle/{gsub("%","",$4); print $4}')"
if awk -v d="$_duty" 'BEGIN{exit !(d+0 > 0 && d+0 < 5.0)}' 2>/dev/null; then
  pass "the sampler costs under 5% of a core (measured ${_duty}%)"
else
  fail "the sampler costs under 5% of a core (measured ${_duty:-unknown}%)"
fi

# lsof cannot see sockets owned by root, so the root-owned bridge looked dead to
# an unprivileged sampler and produced false "the bridge died" verdicts.
if grep -q 'netstat' "$BIN/tunnel-eventlog.sh"; then
  pass "port state comes from netstat, which sees root-owned listeners"
else
  fail "port state comes from netstat, which sees root-owned listeners"
fi

# The recorder must never become a cause of what it observes. Matched on the
# MUTATING forms only: `networksetup -get...` and `pfctl -s` are reads, and the
# script legitimately signals its own daemon to stop it.
if grep -qE 'networksetup +-set|pfctl +-(F|e|d|f)\b|dseditgroup +-o +(create|delete|edit)|route +(add|delete)' \
        "$BIN/tunnel-eventlog.sh"; then
  fail "tunnel-eventlog.sh only observes, never changes system state"
else
  pass "tunnel-eventlog.sh only observes, never changes system state"
fi

# SUDO_USER can be inherited as "root" through a sudo chain, which made the
# doctor abort after one line and show an almost-empty window.
for f in tunnel-doctor.sh tunnel-freehost.sh tunnel-testkit.sh; do
  if grep -q 'SUDO_USER:-\$(id -un)' "$BIN/$f" 2>/dev/null; then
    fail "$f does not trust SUDO_USER when not root"
  else
    pass "$f does not trust SUDO_USER when not root"
  fi
done

# A GUI app launched by plain sudo from a detached root process has no audit
# session, cannot reach the login keychain, and asks the user to sign in on
# every launch.
if grep -q 'launchctl asuser' "$BIN/tunnel-lock.sh"; then
  pass "apps are launched inside the user's Aqua session (keychain works)"
else
  fail "apps are launched inside the user's Aqua session (keychain works)" \
       "no launchctl asuser - sign-in state will be lost every launch"
fi

# =========================================== login-session / keychain ======
hdr "1b. Login session of the current process"
mygname="$(id -gn)"
case "$mygname" in
  apptun*|cldesk*|cgptvpn*)
    # We are inside a tunnelled app: this is exactly where the sign-in state
    # gets lost, so check it directly rather than inferring from source.
    if security list-keychains 2>/dev/null | grep -q 'login.keychain'; then
      pass "the login keychain is reachable (saved sign-ins will persist)"
    else
      fail "the login keychain is reachable (saved sign-ins will persist)" \
           "only the System keychain is visible - this app will ask you to sign in every launch"
    fi
    auid="$("$PY" -c '
import ctypes, ctypes.util
lib = ctypes.CDLL(ctypes.util.find_library("System"))
v = ctypes.c_uint32()
lib.getauid(ctypes.byref(v))
print(v.value)' 2>/dev/null)"
    if [ "$auid" = "4294967295" ]; then
      fail "the process has a valid audit session" \
           "getauid() == -1: launched outside the user's Aqua session"
    else
      pass "the process has a valid audit session (auid $auid)"
    fi
    ;;
  *) skip "login-session checks (not running inside a tunnelled app)" ;;
esac

# The SOCKS port must be discovered, not assumed: VeePN publishes 1180 on some
# profiles, and hardcoding 1080 made phase 2 insist nothing was listening no
# matter how often the VPN was reconnected.
grep -q 'SOCKSPort' "$BIN/tunnel-lock.sh" \
  && pass "tunnel-lock discovers the SOCKS port from the system proxy settings" \
  || fail "tunnel-lock discovers the SOCKS port from the system proxy settings"
grep -q 'SOCKSPort' "$ROOT/app/AppTunnel/Sources/main.swift" \
  && pass "the app discovers the SOCKS port too" \
  || fail "the app discovers the SOCKS port too"
sysport="$(/usr/sbin/scutil --proxy 2>/dev/null | awk '/SOCKSPort/{print $3; exit}')"
if [ -n "$sysport" ]; then
  # stdin from /dev/null so the phase-4 `sudo -v` fails fast instead of
  # blocking this non-interactive suite on a password prompt.
  out="$("$BIN/tunnel-lock.sh" --self-test </dev/null 2>&1 | head -6)"
  assert_contains "phase 2 locates the advertised endpoint ($sysport)" ":$sysport" "$out"
else
  skip "live endpoint discovery (system SOCKS not configured)"
fi

# Every control must explain itself on hover.
btns="$(grep -c 'add(Btn(' "$ROOT/app/AppTunnel/Sources/main.swift" 2>/dev/null || echo 0)"
tips="$(grep -c 'tip: "' "$ROOT/app/AppTunnel/Sources/main.swift" 2>/dev/null || echo 0)"
if [ "${btns:-0}" -gt 0 ] && [ "${tips:-0}" -ge "${btns:-0}" ]; then
  pass "all $btns buttons have a hover description"
else
  fail "all buttons have a hover description" "$btns buttons but only $tips descriptions"
fi
grep -q 'toolTip = tip' "$ROOT/app/AppTunnel/Sources/main.swift" \
  && pass "descriptions are exposed as native tooltips" \
  || fail "descriptions are exposed as native tooltips"

# The doctor must diagnose the endpoint instability that broke phase 2.
grep -q 'VPN / SOCKS endpoint' "$BIN/tunnel-doctor.sh" \
  && pass "the doctor checks the VPN endpoint" \
  || fail "the doctor checks the VPN endpoint"
grep -q 'the advertised port is stale' "$BIN/tunnel-doctor.sh" \
  && pass "the doctor detects an advertised-vs-listening port mismatch" \
  || fail "the doctor detects an advertised-vs-listening port mismatch"
for probe in 'stale session lock' 'stale TEST MODE' 'not $LOGIN_USER'; do
  grep -qF "$probe" "$BIN/tunnel-doctor.sh" \
    && pass "the doctor detects: $probe" \
    || fail "the doctor detects: $probe"
done
out="$("$BIN/tunnel-doctor.sh" 2>&1)"
assert_contains "the doctor reports the live SOCKS endpoint" "system SOCKS proxy advertised at" "$out"
assert_contains "the doctor reports tunnel app state" "Tunnel app state" "$out"

# Per-app RUN: adding one app to a live tunnel must not disturb the others.
grep -q 'join_app' "$BIN/tunnel-lock.sh" \
  && pass "the launcher can add one app to a running tunnel" \
  || fail "the launcher can add one app to a running tunnel"
grep -q 'run-request' "$BIN/tunnel-lock.sh" \
  && pass "the launcher polls a join request file (no second password prompt)" \
  || fail "the launcher polls a join request file"
grep -q 'run-request' "$ROOT/app/AppTunnel/Sources/main.swift" \
  && pass "the app sends join requests through that file" \
  || fail "the app sends join requests through that file"
grep -q 'onRun' "$ROOT/app/AppTunnel/Sources/main.swift" \
  && pass "the roster has a per-app RUN control" \
  || fail "the roster has a per-app RUN control"
# join_app must only ever signal pids derived from the REQUESTED app.
# Checking for the string "kill" is useless - it legitimately kills that one
# app. The real invariant: it never uses the broad launcher-sweep helper, and
# every kill list comes from the exact main-executable matcher.
jbody="$(sed -n '/^join_app()/,/^}/p' "$BIN/tunnel-lock.sh")"
if printf '%s\n' "$jbody" | grep -q 'find_pids'; then
  fail "join_app never uses the broad launcher sweep" "it calls find_pids"
else
  pass "join_app never uses the broad launcher sweep"
fi
bad_assign="$(printf '%s\n' "$jbody" | grep -c 'left=' || true)"
good_assign="$(printf '%s\n' "$jbody" | grep -c 'left="$(main_pids_of "$exe")"' || true)"
if [ "${bad_assign:-0}" -eq "${good_assign:-0}" ] && [ "${good_assign:-0}" -gt 0 ]; then
  pass "every kill list in join_app comes from the requested app only ($good_assign)"
else
  fail "every kill list in join_app comes from the requested app only" \
       "$bad_assign assignments, only $good_assign from main_pids_of"
fi

# A liveness test built on `ps | grep -F "$exe"` matches its OWN grep process,
# so it always reports the app as running and every join failed with
# "would not quit". Liveness must use an exact main-executable match.
if sed -n '/^join_app()/,/^}/p' "$BIN/tunnel-lock.sh" | grep -q 'grep -Fq'; then
  fail "join_app uses an exact match, not a self-matching grep"
else
  pass "join_app uses an exact match, not a self-matching grep"
fi
grep -q 'main_pids_of()' "$BIN/tunnel-lock.sh" \
  && pass "an exact main-executable matcher exists" \
  || fail "an exact main-executable matcher exists"
# It must actually be exact: a path mentioned in another command line is not a run.
probe_exe="/Applications/__apptunnel_nonexistent__.app/Contents/MacOS/Nope"
hits="$(ps -axo pid=,command= | awk -v e="$probe_exe" '{p=$1;$1="";sub(/^[ \t]+/,"");if($0==e||index($0,e" ")==1)print p}' | wc -l | tr -d ' ')"
[ "${hits:-0}" -eq 0 ] \
  && pass "the matcher does not match a path merely mentioned on a command line" \
  || fail "the matcher does not match a path merely mentioned on a command line"
# A join that cannot stop the app must say so precisely, not blame the app.
sed -n '/^join_app()/,/^}/p' "$BIN/tunnel-lock.sh" | grep -q 'could not be stopped' \
  && pass "join failure names the pids it could not stop" \
  || fail "join failure names the pids it could not stop"
sed -n '/^join_app()/,/^}/p' "$BIN/tunnel-lock.sh" | grep -q 'kill -KILL' \
  && pass "join falls back past AppleScript when Automation is denied" \
  || fail "join falls back past AppleScript when Automation is denied"

# ================================================= telemetry sampler ========
hdr "1c. Telemetry sampler"
if [ ! -x "$BIN/tunnel-telemetry.sh" ]; then
  fail "tunnel-telemetry.sh exists and is executable"
else
  pass "tunnel-telemetry.sh exists and is executable"
  tsout="$("$BIN/tunnel-telemetry.sh" 2>/dev/null)"
  if "$PY" -c '
import json, sys
d = json.loads(sys.argv[1])
need = ["t","link","dns","socks","bridge","exit","rtt","flow","seal","wall","grip","score"]
missing = [k for k in need if k not in d]
assert not missing, "missing keys: %s" % missing
bands = [k for k in need if k not in ("t",)]
bad = [k for k in bands if not isinstance(d[k], (int, float))]
assert not bad, "non-numeric: %s" % bad
out = [k for k in bands if not (d[k] == -1.0 or 0.0 <= d[k] <= 1.0)]
assert not out, "out of range: %s" % out
assert isinstance(d.get("detail"), dict), "detail must be an object"
' "$tsout" 2>/dev/null; then
    pass "the sampler emits a valid, in-range telemetry object"
  else
    fail "the sampler emits a valid, in-range telemetry object" "got: $(printf '%s' "$tsout" | head -c 160)"
  fi
  st="$("$PY" -c 'import time;print(time.time())')"
  "$BIN/tunnel-telemetry.sh" >/dev/null 2>&1
  el="$("$PY" -c 'import sys,time;print(int((time.time()-float(sys.argv[1]))*1000))' "$st")"
  if [ "${el:-9999}" -lt 8000 ]; then
    pass "a sampling pass completes in ${el}ms (< 8s budget)"
  else
    fail "a sampling pass completes within 8s" "took ${el}ms"
  fi
fi

grep -q 'TELEMETRY_FILE' "$BIN/tunnel-lock.sh" \
  && pass "the launcher publishes telemetry" \
  || fail "the launcher publishes telemetry"
# The sampler must run in a BACKGROUNDED SUBSHELL: a pass takes ~0.5s and the
# watch loop must keep auditing the process tree every 3s regardless.
wloop="$(sed -n '/^while any_alive; do/,/^done$/p' "$BIN/tunnel-lock.sh")"
if printf '%s\n' "$wloop" | grep -q 'tunnel-telemetry.sh' \
   && printf '%s\n' "$wloop" | grep -qE '^\s*\) >/dev/null 2>&1 &\s*$'; then
  pass "telemetry sampling is detached from the watch loop"
else
  fail "telemetry sampling is detached from the watch loop" \
       "the sampler must sit inside a ( ... ) >/dev/null 2>&1 & subshell"
fi
grep -q 'TELEMETRY_LOCK' "$BIN/tunnel-lock.sh" \
  && pass "overlapping sampling passes are prevented by a lock" \
  || fail "overlapping sampling passes are prevented by a lock"

SRCD="$ROOT/app/AppTunnel/Sources"
[ -f "$SRCD/Telemetry.swift" ] \
  && pass "Telemetry.swift exists" || fail "Telemetry.swift exists"
nb="$(grep -c 'Band(key:' "$SRCD/Telemetry.swift" 2>/dev/null || echo 0)"
[ "${nb:-0}" -eq 10 ] \
  && pass "exactly ten bands are defined" \
  || fail "exactly ten bands are defined" "found $nb"
grep -q 'idleIsFine' "$SRCD/Telemetry.swift" 2>/dev/null \
  && pass "the FLOW band is marked idle-is-not-failure" \
  || fail "the FLOW band is marked idle-is-not-failure"

# The live meter is the top-left analyser unit, not the phase bars below it.
[ -f "$SRCD/Visualiser.swift" ] \
  && pass "Visualiser.swift exists" || fail "Visualiser.swift exists"
grep -q 'valley' "$SRCD/Visualiser.swift" 2>/dev/null \
  && pass "the analyser tracks a valley-hold (worst recent value)" \
  || fail "the analyser tracks a valley-hold (worst recent value)"
grep -q 'idleIsFine' "$SRCD/Visualiser.swift" 2>/dev/null \
  && pass "an idle FLOW band is not drawn as an alarm" \
  || fail "an idle FLOW band is not drawn as an alarm"
# Both axes must carry meaning: height = health, width = bandwidth.
grep -q '0.22 + 0.62 \* flow' "$SRCD/Visualiser.swift" 2>/dev/null \
  && pass "bar width morphs with throughput" \
  || fail "bar width morphs with throughput"
for want in drawRadar drawCircuit drawWaterfall; do
  grep -q "$want" "$SRCD/Visualiser.swift" 2>/dev/null \
    && pass "the analyser has $want" || fail "the analyser has $want"
done
grep -q 'modeCount = 6' "$SRCD/Visualiser.swift" 2>/dev/null \
  && pass "clicking the analyser cycles all six modes" \
  || fail "clicking the analyser cycles all six modes"
grep -q 'drawNeon' "$SRCD/Visualiser.swift" 2>/dev/null \
  && pass "the analyser has the neon wave field" \
  || fail "the analyser has the neon wave field"
grep -q 'snapshot-eq' "$SRCD/main.swift" 2>/dev/null \
  && pass "the equalizer has a deterministic render hook" \
  || fail "the equalizer has a deterministic render hook"

# =============================================== argument / guard behaviour ==
hdr "2. Guards and argument handling"

out="$("$BIN/tunnel-lock.sh" --login-user someone --self-test 2>&1)"
assert_contains "tunnel-lock refuses --login-user when not root" \
  "only valid when this script runs as root" "$out"

out="$("$BIN/tunnel-freehost.sh" 2>&1)"
assert_contains "tunnel-freehost refuses to run without root" "must run as root" "$out"

out="$("$BIN/tunnel-netrescue.sh" reset-network 2>&1)"
assert_contains "netrescue reset-network refuses without --i-understand" \
  "refusing without --i-understand" "$out"
assert_contains "netrescue reset-network offers the cheaper options first" \
  "fix-dns" "$out"

out="$("$BIN/tunnel-lock.sh" --self-test --socks-port 9 2>&1)"
assert_contains "self-test fails cleanly when SOCKS is absent" "No SOCKS5 listener on 127.0.0.1:9" "$out"
assert_contains "the failure names the port the system actually advertises" "system proxy says" "$out"
assert_not_contains "self-test does not trip bash 3.2 empty-array handling" "unbound variable" "$out"

# ============================================================ session lock ==
hdr "3. Session lock"
if [ "$LIVE_SESSION" = 1 ]; then
  skip "session lock tests (a real session is running)"
else
  note_created session.json
  "$PY" -c 'import json,os,sys;json.dump({"pid":os.getpid(),"state":"test"},open(sys.argv[1],"w"))' \
    "$STATE_DIR/session.json"
  # our python already exited, so that pid is dead -> stale, must be reclaimed
  out="$("$BIN/tunnel-lock.sh" --self-test --socks-port 9 2>&1)"
  assert_not_contains "a stale lock (dead pid) is reclaimed" "already running" "$out"
  [ -f "$STATE_DIR/session.json" ] \
    && fail "the reclaimed lock is removed on exit" \
    || pass "the reclaimed lock is removed on exit"

  # A lock owned by a live process must be respected.
  # The helper's stdout MUST be redirected: a background job that inherits the
  # script's stdout keeps the pipe open, so `selfcheck | sed` would block until
  # the sleep expired. That is what made this suite appear to hang.
  sleep 20 >/dev/null 2>&1 & live=$!
  "$PY" -c 'import json,sys;json.dump({"pid":int(sys.argv[2]),"state":"test"},open(sys.argv[1],"w"))' \
    "$STATE_DIR/session.json" "$live"
  out="$("$BIN/tunnel-lock.sh" --self-test --socks-port 9 2>&1)"
  assert_contains "a live lock blocks a second run" "already running" "$out"
  kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
  rm -f "$STATE_DIR/session.json"
fi

# ========================================================= host protection ==
hdr "4. Host protection"
out="$("$BIN/tunnel-testkit.sh" clear 2>&1)"
assert_contains "testkit clear works" "Protection cleared" "$out"

out="$("$BIN/tunnel-testkit.sh" status 2>&1)"
assert_contains "testkit reports 'not armed' when cleared" "not armed" "$out"

out="$("$BIN/tunnel-testkit.sh" protect --pid $$ 2>&1)"
assert_contains "testkit arms protection" "Protection armed" "$out"
host="$("$PY" -c 'import json,os
try: print(json.load(open(os.path.expanduser("~/.apptunnel/protected.json"))).get("host_bundle",""))
except Exception: pass' 2>/dev/null)"
case "$host" in
  /Applications/*.app|"$HOME"/Applications/*.app)
    pass "protection resolves the outermost app bundle ($host)" ;;
  "") skip "no host bundle (not running inside an app)" ;;
  *)  fail "protection resolves the outermost app bundle" "got: $host" ;;
esac

# The all-protected case must produce a clear message, not a silent abort.
if [ "$LIVE_SESSION" = 1 ] || [ -z "$host" ]; then
  skip "all-protected roster test"
else
  note_created apps.json
  "$PY" -c 'import json,sys
json.dump([{"path":sys.argv[2],"name":"Host","enabled":True}], open(sys.argv[1],"w"))' \
    "$STATE_DIR/apps.json" "$host"
  out="$("$BIN/tunnel-lock.sh" --app "$host" --yes 2>&1)"
  assert_contains "an all-protected roster explains itself" "Every roster app is the protected host" "$out"
fi
"$BIN/tunnel-testkit.sh" clear >/dev/null 2>&1

# ============================================= the .command front end ======
hdr "5. Protected-launcher front end"
SHIM="/Applications/Claude-and-ChatGPT-VeePN-Protected.command"
if [ ! -x "$SHIM" ]; then
  skip "front end not installed at $SHIM"
else
  pass "the .command front end is installed and executable"

  # It used to re-exec itself, producing four legacy launchers per run - the
  # engine of every "my Internet died" incident in this project.
  if grep -qE 'exec[[:space:]]+"?\$0|exec .*Protected\.command' "$SHIM"; then
    fail "the front end does not re-execute itself"
  else
    pass "the front end does not re-execute itself"
  fi

  # It must drive the audited engine, not the legacy DNS-blocking launchers.
  if grep -qE '^[^#]*veepn-shadowsocks-lock' "$SHIM"; then
    fail "the front end does not invoke the legacy launchers"
  else
    pass "the front end does not invoke the legacy launchers"
  fi
  grep -q 'tunnel-lock.sh' "$SHIM" \
    && pass "the front end delegates to tunnel-lock.sh" \
    || fail "the front end delegates to tunnel-lock.sh"

  # Both entry points must agree on which apps are tunnelled.
  grep -q 'apps.json' "$SHIM" \
    && pass "the front end reads the same roster as AppTunnel" \
    || fail "the front end reads the same roster as AppTunnel"

  out="$("$SHIM" --version 2>&1)"
  assert_contains "front end --version works" "Protected Launcher" "$out"
  out="$("$SHIM" --help 2>&1)"
  assert_contains "front end --help works" "Usage:" "$out"
fi

# ================================================== read-only tool sanity ===
hdr "6. Read-only tools"
out="$("$BIN/tunnel-doctor.sh" 2>&1)"
assert_contains "tunnel-doctor produces a summary" "Summary" "$out"
assert_contains "tunnel-doctor states it changed nothing" "read-only" "$out"

# macOS has no timeout(1); netrescue bounds its own probes (dig +time, nc -w).
out="$("$BIN/tunnel-netrescue.sh" diagnose 2>&1)"
assert_contains "netrescue produces a verdict" "Verdict" "$out"
assert_contains "netrescue confirms it is read-only" "read-only report" "$out"

out="$("$BIN/tunnel-dnsguard.sh" 2>&1)"
assert_contains "dnsguard reports without --fix" "machine-wide DNS-blocking anchors" "$out"
assert_not_contains "dnsguard does not flush without --fix" "flushing com.apple" "$out"

# ============================================================ the app ======
hdr "7. Application"
APP="$APPDIR/AppTunnel.app"
if [ "$QUICK" = 1 ]; then
  skip "app tests (--quick)"
elif [ ! -d "$APP" ]; then
  fail "AppTunnel.app is installed" "not found at $APP"
else
  pass "AppTunnel.app is installed"
  plutil -lint "$APP/Contents/Info.plist" >/dev/null 2>&1 \
    && pass "Info.plist is valid" || fail "Info.plist is valid"
  file "$APP/Contents/MacOS/AppTunnel" 2>/dev/null | grep -q 'Mach-O' \
    && pass "the binary is Mach-O" || fail "the binary is Mach-O"

  # There are two bundles: the build output under tunnel/app/ and the one the
  # README tells you to double-click at the project root. build.sh used to
  # produce only the first, so they drifted weeks apart - every fix landed in a
  # bundle nobody opened while the root copy stayed frozen, which is exactly how
  # the app came to look unfixable.
  BUILT="$ROOT/app/AppTunnel.app/Contents/MacOS/AppTunnel"
  if [ ! -f "$BUILT" ]; then
    skip "the installed app matches the build output (nothing built yet)"
  elif cmp -s "$BUILT" "$APP/Contents/MacOS/AppTunnel"; then
    pass "the installed app matches the build output"
  else
    fail "the installed app matches the build output" \
         "$APP is stale - re-run app/build.sh, which now installs it"
  fi
  grep -q 'ditto "$APP" "$INSTALLED"' "$ROOT/app/build.sh" \
    && pass "build.sh installs the bundle the user actually opens" \
    || fail "build.sh installs the bundle the user actually opens"

  grep -q 'tell application "Terminal"' "$ROOT/app/AppTunnel/Sources/main.swift" \
    && fail "the app never opens Terminal" || pass "the app never opens Terminal"
  grep -q 'with administrator privileges' "$ROOT/app/AppTunnel/Sources/main.swift" \
    && pass "the app elevates via the macOS authorisation dialog" \
    || fail "the app elevates via the macOS authorisation dialog"
  grep -q 'tunnel-doctor.sh")).*\n.*--login-user\|--login-user " + Runner.q(NSUserName())' \
       "$ROOT/app/AppTunnel/Sources/main.swift" \
    && pass "the app tells root-run helpers which login user to act for" \
    || fail "the app tells root-run helpers which login user to act for"

  # ---- Sonoma compatibility -------------------------------------------------
  # The windows are borderless and drawn by hand, so the app shipped with no
  # NSMainMenu at all. Without one macOS has no key-equivalent table: Command-Q
  # did nothing, and the only way out was the painted X.
  # Bounded: a binary that predates --dump-menu does not recognise the flag and
  # just opens its window, holding the command substitution open forever. macOS
  # ships no timeout(1), so the wait is done by hand.
  menu_out="$SANDBOX/menu.txt"
  "$APP/Contents/MacOS/AppTunnel" --dump-menu >"$menu_out" 2>/dev/null &
  menu_pid=$!
  waited=0
  while [ "$waited" -lt 15 ] && kill -0 "$menu_pid" 2>/dev/null; do
    sleep 1; waited=$((waited+1))
  done
  kill -0 "$menu_pid" 2>/dev/null && kill "$menu_pid" 2>/dev/null
  wait "$menu_pid" 2>/dev/null
  menu="$(cat "$menu_out" 2>/dev/null)"
  if [ -z "$menu" ]; then
    fail "the app installs a main menu (Command-Q works)" \
         "--dump-menu produced nothing - the bundled binary predates the fix, rebuild with app/build.sh"
  else
    assert_contains "Command-Q is bound to terminate:" "cmd+q	terminate:" "$menu"
    assert_contains "Command-W is bound to performClose:" "cmd+w	performClose:" "$menu"
    assert_contains "Command-M is bound to performMiniaturize:" "cmd+m	performMiniaturize:" "$menu"
  fi

  # macOS 14 made the "ignoring" half of activate(ignoringOtherApps:) a no-op
  # for apps not started by a user gesture - which is exactly how the launcher
  # starts this one - so the window was created but stayed behind everything.
  grep -q 'orderFrontRegardless' "$ROOT/app/AppTunnel/Sources/main.swift" \
    && pass "the window is raised with orderFrontRegardless (Sonoma activation)" \
    || fail "the window is raised with orderFrontRegardless (Sonoma activation)" \
            "activate(ignoringOtherApps:) alone leaves the window behind other apps on macOS 14+"
  grep -q 'applicationSupportsSecureRestorableState' "$ROOT/app/AppTunnel/Sources/main.swift" \
    && pass "secure restorable state is answered (no Sonoma launch warning)" \
    || fail "secure restorable state is answered (no Sonoma launch warning)"

  # A binary pinned to one architecture needs Rosetta on the other, and Rosetta
  # is not installed by default - the app simply refuses to open there.
  # file(1), not lipo(1): lipo is an xcrun stub that dies when the Command Line
  # Tools are missing, which reported every binary as "unknown".
  hostarch="$(uname -m)"
  archs="$(file "$APP/Contents/MacOS/AppTunnel" 2>/dev/null)"
  case "$archs" in
    *"$hostarch"*) pass "the binary contains this Mac's architecture ($hostarch)" ;;
    *) fail "the binary contains this Mac's architecture" \
            "host is $hostarch; file(1) says: ${archs:-unknown}" ;;
  esac
  if grep -q 'for arch in .*arm64' "$ROOT/app/build.sh" \
     && grep -q 'for arch in .*x86_64' "$ROOT/app/build.sh" \
     && grep -q 'lipo -create' "$ROOT/app/build.sh"; then
    pass "build.sh builds a universal binary"
  else
    fail "build.sh builds a universal binary" \
         "a single -target produces a binary that needs Rosetta on the other architecture"
  fi

  # Render tests. A view that fails to lay out produces a nearly blank PNG,
  # which compresses far smaller than one containing text - that is exactly how
  # the "stark black screen" log window failed.
  render() {  # render <flag> <outfile> <min-bytes> <label>
    local out="$SANDBOX/$2"
    "$APP/Contents/MacOS/AppTunnel" "$1" "$out" >/dev/null 2>&1
    if [ ! -s "$out" ]; then fail "$4" "no image produced"; return; fi
    local sz; sz="$(wc -c < "$out" | tr -d ' ')"
    if [ "$sz" -lt "$3" ]; then
      fail "$4" "image is only ${sz} bytes - it probably rendered blank"
    else
      pass "$4 (${sz} bytes)"
    fi
  }
  render --snapshot     main.png 20000 "the main window renders content"
  render --snapshot-log log.png  15000 "the log window renders text (not a blank black panel)"
fi

# ================================================== suite's own hygiene =====
hdr "8. The suite's own hygiene"
grep -q '\.existed' "$BIN/tunnel-selfcheck.sh" \
  && pass "the suite records which state files pre-existed" \
  || fail "the suite records which state files pre-existed"
grep -q 'only remove what WE made' "$BIN/tunnel-selfcheck.sh" \
  && pass "the suite only deletes state files it created itself" \
  || fail "the suite only deletes state files it created itself"
# An earlier version removed each file unconditionally and destroyed the roster.
if [ -f "$SANDBOX/backup/apps.json.existed" ]; then
  [ -f "$STATE_DIR/apps.json" ] \
    && pass "the roster survived this run" \
    || fail "the roster survived this run" "apps.json existed at start and is now gone"
else
  skip "roster survival (no roster existed at start)"
fi

# ================================================================ summary ===
hdr "Summary"
printf '   %s%d passed%s, %s%d failed%s, %s%d skipped%s\n' \
  "$G" "$PASS" "$O" "$([ "$FAIL" -gt 0 ] && echo "$R" || echo "$D")" "$FAIL" "$O" "$D" "$SKIP" "$O"
if [ "$FAIL" -eq 0 ]; then
  printf '\n   %sAll checks passed. Nothing was launched, quit, or left behind.%s\n\n' "$G" "$O"
else
  printf '\n   %s%d regression(s). Fix before shipping.%s\n\n' "$R" "$FAIL" "$O"
fi
exit "$FAIL"
