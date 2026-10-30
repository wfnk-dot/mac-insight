import Foundation

/// A file the duplicate finder looks at (Part B fills these from the scan).
public struct DuplicateCandidate: Codable, Hashable, Sendable {
    public var path: String
    public var size: Int64
    public var created: Date?
    public var modified: Date?
    public var device: UInt64
    public var inode: UInt64
    /// APFS clone ID; files sharing one share their blocks on disk.
    public var cloneID: UInt64?

    public init(path: String, size: Int64, created: Date? = nil, modified: Date? = nil, device: UInt64 = 1, inode: UInt64, cloneID: UInt64? = nil) {
        self.path = path
        self.size = size
        self.created = created
        self.modified = modified
        self.device = device
        self.inode = inode
        self.cloneID = cloneID
    }

    /// Creation date if known, else modification date.
    public var age: Date? { created ?? modified }
}

/// Where file bytes come from. `LocalFileContentSource` reads real files;
/// tests use an in-memory one.
public protocol FileContentSource {
    func read(path: String, offset: Int64, length: Int) throws -> Data
    /// SHA-256 of the whole file as lowercase hex. The default streams 1 MB
    /// chunks through `read`; Part B may override it with CryptoKit.
    func fullHash(path: String, size: Int64) throws -> String
}

extension FileContentSource {
    public func fullHash(path: String, size: Int64) throws -> String {
        var hasher = SHA256Hasher()
        let chunk = 1 << 20
        var offset: Int64 = 0
        while offset < size {
            let data = try read(path: path, offset: offset, length: Int(min(Int64(chunk), size - offset)))
            if data.isEmpty { break }
            hasher.update(data)
            offset += Int64(data.count)
        }
        return hasher.finalizeHex()
    }
}

public struct LocalFileContentSource: FileContentSource {
    public init() {}

    public func read(path: String, offset: Int64, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: length) ?? Data()
    }
}

public enum DuplicateTag: String, Codable, CaseIterable, Sendable {
    /// 100% byte-identical copies.
    case exactDuplicate
    /// Identical files that are APFS clones: they share space, so deleting
    /// one frees little or nothing.
    case apfsClone
    /// Same picture at a different size or in a different format.
    case sameImageDifferentSize
    /// Visually similar but cropped or edited.
    case croppedOrEdited
    /// Same length (±1 s) and matching first frame.
    case similarVideo

    public var title: String {
        switch self {
        case .exactDuplicate: return "Exact duplicate"
        case .apfsClone: return "APFS clone (shares space)"
        case .sameImageDifferentSize: return "Same image, different size or format"
        case .croppedOrEdited: return "Cropped / edited version"
        case .similarVideo: return "Similar video"
        }
    }
}

public struct DuplicateGroup: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// The main tag; decides which filter shows the group.
    public var kind: DuplicateTag
    public var tags: Set<DuplicateTag>
    /// Members, suggested keeper first. Nothing is ever pre-selected for deletion.
    public var files: [DuplicateCandidate]
    public var suggestedKeep: String
    public var keepReason: String
    /// Paths that are APFS clones of another member (they waste no space).
    public var clonePaths: Set<String>
    /// Space freed by trashing all but the keeper (0 for clones, and only
    /// counted for exact duplicates).
    public var wastedBytes: Int64
}

public enum DuplicateScanError: Error, Equatable {
    case cancelled
}

public enum DuplicateStage: String, Sendable {
    case groupingBySize
    case quickHash
    case fullHash
}

/// Exact duplicate finder: group by size -> quick hash of the first and last
/// 64 KB -> full SHA-256. Only byte-identical files end up in a group.
public struct DuplicateFinder {
    public static let edgeBytes = 64 * 1024

    public var source: FileContentSource
    public var home: String?
    /// Called as work progresses: (stage, done, total).
    public var progress: ((DuplicateStage, Int, Int) -> Void)?
    /// Return true to stop; `find` then throws `DuplicateScanError.cancelled`.
    public var isCancelled: () -> Bool

    public init(source: FileContentSource = LocalFileContentSource(), home: String? = nil, progress: ((DuplicateStage, Int, Int) -> Void)? = nil, isCancelled: @escaping () -> Bool = { false }) {
        self.source = source
        self.home = home
        self.progress = progress
        self.isCancelled = isCancelled
    }

    public struct Result: Sendable {
        public var groups: [DuplicateGroup]
        /// Files that couldn't be read (permissions, vanished).
        public var unreadable: [String]
        public var wastedBytes: Int64 { groups.reduce(0) { $0 + $1.wastedBytes } }
        public var summary: String {
            "\(ByteFormat.string(wastedBytes)) in exact duplicates"
        }
    }

