import Foundation

/// Pi/OMP v2-v3 JSONL is an append-only tree. Replay the latest selected
/// leaf's ancestry, including invisible extension/state entries. File order
/// alone would resurrect messages abandoned by /tree or a branch switch.
struct PiTranscriptReducer: ChatTranscriptReducer {
    static let revision = 1

    private struct Record: Sendable {
        let offset: UInt64
        let length: Int
        let value: JSONValue
        let isTruncated: Bool
        var type: String { value["type"]?.stringValue ?? "" }
        var id: String? { value["id"]?.stringValue }
        var parent: String? { value["parentId"]?.stringValue }
    }

    private var records: [UInt64: Record] = [:]
    private var invalid: Set<UInt64> = []
    private var oversized: Set<UInt64> = []

    mutating func append(_ lines: [ChatLine]) {
        for line in lines {
            if line.isTruncated {
                oversized.insert(line.offset)
            }
            // Preserve ids/parents before a large text or image block. The
            // shared structural prefix repair never invents a partial string.
            let data = line.isTruncated ? CodexJSONPrefix.repaired(line.data) : line.data
            guard let data, let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                value["type"]?.stringValue != nil
            else {
                invalid.insert(line.offset)
                continue
            }
            records[line.offset] = Record(
                offset: line.offset, length: line.length, value: value, isTruncated: line.isTruncated)
        }
    }

    mutating func prepend(_ lines: [ChatLine]) { append(lines) }

    var unsupportedFormat: String? {
        for record in records.values where record.type == "session" {
            guard case .number(let version)? = record.value["version"], version == 2 || version == 3 else {
                return "Pi session without a supported v2/v3 tree"
            }
        }
        return nil
    }

