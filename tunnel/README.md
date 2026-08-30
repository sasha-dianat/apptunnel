# apptunnel — Winamp-style control panel for the Shadowsocks app tunnel

Double-click **`AppTunnel.app`**. It is a real macOS application — native
AppKit, no browser, no web view.

```
Claude-Chatgpt Tunnel/
├── AppTunnel.app               ← double-click this
├── chatgpt-codex-…-v1.1.sh     ← original scripts (left untouched)
├── claude-desktop-…-v5.4.sh    ← original scripts (left untouched)
└── tunnel/
    ├── bin/tunnel-lock.sh      ← fixed, generalised launcher (v2.0)
    ├── bin/tunnel-doctor.sh    ← diagnose / repair leftovers
    ├── bin/tunnel-dnsguard.sh  ← find & disarm machine-wide DNS blocks
    ├── bin/tunnel-migrate.sh   ← retire legacy sessions, restart under the app
    ├── bin/tunnel-testkit.sh   ← protect the host app so testing cannot kill your session
    ├── bin/tunnel-netrescue.sh ← diagnose / DHCP / graded network recovery
    ├── bin/tunnel-freehost.sh  ← pull an app OUT of every tunnel, back to normal
    ├── bin/tunnel-selfcheck.sh ← regression suite (no sudo, touches nothing)
    ├── app/AppTunnel/Sources/  ← Swift source for the app
    ├── app/build.sh            ← rebuild it (swiftc, no Xcode project)
    └── gui/                    ← superseded browser UI, kept as a fallback
```

Rebuild after editing the Swift source:

```bash
"/Applications/Claude-Chatgpt Tunnel/tunnel/app/build.sh"
```

## The controls

| Button | Does |
|---|---|
| `\|<<` | **CHECK** — read-only health report: VPN endpoint, leftover firewall rules, orphaned groups, stale proxy settings |
| `>` | **Connect** — runs `tunnel-lock.sh` for every enabled app |
| `\|\|` | **Demo** — plays the ten-phase animation, touching nothing |
| `[]` | **Disconnect** — ends the session and restores all state |
| `>>\|` | **REPAIR** — removes orphans and stale state; never touches DHCP, DNS or Wi-Fi |
| `TEST` | Toggles test mode — protects the app this panel runs inside |
| `+ ADD APP` | Adds an app via the standard macOS open panel |
| `- REMOVE` | Removes the selected roster row |
| `DNS RESCUE` | Disarms machine-wide DNS blocks (use if the Internet dies) |

**Hover any button** for a one-line description of exactly what it does. It
appears both as a normal macOS tooltip and, immediately, in the caption strip
under the phase bars — so you can read it without waiting for the tooltip delay.

Click a roster row's checkbox to include/exclude it; double-click the row does
the same. The ten bars are the connection phases, filling live from the running
launcher.

**No Terminal windows.** Anything needing root goes through the standard macOS
authorisation dialog and then detaches into the background. macOS handles the
password; it never passes through the app. Script output comes back in a
Winamp-styled log window instead of a terminal.

Click the analyser to switch between the bar spectrum and the oscilloscope.

## The ten phases

1. **PREFLIGHT** — tools present, app bundles resolved, apps fully quit
2. **SOCKS** — the endpoint published in the system proxy settings is located (VeePN uses 1180 on some profiles) and reaches the Internet
3. **BRIDGE** — localhost HTTP CONNECT → SOCKS5 bridge up, exit IP matches
4. **PRIV** — sudo acquired, keepalive started
5. **GROUP** — temporary isolation group created, effective-gid switch verified
6. **FIREWALL** — group-scoped PF rules loaded and confirmed present in the anchor
7. **CALIBRATE** — an *unguarded* probe must reach the Internet, otherwise the leak test cannot tell "blocked" from "offline"
8. **LEAKTEST** — the guarded group must reach **0 of 5** targets directly
9. **PROXYPATH** — a guarded process reaches the Internet through the bridge, at the tunnel's exit IP; app config injected
10. **LAUNCH** — apps started inside the group, process tree audited

Any phase that fails aborts and rolls everything back.

## If your Internet dies

Almost certainly a leftover machine-wide DNS block from the old scripts:

