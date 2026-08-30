#!/bin/bash
# tunnel-dnsguard.sh — find and disarm machine-wide DNS blocks in PF anchors.
#
# The v1.1/v5.4 launchers emit
#     block drop out quick on <if> proto { tcp udp } from any to any port 53
# with no `group` clause, which blocks DNS for the entire Mac rather than just
# the guarded apps. This tool finds such rules, proves with a cache-bypassing
# query whether DNS is actually down, and removes only the offending rules.
#
# Rules that ARE scoped to a group are left alone — those are legitimate.
# Nothing else is touched: no DHCP, no DNS servers, no network services.
#
#   tunnel-dnsguard.sh          report only
#   tunnel-dnsguard.sh --fix    flush the offending anchors

set -uo pipefail
FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

r="$RANDOM$RANDOM"

echo "############ 1. LIVE ANCHOR CONTENTS ############"
BAD=()
for a in $(sudo pfctl -a com.apple -s Anchors 2>/dev/null); do
  name="com.apple/$(basename "$a")"
  rules="$(sudo pfctl -a "$name" -s rules 2>/dev/null)"
  if [ -z "$rules" ]; then echo "  $name : (empty)"; continue; fi
  echo "  $name :"
  printf '%s\n' "$rules" | sed 's/^/      /'
  # Offending = mentions port 53/853 AND is not scoped to a group.
  if printf '%s\n' "$rules" | grep -E 'port = (53|853)' | grep -qv 'group'; then
    echo "      ^^^ MACHINE-WIDE DNS BLOCK (not scoped to a group)"
    BAD+=("$name")
  fi
done
echo "  machine-wide DNS-blocking anchors: ${#BAD[@]}"

echo
echo "############ 2. IS DNS ACTUALLY BLOCKED? (cache-bypassing) ############"
if [ -n "$(dig +time=4 +tries=1 +short "uncached-$r.wikipedia.org" @1.1.1.1 2>/dev/null)" ]; then
  echo "  uncached udp/53 to 1.1.1.1 : WORKS"
else
  echo "  uncached udp/53 to 1.1.1.1 : NO ANSWER"
fi
if [ -n "$(dig +time=4 +tries=1 +short www.wikipedia.org @1.1.1.1 2>/dev/null)" ]; then
  echo "  real lookup via 1.1.1.1    : WORKS"
else
  echo "  real lookup via 1.1.1.1    : BLOCKED  <-- Internet is broken right now"
fi
if [ -n "$(dig +time=4 +tries=1 +short www.wikipedia.org 2>/dev/null)" ]; then
  echo "  system resolver            : WORKS"
else
  echo "  system resolver            : BLOCKED"
fi

echo
echo "############ 3. DISARM ############"
if [ "${#BAD[@]}" -eq 0 ]; then
  echo "  nothing to disarm"
elif [ "$FIX" = 0 ]; then
  echo "  ${#BAD[@]} anchor(s) would be flushed. Re-run with --fix."
else
  for name in "${BAD[@]}"; do
    echo "  flushing $name"
    sudo pfctl -a "$name" -F rules 2>&1 | sed 's/^/      /'
    echo "      rules remaining: $(sudo pfctl -a "$name" -s rules 2>/dev/null | wc -l | tr -d ' ')"
  done
fi

echo
echo "############ 4. VERIFY ############"
[ -n "$(dig +time=4 +tries=1 +short www.wikipedia.org @1.1.1.1 2>/dev/null)" ] \
  && echo "  uncached DNS : OK" || echo "  uncached DNS : STILL BLOCKED"
/usr/bin/python3 -c "
import socket,sys
s=socket.socket(); s.settimeout(3)
try: s.connect(('1.1.1.1',443)); sys.exit(0)
except Exception: sys.exit(1)
" && echo "  direct TCP   : OK" || echo "  direct TCP   : FAIL"
n=0
for a in $(sudo pfctl -a com.apple -s Anchors 2>/dev/null); do
  sudo pfctl -a "com.apple/$(basename "$a")" -s rules 2>/dev/null \
    | grep -E 'port = (53|853)' | grep -qv 'group' && n=$((n+1))
done
echo "  machine-wide DNS-blocking anchors remaining: $n"
echo
echo "############ END ############"
