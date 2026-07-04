import AppKit
import Foundation

/// Wandelt ein Video LOKAL in Text: Audio-Transkript (whisper.cpp) + Keyframe-Beschreibungen
/// (ffmpeg Szenenwechsel → OCR + Vision-Modell). Riesige Token-Ersparnis ggü. Frames-an-AI.
enum VideoPipeline {

    struct Result {
        var promptReady: String
        var markdown: String
        var savingsNote: String
    }

    static func process(videoURL: URL, settings: Settings, progress: @escaping (String) -> Void) -> Result {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ll-video-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // 1) Audio → 16 kHz mono WAV → whisper.cpp
        progress("Transkribiere Audio …")
        let transcript = transcribeAudio(videoURL, work: work, settings: settings)

        // 2) Keyframes bei Szenenwechseln extrahieren
        progress("Extrahiere Keyframes …")
        let frames = extractKeyframes(videoURL, work: work, settings: settings)

        // 3) Jeden Keyframe: OCR (immer) + Beschreibung (nur erste paar, wegen Zeit)
        let describeAvailable = OllamaDescriber.isAvailable(settings: settings)
        var frameBlocks: [String] = []
        for (i, f) in frames.enumerated() {
            progress("Analysiere Keyframe \(i + 1)/\(frames.count) …")
            guard let img = NSImage(contentsOf: f.url), let tiff = img.tiffRepresentation,
                  let bm = NSBitmapImageRep(data: tiff), let cg = bm.cgImage else { continue }
            let ocr = Pipeline.runOCR(cg)
            var desc = ""
            if describeAvailable && i < 4 {   // nur die ersten 4 beschreiben (Zeit)
                desc = OllamaDescriber.describe(cgImage: cg, settings: settings) ?? ""
            }
            var block = "### \(f.timestamp)\n"
            if !desc.isEmpty { block += "\(desc)\n" }
            if !ocr.isEmpty { block += "Text im Bild: \(ocr.replacingOccurrences(of: "\n", with: " "))\n" }
            frameBlocks.append(block)
        }

        // 4) Zusammenbauen
        let iso = Pipeline.isoFormatter.string(from: Date())
        var md = """
        ---
        quelle: video
        datei: \(videoURL.lastPathComponent)
        erfasst: \(iso)
        keyframes: \(frames.count)
        tags: []
        ---
        # Video: \(videoURL.lastPathComponent)

        ## Transkript (gesprochenes Audio)
        \(transcript.isEmpty ? "_(kein Audio erkannt)_" : transcript)

        ## Verlauf (Keyframes)
        \(frameBlocks.isEmpty ? "_(keine Keyframes)_" : frameBlocks.joined(separator: "\n"))
        """

        let prompt = """
        [Video-Inhalt als Text — von LocalLens lokal extrahiert]
        Datei: \(videoURL.lastPathComponent)

        Gesprochenes (Transkript):
        \(transcript.isEmpty ? "(kein Audio)" : transcript)

        Visueller Verlauf:
        \(frameBlocks.joined(separator: "\n"))
        """

        let textTokens = max(1, prompt.count / 4)
        let note = "\(frames.count) Keyframes + Transkript → ~\(textTokens) Tokens (statt zehntausender für alle Frames)"
        return Result(promptReady: prompt, markdown: md, savingsNote: note)
    }

    // MARK: Bausteine

    private static func transcribeAudio(_ video: URL, work: URL, settings: Settings) -> String {
        guard FileManager.default.isExecutableFile(atPath: settings.ffmpeg),
              FileManager.default.isExecutableFile(atPath: settings.whisperCli),
              FileManager.default.fileExists(atPath: settings.whisperModel) else { return "" }
        let wav = work.appendingPathComponent("audio.wav")
        run(settings.ffmpeg, ["-y", "-i", video.path, "-ac", "1", "-ar", "16000", "-vn", wav.path])
        guard FileManager.default.fileExists(atPath: wav.path) else { return "" }
        // whisper-cli schreibt Text nach stdout mit --no-timestamps
        let out = run(settings.whisperCli, ["-m", settings.whisperModel, "-f", wav.path,
                                            "-l", "auto", "--no-timestamps"]) ?? ""
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Frame { var url: URL; var timestamp: String }

    private static func extractKeyframes(_ video: URL, work: URL, settings: Settings) -> [Frame] {
        // Szenenwechsel-Erkennung; begrenzt auf videoMaxKeyframes
        let pattern = work.appendingPathComponent("kf-%03d.png").path
        run(settings.ffmpeg, ["-y", "-i", video.path,
                              "-vf", "select='gt(scene,0.25)',showinfo",
                              "-vsync", "vfr", "-frames:v", String(settings.videoMaxKeyframes), pattern])
        var frames = collectFrames(work)
        if frames.isEmpty {
            // Fallback: gleichmäßig 1 Frame alle paar Sekunden
            run(settings.ffmpeg, ["-y", "-i", video.path, "-vf", "fps=1/5",
                                  "-frames:v", String(settings.videoMaxKeyframes), pattern])
            frames = collectFrames(work)
        }
        return frames
    }

    private static func collectFrames(_ work: URL) -> [Frame] {
        let files = (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("kf-") && $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .enumerated().map { Frame(url: $0.element, timestamp: "Szene \($0.offset + 1)") }
    }

    static func saveToVault(_ r: Result) {
        let vault = Settings.appSupportDir.appendingPathComponent("vault")
        try? FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let stamp = Pipeline.stampFormatter.string(from: Date())
        try? r.markdown.write(to: vault.appendingPathComponent("video-\(stamp).md"), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
