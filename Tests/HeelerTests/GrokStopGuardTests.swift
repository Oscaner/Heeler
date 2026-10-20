import Foundation
import Testing

@testable import Heeler

/// Whether Chat's Stop presses Ctrl+C in Grok Build, read from Grok Build
/// 1.0.62 captures and from synthetic screens `GrokScreenBuilder` lays out
/// the way Grok does. Ctrl+C cancels a running turn; elsewhere it clears a
/// draft, cancels a permission, skips a question, or quits Grok Build.
@Suite("Grok Build Stop guard")
struct GrokStopGuardTests {
    private static let notWorking =
        "Heeler can't see Grok Build working, so Stop pressed nothing. Stop it in the terminal with Ctrl+C."
    private static let otherView =
        "Grok Build is showing a menu or another view, so Stop pressed nothing. Close it in the terminal first."
    private static let asking =
        "Grok Build is asking something, so Stop pressed nothing. Answer it in Chat or the terminal."
    private static let unfocused =
        "Grok Build's input box doesn't have focus, so Stop pressed nothing. Stop it in the terminal."
    private static let draft =
        "Grok Build's input box has text, and Ctrl+C would only clear it. Stop it in the terminal."

    /// The captured cards: permissions, a question, the subagent panel, the
    /// rewind confirmation and the fork question.
    private static let cards: Set = [
        "grok-12-permission-command", "grok-13-permission-compound", "grok-14-permission-edit", "grok-15-question",
        "grok-16-subagent-panel", "grok-23-rewind-confirm", "grok-25-fork-question",
    ]

    /// The hints Grok's footer shows while a turn runs and the prompt has
    /// focus (grok-26).
    private static let workingHints = ["Shift+Tab:mode", "Ctrl+c:cancel", "Ctrl+.:shortcuts"]

    private static func verdict(_ screen: ANSIScreen, activity: ChatAgentActivity = .working) -> ChatStopVerdict {
        GrokStopGuard.verdict(ChatStopContext(screen: screen, activity: activity))
    }

    /// grok-05: a command running with a message queued.
    private static func queued(columns: Int) -> GrokScreenBuilder {
        GrokScreenBuilder(
            columns: columns,
            status: .init(
                label: "Sleep 40 seconds then echo two…", phase: "15s", turn: "18s ⇣25.8k",
                buttons: " [↓][stop]"),
            dock: ["   ▾ Queued 1", "     #1 After that, reply with the word three."],
            hints: [
                "Enter:send now", "Shift+Tab:mode", "Ctrl+c:cancel", "Ctrl+b:send to bg", "Ctrl+;:queue",
                "Ctrl+.:shortcuts",
            ])
    }

    /// A turn running a command, with `footer` in place of the prompt's
    /// hints when one is given.
    private static func running(footer: String? = nil) -> GrokScreenBuilder {
        GrokScreenBuilder(
            status: .init(label: "Sleep 45 seconds then echo done…"), hints: workingHints, footer: footer)
    }

    @Test(arguments: ["grok-03-working", "grok-05-queued", "grok-26-waiting-subagent", "grok-32-working-62x20"])
    func pressesWhileGrokShowsItWorking(stem: String) throws {
        #expect(Self.verdict(try ScreenFixture.screen(stem)) == .press)
    }

    /// Ctrl+C then puts the prompt back in Grok's input box, with no reply
    /// written. The spinner row, or the footer's cancel hint alone, shows
    /// the turn.
    @Test func pressesBeforeTheFirstOutputIsWritten() {
        let accepting = GrokScreenBuilder(
            scrollback: ["❯ Reply with the word kiwi."],
            status: .init(
                label: "Waiting for the agent to accept the prompt…", phase: nil, turn: "0.2s", buttons: " [stop]"),
            hints: Self.workingHints)
        let noStatusRowYet = GrokScreenBuilder(scrollback: ["❯ Reply with the word kiwi."], hints: Self.workingHints)

        #expect(Self.verdict(accepting.screen) == .press)
        #expect(Self.verdict(noStatusRowYet.screen) == .press)
    }

