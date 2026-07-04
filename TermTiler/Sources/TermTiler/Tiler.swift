import AppKit

/// Layout-Varianten fürs Anordnen.
enum Layout: String, CaseIterable {
    case grid, columns, rows, mainStack

    var title: String {
        switch self {
        case .grid: return "Raster"
        case .columns: return "Spalten"
        case .rows: return "Reihen"
        case .mainStack: return "Hauptfenster + Stapel"
        }
    }

    var next: Layout {
        let all = Layout.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Klick-Zyklus: Wie viele Fenster das erste Display bei Stufe `step` behält.
/// Stufe 0 = volle Komfort-Kapazität, jede weitere Stufe eins weniger (min. 1),
/// nach der letzten Stufe geht es zyklisch wieder von vorn.
func firstDisplayQuota(base: Int, step: Int) -> Int {
    let b = max(1, base)
    return max(1, b - (step % b))
}

/// Terminal.app clampt Fenster real auf ~177×124 pt (empirisch gemessen) —
/// darunter würde `set bounds` still danebenliegen und Fenster überlappen.
let minCellWidth: CGFloat = 180
let minCellHeight: CGFloat = 126

/// Teilt die Achse [start, end] in `count` Zellen mit exakt konstantem Gap:
/// gerundet werden die Gitterkanten, nicht Position und Größe getrennt —
/// dadurch sind alle Gaps pixelgenau gleich, nur Zellgrößen variieren um ≤1 px.
/// Unterschreitet die Zelle `minLen`, wird gleichmäßig überlappend gestaffelt
/// (kontrollierte Degradation statt Terminal-Clamping an zufälligen Stellen).
func splitAxis(from start: CGFloat, to end: CGFloat, count: Int, gap g: CGFloat, minLen: CGFloat) -> [(pos: CGFloat, len: CGFloat)] {
    guard count > 0 else { return [] }
    let cell = (end - start - g * CGFloat(count + 1)) / CGFloat(count)
    if cell < minLen, count > 1 {
        let step = max(0, (end - start - 2 * g - minLen) / CGFloat(count - 1))
        return (0..<count).map { i in
            ((start + g + CGFloat(i) * step).rounded(), minLen)
        }
    }
    let origin: (Int) -> CGFloat = { start + g + CGFloat($0) * (cell + g) }
    return (0..<count).map { i in
        let a = origin(i).rounded()
        let b = ((i == count - 1) ? end - g : origin(i + 1) - g).rounded()
        return (a, b - a)
    }
}

/// Wie viele Fenster auf dieses Display passen, ohne dass Zellen unter die
/// Komfortgröße fallen — bestimmt, wann der Überlauf aufs nächste Display wandert.
func displayCapacity(of frame: CGRect, layout: Layout, gap g: CGFloat, comfortW: CGFloat, comfortH: CGFloat) -> Int {
    func fit(_ span: CGFloat, _ minLen: CGFloat) -> Int {
        max(1, Int(((span - g) / (minLen + g)).rounded(.down)))
    }
    switch layout {
    case .grid:
        var n = 1
        while n < 64 {
            let next = n + 1
            let cols = Int(ceil(sqrt(Double(next))))
            let rows = Int(ceil(Double(next) / Double(cols)))
            let cw = (frame.width - g * CGFloat(cols + 1)) / CGFloat(cols)
            let ch = (frame.height - g * CGFloat(rows + 1)) / CGFloat(rows)
            if cw < comfortW || ch < comfortH { break }
            n = next
        }
        return n
    case .columns: return fit(frame.width, comfortW)
    case .rows: return fit(frame.height, comfortH)
    case .mainStack: return 1 + fit(frame.height, comfortH)
    }
}

/// Reine Geometrie: verteilt `count` Fenster im Rahmen `frame`
/// (Top-Left-Koordinaten, wie AppleScript sie erwartet) mit Abstand `gap`.
func computeRects(count: Int, in frame: CGRect, layout: Layout, gap g: CGFloat) -> [CGRect] {
    guard count > 0 else { return [] }

    switch layout {
    case .grid:
        let cols = Int(ceil(sqrt(Double(count))))
        let rowCount = Int(ceil(Double(count) / Double(cols)))
        let rowSlots = splitAxis(from: frame.minY, to: frame.maxY, count: rowCount, gap: g, minLen: minCellHeight)
        var rects: [CGRect] = []
        var placed = 0
        for (r, row) in rowSlots.enumerated() {
            // Letzte Reihe: übrige Fenster auf volle Breite strecken
            let inRow = (r == rowCount - 1) ? count - placed : min(cols, count - placed)
            for col in splitAxis(from: frame.minX, to: frame.maxX, count: inRow, gap: g, minLen: minCellWidth) {
                rects.append(CGRect(x: col.pos, y: row.pos, width: col.len, height: row.len))
            }
            placed += inRow
        }
        return rects

    case .columns:
        let row = splitAxis(from: frame.minY, to: frame.maxY, count: 1, gap: g, minLen: minCellHeight)[0]
        return splitAxis(from: frame.minX, to: frame.maxX, count: count, gap: g, minLen: minCellWidth).map {
            CGRect(x: $0.pos, y: row.pos, width: $0.len, height: row.len)
        }

    case .rows:
        let col = splitAxis(from: frame.minX, to: frame.maxX, count: 1, gap: g, minLen: minCellWidth)[0]
        return splitAxis(from: frame.minY, to: frame.maxY, count: count, gap: g, minLen: minCellHeight).map {
            CGRect(x: col.pos, y: $0.pos, width: col.len, height: $0.len)
        }

    case .mainStack:
        let row = splitAxis(from: frame.minY, to: frame.maxY, count: 1, gap: g, minLen: minCellHeight)[0]
        if count == 1 {
            let col = splitAxis(from: frame.minX, to: frame.maxX, count: 1, gap: g, minLen: minCellWidth)[0]
            return [CGRect(x: col.pos, y: row.pos, width: col.len, height: row.len)]
        }
        let left = (frame.minX + g).rounded()
        let right = (frame.maxX - g).rounded()
        let innerW = right - left - g
        var mainW = (innerW * 0.58).rounded()
        var stackW = innerW - mainW
        if stackW < minCellWidth {
            stackW = min(minCellWidth, (innerW / 2).rounded())
            mainW = innerW - stackW
        }
        var rects = [CGRect(x: left, y: row.pos, width: mainW, height: row.len)]
        let stackX = left + mainW + g
        for slot in splitAxis(from: frame.minY, to: frame.maxY, count: count - 1, gap: g, minLen: minCellHeight) {
            rects.append(CGRect(x: stackX, y: slot.pos, width: stackW, height: slot.len))
        }
        return rects
    }
}

/// Brücke zu Terminal.app via AppleScript (nur Automation-Berechtigung nötig,
/// keine Bedienungshilfen).
enum TerminalBridge {
    struct TermWindow {
        let id: Int
        let miniaturized: Bool
        let visible: Bool
        /// Position in der Fensterliste (1 = vorderstes Fenster)
        let zIndex: Int
    }

    static var terminalApp: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.Terminal" }
    }

    static var isTerminalRunning: Bool { terminalApp != nil }

    /// Liest alle Terminal-Fenster. `nil` = Skriptfehler (z. B. Automation verweigert).
    static func fetchWindows() -> [TermWindow]? {
        let src = """
        with timeout of 5 seconds
            tell application "Terminal"
                set out to ""
                set i to 0
                repeat with w in windows
                    set i to i + 1
                    try
                        set out to out & (id of w) & "," & (miniaturized of w) & "," & (visible of w) & "," & i & linefeed
                    end try
                end repeat
                return out
            end tell
        end timeout
        """
        guard let result = runScript(src) else { return nil }
        return result.split(separator: "\n").compactMap { line in
            let p = line.split(separator: ",")
            guard p.count == 4, let id = Int(p[0]), let z = Int(p[3]) else { return nil }
            return TermWindow(id: id, miniaturized: p[1] == "true", visible: p[2] == "true", zIndex: z)
        }
    }

    /// Bounds aller Terminal-Fenster auf gerade sichtbaren Spaces, keyed nach
    /// Fenster-ID (Terminals AppleScript-ID == CGWindowID, empirisch verifiziert).
    /// Koordinaten: global, Ursprung oben links — dasselbe System wie AppleScript.
    /// Fenster auf anderen Spaces und Vollbild-Fenster (eigener Space) fehlen hier
    /// und werden dadurch beim Anordnen in Ruhe gelassen (kein Loch im Raster).
    static func onScreenWindowBounds() -> [Int: CGRect] {
        guard let term = terminalApp,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return [:] }
        var bounds: [Int: CGRect] = [:]
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == term.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let num = w[kCGWindowNumber as String] as? Int,
                  let dict = w[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            bounds[num] = CGRect(x: dict["X"] ?? 0, y: dict["Y"] ?? 0,
                                 width: dict["Width"] ?? 0, height: dict["Height"] ?? 0)
        }
        return bounds
    }

