import Foundation
import Observation
import SwiftUI

/// Test widget for the core. Ticks on the next minute boundary while compact, on the next second
/// while expanded, and not at all while hidden (ADR-005).
@MainActor
@Observable
final class ClockWidget: NotchWidget {
    nonisolated var id: String { WidgetID.clock }
    var title: String { String(localized: "Clock") }
    let symbolName = "clock"
    let priority = 10
    /// The clock always has something to show; it only stops being in peek when disabled.
    private(set) var isActive = true
    private(set) var now: Date

    @ObservationIgnored private let context: WidgetContext
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private let calendar: @MainActor () -> Calendar
    @ObservationIgnored private let scheduler = OneShotScheduler()
    @ObservationIgnored private var subscription: SystemEventsSubscription?
    @ObservationIgnored private var visibility: WidgetVisibility = .hidden
    @ObservationIgnored private(set) var isRunning = false

    init(
        context: WidgetContext,
        clock: @escaping @MainActor () -> Date = { Date() },
        calendar: @escaping @MainActor () -> Calendar = { Calendar.autoupdatingCurrent }
    ) {
        self.context = context
        self.clock = clock
        self.calendar = calendar
        self.now = clock()
    }

    var isTickScheduled: Bool { scheduler.isScheduled }
    var scheduledTickDelay: Duration? { scheduler.scheduledDelay }

    func makeCompactView() -> AnyView { AnyView(ClockCompactView(widget: self)) }
    func makeExpandedView() -> AnyView { AnyView(ClockExpandedView(widget: self)) }

    func activate(reason: ActivationReason) {
        guard !isRunning else { return }
        isRunning = true
        subscription = context.systemEvents.subscribe([.wake, .clockChanged, .timeZoneChanged, .dayChanged]) { [weak self] kind in
            if kind == .timeZoneChanged {
                NSTimeZone.resetSystemTimeZone()
            }
            self?.tick()
        }
        tick()
    }

    func deactivate() {
        isRunning = false
        scheduler.cancel()
        subscription?.cancel()
        subscription = nil
    }

    func visibilityDidChange(_ visibility: WidgetVisibility) {
        self.visibility = visibility
        tick()
    }

    private func tick() {
        guard isRunning else { return }
        now = clock()
        switch visibility {
        case .hidden:
            scheduler.cancel()
        case .compact:
            let next = ClockTicker.nextMinuteBoundary(after: now, calendar: calendar())
            scheduler.schedule(at: next, relativeTo: now, tolerance: .seconds(1)) { [weak self] in self?.tick() }
        case .expanded:
            let next = ClockTicker.nextSecondBoundary(after: now)
            scheduler.schedule(at: next, relativeTo: now, tolerance: .milliseconds(100)) { [weak self] in self?.tick() }
        }
    }
}
