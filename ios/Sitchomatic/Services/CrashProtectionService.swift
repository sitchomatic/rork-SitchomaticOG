import Foundation
import UIKit

@MainActor
final class CrashProtectionService {
    static let shared = CrashProtectionService()

    private let logger = DebugLogger.shared
    private let memoryMonitor = MemoryMonitor()
    private var memoryTrimTimer: Task<Void, Never>?
    private var continuousLogFlushTask: Task<Void, Never>?
    private var isRegistered: Bool = false

    private var emergencyBatchKillCount: Int = 0
    private var lastEmergencyCleanup: Date = .distantPast
    private var crashCount: Int = 0
    private var lastCrashRecoveryTime: Date = .distantPast
    private var sessionCrashLog: [(timestamp: Date, signal: String, memoryMB: Int)] = []
    private(set) var lastCrashReport: CrashReport?

    private let stateFile = "crash_protection_state.json"
    private let crashReportFile = "crash_report_pending.json"
    private let launchTimestampFile = "launch_timestamps.json"
    private(set) var didPerformSafeBoot: Bool = false
    private let safeBootCrashThreshold = 2
    private let safeBootWindowSeconds: TimeInterval = 30

    // MARK: - Cleanup Escalation

    private struct CleanupTier {
        let logLimit: Int
        let drainPreWarmed: Bool
        let trimAttempts: Bool
        let aggressiveCleanup: Bool
        let screenshotCacheLimits: (memory: Int, disk: Int)?
        let clearScreenshots: Bool
        let killBatches: Bool
        let purgeURLCache: Bool
        let invalidateSessions: Bool
    }

    private let escalation: [MemoryMonitor.MemoryLevel: CleanupTier] = [
        .soft: CleanupTier(logLimit: 2500, drainPreWarmed: true, trimAttempts: false, aggressiveCleanup: false, screenshotCacheLimits: nil, clearScreenshots: false, killBatches: false, purgeURLCache: false, invalidateSessions: false),
        .high: CleanupTier(logLimit: 1500, drainPreWarmed: true, trimAttempts: true, aggressiveCleanup: false, screenshotCacheLimits: nil, clearScreenshots: false, killBatches: false, purgeURLCache: false, invalidateSessions: false),
        .critical: CleanupTier(logLimit: 800, drainPreWarmed: false, trimAttempts: true, aggressiveCleanup: true, screenshotCacheLimits: (memory: 10, disk: 200), clearScreenshots: false, killBatches: false, purgeURLCache: false, invalidateSessions: false),
        .emergency: CleanupTier(logLimit: 300, drainPreWarmed: false, trimAttempts: true, aggressiveCleanup: true, screenshotCacheLimits: (memory: 5, disk: 100), clearScreenshots: true, killBatches: true, purgeURLCache: true, invalidateSessions: true),
    ]

    // MARK: - Public API

    func register() {
        guard !isRegistered else { return }
        isRegistered = true
        installSignalHandlers()
        restoreState()
        checkAndPerformSafeBootIfNeeded()
        recordLaunchTimestamp()
        startAdaptiveMemoryTrimming()
        startContinuousLogFlush()
        let t = memoryMonitor.thresholds
        logger.log("CrashProtection: registered (soft=\(t.softMB)MB, high=\(t.highMB)MB, critical=\(t.criticalMB)MB, emergency=\(t.emergencyMB)MB, previousCrashes=\(crashCount))", category: .system, level: .info)
    }

    func currentMemoryUsageMB() -> Int { MemoryMonitor.currentUsageMB() }
    var isMemoryDeathSpiral: Bool { memoryMonitor.deathSpiralDetected }
    var isPreemptiveThrottleActive: Bool { memoryMonitor.preemptiveThrottleActive }
    var currentGrowthRateMBPerSec: Double { memoryMonitor.growthRateMBPerSecond }
    var totalCrashCount: Int { crashCount }
    var shouldReduceConcurrency: Bool { memoryMonitor.shouldReduceConcurrency }
    var recommendedMaxConcurrency: Int { memoryMonitor.recommendedMaxConcurrency }

    var isMemorySafeForNewSession: Bool {
        let mb = MemoryMonitor.currentUsageMB()
        return mb < memoryMonitor.thresholds.highMB && !memoryMonitor.deathSpiralDetected
    }

    var isMemoryEmergency: Bool {
        let mb = MemoryMonitor.currentUsageMB()
        return mb > memoryMonitor.thresholds.emergencyMB || memoryMonitor.deathSpiralDetected
    }

