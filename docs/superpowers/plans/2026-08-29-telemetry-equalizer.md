# Live Telemetry Equalizer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn AppTunnel's ten idle equalizer bands into a live, continuously-sampled readout of ten distinct tunnel health factors, and add two new visualisations (a signal-path circuit view and a latency waterfall) so the panel keeps telling the truth for the whole session rather than only during the ten-second connect.

**Architecture:** The running `tunnel-lock.sh` already holds everything privileged the UI cannot get — the isolation gid, the PF anchor name, the bridge URL, and the ability to run a probe *as the guarded group*. It gains a sampler that writes one small JSON snapshot to `~/.apptunnel/telemetry.json` on a slow cadence, atomically, in a detached subshell that can never stall the 3-second watch loop. The app polls that file, plus a few cheap local facts it can see itself, and renders. No new privilege, no new password prompt, no new daemon.

**Tech Stack:** bash 3.2 · `/usr/bin/python3` 3.9 (stdlib only) · Swift 5.7 / AppKit compiled by `swiftc` (no Xcode project) · existing `tunnel-selfcheck.sh` harness for tests.

## Global Constraints

Every one of these comes from a defect this project actually shipped. They apply to all tasks.

- **bash 3.2 only.** No `mapfile`, no associative arrays. Guard every array expansion as `${ARR[@]+"${ARR[@]}"}` — a bare `"${ARR[@]}"` on an empty array aborts under `set -u`.
- **Never use `nc -z -w N` for liveness.** It does not cap a connection PF silently drops; the probe hangs exactly when diagnosis is needed. Use a Python socket with `settimeout()`.
- **Never test process liveness with `ps | grep -F "$path"`.** The grep process carries `$path` on its own command line and matches itself. Use the exact matcher: `awk '{p=$1;$1="";sub(/^[ \t]+/,"");if($0==e||index($0,e" ")==1)print p}'`.
- **Never emit a PF rule containing `to any port 53` without a `group` clause.** That blocks DNS for the whole Mac.
- **When a function's stdout is a data channel, its diagnostics go to stderr.** A log line written to stdout once put a protected pid back into a kill list.
- **The SOCKS endpoint is discovered from `scutil --proxy` (`SOCKSProxy` / `SOCKSPort`), never hardcoded.** VeePN publishes 1180 on this machine.
- **`SUDO_USER` is only trusted when `[ "$(id -u)" -eq 0 ]`.** It is inherited as `root` for ordinary users here.
- **Telemetry state is a single bounded snapshot file**, written by atomic `os.replace`. No append-only log — an unbounded `events.jsonl` already caused a slowdown.
- **Sampling must never block the watch loop and must never disturb the tunnel.** Detached subshell, lock file, skip if the previous sample is still running.
- Test harness is `tunnel/bin/tunnel-selfcheck.sh`; it must stay runnable **without sudo**, must launch and quit nothing, and must restore any state file it touches.

---

## File Structure

**New:**

| File | Responsibility |
|---|---|
| `tunnel/bin/tunnel-telemetry.sh` | One sampling pass. Prints a JSON object on stdout. Knows nothing about files or cadence. |
| `tunnel/app/AppTunnel/Sources/Skin.swift` | Palette, `bevel`, `text`, `width`, `ease`. Extracted verbatim from `main.swift`. |
| `tunnel/app/AppTunnel/Sources/Telemetry.swift` | `Band`, `BANDS`, `Telemetry` struct, JSON decode, `TelemetryStore` polling. |
| `tunnel/app/AppTunnel/Sources/Equalizer.swift` | `PhaseBars` (existing behaviour) + new live-telemetry mode with valley-hold. |
| `tunnel/app/AppTunnel/Sources/Visualiser.swift` | Analyser: bars / oscilloscope / **circuit** / **waterfall**, click to cycle. |

**Modified:**

| File | Change |
|---|---|
| `tunnel/bin/tunnel-lock.sh` | Call the sampler on a slow cadence from the watch loop; write `telemetry.json`. |
| `tunnel/app/build.sh` | Compile `Sources/*.swift` instead of only `main.swift`. |
| `tunnel/app/AppTunnel/Sources/main.swift` | Remove extracted code; wire `TelemetryStore`; add `--snapshot-eq`. |
| `tunnel/bin/tunnel-selfcheck.sh` | New assertions per task. |
| `tunnel/README.md` | Document the band meanings and the visualiser modes. |

## The Ten Bands

Winamp's EQ ran 60 Hz → 16 kHz. The metaphor is kept: **low bands are foundational, high bands are fine-grained security.** A band at full height is healthy; a band that *drops* is the alarm. That inverts the classic peak-hold, so these use a **valley-hold** marker — a red tick showing the worst value in the last 30 samples.

| # | Label | Factor | Healthy (1.0) | Degraded | Failed (0.0) |
|---|---|---|---|---|---|
| 1 | `LINK` | default route + gateway reachable | gateway answers | route but no answer | no default route |
| 2 | `DNS` | uncached resolve, no machine-wide blocks | resolves, 0 unscoped port-53 rules | slow resolve | no resolution, or a machine-wide block found |
| 3 | `SOCKS` | advertised endpoint listening + handshake time | handshake < 50 ms | < 400 ms | not listening |
| 4 | `BRIDGE` | local HTTP→SOCKS bridge alive | responds < 100 ms | < 600 ms | dead |
| 5 | `EXIT` | exit IP present and unchanged | same as session start | changed this session | unreachable |
| 6 | `RTT` | end-to-end latency through the tunnel | < 150 ms | < 800 ms | timeout |
| 7 | `FLOW` | bytes/s through the bridge, log-scaled | active traffic | trickle | idle (not an error — see note) |
| 8 | `SEAL` | guarded leak probe: targets reachable directly | 0 of 5 | — | any reachable = containment breached |
| 9 | `WALL` | PF anchor loaded **and** main ruleset references `com.apple/*` | both true | anchor empty | ruleset does not evaluate anchors |
| 10 | `GRIP` | every app pid still carries the isolation gid | no escapes | — | a process escaped the group |

`FLOW` is the one band where a low value is not an alarm; it renders dim-green rather than red at zero so idleness never looks like failure.

**Preamp slider = protection confidence**, a weighted mean where `SEAL`, `WALL` and `GRIP` carry triple weight. If any of those three is zero the preamp is pinned to zero and turns red, because partial protection is not protection.

---

### Task 0: Make commits possible

This directory is not a git repository, so "commit" is not yet a real step. Every later task ends in a commit; this makes that true. It is also insurance: several files here have been rewritten mid-session by other agents.

**Files:**
- Create: `/Applications/Claude-Chatgpt Tunnel/.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: a working tree where `git add`/`git commit` succeed from the project root.

- [ ] **Step 1: Confirm there is no repository yet**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
git rev-parse --is-inside-work-tree 2>&1
```

Expected: `fatal: not a git repository (or any of the parent directories): .git`

