import Foundation
import Testing

@testable import Heeler

/// Grok Build's screen read just before a send, for a session other than
/// the one herdr reports: the Welcome screen, a Session line, and the
/// newest message on screen, from 1.0.62 captures and synthetic screens.
@Suite("Grok Build session check")
struct GrokSessionCheckTests {
    /// The session in `grok/core-turns.jsonl`, and others the captures and
    /// synthetic screens name.
    private static let bound = "01900000-0000-7000-8000-000000000004"
    private static let other = "01900000-0000-7000-8000-000000000054"

    /// A transcript whose turns each open with one of `prompts`, oldest
    /// first, as the reducer records them.
    private static func transcript(_ prompts: [String], needsOlderHistory: Bool = false) -> ChatTranscript {
        let recorded = prompts.enumerated().map { index, text in
            ChatRecordedPrompt(offset: UInt64(index) * 1_000, text: text, entryID: ChatEntryID("grok:\(index * 1_000)"))
        }
        return ChatTranscript(
            needsOlderHistory: needsOlderHistory, recordedPrompts: recorded, latestPromptOffset: recorded.last?.offset,
            turns: recorded.compactMap { $0.entryID.map { ChatTurn(firstEntryID: $0) } })
    }

    private static let kiwi = transcript(["Reply with exactly the word pong.", "Reply with the word kiwi."])

    private static func input(
        _ transcript: ChatTranscript = kiwi, session: String = bound, activity: ChatAgentActivity = .idle,
        polledSinceIdle: Bool = true, unrecorded: Set<String> = [], misdirected: Set<String> = []
    ) -> ChatSessionCheckInput {
        ChatSessionCheckInput(
            sessionID: session, transcript: transcript, activity: activity, polledSinceIdle: polledSinceIdle,
            unrecordedSendKeys: unrecorded, misdirectedSendKeys: misdirected)
    }

    /// An idle Grok whose scrollback shows `rows` from column 5.
    private static func screen(_ rows: [String], columns: Int = 120) -> ANSIScreen {
        GrokScreenBuilder(columns: columns, scrollback: rows).screen
    }

    private static func verdict(_ screen: ANSIScreen, _ input: ChatSessionCheckInput) -> ChatScreenSessionVerdict {
        GrokSessionCheck.verdict(screen, input)
    }

    // MARK: Session lines

