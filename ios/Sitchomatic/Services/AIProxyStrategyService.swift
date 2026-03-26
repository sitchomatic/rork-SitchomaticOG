import Foundation

nonisolated struct ProxyHostOutcome: Codable, Sendable {
    let proxyId: String
    let host: String
    let target: String
    let success: Bool
    let latencyMs: Int
    let blocked: Bool
    let challengeDetected: Bool
    let timestamp: Date
}

nonisolated struct ProxyHostProfile: Codable, Sendable {
    var proxyId: String
    var host: String
    var successCount: Int = 0
    var failureCount: Int = 0
    var blockCount: Int = 0
    var challengeCount: Int = 0
    var totalLatencyMs: Int = 0
    var sampleCount: Int = 0
    var lastSuccessAt: Date?
    var lastFailureAt: Date?
    var lastAIOptimization: Date?
    var aiRecommendedWeight: Double?
    var cooldownUntil: Date?

    var successRate: Double {
        let total = successCount + failureCount
        guard total > 0 else { return 0.5 }
        return Double(successCount) / Double(total)
    }

    var blockRate: Double {
        let total = successCount + failureCount
        guard total > 0 else { return 0 }
        return Double(blockCount) / Double(total)
    }

    var avgLatencyMs: Int {
        guard sampleCount > 0 else { return 999 }
        return totalLatencyMs / sampleCount
    }

    var isCoolingDown: Bool {
        guard let until = cooldownUntil else { return false }
        return Date() < until
    }

    var compositeScore: Double {
        if isCoolingDown { return 0.01 }

        let srScore = successRate * 0.40
        let latScore = max(0, 1.0 - (Double(avgLatencyMs) / 10000.0)) * 0.25
        let blockPenalty = (1.0 - blockRate) * 0.20

        var recency = 0.3
        if let last = lastSuccessAt {
            let ago = Date().timeIntervalSince(last)
            recency = max(0, 1.0 - (ago / 3600.0))
        }
        let recencyScore = recency * 0.15

        let base = srScore + latScore + blockPenalty + recencyScore

        if let aiWeight = aiRecommendedWeight {
            return base * 0.6 + aiWeight * 0.4
        }
        return base
    }
}

nonisolated struct ProxyStrategyStore: Codable, Sendable {
    var profiles: [String: ProxyHostProfile] = [:]
    var recentOutcomes: [ProxyHostOutcome] = []
    var hostPreferences: [String: [String]] = [:]
    var rotationCooldowns: [String: Date] = [:]
    var lastGlobalAIAnalysis: Date = .distantPast
}

@MainActor
class AIProxyStrategyService {
    static let shared = AIProxyStrategyService()

    private let logger = DebugLogger.shared
    private let persistKey = "AIProxyStrategyData_v1"
    private let maxOutcomes = 1000
    private let maxProfilesPerHost = 50
    private let aiAnalysisThreshold = 30
    private let cooldownDuration: TimeInterval = 300
    private var store: ProxyStrategyStore


    private init() {
        if let saved = UserDefaults.standard.data(forKey: persistKey),
           let decoded = try? JSONDecoder().decode(ProxyStrategyStore.self, from: saved) {
            self.store = decoded
        } else {
            self.store = ProxyStrategyStore()
        }
    }

    func recordOutcome(
        proxyId: String,
        host: String,
        target: String,
        success: Bool,
        latencyMs: Int,
        blocked: Bool,
        challengeDetected: Bool
    ) {
        let outcome = ProxyHostOutcome(
            proxyId: proxyId,
            host: host,
            target: target,
            success: success,
            latencyMs: latencyMs,
            blocked: blocked,
            challengeDetected: challengeDetected,
            timestamp: Date()
        )
        store.recentOutcomes.append(outcome)
        if store.recentOutcomes.count > maxOutcomes {
            store.recentOutcomes.removeFirst(store.recentOutcomes.count - maxOutcomes)
        }

        let key = "\(proxyId)|\(host)"
        var profile = store.profiles[key] ?? ProxyHostProfile(proxyId: proxyId, host: host)

        if success {
            profile.successCount += 1
            profile.lastSuccessAt = Date()
        } else {
            profile.failureCount += 1
            profile.lastFailureAt = Date()
        }
        if blocked { profile.blockCount += 1 }
        if challengeDetected { profile.challengeCount += 1 }
        profile.totalLatencyMs += latencyMs
        profile.sampleCount += 1

        if blocked && profile.blockRate > 0.6 && profile.failureCount >= 3 {
            profile.cooldownUntil = Date().addingTimeInterval(cooldownDuration)
            logger.log("AIProxyStrategy: proxy \(proxyId.prefix(12)) COOLED DOWN for \(host) — block rate \(Int(profile.blockRate * 100))%", category: .proxy, level: .warning)
        }

        store.profiles[key] = profile
        save()


        let totalForHost = store.recentOutcomes.filter { $0.host == host }.count
        if totalForHost >= aiAnalysisThreshold && totalForHost % aiAnalysisThreshold == 0 {
            Task { await requestAIOptimization(host: host) }
        }
    }

