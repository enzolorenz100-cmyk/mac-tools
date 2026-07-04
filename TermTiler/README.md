# TermTiler 🧩

Menüleisten-Tool für macOS: ordnet per Klick oder Hotkey **alle offenen Fenster von Apple Terminal.app** automatisch in einem sauberen Raster an — alle sichtbar, in allen arbeitbar. Praktisch, wenn man viele Terminal-Sessions parallel beobachtet (z. B. mehrere Claude-Agenten/Builds).

## Bedienung

- **Klick aufs Puzzleteil** (graues Symbol, Menüleiste): Terminals sofort anordnen. Kurzes Feedback neben dem Icon: `4` = 4 Fenster angeordnet, `0` = nichts zu tun, `!` = Fehler (meist fehlende Berechtigung).
- **Automatische Display-Verteilung**: Alles kommt aufs Display mit der Maus, solange die Fenster über der Komfortgröße bleiben (Default 560×340 pt); der Rest läuft aufs nächste Display über. Komfortgröße ändern: `defaults write com.enzolorenz.termtiler comfortWidth/comfortHeight -float <pt>`.
- **Klick-Zyklus**: Nochmal klicken (innerhalb von 8 s) schaltet weiter —
  - *mehrere Displays*: pro Klick wandert ein Fenster mehr aufs nächste Display (5 → 4+1 → 3+2 → …); das Icon zeigt kurz die Verteilung.
  - *ein Display*: pro Klick das nächste Layout (Raster → Spalten → Reihen → Hauptfenster + Stapel).
- **Rechtsklick**: Menü mit Layout-Wahl (**Raster** · **Spalten** · **Reihen** · **Hauptfenster + Stapel** — vorderstes Fenster groß links, Rest rechts gestapelt) und Toggles („Minimierte einbeziehen", „Bei Login starten").
- **Hotkey ⌃⌥T** (global, ohne Berechtigungen). Ändern: `defaults write com.enzolorenz.termtiler tileKeyCode/tileModifiers -int <n>`.

## Voraussetzungen

- Apple-Silicon-Mac, macOS 14 (Sonoma) oder neuer
- Xcode Command Line Tools: `xcode-select --install` — kein volles Xcode, keine Homebrew-Pakete, keine Dependencies
- **Apple Terminal.app** als Ziel-Terminal (iTerm2 & Co. werden nicht unterstützt)

## Build & Installation

```bash
cd TermTiler
./build.sh                          # baut und installiert nach ~/Applications/TermTiler.app
open ~/Applications/TermTiler.app   # nur Menüleisten-Icon, kein Dock-Icon
```

## Berechtigungen

Nur **Automation**: Beim ersten Anordnen fragt macOS einmalig „TermTiler möchte Terminal steuern" → **Erlauben**. Keine Bedienungshilfen (Accessibility) nötig, weil Terminal.app direkt per AppleScript gesteuert wird.

Falls versehentlich abgelehnt: Systemeinstellungen → Datenschutz & Sicherheit → Automation → TermTiler → Terminal aktivieren (die App zeigt dafür auch selbst einen Hinweis-Dialog mit Direktlink).

## Bekannte Grenzen / Fallen

- **Ad-hoc-Signatur**: Nach einem Rebuild kann macOS die Automation-Erlaubnis erneut abfragen — einfach wieder „Erlauben".
- **Vollbild-Terminals** (eigener Space) lassen sich per AppleScript nicht verschieben — sie bleiben unangetastet.
- **Andere Spaces**: Fenster auf nicht sichtbaren Spaces werden bewusst in Ruhe gelassen (kein Loch im Raster); macOS erlaubt keinen Space-Wechsel per Skript.
- **Sehr viele Fenster**: Terminal.app erzwingt eine Mindestgröße (~177×124 pt); darunter staffelt TermTiler kontrolliert überlappend.
- Zeigt das Icon dauerhaft `!`, fehlt fast immer die Automation-Berechtigung (siehe oben).
