# Gearbox 🏎️

Desktop-Widget für macOS („Schaltzentrale"): öffnet per Klick oder ⌘⏎ ein neues Terminal-Fenster mit laufender `claude`-Session — Modell über eine H-Schaltkulisse wie im Auto vorgewählt, Effort `xhigh` plus `ultracode`-Keyword aktiv, Aufgabentext direkt als erster Prompt übergeben. Läuft komplett über das Claude-Abo, kein API-Key nötig.

## Features

- **H-Schaltkulisse** (Knauf ziehen oder Gang-Label antippen): `1` Haiku · `2` Sonnet · `3` Opus · `4` Fable (1M Kontext) · `A` **Automatik** (ein Haiku-Router liest die Aufgabe und wählt das kleinste passende Modell, ggf. auch den Projektordner) · `R` **Resume** (`claude --continue` im gewählten Ordner). Rechtsklick auf die Gang-Karte: ältere Modell-Versionen wählen.
- **Modus-Chips**: YOLO (`--dangerously-skip-permissions`), Nacht (caffeinate hält den Mac wach + autonomer Nachtschicht-System-Prompt), Plan (`--permission-mode plan`), Sandbox (Git-Worktree).
- **Summon-Hotkey ⌥Space** (global, ohne Berechtigungen): holt das Widget aufs Display mit der Maus, Cursor steht im Aufgabenfeld. Ändern: `defaults write com.enzolorenz.gearbox summonKeyCode/summonModifiers -int <n>`.
- **Tastatur komplett**: ⌘1–⌘4 Gang, ⌘0 Automatik, ⌘R Resume, ⌘⏎ Start, ⌘⇧⏎ Batch-Fire (Terminal öffnet im Hintergrund), ⌘↑/⌘↓ Prompt-History (letzte 20).
- **Per-Projekt-Gedächtnis** (Gang + YOLO pro Ordner), Projekt-Picker (zuletzt genutzt + alle Desktop-Ordner + Home), Terminal-Titel `Projekt · GANG`.
- **Satelliten-Panels** unter dem Hauptwidget:
  - **Desktop Cleaner** — startet `~/DesktopCleaner/cleanup.sh` / `undo.sh` (das DesktopCleaner-Tool aus diesem Repo; per Symlink verfügbar machen, siehe unten)
  - **Desktop Finder** — Datei per Beschreibung finden & öffnen (KI-Suche via `claude -p` mit Haiku, nur Lese-Tools)
  - **Session-Cockpit** — Live-Liste aller laufenden Claude-Sessions (`claude agents --json`), Klick holt das Terminal-Fenster nach vorn
- Pin-Toggle (über allen Fenstern / Desktop-Widget-Ebene), „Bei Login starten" im ⋯-Menü.

## Was beim Start passiert

Gearbox schreibt ein Startskript nach `~/Library/Application Support/Gearbox/` und öffnet es als `.command`-Datei in Terminal.app (keine Automation-Berechtigung nötig):

```bash
cd '<Projektordner>'
exec claude --model '<modell>' --effort xhigh [--dangerously-skip-permissions] "ultracode

<deine Aufgabe>"
```

`--effort ultracode` existiert nicht als CLI-Flag; `xhigh` + das Keyword `ultracode` im Prompt ergibt dasselbe Verhalten. Skripte >24 h alt werden automatisch aufgeräumt.

## Voraussetzungen

- Apple-Silicon-Mac, macOS 14 (Sonoma) oder neuer
- Xcode Command Line Tools mit Swift 6: `xcode-select --install` — kein volles Xcode nötig
- Claude Code CLI, eingeloggt mit Claude-Abo; das Binary muss in `~/.local/bin`, `/opt/homebrew/bin` oder `/usr/local/bin` liegen
- Optional: DesktopCleaner unter `~/DesktopCleaner` (für den Cleaner-Satelliten)

## Installation

```bash
xcode-select --install                    # falls noch nicht vorhanden
npm install -g @anthropic-ai/claude-code  # falls claude noch fehlt
claude                                    # einmal starten & einloggen, dann beenden

cd Gearbox
./build.sh                                # baut & installiert nach ~/Applications/Gearbox.app
open ~/Applications/Gearbox.app           # Widget erscheint oben links auf dem Hauptbildschirm

# Optional, für den Desktop-Cleaner-Knopf (vom Repo-Root aus):
ln -s "$(pwd)/../DesktopCleaner" ~/DesktopCleaner
```

## Berechtigungs-Dialoge beim ersten Start

- Der Terminal-Start braucht **keine** Automation-Berechtigung (siehe oben).
- Beim ersten Klick auf eine Zeile im **Session-Cockpit** fragt macOS einmalig „Gearbox möchte Terminal steuern" (Automation) — erlauben, sonst kann das Fenster nicht fokussiert werden.
- Die Mikrofon-Buttons starten das **macOS-Systemdiktat** (in Systemeinstellungen ▸ Tastatur ▸ Diktat aktivieren; die App selbst nimmt nichts auf).
- „Bei Login starten" legt ein Login-Item an (Systemeinstellungen ▸ Allgemein ▸ Anmeldeobjekte).

## Bekannte Stolperfallen

- **`claude` nicht gefunden**: Binary muss in einem der drei o. g. Pfade liegen; notfalls Symlink: `mkdir -p ~/.local/bin && ln -s "$(which claude)" ~/.local/bin/claude`.
- **Desktop-Cleaner-Buttons zeigen Fehler**, wenn `~/DesktopCleaner/cleanup.sh` bzw. `undo.sh` fehlen (siehe Symlink oben). Der Rest des Widgets funktioniert trotzdem.
- **Auto-Trust**: Gearbox markiert gestartete Projektordner automatisch als „trusted" in `~/.claude.json`, damit kein Trust-Dialog kommt — bewusstes Verhalten, sollte man kennen.
- **YOLO/Nachtschicht** starten Claude mit `--dangerously-skip-permissions` — nur in vertrauenswürdigen Projekten verwenden.
- **Session-Cockpit bleibt leer**, wenn die installierte claude-Version `claude agents --json` nicht kennt — CLI aktualisieren.
- **Modellnamen sind fest verdrahtet** (Haiku 4.5, Sonnet 5, Opus 4.8, Fable 5 in `Gear.swift`, ältere Versions-IDs in `ContentView.swift`) — bei neuen Modell-Releases dort nachziehen.
- Die App ist **ad-hoc-signiert**; da lokal gebaut, gibt es keinen Gatekeeper-Dialog.
