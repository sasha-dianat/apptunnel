#!/bin/bash
# claude-desktop-veepn-shadowsocks-lock-v5.sh
#
# Strict fail-closed launcher for Claude Desktop / Claude Code GUI on macOS.
# Designed for VeePN Shadowsocks exposing SOCKS5 at 127.0.0.1:1080.
#
# Protection layers:
#   1. Claude Desktop + Local Code sessions receive HTTP(S)_PROXY pointing to
#      a localhost HTTP CONNECT -> VeePN SOCKS5 bridge.
#   2. Claude Desktop is launched under a temporary effective Unix group.
#   3. PF blocks that group's direct TCP/UDP egress on physical interfaces.
#   4. ~/.claude/settings.json is temporarily patched so Desktop Local sessions
#      receive the proxy variables even if Desktop does not pass its whole
#      process environment to the Code engine.
#   5. Physical DNS/DoT is blocked while the protected session is active; the
#      proxy bridge uses SOCKS5 remote DNS instead.
#
# The script restores the Claude settings keys, PF anchor, temporary group,
# and bridge when Claude Desktop exits.
#
# IMPORTANT:
#   - Use LOCAL Code sessions for this local containment guarantee.
#   - Do not authorize sudo/root network commands from Claude.
#   - Remote/Cowork execution occurs on remote infrastructure and is outside
#     this Mac-local egress boundary.

set -euo pipefail

VERSION="5.4"
SOCKS_HOST="127.0.0.1"
SOCKS_PORT="1080"
CHECK_URL="https://api.ipify.org"
ANCHOR="com.apple/cldesktop-vpn-$$"
GROUP_NAME="cldesk$$"
GROUP_GID=""
PF_TOKEN=""
PF_ENABLED_BY_US=0
GUARD_INSTALLED=0
GROUP_CREATED=0
SETTINGS_PATCHED=0
APP_WRAPPER_PID=""
CLAUDE_MAIN_PID=""
BRIDGE_PID=""
BRIDGE_PORT=""
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/cldesktop-vpn.XXXXXX")"
BRIDGE_SCRIPT="$TMPROOT/http_to_socks.py"
BRIDGE_PORT_FILE="$TMPROOT/bridge.port"
BRIDGE_LOG="$TMPROOT/bridge.log"
PF_RULES="$TMPROOT/pf.rules"
SETTINGS_STATE="$TMPROOT/settings-state.json"
SETTINGS_FILE="$HOME/.claude/settings.json"
GUI_ROOT_MODE=0
if [ "$EUID" -eq 0 ] && [ "${VEEPN_GUARDIAN_GUI:-0}" = "1" ]; then
  GUI_ROOT_MODE=1
  LOGIN_USER="${VEEPN_GUARDIAN_LOGIN_USER:-}"
  LOGIN_UID="${VEEPN_GUARDIAN_LOGIN_UID:-}"
  LOGIN_GID="${VEEPN_GUARDIAN_LOGIN_GID:-}"
  [ -n "$LOGIN_USER" ] && [ -n "$LOGIN_UID" ] && [ -n "$LOGIN_GID" ] || {
    printf '\nERROR: Guardian login identity is incomplete.\n' >&2
    exit 1
  }
else
  LOGIN_USER="$(id -un)"
  LOGIN_UID="$(id -u)"
  LOGIN_GID="$(id -g)"
fi
LOGIN_HOME="$HOME"
ORIGINAL_PATH="$PATH"
PHYSICAL_IFS=()
APP_PATH=""
APP_EXEC=""
GUARDIAN_STOP_FILE="${VEEPN_GUARDIAN_STOP_FILE:-}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
guardian_stop_requested() { [ -n "$GUARDIAN_STOP_FILE" ] && [ -f "$GUARDIAN_STOP_FILE" ]; }
exit_if_guardian_stop_requested() {
  if guardian_stop_requested; then
    log "Authenticated cleanup request detected; stopping before the next launch phase."
    exit 0
  fi
}


# Return only the actual Claude Desktop main executable, not crash reporters,
# stale helpers, or unrelated command lines containing the bundle path.
claude_main_pids() {
  ps -axo pid=,command= 2>/dev/null | awk -v exe="$APP_EXEC" '
    {
      pid=$1
      $1=""
      sub(/^[[:space:]]+/, "", $0)
      cmd=$0
      if (cmd == exe || index(cmd, exe " ") == 1) print pid
    }'
}

# Return every process whose executable command lives inside Claude.app.
claude_bundle_pids() {
  ps -axo pid=,command= 2>/dev/null | awk -v prefix="$APP_PATH/Contents/" '
    {
      pid=$1
      $1=""
      sub(/^[[:space:]]+/, "", $0)
      cmd=$0
      if (index(cmd, prefix) == 1) print pid
    }'
}

isolation_group_pids() {
  [ -n "${GROUP_GID:-}" ] || return 0
  ps -axo pid=,gid=,user= 2>/dev/null | awk \
    -v gid="$GROUP_GID" -v user="$LOGIN_USER" '
      $1 ~ /^[0-9]+$/ && $2 == gid && $3 == user { print $1 }
    '
}

