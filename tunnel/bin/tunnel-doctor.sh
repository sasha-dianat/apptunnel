#!/bin/bash
# tunnel-doctor.sh — diagnose and clean up leftovers from tunnel launcher runs.
#
# Default mode is READ ONLY: it reports, it changes nothing.
# Pass --fix to remove orphans.
#
# It never touches DHCP, DNS servers, network service order, Wi-Fi, or the
# system proxy configuration. It only removes things the launchers created:
#   - temporary isolation groups (apptun*/cldesk*/cgptvpn*, gid 57000-57999)
#   - PF anchors created by the launchers
#   - orphaned http_to_socks.py bridge processes
#   - stale proxy keys in ~/.claude/settings.json and ~/.codex/.env

set -uo pipefail

FIX=0
LOGIN_USER_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fix) FIX=1; shift ;;
    --login-user) [ "$#" -ge 2 ] || { echo "--login-user requires a name" >&2; exit 2; }
                  LOGIN_USER_OVERRIDE="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# SUDO_USER is inherited and can even be "root" when this Mac's apps are
# launched through a sudo chain, so it must only be trusted when we are ACTUALLY
# root. Otherwise `id -un` is authoritative.
if [ "$(id -u)" -eq 0 ]; then
  LOGIN_USER="${LOGIN_USER_OVERRIDE:-${SUDO_USER:-}}"
  if [ -z "$LOGIN_USER" ] || [ "$LOGIN_USER" = root ]; then
    echo "Running as root requires --login-user <name>." >&2; exit 2
  fi
else
  LOGIN_USER="${LOGIN_USER_OVERRIDE:-$(id -un)}"
fi
LOGIN_HOME="$(/usr/bin/dscl . -read "/Users/$LOGIN_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
LOGIN_UID="$(/usr/bin/id -u "$LOGIN_USER" 2>/dev/null || true)"
LOGIN_GID="$(/usr/bin/id -g "$LOGIN_USER" 2>/dev/null || true)"
[ -d "$LOGIN_HOME" ] && [ -n "$LOGIN_UID" ] && [ -n "$LOGIN_GID" ] \
  || { echo "Could not resolve login user: $LOGIN_USER" >&2; exit 2; }
STATE_FILE="$LOGIN_HOME/.apptunnel/session.json"
SETTINGS_FILE="$LOGIN_HOME/.claude/settings.json"
CODEX_ENV_FILE="$LOGIN_HOME/.codex/.env"

