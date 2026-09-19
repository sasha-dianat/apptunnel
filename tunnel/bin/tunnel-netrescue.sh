#!/bin/bash
# tunnel-netrescue.sh — diagnose and recover macOS networking after a tunnel
# launcher has gone wrong.
#
# Ordered from least to most invasive. Nothing here runs unless you name it;
# `diagnose` is the default and is strictly read only.
#
#   diagnose            full read-only report with a ranked verdict
#   fix-dns             flush machine-wide DNS blocks + the resolver cache
#   restore-pf          reload Apple's stock /etc/pf.conf ruleset
#   flush-pf            flush ALL pf rules and disable pf (biggest hammer for pf)
#   renew-dhcp [IFACE]  release/renew the DHCP lease (default: active service)
#   backup              back up the SystemConfiguration preferences
#   restore-backup      put a previous backup back
#   reset-network       LAST RESORT: back up, then remove the network
#                       preference files. Requires --i-understand and a reboot.
#
# IMPORTANT ORDER OF ATTACK when the Mac has lost the Internet after using the
# tunnel: the cause is almost always a leftover PF anchor, NOT DHCP and NOT the
# network preferences. Work down the list; stop as soon as connectivity returns.
#   1. fix-dns          (fixes ~90% of cases; instant, reversible)
#   2. restore-pf
#   3. flush-pf
#   4. renew-dhcp
#   5. reset-network    (only if 1-4 all failed; needs a reboot)

set -uo pipefail

# The system python3 at /usr/bin is a Command Line Tools stub: it exists and is
# executable even when the Tools are not installed, and then every call dies
# with "invalid active developer path". This resolves one that actually runs.
. "$(cd "$(dirname "$0")" && pwd)/tunnel-python.sh"

BIN="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$HOME/.apptunnel/netbackup"
SC_DIR="/Library/Preferences/SystemConfiguration"
SC_FILES="preferences.plist NetworkInterfaces.plist com.apple.airport.preferences.plist"

C=$'\033[36m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; O=$'\033[0m'
hdr()  { printf '\n%s== %s ==%s\n' "$C" "$1" "$O"; }
ok()   { printf '   %sok%s   %s\n' "$G" "$O" "$1"; }
warn() { printf '   %s!!%s   %s\n' "$Y" "$O" "$1"; }
bad()  { printf '   %sXX%s   %s\n' "$R" "$O" "$1"; }
act()  { printf '   %s->%s   %s\n' "$D" "$O" "$1"; }

SUDO="sudo"
[ "$(id -u)" -eq 0 ] && SUDO=""

active_iface() {
  route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}'
}
service_for_iface() {
  local dev="$1"
  networksetup -listallhardwareports 2>/dev/null \
    | awk -v d="$dev" '/^Hardware Port:/{hp=substr($0,16)} /^Device:/{if($2==d){print hp; exit}}'
}

