import Foundation

nonisolated enum KnowledgeDomain: String, Codable, Sendable, CaseIterable {
    case detection
    case timing
    case proxy
    case fingerprint
    case credential
    case rescue
    case anomaly
    case interaction
    case health
    case challenge
}

nonisolated enum KnowledgeEventType: String, Codable, Sendable {
    case threatSignal
    case performanceMetric
    case patternDiscovery
    case strategyOutcome
    case configRecommendation
    case anomalyAlert
    case rescueOutcome
    case correlationDiscovery
}

nonisolated enum KnowledgeSeverity: String, Codable, Sendable {
    case low
    case medium
    case high
    case critical
}

nonisolated struct KnowledgeEvent: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    let sourceService: String
    let host: String
    let domain: KnowledgeDomain
    let eventType: KnowledgeEventType
    let severity: KnowledgeSeverity
    let confidence: Double
    let payload: [String: String]
    let summary: String
    let timestamp: Date
    let expiresAt: Date

    var isExpired: Bool { Date() > expiresAt }

    var age: TimeInterval { Date().timeIntervalSince(timestamp) }

    var ageLabel: String {
        let mins = Int(age / 60)
        if mins < 1 { return "just now" }
        if mins < 60 { return "\(mins)m ago" }
        let hours = mins / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}

nonisolated struct KnowledgeCorrelation: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    let host: String
    let domainA: KnowledgeDomain
    let domainB: KnowledgeDomain
    let correlationScore: Double
    let description: String
    let sampleSize: Int
    let discoveredAt: Date
    let lastConfirmed: Date

    var isStrong: Bool { correlationScore >= 0.7 }
    var isModerate: Bool { correlationScore >= 0.4 && correlationScore < 0.7 }
}

nonisolated struct UnifiedHostIntelligence: Codable, Sendable {
    var host: String
    var detectionThreatLevel: Double = 0
    var detectionTrend: String = "stable"
    var topDetectionSignals: [String] = []
    var activeStrategies: [String] = []

    var bestProxyIds: [String] = []
    var proxyBlockRate: Double = 0
    var proxyAvgLatencyMs: Int = 0

    var timingProfile: TimingSummary = TimingSummary()
    var timingDetectionRate: Double = 0

    var preferredFingerprintIndices: [Int] = []
    var fingerprintDetectionRate: Double = 0
    var fingerprintTopSignals: [String] = []

    var credentialDomainSuccessRate: Double = 0
    var credentialExhaustedDomains: [String] = []
    var credentialHighValueDomains: [String] = []

    var rescueSuccessRate: Double = 0
    var rescueAttempts: Int = 0
    var commonRescueOutcomes: [String] = []

    var anomalyRiskLevel: Double = 0
    var anomalyForecast: String = "stable"
    var anomalyAlerts: [String] = []

    var interactionBestPattern: String?
    var interactionSuccessRate: Double = 0

    var overallDifficultyScore: Double = 0
    var lastComputed: Date = .distantPast
    var eventCount: Int = 0
    var correlations: [KnowledgeCorrelation] = []

    nonisolated struct TimingSummary: Codable, Sendable {
        var optimalKeystrokeMs: Int = 80
        var optimalInterFieldMs: Int = 350
        var optimalPreSubmitMs: Int = 500
        var fillRate: Double = 0
    }

    var isStale: Bool { Date().timeIntervalSince(lastComputed) > 300 }

    var threatDescription: String {
        if detectionThreatLevel >= 0.8 { return "Critical" }
        if detectionThreatLevel >= 0.6 { return "High" }
        if detectionThreatLevel >= 0.4 { return "Moderate" }
        if detectionThreatLevel >= 0.2 { return "Low" }
        return "Minimal"
    }

    var difficultyDescription: String {
        if overallDifficultyScore >= 0.8 { return "Extreme" }
        if overallDifficultyScore >= 0.6 { return "Hard" }
        if overallDifficultyScore >= 0.4 { return "Medium" }
        if overallDifficultyScore >= 0.2 { return "Easy" }
        return "Trivial"
    }
}

nonisolated struct KnowledgeGraphStore: Codable, Sendable {
    var events: [KnowledgeEvent] = []
    var correlations: [KnowledgeCorrelation] = []
    var hostIntelligenceCache: [String: UnifiedHostIntelligence] = [:]
    var totalEventsPublished: Int = 0
    var lastPruneDate: Date = .distantPast
    var lastCorrelationAnalysis: Date = .distantPast
}
