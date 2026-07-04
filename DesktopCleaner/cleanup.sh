#!/bin/bash
# Desktop-Cleaner — Hotkey → aufgeräumter Desktop
# Phase 1: deterministische Typ-Sortierung (sofort, ohne KI)
# Phase 2: KI-Ablage der Dokumente aus DOKUMENTE/_Eingang
#          (claude -p hat NUR Leserechte und liefert einen JSON-Plan;
#           alle Moves führt apply-plan.py aus — protokolliert, undo-fähig, löscht nie)
#
# Phase 3: Vision-Pass — KI schaut neue Screenshots AN, benennt sie sprechend um
#          und routet Dokument-Screenshots (Rechnungen etc.) in die Fachordner
#
# Aufruf:  cleanup.sh [--dry-run] [--no-ai] [--no-vision] [--vision-backlog]
# Umgebung: DESKTOP_DIR (Test-Override), CLEANER_MODEL (default: sonnet),
#           CLEANER_AI_LIMIT (max. Dokumente pro KI-Lauf, default: 40),
#           CLEANER_VISION_MODEL (default: haiku — schnell & günstig für Bilder),
#           CLEANER_VISION_LIMIT (max. Screenshots pro Batch, default: 15)
set -euo pipefail

# Shortcuts/launchd haben einen minimalen PATH — claude & Homebrew-Tools sicherstellen
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# API-Key-Fallback: Liegt ein Anthropic-API-Key in .anthropic-api-key (neben diesem
# Skript), schaltet der Cleaner AUTOMATISCH auf pay-per-use um, sobald ein Aufruf
# übers Abo fehlschlägt (z. B. nach Kündigung). Solange das Abo läuft, wird der Key
# nie benutzt und kostet nichts. Einmalig hinterlegen:
#   echo "sk-ant-..." > ~/DesktopCleaner/.anthropic-api-key
#   chmod 600 ~/DesktopCleaner/.anthropic-api-key

DESKTOP="${DESKTOP_DIR:-$HOME/Desktop}"
BASE="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="$BASE/logs"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
MANIFEST="$LOGDIR/manifest-$RUN_ID.tsv"
LOG="$LOGDIR/cleanup-$RUN_ID.log"
INBOX="$DESKTOP/DOKUMENTE/_Eingang"
REVIEW="$DESKTOP/_Prüfen-Löschkandidaten"
AI_LIMIT="${CLEANER_AI_LIMIT:-40}"
MODEL="${CLEANER_MODEL:-sonnet}"
VISION_MODEL="${CLEANER_VISION_MODEL:-haiku}"
VISION_LIMIT="${CLEANER_VISION_LIMIT:-15}"
VISION_STATE="$LOGDIR/vision-processed.txt"

DRY=0; NO_AI=0; NO_VISION=0; BACKLOG=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)        DRY=1 ;;
    --no-ai)          NO_AI=1 ;;
    --no-vision)      NO_VISION=1 ;;
    --vision-backlog) BACKLOG=1 ;;
    *) echo "Unbekannte Option: $arg"; exit 1 ;;
  esac
done

mkdir -p "$LOGDIR"

# Lock gegen Doppelstart (Hotkey zweimal gedrückt, während die KI-Phase noch läuft).
# mkdir ist atomar; flock(1) existiert auf macOS nicht.
LOCKDIR="$BASE/.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  osascript -e 'display notification "Läuft bereits — zweiter Start ignoriert." with title "Desktop-Cleaner"' 2>/dev/null || true
  exit 0
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

# claude -p mit automatischem API-Key-Fallback (siehe Kommentar oben):
# erst normal übers Abo; schlägt das fehl und ein Key ist hinterlegt, ein Retry per API.
API_KEY_FILE="$BASE/.anthropic-api-key"
claude_p() {
  local prompt="$1" model="$2" turns="$3" outfile="$4"
  if claude -p "$prompt" --model "$model" --allowedTools "Read,Glob" --max-turns "$turns" > "$outfile" 2>>"$LOG"; then
    return 0
  fi
  if [[ -z "${ANTHROPIC_API_KEY:-}" && -s "$API_KEY_FILE" ]]; then
    log "Claude-Aufruf fehlgeschlagen — Fallback auf hinterlegten API-Key."
    if ANTHROPIC_API_KEY="$(cat "$API_KEY_FILE")" claude -p "$prompt" --model "$model" --allowedTools "Read,Glob" --max-turns "$turns" > "$outfile" 2>>"$LOG"; then
      return 0
    fi
  fi
  return 1
}

