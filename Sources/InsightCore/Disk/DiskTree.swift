import Foundation

/// A folder or file in the disk map. Children are sorted biggest first.
public struct DiskItem: Codable, Hashable, Sendable {
    public var name: String
    /// Counted bytes, including everything inside.
    public var size: Int64
    /// Number of files inside (1 for a file).
    public var fileCount: Int
    public var isDirectory: Bool
    public var children: [DiskItem]

    public init(name: String, size: Int64, fileCount: Int, isDirectory: Bool, children: [DiskItem] = []) {
        self.name = name
        self.size = size
        self.fileCount = fileCount
        self.isDirectory = isDirectory
        self.children = children
    }

    /// Walks down by name, e.g. `["Users", "wyn", "Movies"]`. Used for zooming
    /// into the treemap and for breadcrumbs.
    public func descendant(_ names: [String]) -> DiskItem? {
        var node = self
        for name in names {
            let key = name.precomposedStringWithCanonicalMapping
            guard let next = node.children.first(where: { $0.name == key }) else { return nil }
            node = next
        }
        return node
    }

    /// Folder path -> size for every folder down to `maxDepth` (root is depth 0).
    /// Used for "changed since last scan".
    public func folderSizes(rootPath: String = "/", maxDepth: Int) -> [String: Int64] {
        var out: [String: Int64] = [:]
        func walk(_ item: DiskItem, _ path: String, _ depth: Int) {
            guard item.isDirectory else { return }
            out[path] = item.size
            guard depth < maxDepth else { return }
            for child in item.children where child.isDirectory {
                walk(child, path == "/" ? "/" + child.name : path + "/" + child.name, depth + 1)
            }
        }
        walk(self, rootPath, 0)
        return out
    }

    /// A smaller copy for the cache: keeps everything down to `keepDepth`, and
    /// deeper items only if at least `minimumSize`. Dropped siblings are merged
    /// into one "N smaller items" entry so sizes still add up.
    public func pruned(minimumSize: Int64, keepDepth: Int = 2) -> DiskItem {
        func prune(_ item: DiskItem, _ depth: Int) -> DiskItem {
            guard item.isDirectory else { return item }
            var kept: [DiskItem] = []
            var droppedSize: Int64 = 0
            var droppedFiles = 0
            var droppedCount = 0
            for child in item.children {
                if depth + 1 <= keepDepth || child.size >= minimumSize {
                    kept.append(prune(child, depth + 1))
                } else {
                    droppedSize += child.size
                    droppedFiles += child.fileCount
                    droppedCount += 1
                }
            }
            if droppedCount > 0 {
                kept.append(DiskItem(
                    name: "\(droppedCount) smaller item\(droppedCount == 1 ? "" : "s")",
                    size: droppedSize,
                    fileCount: droppedFiles,
                    isDirectory: false
                ))
                kept.sort(by: DiskItem.biggestFirst)
            }
            var copy = item
            copy.children = kept
            return copy
        }
        return prune(self, 0)
    }

    static func biggestFirst(_ a: DiskItem, _ b: DiskItem) -> Bool {
        if a.size != b.size { return a.size > b.size }
        return a.name < b.name
    }
}

public struct BiggestFile: Codable, Hashable, Sendable {
    public var path: String
    public var size: Int64
    public var modified: Date?

    public init(path: String, size: Int64, modified: Date?) {
        self.path = path
        self.size = size
        self.modified = modified
    }
}

public struct DiskScanResult: Sendable {
    public var root: DiskItem
    public var rootPath: String
    /// Sum of counted bytes (what the files really occupy).
    public var totalCounted: Int64
    /// Sum of logical sizes, for comparison.
    public var totalLogical: Int64
    public var fileCount: Int
    /// Bytes not counted twice thanks to hard-link de-duplication.
    public var hardLinkSavings: Int64
    /// Bytes not counted twice because APFS clones share blocks.
    public var cloneSavings: Int64
    public var biggestFiles: [BiggestFile]
    public var accounted: [AccountedFile]
}

/// Builds the disk map tree from scanner records.
public struct DiskTreeBuilder {
    public var rootPath: String
    public var biggestFileLimit: Int
    public var accounting: SpaceAccounting

