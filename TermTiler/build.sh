#!/bin/bash
# Baut TermTiler und installiert es nach ~/Applications/TermTiler.app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="$HOME/Applications/TermTiler.app"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/TermTiler "$APP/Contents/MacOS/TermTiler"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force -s - "$APP"

echo "✓ Installiert: $APP"
