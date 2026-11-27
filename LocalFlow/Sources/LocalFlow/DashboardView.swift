import SwiftUI

// Wispr-nahe Markenfarben
private let brandIndigo = Color(red: 0.36, green: 0.32, blue: 0.86)
private let brandViolet = Color(red: 0.55, green: 0.30, blue: 0.90)

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @State private var showClearConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            header
            statsRow
                .padding(.horizontal, 24)
                .padding(.top, 18)
            searchBar
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 10)
            Divider().opacity(0.5)
            historyList
        }
        .frame(minWidth: 520, minHeight: 560)
        .background(
            LinearGradient(colors: [brandIndigo.opacity(0.06), Color(nsColor: .windowBackgroundColor)],
                           startPoint: .top, endPoint: .init(x: 0.5, y: 0.35))
                .ignoresSafeArea()
        )
        .onAppear { model.reload() }
    }

    // MARK: Kopfbereich

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [brandIndigo, brandViolet],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                Image(systemName: "mic.fill").font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("LocalFlow").font(.system(size: 20, weight: .bold))
                Text("Deine lokalen Diktate — offline & privat")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.shareNachtschicht() } label: {
                Label(model.nachtschichtBusy ? "Berechne …" : "Für die Nachtschicht teilen",
                      systemImage: "moon.stars")
            }
            .disabled(model.nachtschichtBusy)
            .help("Zahlen der letzten 7 Tage (Wörter, Diktate, Minuten, Agentic Hours) ans Nachtschicht-Leaderboard übergeben — kein Text")
            Menu {
                Text("Verlauf belegt nur \(model.storageText()) (nur Text, kein Audio)")
                Button(role: .destructive) { showClearConfirm = true } label: {
                    Label("Verlauf leeren", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 17))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .confirmationDialog("Gesamten Verlauf löschen?", isPresented: $showClearConfirm) {
                Button("Verlauf leeren", role: .destructive) { model.deleteAll() }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Alle \(model.stats.count) Diktate werden entfernt. Das lässt sich nicht rückgängig machen.")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
    }

    // MARK: Statistik-Kacheln

    private var statsRow: some View {
        HStack(spacing: 12) {
            StatCard(icon: "waveform", tint: brandIndigo,
                     value: "\(model.stats.count)", label: "Diktate")
            StatCard(icon: "text.word.spacing", tint: brandViolet,
                     value: formatK(model.stats.totalWords), label: "Wörter")
            StatCard(icon: "sun.max", tint: .orange,
                     value: "\(model.stats.todayCount)", label: "Heute")
            StatCard(icon: "bolt.fill", tint: .green,
                     value: String(format: "%.1fs", model.stats.avgLatency), label: "Ø Tempo")
        }
    }

    private func formatK(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n)/1000) : "\(n)"
    }

    // MARK: Suche

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Verlauf durchsuchen…", text: $model.query)
                .textFieldStyle(.plain)
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    // MARK: Verlauf

    private var historyList: some View {
        ScrollView {
            if model.entries.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(model.entries, id: \.id) { entry in
                        HistoryCard(model: model, entry: entry)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: model.query.isEmpty ? "mic.slash" : "magnifyingglass")
                .font(.system(size: 38)).foregroundStyle(.secondary.opacity(0.5))
            Text(model.query.isEmpty
                 ? "Noch keine Diktate.\nHalte deinen Hotkey gedrückt und sprich einfach los."
                 : "Keine Treffer.")
                .multilineTextAlignment(.center)
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }
}

// MARK: - Statistik-Kachel

private struct StatCard: View {
    let icon: String; let tint: Color; let value: String; let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
            Text(value).font(.system(size: 22, weight: .bold)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

// MARK: - Verlaufskarte

private struct HistoryCard: View {
    @ObservedObject var model: DashboardModel
    let entry: HistoryEntry
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: model.appIcon(for: entry.appBundle))
                    .resizable().frame(width: 18, height: 18)
                Text(model.appName(for: entry.appBundle))
                    .font(.system(size: 12, weight: .medium))
                Text("·").foregroundStyle(.secondary)
                Text(model.relativeTime(entry.timestamp))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if !entry.language.isEmpty {
                    Text(entry.language.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(brandIndigo.opacity(0.15)))
                        .foregroundStyle(brandIndigo)
                }
                Spacer()
                if hovering {
                    actionButtons.transition(.opacity)
                }
            }
            Text(entry.formattedText)
                .font(.system(size: 13.5))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor).opacity(hovering ? 0.85 : 0.55)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.primary.opacity(0.07), lineWidth: 1))
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { hovering = h } }
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            iconButton(copied ? "checkmark" : "doc.on.doc", "Kopieren") {
                model.copy(entry)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { copied = false }
            }
            iconButton("arrow.down.doc", "Einfügen") { model.insert(entry) }
            iconButton("trash", "Löschen") {
                withAnimation { model.delete(entry) }
            }
        }
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(tip)
    }
}
