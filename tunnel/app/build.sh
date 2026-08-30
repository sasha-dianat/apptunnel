#!/bin/bash
# Builds AppTunnel.app from Sources/main.swift using the Command Line Tools.
# No Xcode project required.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$HERE/AppTunnel/Sources"
APP="$HERE/AppTunnel.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

command -v swiftc >/dev/null || { echo "swiftc not found. Install the Xcode Command Line Tools."; exit 1; }

echo "==> cleaning"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

echo "==> compiling"
# Compile every file in Sources/ so the app can be split into focused units.
# An array, not $(ls ...): this project lives under a path containing a space
# ("Claude-Chatgpt Tunnel"), and unquoted command substitution word-splits it.
SRCS=("$SRC_DIR"/*.swift)
[ -e "${SRCS[0]}" ] || { echo "no Swift sources in $SRC_DIR"; exit 1; }
swiftc -O \
  -target x86_64-apple-macosx11.0 \
  -framework AppKit \
  -o "$MACOS/AppTunnel" \
  "${SRCS[@]}"

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
/usr/bin/python3 - "$ICONSET" <<'PY'
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
codesign --force --deep --sign - "$APP" 2>/dev/null && echo "    signed" || echo "    unsigned (non-fatal)"

touch "$APP"
echo
echo "Built: $APP"
echo "Open with:  open \"$APP\""
