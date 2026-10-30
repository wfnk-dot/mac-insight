import XCTest
@testable import InsightCore

final class AppNameTests: XCTestCase {
    func testElectronHelperResolvesToTheApp() {
        let path = "/Applications/Slack.app/Contents/Frameworks/Slack Helper (Renderer).app/Contents/MacOS/Slack Helper (Renderer)"
        XCTAssertEqual(AppNameResolver.appName(fromPath: path), "Slack")
    }

    func testRealAppInsideAnotherAppKeepsItsName() {
        let path = "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator"
        XCTAssertEqual(AppNameResolver.appName(fromPath: path), "Simulator")
    }

    func testPlainApp() {
        let procs: [Int32: ProcessRecord] = [
            100: ProcessRecord(pid: 100, executablePath: "/Applications/TradingView.app/Contents/MacOS/TradingView", localizedName: "TradingView"),
        ]
        XCTAssertEqual(AppNameResolver().resolve(pid: 100, processes: procs), "TradingView")
    }

    func testJavaResolvesViaResponsibleProcess() {
        let procs: [Int32: ProcessRecord] = [
            200: ProcessRecord(pid: 200, parentPID: 1, executablePath: "/Applications/ExoCharts.app/Contents/MacOS/ExoCharts", localizedName: "ExoCharts"),
            201: ProcessRecord(pid: 201, parentPID: 1, responsiblePID: 200, executablePath: "/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home/bin/java", localizedName: "java"),
        ]
        XCTAssertEqual(AppNameResolver().resolve(pid: 201, processes: procs), "ExoCharts")
    }

    func testJavaResolvesViaParentChain() {
        let procs: [Int32: ProcessRecord] = [
            300: ProcessRecord(pid: 300, parentPID: 1, executablePath: "/Applications/ExoCharts.app/Contents/MacOS/launcher"),
            301: ProcessRecord(pid: 301, parentPID: 300, executablePath: "/usr/bin/java", localizedName: "java"),
        ]
        XCTAssertEqual(AppNameResolver().resolve(pid: 301, processes: procs), "ExoCharts")
    }

    func testJavaResolvesViaArguments() {
        let procs: [Int32: ProcessRecord] = [
            400: ProcessRecord(pid: 400, executablePath: "/usr/bin/java", localizedName: "java", arguments: ["-jar", "/Applications/ExoCharts.app/Contents/app/exocharts.jar"]),
        ]
        XCTAssertEqual(AppNameResolver().resolve(pid: 400, processes: procs), "ExoCharts")
    }

    func testBundledJREInsideTheApp() {
        let procs: [Int32: ProcessRecord] = [
            500: ProcessRecord(pid: 500, executablePath: "/Applications/ExoCharts.app/Contents/runtime/Contents/Home/bin/java", localizedName: "java"),
        ]
        XCTAssertEqual(AppNameResolver().resolve(pid: 500, processes: procs), "ExoCharts")
    }

    func testOverridesWin() {
        let procs: [Int32: ProcessRecord] = [
            600: ProcessRecord(pid: 600, executablePath: "/opt/tools/bin/java", localizedName: "java"),
            601: ProcessRecord(pid: 601, executablePath: "/Applications/Code.app/Contents/MacOS/Electron", bundleIdentifier: "com.microsoft.VSCode", localizedName: "Code"),
        ]
        let resolver = AppNameResolver(overrides: [
            AppNameOverride(.executableName("java"), displayName: "ExoCharts"),
            AppNameOverride(.bundleIdentifier("com.microsoft.vscode"), displayName: "VS Code"),
        ])
        XCTAssertEqual(resolver.resolve(pid: 600, processes: procs), "ExoCharts")
        XCTAssertEqual(resolver.resolve(pid: 601, processes: procs), "VS Code")
        XCTAssertEqual(AppNameResolver().resolve(pid: 601, processes: procs), "Code")
    }

    func testFallbacks() {
        let procs: [Int32: ProcessRecord] = [
            700: ProcessRecord(pid: 700, parentPID: 701, executablePath: "/usr/bin/java", localizedName: "java"),
            701: ProcessRecord(pid: 701, parentPID: 700, executablePath: "/bin/zsh"),
        ]
        // Parent loop must not hang; nothing better than "java" is known.
        XCTAssertEqual(AppNameResolver().resolve(pid: 700, processes: procs), "java")
        XCTAssertEqual(AppNameResolver().resolve(pid: 999, processes: procs), "Unknown")
    }

