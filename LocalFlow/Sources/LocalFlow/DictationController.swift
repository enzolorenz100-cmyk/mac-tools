import AppKit
import Foundation

/// Zentraler Zustandsautomat: Hotkey → Aufnahme → Transkription → Formatierung → Einfügen → Verlauf.
final class DictationController: HotkeyDelegate {
    enum State {
        case idle
        case recording(handsFree: Bool)
        case transcribing
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((State) -> Void)?

    private let settings: Settings
    private let recorder = AudioRecorder()
    private let whisper: WhisperClient
    private let formatter: TextFormatter
    private let history: HistoryStore
    private let overlay = OverlayPanel()
    private let workQueue = DispatchQueue(label: "localflow.transcribe", qos: .userInitiated)

    private var targetBundleID: String?
    private var recordingStartedAt: Date?
    private var maxDurationTimer: Timer?
    private(set) var lastTranscript: String?

    var isCapturing: Bool {
        if case .recording = state { return true }
        return false
    }

    var isHandsFree: Bool {
        if case .recording(handsFree: true) = state { return true }
        return false
    }

    init(settings: Settings, whisper: WhisperClient, history: HistoryStore) {
        self.settings = settings
        self.whisper = whisper
        self.history = history
        self.formatter = TextFormatter(settings: settings)
        recorder.onLevel = { [weak self] level in self?.overlay.updateLevel(level) }
        overlay.showIdleBar = settings.showIdleBar
        overlay.onClick = { [weak self] in self?.barClicked() }
    }

    /// Idle-Bar beim App-Start anzeigen.
    func showBar() {
        overlay.show(mode: .idle)
    }

    /// Klick auf die Flow Bar: idle → Freihand-Diktat starten, Aufnahme → stoppen.
    func barClicked() {
        switch state {
        case .idle:
            startRecording()
            if case .recording = state {
                state = .recording(handsFree: true)
                overlay.show(mode: .handsFree)
            }
        case .recording:
            finishAndTranscribe()
        case .transcribing:
            break
        }
    }

    // MARK: - HotkeyDelegate

    func hotkeyPressed() {
        switch state {
        case .idle:
            startRecording()
        case .recording(handsFree: true):
            // Im Freihand-Modus stoppt der nächste Fn-Druck die Aufnahme.
            finishAndTranscribe()
        default:
            break
        }
    }

    func hotkeyReleased(heldFor: TimeInterval) {
        guard case .recording(handsFree: false) = state else { return }
        if heldFor >= settings.holdThreshold {
            finishAndTranscribe()          // klassisches Push-to-Talk
        } else {
            state = .recording(handsFree: true)   // Kurz-Tipp → Freihand-Modus
            overlay.show(mode: .handsFree)
            playSound("Morse")
            Log.info("Freihand-Modus aktiv (Fn erneut drücken zum Stoppen)")
        }
    }

    func handsFreeRequested() {
        guard case .recording(handsFree: false) = state else { return }
        state = .recording(handsFree: true)
        overlay.show(mode: .handsFree)
        playSound("Morse")
    }

    /// Modifier+Space im Ruhezustand → direkt Freihand-Aufnahme starten (kein Halten nötig).
    func startHandsFree() {
        guard case .idle = state else { return }
        startRecording()
        guard case .recording = state else { return }   // nur wenn Start klappte
        state = .recording(handsFree: true)
        overlay.show(mode: .handsFree)
        playSound("Morse")
        Log.info("Freihand-Aufnahme gestartet (Space beendet)")
    }

    /// Space allein während Freihand → beenden & transkribieren.
    func stopDictation() {
        guard isCapturing else { return }
        finishAndTranscribe()
    }

    func cancelRequested() {
        guard isCapturing else { return }
        recorder.cancel()
        stopMaxDurationTimer()
        overlay.show(mode: .idle)
        state = .idle
        playSound("Basso")
        Log.info("Diktat abgebrochen")
    }

    func pasteLastRequested() {
        guard let text = lastTranscript else { return }
        TextInserter.insert(text)
    }

    /// Einfügen eines beliebigen Textes aus dem Dashboard in die zuletzt aktive App.
    func insertExternally(_ text: String) {
        TextInserter.insert(text)
    }

    // MARK: - Ablauf

    private func startRecording() {
        targetBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        do {
            try recorder.start()
        } catch {
            Log.error("Aufnahme-Start fehlgeschlagen: \(error.localizedDescription)")
            playSound("Basso")
            return
        }
        recordingStartedAt = Date()
        state = .recording(handsFree: false)
        overlay.show(mode: .recording)
        playSound("Tink")
        startMaxDurationTimer()
    }

