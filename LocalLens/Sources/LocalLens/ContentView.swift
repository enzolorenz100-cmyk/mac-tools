import SwiftUI
import UniformTypeIdentifiers

private let brandIndigo = Color(red: 0.36, green: 0.32, blue: 0.86)
private let brandViolet = Color(red: 0.55, green: 0.30, blue: 0.90)
private let mint = Color(red: 0.22, green: 0.84, blue: 0.63)

/// Zustand des Fensters, von AppKit/Model gefüttert.
final class LensModel: ObservableObject {
    @Published var isDropTargeted = false
    @Published var state: State = .idle
    @Published var output = ""
    @Published var stats = ""
    @Published var appLabel = ""
    @Published var justCopied = false
    var onImageDropped: ((URL) -> Void)?
    var onCapture: (() -> Void)?
    var onCopy: (() -> Void)?

    enum State { case idle, analyzing, done }
}

struct ContentView: View {
    @ObservedObject var model: LensModel

    var body: some View {
        VStack(spacing: 0) {
            header
            dropZone
                .padding(.horizontal, 22).padding(.top, 6)
            if !model.output.isEmpty || model.state == .analyzing {
                outputArea.padding(22)
            } else {
                Spacer()
            }
        }
        .frame(minWidth: 560, minHeight: 560)
        .background(LinearGradient(colors: [brandIndigo.opacity(0.06), Color(nsColor: .windowBackgroundColor)],
                                   startPoint: .top, endPoint: .init(x: 0.5, y: 0.4)).ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [brandIndigo, brandViolet], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                Image(systemName: "text.viewfinder").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("LocalLens").font(.system(size: 18, weight: .bold))
                Text("Bild → AI-Text · lokal & gratis").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.onCapture?() } label: {
                Label("Screen scannen", systemImage: "camera.viewfinder")
            }.controlSize(.large).buttonStyle(.borderedProminent).tint(brandViolet)
        }
        .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(model.isDropTargeted ? brandIndigo.opacity(0.12) : Color(nsColor: .textBackgroundColor).opacity(0.4))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .foregroundStyle(model.isDropTargeted ? brandIndigo : Color.primary.opacity(0.18))
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 30)).foregroundStyle(model.isDropTargeted ? brandIndigo : .secondary)
                Text(model.isDropTargeted ? "Loslassen zum Analysieren" : "Bild oder Video hierher ziehen")
                    .font(.system(size: 15, weight: .medium))
                Text("oder klicken zum Auswählen · PNG, JPG, Screenshots, MP4/MOV")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(24)
        }
        .frame(height: 150)
        .contentShape(Rectangle())
        .onTapGesture { pickFile() }
        .onDrop(of: [.fileURL, .image, .movie], isTargeted: $model.isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var outputArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AI-Text").font(.system(size: 13, weight: .semibold))
                if !model.appLabel.isEmpty {
                    Text(model.appLabel).font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(brandIndigo.opacity(0.15))).foregroundStyle(brandIndigo)
                }
                Spacer()
                if !model.stats.isEmpty {
                    Text(model.stats).font(.system(size: 11, design: .monospaced)).foregroundStyle(mint)
                }
            }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08))
                if model.state == .analyzing {
                    AnalyzingView()
                } else {
                    ScrollView {
                        Text(model.output).font(.system(size: 12.5, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }
                }
            }.frame(minHeight: 200)
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(mint)
                    .opacity(model.state == .done ? 1 : 0)
                Text("automatisch kopiert — bereit zum Pasten")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .opacity(model.state == .done ? 1 : 0)
                Spacer()
                Button { model.onCopy?() } label: {
                    Label(model.justCopied ? "Kopiert!" : "Kopieren",
                          systemImage: model.justCopied ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 90)
                }.controlSize(.large).buttonStyle(.borderedProminent)
                    .tint(model.justCopied ? mint : brandIndigo)
                    .disabled(model.output.isEmpty || model.state == .analyzing)
            }
        }
    }

    // MARK: Datei-Auswahl & Drop

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image, .tiff, .heic, .movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.onImageDropped?(url) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first else { return false }
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { model.onImageDropped?(url) } }
            }
            return true
        }
        // Bilddaten direkt (z. B. aus einem Browser gezogen)
        p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
            guard let data else { return }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString).png")
            try? data.write(to: tmp)
            DispatchQueue.main.async { model.onImageDropped?(tmp) }
        }
        return true
    }
}

/// „Schaut sich das Bild an"-Animation.
struct AnalyzingView: View {
    @State private var phase = 0.0
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(brandIndigo.opacity(0.2), lineWidth: 3).frame(width: 44, height: 44)
                Circle().trim(from: 0, to: 0.3)
                    .stroke(brandViolet, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 44, height: 44)
                    .rotationEffect(.degrees(phase))
                Image(systemName: "eye").font(.system(size: 16)).foregroundStyle(brandIndigo)
            }
            Text("Schaut sich das Bild an …").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { phase = 360 }
        }
    }
}
