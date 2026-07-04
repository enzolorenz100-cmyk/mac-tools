import AVFoundation
import Foundation

/// Nimmt vom Standard-Eingabegerät auf und liefert 16 kHz mono Float32-Samples.
/// Wichtig: Der Tap MUSS im Hardware-Format installiert werden (16 kHz direkt → Exception -10868);
/// konvertiert wird pro Buffer mit AVAudioConverter.
final class AudioRecorder {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false
    /// Höchste Amplitude der gesamten Aufnahme — für die Stille-Erkennung.
    private(set) var peakAmplitude: Float = 0

    /// Wird bei jedem Buffer mit dem aktuellen RMS-Pegel (0...1) aufgerufen (für die Overlay-Anzeige).
    var onLevel: ((Float) -> Void)?

    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        default: completion(false)
        }
    }

    func start() throws {
        guard !isRecording else { return }
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        peakAmplitude = 0

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw NSError(domain: "LocalFlow", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Kein gültiges Aufnahmeformat (Mikrofon vorhanden? Berechtigung erteilt?)"])
        }
        guard let converter = AVAudioConverter(from: hwFormat, to: Self.targetFormat) else {
            throw NSError(domain: "LocalFlow", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "AVAudioConverter konnte nicht erstellt werden"])
        }
        self.converter = converter

        // Kleiner Buffer (1024 ≈ 21 ms) → ~45 Pegel-Updates/s, damit die Waveform
        // wirklich auf die Stimme reagiert statt nur durchzulaufen.
        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, hwFormat: hwFormat)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        isRecording = true
        Log.info("Aufnahme gestartet (HW: \(Int(hwFormat.sampleRate)) Hz, \(hwFormat.channelCount) Kanäle)")
    }

    /// Stoppt und liefert die aufgenommenen 16-kHz-Samples.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        isRecording = false
        lock.lock(); let result = samples; samples.removeAll(); lock.unlock()
        Log.info("Aufnahme gestoppt: \(result.count) Samples (\(String(format: "%.1f", Double(result.count) / 16000)) s)")
        return result
    }

    func cancel() { _ = stop() }

    private func process(buffer: AVAudioPCMBuffer, hwFormat: AVAudioFormat) {
        guard let converter else { return }
        let ratio = Self.targetFormat.sampleRate / hwFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var convErr: NSError?
        converter.convert(to: out, error: &convErr) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        if let convErr { Log.error("Konvertierung: \(convErr)"); return }
        guard let ch = out.floatChannelData, out.frameLength > 0 else { return }

        let n = Int(out.frameLength)
        let ptr = UnsafeBufferPointer(start: ch[0], count: n)
        lock.lock(); samples.append(contentsOf: ptr); lock.unlock()

        // Spitzenwert (max |x|) reagiert knackiger auf Sprache als RMS.
        var peak: Float = 0
        var sum: Float = 0
        for v in ptr {
            let a = abs(v)
            if a > peak { peak = a }
            sum += v * v
        }
        if peak > peakAmplitude { peakAmplitude = peak }
        let rms = (sum / Float(n)).squareRoot()
        // Rauschboden abziehen (leises Zimmerrauschen → ~0), dann kräftig verstärken und
        // Gamma-Kurve, damit die Waveform deutlich und lebendig auf die Stimme reagiert.
        let cleaned = max(0, peak - 0.01)
        let level = pow(min(1, cleaned * 7 + rms * 4), 0.6)
        onLevel?(level)
    }

    /// Schreibt Samples als 16-bit-PCM-WAV (kleiner als Float32, whisper-server-kompatibel).
    static func writeWAV(samples: [Float], to url: URL) throws {
        let sampleRate: UInt32 = 16000
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }

        let dataSize = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))                       // PCM, mono
        append(sampleRate); append(sampleRate * 2)                 // byte rate
        append(UInt16(2)); append(UInt16(16))                      // block align, bits
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        for s in samples {
            append(Int16(max(-1, min(1, s)) * 32767))
        }
        try data.write(to: url)
    }
}
