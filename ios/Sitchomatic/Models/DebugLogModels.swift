import Foundation

nonisolated enum DebugLogCategory: String, CaseIterable, Sendable, Identifiable, Codable {
    case automation = "Automation"
    case login = "Login"
    case ppsr = "PPSR"
    case superTest = "Super Test"
    case network = "Network"
    case proxy = "Proxy"
    case dns = "DNS"
    case vpn = "VPN"
    case url = "URL Rotation"
    case fingerprint = "Fingerprint"
    case stealth = "Stealth"
    case webView = "WebView"
    case persistence = "Persistence"
    case system = "System"
    case evaluation = "Evaluation"
    case screenshot = "Screenshot"
    case timing = "Timing"
    case healing = "Healing"
    case flowRecorder = "Flow Recorder"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .automation: "gearshape.2.fill"
        case .login: "person.badge.key.fill"
        case .ppsr: "car.side.fill"
        case .superTest: "bolt.horizontal.circle.fill"
        case .network: "wifi"
        case .proxy: "network"
        case .dns: "lock.shield.fill"
        case .vpn: "shield.lefthalf.filled"
        case .url: "arrow.triangle.2.circlepath"
        case .fingerprint: "fingerprint"
        case .stealth: "eye.slash.fill"
        case .webView: "safari.fill"
        case .persistence: "externaldrive.fill"
        case .system: "cpu"
        case .evaluation: "chart.bar.xaxis"
        case .screenshot: "camera.fill"
        case .timing: "stopwatch.fill"
        case .healing: "cross.circle.fill"
        case .flowRecorder: "record.circle.fill"
        }
    }

    var color: String {
        switch self {
        case .automation: "blue"
        case .login: "green"
        case .ppsr: "cyan"
        case .superTest: "purple"
        case .network: "orange"
        case .proxy: "red"
        case .dns: "indigo"
        case .vpn: "teal"
        case .url: "mint"
        case .fingerprint: "pink"
        case .stealth: "gray"
        case .webView: "blue"
        case .persistence: "brown"
        case .system: "secondary"
        case .evaluation: "yellow"
        case .screenshot: "purple"
        case .timing: "orange"
        case .healing: "green"
        case .flowRecorder: "red"
        }
    }
}

nonisolated enum DebugLogLevel: String, CaseIterable, Sendable, Comparable, Codable {
    case trace = "TRACE"
    case debug = "DEBUG"
    case info = "INFO"
    case success = "OK"
    case warning = "WARN"
    case error = "ERR"
    case critical = "CRIT"

    nonisolated static func < (lhs: DebugLogLevel, rhs: DebugLogLevel) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    var sortOrder: Int {
        switch self {
        case .trace: 0
        case .debug: 1
        case .info: 2
        case .success: 3
        case .warning: 4
        case .error: 5
        case .critical: 6
        }
    }

    var emoji: String {
        switch self {
        case .trace: "🔍"
        case .debug: "🐛"
        case .info: "ℹ️"
        case .success: "✅"
        case .warning: "⚠️"
        case .error: "❌"
        case .critical: "🔴"
        }
    }
}

nonisolated struct ErrorHealingEvent: Identifiable, Sendable {
    let id: UUID = UUID()
    let timestamp: Date
    let category: DebugLogCategory
    let originalError: String
    let healingAction: String
    let succeeded: Bool
    let attemptNumber: Int
    let durationMs: Int?
}

nonisolated struct RetryState: Sendable {
    var attempts: Int = 0
    var maxAttempts: Int = 3
    var lastAttempt: Date?
    var lastError: String?
    var backoffMs: Int = 1000
    var isExhausted: Bool { attempts >= maxAttempts }

    mutating func recordAttempt(error: String?) {
        attempts += 1
        lastAttempt = Date()
        lastError = error
        backoffMs = min(backoffMs * 2, 30000)
    }

    mutating func reset() {
        attempts = 0
        lastError = nil
        backoffMs = 1000
    }
}

nonisolated struct DebugLogEntry: Identifiable, Sendable, Codable {
    let id: UUID
    let timestamp: Date
    let category: DebugLogCategory
    let level: DebugLogLevel
    let message: String
    let detail: String?
    let sessionId: String?
    let durationMs: Int?
    let metadata: [String: String]?

    init(
        category: DebugLogCategory,
        level: DebugLogLevel,
        message: String,
        detail: String? = nil,
        sessionId: String? = nil,
        durationMs: Int? = nil,
        metadata: [String: String]? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.category = category
        self.level = level
        self.message = message
        self.detail = detail
        self.sessionId = sessionId
        self.durationMs = durationMs
        self.metadata = metadata
    }

    var formattedTime: String {
        DateFormatters.timeWithMillis.string(from: timestamp)
    }

    var fullTimestamp: String {
        DateFormatters.fullTimestamp.string(from: timestamp)
    }

    var compactLine: String {
        let dur = durationMs.map { " [\($0)ms]" } ?? ""
        let sess = sessionId.map { " <\($0)>" } ?? ""
        return "[\(formattedTime)] [\(level.rawValue)] [\(category.rawValue)]\(sess)\(dur) \(message)"
    }

    var exportLine: String {
        let dur = durationMs.map { " duration=\($0)ms" } ?? ""
        let sess = sessionId.map { " session=\($0)" } ?? ""
        let det = detail.map { " | \($0)" } ?? ""
        let meta = metadata.map { dict in
            " {" + dict.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") + "}"
        } ?? ""
        return "[\(fullTimestamp)] [\(level.rawValue)] [\(category.rawValue)]\(sess)\(dur) \(message)\(det)\(meta)"
    }
}
