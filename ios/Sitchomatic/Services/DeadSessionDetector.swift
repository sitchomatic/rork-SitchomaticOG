import Foundation
import WebKit

@MainActor
class DeadSessionDetector {
    static let shared = DeadSessionDetector()

    private let logger = DebugLogger.shared
    private let activityMonitor = SessionActivityMonitor.shared
    private let heartbeatTimeoutSeconds: TimeInterval = 15
    private var activeWatchdogs: [String: Task<Void, Never>] = [:]
    private var sessionStartTimes: [String: Date] = [:]

    func isSessionAlive(_ webView: WKWebView?, sessionId: String = "") async -> Bool {
        guard let webView else {
            logger.log("DeadSessionDetector: webView is nil — session dead", category: .webView, level: .warning, sessionId: sessionId)
            return false
        }

        let alive = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    let result = try await webView.evaluateJavaScript("'heartbeat_ok'")
                    return (result as? String) == "heartbeat_ok"
                } catch {
                    return false
                }
            }

            group.addTask {
                try? await Task.sleep(for: .seconds(self.heartbeatTimeoutSeconds))
                return false
            }

            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        if alive {
            activityMonitor.recordJSResponse(sessionId: sessionId)
        } else {
            logger.log("DeadSessionDetector: session HUNG — no JS response in \(Int(heartbeatTimeoutSeconds))s", category: .webView, level: .error, sessionId: sessionId)
        }

        return alive
    }

    func checkAndRecover(
        webView: WKWebView?,
        sessionId: String,
        onRecovery: () async -> Void
    ) async -> Bool {
        let alive = await isSessionAlive(webView, sessionId: sessionId)
        if !alive {
            logger.log("DeadSessionDetector: triggering recovery for session \(sessionId)", category: .webView, level: .warning, sessionId: sessionId)
            await onRecovery()
            return true
        }
        return false
    }

    func startWatchdog(
        sessionId: String,
        timeout: TimeInterval,
        checkInterval: TimeInterval = 10,
        webViewProvider: @escaping @MainActor () -> WKWebView?,
        onTimeout: @escaping @MainActor () async -> Void
    ) {
        stopWatchdog(sessionId: sessionId)
        sessionStartTimes[sessionId] = Date()
        activityMonitor.startMonitoring(sessionId: sessionId)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(timeout)

            while !Task.isCancelled && Date() < deadline {
                try? await Task.sleep(for: .seconds(checkInterval))
                guard !Task.isCancelled else { return }

                let elapsed = Date().timeIntervalSince(self.sessionStartTimes[sessionId] ?? Date())
                let remaining = timeout - elapsed

                let idleStatus = self.activityMonitor.checkIdleStatus(sessionId: sessionId)
                if case .idle(let secondsIdle) = idleStatus, secondsIdle >= SessionActivityMonitor.idleThresholdSeconds {
                    self.logger.log("DeadSessionDetector: IDLE TIMEOUT for \(sessionId) — no activity for \(Int(secondsIdle))s, killing session", category: .webView, level: .error, sessionId: sessionId)
                    await onTimeout()
                    self.cleanupWatchdog(sessionId: sessionId)
                    return
                }

                if remaining <= 0 {
                    self.logger.log("DeadSessionDetector: watchdog TIMEOUT for \(sessionId) after \(Int(elapsed))s", category: .webView, level: .critical, sessionId: sessionId)
                    await onTimeout()
                    self.cleanupWatchdog(sessionId: sessionId)
                    return
                }

                if remaining < timeout * 0.3 {
                    let webView = webViewProvider()
                    let alive = await self.isSessionAlive(webView, sessionId: sessionId)
                    if !alive {
                        self.logger.log("DeadSessionDetector: watchdog detected HUNG session \(sessionId) with \(Int(remaining))s remaining — triggering early timeout", category: .webView, level: .error, sessionId: sessionId)
                        await onTimeout()
                        self.cleanupWatchdog(sessionId: sessionId)
                        return
                    }
                }
            }

            self.cleanupWatchdog(sessionId: sessionId)
        }

        activeWatchdogs[sessionId] = task
        logger.log("DeadSessionDetector: watchdog started for \(sessionId) (timeout=\(Int(timeout))s, interval=\(Int(checkInterval))s, idleThreshold=\(Int(SessionActivityMonitor.idleThresholdSeconds))s)", category: .webView, level: .debug, sessionId: sessionId)
    }

    func stopWatchdog(sessionId: String) {
        if let existing = activeWatchdogs[sessionId] {
            existing.cancel()
            cleanupWatchdog(sessionId: sessionId)
        }
    }

    func stopAllWatchdogs() {
        for (sessionId, task) in activeWatchdogs {
            task.cancel()
            sessionStartTimes.removeValue(forKey: sessionId)
            activityMonitor.stopMonitoring(sessionId: sessionId)
        }
        activeWatchdogs.removeAll()
        logger.log("DeadSessionDetector: all watchdogs stopped", category: .webView, level: .info)
    }

    var activeWatchdogCount: Int {
        activeWatchdogs.count
    }

    func activeWatchdogSessions() -> [(sessionId: String, elapsedSeconds: Int)] {
        sessionStartTimes.compactMap { sessionId, startTime in
            guard activeWatchdogs[sessionId] != nil else { return nil }
            return (sessionId, Int(Date().timeIntervalSince(startTime)))
        }.sorted { $0.elapsedSeconds > $1.elapsedSeconds }
    }

    private func cleanupWatchdog(sessionId: String) {
        activeWatchdogs.removeValue(forKey: sessionId)
        sessionStartTimes.removeValue(forKey: sessionId)
        activityMonitor.stopMonitoring(sessionId: sessionId)
    }
}
