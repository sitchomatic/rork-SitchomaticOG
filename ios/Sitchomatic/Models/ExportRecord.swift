import Foundation

nonisolated struct ExportRecord: Codable, Identifiable, Sendable {
    let id: String
    let timestamp: Date
    let format: String
    let cardCount: Int
    let exportType: String

    init(format: String, cardCount: Int, exportType: String) {
        self.id = UUID().uuidString
        self.timestamp = Date()
        self.format = format
        self.cardCount = cardCount
        self.exportType = exportType
    }
}
