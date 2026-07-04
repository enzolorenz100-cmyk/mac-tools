import AppKit

/// Wispr-Flow-artige „Flow Bar": dauerhaft sichtbare Mini-Pill unten-mittig,
/// die sich bei Aufnahme ausdehnt und eine Live-Waveform zeigt (flacht bei Stille ab).
/// Klick auf die Bar: Freihand-Diktat starten bzw. laufende Aufnahme stoppen.
/// Nicht-aktivierendes Panel — die Ziel-App behält immer den Fokus.
final class OverlayPanel {
    enum Mode {
        case idle          // Mini-Lozenge
        case recording     // expandiert, Waveform, roter Punkt
        case handsFree     // expandiert, Waveform, oranger Punkt
        case transcribing  // expandiert, pulsierende Punkte
    }

    private let panel: NSPanel
    private let barView: FlowBarView
    private(set) var mode: Mode = .idle
    var showIdleBar = true
    private var positionTimer: Timer?
    var onClick: (() -> Void)? {
        get { barView.onClick }
        set { barView.onClick = newValue }
    }

    private static let idleSize = NSSize(width: 64, height: 14)
    private static let activeSize = NSSize(width: 190, height: 36)

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.idleSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false          // Klick auf die Bar = Freihand-Toggle
        panel.isMovableByWindowBackground = false
        barView = FlowBarView(frame: NSRect(origin: .zero, size: Self.idleSize))
        panel.contentView = barView
    }

    func show(mode: Mode) {
        self.mode = mode
        if mode == .idle && !showIdleBar {
            stopPositionTracking()
            panel.orderOut(nil)
            return
        }
        barView.mode = mode
        let size = (mode == .idle) ? Self.idleSize : Self.activeSize
        let target = frame(for: size)
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
            panel.orderFront(nil)   // NIE makeKeyAndOrderFront — Fokus bleibt bei der Ziel-App
        }
        startPositionTracking()
    }

    func hide() {
        stopPositionTracking()
        panel.orderOut(nil)
    }

    /// Verfolgt den Mauszeiger: verschiebt die Bar live auf den Bildschirm, auf dem sich
    /// die Maus gerade befindet (Multi-Monitor, wie bei Wispr Flow).
    private func startPositionTracking() {
        positionTimer?.invalidate()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            let target = self.frame(for: self.panel.frame.size).origin
            if abs(target.x - self.panel.frame.minX) > 1 || abs(target.y - self.panel.frame.minY) > 1 {
                self.panel.setFrameOrigin(target)
            }
        }
        if let t = positionTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func stopPositionTracking() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    func updateLevel(_ level: Float) {
        DispatchQueue.main.async { self.barView.pushLevel(level) }
    }

    private func frame(for size: NSSize) -> NSRect {
        // Bildschirm unter dem Mauszeiger wählen (Multi-Monitor: Bar erscheint dort,
        // wo der Nutzer gerade arbeitet — wie bei Wispr Flow).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return NSRect(origin: .zero, size: size) }
        // Bewusst screen.frame (physischer Rand) statt visibleFrame: sonst sitzt die Bar auf dem
        // Monitor MIT Dock höher als auf denen ohne. So ist sie auf ALLEN Bildschirmen gleich hoch.
        let f = screen.frame
        let bottomOffset: CGFloat = 66   // knapp über typischem Dock, einheitlich über alle Monitore
        return NSRect(x: f.midX - size.width / 2, y: f.minY + bottomOffset,
                      width: size.width, height: size.height)
    }
}

/// Zeichnet die Pill: idle-Lozenge, Live-Waveform oder Transkriptions-Punkte.
private final class FlowBarView: NSView {
    var onClick: (() -> Void)?
    var mode: OverlayPanel.Mode = .idle {
        didSet {
            if mode == .recording || mode == .handsFree {
                levels = Array(repeating: 0, count: FlowBarView.barCount)
                smoothed = 0
                currentInput = 0
            }
            configureTimer()
            needsDisplay = true
        }
    }

    static let barCount = 28
    private var levels: [Float] = Array(repeating: 0, count: FlowBarView.barCount)
    private var currentInput: Float = 0      // letzter Audio-Pegel (~45×/s aktualisiert)
    private var smoothed: Float = 0          // tiefpassgefiltert für flüssige Bewegung
    private var phase: Double = 0
    private var timer: Timer?

