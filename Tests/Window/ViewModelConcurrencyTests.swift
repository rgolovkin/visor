import Testing
@testable import NotchApp

/// Races between delayed tasks and events in NotchViewModel (AC-3..AC-6, AC-22).
@MainActor
struct ViewModelConcurrencyTests {
    private func makeModel(
        _ h: RegistryHarness, sleeper: ManualSleeper, reduceMotion: Bool = false
    ) -> NotchViewModel {
        h.registry.activateEnabledWidgets()
        return NotchViewModel(registry: h.registry, reduceMotion: { reduceMotion }, sleep: { try await sleeper.sleep($0) })
    }

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    @Test func rapidEnterExitStormNeverOpens() async throws {
        let h = try RegistryHarness([FakeWidget(id: "a", priority: 1, isActive: true)])
        let sleeper = ManualSleeper()
        let model = makeModel(h, sleeper: sleeper)
        for _ in 0..<100 {
            model.send(.pointerEntered)
            model.send(.pointerExited)
        }
        await settle()
        sleeper.advance()
        await settle()
        #expect(model.state == .peek)
    }

    @Test func staleCompletionsOfCancelledTasksAreIgnoredAfterReenter() async throws {
        let h = try RegistryHarness([FakeWidget(id: "a")])
        let sleeper = ManualSleeper()
        let model = makeModel(h, sleeper: sleeper)
        model.send(.pointerEntered)
        await waitUntil { sleeper.pendingDelays.count == 1 }
        model.send(.pointerExited)
        model.send(.pointerEntered)
        await waitUntil { sleeper.pendingDelays.count == 2 }
        let generationBefore = model.transitionGeneration
        sleeper.advance()   // completes the cancelled and the live task together
        await waitUntil { model.state == .expanded }
        #expect(model.transitionGeneration == generationBefore + 1, "exactly one transition expected")
    }

    @Test func closeTimerRacingWithReenterDoesNotCollapse() async throws {
        let h = try RegistryHarness([FakeWidget(id: "a")])
        let sleeper = ManualSleeper()
        let model = makeModel(h, sleeper: sleeper)
        model.send(.clicked)
        model.send(.pointerExited)
        await waitUntil { sleeper.pendingDelays.contains(NotchStateMachine.closeDelay) }
        model.send(.pointerEntered)   // arrives right before the timer fires
        sleeper.advance()
        await settle()
        #expect(model.state == .expanded)
    }

    @Test func textInputBeginDuringCloseDelayCancelsClose() async throws {
        let h = try RegistryHarness([FakeWidget(id: "a")])
        let sleeper = ManualSleeper()
        let model = makeModel(h, sleeper: sleeper)
        model.send(.clicked)
        model.send(.pointerExited)
        await waitUntil { sleeper.pendingDelays.contains(NotchStateMachine.closeDelay) }
        model.send(.textInputBegan)
        sleeper.advance()
        await settle()
        #expect(model.state == .expanded)
        #expect(model.isTextInputActive)
    }

    @Test func screenChangeDuringPendingOpenCancelsIt() async throws {
        let h = try RegistryHarness([FakeWidget(id: "a")])
        let sleeper = ManualSleeper()
        let model = makeModel(h, sleeper: sleeper)
        model.updateGeometry(NotchGeometry.make(for: Screens.builtInNotch))
        model.send(.pointerEntered)
        await waitUntil { !sleeper.pendingDelays.isEmpty }
        model.updateGeometry(NotchGeometry.make(for: Screens.external))
        sleeper.advance()
        await settle()
        #expect(model.state == .collapsed)
        #expect(!model.isPointerInside)
    }

    @Test func modelIsReleasedEvenWithAPendingDelay() async throws {
        let h = try RegistryHarness([FakeWidget(id: "a")])
        let sleeper = ManualSleeper()
        weak var weakModel: NotchViewModel?
        do {
            let model = makeModel(h, sleeper: sleeper)
            weakModel = model
            model.send(.pointerEntered)
            await waitUntil { !sleeper.pendingDelays.isEmpty }
        }
        sleeper.advance()   // late completion after the model is gone must be harmless
        await settle()
        #expect(weakModel == nil, "NotchViewModel leaked through its delay task or observation loop")
    }

    @Test(arguments: [false, true])
    func fullCycleWorksWithAndWithoutReduceMotion(_ reduce: Bool) async throws {
        let h = try RegistryHarness([FakeWidget(id: "a", priority: 1, isActive: true), FakeWidget(id: "b")])
        let sleeper = ManualSleeper()
        let model = makeModel(h, sleeper: sleeper, reduceMotion: reduce)
        model.updateGeometry(NotchGeometry.make(for: Screens.builtInNotch))
        #expect(model.state == .peek)
        model.send(.clicked)
        model.selectTab("b")
        model.selectTab("b")
        #expect(model.selectedTabID == "b")
        model.send(.pointerExited)
        await waitUntil { sleeper.pendingDelays.contains(NotchStateMachine.closeDelay) }
        sleeper.advance()
        await waitUntil { model.state == .peek }
        model.send(.clicked)
        #expect(model.selectedTabID == "b", "AC-23: tab remembered")
    }

    @Test func peekWinnerFlappingNeverLeavesAStaleOrMissingPeek() async throws {
        let a = FakeWidget(id: "a", priority: 10, isActive: true)
        let b = FakeWidget(id: "b", priority: 90, isActive: false)
        let h = try RegistryHarness([a, b])
        let model = makeModel(h, sleeper: ManualSleeper())
        for i in 0..<50 {
            b.isActive = i % 2 == 0
            await Task.yield()
        }
        await waitUntil { model.peekWidget?.id == "a" }   // 49 is odd -> b inactive -> a wins
        #expect(model.state == .peek)
        a.isActive = false
        await waitUntil { model.state == .collapsed }
    }

    @Test func selectingUnknownTabFallsBackWithoutCrash() throws {
        let h = try RegistryHarness([FakeWidget(id: "a"), FakeWidget(id: "b")])
        let model = makeModel(h, sleeper: ManualSleeper())
        model.selectTab("ghost")
        model.send(.clicked)
        #expect(h["a"].lastVisibility == .expanded)
        #expect(h["b"].lastVisibility != .expanded)
    }
}
