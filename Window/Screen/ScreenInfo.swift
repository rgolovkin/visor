import AppKit

/// Value snapshot of an `NSScreen`, so screen selection and geometry are pure and testable.
/// Rects are in global AppKit coordinates (origin bottom-left of the primary screen).
struct ScreenInfo: Equatable, Sendable {
    let id: String
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    let safeAreaTop: CGFloat
    let auxiliaryTopLeftWidth: CGFloat?
    let auxiliaryTopRightWidth: CGFloat?
    let isPrimary: Bool

    var hasNotch: Bool { safeAreaTop > 0 && auxiliaryTopLeftWidth != nil && auxiliaryTopRightWidth != nil }
}

extension ScreenInfo {
    @MainActor
    static func current() -> [ScreenInfo] {
        let screens = NSScreen.screens
        // "Primary" is the screen with the menu bar (`screens.first`), not `NSScreen.main`, which follows
        // the key window and wanders for an agent app.
        let primary = screens.first
        return screens.map { ScreenInfo(screen: $0, isPrimary: $0 == primary) }
    }

    @MainActor
    init(screen: NSScreen, isPrimary: Bool) {
        self.init(
            id: Self.stableID(of: screen),
            name: screen.localizedName,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryTopRightWidth: screen.auxiliaryTopRightArea?.width,
            isPrimary: isPrimary
        )
    }

    /// `CGDirectDisplayID` changes between reboots/reconnects; the display UUID is stable.
    @MainActor
    private static func stableID(of screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            return "unknown-\(screen.localizedName)"
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) as String? else {
            return "display-\(displayID)"
        }
        return string
    }
}
