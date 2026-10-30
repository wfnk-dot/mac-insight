import Foundation

/// Vision's verdict on a pair of pictures, measured by Part B with
/// `VNGenerateImageFeaturePrintRequest` plus `CropMatcher`.
public struct VisualPairCheck: Codable, Hashable, Sendable {
    public var pathA: String
    public var pathB: String
    /// `VNFeaturePrintObservation.computeDistance`; smaller is more alike.
    public var featurePrintDistance: Double
    /// True when one picture is a region of the other.
    public var isCrop: Bool

    public init(pathA: String, pathB: String, featurePrintDistance: Double, isCrop: Bool) {
        self.pathA = pathA
        self.pathB = pathB
        self.featurePrintDistance = featurePrintDistance
        self.isCrop = isCrop
    }
}

/// Everything Part B measures about one video.
public struct VideoFingerprint: Codable, Hashable, Sendable {
    public var file: DuplicateCandidate
    public var duration: Double
    /// dHash of the first frame.
    public var firstFrameHash: UInt64

    public init(file: DuplicateCandidate, duration: Double, firstFrameHash: UInt64) {
        self.file = file
        self.duration = duration
        self.firstFrameHash = firstFrameHash
    }
}

public enum SimilarMedia {
    /// Groups pictures that are the same image at a different size or format.
    /// Pass one picture per exact-duplicate group so exact copies aren't
    /// reported twice.
    public static func sameImageGroups(_ images: [ImageFingerprint], policy: ImageMatchPolicy = ImageMatchPolicy(), home: String? = nil) -> [DuplicateGroup] {
        var uf = UnionFind(count: images.count)
        for i in 0..<images.count {
            for j in (i + 1)..<images.count where policy.isSameImage(images[i], images[j]) {
                uf.union(i, j)
            }
        }
        return uf.groups().map { indices in
            makeGroup(kind: .sameImageDifferentSize, files: indices.map { images[$0].file }, home: home)
        }
    }

    /// Groups cropped or edited versions from Vision pair checks. Pairs
    /// already in a same-image group are skipped by passing `exclude`.
    public static func croppedOrEditedGroups(
        _ checks: [VisualPairCheck],
        files: [DuplicateCandidate],
        maximumDistance: Double = 0.5,
        excludePairsWithin groups: [DuplicateGroup] = [],
        home: String? = nil
    ) -> [DuplicateGroup] {
        var index: [String: Int] = [:]
        for (i, f) in files.enumerated() { index[f.path] = i }
        var groupOf: [String: String] = [:]
        for g in groups { for f in g.files { groupOf[f.path] = g.id } }

        var uf = UnionFind(count: files.count)
        var anyCrop = Set<Int>()
        for check in checks {
            guard check.featurePrintDistance <= maximumDistance,
                  let a = index[check.pathA], let b = index[check.pathB], a != b else { continue }
            if let ga = groupOf[check.pathA], ga == groupOf[check.pathB] { continue }
            uf.union(a, b)
            if check.isCrop {
                anyCrop.insert(a)
                anyCrop.insert(b)
            }
        }
        return uf.groups().map { indices in
            var group = makeGroup(kind: .croppedOrEdited, files: indices.map { files[$0] }, home: home)
            if indices.contains(where: { anyCrop.contains($0) }) { group.keepReason += " (includes a crop)" }
            return group
        }
    }

    /// Videos with the same length (±`durationTolerance` seconds) and a
    /// matching first frame. Tag only: never counted as wasted space.
    public static func similarVideoGroups(_ videos: [VideoFingerprint], durationTolerance: Double = 1.0, frameThreshold: Int = 10, home: String? = nil) -> [DuplicateGroup] {
        let order = videos.indices.sorted { videos[$0].duration < videos[$1].duration }
        var uf = UnionFind(count: videos.count)
        for (k, i) in order.enumerated() {
            var m = k + 1
            while m < order.count {
                let j = order[m]
                if videos[j].duration - videos[i].duration > durationTolerance { break }
                if PerceptualHash.distance(videos[i].firstFrameHash, videos[j].firstFrameHash) <= frameThreshold {
                    uf.union(i, j)
                }
                m += 1
            }
        }
        return uf.groups().map { indices in
            makeGroup(kind: .similarVideo, files: indices.map { videos[$0].file }, home: home)
        }
    }

    static func makeGroup(kind: DuplicateTag, files: [DuplicateCandidate], home: String?) -> DuplicateGroup {
        let pick = KeepSuggester.suggest(files, home: home)
        let others = files.filter { $0.path != pick.file.path }.sorted { $0.path < $1.path }
        let id = kind.rawValue + ":" + ([pick.file.path] + others.map(\.path)).joined(separator: "|")
        return DuplicateGroup(
            id: id,
            kind: kind,
            tags: [kind],
            files: [pick.file] + others,
            suggestedKeep: pick.file.path,
            keepReason: pick.reason,
            clonePaths: [],
            wastedBytes: 0
        )
    }
}

/// The toggles at the top of the Duplicates screen.
public struct DuplicateFilters: Codable, Hashable, Sendable {
    /// On by default: only byte-identical copies.
    public var exactOnly: Bool = true
    /// Off by default.
    public var showSimilarImages: Bool = false

    public init(exactOnly: Bool = true, showSimilarImages: Bool = false) {
        self.exactOnly = exactOnly
        self.showSimilarImages = showSimilarImages
    }

    /// Turning on similar images turns off "Exact only" (and vice versa), so
    /// the two toggles never contradict each other.
    public mutating func setShowSimilarImages(_ on: Bool) {
        showSimilarImages = on
        if on { exactOnly = false }
    }

    public mutating func setExactOnly(_ on: Bool) {
        exactOnly = on
        if on { showSimilarImages = false }
    }

    public func shows(_ group: DuplicateGroup) -> Bool {
        switch group.kind {
        case .exactDuplicate, .apfsClone:
            return true
        case .sameImageDifferentSize, .croppedOrEdited:
            return !exactOnly && showSimilarImages
        case .similarVideo:
            return !exactOnly
        }
    }

    public func visible(_ groups: [DuplicateGroup]) -> [DuplicateGroup] {
        groups.filter(shows)
    }
}
