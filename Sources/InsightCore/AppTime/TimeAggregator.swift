import Foundation

public struct TimelineSegment: Codable, Hashable, Sendable {
    public var start: Date
    public var end: Date
    public var app: String

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// All tracked time turned into exact sets of moments.
public struct TrackedTime: Sendable {
    /// Tracker running, Mac awake, screen on and unlocked.
    public var awake: IntervalSet
    /// Awake and not idle.
    public var active: IntervalSet
    /// App -> moments it was focused and in use.
    public var focused: [String: IntervalSet]
    /// Screen -> app -> moments it was focused on that screen.
    public var focusedByScreen: [String: [String: IntervalSet]]
    /// Screen -> app -> moments it had a window visible on that screen.
    public var visibleByScreen: [String: [String: IntervalSet]]
    /// App -> moments it was visible on any screen (overlaps counted once).
    public var visible: [String: IntervalSet]
    /// Screen -> app -> moments it was the frontmost app on that screen.
    public var frontmostByScreen: [String: [String: IntervalSet]]
    /// Screen ID -> latest friendly name seen.
    public var screenNames: [String: String]
}

/// Turns tracker records into focused / visible time.
///
/// Rules:
/// - Each snapshot describes the time from itself until the next snapshot. A
///   gap longer than `maxGap` means the tracker wasn't running; the last
///   snapshot before it then covers only `snapshotInterval`.
/// - Sleep, screen lock and screens-off stop all counting until the matching
///   wake / unlock / screens-on (or the tracker restarting).
/// - Idle: when a snapshot reports no input for `idleThreshold` or more, the
///   whole stretch since the last input stops counting as focused.
/// - The focused app comes from activation events; a snapshot whose focused
///   app differs corrects it from that moment (in case an event was missed).
public struct TimeAggregator: Sendable {
    public var calendar: Calendar
    public var idleThreshold: TimeInterval
    public var snapshotInterval: TimeInterval
    public var maxGap: TimeInterval

    public init(calendar: Calendar = UKTime.calendar, idleThreshold: TimeInterval = 120, snapshotInterval: TimeInterval = 60, maxGap: TimeInterval = 180) {
        self.calendar = calendar
        self.idleThreshold = idleThreshold
        self.snapshotInterval = snapshotInterval
        self.maxGap = maxGap
    }

