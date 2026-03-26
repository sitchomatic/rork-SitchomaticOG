import Foundation

nonisolated struct DualFindResumePoint: Codable, Sendable {
    let joeEmailIndex: Int
    let joePasswordIndex: Int
    let ignEmailIndex: Int
    let ignPasswordIndex: Int
    let emails: [String]
    let passwords: [String]
    let sessionCount: Int
    let timestamp: Date
    let disabledEmails: [String]
    let foundLogins: [DualFindHit]
    let joeCompletedTests: Int
    let ignCompletedTests: Int

    init(joeEmailIndex: Int, joePasswordIndex: Int, ignEmailIndex: Int, ignPasswordIndex: Int, emails: [String], passwords: [String], sessionCount: Int, timestamp: Date, disabledEmails: [String], foundLogins: [DualFindHit], joeCompletedTests: Int = 0, ignCompletedTests: Int = 0) {
        self.joeEmailIndex = joeEmailIndex
        self.joePasswordIndex = joePasswordIndex
        self.ignEmailIndex = ignEmailIndex
        self.ignPasswordIndex = ignPasswordIndex
        self.emails = emails
        self.passwords = passwords
        self.sessionCount = sessionCount
        self.timestamp = timestamp
        self.disabledEmails = disabledEmails
        self.foundLogins = foundLogins
        self.joeCompletedTests = joeCompletedTests
        self.ignCompletedTests = ignCompletedTests
    }
}

nonisolated struct DualFindHit: Codable, Sendable, Identifiable {
    let id: String
    let email: String
    let password: String
    let platform: String
    let timestamp: Date

    init(email: String, password: String, platform: String) {
        self.id = UUID().uuidString
        self.email = email
        self.password = password
        self.platform = platform
        self.timestamp = Date()
    }

    var copyText: String {
        "\(email):\(password)"
    }
}

nonisolated struct DualFindSessionInfo: Identifiable, Sendable {
    let id: String
    let index: Int
    let platform: String
    var currentEmail: String
    var status: String
    var isActive: Bool

    init(index: Int, platform: String) {
        self.id = "\(platform)_\(index)"
        self.index = index
        self.platform = platform
        self.currentEmail = ""
        self.status = "Idle"
        self.isActive = false
    }
}

nonisolated enum DualFindTestOutcome: Sendable {
    case success
    case disabled
    case transient
    case noAccount
    case unsure
}

nonisolated enum DualFindInterventionAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case markSuccess = "Mark as Success"
    case markNoAccount = "Mark as No Account"
    case markDisabled = "Mark as Disabled"
    case restartWithNewIP = "Restart with New IP"
    case pressSubmitAgain = "Press Submit 3 More Times"
    case disableURL = "Disable This URL"
    case disableViewport = "Disable Viewport"
    case skipAndContinue = "Skip & Continue"

    nonisolated var id: String { rawValue }

    var icon: String {
        switch self {
        case .markSuccess: "checkmark.circle.fill"
        case .markNoAccount: "xmark.circle.fill"
        case .markDisabled: "person.slash.fill"
        case .restartWithNewIP: "arrow.triangle.2.circlepath"
        case .pressSubmitAgain: "hand.tap.fill"
        case .disableURL: "link.badge.plus"
        case .disableViewport: "rectangle.slash"
        case .skipAndContinue: "forward.fill"
        }
    }

    var colorName: String {
        switch self {
        case .markSuccess: "green"
        case .markNoAccount: "red"
        case .markDisabled: "orange"
        case .restartWithNewIP: "blue"
        case .pressSubmitAgain: "purple"
        case .disableURL: "pink"
        case .disableViewport: "indigo"
        case .skipAndContinue: "gray"
        }
    }

    var isResultCorrection: Bool {
        switch self {
        case .markSuccess, .markNoAccount, .markDisabled: true
        default: false
        }
    }

    var correctedOutcome: DualFindTestOutcome? {
        switch self {
        case .markSuccess: .success
        case .markNoAccount: .noAccount
        case .markDisabled: .disabled
        default: nil
        }
    }
}

nonisolated struct DualFindInterventionRequest: Identifiable, Sendable {
    let id: String = UUID().uuidString
    let sessionLabel: String
    let email: String
    let password: String
    let platform: String
    let pageContent: String
    let currentURL: String
    let timestamp: Date = Date()
    let sessionIndex: Int
    let site: LoginTargetSite
    let passwordIndex: Int
}

nonisolated enum DualFindSessionCount: Int, CaseIterable, Sendable {
    case four = 4
    case six = 6
    case eight = 8

    var label: String {
        switch self {
        case .four: "4 Sessions (2+2)"
        case .six: "6 Sessions (3+3)"
        case .eight: "8 Sessions (4+4)"
        }
    }

    var perSite: Int {
        switch self {
        case .four: 2
        case .six: 3
        case .eight: 4
        }
    }
}
