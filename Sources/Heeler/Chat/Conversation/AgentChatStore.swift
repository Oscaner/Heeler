import Foundation
import Observation

/// What one Agent's Chat reads through. ConsoleStore binds the closures
/// late to the Host's live connection, so a reconnect never strands them.
struct AgentChatSource: Sendable {
    let hostID: Host.ID
    /// The herdr session the Host connects to, which keys the cache.
    let socketLocation: HerdrSocketLocation
    let files: ChatHostFiles
    /// Re-reads the Agent's record (`agent.get`). herdr reports a changed
    /// session through no event, so Chat asks after status changes.
    let agentInfo: @Sendable () async throws -> Agent
    let cache: any ChatTranscriptCache
    let adapter: ChatTranscriptAdapter
    /// Looks up only a saved binding for this exact Agent identity, waiting
    /// for the local directory to load. It never confirms a live session.
    var cachedSession: @Sendable (Agent) async -> AgentSessionInfo? = { _ in nil }
    /// The Agent's pane, which a Blocked card reads and answers.
    var screen: BlockedScreenIO = .unavailable
}

/// One Agent's Chat (ADR 0023): the conversation herdr says the Agent is
/// in, followed while Chat shows.
///
/// A single loop makes every engine call in turn. The view's requests, an
/// older page or a retry, only set a flag and wake the loop, so a poll, a
/// page and a save never interleave on one transcript.
@MainActor
@Observable
final class AgentChatStore {
    struct Timing: Sendable {
        var activeInterval: Duration = .seconds(1)
        var idleInterval: Duration = .seconds(4)
        /// How long after a change, a send or a status change polling stays
        /// at the active interval.
        var activeLinger: TimeInterval = 15
        /// Waits before looking for a transcript again, one per failed look;
        /// the last repeats.
        var locateBackoff: [TimeInterval] = [2, 4, 8, 16, 30]
        /// How often the Agent's record is re-read while it reports no
        /// session Chat can follow.
        var sessionRecheck: TimeInterval = 5
        /// How long after delivery a sent prompt may stay unrecorded before
        /// its echo says so.
        var echoTimeout: TimeInterval = 10
        /// How long Pi or Oh My Pi stays idle before Chat looks in its input
        /// box for unrecorded sends, overdue or not, that the turn which
        /// just ended put back.
        var returnCheckDelay: TimeInterval = 1
        var backgroundWorkStaleness = ChatBackgroundWork.Staleness()
    }

    /// A message in Chat's Composer, as the store matches it against the
    /// prompts the transcript records.
    struct SentMessage: Equatable, Sendable {
        let id: UUID
        /// What herdr typed: the draft after Chat's rewrite.
        let text: String
        /// `agent.prompt` took it, so the program may record it.
        let isDelivered: Bool
    }

    /// Where a sent message stands against the transcript.
    enum SendStatus: Equatable, Sendable {
        case awaiting
        /// The transcript recorded it; its entry replaces the echo.
        case recorded
        /// Still unrecorded `Timing.echoTimeout` after delivery.
        case overdue
        /// Unrecorded, and its text sits in the idle Agent's input box: Pi
        /// and Oh My Pi put a steer the turn had not taken back there when
        /// Esc stops the turn, and never record it. A recorded copy still
        /// wins, and a later read of the box that no longer finds it makes
        /// it discarded.
        case returned
        /// Returned, then gone from the input box without the transcript
        /// recording it, such as when the user cleared it in the terminal.
        /// The box is not looked at for it again; only a recorded copy,
        /// such as one the terminal sent, still settles it.
        case discarded
        /// Unrecorded and no longer worth an echo: it went into an earlier
        /// conversation, or was sent before this store was watching.
        case abandoned
    }

    let agentID: ConsoleAgent.ID
    let program: ChatProgram
    /// The conversation as last read, or why there is none.
    private(set) var conversation: ChatConversationSnapshot
    /// Whether a Chat view is showing this conversation.
    private(set) var isVisible = false
    /// Changes whenever Chat starts following another conversation, which
    /// the timeline opens at its end instead of diffing into.
    private(set) var conversationGeneration = 0
    /// Each message `updateSends(_:)` reported, by Composer message id.
    private(set) var sendStatuses: [UUID: SendStatus] = [:]
    /// The dialog the Agent waits on while herdr reports it Blocked.
    let blocked: BlockedCardStore
    /// Output read again for expanded tool rows in this conversation.
    private(set) var outputs = ChatToolOutputs()
    /// The Subagents and Workflows the conversation's program runs beside
    /// it, as last read.
    private(set) var backgroundWork = ChatBackgroundWork()

