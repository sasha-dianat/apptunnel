#!/bin/bash
# tunnel-veepn-repair.sh — bring VeePN's Shadowsocks tunnel up without VeePN.app.
#
#   tunnel-veepn-repair.sh           start the tunnel and claim the system proxy
#   tunnel-veepn-repair.sh --status   report, change nothing
#   tunnel-veepn-repair.sh --stop     stop it and release the system proxy
#   tunnel-veepn-repair.sh --stop --hiddify   ... and hand the proxy to Hiddify
#
# WHY THIS EXISTS
#
# VeePN.app reports "connected" while its Shadowsocks core is not running. Its
# UI state comes from the control plane, not from a working tunnel, so the app
# looks fine, 127.0.0.1:1080 never listens, and the exit IP never changes. Every
# server fails identically, which makes it look like an outage on their side.
#
# It is not. The server, the credentials and the config are all good: VeePN
# writes a complete Xray config to
#
#   ~/Library/Application Support/com.veepn.macos.direct/shadowsocks.json
#
# (Shadowsocks in WebSocket-over-TLS) and ships the core that consumes it at
#
#   VeePN.app/Contents/Resources/VPNManagement_V2RayModule.bundle/.../v2ray
#
# Feeding the one to the other produces a working tunnel immediately. Only the
# app's supervision of that core is broken, so this skips the app.
#
# A NOTE ON WHAT WAS RULED OUT
#
# The missing "alpn" field in tlsSettings looks like the bug - curl and openssl
# negotiate h2 against these servers and get 400, while http/1.1 gets 101. It is
# a red herring: v2ray's ws transport pins http/1.1 internally. An A/B run with
# and without the pin produced two identical working tunnels. Do not spend time
# there again.
#
# CREDENTIALS ROTATE. VeePN rewrites shadowsocks.json on each connect attempt.
# When this stops authenticating, open VeePN, press Connect once to refresh the
# file, and run this again. Nothing else needs to change.

set -uo pipefail

. "$(cd "$(dirname "$0")" && pwd)/tunnel-python.sh"

SOCKS_PORT=1081
HTTP_PORT=1091
V2RAY="/Applications/VeePN.app/Contents/Resources/VPNManagement_V2RayModule.bundle/Contents/Resources/v2ray"
SRC="$HOME/Library/Application Support/com.veepn.macos.direct/shadowsocks.json"
STATE="$HOME/.apptunnel/veepn"
CFG="$STATE/config.json"
LOG="$STATE/v2ray.log"
SVC="${TUNNEL_NET_SERVICE:-Wi-Fi}"

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; O=$'\033[0m'
ok()  { printf '   %sOK%s    %s\n'   "$G" "$O" "$1"; }
bad() { printf '   %sFAIL%s  %s\n'   "$R" "$O" "$1"; }
inf() { printf '   %s...%s   %s\n'   "$Y" "$O" "$1"; }

