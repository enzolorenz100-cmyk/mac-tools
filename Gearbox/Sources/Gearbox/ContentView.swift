import SwiftUI
import ServiceManagement

extension Notification.Name {
    static let gearboxLaunch = Notification.Name("gearboxLaunch")
    static let gearboxLaunchBackground = Notification.Name("gearboxLaunchBackground")
    static let gearboxLevelChanged = Notification.Name("gearboxLevelChanged")
    static let gearboxFocusPrompt = Notification.Name("gearboxFocusPrompt")
    static let gearboxSetGear = Notification.Name("gearboxSetGear")
    static let gearboxHistory = Notification.Name("gearboxHistory")
}

enum LaunchStatus: Equatable {
    case idle
    case classifying
    case launching(Gear)
    case done(Gear)
    case error(String)
}

struct ContentView: View {
    @AppStorage("gearRaw") private var gearRaw = Gear.auto.rawValue
    @AppStorage("projectPath") private var projectPath = NSHomeDirectory()
    @AppStorage("yolo") private var yolo = false
    @AppStorage("overnight") private var overnight = false
    @AppStorage("planFirst") private var planFirst = false
    @AppStorage("sandbox") private var sandbox = false
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false
    @AppStorage("recentProjects") private var recentProjectsJoined = ""
    @AppStorage("projectPrefs") private var projectPrefsJSON = "{}"
    @AppStorage("promptHistory") private var promptHistoryJSON = "[]"

    @State private var prompt = ""
    @State private var status: LaunchStatus = .idle
    @State private var displayGear: Gear?
    @State private var desktopFolders: [String] = []
    @State private var loginItemEnabled = SMAppService.mainApp.status == .enabled
    @State private var historyIndex: Int?
    @State private var draftBeforeHistory = ""
    @State private var restoringFromHistory = false
    @State private var infoMessage: String?
    @AppStorage("gearModelOverrides") private var gearOverridesJSON = "{}"
    @FocusState private var promptFocused: Bool

    private var gear: Gear { Gear(rawValue: gearRaw) ?? .auto }
    private var busy: Bool {
        if case .classifying = status { return true }
        if case .launching = status { return true }
        return false
    }

