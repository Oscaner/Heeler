import SwiftUI

/// How Chat explains a conversation it cannot show (ADR 0024). Each reason
/// leaves the terminal one tap away; none is something Heeler fixes on the
/// Host by itself.
extension ChatUnavailableReason {
    var title: String {
        switch self {
        case .noSession: "Waiting for Conversation"
        case .unidentifiedSession: "Conversation Not Identified"
        case .notFound, .mismatched: "Conversation Not Found"
        case .awaitingFirstMessage: "No Messages Yet"
        case .compressed: "Conversation Compressed"
        case .unsupportedSession, .unsupportedFormat: "Conversation Not Readable"
        }
    }

    var systemImage: String {
        switch self {
        case .noSession, .awaitingFirstMessage: "bubble.left.and.bubble.right"
        case .notFound, .mismatched: "doc.text.magnifyingglass"
        default: "exclamationmark.bubble"
        }
    }

    var explanation: String {
        switch self {
        case .noSession(.claude):
            "herdr hasn't reported a Claude Code session ID for this Agent. Chat will keep checking. You can continue in the Agent terminal."
        case .noSession(.codex):
            "herdr hasn't reported a Codex session ID for this Agent. Codex reports it after the first prompt, also after a resume, so send a prompt to show the conversation here. Chat will keep checking, and you can continue in the Agent terminal."
        case .noSession(.pi):
            "herdr hasn't reported a Pi conversation for this Agent yet. Pi reports it once it has started, after you answer whether to trust the project folder. If this lasts, check the Pi integration on the Host. Chat will keep checking, and you can continue in the Agent terminal."
        case .noSession(.omp):
            "herdr hasn't reported an Oh My Pi conversation for this Agent yet. Oh My Pi reports it once it has started. If this lasts, check the OMP integration on the Host. Chat will keep checking, and you can continue in the Agent terminal."
        case .noSession(.opencode):
            "herdr hasn't reported an OpenCode conversation for this Agent yet. OpenCode reports one once a conversation is open: send a first message in the terminal, or open a session there. Chat will keep checking, and you can continue in the Agent terminal."
        case .unidentifiedSession(.claude), .unidentifiedSession(.codex), .unidentifiedSession(.pi),
            .unidentifiedSession(.omp):
            "herdr names this Agent's session without an id, which happens after resuming a conversation by name. Chat can't tell which transcript is its own."
        case .unidentifiedSession(.opencode):
            "herdr reports a session name that isn't an OpenCode session id, so Chat can't tell which conversation is this Agent's."
        case .unsupportedSession:
            "herdr reports a session Chat doesn't read."
        case .notFound(let searchedAll):
            searchedAll
                ? "Heeler couldn't find this conversation's transcript on the Host. It keeps looking while Chat is open."
                : "Heeler hasn't found this conversation's transcript yet. It keeps looking while Chat is open."
        case .awaitingFirstMessage(let program):
            "\(program.chatName) saves this conversation after its first reply. Send a message to start it."
        case .compressed:
            "Codex compressed this conversation's rollout, which Chat can't read."
        case .mismatched:
            "The transcript under this session's name holds another conversation."
        case .unsupportedFormat(let format):
            "Chat can't read \(format)."
        }
    }

    /// One line for a banner over the timeline. `showingSavedMessages` is
    /// false when the timeline holds only messages sent from this device,
    /// as with a new conversation whose transcript isn't written yet.
    func bannerText(showingSavedMessages: Bool) -> String {
        let saved = showingSavedMessages ? " Showing saved messages." : ""
        return switch self {
        case .noSession:
            "Waiting for the Agent to report its conversation."
        case .awaitingFirstMessage(let program):
            "\(program.chatName) saves this conversation after its first reply."
        case .unidentifiedSession, .unsupportedSession:
            "Chat can't follow this conversation now.\(saved)"
        case .notFound:
            showingSavedMessages
                ? "The transcript isn't on the Host any more.\(saved)"
                : "Heeler hasn't found this conversation's transcript yet."
        case .mismatched:
            "The transcript under this session's name holds another conversation.\(saved)"
        case .compressed, .unsupportedFormat:
            "Chat can't read this transcript now.\(saved)"
        }
    }

    /// Whether looking again could find something the user may have fixed.
    var offersRetry: Bool {
        switch self {
        case .noSession, .notFound, .mismatched: true
        default: false
        }
    }

    var isAwaitingFirstMessage: Bool {
        if case .awaitingFirstMessage = self { true } else { false }
    }

    /// Whether Chat waits for the program rather than for the user: its
    /// banner shows progress and offers nothing to do.
    var isWaiting: Bool {
        switch self {
        case .noSession, .awaitingFirstMessage: true
        default: false
        }
    }
}

/// What takes the conversation's place, if anything, under the banners.
enum ChatSurfacePresentation: Equatable {
    case timeline
    /// Searching the Host for the transcript, with nothing saved to show.
    case locating
    /// Nothing saved to show, and the Host to search isn't connected:
    /// nothing is being looked for until it is.
    case awaitingHost
    case empty
    case unavailable(ChatUnavailableReason)
    /// The Host is not in the catalog, so there is no Chat to read.
    case disconnected

