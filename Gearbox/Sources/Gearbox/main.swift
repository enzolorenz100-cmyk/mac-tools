import AppKit
import Carbon.HIToolbox
import SwiftUI

final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Erster Klick wirkt sofort (auch wenn das Panel nicht key ist) und Maus-Drags
/// gehen an SwiftUI-Gesten statt das ganze Fenster zu verschieben.
final class GearboxHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @MainActor @preconcurrency required dynamic init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
}

/// Griff-Fläche: verschiebt das Fenster (nur der Header ist zum Ziehen gedacht).
final class WindowDragNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragNSView { WindowDragNSView() }
    func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: WidgetPanel!
    private var cleanerPanel: WidgetPanel!
    private var finderPanel: WidgetPanel!
    private var cockpitPanel: WidgetPanel!
    private var keyMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?

    /// Glas-Container: Blur ganz unten fürs Tiefengefühl, darüber ein fester
    /// dunkler Tönungs-Layer, der die Lesbarkeit unabhängig vom jeweiligen
    /// Desktop-Hintergrund garantiert (reines Blur schimmerte mit hellem
    /// Hintergrund durch und wurde dann zu grau/kontrastarm — Enzo: „passt
    /// nicht zu meinem Desktop"). Frame-basiert statt Autolayout — Constraints
    /// zwischen Fenster und SwiftUI-Intrinsic-Size können sich sonst in eine
    /// Endlosschleife hochschaukeln.
    private func makeGlassContainer(cornerRadius: CGFloat, host: NSView, size: NSSize) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.alphaValue = 1

        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.88).cgColor

        for view in [blur, tint, host] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        return container
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Launcher.cleanupOldScripts()

        let panel = WidgetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 372, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Fix wie ein echtes Widget — verschieben nur über den Header-Griff
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // Glas ist immer dunkel getönt — ohne festes darkAqua rendern native
        // Menüs/Controls im Light Mode schwarz auf schwarz
        panel.appearance = NSAppearance(named: .darkAqua)

        let host = GearboxHostingView(rootView: ContentView())
        // Feste Größe statt host.fittingSize: der unbegrenzte Constraint-Solve
        // über den SwiftUI-Baum stallt den Launch sonst minutenlang
        let hostSize = NSSize(width: 684, height: 295)
        host.sizingOptions = [] // keine Intrinsic-Size-Constraints ans Fenster melden
        panel.contentView = makeGlassContainer(cornerRadius: 22, host: host, size: hostSize)
        panel.setContentSize(hostSize)

        let hadSavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame GearboxPanel") != nil
        panel.setFrameAutosaveName("GearboxPanel")
        // Autosave stellt auch eine evtl. veraltete Größe wieder her — Größe erneut erzwingen
        panel.setContentSize(hostSize)
        if !hadSavedFrame, let screen = Self.systemMainScreen {
            let visible = screen.visibleFrame
            let origin = NSPoint(x: visible.maxX - panel.frame.width - 36,
                                 y: visible.midY - panel.frame.height / 2)
            panel.setFrameOrigin(origin)
        }

        self.panel = panel
        cleanerPanel = makeSatellitePanel(rootView: DesktopCleanerView(), like: panel)
        finderPanel = makeSatellitePanel(rootView: DesktopFinderView(), like: panel)
        cockpitPanel = makeSatellitePanel(
            rootView: SessionCockpitView(onHeightChange: { [weak self] height in
                self?.resizeCockpitPanel(toContentHeight: height)
            }),
            like: panel
        )
        applyLevel()
        ensureOnScreen()
        parkInWidgetColumnOnce()
        rehomeToMainScreenIfNeeded()
        positionCleanerPanel()
        panel.addChildWindow(cleanerPanel, ordered: .above)
        panel.addChildWindow(finderPanel, ordered: .above)
        panel.addChildWindow(cockpitPanel, ordered: .above)
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: .gearboxLevelChanged,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.applyLevel()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.ensureOnScreen()
            self?.rehomeToMainScreenIfNeeded()
        }
        // Nach Fokusverlust zurück auf die konfigurierte Ebene (Summon hebt temporär an)
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            self?.applyLevel()
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event)
        }
        registerSummonHotkey()
    }

    /// Globaler Summon-Hotkey (Default ⌥Space; änderbar via
    /// `defaults write com.enzolorenz.gearbox summonKeyCode/summonModifiers`).
    private func registerSummonHotkey() {
        let defaults = UserDefaults.standard
        let keyCode = UInt32(defaults.object(forKey: "summonKeyCode") as? Int ?? kVK_Space)
        let modifiers = UInt32(defaults.object(forKey: "summonModifiers") as? Int ?? optionKey)

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.summon() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4742_5853), id: 1) // 'GBXS'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    /// Widget aufs Display mit dem Mauszeiger holen, nach vorn heben und das Prompt-Feld fokussieren.
    func summon() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
           !screen.frame.intersects(panel.frame) {
            let visible = screen.visibleFrame
            let x = min(max(visible.minX + 24, mouse.x - panel.frame.width / 2),
                        visible.maxX - panel.frame.width - 24)
            panel.setFrameOrigin(NSPoint(x: x, y: visible.midY - panel.frame.height / 2))
        }
        panel.level = .floating
        cleanerPanel?.level = .floating
        finderPanel?.level = .floating
        cockpitPanel?.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .gearboxFocusPrompt, object: nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.orderFrontRegardless()
        return false
    }

    /// Satelliten-Panel (DesktopCleaner, Desktop Finder …): eigenes Mini-Panel,
    /// hängt als Kind-Fenster am Hauptwidget und wandert automatisch mit.
    private func makeSatellitePanel<Content: View>(rootView: Content,
                                                   like parent: WidgetPanel) -> WidgetPanel {
        let satellite = WidgetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 684, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        satellite.isFloatingPanel = true
        satellite.becomesKeyOnlyIfNeeded = true
        satellite.hidesOnDeactivate = false
        satellite.isReleasedWhenClosed = false
        satellite.isMovableByWindowBackground = false
        satellite.backgroundColor = .clear
        satellite.isOpaque = false
        satellite.hasShadow = true
        satellite.collectionBehavior = parent.collectionBehavior
        satellite.appearance = NSAppearance(named: .darkAqua)

        let host = GearboxHostingView(rootView: rootView)
        let hostSize = NSSize(width: 684, height: 54) // fix statt fittingSize (Launch-Stall)
        host.sizingOptions = []
        satellite.contentView = makeGlassContainer(cornerRadius: 16, host: host, size: hostSize)
        satellite.setContentSize(hostSize)
        return satellite
    }

    /// Lässt das Cockpit-Panel — unterstes in der Satelliten-Reihe, nichts
    /// hängt darunter — nach unten wachsen, sobald mehr Sessions laufen
    /// (Enzo: „alle aktiven Tabs sehen, kein +N mehr"). Die Oberkante bleibt
    /// fix; AppKit-Frames sind bottom-left-basiert, „nach unten wachsen"
    /// heißt also origin.y sinkt um genau den Höhenzuwachs.
    private func resizeCockpitPanel(toContentHeight newHeight: CGFloat) {
        guard let cockpitPanel else { return }
        let current = cockpitPanel.frame
        guard abs(current.height - newHeight) > 0.5 else { return }
        let newFrame = NSRect(x: current.minX, y: current.maxY - newHeight,
                              width: current.width, height: newHeight)
        cockpitPanel.setFrame(newFrame, display: true)
    }

    /// Home-Position fürs Widget: oben links auf dem übergebenen Screen
    /// ("Oben links geparkt" — Enzo hat dort Platz gemacht).
    private func topLeftOrigin(on screen: NSScreen, height: CGFloat) -> NSPoint {
        let visible = screen.visibleFrame
        return NSPoint(x: visible.minX + 10, y: visible.maxY - 10 - height)
    }

    /// Einmalig ganz oben links in die Ecke parken (Enzo hat dort Platz gemacht).
    private func parkInWidgetColumnOnce() {
        let key = "parkedObenLinksV3"
        guard !UserDefaults.standard.bool(forKey: key), let panel, let screen = Self.systemMainScreen else { return }
        panel.setFrameOrigin(topLeftOrigin(on: screen, height: panel.frame.height))
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Steht das Widget nicht (mehr) auf dem aktuellen Hauptbildschirm (System
    /// Settings ▸ Displays ▸ Anordnung, der mit der Menüleiste), zurück
    /// dorthin holen. Ohne das bleibt die zuletzt gespeicherte Fensterposition
    /// nach einem Monitor-Wechsel (z. B. 1 Bildschirm → 3 Bildschirme) auf
    /// einem ganz anderen physischen Monitor hängen, obwohl sie dort noch
    /// technisch "sichtbar" ist — Enzo: „auf einmal nicht mehr auf meinem
    /// Hauptbildschirm".
    private func rehomeToMainScreenIfNeeded() {
        guard let panel, let mainScreen = Self.systemMainScreen, panel.screen !== mainScreen else { return }
        panel.setFrameOrigin(topLeftOrigin(on: mainScreen, height: panel.frame.height))
        positionCleanerPanel()
    }

    /// Das in System Settings ▸ Displays ▸ Anordnung als Haupt-Display markierte
    /// (das mit der Menüleiste) — NICHT `NSScreen.main`: das liefert laut Apple-
    /// Doku den Screen des aktuell *Key*-Fensters und fällt bei einer Accessory-
    /// App wie dieser oft einfach auf den Screen zurück, auf dem das eigene
    /// Fenster schon steht (selbstreferenziell, per Debug-Log verifiziert).
    /// Das System-Hauptdisplay hat per Definition immer Frame-Ursprung (0, 0).
    private static var systemMainScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero }
    }

    /// Satelliten unter dem Hauptpanel stapeln: Cleaner, Finder, Cockpit.
    private func positionCleanerPanel() {
        guard let panel, let cleanerPanel, let finderPanel, let cockpitPanel else { return }
        cleanerPanel.setFrameOrigin(NSPoint(x: panel.frame.minX,
                                            y: panel.frame.minY - cleanerPanel.frame.height - 10))
        finderPanel.setFrameOrigin(NSPoint(x: panel.frame.minX,
                                           y: cleanerPanel.frame.minY - finderPanel.frame.height - 10))
        cockpitPanel.setFrameOrigin(NSPoint(x: panel.frame.minX,
                                            y: finderPanel.frame.minY - cockpitPanel.frame.height - 10))
    }

    /// Holt das Widget zurück, wenn sein Display verschwindet (Monitor abgestöpselt o. ä.).
    private func ensureOnScreen() {
        guard let panel else { return }
        let mostlyVisible = NSScreen.screens.contains {
            $0.frame.intersects(panel.frame.insetBy(dx: 60, dy: 60))
        }
        if !mostlyVisible, let screen = Self.systemMainScreen ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 36,
                                         y: visible.midY - panel.frame.height / 2))
            panel.orderFrontRegardless()
        }
    }

    private func applyLevel() {
        if UserDefaults.standard.bool(forKey: "alwaysOnTop") {
            panel.level = .floating
        } else {
            // Desktop-Widget-Ebene: über Wallpaper & Icons, unter normalen Fenstern
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        }
        cleanerPanel?.level = panel.level
        finderPanel?.level = panel.level
        cockpitPanel?.level = panel.level
        panel.orderFrontRegardless()
    }

    /// Cmd+Enter startet; Cmd+C/V/X/A/Z funktionieren trotz fehlender Menüleiste (LSUIElement).
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let isOurWindow = event.window === panel || event.window === cleanerPanel
            || event.window === finderPanel
        guard isOurWindow else { return event }
        let isMainPanel = event.window === panel
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)

        if isMainPanel, event.keyCode == 36 || event.keyCode == 76, flags.contains(.command) {
            if !event.isARepeat {
                // ⌘⇧⏎ = Batch-Fire: Terminal öffnet im Hintergrund, Widget behält den Fokus
                let name: Notification.Name = flags.contains(.shift) ? .gearboxLaunchBackground : .gearboxLaunch
                NotificationCenter.default.post(name: name, object: nil)
            }
            return nil
        }
        // ⌘↑/⌘↓ = Prompt-History blättern
        if isMainPanel, flags == .command, event.keyCode == 126 {
            NotificationCenter.default.post(name: .gearboxHistory, object: -1)
            return nil
        }
        if isMainPanel, flags == .command, event.keyCode == 125 {
            NotificationCenter.default.post(name: .gearboxHistory, object: 1)
            return nil
        }
        guard flags == .command || flags == [.command, .shift] else { return event }
        let key = event.charactersIgnoringModifiers?.lowercased()

        // ⌘1–⌘4 = Gang, ⌘0 = Automatik, ⌘R = Resume (nur im Hauptpanel)
        if isMainPanel, flags == .command, let key {
            let gearForKey: Gear? = switch key {
            case "0": .auto
            case "1": .haiku
            case "2": .sonnet
            case "3": .opus
            case "4": .fable
            case "r": .resume
            default: nil
            }
            if let gearForKey {
                NotificationCenter.default.post(name: .gearboxSetGear, object: gearForKey.rawValue)
                return nil
            }
        }

        let action: Selector?
        switch (key, flags) {
        case ("v", .command): action = Selector(("paste:"))
        case ("c", .command): action = Selector(("copy:"))
        case ("x", .command): action = Selector(("cut:"))
        case ("a", .command): action = Selector(("selectAll:"))
        case ("z", .command): action = Selector(("undo:"))
        case ("z", [.command, .shift]): action = Selector(("redo:"))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: nil) {
            return nil
        }
        return event
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