dns_works() { [ -n "$(dig +time=3 +tries=1 +short www.wikipedia.org @1.1.1.1 2>/dev/null)" ]; }
# `nc -z -w N` does NOT reliably cap a connection that PF silently drops, so a
# probe from inside a guarded group hangs — precisely when this tool is needed.
# Python enforces a hard timeout.
tcp_probe() {  # tcp_probe HOST PORT [SECONDS]
  "$PY" -c '
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

tcp_works() { tcp_probe 1.1.1.1 443 3; }

# ---------------------------------------------------------------- diagnose --
cmd_diagnose() {
  local pf_blocks=0 pf_anchor_missing=0 dnsok=0 tcpok=0 gw="" iface=""

  hdr "Link and addressing"
  iface="$(active_iface)"
  if [ -n "$iface" ]; then
    ok "default route via $iface"
    gw="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')"
    [ -n "$gw" ] && ok "gateway $gw" || bad "no gateway on the default route"
    local ip; ip="$(ipconfig getifaddr "$iface" 2>/dev/null)"
    [ -n "$ip" ] && ok "$iface has IPv4 $ip" || bad "$iface has NO IPv4 address (DHCP did not complete)"
    local lease; lease="$(ipconfig getpacket "$iface" 2>/dev/null | awk '/lease_time/{print $3; exit}')"
    [ -n "$lease" ] && ok "DHCP lease present (lease_time $lease)" \
                    || warn "no DHCP packet on $iface (static config, or lease never obtained)"
    if [ -n "$gw" ]; then
      if ping -c 1 -t 2 "$gw" >/dev/null 2>&1; then ok "gateway responds to ping"
      else warn "gateway does not answer ping (may be filtered)"; fi
    fi
  else
    bad "NO default route — the Mac has no path off this machine"
  fi

  hdr "Name resolution"
  local ns; ns="$(scutil --dns 2>/dev/null | awk '/nameserver\[0\]/{print $3; exit}')"
  [ -n "$ns" ] && ok "resolver nameserver: $ns" || bad "no nameserver configured"
  if dns_works; then dnsok=1; ok "uncached lookup via 1.1.1.1 works"
  else bad "uncached lookup via 1.1.1.1 FAILS"; fi
  if [ -n "$(dig +time=3 +tries=1 +short www.wikipedia.org 2>/dev/null)" ]; then
    ok "system resolver works"
  else bad "system resolver FAILS"; fi
  pgrep -x mDNSResponder >/dev/null 2>&1 && ok "mDNSResponder is running" \
                                         || bad "mDNSResponder is NOT running"

  hdr "Raw reachability"
  if tcp_works; then tcpok=1; ok "TCP 1.1.1.1:443 reachable"
  else bad "TCP 1.1.1.1:443 unreachable"; fi

  # A very common and confusing case: the machine is fine, but THIS process is
  # inside a tunnel's isolation group and is being filtered by group.
  local mygid mygname
  mygid="$(id -g)"; mygname="$(id -gn)"
  case "$mygname" in
    apptun*|cldesk*|cgptvpn*)
      if [ "$tcpok" = 0 ]; then
        bad "this shell is in isolation group $mygname (gid $mygid) and IS being firewalled"
        act "the Mac may be fine; it is this process group that is blocked"
        act "to free the app that hosts you:  sudo $(dirname "$0")/tunnel-freehost.sh"
      else
        warn "this shell is in isolation group $mygname (gid $mygid) but egress still works"
        act "that means the tunnel guard is NOT enforcing on it"
      fi ;;
    *) ok "this shell is in an ordinary group ($mygname)" ;;
  esac

  hdr "Packet filter"
  if [ -z "$SUDO" ] || $SUDO -n true 2>/dev/null; then
    if $SUDO -n pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then
      ok "pf is ENABLED"
    else
      ok "pf is disabled (it cannot be blocking anything)"
    fi
    if $SUDO -n pfctl -s rules 2>/dev/null | grep -q 'anchor "com.apple/\*"'; then
      ok 'main ruleset references com.apple/* (anchors are evaluated)'
    else
      pf_anchor_missing=1
      warn 'main ruleset has NO com.apple/* anchor — loaded anchors are ignored'
    fi
    for a in $($SUDO -n pfctl -a com.apple -s Anchors 2>/dev/null); do
      local name="com.apple/$(basename "$a")"
      local rules; rules="$($SUDO -n pfctl -a "$name" -s rules 2>/dev/null)"
      [ -z "$rules" ] && continue
      if printf '%s\n' "$rules" | grep -E 'port = (53|853)' | grep -qv 'group'; then
        pf_blocks=$((pf_blocks + 1))
        bad "$name has a MACHINE-WIDE DNS block"
      else
        act "$name holds $(printf '%s\n' "$rules" | wc -l | tr -d ' ') rule(s), all group-scoped"
      fi
    done
    [ "$pf_blocks" -eq 0 ] && ok "no machine-wide DNS blocks found"
  else
    warn "pf inspection needs admin rights — re-run with sudo for the full picture"
  fi

  hdr "Proxy configuration (read only)"
  local se sh sp
  se="$(scutil --proxy 2>/dev/null | awk '/SOCKSEnable/{print $3; exit}')"
  sh="$(scutil --proxy 2>/dev/null | awk '/SOCKSProxy /{print $3; exit}')"
  sp="$(scutil --proxy 2>/dev/null | awk '/SOCKSPort/{print $3; exit}')"
  [ "$se" = "1" ] && ok "system SOCKS proxy: $sh:$sp" || ok "system SOCKS proxy: off"
  for f in "$HOME/.claude/settings.json" "$HOME/.codex/.env"; do
    [ -f "$f" ] || continue
    local port; port="$(grep -oE '127\.0\.0\.1:[0-9]+' "$f" 2>/dev/null | head -1 | cut -d: -f2)"
    [ -z "$port" ] && continue
    if tcp_probe 127.0.0.1 "$port" 2; then
      ok "$(basename "$f") -> 127.0.0.1:$port (alive)"
    else
      bad "$(basename "$f") -> 127.0.0.1:$port is DEAD; that app has no network"
    fi
  done

  hdr "Verdict"
  if [ "$dnsok" = 1 ] && [ "$tcpok" = 1 ]; then
    ok "networking looks healthy"
  elif [ "$pf_blocks" -gt 0 ]; then
    bad "CAUSE: $pf_blocks leftover machine-wide DNS block(s) in pf"
    act "run:  $(basename "$0") fix-dns"
  elif [ "$tcpok" = 0 ] && [ -z "$gw" ]; then
    bad "CAUSE: no default route / no DHCP lease"
    act "run:  $(basename "$0") renew-dhcp"
  elif [ "$tcpok" = 1 ] && [ "$dnsok" = 0 ]; then
    bad "CAUSE: raw TCP works but DNS does not — a resolver or DNS-port problem"
    act "run:  $(basename "$0") fix-dns    (then restore-pf if that is not enough)"
  else
    warn "no single cause identified. Work down: fix-dns, restore-pf, flush-pf, renew-dhcp"
  fi
  printf '\n   %sNothing above changed anything. This was a read-only report.%s\n\n' "$D" "$O"
}

