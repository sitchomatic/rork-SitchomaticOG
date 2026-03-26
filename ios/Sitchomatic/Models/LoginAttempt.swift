import Foundation
import Observation
import UIKit

@Observable
class LoginAttempt: Identifiable {
    let id: UUID
    let credential: LoginCredential
    let sessionIndex: Int
    var status: LoginAttemptStatus
    var startedAt: Date?
    var completedAt: Date?
    var logs: [PPSRLogEntry]
    var errorMessage: String?
    var screenshotIds: [String] = []
    var responseSnapshot: UIImage?
    var responseSnippet: String?
    var detectedURL: String?
    var assignedVPNServer: String?
    var assignedVPNIP: String?
    var assignedVPNCountry: String?
    var confidenceScore: Double?
    var confidenceSignals: [ConfidenceResultEngine.SignalContribution] = []
    var confidenceReasoning: String?
    var networkModeLabel: String?
    var replayLog: SessionReplayLog?
    var routedToReview: Bool = false

    init(credential: LoginCredential, sessionIndex: Int) {
        self.id = UUID()
        self.credential = credential
        self.sessionIndex = sessionIndex
        self.status = .queued
        self.logs = []
    }

    var duration: TimeInterval? {
        guard let start = startedAt else { return nil }
        let end = completedAt ?? Date()
        return end.timeIntervalSince(start)
    }

    var formattedDuration: String {
        guard let d = duration else { return "—" }
        return String(format: "%.1fs", d)
    }

    var hasScreenshot: Bool {
        responseSnapshot != nil || !screenshotIds.isEmpty
    }
}
