import Foundation
import Observation
import SwiftUI
import UIKit
import WebKit

nonisolated struct BatchResult: Sendable {
    let working: Int
    let dead: Int
    let requeued: Int
    let total: Int

    var alivePercentage: Int {
        guard total > 0 else { return 0 }
        return Int(Double(working) / Double(total) * 100)
    }
}

@Observable
@MainActor
class PPSRAutomationViewModel {
    static let shared = PPSRAutomationViewModel()

    var cards: [PPSRCard] = []
    var checks: [PPSRCheck] = []
    var testEmail: String = "dev@test.ppsr.gov.au"
    var maxConcurrency: Int = 4
    var isRunning: Bool = false
    var isPaused: Bool = false
    var isStopping: Bool = false
    var pauseCountdown: Int = 0
    private var pauseCountdownTask: Task<Void, Never>?
    var globalLogs: [PPSRLogEntry] = []
    var connectionStatus: ConnectionStatus = .disconnected
    var lastDiagnostics: String = ""
    var activeTestCount: Int = 0
    var debugMode: Bool = true
    var debugScreenshots: [PPSRDebugScreenshot] = []
    var appearanceMode: AppAppearanceMode = .dark
    var useEmailRotation: Bool = true
    var stealthEnabled: Bool = true
    var retrySubmitOnFail: Bool = false
    var screenshotCropRect: CGRect = .zero
    var showBatchResultPopup: Bool = false
    var consecutiveUnusualFailures: Int = 0
    var lastBatchResult: BatchResult?
    var batchTotalCount: Int = 0
    var batchCompletedCount: Int = 0
    var batchProgress: Double {
        guard batchTotalCount > 0 else { return 0 }
        return Double(batchCompletedCount) / Double(batchTotalCount)
    }
    var testTimeout: TimeInterval = 90
    var activeGateway: TestGateway = {
        if let raw = UserDefaults.standard.string(forKey: "ppsr_active_gateway"),
           let gw = TestGateway(rawValue: raw) { return gw }
        return .ppsr
    }() {
        didSet { UserDefaults.standard.set(activeGateway.rawValue, forKey: "ppsr_active_gateway") }
    }
    var chargeAmountTier: ChargeAmountTier = {
        if let raw = UserDefaults.standard.string(forKey: "ppsr_charge_tier"),
           let tier = ChargeAmountTier(rawValue: raw) { return tier }
        return .low
    }() {
        didSet { UserDefaults.standard.set(chargeAmountTier.rawValue, forKey: "ppsr_charge_tier") }
    }
    var cardSortOption: CardSortOption = {
        if let raw = UserDefaults.standard.string(forKey: "ppsr_card_sort_option"),
           let opt = CardSortOption(rawValue: raw) { return opt }
        return .dateAdded
    }() {
        didSet { UserDefaults.standard.set(cardSortOption.rawValue, forKey: "ppsr_card_sort_option") }
    }
    var cardSortAscending: Bool = UserDefaults.standard.bool(forKey: "ppsr_card_sort_ascending") {
        didSet { UserDefaults.standard.set(cardSortAscending, forKey: "ppsr_card_sort_ascending") }
    }
    var speedMultiplier: SpeedMultiplier = {
        if let raw = UserDefaults.standard.string(forKey: "ppsr_speed_multiplier"),
           let speed = SpeedMultiplier(rawValue: raw) { return speed }
        return .normal
    }() {
        didSet { UserDefaults.standard.set(speedMultiplier.rawValue, forKey: "ppsr_speed_multiplier") }
    }

    nonisolated enum SpeedMultiplier: String, CaseIterable, Identifiable, Sendable {
        case half = "0.5×"
        case normal = "1.0×"
        case fast = "1.5×"
        case turbo = "2.0×"
        case max = "3.0×"

        var id: String { rawValue }

        var multiplier: Double {
            switch self {
            case .half: 2.0
            case .normal: 1.0
            case .fast: 0.67
            case .turbo: 0.5
            case .max: 0.33
            }
        }

        var icon: String {
            switch self {
            case .half: "tortoise.fill"
            case .normal: "figure.walk"
            case .fast: "hare.fill"
            case .turbo: "bolt.fill"
            case .max: "bolt.horizontal.fill"
            }
        }

        var blocksImages: Bool { multiplier <= 0.5 }
    }

    nonisolated enum CardSortOption: String, CaseIterable, Identifiable, Sendable {
        case dateAdded = "Date Added"
        case lastTest = "Last Test"
        case successRate = "Success Rate"
        case totalTests = "Total Tests"
        case bin = "BIN Number"
        case brand = "Brand"
        case country = "Country"
        var id: String { rawValue }
    }
    var diagnosticReport: DiagnosticReport?
    var isDiagnosticRunning: Bool = false
    private var connectionTestTask: Task<Void, Never>?
    var lastHealthCheck: (healthy: Bool, detail: String)?
    var autoHealAttempted: Bool = false
    var consecutiveConnectionFailures: Int = 0
    var fingerprintPassRate: String { FingerprintValidationService.shared.formattedPassRate }
    var fingerprintAvgScore: Double { FingerprintValidationService.shared.averageScore }
    var fingerprintHistory: [FingerprintValidationService.FingerprintScore] { FingerprintValidationService.shared.scoreHistory }
    var lastFingerprintScore: FingerprintValidationService.FingerprintScore? { FingerprintValidationService.shared.lastScore }


    nonisolated enum ConnectionStatus: String, Sendable {
        case disconnected = "Disconnected"
        case connecting = "Connecting"
        case connected = "Connected"
        case error = "Error"
    }

    var batchPresets: [BatchPreset] = []
    var schedules: [TestSchedule] = []
    var autoRetryEnabled: Bool = true
    var autoRetryMaxAttempts: Int = 3
    private var autoRetryBackoffCounts: [String: Int] = [:]
    private var batchStartTime: Date?

    private let engine = PPSRAutomationEngine()
    private let bpointEngine = BPointAutomationEngine()
    private let persistence = PPSRPersistenceService.shared
    private let notifications = PPSRNotificationService.shared
    private let emailRotation = PPSREmailRotationService.shared
    private let diagnostics = PPSRConnectionDiagnosticService.shared
    private let logger = DebugLogger.shared
    let statsService = StatsTrackingService.shared
    let exportHistory = ExportHistoryService.shared
    private let presetService = BatchPresetService.shared
    private let scheduler = TestSchedulerService.shared
    private let backgroundService = BackgroundTaskService.shared
    private var batchTask: Task<Void, Never>?
    private var settingsSaveTask: Task<Void, Never>?
    private var cardsSaveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var forceStopTask: Task<Void, Never>?
    private var autoRetryTask: Task<Void, Never>?
    private var sessionHeartbeatTimeout: TimeInterval {
        TimeoutResolver.resolveHeartbeatTimeout(max(90, testTimeout))
    }

