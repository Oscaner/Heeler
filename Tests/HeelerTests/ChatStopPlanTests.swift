import Foundation
import Testing

@testable import Heeler

/// Chat's Stop in each program: the keys it presses in one request, the
/// guard that may read the screen first, and the wait and hint it hands
/// the Composer.
@MainActor
@Suite("Chat Stop plan")
struct ChatStopPlanTests {
    @Test(arguments: [ChatProgram.claude, .codex, .pi, .omp])
    func claudeCodexPiAndOhMyPiPressOneEscAndWaitThreeSeconds(program: ChatProgram) {
        let plan = ChatStopPlan.standard(for: program)

        #expect(plan.keys == ["esc"])
        #expect(plan.screenGuard == nil)
        #expect(plan.wait == AgentStopWait.escape)
        #expect(plan.wait.window == .seconds(3))
        #expect(plan.wait.unconfirmedNotice == "Esc went, but the Agent still shows Working.")
        #expect(plan.wait.minimumGap == .zero)
        #expect(plan.accessibilityHint == "Presses Esc to interrupt the Agent")
    }

    @Test(arguments: ChatProgram.allCases)
    func everyPlanSendsKeysHerdrAccepts(program: ChatProgram) {
        let keys = ChatStopPlan.standard(for: program).keys

        #expect(!keys.isEmpty)
        for key in keys {
            #expect(HerdrKeyGrammar.accepts(key), "\(program) presses \(key)")
        }
    }

    /// Grok Build's guard reads the screen inside the keys queue; then one
    /// Ctrl+C goes, or nothing does and Stop says why.
    @Test func grokPressesOneCtrlCAfterItsGuard() async throws {
        let recorder = StopRecorder()
        let agentKeys = Self.agentKeys(recorder)
        let plan = ChatStopPlan.standard(for: .grok)
        let working = plan.composerInterrupt(
            context: Self.context(recorder, screen: try ScreenFixture.screen("grok-03-working")),
            agentKeys: agentKeys)
        let drafting = plan.composerInterrupt(
            context: Self.context(recorder, screen: try ScreenFixture.screen("grok-04-working-draft")),
            agentKeys: agentKeys)

        let pressed = await working.perform()
        #expect(pressed == .sent)
        #expect(recorder.events == ["read", "ctrl+c"])

        let refused = await drafting.perform()
        let reason = "Grok Build's input box has text, and Ctrl+C would only clear it. Stop it in the terminal."
        #expect(refused == .failed(reason))
        #expect(recorder.contextCalls == 2)
        #expect(recorder.sent == [["ctrl+c"]], "a refused Stop presses nothing")
    }