    var isMemoryCritical: Bool {
        let mb = MemoryMonitor.currentUsageMB()
        return mb > memoryMonitor.thresholds.criticalMB
    }

    func waitForMemoryToDrop(timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isMemorySafeForNewSession && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return false }
        }
        return isMemorySafeForNewSession
    }

    var diagnosticSummary: String {
        let mb = currentMemoryUsageMB()
        let webViews = WebViewTracker.shared.activeCount
        let growth = String(format: "%.1f", memoryMonitor.growthRateMBPerSecond)
        let spiral = memoryMonitor.deathSpiralDetected ? " SPIRAL!" : ""
        return "Memory: \(mb)MB (\(growth)MB/s\(spiral)) | WebViews: \(webViews) | EmergencyKills: \(emergencyBatchKillCount) | Crashes: \(crashCount) | ConsecutiveCritical: \(memoryMonitor.consecutiveCriticalChecks)"
    }

    func generateCrashReportText() -> String {
        lastCrashReport?.formattedReport ?? "No crash report available"
    }

    // MARK: - Memory Monitoring Loop

    private func startAdaptiveMemoryTrimming() {
        memoryTrimTimer?.cancel()
        memoryTrimTimer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.memoryMonitor.adaptiveCheckInterval
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self.performMemoryCheck()
            }
        }
    }

    private func performMemoryCheck() {
        let (level, usedMB) = memoryMonitor.update()
        let growth = String(format: "%.1f", memoryMonitor.growthRateMBPerSecond)

        if memoryMonitor.deathSpiralDetected {
            let ratePerMin = memoryMonitor.growthRateMBPerSecond * 60
            logger.log("CrashProtection: DEATH SPIRAL DETECTED — memory growing \(Int(ratePerMin))MB/min", category: .system, level: .critical)
            AppAlertManager.shared.pushCritical(
                source: .system,
                title: "Memory Death Spiral",
                message: "Memory growing at \(Int(ratePerMin))MB/min. Batches will be stopped to prevent crash."
            )
            if usedMB > memoryMonitor.thresholds.criticalMB {
                executeCleanup(level: .emergency, usedMB: usedMB)
                return
            }
        }

        if memoryMonitor.preemptiveThrottleActive {
            logger.log("CrashProtection: RUNAWAY GROWTH — \(String(format: "%.0f", memoryMonitor.growthRateMBPerSecond))MB/s detected at \(usedMB)MB — preemptive throttle active", category: .system, level: .critical)
            executeCleanup(level: .critical, usedMB: usedMB)
        }

        switch level {
        case .emergency:
            logger.log("CrashProtection: EMERGENCY memory (\(usedMB)MB, growth=\(growth)MB/s) — killing active batches (consecutive critical: \(memoryMonitor.consecutiveCriticalChecks))", category: .system, level: .critical)
            executeCleanup(level: .emergency, usedMB: usedMB)
        case .critical:
            logger.log("CrashProtection: CRITICAL memory (\(usedMB)MB, growth=\(growth)MB/s) — aggressive cleanup (consecutive: \(memoryMonitor.consecutiveCriticalChecks))", category: .system, level: .critical)
            executeCleanup(level: .critical, usedMB: usedMB)
            if memoryMonitor.shouldEscalateToCritical {
                logger.log("CrashProtection: \(memoryMonitor.consecutiveCriticalChecks) consecutive critical checks — escalating to emergency", category: .system, level: .critical)
                executeCleanup(level: .emergency, usedMB: usedMB)
            }
        case .high:
            logger.log("CrashProtection: High memory (\(usedMB)MB) — soft cleanup", category: .system, level: .warning)
            executeCleanup(level: .high, usedMB: usedMB)
        case .soft:
            executeCleanup(level: .soft, usedMB: usedMB)
        case .normal:
            break
        }
    }

    // MARK: - Data-Driven Cleanup Execution

    private func executeCleanup(level: MemoryMonitor.MemoryLevel, usedMB: Int) {
        guard let tier = escalation[level] else { return }

        DebugLogger.shared.trimEntries(to: tier.logLimit)

        if tier.aggressiveCleanup {
            DebugLogger.shared.handleMemoryPressure()
        }



        if let limits = tier.screenshotCacheLimits {
            ScreenshotCacheService.shared.setMaxCacheCounts(memory: limits.memory, disk: limits.disk)
        }
        if tier.clearScreenshots {
            ScreenshotCacheService.shared.clearAll()
        }

        if tier.aggressiveCleanup {
            LoginViewModel.shared.handleMemoryPressure()
            PPSRAutomationViewModel.shared.handleMemoryPressure()
        }
        if tier.trimAttempts {
            LoginViewModel.shared.trimAttemptsIfNeeded()
            PPSRAutomationViewModel.shared.trimChecksIfNeeded()
        }
        if tier.clearScreenshots {
            LoginViewModel.shared.clearDebugScreenshots()
        }
        if tier.killBatches {
            if LoginViewModel.shared.isRunning {
                logger.log("CrashProtection: EMERGENCY — force-stopping login batch (memory: \(usedMB)MB, kill #\(emergencyBatchKillCount))", category: .system, level: .critical)
                LoginViewModel.shared.emergencyStop()
            }
            if PPSRAutomationViewModel.shared.isRunning {
                logger.log("CrashProtection: EMERGENCY — force-stopping PPSR batch (memory: \(usedMB)MB)", category: .system, level: .critical)
                PPSRAutomationViewModel.shared.emergencyStop()
            }
        }

        if tier.killBatches {
            emergencyBatchKillCount += 1
            lastEmergencyCleanup = checkDeathSpiralPersistence(usedMB: usedMB)
            DeadSessionDetector.shared.stopAllWatchdogs()
        }

        if tier.purgeURLCache {
            URLCache.shared.removeAllCachedResponses()
            URLCache.shared.memoryCapacity = 0
        }

        if tier.invalidateSessions {
            NetworkResilienceService.shared.invalidateSharedSessions()
        }

        if level == .emergency {
            let afterMB = currentMemoryUsageMB()
            logger.log("CrashProtection: emergency cleanup freed ~\(usedMB - afterMB)MB (now \(afterMB)MB)", category: .system, level: .critical)
        }
    }

    private func checkDeathSpiralPersistence(usedMB: Int) -> Date {
        let now = Date()
        let timeSinceLast = now.timeIntervalSince(lastEmergencyCleanup)
        if timeSinceLast < 60 {
            logger.log("CrashProtection: TWO emergency cleanups within \(Int(timeSinceLast))s — app may be in memory death spiral", category: .system, level: .critical)
            PersistentFileStorageService.shared.forceSave()
            LoginViewModel.shared.persistCredentialsNow()
            PPSRAutomationViewModel.shared.persistCardsNow()
        }
        return now
    }

    // MARK: - Continuous Log Flush

    private func startContinuousLogFlush() {
        continuousLogFlushTask?.cancel()
        continuousLogFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                let anyBatchRunning = LoginViewModel.shared.isRunning || PPSRAutomationViewModel.shared.isRunning
                let interval: TimeInterval = anyBatchRunning ? 45 : 10
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                DebugLogger.shared.persistLatestLog()
                self.persistPreCrashDiagnostics()
                if anyBatchRunning && self.isMemoryCritical {
                    LoginViewModel.shared.handleMemoryPressure()
                    PPSRAutomationViewModel.shared.handleMemoryPressure()
                }
            }
        }
    }

    private func persistPreCrashDiagnostics() {
        guard let diagURL = documentsURL("pre_crash_diagnostics.txt") else { return }
        let memMB = currentMemoryUsageMB()
        let growth = String(format: "%.1f", memoryMonitor.growthRateMBPerSecond)
        let diag = """
        === PRE-CRASH DIAGNOSTICS ===
        Timestamp: \(Date())
        Memory: \(memMB)MB (growth: \(growth)MB/s)
        WebViews: \(WebViewTracker.shared.activeCount)
        Login Batch: \(LoginViewModel.shared.isRunning ? "RUNNING" : "idle")
        PPSR Batch: \(PPSRAutomationViewModel.shared.isRunning ? "RUNNING" : "idle")
        Death Spiral: \(memoryMonitor.deathSpiralDetected)
        Consecutive Critical: \(memoryMonitor.consecutiveCriticalChecks)
        Emergency Kills: \(emergencyBatchKillCount)
        Total Crashes: \(crashCount)
        iOS: \(UIDevice.current.systemVersion)
        Device: \(UIDevice.current.model)
        App: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
        ===
        """
        do {
            try diag.write(to: diagURL, atomically: true, encoding: .utf8)
        } catch {
            logger.log("CrashProtection: failed to write pre-crash diagnostics: \(error.localizedDescription)", category: .system, level: .error)
        }
    }

    // MARK: - Signal Handlers

    private func installSignalHandlers() {
        let handler: @convention(c) (Int32) -> Void = { signal in
            let signalName: String
            switch signal {
            case SIGABRT: signalName = "SIGABRT"
            case SIGSEGV: signalName = "SIGSEGV"
            case SIGBUS: signalName = "SIGBUS"
            case SIGFPE: signalName = "SIGFPE"
            case SIGILL: signalName = "SIGILL"
            case SIGTRAP: signalName = "SIGTRAP"
            default: signalName = "SIGNAL(\(signal))"
            }

            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
            let memResult = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            let memMB = memResult == KERN_SUCCESS ? Int(info.resident_size / (1024 * 1024)) : 0

            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            let entry = "CRASH: \(signalName) at \(Date()) | Memory: \(memMB)MB | WebViews: unknown\n"
            if let data = entry.data(using: .utf8), let crashLog = docs?.appendingPathComponent("last_crash.log") {
                try? data.write(to: crashLog, options: .atomic)
            }
            let stateJSON = "{\"crashCount\":\(1),\"lastCrashSignal\":\"\(signalName)\",\"lastCrashMemoryMB\":\(memMB),\"lastCrashTimestamp\":\(Date().timeIntervalSince1970)}"
            if let stateData = stateJSON.data(using: .utf8), let stateFile = docs?.appendingPathComponent("crash_protection_state.json") {
                try? stateData.write(to: stateFile, options: .atomic)
            }
        }

        signal(SIGABRT, handler)
        signal(SIGSEGV, handler)
        signal(SIGBUS, handler)
        signal(SIGFPE, handler)
        signal(SIGILL, handler)
        signal(SIGTRAP, handler)

        NSSetUncaughtExceptionHandler { exception in
            let entry = "EXCEPTION: \(exception.name.rawValue) - \(exception.reason ?? "unknown")\nStack: \(exception.callStackSymbols.prefix(20).joined(separator: "\n"))\n"
            if let data = entry.data(using: .utf8) {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                if let crashLog = docs?.appendingPathComponent("last_crash.log") {
                    try? data.write(to: crashLog, options: .atomic)
                }
            }
        }
    }

    // MARK: - Crash Report Recovery

    func checkForPreviousCrash() -> String? {
        guard let crashLog = documentsURL("last_crash.log"),
              let data = try? Data(contentsOf: crashLog) else { return nil }
        let crashInfo = String(data: data, encoding: .utf8)

        let diagnosticLog = documentsURL("pre_crash_diagnostics.txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "No pre-crash diagnostics"
        let savedLog = documentsURL("debug_log_latest.txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

        let screenshotKeys = loadRecentScreenshotKeys()

        if let crashInfo {
            crashCount += 1
            lastCrashRecoveryTime = Date()
            let mb = currentMemoryUsageMB()
            sessionCrashLog.append((Date(), crashInfo.components(separatedBy: " ").first ?? "UNKNOWN", mb))
            persistState()

            let (signal, crashMemMB, crashTimestamp) = loadCrashState()

            let report = CrashReport(
                signal: signal, memoryMB: crashMemMB, timestamp: crashTimestamp,
                crashLog: crashInfo,
                diagnosticLog: diagnosticLog + "\n\n=== PERSISTED LOG (tail) ===\n" + String(savedLog.suffix(5000)),
                iosVersion: UIDevice.current.systemVersion,
                deviceModel: UIDevice.current.model,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                screenshotKeys: screenshotKeys
            )
            lastCrashReport = report
            do {
                let encoded = try JSONEncoder().encode(report)
                if let reportURL = documentsURL(crashReportFile) {
                    try encoded.write(to: reportURL, options: .atomic)
                }
            } catch {
                logger.log("CrashProtection: failed to persist crash report: \(error.localizedDescription)", category: .system, level: .error)
            }
        }

        try? FileManager.default.removeItem(at: crashLog)
        if let diagURL = documentsURL("pre_crash_diagnostics.txt") { try? FileManager.default.removeItem(at: diagURL) }
        return crashInfo
    }

    func loadPendingCrashReport() -> CrashReport? {
        guard let reportURL = documentsURL(crashReportFile),
              let data = try? Data(contentsOf: reportURL) else { return nil }
        return try? JSONDecoder().decode(CrashReport.self, from: data)
    }

    func clearPendingCrashReport() {
        if let reportURL = documentsURL(crashReportFile) {
            try? FileManager.default.removeItem(at: reportURL)
        }
        lastCrashReport = nil
    }

    // MARK: - Persistence Helpers

    private func documentsURL(_ filename: String) -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(filename)
    }

    private func loadRecentScreenshotKeys() -> [String] {
        let screenshotDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("ScreenshotCache", isDirectory: true)
        guard let dir = screenshotDir,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return files.filter { $0.pathExtension == "jpg" }
            .sorted { a, b in
                let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return aDate > bDate
            }
            .prefix(20)
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    private func loadCrashState() -> (String, Int, TimeInterval) {
        guard let stateURL = documentsURL(stateFile),
              let stateData = try? Data(contentsOf: stateURL),
              let json = try? JSONSerialization.jsonObject(with: stateData) as? [String: Any] else {
            return ("UNKNOWN", 0, Date().timeIntervalSince1970)
        }
        return (
            json["lastCrashSignal"] as? String ?? "UNKNOWN",
            json["lastCrashMemoryMB"] as? Int ?? 0,
            json["lastCrashTimestamp"] as? TimeInterval ?? Date().timeIntervalSince1970
        )
    }

    private func persistState() {
        guard let stateURL = documentsURL(stateFile) else { return }
        let json = "{\"crashCount\":\(crashCount),\"emergencyKills\":\(emergencyBatchKillCount),\"lastCrashTimestamp\":\(lastCrashRecoveryTime.timeIntervalSince1970)}"
        try? json.data(using: .utf8)?.write(to: stateURL, options: .atomic)
    }

    private func restoreState() {
        guard let stateURL = documentsURL(stateFile),
              let data = try? Data(contentsOf: stateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let count = json["crashCount"] as? Int { crashCount = count }
        if let kills = json["emergencyKills"] as? Int { emergencyBatchKillCount = kills }
    }

    // MARK: - Safe Boot (Crash Loop Prevention)

    private func checkAndPerformSafeBootIfNeeded() {
        let timestamps = loadLaunchTimestamps()
        let now = Date().timeIntervalSince1970
        let recentCrashes = timestamps.filter { now - $0 < safeBootWindowSeconds }

        if recentCrashes.count >= safeBootCrashThreshold {
            logger.log("CrashProtection: SAFE BOOT — \(recentCrashes.count) crashes in \(Int(safeBootWindowSeconds))s window — resetting network to DNS", category: .system, level: .critical)
            resetNetworkSettingsToSafe()
            didPerformSafeBoot = true
            clearLaunchTimestamps()
        }
    }

    private func resetNetworkSettingsToSafe() {
        Self.resetNetworkSettingsViaUserDefaults()

        let proxyService = ProxyRotationService.shared
        proxyService.setUnifiedConnectionMode(.dns)

        let deviceProxy = DeviceProxyService.shared
        deviceProxy.ipRoutingMode = .appWideUnited
        deviceProxy.localProxyEnabled = false

        logger.log("CrashProtection: network settings reset to DNS/App-Wide-United (safe mode)", category: .system, level: .critical)
    }

    static func resetNetworkSettingsViaUserDefaults() {
        let proxySettings: [String: Any] = [
            "ipRoutingMode": "App-Wide United IP",
            "interval": "Every Batch",
            "rotateOnBatch": false,
            "rotateOnFingerprint": true,
            "localProxy": false,
            "autoFailover": true,
            "healthCheckInterval": 30.0,
            "maxFailures": 3,
        ]
        UserDefaults.standard.set(proxySettings, forKey: "device_proxy_settings_v2")
        UserDefaults.standard.set("DNS", forKey: "unified_connection_mode_v1")
        let connectionModes: [String: String] = [
            "joe": "DNS",
            "ignition": "DNS",
            "ppsr": "DNS",
        ]
        UserDefaults.standard.set(connectionModes, forKey: "connection_modes_v1")
        UserDefaults.standard.synchronize()
    }

    private func recordLaunchTimestamp() {
        var timestamps = loadLaunchTimestamps()
        let now = Date().timeIntervalSince1970
        timestamps.append(now)
        timestamps = timestamps.filter { now - $0 < 120 }
        saveLaunchTimestamps(timestamps)
    }

    func clearLaunchTimestampsAfterStableLaunch() {
        clearLaunchTimestamps()
    }

    private func loadLaunchTimestamps() -> [TimeInterval] {
        guard let url = documentsURL(launchTimestampFile),
              let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [TimeInterval] else { return [] }
        return arr
    }

    private func saveLaunchTimestamps(_ timestamps: [TimeInterval]) {
        guard let url = documentsURL(launchTimestampFile),
              let data = try? JSONSerialization.data(withJSONObject: timestamps) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func clearLaunchTimestamps() {
        guard let url = documentsURL(launchTimestampFile) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
