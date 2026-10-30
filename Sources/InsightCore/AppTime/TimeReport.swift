import Foundation

public enum ReportPeriod: String, Codable, CaseIterable, Sendable {
    case today, thisWeek, thisMonth

    /// The calendar range containing `now` (UK days, Monday-start weeks).
    public func span(containing now: Date, calendar: Calendar = UKTime.calendar) -> Span {
        let component: Calendar.Component
        switch self {
        case .today: component = .day
        case .thisWeek: component = .weekOfYear
        case .thisMonth: component = .month
        }
        let interval = calendar.dateInterval(of: component, for: now)!
        return Span(interval.start, interval.end)
    }
}

public struct AppTotal: Codable, Hashable, Sendable {
    public var app: String
    /// In front of you and in use.
    public var focused: TimeInterval
    /// Open on at least one screen.
    public var visible: TimeInterval
}

public struct ScreenTotal: Codable, Hashable, Sendable {
    public var screenID: String
    public var name: String
    /// Biggest visible time first.
    public var apps: [AppTotal]

    /// e.g. "Widescreen: TradingView 31h, ExoCharts 6h"
    public func summaryLine(maxApps: Int = 3) -> String {
        let parts = apps.prefix(maxApps).map { "\($0.app) \(DurationFormat.string($0.visible))" }
        return "\(name): " + (parts.isEmpty ? "nothing" : parts.joined(separator: ", "))
    }
}

public struct DayTotal: Codable, Hashable, Sendable {
    public var dayStart: Date
    public var focused: TimeInterval
}

public struct TimeReport: Codable, Sendable {
    public var period: Span
    /// Most focused first.
    public var apps: [AppTotal]
    public var screens: [ScreenTotal]
    /// Focused time by local hour of day (index 0 = midnight to 1am).
    public var hoursOfDay: [TimeInterval]
    public var days: [DayTotal]
    public var totalFocused: TimeInterval
}

public struct ScreenTimeline: Codable, Hashable, Sendable {
    public var screenID: String
    public var name: String
    /// What was frontmost on this screen, in time order, gaps where nothing
    /// was tracked.
    public var segments: [TimelineSegment]
}

public struct DayTimeline: Codable, Sendable {
    public var day: Span
    public var screens: [ScreenTimeline]
}

extension TimeAggregator {
    /// Report for one period. `screenNames` (screen ID -> name) overrides the
    /// names the tracker saw, e.g. ["37D8832A-...": "Arzopa"].
    public func report(_ tracked: TrackedTime, period: Span, screenNames: [String: String] = [:]) -> TimeReport {
        let range = IntervalSet([period])
        var apps: [String: AppTotal] = [:]
        for (app, set) in tracked.focused {
            apps[app, default: AppTotal(app: app, focused: 0, visible: 0)].focused = set.intersection(range).total
        }
        for (app, set) in tracked.visible {
            apps[app, default: AppTotal(app: app, focused: 0, visible: 0)].visible = set.intersection(range).total
        }
        let appList = apps.values
            .filter { $0.focused > 0 || $0.visible > 0 }
            .sorted { ($0.focused, $0.visible, $1.app) > ($1.focused, $1.visible, $0.app) }

        var screens: [ScreenTotal] = []
        for screenID in Set(tracked.visibleByScreen.keys).union(tracked.focusedByScreen.keys) {
            var perApp: [String: AppTotal] = [:]
            for (app, set) in tracked.visibleByScreen[screenID] ?? [:] {
                perApp[app, default: AppTotal(app: app, focused: 0, visible: 0)].visible = set.intersection(range).total
            }
            for (app, set) in tracked.focusedByScreen[screenID] ?? [:] {
                perApp[app, default: AppTotal(app: app, focused: 0, visible: 0)].focused = set.intersection(range).total
            }
            let list = perApp.values
                .filter { $0.focused > 0 || $0.visible > 0 }
                .sorted { ($0.visible, $0.focused, $1.app) > ($1.visible, $1.focused, $0.app) }
            guard !list.isEmpty else { continue }
            let name = screenNames[screenID] ?? tracked.screenNames[screenID] ?? screenID
            screens.append(ScreenTotal(screenID: screenID, name: name, apps: list))
        }
        screens.sort { $0.name != $1.name ? $0.name < $1.name : $0.screenID < $1.screenID }

        let allFocused = IntervalSet(tracked.focused.values.flatMap(\.spans)).intersection(range)
        return TimeReport(
            period: period,
            apps: appList,
            screens: screens,
            hoursOfDay: hoursOfDay(allFocused),
            days: dailyTotals(allFocused, period: period),
            totalFocused: allFocused.total
        )
    }

    public func report(_ tracked: TrackedTime, _ period: ReportPeriod, now: Date, screenNames: [String: String] = [:]) -> TimeReport {
        report(tracked, period: period.span(containing: now, calendar: calendar), screenNames: screenNames)
    }

    /// Focused time per local hour of day. On the day the clocks go back, the
    /// repeated hour (1am) counts into the same slot twice.
    public func hoursOfDay(_ set: IntervalSet) -> [TimeInterval] {
        var hours = [TimeInterval](repeating: 0, count: 24)
        for span in set.spans {
            var cursor = span.start
            while cursor < span.end {
                guard let hour = calendar.dateInterval(of: .hour, for: cursor) else { break }
                let end = min(hour.end, span.end)
                hours[calendar.component(.hour, from: cursor)] += end.timeIntervalSince(cursor)
                cursor = end
            }
        }
        return hours
    }

    /// Focused time per local calendar day (handles 23- and 25-hour days).
    public func dailyTotals(_ set: IntervalSet, period: Span) -> [DayTotal] {
        var out: [DayTotal] = []
        var cursor = period.start
        while cursor < period.end {
            guard let day = calendar.dateInterval(of: .day, for: cursor) else { break }
            let span = Span(max(day.start, period.start), min(day.end, period.end))
            out.append(DayTotal(dayStart: day.start, focused: set.clipped(to: span).total))
            cursor = day.end
        }
        return out
    }

    /// One horizontal bar per screen for the day containing `date`.
    public func dayTimeline(_ tracked: TrackedTime, day date: Date, screenNames: [String: String] = [:]) -> DayTimeline {
        let interval = calendar.dateInterval(of: .day, for: date)!
        let day = Span(interval.start, interval.end)
        var screens: [ScreenTimeline] = []
        for (screenID, apps) in tracked.frontmostByScreen {
            var segments: [TimelineSegment] = []
            for (app, set) in apps {
                for span in set.clipped(to: day).spans {
                    segments.append(TimelineSegment(start: span.start, end: span.end, app: app))
                }
            }
            guard !segments.isEmpty else { continue }
            segments.sort { $0.start < $1.start }
            let name = screenNames[screenID] ?? tracked.screenNames[screenID] ?? screenID
            screens.append(ScreenTimeline(screenID: screenID, name: name, segments: segments))
        }
        screens.sort { $0.name != $1.name ? $0.name < $1.name : $0.screenID < $1.screenID }
        return DayTimeline(day: day, screens: screens)
    }
}
