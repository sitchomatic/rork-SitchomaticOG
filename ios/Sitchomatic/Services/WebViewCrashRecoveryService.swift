import Foundation
import WebKit

@MainActor
class WebViewCrashRecoveryService {
    static let shared = WebViewCrashRecoveryService()

    private let logger = DebugLogger.shared
    private let maxRecoveriesPerSession: Int = 3
    private let recoveryBackoffBaseMs: Int = 500
    private var sessionRecoveryCounts: [String: Int] = [:]
    private(set) var totalRecoveries: Int = 0
    private(set) var totalUnrecoverable: Int = 0

    func canRecover(sessionId: String) -> Bool {
        let count = sessionRecoveryCounts[sessionId] ?? 0
        return count < maxRecoveriesPerSession
    }

    func recordRecovery(sessionId: String) {
        sessionRecoveryCounts[sessionId, default: 0] += 1
        totalRecoveries += 1
        logger.log("CrashRecovery: session \(sessionId) recovery #\(sessionRecoveryCounts[sessionId] ?? 0) (total: \(totalRecoveries))", category: .webView, level: .warning)
    }

    func recordUnrecoverable(sessionId: String) {
        totalUnrecoverable += 1
        logger.log("CrashRecovery: session \(sessionId) UNRECOVERABLE — max recoveries exceeded (total unrecoverable: \(totalUnrecoverable))", category: .webView, level: .critical)
    }

    func backoffDelay(sessionId: String) -> Int {
        let count = sessionRecoveryCounts[sessionId] ?? 0
        return recoveryBackoffBaseMs * (1 << min(count, 3))
    }

    func clearSession(_ sessionId: String) {
        sessionRecoveryCounts.removeValue(forKey: sessionId)
    }

    func resetAll() {
        sessionRecoveryCounts.removeAll()
        totalRecoveries = 0
        totalUnrecoverable = 0
    }

    func handleProcessTermination(
        session: LoginSiteWebSession,
        sessionId: String,
        onLog: ((String, PPSRLogEntry.Level) -> Void)?
    ) async -> Bool {
        WebViewPool.shared.reportProcessTermination()

        guard canRecover(sessionId: sessionId) else {
            recordUnrecoverable(sessionId: sessionId)
            onLog?("WebView process terminated — max recoveries exceeded, aborting", .error)
            return false
        }

        recordRecovery(sessionId: sessionId)
        let delay = backoffDelay(sessionId: sessionId)
        let attemptNum = sessionRecoveryCounts[sessionId] ?? 1

        onLog?("WebView process terminated — recovery attempt \(attemptNum)/\(maxRecoveriesPerSession), backoff \(delay)ms", .warning)
        logger.log("CrashRecovery: rebuilding WebView for session \(sessionId) after \(delay)ms backoff", category: .webView, level: .warning)

        try? await Task.sleep(for: .milliseconds(delay))

        session.tearDown(wipeAll: true)
        session.setUp(wipeAll: true)

        let loaded = await session.loadPage(timeout: 30)
        if loaded {
            onLog?("WebView crash recovery SUCCESS — page reloaded", .success)
            logger.log("CrashRecovery: session \(sessionId) recovered successfully", category: .webView, level: .success)
        } else {
            onLog?("WebView crash recovery FAILED — page did not load after rebuild", .error)
            logger.log("CrashRecovery: session \(sessionId) recovery FAILED — page load failed", category: .webView, level: .error)
        }

        return loaded
    }
}
