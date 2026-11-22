#!/bin/bash
# Builds a universal Workbench.app and packages it: dist/Workbench-<version>.pkg, .dmg and .zip (+ How to Install.txt)
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=1 ./build.sh
ARCHS=$(lipo -archs build/Workbench.app/Contents/MacOS/Workbench)
case "$ARCHS" in *arm64*x86_64*|*x86_64*arm64*) ;; *) echo "Expected a universal binary, got: $ARCHS"; exit 1;; esac

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/root/Applications" dist
cp -R build/Workbench.app "$WORK/root/Applications/"

pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$WORK/components.plist"
pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" \
  --identifier app.workbenchsuite.launcher.pkg --version "$VERSION" --install-location / \
  "$WORK/Workbench-component.pkg" >/dev/null

cat > "$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Workbench</title>
    <welcome file="welcome.html" mime-type="text/html"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_localSystem="true"/>
    <volume-check><allowed-os-versions><os-version min="14.0"/></allowed-os-versions></volume-check>
    <choices-outline><line choice="default"><line choice="app"/></line></choices-outline>
    <choice id="default"/>
    <choice id="app" visible="false"><pkg-ref id="app.workbenchsuite.launcher.pkg"/></choice>
    <pkg-ref id="app.workbenchsuite.launcher.pkg" version="$VERSION" onConclusion="none">Workbench-component.pkg</pkg-ref>
</installer-gui-script>
XML

OUT="dist/Workbench-$VERSION.pkg"
productbuild --distribution "$WORK/distribution.xml" --resources Installer/resources --package-path "$WORK" "$OUT" >/dev/null
echo "Created $(pwd)/$OUT ($(du -h "$OUT" | cut -f1))"

GUIDE="Installer/How to Install.txt"
cp "$GUIDE" "dist/How to Install.txt"
ZIPDIR="$WORK/Workbench-$VERSION"; mkdir -p "$ZIPDIR"
cp "$OUT" "$GUIDE" "$ZIPDIR/"
ZIP="dist/Workbench-$VERSION.zip"; rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$ZIPDIR" "$ZIP"
echo "Created $(pwd)/$ZIP (installer + How to Install.txt)"

STAGE="$WORK/dmg"; mkdir -p "$STAGE"
cp -R build/Workbench.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$GUIDE" "$STAGE/"
DMG="dist/Workbench-$VERSION.dmg"; rm -f "$DMG"
hdiutil create -volname "Workbench" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
echo "Created $(pwd)/$DMG ($(du -h "$DMG" | cut -f1))"
