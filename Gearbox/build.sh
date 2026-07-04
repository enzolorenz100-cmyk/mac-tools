#!/bin/bash
# Baut Gearbox und installiert es nach ~/Applications/Gearbox.app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="$HOME/Applications/Gearbox.app"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Gearbox "$APP/Contents/MacOS/Gearbox"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force -s - "$APP"

echo "✓ Installiert: $APP"
