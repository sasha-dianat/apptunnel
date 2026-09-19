#!/bin/bash
# tunnel-python.sh — find a python3 that actually runs. Sourced, not executed.
#
#   . "$(cd "$(dirname "$0")" && pwd)/tunnel-python.sh"
#   "$PY" -c '...'
#
# WHY THIS EXISTS
#
# /usr/bin/python3 is not Python. It is a stub that forwards to whatever the
# Xcode Command Line Tools provide, and the Command Line Tools are NOT part of a
# stock macOS install - they can be absent from a fresh machine and an OS
# upgrade can leave the directory behind while removing its contents. When that
# happens every single call dies with
#
#     xcrun: error: invalid active developer path (/Library/Developer/CommandLineTools)
#
# and, because the file still exists and is executable, `command -v python3`
# and `[ -x /usr/bin/python3 ]` both say yes. Ten scripts in this toolkit drove
# their SOCKS probes, their JSON parsing, their bridge and their telemetry
# through that stub, so on such a machine the launcher stalled on phase 2, the
# telemetry sampler emitted nothing, and the whole app looked broken with no
# visible reason.
#
# The only reliable test is to run the interpreter, which is what this does.
# Preference order puts the system copy first when it works (no user site
# packages, no conda surprises), then the python.org and Homebrew installs, and
# only then whatever PATH happens to offer - PATH is last on purpose, because
# under sudo it may point at root's environment rather than the user's.
#
# Set TUNNEL_PYTHON to override.

tunnel_find_python() {
  local c
  for c in "${TUNNEL_PYTHON:-}" \
           /usr/bin/python3 \
           /usr/local/bin/python3 \
           /opt/homebrew/bin/python3 \
           "$(command -v python3 2>/dev/null || true)"; do
    [ -n "$c" ] || continue
    [ -x "$c" ] || continue
    # Import the modules the toolkit actually uses, so a broken or stripped
    # interpreter is rejected here rather than three phases later.
    if "$c" -c 'import sys, json, socket, subprocess' >/dev/null 2>&1; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

PY="$(tunnel_find_python || true)"
if [ -n "$PY" ]; then
  TUNNEL_PY_OK=1
else
  TUNNEL_PY_OK=0
  # Do not exit: the caller decides how to report this. Falling back to the
  # stub keeps the failure loud and in the usual place rather than producing an
  # empty command word.
  PY=/usr/bin/python3
  printf 'tunnel: no working python3 found.\n' >&2
  printf '        /usr/bin/python3 is a Command Line Tools stub and is not functioning.\n' >&2
  printf '        Install them with:  xcode-select --install\n' >&2
  printf '        (or set TUNNEL_PYTHON to a working interpreter)\n' >&2
fi
export PY TUNNEL_PY_OK