```bash
"/Applications/Claude-Chatgpt Tunnel/tunnel/bin/tunnel-dnsguard.sh" --fix
```

It removes only port-53/853 rules that lack a `group` clause; group-scoped rules
are left alone. **Do not reset your network settings** — the problem is a PF
anchor, not DHCP.

A related trap: `sudo pfctl -E` enables PF *without* loading `/etc/pf.conf`,
leaving an empty main ruleset in which no anchor is ever evaluated. That is why
the old scripts could print `PASS` while blocking nothing. Repair with
`sudo pfctl -f /etc/pf.conf`, then run `tunnel-dnsguard.sh --fix`, because
restoring anchor evaluation also arms any stale anchor still loaded.

## Adding one app without disturbing the others

Each ticked roster row carries a **RUN** chip on the right. Press it and that
single app joins the tunnel that is already running — every other app keeps
running, untouched.

* **play** starts a tunnel with **every** ticked app at once.
* **RUN** adds **one** app to a tunnel that is already up.
* A row shows **IN** instead of RUN once that app is inside the tunnel.

One unavoidable restriction: the app being added is quit and reopened. macOS
cannot move a running process into a different primary group, and if the app is
already open outside the tunnel LaunchServices just reactivates that untunnelled
process. Only the app you pressed RUN on is restarted.

No second password prompt: the launcher is already running as root, so the app
asks it to do the join by writing `~/.apptunnel/run-request`, exactly as the
stop button writes `~/.apptunnel/stop`. The launcher polls for it, quits only
that one app, relaunches it inside the isolation group, verifies its gid, and
adds it to the audited process set.

## Multiple apps — do they start automatically?

**Yes.** Every ticked app is launched *for you* at phase 10, into one shared
isolation group. You do not start them yourself, and you must not: an app you
open from Finder or the Dock gets your normal login group and is therefore
**outside** the tunnel, with no firewall rules applied to it.

So the rule is: tick it in the roster, press play, let the launcher open it.

Adding an app to the roster while a tunnel is running does not pull it in by
itself — but you do **not** have to restart the session. Tick it, then press its
**RUN** chip and it joins the live tunnel on its own (see above).

## What this never touches

DHCP, DNS server settings, network service order, Wi-Fi, and the system proxy
configuration. Those are read for display only. The only writes are:

* a temporary Unix group (removed on exit),
* PF rules inside a per-session anchor `com.apple/apptunnel-<pid>` (flushed on exit),
* proxy keys in `~/.claude/settings.json` / `~/.codex/.env` (restored on exit).

## What was fixed vs the v1.1 / v5.4 scripts

1. **Machine-wide DNS block removed.** The old rules blocked ports 53 and 853
   `from any to any` with no `group` clause, i.e. for the whole Mac. Combined
   with a failed cleanup this takes DNS away from every app — which looks
   exactly like broken DHCP. The group-scoped rule already covers those ports
   for the guarded processes.
2. **Calibrated leak test.** The old test called curl against one URL and read
   "connection failed" as "PF blocked it". If that URL was unreachable for any
   other reason the test passed while nothing was blocked. Phase 7 now proves
   the probe *can* succeed before phase 8 trusts it failing.
3. **Probe uses raw TCP to five literal IPs** — no DNS, no dependence on one
   website being up.
4. **sudo keepalive.** Cleanup used `sudo -n`, which fails once the five-minute
   sudo timestamp expires, so long sessions leaked PF anchors, groups and bridge
   processes on every exit. Cleanup failures are now reported instead of
   swallowed by `|| true`.
5. **Per-session anchor** `com.apple/apptunnel-<pid>`, globbable as
   `apptunnel-*` so orphans stay findable. A single shared anchor name is worse
   than the old `$$` scheme: a second run's teardown flushes the *first* run's
   rules and silently disarms a live session.
6. **Anchor reachability check** — never claims protection while the main PF
   ruleset lacks `anchor "com.apple/*"`, since loaded anchors are then silently
   ignored. It repairs that condition itself (see 9) and only aborts if the
   repair fails.
7. **bash 3.2 safe** — empty arrays no longer trip `set -u` before the friendly
   error message.
