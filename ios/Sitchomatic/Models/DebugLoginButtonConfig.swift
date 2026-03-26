import Foundation

nonisolated struct DebugLoginButtonConfig: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    var urlPattern: String
    var successfulMethod: ClickMethodResult?
    var buttonLocation: ButtonLocation?
    var testedAt: Date = Date()
    var totalAttempts: Int = 0
    var successfulAttemptIndex: Int?
    var userConfirmed: Bool = false
    var notes: String = ""

    nonisolated struct ButtonLocation: Codable, Sendable {
        var relativeX: Double
        var relativeY: Double
        var absoluteX: Double
        var absoluteY: Double
        var viewportWidth: Double
        var viewportHeight: Double
        var elementTag: String?
        var elementText: String?
        var elementSelector: String?

        var normalizedPoint: CGPoint {
            CGPoint(x: relativeX, y: relativeY)
        }

        var absolutePoint: CGPoint {
            CGPoint(x: absoluteX, y: absoluteY)
        }
    }

    nonisolated struct ClickMethodResult: Codable, Sendable {
        var methodName: String
        var methodIndex: Int
        var jsCode: String
        var resultDetail: String
        var responseTimeMs: Int
        var timestamp: Date = Date()
    }
}

nonisolated struct DebugClickAttempt: Identifiable, Sendable {
    let id: String = UUID().uuidString
    let index: Int
    let methodName: String
    let jsSnippet: String
    var status: AttemptStatus = .pending
    var resultDetail: String = ""
    var durationMs: Int = 0
    var screenshotBefore: Data?
    var screenshotAfter: Data?
    var timestamp: Date = Date()

    nonisolated enum AttemptStatus: String, Sendable {
        case pending = "Pending"
        case running = "Running"
        case success = "Success"
        case failed = "Failed"
        case skipped = "Skipped"
        case userConfirmed = "User Confirmed"
    }
}
