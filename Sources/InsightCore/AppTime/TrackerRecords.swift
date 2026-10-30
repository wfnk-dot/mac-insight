import Foundation

/// The frontmost app changed (from `NSWorkspace.didActivateApplicationNotification`).
public struct ActivationEvent: Codable, Hashable, Sendable {
    public var time: Date
    /// Already resolved with `AppNameResolver`.
    public var app: String

    public init(time: Date, app: String) {
        self.time = time
        self.app = app
    }
}

public struct SystemEvent: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case sleep, wake, screenLocked, screenUnlocked, screensSlept, screensWoke, trackerStarted, trackerStopped
    }

    public var time: Date
    public var kind: Kind

    public init(time: Date, kind: Kind) {
        self.time = time
        self.kind = kind
    }
}

/// What one screen showed at snapshot time.
public struct ScreenContents: Codable, Hashable, Sendable {
    /// Stable ID (Part B uses the display's UUID).
    public var screenID: String
    /// Friendly name if known, e.g. "Widescreen".
    public var screenName: String?
    /// Apps with a visible window on this screen, frontmost first. A window
    /// spanning two screens appears on both.
    public var apps: [String]

    public init(screenID: String, screenName: String? = nil, apps: [String]) {
        self.screenID = screenID
        self.screenName = screenName
        self.apps = apps
    }
}

/// The once-a-minute snapshot from `CGWindowListCopyWindowInfo`.
public struct MinuteSnapshot: Codable, Hashable, Sendable {
    public var time: Date
    /// Seconds since the last mouse or keyboard input.
    public var idleSeconds: Double
    public var focusedApp: String?
    /// Screen holding the focused window.
    public var focusedScreenID: String?
    public var screens: [ScreenContents]

    public init(time: Date, idleSeconds: Double, focusedApp: String?, focusedScreenID: String?, screens: [ScreenContents]) {
        self.time = time
        self.idleSeconds = idleSeconds
        self.focusedApp = focusedApp
        self.focusedScreenID = focusedScreenID
        self.screens = screens
    }
}

/// Anything the tracker writes, in one stream.
public enum TrackerRecord: Codable, Hashable, Sendable {
    case activation(ActivationEvent)
    case system(SystemEvent)
    case snapshot(MinuteSnapshot)

    public var time: Date {
        switch self {
        case .activation(let e): return e.time
        case .system(let e): return e.time
        case .snapshot(let s): return s.time
        }
    }
}

/// How records map onto SQLite rows: `(time REAL, kind TEXT, payload TEXT)`.
/// `time` is seconds since 1970 (UTC); `payload` is JSON.
public struct TrackerRow: Hashable, Sendable {
    public var time: Double
    public var kind: String
    public var payload: String

    public init(time: Double, kind: String, payload: String) {
        self.time = time
        self.kind = kind
        self.payload = payload
    }
}

public enum TrackerStorage {
    /// SQL that creates the tracker's table. One row per snapshot (about one a
    /// minute) plus one per app switch.
    public static let schema = """
    CREATE TABLE IF NOT EXISTS records (
        time REAL NOT NULL,
        kind TEXT NOT NULL,
        payload TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS records_time ON records(time);
    """

    /// Records older than this are deleted (kept for one year).
    public static func retentionCutoff(now: Date, calendar: Calendar = UKTime.calendar) -> Date {
        calendar.date(byAdding: .year, value: -1, to: now) ?? now.addingTimeInterval(-366 * 86_400)
    }

    public static func pruneSQL(now: Date) -> String {
        "DELETE FROM records WHERE time < \(retentionCutoff(now: now).timeIntervalSince1970);"
    }

    public static func encode(_ record: TrackerRecord) throws -> TrackerRow {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let kind: String
        let data: Data
        switch record {
        case .activation(let e):
            kind = "activation"
            data = try encoder.encode(e)
        case .system(let e):
            kind = "system"
            data = try encoder.encode(e)
        case .snapshot(let s):
            kind = "snapshot"
            data = try encoder.encode(s)
        }
        return TrackerRow(time: record.time.timeIntervalSince1970, kind: kind, payload: String(decoding: data, as: UTF8.self))
    }

    public enum DecodeError: Error, Equatable {
        case unknownKind(String)
    }

    public static func decode(_ row: TrackerRow) throws -> TrackerRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let data = Data(row.payload.utf8)
        switch row.kind {
        case "activation": return .activation(try decoder.decode(ActivationEvent.self, from: data))
        case "system": return .system(try decoder.decode(SystemEvent.self, from: data))
        case "snapshot": return .snapshot(try decoder.decode(MinuteSnapshot.self, from: data))
        default: throw DecodeError.unknownKind(row.kind)
        }
    }
}

/// Calendar maths in UK time (GMT in winter, BST in summer).
public enum UKTime {
    public static let timeZone = TimeZone(identifier: "Europe/London")!

    /// Gregorian, Europe/London, weeks start on Monday.
    public static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        c.locale = Locale(identifier: "en_GB")
        return c
    }
}
