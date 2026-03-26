import UIKit

nonisolated struct GreenBannerDetector: Sendable {
    nonisolated struct DetectionResult: Sendable {
        let detected: Bool
        let confidence: Double
        let bannerRect: CGRect?
        let greenRowPercentage: Double
    }

    static func detectWelcomeText(in pageContent: String) -> (found: Bool, exact: String?) {
        let searchTarget = "Welcome!"
        guard let range = pageContent.range(of: searchTarget) else {
            return (false, nil)
        }
        let start = pageContent.index(range.lowerBound, offsetBy: -20, limitedBy: pageContent.startIndex) ?? pageContent.startIndex
        let end = pageContent.index(range.upperBound, offsetBy: 20, limitedBy: pageContent.endIndex) ?? pageContent.endIndex
        let context = String(pageContent[start..<end]).replacingOccurrences(of: "\n", with: " ")
        return (true, context)
    }

    static func detectWhiteBanner(in image: UIImage) -> DetectionResult {
        guard let cgImage = image.cgImage else { return DetectionResult(detected: false, confidence: 0, bannerRect: nil, greenRowPercentage: 0) }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 10, height > 10 else { return DetectionResult(detected: false, confidence: 0, bannerRect: nil, greenRowPercentage: 0) }

        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return DetectionResult(detected: false, confidence: 0, bannerRect: nil, greenRowPercentage: 0) }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let step = max(1, width / 200)
        let rowStep = max(1, height / 400)
        let samplesPerRow = (width + step - 1) / step

        var whiteRows: [Bool] = Array(repeating: false, count: height)

        for y in stride(from: 0, to: height, by: rowStep) {
            var whiteCount = 0
            for x in stride(from: 0, to: width, by: step) {
                let offset = (y * width + x) * bytesPerPixel
                let r = Double(pixelData[offset]) / 255.0
                let g = Double(pixelData[offset + 1]) / 255.0
                let b = Double(pixelData[offset + 2]) / 255.0

                let brightness = (r + g + b) / 3.0
                let maxDiff = max(abs(r - g), max(abs(g - b), abs(r - b)))
                if brightness > 0.85 && maxDiff < 0.15 {
                    whiteCount += 1
                }
            }
            let ratio = Double(whiteCount) / Double(samplesPerRow)
            if ratio > 0.50 {
                whiteRows[y] = true
                for fill in y..<min(y + rowStep, height) {
                    whiteRows[fill] = true
                }
            }
        }

        var bestStart = -1
        var bestLength = 0
        var currentStart = -1

        for y in 0..<height {
            if whiteRows[y] {
                if currentStart == -1 { currentStart = y }
            } else {
                if currentStart != -1 {
                    let length = y - currentStart
                    if length > bestLength {
                        bestLength = length
                        bestStart = currentStart
                    }
                    currentStart = -1
                }
            }
        }
        if currentStart != -1 {
            let length = height - currentStart
            if length > bestLength {
                bestLength = length
                bestStart = currentStart
            }
        }

        let minBannerHeight = max(8, Int(Double(height) * 0.02))
        let maxBannerHeight = Int(Double(height) * 0.25)
        if bestLength >= minBannerHeight && bestLength <= maxBannerHeight {
            let confidence = min(1.0, Double(bestLength) / Double(height) * 10.0)
            let normalizedRect = CGRect(
                x: 0,
                y: CGFloat(bestStart) / CGFloat(height),
                width: 1.0,
                height: CGFloat(bestLength) / CGFloat(height)
            )
            let pct = Double(bestLength) / Double(height) * 100.0
            return DetectionResult(detected: true, confidence: confidence, bannerRect: normalizedRect, greenRowPercentage: pct)
        }

        return DetectionResult(detected: false, confidence: 0, bannerRect: nil, greenRowPercentage: 0)
    }

    static func detect(in image: UIImage) -> DetectionResult {
        return detectWhiteBanner(in: image)
    }

    static func detectInCropRegion(image: UIImage, cropRect: CGRect) -> DetectionResult {
        guard let cgImage = image.cgImage else { return DetectionResult(detected: false, confidence: 0, bannerRect: nil, greenRowPercentage: 0) }

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        let pixelRect = CGRect(
            x: cropRect.origin.x * imgW,
            y: cropRect.origin.y * imgH,
            width: cropRect.size.width * imgW,
            height: cropRect.size.height * imgH
        ).intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))

        guard pixelRect.width > 5, pixelRect.height > 5,
              let cropped = cgImage.cropping(to: pixelRect) else {
            return detect(in: image)
        }

        let croppedImage = UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
        return detect(in: croppedImage)
    }
}