    func testOverrideListRoundTrips() throws {
        let list = [AppNameOverride(.pathContains("exocharts"), displayName: "ExoCharts")]
        let data = try JSONEncoder().encode(list)
        XCTAssertEqual(try JSONDecoder().decode([AppNameOverride].self, from: data), list)
    }
}

final class AppTimeTests: XCTestCase {
    let agg = TimeAggregator()

    private func snap(_ t: Date, idle: Double = 5, focused: String? = nil, focusedScreen: String? = "W", screens: [String: [String]] = ["W": ["TradingView"]]) -> TrackerRecord {
        .snapshot(MinuteSnapshot(
            time: t,
            idleSeconds: idle,
            focusedApp: focused,
            focusedScreenID: focusedScreen,
            screens: screens.keys.sorted().map { ScreenContents(screenID: $0, screenName: $0 == "W" ? "Widescreen" : nil, apps: screens[$0]!) }
        ))
    }

    private func minutes(from start: Date, count: Int) -> [Date] {
        (0..<count).map { start.addingTimeInterval(Double($0) * 60) }
    }

    func testFocusedAndVisibleBasic() {
        let start = uk(2026, 7, 1, 9, 0)
        var records: [TrackerRecord] = [.activation(ActivationEvent(time: start, app: "TradingView"))]
        records += minutes(from: start, count: 11).map { snap($0, focused: "TradingView") }
        let tracked = agg.track(records)
        XCTAssertEqual(tracked.focused["TradingView"]?.total, 660)
        XCTAssertEqual(tracked.visible["TradingView"]?.total, 660)
        XCTAssertEqual(tracked.screenNames["W"], "Widescreen")
    }

    func testAppSwitch() {
        let start = uk(2026, 7, 1, 9, 0)
        var records: [TrackerRecord] = [
            .activation(ActivationEvent(time: start, app: "TradingView")),
            .activation(ActivationEvent(time: start.addingTimeInterval(300), app: "ExoCharts")),
        ]
        records += minutes(from: start, count: 10).enumerated().map { i, t in snap(t, focused: i < 5 ? "TradingView" : "ExoCharts") }
        let tracked = agg.track(records)
        XCTAssertEqual(tracked.focused["TradingView"]?.total, 300)
        XCTAssertEqual(tracked.focused["ExoCharts"]?.total, 300)
    }

    func testMissedActivationIsCorrectedBySnapshot() {
        let start = uk(2026, 7, 1, 9, 0)
        var records: [TrackerRecord] = [.activation(ActivationEvent(time: start, app: "TradingView"))]
        records += minutes(from: start, count: 6).enumerated().map { i, t in snap(t, focused: i < 3 ? "TradingView" : "ExoCharts") }
        let tracked = agg.track(records)
        XCTAssertEqual(tracked.focused["TradingView"]?.total, 180)
        XCTAssertEqual(tracked.focused["ExoCharts"]?.total, 180)
    }

    func testIdleGapStopsFocusedTimeButNotVisibleTime() {
        let start = uk(2026, 7, 1, 9, 0)
        var records: [TrackerRecord] = [.activation(ActivationEvent(time: start, app: "TradingView"))]
        let lastInput = start.addingTimeInterval(5 * 60 + 30) // 9:05:30
        let back = start.addingTimeInterval(14 * 60 + 30)    // 9:14:30
        for t in minutes(from: start, count: 21) {
            let idle: Double
            if t <= lastInput {
                idle = 5
            } else if t < back {
                idle = t.timeIntervalSince(lastInput)
            } else {
                idle = min(5, t.timeIntervalSince(back))
            }
            records.append(snap(t, idle: idle, focused: "TradingView"))
        }
        let tracked = agg.track(records)
        // 21 minutes awake, minus 9:05:30-9:14:00 (510 s) of no input.
        XCTAssertEqual(tracked.focused["TradingView"]?.total, 1260 - 510)
        XCTAssertEqual(tracked.visible["TradingView"]?.total, 1260)
    }

    func testShortPausesUnderTwoMinutesStillCount() {
        let start = uk(2026, 7, 1, 9, 0)
        var records: [TrackerRecord] = [.activation(ActivationEvent(time: start, app: "TradingView"))]
        records += minutes(from: start, count: 5).map { snap($0, idle: 119, focused: "TradingView") }
        XCTAssertEqual(agg.track(records).focused["TradingView"]?.total, 300)
    }

