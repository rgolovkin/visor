import SwiftUI

/// Peek content: the compact view of the current peek winner. Switching widgets cross-fades
/// because the view is keyed by widget id inside an animated container.
struct CompactContainerView: View {
    let widget: any NotchWidget
    let geometry: NotchGeometry

    var body: some View {
        widget.makeCompactView()
            .id(widget.id)
            .transition(.opacity)
            .frame(width: geometry.peekRect.width, height: geometry.peekRect.height)
            .environment(\.notchGapWidth, geometry.collapsedRect.width)
            .environment(\.notchSideWidth, geometry.sideWidth)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
    }
}
