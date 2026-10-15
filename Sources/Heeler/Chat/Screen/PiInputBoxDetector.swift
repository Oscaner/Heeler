import Foundation

/// Positively recognizes the stock Pi rule editor and OMP's box/band composers.
/// Custom extension editors, completion lists, Vim cursors and other OMP
/// composer shapes remain in the terminal rather than guessing Enter's role.
enum PiInputBoxDetector {
    static func detect(_ screen: ANSIScreen, program: ChatProgram) -> InputBoxState {
        if program == .omp, let band = ompBand(screen) { return band }
        let rows = screen.rows
        // Prefer the last editor on screen; rules in a tool's output above
        // it must never be mistaken for the input box.
        for bottom in rows.indices.reversed() {
            let end = rows[bottom].trimmedText
            let isRule = rule(end)
            let isBox = program == .omp && end.hasPrefix("╰") && end.hasSuffix("╯")
            guard isRule || isBox else { continue }
            var top = bottom - 1
            while top >= 0, bottom - top <= 12 {
                let start = rows[top].trimmedText
                if (isRule && rule(start)) || (isBox && start.hasPrefix("╭") && start.hasSuffix("╮")) { break }
                top -= 1
            }
            guard top >= 0, bottom - top <= 12 else { continue }
            let input = isBox ? Array(rows[(top + 1)...bottom]) : Array(rows[(top + 1)..<bottom])
            guard !input.isEmpty else { continue }
            let hasCursor = input.contains { row in
                row.runs.contains { $0.style.isReverse }
                    || (program == .omp && row.text.contains("▏"))
            }
            guard hasCursor else { continue }
            // Every nonblank row below stock Pi/OMP editors is footer
            // chrome. Suggestions or an extension popup suspend sending.
            for row in rows.dropFirst(bottom + 1) where !row.isBlank {
                let text = row.trimmedText
                if text.hasPrefix("❯") || text.hasPrefix(">") || text.hasPrefix("/")
                    || text.lowercased().contains("esc to") || text.lowercased().contains("escape to")
                {
                    return .overlay(text)
                }
            }
            var text: [String] = []
            for row in input {
                var value = row.text
                if isBox {
                    let trimmed = value.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("│") || trimmed.hasPrefix("╰") else {
                        return .unknown("The OMP editor is not recognized.")
                    }
                    value = String(trimmed.dropFirst())
                    if value.last == "│" || value.last == "╯" { value.removeLast() }
                    if value.hasPrefix("─") { value.removeFirst() }
                    if value.hasSuffix("─") { value.removeLast() }
                }
                // OMP's software insertion caret is chrome, not input.
                if program == .omp, value.trimmingCharacters(in: .whitespaces) == "▏" { value = "" }
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { text.append(trimmed) }
            }
            let draft = text.joined(separator: "\n")
            if draft.hasPrefix("!") { return .shellMode(draft) }
            return draft.isEmpty ? .empty(placeholder: nil) : .text(draft)
        }
        return .unknown(
            "The \(program == .pi ? "Pi" : "Oh My Pi") input box is not recognized. Continue in the Agent terminal.")
    }

    /// OMP 18.10.4 defaults to a filled status band followed by an unboxed
    /// `╰─ ` prompt. Its hardware cursor is not part of agent.read's cells.
    /// Require the normal-mode branded band immediately above the prompt,
    /// and consume every following row so a multiline draft cannot look empty.
    private static func ompBand(_ screen: ANSIScreen) -> InputBoxState? {
        let rows = screen.rows
        guard let prompt = rows.indices.last(where: { rows[$0].text.hasPrefix("╰─ ") }),
            prompt > 0
        else { return nil }
        let band = rows[prompt - 1]
        guard band.trimmedText.hasPrefix("π > "), band.text.contains("─"),
            band.text.range(of: #"\d{1,3}%"#, options: .regularExpression) != nil,
            band.runs.contains(where: { $0.style.background != nil })
        else { return nil }
        var lines: [String] = []
        for index in prompt..<rows.count {
            let row = rows[index]
            let value = index == prompt ? String(row.text.dropFirst(3)) : row.text
            let text = value.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            // Suggestions/hints are not editor continuation rows. Unknown
            // chrome also stays non-sendable rather than being discarded.
            if index > prompt, !row.text.hasPrefix("   ") { return .overlay(text) }
            if text == "▏" { continue }
            lines.append(text)
        }
        let draft = lines.joined(separator: "\n")
        if draft.hasPrefix("!") { return .shellMode(draft) }
        return draft.isEmpty ? .empty(placeholder: nil) : .text(draft)
    }

    private static func rule(_ text: String) -> Bool {
        text.count >= 10 && text.allSatisfy { $0 == "─" }
    }
}
