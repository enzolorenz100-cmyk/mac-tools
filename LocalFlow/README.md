# LocalFlow

**Wispr Flow, aber lokal, offline und kostenlos.** Hotkey halten → sprechen → loslassen → der Text steht formatiert an der Cursor-Position der aktiven App. Die Spracherkennung läuft zu 100 % offline über whisper.cpp; keine Cloud, kein Abo, kein Wortlimit — Audio und Transkripte verlassen nie den Mac.

## Bedienung

| Aktion | Taste |
|---|---|
| Diktieren (Push-to-Talk) | **Hotkey gedrückt halten** (Fn; konfigurierbar), loslassen = fertig |
| Freihand-Modus | Hotkey **kurz antippen** oder Hotkey+Space; zusätzlich **Ctrl+Space** (für Tastaturen ohne Fn) |
| Abbrechen | **Esc** während der Aufnahme |
| Letztes Transkript erneut einfügen | **Cmd+Ctrl+V** |

Status-Pill unten am Bildschirm („Flow Bar", Live-Pegel): rot = Aufnahme, orange = Freihand, blau = Transkription. Menüleisten-Mikrofon zeigt Status, Verlauf (Klick = kopieren) und öffnet das Dashboard (Cmd-D) mit Statistiken.

**Deutsch + Englisch mit Auto-Erkennung** — auch gemischt im selben Satz (Modell `large-v3-turbo`). Formatierung regelbasiert: Füllwort-Entfernung, Diktat-Kommandos („neue Zeile", „neuer Absatz"), eigenes Wörterbuch und Snippets, Messaging-Stil pro App.

## Voraussetzungen

- Apple-Silicon-Mac, macOS 13+
- Xcode Command Line Tools (kein volles Xcode): `xcode-select --install`
- Homebrew und `brew install whisper-cpp`
- Whisper-Modell `ggml-large-v3-turbo.bin` (~1,6 GB — liegt **nicht** im Repo, Download unten; im Betrieb ~1,5 GB RAM)

## Installation

```bash
xcode-select --install        # falls noch nicht vorhanden
brew install whisper-cpp
cd LocalFlow
mkdir -p models
curl -L -o models/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
scripts/build.sh --install    # baut LocalFlow.app und kopiert es nach /Applications
open /Applications/LocalFlow.app
```

**Modellpfad anpassen:** Der Default zeigt auf `~/Desktop/LocalFlow/models/ggml-large-v3-turbo.bin`. Liegt euer Checkout woanders, nach dem ersten Start `~/Library/Application Support/LocalFlow/settings.json` öffnen, `"modelPath"` auf den absoluten Pfad des heruntergeladenen Modells setzen und die App neu starten. Prüfen mit: `/Applications/LocalFlow.app/Contents/MacOS/LocalFlow --check`

## Berechtigungen beim ersten Start

1. **Mikrofon** — Dialog erscheint automatisch, einfach erlauben.
2. **Bedienungshilfen** (für den Hotkey und das Text-Einfügen): Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen → LocalFlow aktivieren. Die App erkennt die Freigabe von selbst, kein Neustart nötig.
3. Empfohlen: Systemeinstellungen → Tastatur → „Fn-Taste drücken für" auf **„Nichts tun"** stellen.

Mehr braucht LocalFlow nicht — keine Bildschirmaufnahme, keine Automation.

## Eigene Wörter & Snippets

`~/Library/Application Support/LocalFlow/settings.json`:

- **dictionary**: `phrase` = korrekte Schreibweise, `misspellings` = was Whisper fälschlich daraus macht. Wirkt doppelt: als Kontext-Hinweis an Whisper und als Ersetzung danach.
- **snippets**: `trigger` (gesprochene Phrase) → `expansion` (eingefügter Text).
- **language**: `"auto"` (Standard), `"de"` oder `"en"`; **hotkey**: `"fn"`, `"rightOption"`, `"rightCommand"`.

## Bekannte Stolperfallen

- **Nach jedem Rebuild Accessibility neu erteilen:** Die App ist standardmäßig ad-hoc-signiert; jede neue Kompilierung hat eine neue Identität und macOS invalidiert den Bedienungshilfen-Grant *still* (Schalter sieht aktiv aus, wirkt aber nicht). Fix: Schalter einmal aus/an. Dauerhafte Lösung für alle, die selbst bauen: eigenes selbstsigniertes Codesigning-Zertifikat erzeugen (die `openssl`-Befehle stehen in `scripts/setup-signing-cert.sh`; die entstehende `localflow-signing.p12` bleibt lokal und gehört **nicht** ins Repo), dann einmalig `scripts/setup-signing-cert.sh` ausführen — `build.sh` findet und nutzt das Zertifikat automatisch.
- **Parallelbetrieb mit Wispr Flow:** Beide Apps auf Fn kollidieren. In `settings.json` `"hotkey": "rightOption"` setzen, solange Wispr läuft.
- **Erster Start dauert:** Die App startet `whisper-server` (nur 127.0.0.1) als Kindprozess; das Modell-Laden braucht einige Sekunden.
- **whisper-server nicht gefunden:** Default-Pfad ist `/opt/homebrew/bin/whisper-server` (Apple-Silicon-Homebrew); bei abweichender Installation `"whisperServerPath"` in `settings.json` anpassen.
- **Diagnose:** `--check` (Berechtigungen/Server/Modell), Logs unter `~/Library/Application Support/LocalFlow/` (`localflow.log`, `whisper-server.log`); Pipeline-Test ohne Mikro: `.build/debug/LocalFlow --test-file audio.wav`, Formatter-Test: `--format-test`.
