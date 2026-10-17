import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agent Chat store")
struct AgentChatStoreTests {
    private static let first = "e951205e-24af-4a5e-baa7-3ccbebd2de2c"
    private static let second = "5b0c6a51-6a3e-4c55-9d0c-9a2f4f1f0c11"
    private static let cwd = "/home/dev/proj"
    private static let host = UUID(uuidString: "6F1D5C2A-0000-4000-8000-00000000000A")!
    private static let start = Date(timeIntervalSince1970: 1_791_266_400)

    private static func path(_ session: String) -> String {
        "/home/dev/.claude/projects/-home-dev-proj/\(session).jsonl"
    }

    private static func agent(
        session: String?, status: AgentStatus = .idle, program: ChatProgram = .claude
    ) -> Agent {
        Agent(
            terminalID: "term-1", kind: program.rawValue, title: "", status: status, workspaceID: "w1",
            tabID: "t1", paneID: "w1:p1", cwd: cwd, revision: 1,
            agentSession: session.map {
                AgentSessionInfo(
                    agent: program.rawValue, kind: .id, source: "herdr:\(program.rawValue)", value: $0)
            })
    }

    /// What `agent.get` answers, and how often it was asked.
    private actor Server {
        var agent: Agent
        private(set) var reads = 0
        var failure: TransportError?
        private var shouldSuspend = false
        private var pendingRead: CheckedContinuation<Void, Never>?

        init(_ agent: Agent) {
            self.agent = agent
        }

        func read() async throws -> Agent {
            reads += 1
            let answer = agent
            if shouldSuspend {
                shouldSuspend = false
                await withCheckedContinuation { pendingRead = $0 }
            }
            if let failure { throw failure }
            return answer
        }

        func suspendNextRead() {
            shouldSuspend = true
        }

        func releaseRead() {
            pendingRead?.resume()
            pendingRead = nil
        }

        func fail(with failure: TransportError?) {
            self.failure = failure
        }

        func set(_ agent: Agent) {
            self.agent = agent
        }
    }

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_791_266_400)
    }

    @MainActor
    private struct Fixture {
        let files = VirtualHostFiles()
        let cache = VolatileChatTranscriptCache()
        let clock = Clock()
        let server: Server
        let store: AgentChatStore

        init(
            session: String?, program: ChatProgram = .claude,
            limits: TranscriptFollower.Limits = TranscriptFollower.Limits(),
            timing: AgentChatStore.Timing = AgentChatStore.Timing(
                activeInterval: .milliseconds(5), idleInterval: .milliseconds(5)),
            cachedSession: @escaping @Sendable (Agent) async -> AgentSessionInfo? = { _ in nil },
            screen: BlockedScreenIO = .unavailable
        ) {
            let agent = AgentChatStoreTests.agent(session: session, program: program)
            let server = Server(agent)
            let clock = clock
            self.server = server
            store = AgentChatStore(
                agentID: ConsoleAgent.ID(hostID: AgentChatStoreTests.host, paneID: agent.paneID),
                agent: agent, program: program,
                source: AgentChatSource(
                    hostID: AgentChatStoreTests.host, socketLocation: .defaultSession,
                    files: files.hostFiles(), agentInfo: { try await server.read() }, cache: cache,
                    adapter: NumberedChatReducer.adapter(limits: limits, wantsFirstLine: program == .codex),
                    cachedSession: cachedSession, screen: screen),
                timing: timing, now: { clock.now })
        }

        func advance(_ seconds: TimeInterval) {
            clock.now = clock.now.addingTimeInterval(seconds)
        }
    }

    private static func ids(_ store: AgentChatStore) -> [String] {
        store.conversation.transcript.entries.map(\.id.rawValue)
    }

    // MARK: Background work

    private static let journal =
        "/home/dev/.claude/projects/-home-dev-proj/\(first)/subagents/workflows/wf_1/journal.jsonl"

    private static func paced() -> Fixture {
        Fixture(
            session: first,
            timing: AgentChatStore.Timing(
                activeInterval: .seconds(1), idleInterval: .seconds(4),
                backgroundWorkStaleness: ChatBackgroundWork.Staleness(workflowQuiet: 7_200, subagentRun: 10_800)))
    }

    @Test func runningBackgroundWorkKeepsTheActivePaceUntilItEnds() async throws {
        let fixture = Self.paced()
        let launch = NumberedChatReducer.launch("s1", journal: nil, at: fixture.clock.now)
        await fixture.files.write(NumberedChatReducer.lines(0..<2) + launch, at: Self.path(Self.first))
        await fixture.store.step()
        #expect(fixture.store.backgroundWork.rows.map(\.id) == ["s1"])
        #expect(fixture.store.backgroundWork.isLive)

        // Past the linger after the last change, the running Subagent
        // still holds the active pace.
        fixture.advance(60)
        await fixture.store.step()
        #expect(fixture.store.interval == .seconds(1))

        await fixture.files.append(NumberedChatReducer.end("s1"), to: Self.path(Self.first))
        await fixture.store.step()
        #expect(fixture.store.backgroundWork.rows.map(\.item.state) == [.completed])
        #expect(fixture.store.interval == .seconds(4))
    }

    @Test func workRunningLongerThanItCouldIsStaleAndHoldsNothing() async throws {
        let fixture = Self.paced()
        let launch = NumberedChatReducer.launch("s1", journal: nil, at: fixture.clock.now.addingTimeInterval(-4 * 3_600))
        await fixture.files.write(NumberedChatReducer.lines(0..<2) + launch, at: Self.path(Self.first))
        await fixture.store.step()
        fixture.advance(60)
        await fixture.store.step()

        #expect(fixture.store.backgroundWork.rows.map(\.isStale) == [true])
        #expect(fixture.store.interval == .seconds(4))
    }

    @Test func aFailedReadFreezesTheListInsteadOfHoldingThePace() async throws {
        let fixture = Self.paced()
        let launch = NumberedChatReducer.launch("s1", journal: nil, at: fixture.clock.now)
        await fixture.files.write(NumberedChatReducer.lines(0..<2) + launch, at: Self.path(Self.first))
        await fixture.store.step()
        fixture.advance(60)

        await fixture.files.failNext(.status, with: TransportError.hostFileTimedOut)
        await fixture.store.step()

        #expect(fixture.store.backgroundWork.rows.map(\.id) == ["s1"])
        #expect(!fixture.store.backgroundWork.isLive)
        #expect(fixture.store.interval == .seconds(4))
    }

    @Test func savedBackgroundWorkShowsOnlyAfterALiveRead() async throws {
        let previous = Self.paced()
        let launch = NumberedChatReducer.launch("s1", journal: nil, at: previous.clock.now)
        await previous.files.write(NumberedChatReducer.lines(0..<2) + launch, at: Self.path(Self.first))
        await previous.store.step()
        #expect(previous.store.backgroundWork.rows.map(\.id) == ["s1"])
        let key = ChatCacheKey(hostID: Self.host, herdrSession: "", program: .claude, conversationID: Self.first)
        guard case .hit(let document) = await previous.cache.load(key) else {
            Issue.record("Expected a saved conversation")
            return
        }

        let fixture = Self.paced()
        await fixture.cache.save(document)
        await fixture.server.fail(with: .channelFailed(detail: "agent.get failed"))
        await fixture.store.step()

        #expect(fixture.store.conversation.isFromCache)
        #expect(Self.ids(fixture.store) == previous.store.conversation.transcript.entries.map(\.id.rawValue))
        #expect(fixture.store.backgroundWork.rows.isEmpty)

        await fixture.server.fail(with: nil)
        await fixture.files.write(NumberedChatReducer.lines(0..<2) + launch, at: Self.path(Self.first))
        fixture.store.retry()
        await fixture.store.step()
        await fixture.store.step()

        #expect(!fixture.store.conversation.isFromCache)
        #expect(fixture.store.backgroundWork.rows.map(\.id) == ["s1"])
        #expect(fixture.store.backgroundWork.isLive)
    }

    @Test func aWorkflowShowsItsJournalAndTheListResetsWithTheConversation() async throws {
        let fixture = Self.paced()
        let launch = NumberedChatReducer.launch("w1", journal: Self.journal, at: fixture.clock.now)
        await fixture.files.write(NumberedChatReducer.lines(0..<2) + launch, at: Self.path(Self.first))
        await fixture.files.write(
            #"{"type":"launched"}"# + "\n"
                + #"{"type":"started","key":"k1","agentId":"a1","label":"audit:one","phase":"Audit"}"# + "\n",
            at: Self.journal)
        await fixture.store.step()
        // The first poll after opening reads the journal.
        await fixture.store.step()
        #expect(fixture.store.backgroundWork.rows.first?.progress?.started == 1)

        fixture.store.agentDidChange(Self.agent(session: Self.second))
        #expect(fixture.store.backgroundWork == ChatBackgroundWork())
    }

    @Test func followsTheSessionHerdrReports() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))

        await fixture.store.step()

        #expect(fixture.store.conversation.phase == .following(path: Self.path(Self.first)))
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(await fixture.server.reads == 1)
    }

    @Test func noSessionIsExplainedWithoutReadingTheHost() async throws {
        let fixture = Fixture(session: nil)

        await fixture.store.step()

        #expect(fixture.store.conversation.phase == .unavailable(.noSession(.claude)))
        #expect(await fixture.files.statuses.isEmpty)
        #expect(await fixture.files.reads.isEmpty)
    }

    @Test(arguments: [ChatProgram.claude, .codex])
    func missingSessionExplainsTheMissingIdentityWithoutAnInstallDiagnosis(program: ChatProgram) {
        let reason = ChatUnavailableReason.noSession(program)
        #expect(reason.title == "Waiting for Conversation")
        #expect(reason.explanation.contains("session ID"))
        #expect(!reason.explanation.lowercased().contains("install"))
        #expect(reason.offersRetry)
    }

    @Test(arguments: [true, false])
    func aMissingTranscriptBannerClaimsSavedMessagesOnlyWhenThereAreSome(showingSaved: Bool) {
        let text = ChatUnavailableReason.notFound(searchedAll: true)
            .bannerText(showingSavedMessages: showingSaved)
        #expect(text.contains("Showing saved messages") == showingSaved)
        #expect(text.contains("any more") == showingSaved)
    }

    private static func snapshot(
        _ phase: ChatConversationSnapshot.Phase, entries: [ChatEntry] = []
    ) -> ChatConversationSnapshot {
        var snapshot = ChatConversationSnapshot(phase: phase)
        snapshot.transcript.entries = entries
        return snapshot
    }

    private static let savedEntry = ChatEntry(
        id: ChatEntryID("e0"), sourceOffset: 0, content: .assistant(ChatAssistantMessage(text: "hello")))

    /// A first prompt sent before the program writes its transcript: the
    /// timeline holds only the echo, and nothing is saved.
    @Test func aBannerOverOnlyASentEchoDoesNotClaimSavedMessages() {
        let lines = ChatBannerLine.lines(
            hostStatus: .connected, conversation: Self.snapshot(.unavailable(.notFound(searchedAll: true))),
            hasPendingEchoes: true)
        #expect(lines == [.unavailable(.notFound(searchedAll: true), showingSavedMessages: false)])
        #expect(lines.map(\.text) == ["Heeler hasn't found this conversation's transcript yet."])
    }

    @Test func aBannerOverKeptEntriesSaysTheyAreSaved() {
        let lines = ChatBannerLine.lines(
            hostStatus: .connected,
            conversation: Self.snapshot(.unavailable(.notFound(searchedAll: true)), entries: [Self.savedEntry]),
            hasPendingEchoes: false)
        #expect(lines.map(\.text) == ["The transcript isn't on the Host any more. Showing saved messages."])
    }

    @Test(arguments: [EventsSessionStatus?.none, .suspended])
    func aNotConnectedBannerClaimsSavedMessagesOnlyWhenThereAreSome(status: EventsSessionStatus?) {
        let saved = ChatBannerLine.lines(
            hostStatus: status, conversation: Self.snapshot(.locating, entries: [Self.savedEntry]),
            hasPendingEchoes: false)
        #expect(saved.map(\.text) == ["Not connected. Showing saved messages."])
        for conversation in [nil, Self.snapshot(.locating)] {
            let lines = ChatBannerLine.lines(hostStatus: status, conversation: conversation, hasPendingEchoes: true)
            #expect(lines.map(\.text) == ["Not connected."])
        }
    }

    /// With nothing to show, the unavailable view explains instead.
    @Test func noUnavailableBannerWithoutATimeline() {
        let lines = ChatBannerLine.lines(
            hostStatus: .connected, conversation: Self.snapshot(.unavailable(.mismatched)), hasPendingEchoes: false)
        #expect(lines.isEmpty)
    }

    /// A file under the session's name was read and holds another
    /// conversation, so Heeler did find it: the banner says what the
    /// unavailable view says, not that nothing was found yet.
    @Test(arguments: [true, false])
    func aMismatchedTranscriptBannerSaysItHoldsAnotherConversation(showingSaved: Bool) {
        let text = ChatUnavailableReason.mismatched.bannerText(showingSavedMessages: showingSaved)
        #expect(text.hasPrefix(ChatUnavailableReason.mismatched.explanation))
        #expect(text.contains("Showing saved messages") == showingSaved)
        #expect(!text.contains("hasn't found"))
    }

    @Test func aFailedSessionQueryIsVisibleAndRetryClearsItWithoutReadingFiles() async throws {
        let fixture = Fixture(session: nil)
        await fixture.server.fail(with: .channelFailed(detail: "agent.get failed"))

        await fixture.store.step()

        #expect(fixture.store.conversation.readFailure == .channelFailed(detail: "agent.get failed"))
        #expect(fixture.store.conversation.phase == .unavailable(.noSession(.claude)))
        #expect(await fixture.files.reads.isEmpty)

        await fixture.server.fail(with: nil)
        fixture.store.retry()
        await fixture.store.step()

        #expect(fixture.store.conversation.readFailure == nil)
        #expect(await fixture.server.reads == 2)
        #expect(await fixture.files.reads.isEmpty)
    }

    @Test func aFailedSessionQueryKeepsMessagesAndRetriesWhileFollowing() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        await fixture.store.step()
        await fixture.server.fail(with: .channelFailed(detail: "agent.get failed"))
        fixture.store.retry()

        await fixture.store.step()
        await fixture.store.step()

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(fixture.store.conversation.readFailure == .channelFailed(detail: "agent.get failed"))
        #expect(await fixture.server.reads == 2)

        await fixture.server.fail(with: nil)
        fixture.advance(5)
        await fixture.store.step()

        #expect(await fixture.server.reads == 3)
        #expect(fixture.store.conversation.readFailure == nil)
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
    }

    @Test func aFailedSessionQueryKeepsRestoredMessagesWhenTheTranscriptIsMissing() async throws {
        let previous = Fixture(session: Self.first)
        await previous.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        await previous.store.step()
        let key = ChatCacheKey(
            hostID: Self.host, herdrSession: "", program: .claude, conversationID: Self.first)
        guard case .hit(let document) = await previous.cache.load(key) else {
            Issue.record("Expected a saved conversation")
            return
        }
        let fixture = Fixture(session: Self.first)
        await fixture.cache.save(document)
        await fixture.server.fail(with: .channelFailed(detail: "agent.get failed"))

        await fixture.store.step()

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(fixture.store.conversation.isFromCache)
        #expect(fixture.store.conversation.readFailure == .channelFailed(detail: "agent.get failed"))

        await fixture.server.fail(with: nil)
        fixture.store.retry()
        await fixture.store.step()

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(fixture.store.conversation.isFromCache)
        #expect(fixture.store.conversation.readFailure == nil)
    }

    private static func seedCache(_ fixture: Fixture, session: String, numbers: Range<Int>) async throws {
        let previous = Fixture(session: session)
        await previous.files.write(NumberedChatReducer.lines(numbers), at: path(session))
        await previous.store.step()
        let key = ChatCacheKey(hostID: host, herdrSession: "", program: .claude, conversationID: session)
        guard case .hit(let document) = await previous.cache.load(key) else {
            Issue.record("Expected the first transcript read to be saved immediately")
            return
        }
        await fixture.cache.save(document)
    }

    @Test func cachedMessagesShowWhileTheFirstAgentQueryIsStillWaiting() async throws {
        let fixture = Fixture(session: Self.first)
        try await Self.seedCache(fixture, session: Self.first, numbers: 0..<3)
        await fixture.server.suspendNextRead()
        let step = Task { await fixture.store.step() }
        try await Self.waitUntil { await fixture.server.reads == 1 }

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(fixture.store.conversation.isFromCache)
        #expect(fixture.store.conversation.phase == .locating)
        #expect(await fixture.files.reads.isEmpty)
        let generation = fixture.store.conversationGeneration
        await fixture.files.write(NumberedChatReducer.lines(0..<4), at: Self.path(Self.first))
        await fixture.server.releaseRead()
        await step.value

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<4))
        #expect(!fixture.store.conversation.isFromCache)
        #expect(fixture.store.conversationGeneration == generation)
        await fixture.files.append(NumberedChatReducer.lines(4..<5), to: Self.path(Self.first))
        await fixture.store.step()
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<5))
        #expect(fixture.store.conversationGeneration == generation)
    }

    @Test func anInitiallyMissingLiveSessionRestoresTheLocalBindingBeforeTheHostAnswers() async throws {
        let binding = Self.agent(session: Self.first).agentSession
        let fixture = Fixture(session: nil, cachedSession: { _ in binding })
        try await Self.seedCache(fixture, session: Self.first, numbers: 0..<3)
        await fixture.files.write(NumberedChatReducer.lines(0..<4), at: Self.path(Self.first))
        await fixture.server.suspendNextRead()
        let step = Task { await fixture.store.step() }
        try await Self.waitUntil { await fixture.server.reads == 1 }

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(fixture.store.conversation.phase == .unavailable(.noSession(.claude)))
        #expect(fixture.store.conversation.isFromCache)
        #expect(await fixture.files.reads.isEmpty)
        #expect(await fixture.files.statuses.isEmpty)
        let generation = fixture.store.conversationGeneration
        await fixture.server.releaseRead()
        await step.value

        // The Host still reports nil. The old remote file must remain unread.
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(await fixture.files.reads.isEmpty)
        #expect(await fixture.files.statuses.isEmpty)
        await fixture.server.set(Self.agent(session: Self.first))
        fixture.store.retry()
        await fixture.store.step()
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<4))
        #expect(!fixture.store.conversation.isFromCache)
        #expect(fixture.store.conversationGeneration == generation)
    }

    @Test func aNewExplicitSessionReplacesTheInitiallyInferredCacheBinding() async throws {
        let binding = Self.agent(session: Self.first).agentSession
        let fixture = Fixture(session: nil, cachedSession: { _ in binding })
        try await Self.seedCache(fixture, session: Self.first, numbers: 0..<3)
        try await Self.seedCache(fixture, session: Self.second, numbers: 10..<12)
        await fixture.server.set(Self.agent(session: Self.second))

        await fixture.store.step()

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(10..<12))
        #expect(fixture.store.conversationGeneration == 2)
    }

    @Test func refreshedSessionRestoresOnlyItsOwnCachedMessages() async throws {
        let fixture = Fixture(session: Self.first)
        try await Self.seedCache(fixture, session: Self.first, numbers: 0..<3)
        try await Self.seedCache(fixture, session: Self.second, numbers: 10..<12)
        await fixture.server.set(Self.agent(session: Self.second))
        await fixture.files.failNext(.home, with: TransportError.hostFileTimedOut)

        await fixture.store.step()

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(10..<12))
        #expect(fixture.store.conversation.isFromCache)
    }

    @Test(arguments: [false, true])
    func anUnreportedSessionKeepsCachedMessagesUntilTheSameBindingReturns(viaSnapshot: Bool) async throws {
        let fixture = Fixture(session: Self.first)
        try await Self.seedCache(fixture, session: Self.first, numbers: 0..<3)
        await fixture.server.set(Self.agent(session: nil))
        let generation = fixture.store.conversationGeneration

        await fixture.store.step()

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(fixture.store.conversation.phase == .unavailable(.noSession(.claude)))
        #expect(fixture.store.conversation.isFromCache)
        #expect(await fixture.files.reads.isEmpty)
        #expect(await fixture.files.statuses.isEmpty)
        #expect(fixture.store.conversationGeneration == generation)

        await fixture.files.write(NumberedChatReducer.lines(0..<4), at: Self.path(Self.first))
        await fixture.server.set(Self.agent(session: Self.first))
        if viaSnapshot { fixture.store.agentDidChange(Self.agent(session: Self.first)) }
        fixture.store.retry()
        await fixture.store.step()

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<4))
        #expect(fixture.store.conversation.phase == .following(path: Self.path(Self.first)))
        #expect(!fixture.store.conversation.isFromCache)
        #expect(fixture.store.conversationGeneration == generation)
    }

    @Test func aSnapshotWithoutSessionStopsReadingTheOldFileUntilAnExplicitBinding() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        await fixture.store.step()
        let generation = fixture.store.conversationGeneration
        fixture.store.agentDidChange(Self.agent(session: nil))
        await fixture.server.set(Self.agent(session: nil))
        await fixture.files.clearRecords()
        await fixture.files.append(NumberedChatReducer.lines(3..<4), to: Self.path(Self.first))
        fixture.store.retry()
        await fixture.store.step()

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(fixture.store.conversation.isFromCache)
        #expect(fixture.store.conversation.phase == .unavailable(.noSession(.claude)))
        #expect(await fixture.files.reads.isEmpty)
        #expect(await fixture.files.statuses.isEmpty)
        #expect(fixture.store.conversationGeneration == generation)

        fixture.store.agentDidChange(Self.agent(session: Self.second))
        #expect(fixture.store.conversation.transcript.entries.isEmpty)
        #expect(fixture.store.conversationGeneration == generation + 1)
        await fixture.files.write(NumberedChatReducer.lines(10..<12), at: Self.path(Self.second))
        await fixture.server.set(Self.agent(session: Self.second))
        await fixture.store.step()
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(10..<12))
    }

    @Test(arguments: ["terminal", "workspace", "tab", "kind", "pane"], [false, true])
    func aReplacementAgentWithoutSessionDoesNotInheritThePreviousCache(
        changed: String, queried: Bool
    ) async throws {
        let fixture = Fixture(session: Self.first)
        try await Self.seedCache(fixture, session: Self.first, numbers: 0..<3)
        await fixture.store.step()
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        let replacement = Agent(
            terminalID: changed == "terminal" ? "term-2" : "term-1",
            kind: changed == "kind" ? "codex" : "claude", title: "", status: .idle,
            workspaceID: changed == "workspace" ? "w2" : "w1",
            tabID: changed == "tab" ? "t2" : "t1",
            paneID: changed == "pane" ? "w1:p2" : "w1:p1", cwd: Self.cwd, revision: 2)
        await fixture.server.set(replacement)
        if queried {
            fixture.store.retry()
            await fixture.store.step()
        } else {
            fixture.store.agentDidChange(replacement)
        }

        #expect(fixture.store.conversation.transcript.entries.isEmpty)
        #expect(!fixture.store.conversation.isFromCache)
        #expect(fixture.store.conversation.phase == .unavailable(.noSession(.claude)))
    }

    @Test func aSessionQueryCannotOverwriteANewerConsoleSession() async throws {
        let fixture = Fixture(session: Self.first)
        try await Self.seedCache(fixture, session: Self.first, numbers: 0..<3)
        try await Self.seedCache(fixture, session: Self.second, numbers: 10..<12)
        await fixture.server.suspendNextRead()
        let step = Task { await fixture.store.step() }
        try await Self.waitUntil { await fixture.server.reads == 1 }
        fixture.store.agentDidChange(Self.agent(session: Self.second))
        let generation = fixture.store.conversationGeneration
        await fixture.server.releaseRead()
        await step.value

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(10..<12))
        #expect(fixture.store.conversation.isFromCache)
        #expect(fixture.store.conversationGeneration == generation)
    }

    @Test func cancellingAWaitingRefreshKeepsTheCacheAndSkipsRemoteFileReads() async throws {
        let fixture = Fixture(session: Self.first)
        try await Self.seedCache(fixture, session: Self.first, numbers: 0..<3)
        await fixture.server.set(Self.agent(session: Self.second))
        await fixture.server.suspendNextRead()
        let step = Task { await fixture.store.step() }
        try await Self.waitUntil { await fixture.server.reads == 1 }
        let generation = fixture.store.conversationGeneration
        step.cancel()
        await fixture.server.releaseRead()
        await step.value

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(fixture.store.conversationGeneration == generation)
        #expect(fixture.store.conversation.readFailure == nil)
        #expect(await fixture.files.reads.isEmpty)
    }

    @Test func sessionQueryRecoveryDoesNotHideATranscriptFailure() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        await fixture.store.step()
        await fixture.server.fail(with: .channelFailed(detail: "agent.get failed"))
        fixture.store.retry()
        await fixture.store.step()
        await fixture.server.fail(with: nil)
        await fixture.files.failNext(.status, with: TransportError.hostFileTimedOut)
        fixture.store.retry()

        await fixture.store.step()

        #expect(fixture.store.conversation.readFailure == .hostFileTimedOut)
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
    }

    @Test func aCancelledSessionQueryDoesNotShowAReadFailure() async throws {
        let fixture = Fixture(session: nil)
        await fixture.server.fail(with: .cancelled)

        await fixture.store.step()

        #expect(fixture.store.conversation.readFailure == nil)
    }

    @Test func aSessionThatIsNotAnIDIsExplained() async throws {
        let fixture = Fixture(session: "my-thread-name")

        await fixture.store.step()

        #expect(fixture.store.conversation.phase == .unavailable(.unidentifiedSession))
    }

    @Test func aStatusChangeAsksHerdrAgainAndFollowsANewSession() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        await fixture.files.write(NumberedChatReducer.lines(7..<9), at: Self.path(Self.second))
        await fixture.store.step()

        // `/clear` starts a new session; no event says so.
        await fixture.server.set(Self.agent(session: Self.second, status: .working))
        fixture.store.agentDidChange(Self.agent(session: Self.first, status: .working))
        await fixture.store.step()

        #expect(fixture.store.conversation.phase == .following(path: Self.path(Self.second)))
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(7..<9))
        #expect(await fixture.server.reads == 2)
    }

    /// Shows Chat without its loop, so the test drives every turn.
    private static func showWithoutLoop(_ store: AgentChatStore) {
        store.show()
        store.suspend()
    }

    /// `/clear` typed in the terminal moves an Agent that stays idle to a
    /// new session, and no status change asks herdr about it.
    @Test func aShownIdleAgentIsAskedAgainAndFollowsANewSession() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        await fixture.files.write(NumberedChatReducer.lines(7..<9), at: Self.path(Self.second))
        Self.showWithoutLoop(fixture.store)
        await fixture.store.step()
        let generation = fixture.store.conversationGeneration
        await fixture.server.set(Self.agent(session: Self.second))

        fixture.advance(4)
        await fixture.store.step()
        #expect(await fixture.server.reads == 1)

        fixture.advance(1)
        await fixture.store.step()

        #expect(await fixture.server.reads == 2)
        #expect(fixture.store.conversationGeneration == generation + 1)
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(7..<9))
    }

    /// A working Agent's session changes with a status change, which asks
    /// anyway, and a hidden Chat never polls herdr.
    @Test(arguments: [true, false])
    func aWorkingOrHiddenAgentIsNotAskedAgainWithoutAReason(shown: Bool) async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        if shown {
            Self.showWithoutLoop(fixture.store)
            fixture.store.agentDidChange(Self.agent(session: Self.first, status: .working))
        }
        await fixture.store.step()
        #expect(await fixture.server.reads == 1)

        fixture.advance(5)
        await fixture.store.step()
        fixture.advance(30)
        await fixture.store.step()

        #expect(await fixture.server.reads == 1)
    }

    @Test func aSnapshotsNewSessionIsFollowedWithoutAsking() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        await fixture.files.write(NumberedChatReducer.lines(7..<9), at: Self.path(Self.second))
        await fixture.store.step()

        fixture.store.agentDidChange(Self.agent(session: Self.second))

        #expect(fixture.store.conversation.phase == .locating)
        #expect(fixture.store.conversation.transcript.entries.isEmpty)

        await fixture.server.set(Self.agent(session: Self.second))
        await fixture.store.step()

        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(7..<9))
    }

    @Test func aContinuedInLinkFollowsTheNewSession() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(
            NumberedChatReducer.lines(0..<2) + #"{"continued":"\#(Self.second)"}"# + "\n",
            at: Self.path(Self.first))
        await fixture.files.write(NumberedChatReducer.lines(5..<6), at: Self.path(Self.second))

        await fixture.store.step()
        await fixture.store.step()

        #expect(fixture.store.conversation.phase == .following(path: Self.path(Self.second)))
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(5..<6))
    }

    @Test func olderPagesLoadOnRequest() async throws {
        let fixture = Fixture(
            session: Self.first,
            limits: TranscriptFollower.Limits(
                tailWindow: 64, readChunk: 16, pollBudget: 1_024, olderPage: 32,
                maximumOlderPage: 128, lineStartSearch: 1_024, anchorLength: 8, headLength: 32,
                lineCap: 4_096, prefixCap: 16))
        await fixture.files.write(NumberedChatReducer.lines(0..<30), at: Self.path(Self.first))
        await fixture.store.step()
        let shown = Self.ids(fixture.store).count
        #expect(fixture.store.conversation.older == .available)

        fixture.store.loadOlder()

        #expect(fixture.store.conversation.older == .loading)

        await fixture.store.step()

        #expect(Self.ids(fixture.store).count > shown)
        #expect(Self.ids(fixture.store).last == "n-29")
    }

    @Test func aMissingTranscriptIsLookedForAgainWithBackoff() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.store.step()
        #expect(fixture.store.conversation.phase == .unavailable(.notFound(searchedAll: true)))
        let looked = await fixture.files.statuses.count

        await fixture.store.step()

        #expect(await fixture.files.statuses.count == looked)

        await fixture.files.write(NumberedChatReducer.lines(0..<2), at: Self.path(Self.first))
        fixture.advance(2)
        await fixture.store.step()

        #expect(fixture.store.conversation.phase == .following(path: Self.path(Self.first)))
    }

    @Test func openingChatLooksForAMissingTranscriptAtOnceAfterPrefetchesBackedOff() async throws {
        let fixture = Fixture(session: Self.first)
        // Background prefetches found nothing and backed off to 8 s.
        for delay in [0.0, 2, 4] {
            fixture.advance(delay)
            await fixture.store.step()
        }
        #expect(fixture.store.conversation.phase == .unavailable(.notFound(searchedAll: true)))
        let looked = await fixture.files.statuses.count

        fixture.store.show()
        fixture.store.hide()
        await fixture.store.step()
        let opened = await fixture.files.statuses.count
        #expect(opened > looked)

        // Then 2 s, not the prefetches' 8.
        fixture.advance(2)
        await fixture.store.step()
        #expect(await fixture.files.statuses.count > opened)
    }

    @Test func sendingLooksForTheTranscriptAtOnce() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.store.step()
        await fixture.files.write(NumberedChatReducer.lines(0..<2), at: Self.path(Self.first))

        fixture.store.noteSent()
        await fixture.store.step()

        #expect(fixture.store.conversation.phase == .following(path: Self.path(Self.first)))
    }

    @Test func prefetchSavesWithoutOpeningChatOrContinuingToPoll() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        let key = ChatCacheKey(
            hostID: Self.host, herdrSession: "", program: .claude, conversationID: Self.first)

        await fixture.store.prefetch()

        #expect(!fixture.store.isVisible)
        #expect(await Self.savedIDs(fixture.cache, key) == NumberedChatReducer.ids(0..<3))
        let reads = await fixture.files.reads.count
        await fixture.files.append(NumberedChatReducer.lines(3..<4), to: Self.path(Self.first))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await fixture.files.reads.count == reads)

        // Another fresh snapshot must persist its update even within the
        // normal visible loop's save interval.
        await fixture.store.prefetch()
        #expect(await Self.savedIDs(fixture.cache, key) == NumberedChatReducer.ids(0..<4))
        #expect(!fixture.store.isVisible)
    }

    @Test func showingChatDuringPrefetchContinuesTheSameSerializedReader() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        await fixture.server.suspendNextRead()
        let prefetch = Task { await fixture.store.prefetch() }
        try await Self.waitUntil { await fixture.server.reads == 1 }

        fixture.store.show()
        await fixture.store.prefetch()
        #expect(await fixture.server.reads == 1)
        await fixture.server.releaseRead()
        _ = await prefetch.value
        try await Self.waitUntil { Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3) }
        await fixture.files.append(NumberedChatReducer.lines(3..<4), to: Self.path(Self.first))
        try await Self.waitUntil { Self.ids(fixture.store) == NumberedChatReducer.ids(0..<4) }
        fixture.store.hide()
    }

    @Test func cancellingPrefetchStopsBeforeFilesAndAllowsTheNextSnapshot() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        await fixture.server.suspendNextRead()
        let prefetch = Task { await fixture.store.prefetch() }
        try await Self.waitUntil { await fixture.server.reads == 1 }

        prefetch.cancel()
        await fixture.server.releaseRead()
        _ = await prefetch.value

        #expect(await fixture.files.reads.isEmpty)
        #expect(!fixture.store.isVisible)
        await fixture.store.prefetch()
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))
        #expect(await fixture.server.reads == 2)
    }

    @Test func reconnectRetriesAfterACancelledPrefetchStillOwnsTheReader() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        #expect(await fixture.store.prefetch())
        await fixture.files.append(NumberedChatReducer.lines(3..<4), to: Self.path(Self.first))
        await fixture.server.suspendNextRead()
        let oldPrefetch = Task { await fixture.store.prefetch() }
        try await Self.waitUntil { await fixture.server.reads == 2 }

        // Disconnect cancels the caller, but the old remote request has
        // not returned yet. A fast reconnect must not accept its stale,
        // previously successful snapshot as a newly completed prefetch.
        oldPrefetch.cancel()
        #expect(fixture.store.conversation.phase == .following(path: Self.path(Self.first)))
        #expect(fixture.store.conversation.readFailure == nil)
        #expect(!(await fixture.store.prefetch()))
        #expect(await fixture.server.reads == 2)
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<3))

        await fixture.server.releaseRead()
        #expect(!(await oldPrefetch.value))
        #expect(await fixture.store.prefetch())
        #expect(await fixture.server.reads == 3)
        #expect(Self.ids(fixture.store) == NumberedChatReducer.ids(0..<4))
    }

    @Test func leavingChatSavesWhatShowed() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<3), at: Self.path(Self.first))
        let key = ChatCacheKey(
            hostID: Self.host, herdrSession: "", program: .claude, conversationID: Self.first)

        fixture.store.show()
        try await Self.waitUntil { fixture.store.conversation.transcript.entries.count == 3 }
        // Saves while following are spaced out; the clock stands still.
        await fixture.files.append(NumberedChatReducer.lines(3..<4), to: Self.path(Self.first))
        try await Self.waitUntil { fixture.store.conversation.transcript.entries.count == 4 }
        #expect(await Self.savedIDs(fixture.cache, key) == NumberedChatReducer.ids(0..<3))

        fixture.store.hide()
        try await Self.waitUntil {
            await Self.savedIDs(fixture.cache, key) == NumberedChatReducer.ids(0..<4)
        }

        #expect(!fixture.store.isVisible)
    }

    @Test func anotherWindowsChatKeepsFollowingWhenOneLeaves() async throws {
        let fixture = Fixture(session: Self.first)
        let left = UUID()
        let right = UUID()

        fixture.store.show(left)
        fixture.store.show(right)
        fixture.store.hide(left)

        #expect(fixture.store.isVisible)

        fixture.store.hide(right)

        #expect(!fixture.store.isVisible)
    }

    // MARK: Sent prompts

    private static func sent(_ id: UUID, _ text: String, delivered: Bool = true) -> AgentChatStore.SentMessage {
        AgentChatStore.SentMessage(id: id, text: text, isDelivered: delivered)
    }

    @Test func aSentPromptIsRecordedOnceTheTranscriptHasIt() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<2), at: Self.path(Self.first))
        await fixture.store.step()
        let id = UUID()

        fixture.store.updateSends([Self.sent(id, "hello ", delivered: false)])
        #expect(fixture.store.sendStatuses[id] == .awaiting)
        fixture.store.updateSends([Self.sent(id, "hello ")])
        await fixture.files.append(NumberedChatReducer.prompt("hello"), to: Self.path(Self.first))
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[id] == .recorded)
    }

    @Test func onlyAPromptRecordedAfterTheSendCounts() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.prompt("hello"), at: Self.path(Self.first))
        await fixture.store.step()
        let id = UUID()

        fixture.store.updateSends([Self.sent(id, "hello ", delivered: false)])
        fixture.store.updateSends([Self.sent(id, "hello ")])
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[id] == .awaiting)

        fixture.advance(10)
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[id] == .overdue)

        await fixture.files.append(NumberedChatReducer.prompt("hello"), to: Self.path(Self.first))
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[id] == .recorded)
    }

    @Test func aSentImagePathIsRecordedByThePlaceholderThatNamesIt() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<1), at: Self.path(Self.first))
        await fixture.store.step()
        let quoted = UUID()
        let other = UUID()
        let third = UUID()
        let sends = [
            Self.sent(quoted, "'/tmp/a shot.png' "), Self.sent(other, "/tmp/b.png "), Self.sent(third, "/tmp/c.png "),
        ]
        fixture.store.updateSends(sends.map { Self.sent($0.id, $0.text, delivered: false) })
        fixture.store.updateSends(sends)

        // The program names the file it read: only the send of that path
        // matches. A placeholder that names none (a Claude Code enqueue)
        // matches any one path.
        await fixture.files.append(
            NumberedChatReducer.prompt("[Image #1]", images: ["/tmp/a shot.png"]), to: Self.path(Self.first))
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[quoted] == .recorded)
        #expect(fixture.store.sendStatuses[other] == .awaiting)
        #expect(fixture.store.sendStatuses[third] == .awaiting)

        await fixture.files.append(NumberedChatReducer.prompt("[Image #1]", images: []), to: Self.path(Self.first))
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[other] == .recorded)
        #expect(fixture.store.sendStatuses[third] == .awaiting)
    }

    @Test func aCodexUndoIsFollowedOnAStatusChangeAndOnAnOverdueSend() async throws {
        let thread = "01a10f87-e025-7fb1-8974-8dd09937767a"
        let directory = "/home/dev/.codex/sessions/2026/10/06"
        let base = "\(directory)/rollout-2026-10-06T12-45-25-\(thread).jsonl"
        func segment(_ n: Int) -> String {
            "\(directory)/rollout-2026-10-06T13-0\(n)-00-\(thread)_01a10f9a-0000-7000-8000-00000000000\(n).jsonl"
        }
        let meta = #"{"type":"session_meta","payload":{"id":"\#(thread)"}}"# + "\n"
        let fixture = Fixture(session: thread, program: .codex)
        await fixture.files.write(meta + NumberedChatReducer.lines(0..<2), at: base)
        await fixture.store.step()
        #expect(fixture.store.conversation.phase == .following(path: base))

        // An undo continues in a sibling and leaves the base file as it
        // was. The first search after the turn ends fails and is tried again.
        await fixture.files.write(meta + NumberedChatReducer.lines(40..<42), at: segment(1))
        await fixture.files.failNext(.list, with: TransportError.channelFailed(detail: "list"))
        fixture.store.agentDidChange(Self.agent(session: thread, status: .working, program: .codex))
        await fixture.store.step()
        #expect(fixture.store.conversation.phase == .following(path: base))
        await fixture.store.step()
        #expect(fixture.store.conversation.phase == .following(path: segment(1)))
        #expect(Self.ids(fixture.store).suffix(2) == ["n-40", "n-41"])

        // A send recorded only in a newer sibling is found once overdue.
        let id = UUID()
        fixture.store.updateSends([Self.sent(id, "hello ", delivered: false)])
        fixture.store.updateSends([Self.sent(id, "hello ")])
        await fixture.files.write(meta + NumberedChatReducer.prompt("hello"), at: segment(2))
        await fixture.store.step()
        #expect(fixture.store.sendStatuses[id] == .awaiting)
        fixture.advance(10)
        await fixture.store.step()
        #expect(fixture.store.sendStatuses[id] == .overdue)
        await fixture.store.step()
        #expect(fixture.store.conversation.phase == .following(path: segment(2)))
        #expect(fixture.store.sendStatuses[id] == .recorded)
    }

    @Test func twoIdenticalSendsNeedTwoRecordedCopies() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<1), at: Self.path(Self.first))
        await fixture.store.step()
        let first = UUID()
        let second = UUID()
        fixture.store.updateSends([Self.sent(first, "go ", delivered: false), Self.sent(second, "go ", delivered: false)])
        fixture.store.updateSends([Self.sent(first, "go "), Self.sent(second, "go ")])

        await fixture.files.append(NumberedChatReducer.prompt("go"), to: Self.path(Self.first))
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[first] == .recorded)
        #expect(fixture.store.sendStatuses[second] == .awaiting)

        await fixture.files.append(NumberedChatReducer.prompt("go"), to: Self.path(Self.first))
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[second] == .recorded)
    }

    @Test func aSentCompactIsRecordedByTheCompaction() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<1), at: Self.path(Self.first))
        await fixture.store.step()
        let id = UUID()
        fixture.store.updateSends([Self.sent(id, "/compact ", delivered: false)])
        fixture.store.updateSends([Self.sent(id, "/compact ")])

        await fixture.files.append(NumberedChatReducer.compaction, to: Self.path(Self.first))
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[id] == .recorded)
    }

    @Test func aSendIntoAnEarlierConversationMatchesAnywhereInTheNext() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<20), at: Self.path(Self.first))
        await fixture.files.write(NumberedChatReducer.prompt("fork me"), at: Self.path(Self.second))
        await fixture.store.step()
        let id = UUID()
        fixture.store.updateSends([Self.sent(id, "fork me ", delivered: false)])
        fixture.store.updateSends([Self.sent(id, "fork me ")])

        // The prompt landed at the start of a session herdr reports next,
        // far before where the first file had been read to.
        await fixture.server.set(Self.agent(session: Self.second))
        fixture.store.agentDidChange(Self.agent(session: Self.second))
        await fixture.store.step()

        #expect(fixture.store.conversation.phase == .following(path: Self.path(Self.second)))
        #expect(fixture.store.sendStatuses[id] == .recorded)
    }

    @Test func anUnrecordedSendFromAnEarlierConversationStopsShowing() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<2), at: Self.path(Self.first))
        await fixture.files.write(NumberedChatReducer.lines(5..<6), at: Self.path(Self.second))
        await fixture.store.step()
        let id = UUID()
        fixture.store.updateSends([Self.sent(id, "lost ", delivered: false)])
        fixture.store.updateSends([Self.sent(id, "lost ")])

        await fixture.server.set(Self.agent(session: Self.second))
        fixture.store.agentDidChange(Self.agent(session: Self.second))
        fixture.advance(10)
        await fixture.store.step()

        #expect(fixture.store.sendStatuses[id] == .abandoned)
    }

    @Test func aMessageFirstSeenDeliveredGetsNoEcho() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.lines(0..<2), at: Self.path(Self.first))
        await fixture.store.step()
        let id = UUID()

        fixture.store.updateSends([Self.sent(id, "earlier ")])

        #expect(fixture.store.sendStatuses[id] == .abandoned)
    }

    @Test func aMessageTheComposerDroppedIsForgotten() async throws {
        let fixture = Fixture(session: Self.first)
        let id = UUID()
        fixture.store.updateSends([Self.sent(id, "refused ", delivered: false)])

        fixture.store.updateSends([])

        #expect(fixture.store.sendStatuses.isEmpty)
    }

    // MARK: Pi and Oh My Pi skills

    private static let piSession = "01a14046-b00d-75aa-98ce-6267745b012d"
    private static let piHeader = #"{"type":"session","version":3,"id":"\#(piSession)","cwd":"\#(cwd)"}"#

    /// A store following a Pi or Oh My Pi session through the production
    /// adapter, and the text Chat sends for `/probe from chat`.
    private static func piPath(_ program: ChatProgram) -> String {
        let directory = program == .pi ? ".pi" : ".omp"
        return "/home/dev/\(directory)/agent/sessions/--home-dev-proj--/2026-10-15_\(piSession).jsonl"
    }

    private static func piAgent(_ program: ChatProgram, status: AgentStatus = .idle) -> Agent {
        Agent(
            terminalID: "term-1", kind: program.rawValue, title: "", status: status, workspaceID: "w1",
            tabID: "t1", paneID: "w1:p1", cwd: cwd, revision: 1,
            agentSession: AgentSessionInfo(
                agent: program.rawValue, kind: .path, source: "herdr:\(program.rawValue)", value: piPath(program)))
    }

    private static func skillStore(
        _ program: ChatProgram, clock: Clock = Clock(), cache: VolatileChatTranscriptCache = VolatileChatTranscriptCache(),
        screen: BlockedScreenIO = .unavailable, server: Server? = nil
    ) throws -> (
        files: VirtualHostFiles, store: AgentChatStore, path: String, sent: String
    ) {
        let path = piPath(program)
        let agent = piAgent(program)
        let files = VirtualHostFiles()
        let store = AgentChatStore(
            agentID: ConsoleAgent.ID(hostID: host, paneID: agent.paneID), agent: agent, program: program,
            source: AgentChatSource(
                hostID: host, socketLocation: .defaultSession, files: files.hostFiles(),
                agentInfo: { try await server?.read() ?? agent },
                cache: cache,
                adapter: try #require(ChatTranscriptAdapter.standard(for: program)), screen: screen),
            timing: AgentChatStore.Timing(activeInterval: .milliseconds(5), idleInterval: .milliseconds(5)),
            now: { clock.now })
        let rules = ChatSendRules(
            program: program,
            commands: [
                ChatCommand(
                    name: "probe", summary: nil, kind: .skill(prefix: ChatCommandMenu.skillCommandPrefix),
                    isEnabled: true)
            ])
        return (files, store, path, rules.outgoingText("/probe from chat"))
    }

    @Test func ompSkillSendIsRecorded() async throws {
        let (files, store, path, sent) = try Self.skillStore(.omp)
        await files.write(Self.piHeader + "\n", at: path)
        await store.step()
        let id = UUID()
        store.updateSends([Self.sent(id, sent, delivered: false)])
        store.updateSends([Self.sent(id, sent)])

        await files.append(
            #"{"type":"custom_message","customType":"skill-prompt","content":"SKILL BODY","display":true,"details":{"name":"probe","args":"from chat","prompt":"/skill:probe from chat","lineCount":1},"attribution":"user","id":"s1","parentId":null}"#
                + "\n", to: path)
        await store.step()

        #expect(sent == "/skill:probe from chat ")
        #expect(store.sendStatuses[id] == .recorded)
    }

    @Test func piSkillSendIsRecorded() async throws {
        let (files, store, path, sent) = try Self.skillStore(.pi)
        await files.write(Self.piHeader + "\n", at: path)
        await store.step()
        let id = UUID()
        store.updateSends([Self.sent(id, sent, delivered: false)])
        store.updateSends([Self.sent(id, sent)])

        await files.append(
            #"{"type":"message","id":"u1","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"<skill name=\"probe\" location=\"/home/dev/.pi/agent/skills/probe/SKILL.md\">\nSKILL BODY\n</skill>\n\nfrom chat"}]}}"#
                + "\n", to: path)
        await store.step()

        #expect(sent == "/skill:probe from chat ")
        #expect(store.sendStatuses[id] == .recorded)
    }

    // MARK: Pi steers Esc put back

    /// The Agent's pane as Chat reads it, and how often it was read.
    private actor Pane {
        var screen: ANSIScreen
        private(set) var reads = 0

        init(_ screen: ANSIScreen) {
            self.screen = screen
        }

        func read() -> ANSIScreen {
            reads += 1
            return screen
        }

        func show(_ screen: ANSIScreen) {
            self.screen = screen
        }

        nonisolated var io: BlockedScreenIO {
            BlockedScreenIO(
                readScreen: { await self.read() }, sendKeys: { _ in }, paste: { _ in })
        }
    }

    /// Pi's idle editor (pi-36) holding `lines`, or empty.
    private static func piEditor(_ lines: String...) throws -> ANSIScreen {
        let text = try ScreenFixture.text("pi-36-steer-back-in-editor")
        return ANSIScreenDecoder.decode(
            text.replacingOccurrences(of: "Queued steer: say MANGO.", with: lines.joined(separator: "\r\n")))
    }

    /// Steers sent while Pi works, then Esc before the turn takes them: Pi
    /// puts the text back in its editor (pi-36) and never records it.
    private static func stoppedSteers(
        _ program: ChatProgram, texts: [String], screen: ANSIScreen? = nil, server: Server? = nil
    ) async throws -> (files: VirtualHostFiles, store: AgentChatStore, pane: Pane, clock: Clock, ids: [UUID]) {
        let clock = Clock()
        let pane = Pane(try screen ?? ScreenFixture.screen("pi-36-steer-back-in-editor"))
        let (files, store, path, _) = try Self.skillStore(program, clock: clock, screen: pane.io, server: server)
        await files.write(Self.piHeader + "\n" + Self.ompMessage("u1", parent: nil, role: "user", "go"), at: path)
        await store.step()
        store.agentDidChange(Self.piAgent(program, status: .working))
        let messages = texts.map { (id: UUID(), text: $0) }
        store.updateSends(messages.map { Self.sent($0.id, $0.text, delivered: false) })
        store.updateSends(messages.map { Self.sent($0.id, $0.text) })
        clock.now = clock.now.addingTimeInterval(10)
        await store.step()
        for message in messages {
            #expect(store.sendStatuses[message.id] == .overdue)
        }
        store.agentDidChange(Self.piAgent(program, status: .idle))
        return (files, store, pane, clock, messages.map(\.id))
    }

    private static func stoppedSteer(
        _ program: ChatProgram, text: String, screen: ANSIScreen? = nil, server: Server? = nil
    ) async throws -> (files: VirtualHostFiles, store: AgentChatStore, pane: Pane, clock: Clock, id: UUID) {
        let (files, store, pane, clock, ids) = try await stoppedSteers(
            program, texts: [text], screen: screen, server: server)
        return (files, store, pane, clock, try #require(ids.first))
    }

    /// One idle spell passes and herdr reports the next turn ending.
    private static func nextIdleSpell(_ store: AgentChatStore, _ program: ChatProgram, clock: Clock) async {
        store.agentDidChange(Self.piAgent(program, status: .working))
        await store.step()
        store.agentDidChange(Self.piAgent(program, status: .idle))
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
    }

    @Test func aSteerStopPutBackInTheEditorIsReturnedUntilRecorded() async throws {
        let (files, store, pane, clock, id) = try await Self.stoppedSteer(.pi, text: "Queued steer: say MANGO. ")

        // Pi may still be moving the steer back.
        await store.step()
        #expect(await pane.reads == 0)
        #expect(store.sendStatuses[id] == .overdue)

        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        await store.step()

        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .returned)

        // Sent from the terminal after all, the transcript has it.
        await files.append(
            Self.ompMessage("u2", parent: "u1", role: "user", "Queued steer: say MANGO."), to: Self.piPath(.pi))
        await store.step()

        #expect(store.sendStatuses[id] == .recorded)
    }

    /// The box must hold the send and nothing else: a short send found
    /// inside an unrelated draft is not the steer Esc put back.
    @Test func aShortSendInsideALongerDraftStaysOverdue() async throws {
        let (_, store, pane, clock, id) = try await Self.stoppedSteer(.pi, text: "say ")

        clock.now = clock.now.addingTimeInterval(1)
        await store.step()

        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .overdue)
    }

    /// Pi puts every queued steer back at once, a blank line between each.
    @Test func severalSteersStopPutBackTogetherAreAllReturned() async throws {
        let (_, store, pane, clock, ids) = try await Self.stoppedSteers(
            .pi, texts: ["say KIWI ", "say MANGO. ", "say LIME "],
            screen: try Self.piEditor("say KIWI", "", "say LIME"))

        clock.now = clock.now.addingTimeInterval(1)
        await store.step()

        #expect(await pane.reads == 1)
        #expect(ids.map { store.sendStatuses[$0] } == [.returned, .overdue, .returned])
    }

    /// Esc puts back only the steers of the turn it stops. A send overdue
    /// from an earlier turn is not looked for again, whatever the box
    /// shows later.
    @Test func anOverdueSendFromAnEarlierTurnIsNotLookedForAgain() async throws {
        let (_, store, pane, clock, id) = try await Self.stoppedSteer(
            .pi, text: "Queued steer: say MANGO. ", screen: try Self.piEditor())
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .overdue)

        await pane.show(try ScreenFixture.screen("pi-36-steer-back-in-editor"))
        await Self.nextIdleSpell(store, .pi, clock: clock)

        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .overdue)
    }

    /// A returned send is an observation: once the user clears the box in
    /// the terminal, the next idle spell's read finds it discarded, which
    /// it stays. It was never delivered, so it is not overdue.
    @Test func aReturnedSendTheBoxNoLongerHoldsIsDiscarded() async throws {
        let (_, store, pane, clock, id) = try await Self.stoppedSteer(.pi, text: "Queued steer: say MANGO. ")
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        #expect(store.sendStatuses[id] == .returned)

        // Still there a spell later.
        await Self.nextIdleSpell(store, .pi, clock: clock)
        #expect(await pane.reads == 2)
        #expect(store.sendStatuses[id] == .returned)

        await pane.show(try Self.piEditor())
        await Self.nextIdleSpell(store, .pi, clock: clock)

        #expect(await pane.reads == 3)
        #expect(store.sendStatuses[id] == .discarded)

        // The box is not looked at for it again.
        await pane.show(try ScreenFixture.screen("pi-36-steer-back-in-editor"))
        await Self.nextIdleSpell(store, .pi, clock: clock)
        clock.now = clock.now.addingTimeInterval(60)
        await store.step()

        #expect(await pane.reads == 3)
        #expect(store.sendStatuses[id] == .discarded)
    }

    /// The read before a send also shows whether the box still holds a
    /// returned send, without a read of its own.
    @Test func aReadBeforeASendDiscardsAReturnedSendTheBoxNoLongerHolds() async throws {
        let (_, store, pane, clock, id) = try await Self.stoppedSteer(.pi, text: "Queued steer: say MANGO. ")
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        #expect(store.sendStatuses[id] == .returned)

        store.inputBoxWasRead(try ScreenFixture.screen("pi-36-steer-back-in-editor"))
        #expect(store.sendStatuses[id] == .returned)

        store.inputBoxWasRead(try Self.piEditor("a draft of my own"))
        await store.step()

        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .discarded)
    }

    /// Text the user added to a returned steer in the terminal hides where
    /// the steer ends, but the steer is still in the box: neither the read
    /// before a send nor an idle spell's read discards it.
    @Test func aReturnedSendTheUserAddedToInTheBoxStaysReturned() async throws {
        let (_, store, pane, clock, id) = try await Self.stoppedSteer(.pi, text: "Queued steer: say MANGO. ")
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        #expect(store.sendStatuses[id] == .returned)

        let edited = try Self.piEditor("Queued steer: say MANGO. and check X")
        store.inputBoxWasRead(edited)
        #expect(store.sendStatuses[id] == .returned)

        await pane.show(edited)
        await Self.nextIdleSpell(store, .pi, clock: clock)
        #expect(await pane.reads == 2)
        #expect(store.sendStatuses[id] == .returned)

        // Cleared at last.
        store.inputBoxWasRead(try Self.piEditor())
        #expect(store.sendStatuses[id] == .discarded)
    }

    /// The steer the user added to and then sent from the terminal is in
    /// the prompt the transcript records, so that prompt settles it.
    @Test func aReturnedSendTheUserAddedToAndSentIsRecorded() async throws {
        let (files, store, _, clock, id) = try await Self.stoppedSteer(.pi, text: "Queued steer: say MANGO. ")
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        store.inputBoxWasRead(try Self.piEditor("Queued steer: say MANGO. and check X"))
        #expect(store.sendStatuses[id] == .returned)

        store.inputBoxWasRead(try Self.piEditor())
        await files.append(
            Self.ompMessage("u2", parent: "u1", role: "user", "Queued steer: say MANGO. and check X"),
            to: Self.piPath(.pi))
        await store.step()

        #expect(store.sendStatuses[id] == .recorded)
    }

    /// Pi 0.85.1 at the phone's 62 columns: Stop 2 s after a steer puts it
    /// back while its echo is still inside the timeout, then the user adds
    /// to it, a Chat send is held, and Enter in the terminal sends it all.
    /// The steer is found returned at once, so the prompt settles it.
    @Test func aSendMadeWhileIdleIsNotLookedForInTheBoxBeforeItIsOverdue() async throws {
        let capture = try ScreenFixture.text("pi-40-phone-extended-steer")
        let range = try #require(capture.range(of: "say FIG and also say PEAR", options: .backwards))
        let clock = Clock()
        // The editor still shows the text herdr just typed.
        let pane = Pane(ANSIScreenDecoder.decode(capture.replacingCharacters(in: range, with: "say FIG")))
        let (files, store, path, _) = try Self.skillStore(.pi, clock: clock, screen: pane.io)
        await files.write(Self.piHeader + "\n", at: path)
        store.agentDidChange(Self.piAgent(.pi, status: .working))
        await store.step()
        store.agentDidChange(Self.piAgent(.pi, status: .idle))
        await store.step()
        clock.now = clock.now.addingTimeInterval(5)

        let id = UUID()
        store.updateSends([Self.sent(id, "say FIG", delivered: false)])
        store.updateSends([Self.sent(id, "say FIG")])
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()

        #expect(await pane.reads == 0)
        #expect(store.sendStatuses[id] == .awaiting)
    }

    @Test func aReturnedSteerExtendedOnThePhoneIsRecorded() async throws {
        let records = [
            ##"{"type":"message","id":"dcfb765c","parentId":null,"timestamp":"2026-10-17T03:58:00.714Z","message":{"role":"user","content":[{"type":"text","text":"run sleep 40 with bash, then reply: ok"}],"timestamp":1792209480714}}"##,
            ##"{"type":"message","id":"6a04c408","parentId":"dcfb765c","timestamp":"2026-10-17T03:58:02.924Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Running sleep 40 via bash, then replying ok.","thinkingSignature":"{\"id\":\"rs_7c3ac87e-1c7b-961b-9bf8-0ddc730bfc37\",\"summary\":[{\"text\":\"Running sleep 40 via bash, then replying ok.\",\"type\":\"summary_text\"}],\"type\":\"reasoning\",\"status\":\"completed\",\"encrypted_content\":\"qxkzShyrpNcpoBRidtN3Sq0oayhAJnohMakiye+6HSrMARqPLSOvjoqQFwAfbkR8gZ+dQITPLbgNExuyPPsBKhGf6DsCwxx8cegQtL+IYnPv7uhC4+K1lgNihAdHvxaXF9ribah+cZtiMy6ZHW553QKhWQZx7rYhZz7/a2XqZb6wBCcari4d8vtlNtsizIH3ywBCKaGKWozw/yxB0qD4nBWpRYB8dPv/yq6k5loNtPs9ZwHqC2Crc2E+JOe0mp9zxdDFoKiF2AI\"}"},{"type":"toolCall","id":"call-f4bfa82d-4cb3-4a0b-a7d8-3f55e366b25a-3|fc_7c3ac87e-1c7b-961b-9bf8-0ddc730bfc37_0","name":"bash","arguments":{"command":"sleep 40","timeout":60}}],"api":"openai-responses","provider":"xai","model":"grok-4.5","usage":{"input":94,"output":54,"cacheRead":7168,"cacheWrite":0,"reasoning":39,"totalTokens":7316,"cost":{"input":0.000188,"output":0.000324,"cacheRead":0.0021504,"cacheWrite":0,"total":0.0026623999999999997}},"stopReason":"toolUse","timestamp":1792209480715,"responseId":"7c3ac87e-1c7b-961b-9bf8-0ddc730bfc37","rawStopReason":"completed"}}"##,
            ##"{"type":"message","id":"41d0569e","parentId":"6a04c408","timestamp":"2026-10-17T03:58:13.068Z","message":{"role":"toolResult","toolCallId":"call-f4bfa82d-4cb3-4a0b-a7d8-3f55e366b25a-3|fc_7c3ac87e-1c7b-961b-9bf8-0ddc730bfc37_0","toolName":"bash","content":[{"type":"text","text":"Command aborted"}],"details":{},"isError":true,"timestamp":1792209493068}}"##,
            ##"{"type":"message","id":"230cb2fa","parentId":"41d0569e","timestamp":"2026-10-17T03:58:13.069Z","message":{"role":"assistant","content":[],"api":"openai-responses","provider":"xai","model":"grok-4.5","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"error","errorMessage":"This operation was aborted","timestamp":1792209493069}}"##,
            ##"{"type":"message","id":"929aa8c6","parentId":"230cb2fa","timestamp":"2026-10-17T03:58:37.242Z","message":{"role":"user","content":[{"type":"text","text":"say FIG and also say PEAR"}],"timestamp":1792209517241}}"##,
            ##"{"type":"message","id":"5ecb20e9","parentId":"929aa8c6","timestamp":"2026-10-17T03:58:39.432Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"","thinkingSignature":"{\"id\":\"rs_20af3db3-28ae-9efc-93b2-58737484644f\",\"summary\":[],\"type\":\"reasoning\",\"status\":\"completed\",\"encrypted_content\":\"EY3OTsyOVY7cG1jjBLa5vX/QCTg/mibrpKUS2S9RW1I3Zo94/Jb+VNFnTEPiq75LGvR4+VAQ7HzqfJVWdbXPJTrs\"}"},{"type":"text","text":"FIG\nPEAR","textSignature":"{\"v\":1,\"id\":\"msg_20af3db3-28ae-9efc-93b2-58737484644f\"}"}],"api":"openai-responses","provider":"xai","model":"grok-4.5","usage":{"input":168,"output":15,"cacheRead":7168,"cacheWrite":0,"reasoning":11,"totalTokens":7351,"cost":{"input":0.000336,"output":9e-05,"cacheRead":0.0021504,"cacheWrite":0,"total":0.0025764}},"stopReason":"stop","timestamp":1792209517242,"responseId":"20af3db3-28ae-9efc-93b2-58737484644f","rawStopReason":"completed"}}"##,
        ]
        let capture = try ScreenFixture.text("pi-40-phone-extended-steer")
        func editor(_ text: String) throws -> ANSIScreen {
            let range = try #require(capture.range(of: "say FIG and also say PEAR", options: .backwards))
            return ANSIScreenDecoder.decode(capture.replacingCharacters(in: range, with: text))
        }
        let clock = Clock()
        let pane = Pane(try editor("say FIG"))
        let (files, store, path, _) = try Self.skillStore(.pi, clock: clock, screen: pane.io)
        await files.write(Self.piHeader + "\n" + records[0] + "\n" + records[1] + "\n", at: path)
        store.agentDidChange(Self.piAgent(.pi, status: .working))
        await store.step()
        let id = UUID()
        store.updateSends([Self.sent(id, "say FIG", delivered: false)])
        store.updateSends([Self.sent(id, "say FIG")])
        await store.step()
        await files.append(records[2] + "\n" + records[3] + "\n", to: path)
        store.agentDidChange(Self.piAgent(.pi, status: .idle))
        await store.step()
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        await store.step()
        #expect(store.sendStatuses[id] == .returned)

        await pane.show(try editor("say FIG and also say PEAR"))
        clock.now = clock.now.addingTimeInterval(10)
        await store.step()
        store.inputBoxWasRead(try editor("say FIG and also say PEAR"))
        #expect(store.sendStatuses[id] == .returned)

        await pane.show(try editor(""))
        store.agentDidChange(Self.piAgent(.pi, status: .working))
        await files.append(records[4] + "\n", to: path)
        await store.step()
        #expect(store.sendStatuses[id] == .recorded)
        await files.append(records[5] + "\n", to: path)
        store.agentDidChange(Self.piAgent(.pi, status: .idle))
        await store.step()
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        await store.step()
        #expect(store.sendStatuses[id] == .recorded)
    }

    /// Only a send seen among more text takes a prompt that merely contains
    /// it: a cleared one is not recorded when a longer prompt mentions it,
    /// only no longer shown.
    @Test func aClearedSendIsNotSettledByALongerPrompt() async throws {
        let (files, store, _, clock, id) = try await Self.stoppedSteer(.pi, text: "Queued steer: say MANGO. ")
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        store.inputBoxWasRead(try Self.piEditor())
        #expect(store.sendStatuses[id] == .discarded)

        await files.append(
            Self.ompMessage("u2", parent: "u1", role: "user", "Queued steer: say MANGO. and check X"),
            to: Self.piPath(.pi))
        await store.step()

        #expect(store.sendStatuses[id] == .abandoned)
    }

    /// A cleared send shows while it is Chat's latest message, until the
    /// transcript records a prompt after it, such as one the terminal
    /// sent: under that newer turn it would read out of order.
    @Test func aClearedSendStopsShowingOnceALaterPromptIsRecorded() async throws {
        let text = "Queued steer: say MANGO. "
        let (files, store, _, clock, id) = try await Self.stoppedSteer(.pi, text: text)
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        store.inputBoxWasRead(try Self.piEditor())
        await store.step()
        #expect(store.sendStatuses[id] == .discarded)

        await files.append(
            Self.ompMessage("u2", parent: "u1", role: "user", "say PLUM"), to: Self.piPath(.pi))
        await store.step()

        #expect(store.sendStatuses[id] == .abandoned)
    }

    /// Sent from the terminal after all: the box empties before the
    /// transcript has it, and the recorded copy still settles the send.
    @Test func aDiscardedSendTheTranscriptRecordsLaterIsRecorded() async throws {
        let (files, store, _, clock, id) = try await Self.stoppedSteer(.pi, text: "Queued steer: say MANGO. ")
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        #expect(store.sendStatuses[id] == .returned)

        store.inputBoxWasRead(try Self.piEditor())
        #expect(store.sendStatuses[id] == .discarded)

        await files.append(
            Self.ompMessage("u2", parent: "u1", role: "user", "Queued steer: say MANGO."), to: Self.piPath(.pi))
        await store.step()

        #expect(store.sendStatuses[id] == .recorded)
    }

    /// Sent again from Chat once cleared: the new send takes the recorded
    /// copy instead of leaving it unconfirmed, and the cleared one, with a
    /// prompt recorded after it, no longer shows.
    @Test func aSendAgainFromChatTakesTheRecordedCopyBeforeADiscardedOne() async throws {
        let text = "Queued steer: say MANGO. "
        let (files, store, _, clock, id) = try await Self.stoppedSteer(.pi, text: text)
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        store.inputBoxWasRead(try Self.piEditor())
        #expect(store.sendStatuses[id] == .discarded)

        let again = UUID()
        store.updateSends([Self.sent(id, text), Self.sent(again, text, delivered: false)])
        store.updateSends([Self.sent(id, text), Self.sent(again, text)])
        await files.append(
            Self.ompMessage("u2", parent: "u1", role: "user", "Queued steer: say MANGO."), to: Self.piPath(.pi))
        await store.step()

        #expect(store.sendStatuses[again] == .recorded)
        #expect(store.sendStatuses[id] == .abandoned)
    }

    @Test func anOverdueSendTheEditorDoesNotHoldStaysOverdue() async throws {
        let (_, store, pane, clock, id) = try await Self.stoppedSteer(.pi, text: "say KIWI ")

        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        await store.step()

        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .overdue)
    }

    // MARK: Refused compactions

    /// A Pi or Oh My Pi store holding one recorded prompt, with `/compact`
    /// sent from Chat while the Agent stays idle.
    private static func sentCompact(
        _ program: ChatProgram, screen: ANSIScreen
    ) async throws -> (files: VirtualHostFiles, store: AgentChatStore, pane: Pane, clock: Clock, id: UUID) {
        let clock = Clock()
        let pane = Pane(screen)
        let (files, store, path, _) = try Self.skillStore(program, clock: clock, screen: pane.io)
        await files.write(Self.piHeader + "\n" + Self.ompMessage("u1", parent: nil, role: "user", "go"), at: path)
        await store.step()
        let id = UUID()
        store.updateSends([Self.sent(id, "/compact", delivered: false)])
        store.updateSends([Self.sent(id, "/compact")])
        await store.step()
        return (files, store, pane, clock, id)
    }

    /// Pi 0.85.1 (pi-41) and Oh My Pi 18.11.1 print the same refusal for
    /// a `/compact` with nothing to compact, record nothing and stay idle.
    /// One read once the echo is overdue says so instead; a prompt
    /// recorded later retires it rather than leave it under that turn.
    @Test(arguments: [ChatProgram.pi, .omp])
    func aCompactWithNothingToCompactIsRefusedAfterOneRead(program: ChatProgram) async throws {
        let (files, store, pane, clock, id) = try await Self.sentCompact(
            program, screen: try ScreenFixture.screen("pi-41-compact-nothing"))
        #expect(await pane.reads == 0)

        clock.now = clock.now.addingTimeInterval(10)
        await store.step()
        await store.step()

        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .refused("\(program.chatName) had nothing to compact."))

        await files.append(Self.ompMessage("u2", parent: "u1", role: "user", "say PLUM"), to: Self.piPath(program))
        await store.step()

        #expect(store.sendStatuses[id] == .abandoned)
    }

    /// The screen is read once for each overdue `/compact`: one that
    /// showed no refusal stays overdue, whatever the screen shows later.
    @Test func anOverdueCompactIsLookedForOnce() async throws {
        let (_, store, pane, clock, id) = try await Self.sentCompact(.pi, screen: try Self.piEditor())

        clock.now = clock.now.addingTimeInterval(10)
        await store.step()
        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .overdue)

        await pane.show(try ScreenFixture.screen("pi-41-compact-nothing"))
        clock.now = clock.now.addingTimeInterval(10)
        await store.step()

        #expect(await pane.reads == 1)
        #expect(store.sendStatuses[id] == .overdue)
    }

    /// Any other compaction failure is refused too, and a compaction the
    /// transcript records after all still settles the send.
    @Test func anotherCompactionFailureIsRefusedUntilACompactionIsRecorded() async throws {
        let capture = try ScreenFixture.text("pi-41-compact-nothing")
        let screen = ANSIScreenDecoder.decode(
            capture.replacingOccurrences(
                of: "Nothing to compact (session too small)", with: "Summarization request failed"))
        let (files, store, _, clock, id) = try await Self.sentCompact(.pi, screen: screen)

        clock.now = clock.now.addingTimeInterval(10)
        await store.step()
        #expect(store.sendStatuses[id] == .refused("Pi couldn't compact."))

        await files.append(
            #"{"type":"compaction","id":"c1","parentId":"u1","summary":"summary","firstKeptEntryId":"u1"}"# + "\n",
            to: Self.piPath(.pi))
        await store.step()

        #expect(store.sendStatuses[id] == .recorded)
    }

    /// Only Pi and Oh My Pi are known to refuse on screen: Claude's
    /// overdue `/compact` stays overdue without a read.
    @Test func aClaudeCompactIsNotLookedForOnTheScreen() async throws {
        let pane = Pane(try ScreenFixture.screen("pi-41-compact-nothing"))
        let fixture = Fixture(session: Self.first, screen: pane.io)
        await fixture.files.write(NumberedChatReducer.lines(0..<2), at: Self.path(Self.first))
        await fixture.store.step()
        let id = UUID()
        fixture.store.updateSends([Self.sent(id, "/compact", delivered: false)])
        fixture.store.updateSends([Self.sent(id, "/compact")])

        fixture.advance(10)
        await fixture.store.step()
        await fixture.store.step()

        #expect(await pane.reads == 0)
        #expect(fixture.store.sendStatuses[id] == .overdue)
    }

    // MARK: Oh My Pi rewrites

    private static func ompMessage(_ id: String, parent: String?, role: String, _ text: String) -> String {
        let parent = parent.map { #""\#($0)""# } ?? "null"
        let content =
            role == "user" ? #""\#(text)""# : #"[{"type":"text","text":"\#(text)"}],"stopReason":"stop""#
        return #"{"type":"message","id":"\#(id)","parentId":\#(parent),"message":{"role":"\#(role)","content":\#(content)}}"#
            + "\n"
    }

    /// The device saved the conversation read further than the file now
    /// reaches: Oh My Pi rewrote it smaller since. The send's floor from the
    /// saved document no longer locates its prompt; the entries it showed
    /// still rule themselves out.
    @Test func restoredFloorSurvivesRewrite() async throws {
        let cache = VolatileChatTranscriptCache()
        let (files, store, path, _) = try Self.skillStore(.omp, cache: cache)
        await cache.save(
            ChatCacheDocument(
                key: ChatCacheKey(
                    hostID: Self.host, socketLocation: .defaultSession,
                    reference: ConversationReference(program: .omp, sessionID: path)),
                adapterRevision: PiTranscriptReducer.revision, transcriptPath: path,
                head: Data((Self.piHeader + "\n").utf8), coverageStart: 0, coverageEnd: 1 << 20,
                reachedStart: true, title: nil,
                entries: [
                    ChatEntry(
                        id: ChatEntryID("pi:u1"), sourceOffset: 100, content: .user(ChatUserMessage(text: "again")))
                ], savedAt: Self.start))
        await store.step()
        #expect(store.conversation.isFromCache)
        #expect(store.conversation.readOffset == 1 << 20)
        let id = UUID()
        store.updateSends([Self.sent(id, "again ", delivered: false)])
        store.updateSends([Self.sent(id, "again ")])

        let titled = Self.piHeader.replacingOccurrences(of: "}", with: #","title":"Again","titleSource":"auto"}"#)
        await files.write(
            titled + "\n" + Self.ompMessage("u1", parent: nil, role: "user", "again")
                + Self.ompMessage("a1", parent: "u1", role: "assistant", "done"), at: path)
        await store.step()

        #expect(store.conversation.phase == .following(path: path))
        #expect(store.sendStatuses[id] == .awaiting)

        await files.append(Self.ompMessage("u2", parent: "a1", role: "user", "again"), to: path)
        await store.step()

        #expect(store.sendStatuses[id] == .recorded)
    }

    /// One recorded copy answers one send even after Oh My Pi rewrites the
    /// file and every prompt moves.
    @Test func claimSurvivesRewrite() async throws {
        let (files, store, path, _) = try Self.skillStore(.omp)
        let long = Self.ompMessage("f0", parent: nil, role: "assistant", String(repeating: "x", count: 2_000))
        await files.write(Self.piHeader + "\n" + long, at: path)
        await store.step()
        let first = UUID()
        let second = UUID()
        store.updateSends([Self.sent(first, "go ", delivered: false), Self.sent(second, "go ", delivered: false)])
        store.updateSends([Self.sent(first, "go "), Self.sent(second, "go ")])

        let prompt = Self.ompMessage("u1", parent: "f0", role: "user", "go")
        await files.append(prompt, to: path)
        await store.step()

        #expect(store.sendStatuses[first] == .recorded)
        #expect(store.sendStatuses[second] == .awaiting)

        // The rewrite prunes the long reply: the prompt moves up the file.
        let generation = store.conversation.layoutGeneration
        await files.write(
            Self.piHeader + "\n" + Self.ompMessage("f0", parent: nil, role: "assistant", "x") + prompt, at: path)
        await store.step()

        #expect(store.conversation.layoutGeneration == generation + 1)
        #expect(store.sendStatuses[second] == .awaiting)

        await files.append(Self.ompMessage("u2", parent: "u1", role: "user", "go"), to: path)
        await store.step()

        #expect(store.sendStatuses[second] == .recorded)
    }

    // MARK: A new Pi or Oh My Pi conversation

    /// Pi and Oh My Pi write a new conversation's file with the first reply;
    /// until then the Agent is in a conversation with nothing to show.
    @Test(arguments: [ChatProgram.pi, .omp])
    func sendWhileAwaitingFirstMessageIsNotOverdue(program: ChatProgram) async throws {
        let clock = Clock()
        let (files, store, path, _) = try Self.skillStore(program, clock: clock)
        await store.step()
        #expect(store.conversation.phase == .unavailable(.awaitingFirstMessage(program)))
        let id = UUID()
        store.updateSends([Self.sent(id, "hello ", delivered: false)])
        store.updateSends([Self.sent(id, "hello ")])

        clock.now = clock.now.addingTimeInterval(60)
        await store.step()

        #expect(store.sendStatuses[id] == .awaiting)

        await files.write(
            Self.piHeader + "\n"
                + #"{"type":"message","id":"u1","parentId":null,"message":{"role":"user","content":"hello"}}"#
                + "\n", at: path)
        await store.step()

        #expect(store.conversation.phase == .following(path: path))
        #expect(store.sendStatuses[id] == .recorded)
    }

    /// A steer Stop put back, kept or cleared, belongs to the conversation
    /// it was sent into; a new one that is still unwritten does not wait
    /// for it, only for what is sent into it.
    @Test(arguments: [false, true])
    func anEarlierConversationsReturnedSteerDoesNotWaitInTheNext(cleared: Bool) async throws {
        let server = Server(Self.piAgent(.pi))
        let (_, store, pane, clock, old) = try await Self.stoppedSteer(
            .pi, text: "Queued steer: say MANGO. ", server: server)
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        #expect(store.sendStatuses[old] == .returned)
        if cleared {
            await pane.show(try Self.piEditor())
            await Self.nextIdleSpell(store, .pi, clock: clock)
            #expect(store.sendStatuses[old] == .discarded)
        }

        // `/new` in the pane: herdr reports a session whose file Pi writes
        // with the first reply.
        let next = Agent(
            terminalID: "term-1", kind: "pi", title: "", status: .idle, workspaceID: "w1",
            tabID: "t1", paneID: "w1:p1", cwd: Self.cwd, revision: 2,
            agentSession: AgentSessionInfo(
                agent: "pi", kind: .path, source: "herdr:pi",
                value: "/home/dev/.pi/agent/sessions/--home-dev-proj--/2026-10-15_01a14046-b00d-75aa-98ce-000000000002.jsonl"))
        await server.set(next)
        store.agentDidChange(next)
        await store.step()
        #expect(store.conversation.phase == .unavailable(.awaitingFirstMessage(.pi)))
        let sent = UUID()
        store.updateSends([Self.sent(old, "Queued steer: say MANGO. "), Self.sent(sent, "hello ", delivered: false)])
        store.updateSends([Self.sent(old, "Queued steer: say MANGO. "), Self.sent(sent, "hello ")])
        clock.now = clock.now.addingTimeInterval(60)
        await store.step()

        #expect(store.sendStatuses[old] == .abandoned)
        #expect(store.sendStatuses[sent] == .awaiting)
    }

    @Test func fileAppearingAfterFirstTurnIsFollowed() async throws {
        let clock = Clock()
        let (files, store, path, _) = try Self.skillStore(.pi, clock: clock)
        await store.step()
        await store.step()
        await store.step()

        // Looked for on every pass, without backing off.
        #expect(await files.statuses.filter { $0 == path }.count == 3)
        #expect(store.conversation.phase == .unavailable(.awaitingFirstMessage(.pi)))

        await files.write(Self.piHeader + "\n", at: path)
        await store.step()

        #expect(store.conversation.phase == .following(path: path))
    }

    // MARK: Tool output

    @Test func anExpandedToolRowReadsItsOutputOnce() async throws {
        let fixture = Fixture(session: Self.first)
        let id = ChatEntryID("t-5")
        await fixture.files.write(
            NumberedChatReducer.lines(0..<2) + NumberedChatReducer.tool(5, output: "built\nok"),
            at: Self.path(Self.first))
        await fixture.store.step()
        await fixture.files.clearRecords()

        fixture.store.loadOutput(id)
        #expect(fixture.store.outputs.loads[id]?.state == .loading)
        fixture.store.loadOutput(id)
        await fixture.store.outputReadsSettled()

        #expect(fixture.store.outputs.loads[id]?.state == .read(ChatExpandedOutput(preview: ChatToolPreview(text: "built\nok", isTruncated: false))))
        fixture.store.loadOutput(id)
        await fixture.store.outputReadsSettled()
        #expect(await fixture.files.reads.count == 1)
    }

    @Test func aRowExpandedWhileTheHostIsOfflineIsReadOnceItConnects() async throws {
        let fixture = Fixture(session: Self.first)
        let id = ChatEntryID("t-5")
        await fixture.files.write(
            NumberedChatReducer.lines(0..<2) + NumberedChatReducer.tool(5, output: "built"), at: Self.path(Self.first))
        await fixture.store.step()
        await fixture.files.clearRecords()

        // The saved conversation still follows, but the Host is gone.
        fixture.store.hostConnectionChanged(false)
        fixture.store.loadOutput(id)
        await fixture.store.outputReadsSettled()
        #expect(fixture.store.outputs.loads[id] == nil)
        #expect(await fixture.files.reads.isEmpty)

        fixture.store.hostConnectionChanged(true)
        await fixture.store.outputReadsSettled()
        #expect(
            fixture.store.outputs.loads[id]?.state
                == .read(ChatExpandedOutput(preview: ChatToolPreview(text: "built", isTruncated: false))))
    }

    @Test func aRowExpandedWhileTheTranscriptIsMissingIsReadOnceItIsBack() async throws {
        let fixture = Fixture(session: Self.first)
        let id = ChatEntryID("t-5")
        let path = Self.path(Self.first)
        let contents = NumberedChatReducer.lines(0..<2) + NumberedChatReducer.tool(5, output: "built")
        await fixture.files.write(contents, at: path)
        await fixture.store.step()
        // Gone for now: Chat keeps showing what it read.
        await fixture.files.remove(path)
        await fixture.store.step()
        guard case .unavailable = fixture.store.conversation.phase else {
            Issue.record("Expected the transcript to be unavailable, got \(fixture.store.conversation.phase)")
            return
        }
        #expect(Self.ids(fixture.store).contains("t-5"))

        fixture.store.loadOutput(id)
        #expect(fixture.store.outputs.isEmpty)

        await fixture.files.write(contents, at: path)
        fixture.store.retry()
        await fixture.store.step()
        await fixture.store.outputReadsSettled()
        #expect(fixture.store.outputs.loads[id]?.state == .read(ChatExpandedOutput(preview: ChatToolPreview(text: "built", isTruncated: false))))
    }

    @Test func aReadForAnEarlierConversationIsDropped() async throws {
        let fixture = Fixture(session: Self.first)
        await fixture.files.write(NumberedChatReducer.tool(5, output: "first"), at: Self.path(Self.first))
        await fixture.files.write(NumberedChatReducer.tool(5, output: "second"), at: Self.path(Self.second))
        await fixture.store.step()

        fixture.store.loadOutput(ChatEntryID("t-5"))
        fixture.store.agentDidChange(Self.agent(session: Self.second))
        await fixture.store.outputReadsSettled()

        #expect(fixture.store.outputs.isEmpty)
    }

    private static func savedIDs(_ cache: VolatileChatTranscriptCache, _ key: ChatCacheKey) async -> [String] {
        guard case .hit(let document) = await cache.load(key) else { return [] }
        return document.entries.map(\.id.rawValue)
    }

    private static func waitUntil(
        _ condition: @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting")
    }
}
