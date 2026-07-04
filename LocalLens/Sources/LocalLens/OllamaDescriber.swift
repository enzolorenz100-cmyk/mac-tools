import AppKit
import Foundation

/// Lokale Bild-Beschreibung über ein Vision-Modell in Ollama (läuft offline auf dem Mac, gratis).
/// Fällt still auf "" zurück, wenn Ollama nicht läuft oder kein Modell da ist — dann bleibt es bei OCR.
enum OllamaDescriber {

    static func isAvailable(settings: Settings) -> Bool {
        var ok = false
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(settings.ollamaPort)/api/tags")!,
                             timeoutInterval: 1.0)
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            ok = (resp as? HTTPURLResponse)?.statusCode == 200; sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 1.5)
        return ok
    }

    static func describe(cgImage cg: CGImage, settings: Settings) -> String? {
        // Bild auf sinnvolle Größe verkleinern (schneller, reicht fürs Verständnis)
        guard let b64 = base64PNG(cg, maxDimension: 1400) else { return nil }
        let body: [String: Any] = [
            "model": settings.visionModel,
            "prompt": settings.describePrompt,
            "images": [b64],
            "stream": false,
            "keep_alive": "30m",            // Modell warm halten → keine Ladezeit bei Folge-Bildern
            "options": ["temperature": 0.1],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(settings.ollamaPort)/api/generate")!,
                             timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        var result: String?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resp = json["response"] as? String else { return }
            result = resp.trimmingCharacters(in: .whitespacesAndNewlines)
        }.resume()
        sem.wait()
        return (result?.isEmpty == false) ? result : nil
    }

    private static func base64PNG(_ cg: CGImage, maxDimension: Int) -> String? {
        let w = cg.width, h = cg.height
        let scale = min(1.0, Double(maxDimension) / Double(max(w, h)))
        let nw = Int(Double(w) * scale), nh = Int(Double(h) * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: nw, pixelsHigh: nh,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep, let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])?.base64EncodedString()
    }
}
