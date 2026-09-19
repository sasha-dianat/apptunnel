#!/bin/bash
# tunnel-migrate.sh — retire the legacy launcher sessions and restart the apps
# under the new GUI-managed tunnel.
#
# Run this from Terminal, NOT from inside Claude. It quits Claude Desktop, so
# anything running inside Claude dies partway through. Terminal.app is a
# separate process tree, so this script survives that.
#
# Sequence:
#   1. stop the supervisor(s) first, so they cannot respawn launchers
#   2. stop the legacy launchers, giving each a chance to run its own cleanup
#   3. quit Claude and ChatGPT
#   4. tunnel-doctor  --fix   (groups, bridges, stale proxy config)
#   5. tunnel-dnsguard --fix  (machine-wide DNS blocks)
#   6. verify connectivity
#   7. open the GUI, then start the tunnel for the enabled roster apps

set -uo pipefail

# The system python3 at /usr/bin is a Command Line Tools stub: it exists and is
# executable even when the Tools are not installed, and then every call dies
# with "invalid active developer path". This resolves one that actually runs.
. "$(cd "$(dirname "$0")" && pwd)/tunnel-python.sh"

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$BIN")"
APPDIR="$(dirname "$ROOT")"
GUI_CMD="$APPDIR/AppTunnel.app"
LOCK="$BIN/tunnel-lock.sh"
ROSTER="$HOME/.apptunnel/apps.json"

say() { printf '\n\033[36m== %s ==\033[0m\n' "$*"; }
ok()  { printf '   \033[32mok\033[0m   %s\n' "$*"; }
no()  { printf '   \033[31mXX\033[0m   %s\n' "$*"; }
inf() { printf '        %s\n' "$*"; }

alive() { [ -n "${1:-}" ] && ps -p "$1" >/dev/null 2>&1; }

# pgrep under a sandboxed shell silently omits processes in the caller's own
# process group, which would leave half the legacy tree running. ps sees all.
find_pids() { ps -axo pid=,command= | awk -v re="$1" '$0 ~ re && $0 !~ /awk/ && $0 !~ /sh -c/ {print $1}'; }

stop_pids() {   # stop_pids "label" pid...
  local label="$1"; shift
  local p
  [ "$#" -eq 0 ] && { ok "no $label to stop"; return 0; }
  for p in "$@"; do
    alive "$p" || continue
    inf "TERM $label pid $p"
    kill -TERM "$p" 2>/dev/null
  done
  local i=0
  while [ $i -lt 60 ]; do
    local left=0
    for p in "$@"; do alive "$p" && left=$((left+1)); done
    [ "$left" -eq 0 ] && { ok "all $label stopped"; return 0; }
    sleep 0.5; i=$((i+1))
  done
  for p in "$@"; do
    alive "$p" && { inf "KILL $label pid $p (did not exit)"; kill -KILL "$p" 2>/dev/null; }
  done
  ok "$label stopped (some force-killed)"
}

printf '\033[36m\n  apptunnel migration — legacy sessions -> GUI-managed tunnel\033[0m\n'
cat <<'WARN'

  This will QUIT Claude Desktop and ChatGPT.
  Any Claude Code conversation running inside Claude Desktop will end.
  Unsaved work in those apps should be saved now.

  Press Ctrl-C to cancel.
WARN
for n in 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1; do
  printf '\r  starting in %2ds ... ' "$n"; sleep 1
done
printf '\r  starting now.        \n'

say "Administrator rights"
sudo -v || { no "sudo failed, aborting"; exit 1; }
( while true; do sudo -n -v >/dev/null 2>&1 || exit 0; sleep 30; done ) &
KEEPALIVE=$!
trap 'kill "$KEEPALIVE" 2>/dev/null' EXIT
ok "acquired, keepalive running"

say "1. Stopping supervisor(s) so nothing respawns"
# shellcheck disable=SC2046
stop_pids "supervisor" $(find_pids 'Claude-and-ChatGPT-VeePN-Protected')

say "2. Stopping legacy launchers (deepest first, so cleanup can run)"
mapfile_pids="$(find_pids 'veepn-shadowsocks-lock' | sort -rn)"
# shellcheck disable=SC2086
stop_pids "launcher" $mapfile_pids

say "3. Quitting Claude and ChatGPT"
for app in Claude ChatGPT; do
  /usr/bin/osascript -e "tell application \"$app\" to quit" >/dev/null 2>&1 && inf "asked $app to quit"
done
i=0
while [ $i -lt 40 ]; do
  remaining="$(find_pids '/(Claude|ChatGPT)[.]app/Contents/MacOS/' | wc -l | tr -d ' ')"
  [ "$remaining" = "0" ] && break
  sleep 0.5; i=$((i+1))
done
remaining="$(find_pids '/(Claude|ChatGPT)[.]app/Contents/MacOS/')"
if [ -n "$remaining" ]; then
  inf "force-quitting stragglers: $(echo "$remaining" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  kill -KILL $remaining 2>/dev/null
  sleep 1
fi
ok "apps are down"

say "4. tunnel-doctor --fix"
"$BIN/tunnel-doctor.sh" --fix 2>&1 | sed 's/^/   /'

say "5. tunnel-dnsguard --fix"
"$BIN/tunnel-dnsguard.sh" --fix 2>&1 | grep -vE '^      block drop' | sed 's/^/   /'

say "6. Connectivity check"
dnsres="$(dig +time=4 +tries=1 +short www.wikipedia.org 2>/dev/null | head -1)"
[ -n "$dnsres" ] && ok "DNS resolves ($dnsres)" || no "DNS is NOT resolving"
nc -z -w 3 1.1.1.1 443 >/dev/null 2>&1 && ok "direct TCP works" || no "direct TCP failed"
if [ -z "$dnsres" ]; then
  no "Network is not healthy - stopping before starting a new tunnel."
  no "Run: sudo pfctl -F all     then re-check."
  exit 1
fi

say "7. Opening the GUI"
if [ -e "$GUI_CMD" ]; then
  open "$GUI_CMD" && ok "GUI launching (watch the phase animation)"
else
  no "AppTunnel.app not found at $GUI_CMD"
fi
sleep 4

say "8. Starting the tunnel"
APPS=()
if [ -f "$ROSTER" ]; then
  while IFS= read -r p; do [ -n "$p" ] && APPS+=(--app "$p"); done < <(
    "$PY" -c '
import json,sys
try:
    for a in json.load(open(sys.argv[1])):
        if a.get("enabled") and a.get("path"): print(a["path"])
except Exception: pass' "$ROSTER")
fi
if [ "${#APPS[@]}" -eq 0 ]; then
  [ -d /Applications/Claude.app ]  && APPS+=(--app /Applications/Claude.app)
  [ -d /Applications/ChatGPT.app ] && APPS+=(--app /Applications/ChatGPT.app)
fi
if [ "${#APPS[@]}" -eq 0 ]; then
  no "No apps to launch - roster is empty and neither Claude.app nor ChatGPT.app was found."
  no "Add apps in the GUI, then press the play button there."
  exit 1
fi
inf "roster: ${APPS[*]}"
echo
echo "   Keep THIS window open - it is the tunnel session."
echo "   Quit the apps to end it; everything is restored automatically."
echo
exec "$LOCK" "${APPS[@]}" --yes
