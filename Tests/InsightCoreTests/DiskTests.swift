import XCTest
@testable import InsightCore

final class DiskTests: XCTestCase {
    // MARK: Allocated size

    func testAllocatedSizeRounding() {
        XCTAssertEqual(AllocationMath.roundUp(0), 0)
        XCTAssertEqual(AllocationMath.roundUp(1), 4096)
        XCTAssertEqual(AllocationMath.roundUp(4096), 4096)
        XCTAssertEqual(AllocationMath.roundUp(4097), 8192)
        XCTAssertEqual(AllocationMath.roundUp(-5), 0)
    }

    func testScannerAllocatedSizeWinsForSparseAndCompressedFiles() {
        let sparse = FileRecord(path: "/vm.img", logicalSize: 1_000_000_000, allocatedSize: 8192, inode: 1)
        XCTAssertEqual(AllocationMath.allocated(sparse), 8192)
        let result = DiskTreeBuilder().build([sparse])
        XCTAssertEqual(result.totalCounted, 8192)
        XCTAssertEqual(result.totalLogical, 1_000_000_000)
    }

    // MARK: Hard links and clones

    func testHardLinksCountOnce() {
        let records = [
            FileRecord(path: "/a/x.mov", logicalSize: 10_000, inode: 42, linkCount: 2),
            FileRecord(path: "/b/y.mov", logicalSize: 10_000, inode: 42, linkCount: 2),
            FileRecord(path: "/b/z.txt", logicalSize: 100, inode: 43),
        ]
        let result = DiskTreeBuilder().build(records)
        XCTAssertEqual(result.totalCounted, 12_288 + 4096)
        XCTAssertEqual(result.hardLinkSavings, 12_288)
        XCTAssertEqual(result.root.descendant(["a"])?.size, 12_288)
        XCTAssertEqual(result.root.descendant(["b"])?.size, 4096)
        XCTAssertEqual(result.biggestFiles.map(\.path), ["/a/x.mov", "/b/z.txt"])
    }

    func testSameInodeOnDifferentDevicesIsNotAHardLink() {
        let records = [
            FileRecord(path: "/a", logicalSize: 4096, device: 1, inode: 7),
            FileRecord(path: "/Volumes/X/a", logicalSize: 4096, device: 2, inode: 7),
        ]
        XCTAssertEqual(DiskTreeBuilder().build(records).totalCounted, 8192)
    }

    func testFirmlinkedDataVolumePathIsNotDoubleCounted() {
        let records = [
            FileRecord(path: "/Users/wyn/big.zip", logicalSize: 1_000_000, inode: 9),
            FileRecord(path: "/System/Volumes/Data/Users/wyn/big.zip", logicalSize: 1_000_000, inode: 9),
        ]
        let result = DiskTreeBuilder().build(records)
        XCTAssertEqual(result.totalCounted, AllocationMath.roundUp(1_000_000))
        XCTAssertEqual(result.fileCount, 1)
        XCTAssertNil(result.root.descendant(["System"]))
    }

    func testClonesShareTheirBlocks() {
        let records = [
            FileRecord(path: "/m/original.mov", logicalSize: 5_000_000, allocatedSize: 5_001_216, inode: 1, cloneID: 77),
            FileRecord(path: "/m/clone.mov", logicalSize: 5_000_000, allocatedSize: 5_001_216, inode: 2, cloneID: 77),
            FileRecord(path: "/m/edited-clone.mov", logicalSize: 5_000_000, allocatedSize: 5_001_216, inode: 3, cloneID: 77, privateSize: 40_960),
        ]
        let result = DiskTreeBuilder().build(records)
        XCTAssertEqual(result.totalCounted, 5_001_216 + 0 + 40_960)
        XCTAssertEqual(result.cloneSavings, 5_001_216 * 2 - 40_960)
        let shared = SpaceAccounting().account(records).map(\.shared)
        XCTAssertEqual(shared, [.none, .clone, .clone])
    }

