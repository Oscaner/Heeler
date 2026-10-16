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
    func holdsOnTheAgentAreTransientAndRefusalsOfTheTextAreNot(program: ChatProgram) async throws {
        let busy = ChatSendRules(
            program: program, commands: ChatCommandMenu.commands(skills: [], agentIsIdle: false, program: program))
        let blocked = try #require(
            ComposerDeliveryPolicy.chat(rules: busy, activity: { .blocked }, readScreen: { Self.draft("") }).preflight)
        let unreadable = try #require(
            ComposerDeliveryPolicy.chat(
                rules: busy, activity: { .working }, readScreen: { throw TransportError.timedOut }
            ).preflight)

        let holds = [await blocked("hello"), await unreadable("hello"), busy.validate("/compact")]
        let refusals = [busy.validate("!ls"), busy.validate("/nope")]

        for hold in holds {
            #expect(try #require(hold).isTransient)
        }
        for refusal in refusals {
            #expect(try #require(refusal).isTransient == false)
        }
        for state in [InputBoxState.text("draft"), .disabled("Working."), .overlay("/compact"), .dialog, .unknown("")] {
            #expect(ComposerRefusal.inputNotReady(state.holdReason(for: program)).isTransient)
        }
    }

    @Test func ompRefusalsOfTheTextAreNotTransient() throws {
        let rules = ChatSendRules(
            program: .omp, commands: ChatCommandMenu.commands(skills: [], agentIsIdle: true, program: .omp))

        for draft in ["exit", "$ print(1)", ".", "-> later", "/compact keep the notes"] {
            #expect(try #require(rules.validate(draft)).isTransient == false, "\(draft)")
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
