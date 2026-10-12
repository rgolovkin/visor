import Foundation

/// Block-based NotificationCenter observer delivered on the main queue. The `Notification` itself is
/// not forwarded because it is not Sendable.
@MainActor
final class NotificationObservation {
    private let center: NotificationCenter
    private var token: (any NSObjectProtocol)?

    init(
        center: NotificationCenter = .default,
        name: Notification.Name,
        object: AnyObject? = nil,
        handler: @escaping @MainActor () -> Void
    ) {
        self.center = center
        token = center.addObserver(forName: name, object: object, queue: .main) { _ in
            // `queue: .main` guarantees the main thread; `assumeIsolated` tells the compiler so.
            MainActor.assumeIsolated { handler() }
        }
    }

    func cancel() {
        if let token {
            center.removeObserver(token)
        }
        token = nil
    }

    // `isolated deinit` (Swift 6.2, back-deployed to macOS 14) runs on the main actor, so it may touch
    // the non-Sendable token; a plain deinit is nonisolated and cannot.
    isolated deinit {
        if let token {
            center.removeObserver(token)
        }
    }
}
