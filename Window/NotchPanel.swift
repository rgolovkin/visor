import AppKit

/// Borderless, non-activating panel above the menu bar on every Space (ADR-001).
/// SwiftUI scenes cannot set window level/collection behaviour or avoid activating the app,
/// so the window is AppKit and only its content is SwiftUI.
final class NotchPanel: NSPanel {
    /// Set only by our text fields while they edit (ADR-004); otherwise the panel never becomes key.
    var isTextInputActive = false

    init(contentRect: NSRect) {
        // `.nonactivatingPanel` must be set at init: changing it later is unreliable in AppKit.
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // NSPanel defaults to true: the notch would vanish whenever the app deactivates.
        hidesOnDeactivate = false
        isFloatingPanel = true
        // `.statusBar` loses to the menu bar that slides in over full-screen apps; +3 above `.mainMenu` does not.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { isTextInputActive }
    override var canBecomeMain: Bool { false }

    /// AppKit would otherwise push a window that overlaps the menu bar down below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