    public init(rootPath: String = "/", biggestFileLimit: Int = 100, accounting: SpaceAccounting = SpaceAccounting()) {
        self.rootPath = PathUtils.normalize(rootPath)
        self.biggestFileLimit = biggestFileLimit
        self.accounting = accounting
    }

    private final class Node {
        let name: String
        var size: Int64 = 0
        var fileCount = 0
        var isDirectory: Bool
        var children: [String: Node] = [:]

        init(name: String, isDirectory: Bool) {
            self.name = name
            self.isDirectory = isDirectory
        }

        func freeze() -> DiskItem {
            let frozen = children.values.map { $0.freeze() }.sorted(by: DiskItem.biggestFirst)
            return DiskItem(name: name, size: size, fileCount: fileCount, isDirectory: isDirectory, children: frozen)
        }
    }

    public func build(_ records: [FileRecord]) -> DiskScanResult {
        let rootComponents = PathUtils.components(rootPath)
        let root = Node(name: rootPath, isDirectory: true)
        var totalLogical: Int64 = 0
        var hardLinkSavings: Int64 = 0
        var cloneSavings: Int64 = 0
        var top = TopList(limit: biggestFileLimit)
        let accounted = accounting.account(records)

        func insert(_ components: ArraySlice<String>, isDirectory: Bool, bytes: Int64, isFile: Bool) {
            var node = root
            node.size += bytes
            if isFile { node.fileCount += 1 }
            var index = components.startIndex
            while index < components.endIndex {
                let name = components[index]
                let isLast = index == components.endIndex - 1
                let child: Node
                if let existing = node.children[name] {
                    child = existing
                    if !isLast || isDirectory { child.isDirectory = true }
                } else {
                    child = Node(name: name, isDirectory: !isLast || isDirectory)
                    node.children[name] = child
                }
                child.size += bytes
                if isFile { child.fileCount += 1 }
                node = child
                index += 1
            }
        }

        func relative(_ path: String) -> ArraySlice<String>? {
            let parts = PathUtils.components(path)
            guard parts.count >= rootComponents.count, Array(parts.prefix(rootComponents.count)) == rootComponents else {
                return nil
            }
            return parts[rootComponents.count...]
        }

        // Folders first, so empty folders still show up.
        for record in records where record.isDirectory {
            if let parts = relative(PathUtils.normalize(record.path)), !parts.isEmpty {
                insert(parts, isDirectory: true, bytes: 0, isFile: false)
            }
        }

        var included: [AccountedFile] = []
        included.reserveCapacity(accounted.count)
        for file in accounted {
            guard let parts = relative(file.path), !parts.isEmpty else { continue }
            included.append(file)
            insert(parts, isDirectory: false, bytes: file.countedBytes, isFile: true)
            totalLogical += max(0, file.record.logicalSize)
            let allocated = AllocationMath.allocated(file.record, blockSize: accounting.blockSize)
            switch file.shared {
            case .hardLink:
                hardLinkSavings += allocated
            case .clone:
                cloneSavings += allocated - file.countedBytes
            case .none:
                top.offer(BiggestFile(path: file.path, size: allocated, modified: file.record.modified))
            }
        }

        return DiskScanResult(
            root: root.freeze(),
            rootPath: rootPath,
            totalCounted: root.size,
            totalLogical: totalLogical,
            fileCount: root.fileCount,
            hardLinkSavings: hardLinkSavings,
            cloneSavings: cloneSavings,
            biggestFiles: top.items,
            accounted: included
        )
    }
}

/// Keeps the N biggest files without sorting everything.
struct TopList {
    let limit: Int
    private(set) var items: [BiggestFile] = []

    init(limit: Int) { self.limit = limit }

    mutating func offer(_ file: BiggestFile) {
        guard limit > 0 else { return }
        if items.count == limit, let smallest = items.last, !TopList.ranksAbove(file, smallest) { return }
        var low = 0, high = items.count
        while low < high {
            let mid = (low + high) / 2
            if TopList.ranksAbove(items[mid], file) { low = mid + 1 } else { high = mid }
        }
        items.insert(file, at: low)
        if items.count > limit { items.removeLast() }
    }

    static func ranksAbove(_ a: BiggestFile, _ b: BiggestFile) -> Bool {
        if a.size != b.size { return a.size > b.size }
        return a.path < b.path
    }
}
