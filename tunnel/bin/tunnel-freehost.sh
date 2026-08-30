#!/bin/bash
# tunnel-freehost.sh — get an app OUT of every tunnel and back to normal
# networking, then relaunch it clean.
#
# Why you need this:
#   If the app you work in (Claude Desktop, say) is itself inside a tunnel, and
#   that tunnel's firewall rules are enforcing, the app can only reach the
#   Internet through the launcher's proxy. When that proxy is stale or the
#   launcher is a legacy one, the app appears to work but its network requests
#   fail intermittently — "request failed", dropped sessions, hangs.
#
#   Note the trap: the OLD v1.1/v5.4 launchers were never enforcing while the pf
#   main ruleset lacked `anchor "com.apple/*"`. Repairing that ruleset (which
#   tunnel-lock.sh now does automatically) makes those old anchors live for the
#   first time — so an app that seemed fine suddenly gets firewalled by a
#   launcher started hours ago.
#
# This stops every launcher, removes their firewall rules and temporary groups,
# clears stale proxy config, and relaunches the app with ordinary networking.
#
# Usage (needs admin):
#   sudo tunnel-freehost.sh [--app /Applications/Claude.app] [--no-relaunch]
#
# It WILL quit the named app. Run it from Terminal, or let AppTunnel run it.

set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/Claude.app"
RELAUNCH=1
LOGIN_USER="${SUDO_USER:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)          APP="${2:-}"; shift 2 ;;
    --no-relaunch)  RELAUNCH=0; shift ;;
    --login-user)   LOGIN_USER="${2:-}"; shift 2 ;;
    -h|--help)      sed -n '2,28p' "$0"; exit 0 ;;
    *)              shift ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "tunnel-freehost: must run as root (use sudo)" >&2; exit 1; }
if [ -z "$LOGIN_USER" ] || [ "$LOGIN_USER" = root ]; then
  echo "tunnel-freehost: could not determine the login user; pass --login-user <name>" >&2; exit 2
fi

LOGIN_HOME="$(/usr/bin/dscl . -read "/Users/$LOGIN_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
STATE_DIR="$LOGIN_HOME/.apptunnel"

C=$'\033[36m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; O=$'\033[0m'
hdr() { printf '\n%s== %s ==%s\n' "$C" "$1" "$O"; }
ok()  { printf '   %sok%s   %s\n' "$G" "$O" "$1"; }
warn(){ printf '   %s!!%s   %s\n' "$Y" "$O" "$1"; }
bad() { printf '   %sXX%s   %s\n' "$R" "$O" "$1"; }
act() { printf '        %s\n' "$1"; }

find_pids() {
  ps -axo pid=,command= \
    | awk -v re="$1" '$0 ~ re && $0 !~ /awk/ && $0 !~ /sh -c/ && $0 !~ /freehost/ {print $1}' \
    | awk '/^[0-9]+$/{print}'
}

hdr "1. Stopping every tunnel launcher"
# Deliberately no protection here: freeing the host is the whole point, and the
# host's own launcher is exactly what has to go.
for pattern in 'Claude-and-ChatGPT-VeePN-Protected' 'veepn-shadowsocks-lock' 'tunnel-lock.sh' 'tunnel-connect.sh'; do
  pids="$(find_pids "$pattern")"
  [ -z "$pids" ] && continue
  act "TERM $pattern: $(echo "$pids" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null
done
sleep 4
for pattern in 'Claude-and-ChatGPT-VeePN-Protected' 'veepn-shadowsocks-lock' 'tunnel-lock.sh'; do
  pids="$(find_pids "$pattern")"
  [ -z "$pids" ] && continue
  act "KILL leftovers: $(echo "$pids" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  kill -KILL $pids 2>/dev/null
done
ok "launchers stopped"

hdr "2. Removing their firewall rules"
n=0
for a in $(pfctl -a com.apple -s Anchors 2>/dev/null); do
  name="com.apple/$(basename "$a")"
  case "$name" in
    *apptunnel-*|*cldesktop-vpn*|*chatgpt-codex-vpn*)
      rules="$(pfctl -a "$name" -s rules 2>/dev/null | wc -l | tr -d ' ')"
      [ "${rules:-0}" -eq 0 ] && continue
      act "flushing $name ($rules rules)"
      pfctl -a "$name" -F rules >/dev/null 2>&1 && n=$((n + 1)) ;;
  esac
done
ok "$n anchor(s) flushed"

hdr "3. Removing temporary isolation groups"
n=0
for g in $(dscl . -list /Groups PrimaryGroupID 2>/dev/null | awk '$2>=57000 && $2<58000{print $1}'); do
  case "$g" in apptun*|cldesk*|cgptvpn*) ;; *) continue ;; esac
  act "removing $g"
  /usr/sbin/dseditgroup -o edit -d "$LOGIN_USER" -t user "$g" >/dev/null 2>&1
  /usr/sbin/dseditgroup -o delete "$g" >/dev/null 2>&1 && n=$((n + 1))