# Liveness must be tested with ps, not `kill -0`. Sending even signal 0 to a
# process outside the caller's own session fails under a sandboxed shell, which
# made this script report live bridges and sessions as orphans.
alive() { [ -n "${1:-}" ] && ps -p "$1" >/dev/null 2>&1; }
PROBLEMS=0
CYA=$'\033[36m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; OFF=$'\033[0m'

hdr()  { printf '\n%s== %s ==%s\n' "$CYA" "$1" "$OFF"; }
good() { printf '   %sok%s   %s\n' "$GRN" "$OFF" "$1"; }
warn() { printf '   %s!!%s   %s\n' "$YEL" "$OFF" "$1"; PROBLEMS=$((PROBLEMS+1)); }
bad()  { printf '   %sXX%s   %s\n' "$RED" "$OFF" "$1"; PROBLEMS=$((PROBLEMS+1)); }
act()  { printf '   %s->%s   %s\n' "$DIM" "$OFF" "$1"; }

printf '%stunnel-doctor%s  %s\n' "$CYA" "$OFF" "$( [ "$FIX" = 1 ] && echo 'MODE: FIX' || echo 'MODE: read-only (pass --fix to repair)')"

# ------------------------------------------------------------ live session --
hdr "Active session"
LIVE_PID=""
if [ -f "$STATE_FILE" ]; then
  LIVE_PID="$(/usr/bin/python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("pid",""))
except Exception: pass' "$STATE_FILE" 2>/dev/null)"
fi
if alive "$LIVE_PID"; then
  good "tunnel-lock.sh running (pid $LIVE_PID) - its resources will be left alone"
else
  LIVE_PID=""
  # Legacy scripts kept no state file; detect them by command line.
  # Match only a shell *running* a launcher script - not shells that merely
  # mention one (this doctor's own invocation would otherwise match itself).
  legacy="$(ps -axo pid=,command= | awk -v self="$$" '
      $1 != self &&
      $0 ~ /\/bin\/(ba)?sh .*(veepn-shadowsocks-lock|tunnel-lock).*\.sh/ &&
      $0 !~ /(ba)?sh -c/ {print}' || true)"
  if [ -n "$legacy" ]; then
    printf '%s\n' "$legacy" | while IFS= read -r l; do good "launcher running: $l"; done
    LIVE_PID="$(printf '%s\n' "$legacy" | awk '{print $1}' | head -1)"
  else
    good "no launcher session running"
  fi
fi

LIVE_GID=""
[ -n "$LIVE_PID" ] && LIVE_GID="$(ps -o gid= -p "$LIVE_PID" 2>/dev/null | awk '{print $1}')"

# ------------------------------------------------------- orphaned groups ----
hdr "Temporary isolation groups"
ORPHAN_GROUPS=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  gname="$(printf '%s' "$line" | awk '{print $1}')"
  ggid="$(printf '%s' "$line" | awk '{print $2}')"
  case "$gname" in apptun*|cldesk*|cgptvpn*) ;; *) continue ;; esac
  # Is any live process still using this gid?
  users="$(ps -axo gid= | awk -v g="$ggid" '$1==g' | wc -l | tr -d ' ')"
  if [ "$ggid" = "$LIVE_GID" ] || [ "${users:-0}" -gt 0 ]; then
    good "$gname (gid $ggid) in use by $users process(es) - keeping"
  else
    bad "$gname (gid $ggid) orphaned - no process uses it"
    ORPHAN_GROUPS+=("$gname")
  fi
done < <(dscl . -list /Groups PrimaryGroupID 2>/dev/null | awk '$2>=57000 && $2<58000')
[ "${#ORPHAN_GROUPS[@]}" -eq 0 ] && good "no orphaned groups"

if [ "$FIX" = 1 ] && [ "${#ORPHAN_GROUPS[@]}" -gt 0 ]; then
  for g in "${ORPHAN_GROUPS[@]}"; do
    act "removing group $g"
    sudo /usr/sbin/dseditgroup -o edit -d "$LOGIN_USER" -t user "$g" >/dev/null 2>&1
    sudo /usr/sbin/dseditgroup -o delete "$g" >/dev/null 2>&1 && good "deleted $g" || bad "could not delete $g"
  done
fi

# --------------------------------------------------------- orphaned bridges -
hdr "HTTP->SOCKS bridge processes"
ORPHAN_BRIDGES=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  bpid="$(printf '%s' "$line" | awk '{print $1}')"
  bppid="$(ps -o ppid= -p "$bpid" 2>/dev/null | awk '{print $1}')"
  if alive "$bppid" && [ "$bppid" != "1" ]; then
    good "bridge pid $bpid owned by live launcher pid $bppid - keeping"
  else
    bad "bridge pid $bpid orphaned (parent gone)"
    ORPHAN_BRIDGES+=("$bpid")
  fi
done < <(ps -axo pid=,command= | grep 'http_to_socks.py' | grep -v grep)
[ "${#ORPHAN_BRIDGES[@]}" -eq 0 ] && good "no orphaned bridges"

if [ "$FIX" = 1 ] && [ "${#ORPHAN_BRIDGES[@]}" -gt 0 ]; then
  for b in "${ORPHAN_BRIDGES[@]}"; do
    act "killing orphaned bridge $b"
    kill -TERM "$b" 2>/dev/null; sleep 0.3; kill -KILL "$b" 2>/dev/null
    alive "$b" && bad "bridge $b survived" || good "bridge $b stopped"
  done
fi

# --------------------------------------------------------------- PF state ---
hdr "Packet filter"
if sudo -n true 2>/dev/null; then
  PFSUDO="sudo -n"
elif [ "$FIX" = 1 ]; then
  sudo -v && PFSUDO="sudo" || PFSUDO=""
