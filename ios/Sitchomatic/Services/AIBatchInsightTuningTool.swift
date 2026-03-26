import Foundation

nonisolated enum TuningAction: String, Codable, Sendable, CaseIterable {
    case increaseConcurrency
    case decreaseConcurrency
    case rotateProxies
    case cooldownHost
    case switchURLs
    case adjustTiming
    case pauseBatch
    case noChange
}

nonisolated struct BatchInsightInput: Sendable {
    let batchId: String
    let results: [(cardId: String, outcome: String, latencyMs: Int)]
    let settingsSnapshot: BatchSettingsSnapshot
}

nonisolated struct BatchSettingsSnapshot: Sendable {
    let concurrency: Int
    let proxyTarget: String
    let networkMode: String
    let stealthEnabled: Bool
    let fingerprintSpoofing: Bool
    let pageLoadTimeout: Int
    let submitRetryCount: Int
}

nonisolated struct BatchInsightResult: Sendable {
    let summary: String
    let failureClusters: [FailureCluster]
    let tuningRecommendations: [TuningRecommendation]
    let overallGrade: String
    let confidence: Double
    let timestamp: Date
}

nonisolated struct FailureCluster: Sendable {
    let pattern: String
    let count: Int
    let percentage: Double
    let affectedCards: [String]
    let severity: Int
}

nonisolated struct TuningRecommendation: Sendable {
    let action: TuningAction
    let priority: Int
    let reasoning: String
    let expectedImprovement: String
    let parameters: [String: String]
}

nonisolated struct BatchInsightAuditEntry: Codable, Sendable {
    let id: String
    let batchId: String
    let summary: String
    let grade: String
    let clusterCount: Int
    let recommendationCount: Int
    let confidence: Double
    let timestamp: Date
    let successRate: Double
    let totalItems: Int
}

nonisolated struct BatchInsightStore: Codable, Sendable {
    var auditLog: [BatchInsightAuditEntry] = []
    var historicalGrades: [String] = []
    var recurringPatterns: [String: Int] = [:]
    var totalAnalyses: Int = 0
    var cumulativeSuccessRates: [Double] = []
    var lastAnalysisDate: Date?
}

@MainActor
class AIBatchInsightTuningTool {
    static let shared = AIBatchInsightTuningTool()

    private let logger = DebugLogger.shared
    private let persistKey = "AIBatchInsightTuningTool_v1"
    private let maxAuditEntries = 200
    private var store: BatchInsightStore

    private(set) var lastResult: BatchInsightResult?
    private(set) var isAnalyzing: Bool = false

    init() {
        if let data = UserDefaults.standard.data(forKey: persistKey),
           let decoded = try? JSONDecoder().decode(BatchInsightStore.self, from: data) {
            self.store = decoded
        } else {
            self.store = BatchInsightStore()
        }
    }

    func summarizeBatchPerformance(input: BatchInsightInput) async -> BatchInsightResult {
        isAnalyzing = true
        defer { isAnalyzing = false }

        logger.log("BatchInsight: analyzing batch \(input.batchId) with \(input.results.count) results", category: .automation, level: .info)

        let clusters = identifyFailureClusters(results: input.results)
        let heuristicRecs = generateHeuristicRecommendations(results: input.results, clusters: clusters, settings: input.settingsSnapshot)

        let successCount = input.results.filter { $0.outcome == "pass" || $0.outcome == "success" }.count
        let successRate = input.results.isEmpty ? 0 : Double(successCount) / Double(input.results.count)
        let grade = gradePerformance(successRate: successRate, clusters: clusters)

        let heuristicResult = BatchInsightResult(
            summary: buildHeuristicSummary(results: input.results, clusters: clusters, successRate: successRate, grade: grade),
            failureClusters: clusters,
            tuningRecommendations: heuristicRecs,
            overallGrade: grade,
            confidence: 0.6,
            timestamp: Date()
        )

        if let aiResult = await requestAIInsight(input: input, clusters: clusters, heuristicRecs: heuristicRecs, successRate: successRate, grade: grade) {
            recordResult(input: input, result: aiResult, successRate: successRate)
            lastResult = aiResult
            return aiResult
        }

        recordResult(input: input, result: heuristicResult, successRate: successRate)
        lastResult = heuristicResult
        return heuristicResult
    }

