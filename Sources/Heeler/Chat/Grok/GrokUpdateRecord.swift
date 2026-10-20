import Foundation

/// One line of a Grok Build session's `updates.jsonl`, decoded down to what
/// Chat projects. Each line is an ACP `session/update`, or Grok's own
/// `_x.ai/session/update`: `params.update.sessionUpdate` names its kind, and
/// `params._meta` carries its event id and Grok's clock. Neither the line nor
/// an image's data is kept.
struct GrokUpdateRecord: Sendable {
    /// An `eventId`, `<session>-<n>`: the session that first wrote the
    /// record (a fork keeps its parent's) and its number there. Only split
    /// prompts compare it; Grok numbers events again after a rewind, so it
    /// never identifies a record.
    struct EventNumber: Equatable, Sendable {
        let prefix: String
        let number: Int

        init?(_ eventID: String) {
            guard let dash = eventID.lastIndex(of: "-"), let number = Int(eventID[eventID.index(after: dash)...])
            else { return nil }
            prefix = String(eventID[..<dash])
            self.number = number
        }
    }

    /// One content block of a prompt.
    struct UserChunk: Sendable {
        /// `text`, `image` or another ACP block type.
        let contentType: String?
        let text: String?
        /// What Grok shows instead of `text`: a skill's `/name args`, or an
        /// interjection's own words.
        let displayText: String?
        let displayAsSkill: Bool
        /// The command a `!cmd` typed in Grok's shell mode ran.
        let bashCommand: String?
        /// Counts submitted prompts from 0. Nil for an interjection and a
        /// shell-mode command, and when a cut line lost it.
        let promptIndex: Int?
        /// A prompt Grok wrote for itself (`hideFromScrollback`): a task,
        /// subagent or notification wake-up.
        let isHidden: Bool
    }

    /// A message or thought block, or one part of it.
    struct AgentChunk: Sendable {
        let text: String?
        /// Consecutive within one block.
        let chunkID: Int?
    }

    struct TurnCompleted: Sendable {
        let stopReason: String?
        /// The error's text when `stopReason` is `error`.
        let agentResult: String?
        let elapsedMilliseconds: Int64?
        /// What cancelled the turn (`params._meta`).
        let cancelTrigger: String?
        let cancellationCategory: String?
    }

    enum Retry: Sendable {
        /// Grok tries the request again.
        case retrying
        case exhausted(attempts: Int?, reason: String?)
        /// An error Grok does not retry, such as an expired sign-in.
        case failed(message: String?)
    }

    enum Kind: Sendable {
        case userChunk(UserChunk)
        case agentMessage(AgentChunk)
        case agentThought(AgentChunk)
        case toolCall(id: String?)
        case toolUpdate(id: String?)
        case turnCompleted(TurnCompleted)
        case rewind(targetPromptIndex: Int?)
        case compactionCheckpoint
        case compactionCancelled
        case compactionFailed(error: String?)
        case retry(Retry)
        case imageDropped(notes: [String])
        case taskBackgrounded
        case taskCompleted
        case subagentSpawned
        case subagentFinished
        /// A kind Chat shows nothing for.
        case skipped(String)
        /// A kind this build does not know.
        case unknown(String)
    }

    let offset: UInt64
    let length: Int
    /// The line was longer than the reader keeps. Fields after the cut are
    /// missing, `params._meta` among them: it follows the content.
    let isTruncated: Bool
    /// Seconds, on the Host's clock.
    let timestamp: Int?
    let agentTimestampMs: Int64?
    /// When the turn an agent record belongs to started.
    let turnStartMs: Int64?
    /// `params._meta.promptId`, which agent records carry.
    let promptID: String?
    let eventNumber: EventNumber?
    let kind: Kind

    static func decode(_ line: ChatLine) -> GrokUpdateRecord? {
        // A cut line still parses up to its last complete value, which
        // keeps the kind and the fields before a long text or output.
        let data = line.isTruncated ? CodexJSONPrefix.repaired(line.data) : line.data
        guard let data, let value = try? JSONDecoder().decode(JSONValue.self, from: data),
            let update = value["params"]?["update"], let type = update["sessionUpdate"]?.stringValue
        else { return nil }
        let meta = value["params"]?["_meta"]
        return GrokUpdateRecord(
            offset: line.offset, length: line.length, isTruncated: line.isTruncated,
            timestamp: integer(value["timestamp"]).flatMap { Int(exactly: $0) },
            agentTimestampMs: integer(meta?["agentTimestampMs"]), turnStartMs: integer(meta?["turnStartMs"]),
            promptID: meta?["promptId"]?.stringValue, eventNumber: meta?["eventId"]?.stringValue.flatMap(EventNumber.init),
            kind: kind(type, update: update, meta: meta))
    }

