import Foundation

/// Human-readable sizes using decimal units, the same way Finder and
/// About This Mac count them (1 GB = 1,000,000,000 bytes).
public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        if bytes < 0 { return "-" + string(-bytes) }
        if bytes < 1000 { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes) / 1000
        var index = 0
        while value >= 999.95 && index < units.count - 1 {
            value /= 1000
            index += 1
        }
        let text = value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return "\(text) \(units[index])"
    }
}

/// Plain-English durations for the time report, e.g. "31h 5m", "6m", "0m".
public enum DurationFormat {
    public static func string(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int((max(0, seconds) / 60).rounded(.down))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }
}