    func testTrackerNotRunningIsNotCounted() {
        let start = uk(2026, 7, 1, 9, 0)
        var records: [TrackerRecord] = [.activation(ActivationEvent(time: start, app: "TradingView"))]
        records += minutes(from: start, count: 6).map { snap($0, focused: "TradingView") }
        records += minutes(from: start.addingTimeInterval(3600), count: 6).map { snap($0, focused: "TradingView") }
        XCTAssertEqual(agg.track(records).focused["TradingView"]?.total, 720)
    }

    func testSleepStopsCounting() {
        let start = uk(2026, 7, 1, 9, 0)
        var records: [TrackerRecord] = [.activation(ActivationEvent(time: start, app: "TradingView"))]
        records += minutes(from: start, count: 4).map { snap($0, focused: "TradingView") }
        records.append(.system(SystemEvent(time: start.addingTimeInterval(210), kind: .sleep)))
        records.append(.system(SystemEvent(time: start.addingTimeInterval(450), kind: .wake)))
        records += minutes(from: start.addingTimeInterval(480), count: 3).map { snap($0, focused: "TradingView") }
        let tracked = agg.track(records)
        XCTAssertEqual(tracked.focused["TradingView"]?.total, 420)
        XCTAssertEqual(tracked.visible["TradingView"]?.total, 390)
    }

    func testScreenLockStopsCounting() {
        let start = uk(2026, 7, 1, 9, 0)
        var records: [TrackerRecord] = [.activation(ActivationEvent(time: start, app: "TradingView"))]
        records += minutes(from: start, count: 10).map { snap($0, focused: "TradingView") }
        records.append(.system(SystemEvent(time: start.addingTimeInterval(120), kind: .screenLocked)))
        records.append(.system(SystemEvent(time: start.addingTimeInterval(300), kind: .screenUnlocked)))
        let tracked = agg.track(records)
        XCTAssertEqual(tracked.awake.total, 420)
        XCTAssertEqual(tracked.focused["TradingView"]?.total, 420)
    }

    func testTrackerStoppedEndsCoverage() {
        let start = uk(2026, 7, 1, 9, 0)
        var records: [TrackerRecord] = [.activation(ActivationEvent(time: start, app: "TradingView"))]
        records += minutes(from: start, count: 3).map { snap($0, focused: "TradingView") }
        records.append(.system(SystemEvent(time: start.addingTimeInterval(150), kind: .trackerStopped)))
        XCTAssertEqual(agg.track(records).focused["TradingView"]?.total, 150)
    }

    func testOverlappingScreensCountOncePerApp() {
        let start = uk(2026, 7, 1, 9, 0)
        var records: [TrackerRecord] = [.activation(ActivationEvent(time: start, app: "TradingView"))]
        records += minutes(from: start, count: 10).map {
            snap($0, focused: "TradingView", screens: ["W": ["TradingView"], "A": ["TradingView", "Safari"]])
        }
        let tracked = agg.track(records)
        XCTAssertEqual(tracked.visible["TradingView"]?.total, 600)
        XCTAssertEqual(tracked.visibleByScreen["W"]?["TradingView"]?.total, 600)
        XCTAssertEqual(tracked.visibleByScreen["A"]?["TradingView"]?.total, 600)
        XCTAssertEqual(tracked.visibleByScreen["A"]?["Safari"]?.total, 600)
        XCTAssertEqual(tracked.frontmostByScreen["A"]?["TradingView"]?.total, 600)
        XCTAssertNil(tracked.frontmostByScreen["A"]?["Safari"])

        let report = agg.report(tracked, period: Span(start, start.addingTimeInterval(3600)))
        XCTAssertEqual(report.apps.first(where: { $0.app == "TradingView" })?.visible, 600)
        XCTAssertEqual(report.screens.map(\.name), ["A", "Widescreen"])
    }

    func testFocusedTimePerScreen() {
        let start = uk(2026, 7, 1, 9, 0)
        var records: [TrackerRecord] = [.activation(ActivationEvent(time: start, app: "TradingView"))]
        records += minutes(from: start, count: 10).enumerated().map { i, t in
            snap(t, focused: "TradingView", focusedScreen: i < 5 ? "W" : "A", screens: ["W": ["TradingView"], "A": ["TradingView"]])
        }
        let tracked = agg.track(records)
        XCTAssertEqual(tracked.focusedByScreen["W"]?["TradingView"]?.total, 300)
        XCTAssertEqual(tracked.focusedByScreen["A"]?["TradingView"]?.total, 300)
    }

