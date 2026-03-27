import UIKit

nonisolated enum BlankScreenshotDetector: Sendable {

    static func isBlank(_ image: UIImage, threshold: Double = 0.97) -> Bool {
        guard let cgImage = image.cgImage else { return true }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return true }

        let sampleSize = 60
        let sampleW = min(sampleSize, width)
        let sampleH = min(sampleSize, height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = sampleW * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: sampleW * sampleH * bytesPerPixel)

        guard let context = CGContext(
            data: &pixelData,
            width: sampleW,
            height: sampleH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))

        let totalPixels = sampleW * sampleH
        guard totalPixels > 0 else { return true }

        var dominantCount = 0
        let pixelDataCount = pixelData.count
        guard pixelDataCount >= bytesPerPixel else { return true }
        let firstR = pixelData[0]
        let firstG = pixelData[1]
        let firstB = pixelData[2]

        let tolerance: UInt8 = 12

        for i in 0..<totalPixels {
            let offset = i * bytesPerPixel
            guard offset + 2 < pixelDataCount else { break }
            let r = pixelData[offset]
            let g = pixelData[offset + 1]
            let b = pixelData[offset + 2]

            let dr = r > firstR ? r - firstR : firstR - r
            let dg = g > firstG ? g - firstG : firstG - g
            let db = b > firstB ? b - firstB : firstB - b

            if dr <= tolerance && dg <= tolerance && db <= tolerance {
                dominantCount += 1
            }
        }

        let uniformity = Double(dominantCount) / Double(totalPixels)
        return uniformity >= threshold
    }
}