    func bestProxyId(for host: String, from proxyIds: [String], target: String) -> String? {
        guard !proxyIds.isEmpty else { return nil }
        if proxyIds.count == 1 { return proxyIds.first }

        if let preferred = store.hostPreferences[host], !preferred.isEmpty {
            let available = preferred.filter { proxyIds.contains($0) }
            if let best = available.first(where: { id in
                let key = "\(id)|\(host)"
                let profile = store.profiles[key]
                return !(profile?.isCoolingDown ?? false)
            }) {
                logger.log("AIProxyStrategy: AI-preferred proxy \(best.prefix(12)) for \(host)", category: .proxy, level: .debug)
                return best
            }
        }

        let scored = proxyIds.map { id -> (String, Double) in
            let key = "\(id)|\(host)"
            let profile = store.profiles[key]
            let score = profile?.compositeScore ?? 0.5
            return (id, score)
        }.sorted { $0.1 > $1.1 }

        let topCount = max(1, min(3, scored.count))
        let topCandidates = Array(scored.prefix(topCount))
        let totalWeight = topCandidates.reduce(0.0) { $0 + max($1.1, 0.05) }

        guard totalWeight > 0 else { return proxyIds.randomElement() }

        var random = Double.random(in: 0..<totalWeight)
        for (id, weight) in topCandidates {
            random -= max(weight, 0.05)
            if random <= 0 { return id }
        }

        return topCandidates.last?.0
    }

    func bestProxy(for host: String, from proxies: [ProxyConfig], target: ProxyRotationService.ProxyTarget) -> ProxyConfig? {
        let ids = proxies.map { $0.id.uuidString }
        guard let bestId = bestProxyId(for: host, from: ids, target: target.rawValue) else { return nil }
        return proxies.first { $0.id.uuidString == bestId }
    }

    func shouldRotateProxy(currentProxyId: String, host: String) -> Bool {
        let key = "\(currentProxyId)|\(host)"
        guard let profile = store.profiles[key] else { return false }

        if profile.isCoolingDown { return true }
        if profile.blockRate > 0.5 && profile.failureCount >= 3 { return true }
        if profile.successRate < 0.2 && profile.sampleCount >= 5 { return true }

        return false
    }

    func proxyPerformanceSummary(for host: String) -> [(proxyId: String, score: Double, successRate: Int, avgLatency: Int, blocks: Int)] {
        store.profiles
            .filter { $0.value.host == host }
            .map { (_, profile) in
                (profile.proxyId, profile.compositeScore, Int(profile.successRate * 100), profile.avgLatencyMs, profile.blockCount)
            }
            .sorted { $0.1 > $1.1 }
    }

    func allHostStats() -> [(host: String, proxyCount: Int, avgSuccessRate: Int, totalSamples: Int)] {
        let grouped = Dictionary(grouping: store.profiles.values) { $0.host }
        return grouped.map { host, profiles in
            let avgSR = profiles.isEmpty ? 0 : Int(profiles.map(\.successRate).reduce(0, +) / Double(profiles.count) * 100)
            let totalSamples = profiles.reduce(0) { $0 + $1.sampleCount }
            return (host, profiles.count, avgSR, totalSamples)
        }.sorted { $0.3 > $1.3 }
    }

    func resetHost(_ host: String) {
        store.profiles = store.profiles.filter { $0.value.host != host }
        store.recentOutcomes.removeAll { $0.host == host }
        store.hostPreferences.removeValue(forKey: host)
        save()
        logger.log("AIProxyStrategy: reset all data for \(host)", category: .proxy, level: .warning)
    }

    func resetAll() {
        store = ProxyStrategyStore()
        save()
        logger.log("AIProxyStrategy: all data RESET", category: .proxy, level: .warning)
    }