    @Test func theGrokPlanWaitsThreeSecondsAndKeepsPressesApart() {
        let plan = ChatStopPlan.standard(for: .grok)

        #expect(plan.keys == ["ctrl+c"])
        #expect(plan.wait.window == .seconds(3))
        #expect(plan.wait.minimumGap == .milliseconds(1500))
        #expect(
            plan.wait.unconfirmedNotice
                == "Ctrl+C went, but the Agent still shows Working. A queued message may have started.")
        #expect(plan.accessibilityHint == "Presses Ctrl+C to cancel the turn")
    }

    @Test func anUnguardedPlanSendsEveryKeyInOneRequestWithoutReading() async {
        let recorder = StopRecorder()
        let plan = ChatStopPlan(keys: ["esc", "esc"], wait: .escape, accessibilityHint: "Presses Esc twice")
        let interrupt = plan.composerInterrupt(context: Self.context(recorder), agentKeys: Self.agentKeys(recorder))

        let outcome = await interrupt.perform()

        #expect(outcome == .sent)
        #expect(recorder.sent == [["esc", "esc"]])
        #expect(recorder.contextCalls == 0, "a plan without a guard never reads the screen")
    }

    @Test func aGuardSeesTheScreenAndStatusAndMayRefuse() async throws {
        let recorder = StopRecorder()
        let seen = SeenContexts()
        let plan = Self.guarded { context in
            seen.contexts.append(context)
            return .refuse("Not now.")
        }
        let screen = ScreenFixture.synthetic(["a dialog row"])
        let interrupt = plan.composerInterrupt(
            context: Self.context(recorder, screen: screen, activity: .blocked), agentKeys: Self.agentKeys(recorder))

        let outcome = await interrupt.perform()

        #expect(outcome == .failed("Not now."))
        #expect(recorder.contextCalls == 1)
        #expect(recorder.sent.isEmpty, "a refused Stop presses nothing")
        let context = try #require(seen.contexts.first)
        #expect(seen.contexts.count == 1)
        #expect(context.activity == .blocked)
        #expect(context.screen.rows == screen.rows)
    }

    @Test func aGuardThatAllowsSendsTheKeys() async {
        let recorder = StopRecorder()
        let plan = Self.guarded(keys: ["esc", "esc"]) { _ in .press }
        let interrupt = plan.composerInterrupt(context: Self.context(recorder), agentKeys: Self.agentKeys(recorder))

        let outcome = await interrupt.perform()

        #expect(outcome == .sent)
        #expect(recorder.contextCalls == 1)
        #expect(recorder.sent == [["esc", "esc"]])
    }

    @Test func anUnreadableScreenSendsNothing() async {
        let recorder = StopRecorder()
        let seen = SeenContexts()
        let plan = Self.guarded { context in
            seen.contexts.append(context)
            return .press
        }
        let interrupt = plan.composerInterrupt(
            context: Self.context(recorder, readFails: true), agentKeys: Self.agentKeys(recorder))

        let outcome = await interrupt.perform()

        #expect(outcome == .failed("Heeler couldn't check the Agent's screen, so Stop pressed nothing."))
        #expect(recorder.sent.isEmpty)
        #expect(seen.contexts.isEmpty, "a guard decides only on a screen it saw")
    }

    @Test func aFailedRequestSaysTheAgentMayStillBeWorking() async {
        let recorder = StopRecorder()
        let interrupt = ChatStopPlan.escape.composerInterrupt(
            context: Self.context(recorder), agentKeys: Self.agentKeys(recorder, requestsFail: true))

        let outcome = await interrupt.perform()

        #expect(outcome == .failed("Couldn't reach the Agent, so it may still be working."))
    }

    /// Up recalls history into the input box, so a guard must see the
    /// screen once the keys pressed before Stop have gone.
    @Test func aGuardReadsOnlyAfterKeysAlreadyQueued() async {
        let gate = ScriptedTransportCallGate()
        let recorder = StopRecorder()
        let agentKeys = Self.agentKeys(recorder, firstRequestWaitsOn: gate)
        let interrupt = Self.guarded { _ in .press }
            .composerInterrupt(context: Self.context(recorder), agentKeys: agentKeys)

        agentKeys.press(.up)
        let stop = Task { await interrupt.perform() }
        await gate.waitForEntry()
        for _ in 0..<20 { await Task.yield() }
        #expect(recorder.contextCalls == 0, "the guard waits for the key pressed before Stop")

        await gate.open()
        let outcome = await stop.value
        #expect(outcome == .sent)
        #expect(recorder.events == ["up", "read", "esc"])
    }

    @Test func theComposerInterruptCarriesThePlan() async {
        let recorder = StopRecorder()
        let agentKeys = Self.agentKeys(recorder)
        let plan = ChatStopPlan(
            keys: ["esc"],
            wait: AgentStopWait(
                window: .seconds(5), unconfirmedNotice: "Keys went, but the Agent still shows Working.",
                minimumGap: .milliseconds(1500)),
            accessibilityHint: "Presses the program's Stop keys")
        let carried = plan.composerInterrupt(context: Self.context(recorder), agentKeys: agentKeys)
        #expect(carried.wait == plan.wait)
        #expect(carried.accessibilityHint == plan.accessibilityHint)

        let escape = ChatStopPlan.escape.composerInterrupt(context: Self.context(recorder), agentKeys: agentKeys)
        #expect(escape.wait == ChatStopPlan.escape.wait)
        #expect(escape.accessibilityHint == ChatStopPlan.escape.accessibilityHint)
        let outcome = await escape.perform()
        #expect(outcome == .sent)
        #expect(recorder.sent == [["esc"]])
        #expect(recorder.contextCalls == 0)
    }

    // MARK: Helpers

    /// A real keys store over `recorder`. The first request waits on
    /// `gate` when one is given; with `requestsFail`, every request throws.
    private static func agentKeys(
        _ recorder: StopRecorder, firstRequestWaitsOn gate: ScriptedTransportCallGate? = nil,
        requestsFail: Bool = false
    ) -> ChatAgentKeysStore {
        ChatAgentKeysStore { keys in
            recorder.calls += 1
            if recorder.calls == 1, let gate { await gate.waitUntilOpen() }
            if requestsFail { throw TransportError.cancelled }
            recorder.sent.append(keys)
            recorder.events.append(keys.joined(separator: " "))
        }
    }

    /// A Stop context that counts its reads: `screen` with the Agent's
    /// `activity` (by default a probe row while it works), or a failed read.
    private static func context(
        _ recorder: StopRecorder, screen: ANSIScreen = ScreenFixture.synthetic(["probe row"]),
        activity: ChatAgentActivity = .working, readFails: Bool = false
    ) -> @MainActor () async throws -> ChatStopContext {
        {
            recorder.contextCalls += 1
            recorder.events.append("read")
            if readFails { throw TransportError.timedOut }
            return ChatStopContext(screen: screen, activity: activity)
        }
    }

    /// A synthetic plan whose guard decides.
    private static func guarded(
        keys: [String] = ["esc"], _ screenGuard: @escaping @Sendable (ChatStopContext) -> ChatStopVerdict
    ) -> ChatStopPlan {
        ChatStopPlan(
            keys: keys, screenGuard: screenGuard, wait: .escape,
            accessibilityHint: AgentComposerInterrupt.escapeHint)
    }
}

/// What Chat's keys sent and how often a Stop context was read; `events`
/// keeps both in the order they happened.
@MainActor
private final class StopRecorder {
    var calls = 0
    var sent: [[String]] = []
    var contextCalls = 0
    var events: [String] = []
}

/// The contexts a guard was shown. Guards run inside the keys queue's
/// check, on the main actor.
private final class SeenContexts: @unchecked Sendable {
    var contexts: [ChatStopContext] = []
}
