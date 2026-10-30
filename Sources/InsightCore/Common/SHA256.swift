import Foundation

/// A streaming SHA-256 written in plain Swift so InsightCore needs nothing
/// beyond Foundation. On the Mac, Part B may swap in CryptoKit for speed via
/// `FileContentSource.fullHash`; the digests are identical.
public struct SHA256Hasher {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private var buffer: [UInt8] = []
    private var totalBytes: UInt64 = 0
    private var w = [UInt32](repeating: 0, count: 64)

    public init() {}

    public mutating func update(_ data: Data) {
        update([UInt8](data))
    }

    public mutating func update(_ bytes: [UInt8]) {
        totalBytes &+= UInt64(bytes.count)
        var index = 0
        if !buffer.isEmpty {
            let take = min(64 - buffer.count, bytes.count)
            buffer.append(contentsOf: bytes[0..<take])
            index = take
            if buffer.count == 64 {
                processBlock(buffer, at: 0)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        while bytes.count - index >= 64 {
            processBlock(bytes, at: index)
            index += 64
        }
        if index < bytes.count {
            buffer.append(contentsOf: bytes[index...])
        }
    }

    /// Finishes the hash and returns it as lowercase hex.
    public mutating func finalizeHex() -> String {
        let bitLength = totalBytes &* 8
        var tail = buffer
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        var offset = 0
        while offset < tail.count {
            processBlock(tail, at: offset)
            offset += 64
        }
        buffer.removeAll()
        let digits = Array("0123456789abcdef")
        var hex = ""
        hex.reserveCapacity(64)
        for word in state {
            for shift in stride(from: 28, through: 0, by: -4) {
                hex.append(digits[Int((word >> UInt32(shift)) & 0xf)])
            }
        }
        return hex
    }

    public static func hex(_ data: Data) -> String {
        var hasher = SHA256Hasher()
        hasher.update(data)
        return hasher.finalizeHex()
    }

    @inline(__always)
    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }

    private mutating func processBlock(_ bytes: [UInt8], at start: Int) {
        for i in 0..<16 {
            let j = start + i * 4
            let b0 = UInt32(bytes[j]) << 24
            let b1 = UInt32(bytes[j + 1]) << 16
            let b2 = UInt32(bytes[j + 2]) << 8
            let b3 = UInt32(bytes[j + 3])
            w[i] = b0 | b1 | b2 | b3
        }
        for i in 16..<64 {
            let x15 = w[i - 15]
            let x2 = w[i - 2]
            let s0: UInt32 = Self.rotr(x15, 7) ^ Self.rotr(x15, 18) ^ (x15 >> 3)
            let s1: UInt32 = Self.rotr(x2, 17) ^ Self.rotr(x2, 19) ^ (x2 >> 10)
            let sum1: UInt32 = w[i - 16] &+ s0
            let sum2: UInt32 = w[i - 7] &+ s1
            w[i] = sum1 &+ sum2
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for i in 0..<64 {
            let bigS1: UInt32 = Self.rotr(e, 6) ^ Self.rotr(e, 11) ^ Self.rotr(e, 25)
            let ch: UInt32 = (e & f) ^ (~e & g)
            let t1a: UInt32 = h &+ bigS1
            let t1b: UInt32 = ch &+ Self.k[i]
            let t1: UInt32 = t1a &+ t1b &+ w[i]
            let bigS0: UInt32 = Self.rotr(a, 2) ^ Self.rotr(a, 13) ^ Self.rotr(a, 22)
            let maj: UInt32 = (a & b) ^ (a & c) ^ (b & c)
            let t2: UInt32 = bigS0 &+ maj
            h = g
            g = f
            f = e
            e = d &+ t1
            d = c
            c = b
            b = a
            a = t1 &+ t2
        }
        state[0] = state[0] &+ a
        state[1] = state[1] &+ b
        state[2] = state[2] &+ c
        state[3] = state[3] &+ d
        state[4] = state[4] &+ e
        state[5] = state[5] &+ f
        state[6] = state[6] &+ g
        state[7] = state[7] &+ h
    }
}
