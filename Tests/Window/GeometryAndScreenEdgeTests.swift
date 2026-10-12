import AppKit
import CoreGraphics
import Testing
@testable import NotchApp

/// Edge cases for ScreenResolver / NotchGeometry / ScreenManager (AC-1, AC-2, AC-12).
struct ScreenResolverEdgeTests {
    @Test(arguments: [DisplayMode.auto, .primary, .notch, .display])
    func noScreensAlwaysResolvesToNil(_ mode: DisplayMode) {
        #expect(ScreenResolver.resolve(screens: [], mode: mode, displayID: "x") == nil)
        #expect(ScreenResolver.resolve(screens: [], mode: mode, displayID: nil) == nil)
    }

    @Test func noPrimaryFlagFallsBackToFirstScreen() {
        let screens = [Screens.external.withPrimary(false), Screens.secondExternal]
        #expect(ScreenResolver.resolve(screens: screens, mode: .primary, displayID: nil)?.id == "external")
        #expect(ScreenResolver.resolve(screens: screens, mode: .auto, displayID: nil)?.id == "external")
    }

    @Test func displayModeWithoutIdFallsBackToPrimary() {
        let screens = [Screens.builtInNotch, Screens.external]
        #expect(ScreenResolver.resolve(screens: screens, mode: .display, displayID: nil)?.id == "builtin")
        #expect(ScreenResolver.resolve(screens: screens, mode: .display, displayID: "")?.id == "builtin")
        #expect(ScreenResolver.resolve(screens: screens, mode: .display, displayID: "external")?.id == "external")
    }

    @Test func autoWithoutNotchPicksPrimaryNotJustFirst() {
        let screens = [Screens.secondExternal, Screens.externalPrimary]
        #expect(ScreenResolver.resolve(screens: screens, mode: .auto, displayID: nil)?.id == "external")
    }

    @Test func notchScreenInClamshellWithOnlyExternalFallsBack() {
        #expect(ScreenResolver.resolve(screens: [Screens.externalPrimary], mode: .notch, displayID: nil)?.id == "external")
    }

    @Test func incompleteNotchInfoIsNotTreatedAsNotch() {
        var s = Screens.builtInNotch
        s = ScreenInfo(id: s.id, name: s.name, frame: s.frame, visibleFrame: s.visibleFrame, safeAreaTop: 32,
                       auxiliaryTopLeftWidth: nil, auxiliaryTopRightWidth: 600, isPrimary: true)
        #expect(!s.hasNotch)
        let g = NotchGeometry.make(for: s)
        #expect(!g.isPhysicalNotch)
        #expect(g.collapsedRect.width >= NotchGeometry.pillMinSize.width)
    }
}