    public func track(_ input: [TrackerRecord]) -> TrackedTime {
        let records = input.enumerated()
            .sorted { $0.element.time != $1.element.time ? $0.element.time < $1.element.time : $0.offset < $1.offset }
            .map(\.element)

        // 1. When the tracker was running.
        var running: [Span] = []
        for (i, record) in records.enumerated() {
            if case .system(let e) = record, e.kind == .trackerStopped { continue }
            let t = record.time
            if i + 1 < records.count, records[i + 1].time.timeIntervalSince(t) <= maxGap {
                running.append(Span(t, records[i + 1].time))
            } else {
                running.append(Span(t, t.addingTimeInterval(snapshotInterval)))
            }
        }

        // 2. Asleep / locked / screens off.
        var blocked: [Span] = []
        var openSince: [SystemEvent.Kind: Date] = [:]
        let opens: [SystemEvent.Kind: SystemEvent.Kind] = [.wake: .sleep, .screenUnlocked: .screenLocked, .screensWoke: .screensSlept]
        for record in records {
            guard case .system(let e) = record else { continue }
            switch e.kind {
            case .sleep, .screenLocked, .screensSlept:
                if openSince[e.kind] == nil { openSince[e.kind] = e.time }
            case .wake, .screenUnlocked, .screensWoke:
                if let start = openSince.removeValue(forKey: opens[e.kind]!) { blocked.append(Span(start, e.time)) }
            case .trackerStarted:
                // A fresh start means whatever was open has ended.
                for (_, start) in openSince { blocked.append(Span(start, e.time)) }
                openSince.removeAll()
            case .trackerStopped:
                break
            }
        }
        if let last = records.last?.time {
            for (_, start) in openSince { blocked.append(Span(start, last.addingTimeInterval(snapshotInterval))) }
        }
        let awake = IntervalSet(running).subtracting(IntervalSet(blocked))

        // 3. Idle.
        var idleSpans: [Span] = []
        var snapshots: [MinuteSnapshot] = []
        for record in records {
            guard case .snapshot(let s) = record else { continue }
            snapshots.append(s)
            if s.idleSeconds >= idleThreshold {
                idleSpans.append(Span(s.time.addingTimeInterval(-s.idleSeconds), s.time))
            }
        }
        let active = awake.subtracting(IntervalSet(idleSpans))

        // 4. Focus timeline.
        var focusPoints: [(Date, String)] = []
        var current: String?
        for record in records {
            switch record {
            case .activation(let e):
                if e.app != current {
                    focusPoints.append((e.time, e.app))
                    current = e.app
                }
            case .snapshot(let s):
                if let app = s.focusedApp, app != current {
                    focusPoints.append((s.time, app))
                    current = app
                }
            case .system:
                break
            }
        }
        var focusSpans: [String: [Span]] = [:]
        let farFuture = (records.last?.time ?? Date()).addingTimeInterval(86_400)
        for (i, point) in focusPoints.enumerated() {
            let end = i + 1 < focusPoints.count ? focusPoints[i + 1].0 : farFuture
            focusSpans[point.1, default: []].append(Span(point.0, end))
        }
        var focused: [String: IntervalSet] = [:]
        for (app, spans) in focusSpans {
            let set = IntervalSet(spans).intersection(active)
            if !set.isEmpty { focused[app] = set }
        }

        // 5. What each snapshot covers.
        var focusScreenSpans: [String: [Span]] = [:]
        var visibleSpans: [String: [String: [Span]]] = [:]
        var frontSpans: [String: [String: [Span]]] = [:]
        var screenNames: [String: String] = [:]
        for (i, s) in snapshots.enumerated() {
            let end: Date
            if i + 1 < snapshots.count, snapshots[i + 1].time.timeIntervalSince(s.time) <= maxGap {
                end = snapshots[i + 1].time
            } else {
                end = s.time.addingTimeInterval(snapshotInterval)
            }
            let span = Span(s.time, end)
            if let screen = s.focusedScreenID { focusScreenSpans[screen, default: []].append(span) }
            for screen in s.screens {
                if let name = screen.screenName { screenNames[screen.screenID] = name }
                for app in Set(screen.apps) {
                    visibleSpans[screen.screenID, default: [:]][app, default: []].append(span)
                }
                if let front = screen.apps.first {
                    frontSpans[screen.screenID, default: [:]][front, default: []].append(span)
                }
            }
        }

        func clip(_ byScreen: [String: [String: [Span]]]) -> [String: [String: IntervalSet]] {
            var out: [String: [String: IntervalSet]] = [:]
            for (screen, apps) in byScreen {
                for (app, spans) in apps {
                    let set = IntervalSet(spans).intersection(awake)
                    if !set.isEmpty { out[screen, default: [:]][app] = set }
                }
            }
            return out
        }
        let visibleByScreen = clip(visibleSpans)
        let frontmostByScreen = clip(frontSpans)

        var visibleUnion: [String: [Span]] = [:]
        for (_, apps) in visibleByScreen {
            for (app, set) in apps { visibleUnion[app, default: []].append(contentsOf: set.spans) }
        }
        let visible = visibleUnion.mapValues { IntervalSet($0) }

        var focusedByScreen: [String: [String: IntervalSet]] = [:]
        for (screen, spans) in focusScreenSpans {
            let onScreen = IntervalSet(spans)
            for (app, set) in focused {
                let both = set.intersection(onScreen)
                if !both.isEmpty { focusedByScreen[screen, default: [:]][app] = both }
            }
        }

        return TrackedTime(
            awake: awake,
            active: active,
            focused: focused,
            focusedByScreen: focusedByScreen,
            visibleByScreen: visibleByScreen,
            visible: visible,
            frontmostByScreen: frontmostByScreen,
            screenNames: screenNames
        )
    }
}
