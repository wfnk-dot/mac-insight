import XCTest
@testable import InsightCore

final class DuplicateTests: XCTestCase {
    private func candidate(_ path: String, _ data: Data?, inode: UInt64, size: Int64? = nil, cloneID: UInt64? = nil, created: Date? = nil) -> DuplicateCandidate {
        DuplicateCandidate(path: path, size: size ?? Int64(data?.count ?? 0), created: created, inode: inode, cloneID: cloneID)
    }

    // MARK: Exact duplicates

    func testOnlyByteIdenticalFilesAreGrouped() throws {
        let content = bytes(200_000, seed: 1)
        var differentMiddle = content
        differentMiddle[100_000] ^= 0xff // same size, same first and last 64 KB
        let source = MemorySource([
            "/d/a.bin": content,
            "/d/b.bin": content,
            "/d/c.bin": differentMiddle,
            "/d/other-size.bin": bytes(150_000, seed: 1),
        ])
        let files = [
            candidate("/d/a.bin", content, inode: 1),
            candidate("/d/b.bin", content, inode: 2),
            candidate("/d/c.bin", differentMiddle, inode: 3),
            candidate("/d/other-size.bin", source.files["/d/other-size.bin"], inode: 4),
        ]
        let result = try DuplicateFinder(source: source).find(files)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(Set(result.groups[0].files.map(\.path)), ["/d/a.bin", "/d/b.bin"])
        XCTAssertEqual(result.groups[0].wastedBytes, 200_000)
        XCTAssertEqual(result.groups[0].tags, [.exactDuplicate])
        // The file with a unique size is never opened.
        XCTAssertNil(source.reads["/d/other-size.bin"])
        // c.bin passed the quick hash, so it needed the full hash.
        XCTAssertEqual(source.fullHashes["/d/c.bin"], 1)
    }

    func testQuickHashRejectsDifferentEdgesWithoutFullHash() throws {
        let a = bytes(300_000, seed: 2)
        var b = a
        b[0] ^= 1
        let source = MemorySource(["/a": a, "/b": b])
        let result = try DuplicateFinder(source: source).find([candidate("/a", a, inode: 1), candidate("/b", b, inode: 2)])
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertTrue(source.fullHashes.isEmpty)
    }

    func testSmallFilesReuseTheQuickHash() throws {
        let data = bytes(1000, seed: 9)
        let source = MemorySource(["/x": data, "/y": data])
        let result = try DuplicateFinder(source: source).find([candidate("/x", data, inode: 1), candidate("/y", data, inode: 2)])
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertTrue(source.fullHashes.isEmpty)
        XCTAssertEqual(result.groups[0].id, "1000:" + SHA256Hasher.hex(data))
    }

    func testEmptyFilesAreNeverDuplicates() throws {
        let source = MemorySource(["/e1": Data(), "/e2": Data(), "/e3": Data()])
        let files = (1...3).map { candidate("/e\($0)", Data(), inode: UInt64($0)) }
        XCTAssertTrue(try DuplicateFinder(source: source).find(files).groups.isEmpty)
    }

    func testHardLinksAreTheSameFileNotCopies() throws {
        let data = bytes(5000, seed: 4)
        let source = MemorySource(["/a": data, "/b": data])
        let files = [candidate("/a", data, inode: 7), candidate("/b", data, inode: 7)]
        XCTAssertTrue(try DuplicateFinder(source: source).find(files).groups.isEmpty)
    }

    func testClonesAreTaggedAndWasteNothing() throws {
        let data = bytes(10_000, seed: 5)
        let source = MemorySource(["/a": data, "/b": data, "/c": data])
        let allClones = [candidate("/a", data, inode: 1, cloneID: 50), candidate("/b", data, inode: 2, cloneID: 50)]
        let g1 = try DuplicateFinder(source: source).find(allClones).groups[0]
        XCTAssertEqual(g1.tags, [.exactDuplicate, .apfsClone])
        XCTAssertEqual(g1.wastedBytes, 0)
        XCTAssertEqual(g1.clonePaths, ["/a", "/b"])

        let mixed = allClones + [candidate("/c", data, inode: 3)]
        let g2 = try DuplicateFinder(source: source).find(mixed).groups[0]
        XCTAssertEqual(g2.files.count, 3)
        XCTAssertEqual(g2.wastedBytes, 10_000)
        XCTAssertEqual(g2.clonePaths, ["/a", "/b"])
    }