struct NotchGeometryEdgeTests {
    static let allScreens: [ScreenInfo] = [
        Screens.builtInNotch, Screens.external, Screens.externalPrimary, Screens.secondExternal,
        // Display stacked above the primary one (non-zero positive y origin).
        ScreenInfo(id: "above", name: "Above", frame: CGRect(x: 0, y: 982, width: 1920, height: 1080),
                   visibleFrame: CGRect(x: 0, y: 982, width: 1920, height: 1055), safeAreaTop: 0,
                   auxiliaryTopLeftWidth: nil, auxiliaryTopRightWidth: nil, isPrimary: false),
        // 16" MBP default scaled mode.
        ScreenInfo(id: "mbp16", name: "MBP16", frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                   visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085), safeAreaTop: 32,
                   auxiliaryTopLeftWidth: 772, auxiliaryTopRightWidth: 772, isPrimary: true),
        // Small-resolution scaled mode: the notch grows (safeAreaInsets changes with scaling).
        ScreenInfo(id: "mbp14-scaled", name: "MBP14s", frame: CGRect(x: 0, y: 0, width: 1352, height: 878),
                   visibleFrame: CGRect(x: 0, y: 0, width: 1352, height: 846), safeAreaTop: 32,
                   auxiliaryTopLeftWidth: 585.5, auxiliaryTopRightWidth: 585.5, isPrimary: true),
    ]

    @Test(arguments: NotchGeometryEdgeTests.allScreens)
    func shapesAreNestedTopAlignedAndInsideTheScreenHorizontallyAndVertically(_ screen: ScreenInfo) {
        let g = NotchGeometry.make(for: screen)
        for rect in [g.collapsedRect, g.peekRect, g.expandedRect] {
            #expect(rect.maxY == screen.frame.maxY, "top-aligned: \(rect)")
            #expect(rect.minX >= screen.frame.minX && rect.maxX <= screen.frame.maxX)
            #expect(rect.minY >= screen.frame.minY)
            #expect(rect.width > 0 && rect.height > 0)
        }
        #expect(g.peekRect.contains(g.collapsedRect))
        #expect(g.expandedRect.contains(g.collapsedRect))
        #expect(g.expandedRect.width >= 520 && g.expandedRect.height >= 200)
        #expect(g.screenID == screen.id)
    }

    // AC-1: offset from the real notch must be <= 1 pt on every edge, including fractional aux widths.
    @Test(arguments: [Screens.builtInNotch, NotchGeometryEdgeTests.allScreens[5], NotchGeometryEdgeTests.allScreens[6]])
    func collapsedRectMatchesPhysicalNotchWithinOnePoint(_ screen: ScreenInfo) {
        let g = NotchGeometry.make(for: screen)
        let exactMinX = screen.frame.minX + screen.auxiliaryTopLeftWidth!
        let exactMaxX = screen.frame.maxX - screen.auxiliaryTopRightWidth!
        let exactMinY = screen.frame.maxY - screen.safeAreaTop
        #expect(abs(g.collapsedRect.minX - exactMinX) <= 1)
        #expect(abs(g.collapsedRect.maxX - exactMaxX) <= 1)
        #expect(abs(g.collapsedRect.minY - exactMinY) <= 1)
        #expect(abs(g.collapsedRect.maxY - screen.frame.maxY) <= 1)
        #expect(g.isPhysicalNotch)
    }

    // Peek/expanded bug: every resting rect and every grow-phase union must share the notch center,
    // otherwise one side of the shape jumps when the window frame changes.
    @Test(arguments: NotchGeometryEdgeTests.allScreens)
    func allStateRectsAndTransitionUnionsAreCenteredOnTheNotch(_ screen: ScreenInfo) {
        let g = NotchGeometry.make(for: screen)
        let states: [NotchState] = [.collapsed, .peek, .expanded]
        for from in states {
            for to in states {
                let union = g.rect(for: from).union(g.rect(for: to))
                #expect(abs(union.midX - g.collapsedRect.midX) <= 0.5, "\(from) -> \(to): \(union)")
                #expect(g.canvasRect.contains(union))
            }
        }
        #expect(abs(g.canvasRect.midX - g.collapsedRect.midX) <= 0.5)
        #expect(g.canvasRect.maxY == screen.frame.maxY)
    }

    @Test func geometryIsDeterministicAndChangesWithScaling() {
        let a = NotchGeometry.make(for: Self.allScreens[5])
        #expect(a == NotchGeometry.make(for: Self.allScreens[5]))
        #expect(a != NotchGeometry.make(for: Self.allScreens[6]))
    }

    @Test func pillIsAtLeastTheHoverZoneAndCenteredOnExternalMonitors() {
        for screen in [Screens.external, Screens.externalPrimary, Screens.secondExternal, Self.allScreens[4]] {
            let g = NotchGeometry.make(for: screen)
            #expect(g.collapsedRect.width >= 200 && g.collapsedRect.height >= 24)
            #expect(abs(g.collapsedRect.midX - screen.frame.midX) <= 1)
            #expect(!g.isPhysicalNotch)
        }
    }

    @Test func rectForStateMapsCorrectly() {
        let g = NotchGeometry.make(for: Screens.builtInNotch)
        #expect(g.rect(for: .collapsed) == g.collapsedRect)
        #expect(g.rect(for: .peek) == g.peekRect)
        #expect(g.rect(for: .expanded) == g.expandedRect)
    }

    @Test func customExpandedSizeIsRespected() {
        let g = NotchGeometry.make(for: Screens.builtInNotch, expandedSize: CGSize(width: 640, height: 300))
        #expect(g.expandedRect.width == 640)
        #expect(g.expandedRect.height == 300 + g.collapsedRect.height)
    }
}

@MainActor
struct ScreenManagerEdgeTests {
    private func manager(_ box: Box<[ScreenInfo]>, delay: Duration = .milliseconds(20)) -> ScreenManager {
        ScreenManager(provider: { box.value }, coalesceDelay: delay)
    }

