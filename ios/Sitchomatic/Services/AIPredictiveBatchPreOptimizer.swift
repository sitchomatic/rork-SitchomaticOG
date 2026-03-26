import Foundation
import UIKit

nonisolated struct BatchPreOptimizationReport: Sendable {
    let timestamp: Date
    let credentialCount: Int
    let urlCount: Int
    let proxyTarget: String

    let recommendedConcurrency: Int
    let recommendedTimeout: TimeInterval
    let recommendedStealthEnabled: Bool
    let recommendedRetryOnFail: Bool

    let proxyPoolHealth: Double
    let urlPoolHealth: Double
    let credentialQualityScore: Double
    let timeOfDayScore: Double
    let memoryPressureScore: Double
    let estimatedSuccessRate: Double
    let estimatedDurationMinutes: Double

    let urlRankings: [(url: String, score: Double, reason: String)]
    let proxyWarnings: [String]
    let credentialInsights: [String]
    let strategicRecommendations: [String]

    let overallReadiness: BatchReadiness
    let readinessScore: Double
}

nonisolated enum BatchReadiness: String, Sendable {
    case optimal
    case good
    case acceptable
    case degraded
    case risky
}

nonisolated struct TimeOfDayPattern: Codable, Sendable {
    var hourBuckets: [Int: HourBucket] = [:]

    struct HourBucket: Codable, Sendable {
        var successCount: Int = 0
        var failureCount: Int = 0
        var totalLatencyMs: Int = 0
        var challengeCount: Int = 0
        var batchCount: Int = 0

        var successRate: Double {
            let total = successCount + failureCount
            guard total > 0 else { return 0.5 }
            return Double(successCount) / Double(total)
        }

        var avgLatencyMs: Int {
            guard batchCount > 0 else { return 5000 }
            return totalLatencyMs / max(1, successCount + failureCount)
        }

        var challengeRate: Double {
            let total = successCount + failureCount
            guard total > 0 else { return 0 }
            return Double(challengeCount) / Double(total)
        }
    }
}

nonisolated struct PreOptimizerStore: Codable, Sendable {
    var timePatterns: TimeOfDayPattern = TimeOfDayPattern()
    var hostPerformanceHistory: [String: HostPerformanceSnapshot] = [:]
    var totalBatchesAnalyzed: Int = 0
    var totalAIAnalyses: Int = 0
    var lastAIAnalysis: Date = .distantPast

    struct HostPerformanceSnapshot: Codable, Sendable {
        var host: String
        var recentSuccessRate: Double = 0.5
        var recentAvgLatencyMs: Int = 5000
        var recentChallengeRate: Double = 0
        var bestConcurrency: Int = 4
        var bestTimeOfDay: Int?
        var lastUpdated: Date = .distantPast
    }
}

@MainActor
class AIPredictiveBatchPreOptimizer {
    static let shared = AIPredictiveBatchPreOptimizer()

    private let logger = DebugLogger.shared
    private let urlQuality = URLQualityScoringService.shared
    private let proxyQuality = ProxyQualityDecayService.shared
    private let credentialPriority = AICredentialPriorityScoringService.shared
    private let concurrencyGovernor = AIPredictiveConcurrencyGovernor.shared
    private let persistKey = "AIPredictiveBatchPreOptimizer_v1"

    private(set) var store: PreOptimizerStore
    private(set) var lastReport: BatchPreOptimizationReport?

    private init() {
        if let saved = UserDefaults.standard.data(forKey: persistKey),
           let decoded = try? JSONDecoder().decode(PreOptimizerStore.self, from: saved) {
            self.store = decoded
        } else {
            self.store = PreOptimizerStore()
        }
    }