purge_stale_claude_processes() {
  local pids=""
  local remaining=""
  local pid=""
  local i=0

  pids="$(claude_bundle_pids)"
  [ -n "$pids" ] || return 0
  log "Stopping stale Claude bundle helper process(es): $(printf '%s\n' "$pids" | tr '\n' ' ')"
  for pid in $pids; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  while [ "$i" -lt 30 ]; do
    remaining="$(claude_bundle_pids)"
    [ -z "$remaining" ] && return 0
    sleep 0.1
    i=$((i+1))
  done
  for pid in $remaining; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  i=0
  while [ "$i" -lt 20 ]; do
    [ -z "$(claude_bundle_pids)" ] && return 0
    sleep 0.1
    i=$((i+1))
  done
  log "Remaining Claude bundle PID(s): $(claude_bundle_pids | tr '\n' ' ')"
  return 1
}

drain_isolation_group() {
  local pids=""
  local remaining=""
  local pid=""
  local i=0

  pids="$(isolation_group_pids)"
  [ -n "$pids" ] || return 0
  log "Stopping remaining Claude isolation-group process(es): $(printf '%s\n' "$pids" | tr '\n' ' ')"
  for pid in $pids; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  while [ "$i" -lt 30 ]; do
    remaining="$(isolation_group_pids)"
    [ -z "$remaining" ] && return 0
    sleep 0.1
    i=$((i+1))
  done
  for pid in $remaining; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  i=0
  while [ "$i" -lt 20 ]; do
    [ -z "$(isolation_group_pids)" ] && return 0
    sleep 0.1
    i=$((i+1))
  done
  log "WARNING: Claude isolation-group process(es) did not exit: $(isolation_group_pids | tr '\n' ' ')"
  return 1
}

# Print PID plus every descendant PID of a root process.
# This lets us audit only the process tree actually launched inside our
# protected boundary instead of every stale Claude helper on the machine.
descendant_pids() {
  local root="$1"

  # On macOS/BSD ps, use separate -o arguments.  The previous
  # `pid=,ppid=` form produced malformed output on this Monterey machine.
  ps -A -o pid= -o ppid= 2>/dev/null | awk -v root="$root" '
    {
      p=$1
      parent=$2
      if (p ~ /^[0-9]+$/ && parent ~ /^[0-9]+$/) {
        pid[n]=p
        ppid[n]=parent
        n++
      }
    }
    END {
      wanted[root]=1
      changed=1
      while (changed) {
        changed=0
        for (i=0; i<n; i++) {
          if (wanted[ppid[i]] && !wanted[pid[i]]) {
            wanted[pid[i]]=1
            changed=1
          }
        }
      }
      for (i=0; i<n; i++) {
        if (wanted[pid[i]]) print pid[i]
      }
      if (wanted[root]) print root
    }' | awk 'NF && !seen[$0]++'
}

usage() {
  cat <<'USAGE'
Usage:
  claude-desktop-veepn-shadowsocks-lock-v5.sh [options]

Options:
  --physical-if IFACE   Physical interface to guard. May be repeated.
  --socks-host HOST     VeePN SOCKS5 host (default 127.0.0.1)
  --socks-port PORT     VeePN SOCKS5 port (default 1080)
  --check-url URL       HTTPS URL used for protected-path verification.
  --app PATH            Claude.app path if not in /Applications or ~/Applications.
  -h, --help            Show this help.

Normal use:
  1. Connect VeePN using Shadowsocks.
  2. Fully quit any already-running Claude Desktop instance.
  3. Run this script.
  4. Use Claude Desktop -> Code -> Local.

Exit Claude Desktop normally when finished. Cleanup is automatic.
USAGE
}

bounded_kill() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; return 0; }
  kill -TERM "$pid" 2>/dev/null || true
  local i=0
  while [ "$i" -lt 25 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 0.1
    i=$((i+1))
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

restore_settings() {
  (( SETTINGS_PATCHED )) || return 0
  [ -f "$SETTINGS_STATE" ] || return 0

  /usr/bin/python3 - "$SETTINGS_FILE" "$SETTINGS_STATE" <<'PY' >/dev/null 2>&1 || true
import json, os, sys, tempfile
settings_path, state_path = sys.argv[1:3]

try:
    with open(state_path, "r") as f:
        state = json.load(f)
except Exception:
    raise SystemExit(0)

if os.path.exists(settings_path):
    try:
        with open(settings_path, "r") as f:
            data = json.load(f)
    except Exception:
        raise SystemExit(0)
else:
    data = {}

if not isinstance(data, dict):
    raise SystemExit(0)
env = data.get("env")
if not isinstance(env, dict):
    env = {}
    data["env"] = env

for key, info in state.get("keys", {}).items():
    if info.get("present"):
        env[key] = info.get("value", "")
    else:
        env.pop(key, None)

if state.get("env_was_absent") and not env:
    data.pop("env", None)

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".settings.restore.", dir=os.path.dirname(settings_path))
try:
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, settings_path)
finally:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
PY
  if [ "$GUI_ROOT_MODE" -eq 1 ] && [ -e "$SETTINGS_FILE" ]; then
    chown "$LOGIN_UID:$LOGIN_GID" "$SETTINGS_FILE" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP

  if [ -n "${CLAUDE_MAIN_PID:-}" ] && kill -0 "$CLAUDE_MAIN_PID" 2>/dev/null; then
    log "Stopping protected Claude Desktop main process."
    bounded_kill "$CLAUDE_MAIN_PID"
  fi
  if [ -n "${APP_WRAPPER_PID:-}" ] && kill -0 "$APP_WRAPPER_PID" 2>/dev/null; then
    log "Stopping protected Claude Desktop process wrapper."
    bounded_kill "$APP_WRAPPER_PID"
  fi

  drain_isolation_group || true

  restore_settings

  if [ -n "${BRIDGE_PID:-}" ]; then
    log "Stopping localhost HTTP->SOCKS bridge."
    bounded_kill "$BRIDGE_PID"
  fi

  if (( GUARD_INSTALLED )); then
    log "Removing PF anchor $ANCHOR."
    sudo -n pfctl -a "$ANCHOR" -F rules >/dev/null 2>&1 || true
  fi

  if (( PF_ENABLED_BY_US )); then
    if [ -n "$PF_TOKEN" ]; then
      sudo -n pfctl -X "$PF_TOKEN" >/dev/null 2>&1 || true
    else
      sudo -n pfctl -d >/dev/null 2>&1 || true
    fi
  fi

  if (( GROUP_CREATED )); then
    log "Removing temporary isolation group $GROUP_NAME."
    sudo -n /usr/sbin/dseditgroup -o edit -d "$LOGIN_USER" -t user "$GROUP_NAME" >/dev/null 2>&1 || true
    sudo -n /usr/sbin/dseditgroup -o delete "$GROUP_NAME" >/dev/null 2>&1 || true
  fi

  rm -rf "$TMPROOT" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT INT TERM HUP
