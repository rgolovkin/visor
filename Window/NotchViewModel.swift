import AppKit
import Observation
import SwiftUI

struct NotchLayoutRequest: Equatable {
    enum Phase: Equatable {
        /// Grow instantly to cover both the old and the new shape before the animation starts.
        case growBeforeAnimation
        /// Shrink to the exact resting shape after the animation has fully finished.
        case shrinkAfterAnimation
        /// No animation (screen change, first layout).
        case immediate
    }

    let frame: CGRect
    let phase: Phase
}

/// Glue between the pure state machine, timers, SwiftUI animations and the AppKit window frame.
@MainActor
@Observable
final class NotchViewModel {
    private(set) var state: NotchState
    private(set) var geometry: NotchGeometry?
    /// Remembered between openings (in memory only).
    private(set) var selectedTabID: String?
    /// Last peek winner; meaningful only while `state == .peek`.
    private(set) var peekWidgetID: String?
    let registry: WidgetRegistry

    @ObservationIgnored var onLayoutChange: (@MainActor (NotchLayoutRequest) -> Void)?
    @ObservationIgnored var onEndTextInput: (@MainActor () -> Void)?
    @ObservationIgnored private var machine: NotchStateMachine
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var windowFrame: CGRect?
    @ObservationIgnored private(set) var transitionGeneration = 0
    @ObservationIgnored private let reduceMotion: @MainActor () -> Bool
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private var peekLoop: ObservationLoop<String?>?

    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let reducedMotion = Animation.easeInOut(duration: 0.15)

    init(
        registry: WidgetRegistry,
        reduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0, tolerance: .milliseconds(10)) }
    ) {
        self.registry = registry
        self.reduceMotion = reduceMotion
        self.sleep = sleep
        let winnerID = registry.peekWinner?.id
        peekWidgetID = winnerID
        machine = NotchStateMachine(hasPeek: winnerID != nil)
        state = machine.state
        // The window frame (AppKit) must follow peek availability, so bridge it out of Observation.
        peekLoop = ObservationLoop(read: { [weak registry] in registry?.peekWinner?.id }) { [weak self] id in
            self?.peekWinnerChanged(id)
        }
        registry.updateVisibility(state: state, selectedTabID: selectedTabID)
    }

    var peekWidget: (any NotchWidget)? {
        peekWidgetID.flatMap { registry.widget(id: $0) }
    }

    func selectTab(_ id: String) {
        guard selectedTabID != id else { return }
        withAnimation(reduceMotion() ? Self.reducedMotion : Self.spring) {
            selectedTabID = id
        }
        registry.updateVisibility(state: state, selectedTabID: selectedTabID)
    }

    var isPointerInside: Bool { machine.pointerInside }
    var isTextInputActive: Bool { machine.textInputActive }

    func send(_ event: NotchEvent) {
        let effects = machine.handle(event)
        for effect in effects {
            perform(effect)
        }
    }

    func updateGeometry(_ newGeometry: NotchGeometry?) {
        let screenChanged = geometry != nil && newGeometry?.screenID != geometry?.screenID
        geometry = newGeometry
        if screenChanged || newGeometry == nil {
            // The old frame belongs to the previous screen; a union with it would span both displays.
            windowFrame = nil
            send(.screenChanged)
        }
        guard let newGeometry else {
            windowFrame = nil
            return
        }
        transitionGeneration += 1
        setWindowFrame(newGeometry.rect(for: state), phase: .immediate)
    }

    /// Called by SwiftUI when the animation started by transition `generation` is fully removed.
    func animationDidFinish(generation: Int) {
        guard generation == transitionGeneration, let geometry else { return }
        let target = geometry.rect(for: state)
        guard windowFrame != target else { return }
        setWindowFrame(target, phase: .shrinkAfterAnimation)
    }

    private func peekWinnerChanged(_ id: String?) {
        if id != nil, id != peekWidgetID {
            withAnimation(reduceMotion() ? Self.reducedMotion : Self.spring) {
                peekWidgetID = id
            }
        }
        // On nil the last id is kept on purpose: compact content is shown only in `.peek`, and keeping
        // it lets the view fade out together with the peek → collapsed animation.
        send(.peekAvailabilityChanged(id != nil))
        registry.updateVisibility(state: state, selectedTabID: selectedTabID)
    }

    private func perform(_ effect: NotchEffect) {
        switch effect {
        case .scheduleOpen(let delay, let token):
            schedule(after: delay) { [weak self] in self?.send(.openDelayElapsed(token: token)) }
        case .scheduleClose(let delay, let token):
            schedule(after: delay) { [weak self] in self?.send(.closeDelayElapsed(token: token)) }
        case .cancelPending:
            pendingTask?.cancel()
            pendingTask = nil
        case .transition(let target):
            transition(to: target)
        case .endTextInput:
            onEndTextInput?()
        }
    }

    private func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        pendingTask?.cancel()
        let sleep = self.sleep
        pendingTask = Task { @MainActor in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
    }

    private func transition(to target: NotchState) {
        let previous = state
        guard previous != target else { return }
        if previous == .expanded {
            onEndTextInput?()
            registry.flushAll()
        }

        transitionGeneration += 1
        let generation = transitionGeneration

        guard let geometry else {
            state = target
            registry.updateVisibility(state: state, selectedTabID: selectedTabID)
            return
        }

        let targetRect = geometry.rect(for: target)
        let grown = (windowFrame ?? targetRect).union(targetRect)
        if grown != windowFrame {
            setWindowFrame(grown, phase: .growBeforeAnimation)
        }

        let animation = reduceMotion() ? Self.reducedMotion : Self.spring
        withAnimation(animation, completionCriteria: .removed) {
            state = target
        } completion: { [weak self] in
            self?.animationDidFinish(generation: generation)
        }
        registry.updateVisibility(state: state, selectedTabID: selectedTabID)
    }

    private func setWindowFrame(_ frame: CGRect, phase: NotchLayoutRequest.Phase) {
        windowFrame = frame
        onLayoutChange?(NotchLayoutRequest(frame: frame, phase: phase))
    }
}
