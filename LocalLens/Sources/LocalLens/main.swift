import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - CLI-Testmodus (ohne GUI): locallens --process <bild> [--no-describe]
let args = CommandLine.arguments
if args.contains("--detect-window") {
    let t = Capture.frontmostTarget()
    print("Erkanntes Fenster: app=\(t.appName.isEmpty ? "(keins)" : t.appName) windowID=\(t.windowID.map(String.init) ?? "nil") → \(t.windowID != nil ? "AUTO-Scan (kein Ziehen)" : "Fallback Region")")
    exit(0)
}

if let i = args.firstIndex(of: "--video"), i + 1 < args.count {
    let settings = Settings.load()
    let r = VideoPipeline.process(videoURL: URL(fileURLWithPath: args[i + 1]), settings: settings) { note in
        FileHandle.standardError.write((note + "\n").data(using: .utf8)!)
    }
    print(r.promptReady); print("\n--- \(r.savingsNote)")
    exit(0)
}

if let i = args.firstIndex(of: "--process"), i + 1 < args.count {
    let settings = Settings.load()
    let describe = !args.contains("--no-describe") && OllamaDescriber.isAvailable(settings: settings)
    guard let r = Pipeline.process(imageURL: URL(fileURLWithPath: args[i + 1]),
                                   sourceApp: "", describe: describe, settings: settings) else {
        FileHandle.standardError.write("Bild nicht lesbar\n".data(using: .utf8)!); exit(1)
    }
    print(r.promptReady)
    print("\n--- \(r.imageTokens) Bild-Tokens → \(r.textTokens) Text-Tokens (gespart ~\(r.imageTokens - r.textTokens)/Blick), Beschreibung: \(describe ? "ja" : "nein")")
    exit(0)
}

// MARK: - App

final class AppController: NSObject, NSApplicationDelegate {
    let settings = Settings.load()
    let model = LensModel()
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var hotKey: HotKey?
    let queue = DispatchQueue(label: "locallens.pipeline", qos: .userInitiated)

    func applicationDidFinishLaunching(_ n: Notification) {
        Log.info("LocalLens startet")
        model.onImageDropped = { [weak self] url in self?.processFile(url) }
        model.onCapture = { [weak self] in self?.capture() }
        model.onCopy = { [weak self] in self?.copyOutput() }

        buildWindow()
        buildStatusItem()
        // Globaler Hotkey Cmd+Shift+2 → aktives Fenster scannen (kostet ~nichts)
        hotKey = HotKey(keyCode: kVK_ANSI_2, modifiers: cmdKey | shiftKey) { [weak self] in
            self?.capture()
        }
        // Beim Autostart (--background) NUR Dock-Icon + Menüleiste, kein Fenster-Popup.
        if !CommandLine.arguments.contains("--background") {
            showWindow()
        }

        // Vision-Modell im Hintergrund vorwärmen (falls Ollama läuft)
        queue.async { [weak self] in
            guard let self else { return }
            let ok = OllamaDescriber.isAvailable(settings: self.settings)
            Log.info("Ollama verfügbar: \(ok) (Modell \(self.settings.visionModel))")
        }
    }

    // MARK: Aktionen

    private func capture() {
        // Bildschirmaufnahme-Berechtigung sicherstellen (zeigt beim ersten Mal den System-Dialog).
        if !Capture.hasPermission() {
            Capture.requestPermission()
            showWindow()
            model.output = "Bitte die Bildschirmaufnahme für LocalLens erlauben:\nSystemeinstellungen → Datenschutz & Sicherheit → Bildschirmaufnahme → LocalLens aktivieren.\n\nDanach nochmal auf Screen scannen klicken. (Bilder per Drag & Drop gehen sofort, ohne Berechtigung.)"
            model.state = .done
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            return
        }
        Capture.grab(mode: settings.captureMode) { [weak self] cg, app in
            guard let self else { return }
            guard let cg else { return }   // abgebrochen
            self.showWindow()
            self.runPipeline(cgImage: cg, app: app)
        }
    }

