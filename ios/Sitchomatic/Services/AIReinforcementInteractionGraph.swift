import Foundation

nonisolated struct InteractionAction: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    let actionType: String
    let detail: String
    let durationMs: Int
    let delayBeforeMs: Int
    let success: Bool
    let timestamp: Date
}

nonisolated struct InteractionSequence: Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    let host: String
    let actions: [InteractionAction]
    let finalOutcome: String
    let wasSuccess: Bool
    let totalDurationMs: Int
    let patternUsed: String
    let proxyType: String
    let stealthSeed: Int?
    let timestamp: Date
    var reward: Double = 0
}

nonisolated struct ActionNode: Codable, Sendable {
    var actionType: String
    var detail: String
    var totalOccurrences: Int = 0
    var successOccurrences: Int = 0
    var cumulativeReward: Double = 0
    var avgDurationMs: Double = 0
    var avgDelayBeforeMs: Double = 0
    var bestFollowUp: String?
    var lastUpdated: Date = .distantPast

    var successRate: Double {
        totalOccurrences > 0 ? Double(successOccurrences) / Double(totalOccurrences) : 0
    }

    var avgReward: Double {
        totalOccurrences > 0 ? cumulativeReward / Double(totalOccurrences) : 0
    }
}

nonisolated struct InteractionRecipe: Codable, Sendable {
    var host: String
    var recommendedActions: [RecommendedAction]
    var confidence: Double
    var dataPoints: Int
    var aiOptimized: Bool = false
    var aiReasoning: String?
    var lastUpdated: Date = .distantPast
    var version: Int = 0
}

nonisolated struct RecommendedAction: Codable, Sendable {
    let actionType: String
    let detail: String
    let recommendedDurationMs: Int
    let recommendedDelayBeforeMs: Int
    let expectedSuccessRate: Double
    let reward: Double
}

nonisolated struct InteractionGraphStore: Codable, Sendable {
    var hostGraphs: [String: [String: ActionNode]] = [:]
    var sequences: [InteractionSequence] = []
    var recipes: [String: InteractionRecipe] = [:]
    var aiAnalysisCount: Int = 0
    var lastAIAnalysis: Date = .distantPast
}

@MainActor
class AIReinforcementInteractionGraph {
    static let shared = AIReinforcementInteractionGraph()

    private let logger = DebugLogger.shared
    private let persistenceKey = "AIReinforcementInteractionGraph_v1"
    private let maxSequences = 2000
    private let maxActionsPerSequence = 50
    private let convergenceThreshold = 10
    private let aiAnalysisCooldownSeconds: TimeInterval = 900
    private let decayFactor: Double = 0.95
    private var store: InteractionGraphStore

    private init() {
        if let saved = UserDefaults.standard.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode(InteractionGraphStore.self, from: saved) {
            self.store = decoded
        } else {
            self.store = InteractionGraphStore()
        }
    }

    func recordSequence(
        host: String,
        actions: [InteractionAction],
        finalOutcome: String,
        wasSuccess: Bool,
        totalDurationMs: Int,
        patternUsed: String,
        proxyType: String,
        stealthSeed: Int?
    ) {
        let trimmedActions = Array(actions.prefix(maxActionsPerSequence))
        let reward = computeReward(outcome: finalOutcome, wasSuccess: wasSuccess, durationMs: totalDurationMs, actionCount: trimmedActions.count)

        let sequence = InteractionSequence(
            host: host,
            actions: trimmedActions,
            finalOutcome: finalOutcome,
            wasSuccess: wasSuccess,
            totalDurationMs: totalDurationMs,
            patternUsed: patternUsed,
            proxyType: proxyType,
            stealthSeed: stealthSeed,
            timestamp: Date(),
            reward: reward
        )

        store.sequences.append(sequence)
        if store.sequences.count > maxSequences {
            store.sequences.removeFirst(store.sequences.count - maxSequences)
        }

        updateGraph(host: host, actions: trimmedActions, reward: reward, wasSuccess: wasSuccess)
        applyDecay(host: host)

        let hostSequences = store.sequences.filter { $0.host == host }
        if hostSequences.count >= convergenceThreshold {
            updateRecipe(for: host)
        }

        save()

        if hostSequences.count >= convergenceThreshold * 2 &&
           hostSequences.count % (convergenceThreshold * 2) == 0 &&
           Date().timeIntervalSince(store.lastAIAnalysis) > aiAnalysisCooldownSeconds {
            Task {
                await requestAIOptimization(for: host)
            }
        }

        logger.log("InteractionGraph: recorded \(trimmedActions.count) actions for \(host) — outcome=\(finalOutcome) reward=\(String(format: "%.2f", reward)) total_sequences=\(hostSequences.count)", category: .automation, level: .debug)
    }

