import AppKit
import Observation

/// Tracks connected screens and picks the one that hosts the notch.
@MainActor
@Observable
final class ScreenManager {
    private(set) var screens: [ScreenInfo] = []
    private(set) var current: ScreenInfo?
    private(set) var geometry: NotchGeometry?

    @ObservationIgnored var onChange: (@MainActor (NotchGeometry?) -> Void)?
    @ObservationIgnored private let provider: @MainActor () -> [ScreenInfo]
    @ObservationIgnored private var mode: DisplayMode = .auto
    @ObservationIgnored private var displayID: String?
    @ObservationIgnored private var observation: NotificationObservation?
    @ObservationIgnored private let coalescer = OneShotScheduler()
    @ObservationIgnored private let coalesceDelay: Duration

    init(
        provider: @escaping @MainActor () -> [ScreenInfo] = { ScreenInfo.current() },
        coalesceDelay: Duration = .milliseconds(200)
    ) {
        self.provider = provider
        self.coalesceDelay = coalesceDelay
    }

    func startObserving(center: NotificationCenter = .default) {
        guard observation == nil else { return }
        // Connecting a display posts a burst of notifications; recompute once after it settles.
        observation = NotificationObservation(
            center: center,
            name: NSApplication.didChangeScreenParametersNotification
        ) { [weak self] in
            guard let self else { return }
            self.coalescer.schedule(after: self.coalesceDelay, tolerance: .milliseconds(50)) { [weak self] in
                self?.refresh()
            }
        }
    }

    func stopObserving() {
        observation?.cancel()
        observation = nil
        coalescer.cancel()
    }

    func apply(mode: DisplayMode, displayID: String?) {
        self.mode = mode
        self.displayID = displayID
        refresh()
    }

    func refresh() {
        screens = provider()
        let resolved = ScreenResolver.resolve(screens: screens, mode: mode, displayID: displayID)
        current = resolved
        let newGeometry = resolved.map { NotchGeometry.make(for: $0) }
        if resolved == nil {
            Log.window.warning("No screens available")
        }
        guard newGeometry != geometry else { return }
        geometry = newGeometry
        Log.window.info("Notch screen: \(resolved?.name ?? "none", privacy: .public), physical notch: \(resolved?.hasNotch ?? false)")
        onChange?(newGeometry)
    }
}
