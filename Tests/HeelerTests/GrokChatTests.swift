import Foundation
import Testing

@testable import Heeler

/// Grok Build's Chat end to end: the engine, and the store above it, with
/// `ChatTranscriptAdapter.grok` over a Host's files.
@Suite("Grok Build Chat", .timeLimit(.minutes(1)))
struct GrokChatTests {
    private static let cwd = "/home/dev/proj"
    private static let host = UUID()
    /// The sessions in `grok/core-turns.jsonl`, `grok/rewind.jsonl` and
    /// `grok/dispatch-order.jsonl`.
    private static let coreTurns = "01900000-0000-7000-8000-000000000004"
    private static let rewind = "01900000-0000-7000-8000-000000000014"
    private static let dispatched = "01900000-0000-7000-8000-000000000018"

    private static func path(_ session: String) -> String {
        "/home/dev/.grok/sessions/%2Fhome%2Fdev%2Fproj/\(session)/updates.jsonl"
    }

    /// Lines `range` of a `grok/` fixture (1-based, inclusive), as written.
    private static func text(_ fixture: String, lines range: ClosedRange<Int>) throws -> String {
        let rows = try ChatFixture.text("grok/\(fixture)").split(separator: "\n", omittingEmptySubsequences: false)
        return rows[(range.lowerBound - 1)..<range.upperBound].joined(separator: "\n") + "\n"
    }

    private static func engine(_ session: String, files: VirtualHostFiles) -> ChatConversationEngine {
        ChatConversationEngine(
            reference: ConversationReference(program: .grok, sessionID: session),
            cacheKey: ChatCacheKey(hostID: host, herdrSession: "", program: .grok, conversationID: session),
            files: files.hostFiles(), cache: VolatileChatTranscriptCache(), adapter: .grok)
    }

    @Test func opensTheBoundSessionAndFollowsAppendedLines() async throws {
        let files = VirtualHostFiles()
        let path = Self.path(Self.coreTurns)
        await files.write(try Self.text("core-turns.jsonl", lines: 1...4), at: path)
        let engine = Self.engine(Self.coreTurns, files: files)

        let opened = await engine.open(directories: [Self.cwd], context: ChatProjectionContext(activity: .idle))

        #expect(opened.phase == .following(path: path))
        #expect(opened.transcript.entries.map(\.id.rawValue) == ["grok:391", "grok:773"])
        #expect(opened.transcript.turns.map(\.ending) == [.completed])

        await files.append(try Self.text("core-turns.jsonl", lines: 5...7), to: path)
        let polled = await engine.poll(context: ChatProjectionContext(activity: .idle))

        #expect(polled.transcript.entries.map(\.id.rawValue) == ["grok:391", "grok:773", "grok:2059", "grok:2478"])
        #expect(polled.transcript.turns.map(\.ending) == [.completed, .completed])
        #expect(polled.transcript.latestPromptOffset == 2059)
        #expect(!polled.transcript.needsOlderHistory)
    }

    // MARK: Rebinding

    /// What `agent.get` answers.
    private actor AgentRecord {
        var agent: Agent

        init(_ agent: Agent) {
            self.agent = agent
        }

        func set(_ agent: Agent) {
            self.agent = agent
        }
    }

    private static func agent(session: String) -> Agent {
        Agent(
            terminalID: "term-1", kind: "grok", title: "", status: .idle, workspaceID: "w1", tabID: "t1",
            paneID: "w1:p1", cwd: cwd, revision: 1,
            agentSession: AgentSessionInfo(agent: "grok", kind: .id, source: "herdr:grok", value: session))
    }

    @MainActor
    @Test func aNewSessionReportRebindsChat() async throws {
        let files = VirtualHostFiles()
        await files.write(try ChatFixture.text("grok/core-turns.jsonl"), at: Self.path(Self.coreTurns))
        await files.write(try ChatFixture.text("grok/rewind.jsonl"), at: Self.path(Self.rewind))
        let record = AgentRecord(Self.agent(session: Self.coreTurns))
        let store = AgentChatStore(
            agentID: ConsoleAgent.ID(hostID: Self.host, paneID: "w1:p1"),
            agent: Self.agent(session: Self.coreTurns), program: .grok,
            source: AgentChatSource(
                hostID: Self.host, socketLocation: .defaultSession, files: files.hostFiles(),
                agentInfo: { await record.agent }, cache: VolatileChatTranscriptCache(), adapter: .grok),
            timing: AgentChatStore.Timing(activeInterval: .milliseconds(5), idleInterval: .milliseconds(5)))
        await store.step()
        #expect(store.conversation.phase == .following(path: Self.path(Self.coreTurns)))

        // `/new` or `/resume` in Grok moves the Agent to another session,
        // which herdr reports with the Agent.
        await record.set(Self.agent(session: Self.rewind))
        store.agentDidChange(Self.agent(session: Self.rewind))
        await store.step()

        #expect(store.conversation.phase == .following(path: Self.path(Self.rewind)))
        #expect(
            store.conversation.transcript.entries.map(\.id.rawValue) == [
                "grok:391", "grok:765", "grok:4054", "grok:4456",
            ])
    }

    @Test func waitsForUpdatesThatAreNotWrittenYet() async throws {
        let files = VirtualHostFiles()
        let path = Self.path(Self.dispatched)
        // A session dispatched from Grok's dashboard has its folder before
        // its first record.
        await files.makeDirectory((path as NSString).deletingLastPathComponent)
        let engine = Self.engine(Self.dispatched, files: files)

        let early = await engine.open(directories: [Self.cwd], context: ChatProjectionContext(activity: .working))
        #expect(early.phase == .unavailable(.notFound(searchedAll: false)))

        // Its prompt comes before herdr's `session_start` hook record.
        await files.write(try ChatFixture.text("grok/dispatch-order.jsonl"), at: path)
        let found = await engine.open(directories: [Self.cwd], context: ChatProjectionContext(activity: .idle))

        #expect(found.phase == .following(path: path))
        #expect(
            found.transcript.entries.map(\.content) == [
                .user(ChatUserMessage(text: "Reply with the word pear.")),
                .assistant(ChatAssistantMessage(text: "pear")),
            ])
        #expect(found.transcript.turns.map(\.ending) == [.completed])
    }
}
