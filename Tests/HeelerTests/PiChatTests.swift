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

    // MARK: Skills, approvals and questions

    private static let skillTurn = [
        Self.header,
        #"{"type":"message","id":"u1","parentId":null,"message":{"role":"user","content":"hello"}}"#,
        #"{"type":"message","id":"a1","parentId":"u1","message":{"role":"assistant","content":[{"type":"text","text":"hi"}],"stopReason":"stop"}}"#,
        #"{"type":"custom_message","customType":"skill-prompt","content":"[IMPORTANT: User invoked the \"probe\" skill]\n\nSKILL BODY","display":true,"details":{"name":"probe","path":"/home/test/.agents/skills/probe/SKILL.md","args":"from chat","prompt":"/skill:probe from chat","lineCount":3},"attribution":"user","id":"s1","parentId":"a1"}"#,
        #"{"type":"message","id":"a2","parentId":"s1","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_1|fc_1","name":"bash","arguments":{"i":"Probing","command":"echo probe"}}],"stopReason":"toolUse"}}"#,
    ]

    @Test func ompSkillPromptOpensTurnAndRecordsPrompt() {
        var reducer = PiTranscriptReducer()
        reducer.append(Self.lines(Self.skillTurn))
        let transcript = reducer.transcript(.init(activity: .working))
        let invocation = ChatCommandInvocation(name: "probe", arguments: "from chat")
        #expect(
            transcript.entries[2].content
                == .user(ChatUserMessage(text: "/probe from chat", command: invocation)))
        #expect(transcript.entries[2].id == ChatEntryID("pi:s1"))
        #expect(transcript.turns.map(\.firstEntryID) == [ChatEntryID("pi:u1"), ChatEntryID("pi:s1")])
        #expect(transcript.turns.first?.ending == .completed)
        #expect(transcript.turns.last?.ending == nil)
        #expect(transcript.recordedPrompts.map(\.text) == ["hello", "/skill:probe from chat"])
        #expect(transcript.latestPromptOffset == transcript.entries[2].sourceOffset)
        #expect(!transcript.entries.contains { "\($0.content)".contains("SKILL BODY") })
        guard case .tool(let tool) = transcript.entries.last?.content else {
            Issue.record("Tool missing")
            return
        }
        #expect(tool.status == .running)
    }

    @Test func ompSkillPromptMidSentenceOrWithoutPromptOrFromTheAgent() {
        func entry(_ fields: String) -> ChatEntry.Content? {
            var reducer = PiTranscriptReducer()
            reducer.append(
                Self.lines([
                    Self.header,
                    #"{"type":"custom_message","customType":"skill-prompt","content":"SKILL BODY","display":true,"id":"s","parentId":null,"#
                        + fields + "}",
                ]))
            return reducer.transcript(.init()).entries.first?.content
        }
        #expect(
            entry(#""attribution":"user","details":{"name":"probe","prompt":"please /skill:probe now"}"#)
                == .user(ChatUserMessage(text: "please /skill:probe now")))
        #expect(
            entry(#""attribution":"user","details":{"name":"probe"}"#)
                == .notice(ChatNotice(kind: .hook, title: "skill-prompt", detail: "SKILL BODY")))
        #expect(
            entry(#""attribution":"agent","details":{"name":"probe","prompt":"/skill:probe"}"#)
                == .notice(ChatNotice(kind: .hook, title: "skill-prompt", detail: "SKILL BODY")))
    }

    @Test func blockedToolInSkillTurnIsPending() {
        var reducer = PiTranscriptReducer()
        reducer.append(Self.lines(Self.skillTurn))
        let transcript = reducer.transcript(.init(activity: .blocked))
        guard case .tool(let tool) = transcript.entries.last?.content else {
            Issue.record("Tool missing")
            return
        }
        #expect(tool.status == .awaitingApproval)
        #expect(tool.subtitle == nil)
        #expect(
            transcript.pendingRequests
                == [
                    ChatPendingRequest(
                        entryID: ChatEntryID("pi:tool:call_1|fc_1"), callID: "call_1|fc_1", kind: .command,
                        toolName: "bash", summary: "echo probe")
                ])
    }

    @Test func piSkillBlockShowsAsCommandAndEchoes() throws {
        let lines = try ChatFixture.lines("pi/auth-error-skill.jsonl")
        var reducer = PiTranscriptReducer()
        reducer.append(lines)
        let transcript = reducer.transcript(.init())
        let skill = try #require(transcript.entries.first { $0.id == ChatEntryID("pi:d3d6363a") })
        let invocation = ChatCommandInvocation(name: "probe-hello", arguments: "world args")
        #expect(skill.content == .user(ChatUserMessage(text: "/probe-hello world args", command: invocation)))
        #expect(transcript.recordedPrompts.last?.text == "/skill:probe-hello world args")
        #expect(transcript.turns.count == 2)

        func content(_ text: String) -> (ChatEntry.Content?, String?) {
            var reducer = PiTranscriptReducer()
            let record: JSONValue = .object([
                "type": .string("message"), "id": .string("u"), "parentId": .null,
                "message": .object(["role": .string("user"), "content": .string(text)]),
            ])
            reducer.append(Self.lines([Self.header, String(decoding: try! JSONEncoder().encode(record), as: UTF8.self)]))
            let transcript = reducer.transcript(.init())
            return (transcript.entries.first?.content, transcript.recordedPrompts.first?.text)
        }
        let block = "<skill name=\"hello\" location=\"/p/SKILL.md\">\nBody line\n</skill>"
        #expect(
            content(block)
                == (.user(ChatUserMessage(text: "/hello", command: ChatCommandInvocation(name: "hello"))), "/skill:hello"))
        let multiline = ChatCommandInvocation(name: "hello", arguments: "first\n\nsecond </skill>")
        #expect(
            content(block + "\n\nfirst\n\nsecond </skill>")
                == (
                    .user(ChatUserMessage(text: multiline.displayText, command: multiline)),
                    "/skill:hello first\n\nsecond </skill>"
                ))
        let unclosed = "<skill name=\"hello\" location=\"/p/SKILL.md\">\nBody line\n\nargs"
        #expect(content(unclosed) == (.user(ChatUserMessage(text: unclosed)), unclosed))
    }

    private static func ompTranscript(through line: Int? = nil, activity: ChatAgentActivity = .idle) throws
        -> ChatTranscript
    {
        let lines = try ChatFixture.lines("omp/approvals-asks-plan.jsonl")
        var reducer = PiTranscriptReducer()
        reducer.append(Array(lines.prefix(line ?? lines.count)))
        return reducer.transcript(.init(activity: activity))
    }

    private static func tool(_ callPrefix: String, in transcript: ChatTranscript) -> ChatToolActivity? {
        for entry in transcript.entries {
            if case .tool(let tool) = entry.content, tool.callID?.hasPrefix(callPrefix) == true { return tool }
        }
        return nil
    }

    @Test func ompAskPendingRequestCarriesQuestions() throws {
        // The two-question ask, Blocked before its result.
        let transcript = try Self.ompTranscript(through: 37, activity: .blocked)
        let request = try #require(transcript.pendingRequests.first)
        #expect(transcript.pendingRequests.count == 1)
        #expect(request.callID?.contains("|") == true)
        #expect(request.kind == .question)
        #expect(request.toolName == "ask")
        #expect(request.summary == "Pick a fruit")
        #expect(
            request.questions
                == [
                    ChatQuestion(id: "fruit", text: "Pick a fruit", options: ["apple", "pear"]),
                    ChatQuestion(id: "size", text: "Pick a size", options: ["small", "large"]),
                ])

        var reducer = PiTranscriptReducer()
        reducer.append(
            Self.lines([
                Self.header,
                #"{"type":"message","id":"a","parentId":null,"message":{"role":"assistant","content":[{"type":"toolCall","id":"c","name":"ask","arguments":{"questions":[{"id":"q","question":"Which?","header":"Pick","options":[{"label":"one","description":"First"},{"label":"two"}],"multi":true,"recommended":1}]}}],"stopReason":"toolUse"}}"#,
            ]))
        #expect(
            reducer.transcript(.init(activity: .blocked)).pendingRequests.first?.questions
                == [
                    ChatQuestion(
                        id: "q", header: "Pick", text: "Which?",
                        options: [ChatQuestion.Option(label: "one", detail: "First"), "two"], isMultiSelect: true,
                        recommendedIndex: 1)
                ])
    }

    @Test func ompDeniedApprovalIsDeclined() throws {
        let transcript = try Self.ompTranscript(through: 28)
        #expect(Self.tool("call_adb504f6", in: transcript)?.status == .succeeded)
        #expect(Self.tool("call_74e0dc7b", in: transcript)?.status == .declined)
        #expect(Self.tool("call_fd940fe8", in: transcript)?.status == .declined)
        #expect(transcript.pendingRequests.isEmpty)
    }

    @Test func ompCancelledAskIsDeclined() throws {
        let transcript = try Self.ompTranscript(through: 39)
        let ask = try #require(Self.tool("call_7bfdda8a", in: transcript))
        #expect(ask.status == .declined)
        #expect(ask.questions.allSatisfy { $0.answer == nil })
        #expect(
            transcript.entries.last?.content == .notice(ChatNotice(kind: .interrupted, title: "Interrupted")))
        #expect(transcript.turns.last?.ending == .interrupted)
    }

    @Test func ompAnsweredAskRecordsAnswer() throws {
        let transcript = try Self.ompTranscript()
        #expect(
            Self.tool("call_c20d8fdc", in: transcript)?.questions
                == [ChatQuestion(id: "fruit", text: "Pick a fruit", options: ["apple", "pear", "plum"], answer: "pear")])
        #expect(Self.tool("call_a97f9e92", in: transcript)?.questions.first?.answer == "red")

        // Several questions answer by id.
        var reducer = PiTranscriptReducer()
        reducer.append(
            Self.lines([
                Self.header,
                #"{"type":"message","id":"a","parentId":null,"message":{"role":"assistant","content":[{"type":"toolCall","id":"c","name":"ask","arguments":{"questions":[{"id":"one","question":"First?","options":[{"label":"x"},{"label":"y"}]},{"id":"two","question":"Second?","options":[{"label":"p"},{"label":"q"}],"multi":true}]}}],"stopReason":"toolUse"}}"#,
                #"{"type":"message","id":"r","parentId":"a","message":{"role":"toolResult","toolCallId":"c","toolName":"ask","content":[{"type":"text","text":"User answers:\none: y\ntwo: [p, q]"}],"details":{"results":[{"id":"two","selectedOptions":["p","q"]},{"id":"one","selectedOptions":["y"]}]},"isError":false}}"#,
            ]))
        guard case .tool(let tool) = reducer.transcript(.init()).entries.last?.content else {
            Issue.record("Tool missing")
            return
        }
        #expect(tool.questions.map(\.answer) == ["y", "p, q"])
    }

    @Test func toolWithoutATargetIsSubtitledByItsIntent() {
        var reducer = PiTranscriptReducer()
        reducer.append(
            Self.lines([
                Self.header,
                #"{"type":"message","id":"a","parentId":null,"message":{"role":"assistant","content":[{"type":"toolCall","id":"c","name":"edit","arguments":{"input":"*** Begin Patch","i":"Fixing the typo"}}],"stopReason":"toolUse"}}"#,
            ]))
        guard case .tool(let tool) = reducer.transcript(.init(activity: .working)).entries.last?.content else {
            Issue.record("Tool missing")
            return
        }
        #expect(tool.title == "edit")
        #expect(tool.subtitle == "Fixing the typo")
    }

    @Test func emptyPiEditorPassesButDraftAndPopupDoNot() {
        let rule = String(repeating: "─", count: 40)
        let footer = "~/project (main)\r\n$0.000 0.0%/200k (auto)"
        func detect(_ text: String) -> InputBoxState {
            InputBoxStateDetector.detect(ANSIScreenDecoder.decode(text), program: .pi)
        }
        #expect(detect("\(rule)\r\n\u{1B}[7m \u{1B}[0m\r\n\(rule)\r\n\(footer)") == .empty(placeholder: nil))
        #expect(detect("\(rule)\r\nexisting\u{1B}[7m \u{1B}[0m\r\n\(rule)\r\n\(footer)") == .text("existing"))
        #expect(
            detect("\(rule)\r\n\u{1B}[7m \u{1B}[0m\r\n\(rule)\r\n❯ /model\r\n\(footer)") == .overlay("❯ /model"))
        #expect(!detect("\(rule)\r\n\r\n\(rule)\r\n\(footer)").isSendable)
    }

    // MARK: Pi 0.85.1 editor and footer

    private static func piState(_ stem: String) throws -> InputBoxState {
        InputBoxStateDetector.detect(try ScreenFixture.screen(stem), program: .pi)
    }

    /// Pi-06 has the Update notice's rules above the editor and its project
    /// outside the home directory, so the pwd row starts with `/`; pi-17's
    /// pwd is cut with `...`; pi-14 compacts while herdr reports idle.
    @Test(arguments: [
        "pi-06-empty-editor-119", "pi-08-auth-error-idle", "pi-13-skill-invoked", "pi-14-compact-0.25s",
        "pi-16-empty-editor-120-attached", "pi-17-empty-editor-40-attached",
    ])
    func piEmptyEditorAnywhereIsEmpty(stem: String) throws {
        let screen = try ScreenFixture.screen(stem)
        #expect(InputBoxStateDetector.detect(screen, program: .pi) == .empty(placeholder: nil))
        #expect(PreSendGate.check(screen, program: .pi, activity: .idle) == .send)
    }

    @Test(arguments: [
        ("pi-11-nonempty-after-popup-esc", "/pr"), ("pi-12-nonempty-editor", "hello draft text"),
        ("pi-20-nonempty-40", "a fairly long draft line that will\nwrap at forty columns"),
    ])
    func piDraftsAreText(stem: String, draft: String) throws {
        #expect(try Self.piState(stem) == .text(draft))
    }

    /// The editor holds `/`, so a draft reading would also hold; what
    /// matters is that a completion list never passes.
    @Test(arguments: ["pi-09-slash-popup", "pi-10-slash-pr-popup", "pi-19-slash-popup-40"])
    func piPopupBetweenBorderAndFooterIsOverlay(stem: String) throws {
        let screen = try ScreenFixture.screen(stem)
        let state = InputBoxStateDetector.detect(screen, program: .pi)
        switch state {
        case .overlay(let row): #expect(row.hasPrefix("→ "))
        default: Issue.record("\(stem) read as \(state)")
        }
        #expect(PreSendGate.check(screen, program: .pi, activity: .idle) != .send)
    }

    @Test func piTrustSelectorIsUnknown() throws {
        let state = try Self.piState("pi-03-trust-1s")
        guard case .unknown = state else {
            Issue.record("pi-03 read as \(state)")
            return
        }
    }

    @Test func piFooterIsMatchedByStructure() {
        let rule = String(repeating: "─", count: 40)
        let editor = "\(rule)\r\n\u{1B}[7m \u{1B}[0m\r\n\(rule)"
        func detect(_ below: String...) -> InputBoxState {
            let rows = [editor] + below
            return InputBoxStateDetector.detect(ANSIScreenDecoder.decode(rows.joined(separator: "\r\n")), program: .pi)
        }
        #expect(detect("/srv/app (main)", "↑12k ↓3.4k R120k W12k CH90.0% $0.12...") == .empty(placeholder: nil))
        #expect(detect("~/app", "?/200k (auto)    model", "extension status") == .empty(placeholder: nil))
        #expect(detect("→ compact   Compact the session", "~/app", "$0.000 0.0%/200k") == .overlay("→ compact   Compact the session"))
        #expect(!detect("~/app").isSendable)
        #expect(!detect("~/app (mai...", "grok-4.5 • high").isSendable)
        #expect(detect("~/app", "$0.000 0.0%/200k").isSendable)
        let twoBlankRows = "\(rule)\r\n\u{1B}[7m \u{1B}[0m\r\n\r\n\(rule)\r\n~/app\r\n$0.000 0.0%/200k"
        #expect(!InputBoxStateDetector.detect(ANSIScreenDecoder.decode(twoBlankRows), program: .pi).isSendable)
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

    // MARK: OMP 18.11.1 nerd band composer

    private static func ompState(_ stem: String) throws -> InputBoxState {
        InputBoxStateDetector.detect(try ScreenFixture.screen(stem), program: .omp)
    }

    @Test(arguments: [
        "omp-01-startup-empty-119", "omp-02-empty-120-before-first", "omp-03-empty-40-before-first",
        "omp-07-empty-40-after-first", "omp-08-empty-120-after-first", "omp-19-compact-nospace-1s",
        "omp-26-approval-b-idle", "omp-27-ask-e-idle", "omp-28-ask2-e-after-esc-2s", "omp-29-guard-f-idle",
        "omp-30-plan-mode-on", "omp-32-plan-after-esc",
    ])
    func ompIdleNerdBandIsEmpty(stem: String) throws {
        let screen = try ScreenFixture.screen(stem)
        #expect(InputBoxStateDetector.detect(screen, program: .omp) == .empty(placeholder: nil))
        #expect(PreSendGate.check(screen, program: .omp, activity: .idle) == .send)
    }

    @Test(arguments: [
        "omp-01-startup-empty-119", "omp-02-empty-120-before-first", "omp-03-empty-40-before-first",
    ])
    func ompFirstMessageHintIsNotADraft(stem: String) throws {
        let screen = try ScreenFixture.screen(stem)
        let prompt = try #require(screen.rows.last { $0.text.hasPrefix("╰─ ") })
        #expect(prompt.text.contains("to change thinking effort"))
        #expect(InputBoxStateDetector.detect(screen, program: .omp) == .empty(placeholder: nil))
    }

    @Test(arguments: ["omp-05-qa-working-1s", "omp-09-tool-working-3s"])
    func ompWorkingBandHoldsWithReason(stem: String) throws {
        let screen = try ScreenFixture.screen(stem)
        let state = InputBoxStateDetector.detect(screen, program: .omp)
        #expect(state == .disabled("Oh My Pi is working. Send once it's idle, or steer from the terminal."))
        #expect(PreSendGate.check(screen, program: .omp, activity: .working) == .hold(state))
    }

    @Test(arguments: [
        ("omp-16-compact-space-after-enter", "/compact soft [focus]"),
        ("omp-29-guard-a-draft-while-working", "my draft text"),
    ])
    func ompDraftsAndGhostTextAreText(stem: String, draft: String) throws {
        #expect(try Self.ompState(stem) == .text(draft))
    }

    @Test(arguments: [
        "omp-14-slash-popup", "omp-17-compact-space-pre-enter-150ms", "omp-18-compact-nospace-150ms",
        "omp-21-after-exit-shell", "omp-33-after-exit-2",
    ])
    func ompPopupsAndShellBelowAreOverlay(stem: String) throws {
        let state = try Self.ompState(stem)
        guard case .overlay = state else {
            Issue.record("\(stem) read as \(state)")
            return
        }
    }

    /// Approval and ask panels keep the band and prompt below them, with or
    /// without a draft in the prompt.
    @Test(arguments: [
        "omp-23-approval-a-ctrlq-early", "omp-24-approval-a-dialog", "omp-24-approval-d-typed-abc",
        "omp-29-guard-b-ask-with-draft", "omp-29-guard-c-after-enter",
    ])
    func ompPanelAboveBandIsNotSendable(stem: String) throws {
        let screen = try ScreenFixture.screen(stem)
        let state = InputBoxStateDetector.detect(screen, program: .omp)
        switch state {
        case .overlay, .dialog: break
        default: Issue.record("\(stem) read as \(state)")
        }
        #expect(PreSendGate.check(screen, program: .omp, activity: .idle) != .send)
    }

    @Test func ompPlanReviewIsNotSendable() throws {
        let screen = try ScreenFixture.screen("omp-31-plan-review")
        #expect(PreSendGate.check(screen, program: .omp, activity: .idle) != .send)
    }

    @Test func ompPromptHintsAreDroppedOnlyWhenItalicAndSetApart() {
        let band =
            "\u{1B}[38;2;15;18;22m\u{E0B6}\u{1B}[0m\u{1B}[48;2;15;18;22m \u{F0D57} \u{1B}[0m──3%────272K─"
        func detect(_ prompt: String) -> InputBoxState {
            InputBoxStateDetector.detect(ANSIScreenDecoder.decode("\(band)\r\n\(prompt)"), program: .omp)
        }
        let hint = "to change thinking effort"
        #expect(detect("╰─") == .empty(placeholder: nil))
        #expect(detect("╰─ hello      \(hint)") == .text("hello      \(hint)"))
        #expect(detect("╰─ hello  \(SGR.italic)\(hint)\(SGR.reset)") == .text("hello"))
        #expect(detect("╰─ hello \(SGR.italic)\(hint)\(SGR.reset)") == .text("hello \(hint)"))
        #expect(detect("╰─    \u{F0636} \(SGR.italic)to see 2 running agents\(SGR.reset)") == .empty(placeholder: nil))
        #expect(detect("╰─    \(SGR.italic)something else\(SGR.reset)") == .text("something else"))
    }

    @Test func ompUnknownBandGlyphsStayUnrecognized() {
        func detect(_ segment: String) -> InputBoxState {
            let band = "\u{1B}[48;2;15;18;22m\(segment) project \u{1B}[0m──3%────272K─"
            return InputBoxStateDetector.detect(ANSIScreenDecoder.decode("\(band)\r\n╰─ "), program: .omp)
        }
        #expect(detect("\u{E0B6} \u{2839} 1s") == .disabled("Oh My Pi is working. Send once it's idle, or steer from the terminal."))
        #expect(!detect("pi >").isSendable)
        #expect(!detect("\u{E0B6} @ explore").isSendable)
        #expect(!detect("\u{E0B6} \u{F0D58}").isSendable)
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
