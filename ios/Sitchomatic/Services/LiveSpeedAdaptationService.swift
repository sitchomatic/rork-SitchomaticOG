import Foundation

@MainActor
class LiveSpeedAdaptationService {
    static let shared = LiveSpeedAdaptationService()

    private let logger = DebugLogger.shared
    private let aiTiming = AITimingOptimizerService.shared
    private let persistenceKey = "live_speed_adaptation_v1"

    private var latencyWindow: [LatencySample] = []
    private let maxWindowSize: Int = 30
    private let fastLatencyThresholdMs: Int = 8000
    private let slowLatencyThresholdMs: Int = 25000
    private let verySlowLatencyThresholdMs: Int = 45000

    private(set) var currentSpeedMultiplier: Double = 1.0
    private(set) var currentConcurrencyRecommendation: Int?
    private(set) var adaptationCount: Int = 0
    private(set) var lastAdaptationReason: String = ""
    private(set) var isEnabled: Bool = true

    private let minMultiplier: Double = 0.3
    private let maxMultiplier: Double = 2.5
    private let smoothingFactor: Double = 0.15

    nonisolated struct LatencySample: Sendable {
        let timestampMs: Int
        let latencyMs: Int
        let success: Bool
        let wasTimeout: Bool
        let wasConnectionFailure: Bool
        let host: String
    }

    nonisolated struct SpeedRecommendation: Sendable {
        let multiplier: Double
        let concurrencyDelta: Int
        let reason: String
        let shouldApply: Bool

        var isSpeedUp: Bool { multiplier < 1.0 }
        var isSlowDown: Bool { multiplier > 1.0 }
    }

    nonisolated struct AdaptedDelays: Sendable {
        let pageStabilizationMs: Int
        let ajaxSettleMs: Int
        let domMutationMs: Int
        let animationSettleMs: Int
        let betweenAttemptsMs: Int
        let betweenCredentialsMs: Int
        let preNavigationMs: Int
        let postNavigationMs: Int
        let preTypingMs: Int
        let postTypingMs: Int
        let preSubmitMs: Int
        let postSubmitMs: Int
        let cooldownBetweenBatchesMs: Int
    }

    func recordLatency(
        latencyMs: Int,
        success: Bool,
        wasTimeout: Bool = false,
        wasConnectionFailure: Bool = false,
        host: String = ""
    ) {
        guard isEnabled else { return }

        let sample = LatencySample(
            timestampMs: Int(Date().timeIntervalSince1970 * 1000),
            latencyMs: latencyMs,
            success: success,
            wasTimeout: wasTimeout,
            wasConnectionFailure: wasConnectionFailure,
            host: host
        )
        latencyWindow.append(sample)
        if latencyWindow.count > maxWindowSize {
            latencyWindow.removeFirst(latencyWindow.count - maxWindowSize)
        }

        let recommendation = computeRecommendation()
        if recommendation.shouldApply {
            applyRecommendation(recommendation)
        }
    }

    func adaptedDelays(from settings: AutomationSettings) -> AdaptedDelays {
        let m = currentSpeedMultiplier
        return AdaptedDelays(
            pageStabilizationMs: clampDelay(Int(Double(settings.pageStabilizationDelayMs) * m), min: 200, max: 5000),
            ajaxSettleMs: clampDelay(Int(Double(settings.ajaxSettleDelayMs) * m), min: 200, max: 5000),
            domMutationMs: clampDelay(Int(Double(settings.domMutationSettleMs) * m), min: 100, max: 3000),
            animationSettleMs: clampDelay(Int(Double(settings.animationSettleDelayMs) * m), min: 100, max: 3000),
            betweenAttemptsMs: clampDelay(Int(Double(settings.betweenAttemptsDelayMs) * m), min: 200, max: 5000),
            betweenCredentialsMs: clampDelay(Int(Double(settings.betweenCredentialsDelayMs) * m), min: 150, max: 3000),
            preNavigationMs: clampDelay(Int(Double(settings.preNavigationDelayMs) * m), min: 50, max: 2000),
            postNavigationMs: clampDelay(Int(Double(settings.postNavigationDelayMs) * m), min: 100, max: 3000),
            preTypingMs: clampDelay(Int(Double(settings.preTypingDelayMs) * m), min: 50, max: 1500),
            postTypingMs: clampDelay(Int(Double(settings.postTypingDelayMs) * m), min: 50, max: 1500),
            preSubmitMs: clampDelay(Int(Double(settings.preSubmitDelayMs) * m), min: 50, max: 2000),
            postSubmitMs: clampDelay(Int(Double(settings.postSubmitDelayMs) * m), min: 100, max: 3000),
            cooldownBetweenBatchesMs: clampDelay(Int(Double(settings.sessionCooldownDelayMs) * m), min: 100, max: 5000)
        )
    }

    func adaptDelay(_ baseMs: Int) -> Int {
        guard isEnabled else { return baseMs }
        return clampDelay(Int(Double(baseMs) * currentSpeedMultiplier), min: max(30, baseMs / 5), max: baseMs * 4)
    }

    func reset() {
        latencyWindow.removeAll()
        currentSpeedMultiplier = 1.0
        currentConcurrencyRecommendation = nil
        adaptationCount = 0
        lastAdaptationReason = ""
        logger.log("LiveSpeed: RESET — multiplier back to 1.0x", category: .timing, level: .info)
    }

    func statusSummary() -> String {
        let avgLatency = averageLatencyMs()
        let successRate = recentSuccessRate()
        return "Speed: \(String(format: "%.2f", currentSpeedMultiplier))x | AvgLatency: \(avgLatency)ms | Success: \(Int(successRate * 100))% | Adaptations: \(adaptationCount)"
    }

