import AppKit
import SwiftUI

/// Hauptfenster (Dock-App) mit dem SwiftUI-Dashboard im Wispr-Flow-Stil.
final class HistoryWindowController: NSObject, NSWindowDelegate {
    private let model: DashboardModel
    private var window: NSWindow!

    init(history: HistoryStore, onInsert: @escaping (String) -> Void) {
        self.model = DashboardModel(history: history, onInsert: onInsert)
        super.init()
        buildWindow()
    }

    func show() {
        model.reload()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "LocalFlow"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 480, height: 440)
        window.setFrameAutosaveName("LocalFlowDashboard")

        let host = NSHostingView(rootView: DashboardView(model: model))
        host.frame = window.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        window.contentView = host
    }

    // Fenster schließen beendet die App NICHT — sie läuft als Menüleisten-/Dock-App weiter.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window.orderOut(nil)
        return false
    }
}
