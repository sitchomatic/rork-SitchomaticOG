import Foundation

nonisolated struct SignalClassification: Sendable {
    let signalType: AutopilotSignalType
    let severity: Double
    let category: SignalCategory
    let isPreemptive: Bool
    let relatedSignals: [AutopilotSignalType]
    let decayRatePerSecond: Double
}

nonisolated enum SignalCategory: String, Sendable {
    case detection
    case performance
    case challenge
    case network
    case behavioral
    case fingerprint
    case informational
}

@MainActor
class AutopilotSignalProcessor {

    private var signalWeights: [AutopilotSignalType: Double] = [
        .challengeFormingDetected: 0.95,
        .captchaFormingDetected: 0.92,
        .webDriverProbeDetected: 0.90,
        .fingerprintProbeDetected: 0.85,
        .canvasProbeDetected: 0.80,
        .rateLimitSignal: 0.88,
        .typingVelocityAnomaly: 0.70,
        .timingAnomalyDetected: 0.65,
        .blankPageDetected: 0.75,
        .connectionDegraded: 0.55,
        .proxyLatencySpike: 0.60,
        .httpStatusAnomaly: 0.50,
        .redirectDetected: 0.40,
        .cookieBombDetected: 0.72,
        .sessionHealthDegraded: 0.68,
        .jsErrorDetected: 0.35,
        .domMutation: 0.15,
        .networkRequestFired: 0.10,
        .networkResponseReceived: 0.12,
        .pageLoadStarted: 0.05,
        .pageLoadComplete: 0.08,
    ]

    private let categoryMap: [AutopilotSignalType: SignalCategory] = [
        .challengeFormingDetected: .challenge,
        .captchaFormingDetected: .challenge,
        .rateLimitSignal: .challenge,
        .webDriverProbeDetected: .detection,
        .fingerprintProbeDetected: .fingerprint,
        .canvasProbeDetected: .fingerprint,
        .cookieBombDetected: .fingerprint,
        .typingVelocityAnomaly: .behavioral,
        .timingAnomalyDetected: .behavioral,
        .blankPageDetected: .performance,
        .connectionDegraded: .network,
        .proxyLatencySpike: .network,
        .httpStatusAnomaly: .network,
        .redirectDetected: .network,
        .sessionHealthDegraded: .performance,
        .jsErrorDetected: .performance,
        .domMutation: .informational,
        .networkRequestFired: .informational,
        .networkResponseReceived: .informational,
        .pageLoadStarted: .informational,
        .pageLoadComplete: .informational,
    ]

    private let preemptiveSignals: Set<AutopilotSignalType> = [
        .challengeFormingDetected,
        .captchaFormingDetected,
        .fingerprintProbeDetected,
        .canvasProbeDetected,
        .webDriverProbeDetected,
        .cookieBombDetected,
        .typingVelocityAnomaly,
    ]

    func classify(signal: AutopilotSignal, sessionState: AutopilotSessionState, mode: AutopilotMode) -> SignalClassification {
        let baseWeight = signalWeights[signal.type] ?? 0.3
        let category = categoryMap[signal.type] ?? .informational
        let isPreemptive = preemptiveSignals.contains(signal.type)

        var severity = baseWeight * signal.confidence

        let recentSameType = sessionState.signalHistory.suffix(20).filter { $0.type == signal.type }
        if recentSameType.count >= 3 {
            let burstMultiplier = min(2.0, 1.0 + Double(recentSameType.count - 2) * 0.25)
            severity *= burstMultiplier
        }

        if sessionState.threatLevel > 0.6 {
            severity *= 1.3
        }

        switch mode {
        case .aggressive: severity *= 1.4
        case .active: severity *= 1.0
        case .passive: severity *= 0.6
        case .off: severity = 0
        }

        severity = min(1.0, severity)

        let related = findRelatedSignals(for: signal.type)
        let decayRate = computeDecayRate(for: signal.type)

        return SignalClassification(
            signalType: signal.type,
            severity: severity,
            category: category,
            isPreemptive: isPreemptive,
            relatedSignals: related,
            decayRatePerSecond: decayRate
        )
    }

    func computeThreatLevel(for state: AutopilotSessionState) -> Double {
        let now = Date()
        var weightedSum = 0.0
        var totalWeight = 0.0

        for signal in state.signalHistory.suffix(50) {
            let age = now.timeIntervalSince(signal.timestamp)
            let decay = exp(-age / 30.0)
            let weight = (signalWeights[signal.type] ?? 0.2) * signal.confidence * decay
            weightedSum += weight
            totalWeight += 1.0
        }

        guard totalWeight > 0 else { return 0 }

        let rawThreat = weightedSum / max(totalWeight, 5.0)

        let recentHighPriority = state.signalHistory.suffix(10).filter {
            (signalWeights[$0.type] ?? 0) >= 0.7
        }.count
        let burstBonus = min(0.3, Double(recentHighPriority) * 0.06)

        let interventionDamping = state.totalInterventions > 5 ? min(0.15, Double(state.totalInterventions) * 0.02) : 0

        return min(1.0, max(0, rawThreat + burstBonus - interventionDamping))
    }

    func signalBurstDetected(in state: AutopilotSessionState, windowSeconds: Double = 5.0, threshold: Int = 4) -> (detected: Bool, signalType: AutopilotSignalType?, count: Int) {
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        let recentHighSignals = state.signalHistory.filter {
            $0.timestamp > cutoff && (signalWeights[$0.type] ?? 0) >= 0.6
        }

        guard recentHighSignals.count >= threshold else {
            return (false, nil, recentHighSignals.count)
        }

        var typeCounts: [AutopilotSignalType: Int] = [:]
        for s in recentHighSignals {
            typeCounts[s.type, default: 0] += 1
        }
        let dominant = typeCounts.max(by: { $0.value < $1.value })

        return (true, dominant?.key, recentHighSignals.count)
    }

    func updateWeight(for signalType: AutopilotSignalType, delta: Double) {
        let current = signalWeights[signalType] ?? 0.3
        signalWeights[signalType] = max(0.05, min(1.0, current + delta))
    }

    private func findRelatedSignals(for type: AutopilotSignalType) -> [AutopilotSignalType] {
        switch type {
        case .challengeFormingDetected:
            return [.captchaFormingDetected, .rateLimitSignal, .httpStatusAnomaly]
        case .fingerprintProbeDetected:
            return [.canvasProbeDetected, .webDriverProbeDetected, .cookieBombDetected]
        case .webDriverProbeDetected:
            return [.fingerprintProbeDetected, .timingAnomalyDetected]
        case .typingVelocityAnomaly:
            return [.timingAnomalyDetected, .webDriverProbeDetected]
        case .rateLimitSignal:
            return [.httpStatusAnomaly, .connectionDegraded, .challengeFormingDetected]
        case .blankPageDetected:
            return [.connectionDegraded, .jsErrorDetected, .sessionHealthDegraded]
        case .proxyLatencySpike:
            return [.connectionDegraded, .blankPageDetected]
        default:
            return []
        }
    }

    private func computeDecayRate(for type: AutopilotSignalType) -> Double {
        let weight = signalWeights[type] ?? 0.3
        if weight >= 0.8 { return 0.02 }
        if weight >= 0.5 { return 0.05 }
        return 0.10
    }
}