    func getRecipe(for host: String) -> InteractionRecipe? {
        store.recipes[host]
    }

    func recommendNextAction(for host: String, afterAction: String?) -> RecommendedAction? {
        guard let graph = store.hostGraphs[host] else { return nil }

        if let afterAction {
            if let node = graph[afterAction], let followUp = node.bestFollowUp, let followNode = graph[followUp] {
                return RecommendedAction(
                    actionType: followNode.actionType,
                    detail: followNode.detail,
                    recommendedDurationMs: Int(followNode.avgDurationMs),
                    recommendedDelayBeforeMs: Int(followNode.avgDelayBeforeMs),
                    expectedSuccessRate: followNode.successRate,
                    reward: followNode.avgReward
                )
            }
        }

        let bestNode = graph.values
            .filter { $0.totalOccurrences >= 3 }
            .max(by: { $0.avgReward < $1.avgReward })

        guard let best = bestNode else { return nil }
        return RecommendedAction(
            actionType: best.actionType,
            detail: best.detail,
            recommendedDurationMs: Int(best.avgDurationMs),
            recommendedDelayBeforeMs: Int(best.avgDelayBeforeMs),
            expectedSuccessRate: best.successRate,
            reward: best.avgReward
        )
    }

    func recommendPatternOrder(for host: String) -> [String]? {
        let hostSequences = store.sequences.filter { $0.host == host }
        guard hostSequences.count >= convergenceThreshold else { return nil }

        var patternScores: [String: (totalReward: Double, count: Int)] = [:]
        for seq in hostSequences {
            var entry = patternScores[seq.patternUsed] ?? (0, 0)
            entry.totalReward += seq.reward
            entry.count += 1
            patternScores[seq.patternUsed] = entry
        }

        let sorted = patternScores
            .filter { $0.value.count >= 2 }
            .sorted { ($0.value.totalReward / Double($0.value.count)) > ($1.value.totalReward / Double($1.value.count)) }

        guard !sorted.isEmpty else { return nil }
        return sorted.map(\.key)
    }

    func convergenceLevel(for host: String) -> (converged: Bool, dataPoints: Int, confidence: Double) {
        let hostSequences = store.sequences.filter { $0.host == host }
        let count = hostSequences.count
        guard count >= 3 else { return (false, count, 0) }

        let recent = hostSequences.suffix(min(count, 10))
        let successRate = Double(recent.filter(\.wasSuccess).count) / Double(recent.count)
        let confidence = min(1.0, Double(count) / Double(convergenceThreshold * 3)) * successRate

        return (count >= convergenceThreshold, count, confidence)
    }

    func hostStats() -> [(host: String, sequences: Int, converged: Bool, confidence: Double, topPattern: String?)] {
        var hosts: Set<String> = []
        for seq in store.sequences { hosts.insert(seq.host) }

        return hosts.map { host in
            let conv = convergenceLevel(for: host)
            let topPattern = recommendPatternOrder(for: host)?.first
            return (host, conv.dataPoints, conv.converged, conv.confidence, topPattern)
        }.sorted { $0.sequences > $1.sequences }
    }

    func allRecipes() -> [InteractionRecipe] {
        Array(store.recipes.values).sorted { $0.confidence > $1.confidence }
    }

    func resetHost(_ host: String) {
        store.hostGraphs.removeValue(forKey: host)
        store.recipes.removeValue(forKey: host)
        store.sequences.removeAll { $0.host == host }
        save()
    }

    func resetAll() {
        store = InteractionGraphStore()
        save()
    }

