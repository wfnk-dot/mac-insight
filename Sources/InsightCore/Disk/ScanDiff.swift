import Foundation

public struct FolderChange: Codable, Hashable, Sendable {
    public var path: String
    public var oldSize: Int64
    public var newSize: Int64
    public var delta: Int64 { newSize - oldSize }
}

/// "Changed since last scan": compares folder sizes from two scans.
public enum ScanDiff {
    /// Folders that grew the most, biggest growth first.
    ///
    /// With `collapseParents` (the default), a folder is left out when one of
    /// its subfolders accounts for at least `explainedFraction` of its growth,
    /// so the list points at the folder that actually grew (e.g.
    /// ~/Movies/OBS) rather than every parent above it.
    public static func grew(
        old: [String: Int64],
        new: [String: Int64],
        minimumDelta: Int64 = 1,
        limit: Int = 25,
        collapseParents: Bool = true,
        explainedFraction: Double = 0.9
    ) -> [FolderChange] {
        let changes = allChanges(old: old, new: new)
        var childrenByParent: [String: [FolderChange]] = [:]
        for change in changes.values where change.path != "/" {
            childrenByParent[PathUtils.parent(change.path), default: []].append(change)
        }
        let candidates = changes.values.filter { $0.delta >= max(1, minimumDelta) }
        let kept = candidates.filter { change in
            guard collapseParents else { return true }
            let children = childrenByParent[change.path] ?? []
            return !children.contains { Double($0.delta) >= explainedFraction * Double(change.delta) }
        }
        return Array(kept.sorted { $0.delta != $1.delta ? $0.delta > $1.delta : $0.path < $1.path }.prefix(limit))
    }

    /// Folders that shrank the most (most negative first).
    public static func shrank(old: [String: Int64], new: [String: Int64], limit: Int = 25) -> [FolderChange] {
        let changes = allChanges(old: old, new: new).values.filter { $0.delta < 0 }
        return Array(changes.sorted { $0.delta != $1.delta ? $0.delta < $1.delta : $0.path < $1.path }.prefix(limit))
    }

    static func allChanges(old: [String: Int64], new: [String: Int64]) -> [String: FolderChange] {
        var out: [String: FolderChange] = [:]
        for path in Set(old.keys).union(new.keys) {
            out[path] = FolderChange(path: path, oldSize: old[path] ?? 0, newSize: new[path] ?? 0)
        }
        return out
    }
}