    func testUnicodePaths() throws {
        let data = bytes(3000, seed: 6)
        let p1 = "/Users/wyn/Pictures/Café/写真 1.jpg"
        let p2 = "/Users/wyn/Downloads/📷 写真 1.jpg"
        let source = MemorySource([p1: data, p2: data])
        let result = try DuplicateFinder(source: source, home: "/Users/wyn").find([candidate(p1, data, inode: 1), candidate(p2, data, inode: 2)])
        XCTAssertEqual(result.groups.first?.suggestedKeep, p1)
    }

    func testUnreadableFilesAreReportedNotGrouped() throws {
        let data = bytes(4000, seed: 7)
        let source = MemorySource(["/a": data, "/b": data, "/locked": data])
        source.unreadable = ["/locked"]
        let files = [candidate("/a", data, inode: 1), candidate("/b", data, inode: 2), candidate("/locked", data, inode: 3)]
        let result = try DuplicateFinder(source: source).find(files)
        XCTAssertEqual(result.unreadable, ["/locked"])
        XCTAssertEqual(result.groups.first?.files.count, 2)
    }

    func testCancel() {
        let data = bytes(4000, seed: 8)
        let source = MemorySource(["/a": data, "/b": data])
        let finder = DuplicateFinder(source: source, isCancelled: { true })
        XCTAssertThrowsError(try finder.find([candidate("/a", data, inode: 1), candidate("/b", data, inode: 2)])) { error in
            XCTAssertEqual(error as? DuplicateScanError, .cancelled)
        }
    }

    func testProgressIsReported() throws {
        let data = bytes(4000, seed: 8)
        let source = MemorySource(["/a": data, "/b": data])
        var stages: [DuplicateStage] = []
        let finder = DuplicateFinder(source: source, progress: { stage, _, _ in stages.append(stage) })
        _ = try finder.find([candidate("/a", data, inode: 1), candidate("/b", data, inode: 2)])
        XCTAssertTrue(stages.contains(.groupingBySize))
        XCTAssertTrue(stages.contains(.quickHash))
        XCTAssertTrue(stages.contains(.fullHash))
    }

    func testManyFilesManyGroups() throws {
        var files: [String: Data] = [:]
        var candidates: [DuplicateCandidate] = []
        for i in 0..<2000 {
            let data = bytes(100 + (i % 100), seed: UInt8(i % 100))
            let path = "/many/\(i)"
            files[path] = data
            candidates.append(candidate(path, data, inode: UInt64(i + 1)))
        }
        let result = try DuplicateFinder(source: MemorySource(files)).find(candidates)
        XCTAssertEqual(result.groups.count, 100)
        XCTAssertTrue(result.groups.allSatisfy { $0.files.count == 20 })
    }

    func testSummaryText() {
        let group = DuplicateGroup(id: "x", kind: .exactDuplicate, tags: [.exactDuplicate], files: [], suggestedKeep: "", keepReason: "", clonePaths: [], wastedBytes: 1_500_000_000)
        let result = DuplicateFinder.Result(groups: [group], unreadable: [])
        XCTAssertEqual(result.summary, "1.5 GB in exact duplicates")
    }

    func testLocalFileSourceReadsRealFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("insight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = bytes(300_000, seed: 11)
        let a = dir.appendingPathComponent("a.bin"), b = dir.appendingPathComponent("b é.bin")
        try data.write(to: a)
        try data.write(to: b)
        let files = [
            DuplicateCandidate(path: a.path, size: Int64(data.count), inode: 1),
            DuplicateCandidate(path: b.path, size: Int64(data.count), inode: 2),
        ]
        let result = try DuplicateFinder().find(files)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].id, "300000:" + SHA256Hasher.hex(data))
    }

    // MARK: Keep suggestion

    func testKeepPrefersTidyFolderThenOldest() {
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        let new = Date(timeIntervalSince1970: 1_600_000_000)
        let downloads = DuplicateCandidate(path: "/Users/wyn/Downloads/photo.jpg", size: 1, created: old, inode: 1)
        let filed = DuplicateCandidate(path: "/Users/wyn/Pictures/Trips/photo.jpg", size: 1, created: new, inode: 2)
        let pick = KeepSuggester.suggest([downloads, filed], home: "/Users/wyn")
        XCTAssertEqual(pick.file.path, filed.path)
        XCTAssertEqual(pick.reason, "In the tidiest folder")

        let a = DuplicateCandidate(path: "/Users/wyn/Documents/b.pdf", size: 1, created: new, inode: 3)
        let b = DuplicateCandidate(path: "/Users/wyn/Documents/a.pdf", size: 1, created: old, inode: 4)
        let pick2 = KeepSuggester.suggest([a, b], home: "/Users/wyn")
        XCTAssertEqual(pick2.file.path, b.path)
        XCTAssertEqual(pick2.reason, "Oldest copy")
    }

    func testCopyNamesScoreLower() {
        for name in ["photo copy.jpg", "photo copy 2.jpg", "photo (1).jpg", "copy of photo.jpg"] {
            XCTAssertTrue(KeepSuggester.looksLikeCopyName(name), name)
        }
        for name in ["copycat.jpg", "photo (a).jpg", "photo.jpg"] {
            XCTAssertFalse(KeepSuggester.looksLikeCopyName(name), name)
        }
        let original = DuplicateCandidate(path: "/Users/wyn/Documents/report.pdf", size: 1, inode: 1)
        let copy = DuplicateCandidate(path: "/Users/wyn/Documents/report copy.pdf", size: 1, inode: 2)
        XCTAssertEqual(KeepSuggester.suggest([copy, original], home: nil).file.path, original.path)
    }

    func testKeeperIsListedFirstAndNothingElseIsMarked() throws {
        let data = bytes(2000, seed: 12)
        let p1 = "/Users/wyn/Desktop/x.dat", p2 = "/Users/wyn/Documents/x.dat"
        let source = MemorySource([p1: data, p2: data])
        let group = try DuplicateFinder(source: source, home: "/Users/wyn").find([candidate(p1, data, inode: 1), candidate(p2, data, inode: 2)]).groups[0]
        XCTAssertEqual(group.files.first?.path, p2)
        XCTAssertEqual(group.suggestedKeep, p2)
    }

    // MARK: Perceptual hashes

    func testGreyImageValidation() {
        XCTAssertNil(GreyImage(width: 2, height: 2, pixels: [1, 2, 3]))
        XCTAssertNil(GreyImage(width: 0, height: 2, pixels: []))
        XCTAssertNotNil(GreyImage(width: 1, height: 1, pixels: [9]))
    }

    func testHashDistance() {
        XCTAssertEqual(PerceptualHash.distance(0, 0), 0)
        XCTAssertEqual(PerceptualHash.distance(0, UInt64.max), 64)
        XCTAssertEqual(PerceptualHash.distance(0b1011, 0b0001), 2)
    }

    func testResizedImageHasTheSameHash() {
        let big = blockImage(seed: 1, width: 256, height: 192)
        let small = blockImage(seed: 1, width: 128, height: 96)
        XCTAssertLessThanOrEqual(PerceptualHash.distance(PerceptualHash.dHash(big), PerceptualHash.dHash(small)), 2)
        XCTAssertLessThanOrEqual(PerceptualHash.distance(PerceptualHash.pHash(big), PerceptualHash.pHash(small)), 2)
    }

    func testReencodedImageWithNoiseStillMatches() {
        let clean = blockImage(seed: 2, width: 200, height: 150)
        let noisy = blockImage(seed: 2, width: 200, height: 150, noise: 4)
        XCTAssertLessThanOrEqual(PerceptualHash.distance(PerceptualHash.dHash(clean), PerceptualHash.dHash(noisy)), 4)
        XCTAssertLessThanOrEqual(PerceptualHash.distance(PerceptualHash.pHash(clean), PerceptualHash.pHash(noisy)), 4)
    }

    func testDifferentImagesAreFarApart() {
        let a = blockImage(seed: 1, width: 128, height: 96)
        let b = blockImage(seed: 99, width: 128, height: 96)
        XCTAssertGreaterThan(PerceptualHash.distance(PerceptualHash.dHash(a), PerceptualHash.dHash(b)), 15)
        XCTAssertGreaterThan(PerceptualHash.distance(PerceptualHash.pHash(a), PerceptualHash.pHash(b)), 15)
        XCTAssertFalse(ImageMatchPolicy().isSameImage(
            ImageFingerprint(file: DuplicateCandidate(path: "/a", size: 1, inode: 1), image: a),
            ImageFingerprint(file: DuplicateCandidate(path: "/b", size: 1, inode: 2), image: b)
        ))
    }

    func testThresholdIsInclusive() {
        let policy = ImageMatchPolicy(dHashThreshold: 10, pHashThreshold: 8)
        func fp(_ d: UInt64, _ p: UInt64) -> ImageFingerprint {
            ImageFingerprint(file: DuplicateCandidate(path: "/\(d)-\(p)", size: 1, inode: d), pixelWidth: 1, pixelHeight: 1, dHash: d, pHash: p)
        }
        let base = fp(0, 0)
        let tenBits: UInt64 = (1 << 10) - 1
        let elevenBits: UInt64 = (1 << 11) - 1
        let eightBits: UInt64 = (1 << 8) - 1
        let nineBits: UInt64 = (1 << 9) - 1
        XCTAssertTrue(policy.isSameImage(base, fp(tenBits, eightBits)))
        XCTAssertFalse(policy.isSameImage(base, fp(elevenBits, eightBits)))
        XCTAssertFalse(policy.isSameImage(base, fp(tenBits, nineBits)))
    }

    func testSameImageGrouping() {
        let big = ImageFingerprint(file: DuplicateCandidate(path: "/Users/wyn/Pictures/sunset.heic", size: 3_000_000, inode: 1), image: blockImage(seed: 5, width: 256, height: 192))
        let small = ImageFingerprint(file: DuplicateCandidate(path: "/Users/wyn/Downloads/sunset-small.jpg", size: 200_000, inode: 2), image: blockImage(seed: 5, width: 128, height: 96, noise: 2))
        let other = ImageFingerprint(file: DuplicateCandidate(path: "/Users/wyn/Pictures/cat.jpg", size: 1_000_000, inode: 3), image: blockImage(seed: 6, width: 256, height: 192))
        let groups = SimilarMedia.sameImageGroups([big, other, small], home: "/Users/wyn")
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].kind, .sameImageDifferentSize)
        XCTAssertEqual(groups[0].suggestedKeep, "/Users/wyn/Pictures/sunset.heic")
        XCTAssertEqual(groups[0].wastedBytes, 0)
    }

    // MARK: Crops

    func testFindsACrop() {
        let large = blockImage(seed: 3, width: 256, height: 192)
        let crop = large.cropped(x: 64, y: 48, width: 128, height: 96)!
        let match = CropMatcher().findCrop(crop, in: large)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.x ?? 0, 0.25, accuracy: 0.05)
        XCTAssertEqual(match?.y ?? 0, 0.25, accuracy: 0.05)
        XCTAssertEqual(match?.width ?? 0, 0.5, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(match?.score ?? 0, 0.9)
    }

    func testFindsACropThatWasAlsoShrunk() {
        let large = blockImage(seed: 3, width: 256, height: 192)
        let crop = large.cropped(x: 64, y: 48, width: 128, height: 96)!
        let shrunkPixels = crop.resized(width: 64, height: 48).map { UInt8(max(0, min(255, $0.rounded()))) }
        let shrunk = GreyImage(width: 64, height: 48, pixels: shrunkPixels)!
        let match = CropMatcher().findCrop(shrunk, in: large)
        XCTAssertEqual(match?.width ?? 0, 0.5, accuracy: 0.05)
    }

    func testUnrelatedPictureIsNotACrop() {
        let large = blockImage(seed: 3, width: 256, height: 192)
        let unrelated = blockImage(seed: 42, width: 128, height: 96)
        XCTAssertNil(CropMatcher().findCrop(unrelated, in: large))
    }

    func testCroppedOrEditedGroupsFromVisionChecks() {
        let files = ["/p/a.jpg", "/p/a-crop.jpg", "/p/b.jpg", "/p/c.jpg"].enumerated().map {
            DuplicateCandidate(path: $0.element, size: 1, inode: UInt64($0.offset + 1))
        }
        let checks = [
            VisualPairCheck(pathA: "/p/a.jpg", pathB: "/p/a-crop.jpg", featurePrintDistance: 0.3, isCrop: true),
            VisualPairCheck(pathA: "/p/a.jpg", pathB: "/p/b.jpg", featurePrintDistance: 0.9, isCrop: false),
            VisualPairCheck(pathA: "/p/b.jpg", pathB: "/p/c.jpg", featurePrintDistance: 0.2, isCrop: false),
        ]
        let sameImage = [SimilarMedia.makeGroup(kind: .sameImageDifferentSize, files: [files[2], files[3]], home: nil)]
        let groups = SimilarMedia.croppedOrEditedGroups(checks, files: files, excludePairsWithin: sameImage)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].files.map(\.path)), ["/p/a.jpg", "/p/a-crop.jpg"])
        XCTAssertEqual(groups[0].kind, .croppedOrEdited)
        XCTAssertTrue(groups[0].keepReason.contains("crop"))
    }

    // MARK: Videos

    func testSimilarVideos() {
        func v(_ path: String, _ duration: Double, _ hash: UInt64, inode: UInt64) -> VideoFingerprint {
            VideoFingerprint(file: DuplicateCandidate(path: path, size: 1, inode: inode), duration: duration, firstFrameHash: hash)
        }
        let videos = [
            v("/m/a.mov", 60.0, 0xFF00, inode: 1),
            v("/m/a-export.mp4", 60.8, 0xFF01, inode: 2),
            v("/m/longer.mp4", 62.5, 0xFF00, inode: 3),
            v("/m/other.mp4", 60.5, ~UInt64(0xFF00), inode: 4),
        ]
        let groups = SimilarMedia.similarVideoGroups(videos)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].files.map(\.path)), ["/m/a.mov", "/m/a-export.mp4"])
        XCTAssertEqual(groups[0].tags, [.similarVideo])
        XCTAssertEqual(groups[0].wastedBytes, 0)
    }

    func testDurationToleranceIsInclusive() {
        let a = VideoFingerprint(file: DuplicateCandidate(path: "/a", size: 1, inode: 1), duration: 10, firstFrameHash: 0)
        let b = VideoFingerprint(file: DuplicateCandidate(path: "/b", size: 1, inode: 2), duration: 11, firstFrameHash: 0)
        let c = VideoFingerprint(file: DuplicateCandidate(path: "/c", size: 1, inode: 3), duration: 12.01, firstFrameHash: 0)
        let groups = SimilarMedia.similarVideoGroups([a, c, b])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].files.map(\.path)), ["/a", "/b"])
    }

    // MARK: Filters

    func testFilterDefaultsAndToggles() {
        let exact = DuplicateGroup(id: "e", kind: .exactDuplicate, tags: [.exactDuplicate], files: [], suggestedKeep: "", keepReason: "", clonePaths: [], wastedBytes: 1)
        let image = SimilarMedia.makeGroup(kind: .sameImageDifferentSize, files: [DuplicateCandidate(path: "/i", size: 1, inode: 1)], home: nil)
        let crop = SimilarMedia.makeGroup(kind: .croppedOrEdited, files: [DuplicateCandidate(path: "/c", size: 1, inode: 2)], home: nil)
        let video = SimilarMedia.makeGroup(kind: .similarVideo, files: [DuplicateCandidate(path: "/v", size: 1, inode: 3)], home: nil)
        let all = [exact, image, crop, video]

        var filters = DuplicateFilters()
        XCTAssertTrue(filters.exactOnly)
        XCTAssertFalse(filters.showSimilarImages)
        XCTAssertEqual(filters.visible(all).map(\.id), [exact.id])

        filters.setShowSimilarImages(true)
        XCTAssertFalse(filters.exactOnly)
        XCTAssertEqual(filters.visible(all).count, 4)

        filters.setShowSimilarImages(false)
        XCTAssertEqual(filters.visible(all).map(\.id), [exact.id, video.id])

        filters.setExactOnly(true)
        XCTAssertEqual(filters.visible(all).map(\.id), [exact.id])
    }
}
