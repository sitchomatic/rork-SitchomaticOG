import Foundation

nonisolated struct AutomationTemplate: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var description: String
    var icon: String
    var color: String
    var isBuiltIn: Bool = false
    var createdAt: Date = Date()
    var settings: AutomationSettings

    static let builtInTemplates: [AutomationTemplate] = [
        trueDetectionProtocol,
        visionMLHunter,
        coordinateSniper,
        stealthGhost,
        speedDemon,
        resilientTank,
    ]

    static let trueDetectionProtocol = AutomationTemplate(
        name: "TRUE DETECTION",
        description: "Hardcoded Interaction Protocol: Triple-Wait → #email → #login-password → Triple-Click #login-submit. Success = balance/wallet/my account/logout. No DOM guessing.",
        icon: "shield.checkered",
        color: "blue",
        isBuiltIn: true,
        settings: {
            var s = AutomationSettings()
            s.trueDetectionEnabled = true
            s.trueDetectionPriority = true
            s.trueDetectionHardPauseMs = 4000
            s.trueDetectionTripleClickCount = 3
            s.trueDetectionTripleClickDelayMs = 1100
            s.trueDetectionSubmitCycleCount = 4
            s.trueDetectionButtonRecoveryTimeoutMs = 12000
            s.trueDetectionMaxAttempts = 4
            s.trueDetectionPostClickWaitMs = 2500
            s.trueDetectionCooldownMinutes = 15
            s.trueDetectionNoProxyRotation = true
            s.trueDetectionStrictWaits = true
            s.loginButtonDetectionMode = .trueDetection
            s.loginButtonClickMethod = .dispatchEvent
            s.fallbackToLegacyFill = true
            s.fallbackToOCRClick = true
            s.fallbackToVisionMLClick = true
            s.fallbackToCoordinateClick = true
            s.stealthJSInjection = true
            s.fingerprintSpoofing = true
            s.humanMouseMovement = false
            s.patternPriorityOrder = [
                "TRUE DETECTION",
                "Calibrated Typing",
                "Calibrated Direct",
                "Tab Navigation",
                "React Native Setter",
                "Form Submit Direct",
                "Coordinate Click",
                "Vision ML Coordinate",
                "Click-Focus Sequential",
                "ExecCommand Insert",
                "Slow Deliberate Typer",
                "Mobile Touch Burst",
            ]
            return s
        }()
    )

    static let visionMLHunter = AutomationTemplate(
        name: "Vision ML Hunter",
        description: "Pure pixel-based automation using Vision OCR and ML element detection. Zero DOM dependency — survives any site redesign.",
        icon: "eye.trianglebadge.exclamationmark",
        color: "purple",
        isBuiltIn: true,
        settings: {
            var s = AutomationSettings()
            s.loginButtonDetectionMode = .visionML
            s.loginButtonClickMethod = .dispatchEvent
            s.fallbackToVisionMLClick = true
            s.fallbackToOCRClick = true
            s.fallbackToCoordinateClick = true
            s.fallbackToLegacyFill = false
            s.loginButtonVisionMLFallback = true
            s.loginButtonOCRFallback = true
            s.loginButtonCoordinateFallback = true
            s.loginButtonAriaLabelMatch = false
            s.loginButtonRoleMatch = false
            s.loginButtonShadowDOMSearch = false
            s.loginButtonIframeSearch = false
            s.autoCalibrationEnabled = false
            s.visionMLCalibrationFallback = true
            s.fieldVerificationEnabled = true
            s.screenshotOnEveryEval = true
            s.stealthJSInjection = true
            s.fingerprintSpoofing = true
            s.humanMouseMovement = true
            s.typingJitterEnabled = true
            s.gaussianTimingDistribution = true
            s.pageStabilizationDelayMs = 1200
            s.patternPriorityOrder = [
                "TRUE DETECTION",
                "Vision ML Coordinate",
                "Coordinate Click",
                "Mobile Touch Burst",
                "Calibrated Direct",
                "Calibrated Typing",
                "Tab Navigation",
                "Click-Focus Sequential",
                "ExecCommand Insert",
                "Slow Deliberate Typer",
                "Form Submit Direct",
                "React Native Setter",
            ]
            return s
        }()
    )

    static let coordinateSniper = AutomationTemplate(
        name: "Coordinate Sniper",
        description: "Positional automation using recorded pixel coordinates and touch event dispatch. No selectors, no DOM queries — pure coordinate warfare.",
        icon: "scope",
        color: "red",
        isBuiltIn: true,
        settings: {
            var s = AutomationSettings()
            s.loginButtonDetectionMode = .coordinateOnly
            s.loginButtonClickMethod = .dispatchEvent
            s.fallbackToCoordinateClick = true
            s.fallbackToVisionMLClick = true
            s.fallbackToOCRClick = false
            s.fallbackToLegacyFill = false
            s.loginButtonVisionMLFallback = true
            s.loginButtonOCRFallback = false
            s.loginButtonCoordinateFallback = true
            s.loginButtonAriaLabelMatch = false
            s.loginButtonRoleMatch = false
            s.loginButtonShadowDOMSearch = false
            s.loginButtonIframeSearch = false
            s.autoCalibrationEnabled = false
            s.visionMLCalibrationFallback = false
            s.humanMouseMovement = true
            s.humanScrollJitter = true
            s.typingSpeedMinMs = 45
            s.typingSpeedMaxMs = 140
            s.typingJitterEnabled = true
            s.occasionalBackspaceEnabled = true
            s.loginButtonClickOffsetJitter = true
            s.loginButtonClickOffsetMaxPx = 3
            s.loginButtonHoverBeforeClick = true
            s.loginButtonHoverDurationMs = 150
            s.stealthJSInjection = true
            s.fingerprintSpoofing = true
            s.webGLNoise = true
            s.canvasNoise = true
            s.patternPriorityOrder = [
                "TRUE DETECTION",
                "Coordinate Click",
                "Vision ML Coordinate",
                "Mobile Touch Burst",
                "Calibrated Direct",
                "Calibrated Typing",
                "Tab Navigation",
                "Click-Focus Sequential",
                "ExecCommand Insert",
                "Slow Deliberate Typer",
                "Form Submit Direct",
                "React Native Setter",
            ]
            return s
        }()
    )

    static let stealthGhost = AutomationTemplate(
        name: "Stealth Ghost",
        description: "Maximum anti-detection with full fingerprint spoofing, human simulation, randomized timing, and aggressive session isolation.",
        icon: "eye.slash.fill",
        color: "indigo",
        isBuiltIn: true,
        settings: {
            var s = AutomationSettings()
            s.loginButtonDetectionMode = .hybrid
            s.loginButtonClickMethod = .humanClick
            s.stealthJSInjection = true
            s.fingerprintSpoofing = true
            s.userAgentRotation = true
            s.viewportRandomization = true
            s.webGLNoise = true
            s.canvasNoise = true
            s.audioContextNoise = true
            s.timezoneSpoof = true
            s.languageSpoof = true
            s.humanMouseMovement = true
            s.humanScrollJitter = true
            s.randomPreActionPause = true
            s.preActionPauseMinMs = 100
            s.preActionPauseMaxMs = 500
            s.gaussianTimingDistribution = true
            s.typingSpeedMinMs = 60
            s.typingSpeedMaxMs = 200
            s.typingJitterEnabled = true
            s.occasionalBackspaceEnabled = true
            s.backspaceProbability = 0.05
            s.loginButtonHoverBeforeClick = true
            s.loginButtonHoverDurationMs = 300
            s.loginButtonClickOffsetJitter = true
            s.loginButtonClickOffsetMaxPx = 8
            s.loginButtonPreClickDelayMs = 250
            s.loginButtonPostClickDelayMs = 400
            s.sessionIsolation = .full
            s.clearCookiesBetweenAttempts = true
            s.clearLocalStorageBetweenAttempts = true
            s.clearSessionStorageBetweenAttempts = true
            s.clearCacheBetweenAttempts = true
            s.clearIndexedDBBetweenAttempts = true
            s.freshWebViewPerAttempt = true
            s.smartFingerprintReuse = false
            s.randomizeViewportSize = true
            s.viewportSizeVariancePx = 80
            s.delayRandomizationEnabled = true
            s.delayRandomizationPercent = 40
            s.betweenAttemptsDelayMs = 2000
            s.betweenCredentialsDelayMs = 1500
            s.fallbackToVisionMLClick = true
            s.fallbackToOCRClick = true
            s.fallbackToCoordinateClick = true
            s.fallbackToLegacyFill = false
            s.patternPriorityOrder = [
                "TRUE DETECTION",
                "Slow Deliberate Typer",
                "Click-Focus Sequential",
                "Calibrated Typing",
                "Tab Navigation",
                "Vision ML Coordinate",
                "Coordinate Click",
                "Mobile Touch Burst",
                "Calibrated Direct",
                "ExecCommand Insert",
                "Form Submit Direct",
                "React Native Setter",
            ]
            return s
        }()
    )

    static let speedDemon = AutomationTemplate(
        name: "Speed Demon",
        description: "Maximum throughput with minimal delays, high concurrency, and aggressive batch processing. Trades stealth for raw speed.",
        icon: "bolt.fill",
        color: "orange",
        isBuiltIn: true,
        settings: {
            var s = AutomationSettings()
            s.loginButtonDetectionMode = .hybrid
            s.loginButtonClickMethod = .jsClick
            s.maxConcurrency = 12
            s.batchDelayBetweenStartsMs = 0
            s.typingSpeedMinMs = 15
            s.typingSpeedMaxMs = 40
            s.typingJitterEnabled = false
            s.occasionalBackspaceEnabled = false
            s.humanMouseMovement = false
            s.humanScrollJitter = false
            s.randomPreActionPause = false
            s.gaussianTimingDistribution = false
            s.loginButtonHoverBeforeClick = false
            s.loginButtonClickOffsetJitter = false
            s.loginButtonPreClickDelayMs = 50
            s.loginButtonPostClickDelayMs = 100
            s.fieldFocusDelayMs = 50
            s.interFieldDelayMs = 100
            s.preFillPauseMinMs = 0
            s.preFillPauseMaxMs = 50
            s.preNavigationDelayMs = 0
            s.postNavigationDelayMs = 200
            s.preTypingDelayMs = 50
            s.postTypingDelayMs = 50
            s.preSubmitDelayMs = 100
            s.postSubmitDelayMs = 200
            s.betweenAttemptsDelayMs = 300
            s.betweenCredentialsDelayMs = 200
            s.pageStabilizationDelayMs = 400
            s.ajaxSettleDelayMs = 500
            s.domMutationSettleMs = 200
            s.animationSettleDelayMs = 100
            s.waitForJSRenderMs = 2000
            s.pageLoadTimeout = 20
            s.waitForResponseSeconds = 3.0
            s.delayRandomizationEnabled = false
            s.sessionIsolation = .cookies
            s.clearCookiesBetweenAttempts = true
            s.clearLocalStorageBetweenAttempts = false
            s.clearCacheBetweenAttempts = false
            s.freshWebViewPerAttempt = false
            s.stealthJSInjection = true
            s.fingerprintSpoofing = true
            s.fallbackToVisionMLClick = true
            s.fallbackToCoordinateClick = true
            s.fallbackToLegacyFill = false
            s.patternPriorityOrder = [
                "TRUE DETECTION",
                "React Native Setter",
                "Form Submit Direct",
                "Calibrated Direct",
                "Tab Navigation",
                "Coordinate Click",
                "Vision ML Coordinate",
                "Click-Focus Sequential",
                "ExecCommand Insert",
                "Mobile Touch Burst",
                "Calibrated Typing",
                "Slow Deliberate Typer",
            ]
            return s
        }()
    )

    static let resilientTank = AutomationTemplate(
        name: "Resilient Tank",
        description: "Maximum retry resilience with aggressive healing, full fallback chains, and connection recovery. Never gives up.",
        icon: "shield.checkered",
        color: "green",
        isBuiltIn: true,
        settings: {
            var s = AutomationSettings()
            s.loginButtonDetectionMode = .hybrid
            s.loginButtonClickMethod = .humanClick
            s.pageLoadRetries = 5
            s.retryBackoffMultiplier = 2.0
            s.fullSessionResetOnFinalRetry = true
            s.maxSubmitCycles = 6
            s.submitRetryCount = 5
            s.submitRetryDelayMs = 1500
            s.maxRequeueCount = 5
            s.requeueOnTimeout = true
            s.requeueOnConnectionFailure = true
            s.requeueOnUnsure = true
            s.requeueOnRedBanner = true
            s.networkErrorAutoRetry = true
            s.sslErrorAutoRetry = true
            s.http5xxAutoRetry = true
            s.connectionResetAutoRetry = true
            s.dnsFailureAutoRetry = true
            s.classifyUnknownAsUnsure = true
            s.fallbackToLegacyFill = false
            s.fallbackToOCRClick = true
            s.fallbackToVisionMLClick = true
            s.fallbackToCoordinateClick = true
            s.loginButtonEnterKeyFallback = true
            s.loginButtonFormSubmitFallback = true
            s.loginButtonVisionMLFallback = true
            s.loginButtonOCRFallback = true
            s.loginButtonCoordinateFallback = true
            s.loginButtonAriaLabelMatch = false
            s.loginButtonRoleMatch = false
            s.patternLearningEnabled = true
            s.preferCalibratedPatternsFirst = true
            s.evaluationStrictness = .lenient
            s.stealthJSInjection = true
            s.fingerprintSpoofing = true
            s.humanMouseMovement = true
            s.typingJitterEnabled = true
            s.proxyRotateOnDisabled = true
            s.proxyRotateOnFailure = true
            s.dnsRotatePerRequest = true
            s.vpnConfigRotation = true
            s.errorRecoveryDelayMs = 2000
            s.pageLoadTimeout = 45
            s.waitForResponseSeconds = 8.0
            s.waitForJSRenderMs = 5000
            s.patternPriorityOrder = [
                "TRUE DETECTION",
                "Calibrated Typing",
                "Calibrated Direct",
                "Vision ML Coordinate",
                "Coordinate Click",
                "Tab Navigation",
                "Click-Focus Sequential",
                "React Native Setter",
                "Form Submit Direct",
                "ExecCommand Insert",
                "Slow Deliberate Typer",
                "Mobile Touch Burst",
            ]
            return s
        }()
    )
}
