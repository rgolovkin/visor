import Foundation
import Testing
@testable import NotchApp

/// Fast / repeated event sequences (AC-3..AC-6, AC-22).
struct StateMachineEdgeTests {
    private func token(_ effects: [NotchEffect]) -> Int? {
        for effect in effects {
            switch effect {
            case .scheduleOpen(_, let t), .scheduleClose(_, let t): return t
            default: continue
            }
        }
        return nil
    }

    @Test func repeatedClicksAreIdempotent() {
        var m = NotchStateMachine(hasPeek: true)
        #expect(m.handle(.clicked) == [.transition(to: .expanded)])
        #expect(m.handle(.clicked) == [])
        #expect(m.handle(.clicked) == [])
        #expect(m.state == .expanded)
    }

    @Test func clickWhileOpenDelayPendingCancelsTheDelay() {
        var m = NotchStateMachine()
        let t = token(m.handle(.pointerEntered))!
        #expect(m.handle(.clicked) == [.cancelPending, .transition(to: .expanded)])
        #expect(m.handle(.openDelayElapsed(token: t)) == [])
    }

    @Test func exitAndReenterWithinCloseDelayInvalidatesTheOldCloseToken() {
        var m = NotchStateMachine()
        _ = m.handle(.pointerEntered)
        _ = m.handle(.clicked)
        let close = token(m.handle(.pointerExited))!
        #expect(m.handle(.pointerEntered) == [.cancelPending])
        #expect(m.handle(.closeDelayElapsed(token: close)) == [])
        #expect(m.state == .expanded)
        let close2 = token(m.handle(.pointerExited))!
        #expect(close2 != close)
        #expect(m.handle(.closeDelayElapsed(token: close)) == [])
        #expect(m.handle(.closeDelayElapsed(token: close2)) == [.transition(to: .collapsed)])
    }

    @Test func duplicateExitEventsReplaceTheCloseTimer() {
        var m = NotchStateMachine()
        _ = m.handle(.clicked)
        let first = token(m.handle(.pointerExited))!
        let second = token(m.handle(.pointerExited))!
        #expect(first != second)
        #expect(m.handle(.closeDelayElapsed(token: first)) == [])
        #expect(m.handle(.closeDelayElapsed(token: second)) == [.transition(to: .collapsed)])
    }

    @Test func textInputEndedWithPointerInsideNeverSchedulesClose() {
        var m = NotchStateMachine()
        _ = m.handle(.pointerEntered)
        _ = m.handle(.clicked)
        _ = m.handle(.textInputBegan)
        #expect(m.handle(.textInputEnded) == [])
        #expect(m.handle(.textInputEnded) == [])
        #expect(m.state == .expanded)
    }

    @Test func textInputBeganTwiceThenEndedOnceReleasesTheLock() {
        var m = NotchStateMachine()
        _ = m.handle(.clicked)
        _ = m.handle(.textInputBegan)
        _ = m.handle(.textInputBegan)
        _ = m.handle(.pointerExited)
        let effects = m.handle(.textInputEnded)
        #expect(token(effects) != nil)
    }

