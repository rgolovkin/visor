import Foundation
import Testing
@testable import NotchApp

/// Edge cases of WidgetOrder / PeekResolver / WidgetRegistry (AC-7, AC-8, AC-9, AC-16, AC-18).
struct WidgetOrderEdgeTests {
    private func entries(_ ids: [String]) -> [WidgetConfigEntry] {
        ids.map { WidgetConfigEntry(id: $0, enabled: true, settings: .object(["origin": .string($0)])) }
    }

    @Test func emptyInputs() {
        #expect(WidgetOrder.reorder(entries: [], knownIDs: ["a"], newKnownOrder: ["a"]).isEmpty)
        #expect(WidgetOrder.reorder(entries: entries(["a", "b"]), knownIDs: [], newKnownOrder: ["b", "a"]).map(\.id) == ["a", "b"])
        #expect(WidgetOrder.reorder(entries: entries(["a", "b"]), knownIDs: ["a", "b"], newKnownOrder: []).map(\.id) == ["a", "b"])
    }

    @Test func onlyUnknownEntriesStayUntouched() {
        let input = entries(["x", "y", "z"])
        #expect(WidgetOrder.reorder(entries: input, knownIDs: ["a"], newKnownOrder: ["a"]) == input)
    }

    @Test func unknownIdsInNewOrderAreIgnored() {
        let result = WidgetOrder.reorder(entries: entries(["a", "X", "b"]), knownIDs: ["a", "b"], newKnownOrder: ["b", "ghost", "a"])
        #expect(result.map(\.id) == ["b", "X", "a"])
    }

    @Test func duplicatesInNewOrderDoNotDuplicateEntries() {
        let result = WidgetOrder.reorder(entries: entries(["a", "X", "b"]), knownIDs: ["a", "b"], newKnownOrder: ["b", "b", "a", "a"])
        #expect(result.map(\.id) == ["b", "X", "a"])
    }

    @Test func entryContentTravelsWithItsId() {
        let result = WidgetOrder.reorder(entries: entries(["a", "X", "b"]), knownIDs: ["a", "b"], newKnownOrder: ["b", "a"])
        for entry in result {
            #expect(entry.settings["origin"] == .string(entry.id))
        }
    }

    /// Property: for random permutations and random unknown placement the multiset is preserved and
    /// every unknown id keeps its index.
    @Test func randomPermutationsKeepUnknownSlotsAndMultiset() {
        var rng = SplitMix(seed: 42)
        for _ in 0..<500 {
            let count = Int(rng.next() % 9) + 1
            let ids = (0..<count).map { "w\($0)" }
            let unknown = Set(ids.filter { _ in rng.next() % 3 == 0 })
            let known = Set(ids).subtracting(unknown)
            var order = ids.filter(known.contains)
            for i in order.indices.reversed() where i > 0 {
                order.swapAt(i, Int(rng.next() % UInt64(i + 1)))
            }
            let result = WidgetOrder.reorder(entries: entries(ids), knownIDs: known, newKnownOrder: order)
            #expect(result.map(\.id).sorted() == ids.sorted())
            for (index, id) in ids.enumerated() where unknown.contains(id) {
                #expect(result[index].id == id)
            }
            #expect(result.map(\.id).filter(known.contains) == order)
        }
    }

    @Test func reconcileAppendsOnlyMissingCatalogWidgetsWithTheirDefaults() {
        let catalog = [
            WidgetDescriptor(id: "a", defaultEnabled: true) { _ in fatalError() },
            WidgetDescriptor(id: "b", defaultEnabled: false) { _ in fatalError() },
        ]
        let result = WidgetOrder.reconcile(entries: entries(["a", "ghost"]), catalog: catalog)
        #expect(result.map(\.id) == ["a", "ghost", "b"])
        #expect(result.last?.enabled == false)
        #expect(WidgetOrder.reconcile(entries: [], catalog: []).isEmpty)
    }
}

struct PeekResolverEdgeTests {
    private func c(_ id: String, _ priority: Int, _ active: Bool = true, order: Int) -> PeekCandidate {
        PeekCandidate(id: id, priority: priority, isActive: active, order: order)
    }