# ------------------------------------------------------------------ fixes ---
cmd_fix_dns() {
  hdr "Removing machine-wide DNS blocks"
  local n=0
  for a in $($SUDO pfctl -a com.apple -s Anchors 2>/dev/null); do
    local name="com.apple/$(basename "$a")"
    if $SUDO pfctl -a "$name" -s rules 2>/dev/null | grep -E 'port = (53|853)' | grep -qv 'group'; then
      act "flushing $name"
      $SUDO pfctl -a "$name" -F rules >/dev/null 2>&1 && n=$((n + 1))
    fi
  done
  [ "$n" -gt 0 ] && ok "flushed $n anchor(s)" || ok "no offending anchors found"

  hdr "Flushing the resolver cache"
  $SUDO dscacheutil -flushcache 2>/dev/null && ok "dscacheutil cache flushed"
  $SUDO killall -HUP mDNSResponder 2>/dev/null && ok "mDNSResponder reloaded" \
    || warn "could not signal mDNSResponder"
  sleep 1
  hdr "Result"
  dns_works && ok "DNS resolves again" || bad "DNS still failing — try: restore-pf"
  tcp_works && ok "TCP works" || bad "TCP still failing"
}

cmd_restore_pf() {
  hdr "Restoring Apple's stock pf ruleset"
  if grep -qE '^[[:space:]]*(block|pass)' /etc/pf.conf 2>/dev/null; then
    bad "/etc/pf.conf contains filter rules — it is not the stock file. Not loading it."
    act "inspect it yourself, then decide"
    return 1
  fi
  ok "/etc/pf.conf is anchor declarations only"
  $SUDO pfctl -f /etc/pf.conf 2>&1 | sed 's/^/        /'
  ok "loaded"
  act "re-checking for anchors that this may have re-armed"
  cmd_fix_dns
}

cmd_flush_pf() {
  hdr "Flushing every pf rule and disabling pf"
  warn "this removes ALL packet-filter rules, including any this Mac needs"
  $SUDO pfctl -F all 2>&1 | sed 's/^/        /'
  $SUDO pfctl -d 2>&1 | sed 's/^/        /'
  sleep 1
  dns_works && ok "DNS resolves" || bad "DNS still failing"
  tcp_works && ok "TCP works" || bad "TCP still failing"
  act "pf is now off; reboot or 'restore-pf' to put the stock ruleset back"
}