    @ObservationIgnored private let source: AgentChatSource
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var agent: Agent
    /// Whether this conversation has had a live read. Until then the
    /// Background Work list stays empty: saved work alone could have ended
    /// long ago (ADR 0023).
    @ObservationIgnored private var hasReadLive = false
    /// What herdr last said the Agent's session is.
    @ObservationIgnored private var resolution: ConversationReference.Resolution
    /// A session the transcript says the conversation continued in, until
    /// herdr reports a session of its own.
    @ObservationIgnored private var continuedSession: ConversationReference?
    @ObservationIgnored private var followed: ConversationReference?
    @ObservationIgnored private var engine: ChatConversationEngine?
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var appliedRevision: Int?
    @ObservationIgnored private var needsAgentRefresh = true
    /// Rejects an Agent query overtaken by a newer Console session record.
    @ObservationIgnored private var sessionRecordRevision = 0
    @ObservationIgnored private var lastAgentRefresh: Date?
    /// Agent queries and transcript reads recover independently.
    @ObservationIgnored private var agentRefreshFailure: TransportError?
    @ObservationIgnored private var transcriptReadFailure: TransportError?
    @ObservationIgnored private var olderRequested = false
    /// Look for the transcript's file again before the next read: Codex
    /// continues an undone thread in a new file and leaves the old one
    /// unchanged, so following it alone never shows the new turns.
    @ObservationIgnored private var needsRelocate = false
    @ObservationIgnored private var nextOpen: Date?
    @ObservationIgnored private var failedOpens = 0
    @ObservationIgnored private var lastActivity: Date?
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var loopID: UUID?
    /// The last loop's end, saving included; a new loop waits for it.
    @ObservationIgnored private var finishing: Task<Void, Never>?
    @ObservationIgnored private var sleeper: Task<Void, Never>?
    @ObservationIgnored private var wakeRequested = false
    /// The Chat views on screen; the conversation is followed while any is.
    @ObservationIgnored private var viewers: Set<UUID> = []
    @ObservationIgnored private var sends: [TrackedSend] = []
    /// Sends the input box was last seen holding, which stay `.returned`
    /// until the transcript records them or a later read of the box no
    /// longer finds them.
    @ObservationIgnored private var returnedSends: Set<UUID> = []
    /// Returned sends a later read of the box no longer found, which stay
    /// `.discarded` unless the transcript records them.
    @ObservationIgnored private var discardedSends: Set<UUID> = []
    /// Returned sends the box was seen holding among more text, which the
    /// user added in the terminal: a recorded prompt that contains one
    /// settles it, since what the user sent is that text and more.
    @ObservationIgnored private var extendedSends: Set<UUID> = []
    /// Sends already looked for in the input box since the Agent last
    /// turned idle: each idle spell reads the screen once for them.
    @ObservationIgnored private var returnChecked: Set<UUID> = []
    /// When herdr last reported the Agent idle, while it still is.
    @ObservationIgnored private var idleSince: Date?
    /// When herdr last reported a turn starting. Esc puts back only the
    /// steers queued in the turn it stops, so sends delivered before this
    /// are never looked for in the box.
    @ObservationIgnored private var turnStartedAt: Date?
    /// Recorded prompts already taken by a send in the current
    /// conversation: one recorded copy answers one send. Keyed by entry for
    /// a program whose entries outlive a rewrite of its file, otherwise by
    /// offset within one layout of the file.
    @ObservationIgnored private var claimedPrompts: Set<String> = []
    @ObservationIgnored private var claimedGeneration = 0
    @ObservationIgnored private var claimedLayout = 0
    @ObservationIgnored private var skillNames: Set<String> = []
    /// Rows expanded before the transcript was open, or while the Host was
    /// not connected, read once both are.
    @ObservationIgnored private var waitingOutputs: Set<ChatEntryID> = []
    /// What the Console last said of the Host's connection. A saved
    /// conversation keeps following offline, but its outputs cannot be read.
    @ObservationIgnored private var isHostConnected = true
    /// The latest read for each row, kept so tests can wait for them.
    @ObservationIgnored private var outputReads: [ChatEntryID: Task<Void, Never>] = [:]
    /// What each listed Workflow's journal showed, by the Workflow's id.
    @ObservationIgnored private var workflowProgress: [String: ChatWorkflowProgress] = [:]

    private struct TrackedSend {
        let id: UUID
        let key: String
        /// What herdr typed, looked for in the input box.
        let text: String
        /// The conversation it went into, how its file was laid out, and
        /// how far it had been read: while that layout holds, the program
        /// records the prompt at or after this offset.
        let generation: Int
        let layout: Int
        let floor: UInt64
        /// The entries showing when it was sent, none of which can record
        /// it, wherever a rewrite moves them.
        let knownEntries: Set<ChatEntryID>
        /// First seen already delivered, so its floor is unknown.
        let isOrphan: Bool
        var deliveredAt: Date?
    }

    /// Callers that only ever show one Chat for this Agent.
    static let soleViewer = UUID()

