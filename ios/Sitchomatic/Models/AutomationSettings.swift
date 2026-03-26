import Foundation

nonisolated struct AutomationSettings: Codable, Sendable {
    // MARK: - TRUE DETECTION (Primary Protocol)
    var trueDetectionEnabled: Bool = true
    var trueDetectionPriority: Bool = true
    var trueDetectionHardPauseMs: Int = 4500
    var trueDetectionTripleClickCount: Int = 4
    var trueDetectionTripleClickDelayMs: Int = 1600
    var trueDetectionSubmitCycleCount: Int = 4
    var trueDetectionButtonRecoveryTimeoutMs: Int = 12000
    var trueDetectionMaxAttempts: Int = 4
    var trueDetectionAlwaysForceEnabled: Bool = true
    var trueDetectionPostClickWaitMs: Int = 3250
    var trueDetectionCooldownMinutes: Int = 15
    var trueDetectionEmailSelector: String = "#email"
    var trueDetectionPasswordSelector: String = "#login-password"
    var trueDetectionSubmitSelector: String = "#login-submit"
    var trueDetectionSuccessMarkers: [String] = ["balance", "wallet", "my account", "logout"]
    var trueDetectionTerminalKeywords: [String] = ["temporarily disabled", "account is disabled"]
    var trueDetectionErrorBannerSelectors: [String] = [".error-banner", ".alert-danger", ".alert-error", ".login-error", ".notification-error", "[role='alert']"]
    var trueDetectionNoProxyRotation: Bool = false
    var trueDetectionStrictWaits: Bool = true
    var trueDetectionIgnorePlaceholders: Bool = true
    var trueDetectionIgnoreXPaths: Bool = true
    var trueDetectionIgnoreClassNames: Bool = true

    // MARK: - Page Loading
    var pageLoadTimeout: TimeInterval = 90
    var pageLoadRetries: Int = 3
    var retryBackoffMultiplier: Double = 2.0
    var waitForJSRenderMs: Int = 4500
    var fullSessionResetOnFinalRetry: Bool = true

    // MARK: - Field Detection
    var fieldVerificationEnabled: Bool = true
    var fieldVerificationTimeout: TimeInterval = 90
    var autoCalibrationEnabled: Bool = true
    var visionMLCalibrationFallback: Bool = true
    var calibrationConfidenceThreshold: Double = 0.6

    // MARK: - Cookie/Consent
    var dismissCookieNotices: Bool = true
    var cookieDismissDelayMs: Int = 300

    // MARK: - Credential Entry
    var typingSpeedMinMs: Int = 80
    var typingSpeedMaxMs: Int = 150
    var typingJitterEnabled: Bool = true
    var occasionalBackspaceEnabled: Bool = true
    var backspaceProbability: Double = 0.04
    var fieldFocusDelayMs: Int = 200
    var interFieldDelayMs: Int = 400
    var preFillPauseMinMs: Int = 100
    var preFillPauseMaxMs: Int = 500

    // MARK: - Pattern Strategy
    var maxSubmitCycles: Int = 5
    var enabledPatterns: [String] = LoginFormPatternList.allNames
    var patternPriorityOrder: [String] = LoginFormPatternList.defaultPriorityOrder
    var preferCalibratedPatternsFirst: Bool = true
    var patternLearningEnabled: Bool = true

    // MARK: - Fallback Chain (Anti-Bot)
    var fallbackToLegacyFill: Bool = false
    var fallbackToOCRClick: Bool = true
    var fallbackToVisionMLClick: Bool = true
    var fallbackToCoordinateClick: Bool = true

    // MARK: - Submit Behavior
    var submitRetryCount: Int = 5
    var submitRetryDelayMs: Int = 4800
    var waitForResponseSeconds: Double = 90.0
    var rapidPollEnabled: Bool = true
    var rapidPollIntervalMs: Int = 200

    // MARK: - Post-Submit Evaluation
    var redirectDetection: Bool = true
    var errorBannerDetection: Bool = false
    var contentChangeDetection: Bool = true
    var evaluationStrictness: EvaluationStrictness = .strict
    var capturePageContent: Bool = true
    // Kept for backward compat but unused by True Detection eval
    var welcomeTextDetection: Bool = false

    // MARK: - Retry / Requeue
    var requeueOnTimeout: Bool = true
    var requeueOnConnectionFailure: Bool = true
    var requeueOnUnsure: Bool = true
    var requeueOnRedBanner: Bool = true
    var maxRequeueCount: Int = 3
    var minAttemptsBeforeNoAcc: Int = 3
    var cyclePauseMinMs: Int = 500
    var cyclePauseMaxMs: Int = 1500

    // MARK: - Stealth
    var stealthJSInjection: Bool = true
    var fingerprintValidationEnabled: Bool = false
    var fingerprintSpoofing: Bool = true
    var userAgentRotation: Bool = true
    var viewportRandomization: Bool = true
    var webGLNoise: Bool = true
    var canvasNoise: Bool = false
    var audioContextNoise: Bool = false
    var timezoneSpoof: Bool = true
    var languageSpoof: Bool = true

    // MARK: - Screenshot / Debug
    var slowDebugMode: Bool = false
    var screenshotOnEveryEval: Bool = true
    var screenshotOnFailure: Bool = true
    var screenshotOnSuccess: Bool = true
    var maxScreenshotRetention: Int = 500

    // MARK: - Concurrency
    var maxConcurrency: Int = 4
    var batchDelayBetweenStartsMs: Int = 0
    var connectionTestBeforeBatch: Bool = true

    // MARK: - Network Per-Mode
    var useAssignedNetworkForTests: Bool = true
    var proxyRotateOnDisabled: Bool = true
    var proxyRotateOnFailure: Bool = false
    var dnsRotatePerRequest: Bool = true
    var vpnConfigRotation: Bool = true

    // MARK: - URL Rotation
    var urlRotationEnabled: Bool = true
    var disableURLAfterConsecutiveFailures: Int = 2
    var reEnableURLAfterSeconds: TimeInterval = 0
    var preferFastestURL: Bool = false
    var smartURLSelection: Bool = true

    // MARK: - Blacklist / Auto-Actions
    var autoBlacklistNoAcc: Bool = true
    var autoBlacklistPermDisabled: Bool = true
    var autoExcludeBlacklist: Bool = true

    // MARK: - Human Simulation
    var humanMouseMovement: Bool = true
    var humanScrollJitter: Bool = true
    var randomPreActionPause: Bool = true
    var preActionPauseMinMs: Int = 80
    var preActionPauseMaxMs: Int = 310
    var gaussianTimingDistribution: Bool = true

    // MARK: - Login Button (Fallback modes only)
    var loginButtonDetectionMode: ButtonDetectionMode = .trueDetection
    var loginButtonTextMatches: [String] = ["LOGIN", "Sign in", "Sign In", "Submit", "Continue", "Next", "Go", "Enter", "Login", "Lo gin"]
    var loginButtonCustomSelector: String = ""
    var loginButtonClickMethod: ButtonClickMethod = .humanClick
    var loginButtonPreClickDelayMs: Int = 250
    var loginButtonPostClickDelayMs: Int = 350
    var loginButtonDoubleClickGuard: Bool = true
    var loginButtonDoubleClickWindowMs: Int = 1500
    var loginButtonScrollIntoView: Bool = false
    var loginButtonWaitForEnabled: Bool = true
    var loginButtonWaitForEnabledTimeoutMs: Int = 90_000
    var pageLoadExtraDelayMs: Int = 2000
    var submitButtonWaitDelayMs: Int = 2000
    var loginButtonVisibilityCheck: Bool = true
    var loginButtonFocusBeforeClick: Bool = false
    var loginButtonHoverBeforeClick: Bool = true
    var loginButtonHoverDurationMs: Int = 200
    var loginButtonClickOffsetJitter: Bool = true
    var loginButtonClickOffsetMaxPx: Int = 5
    var loginButtonEnterKeyFallback: Bool = true
    var loginButtonFormSubmitFallback: Bool = true
    var loginButtonVisionMLFallback: Bool = true
    var loginButtonOCRFallback: Bool = true
    var loginButtonCoordinateFallback: Bool = true
    var loginButtonMinSizePx: Int = 20
    var loginButtonMaxCandidates: Int = 5
    var loginButtonConfidenceThreshold: Double = 0.5
    // Legacy DOM settings — kept for backward compat, not used by True Detection
    var loginButtonAriaLabelMatch: Bool = true
    var loginButtonRoleMatch: Bool = true
    var loginButtonImageButtonDetection: Bool = true
    var loginButtonShadowDOMSearch: Bool = true
    var loginButtonIframeSearch: Bool = false

    // MARK: - Time Delays
    var globalPreActionDelayMs: Int = 0
    var globalPostActionDelayMs: Int = 0
    var preNavigationDelayMs: Int = 200
    var postNavigationDelayMs: Int = 600
    var preTypingDelayMs: Int = 250
    var postTypingDelayMs: Int = 350
    var preSubmitDelayMs: Int = 350
    var postSubmitDelayMs: Int = 600
    var betweenAttemptsDelayMs: Int = 1250
    var betweenCredentialsDelayMs: Int = 750
    var pageStabilizationDelayMs: Int = 1100
    var ajaxSettleDelayMs: Int = 1100
    var domMutationSettleMs: Int = 600
    var animationSettleDelayMs: Int = 700
    var redirectFollowDelayMs: Int = 600
    var captchaDetectionDelayMs: Int = 2000
    var errorRecoveryDelayMs: Int = 1750
    var sessionCooldownDelayMs: Int = 500
    var proxyRotationDelayMs: Int = 750
    var vpnReconnectDelayMs: Int = 2500
    var autoFallbackWGtoOVPN: Bool = true
    var autoFallbackOVPNtoSOCKS5: Bool = true
    var delayRandomizationEnabled: Bool = true
    var delayRandomizationPercent: Int = 25

    // MARK: - Two-Factor / MFA Handling
    var mfaDetectionEnabled: Bool = false
    var mfaWaitTimeoutSeconds: Int = 90
    var mfaAutoSkip: Bool = false
    var mfaMarkAsTempDisabled: Bool = true
    var mfaKeywords: [String] = ["verification", "verify", "code", "2fa", "two-factor", "authenticator", "one-time", "OTP", "security code"]

    var smsNotificationKeywords: [String] = ["sms", "text message", "verification code", "verify your phone", "send code", "sent a code", "enter the code", "phone verification", "mobile verification", "confirm your number", "we sent", "code sent", "enter code", "security code sent", "check your phone"]
    var smsDetectionEnabled: Bool = true
    var smsBurnSession: Bool = true

    // MARK: - CAPTCHA Handling
    var captchaDetectionEnabled: Bool = false
    var captchaAutoSkip: Bool = true
    var captchaMarkAsFailed: Bool = false
    var captchaWaitTimeoutSeconds: Int = 90
    var captchaKeywords: [String] = ["captcha", "recaptcha", "hcaptcha", "robot", "verify you are human", "I'm not a robot"]
    var captchaIframeDetection: Bool = true
    var captchaImageDetection: Bool = true

    // MARK: - Session Management
    var sessionIsolation: SessionIsolationMode = .full
    var clearCookiesBetweenAttempts: Bool = true
    var clearLocalStorageBetweenAttempts: Bool = true
    var clearSessionStorageBetweenAttempts: Bool = true
    var clearCacheBetweenAttempts: Bool = false
    var clearIndexedDBBetweenAttempts: Bool = false
    var freshWebViewPerAttempt: Bool = false
    var reuseWebViewPoolSize: Int = 24
    var webViewMemoryLimitMB: Int = 2048
    var webViewJSEnabled: Bool = true
    var webViewImageLoadingEnabled: Bool = true
    var webViewPluginsEnabled: Bool = false

    // MARK: - Blank Page Recovery
    var blankPageRecoveryEnabled: Bool = true
    var blankPageTimeoutSeconds: Int = 20
    var blankPageWaitThresholdSeconds: Int = 90
    var blankPageFallback1_WaitAndRecheck: Bool = true
    var blankPageFallback2_ChangeURL: Bool = true
    var blankPageFallback3_ChangeDNS: Bool = true
    var blankPageFallback4_ChangeFingerprint: Bool = true
    var blankPageFallback5_FullSessionReset: Bool = true
    var blankPageMaxFallbackAttempts: Int = 5
    var blankPageRecheckIntervalMs: Int = 3000

    // MARK: - Error Classification
    var networkErrorAutoRetry: Bool = true
    var sslErrorAutoRetry: Bool = true
    var http403MarkAsBlocked: Bool = true
    var http429RetryAfterSeconds: Int = 90
    var http5xxAutoRetry: Bool = true
    var connectionResetAutoRetry: Bool = true
    var dnsFailureAutoRetry: Bool = true
    var classifyUnknownAsUnsure: Bool = true

    // MARK: - Form Interaction Advanced
    var clearFieldsBeforeTyping: Bool = true
    var clearFieldMethod: FieldClearMethod = .tripleClickDelete
    var tabBetweenFields: Bool = false
    var clickFieldBeforeTyping: Bool = true
    var verifyFieldValueAfterTyping: Bool = true
    var retypeOnVerificationFailure: Bool = true
    var maxRetypeAttempts: Int = 2
    var passwordFieldUnmaskCheck: Bool = false
    var autoDetectRememberMe: Bool = false
    var uncheckRememberMe: Bool = true
    var dismissAutofillSuggestions: Bool = true
    var handlePasswordManagers: Bool = true

    // MARK: - Viewport & Window
    var viewportWidth: Int = 390
    var viewportHeight: Int = 844
    var useWebViewPoolFingerprints: Bool = true
    var randomizeViewportSize: Bool = false
    var viewportSizeVariancePx: Int = 50
    var mobileViewportEmulation: Bool = true
    var mobileViewportWidth: Int = 390
    var mobileViewportHeight: Int = 844
    var deviceScaleFactor: Double = 2.0

    // MARK: - Speed Optimization (legacy)
    var speedOptimizationEnabled: Bool = false
    var autoTuneConcurrency: Bool = false
    var autoTuneDelays: Bool = false
    var speedProfileApplied: Bool = false

    // MARK: - Recorded Flow Override
    var urlFlowAssignments: [URLFlowAssignment] = []

    static let minimumTimeoutSeconds: TimeInterval = 180
    static let minimumTimeoutMilliseconds: Int = 180_000

    func normalizedTimeouts() -> AutomationSettings {
        var normalized = self
        // slowDebugMode is now a plain Bool, no normalization needed
        normalized.pageLoadTimeout = max(normalized.pageLoadTimeout, Self.minimumTimeoutSeconds)
        normalized.fieldVerificationTimeout = max(normalized.fieldVerificationTimeout, Self.minimumTimeoutSeconds)
        normalized.waitForResponseSeconds = max(normalized.waitForResponseSeconds, Self.minimumTimeoutSeconds)
        normalized.loginButtonWaitForEnabledTimeoutMs = max(normalized.loginButtonWaitForEnabledTimeoutMs, Self.minimumTimeoutMilliseconds)
        normalized.mfaWaitTimeoutSeconds = max(normalized.mfaWaitTimeoutSeconds, Int(Self.minimumTimeoutSeconds))
        normalized.captchaWaitTimeoutSeconds = max(normalized.captchaWaitTimeoutSeconds, Int(Self.minimumTimeoutSeconds))
        normalized.blankPageWaitThresholdSeconds = max(normalized.blankPageWaitThresholdSeconds, 30)
        normalized.http429RetryAfterSeconds = max(normalized.http429RetryAfterSeconds, Int(Self.minimumTimeoutSeconds))
        return normalized
    }

    // MARK: - Enums

    nonisolated enum EvaluationStrictness: String, Codable, CaseIterable, Sendable {
        case lenient = "Lenient"
        case normal = "Normal"
        case strict = "Strict"
    }

    nonisolated enum ButtonDetectionMode: String, Codable, CaseIterable, Sendable {
        case trueDetection = "TRUE DETECTION"
        case textMatch = "Text Match"
        case visionML = "Vision ML"
        case hybrid = "Hybrid"
        case coordinateOnly = "Coordinate Only"
    }

    nonisolated enum ButtonClickMethod: String, Codable, CaseIterable, Sendable {
        case humanClick = "Human Touch Chain"
        case jsClick = "JS Click"
        case dispatchEvent = "Pointer+Touch Dispatch"
        case formSubmit = "Form Submit"
        case enterKey = "Enter Key"
    }

    nonisolated enum SessionIsolationMode: String, Codable, CaseIterable, Sendable {
        case none = "None"
        case cookies = "Cookies Only"
        case storage = "Storage Only"
        case full = "Full Isolation"
    }

    nonisolated enum FieldClearMethod: String, Codable, CaseIterable, Sendable {
        case selectAllDelete = "Select All + Delete"
        case tripleClickDelete = "Triple Click + Delete"
        case jsValueClear = "JS Value Clear"
        case backspaceLoop = "Backspace Loop"
    }
}

nonisolated struct URLFlowAssignment: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    var urlPattern: String
    var flowId: String
    var flowName: String
    var overridePatternStrategy: Bool = true
    var overrideTypingSpeed: Bool = false
    var overrideStealthSettings: Bool = false
    var overrideSubmitBehavior: Bool = false
    var assignedAt: Date = Date()
}

nonisolated enum LoginFormPatternList {
    static let allNames: [String] = [
        "TRUE DETECTION",
        "Tab Navigation",
        "Click-Focus Sequential",
        "ExecCommand Insert",
        "Slow Deliberate Typer",
        "Mobile Touch Burst",
        "Calibrated Direct",
        "Calibrated Typing",
        "Form Submit Direct",
        "Coordinate Click",
        "React Native Setter",
        "Vision ML Coordinate",
    ]

    static let defaultPriorityOrder: [String] = [
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
}
