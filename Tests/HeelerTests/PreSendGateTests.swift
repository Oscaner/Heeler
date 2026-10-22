import Foundation
import Testing

@testable import Heeler

@Suite("Pre-send gate")
struct PreSendGateTests {
    @Test("An empty box passes unless the Agent is Blocked")
    func emptyBox() {
        #expect(PreSendGate.check(.empty(placeholder: nil), activity: .idle) == .send)
        #expect(PreSendGate.check(.empty(placeholder: "Ask Codex to do anything"), activity: .working) == .send)
        #expect(PreSendGate.check(.empty(placeholder: nil), activity: .unknown) == .send)
        #expect(PreSendGate.check(.empty(placeholder: nil), activity: .blocked) == .holdBlocked)
    }

    @Test(
        "Every other state holds the message",
        arguments: [
            InputBoxState.text("draft"), .shellMode("ls"), .shellMode(""), .disabled("Input disabled."),
            .overlay("/compact"), .dialog(title: nil), .unknown("Claude's input box is not on screen."),
            .noComposer("Open this conversation in the terminal first."),
        ])
    func holds(state: InputBoxState) {
        #expect(PreSendGate.check(state, activity: .idle) == .hold(state))
        #expect(PreSendGate.check(state, activity: .blocked) == .holdBlocked)
    }

    @Test("Captured screens")
    func capturedScreens() throws {
        #expect(PreSendGate.check(try ScreenFixture.screen("claude-01-ready"), program: .claude, activity: .idle) == .send)
        #expect(PreSendGate.check(try ScreenFixture.screen("codex-00-ready"), program: .codex, activity: .idle) == .send)
        let bash = try ScreenFixture.screen("claude-02-c1-bash-blocked")
        #expect(PreSendGate.check(bash, program: .claude, activity: .blocked) == .holdBlocked)
        #expect(PreSendGate.check(bash, program: .claude, activity: .unknown) == .hold(.dialog(title: nil)))
        // The composer stays in view while asynchronous questions wait.
        let collapsed = try ScreenFixture.screen("codex-08-x4-async-collapsed")
        #expect(PreSendGate.check(collapsed, program: .codex, activity: .working) == .hold(.dialog(title: nil)))
        // herdr reports Codex idle under its plan selector.
        let plan = try ScreenFixture.screen("codex-19-x3-implement-plan")
        #expect(PreSendGate.check(plan, program: .codex, activity: .idle) == .hold(.dialog(title: "Implement this plan?")))
    }

    /// Grok Build takes a message only into an empty composer with prompt
    /// focus, working or not, or under its Welcome view. herdr reports
    /// menus, pickers and the dashboard idle, so the screen holds those.
    /// The dashboard's view of an agent passes here, and the session check
    /// reads whose agent it shows.
    @Test("Grok Build sends only into a focused, empty composer", arguments: ScreenFixture.grok)
    func grokSendsOnlyIntoAFocusedEmptyComposer(stem: String) throws {
        let sendable: Set = [
            "grok-01-idle-empty", "grok-03-working", "grok-05-queued", "grok-06-esc-toast", "grok-17-session-new",
            "grok-18-session-fork", "grok-19-resumed-other", "grok-20-welcome", "grok-27-compacting",
            "grok-28-welcome-62", "grok-29-welcome-40", "grok-30-idle-62x20", "grok-32-working-62x20",
            "grok-40-agent-view-other-62", "grok-41-agent-view-this-62", "grok-42-agent-view-dispatched-62",
            "grok-43-resumed-from-welcome-120", "grok-45-compaction-cancelled-62",
        ]
        let screen = try ScreenFixture.screen(stem)

        let decision = PreSendGate.check(screen, program: .grok, activity: .idle)

        if sendable.contains(stem) {
            #expect(decision == .send)
        } else {
            #expect(decision != .send)
        }
        #expect(PreSendGate.check(screen, program: .grok, activity: .blocked) == .holdBlocked)
    }
}

@Suite("Delivery check")
struct DeliveryCheckTests {
    @Test("The box emptied, or a dialog or Blocked took over: delivered")
    func delivered() {
        #expect(DeliveryCheck.verdict(.empty(placeholder: nil), activity: .working) == .delivered)
        #expect(DeliveryCheck.verdict(.dialog(title: nil), activity: .unknown) == .delivered)
        #expect(DeliveryCheck.verdict(.unknown("why"), activity: .blocked) == .delivered)
    }

    @Test("Text left in the box: not delivered, with the text")
    func notDelivered() {
        #expect(DeliveryCheck.verdict(.text("fix the tests"), activity: .idle) == .notDelivered("fix the tests"))
        #expect(DeliveryCheck.verdict(.shellMode("ls"), activity: .working) == .notDelivered("ls"))
    }