    func testScreenSummaryLineAndNames() {
        let total = ScreenTotal(screenID: "W", name: "Widescreen", apps: [
            AppTotal(app: "TradingView", focused: 0, visible: 31 * 3600),
            AppTotal(app: "ExoCharts", focused: 0, visible: 6 * 3600),
        ])
        XCTAssertEqual(total.summaryLine(), "Widescreen: TradingView 31h, ExoCharts 6h")

        let start = uk(2026, 7, 1, 9, 0)
        let records = minutes(from: start, count: 3).map { snap($0, focused: "TradingView") }
        let report = agg.report(agg.track(records), period: Span(start, start.addingTimeInterval(3600)), screenNames: ["W": "Samsung 49\""])
        XCTAssertEqual(report.screens.first?.name, "Samsung 49\"")
    }

    // MARK: UK days, weeks, months

    func testMidnightSplitInSummerTime() {
        let start = uk(2026, 7, 1, 23, 30)
        var records: [TrackerRecord] = [.activation(ActivationEvent(time: start, app: "TradingView"))]
        records += minutes(from: start, count: 60).map { snap($0, focused: "TradingView") }
        let tracked = agg.track(records)
        let days = agg.dailyTotals(IntervalSet(tracked.focused["TradingView"]!.spans), period: Span(uk(2026, 7, 1), uk(2026, 7, 3)))
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].focused, 1800)
        XCTAssertEqual(days[1].focused, 1800)
        // UK midnight in July is 23:00 UTC.
        XCTAssertEqual(days[1].dayStart, Date(timeIntervalSince1970: 1_782_946_800))

        let today = agg.report(tracked, .today, now: uk(2026, 7, 2, 12, 0))
        XCTAssertEqual(today.totalFocused, 1800)
        XCTAssertEqual(today.apps.first?.focused, 1800)
    }

    func testDayLengthsAroundClockChanges() {
        let autumn = ReportPeriod.today.span(containing: uk(2026, 10, 25, 12))
        XCTAssertEqual(autumn.duration, 25 * 3600)
        let spring = ReportPeriod.today.span(containing: uk(2026, 3, 29, 12))
        XCTAssertEqual(spring.duration, 23 * 3600)
        let normal = ReportPeriod.today.span(containing: uk(2026, 7, 1, 12))
        XCTAssertEqual(normal.duration, 24 * 3600)
    }

    func testHoursOfDayWhenClocksGoBack() {
        // 00:30 BST to 02:30 GMT on 25 Oct 2026 is 3 real hours; the 1am hour happens twice.
        let set = IntervalSet([Span(uk(2026, 10, 25, 0, 30), uk(2026, 10, 25, 2, 30))])
        XCTAssertEqual(set.total, 3 * 3600)
        let hours = agg.hoursOfDay(set)
        XCTAssertEqual(hours[0], 1800)
        XCTAssertEqual(hours[1], 7200)
        XCTAssertEqual(hours[2], 1800)
        XCTAssertEqual(hours.reduce(0, +), 3 * 3600)
    }

    func testHoursOfDayWhenClocksGoForward() {
        // 00:30 GMT to 03:30 BST on 29 Mar 2026 is 2 real hours; 1am never happens.
        let set = IntervalSet([Span(uk(2026, 3, 29, 0, 30), uk(2026, 3, 29, 3, 30))])
        XCTAssertEqual(set.total, 2 * 3600)
        let hours = agg.hoursOfDay(set)
        XCTAssertEqual(hours[0], 1800)
        XCTAssertEqual(hours[1], 0)
        XCTAssertEqual(hours[2], 3600)
        XCTAssertEqual(hours[3], 1800)
    }

    func testWeeksStartMondayAndMonthsUseUKTime() {
        let week = ReportPeriod.thisWeek.span(containing: uk(2026, 10, 28, 15))
        XCTAssertEqual(week.start, uk(2026, 10, 26))
        XCTAssertEqual(week.duration, 7 * 86_400)
        let dstWeek = ReportPeriod.thisWeek.span(containing: uk(2026, 10, 25, 15))
        XCTAssertEqual(dstWeek.start, uk(2026, 10, 19))
        XCTAssertEqual(dstWeek.duration, 7 * 86_400 + 3600)
        let month = ReportPeriod.thisMonth.span(containing: uk(2026, 10, 30, 9))
        XCTAssertEqual(month.start, uk(2026, 10, 1))
        XCTAssertEqual(month.duration, 31 * 86_400 + 3600)
    }

    func testWeekAndMonthRollups() {
        var records: [TrackerRecord] = []
        // One hour of TradingView at 10:00 each day, 1-14 October.
        for day in 1...14 {
            let start = uk(2026, 10, day, 10)
            records.append(.activation(ActivationEvent(time: start, app: "TradingView")))
            records += minutes(from: start, count: 60).map { snap($0, focused: "TradingView") }
            records.append(.system(SystemEvent(time: start.addingTimeInterval(3600), kind: .trackerStopped)))
        }
        let tracked = agg.track(records)
        let week = agg.report(tracked, .thisWeek, now: uk(2026, 10, 8, 12)) // Mon 5 - Sun 11
        XCTAssertEqual(week.totalFocused, 7 * 3600)
        XCTAssertEqual(week.days.count, 7)
        XCTAssertTrue(week.days.allSatisfy { $0.focused == 3600 })
        XCTAssertEqual(week.hoursOfDay[10], 7 * 3600)
        let month = agg.report(tracked, .thisMonth, now: uk(2026, 10, 20, 12))
        XCTAssertEqual(month.totalFocused, 14 * 3600)
        XCTAssertEqual(month.days.count, 31)
    }

    // MARK: Timeline

    func testDayTimeline() {
        let start = uk(2026, 7, 1, 9, 0)
        let records = minutes(from: start, count: 10).enumerated().map { i, t in
            snap(t, focused: nil, screens: ["W": [i < 5 ? "TradingView" : "ExoCharts", "Safari"]])
        }
        let timeline = agg.dayTimeline(agg.track(records), day: start)
        XCTAssertEqual(timeline.screens.count, 1)
        let segments = timeline.screens[0].segments
        XCTAssertEqual(segments.map(\.app), ["TradingView", "ExoCharts"])
        XCTAssertEqual(segments[0].start, start)
        XCTAssertEqual(segments[0].duration, 300)
        XCTAssertEqual(segments[1].duration, 300)
        XCTAssertEqual(timeline.day.start, uk(2026, 7, 1))
    }

    // MARK: Volume

    func testAMonthOfMinuteSnapshots() {
        let start = uk(2026, 10, 1)
        let count = 30 * 24 * 60
        var records: [TrackerRecord] = []
        records.reserveCapacity(count + 800)
        let apps = ["TradingView", "ExoCharts", "Safari"]
        for i in 0..<count {
            let t = start.addingTimeInterval(Double(i) * 60)
            if i % 60 == 0 { records.append(.activation(ActivationEvent(time: t, app: apps[(i / 60) % 3]))) }
            records.append(snap(t, focused: apps[(i / 60) % 3], screens: ["W": [apps[(i / 60) % 3]], "A": ["Safari"]]))
        }
        let tracked = agg.track(records)
        let total = tracked.focused.values.reduce(0) { $0 + $1.total }
        XCTAssertEqual(total, Double(count) * 60)
        XCTAssertEqual(tracked.focused["TradingView"]!.total, Double(count) * 20, accuracy: 0.001)
        XCTAssertEqual(tracked.visible["Safari"]?.total, Double(count) * 60)
    }

    // MARK: Storage

    func testRecordsRoundTripThroughRows() throws {
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        let records: [TrackerRecord] = [
            .activation(ActivationEvent(time: t, app: "ExoCharts")),
            .system(SystemEvent(time: t, kind: .sleep)),
            snap(t, idle: 12.5, focused: "Café ☕️", screens: ["W": ["Café ☕️", "TradingView"]]),
        ]
        for record in records {
            let row = try TrackerStorage.encode(record)
            XCTAssertEqual(row.time, 1_790_000_000)
            XCTAssertEqual(try TrackerStorage.decode(row), record)
        }
        XCTAssertThrowsError(try TrackerStorage.decode(TrackerRow(time: 0, kind: "bogus", payload: "{}")))
    }

    func testRetentionIsOneYear() {
        let now = uk(2026, 10, 30, 12)
        XCTAssertEqual(TrackerStorage.retentionCutoff(now: now), uk(2025, 10, 30, 12))
        XCTAssertTrue(TrackerStorage.pruneSQL(now: now).hasPrefix("DELETE FROM records WHERE time < "))
        XCTAssertTrue(TrackerStorage.schema.contains("CREATE TABLE IF NOT EXISTS records"))
    }
}
