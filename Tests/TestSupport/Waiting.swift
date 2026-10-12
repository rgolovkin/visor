import Testing

/// Waits for a condition instead of sleeping a fixed time: fast when things are fast, and only fails
/// when the deadline (generous, for loaded CI machines) is exceeded.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(3),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline {
            Issue.record("Condition not met within \(timeout)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// Sleep replacement for `NotchViewModel`: delays complete only when the test calls `advance()`.
@MainActor
final class ManualSleeper {
    private var waiters: [(delay: Duration, continuation: CheckedContinuation<Void, Never>)] = []

    var pendingDelays: [Duration] { waiters.map(\.delay) }

    func sleep(_ delay: Duration) async throws {
        await withCheckedContinuation { waiters.append((delay, $0)) }
    }

    /// Completes every pending delay (including ones whose task was cancelled: the view model must
    /// ignore those by token / cancellation).
    func advance() {
        let current = waiters
        waiters = []
        for waiter in current {
            waiter.continuation.resume()
        }
    }
}
