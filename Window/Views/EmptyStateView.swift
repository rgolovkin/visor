import SwiftUI

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("No widgets enabled")
                .font(.headline)
                .foregroundStyle(.white)
            // Becomes active together with the settings window (TASK-002).
            Button("Open Settings") {}
                .buttonStyle(.bordered)
                .disabled(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
