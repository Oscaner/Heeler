import Foundation
import Testing

@testable import Heeler

/// The Blocked card against captured screens: what it shows, the keys it
/// sends and when, and how it knows they worked.
@MainActor
@Suite("Blocked card store", .timeLimit(.minutes(1)))
struct BlockedCardStoreTests {
    @Test func aBlockedAgentsDialogShowsAsACardWithItsRequest() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        let store = Self.store(.claude, pane: pane)
        store.update(transcript: Self.transcript(pending: [Self.bash("toolu_old", "rm -rf build"), Self.bash("toolu_1", "touch c1.txt")]))
        store.update(activity: .blocked)

        await store.refresh()

        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        #expect(card.dialog.kind == .claudeBash)
        #expect(card.request?.callID == "toolu_1")
        #expect(store.progress == .ready)
    }

    @Test func anOptionWaitsOutTheGraceThenSendsItsDigitOnce() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        await pane.react(to: ["1"], with: try ScreenFixture.screen("claude-29-c3-after-immediate"))
        let clock = ManualClock()
        let store = Self.store(.claude, pane: pane, clock: clock)
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys == [["1"]])
        #expect(clock.sleeps.first == .milliseconds(150))
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
        store.update(activity: .working)
        #expect(store.content == .none)
    }

    @Test func aDialogThatChangedBeforeTheTapGetsNoKeys() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-30-par-first"))
        let store = Self.store(.claude, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()
        await pane.show(try ScreenFixture.screen("claude-31-par-second"))

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys.isEmpty)
        #expect(store.notice == "This prompt changed. Check it before answering.")
        guard case .card(let card) = store.content else {
            Issue.record("Expected the new dialog's card, got \(store.content)")
            return
        }
        #expect(card.dialog.subject.command == "touch par-b.txt")
    }

    @Test func aStepTheDialogIgnoresStopsTheKeysAndFallsBackToTheGenericCard() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        let store = Self.store(.claude, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.amend(ordinal: 4, note: "Skip it"))

        // The first arrow never moved focus, so nothing follows it.
        #expect(await pane.keys == [["down"]])
        #expect(await pane.pastes.isEmpty)
        guard case .generic(let excerpt) = store.content else {
            Issue.record("Expected the generic card, got \(store.content)")
            return
        }
        #expect(excerpt.numbered.count == 4)
        #expect(excerpt.numbered[4] == "No")
        #expect(store.notice?.hasPrefix("The dialog didn't respond") == true)

        // The generic card's buttons still answer it, by digit.
        await pane.react(to: ["4"], with: try ScreenFixture.screen("claude-29-c3-after-immediate"))
        await store.press(number: 4)
        #expect(await pane.keys == [["down"], ["4"]])
        #expect(store.progress == .ready)
    }

    @Test func noEffectKeepsTheAnswersOffWhileTheDialogStaysAndNeverResends() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        let store = Self.store(.claude, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys == [["1"]])
        #expect(store.progress == .unconfirmed)
        #expect(store.notice == "The Agent hasn't responded yet. Answer in the terminal if it stays.")
        #expect(store.canStop)

        // The same dialog: the key may still land, so a tap sends nothing.
        await store.refresh()
        #expect(store.progress == .unconfirmed)
        await store.perform(.choose(ordinal: 1))
        #expect(await pane.keys == [["1"]])

        // Another screen brings the answers back.
        await pane.show(try ScreenFixture.screen("claude-31-par-second"))
        await store.refresh()
        #expect(store.progress == .ready)
    }

    /// The next dialog can be identical (two `ls` approvals in a row): a
    /// call that waited resolving brings the answers back, one that only
    /// starts waiting does not.
    @Test func anUnconfirmedAnswerIsReleasedOnceAWaitingCallResolves() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        let store = Self.store(.claude, pane: pane)
        // A request the dialog doesn't match, as a subagent's dialog has.
        let waiting = Self.bash("toolu_x", "echo other")
        store.update(transcript: Self.transcript(pending: [waiting]))
        store.update(activity: .blocked)
        await store.refresh()
        await store.perform(.choose(ordinal: 1))
        #expect(store.progress == .unconfirmed)

        store.update(transcript: Self.transcript(pending: [waiting, Self.bash("toolu_y", "echo next")]))
        #expect(store.progress == .unconfirmed)
        store.update(transcript: Self.transcript(resolved: [waiting]))
        #expect(store.progress == .ready)
        await store.refresh()
        #expect(store.progress == .ready)
    }

    @Test func stopStillGoesAfterAnAnswerShowedNoEffect() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        let store = Self.store(.claude, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()
        await store.perform(.choose(ordinal: 1))
        #expect(store.progress == .unconfirmed)
        await pane.react(to: ["esc"], with: try ScreenFixture.screen("claude-29-c3-after-immediate"))

        await store.perform(.dismiss)

        #expect(await pane.keys == [["1"], ["esc"]])
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
    }

    @Test func aClaudeCardConfirmsByItsCallsResult() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        let request = Self.bash("toolu_1", "touch c1.txt")
        let box = StoreBox()
        let store = BlockedCardStore(
            program: .claude,
            io: BlockedScreenIO(
                readScreen: { await pane.read() },
                sendKeys: { keys in
                    await pane.send(keys)
                    // The program records the result; the dialog still shows.
                    await MainActor.run {
                        box.store?.update(transcript: Self.transcript(resolved: [request]))
                    }
                },
                paste: { await pane.paste($0) }),
            clock: ManualClock().clock)
        box.store = store
        store.update(transcript: Self.transcript(pending: [request]))
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys == [["1"]])
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
    }

    @Test func aCodexDeclineHandsTheTurnToTheComposer() async throws {
        let pane = FakePane(try ScreenFixture.screen("codex-01-x1-exec"))
        await pane.react(to: ["3"], with: try ScreenFixture.screen("codex-00-ready"))
        let store = Self.store(.codex, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.choose(ordinal: 3))

        #expect(await pane.keys == [["3"]])
        #expect(store.composerFocusRequest == 1)
        #expect(store.progress == .ready)
    }

    @Test func answersTheTranscriptCantShowAreKeptOnceTheyTakeEffect() async throws {
        let request = Self.bash("toolu_1", "touch c1.txt")
        for (action, keys, expected) in [
            (DialogAction.choose(ordinal: 1), ["1"], ChatToolActivity.CardAnswer?.some(.allowed)),
            (.dismiss, ["esc"], .stopped),
            // The transcript records a decline itself.
            (.choose(ordinal: 4), ["4"], nil),
        ] {
            let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
            await pane.react(to: keys, with: try ScreenFixture.screen("claude-29-c3-after-immediate"))
            let store = Self.store(.claude, pane: pane)
            store.update(transcript: Self.transcript(pending: [request]))
            store.update(activity: .blocked)
            await store.refresh()

            await store.perform(action)

            #expect(await pane.keys == [keys])
            #expect(store.history.calls["toolu_1"] == expected, "\(action)")
        }
    }

    @Test func aPlanKeepsOnlyTheCardsStopSinceClaudeRecordsItsApproval() async throws {
        let request = ChatPendingRequest(
            entryID: ChatEntryID("plan"), callID: "toolu_plan", kind: .other, toolName: "ExitPlanMode", summary: "Plan")
        for (action, expected) in [
            (DialogAction.choose(ordinal: 1), ChatToolActivity.CardAnswer?.none),
            (.dismiss, .stopped),
        ] {
            let pane = FakePane(try ScreenFixture.screen("claude-16-c6-exitplan-1"))
            await pane.react(to: action == .dismiss ? ["esc"] : ["1"], with: try ScreenFixture.screen("claude-29-c3-after-immediate"))
            let store = Self.store(.claude, pane: pane)
            store.update(transcript: Self.transcript(pending: [request]))
            store.update(activity: .blocked)
            await store.refresh()
            guard case .card(let card) = store.content else {
                Issue.record("Expected a plan card, got \(store.content)")
                return
            }
            #expect(card.dialog.kind == .claudePlan)

            await store.perform(action)

            #expect(store.progress == .ready, "\(action)")
            #expect(store.history.calls["toolu_plan"] == expected, "\(action)")
        }
    }

    @Test func anAnswerThatShowedNoEffectIsNotKept() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        let store = Self.store(.claude, pane: pane)
        store.update(transcript: Self.transcript(pending: [Self.bash("toolu_1", "touch c1.txt")]))
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.choose(ordinal: 1))

        #expect(store.progress == .unconfirmed)
        #expect(store.history.isEmpty)
    }

    @Test func aCodexAsynchronousAnswerIsQueuedUnderItsQuestion() async throws {
        let pane = FakePane(try ScreenFixture.screen("codex-09-x4-expanded"))
        await pane.react(to: ["1"], with: try ScreenFixture.screen("codex-10-x4-after-digit"))
        let store = Self.store(.codex, pane: pane)
        let request = ChatPendingRequest(
            entryID: ChatEntryID("item-1"), callID: "item-1", kind: .question, toolName: "request_user_input_async",
            summary: "Pick a fruit",
            questions: [ChatQuestion(id: "item-1:0", text: "Pick a fruit"), ChatQuestion(id: "item-1:1", text: "Pick a drink")])
        store.update(transcript: ChatTranscript(entries: [], pendingRequests: [request]))
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys == [["1"]])
        #expect(store.history.queuedAnswers == ["item-1:0": "Apple"])
        #expect(store.history.calls.isEmpty)
    }

    /// Codex 0.162.1 delivers an asynchronous answer to a waiting tool call
    /// at once and draws no queued-messages notice: the next question
    /// replacing the answered one confirms the answer.
    @Test func aCodexAsynchronousAnswerWithoutTheNoticeConfirmsWhenTheQuestionLeaves() async throws {
        let pane = FakePane(try ScreenFixture.screen("codex-09-x4-expanded"))
        let notice = ["Messages to be submitted after next tool call", "↳ > Pick a fruit", "    Apple"]
        let delivered = try ScreenFixture.text("codex-10-x4-after-digit").components(separatedBy: "\r\n")
            .filter { row in !notice.contains { ANSIScreenDecoder.decode(row).rows.first?.text.contains($0) == true } }
        await pane.react(to: ["1"], with: ScreenFixture.synthetic(delivered))
        let store = Self.store(.codex, pane: pane)
        let request = ChatPendingRequest(
            entryID: ChatEntryID("item-1"), callID: "item-1", kind: .question, toolName: "request_user_input_async",
            summary: "Pick a fruit",
            questions: [ChatQuestion(id: "item-1:0", text: "Pick a fruit"), ChatQuestion(id: "item-1:1", text: "Pick a drink")])
        store.update(transcript: ChatTranscript(entries: [], pendingRequests: [request]))
        store.update(activity: .blocked)
        await store.refresh()

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys == [["1"]])
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
        #expect(store.history.queuedAnswers == ["item-1:0": "Apple"])
        guard case .card(let card) = store.content else {
            Issue.record("Expected the next question's card, got \(store.content)")
            return
        }
        #expect(card.dialog.title == "Pick a drink")
    }

    @Test func oneActionAtATime() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        await pane.react(to: ["1"], with: try ScreenFixture.screen("claude-29-c3-after-immediate"))
        let store = Self.store(.claude, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()

        async let first: Void = store.perform(.choose(ordinal: 1))
        async let second: Void = store.perform(.choose(ordinal: 1))
        _ = await (first, second)

        #expect(await pane.keys == [["1"]])
    }

    @Test func aScreenWithNoDialogWhileBlockedSaysSoOnlyAfterAMoment() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-01-ready"))
        let clock = ManualClock()
        let store = Self.store(.claude, pane: pane, clock: clock)
        store.update(activity: .blocked)

        // herdr reports Blocked a moment before the dialog draws.
        await store.refresh()
        #expect(store.content == .none)
        clock.advance(.seconds(2))
        await store.refresh()
        #expect(store.content == .unreadable)

        store.update(activity: .idle)
        #expect(store.content == .none)
        await store.refresh()
        #expect(store.content == .none)
    }

    @Test func anAnsweredDialogLeavesNothingBehindWhileBlockedLingers() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        await pane.react(to: ["1"], with: try ScreenFixture.screen("claude-29-c3-after-immediate"))
        let clock = ManualClock()
        let store = Self.store(.claude, pane: pane, clock: clock)
        store.update(activity: .blocked)
        clock.advance(.seconds(5))
        await store.refresh()

        await store.perform(.choose(ordinal: 1))
        await store.refresh()

        #expect(store.content == .none)
    }

    /// herdr reports Claude idle on its question review page and on a
    /// question with previews; the open call keeps the card reading.
    @Test func anIdleClaudeWithAnOpenQuestionStillShowsItsDialog() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-14-c4-review"))
        let store = Self.store(.claude, pane: pane)
        store.update(transcript: Self.transcript(pending: [Self.question("toolu_q")]))
        store.update(activity: .blocked)
        await store.refresh()
        store.update(activity: .idle)
        guard case .card(let review) = store.content else {
            Issue.record("Expected the review card to stay, got \(store.content)")
            return
        }
        #expect(review.dialog.kind == .claudeQuestionReview)

        // A relaunch: the review was reached while Chat wasn't watching.
        let relaunched = Self.store(.claude, pane: pane)
        relaunched.update(activity: .idle)
        relaunched.update(transcript: Self.transcript(pending: [Self.question("toolu_q")]))
        await relaunched.refresh()
        guard case .card(let card) = relaunched.content else {
            Issue.record("Expected the review card, got \(relaunched.content)")
            return
        }
        #expect(card.dialog.kind == .claudeQuestionReview)
        #expect(card.request?.callID == "toolu_q")

        await pane.show(try ScreenFixture.screen("claude-42-c8-phone-question-previews"))
        await relaunched.refresh()
        guard case .generic = relaunched.content else {
            Issue.record("Expected the generic card, got \(relaunched.content)")
            return
        }

        // The call's result ends it.
        relaunched.update(transcript: Self.transcript(resolved: [Self.question("toolu_q")]))
        #expect(relaunched.content == .none)
    }

    @Test func anIdleAgentWithoutAnOpenQuestionIsNotRead() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-14-c4-review"))
        let store = Self.store(.claude, pane: pane)
        store.update(transcript: Self.transcript(pending: [Self.bash("toolu_1", "touch c1.txt")]))
        store.update(activity: .idle)

        await store.refresh()

        #expect(store.content == .none)
        #expect(await pane.reads == 0)

        // Only Claude's idle questions read: herdr reports the others.
        let codex = Self.store(.codex, pane: pane)
        codex.update(transcript: Self.transcript(pending: [Self.question("toolu_q")]))
        codex.update(activity: .idle)
        await codex.refresh()
        #expect(codex.content == .none)
        #expect(await pane.reads == 0)
    }

    @Test func aNewDialogUnfoldsACollapsedCard() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-30-par-first"))
        let store = Self.store(.claude, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()
        store.isCollapsed = true

        await store.refresh()
        #expect(store.isCollapsed)
        await pane.show(try ScreenFixture.screen("claude-31-par-second"))
        await store.refresh()
        #expect(!store.isCollapsed)
    }

    @Test func keyPadKeysGoAsTheyAre() async throws {
        let pane = FakePane(try ScreenFixture.screen("claude-02-c1-bash-blocked"))
        await pane.react(to: ["down"], with: try ScreenFixture.screen("claude-03-c1-focus-no"))
        let store = Self.store(.claude, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()

        await store.sendKeys(["down"])

        #expect(await pane.keys == [["down"]])
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        #expect(card.dialog.focus.focusedOrdinal == 4)
    }

    // MARK: Oh My Pi

    /// OMP ignores ctrl+q for 500 ms after drawing the approval, so the key
    /// waits until 650 ms after the panel first showed, and goes once.
    @Test func anOMPApprovalWaitsOutTheArmBeforeCtrlQ() async throws {
        let pane = FakePane(try ScreenFixture.screen("omp-24-approval-a-dialog"))
        await pane.react(to: ["ctrl+q"], with: try ScreenFixture.screen("omp-09-tool-working-3s"))
        let clock = ManualClock()
        let store = Self.store(.omp, pane: pane, clock: clock)
        let request = Self.ompBash("call_1|fc_1", "echo approved-2")
        store.update(transcript: Self.transcript(pending: [request]))
        store.update(activity: .blocked)
        await store.refresh()
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        #expect(card.dialog.kind == .ompApproval)
        #expect(card.request?.callID == "call_1|fc_1")
        clock.advance(.milliseconds(100))

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys == [["ctrl+q"]])
        // Seen at t0, tapped at t0 + 100 ms: the key went at t0 + 650 ms.
        #expect(clock.sleeps == [.milliseconds(550)])
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
        #expect(store.history.calls["call_1|fc_1"] == .allowed)
    }

    @Test func anOMPApprovalSeenLongAgoSendsAtOnce() async throws {
        let pane = FakePane(try ScreenFixture.screen("omp-24-approval-a-dialog"))
        await pane.react(to: ["ctrl+q"], with: try ScreenFixture.screen("omp-09-tool-working-3s"))
        let clock = ManualClock()
        let store = Self.store(.omp, pane: pane, clock: clock)
        store.update(activity: .blocked)
        await store.refresh()
        clock.advance(.seconds(2))

        await store.perform(.choose(ordinal: 1))

        #expect(await pane.keys == [["ctrl+q"]])
        #expect(clock.sleeps.isEmpty)
        #expect(store.progress == .ready)
    }

    /// Esc denies the call and OMP goes on; the transcript records the
    /// denial, so the card keeps nothing.
    @Test func anOMPDenyIsEscAndNotKeptAsAStop() async throws {
        let request = Self.ompBash("call_1|fc_1", "echo approved-2")
        for action in [DialogAction.dismiss, .choose(ordinal: 2)] {
            let pane = FakePane(try ScreenFixture.screen("omp-24-approval-a-dialog"))
            await pane.react(to: ["esc"], with: try ScreenFixture.screen("omp-24-approval-e-enter-deny-and-send"))
            let store = Self.store(.omp, pane: pane)
            store.update(transcript: Self.transcript(pending: [request]))
            store.update(activity: .blocked)
            await store.refresh()

            await store.perform(action)

            #expect(await pane.keys == [["esc"]], "\(action)")
            #expect(store.progress == .ready, "\(action)")
            #expect(store.composerFocusRequest == 0, "\(action)")
            #expect(store.history.isEmpty, "\(action)")
        }
    }

    @Test func anOMPPanelHeelerDoesNotKnowGetsTheGenericCardWithoutDigits() async throws {
        let pane = FakePane(try ScreenFixture.screen("omp-31-plan-review"))
        let store = Self.store(.omp, pane: pane)
        store.update(activity: .blocked)
        await store.refresh()

        guard case .generic(let excerpt) = store.content else {
            Issue.record("Expected the generic card, got \(store.content)")
            return
        }
        #expect(excerpt.numbered.isEmpty)
        await store.press(number: 2)
        #expect(await pane.keys.isEmpty)
    }

    /// The program keeps drawing the question after Enter; the ask's result
    /// in the transcript confirms the answer.
    @Test func anOMPQuestionConfirmsByTheAskResult() async throws {
        let tui = FakeQuestionTUI(.omp, [Self.fruit])
        await tui.ignore("enter")
        let request = Self.ompAsk("call_a|fc_a", [Self.fruit])
        let box = StoreBox()
        let store = BlockedCardStore(
            program: .omp,
            io: BlockedScreenIO(
                readScreen: { await tui.read() },
                sendKeys: { keys in
                    await tui.send(keys)
                    guard keys == ["enter"] else { return }
                    await MainActor.run { box.store?.update(transcript: Self.transcript(resolved: [request])) }
                },
                paste: { await tui.paste($0) }),
            clock: ManualClock().clock)
        box.store = store
        store.update(transcript: Self.transcript(pending: [request]))
        store.update(activity: .blocked)
        await store.refresh()
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        #expect(card.dialog.kind == .ompQuestion)
        #expect(card.request?.callID == "call_a|fc_a")

        await store.perform(.choose(ordinal: 2))

        #expect(await tui.keys == [["down"], ["enter"]])
        #expect(store.progress == .ready)
        #expect(store.notice == nil)
    }

    /// Each page is its own card: Enter answers it and turns to the next,
    /// and the review's Submit sends the answers.
    @Test func anOMPTwoQuestionAskAnswersEachPageThenSubmits() async throws {
        let questions = [Self.fruit, FakeQuestionTUI.Question(header: "size", text: "Pick a size", options: ["small", "large"])]
        let tui = FakeQuestionTUI(.omp, questions)
        let store = Self.store(tui)
        store.update(transcript: Self.transcript(pending: [Self.ompAsk("call_b", questions)]))
        store.update(activity: .blocked)
        await store.refresh()

        for (progress, ordinal) in [("fruit", 2), ("size", 1), ("Review answers", 1)] {
            guard case .card(let card) = store.content else {
                Issue.record("Expected a card on \(progress), got \(store.content)")
                return
            }
            #expect(card.dialog.progress == progress)
            #expect(card.request?.callID == "call_b", "\(progress)")
            await store.perform(.choose(ordinal: ordinal))
            #expect(store.progress == .ready, "\(progress)")
            #expect(store.notice == nil, "\(progress)")
        }

        #expect(await tui.keys == [["down"], ["enter"], ["enter"], ["enter"]])
        #expect(await tui.answers == ["pear", "small"])
        #expect(await tui.state == .submitted)
        #expect(store.content == .none)
    }

    @Test func aGuardedQuestionSendsNoKeysAndSaysWhy() async throws {
        let tui = FakeQuestionTUI(.omp, [Self.fruit])
        await tui.holdDraft("my draft text")
        let store = Self.store(tui)
        store.update(activity: .blocked)
        await store.refresh()
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        #expect(card.dialog.focus.composerDraftGuard)

        await store.perform(.choose(ordinal: 1))

        #expect(await tui.keys.isEmpty)
        #expect(store.progress == .ready)
        #expect(
            store.notice
                == "Oh My Pi's input box holds a draft, so keys would go into it. Press Enter in the terminal to "
                + "queue it, or clear it, then answer.")

        // Stop still goes: Esc cancels the question.
        await store.perform(.dismiss)
        #expect(await tui.keys == [["esc"]])
        #expect(await tui.state == .cancelled)
        #expect(await tui.queued.isEmpty)
    }

    // MARK: Helpers

    private static let fruit = FakeQuestionTUI.Question(
        header: "fruit", text: "Pick a fruit", options: ["apple", "pear", "plum"])

    private static func ompAsk(_ id: String, _ questions: [FakeQuestionTUI.Question]) -> ChatPendingRequest {
        ChatPendingRequest(
            entryID: ChatEntryID(id), callID: id, kind: .question, toolName: "ask",
            summary: questions.first?.text ?? "",
            questions: questions.map {
                ChatQuestion(id: $0.header, text: $0.text, options: $0.options.map { ChatQuestion.Option(label: $0) })
            })
    }

    private static func store(_ tui: FakeQuestionTUI) -> BlockedCardStore {
        BlockedCardStore(
            program: tui.program,
            io: BlockedScreenIO(
                readScreen: { await tui.read() },
                sendKeys: { await tui.send($0) },
                paste: { await tui.paste($0) }),
            clock: ManualClock().clock)
    }

    private static func ompBash(_ id: String, _ command: String) -> ChatPendingRequest {
        ChatPendingRequest(entryID: ChatEntryID(id), callID: id, kind: .command, toolName: "bash", summary: command)
    }

    private static func store(_ program: ChatProgram, pane: FakePane, clock: ManualClock = ManualClock()) -> BlockedCardStore {
        BlockedCardStore(
            program: program,
            io: BlockedScreenIO(
                readScreen: { await pane.read() },
                sendKeys: { await pane.send($0) },
                paste: { await pane.paste($0) }),
            clock: clock.clock)
    }

    private static func question(_ id: String) -> ChatPendingRequest {
        ChatPendingRequest(
            entryID: ChatEntryID(id), callID: id, kind: .question, toolName: "AskUserQuestion", summary: "Colors")
    }

    private static func bash(_ id: String, _ command: String) -> ChatPendingRequest {
        ChatPendingRequest(
            entryID: ChatEntryID(id), callID: id, kind: .command, toolName: "Bash", summary: command)
    }

    private static func transcript(
        pending: [ChatPendingRequest] = [], resolved: [ChatPendingRequest] = []
    ) -> ChatTranscript {
        let entries = (pending.map { ($0, ChatToolActivity.Status.awaitingApproval) }
            + resolved.map { ($0, ChatToolActivity.Status.succeeded) }).enumerated().map { index, item in
                ChatEntry(
                    id: item.0.entryID, sourceOffset: UInt64(index),
                    content: .tool(
                        ChatToolActivity(
                            kind: item.0.kind, name: item.0.toolName, title: item.0.summary, status: item.1,
                            callID: item.0.callID)))
            }
        return ChatTranscript(entries: entries, pendingRequests: pending)
    }
}

