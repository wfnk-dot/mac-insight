import Foundation

/// A rectangle in treemap space (no CoreGraphics, so it works on Linux).
public struct TreemapRect: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { width * height }
}

/// Squarified treemap layout (Bruls, Huijsing & van Wijk). Rectangles come
/// back in the same order as the sizes passed in.
public enum Treemap {
    public static func layout(sizes: [Double], in bounds: TreemapRect) -> [TreemapRect] {
        var result = [TreemapRect](repeating: TreemapRect(x: bounds.x, y: bounds.y, width: 0, height: 0), count: sizes.count)
        let total = sizes.reduce(0) { $0 + max(0, $1) }
        guard total > 0, bounds.area > 0 else { return result }

        // Work biggest first for good aspect ratios; remember original slots.
        let order = sizes.indices.filter { sizes[$0] > 0 }.sorted { sizes[$0] > sizes[$1] }
        let scale = bounds.area / total
        let areas = order.map { sizes[$0] * scale }

        var free = bounds
        var row: [Int] = []
        var i = 0
        while i < areas.count {
            let side = min(free.width, free.height)
            let candidate = row + [i]
            if row.isEmpty || worst(candidate.map { areas[$0] }, side: side) <= worst(row.map { areas[$0] }, side: side) {
                row = candidate
                i += 1
            } else {
                free = place(row, areas: areas, order: order, in: free, into: &result)
                row = []
            }
        }
        if !row.isEmpty { _ = place(row, areas: areas, order: order, in: free, into: &result) }
        return result
    }

    private static func worst(_ row: [Double], side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard sum > 0, side > 0, let maxA = row.max(), let minA = row.min(), minA > 0 else { return .infinity }
        let s2 = side * side
        let sum2 = sum * sum
        return max(s2 * maxA / sum2, sum2 / (s2 * minA))
    }

    /// Lays a row along the shorter side of `free`; returns the space left.
    private static func place(_ row: [Int], areas: [Double], order: [Int], in free: TreemapRect, into result: inout [TreemapRect]) -> TreemapRect {
        let rowArea = row.reduce(0) { $0 + areas[$1] }
        if free.width >= free.height {
            // Column on the left.
            let columnWidth = free.height > 0 ? rowArea / free.height : 0
            var y = free.y
            for index in row {
                let h = columnWidth > 0 ? areas[index] / columnWidth : 0
                result[order[index]] = TreemapRect(x: free.x, y: y, width: columnWidth, height: h)
                y += h
            }
            return TreemapRect(x: free.x + columnWidth, y: free.y, width: max(0, free.width - columnWidth), height: free.height)
        } else {
            // Row along the top.
            let rowHeight = free.width > 0 ? rowArea / free.width : 0
            var x = free.x
            for index in row {
                let w = rowHeight > 0 ? areas[index] / rowHeight : 0
                result[order[index]] = TreemapRect(x: x, y: free.y, width: w, height: rowHeight)
                x += w
            }
            return TreemapRect(x: free.x, y: free.y + rowHeight, width: free.width, height: max(0, free.height - rowHeight))
        }
    }
}
