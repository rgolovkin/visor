import SwiftUI

struct ExpandedPanelView: View {
    let model: NotchViewModel
    let geometry: NotchGeometry

    var body: some View {
        let widgets = model.registry.enabledWidgets
        let selectedID = model.registry.resolvedTabID(model.selectedTabID)
        VStack(spacing: 6) {
            if widgets.isEmpty {
                EmptyStateView()
            } else {
                TabBarView(widgets: widgets, selectedID: selectedID) { id in
                    model.selectTab(id)
                }
                if let widget = widgets.first(where: { $0.id == selectedID }) {
                    widget.makeExpandedView()
                        .id(widget.id)
                        .transition(.opacity)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(.top, geometry.notchHeight + 4)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(width: geometry.expandedRect.width, height: geometry.expandedRect.height, alignment: .top)
    }
}