month_name() {
  case "$1" in
    01) echo "Januar";;  02) echo "Februar";; 03) echo "März";;     04) echo "April";;
    05) echo "Mai";;     06) echo "Juni";;    07) echo "Juli";;     08) echo "August";;
    09) echo "September";; 10) echo "Oktober";; 11) echo "November";; 12) echo "Dezember";;
    *) echo "Unbekannt";;
  esac
}

# Manifest bei jedem echten Lauf anlegen (auch wenn 0 Moves passieren) —
# sonst würde undo.sh das Manifest eines ÄLTEREN Laufs erwischen.
# Nebeneffekt: Unbeschreibbarkeit fliegt vor dem ersten Move auf.
[[ $DRY -eq 0 ]] && : > "$MANIFEST"

# "name.pdf" -> "name 2.pdf", falls das Ziel schon belegt ist (-L: auch kaputte Symlinks zählen als belegt)
unique_dest() {
  local dir="$1" name="$2" base ext candidate n
  if [[ "$name" == *.* ]]; then base="${name%.*}"; ext=".${name##*.}"; else base="$name"; ext=""; fi
  candidate="$dir/$name"; n=2
  while [[ -e "$candidate" || -L "$candidate" ]]; do candidate="$dir/$base $n$ext"; n=$((n+1)); done
  printf '%s' "$candidate"
}

MOVED_COUNT=0
move_file() {
  local src="$1" destdir="$2" dest
  # Tab/Newline im Pfad würde das TSV-Manifest (und damit undo) korrumpieren → nicht anfassen
  case "$src" in
    *$'\t'*|*$'\n'*) log "SKIP (Tab/Zeilenumbruch im Namen): $(basename "$src")"; return 0 ;;
  esac
  dest="$(unique_dest "$destdir" "$(basename "$src")")"
  if [[ $DRY -eq 1 ]]; then
    log "DRY: $(basename "$src") -> ${dest#"$DESKTOP"/}"
    MOVED_COUNT=$((MOVED_COUNT+1)); return 0
  fi
  mkdir -p "$destdir"
  # Write-ahead: Manifest VOR dem Move — undo überspringt Einträge, deren Ziel nicht existiert,
  # aber ein Move ohne Manifest-Eintrag wäre für undo unsichtbar.
  printf '%s\t%s\n' "$src" "$dest" >> "$MANIFEST"
  if mv -n "$src" "$dest" 2>>"$LOG" && [[ ! -e "$src" ]]; then
    log "MOVE: $(basename "$src") -> ${dest#"$DESKTOP"/}"
    MOVED_COUNT=$((MOVED_COUNT+1))
  else
    log "FEHLER (nicht verschoben, bleibt liegen): $src"
  fi
  return 0
}

# Summary-Variablen VOR den Phasen initialisieren — im Backlog-Modus werden
# Phase 1+2 übersprungen und set -u würde sonst am Ende abbrechen
AI_SUMMARY="KI übersprungen"
REVIEW_HINT=""

