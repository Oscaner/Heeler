import Foundation
import Testing

@testable import Heeler

/// OpenCode 2.0.32's prompts as captured live at 180 and 62 columns: a
/// permission and a single question are known dialogs, the reject-feedback
/// stage and a form with several questions hold sending as excerpts, and
/// other screens show no dialog.
@Suite("OpenCode dialog parser")
struct OpenCodeDialogParserTests {
    private func parse(_ stem: String) throws -> DialogParseResult {
        BlockedDialogParser.parse(try ScreenFixture.screen(stem), program: .opencode)
    }

    private func dialog(_ stem: String) throws -> BlockedDialog {
        let result = try parse(stem)
        return try #require(result.dialog, "\(stem) parsed as \(result)")
    }

    // MARK: Permissions

    /// Allow once has focus when the request shows; each Right moves the
    /// fill one option on.
    @Test(arguments: [
        ("opencode-10-permission-180", 1), ("opencode-11-permission-right1-180", 2),
        ("opencode-12-permission-right2-180", 3),
    ])
    func permissionDialogsListTheirOptionsAndFocus(stem: String, focus: Int) throws {
        let dialog = try dialog(stem)
        #expect(dialog.kind == .openCodePermission)
        #expect(dialog.program == .opencode)
        #expect(dialog.title == "Permission required")
        #expect(dialog.body == ["Read .env"])
        #expect(dialog.rows == 37..<46)
        #expect(dialog.subject.toolName == "Read")
        #expect(dialog.subject.filePath == ".env")
        #expect(dialog.options.map(\.label) == ["Allow once", "Always allow", "Reject"])
        #expect(dialog.options.map(\.role) == [.approve, .approvePersistent, .decline])
        #expect(dialog.options.map(\.ordinal) == [1, 2, 3])
        #expect(dialog.options.allSatisfy { $0.number == nil && $0.shortcut == nil })
        #expect(dialog.options.filter(\.isFocused).map(\.ordinal) == [focus])
        #expect(dialog.focus == DialogFocusState(focusedOrdinal: focus))
    }

    @Test func focusLeavesTheFingerprintUnchanged() throws {
        let once = try dialog("opencode-10-permission-180")
        #expect(try dialog("opencode-11-permission-right1-180").fingerprint == once.fingerprint)
        #expect(try dialog("opencode-12-permission-right2-180").fingerprint == once.fingerprint)
    }

    /// While Always allow has focus, OpenCode swaps `Path: .env` for what
    /// the rule would allow. The card shows those lines; the fingerprint
    /// leaves them out, or the first Right would read as a new dialog.
    @Test func notesAreShownButNotFingerprinted() throws {
        let once = try dialog("opencode-10-permission-180")
        let always = try dialog("opencode-11-permission-right1-180")
        #expect(once.subject.notes == ["Path: .env"])
        #expect(always.subject.notes == ["This will always allow read for this project."])
        var swapped = always.subject
        swapped.notes = once.subject.notes
        #expect(swapped == once.subject)
        #expect(always.body == once.body)
        #expect(always.options.map(\.label) == once.options.map(\.label))
        #expect(always.fingerprint == once.fingerprint)
        #expect(try dialog("opencode-12-permission-right2-180").subject == once.subject)
    }

    /// Without a rule to keep, OpenCode offers Allow once and Reject only.
    @Test func aPermissionWithoutAlwaysAllowListsTwoOptions() throws {
        let captured = try dialog("opencode-10-permission-180")
        let drawn = try #require(
            BlockedDialogParser.parse(
                Self.permission(options: ["Allow once", "Always allow", "Reject"]), program: .opencode
            ).dialog)
        // The drawing reads like the capture.
        #expect(drawn.fingerprint == captured.fingerprint)
        #expect(drawn.subject == captured.subject)
        #expect(drawn.focus == captured.focus)

