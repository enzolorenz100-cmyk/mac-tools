import AppKit
import ServiceManagement

/// Menübar-Icon + Menü (Status, letztes Transkript, Verlauf, Beenden).
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let controller: DictationController
    private let history: HistoryStore
    private let statusMenuItem = NSMenuItem(title: "Bereit", action: nil, keyEquivalent: "")
    private lazy var historyWindow = HistoryWindowController(history: history) { [weak self] text in
        self?.controller.insertExternally(text)
    }
    var hotkeyLabel = "Fn"

    init(controller: DictationController, history: HistoryStore) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.controller = controller
        self.history = history
        super.init()

        setIcon(recording: false)
        let menu = NSMenu()
        menu.delegate = self
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        let dashboardItem = NSMenuItem(title: "Verlauf & Dashboard öffnen…", action: #selector(openDashboard), keyEquivalent: "d")
        dashboardItem.target = self
        menu.addItem(dashboardItem)

        let pasteItem = NSMenuItem(title: "Letztes Transkript einfügen", action: #selector(pasteLast), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)

        let historyMenu = NSMenu()
        let historyItem = NSMenuItem(title: "Zuletzt (Schnellzugriff)", action: nil, keyEquivalent: "")
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)

        menu.addItem(.separator())
        let loginItem = NSMenuItem(title: "Bei Anmeldung starten", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = AutoStart.isEnabled() ? .on : .off
        menu.addItem(loginItem)
        let settingsItem = NSMenuItem(title: "Einstellungen öffnen (settings.json)", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let logItem = NSMenuItem(title: "Log anzeigen", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "LocalFlow beenden", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu

        controller.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.update(for: state) }
        }
    }

    private func update(for state: DictationController.State) {
        switch state {
        case .idle:
            statusMenuItem.title = "Bereit — \(hotkeyLabel) halten zum Diktieren"
            setIcon(recording: false)
        case .recording(let handsFree):
            statusMenuItem.title = handsFree ? "Aufnahme (Freihand — \(hotkeyLabel) stoppt)" : "Aufnahme läuft …"
            setIcon(recording: true)
        case .transcribing:
            statusMenuItem.title = "Transkribiere …"
            setIcon(recording: false)
        }
    }

    private func setIcon(recording: Bool) {
        let name = recording ? "mic.fill" : "mic"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "LocalFlow")
        img?.isTemplate = !recording
        statusItem.button?.image = img
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    // Verlauf-Untermenü bei jedem Öffnen frisch befüllen.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let historyItem = menu.items.first(where: { $0.title == "Zuletzt (Schnellzugriff)" }),
              let submenu = historyItem.submenu else { return }
        submenu.removeAllItems()
        let entries = history.recent(limit: 10)
        if entries.isEmpty {
            submenu.addItem(NSMenuItem(title: "Noch keine Diktate", action: nil, keyEquivalent: ""))
            return
        }
        for entry in entries {
            let preview = entry.formattedText.replacingOccurrences(of: "\n", with: " ").prefix(60)
            let item = NSMenuItem(title: String(preview), action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.formattedText
            item.toolTip = entry.formattedText
            submenu.addItem(item)
        }
    }

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openDashboard() { historyWindow.show() }
    func openDashboardPublic() { historyWindow.show() }

    @objc private func pasteLast() { controller.pasteLastRequested() }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let enable = sender.state != .on
        if AutoStart.set(enable) {
            sender.state = enable ? .on : .off
        } else {
            let alert = NSAlert()
            alert.messageText = "Autostart konnte nicht gesetzt werden"
            alert.informativeText = "Bitte füge LocalFlow manuell hinzu: Systemeinstellungen > Allgemein > Anmeldeobjekte > Plus-Button > LocalFlow.app"
            alert.runModal()
        }
    }

    @objc private func openSettings() {
        NSWorkspace.shared.open(Settings.fileURL)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.logFileURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
