import Foundation

@MainActor
class AIPredictiveRouteService {
    static let shared = AIPredictiveRouteService()

    private let logger = DebugLogger.shared
    private let persistKey = "ai_predictive_route_v1"

    private var hostProtocolScores: [String: [String: ProtocolProfile]] = [:]
    private var timeOfDayPatterns: [String: [Int: [String: Double]]] = [:]
    private var lastAIAnalysis: Date = .distantPast
    private let aiAnalysisInterval: TimeInterval = 300

    private struct ProtocolProfile: Codable {
        var method: String
        var region: String
        var successCount: Int = 0
        var failureCount: Int = 0
        var totalLatencyMs: Int = 0
        var sampleCount: Int = 0
        var blockCount: Int = 0
        var timeoutCount: Int = 0
        var lastUsed: Date?
        var lastSuccess: Date?

        var successRate: Double {
            let total = successCount + failureCount
            guard total > 0 else { return 0.5 }
            return Double(successCount) / Double(total)
        }

        var avgLatencyMs: Int {
            guard sampleCount > 0 else { return 5000 }
            return totalLatencyMs / sampleCount
        }

        var compositeScore: Double {
            let total = successCount + failureCount
            guard total >= 2 else { return 0.5 }

            let srWeight = successRate * 0.40
            let latWeight = max(0, 1.0 - (Double(avgLatencyMs) / 15000.0)) * 0.25
            let blockPenalty = total > 0 ? (1.0 - (Double(blockCount) / Double(total))) * 0.15 : 0.15
            let timeoutPenalty = total > 0 ? (1.0 - (Double(timeoutCount) / Double(total))) * 0.10 : 0.10

            var recency = 0.5
            if let last = lastSuccess {
                let ago = Date().timeIntervalSince(last)
                recency = max(0, 1.0 - (ago / 3600.0))
            }
            let recencyScore = recency * 0.10

            return srWeight + latWeight + blockPenalty + timeoutPenalty + recencyScore
        }
    }

    nonisolated struct RouteRecommendation: Sendable {
        let method: HybridNetworkingService.HybridMethod
        let region: String
        let confidence: Double
        let reason: String
    }

    init() {
        loadPersisted()
    }

    func recordOutcome(
        host: String,
        method: HybridNetworkingService.HybridMethod,
        region: String,
        success: Bool,
        latencyMs: Int,
        wasBlocked: Bool = false,
        wasTimeout: Bool = false
    ) {
        let methodKey = method.rawValue
        let profileKey = "\(methodKey)_\(region)"

        if hostProtocolScores[host] == nil {
            hostProtocolScores[host] = [:]
        }

        var profile = hostProtocolScores[host]?[profileKey] ?? ProtocolProfile(method: methodKey, region: region)
        if success {
            profile.successCount += 1
            profile.lastSuccess = Date()
        } else {
            profile.failureCount += 1
        }
        if wasBlocked { profile.blockCount += 1 }
        if wasTimeout { profile.timeoutCount += 1 }
        profile.totalLatencyMs += latencyMs
        profile.sampleCount += 1
        profile.lastUsed = Date()
        hostProtocolScores[host]?[profileKey] = profile

        let hour = Calendar.current.component(.hour, from: Date())
        if timeOfDayPatterns[host] == nil { timeOfDayPatterns[host] = [:] }
        if timeOfDayPatterns[host]?[hour] == nil { timeOfDayPatterns[host]?[hour] = [:] }

        let currentScore = timeOfDayPatterns[host]?[hour]?[profileKey] ?? 0.5
        let newScore = success ? min(1.0, currentScore + 0.05) : max(0.0, currentScore - 0.08)
        timeOfDayPatterns[host]?[hour]?[profileKey] = newScore

        persistScores()
    }

    func rankedMethods(
        for host: String,
        available: [HybridNetworkingService.HybridMethod]
    ) -> [HybridNetworkingService.HybridMethod] {
        guard let profiles = hostProtocolScores[host], !profiles.isEmpty else {
            return available
        }

        let hour = Calendar.current.component(.hour, from: Date())
        let todPatterns = timeOfDayPatterns[host]?[hour] ?? [:]

        var methodScores: [HybridNetworkingService.HybridMethod: Double] = [:]

        for method in available {
            let methodKey = method.rawValue
            let relevantProfiles = profiles.filter { $0.value.method == methodKey }

            if relevantProfiles.isEmpty {
                methodScores[method] = 0.5
                continue
            }

            let bestProfile = relevantProfiles.max(by: { $0.value.compositeScore < $1.value.compositeScore })
            var score = bestProfile?.value.compositeScore ?? 0.5

            if let todScore = todPatterns.first(where: { $0.key.hasPrefix(methodKey) })?.value {
                score = score * 0.7 + todScore * 0.3
            }

            methodScores[method] = score
        }

        let ranked = available.sorted { a, b in
            let scoreA = methodScores[a] ?? 0.5
            let scoreB = methodScores[b] ?? 0.5
            if abs(scoreA - scoreB) < 0.03 {
                return a.priority < b.priority
            }
            return scoreA > scoreB
        }

        if ranked != available {
            let labels = ranked.map { "\($0.rawValue):\(Int((methodScores[$0] ?? 0.5) * 100))%" }
            logger.log("PredictiveRoute: \(host) ranked → \(labels.joined(separator: ", "))", category: .network, level: .debug)
        }

        return ranked
    }