    @Test func tieBreakIsIndependentOfInputArrayOrder() {
        let items = [c("a", 50, order: 2), c("b", 50, order: 0), c("c", 50, order: 1), c("d", 49, order: -1)]
        var rng = SplitMix(seed: 7)
        for _ in 0..<200 {
            var shuffled = items
            for i in shuffled.indices.reversed() where i > 0 { shuffled.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
            #expect(PeekResolver.winner(shuffled) == "b")
        }
    }

    @Test func extremeAndNegativePriorities() {
        #expect(PeekResolver.winner([c("min", Int.min, order: 0), c("max", Int.max, order: 1)]) == "max")
        #expect(PeekResolver.winner([c("neg", -5, order: 0), c("zero", 0, order: 1)]) == "zero")
        #expect(PeekResolver.winner([c("only", Int.min, order: 0)]) == "only")
    }

    @Test func inactiveHigherPriorityNeverWins() {
        #expect(PeekResolver.winner([c("top", 100, false, order: 0), c("low", 1, true, order: 1)]) == "low")
        #expect(PeekResolver.winner([c("top", 100, false, order: 0), c("low", 1, false, order: 1)]) == nil)
    }

    @Test func fullyIdenticalCandidatesGiveAStableAnswer() {
        let items = [c("first", 5, order: 0), c("second", 5, order: 0)]
        #expect(PeekResolver.winner(items) == PeekResolver.winner(items))
        #expect(PeekResolver.winner(items) == "first")
    }

    /// Scale from the specification: timer 90 > battery 80 > calendar 70 > sysmon 30 > weather 20 > clock 10 > notes 0.
    @Test func specificationScaleOrdersWidgetsAsDocumented() {
        let scale: [(String, Int)] = [("notes", 0), ("clock", 10), ("weather", 20), ("sysmon", 30), ("calendar", 70), ("battery", 80), ("timer", 90)]
        var remaining = scale
        while remaining.count > 1 {
            let items = remaining.enumerated().map { c($0.element.0, $0.element.1, order: $0.offset) }
            #expect(PeekResolver.winner(items) == remaining.last?.0)
            remaining.removeLast()
        }
    }
}

@MainActor
struct WidgetRegistryEdgeTests {
    @Test func disabledWidgetNeverWinsPeekEvenWhenActiveAndTopPriority() throws {
        let h = try RegistryHarness(
            [FakeWidget(id: "hi", priority: 90, isActive: true), FakeWidget(id: "lo", priority: 10, isActive: true)],
            configJSON: #"{"widgets":[{"id":"hi","enabled":false},{"id":"lo","enabled":true}]}"#
        )
        #expect(h.registry.peekWinner?.id == "lo")
        h.registry.setEnabled("lo", false)
        #expect(h.registry.peekWinner == nil)
    }

    @Test func reorderingChangesTieBreakWinner() throws {
        let h = try RegistryHarness([FakeWidget(id: "a", priority: 5, isActive: true), FakeWidget(id: "b", priority: 5, isActive: true)])
        #expect(h.registry.peekWinner?.id == "a")
        h.registry.moveDown("a")
        #expect(h.registry.peekWinner?.id == "b")
    }

    @Test func unknownIdsInConfigSurviveMovesAndToggles() throws {
        let h = try RegistryHarness(
            [FakeWidget(id: "a"), FakeWidget(id: "b")],
            configJSON: #"{"widgets":[{"id":"a"},{"id":"future","settings":{"k":1},"extraKey":true},{"id":"b"}]}"#
        )
        h.registry.moveUp("b")
        h.registry.setEnabled("a", false)
        h.store.flush()
        let widgets = try TestFixtures.jsonObject(at: AppPaths(root: h.dir.url).config)["widgets"]?.arrayValue ?? []
        #expect(widgets.compactMap { $0["id"]?.stringValue } == ["b", "future", "a"])
        #expect(widgets[1]["settings"] == .object(["k": .number(1)]))
        #expect(widgets[1]["extraKey"] == .bool(true))
        #expect(widgets[2]["enabled"] == .bool(false))
    }

