# Re-attach: Stable Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A tunnelled app survives a disconnect and re-adopts the rebuilt tunnel without restarting.

**Architecture:** Every identity in the tunnel is currently derived from the launcher's PID (`$$`) — the isolation group, its GID, the PF anchor, and the bridge port — so a reconnect builds a tunnel the surviving app is not a member of and cannot reach. This plan makes those four identities fixed, stops teardown from killing apps, and makes connect adopt live group members instead of relaunching them. The app's `HTTP_PROXY` is baked in at `exec` and can never be changed afterward, which is why the bridge port in particular must be deterministic.

**Tech Stack:** bash 3.2 (macOS system bash), python3 via `tunnel-python.sh`, PF (`pfctl`), Directory Services (`dseditgroup`/`dscl`), a stdlib-only HTTP→SOCKS5 bridge.

## Global Constraints

- Target bash is macOS `/bin/bash` 3.2 — no `mapfile`, no associative arrays, no `${var^^}`.
- All python3 must go through `$PY` from `tunnel-python.sh`; never call `/usr/bin/python3` directly.
- `tunnel-selfcheck.sh` must run without sudo, launch nothing, and quit nothing.
- Tests in this project are grep-based static assertions in `tunnel-selfcheck.sh`, one per shipped bug.
- Fixed group name: `apptunnel`. Fixed GID: `57000`. Fixed anchor: `com.apple/apptunnel`. Fixed bridge port: `17080`, overridable via `TUNNEL_BRIDGE_PORT`.
- Fail loudly on identity collision. Never silently fall back to a different port or GID — an app pinned to a port cannot follow a fallback.
- `retire_orphaned_state` already preserves groups that have live processes and deletes only empty ones. Keep that behaviour; it is what makes a fixed group safe.

---

### Task 1: Stable identity

**Files:**
- Modify: `tunnel/bin/tunnel-lock.sh` (anchor line 60, group name line 69, bridge invocation ~828, group creation ~865)
- Test: `tunnel/bin/tunnel-selfcheck.sh`

**Interfaces:**
- Produces: `GROUP_NAME=apptunnel`, `GROUP_GID=57000`, `ANCHOR=com.apple/apptunnel`, `BRIDGE_PORT` defaulting to `17080`. Tasks 3 and 4 rely on all four being constant across runs.

- [x] **Step 1: Write the failing test**

Add to `tunnel-selfcheck.sh`, after the existing `tunnel-connect.sh` ordering test:

```bash
# Re-attach requires identity that survives a reconnect. Keying the group, the
# anchor or the bridge port to $$ built a tunnel the surviving app was not a
# member of and could not reach, so reconnecting forced a relaunch.
for pat in 'ANCHOR="com.apple/apptunnel-\$\$"' 'GROUP_NAME="apptun\$\$"' 'GROUP_GID=\$((57000 + (\$\$ % 500)))'; do
  if grep -q "$pat" "$BIN/tunnel-lock.sh"; then
    fail "tunnel-lock.sh does not key tunnel identity to \$\$ ($pat)"
  else
    pass "tunnel-lock.sh does not key tunnel identity to \$\$ ($pat)"
  fi
done
grep -q 'BRIDGE_PORT="\${TUNNEL_BRIDGE_PORT:-17080}"' "$BIN/tunnel-lock.sh" \
  && pass "tunnel-lock.sh pins the bridge to a fixed port" \
  || fail "tunnel-lock.sh pins the bridge to a fixed port"
```

- [x] **Step 2: Run test to verify it fails**

Run: `tunnel/bin/tunnel-selfcheck.sh --quick 2>&1 | grep -E "identity to|fixed port"`
Expected: 4 FAIL lines.

- [x] **Step 3: Implement**

In `tunnel-lock.sh` replace line 60:

```bash
# Fixed anchor. A surviving app must still be covered when the tunnel is
# rebuilt, so the anchor cannot be per-session. Single-instance is enforced by
# STATE_FILE, which is what makes one shared anchor safe.
ANCHOR="com.apple/apptunnel"
```

Replace line 69:

```bash
GROUP_NAME="apptunnel"
```

Replace line 79 (`BRIDGE_PORT=""`):

```bash
# Fixed: the app's HTTP_PROXY is baked in at exec and cannot be changed
# afterward, so a rebuilt bridge MUST return on the same port or every
# surviving app is left pointing at a dead one.
BRIDGE_PORT="${TUNNEL_BRIDGE_PORT:-17080}"
```

Replace the GID block at ~865:

