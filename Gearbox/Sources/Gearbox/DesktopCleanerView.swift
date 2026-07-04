import SwiftUI

enum CleanerStatus: Equatable {
    case idle
    case running
    case done
    case error
}

/// Angedocktes Satelliten-Panel unter dem Hauptwidget: startet ~/DesktopCleaner/cleanup.sh.
struct DesktopCleanerView: View {
    @State private var status: CleanerStatus = .idle

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.zentraleBlau.opacity(0.22)))
                .overlay(Circle().stroke(Color.zentraleBlau.opacity(0.75), lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 2) {
                Text("DESKTOP CLEANER")
                    .font(.system(size: 9.5, weight: .black, design: .monospaced))
                    .tracking(2.5)
                    .foregroundStyle(.white)
                Text("Sortiert Screenshots, PDFs & Doks per KI — löscht nie")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.zentraleGrauTertiär)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("⌃⌥L")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.zentraleBlau.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.zentraleBlau.opacity(0.5), lineWidth: 1))
                .foregroundStyle(.white)
                .help("Globaler Hotkey: Ctrl + Option + L — räumt den Desktop von überall auf")
            Button(action: { runScript("undo.sh") }) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white.opacity(0.08)))
                    .foregroundStyle(Color.zentraleGrauSekundär)
            }
            .buttonStyle(.plain)
            .disabled(status == .running)
            .help("Letzten Aufräumlauf rückgängig machen — alle Dateien wandern zurück auf den Desktop")
            Button(action: { runScript("cleanup.sh") }) {
                Group {
                    switch status {
                    case .idle:
                        Image(systemName: "play.fill")
                    case .running:
                        ProgressView().controlSize(.mini)
                    case .done:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.zentraleBlauHell)
                    case .error:
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 11, weight: .bold))
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: [Color.zentraleBlau.opacity(0.85), Color.zentraleBlau.opacity(0.55)],
                                             startPoint: .top, endPoint: .bottom))
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(status == .running)
            .help("Desktop jetzt aufräumen (gleiche Wirkung wie ⌃⌥L)")
        }
        .padding(12)
        .frame(width: 684) // Breite der Schaltzentrale (zwei Spalten)
        .preferredColorScheme(.dark)
    }

    private func runScript(_ name: String) {
        guard status != .running else { return }
        status = .running
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [NSHomeDirectory() + "/DesktopCleaner/" + name]
        // Skript loggt selbst nach ~/DesktopCleaner/logs/ — Pipes ohne Reader würden deadlocken
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { proc in
            DispatchQueue.main.async {
                status = proc.terminationStatus == 0 ? .done : .error
                scheduleReset()
            }
        }
        do {
            try process.run()
        } catch {
            status = .error
            scheduleReset()
        }
    }

    private func scheduleReset() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if status != .running { status = .idle }
        }
    }
}