    var auditLog: [BatchInsightAuditEntry] { store.auditLog }
    var totalAnalyses: Int { store.totalAnalyses }
    var averageSuccessRate: Double {
        guard !store.cumulativeSuccessRates.isEmpty else { return 0 }
        return store.cumulativeSuccessRates.reduce(0, +) / Double(store.cumulativeSuccessRates.count)
    }
    var recurringPatterns: [String: Int] { store.recurringPatterns }

    func resetAll() {
        store = BatchInsightStore()
        lastResult = nil
        save()
        logger.log("BatchInsight: all data RESET", category: .automation, level: .warning)
    }

    // MARK: - Cluster Detection

    private func identifyFailureClusters(results: [(cardId: String, outcome: String, latencyMs: Int)]) -> [FailureCluster] {
        let total = results.count
        guard total > 0 else { return [] }

        var outcomeMap: [String: [String]] = [:]
        for r in results where r.outcome != "pass" && r.outcome != "success" {
            outcomeMap[r.outcome, default: []].append(r.cardId)
        }

        var clusters: [FailureCluster] = []
        for (pattern, cards) in outcomeMap {
            let pct = Double(cards.count) / Double(total) * 100
            let severity: Int
            if pct > 50 { severity = 3 }
            else if pct > 25 { severity = 2 }
            else { severity = 1 }

            clusters.append(FailureCluster(
                pattern: pattern,
                count: cards.count,
                percentage: pct,
                affectedCards: Array(cards.prefix(10)),
                severity: severity
            ))
        }

        let timeoutCards = results.filter { $0.latencyMs > 40000 }
        if timeoutCards.count >= 3 {
            clusters.append(FailureCluster(
                pattern: "high_latency_cluster",
                count: timeoutCards.count,
                percentage: Double(timeoutCards.count) / Double(total) * 100,
                affectedCards: timeoutCards.prefix(10).map(\.cardId),
                severity: 2
            ))
        }

        return clusters.sorted { $0.count > $1.count }
    }

    // MARK: - Heuristic Recommendations

    private func generateHeuristicRecommendations(results: [(cardId: String, outcome: String, latencyMs: Int)], clusters: [FailureCluster], settings: BatchSettingsSnapshot) -> [TuningRecommendation] {
        var recs: [TuningRecommendation] = []
        let total = results.count
        guard total > 0 else { return recs }

        let successCount = results.filter { $0.outcome == "pass" || $0.outcome == "success" }.count
        let successRate = Double(successCount) / Double(total)
        let avgLatency = results.map(\.latencyMs).reduce(0, +) / total
        let connFailures = results.filter { $0.outcome == "connectionFailure" || $0.outcome == "connection_failure" }.count
        let timeouts = results.filter { $0.outcome == "timeout" }.count

        if Double(connFailures) / Double(total) > 0.3 {
            recs.append(TuningRecommendation(action: .rotateProxies, priority: 1, reasoning: "\(Int(Double(connFailures) / Double(total) * 100))% connection failures — proxies may be burned", expectedImprovement: "Reduce connection failures by 40-60%", parameters: ["currentProxy": settings.proxyTarget]))
        }

        if Double(timeouts) / Double(total) > 0.25 {
            if settings.concurrency > 3 {
                recs.append(TuningRecommendation(action: .decreaseConcurrency, priority: 1, reasoning: "\(Int(Double(timeouts) / Double(total) * 100))% timeouts at concurrency \(settings.concurrency) — server overload likely", expectedImprovement: "Reduce timeouts by 30-50%", parameters: ["current": "\(settings.concurrency)", "suggested": "\(max(2, settings.concurrency - 2))"]))
            } else {
                recs.append(TuningRecommendation(action: .adjustTiming, priority: 2, reasoning: "High timeout rate even at low concurrency — increase page load timeout", expectedImprovement: "Reduce timeouts by 20-30%", parameters: ["currentTimeout": "\(settings.pageLoadTimeout)", "suggested": "\(settings.pageLoadTimeout + 10)"]))
            }
        }

        if successRate > 0.75 && settings.concurrency < 6 && avgLatency < 15000 {
            recs.append(TuningRecommendation(action: .increaseConcurrency, priority: 3, reasoning: "High success rate (\(Int(successRate * 100))%) with low latency — room to scale up", expectedImprovement: "Increase throughput by 25-40%", parameters: ["current": "\(settings.concurrency)", "suggested": "\(min(8, settings.concurrency + 2))"]))
        }

        if successRate < 0.2 && total >= 5 {
            recs.append(TuningRecommendation(action: .pauseBatch, priority: 1, reasoning: "Very low success rate (\(Int(successRate * 100))%) — batch may be wasting resources", expectedImprovement: "Save resources, diagnose root cause", parameters: [:]))
        }

        for cluster in clusters where cluster.severity >= 2 {
            if cluster.pattern.contains("institution") || cluster.pattern.contains("decline") {
                recs.append(TuningRecommendation(action: .switchURLs, priority: 2, reasoning: "Cluster: \(cluster.count) institution declines (\(Int(cluster.percentage))%) — try alternate endpoints", expectedImprovement: "Reduce declines by rotating entry points", parameters: ["cluster": cluster.pattern]))
            }

            if cluster.pattern.contains("challenge") || cluster.pattern.contains("captcha") {
                recs.append(TuningRecommendation(action: .cooldownHost, priority: 1, reasoning: "Cluster: \(cluster.count) challenges (\(Int(cluster.percentage))%) — host is actively blocking", expectedImprovement: "Let detection cooldown before retrying", parameters: ["cluster": cluster.pattern, "suggestedCooldown": "300"]))
            }
        }

        if recs.isEmpty {
            recs.append(TuningRecommendation(action: .noChange, priority: 5, reasoning: "No significant issues detected — current config is performing acceptably", expectedImprovement: "Maintain steady state", parameters: [:]))
        }

        return recs.sorted { $0.priority < $1.priority }
    }

