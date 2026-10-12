import SwiftUI

/// Differs from the original sketch (ADR-003): the protocol is `@MainActor` because widgets are
/// observable models read by SwiftUI on the main thread, and `Identifiable` is replaced by a
/// `nonisolated var id` because a main-actor `id` cannot satisfy Identifiable's nonisolated requirement.
@MainActor
protocol NotchWidget: AnyObject {
    nonisolated var id: String { get }
    var title: String { get }
    var symbolName: String { get }
    /// Larger wins the peek slot (scale fixed in TASK-001).
    var priority: Int { get }
    /// Must be an observable property: the core never polls it.
    var isActive: Bool { get }

    func makeCompactView() -> AnyView
    func makeExpandedView() -> AnyView
    func makeSettingsView() -> AnyView?

    /// Resources (timers, observers, network) may only be held between `activate` and `deactivate`.
    func activate(reason: ActivationReason)
    func deactivate()
    /// Called only when the value actually changes.
    func visibilityDidChange(_ visibility: WidgetVisibility)
    func reloadSettings()
    /// Synchronously persist widget data files (quit, collapse).
    func flush()
    var deactivationWarning: String? { get }
}

extension NotchWidget {
    func makeSettingsView() -> AnyView? { nil }
    func visibilityDidChange(_ visibility: WidgetVisibility) {}
    func reloadSettings() {}
    func flush() {}
    var deactivationWarning: String? { nil }
}
