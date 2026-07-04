import Foundation

/// Verwaltet den whisper-server-Kindprozess (hält das Modell warm) und transkribiert WAVs per HTTP.
final class WhisperClient {
    private let settings: Settings
    private var process: Process?
    private var restartCount = 0
    private var stopped = false

    var baseURL: URL { URL(string: "http://127.0.0.1:\(settings.whisperPort)")! }

    init(settings: Settings) {
        self.settings = settings
    }

    // MARK: - Server-Lifecycle

    /// Startet den Server, falls auf dem Port nicht schon einer läuft. Blockiert bis das Modell geladen ist.
    func ensureRunning(timeout: TimeInterval = 60) throws {
        if healthCheck() {
            Log.info("whisper-server läuft bereits auf Port \(settings.whisperPort)")
            return
        }
        try spawn()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if healthCheck() {
                Log.info("whisper-server bereit (Modell geladen)")
                return
            }
            if let p = process, !p.isRunning {
                throw NSError(domain: "LocalFlow", code: 10, userInfo: [
                    NSLocalizedDescriptionKey: "whisper-server sofort beendet (Exit \(p.terminationStatus)) — Modellpfad prüfen: \(settings.modelPath)"])
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw NSError(domain: "LocalFlow", code: 11,
                      userInfo: [NSLocalizedDescriptionKey: "whisper-server nicht bereit nach \(Int(timeout)) s"])
    }

    private func spawn() throws {
        guard FileManager.default.isExecutableFile(atPath: settings.whisperServerPath) else {
            throw NSError(domain: "LocalFlow", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "whisper-server nicht gefunden: \(settings.whisperServerPath) — `brew install whisper-cpp`"])
        }
        guard FileManager.default.fileExists(atPath: settings.modelPath) else {
            throw NSError(domain: "LocalFlow", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "Whisper-Modell fehlt: \(settings.modelPath)"])
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: settings.whisperServerPath)
        p.arguments = [
            "-m", settings.modelPath,
            "--host", "127.0.0.1",
            "--port", String(settings.whisperPort),
            "-t", String(settings.whisperThreads),
            "--flash-attn",
        ]
        let logURL = Settings.appSupportDir.appendingPathComponent("whisper-server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: logURL) {
            p.standardOutput = h
            p.standardError = h
        }
        p.terminationHandler = { [weak self] proc in
            guard let self, !self.stopped else { return }
            Log.error("whisper-server unerwartet beendet (Exit \(proc.terminationStatus))")
            if self.restartCount < 3 {
                self.restartCount += 1
                Log.info("Neustart-Versuch \(self.restartCount)/3 …")
                try? self.ensureRunning()
            }
        }
        try p.run()
        process = p
        Log.info("whisper-server gestartet (PID \(p.processIdentifier))")
    }

    func shutdown() {
        stopped = true
        process?.terminate()
        process = nil
    }

    func healthCheck() -> Bool {
        var ok = false
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: baseURL, timeoutInterval: 1.5)
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            ok = (resp as? HTTPURLResponse) != nil
            sem.signal()
        }.resume()
        sem.wait()
        return ok
    }

    // MARK: - Transkription

    struct Result {
        var text: String
        var detectedLanguage: String   // z. B. "de"/"en" — steuert sprachspezifische Formatierung
        var latency: TimeInterval
        var confidence: Double         // mittlere Wort-Wahrscheinlichkeit (niedrig = wahrscheinlich Halluzination)
    }

    /// Synchron (wird vom Dictation-Controller auf einer Hintergrund-Queue aufgerufen).
    func transcribe(wavURL: URL, language: String, initialPrompt: String?) throws -> Result {
        let boundary = "LocalFlow-\(UUID().uuidString)"
        var req = URLRequest(url: baseURL.appendingPathComponent("inference"), timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("response_format", "verbose_json")   // enthält zusätzlich die erkannte Sprache
        field("language", language)
        field("temperature", "0.0")
        if let initialPrompt, !initialPrompt.isEmpty {
            field("prompt", initialPrompt)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: wavURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let started = Date()
        var resultData: Data?
        var resultError: Error?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, err in
            resultData = data; resultError = err; sem.signal()
        }.resume()
        sem.wait()

        if let resultError { throw resultError }
        guard let data = resultData,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            let raw = resultData.flatMap { String(data: $0, encoding: .utf8) } ?? "<leer>"
            throw NSError(domain: "LocalFlow", code: 14,
                          userInfo: [NSLocalizedDescriptionKey: "Unerwartete whisper-server-Antwort: \(raw.prefix(300))"])
        }
        let latency = Date().timeIntervalSince(started)
        let detected = Self.normalizeLanguage((json["language"] as? String) ?? language)
        let confidence = Self.meanWordConfidence(json)
        return Result(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                      detectedLanguage: detected, latency: latency, confidence: confidence)
    }

    /// Mittlere Wahrscheinlichkeit der Inhaltswörter aus verbose_json.
    /// Halluzinationen auf Stille haben typisch sehr niedrige Werte (~0,1), echte Sprache > 0,5.
    private static func meanWordConfidence(_ json: [String: Any]) -> Double {
        guard let segments = json["segments"] as? [[String: Any]] else { return 1.0 }
        var probs: [Double] = []
        for seg in segments {
            guard let words = seg["words"] as? [[String: Any]] else { continue }
            for w in words {
                let word = (w["word"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                // reine Interpunktion überspringen
                guard word.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                if let p = w["probability"] as? Double { probs.append(p) }
            }
        }
        guard !probs.isEmpty else { return 1.0 }
        return probs.reduce(0, +) / Double(probs.count)
    }

    /// whisper-server liefert volle Sprachnamen ("german") statt ISO-Codes.
    private static func normalizeLanguage(_ lang: String) -> String {
        switch lang.lowercased() {
        case "german": return "de"
        case "english": return "en"
        case "french": return "fr"
        case "spanish": return "es"
        case "italian": return "it"
        default: return lang.count == 2 ? lang.lowercased() : lang
        }
    }
}
