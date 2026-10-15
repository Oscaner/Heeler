import Foundation
import Testing

@testable import Heeler

@Suite("Pi Chat", .timeLimit(.minutes(1)))
struct PiChatTests {
    private static let id = "f3c2a481-54ed-4c7e-a240-6d036157dc80"
    private static let path = "/home/test/.pi/agent/sessions/--project--/2026-10-15_\(id).jsonl"
    private static let header =
        #"{"type":"session","version":3,"id":"f3c2a481-54ed-4c7e-a240-6d036157dc80","cwd":"/project"}"#

    private static func lines(_ rows: [String]) -> [ChatLine] {
        JSONLLineFramer.lines(in: Data((rows.joined(separator: "\n") + "\n").utf8))
    }

    @Test(arguments: [ChatProgram.pi, .omp])
    func resolvesOfficialPathsAndUUIDs(program: ChatProgram) {
        for value in [Self.path, Self.id] {
            let kind: AgentSessionRefKind = value == Self.path ? .path : .id
            #expect(
                ConversationReference.resolve(
                    AgentSessionInfo(
                        agent: program.rawValue, kind: kind,
                        source: "herdr:\(program.rawValue)", value: value))
                    == .bound(ConversationReference(program: program, sessionID: value)))
        }
    }

    @Test(arguments: ["../x.jsonl", "/tmp/../other.jsonl", "/tmp/./x.jsonl", "/tmp/x\n.jsonl", "/tmp/x.txt"])
    func refusesUnsafeSessionPaths(path: String) {
        #expect(
            ConversationReference.resolve(AgentSessionInfo(agent: "pi", kind: .path, source: "herdr:pi", value: path))
                == .unidentified)
    }

    @Test func followsCurrentBranchThroughInvisibleEntries() {
        var reducer = PiTranscriptReducer()
        reducer.append(
            Self.lines([
                Self.header,
                #"{"type":"message","id":"u1","parentId":null,"message":{"role":"user","content":"original"}}"#,
                #"{"type":"message","id":"a1","parentId":"u1","message":{"role":"assistant","content":[{"type":"text","text":"abandoned answer"}],"stopReason":"stop"}}"#,
                #"{"type":"custom","id":"branch","parentId":"u1","customType":"switch"}"#,
                #"{"type":"message","id":"a2","parentId":"branch","message":{"role":"assistant","content":[{"type":"text","text":"current answer"}],"stopReason":"stop"}}"#,
            ]))
        let transcript = reducer.transcript(.init())
        #expect(transcript.entries.count == 2)
        #expect(transcript.entries.last?.content == .assistant(ChatAssistantMessage(text: "current answer")))
        #expect(!transcript.needsOlderHistory)
    }

    @Test func lateOMPUsageDoesNotRestoreAnAbandonedBranch() {
        var reducer = PiTranscriptReducer()
        reducer.append(
            Self.lines([
                Self.header,
                #"{"type":"message","id":"a","parentId":null,"message":{"role":"user","content":"old"}}"#,
                #"{"type":"message","id":"b","parentId":null,"message":{"role":"user","content":"new"}}"#,
                #"{"type":"model_usage","id":"usage","parentId":"a","activeLeafId":"b"}"#,
            ]))
        #expect(reducer.transcript(.init()).entries.map(\.content) == [.user(ChatUserMessage(text: "new"))])
    }

    @Test func prependAndRepeatedReadsConvergeWithoutDuplicateRows() {
        let lines = Self.lines([
            Self.header,
            #"{"type":"message","id":"u","parentId":null,"message":{"role":"user","content":"你好"}}"#,
            #"{"type":"message","id":"a","parentId":"u","message":{"role":"assistant","content":[{"type":"text","text":"回复"}],"stopReason":"stop"}}"#,
        ])
        var whole = PiTranscriptReducer()
        whole.append(lines)
        var paged = PiTranscriptReducer()
        paged.append(Array(lines.suffix(1)))
        #expect(paged.transcript(.init(windowStart: lines[2].offset)).needsOlderHistory)
        paged.prepend(Array(lines.prefix(2)))
        paged.append(lines)
        #expect(paged.transcript(.init()) == whole.transcript(.init()))
    }

    @Test func pairsToolsByIDAndReadsFullOutputOnDemand() throws {
        let lines = Self.lines([
            Self.header,
            #"{"type":"message","id":"u","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"inspect"},{"type":"image","data":"synthetic"}]}}"#,
            #"{"type":"message","id":"a","parentId":"u","message":{"role":"assistant","content":[{"type":"thinking","thinking":"read first"},{"type":"toolCall","id":"c","name":"read","arguments":{"path":"file.swift"}}],"stopReason":"toolUse"}}"#,
            #"{"type":"message","id":"r","parentId":"a","message":{"role":"toolResult","toolCallId":"c","toolName":"read","content":[{"type":"text","text":"file contents"}],"isError":true}}"#,
        ])
        var reducer = PiTranscriptReducer()
        reducer.append(lines)
        let transcript = reducer.transcript(.init(activity: .working))
        guard case .tool(let tool) = transcript.entries.last?.content else {
            Issue.record("Tool missing")
            return
        }
        #expect(tool.status == .failed)
        #expect(tool.kind == .fileRead)
        #expect(tool.title == "file.swift")
        #expect(tool.preview?.text == "file contents")
        #expect(tool.output?.offset == lines[3].offset)
        #expect(reducer.output(of: lines[3], for: tool) == .preview(ChatToolPreview(capping: "file contents")))
        #expect(transcript.entries.first?.content == .user(ChatUserMessage(text: "inspect", imageCount: 1)))
        #expect(transcript.entries[1].content == .reasoning(ChatReasoning(text: "read first")))
        #expect(transcript.pendingRequests.isEmpty)
    }

    @Test func compactionKeepsHistoryAndFinishedTurns() {
        var reducer = PiTranscriptReducer()
        reducer.append(
            Self.lines([
                Self.header,
                #"{"type":"message","id":"u","parentId":null,"timestamp":"2026-10-15T00:00:00.000Z","message":{"role":"user","content":"hello"}}"#,
                #"{"type":"message","id":"a","parentId":"u","timestamp":"2026-10-15T00:00:03.000Z","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stopReason":"stop"}}"#,
                #"{"type":"compaction","id":"c","parentId":"a","summary":"summary","firstKeptEntryId":"u"}"#,
            ]))
        let transcript = reducer.transcript(.init())
        #expect(transcript.entries.count == 3)
        #expect(transcript.entries.last?.content == .divider(ChatDivider(kind: .compaction, detail: "summary")))
        #expect(transcript.turns.first?.ending == .completed)
        #expect(
            transcript.turns.first?.endedAt?.timeIntervalSince(transcript.turns.first?.startedAt ?? .distantPast) == 3)
    }

    @Test func unknownRecordsRemainTreeLinksAndMalformedLinesAreCounted() {
        var reducer = PiTranscriptReducer()
        reducer.append(
            Self.lines([
                Self.header,
                "{not json}",
                #"{"type":"message","id":"u","parentId":null,"message":{"role":"user","content":"visible"}}"#,
                #"{"type":"future_state","id":"f","parentId":"u"}"#,
            ]))
        let transcript = reducer.transcript(.init())
        #expect(transcript.entries.count == 1)
        #expect(transcript.diagnostics.invalidLines == 1)
        #expect(transcript.diagnostics.unknownRecordTypes == ["future_state"])
    }

    @Test func oversizedImageRecordKeepsBranchAncestry() {
        let header = Self.lines([Self.header])[0]
        let prefix =
            #"{"type":"message","id":"image","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"look"},{"type":"image","data":""#
        let line = ChatLine(offset: header.end, length: 2 << 20, data: Data(prefix.utf8))
        let answer = ChatLine(
            offset: line.end,
            data: Data(
                #"{"type":"message","id":"answer","parentId":"image","message":{"role":"assistant","content":[{"type":"text","text":"visible answer"}],"stopReason":"stop"}}"#
                    .utf8))
        var reducer = PiTranscriptReducer()
        reducer.append([header, line, answer])
        let transcript = reducer.transcript(.init())
        #expect(transcript.entries.count == 2)
        #expect(transcript.diagnostics.oversizedLines == 1)
        #expect(!transcript.needsOlderHistory)
        #expect(transcript.recordedPrompts.isEmpty)
    }

    @Test func priorTailTurnEndDoesNotInterruptTheCurrentTool() {
        var reducer = PiTranscriptReducer()
        reducer.append(
            Self.lines([
                Self.header,
                #"{"type":"message","id":"end","parentId":null,"message":{"role":"assistant","content":[],"stopReason":"stop"}}"#,
                #"{"type":"message","id":"u","parentId":"end","message":{"role":"user","content":"next"}}"#,
                #"{"type":"message","id":"a","parentId":"u","message":{"role":"assistant","content":[{"type":"toolCall","id":"c","name":"bash","arguments":{"command":"pwd"}}],"stopReason":"toolUse"}}"#,
            ]))
        guard case .tool(let tool) = reducer.transcript(.init(activity: .working)).entries.last?.content else {
            Issue.record("Tool missing")
            return
        }
        #expect(tool.status == .running)
    }

    @Test func doesNotJoinCachedPrefixesAcrossPiBranchSwitches() async throws {
        let old = #"{"type":"message","id":"old","parentId":null,"message":{"role":"user","content":"abandoned"}}"#
        let padding =
            #"{"type":"custom","id":"pad","parentId":"old","data":""# + String(repeating: "x", count: 1000) + #""}"#
        let newest = [
            #"{"type":"message","id":"new","parentId":null,"message":{"role":"user","content":"current"}}"#,
            #"{"type":"message","id":"answer","parentId":"new","message":{"role":"assistant","content":[{"type":"text","text":"new answer"}],"stopReason":"stop"}}"#,
        ]
        let data = Data(([Self.header, old, padding] + newest).joined(separator: "\n").appending("\n").utf8)
        let key = ChatCacheKey(hostID: UUID(), herdrSession: "", program: .pi, conversationID: Self.path)
        let cache = VolatileChatTranscriptCache()
        await cache.save(
            ChatCacheDocument(
                key: key, adapterRevision: PiTranscriptReducer.revision,
                transcriptPath: Self.path, head: Data(data.prefix(64)), coverageStart: 0,
                coverageEnd: UInt64(data.count),
                reachedStart: true, title: nil,
                entries: [
                    ChatEntry(
                        id: ChatEntryID("pi:old"), sourceOffset: UInt64(Self.header.utf8.count + 1),
                        content: .user(ChatUserMessage(text: "abandoned")))
                ], savedAt: Date()))
        var adapter = try #require(ChatTranscriptAdapter.standard(for: .pi))
        adapter.limits.tailWindow = newest.joined(separator: "\n").utf8.count + 3
        let engine = ChatConversationEngine(
            reference: .init(program: .pi, sessionID: Self.path), cacheKey: key,
            files: Self.hostFiles([Self.path: data]), cache: cache, adapter: adapter)
        #expect(await engine.restore().isFromCache)
        let live = await engine.open(directories: [], context: .init())
        #expect(live.phase == .following(path: Self.path))
        #expect(live.transcript.entries.map(\.id) == [ChatEntryID("pi:new"), ChatEntryID("pi:answer:0")])
    }

    @Test func verifiesOMPTitleSlotAndSessionHeader() async throws {
        let data = Data((#"{"type":"title","v":1,"title":"sample"}"# + "\n" + Self.header + "\n").utf8)
        let files = Self.hostFiles([Self.path: data])
        let result = try await PiTranscriptLocator(files: files).locate(
            reference: .init(program: .omp, sessionID: Self.path), directories: [])
        #expect(result == .success(Self.path))
    }

    @Test func UUIDLookupVerifiesIdentityInsteadOfPickingNewest() async throws {
        let files = Self.hostFiles([Self.path: Data((Self.header + "\n").utf8)])
        let result = try await PiTranscriptLocator(files: files).locate(
            reference: .init(program: .pi, sessionID: Self.id), directories: ["/project"])
        #expect(result == .success(Self.path))
        let wrong = Self.header.replacingOccurrences(of: Self.id, with: "11111111-1111-4111-8111-111111111111")
        let mismatch = try await PiTranscriptLocator(files: Self.hostFiles([Self.path: Data((wrong + "\n").utf8)]))
            .locate(reference: .init(program: .pi, sessionID: Self.id), directories: ["/project"])
        #expect(mismatch == .failure(.mismatched))
    }

    @Test func newerSessionVersionsAreNotSilentlyMisread() async throws {
        let header = Self.header.replacingOccurrences(of: "\"version\":3", with: "\"version\":9")
        let result = try await PiTranscriptLocator(files: Self.hostFiles([Self.path: Data((header + "\n").utf8)]))
            .locate(reference: .init(program: .pi, sessionID: Self.path), directories: [])
        #expect(result == .failure(.unsupportedVersion(9)))
    }

    @Test func emptyPiEditorPassesButDraftAndPopupDoNot() {
        let rule = String(repeating: "─", count: 40)
        func detect(_ text: String) -> InputBoxState {
            InputBoxStateDetector.detect(ANSIScreenDecoder.decode(text), program: .pi)
        }
        #expect(detect("\(rule)\r\n \u{1B}[7m \u{1B}[0m\r\n\(rule)") == .empty(placeholder: nil))
        #expect(detect("\(rule)\r\n existing\u{1B}[7m \u{1B}[0m\r\n\(rule)") == .text("existing"))
        #expect(detect("\(rule)\r\n \u{1B}[7m \u{1B}[0m\r\n\(rule)\r\n❯ /model") == .overlay("❯ /model"))
        #expect(!detect("\(rule)\r\n\r\n\(rule)").isSendable)
    }

    @Test func emptyOMPBoxPassesButMultilineDraftDoesNot() {
        func detect(_ text: String) -> InputBoxState {
            InputBoxStateDetector.detect(ANSIScreenDecoder.decode(text), program: .omp)
        }
        #expect(
            detect("╭── Ready ──────────────────────╮\r\n╰─ ▏                          ─╯") == .empty(placeholder: nil))
        #expect(
            !detect(
                "╭──────────────────────────────╮\r\n│ first line                  │\r\n╰─ second▏                    ─╯"
            ).isSendable)
        #expect(!detect("custom editor without a known border").isSendable)
    }

    @Test(arguments: ["────────────────44%────300K─", "──44%┃300K─"])
    func ompBandWithHardwareCursorIsRecognizedBeforeSending(gauge: String) {
        // OMP 18.10.4 default band composer, read through herdr 0.9.1.
        // agent.read serializes cells, so the hardware cursor is absent.
        let band = "\u{1B}[48;2;15;18;22m π > model > 📁 project \u{1B}[0m\(gauge)"
        let screen = ANSIScreenDecoder.decode("\(band)\r\n\u{1B}[38;2;236;70;140m╰─ \u{1B}[0m          ")
        #expect(InputBoxStateDetector.detect(screen, program: .omp) == .empty(placeholder: nil))
        #expect(PreSendGate.check(screen, program: .omp, activity: .idle) == .send)
        #expect(PreSendGate.check(screen, program: .omp, activity: .blocked) == .holdBlocked)
    }

    @Test func ompBandPreservesDraftsAndRefusesMenusAndIncompleteChrome() {
        let band = "\u{1B}[48;2;15;18;22m π > 📁 project \u{1B}[0m────────────────44%────300K─"
        func detect(_ text: String) -> InputBoxState {
            InputBoxStateDetector.detect(ANSIScreenDecoder.decode(text), program: .omp)
        }
        #expect(detect("\(band)\r\n╰─ existing\r\n   second line") == .text("existing\nsecond line"))
        #expect(detect("\(band)\r\n╰─ !pwd") == .shellMode("!pwd"))
        #expect(!detect("\(band)\r\n╰─ \r\n❯ /model").isSendable)
        #expect(!detect("\(band)\r\n╰─ \r\nEsc to cancel").isSendable)
        #expect(!detect("╰─ ").isSendable)
        #expect(!detect("π > 📁 project ────────────\r\n╰─ ").isSendable)
        #expect(!detect("\(band.replacingOccurrences(of: "π >", with: "π N"))\r\n╰─ ").isSendable)
    }

    #if DEBUG && targetEnvironment(simulator)
        @Test(arguments: [ChatProgram.pi, .omp])
        func simulatorSamplesUseProductionLocatorFollowerAndReducer(program: ChatProgram) async throws {
            let path = program == .pi ? DemoPiChatSample.piPath : DemoPiChatSample.ompPath
            let reference = ConversationReference(program: program, sessionID: path)
            let adapter = try #require(ChatTranscriptAdapter.standard(for: program))
            let engine = ChatConversationEngine(
                reference: reference,
                cacheKey: ChatCacheKey(hostID: UUID(), herdrSession: "", program: program, conversationID: path),
                files: DemoChatSample.hostFiles, cache: VolatileChatTranscriptCache(), adapter: adapter)
            let snapshot = await engine.open(directories: [], context: .init(activity: .idle))
            #expect(snapshot.phase == .following(path: path))
            #expect(snapshot.older == .reachedStart)
            #expect(snapshot.transcript.diagnostics == ChatTranscriptDiagnostics())
            #expect(snapshot.transcript.entries.contains { if case .reasoning = $0.content { true } else { false } })
            #expect(
                snapshot.transcript.entries.contains {
                    if case .divider(let d) = $0.content { d.kind == .compaction } else { false }
                })
            #expect(
                snapshot.transcript.entries.contains {
                    if case .tool(let t) = $0.content { t.status == .succeeded } else { false }
                })
            #expect(snapshot.transcript.turns.count == 2)
        }
    #endif

    private static func hostFiles(_ documents: [String: Data]) -> ChatHostFiles {
        ChatHostFiles(
            status: { path in
                documents[path].map { RemoteFileStatus(kind: .regular, size: UInt64($0.count), modificationTime: 1) }
            },
            list: { request in
                let prefix = request.directory + "/"
                let names = documents.keys.filter { $0.hasPrefix(prefix) }.compactMap { path -> String? in
                    let name = String(path.dropFirst(prefix.count))
                    return !name.contains("/") && request.nameSuffixes.contains(where: name.hasSuffix) ? name : nil
                }
                return RemoteFileListing(
                    entries: names.map {
                        RemoteFileEntry(
                            name: $0, status: RemoteFileStatus(kind: .regular, size: 1, modificationTime: 1))
                    })
            },
            read: { range in
                guard let data = documents[range.path] else { return RemoteFileSlice(data: Data(), length: nil) }
                let start = Int(min(range.offset, UInt64(data.count)))
                return RemoteFileSlice(
                    data: data.subdata(in: start..<min(data.count, start + range.maxBytes)), length: UInt64(data.count))
            }, home: { "/home/test" })
    }
}
