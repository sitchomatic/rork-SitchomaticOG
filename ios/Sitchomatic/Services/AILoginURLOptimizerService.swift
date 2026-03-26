import Foundation

nonisolated struct URLOutcomeSample: Codable, Sendable {
    let urlString: String
    let host: String
    let outcome: String
    let latencyMs: Int
    let blocked: Bool
    let challengeDetected: Bool
    let blankPage: Bool
    let timestamp: Date
}

nonisolated struct URLPerformanceProfile: Codable, Sendable {
    var urlString: String
    var host: String
    var successCount: Int = 0
    var failureCount: Int = 0
    var timeoutCount: Int = 0
    var blockCount: Int = 0
    var challengeCount: Int = 0
    var blankPageCount: Int = 0
    var loginSuccessCount: Int = 0
    var totalLatencyMs: Int = 0
    var sampleCount: Int = 0
    var lastSuccessAt: Date?
    var lastFailureAt: Date?
    var lastBlockAt: Date?
    var aiRecommendedWeight: Double?
    var aiCooldownUntil: Date?
    var consecutiveFailures: Int = 0
    var lastAIOptimization: Date?

    var totalAttempts: Int { successCount + failureCount }

    var successRate: Double {
        guard totalAttempts > 0 else { return 0.5 }
        return Double(successCount) / Double(totalAttempts)
    }

    var blockRate: Double {
        guard totalAttempts > 0 else { return 0 }
        return Double(blockCount) / Double(totalAttempts)
    }

    var challengeRate: Double {
        guard totalAttempts > 0 else { return 0 }
        return Double(challengeCount) / Double(totalAttempts)
    }

    var blankPageRate: Double {
        guard totalAttempts > 0 else { return 0 }
        return Double(blankPageCount) / Double(totalAttempts)
    }

    var avgLatencyMs: Int {
        guard sampleCount > 0 else { return 9999 }
        return totalLatencyMs / sampleCount
    }

    var isCoolingDown: Bool {
        guard let until = aiCooldownUntil else { return false }
        return Date() < until
    }

    var compositeScore: Double {
        if isCoolingDown { return 0.01 }
        guard totalAttempts >= 2 else { return 0.5 }

        let srScore = successRate * 0.30
        let latScore = max(0, 1.0 - (Double(avgLatencyMs) / 15000.0)) * 0.20
        let blockPenalty = (1.0 - blockRate) * 0.15
        let challengePenalty = (1.0 - challengeRate) * 0.10
        let blankPenalty = (1.0 - blankPageRate) * 0.10
        let loginBonus = (totalAttempts > 0 ? Double(loginSuccessCount) / Double(totalAttempts) : 0) * 0.15

        var recency = 0.3
        if let last = lastSuccessAt {
            let ago = Date().timeIntervalSince(last)
            recency = max(0, 1.0 - (ago / 3600.0))
        }

        let base = srScore + latScore + blockPenalty + challengePenalty + blankPenalty + loginBonus

        let streakPenalty = consecutiveFailures >= 3 ? max(0.3, 1.0 - Double(consecutiveFailures) * 0.15) : 1.0

        let scored = base * streakPenalty

        if let aiWeight = aiRecommendedWeight {
            return scored * 0.55 + aiWeight * 0.45
        }
        return scored
    }
}

nonisolated struct URLOptimizerStore: Codable, Sendable {
    var profiles: [String: URLPerformanceProfile] = [:]
    var recentOutcomes: [URLOutcomeSample] = []
    var hostRankings: [String: [String]] = [:]
    var lastGlobalAIAnalysis: Date = .distantPast
}

@MainActor
class AILoginURLOptimizerService {
    static let shared = AILoginURLOptimizerService()

    private let logger = DebugLogger.shared
    private let persistenceKey = "AILoginURLOptimizerData_v1"
    private let maxOutcomesPerURL = 200
    private let maxTotalOutcomes = 2000
    private let aiAnalysisThreshold = 30
    private let aiAnalysisCooldownSeconds: TimeInterval = 300
    private var store: URLOptimizerStore

    private init() {
        if let saved = UserDefaults.standard.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode(URLOptimizerStore.self, from: saved) {
            self.store = decoded
        } else {
            self.store = URLOptimizerStore()
        }
    }

