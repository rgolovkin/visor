import AppKit
import SwiftUI

final class NotchHostingView: NSHostingView<NotchRootView> {
    var onPointerEvent: (@MainActor (_ inside: Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    required init(rootView: NotchRootView) {
        super.init(rootView: rootView)
        // The window frame is driven by NotchWindowController, never by SwiftUI's ideal size.
        sizingOptions = []
        // The panel sits over the notch, i.e. inside the screen's top safe area. If the hosting view
        // applies that inset, every frame change re-proposes a different size and AppKit throws
        // "more Update Constraints in Window passes than there are views".
        safeAreaRegions = []
        installHoverArea()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The first click in a non-key panel should press the control, not just "activate" the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// `.activeAlways` is required: our app is almost never active, and without it the area only
    /// reports events while the app is frontmost. `.inVisibleRect` keeps it in sync with the frame.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installHoverArea()
    }

    var hasHoverArea: Bool { hoverArea.map { trackingAreas.contains($0) } ?? false }

    private func installHoverArea() {
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === hoverArea {
            onPointerEvent?(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverArea {
            onPointerEvent?(false)
        }
    }
}
