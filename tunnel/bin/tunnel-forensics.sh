#!/bin/bash
# tunnel-forensics.sh — answer "what disconnected me, and was it AppTunnel?"
#
#   tunnel-forensics.sh              explain the most recent disconnection
#   tunnel-forensics.sh --all        explain every recorded event
#   tunnel-forensics.sh --since 2h   only events newer than this
#   tunnel-forensics.sh --system     also mine macOS logs around each event
#
# Reads what tunnel-eventlog.sh recorded and turns raw state changes into an
# attributed cause. Nothing here changes anything; it only reads.
#
# WHY THIS EXISTS
#
# "The tunnel dropped" has at least eight causes on this Mac and they look
# identical from the outside: AppTunnel was told to stop; the launcher died on
# its own; the bridge crashed; VeePN's core died; one of eleven other VPN apps
# grabbed the system proxy; the Wi-Fi changed; the route changed; the machine
# slept. Guessing between them has cost more time than any actual bug, so this
# ranks them from evidence instead.

set -uo pipefail

. "$(cd "$(dirname "$0")" && pwd)/tunnel-python.sh"

STATE_DIR="$HOME/.apptunnel"
LOG="$STATE_DIR/disconnects.jsonl"

MODE="last"; SINCE=""; SYSTEM=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --all)    MODE="all"; shift ;;
    --since)  SINCE="${2:-}"; shift 2 ;;
    --system) SYSTEM=1; shift ;;
    *) echo "usage: $(basename "$0") [--all] [--since 2h] [--system]" >&2; exit 2 ;;
  esac
done

if [ ! -s "$LOG" ]; then
  echo "No events recorded yet."
  echo "Start the recorder first:  $(dirname "$0")/tunnel-eventlog.sh start"
  exit 0
fi

"$PY" - "$LOG" "$MODE" "$SINCE" <<'PY'
import json, sys, time, datetime

log, mode, since = sys.argv[1], sys.argv[2], sys.argv[3]

def parse_since(s):
    if not s: return 0
    try:
        n, u = float(s[:-1]), s[-1]
        return time.time() - n * {"s":1,"m":60,"h":3600,"d":86400}.get(u, 1)
    except Exception:
        return 0

floor = parse_since(since)
events = []
for line in open(log):
    line = line.strip()
    if not line: continue
    try: e = json.loads(line)
    except Exception: continue
    if e.get("kind") == "baseline": continue
    if e.get("t", 0) < floor: continue
    events.append(e)

if not events:
    print("No disconnection events in that window. (Steady state records nothing.)")
    raise SystemExit(0)

if mode == "last":
    events = events[-1:]

GREEN, RED, YEL, DIM, OFF = "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[0m"

def owner_name(v):
    return v.split("/")[0] if v else ""

