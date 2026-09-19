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
INTERVAL="${TUNNEL_EVENTLOG_INTERVAL:-10}"

mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------- probes ---
# Every probe is cheap, local, and read-only. None may block: a hung probe would
# stall sampling exactly when a disconnection is happening, which is the moment
# the record matters most.

# Port state comes from netstat, not lsof, for two reasons measured on this Mac:
# lsof costs ~0.111s for all four ports against netstat's ~0.010s, and an
# (netstat lives in /usr/sbin, NOT /usr/bin - an earlier version pointed at the
# wrong path, exited 127 every time, and reported every port as down while
# looking impressively fast in a benchmark that never checked the exit code)
# unprivileged lsof CANNOT SEE root-owned sockets - so the root-owned bridge on
# 17080 looked dead to the sampler and produced false "the bridge died"
# verdicts. netstat sees it.
#
# The owning process name is still worth having, but only changes when the port
# changes, so it is resolved with a single lsof at that moment and cached.
LISTENING=""
declare_listening() {  # one netstat for every port we care about
  LISTENING="$(/usr/sbin/netstat -an -p tcp 2>/dev/null \
    | awk '$6=="LISTEN" && $4 ~ /\.(17080|1081|1091|12334)$/ {n=split($4,a,"."); print a[n]}' \
    | sort -u | tr '\n' ',' || true)"
}

OWNER_CACHE=""
port_owner() {  # port -> "name/pid" if known, "up" if listening but unnamed, "" if down
  case ",$LISTENING," in
    *",$1,"*) ;;
    *) printf ''; return ;;
  esac
  case "$OWNER_CACHE" in
    *"$1="*) printf '%s' "$(printf '%s' "$OWNER_CACHE" | tr ';' '\n' | awk -F= -v p="$1" '$1==p{print $2; exit}')" ;;
    *) printf 'up' ;;
  esac
}

refresh_owners() {  # one lsof, only when the set of listening ports changed
  OWNER_CACHE="$(/usr/sbin/lsof -nP -iTCP:17080,1081,1091,12334 -sTCP:LISTEN 2>/dev/null \
    | awk 'NR>1 {n=split($9,a,":"); print a[n] "=" $1 "/" $2}' | sort -u | tr '\n' ';' || true)"
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

# ONE ps per sample, reused three ways. Three separate `ps -axo` calls cost
# ~0.095s each; the process table is the same table each time.
PSFILE="${TMPDIR:-/tmp}/apptunnel-eventlog.ps.$$"
take_ps() { /bin/ps -axo pid=,gid=,command= > "$PSFILE" 2>/dev/null || : > "$PSFILE"; }

vpn_procs() {
  grep -iEo "hiddify|veepn|v2ray|xray|sing-box|openvpn|wireguard|tunnelbear|expressvpn|proxifier|karing" \
    "$PSFILE" 2>/dev/null | tr "[:upper:]" "[:lower:]" | sort -u | tr "\n" "," | sed "s/,$//"
}

# The gid is looked up once and cached: dscl costs ~0.031s and the group's id
# does not change while it exists.
GROUP_GID_CACHE=""
refresh_gid() {
  GROUP_GID_CACHE="$(/usr/bin/dscl . -read /Groups/apptunnel PrimaryGroupID 2>/dev/null | awk '{print $2}' || true)"
}

group_members() {
  [ -n "${GROUP_GID_CACHE:-}" ] || { printf 'nogroup'; return; }
  n="$(awk -v g="$GROUP_GID_CACHE" '$2==g{n++} END{print n+0}' "$PSFILE" 2>/dev/null || true)"
  printf 'gid%s:%s' "$GROUP_GID_CACHE" "${n:-0}"
}

launcher_alive() {
  grep -qE 'tunnel-lock\.sh' "$PSFILE" 2>/dev/null && printf yes || printf no
}

stop_file_provenance() {  # who asked for the stop, if anyone did
  [ -f "$STATE_DIR/stop" ] || { printf ''; return; }
  body="$(head -c 400 "$STATE_DIR/stop" 2>/dev/null || true)"
  [ -n "$body" ] && printf '%s' "$body" || printf 'present(no provenance recorded)'
}

# The SSID costs ~0.066s and changes rarely, so it is only re-read periodically
# or when the default route moves - a Wi-Fi change always moves the route.
SSID_CACHE=""
TICK=0
LAST_LISTENING=""
LAST_ROUTE=""

snapshot() {
  take_ps
  declare_listening
  rt="$(default_route)"

  if [ "$LISTENING" != "$LAST_LISTENING" ]; then
    refresh_owners
    LAST_LISTENING="$LISTENING"
  fi
  if [ $(( TICK % 20 )) -eq 0 ] || [ "$rt" != "$LAST_ROUTE" ] || [ -z "$SSID_CACHE" ]; then
    SSID_CACHE="$(wifi_ssid)"
    refresh_gid
    LAST_ROUTE="$rt"
  fi
  TICK=$(( TICK + 1 ))

  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s' \
    "$(proxy_state)" \
    "$rt" \
    "$(port_owner 17080)" \
    "$(port_owner 1081)" \
    "$(port_owner 12334)" \
    "$(launcher_alive)" \
    "$(group_members)" \
    "$SSID_CACHE" \
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

  # Steady-state cost, which is the number that matters: `once` always pays the
  # cold path (tick 0 re-reads the SSID and the gid), and the daemon pays that
  # on 1 sample in 20. Reports the per-sample average and the duty cycle at the
  # configured interval.
  bench)
    n="${2:-10}"
    t0="$("$PY" -c 'import time; print(time.time())')"
    i=0; while [ "$i" -lt "$n" ]; do snapshot >/dev/null; i=$((i+1)); done
    t1="$("$PY" -c 'import time; print(time.time())')"
    "$PY" -c "
import sys
n, t0, t1, iv = int('$n'), float('$t0'), float('$t1'), float('$INTERVAL')
per = (t1 - t0) / n
print('  samples        : %d' % n)
print('  per sample     : %.3fs' % per)
print('  interval       : %.0fs' % iv)
print('  duty cycle     : %.1f%% of one core' % (100.0 * per / iv))
"
    rm -f "$PSFILE"
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
  trap 'rm -f "$PIDFILE" "$PSFILE"; exit 0' TERM INT
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
