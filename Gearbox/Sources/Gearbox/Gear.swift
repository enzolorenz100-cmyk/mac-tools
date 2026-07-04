import SwiftUI

enum Gear: Int, CaseIterable, Identifiable {
    case auto = 0
    case haiku = 1
    case sonnet = 2
    case opus = 3
    case fable = 4
    case resume = 5

    var id: Int { rawValue }

    var symbol: String {
        switch self {
        case .auto: return "A"
        case .haiku: return "1"
        case .sonnet: return "2"
        case .opus: return "3"
        case .fable: return "4"
        case .resume: return "R"
        }
    }

    var chipLabel: String {
        switch self {
        case .auto: return "AUTO"
        case .haiku: return "HAIKU"
        case .sonnet: return "SONNET"
        case .opus: return "OPUS"
        case .fable: return "FABLE"
        case .resume: return "RESUME"
        }
    }

    var name: String {
        switch self {
        case .auto: return "Automatik"
        case .haiku: return "Haiku 4.5"
        case .sonnet: return "Sonnet 5"
        case .opus: return "Opus 4.8"
        case .fable: return "Fable 5 · 1M"
        case .resume: return "Resume"
        }
    }

    var tagline: String {
        switch self {
        case .auto: return "Router wählt das passende Modell"
        case .haiku: return "schnell & günstig — simple Tasks"
        case .sonnet: return "solide Alltagsarbeit"
        case .opus: return "komplexe Aufgaben & Debugging"
        case .fable: return "maximale Power, 1M Kontext"
        case .resume: return "setzt die letzte Session im Ordner fort"
        }
    }

    /// Argument für `claude --model …`. `nil` bei Automatik (wird vorher aufgelöst)
    /// und bei Resume (die fortgesetzte Session behält ihr Modell).
    var modelArg: String? {
        switch self {
        case .auto, .resume: return nil
        case .haiku: return "haiku"
        case .sonnet: return "sonnet"
        case .opus: return "opus"
        case .fable: return "claude-fable-5[1m]"
        }
    }

    /// Einheitliches Theme-Blau — Enzos Wunsch: alles uniform in diesem Blau.
    var color: Color { .zentraleBlau }
}

extension Color {
    /// Schaltzentrale-Blau — einheitlicher Akzent für das ganze Widget. Dunkler
    /// als die erste Version (Enzo: zu hell/grell). NUR für Flächen (Chips,
    /// Buttons, Ringe) — als Schriftfarbe hat es auf dem 0.07er-Glas nur
    /// ~2.5:1 Kontrast („schwarz auf schwarz", Enzo-Feedback 04.07.).
    static let zentraleBlau = Color(red: 0.12, green: 0.32, blue: 0.68)
    /// Helles Blau für Status-Text/-Punkte und kleine Symbole auf dunklem
    /// Grund (~7.7:1 Kontrast) — Schrift selbst ist weiß.
    static let zentraleBlauHell = Color(red: 0.55, green: 0.73, blue: 1.0)
    /// Feste, volldeckende Grautöne statt Apples .secondary/.tertiary — und
    /// bewusst KEINE Color.white.opacity(x): bei 9pt-Text erreichen dünne
    /// Striche beim Antialiasing nie volle Deckkraft, das verdünnt sich mit
    /// einer zusätzlichen Opacity nochmal — gemessen (Screenshot-Pixelprobe)
    /// blieb .opacity(0.6) auf dunklem Grund bei nur ~20% der beabsichtigten
    /// Helligkeit hängen. Volldeckende Werte treffen den Zielton direkt.
    static let zentraleGrauSekundär = Color(white: 0.88)
    static let zentraleGrauTertiär = Color(white: 0.70)
}