    init(
        agentID: ConsoleAgent.ID,
        agent: Agent,
        program: ChatProgram,
        source: AgentChatSource,
        timing: Timing = Timing(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.agentID = agentID
        self.agent = agent
        self.program = program
        self.source = source
        self.timing = timing
        self.now = now
        let resolution = ConversationReference.resolve(agent.agentSession)
        self.resolution = resolution
        conversation = ChatConversationSnapshot()
        blocked = BlockedCardStore(program: program, io: source.screen)
        blocked.update(activity: ChatAgentActivity(agent.status))
        switch ChatAgentActivity(agent.status) {
        case .idle: idleSince = now()
        case .working: turnStartedAt = now()
        default: break
        }
        followReference()
    }

    // MARK: View lifecycle

    /// A Chat view is on screen: follow the conversation. Each view passes
    /// its own token, so one window leaving does not stop another's.
    func show(_ viewer: UUID = AgentChatStore.soleViewer) {
        if viewers.isEmpty {
            // Background prefetches back off looking for a missing
            // transcript; opening Chat looks at once and backs off afresh.
            switch conversation.phase {
            case .locating, .unavailable(.notFound):
                nextOpen = nil
                failedOpens = 0
            default:
                break
            }
        }
        viewers.insert(viewer)
        isVisible = true
        needsAgentRefresh = true
        startLoop()
        blocked.show()
    }

    /// A Chat view left the screen. The last one out stops reading, saving
    /// what showed.
    func hide(_ viewer: UUID = AgentChatStore.soleViewer) {
        viewers.remove(viewer)
        guard viewers.isEmpty else { return }
        isVisible = false
        stopLoop()
        blocked.hide()
    }

    /// The app went to the background; Chat keeps its place.
    func suspend() {
        isSuspended = true
        stopLoop()
        blocked.suspend()
    }

    func resume() {
        isSuspended = false
        needsAgentRefresh = true
        startLoop()
        blocked.resume()
    }

    /// The Agent or its Host is gone.
    func end() {
        viewers.removeAll()
        isVisible = false
        stopLoop()
        blocked.end()
    }

    /// Warms the local document once after a fresh Host snapshot, without
    /// opening Chat or starting permanent polling. A view appearing during
    /// this read takes over the same serialized loop when it finishes.
    /// Returns whether an active visible reader handles the refresh, or this
    /// call completed its own pass without cancellation. Callers still check
    /// the snapshot for read failures. Busy hidden readers return false so
    /// reconnect can retry after a cancelled earlier pass finishes.
    @discardableResult
    func prefetch() async -> Bool {
        guard !isSuspended, !Task.isCancelled else { return false }
        if isVisible { return loop.map { !$0.isCancelled } ?? false }
        guard loop == nil else { return false }
        needsAgentRefresh = true
        let previous = finishing
        let id = UUID()
        loopID = id
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if !Task.isCancelled {
                await self.step()
                await self.engine?.save(force: true)
            }
            guard self.loopID == id else { return }
            self.loop = nil
            self.loopID = nil
            self.startLoop()
        }
        loop = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return !Task.isCancelled && !task.isCancelled
    }

    // MARK: Requests

    /// Preview reads use the same Host connection as the transcript.
    func readImage(at path: String) async throws -> Data {
        try await ChatImagePreviewReader.read(path: path, files: source.files)
    }

    /// Reads one page above the oldest message shown.
    func loadOlder() {
        guard conversation.older == .available || isFailedOlder,
            case .following = conversation.phase
        else { return }
        olderRequested = true
        conversation.older = .loading
        wake()
    }

    /// Reads a tool's output again for its expanded row, once the
    /// transcript is open and the Host connected. A read that failed is
    /// tried again. Reads run beside the loop: they change nothing it
    /// follows.
    func loadOutput(_ id: ChatEntryID) {
        guard case .tool(let tool)? = conversation.transcript.entries.last(where: { $0.id == id })?.content,
            let reference = tool.output, outputs.needsRead(id, at: reference)
        else { return }
        guard case .following = conversation.phase, isHostConnected, let engine else {
            waitingOutputs.insert(id)
            return
        }
        waitingOutputs.remove(id)
        outputs.begin(id, at: reference)
        let generation = conversationGeneration
        outputReads[id] = Task { [weak self] in
            let result = await engine.output(of: tool)
            guard let self, conversationGeneration == generation else { return }
            outputs.finish(id, at: reference, with: result)
        }
    }

    /// The Console's Host status changed. Rows expanded while it was not
    /// connected are read once it is.
    func hostConnectionChanged(_ isConnected: Bool) {
        guard isConnected != isHostConnected else { return }
        isHostConnected = isConnected
        guard isConnected else { return }
        let waiting = waitingOutputs
        for id in waiting {
            loadOutput(id)
        }
    }

    /// Resolves once every output read so far has finished, for tests.
    func outputReadsSettled() async {
        for read in outputReads.values {
            await read.value
        }
    }

    /// Looks for the transcript again now, after a failure or an
    /// unavailable state the user may have fixed.
    func retry() {
        needsAgentRefresh = true
        nextOpen = nil
        failedOpens = 0
        wake()
    }

    /// A prompt was just sent: the Agent is about to write, and may start a
    /// session Chat has not seen.
    func noteSent() {
        lastActivity = now()
        needsAgentRefresh = true
        nextOpen = nil
        failedOpens = 0
        wake()
    }