@MainActor
private final class StoreBox {
    weak var store: BlockedCardStore?
}

/// The Agent's pane: one screen at a time, which keys can replace.
private actor FakePane {
    private var screen: ANSIScreen
    private var reactions: [[String]: ANSIScreen] = [:]
    private(set) var keys: [[String]] = []
    private(set) var pastes: [String] = []
    private(set) var reads = 0

    init(_ screen: ANSIScreen) {
        self.screen = screen
    }

    func read() -> ANSIScreen {
        reads += 1
        return screen
    }

    func show(_ screen: ANSIScreen) {
        self.screen = screen
    }

    func react(to keys: [String], with screen: ANSIScreen) {
        reactions[keys] = screen
    }

    func send(_ keys: [String]) {
        self.keys.append(keys)
        if let next = reactions[keys] { screen = next }
    }

    func paste(_ text: String) {
        pastes.append(text)
    }
}

@Suite("Agent quick key names")
struct AgentQuickKeyHerdrNameTests {
    @Test func everyKeyThePadSendsIsOneHerdrAccepts() {
        let pad: [AgentQuickKey] = [.escape, .tab, .backspace, .left, .up, .right, .shiftTab, .down, .enter]
        for key in pad {
            let name = key.herdrKeyName
            #expect(name.map(HerdrKeyGrammar.accepts) == true, "\(key) as \(String(describing: name))")
        }
        #expect(AgentQuickKey.character("+").herdrKeyName == "plus")
        #expect(AgentQuickKey.character(" ").herdrKeyName == "space")
        #expect(AgentQuickKey.function(.f5).herdrKeyName == "f5")
    }