exit_if_guardian_stop_requested

while [ "$#" -gt 0 ]; do
  case "$1" in
    --physical-if)
      [ "$#" -ge 2 ] || die "--physical-if requires an interface"
      PHYSICAL_IFS+=("$2"); shift 2 ;;
    --socks-host)
      [ "$#" -ge 2 ] || die "--socks-host requires a host"
      SOCKS_HOST="$2"; shift 2 ;;
    --socks-port)
      [ "$#" -ge 2 ] || die "--socks-port requires a port"
      SOCKS_PORT="$2"; shift 2 ;;
    --check-url)
      [ "$#" -ge 2 ] || die "--check-url requires a URL"
      CHECK_URL="$2"; shift 2 ;;
    --app)
      [ "$#" -ge 2 ] || die "--app requires a Claude.app path"
      APP_PATH="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "Unknown option: $1" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "This launcher is for macOS only."
if [ "$EUID" -eq 0 ] && [ "$GUI_ROOT_MODE" -ne 1 ]; then
  die "Root launch is accepted only through VeePN Guardian's macOS authorization flow."
fi

for cmd in pfctl curl networksetup ifconfig sudo id awk grep python3 nc ps pgrep osascript; do
  command -v "$cmd" >/dev/null 2>&1 || die "Required command '$cmd' was not found."
done
[ -x /usr/sbin/dseditgroup ] || die "dseditgroup was not found."
[ -x /usr/bin/dscl ] || die "dscl was not found."

if [ -z "$APP_PATH" ]; then
  if [ -d "/Applications/Claude.app" ]; then
    APP_PATH="/Applications/Claude.app"
  elif [ -d "$HOME/Applications/Claude.app" ]; then
    APP_PATH="$HOME/Applications/Claude.app"
  else
    die "Claude.app was not found. Use --app /path/to/Claude.app."
  fi
fi

APP_EXEC="$APP_PATH/Contents/MacOS/Claude"
[ -x "$APP_EXEC" ] || die "Claude executable not found at: $APP_EXEC"

log "Claude Desktop/VeePN Shadowsocks fail-closed GUI launcher v$VERSION"
log "Claude app: $APP_PATH"
log "Login user: $LOGIN_USER (uid=$LOGIN_UID)"

cat <<EOF

Required state:
  VeePN protocol : Shadowsocks
  VeePN status   : Connected

This launcher protects the Claude Desktop app and LOCAL Claude Code GUI sessions.

It will:
  * explicitly proxy Local Code via VeePN's SOCKS5 endpoint,
  * deny Claude's direct physical-interface TCP/UDP with PF,
  * temporarily inject proxy variables into ~/.claude/settings.json,
  * block physical DNS/DoT while the protected session is active,
  * restore all temporary changes when Claude Desktop exits.

Do not authorize sudo/root network commands from a Local Code session.
EOF

if [ -t 0 ]; then
  read -r -p "Type YES after confirming VeePN Shadowsocks is connected: " answer
  [ "$answer" = "YES" ] || die "Confirmation not received."
fi

# Claude's main executable must not already be running, because LaunchServices
# could reuse a pre-existing process outside our protected group. Detached
# bundle helpers are purged after the visible app finishes its normal quit.
if [ -n "$(claude_main_pids)" ]; then
  log "Claude Desktop main process is already running; requesting a clean quit."
  if [ "$GUI_ROOT_MODE" -eq 1 ]; then
    /bin/launchctl asuser "$LOGIN_UID" /usr/bin/sudo -n -u "$LOGIN_USER" \
      /usr/bin/osascript -e 'tell application "Claude" to quit' >/dev/null 2>&1 || true
  else
    /usr/bin/osascript -e 'tell application "Claude" to quit' >/dev/null 2>&1 || true
  fi
  i=0
  while [ "$i" -lt 50 ]; do
    [ -z "$(claude_main_pids)" ] && break
    sleep 0.2
    i=$((i+1))
  done
  if [ -n "$(claude_main_pids)" ]; then
    log "Actual remaining Claude main PID(s): $(claude_main_pids | tr '\\n' ' ')"
    die "Claude Desktop main executable did not quit. Quit/force-quit Claude, then rerun."
  fi
  log "Previous Claude Desktop main process fully exited."
