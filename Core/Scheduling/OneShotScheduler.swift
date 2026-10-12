import Foundation

/// A single pending action at the next meaningful moment (ADR-005). Scheduling again replaces the
/// previous action; there are no repeating timers.
@MainActor
final class OneShotScheduler {
    private var task: Task<Void, Never>?
    private var generation = 0
    private(set) var scheduledDelay: Duration?

    var isScheduled: Bool { task != nil }

    deinit {
        task?.cancel()
    }

    func schedule(
        at date: Date,
        relativeTo now: Date = Date(),
        tolerance: Duration,
        _ action: @escaping @MainActor () -> Void
    ) {
        let seconds = max(0, date.timeIntervalSince(now))
        schedule(after: .milliseconds(Int64((seconds * 1000).rounded(.up))), tolerance: tolerance, action)
    }

    func schedule(after delay: Duration, tolerance: Duration, _ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        generation += 1
        let current = generation
        scheduledDelay = delay
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay, tolerance: tolerance)
            } catch {
                return
            }
            guard let self, self.generation == current else { return }
            self.task = nil
            self.scheduledDelay = nil
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        scheduledDelay = nil
        generation += 1
    }
}
