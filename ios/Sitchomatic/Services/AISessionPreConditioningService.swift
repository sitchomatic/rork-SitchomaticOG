import Foundation

nonisolated struct PreConditioningRecipe: Codable, Sendable {
    var host: String
    var bestProxyType: String?
    var bestStealthProfileSeed: Int?
    var bestPatternOrder: [String]?
    var bestURLVariant: String?
    var optimalTimingProfile: OptimalTiming?
    var optimalConcurrency: Int?
    var recommendedWaitBeforeSubmitMs: Int?
    var recommendedPageLoadExtraMs: Int?
    var aiGenerated: Bool = false
    var aiReasoning: String?
    var totalDataPoints: Int = 0
    var successRate: Double = 0
    var lastUpdated: Date = .distantPast
    var version: Int = 0
}

nonisolated struct OptimalTiming: Codable, Sendable {
    var keystrokeMinMs: Int = 45
    var keystrokeMaxMs: Int = 160
    var interFieldMinMs: Int = 200
    var interFieldMaxMs: Int = 600
    var preSubmitMinMs: Int = 300
    var preSubmitMaxMs: Int = 700
}

nonisolated struct SessionOutcomeRecord: Codable, Sendable {
    let host: String
    let proxyType: String
    let stealthSeed: Int?
    let patternUsed: String
    let urlVariant: String
    let outcome: String
    let latencyMs: Int
    let wasSuccess: Bool
    let wasChallenge: Bool
    let wasBlocked: Bool
    let timestamp: Date
}

nonisolated struct PreConditioningStore: Codable, Sendable {
    var recipes: [String: PreConditioningRecipe] = [:]
    var outcomeHistory: [SessionOutcomeRecord] = []
    var aiRecipeCallCount: Int = 0
    var lastAICall: Date = .distantPast
}

@MainActor
class AISessionPreConditioningService {
    static let shared = AISessionPreConditioningService()

    private let logger = DebugLogger.shared
    private let persistenceKey = "AISessionPreConditioningData_v1"
    private let maxOutcomeHistory = 3000
    private let minDataForRecipe = 5
    private let aiRecipeThreshold = 10
    private let aiCooldownSeconds: TimeInterval = 600
    private var store: PreConditioningStore

    private init() {
        if let saved = UserDefaults.standard.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode(PreConditioningStore.self, from: saved) {
            self.store = decoded
        } else {
            self.store = PreConditioningStore()
        }
    }

    func recordOutcome(
        host: String,
        proxyType: String,
        stealthSeed: Int?,
        patternUsed: String,
        urlVariant: String,
        outcome: String,
        latencyMs: Int,
        wasSuccess: Bool,
        wasChallenge: Bool,
        wasBlocked: Bool
    ) {
        let record = SessionOutcomeRecord(
            host: host,
            proxyType: proxyType,
            stealthSeed: stealthSeed,
            patternUsed: patternUsed,
            urlVariant: urlVariant,
            outcome: outcome,
            latencyMs: latencyMs,
            wasSuccess: wasSuccess,
            wasChallenge: wasChallenge,
            wasBlocked: wasBlocked,
            timestamp: Date()
        )

        store.outcomeHistory.append(record)
        if store.outcomeHistory.count > maxOutcomeHistory {
            store.outcomeHistory.removeFirst(store.outcomeHistory.count - maxOutcomeHistory)
        }

        updateLocalRecipe(for: host)
        save()

        let hostRecords = store.outcomeHistory.filter { $0.host == host }
        if hostRecords.count >= aiRecipeThreshold &&
           hostRecords.count % aiRecipeThreshold == 0 &&
           Date().timeIntervalSince(store.lastAICall) > aiCooldownSeconds {
            Task {
                await generateAIRecipe(for: host)
            }
        }
    }

    func getRecipe(for host: String) -> PreConditioningRecipe? {
        store.recipes[host]
    }

    func preConditionSession(for host: String) -> PreConditioningRecipe {
        if let existing = store.recipes[host], existing.totalDataPoints >= minDataForRecipe {
            logger.log("PreCondition: using recipe for \(host) (v\(existing.version), \(existing.totalDataPoints) data points, \(String(format: "%.0f%%", existing.successRate * 100)) success, ai=\(existing.aiGenerated))", category: .automation, level: .info)
            return existing
        }

        if let similar = findSimilarHostRecipe(for: host) {
            logger.log("PreCondition: no direct recipe for \(host), using similar host recipe (\(similar.host))", category: .automation, level: .info)
            return similar
        }

        logger.log("PreCondition: no recipe for \(host) — using defaults", category: .automation, level: .debug)
        return PreConditioningRecipe(host: host)
    }

