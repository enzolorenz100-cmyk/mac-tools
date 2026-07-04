# LocalLens

Menüleisten-App für Apple-Silicon-Macs, die Screenshots, Bilder und Videos **komplett lokal** in AI-fertigen Text umwandelt (Apple-Vision-OCR + optional lokales Vision-Modell via Ollama). Zweck: statt teurer Bild-Uploads an eine Cloud-AI nur noch kompakten Text einfügen — spart Tokens, und nichts verlässt den Mac.

## Features

- **Menüleisten-Icon**: Linksklick scannt das aktive Fenster vollautomatisch (kein Region-Ziehen); Rechtsklick öffnet das Menü (Region scannen, Fenster öffnen, Autostart, Beenden)
- **Globaler Hotkey ⌘⇧2** scannt das aktive Fenster
- **Drag & Drop** von Bildern (PNG, JPG, TIFF, HEIC) und Videos (MOV, MP4, M4V, AVI, MKV, WEBM) ins App-Fenster — funktioniert ganz ohne Berechtigungen
- **OCR** über Apple Vision (Deutsch + Englisch), plus optionale **Bild-Beschreibung** durch ein lokales Vision-Modell (Standard: `qwen2.5vl:3b` in Ollama)
- **Video**: Audio-Transkript via whisper.cpp + Keyframe-Analyse via ffmpeg-Szenenerkennung
- Ergebnis wird **automatisch in die Zwischenablage** kopiert; zusätzlich Markdown-Archiv („Vault") unter `~/Library/Application Support/LocalLens/vault/`
- **CLI-Modus**: `LocalLens --process <bild> [--no-describe]`, `LocalLens --video <datei>`

## Voraussetzungen

- Apple-Silicon-Mac, macOS 13+
- Xcode Command Line Tools (Swift-Compiler): `xcode-select --install`
- Homebrew-Pakete: `ffmpeg` und `whisper-cpp` (beide nur für Video), `ollama` (optional — ohne laufendes Ollama gibt es nur OCR, keine Beschreibungen)
- Ollama-Modell `qwen2.5vl:3b` (~3,2 GB)
- Whisper-Modell `ggml-large-v3-turbo.bin` (~1,6 GB, Hugging Face `ggerganov/whisper.cpp`) — nur für Video-Transkripte; dasselbe Modell wie bei LocalFlow, es kann geteilt werden

## Installation

```bash
xcode-select --install
brew install ffmpeg whisper-cpp ollama
brew services start ollama
ollama pull qwen2.5vl:3b

cd LocalLens
./scripts/build.sh --install
open /Applications/LocalLens.app
```

**Whisper-Modell für Video-Transkripte:** Der Default-Pfad zeigt auf `~/Desktop/LocalFlow/models/ggml-large-v3-turbo.bin` (das Schwester-Tool LocalFlow). Wer LocalFlow nicht nutzt oder das Modell woanders ablegt: nach dem ersten Start in `~/Library/Application Support/LocalLens/settings.json` den Schlüssel `whisperModel` auf den echten Pfad setzen (dort lassen sich auch `whisperCli`, `ffmpeg`, `visionModel`, `autoCopy`, `saveToVault` und `captureMode` ändern), danach die App neu starten.

## Berechtigungen beim ersten Start

- **Bildschirmaufnahme**: Beim ersten Klick auf „Screen scannen" (oder ⌘⇧2) öffnet LocalLens automatisch Systemeinstellungen → Datenschutz & Sicherheit → Bildschirmaufnahme. Dort LocalLens aktivieren und erneut scannen. Drag & Drop von Dateien funktioniert auch ohne diese Berechtigung sofort.
- **Nicht benötigt**: Mikrofon, Bedienungshilfen (Accessibility) und Automation — der globale Hotkey läuft über die Carbon-HotKey-API.

## Bekannte Stolperfallen

- **Ollama läuft nicht** → stiller Fallback: nur OCR, keine Beschreibung (kein Fehler, keine Meldung). Prüfen: `brew services start ollama`.
- **Whisper-Modell fehlt oder liegt am falschen Pfad** → das Video-Transkript bleibt still leer; die Keyframe-Analyse läuft trotzdem.
- **Signatur & Berechtigungs-Reset**: `build.sh` sucht im Schlüsselbund ein Codesigning-Zertifikat namens „LocalFlow"; fehlt es, wird ad-hoc signiert — macOS kann die Bildschirmaufnahme-Berechtigung dann nach jedem Rebuild erneut verlangen. Wer häufig neu baut, richtet das LocalFlow-Signier-Zertifikat ein (siehe LocalFlow-README).
- **Autostart** („Bei Anmeldung starten" im Menü) setzt voraus, dass die App unter `/Applications/LocalLens.app` liegt — also mit `./scripts/build.sh --install` installieren, nicht nur bauen.
- Die Oberfläche ist auf Deutsch.
