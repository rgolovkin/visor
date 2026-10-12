import AppKit
import SwiftUI

/// Single-line text field for content inside the notch panel. SwiftUI `TextField` cannot get focus
/// in a non-key borderless panel, so this wraps an AppKit field that asks `TextInputCoordinator`
/// to make the panel key on click (ADR-004).
struct NotchTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var onSubmit: (() -> Void)?

    @Environment(\.textInputCoordinator) private var inputCoordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NotchNSTextField {
        let field = NotchNSTextField()
        field.placeholderString = placeholder
        field.stringValue = text
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .white
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.inputCoordinator = inputCoordinator
        return field
    }

    func updateNSView(_ field: NotchNSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        field.inputCoordinator = inputCoordinator
        field.placeholderString = placeholder
        // Never overwrite the string while the user is editing (would reset caret / IME state).
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: (() -> Void)?

        init(text: Binding<String>, onSubmit: (() -> Void)?) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            onSubmit?()
            (control as? NotchNSTextField)?.inputCoordinator?.end()
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            (notification.object as? NotchNSTextField)?.inputCoordinator?.end()
        }
    }
}

final class NotchNSTextField: NSTextField {
    weak var inputCoordinator: TextInputCoordinator?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        inputCoordinator?.begin(from: self)
        super.mouseDown(with: event)
    }

    /// Workaround: an agent app (LSUIElement) has no visible Edit menu, so ⌘C/⌘V/⌘X/⌘A/⌘Z/⇧⌘Z key
    /// equivalents never reach the field editor. Route them to the responder chain ourselves.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, currentEditor() != nil,
              let action = Self.editAction(for: event) else {
            return super.performKeyEquivalent(with: event)
        }
        return NSApp.sendAction(action, to: nil, from: self)
    }

    static func editAction(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        switch (flags, key) {
        case (.command, "x"): return #selector(NSText.cut(_:))
        case (.command, "c"): return #selector(NSText.copy(_:))
        case (.command, "v"): return #selector(NSText.paste(_:))
        case (.command, "a"): return #selector(NSText.selectAll(_:))
        case (.command, "z"): return Selector(("undo:"))
        case ([.command, .shift], "z"): return Selector(("redo:"))
        default: return nil
        }
    }
}
