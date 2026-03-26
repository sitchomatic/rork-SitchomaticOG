import Foundation
import WebKit

@MainActor
class SessionActivityMonitor {
    static let shared = SessionActivityMonitor()

    private let logger = DebugLogger.shared
    private var sessions: [String: SessionActivity] = [:]

    private struct SessionActivity {
        var lastActivityAt: Date
        var navigationEvents: Int = 0
        var resourceLoads: Int = 0
        var jsResponses: Int = 0
        var domChanges: Int = 0
        var hasEverHadActivity: Bool = false

        var totalEvents: Int {
            navigationEvents + resourceLoads + jsResponses + domChanges
        }

        var secondsSinceLastActivity: TimeInterval {
            Date().timeIntervalSince(lastActivityAt)
        }
    }

    static let activeTimeoutSeconds: TimeInterval = 180
    static let idleThresholdSeconds: TimeInterval = 15
    static let idleRetryDelaySeconds: TimeInterval = 1

    func startMonitoring(sessionId: String) {
        sessions[sessionId] = SessionActivity(lastActivityAt: Date())
        logger.log("ActivityMonitor: started for \(sessionId)", category: .webView, level: .debug, sessionId: sessionId)
    }

    func stopMonitoring(sessionId: String) {
        sessions.removeValue(forKey: sessionId)
    }

    func recordNavigation(sessionId: String) {
        guard var activity = sessions[sessionId] else { return }
        activity.lastActivityAt = Date()
        activity.navigationEvents += 1
        activity.hasEverHadActivity = true
        sessions[sessionId] = activity
    }

    func recordResourceLoad(sessionId: String) {
        guard var activity = sessions[sessionId] else { return }
        activity.lastActivityAt = Date()
        activity.resourceLoads += 1
        activity.hasEverHadActivity = true
        sessions[sessionId] = activity
    }

    func recordJSResponse(sessionId: String) {
        guard var activity = sessions[sessionId] else { return }
        activity.lastActivityAt = Date()
        activity.jsResponses += 1
        activity.hasEverHadActivity = true
        sessions[sessionId] = activity
    }

    func recordDOMChange(sessionId: String) {
        guard var activity = sessions[sessionId] else { return }
        activity.lastActivityAt = Date()
        activity.domChanges += 1
        activity.hasEverHadActivity = true
        sessions[sessionId] = activity
    }

    func recordActivity(sessionId: String) {
        guard var activity = sessions[sessionId] else { return }
        activity.lastActivityAt = Date()
        activity.hasEverHadActivity = true
        sessions[sessionId] = activity
    }

    func hasActivity(sessionId: String) -> Bool {
        guard let activity = sessions[sessionId] else { return false }
        return activity.hasEverHadActivity
    }

    func isIdle(sessionId: String) -> Bool {
        guard let activity = sessions[sessionId] else { return true }
        return activity.secondsSinceLastActivity >= Self.idleThresholdSeconds
    }

    func secondsSinceLastActivity(sessionId: String) -> TimeInterval {
        guard let activity = sessions[sessionId] else { return .infinity }
        return activity.secondsSinceLastActivity
    }

    func resolveTimeout(sessionId: String) -> TimeInterval {
        guard let activity = sessions[sessionId] else {
            return Self.activeTimeoutSeconds
        }
        if activity.hasEverHadActivity {
            return Self.activeTimeoutSeconds
        }
        return Self.idleThresholdSeconds
    }

    nonisolated enum IdleCheckResult: Sendable {
        case active
        case idle(secondsIdle: TimeInterval)
        case noSession
    }

    func checkIdleStatus(sessionId: String) -> IdleCheckResult {
        guard let activity = sessions[sessionId] else { return .noSession }
        let idle = activity.secondsSinceLastActivity
        if idle >= Self.idleThresholdSeconds && !activity.hasEverHadActivity {
            return .idle(secondsIdle: idle)
        }
        if activity.hasEverHadActivity && idle >= Self.idleThresholdSeconds {
            return .idle(secondsIdle: idle)
        }
        return .active
    }

    func startIdleWatchdog(
        sessionId: String,
        webView: WKWebView?,
        pollInterval: TimeInterval = 3,
        onIdle: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        startMonitoring(sessionId: sessionId)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pollInterval))
                guard !Task.isCancelled else { return }

                if let wv = webView {
                    let hasNetwork = await self.probeWebViewActivity(wv, sessionId: sessionId)
                    if hasNetwork {
                        self.recordActivity(sessionId: sessionId)
                    }
                }

                let status = self.checkIdleStatus(sessionId: sessionId)
                switch status {
                case .idle(let seconds):
                    self.logger.log("ActivityMonitor: \(sessionId) IDLE for \(Int(seconds))s — triggering idle timeout", category: .webView, level: .warning, sessionId: sessionId)
                    await onIdle()
                    return
                case .active, .noSession:
                    break
                }
            }
        }

        return task
    }

    private func probeWebViewActivity(_ webView: WKWebView, sessionId: String) async -> Bool {
        do {
            let js = """
            (function() {
                var p = window.__sitchActivityProbe || { nav: 0, res: 0 };
                var navCount = performance.getEntriesByType('navigation').length + performance.getEntriesByType('resource').length;
                var changed = navCount !== p.res;
                p.res = navCount;
                window.__sitchActivityProbe = p;
                return changed ? 'active' : 'idle';
            })()
            """
            let result = try await webView.evaluateJavaScript(js)
            if let str = result as? String, str == "active" {
                return true
            }
        } catch {
            logger.log("SessionActivity: JS eval failed, assuming no activity change", category: .webView, level: .trace)
        }
        return false
    }

    func summary(sessionId: String) -> String {
        guard let activity = sessions[sessionId] else { return "no session" }
        return "nav:\(activity.navigationEvents) res:\(activity.resourceLoads) js:\(activity.jsResponses) dom:\(activity.domChanges) idle:\(Int(activity.secondsSinceLastActivity))s"
    }

    func stopAll() {
        sessions.removeAll()
    }
}