    private func requestAIOptimization(host: String) async {
        let hostOutcomes = store.recentOutcomes.filter { $0.host == host }
        guard hostOutcomes.count >= 15 else { return }

        let proxyGroups = Dictionary(grouping: hostOutcomes) { $0.proxyId }
        var proxySummaries: [[String: Any]] = []

        for (proxyId, outcomes) in proxyGroups {
            let successes = outcomes.filter { $0.success }.count
            let blocks = outcomes.filter { $0.blocked }.count
            let challenges = outcomes.filter { $0.challengeDetected }.count
            let avgLatency = outcomes.isEmpty ? 0 : outcomes.map(\.latencyMs).reduce(0, +) / outcomes.count

            proxySummaries.append([
                "proxyId": String(proxyId.prefix(12)),
                "total": outcomes.count,
                "successes": successes,
                "blocks": blocks,
                "challenges": challenges,
                "avgLatencyMs": avgLatency,
                "successRate": outcomes.isEmpty ? 0 : Int(Double(successes) / Double(outcomes.count) * 100),
            ])
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: proxySummaries),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

        let systemPrompt = """
        You optimize proxy rotation strategy for web automation targeting a specific host. \
        Analyze the proxy performance data and return ONLY a JSON object with: \
        {"rankedProxies":["proxyId1","proxyId2"],"weights":{"proxyId1":0.9,"proxyId2":0.5},"cooldowns":["proxyId3"],"reasoning":"brief reason"}. \
        Rank proxies by effectiveness (high success, low blocks, low latency). \
        Proxies with high block rates should get low weights or be cooled down. \
        Return ONLY the JSON.
        """

        let userPrompt = "Host: \(host)\nProxy performance data:\n\(jsonStr)"

        logger.log("AIProxyStrategy: requesting AI optimization for \(host) (\(hostOutcomes.count) outcomes, \(proxyGroups.count) proxies)", category: .proxy, level: .info)

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: userPrompt) else {
            logger.log("AIProxyStrategy: AI optimization failed for \(host) — no response", category: .proxy, level: .warning)
            return
        }

        applyAIOptimization(host: host, response: response)
    }

    private func applyAIOptimization(host: String, response: String) {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.log("AIProxyStrategy: failed to parse AI response for \(host)", category: .proxy, level: .warning)
            return
        }

        if let ranked = json["rankedProxies"] as? [String] {
            let fullIds = resolveFullProxyIds(prefixes: ranked, host: host)
            if !fullIds.isEmpty {
                store.hostPreferences[host] = fullIds
                logger.log("AIProxyStrategy: AI ranked \(fullIds.count) proxies for \(host)", category: .proxy, level: .info)
            }
        }

        if let weights = json["weights"] as? [String: Double] {
            var applied = 0
            for (prefix, weight) in weights {
                let clamped = max(0.01, min(1.0, weight))
                for (key, var profile) in store.profiles where profile.host == host && profile.proxyId.hasPrefix(prefix) {
                    profile.aiRecommendedWeight = clamped
                    profile.lastAIOptimization = Date()
                    store.profiles[key] = profile
                    applied += 1
                }
            }
            logger.log("AIProxyStrategy: AI weights applied to \(applied) proxy-host pairs for \(host)", category: .proxy, level: .info)
        }

        if let cooldowns = json["cooldowns"] as? [String] {
            let cooldownDate = Date().addingTimeInterval(cooldownDuration)
            for prefix in cooldowns {
                for (key, var profile) in store.profiles where profile.host == host && profile.proxyId.hasPrefix(prefix) {
                    profile.cooldownUntil = cooldownDate
                    store.profiles[key] = profile
                }
            }
            if !cooldowns.isEmpty {
                logger.log("AIProxyStrategy: AI cooled down \(cooldowns.count) proxies for \(host)", category: .proxy, level: .warning)
            }
        }

        if let reasoning = json["reasoning"] as? String {
            logger.log("AIProxyStrategy: AI reasoning for \(host): \(reasoning)", category: .proxy, level: .info)
        }

        store.lastGlobalAIAnalysis = Date()
        save()
    }

    private func resolveFullProxyIds(prefixes: [String], host: String) -> [String] {
        var resolved: [String] = []
        for prefix in prefixes {
            if let match = store.profiles.values.first(where: { $0.host == host && $0.proxyId.hasPrefix(prefix) }) {
                resolved.append(match.proxyId)
            }
        }
        return resolved
    }



    private func save() {
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: persistKey)
        }
    }
}
