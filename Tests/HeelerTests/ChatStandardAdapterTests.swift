import Foundation
import Testing

@testable import Heeler

/// The adapters the app reads transcripts with, run through the engine
/// against captured files and an OpenCode store.
@Suite("Chat standard adapters")
struct ChatStandardAdapterTests {
    @Test func claudeFollowsACapturedSessionAsTheReducerProjectsIt() async throws {
        let sessionID = "faf3ddf8-b1aa-44b1-8285-b062ad473e0d"
        let cwd = "/private/tmp/heeler-tmp-chat/probe-claude"
        let fixture = "claude/probe1-transcript.jsonl"
        let adapter = try #require(ChatTranscriptAdapter.standard(for: .claude))
        let files = VirtualHostFiles(home: "/Users/developer")
        let path = "/Users/developer/.claude/projects/"
            + "\(ClaudeProjectKey.key(forDirectory: cwd))/\(sessionID).jsonl"
        await files.write(try ChatFixture.data(fixture), at: path)
        let engine = ChatConversationEngine(
            reference: ConversationReference(program: .claude, sessionID: sessionID),
            cacheKey: ChatCacheKey(
                hostID: UUID(), herdrSession: "", program: .claude, conversationID: sessionID),
            files: files.hostFiles(), cache: VolatileChatTranscriptCache(), adapter: adapter,
            now: { Date() })

        let snapshot = await engine.open(
            directories: [cwd], context: ChatProjectionContext(activity: .idle))

        var reducer = ClaudeTranscriptReducer(role: .main)
        reducer.append(try ChatFixture.lines(fixture))
        let expected = reducer.transcript(ChatProjectionContext(activity: .idle))
        #expect(snapshot.phase == .following(path: path))
        #expect(snapshot.older == .reachedStart)
        #expect(!expected.entries.isEmpty)
        #expect(snapshot.transcript.entries == expected.entries)
    }

    @Test func codexFollowsACapturedRolloutAsTheReducerProjectsIt() async throws {
        let threadID = CodexProbe.probe2ID
        let fixture = "codex/probe2-rollout.jsonl"
        let adapter = try #require(ChatTranscriptAdapter.standard(for: .codex))
        let files = VirtualHostFiles(home: "/Users/developer")
        let path = Self.codexPath(threadID: threadID)
        await files.write(try ChatFixture.data(fixture), at: path)
        let engine = Self.codexEngine(threadID: threadID, files: files, adapter: adapter)

        let snapshot = await engine.open(directories: [], context: ChatProjectionContext(activity: .idle))

        var reducer = CodexRolloutReducer(rolloutID: threadID)
        reducer.append(try ChatFixture.lines(fixture))
        let expected = reducer.transcript(ChatProjectionContext(activity: .idle))
        #expect(snapshot.phase == .following(path: path))
        #expect(snapshot.older == .reachedStart)
        #expect(!expected.entries.isEmpty)
        #expect(snapshot.transcript.entries == expected.entries)
    }

    @Test func codexExplainsARolloutInAHistoryModeItCannotRead() async throws {
        let threadID = CodexProbe.probe2ID
        let adapter = try #require(ChatTranscriptAdapter.standard(for: .codex))
        let files = VirtualHostFiles(home: "/Users/developer")
        let meta = #"{"timestamp":"2026-10-06T00:00:00.000Z","type":"session_meta","payload":{"id":""#
            + threadID + #"","cwd":"/w","history_mode":"tiered"}}"#
        await files.write(Data((meta + "\n").utf8), at: Self.codexPath(threadID: threadID))
        let engine = Self.codexEngine(threadID: threadID, files: files, adapter: adapter)

        let snapshot = await engine.open(directories: [], context: ChatProjectionContext(activity: .idle))

        guard case .unavailable(.unsupportedFormat(let format)) = snapshot.phase else {
            Issue.record("expected an unsupported format, got \(snapshot.phase)")
            return
        }
        #expect(format.contains("history mode"))
    }

