import AppKit
import SwiftUI

/// Makes the notch panel key only while one of our text fields is being edited (ADR-004).
/// The panel is `.nonactivatingPanel`, so becoming key does not activate the app: the frontmost
/// app and its menu bar stay, but keystrokes go to our field.
@MainActor
final class TextInputCoordinator {
    private weak var panel: NotchPanel?
    private(set) var isActive = false
    var onChange: (@MainActor (Bool) -> Void)?

    private var globalClickMonitor: Any?
    private var escapeMonitor: Any?
    private var resignKeyObservation: NotificationObservation?

    init(panel: NotchPanel) {
        self.panel = panel
    }

    func begin(from view: NSView) {
        guard let panel else { return }
        if !isActive {
            isActive = true
            panel.isTextInputActive = true
            panel.makeKey()
            installMonitors(for: panel)
            onChange?(true)
        }
        if panel.firstResponder !== view, !isEditing(view, in: panel) {
            panel.makeFirstResponder(view)
        }
    }

    func end() {
        guard isActive else { return }
        isActive = false
        removeMonitors()
        if let panel {
            panel.makeFirstResponder(nil)
            panel.isTextInputActive = false
            panel.resignKey()
        }
        onChange?(false)
    }

    private func isEditing(_ view: NSView, in panel: NSWindow) -> Bool {
        guard let editor = panel.firstResponder as? NSText else { return false }
        return (editor.delegate as? NSView) === view
    }

    private func installMonitors(for panel: NotchPanel) {
        // A click in another app does not make our field resign on its own, so watch for it.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isEscape = event.keyCode == 53
            let consumed = isEscape && MainActor.assumeIsolated { self?.handleEscape() ?? false }
            return consumed ? nil : event
        }
        resignKeyObservation = NotificationObservation(name: NSWindow.didResignKeyNotification, object: panel) { [weak self] in
            self?.end()
        }
    }

    /// Esc during IME composition cancels the composition, not the editing.
    private func handleEscape() -> Bool {
        guard isActive, let panel, panel.isKeyWindow else { return false }
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() {
            return false
        }
        end()
        return true
    }

    private func removeMonitors() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        globalClickMonitor = nil
        escapeMonitor = nil
        resignKeyObservation?.cancel()
        resignKeyObservation = nil
    }
}

extension EnvironmentValues {
    @Entry var textInputCoordinator: TextInputCoordinator?
}
