import SwiftUI

/// Confirmation inside the notch panel. System alerts do not work reliably in a borderless,
/// non-key panel, so widgets use this instead of `.alert` / `.confirmationDialog`.
struct InlineConfirmView: View {
    let message: String
    let confirmTitle: String
    let cancelTitle: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            HStack(spacing: 12) {
                Button(cancelTitle, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, role: .destructive, action: onConfirm)
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
