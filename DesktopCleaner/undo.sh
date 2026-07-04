#!/bin/bash
# Macht den letzten Cleanup-Lauf rückgängig (oder einen bestimmten: undo.sh logs/manifest-….tsv)
set -euo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${1:-$(ls -t "$BASE/logs"/manifest-*.tsv 2>/dev/null | head -1 || true)}"
if [[ -z "${MANIFEST:-}" || ! -f "$MANIFEST" ]]; then
  echo "Kein Manifest gefunden."; exit 1
fi
COUNT="$(wc -l < "$MANIFEST" | tr -d ' ')"
echo "Mache rückgängig: $MANIFEST ($COUNT Einträge)"
if [[ "$COUNT" -eq 0 ]]; then
  echo "Dieser Lauf hat nichts verschoben — nichts zu tun."; exit 0
fi
restored=0; skipped=0
while IFS=$'\t' read -r src dst; do
  [[ -z "$src" || -z "$dst" ]] && continue
  # Nur absolute, zweispaltige Einträge akzeptieren (korrupte Zeilen niemals ausführen)
  if [[ "$src" != /* || "$dst" != /* ]]; then
    echo "ÜBERSPRUNGEN (ungültiger Manifest-Eintrag): $src -> $dst"; skipped=$((skipped+1)); continue
  fi
  if [[ -e "$dst" && ! -e "$src" ]]; then
    mkdir -p "$(dirname "$src")"
    if mv -n "$dst" "$src" 2>/dev/null; then
      restored=$((restored+1))
    else
      echo "FEHLER bei: $dst"; skipped=$((skipped+1))
    fi
  else
    echo "ÜBERSPRUNGEN (Ziel fehlt oder Quelle belegt): $dst"
    skipped=$((skipped+1))
  fi
done < <(tail -r "$MANIFEST")
echo "Wiederhergestellt: $restored | Übersprungen: $skipped"
