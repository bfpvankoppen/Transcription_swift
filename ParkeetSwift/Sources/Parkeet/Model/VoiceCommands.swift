import Foundation

/// Post-processes transcribed text, replacing spoken formatting commands with symbols.
///
/// Example: "Hello new line world period" → "Hello\nworld."
enum VoiceCommands {

    // Commands ordered longest-first (greedy matching)
    static let commands: [(phrase: String, replacement: String)] = [
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
        ("exclamation point", "!"),
        ("exclamation mark", "!"),
        ("question mark", "?"),
        ("open parenthesis", "("),
        ("close parenthesis", ")"),
        ("open quote", "\""),
        ("close quote", "\""),
        ("semicolon", ";"),
        ("period", "."),
        ("comma", ","),
        ("colon", ":"),
        ("dash", "—"),
        ("hyphen", "-"),
    ]

    /// Default enabled state for each command.
    static let defaultEnabled: [String: Bool] = {
        var dict: [String: Bool] = [:]
        for cmd in commands {
            dict[cmd.phrase] = true
        }
        return dict
    }()

    /// Apply enabled voice commands to transcribed text.
    static func apply(to text: String, enabled: [String: Bool]) -> String {
        var result = text

        // Replace each enabled command phrase with its symbol
        for cmd in commands {
            guard enabled[cmd.phrase] ?? true else { continue }

            // Case-insensitive replacement
            result = result.replacingOccurrences(
                of: cmd.phrase,
                with: cmd.replacement,
                options: .caseInsensitive
            )
        }

        // Clean up whitespace around punctuation
        result = cleanupWhitespace(result)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove spaces before punctuation, after opening quotes/parens.
    private static func cleanupWhitespace(_ text: String) -> String {
        var result = text

        // Remove space before punctuation: "Hello ." → "Hello."
        let punctuation = [".", ",", "!", "?", ";", ":", "—", "-", ")", "\""]
        for p in punctuation {
            result = result.replacingOccurrences(of: " \(p)", with: p)
        }

        // Remove space after opening delimiters: "( hello" → "(hello"
        result = result.replacingOccurrences(of: "( ", with: "(")
        result = result.replacingOccurrences(of: "\" ", with: "\"")

        // Collapse multiple spaces
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        // Remove orphaned punctuation at line starts (model artifacts)
        let lines = result.components(separatedBy: "\n")
        let cleaned = lines.map { line -> String in
            var l = line.trimmingCharacters(in: .whitespaces)
            while let first = l.first, ".!?,;:".contains(first) {
                l = String(l.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            return l
        }
        result = cleaned.joined(separator: "\n")

        return result
    }
}
