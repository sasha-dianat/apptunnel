#!/bin/bash
# Builds AppTunnel.app from Sources/main.swift using the Command Line Tools.
# No Xcode project required.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$(dirname "$HERE")")"        # the "Claude-Chatgpt Tunnel" folder
SRC_DIR="$HERE/AppTunnel/Sources"
APP="$HERE/AppTunnel.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
INSTALLED="$ROOT/AppTunnel.app"               # the one README tells you to double-click

# The icon generator needs a python3 that runs; /usr/bin/python3 is a stub that
# only works when a developer directory is active.
. "$(dirname "$HERE")/bin/tunnel-python.sh"

# ---- find a toolchain that actually works ----------------------------------
#
# /usr/bin/swiftc always exists on macOS - it is a stub that forwards to the
# active developer directory. When that directory is empty (the Command Line
# Tools are not part of a stock install, and an OS upgrade can gut them) the
# stub is still there and still executable, but every invocation dies with
# "invalid active developer path". Testing for the command is therefore
# useless; the only honest test is to run it.
#
# DEVELOPER_DIR overrides xcode-select for the current process only, so a copy
# of Xcode that was downloaded but never "installed" - sitting in ~/Downloads,
# say - can be used without sudo and without changing a single system setting.
# That matters here: this project exists because a previous tool rearranged the
# machine's configuration.
echo "==> toolchain"
find_developer_dir() {
  local c
  for c in "${DEVELOPER_DIR:-}" \
           "$(xcode-select -p 2>/dev/null || true)" \
           /Applications/Xcode.app/Contents/Developer \
           "$HOME/Downloads/Xcode.app/Contents/Developer" \
           "$HOME/Applications/Xcode.app/Contents/Developer" \
           /Library/Developer/CommandLineTools; do
    [ -n "$c" ] && [ -d "$c" ] || continue
    if DEVELOPER_DIR="$c" swiftc --version >/dev/null 2>&1; then
      printf '%s\n' "$c"; return 0
    fi
  done
  # Last resort: ask Spotlight where Xcode is.
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    c="$app/Contents/Developer"
    if [ -d "$c" ] && DEVELOPER_DIR="$c" swiftc --version >/dev/null 2>&1; then
      printf '%s\n' "$c"; return 0
    fi
  done <<EOF
$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null)
EOF
  return 1
}

if DEV="$(find_developer_dir)"; then
  export DEVELOPER_DIR="$DEV"
  echo "    $DEV"
  echo "    $(swiftc --version 2>/dev/null | head -1)"
else
  echo "No working Swift toolchain found."
  echo
  echo "/usr/bin/swiftc is a stub and the active developer directory is empty:"
  swiftc --version 2>&1 | sed 's/^/    /' || true
  echo
  echo "Install the Command Line Tools:"
  echo "    xcode-select --install"
  echo "or set DEVELOPER_DIR to an Xcode you already have, e.g."
  echo "    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer $0"
  exit 1
fi

echo "==> cleaning"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

