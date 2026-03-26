import Foundation

nonisolated struct FailureNotice: Identifiable, Sendable {
    let id: String
    let message: String
    let source: Source
    let timestamp: Date
    var autoRetried: Bool

    enum Source: String, Sendable, Codable {
        case ppsr = "PPSR"
        case login = "Login"
    }

    init(message: String, source: Source, autoRetried: Bool = false) {
        self.id = UUID().uuidString
        self.message = message
        self.source = source
        self.timestamp = Date()
        self.autoRetried = autoRetried
    }

    var formattedTime: String {
        DateFormatters.timeOnly.string(from: timestamp)
    }
}