else
  PFSUDO=""
fi

if [ -z "$PFSUDO" ]; then
  warn "PF state needs root to inspect. Run: sudo pfctl -s Anchors -v"
  warn "and check for machine-wide DNS blocks: sudo pfctl -sr | grep 'port = 53'"
else
  if $PFSUDO pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then
    good "PF is enabled"
  else
    good "PF is disabled (no launcher rules can be in effect)"
  fi
  if $PFSUDO pfctl -s rules 2>/dev/null | grep -q 'anchor "com.apple/\*"'; then
    good 'main ruleset references com.apple/* (anchors are evaluated)'
  else
    bad 'main ruleset is missing anchor "com.apple/*" - loaded anchors do NOTHING'
    act 'repair with: sudo pfctl -f /etc/pf.conf'
  fi
  anchors="$($PFSUDO pfctl -a com.apple -s Anchors 2>/dev/null | grep -Ei 'apptunnel|cldesktop-vpn|chatgpt-codex-vpn' || true)"
  if [ -n "$anchors" ]; then
    printf '%s\n' "$anchors" | while IFS= read -r a; do printf '   found anchor: %s\n' "$a"; done
    for a in $anchors; do
      full="com.apple/$(basename "$a")"
      rules="$($PFSUDO pfctl -a "$full" -s rules 2>/dev/null || true)"
      [ -z "$rules" ] && { good "$full is empty"; continue; }
      # A port-53/853 rule WITHOUT a `group` clause blocks DNS for the whole
      # Mac, not just the guarded apps. Group-scoped rules are legitimate.
      if printf '%s\n' "$rules" | grep -E 'port = (53|853)' | grep -qv 'group'; then
        bad "$full has a MACHINE-WIDE DNS block - this is what kills your Internet"
        act "disarm with: \"$(dirname "$0")/tunnel-dnsguard.sh\" --fix"
      else
        warn "$full still holds rules"
      fi
      if [ "$FIX" = 1 ] && [ "$full" != "com.apple/apptunnel" -o -z "$LIVE_PID" ]; then
        act "flushing $full"
        $PFSUDO pfctl -a "$full" -F rules >/dev/null 2>&1 && good "flushed $full" || bad "could not flush $full"
      fi
    done
  else
    good "no launcher PF anchors present"
  fi
fi

# ---------------------------------------------------- configuration access --
hdr "Configuration ownership"
for config_path in "$SETTINGS_FILE" "$CODEX_ENV_FILE"; do
  [ -e "$config_path" ] || { good "$config_path does not exist"; continue; }
  if [ -L "$config_path" ]; then
    bad "$config_path is a symbolic link; refusing automatic repair"
    continue
  fi
  config_owner="$(/usr/bin/stat -f '%u' "$config_path" 2>/dev/null || true)"
  config_mode="$(/usr/bin/stat -f '%Lp' "$config_path" 2>/dev/null || true)"
  if [ "$config_owner" = "$LOGIN_UID" ] && [ -r "$config_path" ] && [ -w "$config_path" ]; then
    good "$config_path is owned and accessible by $LOGIN_USER (mode $config_mode)"
  else
    bad "$config_path owner uid=${config_owner:-unknown}, expected $LOGIN_UID; user access is broken"
    if [ "$FIX" = 1 ]; then
      act "returning $config_path to $LOGIN_USER with mode 600"
      if [ "$(id -u)" -eq 0 ]; then
        /usr/sbin/chown "$LOGIN_UID:$LOGIN_GID" "$config_path" && /bin/chmod 600 "$config_path"
      else
        sudo /usr/sbin/chown "$LOGIN_UID:$LOGIN_GID" "$config_path" && /bin/chmod 600 "$config_path"
      fi
      [ "$(/usr/bin/stat -f '%u' "$config_path" 2>/dev/null)" = "$LOGIN_UID" ] \
        && good "ownership repaired" || bad "could not repair ownership"
    fi
  fi
done

