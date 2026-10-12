import SwiftUI

struct MenuBarContent: View {
    var body: some View {
        Button("Settings…") {}
            .keyboardShortcut(",")
            .disabled(true)
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
