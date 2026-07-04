import SwiftUI

/// Echte H-Schaltkulisse wie im Auto: 1 oben links → 4 unten Mitte,
/// R(esume) oben rechts, A(utomatik) unten rechts. Der Knauf wird
/// durch die Gassen gezogen und rastet in den Gängen ein.
struct GearShifterView: View {
    @Binding var gearRaw: Int
    @Binding var displayGear: Gear?
    var enabled: Bool = true

    @State private var dragPos: CGPoint?
    @State private var dragBase: CGPoint?

    private let plateSize = CGSize(width: 340, height: 158)
    private let knobSize: CGFloat = 46
    private let slotWidth: CGFloat = 16

    // Kulissen-Geometrie (Plate-Koordinaten)
    private let colX: [CGFloat] = [64, 170, 276]
    private let topY: CGFloat = 38
    private let midY: CGFloat = 79
    private let botY: CGFloat = 120

    private var gearPoint: [Gear: CGPoint] {
        [.haiku: CGPoint(x: colX[0], y: topY),
         .sonnet: CGPoint(x: colX[0], y: botY),
         .opus: CGPoint(x: colX[1], y: topY),
         .fable: CGPoint(x: colX[1], y: botY),
         .resume: CGPoint(x: colX[2], y: topY),
         .auto: CGPoint(x: colX[2], y: botY)]
    }

    /// Die Gassen: drei senkrechte Schächte + Querbalken
    private var segments: [(CGPoint, CGPoint)] {
        [(CGPoint(x: colX[0], y: topY), CGPoint(x: colX[0], y: botY)),
         (CGPoint(x: colX[1], y: topY), CGPoint(x: colX[1], y: botY)),
         (CGPoint(x: colX[2], y: topY), CGPoint(x: colX[2], y: botY)),
         (CGPoint(x: colX[0], y: midY), CGPoint(x: colX[2], y: midY))]
    }

    private var selected: Gear { Gear(rawValue: gearRaw) ?? .auto }
    private var shown: Gear { displayGear ?? selected }
    private var knobPos: CGPoint { dragPos ?? gearPoint[shown] ?? gearPoint[.auto]! }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                plate
                slots
                labels
                knob
            }
            .frame(width: plateSize.width, height: plateSize.height)
            legend
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: gearRaw)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: displayGear)
    }

    // MARK: - Optik

    /// Kurzlegende: welcher Gang wofür am besten ist.
    private var legend: some View {
        let entries: [(Gear, String)] = [
            (.haiku, "Haiku — schnell & simpel"),
            (.sonnet, "Sonnet — Alltag & Bugfixes"),
            (.opus, "Opus — komplexe Arbeit"),
            (.fable, "Fable — volle Power"),
            (.auto, "Auto — KI entscheidet alles"),
            (.resume, "Resume — Session fortsetzen"),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                         spacing: 3.5) {
            ForEach(entries, id: \.0) { gear, text in
                HStack(spacing: 5) {
                    Text(gear.symbol)
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 10)
                    Text(text)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.zentraleGrauSekundär)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(width: plateSize.width - 12)
    }

    private var plate: some View {
        RoundedRectangle(cornerRadius: 22)
            .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.07)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.03)],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
    }

    private var gatePath: Path {
        Path { path in
            for (a, b) in segments {
                path.move(to: a)
                path.addLine(to: b)
            }
        }
    }

    private var slots: some View {
        ZStack {
            gatePath.stroke(Color.black.opacity(0.85),
                            style: StrokeStyle(lineWidth: slotWidth, lineCap: .round, lineJoin: .round))
            // Fräskante: feiner Lichtsaum an der Unterkante der Gasse
            gatePath.stroke(Color.white.opacity(0.10),
                            style: StrokeStyle(lineWidth: slotWidth + 1.5, lineCap: .round, lineJoin: .round))
                .blendMode(.screen)
                .mask(gatePath.stroke(style: StrokeStyle(lineWidth: slotWidth + 3, lineCap: .round))
                    .offset(y: 1.5))
        }
    }

    private var labels: some View {
        ForEach(Gear.allCases) { gear in
            let active = gear == shown
            Text(gear.symbol)
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .foregroundStyle(Color(white: 0.92))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
                // der Knauf steht im aktiven Gang und zeigt das Symbol selbst
                .opacity(active ? 0 : 1)
                .position(labelPoint(gear))
                .onTapGesture { select(gear) }
        }
    }

    private func labelPoint(_ gear: Gear) -> CGPoint {
        guard let p = gearPoint[gear] else { return .zero }
        return CGPoint(x: p.x, y: p.y == topY ? topY - 24 : botY + 24)
    }

    private var knob: some View {
        ZStack {
            // Schaltknauf: polierte Kugel mit Lichtpunkt oben links
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.60), Color(white: 0.22), Color(white: 0.08)],
                                     center: .init(x: 0.32, y: 0.28),
                                     startRadius: 2, endRadius: knobSize * 0.95))
            Circle()
                .stroke(Color.zentraleBlauHell.opacity(0.9), lineWidth: 2)
            Text(shown.symbol)
                .font(.system(size: 15, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
        }
        .frame(width: knobSize, height: knobSize)
        .shadow(color: .black.opacity(0.55), radius: 5, y: 4)
        .shadow(color: shown.color.opacity(dragPos == nil ? 0.35 : 0.75),
                radius: dragPos == nil ? 7 : 13)
        .position(knobPos)
        .gesture(dragGesture)
    }

    // MARK: - Mechanik

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard enabled else { return }
                if dragBase == nil {
                    dragBase = knobPos
                    displayGear = nil
                }
                let raw = CGPoint(x: dragBase!.x + value.translation.width,
                                  y: dragBase!.y + value.translation.height)
                dragPos = constrainToTrack(raw)
            }
            .onEnded { _ in
                defer { dragBase = nil }
                guard enabled, let p = dragPos else { dragPos = nil; return }
                let nearest = gearPoint.min {
                    hypot($0.value.x - p.x, $0.value.y - p.y) <
                    hypot($1.value.x - p.x, $1.value.y - p.y)
                }!
                withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) {
                    gearRaw = nearest.key.rawValue
                    dragPos = nil
                }
            }
    }

    private func select(_ gear: Gear) {
        guard enabled else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.65)) {
            displayGear = nil
            gearRaw = gear.rawValue
        }
    }

    private func constrainToTrack(_ p: CGPoint) -> CGPoint {
        var best = p
        var bestDistance = CGFloat.infinity
        for (a, b) in segments {
            let q = nearestOnSegment(p, a, b)
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < bestDistance {
                bestDistance = d
                best = q
            }
        }
        return best
    }

    private func nearestOnSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let lengthSquared = ab.x * ab.x + ab.y * ab.y
        guard lengthSquared > 0 else { return a }
        let t = max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / lengthSquared))
        return CGPoint(x: a.x + t * ab.x, y: a.y + t * ab.y)
    }
}
