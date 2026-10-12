import CoreGraphics
import Testing
@testable import NotchApp

@MainActor
struct NotchViewModelTests {
    private func makeModel(_ h: RegistryHarness, sleeper: ManualSleeper = ManualSleeper()) -> NotchViewModel {
        h.registry.activateEnabledWidgets()
        return NotchViewModel(registry: h.registry, reduceMotion: { false }, sleep: { try await sleeper.sleep($0) })
    }

    /// Lets the delay task reach `sleep`, then completes it and lets the action run.
    private func elapse(_ sleeper: ManualSleeper, expecting delay: Duration) async {
        await waitUntil { sleeper.pendingDelays.contains(delay) }
        sleeper.advance()
    }

    // AC-9
    @Test func noActiveWidgetsMeansCollapsed() throws {
        let h = try RegistryHarness([FakeWidget(id: "a", priority: 10), FakeWidget(id: "b", priority: 90)])
        let model = makeModel(h)
        #expect(model.state == .collapsed)
        #expect(model.peekWidget == nil)
    }

    // AC-7, AC-8
    @Test func peekFollowsHighestPriorityActiveWidget() async throws {
        let h = try RegistryHarness([FakeWidget(id: "a", priority: 10, isActive: true), FakeWidget(id: "b", priority: 90)])
        let model = makeModel(h)
        #expect(model.state == .peek)
        #expect(model.peekWidgetID == "a")
        #expect(h["a"].lastVisibility == .compact)

        h["b"].isActive = true
        await waitUntil { model.peekWidgetID == "b" }
        #expect(model.state == .peek)
        #expect(h["b"].lastVisibility == .compact)
        #expect(h["a"].lastVisibility == .hidden)

        h["b"].isActive = false
        await waitUntil { model.peekWidgetID == "a" }
        #expect(h["a"].lastVisibility == .compact)
    }

    // AC-9
    @Test func lastActiveWidgetGoingInactiveCollapses() async throws {
        let h = try RegistryHarness([FakeWidget(id: "a", priority: 10, isActive: true)])
        let model = makeModel(h)
        h["a"].isActive = false
        await waitUntil { model.state == .collapsed }
        #expect(h["a"].lastVisibility == .hidden)

        h["a"].isActive = true
        await waitUntil { model.state == .peek }
    }

    @Test func disablingPeekWidgetCollapses() async throws {
        let h = try RegistryHarness([FakeWidget(id: "a", priority: 10, isActive: true)])
        let model = makeModel(h)
        h.registry.setEnabled("a", false)
        await waitUntil { model.state == .collapsed }
    }

    @Test func expandedVisibilityFollowsSelectedTab() throws {
        let h = try RegistryHarness([FakeWidget(id: "a", priority: 10, isActive: true), FakeWidget(id: "b")])
        let model = makeModel(h)
        model.send(.clicked)
        #expect(model.state == .expanded)
        #expect(h["a"].lastVisibility == .expanded)
        #expect(h["b"].lastVisibility == nil)

        model.selectTab("b")
        #expect(h["a"].lastVisibility == .hidden)
        #expect(h["b"].lastVisibility == .expanded)
    }

    // AC-23
    @Test func selectedTabIsRememberedBetweenOpenings() async throws {
        let h = try RegistryHarness([FakeWidget(id: "a"), FakeWidget(id: "b")])
        let sleeper = ManualSleeper()
        let model = makeModel(h, sleeper: sleeper)
        model.send(.clicked)
        model.selectTab("b")
        model.send(.pointerExited)
        await elapse(sleeper, expecting: NotchStateMachine.closeDelay)
        await waitUntil { model.state == .collapsed }
        #expect(h["b"].lastVisibility == .hidden)

        model.send(.clicked)
        #expect(model.selectedTabID == "b")
        #expect(h["b"].lastVisibility == .expanded)
    }

    // AC-3
    @Test func hoverOpensAfterOpenDelay() async throws {
        let h = try RegistryHarness([FakeWidget(id: "a")])
        let sleeper = ManualSleeper()
        let model = makeModel(h, sleeper: sleeper)
        model.send(.pointerEntered)
        #expect(model.state == .collapsed)
        await elapse(sleeper, expecting: .milliseconds(150))
        await waitUntil { model.state == .expanded }
    }

    // AC-5
    @Test func quickPassDoesNotOpenEvenIfStaleDelayCompletes() async throws {
        let h = try RegistryHarness([FakeWidget(id: "a")])
        let sleeper = ManualSleeper()
        let model = makeModel(h, sleeper: sleeper)
        model.send(.pointerEntered)
        await waitUntil { !sleeper.pendingDelays.isEmpty }
        model.send(.pointerExited)
        sleeper.advance()
        for _ in 0..<5 { await Task.yield() }
        #expect(model.state == .collapsed)
    }

    // AC-4
    @Test func leavingClosesAfterCloseDelay() async throws {
        let h = try RegistryHarness([FakeWidget(id: "a", priority: 10, isActive: true)])
        let sleeper = ManualSleeper()
        let model = makeModel(h, sleeper: sleeper)
        model.send(.clicked)
        model.send(.pointerExited)
        #expect(model.state == .expanded)
        await elapse(sleeper, expecting: .milliseconds(300))
        await waitUntil { model.state == .peek }
    }