    @Test func peekAvailabilityFlappingWhileExpandedLeavesPanelOpenAndClosesToLatestResting() {
        var m = NotchStateMachine(hasPeek: false)
        _ = m.handle(.clicked)
        for i in 0..<10 { #expect(m.handle(.peekAvailabilityChanged(i % 2 == 0)) == []) }
        #expect(m.hasPeek == false)
        _ = m.handle(.pointerExited)
        let t = m.pendingCloseToken!
        #expect(m.handle(.closeDelayElapsed(token: t)) == [.transition(to: .collapsed)])
    }

    @Test func peekAvailabilityRepeatedSameValueIsNoOp() {
        var m = NotchStateMachine(hasPeek: true)
        #expect(m.handle(.peekAvailabilityChanged(true)) == [])
        #expect(m.handle(.peekAvailabilityChanged(false)) == [.transition(to: .collapsed)])
        #expect(m.handle(.peekAvailabilityChanged(false)) == [])
    }

    @Test func screenChangeWhileCollapsedWithPointerInsideAllowsReentry() {
        var m = NotchStateMachine()
        _ = m.handle(.pointerEntered)
        _ = m.handle(.screenChanged)
        #expect(!m.pointerInside)
        #expect(token(m.handle(.pointerEntered)) != nil)
    }

    @Test func tokensAreNeverReused() {
        var m = NotchStateMachine()
        var seen = Set<Int>()
        for _ in 0..<50 {
            if let t = token(m.handle(.pointerEntered)) { #expect(seen.insert(t).inserted) }
            _ = m.handle(.pointerExited)
        }
        _ = m.handle(.clicked)
        for _ in 0..<50 {
            if let t = token(m.handle(.pointerExited)) { #expect(seen.insert(t).inserted) }
            _ = m.handle(.pointerEntered)
        }
    }

    /// Randomised model check of the invariants, including stale and foreign tokens.
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
    func fuzzedEventSequencesKeepInvariants(_ seed: UInt64) {
        var rng = SplitMix(seed: seed)
        var m = NotchStateMachine(hasPeek: seed % 2 == 0)
        var issued: [Int] = []
        for step in 0..<3_000 {
            let before = m
            let event: NotchEvent
            var staleElapsed = false
            switch rng.next() % 11 {
            case 0: event = .pointerEntered
            case 1: event = .pointerExited
            case 2: event = .clicked
            case 3: event = .peekAvailabilityChanged(rng.next() % 2 == 0)
            case 4: event = .textInputBegan
            case 5: event = .textInputEnded
            case 6: event = .screenChanged
            case 7, 8:
                if let t = (rng.next() % 2 == 0 ? m.pendingOpenToken : m.pendingCloseToken) {
                    event = rng.next() % 2 == 0 ? .openDelayElapsed(token: t) : .closeDelayElapsed(token: t)
                } else {
                    event = .openDelayElapsed(token: -1)
                    staleElapsed = true
                }
            default:
                let t = issued.isEmpty ? 999 : issued[Int(rng.next() % UInt64(issued.count))]
                event = rng.next() % 2 == 0 ? .openDelayElapsed(token: t) : .closeDelayElapsed(token: t)
                staleElapsed = t != m.pendingOpenToken && t != m.pendingCloseToken
            }

            let effects = m.handle(event)
            for case .scheduleOpen(_, let t) in effects { issued.append(t) }
            for case .scheduleClose(_, let t) in effects { issued.append(t) }

            #expect(!(m.pendingOpenToken != nil && m.pendingCloseToken != nil), "step \(step): both timers pending")
            if m.pendingCloseToken != nil { #expect(m.state == .expanded, "step \(step): close pending outside expanded") }
            if m.state != .expanded { #expect(m.state == (m.hasPeek ? .peek : .collapsed), "step \(step): non-resting \(m.state)") }
            if m.textInputActive && m.state == .expanded { #expect(m.pendingCloseToken == nil, "step \(step): close pending during text input") }
            if staleElapsed {
                #expect(effects.isEmpty && m.state == before.state, "step \(step): stale token had effect")
            }
            if let last = effects.last(where: { if case .transition = $0 { true } else { false } }), case .transition(let to) = last {
                #expect(m.state == to)
            }
            if before.state == .expanded && m.state != .expanded {
                switch event {
                case .closeDelayElapsed, .screenChanged: break
                default: Issue.record("step \(step): left expanded on \(event)")
                }
                if case .closeDelayElapsed = event {
                    #expect(!before.textInputActive && !before.pointerInside)
                }
            }
        }
    }

    /// Liveness under realistic input (a click implies the pointer is inside): an open panel with
    /// nobody inside and no text input always has a close scheduled.
    @Test(arguments: [11, 12, 13, 14] as [UInt64])
    func openPanelWithoutPointerOrInputAlwaysHasAPathToClose(_ seed: UInt64) {
        var rng = SplitMix(seed: seed)
        var m = NotchStateMachine()
        for step in 0..<2_000 {
            switch rng.next() % 6 {
            case 0: _ = m.handle(.pointerEntered)
            case 1: _ = m.handle(.pointerExited)
            case 2: if m.pointerInside { _ = m.handle(.clicked) }
            case 3: _ = m.handle(.textInputBegan)
            case 4: _ = m.handle(.textInputEnded)
            default:
                if let t = m.pendingOpenToken { _ = m.handle(.openDelayElapsed(token: t)) }
                else if let t = m.pendingCloseToken { _ = m.handle(.closeDelayElapsed(token: t)) }
            }
            if m.state == .expanded, !m.pointerInside, !m.textInputActive {
                #expect(m.pendingCloseToken != nil, "step \(step): open, pointer outside, no input, but no close scheduled (stuck open)")
            }
        }
    }
}