    /// The messages Chat's Composer holds, oldest first. Each one's place in
    /// the transcript is taken when it first appears, before it is sent, so
    /// only prompts recorded after that can match it.
    func updateSends(_ messages: [SentMessage]) {
        let ids = Set(messages.map(\.id))
        sends.removeAll { !ids.contains($0.id) }
        returnedSends.formIntersection(ids)
        discardedSends.formIntersection(ids)
        extendedSends.formIntersection(ids)
        returnChecked.formIntersection(ids)
        for message in messages {
            if let index = sends.firstIndex(where: { $0.id == message.id }) {
                guard message.isDelivered != (sends[index].deliveredAt != nil) else { continue }
                sends[index].deliveredAt = message.isDelivered ? now() : nil
                if message.isDelivered { noteSent() }
            } else {
                let transcript = conversation.transcript
                let knownEntries = Set(transcript.entries.map(\.id) + transcript.recordedPrompts.compactMap(\.entryID))
                sends.append(
                    TrackedSend(
                        id: message.id, key: source.adapter.echoKey(message.text), text: message.text,
                        generation: conversationGeneration, layout: conversation.layoutGeneration,
                        floor: conversation.readOffset, knownEntries: knownEntries,
                        isOrphan: message.isDelivered, deliveredAt: message.isDelivered ? now() : nil))
            }
        }
        matchSends()
    }

    /// The skills the Host offers, so a Codex `$name` prompt shows as the
    /// command it invoked.
    func skillsDidLoad(_ names: Set<String>) {
        guard names != skillNames else { return }
        skillNames = names
        wake()
    }

    /// The Console's latest record of the Agent, from a snapshot or a status
    /// change.
    func agentDidChange(_ next: Agent) {
        let statusChanged = next.status != agent.status
        let sessionChanged = next.agentSession != agent.agentSession
        let identityChanged = !sameIdentity(agent, next)
        let bindingReturned = isAwaitingSession && next.agentSession != nil
        let previous = ChatAgentActivity(agent.status)
        agent = next
        if sessionChanged || identityChanged || bindingReturned {
            sessionRecordRevision += 1
            adopt(ConversationReference.resolve(next.agentSession), replacingAgent: identityChanged)
            wake()
        }
        guard statusChanged else { return }
        let activity = ChatAgentActivity(next.status)
        blocked.update(activity: activity)
        idleSince = activity == .idle ? now() : nil
        // Answering a dialog resumes the turn it interrupted.
        if activity == .working, previous != .working, previous != .blocked { turnStartedAt = now() }
        returnChecked = []
        // A turn starting or ending is when a session changes (`/clear`,
        // `/resume`), when a missing transcript appears, and when a turn
        // after an undo writes to the thread's new file.
        lastActivity = now()
        needsAgentRefresh = true
        needsRelocate = true
        nextOpen = nil
        failedOpens = 0
        wake()
    }

    // MARK: Loop

    /// One turn of the loop: restores local entries before asking the Host,
    /// then makes at most one read of the transcript, and after a poll that
    /// worked, a few reads of Workflow journals. Internal for tests, which
    /// drive turns directly.
    func step() async {
        await restoreIfNeeded()
        guard !Task.isCancelled else { return }
        if needsAgentRefresh || sessionRecheckIsDue { await refreshAgent() }
        guard !Task.isCancelled else { return }
        // The query may select another session. Restore that session's own
        // document before waiting for its transcript, too.
        await restoreIfNeeded()
        guard !Task.isCancelled else { return }
        guard let engine, !isAwaitingSession else {
            matchSends()
            refreshBackgroundWork()
            return
        }
        let context = projectionContext
        let snapshot: ChatConversationSnapshot
        var polled = false
        if olderRequested {
            olderRequested = false
            snapshot = await engine.loadOlder(context: context)
        } else if case .following = conversation.phase {
            if needsRelocate {
                needsRelocate = false
                snapshot = await engine.relocate(context: context)
                // A search that failed is tried again on the next step.
                if snapshot.readFailure != nil, !Task.isCancelled, engine === self.engine { needsRelocate = true }
            } else {
                snapshot = await engine.poll(context: context)
            }
            polled = true
        } else if openIsDue {
            snapshot = await engine.open(directories: directories, context: context)
            if !Task.isCancelled, engine === self.engine { scheduleNextOpen(after: snapshot) }
        } else {
            snapshot = await engine.reproject(context: context)
        }
        guard !Task.isCancelled, engine === self.engine, !isAwaitingSession else { return }
        apply(snapshot, from: engine)
        matchSends()
        // Persist the transcript before optional journal requests can wait
        // on an unavailable connection.
        await engine.save()
        guard !Task.isCancelled, engine === self.engine, !isAwaitingSession else { return }
        await checkReturnedSends()
        guard !Task.isCancelled, engine === self.engine, !isAwaitingSession else { return }
        // A journal read adds a deadline of its own, so a round whose
        // transcript read failed leaves the journals for later.
        if polled, case .following = snapshot.phase, snapshot.readFailure == nil {
            let progress = await engine.followWorkflows()
            if engine === self.engine { workflowProgress = progress }
        }
        refreshBackgroundWork()
    }