# ---------- Phase 3 (Funktion): Vision-Pass über Screenshots ----------
# Schaut noch nicht analysierte Screenshots (Original-Namensmuster) an, benennt
# sie sprechend um oder routet Dokument-Screenshots in Fachordner. State-Datei
# verhindert, dass "keep"-Dateien endlos erneut analysiert werden.
VISION_SUMMARY="Vision übersprungen"
VB_ROUND=0
vision_batch() {
  VB_PROCESSED=0
  VB_ROUND=$((VB_ROUND+1))
  local vfiles=() vcount=0 f ext line
  while IFS= read -r -d '' f; do
    case "$f" in *$'\t'*|*$'\n'*) continue ;; esac
    ext="$(printf '%s' "${f##*.}" | tr '[:upper:]' '[:lower:]')"
    case "$ext" in png|jpg|jpeg|heic|webp) ;; *) continue ;; esac
    grep -Fxq "$f" "$VISION_STATE" 2>/dev/null && continue
    vfiles+=("$f"); vcount=$((vcount+1)); [[ $vcount -ge $VISION_LIMIT ]] && break
  done < <(find "$DESKTOP/SCREENSHOTS" -type f \( -name "Bildschirmfoto*" -o -name "Screenshot*" -o -name "CleanShot*" -o -name "Bildschirmaufnahme*" -o -name "Screen Shot*" \) ! -name ".*" -print0 2>/dev/null)

  [[ $vcount -eq 0 ]] && return 0

  log "Vision: $vcount Screenshot(s) ansehen (Modell: $VISION_MODEL, Batch $VB_ROUND) ..."
  local TAXONOMY FILELIST ALLOW_FILE PROMPT RAW_FILE PLAN_OUT
  TAXONOMY="$(cd "$DESKTOP" && find . -maxdepth 2 -type d ! -path "*/.*" | sed 's|^\./||;/^\.$/d' | sort)"
  FILELIST=""
  for f in "${vfiles[@]}"; do
    line="$(stat -f '%N | %z Bytes | geändert %Sm' -t '%Y-%m-%d' "$f" 2>/dev/null || true)"
    [[ -n "$line" ]] && FILELIST="$FILELIST$line"$'\n'
  done
  ALLOW_FILE="$LOGDIR/vision-allow-$RUN_ID-$VB_ROUND.txt"
  printf '%s\n' "${vfiles[@]}" > "$ALLOW_FILE"
  PROMPT="$(cat "$BASE/ai-screenshot-prompt.md"
    printf '\n## Vorhandene Ordnerstruktur (relativ zum Desktop)\n%s\n' "$TAXONOMY"
    printf '\n## Anzusehende Screenshots (absolute Pfade)\n%s\n' "$FILELIST")"
  RAW_FILE="$LOGDIR/vision-plan-$RUN_ID-$VB_ROUND.raw"
  if claude_p "$PROMPT" "$VISION_MODEL" 100 "$RAW_FILE"; then
    PLAN_OUT="$(python3 "$BASE/apply-plan.py" "$RAW_FILE" "$DESKTOP" "$DESKTOP/SCREENSHOTS" "$REVIEW" "$MANIFEST" "$ALLOW_FILE" || true)"
    echo "$PLAN_OUT" | tee -a "$LOG"
    VISION_SUMMARY="$(echo "$PLAN_OUT" | tail -1)"
    printf '%s\n' "${vfiles[@]}" >> "$VISION_STATE"
    VB_PROCESSED=$vcount
  else
    log "Vision-Aufruf fehlgeschlagen — Screenshots bleiben unverändert."
    VISION_SUMMARY="Vision fehlgeschlagen"
    VB_PROCESSED=-1
  fi
  return 0
}

log "=== Desktop-Cleaner Lauf $RUN_ID (dry=$DRY, no_ai=$NO_AI, vision=$((1-NO_VISION)), backlog=$BACKLOG) auf $DESKTOP ==="