    func generatePreBatchReport(
        credentials: [LoginCredential],
        urls: [URL],
        proxyTarget: ProxyRotationService.ProxyTarget,
        currentConcurrency: Int,
        currentTimeout: TimeInterval,
        stealthEnabled: Bool
    ) async -> BatchPreOptimizationReport {
        let proxyHealth = await assessProxyPoolHealth(target: proxyTarget)
        let urlHealth = await assessURLPoolHealth(urls: urls)
        let credQuality = assessCredentialQuality(credentials: credentials)
        let todScore = assessTimeOfDay()
        let memoryScore = assessMemoryPressure()

        let urlRankings = await rankURLs(urls: urls)
        let proxyWarnings = generateProxyWarnings(target: proxyTarget, health: proxyHealth)
        let credInsights = generateCredentialInsights(credentials: credentials)

        let recConcurrency = recommendConcurrency(
            credentialCount: credentials.count,
            urlHealth: urlHealth,
            proxyHealth: proxyHealth,
            memoryScore: memoryScore,
            currentConcurrency: currentConcurrency
        )
        let recTimeout = recommendTimeout(urlHealth: urlHealth, proxyHealth: proxyHealth, currentTimeout: currentTimeout)
        let recStealth = recommendStealth(proxyHealth: proxyHealth, todScore: todScore, stealthEnabled: stealthEnabled)
        let recRetry = recommendRetry(urlHealth: urlHealth, proxyHealth: proxyHealth)

        let readinessScore = computeReadinessScore(
            proxyHealth: proxyHealth,
            urlHealth: urlHealth,
            credQuality: credQuality,
            todScore: todScore,
            memoryScore: memoryScore
        )

        let readiness: BatchReadiness
        if readinessScore >= 0.8 { readiness = .optimal }
        else if readinessScore >= 0.65 { readiness = .good }
        else if readinessScore >= 0.5 { readiness = .acceptable }
        else if readinessScore >= 0.35 { readiness = .degraded }
        else { readiness = .risky }

        let estSuccessRate = estimateSuccessRate(
            proxyHealth: proxyHealth, urlHealth: urlHealth,
            credQuality: credQuality, todScore: todScore
        )
        let estDuration = estimateDuration(
            credentialCount: credentials.count,
            concurrency: recConcurrency,
            avgTimeout: recTimeout,
            urlHealth: urlHealth
        )

        var recommendations = generateStrategicRecommendations(
            readiness: readiness,
            proxyHealth: proxyHealth,
            urlHealth: urlHealth,
            credQuality: credQuality,
            todScore: todScore,
            memoryScore: memoryScore,
            credentialCount: credentials.count
        )

        if shouldRequestAIAnalysis(credentialCount: credentials.count, readinessScore: readinessScore) {
            let aiRecs = await requestAIPreBatchAnalysis(
                credentialCount: credentials.count,
                urlCount: urls.count,
                proxyTarget: proxyTarget.rawValue,
                proxyHealth: proxyHealth,
                urlHealth: urlHealth,
                credQuality: credQuality,
                todScore: todScore,
                readinessScore: readinessScore,
                urlRankings: urlRankings
            )
            recommendations.append(contentsOf: aiRecs)
        }

        let report = BatchPreOptimizationReport(
            timestamp: Date(),
            credentialCount: credentials.count,
            urlCount: urls.count,
            proxyTarget: proxyTarget.rawValue,
            recommendedConcurrency: recConcurrency,
            recommendedTimeout: recTimeout,
            recommendedStealthEnabled: recStealth,
            recommendedRetryOnFail: recRetry,
            proxyPoolHealth: proxyHealth,
            urlPoolHealth: urlHealth,
            credentialQualityScore: credQuality,
            timeOfDayScore: todScore,
            memoryPressureScore: memoryScore,
            estimatedSuccessRate: estSuccessRate,
            estimatedDurationMinutes: estDuration,
            urlRankings: urlRankings,
            proxyWarnings: proxyWarnings,
            credentialInsights: credInsights,
            strategicRecommendations: recommendations,
            overallReadiness: readiness,
            readinessScore: readinessScore
        )

        lastReport = report
        store.totalBatchesAnalyzed += 1
        save()

        logger.log("BatchPreOptimizer: report generated — readiness=\(readiness.rawValue) score=\(String(format: "%.0f%%", readinessScore * 100)) recConcurrency=\(recConcurrency) estSuccess=\(String(format: "%.0f%%", estSuccessRate * 100))", category: .automation, level: .info)

        return report
    }

