import AppKit
import Combine

/// Bindeglied zwischen HistoryStore (SQLite) und der SwiftUI-Oberfläche.
final class DashboardModel: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    @Published var stats: HistoryStore.Stats = .init()
    @Published var query: String = "" { didSet { applyFilter() } }
    @Published var nachtschichtBusy = false

    private let history: HistoryStore
    private let onInsert: (String) -> Void
    private var allEntries: [HistoryEntry] = []

    init(history: HistoryStore, onInsert: @escaping (String) -> Void) {
        self.history = history
        self.onInsert = onInsert
    }

    func reload() {
        allEntries = history.recent(limit: 500)
        stats = history.stats()
        applyFilter()
    }

    private func applyFilter() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        entries = q.isEmpty ? allEntries
            : allEntries.filter { $0.formattedText.lowercased().contains(q) }
    }

    func copy(_ entry: HistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.formattedText, forType: .string)
    }

    func insert(_ entry: HistoryEntry) {
        onInsert(entry.formattedText)
    }

    func delete(_ entry: HistoryEntry) {
        history.delete(id: entry.id)
        reload()
    }

    /// Rechnet im Hintergrund, zeigt vor dem Senden die Zahlen und öffnet dann den Browser.
    func shareNachtschicht() {
        NachtschichtShare.start(history: history) { [weak self] busy in
            self?.nachtschichtBusy = busy
        }
    }

    func deleteAll() {
        history.deleteAll()
        reload()
    }

    /// Menschlich lesbare Größe der Verlaufsdatenbank, z. B. "0,4 MB".
    func storageText() -> String {
        let bytes = history.databaseBytes()
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes)/1024) }
        return String(format: "%.1f MB", Double(bytes)/(1024*1024))
    }

    // MARK: - Darstellungshelfer

    func appIcon(for bundle: String) -> NSImage {
        if !bundle.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }

    func appName(for bundle: String) -> String {
        guard !bundle.isEmpty else { return "Unbekannt" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundle.components(separatedBy: ".").last ?? bundle
    }

    func relativeTime(_ date: Date) -> String {
        let now = Date()
        let secs = now.timeIntervalSince(date)
        if secs < 60 { return "gerade eben" }
        if secs < 3600 { return "vor \(Int(secs/60)) Min" }
        let cal = Calendar.current
        let df = DateFormatter()
        if cal.isDateInToday(date) { df.dateFormat = "'heute' HH:mm" }
        else if cal.isDateInYesterday(date) { df.dateFormat = "'gestern' HH:mm" }
        else { df.dateFormat = "dd.MM. HH:mm" }
        return df.string(from: date)
    }
}