echo "==> compiling"
# Compile every file in Sources/ so the app can be split into focused units.
# An array, not $(ls ...): this project lives under a path containing a space
# ("Claude-Chatgpt Tunnel"), and unquoted command substitution word-splits it.
SRCS=("$SRC_DIR"/*.swift)
[ -e "${SRCS[0]}" ] || { echo "no Swift sources in $SRC_DIR"; exit 1; }

# Build both architectures and lipo them together. The previous version pinned
# -target x86_64 only, which produced a binary that needs Rosetta on any Apple
# Silicon Mac - and Rosetta is not installed by default, so the app would refuse
# to open at all there. A slice that will not build (no SDK support for that
# arch on this host) is skipped rather than failing the build.
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
SLICES=()
for arch in arm64 x86_64; do
  if swiftc -O \
       -target "$arch-apple-macosx11.0" \
       -framework AppKit \
       -o "$TMPD/AppTunnel.$arch" \
       "${SRCS[@]}" 2>"$TMPD/err.$arch"; then
    SLICES+=("$TMPD/AppTunnel.$arch")
    echo "    $arch ok"
  else
    echo "    $arch skipped"
    sed 's/^/      /' "$TMPD/err.$arch" | head -4
  fi
done
[ "${#SLICES[@]}" -gt 0 ] || { echo "no architecture compiled - see the errors above"; exit 1; }
if [ "${#SLICES[@]}" -gt 1 ]; then
  lipo -create -output "$MACOS/AppTunnel" "${SLICES[@]}"
else
  cp "${SLICES[0]}" "$MACOS/AppTunnel"
fi
chmod +x "$MACOS/AppTunnel"
echo "    $(lipo -archs "$MACOS/AppTunnel" 2>/dev/null || echo unknown)"

echo "==> bundle metadata"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                  <string>AppTunnel</string>
  <key>CFBundleDisplayName</key>           <string>AppTunnel</string>
  <key>CFBundleExecutable</key>            <string>AppTunnel</string>
  <key>CFBundleIdentifier</key>            <string>local.apptunnel.gui</string>
  <key>CFBundlePackageType</key>           <string>APPL</string>
  <key>CFBundleShortVersionString</key>    <string>2.0</string>
  <key>CFBundleVersion</key>               <string>2.0</string>
  <key>LSMinimumSystemVersion</key>        <string>11.0</string>
  <key>NSHighResolutionCapable</key>       <true/>
  <key>NSPrincipalClass</key>              <string>NSApplication</string>
  <key>CFBundleIconFile</key>              <string>AppTunnel</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>AppTunnel opens Terminal so the tunnel scripts can ask for your administrator password there, rather than in this app.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> icon"
ICONSET="$(mktemp -d)/AppTunnel.iconset"
mkdir -p "$ICONSET"
"$PY" - "$ICONSET" <<'PY'
import os, struct, sys, zlib
out = sys.argv[1]

def png(path, n):
    px = bytearray()
    for y in range(n):
        px.append(0)
        for x in range(n):
            u, v = x / n, y / n
            edge = min(u, v, 1 - u, 1 - v)
            if edge < 0.06:                       # bezel
                r, g, b = 90, 90, 110
            elif 0.18 < v < 0.82 and 0.10 < u < 0.90:
                # LCD panel with green bars
                bar = int((u - 0.10) / 0.80 * 12)
                h = (0.30, 0.55, 0.42, 0.72, 0.50, 0.85, 0.60, 0.45, 0.78, 0.38, 0.66, 0.52)[bar % 12]
                lit = (0.82 - v) < h * 0.6
                r, g, b = (30, 232, 30) if lit else (6, 26, 6)
            else:
                r, g, b = 45, 45, 58
            px += bytes((r, g, b))
    raw = zlib.compress(bytes(px), 9)
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    hdr = struct.pack(">IIBBBBB", n, n, 8, 2, 0, 0, 0)
    blob = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", hdr) + chunk(b"IDAT", raw) + chunk(b"IEND", b"")
    open(path, "wb").write(blob)

for size in (16, 32, 64, 128, 256, 512):
    png(os.path.join(out, "icon_%dx%d.png" % (size, size)), size)
    png(os.path.join(out, "icon_%dx%d@2x.png" % (size, size)), size * 2)
PY
iconutil -c icns "$ICONSET" -o "$RES/AppTunnel.icns" 2>/dev/null \
  && echo "    icon built" || echo "    icon skipped (non-fatal)"

echo "==> signing (ad-hoc)"
# --deep is deprecated as of Sonoma and warns on every run. There is nothing
# nested to sign here - one executable, one icon - so signing the bundle is
# enough. Any stale quarantine flag is cleared too, or Gatekeeper shows the
# "damaged" dialog instead of opening the app.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign --force --sign - "$APP" 2>/dev/null && echo "    signed" || echo "    unsigned (non-fatal)"

touch "$APP"

echo "==> installing"
# The bundle the user actually opens lives at the project root - tunnel/README.md
# says "double-click AppTunnel.app" and tunnel-migrate.sh looks for it there -
# but the build only ever produced one inside tunnel/app/. Nothing copied it
# across, so the two drifted apart by weeks: every fix landed in a bundle nobody
# opened, while the root copy stayed frozen at whatever was built the day it was
# first created. That is why the app "did not function" after being fixed.
if [ "$INSTALLED" = "$APP" ]; then
  echo "    already at the project root"
else
  rm -rf "$INSTALLED"
  # ditto, not cp -R: it preserves the code signature and resource forks.
  ditto "$APP" "$INSTALLED"
  touch "$INSTALLED"
  echo "    $INSTALLED"
fi

echo
echo "Built:     $APP"
echo "Installed: $INSTALLED"
echo "Open with:  open \"$INSTALLED\""