        let dialog = try #require(
            BlockedDialogParser.parse(Self.permission(options: ["Allow once", "Reject"]), program: .opencode).dialog)
        #expect(dialog.kind == .openCodePermission)
        #expect(dialog.body == ["Read .env"])
        #expect(dialog.options.map(\.label) == ["Allow once", "Reject"])
        #expect(dialog.options.map(\.role) == [.approve, .decline])
        #expect(dialog.focus.focusedOrdinal == 1)
        #expect(dialog.fingerprint != captured.fingerprint)
    }

    @Test func alwaysAllowSaysItKeepsAProjectRule() throws {
        let always = try #require(try dialog("opencode-10-permission-180").option(2))
        #expect(always.label == "Always allow")
        #expect(always.role == .approvePersistent)
        #expect(
            always.persistenceNote(program: .opencode)
                == "Always allows this for the project in OpenCode, so it isn't asked again.")
        // As OpenCode itself says while the option has focus.
        let note = try dialog("opencode-11-permission-right1-180").subject.notes.first
        #expect(note?.hasSuffix("for this project.") == true)
    }

    // MARK: Questions

    @Test func theQuestionDialogListsNumberedOptions() throws {
        let dialog = try dialog("opencode-13-question-180")
        #expect(dialog.kind == .openCodeQuestion)
        #expect(dialog.program == .opencode)
        #expect(dialog.title == "Do you prefer red or blue?")
        #expect(dialog.subject.question == "Do you prefer red or blue?")
        #expect(dialog.body == ["Do you prefer red or blue?"])
        #expect(dialog.rows == 33..<46)
        #expect(dialog.options.map(\.label) == ["red", "blue", "Type your own answer"])
        #expect(dialog.options.map(\.detail) == ["Prefer red", "Prefer blue", nil])
        #expect(dialog.options.map(\.number) == [1, 2, 3])
        #expect(dialog.options.map(\.role) == [.answer, .answer, .otherText])
        #expect(dialog.focus == DialogFocusState(focusedOrdinal: 1))
    }

    /// Several questions add a tab row and `⇆ tab`; those stay in the
    /// terminal.
    @Test func aMultiQuestionFormIsUnrecognized() throws {
        let single = Self.question(tabs: nil, footer: "↑↓ select  enter submit  esc dismiss")
        let dialog = try #require(BlockedDialogParser.parse(single, program: .opencode).dialog)
        #expect(dialog.options.map(\.label) == ["apple", "pear", "Type your own answer"])

        let several = Self.question(
            tabs: "Fruit  Size  Confirm", footer: "⇆ tab  ↑↓ select  enter confirm  esc dismiss")
        let excerpt = try #require(BlockedDialogParser.parse(several, program: .opencode).excerpt)
        #expect(excerpt.reason == "Heeler answers only OpenCode's single questions. Answer this one in the terminal.")
        #expect(excerpt.numbered.isEmpty)
    }

    // MARK: Anything else

    /// Esc on a subagent's permission asks what to do differently, in a
    /// field Heeler doesn't type into.
    @Test func aRejectFeedbackStageIsUnrecognized() throws {
        let excerpt = try #require(try parse("opencode-25-reject-feedback-180").excerpt)
        #expect(excerpt.reason == "OpenCode asks what to do differently before it rejects. Answer it in the terminal.")
        #expect(excerpt.numbered.isEmpty)
        #expect(excerpt.rows.count == 8)
        // The hints at the band's right edge show at the start of a line.
        #expect(
            excerpt.displayLines == [
                "", "△ Reject permission", "", "Tell OpenCode what to do differently", "", "",
                "enter confirm  esc cancel", "",
            ])
    }

    /// At 62 columns the target, its path, the labels and descriptions
    /// wrap, and the key hints take a row of their own.
    @Test(arguments: [
        "opencode-37-permission-long-62", "opencode-38-question-long-62", "opencode-42-reject-feedback-62",
    ])
    func phoneWidthDialogsParse(stem: String) throws {
        switch stem {
        case "opencode-37-permission-long-62":
            let path =
                "config/scratch-environments/placeholder-staging-environment/phone-width-capture/dummy-settings.env"
            let dialog = try dialog(stem)
            #expect(dialog.kind == .openCodePermission)
            #expect(dialog.body == ["Read \(path)"])
            #expect(dialog.subject.filePath == path)
            #expect(dialog.subject.notes == ["Path: \(path)"])
            #expect(dialog.rows == 25..<40)
            #expect(dialog.options.map(\.label) == ["Allow once", "Always allow", "Reject"])
            #expect(dialog.focus.focusedOrdinal == 1)
        case "opencode-38-question-long-62":
            let dialog = try dialog(stem)
            #expect(dialog.kind == .openCodeQuestion)
            #expect(
                dialog.subject.question
                    == "Which scratch fruit should the placeholder capture use for the phone-width layout check?")
            #expect(dialog.rows == 23..<40)
            #expect(
                dialog.options.map(\.label) == [
                    "Kiwi from the scratch fixtures folder that the earlier prompts named",
                    "Pear from the queued steer test that ran in this scratch session", "Type your own answer",
                ])
            #expect(
                dialog.options.map(\.detail) == [
                    "Keeps the kiwi placeholder",
                    "Keeps the pear placeholder from the steer test, which the queued prompt produced earlier", nil,
                ])
            #expect(dialog.options.map(\.number) == [1, 2, 3])
            #expect(dialog.focus.focusedOrdinal == 1)
        default:
            // The stage at 180 columns keeps its fingerprint.
            let excerpt = try #require(try parse(stem).excerpt)
            let wide = try #require(try parse("opencode-25-reject-feedback-180").excerpt)
            #expect(excerpt.reason == wide.reason)
            #expect(excerpt.numbered.isEmpty)
            #expect(excerpt.fingerprint == wide.fingerprint)
        }
    }

    /// Working, the session picker, the subagent panel, an empty session
    /// and the queued-prompt dock.
    @Test(arguments: [
        "opencode-08-working-180", "opencode-14-session-picker-180", "opencode-15-subagent-panel-180",
        "opencode-32-session-empty-62", "opencode-43-queued-dock-62",
    ])
    func screensWithoutADialogParseAsNone(stem: String) throws {
        #expect(try parse(stem) == .none)
    }

    // MARK: Helpers

    /// OpenCode's default dark theme, as the captures draw it.
    private static let screenFill = SGR.bg(10, 10, 10)
    private static let panel = SGR.bg(20, 20, 20)
    private static let band = SGR.bg(30, 30, 30)
    private static let focusFill = SGR.bg(250, 178, 131)
    private static let accent = SGR.fg(250, 178, 131)
    private static let text = SGR.fg(238, 238, 238)
    private static let muted = SGR.fg(128, 128, 128)
    private static let columns = 100

    /// One row behind the bar on `fill`, padded to the block's edge.
    /// `content` sets only foregrounds, or restores `fill` after a fill of
    /// its own.
    private static func row(_ fill: String, _ content: String = "") -> String {
        let padding = String(repeating: " ", count: columns - 5 - width(of: content))
        return screenFill + "  " + accent + panel + "┃" + fill + text + content + fill + padding + SGR.reset
            + screenFill + "  " + SGR.reset
    }

    private static func width(of styled: String) -> Int {
        TerminalCellWidth.width(
            of: styled.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression))
    }

    /// A permission to read `.env` like stem 10's, with these options, the
    /// first focused, and the key hints at the end of their row.
    private static func permission(options: [String]) -> ANSIScreen {
        // Each option has a blank on either side, and a blank parts them.
        var line = "  "
        for (index, label) in options.enumerated() {
            line += index == 0 ? focusFill + SGR.fg(10, 10, 10) + " \(label) " + band : text + "  \(label) "
        }
        let hints = "ctrl+f fullscreen  ⇆ select  enter confirm"
        line += String(repeating: " ", count: columns - 5 - width(of: line) - width(of: hints) - 3) + hints
        let rows = [
            "I'll check .env.", "", row(panel),
            row(panel, "  " + SGR.fg(245, 167, 66) + "△" + text + " Permission required"),
            row(panel, "    " + muted + "→" + text + " Read .env"), row(panel),
            row(panel, "  " + muted + "Path: .env"), row(panel), row(band), row(band, line), row(band),
        ]
        return ScreenFixture.synthetic(rows)
    }

    /// A form like stem 13's asking `Pick a fruit`, its first answer
    /// focused, with a tab row when it asks several questions.
    private static func question(tabs: String?, footer: String) -> ANSIScreen {
        var rows = ["I'll ask.", "", row(panel), row(panel, "  " + muted + "Questions"), row(panel)]
        if let tabs { rows += [row(panel, "  " + tabs), row(panel)] }
        rows += [row(panel, "  Pick a fruit"), row(panel)]
        for (index, label) in ["apple", "pear", "Type your own answer"].enumerated() {
            let number = index == 0 ? accent : muted
            rows.append(row(panel, "  " + number + "\(index + 1)." + text + " " + (index == 0 ? accent : text) + label))
        }
        rows += [row(panel), row(panel, "  " + footer), row(panel)]
        return ScreenFixture.synthetic(rows)
    }
}