# ------------------------------------------------------ stale app proxy cfg -
hdr "Leftover proxy configuration"
check_proxy_file() {
  local label="$1" port="$2"
  [ -n "$port" ] || return 0
  if nc -z -w 2 127.0.0.1 "$port" >/dev/null 2>&1; then
    warn "$label points at 127.0.0.1:$port (alive, but it dies with the session)"
  else
    bad "$label points at 127.0.0.1:$port which is DEAD - that app has no network"
  fi
}

CLAUDE_PORT="$(/usr/bin/python3 -c '
import json,re,sys
p=sys.argv[1]
try:
    v=json.load(open(p)).get("env",{}).get("HTTP_PROXY","")
except Exception:
    v=""
m=re.search(r":(\d+)",v); print(m.group(1) if m else "")' "$SETTINGS_FILE" 2>/dev/null)"
if [ -e "$SETTINGS_FILE" ] && [ ! -r "$SETTINGS_FILE" ]; then
  warn "~/.claude/settings.json could not be inspected until ownership is repaired"
elif [ -n "$CLAUDE_PORT" ]; then
  check_proxy_file "~/.claude/settings.json" "$CLAUDE_PORT"
else
  good "~/.claude/settings.json has no proxy override"
fi

CODEX_PORT="$(/usr/bin/python3 -c '
import re,sys
p=sys.argv[1]
try: t=open(p,encoding="utf-8").read()
except Exception: t=""
m=re.search(r"^HTTP_PROXY=.*?:(\d+)",t,re.M); print(m.group(1) if m else "")' "$CODEX_ENV_FILE" 2>/dev/null)"
if [ -e "$CODEX_ENV_FILE" ] && [ ! -r "$CODEX_ENV_FILE" ]; then
  warn "~/.codex/.env could not be inspected until ownership is repaired"
elif [ -n "$CODEX_PORT" ]; then
  check_proxy_file "~/.codex/.env" "$CODEX_PORT"
else
  good "~/.codex/.env has no proxy override"
fi

if [ "$FIX" = 1 ] && [ -z "$LIVE_PID" ]; then
  if [ -n "$CLAUDE_PORT" ]; then
    act "removing proxy keys from ~/.claude/settings.json (backup: .bak)"
    /usr/bin/python3 -c '
import json,shutil,sys
p=sys.argv[1]
shutil.copy2(p,p+".bak")
d=json.load(open(p)); e=d.get("env",{})
for k in ("HTTP_PROXY","HTTPS_PROXY","http_proxy","https_proxy","NO_PROXY","no_proxy"):
    e.pop(k,None)
if not e: d.pop("env",None)
json.dump(d,open(p,"w"),indent=2); open(p,"a").write("\n")
print("cleaned")' "$SETTINGS_FILE" && good "settings.json cleaned" || bad "could not clean settings.json"
  fi
  if [ -n "$CODEX_PORT" ]; then
    act "removing proxy keys from ~/.codex/.env (backup: .bak)"
    /usr/bin/python3 -c '
import re,shutil,sys
p=sys.argv[1]
shutil.copy2(p,p+".bak")
keys={"HTTP_PROXY","HTTPS_PROXY","http_proxy","https_proxy","NO_PROXY","no_proxy","ALL_PROXY","all_proxy"}
pat=re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=")
out=[]
for line in open(p,encoding="utf-8"):
    if line.startswith("# Temporary VeePN") or line.startswith("# apptunnel"): continue
    m=pat.match(line)
    if m and m.group(1) in keys: continue
    out.append(line)
while out and not out[0].strip(): out.pop(0)
open(p,"w",encoding="utf-8").writelines(out)
print("cleaned")' "$CODEX_ENV_FILE" && good ".codex/.env cleaned" || bad "could not clean .codex/.env"
  fi
fi

# ------------------------------------------------------- untouched by us ----
# ------------------------------------------------------- VPN endpoint -------
hdr "VPN / SOCKS endpoint"

tcp_probe() {  # host port [seconds]  - hard timeout; nc -w does not cap a PF drop
  /usr/bin/python3 -c '
import socket, sys
s = socket.socket(); s.settimeout(float(sys.argv[3]))
try: s.connect((sys.argv[1], int(sys.argv[2]))); sys.exit(0)
except Exception: sys.exit(1)
finally: s.close()
' "$1" "$2" "${3:-2}"
}

