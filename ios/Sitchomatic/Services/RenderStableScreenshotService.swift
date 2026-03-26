import Foundation
import WebKit
import UIKit

@MainActor
class RenderStableScreenshotService {
    static let shared = RenderStableScreenshotService()

    private let logger = DebugLogger.shared
    private let maxStabilityChecks: Int = 6
    private let stabilityCheckIntervalMs: Int = 300
    private let pixelDiffThreshold: Double = 0.02

    func captureStableScreenshot(from webView: WKWebView?, fallbackTimeout: TimeInterval = 3.0) async -> UIImage? {
        guard let webView else { return nil }
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }
        guard !webView.isLoading || webView.url != nil else { return nil }

        let readyState = try? await webView.evaluateJavaScript("document.readyState") as? String
        if readyState == nil {
            return nil
        }
        if readyState != "complete" {
            let start = Date()
            while Date().timeIntervalSince(start) < 2.0 {
                let state = try? await webView.evaluateJavaScript("document.readyState") as? String
                if state == nil { return nil }
                if state == "complete" { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        let pendingJS = """
        (function(){
            var imgs = document.querySelectorAll('img');
            var pending = 0;
            for (var i = 0; i < imgs.length; i++) {
                if (!imgs[i].complete && imgs[i].src) pending++;
            }
            return pending;
        })()
        """
        if let pendingCount = try? await webView.evaluateJavaScript(pendingJS) as? Int, pendingCount > 0 {
            try? await Task.sleep(for: .milliseconds(500))
        }

        var previousHash: Int?
        var stableCount = 0

        for check in 0..<maxStabilityChecks {
            guard webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }
            let config = WKSnapshotConfiguration()
            config.rect = webView.bounds
            let snapshot: UIImage?
            do {
                snapshot = try await webView.takeSnapshot(configuration: config)
            } catch {
                logger.log("RenderStable: takeSnapshot failed (check \(check)): \(error.localizedDescription)", category: .screenshot, level: .debug)
                return nil
            }
            guard let snapshot else {
                try? await Task.sleep(for: .milliseconds(stabilityCheckIntervalMs))
                continue
            }

            let currentHash = fastImageHash(snapshot)

            if let prev = previousHash {
                if currentHash == prev {
                    stableCount += 1
                    if stableCount >= 2 {
                        logger.log("RenderStable: stable after \(check + 1) checks", category: .screenshot, level: .trace)
                        return snapshot
                    }
                } else {
                    stableCount = 0
                }
            }

            previousHash = currentHash

            if check == maxStabilityChecks - 1 {
                logger.log("RenderStable: returning after max checks (may not be fully stable)", category: .screenshot, level: .debug)
                return snapshot
            }

            try? await Task.sleep(for: .milliseconds(stabilityCheckIntervalMs))
        }

        guard webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        do {
            return try await webView.takeSnapshot(configuration: config)
        } catch {
            logger.log("RenderStable: final takeSnapshot failed: \(error.localizedDescription)", category: .screenshot, level: .debug)
            return nil
        }
    }

    private func fastImageHash(_ image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let width = 16
        let height = 16
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var hash = 0
        for i in stride(from: 0, to: pixels.count - 1, by: 2) {
            hash = hash &* 31 &+ Int(pixels[i] > pixels[i + 1] ? 1 : 0)
        }
        return hash
    }
}
