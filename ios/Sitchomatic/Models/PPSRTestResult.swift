import Foundation

nonisolated struct PPSRTestResult: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let success: Bool
    let vin: String
    let duration: TimeInterval
    let errorMessage: String?

    init(success: Bool, vin: String, duration: TimeInterval, errorMessage: String? = nil, timestamp: Date? = nil) {
        self.id = UUID()
        self.timestamp = timestamp ?? Date()
        self.success = success
        self.vin = vin
        self.duration = duration
        self.errorMessage = errorMessage
    }

    var formattedDuration: String {
        String(format: "%.1fs", duration)
    }

    var formattedDate: String {
        DateFormatters.mediumDateTime.string(from: timestamp)
    }

    var formattedTime: String {
        DateFormatters.timeOnly.string(from: timestamp)
    }
}
