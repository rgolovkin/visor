import SwiftUI
@testable import NotchApp

@MainActor
@Observable
final class FakeWidget: NotchWidget {
    nonisolated let id: String
    var title: String
    var symbolName = "square"
    var priority: Int
    var isActive: Bool

    private(set) var activateCount = 0
    private(set) var deactivateCount = 0
    private(set) var lastActivationReason: ActivationReason?
    private(set) var visibilityHistory: [WidgetVisibility] = []
    private(set) var reloadCount = 0
    private(set) var flushCount = 0

    var lastVisibility: WidgetVisibility? { visibilityHistory.last }
    var isRunning: Bool { activateCount > deactivateCount }

    init(id: String, priority: Int = 0, isActive: Bool = false) {
        self.id = id
        self.title = id
        self.priority = priority
        self.isActive = isActive
    }

    func makeCompactView() -> AnyView { AnyView(Text(id)) }
    func makeExpandedView() -> AnyView { AnyView(Text(id)) }

    func activate(reason: ActivationReason) {
        activateCount += 1
        lastActivationReason = reason
    }

    func deactivate() { deactivateCount += 1 }
    func visibilityDidChange(_ visibility: WidgetVisibility) { visibilityHistory.append(visibility) }
    func reloadSettings() { reloadCount += 1 }
    func flush() { flushCount += 1 }
}

@MainActor
struct RegistryHarness {
    let dir: TempDirectory
    let store: ConfigStore
    let registry: WidgetRegistry
    let widgets: [String: FakeWidget]

    init(_ fakes: [FakeWidget], configJSON: String? = nil) throws {
        dir = try TempDirectory()
        let paths = AppPaths(root: dir.url)
        if let configJSON {
            try Data(configJSON.utf8).write(to: paths.config)
        }
        store = ConfigStore(paths: paths, defaultWidgetOrder: fakes.map(\.id), saveDelay: .milliseconds(10))
        store.load()
        let events = SystemEvents(center: NotificationCenter(), workspaceCenter: NotificationCenter())
        let catalog = fakes.map { fake in
            WidgetDescriptor(id: fake.id, defaultEnabled: true) { _ in fake }
        }
        let store = self.store
        registry = WidgetRegistry(store: store, catalog: catalog) { id in
            WidgetContext(
                settings: WidgetSettingsHandle(widgetID: id, store: store),
                paths: paths,
                systemEvents: events,
                openSettings: {}
            )
        }
        widgets = Dictionary(uniqueKeysWithValues: fakes.map { ($0.id, $0) })
    }

    subscript(_ id: String) -> FakeWidget { widgets[id]! }
}