    func bestPatternOrder(for host: String) -> [String]? {
        store.recipes[host]?.bestPatternOrder
    }

    func bestProxyType(for host: String) -> String? {
        store.recipes[host]?.bestProxyType
    }

    func allRecipes() -> [PreConditioningRecipe] {
        Array(store.recipes.values).sorted { $0.successRate > $1.successRate }
    }

    func resetHost(_ host: String) {
        store.recipes.removeValue(forKey: host)
        store.outcomeHistory.removeAll { $0.host == host }
        save()
    }

    func resetAll() {
        store = PreConditioningStore()
        save()
    }

    private func updateLocalRecipe(for host: String) {
        let records = store.outcomeHistory.filter { $0.host == host }
        guard records.count >= minDataForRecipe else { return }

        var recipe = store.recipes[host] ?? PreConditioningRecipe(host: host)

        let successRecords = records.filter { $0.wasSuccess }
        let totalSuccess = successRecords.count
        let totalAttempts = records.count
        recipe.successRate = totalAttempts > 0 ? Double(totalSuccess) / Double(totalAttempts) : 0
        recipe.totalDataPoints = totalAttempts

        var proxyScores: [String: (success: Int, total: Int)] = [:]
        for r in records {
            var entry = proxyScores[r.proxyType] ?? (0, 0)
            entry.total += 1
            if r.wasSuccess { entry.success += 1 }
            proxyScores[r.proxyType] = entry
        }
        let bestProxy = proxyScores
            .filter { $0.value.total >= 2 }
            .max(by: { Double($0.value.success) / Double($0.value.total) < Double($1.value.success) / Double($1.value.total) })
        recipe.bestProxyType = bestProxy?.key

        var patternScores: [String: (success: Int, total: Int)] = [:]
        for r in records {
            var entry = patternScores[r.patternUsed] ?? (0, 0)
            entry.total += 1
            if r.wasSuccess { entry.success += 1 }
            patternScores[r.patternUsed] = entry
        }
        let sortedPatterns = patternScores
            .filter { $0.value.total >= 2 }
            .sorted { Double($0.value.success) / Double($0.value.total) > Double($1.value.success) / Double($1.value.total) }
        if !sortedPatterns.isEmpty {
            recipe.bestPatternOrder = sortedPatterns.map(\.key)
        }

        var seedScores: [Int: (success: Int, total: Int)] = [:]
        for r in records {
            guard let seed = r.stealthSeed else { continue }
            var entry = seedScores[seed] ?? (0, 0)
            entry.total += 1
            if r.wasSuccess { entry.success += 1 }
            seedScores[seed] = entry
        }
        let bestSeed = seedScores
            .filter { $0.value.total >= 2 }
            .max(by: { Double($0.value.success) / Double($0.value.total) < Double($1.value.success) / Double($1.value.total) })
        recipe.bestStealthProfileSeed = bestSeed?.key

        var urlScores: [String: (success: Int, total: Int)] = [:]
        for r in records {
            var entry = urlScores[r.urlVariant] ?? (0, 0)
            entry.total += 1
            if r.wasSuccess { entry.success += 1 }
            urlScores[r.urlVariant] = entry
        }
        let bestURL = urlScores
            .filter { $0.value.total >= 2 }
            .max(by: { Double($0.value.success) / Double($0.value.total) < Double($1.value.success) / Double($1.value.total) })
        recipe.bestURLVariant = bestURL?.key

        let successLatencies = successRecords.map(\.latencyMs).sorted()
        if let median = successLatencies.isEmpty ? nil : successLatencies[successLatencies.count / 2] {
            let extraWait = max(0, min(5000, median / 4))
            recipe.recommendedPageLoadExtraMs = extraWait
        }

        recipe.lastUpdated = Date()
        recipe.version += 1
        store.recipes[host] = recipe
    }

