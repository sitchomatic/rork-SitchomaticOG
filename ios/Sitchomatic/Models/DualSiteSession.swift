import Foundation

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
        url: "https://www.joefortunepokies.win/login",
        selectors: SiteSelectors(user: "#username", pass: "#password", submit: "#loginSubmit", error: ".error-message")
    )

    static let ignition = SiteTarget(
        id: "ignition",
        name: "Ignition",
        url: "https://www.ignitioncasino.ooo/?overlay=login",
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
    var currentAttempt: Int
    let maxAttempts: Int
    let startTime: Date
    var endTime: Date?

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
            currentAttempt: 0,
            maxAttempts: 4,
            startTime: Date(),
            endTime: nil
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
        systemVersion: "4.1",
        concurrencyLimit: 4,
        maxAttemptsPerSite: 4,
        earlyStopTriggers: ["disabled", "closed", "restricted"],
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
    static let successTriggers = ["lobby", "Welcome", "session_id"]
    static let permStopTriggers = ["has been disabled", "permanently closed", "restricted"]
    static let tempStopTriggers = ["temporarily disabled", "too many attempts", "try again later"]
    static let continueTriggers = ["incorrect password", "incorrect"]
}
