import AppKit
import Testing
@testable import NotchApp

@MainActor
struct NotchPanelTests {
    // AC-10, AC-11
    @Test func panelNeverBecomesKeyOrMainByDefault() {
        let panel = NotchPanel(contentRect: .zero)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.level.rawValue > NSWindow.Level.mainMenu.rawValue)
        #expect(panel.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]))
        #expect(!panel.hasShadow)
        #expect(!panel.isOpaque)
    }

    @Test func constrainFrameDoesNotMoveBelowMenuBar() {
        let panel = NotchPanel(contentRect: .zero)
        let rect = CGRect(x: 10, y: 5000, width: 100, height: 32)
        #expect(panel.constrainFrameRect(rect, to: nil) == rect)
    }

    // AC-22 / ADR-004
    @Test func textInputMakesPanelKeyableOnlyWhileActive() {
        let panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40))
        let field = NotchNSTextField()
        panel.contentView = NSView()
        panel.contentView?.addSubview(field)
        let coordinator = TextInputCoordinator(panel: panel)
        var changes: [Bool] = []
        coordinator.onChange = { changes.append($0) }

        coordinator.begin(from: field)
        #expect(coordinator.isActive)
        #expect(panel.canBecomeKey)
        coordinator.begin(from: field)

        coordinator.end()
        coordinator.end()
        #expect(!coordinator.isActive)
        #expect(!panel.canBecomeKey)
        #expect(changes == [true, false])
    }

    @Test func hostingViewInstallsAlwaysActiveHoverArea() {
        let registry = try? RegistryHarness([])
        guard let registry else { return }
        let model = NotchViewModel(registry: registry.registry, reduceMotion: { false })
        let view = NotchHostingView(rootView: NotchRootView(model: model))
        #expect(view.hasHoverArea)
        let area = view.trackingAreas.first { $0.options.contains(.activeAlways) }
        #expect(area?.options.contains(.mouseEnteredAndExited) == true)
        #expect(area?.options.contains(.inVisibleRect) == true)
        #expect(view.acceptsFirstMouse(for: nil))
    }

    @Test func editShortcutsAreRoutedManually() throws {
        func event(_ chars: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0
            ))
        }
        #expect(NotchNSTextField.editAction(for: try event("v", .command)) == #selector(NSText.paste(_:)))
        #expect(NotchNSTextField.editAction(for: try event("z", [.command, .shift])) == Selector(("redo:")))
        #expect(NotchNSTextField.editAction(for: try event("v", [])) == nil)
        #expect(NotchNSTextField.editAction(for: try event("q", .command)) == nil)
    }
}
