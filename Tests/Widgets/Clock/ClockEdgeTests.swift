import AppKit
import Foundation
import Testing
@testable import NotchApp

/// ClockWidget / ClockFormat edge cases (AC-18, AC-19).
@MainActor
struct ClockEdgeTests {
    private struct Env {
        let dir: TempDirectory
        let center: NotificationCenter
        let workspace: NotificationCenter
        let events: SystemEvents
        let widget: ClockWidget
        let time: Box<Date>
        let calendar: Box<Calendar>
    }

    private func makeEnv(start: Date = Date(timeIntervalSince1970: 1_700_000_030), timeZone: String = "UTC") throws -> Env {
        let dir = try TempDirectory()
        let center = NotificationCenter()
        let workspace = NotificationCenter()
        let events = SystemEvents(center: center, workspaceCenter: workspace)
        let store = ConfigStore(paths: AppPaths(root: dir.url), defaultWidgetOrder: [WidgetID.clock])
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: timeZone)!
        let calBox = Box(cal)
        let time = Box(start)
        let context = WidgetContext(
            settings: WidgetSettingsHandle(widgetID: WidgetID.clock, store: store),
            paths: AppPaths(root: dir.url), systemEvents: events, openSettings: {}
        )
        let widget = ClockWidget(context: context, clock: { time.value }, calendar: { calBox.value })
        return Env(dir: dir, center: center, workspace: workspace, events: events, widget: widget, time: time, calendar: calBox)
    }

    @Test func activationInHiddenStateStartsNoTimerAndSubscribesOnlyToTimeEvents() throws {
        let env = try makeEnv()
        env.widget.activate(reason: .launch)
        #expect(env.widget.isRunning)
        #expect(!env.widget.isTickScheduled)
        #expect(env.events.observedKinds == [.wake, .clockChanged, .timeZoneChanged, .dayChanged])
        #expect(!env.events.observedKinds.contains(.willSleep))
    }

    @Test func systemEventsWhileHiddenRefreshTimeButNeverScheduleATimer() throws {
        let env = try makeEnv()
        env.widget.activate(reason: .launch)
        env.time.value = Date(timeIntervalSince1970: 1_800_000_000)
        env.center.post(name: .NSSystemClockDidChange, object: nil)
        env.center.post(name: .NSCalendarDayChanged, object: nil)
        env.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(env.widget.now == env.time.value)
        #expect(!env.widget.isTickScheduled)
    }

    @Test func eventsAfterDeactivateAreIgnored() throws {
        let env = try makeEnv()
        env.widget.activate(reason: .launch)
        env.widget.visibilityDidChange(.compact)
        env.widget.deactivate()
        let frozen = env.widget.now
        env.time.value = Date(timeIntervalSince1970: 1_900_000_000)
        env.center.post(name: .NSSystemClockDidChange, object: nil)
        env.widget.visibilityDidChange(.expanded)
        #expect(env.widget.now == frozen)
        #expect(!env.widget.isTickScheduled)
        #expect(env.events.observedKinds.isEmpty)
    }

    @Test func doubleActivateDoesNotDuplicateSubscriptionsAndReactivationWorks() throws {
        let env = try makeEnv()
        env.widget.activate(reason: .launch)
        env.widget.activate(reason: .userEnabled)
        env.widget.visibilityDidChange(.compact)
        env.widget.deactivate()
        env.widget.deactivate()
        #expect(env.events.observedKinds.isEmpty)

        env.widget.activate(reason: .userEnabled)
        env.widget.visibilityDidChange(.expanded)   // same value as before? no: previous was .compact
        #expect(env.widget.isTickScheduled)
        env.widget.deactivate()
        #expect(!env.widget.isTickScheduled)
    }

    @Test func rapidVisibilityFlappingLeavesExactlyOneTimerMatchingTheFinalState() throws {
        let env = try makeEnv()
        env.widget.activate(reason: .launch)
        for i in 0..<100 {
            env.widget.visibilityDidChange([.hidden, .compact, .expanded][i % 3])
        }
        // i == 99 -> index 0 -> hidden
        #expect(!env.widget.isTickScheduled)
        env.widget.visibilityDidChange(.compact)
        #expect(env.widget.scheduledTickDelay == .seconds(10))
        env.widget.visibilityDidChange(.hidden)
        #expect(env.widget.scheduledTickDelay == nil)
    }

    @Test func tickOnExactMinuteBoundaryWaitsAFullMinute() throws {
        let env = try makeEnv(start: Date(timeIntervalSince1970: 1_700_000_040))   // 22:14:00 UTC
        env.widget.activate(reason: .launch)
        env.widget.visibilityDidChange(.compact)
        #expect(env.widget.scheduledTickDelay == .seconds(60))
    }

    @Test(arguments: ["UTC", "Asia/Kolkata", "Asia/Kathmandu", "America/St_Johns", "Pacific/Chatham", "Pacific/Kiritimati"])
    func compactDelayEndsExactlyOnALocalMinuteInAnyZone(_ zone: String) throws {
        let env = try makeEnv(start: Date(timeIntervalSince1970: 1_700_000_012.3), timeZone: zone)
        env.widget.activate(reason: .launch)
        env.widget.visibilityDidChange(.compact)
        let delay = try #require(env.widget.scheduledTickDelay)
        let ms = Double(delay.components.seconds) * 1000 + Double(delay.components.attoseconds) / 1e15
        let target = env.time.value.addingTimeInterval(ms / 1000)
        let cal = env.calendar.value
        #expect(cal.component(.second, from: target) == 0 || cal.component(.second, from: target.addingTimeInterval(-0.001)) == 59)
        #expect(ms > 0 && ms <= 60_000 + 1)
    }

    @Test func timeZoneChangeRecomputesBoundaryUsingTheNewCalendar() throws {
        let env = try makeEnv(timeZone: "UTC")
        env.widget.activate(reason: .launch)
        env.widget.visibilityDidChange(.compact)
        let before = env.widget.scheduledTickDelay
        var other = Calendar(identifier: .gregorian)
        other.timeZone = TimeZone(identifier: "Asia/Kathmandu")!
        env.calendar.value = other
        env.center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        #expect(env.widget.isTickScheduled)
        #expect(env.widget.scheduledTickDelay == before)   // whole-minute offset: same boundary, but recomputed
    }

    @Test func clockJumpingBackwardsStillSchedulesForwardOnly() throws {
        let env = try makeEnv()
        env.widget.activate(reason: .launch)
        env.widget.visibilityDidChange(.compact)
        env.time.value = Date(timeIntervalSince1970: 1_000_000_000)
        env.center.post(name: .NSSystemClockDidChange, object: nil)
        let delay = try #require(env.widget.scheduledTickDelay)
        #expect(delay > .zero && delay <= .seconds(60))
    }

    @Test func expandedDelayNeverExceedsOneSecond() throws {
        for fraction in [0.0, 0.001, 0.5, 0.999] {
            let env = try makeEnv(start: Date(timeIntervalSince1970: 1_700_000_000 + fraction))
            env.widget.activate(reason: .launch)
            env.widget.visibilityDidChange(.expanded)
            let delay = try #require(env.widget.scheduledTickDelay)
            #expect(delay > .zero && delay <= .seconds(1), "fraction \(fraction): \(delay)")
        }
    }

    // MARK: format (12/24h, time zone)

    private func format(_ style: Date.FormatStyle, _ date: Date, locale: String, zone: String) -> String {
        var s = style
        s.locale = Locale(identifier: locale)
        s.timeZone = TimeZone(identifier: zone)!
        return date.formatted(s)
    }

    @Test func compactFormatFollowsLocaleHourCycleAndTimeZone() {
        let date = Date(timeIntervalSince1970: 1_700_000_000 + 3600 * 3)   // 2023-11-15 01:13:20 UTC
        let us = format(ClockFormat.compact, date, locale: "en_US", zone: "UTC")
        let gb = format(ClockFormat.compact, date, locale: "en_GB", zone: "UTC")
        let ru = format(ClockFormat.compact, date, locale: "ru_RU", zone: "UTC")
        #expect(us.contains("AM") || us.contains("PM"), Comment(rawValue: us))
        #expect(!gb.contains("AM") && gb.contains(":"), Comment(rawValue: gb))
        #expect(!ru.contains("AM") && ru.contains(":"), Comment(rawValue: ru))
        let tokyo = format(ClockFormat.compact, date, locale: "en_GB", zone: "Asia/Tokyo")
        #expect(tokyo != gb)
    }

    @Test func expandedFormatsIncludeSecondsAndDateParts() {
        let date = Date(timeIntervalSince1970: 1_700_000_000 + 7)
        let time = format(ClockFormat.expandedTime, date, locale: "en_GB", zone: "UTC")
        #expect(time.split(separator: ":").count == 3, Comment(rawValue: time))
        let day = format(ClockFormat.expandedDate, date, locale: "en_GB", zone: "UTC")
        #expect(day.contains("Tuesday") || day.contains("Wednesday"), Comment(rawValue: day))
        let ru = format(ClockFormat.expandedDate, date, locale: "ru_RU", zone: "UTC")
        #expect(!ru.isEmpty && ru != day)
    }
}
