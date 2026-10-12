import SwiftUI

enum ClockFormat {
    static var compact: Date.FormatStyle { base.hour().minute() }
    static var expandedTime: Date.FormatStyle { base.hour().minute().second() }
    static var expandedDate: Date.FormatStyle { base.weekday(.wide).day().month(.wide) }

    /// Follows the system locale (12/24 h) and time zone, including later changes.
    private static var base: Date.FormatStyle {
        Date.FormatStyle(locale: .autoupdatingCurrent, calendar: .autoupdatingCurrent, timeZone: .autoupdatingCurrent)
    }
}

struct ClockCompactView: View {
    let widget: ClockWidget

    var body: some View {
        CompactSplit {
            Image(systemName: "clock")
                .font(.system(size: 12, weight: .semibold))
        } trailing: {
            Text(widget.now, format: ClockFormat.compact)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
        }
    }
}

struct ClockExpandedView: View {
    let widget: ClockWidget

    var body: some View {
        VStack(spacing: 4) {
            Text(widget.now, format: ClockFormat.expandedTime)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(widget.now, format: ClockFormat.expandedDate)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
