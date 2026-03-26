import Foundation

nonisolated enum AdversarialScenarioType: String, Codable, Sendable, CaseIterable {
    case timingDetection
    case fingerprintDetection
    case proxyBlocking
    case challengePage
    case rateLimiting
    case behavioralAnalysis
    case headerInspection
    case cookieTracking
    case jsEnvironmentProbe
    case compositeDefense
}

nonisolated enum AdversarialDifficulty: String, Codable, Sendable, CaseIterable {
    case basic
    case intermediate
    case advanced
    case expert

    var multiplier: Double {
        switch self {
        case .basic: return 1.0
        case .intermediate: return 1.5
        case .advanced: return 2.0
        case .expert: return 3.0
        }
    }

    var label: String { rawValue.capitalized }
}

nonisolated struct AdversarialScenario: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    let type: AdversarialScenarioType
    let difficulty: AdversarialDifficulty
    let name: String
    let description: String
    let expectedSignals: [String]
    let thresholds: ScenarioThresholds
    let weight: Double

    nonisolated struct ScenarioThresholds: Codable, Sendable {
        let maxAcceptableDetectionRate: Double
        let minRequiredEvasionScore: Double
        let maxLatencyMs: Int
        let maxRetries: Int
    }
}

nonisolated enum SimulationVerdict: String, Codable, Sendable {
    case passed
    case marginal
    case failed
    case critical

    var icon: String {
        switch self {
        case .passed: return "checkmark.shield.fill"
        case .marginal: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.shield.fill"
        case .critical: return "bolt.shield.fill"
        }
    }

    var label: String { rawValue.capitalized }
}

nonisolated struct SimulationResult: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    let scenarioId: String
    let scenarioType: AdversarialScenarioType
    let scenarioName: String
    let difficulty: AdversarialDifficulty
    let verdict: SimulationVerdict
    let detectedSignals: [String]
    let evasionScore: Double
    let detectionRate: Double
    let latencyMs: Int
    let retryCount: Int
    let recommendations: [SimulationRecommendation]
    let timestamp: Date
    let durationMs: Int
    let host: String

    var isHealthy: Bool { verdict == .passed || verdict == .marginal }
}

nonisolated struct SimulationRecommendation: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    let domain: String
    let action: String
    let priority: RecommendationPriority
    let settingKey: String?
    let suggestedValue: String?

    nonisolated enum RecommendationPriority: String, Codable, Sendable {
        case low
        case medium
        case high
        case critical
    }
}

nonisolated struct SimulationSuite: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    let host: String
    let difficulty: AdversarialDifficulty
    let results: [SimulationResult]
    let overallScore: Double
    let overallVerdict: SimulationVerdict
    let timestamp: Date
    let durationMs: Int
    let scenariosRun: Int
    let scenariosPassed: Int

    var passRate: Double {
        guard scenariosRun > 0 else { return 0 }
        return Double(scenariosPassed) / Double(scenariosRun)
    }
}

nonisolated struct AdversarialSimulationStore: Codable, Sendable {
    var suites: [SimulationSuite] = []
    var lastRunPerHost: [String: Date] = [:]
    var totalSimulationsRun: Int = 0
    var autoHealingActions: [AutoHealingAction] = []
    let maxStoredSuites: Int = 50
}

nonisolated struct AutoHealingAction: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    let host: String
    let scenarioType: AdversarialScenarioType
    let settingKey: String
    let oldValue: String
    let newValue: String
    let reason: String
    let timestamp: Date
    var reverted: Bool = false
}
