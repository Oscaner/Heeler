import Foundation

/// Reads Oh My Pi's dialog panels from a visible-screen read.
///
/// OMP draws a dialog as a rounded panel titled in its top border,
/// `╭─ Allow tool: bash ─…╮`, with `├─…┤` rules between its sections and
/// its key hints in the last one. The panel is either the screen's last row
/// (a question without a draft replaces the composer, the plan review fills
/// the screen) or rests directly on the status band, whose `╰─` prompt stays
/// below it (an approval, or a question while the prompt holds a draft).
/// Tool renderings in the history are panels too, but untitled (`╭───╮`) or
/// with a rule before the title (`╭─── Ask 1 questions`), and never touch the
/// band. Only a tool approval is a known dialog; any other titled panel holds
/// sending as an excerpt for the generic card. OMP binds no digits, so the
/// excerpt offers none.
enum OMPDialogParser {
    static func parse(_ screen: ANSIScreen) -> DialogParseResult {
        guard let panel = OMPPanel.bottom(of: screen) else { return .none }
        guard let title = panel.title else {
            return unrecognized(panel, on: screen, "The top of Oh My Pi's panel is off screen.")
        }
        if title.hasPrefix(approvalPrefix) {
            return approval(panel, title: title, on: screen)
        }
        if title == "Ask" {
            return unrecognized(panel, on: screen, "Answer Oh My Pi's question with these keys or in the terminal.")
        }
        return unrecognized(panel, on: screen, "Heeler does not know Oh My Pi's \u{201C}\(title)\u{201D} panel.")
    }

    private static let approvalPrefix = "Allow tool:"

    /// `Allow tool: <name>`, its details (`Command:`, `Reason:`, `Origin:`
    /// and per-tool rows), then `ctrl+q approve · esc deny · …`. Plain Enter
    /// does nothing; typing goes to the prompt below, which turns the footer's
    /// tail into `deny and send`, so the footer stays out of the fingerprint.
    private static func approval(_ panel: OMPPanel, title: String, on screen: ANSIScreen) -> DialogParseResult {
        guard panel.sections.count > 1, let footer = panel.sections.last else {
            return unrecognized(panel, on: screen, "The approval's keys are not on screen.")
        }
        let keys = footer.joined(separator: " ")
        guard keys.contains(" approve"), keys.contains(" deny") else {
            return unrecognized(panel, on: screen, "The approval's keys are not on screen.")
        }
        let body = panel.sections.dropLast().flatMap { $0 }
        var subject = DialogSubject()
        subject.toolName = String(title.dropFirst(approvalPrefix.count)).trimmingCharacters(in: .whitespaces)
        subject.command = value(of: "Command:", in: body).map { command in
            // A command too long for its row ends in `…`.
            command.hasSuffix("…") ? String(command.dropLast()).trimmingCharacters(in: .whitespaces) : command
        }
        subject.reason = value(of: "Reason:", in: body)
        // OMP ignores ctrl+q for 500 ms after drawing the panel; the store
        // waits that out. ctrl+enter reads as Enter without kitty keys.
        let options = [
            DialogOption(ordinal: 1, number: nil, label: "Approve", shortcut: "ctrl+q", role: .approve),
            DialogOption(ordinal: 2, number: nil, label: "Deny", shortcut: "esc", role: .decline),
        ]
        return .dialog(
            BlockedDialog(
                kind: .ompApproval, title: title, sourceSuffix: nil, positionLabel: nil, body: body, progress: nil,
                options: options, rows: panel.rows,
                fingerprint: DialogFingerprint(
                    program: .omp, kind: .ompApproval, title: title, sourceSuffix: nil, body: body, progress: nil,
                    options: options),
                focus: DialogFocusState(), subject: subject))
    }

    private static func value(of label: String, in body: [String]) -> String? {
        body.first { $0.hasPrefix(label) }.map {
            String($0.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
    }

    /// The panel's rows verbatim. The fingerprint leaves out the key hints,
    /// which change with the prompt's draft, and the focus pointer.
    private static func unrecognized(_ panel: OMPPanel, on screen: ANSIScreen, _ reason: String) -> DialogParseResult {
        let content = panel.sections.count > 1 ? panel.sections.dropLast().flatMap { $0 } : panel.sections.flatMap { $0 }
        let unpointed = content.map { row in
            String(row.drop { $0 == "\u{F054}" || $0 == "❯" || ScreenRow.isBlank($0) })
        }
        return .unrecognized(
            GenericDialogExcerpt(
                rows: Array(screen.rows[panel.rows]), numbered: [:], reason: reason,
                fingerprint: DialogFingerprint(program: .omp, excerptRows: [panel.title ?? ""] + unpointed)))
    }
}

/// An OMP panel as `OMPDialogParser` finds it.
private struct OMPPanel {
    /// The zero-based screen rows from the top border, or the screen's top
    /// when the border is off screen, through the bottom border.
    let rows: Range<Int>
    /// The title from the top border, without a countdown such as `(30s)`;
    /// nil when the top border is off screen.
    let title: String?
    /// The text between the side borders, blank rows dropped, split at each
    /// `├─…┤` rule.
    let sections: [[String]]

    /// The lowest panel, when it ends the screen or rests on the status
    /// band. An untitled panel is a tool's rendering, not a dialog.
    static func bottom(of screen: ANSIScreen) -> OMPPanel? {
        let rows = screen.rows
        guard let last = rows.lastIndex(where: { !$0.isBlank }) else { return nil }
        let bottom: Int
        if isBottomBorder(rows[last]) {
            bottom = last
        } else if let prompt = rows.indices.last(where: { PiInputBoxDetector.isOMPPrompt(rows[$0]) }), prompt >= 2,
            PiInputBoxDetector.isOMPStatusBand(rows[prompt - 1]), isBottomBorder(rows[prompt - 2])
        {
            bottom = prompt - 2
        } else {
            return nil
        }
        var sections: [[String]] = [[]]
        var index = bottom - 1
        while index >= 0 {
            let text = rows[index].trimmedText
            if text.hasPrefix("╭"), text.hasSuffix("╮") { break }
            if text.hasPrefix("├"), text.hasSuffix("┤") {
                sections.insert([], at: 0)
            } else if text.hasPrefix("│"), text.hasSuffix("│"), text.count >= 2 {
                let inner = text.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                if !inner.isEmpty { sections[0].insert(inner, at: 0) }
            } else {
                return nil
            }
            index -= 1
        }
        guard index >= 0 else { return OMPPanel(rows: 0..<(bottom + 1), title: nil, sections: sections) }
        guard let title = title(of: rows[index].trimmedText) else { return nil }
        return OMPPanel(rows: index..<(bottom + 1), title: title, sections: sections)
    }

    private static func isBottomBorder(_ row: ScreenRow) -> Bool {
        let text = row.trimmedText
        return text.hasPrefix("╰") && text.hasSuffix("╯")
    }

    /// `╭─ Title ─…╮`: exactly one rule cell, a space, then the title.
    private static func title(of border: String) -> String? {
        guard border.hasPrefix("╭─ ") else { return nil }
        let rest = border.dropFirst(3)
        guard let first = rest.first, first != "─", !ScreenRow.isBlank(first) else { return nil }
        let end = rest.range(of: " ─")?.lowerBound ?? rest.index(before: rest.endIndex)
        let title = rest[..<end].replacingOccurrences(
            of: #"\s*\(\d+s\)$"#, with: "", options: .regularExpression)
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