    @Test func keysHerdrHasNoNameForStayUnsent() {
        for key: AgentQuickKey in [.home, .end, .insert, .forwardDelete, .pageUp, .pageDown, .character("👍🏽")] {
            #expect(key.herdrKeyName == nil)
        }
    }
}

@Suite("Blocked request match")
struct BlockedRequestMatchTests {
    private func dialog(_ stem: String) throws -> BlockedDialog {
        let result = BlockedDialogParser.parse(try ScreenFixture.screen(stem), program: ScreenFixture.program(stem))
        return try #require(result.dialog, "\(stem) parsed as \(result)")
    }

    private func request(
        _ id: String, _ tool: String, _ summary: String, kind: ChatToolActivity.Kind = .command,
        questions: [ChatQuestion] = []
    ) -> ChatPendingRequest {
        ChatPendingRequest(
            entryID: ChatEntryID(id), callID: id, kind: kind, toolName: tool, summary: summary, questions: questions)
    }

    @Test func aBashDialogMatchesItsCommandEvenWrappedNarrow() throws {
        let requests = [
            request("a", "Bash", "touch other.txt"), request("b", "Bash", "touch n1.txt"),
            request("c", "Bash", "touch n1.txt"),
        ]
        // Two identical calls: the older one asked first.
        #expect(BlockedRequestMatch.request(for: try dialog("claude-27-n1-narrow-bash"), in: requests)?.callID == "b")
    }