    /// The footer offers no `Ctrl+c:cancel` while Grok compacts; the
    /// spinner row shows the work.
    @Test func cancelsARunningCompaction() throws {
        let screen = try ScreenFixture.screen("grok-27-compacting")

        #expect(GrokScreen(screen).footer?.contains("Ctrl+c:cancel") == false)
        #expect(Self.verdict(screen) == .press)
    }

    /// Grok cuts the spinner row's label at these widths and drops its
    /// phase timer, with the queue between the row and the composer. At 40
    /// columns the footer stops before `Ctrl+c:cancel`; cut that way at 62
    /// too, the row is the only cue.
    @Test(arguments: [62, 40])
    func acceptsTheSpinnerRowWhenTheFooterIsCut(columns: Int) {
        var builder = Self.queued(columns: columns)
        #expect(Self.verdict(builder.screen) == .press)

        builder.footer = "Enter:send now  │  Shift+Tab:mode"
        #expect(GrokScreen(builder.screen).statusRow != nil)
        #expect(Self.verdict(builder.screen) == .press)
    }

    /// Ctrl+C on a draft only clears it. Ghost text is not a draft.
    @Test func refusesWhenTheComposerHoldsADraft() throws {
        let ghost = GrokScreenBuilder(
            status: .init(label: "Sleep 45 seconds then echo done…"), ghost: "Run the tests again",
            hints: ["Tab/→:accept suggestion", "Shift+Tab:mode", "Ctrl+c:cancel", "Ctrl+.:shortcuts"])

        #expect(Self.verdict(try ScreenFixture.screen("grok-04-working-draft")) == .refuse(Self.draft))
        #expect(Self.verdict(ghost.screen) == .press)
    }

    /// herdr says Working, but the screen shows no turn: Ctrl+C on an idle
    /// prompt arms Grok's quit. Background work's cue is not a turn.
    @Test func refusesWithoutAWorkingCue() throws {
        let screens = [
            try ScreenFixture.screen("grok-01-idle-empty"), GrokScreenBuilder().screen,
            GrokScreenBuilder(cue: "1 command still running").screen,
        ]

        for screen in screens {
            #expect(Self.verdict(screen) == .refuse(Self.notWorking))
        }
    }

    /// Blocked means herdr saw a card that the screen read came too early
    /// for.
    @Test(arguments: [ChatAgentActivity.idle, .blocked, .unknown])
    func refusesWhenHerdrIsNotWorking(activity: ChatAgentActivity) throws {
        let screen = try ScreenFixture.screen("grok-03-working")
        let reason = activity == .blocked ? Self.asking : Self.notWorking

        #expect(Self.verdict(screen, activity: activity) == .refuse(reason))
    }

    /// Cards take the composer's place, and Ctrl+C would cancel the
    /// permission or skip the question. On a menu, a picker, the dashboard
    /// or the Welcome view it clears the input or quits.
    @Test(arguments: [
        "grok-12-permission-command", "grok-13-permission-compound", "grok-14-permission-edit", "grok-15-question",
        "grok-16-subagent-panel", "grok-23-rewind-confirm", "grok-25-fork-question", "grok-07-slash-popup",
        "grok-10-btw", "grok-11-dashboard", "grok-20-welcome", "grok-21-resume-picker", "grok-22-rewind-picker",
        "grok-28-welcome-62", "grok-29-welcome-40",
    ])
    func refusesOverCardsMenusAndOtherViews(stem: String) throws {
        let screen = try ScreenFixture.screen(stem)
        let isCard = Self.cards.contains(stem)

        #expect((GrokScreen(screen).card != nil) == isCard)
        #expect(Self.verdict(screen) == .refuse(isCard ? Self.asking : Self.otherView))
    }

