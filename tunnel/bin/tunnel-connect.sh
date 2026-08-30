#!/bin/bash
# tunnel-connect.sh — root entry point used by AppTunnel's play button.
#
# Runs as root (via the macOS authorisation dialog), with no Terminal.
# Retires any legacy VeePN launcher still running, then hands off to
# tunnel-lock.sh, which does the real work.
#
# Why this exists: /Applications/Claude-and-ChatGPT-VeePN-Protected.command
# re-executes itself, so one invocation leaves several v1.1/v5.4 launchers
# running. Each installs its own PF anchor and isolation group, and the v1.1
# one blocks DNS machine-wide. Starting a new tunnel on top of that produces
# exactly the "not in the isolation group" confusion, because the apps are
# already inside somebody else's group.

set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LOGIN_USER=""
APPS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --login-user) LOGIN_USER="${2:-}"; shift 2 ;;
    --app)        APPS+=(--app "${2:-}"); shift 2 ;;
    *)            shift ;;
  esac
done

[ -n "$LOGIN_USER" ] || { echo "tunnel-connect: --login-user is required" >&2; exit 2; }
[ "${#APPS[@]}" -gt 0 ] || { echo "tunnel-connect: no --app given" >&2; exit 2; }

stamp() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

# pgrep omits processes in the caller's own group under some sandboxes; ps does not.
find_pids() {
  ps -axo pid=,command= \
    | awk -v re="$1" '$0 ~ re && $0 !~ /awk/ && $0 !~ /sh -c/ && $0 !~ /tunnel-connect/ {print $1}'
}

LEGACY='Claude-and-ChatGPT-VeePN-Protected|veepn-shadowsocks-lock'

# Test protection: tunnel-testkit.sh can record the process ancestry of the app
# hosting whoever is driving us (e.g. Claude Code running inside Claude
# Desktop). Signalling those pids would kill the session running the test, so
# they are filtered out of every kill list below.
LOGIN_HOME="$(/usr/bin/dscl . -read "/Users/$LOGIN_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
GUARD="$LOGIN_HOME/.apptunnel/protected.json"

protected_pids() {
  [ -f "$GUARD" ] || return 0
  /usr/bin/python3 -c '
import json, sys
try: print(" ".join(str(p) for p in json.load(open(sys.argv[1])).get("pids", [])))
except Exception: pass
' "$GUARD" 2>/dev/null
}

drop_protected() {   # reads pids on stdin, prints ONLY the ones safe to signal
  local guarded; guarded=" $(protected_pids) "
  local p
  while IFS= read -r p; do
    # Only bare pids may reach stdout: this function's stdout IS the kill list.
    case "$p" in ''|*[!0-9]*) continue ;; esac
    case "$guarded" in
      # Diagnostics MUST go to stderr. Logging to stdout here put the protected
      # pid straight back into the kill list and killed the session we were
      # trying to protect.
      *" $p "*) stamp "  protecting pid $p (hosts the session driving this run)" >&2 ;;
      *) echo "$p" ;;
    esac
  done
}

# Defence in depth: strip anything that is not a bare pid.
only_pids() { awk '/^[0-9]+$/{print}'; }

stamp "checking for legacy launcher sessions"
# Supervisors first, so they cannot respawn the launchers we are about to stop.
for pattern in 'Claude-and-ChatGPT-VeePN-Protected' 'veepn-shadowsocks-lock'; do
  pids="$(find_pids "$pattern" | drop_protected | only_pids)"
  if [ -n "$pids" ]; then
    stamp "stopping $(echo "$pids" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null
  fi
done

i=0
while [ "$i" -lt 60 ]; do
  left="$(find_pids "$LEGACY" | drop_protected | only_pids)"
  [ -z "$left" ] && break
  sleep 0.5
  i=$((i + 1))
done

left="$(find_pids "$LEGACY" | drop_protected | only_pids)"
if [ -n "$left" ]; then
  stamp "force-stopping $(echo "$left" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  kill -KILL $left 2>/dev/null
  sleep 1
fi
stamp "legacy sessions retired"

# Their cleanup may not have completed; make sure no machine-wide DNS block is
# left armed before we build a new tunnel on top.
for a in $(pfctl -a com.apple -s Anchors 2>/dev/null); do
  name="com.apple/$(basename "$a")"
  case "$name" in *apptunnel-*) continue ;; esac
  if pfctl -a "$name" -s rules 2>/dev/null | grep -E 'port = (53|853)' | grep -qv 'group'; then
    stamp "disarming machine-wide DNS block left in $name"
    pfctl -a "$name" -F rules >/dev/null 2>&1 || true
  fi
done

stamp "handing off to tunnel-lock.sh"
exec "$BIN/tunnel-lock.sh" --login-user "$LOGIN_USER" ${APPS[@]+"${APPS[@]}"} --yes
