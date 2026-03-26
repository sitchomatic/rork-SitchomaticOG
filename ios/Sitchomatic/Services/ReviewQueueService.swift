import Foundation
import Observation

@Observable
@MainActor
class ReviewQueueService {
    static let shared = ReviewQueueService()

    var items: [ReviewItem] = []
    private let confidenceEngine = ConfidenceResultEngine.shared
    private let logger = DebugLogger.shared

    static let reviewThreshold: Double = 0.70

    static let autoReviewOutcomes: Set<String> = [
        "unsure", "connectionFailure", "timeout"
    ]

    var pendingCount: Int {
        items.filter { !$0.isResolved && !$0.isExpired }.count
    }

    var resolvedCount: Int {
        items.filter { $0.isResolved }.count
    }

    var expiredCount: Int {
        items.filter { !$0.isResolved && $0.isExpired }.count
    }

    func shouldRouteToReview(outcome: LoginOutcome, confidence: Double) -> Bool {
        if confidence < Self.reviewThreshold { return true }

        switch outcome {
        case .unsure, .connectionFailure, .timeout:
            return true
        default:
            return false
        }
    }

    func addItem(
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
        let item = ReviewItem(
            credentialId: credentialId,
            username: username,
            password: password,
            suggestedOutcome: suggestedOutcome,
            confidence: confidence,
            signalBreakdown: signalBreakdown,
            reasoning: reasoning,
            screenshotIds: screenshotIds,
            logs: logs,
            testedURL: testedURL,
            networkMode: networkMode,
            vpnServer: vpnServer,
            vpnIP: vpnIP,
            replayLog: replayLog
        )
        items.insert(item, at: 0)
        logger.log("ReviewQueue: Added item for \(username) — \(suggestedOutcome) @ \(String(format: "%.0f%%", confidence * 100))", category: .evaluation, level: .warning)
    }

    func resolveItem(_ item: ReviewItem, as status: CredentialStatus) {
        item.resolve(as: status)

        let actualOutcome: LoginOutcome
        switch status {
        case .working: actualOutcome = .success
        case .noAcc: actualOutcome = .noAcc
        case .tempDisabled: actualOutcome = .tempDisabled
        case .permDisabled: actualOutcome = .permDisabled
        default: actualOutcome = .unsure
        }

        if let cred = LoginViewModel.shared.credentials.first(where: { $0.id == item.credentialId }) {
            cred.status = status
        }

        let host = URL(string: item.testedURL)?.host ?? item.testedURL
        confidenceEngine.recordOutcomeFeedback(
            host: host,
            predictedOutcome: item.suggestedOutcome,
            actualOutcome: actualOutcome,
            confidence: item.confidence,
            pageContent: item.reasoning
        )

        logger.log("ReviewQueue: Resolved \(item.username) as \(status.rawValue) (was \(item.suggestedStatusLabel))", category: .evaluation, level: .success)
    }

    func approveEngineSuggestion(_ item: ReviewItem) {
        let status: CredentialStatus
        switch item.suggestedOutcome {
        case .success: status = .working
        case .noAcc: status = .noAcc
        case .tempDisabled: status = .tempDisabled
        case .permDisabled: status = .permDisabled
        default: status = .unsure
        }
        resolveItem(item, as: status)
    }

    func expireOldItems() {
        for item in items where !item.isResolved && item.isExpired {
            approveEngineSuggestion(item)
            logger.log("ReviewQueue: Auto-expired \(item.username) → \(item.suggestedStatusLabel)", category: .evaluation, level: .info)
        }
    }

    func removeResolved() {
        items.removeAll { $0.isResolved }
    }

    func clearAll() {
        items.removeAll()
    }
}