    private func restoreIfNeeded() async {
        while engine == nil, resolution == .noSession {
            let recordRevision = sessionRecordRevision
            let session = await source.cachedSession(agent)
            guard !Task.isCancelled else { return }
            // Retry the local lookup if inventory replaced this Agent while
            // the directory was loading. Its cache must precede remote work.
            guard recordRevision == sessionRecordRevision else { continue }
            guard engine == nil, resolution == .noSession,
                case .bound(let reference) = ConversationReference.resolve(session), reference.program == program
            else { break }
            // Keep resolution unresolved: a saved binding permits local
            // display, never remote reads of an unconfirmed session.
            followReference(cachedReference: reference)
        }
        while !restored, let engine {
            let snapshot = await engine.restore()
            guard !Task.isCancelled else { return }
            // A Console update can switch sessions during a disk read.
            // Finish restoring the new identity before doing remote work.
            guard engine === self.engine else { continue }
            restored = true
            apply(snapshot, from: engine)
            matchSends()
            refreshBackgroundWork()
        }
    }

    private func startLoop() {
        guard isVisible, !isSuspended, loop == nil else { return }
        let previous = finishing
        loopID = UUID()
        loop = Task { [weak self] in
            await previous?.value
            while !Task.isCancelled {
                guard let self else { return }
                await self.step()
                guard !Task.isCancelled else { return }
                await self.pause(self.interval)
            }
        }
    }

    private func stopLoop() {
        guard let loop else { return }
        loop.cancel()
        sleeper?.cancel()
        self.loop = nil
        loopID = nil
        let engine = engine
        finishing = Task {
            await loop.value
            await engine?.save(force: true)
        }
    }

    private func pause(_ duration: Duration) async {
        if wakeRequested {
            wakeRequested = false
            return
        }
        let sleeper = Task<Void, Never> { try? await Task.sleep(for: duration) }
        self.sleeper = sleeper
        await sleeper.value
        self.sleeper = nil
        wakeRequested = false
    }

    private func wake() {
        if let sleeper {
            sleeper.cancel()
        } else {
            wakeRequested = true
        }
    }

    /// The pause after each turn. Internal for tests.
    var interval: Duration {
        if engine == nil { return .seconds(timing.sessionRecheck) }
        if [.working, .blocked].contains(agent.status) { return timing.activeInterval }
        if let lastActivity, now().timeIntervalSince(lastActivity) < timing.activeLinger {
            return timing.activeInterval
        }
        // herdr can report the Agent idle while its program still runs
        // work in the background.
        if backgroundWork.holdsActivePace { return timing.activeInterval }
        return timing.idleInterval
    }

    // MARK: Session

    private var sessionRecheckIsDue: Bool {
        guard engine == nil || isUnavailable || agentRefreshFailure != nil else { return false }
        guard let lastAgentRefresh else { return true }
        return now().timeIntervalSince(lastAgentRefresh) >= timing.sessionRecheck
    }

    private func refreshAgent() async {
        needsAgentRefresh = false
        lastAgentRefresh = now()
        let recordRevision = sessionRecordRevision
        // The Console's record keeps whatever its last snapshot said; herdr's
        // answer here is newer, and only a later change to that record
        // overrides it.
        do {
            let fresh = try await source.agentInfo()
            guard !Task.isCancelled, recordRevision == sessionRecordRevision else { return }
            agentRefreshFailure = nil
            updateReadFailure()
            let identityChanged = !sameIdentity(agent, fresh)
            if identityChanged {
                agent = fresh
                blocked.update(activity: ChatAgentActivity(fresh.status))
            }
            adopt(ConversationReference.resolve(fresh.agentSession), replacingAgent: identityChanged)
        } catch {
            guard !Task.isCancelled, recordRevision == sessionRecordRevision,
                !(error is CancellationError), error as? TransportError != .cancelled
            else { return }
            agentRefreshFailure = error as? TransportError
                ?? .channelFailed(detail: String(describing: type(of: error)))
            updateReadFailure()
        }
    }

    private func sameIdentity(_ lhs: Agent, _ rhs: Agent) -> Bool {
        lhs.terminalID == rhs.terminalID && lhs.workspaceID == rhs.workspaceID
            && lhs.tabID == rhs.tabID && lhs.kind == rhs.kind && lhs.paneID == rhs.paneID
    }

    /// An unreported binding does not prove that this Agent changed its
    /// conversation. Keep its last document readable, but stop remote reads
    /// until the Host supplies an explicit binding again.
    private var isAwaitingSession: Bool {
        resolution == .noSession && followed != nil
    }

    private func adopt(_ next: ConversationReference.Resolution, replacingAgent: Bool = false) {
        guard next != resolution || replacingAgent else { return }
        resolution = next
        if !replacingAgent, isAwaitingSession {
            conversation.phase = .unavailable(.noSession(program))
            conversation.isFromCache = !conversation.transcript.entries.isEmpty
            if conversation.older == .loading { conversation.older = .available }
            olderRequested = false
            appliedRevision = nil
            refreshBackgroundWork()
            return
        }
        continuedSession = nil
        followReference(force: replacingAgent)
    }