8. **One group for many apps**, driven by the app's roster.
9. **PF main-ruleset self-repair.** `pfctl -E` enables PF *without* loading
   `/etc/pf.conf`, leaving a ruleset that references no anchors, so everything
   loaded into an anchor is ignored. The launcher now restores the stock
   `/etc/pf.conf` itself (after checking it really is stock), disarms any legacy
   anchor that repair re-arms, and only then continues.
10. **Runs without a Terminal.** The app elevates via the macOS authorisation
   dialog and detaches the launcher into the background. Because the launcher is
   then root-owned and cannot be signalled by the user, the stop button works
   through a flag file that the launcher polls.
11. **Atomic session lock**, claimed at phase 1 via `O_EXCL` rather than written
   at phase 10. Writing it last let two concurrent runs both pass the
   "already running?" check; the second run then tore down the first run's
   firewall and reported the first run's app as *"not in the isolation group"*,
   because it was comparing against its own gid. A stale lock whose pid is dead
   is reclaimed automatically.


## Testing from inside a tunnelled app

If the app you work in is itself on the roster, any connect or repair stops the
launcher that owns it — and your session dies with it. Arm protection first:

```bash
"/Applications/Claude-Chatgpt Tunnel/tunnel/bin/tunnel-testkit.sh" protect
```

That records the host app's whole process ancestry. `tunnel-connect.sh` then
refuses to signal those pids, and `tunnel-lock.sh` skips the host app instead of
quitting it. Check what a connect would do before running one:

```bash
"/Applications/Claude-Chatgpt Tunnel/tunnel/bin/tunnel-testkit.sh" preview
```

`tunnel-testkit.sh selftest` exercises phases 1–9 and launches nothing at all.

Two bugs this flushed out, both worth remembering:

* A diagnostic printed from inside the pid-filter went to **stdout**, which was
  the kill list itself — so the protected pid was fed straight back in and
  killed. Anything that filters pids must log to stderr, and the list is now
  passed through a numeric-only filter as a second line of defence.
* Repairing the pf main ruleset **arms every stale anchor at once**. Old v1.1 /
  v5.4 launchers that had been inert for hours suddenly start enforcing, and an
  app that was working fine gets firewalled by a launcher you had forgotten
  about. `tunnel-lock.sh` disarms machine-wide DNS blocks straight after the
  repair for this reason.

## When the app you work in loses the network

Symptom: intermittent "request failed", dropped sessions, hangs — but the Mac
itself is fine. Cause: that app is inside an isolation group whose firewall
rules are enforcing, and the launcher's proxy is stale.

```bash
sudo "/Applications/Claude-Chatgpt Tunnel/tunnel/bin/tunnel-freehost.sh"
```

Stops every launcher, flushes their anchors, deletes the temporary groups,
clears stale proxy config, and relaunches the app with ordinary networking.
`--app /Applications/X.app` picks a different app; `--no-relaunch` leaves it shut.

`tunnel-netrescue.sh diagnose` now reports this case explicitly: it checks
whether *your own shell* is in an isolation group and being filtered, which is
easy to mistake for the whole Mac being offline.

## Network recovery toolkit

```bash
"/Applications/Claude-Chatgpt Tunnel/tunnel/bin/tunnel-netrescue.sh" diagnose
```

Read-only, and it ends with a ranked verdict. Repairs, least invasive first:

| Command | Does |
|---|---|
| `fix-dns` | flush machine-wide DNS blocks + resolver cache — fixes most cases |
| `restore-pf` | reload Apple's stock `/etc/pf.conf` |
| `flush-pf` | flush every pf rule and disable pf |
| `renew-dhcp [iface]` | release and renew the DHCP lease |
| `backup` / `restore-backup` | save / restore the SystemConfiguration plists |
| `reset-network --i-understand` | last resort: back up, delete network prefs, reboot |

`reset-network` refuses to run without `--i-understand` and prints the cheaper
options first. It always takes a backup you can restore before rebooting. In
this project **no** failure has ever actually needed it — every one has been a
leftover pf anchor that `fix-dns` clears in under a second.


## Regression suite

```bash
"/Applications/Claude-Chatgpt Tunnel/tunnel/bin/tunnel-selfcheck.sh"
```

