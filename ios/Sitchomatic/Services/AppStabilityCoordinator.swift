import Foundation
import UIKit

@MainActor
final class AppStabilityCoordinator {
    static let shared = AppStabilityCoordinator()

    private let logger = DebugLogger.shared
    private let crashProtection = CrashProtectionService.shared
    private var healthCheckTask: Task<Void, Never>?
    private var isRunning: Bool = false

    private var consecutiveHealthyChecks: Int = 0
    private var consecutiveUnhealthyChecks: Int = 0
    private var taskGroupWatchdogs: [String: Task<Void, Never>] = [:]
    private var subsystemHealthStatus: [String: Bool] = [:]
    private(set) var lastHealthReport: HealthReport?
    private var backgroundSaveTask: Task<Void, Never>?
    private var foregroundObserver: Any?
    private var backgroundObserver: Any?
    private var terminateObserver: Any?

    nonisolated struct HealthReport: Sendable {
        let timestamp: Date
        let memoryMB: Int
        let memoryGrowthRate: Double
        let webViewCount: Int
        let webViewLeakSuspected: Bool
        let loginBatchRunning: Bool
        let ppsrBatchRunning: Bool
        let deathSpiralDetected: Bool
        let watchdogCount: Int
        let overallHealthy: Bool

        var summary: String {
            let status = overallHealthy ? "HEALTHY" : "DEGRADED"
            return "[\(status)] Mem:\(memoryMB)MB(\(String(format: "%.1f", memoryGrowthRate))MB/s) WV:\(webViewCount) Login:\(loginBatchRunning ? "RUN" : "idle") PPSR:\(ppsrBatchRunning ? "RUN" : "idle")\(deathSpiralDetected ? " SPIRAL!" : "")"
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startPeriodicHealthCheck()
        registerLifecycleObservers()
        startPeriodicStatePersistence()
        logger.log("StabilityCoordinator: started", category: .system, level: .info)
    }

    func stop() {
        isRunning = false
        healthCheckTask?.cancel()
        healthCheckTask = nil
        backgroundSaveTask?.cancel()
        backgroundSaveTask = nil
        cancelAllWatchdogs()
        removeLifecycleObservers()
        logger.log("StabilityCoordinator: stopped", category: .system, level: .info)
    }

    private func startPeriodicHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.computeCheckInterval()
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self.performHealthCheck()
            }
        }
    }

    private func computeCheckInterval() -> TimeInterval {
        if crashProtection.isMemoryDeathSpiral { return 3 }
        if consecutiveUnhealthyChecks > 3 { return 5 }
        let anyBatchRunning = LoginViewModel.shared.isRunning || PPSRAutomationViewModel.shared.isRunning
        return anyBatchRunning ? 8 : 15
    }

    private func performHealthCheck() {
        let memMB = crashProtection.currentMemoryUsageMB()
        let growthRate = crashProtection.currentGrowthRateMBPerSec
        let webViewCount = WebViewPool.shared.activeCount
        let loginRunning = LoginViewModel.shared.isRunning
        let ppsrRunning = PPSRAutomationViewModel.shared.isRunning
        let deathSpiral = crashProtection.isMemoryDeathSpiral
        let watchdogCount = DeadSessionDetector.shared.activeWatchdogCount

        let webViewLeakSuspected = webViewCount > 0 && !loginRunning && !ppsrRunning

        let healthy = memMB < crashProtection.recommendedMaxConcurrency * 500
            && !deathSpiral
            && !webViewLeakSuspected
            && consecutiveUnhealthyChecks < 5

        let report = HealthReport(
            timestamp: Date(),
            memoryMB: memMB,
            memoryGrowthRate: growthRate,
            webViewCount: webViewCount,
            webViewLeakSuspected: webViewLeakSuspected,
            loginBatchRunning: loginRunning,
            ppsrBatchRunning: ppsrRunning,
            deathSpiralDetected: deathSpiral,
            watchdogCount: watchdogCount,
            overallHealthy: healthy
        )
        lastHealthReport = report

        if healthy {
            consecutiveHealthyChecks += 1
            consecutiveUnhealthyChecks = 0
        } else {
            consecutiveUnhealthyChecks += 1
            consecutiveHealthyChecks = 0
        }

        if webViewLeakSuspected {
            handleWebViewLeak(count: webViewCount)
        }

        if deathSpiral && (loginRunning || ppsrRunning) {
            handleDeathSpiralDuringBatch()
        }

        if consecutiveUnhealthyChecks >= 5 {
            handleProlongedDegradation()
        }

        if watchdogCount > 20 {
            logger.log("StabilityCoordinator: excessive watchdogs (\(watchdogCount)) — cleaning stale ones", category: .system, level: .warning)
            DeadSessionDetector.shared.stopAllWatchdogs()
        }

        if consecutiveUnhealthyChecks > 0 && consecutiveUnhealthyChecks % 3 == 0 {
            logger.log("StabilityCoordinator: \(report.summary) | \(AIPredictiveConcurrencyGovernor.shared.diagnosticSummary) | \(AIWebViewMemoryLifecycleManager.shared.diagnosticSummary)", category: .system, level: .warning)
        }
    }

    private func handleWebViewLeak(count: Int) {
        logger.log("StabilityCoordinator: WebView leak suspected — \(count) active with no batch running. Force resetting.", category: .system, level: .error)
        WebViewPool.shared.forceResetCount()
    }

    private func handleDeathSpiralDuringBatch() {
        logger.log("StabilityCoordinator: death spiral with active batch — persisting state before potential crash", category: .system, level: .critical)
        PersistentFileStorageService.shared.forceSave()
        LoginViewModel.shared.persistCredentialsNow()
        PPSRAutomationViewModel.shared.persistCardsNow()
    }

    private func handleProlongedDegradation() {
        logger.log("StabilityCoordinator: prolonged degradation (\(consecutiveUnhealthyChecks) checks) — forcing cleanup", category: .system, level: .critical)

        WebViewPool.shared.handleMemoryPressure()
        DebugLogger.shared.trimEntries(to: 1000)

        NetworkResilienceService.shared.invalidateSharedSessions()

        AppAlertManager.shared.pushWarning(
            source: .system,
            title: "App Stability Warning",
            message: "The app has been in a degraded state. Some resources have been freed to improve stability."
        )

        consecutiveUnhealthyChecks = 0
    }

    func registerTaskGroupWatchdog(id: String, timeout: TimeInterval, onTimeout: @escaping @MainActor () -> Void) {
        cancelTaskGroupWatchdog(id: id)
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.logger.log("StabilityCoordinator: task group watchdog FIRED for '\(id)' after \(Int(timeout))s", category: .system, level: .critical)
            onTimeout()
            self?.taskGroupWatchdogs.removeValue(forKey: id)
        }
        taskGroupWatchdogs[id] = task
    }

    func cancelTaskGroupWatchdog(id: String) {
        taskGroupWatchdogs[id]?.cancel()
        taskGroupWatchdogs.removeValue(forKey: id)
    }

    private func cancelAllWatchdogs() {
        for (_, task) in taskGroupWatchdogs {
            task.cancel()
        }
        taskGroupWatchdogs.removeAll()
    }

    private func startPeriodicStatePersistence() {
        backgroundSaveTask?.cancel()
        backgroundSaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled, let self else { return }
                let anyRunning = LoginViewModel.shared.isRunning || PPSRAutomationViewModel.shared.isRunning
                if anyRunning {
                    PersistentFileStorageService.shared.forceSave()
                    LoginViewModel.shared.persistCredentialsNow()
                    PPSRAutomationViewModel.shared.persistCardsNow()
                    self.logger.log("StabilityCoordinator: periodic state persistence (batch active)", category: .persistence, level: .debug)
                }
            }
        }
    }

    private func registerLifecycleObservers() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleForegroundReturn()
            }
        }

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleBackgroundEntry()
            }
        }

        terminateObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                PersistentFileStorageService.shared.forceSave()
                LoginViewModel.shared.persistCredentialsNow()
                PPSRAutomationViewModel.shared.persistCardsNow()
                DebugLogger.shared.persistLatestLog()
            }
        }
    }

    private func removeLifecycleObservers() {
        if let obs = foregroundObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = backgroundObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = terminateObserver { NotificationCenter.default.removeObserver(obs) }
        foregroundObserver = nil
        backgroundObserver = nil
        terminateObserver = nil
    }

    private func handleForegroundReturn() {
        logger.log("StabilityCoordinator: app returning to foreground — running health check", category: .system, level: .info)
        performHealthCheck()

        let webViewCount = WebViewPool.shared.activeCount
        let anyRunning = LoginViewModel.shared.isRunning || PPSRAutomationViewModel.shared.isRunning
        if webViewCount > 0 && !anyRunning {
            logger.log("StabilityCoordinator: orphaned WebViews after background — cleaning up", category: .system, level: .warning)
            WebViewPool.shared.forceResetCount()
        }
    }

    private func handleBackgroundEntry() {
        logger.log("StabilityCoordinator: entering background — persisting all state", category: .system, level: .info)
        PersistentFileStorageService.shared.forceSave()
        LoginViewModel.shared.persistCredentialsNow()
        PPSRAutomationViewModel.shared.persistCardsNow()
        DebugLogger.shared.persistLatestLog()

        WebViewPool.shared.drainPreWarmed()
    }

    func safeExecute<T: Sendable>(_ label: String, fallback: T, operation: @MainActor () async throws -> T) async -> T {
        do {
            return try await operation()
        } catch is CancellationError {
            logger.log("StabilityCoordinator: '\(label)' cancelled", category: .system, level: .debug)
            return fallback
        } catch {
            logger.log("StabilityCoordinator: '\(label)' failed — \(error.localizedDescription)", category: .system, level: .error)
            return fallback
        }
    }

    var healthSummary: String {
        lastHealthReport?.summary ?? "No health data"
    }
}