If it prints `true`, skip to Step 4 — a repo already exists, do not re-init.

- [ ] **Step 2: Write the ignore file**

Create `/Applications/Claude-Chatgpt Tunnel/.gitignore`:

```gitignore
# Build output — rebuilt by tunnel/app/build.sh
AppTunnel.app/
tunnel/app/AppTunnel.app/

# Rolling backups the scripts make
*.bak
*.prev
*.prev2
*.prev3

# macOS
.DS_Store
```

- [ ] **Step 3: Initialise and take a baseline commit**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
git init -q
git add -A
git commit -q -m "chore: baseline of the apptunnel toolkit before telemetry work"
git log --oneline | head -1
```

Expected: one commit hash and the message.

- [ ] **Step 4: Confirm the suite still passes before changing anything**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
tunnel/bin/tunnel-selfcheck.sh --quick 2>&1 | tail -3
```

Expected: `0 failed`. If anything fails, stop and report — do not build on a red baseline.

---

### Task 1: The telemetry sampler

A standalone script that takes one measurement pass and prints JSON. It is deliberately ignorant of files and scheduling so it can be tested directly.

**Files:**
- Create: `tunnel/bin/tunnel-telemetry.sh`
- Test: `tunnel/bin/tunnel-selfcheck.sh` (new section)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `tunnel-telemetry.sh [--gid N] [--anchor NAME] [--bridge URL] [--exit-ip IP]` printing to stdout a single-line JSON object with exactly these keys, every value a float in `0.0…1.0` except `t`, `detail` and `exit_ip`:
  `{"t":<epoch float>,"link":f,"dns":f,"socks":f,"bridge":f,"exit":f,"rtt":f,"flow":f,"seal":f,"wall":f,"grip":f,"score":f,"exit_ip":"<string>","detail":{"<band>":"<short human string>"}}`
  All arguments are optional; a band whose inputs are unavailable reports `-1.0`, meaning *unknown* (rendered dim grey, never red).

- [ ] **Step 1: Write the failing test**

Append to `tunnel/bin/tunnel-selfcheck.sh`, immediately before the line `# =============================================== argument / guard behaviour ==`:

```bash
# ================================================= telemetry sampler ========
hdr "1c. Telemetry sampler"
if [ ! -x "$BIN/tunnel-telemetry.sh" ]; then
  fail "tunnel-telemetry.sh exists and is executable"
else
  pass "tunnel-telemetry.sh exists and is executable"
  tsout="$("$BIN/tunnel-telemetry.sh" 2>/dev/null)"
  if /usr/bin/python3 -c '
import json, sys
d = json.loads(sys.argv[1])
need = ["t","link","dns","socks","bridge","exit","rtt","flow","seal","wall","grip","score"]
missing = [k for k in need if k not in d]
assert not missing, "missing keys: %s" % missing
bands = [k for k in need if k not in ("t",)]
bad = [k for k in bands if not isinstance(d[k], (int, float))]
assert not bad, "non-numeric: %s" % bad
out = [k for k in bands if not (d[k] == -1.0 or 0.0 <= d[k] <= 1.0)]
assert not out, "out of range: %s" % out
assert isinstance(d.get("detail"), dict), "detail must be an object"
' "$tsout" 2>/dev/null; then
    pass "the sampler emits a valid, in-range telemetry object"
  else
    fail "the sampler emits a valid, in-range telemetry object" "got: $(printf '%s' "$tsout" | head -c 160)"
  fi
  # One pass must be cheap: the watch loop ticks every 3s.
  st="$(/usr/bin/python3 -c 'import time;print(time.time())')"
  "$BIN/tunnel-telemetry.sh" >/dev/null 2>&1
  el="$(/usr/bin/python3 -c 'import sys,time;print(int((time.time()-float(sys.argv[1]))*1000))' "$st")"
  if [ "${el:-9999}" -lt 8000 ]; then
    pass "a sampling pass completes in ${el}ms (< 8s budget)"
  else
    fail "a sampling pass completes within 8s" "took ${el}ms"
  fi
fi
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
tunnel/bin/tunnel-selfcheck.sh --quick 2>&1 | grep -A2 'Telemetry sampler'
```

Expected: `FAIL  tunnel-telemetry.sh exists and is executable`

- [ ] **Step 3: Write the sampler**

Create `tunnel/bin/tunnel-telemetry.sh`:

```bash
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

# 1.0 at or below `good` ms, 0.0 at or above `bad` ms, linear between.
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
  bport="$(printf '%s' "$BRIDGE" | sed -e 's|.*:||' -e 's|/.*||')"
  conns="$(netstat -an -p tcp 2>/dev/null | grep -c "\.${bport}.*ESTABLISHED" || true)"
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
```

Then:

```bash
chmod +x "/Applications/Claude-Chatgpt Tunnel/tunnel/bin/tunnel-telemetry.sh"
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
bash -n tunnel/bin/tunnel-telemetry.sh && echo "parses"
tunnel/bin/tunnel-telemetry.sh | /usr/bin/python3 -m json.tool | head -20
tunnel/bin/tunnel-selfcheck.sh --quick 2>&1 | grep -A4 'Telemetry sampler'
```

Expected: `parses`, a readable JSON object, and three `PASS` lines. Unprivileged bands (`seal`, `wall`) will read `-1.0` — that is correct, not a failure.

- [ ] **Step 5: Commit**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
git add tunnel/bin/tunnel-telemetry.sh tunnel/bin/tunnel-selfcheck.sh
git commit -q -m "feat(telemetry): add a bounded, hard-timeout tunnel health sampler"
```

---

### Task 2: Publish telemetry from the running launcher

The sampler only sees the privileged facts when the launcher runs it. This wires it into the watch loop without ever letting it stall that loop.

**Files:**
- Modify: `tunnel/bin/tunnel-lock.sh` (watch loop, and the `RUN_FILE` variable block)
- Test: `tunnel/bin/tunnel-selfcheck.sh`

**Interfaces:**
- Consumes: `tunnel-telemetry.sh` from Task 1.
- Produces: `~/.apptunnel/telemetry.json` — the sampler's object, replaced atomically, owned by the login user, refreshed roughly every 15 s. Absence of the file means "no session".

- [ ] **Step 1: Write the failing test**

Append to `tunnel/bin/tunnel-selfcheck.sh` inside the `1c. Telemetry sampler` section, after the last `fi`:

```bash
grep -q 'TELEMETRY_FILE' "$BIN/tunnel-lock.sh" \
  && pass "the launcher publishes telemetry" \
  || fail "the launcher publishes telemetry"
# It must never run the sampler synchronously: the watch loop ticks every 3s.
if sed -n '/^while any_alive; do/,/^done$/p' "$BIN/tunnel-lock.sh" | grep -qE 'tunnel-telemetry\.sh[^&]*$'; then
  fail "telemetry sampling is detached from the watch loop" "found a blocking call"
else
  pass "telemetry sampling is detached from the watch loop"
