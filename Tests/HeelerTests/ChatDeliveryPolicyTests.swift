import Foundation
import Testing

@testable import Heeler

/// Chat's delivery policy: the screen checks around a send, read through
/// `agent.read` and never through the PTY.
@MainActor
@Suite("Chat delivery policy")
struct ChatDeliveryPolicyTests {
    private static let rules = ChatSendRules(
        program: .codex, commands: ChatCommandMenu.commands(skills: [], agentIsIdle: true, program: .codex))

    /// Codex's composer holding a draft the user typed in the terminal.
    private static func draft(_ text: String) -> ANSIScreen {
        ScreenFixture.synthetic(
            ["• Done.", "", SGR.bold + "›" + SGR.reset + " " + text, "",
             "  " + SGR.bold + "? " + SGR.reset + "for shortcuts"])
    }

    @MainActor
    private final class Reads {
        var count = 0
        var pauses: [Duration] = []
    }

    private static func policy(
        activity: ChatAgentActivity = .idle, reads: Reads = Reads(),
        screen: @escaping @MainActor () throws -> ANSIScreen
    ) -> ComposerDeliveryPolicy {
        .chat(
            rules: rules, activity: { activity },
            readScreen: {
                reads.count += 1
                return try screen()
            },
            pause: { duration in await MainActor.run { reads.pauses.append(duration) } })
    }

    @Test func anEmptyInputBoxLetsTheMessageGo() async throws {
        let ready = try ScreenFixture.screen("codex-00-ready")
        let preflight = try #require(Self.policy { ready }.preflight)

        #expect(await preflight("hello") == nil)
    }

    @Test func aBlockedAgentIsRefusedWithoutReadingTheScreen() async throws {
        let reads = Reads()
        let preflight = try #require(Self.policy(activity: .blocked, reads: reads) { Self.draft("") }.preflight)

        #expect(await preflight("hello") == .agentBlocked)
        #expect(reads.count == 0)
    }

    @Test func textAlreadyInTheBoxHoldsTheMessage() async throws {
        let preflight = try #require(Self.policy { Self.draft("half typed") }.preflight)

        #expect(await preflight("hello") == .inputNotReady(InputBoxState.text("half typed").holdReason(for: .codex)))
    }