    /// OpenCode writes no file: Chat follows the session by querying its
    /// database, and shows the rows the query prints as the reducer
    /// projects them (ADR 0025).
    @Test func openCodeFollowsACapturedStore() async throws {
        let scenario = "patch"
        let store = try OpenCodeStore(scenario: scenario)
        let sessionID = try #require(try OpenCodeStoreFixture.named(scenario).sessionID).rawValue
        let adapter = try #require(ChatTranscriptAdapter.standard(for: .opencode))
        let engine = ChatConversationEngine(
            reference: ConversationReference(program: .opencode, sessionID: sessionID),
            cacheKey: ChatCacheKey(
                hostID: UUID(), herdrSession: "", program: .opencode, conversationID: sessionID),
            files: store.files, cache: VolatileChatTranscriptCache(), adapter: adapter, now: { Date() })

        let snapshot = await engine.open(directories: [], context: ChatProjectionContext(activity: .idle))

        // The probe's lines, each row at its `seq` as the record source
        // hands them on.
        var reducer = OpenCodeTranscriptReducer()
        reducer.append(
            try ChatFixture.lines("opencode/rows-\(scenario).jsonl").map { line in
                guard case .row(let row) = OpenCodeLine(line.data) else { return line }
                return ChatLine(offset: UInt64(row.seq), data: line.data)
            })
        let expected = reducer.transcript(ChatProjectionContext(activity: .idle))
        #expect(snapshot.phase == .following(path: "opencode:\(sessionID)"))
        #expect(snapshot.older == .reachedStart)
        #expect(!expected.entries.isEmpty)
        #expect(snapshot.transcript.entries == expected.entries)
        #expect(snapshot.transcript.turns == expected.turns)
        // One query read the whole session.
        #expect(await store.queries.count == 1)
    }

    @Test func eachProgramComparesEchoesTheWayItRecordsPrompts() throws {
        let claude = try #require(ChatTranscriptAdapter.standard(for: .claude))
        let codex = try #require(ChatTranscriptAdapter.standard(for: .codex))
        #expect(claude.echoKey("Fix it\r\nplease ") == "Fix it\nplease")
        #expect(codex.echoKey("Fix \u{1B}[31mit\u{1B}[0m\r\nplease ") == "Fix it\nplease")
    }

    /// A scratch OpenCode store built from a captured one, queried the way a
    /// Host's is. Only queries reach it: there are no files to read.
    private actor OpenCodeStore {
        private let harness: OpenCodeSQLiteHarness
        private(set) var queries: [OpenCodeQuery] = []

        init(scenario: String) throws {
            harness = try OpenCodeSQLiteHarness(scenario: scenario)
        }

        func response(_ query: OpenCodeQuery) throws -> OpenCodeQueryResponse {
            queries.append(query)
            return try harness.response(query)
        }

        nonisolated var files: ChatHostFiles {
            let none = TransportError.hostFeatureUnavailable(feature: "Files")
            return ChatHostFiles(
                status: { _ in throw none }, list: { _ in throw none }, read: { _ in throw none },
                home: { throw none }, queryOpenCode: { try await self.response($0) })
        }
    }

    private static func codexPath(threadID: String) -> String {
        "/Users/developer/.codex/sessions/2026/10/06/rollout-2026-10-06T05-55-29-\(threadID).jsonl"
    }

    private static func codexEngine(
        threadID: String, files: VirtualHostFiles, adapter: ChatTranscriptAdapter
    ) -> ChatConversationEngine {
        ChatConversationEngine(
            reference: ConversationReference(program: .codex, sessionID: threadID),
            cacheKey: ChatCacheKey(
                hostID: UUID(), herdrSession: "", program: .codex, conversationID: threadID),
            files: files.hostFiles(), cache: VolatileChatTranscriptCache(), adapter: adapter,
            now: { Date() })
    }
}