```bash
GROUP_GID=57000
existing_gid="$(/usr/bin/dscl . -read "/Groups/$GROUP_NAME" PrimaryGroupID 2>/dev/null | awk '{print $2}')"
if [ -n "$existing_gid" ]; then
  GROUP_GID="$existing_gid"
  log "      reusing isolation group $GROUP_NAME (gid=$GROUP_GID)"
else
  if /usr/bin/dscl . -search /Groups PrimaryGroupID "$GROUP_GID" 2>/dev/null | grep -q .; then
    die "gid $GROUP_GID is held by another group. Set TUNNEL_BRIDGE_PORT aside and free the gid, or run tunnel-doctor.sh --fix."
  fi
  sudo /usr/sbin/dseditgroup -o create -i "$GROUP_GID" "$GROUP_NAME" >/dev/null
  GROUP_CREATED=1
fi
sudo /usr/sbin/dseditgroup -o edit -a "$LOGIN_USER" -t user "$GROUP_NAME" >/dev/null
```

In the embedded bridge python, add the argument and use it:

```python
ap.add_argument("--port", type=int, default=0)
```

and change `with Server(("127.0.0.1", 0), Handler) as srv:` to:

```python
with Server(("127.0.0.1", args.port), Handler) as srv:
```

Pass it at the invocation (~828):

```bash
"$PY" "$BRIDGE_SCRIPT" --socks-host "$SOCKS_HOST" --socks-port "$SOCKS_PORT" \
  --port "$BRIDGE_PORT" --port-file "$BRIDGE_PORT_FILE" >"$BRIDGE_LOG" 2>&1 &
```

- [x] **Step 4: Run test to verify it passes**

Run: `tunnel/bin/tunnel-selfcheck.sh --quick 2>&1 | tail -4`
Expected: 0 failed.

- [x] **Step 5: Commit**

```bash
git add tunnel/bin/tunnel-lock.sh tunnel/bin/tunnel-selfcheck.sh
git commit -m "feat(lock): pin tunnel identity so a rebuilt tunnel is the same tunnel"
```

---

### Task 2: Teardown stops killing apps

**Files:**
- Modify: `tunnel/bin/tunnel-lock.sh` (`cleanup()` ~368-377, group deletion ~398-403, escape handler ~1364-1369)
- Test: `tunnel/bin/tunnel-selfcheck.sh`

**Interfaces:**
- Consumes: stable `GROUP_NAME` from Task 1.
- Produces: teardown that leaves `APP_WRAPPER_PIDS` and `APP_MAIN_PIDS` running and leaves the group in place. Task 4 relies on the group surviving teardown.

- [x] **Step 1: Write the failing test**

```bash
# Teardown killed every tunnelled app on any exit, so one transient failure
# destroyed live Claude/Codex sessions. Fail-closed must mean no network, not
# no process.
if awk '/^cleanup\(\)/,/^}/' "$BIN/tunnel-lock.sh" | grep -qE 'kill .*APP_(WRAPPER|MAIN)_PIDS|APP_(WRAPPER|MAIN)_PIDS.*kill'; then
  fail "cleanup() does not signal tunnelled apps"
else
  pass "cleanup() does not signal tunnelled apps"
fi
if grep -q 'failing closed: dropping the network, apps left running' "$BIN/tunnel-lock.sh"; then
  pass "escape handler cuts the network without killing apps"
else
  fail "escape handler cuts the network without killing apps"
fi
```

- [x] **Step 2: Run test to verify it fails**

Run: `tunnel/bin/tunnel-selfcheck.sh --quick 2>&1 | grep -E "does not signal|without killing"`
Expected: 2 FAIL lines.

- [x] **Step 3: Implement**

In `cleanup()`, delete the wrapper-kill loop entirely and replace with:

```bash
  # Deliberately does NOT signal APP_WRAPPER_PIDS or APP_MAIN_PIDS. Dropping PF
  # and the bridge already denies these apps the network, which is the property
  # the guard exists to provide. Killing them additionally destroyed live
  # sessions on every transient failure, and is what made a reconnect need a
  # relaunch. tunnel-quit.sh is the one path that closes them, on purpose.
```

Replace the `GROUP_CREATED` deletion block with:

```bash
  # The group is persistent so a surviving app stays a member across a
  # reconnect. retire_orphaned_state deletes it at the next connect if it is
  # empty; tunnel-quit.sh deletes it after closing the apps.
```

Replace the escape handler body (`if [ "$bad" -gt 0 ]`):

```bash
  if [ "$bad" -gt 0 ]; then
    emit 12 ESCAPE fail "$bad process(es) left the isolation group - failing closed"
    log "Failing closed: dropping the network, apps left running."
    exit 70
  fi
```

