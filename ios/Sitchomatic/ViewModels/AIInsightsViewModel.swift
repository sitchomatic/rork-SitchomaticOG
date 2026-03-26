import Foundation
import Observation

@Observable
class AIInsightsViewModel {
    var isLoadingInsights: Bool = false
    var aiSummary: String?
    var lastRefreshed: Date?

    struct SystemHealthSnapshot {
        let globalHealth: Double
        let globalDetectionRate: Double
        let adaptiveMode: String
        let hostHealthItems: [(host: String, health: Double, sessions: Int, failureRate: Int, streak: Int, risk: SessionHealthRisk)]
        let topURLs: [(url: String, score: Double, attempts: Int, successRate: Int, avgLatency: Int, blocked: Int)]
        let fingerprintStats: [FingerprintProfileStats]
        let detectionPatterns: [DetectionPattern]
        let credentialSummary: (total: Int, tested: Int, untested: Int, highPriority: Int, lowPriority: Int)
        let topDomains: [(domain: String, accountRate: Int, total: Int)]
        let topDetectionSignals: [(signal: String, count: Int)]
    }

    func buildSnapshot() -> SystemHealthSnapshot {
        let sessionHealth = AISessionHealthMonitorService.shared
        let urlOptimizer = AILoginURLOptimizerService.shared
        let fingerprintTuning = AIFingerprintTuningService.shared
        let antiDetection = AIAntiDetectionAdaptiveService.shared
        let credentialPriority = AICredentialPriorityScoringService.shared

        return SystemHealthSnapshot(
            globalHealth: sessionHealth.globalHealthScore(),
            globalDetectionRate: antiDetection.globalDetectionRate(),
            adaptiveMode: antiDetection.currentAdaptiveMode(),
            hostHealthItems: sessionHealth.hostHealthSummary(),
            topURLs: urlOptimizer.allProfiles().prefix(10).map { ($0.urlString, $0.compositeScore, $0.totalAttempts, Int($0.successRate * 100), $0.avgLatencyMs, $0.blockCount) },
            fingerprintStats: fingerprintTuning.allProfileStats(),
            detectionPatterns: antiDetection.activePatterns(),
            credentialSummary: credentialPriority.credentialSummary(),
            topDomains: credentialPriority.topDomains(limit: 8),
            topDetectionSignals: fingerprintTuning.topDetectionSignals(limit: 8)
        )
    }

    func requestAISummary() async {
        isLoadingInsights = true
        defer { isLoadingInsights = false }

        let snapshot = buildSnapshot()

        var summaryData: [String: Any] = [
            "globalHealth": String(format: "%.0f%%", snapshot.globalHealth * 100),
            "globalDetectionRate": String(format: "%.0f%%", snapshot.globalDetectionRate * 100),
            "adaptiveMode": snapshot.adaptiveMode,
            "hostsMonitored": snapshot.hostHealthItems.count,
            "urlsTracked": snapshot.topURLs.count,
            "fingerprintProfiles": snapshot.fingerprintStats.count,
            "activePatterns": snapshot.detectionPatterns.count,
            "credentialsTested": snapshot.credentialSummary.tested,
            "credentialsUntested": snapshot.credentialSummary.untested,
            "highPriorityCredentials": snapshot.credentialSummary.highPriority,
        ]

        if !snapshot.hostHealthItems.isEmpty {
            summaryData["worstHost"] = snapshot.hostHealthItems.last.map { "\($0.host) (health: \(Int($0.health * 100))%, failures: \($0.failureRate)%)" } ?? "none"
            summaryData["bestHost"] = snapshot.hostHealthItems.first.map { "\($0.host) (health: \(Int($0.health * 100))%, failures: \($0.failureRate)%)" } ?? "none"
        }

        if !snapshot.topDetectionSignals.isEmpty {
            summaryData["topSignals"] = snapshot.topDetectionSignals.prefix(5).map { "\($0.signal) (\($0.count)x)" }
        }

        if !snapshot.topDomains.isEmpty {
            summaryData["topDomains"] = snapshot.topDomains.prefix(5).map { "\($0.domain) (\($0.accountRate)% accounts, \($0.total) tested)" }
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: summaryData),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

        let systemPrompt = """
        You are an AI automation analyst. Analyze the system health data and provide a concise, actionable summary. \
        Focus on: 1) Overall system health assessment, 2) Top issues to address, 3) Optimization opportunities, \
        4) Credential testing efficiency, 5) Detection avoidance effectiveness. \
        Use bullet points. Be specific with numbers. Keep it under 300 words. \
        Do NOT use markdown headers or code blocks — just plain text with bullet points.
        """

        let userPrompt = "Current system state:\n\(jsonStr)"

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: userPrompt) else {
            aiSummary = "Unable to generate AI summary — check network connection."
            return
        }

        aiSummary = response
        lastRefreshed = Date()
    }

    func resetAllAIData() {
        AITimingOptimizerService.shared.resetAll()
        AIProxyStrategyService.shared.resetAll()
        AIChallengePageSolverService.shared.resetAll()
        AILoginURLOptimizerService.shared.resetAll()
        AIFingerprintTuningService.shared.resetAll()
        AISessionHealthMonitorService.shared.resetAll()
        AICredentialPriorityScoringService.shared.resetAll()
        AIAntiDetectionAdaptiveService.shared.resetAll()
        aiSummary = nil
        lastRefreshed = nil
    }
}
