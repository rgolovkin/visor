import AppKit
import Testing
@testable import NotchApp

struct PeekResolverTests {
    private func c(_ id: String, _ priority: Int, _ active: Bool, _ order: Int) -> PeekCandidate {
        PeekCandidate(id: id, priority: priority, isActive: active, order: order)
    }

    // AC-7
    @Test func highestActivePriorityWins() {
        #expect(PeekResolver.winner([c("a", 10, true, 0), c("b", 90, true, 1), c("c", 95, false, 2)]) == "b")
    }

    @Test func tieBreaksByConfigOrder() {
        #expect(PeekResolver.winner([c("late", 50, true, 3), c("early", 50, true, 1)]) == "early")
    }

    // AC-9
    @Test func noActiveCandidatesMeansNoPeek() {
        #expect(PeekResolver.winner([c("a", 10, false, 0)]) == nil)
        #expect(PeekResolver.winner([]) == nil)
    }
}

@MainActor
struct WidgetRegistryTests {
    @Test func launchActivatesOnlyEnabledWidgets() throws {
        let h = try RegistryHarness(
            [FakeWidget(id: "a"), FakeWidget(id: "b")],
            configJSON: #"{"schemaVersion":1,"widgets":[{"id":"a","enabled":true},{"id":"b","enabled":false}]}"#
        )
        h.registry.activateEnabledWidgets()
        #expect(h["a"].activateCount == 1)
        #expect(h["a"].lastActivationReason == .launch)
        #expect(h["b"].activateCount == 0)
        #expect(h.registry.enabledWidgets.map(\.id) == ["a"])
    }

    @Test func itemsFollowConfigOrderAndMissingWidgetsAreAppended() throws {
        let h = try RegistryHarness(
            [FakeWidget(id: "a"), FakeWidget(id: "b"), FakeWidget(id: "c")],
            configJSON: #"{"schemaVersion":1,"widgets":[{"id":"c","enabled":true},{"id":"ghost","enabled":true},{"id":"a","enabled":true}]}"#
        )
        #expect(h.registry.items.map(\.widget.id) == ["c", "a", "b"])
        #expect(h.store.document.widgets.map(\.id) == ["c", "ghost", "a", "b"])
    }

    // AC-18
    @Test func disablingDeactivatesAndHidesWidget() throws {
        let h = try RegistryHarness([FakeWidget(id: "a", priority: 10, isActive: true), FakeWidget(id: "b")])
        h.registry.activateEnabledWidgets()
        h.registry.updateVisibility(state: .peek, selectedTabID: nil)
        #expect(h["a"].lastVisibility == .compact)

        h.registry.setEnabled("a", false)
        #expect(h["a"].deactivateCount == 1)
        #expect(h["a"].lastVisibility == .hidden)
        #expect(h.registry.enabledWidgets.map(\.id) == ["b"])
        #expect(h.registry.peekWinner == nil)
        #expect(h.store.document.widgets.first { $0.id == "a" }?.enabled == false)
    }

    @Test func fastToggleKeepsExactlyOneActiveCycle() throws {
        let h = try RegistryHarness([FakeWidget(id: "a")])
        h.registry.activateEnabledWidgets()
        h.registry.setEnabled("a", false)
        h.registry.setEnabled("a", true)
        h.registry.setEnabled("a", true)
        h.registry.setEnabled("a", false)
        h.registry.setEnabled("a", false)
        h.registry.setEnabled("a", true)
        #expect(h["a"].activateCount == 3)
        #expect(h["a"].deactivateCount == 2)
        #expect(h["a"].isRunning)
        #expect(h["a"].lastActivationReason == .userEnabled)
    }

    @Test func moveChangesConfigOrderAndKeepsUnknownSlots() throws {
        let h = try RegistryHarness(
            [FakeWidget(id: "a"), FakeWidget(id: "b"), FakeWidget(id: "c")],
            configJSON: #"{"schemaVersion":1,"widgets":[{"id":"a"},{"id":"ghost"},{"id":"b"},{"id":"c"}]}"#
        )
        h.registry.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(h.registry.items.map(\.widget.id) == ["c", "a", "b"])
        #expect(h.store.document.widgets.map(\.id) == ["c", "ghost", "a", "b"])

        h.registry.moveDown("c")
        #expect(h.registry.items.map(\.widget.id) == ["a", "c", "b"])
        h.registry.moveUp("a")
        h.registry.moveDown("b")
        #expect(h.registry.items.map(\.widget.id) == ["a", "c", "b"])
    }

    @Test func visibilityIsReportedOnlyOnChange() throws {
        let h = try RegistryHarness([FakeWidget(id: "a", priority: 10, isActive: true), FakeWidget(id: "b")])
        h.registry.activateEnabledWidgets()
        h.registry.updateVisibility(state: .peek, selectedTabID: nil)
        h.registry.updateVisibility(state: .peek, selectedTabID: nil)
        #expect(h["a"].visibilityHistory == [.compact])

        h.registry.updateVisibility(state: .expanded, selectedTabID: "b")
        #expect(h["a"].visibilityHistory == [.compact, .hidden])
        #expect(h["b"].visibilityHistory == [.expanded])

        h.registry.updateVisibility(state: .collapsed, selectedTabID: "b")
        #expect(h["b"].visibilityHistory == [.expanded, .hidden])
    }

