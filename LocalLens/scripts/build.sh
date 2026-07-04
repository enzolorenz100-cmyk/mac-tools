#!/bin/bash
# Baut LocalLens.app (ohne Xcode). Nutzt dasselbe stabile Signier-Zertifikat wie LocalFlow,
# damit die Bildschirm-/Berechtigungen Rebuilds überleben.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$(pwd)/LocalLens.app"
ID="de.enzolorenz.locallens"
VER="1.0.0"

echo "▸ swift build -c release"; swift build -c release
echo "▸ Bundle"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -X .build/release/LocalLens "$APP/Contents/MacOS/LocalLens"
[ -f Resources/AppIcon.icns ] || ./scripts/make-icon.sh
cp -X Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>LocalLens</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>LocalLens</string>
  <key>CFBundleDisplayName</key><string>LocalLens</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundleVersion</key><string>$VER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Lokal &amp; gratis — kein Cloud-Upload.</string>
</dict></plist>
PLIST

# Begleit-Detritus entfernen, sonst verweigert codesign ("resource fork … not allowed").
# KEIN dot_clean — das verschmilzt ._-Dateien in Ressourcen-Forks und verschlimmert es.
# Rekursiv + per-Datei (manche xattrs überlebt -cr sonst) + ._-Dateien löschen.
xattr -cr "$APP" 2>/dev/null || true
find "$APP" -name '._*' -delete 2>/dev/null || true
find "$APP" -exec xattr -c {} \; 2>/dev/null || true
IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk '/"LocalFlow"/{print $2; exit}')"
if [ -n "$IDENTITY" ]; then
  echo "▸ Signiere mit stabilem Zertifikat ($IDENTITY)"
  codesign --force --sign "$IDENTITY" --identifier "$ID" "$APP"
else
  echo "▸ Signiere ad-hoc"; codesign --force --sign - --identifier "$ID" "$APP"
fi
codesign --verify "$APP" && echo "▸ Signatur OK"

if [ "${1:-}" = "--install" ]; then
  pkill -x LocalLens 2>/dev/null || true; sleep 0.5
  rm -rf /Applications/LocalLens.app; cp -R "$APP" /Applications/LocalLens.app
  echo "▸ Installiert: /Applications/LocalLens.app"
else
  echo "▸ Fertig: $APP"
fi
