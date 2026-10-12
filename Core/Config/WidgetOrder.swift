import Foundation

enum WidgetOrder {
    /// Reorders known entries according to `newKnownOrder`; entries with unknown ids keep their
    /// index "slots", so ids from newer app versions do not drift around (ADR-002).
    static func reorder(
        entries: [WidgetConfigEntry],
        knownIDs: Set<String>,
        newKnownOrder: [String]
    ) -> [WidgetConfigEntry] {
        let knownSlots = entries.indices.filter { knownIDs.contains(entries[$0].id) }
        var knownByID: [String: WidgetConfigEntry] = [:]
        for index in knownSlots {
            knownByID[entries[index].id] = entries[index]
        }

        var ordered: [WidgetConfigEntry] = []
        for id in newKnownOrder {
            if let entry = knownByID.removeValue(forKey: id) {
                ordered.append(entry)
            }
        }
        for index in knownSlots where knownByID[entries[index].id] != nil {
            ordered.append(entries[index])
        }

        var result = entries
        for (slot, entry) in zip(knownSlots, ordered) {
            result[slot] = entry
        }
        return result
    }
}

extension WidgetOrder {
    /// Appends catalog widgets that are missing from the config (new in this app version).
    static func reconcile(entries: [WidgetConfigEntry], catalog: [WidgetDescriptor]) -> [WidgetConfigEntry] {
        let present = Set(entries.map(\.id))
        let missing = catalog
            .filter { !present.contains($0.id) }
            .map { WidgetConfigEntry(id: $0.id, enabled: $0.defaultEnabled) }
        return entries + missing
    }
}
