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
  pid="$(/usr/bin/python3 -c 'import json,sys
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
    auid="$(/usr/bin/python3 -c '
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
  if /usr/bin/python3 -c '
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
  st="$(/usr/bin/python3 -c 'import time;print(time.time())')"
  "$BIN/tunnel-telemetry.sh" >/dev/null 2>&1
  el="$(/usr/bin/python3 -c 'import sys,time;print(int((time.time()-float(sys.argv[1]))*1000))' "$st")"
  if [ "${el:-9999}" -lt 8000 ]; then
    pass "a sampling pass completes in ${el}ms (< 8s budget)"
  else
    fail "a sampling pass completes within 8s" "took ${el}ms"
  fi
fi

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
  /usr/bin/python3 -c 'import json,os,sys;json.dump({"pid":os.getpid(),"state":"test"},open(sys.argv[1],"w"))' \
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
  /usr/bin/python3 -c 'import json,sys;json.dump({"pid":int(sys.argv[2]),"state":"test"},open(sys.argv[1],"w"))' \
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
host="$(/usr/bin/python3 -c 'import json,os
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
  /usr/bin/python3 -c 'import json,sys
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

  grep -q 'tell application "Terminal"' "$ROOT/app/AppTunnel/Sources/main.swift" \
    && fail "the app never opens Terminal" || pass "the app never opens Terminal"
  grep -q 'with administrator privileges' "$ROOT/app/AppTunnel/Sources/main.swift" \
    && pass "the app elevates via the macOS authorisation dialog" \
    || fail "the app elevates via the macOS authorisation dialog"
  grep -q 'tunnel-doctor.sh")).*\n.*--login-user\|--login-user " + Runner.q(NSUserName())' \
       "$ROOT/app/AppTunnel/Sources/main.swift" \
    && pass "the app tells root-run helpers which login user to act for" \
    || fail "the app tells root-run helpers which login user to act for"

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
