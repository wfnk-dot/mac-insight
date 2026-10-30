import Foundation

/// An 8-bit greyscale image: `pixels` row by row, top-left first. Part B
/// makes these from a small thumbnail (e.g. 256 px) of each picture.
public struct GreyImage: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init?(width: Int, height: Int, pixels: [UInt8]) {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Area-averaging resize to `w` x `h` (works for shrinking and growing).
    public func resized(width w: Int, height h: Int) -> [Double] {
        let sx = Double(width) / Double(w)
        let sy = Double(height) / Double(h)
        var out = [Double](repeating: 0, count: w * h)
        for oy in 0..<h {
            let y0 = Double(oy) * sy
            let y1 = y0 + sy
            for ox in 0..<w {
                let x0 = Double(ox) * sx
                let x1 = x0 + sx
                var sum = 0.0
                var area = 0.0
                var yy = Int(y0)
                while Double(yy) < y1 && yy < height {
                    let wy = min(y1, Double(yy + 1)) - max(y0, Double(yy))
                    if wy > 0 {
                        var xx = Int(x0)
                        let rowStart = yy * width
                        while Double(xx) < x1 && xx < width {
                            let wx = min(x1, Double(xx + 1)) - max(x0, Double(xx))
                            if wx > 0 {
                                sum += wx * wy * Double(pixels[rowStart + xx])
                                area += wx * wy
                            }
                            xx += 1
                        }
                    }
                    yy += 1
                }
                out[oy * w + ox] = area > 0 ? sum / area : 0
            }
        }
        return out
    }

    /// A rectangular part of the image.
    public func cropped(x: Int, y: Int, width w: Int, height h: Int) -> GreyImage? {
        guard x >= 0, y >= 0, w > 0, h > 0, x + w <= width, y + h <= height else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(w * h)
        for row in y..<(y + h) {
            out.append(contentsOf: pixels[(row * width + x)..<(row * width + x + w)])
        }
        return GreyImage(width: w, height: h, pixels: out)
    }
}

/// 64-bit perceptual hashes. Similar-looking pictures get hashes that differ
/// in only a few bits, whatever their size or file format.
public enum PerceptualHash {
    /// Difference hash: shrink to 9x8, each bit says "is this pixel brighter
    /// than its right-hand neighbour".
    public static func dHash(_ image: GreyImage) -> UInt64 {
        let small = image.resized(width: 9, height: 8)
        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                if small[y * 9 + x] > small[y * 9 + x + 1] { hash |= (1 << bit) }
                bit += 1
            }
        }
        return hash
    }

    private static let dctSize = 32
    private static let cosTable: [[Double]] = (0..<8).map { u in
        (0..<32).map { x in cos(Double(2 * x + 1) * Double(u) * Double.pi / 64) }
    }

    /// DCT hash: shrink to 32x32, take the 8x8 lowest frequencies, each bit
    /// says "above the median" (median taken without the DC term).
    public static func pHash(_ image: GreyImage) -> UInt64 {
        let n = dctSize
        let small = image.resized(width: n, height: n)
        // Rows: tmp[y][u] = sum_x p[y][x] * cos[u][x]
        var tmp = [Double](repeating: 0, count: n * 8)
        for y in 0..<n {
            for u in 0..<8 {
                var s = 0.0
                let c = cosTable[u]
                for x in 0..<n { s += small[y * n + x] * c[x] }
                tmp[y * 8 + u] = s
            }
        }
        // Columns: coef[v][u] = sum_y tmp[y][u] * cos[v][y], with scaling.
        let a0 = (1.0 / Double(n)).squareRoot()
        let ak = (2.0 / Double(n)).squareRoot()
        var coef = [Double](repeating: 0, count: 64)
        for v in 0..<8 {
            for u in 0..<8 {
                var s = 0.0
                let c = cosTable[v]
                for y in 0..<n { s += tmp[y * 8 + u] * c[y] }
                coef[v * 8 + u] = s * (u == 0 ? a0 : ak) * (v == 0 ? a0 : ak)
            }
        }
        let ac = Array(coef.dropFirst()).sorted()
        let median = (ac[31] + ac[30]) / 2
        var hash: UInt64 = 0
        for i in 0..<64 where coef[i] > median { hash |= (1 << UInt64(i)) }
        return hash
    }

    /// Number of differing bits (0 = identical, 64 = opposite).
    public static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}

/// Everything Part B measures about one picture.
public struct ImageFingerprint: Codable, Hashable, Sendable {
    public var file: DuplicateCandidate
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var dHash: UInt64
    public var pHash: UInt64

    public init(file: DuplicateCandidate, pixelWidth: Int, pixelHeight: Int, dHash: UInt64, pHash: UInt64) {
        self.file = file
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.dHash = dHash
        self.pHash = pHash
    }

    public init(file: DuplicateCandidate, image: GreyImage, pixelWidth: Int? = nil, pixelHeight: Int? = nil) {
        self.init(
            file: file,
            pixelWidth: pixelWidth ?? image.width,
            pixelHeight: pixelHeight ?? image.height,
            dHash: PerceptualHash.dHash(image),
            pHash: PerceptualHash.pHash(image)
        )
    }
}

/// When two pictures count as "the same image". Both hashes must be within
/// their threshold (inclusive).
public struct ImageMatchPolicy: Codable, Hashable, Sendable {
    public var dHashThreshold: Int
    public var pHashThreshold: Int

    public init(dHashThreshold: Int = 10, pHashThreshold: Int = 10) {
        self.dHashThreshold = dHashThreshold
        self.pHashThreshold = pHashThreshold
    }

    public func isSameImage(_ a: ImageFingerprint, _ b: ImageFingerprint) -> Bool {
        PerceptualHash.distance(a.dHash, b.dHash) <= dHashThreshold
            && PerceptualHash.distance(a.pHash, b.pHash) <= pHashThreshold
    }
}
