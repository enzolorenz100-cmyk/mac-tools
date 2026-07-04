import Foundation

/// Startet LocalLens beim Anmelden (LaunchAgent, robust & ohne Fenster-Popup via --background).
enum AutoStart {
    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/de.enzolorenz.locallens.plist")
    }

    static func isEnabled() -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @discardableResult
    static func set(_ enable: Bool) -> Bool {
        if enable {
            let app = "/Applications/LocalLens.app/Contents/MacOS/LocalLens"
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
                <key>Label</key><string>de.enzolorenz.locallens</string>
                <key>ProgramArguments</key><array><string>\(app)</string><string>--background</string></array>
                <key>RunAtLoad</key><true/>
                <key>LimitLoadToSessionType</key><string>Aqua</string>
            </dict></plist>
            """
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try plist.write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch { Log.info("Autostart-Fehler: \(error)"); return false }
        } else {
            try? FileManager.default.removeItem(at: url)
            return true
        }
    }
}