    func testSameCloneIDOnAnotherDeviceIsSeparate() {
        let records = [
            FileRecord(path: "/a", logicalSize: 4096, device: 1, inode: 1, cloneID: 5),
            FileRecord(path: "/Volumes/X/a", logicalSize: 4096, device: 2, inode: 1, cloneID: 5),
        ]
        XCTAssertEqual(DiskTreeBuilder().build(records).totalCounted, 8192)
    }

    // MARK: Tree

    func testUnicodePathsMergeAcrossNormalisationForms() {
        let records = [
            FileRecord(path: "/Users/wyn/Caf\u{E9}/a.txt", logicalSize: 10, inode: 1),
            FileRecord(path: "/Users/wyn/Cafe\u{301}/b.txt", logicalSize: 10, inode: 2),
            FileRecord(path: "/Users/wyn/📈 Charts/日本.png", logicalSize: 10, inode: 3),
        ]
        let root = DiskTreeBuilder().build(records).root
        let wyn = root.descendant(["Users", "wyn"])!
        XCTAssertEqual(wyn.children.count, 2)
        let cafe = root.descendant(["Users", "wyn", "Cafe\u{301}"])
        XCTAssertEqual(cafe?.fileCount, 2)
        XCTAssertEqual(cafe?.name, "Caf\u{E9}")
        XCTAssertEqual(root.descendant(["Users", "wyn", "📈 Charts", "日本.png"])?.size, 4096)
    }

    func testEmptyFilesAndEmptyFolders() {
        let records = [
            FileRecord(path: "/e/empty.txt", logicalSize: 0, inode: 1),
            FileRecord(path: "/e/nothing-here", logicalSize: 0, inode: 2, isDirectory: true),
        ]
        let result = DiskTreeBuilder().build(records)
        XCTAssertEqual(result.totalCounted, 0)
        XCTAssertEqual(result.fileCount, 1)
        let folder = result.root.descendant(["e", "nothing-here"])
        XCTAssertEqual(folder?.isDirectory, true)
        XCTAssertEqual(folder?.fileCount, 0)
        XCTAssertEqual(result.root.descendant(["e", "empty.txt"])?.isDirectory, false)
    }

    func testChildrenSortedBiggestFirstAndSizesAddUp() {
        let records = [
            FileRecord(path: "/r/small", logicalSize: 1, inode: 1),
            FileRecord(path: "/r/big/a", logicalSize: 100_000, inode: 2),
            FileRecord(path: "/r/big/b", logicalSize: 50_000, inode: 3),
            FileRecord(path: "/r/mid/c", logicalSize: 20_000, inode: 4),
        ]
        let r = DiskTreeBuilder().build(records).root.descendant(["r"])!
        XCTAssertEqual(r.children.map(\.name), ["big", "mid", "small"])
        XCTAssertEqual(r.size, r.children.reduce(0) { $0 + $1.size })
    }

    func testRootPathLimitsTheScan() {
        let records = [
            FileRecord(path: "/Users/wyn/a", logicalSize: 4096, inode: 1),
            FileRecord(path: "/Applications/App.app/b", logicalSize: 4096, inode: 2),
        ]
        let result = DiskTreeBuilder(rootPath: "/Users").build(records)
        XCTAssertEqual(result.totalCounted, 4096)
        XCTAssertNotNil(result.root.descendant(["wyn", "a"]))
    }

    func testBiggestFilesTop100() {
        let records = (1...150).map { FileRecord(path: "/f/\($0)", logicalSize: Int64($0) * 4096, inode: UInt64($0)) }
        let top = DiskTreeBuilder().build(records.shuffled()).biggestFiles
        XCTAssertEqual(top.count, 100)
        XCTAssertEqual(top.first?.path, "/f/150")
        XCTAssertEqual(top.last?.path, "/f/51")
        XCTAssertEqual(top.map(\.size), top.map(\.size).sorted(by: >))
    }