    private func findSimilarHostRecipe(for host: String) -> PreConditioningRecipe? {
        let components = host.split(separator: ".").map(String.init)
        guard components.count >= 2 else { return nil }
        let domain = components.suffix(2).joined(separator: ".")

        for (existingHost, recipe) in store.recipes where existingHost != host {
            if existingHost.contains(domain) && recipe.totalDataPoints >= minDataForRecipe {
                return recipe
            }
        }
        return nil
    }

    private func generateAIRecipe(for host: String) async {
        let records = store.outcomeHistory.filter { $0.host == host }
        guard records.count >= aiRecipeThreshold else { return }

        var summaryData: [[String: Any]] = []
        for r in records.suffix(50) {
            summaryData.append([
                "proxy": r.proxyType,
                "pattern": r.patternUsed,
                "url": r.urlVariant,
                "outcome": r.outcome,
                "latencyMs": r.latencyMs,
                "success": r.wasSuccess,
                "challenge": r.wasChallenge,
                "blocked": r.wasBlocked,
            ])
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: ["host": host, "records": summaryData]),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

        let systemPrompt = """
        You optimize login automation session configurations for specific hosts. \
        Analyze the outcome history and return ONLY a JSON object with the optimal configuration recipe. \
        Format: {"bestProxyType":"...","bestPatternOrder":["pattern1","pattern2"],"bestURLVariant":"...","optimalTiming":{"keystrokeMinMs":N,"keystrokeMaxMs":N,"interFieldMinMs":N,"interFieldMaxMs":N,"preSubmitMinMs":N,"preSubmitMaxMs":N},"recommendedWaitBeforeSubmitMs":N,"recommendedPageLoadExtraMs":N,"reasoning":"brief explanation"}. \
        Focus on which combinations yielded the highest success rate. \
        Consider proxy types, patterns, URL variants, and timing. \
        Avoid configurations that led to challenges or blocks. \
        Return ONLY the JSON.
        """

        let userPrompt = "Session outcome data for \(host):\n\(jsonStr)"

        logger.log("PreCondition: requesting AI recipe for \(host) (\(records.count) records)", category: .automation, level: .info)

        store.aiRecipeCallCount += 1
        store.lastAICall = Date()
        save()

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: userPrompt) else {
            logger.log("PreCondition: AI recipe generation failed for \(host)", category: .automation, level: .warning)
            return
        }

        applyAIRecipe(response: response, host: host)
    }

    private func applyAIRecipe(response: String, host: String) {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.log("PreCondition: failed to parse AI recipe for \(host)", category: .automation, level: .warning)
            return
        }

        var recipe = store.recipes[host] ?? PreConditioningRecipe(host: host)
        recipe.aiGenerated = true
        recipe.aiReasoning = json["reasoning"] as? String

        if let proxy = json["bestProxyType"] as? String { recipe.bestProxyType = proxy }
        if let patterns = json["bestPatternOrder"] as? [String] { recipe.bestPatternOrder = patterns }
        if let url = json["bestURLVariant"] as? String { recipe.bestURLVariant = url }
        if let waitMs = json["recommendedWaitBeforeSubmitMs"] as? Int { recipe.recommendedWaitBeforeSubmitMs = waitMs }
        if let loadMs = json["recommendedPageLoadExtraMs"] as? Int { recipe.recommendedPageLoadExtraMs = loadMs }

        if let timing = json["optimalTiming"] as? [String: Any] {
            var t = OptimalTiming()
            if let v = timing["keystrokeMinMs"] as? Int { t.keystrokeMinMs = v }
            if let v = timing["keystrokeMaxMs"] as? Int { t.keystrokeMaxMs = v }
            if let v = timing["interFieldMinMs"] as? Int { t.interFieldMinMs = v }
            if let v = timing["interFieldMaxMs"] as? Int { t.interFieldMaxMs = v }
            if let v = timing["preSubmitMinMs"] as? Int { t.preSubmitMinMs = v }
            if let v = timing["preSubmitMaxMs"] as? Int { t.preSubmitMaxMs = v }
            recipe.optimalTimingProfile = t
        }

        recipe.lastUpdated = Date()
        recipe.version += 1
        store.recipes[host] = recipe
        save()

        logger.log("PreCondition: AI recipe applied for \(host) — \(recipe.aiReasoning ?? "no reasoning")", category: .automation, level: .success)
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: persistenceKey)
        }
    }
}
