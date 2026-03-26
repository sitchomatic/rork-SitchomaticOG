import Foundation

nonisolated struct Blake2s: Sendable {
    static let blockSize = 64
    static let hashSize = 32

    private static let iv: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
    ]

    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    static func hash(data: Data, outputLength: Int = 32, key: Data = Data()) -> Data {
        precondition(outputLength > 0 && outputLength <= 32)
        precondition(key.count <= 32)

        var h = iv
        h[0] ^= 0x01010000 ^ (UInt32(key.count) << 8) ^ UInt32(outputLength)

        var t: UInt64 = 0
        var buffer = Data()

        if !key.isEmpty {
            var paddedKey = key
            paddedKey.append(Data(repeating: 0, count: blockSize - key.count))
            buffer.append(paddedKey)
        }

        buffer.append(data)

        if buffer.isEmpty {
            buffer = Data(repeating: 0, count: blockSize)
        }

        let fullBlocks = (buffer.count - 1) / blockSize
        for i in 0..<fullBlocks {
            let blockStart = i * blockSize
            let block = buffer[blockStart..<(blockStart + blockSize)]
            t += UInt64(blockSize)
            compress(h: &h, block: Array(block), t: t, finalize: false)
        }

        let lastBlockStart = fullBlocks * blockSize
        var lastBlock = Array(buffer[lastBlockStart...])
        t += UInt64(lastBlock.count)
        while lastBlock.count < blockSize {
            lastBlock.append(0)
        }
        compress(h: &h, block: lastBlock, t: t, finalize: true)

        var result = Data(capacity: outputLength)
        for i in 0..<(outputLength / 4 + (outputLength % 4 != 0 ? 1 : 0)) {
            if i < 8 {
                var val = h[i]
                withUnsafeBytes(of: &val) { result.append(contentsOf: $0) }
            }
        }
        return result.prefix(outputLength)
    }

    static func keyedHash(key: Data, data: Data, outputLength: Int = 32) -> Data {
        hash(data: data, outputLength: outputLength, key: key)
    }

    private static func compress(h: inout [UInt32], block: [UInt8], t: UInt64, finalize: Bool) {
        var m = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            let offset = i * 4
            if offset + 3 < block.count {
                m[i] = UInt32(block[offset]) |
                    (UInt32(block[offset + 1]) << 8) |
                    (UInt32(block[offset + 2]) << 16) |
                    (UInt32(block[offset + 3]) << 24)
            }
        }

        var v = [UInt32](repeating: 0, count: 16)
        for i in 0..<8 { v[i] = h[i] }
        for i in 0..<8 { v[8 + i] = iv[i] }

        v[12] ^= UInt32(truncatingIfNeeded: t)
        v[13] ^= UInt32(truncatingIfNeeded: t >> 32)

        if finalize {
            v[14] = ~v[14]
        }

        for round in 0..<10 {
            let s = sigma[round]
            g(&v, 0, 4, 8, 12, m[s[0]], m[s[1]])
            g(&v, 1, 5, 9, 13, m[s[2]], m[s[3]])
            g(&v, 2, 6, 10, 14, m[s[4]], m[s[5]])
            g(&v, 3, 7, 11, 15, m[s[6]], m[s[7]])
            g(&v, 0, 5, 10, 15, m[s[8]], m[s[9]])
            g(&v, 1, 6, 11, 12, m[s[10]], m[s[11]])
            g(&v, 2, 7, 8, 13, m[s[12]], m[s[13]])
            g(&v, 3, 4, 9, 14, m[s[14]], m[s[15]])
        }

        for i in 0..<8 {
            h[i] ^= v[i] ^ v[i + 8]
        }
    }

    private static func g(_ v: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt32, _ y: UInt32) {
        v[a] = v[a] &+ v[b] &+ x
        v[d] = rotateRight(v[d] ^ v[a], by: 16)
        v[c] = v[c] &+ v[d]
        v[b] = rotateRight(v[b] ^ v[c], by: 12)
        v[a] = v[a] &+ v[b] &+ y
        v[d] = rotateRight(v[d] ^ v[a], by: 8)
        v[c] = v[c] &+ v[d]
        v[b] = rotateRight(v[b] ^ v[c], by: 7)
    }

    private static func rotateRight(_ value: UInt32, by amount: Int) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
