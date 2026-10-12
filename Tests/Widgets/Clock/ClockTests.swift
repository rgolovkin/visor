import AppKit
import Testing
@testable import NotchApp

struct ClockTickerTests {
    private func calendar(_ tz: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tz)!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        try! Date(iso, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }

    @Test func nextMinuteFromMiddleOfMinute() {
        let next = ClockTicker.nextMinuteBoundary(after: date("2026-10-12T10:15:30.000Z"), calendar: calendar("UTC"))
        #expect(next == date("2026-10-12T10:16:00.000Z"))
    }

    @Test func nextMinuteJustBeforeBoundary() {
        let next = ClockTicker.nextMinuteBoundary(after: date("2026-10-12T10:59:59.999Z"), calendar: calendar("UTC"))
        #expect(next == date("2026-10-12T11:00:00.000Z"))
    }

    @Test func nextMinuteExactlyOnBoundaryMovesForward() {
        let next = ClockTicker.nextMinuteBoundary(after: date("2026-10-12T10:16:00.000Z"), calendar: calendar("UTC"))
        #expect(next == date("2026-10-12T10:17:00.000Z"))
    }

    @Test func nextMinuteAcrossMidnight() {
        let next = ClockTicker.nextMinuteBoundary(after: date("2026-12-31T23:59:59.500Z"), calendar: calendar("UTC"))
        #expect(next == date("2027-01-01T00:00:00.000Z"))
    }

    @Test(arguments: ["Asia/Kolkata", "Asia/Kathmandu", "America/St_Johns", "Asia/Almaty"])
    func nextMinuteIsOnLocalMinuteInAnyTimeZone(_ tz: String) {
        let cal = calendar(tz)
        let next = ClockTicker.nextMinuteBoundary(after: date("2026-10-12T10:15:30.250Z"), calendar: cal)
        #expect(cal.component(.second, from: next) == 0)
        #expect(cal.component(.nanosecond, from: next) == 0)
        #expect(next.timeIntervalSince(date("2026-10-12T10:15:30.250Z")) <= 60)
    }

    @Test func nextMinuteAcrossDSTChange() {
        let cal = calendar("Europe/Berlin")
        let next = ClockTicker.nextMinuteBoundary(after: date("2026-10-25T00:59:59.000Z"), calendar: cal)
        #expect(next == date("2026-10-25T01:00:00.000Z"))
    }

    @Test func nextSecond() {
        #expect(ClockTicker.nextSecondBoundary(after: date("2026-10-12T10:15:30.250Z")) == date("2026-10-12T10:15:31.000Z"))
        #expect(ClockTicker.nextSecondBoundary(after: date("2026-10-12T10:15:30.000Z")) == date("2026-10-12T10:15:31.000Z"))
    }
}

@MainActor
struct ClockWidgetTests {
    private struct Env {
        let dir: TempDirectory
        let center: NotificationCenter
        let workspace: NotificationCenter
        let events: SystemEvents
        let widget: ClockWidget
        let time: Box<Date>
    }

    private func makeEnv() throws -> Env {
        let dir = try TempDirectory()
        let center = NotificationCenter()
        let workspace = NotificationCenter()
        let events = SystemEvents(center: center, workspaceCenter: workspace)
        let store = ConfigStore(paths: AppPaths(root: dir.url), defaultWidgetOrder: [WidgetID.clock])
        let time = Box(Date(timeIntervalSince1970: 1_700_000_030))
        let context = WidgetContext(
            settings: WidgetSettingsHandle(widgetID: WidgetID.clock, store: store),
            paths: AppPaths(root: dir.url),
            systemEvents: events,
            openSettings: {}
        )
        let widget = ClockWidget(context: context, clock: { time.value })
        return Env(dir: dir, center: center, workspace: workspace, events: events, widget: widget, time: time)
    }

    @Test func contract() throws {
        let env = try makeEnv()
        #expect(env.widget.id == "clock")
        #expect(env.widget.priority == 10)
        #expect(env.widget.isActive)
        #expect(env.widget.makeSettingsView() == nil)
        #expect(WidgetCatalog.all.map(\.id) == ["clock"])
    }

    @Test func compactSchedulesMinuteBoundaryExpandedSchedulesSecond() throws {
        let env = try makeEnv()
        env.widget.activate(reason: .launch)
        #expect(!env.widget.isTickScheduled)

        env.widget.visibilityDidChange(.compact)
        #expect(env.widget.isTickScheduled)
        #expect(env.widget.scheduledTickDelay == .seconds(10))

        env.widget.visibilityDidChange(.expanded)
        #expect(env.widget.scheduledTickDelay! <= .seconds(1))

        env.widget.visibilityDidChange(.hidden)
        #expect(!env.widget.isTickScheduled)
    }

    // AC-18
    @Test func deactivateReleasesEverything() throws {
        let env = try makeEnv()
        env.widget.activate(reason: .launch)
        env.widget.visibilityDidChange(.compact)
        #expect(!env.events.observedKinds.isEmpty)

        env.widget.deactivate()
        #expect(!env.widget.isTickScheduled)
        #expect(env.events.observedKinds.isEmpty)

        env.widget.visibilityDidChange(.expanded)
        #expect(!env.widget.isTickScheduled)
    }

    // AC-19
    @Test func systemTimeChangesRefreshImmediately() throws {
        let env = try makeEnv()
        env.widget.activate(reason: .launch)
        env.widget.visibilityDidChange(.compact)

        env.time.value = Date(timeIntervalSince1970: 1_800_000_000)
        env.center.post(name: .NSSystemClockDidChange, object: nil)
        #expect(env.widget.now == env.time.value)

        env.time.value = Date(timeIntervalSince1970: 1_800_000_100)
        env.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(env.widget.now == env.time.value)

        env.time.value = Date(timeIntervalSince1970: 1_800_000_200)
        env.center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        #expect(env.widget.now == env.time.value)
        #expect(env.widget.scheduledTickDelay == .seconds(40))
    }

    @Test func tickFiresAndReschedules() async throws {
        let env = try makeEnv()
        env.time.value = Date(timeIntervalSince1970: 1_700_000_000.95)
        env.widget.activate(reason: .launch)
        env.widget.visibilityDidChange(.expanded)
        env.time.value = Date(timeIntervalSince1970: 1_700_000_001.01)
        await waitUntil { env.widget.now == env.time.value }
        #expect(env.widget.isTickScheduled)
        env.widget.deactivate()
    }
}
