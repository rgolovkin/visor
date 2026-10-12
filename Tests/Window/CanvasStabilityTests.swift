import AppKit
import Testing
@testable import NotchApp

/// the fixed-canvas fix for "right part jumps left on peek -> expanded".
/// Pure geometry cases plus the real controller/panel driven through the model (no synthetic mouse events;
/// the notch panel briefly appears on screen while these run).
struct CanvasRectGeometryTests {
    static let screens: [ScreenInfo] = NotchGeometryEdgeTests.allScreens + [
        // External display left of and above the primary one: negative x and negative y origin.
        ScreenInfo(id: "neg", name: "Neg", frame: CGRect(x: -2560, y: -400, width: 2560, height: 1440),
                   visibleFrame: CGRect(x: -2560, y: -400, width: 2560, height: 1415), safeAreaTop: 0,
                   auxiliaryTopLeftWidth: nil, auxiliaryTopRightWidth: nil, isPrimary: false),
        // Notch screen that is not at the origin (extended arrangement), narrow notch.
        ScreenInfo(id: "offset-notch", name: "Offset", frame: CGRect(x: 3000, y: 500, width: 1470, height: 956),
                   visibleFrame: CGRect(x: 3000, y: 500, width: 1470, height: 924), safeAreaTop: 32,
                   auxiliaryTopLeftWidth: 640, auxiliaryTopRightWidth: 640, isPrimary: false),
    ]