    @Test func noScreensGivesNilGeometryAndReportsOnlyTransitions() {
        let screens = Box<[ScreenInfo]>([])
        let m = manager(screens)
        var reports: [NotchGeometry?] = []
        m.onChange = { reports.append($0) }

        m.apply(mode: .auto, displayID: nil)
        #expect(m.geometry == nil && m.current == nil)
        #expect(reports.isEmpty)   // nil -> nil is not a change

        screens.value = [Screens.builtInNotch]
        m.refresh()
        m.refresh()
        #expect(reports.count == 1 && reports[0] != nil)

        screens.value = []
        m.refresh()
        #expect(reports.count == 2 && reports[1] == nil)
    }

    @Test func targetScreenDisappearsThenReturns() {
        let screens = Box([Screens.builtInNotch, Screens.external])
        let m = manager(screens)
        m.apply(mode: .display, displayID: "external")
        #expect(m.current?.id == "external")

        screens.value = [Screens.builtInNotch]
        m.refresh()
        #expect(m.current?.id == "builtin")   // fell back to the primary

        screens.value = [Screens.builtInNotch, Screens.external]
        m.refresh()
        #expect(m.current?.id == "external")  // preference survived the outage
    }

    @Test func resolutionChangeOnSameScreenIsReported() {
        let screens = Box([Screens.builtInNotch])
        let m = manager(screens)
        var reports = 0
        m.onChange = { _ in reports += 1 }
        m.apply(mode: .auto, displayID: nil)
        let before = reports
        screens.value = [NotchGeometryEdgeTests_scaled()]
        m.refresh()
        #expect(reports == before + 1)
    }

    @Test func burstOfScreenNotificationsIsCoalescedIntoOneRefresh() async throws {
        let center = NotificationCenter()
        var providerCalls = 0
        let screens = Box([Screens.builtInNotch])
        let m = ScreenManager(provider: { providerCalls += 1; return screens.value }, coalesceDelay: .milliseconds(40))
        m.startObserving(center: center)
        m.startObserving(center: center)   // idempotent
        for _ in 0..<20 { center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil) }
        #expect(providerCalls == 0)
        await waitUntil { providerCalls >= 1 }
        try await Task.sleep(for: .milliseconds(150))
        #expect(providerCalls == 1)
    }

    @Test func stopObservingCancelsPendingRefreshAndIgnoresLaterNotifications() async throws {
        let center = NotificationCenter()
        var providerCalls = 0
        let m = ScreenManager(provider: { providerCalls += 1; return [Screens.builtInNotch] }, coalesceDelay: .milliseconds(30))
        m.startObserving(center: center)
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        m.stopObserving()
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await Task.sleep(for: .milliseconds(120))
        #expect(providerCalls == 0)
    }

    // AC-12: reposition within 1 s with the production coalescing delay.
    @Test func defaultCoalescingFitsTheOneSecondBudget() async throws {
        let center = NotificationCenter()
        let screens = Box([Screens.builtInNotch])
        let m = ScreenManager(provider: { screens.value })
        m.apply(mode: .auto, displayID: nil)
        m.startObserving(center: center)
        screens.value = [Screens.external.withPrimary(true)]
        let started = ContinuousClock.now
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await waitUntil(timeout: .seconds(2)) { m.current?.id == "external" }
        #expect(ContinuousClock.now - started < .milliseconds(700))
        m.stopObserving()
    }

    private func NotchGeometryEdgeTests_scaled() -> ScreenInfo {
        ScreenInfo(id: "builtin", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1352, height: 878),
                   visibleFrame: CGRect(x: 0, y: 0, width: 1352, height: 846), safeAreaTop: 32,
                   auxiliaryTopLeftWidth: 585.5, auxiliaryTopRightWidth: 585.5, isPrimary: true)
    }
}

@MainActor
struct ViewModelScreenSwitchEdgeTests {
    @Test func geometryBecomingNilAndBackKeepsModelUsable() throws {
        let h = try RegistryHarness([FakeWidget(id: "a", priority: 1, isActive: true)])
        h.registry.activateEnabledWidgets()
        let model = NotchViewModel(registry: h.registry, reduceMotion: { false })
        var requests: [NotchLayoutRequest] = []
        model.onLayoutChange = { requests.append($0) }
        model.updateGeometry(NotchGeometry.make(for: Screens.builtInNotch))
        model.send(.clicked)
        #expect(model.state == .expanded)

        model.updateGeometry(nil)
        #expect(model.state == .peek)
        let before = requests.count
        model.send(.clicked)                       // no geometry: must not crash or emit frames
        #expect(requests.count == before)

        model.updateGeometry(NotchGeometry.make(for: Screens.external))
        #expect(requests.last?.phase == .immediate)
    }
}