    // MARK: - AI

    private func requestAIInsight(input: BatchInsightInput, clusters: [FailureCluster], heuristicRecs: [TuningRecommendation], successRate: Double, grade: String) async -> BatchInsightResult? {
        var data: [String: Any] = [
            "batchId": input.batchId,
            "totalItems": input.results.count,
            "successRate": Int(successRate * 100),
            "grade": grade,
            "settings": [
                "concurrency": input.settingsSnapshot.concurrency,
                "proxyTarget": input.settingsSnapshot.proxyTarget,
                "networkMode": input.settingsSnapshot.networkMode,
                "stealthEnabled": input.settingsSnapshot.stealthEnabled,
                "pageLoadTimeout": input.settingsSnapshot.pageLoadTimeout,
            ] as [String: Any],
            "clusters": clusters.map { [
                "pattern": $0.pattern,
                "count": $0.count,
                "percentage": Int($0.percentage),
                "severity": $0.severity,
            ] as [String: Any] },
            "heuristicRecommendations": heuristicRecs.map { [
                "action": $0.action.rawValue,
                "priority": $0.priority,
                "reasoning": $0.reasoning,
            ] as [String: Any] },
            "outcomeBreakdown": buildOutcomeBreakdown(results: input.results),
        ]

        let trend = BatchTelemetryService.shared.trendAnalysis()
        data["trends"] = [
            "successRateTrend": trend.successRateTrend.rawValue,
            "throughputTrend": trend.throughputTrend.rawValue,
            "latencyTrend": trend.latencyTrend.rawValue,
        ]

        if !store.recurringPatterns.isEmpty {
            data["recurringPatterns"] = store.recurringPatterns
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return nil }

        let systemPrompt = """
        You analyze batch automation performance. Given batch results, failure clusters, settings, and trends, provide: \
        1) A concise summary (2-3 sentences) 2) Specific tuning recommendations. \
        Return ONLY JSON: {"summary":"...","recommendations":[{"action":"increaseConcurrency|decreaseConcurrency|rotateProxies|cooldownHost|switchURLs|adjustTiming|pauseBatch|noChange","priority":1-5,"reasoning":"...","expectedImprovement":"...","parameters":{}}],"grade":"A|B|C|D|F","confidence":0.0-1.0}. \
        Grade: A=90%+ success, B=70-90%, C=50-70%, D=30-50%, F=<30%. Return ONLY JSON.
        """

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: "Batch data:\n\(jsonStr)") else { return nil }