- [x] **Step 4: Run test to verify it passes**

Run: `tunnel/bin/tunnel-selfcheck.sh --quick 2>&1 | tail -4`
Expected: 0 failed.

- [x] **Step 5: Commit**

```bash
git add tunnel/bin/tunnel-lock.sh tunnel/bin/tunnel-selfcheck.sh
git commit -m "fix(lock): fail closed by cutting the network, not by killing sessions"
```

---

### Task 3: Connect adopts live group members

**Files:**
- Modify: `tunnel/bin/tunnel-lock.sh` (launch loop ~1125-1160, `join_app` ~1228)
- Test: `tunnel/bin/tunnel-selfcheck.sh`

**Interfaces:**
- Consumes: stable `GROUP_GID` (Task 1), surviving processes (Task 2).
- Produces: `group_pids_for_exe <exe>` printing PIDs of live group members running `<exe>`. Used by the launch loop and by `join_app`.

- [x] **Step 1: Write the failing test**

```bash
# A reconnect must adopt the processes that are already inside the group
# instead of quitting and relaunching them.
grep -q '^group_pids_for_exe()' "$BIN/tunnel-lock.sh" \
  && pass "tunnel-lock.sh can find live members of the isolation group" \
  || fail "tunnel-lock.sh can find live members of the isolation group"
grep -q 'already inside the tunnel; adopting' "$BIN/tunnel-lock.sh" \
  && pass "tunnel-lock.sh adopts a running app instead of relaunching it" \
  || fail "tunnel-lock.sh adopts a running app instead of relaunching it"
if awk '/^join_app\(\)/,/^}/' "$BIN/tunnel-lock.sh" | grep -q 'group_pids_for_exe'; then
  pass "join_app skips the quit for an app already in the group"
else
  fail "join_app skips the quit for an app already in the group"
fi
```

- [x] **Step 2: Run test to verify it fails**

Run: `tunnel/bin/tunnel-selfcheck.sh --quick 2>&1 | grep -E "live members|adopts a running|skips the quit"`
Expected: 3 FAIL lines.

- [x] **Step 3: Implement**

Add above the phase 10 launch loop:

```bash
# PIDs of live processes that are already inside the isolation group AND are
# running this executable. Main-executable matches only, same rule as
# main_pids_of: a bare `grep -F` matches the grep process itself.
group_pids_for_exe() {
  ps -axo pid=,gid=,command= | awk -v g="$GROUP_GID" -v e="$1" '
    {p=$1; gg=$2; $1=""; $2=""; sub(/^[ \t]+/,"");
     if (gg==g && ($0==e || index($0, e " ")==1)) print p}'
}
```

In the launch loop, guard the launch:

```bash
  adopted="$(group_pids_for_exe "$exe" | head -1)"
  if [ -n "$adopted" ]; then
    log "      $name already inside the tunnel; adopting pid $adopted"
    APP_MAIN_PIDS+=("$adopted")
    idx=$((idx+1))
    continue
  fi
```

In the verification loop, skip executables that were adopted:

```bash
  if group_pids_for_exe "$exe" | grep -q .; then idx=$((idx+1)); continue; fi
```

In `join_app`, before the quit block:

```bash
  adopted="$(group_pids_for_exe "$exe" | head -1)"
  if [ -n "$adopted" ]; then
    APP_MAIN_PIDS+=("$adopted")
    emit 13 JOIN ok "$name already inside the tunnel; adopting pid $adopted"
    return 0
  fi
```

- [x] **Step 4: Run test to verify it passes**

Run: `tunnel/bin/tunnel-selfcheck.sh --quick 2>&1 | tail -4`
Expected: 0 failed.

- [x] **Step 5: Commit**

```bash
git add tunnel/bin/tunnel-lock.sh tunnel/bin/tunnel-selfcheck.sh
git commit -m "feat(lock): adopt live group members instead of relaunching them"
```

---

### Task 4: Quitting AppTunnel closes the tunnelled apps

**Files:**
- Create: `tunnel/bin/tunnel-quit.sh`
- Modify: `tunnel/gui/tunneld.py` (path constants ~30, shutdown path ~362)
- Test: `tunnel/bin/tunnel-selfcheck.sh`

**Interfaces:**
- Consumes: stable `GROUP_NAME`/`GROUP_GID` (Task 1), group surviving teardown (Task 2).
- Produces: `tunnel-quit.sh`, exit 0 on success. Closes every live group member, then deletes the group.

