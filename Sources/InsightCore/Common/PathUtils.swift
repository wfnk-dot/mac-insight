import Foundation

public enum PathUtils {
    /// Normalises a path the way APFS compares names: Unicode NFC, no
    /// trailing slash, no duplicate slashes, and the Data-volume firmlink
    /// prefix (`/System/Volumes/Data`) folded onto `/` so the same file is
    /// never seen under two paths.
    public static func normalize(_ path: String) -> String {
        var p = path.precomposedStringWithCanonicalMapping
        while p.contains("//") { p = p.replacingOccurrences(of: "//", with: "/") }
        let dataPrefix = "/System/Volumes/Data"
        if p == dataPrefix {
            p = "/"
        } else if p.hasPrefix(dataPrefix + "/") {
            p = String(p.dropFirst(dataPrefix.count))
        }
        if p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Path components without empty pieces: "/a/b" -> ["a", "b"].
    public static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// True when `path` is `folder` or anything inside it.
    @inline(__always)
    public static func isInside(_ path: String, _ folder: String) -> Bool {
        if folder == "/" { return path.hasPrefix("/") }
        return path == folder || path.hasPrefix(folder + "/")
    }

    public static func lastComponent(_ path: String) -> String {
        components(path).last ?? path
    }

    public static func parent(_ path: String) -> String {
        var parts = components(path)
        guard !parts.isEmpty else { return "/" }
        parts.removeLast()
        return "/" + parts.joined(separator: "/")
    }
}
