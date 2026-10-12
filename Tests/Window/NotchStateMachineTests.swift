import Testing
@testable import NotchApp

struct NotchStateMachineTests {
    private func openToken(_ effects: [NotchEffect]) -> Int? {
        for case .scheduleOpen(_, let token) in effects { return token }
        return nil
    }

    private func closeToken(_ effects: [NotchEffect]) -> Int? {
        for case .scheduleClose(_, let token) in effects { return token }
        return nil
    }

    private func expandedMachine(hasPeek: Bool = false) -> NotchStateMachine {
        var m = NotchStateMachine(hasPeek: hasPeek)
        let token = openToken(m.handle(.pointerEntered))!
        _ = m.handle(.openDelayElapsed(token: token))
        return m
    }

    @Test func initialStateDependsOnPeek() {
        #expect(NotchStateMachine(hasPeek: false).state == .collapsed)
        #expect(NotchStateMachine(hasPeek: true).state == .peek)
    }

    // AC-3
    @Test func hoverOpensAfter150ms() {
        var m = NotchStateMachine()
        let effects = m.handle(.pointerEntered)
        #expect(effects == [.scheduleOpen(after: .milliseconds(150), token: openToken(effects)!)])
        #expect(m.state == .collapsed)
        #expect(m.handle(.openDelayElapsed(token: openToken(effects)!)) == [.transition(to: .expanded)])
        #expect(m.state == .expanded)
    }

    @Test func repeatedEnterDoesNotRestartOpenDelay() {
        var m = NotchStateMachine()
        let token = openToken(m.handle(.pointerEntered))!
        #expect(m.handle(.pointerEntered) == [])
        #expect(m.handle(.openDelayElapsed(token: token)) == [.transition(to: .expanded)])
    }

    // AC-5
    @Test func quickPassDoesNotOpen() {
        var m = NotchStateMachine(hasPeek: true)
        let token = openToken(m.handle(.pointerEntered))!
        #expect(m.handle(.pointerExited) == [.cancelPending])
        #expect(m.handle(.openDelayElapsed(token: token)) == [])
        #expect(m.state == .peek)
    }

    @Test func staleOpenTokenIsIgnored() {
        var m = NotchStateMachine()
        let first = openToken(m.handle(.pointerEntered))!
        _ = m.handle(.pointerExited)
        let second = openToken(m.handle(.pointerEntered))!
        #expect(first != second)
        #expect(m.handle(.openDelayElapsed(token: first)) == [])
        #expect(m.handle(.openDelayElapsed(token: second)) == [.transition(to: .expanded)])
    }

    // AC-4, AC-9
    @Test(arguments: [(true, NotchState.peek), (false, NotchState.collapsed)])
    func leavingClosesAfter300msToRestingState(hasPeek: Bool, expected: NotchState) {
        var m = expandedMachine(hasPeek: hasPeek)
        let effects = m.handle(.pointerExited)
        let token = closeToken(effects)!
        #expect(effects == [.scheduleClose(after: .milliseconds(300), token: token)])
        #expect(m.state == .expanded)
        #expect(m.handle(.closeDelayElapsed(token: token)) == [.transition(to: expected)])
        #expect(m.state == expected)
    }

    // AC-6
    @Test func reenteringDuringCloseDelayKeepsExpanded() {
        var m = expandedMachine()
        let token = closeToken(m.handle(.pointerExited))!
        #expect(m.handle(.pointerEntered) == [.cancelPending])
        #expect(m.handle(.closeDelayElapsed(token: token)) == [])
        #expect(m.state == .expanded)
    }

    @Test func reenteringDuringCollapseAnimationReopens() {
        var m = expandedMachine()
        let close = closeToken(m.handle(.pointerExited))!
        _ = m.handle(.closeDelayElapsed(token: close))
        #expect(m.state == .collapsed)
        let open = openToken(m.handle(.pointerEntered))!
        #expect(m.handle(.openDelayElapsed(token: open)) == [.transition(to: .expanded)])
    }

    @Test(arguments: [false, true])
    func clickOpensImmediately(hasPeek: Bool) {
        var m = NotchStateMachine(hasPeek: hasPeek)
        let token = openToken(m.handle(.pointerEntered))!
        #expect(m.handle(.clicked) == [.cancelPending, .transition(to: .expanded)])
        #expect(m.handle(.openDelayElapsed(token: token)) == [])
        #expect(m.handle(.clicked) == [])
    }

    // AC-8, AC-9
    @Test func peekAvailabilityMovesBetweenCollapsedAndPeek() {
        var m = NotchStateMachine()
        #expect(m.handle(.peekAvailabilityChanged(true)) == [.transition(to: .peek)])
        #expect(m.handle(.peekAvailabilityChanged(true)) == [])
        #expect(m.handle(.peekAvailabilityChanged(false)) == [.transition(to: .collapsed)])
    }

    @Test func peekAvailabilityInExpandedIsRememberedForClose() {
        var m = expandedMachine()
        #expect(m.handle(.peekAvailabilityChanged(true)) == [])
        #expect(m.state == .expanded)
        let token = closeToken(m.handle(.pointerExited))!
        #expect(m.handle(.closeDelayElapsed(token: token)) == [.transition(to: .peek)])
    }

    // AC-22
    @Test func textInputBlocksAutoCollapse() {
        var m = expandedMachine()
        _ = m.handle(.textInputBegan)
        #expect(m.handle(.pointerExited) == [])
        #expect(m.state == .expanded)

        let effects = m.handle(.textInputEnded)
        let token = closeToken(effects)!
        #expect(m.handle(.closeDelayElapsed(token: token)) == [.transition(to: .collapsed)])
    }

    @Test func textInputBeganCancelsScheduledClose() {
        var m = expandedMachine()
        let token = closeToken(m.handle(.pointerExited))!
        #expect(m.handle(.textInputBegan) == [.cancelPending])
        #expect(m.handle(.closeDelayElapsed(token: token)) == [])
        #expect(m.state == .expanded)
    }

    @Test func textInputEndedInsidePanelDoesNotSchedule() {
        var m = expandedMachine()
        _ = m.handle(.textInputBegan)
        #expect(m.handle(.textInputEnded) == [])
        #expect(m.state == .expanded)
    }

    @Test func screenChangeEndsInputAndRests() {
        var m = expandedMachine(hasPeek: true)
        _ = m.handle(.textInputBegan)
        #expect(m.handle(.screenChanged) == [.endTextInput, .transition(to: .peek)])
        #expect(!m.textInputActive)
        #expect(!m.pointerInside)
    }

    @Test func screenChangeWithPendingOpenCancelsIt() {
        var m = NotchStateMachine()
        let token = openToken(m.handle(.pointerEntered))!
        #expect(m.handle(.screenChanged) == [.cancelPending])
        #expect(m.handle(.openDelayElapsed(token: token)) == [])
    }
}
