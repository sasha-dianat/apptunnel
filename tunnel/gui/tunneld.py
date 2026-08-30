#!/usr/bin/env python3
"""
tunneld.py - local control daemon for the Winamp-style tunnel GUI.

Binds to 127.0.0.1 on a random port with a per-run bearer token. Serves
index.html and a small JSON API. It shells out only to the two scripts in
../bin and to read-only inspection commands.

It does NOT change any macOS network setting. There is no code path here that
runs networksetup, ipconfig, route, or scutil in write mode.
"""

import json
import os
import re
import secrets
import shlex
import signal
import subprocess
import sys
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.normpath(os.path.join(HERE, "..", "bin"))
LOCK = os.path.join(BIN, "tunnel-lock.sh")
DOCTOR = os.path.join(BIN, "tunnel-doctor.sh")
STATE_DIR = os.path.expanduser("~/.apptunnel")
APPS_FILE = os.path.join(STATE_DIR, "apps.json")
EVENTS = os.path.join(STATE_DIR, "events.jsonl")
SESSION = os.path.join(STATE_DIR, "session.json")
TOKEN = secrets.token_urlsafe(24)

DEFAULT_ROSTER = [
    "/Applications/Claude.app",
    "/Applications/ChatGPT.app",
    "/Applications/Codex.app",
]

PHASES = [
    ("PREFLIGHT",  "Checking apps and tools"),
    ("SOCKS",      "Reaching the SOCKS5 endpoint"),
    ("BRIDGE",     "Raising the HTTP-to-SOCKS bridge"),
    ("PRIV",       "Requesting administrator rights"),
    ("GROUP",      "Creating the isolation group"),
    ("FIREWALL",   "Installing group-scoped PF rules"),
    ("CALIBRATE",  "Proving the leak test can detect egress"),
    ("LEAKTEST",   "Confirming no direct egress"),
    ("PROXYPATH",  "Verifying the tunnel path"),
    ("LAUNCH",     "Starting the protected apps"),
]


# --------------------------------------------------------------- helpers ---
def run(cmd, timeout=8):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except Exception as e:
        return 1, "", str(e)


def load_roster():
    os.makedirs(STATE_DIR, exist_ok=True)
    if os.path.exists(APPS_FILE):
        try:
            with open(APPS_FILE) as f:
                data = json.load(f)
            if isinstance(data, list):
                return data
        except Exception:
            pass
    roster = [{"path": p, "name": os.path.basename(p)[:-4], "enabled": True}
              for p in DEFAULT_ROSTER if os.path.isdir(p)]
    save_roster(roster)
    return roster


def save_roster(roster):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = APPS_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(roster, f, indent=2)
    os.replace(tmp, APPS_FILE)


def scan_apps():
    """Every .app bundle the user could add. Read-only directory listing."""
    out, seen = [], set()
    for root in ("/Applications", os.path.expanduser("~/Applications"),
                 "/Applications/Utilities"):
        if not os.path.isdir(root):
            continue
        try:
            names = sorted(os.listdir(root))
        except OSError:
            continue
        for n in names:
            if not n.endswith(".app"):
                continue
            p = os.path.join(root, n)
            if p in seen or not os.path.isdir(os.path.join(p, "Contents", "MacOS")):
                continue
            seen.add(p)
            out.append({"path": p, "name": n[:-4]})
    return out


def socks_state(host="127.0.0.1", port=1080):
    import socket
    try:
        s = socket.create_connection((host, port), 1.5)
        s.close()
        return True
    except Exception:
        return False


def session_state():
    if not os.path.exists(SESSION):
        return None
    try:
        with open(SESSION) as f:
            data = json.load(f)
    except Exception:
        return None
    pid = data.get("pid")
    try:
        os.kill(int(pid), 0)
    except Exception:
        return None
    return data


def system_readonly():
    """Read-only snapshot, purely informational for the GUI."""
    _, proxy, _ = run(["scutil", "--proxy"])
    m_h = re.search(r"SOCKSProxy\s*:\s*(\S+)", proxy)
    m_p = re.search(r"SOCKSPort\s*:\s*(\S+)", proxy)
    m_e = re.search(r"SOCKSEnable\s*:\s*(\S+)", proxy)
    _, dns, _ = run(["scutil", "--dns"])
    m_dns = re.search(r"nameserver\[0\]\s*:\s*(\S+)", dns)
    _, rt, _ = run(["route", "-n", "get", "default"])
    m_gw = re.search(r"gateway:\s*(\S+)", rt)
    return {
        "system_socks": ("%s:%s" % (m_h.group(1), m_p.group(1))
                         if (m_e and m_e.group(1) == "1" and m_h and m_p) else None),
        "dns": m_dns.group(1) if m_dns else None,
        "gateway": m_gw.group(1) if m_gw else None,
    }


def leftovers():
    """Count orphans without changing anything."""
    _, g, _ = run(["dscl", ".", "-list", "/Groups", "PrimaryGroupID"])
    groups = []
    for line in g.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].isdigit() and 57000 <= int(parts[1]) < 58000:
            groups.append(parts[0])
    _, ps, _ = run(["ps", "-axo", "pid=,command="])
    bridges = [l.split()[0] for l in ps.splitlines() if "http_to_socks.py" in l]
    stale = []
    for label, path in (
        ("~/.claude/settings.json", os.path.expanduser("~/.claude/settings.json")),
        ("~/.codex/.env", os.path.expanduser("~/.codex/.env")),
    ):
        try:
            txt = open(path, encoding="utf-8").read()
        except Exception:
            continue
        m = re.search(r"HTTP_PROXY\"?\s*[:=]\s*\"?http://127\.0\.0\.1:(\d+)", txt)
        if m:
            port = int(m.group(1))
            stale.append({"file": label, "port": port, "alive": socks_state(port=port)})
    return {"groups": groups, "bridges": bridges, "stale_proxy": stale}