    private func computeRecommendation() -> SpeedRecommendation {
        guard latencyWindow.count >= 3 else {
            return SpeedRecommendation(multiplier: 1.0, concurrencyDelta: 0, reason: "insufficient_data", shouldApply: false)
        }

        let recentSamples = Array(latencyWindow.suffix(10))
        let avgLatency = recentSamples.map(\.latencyMs).reduce(0, +) / recentSamples.count
        let successRate = Double(recentSamples.filter(\.success).count) / Double(recentSamples.count)
        let timeoutRate = Double(recentSamples.filter(\.wasTimeout).count) / Double(recentSamples.count)
        let connectionFailureRate = Double(recentSamples.filter(\.wasConnectionFailure).count) / Double(recentSamples.count)

        let olderSamples = Array(latencyWindow.prefix(max(1, latencyWindow.count - 10)))
        let olderAvgLatency = olderSamples.isEmpty ? avgLatency : olderSamples.map(\.latencyMs).reduce(0, +) / olderSamples.count
        let latencyTrend = olderAvgLatency > 0 ? Double(avgLatency) / Double(olderAvgLatency) : 1.0

        if connectionFailureRate > 0.5 {
            return SpeedRecommendation(
                multiplier: 2.0,
                concurrencyDelta: -2,
                reason: "high_connection_failures (\(Int(connectionFailureRate * 100))%)",
                shouldApply: true
            )
        }

        if timeoutRate > 0.4 {
            return SpeedRecommendation(
                multiplier: 1.8,
                concurrencyDelta: -1,
                reason: "high_timeout_rate (\(Int(timeoutRate * 100))%)",
                shouldApply: true
            )
        }

        if avgLatency > verySlowLatencyThresholdMs {
            return SpeedRecommendation(
                multiplier: 2.0,
                concurrencyDelta: -2,
                reason: "very_slow_latency (\(avgLatency)ms avg)",
                shouldApply: true
            )
        }

        if avgLatency > slowLatencyThresholdMs && successRate < 0.6 {
            return SpeedRecommendation(
                multiplier: 1.5,
                concurrencyDelta: -1,
                reason: "slow_latency_low_success (\(avgLatency)ms, \(Int(successRate * 100))%)",
                shouldApply: true
            )
        }

        if avgLatency > slowLatencyThresholdMs {
            return SpeedRecommendation(
                multiplier: 1.3,
                concurrencyDelta: 0,
                reason: "slow_latency (\(avgLatency)ms avg)",
                shouldApply: true
            )
        }

        if avgLatency < fastLatencyThresholdMs && successRate > 0.7 && latencyTrend <= 1.1 {
            return SpeedRecommendation(
                multiplier: 0.7,
                concurrencyDelta: 1,
                reason: "fast_responses (\(avgLatency)ms, \(Int(successRate * 100))% success)",
                shouldApply: true
            )
        }

        if avgLatency < fastLatencyThresholdMs / 2 && successRate > 0.85 {
            return SpeedRecommendation(
                multiplier: 0.5,
                concurrencyDelta: 1,
                reason: "very_fast_responses (\(avgLatency)ms, \(Int(successRate * 100))% success)",
                shouldApply: true
            )
        }

        if latencyTrend > 1.5 && avgLatency > fastLatencyThresholdMs {
            return SpeedRecommendation(
                multiplier: 1.2,
                concurrencyDelta: 0,
                reason: "latency_increasing (trend \(String(format: "%.1f", latencyTrend))x)",
                shouldApply: true
            )
        }

        if latencyTrend < 0.7 && successRate > 0.6 {
            return SpeedRecommendation(
                multiplier: 0.85,
                concurrencyDelta: 0,
                reason: "latency_decreasing (trend \(String(format: "%.1f", latencyTrend))x)",
                shouldApply: true
            )
        }

        return SpeedRecommendation(multiplier: 1.0, concurrencyDelta: 0, reason: "stable", shouldApply: false)
    }

    private func applyRecommendation(_ recommendation: SpeedRecommendation) {
        let previousMultiplier = currentSpeedMultiplier
        let blended = previousMultiplier * (1.0 - smoothingFactor) + (previousMultiplier * recommendation.multiplier) * smoothingFactor
        currentSpeedMultiplier = max(minMultiplier, min(maxMultiplier, blended))

        if recommendation.concurrencyDelta != 0 {
            currentConcurrencyRecommendation = recommendation.concurrencyDelta
        }

        adaptationCount += 1
        lastAdaptationReason = recommendation.reason

        let direction = currentSpeedMultiplier < previousMultiplier ? "FASTER" : (currentSpeedMultiplier > previousMultiplier ? "SLOWER" : "STABLE")
        logger.log(
            "LiveSpeed: \(direction) \(String(format: "%.2f", previousMultiplier))x → \(String(format: "%.2f", currentSpeedMultiplier))x | reason: \(recommendation.reason) | concurrency delta: \(recommendation.concurrencyDelta)",
            category: .timing,
            level: recommendation.isSlowDown ? .warning : .info
        )
    }

    private func averageLatencyMs() -> Int {
        guard !latencyWindow.isEmpty else { return 0 }
        return latencyWindow.map(\.latencyMs).reduce(0, +) / latencyWindow.count
    }

    private func recentSuccessRate() -> Double {
        let recent = Array(latencyWindow.suffix(10))
        guard !recent.isEmpty else { return 0 }
        return Double(recent.filter(\.success).count) / Double(recent.count)
    }

    private func clampDelay(_ value: Int, min minVal: Int, max maxVal: Int) -> Int {
        max(minVal, min(maxVal, value))
    }
}
