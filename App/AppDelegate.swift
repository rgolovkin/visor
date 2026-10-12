import AppKit

/// AppKit lifecycle hooks the SwiftUI `App` does not expose (will-terminate, single instance).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var environment: AppEnvironment?
    private var isDuplicateInstance = false

    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningUnitTests else { return }
        if SingleInstanceGuard.isAnotherInstanceRunning() {
            Log.app.notice("Another instance is already running, quitting")
            isDuplicateInstance = true
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests are hosted inside the app; do not bring up windows or widgets there.
        guard !Self.isRunningUnitTests, !isDuplicateInstance else { return }
        let environment = AppEnvironment(paths: AppEnvironment.standardPaths())
        self.environment = environment
        environment.start()
        Log.app.info("Started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment?.flushAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
