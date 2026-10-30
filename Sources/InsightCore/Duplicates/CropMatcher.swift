import Foundation

/// Checks whether a smaller picture is a region of a larger one (a crop,
/// possibly resized). Part B runs it only on pairs Vision already found
/// similar, so it can afford a brute-force search at low resolution.
public struct CropMatcher: Sendable {
    public struct Match: Hashable, Sendable {
        /// Where the crop sits in the larger picture, as fractions (0...1).
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        /// Normalised cross-correlation, 1 = perfect.
        public var score: Double
    }

    /// Width the larger picture is shrunk to before searching.
    public var workingWidth: Int
    /// Minimum correlation to call it a crop.
    public var minimumScore: Double
    /// Crop widths tried, as fractions of the larger picture's width.
    public var scales: [Double]

    public init(workingWidth: Int = 64, minimumScore: Double = 0.9, scales: [Double] = Array(stride(from: 0.3, through: 0.95, by: 0.025))) {
        self.workingWidth = workingWidth
        self.minimumScore = minimumScore
        self.scales = scales
    }

    /// Returns the best match if `small` looks like a crop of `large`. A
    /// full-frame match (nothing cut off) is not a crop and returns nil.
    public func findCrop(_ small: GreyImage, in large: GreyImage) -> Match? {
        let lw = min(workingWidth, large.width)
        let lh = max(1, Int((Double(large.height) * Double(lw) / Double(large.width)).rounded()))
        let big = large.resized(width: lw, height: lh)
        let aspect = Double(small.height) / Double(small.width)

        var best: Match?
        for scale in scales {
            let tw = Int((Double(lw) * scale).rounded())
            let th = Int((Double(tw) * aspect).rounded())
            guard tw >= 6, th >= 6, tw <= lw, th <= lh else { continue }
            let template = small.resized(width: tw, height: th)
            guard let stats = Self.meanStd(template), stats.std > 1 else { continue }
            let tMean = stats.mean, tStd = stats.std
            for oy in 0...(lh - th) {
                for ox in 0...(lw - tw) {
                    let score = Self.correlation(big, lw, ox, oy, template, tw, th, tMean, tStd)
                    if score > (best?.score ?? -1) {
                        best = Match(
                            x: Double(ox) / Double(lw),
                            y: Double(oy) / Double(lh),
                            width: Double(tw) / Double(lw),
                            height: Double(th) / Double(lh),
                            score: score
                        )
                    }
                }
            }
        }
        guard let match = best, match.score >= minimumScore else { return nil }
        return match
    }

    static func meanStd(_ values: [Double]) -> (mean: Double, std: Double)? {
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return (mean, variance.squareRoot())
    }

    static func correlation(_ big: [Double], _ bw: Int, _ ox: Int, _ oy: Int, _ t: [Double], _ tw: Int, _ th: Int, _ tMean: Double, _ tStd: Double) -> Double {
        let count = Double(tw * th)
        var sum = 0.0
        var sumSq = 0.0
        for y in 0..<th {
            let row = (oy + y) * bw + ox
            for x in 0..<tw {
                let v = big[row + x]
                sum += v
                sumSq += v * v
            }
        }
        let mean = sum / count
        let variance = max(0, sumSq / count - mean * mean)
        let std = variance.squareRoot()
        guard std > 1 else { return -1 }
        var cross = 0.0
        for y in 0..<th {
            let row = (oy + y) * bw + ox
            for x in 0..<tw {
                cross += (big[row + x] - mean) * (t[y * tw + x] - tMean)
            }
        }
        return cross / (count * std * tStd)
    }
}
