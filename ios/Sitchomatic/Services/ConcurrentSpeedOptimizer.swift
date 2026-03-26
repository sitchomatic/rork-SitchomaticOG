import Foundation

@MainActor
class ConcurrentSpeedOptimizer {
    static let shared = ConcurrentSpeedOptimizer()

    private let logger = DebugLogger.shared

    struct OptimizationResult {
        var optimalConcurrency: Int = 1
        var optimalStepDelayMs: Int = 1100
        var optimalTrialDelayMs: Int = 2000
        var estimatedThroughputPerMinute: Double = 0
        var testDurationMs: Int = 0
        var trialResults: [TrialResult] = []
    }

    struct TrialResult {
        let concurrency: Int
        let stepDelayMs: Int
        let successCount: Int
        let failureCount: Int
        let avgLatencyMs: Int
        let totalTimeMs: Int
        let throughputPerMinute: Double
        let errorRate: Double
    }

    nonisolated struct SpeedProfile: Codable, Sendable {
        var concurrency: Int
        var stepDelayMs: Int
        var trialDelayMs: Int
        var hardPauseMs: Int
        var tripleClickDelayMs: Int
        var postClickWaitMs: Int
        var lastOptimized: Date
        var throughputPerMinute: Double
    }

    private let profileKey = "speed_optimizer_profile_v1"

    func loadProfile() -> SpeedProfile? {
        guard let data = UserDefaults.standard.data(forKey: profileKey),
              let profile = try? JSONDecoder().decode(SpeedProfile.self, from: data) else { return nil }
        return profile
    }

    func saveProfile(_ profile: SpeedProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: profileKey)
        }
    }

    func runSpeedOptimization(
        engine: LoginAutomationEngine,
        testAttempts: [LoginAttempt],
        testURLs: [URL],
        currentSettings: AutomationSettings,
        onProgress: @escaping (String) -> Void
    ) async -> OptimizationResult {
        var result = OptimizationResult()
        let startTime = Date()
        var trials: [TrialResult] = []

        let concurrencyLevels = [1, 2, 3, 4, 5, 6, 8]
        let delayLevels = [1100, 900, 700, 500, 300]

        let testSubset = Array(testAttempts.prefix(min(4, testAttempts.count)))
        guard !testSubset.isEmpty, !testURLs.isEmpty else {
            onProgress("No test data available for optimization")
            return result
        }

        onProgress("Starting speed optimization with \(testSubset.count) test accounts...")

        for concurrency in concurrencyLevels {
            if concurrency > testSubset.count * 2 { continue }

            for delay in delayLevels {
                onProgress("Testing: concurrency=\(concurrency) stepDelay=\(delay)ms...")
                logger.log("SpeedOptimizer: trial concurrency=\(concurrency) delay=\(delay)ms", category: .automation, level: .info)

                let trialStart = Date()
                var successes = 0
                var failures = 0
                var latencies: [Int] = []

                let batchSize = min(concurrency, testSubset.count)
                let batch = Array(testSubset.prefix(batchSize))

                let batchResults: [(Bool, Int)] = await withTaskGroup(of: (Bool, Int).self) { group in
                    for (index, attempt) in batch.enumerated() {
                        let url = testURLs[index % testURLs.count]
                        group.addTask {
                            let taskStart = Date()
                            let outcome = await engine.runLoginTest(attempt, targetURL: url, timeout: TimeoutResolver.resolveAutomationTimeout(30))
                            let latency = Int(Date().timeIntervalSince(taskStart) * 1000)
                            let success = outcome == .success || outcome == .noAcc || outcome == .permDisabled || outcome == .tempDisabled
                            return (success, latency)
                        }
                    }
                    var results: [(Bool, Int)] = []
                    for await r in group { results.append(r) }
                    return results
                }

                for (success, latency) in batchResults {
                    if success { successes += 1 } else { failures += 1 }
                    latencies.append(latency)
                }

                let totalMs = Int(Date().timeIntervalSince(trialStart) * 1000)
                let avgLatency = latencies.isEmpty ? 0 : latencies.reduce(0, +) / latencies.count
                let total = successes + failures
                let errorRate = total > 0 ? Double(failures) / Double(total) : 1.0
                let throughput = totalMs > 0 ? Double(successes) / (Double(totalMs) / 60000.0) : 0

                let trial = TrialResult(
                    concurrency: concurrency,
                    stepDelayMs: delay,
                    successCount: successes,
                    failureCount: failures,
                    avgLatencyMs: avgLatency,
                    totalTimeMs: totalMs,
                    throughputPerMinute: throughput,
                    errorRate: errorRate
                )
                trials.append(trial)

                onProgress("  Result: \(successes)/\(total) success, \(avgLatency)ms avg, \(String(format: "%.1f", throughput))/min throughput")
                logger.log("SpeedOptimizer: trial result success=\(successes)/\(total) avgLatency=\(avgLatency)ms throughput=\(String(format: "%.1f", throughput))/min", category: .automation, level: .info)

                if errorRate > 0.7 && concurrency > 2 {
                    onProgress("  High error rate at concurrency=\(concurrency) — skipping higher")
                    break
                }
            }
        }

        result.trialResults = trials
        result.testDurationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        let validTrials = trials.filter { $0.errorRate < 0.5 }
        if let best = validTrials.max(by: { $0.throughputPerMinute < $1.throughputPerMinute }) {
            result.optimalConcurrency = best.concurrency
            result.optimalStepDelayMs = best.stepDelayMs
            result.optimalTrialDelayMs = max(500, best.stepDelayMs * 2)
            result.estimatedThroughputPerMinute = best.throughputPerMinute

            let profile = SpeedProfile(
                concurrency: best.concurrency,
                stepDelayMs: best.stepDelayMs,
                trialDelayMs: max(500, best.stepDelayMs * 2),
                hardPauseMs: max(2000, 4000 - (best.concurrency * 300)),
                tripleClickDelayMs: best.stepDelayMs,
                postClickWaitMs: max(1500, 2500 - (best.concurrency * 150)),
                lastOptimized: Date(),
                throughputPerMinute: best.throughputPerMinute
            )
            saveProfile(profile)

            onProgress("OPTIMAL: concurrency=\(best.concurrency) stepDelay=\(best.stepDelayMs)ms throughput=\(String(format: "%.1f", best.throughputPerMinute))/min")
            logger.log("SpeedOptimizer: OPTIMAL concurrency=\(best.concurrency) stepDelay=\(best.stepDelayMs)ms throughput=\(String(format: "%.1f", best.throughputPerMinute))/min", category: .automation, level: .success)
        } else {
            result.optimalConcurrency = 2
            result.optimalStepDelayMs = 1100
            result.optimalTrialDelayMs = 2000
            onProgress("No valid trials — using safe defaults: concurrency=2 stepDelay=1100ms")
        }

        return result
    }

    func applyProfileToSettings(_ settings: inout AutomationSettings) {
        guard let profile = loadProfile() else { return }
        settings.maxConcurrency = profile.concurrency
        settings.trueDetectionHardPauseMs = profile.hardPauseMs
        settings.trueDetectionTripleClickDelayMs = profile.tripleClickDelayMs
        settings.trueDetectionPostClickWaitMs = profile.postClickWaitMs
        logger.log("SpeedOptimizer: applied saved profile — concurrency=\(profile.concurrency) hardPause=\(profile.hardPauseMs)ms", category: .automation, level: .info)
    }
}