if [[ $BACKLOG -eq 0 ]]; then
# ---------- Phase 1: deterministische Typ-Sortierung ----------
# Nur lose DATEIEN direkt auf dem Desktop. Ordner werden NIE angefasst.
while IFS= read -r -d '' f; do
  # Datei kann seit dem find verschwunden sein (Nutzer räumt parallel) → ein SKIP, kein Abbruch
  [[ -f "$f" ]] || { log "SKIP (verschwunden): $f"; continue; }
  name="$(basename "$f")"
  case "$name" in
    *.crdownload|*.download|*.part|*.tmp) log "SKIP (laufender Download): $name"; continue ;;
  esac
  ext=""
  [[ "$name" == *.* ]] && ext="$(printf '%s' "${name##*.}" | tr '[:upper:]' '[:lower:]')"
  if ! ym="$(stat -f %Sm -t '%Y %m' "$f" 2>/dev/null)"; then
    log "SKIP (nicht lesbar): $name"; continue
  fi
  year="${ym%% *}"; month="${ym##* }"

  case "$name" in
    Bildschirmfoto*|Screenshot*|CleanShot*|Bildschirmaufnahme*|"Screen Recording"*|"Screen Shot"*)
      move_file "$f" "$DESKTOP/SCREENSHOTS/$year/$month-$(month_name "$month")"; continue ;;
  esac

  case "$ext" in
    png|jpg|jpeg|heic|heif|gif|webp|svg|tiff|bmp) move_file "$f" "$DESKTOP/MEDIEN/Fotos" ;;
    mov|mp4|m4v|avi|mkv)                          move_file "$f" "$DESKTOP/MEDIEN/Videos" ;;
    mp3|wav|m4a|aac|flac|ogg)                     move_file "$f" "$DESKTOP/MEDIEN/Audio" ;;
    zip|rar|7z|tar|gz|tgz)                        move_file "$f" "$DESKTOP/ARCHIV/Alte_Dateien" ;;
    dmg|pkg|iso)                                  move_file "$f" "$DESKTOP/ARCHIV/Installer" ;;
    pdf|doc|docx|pages|txt|md|rtf|odt|xls|xlsx|csv|ppt|pptx|key|numbers)
                                                  move_file "$f" "$INBOX" ;;
    *) log "SKIP (unbekannter Typ, bleibt liegen): $name" ;;
  esac
done < <(find "$DESKTOP" -maxdepth 1 -type f ! -name ".*" -print0)

log "Phase 1 fertig: $MOVED_COUNT Datei(en) einsortiert."

# ---------- Phase 2: KI-Ablage aus dem Eingang ----------
AI_SUMMARY="KI übersprungen"
REVIEW_HINT=""
if [[ $NO_AI -eq 0 && $DRY -eq 0 && -d "$INBOX" ]] && command -v claude >/dev/null 2>&1; then
  files=(); count=0
  while IFS= read -r -d '' f; do
    case "$f" in *$'\t'*|*$'\n'*) continue ;; esac   # würden Prompt/Allowlist korrumpieren
    files+=("$f"); count=$((count+1)); [[ $count -ge $AI_LIMIT ]] && break
  done < <(find "$INBOX" -maxdepth 1 -type f ! -name ".*" -print0)

  if [[ $count -gt 0 ]]; then
    log "Phase 2: KI-Ablage für $count Dokument(e) (Modell: $MODEL) ..."
    TAXONOMY="$(cd "$DESKTOP" && find . -maxdepth 2 -type d ! -path "*/.*" | sed 's|^\./||;/^\.$/d' | sort)"
    FILELIST=""
    for f in "${files[@]}"; do
      line="$(stat -f '%N | %z Bytes | geändert %Sm' -t '%Y-%m-%d' "$f" 2>/dev/null || true)"
      [[ -n "$line" ]] && FILELIST="$FILELIST$line"$'\n'
    done
    # Allowlist: apply-plan.py akzeptiert NUR Moves für exakt diese Dateien
    ALLOW_FILE="$LOGDIR/ai-allow-$RUN_ID.txt"
    printf '%s\n' "${files[@]}" > "$ALLOW_FILE"

    PROMPT="$(cat "$BASE/ai-prompt.md"
      printf '\n## Vorhandene Ordnerstruktur (relativ zum Desktop)\n%s\n' "$TAXONOMY"
      printf '\n## Zu sortierende Dateien (absolute Pfade)\n%s\n' "$FILELIST")"

    RAW_FILE="$LOGDIR/ai-plan-$RUN_ID.raw"
    if claude_p "$PROMPT" "$MODEL" 150 "$RAW_FILE"; then
      PLAN_OUT="$(python3 "$BASE/apply-plan.py" "$RAW_FILE" "$DESKTOP" "$INBOX" "$REVIEW" "$MANIFEST" "$ALLOW_FILE" || true)"
      echo "$PLAN_OUT" | tee -a "$LOG"
      AI_SUMMARY="$(echo "$PLAN_OUT" | tail -1)"
      if echo "$AI_SUMMARY" | grep -q "review=[1-9]"; then
        REVIEW_HINT=" Prüf-Ordner ansehen vor dem Löschen!"
      fi
    else
      log "KI-Aufruf fehlgeschlagen — Dokumente bleiben in DOKUMENTE/_Eingang."
      AI_SUMMARY="KI fehlgeschlagen, Dokumente im Eingang"
    fi
  else
    AI_SUMMARY="Eingang leer"
  fi
