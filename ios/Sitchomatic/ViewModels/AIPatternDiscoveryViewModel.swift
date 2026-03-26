import Foundation
import Observation

@Observable
class AIPatternDiscoveryViewModel {
    var isLoading: Bool = false
    var isGeneratingInsight: Bool = false
    var aiInsight: String?

    struct HostComboProfile {
        let host: String
        let bestPattern: String?
        let bestProxyType: String?
        let successRate: Double
        let convergenceConfidence: Double
        let dataPoints: Int
        let avgLatencyMs: Int
        let detectionRate: Double
        let timingProfile: TimingProfile?
        let aiOptimized: Bool
    }

    struct HourBucket {
        let hour: Int
        let successCount: Int
        let failureCount: Int
        let totalCount: Int
        var successRate: Double { totalCount > 0 ? Double(successCount) / Double(totalCount) : 0 }
    }

    struct ProxyTrendPoint {
        let proxyIdShort: String
        let host: String
        let successRate: Double
        let blockRate: Double
        let avgLatencyMs: Int
        let sampleCount: Int
        let compositeScore: Double
        let isCoolingDown: Bool
        let hasAIWeight: Bool
    }

    struct ConvergenceItem {
        let host: String
        let converged: Bool
        let dataPoints: Int
        let confidence: Double
        let topPattern: String?
        let recipeActions: Int
        let aiOptimized: Bool
        let aiReasoning: String?
    }

    struct PatternLearningItem {
        let host: String
        let pattern: String
        let score: Double
        let fillRate: Double
        let submitRate: Double
        let loginRate: Double
        let weight: Double
        let attempts: Int
    }

    func buildHostCombos() -> [HostComboProfile] {
        let interactionGraph = AIReinforcementInteractionGraph.shared
        let proxyStrategy = AIProxyStrategyService.shared
        let timingService = AITimingOptimizerService.shared
        let fingerprintLearning = HostFingerprintLearningService.shared

        let hostStats = interactionGraph.hostStats()
        let timingProfiles = timingService.allProfiles()
        let proxyHostStats = proxyStrategy.allHostStats()

        var hosts = Set<String>()
        for stat in hostStats { hosts.insert(stat.host) }
        for stat in proxyHostStats { hosts.insert(stat.host) }
        for key in timingProfiles.keys { hosts.insert(key) }

        return hosts.map { host in
            let conv = interactionGraph.convergenceLevel(for: host)
            let recipe = interactionGraph.getRecipe(for: host)
            let timing = timingProfiles[host]
            let fingerprint = fingerprintLearning.signatureFor(host)
            let proxyStats = proxyHostStats.first { $0.host == host }

            return HostComboProfile(
                host: host,
                bestPattern: fingerprint?.bestPattern ?? interactionGraph.recommendPatternOrder(for: host)?.first,
                bestProxyType: nil,
                successRate: conv.confidence,
                convergenceConfidence: conv.confidence,
                dataPoints: conv.dataPoints,
                avgLatencyMs: proxyStats.map { _ in 0 } ?? 0,
                detectionRate: timing?.detectionRate ?? 0,
                timingProfile: timing,
                aiOptimized: recipe?.aiOptimized ?? false
            )
        }
        .sorted { $0.dataPoints > $1.dataPoints }
    }

    func buildTimeOfDayHeatmap() -> [HourBucket] {
        let interactionGraph = AIReinforcementInteractionGraph.shared
        let allStats = interactionGraph.hostStats()

        var buckets = (0..<24).map { HourBucket(hour: $0, successCount: 0, failureCount: 0, totalCount: 0) }

        let telemetry = BatchTelemetryService.shared
        for record in telemetry.batchRecords {
            let hour = Calendar.current.component(.hour, from: record.startedAt)
            let old = buckets[hour]
            buckets[hour] = HourBucket(
                hour: hour,
                successCount: old.successCount + record.successCount,
                failureCount: old.failureCount + record.failureCount,
                totalCount: old.totalCount + record.processedItems
            )
        }

        _ = allStats
        return buckets
    }

