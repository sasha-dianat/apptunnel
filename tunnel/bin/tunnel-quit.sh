#!/bin/bash
# tunnel-quit.sh — close every app inside the tunnel, then retire the group.
#
# Stop and an accidental disconnect both leave tunnelled apps running with no
# network, on purpose, so they keep their gid and can re-adopt a rebuilt tunnel
# without restarting. Quitting AppTunnel is the one action that is meant to take
# them down with it, and that is what this does.
#
# Membership is read from the isolation group rather than from a pid list: the
# launcher that started those apps may be long gone, and the group is the only
# record that survives it.

set -uo pipefail

GROUP_NAME="${TUNNEL_GROUP_NAME:-apptunnel}"

GROUP_GID="$(/usr/bin/dscl . -read "/Groups/$GROUP_NAME" PrimaryGroupID 2>/dev/null | awk '{print $2}')"
if [ -z "$GROUP_GID" ]; then
  echo "tunnel-quit: no isolation group; nothing to close"
  exit 0
fi

members() { ps -axo pid=,gid= 2>/dev/null | awk -v g="$GROUP_GID" '$2==g{print $1}'; }

# App names for a graceful AppleScript quit, derived from the bundle path so the
# app can save state. Falls through to signals for anything without a bundle.
names_of() {
  ps -axo pid=,gid=,command= 2>/dev/null | awk -v g="$GROUP_GID" '
    $2==g {p=$1; $1=""; $2=""; sub(/^[ \t]+/,"");
           if (match($0, /\/[^\/]+\.app\/Contents\/MacOS\//)) {
             s = substr($0, RSTART+1, RLENGTH-1);
             sub(/\.app.*/, "", s);
             print s }}' | sort -u
}

if [ -z "$(members)" ]; then
  sudo -n /usr/sbin/dseditgroup -o delete "$GROUP_NAME" >/dev/null 2>&1 || true
  echo "tunnel-quit: tunnel was empty; group retired"
  exit 0
fi

for name in $(names_of); do
  /usr/bin/osascript -e "tell application \"$name\" to quit" >/dev/null 2>&1 || true
done

i=0
while [ "$i" -lt 30 ]; do
  [ -z "$(members)" ] && break
  sleep 0.5
  i=$((i + 1))
done

left="$(members)"
if [ -n "$left" ]; then
  # shellcheck disable=SC2086
  kill -TERM $left 2>/dev/null || true
  sleep 2
fi

left="$(members)"
if [ -n "$left" ]; then
  # shellcheck disable=SC2086
  kill -KILL $left 2>/dev/null || true
  sleep 1
fi

left="$(members)"
if [ -n "$left" ]; then
  echo "tunnel-quit: some processes would not exit: $(printf '%s' "$left" | tr '\n' ' ')" >&2
  exit 1
fi

sudo -n /usr/sbin/dseditgroup -o delete "$GROUP_NAME" >/dev/null 2>&1 || true
echo "tunnel-quit: tunnelled apps closed"
