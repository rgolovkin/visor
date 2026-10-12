import SwiftUI

struct NotchRootView: View {
    let model: NotchViewModel
    var textInput: TextInputCoordinator?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if let geometry = model.geometry {
                notch(geometry)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .environment(\.textInputCoordinator, textInput)
    }

    @ViewBuilder
    private func notch(_ geometry: NotchGeometry) -> some View {
        let size = geometry.rect(for: model.state).size
        let style = NotchStyle(state: model.state, isPhysicalNotch: geometry.isPhysicalNotch)
        ZStack(alignment: .top) {
            NotchShape(topRadius: style.topRadius, bottomRadius: style.bottomRadius)
                .fill(Color.black)
            content(geometry)
        }
        // `.top`: during a transition the content is larger than the animated frame; centering would push
        // it up/down instead of letting the growing shape reveal it from the top.
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(NotchShape(topRadius: style.topRadius, bottomRadius: style.bottomRadius))
        .contentShape(NotchShape(topRadius: style.topRadius, bottomRadius: style.bottomRadius))
        // Reduce Motion: replace the morph with a short cross-fade between states.
        .id(reduceMotion ? AnyHashable(model.state) : AnyHashable(0))
        .transition(.opacity)
        .onTapGesture {
            if model.state != .expanded {
                model.send(.clicked)
            }
        }
    }

    /// Content exists only in its own state, so hidden views do not live (and tick) in the hierarchy.
    @ViewBuilder
    private func content(_ geometry: NotchGeometry) -> some View {
        switch model.state {
        case .expanded:
            ExpandedPanelView(model: model, geometry: geometry)
                .transition(.opacity)
        case .peek:
            if let widget = model.peekWidget {
                CompactContainerView(widget: widget, geometry: geometry)
                    .transition(.opacity)
            }
        case .collapsed:
            EmptyView()
        }
    }
}

struct NotchStyle: Equatable {
    let topRadius: CGFloat
    let bottomRadius: CGFloat

    init(state: NotchState, isPhysicalNotch: Bool) {
        switch state {
        case .collapsed:
            // Physical notch: radius not smaller than the hardware corner, so no black corner shows.
            topRadius = 0
            bottomRadius = isPhysicalNotch ? 10 : 12
        case .peek:
            topRadius = 6
            bottomRadius = 14
        case .expanded:
            topRadius = 12
            bottomRadius = 24
        }
    }
}
