enum NotchState: Equatable, Sendable {
    case collapsed, peek, expanded
}

enum NotchEvent: Equatable, Sendable {
    case pointerEntered, pointerExited, clicked
    case openDelayElapsed(token: Int), closeDelayElapsed(token: Int)
    case peekAvailabilityChanged(Bool)
    case textInputBegan, textInputEnded
    case screenChanged
}

enum NotchEffect: Equatable, Sendable {
    case scheduleOpen(after: Duration, token: Int)
    case scheduleClose(after: Duration, token: Int)
    case cancelPending
    case transition(to: NotchState)
    case endTextInput
}

/// Pure state machine: no AppKit, no clocks. Delays are returned as effects with a token, and a
/// delayed event is honoured only if its token is still the pending one (ADR-001).
struct NotchStateMachine: Sendable {
    static let openDelay: Duration = .milliseconds(150)
    static let closeDelay: Duration = .milliseconds(300)

    private(set) var state: NotchState
    private(set) var pointerInside = false
    private(set) var textInputActive = false
    private(set) var hasPeek: Bool
    private(set) var pendingOpenToken: Int?
    private(set) var pendingCloseToken: Int?
    private var lastToken = 0

    init(hasPeek: Bool = false) {
        self.hasPeek = hasPeek
        self.state = hasPeek ? .peek : .collapsed
    }

    private var restingState: NotchState { hasPeek ? .peek : .collapsed }

    mutating func handle(_ event: NotchEvent) -> [NotchEffect] {
        switch event {
        case .pointerEntered:
            pointerInside = true
            if state == .expanded {
                return cancelPending()
            }
            guard pendingOpenToken == nil else { return [] }
            let token = nextToken()
            pendingOpenToken = token
            return [.scheduleOpen(after: Self.openDelay, token: token)]

        case .pointerExited:
            pointerInside = false
            if state == .expanded {
                return scheduleCloseIfAllowed()
            }
            return cancelPending()

        case .clicked:
            guard state != .expanded else { return [] }
            return cancelPending() + transition(to: .expanded)

        case .openDelayElapsed(let token):
            guard token == pendingOpenToken else { return [] }
            pendingOpenToken = nil
            guard pointerInside, state != .expanded else { return [] }
            return transition(to: .expanded)

        case .closeDelayElapsed(let token):
            guard token == pendingCloseToken else { return [] }
            pendingCloseToken = nil
            guard state == .expanded, !pointerInside, !textInputActive else { return [] }
            return transition(to: restingState)

        case .peekAvailabilityChanged(let available):
            hasPeek = available
            guard state != .expanded, state != restingState else { return [] }
            return transition(to: restingState)

        case .textInputBegan:
            textInputActive = true
            return cancelPending()

        case .textInputEnded:
            guard textInputActive else { return [] }
            textInputActive = false
            guard state == .expanded, !pointerInside else { return [] }
            return scheduleCloseIfAllowed()

        case .screenChanged:
            var effects = cancelPending()
            if textInputActive {
                textInputActive = false
                effects.append(.endTextInput)
            }
            pointerInside = false
            if state != restingState {
                effects += transition(to: restingState)
            }
            return effects
        }
    }

    private mutating func nextToken() -> Int {
        lastToken += 1
        return lastToken
    }

    private mutating func cancelPending() -> [NotchEffect] {
        guard pendingOpenToken != nil || pendingCloseToken != nil else { return [] }
        pendingOpenToken = nil
        pendingCloseToken = nil
        return [.cancelPending]
    }

    private mutating func scheduleCloseIfAllowed() -> [NotchEffect] {
        guard !textInputActive else { return [] }
        let token = nextToken()
        pendingOpenToken = nil
        pendingCloseToken = token
        return [.scheduleClose(after: Self.closeDelay, token: token)]
    }

    private mutating func transition(to target: NotchState) -> [NotchEffect] {
        state = target
        return [.transition(to: target)]
    }
}
