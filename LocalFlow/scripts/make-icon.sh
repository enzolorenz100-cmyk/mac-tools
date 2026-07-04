#!/bin/bash
# Erzeugt Resources/AppIcon.icns (Dock-Icon) — gerendert per AppKit, ohne Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Resources
TMP=$(mktemp -d)

cat > "$TMP/render.swift" <<'SWIFT'
import AppKit
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// Dunkler abgerundeter Hintergrund (Squircle) mit tiefem Indigo→Schwarz-Verlauf
let inset = size * 0.07
let rect = NSRect(x: inset, y: inset, width: size - 2*inset, height: size - 2*inset)
let clip = NSBezierPath(roundedRect: rect, xRadius: size*0.225, yRadius: size*0.225)
clip.addClip()
NSGradient(colors: [
    NSColor(calibratedRed: 0.13, green: 0.11, blue: 0.22, alpha: 1),   // dunkles Indigo
    NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.09, alpha: 1),   // fast Schwarz
])!.draw(in: rect, angle: -90)

// dezenter Lichtschein oben
NSGradient(colors: [NSColor(white: 1, alpha: 0.10), NSColor(white: 1, alpha: 0)])!
    .draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height/2), angle: -90)

// Leuchtende Waveform-Balken (wie die Flow Bar), vibranter Verlauf pro Balken
let heights: [Double] = [0.30, 0.55, 0.82, 1.0, 0.68, 0.90, 0.48, 0.24]
let n = heights.count
let barW = size * 0.062
let gap = size * 0.038
let totalW = Double(n) * barW + Double(n - 1) * gap
var x = size/2 - totalW/2
let maxH = size * 0.46
let cy = size/2

let palette: [(NSColor, NSColor)] = [
    (NSColor(calibratedRed: 0.40, green: 0.45, blue: 1.00, alpha: 1), NSColor(calibratedRed: 0.30, green: 0.60, blue: 1.00, alpha: 1)),
    (NSColor(calibratedRed: 0.55, green: 0.35, blue: 1.00, alpha: 1), NSColor(calibratedRed: 0.40, green: 0.50, blue: 1.00, alpha: 1)),
    (NSColor(calibratedRed: 0.80, green: 0.30, blue: 0.95, alpha: 1), NSColor(calibratedRed: 0.55, green: 0.35, blue: 1.00, alpha: 1)),
    (NSColor(calibratedRed: 1.00, green: 0.35, blue: 0.70, alpha: 1), NSColor(calibratedRed: 0.80, green: 0.30, blue: 0.95, alpha: 1)),
]

// weicher Glow hinter den Balken
let glow = NSShadow()
glow.shadowColor = NSColor(calibratedRed: 0.5, green: 0.4, blue: 1.0, alpha: 0.7)
glow.shadowBlurRadius = size * 0.03
glow.shadowOffset = .zero

for (i, h) in heights.enumerated() {
    let barH = maxH * h
    let bar = NSRect(x: x, y: cy - barH/2, width: barW, height: barH)
    let p = NSBezierPath(roundedRect: bar, xRadius: barW/2, yRadius: barW/2)
    let colors = palette[i % palette.count]
    // 1) Glow: gefüllte Form mit Leucht-Schatten (ohne Clip, damit der Schein sichtbar bleibt)
    NSGraphicsContext.saveGraphicsState()
    glow.set()
    colors.0.setFill()
    p.fill()
    NSGraphicsContext.restoreGraphicsState()
    // 2) Körper: Farbverlauf auf den Balken geclippt
    NSGraphicsContext.saveGraphicsState()
    p.addClip()
    NSGradient(colors: [colors.0, colors.1])!.draw(in: bar, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    x += barW + gap
}

img.unlockFocus()
let tiff = img.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT

swift "$TMP/render.swift" "$TMP/icon_1024.png"

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 64 128 256 512 1024; do
    sips -z $s $s "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
done
# @2x-Varianten (Retina)
cp "$ICONSET/icon_32x32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$TMP"
echo "▸ Resources/AppIcon.icns erstellt"
