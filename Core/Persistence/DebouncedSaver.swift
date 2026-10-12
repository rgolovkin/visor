import Foundation

@MainActor
final class DebouncedSaver {
    private let delay: Duration
    private let save: @MainActor () -> Void
    private var pending: Task<Void, Never>?
    private(set) var isDirty = false

    init(delay: Duration, save: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.save = save
    }

    deinit {
        pending?.cancel()
    }

    func markDirty() {
        isDirty = true
        pending?.cancel()
        let delay = self.delay
        pending = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay, tolerance: .milliseconds(50))
            } catch {
                return
            }
            self?.fire()
        }
    }

    /// Writes synchronously if there are unsaved changes (used on quit).
    func flush() {
        pending?.cancel()
        pending = nil
        guard isDirty else { return }
        fire()
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }

    private func fire() {
        pending = nil
        isDirty = false
        save()
    }
}
