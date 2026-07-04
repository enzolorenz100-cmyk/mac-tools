import SwiftUI

/// Satelliten-Panel unter dem DesktopCleaner: Datei per Beschreibung finden & öffnen.
/// Kein Dateiname nötig — eine KI-Suche (claude -p, Haiku) sucht per Spotlight,
/// Glob und Inhalts-Blick die passende Datei.
struct DesktopFinderView: View {
    enum FinderStatus: Equatable {
        case idle
        case searching
        case done
        case error
    }

    @State private var query = ""
    @State private var status: FinderStatus = .idle
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.zentraleBlau.opacity(0.22)))
                .overlay(Circle().stroke(Color.zentraleBlau.opacity(0.75), lineWidth: 1.5))
            Text("DESKTOP FINDER")
                .font(.system(size: 9.5, weight: .black, design: .monospaced))
                .tracking(2.5)
                .foregroundStyle(.white)
                .fixedSize()
            TextField("", text: $query,
                      prompt: Text("Beschreib die Datei — ich finde & öffne sie …")
                          .foregroundStyle(Color.zentraleGrauTertiär))
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Color(white: 0.95))
                .focused($focused)
                .onSubmit(search)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.07)))
                .overlay(Capsule().stroke(focused ? Color.zentraleBlau.opacity(0.6) : .white.opacity(0.12),
                                          lineWidth: 1))
            Button(action: startDictation) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.zentraleGrauSekundär)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Beschreibung diktieren")
            Button(action: search) {
                Group {
                    switch status {
                    case .idle:
                        Image(systemName: "arrow.right")
                    case .searching:
                        ProgressView().controlSize(.mini)
                    case .done:
                        Image(systemName: "checkmark.circle.fill")
                    case .error:
                        Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 11, weight: .bold))
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: [Color.zentraleBlau.opacity(0.9),
                                                      Color.zentraleBlau.opacity(0.6)],
                                             startPoint: .top, endPoint: .bottom))
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(status == .searching)
            .help("Suchen und öffnen (oder Enter im Feld)")
        }
        .padding(12)
        .frame(width: 684) // Breite der Schaltzentrale
        .preferredColorScheme(.dark)
    }

    private func startDictation() {
        focused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
        }
    }

    private func search() {
        let description = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty, status != .searching else { return }
        status = .searching
        Task { @MainActor in
            do {
                let path = try await Launcher.findFile(description: description)
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                status = .done
                query = ""
            } catch {
                status = .error
            }
            try? await Task.sleep(for: .seconds(4))
            if status != .searching { status = .idle }
        }
    }
}
