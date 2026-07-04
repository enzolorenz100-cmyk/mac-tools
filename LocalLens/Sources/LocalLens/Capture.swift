import AppKit
import CoreGraphics
import Foundation

/// Nimmt den Bildschirm auf (Menüleiste / Hotkey) via /usr/sbin/screencapture.
enum Capture {

    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    /// Fensterinfo der zum Zeitpunkt AKTIVEN App (nicht LocalLens selbst).
    struct Target { var windowID: CGWindowID?; var appName: String }

    /// Oberstes „echtes" Fenster, das du gerade anschaust — unabhängig vom Fokus.
    /// (Beim Menüleisten-Klick wird LocalLens kurz aktiv; deshalb NICHT auf frontmostApplication
    /// verlassen, sondern die vordere-nach-hintere Fensterliste nehmen und LocalLens/System-UI überspringen.)
    static func frontmostTarget() -> Target {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ignoredOwners: Set<String> = ["LocalLens", "Window Server", "Dock", "Control Center",
                                          "Notification Center", "Spotlight", "WindowManager"]
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                               kCGNullWindowID) as? [[String: Any]]) ?? []
        // Liste ist front→hinten sortiert: erstes normales, großes Fenster gewinnt.
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width > 120, height > 120 else { continue }   // Overlays/Tooltips überspringen
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            if ignoredOwners.contains(owner) { continue }
            return Target(windowID: id, appName: owner)
        }
        return Target(windowID: nil, appName: "")
    }

    /// Nimmt auf. mode "windowAuto" = aktives Fenster automatisch, sonst Region-Auswahl.
    static func grab(mode: String, completion: @escaping (CGImage?, String) -> Void) {
        let target = frontmostTarget()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("locallens-\(UUID().uuidString).png")

        var args: [String]
        if mode == "windowAuto" {
            if let wid = target.windowID {
                args = ["-l", String(wid), "-o", "-x", tmp.path]  // genau dieses Fenster, automatisch
            } else {
                args = ["-x", tmp.path]                            // Fallback: ganzer Screen — NIE Crosshair
            }
        } else if mode == "screen" {
            args = ["-x", tmp.path]
        } else {
            args = ["-i", tmp.path]                                // "region": bewusst interaktiv (Menüpunkt)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = args
            try? p.run(); p.waitUntilExit()

            var cg: CGImage?
            if FileManager.default.fileExists(atPath: tmp.path),
               let img = NSImage(contentsOf: tmp),
               let tiff = img.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff) {
                cg = bitmap.cgImage
            }
            try? FileManager.default.removeItem(at: tmp)
            DispatchQueue.main.async { completion(cg, target.appName) }
        }
    }
}
