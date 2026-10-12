import Observation
import SwiftUI

struct WidgetItem {
    let widget: any NotchWidget
    var enabled: Bool
}

/// Single owner of widget lifecycle: enabling, order, activation and visibility.
/// Everything runs synchronously on the main actor, so fast on/off toggles cannot race.
@MainActor
@Observable
final class WidgetRegistry {
    private(set) var items: [WidgetItem] = []

    @ObservationIgnored private let store: ConfigStore
    @ObservationIgnored private let catalog: [WidgetDescriptor]
    @ObservationIgnored private var activatedIDs: Set<String> = []
    @ObservationIgnored private var visibilities: [String: WidgetVisibility] = [:]
    @ObservationIgnored private var lastState: NotchState = .collapsed
    @ObservationIgnored private var lastSelectedTabID: String?

    init(store: ConfigStore, catalog: [WidgetDescriptor], makeContext: @MainActor (String) -> WidgetContext) {
        self.store = store
        self.catalog = catalog
        reconcileConfig()
        let widgets = catalog.map { $0.make(makeContext($0.id)) }
        items = Self.orderedItems(widgets: widgets, entries: store.document.widgets)
    }

    var enabledWidgets: [any NotchWidget] {
        items.filter(\.enabled).map(\.widget)
    }

    var peekWinner: (any NotchWidget)? {
        let enabled = enabledWidgets
        let candidates = enabled.enumerated().map { index, widget in
            PeekCandidate(id: widget.id, priority: widget.priority, isActive: widget.isActive, order: index)
        }
        guard let id = PeekResolver.winner(candidates) else { return nil }
        return enabled.first { $0.id == id }
    }

    func widget(id: String) -> (any NotchWidget)? {
        items.first { $0.widget.id == id }?.widget
    }

    /// Selected tab if it is still enabled, otherwise the first enabled widget.
    func resolvedTabID(_ selected: String?) -> String? {
        let enabled = enabledWidgets
        if let selected, enabled.contains(where: { $0.id == selected }) {
            return selected
        }
        return enabled.first?.id
    }

    func activateEnabledWidgets() {
        for item in items where item.enabled {
            activate(item.widget, reason: .launch)
        }
    }

    func deactivateAll() {
        for item in items {
            setVisibility(.hidden, for: item.widget)
            deactivate(item.widget)
        }
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = items.firstIndex(where: { $0.widget.id == id }),
              items[index].enabled != enabled else { return }
        items[index].enabled = enabled
        store.update { document in
            if let entry = document.widgets.firstIndex(where: { $0.id == id }) {
                document.widgets[entry].enabled = enabled
            }
        }
        let widget = items[index].widget
        if enabled {
            activate(widget, reason: .userEnabled)
        } else {
            setVisibility(.hidden, for: widget)
            deactivate(widget)
        }
        refreshVisibility()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = items
        reordered.move(fromOffsets: source, toOffset: destination)
        guard reordered.map(\.widget.id) != items.map(\.widget.id) else { return }
        items = reordered
        persistOrder()
        refreshVisibility()
    }

    func moveUp(_ id: String) {
        guard let index = items.firstIndex(where: { $0.widget.id == id }), index > 0 else { return }
        move(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
    }

    func moveDown(_ id: String) {
        guard let index = items.firstIndex(where: { $0.widget.id == id }), index < items.count - 1 else { return }
        move(fromOffsets: IndexSet(integer: index), toOffset: index + 2)
    }

    /// Re-applies order/enabled state from the (already reset) config document.
    func resetToDefaults() {
        reconcileConfig()
        let newItems = Self.orderedItems(widgets: items.map(\.widget), entries: store.document.widgets)
        let wasEnabled = Dictionary(uniqueKeysWithValues: items.map { ($0.widget.id, $0.enabled) })
        items = newItems
        for item in newItems where wasEnabled[item.widget.id] != item.enabled {
            if item.enabled {
                activate(item.widget, reason: .userEnabled)
            } else {
                setVisibility(.hidden, for: item.widget)
                deactivate(item.widget)
            }
        }
        for item in newItems {
            item.widget.reloadSettings()
        }
        refreshVisibility()
    }

    func flushAll() {
        for item in items {
            item.widget.flush()
        }
    }

    func updateVisibility(state: NotchState, selectedTabID: String?) {
        lastState = state
        lastSelectedTabID = selectedTabID
        refreshVisibility()
    }

    private func refreshVisibility() {
        let peekID = lastState == .peek ? peekWinner?.id : nil
        let tabID = lastState == .expanded ? resolvedTabID(lastSelectedTabID) : nil
        for item in items {
            let id = item.widget.id
            let visibility: WidgetVisibility
            if !item.enabled {
                visibility = .hidden
            } else if id == tabID {
                visibility = .expanded
            } else if id == peekID {
                visibility = .compact
            } else {
                visibility = .hidden
            }
            setVisibility(visibility, for: item.widget)
        }
    }

    private func setVisibility(_ visibility: WidgetVisibility, for widget: any NotchWidget) {
        let current = visibilities[widget.id] ?? .hidden
        guard current != visibility else { return }
        visibilities[widget.id] = visibility
        widget.visibilityDidChange(visibility)
    }

    private func activate(_ widget: any NotchWidget, reason: ActivationReason) {
        guard activatedIDs.insert(widget.id).inserted else { return }
        Log.widgets.debug("Activating \(widget.id, privacy: .public)")
        widget.activate(reason: reason)
    }

    private func deactivate(_ widget: any NotchWidget) {
        guard activatedIDs.remove(widget.id) != nil else { return }
        Log.widgets.debug("Deactivating \(widget.id, privacy: .public)")
        widget.deactivate()
    }

    private func reconcileConfig() {
        let catalog = self.catalog
        store.update { document in
            document.widgets = WidgetOrder.reconcile(entries: document.widgets, catalog: catalog)
        }
    }

    private func persistOrder() {
        let knownIDs = Set(items.map(\.widget.id))
        let order = items.map(\.widget.id)
        store.update { document in
            document.widgets = WidgetOrder.reorder(entries: document.widgets, knownIDs: knownIDs, newKnownOrder: order)
        }
    }

    private static func orderedItems(widgets: [any NotchWidget], entries: [WidgetConfigEntry]) -> [WidgetItem] {
        let byID = Dictionary(uniqueKeysWithValues: widgets.map { ($0.id, $0) })
        var result: [WidgetItem] = []
        var placed = Set<String>()
        for entry in entries {
            guard let widget = byID[entry.id], placed.insert(entry.id).inserted else { continue }
            result.append(WidgetItem(widget: widget, enabled: entry.enabled))
        }
        for widget in widgets where !placed.contains(widget.id) {
            result.append(WidgetItem(widget: widget, enabled: true))
        }
        return result
    }
}