    /// Kinds that show nothing: hooks, Grok's bookkeeping, and `plan`, whose
    /// snapshot the `todo_write` row covers.
    private static let skippedKinds: Set<String> = [
        "plan", "hook_execution", "background_tasks", "session_recap", "response_started", "turn_usage",
        "model_changed", "served_model", "available_commands_update", "current_mode_update", "image_compressed",
        "session_start", "auto_compact_started", "auto_compact_completed",
    ]

    private static func kind(_ type: String, update: JSONValue, meta: JSONValue?) -> Kind {
        switch type {
        case "user_message_chunk":
            let content = update["content"]
            return .userChunk(
                UserChunk(
                    contentType: content?["type"]?.stringValue, text: content?["text"]?.stringValue,
                    displayText: content?["_meta"]?["displayText"]?.stringValue,
                    displayAsSkill: content?["_meta"]?["displayAsSkill"] == .bool(true),
                    bashCommand: content?["_meta"]?["bash_command"]?.stringValue,
                    promptIndex: integer(update["_meta"]?["promptIndex"]).flatMap { Int(exactly: $0) },
                    isHidden: update["_meta"]?["hideFromScrollback"] == .bool(true)))
        case "agent_message_chunk":
            return .agentMessage(agentChunk(update, meta))
        case "agent_thought_chunk":
            return .agentThought(agentChunk(update, meta))
        case "tool_call":
            return .toolCall(id: update["toolCallId"]?.stringValue)
        case "tool_call_update":
            return .toolUpdate(id: update["toolCallId"]?.stringValue)
        case "turn_completed":
            return .turnCompleted(
                TurnCompleted(
                    stopReason: update["stop_reason"]?.stringValue, agentResult: update["agent_result"]?.stringValue,
                    elapsedMilliseconds: integer(update["elapsed_ms"]),
                    cancelTrigger: meta?["cancelTrigger"]?.stringValue,
                    cancellationCategory: meta?["cancellationCategory"]?.stringValue))
        case "rewind_marker":
            return .rewind(targetPromptIndex: integer(update["target_prompt_index"]).flatMap { Int(exactly: $0) })
        case "compaction_checkpoint":
            return .compactionCheckpoint
        case "auto_compact_cancelled":
            return .compactionCancelled
        case "auto_compact_failed":
            return .compactionFailed(error: update["error"]?.stringValue)
        case "retry_state":
            switch update["type"]?.stringValue {
            case "exhausted":
                return .retry(
                    .exhausted(
                        attempts: integer(update["attempts"]).flatMap { Int(exactly: $0) },
                        reason: update["reason"]?.stringValue))
            case "failed":
                return .retry(.failed(message: update["message"]?.stringValue))
            default:
                return .retry(.retrying)
            }
        case "image_dropped":
            guard case .array(let notes) = update["notes"] else { return .imageDropped(notes: []) }
            return .imageDropped(notes: notes.compactMap(\.stringValue))
        case "task_backgrounded": return .taskBackgrounded
        case "task_completed": return .taskCompleted
        case "subagent_spawned": return .subagentSpawned
        case "subagent_finished": return .subagentFinished
        case _ where skippedKinds.contains(type) || type.hasPrefix("memory_dream_"):
            return .skipped(type)
        default:
            return .unknown(type)
        }
    }

    private static func agentChunk(_ update: JSONValue, _ meta: JSONValue?) -> AgentChunk {
        AgentChunk(
            text: update["content"]?["text"]?.stringValue,
            chunkID: integer(meta?["chunkId"]).flatMap { Int(exactly: $0) })
    }

    /// A whole number, which JSON decodes as a double.
    private static func integer(_ value: JSONValue?) -> Int64? {
        guard case .number(let number)? = value else { return nil }
        return Int64(exactly: number)
    }
}