    func testHugeFileCount() {
        let count = 100_000
        var records: [FileRecord] = []
        records.reserveCapacity(count)
        for i in 0..<count {
            records.append(FileRecord(path: "/Users/wyn/Data/folder\(i % 1000)/sub\(i % 7)/file\(i).bin", logicalSize: Int64(i % 10_000), inode: UInt64(i + 1)))
        }
        let expected = records.reduce(Int64(0)) { $0 + AllocationMath.roundUp($1.logicalSize) }
        let result = DiskTreeBuilder().build(records)
        XCTAssertEqual(result.fileCount, count)
        XCTAssertEqual(result.totalCounted, expected)
        XCTAssertEqual(result.root.descendant(["Users", "wyn", "Data"])?.children.count, 1000)
        XCTAssertEqual(result.biggestFiles.count, 100)
    }

    func testFolderSizesAndPruning() {
        var records: [FileRecord] = []
        for i in 0..<50 {
            records.append(FileRecord(path: "/a/b/c/tiny\(i)", logicalSize: 10, inode: UInt64(i + 1)))
        }
        records.append(FileRecord(path: "/a/b/c/huge", logicalSize: 100_000_000, inode: 999))
        let result = DiskTreeBuilder().build(records)
        let sizes = result.root.folderSizes(maxDepth: 2)
        XCTAssertEqual(Set(sizes.keys), ["/", "/a", "/a/b"])
        XCTAssertEqual(sizes["/a/b"], result.totalCounted)

        let pruned = result.root.pruned(minimumSize: 1_000_000, keepDepth: 2)
        let c = pruned.descendant(["a", "b", "c"])!
        XCTAssertEqual(c.children.count, 2)
        XCTAssertEqual(c.children[0].name, "huge")
        XCTAssertEqual(c.children[1].name, "50 smaller items")
        XCTAssertEqual(c.size, c.children.reduce(0) { $0 + $1.size })
        XCTAssertEqual(pruned.size, result.root.size)
    }

    // MARK: Buckets

    func testBucketRules() {
        let c = BucketClassifier(home: "/Users/wyn")
        let cases: [(String, StorageBucket)] = [
            ("/Users/wyn/Library/Caches/com.foo/x", .caches),
            ("/Library/Caches/x", .caches),
            ("/private/var/folders/ab/cd/T/x", .caches),
            ("/Users/wyn/Library/Caches/Homebrew/downloads/x.tar.gz", .homebrewCache),
            ("/Users/wyn/Library/Logs/DiagnosticReports/x", .logs),
            ("/private/var/log/system.log", .logs),
            ("/Users/wyn/Library/Application Support/MobileSync/Backup/abc/x", .iosBackups),
            ("/Users/wyn/Movies/iMovie Library.imovielibrary/x/y.mov", .iMovie),
            ("/Users/wyn/Movies/iMovie Theater.theater/x", .iMovie),
            ("/Users/wyn/Pictures/Photos Library.photoslibrary/originals/A/x.heic", .photos),
            ("/Users/wyn/Library/Mail/V10/x.emlx", .mail),
            ("/Users/wyn/Library/Containers/com.apple.mail/Data/x", .mail),
            ("/Users/wyn/Library/Messages/Attachments/ab/x.jpg", .messages),
            ("/Users/wyn/Movies/OBS/session.mkv", .obsRecordings),
            ("/Users/wyn/Movies/2026-10-30 14-05-33.mkv", .obsRecordings),
            ("/Users/wyn/Movies/holiday.mkv", .everythingElse),
            ("/Users/wyn/Downloads/setup.dmg", .downloads),
            ("/Users/wyn/Library/Developer/Xcode/DerivedData/x", .developer),
            ("/Library/Developer/CommandLineTools/x", .developer),
            ("/Applications/Xcode.app/Contents/x", .developer),
            ("/Users/wyn/code/app/node_modules/react/index.js", .nodeModules),
            ("/Users/wyn/Downloads/proj/node_modules/x", .nodeModules),
            ("/Users/wyn/Library/Containers/com.docker.docker/Data/vms/0/Docker.raw", .docker),
            ("/Users/wyn/Library/Containers/com.apple.Notes/Data/x", .appContainers),
            ("/Users/wyn/Library/Group Containers/group.com.apple.notes/x", .appContainers),
            ("/private/var/vm/sleepimage", .virtualMemory),
            ("/private/var/vm/swapfile0", .virtualMemory),
            ("/Users/wyn/.Trash/old.zip", .trash),
            ("/Volumes/Backup/.Trashes/501/x", .trash),
            ("/Applications/Safari.app/Contents/x", .applications),
            ("/System/Library/Frameworks/x", .macOS),
            ("/Users/wyn/Documents/taxes.pdf", .everythingElse),
            ("/Users/wyn/Library/CachesOld/x", .everythingElse),
        ]
        for (path, bucket) in cases {
            XCTAssertEqual(c.classify(path), bucket, path)
        }
    }