    func recordBatchOutcome(
        host: String,
        successRate: Double,
        avgLatencyMs: Int,
        challengeRate: Double,
        concurrency: Int
    ) {
        let hour = Calendar.current.component(.hour, from: Date())
        var bucket = store.timePatterns.hourBuckets[hour] ?? TimeOfDayPattern.HourBucket()
        let estimatedTotal = max(1, Int(1.0 / max(0.01, successRate)))
        bucket.successCount += Int(successRate * Double(estimatedTotal))
        bucket.failureCount += estimatedTotal - Int(successRate * Double(estimatedTotal))
        bucket.totalLatencyMs += avgLatencyMs * estimatedTotal
        bucket.challengeCount += Int(challengeRate * Double(estimatedTotal))
        bucket.batchCount += 1
        store.timePatterns.hourBuckets[hour] = bucket

        var snapshot = store.hostPerformanceHistory[host] ?? PreOptimizerStore.HostPerformanceSnapshot(host: host)
        snapshot.recentSuccessRate = (snapshot.recentSuccessRate * 0.6) + (successRate * 0.4)
        snapshot.recentAvgLatencyMs = Int(Double(snapshot.recentAvgLatencyMs) * 0.6 + Double(avgLatencyMs) * 0.4)
        snapshot.recentChallengeRate = (snapshot.recentChallengeRate * 0.6) + (challengeRate * 0.4)
        if successRate > snapshot.recentSuccessRate {
            snapshot.bestConcurrency = concurrency
        }
        snapshot.lastUpdated = Date()
        store.hostPerformanceHistory[host] = snapshot

        save()
    }

    func timeOfDayHeatmap() -> [(hour: Int, successRate: Double, batchCount: Int)] {
        (0..<24).map { hour in
            let bucket = store.timePatterns.hourBuckets[hour]
            return (hour: hour, successRate: bucket?.successRate ?? 0.5, batchCount: bucket?.batchCount ?? 0)
        }
    }

    func hostPerformanceRankings() -> [(host: String, score: Double, latency: Int)] {
        store.hostPerformanceHistory.values
            .sorted { a, b in
                let scoreA = a.recentSuccessRate * 0.6 + max(0, 1.0 - Double(a.recentAvgLatencyMs) / 15000.0) * 0.4
                let scoreB = b.recentSuccessRate * 0.6 + max(0, 1.0 - Double(b.recentAvgLatencyMs) / 15000.0) * 0.4
                return scoreA > scoreB
            }
            .map { ($0.host, $0.recentSuccessRate, $0.recentAvgLatencyMs) }
    }

    func resetAll() {
        store = PreOptimizerStore()
        lastReport = nil
        save()
        logger.log("BatchPreOptimizer: all data RESET", category: .automation, level: .warning)
    }

    private func assessProxyPoolHealth(target: ProxyRotationService.ProxyTarget) async -> Double {
        let proxyService = ProxyRotationService.shared
        let activeProxy = proxyService.nextWorkingProxy(for: target)
        let deviceProxy = DeviceProxyService.shared

        var health = 0.5
        if deviceProxy.isEnabled { health += 0.2 }
        if NodeMavenService.shared.isEnabled { health += 0.2 }
        if activeProxy != nil { health += 0.1 }

        let qualityScore = await proxyQuality.scoreFor(proxyId: target.rawValue)
        health = (health * 0.5) + (qualityScore * 0.5)

        return min(1.0, max(0.1, health))
    }

