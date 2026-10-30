import Foundation

/// One item found by the scanner (Part B fills these from `getattrlistbulk`).
public struct FileRecord: Codable, Hashable, Sendable {
    /// Absolute path. Any Unicode form is fine; it is normalised to NFC.
    public var path: String
    /// Length of the file's contents (`st_size`).
    public var logicalSize: Int64
    /// Bytes really allocated on disk (`ATTR_FILE_ALLOCSIZE`). When nil it is
    /// estimated by rounding the logical size up to whole blocks.
    public var allocatedSize: Int64?
    public var device: UInt64
    public var inode: UInt64
    /// Number of hard links (`st_nlink`).
    public var linkCount: Int
    /// APFS clone ID (`ATTR_CMNEXT_CLONEID`). Files with the same non-nil
    /// clone ID on the same device share their data blocks.
    public var cloneID: UInt64?
    /// Bytes owned only by this file and not shared with any clone
    /// (`ATTR_CMNEXT_PRIVATESIZE`). Optional.
    public var privateSize: Int64?
    public var modified: Date?
    public var isDirectory: Bool

    public init(
        path: String,
        logicalSize: Int64,
        allocatedSize: Int64? = nil,
        device: UInt64 = 1,
        inode: UInt64,
        linkCount: Int = 1,
        cloneID: UInt64? = nil,
        privateSize: Int64? = nil,
        modified: Date? = nil,
        isDirectory: Bool = false
    ) {
        self.path = path
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.device = device
        self.inode = inode
        self.linkCount = linkCount
        self.cloneID = cloneID
        self.privateSize = privateSize
        self.modified = modified
        self.isDirectory = isDirectory
    }
}

public enum AllocationMath {
    /// APFS allocates in 4 KB blocks.
    public static let defaultBlockSize: Int64 = 4096

    /// Rounds a logical size up to whole blocks. Empty files take no blocks.
    public static func roundUp(_ logical: Int64, blockSize: Int64 = defaultBlockSize) -> Int64 {
        guard logical > 0, blockSize > 0 else { return 0 }
        let blocks = (logical + blockSize - 1) / blockSize
        return blocks * blockSize
    }

    /// The on-disk size of a record: the scanner's allocated size if known
    /// (correct for sparse and compressed files), else the rounded estimate.
    public static func allocated(_ record: FileRecord, blockSize: Int64 = defaultBlockSize) -> Int64 {
        if let allocated = record.allocatedSize { return max(0, allocated) }
        return roundUp(record.logicalSize, blockSize: blockSize)
    }
}

/// Why a file's bytes were not (fully) counted.
public enum SharedStorage: String, Codable, Sendable {
    /// Counted in full.
    case none
    /// Another path to the same inode was already counted.
    case hardLink
    /// An APFS clone of a file already counted; only its private bytes count.
    case clone
}

public struct AccountedFile: Sendable {
    public var record: FileRecord
    /// Normalised path.
    public var path: String
    /// Bytes this file adds to the disk total after de-duplication.
    public var countedBytes: Int64
    public var shared: SharedStorage
}

/// Turns raw records into bytes that add up to real disk usage: each inode
/// counts once (hard links, firmlinked duplicates), and each APFS clone family
/// counts its shared blocks once.
public struct SpaceAccounting {
    public var blockSize: Int64

    public init(blockSize: Int64 = AllocationMath.defaultBlockSize) {
        self.blockSize = blockSize
    }

    private struct InodeKey: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private struct CloneKey: Hashable {
        let device: UInt64
        let cloneID: UInt64
    }

    /// Files only (directories are skipped). Input order decides which path of
    /// a hard-linked or cloned set is treated as the "owner"; the first wins.
    public func account(_ records: [FileRecord]) -> [AccountedFile] {
        var firstPathForInode: [InodeKey: String] = [:]
        var seenClones = Set<CloneKey>()
        var result: [AccountedFile] = []
        result.reserveCapacity(records.count)
        for record in records where !record.isDirectory {
            let path = PathUtils.normalize(record.path)
            let allocated = AllocationMath.allocated(record, blockSize: blockSize)
            let inodeKey = InodeKey(device: record.device, inode: record.inode)
            if let firstPath = firstPathForInode[inodeKey] {
                // The same path seen twice (e.g. via /System/Volumes/Data) is
                // dropped; a different path is a hard link and counts 0 bytes.
                if firstPath != path {
                    result.append(AccountedFile(record: record, path: path, countedBytes: 0, shared: .hardLink))
                }
                continue
            }
            firstPathForInode[inodeKey] = path
            if let cloneID = record.cloneID {
                let cloneKey = CloneKey(device: record.device, cloneID: cloneID)
                if !seenClones.insert(cloneKey).inserted {
                    let privateBytes = min(allocated, max(0, record.privateSize ?? 0))
                    result.append(AccountedFile(record: record, path: path, countedBytes: privateBytes, shared: .clone))
                    continue
                }
            }
            result.append(AccountedFile(record: record, path: path, countedBytes: allocated, shared: .none))
        }
        return result
    }
}
