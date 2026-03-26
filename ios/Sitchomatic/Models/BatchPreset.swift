import Foundation

nonisolated struct BatchPreset: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var maxConcurrency: Int
    var stealthEnabled: Bool
    var useEmailRotation: Bool
    var retrySubmitOnFail: Bool
    var testTimeout: TimeInterval
    var createdAt: Date

    init(name: String, maxConcurrency: Int, stealthEnabled: Bool, useEmailRotation: Bool, retrySubmitOnFail: Bool, testTimeout: TimeInterval) {
        self.id = UUID().uuidString
        self.name = name
        self.maxConcurrency = maxConcurrency
        self.stealthEnabled = stealthEnabled
        self.useEmailRotation = useEmailRotation
        self.retrySubmitOnFail = retrySubmitOnFail
        self.testTimeout = testTimeout
        self.createdAt = Date()
    }
}