    private func assessURLPoolHealth(urls: [URL]) async -> Double {
        guard !urls.isEmpty else { return 0.1 }
        var totalScore = 0.0
        for url in urls {
            let sc = await urlQuality.scoreFor(urlString: url.absoluteString)
            totalScore += sc
        }
        let avgScore = totalScore / Double(urls.count)
        let countBonus = min(0.2, Double(urls.count - 1) * 0.05)
        return min(1.0, max(0.1, avgScore + countBonus))
    }

    private func assessCredentialQuality(credentials: [LoginCredential]) -> Double {
        guard !credentials.isEmpty else { return 0 }
        let untestedRatio = Double(credentials.filter { $0.status == .untested }.count) / Double(credentials.count)
        let alreadyTestedRatio = 1.0 - untestedRatio
        var domains: Set<String> = []
        for cred in credentials {
            if let atIdx = cred.username.firstIndex(of: "@") {
                domains.insert(String(cred.username[cred.username.index(after: atIdx)...]).lowercased())
            }
        }
        let domainDiversity = min(1.0, Double(domains.count) / max(1.0, Double(credentials.count) * 0.3))
        let summary = credentialPriority.credentialSummary()
        let highPriorityRatio = summary.total > 0 ? Double(summary.highPriority) / Double(summary.total) : 0.5
        return min(1.0, untestedRatio * 0.3 + domainDiversity * 0.3 + highPriorityRatio * 0.2 + (1.0 - alreadyTestedRatio * 0.5) * 0.2)
    }

    private func assessTimeOfDay() -> Double {
        let hour = Calendar.current.component(.hour, from: Date())
        if let bucket = store.timePatterns.hourBuckets[hour], bucket.batchCount >= 2 {
            let sr = bucket.successRate
            let cr = bucket.challengeRate
            return min(1.0, sr * 0.7 + (1.0 - cr) * 0.3)
        }
        let nearbyHours = [(hour - 1 + 24) % 24, (hour + 1) % 24]
        for nearby in nearbyHours {
            if let bucket = store.timePatterns.hourBuckets[nearby], bucket.batchCount >= 2 {
                return min(1.0, bucket.successRate * 0.6 + 0.2)
            }
        }
        return 0.5
    }

    private func assessMemoryPressure() -> Double {
        let totalMB = ProcessInfo.processInfo.physicalMemory / 1024 / 1024
        let usedMB = CrashProtectionService.shared.currentMemoryUsageMB()
        let ratio = Double(usedMB) / Double(max(1, totalMB))
        if ratio < 0.3 { return 1.0 }
        if ratio < 0.5 { return 0.7 }
        if ratio < 0.7 { return 0.4 }
        return 0.2
    }

    private func rankURLs(urls: [URL]) async -> [(url: String, score: Double, reason: String)] {
        var results: [(url: String, score: Double, reason: String)] = []
        for url in urls {
            let score = await urlQuality.scoreFor(urlString: url.absoluteString)
            let host = url.host ?? url.absoluteString
            let reason: String
            if score >= 0.7 { reason = "High quality — reliable responses" }
            else if score >= 0.4 { reason = "Moderate — some failures recently" }
            else { reason = "Low quality — frequent failures or high latency" }
            results.append((url: host, score: score, reason: reason))
        }
        return results.sorted { $0.score > $1.score }
    }

    private func generateProxyWarnings(target: ProxyRotationService.ProxyTarget, health: Double) -> [String] {
        var warnings: [String] = []
        if health < 0.3 {
            warnings.append("Proxy pool health is critically low (\(Int(health * 100))%) — expect high failure rates")
        } else if health < 0.5 {
            warnings.append("Proxy pool health is degraded (\(Int(health * 100))%) — consider refreshing proxies")
        }
        let deviceProxy = DeviceProxyService.shared
        if !deviceProxy.isEnabled && !NodeMavenService.shared.isEnabled {
            warnings.append("No device proxy or NodeMaven configured — using built-in proxy rotation only")
        }
        return warnings
    }