def read_events(since=0):
    if not os.path.exists(EVENTS):
        return []
    out = []
    try:
        with open(EVENTS) as f:
            for i, line in enumerate(f):
                if i < since:
                    continue
                line = line.strip()
                if line:
                    try:
                        out.append(json.loads(line))
                    except Exception:
                        pass
    except Exception:
        pass
    return out


def terminal(cmd_argv, title):
    """Run a command in Terminal.app so sudo can prompt for the password there.

    The GUI deliberately never handles the password itself.
    """
    cmd = " ".join(shlex.quote(a) for a in cmd_argv)
    script = 'clear; echo "%s"; %s; echo; echo "[window can be closed]"' % (title, cmd)
    osa = 'tell application "Terminal"\nactivate\ndo script %s\nend tell' % json.dumps(script)
    return run(["osascript", "-e", osa], timeout=15)


# ------------------------------------------------------------------ HTTP ---
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):  # noqa: A002 - signature fixed by base class
        pass

    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _auth(self, q):
        return q.get("token", [""])[0] == TOKEN

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)

        if u.path in ("/", "/index.html"):
            try:
                with open(os.path.join(HERE, "index.html"), "rb") as f:
                    html = f.read()
            except OSError:
                return self._send(500, "index.html missing", "text/plain")
            html = html.replace(b"__TOKEN__", TOKEN.encode())
            return self._send(200, html, "text/html; charset=utf-8")

        if not u.path.startswith("/api/"):
            return self._send(404, "not found", "text/plain")
        if not self._auth(q):
            return self._send(403, {"error": "bad token"})

        if u.path == "/api/state":
            sess = session_state()
            return self._send(200, {
                "phases": [{"name": n, "label": l} for n, l in PHASES],
                "socks": socks_state(),
                "session": sess,
                "roster": load_roster(),
                "system": system_readonly(),
                "leftovers": leftovers(),
                "scripts_ok": os.path.isfile(LOCK) and os.path.isfile(DOCTOR),
            })

        if u.path == "/api/events":
            since = int(q.get("since", ["0"])[0])
            ev = read_events(since)
            return self._send(200, {"since": since + len(ev), "events": ev})

        if u.path == "/api/scan":
            return self._send(200, {"apps": scan_apps()})

        return self._send(404, {"error": "unknown endpoint"})

    def do_POST(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if not self._auth(q):
            return self._send(403, {"error": "bad token"})
        n = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            body = {}

        if u.path == "/api/roster":
            roster = body.get("roster")
            if not isinstance(roster, list):
                return self._send(400, {"error": "roster must be a list"})
            clean = []
            for it in roster:
                p = it.get("path", "")
                if not (isinstance(p, str) and p.endswith(".app") and os.path.isdir(p)):
                    continue
                clean.append({"path": p,
                              "name": os.path.basename(p)[:-4],
                              "enabled": bool(it.get("enabled", True))})
            save_roster(clean)
            return self._send(200, {"roster": clean})

        if u.path == "/api/start":
            if session_state():
                return self._send(409, {"error": "a tunnel session is already running"})
            apps = [a["path"] for a in load_roster() if a.get("enabled")]
            if not apps:
                return self._send(400, {"error": "no apps enabled in the roster"})
            try:
                open(EVENTS, "w").close()
            except Exception:
                pass
            argv = [LOCK]
            for a in apps:
                argv += ["--app", a]
            argv.append("--yes")
            rc, out, err = terminal(argv, "apptunnel - starting %d app(s)" % len(apps))
            if rc != 0:
                return self._send(500, {"error": err or out or "could not open Terminal"})
            return self._send(200, {"started": apps})

        if u.path == "/api/stop":
            sess = session_state()
            if not sess:
                return self._send(404, {"error": "no session running"})
            try:
                os.kill(int(sess["pid"]), signal.SIGTERM)
            except Exception as e:
                return self._send(500, {"error": str(e)})
            return self._send(200, {"stopping": sess["pid"]})

        if u.path == "/api/doctor":
            argv = [DOCTOR] + (["--fix"] if body.get("fix") else [])
            rc, out, err = terminal(argv, "tunnel-doctor")
            if rc != 0:
                return self._send(500, {"error": err or out})
            return self._send(200, {"ok": True})

        return self._send(404, {"error": "unknown endpoint"})


def main():
    os.makedirs(STATE_DIR, exist_ok=True)
    for p in (LOCK, DOCTOR):
        if os.path.isfile(p):
            os.chmod(p, 0o755)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = srv.server_address[1]
    url = "http://127.0.0.1:%d/?token=%s" % (port, TOKEN)
    print("apptunnel GUI: %s" % url, flush=True)
    if "--no-open" not in sys.argv:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nGUI stopped. Any running tunnel session is unaffected.")


if __name__ == "__main__":
    main()
