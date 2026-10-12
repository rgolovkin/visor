enum ScreenResolver {
    static func resolve(screens: [ScreenInfo], mode: DisplayMode, displayID: String?) -> ScreenInfo? {
        let primary = screens.first(where: \.isPrimary) ?? screens.first
        switch mode {
        case .auto, .notch:
            return screens.first(where: \.hasNotch) ?? primary
        case .primary:
            return primary
        case .display:
            return screens.first { $0.id == displayID } ?? primary
        }
    }
}