def explain(ch, st, stop):
    """Return (verdict, culprit, detail) ranked most-specific first."""
    out = []

    # 1. An explicit stop is the least ambiguous signal there is.
    if stop:
        out.append(("AppTunnel was told to stop", "AppTunnel", stop))

    # 2. The launcher going away while nobody asked is a crash, not a stop.
    if "launcher" in ch and ch["launcher"]["to"] == "no":
        if not stop:
            out.append(("the launcher exited without a stop request "
                        "(crashed, or a phase failed)", "AppTunnel",
                        "check ~/.apptunnel/launcher.log and events.jsonl for the last phase"))

    # 3. Bridge died while the launcher was still alive: the bridge itself.
    if "bridge_17080" in ch and not ch["bridge_17080"]["to"]:
        if st.get("launcher") == "yes":
            out.append(("the HTTP->SOCKS bridge died while the tunnel was up",
                        "AppTunnel (bridge)", "tunnelled apps lose their route immediately"))
        else:
            out.append(("the bridge went down with the launcher",
                        "AppTunnel", "expected when the tunnel is torn down"))

    # 4. The upstream VPN core dying takes everything with it.
    if "socks_1081" in ch and not ch["socks_1081"]["to"]:
        out.append(("VeePN's proxy core stopped serving SOCKS",
                    "VeePN", "run tunnel-veepn-repair.sh"))

    # 5. Somebody else claimed the system proxy.
    if "proxy" in ch:
        a, b = ch["proxy"]["from"], ch["proxy"]["to"]
        who = owner_name(st.get("hiddify_12334") or "") or "another app"
        out.append((f"the system proxy changed ({a} -> {b})",
                    who if "12334" in b else "unknown app",
                    "two proxy apps cannot both own the system proxy"))

    # 6. Environmental causes. Real, and not anyone's bug.
    if "ssid" in ch:
        out.append((f"Wi-Fi network changed ({ch['ssid']['from'] or 'none'} -> "
                    f"{ch['ssid']['to'] or 'none'})", "the network", "not an app fault"))
    if "route" in ch:
        out.append((f"default route changed ({ch['route']['from']} -> {ch['route']['to']})",
                    "the network", "link flap, sleep/wake, or DHCP"))
    if "vpn_procs" in ch:
        before = set(filter(None, ch["vpn_procs"]["from"].split(",")))
        after = set(filter(None, ch["vpn_procs"]["to"].split(",")))
        for p in sorted(after - before):
            out.append((f"{p} started", p, "a new VPN app may contend for the proxy"))
        for p in sorted(before - after):
            out.append((f"{p} exited", p, "if it owned the proxy, traffic has nowhere to go"))

    # 7. Apps leaving the isolation group is the symptom users actually feel.
    if "group" in ch:
        try:
            was = int(ch["group"]["from"].split(":")[1])
            now = int(ch["group"]["to"].split(":")[1])
            if now < was:
                out.append((f"{was - now} tunnelled app(s) left the isolation group",
                            "AppTunnel" if stop else "unknown",
                            "they were closed, or they exited on their own"))
        except Exception:
            pass

    return out

for e in events:
    print(f"\n{'='*66}")
    print(f"  {e.get('at','?')}   {len(e.get('changed',{}))} thing(s) changed")
    print(f"{'='*66}")
    causes = explain(e.get("changed", {}), e.get("state", {}), e.get("stop_request"))
    if not causes:
        print(f"  {DIM}No known disconnection signature; raw change below.{OFF}")
    for i, (verdict, culprit, detail) in enumerate(causes):
        mark = f"{RED}MOST LIKELY{OFF}" if i == 0 else f"{DIM}also{OFF}      "
        print(f"  {mark}  {verdict}")
        print(f"              culprit: {YEL}{culprit}{OFF}")
        print(f"              {DIM}{detail}{OFF}")
    print(f"\n  {DIM}raw changes:{OFF}")
    for k, v in e.get("changed", {}).items():
        print(f"    {k:<14} {v['from'] or '(none)'}  ->  {v['to'] or '(none)'}")
    if e.get("stop_request"):
        print(f"\n  {DIM}stop request recorded:{OFF} {e['stop_request']}")
    print(f"\n  {DIM}state after:{OFF}")
    for k, v in e.get("state", {}).items():
        print(f"    {k:<14} {v or '(none)'}")
PY

if [ "$SYSTEM" -eq 1 ]; then
  echo
  echo "=== macOS log context (last 30m) ==="
  echo "--- sleep / wake ---"
  /usr/bin/pmset -g log 2>/dev/null | grep -iE "Sleep|Wake" | tail -5 | sed 's/^/  /'
  echo "--- VPN session state changes ---"
  /usr/bin/log show --predicate 'process == "nesessionmanager"' --last 30m --style compact 2>/dev/null \
    | grep -oE "Entering state NESMVPNSessionState[A-Za-z]+|Received a stop command from [A-Za-z]+" \
    | sort | uniq -c | tail -10 | sed 's/^/  /'
  echo "--- link flaps ---"
  /usr/bin/log show --predicate 'subsystem == "com.apple.SystemConfiguration"' --last 30m --style compact 2>/dev/null \
    | grep -iE "link (up|down)|interface" | tail -5 | sed 's/^/  /'
fi
