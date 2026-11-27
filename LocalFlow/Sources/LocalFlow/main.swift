import AppKit
import AVFoundation
import Foundation
import ServiceManagement

// MARK: - CLI-Modi (Testbarkeit ohne Mikrofon/Hotkey)

let args = CommandLine.arguments

if let idx = args.firstIndex(of: "--test-file"), idx + 1 < args.count {
    // Pipeline-Test: WAV → whisper-server → Formatter → (optional --paste) → stdout
    let wavPath = args[idx + 1]
    let doPaste = args.contains("--paste")
    let lang = args.firstIndex(of: "--lang").flatMap { i in i + 1 < args.count ? args[i + 1] : nil } ?? "auto"

    let settings = Settings.load()
    let whisper = WhisperClient(settings: settings)
    let formatter = TextFormatter(settings: settings)
    do {
        try whisper.ensureRunning()
        let result = try whisper.transcribe(
            wavURL: URL(fileURLWithPath: wavPath),
            language: lang,
            initialPrompt: formatter.initialPrompt())
        let formatted = formatter.format(result.text, targetBundleID: nil,
                                         language: result.detectedLanguage)
        let out: [String: Any] = [
            "asr": result.text,
            "formatted": formatted,
            "language": result.detectedLanguage,
            "confidence": (result.confidence * 100).rounded() / 100,
            "latency_s": (result.latency * 100).rounded() / 100,
        ]
        let json = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        print(String(data: json, encoding: .utf8)!)
        if doPaste {
            // RunLoop pumpen statt Thread.sleep — TextInserter arbeitet mit asyncAfter
            // auf der Main-Queue, die sonst nie drankäme.
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))   // Zeit, den Fokus zu setzen
            TextInserter.insert(formatted)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))   // Paste + Clipboard-Restore
        }
        exit(0)
    } catch {
        FileHandle.standardError.write("FEHLER: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

if args.contains("--format-test") {
    // Formatter-Unit-Test: Zeilen von stdin → formatiert nach stdout.
    // Zeilenpräfixe steuern den Kontext: "en:" (Sprache), "msg:" (Messaging-App).
    let settings = Settings.load()
    let formatter = TextFormatter(settings: settings)
    while var line = readLine() {
        var lang = "de"
        var bundle: String? = nil
        if line.hasPrefix("en:") { lang = "en"; line = String(line.dropFirst(3)) }
        if line.hasPrefix("msg:") { bundle = settings.messagingBundleIDs.first; line = String(line.dropFirst(4)) }
        print(formatter.format(line, targetBundleID: bundle, language: lang))
    }
    exit(0)
}

if let idx = args.firstIndex(of: "--voiced"), idx + 1 < args.count {
    // Verifiziert den Live-Stille-Gate: liest WAV → Sprech-Dauer → würde verworfen?
    let url = URL(fileURLWithPath: args[idx + 1])
    guard let file = try? AVAudioFile(forReading: url),
          let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                     frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: buf)) != nil, let ch = buf.floatChannelData else {
        print("WAV nicht lesbar"); exit(1)
    }
    let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
    let voiced = DictationController.voicedDuration(samples)
    let settings = Settings.load()
    let gated = voiced < settings.minVoicedSeconds
    print(String(format: "voiced=%.2fs  Schwelle=%.2fs  → %@",
                 voiced, settings.minVoicedSeconds,
                 gated ? "VERWORFEN (Stille, keine Transkription)" : "wird transkribiert"))
    exit(0)
}

if let idx = args.firstIndex(of: "--autostart"), idx + 1 < args.count {
    let enable = args[idx + 1] == "on"
    let ok = AutoStart.set(enable)
    print("Autostart \(enable ? "aktiviert" : "deaktiviert"): \(ok ? "OK (\(AutoStart.statusText()))" : "FEHLGESCHLAGEN")")
    exit(ok ? 0 : 1)
}

if args.contains("--dashboard") {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("de.enzolorenz.localflow.open-dashboard"),
        object: nil, userInfo: nil, deliverImmediately: true)
    print("Dashboard-Öffnen an laufende App geschickt")
    exit(0)
}

if let idx = args.firstIndex(of: "--trigger-test"), idx + 1 < args.count {
    // Schickt ein Test-WAV an die LAUFENDE App (die die TCC-Berechtigungen hat).
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("de.enzolorenz.localflow.test-dictation"),
        object: args[idx + 1], userInfo: nil, deliverImmediately: true)
    print("Test-Diktat an laufende App geschickt: \(args[idx + 1])")
    exit(0)
}

if args.contains("--paste-test") {
    let (ok, details) = TextInserter.clipboardSelfTest()
    print("Clipboard-Selbsttest: \(ok ? "BESTANDEN" : "FEHLGESCHLAGEN") — \(details)")
    exit(ok ? 0 : 1)
}

