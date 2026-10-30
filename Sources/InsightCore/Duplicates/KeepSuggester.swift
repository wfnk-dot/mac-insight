import Foundation

/// Suggests which copy to keep. It only ever suggests; nothing is selected
/// for deletion.
///
/// Rule: the copy in the most "organised" folder wins; if that's a tie, the
/// oldest copy; then the shortest path; then alphabetical.
public enum KeepSuggester {
    public struct Pick {
        public var file: DuplicateCandidate
        public var reason: String
    }

    /// Higher is tidier. Downloads, Desktop, Trash and temp folders score
    /// low; "copy" / "(1)" style names score low; Documents, Pictures etc.
    /// score higher.
    public static func organisationScore(_ path: String, home: String?) -> Int {
        var score = 0
        let lower = path.lowercased()
        let parts = PathUtils.components(lower)
        let name = parts.last ?? lower
        let folders = Set(parts.dropLast())

        let messy: Set<String> = ["downloads", "desktop", ".trash", "tmp", "temp", "caches", "untitled folder", "new folder"]
        if !folders.isDisjoint(with: messy) { score -= 3 }
        if folders.contains(where: { $0.hasPrefix("untitled") || $0.hasPrefix("new folder") }) { score -= 1 }

        let tidy: Set<String> = ["documents", "pictures", "movies", "music", "projects", "archive", "photos"]
        if !folders.isDisjoint(with: tidy) { score += 1 }

        if looksLikeCopyName(name) { score -= 2 }
        return score
    }

    /// "photo copy.jpg", "photo copy 2.jpg", "photo (1).jpg", "Copy of photo.jpg", "photo-1.jpg"
    public static func looksLikeCopyName(_ lowercasedName: String) -> Bool {
        var stem = lowercasedName
        if let dot = stem.lastIndex(of: "."), dot != stem.startIndex { stem = String(stem[..<dot]) }
        if stem.hasPrefix("copy of ") { return true }
        if stem.hasSuffix(" copy") { return true }
        if let range = stem.range(of: " copy ", options: .backwards),
           Int(stem[range.upperBound...]) != nil { return true }
        if stem.hasSuffix(")"), let open = stem.lastIndex(of: "(") {
            let inside = stem[stem.index(after: open)..<stem.index(before: stem.endIndex)]
            if Int(inside) != nil { return true }
        }
        return false
    }

    public static func suggest(_ files: [DuplicateCandidate], home: String?) -> Pick {
        precondition(!files.isEmpty)
        let scored = files.map { (file: $0, score: organisationScore($0.path, home: home)) }
        let best = scored.min { a, b in
            if a.score != b.score { return a.score > b.score }
            switch (a.file.age, b.file.age) {
            case let (x?, y?) where x != y: return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            default: break
            }
            if a.file.path.count != b.file.path.count { return a.file.path.count < b.file.path.count }
            return a.file.path < b.file.path
        }!
        let topScores = scored.filter { $0.score == best.score }.count
        let reason: String
        if topScores < scored.count {
            reason = "In the tidiest folder"
        } else if best.file.age != nil && scored.contains(where: { $0.file.age != best.file.age }) {
            reason = "Oldest copy"
        } else {
            reason = "Shortest path"
        }
        return Pick(file: best.file, reason: reason)
    }
}
