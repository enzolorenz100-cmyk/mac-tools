import Foundation

struct DictionaryEntry: Codable, Equatable {
    var phrase: String            // korrekte Schreibweise, z. B. "Wispr Flow"
    var misspellings: [String]    // was Whisper stattdessen liefert, z. B. ["Wispflow", "Wisper Flow"]
}

struct Snippet: Codable, Equatable {
    var trigger: String           // gesprochene Phrase, z. B. "meine Adresse"
    var expansion: String
}

struct Settings: Codable {
    var language: String = "auto"            // "auto" | "de" | "en"
    // "fn" (wie Wispr Flow) | "rightOption" | "rightCommand".
    // Für den Parallelbetrieb neben Wispr Flow rightOption nutzen — beide auf Fn kollidieren!
    var hotkey: String = "fn"
    // Zusätzlicher Trigger Ctrl+Space (für Tastaturen ohne Fn-Taste); läuft parallel zum Haupt-Hotkey.
    var enableControlSpace: Bool = true
    var holdThreshold: Double = 0.5          // Sekunden: länger = Push-to-Talk, kürzer = Freihand-Toggle
    var maxRecordingSeconds: Double = 1200   // 20 min wie Wispr
    var whisperPort: Int = 8873
    var whisperServerPath: String = "/opt/homebrew/bin/whisper-server"
    var modelPath: String = NSString(string: "~/Desktop/LocalFlow/models/ggml-large-v3-turbo.bin").expandingTildeInPath
    var whisperThreads: Int = 4
    var soundsEnabled: Bool = true
    var fillerRemoval: Bool = true
    var showIdleBar: Bool = true             // Wispr-artige Mini-Bar dauerhaft anzeigen
    var appendSpaceAfterSentence: Bool = true // Leerzeichen nach Satzende anhängen (Folge-Diktate kleben sonst)
    var minVoicedSeconds: Double = 0.25      // so viel echte Sprech-Energie muss die Aufnahme haben
    var minConfidence: Double = 0.35         // niedrigere Wort-Konfidenz → als Halluzination verwerfen
    var messagingBundleIDs: [String] = [      // Apps ohne Satz-Endpunkt (Wisprs Messaging-Stil)
        "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "org.telegram.desktop", "ru.keepcoder.Telegram",
    ]
    var dictionary: [DictionaryEntry] = [
        DictionaryEntry(phrase: "Wispr Flow", misspellings: ["Wispflow", "Wisperflow", "Wisper Flow", "Whisper Flow"]),
        DictionaryEntry(phrase: "304supply", misspellings: ["304 Supply", "304 supply", "3 0 4 supply"]),
        DictionaryEntry(phrase: "Claude Code", misspellings: ["Cloud Code", "Clod Code"]),
        DictionaryEntry(phrase: "Vercel", misspellings: ["Wassel", "Vassel", "Wörsel", "Versel", "Werzel", "Fersel"]),
        DictionaryEntry(phrase: "Upstash", misspellings: ["Upstesh", "Abstash", "Up Stash", "Upsteach"]),
    ]
    var snippets: [Snippet] = []
    var launchAtLogin: Bool = false
    // Debug: erlaubt Pipeline-Tests via Distributed Notification (nur für Entwicklung aktivieren)
    var debugHooksEnabled: Bool = false

    static var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalFlow", isDirectory: true)
    }
    static var fileURL: URL { appSupportDir.appendingPathComponent("settings.json") }

    static func load() -> Settings {
        // Robust gegen neue Felder: Nutzer-JSON über die Defaults mergen statt strikt dekodieren —
        // sonst würde EIN fehlender neuer Key die komplette Nutzer-Konfiguration verwerfen.
        guard let userData = try? Data(contentsOf: fileURL),
              let userDict = (try? JSONSerialization.jsonObject(with: userData)) as? [String: Any] else {
            let s = Settings()
            s.save()
            return s
        }
        do {
            let defaultData = try JSONEncoder().encode(Settings())
            var merged = (try JSONSerialization.jsonObject(with: defaultData)) as! [String: Any]
            for (k, v) in userDict { merged[k] = v }
            let s = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: merged))
            s.save()   // Datei um neue Default-Keys ergänzen
            return s
        } catch {
            Log.error("Settings unlesbar (\(error)) — nutze Defaults, Datei bleibt unangetastet")
            return Settings()
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: Self.appSupportDir, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(self).write(to: Self.fileURL, options: .atomic)
        } catch {
            Log.error("Settings speichern fehlgeschlagen: \(error)")
        }
    }
}

enum Log {
    static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()
    static var logFileURL: URL {
        Settings.appSupportDir.appendingPathComponent("localflow.log")
    }
    private static let maxLogBytes = 1_000_000   // Log bei ~1 MB kappen (kein unbegrenztes Wachstum)
    private static func write(_ level: String, _ msg: String) {
        let line = "\(dateFmt.string(from: Date())) [\(level)] \(msg)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        rotateIfNeeded()
        if let h = try? FileHandle(forWritingTo: logFileURL) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? FileManager.default.createDirectory(at: Settings.appSupportDir, withIntermediateDirectories: true)
            try? line.data(using: .utf8)?.write(to: logFileURL)
        }
    }
    private static func rotateIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: logFileURL.path)[.size] as? Int,
              size > maxLogBytes else { return }
        // Letzte Hälfte behalten, Rest verwerfen.
        if let data = try? Data(contentsOf: logFileURL) {
            let tail = data.suffix(maxLogBytes / 2)
            try? tail.write(to: logFileURL)
        }
    }
    static func info(_ msg: String)  { write("INFO", msg) }
    static func error(_ msg: String) { write("ERROR", msg) }
}