if args.contains("--nachtschicht-stats") {
    // Gibt genau die Zahlen aus, die „Für die Nachtschicht teilen“ übergeben würde, plus Messdaten.
    // --no-cache: alles frisch lesen, Cache weder lesen noch schreiben.
    // --cache <pfad>: anderer Cache-Ort (Default: Application Support/LocalFlow/nachtschicht-cache.json).
    let cacheURL: URL? = args.contains("--no-cache") ? nil
        : args.firstIndex(of: "--cache").flatMap { i in i + 1 < args.count ? URL(fileURLWithPath: args[i + 1]) : nil }
            ?? AgenticHours.defaultCacheURL
    // --root <pfad>: anderer Transkript-Ordner (für Tests; Default ~/.claude/projects).
    let root = args.firstIndex(of: "--root").flatMap { i in i + 1 < args.count ? URL(fileURLWithPath: args[i + 1]) : nil }
        ?? AgenticHours.defaultRoot
    let agentic = AgenticHours.compute(root: root, cacheURL: cacheURL)
    let history = HistoryStore(readOnly: true)
    let snap = NachtschichtSnapshot.collect(history: history, agentic: agentic)
    let out: [String: Any] = [
        "geteilt": [
            "quelle": "localflow",
            "lf_woerter": snap.woerter,
            "lf_diktate": snap.diktate,
            "lf_minuten": snap.minuten,
            "agent_stunden": snap.agentStunden,
        ],
        "share_url": snap.shareURL(handle: "")?.absoluteString ?? "",
        "messung": [
            "agent_sekunden_exakt": (agentic.seconds * 10).rounded() / 10,
            "ordner_fehlt": agentic.folderMissing,
            "dateien_im_fenster": agentic.filesInWindow,
            "dateien_gelesen": agentic.filesRead,
            "bytes_gelesen": agentic.bytesRead,
            "zeitstempel_gesehen": agentic.timestampsSeen,
            "dauer_s": (agentic.elapsed * 1000).rounded() / 1000,
            "cache": cacheURL?.path ?? "aus",
        ],
    ]
    let json = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    print(String(data: json, encoding: .utf8)!)
    exit(0)
}

if args.contains("--check") {
    let settings = Settings.load()
    let ax = HotkeyManager.hasAccessibilityPermission(prompt: false)
    let whisper = WhisperClient(settings: settings)
    print("Accessibility: \(ax ? "OK" : "FEHLT")")
    print("whisper-server erreichbar: \(whisper.healthCheck() ? "JA" : "NEIN (wird beim App-Start automatisch gestartet)")")
    print("Modell vorhanden: \(FileManager.default.fileExists(atPath: settings.modelPath) ? "JA" : "NEIN") (\(settings.modelPath))")
    exit(0)
}

// MARK: - Normaler App-Start (Menübar)

final class AppDelegate: NSObject, NSApplicationDelegate {
    var settings = Settings.load()
    var whisper: WhisperClient!
    var history: HistoryStore!
    var controller: DictationController!
    var statusBar: StatusBarController!
    var hotkeys: HotkeyManager!
    var axPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("LocalFlow startet …")
        whisper = WhisperClient(settings: settings)
        history = HistoryStore()
        controller = DictationController(settings: settings, whisper: whisper, history: history)
        statusBar = StatusBarController(controller: controller, history: history)
        statusBar.hotkeyLabel = ["rightOption": "rechte ⌥", "rightCommand": "rechte ⌘"][settings.hotkey] ?? "Fn"
        controller.showBar()

        // Berechtigungen anstoßen (Prompts erscheinen nur beim ersten Mal)
        AudioRecorder.requestPermission { granted in
            Log.info("Mikrofon-Berechtigung: \(granted ? "erteilt" : "FEHLT")")
        }
        let axOK = HotkeyManager.hasAccessibilityPermission(prompt: true)
        Log.info("Accessibility-Berechtigung: \(axOK ? "erteilt" : "FEHLT — bitte in Systemeinstellungen › Datenschutz › Bedienungshilfen erteilen")")

        let hotkeyName = settings.hotkey
        Log.info("Hotkey: \(hotkeyName)")
        hotkeys = HotkeyManager(maxHold: settings.maxRecordingSeconds,
                                hotkey: .named(hotkeyName),
                                enableControlSpace: settings.enableControlSpace)

        // Dashboard beim manuellen Start zeigen — beim Autostart (--background) NICHT,
        // damit nicht bei jedem Anmelden ein Fenster aufpoppt.
        if !CommandLine.arguments.contains("--background") {
            statusBar.openDashboardPublic()
        }
        hotkeys.delegate = controller
        if !hotkeys.start() {
            // Accessibility hat keinen Grant-Callback → pollen und Tap nachziehen,
            // sobald der Nutzer die Berechtigung erteilt (kein App-Neustart nötig).
            Log.error("Hotkey-Tap inaktiv — warte auf Accessibility-Berechtigung …")
            axPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                guard HotkeyManager.hasAccessibilityPermission(prompt: false) else { return }
                if self?.hotkeys.start() == true {
                    Log.info("Accessibility erteilt — Hotkey jetzt aktiv")
                    timer.invalidate()
                    self?.axPollTimer = nil
                }
            }
        }

        // Dashboard per Notification öffnen — harmloses Lese-Fenster, daher immer aktiv
        // (z. B. für einen künftigen globalen Shortcut oder `LocalFlow --dashboard`).
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("de.enzolorenz.localflow.open-dashboard"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.statusBar.openDashboardPublic()
        }

        if settings.debugHooksEnabled {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("de.enzolorenz.localflow.test-dictation"),
                object: nil, queue: .main
            ) { [weak self] note in
                guard let path = note.object as? String else { return }
                Log.info("Test-Hook: \(path)")
                self?.controller.processTestFile(path)
            }
            Log.info("Debug-Test-Hook aktiv (debugHooksEnabled)")
        }

        // whisper-server im Hintergrund hochfahren (Modell-Load dauert einige Sekunden)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try self?.whisper.ensureRunning()
            } catch {
                Log.error("whisper-server: \(error.localizedDescription)")
            }
        }
    }

    // Fenster schließen beendet die App nicht — läuft als Dock-/Menüleisten-App weiter.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Klick aufs Dock-Icon öffnet das Dashboard wieder.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        statusBar?.openDashboardPublic()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.stop()
        whisper?.shutdown()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)   // echte App mit Dock-Icon
app.run()
