import Foundation

/// A half-open time span [start, end).
public struct Span: Hashable, Codable, Sendable {
    public var start: Date
    public var end: Date

    public init(_ start: Date, _ end: Date) {
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    public var isEmpty: Bool { end <= start }
}

/// A sorted set of non-overlapping spans with union, intersection and
/// subtraction. Used to combine "tracker running", "asleep", "idle" and
/// "focused on app X" into exact durations.
public struct IntervalSet: Equatable, Sendable {
    public private(set) var spans: [Span]

    public init() { spans = [] }

    public init<S: Sequence>(_ input: S) where S.Element == Span {
        let sorted = input.filter { !$0.isEmpty }.sorted { $0.start < $1.start }
        var merged: [Span] = []
        for span in sorted {
            if let last = merged.last, span.start <= last.end {
                if span.end > last.end { merged[merged.count - 1].end = span.end }
            } else {
                merged.append(span)
            }
        }
        spans = merged
    }

    public var total: TimeInterval { spans.reduce(0) { $0 + $1.duration } }
    public var isEmpty: Bool { spans.isEmpty }

    public func union(_ other: IntervalSet) -> IntervalSet {
        IntervalSet(spans + other.spans)
    }

    public func intersection(_ other: IntervalSet) -> IntervalSet {
        var result: [Span] = []
        var i = 0, j = 0
        while i < spans.count && j < other.spans.count {
            let a = spans[i], b = other.spans[j]
            let start = max(a.start, b.start)
            let end = min(a.end, b.end)
            if start < end { result.append(Span(start, end)) }
            if a.end < b.end { i += 1 } else { j += 1 }
        }
        var set = IntervalSet()
        set.spans = result
        return set
    }

    public func subtracting(_ other: IntervalSet) -> IntervalSet {
        var result: [Span] = []
        var j = 0
        for span in spans {
            var cursor = span.start
            while j < other.spans.count && other.spans[j].end <= cursor { j += 1 }
            var k = j
            while k < other.spans.count && other.spans[k].start < span.end {
                let cut = other.spans[k]
                if cut.start > cursor { result.append(Span(cursor, cut.start)) }
                cursor = max(cursor, cut.end)
                if cursor >= span.end { break }
                k += 1
            }
            if cursor < span.end { result.append(Span(cursor, span.end)) }
        }
        var set = IntervalSet()
        set.spans = result
        return set
    }

    public func clipped(to range: Span) -> IntervalSet {
        intersection(IntervalSet([range]))
    }
}

/// Union-find used to merge pairwise "these look alike" matches into groups.
struct UnionFind {
    private var parent: [Int]
    private var rank: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        rank = Array(repeating: 0, count: count)
    }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var node = x
        while parent[node] != root {
            let next = parent[node]
            parent[node] = root
            node = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        if ra == rb { return }
        if rank[ra] < rank[rb] {
            parent[ra] = rb
        } else if rank[ra] > rank[rb] {
            parent[rb] = ra
        } else {
            parent[rb] = ra
            rank[ra] += 1
        }
    }

    /// Groups with two or more members, each sorted by index.
    mutating func groups() -> [[Int]] {
        var byRoot: [Int: [Int]] = [:]
        for i in 0..<parent.count { byRoot[find(i), default: []].append(i) }
        return byRoot.values.filter { $0.count > 1 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }
}
