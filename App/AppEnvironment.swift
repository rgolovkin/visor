import Foundation

/// Composition root: creates and owns every long-lived service. Owned by `AppDelegate`.
@MainActor
final class AppEnvironment {
    let paths: AppPaths
    let config: ConfigStore
    let systemEvents: SystemEvents
    let registry: WidgetRegistry
    let screens: ScreenManager
    private(set) var notchModel: NotchViewModel?
    private(set) var notchWindow: NotchWindowController?

    init(paths: AppPaths, catalog: [WidgetDescriptor] = WidgetCatalog.all) {
        self.paths = paths
        let config = ConfigStore(paths: paths, defaultWidgetOrder: WidgetCatalog.defaultOrder)
        config.load()
        self.config = config
        let systemEvents = SystemEvents()
        self.systemEvents = systemEvents
        registry = WidgetRegistry(store: config, catalog: catalog) { id in
            WidgetContext(
                settings: WidgetSettingsHandle(widgetID: id, store: config),
                paths: paths,
                systemEvents: systemEvents,
                openSettings: { Log.app.info("Settings window is not available yet (TASK-002)") }
            )
        }
        screens = ScreenManager()
    }

    static func standardPaths() -> AppPaths {
        do {
            return try AppPaths.standard()
        } catch {
            Log.app.error("Cannot resolve Application Support: \(error.localizedDescription, privacy: .public)")
            let fallback = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent(AppPaths.appFolderName, isDirectory: true)
            return AppPaths(root: fallback)
        }
    }

    func start() {
        registry.activateEnabledWidgets()
        let model = NotchViewModel(registry: registry)
        notchModel = model
        let window = NotchWindowController(model: model)
        notchWindow = window
        screens.onChange = { [weak window] geometry in window?.apply(geometry: geometry) }
        screens.startObserving()
        let general = config.document.general
        screens.apply(mode: general.displayMode, displayID: general.displayId)
        window.apply(geometry: screens.geometry)
    }

    func stop() {
        screens.stopObserving()
        notchWindow?.close()
        notchWindow = nil
        registry.deactivateAll()
    }

    /// Synchronous: must complete before the process exits.
    func flushAll() {
        registry.flushAll()
        config.flush()
    }
}
