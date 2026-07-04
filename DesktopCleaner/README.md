# DesktopCleaner

Ein Tastendruck räumt den macOS-Desktop auf: Ein Shell-Skript sortiert lose Dateien deterministisch in eine feste Ordnerstruktur, anschließend klassifiziert Claude (nur mit Leserechten!) Dokumente und Screenshots und liefert einen JSON-Plan, den ein Python-Skript kontrolliert ausführt. Es wird **nie automatisch gelöscht** — jeder Move steht in einem Manifest und ist per `undo.sh` vollständig rückgängig zu machen.

## Was passiert bei einem Lauf

1. **Phase 1 (sofort, ohne KI):** lose Desktop-Dateien nach Typ einsortieren — Screenshots → `SCREENSHOTS/<Jahr>/`, Bilder/Videos/Audio → `MEDIEN/…`, Archive/Installer → `ARCHIV/…`, Dokumente → `DOKUMENTE/_Eingang/`. **Ordner werden nie angefasst**, unbekannte Typen bleiben liegen.
2. **Phase 2 (KI-Ablage):** `claude -p` (Modell `sonnet`, nur Read/Glob) liest die Dokumente im Eingang an und schlägt Zielordner vor; `apply-plan.py` führt die Moves aus — mit Allowlist, Ziel-Beschränkung und Review-Deckel gegen Prompt-Injection.
3. **Phase 3 (Vision):** `claude -p` (Modell `haiku`) schaut Screenshots an, benennt sie sprechend um (`YYYY-MM-DD Kurzbeschreibung.png` — Spotlight findet sie danach nach Inhalt) und routet abfotografierte Dokumente (Rechnung, Etikett, …) in Fachordner.
4. Duplikat-/Müll-Kandidaten landen in `_Prüfen-Löschkandidaten/` auf dem Desktop — löschen entscheidest du selbst. Jeder Move steht im Write-Ahead-Manifest (`logs/manifest-*.tsv`).

## Voraussetzungen

- macOS auf Apple Silicon; Xcode Command Line Tools (`xcode-select --install`) für `git`/`python3`
- Claude Code CLI (`claude`) mit aktivem Claude-Abo (Modelle `sonnet` und `haiku`), z. B. `brew install node && npm install -g @anthropic-ai/claude-code`
- Python 3 — nur Standardbibliothek, keine Pakete nötig
- Optional: Anthropic-API-Key von console.anthropic.com als Fallback (siehe unten)

## Installation

```bash
cd DesktopCleaner
chmod +x cleanup.sh undo.sh apply-plan.py   # falls Exec-Bits beim Klonen verloren gingen
claude                      # einmalig mit Claude-Abo einloggen, dann beenden
./cleanup.sh --dry-run      # Testlauf: zeigt nur, verschiebt nichts
./cleanup.sh                # erster echter Lauf
```

Danach unbedingt:

1. **Prompts personalisieren:** In `ai-prompt.md` (Regel 6 „Kontext zum Nutzer") und `ai-screenshot-prompt.md` den Platzhalter `<<HIER EIGENEN KONTEXT EINTRAGEN>>` durch die eigene Ordnerstruktur und Projekte ersetzen — sonst kann die KI Dokumente nicht sinnvoll zuordnen.
2. Optional API-Fallback hinterlegen: `echo "sk-ant-…" > .anthropic-api-key && chmod 600 .anthropic-api-key` — die Datei steht in der `.gitignore` und darf **niemals** committet werden. Solange das Abo funktioniert, wird der Key nie benutzt; schlägt ein Abo-Aufruf fehl, wiederholt der Cleaner ihn automatisch pay-per-use.
3. Optional Hotkey (⌃⌥L): Kurzbefehle-App → „+" → Aktion **„Shell-Skript ausführen"** mit dem absoluten Pfad zu **deinem** geklonten `cleanup.sh` → ⓘ → „Mit Tastenkurzbefehl ausführen" → **Ctrl+Option+L**. (Achtung: Option+L allein tippt auf deutschem Layout „@".)

## Benutzung

```bash
./cleanup.sh                   # normaler Lauf
./cleanup.sh --dry-run         # nur zeigen, nichts verschieben
./cleanup.sh --no-ai           # ohne Dokumenten-KI
./cleanup.sh --no-vision       # ohne Screenshot-Analyse
./cleanup.sh --vision-backlog  # alte Screenshots batchweise nachholen
./undo.sh                      # letzten Lauf komplett rückgängig machen
```

Konfiguration per Umgebungsvariable: `CLEANER_MODEL` (Standard `sonnet`), `CLEANER_AI_LIMIT` (max. Dokumente pro Lauf, 40), `CLEANER_VISION_MODEL` (`haiku`), `CLEANER_VISION_LIMIT` (Screenshots pro Batch, 15), `DESKTOP_DIR` (Test-Override).

Tipp: In der **Gearbox** (gleiches Repo) hängt ein Desktop-Cleaner-Panel mit Start- und Undo-Button — dafür muss dieses Projekt unter `~/DesktopCleaner` liegen (Symlink reicht: `ln -s "$(pwd)" ~/DesktopCleaner`).

## Berechtigungs-Dialoge beim ersten Start

- macOS fragt beim ersten Lauf nach Zugriff auf den **Schreibtisch-Ordner** → erlauben (einmal pro startender App, also je einmal für Terminal bzw. Kurzbefehle).
- Bei Ausführung über Kurzbefehle ggf. in Kurzbefehle → Einstellungen → Erweitert **„Ausführen von Skripts erlauben"** aktivieren.
- Die Abschluss-Benachrichtigung kommt per `osascript` — Mitteilungen erlauben, falls macOS fragt.
- **Nicht** benötigt: Mikrofon, Bedienungshilfen, Bildschirmaufnahme, Automation.

## Bekannte Stolperfallen

- `claude` muss im PATH liegen; das Skript ergänzt `~/.local/bin`, `/opt/homebrew/bin` und `/usr/local/bin`. Bei anderem Installationsort den PATH-Export am Anfang von `cleanup.sh` erweitern.
- `logs/` enthält nach jedem Lauf **komplette Dateilisten deines Desktops** (privat!) — der Ordner bleibt lokal und ist per `.gitignore` vom Repo ausgeschlossen.
- KI-Limits pro Lauf: max. 40 Dokumente (Phase 2) und 15 Screenshots (Phase 3); der Rest kommt beim nächsten Lauf dran.
- Umlaute in Dateinamen sind ok — die NFD/NFC-Normalisierung übernimmt `apply-plan.py` intern.
- Dateinamen mit Tab oder Zeilenumbruch werden bewusst übersprungen (würden das Undo-Manifest korrumpieren).
- Es wird nie gelöscht: Kandidaten landen in `_Prüfen-Löschkandidaten/` — vor dem Leeren selbst durchsehen.