    func testCustomOBSFolder() {
        let c = BucketClassifier(home: "/Users/wyn", obsFolders: ["/Users/wyn/Recordings"])
        XCTAssertEqual(c.classify("/Users/wyn/Recordings/a.mkv"), .obsRecordings)
        XCTAssertEqual(c.classify("/Users/wyn/Movies/OBS/a.mkv"), .everythingElse)
    }

    func testOBSNamePattern() {
        XCTAssertTrue(BucketClassifier.looksLikeOBSRecording("2026-10-30 14-05-33.mkv"))
        XCTAssertTrue(BucketClassifier.looksLikeOBSRecording("2026-10-30 14-05-33.MP4"))
        XCTAssertFalse(BucketClassifier.looksLikeOBSRecording("2026-10-30 14-05-33.txt"))
        XCTAssertFalse(BucketClassifier.looksLikeOBSRecording("holiday 2026-10-30.mkv"))
    }

    func testEveryBucketHasANote() {
        for bucket in StorageBucket.allCases {
            XCTAssertFalse(bucket.title.isEmpty)
            XCTAssertFalse(bucket.note.isEmpty)
        }
        XCTAssertTrue(StorageBucket.iMovie.note.contains("inside iMovie"))
        XCTAssertEqual(StorageBucket.iMovie.advice, .useItsOwnApp)
        XCTAssertEqual(StorageBucket.caches.advice, .safeToClear)
    }

    func testTopFolders() {
        let c = BucketClassifier(home: "/Users/wyn")
        XCTAssertEqual(c.topFolder(for: "/Users/wyn/Documents/a/b.pdf"), "/Users/wyn/Documents")
        XCTAssertEqual(c.topFolder(for: "/opt/x/y"), "/opt")
        XCTAssertEqual(c.topFolder(for: "/Users/wyn/notes.txt"), "/Users/wyn (loose files)")
    }

    func testStorageSummaryAddsUpToUsedSpace() {
        let records = [
            FileRecord(path: "/Users/wyn/Library/Caches/a", logicalSize: 4096 * 10, inode: 1),
            FileRecord(path: "/Users/wyn/Downloads/b", logicalSize: 4096 * 5, inode: 2),
            FileRecord(path: "/Users/wyn/Documents/c", logicalSize: 4096 * 3, inode: 3),
            FileRecord(path: "/Users/wyn/Documents/d", logicalSize: 4096 * 1, inode: 4),
            FileRecord(path: "/opt/tool/e", logicalSize: 4096 * 2, inode: 5),
        ]
        let result = DiskTreeBuilder().build(records)
        let facts = VolumeFacts(
            usedBytes: result.totalCounted + 50_000,
            purgeableBytes: 1234,
            snapshots: [LocalSnapshot(name: "com.apple.TimeMachine.2026-10-29-101530.local", date: nil)],
            hasFullDiskAccess: true
        )
        let summary = StorageSummary.make(files: result.accounted, classifier: BucketClassifier(home: "/Users/wyn"), facts: facts)
        let byBucket = Dictionary(uniqueKeysWithValues: summary.buckets.map { ($0.bucket, $0) })
        XCTAssertEqual(byBucket[.caches]?.bytes, 4096 * 10)
        XCTAssertEqual(byBucket[.downloads]?.bytes, 4096 * 5)
        XCTAssertEqual(byBucket[.everythingElse]?.bytes, 4096 * 6)
        XCTAssertEqual(byBucket[.notFound]?.bytes, 50_000)
        XCTAssertEqual(byBucket[.timeMachineSnapshots]?.detail?.hasPrefix("1 snapshot,"), true)
        XCTAssertEqual(byBucket[.purgeable]?.bytes, 1234)
        XCTAssertEqual(summary.buckets.first?.bucket, .notFound)
        XCTAssertEqual(summary.everythingElseTopFolders.first, FolderTotal(path: "/Users/wyn/Documents", bytes: 4096 * 4))
        XCTAssertEqual(summary.everythingElseTopFolders.last, FolderTotal(path: "/opt", bytes: 4096 * 2))
        XCTAssertEqual(summary.coverage!, Double(result.totalCounted) / Double(result.totalCounted + 50_000), accuracy: 1e-9)
        XCTAssertTrue(summary.isComplete)
        XCTAssertNil(summary.warning)
        // Named buckets + not found = used (purgeable is informational).
        let counted = summary.buckets.filter { $0.bucket != .purgeable }.reduce(Int64(0)) { $0 + $1.bytes }
        XCTAssertEqual(counted, facts.usedBytes)
    }

