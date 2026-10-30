import XCTest
@testable import InsightCore

final class CommonTests: XCTestCase {
    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256Hasher.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Hasher.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            SHA256Hasher.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    func testSHA256MillionAInUnevenChunks() {
        var hasher = SHA256Hasher()
        var remaining = 1_000_000
        var chunk = 1
        while remaining > 0 {
            let n = min(chunk, remaining)
            hasher.update([UInt8](repeating: 0x61, count: n))
            remaining -= n
            chunk = chunk * 3 + 1
        }
        XCTAssertEqual(hasher.finalizeHex(), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testSHA256ChunkingDoesNotMatter() {
        let data = bytes(10_000, seed: 3)
        var a = SHA256Hasher()
        a.update(data)
        var b = SHA256Hasher()
        b.update(data.prefix(63))
        b.update(data.subdata(in: 63..<64))
        b.update(data.subdata(in: 64..<5000))
        b.update(data.subdata(in: 5000..<10_000))
        XCTAssertEqual(a.finalizeHex(), b.finalizeHex())
    }

    func testByteFormat() {
        XCTAssertEqual(ByteFormat.string(0), "0 bytes")
        XCTAssertEqual(ByteFormat.string(1), "1 byte")
        XCTAssertEqual(ByteFormat.string(999), "999 bytes")
        XCTAssertEqual(ByteFormat.string(1000), "1.0 KB")
        XCTAssertEqual(ByteFormat.string(123_456_789), "123 MB")
        XCTAssertEqual(ByteFormat.string(1_500_000_000), "1.5 GB")
        XCTAssertEqual(ByteFormat.string(999_950), "1.0 MB")
    }

    func testDurationFormat() {
        XCTAssertEqual(DurationFormat.string(59), "0m")
        XCTAssertEqual(DurationFormat.string(3660), "1h 1m")
        XCTAssertEqual(DurationFormat.string(31 * 3600), "31h")
    }

    func testIntervalSetOperations() {
        let t0 = Date(timeIntervalSince1970: 0)
        func s(_ a: Double, _ b: Double) -> Span { Span(t0.addingTimeInterval(a), t0.addingTimeInterval(b)) }

        let merged = IntervalSet([s(0, 10), s(5, 15), s(20, 30), s(30, 31), s(40, 40)])
        XCTAssertEqual(merged.spans, [s(0, 15), s(20, 31)])
        XCTAssertEqual(merged.total, 26)

        let cut = merged.subtracting(IntervalSet([s(2, 4), s(12, 22)]))
        XCTAssertEqual(cut.spans, [s(0, 2), s(4, 12), s(22, 31)])

        let both = merged.intersection(IntervalSet([s(10, 25)]))
        XCTAssertEqual(both.spans, [s(10, 15), s(20, 25)])

        XCTAssertEqual(merged.subtracting(IntervalSet([s(-5, 100)])).total, 0)
        XCTAssertEqual(merged.subtracting(IntervalSet()).spans, merged.spans)
    }

    func testPathNormalisation() {
        XCTAssertEqual(PathUtils.normalize("/System/Volumes/Data/Users/wyn"), "/Users/wyn")
        XCTAssertEqual(PathUtils.normalize("/Users//wyn/"), "/Users/wyn")
        XCTAssertEqual(PathUtils.normalize("/Users/wyn/Cafe\u{301}"), "/Users/wyn/Caf\u{E9}")
        XCTAssertTrue(PathUtils.isInside("/Users/wyn/Library/Caches/x", "/Users/wyn/Library/Caches"))
        XCTAssertFalse(PathUtils.isInside("/Users/wyn/Library/CachesOld/x", "/Users/wyn/Library/Caches"))
        XCTAssertEqual(PathUtils.parent("/a/b/c"), "/a/b")
        XCTAssertEqual(PathUtils.parent("/a"), "/")
    }
}