fi
grep -q 'TELEMETRY_LOCK' "$BIN/tunnel-lock.sh" \
  && pass "overlapping sampling passes are prevented by a lock" \
  || fail "overlapping sampling passes are prevented by a lock"
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
tunnel/bin/tunnel-selfcheck.sh --quick 2>&1 | grep -E 'publishes telemetry|detached|lock'
```

Expected: three `FAIL` lines.

- [ ] **Step 3: Declare the paths**

In `tunnel/bin/tunnel-lock.sh`, find:

```bash
RUN_FILE="$STATE_DIR/run-request"
```

There are two occurrences — the default block near the top and the root-mode remap inside `if [ "$EUID" -eq 0 ]`. Add this line after **each** of them, matching the surrounding indentation:

```bash
TELEMETRY_FILE="$STATE_DIR/telemetry.json"
TELEMETRY_LOCK="$STATE_DIR/telemetry.lock"
```

- [ ] **Step 4: Sample from the watch loop, detached**

In `tunnel/bin/tunnel-lock.sh`, find this block inside the watch loop:

```bash
  # A one-app join request from the roster's RUN button.
  if [ -f "$RUN_FILE" ]; then
```

Insert immediately **before** it:

```bash
  # Publish telemetry on a slow cadence. Detached and lock-guarded: a sampling
  # pass can take seconds, and this loop must keep auditing the process tree
  # every 3s regardless. A stale lock older than 120s is ignored so a killed
  # sampler cannot silence telemetry for the rest of the session.
  TELEMETRY_TICK=$(( ${TELEMETRY_TICK:-0} + 1 ))
  if [ $(( TELEMETRY_TICK % 5 )) -eq 0 ]; then
    if [ -f "$TELEMETRY_LOCK" ] \
       && [ -n "$(find "$TELEMETRY_LOCK" -mmin +2 2>/dev/null)" ]; then
      rm -f "$TELEMETRY_LOCK"
    fi
    if [ ! -f "$TELEMETRY_LOCK" ]; then
      (
        : > "$TELEMETRY_LOCK"
        snap="$("$(dirname "$0")/tunnel-telemetry.sh" \
                  --gid "$GROUP_GID" --anchor "$ANCHOR" \
                  --bridge "$HTTP_PROXY_URL" --exit-ip "$SOCKS_IP" 2>/dev/null)"
        if [ -n "$snap" ]; then
          printf '%s\n' "$snap" > "$TELEMETRY_FILE.tmp" \
            && mv -f "$TELEMETRY_FILE.tmp" "$TELEMETRY_FILE"
          if (( RUN_AS_ROOT )); then
            chown "$LOGIN_USER" "$TELEMETRY_FILE" 2>/dev/null || true
          fi
        fi
        rm -f "$TELEMETRY_LOCK"
      ) >/dev/null 2>&1 &
    fi
  fi

```

- [ ] **Step 5: Clear telemetry on teardown**

In `tunnel/bin/tunnel-lock.sh`, find in the cleanup function:

```bash
  rm -f "$STOP_FILE" "$RUN_FILE" 2>/dev/null
```

Replace with:

```bash
  rm -f "$STOP_FILE" "$RUN_FILE" "$TELEMETRY_FILE" "$TELEMETRY_LOCK" 2>/dev/null
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
bash -n tunnel/bin/tunnel-lock.sh && echo "parses"
tunnel/bin/tunnel-selfcheck.sh --quick 2>&1 | grep -E 'publishes telemetry|detached|lock'
```

Expected: `parses` and three `PASS` lines.

- [ ] **Step 7: Commit**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
git add tunnel/bin/tunnel-lock.sh tunnel/bin/tunnel-selfcheck.sh
git commit -q -m "feat(telemetry): publish a bounded snapshot from the launcher watch loop"
```

---

### Task 3: Split the Swift sources

`main.swift` is 1430 lines and this feature adds several hundred more. Split first so later tasks touch small, focused files. Pure extraction — **no behaviour changes**, which is what makes it safe to verify by identical render output.

**Files:**
- Create: `tunnel/app/AppTunnel/Sources/Skin.swift`
- Modify: `tunnel/app/AppTunnel/Sources/main.swift`, `tunnel/app/build.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum Skin` and the free functions `bevel(_:sunken:)`, `text(_:_:_:_:glow:)`, `width(_:_:)`, `ease(_:_:_:)` in `Skin.swift`, unchanged in signature. `build.sh` compiles every `Sources/*.swift`.

- [ ] **Step 1: Capture the current render as the regression baseline**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
tunnel/app/AppTunnel.app/Contents/MacOS/AppTunnel --snapshot /tmp/eq-before.png 2>&1 | tail -1
/usr/bin/shasum -a 256 /tmp/eq-before.png | awk '{print "  baseline "$1}'
```

Expected: `snapshot written: /tmp/eq-before.png` and a hash. Keep it; Step 5 compares against it.

- [ ] **Step 2: Make the build compile every source file**

In `tunnel/app/build.sh`, find:

```bash
SRC="$HERE/AppTunnel/Sources/main.swift"
```

Replace with:

```bash
SRC_DIR="$HERE/AppTunnel/Sources"
```

Then find:

```bash
swiftc -O \
  -target x86_64-apple-macosx11.0 \
  -framework AppKit \
  -o "$MACOS/AppTunnel" \
  "$SRC"