    @Test(arguments: CanvasRectGeometryTests.screens)
    func canvasIsTheExactUnionTopAlignedCenteredAndOnScreen(_ screen: ScreenInfo) {
        let g = NotchGeometry.make(for: screen)
        let union = g.collapsedRect.union(g.peekRect).union(g.expandedRect)
        #expect(g.canvasRect == union)
        #expect(g.canvasRect.maxY == screen.frame.maxY)
        #expect(screen.frame.contains(g.canvasRect), "canvas \(g.canvasRect) escapes screen \(screen.frame)")
        #expect(abs(g.canvasRect.midX - g.collapsedRect.midX) <= 0.5)
        for r in [g.collapsedRect, g.peekRect, g.expandedRect] { #expect(g.canvasRect.contains(r)) }
    }

    @Test(arguments: [
        CGSize.zero, CGSize(width: 1, height: 1), CGSize(width: -50, height: -50),
        CGSize(width: 520, height: 0), CGSize(width: 0, height: 200), CGSize(width: 900, height: 500),
    ])
    func degenerateExpandedSizesNeverProduceNaNOrEmptyOrUncenteredCanvas(_ size: CGSize) {
        for screen in [Screens.builtInNotch, Screens.external, Screens.secondExternal] {
            let g = NotchGeometry.make(for: screen, expandedSize: size)
            let c = g.canvasRect
            #expect(!c.isNull && !c.isInfinite && !c.isEmpty)
            #expect(c.minX.isFinite && c.maxX.isFinite && c.minY.isFinite && c.maxY.isFinite)
            #expect(c.contains(g.collapsedRect) && c.contains(g.peekRect) && c.contains(g.expandedRect))
            #expect(c.width >= g.peekRect.width && c.height >= g.collapsedRect.height)
            #expect(abs(c.midX - g.collapsedRect.midX) <= 0.5)
        }
    }

    @Test(arguments: [CGFloat(0), 1, 96, 400])
    func sideWidthVariantsStayCentered(_ side: CGFloat) {
        for screen in CanvasRectGeometryTests.screens {
            let g = NotchGeometry.make(for: screen, sideWidth: side)
            #expect(abs(g.canvasRect.midX - g.collapsedRect.midX) <= 0.5)
            #expect(g.canvasRect.contains(g.peekRect))
            if side == 0 { #expect(g.peekRect == g.collapsedRect) }
        }
    }

    @Test func canvasChangesWithScalingAndIsStablePerGeometry() {
        let a = NotchGeometry.make(for: NotchGeometryEdgeTests.allScreens[5])
        let b = NotchGeometry.make(for: NotchGeometryEdgeTests.allScreens[6])
        #expect(a.canvasRect == NotchGeometry.make(for: NotchGeometryEdgeTests.allScreens[5]).canvasRect)
        #expect(a.canvasRect != b.canvasRect)
    }
}

@MainActor
private final class Rig {
    struct Entry {
        let request: NotchLayoutRequest
        let panelFrame: CGRect
        let hostingOnScreen: CGRect
        let canvas: CGRect?
        let state: NotchState
    }

    let harness: RegistryHarness
    let model: NotchViewModel
    let controller: NotchWindowController
    let sleeper = ManualSleeper()
    private(set) var log: [Entry] = []

    var panel: NotchPanel { controller.notchPanel }
    var hosting: NotchHostingView { controller.notchHostingView }
    var hostingOnScreen: CGRect { panel.convertToScreen(hosting.convert(hosting.bounds, to: nil)) }

    init(reduceMotion: Bool = false, peek: Bool = true) throws {
        harness = try RegistryHarness([FakeWidget(id: "a", priority: 1, isActive: peek)])
        harness.registry.activateEnabledWidgets()
        let sleeper = self.sleeper
        model = NotchViewModel(registry: harness.registry, reduceMotion: { reduceMotion }, sleep: { try await sleeper.sleep($0) })
        controller = NotchWindowController(model: model)
        let original = model.onLayoutChange
        model.onLayoutChange = { [unowned self] request in
            original?(request)
            log.append(Entry(request: request, panelFrame: panel.frame, hostingOnScreen: hostingOnScreen,
                             canvas: model.geometry?.canvasRect, state: model.state))
        }
    }

    func show(_ screen: ScreenInfo) { controller.apply(geometry: NotchGeometry.make(for: screen)) }

    /// Completes pending open/close delays once their tasks have reached `sleep`.
    func elapse() async {
        for _ in 0..<20 { await Task.yield() }
        sleeper.advance()
        for _ in 0..<20 { await Task.yield() }
    }

    func settle() async {
        let geometry = model.geometry
        await waitUntil(timeout: .seconds(5)) { geometry.map { self.panel.frame == $0.rect(for: self.model.state) } ?? true }
    }

    func expectInvariants(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!log.isEmpty, sourceLocation: sourceLocation)
        for e in log {
            guard let canvas = e.canvas else { continue }
            #expect(e.hostingOnScreen == canvas, "hosting moved: \(e.hostingOnScreen) vs canvas \(canvas) at \(e.request.phase)", sourceLocation: sourceLocation)
            #expect(e.panelFrame == e.request.frame, sourceLocation: sourceLocation)
            #expect(canvas.contains(e.panelFrame), "window \(e.panelFrame) left canvas \(canvas)", sourceLocation: sourceLocation)
        }
    }
}

@MainActor
struct CanvasStabilityTests {
    @Test(arguments: [false, true])
    func fullCycleCollapsedPeekExpandedPeekCollapsedKeepsHostingStill(_ reduceMotion: Bool) async throws {
        let rig = try Rig(reduceMotion: reduceMotion)
        rig.show(Screens.builtInNotch)
        let geometry = try #require(rig.model.geometry)
        #expect(rig.hostingOnScreen == geometry.canvasRect)

        rig.model.send(.clicked)                       // peek -> expanded
        #expect(rig.model.state == .expanded)
        #expect(rig.panel.frame.contains(geometry.expandedRect))
        #expect(rig.hostingOnScreen == geometry.canvasRect)
        await rig.settle()
        #expect(rig.panel.frame == geometry.expandedRect)

        rig.model.send(.pointerExited)                 // expanded -> peek after delay
        await rig.elapse()
        await rig.settle()
        #expect(rig.panel.frame == geometry.rect(for: rig.model.state))
        #expect(rig.hostingOnScreen == geometry.canvasRect)

        rig.harness["a"].isActive = false              // peek -> collapsed
        await waitUntil(timeout: .seconds(5)) { rig.model.state == .collapsed }
        await rig.settle()
        #expect(rig.panel.frame == geometry.collapsedRect)
        #expect(rig.hostingOnScreen == geometry.canvasRect)

        rig.harness["a"].isActive = true               // collapsed -> peek
        await waitUntil(timeout: .seconds(5)) { rig.model.state == .peek }
        await rig.settle()
        #expect(rig.panel.frame == geometry.peekRect)
        rig.expectInvariants()
        rig.controller.close()
    }

    /// Hit-test / hover zone: at rest the window is exactly the shape, so clicks on the menu bar outside it
    /// are not swallowed; the hover area follows the visible rect.
    @Test(arguments: [false, true])
    func restingWindowEqualsShapeInCollapsedAndPeek(_ peek: Bool) async throws {
        let rig = try Rig(peek: peek)
        rig.show(Screens.builtInNotch)
        let g = try #require(rig.model.geometry)
        await rig.settle()
        #expect(rig.model.state == (peek ? .peek : .collapsed))
        #expect(rig.panel.frame == (peek ? g.peekRect : g.collapsedRect))
        #expect(rig.panel.frame.width < g.canvasRect.width)
        // Hosting view is clipped to the window: nothing of the canvas outside the shape is hit-testable.
        #expect(rig.panel.contentView?.clipsToBounds == true)
        let outside = CGPoint(x: g.canvasRect.minX + 1, y: g.canvasRect.minY + 1)
        if !rig.panel.frame.contains(outside) {
            let inWindow = rig.panel.convertPoint(fromScreen: outside)
            #expect(!(rig.panel.contentView?.bounds.contains(inWindow) ?? false))
        }
        // Tracking area survives frame changes and still uses .inVisibleRect.
        #expect(rig.hosting.hasHoverArea)
        let areas = rig.hosting.trackingAreas.filter { $0.options.contains(.inVisibleRect) && $0.options.contains(.activeAlways) }
        #expect(areas.count == 1)
        rig.model.send(.clicked)
        rig.hosting.updateTrackingAreas()
        #expect(rig.hosting.trackingAreas.filter { $0.options.contains(.inVisibleRect) }.count == 1)
        rig.controller.close()
    }

