import CoreGraphics

/// All rects are in global screen coordinates, top-aligned to the screen and centered on the notch.
struct NotchGeometry: Equatable, Sendable {
    static let pillMinSize = CGSize(width: 200, height: 24)

    let screenID: String
    let isPhysicalNotch: Bool
    let collapsedRect: CGRect
    let peekRect: CGRect
    let expandedRect: CGRect
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let sideWidth: CGFloat

    static func make(
        for screen: ScreenInfo,
        sideWidth: CGFloat = 96,
        expandedSize: CGSize = CGSize(width: 520, height: 200)
    ) -> NotchGeometry {
        let frame = screen.frame
        let collapsed: CGRect
        if screen.hasNotch, let left = screen.auxiliaryTopLeftWidth, let right = screen.auxiliaryTopRightWidth {
            let width = frame.width - left - right
            collapsed = CGRect(
                x: frame.minX + left,
                y: frame.maxY - screen.safeAreaTop,
                width: width,
                height: screen.safeAreaTop
            )
        } else {
            let menuBarHeight = frame.maxY - screen.visibleFrame.maxY
            let height = max(pillMinSize.height, menuBarHeight)
            collapsed = CGRect(
                x: frame.midX - pillMinSize.width / 2,
                y: frame.maxY - height,
                width: pillMinSize.width,
                height: height
            )
        }

        let peek = CGRect(
            x: collapsed.minX - sideWidth,
            y: collapsed.minY,
            width: collapsed.width + sideWidth * 2,
            height: collapsed.height
        )
        let expandedWidth = max(expandedSize.width, peek.width)
        let expandedHeight = collapsed.height + expandedSize.height
        let expanded = CGRect(
            x: collapsed.midX - expandedWidth / 2,
            y: frame.maxY - expandedHeight,
            width: expandedWidth,
            height: expandedHeight
        )

        return NotchGeometry(
            screenID: screen.id,
            isPhysicalNotch: screen.hasNotch,
            collapsedRect: collapsed.integral,
            peekRect: peek.integral,
            expandedRect: expanded.integral,
            notchWidth: collapsed.width,
            notchHeight: collapsed.height,
            sideWidth: sideWidth
        )
    }

    /// Fixed area the SwiftUI content is laid out in: covers every state, so the hosting view never
    /// changes size while the window frame grows or shrinks around a transition.
    var canvasRect: CGRect { collapsedRect.union(peekRect).union(expandedRect) }

    func rect(for state: NotchState) -> CGRect {
        switch state {
        case .collapsed: collapsedRect
        case .peek: peekRect
        case .expanded: expandedRect
        }
    }
}
