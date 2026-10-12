import AppKit

/// Shared source of system events. Observers are installed lazily for the first subscriber of a kind
/// and removed with the last one, so an idle app with no subscribers observes nothing.
@MainActor
final class SystemEvents {
    enum Kind: Sendable, Hashable, CaseIterable {
        case wake, willSleep, clockChanged, timeZoneChanged, dayChanged
    }

    private struct Subscriber {
        let kinds: Set<Kind>
        let handler: @MainActor (Kind) -> Void
    }

    private let center: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private var subscribers: [Int: Subscriber] = [:]
    private var nextID = 0
    private var observations: [Kind: NotificationObservation] = [:]

    init(center: NotificationCenter = .default, workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.center = center
        self.workspaceCenter = workspaceCenter
    }

    var observedKinds: Set<Kind> { Set(observations.keys) }

    func subscribe(_ kinds: Set<Kind>, handler: @escaping @MainActor (Kind) -> Void) -> SystemEventsSubscription {
        let id = nextID
        nextID += 1
        subscribers[id] = Subscriber(kinds: kinds, handler: handler)
        updateObservations()
        return SystemEventsSubscription { [weak self] in self?.unsubscribe(id) }
    }

    private func unsubscribe(_ id: Int) {
        guard subscribers.removeValue(forKey: id) != nil else { return }
        updateObservations()
    }

    private func dispatch(_ kind: Kind) {
        for subscriber in subscribers.values where subscriber.kinds.contains(kind) {
            subscriber.handler(kind)
        }
    }

    private func updateObservations() {
        let needed = subscribers.values.reduce(into: Set<Kind>()) { $0.formUnion($1.kinds) }
        for kind in observedKinds.subtracting(needed) {
            observations.removeValue(forKey: kind)?.cancel()
        }
        for kind in needed.subtracting(observedKinds) {
            let (center, name) = source(for: kind)
            observations[kind] = NotificationObservation(center: center, name: name) { [weak self] in
                self?.dispatch(kind)
            }
        }
    }

    private func source(for kind: Kind) -> (NotificationCenter, Notification.Name) {
        switch kind {
        case .wake: (workspaceCenter, NSWorkspace.didWakeNotification)
        case .willSleep: (workspaceCenter, NSWorkspace.willSleepNotification)
        case .clockChanged: (center, .NSSystemClockDidChange)
        case .timeZoneChanged: (center, .NSSystemTimeZoneDidChange)
        case .dayChanged: (center, .NSCalendarDayChanged)
        }
    }
}

@MainActor
final class SystemEventsSubscription {
    private var onCancel: (@MainActor () -> Void)?

    init(onCancel: @escaping @MainActor () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        onCancel?()
        onCancel = nil
    }

    isolated deinit {
        onCancel?()
    }
}
