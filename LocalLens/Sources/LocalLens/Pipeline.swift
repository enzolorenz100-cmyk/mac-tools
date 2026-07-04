import AppKit
import Foundation
import Vision

/// Wandelt ein Bild lokal in „AI-Sprache" um: OCR (Apple Vision) + optionale Beschreibung
/// (lokales Vision-Modell via Ollama). Komplett offline & gratis — spart Tokens bei der Ziel-AI,
/// ohne die Kosten nur zu verlagern.
enum Pipeline {

    struct Result {
        var ocr: String
        var description: String     // leer, wenn kein Vision-Modell verfügbar
        var promptReady: String     // fertiger Text zum Kopieren/Pasten
        var markdown: String        // für den Vault
        var imageTokens: Int
        var textTokens: Int
        var width: Int
        var height: Int
    }

    /// Verarbeitet ein Bild. `describe` steuert, ob zusätzlich das lokale VLM läuft.
    static func process(imageURL: URL, sourceApp: String, describe: Bool,
                        settings: Settings) -> Result? {
        guard let img = NSImage(contentsOf: imageURL),
              let tiff = img.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cg = bitmap.cgImage else { return nil }
        return process(cgImage: cg, sourceApp: sourceApp, describe: describe,
                       originalURL: imageURL, settings: settings)
    }

    static func process(cgImage cg: CGImage, sourceApp: String, describe: Bool,
                        originalURL: URL?, settings: Settings) -> Result {
        let w = cg.width, h = cg.height
        let ocr = runOCR(cg)
        var description = ""
        if describe {
            description = OllamaDescriber.describe(cgImage: cg, settings: settings) ?? ""
        }

        // Fertiger Prompt-Text zum Pasten
        var parts: [String] = []
        parts.append("[Bild-Inhalt als Text — von LocalLens lokal extrahiert]")
        if !sourceApp.isEmpty, sourceApp != "unbekannt" { parts.append("App/Kontext: \(sourceApp)") }
        if !description.isEmpty { parts.append("\nBeschreibung:\n\(description)") }
        parts.append("\nSichtbarer Text:\n\(ocr.isEmpty ? "(kein Text erkannt)" : ocr)")
        let promptReady = parts.joined(separator: "\n")

        // Markdown für den Vault
        let iso = Self.isoFormatter.string(from: Date())
        let title = ocr.split(separator: "\n").first.map { String($0.prefix(60)) } ?? "Bild \(iso)"
        let markdown = """
        ---
        quelle: bild
        app: \(sourceApp.isEmpty ? "unbekannt" : sourceApp)
        erfasst: \(iso)
        bildgroesse: \(w)x\(h)
        tags: []
        ---
        # \(title)

        ## Beschreibung
        \(description.isEmpty ? "_(keine — Vision-Modell nicht aktiv)_" : description)

        ## Sichtbarer Text (OCR)
        \(ocr.isEmpty ? "_(kein Text erkannt)_" : ocr)
        """

        let imageTokens = (w * h) / 750
        let textTokens = max(1, promptReady.count / 4)
        return Result(ocr: ocr, description: description, promptReady: promptReady,
                      markdown: markdown, imageTokens: imageTokens, textTokens: textTokens,
                      width: w, height: h)
    }

    // MARK: - OCR (Apple Vision, lokal)

    static func runOCR(_ cg: CGImage) -> String {
        var lines: [String] = []
        let req = VNRecognizeTextRequest { request, _ in
            for obs in (request.results as? [VNRecognizedTextObservation]) ?? [] {
                if let top = obs.topCandidates(1).first { lines.append(top.string) }
            }
        }
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["de-DE", "en-US"]
        req.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([req])
        return lines.joined(separator: "\n")
    }

    static func saveToVault(_ r: Result, originalCG: CGImage?) -> URL? {
        let vault = Settings.appSupportDir.appendingPathComponent("vault")
        try? FileManager.default.createDirectory(at: vault.appendingPathComponent("assets"),
                                                 withIntermediateDirectories: true)
        let stamp = Self.stampFormatter.string(from: Date())
        if let cg = originalCG {
            let rep = NSBitmapImageRep(cgImage: cg)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: vault.appendingPathComponent("assets/\(stamp).png"))
            }
        }
        let url = vault.appendingPathComponent("\(stamp).md")
        try? r.markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static let isoFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm"; return f
    }()
    static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"; return f
    }()
}