    @Test(arguments: [false, true])
    func interruptedTransitionsNeverMoveHostingOrEscapeCanvas(_ reduceMotion: Bool) async throws {
        let rig = try Rig(reduceMotion: reduceMotion)
        rig.show(Screens.builtInNotch)
        // Rapid enter/exit/click without waiting for any animation to finish.
        for _ in 0..<5 {
            rig.model.send(.pointerEntered)
            await rig.elapse()
            rig.model.send(.pointerExited)
            rig.model.send(.pointerEntered)
            rig.model.send(.clicked)
            rig.model.send(.pointerExited)
            await rig.elapse()
            rig.model.send(.clicked)
            rig.model.send(.screenChanged)
        }
        await rig.settle()
        rig.expectInvariants()
        let g = try #require(rig.model.geometry)
        #expect(rig.panel.frame == g.rect(for: rig.model.state))
        #expect(rig.log.contains { $0.request.phase == .growBeforeAnimation })
        rig.controller.close()
    }

    @Test(arguments: [false, true])
    func geometryChangeWhilePanelIsOpenRebasesHostingOntoTheNewCanvas(_ reduceMotion: Bool) async throws {
        let rig = try Rig(reduceMotion: reduceMotion)
        rig.show(Screens.builtInNotch)
        rig.model.send(.clicked)
        #expect(rig.model.state == .expanded)

        let targets: [ScreenInfo] = [
            NotchGeometryEdgeTests.allScreens[6],          // scaled mode, same screen id? no: different id
            Screens.external, Screens.secondExternal,      // other display, positive then negative coords
            CanvasRectGeometryTests.screens[7],            // negative x and y
            Screens.builtInNotch,
        ]
        for target in targets {
            rig.model.send(.clicked)                       // may reopen after screenChanged closes it
            rig.show(target)
            let g = try #require(rig.model.geometry)
            #expect(rig.hostingOnScreen == g.canvasRect, "after switching to \(target.id)")
            #expect(g.canvasRect.contains(rig.panel.frame))
            #expect(rig.panel.frame == g.rect(for: rig.model.state))
            await rig.settle()
            #expect(rig.hostingOnScreen == g.canvasRect)
        }
        // Same screen id, different scale while expanded (resolution change, no screenChanged event).
        rig.model.send(.clicked)
        var scaled = NotchGeometryEdgeTests.allScreens[5]
        let base = NotchGeometry.make(for: scaled)
        rig.show(scaled)
        scaled = ScreenInfo(id: scaled.id, name: scaled.name, frame: CGRect(x: 0, y: 0, width: 1352, height: 878),
                            visibleFrame: CGRect(x: 0, y: 0, width: 1352, height: 846), safeAreaTop: 32,
                            auxiliaryTopLeftWidth: 585.5, auxiliaryTopRightWidth: 585.5, isPrimary: true)
        rig.model.send(.clicked)
        rig.show(scaled)
        let g = try #require(rig.model.geometry)
        #expect(g != base)
        #expect(rig.hostingOnScreen == g.canvasRect)
        await rig.settle()
        #expect(rig.panel.frame == g.rect(for: rig.model.state))
        #expect(rig.hostingOnScreen == g.canvasRect)
        rig.controller.close()
    }

    @Test func nilGeometryHidesPanelAndRecoveryRestoresCanvas() async throws {
        let rig = try Rig()
        rig.show(Screens.builtInNotch)
        #expect(rig.panel.isVisible)
        rig.controller.apply(geometry: nil)
        #expect(!rig.panel.isVisible)
        rig.model.send(.clicked)                       // no geometry: must not crash or move anything
        rig.show(Screens.external)
        let g = try #require(rig.model.geometry)
        #expect(rig.hostingOnScreen == g.canvasRect)
        #expect(rig.panel.isVisible)
        rig.controller.close()
    }

    @Test func hostingViewDoesNotAutoresizeWithTheWindow() throws {
        let rig = try Rig()
        rig.show(Screens.builtInNotch)
        #expect(rig.hosting.autoresizingMask.isEmpty)
        let before = rig.hosting.frame.size
        rig.panel.setFrame(rig.panel.frame.insetBy(dx: -40, dy: 0), display: true)
        #expect(rig.hosting.frame.size == before)
        rig.controller.close()
    }
}