    func transcript(_ context: ChatProjectionContext) -> ChatTranscript {
        let ordered = records.values.sorted { $0.offset < $1.offset }
        var byID: [String: Record] = [:]
        var leaf: String?
        var title: String?
        for record in ordered {
            if record.type == "session" || record.type == "title" {
                if let name = record.value["title"]?.stringValue { title = name }
                continue
            }
            guard let id = record.id else { continue }
            byID[id] = record
            if record.type == "model_usage", let active = record.value["activeLeafId"] {
                // Late usage belongs to an earlier call and must not
                // select that call's branch again.
                leaf = active.stringValue
            } else {
                leaf = id
            }
        }
        var chain: [Record] = []
        var seen: Set<String> = []
        var missingAncestor = false
        while let id = leaf, seen.insert(id).inserted {
            guard let record = byID[id] else {
                missingAncestor = true
                break
            }
            chain.append(record)
            leaf = record.parent
        }
        chain.reverse()

        var transcript = ChatTranscript(
            title: title, needsOlderHistory: context.windowStart > 0 || missingAncestor,
            diagnostics: ChatTranscriptDiagnostics(invalidLines: invalid.count, oversizedLines: oversized.count))
        var calls: [String: Int] = [:]

        func entryID(_ record: Record, _ suffix: String = "") -> ChatEntryID {
            ChatEntryID("pi:\(record.id ?? String(record.offset))\(suffix)")
        }
        func add(_ record: Record, _ content: ChatEntry.Content, _ suffix: String = "") {
            transcript.entries.append(
                ChatEntry(id: entryID(record, suffix), sourceOffset: record.offset, content: content))
        }
        func finish(_ ending: ChatTurn.Ending, at record: Record) {
            if let index = transcript.turns.indices.last {
                transcript.turns[index].ending = ending
                transcript.turns[index].endedAt = Self.date(record)
            } else {
                transcript.precedingTurnEnd = ChatTurnEnd(ending: ending, endedAt: Self.date(record))
            }
        }

        for record in chain {
            switch record.type {
            case "session_info", "title_change":
                transcript.title =
                    record.value["name"]?.stringValue ?? record.value["title"]?.stringValue ?? transcript.title
            case "compaction":
                add(record, .divider(ChatDivider(kind: .compaction, detail: record.value["summary"]?.stringValue)))
            case "branch_summary":
                add(
                    record,
                    .notice(
                        ChatNotice(kind: .system, title: "Branch summary", detail: record.value["summary"]?.stringValue)
                    ))
            case "reset_boundary":
                add(record, .notice(ChatNotice(kind: .system, title: "Conversation context cleared")))
            case "custom_message":
                if record.value["display"] == .bool(true) {
                    add(
                        record,
                        .notice(
                            ChatNotice(
                                kind: .hook, title: record.value["customType"]?.stringValue ?? "Extension",
                                detail: Self.text(record.value["content"]))))
                }
            case "message":
                guard let message = record.value["message"], let role = message["role"]?.stringValue else { continue }
                switch role {
                case "user":
                    let text = Self.text(message["content"])
                    if let last = transcript.turns.indices.last, transcript.turns[last].ending == nil {
                        transcript.turns[last].ending = .interrupted
                        transcript.turns[last].endedAt = Self.date(record)
                    }
                    if record.isTruncated, text.isEmpty, Self.images(message["content"]) == 0 {
                        add(record, .notice(ChatNotice(kind: .system, title: "Message exceeds the preview limit")))
                    } else {
                        add(record, .user(ChatUserMessage(text: text, imageCount: Self.images(message["content"]))))
                    }
                    let id = entryID(record)
                    transcript.turns.append(ChatTurn(firstEntryID: id, startedAt: Self.date(record)))
                    if !record.isTruncated {
                        transcript.recordedPrompts.append(
                            ChatRecordedPrompt(offset: record.offset, text: text, entryID: id))
                    }
                    transcript.latestPromptOffset = record.offset
                case "assistant":
                    for (index, block) in Self.blocks(message["content"]).enumerated() {
                        switch block["type"]?.stringValue {
                        case "text":
                            if let text = block["text"]?.stringValue, !text.isEmpty {
                                add(record, .assistant(ChatAssistantMessage(text: text)), ":\(index)")
                            }
                        case "thinking":
                            if let text = block["thinking"]?.stringValue, !text.isEmpty {
                                add(record, .reasoning(ChatReasoning(text: text)), ":\(index)")
                            }
                        case "toolCall":
                            guard let callID = block["id"]?.stringValue, let name = block["name"]?.stringValue else {
                                continue
                            }
                            let tool = Self.tool(
                                name: name, arguments: block["arguments"], callID: callID, activity: context.activity)
                            calls[callID] = transcript.entries.count
                            transcript.entries.append(
                                ChatEntry(
                                    id: ChatEntryID("pi:tool:\(callID)"), sourceOffset: record.offset,
                                    content: .tool(tool)))
                        default: break
                        }
                    }
                    switch message["stopReason"]?.stringValue {
                    case "stop", "length": finish(.completed, at: record)
                    case "aborted":
                        add(record, .notice(ChatNotice(kind: .interrupted, title: "Interrupted")), ":end")
                        finish(.interrupted, at: record)
                    case "error":
                        add(
                            record,
                            .notice(
                                ChatNotice(
                                    kind: .error, title: "Agent error", detail: message["errorMessage"]?.stringValue)),
                            ":end")
                        finish(.failed, at: record)
                    default: break
                    }
                case "toolResult":
                    guard let callID = message["toolCallId"]?.stringValue else { continue }
                    var tool: ChatToolActivity
                    let index = calls[callID]
                    if let index, case .tool(let existing) = transcript.entries[index].content {
                        tool = existing
                    } else {
                        tool = Self.tool(
                            name: message["toolName"]?.stringValue ?? "Tool", arguments: nil, callID: callID,
                            activity: context.activity)
                    }
                    tool.status = message["isError"] == .bool(true) ? .failed : .succeeded
                    tool.preview = Self.preview(message)
                    if record.isTruncated {
                        tool.preview?.isTruncated = true
                        tool.note = "Output exceeds the preview limit."
                    }
                    tool.output = ChatOutputReference(offset: record.offset, length: record.length)
                    if let index {
                        transcript.entries[index].content = .tool(tool)
                    } else {
                        calls[callID] = transcript.entries.count
                        transcript.entries.append(
                            ChatEntry(
                                id: ChatEntryID("pi:tool:\(callID)"), sourceOffset: record.offset, content: .tool(tool))
                        )
                    }
                case "bashExecution":
                    add(
                        record,
                        .notice(
                            ChatNotice(
                                kind: .shellCommand, title: message["command"]?.stringValue ?? "Shell command",
                                detail: ChatToolPreview(capping: message["output"]?.stringValue ?? "").text)))
                default: transcript.diagnostics.unknownRecordTypes.insert("message:\(role)")
                }
            case "model_change", "thinking_level_change", "model_usage", "usage", "service_tier_change", "custom",
                "label",
                "context_edit", "session_init", "credential_pin", "ttsr_injection", "mode_change":
                break
            default: transcript.diagnostics.unknownRecordTypes.insert(record.type)
            }
        }
        let latestTurnOffset = transcript.latestPromptOffset ?? context.windowStart
        let ended = transcript.turns.last.map { $0.ending != nil } ?? (transcript.precedingTurnEnd != nil)
        for index in transcript.entries.indices {
            guard case .tool(var tool) = transcript.entries[index].content, tool.output == nil else { continue }
            if transcript.entries[index].sourceOffset < latestTurnOffset || ended { tool.status = .interrupted }
            if tool.status == .awaitingApproval {
                transcript.pendingRequests.append(
                    ChatPendingRequest(
                        entryID: transcript.entries[index].id, callID: tool.callID,
                        kind: tool.kind, toolName: tool.name, summary: tool.title, detail: tool.subtitle))
            }
            transcript.entries[index].content = .tool(tool)
        }
        return transcript
    }