    func testWarningWithoutFullDiskAccess() {
        let summary = StorageSummary.make(files: [], classifier: BucketClassifier(home: "/Users/wyn"), facts: VolumeFacts(hasFullDiskAccess: false))
        XCTAssertFalse(summary.isComplete)
        XCTAssertTrue(summary.warning?.contains("Full Disk Access") ?? false)
    }

    func testTMUtilParsing() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-10-29-101530.local
        com.apple.TimeMachine.2026-07-01-230000.local

        """
        let snaps = TMUtilParser.parseLocalSnapshots(output, timeZone: UKTime.timeZone)
        XCTAssertEqual(snaps.count, 2)
        XCTAssertEqual(snaps[0].date, uk(2026, 10, 29, 10, 15, 30))
        XCTAssertEqual(snaps[1].date, uk(2026, 7, 1, 23, 0, 0))
        XCTAssertEqual(TMUtilParser.parseLocalSnapshots("com.apple.TimeMachine.garbage.local").first?.date, nil)
        XCTAssertTrue(TMUtilParser.parseLocalSnapshots("No snapshots found").isEmpty)
    }

    // MARK: Changed since last scan

    func testGrowthPointsAtTheFolderThatGrew() {
        let old: [String: Int64] = ["/": 100, "/Users": 80, "/Users/wyn": 80, "/Users/wyn/Movies": 10, "/Users/wyn/Documents": 70]
        let new: [String: Int64] = ["/": 150, "/Users": 130, "/Users/wyn": 130, "/Users/wyn/Movies": 60, "/Users/wyn/Movies/OBS": 50, "/Users/wyn/Documents": 70]
        let grew = ScanDiff.grew(old: old, new: new)
        XCTAssertEqual(grew.map(\.path), ["/Users/wyn/Movies/OBS"])
        XCTAssertEqual(grew.first?.delta, 50)

        let all = ScanDiff.grew(old: old, new: new, collapseParents: false)
        XCTAssertEqual(all.map(\.path), ["/", "/Users", "/Users/wyn", "/Users/wyn/Movies", "/Users/wyn/Movies/OBS"])
    }

    func testGrowthSpreadAcrossChildrenKeepsTheParent() {
        let old: [String: Int64] = ["/a": 0, "/a/x": 0, "/a/y": 0]
        let new: [String: Int64] = ["/a": 100, "/a/x": 50, "/a/y": 50]
        XCTAssertEqual(ScanDiff.grew(old: old, new: new).map(\.path), ["/a", "/a/x", "/a/y"])
    }

    func testShrank() {
        let old: [String: Int64] = ["/a": 100, "/b": 50]
        let new: [String: Int64] = ["/a": 40, "/b": 50]
        XCTAssertEqual(ScanDiff.shrank(old: old, new: new).map(\.delta), [-60])
    }

    // MARK: Cache

    func testCacheRoundTrip() throws {
        let records = [
            FileRecord(path: "/Users/wyn/Caf\u{E9}/a", logicalSize: 60_000_000, inode: 1),
            FileRecord(path: "/Users/wyn/📈/b", logicalSize: 10, inode: 2),
        ]
        let result = DiskTreeBuilder().build(records)
        let summary = StorageSummary.make(files: result.accounted, classifier: BucketClassifier(home: "/Users/wyn"), facts: VolumeFacts())
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        let cache = DiskScanCache(result: result, summary: summary, scannedAt: when, hadFullDiskAccess: true)
        let decoded = try DiskScanCache.decode(cache.encoded())
        XCTAssertEqual(decoded.version, DiskScanCache.currentVersion)
        XCTAssertEqual(decoded.scannedAt, when)
        XCTAssertEqual(decoded.tree, cache.tree)
        XCTAssertEqual(decoded.folderSizes, cache.folderSizes)
        XCTAssertEqual(decoded.biggestFiles, result.biggestFiles)
        XCTAssertEqual(decoded.summary.buckets, summary.buckets)
        XCTAssertNotNil(decoded.tree.descendant(["Users", "wyn", "Caf\u{E9}"]))
        // The tiny emoji folder is merged into "1 smaller item" in the pruned
        // tree, but keeps its own entry in the folder sizes.
        XCTAssertNil(decoded.tree.descendant(["Users", "wyn", "📈"]))
        XCTAssertNotNil(decoded.tree.descendant(["Users", "wyn", "1 smaller item"]))
        XCTAssertEqual(decoded.folderSizes["/Users/wyn/📈"], 4096)
        XCTAssertEqual(decoded.folderSizes["/Users/wyn/Caf\u{E9}"], AllocationMath.roundUp(60_000_000))
    }

    func testCacheFromAnotherVersionIsRejected() {
        XCTAssertThrowsError(try DiskScanCache.decode(Data(#"{"version": 99}"#.utf8))) { error in
            XCTAssertEqual(error as? DiskScanCache.CacheError, .unsupportedVersion(99))
        }
    }

    func testCacheDiffAgainstNewScan() {
        let first = DiskTreeBuilder().build([FileRecord(path: "/Users/wyn/Movies/OBS/a.mkv", logicalSize: 4096, inode: 1)])
        let cache = DiskScanCache(result: first, summary: StorageSummary.make(files: [], classifier: BucketClassifier(home: "/Users/wyn"), facts: VolumeFacts()), scannedAt: Date(), hadFullDiskAccess: true)
        let second = DiskTreeBuilder().build([
            FileRecord(path: "/Users/wyn/Movies/OBS/a.mkv", logicalSize: 4096, inode: 1),
            FileRecord(path: "/Users/wyn/Movies/OBS/b.mkv", logicalSize: 4096 * 100, inode: 2),
        ])
        let grew = cache.grewSince(newFolderSizes: second.root.folderSizes(maxDepth: cache.folderDepth))
        XCTAssertEqual(grew.first?.path, "/Users/wyn/Movies/OBS")
        XCTAssertEqual(grew.first?.delta, 4096 * 100)
    }

    // MARK: Treemap

    func testTreemapAreasAreProportionalAndDoNotOverlap() {
        let sizes: [Double] = [6, 6, 4, 3, 2, 2, 1, 0]
        let bounds = TreemapRect(x: 10, y: 20, width: 6, height: 4)
        let rects = Treemap.layout(sizes: sizes, in: bounds)
        XCTAssertEqual(rects.count, sizes.count)
        for (rect, size) in zip(rects, sizes) {
            XCTAssertEqual(rect.area, size, accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(rect.x, bounds.x - 1e-9)
            XCTAssertGreaterThanOrEqual(rect.y, bounds.y - 1e-9)
            XCTAssertLessThanOrEqual(rect.x + rect.width, bounds.x + bounds.width + 1e-9)
            XCTAssertLessThanOrEqual(rect.y + rect.height, bounds.y + bounds.height + 1e-9)
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                let a = rects[i], b = rects[j]
                let w = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
                let h = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
                XCTAssertLessThanOrEqual(max(0, w) * max(0, h), 1e-9, "\(i) overlaps \(j)")
            }
        }
    }

    func testTreemapEmptyInput() {
        XCTAssertTrue(Treemap.layout(sizes: [], in: TreemapRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        let zero = Treemap.layout(sizes: [0, 0], in: TreemapRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(zero.map(\.area), [0, 0])
    }
}
