import Foundation
import UIKit
import Observation

@Observable
class ReviewItem: Identifiable {
    let id: UUID
    let credentialId: String
    let username: String
    let password: String
    let suggestedOutcome: LoginOutcome
    let confidence: Double
    let signalBreakdown: [ConfidenceResultEngine.SignalContribution]
    let reasoning: String
    let screenshotIds: [String]
    let logs: [PPSRLogEntry]
    let testedURL: String
    let networkMode: String
    let vpnServer: String?
    let vpnIP: String?
    let replayLog: SessionReplayLog?
    let createdAt: Date
    let expiresAt: Date
    var resolvedOutcome: CredentialStatus?
    var resolvedAt: Date?
    var isResolved: Bool { resolvedOutcome != nil }

    init(
        credentialId: String,
        username: String,
        password: String,
        suggestedOutcome: LoginOutcome,
        confidence: Double,
        signalBreakdown: [ConfidenceResultEngine.SignalContribution],
        reasoning: String,
        screenshotIds: [String],
        logs: [PPSRLogEntry],
        testedURL: String,
        networkMode: String,
        vpnServer: String?,
        vpnIP: String?,
        replayLog: SessionReplayLog?
    ) {
        self.id = UUID()
        self.credentialId = credentialId
        self.username = username
        self.password = password
        self.suggestedOutcome = suggestedOutcome
        self.confidence = confidence
        self.signalBreakdown = signalBreakdown
        self.reasoning = reasoning
        self.screenshotIds = screenshotIds
        self.logs = logs
        self.testedURL = testedURL
        self.networkMode = networkMode
        self.vpnServer = vpnServer
        self.vpnIP = vpnIP
        self.replayLog = replayLog
        self.createdAt = Date()
        self.expiresAt = Date().addingTimeInterval(48 * 3600)
    }

    var confidenceColor: String {
        if confidence < 0.4 { return "red" }
        if confidence < 0.6 { return "orange" }
        return "yellow"
    }

    var suggestedStatusLabel: String {
        switch suggestedOutcome {
        case .success: "Working"
        case .noAcc: "No Acc"
        case .tempDisabled: "Temp Disabled"
        case .permDisabled: "Perm Disabled"
        case .unsure: "Unsure"
        case .connectionFailure: "Connection Failure"
        case .timeout: "Timeout"
        case .redBannerError: "Red Banner"
        case .smsDetected: "SMS Detected"
        }
    }

    var isExpired: Bool {
        Date() > expiresAt
    }

    func resolve(as status: CredentialStatus) {
        resolvedOutcome = status
        resolvedAt = Date()
    }
}
