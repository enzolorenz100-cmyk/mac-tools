import Foundation

/// Regelbasierte Nachbearbeitung des Whisper-Outputs (<10 ms):
/// Füllwörter, Stotter-Duplikate, Diktat-Kommandos, Wörterbuch, Snippets, Messaging-Stil.
struct TextFormatter {
    let settings: Settings

    func format(_ raw: String, targetBundleID: String?, language: String = "de") -> String {
        // whisper-server trennt Segmente mit "\n"; die Segmente tragen ihr führendes Leerzeichen
        // bereits selbst. Das "\n" muss daher ERSATZLOS weg — ein Leerzeichen stattdessen zerreißt
        // Wörter, wenn die Segmentgrenze mitten im Wort liegt ("ba\nue" → "ba ue").
        var text = raw
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        // Sicherheitsnetz gegen Whisper-Halluzinationen bei Stille/Rauschen
        // (die Stille-Erkennung im Controller fängt den Normalfall schon vorher ab).
        if Self.isLikelyHallucination(text) {
            Log.info("Halluzination verworfen: \(text.prefix(60))")
            return ""
        }
        let startedCapitalized = text.first?.isUppercase ?? false

        if settings.fillerRemoval {
            text = removeFillers(text, language: language)
            text = mergeStutters(text)
        }
        text = applyDictationCommands(text)
        text = applyDictionary(text)
        text = applySnippets(text)
        text = normalizeWhitespace(text)

        if let bundleID = targetBundleID, settings.messagingBundleIDs.contains(bundleID) {
            text = stripTrailingPeriod(text)
        }
        // Großschreibung wiederherstellen, falls ein entferntes Füllwort am Anfang stand.
        if startedCapitalized, let first = text.first, first.isLowercase {
            text = first.uppercased() + text.dropFirst()
        }
        return text
    }

    // MARK: Füllwörter

    // Sprachneutral sicher entfernbar (keine Kollision mit echten Wörtern).
    private static let universalFillers = ["ähm", "ähh", "äh", "öhm", "öh", "hmm", "mhm"]
    // NUR in englischen Diktaten entfernen: "um" ist eine deutsche Präposition
    // ("um 4 Uhr" / mit Zögerpause sogar "um, äh, 4 Uhr") und darf dort nie verschwinden.
    private static let englishFillers = ["um", "uh", "uhm", "erm"]

    private func removeFillers(_ text: String, language: String) -> String {
        var result = text
        for filler in Self.universalFillers {
            result = result.replacingOccurrences(
                of: #"(?i)(^|[\s„"(])\#(filler)[,.]?\s+"#,
                with: "$1", options: .regularExpression)
        }
        if language == "en" {
            for filler in Self.englishFillers {
                result = result.replacingOccurrences(
                    of: #"(?i)(^|[\s„"(])\#(filler)[,.]\s+"#,
                    with: "$1", options: .regularExpression)
            }
        }
        return result
    }

    /// "das das Problem" → "das Problem" (Wort-Doppelungen durch Stottern/Neustarts)
    private func mergeStutters(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?i)\b(\p{L}{2,})(\s+\1)+\b"#,
            with: "$1", options: .regularExpression)
    }

    // MARK: Diktat-Kommandos (nur eindeutige Mehrwort-Kommandos)

    private static let commands: [(pattern: String, replacement: String)] = [
        (#"(?i)[,.]?\s*\b(neue zeile|new line)\b[,.]?\s*"#, "\n"),
        (#"(?i)[,.]?\s*\b(neuer absatz|new paragraph)\b[,.]?\s*"#, "\n\n"),
    ]

    private func applyDictationCommands(_ text: String) -> String {
        var result = text
        for cmd in Self.commands {
            result = result.replacingOccurrences(of: cmd.pattern, with: cmd.replacement, options: .regularExpression)
        }
        return result
    }

    // MARK: Wörterbuch & Snippets

    private func applyDictionary(_ text: String) -> String {
        var result = text
        for entry in settings.dictionary {
            for wrong in entry.misspellings {
                let escaped = NSRegularExpression.escapedPattern(for: wrong)
                result = result.replacingOccurrences(
                    of: #"(?i)\b\#(escaped)\b"#,
                    with: entry.phrase, options: .regularExpression)
            }
        }
        return result
    }

    private func applySnippets(_ text: String) -> String {
        var result = text
        for snippet in settings.snippets where !snippet.trigger.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: snippet.trigger)
            result = result.replacingOccurrences(
                of: #"(?i)\b\#(escaped)\b[,.]?"#,
                with: snippet.expansion, options: .regularExpression)
        }
        return result
    }

    // MARK: Feinschliff

    private func normalizeWhitespace(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #" +([,.!?;:])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n "#, with: "\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Messaging-Apps: einzelnen Schlusspunkt entfernen ("ok." → "ok"), aber nie "..." / "?!"
    private func stripTrailingPeriod(_ text: String) -> String {
        guard text.hasSuffix("."), !text.hasSuffix(".."),
              !text.contains("\n") else { return text }
        return String(text.dropLast())
    }

    // Bekannte Whisper-Artefakte, die NUR bei Stille/Rauschen auftreten und praktisch nie
    // echte Diktate sind. Bewusst konservativ — mehrdeutige Kurzphrasen ("Vielen Dank",
    // "Thank you") stehen NICHT drin, die fängt die Energie-basierte Stille-Erkennung ab.
    private static let hallucinationPatterns: [String] = [
        #"(?i)untertitel(ung)?"#,
        #"(?i)amara\.org"#,
        #"(?i)zdf\b.*funk"#,
        #"(?i)\bswr\b.*\d{4}"#,
        #"(?i)www\.[a-z]"#,
        #"(?i)thanks for watching"#,
        #"(?i)subscribe to"#,
        #"(?i)copyright.*\d{4}"#,
    ]

    // Kurze Ein-Wort-Artefakte, die Whisper NUR auf Stille ausgibt (exakter Match,
    // damit "Amen sagen zum Vertrag" o. ä. nicht fälschlich verworfen wird).
    private static let exactArtifacts: Set<String> = [
        "amen", "amen.", "amara.org", "bye", "bye.", "you", "you.", ".", "..", "...",
        "ende", "ende.", "the end", "the end.",
    ]

    static func isLikelyHallucination(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nur Interpunktion/Sonderzeichen → Müll.
        if t.allSatisfy({ !$0.isLetter && !$0.isNumber }) { return true }
        if exactArtifacts.contains(t.lowercased()) { return true }
        for pattern in hallucinationPatterns where t.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// Whisper-initial_prompt: korrekte Schreibweisen der Wörterbuch-Einträge als Kontext-Bias.
    func initialPrompt() -> String {
        let words = settings.dictionary.map(\.phrase) + settings.snippets.map(\.trigger)
        guard !words.isEmpty else { return "" }
        return "Glossar: " + words.joined(separator: ", ") + "."
    }
}