    // AC-22
    @Test func textInputKeepsPanelOpen() async throws {
        let h = try RegistryHarness([FakeWidget(id: "a")])
        let sleeper = ManualSleeper()
        let model = makeModel(h, sleeper: sleeper)
        model.send(.clicked)
        model.send(.textInputBegan)
        model.send(.pointerExited)
        for _ in 0..<5 { await Task.yield() }
        #expect(sleeper.pendingDelays.isEmpty)
        sleeper.advance()
        #expect(model.state == .expanded)

        model.send(.textInputEnded)
        await elapse(sleeper, expecting: NotchStateMachine.closeDelay)
        await waitUntil { model.state == .collapsed }
    }

    @Test func layoutGrowsBeforeExpandingAndPlacesCollapsedImmediately() throws {
        let h = try RegistryHarness([FakeWidget(id: "a")])
        let model = makeModel(h)
        var requests: [NotchLayoutRequest] = []
        model.onLayoutChange = { requests.append($0) }
        let geometry = NotchGeometry.make(for: Screens.builtInNotch)

        model.updateGeometry(geometry)
        #expect(requests.last == NotchLayoutRequest(frame: geometry.collapsedRect, phase: .immediate))

        model.send(.clicked)
        #expect(requests.last == NotchLayoutRequest(frame: geometry.expandedRect, phase: .growBeforeAnimation))
    }

    // grow → animate → shrink (ADR-001)
    @Test func animationFinishShrinksToRestingShapeOnlyForCurrentGeneration() async throws {
        let h = try RegistryHarness([FakeWidget(id: "a", priority: 10, isActive: true)])
        let sleeper = ManualSleeper()
        let model = makeModel(h, sleeper: sleeper)
        var requests: [NotchLayoutRequest] = []
        model.onLayoutChange = { requests.append($0) }
        let geometry = NotchGeometry.make(for: Screens.builtInNotch)
        model.updateGeometry(geometry)

        model.send(.clicked)
        model.send(.pointerExited)
        await elapse(sleeper, expecting: NotchStateMachine.closeDelay)
        await waitUntil { model.state == .peek }
        #expect(requests.contains(NotchLayoutRequest(frame: geometry.expandedRect, phase: .growBeforeAnimation)))

        // The shrink is triggered by `animationDidFinish`, called either by SwiftUI's completion (it also
        // fires without a view) or explicitly here; either way it must happen exactly once.
        model.animationDidFinish(generation: model.transitionGeneration)
        let shrink = NotchLayoutRequest(frame: geometry.peekRect, phase: .shrinkAfterAnimation)
        await waitUntil { requests.last == shrink }
        #expect(requests.filter { $0.phase == .shrinkAfterAnimation } == [shrink])

        let countBefore = requests.count
        model.animationDidFinish(generation: model.transitionGeneration - 1)
        model.animationDidFinish(generation: model.transitionGeneration)
        #expect(requests.count == countBefore)
    }

    @Test func staleAnimationCompletionDoesNotShrinkNewerTransition() async throws {
        let h = try RegistryHarness([FakeWidget(id: "a", priority: 10, isActive: true)])
        let model = makeModel(h)
        var requests: [NotchLayoutRequest] = []
        model.onLayoutChange = { requests.append($0) }
        let geometry = NotchGeometry.make(for: Screens.builtInNotch)
        model.updateGeometry(geometry)
        let peekGeneration = model.transitionGeneration

        model.send(.clicked)
        #expect(model.state == .expanded)
        model.animationDidFinish(generation: peekGeneration)
        #expect(requests.last == NotchLayoutRequest(frame: geometry.expandedRect, phase: .growBeforeAnimation))
        #expect(!requests.contains { $0.phase == .shrinkAfterAnimation })
    }

    @Test func screenChangeEndsInputAndRests() throws {
        let h = try RegistryHarness([FakeWidget(id: "a")])
        let model = makeModel(h)
        var ended = 0
        model.onEndTextInput = { ended += 1 }
        model.updateGeometry(NotchGeometry.make(for: Screens.builtInNotch))
        model.send(.clicked)
        model.send(.textInputBegan)

        model.updateGeometry(NotchGeometry.make(for: Screens.external))
        #expect(model.state == .collapsed)
        #expect(!model.isTextInputActive)
        #expect(ended >= 1)
    }

    @Test func screenChangeWhileExpandedNeverSpansBothScreens() throws {
        let h = try RegistryHarness([FakeWidget(id: "a", priority: 10, isActive: true)])
        let model = makeModel(h)
        var requests: [NotchLayoutRequest] = []
        model.updateGeometry(NotchGeometry.make(for: Screens.builtInNotch))
        model.send(.clicked)
        #expect(model.state == .expanded)

        model.onLayoutChange = { requests.append($0) }
        let external = NotchGeometry.make(for: Screens.external)
        model.updateGeometry(external)

        #expect(!requests.isEmpty)
        for request in requests {
            #expect(external.expandedRect.contains(request.frame))
        }
        #expect(requests.last == NotchLayoutRequest(frame: external.peekRect, phase: .immediate))
    }
}