proxy_dump="$(/usr/sbin/scutil --proxy 2>/dev/null || true)"
sx_en="$(printf '%s\n' "$proxy_dump" | awk '/SOCKSEnable[[:space:]]*:/{print $3; exit}')"
sx_host="$(printf '%s\n' "$proxy_dump" | awk '/SOCKSProxy[[:space:]]*:/{print $3; exit}')"
sx_port="$(printf '%s\n' "$proxy_dump" | awk '/SOCKSPort[[:space:]]*:/{print $3; exit}')"

if [ "$sx_en" != "1" ]; then
  bad "system SOCKS proxy is DISABLED - the VPN is not connected in Shadowsocks mode"
  act "connect VeePN and choose the Shadowsocks protocol, then re-run"
else
  good "system SOCKS proxy advertised at ${sx_host:-?}:${sx_port:-?}"

  if [ -n "$sx_host" ] && [ -n "$sx_port" ] && tcp_probe "$sx_host" "$sx_port" 3; then
    good "the advertised endpoint is listening"
    exit_ip="$(/usr/bin/curl -4fsS --socks5-hostname "$sx_host:$sx_port" \
                 --connect-timeout 6 --max-time 15 https://api.ipify.org 2>/dev/null || true)"
    [ -z "$exit_ip" ] && exit_ip="$(/usr/bin/curl -4fsS --socks5-hostname "$sx_host:$sx_port" \
                 --connect-timeout 6 --max-time 15 https://ifconfig.me/ip 2>/dev/null || true)"
    if printf '%s' "$exit_ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
      good "SOCKS5 works end to end - exit IP $exit_ip"
    else
      bad "the endpoint accepts connections but no request completed through it"
      act "the VPN is half-connected; disconnect and reconnect it"
    fi
  else
    bad "NOTHING is listening on the advertised endpoint ${sx_host:-?}:${sx_port:-?}"
    # The exact failure that made phase 2 unusable: the client moved its
    # listener but the advertised port (or a hardcoded one) was stale.
    found=""
    for cand in 1080 1180 1081 7890 1086 10808; do
      [ "$cand" = "$sx_port" ] && continue
      if tcp_probe "${sx_host:-127.0.0.1}" "$cand" 1; then found="$cand"; break; fi
    done
    if [ -n "$found" ]; then
      bad "a SOCKS listener IS running on port $found instead - the advertised port is stale"
      act "this mismatch is why a connect can fail no matter how often you reconnect the VPN"
      act "the launcher now auto-detects and will use $found; to pin it: --socks-port $found"
    else
      act "no listener found on any common SOCKS port either - the VPN is not running"
    fi
  fi
fi

# ------------------------------------------------------- app/session state --
hdr "Tunnel app state"

# Stale session lock: a lock whose owner is gone blocks the next connect.
if [ -f "$STATE_FILE" ]; then
  lock_pid="$(/usr/bin/python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("pid",""))
except Exception: pass' "$STATE_FILE" 2>/dev/null)"
  if alive "$lock_pid"; then
    good "session lock held by live launcher pid $lock_pid"
  else
    bad "stale session lock (pid ${lock_pid:-?} is gone) - it would block the next connect"
    if [ "$FIX" = 1 ]; then
      rm -f "$STATE_FILE" && good "removed the stale lock"
    fi
  fi
else
  good "no session lock"
fi

# Stale test protection: armed, but the app it protects is no longer running.
GUARD_FILE="$LOGIN_HOME/.apptunnel/protected.json"
if [ -f "$GUARD_FILE" ]; then
  ghost="$(/usr/bin/python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("host_bundle",""))
except Exception: pass' "$GUARD_FILE" 2>/dev/null)"
  live_host=""
  [ -n "$ghost" ] && live_host="$(ps -axo command= | grep -F "$ghost/Contents/MacOS/" | grep -v grep | head -1)"
  if [ -n "$live_host" ]; then
    warn "TEST MODE is on: $(basename "${ghost:-?}") is protected and will NOT be tunnelled"
    act "turn it off with the TEST button, or: $(dirname "$0")/tunnel-testkit.sh clear"
  else
    bad "stale TEST MODE: $(basename "${ghost:-?}") is protected but is not running"
    act "this silently removes that app from every connect"
    if [ "$FIX" = 1 ]; then
      rm -f "$GUARD_FILE" && good "cleared the stale protection"
    fi
  fi
