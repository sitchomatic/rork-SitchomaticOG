import Foundation

nonisolated struct PPSRLogEntry: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let message: String
    let level: Level

    nonisolated enum Level: String, Sendable {
        case info = "INFO"
        case success = "OK"
        case warning = "WARN"
        case error = "ERR"
    }

    init(message: String, level: Level = .info) {
        self.id = UUID()
        self.timestamp = Date()
        self.message = message
        self.level = level
    }

    var formattedTime: String {
        DateFormatters.timeWithMillis.string(from: timestamp)
    }
}