else
  log "Claude Desktop main process is not running."
fi
[ -z "$(claude_main_pids)" ] || die "Claude Desktop main executable is still running."
if ! purge_stale_claude_processes; then
  die "Stale Claude helper processes could not be stopped. Restart macOS, then retry."
fi
log "PASS: no stale Claude bundle processes remain."
exit_if_guardian_stop_requested

log "Checking VeePN SOCKS5 endpoint $SOCKS_HOST:$SOCKS_PORT."
if ! /usr/bin/nc -z -w 2 "$SOCKS_HOST" "$SOCKS_PORT" >/dev/null 2>&1; then
  die "Nothing is listening on $SOCKS_HOST:$SOCKS_PORT. Confirm VeePN Shadowsocks is connected."
fi

log "Verifying VeePN SOCKS5 with remote DNS."
SOCKS_IP="$(/usr/bin/curl -4fsS --socks5-hostname "$SOCKS_HOST:$SOCKS_PORT" \
  --connect-timeout 5 --max-time 12 "$CHECK_URL" 2>/dev/null || true)"
[[ "$SOCKS_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  die "VeePN SOCKS5 is listening but could not reach the verification URL."
log "VeePN SOCKS5 public IPv4: $SOCKS_IP"
exit_if_guardian_stop_requested

# Discover physical interfaces if not explicitly given.
if [ "${#PHYSICAL_IFS[@]}" -eq 0 ]; then
  while IFS= read -r dev; do
    [ -n "$dev" ] || continue
    [ "$dev" = "lo0" ] && continue
    if ifconfig "$dev" >/dev/null 2>&1 && \
       ifconfig "$dev" 2>/dev/null | head -1 | grep -q '<.*UP' && \
       ifconfig "$dev" 2>/dev/null | grep -qE '^[[:space:]]*inet '; then
      PHYSICAL_IFS+=("$dev")
    fi
  done < <(networksetup -listallhardwareports 2>/dev/null | awk '/Device:/{print $2}')
fi

tmp_if="$TMPROOT/interfaces"
printf '%s\n' "${PHYSICAL_IFS[@]}" | awk 'NF && !seen[$0]++' > "$tmp_if"
PHYSICAL_IFS=()
while IFS= read -r dev; do
  [ -n "$dev" ] && PHYSICAL_IFS+=("$dev")
done < "$tmp_if"
[ "${#PHYSICAL_IFS[@]}" -gt 0 ] || die "No active physical IPv4 interface found. Retry with --physical-if en0."
log "Physical interface(s) guarded: ${PHYSICAL_IFS[*]}"

# Embedded HTTP CONNECT -> SOCKS5 bridge.
cat > "$BRIDGE_SCRIPT" <<'PYBRIDGE'
#!/usr/bin/env python3
import argparse
import ipaddress
import select
import socket
import socketserver
import struct
import sys
import threading
from urllib.parse import urlsplit

BUF = 65536

def recvn(sock, n):
    data = bytearray()
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise OSError("unexpected EOF")
        data.extend(chunk)
    return bytes(data)

def socks5_connect(proxy_host, proxy_port, host, port, timeout=12):
    s = socket.create_connection((proxy_host, proxy_port), timeout=timeout)
    s.settimeout(timeout)
    s.sendall(b"\x05\x01\x00")
    if recvn(s, 2) != b"\x05\x00":
        s.close()
        raise OSError("SOCKS5 proxy rejected no-authentication method")

    try:
        ip = ipaddress.ip_address(host)
        if ip.version == 4:
            atyp = b"\x01"
            addr = ip.packed
        else:
            atyp = b"\x04"
            addr = ip.packed
    except ValueError:
        raw = host.encode("idna")
        if len(raw) > 255:
            s.close()
            raise OSError("target hostname too long")
        atyp = b"\x03"
        addr = bytes([len(raw)]) + raw

    req = b"\x05\x01\x00" + atyp + addr + struct.pack("!H", int(port))
    s.sendall(req)

    head = recvn(s, 4)
    if head[0] != 5 or head[1] != 0:
        s.close()
        raise OSError("SOCKS5 connect failed, reply=%d" % (head[1],))

    atyp = head[3]
    if atyp == 1:
        recvn(s, 4)
    elif atyp == 3:
        ln = recvn(s, 1)[0]
        recvn(s, ln)
    elif atyp == 4:
        recvn(s, 16)
    else:
        s.close()
        raise OSError("invalid SOCKS5 address type")
    recvn(s, 2)
    s.settimeout(None)
    return s

def relay(a, b):
    sockets = [a, b]
    try:
        while True:
            r, _, _ = select.select(sockets, [], [], 60)
            if not r:
                continue
            for src in r:
                dst = b if src is a else a
                data = src.recv(BUF)
                if not data:
                    return
                dst.sendall(data)
    finally:
        for s in sockets:
            try:
                s.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
            try:
                s.close()
            except Exception:
                pass

class Handler(socketserver.StreamRequestHandler):
    timeout = 30

    def send_error_simple(self, code, text):
        body = (text + "\n").encode()
        self.wfile.write(
            ("HTTP/1.1 %d %s\r\nConnection: close\r\nContent-Length: %d\r\n\r\n"
             % (code, text, len(body))).encode() + body
        )

    def handle(self):
        try:
            first = self.rfile.readline(65537)
            if not first or len(first) > 65536:
                return
            try:
                method, target, version = first.decode("iso-8859-1").rstrip("\r\n").split(" ", 2)
            except ValueError:
                self.send_error_simple(400, "Bad Request")
                return

            headers = []
            host_header = None
            while True:
                line = self.rfile.readline(65537)
                if not line or len(line) > 65536:
                    return
                if line in (b"\r\n", b"\n"):
                    break
                headers.append(line)
                if line.lower().startswith(b"host:"):
                    host_header = line.split(b":", 1)[1].strip().decode("iso-8859-1")

            if method.upper() == "CONNECT":
                host, port = self.parse_hostport(target, 443)
                upstream = socks5_connect(self.server.socks_host, self.server.socks_port, host, port)
                self.wfile.write(b"HTTP/1.1 200 Connection Established\r\nProxy-Agent: clvpn-bridge\r\n\r\n")
                self.wfile.flush()
                relay(self.connection, upstream)
                return

            # Plain HTTP proxying. Keep DNS remote by giving the hostname directly
            # to SOCKS5 instead of resolving it locally.
            parts = urlsplit(target)
            if parts.scheme and parts.hostname:
                if parts.scheme.lower() != "http":
                    self.send_error_simple(400, "Unsupported absolute URI scheme")
                    return
                host = parts.hostname
                port = parts.port or 80
                path = parts.path or "/"
                if parts.query:
                    path += "?" + parts.query
            else:
                if not host_header:
                    self.send_error_simple(400, "Host header required")
                    return
                host, port = self.parse_hostport(host_header, 80)
                path = target

            upstream = socks5_connect(self.server.socks_host, self.server.socks_port, host, port)
            upstream.sendall(("%s %s %s\r\n" % (method, path, version)).encode("iso-8859-1"))
            for line in headers:
                # Remove hop-by-hop proxy headers; preserve everything else.
                lower = line.lower()
                if lower.startswith(b"proxy-connection:") or lower.startswith(b"proxy-authorization:"):
                    continue
                upstream.sendall(line)
            upstream.sendall(b"Connection: close\r\n\r\n")

            # Forward request body if Content-Length is present.
            content_length = 0
            for line in headers:
                if line.lower().startswith(b"content-length:"):
                    try:
                        content_length = int(line.split(b":",1)[1].strip())
                    except Exception:
                        content_length = 0
            if content_length:
                upstream.sendall(recvn(self.connection, content_length))

            # Stream the response.
            while True:
                data = upstream.recv(BUF)
                if not data:
                    break
                self.connection.sendall(data)
            upstream.close()
        except Exception as e:
            try:
                self.send_error_simple(502, "Bad Gateway")
            except Exception:
                pass

    @staticmethod
    def parse_hostport(value, default_port):
        value = value.strip()
        if value.startswith("["):
            end = value.find("]")
            if end < 0:
                raise ValueError("bad IPv6 host")
            host = value[1:end]
            rest = value[end+1:]
            port = int(rest[1:]) if rest.startswith(":") else default_port
            return host, port
        if value.count(":") == 1:
            host, p = value.rsplit(":", 1)
            if p.isdigit():
                return host, int(p)
        return value, default_port

class ThreadingServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen-host", default="127.0.0.1")
    ap.add_argument("--listen-port", type=int, default=0)
    ap.add_argument("--socks-host", default="127.0.0.1")
    ap.add_argument("--socks-port", type=int, default=1080)
    ap.add_argument("--port-file", required=True)
    args = ap.parse_args()

    with ThreadingServer((args.listen_host, args.listen_port), Handler) as srv:
        srv.socks_host = args.socks_host
        srv.socks_port = args.socks_port
        port = srv.server_address[1]
        with open(args.port_file, "w") as f:
            f.write(str(port))
            f.flush()
        print("HTTP bridge listening on %s:%d -> SOCKS5 %s:%d"
              % (args.listen_host, port, args.socks_host, args.socks_port), flush=True)
        srv.serve_forever(poll_interval=0.2)

if __name__ == "__main__":
    main()
PYBRIDGE
chmod 700 "$BRIDGE_SCRIPT"

log "Starting localhost HTTP CONNECT bridge -> VeePN SOCKS5."
/usr/bin/python3 "$BRIDGE_SCRIPT" \
  --listen-host 127.0.0.1 --listen-port 0 \
  --socks-host "$SOCKS_HOST" --socks-port "$SOCKS_PORT" \
  --port-file "$BRIDGE_PORT_FILE" >"$BRIDGE_LOG" 2>&1 &
BRIDGE_PID=$!
disown "$BRIDGE_PID" 2>/dev/null || true

i=0
while [ "$i" -lt 50 ]; do
  if [ -s "$BRIDGE_PORT_FILE" ]; then
    BRIDGE_PORT="$(cat "$BRIDGE_PORT_FILE")"
    break
  fi
  if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
    cat "$BRIDGE_LOG" >&2 || true
    die "HTTP bridge exited before becoming ready."
  fi
  sleep 0.1
  i=$((i+1))
done
[[ "$BRIDGE_PORT" =~ ^[0-9]+$ ]] || die "HTTP bridge did not become ready."

HTTP_PROXY_URL="http://127.0.0.1:$BRIDGE_PORT"
log "Local HTTP proxy bridge: $HTTP_PROXY_URL"

BRIDGE_IP="$(/usr/bin/curl -4fsS -x "$HTTP_PROXY_URL" --noproxy '' \
  --connect-timeout 5 --max-time 12 "$CHECK_URL" 2>/dev/null || true)"
[ "$BRIDGE_IP" = "$SOCKS_IP" ] || \
  die "HTTP bridge verification failed (SOCKS=$SOCKS_IP bridge=${BRIDGE_IP:-none})."
log "PASS: HTTP bridge exits through VeePN at $BRIDGE_IP."

log "Requesting sudo for temporary group/PF setup."
sudo -v

base_gid=$((57000 + ($$ % 500)))
GROUP_GID="$base_gid"
while /usr/bin/dscl . -search /Groups PrimaryGroupID "$GROUP_GID" 2>/dev/null | grep -q .; do
  GROUP_GID=$((GROUP_GID + 1))
  [ "$GROUP_GID" -lt 58000 ] || die "Could not find a free temporary group ID."
done

log "Creating temporary isolation group $GROUP_NAME (gid=$GROUP_GID)."
sudo /usr/sbin/dseditgroup -o create -i "$GROUP_GID" "$GROUP_NAME" >/dev/null
GROUP_CREATED=1
sudo /usr/sbin/dseditgroup -o edit -a "$LOGIN_USER" -t user "$GROUP_NAME" >/dev/null
probe_gid="$(sudo -n -u "$LOGIN_USER" -g "$GROUP_NAME" /usr/bin/id -g 2>/dev/null || true)"
[ "$probe_gid" = "$GROUP_GID" ] || die "Could not establish effective-group isolation."
log "Effective-group isolation verified."

if ! sudo pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then
  enable_out="$(sudo pfctl -E 2>&1 || true)"
  PF_TOKEN="$(printf '%s\n' "$enable_out" | awk '/Token[[:space:]]*:/ {print $NF; exit}')"
  PF_ENABLED_BY_US=1
  log "PF was disabled; enabled temporarily${PF_TOKEN:+ with reference token}."
else
  log "PF already enabled; existing rules remain intact."
fi

: > "$PF_RULES"
for dev in "${PHYSICAL_IFS[@]}"; do
  printf 'block drop out quick on %s inet proto { tcp udp } from any to any group %s\n' \
    "$dev" "$GROUP_GID" >> "$PF_RULES"
  printf 'block drop out quick on %s inet6 proto { tcp udp } from any to any group %s\n' \
    "$dev" "$GROUP_GID" >> "$PF_RULES"

  # Prevent OS resolver leakage while this strict session is active.
  printf 'block drop out quick on %s inet proto { tcp udp } from any to any port 53\n' "$dev" >> "$PF_RULES"
  printf 'block drop out quick on %s inet6 proto { tcp udp } from any to any port 53\n' "$dev" >> "$PF_RULES"
  printf 'block drop out quick on %s inet proto { tcp udp } from any to any port 853\n' "$dev" >> "$PF_RULES"
  printf 'block drop out quick on %s inet6 proto { tcp udp } from any to any port 853\n' "$dev" >> "$PF_RULES"
done

sudo pfctl -vnf "$PF_RULES" >/dev/null 2>&1 || {
  cat "$PF_RULES" >&2
  die "macOS PF rejected the generated rules."
}
sudo pfctl -a "$ANCHOR" -f "$PF_RULES" >/dev/null
GUARD_INSTALLED=1
log "PF guard installed in anchor $ANCHOR."

restricted() {
  if [ "$GUI_ROOT_MODE" -eq 1 ]; then
    /bin/launchctl asuser "$LOGIN_UID" /usr/bin/sudo -n -u "$LOGIN_USER" -g "$GROUP_NAME" \
      /usr/bin/env HOME="$LOGIN_HOME" USER="$LOGIN_USER" LOGNAME="$LOGIN_USER" PATH="$ORIGINAL_PATH" \
      "$@"
  else
    sudo -n -u "$LOGIN_USER" -g "$GROUP_NAME" \
      /usr/bin/env HOME="$LOGIN_HOME" USER="$LOGIN_USER" LOGNAME="$LOGIN_USER" PATH="$ORIGINAL_PATH" \
      "$@"
  fi
}

for dev in "${PHYSICAL_IFS[@]}"; do
  log "PF leak test: restricted direct HTTPS on $dev must fail."
  if restricted /usr/bin/env \
      HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= NO_PROXY='*' \
      http_proxy= https_proxy= all_proxy= no_proxy='*' \
      /usr/bin/curl -4fsS --interface "$dev" --connect-timeout 3 --max-time 6 \
      "$CHECK_URL" >/dev/null 2>&1; then
    die "UNSAFE: restricted process reached the Internet directly on $dev."
  fi
  log "PASS: PF blocks restricted direct egress on $dev."
done

log "Protected-path test: restricted group must still work through localhost/VeePN."
PROTECTED_IP="$(restricted /usr/bin/env \
  HTTP_PROXY="$HTTP_PROXY_URL" HTTPS_PROXY="$HTTP_PROXY_URL" \
  http_proxy="$HTTP_PROXY_URL" https_proxy="$HTTP_PROXY_URL" \
  ALL_PROXY= all_proxy= \
  NO_PROXY="127.0.0.1,localhost,::1" no_proxy="127.0.0.1,localhost,::1" \
  /usr/bin/curl -4fsS -x "$HTTP_PROXY_URL" --noproxy '' \
  --connect-timeout 5 --max-time 12 "$CHECK_URL" 2>/dev/null || true)"
[ "$PROTECTED_IP" = "$SOCKS_IP" ] || \
  die "Protected path failed (expected $SOCKS_IP, got ${PROTECTED_IP:-none})."
log "PASS: restricted process exits through VeePN at $PROTECTED_IP."
exit_if_guardian_stop_requested

# Temporarily inject proxy variables for Desktop Local Code sessions.
# Official Desktop Local environment behavior also supports settings.json env.
log "Temporarily injecting protected proxy variables into $SETTINGS_FILE."
mkdir -p "$HOME/.claude"
if [ "$GUI_ROOT_MODE" -eq 1 ]; then
  chown "$LOGIN_UID:$LOGIN_GID" "$HOME/.claude" >/dev/null 2>&1 || true
fi
/usr/bin/python3 - "$SETTINGS_FILE" "$SETTINGS_STATE" "$HTTP_PROXY_URL" <<'PY'
import json, os, sys, tempfile
settings_path, state_path, proxy = sys.argv[1:4]

keys = {
    "HTTP_PROXY": proxy,
    "HTTPS_PROXY": proxy,
    "http_proxy": proxy,
    "https_proxy": proxy,
    "NO_PROXY": "127.0.0.1,localhost,::1",
    "no_proxy": "127.0.0.1,localhost,::1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "DISABLE_TELEMETRY": "1",
    "DISABLE_ERROR_REPORTING": "1",
    "DISABLE_BUG_COMMAND": "1",
    "DISABLE_AUTOUPDATER": "1",
}

if os.path.exists(settings_path):
    try:
        with open(settings_path, "r") as f:
            data = json.load(f)
    except Exception as e:
        print("settings.json is not valid JSON: %s" % e, file=sys.stderr)
        raise SystemExit(2)
else:
    data = {}

if not isinstance(data, dict):
    print("settings.json root is not an object", file=sys.stderr)
    raise SystemExit(2)

env_was_absent = not isinstance(data.get("env"), dict)
if env_was_absent:
    data["env"] = {}
env = data["env"]

state = {"env_was_absent": env_was_absent, "keys": {}}
for k, v in keys.items():
    state["keys"][k] = {"present": k in env, "value": env.get(k)}
    env[k] = v

with open(state_path, "w") as f:
    json.dump(state, f)

fd, tmp = tempfile.mkstemp(prefix=".settings.clvpn.", dir=os.path.dirname(settings_path))
try:
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, settings_path)
finally:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
PY
if [ "$GUI_ROOT_MODE" -eq 1 ]; then
  chown "$LOGIN_UID:$LOGIN_GID" "$SETTINGS_FILE" >/dev/null 2>&1 || true
fi
SETTINGS_PATCHED=1
log "Local Code proxy environment injected; original values will be restored on exit."

cat <<EOF

======================================================================
PROTECTED CLAUDE DESKTOP SESSION READY
======================================================================
VeePN SOCKS5        : $SOCKS_HOST:$SOCKS_PORT
HTTP proxy bridge   : $HTTP_PROXY_URL
Verified public IP  : $PROTECTED_IP
Physical guard      : ${PHYSICAL_IFS[*]}
Isolation group     : $GROUP_NAME (gid=$GROUP_GID)
Claude settings env : temporarily patched for LOCAL Code sessions

Use:
  Claude Desktop -> Code -> Environment: Local

Policy:
  Claude Desktop / Local Code -> localhost -> VeePN Shadowsocks : ALLOWED
  Direct TCP/UDP on physical interfaces from Claude descendants : BLOCKED
  Child process ignoring HTTP_PROXY/HTTPS_PROXY                 : BLOCKED
  Physical DNS/DoT while this launcher is active                : BLOCKED

Do NOT authorize sudo/root networking from Claude.
Remote and Cowork jobs execute off this Mac and are not governed by this
Mac-local process firewall.

Launching Claude Desktop now...
======================================================================

EOF

# Launch the app executable directly so the effective-group boundary is inherited.
# Avoid `open -a Claude`: LaunchServices could reuse/relaunch a process outside
# our effective group.
exit_if_guardian_stop_requested
set +e
restricted /usr/bin/env \
  HOME="$LOGIN_HOME" USER="$LOGIN_USER" LOGNAME="$LOGIN_USER" PATH="$ORIGINAL_PATH" \
  HTTP_PROXY="$HTTP_PROXY_URL" HTTPS_PROXY="$HTTP_PROXY_URL" \
  http_proxy="$HTTP_PROXY_URL" https_proxy="$HTTP_PROXY_URL" \
  NO_PROXY="127.0.0.1,localhost,::1" no_proxy="127.0.0.1,localhost,::1" \
  ALL_PROXY= all_proxy= \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  DISABLE_TELEMETRY=1 \
  DISABLE_ERROR_REPORTING=1 \
  DISABLE_BUG_COMMAND=1 \
  DISABLE_AUTOUPDATER=1 \
  "$APP_EXEC" >"$TMPROOT/claude-desktop.stdout.log" 2>"$TMPROOT/claude-desktop.stderr.log" &
APP_WRAPPER_PID=$!
set -e

# Give Electron time to initialize.
sleep 4
if ! kill -0 "$APP_WRAPPER_PID" 2>/dev/null; then
  echo "--- Claude Desktop stderr ---" >&2
  tail -80 "$TMPROOT/claude-desktop.stderr.log" >&2 || true
  die "Claude Desktop exited during protected startup."
fi

# Resolve the real Claude Desktop main process.  APP_WRAPPER_PID is a Bash
# background-job wrapper created by Bash when the `restricted` shell function is
# backgrounded; that wrapper legitimately remains in the user's ordinary group.
# The security boundary begins at the Claude executable launched underneath sudo.
CLAUDE_MAIN_PID="$(claude_main_pids | head -1 || true)"
if [ -z "$CLAUDE_MAIN_PID" ]; then
  echo "--- Claude Desktop stderr ---" >&2
  tail -80 "$TMPROOT/claude-desktop.stderr.log" >&2 || true
  die "Could not identify the protected Claude Desktop main process."
fi

main_gid="$(ps -o gid= -p "$CLAUDE_MAIN_PID" 2>/dev/null | awk '{print $1}' || true)"
exit_if_guardian_stop_requested
[ "$main_gid" = "$GROUP_GID" ] || \
  die "Claude Desktop main process is not in the isolation group (pid=$CLAUDE_MAIN_PID gid=${main_gid:-unknown})."
log "Protected Claude main PID: $CLAUDE_MAIN_PID (gid=$main_gid)."

# Build a union of the real process tree and bundle helpers that detached
# through macOS service mechanisms. Startup begins with an empty bundle process
# set, so every bundle helper visible here belongs to this protected run.
protected_related_pids() {
  {
    descendant_pids "$CLAUDE_MAIN_PID"
    claude_bundle_pids
  } | awk 'NF && !seen[$0]++'
}

log "Auditing protected Claude Desktop process tree with macOS-safe PID/GID parsing."
log "Protected process-tree snapshot (pid ppid gid command):"
while IFS= read -r pid; do
  [ -n "$pid" ] || continue
  kill -0 "$pid" 2>/dev/null || continue
  ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | awk '{print $1}' || true)"
  gid="$(ps -o gid= -p "$pid" 2>/dev/null | awk '{print $1}' || true)"
  cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
  printf '  pid=%s ppid=%s gid=%s %s\n' "$pid" "${ppid:-?}" "${gid:-?}" "$cmd"
