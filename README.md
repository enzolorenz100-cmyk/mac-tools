# mac-tools

Fünf kleine macOS-Tools (Apple Silicon), die zusammen eine lokale „Kommandozentrale" für die Arbeit mit Claude Code und den Mac-Alltag bilden. Alles wird lokal aus dem Quellcode gebaut — kein App Store, keine Cloud-Abhängigkeiten außer dem eigenen Claude-Abo (wo angegeben).

| Tool | Was es macht | Braucht |
|---|---|---|
| [**Gearbox**](Gearbox/) | Desktop-Widget „Schaltzentrale": startet Claude-Code-Terminals mit Modellwahl per H-Schaltkulisse (wie im Auto), Modi-Chips (YOLO/Nacht/Plan/Sandbox), KI-Dateisuche, Desktop-Cleaner-Knopf und Live-Cockpit aller laufenden Sessions | Claude Code CLI + Abo |
| [**LocalFlow**](LocalFlow/) | Diktier-App wie Wispr Flow, aber 100 % offline: Hotkey halten, sprechen, Text landet an der Cursor-Position (Deutsch + Englisch gemischt) | whisper.cpp + Modell (~1,6 GB) |
| [**LocalLens**](LocalLens/) | Screenshots/Bilder/Videos → AI-fertiger Text, komplett lokal (Apple-Vision-OCR + Ollama-Vision-Modell). Spart Bild-Tokens bei Cloud-AIs | Ollama (optional), ffmpeg/whisper für Video |
| [**TermTiler**](TermTiler/) | Menüleisten-Icon 🧩: ordnet alle Terminal.app-Fenster per Klick oder ⌃⌥T in einem sauberen Raster an (Multi-Display) | nichts |
| [**DesktopCleaner**](DesktopCleaner/) | Ein Befehl räumt den Desktop auf: deterministische Sortierung + KI-Ablage (Claude klassifiziert Dokumente & Screenshots, nur lesend). Nie löschend, komplett per `undo.sh` rückgängig | Claude Code CLI + Abo |

## Gemeinsame Voraussetzungen

- Apple-Silicon-Mac, macOS 14 (Sonoma) oder neuer (LocalFlow/LocalLens: ab macOS 13)
- **Xcode Command Line Tools** (Swift-Compiler, git, python3): `xcode-select --install` — kein volles Xcode nötig
- Für Gearbox & DesktopCleaner: **Claude Code CLI** mit aktivem Abo (`npm install -g @anthropic-ai/claude-code`, dann einmal `claude` starten und einloggen)
- [Homebrew](https://brew.sh) für die LocalFlow/LocalLens-Abhängigkeiten

## Schnellstart

```bash
git clone <REPO-URL>
cd mac-tools

# Jedes Tool einzeln bauen — Details & Berechtigungen im jeweiligen README:
(cd TermTiler && ./build.sh)        # sofort nutzbar, keine Abhängigkeiten
(cd Gearbox && ./build.sh)          # braucht claude-CLI
(cd LocalFlow && scripts/build.sh --install)   # vorher: brew install whisper-cpp + Modell-Download
(cd LocalLens && scripts/build.sh --install)   # vorher: brew install ollama (optional ffmpeg whisper-cpp)
```

**DesktopCleaner** wird nicht gebaut, sondern nur verlinkt — der Cleaner-Knopf in Gearbox erwartet ihn unter `~/DesktopCleaner`:

```bash
ln -s "$(pwd)/DesktopCleaner" ~/DesktopCleaner
cd DesktopCleaner && ./cleanup.sh --dry-run   # Testlauf, verschiebt nichts
```

## Wichtig zu wissen

- Jedes Tool-README beschreibt genau, **welche macOS-Berechtigungs-Dialoge** beim ersten Start kommen (Automation, Bedienungshilfen, Mikrofon, Bildschirmaufnahme) und welche Stolperfallen es gibt — vor der Installation kurz lesen.
- Die Apps sind **ad-hoc-signiert** (lokaler Build). Nach einem Rebuild kann macOS einzelne Berechtigungen erneut abfragen; LocalFlow bringt dafür eine dauerhafte Lösung mit (eigenes Signier-Zertifikat, siehe dessen README).
- **DesktopCleaner personalisieren:** In `DesktopCleaner/ai-prompt.md` und `ai-screenshot-prompt.md` den Platzhalter `<<HIER EIGENEN KONTEXT EINTRAGEN>>` mit den eigenen Projekten/Ordnernamen füllen — sonst kann die KI nicht sinnvoll zuordnen.
- Große Downloads liegen **nicht** im Repo: das Whisper-Modell (~1,6 GB) und das Ollama-Vision-Modell (~3,2 GB) lädt man gemäß den Tool-READMEs nach.