    func recordOutcome(
        urlString: String,
        outcome: String,
        latencyMs: Int,
        blocked: Bool,
        challengeDetected: Bool,
        blankPage: Bool,
        loginSuccess: Bool
    ) {
        let host = extractHost(from: urlString)
        let sample = URLOutcomeSample(
            urlString: urlString,
            host: host,
            outcome: outcome,
            latencyMs: latencyMs,
            blocked: blocked,
            challengeDetected: challengeDetected,
            blankPage: blankPage,
            timestamp: Date()
        )

        store.recentOutcomes.append(sample)
        if store.recentOutcomes.count > maxTotalOutcomes {
            store.recentOutcomes.removeFirst(store.recentOutcomes.count - maxTotalOutcomes)
        }

        var profile = store.profiles[urlString] ?? URLPerformanceProfile(urlString: urlString, host: host)
        profile.sampleCount += 1
        profile.totalLatencyMs += latencyMs

        let isSuccess = outcome == "success" || outcome == "noAcc" || outcome == "permDisabled" || outcome == "tempDisabled"

        if isSuccess {
            profile.successCount += 1
            profile.lastSuccessAt = Date()
            profile.consecutiveFailures = 0
        } else {
            profile.failureCount += 1
            profile.lastFailureAt = Date()
            profile.consecutiveFailures += 1
        }

        if blocked {
            profile.blockCount += 1
            profile.lastBlockAt = Date()
        }
        if challengeDetected { profile.challengeCount += 1 }
        if blankPage { profile.blankPageCount += 1 }
        if loginSuccess { profile.loginSuccessCount += 1 }

        if profile.consecutiveFailures >= 5 {
            let cooldownSeconds = min(300.0, Double(profile.consecutiveFailures) * 30.0)
            profile.aiCooldownUntil = Date().addingTimeInterval(cooldownSeconds)
            logger.log("AIURLOptimizer: \(urlString) entering cooldown \(Int(cooldownSeconds))s after \(profile.consecutiveFailures) consecutive failures", category: .network, level: .warning)
        }

        store.profiles[urlString] = profile
        save()

        let totalSamples = store.profiles.values.reduce(0) { $0 + $1.sampleCount }
        if totalSamples >= aiAnalysisThreshold &&
           totalSamples % aiAnalysisThreshold == 0 &&
           Date().timeIntervalSince(store.lastGlobalAIAnalysis) > aiAnalysisCooldownSeconds {
            Task {
                await requestAIOptimization()
            }
        }
    }

    func selectBestURL(from urls: [String]) -> String? {
        guard !urls.isEmpty else { return nil }
        if urls.count == 1 { return urls.first }

        let scored = urls.map { url -> (String, Double) in
            let profile = store.profiles[url]
            let score = profile?.compositeScore ?? 0.5
            return (url, score)
        }

        let totalWeight = scored.reduce(0.0) { $0 + max($1.1, 0.02) }
        guard totalWeight > 0 else { return urls.randomElement() }

        var random = Double.random(in: 0..<totalWeight)
        for (url, weight) in scored {
            random -= max(weight, 0.02)
            if random <= 0 { return url }
        }
        return urls.last
    }

    func rankedURLs(from urls: [String]) -> [(url: String, score: Double, attempts: Int, successRate: Int, avgLatency: Int, blocked: Int)] {
        urls.map { url in
            let profile = store.profiles[url]
            return (
                url: url,
                score: profile?.compositeScore ?? 0.5,
                attempts: profile?.totalAttempts ?? 0,
                successRate: Int((profile?.successRate ?? 0.5) * 100),
                avgLatency: profile?.avgLatencyMs ?? 0,
                blocked: profile?.blockCount ?? 0
            )
        }.sorted { $0.score > $1.score }
    }

    func profileFor(urlString: String) -> URLPerformanceProfile? {
        store.profiles[urlString]
    }

    func allProfiles() -> [URLPerformanceProfile] {
        Array(store.profiles.values).sorted { $0.compositeScore > $1.compositeScore }
    }

    func hostSummary() -> [(host: String, urlCount: Int, avgScore: Double, bestURL: String?)] {
        var hostMap: [String: [URLPerformanceProfile]] = [:]
        for profile in store.profiles.values {
            hostMap[profile.host, default: []].append(profile)
        }
        return hostMap.map { host, profiles in
            let avgScore = profiles.reduce(0.0) { $0 + $1.compositeScore } / Double(profiles.count)
            let best = profiles.max(by: { $0.compositeScore < $1.compositeScore })
            return (host, profiles.count, avgScore, best?.urlString)
        }.sorted { $0.avgScore > $1.avgScore }
    }

