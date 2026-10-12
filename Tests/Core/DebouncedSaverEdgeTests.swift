import Testing
@testable import NotchApp

@MainActor
struct DebouncedSaverEdgeTests {
    @Test func burstProducesExactlyOneSave() async throws {
        var saves = 0
        let saver = DebouncedSaver(delay: .milliseconds(30)) { saves += 1 }
        for _ in 0..<100 { saver.markDirty() }
        await waitUntil { saves >= 1 }
        try await Task.sleep(for: .milliseconds(120))
        #expect(saves == 1)
        #expect(!saver.isDirty)
    }

    @Test func flushThenPendingDelayDoesNotSaveTwice() async throws {
        var saves = 0
        let saver = DebouncedSaver(delay: .milliseconds(30)) { saves += 1 }
        saver.markDirty()
        saver.flush()
        saver.flush()
        try await Task.sleep(for: .milliseconds(120))
        #expect(saves == 1)
    }

    @Test func cancelKeepsDirtyFlagSoQuitStillSaves() {
        var saves = 0
        let saver = DebouncedSaver(delay: .seconds(60)) { saves += 1 }
        saver.markDirty()
        saver.cancel()
        #expect(saver.isDirty)
        saver.flush()
        #expect(saves == 1)
    }

    @Test func markDirtyInsideSaveSchedulesAnotherSave() async throws {
        var saves = 0
        var saverRef: DebouncedSaver?
        let saver = DebouncedSaver(delay: .milliseconds(20)) {
            saves += 1
            if saves == 1 { saverRef?.markDirty() }
        }
        saverRef = saver
        saver.markDirty()
        await waitUntil { saves == 2 }
        saverRef = nil
    }

    @Test func deallocationCancelsPendingSave() async throws {
        var saves = 0
        var saver: DebouncedSaver? = DebouncedSaver(delay: .milliseconds(20)) { saves += 1 }
        saver?.markDirty()
        saver = nil
        try await Task.sleep(for: .milliseconds(100))
        #expect(saves == 0)
    }

    @Test func oneShotSchedulerCancelAndReplaceRaces() async throws {
        let scheduler = OneShotScheduler()
        var fired: [Int] = []
        scheduler.schedule(after: .milliseconds(20), tolerance: .zero) { fired.append(1) }
        scheduler.schedule(after: .milliseconds(20), tolerance: .zero) { fired.append(2) }
        scheduler.cancel()
        scheduler.schedule(after: .milliseconds(20), tolerance: .zero) { fired.append(3) }
        try await Task.sleep(for: .milliseconds(120))
        #expect(fired == [3])
        #expect(!scheduler.isScheduled)
        // Past dates fire immediately (no negative delay crash).
        scheduler.schedule(at: .distantPast, tolerance: .zero) { fired.append(4) }
        await waitUntil { fired.contains(4) }
    }
}
