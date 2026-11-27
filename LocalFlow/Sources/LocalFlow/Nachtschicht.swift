import AppKit
import Foundation

// MARK: - Agentic Hours (aktive Stunden der KI-Agenten, letzte 7 Tage)

/// Liest aus `~/.claude/projects/*/*.jsonl` NUR die `"timestamp": "…"`-Werte und summiert pro Datei
/// die Abstände zwischen aufeinanderfolgenden Zeitstempeln, die kürzer als 5 Minuten sind.
///
/// Datenschutz: Es wird kein Zeileninhalt geparst, gespeichert oder gesendet. Die Bytes werden nur
/// nach dem Schlüssel `"timestamp"` durchsucht; der Cache enthält ausschließlich Zahlen
/// (Dateigröße, Lese-Offset, letzter Zeitstempel, aktive Sekunden je 5-Minuten-Fenster).
///
/// Tempo: Transkripte sind Append-only und können GB groß werden. Deshalb merkt sich der Cache
/// pro Datei, bis wohin schon gelesen wurde; danach werden nur neu angehängte Bytes gelesen.
/// Dateien, die seit mehr als 7 Tagen nicht geändert wurden, werden gar nicht geöffnet.
enum AgenticHours {
    static let maxGap: Double = 300          // < 5 min zwischen zwei Zeitstempeln = aktiv
    static let windowDays: Double = 7
    static let bucketSeconds: Double = 300   // Auflösung der Fenstergrenze (max. Fehler je Datei: 5 min)

    struct Result {
        var seconds: Double = 0
        var hours: Double { seconds / 3600 }
        var folderMissing = false
        var filesInWindow = 0        // Dateien mit mtime in den letzten 7 Tagen
        var filesRead = 0            // davon mit neuen Bytes seit dem letzten Lauf
        var bytesRead: Int64 = 0
        var timestampsSeen = 0
        var elapsed: Double = 0
    }

    struct FileEntry: Codable {
        var inode: UInt64
        var offset: Int64            // bis hierhin gelesen
        var last: Double             // letzter (größter) gesehener Zeitstempel, Unix-Sekunden
        var buckets: [Int: Double]   // 5-Minuten-Fenster-Index → aktive Sekunden
    }

    struct Cache: Codable {
        var version = 1
        var files: [String: FileEntry] = [:]
    }

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    static var defaultCacheURL: URL {
        Settings.appSupportDir.appendingPathComponent("nachtschicht-cache.json")
    }

    /// Blockiert — immer aus einem Hintergrund-Thread aufrufen (die App tut das).
    /// `cacheURL == nil` → ohne Cache (alles frisch lesen, nichts schreiben).
    static func compute(root: URL = defaultRoot, cacheURL: URL? = defaultCacheURL,
                        now: Date = Date()) -> Result {
        let started = Date()
        var result = Result()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            result.folderMissing = true
            return result
        }

        var cache = Cache()
        if let url = cacheURL, let data = try? Data(contentsOf: url),
           let c = try? JSONDecoder().decode(Cache.self, from: data), c.version == 1 {
            cache = c
        }

        let nowTs = now.timeIntervalSince1970
        let cutoff = nowTs - windowDays * 86400
        let cutoffBucket = Int(cutoff / bucketSeconds)

