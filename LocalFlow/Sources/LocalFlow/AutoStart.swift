import Foundation
import ServiceManagement

/// Startet LocalFlow automatisch beim Anmelden.
/// Bevorzugt die moderne SMAppService-API (erscheint in Systemeinstellungen › Anmeldeobjekte);
/// fällt auf einen LaunchAgent-plist zurück, falls die Registrierung scheitert.
enum AutoStart {
    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/de.enzolorenz.localflow.plist")
    }

    // Bewusst LaunchAgent statt SMAppService: SMAppService.register() kann sich beim direkten
    // Binary-Aufruf aufhängen; der LaunchAgent ist robust, verifizierbar und startet ohne Fenster.
    static func set(_ enable: Bool) -> Bool {
        enable ? installLaunchAgent() : removeLaunchAgent()
    }

    static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    static func statusText() -> String {
        isEnabled() ? "aktiv (LaunchAgent)" : "aus"
    }

    // MARK: - LaunchAgent-Fallback

    private static func installLaunchAgent() -> Bool {
        let appPath = "/Applications/LocalFlow.app/Contents/MacOS/LocalFlow"
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>de.enzolorenz.localflow</string>
            <key>ProgramArguments</key><array><string>\(appPath)</string><string>--background</string></array>
            <key>RunAtLoad</key><true/>
            <key>ProcessType</key><string>Interactive</string>
            <key>LimitLoadToSessionType</key><string>Aqua</string>
        </dict>
        </plist>
        """
        do {
            try FileManager.default.createDirectory(
                at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try plist.write(to: launchAgentURL, atomically: true, encoding: .utf8)
            Log.info("Autostart via LaunchAgent installiert: \(launchAgentURL.path)")
            return true
        } catch {
            Log.error("LaunchAgent installieren fehlgeschlagen: \(error)")
            return false
        }
    }

    private static func removeLaunchAgent() -> Bool {
        try? FileManager.default.removeItem(at: launchAgentURL)
        return true
    }
}