    /// On the dashboard's view of an agent, Ctrl+C would cancel that
    /// agent's turn, whichever conversation it is.
    @Test func refusesOnTheDashboardsViewOfAnAgent() {
        let screen = GrokScreenBuilder(
            status: .init(label: "Thinking…"), hints: ["Ctrl+\\:dashboard", "Ctrl+x:stop"] + Self.workingHints
        ).screen

        #expect(Self.verdict(screen) == .refuse(Self.otherView))
        // The same turn on the conversation's own view.
        let own = GrokScreenBuilder(status: .init(label: "Thinking…"), hints: Self.workingHints)
        #expect(Self.verdict(own.screen) == .press)
    }

    /// Shell and remember modes draw their own glyph and label in the box,
    /// where Ctrl+C would clear the text or leave the mode while the turn
    /// runs on.
    @Test(arguments: [("!", "Run shell command"), ("#", "Save memory note")])
    func refusesInShellAndRememberModes(glyph: String, label: String) {
        let screen = GrokScreenBuilder(
            status: .init(label: "Thinking…"), glyph: glyph, bottomLabel: label, hints: Self.workingHints
        ).screen

        #expect(GrokScreen(screen).composer?.mode == (glyph == "!" ? .bash : .remember))
        #expect(Self.verdict(screen) == .refuse(Self.otherView))
    }

    /// While a cancel is pending, Ctrl+C maps to Quit.
    @Test func refusesWhileCancelling() {
        let screen = GrokScreenBuilder(status: .init(label: "Cancelling…"), hints: Self.workingHints).screen

        #expect(Self.verdict(screen) == .refuse("Grok Build is already cancelling the turn."))
    }

    /// The pending press replaces every hint in the footer, and the press
    /// Grok waits for may not be a quit.
    @Test func refusesAPendingDoublePress() {
        let quit = Self.running(footer: "Ctrl+c:press again to quit").screen
        let newSession = Self.running(footer: "Ctrl+n:press again to new").screen

        #expect(
            Self.verdict(quit)
                == .refuse("Grok Build is waiting for a second key press to quit, so Stop pressed nothing."))
        #expect(
            Self.verdict(newSession)
                == .refuse("Grok Build is waiting for a second key press, so Stop pressed nothing."))
    }

    /// Grok offers `Ctrl+c:cancel` in every pane while a turn runs, and
    /// Ctrl+C cancels from there too. A footer with neither it nor a
    /// prompt hint leaves the press's target unknown.
    @Test func refusesWhenThePromptLacksFocus() {
        var tasks = Self.running(footer: "Enter:view  │  y:copy output  │  x:kill  │  h:show done")
        tasks.placeholder = "Build anything"
        var queuePane = tasks
        queuePane.footer =
            "x:delete row  │  e:edit  │  J/K:reorder  │  y:copy  │  Ctrl+Enter:send now  │  Ctrl+c:cancel"

        #expect(Self.verdict(tasks.screen) == .refuse(Self.unfocused))
        #expect(Self.verdict(queuePane.screen) == .press)
    }

    /// Compact mode, which Grok forces at 20 rows or fewer, cuts every
    /// footer to `Ctrl+.:shortcuts`, the cancel hint too. With the
    /// scrollback focused only the placeholder in the empty box shows it.
    @Test func refusesACompactScreenWithTheScrollbackFocused() throws {
        let screen = try ScreenFixture.screen("grok-33-working-scrollback-62x20")

        #expect(Self.verdict(screen) == .refuse(Self.unfocused))
    }

    /// Minimal mode draws no box (the 1.0.45 source; not captured), and
    /// Ctrl+C on its idle prompt quits at once.
    @Test func refusesInMinimalMode() {
        let screen = ScreenFixture.synthetic(
            ["❯ Reply with the word kiwi.", "", "", "", "", "", "", "⠋ Thinking… 1.2s", "❯ ",
             "Grok 4.7 Fast (high) · ctrl+o transcript"])

        #expect(GrokScreen(screen).isMinimal)
        #expect(Self.verdict(screen) == .refuse(Self.otherView))
    }
}