    init() {
        engine.onScreenshot = { [weak self] screenshot in
            guard let self else { return }
            self.addScreenshot(screenshot)
        }
        engine.onConnectionFailure = { [weak self] detail in
            self?.notifications.sendConnectionFailure(detail: detail)
        }
        engine.onUnusualFailure = { [weak self] detail in
            guard let self else { return }
            self.consecutiveUnusualFailures += 1
            let retrying = self.autoRetryEnabled
            NoticesService.shared.addNotice(
                message: detail,
                source: .ppsr,
                autoRetried: retrying
            )
            self.log("Unusual failure: \(detail)\(retrying ? " — auto-retry queued" : "")", level: .warning)
        }
        engine.onLog = { [weak self] message, level in
            self?.log(message, level: level)
        }
        engine.onBlankScreenshot = { [weak self] in
            self?.log("Blank screenshot detected — card requeued for auto-retry", level: .warning)
        }
        configureBPointEngine()
        notifications.requestPermission()
        loadPersistedData()
        batchPresets = presetService.loadPresets()
        schedules = scheduler.schedules
        scheduler.onScheduleTriggered = { [weak self] schedule in
            self?.handleScheduledTest(schedule)
        }
        scheduler.startMonitoring()
    }

    private func configureBPointEngine() {
        bpointEngine.onScreenshot = { [weak self] screenshot in
            guard let self else { return }
            self.addScreenshot(screenshot)
        }
        bpointEngine.onConnectionFailure = { [weak self] detail in
            self?.notifications.sendConnectionFailure(detail: detail)
        }
        bpointEngine.onUnusualFailure = { [weak self] detail in
            guard let self else { return }
            self.consecutiveUnusualFailures += 1
            NoticesService.shared.addNotice(message: detail, source: .ppsr, autoRetried: self.autoRetryEnabled)
            self.log("BPoint unusual failure: \(detail)", level: .warning)
        }
        bpointEngine.onLog = { [weak self] message, level in
            self?.log(message, level: level)
        }
    }

    private func loadPersistedData() {
        let loaded = persistence.loadCards()
        let expiredCount = loaded.filter { $0.isExpired }.count
        cards = loaded.filter { !$0.isExpired }
        if let settings = persistence.loadSettings() {
            testEmail = settings.email
            maxConcurrency = settings.maxConcurrency
            debugMode = settings.debugMode
            if let mode = AppAppearanceMode(rawValue: settings.appearanceMode) {
                appearanceMode = mode
            }
            useEmailRotation = settings.useEmailRotation
            stealthEnabled = settings.stealthEnabled
            retrySubmitOnFail = settings.retrySubmitOnFail
            if let rect = settings.screenshotCropRect {
                screenshotCropRect = rect
            }
        }
        if expiredCount > 0 {
            log("Removed \(expiredCount) expired card(s) automatically", level: .warning)
            persistCards()
        }
        if !cards.isEmpty {
            log("Restored \(cards.count) cards from storage")
        }
        restoreTestQueueIfNeeded()
    }

    private func restoreTestQueueIfNeeded() {
        guard let queuedIds = persistence.loadTestQueue(), !queuedIds.isEmpty else { return }
        let idSet = Set(queuedIds)
        var restoredCount = 0
        for card in cards where idSet.contains(card.id) {
            if card.status == .testing {
                card.status = .untested
                restoredCount += 1
            }
        }
        persistence.clearTestQueue()
        if restoredCount > 0 {
            log("Restored \(restoredCount) interrupted test(s) back to queue", level: .warning)
            persistCards()
        }
    }