    /// Esc in Pi and Oh My Pi puts a steer the turn had not taken back into
    /// the input box, which then holds Chat's next message; so does a draft
    /// typed there, with nothing queued.
    @Test func aPiDraftMentionsWhatStopPutBack() {
        for program in [ChatProgram.pi, .omp] {
            #expect(
                InputBoxState.text("steer").holdReason(for: program)
                    == "The Agent's input box already has text, such as a draft or a steer that Stop returned. Send or clear it in the terminal first."
            )
        }
        #expect(!InputBoxState.text("draft").holdReason(for: .claude).contains("Stop"))
    }

    /// herdr reports Codex idle under its plan selector, so no card names
    /// it; the hold does. Every other dialog keeps the general copy.
    @Test func aCodexPlanSelectorIsNamedInTheHold() {
        let plan = InputBoxState.dialog(title: "Implement this plan?")
        #expect(
            plan.holdReason(for: .codex)
                == "Codex is asking whether to implement the plan. Answer it in the terminal first.")
        let general = "The Agent is showing a dialog. Answer it in the terminal first."
        #expect(InputBoxState.dialog(title: nil).holdReason(for: .codex) == general)
        #expect(plan.holdReason(for: .claude) == general)
    }

    /// Codex 0.162.1's Esc puts a follow-up queued with Tab back into the
    /// composer, which then holds Chat's next message.
    @Test func aCodexDraftMentionsWhatStopPutBack() {
        #expect(
            InputBoxState.text("follow-up").holdReason(for: .codex)
                == "The Agent's input box already has text, such as a draft or a message Stop returned. Send or clear it in the terminal first."
        )
        #expect(
            InputBoxState.text("draft").holdReason(for: .claude)
                == "The Agent's input box already has text. Send or clear it in the terminal first.")
    }

    /// OpenCode's `/undo` puts the undone prompt back in the box, and Up
    /// recalls an earlier one; the hold names both beside a draft.
    @Test func openCodeDraftHoldNamesUndoAndHistory() {
        #expect(
            InputBoxState.text("draft").holdReason(for: .opencode)
                == "The Agent's input box already has text, such as a draft, a prompt /undo put back, or one recalled with Up. Send or clear it in the terminal first."
        )
    }

    /// A home screen, dashboard or picker in place of the conversation's
    /// input box holds with the sentence the program's detector gave.
    @Test(arguments: ChatProgram.allCases)
    func aScreenWithNoComposerHoldsWithItsOwnReason(program: ChatProgram) {
        let reason = "Open this conversation in the terminal first."

        #expect(InputBoxState.noComposer(reason).holdReason(for: program) == reason)
    }

    @Test func anUnreadableScreenHoldsTheMessage() async throws {
        let preflight = try #require(Self.policy { throw TransportError.timedOut }.preflight)

        let refusal = await preflight("hello")

        guard case .inputNotReady(let reason) = refusal else {
            Issue.record("Expected inputNotReady, got \(String(describing: refusal))")
            return
        }
        #expect(reason.hasPrefix("Heeler couldn't check the Agent's input box."))
        #expect(refusal?.suggestsTerminal == true)
    }

    @Test func textLeftInTheBoxAfterTheDelayIsNotDelivered() async throws {
        let reads = Reads()
        let verify = try #require(Self.policy(reads: reads) { Self.draft("hello") }.verify)

        #expect(await verify("hello ") == false)
        #expect(reads.pauses == [DeliveryCheck.delay])
    }

    @Test func anEmptiedBoxOrAnUnreadableScreenCountsAsSent() async throws {
        let ready = try ScreenFixture.screen("codex-00-ready")
        let emptied = try #require(Self.policy { ready }.verify)
        let unreadable = try #require(Self.policy { throw TransportError.timedOut }.verify)

        #expect(await emptied("hello ") == true)
        #expect(await unreadable("hello ") == true)
    }

    /// What the Agent's state held ends with that state, for every program;
    /// what the rules refuse in the text waits for the text to change.
    @Test(arguments: ChatProgram.allCases)
    func holdsOnTheAgentEndWithTheirStateAndRefusalsOfTheTextDoNot(program: ChatProgram) async throws {
        let busy = ChatSendRules(
            program: program, commands: ChatCommandMenu.commands(skills: [], agentIsIdle: false, program: program))
        let blocked = try #require(
            ComposerDeliveryPolicy.chat(rules: busy, activity: { .blocked }, readScreen: { Self.draft("") }).preflight)
        let unreadable = try #require(
            ComposerDeliveryPolicy.chat(
                rules: busy, activity: { .working }, readScreen: { throw TransportError.timedOut }
            ).preflight)
        let statuses: [AgentStatus] = [.idle, .working, .blocked, .done, .unknown]
        func ending(_ refusal: ComposerRefusal?) throws -> [AgentStatus] {
            let refusal = try #require(refusal)
            return statuses.filter { refusal.endsWhenStatusBecomes($0) }
        }

        #expect(try ending(await blocked("hello")) == [.idle, .working, .done, .unknown])
        #expect(try ending(busy.validate("/compact")) == [.idle, .done])
        #expect(try ending(await unreadable("hello")) == statuses)
        for state in [
            InputBoxState.text("draft"), .disabled("Working."), .overlay("/compact"), .dialog(title: nil),
            .noComposer(""), .unknown(""),
        ] {
            #expect(try ending(.inputNotReady(state.holdReason(for: program))) == statuses)
        }
        for refusal in [busy.validate("!ls"), busy.validate("/nope")] {
            #expect(try ending(refusal).isEmpty)
        }
    }

    @Test func ompRefusalsOfTheTextOutliveEveryStatus() throws {
        let rules = ChatSendRules(
            program: .omp, commands: ChatCommandMenu.commands(skills: [], agentIsIdle: true, program: .omp))

        for draft in ["exit", "$ print(1)", ".", "-> later", "/compact keep the notes"] {
            let refusal = try #require(rules.validate(draft))
            for status in [AgentStatus.idle, .working, .blocked, .done, .unknown] {
                #expect(!refusal.endsWhenStatusBecomes(status), "\(draft)")
            }
        }
    }

    @Test func theRulesShapeWhatIsSentAndRefused() {
        let policy = Self.policy { Self.draft("") }

        #expect(policy.route == .chat)
        #expect(!policy.insertsIntoAttachWhenBlocked)
        #expect(policy.outgoingText("/compact") == "/compact ")
        #expect(policy.validate("!rm -rf build") != nil)
    }
}

/// Chat's reading of the Composer's messages: what the store matches, and
/// the echoes it still shows.
@MainActor
@Suite("Chat Composer echoes")
struct ChatComposerEchoesTests {
    private static let rules = ChatSendRules(
        program: .codex,
        commands: ChatCommandMenu.commands(
            skills: [AgentSkill(scope: .global, name: "review", description: nil, commandPrefix: "$")],
            agentIsIdle: true, program: .codex))

    private static func policy(verify: (@MainActor (String) async -> Bool)? = nil) -> ComposerDeliveryPolicy {
        ComposerDeliveryPolicy(
            route: .chat, insertsIntoAttachWhenBlocked: false, outgoingText: { rules.outgoingText($0) },
            validate: { rules.validate($0) }, preflight: nil, verify: verify)
    }

    private static func store(_ transport: ScriptedTransport) -> AgentComposerStore {
        AgentComposerStore(target: "w1:p1") { params in try await transport.promptAgent(params) }
    }

    @Test func onlyChatsMessagesAreMatchedAsHerdrTypedThem() async {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "from the terminal")
        await store.send()
        store.replaceDraft(with: "/review the diff")
        await store.send(policy: Self.policy())