    @Test func aCutOffCommandMatchesTheCallItStarts() throws {
        let requests = [request("a", "Bash", "touch c1.txt && echo done")]
        #expect(BlockedRequestMatch.request(for: try dialog("claude-02-c1-bash-blocked"), in: requests)?.callID == "a")
        #expect(BlockedRequestMatch.request(for: try dialog("claude-02-c1-bash-blocked"), in: [request("b", "Bash", "touch")]) == nil)
    }

    @Test func filesMatchByNameAndFetchesByURL() throws {
        let edit = request("e", "Edit", "/work/probe/q.txt", kind: .fileEdit)
        #expect(BlockedRequestMatch.request(for: try dialog("claude-22-c7-edit"), in: [edit])?.callID == "e")
        #expect(
            BlockedRequestMatch.request(
                for: try dialog("claude-22-c7-edit"), in: [request("w", "Edit", "/work/q.md", kind: .fileEdit)]) == nil)
        let fetch = request("f", "WebFetch", "https://example.com/", kind: .web)
        #expect(BlockedRequestMatch.request(for: try dialog("claude-24-c8-webfetch"), in: [fetch])?.callID == "f")
        // The call names the bare host; the dialog shows `https://example.com/`.
        let bare = request("b", "WebFetch", "https://example.com", kind: .web)
        #expect(BlockedRequestMatch.request(for: try dialog("claude-24-c8-webfetch"), in: [bare])?.callID == "b")
        let other = request("o", "WebFetch", "https://example.org", kind: .web)
        #expect(BlockedRequestMatch.request(for: try dialog("claude-24-c8-webfetch"), in: [other]) == nil)
        // Hosts that only start with the shown host are other hosts.
        for url in ["https://example.com.au", "https://example.community/x", "https://example.com:8080"] {
            let longer = request("l", "WebFetch", url, kind: .web)
            #expect(BlockedRequestMatch.request(for: try dialog("claude-24-c8-webfetch"), in: [longer]) == nil)
        }
        // A path on the same host still matches, as before.
        let path = request("p", "WebFetch", "https://example.com/docs?q=1", kind: .web)
        #expect(BlockedRequestMatch.request(for: try dialog("claude-24-c8-webfetch"), in: [path])?.callID == "p")
    }

    @Test func aReadMatchesItsFile() throws {
        let path = "/var/folders/zz/probe0placeholder00000000000gn/T/heeler.hnDAu48H/"
            + "stage-474a20ea-59f3-48eb-8639-56c1977b6d41/image.jpg"
        let read = request("r", "Read", path, kind: .fileRead)
        let shown = try dialog("claude-43-c12-read-file")
        let edit = request("e", "Edit", path, kind: .fileEdit)
        #expect(BlockedRequestMatch.request(for: shown, in: [edit, read])?.callID == "r")
        // Staged images all share a name: an older Read of another one is not it.
        let other = request(
            "o", "Read",
            "/var/folders/zz/probe0placeholder00000000000gn/T/heeler.hnDAu48H/"
                + "stage-0b1c2d3e-0000-4000-8000-000000000000/image.jpg",
            kind: .fileRead)
        #expect(BlockedRequestMatch.request(for: shown, in: [other, read])?.callID == "r")
        #expect(BlockedRequestMatch.request(for: shown, in: [other]) == nil)
    }

    @Test func questionsMatchByTheirText() throws {
        let colors = request(
            "q", "AskUserQuestion", "Which colors?\nWhich size?", kind: .question,
            questions: [ChatQuestion(text: "Which colors?"), ChatQuestion(text: "Which size?")])
        #expect(BlockedRequestMatch.request(for: try dialog("claude-08-c4-auq-q1"), in: [colors])?.callID == "q")
        let codex = request(
            "c", "request_user_input", "Pick a color", kind: .question, questions: [ChatQuestion(text: "Pick a color")])
        #expect(BlockedRequestMatch.request(for: try dialog("codex-04-x3-q1"), in: [codex])?.callID == "c")
    }

    @Test func aPlanCardShowsTheCallsPlanOnlyWhenTheScreenAgrees() throws {
        // Claude Code 2.1.301, phone width: Write to the plan file and
        // ExitPlanMode in one message; the call holds the previous plan.
        let dialog = try dialog("claude-38-c8-phone-plan-stale-call")
        #expect(dialog.kind == .claudePlan)
        let shown = dialog.body.filter { !$0.hasPrefix("Claude has written up a plan") }
        let plan = { (name: String) in
            "# Plan: create \(name)\n\n## Context\nThe user wants a file `\(name)` in "
                + "`/private/tmp/heeler-iso-4h/proj-claude-b` containing the single word `probe`.\n\n## Steps\n"
                + "1. Use the Write tool to create `/private/tmp/heeler-iso-4h/proj-claude-b/\(name)` with the "
                + "content `probe`.\n2. Verify with the Read tool that the file contains exactly `probe`.\n\n"
                + "## Verification\nRead `\(name)` and confirm it holds only the word `probe`.\n"
        }
        #expect(BlockedRequestMatch.claudePlanText(call: plan("q.txt"), shownRows: shown) == plan("q.txt"))
        let stale = BlockedRequestMatch.claudePlanText(call: plan("p2.txt"), shownRows: shown)
        #expect(stale == shown.joined(separator: "\n"))
        #expect(stale.contains("Plan: create q.txt"))
        #expect(BlockedRequestMatch.claudePlanText(call: nil, shownRows: shown) == stale)
    }

    @Test func aPlanWithAWrappedTableAndARenumberedListStillAgrees() {
        let call = "# Plan\n\n| Step | Command |\n| --- | --- |\n| Create the file named | touch a.txt && echo done |\n\n"
            + "1. First thing to do here\n1. Second thing to do here\n"
        // Drawn the way the terminal draws them: cells wrapped side by
        // side, the list renumbered.
        let shown = [
            "Plan", "┌────────────┬──────────────┐", "│ Step       │ Command      │",
            "├────────────┼──────────────┤", "│ Create the │ touch a.txt  │", "│ file named │ && echo done │",
            "└────────────┴──────────────┘", "1. First thing to do here", "2. Second thing to do here",
        ]
        #expect(BlockedRequestMatch.claudePlanText(call: call, shownRows: shown) == call)
        let other = call.replacingOccurrences(of: "touch a.txt", with: "touch b.txt")
        #expect(BlockedRequestMatch.claudePlanText(call: other, shownRows: shown) == shown.joined(separator: "\n"))
    }

    @Test func anOMPApprovalMatchesItsToolAndCommand() throws {
        let approval = try dialog("omp-24-approval-a-dialog")
        let requests = [
            request("a", "bash", "echo approved-1"), request("b", "read", "echo approved-2", kind: .fileRead),
            request("c|fc", "bash", "echo approved-2 && echo more"),
        ]
        #expect(BlockedRequestMatch.request(for: approval, in: requests)?.callID == "c|fc")
        #expect(BlockedRequestMatch.request(for: approval, in: [request("d", "Bash", "echo approved-2")]) == nil)
    }

    @Test func aCodexCommandMatchesInsideItsScript() throws {
        let script = request("x", "exec", "await tools.exec_command({cmd: \"touch x1.txt\"})")
        #expect(BlockedRequestMatch.request(for: try dialog("codex-01-x1-exec"), in: [script])?.callID == "x")
        #expect(BlockedRequestMatch.request(for: try dialog("codex-01-x1-exec"), in: [request("y", "exec", "ls")]) == nil)
    }
}