```

Replace with:

```bash
# Compile every file in Sources/ so the app can be split into focused units.
# shellcheck disable=SC2046
swiftc -O \
  -target x86_64-apple-macosx11.0 \
  -framework AppKit \
  -o "$MACOS/AppTunnel" \
  $(ls "$SRC_DIR"/*.swift)
```

- [ ] **Step 3: Extract the skin**

Create `tunnel/app/AppTunnel/Sources/Skin.swift` by **moving** — cutting, not copying — from `main.swift` the block that begins at the line `// MARK: - Skin` and ends immediately before `// MARK: - Model`. Prefix the new file with:

```swift
// Skin.swift — palette and drawing primitives shared by every view.
// Extracted verbatim from main.swift; no behaviour change.

import AppKit
```

Delete that block from `main.swift`. Everything in it is internal by default, so no access-level changes are needed.

- [ ] **Step 4: Build**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
tunnel/app/build.sh 2>&1 | grep -E 'error:|Built'
```

Expected: `Built: …/AppTunnel.app` and no `error:` lines. A `duplicate` error means the block was copied rather than moved — delete it from `main.swift`.

- [ ] **Step 5: Verify the render is byte-identical**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
tunnel/app/AppTunnel.app/Contents/MacOS/AppTunnel --snapshot /tmp/eq-after.png 2>&1 | tail -1
if [ "$(shasum -a 256 < /tmp/eq-before.png)" = "$(shasum -a 256 < /tmp/eq-after.png)" ]; then
  echo "IDENTICAL — pure extraction confirmed"
else
  echo "DIFFERENT — the extraction changed behaviour; revert and redo"
fi
```

Expected: `IDENTICAL`.

- [ ] **Step 6: Commit**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
git add tunnel/app/build.sh tunnel/app/AppTunnel/Sources/
git commit -q -m "refactor(app): extract Skin.swift and build all Sources/*.swift"
```

---

### Task 4: Telemetry model in the app

**Files:**
- Create: `tunnel/app/AppTunnel/Sources/Telemetry.swift`
- Modify: `tunnel/app/AppTunnel/Sources/main.swift`

**Interfaces:**
- Consumes: `~/.apptunnel/telemetry.json` from Task 2.
- Produces:
  - `struct Band { let key: String; let label: String; let hz: String; let idleIsFine: Bool }`
  - `let BANDS: [Band]` — exactly ten, in the order `link dns socks bridge exit rtt flow seal wall grip`
  - `final class TelemetryStore` with `var values: [Double]` (ten entries, `-1` = unknown), `var details: [String]`, `var score: Double`, `var fresh: Bool`, `var history: [Double]` (last 120 `rtt` samples), and `func poll() -> Bool` returning true when anything changed.

- [ ] **Step 1: Write the failing test**

Append to `tunnel/bin/tunnel-selfcheck.sh` in the `1c. Telemetry sampler` section:

```bash
SRCD="$ROOT/app/AppTunnel/Sources"
[ -f "$SRCD/Telemetry.swift" ] \
  && pass "Telemetry.swift exists" || fail "Telemetry.swift exists"
nb="$(grep -c 'Band(key:' "$SRCD/Telemetry.swift" 2>/dev/null || echo 0)"
[ "${nb:-0}" -eq 10 ] \
  && pass "exactly ten bands are defined" \
  || fail "exactly ten bands are defined" "found $nb"
grep -q 'idleIsFine' "$SRCD/Telemetry.swift" \
  && pass "the FLOW band is marked idle-is-not-failure" \
  || fail "the FLOW band is marked idle-is-not-failure"
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
tunnel/bin/tunnel-selfcheck.sh --quick 2>&1 | grep -E 'Telemetry.swift|ten bands|idle-is'
```

Expected: three `FAIL` lines.

- [ ] **Step 3: Write the model**

Create `tunnel/app/AppTunnel/Sources/Telemetry.swift`:

```swift
// Telemetry.swift — the ten live health bands and the snapshot reader.
//
// Values are 0.0...1.0, or -1.0 for "unknown", which renders grey and never
// red: an unmeasured band must not look like a failing one.

import Foundation

struct Band {
    let key: String
    let label: String
    let hz: String          // the Winamp band this replaces, for the scale strip
    let idleIsFine: Bool    // zero is normal, not an alarm (FLOW only)
}

let BANDS: [Band] = [
    Band(key: "link",   label: "LINK",   hz: "60",  idleIsFine: false),
    Band(key: "dns",    label: "DNS",    hz: "170", idleIsFine: false),
    Band(key: "socks",  label: "SOCKS",  hz: "310", idleIsFine: false),
    Band(key: "bridge", label: "BRIDGE", hz: "600", idleIsFine: false),
    Band(key: "exit",   label: "EXIT",   hz: "1K",  idleIsFine: false),
    Band(key: "rtt",    label: "RTT",    hz: "3K",  idleIsFine: false),
    Band(key: "flow",   label: "FLOW",   hz: "6K",  idleIsFine: true),
    Band(key: "seal",   label: "SEAL",   hz: "12K", idleIsFine: false),
    Band(key: "wall",   label: "WALL",   hz: "14K", idleIsFine: false),
    Band(key: "grip",   label: "GRIP",   hz: "16K", idleIsFine: false),
]

final class TelemetryStore {
    private(set) var values  = [Double](repeating: -1, count: BANDS.count)
    private(set) var details = [String](repeating: "", count: BANDS.count)
    private(set) var score: Double = -1
    private(set) var exitIP = ""
    private(set) var history: [Double] = []     // last 120 rtt samples
    private(set) var fresh = false              // a sample arrived in the last 60s

    private let path = NSHomeDirectory() + "/.apptunnel/telemetry.json"
    private var lastStamp: Double = 0

    /// Returns true when anything changed and the UI should redraw.
    func poll() -> Bool {
        guard let d = FileManager.default.contents(atPath: path),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = o["t"] as? Double else {
            if fresh || score >= 0 {
                values = [Double](repeating: -1, count: BANDS.count)
                details = [String](repeating: "", count: BANDS.count)
                score = -1; fresh = false; exitIP = ""
                return true
            }
            return false
        }
        let age = Date().timeIntervalSince1970 - t
        let nowFresh = age < 60
        if t == lastStamp && nowFresh == fresh { return false }
        lastStamp = t
        fresh = nowFresh

        let detail = (o["detail"] as? [String: Any]) ?? [:]
        for (i, b) in BANDS.enumerated() {
            values[i]  = (o[b.key] as? Double) ?? -1
            details[i] = (detail[b.key] as? String) ?? ""
        }
        score = (o["score"] as? Double) ?? -1
        exitIP = (o["exit_ip"] as? String) ?? ""

        if let rtt = o["rtt"] as? Double, rtt >= 0 {
            history.append(rtt)
            if history.count > 120 { history.removeFirst(history.count - 120) }
        }
        return true
    }
}
```

- [ ] **Step 4: Wire it into the model**

In `tunnel/app/AppTunnel/Sources/main.swift`, find inside `final class Model`:

```swift
    var tunnelled: Set<String> = []
```

Add directly after it:

```swift
    let telemetry = TelemetryStore()
```

Then find, inside `func poll() -> Bool`:

```swift
        if !demoMode && consumeEvents() { dirty = true }
        return dirty
```

Replace with:

```swift
        if !demoMode && consumeEvents() { dirty = true }
        if !demoMode && telemetry.poll() { dirty = true }
        return dirty
```

- [ ] **Step 5: Build and verify the tests pass**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
tunnel/app/build.sh 2>&1 | grep -E 'error:|Built'
tunnel/bin/tunnel-selfcheck.sh --quick 2>&1 | grep -E 'Telemetry.swift|ten bands|idle-is'
```

Expected: `Built: …` and three `PASS` lines.

- [ ] **Step 6: Commit**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
git add tunnel/app/AppTunnel/Sources/ tunnel/bin/tunnel-selfcheck.sh
git commit -q -m "feat(app): read live telemetry into a ten-band model"
```

---

### Task 5: The live equalizer

The visual centrepiece. During connect the bars mean phases, exactly as now. Once a session is live they cross-fade into telemetry mode: ten labelled bands, valley-hold markers, a preamp confidence slider, and hover readouts.

**Files:**
- Create: `tunnel/app/AppTunnel/Sources/Equalizer.swift`
- Modify: `tunnel/app/AppTunnel/Sources/main.swift`

**Interfaces:**
- Consumes: `BANDS`, `TelemetryStore` (Task 4); `Skin` (Task 3).
- Produces: `final class Equalizer: NSView` with `var onHover: ((String?) -> Void)?` and `func step()`. It replaces `PhaseBars`; `main.swift` must construct `Equalizer` and keep calling `step()` from the 30 fps timer.

- [ ] **Step 1: Write the failing test**

Append to `tunnel/bin/tunnel-selfcheck.sh` in the `1c.` section:

```bash
[ -f "$SRCD/Equalizer.swift" ] \
  && pass "Equalizer.swift exists" || fail "Equalizer.swift exists"
grep -q 'valley' "$SRCD/Equalizer.swift" 2>/dev/null \
  && pass "the equalizer tracks a valley-hold (worst recent value)" \
  || fail "the equalizer tracks a valley-hold (worst recent value)"
grep -q 'idleIsFine' "$SRCD/Equalizer.swift" 2>/dev/null \
  && pass "an idle FLOW band is not drawn as an alarm" \
  || fail "an idle FLOW band is not drawn as an alarm"
grep -q 'snapshot-eq' "$SRCD/main.swift" 2>/dev/null \
  && pass "the equalizer has a deterministic render hook" \
  || fail "the equalizer has a deterministic render hook"
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
tunnel/bin/tunnel-selfcheck.sh --quick 2>&1 | grep -E 'Equalizer.swift|valley|idle FLOW|render hook'
```

Expected: four `FAIL` lines.

- [ ] **Step 3: Write the view**

Create `tunnel/app/AppTunnel/Sources/Equalizer.swift`:

```swift
// Equalizer.swift — ten bands that mean connection phases while connecting,
// then cross-fade into live telemetry for the rest of the session.
//
// A band at full height is healthy. Because a FALLING bar is the alarm, the
// classic peak-hold is inverted into a valley-hold: a red tick marking the
// worst value seen recently, so a brief outage stays visible.

import AppKit

final class Equalizer: NSView {
    var onHover: ((String?) -> Void)?

    private var shown   = [CGFloat](repeating: 0.04, count: BANDS.count)
    private var valley  = [CGFloat](repeating: 1.0,  count: BANDS.count)
    private var valleyAge = [Int](repeating: 0, count: BANDS.count)
    private var flash   = [CGFloat](repeating: 0, count: BANDS.count)
    private var wasOK   = [Bool](repeating: false, count: BANDS.count)
    private var pulse: CGFloat = 0
    private var mix: CGFloat = 0            // 0 = phases, 1 = telemetry
    private var hoverIndex: Int? = nil

    override init(frame f: NSRect) {
        super.init(frame: f)
        addTrackingArea(NSTrackingArea(rect: .zero,
                        options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                        owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    private var live: Bool { Model.shared.telemetry.fresh && Model.shared.sessionActive }

    func step() {
        let m = Model.shared
        pulse += 0.09
        ease(&mix, live ? 1 : 0, 0.06)

        for i in 0..<BANDS.count {
            let target: CGFloat
            if live {
                let v = CGFloat(m.telemetry.values[i])
                target = v < 0 ? 0.06 : max(0.04, v)
            } else {
                let st = m.phases[i]
                target = st == .ok ? 1 : st == .running ? 0.55 : st == .failed ? 1 : 0.04
            }
            ease(&shown[i], target, 0.16)

            // Valley-hold: remember the worst recent value, then relax upward.
            if shown[i] < valley[i] { valley[i] = shown[i]; valleyAge[i] = 0 }
            else {
                valleyAge[i] += 1
                if valleyAge[i] > 900 { valley[i] = min(1, valley[i] + 0.004) }  // ~30s at 30fps
            }

            let ok = live ? (m.telemetry.values[i] > 0.66) : (m.phases[i] == .ok)
            if ok && !wasOK[i] { flash[i] = 1 }
            wasOK[i] = ok
            if flash[i] > 0 { flash[i] = max(0, flash[i] - 0.05) }
        }
        needsDisplay = true
    }

    private func colour(_ i: Int) -> NSColor {
        let m = Model.shared
        if !live {
            switch m.phases[i] {
            case .ok: return Skin.green
            case .running: return Skin.amber
            case .failed: return Skin.red
            case .idle: return Skin.greenDim
            }
        }
        let v = m.telemetry.values[i]
        if v < 0 { return NSColor(white: 0.34, alpha: 1) }          // unknown, never red
        if BANDS[i].idleIsFine && v < 0.15 { return Skin.greenDim } // idle FLOW is fine
        if v > 0.66 { return Skin.green }
        if v > 0.33 { return Skin.amber }
        return Skin.red
    }

    override func draw(_ r: NSRect) {
        let m = Model.shared
        Skin.lcd.setFill(); bounds.fill()
        bevel(bounds, sunken: true)

        // dashed midline
        NSColor(srgbRed: 0.05, green: 0.16, blue: 0.06, alpha: 1).setFill()
        var gx: CGFloat = 6
        while gx < bounds.width - 6 { NSRect(x: gx, y: bounds.midY, width: 2, height: 1).fill(); gx += 5 }

        // preamp: overall protection confidence, left of the bands
        let preW: CGFloat = 16
        drawPreamp(NSRect(x: 6, y: 20, width: preW, height: bounds.height - 34))

        let x0 = preW + 14
        let slot = (bounds.width - x0 - 8) / CGFloat(BANDS.count)
        let trackH = bounds.height - 34
        for i in 0..<BANDS.count {
            let cx = x0 + slot * (CGFloat(i) + 0.5)
            let track = NSRect(x: cx - 5, y: 20, width: 10, height: trackH)
            NSColor(white: 0.05, alpha: 1).setFill(); track.fill()
            bevel(track, sunken: true)

            var c = colour(i)
            if !live && m.phases[i] == .running {
                c = c.withAlphaComponent(0.55 + 0.45 * CGFloat(abs(sin(pulse))))
            }
            let fh = max(2, (trackH - 2) * shown[i])
            let fill = NSRect(x: track.minX + 1, y: track.minY + 1, width: 8, height: fh)
            NSGradient(colors: [c, c.shadow(withLevel: 0.55) ?? c])?.draw(in: fill, angle: -90)

            if flash[i] > 0 {
                Skin.green.withAlphaComponent(flash[i] * 0.5).setFill()
                fill.insetBy(dx: -3, dy: -3).fill()
            }

            // valley-hold marker: how bad it recently got
            if live && valley[i] < 0.95 {
                let vy = track.minY + 1 + (trackH - 2) * valley[i]
                Skin.red.withAlphaComponent(0.85).setFill()
                NSRect(x: track.minX - 2, y: vy, width: 14, height: 1).fill()
            }

            let knob = NSRect(x: cx - 7, y: track.minY + fh - 2, width: 14, height: 5)
            NSGradient(colors: [NSColor(white: 0.62, alpha: 1), NSColor(white: 0.26, alpha: 1)])?
                .draw(in: knob, angle: -90)
            bevel(knob)

            // Band label when live, phase number when connecting.
            let lbl = live ? BANDS[i].label : "\(i + 1)"
            let f = Skin.mono(live ? 7 : 8, hoverIndex == i)
            text(lbl, NSPoint(x: cx - width(lbl, f) / 2, y: 5), f, c)
        }
    }

    private func drawPreamp(_ track: NSRect) {
        let m = Model.shared
        NSColor(white: 0.05, alpha: 1).setFill(); track.fill()
        bevel(track, sunken: true)
        let s = live ? CGFloat(max(0, m.telemetry.score)) : CGFloat(m.completed) / CGFloat(BANDS.count)
        let c: NSColor = s <= 0.001 ? Skin.red : s > 0.8 ? Skin.green : Skin.amber
        let fh = max(2, (track.height - 2) * s)
        NSGradient(colors: [c, c.shadow(withLevel: 0.55) ?? c])?
            .draw(in: NSRect(x: track.minX + 2, y: track.minY + 1, width: track.width - 4, height: fh),
                  angle: -90)
        let f = Skin.mono(7)
        text("PRE", NSPoint(x: track.midX - width("PRE", f) / 2, y: 5), f, c)
    }

    // MARK: hover

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let preW: CGFloat = 16, x0 = preW + 14
        let slot = (bounds.width - x0 - 8) / CGFloat(BANDS.count)
        let i = Int((p.x - x0) / slot)
        let newIndex = (i >= 0 && i < BANDS.count && p.x >= x0) ? i : nil
        if newIndex != hoverIndex {
            hoverIndex = newIndex
            needsDisplay = true
            if let i = newIndex { onHover?(describe(i)) } else { onHover?(nil) }
        }
    }
    override func mouseExited(with e: NSEvent) {
        hoverIndex = nil; needsDisplay = true; onHover?(nil)
    }

    private func describe(_ i: Int) -> String {
        let m = Model.shared
        let b = BANDS[i]
        guard live else { return "\(i + 1). \(PHASES[i].name) — \(PHASES[i].label)" }
        let v = m.telemetry.values[i]
        let d = m.telemetry.details[i]
        let state = v < 0 ? "unknown" : v > 0.66 ? "good" : v > 0.33 ? "degraded" : "FAILING"
        return "\(b.label) (\(b.hz)Hz band) — \(state)\(d.isEmpty ? "" : " · \(d)")"
    }
}
```

- [ ] **Step 4: Swap it in and add the render hook**

In `tunnel/app/AppTunnel/Sources/main.swift`:

1. Find `let bars = PhaseBars(frame: .zero)` and replace with `let bars = Equalizer(frame: .zero)`.
2. Find `root.addSubview(bars)` and add directly after it:

```swift
        bars.onHover = { [weak self] t in self?.showHint(t) }
```

3. Delete the entire `final class PhaseBars: NSView { … }` block — `Equalizer` replaces it.
4. Find, in `applicationDidFinishLaunching`, the line `if let i = args.firstIndex(of: "--snapshot-log"), i + 1 < args.count {` and insert this block immediately **before** it:

```swift
        // Deterministic telemetry render for the test suite: synthetic values,
        // no live session needed.
        if let i = args.firstIndex(of: "--snapshot-eq"), i + 1 < args.count {
            let out = args[i + 1]
            let synthetic = """
            {"t": \(Date().timeIntervalSince1970),
             "link":1.0,"dns":0.92,"socks":1.0,"bridge":0.88,"exit":1.0,
             "rtt":0.61,"flow":0.34,"seal":1.0,"wall":1.0,"grip":1.0,
             "score":0.93,"exit_ip":"91.207.57.102",
             "detail":{"link":"gateway 192.168.85.229","dns":"48ms","socks":"127.0.0.1:1180 6ms",
                       "bridge":"12ms","exit":"91.207.57.102","rtt":"180ms","flow":"3 conn",
                       "seal":"0/3 reachable","wall":"60 rules","grip":"14 inside"}}
            """
            let dir = NSHomeDirectory() + "/.apptunnel"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? synthetic.write(toFile: dir + "/telemetry.json", atomically: true, encoding: .utf8)
            m.sessionActive = true
            _ = m.telemetry.poll()
            for _ in 0..<120 { w.bars.step() }
            w.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    if let d = rep.representation(using: .png, properties: [:]) {
                        try? d.write(to: URL(fileURLWithPath: out))
                        FileHandle.standardError.write("eq snapshot: \(out)\n".data(using: .utf8)!)
                    }
                }
                NSApp.terminate(nil)
            }
            return
        }
```

> **Note:** `--snapshot-eq` writes a synthetic `telemetry.json`. The suite must
> treat that file the same way it treats `apps.json` — see Task 7, Step 3.

- [ ] **Step 5: Build and render**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
tunnel/app/build.sh 2>&1 | grep -E 'error:|Built'
tunnel/app/AppTunnel.app/Contents/MacOS/AppTunnel --snapshot-eq /tmp/eq-live.png 2>&1 | tail -1
```

Expected: `Built: …` then `eq snapshot: /tmp/eq-live.png`. Open it and confirm: ten labelled bands (`LINK`…`GRIP`), a `PRE` slider on the left, `RTT` and `FLOW` visibly lower than the rest, nothing red.

- [ ] **Step 6: Verify the tests pass**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
tunnel/bin/tunnel-selfcheck.sh --quick 2>&1 | grep -E 'Equalizer.swift|valley|idle FLOW|render hook'
```

Expected: four `PASS` lines.

- [ ] **Step 7: Commit**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
git add tunnel/app/AppTunnel/Sources/ tunnel/bin/tunnel-selfcheck.sh
git commit -q -m "feat(app): live telemetry equalizer with valley-hold and preamp confidence"
```

---

### Task 6: Circuit and waterfall visualisations

The analyser currently toggles bars ↔ oscilloscope. Add two more modes, cycled by clicking: a **circuit** view showing the actual signal path with animated packets, and a **waterfall** of recent latency.

**Files:**
- Create: `tunnel/app/AppTunnel/Sources/Visualiser.swift`
- Modify: `tunnel/app/AppTunnel/Sources/main.swift`

**Interfaces:**
- Consumes: `BANDS`, `TelemetryStore`, `Skin`.
- Produces: `final class Visualiser: NSView` with `func step()` and `var mode: Int` (0 bars, 1 scope, 2 circuit, 3 waterfall), replacing the existing class of the same name in `main.swift`.

- [ ] **Step 1: Write the failing test**

Append to `tunnel/bin/tunnel-selfcheck.sh` in the `1c.` section:

```bash
[ -f "$SRCD/Visualiser.swift" ] \
  && pass "Visualiser.swift exists" || fail "Visualiser.swift exists"
for want in drawCircuit drawWaterfall; do
  grep -q "$want" "$SRCD/Visualiser.swift" 2>/dev/null \
    && pass "the analyser has $want" || fail "the analyser has $want"
done
grep -q 'modeCount' "$SRCD/Visualiser.swift" 2>/dev/null \
  && pass "clicking the analyser cycles all modes" \
  || fail "clicking the analyser cycles all modes"
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
tunnel/bin/tunnel-selfcheck.sh --quick 2>&1 | grep -E 'Visualiser.swift|drawCircuit|drawWaterfall|cycles'
```

Expected: four `FAIL` lines.

- [ ] **Step 3: Write the view**

Create `tunnel/app/AppTunnel/Sources/Visualiser.swift`. Move the existing `final class Visualiser: NSView { … }` out of `main.swift` into this file (cut, not copy), prefix it with:

```swift
// Visualiser.swift — the analyser panel. Click to cycle:
//   0 bars · 1 oscilloscope · 2 circuit · 3 latency waterfall
// Circuit and waterfall are driven by live telemetry rather than by decoration.

import AppKit
```

Then make these four edits inside the moved class:

1. Replace `var scopeMode = false` with:

```swift
    var mode = 0
    let modeCount = 4
    private var packets: [CGFloat] = [0, 0.25, 0.5, 0.75]   // positions 0..1 along the path
```

2. Replace the `mouseDown` implementation with:

```swift
    override func mouseDown(with e: NSEvent) {
        mode = (mode + 1) % modeCount
        needsDisplay = true
    }
```

3. In `step()`, find `tick += 1` and insert immediately before it:

```swift
        // Packets travel faster when latency is low; they stall when the
        // tunnel is down, so the animation carries real information.
        let t = Model.shared.telemetry
        let speed: CGFloat = t.fresh ? 0.004 + CGFloat(max(0, t.values[5])) * 0.016 : 0
        for i in 0..<packets.count {
            packets[i] += speed
            if packets[i] > 1 { packets[i] -= 1 }
        }
```

4. Replace the body of `draw(_:)` with:

```swift
    override func draw(_ r: NSRect) {
        Skin.lcd.setFill(); bounds.fill()
        switch mode {
        case 1: drawScope()
        case 2: drawCircuit()
        case 3: drawWaterfall()
        default: drawBars()
        }
    }
```

Rename the existing bar-drawing body into `private func drawBars()` and the
oscilloscope body into `private func drawScope()`, then append these two new
methods inside the class:

```swift
    /// The actual signal path. A hop dims and reddens when its band fails, so
    /// you can see *where* the tunnel is broken rather than only that it is.
    private func drawCircuit() {
        let t = Model.shared.telemetry
        let hops = [("APP", 9), ("BRDG", 3), ("SOCKS", 2), ("EXIT", 4)]   // band indices
        let y = bounds.midY
        let pad: CGFloat = 16
        let span = bounds.width - pad * 2
        let step = span / CGFloat(hops.count - 1)

        // wire
        for i in 0..<(hops.count - 1) {
            let a = NSPoint(x: pad + step * CGFloat(i), y: y)
            let b = NSPoint(x: pad + step * CGFloat(i + 1), y: y)
            let v = t.fresh ? t.values[hops[i + 1].1] : -1
            let c: NSColor = v < 0 ? NSColor(white: 0.3, alpha: 1)
                           : v > 0.66 ? Skin.greenMid : v > 0.33 ? Skin.amber : Skin.red
            c.setStroke()
            let p = NSBezierPath()
            p.lineWidth = 1
            p.move(to: a); p.line(to: b); p.stroke()
        }

        // packets in flight
        if t.fresh {
            for pos in packets {
                let x = pad + span * pos
                Skin.green.withAlphaComponent(0.9).setFill()
                NSRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3).fill()
            }
        }

        // nodes
        for (i, hop) in hops.enumerated() {
            let x = pad + step * CGFloat(i)
            let v = t.fresh ? t.values[hop.1] : -1
            let c: NSColor = v < 0 ? NSColor(white: 0.35, alpha: 1)
                           : v > 0.66 ? Skin.green : v > 0.33 ? Skin.amber : Skin.red
            let box = NSRect(x: x - 5, y: y - 5, width: 10, height: 10)
            c.setFill(); box.fill()
            let f = Skin.mono(7)
            text(hop.0, NSPoint(x: x - width(hop.0, f) / 2, y: y - 18), f, c)
        }
    }

    /// Latency history, newest on the right — a seismograph for the tunnel.
    private func drawWaterfall() {
        let h = Model.shared.telemetry.history
        guard !h.isEmpty else {
            let f = Skin.mono(8)
            text("no samples yet", NSPoint(x: 8, y: bounds.midY - 4), f, Skin.greenDim)
            return
        }
        let n = min(h.count, Int(bounds.width))
        let slice = h.suffix(n)
        let colW = bounds.width / CGFloat(n)
        for (i, v) in slice.enumerated() {
            let x = CGFloat(i) * colW
            let bh = max(1, CGFloat(v) * (bounds.height - 2))
            let c: NSColor = v > 0.66 ? Skin.green : v > 0.33 ? Skin.amber : Skin.red
            c.withAlphaComponent(0.85).setFill()
            NSRect(x: x, y: 1, width: max(1, colW - 0.5), height: bh).fill()
        }
        let f = Skin.mono(7)
        text("RTT", NSPoint(x: 4, y: bounds.height - 10), f, Skin.greenDim)
    }
```

- [ ] **Step 4: Update the analyser tooltip**

In `main.swift`, find `toolTip = "Click to switch between analyser and oscilloscope"` and replace with:

```swift
        toolTip = "Click to cycle: spectrum · oscilloscope · signal path · latency history"
```

- [ ] **Step 5: Build and verify**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
tunnel/app/build.sh 2>&1 | grep -E 'error:|Built'
tunnel/bin/tunnel-selfcheck.sh --quick 2>&1 | grep -E 'Visualiser.swift|drawCircuit|drawWaterfall|cycles'
```

Expected: `Built: …` and four `PASS` lines.

- [ ] **Step 6: Commit**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
git add tunnel/app/AppTunnel/Sources/ tunnel/bin/tunnel-selfcheck.sh
git commit -q -m "feat(app): circuit and latency-waterfall analyser modes"
```

---

### Task 7: Suite hygiene, live proof, and documentation

Two loose ends: the suite must protect the new state file the way it protects the others, and the band meanings must be documented where someone will find them.

**Files:**
- Modify: `tunnel/bin/tunnel-selfcheck.sh`, `tunnel/README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: a suite that leaves `telemetry.json` exactly as it found it, plus a live end-to-end assertion when a session happens to be running.

- [ ] **Step 1: Write the failing test**

Append to `tunnel/bin/tunnel-selfcheck.sh` in the `1c.` section:

```bash
# The suite writes telemetry.json via --snapshot-eq; it must restore it, exactly
# as it does for apps.json. An earlier version of this harness destroyed the
# user's roster by removing a file it had not backed up.
grep -q 'telemetry.json' "$BIN/tunnel-selfcheck.sh" \
  && pass "the suite protects telemetry.json like its other state files" \
  || fail "the suite protects telemetry.json like its other state files"

# When a session is live, prove the whole chain really works.
if [ "$LIVE_SESSION" = 1 ] && [ -f "$STATE_DIR/telemetry.json" ]; then
  if /usr/bin/python3 -c '
import json, sys, time
d = json.load(open(sys.argv[1]))
assert time.time() - d["t"] < 120, "snapshot is stale"
assert d["seal"] in (-1.0, 1.0), "containment is neither unknown nor sealed: %s" % d["seal"]
' "$STATE_DIR/telemetry.json" 2>/dev/null; then
    pass "live telemetry is fresh and containment is intact"
  else
    fail "live telemetry is fresh and containment is intact"
  fi
else
  skip "live telemetry assertions (no running session)"
fi
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
tunnel/bin/tunnel-selfcheck.sh --quick 2>&1 | grep -E 'protects telemetry'
```

Expected: `FAIL  the suite protects telemetry.json like its other state files`

- [ ] **Step 3: Protect the new state file**

In `tunnel/bin/tunnel-selfcheck.sh` there are **three** places listing the state files. Change each to include `telemetry.json`:

```bash
for f in apps.json protected.json session.json; do
```

becomes, in the backup loop and in `restore_state`:

```bash
for f in apps.json protected.json session.json telemetry.json; do
```

- [ ] **Step 4: Add the render test**

In `tunnel/bin/tunnel-selfcheck.sh`, find:

```bash
  render --snapshot-log log.png  15000 "the log window renders text (not a blank black panel)"
```

Add directly after it:

```bash
  render --snapshot-eq  eq.png   20000 "the equalizer renders ten live telemetry bands"
```

- [ ] **Step 5: Run the whole suite**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
tunnel/bin/tunnel-selfcheck.sh 2>&1 | tail -5
```

Expected: `0 failed`. Then confirm the suite left nothing behind:

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
ls -la ~/.apptunnel/ | grep -E 'apps.json|telemetry.json' || echo "  (none — expected only if none existed before)"
```

- [ ] **Step 6: Document the bands**

Append to `tunnel/README.md`:

```markdown
## The equalizer is a live instrument

While connecting, the ten bars are the ten connection phases. Once the tunnel is
up they cross-fade into live telemetry, sampled about every 15 seconds by the
running launcher and published to `~/.apptunnel/telemetry.json`.

A band at full height is healthy — so a **falling** bar is the alarm. That
inverts the classic peak-hold into a **valley-hold**: the red tick on a band
marks the worst value seen in the last half-minute, so a brief outage stays
visible after it recovers.

| Band | Watches | Falls when |
|---|---|---|
| `LINK` | default route and gateway | no route, or the gateway stops answering |
| `DNS` | uncached resolution | resolution slows or stops |
| `SOCKS` | the endpoint published by the VPN | the listener moves or dies |
| `BRIDGE` | the local HTTP→SOCKS bridge | the bridge stalls or exits |
| `EXIT` | the public exit address | the VPN flaps and the exit IP changes |
| `RTT` | end-to-end latency through the tunnel | the path slows |
| `FLOW` | connections through the bridge | *never an alarm* — idle is dim, not red |
| `SEAL` | the guarded group's direct egress | anything becomes reachable directly |
| `WALL` | the PF anchor and that anchors are evaluated | rules vanish or stop being applied |
| `GRIP` | every app process still in the isolation group | a process escapes the group |

`SEAL`, `WALL` and `GRIP` are the security invariants. The **PRE** slider on the
left is overall confidence; if any of those three hits zero it is pinned to zero
and turns red, because partial protection is not protection.

Hover any band for its live reading. Grey means *not measured* — never red,
so an unmeasured band can never be mistaken for a failing one.

**Click the analyser** to cycle four modes: spectrum · oscilloscope · **signal
path** (app → bridge → SOCKS → exit, with packets that slow down as latency
rises and stop when the tunnel does) · **latency waterfall** (a seismograph of
recent round-trips).
```

- [ ] **Step 7: Commit**

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
git add tunnel/bin/tunnel-selfcheck.sh tunnel/README.md
git commit -q -m "test+docs: protect telemetry state, render-test the equalizer, document the bands"
```

- [ ] **Step 8: Prove it end to end**

This is the only step that needs a live tunnel. It restarts the roster apps.

```bash
cd "/Applications/Claude-Chatgpt Tunnel"
# Open AppTunnel, press play, wait for READY, then:
sleep 20
/usr/bin/python3 -m json.tool < ~/.apptunnel/telemetry.json
tunnel/bin/tunnel-selfcheck.sh 2>&1 | grep -E 'live telemetry|passed,'
```

Expected: a snapshot whose `seal` is `1.0`, `wall` is `1.0`, `grip` is `1.0` and
`score` above `0.9`; then `PASS  live telemetry is fresh and containment is
intact` and `0 failed`.

If `seal` reads `0.0`, **stop**: containment is genuinely broken and the band is
doing its job. Run `tunnel/bin/tunnel-doctor.sh` and treat it as a real defect.

---

## Self-Review

**Spec coverage.** The brief asked for creative graphics and charts, and for the equalizer to indicate diverse factors. Bands: Task 4 defines ten genuinely different factors spanning link, naming, proxy, transport, latency, throughput, containment, firewall and process integrity — not ten views of one number. Charts: Task 6 adds the circuit path and the latency waterfall; Task 5 adds the preamp and valley-hold. Animation: packet flow speed is driven by measured latency and stops when the tunnel does, so motion carries information rather than decorating it.

**Placeholders.** None. Every code step contains the code; every command states its expected output.

**Type consistency.** `BANDS` is ten entries in the fixed order `link dns socks bridge exit rtt flow seal wall grip`; `TelemetryStore.values` is indexed by that same order. Task 5 uses index 5 for `rtt` and Task 6 uses index 5 for packet speed, 9 for `grip`, 3 for `bridge`, 2 for `socks`, 4 for `exit` — all consistent with that list. The sampler in Task 1 emits exactly those keys plus `t`, `score`, `exit_ip`, `detail`, which is what `poll()` reads. `Equalizer` exposes `onHover` and `step()`, both of which `main.swift` calls in Task 5.

**Two risks worth naming.**

*Task 3 is a pure refactor with no behaviour change,* which is why its verification is a byte-identical render hash rather than a new assertion. If the hash differs, something moved that should not have.

*The `SEAL` band re-runs a real leak probe as the guarded group.* That is the most valuable band and the most invasive — it opens three sockets every sampling pass. It is deliberately gated on the launcher running as root and on knowing the gid, and the 15-second cadence keeps it to a few connections a minute. If it ever proves noisy, raise the cadence for that band alone rather than dropping it; a containment check that only ran once at connect time is exactly the weakness that made the original scripts print `PASS` while blocking nothing.
