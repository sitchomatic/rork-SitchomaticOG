import Foundation
import UIKit

@MainActor
class ScreenshotDedupService {
    static let shared = ScreenshotDedupService()

    private let logger = DebugLogger.shared
    private var recentHashes: [Int] = []
    private let maxRecentHashes: Int = 50
    private let hashGridSize: Int = 16
    private(set) var duplicatesSkipped: Int = 0
    private(set) var totalChecked: Int = 0

    func isDuplicate(_ image: UIImage) -> Bool {
        totalChecked += 1
        let hash = perceptualHash(image)

        for existing in recentHashes {
            let distance = hammingDistance(hash, existing)
            if distance <= 3 {
                duplicatesSkipped += 1
                logger.log("ScreenshotDedup: duplicate detected (hamming=\(distance)), skipped (total skipped: \(duplicatesSkipped))", category: .screenshot, level: .trace)
                return true
            }
        }

        recentHashes.append(hash)
        if recentHashes.count > maxRecentHashes {
            recentHashes.removeFirst()
        }
        return false
    }

    func resetSession() {
        recentHashes.removeAll()
    }

    func resetAll() {
        recentHashes.removeAll()
        duplicatesSkipped = 0
        totalChecked = 0
    }

    private func perceptualHash(_ image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let size = hashGridSize
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: size * size)
        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        let total = pixels.reduce(0) { $0 + Int($1) }
        let average = UInt8(total / pixels.count)

        var hash = 0
        for (i, pixel) in pixels.enumerated() {
            if pixel > average {
                hash |= (1 << (i % 64))
            }
        }
        return hash
    }

    private func hammingDistance(_ a: Int, _ b: Int) -> Int {
        var xor = a ^ b
        var count = 0
        while xor != 0 {
            count += xor & 1
            xor >>= 1
        }
        return count
    }
}