    private func computeReward(outcome: String, wasSuccess: Bool, durationMs: Int, actionCount: Int) -> Double {
        var reward: Double = 0

        if wasSuccess {
            reward += 1.0
        }

        switch outcome {
        case "success": reward += 1.0
        case "noAcc": reward += 0.3
        case "permDisabled", "tempDisabled": reward += 0.4
        case "unsure": reward -= 0.2
        case "timeout": reward -= 0.5
        case "connectionFailure": reward -= 0.7
        default: reward -= 0.1
        }

        let speedBonus = max(0, 1.0 - (Double(durationMs) / 60000.0)) * 0.2
        reward += speedBonus

        let efficiencyBonus = max(0, 1.0 - (Double(actionCount) / 30.0)) * 0.1
        reward += efficiencyBonus

        return max(-1.0, min(2.5, reward))
    }

    private func updateGraph(host: String, actions: [InteractionAction], reward: Double, wasSuccess: Bool) {
        var graph = store.hostGraphs[host] ?? [:]

        for (index, action) in actions.enumerated() {
            let key = "\(action.actionType)_\(action.detail)"
            var node = graph[key] ?? ActionNode(actionType: action.actionType, detail: action.detail)

            node.totalOccurrences += 1
            if wasSuccess { node.successOccurrences += 1 }

            let actionReward = reward * pow(0.9, Double(actions.count - 1 - index))
            node.cumulativeReward += actionReward

            let prevDuration = node.avgDurationMs
            node.avgDurationMs = prevDuration + (Double(action.durationMs) - prevDuration) / Double(node.totalOccurrences)

            let prevDelay = node.avgDelayBeforeMs
            node.avgDelayBeforeMs = prevDelay + (Double(action.delayBeforeMs) - prevDelay) / Double(node.totalOccurrences)

            if index + 1 < actions.count {
                let nextKey = "\(actions[index + 1].actionType)_\(actions[index + 1].detail)"
                if let currentBest = node.bestFollowUp, let currentBestNode = graph[currentBest] {
                    let nextNode = graph[nextKey]
                    if let nextNode, nextNode.avgReward > currentBestNode.avgReward {
                        node.bestFollowUp = nextKey
                    }
                } else {
                    node.bestFollowUp = nextKey
                }
            }

            node.lastUpdated = Date()
            graph[key] = node
        }

        store.hostGraphs[host] = graph
    }

    private func applyDecay(host: String) {
        guard var graph = store.hostGraphs[host] else { return }

        let cutoff = Date().addingTimeInterval(-86400 * 7)
        var keysToRemove: [String] = []

        for (key, var node) in graph {
            if node.lastUpdated < cutoff {
                node.cumulativeReward *= decayFactor
                if node.totalOccurrences <= 1 && node.cumulativeReward < 0.01 {
                    keysToRemove.append(key)
                } else {
                    graph[key] = node
                }
            }
        }

        for key in keysToRemove {
            graph.removeValue(forKey: key)
        }

        store.hostGraphs[host] = graph
    }

    private func updateRecipe(for host: String) {
        guard let graph = store.hostGraphs[host] else { return }

        let sortedNodes = graph.values
            .filter { $0.totalOccurrences >= 2 }
            .sorted { $0.avgReward > $1.avgReward }

        guard !sortedNodes.isEmpty else { return }

        let recommendedActions = sortedNodes.prefix(15).map { node in
            RecommendedAction(
                actionType: node.actionType,
                detail: node.detail,
                recommendedDurationMs: Int(node.avgDurationMs),
                recommendedDelayBeforeMs: Int(node.avgDelayBeforeMs),
                expectedSuccessRate: node.successRate,
                reward: node.avgReward
            )
        }

        let conv = convergenceLevel(for: host)

        var recipe = store.recipes[host] ?? InteractionRecipe(host: host, recommendedActions: [], confidence: 0, dataPoints: 0)
        recipe.recommendedActions = Array(recommendedActions)
        recipe.confidence = conv.confidence
        recipe.dataPoints = conv.dataPoints
        recipe.lastUpdated = Date()
        recipe.version += 1

        store.recipes[host] = recipe

        logger.log("InteractionGraph: updated recipe for \(host) — \(recommendedActions.count) actions, confidence=\(String(format: "%.0f%%", conv.confidence * 100)), data=\(conv.dataPoints)", category: .automation, level: .info)
    }