    private func finishAndTranscribe() {
        stopMaxDurationTimer()
        let samples = recorder.stop()
        let duration = Double(samples.count) / 16000.0
        overlay.show(mode: .transcribing)

        // Zu kurze Aufnahmen (versehentlicher Tipp) verwerfen.
        guard duration >= 0.3 else {
            overlay.show(mode: .idle)
            state = .idle
            return
        }
        // Stille verwerfen: ohne genug echte Sprech-Energie NICHT transkribieren
        // (Whisper halluziniert sonst auf Stille/Rauschen "Amen", "Untertitel…" etc.).
        let voiced = Self.voicedDuration(samples)
        guard voiced >= settings.minVoicedSeconds else {
            Log.info("Keine Sprache erkannt (nur \(String(format: "%.2f", voiced))s Sprech-Energie) — verworfen")
            overlay.show(mode: .idle)
            state = .idle
            playSound("Basso")
            return
        }
        state = .transcribing
        let bundleID = targetBundleID
        let language = settings.language
        let prompt = formatter.initialPrompt()

        workQueue.async { [weak self] in
            guard let self else { return }
            defer {
                DispatchQueue.main.async {
                    self.overlay.show(mode: .idle)
                    self.state = .idle
                }
            }
            do {
                let wavURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("localflow-\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: wavURL) }
                try AudioRecorder.writeWAV(samples: samples, to: wavURL)

                let result = try self.whisper.transcribe(
                    wavURL: wavURL, language: language, initialPrompt: prompt)

                // Zweites Signal: sehr niedrige Wort-Konfidenz = wahrscheinlich Halluzination.
                guard result.confidence >= self.settings.minConfidence else {
                    Log.info("Niedrige Konfidenz (\(String(format: "%.2f", result.confidence))) — verworfen: \(result.text.prefix(50))")
                    DispatchQueue.main.async { self.playSound("Basso") }
                    return
                }

                let formatted = self.formatter.format(result.text, targetBundleID: bundleID,
                                                      language: result.detectedLanguage)
                Log.info("Transkribiert (\(result.detectedLanguage), conf \(String(format: "%.2f", result.confidence)), \(String(format: "%.2f", result.latency)) s): \(formatted.prefix(80))…")

                guard !formatted.isEmpty else {
                    DispatchQueue.main.async { self.playSound("Basso") }
                    return
                }
                DispatchQueue.main.async {
                    TextInserter.insert(self.withTrailingSpace(formatted))
                    self.lastTranscript = formatted
                    self.playSound("Pop")
                }
                self.history.add(asr: result.text, formatted: formatted,
                                 appBundle: bundleID ?? "", language: result.detectedLanguage,
                                 duration: duration, latency: result.latency)
            } catch {
                Log.error("Transkription fehlgeschlagen: \(error.localizedDescription)")
                DispatchQueue.main.async { self.playSound("Basso") }
            }
        }
    }

    /// Debug-Pfad: WAV-Datei durch die komplette Pipeline schicken (Transkription → Formatierung →
    /// Einfügen in die aktive App). Ermöglicht End-to-End-Tests ohne Mikrofon/Hotkey.
    func processTestFile(_ path: String) {
        guard case .idle = state else { return }
        state = .transcribing
        overlay.show(mode: .transcribing)
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let language = settings.language
        let prompt = formatter.initialPrompt()

        workQueue.async { [weak self] in
            guard let self else { return }
            defer {
                DispatchQueue.main.async {
                    self.overlay.show(mode: .idle)
                    self.state = .idle
                }
            }
            do {
                let result = try self.whisper.transcribe(
                    wavURL: URL(fileURLWithPath: path), language: language, initialPrompt: prompt)
                let formatted = self.formatter.format(result.text, targetBundleID: bundleID,
                                                      language: result.detectedLanguage)
                Log.info("TEST-Diktat (\(result.detectedLanguage), \(String(format: "%.2f", result.latency)) s): \(formatted)")
                guard !formatted.isEmpty else { return }
                DispatchQueue.main.async {
                    TextInserter.insert(self.withTrailingSpace(formatted))
                    self.lastTranscript = formatted
                }
            } catch {
                Log.error("TEST-Diktat fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    private func startMaxDurationTimer() {
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: settings.maxRecordingSeconds, repeats: false) { [weak self] _ in
            Log.info("Maximale Aufnahmedauer erreicht — stoppe automatisch")
            self?.finishAndTranscribe()
        }
    }

    private func stopMaxDurationTimer() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
    }

    /// Dauer echter Sprech-Energie in Sekunden (30-ms-Frames mit RMS > 0,02).
    /// Trennt zuverlässig Sprache (mehrere Sekunden) von Stille/Rauschen (~0 s).
    static func voicedDuration(_ samples: [Float]) -> Double {
        let frame = 480                    // 30 ms bei 16 kHz
        let threshold: Float = 0.02
        var voiced = 0, count = 0
        var i = 0
        while i + frame <= samples.count {
            var sum: Float = 0
            for j in i..<(i + frame) { sum += samples[j] * samples[j] }
            if (sum / Float(frame)).squareRoot() > threshold { voiced += 1 }
            count += 1
            i += frame
        }
        return Double(voiced) * 0.03
    }

    /// Folge-Diktate kleben sonst aneinander ("Test.Hallo") — nach Satzende ein Leerzeichen anhängen.
    private func withTrailingSpace(_ text: String) -> String {
        guard settings.appendSpaceAfterSentence, let last = text.last,
              ".!?…".contains(last) else { return text }
        return text + " "
    }

    private func playSound(_ name: String) {
        guard settings.soundsEnabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