    private func generateCredentialInsights(credentials: [LoginCredential]) -> [String] {
        var insights: [String] = []
        let untestedCount = credentials.filter { $0.status == .untested }.count
        let testedCount = credentials.count - untestedCount
        if testedCount > 0 && untestedCount == 0 {
            insights.append("All \(credentials.count) credentials have been tested before — consider adding fresh credentials")
        }
        if untestedCount > 0 {
            insights.append("\(untestedCount) untested credentials will be prioritized")
        }
        let topDomains = credentialPriority.topDomains(limit: 3)
        if !topDomains.isEmpty {
            let domainList = topDomains.map { "\($0.domain) (\($0.accountRate)%)" }.joined(separator: ", ")
            insights.append("Top domains by account discovery: \(domainList)")
        }
        let workingCount = credentials.filter { $0.status == .working }.count
        if workingCount > 0 {
            insights.append("\(workingCount) credentials already marked as working — will be deprioritized")
        }
        return insights
    }

    private func recommendConcurrency(credentialCount: Int, urlHealth: Double, proxyHealth: Double, memoryScore: Double, currentConcurrency: Int) -> Int {
        var rec = currentConcurrency

        if credentialCount <= 5 { rec = min(rec, 2) }
        else if credentialCount <= 20 { rec = min(rec, 4) }

        if proxyHealth < 0.3 { rec = max(1, rec - 2) }
        else if proxyHealth < 0.5 { rec = max(2, rec - 1) }

        if urlHealth < 0.3 { rec = max(1, rec - 1) }

        if memoryScore < 0.3 { rec = max(1, rec - 2) }
        else if memoryScore < 0.5 { rec = max(2, rec - 1) }

        let governorRec = concurrencyGovernor.currentRecommendedConcurrency
        rec = min(rec, governorRec + 1)

        return max(1, min(10, rec))
    }

    private func recommendTimeout(urlHealth: Double, proxyHealth: Double, currentTimeout: TimeInterval) -> TimeInterval {
        var timeout = currentTimeout
        if urlHealth < 0.4 { timeout = min(timeout + 15, 180) }
        if proxyHealth < 0.4 { timeout = min(timeout + 10, 180) }
        if urlHealth > 0.7 && proxyHealth > 0.7 { timeout = max(60, timeout - 10) }
        return timeout
    }

    private func recommendStealth(proxyHealth: Double, todScore: Double, stealthEnabled: Bool) -> Bool {
        if proxyHealth < 0.4 { return true }
        if todScore < 0.4 { return true }
        return stealthEnabled
    }

    private func recommendRetry(urlHealth: Double, proxyHealth: Double) -> Bool {
        if urlHealth < 0.5 || proxyHealth < 0.5 { return true }
        return false
    }

    private func computeReadinessScore(proxyHealth: Double, urlHealth: Double, credQuality: Double, todScore: Double, memoryScore: Double) -> Double {
        proxyHealth * 0.30 + urlHealth * 0.25 + credQuality * 0.20 + todScore * 0.15 + memoryScore * 0.10
    }

    private func estimateSuccessRate(proxyHealth: Double, urlHealth: Double, credQuality: Double, todScore: Double) -> Double {
        let base = proxyHealth * 0.35 + urlHealth * 0.30 + credQuality * 0.20 + todScore * 0.15
        return min(0.95, max(0.05, base))
    }

    private func estimateDuration(credentialCount: Int, concurrency: Int, avgTimeout: TimeInterval, urlHealth: Double) -> Double {
        let avgTimePerCred = avgTimeout * 0.4 * (1.0 + (1.0 - urlHealth) * 0.5)
        let totalSeconds = (Double(credentialCount) / Double(max(1, concurrency))) * avgTimePerCred
        return max(0.5, totalSeconds / 60.0)
    }