    /// Points the engine at the conversation to follow, starting a new one
    /// when it changed.
    private func followReference(force: Bool = false, cachedReference: ConversationReference? = nil) {
        var target = cachedReference
        if case .bound(let reference) = resolution, reference.program == program {
            target = continuedSession ?? reference
        }
        guard target != followed || force else {
            if target == nil {
                showUnavailable()
            } else if case .unavailable(.noSession) = conversation.phase {
                // Resume the same timeline rather than changing its identity
                // or clearing the entries while the Host is being read.
                conversation.phase = .locating
                appliedRevision = nil
                nextOpen = nil
                failedOpens = 0
            }
            return
        }
        if let engine { Task { await engine.save(force: true) } }
        followed = target
        transcriptReadFailure = nil
        conversationGeneration += 1
        engine = target.map(makeEngine)
        restored = false
        appliedRevision = nil
        olderRequested = false
        needsRelocate = false
        nextOpen = nil
        failedOpens = 0
        // Reads still running for the last conversation drop their results.
        outputs = ChatToolOutputs()
        waitingOutputs = []
        workflowProgress = [:]
        backgroundWork = ChatBackgroundWork()
        hasReadLive = false
        if target == nil {
            showUnavailable()
        } else {
            conversation = ChatConversationSnapshot()
            if isAwaitingSession { conversation.phase = .unavailable(.noSession(program)) }
            updateReadFailure()
        }
    }

    private func showUnavailable() {
        let reason: ChatUnavailableReason =
            switch resolution {
            case .noSession: .noSession(program)
            case .unidentified: .unidentifiedSession
            case .unsupported, .bound: .unsupportedSession
            }
        var next = ChatConversationSnapshot()
        next.phase = .unavailable(reason)
        next.readFailure = agentRefreshFailure
        if conversation != next { conversation = next }
    }

    private func makeEngine(_ reference: ConversationReference) -> ChatConversationEngine {
        ChatConversationEngine(
            reference: reference,
            cacheKey: ChatCacheKey(
                hostID: source.hostID, socketLocation: source.socketLocation, reference: reference),
            files: source.files, cache: source.cache, adapter: source.adapter, now: now)
    }

    // MARK: Snapshots

    private func apply(_ snapshot: ChatConversationSnapshot, from origin: ChatConversationEngine) {
        // A session switch may have replaced the engine during the read.
        guard origin === engine, snapshot.revision != appliedRevision,
            !isAwaitingSession || snapshot.isFromCache
        else { return }
        if snapshot.transcript.entries != conversation.transcript.entries { lastActivity = now() }
        appliedRevision = snapshot.revision
        transcriptReadFailure = snapshot.readFailure
        var next = snapshot
        next.readFailure = transcriptReadFailure ?? agentRefreshFailure
        if isAwaitingSession { next.phase = .unavailable(.noSession(program)) }
        if olderRequested, next.older == .available { next.older = .loading }
        conversation = next
        blocked.update(transcript: next.transcript)
        if case .following = next.phase, !waitingOutputs.isEmpty {
            let waiting = waitingOutputs
            waitingOutputs = []
            for id in waiting {
                loadOutput(id)
            }
        }
        if let linked = snapshot.transcript.links.continuedInSessionID
            .flatMap(ConversationReference.canonicalUUID),
            linked != followed?.sessionID
        {
            continuedSession = ConversationReference(program: program, sessionID: linked)
            followReference()
        }
    }

    private func updateReadFailure() {
        conversation.readFailure = transcriptReadFailure ?? agentRefreshFailure
    }

    private var isUnavailable: Bool {
        if case .unavailable = conversation.phase { return true }
        return false
    }

    private func refreshBackgroundWork() {
        var isLive = conversation.readFailure == nil && !conversation.isFromCache
        if case .following = conversation.phase {} else { isLive = false }
        if isLive { hasReadLive = true }
        let next =
            hasReadLive
            ? ChatBackgroundWork(
                transcript: conversation.transcript, progress: workflowProgress, isLive: isLive, now: now(),
                staleness: timing.backgroundWorkStaleness)
            : ChatBackgroundWork()
        if next != backgroundWork { backgroundWork = next }
    }

    private var isFailedOlder: Bool {
        if case .failed = conversation.older { return true }
        return false
    }

    private var openIsDue: Bool {
        nextOpen.map { now() >= $0 } ?? true
    }

    private func scheduleNextOpen(after snapshot: ChatConversationSnapshot) {
        switch snapshot.phase {
        case .following, .unavailable(.awaitingFirstMessage):
            // A new conversation's file comes with the first reply, during
            // a turn that keeps the active pace: look on every pass.
            nextOpen = nil
            failedOpens = 0
            return
        default:
            break
        }
        let delays = timing.locateBackoff
        let delay = delays.isEmpty ? 0 : delays[min(failedOpens, delays.count - 1)]
        failedOpens += 1
        nextOpen = now().addingTimeInterval(delay)
        // Not found may mean the session moved on: ask herdr again first.
        needsAgentRefresh = true
    }

    private var directories: [String] {
        var directories: [String] = []
        for directory in [agent.foregroundCwd, agent.cwd].compactMap(\.self)
        where !directory.isEmpty && !directories.contains(directory) {
            directories.append(directory)
        }
        return directories
    }

    private var projectionContext: ChatProjectionContext {
        ChatProjectionContext(activity: ChatAgentActivity(agent.status), skillNames: skillNames)
    }

    // MARK: Sent prompts