    func output(of line: ChatLine, for tool: ChatToolActivity) -> ChatToolOutput? {
        guard !line.isTruncated, let record = try? JSONDecoder().decode(JSONValue.self, from: line.data),
            record["type"]?.stringValue == "message", let message = record["message"],
            message["role"]?.stringValue == "toolResult", message["toolCallId"]?.stringValue == tool.callID
        else { return nil }
        return .preview(Self.preview(message))
    }

    private static func tool(name: String, arguments: JSONValue?, callID: String, activity: ChatAgentActivity)
        -> ChatToolActivity
    {
        let kind: ChatToolActivity.Kind
        switch name.lowercased() {
        case "bash", "exec", "python": kind = .command
        case "read": kind = .fileRead
        case "edit", "apply_patch": kind = .fileEdit
        case "write": kind = .fileWrite
        case "grep", "find", "ls": kind = .search
        case "web_search", "fetch", "browse": kind = .web
        case "task", "subagent": kind = .agent
        case "ask", "ask_user": kind = .question
        default: kind = .other
        }
        let summary =
            arguments?["command"]?.stringValue ?? arguments?["path"]?.stringValue
            ?? arguments?["file_path"]?.stringValue ?? arguments?["pattern"]?.stringValue
            ?? arguments?["query"]?.stringValue ?? arguments?["url"]?.stringValue ?? name
        let status: ChatToolActivity.Status =
            switch activity {
            case .working: .running
            case .blocked: .awaitingApproval
            default: .interrupted
            }
        return ChatToolActivity(
            kind: kind, name: name, title: String(summary.prefix(500)), status: status, callID: callID)
    }

    private static func blocks(_ content: JSONValue?) -> [JSONValue] {
        if case .array(let blocks) = content { return blocks }
        if case .string(let text) = content { return [.object(["type": .string("text"), "text": .string(text)])] }
        return []
    }

    private static func text(_ content: JSONValue?) -> String {
        blocks(content).compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined(
            separator: "\n")
    }

    private static func images(_ content: JSONValue?) -> Int {
        blocks(content).filter { $0["type"]?.stringValue == "image" }.count
    }

    private static func preview(_ message: JSONValue) -> ChatToolPreview {
        ChatToolPreview(capping: text(message["content"]), imageCount: images(message["content"]))
    }

    private static func date(_ record: Record) -> Date? {
        if let text = record.value["timestamp"]?.stringValue {
            return Date.ISO8601FormatStyle(includingFractionalSeconds: true).parseStrategy.parseOptional(text)
                ?? Date.ISO8601FormatStyle().parseStrategy.parseOptional(text)
        }
        return nil
    }
}

extension ParseStrategy where ParseInput == String, ParseOutput == Date {
    fileprivate func parseOptional(_ input: String) -> Date? { try? parse(input) }
}