    func clearCooldown(urlString: String) {
        guard var profile = store.profiles[urlString] else { return }
        profile.aiCooldownUntil = nil
        profile.consecutiveFailures = 0
        store.profiles[urlString] = profile
        save()
        logger.log("AIURLOptimizer: cooldown cleared for \(urlString)", category: .network, level: .info)
    }

    func resetURL(_ urlString: String) {
        store.profiles.removeValue(forKey: urlString)
        store.recentOutcomes.removeAll { $0.urlString == urlString }
        save()
        logger.log("AIURLOptimizer: reset all data for \(urlString)", category: .network, level: .warning)
    }

    func resetAll() {
        store = URLOptimizerStore()
        save()
        logger.log("AIURLOptimizer: all URL data RESET", category: .network, level: .warning)
    }

    private func requestAIOptimization() async {
        let profiles = store.profiles.values.filter { $0.totalAttempts >= 3 }
        guard profiles.count >= 2 else { return }

        var summaryData: [[String: Any]] = []
        for p in profiles {
            summaryData.append([
                "url": p.urlString,
                "host": p.host,
                "attempts": p.totalAttempts,
                "successRate": Int(p.successRate * 100),
                "blockRate": Int(p.blockRate * 100),
                "challengeRate": Int(p.challengeRate * 100),
                "blankPageRate": Int(p.blankPageRate * 100),
                "avgLatencyMs": p.avgLatencyMs,
                "loginSuccesses": p.loginSuccessCount,
                "consecutiveFailures": p.consecutiveFailures,
                "currentScore": String(format: "%.3f", p.compositeScore),
            ])
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: summaryData),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

        let systemPrompt = """
        You optimize login URL rotation for web automation targeting casino login pages. \
        Analyze the URL performance data and return ONLY a JSON array of objects with recommended weights and cooldowns. \
        Format: [{"url":"...","weight":0.0-1.0,"cooldownSeconds":0}]. \
        Higher weight = more likely to be selected. Set cooldownSeconds > 0 for URLs with high block/challenge rates. \
        Prioritize URLs with high success rates, low latency, low block rates, and actual login successes. \
        Deprioritize URLs with high blank page rates or consecutive failures. \
        URLs from the same host/domain family should be diversified — don't stack all weight on one. \
        Return ONLY the JSON array, no explanation.
        """

        let userPrompt = "URL performance data:\n\(jsonStr)"

        logger.log("AIURLOptimizer: requesting AI optimization for \(profiles.count) URLs", category: .network, level: .info)

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: userPrompt) else {
            logger.log("AIURLOptimizer: AI optimization failed — no response", category: .network, level: .warning)
            return
        }

        applyAIOptimization(response: response)
        store.lastGlobalAIAnalysis = Date()
        save()
    }

    private func applyAIOptimization(response: String) {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            logger.log("AIURLOptimizer: failed to parse AI response", category: .network, level: .warning)
            return
        }

        var applied = 0
        for entry in json {
            guard let url = entry["url"] as? String,
                  let weight = entry["weight"] as? Double else { continue }

            guard var profile = store.profiles[url] else { continue }

            let clampedWeight = max(0.01, min(1.0, weight))
            let previousWeight = profile.aiRecommendedWeight
            profile.aiRecommendedWeight = clampedWeight
            profile.lastAIOptimization = Date()

            if let cooldown = entry["cooldownSeconds"] as? Int, cooldown > 0 {
                profile.aiCooldownUntil = Date().addingTimeInterval(Double(cooldown))
                logger.log("AIURLOptimizer: AI cooldown \(cooldown)s for \(url)", category: .network, level: .warning)
            }

            store.profiles[url] = profile
            applied += 1

            let prevStr = previousWeight.map { String(format: "%.3f", $0) } ?? "none"
            logger.log("AIURLOptimizer: \(url) weight \(prevStr) → \(String(format: "%.3f", clampedWeight))", category: .network, level: .info)
        }

        logger.log("AIURLOptimizer: AI optimization applied to \(applied)/\(json.count) URLs", category: .network, level: .success)
    }

    private func extractHost(from url: String) -> String {
        URL(string: url)?.host ?? url
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: persistenceKey)
        }
    }
}
