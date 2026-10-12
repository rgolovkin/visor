struct WidgetDescriptor {
    let id: String
    let defaultEnabled: Bool
    let make: @MainActor (WidgetContext) -> any NotchWidget
}

enum WidgetCatalog {
    /// Default order for a fresh config (AC-13). Includes ids that are not implemented yet: they are
    /// kept in config.json as "unknown" entries until their widget ships.
    static let defaultOrder: [String] = [
        WidgetID.clock, WidgetID.calendar, WidgetID.timer, WidgetID.battery,
        WidgetID.weather, WidgetID.sysmon, WidgetID.notes,
    ]

    /// Implemented widgets. Adding a widget = one line here.
    @MainActor static let all: [WidgetDescriptor] = [
        WidgetDescriptor(id: WidgetID.clock, defaultEnabled: true) { ClockWidget(context: $0) },
    ]
}
