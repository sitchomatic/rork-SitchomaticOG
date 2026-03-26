import Foundation

nonisolated struct TestSchedule: Codable, Identifiable, Sendable {
    let id: String
    var scheduledDate: Date
    var isActive: Bool
    var cardFilter: CardFilter
    var createdAt: Date

    nonisolated enum CardFilter: String, Codable, CaseIterable, Sendable {
        case allUntested = "All Untested"
        case deadOnly = "Dead Only (Retest)"
        case allNonWorking = "All Non-Working"
    }

    init(scheduledDate: Date, cardFilter: CardFilter = .allUntested) {
        self.id = UUID().uuidString
        self.scheduledDate = scheduledDate
        self.isActive = true
        self.cardFilter = cardFilter
        self.createdAt = Date()
    }
}
