import Foundation
import Testing

@testable import Heeler

/// Oh My Pi 18.11.1's panels as captured live: the tool approval is a known
/// dialog, other titled panels hold sending as excerpts, and tool renderings
/// are not dialogs.
@Suite("OMP dialog parser")
struct OMPDialogParserTests {
    private func parse(_ stem: String) throws -> DialogParseResult {
        BlockedDialogParser.parse(try ScreenFixture.screen(stem), program: .omp)
    }

    private func dialog(_ stem: String) throws -> BlockedDialog {
        let result = try parse(stem)
        return try #require(result.dialog, "\(stem) parsed as \(result)")
    }

    @Test(arguments: [
        ("omp-24-approval-a-dialog", "echo approved-2", 33),
        ("omp-23-approval-a-ctrlq-early", "echo approved-1", 24),
    ])
    func approvalBashIsParsedWithCommandAndTwoOptions(stem: String, command: String, top: Int) throws {
        let dialog = try dialog(stem)
        #expect(dialog.kind == .ompApproval)
        #expect(dialog.program == .omp)
        #expect(dialog.title == "Allow tool: bash")
        #expect(dialog.subject.toolName == "bash")
        #expect(dialog.subject.command == command)
        #expect(dialog.subject.reason == nil)
        #expect(dialog.body == ["Command: \(command)"])
        #expect(dialog.rows == top..<(top + 5))
        #expect(dialog.options.map(\.label) == ["Approve", "Deny"])
        #expect(dialog.options.map(\.shortcut) == ["ctrl+q", "esc"])
        #expect(dialog.options.map(\.role) == [.approve, .decline])
        #expect(dialog.options.allSatisfy { $0.number == nil })
    }

    /// Typing during an approval goes to the prompt below and turns the
    /// footer's `type to steer instead` into `deny and send`.
    @Test func fingerprintIgnoresDraftFooterAndCountdown() throws {
        let clean = try dialog("omp-24-approval-a-dialog")
        let drafted = try dialog("omp-24-approval-d-typed-abc")
        #expect(clean.fingerprint == drafted.fingerprint)
        #expect(clean.fingerprint != (try dialog("omp-23-approval-a-ctrlq-early")).fingerprint)

        let counting = BlockedDialogParser.parse(
            Self.panel(title: "Allow tool: bash (30s)", details: ["Command: echo approved-2"]), program: .omp)
        #expect(counting.dialog?.title == "Allow tool: bash")
        #expect(counting.dialog?.fingerprint == clean.fingerprint)
    }

    @Test func aCutOffCommandAndAReasonAreRead() throws {
        let screen = Self.panel(
            title: "Allow tool: bash", details: ["Command: rm -rf build && make…", "Reason: Cleans the build"])
        let dialog = try #require(BlockedDialogParser.parse(screen, program: .omp).dialog)
        #expect(dialog.subject.command == "rm -rf build && make")
        #expect(dialog.subject.reason == "Cleans the build")
    }

    @Test func anApprovalWithoutItsKeysIsUnrecognized() throws {
        let screen = Self.panel(title: "Allow tool: bash", details: ["Command: ls"], footer: "↑/↓ scroll")
        #expect(BlockedDialogParser.parse(screen, program: .omp).excerpt != nil)
    }

    @Test func planReviewIsUnrecognized() throws {
        let excerpt = try #require(try parse("omp-31-plan-review").excerpt)
        #expect(excerpt.reason == "Heeler does not know Oh My Pi's \u{201C}Plan Review\u{201D} panel.")
        #expect(excerpt.numbered.isEmpty)
        #expect(excerpt.rows.first?.trimmedText.hasPrefix("╭─ Plan Review ─") == true)
    }

    /// Until Heeler answers OMP's questions, they hold sending as excerpts.
    @Test(arguments: ["omp-27-ask-a-dialog", "omp-28-ask2-a-dialog", "omp-29-guard-b-ask-with-draft"])
    func askPanelsAreUnrecognizedForNow(stem: String) throws {
        let excerpt = try #require(try parse(stem).excerpt, "\(stem)")
        #expect(excerpt.numbered.isEmpty)
        #expect(excerpt.rows.first?.trimmedText.hasPrefix("╭─ Ask ─") == true)
    }

    /// A focus move changes only the pointer, not the excerpt's fingerprint.
    @Test func anAskExcerptKeepsItsFingerprintAsFocusMoves() throws {
        let first = try #require(try parse("omp-27-ask-a-dialog").fingerprint)
        #expect(try parse("omp-27-ask-c-after-down").fingerprint == first)
    }

    /// Idle and working screens with tool renderings in the history, and
    /// the screen after a denial.
    @Test(arguments: [
        "omp-26-approval-b-idle", "omp-27-ask-e-idle", "omp-24-approval-e-enter-deny-and-send",
        "omp-09-tool-working-3s", "omp-08-empty-120-after-first", "omp-14-slash-popup", "omp-33-after-exit-2",
    ])
    func toolRenderBoxesAreNotDialogs(stem: String) throws {
        #expect(try parse(stem) == .none)
    }

    /// Tool renderings drawn right on the band still are not dialogs.
    @Test func untitledAndRuledPanelsOnTheBandAreNotDialogs() {
        for border in ["╭" + String(repeating: "─", count: 30) + "╮", "╭─── Ask 1 questions ─────────╮", "╭───  Ask ────╮"] {
            let screen = Self.panel(border: border, details: ["$ echo hi"])
            #expect(BlockedDialogParser.parse(screen, program: .omp) == .none, "\(border)")
        }
    }

    @Test func piNeverParses() throws {
        for stem in ["omp-24-approval-a-dialog", "omp-31-plan-review", "omp-27-ask-a-dialog"] {
            #expect(BlockedDialogParser.parse(try ScreenFixture.screen(stem), program: .pi) == .none)
        }
    }

    // MARK: Helpers

    private static let band =
        "\u{1B}[48;2;15;18;22m \u{2839} 1m  project \u{1B}[0m──3%────272K─"

    private static func panel(
        title: String, details: [String], footer: String = "ctrl+q approve · esc deny · type to steer instead"
    ) -> ANSIScreen {
        panel(border: "╭─ \(title) " + String(repeating: "─", count: 20) + "╮", details: details, footer: footer)
    }

    /// A panel resting on the working band, the prompt below it.
    private static func panel(border: String, details: [String], footer: String? = nil) -> ANSIScreen {
        var rows = ["Working…", border] + details.map { "│ \($0) │" }
        if let footer { rows += ["├" + String(repeating: "─", count: 30) + "┤", "│ \(footer) │"] }
        rows += ["╰" + String(repeating: "─", count: 30) + "╯", band, "╰─ "]
        return ScreenFixture.synthetic(rows)
    }
}