cmd_renew_dhcp() {
  local dev="${1:-$(active_iface)}"
  [ -n "$dev" ] || { bad "could not determine the interface; pass one, e.g. renew-dhcp en0"; return 1; }
  local svc; svc="$(service_for_iface "$dev")"
  hdr "Renewing the DHCP lease on $dev${svc:+ ($svc)}"
  act "before: $(ipconfig getifaddr "$dev" 2>/dev/null || echo 'no address')"
  $SUDO ipconfig set "$dev" NONE 2>/dev/null && act "released"
  sleep 2
  $SUDO ipconfig set "$dev" DHCP 2>/dev/null && act "requesting a new lease..."
  local i=0
  while [ "$i" -lt 20 ]; do
    [ -n "$(ipconfig getifaddr "$dev" 2>/dev/null)" ] && break
    sleep 1; i=$((i + 1))
  done
  local ip; ip="$(ipconfig getifaddr "$dev" 2>/dev/null)"
  if [ -n "$ip" ]; then
    ok "new address: $ip"
    ok "gateway: $(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')"
  else
    bad "no address obtained — check the cable/Wi-Fi and the router"
  fi
  sleep 1
  dns_works && ok "DNS resolves" || warn "DNS still failing (try fix-dns)"
}

cmd_backup() {
  hdr "Backing up SystemConfiguration preferences"
  local stamp dest
  stamp="$(date '+%Y%m%d-%H%M%S')"
  dest="$BACKUP_DIR/$stamp"
  mkdir -p "$dest" || { bad "could not create $dest"; return 1; }
  local n=0
  for f in $SC_FILES; do
    if [ -f "$SC_DIR/$f" ]; then
      $SUDO cp -p "$SC_DIR/$f" "$dest/$f" 2>/dev/null && { act "saved $f"; n=$((n + 1)); }
    fi
  done
  $SUDO chown -R "$(id -un)" "$dest" 2>/dev/null || true
  ok "$n file(s) backed up to $dest"
  echo "$dest"
}

cmd_restore_backup() {
  hdr "Restoring a SystemConfiguration backup"
  local latest="${1:-$(ls -1d "$BACKUP_DIR"/*/ 2>/dev/null | tail -1)}"
  [ -n "$latest" ] && [ -d "$latest" ] || { bad "no backup found in $BACKUP_DIR"; return 1; }
  act "restoring from $latest"
  local n=0
  for f in $SC_FILES; do
    [ -f "$latest/$f" ] || continue
    $SUDO cp -p "$latest/$f" "$SC_DIR/$f" 2>/dev/null && { act "restored $f"; n=$((n + 1)); }
  done
  ok "$n file(s) restored"
  warn "reboot for the restored configuration to take effect"
}

cmd_reset_network() {
  hdr "Full network reset"
  if [ "${1:-}" != "--i-understand" ]; then
    bad "refusing without --i-understand"
    cat <<'EXPL'

   This removes the macOS network preference files. It will:
     - delete every configured network service (Wi-Fi, Ethernet, VPN entries)
     - forget saved Wi-Fi networks
     - require a REBOOT, after which macOS rebuilds them from scratch

   You almost certainly do NOT need this. In this project every "the Internet
   died" case so far has been a leftover pf anchor, which `fix-dns` clears in
   under a second. Try, in order:

       tunnel-netrescue.sh fix-dns
       tunnel-netrescue.sh restore-pf
       tunnel-netrescue.sh flush-pf
       tunnel-netrescue.sh renew-dhcp

   If you still want the reset, re-run:
       tunnel-netrescue.sh reset-network --i-understand

EXPL
    return 1
  fi
  local dest; dest="$(cmd_backup | tail -1)"
  ok "backup taken: $dest"
  for f in $SC_FILES; do
    [ -f "$SC_DIR/$f" ] || continue
    $SUDO rm -f "$SC_DIR/$f" && act "removed $f"
  done
  warn "REBOOT NOW. macOS will recreate the network configuration on next boot."
  act "to undo before rebooting:  $(basename "$0") restore-backup $dest"
}

case "${1:-diagnose}" in
  diagnose|"")     cmd_diagnose ;;
  fix-dns)         cmd_fix_dns ;;
  restore-pf)      cmd_restore_pf ;;
  flush-pf)        cmd_flush_pf ;;
  renew-dhcp)      shift; cmd_renew_dhcp "${1:-}" ;;
  backup)          cmd_backup >/dev/null; ;;
  restore-backup)  shift; cmd_restore_backup "${1:-}" ;;
  reset-network)   shift; cmd_reset_network "${1:-}" ;;
  -h|--help|help)  sed -n '2,30p' "$0" ;;
  *) echo "unknown command: $1" >&2; sed -n '6,18p' "$0" >&2; exit 2 ;;
esac