done < <(protected_related_pids)

bad_helpers=0
helper_count=0
while IFS= read -r pid; do
  [ -n "$pid" ] || continue
  kill -0 "$pid" 2>/dev/null || continue
  proc_user="$(ps -o user= -p "$pid" 2>/dev/null | awk '{print $1}' || true)"
  [ "$proc_user" = "$LOGIN_USER" ] || continue
  helper_count=$((helper_count + 1))
  gid="$(ps -o gid= -p "$pid" 2>/dev/null | awk '{print $1}' || true)"
  if [ -n "$gid" ] && [ "$gid" != "$GROUP_GID" ]; then
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    printf 'UNPROTECTED CLAUDE PROCESS: pid=%s gid=%s command=%s\n' "$pid" "$gid" "$cmd" >&2
    bad_helpers=$((bad_helpers + 1))
  fi
done < <(protected_related_pids)

[ "$helper_count" -gt 0 ] || die "No protected Claude processes were visible during startup audit."
[ "$bad_helpers" -eq 0 ] || die "A Claude Desktop process escaped the temporary group; refusing to claim fail-closed protection."
log "PASS: Claude Desktop main process and visible descendants are inside the isolation group."

echo
if [ "$GUI_ROOT_MODE" -eq 1 ]; then
  log "Claude Desktop is running protected. VeePN Guardian is monitoring the hidden supervisor."
