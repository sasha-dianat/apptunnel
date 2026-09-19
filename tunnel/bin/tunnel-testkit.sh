#!/bin/bash
# tunnel-testkit.sh — make the tunnel safe to test from inside a tunnelled app.
#
# The problem this solves:
#   Claude Desktop (or ChatGPT/Cursor) can itself be one of the apps under the
#   tunnel. An agent running inside that app — Claude Code, for instance — is a
#   descendant of the very launcher that a connect/repair operation stops. The
#   moment the launcher is signalled, the app dies and the session running the
#   test dies with it. From the caller's side that looks like "request failed".
#
#   This records the host app's entire process ancestry as PROTECTED.
#   tunnel-connect.sh and tunnel-lock.sh then refuse to signal those pids and
#   skip the host app instead of quitting it, so a test can run end to end
#   without cutting the branch it is sitting on.
#
# Usage:
#   tunnel-testkit.sh protect [--pid N]   record host ancestry (default: $PPID)
#   tunnel-testkit.sh status              show what is currently protected
#   tunnel-testkit.sh preview             what a connect WOULD stop, and what it will skip
#   tunnel-testkit.sh selftest            run tunnel-lock --self-test (launches nothing)
#   tunnel-testkit.sh clear               drop protection (normal behaviour resumes)
#
# Protection is advisory and local: it only affects this project's scripts.

set -uo pipefail

# The system python3 at /usr/bin is a Command Line Tools stub: it exists and is
# executable even when the Tools are not installed, and then every call dies
# with "invalid active developer path". This resolves one that actually runs.
. "$(cd "$(dirname "$0")" && pwd)/tunnel-python.sh"

BIN="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$HOME/.apptunnel"
GUARD="$STATE_DIR/protected.json"
mkdir -p "$STATE_DIR"

C=$'\033[36m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; O=$'\033[0m'
hdr() { printf '\n%s== %s ==%s\n' "$C" "$1" "$O"; }
ok()  { printf '   %sok%s   %s\n' "$G" "$O" "$1"; }
warn(){ printf '   %s!!%s   %s\n' "$Y" "$O" "$1"; }
bad() { printf '   %sXX%s   %s\n' "$R" "$O" "$1"; }
inf() { printf '        %s\n' "$1"; }

# Walk parents to pid 1, collecting the chain and the owning .app bundle.
ancestry() {
  local p="$1" i=0
  while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ] && [ "$i" -lt 40 ]; do
    echo "$p"
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    i=$((i + 1))
  done
}