        return parseAIResponse(response, clusters: clusters)
    }

    private func parseAIResponse(_ response: String, clusters: [FailureCluster]) -> BatchInsightResult? {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let summary = (json["summary"] as? String) ?? "AI analysis complete"
        let grade = (json["grade"] as? String) ?? "C"
        let confidence = (json["confidence"] as? Double) ?? 0.7

        var recs: [TuningRecommendation] = []
        if let recArray = json["recommendations"] as? [[String: Any]] {
            for rec in recArray {
                guard let actionStr = rec["action"] as? String,
                      let action = TuningAction(rawValue: actionStr) else { continue }
                let priority = (rec["priority"] as? Int) ?? 3
                let reasoning = (rec["reasoning"] as? String) ?? ""
                let improvement = (rec["expectedImprovement"] as? String) ?? ""
                var params: [String: String] = [:]
                if let p = rec["parameters"] as? [String: Any] {
                    for (k, v) in p { params[k] = "\(v)" }
                }
                recs.append(TuningRecommendation(action: action, priority: priority, reasoning: reasoning, expectedImprovement: improvement, parameters: params))
            }
        }

        return BatchInsightResult(summary: summary, failureClusters: clusters, tuningRecommendations: recs.sorted { $0.priority < $1.priority }, overallGrade: grade, confidence: min(1.0, max(0.0, confidence)), timestamp: Date())
    }

    // MARK: - Helpers

    private func buildOutcomeBreakdown(results: [(cardId: String, outcome: String, latencyMs: Int)]) -> [String: Int] {
        var breakdown: [String: Int] = [:]
        for r in results { breakdown[r.outcome, default: 0] += 1 }
        return breakdown
    }

    private func gradePerformance(successRate: Double, clusters: [FailureCluster]) -> String {
        let criticalClusters = clusters.filter { $0.severity >= 3 }.count
        if criticalClusters > 0 && successRate < 0.5 { return "F" }
        if successRate >= 0.9 { return "A" }
        if successRate >= 0.7 { return "B" }
        if successRate >= 0.5 { return "C" }
        if successRate >= 0.3 { return "D" }
        return "F"
    }

    private func buildHeuristicSummary(results: [(cardId: String, outcome: String, latencyMs: Int)], clusters: [FailureCluster], successRate: Double, grade: String) -> String {
        let total = results.count
        let successCount = results.filter { $0.outcome == "pass" || $0.outcome == "success" }.count
        let avgLatency = total > 0 ? results.map(\.latencyMs).reduce(0, +) / total : 0

        var summary = "Batch: \(successCount)/\(total) success (\(Int(successRate * 100))%), grade \(grade), avg latency \(avgLatency)ms."
        if !clusters.isEmpty {
            let topCluster = clusters[0]
            summary += " Top failure: \(topCluster.pattern) (\(topCluster.count) occurrences, \(Int(topCluster.percentage))%)."
        }
        return summary
    }

    // MARK: - Recording

    private func recordResult(input: BatchInsightInput, result: BatchInsightResult, successRate: Double) {
        store.totalAnalyses += 1
        store.lastAnalysisDate = Date()
        store.historicalGrades.append(result.overallGrade)
        if store.historicalGrades.count > 100 { store.historicalGrades = Array(store.historicalGrades.suffix(100)) }

        store.cumulativeSuccessRates.append(successRate)
        if store.cumulativeSuccessRates.count > 100 { store.cumulativeSuccessRates = Array(store.cumulativeSuccessRates.suffix(100)) }

        for cluster in result.failureClusters {
            store.recurringPatterns[cluster.pattern, default: 0] += 1
        }

        let entry = BatchInsightAuditEntry(
            id: UUID().uuidString,
            batchId: input.batchId,
            summary: result.summary,
            grade: result.overallGrade,
            clusterCount: result.failureClusters.count,
            recommendationCount: result.tuningRecommendations.count,
            confidence: result.confidence,
            timestamp: Date(),
            successRate: successRate,
            totalItems: input.results.count
        )

        store.auditLog.insert(entry, at: 0)
        if store.auditLog.count > maxAuditEntries {
            store.auditLog = Array(store.auditLog.prefix(maxAuditEntries))
        }

        save()

        logger.log("BatchInsight: batch \(input.batchId) — grade \(result.overallGrade), \(result.failureClusters.count) clusters, \(result.tuningRecommendations.count) recommendations", category: .automation, level: .info)
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: persistKey)
        }
    }
}
