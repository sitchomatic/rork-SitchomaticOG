import Foundation

@MainActor
class WebViewTracker {
    static let shared = WebViewTracker()

    private(set) var activeCount: Int = 0
    private(set) var totalCreated: Int = 0
    private(set) var totalReleased: Int = 0
    private(set) var processTerminationCount: Int = 0
    private(set) var peakActiveCount: Int = 0
    private var activeSessions: [String: Date] = [:]
    private var orphanDetectionCount: Int = 0

    func incrementActive(sessionId: String = "unknown") {
        activeCount += 1
        totalCreated += 1
        activeSessions[sessionId] = Date()
        peakActiveCount = max(peakActiveCount, activeCount)
    }

    func decrementActive(sessionId: String = "unknown") {
        guard activeCount > 0 else {
            DebugLogger.shared.log("WebViewTracker: decrementActive called with count=0 (session: \(sessionId)) — possible double-tearDown", category: .webView, level: .warning)
            return
        }
        activeCount -= 1
        totalReleased += 1
        activeSessions.removeValue(forKey: sessionId)
    }

    func reportProcessTermination() {
        processTerminationCount += 1
    }

    func reset() {
        let leaked = activeSessions
        activeCount = 0
        activeSessions.removeAll()
        if !leaked.isEmpty {
            let sessionList = leaked.keys.prefix(10).joined(separator: ", ")
            DebugLogger.shared.log("WebViewTracker: force-reset \(leaked.count) leaked sessions [\(sessionList)] (created:\(totalCreated) released:\(totalReleased))", category: .webView, level: .warning)
        } else {
            DebugLogger.shared.log("WebViewTracker: force-reset (created:\(totalCreated) released:\(totalReleased))", category: .webView, level: .warning)
        }
    }

    func detectOrphans(batchRunning: Bool) -> [String] {
        guard !batchRunning, !activeSessions.isEmpty else { return [] }
        let now = Date()
        let orphanThreshold: TimeInterval = 120
        let orphans = activeSessions.filter { now.timeIntervalSince($0.value) > orphanThreshold }
        if !orphans.isEmpty {
            orphanDetectionCount += 1
            let sessionList = orphans.keys.prefix(5).joined(separator: ", ")
            DebugLogger.shared.log("WebViewTracker: \(orphans.count) orphaned WebViews detected (>\(Int(orphanThreshold))s old) [\(sessionList)]", category: .webView, level: .error)
        }
        return Array(orphans.keys)
    }

    var activeSessionIds: [String] {
        Array(activeSessions.keys)
    }

    var diagnosticSummary: String {
        "Active: \(activeCount) | Peak: \(peakActiveCount) | Created: \(totalCreated) | Released: \(totalReleased) | Crashes: \(processTerminationCount) | Orphans: \(orphanDetectionCount)"
    }
}