done
ok "$n group(s) removed"

hdr "4. Clearing stale proxy configuration"
for f in "$LOGIN_HOME/.claude/settings.json" "$LOGIN_HOME/.codex/.env"; do
  [ -f "$f" ] || continue
  case "$f" in
    *settings.json)
      /usr/bin/python3 - "$f" <<'PY' && act "cleaned $(basename "$f")"
import json, shutil, sys
p = sys.argv[1]
try: d = json.load(open(p))
except Exception: raise SystemExit(1)
e = d.get("env", {})
before = len(e)
for k in ("HTTP_PROXY","HTTPS_PROXY","http_proxy","https_proxy","NO_PROXY","no_proxy"):
    e.pop(k, None)
if before != len(e):
    shutil.copy2(p, p + ".bak")
    if not e: d.pop("env", None)
    json.dump(d, open(p, "w"), indent=2); open(p, "a").write("\n")
PY
      ;;
    *.env)
      /usr/bin/python3 - "$f" <<'PY' && act "cleaned $(basename "$f")"
import re, shutil, sys
p = sys.argv[1]
keys = {"HTTP_PROXY","HTTPS_PROXY","http_proxy","https_proxy","NO_PROXY","no_proxy","ALL_PROXY","all_proxy"}
pat = re.compile(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=')
lines = open(p, encoding="utf-8").readlines()
out = [l for l in lines
       if not (l.startswith("# Temporary VeePN") or l.startswith("# apptunnel")
               or (pat.match(l) and pat.match(l).group(1) in keys))]
if out != lines:
    shutil.copy2(p, p + ".bak")
    while out and not out[0].strip(): out.pop(0)
    open(p, "w", encoding="utf-8").writelines(out)
PY
      ;;
  esac
done
chown "$LOGIN_USER" "$LOGIN_HOME/.claude/settings.json" "$LOGIN_HOME/.codex/.env" 2>/dev/null || true
rm -f "$STATE_DIR/session.json" "$STATE_DIR/stop" 2>/dev/null || true
ok "proxy overrides removed (backups kept as .bak)"

hdr "5. Quitting the app"
NAME="$(basename "$APP" .app)"
su - "$LOGIN_USER" -c "/usr/bin/osascript -e 'tell application \"$NAME\" to quit'" >/dev/null 2>&1
i=0
while [ "$i" -lt 30 ]; do
  [ -z "$(find_pids "$(printf '%s' "$APP" | sed 's/[].[^$*\\/]/\\&/g')/Contents/MacOS/")" ] && break
  sleep 0.5; i=$((i + 1))
done
left="$(find_pids "$(printf '%s' "$APP" | sed 's/[].[^$*\\/]/\\&/g')/Contents/MacOS/")"
if [ -n "$left" ]; then
  act "force-quitting $(echo "$left" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  kill -KILL $left 2>/dev/null
fi
ok "$NAME is down"

# `nc -z -w N` does NOT reliably cap a connection that PF silently drops, so a
# probe from inside a guarded group hangs — precisely when this tool is needed.
# Python enforces a hard timeout.
tcp_probe() {  # tcp_probe HOST PORT [SECONDS]
  /usr/bin/python3 -c '
import socket, sys
s = socket.socket(); s.settimeout(float(sys.argv[3]) if len(sys.argv) > 3 else 2.0)
try:
    s.connect((sys.argv[1], int(sys.argv[2]))); sys.exit(0)
except Exception:
    sys.exit(1)
finally:
    s.close()
' "$1" "$2" "${3:-2}"
}

hdr "6. Verifying normal networking"
sleep 1
dig +time=3 +tries=1 +short www.wikipedia.org @1.1.1.1 >/dev/null 2>&1 && ok "DNS resolves" || bad "DNS still failing"
if tcp_probe 1.1.1.1 443 4; then
  ok "direct TCP works — nothing is firewalling this Mac any more"
else
  bad "direct TCP still blocked"
  act "run: $BIN/tunnel-netrescue.sh diagnose"
fi

if [ "$RELAUNCH" = "1" ]; then
  hdr "7. Relaunching $NAME outside any tunnel"
  su - "$LOGIN_USER" -c "/usr/bin/open -a '$APP'" >/dev/null 2>&1 \
    && ok "$NAME relaunched with ordinary networking" \
    || bad "could not relaunch $NAME — open it yourself"
fi

hdr "Done"
act "The app is no longer inside any tunnel."
act "To tunnel it again deliberately: open AppTunnel.app and press play."
act "To keep it permanently untunnelled: untick it in the AppTunnel roster."
