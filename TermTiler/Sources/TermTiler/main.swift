import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var flashResetWorkItem: DispatchWorkItem?

    // Klick-Zyklus: erneutes Auslösen kurz nacheinander schaltet eine Stufe weiter
    private var cycleStep = 0
    private var lastTileAt: Date?
    private var lastFingerprint = ""

    private var layout: Layout {
        get { Layout(rawValue: UserDefaults.standard.string(forKey: "layout") ?? "") ?? .grid }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "layout") }
    }
    private var includeMinimized: Bool {
        get { UserDefaults.standard.bool(forKey: "includeMinimized") }
        set { UserDefaults.standard.set(newValue, forKey: "includeMinimized") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // Monochromes Template-Symbol: rendert grau und passt sich
            // hell/dunkel sowie aktivem Zustand der Menüleiste an.
            if let img = NSImage(systemSymbolName: "puzzlepiece.fill", accessibilityDescription: "TermTiler") {
                img.isTemplate = true
                button.image = img
                button.imagePosition = .imageLeading
            } else {
                button.title = "🧩"
            }
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "TermTiler — Klick: Terminals anordnen · Rechtsklick: Menü"
        }
        registerTileHotkey()
    }

    // MARK: - Klick-Handling

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            tile()
        }
    }

    // MARK: - Kernfunktion

    @objc func tile() {
        guard TerminalBridge.isTerminalRunning else { flash("0"); return }
        guard let all = TerminalBridge.fetchWindows() else { flash("!"); return }

        // Nur Fenster auf gerade sichtbaren Spaces anfassen — Fenster auf anderen
        // Spaces/Vollbild blieben sonst als Löcher im Raster zurück. Fallback auf
        // das AppleScript-visible-Flag, falls CGWindowList nichts liefert.
        let onScreen = TerminalBridge.onScreenWindowBounds()
        var windows = onScreen.isEmpty
            ? all.filter { $0.visible && !$0.miniaturized }
            : all.filter { onScreen[$0.id] != nil }
        if includeMinimized {
            windows += all.filter { $0.miniaturized }
        }
        guard !windows.isEmpty else { flash("0"); return }

        // Displays automatisch erkennen; Maus-Display zuerst befüllen,
        // Überlauf wandert auf die weiteren Displays.
        let screens = NSScreen.screens
        guard !screens.isEmpty else { flash("!"); return }
        let mouse = NSEvent.mouseLocation
        let mouseIdx = screens.firstIndex { NSMouseInRect(mouse, $0.frame, false) } ?? 0
        var order = Array(screens.indices)
        order.removeAll { $0 == mouseIdx }
        order.insert(mouseIdx, at: 0)

        // Klick-Zyklus: erneuter Klick innerhalb von 8 s (bei unveränderter
        // Fenster-/Displayzahl) schaltet weiter — Multi-Display: ein Fenster mehr
        // wandert aufs nächste Display; ein Display: nächstes Layout.
        let fingerprint = "\(windows.count)/\(screens.count)"
        if let last = lastTileAt, Date().timeIntervalSince(last) < 8, fingerprint == lastFingerprint {
            cycleStep += 1
        } else {
            cycleStep = 0
        }
        lastTileAt = Date()
        lastFingerprint = fingerprint

        var cycledLayout = false
        if screens.count == 1, cycleStep > 0 {
            layout = layout.next
            cycledLayout = true
        }

        // Komfortgröße: solange Zellen so groß bleiben, kommt alles auf ein
        // Display; sonst Überlauf (z. B. 5 Terminals → 4 + 1). Änderbar via
        // `defaults write com.enzolorenz.termtiler comfortWidth/comfortHeight`.
        let defaults = UserDefaults.standard
        let comfortW = CGFloat(defaults.object(forKey: "comfortWidth") as? Double ?? 560)
        let comfortH = CGFloat(defaults.object(forKey: "comfortHeight") as? Double ?? 340)

        // Stabil nach Fenster-ID, damit wiederholtes Anordnen nicht durchwürfelt
        var remaining = windows.sorted { $0.id < $1.id }
        var groups: [(frame: CGRect, windows: [TerminalBridge.TermWindow])] = []
        for (i, idx) in order.enumerated() {
            guard !remaining.isEmpty else { break }
            let frame = TerminalBridge.appleScriptFrame(for: screens[idx].visibleFrame)
            var cap: Int
            if i == order.count - 1 {
                cap = remaining.count // letztes Display nimmt den Rest
            } else {
                cap = displayCapacity(of: frame, layout: layout, gap: 10, comfortW: comfortW, comfortH: comfortH)
                if i == 0 {
                    // Zyklus-Stufe: pro Klick behält das Maus-Display ein Fenster
                    // weniger; nach der letzten Stufe wieder von vorn
                    cap = firstDisplayQuota(base: min(cap, windows.count), step: cycleStep)
                }
            }
            let take = min(max(1, cap), remaining.count)
            groups.append((frame, Array(remaining.prefix(take))))
            remaining.removeFirst(take)
        }

        var assignments: [(TerminalBridge.TermWindow, CGRect)] = []
        for group in groups {
            // Beim Stapel-Layout kommt das vorderste Fenster auf den Hauptplatz
            let arranged: [TerminalBridge.TermWindow]
            if layout == .mainStack, let front = group.windows.min(by: { $0.zIndex < $1.zIndex }) {
                arranged = [front] + group.windows.filter { $0.id != front.id }
            } else {
                arranged = group.windows
            }
            let rects = computeRects(count: arranged.count, in: group.frame, layout: layout, gap: 10)
            assignments += Array(zip(arranged, rects))
        }

        TerminalBridge.apply(assignments)
        // Feedback: Layout-Name beim Durchschalten, sonst Verteilung ("4+1")
        flash(cycledLayout ? layout.title : groups.map { "\($0.windows.count)" }.joined(separator: "+"))
    }

    /// Kurzes Feedback neben dem Icon (z. B. Fensteranzahl), dann wieder nur Symbol.
    private func flash(_ text: String) {
        flashResetWorkItem?.cancel()
        statusItem.button?.title = " \(text)"
        let reset = DispatchWorkItem { [weak self] in self?.statusItem.button?.title = "" }
        flashResetWorkItem = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: reset)
    }

    // MARK: - Menü

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let tileItem = NSMenuItem(title: "Terminals anordnen", action: #selector(tile), keyEquivalent: "")
        tileItem.target = self
        menu.addItem(tileItem)
        menu.addItem(.separator())

        let header = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for l in Layout.allCases {
            let item = NSMenuItem(title: l.title, action: #selector(selectLayout(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = l.rawValue
            item.state = (l == layout) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let minItem = NSMenuItem(title: "Minimierte einbeziehen", action: #selector(toggleMinimized), keyEquivalent: "")
        minItem.target = self
        minItem.state = includeMinimized ? .on : .off
        menu.addItem(minItem)

        let loginItem = NSMenuItem(title: "Bei Login starten", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "TermTiler beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    @objc private func selectLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let l = Layout(rawValue: raw) else { return }
        layout = l
        lastTileAt = nil // bewusste Menü-Wahl schaltet den Klick-Zyklus nicht weiter
        tile() // direkt anwenden — sofortiges Feedback
    }

    @objc private func toggleMinimized() {
        includeMinimized.toggle()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("TermTiler Login-Item-Fehler: \(error)")
        }
    }

    // MARK: - Globaler Hotkey (Default ⌃⌥T; änderbar via
    // `defaults write com.enzolorenz.termtiler tileKeyCode/tileModifiers -int <n>`)

    private func registerTileHotkey() {
        let defaults = UserDefaults.standard
        // UInt32(exactly:) statt trappendem Init — negative/zu große defaults-Werte
        // dürfen die App nicht beim Start crashen, sondern fallen auf ⌃⌥T zurück.
        let keyCode = (defaults.object(forKey: "tileKeyCode") as? Int)
            .flatMap { UInt32(exactly: $0) } ?? UInt32(kVK_ANSI_T)
        let modifiers = (defaults.object(forKey: "tileModifiers") as? Int)
            .flatMap { UInt32(exactly: $0) } ?? UInt32(controlKey | optionKey)

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.tile() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x5454_4C52), id: 1) // 'TTLR'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