    @Test func expandedFallsBackToFirstEnabledTab() throws {
        let h = try RegistryHarness([FakeWidget(id: "a"), FakeWidget(id: "b")])
        h.registry.activateEnabledWidgets()
        h.registry.updateVisibility(state: .expanded, selectedTabID: "b")
        h.registry.setEnabled("b", false)
        #expect(h.registry.resolvedTabID("b") == "a")
        #expect(h["a"].lastVisibility == .expanded)
        #expect(h["b"].lastVisibility == .hidden)
        #expect(h.registry.resolvedTabID(nil) == "a")
    }

    // AC-7
    @Test func peekWinnerUsesPriorityThenOrder() throws {
        let h = try RegistryHarness([
            FakeWidget(id: "low", priority: 10, isActive: true),
            FakeWidget(id: "tieFirst", priority: 50, isActive: true),
            FakeWidget(id: "tieSecond", priority: 50, isActive: true),
        ])
        #expect(h.registry.peekWinner?.id == "tieFirst")
        h.registry.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(h.registry.peekWinner?.id == "tieSecond")
    }

    // AC-8
    @Test func observationLoopFiresWhenIsActiveChanges() async throws {
        let h = try RegistryHarness([FakeWidget(id: "a", priority: 10, isActive: true), FakeWidget(id: "b", priority: 90)])
        var seen: [String?] = []
        let loop = ObservationLoop(read: { h.registry.peekWinner?.id }) { seen.append($0) }
        #expect(loop.value == "a")

        h["b"].isActive = true
        await waitUntil { seen == ["b"] }
        h["b"].isActive = false
        await waitUntil { seen == ["b", "a"] }
        h["a"].priority = 11
        try await Task.sleep(for: .milliseconds(50))
        #expect(seen == ["b", "a"])

        loop.cancel()
        h["a"].isActive = false
        try await Task.sleep(for: .milliseconds(50))
        #expect(seen == ["b", "a"])
    }

    @Test func resetToDefaultsReappliesConfigAndReloadsSettings() throws {
        let h = try RegistryHarness(
            [FakeWidget(id: "a"), FakeWidget(id: "b")],
            configJSON: #"{"schemaVersion":1,"widgets":[{"id":"b","enabled":false},{"id":"a","enabled":true}]}"#
        )
        h.registry.activateEnabledWidgets()
        h.store.resetToDefaults()
        h.registry.resetToDefaults()
        #expect(h.registry.items.map(\.widget.id) == ["a", "b"])
        #expect(h["b"].isRunning)
        #expect(h["a"].reloadCount == 1)
        #expect(h["b"].reloadCount == 1)
    }

    @Test func flushAllFlushesEveryWidget() throws {
        let h = try RegistryHarness([FakeWidget(id: "a"), FakeWidget(id: "b")])
        h.registry.flushAll()
        #expect(h["a"].flushCount == 1)
        #expect(h["b"].flushCount == 1)
    }

    @Test func settingsHandleMergesAndKeepsUnknownKeys() throws {
        struct S: Codable, Equatable { var format: String }
        let h = try RegistryHarness(
            [FakeWidget(id: "a")],
            configJSON: #"{"schemaVersion":1,"widgets":[{"id":"a","settings":{"format":"12h","future":1}}]}"#
        )
        let handle = WidgetSettingsHandle(widgetID: "a", store: h.store)
        #expect(handle.load(S.self) == S(format: "12h"))
        handle.save(S(format: "24h"))
        #expect(h.store.document.widgets[0].settings == .object(["format": .string("24h"), "future": .number(1)]))
        #expect(WidgetSettingsHandle(widgetID: "missing", store: h.store).load(S.self) == nil)
    }
}

@MainActor
struct SystemUtilitiesTests {
    @Test func systemEventsObserveLazilyAndDispatch() {
        let center = NotificationCenter()
        let workspace = NotificationCenter()
        let events = SystemEvents(center: center, workspaceCenter: workspace)
        #expect(events.observedKinds.isEmpty)

        var received: [SystemEvents.Kind] = []
        let first = events.subscribe([.clockChanged, .wake]) { received.append($0) }
        let second = events.subscribe([.clockChanged]) { received.append($0) }
        #expect(events.observedKinds == [.clockChanged, .wake])

        center.post(name: .NSSystemClockDidChange, object: nil)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(received.filter { $0 == .clockChanged }.count == 2)
        #expect(received.filter { $0 == .wake }.count == 1)

        first.cancel()
        #expect(events.observedKinds == [.clockChanged])
        second.cancel()
        #expect(events.observedKinds.isEmpty)

        center.post(name: .NSSystemClockDidChange, object: nil)
        #expect(received.count == 3)
    }

    @Test func notificationObservationStopsAfterCancel() {
        let center = NotificationCenter()
        let name = Notification.Name("test")
        var count = 0
        let observation = NotificationObservation(center: center, name: name) { count += 1 }
        center.post(name: name, object: nil)
        observation.cancel()
        center.post(name: name, object: nil)
        #expect(count == 1)
    }

    @Test func oneShotSchedulerFiresOnceAndCanBeReplaced() async throws {
        let scheduler = OneShotScheduler()
        var fired: [String] = []
        scheduler.schedule(after: .milliseconds(30), tolerance: .milliseconds(5)) { fired.append("first") }
        scheduler.schedule(after: .milliseconds(30), tolerance: .milliseconds(5)) { fired.append("second") }
        #expect(scheduler.isScheduled)
        await waitUntil { fired == ["second"] }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fired == ["second"])
        #expect(!scheduler.isScheduled)

        scheduler.schedule(after: .milliseconds(30), tolerance: .milliseconds(5)) { fired.append("cancelled") }
        scheduler.cancel()
        try await Task.sleep(for: .milliseconds(150))
        #expect(fired == ["second"])
    }
}