    func persistCards() {
        cardsSaveTask?.cancel()
        cardsSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            persistence.saveCards(cards)
        }
    }

    func persistCardsNow() {
        cardsSaveTask?.cancel()
        cardsSaveTask = nil
        persistence.saveCards(cards)
    }

    func persistSettings() {
        settingsSaveTask?.cancel()
        settingsSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            persistence.saveSettings(
                email: testEmail,
                maxConcurrency: maxConcurrency,
                debugMode: debugMode,
                appearanceMode: appearanceMode.rawValue,
                useEmailRotation: useEmailRotation,
                stealthEnabled: stealthEnabled,
                retrySubmitOnFail: retrySubmitOnFail,
                screenshotCropRect: screenshotCropRect
            )
        }
    }

    func syncFromiCloud() {
        if let synced = persistence.syncFromiCloud() {
            let existingIds = Set(cards.map(\.number))
            var added = 0
            for card in synced where !existingIds.contains(card.number) && !card.isExpired {
                cards.append(card)
                added += 1
            }
            if added > 0 {
                log("iCloud sync: merged \(added) new cards", level: .success)
                persistCards()
            } else {
                log("iCloud sync: no new cards found", level: .info)
            }
        }
    }

    var workingCards: [PPSRCard] { cards.filter { $0.status == .working } }
    var deadCards: [PPSRCard] { cards.filter { $0.status == .dead } }
    var untestedCards: [PPSRCard] { applySortOrder(cards.filter { $0.status == .untested }) }
    var testingCards: [PPSRCard] { cards.filter { $0.status == .testing } }

    func applySortOrder(_ input: [PPSRCard]) -> [PPSRCard] {
        var result = input
        result.sort { a, b in
            let comparison: Bool
            switch cardSortOption {
            case .dateAdded: comparison = a.addedAt > b.addedAt
            case .lastTest: comparison = (a.lastTestedAt ?? .distantPast) > (b.lastTestedAt ?? .distantPast)
            case .successRate: comparison = a.successRate > b.successRate
            case .totalTests: comparison = a.totalTests > b.totalTests
            case .bin: comparison = a.binPrefix < b.binPrefix
            case .brand: comparison = a.brand.rawValue < b.brand.rawValue
            case .country: comparison = (a.binData?.country ?? "") < (b.binData?.country ?? "")
            }
            return cardSortAscending ? !comparison : comparison
        }
        return result
    }
    var activeChecks: [PPSRCheck] { checks.filter { !$0.status.isTerminal } }
    var completedChecks: [PPSRCheck] { checks.filter { $0.status == .completed } }
    var failedChecks: [PPSRCheck] { checks.filter { $0.status == .failed } }
    var totalSuccessfulCards: Int { cards.filter { $0.status == .working }.count }

    private func resolveEmail() -> String {
        if useEmailRotation, let rotated = emailRotation.nextEmail() {
            return rotated
        }
        return testEmail
    }

    func testConnection() async {
        connectionTestTask?.cancel()
        let task = Task {
            await _testConnection()
        }
        connectionTestTask = task
        await task.value
    }

    private func _testConnection() async {
        connectionStatus = .connecting
        log("Testing connection to \(LoginWebSession.targetURL.absoluteString)...")

        let quickCheck = await diagnostics.quickHealthCheck()
        lastHealthCheck = quickCheck

        if !quickCheck.healthy {
            connectionStatus = .error
            log("Quick health check failed: \(quickCheck.detail)", level: .error)
            log("Running full diagnostics to identify the issue...", level: .warning)
            await runFullDiagnostic()

            if let report = diagnosticReport, !report.overallHealthy {
                if !autoHealAttempted {
                    autoHealAttempted = true
                    log("Attempting auto-heal...", level: .info)
                    await attemptAutoHeal(report: report)
                }
            }
            return
        }

        log("Quick health check passed: \(quickCheck.detail)", level: .success)

        let session = LoginWebSession()
        session.stealthEnabled = stealthEnabled
        session.networkConfig = NetworkSessionFactory.shared.appWideConfig(for: .ppsr)
        session.setUp()
        defer { session.tearDown() }

        let loaded = await session.loadPage(timeout: TimeoutResolver.resolvePageLoadTimeout(30))
        guard loaded else {
            connectionStatus = .error
            let errorDetail = session.lastNavigationError ?? "Unknown error"
            let httpCode = session.lastHTTPStatusCode.map { " (HTTP \($0))" } ?? ""
            log("WebView page load failed: \(errorDetail)\(httpCode)", level: .error)
            notifications.sendConnectionFailure(detail: "Page load failed: \(errorDetail)")

            log("Running full diagnostics...", level: .warning)
            await runFullDiagnostic()
            return
        }

        let pageTitle = session.webView?.title ?? "(unknown)"
        log("Page loaded: \(pageTitle)")

        let structure = await session.dumpPageStructure() ?? "(empty)"
        lastDiagnostics = structure
        log("DOM structure captured (\(structure.count) chars)")

        let fieldsVerified = await session.verifyFieldsExist()
        if fieldsVerified {
            connectionStatus = .connected
            consecutiveConnectionFailures = 0
            autoHealAttempted = false
            log("Connected — form fields verified on live PPSR page", level: .success)
        } else {
            connectionStatus = .connected
            log("Connected to page but VIN field not found — page may use dynamic rendering", level: .warning)

            let hasIframes = await session.checkForIframes()
            if hasIframes {
                log("Detected iframe(s) on page — fields may be inside iframe", level: .warning)
            }

            log("Waiting 3s for dynamic JS to render...")
            try? await Task.sleep(for: .seconds(3))
            let retryVerified = await session.verifyFieldsExist()
            if retryVerified {
                log("After wait: form fields found", level: .success)
            } else {
                log("Still no fields after wait — check page structure in diagnostics", level: .error)
            }
        }
    }

    func runFullDiagnostic() async {
        isDiagnosticRunning = true
        log("Starting full connection diagnostic...")
        let report = await diagnostics.runFullDiagnostic()
        diagnosticReport = report
        isDiagnosticRunning = false

        for step in report.steps {
            let level: PPSRLogEntry.Level
            switch step.status {
            case .passed: level = .success
            case .failed: level = .error
            case .warning: level = .warning
            default: level = .info
            }
            let latencyStr = step.latencyMs.map { " (\($0)ms)" } ?? ""
            log("[\(step.status.rawValue.uppercased())] \(step.name): \(step.detail)\(latencyStr)", level: level)
        }

        log("Recommendation: \(report.recommendation)", level: report.overallHealthy ? .info : .warning)
    }

    private func attemptAutoHeal(report: DiagnosticReport) async {
        let failedSteps = report.steps.filter { $0.status == .failed }

        for step in failedSteps {
            switch step.name {
            case "System DNS":
                log("Auto-heal: System DNS failed — enabling stealth mode for DoH resolution", level: .info)
                if !stealthEnabled {
                    stealthEnabled = true
                    persistSettings()
                    log("Auto-heal: Enabled Ultra Stealth Mode", level: .success)
                }

            case "HTTPS Reachability":
                if step.detail.contains("403") || step.detail.contains("blocked") {
                    log("Auto-heal: Server blocking detected — enabling stealth + reducing concurrency", level: .info)
                    if !stealthEnabled {
                        stealthEnabled = true
                    }
                    if maxConcurrency > 2 {
                        maxConcurrency = 2
                    }
                    persistSettings()
                    log("Auto-heal: Stealth ON, concurrency reduced to \(maxConcurrency)", level: .success)
                } else if step.detail.contains("timed out") {
                    log("Auto-heal: Connection timeout — increasing test timeout", level: .info)
                    let healCap = TimeoutResolver.resolveAutoHealCap(testTimeout)
                    if testTimeout < healCap {
                        testTimeout = healCap
                        log("Auto-heal: Test timeout increased to \(Int(healCap))s", level: .success)
                    }
                }

            case "Page Content":
                if step.detail.contains("CAPTCHA") || step.detail.contains("challenge") {
                    log("Auto-heal: CAPTCHA detected — enabling stealth + reducing concurrency to 1", level: .info)
                    stealthEnabled = true
                    maxConcurrency = 1
                    persistSettings()
                    log("Auto-heal: Stealth ON, concurrency set to 1", level: .success)
                }

            default:
                break
            }
        }

        log("Auto-heal complete — retesting connection...", level: .info)
        try? await Task.sleep(for: .seconds(2))
        await testConnection()
    }

    func addCardFromPipeFormat(_ input: String) {
        smartImportCards(input)
    }

    func smartImportCards(_ input: String) {
        let parsed = PPSRCard.smartParse(input)
        let lines = input.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if parsed.isEmpty && !lines.isEmpty {
            for line in lines {
                log("Could not parse: \(line)", level: .warning)
            }
            return
        }

        var added = 0
        var dupes = 0
        var expired = 0
        for card in parsed {
            if card.isExpired {
                expired += 1
                log("Skipped expired: \(card.brand.rawValue) \(card.number) exp \(card.formattedExpiry)", level: .warning)
                continue
            }
            let isDuplicate = cards.contains { $0.number == card.number }
            if isDuplicate {
                dupes += 1
                log("Skipped duplicate: \(card.brand.rawValue) \(card.number)", level: .warning)
            } else {
                cards.append(card)
                added += 1
                log("Added \(card.brand.rawValue) \(card.number) exp \(card.formattedExpiry)")
                Task { await card.loadBINData() }
            }
        }

        if parsed.count > 0 {
            var msg = "Smart import: \(added) card(s) added from \(lines.count) line(s)"
            if dupes > 0 { msg += ", \(dupes) duplicate(s) skipped" }
            if expired > 0 { msg += ", \(expired) expired skipped" }
            log(msg, level: .success)
        }
        persistCards()
    }

    func importFromCSV(_ csvText: String, mapping: PPSRCard.CSVColumnMapping = .auto) -> (added: Int, duplicates: Int) {
        let parsed = PPSRCard.parseCSVData(csvText, columnMapping: mapping)
        var added = 0
        var dupes = 0
        var expired = 0
        for card in parsed {
            if card.isExpired {
                expired += 1
                log("Skipped expired: \(card.brand.rawValue) \(card.number) exp \(card.formattedExpiry)", level: .warning)
                continue
            }
            if cards.contains(where: { $0.number == card.number }) {
                dupes += 1
                log("Skipped duplicate: \(card.brand.rawValue) \(card.number)", level: .warning)
            } else {
                cards.append(card)
                added += 1
                log("Added \(card.brand.rawValue) \(card.number) exp \(card.formattedExpiry)")
                Task { await card.loadBINData() }
            }
        }
        if added > 0 || dupes > 0 || expired > 0 {
            var msg = "CSV import: \(added) card(s) added"
            if dupes > 0 { msg += ", \(dupes) duplicate(s) skipped" }
            if expired > 0 { msg += ", \(expired) expired skipped" }
            log(msg, level: added > 0 ? .success : .warning)
        } else {
            log("CSV import: no valid cards found", level: .warning)
        }
        persistCards()
        return (added, dupes)
    }

    func deleteCard(_ card: PPSRCard) {
        cards.removeAll { $0.id == card.id }
        log("Removed \(card.brand.rawValue) card: \(card.number)")
        persistCards()
    }

    func deleteCards(withIds ids: Set<String>) {
        let count = ids.count
        cards.removeAll { ids.contains($0.id) }
        log("Removed \(count) selected card(s)")
        persistCards()
    }

    func restoreCard(_ card: PPSRCard) {
        card.status = .untested
        log("Restored \(card.brand.rawValue) \(card.number) to untested")
        persistCards()
    }

    func purgeDeadCards() {
        let count = deadCards.count
        cards.removeAll { $0.status == .dead }
        log("Purged \(count) dead card(s)")
        persistCards()
    }

    private let maxInMemoryScreenshots: Int = 200

    func addScreenshot(_ screenshot: PPSRDebugScreenshot) {
        if isRunning && CrashProtectionService.shared.isMemoryCritical {
            ScreenshotCacheService.shared.store(screenshot.image, forKey: screenshot.id)
            return
        }
        debugScreenshots.insert(screenshot, at: 0)
        let effectiveLimit = isRunning ? min(15, maxInMemoryScreenshots) : maxInMemoryScreenshots
        if debugScreenshots.count > effectiveLimit {
            let overflow = Array(debugScreenshots.suffix(from: effectiveLimit))
            for ss in overflow {
                ScreenshotCacheService.shared.store(ss.image, forKey: ss.id)
            }
            debugScreenshots.removeLast(debugScreenshots.count - effectiveLimit)
        }
    }

    func clearDebugScreenshots() {
        let count = debugScreenshots.count
        debugScreenshots.removeAll()
        log("Cleared \(count) debug screenshots")
    }

    func handleMemoryPressure() {
        let before = debugScreenshots.count
        let keep = min(50, maxInMemoryScreenshots / 4)
        if debugScreenshots.count > keep {
            let overflow = Array(debugScreenshots.suffix(from: keep))
            for ss in overflow {
                ScreenshotCacheService.shared.store(ss.image, forKey: ss.id)
            }
            debugScreenshots.removeLast(debugScreenshots.count - keep)
            log("Memory pressure: flushed \(before - keep) screenshots to disk cache", level: .warning)
        }
        if globalLogs.count > 200 {
            globalLogs = Array(globalLogs.prefix(200))
        }
    }

    func correctResult(for screenshot: PPSRDebugScreenshot, override: UserResultOverride) {
        screenshot.userOverride = override

        guard let card = cards.first(where: { $0.id == screenshot.cardId }) else {
            log("Correction: could not find card \(screenshot.cardDisplayNumber)", level: .warning)
            return
        }

        let isPass = override == .success
        card.applyCorrection(success: isPass)

        log("Debug correction: \(card.brand.rawValue) \(card.number) marked as \(override.displayLabel) by user", level: isPass ? .success : .warning)
        persistCards()
    }

    func resetScreenshotOverride(_ screenshot: PPSRDebugScreenshot) {
        screenshot.userOverride = .none
        log("Reset override for screenshot at \(screenshot.formattedTime)")
    }

    func requeueCardFromScreenshot(_ screenshot: PPSRDebugScreenshot) {
        guard let card = cards.first(where: { $0.id == screenshot.cardId }) else {
            log("Requeue: could not find card \(screenshot.cardDisplayNumber)", level: .warning)
            return
        }
        card.status = .untested
        log("Requeued \(card.brand.rawValue) \(card.number) for retesting", level: .info)
        persistCards()
    }

    func stopAfterCurrent() {
        cancelPauseCountdown()
        isStopping = true
        isPaused = false
        pauseCountdown = 0
        log("Stopping after current batch due to unusual failures...", level: .warning)
        startForceStopTimer()
    }

    private func startForceStopTimer() {
        forceStopTask?.cancel()
        let forceStopTimeout = TimeoutResolver.resolveAutomationTimeout(20)
        forceStopTask = Task {
            try? await Task.sleep(for: .seconds(forceStopTimeout))
            guard !Task.isCancelled else { return }
            guard isRunning || isStopping else { return }
            log("Force-stop: batch did not finish within \(Int(forceStopTimeout))s — force cancelling", level: .error)
            logger.log("Force-stop triggered — cancelling hung PPSR batch task", category: .ppsr, level: .error)
            batchTask?.cancel()
            forceFinalizeBatch()
        }
    }

    private func forceFinalizeBatch() {
        cancelPauseCountdown()
        stopHeartbeatMonitor()
        forceStopTask?.cancel()
        forceStopTask = nil
        persistence.clearTestQueue()
        isRunning = false
        isPaused = false
        isStopping = false
        pauseCountdown = 0
        activeTestCount = 0
        batchTask = nil
        resetStuckTestingCards()
        syncActiveTestCount()
        trimChecksIfNeeded()
        backgroundService.endExtendedBackgroundExecution()
        log("Force-stop complete — all state reset", level: .warning)
        persistCards()
    }

    func emergencyStop() {
        logger.log("PPSRAutomationViewModel: EMERGENCY STOP triggered by crash protection", category: .system, level: .critical)
        autoRetryTask?.cancel()
        autoRetryTask = nil
        batchTask?.cancel()
        batchTask = nil
        forceFinalizeBatch()
        DeadSessionDetector.shared.stopAllWatchdogs()
        SessionActivityMonitor.shared.stopAll()
        WebViewTracker.shared.reset()
    }

    private func syncActiveTestCount() {
        let actualActive = checks.filter({ !$0.status.isTerminal }).count
        if activeTestCount != actualActive {
            log("activeTestCount sync: \(activeTestCount) → \(actualActive)", level: .warning)
            activeTestCount = actualActive
        }
    }

    func testSingleCard(_ card: PPSRCard) {
        guard !isRunning || activeTestCount < maxConcurrency else {
            log("Max concurrency reached", level: .warning)
            return
        }

        switch activeGateway {
        case .ppsr:
            testSingleCardViaPPSR(card)
        case .bpoint:
            testSingleCardViaBPoint(card)
        }
    }

    private func testSingleCardViaPPSR(_ card: PPSRCard) {
        let vin = PPSRVINGenerator.generate()
        let email = resolveEmail()
        card.status = .testing

        let check = PPSRCheck(vin: vin, email: email, card: card, sessionIndex: activeTestCount + 1)
        checks.insert(check, at: 0)

        Task {
            configureEngine()

            let preCheck = await engine.runPreTestNetworkCheck()
            if !preCheck.passed {
                log("Pre-test failed: \(preCheck.detail) — skipping", level: .error)
                card.status = .untested
                check.status = .failed
                check.errorMessage = preCheck.detail
                check.completedAt = Date()
                persistCards()
                return
            }
            log("Pre-test passed: \(preCheck.detail)", level: .success)

            isRunning = true
            activeTestCount += 1
            let outcome = await engine.runCheck(check, timeout: testTimeout)
            activeTestCount -= 1
            handleOutcome(outcome, card: card, check: check, vin: vin)
            if activeTestCount == 0 { isRunning = false }
            persistCards()
        }
    }

    private func testSingleCardViaBPoint(_ card: PPSRCard) {
        let amount = chargeAmountTier.randomizedAmount()
        card.status = .testing

        let check = PPSRCheck(vin: "BPOINT", email: "n/a", card: card, sessionIndex: activeTestCount + 1)
        checks.insert(check, at: 0)

        Task {
            configureBPointEngineSettings()

            let preCheck = await bpointEngine.runPreTestNetworkCheck()
            if !preCheck.passed {
                log("BPoint pre-test failed: \(preCheck.detail)", level: .error)
                card.status = .untested
                check.status = .failed
                check.errorMessage = preCheck.detail
                check.completedAt = Date()
                persistCards()
                return
            }
            log("BPoint pre-test passed — charging $\(String(format: "%.2f", amount))", level: .success)

            isRunning = true
            activeTestCount += 1
            let outcome = await bpointEngine.runCheck(check, chargeAmount: amount, timeout: testTimeout, skipPreTest: true)
            activeTestCount -= 1
            handleOutcome(outcome, card: card, check: check, vin: "BPOINT_$\(String(format: "%.2f", amount))")
            if activeTestCount == 0 { isRunning = false }
            persistCards()
        }
    }

    private func configureBPointEngineSettings() {
        bpointEngine.debugMode = debugMode
        bpointEngine.stealthEnabled = stealthEnabled
        bpointEngine.screenshotCropRect = screenshotCropRect
        bpointEngine.speedMultiplier = speedMultiplier.multiplier
    }

    private func configureEngine() {
        engine.debugMode = debugMode
        engine.stealthEnabled = stealthEnabled
        engine.retrySubmitOnFail = retrySubmitOnFail
        engine.screenshotCropRect = screenshotCropRect
        engine.speedMultiplier = speedMultiplier.multiplier
    }

    private func handleOutcome(_ outcome: CheckOutcome, card: PPSRCard, check: PPSRCheck, vin: String) {
        let duration = check.duration ?? 0

        switch outcome {
        case .pass:
            card.recordResult(success: true, vin: vin, duration: duration, error: nil)
            log("\(card.brand.rawValue) \(card.number) — PASSED (\(check.formattedDuration))", level: .success)
            consecutiveUnusualFailures = 0

        case .failInstitution:
            card.recordResult(success: false, vin: vin, duration: duration, error: check.errorMessage)
            log("\(card.brand.rawValue) \(card.number) — FAILED: institution detected", level: .error)
            consecutiveUnusualFailures = 0

        case .uncertain, .timeout, .connectionFailure:
            card.status = .untested
            let reason: String
            switch outcome {
            case .timeout: reason = "timeout"
            case .connectionFailure:
                reason = "connection failure"
                consecutiveConnectionFailures += 1
                if consecutiveConnectionFailures >= 3 {
                    log("3+ consecutive connection failures — auto-running diagnostics", level: .error)
                    Task { await runFullDiagnostic() }
                }
            default: reason = "uncertain result"
            }
            log("\(card.brand.rawValue) \(card.number) — requeued (\(reason))", level: .warning)
        }
    }

    func testAllUntested() {
        switch activeGateway {
        case .ppsr: testAllUntestedViaPPSR()
        case .bpoint: testAllUntestedViaBPoint()
        }
    }

    private func testAllUntestedViaPPSR() {
        let cardsToTest = untestedCards
        guard !cardsToTest.isEmpty else {
            log("No untested cards in queue", level: .warning)
            return
        }

        batchTask?.cancel()
        isPaused = false
        isStopping = false
        batchStartTime = Date()
        batchTotalCount = cardsToTest.count
        batchCompletedCount = 0
        autoRetryBackoffCounts.removeAll()
        log("Starting PPSR batch: \(cardsToTest.count) cards, max \(maxConcurrency) concurrent, stealth: \(stealthEnabled ? "ON" : "OFF")")
        logger.log("PPSR BATCH START: \(cardsToTest.count) cards, concurrency=\(maxConcurrency), stealth=\(stealthEnabled)", category: .ppsr, level: .info, metadata: ["count": "\(cardsToTest.count)"])
        isRunning = true
        startHeartbeatMonitor()
        DeviceProxyService.shared.notifyBatchStart()
        backgroundService.beginExtendedBackgroundExecution(reason: "PPSR batch test")
        persistence.saveTestQueue(cardIds: cardsToTest.map(\.id))

        var batchWorking = 0
        var batchDead = 0
        var batchRequeued = 0

        batchTask = Task {
            configureEngine()
            await withTaskGroup(of: Void.self) { group in
                var running = 0

                for card in cardsToTest {
                    guard !Task.isCancelled && !isStopping else { break }

                    if CrashProtectionService.shared.isMemoryEmergency {
                        self.log("Memory EMERGENCY during batch — auto-stopping to prevent crash", level: .error)
                        self.isStopping = true
                        break
                    }

                    if !CrashProtectionService.shared.isMemorySafeForNewSession {
                        self.log("Memory pressure — waiting before spawning next session", level: .warning)
                        let recovered = await CrashProtectionService.shared.waitForMemoryToDrop(timeout: 15)
                        if !recovered || Task.isCancelled {
                            self.isStopping = true
                            break
                        }
                    }

                    while isPaused && !isStopping && !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(500))
                    }

                    guard !Task.isCancelled && !isStopping else { break }

                    if running >= maxConcurrency {
                        await group.next()
                        running -= 1
                    }

                    running += 1
                    let vin = PPSRVINGenerator.generate()
                    let email = resolveEmail()
                    card.status = .testing
                    let sessionIdx = running

                    let check = PPSRCheck(vin: vin, email: email, card: card, sessionIndex: sessionIdx)
                    checks.insert(check, at: 0)
                    activeTestCount += 1
                    trimChecksIfNeeded()

                    group.addTask { [engine, testTimeout] in
                        defer {
                            Task { @MainActor in
                                self.activeTestCount = max(0, self.activeTestCount - 1)
                            }
                        }
                        let outcome = await engine.runCheck(check, timeout: testTimeout)
                        await MainActor.run {
                            self.batchCompletedCount += 1
                            self.handleOutcome(outcome, card: card, check: check, vin: vin)

                            switch outcome {
                            case .pass: batchWorking += 1
                            case .failInstitution: batchDead += 1
                            case .uncertain, .timeout, .connectionFailure: batchRequeued += 1
                            }

                            self.persistCards()
                        }
                    }
                }

                await group.waitForAll()
            }

            syncActiveTestCount()
            finalizePPSRBatch(working: batchWorking, dead: batchDead, requeued: batchRequeued)
        }
    }

    private func testAllUntestedViaBPoint() {
        let cardsToTest = untestedCards
        guard !cardsToTest.isEmpty else {
            log("No untested cards in queue", level: .warning)
            return
        }

        batchTask?.cancel()
        isPaused = false
        isStopping = false
        batchStartTime = Date()
        batchTotalCount = cardsToTest.count
        batchCompletedCount = 0
        autoRetryBackoffCounts.removeAll()
        let tierDisplay = chargeAmountTier.displayRange
        log("Starting BPoint batch: \(cardsToTest.count) cards, \(tierDisplay) charge, max \(maxConcurrency) concurrent")
        logger.log("BPOINT BATCH START: \(cardsToTest.count) cards, tier=\(chargeAmountTier.rawValue), concurrency=\(maxConcurrency)", category: .ppsr, level: .info, metadata: ["count": "\(cardsToTest.count)", "tier": chargeAmountTier.rawValue])
        isRunning = true
        startHeartbeatMonitor()
        DeviceProxyService.shared.notifyBatchStart()
        backgroundService.beginExtendedBackgroundExecution(reason: "BPoint batch test")
        persistence.saveTestQueue(cardIds: cardsToTest.map(\.id))

        var batchWorking = 0
        var batchDead = 0
        var batchRequeued = 0

        batchTask = Task {
            configureBPointEngineSettings()
            await withTaskGroup(of: Void.self) { group in
                var running = 0

                for card in cardsToTest {
                    guard !Task.isCancelled && !isStopping else { break }

                    if CrashProtectionService.shared.isMemoryEmergency {
                        self.log("Memory EMERGENCY during BPoint batch — auto-stopping to prevent crash", level: .error)
                        self.isStopping = true
                        break
                    }

                    if !CrashProtectionService.shared.isMemorySafeForNewSession {
                        self.log("Memory pressure — waiting before spawning next BPoint session", level: .warning)
                        let recovered = await CrashProtectionService.shared.waitForMemoryToDrop(timeout: 15)
                        if !recovered || Task.isCancelled {
                            self.isStopping = true
                            break
                        }
                    }

                    while isPaused && !isStopping && !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    guard !Task.isCancelled && !isStopping else { break }
                    if running >= maxConcurrency {
                        await group.next()
                        running -= 1
                    }

                    running += 1
                    let amount = chargeAmountTier.randomizedAmount()
                    card.status = .testing
                    let sessionIdx = running

                    let check = PPSRCheck(vin: "BPOINT", email: "n/a", card: card, sessionIndex: sessionIdx)
                    checks.insert(check, at: 0)
                    activeTestCount += 1
                    trimChecksIfNeeded()

                    let capturedAmount = amount
                    group.addTask { [bpointEngine, testTimeout] in
                        defer {
                            Task { @MainActor in
                                self.activeTestCount = max(0, self.activeTestCount - 1)
                            }
                        }
                        let outcome = await bpointEngine.runCheck(check, chargeAmount: capturedAmount, timeout: testTimeout)
                        await MainActor.run {
                            self.batchCompletedCount += 1
                            self.handleOutcome(outcome, card: card, check: check, vin: "BPOINT_$\(String(format: "%.2f", capturedAmount))")

                            switch outcome {
                            case .pass: batchWorking += 1
                            case .failInstitution: batchDead += 1
                            case .uncertain, .timeout, .connectionFailure: batchRequeued += 1
                            }

                            self.persistCards()
                        }
                    }
                }

                await group.waitForAll()
            }

            syncActiveTestCount()
            finalizePPSRBatch(working: batchWorking, dead: batchDead, requeued: batchRequeued)
        }
    }

    func pauseQueue() {
        isPaused = true
        pauseCountdown = 60
        log("Queue paused for 60 seconds — all sessions frozen, auto-resume in 60s", level: .warning)
        startPauseCountdown()
    }

    func resumeQueue() {
        cancelPauseCountdown()
        isPaused = false
        pauseCountdown = 0
        log("Queue resumed", level: .info)
    }

    func stopQueue() {
        autoRetryTask?.cancel()
        autoRetryTask = nil
        cancelPauseCountdown()
        isStopping = true
        isPaused = false
        pauseCountdown = 0
        log("Stopping queue — current batch sessions completing, no new batches will be added", level: .warning)
        startForceStopTimer()
    }

    private func startPauseCountdown() {
        pauseCountdownTask?.cancel()
        pauseCountdownTask = Task {
            for tick in stride(from: 59, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if !isPaused { return }
                pauseCountdown = tick
            }
            guard !Task.isCancelled, isPaused else { return }
            isPaused = false
            pauseCountdown = 0
            log("Pause timer expired — queue auto-resumed", level: .info)
        }
    }

    private func cancelPauseCountdown() {
        pauseCountdownTask?.cancel()
        pauseCountdownTask = nil
    }

    func testSelectedCards(_ selectedCards: [PPSRCard]) {
        let cardsToTest = applySortOrder(selectedCards.filter { $0.status == .untested || $0.status == .dead })
        guard !cardsToTest.isEmpty else {
            log("No eligible cards in selection", level: .warning)
            return
        }

        for card in cardsToTest {
            card.status = .untested
        }

        isPaused = false
        isStopping = false
        batchStartTime = Date()
        batchTotalCount = cardsToTest.count
        batchCompletedCount = 0
        let gatewayLabel = activeGateway.displayName
        log("Starting \(gatewayLabel) selected test: \(cardsToTest.count) cards, max \(maxConcurrency) concurrent")
        isRunning = true
        startHeartbeatMonitor()
        backgroundService.beginExtendedBackgroundExecution(reason: "\(gatewayLabel) selected card test")
        persistence.saveTestQueue(cardIds: cardsToTest.map(\.id))

        var batchWorking = 0
        var batchDead = 0
        var batchRequeued = 0
        let gateway = activeGateway
        let tier = chargeAmountTier

        batchTask = Task {
            if gateway == .bpoint {
                configureBPointEngineSettings()
            } else {
                configureEngine()
            }
            await withTaskGroup(of: Void.self) { group in
                var running = 0

                for card in cardsToTest {
                    guard !Task.isCancelled && !isStopping else { break }

                    if CrashProtectionService.shared.isMemoryEmergency {
                        self.log("Memory EMERGENCY during selected batch — auto-stopping to prevent crash", level: .error)
                        self.isStopping = true
                        break
                    }

                    if !CrashProtectionService.shared.isMemorySafeForNewSession {
                        self.log("Memory pressure — waiting before spawning next session", level: .warning)
                        let recovered = await CrashProtectionService.shared.waitForMemoryToDrop(timeout: 15)
                        if !recovered || Task.isCancelled {
                            self.isStopping = true
                            break
                        }
                    }

                    while isPaused && !isStopping && !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    guard !Task.isCancelled && !isStopping else { break }
                    if running >= maxConcurrency {
                        await group.next()
                        running -= 1
                    }

                    running += 1
                    card.status = .testing
                    let sessionIdx = running

                    if gateway == .bpoint {
                        let amount = tier.randomizedAmount()
                        let check = PPSRCheck(vin: "BPOINT", email: "n/a", card: card, sessionIndex: sessionIdx)
                        checks.insert(check, at: 0)
                        activeTestCount += 1
                        trimChecksIfNeeded()

                        let capturedAmount = amount
                        group.addTask { [bpointEngine, testTimeout] in
                            defer {
                                Task { @MainActor in
                                    self.activeTestCount = max(0, self.activeTestCount - 1)
                                }
                            }
                            let outcome = await bpointEngine.runCheck(check, chargeAmount: capturedAmount, timeout: testTimeout)
                            await MainActor.run {
                                self.batchCompletedCount += 1
                                self.handleOutcome(outcome, card: card, check: check, vin: "BPOINT_$\(String(format: "%.2f", capturedAmount))")
                                switch outcome {
                                case .pass: batchWorking += 1
                                case .failInstitution: batchDead += 1
                                case .uncertain, .timeout, .connectionFailure: batchRequeued += 1
                                }
                                self.persistCards()
                            }
                        }
                    } else {
                        let vin = PPSRVINGenerator.generate()
                        let email = resolveEmail()
                        let check = PPSRCheck(vin: vin, email: email, card: card, sessionIndex: sessionIdx)
                        checks.insert(check, at: 0)
                        activeTestCount += 1
                        trimChecksIfNeeded()

                        group.addTask { [engine, testTimeout] in
                            defer {
                                Task { @MainActor in
                                    self.activeTestCount = max(0, self.activeTestCount - 1)
                                }
                            }
                            let outcome = await engine.runCheck(check, timeout: testTimeout)
                            await MainActor.run {
                                self.batchCompletedCount += 1
                                self.handleOutcome(outcome, card: card, check: check, vin: vin)
                                switch outcome {
                                case .pass: batchWorking += 1
                                case .failInstitution: batchDead += 1
                                case .uncertain, .timeout, .connectionFailure: batchRequeued += 1
                                }
                                self.persistCards()
                            }
                        }
                    }
                }
                await group.waitForAll()
            }

            syncActiveTestCount()
            finalizePPSRBatch(working: batchWorking, dead: batchDead, requeued: batchRequeued)
        }
    }

    private func finalizePPSRBatch(working: Int, dead: Int, requeued: Int) {
        let result = BatchResult(working: working, dead: dead, requeued: requeued, total: working + dead + requeued)
        lastBatchResult = result
        cancelPauseCountdown()
        stopHeartbeatMonitor()
        forceStopTask?.cancel()
        forceStopTask = nil
        persistence.clearTestQueue()
        isRunning = false
        isPaused = false
        pauseCountdown = 0
        activeTestCount = 0

        let stoppedEarly = isStopping
        isStopping = false

        resetStuckTestingCards()
        syncActiveTestCount()
        trimChecksIfNeeded()
        backgroundService.endExtendedBackgroundExecution()

        let batchDuration = batchStartTime.map { Date().timeIntervalSince($0) } ?? 0
        Task { await self.statsService.recordBatchResult(working: working, dead: dead, requeued: requeued, duration: batchDuration) }
        batchStartTime = nil

        if stoppedEarly {
            log("Batch stopped: \(working) working, \(dead) dead, \(requeued) requeued", level: .warning)
        } else {
            log("Batch complete: \(working) working, \(dead) dead, \(requeued) requeued", level: .success)
        }

        if autoRetryEnabled && requeued > 0 {
            let retryCards = cards.filter { card in
                card.status == .untested && (autoRetryBackoffCounts[card.id] ?? 0) < autoRetryMaxAttempts
            }
            if !retryCards.isEmpty {
                let retryCount = retryCards.count
                for card in retryCards {
                    autoRetryBackoffCounts[card.id, default: 0] += 1
                }
                let backoffDelay = Double(autoRetryBackoffCounts.values.max() ?? 1) * 5.0
                log("Auto-retry: \(retryCount) card(s) scheduled for retry in \(Int(backoffDelay))s", level: .info)
                autoRetryTask?.cancel()
                autoRetryTask = Task {
                    try? await Task.sleep(for: .seconds(backoffDelay))
                    guard !Task.isCancelled, !self.isRunning else { return }
                    self.testSelectedCards(retryCards)
                }
            }
        }

        showBatchResultPopup = true
        notifications.sendBatchComplete(working: working, dead: dead, requeued: requeued)
        persistCards()
    }

    private func resetStuckTestingCards() {
        var resetCount = 0
        for card in cards where card.status == .testing {
            card.status = .untested
            resetCount += 1
        }
        if resetCount > 0 {
            log("Reset \(resetCount) stuck testing card(s) back to untested", level: .warning)
        }
    }

    private func startHeartbeatMonitor() {
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            while !Task.isCancelled && isRunning {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, isRunning else { break }
                let now = Date()
                var stuckCount = 0
                for check in checks where !check.status.isTerminal {
                    guard let started = check.startedAt else { continue }
                    let elapsed = now.timeIntervalSince(started)
                    if elapsed > sessionHeartbeatTimeout && check.status != .queued {
                        check.status = .failed
                        check.errorMessage = "Session stuck for \(Int(elapsed))s — force terminated by heartbeat"
                        check.completedAt = now
                        if let card = cards.first(where: { $0.id == check.card.id }), card.status == .testing {
                            card.status = .untested
                            stuckCount += 1
                        }
                    }
                }
                syncActiveTestCount()
                if stuckCount > 0 {
                    log("Heartbeat: force-terminated \(stuckCount) stuck session(s) (>\(Int(sessionHeartbeatTimeout))s)", level: .warning)
                    logger.log("Heartbeat terminated \(stuckCount) stuck sessions", category: .ppsr, level: .warning)
                    persistCards()
                }
            }
        }
    }

    private func stopHeartbeatMonitor() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    func retestCard(_ card: PPSRCard) {
        card.status = .untested
        testSingleCard(card)
    }

    func clearHistory() {
        checks.removeAll(where: { $0.status.isTerminal })
        log("Cleared completed checks")
    }

    func clearAll() {
        checks.removeAll()
        globalLogs.removeAll()
    }

    func exportWorkingCards() -> String {
        let text = workingCards.map(\.pipeFormat).joined(separator: "\n")
        exportHistory.recordExport(format: "pipe", cardCount: workingCards.count, exportType: "working")
        return text
    }

    func importEmails(_ text: String) -> Int {
        let count = emailRotation.importFromCSV(text)
        log("Imported \(count) emails for rotation", level: .success)
        return count
    }

    func clearRotationEmails() {
        emailRotation.clear()
        log("Cleared email rotation list")
    }

    func resetRotationEmailsToDefault() {
        emailRotation.resetToDefault()
        log("Reset email list to default (\(emailRotation.count) emails)", level: .success)
    }

    var rotationEmailCount: Int { emailRotation.count }
    var rotationEmails: [String] { emailRotation.emails }

    func screenshotsForCard(_ cardId: String) -> [PPSRDebugScreenshot] {
        debugScreenshots.filter { $0.cardId == cardId }
    }

    func screenshotsForCheck(_ check: PPSRCheck) -> [PPSRDebugScreenshot] {
        let ids = Set(check.screenshotIds)
        return debugScreenshots.filter { ids.contains($0.id) }
    }

    private var pendingLogs: [PPSRLogEntry] = []
    private var logFlushTask: Task<Void, Never>?

    func log(_ message: String, level: PPSRLogEntry.Level = .info) {
        pendingLogs.append(PPSRLogEntry(message: message, level: level))
        if level == .error || pendingLogs.count >= 10 {
            flushLogs()
        } else {
            scheduleLogFlush()
        }
        let debugLevel: DebugLogLevel
        switch level {
        case .info: debugLevel = .info
        case .success: debugLevel = .success
        case .warning: debugLevel = .warning
        case .error: debugLevel = .error
        }
        logger.log(message, category: .ppsr, level: debugLevel)
    }

    private func scheduleLogFlush() {
        guard logFlushTask == nil else { return }
        logFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.flushLogs()
        }
    }

    private func flushLogs() {
        logFlushTask = nil
        guard !pendingLogs.isEmpty else { return }
        let batch = pendingLogs
        pendingLogs.removeAll()
        globalLogs.insert(contentsOf: batch.reversed(), at: 0)
        let cap = isRunning ? 800 : 1500
        if globalLogs.count > cap {
            globalLogs.removeLast(globalLogs.count - cap)
        }
    }

    private let maxCheckHistory: Int = 500
    private let maxChecksInBatch: Int = 500

    func trimChecksIfNeeded() {
        let hardCap = isRunning ? maxChecksInBatch : maxCheckHistory
        if checks.count > hardCap {
            let terminal = checks.enumerated().filter { $0.element.status.isTerminal }
            if terminal.count > hardCap / 2 {
                let toRemove = terminal.suffix(terminal.count - hardCap / 2)
                let removeIds = Set(toRemove.map { $0.element.id })
                checks.removeAll { removeIds.contains($0.id) }
            }
        }
        let terminal = checks.filter { $0.status.isTerminal }
        if terminal.count > maxCheckHistory {
            let excess = terminal.count - maxCheckHistory
            let oldestTerminalIds = Set(terminal.suffix(excess).map(\.id))
            checks.removeAll { oldestTerminalIds.contains($0.id) }
        }
    }

    func applyPreset(_ preset: BatchPreset) {
        maxConcurrency = preset.maxConcurrency
        stealthEnabled = preset.stealthEnabled
        useEmailRotation = preset.useEmailRotation
        retrySubmitOnFail = preset.retrySubmitOnFail
        testTimeout = TimeoutResolver.resolveAutomationTimeout(preset.testTimeout)
        persistSettings()
        log("Applied preset: \(preset.name)", level: .success)
    }

    func saveCurrentAsPreset(name: String) {
        let preset = BatchPreset(
            name: name,
            maxConcurrency: maxConcurrency,
            stealthEnabled: stealthEnabled,
            useEmailRotation: useEmailRotation,
            retrySubmitOnFail: retrySubmitOnFail,
            testTimeout: TimeoutResolver.resolveAutomationTimeout(testTimeout)
        )
        batchPresets.append(preset)
        presetService.savePresets(batchPresets)
        log("Saved preset: \(name)", level: .success)
    }

    func deletePreset(_ preset: BatchPreset) {
        batchPresets.removeAll { $0.id == preset.id }
        presetService.savePresets(batchPresets)
    }

    func scheduleTest(at date: Date, filter: TestSchedule.CardFilter) {
        let schedule = TestSchedule(scheduledDate: date, cardFilter: filter)
        scheduler.addSchedule(schedule)
        schedules = scheduler.schedules
        log("Scheduled test for \(DateFormatters.mediumDateTime.string(from: date))", level: .success)
    }

    func cancelSchedule(_ schedule: TestSchedule) {
        scheduler.removeSchedule(schedule)
        schedules = scheduler.schedules
        log("Cancelled scheduled test")
    }

    private func handleScheduledTest(_ schedule: TestSchedule) {
        guard !isRunning else {
            log("Scheduled test skipped — batch already running", level: .warning)
            return
        }
        switch schedule.cardFilter {
        case .allUntested:
            testAllUntested()
        case .deadOnly:
            let deadToRetest = deadCards
            for card in deadToRetest { card.status = .untested }
            persistCards()
            if !deadToRetest.isEmpty { testSelectedCards(deadToRetest) }
        case .allNonWorking:
            let nonWorking = cards.filter { $0.status != .working && $0.status != .testing }
            for card in nonWorking { card.status = .untested }
            persistCards()
            if !nonWorking.isEmpty { testSelectedCards(nonWorking) }
        }
        schedules = scheduler.schedules
        log("Scheduled test triggered: \(schedule.cardFilter.rawValue)", level: .info)
    }

    func copyCardToClipboard(_ card: PPSRCard) {
        UIPasteboard.general.string = card.pipeFormat
    }
}
