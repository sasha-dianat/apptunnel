#!/bin/bash
# tunnel-telemetry.sh — one measurement pass over tunnel health.
#
# Prints a single JSON object on stdout and nothing else; diagnostics go to
# stderr. Every band is 0.0..1.0, or -1.0 for "unknown" (never rendered as an
# alarm). Designed to be cheap: the caller's watch loop ticks every 3 seconds.
#
#   tunnel-telemetry.sh [--gid N] [--anchor NAME] [--bridge URL] [--exit-ip IP]
#
# Every probe uses a hard timeout. `nc -z -w N` is never used: it does not cap a
# connection that PF silently drops, which is exactly the state we measure in.

set -uo pipefail

GID=""; ANCHOR=""; BRIDGE=""; BASE_EXIT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --gid)     GID="${2:-}"; shift 2 ;;
    --anchor)  ANCHOR="${2:-}"; shift 2 ;;
    --bridge)  BRIDGE="${2:-}"; shift 2 ;;
    --exit-ip) BASE_EXIT="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

# ms taken by a TCP connect, or -1 if it did not connect within `t` seconds.
connect_ms() {
  /usr/bin/python3 -c '
import socket, sys, time
host, port, t = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
s = socket.socket(); s.settimeout(t)
start = time.time()
try:
    s.connect((host, port)); print(int((time.time() - start) * 1000))
except Exception:
    print(-1)
finally:
    s.close()
' "$1" "$2" "${3:-2}"
}

# 1.0 at or below `good` ms, ~0 at or above `bad` ms, linear between.
grade() {
  /usr/bin/python3 -c '
import sys
v, good, bad = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
if v < 0: print(0.0)
elif v <= good: print(1.0)
elif v >= bad: print(0.05)
else: print(round(1.0 - (v - good) / (bad - good), 3))
' "$1" "$2" "$3"
}

D_LINK="" D_DNS="" D_SOCKS="" D_BRIDGE="" D_EXIT="" D_RTT="" D_FLOW="" D_SEAL="" D_WALL="" D_GRIP=""

# --- 1 LINK ---------------------------------------------------------------
gw="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')"
if [ -z "$gw" ]; then
  LINK=0.0; D_LINK="no default route"
elif ping -c 1 -t 2 "$gw" >/dev/null 2>&1; then
  LINK=1.0; D_LINK="gateway $gw"
else
  LINK=0.5; D_LINK="gateway $gw silent"
fi

# --- 2 DNS ----------------------------------------------------------------
dstart="$(/usr/bin/python3 -c 'import time;print(time.time())')"
if [ -n "$(dig +time=2 +tries=1 +short www.wikipedia.org @1.1.1.1 2>/dev/null)" ]; then
  dms="$(/usr/bin/python3 -c 'import sys,time;print(int((time.time()-float(sys.argv[1]))*1000))' "$dstart")"
  DNS="$(grade "$dms" 120 2000)"; D_DNS="${dms}ms"
else
  DNS=0.0; D_DNS="no resolution"
fi

# --- 3 SOCKS --------------------------------------------------------------
sx="$(/usr/sbin/scutil --proxy 2>/dev/null)"
sh_="$(printf '%s\n' "$sx" | awk '/SOCKSProxy[[:space:]]*:/{print $3; exit}')"
sp_="$(printf '%s\n' "$sx" | awk '/SOCKSPort[[:space:]]*:/{print $3; exit}')"
if [ -n "$sh_" ] && [ -n "$sp_" ]; then
  sms="$(connect_ms "$sh_" "$sp_" 2)"
  if [ "$sms" -lt 0 ] 2>/dev/null; then
    SOCKS=0.0; D_SOCKS="$sh_:$sp_ not listening"
  else
    SOCKS="$(grade "$sms" 50 400)"; D_SOCKS="$sh_:$sp_ ${sms}ms"
  fi
else
  SOCKS=-1.0; D_SOCKS="no system SOCKS"
fi

# --- 4 BRIDGE / 6 RTT / 5 EXIT -------------------------------------------
if [ -n "$BRIDGE" ]; then
  bhost="$(printf '%s' "$BRIDGE" | sed -e 's|http://||' -e 's|/.*||' -e 's|:.*||')"
  bport="$(printf '%s' "$BRIDGE" | sed -e 's|.*:||' -e 's|/.*||')"
  bms="$(connect_ms "${bhost:-127.0.0.1}" "${bport:-0}" 2)"
  if [ "$bms" -lt 0 ] 2>/dev/null; then
    BRIDGE_V=0.0; D_BRIDGE="dead"
  else
    BRIDGE_V="$(grade "$bms" 100 600)"; D_BRIDGE="${bms}ms"
  fi

  rstart="$(/usr/bin/python3 -c 'import time;print(time.time())')"
  ip="$(/usr/bin/curl -4fsS -x "$BRIDGE" --noproxy '' --connect-timeout 4 --max-time 8 \
        https://api.ipify.org 2>/dev/null || true)"
  if printf '%s' "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    rms="$(/usr/bin/python3 -c 'import sys,time;print(int((time.time()-float(sys.argv[1]))*1000))' "$rstart")"
    RTT="$(grade "$rms" 150 2500)"; D_RTT="${rms}ms"
    if [ -z "$BASE_EXIT" ] || [ "$ip" = "$BASE_EXIT" ]; then
      EXIT_V=1.0; D_EXIT="$ip"
    else
      EXIT_V=0.4; D_EXIT="changed: $ip"
    fi
  else
    RTT=0.0; D_RTT="no reply"; EXIT_V=0.0; D_EXIT="unreachable"; ip="${BASE_EXIT:-}"
  fi