    func buildProxyTrends() -> [ProxyTrendPoint] {
        let proxyStrategy = AIProxyStrategyService.shared
        let allStats = proxyStrategy.allHostStats()

        var trends: [ProxyTrendPoint] = []
        for stat in allStats {
            let perfSummary = proxyStrategy.proxyPerformanceSummary(for: stat.host)
            for perf in perfSummary.prefix(5) {
                trends.append(ProxyTrendPoint(
                    proxyIdShort: String(perf.proxyId.prefix(8)),
                    host: stat.host,
                    successRate: Double(perf.successRate) / 100.0,
                    blockRate: 0,
                    avgLatencyMs: perf.avgLatency,
                    sampleCount: stat.totalSamples,
                    compositeScore: perf.score,
                    isCoolingDown: false,
                    hasAIWeight: perf.score > 0.7
                ))
            }
        }

        return trends.sorted { $0.compositeScore > $1.compositeScore }
    }

    func buildConvergenceItems() -> [ConvergenceItem] {
        let interactionGraph = AIReinforcementInteractionGraph.shared
        let hostStats = interactionGraph.hostStats()
        let recipes = interactionGraph.allRecipes()
        let recipeMap = Dictionary(uniqueKeysWithValues: recipes.map { ($0.host, $0) })

        return hostStats.map { stat in
            let recipe = recipeMap[stat.host]
            return ConvergenceItem(
                host: stat.host,
                converged: stat.converged,
                dataPoints: stat.sequences,
                confidence: stat.confidence,
                topPattern: stat.topPattern,
                recipeActions: recipe?.recommendedActions.count ?? 0,
                aiOptimized: recipe?.aiOptimized ?? false,
                aiReasoning: recipe?.aiReasoning
            )
        }
        .sorted { $0.confidence > $1.confidence }
    }

    func buildPatternLearningItems() -> [PatternLearningItem] {
        let fingerprints = HostFingerprintLearningService.shared.allSignatures()
        var items: [PatternLearningItem] = []

        for sig in fingerprints {
            for (pattern, score) in sig.matchedPatterns {
                items.append(PatternLearningItem(
                    host: sig.host,
                    pattern: pattern,
                    score: Double(score),
                    fillRate: 0,
                    submitRate: 0,
                    loginRate: 0,
                    weight: Double(max(0, score)),
                    attempts: sig.captureCount
                ))
            }
        }

        return items.sorted { $0.score > $1.score }
    }

    func requestAIPatternInsight() async {
        isGeneratingInsight = true
        defer { isGeneratingInsight = false }

        let combos = buildHostCombos()
        let convergence = buildConvergenceItems()
        let trends = buildProxyTrends()
        let heatmap = buildTimeOfDayHeatmap().filter { $0.totalCount > 0 }

        var payload: [String: Any] = [
            "totalHosts": combos.count,
            "convergedHosts": convergence.filter(\.converged).count,
            "aiOptimizedHosts": combos.filter(\.aiOptimized).count,
            "avgConfidence": combos.isEmpty ? 0 : String(format: "%.0f%%", combos.map(\.convergenceConfidence).reduce(0, +) / Double(combos.count) * 100),
            "proxyTrendsCount": trends.count,
        ]

        if !combos.isEmpty {
            payload["topHosts"] = combos.prefix(5).map { [
                "host": $0.host,
                "successRate": String(format: "%.0f%%", $0.successRate * 100),
                "detectionRate": String(format: "%.0f%%", $0.detectionRate * 100),
                "dataPoints": $0.dataPoints,
                "aiOptimized": $0.aiOptimized,
                "bestPattern": $0.bestPattern ?? "none",
            ] as [String: Any] }
        }

        if !heatmap.isEmpty {
            let bestHour = heatmap.max(by: { $0.successRate < $1.successRate })
            let worstHour = heatmap.filter { $0.totalCount >= 3 }.min(by: { $0.successRate < $1.successRate })
            payload["bestHour"] = bestHour.map { "\($0.hour):00 (\(Int($0.successRate * 100))% success)" } ?? "insufficient data"
            payload["worstHour"] = worstHour.map { "\($0.hour):00 (\(Int($0.successRate * 100))% success)" } ?? "insufficient data"
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

        let systemPrompt = """
        You analyze AI pattern discovery data for a web automation system. \
        Provide actionable insights about: 1) Which host/setting combos are converging best, \
        2) Time-of-day optimization opportunities, 3) Proxy quality trends, \
        4) Which patterns the AI should explore vs exploit. \
        Be specific with numbers. Use bullet points. Under 250 words. No markdown headers or code blocks.
        """

        let userPrompt = "Pattern discovery data:\n\(jsonStr)"

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: userPrompt) else {
            aiInsight = "Unable to generate insight — check network."
            return
        }

        aiInsight = response
    }
}