exit_ip() { /usr/bin/curl -4fsS -x "http://127.0.0.1:$HTTP_PORT" \
              --connect-timeout 6 --max-time 20 https://api.ipify.org 2>/dev/null; }

# OUR core only, identified by OUR config path.
#
# VeePN.app runs the same binary for its own tunnel (`v2ray run -config ...`)
# while this script runs `v2ray run -c ~/.apptunnel/veepn/config.json`. Matching
# on the binary alone caught both, so stopping this tunnel also killed VeePN's
# own process - and, worse, made the two indistinguishable when deciding whether
# anything of ours was running at all.
# Both conditions are required: the command must BEGIN with the v2ray binary and
# also mention our config. Testing the config alone matched the very `awk` doing
# the testing, because the path is on its own command line - the same
# self-matching trap main_pids_of documents for grep, in a function that feeds
# a kill.
core_pids() { /bin/ps -axo pid=,command= \
                | awk -v e="$V2RAY" -v c="$CFG" \
                  '{p=$1; $1=""; sub(/^[ \t]+/,""); if (index($0, e)==1 && index($0, c)>0) print p}'; }

# Anyone's v2ray, ours or VeePN.app's - only used for reporting.
all_core_pids() { /bin/ps -axo pid=,command= \
                | awk -v e="$V2RAY" '{p=$1;$1="";sub(/^[ \t]+/,"");if(index($0,e)==1)print p}'; }

STATEFILE="$STATE/tunnel.json"

write_state() {  # $1 = exit ip
  /bin/mkdir -p "$STATE"
  printf '{"pid":%s,"socks":%s,"http":%s,"exit_ip":"%s","at":%s}\n' \
    "$(core_pids | head -1 || echo 0)" "$SOCKS_PORT" "$HTTP_PORT" "$1" \
    "$(date +%s)" > "$STATEFILE" 2>/dev/null || true
}
clear_state() { /bin/rm -f "$STATEFILE" 2>/dev/null || true; }

# ---------------------------------------------------------------- status ---
if [ "${1:-}" = "--status" ]; then
  printf '\nVeePN tunnel status\n\n'
  pids="$(core_pids)"
  [ -n "$pids" ] && ok "our core running (pid $(echo "$pids" | tr '\n' ' '))" || bad "our core not running"
  others="$(all_core_pids | grep -vxF "${pids:-__none__}" | tr '\n' ' ' || true)"
  [ -n "${others// /}" ] && inf "VeePN.app is also running its own core (pid $others) - its Disconnect stops that one, not ours"
  /usr/sbin/scutil --proxy | awk '/SOCKS(Enable|Proxy|Port)|HTTP(Enable|Proxy|Port)/{print "         "$0}'
  ip="$(exit_ip)"
  [ -n "$ip" ] && ok "exit IP $ip" || bad "no exit IP (tunnel not carrying traffic)"
  printf '\n'
  exit 0
fi

# ------------------------------------------------------------------ stop ---
if [ "${1:-}" = "--stop" ]; then
  printf '\nStopping VeePN tunnel\n\n'
  if [ "${2:-}" = "--hiddify" ] && [ -d /Applications/Hiddify.app ]; then
    /usr/bin/open -a Hiddify; sleep 8
    /usr/sbin/networksetup -setwebproxy          "$SVC" 127.0.0.1 12334
    /usr/sbin/networksetup -setsecurewebproxy    "$SVC" 127.0.0.1 12334
    /usr/sbin/networksetup -setsocksfirewallproxy "$SVC" 127.0.0.1 12334
    ok "system proxy handed back to Hiddify"
  else
    /usr/sbin/networksetup -setwebproxystate           "$SVC" off
    /usr/sbin/networksetup -setsecurewebproxystate     "$SVC" off
    /usr/sbin/networksetup -setsocksfirewallproxystate "$SVC" off
    ok "system proxy released"
    inf "this network DPI-blocks direct HTTPS; expect no internet until a tunnel is up"
  fi
  # TERM, verify, then KILL, then verify again. A single unverified TERM left a
  # second core alive once: it kept serving 1081/1091, so the system proxy still
  # pointed at a live VeePN exit and the reported IP never changed - exactly the
  # "disconnected but still connected" symptom this command exists to cure.
  pids="$(core_pids)"
  if [ -n "$pids" ]; then
    kill -TERM $pids 2>/dev/null
    i=0; while [ "$i" -lt 20 ] && [ -n "$(core_pids)" ]; do sleep 0.25; i=$((i+1)); done
    left="$(core_pids)"
    [ -n "$left" ] && { kill -KILL $left 2>/dev/null; sleep 1; }
    if [ -n "$(core_pids)" ]; then
      bad "a core would not exit: $(core_pids | tr '\n' ' ')"
    else
      ok "our core stopped"
    fi
  else
    inf "our core was not running"
  fi
  clear_state

  # The ports are the thing that actually matters: while either is still served,
  # anything pointed at them keeps exiting through VeePN.
  still="$(/usr/sbin/netstat -an -p tcp 2>/dev/null \
    | awk -v s=".$SOCKS_PORT" -v h=".$HTTP_PORT" \
      '$6=="LISTEN" && ($4 ~ s"$" || $4 ~ h"$"){printf "%s ", $4}')"
  [ -n "$still" ] && bad "still serving: $still - something else is bound there" \
                  || ok "$SOCKS_PORT and $HTTP_PORT released"
  printf '\n'
  exit 0
fi

# ------------------------------------------------------------------- up ----
printf '\nRepairing VeePN Shadowsocks tunnel\n\n'

(( TUNNEL_PY_OK )) || { bad "no working python3 (see: xcode-select --install)"; exit 1; }
[ -x "$V2RAY" ] || { bad "VeePN's v2ray core not found at $V2RAY"; exit 1; }
ok "core binary present"

if [ ! -f "$SRC" ]; then
  bad "no VeePN config at shadowsocks.json"
  printf '\n   Open VeePN, choose Shadowsocks, press Connect once (it may still say\n'
  printf '   it failed - that is fine, it writes the config), then run this again.\n\n'
  exit 1
fi
ok "VeePN config found ($(/bin/date -r "$SRC" '+%Y-%m-%d %H:%M'))"

/bin/mkdir -p "$STATE"

# Rewrite only the inbounds: the outbound chain is VeePN's and is known good.
server="$("$PY" - "$SRC" "$CFG" "$SOCKS_PORT" "$HTTP_PORT" <<'PY'
import json, sys
src, dst, sp, hp = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
d = json.load(open(src))
d["inbounds"] = [
    {"tag": "socks-in", "listen": "127.0.0.1", "port": sp, "protocol": "socks",
     "settings": {"udp": True, "auth": "noauth"}},
    {"tag": "http-in",  "listen": "127.0.0.1", "port": hp, "protocol": "http",
     "settings": {}},
]
d["log"] = {"loglevel": "warning"}
json.dump(d, open(dst, "w"), indent=1)
s = d["outbounds"][0]["settings"]["servers"][0]
print("%s:%s" % (s["address"], s["port"]))
PY
)" || { bad "could not read VeePN's config"; exit 1; }
ok "config built for $server"

