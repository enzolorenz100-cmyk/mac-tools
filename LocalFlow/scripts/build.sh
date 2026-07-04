#!/bin/bash
# Baut LocalFlow.app aus dem SPM-Executable (ohne Xcode, nur Command Line Tools).
# Nutzung: scripts/build.sh [--install]   (--install kopiert nach /Applications)
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd)"
APP="$PROJECT_DIR/LocalFlow.app"
IDENTIFIER="de.enzolorenz.localflow"
VERSION="1.0.0"

echo "▸ swift build -c release"
swift build -c release

echo "▸ Bundle zusammenbauen"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PROJECT_DIR/.build/release/LocalFlow" "$APP/Contents/MacOS/LocalFlow"

# App-Icon einbetten (Dock)
if [ ! -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    echo "▸ Icon fehlt — erzeuge es"
    "$PROJECT_DIR/scripts/make-icon.sh"
fi
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>LocalFlow</string>
    <key>CFBundleIdentifier</key><string>$IDENTIFIER</string>
    <key>CFBundleName</key><string>LocalFlow</string>
    <key>CFBundleDisplayName</key><string>LocalFlow</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>LocalFlow nimmt deine Stimme auf, um sie lokal (offline) zu transkribieren.</string>
    <key>NSHumanReadableCopyright</key><string>Lokal &amp; Open Source — keine Cloud.</string>
</dict>
</plist>
PLIST

# Signieren: stabile Identität bevorzugen (TCC-Grants überleben dann Rebuilds),
# sonst Ad-hoc (Accessibility muss nach jedem Rebuild neu erteilt werden).
# Stabiles LocalFlow-Zertifikat per SHA-1-Hash suchen. Das selbstsignierte Cert ist
# NICHT vertraut (CSSMERR_TP_NOT_TRUSTED) und erscheint daher nicht in `-v`, aber
# codesign kann trotzdem damit signieren — und genau das gibt die stabile Identität,
# an der die Accessibility-Freigabe über Rebuilds hinweg hängen bleibt.
IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk '/"LocalFlow"/{print $2; exit}')"
if [ -n "$IDENTITY" ]; then
    echo "▸ Signiere mit stabilem Zertifikat: LocalFlow ($IDENTITY)"
    codesign --force --sign "$IDENTITY" --identifier "$IDENTIFIER" "$APP"
else
    echo "▸ Signiere ad-hoc (Hinweis: Accessibility-Grant gilt nur bis zum nächsten Rebuild)"
    codesign --force --sign - --identifier "$IDENTIFIER" "$APP"
fi
codesign --verify --deep "$APP" && echo "▸ Signatur OK"

if [ "${1:-}" = "--install" ]; then
    echo "▸ Installiere nach /Applications"
    # Laufende Instanz beenden, sonst schlägt das Ersetzen fehl
    pkill -x LocalFlow 2>/dev/null || true
    sleep 0.5
    rm -rf "/Applications/LocalFlow.app"
    cp -R "$APP" "/Applications/LocalFlow.app"
    echo "▸ Fertig: /Applications/LocalFlow.app"
else
    echo "▸ Fertig: $APP   (mit --install nach /Applications kopieren)"
fi
