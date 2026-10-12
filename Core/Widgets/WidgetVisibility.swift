enum ActivationReason: Sendable, Equatable {
    case launch
    case userEnabled
}

enum WidgetVisibility: Equatable, Sendable {
    case hidden
    case compact
    case expanded
}