pids="$(core_pids)"; [ -n "$pids" ] && { kill -TERM $pids 2>/dev/null; sleep 1; inf "replaced running core"; }

/usr/bin/nohup "$V2RAY" run -c "$CFG" >"$LOG" 2>&1 &
sleep 5

ip="$(exit_ip)"
if [ -z "$ip" ]; then
  bad "tunnel did not come up"
  printf '\n   Most likely the credentials expired. Open VeePN, press Connect once to\n'
  printf '   refresh shadowsocks.json, then run this again.\n\n   Last log lines:\n'
  /usr/bin/tail -5 "$LOG" 2>/dev/null | /usr/bin/sed 's/^/      /'
  printf '\n'
  kill -TERM $(core_pids) 2>/dev/null
  exit 1
fi
ok "tunnel up, exit IP $ip"
write_state "$ip"

# Claim the system proxy only once the tunnel is proven, so a failure here can
# never leave the machine pointed at a dead port.
/usr/sbin/networksetup -setwebproxy           "$SVC" 127.0.0.1 "$HTTP_PORT"
/usr/sbin/networksetup -setsecurewebproxy     "$SVC" 127.0.0.1 "$HTTP_PORT"
/usr/sbin/networksetup -setsocksfirewallproxy "$SVC" 127.0.0.1 "$SOCKS_PORT"
ok "system proxy -> SOCKS $SOCKS_PORT / HTTP $HTTP_PORT"

geo="$(/usr/bin/curl -4fsS -x "http://127.0.0.1:$HTTP_PORT" --max-time 20 https://ipinfo.io/json 2>/dev/null \
        | "$PY" -c 'import sys,json;d=json.load(sys.stdin);print(d.get("city",""),d.get("country",""))' 2>/dev/null)"
[ -n "$geo" ] && ok "exit location $geo"

printf '\n   AppTunnel can now be started - its Run button will find this endpoint.\n\n'
