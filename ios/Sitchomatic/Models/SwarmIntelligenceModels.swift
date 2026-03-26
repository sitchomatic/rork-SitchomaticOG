import Foundation

nonisolated enum SwarmSignalType: String, Codable, Sendable, CaseIterable {
    case proxyQuality
    case timingDiscovery
    case fingerprintResult
    case detectionAlert
    case challengeEncountered
    case rateLimitHit
    case successPattern
    case failurePattern
    case hostDifficultyUpdate
    case strategyRecommendation
}

nonisolated enum SwarmSignalPriority: String, Codable, Sendable {
    case low
    case normal
    case high
    case urgent

    var weight: Double {
        switch self {
        case .low: return 0.5
        case .normal: return 1.0
        case .high: return 1.5
        case .urgent: return 2.0
        }
    }
}

nonisolated struct SwarmSignal: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    let sessionId: String
    let host: String
    let signalType: SwarmSignalType
    let priority: SwarmSignalPriority
    let payload: [String: String]
    let confidence: Double
    let timestamp: Date
    let ttlSeconds: TimeInterval

    var isExpired: Bool { Date().timeIntervalSince(timestamp) > ttlSeconds }
}

nonisolated enum SessionRole: String, Codable, Sendable, CaseIterable {
    case scout
    case worker
    case validator

    var description: String {
        switch self {
        case .scout: return "Tests new strategies and reports findings"
        case .worker: return "Executes proven strategies at scale"
        case .validator: return "Confirms results and detects regressions"
        }
    }

    var icon: String {
        switch self {
        case .scout: return "binoculars.fill"
        case .worker: return "hammer.fill"
        case .validator: return "checkmark.seal.fill"
        }
    }
}

nonisolated struct SessionStrategyProfile: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    let sessionId: String
    var host: String
    var role: SessionRole
    var assignedAt: Date = Date()

    var preferredProxyIds: [String] = []
    var optimalKeystrokeMs: Int = 80
    var optimalInterFieldMs: Int = 350
    var optimalPreSubmitMs: Int = 500
    var preferredFingerprintIndex: Int = 0

    var successCount: Int = 0
    var failureCount: Int = 0
    var totalAttempts: Int = 0
    var avgLatencyMs: Int = 0
    var detectionEvents: Int = 0

    var successRate: Double {
        guard totalAttempts > 0 else { return 0 }
        return Double(successCount) / Double(totalAttempts)
    }

    var effectivenessScore: Double {
        let rateScore = successRate * 0.6
        let latencyScore = max(0, 1.0 - Double(avgLatencyMs) / 10000.0) * 0.2
        let detectionPenalty = min(1.0, Double(detectionEvents) / 10.0) * 0.2
        return rateScore + latencyScore - detectionPenalty
    }

    mutating func recordOutcome(success: Bool, latencyMs: Int) {
        totalAttempts += 1
        if success { successCount += 1 } else { failureCount += 1 }
        let total = Double(totalAttempts)
        avgLatencyMs = Int((Double(avgLatencyMs) * (total - 1) + Double(latencyMs)) / total)
    }
}

nonisolated struct SwarmStrategyVote: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    let sessionId: String
    let host: String
    let strategyKey: String
    let strategyValue: String
    let confidence: Double
    let evidence: String
    let timestamp: Date
}

nonisolated struct SwarmConsensus: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    let host: String
    let strategyKey: String
    let consensusValue: String
    let agreementRate: Double
    let voterCount: Int
    let confidence: Double
    let decidedAt: Date

    var isStrong: Bool { agreementRate >= 0.7 && voterCount >= 2 }
}

nonisolated struct SwarmCoordinationState: Codable, Sendable {
    var activeProfiles: [SessionStrategyProfile] = []
    var pendingSignals: [SwarmSignal] = []
    var recentVotes: [SwarmStrategyVote] = []
    var consensusHistory: [SwarmConsensus] = []
    var totalSignalsBroadcast: Int = 0
    var totalConsensusReached: Int = 0
    var lastCoordinationCycle: Date = .distantPast

    let maxPendingSignals: Int = 500
    let maxVotes: Int = 200
    let maxConsensusHistory: Int = 100
    let maxProfiles: Int = 20
}
