#!/usr/bin/env python3
"""Führt den JSON-Plan der KI aus (Dokumente UND Screenshots). Sicherheitsregeln:
- Quelle muss eine existierende Datei unterhalb des Quellordners sein
  UND auf der Allowlist stehen (= exakt die Dateien, die der KI gezeigt wurden)
- Ziel muss innerhalb des Desktops liegen (kein "..", keine absoluten target_dirs)
- "rename" nur im selben Ordner, Dateiendung muss erhalten bleiben
- "review"-Aktionen sind gedeckelt (Prompt-Injection kann nicht den ganzen
  Bestand in die Löschkandidaten fluten) — Überschuss wird normal abgelegt
- es wird ausschließlich verschoben/umbenannt (shutil.move), nie gelöscht
- Manifest wird VOR jedem Move geschrieben (write-ahead; undo überspringt
  Einträge, deren Ziel nicht existiert)

Aufruf: apply-plan.py <raw> <desktop> <srcroot> <review> <manifest> <allowlist>
"""
import json
import os
import shutil
import sys
import unicodedata

raw_path, desktop, srcroot, review, manifest, allow_path = sys.argv[1:7]
raw = open(raw_path, encoding="utf-8", errors="replace").read()

desktop_r = os.path.realpath(desktop)
srcroot_r = os.path.realpath(srcroot)


def nfc(s):
    """macOS speichert Dateinamen NFD-zerlegt, LLM-Ausgaben sind meist NFC —
    für VERGLEICHE immer normalisieren (APFS-Lookups selbst sind formunabhängig)."""
    return unicodedata.normalize("NFC", s)


allow = set()
with open(allow_path, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if line:
            allow.add(nfc(os.path.realpath(line)))


def extract_plan(text):
    """Erstes valides JSON-Array im Text — robust gegen Begleittext/Code-Fences."""
    dec = json.JSONDecoder()
    idx = text.find("[")
    while idx != -1:
        try:
            obj, _ = dec.raw_decode(text[idx:])
            if isinstance(obj, list):
                return obj
        except Exception:
            pass
        idx = text.find("[", idx + 1)
    return None


plan = extract_plan(raw)
if plan is None:
    print("OK moved=0 renamed=0 review=0 kept=0 skipped=0 (kein valider Plan gefunden)")
    sys.exit(0)

review_cap = max(3, len(plan) // 5)
review_seen = 0
moved = renamed = review_n = kept = skipped = 0


def unique_dest(d, name):
    base, ext = os.path.splitext(name)
    cand, n = os.path.join(d, name), 2
    while os.path.lexists(cand):
        cand = os.path.join(d, f"{base} {n}{ext}")
        n += 1
    return cand


def valid_new_name(name, src):
    """Neuer Basename: kein Pfad, keine Steuerzeichen, gleiche Endung, kein Hidden-File."""
    if not name or len(name) > 120:
        return None
    if any(c in name for c in ("/", "\\", "\t", "\n")) or name in (".", "..") or name.startswith("."):
        return None
    if os.path.splitext(name)[1].lower() != os.path.splitext(src)[1].lower():
        return None
    return name


def resolve_target(tgt_raw):
    """Zielordner auflösen. Exakten Namen bevorzugen (es gibt Ordner mit
    anhängenden Leerzeichen wie 'Bachelorarbeit '), Whitespace-Strip nur als
    Fallback. Absolut-Check VOR jedem Slash-Strip (sonst würde '/tmp/x' zu
    'tmp/x' relativiert statt abgelehnt)."""
    for tgt in (tgt_raw, tgt_raw.strip()):
        if not tgt or tgt.startswith("/") or ".." in tgt.split("/"):
            continue
        tgt = tgt.rstrip("/")
        if not tgt:
            continue
        cand = os.path.realpath(os.path.join(desktop_r, tgt))
        if cand != desktop_r and not cand.startswith(desktop_r + os.sep):
            continue
        if cand in (srcroot_r, desktop_r):
            continue
        if os.path.isdir(cand):
            return cand
        fallback = cand  # existiert noch nicht → wird ggf. angelegt
    try:
        return fallback
    except NameError:
        return None


for item in plan:
    try:
        if not isinstance(item, dict):
            skipped += 1
            continue
        src = os.path.realpath(str(item.get("file", "")))
        action = str(item.get("action", "move"))
        reason = str(item.get("reason", ""))[:80].replace("\n", " ")

        if nfc(src) not in allow:
            skipped += 1
            print(f"  ÜBERSPRUNGEN (nicht auf der Allowlist): {item.get('file')}")
            continue
        if not nfc(src).startswith(nfc(srcroot_r) + os.sep) or not os.path.isfile(src):
            skipped += 1
            print(f"  ÜBERSPRUNGEN (Quelle ungültig): {item.get('file')}")
            continue

        if action == "keep":
            kept += 1
            continue

        if action == "review":
            review_seen += 1
            if review_seen > review_cap:
                action = "move"
                item["target_dir"] = "DOKUMENTE/Sonstiges"
                print(f"  HINWEIS: review-Deckel ({review_cap}) erreicht — "
                      f"{os.path.basename(src)} wird stattdessen normal abgelegt")

        new_name = None
        if item.get("new_name"):
            new_name = valid_new_name(str(item["new_name"]), src)
            if new_name is None and action == "rename":
                skipped += 1
                print(f"  ÜBERSPRUNGEN (neuer Name ungültig): {item.get('new_name')!r} "
                      f"für {os.path.basename(src)}")
                continue

        if action == "rename":
            destdir = os.path.dirname(src)
            if nfc(new_name) == nfc(os.path.basename(src)):
                kept += 1
                continue
        elif action == "review":
            destdir = os.path.realpath(review)
        else:  # move
            destdir = resolve_target(str(item.get("target_dir", "")))
            if destdir is None:
                skipped += 1
                print(f"  ÜBERSPRUNGEN (Ziel ungültig): {item.get('target_dir')!r} "
                      f"für {os.path.basename(src)}")
                continue

        dest = unique_dest(destdir, new_name or os.path.basename(src))
        if "\t" in src + dest or "\n" in src + dest:
            skipped += 1
            print(f"  ÜBERSPRUNGEN (Tab/Newline im Pfad): {os.path.basename(src)}")
            continue

        os.makedirs(destdir, exist_ok=True)
        # Write-ahead-Manifest: Eintrag vor dem Move, geflusht
        with open(manifest, "a", encoding="utf-8") as m:
            m.write(f"{src}\t{dest}\n")
            m.flush()
            os.fsync(m.fileno())
        shutil.move(src, dest)
        if action == "rename":
            renamed += 1
            label = "UMBENANNT"
        elif action == "review":
            review_n += 1
            label = "PRÜFEN"
        else:
            moved += 1
            label = "ABGELEGT"
        print(f"  {label}: {os.path.basename(src)} -> {os.path.relpath(dest, desktop_r)}  ({reason})")
    except Exception as e:
        skipped += 1
        print(f"  FEHLER: {e}")

print(f"OK moved={moved} renamed={renamed} review={review_n} kept={kept} skipped={skipped}")