- [x] **Step 1: Write the failing test**

```bash
# Stop leaves apps running so they can re-adopt; quitting AppTunnel is the one
# action that closes them.
if [ -x "$BIN/tunnel-quit.sh" ]; then
  pass "tunnel-quit.sh exists and is executable"
else
  fail "tunnel-quit.sh exists and is executable"
fi
bash -n "$BIN/tunnel-quit.sh" 2>/dev/null \
  && pass "tunnel-quit.sh parses" || fail "tunnel-quit.sh parses"
grep -q 'tunnel-quit.sh' "$HERE/../gui/tunneld.py" \
  && pass "the GUI closes tunnelled apps when it shuts down" \
  || fail "the GUI closes tunnelled apps when it shuts down"
```

- [x] **Step 2: Run test to verify it fails**

Run: `tunnel/bin/tunnel-selfcheck.sh --quick 2>&1 | grep -E "tunnel-quit|GUI closes"`
Expected: 3 FAIL lines.

- [x] **Step 3: Implement**

Create `tunnel/bin/tunnel-quit.sh`:

```bash
#!/bin/bash
# tunnel-quit.sh — close every app inside the tunnel, then retire the group.
#
# Stop and an accidental disconnect both leave tunnelled apps running with no
# network so they can re-adopt a rebuilt tunnel. Quitting AppTunnel is the one
# action that is meant to take them down with it, which is what this does.

set -uo pipefail
GROUP_NAME="${TUNNEL_GROUP_NAME:-apptunnel}"

GROUP_GID="$(/usr/bin/dscl . -read "/Groups/$GROUP_NAME" PrimaryGroupID 2>/dev/null | awk '{print $2}')"
[ -n "$GROUP_GID" ] || { echo "tunnel-quit: no isolation group; nothing to close"; exit 0; }

members() { ps -axo pid=,gid= | awk -v g="$GROUP_GID" '$2==g{print $1}'; }

names_of() {
  ps -axo pid=,gid=,command= | awk -v g="$GROUP_GID" '
    $2==g {p=$1; $1="";$2=""; sub(/^[ \t]+/,"");
           if (match($0, /\/([^\/]+)\.app\/Contents\/MacOS\//)) {
             s=substr($0, RSTART+1, RLENGTH-1); sub(/\.app.*/,"",s); print s }}' | sort -u
}

for name in $(names_of); do
  /usr/bin/osascript -e "tell application \"$name\" to quit" >/dev/null 2>&1 || true
done

i=0
while [ "$i" -lt 30 ]; do
  [ -z "$(members)" ] && break
  sleep 0.5; i=$((i+1))
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

if [ -z "$(members)" ]; then
  sudo -n /usr/sbin/dseditgroup -o delete "$GROUP_NAME" >/dev/null 2>&1 || true
  echo "tunnel-quit: tunnelled apps closed"
else
  echo "tunnel-quit: some processes would not exit: $(members | tr '\n' ' ')" >&2
  exit 1
fi
```

In `tunneld.py`, add next to the other path constants:

```python
QUIT = os.path.join(BIN, "tunnel-quit.sh")
```

and replace the shutdown handler:

```python
    except KeyboardInterrupt:
        pass
    finally:
        # Quitting AppTunnel closes the apps it put inside the tunnel. Stop and
        # an accidental disconnect deliberately do not.
        try:
            subprocess.run([QUIT], timeout=60)
        except Exception:
            pass
        print("\nGUI stopped.")
```

Add `REPAIR`'s sibling to the chmod loop: `for p in (LOCK, DOCTOR, REPAIR, QUIT):`

- [x] **Step 4: Run test to verify it passes**

Run: `tunnel/bin/tunnel-selfcheck.sh --quick 2>&1 | tail -4`
Expected: 0 failed.

- [x] **Step 5: Commit**

```bash
git add tunnel/bin/tunnel-quit.sh tunnel/bin/tunnel-selfcheck.sh tunnel/gui/tunneld.py
git commit -m "feat(quit): closing AppTunnel closes the apps inside the tunnel"
```

---

## Verification

After all four tasks:

```bash
tunnel/bin/tunnel-selfcheck.sh --quick     # expect 0 failed
for f in tunnel/bin/*.sh; do bash -n "$f" || echo "SYNTAX: $f"; done
python3 -m py_compile tunnel/gui/tunneld.py
```

Live re-attach check, run by hand with a tunnel session up: note a tunnelled app's PID, press Stop, confirm the PID is still alive and has no network, press Connect, confirm the log says `adopting pid <same pid>` and the app reaches the network again without restarting.
