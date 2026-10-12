import SwiftUI

extension EnvironmentValues {
    /// Width of the (physical or virtual) notch between the two compact halves.
    @Entry var notchGapWidth: CGFloat = 0
    /// Maximum width available on each side of the notch in peek.
    @Entry var notchSideWidth: CGFloat = 96
}

/// Lays a compact widget view out on both sides of the notch (Q4): `leading` left of it, `trailing`
/// right of it. Each side is limited to `notchSideWidth` and truncates instead of growing.
struct CompactSplit<Leading: View, Trailing: View>: View {
    @Environment(\.notchGapWidth) private var gap
    @Environment(\.notchSideWidth) private var side

    private let leading: Leading
    private let trailing: Trailing

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 0) {
            leading
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .frame(width: side, alignment: .leading)
            Spacer(minLength: gap)
            trailing
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .frame(width: side, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .clipped()
    }
}