    /// Datei aus Drop/Upload: Bild ODER Video (nach Endung/Typ).
    private func processFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ["mov", "mp4", "m4v", "avi", "mkv", "webm"].contains(ext) {
            processVideo(url)
        } else {
            processImageFile(url)
        }
    }

    private func processImageFile(_ url: URL) {
        model.state = .analyzing; model.output = ""; model.appLabel = ""
        queue.async { [weak self] in
            guard let self else { return }
            let describe = OllamaDescriber.isAvailable(settings: self.settings)
            guard let r = Pipeline.process(imageURL: url, sourceApp: "", describe: describe, settings: self.settings) else {
                DispatchQueue.main.async { self.model.state = .idle; self.model.output = "Bild nicht lesbar." }
                return
            }
            self.finish(r, cg: nil)
        }
    }

    private func processVideo(_ url: URL) {
        model.state = .analyzing; model.output = ""; model.appLabel = "Video"
        queue.async { [weak self] in
            guard let self else { return }
            let r = VideoPipeline.process(videoURL: url, settings: self.settings) { note in
                DispatchQueue.main.async { self.model.stats = note }
            }
            DispatchQueue.main.async {
                self.model.output = r.promptReady
                self.model.state = .done
                self.model.stats = r.savingsNote
                if self.settings.autoCopy { self.copyOutput() }
            }
            if self.settings.saveToVault { VideoPipeline.saveToVault(r) }
        }
    }

    private func runPipeline(cgImage cg: CGImage, app: String) {
        model.state = .analyzing
        model.output = ""
        model.appLabel = app
        queue.async { [weak self] in
            guard let self else { return }
            let describe = OllamaDescriber.isAvailable(settings: self.settings)
            let r = Pipeline.process(cgImage: cg, sourceApp: app, describe: describe, originalURL: nil, settings: self.settings)
            self.finish(r, cg: cg)
        }
    }

    private func finish(_ r: Pipeline.Result, cg: CGImage?) {
        if settings.saveToVault { _ = Pipeline.saveToVault(r, originalCG: cg) }
        DispatchQueue.main.async {
            self.model.output = r.promptReady
            self.model.state = .done
            self.model.stats = "\(r.imageTokens)→\(r.textTokens) Tokens · gespart ~\(r.imageTokens - r.textTokens)"
            if self.settings.autoCopy { self.copyOutput() }
        }
    }

    private func copyOutput() {
        guard !model.output.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.output, forType: .string)
        model.justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.model.justCopied = false }
    }

    // MARK: UI

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "LocalLens"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        let host = NSHostingView(rootView: ContentView(model: model))
        host.frame = window.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        window.contentView = host
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Log.info("Fenster sichtbar=\(window.isVisible) frame=\(NSStringFromRect(window.frame)) screen=\(window.screen?.localizedName ?? "?")")
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "LocalLens")
            button.toolTip = "LocalLens — klicken: aktives Fenster scannen · Rechtsklick: Menü"
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Aktives Fenster scannen", action: #selector(menuCapture), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Region scannen", action: #selector(menuCaptureRegion), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Fenster öffnen (Drag & Drop)", action: #selector(menuOpen), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let auto = NSMenuItem(title: "Bei Anmeldung starten", action: #selector(toggleAutoStart), keyEquivalent: "")
        auto.target = self; auto.state = AutoStart.isEnabled() ? .on : .off
        menu.addItem(auto)
        let hk = NSMenuItem(title: "Hotkey: ⌘⇧2", action: nil, keyEquivalent: ""); hk.isEnabled = false
        menu.addItem(hk)
        menu.addItem(.separator())
        menu.addItem(withTitle: "LocalLens beenden", action: #selector(menuQuit), keyEquivalent: "q").target = self
        return menu
    }

    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false) {
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)      // Menü zeigen
            statusItem.menu = nil                     // danach zurücksetzen, damit Linksklick wieder Aktion ist
        } else {
            capture()
        }
    }

    @objc private func menuCapture() { capture() }
    @objc private func menuCaptureRegion() {
        if !Capture.hasPermission() { capture(); return }
        Capture.grab(mode: "region") { [weak self] cg, app in
            guard let self, let cg else { return }
            self.showWindow(); self.runPipeline(cgImage: cg, app: app)
        }
    }
    @objc private func menuOpen() { showWindow() }
    @objc private func toggleAutoStart(_ sender: NSMenuItem) {
        let enable = sender.state != .on
        if AutoStart.set(enable) { sender.state = enable ? .on : .off }
    }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool { showWindow(); return true }
}

let app = NSApplication.shared
let delegate = AppController()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
