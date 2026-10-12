import SwiftUI

/// SwiftUI owns only the menu bar item; the notch window itself is AppKit (see `NotchPanel`).
@main
struct NotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("NotchApp", systemImage: "rectangle.topthird.inset.filled") {
            MenuBarContent()
        }
    }
}