    /// Matches sends to the prompts the transcript recorded: first in,
    /// first out, one to one, equal keys, and only prompts recorded after
    /// the send. A send that went into an earlier conversation, such as the
    /// first prompt that makes Codex report a session, may match anywhere in
    /// the current one, as may one sent before the file was rewritten; an
    /// entry already showing at the send never matches it. A discarded send
    /// takes only a prompt no other send matches, so sending its text again
    /// settles the new send; a returned send the user added to in the box
    /// takes a prompt that contains it. Conservative on purpose: a wrong match would
    /// hide a prompt that never arrived.
    private func matchSends() {
        let byEntry = source.adapter.echoesByEntry
        let layout = conversation.layoutGeneration
        if claimedGeneration != conversationGeneration || (!byEntry && claimedLayout != layout) {
            claimedGeneration = conversationGeneration
            claimedLayout = layout
            claimedPrompts = []
        }
        struct Candidate {
            let claim: String
            let offset: UInt64
            let entryID: ChatEntryID?
        }
        func candidate(offset: UInt64, entryID: ChatEntryID?) -> Candidate? {
            guard byEntry else { return Candidate(claim: "@\(offset)", offset: offset, entryID: entryID) }
            return entryID.map { Candidate(claim: $0.rawValue, offset: offset, entryID: $0) }
        }
        let transcript = conversation.transcript
        let recorded = transcript.recordedPrompts.compactMap { prompt in
            candidate(offset: prompt.offset, entryID: prompt.entryID).map {
                (
                    candidate: $0, key: source.adapter.echoKey(prompt.text), text: String(Self.squeezed(prompt.text)),
                    imagePaths: prompt.pastedImagePaths
                )
            }
        }
        // Codex records no prompt for `/compact`, only the compaction.
        let compactions = transcript.entries.compactMap { entry -> Candidate? in
            guard case .divider(let divider) = entry.content, divider.kind == .compaction else { return nil }
            return candidate(offset: entry.sourceOffset, entryID: entry.id)
        }
        let date = now()
        // A new conversation records nothing until the program writes its
        // file, however long the first reply takes.
        var isUnwritten = false
        if case .unavailable(.awaitingFirstMessage) = conversation.phase { isUnwritten = true }
        var statuses: [UUID: SendStatus] = [:]
        var becameOverdue = false
        let ordered = sends.filter { !discardedSends.contains($0.id) } + sends.filter { discardedSends.contains($0.id) }
        for send in ordered {
            if sendStatuses[send.id] == .recorded {
                statuses[send.id] = .recorded
                continue
            }
            guard let deliveredAt = send.deliveredAt else {
                statuses[send.id] = .awaiting
                continue
            }
            if send.isOrphan {
                statuses[send.id] = .abandoned
                continue
            }
            let isSameConversation = send.generation == conversationGeneration
            let floor = isSameConversation && send.layout == layout ? send.floor : 0
            func isOpen(_ candidate: Candidate) -> Bool {
                guard candidate.offset >= floor, !claimedPrompts.contains(candidate.claim) else { return false }
                guard isSameConversation, let entryID = candidate.entryID else { return true }
                return !send.knownEntries.contains(entryID)
            }
            var match = recorded.first { $0.key == send.key && isOpen($0.candidate) }?.candidate
            if match == nil, send.key == "/compact" {
                match = compactions.first(where: isOpen)
            }
            // A path pasted alone becomes `[Image #N]` plus the image, which
            // may name the path only as the program read it, or not at all.
            if match == nil, let path = ChatRecordedPrompt.pastedPath(in: send.text) {
                match = recorded.first { prompt in
                    guard let paths = prompt.imagePaths, isOpen(prompt.candidate) else { return false }
                    return paths.isEmpty || paths.contains(path)
                }?.candidate
            }
            if match == nil, extendedSends.contains(send.id) {
                let text = String(Self.squeezed(send.text))
                match = recorded.first { !text.isEmpty && $0.text.contains(text) && isOpen($0.candidate) }?.candidate
            }
            if let match {
                claimedPrompts.insert(match.claim)
                statuses[send.id] = .recorded
            } else if returnedSends.contains(send.id), send.generation == conversationGeneration {
                statuses[send.id] = .returned
            } else if discardedSends.contains(send.id), send.generation == conversationGeneration {
                statuses[send.id] = .discarded
            } else if returnedSends.contains(send.id) || discardedSends.contains(send.id) {
                // Put back or cleared in an earlier conversation: the new
                // one, still unwritten, is not waiting for it.
                statuses[send.id] = .abandoned
            } else if isUnwritten || date.timeIntervalSince(deliveredAt) < timing.echoTimeout {
                statuses[send.id] = .awaiting
            } else if send.generation == conversationGeneration {
                statuses[send.id] = .overdue
                becameOverdue = becameOverdue || sendStatuses[send.id] != .overdue
            } else {
                statuses[send.id] = .abandoned
            }
        }
        if statuses != sendStatuses { sendStatuses = statuses }
        // The program may have forked into a session herdr has not
        // reported through the snapshot yet.
        if becameOverdue {
            needsAgentRefresh = true
            needsRelocate = true
            wake()
        }
    }

