import AppKit

enum LaunchError: LocalizedError {
    case claudeNotFound
    case routerFailed
    case routerTimeout
    case openFailed(String)
    case fileNotFound

    var errorDescription: String? {
        switch self {
        case .claudeNotFound: return "claude CLI nicht gefunden (erwartet in ~/.local/bin)"
        case .routerFailed: return "Automatik konnte kein Modell wählen — schalt manuell"
        case .routerTimeout: return "Automatik-Timeout — Netz ok? Schalt manuell"
        case .openFailed(let msg): return "Terminal-Start fehlgeschlagen: \(msg)"
        case .fileNotFound: return "Nichts Passendes gefunden — beschreib es anders"
        }
    }
}

enum Launcher {
    /// Effort für jede gestartete Session; das Keyword "ultracode" im Prompt
    /// aktiviert zusätzlich die Workflow-Orchestrierung für den ersten Turn.
    static let sessionEffort = "xhigh"

    private static var cachedClaudePath: String?

    static func claudePath() -> String? {
        if let c = cachedClaudePath { return c }
        let home = NSHomeDirectory()
        let candidates = [
            home + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            cachedClaudePath = c
            return c
        }
        return nil
    }

    static var scriptsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Gearbox", isDirectory: true)
    }

    // MARK: - Automatik (KI-Router via `claude -p`, läuft über das Max-Abo, kein API-Key nötig)

    struct AutoDecision {
        let gear: Gear
        let projectName: String?
        let reason: String?
    }

    static func classify(task: String, projectNames: [String]) async throws -> AutoDecision {
        guard let claude = claudePath() else { throw LaunchError.claudeNotFound }
        let projectList = projectNames.isEmpty ? "(keine)" : projectNames.joined(separator: ", ")
        let router = """
        Du bist ein Router für Coding-Aufgaben. Antworte mit GENAU einer Zeile JSON, \
        ohne Markdown, ohne weiteren Text:
        {"modell":"haiku|sonnet|opus|fable","projekt":"<Ordnername oder null>","grund":"<max 6 Wörter>"}

        modell — das kleinste Modell, das die Aufgabe sehr gut lösen kann:
        haiku = trivial, einzelne Datei, kurze Frage; sonnet = normale Aufgaben, klare Bugfixes; \
        opus = komplex, mehrere Dateien, Refactorings; fable = Architektur, sehr komplex, tiefe Recherche.
        projekt — exakt einer dieser Ordnernamen, falls die Aufgabe eindeutig dazu gehört, sonst null: \(projectList)
        grund — sehr kurze deutsche Begründung der Modellwahl.

        Aufgabe: \(task)
        """
        let out = try await run(claude,
                                args: ["-p", "--model", "haiku", "--effort", "low",
                                       "--fallback-model", "sonnet", router],
                                timeout: 60)

        if let start = out.firstIndex(of: "{"), let end = out.lastIndex(of: "}"), start < end,
           let obj = try? JSONSerialization.jsonObject(with: Data(String(out[start...end]).utf8)) as? [String: Any] {
            let modelWord = (obj["modell"] as? String ?? "").lowercased()
            let gear: Gear? = modelWord.contains("fable") ? .fable
                : modelWord.contains("opus") ? .opus
                : modelWord.contains("sonnet") ? .sonnet
                : modelWord.contains("haiku") ? .haiku : nil
            if let gear {
                var project = obj["projekt"] as? String
                if project?.lowercased() == "null" || project?.isEmpty == true { project = nil }
                return AutoDecision(gear: gear, projectName: project,
                                    reason: obj["grund"] as? String)
            }
        }
        // Fallback: Modellname irgendwo in der Antwort
        let lowered = out.lowercased()
        for (word, gear) in [("fable", Gear.fable), ("opus", .opus), ("sonnet", .sonnet), ("haiku", .haiku)]
        where lowered.contains(word) {
            return AutoDecision(gear: gear, projectName: nil, reason: nil)
        }
        throw LaunchError.routerFailed
    }

    private static func run(_ path: String, args: [String], timeout: TimeInterval) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.local/bin"
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + extra
        process.environment = env

        let outPipe = Pipe()
        process.standardOutput = outPipe
        // Warnungen verwerfen — ein ungelesenes Pipe würde ab ~64KB stderr deadlocken
        process.standardError = FileHandle.nullDevice

        try process.run()

        let once = NSLock()
        var resumed = false
        func resumeOnce(_ block: () -> Void) {
            once.lock(); defer { once.unlock() }
            guard !resumed else { return }
            resumed = true
            block()
        }

        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                resumeOnce { cont.resume(returning: String(data: data, encoding: .utf8) ?? "") }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                    resumeOnce { cont.resume(throwing: LaunchError.routerTimeout) }
                }
            }
        }
    }

    // MARK: - Terminal-Start via .command-Datei (keine Automation-Berechtigung nötig)

    static func launch(gear: Gear, modelOverride: String? = nil,
                       prompt: String, dir: String, yolo: Bool,
                       overnight: Bool = false, planFirst: Bool = false,
                       sandbox: Bool = false,
                       activate: Bool = true) async throws {
        let model = modelOverride ?? gear.modelArg
        guard gear == .resume || model != nil else {
            throw LaunchError.routerFailed
        }
        guard let claude = claudePath() else { throw LaunchError.claudeNotFound }
        trustProjectFolder(dir)
        let fm = FileManager.default
        try fm.createDirectory(at: scriptsDir, withIntermediateDirectories: true)

        let projectName = (dir as NSString).lastPathComponent
        let safeProject = String(projectName.map { $0.isLetter || $0.isNumber ? $0 : "-" }).prefix(24)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let base = "Gearbox-\(safeProject)-\(gear.chipLabel)-\(stamp)"
        let scriptURL = scriptsDir.appendingPathComponent(base + ".command")

        var promptFile: URL?
        let task = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !task.isEmpty {
            let url = scriptsDir.appendingPathComponent(base + ".prompt")
            try ("ultracode\n\n" + task).write(to: url, atomically: true, encoding: .utf8)
            promptFile = url
        }

        // Nachtschicht: caffeinate hält den Mac wach, solange die Session läuft
        var command = "exec "
        if overnight { command += "/usr/bin/caffeinate -dims " }
        command += "\(shq(claude)) --effort \(Launcher.sessionEffort)"
        if gear != .resume, let model { command += " --model \(shq(model))" }
        if gear == .resume { command += " --continue" }
        if sandbox { command += " --worktree" }
        if planFirst {
            command += " --permission-mode plan"
        } else if yolo || overnight {
            command += " --dangerously-skip-permissions"
        }
        if overnight {
            // Autonomie-Anweisung session-weit (nicht nur für den ersten Turn)
            command += " -n \(shq("🌙 Nachtschicht")) --append-system-prompt \(shq(nachtschichtSystemPrompt))"
        }
        if let promptFile { command += " \"$(cat \(shq(promptFile.path)))\"" }

        let title = "\(projectName) · \(gear.chipLabel)"
        let script = """
        #!/bin/bash
        clear
        printf '\\033]2;%s\\007' \(shq(title))
        cd \(shq(dir)) || { echo 'Gearbox: Projektordner nicht gefunden.'; exec /bin/zsh; }
        \(command)
        """
        try (script + "\n").write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        return try await withCheckedThrowingContinuation { cont in
            NSWorkspace.shared.open([scriptURL], withApplicationAt: terminal,
                                    configuration: configuration) { _, error in
                if let error {
                    cont.resume(throwing: LaunchError.openFailed(error.localizedDescription))
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }

    // MARK: - Session-Cockpit (laufende Claude-Sessions)

    struct AgentSession: Identifiable, Equatable {
        let id: String
        let pid: Int
        let cwd: String
        let kind: String
        let name: String?
        let status: String   // "busy" = arbeitet, "idle" = wartet auf Input
        let state: String?   // Background-Agents: z. B. "blocked"
        let aiTitle: String? // KI-generierte Kurzfassung des Sessioninhalts
    }

    /// Läuft in ~0,2 s — `claude agents --json` listet alle Sessions inkl. Status.
    static func listSessions() async throws -> [AgentSession] {
        guard let claude = claudePath() else { throw LaunchError.claudeNotFound }
        let out = try await run(claude, args: ["agents", "--json"], timeout: 15)
        guard let start = out.firstIndex(of: "["),
              let array = try? JSONSerialization.jsonObject(with: Data(String(out[start...]).utf8)) as? [[String: Any]]
        else { return [] }
        return array.compactMap { dict in
            guard let sessionId = dict["sessionId"] as? String,
                  let cwd = dict["cwd"] as? String,
                  let status = dict["status"] as? String else { return nil }
            return AgentSession(id: sessionId,
                                pid: dict["pid"] as? Int ?? 0,
                                cwd: cwd,
                                kind: dict["kind"] as? String ?? "interactive",
                                name: dict["name"] as? String,
                                status: status,
                                state: dict["state"] as? String,
                                aiTitle: readAiTitle(sessionId: sessionId, cwd: cwd))
        }
    }

    /// Liest den zuletzt generierten KI-Titel aus dem Session-Transcript — Claude Code
    /// schreibt ihn als laufend aktualisierte "ai-title"-Zeile in
    /// ~/.claude/projects/<cwd mit "-" statt "/">/<sessionId>.jsonl.
    private static func readAiTitle(sessionId: String, cwd: String) -> String? {
        let encodedCwd = cwd.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(encodedCwd)/\(sessionId).jsonl")
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "ai-title",
                  let title = obj["aiTitle"] as? String, !title.isEmpty else { continue }
            return title
        }
        return nil
    }

    /// Terminal-Fenster der Session nach vorn holen (best effort über den
    /// Fenstertitel; braucht einmalig die Automation-Erlaubnis für Terminal).
    static func focusTerminal(matching hint: String) {
        let safeHint = hint
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            repeat with w in windows
                if name of w contains "\(safeHint)" then
                    set index of w to 1
                    exit repeat
                end if
            end repeat
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }

    // MARK: - Desktop Finder (Datei per Beschreibung finden)

    /// Agentische KI-Suche: Haiku sucht headless mit mdfind/Glob/Grep/Read die
    /// Datei, die zur Beschreibung passt, und gibt den absoluten Pfad zurück.
    static func findFile(description: String) async throws -> String {
        guard let claude = claudePath() else { throw LaunchError.claudeNotFound }
        // Gerätebesitzer dynamisch — hartkodierter Name würde auf fremden Macs
        // die „mein/meine"-Zuordnung an die falsche Person binden
        let owner = NSFullUserName()
        let prompt = """
        Du bist eine intelligente Datei-Suche auf dem Mac von \(owner). Er/sie \
        beschreibt eine Datei — kennt den Dateinamen aber NICHT. Finde die EINE am \
        besten passende Datei.

        Suchbereiche (inkl. Unterordner): ~/Desktop, ~/Documents, ~/Downloads
        Vorgehen:
        1. Leite aus der Beschreibung mehrere Suchbegriffe ab (deutsch UND englisch, Synonyme).
        2. Suche mit mdfind -onlyin je Bereich (Spotlight indiziert auch Dateiinhalte). \
        Ergänze gezielte ls/Glob-Blicke in thematisch passende Ordner.
        3. Sammle ALLE Kandidaten. Wenn mehrere passen: vergleiche jeden Kandidaten \
        gegen JEDES Detail der Beschreibung — wessen Dokument ist es („mein/meine" = \
        \(owner) selbst, nicht Familienmitglieder), welcher Zeitraum, welcher \
        Kontext/Anlass. Im Zweifel schau per Read/Grep in die Kandidaten rein, statt zu raten.
        4. Bevorzuge Dokumente und Bilder; ignoriere Systemdateien und .DS_Store.

        Antworte am ENDE mit GENAU einer Zeile: dem absoluten Pfad der besten Datei.
        Wenn wirklich nichts passt: NOT_FOUND

        Beschreibung: \(description)
        """
        // Prompt MUSS vor --allowedTools stehen — das variadische Flag frisst
        // sonst alle folgenden Argumente inklusive Prompt
        let out = try await run(claude, args: [
            "-p", prompt,
            "--model", "haiku", "--effort", "low",
            "--allowedTools", "Bash(mdfind *),Bash(ls *),Bash(find *),Glob,Grep,Read",
        ], timeout: 120)

        let fm = FileManager.default
        for line in out.split(separator: "\n").reversed() {
            var path = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            if path.hasPrefix("~") { path = NSHomeDirectory() + path.dropFirst() }
            var isDir: ObjCBool = false
            if path.hasPrefix("/"), fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                return path
            }
        }
        throw LaunchError.fileNotFound
    }

    /// Session-weite Anweisung für den Nachtschicht-Modus (wie /goal, nur ab Start).
    private static let nachtschichtSystemPrompt = """
    Nachtschicht-Modus: Du arbeitest unbeaufsichtigt über Nacht. Arbeite vollständig \
    autonom bis zum fertigen, verifizierten Ergebnis. Frag nie nach Bestätigung — \
    triff sinnvolle Entscheidungen selbst. Beende deinen Turn nie mit offenen Plänen \
    oder Fragen: führe sie aus. Verifiziere dein Ergebnis am Ende selbst (Tests, \
    Build, Sichtprüfung) und dokumentiere abschließend präzise: was getan wurde, \
    was funktioniert, was offen ist.
    """

    /// Ordner in ~/.claude.json als vertrauenswürdig markieren, damit beim Start
    /// kein "Trust this folder"-Dialog mehr kommt.
    static func trustProjectFolder(_ dir: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        var projects = root["projects"] as? [String: Any] ?? [:]
        var entry = projects[dir] as? [String: Any] ?? [:]
        if entry["hasTrustDialogAccepted"] as? Bool == true { return }
        entry["hasTrustDialogAccepted"] = true
        projects[dir] = entry
        root["projects"] = projects
        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) {
            try? out.write(to: url, options: .atomic)
        }
    }

    /// Alte Start-Skripte (>24h) aufräumen.
    static func cleanupOldScripts() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: scriptsDir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for f in files where f.lastPathComponent.hasPrefix("Gearbox-") {
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, date < cutoff { try? fm.removeItem(at: f) }
        }
    }

    private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