    func bestRegionForMethod(
        host: String,
        method: HybridNetworkingService.HybridMethod
    ) -> String? {
        guard let profiles = hostProtocolScores[host] else { return nil }
        let methodKey = method.rawValue
        let relevant = profiles.filter { $0.value.method == methodKey && $0.value.sampleCount >= 2 }
        guard !relevant.isEmpty else { return nil }

        let best = relevant.max(by: { $0.value.compositeScore < $1.value.compositeScore })
        return best?.value.region
    }

    func recommend(for host: String, available: [HybridNetworkingService.HybridMethod]) -> RouteRecommendation? {
        let ranked = rankedMethods(for: host, available: available)
        guard let top = ranked.first else { return nil }

        let profiles = hostProtocolScores[host] ?? [:]
        let methodKey = top.rawValue
        let topProfiles = profiles.filter { $0.value.method == methodKey }
        let bestProfile = topProfiles.max(by: { $0.value.compositeScore < $1.value.compositeScore })

        let confidence = bestProfile?.value.compositeScore ?? 0.5
        let region = bestProfile?.value.region ?? "auto"
        let total = (bestProfile?.value.successCount ?? 0) + (bestProfile?.value.failureCount ?? 0)
        let reason = total >= 5 ? "Based on \(total) samples, \(Int(confidence * 100))% confidence" : "Limited data (\(total) samples)"

        return RouteRecommendation(method: top, region: region, confidence: confidence, reason: reason)
    }

    func degradedMethods(for host: String, threshold: Double = 0.3) -> [HybridNetworkingService.HybridMethod] {
        guard let profiles = hostProtocolScores[host] else { return [] }
        var degraded: Set<String> = []

        for (_, profile) in profiles {
            let total = profile.successCount + profile.failureCount
            if total >= 3 && profile.successRate < threshold {
                degraded.insert(profile.method)
            }
        }

        return degraded.compactMap { HybridNetworkingService.HybridMethod(rawValue: $0) }
    }

    func shouldPreemptivelySwitch(host: String, currentMethod: HybridNetworkingService.HybridMethod) -> HybridNetworkingService.HybridMethod? {
        guard let profiles = hostProtocolScores[host] else { return nil }
        let methodKey = currentMethod.rawValue
        let currentProfiles = profiles.filter { $0.value.method == methodKey }

        guard let current = currentProfiles.max(by: { $0.value.compositeScore < $1.value.compositeScore }) else { return nil }

        if current.value.compositeScore > 0.4 { return nil }

        let alternatives = profiles.filter { $0.value.method != methodKey && $0.value.sampleCount >= 2 }
        guard let best = alternatives.max(by: { $0.value.compositeScore < $1.value.compositeScore }) else { return nil }

        if best.value.compositeScore > current.value.compositeScore + 0.15 {
            let method = HybridNetworkingService.HybridMethod(rawValue: best.value.method)
            if let method {
                logger.log("PredictiveRoute: recommending switch from \(currentMethod.rawValue) → \(method.rawValue) for \(host) (score \(Int(current.value.compositeScore * 100))% → \(Int(best.value.compositeScore * 100))%)", category: .network, level: .info)
            }
            return method
        }

        return nil
    }

    func summary(for host: String) -> String {
        guard let profiles = hostProtocolScores[host], !profiles.isEmpty else { return "No data" }
        let grouped = Dictionary(grouping: profiles.values, by: \.method)
        return grouped.map { method, profs in
            let best = profs.max(by: { $0.compositeScore < $1.compositeScore })
            return "\(method):\(Int((best?.compositeScore ?? 0) * 100))%"
        }.sorted().joined(separator: " | ")
    }

    func resetHost(_ host: String) {
        hostProtocolScores.removeValue(forKey: host)
        timeOfDayPatterns.removeValue(forKey: host)
        persistScores()
    }

    func resetAll() {
        hostProtocolScores.removeAll()
        timeOfDayPatterns.removeAll()
        persistScores()
    }

    private func persistScores() {
        var flat: [String: [String: [String: Double]]] = [:]
        for (host, profiles) in hostProtocolScores {
            flat[host] = [:]
            for (key, profile) in profiles {
                flat[host]?[key] = [
                    "score": profile.compositeScore,
                    "sr": profile.successRate,
                    "lat": Double(profile.avgLatencyMs),
                    "n": Double(profile.sampleCount)
                ]
            }
        }
        if let data = try? JSONEncoder().encode(flat) {
            UserDefaults.standard.set(data, forKey: persistKey)
        }
    }

    private func loadPersisted() {
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let flat = try? JSONDecoder().decode([String: [String: [String: Double]]].self, from: data) else { return }

        for (host, profiles) in flat {
            hostProtocolScores[host] = [:]
            for (key, values) in profiles {
                let parts = key.split(separator: "_", maxSplits: 1)
                let method = parts.count > 0 ? String(parts[0]) : key
                let region = parts.count > 1 ? String(parts[1]) : "unknown"
                let n = Int(values["n"] ?? 0)
                let sr = values["sr"] ?? 0.5
                let lat = Int(values["lat"] ?? 5000)
                var profile = ProtocolProfile(method: method, region: region)
                profile.sampleCount = n
                profile.successCount = Int(sr * Double(n))
                profile.failureCount = n - profile.successCount
                profile.totalLatencyMs = lat * n
                hostProtocolScores[host]?[key] = profile
            }
        }
    }
}
