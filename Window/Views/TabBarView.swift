import SwiftUI

struct TabBarView: View {
    let widgets: [any NotchWidget]
    let selectedID: String?
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(widgets, id: \.id) { widget in
                let isSelected = widget.id == selectedID
                Button {
                    onSelect(widget.id)
                } label: {
                    Image(systemName: widget.symbolName)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 30, height: 24)
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.55))
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.white.opacity(isSelected ? 0.18 : 0))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(widget.title)
                .accessibilityLabel(widget.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}
