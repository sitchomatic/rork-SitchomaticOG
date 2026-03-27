import Foundation
import SwiftUI

nonisolated enum SessionGlobalState: String, Codable, Sendable {
    case active = "ACTIVE"
    case success = "SUCCESS"
    case abortPerm = "ABORT_PERM"
    case abortTemp = "ABORT_TEMP"
    case exhausted = "EXHAUSTED"
}

nonisolated enum SessionClassification: String, Codable, Sendable {
    case validAccount = "Valid Account"
    case permanentBan = "Permanent Ban"
    case temporaryLock = "Temporary Lock"
    case noAccount = "No Account"
    case pending = "Pending"
}

nonisolated enum SiteResult: String, Codable, Sendable, CaseIterable {
    case success = "Success"
    case noAccount = "No Acc"
    case permDisabled = "Perm Disabled"
    case tempDisabled = "Temp Disabled"
    case unsure = "Unsure"
    case pending = "Pending"

    var shortLabel: String {
        switch self {
        case .success: "SUCCESS"
        case .noAccount: "NO ACC"
        case .permDisabled: "PERM DIS"
        case .tempDisabled: "TEMP DIS"
        case .unsure: "UNSURE"
        case .pending: "PENDING"
        }
    }

    var pluralLabel: String {
        switch self {
        case .success: "SUCCESS"
        case .noAccount: "NO ACCOUNTS"
        case .permDisabled: "PERM DISABLED"
        case .tempDisabled: "TEMP DISABLED"
        case .unsure: "UNSURE"
        case .pending: "PENDING"
        }
    }

    var color: Color {
        switch self {
        case .success: .green
        case .noAccount: .secondary
        case .permDisabled: .red
        case .tempDisabled: .orange
        case .unsure: .yellow
        case .pending: .cyan
        }
    }

    var icon: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .noAccount: "xmark.circle.fill"
        case .permDisabled: "lock.slash.fill"
        case .tempDisabled: "clock.badge.exclamationmark"
        case .unsure: "questionmark.circle.fill"
        case .pending: "clock"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .pending: false
        default: true
        }
    }

    var priority: Int {
        switch self {
        case .success: 5
        case .permDisabled: 4
        case .tempDisabled: 3
        case .noAccount: 2
        case .unsure: 1
        case .pending: 0
        }
    }

    static func fromLoginOutcome(_ outcome: LoginOutcome, registeredAttempts: Int, maxAttempts: Int) -> SiteResult {
        switch outcome {
        case .success: return .success
        case .permDisabled: return .permDisabled
        case .tempDisabled: return .tempDisabled
        case .noAcc:
            // No Account requires 4 complete login cycles before confirmation
            if registeredAttempts >= 4 {
                return .noAccount
            }
            return .unsure
        case .unsure, .redBannerError, .smsDetected:
            return .unsure
        case .connectionFailure, .timeout:
            return .unsure
        }
    }
}

nonisolated enum IdentityAction: String, Codable, Sendable {
    case burn = "BURN"
    case save = "SAVE"
}

nonisolated struct SiteSelectors: Codable, Sendable {
    let user: String
    let pass: String
    let submit: String
    let error: String
}

nonisolated struct SiteTarget: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let url: String
    let selectors: SiteSelectors

    static let joefortune = SiteTarget(
        id: "joe",
        name: "JoeFortune",
        url: "https://joefortunepokies.win/login",
        selectors: SiteSelectors(user: "#username", pass: "#password", submit: "#loginSubmit", error: ".error-message")
    )

    static let ignition = SiteTarget(
        id: "ignition",
        name: "Ignition",
        url: "https://ignitioncasino.ooo/?overlay=login",
        selectors: SiteSelectors(user: "#email", pass: "#login-password", submit: "#login-submit", error: ".alert-danger")
    )
}

nonisolated struct SessionIdentity: Codable, Sendable {
    let proxyAddress: String
    let userAgent: String
    let viewport: String
    let canvasFingerprint: String
}

nonisolated struct SiteAttemptResult: Codable, Sendable {
    let siteId: String
    let attemptNumber: Int
    let responseText: String
    let timestamp: Date
    let durationMs: Int
    var ocrOutcome: String? = nil
    var ocrFullText: String? = nil
    var ocrCrucialMatches: [String]? = nil
}

/// OCR metadata for a single site's evaluation, used by the Debug Results UI.
nonisolated struct SiteOCRMetadata: Codable, Sendable {
    let siteId: String
    let ocrOutcome: String
    let crucialMatches: [String]
    let fullText: String
    let confidence: Double
    let screenshotTimestamp: Date
}