else
  BRIDGE_V=-1.0; D_BRIDGE="no bridge"; RTT=-1.0; D_RTT="idle"
  EXIT_V=-1.0; D_EXIT="unknown"; ip="${BASE_EXIT:-}"
fi

# --- 7 FLOW ---------------------------------------------------------------
# Established connections through the bridge port, log-scaled. Zero is idle,
# not an error; the UI renders this band dim rather than red at zero.
if [ -n "$BRIDGE" ]; then
  fport="$(printf '%s' "$BRIDGE" | sed -e 's|.*:||' -e 's|/.*||')"
  conns="$(netstat -an -p tcp 2>/dev/null | grep -c "\.${fport}.*ESTABLISHED" || true)"
  FLOW="$(/usr/bin/python3 -c '
import math, sys
n = int(sys.argv[1] or 0)
print(round(min(1.0, math.log1p(n) / math.log1p(24)), 3))
' "${conns:-0}")"
  D_FLOW="${conns:-0} conn"
else
  FLOW=-1.0; D_FLOW="idle"
fi

# --- 8 SEAL ---------------------------------------------------------------
# The security invariant, re-verified live: a process in the isolation group
# must reach nothing directly. Only meaningful when we know the gid.
if [ -n "$GID" ] && [ "$(id -u)" -eq 0 ]; then
  gname="$(dscl . -list /Groups PrimaryGroupID 2>/dev/null | awk -v g="$GID" '$2==g{print $1; exit}')"
  if [ -n "$gname" ]; then
    reach="$(sudo -n -u "${SUDO_USER:-root}" -g "$gname" /usr/bin/python3 -c '
import socket
n = 0
for host, port in (("1.1.1.1",443), ("8.8.8.8",53), ("9.9.9.9",443)):
    s = socket.socket(); s.settimeout(2)
    try:
        s.connect((host, port)); n += 1
    except Exception:
        pass
    finally:
        s.close()
print(n)
' 2>/dev/null || echo -1)"
    case "$reach" in
      0) SEAL=1.0; D_SEAL="0/3 reachable" ;;
      -1|"") SEAL=-1.0; D_SEAL="probe failed" ;;
      *) SEAL=0.0; D_SEAL="LEAK $reach/3" ;;
    esac
  else
    SEAL=-1.0; D_SEAL="group $GID unknown"
  fi
else
  SEAL=-1.0; D_SEAL="not sampled"
fi

# --- 9 WALL ---------------------------------------------------------------
if [ "$(id -u)" -eq 0 ] && [ -n "$ANCHOR" ]; then
  if ! pfctl -s rules 2>/dev/null | grep -q 'anchor "com.apple/\*"'; then
    WALL=0.0; D_WALL="anchors not evaluated"
  else
    nrules="$(pfctl -a "$ANCHOR" -s rules 2>/dev/null | grep -c 'block drop' || true)"
    if [ "${nrules:-0}" -gt 0 ]; then
      WALL=1.0; D_WALL="${nrules} rules"
    else
      WALL=0.0; D_WALL="anchor empty"
    fi
  fi
else
  WALL=-1.0; D_WALL="needs root"
fi

# --- 10 GRIP --------------------------------------------------------------
if [ -n "$GID" ]; then
  escaped="$(ps -axo gid=,command= | awk -v g="$GID" '
    $0 ~ /\/Applications\/[^ ]*\.app\/Contents\/MacOS\// { if ($1 != g) n++ } END { print n+0 }')"
  inside="$(ps -axo gid= | awk -v g="$GID" '$1==g{n++} END{print n+0}')"
  if [ "${inside:-0}" -eq 0 ]; then
    GRIP=-1.0; D_GRIP="no processes"
  elif [ "${escaped:-0}" -gt 0 ]; then
    GRIP=0.0; D_GRIP="$escaped outside"
  else
    GRIP=1.0; D_GRIP="$inside inside"
  fi
else
  GRIP=-1.0; D_GRIP="no group"
fi

# --- emit -----------------------------------------------------------------
/usr/bin/python3 -c '
import json, sys, time
keys = ["link","dns","socks","bridge","exit","rtt","flow","seal","wall","grip"]
vals = [float(v) for v in sys.argv[1:11]]
details = sys.argv[11:21]
exit_ip = sys.argv[21]
d = dict(zip(keys, vals))
# Protection confidence: containment, firewall and grip carry triple weight,
# and any hard zero among them pins the score to zero. Partial protection is
# not protection.
w = {"seal": 3.0, "wall": 3.0, "grip": 3.0}
crit = [d[k] for k in ("seal", "wall", "grip") if d[k] >= 0]
if crit and min(crit) == 0.0:
    score = 0.0
else:
    num = den = 0.0
    for k in keys:
        if d[k] < 0:
            continue
        ww = w.get(k, 1.0)
        num += d[k] * ww; den += ww
    score = round(num / den, 3) if den else -1.0
d["t"] = time.time()
d["score"] = score
d["exit_ip"] = exit_ip
d["detail"] = dict(zip(keys, details))
print(json.dumps(d))
' "$LINK" "$DNS" "$SOCKS" "$BRIDGE_V" "$EXIT_V" "$RTT" "$FLOW" "$SEAL" "$WALL" "$GRIP" \
  "$D_LINK" "$D_DNS" "$D_SOCKS" "$D_BRIDGE" "$D_EXIT" "$D_RTT" "$D_FLOW" "$D_SEAL" "$D_WALL" "$D_GRIP" \
  "${ip:-}"