    /// `/new` (grok-17) and `/fork` (grok-18) print the session the screen
    /// moved to. herdr follows `/new`, so it holds only until herdr says
    /// so; it never follows `/fork`.
    @Test(arguments: ["grok-17-session-new", "grok-18-session-fork"])
    func aSessionLineNamingAnotherSessionHolds(stem: String) throws {
        let session =
            stem == "grok-17-session-new"
            ? "01900000-0000-7000-8000-000000000009" : "01900000-0000-7000-8000-000000000001"
        let input = Self.input(Self.transcript(["Reply with exactly: two."]), session: session)

        #expect(
            Self.verdict(try ScreenFixture.screen(stem), input) == .otherSession(GrokSessionCheck.sessionLineReason))
    }

    @Test(arguments: ["grok-17-session-new", "grok-18-session-fork"])
    func theSessionHerdrFollowsPasses(stem: String) throws {
        let screen = try ScreenFixture.screen(stem)
        if stem == "grok-17-session-new" {
            #expect(GrokScreen(screen).sessionLine?.sessionID == "01900000-0000-7000-8000-000000000001")
            #expect(
                Self.verdict(screen, Self.input(Self.transcript([]), session: "01900000-0000-7000-8000-000000000001"))
                    == .unknown)
        } else {
            // The fork's copy of the parent's history shows above the line.
            #expect(GrokScreen(screen).sessionLine?.sessionID == "01900000-0000-7000-8000-000000000002")
            let input = Self.input(
                Self.transcript(["Reply with exactly: two."]), session: "01900000-0000-7000-8000-000000000002")
            #expect(Self.verdict(screen, input) == .thisSession)
        }
    }

    /// Grok wraps system lines at word ends and after an id's hyphens,
    /// keeping the indent: at 40 columns the ids split over rows.
    @Test func aSessionLineWrappedAtFortyColumnsStillMatches() {
        let new = Self.screen(
            [
                "Session 01900000-0000-7000-8000-", "000000000054, use /dashboard to", "switch between sessions", "",
            ], columns: 40)
        let fork = Self.screen(
            [
                "Session 01900000-0000-7000-8000-", "000000000054 (forked from", "01900000-0000-7000-8000-",
                "000000000004), use /dashboard to", "switch between sessions", "  (both agents share cwd)", "",
            ], columns: 40)

        for screen in [new, fork] {
            #expect(GrokScreen(screen).sessionLine?.sessionID == Self.other)
            #expect(Self.verdict(screen, Self.input()) == .otherSession(GrokSessionCheck.sessionLineReason))
        }
    }

    @Test func aSessionIdInAssistantTextIsIgnored() {
        let screen = Self.screen([
            "❯ Reply with the word kiwi.", "", "Session \(Self.other) was created yesterday.",
            "\(Self.other), use /dashboard to switch between sessions", "", "Worked for 3.4s",
        ])

        #expect(GrokScreen(screen).sessionLine == nil)
        #expect(Self.verdict(screen, Self.input()) == .thisSession)
    }

    /// Grok prints a Session line only into the scrollback of the session
    /// it names (1.0.45 `lifecycle.rs`, `load.rs`; the parent of a fork
    /// gets `Forked`), so the screen shows that session whatever messages
    /// follow the line, even this conversation's newest.
    @Test func aSessionLineHoldsWhateverMessagesFollowIt() throws {
        let screen = Self.screen([
            "Session \(Self.other), use /dashboard to switch between sessions", "", "❯ Reply with the word kiwi.", "",
            "kiwi", "", "Worked for 3.4s",
        ])
        #expect(Self.verdict(screen, Self.input()) == .otherSession(GrokSessionCheck.sessionLineReason))

        // grok-18, the fork's first message repeating the parent's newest.
        var rows = try ScreenFixture.text("grok-18-session-fork").components(separatedBy: "\r\n")
        rows[16] = rows[4]
        let fork = ANSIScreenDecoder.decode(rows.joined(separator: "\r\n"))
        #expect(GrokScreen(fork).userRows.map(\.text) == ["Reply with exactly: two.", "Reply with exactly: two."])
        let parent = Self.input(
            Self.transcript(["Reply with exactly: two."]), session: "01900000-0000-7000-8000-000000000001")
        #expect(Self.verdict(fork, parent) == .otherSession(GrokSessionCheck.sessionLineReason))
    }

    // MARK: The newest message

    /// grok-19: `/resume` moved the screen to a session herdr doesn't
    /// report; its sticky prompt is not in the bound transcript.
    @Test func aVisiblePromptThisConversationLacksHolds() throws {
        let screen = try ScreenFixture.screen("grok-19-resumed-other")

        #expect(
            GrokScreen(screen).userRows.last?.text.hasPrefix("Reply with just the word big. Ignore the filler") == true)
        #expect(
            Self.verdict(screen, Self.input(Self.transcript(["Reply with exactly the word pong."])))
                == .otherSession(GrokSessionCheck.unknownPromptReason))
    }

    @Test func theNewestRecordedPromptPasses() {
        let screen = Self.screen([
            "❯ Reply with exactly the word pong.", "", "pong", "", "❯ Reply with the word kiwi.",
        ])

        #expect(Self.verdict(screen, Self.input()) == .thisSession)
    }

    /// The terminal may be scrolled up to an earlier message.
    @Test func anOlderRecordedPromptSaysNothing() {
        let screen = Self.screen(["❯ Reply with exactly the word pong.", "", "pong", "", "Worked for 3.4s"])

        #expect(Self.verdict(screen, Self.input()) == .unknown)
    }

    /// A window that starts inside a long turn opens no turn of its own,
    /// so the newest prompt may be above it.
    @Test func noVerdictWhenTheNewestPromptIsAboveTheWindow() {
        let screen = Self.screen(["❯ Reply with the word lime.", "", "lime"])
        var transcript = Self.transcript([], needsOlderHistory: true)

        #expect(Self.verdict(screen, Self.input(transcript)) == .unknown)
        // Earlier turns in the window, but the newest opened with a notice.
        transcript = Self.kiwi
        transcript.turns.append(ChatTurn(firstEntryID: ChatEntryID("grok:5000:notice")))
        #expect(Self.verdict(screen, Self.input(transcript)) == .unknown)
        #expect(Self.verdict(screen, Self.input()) == .otherSession(GrokSessionCheck.unknownPromptReason))
    }

    /// A prompt typed in the terminal shows before Chat has read it.
    @Test func noVerdictBeforeTheIdlePollIsApplied() {
        let screen = Self.screen(["❯ Reply with the word lime."])

        #expect(Self.verdict(screen, Self.input(polledSinceIdle: false)) == .unknown)
    }

    /// Grok holds the user chunk back while it works, so the transcript
    /// may not have the prompt on screen yet.
    @Test func noVerdictWhileWorking() {
        let idle = Self.screen(["❯ Reply with the word lime."])
        var builder = GrokScreenBuilder(scrollback: ["❯ Reply with the word lime."])
        builder.status = .init(label: "Thinking…")

        #expect(Self.verdict(idle, Self.input(activity: .working)) == .unknown)
        #expect(Self.verdict(idle, Self.input(activity: .blocked)) == .unknown)
        #expect(Self.verdict(builder.screen, Self.input()) == .unknown)
    }

    @Test func onlyTheBottomUserRowCounts() {
        let newestLast = Self.screen(["❯ Reply with the word lime.", "", "lime", "", "❯ Reply with the word kiwi."])
        let unknownLast = Self.screen([
            "❯ Reply with the word kiwi.", "", "kiwi", "", "❯ Reply with the word lime.",
        ])
        let commandLast = Self.screen(["❯ Reply with the word lime.", "", "lime", "", "❯ /compact"])

        #expect(Self.verdict(newestLast, Self.input()) == .thisSession)
        #expect(Self.verdict(unknownLast, Self.input()) == .otherSession(GrokSessionCheck.unknownPromptReason))
        // Never an older row instead.
        #expect(Self.verdict(commandLast, Self.input()) == .unknown)
    }

    /// The scrollback shows commands, shell commands and pasted chips
    /// differently from what the transcript records.
    @Test(arguments: ["/compact", "!ls", "[Pasted text #1 +5 lines]", "[Image #1]"])
    func commandChipAndShellRowsSayNothing(row: String) {
        #expect(Self.verdict(Self.screen(["❯ \(row)"]), Self.input()) == .unknown)
    }

    /// Chat's own send shows at once, and the transcript records it a
    /// moment later.
    @Test func aSendStillOnItsWaySaysNothing() {
        let screen = Self.screen(["❯ Reply with the word lime. Then say", "  nothing else."])

        #expect(
            Self.verdict(screen, Self.input(unrecorded: ["Reply with the word lime. Then say nothing else."]))
                == .unknown)
        #expect(Self.verdict(screen, Self.input()) == .otherSession(GrokSessionCheck.unknownPromptReason))
    }

    /// A send another session took shows on that session's screen however
    /// old. Where it reads the same as this conversation's newest message,
    /// the screen can't tell which session it shows.
    @Test func aMisdirectedSendLikeTheNewestMessageSaysNothing() {
        let kiwi = Self.screen(["❯ Reply with the word kiwi."])
        let lime = Self.screen(["❯ Reply with the word lime."])

        #expect(Self.verdict(kiwi, Self.input(misdirected: ["Reply with the word kiwi. "])) == .unknown)
        #expect(Self.verdict(kiwi, Self.input()) == .thisSession)
        // A copy this conversation lacks still shows another session.
        #expect(
            Self.verdict(lime, Self.input(misdirected: ["Reply with the word lime. "]))
                == .otherSession(GrokSessionCheck.unknownPromptReason))
    }

    @Test(arguments: [
        "❯ Reply with the word kiwi.                                                            10:58 PM",
        "❯ Reply with the word kiwi.                                                    22:58:10 | Oct 19",
        "❯ Reply with the word kiwi.                                                         10:58 PM  █",
        "❯ Reply with the word kiwi.                                                                    █",
    ])
    func stripsBothTimestampFormsAndTheScrollbar(row: String) {
        let screen = Self.screen([row])

        #expect(GrokScreen(screen).userRows.map(\.text) == ["Reply with the word kiwi."])
        #expect(Self.verdict(screen, Self.input()) == .thisSession)
    }

    // MARK: Welcome

    /// grok-20: a message from the Welcome screen starts a new session.
    @Test func theWelcomeScreenOfAConversationWithHistoryHolds() throws {
        let screen = try ScreenFixture.screen("grok-20-welcome")

        #expect(Self.verdict(screen, Self.input()) == .otherSession(GrokSessionCheck.welcomeReason))
        #expect(
            Self.verdict(screen, Self.input(Self.transcript([], needsOlderHistory: true)))
                == .otherSession(GrokSessionCheck.welcomeReason))
    }

    /// At Grok's start the session has no prompt yet, and the message is
    /// its first.
    @Test func theWelcomeScreenOfANewSessionPasses() throws {
        let screen = try ScreenFixture.screen("grok-20-welcome")

        #expect(Self.verdict(screen, Self.input(Self.transcript([]))) == .unknown)
    }
}