# Return the OUTERMOST app bundle in the ancestry, preferring one under
# /Applications. Taking the first match finds nested helper bundles such as
# .../claude-code/<ver>/claude.app, which is not the app the roster names.
host_bundle_of() {
  local p cmd b best="" fallback=""
  for p in $(ancestry "$1"); do
    cmd="$(ps -o command= -p "$p" 2>/dev/null)"
    case "$cmd" in
      */Contents/MacOS/*|*/Contents/Helpers/*|*/Contents/Frameworks/*)
        b="$(printf '%s' "$cmd" | sed -e 's|/Contents/.*||' -e 's/^ *//')"
        case "$b" in
          /Applications/*.app|"$HOME"/Applications/*.app) best="$b" ;;
          *.app) [ -z "$fallback" ] && fallback="$b" ;;
        esac ;;
    esac
  done
  if [ -n "$best" ]; then printf '%s\n' "$best"; return 0; fi
  if [ -n "$fallback" ]; then printf '%s\n' "$fallback"; return 0; fi
  return 1
}

cmd_protect() {
  local pid="${1:-$PPID}"
  local chain bundle
  chain="$(ancestry "$pid" | tr '\n' ' ')"
  bundle="$(host_bundle_of "$pid" || true)"

  # Everything the host app spawned counts too (helpers, renderers).
  local extra=""
  if [ -n "$bundle" ]; then
    extra="$(ps -axo pid=,command= | awk -v b="$bundle/Contents/" 'index($0,b){print $1}' | tr '\n' ' ')"
  fi

  "$PY" -c '
import json, os, sys, time
guard, bundle = sys.argv[1], sys.argv[2]
pids = sorted({int(x) for x in (sys.argv[3] + " " + sys.argv[4]).split() if x.isdigit()})
json.dump({"host_bundle": bundle, "pids": pids, "created": time.time()},
          open(guard, "w"), indent=2)
print(len(pids))
' "$GUARD" "${bundle:-}" "$chain" "$extra" >/dev/null

  hdr "Protection armed"
  [ -n "$bundle" ] && ok "host app: $bundle" || warn "no .app bundle found in the ancestry"
  ok "protected pids: $(echo "$chain $extra" | tr ' ' '\n' | awk 'NF&&!s[$0]++' | tr '\n' ' ')"
  inf "written to $GUARD"
  echo
  inf "${D}connect/repair will now skip these, and will not launch the host app.${O}"
  inf "${D}run 'tunnel-testkit.sh clear' to restore normal behaviour.${O}"
}

cmd_status() {
  hdr "Protection status"
  if [ ! -f "$GUARD" ]; then ok "not armed — normal behaviour"; return 0; fi
  local bundle pids p alive=0 total=0
  bundle="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("host_bundle") or "")' "$GUARD")"
  pids="$("$PY" -c 'import json,sys;print(" ".join(str(p) for p in json.load(open(sys.argv[1])).get("pids",[])))' "$GUARD")"
  ok "host bundle: ${bundle:-none}"
  for p in $pids; do
    total=$((total + 1))
    ps -p "$p" >/dev/null 2>&1 && alive=$((alive + 1))
  done
  ok "$alive of $total protected pids still alive"
  inf "pids: $pids"
}

cmd_clear() {
  rm -f "$GUARD"
  hdr "Protection cleared"
  ok "normal behaviour restored — connect will stop and relaunch every roster app"
}

is_protected() {   # is_protected PID
  [ -f "$GUARD" ] || return 1
  "$PY" -c '
import json, sys
try: g = json.load(open(sys.argv[1]))
except Exception: sys.exit(1)
sys.exit(0 if int(sys.argv[2]) in set(g.get("pids", [])) else 1)
' "$GUARD" "$1"
}

cmd_preview() {
  hdr "What a connect would stop"
  local found=0 skipped=0
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    found=$((found + 1))
    local cmd; cmd="$(ps -o command= -p "$pid" 2>/dev/null | cut -c1-88)"
    if is_protected "$pid"; then
      warn "SKIP  pid=$pid  $cmd"
      skipped=$((skipped + 1))
    else
      printf '   %sstop%s pid=%s  %s\n' "$R" "$O" "$pid" "$cmd"
    fi
  done < <(ps -axo pid=,command= \
            | awk '/Claude-and-ChatGPT-VeePN-Protected|veepn-shadowsocks-lock/ && !/awk/ && $0 !~ /sh -c/ && !/testkit/ {print $1}')
  [ "$found" -eq 0 ] && ok "nothing to stop"
  echo
  hdr "Roster"
  local bundle; bundle="$( [ -f "$GUARD" ] && "$PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("host_bundle") or "")' "$GUARD" || echo "")"
  "$PY" -c '
import json, os, sys
b = sys.argv[2]
try: r = json.load(open(sys.argv[1]))
except Exception: r = []
for a in r:
    if not a.get("enabled"): continue
    mark = "SKIP (protected host)" if b and os.path.realpath(a["path"]) == os.path.realpath(b) else "launch"
    print("   %-22s %s" % (mark, a["path"]))
' "$STATE_DIR/apps.json" "$bundle" 2>/dev/null || inf "(no roster)"
  echo
  [ "$skipped" -gt 0 ] && ok "$skipped protected process(es) will be left alone — your session survives" \
                       || warn "nothing protected: a connect WILL stop the app hosting this session"
}

cmd_selftest() {
  hdr "Self-test (no app is launched or quit)"
  inf "this exercises phases 1-9 and tears everything down"
  echo
  if [ "$(id -u)" -eq 0 ]; then
    "$BIN/tunnel-lock.sh" --self-test --login-user "${SUDO_USER:?run as your login user, not root}"
  else
    "$BIN/tunnel-lock.sh" --self-test
  fi
}

case "${1:-status}" in
  protect)
    shift
    pid="$PPID"
    [ "${1:-}" = "--pid" ] && pid="${2:-$PPID}"
    cmd_protect "$pid" ;;
  status)   cmd_status ;;
  preview)  cmd_preview ;;
  selftest) cmd_selftest ;;
  clear)    cmd_clear ;;
  is-protected) shift; is_protected "${1:-0}" ;;
  -h|--help|help) sed -n '2,26p' "$0" ;;
  *) echo "unknown command: $1" >&2; sed -n '17,25p' "$0" >&2; exit 2 ;;
esac