else
  log "Claude Desktop is running protected. Keep this Terminal window open."
fi
log "Use Code -> Local. When you quit Claude Desktop, the guard will be removed."

# Watch the actual Claude process tree.  If Claude exits, the wrapper will
# naturally unwind and cleanup.  Any newly-spawned Claude descendant must retain
# the isolation GID.
while kill -0 "$CLAUDE_MAIN_PID" 2>/dev/null; do
  if guardian_stop_requested; then
    log "Authenticated cleanup request detected; ending the protected Claude Desktop session."
    exit 0
  fi
  sleep 1
  bad_helpers=0
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    kill -0 "$pid" 2>/dev/null || continue
    proc_user="$(ps -o user= -p "$pid" 2>/dev/null | awk '{print $1}' || true)"
    [ "$proc_user" = "$LOGIN_USER" ] || continue
    gid="$(ps -o gid= -p "$pid" 2>/dev/null | awk '{print $1}' || true)"
    if [ -n "$gid" ] && [ "$gid" != "$GROUP_GID" ]; then
      cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
      printf '\nSECURITY STOP: Claude process escaped group: pid=%s gid=%s %s\n' \
        "$pid" "$gid" "$cmd" >&2
      bad_helpers=$((bad_helpers + 1))
    fi
  done < <(protected_related_pids)

  if [ "$bad_helpers" -gt 0 ]; then
    log "Failing closed: stopping protected Claude Desktop."
    bounded_kill "$APP_WRAPPER_PID"
    exit 70
  fi
done

wait "$APP_WRAPPER_PID" 2>/dev/null
app_rc=$?
log "Claude Desktop exited with status $app_rc."
exit "$app_rc"
