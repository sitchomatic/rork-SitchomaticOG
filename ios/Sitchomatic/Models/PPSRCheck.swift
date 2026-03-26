import Foundation
import Observation
import UIKit

@Observable
class PPSRCheck: Identifiable {
    let id: UUID
    let vin: String
    let email: String
    let card: PPSRCard
    let sessionIndex: Int
    var status: PPSRCheckStatus
    var startedAt: Date?
    var completedAt: Date?
    var logs: [PPSRLogEntry]
    var errorMessage: String?
    var screenshotIds: [String] = []
    var responseSnapshot: UIImage?
    var responseSnippet: String?

    var expiryMonth: String { card.expiryMonth }
    var expiryYear: String { card.expiryYear }
    var cvv: String { card.cvv }

    init(vin: String, email: String, card: PPSRCard, sessionIndex: Int) {
        self.id = UUID()
        self.vin = vin
        self.email = email
        self.card = card
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
}
