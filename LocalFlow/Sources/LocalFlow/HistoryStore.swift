import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct HistoryEntry {
    var id: Int64
    var timestamp: Date
    var asrText: String
    var formattedText: String
    var appBundle: String
    var language: String
    var durationSeconds: Double
    var latencySeconds: Double
}

/// Diktier-Verlauf in SQLite (nur Text — bewusst KEIN Roh-Audio wie bei Wispr, Privacy by Design).
final class HistoryStore {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "localflow.history")

    /// `readOnly: true` öffnet die DB nur lesend und legt nichts an (für CLI-Auswertungen,
    /// die neben der laufenden App nichts verändern dürfen).
    init(readOnly: Bool = false) {
        let url = Settings.appSupportDir.appendingPathComponent("history.sqlite")
        if readOnly {
            if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
                sqlite3_close(db); db = nil
            }
            return
        }
        try? FileManager.default.createDirectory(at: Settings.appSupportDir, withIntermediateDirectories: true)
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            Log.error("History-DB konnte nicht geöffnet werden")
            return
        }
        exec("""
        CREATE TABLE IF NOT EXISTS history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL,
            asr_text TEXT NOT NULL,
            formatted_text TEXT NOT NULL,
            app_bundle TEXT,
            language TEXT,
            duration_s REAL,
            latency_s REAL
        );
        """)
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            Log.error("SQLite: \(err.map { String(cString: $0) } ?? "?")")
            sqlite3_free(err)
        }
    }

    func add(asr: String, formatted: String, appBundle: String, language: String,
             duration: Double, latency: Double) {
        queue.async { [self] in
            var stmt: OpaquePointer?
            let sql = "INSERT INTO history (ts, asr_text, formatted_text, app_bundle, language, duration_s, latency_s) VALUES (?,?,?,?,?,?,?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, asr, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, formatted, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, appBundle, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, language, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 6, duration)
            sqlite3_bind_double(stmt, 7, latency)
            sqlite3_step(stmt)
        }
    }

    struct Stats {
        var count: Int = 0
        var totalWords: Int = 0
        var avgLatency: Double = 0
        var todayCount: Int = 0
    }

    func stats() -> Stats {
        queue.sync { [self] in
            var s = Stats()
            var stmt: OpaquePointer?
            // Wortzahl aus formatiertem Text grob per Leerzeichen; Tagesbeginn als Unix-Zeit.
            let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            let sql = "SELECT formatted_text, latency_s, ts FROM history"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return s }
            defer { sqlite3_finalize(stmt) }
            var latencySum = 0.0
            while sqlite3_step(stmt) == SQLITE_ROW {
                s.count += 1
                if let c = sqlite3_column_text(stmt, 0) {
                    let words = String(cString: c).split(whereSeparator: { $0 == " " || $0 == "\n" }).count
                    s.totalWords += words
                }
                latencySum += sqlite3_column_double(stmt, 1)
                if sqlite3_column_double(stmt, 2) >= startOfDay { s.todayCount += 1 }
            }
            s.avgLatency = s.count > 0 ? latencySum / Double(s.count) : 0
            return s
        }
    }

    struct WeekStats {
        var count: Int = 0
        var words: Int = 0
        var recordedSeconds: Double = 0   // Summe duration_s = Länge der Aufnahmen (inkl. Pausen)
    }

    /// Diktate, Wörter und Aufnahmedauer der letzten `days` Tage (rollierend ab jetzt).
    /// Wortzählung wie in `stats()`, damit beide Anzeigen zusammenpassen.
    func weekStats(days: Int = 7) -> WeekStats {
        queue.sync { [self] in
            var w = WeekStats()
            var stmt: OpaquePointer?
            let since = Date().timeIntervalSince1970 - Double(days) * 86400
            let sql = "SELECT formatted_text, duration_s FROM history WHERE ts >= ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return w }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, since)
            while sqlite3_step(stmt) == SQLITE_ROW {
                w.count += 1
                if let c = sqlite3_column_text(stmt, 0) {
                    w.words += String(cString: c).split(whereSeparator: { $0 == " " || $0 == "\n" }).count
                }
                w.recordedSeconds += sqlite3_column_double(stmt, 1)
            }
            return w
        }
    }

    func recent(limit: Int = 10) -> [HistoryEntry] {
        queue.sync { [self] in
            var stmt: OpaquePointer?
            let sql = "SELECT id, ts, asr_text, formatted_text, app_bundle, language, duration_s, latency_s FROM history ORDER BY id DESC LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            return readEntries(stmt)
        }
    }

    func delete(id: Int64) {
        queue.async { [self] in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM history WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
    }

    func deleteAll() {
        queue.sync { [self] in
            exec("DELETE FROM history;")
            exec("VACUUM;")   // Datei tatsächlich schrumpfen
        }
    }

    /// Größe der Verlaufsdatenbank in Bytes (für die Speicher-Anzeige).
    func databaseBytes() -> Int {
        let url = Settings.appSupportDir.appendingPathComponent("history.sqlite")
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private func readEntries(_ stmt: OpaquePointer?) -> [HistoryEntry] {
        var result: [HistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(HistoryEntry(
                id: sqlite3_column_int64(stmt, 0),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                asrText: String(cString: sqlite3_column_text(stmt, 2)),
                formattedText: String(cString: sqlite3_column_text(stmt, 3)),
                appBundle: sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "",
                language: sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "",
                durationSeconds: sqlite3_column_double(stmt, 6),
                latencySeconds: sqlite3_column_double(stmt, 7)))
        }
        return result
    }
}
