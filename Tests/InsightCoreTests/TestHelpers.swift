import Foundation
@testable import InsightCore

/// A date in UK local time.
func uk(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    var c = DateComponents()
    c.year = year
    c.month = month
    c.day = day
    c.hour = hour
    c.minute = minute
    c.second = second
    return UKTime.calendar.date(from: c)!
}

/// A picture made of an 8x8 grid of flat grey blocks with pseudo-random
/// brightness. The same seed gives the same picture at any size.
func blockImage(seed: UInt64, width: Int, height: Int, noise: Int = 0) -> GreyImage {
    var state = seed
    var blocks = [UInt8]()
    for _ in 0..<64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        blocks.append(UInt8(truncatingIfNeeded: state >> 56))
    }
    var pixels = [UInt8]()
    pixels.reserveCapacity(width * height)
    for y in 0..<height {
        for x in 0..<width {
            let bx = x * 8 / width
            let by = y * 8 / height
            var v = Int(blocks[by * 8 + bx])
            if noise > 0 {
                v += ((x * 31 + y * 17 + Int(seed % 7)) % (2 * noise + 1)) - noise
            }
            pixels.append(UInt8(max(0, min(255, v))))
        }
    }
    return GreyImage(width: width, height: height, pixels: pixels)!
}

/// Files held in memory, counting how often each is read.
final class MemorySource: FileContentSource {
    var files: [String: Data]
    var unreadable: Set<String> = []
    private(set) var reads: [String: Int] = [:]
    private(set) var fullHashes: [String: Int] = [:]

    init(_ files: [String: Data]) { self.files = files }

    struct Unreadable: Error {}

    func read(path: String, offset: Int64, length: Int) throws -> Data {
        reads[path, default: 0] += 1
        guard !unreadable.contains(path), let data = files[path] else { throw Unreadable() }
        let start = Int(min(Int64(data.count), max(0, offset)))
        let end = min(data.count, start + length)
        return data.subdata(in: start..<end)
    }

    func fullHash(path: String, size: Int64) throws -> String {
        fullHashes[path, default: 0] += 1
        guard !unreadable.contains(path), let data = files[path] else { throw Unreadable() }
        return SHA256Hasher.hex(data)
    }
}

func bytes(_ count: Int, seed: UInt8) -> Data {
    var out = Data(count: count)
    var v = seed
    for i in 0..<count {
        v = v &* 31 &+ 7
        out[i] = v
    }
    return out
}