        let sent = ChatComposerEchoes.sentMessages(store.messages, rules: Self.rules)

        #expect(sent.map(\.text) == ["$review the diff "])
        #expect(sent.map(\.isDelivered) == [true])
    }

    @Test func aRecordedMessageGivesWayToItsEntry() async {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "one")
        await store.send(policy: Self.policy())
        store.replaceDraft(with: "two")
        await store.send(policy: Self.policy())
        let ids = store.messages.map(\.id)

        let echoes = ChatComposerEchoes.pending(
            store.messages, statuses: [ids[0]: .recorded, ids[1]: .overdue])

        #expect(echoes.map(\.text) == ["two"])
        #expect(echoes.map(\.state) == [.unconfirmed])
    }

    @Test func aMessageTheStoreHasNotSeenGetsNoEcho() async {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "earlier")
        await store.send(policy: Self.policy())

        #expect(ChatComposerEchoes.pending(store.messages, statuses: [:]).isEmpty)
    }

    @Test func onlyTheLatestFailureShows() async {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailures([TransportError.timedOut, TransportError.timedOut])
        let store = Self.store(transport)
        store.replaceDraft(with: "first")
        await store.send(policy: Self.policy())
        store.replaceDraft(with: "second")
        await store.send(policy: Self.policy())

        let echoes = ChatComposerEchoes.pending(store.messages, statuses: [:])

        #expect(echoes.map(\.text) == ["second"])
        guard case .failed = echoes.first?.state else {
            Issue.record("Expected a failed echo")
            return
        }
    }

    @Test func textLeftInTheInputBoxShowsAsNotDelivered() async throws {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "stuck")
        await store.send(policy: Self.policy(verify: { _ in false }))
        try await waitUntil("the verify task should mark the message") {
            store.messages.first?.state == .undelivered
        }
        let id = try #require(store.messages.first?.id)

        let echoes = ChatComposerEchoes.pending(store.messages, statuses: [id: .awaiting])

        #expect(echoes.map(\.state) == [.notDelivered])
    }

    /// Text left in the input box that the user cleared there since: what
    /// the Chat store last saw in the box outranks the check after the send.
    @Test func textClearedFromTheInputBoxSinceShowsAsDiscarded() async throws {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "stuck")
        await store.send(policy: Self.policy(verify: { _ in false }))
        try await waitUntil("the verify task should mark the message") {
            store.messages.first?.state == .undelivered
        }
        let id = try #require(store.messages.first?.id)

        let echoes = ChatComposerEchoes.pending(store.messages, statuses: [id: .discarded])

        #expect(echoes.map(\.state) == [.discarded])
    }

    /// A `/compact` Pi said it had nothing to compact for.
    @Test func aRefusedSendSaysWhatTheProgramSaid() async throws {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "/compact")
        await store.send(policy: Self.policy())
        let id = try #require(store.messages.first?.id)

        let echoes = ChatComposerEchoes.pending(
            store.messages, statuses: [id: .refused("Pi had nothing to compact.")])

        #expect(echoes.map(\.state) == [.refused("Pi had nothing to compact.")])
    }

    /// A steer Esc put back in Pi's or Oh My Pi's input box.
    @Test func aSendFoundBackInTheInputBoxShowsAsNotDelivered() async throws {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "say KIWI")
        await store.send(policy: Self.policy())
        let id = try #require(store.messages.first?.id)

        let echoes = ChatComposerEchoes.pending(store.messages, statuses: [id: .returned])

        #expect(echoes.map(\.state) == [.notDelivered])
    }

    /// A steer Esc put back that the user then cleared in the terminal: it
    /// was never delivered, so it never reads as sent.
    @Test func aSendClearedFromTheInputBoxShowsAsDiscarded() async throws {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "say KIWI")
        await store.send(policy: Self.policy())
        let id = try #require(store.messages.first?.id)

        let echoes = ChatComposerEchoes.pending(store.messages, statuses: [id: .discarded])

        #expect(echoes.map(\.state) == [.discarded])
    }

    /// Like a failure, a discarded send shows only while it is Chat's
    /// latest message; one sent since moves the conversation on.
    @Test func aDiscardedSendGivesWayToANewerMessage() async throws {
        let transport = ScriptedTransport()
        let store = Self.store(transport)
        store.replaceDraft(with: "say KIWI")
        await store.send(policy: Self.policy())
        store.replaceDraft(with: "say yes")
        await store.send(policy: Self.policy())
        let ids = store.messages.map(\.id)

        let echoes = ChatComposerEchoes.pending(
            store.messages, statuses: [ids[0]: .discarded, ids[1]: .awaiting])

        #expect(echoes.map(\.text) == ["say yes"])
        #expect(echoes.map(\.state) == [.sent])
    }

    private func waitUntil(
        _ comment: Comment,
        timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }
}
