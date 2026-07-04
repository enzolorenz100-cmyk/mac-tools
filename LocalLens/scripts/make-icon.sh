#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Resources
TMP=$(mktemp -d)
cat > "$TMP/render.swift" <<'SWIFT'
import AppKit
let size=1024.0
let img=NSImage(size:NSSize(width:size,height:size)); img.lockFocus()
let inset=size*0.07
let rect=NSRect(x:inset,y:inset,width:size-2*inset,height:size-2*inset)
NSBezierPath(roundedRect:rect,xRadius:size*0.225,yRadius:size*0.225).addClip()
NSGradient(colors:[NSColor(calibratedRed:0.11,green:0.10,blue:0.20,alpha:1),NSColor(calibratedRed:0.05,green:0.05,blue:0.09,alpha:1)])!.draw(in:rect,angle:-90)
// Viewfinder-Ecken + Auge in Indigo/Violett
let g=NSGradient(colors:[NSColor(calibratedRed:0.42,green:0.38,blue:0.98,alpha:1),NSColor(calibratedRed:0.62,green:0.34,blue:0.94,alpha:1)])!
let cfg=NSImage.SymbolConfiguration(pointSize:size*0.52,weight:.medium)
if let sym=NSImage(systemSymbolName:"text.viewfinder",accessibilityDescription:nil)?.withSymbolConfiguration(cfg){
  let s=sym.size
  let mask=NSImage(size:s); mask.lockFocus(); NSColor.white.set(); NSRect(origin:.zero,size:s).fill(using:.sourceOver)
  sym.draw(in:NSRect(origin:.zero,size:s),from:.zero,operation:.destinationIn,fraction:1); mask.unlockFocus()
  let w=size*0.46, h=w*(s.height/s.width)
  let box=NSRect(x:(size-w)/2,y:(size-h)/2,width:w,height:h)
  box.clip()
  g.draw(in:box,angle:-90)
  // Verlauf nur wo das Symbol ist
  NSGraphicsContext.current?.saveGraphicsState()
  mask.draw(in:box,from:.zero,operation:.destinationIn,fraction:1)
  NSGraphicsContext.current?.restoreGraphicsState()
}
img.unlockFocus()
try! NSBitmapImageRep(data:img.tiffRepresentation!)!.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
SWIFT
swift "$TMP/render.swift" "$TMP/i.png"
ICON="$TMP/AppIcon.iconset"; mkdir -p "$ICON"
for s in 16 32 64 128 256 512 1024; do sips -z $s $s "$TMP/i.png" --out "$ICON/icon_${s}x${s}.png" >/dev/null; done
cp "$ICON/icon_32x32.png" "$ICON/icon_16x16@2x.png"; cp "$ICON/icon_64x64.png" "$ICON/icon_32x32@2x.png"
cp "$ICON/icon_256x256.png" "$ICON/icon_128x128@2x.png"; cp "$ICON/icon_512x512.png" "$ICON/icon_256x256@2x.png"
cp "$ICON/icon_1024x1024.png" "$ICON/icon_512x512@2x.png"
iconutil -c icns "$ICON" -o Resources/AppIcon.icns
rm -rf "$TMP"; echo "Icon erstellt"