No sudo, launches nothing, quits nothing, and skips state-mutating tests while a
tunnel is live. Safe to run from inside a tunnelled app. It backs up and
restores `apps.json`, `protected.json` and `session.json` around itself. Exit
code is the number of failures.

It covers every defect this project has shipped, so none can come back quietly:

* no unscoped `port 53` rule is ever emitted (comment lines excluded — the first
  version of this test failed against the file's own documentation)
* PF rules are group-scoped
* pid filters log to stderr, never into the kill list, and the list is numeric-only
* `SUDO_USER` is not trusted unless actually running as root
* the session lock rejects a live owner and reclaims a stale one
* an all-protected roster explains itself instead of aborting silently
* the app never opens Terminal, elevates via the authorisation dialog, and tells
  root-run helpers which login user to act for
* the main window and the log window both render content, not blank panels

Two traps it exists to catch, both of which cost a working session:

* **`SUDO_USER` can be inherited as `root`.** These apps are launched through a
  `sudo -u <user> -g <group>` chain, so `${SUDO_USER:-$(id -un)}` resolves to
  `root` for an ordinary user. The doctor aborted after one line, which is what
  made its window look blank. Only trust `SUDO_USER` when `id -u` is 0.
* **`nc -z -w N` does not cap a silently dropped connection.** A probe from
  inside a guarded group hangs indefinitely — exactly when diagnosis is needed.
  All probes now use a Python socket with a hard timeout.


## "Shadowsocks is not available" at phase 2

The endpoint is **discovered**, not assumed. VeePN publishes its listener in the
macOS system proxy settings, and on some profiles/builds it uses **1180**, not
the 1080 everything here originally hardcoded. That produced

```
Nothing listening on 127.0.0.1:1080. Connect VeePN with Shadowsocks.
```

which no amount of disconnecting and reconnecting could fix, because nothing was
ever going to appear on 1080.

Check what your VPN actually published:

```bash
scutil --proxy | grep SOCKS
```

`tunnel-lock.sh`, the `.command` front end and AppTunnel all read `SOCKSProxy` /
`SOCKSPort` from there. If the advertised endpoint is not listening, the launcher
also scans 1080, 1180, 1081, 7890 and 1086 before giving up, and its error now
reports both the port it tried and the port the system advertised. `--socks-port`
still overrides everything.

## Sign-in is not remembered

A GUI app launched by plain `sudo` from a detached root process lands in the
System domain with **no audit session** (`getauid()` returns -1), so the login
keychain is unreachable and the app asks you to sign in on every launch.
`tunnel-lock.sh` now launches apps through `launchctl asuser "$LOGIN_UID"`,
which joins your Aqua session and restores keychain access.

To check from inside a tunnelled app:

```bash
security list-keychains        # must list login.keychain-db, not only System
```

`tunnel-selfcheck.sh` tests this directly whenever it runs inside a tunnelled app.


## What CHECK and REPAIR now look for

Beyond leftover groups, bridges and firewall anchors, both buttons diagnose the
failure modes that actually cost time on this machine:

**VPN / SOCKS endpoint**

* system SOCKS disabled → the VPN is not connected in Shadowsocks mode
* the advertised endpoint is not listening → and, crucially, it then scans
  1080 / 1180 / 1081 / 7890 / 1086 / 10808 and reports *"a SOCKS listener IS
  running on port N instead — the advertised port is stale"*. That mismatch is
  what made connecting fail no matter how often the VPN was reconnected
* the endpoint accepts connections but no request completes → half-connected VPN
* otherwise it proves the proxy end to end and prints the exit IP

**Tunnel app state**

* a stale session lock whose owner is gone, which silently blocks the next connect
* test mode left armed for an app that is no longer running, which silently drops
  that app from every connect
* `settings.json` / `.codex/.env` owned by root instead of you — the app cannot
  write them
* more than one launcher session running and fighting over the firewall state
  (counted as *sessions*, not processes: bash subshells inherit the parent's
  command line, so one session otherwise looks like three)
* an oversized event log slowing the animation

`--fix` repairs the safe ones: removes stale locks and stale protection, restores
config ownership, truncates the event log. It never guesses at the VPN.
