import Foundation

/// The conversation an Agent's herdr session record names: which program
/// wrote it and the session id its transcript is filed under.
///
/// herdr reports `agent_session` through the official integration hooks.
/// Chat binds by the exact source/agent pair and never parses `source`.
/// Claude/Codex use UUID ids; Pi/OMP also report absolute transcript paths.
/// A value is validated before it becomes a path or path component.
struct ConversationReference: Hashable, Sendable {
    let program: ChatProgram
    /// A canonical UUID, or Pi/OMP's validated absolute JSONL path. Paths
    /// are read directly, never interpolated into an exec command.
    let sessionID: String

    enum Resolution: Hashable, Sendable {
        case bound(ConversationReference)
        /// herdr has no session for the Agent yet. Codex reports one only
        /// after the first prompt.
        case noSession
        /// A session from another program, or of a kind Chat cannot read.
        case unsupported
        /// The right program, but the value is not a session id Chat can
        /// file-locate, such as a Codex thread name after `resume <name>`.
        case unidentified
    }

    static func resolve(_ session: AgentSessionInfo?) -> Resolution {
        guard let session else { return .noSession }
        let program: ChatProgram
        switch (session.source, session.agent) {
        case ("herdr:claude", "claude"): program = .claude
        case ("herdr:codex", "codex"): program = .codex
        case ("herdr:pi", "pi"): program = .pi
        case ("herdr:omp", "omp"): program = .omp
        default: return .unsupported
        }
        if program == .pi || program == .omp, session.kind == .path {
            guard RemoteFilePath.isAcceptable(session.value), session.value.hasSuffix(".jsonl") else {
                return .unidentified
            }
            return .bound(ConversationReference(program: program, sessionID: session.value))
        }
        guard session.kind == .id else { return .unsupported }
        guard let sessionID = canonicalUUID(session.value) else { return .unidentified }
        return .bound(ConversationReference(program: program, sessionID: sessionID))
    }

    /// The UUID's lowercased hyphenated text, or nil for anything else.
    /// UUID-based lookup uses lowercase file ids.
    static func canonicalUUID(_ text: String) -> String? {
        guard text.utf8.count == 36, let uuid = UUID(uuidString: text) else { return nil }
        return uuid.uuidString.lowercased()
    }
}