    private func generateStrategicRecommendations(readiness: BatchReadiness, proxyHealth: Double, urlHealth: Double, credQuality: Double, todScore: Double, memoryScore: Double, credentialCount: Int) -> [String] {
        var recs: [String] = []
        switch readiness {
        case .optimal:
            recs.append("Conditions are optimal — proceed with confidence")
        case .good:
            recs.append("Conditions are favorable — minor adjustments may improve results")
        case .acceptable:
            recs.append("Conditions are acceptable but not ideal — consider timing or proxy changes")
        case .degraded:
            recs.append("Conditions are degraded — reduce concurrency and consider waiting")
        case .risky:
            recs.append("High risk — strongly consider postponing or fixing proxy/URL issues first")
        }

        if todScore < 0.4 {
            let bestHour = store.timePatterns.hourBuckets.max(by: { a, b in a.value.successRate < b.value.successRate })
            if let best = bestHour, best.value.batchCount >= 2 {
                recs.append("Current time has low success history — best hour is \(best.key):00 (\(Int(best.value.successRate * 100))% success)")
            }
        }

        if credentialCount > 50 && proxyHealth < 0.5 {
            recs.append("Large batch (\(credentialCount)) with weak proxies — consider splitting into smaller batches")
        }

        if memoryScore < 0.3 {
            recs.append("High memory pressure — close other apps and reduce concurrency")
        }

        return recs
    }

    private func shouldRequestAIAnalysis(credentialCount: Int, readinessScore: Double) -> Bool {
        guard credentialCount >= 10 else { return false }
        guard Date().timeIntervalSince(store.lastAIAnalysis) > 300 else { return false }
        if readinessScore < 0.5 { return true }
        if store.totalBatchesAnalyzed % 5 == 0 { return true }
        return false
    }

    private func requestAIPreBatchAnalysis(
        credentialCount: Int, urlCount: Int, proxyTarget: String,
        proxyHealth: Double, urlHealth: Double, credQuality: Double,
        todScore: Double, readinessScore: Double,
        urlRankings: [(url: String, score: Double, reason: String)]
    ) async -> [String] {
        let hour = Calendar.current.component(.hour, from: Date())
        let heatmapSlice = (-2...2).compactMap { offset -> [String: Any]? in
            let h = (hour + offset + 24) % 24
            guard let bucket = store.timePatterns.hourBuckets[h] else { return nil }
            return ["hour": h, "successRate": Int(bucket.successRate * 100), "batches": bucket.batchCount, "challengeRate": Int(bucket.challengeRate * 100)]
        }

        let urlData = urlRankings.prefix(8).map { ["url": $0.url, "score": Int($0.score * 100)] as [String: Any] }

        let topDomains = credentialPriority.topDomains(limit: 5).map {
            ["domain": $0.domain, "accountRate": $0.accountRate, "total": $0.total] as [String: Any]
        }

        let combined: [String: Any] = [
            "credentialCount": credentialCount,
            "urlCount": urlCount,
            "proxyTarget": proxyTarget,
            "proxyHealth": Int(proxyHealth * 100),
            "urlHealth": Int(urlHealth * 100),
            "credQuality": Int(credQuality * 100),
            "todScore": Int(todScore * 100),
            "readiness": Int(readinessScore * 100),
            "currentHour": hour,
            "heatmap": heatmapSlice,
            "urls": urlData,
            "topDomains": topDomains,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: combined),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return [] }

        let systemPrompt = """
        You are a batch optimization strategist for automated web testing. \
        Analyze pre-batch telemetry and provide 3-5 actionable recommendations. \
        Return ONLY a JSON array of strings: ["recommendation1", "recommendation2", ...]. \
        Focus on: optimal timing, proxy strategy, credential ordering strategy, \
        concurrency tuning, and risk mitigation. Be specific and data-driven.
        """

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: "Pre-batch telemetry:\n\(jsonStr)") else {
            return []
        }

        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }

        store.totalAIAnalyses += 1
        store.lastAIAnalysis = Date()
        save()

        logger.log("BatchPreOptimizer: AI analysis returned \(arr.count) recommendations", category: .automation, level: .success)
        return arr
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: persistKey)
        }
    }
}
