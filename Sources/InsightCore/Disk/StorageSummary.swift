import Foundation

/// A local Time Machine snapshot, as listed by `tmutil listlocalsnapshots /`.
public struct LocalSnapshot: Codable, Hashable, Sendable {
    public var name: String
    public var date: Date?
}

public enum TMUtilParser {
    /// Parses `tmutil listlocalsnapshots /` output. Handles both the old
    /// format (bare names) and the newer one with a "Snapshots for disk /:"
    /// header. Names look like `com.apple.TimeMachine.2026-10-29-101530.local`;
    /// the time in the name is local time in `timeZone`.
    public static func parseLocalSnapshots(_ output: String, timeZone: TimeZone = .current) -> [LocalSnapshot] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var result: [LocalSnapshot] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("com.apple.TimeMachine.") else { continue }
            let core = line.dropFirst("com.apple.TimeMachine.".count)
            let stamp = core.hasSuffix(".local") ? String(core.dropLast(".local".count)) : String(core)
            result.append(LocalSnapshot(name: line, date: parseStamp(stamp, calendar: calendar)))
        }
        return result
    }

    /// "2026-10-29-101530" -> Date
    static func parseStamp(_ stamp: String, calendar: Calendar) -> Date? {
        let parts = stamp.split(separator: "-")
        guard parts.count == 4, parts[3].count == 6,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let hms = Int(parts[3]) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hms / 10000
        components.minute = (hms / 100) % 100
        components.second = hms % 100
        return calendar.date(from: components)
    }
}

public struct BucketTotal: Codable, Hashable, Sendable {
    public var bucket: StorageBucket
    public var bytes: Int64
    public var fileCount: Int
    /// Extra detail, e.g. "3 snapshots" or "estimated".
    public var detail: String?

    public var title: String { bucket.title }
    public var note: String { bucket.note }
}

public struct FolderTotal: Codable, Hashable, Sendable {
    public var path: String
    public var bytes: Int64
}

/// What Part B knows about the volume beyond the file scan.
public struct VolumeFacts: Codable, Sendable {
    /// Used bytes as macOS reports them (capacity minus available).
    public var usedBytes: Int64?
    /// Space macOS reports as purgeable ("important" minus "available").
    public var purgeableBytes: Int64?
    public var snapshots: [LocalSnapshot]
    /// Size held by snapshots, if Part B can measure it.
    public var snapshotBytes: Int64?
    public var hasFullDiskAccess: Bool
    /// Folders the scanner couldn't read.
    public var unreadableFolders: [String]

    public init(
        usedBytes: Int64? = nil,
        purgeableBytes: Int64? = nil,
        snapshots: [LocalSnapshot] = [],
        snapshotBytes: Int64? = nil,
        hasFullDiskAccess: Bool = true,
        unreadableFolders: [String] = []
    ) {
        self.usedBytes = usedBytes
        self.purgeableBytes = purgeableBytes
        self.snapshots = snapshots
        self.snapshotBytes = snapshotBytes
        self.hasFullDiskAccess = hasFullDiskAccess
        self.unreadableFolders = unreadableFolders
    }
}

/// "Explain my storage": named buckets that add up to what macOS says is used.
public struct StorageSummary: Codable, Sendable {
    /// Biggest first; empty buckets left out.
    public var buckets: [BucketTotal]
    /// Biggest folders inside "Everything else".
    public var everythingElseTopFolders: [FolderTotal]
    public var scannedBytes: Int64
    public var usedBytes: Int64?
    /// Fraction of macOS "used" space the scan explains (0...1), if known.
    public var coverage: Double?
    public var isComplete: Bool
    /// Banner text for the top of the results, or nil when all is well.
    public var warning: String?

    public static func make(
        files: [AccountedFile],
        classifier: BucketClassifier,
        facts: VolumeFacts,
        topFolderLimit: Int = 15
    ) -> StorageSummary {
        var bytes: [StorageBucket: Int64] = [:]
        var counts: [StorageBucket: Int] = [:]
        var otherFolders: [String: Int64] = [:]
        var scanned: Int64 = 0
        for file in files {
            let bucket = classifier.classify(file.path)
            bytes[bucket, default: 0] += file.countedBytes
            counts[bucket, default: 0] += 1
            scanned += file.countedBytes
            if bucket == .everythingElse {
                otherFolders[classifier.topFolder(for: file.path), default: 0] += file.countedBytes
            }
        }

        var totals: [BucketTotal] = StorageBucket.allCases.compactMap { bucket in
            guard let b = bytes[bucket], b > 0 else { return nil }
            return BucketTotal(bucket: bucket, bytes: b, fileCount: counts[bucket] ?? 0, detail: nil)
        }

        // Space the scan can't see: snapshots, purgeable, blocked folders.
        var unexplained: Int64 = 0
        if let used = facts.usedBytes { unexplained = max(0, used - scanned) }
        if !facts.snapshots.isEmpty || (facts.snapshotBytes ?? 0) > 0 {
            let count = facts.snapshots.count
            let label = "\(count) snapshot\(count == 1 ? "" : "s")"
            var size = facts.snapshotBytes ?? 0
            if facts.usedBytes != nil { size = min(size, unexplained) }
            unexplained -= size
            totals.append(BucketTotal(
                bucket: .timeMachineSnapshots,
                bytes: size,
                fileCount: 0,
                detail: facts.snapshotBytes == nil ? label + ", size included in \"Not found by the scan\"" : label
            ))
        }
        if let purgeable = facts.purgeableBytes, purgeable > 0 {
            // Purgeable space overlaps with what's already counted (snapshots,
            // caches), so it's shown for information, not added to the total.
            totals.append(BucketTotal(bucket: .purgeable, bytes: purgeable, fileCount: 0, detail: "already included above"))
        }
        if unexplained > 0 {
            totals.append(BucketTotal(bucket: .notFound, bytes: unexplained, fileCount: 0, detail: nil))
        }
        totals.sort { a, b in a.bytes != b.bytes ? a.bytes > b.bytes : a.bucket.rawValue < b.bucket.rawValue }

        let folders = otherFolders
            .map { FolderTotal(path: $0.key, bytes: $0.value) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
            .prefix(topFolderLimit)

        var coverage: Double?
        if let used = facts.usedBytes, used > 0 { coverage = min(1, Double(scanned) / Double(used)) }

        var warning: String?
        if !facts.hasFullDiskAccess {
            warning = "This scan is incomplete: Mac Insight doesn't have Full Disk Access, so some folders were skipped. Turn it on in System Settings > Privacy & Security > Full Disk Access."
        } else if !facts.unreadableFolders.isEmpty {
            let n = facts.unreadableFolders.count
            warning = "\(n) folder\(n == 1 ? "" : "s") couldn't be read, so the totals may be a little low."
        }

        return StorageSummary(
            buckets: totals,
            everythingElseTopFolders: Array(folders),
            scannedBytes: scanned,
            usedBytes: facts.usedBytes,
            coverage: coverage,
            isComplete: facts.hasFullDiskAccess && facts.unreadableFolders.isEmpty,
            warning: warning
        )
    }
}