fi
fi  # Ende BACKLOG-Guard (Phase 1+2)

# ---------- Phase 3: Vision-Pass ----------
if [[ $NO_VISION -eq 0 && $DRY -eq 0 ]] && command -v claude >/dev/null 2>&1; then
  if [[ $BACKLOG -eq 1 ]]; then
    rounds=0
    while :; do
      vision_batch
      [[ $VB_PROCESSED -le 0 ]] && break
      rounds=$((rounds+1))
      [[ $rounds -ge 40 ]] && { log "Backlog-Limit (40 Batches) erreicht — Rest beim nächsten Lauf."; break; }
    done
    [[ "$VISION_SUMMARY" == "Vision übersprungen" ]] && VISION_SUMMARY="Backlog leer — alles analysiert"
  else
    vision_batch
    [[ "$VISION_SUMMARY" == "Vision übersprungen" ]] && VISION_SUMMARY="keine neuen Screenshots"
  fi
fi

log "=== Fertig. Phase 1: $MOVED_COUNT | Phase 2: $AI_SUMMARY | Vision: $VISION_SUMMARY ==="

if [[ $DRY -eq 0 ]]; then
  # ---------- Benachrichtigung: menschenlesbar statt Rohdaten ----------
  # "|| true": grep findet bei "übersprungen"-Summaries nichts — ohne das würde
  # pipefail+set -e den Lauf hier beenden (die Zahlen defaulten dann auf 0)
  num() { printf '%s' "$1" | grep -oE "${2}=[0-9]+" | head -1 | cut -d= -f2 || true; }
  docs="$(num "$AI_SUMMARY" moved)";            docs="${docs:-0}"
  docs_review="$(num "$AI_SUMMARY" review)";    docs_review="${docs_review:-0}"
  shots="$(num "$VISION_SUMMARY" renamed)";     shots="${shots:-0}"
  shots_docs="$(num "$VISION_SUMMARY" moved)";  shots_docs="${shots_docs:-0}"
  shots_review="$(num "$VISION_SUMMARY" review)"; shots_review="${shots_review:-0}"
  abgelegt=$((docs + shots_docs))
  pruefen=$((docs_review + shots_review))

  PARTS=()
  if [[ $MOVED_COUNT -eq 1 ]]; then PARTS+=("1 Datei einsortiert")
  elif [[ $MOVED_COUNT -gt 1 ]]; then PARTS+=("$MOVED_COUNT Dateien einsortiert"); fi
  if [[ $abgelegt -eq 1 ]]; then PARTS+=("1 Dokument abgelegt")
  elif [[ $abgelegt -gt 1 ]]; then PARTS+=("$abgelegt Dokumente abgelegt"); fi
  if [[ $shots -eq 1 ]]; then PARTS+=("1 Screenshot benannt")
  elif [[ $shots -gt 1 ]]; then PARTS+=("$shots Screenshots benannt"); fi
  [[ $pruefen -gt 0 ]] && PARTS+=("$pruefen zur Prüfung")

  if [[ ${#PARTS[@]} -eq 0 ]]; then
    SUBTITLE="Nichts zu tun"
    BODY="Dein Desktop ist bereits aufgeräumt ✨"
  else
    SUBTITLE="Aufgeräumt ✓"
    BODY=""
    for part in "${PARTS[@]}"; do
      [[ -n "$BODY" ]] && BODY="$BODY · "
      BODY="$BODY$part"
    done
  fi
  case "$AI_SUMMARY$VISION_SUMMARY" in
    *fehlgeschlagen*) SUBTITLE="Teilweise fehlgeschlagen"; BODY="$BODY — Details im Log" ;;
  esac

  BODY="$(printf '%s' "$BODY" | tr -d '"\\')"
  osascript -e "display notification \"$BODY\" with title \"Desktop Cleaner\" subtitle \"$SUBTITLE\" sound name \"Glass\"" 2>/dev/null || true
fi
