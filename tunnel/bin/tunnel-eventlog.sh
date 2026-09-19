#!/bin/bash
# tunnel-eventlog.sh — record WHAT changed, WHEN, and WHO owned it, so a
# disconnection can be attributed afterwards instead of guessed at.
#
#   tunnel-eventlog.sh start     begin recording (detached)
#   tunnel-eventlog.sh stop      stop recording
#   tunnel-eventlog.sh status    is it running, how many events so far
#   tunnel-eventlog.sh once      take a single snapshot and print it
#
# WHY THIS EXISTS
#
# When the tunnel drops, the question is always "was that AppTunnel, VeePN,
# Hiddify, another VPN app, the Wi-Fi, or the machine sleeping?" — and by the
# time anyone looks, the evidence is gone. macOS logs some of it, but nothing
# records the one fact that matters most: which of the eleven VPN-ish apps on
# this Mac owned the system proxy at the moment the connection died.
#
# So this samples a small set of facts every few seconds and writes a line ONLY
# when one of them changes. Steady state costs nothing and produces nothing; a
# disconnection produces a precise before/after with the owning processes named.
#
# It changes NOTHING. No sudo, no network calls, no writes outside its own log.
# It is safe to leave running forever and safe to run inside a tunnelled app.

set -uo pipefail

. "$(cd "$(dirname "$0")" && pwd)/tunnel-python.sh"

STATE_DIR="$HOME/.apptunnel"
LOG="$STATE_DIR/disconnects.jsonl"
PIDFILE="$STATE_DIR/eventlog.pid"
INTERVAL="${TUNNEL_EVENTLOG_INTERVAL:-3}"

mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------- probes ---
# Every probe is cheap, local, and read-only. None may block: a hung probe would
# stall sampling exactly when a disconnection is happening, which is the moment
# the record matters most.

port_owner() {  # port -> "name/pid" of whoever LISTENS on it, or ""
  /usr/sbin/lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null \
    | awk 'NR>1 {print $1 "/" $2; exit}'
}

proxy_state() {  # "http:port socks:port" from the live system config
  /usr/sbin/scutil --proxy 2>/dev/null | awk '
    /HTTPEnable/{he=$3} /HTTPPort/{hp=$3} /HTTPProxy/{hh=$3}
    /SOCKSEnable/{se=$3} /SOCKSPort/{sp=$3} /SOCKSProxy/{sh=$3}
    END{printf "%s:%s/%s %s:%s/%s", (he=="1"?"on":"off"), hh, hp,
                                     (se=="1"?"on":"off"), sh, sp}'
}

default_route() { /sbin/route -n get default 2>/dev/null \
  | awk '/gateway:/{g=$2} /interface:/{i=$2} END{printf "%s@%s", g, i}'; }

wifi_ssid() { /usr/sbin/networksetup -getairportnetwork en0 2>/dev/null \
  | sed 's/^.*: //' | tr -d '\n'; }

vpn_procs() {  # which VPN-ish apps are alive at all
  /bin/ps -axo comm= 2>/dev/null \
    | grep -iE "hiddify|veepn|v2ray|xray|sing-box|openvpn|wireguard|tunnelbear|expressvpn|proxifier|karing" \
    | sed 's#.*/##' | sort -u | tr '\n' ',' | sed 's/,$//'
}

group_members() {  # processes inside the isolation group
  gid="$(/usr/bin/dscl . -read /Groups/apptunnel PrimaryGroupID 2>/dev/null | awk '{print $2}' || true)"
  [ -n "${gid:-}" ] || { printf 'nogroup'; return; }
  n="$(/bin/ps -axo gid= 2>/dev/null | awk -v g="$gid" '$1==g{n++} END{print n+0}' || true)"
  printf 'gid%s:%s' "$gid" "${n:-0}"
}

launcher_alive() {
  /bin/ps -axo command= 2>/dev/null | grep -qE '[t]unnel-lock\.sh' && printf yes || printf no
}

stop_file_provenance() {  # who asked for the stop, if anyone did
  [ -f "$STATE_DIR/stop" ] || { printf ''; return; }
  body="$(head -c 400 "$STATE_DIR/stop" 2>/dev/null || true)"
  [ -n "$body" ] && printf '%s' "$body" || printf 'present(no provenance recorded)'
}

snapshot() {
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s' \
    "$(proxy_state)" \
    "$(default_route)" \
    "$(port_owner 17080)" \
    "$(port_owner 1081)" \
    "$(port_owner 12334)" \
    "$(launcher_alive)" \
    "$(group_members)" \
    "$(wifi_ssid)" \
    "$(vpn_procs)"
}

emit() {  # $1 = kind, $2 = previous snapshot, $3 = current snapshot
  "$PY" - "$LOG" "$1" "$2" "$3" "$(stop_file_provenance)" <<'PY'
import json, sys, time, datetime
log, kind, prev, cur, stopinfo = sys.argv[1:6]
F = ["proxy","route","bridge_17080","socks_1081","hiddify_12334",
     "launcher","group","ssid","vpn_procs"]
p, c = prev.split("|"), cur.split("|")
changed = {F[i]: {"from": p[i], "to": c[i]} for i in range(min(len(F), len(p), len(c))) if p[i] != c[i]}
rec = {
    "t": time.time(),
    "at": datetime.datetime.now().isoformat(timespec="seconds"),
    "kind": kind,
    "changed": changed,
    "state": {F[i]: c[i] for i in range(min(len(F), len(c)))},
}
if stopinfo:
    rec["stop_request"] = stopinfo
with open(log, "a") as f:
    f.write(json.dumps(rec) + "\n")
PY
}

# ------------------------------------------------------------------ run ----
case "${1:-status}" in
  once)
    printf 'snapshot: %s\n' "$(snapshot)"
    exit 0 ;;

  stop)
    if [ -f "$PIDFILE" ]; then
      p="$(cat "$PIDFILE" 2>/dev/null || true)"
      [ -n "$p" ] && kill -TERM "$p" 2>/dev/null
      rm -f "$PIDFILE"
      echo "eventlog stopped"
    else
      echo "eventlog was not running"
    fi
    exit 0 ;;

  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null || echo 0)" 2>/dev/null; then
      echo "eventlog running (pid $(cat "$PIDFILE"))"
    else
      echo "eventlog not running"
    fi
    echo "events recorded: $( [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0 )"
    echo "log: $LOG"
    exit 0 ;;

  start) ;;
  *) echo "usage: $(basename "$0") {start|stop|status|once}" >&2; exit 2 ;;
esac

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null || echo 0)" 2>/dev/null; then
  echo "eventlog already running (pid $(cat "$PIDFILE"))"; exit 0
fi

# The pid is written by the PARENT from $!, not by the subshell from $$: in
# bash 3.2 - the only bash on macOS - $$ inside `( ... ) &` is still the
# parent's pid, so the pidfile named a process that had already exited and
# `status` always reported "not running".
(
  trap 'rm -f "$PIDFILE"; exit 0' TERM INT
  prev="$(snapshot)"
  emit baseline "$prev" "$prev"
  while :; do
    sleep "$INTERVAL"
    cur="$(snapshot)"
    if [ "$cur" != "$prev" ]; then
      emit change "$prev" "$cur"
      prev="$cur"
    fi
  done
) >/dev/null 2>&1 &
BG=$!
echo "$BG" > "$PIDFILE"

sleep 1
echo "eventlog started (pid $BG), sampling every ${INTERVAL}s"
echo "log: $LOG"