    @Test func duplicateConfigEntriesDoNotDuplicateWidgets() throws {
        let h = try RegistryHarness(
            [FakeWidget(id: "a"), FakeWidget(id: "b")],
            configJSON: #"{"widgets":[{"id":"a"},{"id":"a","enabled":false},{"id":"b"}]}"#
        )
        #expect(h.registry.items.map(\.widget.id) == ["a", "b"])
        #expect(h.registry.items[0].enabled)
    }

    @Test func emptyOrBrokenWidgetsArrayStillYieldsAllCatalogWidgets() throws {
        for json in [#"{"widgets":[]}"#, #"{"widgets":null}"#, #"{"widgets":"x"}"#, "{}"] {
            let h = try RegistryHarness([FakeWidget(id: "a"), FakeWidget(id: "b")], configJSON: json)
            #expect(h.registry.items.map(\.widget.id) == ["a", "b"], "config: \(json)")
            #expect(h.registry.items.allSatisfy { $0.enabled })
        }
    }

    @Test func enableDisableAreIdempotent() throws {
        let h = try RegistryHarness([FakeWidget(id: "a")])
        h.registry.activateEnabledWidgets()
        h.registry.activateEnabledWidgets()
        #expect(h["a"].activateCount == 1)
        h.registry.setEnabled("a", true)
        #expect(h["a"].activateCount == 1)
        h.registry.setEnabled("a", false)
        h.registry.setEnabled("a", false)
        #expect(h["a"].deactivateCount == 1)
        h.registry.setEnabled("nope", true)
        h.registry.moveUp("nope")
        h.registry.moveDown("nope")
    }

    @Test func deactivateAllReleasesEverythingExactlyOnceAndIsRepeatable() throws {
        let h = try RegistryHarness([FakeWidget(id: "a", isActive: true), FakeWidget(id: "b")])
        h.registry.activateEnabledWidgets()
        h.registry.deactivateAll()
        h.registry.deactivateAll()
        for id in ["a", "b"] {
            #expect(h[id].deactivateCount == 1)
            #expect(!h[id].isRunning)
            #expect(h[id].lastVisibility == nil || h[id].lastVisibility == .hidden)
        }
    }

    @Test func disabledAtLaunchWidgetIsNeverActivatedOrShown() throws {
        let h = try RegistryHarness(
            [FakeWidget(id: "a", priority: 90, isActive: true), FakeWidget(id: "b", priority: 1, isActive: true)],
            configJSON: #"{"widgets":[{"id":"a","enabled":false},{"id":"b"}]}"#
        )
        h.registry.activateEnabledWidgets()
        h.registry.updateVisibility(state: .peek, selectedTabID: nil)
        #expect(h["a"].activateCount == 0)
        #expect(!(h["a"].visibilityHistory.contains { $0 != .hidden }))
        #expect(h["b"].lastVisibility == .compact)
        h.registry.updateVisibility(state: .expanded, selectedTabID: "a")  // tab of a disabled widget: falls back
        #expect(h["a"].activateCount == 0)
        #expect(h["b"].lastVisibility == .expanded)
    }

    @Test func settingsHandleToleratesGarbageSettingsAndMissingEntries() throws {
        struct S: Codable, Equatable { var n: Int }
        let h = try RegistryHarness([FakeWidget(id: "a")], configJSON: #"{"widgets":[{"id":"a","settings":{"n":"not a number"}}]}"#)
        let handle = WidgetSettingsHandle(widgetID: "a", store: h.store)
        #expect(handle.load(S.self) == nil)
        handle.save(S(n: 3))
        #expect(handle.load(S.self) == S(n: 3))
        let ghost = WidgetSettingsHandle(widgetID: "ghost", store: h.store)
        #expect(ghost.load(S.self) == nil)
        ghost.save(S(n: 1))   // must not crash or create an entry
        #expect(!h.store.document.widgets.contains { $0.id == "ghost" })
    }
}

/// Deterministic PRNG so "random" tests are reproducible.
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