    var body: some View {
        // Zwei Spalten: Getriebe links, Bedienung rechts — passt neben die
        // nativen Widgets (gleiche Höhe wie Kalender+Foto-Block)
        HStack(alignment: .center, spacing: 16) {
            GearShifterView(gearRaw: $gearRaw, displayGear: $displayGear, enabled: !busy)
                .frame(width: 340)
            VStack(spacing: 8) {
                header
                gearCard
                projectPicker
                HStack(spacing: 5) {
                    toggleChip("YOLO", icon: "bolt.fill", isOn: $yolo,
                               help: "Skip Permissions — Claude arbeitet ohne Rückfragen")
                    toggleChip("Nacht", icon: "moon.stars.fill", isOn: $overnight,
                               help: "Nachtschicht: Mac bleibt wach (caffeinate), keine Rückfragen, Claude arbeitet autonom bis fertig, verifiziert und dokumentiert alles")
                    toggleChip("Plan", icon: "list.bullet.clipboard", isOn: $planFirst,
                               help: "Claude plant erst und wartet auf dein OK, bevor er loslegt")
                    toggleChip("Sandbox", icon: "shippingbox.fill", isOn: $sandbox,
                               help: "Git-Worktree: Claude arbeitet auf einer isolierten Kopie des Repos — parallele Sessions kommen sich nicht in die Quere (nur in Git-Projekten)")
                    Spacer(minLength: 0)
                }
                promptEditor
                launchButton
                statusLine
            }
            .frame(width: 300)
        }
        .padding(14)
        .preferredColorScheme(.dark)
        .onAppear { desktopFolders = Self.scanDesktopFolders() }
        .onReceive(NotificationCenter.default.publisher(for: .gearboxLaunch)) { _ in
            startLaunch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gearboxLaunchBackground)) { _ in
            startLaunch(background: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .gearboxFocusPrompt)) { _ in
            promptFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .gearboxSetGear)) { note in
            guard !busy, let raw = note.object as? Int, let newGear = Gear(rawValue: raw) else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.65)) {
                displayGear = nil
                gearRaw = newGear.rawValue
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gearboxHistory)) { note in
            cycleHistory(direction: note.object as? Int ?? -1)
        }
        .onChange(of: projectPath) { _, newPath in
            applyProjectPrefs(for: newPath)
        }
        .onChange(of: prompt) { _, _ in
            if restoringFromHistory { restoringFromHistory = false } else { historyIndex = nil }
        }
        // Modi schließen sich aus: Plan ⟷ (YOLO/Nachtschicht); Nachtschicht braucht YOLO
        .onChange(of: planFirst) { _, on in
            if on { yolo = false; overnight = false }
        }
        .onChange(of: overnight) { _, on in
            if on { planFirst = false; yolo = true }
        }
        .onChange(of: yolo) { _, on in
            if !on { overnight = false }
        }
    }

    private func toggleChip(_ label: String, icon: String, isOn: Binding<Bool>,
                            help: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isOn.wrappedValue ? Color.zentraleBlau : .white.opacity(0.06))
            )
            .overlay(
                Capsule().stroke(isOn.wrappedValue ? Color.zentraleBlau.opacity(0.9) : .white.opacity(0.14),
                                 lineWidth: 1)
            )
            .foregroundStyle(isOn.wrappedValue ? .white : Color.zentraleGrauSekundär)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.zentraleGrauTertiär)
            Text("SCHALTZENTRALE")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(2.5)
                .foregroundStyle(.white)
            Spacer()
            Button {
                alwaysOnTop.toggle()
                NotificationCenter.default.post(name: .gearboxLevelChanged, object: nil)
            } label: {
                Image(systemName: alwaysOnTop ? "pin.fill" : "pin.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(alwaysOnTop ? Color.cyan : Color.zentraleGrauSekundär)
            }
            .buttonStyle(.plain)
            .help(alwaysOnTop ? "Schwebt über allen Fenstern" : "Liegt auf dem Desktop")
            Menu {
                Toggle("Bei Login starten", isOn: Binding(
                    get: { loginItemEnabled },
                    set: { setLoginItem($0) }
                ))
                Divider()
                Button("Gearbox beenden") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.zentraleGrauSekundär)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .background(WindowDragHandle())
    }

    private var gearCard: some View {
        let shown = displayGear ?? gear
        let override = overrideModel(for: shown)
        return HStack(spacing: 10) {
            Text(shown.symbol)
                .font(.system(size: 20, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(shown.color.opacity(0.14)))
                .overlay(Circle().stroke(shown.color.opacity(0.5), lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(shown.name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Text(override.map { "Version: \($0)" } ?? shown.tagline)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.zentraleGrauSekundär)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.055)))
        .contextMenu { versionMenu(for: shown) }
        .help("Rechtsklick: ältere Modell-Versionen wählen")
    }

    // MARK: - Modell-Versionen (Rechtsklick auf die Gang-Karte)

    private static let modelVersions: [Gear: [(label: String, id: String?)]] = [
        .haiku: [("Haiku 4.5 (neueste)", nil)],
        .sonnet: [("Sonnet 5 (neueste)", nil),
                  ("Sonnet 4.6", "claude-sonnet-4-6"),
                  ("Sonnet 4.5", "claude-sonnet-4-5")],
        .opus: [("Opus 4.8 (neueste)", nil),
                ("Opus 4.7", "claude-opus-4-7"),
                ("Opus 4.6", "claude-opus-4-6"),
                ("Opus 4.5", "claude-opus-4-5")],
        .fable: [("Fable 5 · 1M (Standard)", nil),
                 ("Fable 5", "claude-fable-5")],
    ]

    @ViewBuilder
    private func versionMenu(for shown: Gear) -> some View {
        if let versions = Self.modelVersions[shown] {
            Text("Modell-Version für Gang \(shown.symbol)")
            ForEach(versions, id: \.label) { version in
                Button {
                    setOverrideModel(version.id, for: shown)
                } label: {
                    if overrideModel(for: shown) == version.id {
                        Label(version.label, systemImage: "checkmark")
                    } else {
                        Text(version.label)
                    }
                }
            }
        } else {
            Text("Für \(shown.name) gibt es keine Versionswahl")
        }
    }

    private func overrideModel(for gear: Gear) -> String? {
        let dict = (try? JSONSerialization.jsonObject(with: Data(gearOverridesJSON.utf8))) as? [String: String] ?? [:]
        return dict[String(gear.rawValue)]
    }

    private func setOverrideModel(_ model: String?, for gear: Gear) {
        var dict = (try? JSONSerialization.jsonObject(with: Data(gearOverridesJSON.utf8))) as? [String: String] ?? [:]
        dict[String(gear.rawValue)] = model
        if model == nil { dict.removeValue(forKey: String(gear.rawValue)) }
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            gearOverridesJSON = String(decoding: data, as: UTF8.self)
        }
    }

    private var projectPicker: some View {
        Menu {
            ForEach(projectMenuEntries, id: \.self) { path in
                Button {
                    projectPath = path
                } label: {
                    Label(Self.displayName(for: path),
                          systemImage: path == projectPath ? "checkmark" : "folder")
                }
            }
            Divider()
            Button("Anderer Ordner…") { chooseFolder() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.zentraleGrauSekundär)
                // EIN Text-Wert, nicht zwei Views: der native NSPopUpButton
                // hinter .menuStyle(.borderlessButton) rendert vom Label nur
                // den ERSTEN Text — ein zweites Geschwister-Text (ob in einem
                // VStack oder HStack) verschwand komplett, unabhängig von
                // Farbe/Größe/Inhalt (per Screenshot-Test verifiziert). Text-
                // Konkatenation (+) erzeugt einen einzigen Text-Wert und
                // entgeht dem Problem.
                (Text(Self.displayName(for: projectPath))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white)
                 + Text("  " + Self.abbreviate(projectPath))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.zentraleGrauTertiär))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.zentraleGrauTertiär)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.055)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private var projectMenuEntries: [String] {
        var seen = Set<String>()
        var entries: [String] = []
        for path in recentProjects + desktopFolders + [NSHomeDirectory()] {
            if seen.insert(path).inserted, FileManager.default.fileExists(atPath: path) {
                entries.append(path)
            }
        }
        return entries
    }

    // MARK: - Prompt & Start

    private var promptEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $prompt)
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.95))
                .scrollContentBackground(.hidden)
                .focused($promptFocused)
                .padding(.leading, 6)
                .padding(.vertical, 4)
                .padding(.trailing, 36) // Platz für den Mikro-Button
                .frame(height: 58)
            if prompt.isEmpty {
                Text("Aufgabe diktieren oder tippen …\n(leer = nur Terminal öffnen)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.zentraleGrauTertiär)
                    .padding(.top, 14)
                    .padding(.leading, 12)
                    .padding(.trailing, 40)
                    .allowsHitTesting(false)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(promptFocused ? gear.color.opacity(0.5) : .white.opacity(0.08), lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            Button(action: startDictation) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.zentraleGrauSekundär)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .padding(6)
            .help("Diktat ins Aufgabenfeld starten (Wispr Flow funktioniert genauso)")
        }
    }

    private func startDictation() {
        promptFocused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
        }
    }

    private var launchButton: some View {
        Button(action: { startLaunch() }) {
            HStack(spacing: 8) {
                switch status {
                case .classifying:
                    ProgressView().controlSize(.small)
                    Text("Automatik wählt Modell …")
                case .launching(let g):
                    ProgressView().controlSize(.small)
                    Text("\(g.name) startet …")
                case .done(let g):
                    Image(systemName: "checkmark.circle.fill")
                    Text("\(g.name) läuft im Terminal")
                default:
                    Image(systemName: "play.fill")
                    Text("Start")
                    Text(gear.symbol)
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.black.opacity(0.35)))
                    Text("⌘⏎")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .font(.system(size: 13, weight: .bold))
            .frame(maxWidth: .infinity)
            .frame(height: 34)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [Color.zentraleBlau.opacity(0.95),
                                              Color.zentraleBlau.opacity(0.6)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .foregroundStyle(.white)
        .disabled(busy)
        .opacity(busy ? 0.75 : 1)
    }

    private var statusLine: some View {
        Group {
            if case .error(let message) = status {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let infoMessage {
                Text(infoMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.zentraleGrauSekundär)
                    .lineLimit(2)
            } else {
                Text("⚡ ultracode immer aktiv · ⌘⏎ startet")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.zentraleGrauTertiär)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func startLaunch(background: Bool = false) {
        guard !busy else { return }
        let task = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        // Status synchron setzen, bevor der Task anläuft — sonst kann ein zweites
        // ⌘⏎ im selben Runloop-Tick den busy-Guard passieren und doppelt starten.
        if gear == .auto {
            guard !task.isEmpty else {
                status = .error("Automatik braucht eine Aufgabe — oder schalt manuell.")
                scheduleStatusReset(after: 5)
                return
            }
            status = .classifying
        } else {
            status = .launching(gear)
        }

        // Modi vor einem evtl. Automatik-Projektwechsel einfrieren — der Wechsel
        // stellt Projekt-Prefs wieder her und würde sonst still den Modus ändern
        let useYolo = yolo
        let useOvernight = overnight
        let usePlan = planFirst
        let useSandbox = sandbox

        Task { @MainActor in
            do {
                var resolved = gear
                var targetDir = projectPath
                if resolved == .auto {
                    let names = projectMenuEntries.map { Self.displayName(for: $0) }
                    let decision = try await Launcher.classify(task: task, projectNames: names)
                    resolved = decision.gear
                    if let name = decision.projectName,
                       let path = projectMenuEntries.first(where: {
                           Self.displayName(for: $0).caseInsensitiveCompare(name) == .orderedSame
                       }) {
                        targetDir = path
                        projectPath = path
                    }
                    var info = "Automatik: \(resolved.name)"
                    if let name = decision.projectName { info += " → \(name)" }
                    if let reason = decision.reason { info += " (\(reason))" }
                    infoMessage = info
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        displayGear = resolved
                    }
                    status = .launching(resolved)
                }
                try await Launcher.launch(gear: resolved,
                                          modelOverride: overrideModel(for: resolved),
                                          prompt: task,
                                          dir: targetDir, yolo: useYolo,
                                          overnight: useOvernight, planFirst: usePlan,
                                          sandbox: useSandbox,
                                          activate: !background)
                status = .done(resolved)
                if prompt.trimmingCharacters(in: .whitespacesAndNewlines) == task {
                    prompt = ""
                }
                addRecentProject(targetDir)
                saveProjectPrefs()
                addToHistory(task)
                scheduleStatusReset(after: 6)
            } catch {
                status = .error(error.localizedDescription)
                infoMessage = nil
                withAnimation { displayGear = nil }
                scheduleStatusReset(after: 6)
            }
        }
    }

    private func scheduleStatusReset(after seconds: Double) {
        let snapshot = status
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if status == snapshot {
                withAnimation {
                    status = .idle
                    displayGear = nil
                    infoMessage = nil
                }
            }
        }
    }

    // MARK: - Per-Projekt-Gedächtnis (Gang + YOLO)

    private func saveProjectPrefs() {
        var prefs = (try? JSONSerialization.jsonObject(with: Data(projectPrefsJSON.utf8))) as? [String: [String: Int]] ?? [:]
        prefs[projectPath] = ["gear": gearRaw, "yolo": yolo ? 1 : 0]
        if let data = try? JSONSerialization.data(withJSONObject: prefs) {
            projectPrefsJSON = String(decoding: data, as: UTF8.self)
        }
    }

    private func applyProjectPrefs(for path: String) {
        let prefs = (try? JSONSerialization.jsonObject(with: Data(projectPrefsJSON.utf8))) as? [String: [String: Int]] ?? [:]
        guard let saved = prefs[path] else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.65)) {
            displayGear = nil
            if let g = saved["gear"], Gear(rawValue: g) != nil { gearRaw = g }
            yolo = saved["yolo"] == 1
        }
    }

    // MARK: - Prompt-History (⌘↑/⌘↓)

    private var promptHistory: [String] {
        (try? JSONSerialization.jsonObject(with: Data(promptHistoryJSON.utf8))) as? [String] ?? []
    }

    private func addToHistory(_ task: String) {
        guard !task.isEmpty else { return }
        var history = promptHistory.filter { $0 != task }
        history.insert(task, at: 0)
        if let data = try? JSONSerialization.data(withJSONObject: Array(history.prefix(20))) {
            promptHistoryJSON = String(decoding: data, as: UTF8.self)
        }
        historyIndex = nil
    }

    private func cycleHistory(direction: Int) {
        let history = promptHistory
        guard !history.isEmpty else { return }
        var newIndex: Int?
        switch (historyIndex, direction) {
        case (nil, -1):
            draftBeforeHistory = prompt
            newIndex = 0
        case (let i?, -1):
            newIndex = min(i + 1, history.count - 1)
        case (let i?, 1):
            newIndex = i > 0 ? i - 1 : nil
        default:
            return
        }
        restoringFromHistory = true
        if let newIndex {
            prompt = history[newIndex]
        } else {
            prompt = draftBeforeHistory
        }
        historyIndex = newIndex
    }

    // MARK: - Projekte

    private var recentProjects: [String] {
        recentProjectsJoined.split(separator: "\n").map(String.init)
    }

    private func addRecentProject(_ path: String) {
        var recents = recentProjects.filter { $0 != path }
        recents.insert(path, at: 0)
        recentProjectsJoined = recents.prefix(5).joined(separator: "\n")
    }

    private func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: projectPath)
        panel.level = .modalPanel
        if panel.runModal() == .OK, let url = panel.url {
            projectPath = url.path
            addRecentProject(url.path)
        }
    }

    private static func scanDesktopFolders() -> [String] {
        let desktop = NSHomeDirectory() + "/Desktop"
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: desktop) else { return [] }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .compactMap { name in
                guard !name.hasPrefix(".") else { return nil }
                let path = desktop + "/" + name
                var isDir: ObjCBool = false
                fm.fileExists(atPath: path, isDirectory: &isDir)
                return isDir.boolValue ? path : nil
            }
    }

    private static func displayName(for path: String) -> String {
        path == NSHomeDirectory() ? "Home (~)" : (path as NSString).lastPathComponent
    }

    private static func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Login Item

    private func setLoginItem(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            loginItemEnabled = SMAppService.mainApp.status == .enabled
            status = .error("Login-Item: \(error.localizedDescription)")
            scheduleStatusReset(after: 6)
        }
    }
}