struct DualSiteSession: Identifiable, Codable, Sendable {
    let id: String
    let credential: SessionCredential
    let identity: SessionIdentity
    var globalState: SessionGlobalState
    var classification: SessionClassification
    var identityAction: IdentityAction
    var joeAttempts: [SiteAttemptResult]
    var ignitionAttempts: [SiteAttemptResult]
    var joeSiteResult: SiteResult
    var ignitionSiteResult: SiteResult
    var currentAttempt: Int
    let maxAttempts: Int
    let startTime: Date
    var endTime: Date?
    var joeOCRMetadata: SiteOCRMetadata?
    var ignitionOCRMetadata: SiteOCRMetadata?

    var isTerminal: Bool {
        switch globalState {
        case .active: false
        case .success, .abortPerm, .abortTemp, .exhausted: true
        }
    }

    var duration: TimeInterval {
        let end = endTime ?? Date()
        return end.timeIntervalSince(startTime)
    }

    var formattedDuration: String {
        let d = duration
        if d < 60 { return String(format: "%.1fs", d) }
        return String(format: "%.0fm %02.0fs", (d / 60).rounded(.down), d.truncatingRemainder(dividingBy: 60))
    }

    var hasMixedResults: Bool {
        guard joeSiteResult.isTerminal && ignitionSiteResult.isTerminal else { return false }
        return joeSiteResult != ignitionSiteResult
    }

    var highestPriorityResult: SiteResult {
        joeSiteResult.priority >= ignitionSiteResult.priority ? joeSiteResult : ignitionSiteResult
    }

    var pairedBadgeText: String {
        guard isTerminal else {
            if globalState == .active && currentAttempt > 0 {
                return "TESTING"
            }
            return "QUEUED"
        }
        if joeSiteResult == ignitionSiteResult {
            return joeSiteResult.pluralLabel
        }
        return "\(joeSiteResult.shortLabel) | \(ignitionSiteResult.shortLabel)"
    }

    /// Apple Vision Blueprint paired OCR status string.
    /// Format: "Perm Disableds" (same) or "Perm Disabled / Success" (split).
    var pairedOCRStatus: String? {
        guard let joeOCR = joeOCRMetadata, let ignOCR = ignitionOCRMetadata else { return nil }
        if joeOCR.ocrOutcome == ignOCR.ocrOutcome {
            return joeOCR.ocrOutcome == "Unsure" ? "Unsure" : "\(joeOCR.ocrOutcome)s"
        }
        return "\(joeOCR.ocrOutcome) / \(ignOCR.ocrOutcome)"
    }

    func hasSiteResult(_ result: SiteResult) -> Bool {
        joeSiteResult == result || ignitionSiteResult == result
    }

    static func create(credential: SessionCredential, identity: SessionIdentity) -> DualSiteSession {
        DualSiteSession(
            id: UUID().uuidString,
            credential: credential,
            identity: identity,
            globalState: .active,
            classification: .pending,
            identityAction: .save,
            joeAttempts: [],
            ignitionAttempts: [],
            joeSiteResult: .pending,
            ignitionSiteResult: .pending,
            currentAttempt: 0,
            maxAttempts: 4,
            startTime: Date(),
            endTime: nil,
            joeOCRMetadata: nil,
            ignitionOCRMetadata: nil
        )
    }
}

nonisolated struct SessionCredential: Codable, Sendable, Identifiable {
    let id: String
    let email: String
    let password: String

    var maskedPassword: String {
        guard password.count > 2 else { return "••••" }
        return String(password.prefix(1)) + String(repeating: "•", count: max(password.count - 2, 2)) + String(password.suffix(1))
    }
}

nonisolated struct UnifiedSystemConfig: Codable, Sendable {
    let systemVersion: String
    let concurrencyLimit: Int
    let maxAttemptsPerSite: Int
    let earlyStopTriggers: [String]
    let sites: [SiteTarget]
    let humanEmulation: HumanEmulationConfig

    static let defaultConfig = UnifiedSystemConfig(
        systemVersion: "4.2",
        concurrencyLimit: 4,
        maxAttemptsPerSite: 4,
        earlyStopTriggers: ["has been disabled", "temporarily disabled"],
        sites: [.joefortune, .ignition],
        humanEmulation: .default
    )
}

nonisolated struct HumanEmulationConfig: Codable, Sendable {
    let typingSpeedMin: Int
    let typingSpeedMax: Int
    let clickJitterPx: Int
    let postErrorDelayMin: Int
    let postErrorDelayMax: Int

    static let `default` = HumanEmulationConfig(
        typingSpeedMin: 60,
        typingSpeedMax: 150,
        clickJitterPx: 3,
        postErrorDelayMin: 400,
        postErrorDelayMax: 700
    )
}

nonisolated struct TerminationLogic: Sendable {
    // Blueprint 100/100 Strict Triggers
    static let successTriggers = ["my account", "balance", "deposit", "welcome", "dashboard", "lobby", "session_id"]
    static let permStopTriggers = ["has been disabled"]
    static let tempStopTriggers = ["temporarily disabled"]
    static let continueTriggers = ["incorrect", "not find", "no account", "invalid", "incorrect password"]
}
