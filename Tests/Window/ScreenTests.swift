import CoreGraphics
import Testing
@testable import NotchApp

enum Screens {
    /// 14" MacBook Pro: 1512×982 pt, notch 185×32 pt.
    static let builtInNotch = ScreenInfo(
        id: "builtin", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950), safeAreaTop: 32,
        auxiliaryTopLeftWidth: 663.5, auxiliaryTopRightWidth: 663.5, isPrimary: true
    )
    static let external = ScreenInfo(
        id: "external", name: "LG", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415), safeAreaTop: 0,
        auxiliaryTopLeftWidth: nil, auxiliaryTopRightWidth: nil, isPrimary: false
    )
    static let externalPrimary = ScreenInfo(
        id: "external", name: "LG", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415), safeAreaTop: 0,
        auxiliaryTopLeftWidth: nil, auxiliaryTopRightWidth: nil, isPrimary: true
    )
    static let secondExternal = ScreenInfo(
        id: "second", name: "Dell", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), safeAreaTop: 0,
        auxiliaryTopLeftWidth: nil, auxiliaryTopRightWidth: nil, isPrimary: false
    )
}

struct ScreenResolverTests {
    @Test(arguments: [DisplayMode.auto, .notch])
    func notchAndExternalPicksNotchScreen(_ mode: DisplayMode) {
        let screens = [Screens.external, Screens.builtInNotch]
        #expect(ScreenResolver.resolve(screens: screens, mode: mode, displayID: nil)?.id == "builtin")
    }

    @Test func primaryModePicksMenuBarScreen() {
        let screens = [Screens.builtInNotch, Screens.external]
        let externalAsPrimary = [Screens.externalPrimary, Screens.builtInNotch.withPrimary(false)]
        #expect(ScreenResolver.resolve(screens: screens, mode: .primary, displayID: nil)?.id == "builtin")
        #expect(ScreenResolver.resolve(screens: externalAsPrimary, mode: .primary, displayID: nil)?.id == "external")
    }

    @Test(arguments: [DisplayMode.auto, .notch, .primary])
    func clamshellWithoutBuiltInFallsBackToPrimary(_ mode: DisplayMode) {
        let screens = [Screens.externalPrimary, Screens.secondExternal]
        #expect(ScreenResolver.resolve(screens: screens, mode: mode, displayID: nil)?.id == "external")
    }

    @Test func displayModePicksRequestedScreen() {
        let screens = [Screens.builtInNotch, Screens.external, Screens.secondExternal]
        #expect(ScreenResolver.resolve(screens: screens, mode: .display, displayID: "second")?.id == "second")
    }

    // AC-12
    @Test func displayModeWithMissingScreenFallsBackToPrimary() {
        let screens = [Screens.builtInNotch, Screens.external]
        #expect(ScreenResolver.resolve(screens: screens, mode: .display, displayID: "gone")?.id == "builtin")
        #expect(ScreenResolver.resolve(screens: screens, mode: .display, displayID: nil)?.id == "builtin")
    }

    @Test func noScreensResolvesToNil() {
        #expect(ScreenResolver.resolve(screens: [], mode: .auto, displayID: nil) == nil)
    }
}

struct NotchGeometryTests {
    // AC-1
    @Test func physicalNotchRectComesFromAuxiliaryAreas() {
        let g = NotchGeometry.make(for: Screens.builtInNotch)
        #expect(g.isPhysicalNotch)
        #expect(g.collapsedRect == CGRect(x: 663, y: 950, width: 186, height: 32))
        #expect(abs(g.notchWidth - 185) < 0.01)
        #expect(g.collapsedRect.maxY == Screens.builtInNotch.frame.maxY)
    }

    // AC-2
    @Test func pillOnScreenWithoutNotchIsCenteredAndLargeEnough() {
        let g = NotchGeometry.make(for: Screens.external)
        #expect(!g.isPhysicalNotch)
        #expect(g.collapsedRect.width >= 200)
        #expect(g.collapsedRect.height >= 24)
        #expect(g.collapsedRect.midX == Screens.external.frame.midX)
        #expect(g.collapsedRect.maxY == Screens.external.frame.maxY)
        #expect(g.collapsedRect.height == 25)
    }

    @Test func pillKeepsMinimumHeightWhenMenuBarIsHidden() {
        let g = NotchGeometry.make(for: Screens.secondExternal)
        #expect(g.collapsedRect.size == CGSize(width: 200, height: 24))
    }

    @Test(arguments: [Screens.builtInNotch, Screens.external, Screens.secondExternal])
    func peekAndExpandedAreCenteredOnNotchAndTopAligned(_ screen: ScreenInfo) {
        let g = NotchGeometry.make(for: screen)
        for rect in [g.peekRect, g.expandedRect] {
            #expect(abs(rect.midX - g.collapsedRect.midX) <= 1)
            #expect(rect.maxY == screen.frame.maxY)
        }
        #expect(g.peekRect.height == g.collapsedRect.height)
        #expect(g.peekRect.width >= g.collapsedRect.width + 2 * 96 - 1)
        #expect(g.expandedRect.width == 520)
        #expect(g.expandedRect.height == g.collapsedRect.height + 200)
        #expect(g.expandedRect.contains(g.peekRect))
        #expect(g.peekRect.contains(g.collapsedRect))
    }
}

extension ScreenInfo {
    func withPrimary(_ primary: Bool) -> ScreenInfo {
        ScreenInfo(
            id: id, name: name, frame: frame, visibleFrame: visibleFrame, safeAreaTop: safeAreaTop,
            auxiliaryTopLeftWidth: auxiliaryTopLeftWidth, auxiliaryTopRightWidth: auxiliaryTopRightWidth,
            isPrimary: primary
        )
    }
}

@MainActor
struct ScreenManagerTests {
    @Test func reportsGeometryChangesOnlyWhenTheyHappen() {
        let screens = Box([Screens.builtInNotch, Screens.external])
        let manager = ScreenManager(provider: { screens.value })
        var reported: [String?] = []
        manager.onChange = { reported.append($0?.screenID) }

        manager.apply(mode: .auto, displayID: nil)
        manager.refresh()
        manager.apply(mode: .display, displayID: "external")
        screens.value = [Screens.builtInNotch]
        manager.refresh()
        screens.value = []
        manager.refresh()
        #expect(reported == ["builtin", "external", "builtin", nil])
    }
}
