import AppKit

/// Owns the panel and applies frame requests from the view model.
@MainActor
final class NotchWindowController {
    private let panel: NotchPanel
    private let hostingView: NotchHostingView
    private let model: NotchViewModel
    let textInput: TextInputCoordinator

    init(model: NotchViewModel) {
        self.model = model
        panel = NotchPanel(contentRect: .zero)
        textInput = TextInputCoordinator(panel: panel)
        hostingView = NotchHostingView(rootView: NotchRootView(model: model, textInput: textInput))
        // A plain container keeps SwiftUI's layout constraints away from the window, so the frame is set
        // only by us (hosting view as contentView let SwiftUI resize the window). The hosting view is
        // positioned manually (see `apply(_:)`), not autoresized.
        let container = NSView(frame: .zero)
        container.clipsToBounds = true
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = []
        container.addSubview(hostingView)
        panel.contentView = container
        hostingView.onPointerEvent = { [weak model] inside in
            model?.send(inside ? .pointerEntered : .pointerExited)
        }
        model.onLayoutChange = { [weak self] request in self?.apply(request) }
        model.onEndTextInput = { [weak textInput] in textInput?.end() }
        textInput.onChange = { [weak model] active in
            model?.send(active ? .textInputBegan : .textInputEnded)
        }
    }

    var notchPanel: NotchPanel { panel }
    var notchHostingView: NotchHostingView { hostingView }

    func close() {
        textInput.end()
        panel.orderOut(nil)
    }

    func apply(geometry: NotchGeometry?) {
        model.updateGeometry(geometry)
        if geometry == nil {
            panel.orderOut(nil)
        }
    }

    /// The hosting view keeps a fixed size and a fixed position on screen (the geometry's canvas); only
    /// the window around it grows or shrinks. If SwiftUI saw the window size change, it would re-center
    /// the notch inside the animated transaction that follows, while the window origin had already
    /// jumped, so one edge of the shape (and the content) visibly jumped sideways.
    private func apply(_ request: NotchLayoutRequest) {
        let canvas = (model.geometry?.canvasRect ?? request.frame).union(request.frame)
        let hostingFrame = canvas.offsetBy(dx: -request.frame.minX, dy: -request.frame.minY)
        if hostingView.frame != hostingFrame {
            hostingView.frame = hostingFrame
        }
        panel.setFrame(request.frame, display: true)
        if !panel.isVisible {
            // Shows the panel without activating the app or making it key.
            panel.orderFrontRegardless()
        }
        syncPointer()
    }

    /// AppKit may not send enter/exit when the frame changes under a stationary cursor, so check once
    /// after every frame change. This is a single check per layout event, not polling.
    private func syncPointer() {
        let inside = panel.frame.contains(NSEvent.mouseLocation)
        if inside != model.isPointerInside {
            model.send(inside ? .pointerEntered : .pointerExited)
        }
    }
}