        // 1) Kandidaten: genau eine Ebene tief (projects/<projekt>/<session>.jsonl), nur per mtime.
        struct Job { let path: String; let size: Int64; let inode: UInt64 }
        var jobs: [Job] = []
        let projects = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        for p in projects where !p.hasPrefix(".") {
            let dir = root.appendingPathComponent(p).path
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".jsonl") {
                let path = dir + "/" + n
                var st = stat()
                guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
                let mtime = Double(st.st_mtimespec.tv_sec)
                guard mtime >= cutoff else { continue }
                jobs.append(Job(path: path, size: Int64(st.st_size), inode: UInt64(st.st_ino)))
            }
        }
        result.filesInWindow = jobs.count

        // 2) Neue Bytes parallel lesen (SSD verträgt das gut).
        var entries = [FileEntry](repeating: FileEntry(inode: 0, offset: 0, last: 0, buckets: [:]),
                                  count: jobs.count)
        var reads = [Int64](repeating: 0, count: jobs.count)
        var seen = [Int](repeating: 0, count: jobs.count)
        for (i, job) in jobs.enumerated() {
            if let e = cache.files[job.path], e.inode == job.inode, e.offset <= job.size {
                entries[i] = e
            } else {
                entries[i] = FileEntry(inode: job.inode, offset: 0, last: 0, buckets: [:])
            }
        }
        entries.withUnsafeMutableBufferPointer { ebuf in
            reads.withUnsafeMutableBufferPointer { rbuf in
                seen.withUnsafeMutableBufferPointer { sbuf in
                    DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
                        let job = jobs[i]
                        guard job.size > ebuf[i].offset else { return }
                        let (bytes, count) = scan(path: job.path, upTo: job.size, entry: &ebuf[i])
                        rbuf[i] = bytes
                        sbuf[i] = count
                    }
                }
            }
        }

        // 3) Summieren + Cache auf das Fenster zurückschneiden.
        var newCache = Cache()
        let nowBucket = Int(nowTs / bucketSeconds)
        for (i, job) in jobs.enumerated() {
            var e = entries[i]
            e.buckets = e.buckets.filter { $0.key >= cutoffBucket - 1 }
            for (b, s) in e.buckets where b >= cutoffBucket && b <= nowBucket { result.seconds += s }
            if reads[i] > 0 { result.filesRead += 1 }
            result.bytesRead += reads[i]
            result.timestampsSeen += seen[i]
            newCache.files[job.path] = e
        }
        if let url = cacheURL, let data = try? JSONEncoder().encode(newCache) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        result.elapsed = Date().timeIntervalSince(started)
        return result
    }

    /// Liest [entry.offset, size) in Blöcken und wertet jeden `"timestamp"`-Treffer aus.
    /// Gibt (gelesene Bytes, Anzahl Zeitstempel) zurück. Inhalt wird nicht behalten.
    private static func scan(path: String, upTo size: Int64, entry: inout FileEntry) -> (Int64, Int) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return (0, 0) }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: UInt64(entry.offset)) } catch { return (0, 0) }

        let pattern = Array("\"timestamp\"".utf8)
        let tail = 96                       // Schlüssel + Doppelpunkt/Leerzeichen + Zeitstempel passen hinein
        let chunk = 8 << 20
        var remaining = size - entry.offset
        var carry = Data()
        var bytesRead: Int64 = 0
        var count = 0
        var last = entry.last
        var buckets = entry.buckets

        while remaining > 0 {
            guard let data = try? fh.read(upToCount: Int(min(Int64(chunk), remaining))),
                  !data.isEmpty else { break }
            remaining -= Int64(data.count)
            bytesRead += Int64(data.count)
            var buf = carry
            buf.append(data)
            let isLast = remaining <= 0
            buf.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                let n = raw.count
                // Treffer, die im Schwanz beginnen, wertet der nächste Block aus (siehe carry).
                let limit = isLast ? n : max(0, n - tail)
                var pos = 0
                while pos < limit {
                    guard let hit = memmem(base + pos, n - pos, pattern, pattern.count) else { break }
                    let start = base.distance(to: UnsafeRawPointer(hit))
                    if start >= limit { break }
                    // Nach dem Schlüssel: optionale Leerzeichen, ':', optionale Leerzeichen, '"'.
                    var q = start + pattern.count
                    let bytes = base.assumingMemoryBound(to: UInt8.self)
                    func skipWS() { while q < n, bytes[q] == 32 || bytes[q] == 9 { q += 1 } }
                    skipWS()
                    var ok = q < n && bytes[q] == 58      // ':'
                    if ok { q += 1; skipWS(); ok = q < n && bytes[q] == 34 }   // '"'
                    let tsStart = q + 1
                    if ok, let t = parseISO8601(base + tsStart, available: n - tsStart) {
                        count += 1
                        let gap = t - last
                        if gap > 0 && gap < maxGap {
                            buckets[Int(t / bucketSeconds), default: 0] += gap
                        }
                        if t > last { last = t }
                    }
                    pos = start + pattern.count
                }
            }
            carry = isLast ? Data() : buf.suffix(min(tail, buf.count))
        }
        entry.offset += bytesRead
        entry.last = last
        entry.buckets = buckets
        return (bytesRead, count)
    }

    /// Parst "YYYY-MM-DDTHH:MM:SS[.fff…](Z|±HH:MM)" direkt aus Bytes → Unix-Sekunden.
    static func parseISO8601(_ p: UnsafeRawPointer, available: Int) -> Double? {
        guard available >= 19 else { return nil }
        let b = p.assumingMemoryBound(to: UInt8.self)
        func d(_ i: Int) -> Int? { let c = b[i]; return (c >= 48 && c <= 57) ? Int(c - 48) : nil }
        func num(_ i: Int, _ len: Int) -> Int? {
            var v = 0
            for k in 0..<len { guard let x = d(i + k) else { return nil }; v = v * 10 + x }
            return v
        }
        guard b[4] == 45, b[7] == 45, b[10] == 84, b[13] == 58, b[16] == 58,
              let y = num(0, 4), let mo = num(5, 2), let da = num(8, 2),
              let h = num(11, 2), let mi = num(14, 2), let s = num(17, 2),
              (1...12).contains(mo), (1...31).contains(da), h < 24, mi < 60, s < 61 else { return nil }
        var i = 19
        var frac = 0.0, scale = 0.1
        if i < available, b[i] == 46 {           // '.'
            i += 1
            while i < available, let x = d(i) { frac += Double(x) * scale; scale /= 10; i += 1 }
        }
        var offset = 0
        if i < available, b[i] == 43 || b[i] == 45, i + 5 < available,   // '+' / '-'
           let oh = num(i + 1, 2), let om = num(i + 4, 2) {
            offset = (oh * 3600 + om * 60) * (b[i] == 43 ? 1 : -1)
        }
        // Tage seit 1970-01-01 (Howard Hinnant, days_from_civil)
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (mo + 9) % 12
        let doy = (153 * mp + 2) / 5 + da - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        return Double(days * 86400 + h * 3600 + mi * 60 + s - offset) + frac
    }
}