    private func requestAIOptimization(for host: String) async {
        let hostSequences = store.sequences.filter { $0.host == host }
        guard hostSequences.count >= convergenceThreshold else { return }

        var sequenceData: [[String: Any]] = []
        for seq in hostSequences.suffix(30) {
            let actions = seq.actions.map { a -> [String: Any] in
                [
                    "type": a.actionType,
                    "detail": a.detail,
                    "durationMs": a.durationMs,
                    "delayBeforeMs": a.delayBeforeMs,
                    "success": a.success,
                ]
            }
            sequenceData.append([
                "pattern": seq.patternUsed,
                "outcome": seq.finalOutcome,
                "success": seq.wasSuccess,
                "reward": seq.reward,
                "totalMs": seq.totalDurationMs,
                "actions": actions,
            ])
        }

        var graphData: [[String: Any]] = []
        if let graph = store.hostGraphs[host] {
            for (_, node) in graph where node.totalOccurrences >= 3 {
                graphData.append([
                    "action": "\(node.actionType)_\(node.detail)",
                    "occurrences": node.totalOccurrences,
                    "successRate": String(format: "%.2f", node.successRate),
                    "avgReward": String(format: "%.2f", node.avgReward),
                    "avgDurationMs": Int(node.avgDurationMs),
                    "bestFollowUp": node.bestFollowUp ?? "none",
                ])
            }
        }

        let payload: [String: Any] = [
            "host": host,
            "sequences": sequenceData,
            "graph": graphData,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

        let systemPrompt = """
        You optimize interaction sequences for web automation login flows. \
        Analyze the reinforcement interaction graph and sequence history to identify: \
        1. Bottleneck actions that cause failures \
        2. Optimal action ordering for maximum success rate \
        3. Ideal timing between actions \
        4. Which patterns work best and why \
        Return ONLY a JSON object: {"optimizedActions":[{"actionType":"...","detail":"...","recommendedDurationMs":N,"recommendedDelayBeforeMs":N}],"bottlenecks":["action1","action2"],"reasoning":"brief explanation","suggestedPatternOrder":["pattern1","pattern2"]}. \
        Return ONLY the JSON.
        """

        let userPrompt = "Interaction data for \(host):\n\(jsonStr)"

        logger.log("InteractionGraph: requesting AI optimization for \(host)", category: .automation, level: .info)

        store.aiAnalysisCount += 1
        store.lastAIAnalysis = Date()
        save()

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: userPrompt) else {
            logger.log("InteractionGraph: AI optimization failed for \(host)", category: .automation, level: .warning)
            return
        }

        applyAIOptimization(response: response, host: host)
    }

    private func applyAIOptimization(response: String, host: String) {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.log("InteractionGraph: failed to parse AI response for \(host)", category: .automation, level: .warning)
            return
        }

        var recipe = store.recipes[host] ?? InteractionRecipe(host: host, recommendedActions: [], confidence: 0, dataPoints: 0)
        recipe.aiOptimized = true
        recipe.aiReasoning = json["reasoning"] as? String

        if let optimizedActions = json["optimizedActions"] as? [[String: Any]] {
            let aiActions = optimizedActions.compactMap { a -> RecommendedAction? in
                guard let type = a["actionType"] as? String,
                      let detail = a["detail"] as? String else { return nil }
                return RecommendedAction(
                    actionType: type,
                    detail: detail,
                    recommendedDurationMs: a["recommendedDurationMs"] as? Int ?? 0,
                    recommendedDelayBeforeMs: a["recommendedDelayBeforeMs"] as? Int ?? 0,
                    expectedSuccessRate: 0,
                    reward: 0
                )
            }
            if !aiActions.isEmpty {
                recipe.recommendedActions = aiActions
            }
        }

        recipe.lastUpdated = Date()
        recipe.version += 1
        store.recipes[host] = recipe
        save()

        if let bottlenecks = json["bottlenecks"] as? [String] {
            logger.log("InteractionGraph: AI identified bottlenecks for \(host): \(bottlenecks.joined(separator: ", "))", category: .automation, level: .warning)
        }

        logger.log("InteractionGraph: AI optimization applied for \(host) — \(recipe.aiReasoning ?? "no reasoning")", category: .automation, level: .success)
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: persistenceKey)
        }
    }
}