    @Test(
        "Anything else leaves the message marked as sent",
        arguments: [
            InputBoxState.shellMode(""), .disabled("Input disabled."), .overlay("/compact"),
            .unknown("Codex's composer is not on screen."),
            .noComposer("Open this conversation in the terminal first."),
        ])
    func unconfirmed(state: InputBoxState) {
        #expect(DeliveryCheck.verdict(state, activity: .idle) == .unconfirmed)
    }

    @Test("Captured screens after sending")
    func capturedScreens() throws {
        #expect(
            DeliveryCheck.verdict(try ScreenFixture.screen("claude-29-c3-after-immediate"), program: .claude, activity: .idle)
                == .delivered)
        #expect(
            DeliveryCheck.verdict(try ScreenFixture.screen("claude-02-c1-bash-blocked"), program: .claude, activity: .unknown)
                == .delivered)
        #expect(
            DeliveryCheck.verdict(try ScreenFixture.screen("codex-03-x2-after-esc"), program: .codex, activity: .idle)
                == .delivered)
    }

    @Test("The re-read waits three seconds")
    func delay() {
        #expect(DeliveryCheck.delay == .seconds(3))
    }

    /// Whitespace doesn't count: the box wraps a long message across rows,
    /// trims each, and may show only its end.
    @Test("Grok Build: the sent text left in the box is not delivered")
    func grokTextLeftFromTheSendIsNotDelivered() throws {
        let draft = try ScreenFixture.screen("grok-02-idle-draft")
        let sent = "Reply with the word kiwi."

        #expect(
            DeliveryCheck.verdict(draft, program: .grok, activity: .idle, sent: "hello draft ")
                == .notDelivered("hello draft"))
        #expect(
            DeliveryCheck.verdict(.text("Reply with the\nword kiwi."), program: .grok, activity: .working, sent: sent)
                == .notDelivered("Reply with the\nword kiwi."))
        #expect(
            DeliveryCheck.verdict(.text("word kiwi."), program: .grok, activity: .idle, sent: sent)
                == .notDelivered("word kiwi."))
    }

    /// Grok Build puts a draft stashed with Ctrl+S back after the next send,
    /// so other text there says nothing about the message.
    @Test("Grok Build: other text after the send is unconfirmed")
    func otherTextAfterAGrokSendIsUnconfirmed() throws {
        let restored = try ScreenFixture.screen("grok-24-restored-draft")

        #expect(
            DeliveryCheck.verdict(restored, program: .grok, activity: .working, sent: "Summarize the README ")
                == .unconfirmed)
        #expect(DeliveryCheck.verdict(.shellMode("ls"), program: .grok, activity: .idle, sent: "hello") == .unconfirmed)
        // Without the sent text, the plain verdict.
        #expect(
            DeliveryCheck.verdict(restored, program: .grok, activity: .idle)
                == .notDelivered("Reply with the word kiwi."))
    }

    @Test("Grok Build: a suggestion drawn after the send is delivered")
    func aGhostSuggestionAfterAGrokSendIsDelivered() {
        let suggestion = GrokScreenBuilder(
            ghost: "Now run the tests", hints: ["Tab/→:accept suggestion", "Shift+Tab:mode", "Ctrl+.:shortcuts"]
        ).screen

        #expect(
            DeliveryCheck.verdict(suggestion, program: .grok, activity: .idle, sent: "Fix the build ") == .delivered)
    }

    /// A send the dashboard's view of an agent took is checked in that
    /// view's box (grok-41; synthetic, the send left behind).
    @Test("Grok Build: the dashboard's view of an agent confirms a send")
    func theDashboardsViewOfAGrokAgentConfirmsASend() throws {
        let emptied = try ScreenFixture.screen("grok-41-agent-view-this-62")
        let left = GrokScreenBuilder(
            columns: 62, typed: "Reply with the word pear",
            hints: ["Ctrl+\\:dashboard", "Ctrl+[/]:prev/next agent", "Ctrl+x:stop"],
            header: "Se… │ main /p/t/hcl/pr… 21K / 256K │ ‹ 2/3 › │ [Dashboard]"
        ).screen

        #expect(
            DeliveryCheck.verdict(emptied, program: .grok, activity: .idle, sent: "Reply with the word pear ")
                == .delivered)
        #expect(
            DeliveryCheck.verdict(left, program: .grok, activity: .idle, sent: "Reply with the word pear ")
                == .notDelivered("Reply with the word pear"))
    }

    @Test(
        "Other programs: any text left in the box is not delivered",
        arguments: ChatProgram.allCases.filter { !$0.mayRefillInputBoxAfterSend })
    func otherProgramsKeepTheirVerdictForOtherText(program: ChatProgram) {
        #expect(
            DeliveryCheck.verdict(.text("draft"), program: program, activity: .idle, sent: "hello")
                == .notDelivered("draft"))
        #expect(
            DeliveryCheck.verdict(.shellMode("ls"), program: program, activity: .working, sent: "hello")
                == .notDelivered("ls"))
    }
}