    /// Setzt die Fenster-Bounds in einem einzigen Skriptlauf und holt Terminal nach vorn.
    /// `rect` in AppleScript-Koordinaten (Ursprung oben links am Hauptdisplay).
    static func apply(_ assignments: [(window: TermWindow, rect: CGRect)]) {
        var lines: [String] = []
        for a in assignments {
            let b = "{\(Int(a.rect.minX)), \(Int(a.rect.minY)), \(Int(a.rect.maxX)), \(Int(a.rect.maxY))}"
            var body = ""
            if a.window.miniaturized {
                body += "            set miniaturized of window id \(a.window.id) to false\n"
            }
            body += "            set bounds of window id \(a.window.id) to \(b)"
            lines.append("        try\n\(body)\n        end try")
        }
        let src = """
        with timeout of 5 seconds
            tell application "Terminal"
        \(lines.joined(separator: "\n"))
                activate
            end tell
        end timeout
        """
        _ = runScript(src)
    }

    /// Cocoa-Rect (Ursprung unten links) → AppleScript-Rect (Ursprung oben links
    /// am Hauptdisplay, y nach unten).
    static func appleScriptFrame(for cocoaRect: CGRect) -> CGRect {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? cocoaRect.maxY
        return CGRect(x: cocoaRect.minX,
                      y: primaryMaxY - cocoaRect.maxY,
                      width: cocoaRect.width,
                      height: cocoaRect.height)
    }

    private static var didShowTCCAlert = false

    @discardableResult
    static func runScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let desc = script.executeAndReturnError(&error)
        if let error {
            NSLog("TermTiler AppleScript-Fehler: \(error)")
            // -1743 = Automation verweigert; der macOS-Dialog kommt nie wieder —
            // ohne Hinweis wäre die App aus Nutzersicht dauerhaft stumm kaputt.
            if (error[NSAppleScript.errorNumber] as? Int) == -1743, !didShowTCCAlert {
                didShowTCCAlert = true
                DispatchQueue.main.async { showAutomationHint() }
            }
            return nil
        }
        return desc.stringValue ?? ""
    }

    private static func showAutomationHint() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Keine Berechtigung, Terminal zu steuern"
        alert.informativeText = """
        TermTiler darf Terminal.app nicht steuern. Bitte in Systemeinstellungen → \
        Datenschutz & Sicherheit → Automation den Schalter „TermTiler → Terminal“ aktivieren.
        """
        alert.addButton(withTitle: "Einstellungen öffnen")
        alert.addButton(withTitle: "Später")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