    /// `conversation` is nil while there is no Chat to read.
    init(conversation: ChatConversationSnapshot?, hasPendingEchoes: Bool, isHostConnected: Bool) {
        guard let conversation else {
            self = .disconnected
            return
        }
        if conversation.showsTimeline(hasPendingEchoes: hasPendingEchoes) {
            self = .timeline
            return
        }
        switch conversation.phase {
        case .locating: self = isHostConnected ? .locating : .awaitingHost
        case .following: self = .empty
        case .unavailable(let reason): self = .unavailable(reason)
        }
    }
}

/// One line over Chat's conversation, before the view adds its action.
enum ChatBannerLine: Equatable, Identifiable {
    case connecting(showingSavedMessages: Bool)
    case notConnected(showingSavedMessages: Bool)
    case readFailure(TransportError)
    case unavailable(ChatUnavailableReason, showingSavedMessages: Bool)

    var id: String {
        switch self {
        case .connecting, .notConnected: "host"
        case .readFailure: "read"
        case .unavailable: "unavailable"
        }
    }

    /// The lines over the conversation, top to bottom. `conversation` is nil
    /// while there is no Chat to read. Saved messages are transcript entries
    /// this device kept; messages sent from it and not yet recorded are not.
    static func lines(
        hostStatus: EventsSessionStatus?, conversation: ChatConversationSnapshot?, hasPendingEchoes: Bool
    ) -> [ChatBannerLine] {
        let showingSaved = conversation?.transcript.entries.isEmpty == false
        switch hostStatus {
        case .connected?: break
        case .connecting?, .reconnecting?: return [.connecting(showingSavedMessages: showingSaved)]
        default: return [.notConnected(showingSavedMessages: showingSaved)]
        }
        guard let conversation else { return [] }
        var lines: [ChatBannerLine] = []
        if let failure = conversation.readFailure { lines.append(.readFailure(failure)) }
        if case .unavailable(let reason) = conversation.phase,
            conversation.showsTimeline(hasPendingEchoes: hasPendingEchoes)
        {
            lines.append(
                .unavailable(reason, showingSavedMessages: !conversation.transcript.entries.isEmpty))
        }
        return lines
    }

    var text: String {
        switch self {
        // A Host that accepts the connection and never answers keeps this
        // line up, so it says the rows below are the saved ones.
        case .connecting(let showingSavedMessages):
            showingSavedMessages ? "Connecting to the Host… Showing saved messages." : "Connecting to the Host…"
        case .notConnected(let showingSavedMessages):
            showingSavedMessages ? "Not connected. Showing saved messages." : "Not connected."
        case .readFailure(let failure): "Couldn't read the conversation. \(failure.presentation.explanation)"
        case .unavailable(let reason, let showingSavedMessages):
            reason.bannerText(showingSavedMessages: showingSavedMessages)
        }
    }

    var systemImage: String {
        switch self {
        case .connecting: "wifi"
        case .notConnected: "wifi.slash"
        case .readFailure: "exclamationmark.triangle"
        case .unavailable(let reason, _): reason.systemImage
        }
    }

    var showsProgress: Bool {
        switch self {
        case .connecting: true
        case .unavailable(let reason, _): reason.isWaiting
        case .notConnected, .readFailure: false
        }
    }
}

extension ChatConversationSnapshot {
    /// Whether the timeline is up rather than a placeholder: it has entries,
    /// or messages sent from this device the program hasn't recorded yet.
    func showsTimeline(hasPendingEchoes: Bool) -> Bool {
        !transcript.entries.isEmpty || hasPendingEchoes
    }
}

extension ChatProgram {
    /// The program's name in what Chat says about its conversation.
    var chatName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .pi: "Pi"
        case .omp: "Oh My Pi"
        case .opencode: "OpenCode"
        }
    }
}

/// In the conversation's place while there is nothing to show.
struct ChatUnavailableView: View {
    let reason: ChatUnavailableReason
    let retry: () -> Void
    let showAgentTerminal: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(reason.title, systemImage: reason.systemImage)
        } description: {
            Text(reason.explanation)
        } actions: {
            Button(AgentDetailSurface.terminal.showTitle, action: showAgentTerminal)
                .buttonStyle(.bordered)
            if reason.offersRetry {
                Button("Check Again", action: retry)
            }
        }
        .accessibilityIdentifier("chat.unavailable")
    }
}

/// While Chat looks for the transcript and has nothing saved to show.
struct ChatLocatingView: View {
    var body: some View {
        ProgressView {
            Text("Looking for the conversation…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("chat.locating")
    }
}

/// A conversation with nothing in it yet.
struct ChatEmptyConversationView: View {
    var description = "Messages you and the Agent send show here."

    var body: some View {
        ContentUnavailableView(
            "No Messages Yet", systemImage: "bubble.left.and.bubble.right",
            description: Text(description))
        .accessibilityIdentifier("chat.empty")
    }
}

/// One line over the conversation: the Host is unreachable, a read failed,
/// or the transcript went away.
struct ChatBanner: View {
    let systemImage: String
    let text: String
    var showsProgress = false
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