    /// Vom AudioRecorder (~45×/s): nur den aktuellen Ziel-Pegel merken.
    func pushLevel(_ level: Float) {
        currentInput = min(1, max(0, level))
    }

    /// EIN 60-fps-Timer treibt alles: schiebt den (geglätteten) Pegel gleichmäßig in die
    /// Historie → konstant flüssige, auf die Stimme reagierende Waveform (wie bei Wispr).
    private func configureTimer() {
        timer?.invalidate()
        timer = nil
        guard mode != .idle else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase += 1.0 / 60.0
            if self.mode == .recording || self.mode == .handsFree {
                // Tiefpass: schnelles Ansteigen, etwas langsameres Abfallen → weich, aber reaktiv.
                let target = self.currentInput
                let k: Float = target > self.smoothed ? 0.55 : 0.25
                self.smoothed += (target - self.smoothed) * k
                self.levels.removeFirst()
                self.levels.append(self.smoothed)
            }
            self.needsDisplay = true
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let pill = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor.black.withAlphaComponent(0.84).setFill()
        pill.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        pill.lineWidth = 1
        pill.stroke()

        switch mode {
        case .idle:
            drawIdleDots()
        case .recording, .handsFree:
            drawModeDot(color: mode == .recording ? .systemRed : .systemOrange)
            drawWaveform()
        case .transcribing:
            drawThinkingDots()
        }
    }

    /// Idle: drei kleine, dezente Punkte in der Mitte (Mini-Lozenge wie bei Wispr).
    private func drawIdleDots() {
        NSColor.white.withAlphaComponent(0.45).setFill()
        let d: CGFloat = 3.5, gap: CGFloat = 6
        let startX = bounds.midX - d * 1.5 - gap
        for i in 0..<3 {
            let x = startX + CGFloat(i) * (d + gap)
            NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY - d / 2, width: d, height: d)).fill()
        }
    }

    private func drawModeDot(color: NSColor) {
        // sanftes Pulsieren
        let pulse = 0.75 + 0.25 * CGFloat(abs(sin(phase * 2.4)))
        color.withAlphaComponent(pulse).setFill()
        NSBezierPath(ovalIn: NSRect(x: 13, y: bounds.midY - 3.5, width: 7, height: 7)).fill()
    }

    private func drawWaveform() {
        let leftPad: CGFloat = 28, rightPad: CGFloat = 14
        let area = NSRect(x: leftPad, y: 0, width: bounds.width - leftPad - rightPad, height: bounds.height)
        let n = Self.barCount
        let gap: CGFloat = 2
        let barW = (area.width - gap * CGFloat(n - 1)) / CGFloat(n)
        let maxH = bounds.height - 12

        for (i, level) in levels.enumerated() {
            // Bei Stille flach (1,5 px), sonst symmetrisch nach oben/unten wie bei Wispr.
            let h = max(1.5, CGFloat(level) * maxH)
            let x = area.minX + CGFloat(i) * (barW + gap)
            // neuere Balken (rechts) leicht heller; lautere zusätzlich kräftiger
            let recency = 0.30 + 0.45 * CGFloat(i) / CGFloat(n)
            let loudness = 0.25 * CGFloat(level)
            NSColor.white.withAlphaComponent(min(1, recency + loudness)).setFill()
            let rect = NSRect(x: x, y: bounds.midY - h / 2, width: barW, height: h)
            NSBezierPath(roundedRect: rect, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }

    /// Transkription: drei nacheinander pulsierende Punkte.
    private func drawThinkingDots() {
        let d: CGFloat = 6, gap: CGFloat = 10
        let startX = bounds.midX - d * 1.5 - gap
        for i in 0..<3 {
            let a = 0.25 + 0.75 * abs(sin(phase * 3 - Double(i) * 0.7))
            NSColor.white.withAlphaComponent(CGFloat(a)).setFill()
            let x = startX + CGFloat(i) * (d + gap)
            NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY - d / 2, width: d, height: d)).fill()
        }
    }
}