// MARK: - Teilen („Die Nachtschicht“ auf sleeplessenzo.com)

/// Genau die Zahlen, die geteilt werden — sonst nichts.
struct NachtschichtSnapshot {
    var woerter: Int
    var diktate: Int
    var minuten: Int
    var agentStunden: Double
    var agentOrdnerFehlt: Bool

    static let baseURL = "https://github.com/enzolorenz100-cmyk/sleeplessenzo/issues/new"

    var agentStundenText: String { String(format: "%.1f", agentStunden) }

    func shareURL(handle: String) -> URL? {
        var c = URLComponents(string: Self.baseURL)
        var items = [
            URLQueryItem(name: "template", value: "checkin.yml"),
            URLQueryItem(name: "title", value: "Check-in"),
            URLQueryItem(name: "quelle", value: "localflow"),
            URLQueryItem(name: "lf_woerter", value: String(woerter)),
            URLQueryItem(name: "lf_diktate", value: String(diktate)),
            URLQueryItem(name: "lf_minuten", value: String(minuten)),
            URLQueryItem(name: "agent_stunden", value: agentStundenText),
        ]
        let h = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !h.isEmpty { items.append(URLQueryItem(name: "handle", value: h)) }
        c?.queryItems = items
        return c?.url
    }

    /// Wird von der App und vom CLI-Flag `--nachtschicht-stats` benutzt.
    static func collect(history: HistoryStore, agentic: AgenticHours.Result) -> NachtschichtSnapshot {
        let w = history.weekStats(days: 7)
        return NachtschichtSnapshot(woerter: w.words, diktate: w.count,
                                    minuten: Int((w.recordedSeconds / 60).rounded()),
                                    agentStunden: (agentic.hours * 10).rounded() / 10,
                                    agentOrdnerFehlt: agentic.folderMissing)
    }
}

/// Ablauf für Dashboard-Knopf und Menüeintrag: rechnen (Hintergrund) → Zahlen zeigen → Browser.
enum NachtschichtShare {
    private static var running = false
    private static let handleKey = "nachtschichtHandle"

    /// `onBusy(true/false)` erlaubt der Oberfläche, einen „berechne…“-Zustand zu zeigen.
    static func start(history: HistoryStore, onBusy: ((Bool) -> Void)? = nil) {
        guard !running else { return }
        running = true
        onBusy?(true)
        DispatchQueue.global(qos: .userInitiated).async {
            let agentic = AgenticHours.compute()
            let snap = NachtschichtSnapshot.collect(history: history, agentic: agentic)
            DispatchQueue.main.async {
                running = false
                onBusy?(false)
                confirmAndOpen(snap)
            }
        }
    }

    private static func confirmAndOpen(_ s: NachtschichtSnapshot) {
        let alert = NSAlert()
        alert.messageText = "Für die Nachtschicht teilen"
        let agentLine = s.agentOrdnerFehlt
            ? "Agentic Hours: 0 (kein ~/.claude/projects gefunden)"
            : "Agentic Hours: \(s.agentStundenText) h"
        alert.informativeText = """
        Diese Zahlen der letzten 7 Tage werden an das Check-in-Formular übergeben:

        Wörter diktiert: \(s.woerter)
        Diktate: \(s.diktate)
        Aufnahmedauer: \(s.minuten) Min
        \(agentLine)

        Es werden nur diese Zahlen übertragen — kein Diktat- und kein Transkripttext. \
        Der Browser öffnet ein GitHub-Formular; abgeschickt wird erst, wenn du dort auf „Submit“ klickst.
        """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Dein Handle (optional, z. B. @name)"
        field.stringValue = UserDefaults.standard.string(forKey: handleKey) ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Im Browser öffnen")
        alert.addButton(withTitle: "Abbrechen")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(field.stringValue, forKey: handleKey)
        if let url = s.shareURL(handle: field.stringValue) {
            NSWorkspace.shared.open(url)
        }
    }
}
