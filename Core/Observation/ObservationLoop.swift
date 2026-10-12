import Observation

/// Bridges `@Observable` state to imperative (AppKit) code: calls `onChange` after each change of the
/// value produced by `read`. Not polling: `withObservationTracking` fires only on writes to the
/// properties that `read` touched, and the loop re-registers after each fire.
@MainActor
final class ObservationLoop<Value: Equatable & Sendable> {
    private let read: @MainActor () -> Value
    private let onChange: @MainActor (Value) -> Void
    private(set) var value: Value
    private var isCancelled = false

    init(read: @escaping @MainActor () -> Value, onChange: @escaping @MainActor (Value) -> Void) {
        self.read = read
        self.onChange = onChange
        self.value = read()
        track()
    }

    func cancel() {
        isCancelled = true
    }

    private func track() {
        let current = withObservationTracking {
            read()
        } onChange: { [weak self] in
            // `onChange` runs in willSet, before the new value is stored; hop to the next main-actor turn to read it.
            Task { @MainActor [weak self] in self?.fire() }
        }
        value = current
    }

    private func fire() {
        guard !isCancelled else { return }
        let previous = value
        track()
        if value != previous {
            onChange(value)
        }
    }
}
