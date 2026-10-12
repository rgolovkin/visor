import AppKit
import Testing
@testable import NotchApp

/// Drives the real panel through open/close cycles (no synthetic mouse events: state changes are sent
/// to the model directly). Regression test for the AppKit "more Update Constraints in Window passes
/// than there are views" crash, which happened when SwiftUI's hosting view resized the window.
/// Note: the notch panel briefly appears on screen while this test runs.
@MainActor
struct NotchWindowIntegrationTests {
    @Test func openCloseCyclesOnRealWindowDoNotCrash() async throws {
        let dir = try TempDirectory()
        let env = AppEnvironment(paths: AppPaths(root: dir.url))
        env.start()
        let model = try #require(env.notchModel)
        let window = try #require(env.notchWindow)
        let geometry = try #require(model.geometry)
        for _ in 0..<3 {
            model.send(.clicked)
            #expect(model.state == .expanded)
            await waitUntil { window.notchPanel.frame == geometry.expandedRect }
            model.send(.pointerExited)
            await waitUntil(timeout: .seconds(5)) { model.state != .expanded }
            // After the collapse animation finishes the panel shrinks to the exact resting shape.
            await waitUntil(timeout: .seconds(5)) { window.notchPanel.frame == geometry.rect(for: model.state) }
        }
        #expect([NotchState.peek, .collapsed].contains(model.state))
        env.stop()
    }

    /// Peek -> expanded jump regression: the SwiftUI content must not move or resize on screen when the
    /// window frame grows/shrinks, only the window around it changes.
    @Test func hostingViewStaysOnTheCanvasWhileTheWindowFrameChanges() async throws {
        let dir = try TempDirectory()
        let env = AppEnvironment(paths: AppPaths(root: dir.url))
        env.start()
        let model = try #require(env.notchModel)
        let window = try #require(env.notchWindow)
        let geometry = try #require(model.geometry)
        let panel = window.notchPanel
        let hosting = window.notchHostingView
        func hostingOnScreen() -> CGRect {
            panel.convertToScreen(hosting.convert(hosting.bounds, to: nil))
        }
        #expect(hostingOnScreen() == geometry.canvasRect)
        model.send(.clicked)
        #expect(panel.frame == geometry.expandedRect)
        #expect(hostingOnScreen() == geometry.canvasRect)
        model.send(.pointerExited)
        await waitUntil(timeout: .seconds(5)) { model.state != .expanded }
        await waitUntil(timeout: .seconds(5)) { panel.frame == geometry.rect(for: model.state) }
        #expect(panel.frame == geometry.rect(for: model.state))
        #expect(hostingOnScreen() == geometry.canvasRect)
        env.stop()
    }
}
