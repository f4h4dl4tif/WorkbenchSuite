#!/bin/bash
# Builds Workbench.app into ./build. Set UNIVERSAL=1 for an Apple silicon + Intel binary.
set -euo pipefail
cd "$(dirname "$0")"

# SwiftUI's macro plugin ships only with Xcode, so prefer Xcode's toolchain when it is installed.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [ "${UNIVERSAL:-0}" = "1" ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Workbench"
else
  swift build -c release
  BIN=.build/release/Workbench
fi

ICON=Resources/AppIcon.icns
if [ ! -f "$ICON" ]; then
  TMP=$(mktemp -d)
  swift Scripts/make-icon.swift "$TMP/icon.png"
  SET="$TMP/AppIcon.iconset"; mkdir "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$ICON"
  rm -rf "$TMP"
fi

APP=build/Workbench.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Icons"
cp "$BIN" "$APP/Contents/MacOS/Workbench"
strip -x "$APP/Contents/MacOS/Workbench"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
# The catalog and tool icons are shared with the website and live at the repo root.
cp ../catalog.json "$APP/Contents/Resources/catalog.json"
cp ../icons/*.png "$APP/Contents/Resources/Icons/"

codesign --force --deep --sign - "$APP"
echo "Built $(pwd)/$APP"
