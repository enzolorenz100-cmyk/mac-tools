import SwiftUI

/// Satelliten-Panel: Live-Übersicht aller laufenden Claude-Sessions, eine
/// Zeile pro Session — das Panel wächst nach unten, damit IMMER alle
/// sichtbar sind (kein "+N" mehr, das etwas versteckt).
/// Orange = wartet auf Input („braucht dich"), Blau = arbeitet gerade.
/// Klick auf eine Zeile holt das zugehörige Terminal-Fenster nach vorn.
struct SessionCockpitView: View {
    @State private var sessions: [Launcher.AgentSession] = []
    @State private var refreshing = false

    /// Wird nach jeder Sessionzahl-Änderung mit der neuen Ideal-Höhe des
    /// Inhalts aufgerufen, damit `main.swift` das echte AppKit-Fenster
    /// entsprechend nach unten wachsen lassen kann.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    private let timer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    // Row-Geometrie — muss zur Formel in main.swift (resizeCockpitPanel) passen.
    private static let emptyHeight: CGFloat = 54
    private static let headerRowHeight: CGFloat = 30
    private static let rowHeight: CGFloat = 28
    private static let rowSpacing: CGFloat = 6
    private static let verticalPadding: CGFloat = 24 // 12 oben + 12 unten

    /// Wartende zuerst — die brauchen Aufmerksamkeit.
    private var sorted: [Launcher.AgentSession] {
        sessions.sorted { a, b in
            if a.status != b.status { return a.status == "idle" }
            return a.pid > b.pid
        }
    }

    static func idealHeight(forRowCount count: Int) -> CGFloat {
        guard count > 0 else { return emptyHeight }
        return verticalPadding + headerRowHeight
            + CGFloat(count) * rowHeight + CGFloat(count) * rowSpacing
    }

    private var idealHeight: CGFloat { Self.idealHeight(forRowCount: sorted.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            header
            ForEach(sorted) { session in
                row(session)
            }
        }
        .padding(12)
        .frame(width: 684, alignment: .top) // Breite der Schaltzentrale
        .preferredColorScheme(.dark)
        .onAppear {
            refresh()
            onHeightChange(idealHeight)
        }
        .onReceive(timer) { _ in refresh() }
        .onChange(of: sorted.count) { _, _ in onHeightChange(idealHeight) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.zentraleBlau.opacity(0.22)))
                .overlay(Circle().stroke(Color.zentraleBlau.opacity(0.75), lineWidth: 1.5))
            Text("SESSION COCKPIT")
                .font(.system(size: 9.5, weight: .black, design: .monospaced))
                .tracking(2.5)
                .foregroundStyle(.white)
                .fixedSize()
            if sorted.isEmpty {
                Text("keine aktiven Claude-Sessions")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.zentraleGrauTertiär)
            }
            Spacer(minLength: 0)
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.white.opacity(0.08)))
                    .foregroundStyle(Color.zentraleGrauSekundär)
                    .opacity(refreshing ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .help("Jetzt aktualisieren (läuft automatisch alle 8 s)")
        }
    }

    private func row(_ session: Launcher.AgentSession) -> some View {
        let color = statusColor(session)
        return Button {
            Launcher.focusTerminal(matching: terminalMatchHint(session))
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(displayLabel(session))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(terminalMatchHint(session))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.zentraleGrauTertiär)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(statusText(session))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
            .foregroundStyle(.white)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("\(session.cwd)\n\(statusText(session)) — Klick holt das Terminal nach vorn")
    }

    private func statusColor(_ session: Launcher.AgentSession) -> Color {
        if session.state == "blocked" { return .red }
        return session.status == "busy" ? .zentraleBlauHell : .orange
    }

    private func statusText(_ session: Launcher.AgentSession) -> String {
        if session.state == "blocked" { return "blockiert" }
        return session.status == "busy" ? "arbeitet" : "wartet auf dich"
    }

    /// Anzeige-Text: bevorzugt die KI-generierte Kurzfassung des Sessioninhalts
    /// (statt der kryptischen Session-Suffixe wie „gearbox-5b").
    private func displayLabel(_ session: Launcher.AgentSession) -> String {
        if let title = session.aiTitle, !title.isEmpty { return title }
        if let name = session.name, !name.isEmpty { return name }
        let folder = (session.cwd as NSString).lastPathComponent
        return folder == (NSHomeDirectory() as NSString).lastPathComponent ? "Home" : folder
    }

    /// Muss zum Fenstertitel passen, den `Launcher.launch` gesetzt hat
    /// ("<Ordnername> · <GEAR>") — nicht der hübsche Anzeige-Text, sonst
    /// findet die AppleScript-Suche das Terminal-Fenster nie.
    private func terminalMatchHint(_ session: Launcher.AgentSession) -> String {
        (session.cwd as NSString).lastPathComponent
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task { @MainActor in
            defer { refreshing = false }
            if let result = try? await Launcher.listSessions() {
                // Nur echte Terminal-Sessions — Background-Agents haben kein
                // Fenster zum Fokussieren und gehören nicht zu „meinen offenen
                // Sessions" im Sinn dieses Widgets.
                sessions = result.filter { $0.kind == "interactive" }
            }
        }
    }
}