    private struct InodeKey: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    public func find(_ candidates: [DuplicateCandidate]) throws -> Result {
        progress?(.groupingBySize, 0, candidates.count)
        // Hard links are the same file, not copies: keep one path per inode.
        // Empty files are all "identical" but waste nothing, so skip them.
        var seen = Set<InodeKey>()
        var bySize: [Int64: [DuplicateCandidate]] = [:]
        for file in candidates where file.size > 0 {
            guard seen.insert(InodeKey(device: file.device, inode: file.inode)).inserted else { continue }
            bySize[file.size, default: []].append(file)
        }
        let sizeGroups = bySize.values.filter { $0.count > 1 }
        progress?(.groupingBySize, candidates.count, candidates.count)

        var unreadable: [String] = []

        // Quick hash.
        let quickTotal = sizeGroups.reduce(0) { $0 + $1.count }
        var quickDone = 0
        var byQuick: [String: [DuplicateCandidate]] = [:]
        for group in sizeGroups {
            for file in group {
                if isCancelled() { throw DuplicateScanError.cancelled }
                do {
                    let hash = try quickHash(file)
                    byQuick["\(file.size):\(hash)", default: []].append(file)
                } catch {
                    unreadable.append(file.path)
                }
                quickDone += 1
                progress?(.quickHash, quickDone, quickTotal)
            }
        }
        let quickGroups = byQuick.filter { $0.value.count > 1 }

        // Full hash (files that fit in the quick hash were hashed whole already).
        let fullTotal = quickGroups.reduce(0) { $0 + $1.value.count }
        var fullDone = 0
        var byFull: [String: [DuplicateCandidate]] = [:]
        for (quickKey, group) in quickGroups {
            for file in group {
                if isCancelled() { throw DuplicateScanError.cancelled }
                if file.size <= Int64(2 * Self.edgeBytes) {
                    byFull[quickKey, default: []].append(file)
                } else {
                    do {
                        let hash = try source.fullHash(path: file.path, size: file.size)
                        byFull["\(file.size):\(hash)", default: []].append(file)
                    } catch {
                        unreadable.append(file.path)
                    }
                }
                fullDone += 1
                progress?(.fullHash, fullDone, fullTotal)
            }
        }

        var groups: [DuplicateGroup] = []
        for (key, files) in byFull where files.count > 1 {
            groups.append(Self.makeExactGroup(id: key, files: files, home: home))
        }
        groups.sort { a, b in a.wastedBytes != b.wastedBytes ? a.wastedBytes > b.wastedBytes : a.id < b.id }
        return Result(groups: groups, unreadable: unreadable.sorted())
    }

    /// SHA-256 of the first and last 64 KB (the whole file if it's 128 KB or less).
    func quickHash(_ file: DuplicateCandidate) throws -> String {
        var hasher = SHA256Hasher()
        let edge = Int64(Self.edgeBytes)
        if file.size <= 2 * edge {
            hasher.update(try source.read(path: file.path, offset: 0, length: Int(file.size)))
        } else {
            hasher.update(try source.read(path: file.path, offset: 0, length: Self.edgeBytes))
            hasher.update(try source.read(path: file.path, offset: file.size - edge, length: Self.edgeBytes))
        }
        return hasher.finalizeHex()
    }

    static func makeExactGroup(id: String, files: [DuplicateCandidate], home: String?) -> DuplicateGroup {
        let pick = KeepSuggester.suggest(files, home: home)
        let ordered = [pick.file] + files.filter { $0.path != pick.file.path }.sorted { $0.path < $1.path }

        // Each clone family shares one copy of the data.
        var familyCounts: [String: Int] = [:]
        for file in files {
            if let clone = file.cloneID { familyCounts["\(file.device):\(clone)", default: 0] += 1 }
        }
        var clonePaths = Set<String>()
        var storageUnits = 0
        var countedFamilies = Set<String>()
        for file in files {
            if let clone = file.cloneID, let n = familyCounts["\(file.device):\(clone)"], n > 1 {
                clonePaths.insert(file.path)
                if countedFamilies.insert("\(file.device):\(clone)").inserted { storageUnits += 1 }
            } else {
                storageUnits += 1
            }
        }
        var tags: Set<DuplicateTag> = [.exactDuplicate]
        if !clonePaths.isEmpty { tags.insert(.apfsClone) }
        let size = files[0].size
        return DuplicateGroup(
            id: id,
            kind: .exactDuplicate,
            tags: tags,
            files: ordered,
            suggestedKeep: pick.file.path,
            keepReason: pick.reason,
            clonePaths: clonePaths,
            wastedBytes: Int64(max(0, storageUnits - 1)) * size
        )
    }
}
