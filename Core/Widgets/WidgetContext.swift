@MainActor
struct WidgetContext {
    let settings: WidgetSettingsHandle
    let paths: AppPaths
    let systemEvents: SystemEvents
    let openSettings: @MainActor () -> Void
}