    /// Esc in Pi or Oh My Pi puts the steers its turn had not taken back
    /// into the input box, and the transcript never records them. Once the
    /// Agent has been idle a moment, the screen is read once for the sends
    /// from the turn that just ended that are still unrecorded, overdue or
    /// not (a Stop right after a steer ends the turn inside the echo
    /// timeout, and the user may add to the box before it runs out), and
    /// for the sends already found there, which the user may have sent or
    /// cleared in the terminal since. Only Pi's and Oh My Pi's Esc is known
    /// to hand steers back.
    private func checkReturnedSends() async {
        guard program == .pi || program == .omp, let idleSince,
            now().timeIntervalSince(idleSince) >= timing.returnCheckDelay
        else { return }
        let candidates = sends.filter { send in
            guard !returnChecked.contains(send.id) else { return false }
            switch sendStatuses[send.id] {
            case .returned:
                return true
            case .overdue:
                guard let deliveredAt = send.deliveredAt, let turnStartedAt else { return false }
                return deliveredAt >= turnStartedAt
            case .awaiting:
                // A send still in time is read early only when it went in
                // while the turn ran; one made since is the next turn's.
                guard let deliveredAt = send.deliveredAt, let turnStartedAt else { return false }
                return deliveredAt >= turnStartedAt && deliveredAt <= idleSince
            default:
                return false
            }
        }
        guard !candidates.isEmpty else { return }
        let ids = Set(candidates.map(\.id))
        returnChecked.formUnion(ids)
        guard let screen = try? await source.screen.readScreen(), !Task.isCancelled,
            self.idleSince == idleSince
        else { return }
        observeInputBox(InputBoxStateDetector.detect(screen, program: program), for: ids)
    }

    /// A read of the Agent's screen made for another reason, such as the
    /// check before a send: a returned send it no longer finds in the input
    /// box is discarded. It never finds new ones.
    func inputBoxWasRead(_ screen: ANSIScreen) {
        guard program == .pi || program == .omp, !returnedSends.isEmpty else { return }
        observeInputBox(InputBoxStateDetector.detect(screen, program: program), for: returnedSends)
    }

    /// Settles which of `ids` the input box holds. Only an empty box or
    /// one showing text says so; any other state leaves them as they were.
    /// A returned send the box no longer holds left it undelivered, but
    /// text that shows one of them among more, such as one the user added
    /// to in the terminal, says nothing about which left.
    private func observeInputBox(_ state: InputBoxState, for ids: Set<UUID>) {
        let box: String
        switch state {
        case .text(let draft): box = draft
        case .empty: box = ""
        default: return
        }
        let held = Self.sends(in: box, among: sends.filter { ids.contains($0.id) })
        let returned = sends.filter { ids.contains($0.id) && returnedSends.contains($0.id) }
        let mentioned = Self.mentioned(in: box, among: returned)
        if held.isEmpty, !mentioned.isEmpty {
            extendedSends.formUnion(mentioned)
            return
        }
        let left = returnedSends.intersection(ids).subtracting(held)
        let next = returnedSends.subtracting(ids).union(held)
        guard next != returnedSends else { return }
        returnedSends = next
        discardedSends.formUnion(left)
        matchSends()
    }

    /// The sends, oldest first, whose texts make up all of `box`. Pi
    /// returns every queued steer at once, joined by blank lines in the
    /// order they were sent; the editor also wraps and trims what it shows,
    /// so spacing says nothing. Text the box holds beyond them, such as a
    /// draft, means none of them can be told apart from it.
    private static func sends(in box: String, among sends: [TrackedSend]) -> Set<UUID> {
        let target = squeezed(box)
        let texts = sends.map { squeezed($0.text) }
        guard !target.isEmpty else { return [] }
        var dead: Set<Int> = []
        // Indices of the sends that spell `target` from `start` on, using
        // only sends from `first` on.
        func spell(from start: Int, first: Int) -> [Int]? {
            if start == target.count { return [] }
            let key = start * (texts.count + 1) + first
            guard !dead.contains(key) else { return nil }
            for index in first..<texts.count where !texts[index].isEmpty {
                let end = start + texts[index].count
                guard end <= target.count, target[start..<end].elementsEqual(texts[index]),
                    let rest = spell(from: end, first: index + 1)
                else { continue }
                return [index] + rest
            }
            dead.insert(key)
            return nil
        }
        guard let indices = spell(from: 0, first: 0) else { return [] }
        return Set(indices.map { sends[$0].id })
    }

    /// Those of `sends` that show anywhere in `box`, spacing aside.
    private static func mentioned(in box: String, among sends: [TrackedSend]) -> Set<UUID> {
        let target = String(squeezed(box))
        return Set(
            sends.filter { send in
                let text = String(squeezed(send.text))
                return !text.isEmpty && target.contains(text)
            }.map(\.id))
    }

    /// `text` without its whitespace, which the editor's wrapping changes.
    private static func squeezed(_ text: String) -> [Character] { Array(text.filter { !$0.isWhitespace }) }
}

extension ChatAgentActivity {
    /// What herdr's Agent Status says about the Agent's turn.
    init(_ status: AgentStatus?) {
        guard let status else {
            self = .unknown
            return
        }
        switch status {
        case .idle, .done: self = .idle
        case .working: self = .working
        case .blocked: self = .blocked
        default: self = .unknown
        }
    }
}
