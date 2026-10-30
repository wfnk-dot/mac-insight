import Foundation

/// What's saved after a scan so reopening the app is instant and the next
/// scan can show what changed. Stored as JSON (Part B keeps it in
/// ~/Library/Application Support/Mac Insight/last-scan.json).
public struct DiskScanCache: Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var scannedAt: Date
    public var rootPath: String
    public var hadFullDiskAccess: Bool
    public var totalCounted: Int64
    public var fileCount: Int
    /// Pruned tree for the treemap.
    public var tree: DiskItem
    /// Folder sizes down to `folderDepth`, for "changed since last scan".
    public var folderSizes: [String: Int64]
    public var folderDepth: Int
    public var biggestFiles: [BiggestFile]
    public var summary: StorageSummary

    public init(
        result: DiskScanResult,
        summary: StorageSummary,
        scannedAt: Date,
        hadFullDiskAccess: Bool,
        folderDepth: Int = 6,
        pruneBelow: Int64 = 50_000_000
    ) {
        version = Self.currentVersion
        self.scannedAt = scannedAt
        rootPath = result.rootPath
        self.hadFullDiskAccess = hadFullDiskAccess
        totalCounted = result.totalCounted
        fileCount = result.fileCount
        tree = result.root.pruned(minimumSize: pruneBelow)
        folderSizes = result.root.folderSizes(rootPath: result.rootPath, maxDepth: folderDepth)
        self.folderDepth = folderDepth
        biggestFiles = result.biggestFiles
        self.summary = summary
    }

    public enum CacheError: Error, Equatable {
        case unsupportedVersion(Int)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Throws `CacheError.unsupportedVersion` for caches from a newer or
    /// older format; the app should then just scan again.
    public static func decode(_ data: Data) throws -> DiskScanCache {
        struct VersionOnly: Decodable { let version: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let version = try decoder.decode(VersionOnly.self, from: data).version
        guard version == currentVersion else { throw CacheError.unsupportedVersion(version) }
        return try decoder.decode(DiskScanCache.self, from: data)
    }

    /// Growth since this (older) cache, given a fresh scan.
    public func grewSince(newFolderSizes: [String: Int64], limit: Int = 25) -> [FolderChange] {
        ScanDiff.grew(old: folderSizes, new: newFolderSizes, limit: limit)
    }
}