else
  good "test protection is off (normal behaviour)"
fi

# Config files must belong to the login user; a root-owned one locks the app out.
for f in "$SETTINGS_FILE" "$CODEX_ENV_FILE"; do
  [ -e "$f" ] || continue
  owner="$(/usr/bin/stat -f '%u' "$f" 2>/dev/null || true)"
  if [ "$owner" = "$LOGIN_UID" ]; then
    good "$(basename "$f") is owned by $LOGIN_USER"
  else
    bad "$(basename "$f") is owned by uid ${owner:-?}, not $LOGIN_USER - the app cannot write it"
    if [ "$FIX" = 1 ]; then
      sudo /usr/sbin/chown "$LOGIN_UID:$LOGIN_GID" "$f" 2>/dev/null \
        && good "ownership repaired" || bad "could not repair ownership"
    fi
  fi
done

# Concurrent launchers cannot both own the firewall state.
# Count SESSIONS, not processes: a bash subshell (the sudo keepalive, process
# substitutions) inherits its parent's command line, so one session shows up
# as three. A session is a tunnel-lock whose parent is not also a tunnel-lock.
running="$(/usr/bin/python3 -c '
import re, subprocess
out = subprocess.run(["ps","-axo","pid=,ppid=,command="],
                     capture_output=True, text=True).stdout
locks = {}
for line in out.splitlines():
    m = re.match(r"\s*(\d+)\s+(\d+)\s+(.*)", line)
    if not m: continue
    pid, ppid, cmd = m.group(1), m.group(2), m.group(3)
    if "tunnel-lock.sh" in cmd and "sh -c" not in cmd:
        locks[pid] = ppid
roots = [p for p, pp in locks.items() if pp not in locks]
print(len(roots))
' 2>/dev/null || echo 0)"
if [ "${running:-0}" -gt 1 ]; then
  bad "$running concurrent tunnel sessions are running - they fight over the firewall state"
  act "stop them, then connect once: $(dirname "$0")/tunnel-freehost.sh"
else
  good "$running launcher session(s) - no conflict"
fi

# An unbounded event log slows the app's animation polling.
EV="$LOGIN_HOME/.apptunnel/events.jsonl"
if [ -f "$EV" ]; then
  evsz="$(wc -c < "$EV" | tr -d ' ')"
  if [ "${evsz:-0}" -gt 1000000 ]; then
    warn "event log is $((evsz/1024)) KB - the app re-reads it constantly"
    [ "$FIX" = 1 ] && { : > "$EV"; good "event log truncated"; }
  else
    good "event log size is fine"
  fi
fi

hdr "System network settings (read-only check - never modified by these tools)"
sys_socks="$(scutil --proxy 2>/dev/null | awk '/SOCKSEnable/{e=$3}/SOCKSProxy /{h=$3}/SOCKSPort/{p=$3}END{print (e=="1"? h":"p : "disabled")}')"
good "system SOCKS proxy: $sys_socks"
good "DNS servers: $(scutil --dns 2>/dev/null | awk '/nameserver\[0\]/{print $3; exit}')"
good "default route: $(route -n get default 2>/dev/null | awk '/gateway/{print $2}')"
printf '   %sThese tools only read the above. DHCP and network services are never changed.%s\n' "$DIM" "$OFF"

hdr "Summary"
if [ "$PROBLEMS" -eq 0 ]; then
  printf '   %sClean. Nothing left behind.%s\n\n' "$GRN" "$OFF"
elif [ "$FIX" = 1 ]; then
  printf '   %s%s issue(s) processed. Re-run to confirm.%s\n\n' "$YEL" "$PROBLEMS" "$OFF"
else
  printf '   %s%s issue(s) found. Re-run with --fix to repair.%s\n\n' "$YEL" "$PROBLEMS" "$OFF"
fi
exit 0
