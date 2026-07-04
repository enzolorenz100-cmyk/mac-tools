import Foundation

struct Settings: Codable {
    var ollamaPort: Int = 11434
    var visionModel: String = "qwen2.5vl:3b"     // lokales Vision-Modell in Ollama (SOTA für UI/Dokumente)
    // qwen2.5vl versteht komplexe Anweisungen gut. Die exakten Texte kommen aus der OCR,
    // daher hier Fokus auf Kontext/Layout/visuelle Elemente statt Text-Transkription.
    var describePrompt: String = "Describe this screen or image for an AI that cannot see it. State what kind of app or screen it is, the overall layout, and any charts, images or visual elements. Be concise (2-4 sentences). Do not transcribe long text — that is captured separately."
    var saveToVault: Bool = true                 // Markdown zusätzlich im Vault speichern
    var autoCopy: Bool = true                    // Ergebnis automatisch in die Zwischenablage
    var captureMode: String = "windowAuto"       // "windowAuto" (aktives Fenster) | "region" | "screen"
    var whisperCli: String = "/opt/homebrew/bin/whisper-cli"
    var whisperModel: String = NSString(string: "~/Desktop/LocalFlow/models/ggml-large-v3-turbo.bin").expandingTildeInPath
    var ffmpeg: String = "/opt/homebrew/bin/ffmpeg"
    var videoMaxKeyframes: Int = 8               // begrenzt die Analyse-Zeit bei Videos

    static var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLens", isDirectory: true)
    }
    static var fileURL: URL { appSupportDir.appendingPathComponent("settings.json") }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL),
              let userDict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let s = Settings(); s.save(); return s
        }
        do {
            let def = try JSONEncoder().encode(Settings())
            var merged = (try JSONSerialization.jsonObject(with: def)) as! [String: Any]
            for (k, v) in userDict { merged[k] = v }
            let s = try JSONDecoder().decode(Settings.self,
                        from: JSONSerialization.data(withJSONObject: merged))
            s.save(); return s
        } catch { return Settings() }
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.appSupportDir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Self.fileURL)
    }
}

enum Log {
    static var logURL: URL { Settings.appSupportDir.appendingPathComponent("locallens.log") }
    static func info(_ m: String) {
        let line = "\(Date()) \(m)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using:.utf8)!); try? h.close() }
        else { try? FileManager.default.createDirectory(at: Settings.appSupportDir, withIntermediateDirectories: true); try? line.data(using:.utf8)?.write(to: logURL) }
    }
}
