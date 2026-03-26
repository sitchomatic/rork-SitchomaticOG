import Foundation

@MainActor
class WebViewTracker {
    static let shared = WebViewTracker()

    private(set) var activeCount: Int = 0
    private(set) var totalCreated: Int = 0
    private(set) var totalReleased: Int = 0
    private(set) var processTerminationCount: Int = 0
    private(set) var peakActiveCount: Int = 0

    func incrementActive() {
        activeCount += 1
        totalCreated += 1
        peakActiveCount = max(peakActiveCount, activeCount)
    }

    func decrementActive() {
        guard activeCount > 0 else { return }
        activeCount -= 1
        totalReleased += 1
    }

    func reportProcessTermination() {
        processTerminationCount += 1
    }

    func reset() {
        activeCount = 0
        DebugLogger.shared.log("WebViewTracker: force-reset (created:\(totalCreated) released:\(totalReleased))", category: .webView, level: .warning)
    }

    var diagnosticSummary: String {
        "Active: \(activeCount) | Peak: \(peakActiveCount) | Created: \(totalCreated) | Released: \(totalReleased) | Crashes: \(processTerminationCount)"
    }
}
