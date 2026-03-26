import Foundation

nonisolated struct ChallengeEncounter: Codable, Sendable {
    let host: String
    let challengeType: String
    let signals: [String]
    let bypassUsed: String
    let success: Bool
    let latencyMs: Int
    let timestamp: Date
}

nonisolated struct HostChallengeProfile: Codable, Sendable {
    var encounterCount: Int = 0
    var bypassSuccessRates: [String: BypassStats] = [:]
    var commonSignals: [String: Int] = [:]
    var challengeTypeFrequency: [String: Int] = [:]
    var averageLatencyMs: Double = 0
    var lastEncounter: Date = .distantPast
    var aiRecommendedStrategy: String?
    var aiRecommendedAt: Date?
    var consecutiveFailures: Int = 0
    var cooldownUntil: Date?
}

nonisolated struct BypassStats: Codable, Sendable {
    var attempts: Int = 0
    var successes: Int = 0
    var totalLatencyMs: Int = 0

    var successRate: Double {
        attempts > 0 ? Double(successes) / Double(attempts) : 0
    }

    var averageLatencyMs: Double {
        attempts > 0 ? Double(totalLatencyMs) / Double(attempts) : 0
    }
}

nonisolated struct AIBypassRecommendation: Codable, Sendable {
    let primaryStrategy: String
    let fallbackStrategies: [String]
    let waitTimeMs: Int
    let shouldRotateProxy: Bool
    let shouldRotateFingerprint: Bool
    let shouldRotateURL: Bool
    let confidence: Double
    let reasoning: String
}

nonisolated struct AIChallengeStore: Codable, Sendable {
    var hostProfiles: [String: HostChallengeProfile] = [:]
    var recentEncounters: [ChallengeEncounter] = []
    var aiCallCount: Int = 0
    var totalBypasses: Int = 0
    var totalBypassSuccesses: Int = 0
}

@MainActor
class AIChallengePageSolverService {
    static let shared = AIChallengePageSolverService()

    private let logger = DebugLogger.shared
    private let persistenceKey = "AIChallengePageSolverData"
    private let maxEncounterHistory = 300
    private let aiRefreshIntervalMinutes: Double = 30
    private var store: AIChallengeStore

    private init() {
        if let saved = UserDefaults.standard.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode(AIChallengeStore.self, from: saved) {
            self.store = decoded
        } else {
            self.store = AIChallengeStore()
        }
    }

    func recommendBypass(
        host: String,
        challengeType: ChallengePageClassifier.ChallengeType,
        signals: [String],
        confidence: Double,
        pageContent: String
    ) async -> AIBypassRecommendation {
        let profile = store.hostProfiles[host]

        if let profile, profile.encounterCount >= 5 {
            let bestBypass = profile.bypassSuccessRates
                .filter { $0.value.attempts >= 2 }
                .max(by: { $0.value.successRate < $1.value.successRate })

            if let bestBypass, bestBypass.value.successRate >= 0.6 {
                let needsAIRefresh = shouldRefreshAIStrategy(profile: profile)

                if !needsAIRefresh {
                    logger.log("AIChallengeSolver: using learned bypass '\(bestBypass.key)' for \(host) (rate: \(String(format: "%.0f%%", bestBypass.value.successRate * 100)))", category: .evaluation, level: .info)
                    return buildLearnedRecommendation(
                        host: host,
                        challengeType: challengeType,
                        bestBypass: bestBypass.key,
                        profile: profile
                    )
                }
            }
        }

        if let aiRec = await requestAIBypassStrategy(
            host: host,
            challengeType: challengeType,
            signals: signals,
            confidence: confidence,
            pageContent: pageContent,
            profile: profile
        ) {
            return aiRec
        }

        return buildStaticRecommendation(challengeType: challengeType, host: host)
    }

    func recordEncounter(
        host: String,
        challengeType: ChallengePageClassifier.ChallengeType,
        signals: [String],
        bypassUsed: String,
        success: Bool,
        latencyMs: Int
    ) {
        let encounter = ChallengeEncounter(
            host: host,
            challengeType: challengeType.rawValue,
            signals: signals,
            bypassUsed: bypassUsed,
            success: success,
            latencyMs: latencyMs,
            timestamp: Date()
        )

        store.recentEncounters.append(encounter)
        if store.recentEncounters.count > maxEncounterHistory {
            store.recentEncounters.removeFirst(store.recentEncounters.count - maxEncounterHistory)
        }

        store.totalBypasses += 1
        if success { store.totalBypassSuccesses += 1 }

        var profile = store.hostProfiles[host] ?? HostChallengeProfile()
        profile.encounterCount += 1
        profile.lastEncounter = Date()

        var stats = profile.bypassSuccessRates[bypassUsed] ?? BypassStats()
        stats.attempts += 1
        if success { stats.successes += 1 }
        stats.totalLatencyMs += latencyMs
        profile.bypassSuccessRates[bypassUsed] = stats

        for signal in signals.prefix(10) {
            profile.commonSignals[signal, default: 0] += 1
        }
        profile.challengeTypeFrequency[challengeType.rawValue, default: 0] += 1

        let totalLatency = profile.averageLatencyMs * Double(profile.encounterCount - 1) + Double(latencyMs)
        profile.averageLatencyMs = totalLatency / Double(profile.encounterCount)

        if success {
            profile.consecutiveFailures = 0
            profile.cooldownUntil = nil
        } else {
            profile.consecutiveFailures += 1
            if profile.consecutiveFailures >= 5 {
                let cooldownSeconds = min(Double(profile.consecutiveFailures) * 30, 300)
                profile.cooldownUntil = Date().addingTimeInterval(cooldownSeconds)
                logger.log("AIChallengeSolver: \(host) entered cooldown (\(Int(cooldownSeconds))s) after \(profile.consecutiveFailures) consecutive failures", category: .evaluation, level: .warning)
            }
        }

        pruneProfile(&profile)
        store.hostProfiles[host] = profile
        save()

        logger.log("AIChallengeSolver: recorded \(success ? "SUCCESS" : "FAIL") for \(host) — bypass: \(bypassUsed), type: \(challengeType.rawValue), latency: \(latencyMs)ms", category: .evaluation, level: success ? .debug : .warning)
    }

    func isHostInCooldown(_ host: String) -> Bool {
        guard let profile = store.hostProfiles[host],
              let cooldown = profile.cooldownUntil else { return false }
        return Date() < cooldown
    }

    func cooldownRemaining(_ host: String) -> TimeInterval {
        guard let profile = store.hostProfiles[host],
              let cooldown = profile.cooldownUntil else { return 0 }
        return max(0, cooldown.timeIntervalSinceNow)
    }

    func profileForHost(_ host: String) -> HostChallengeProfile? {
        store.hostProfiles[host]
    }

    func globalStats() -> (encounters: Int, bypasses: Int, successRate: Double, hostsTracked: Int, aiCalls: Int) {
        let rate = store.totalBypasses > 0 ? Double(store.totalBypassSuccesses) / Double(store.totalBypasses) : 0
        return (store.recentEncounters.count, store.totalBypasses, rate, store.hostProfiles.count, store.aiCallCount)
    }

    func resetHost(_ host: String) {
        store.hostProfiles.removeValue(forKey: host)
        save()
    }

    func resetAll() {
        store = AIChallengeStore()
        save()
    }

    // MARK: - AI Strategy Request

    private func requestAIBypassStrategy(
        host: String,
        challengeType: ChallengePageClassifier.ChallengeType,
        signals: [String],
        confidence: Double,
        pageContent: String,
        profile: HostChallengeProfile?
    ) async -> AIBypassRecommendation? {
        let snippet = String(pageContent.prefix(2000))

        var context = "Host: \(host)\n"
        context += "Challenge type: \(challengeType.rawValue) (confidence: \(String(format: "%.0f%%", confidence * 100)))\n"
        context += "Signals: \(signals.prefix(8).joined(separator: ", "))\n"

        if let profile {
            context += "Total encounters on this host: \(profile.encounterCount)\n"
            context += "Consecutive failures: \(profile.consecutiveFailures)\n"

            let bypassSummary = profile.bypassSuccessRates
                .sorted { $0.value.successRate > $1.value.successRate }
                .prefix(5)
                .map { "\($0.key): \(String(format: "%.0f%%", $0.value.successRate * 100)) (\($0.value.attempts) attempts)" }
                .joined(separator: ", ")
            if !bypassSummary.isEmpty {
                context += "Bypass history: \(bypassSummary)\n"
            }

            let topTypes = profile.challengeTypeFrequency
                .sorted { $0.value > $1.value }
                .prefix(3)
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ", ")
            if !topTypes.isEmpty {
                context += "Common challenge types: \(topTypes)\n"
            }
        }

        let systemPrompt = """
        You are an anti-bot bypass strategist for web automation. Analyze challenge page data and recommend the best bypass strategy. \
        Available strategies: "waitAndRetry" (wait then reload), "rotateProxy" (change IP/proxy), "rotateURL" (try different login URL), \
        "rotateFingerprint" (change browser fingerprint), "fullSessionReset" (destroy and rebuild session), "switchNetwork" (change network entirely), \
        "changeDNS" (rotate DNS provider), "abort" (skip this attempt). \
        Respond with ONLY a JSON object: \
        {"primaryStrategy":"...","fallbackStrategies":["..."],"waitTimeMs":0,"shouldRotateProxy":false,"shouldRotateFingerprint":false,"shouldRotateURL":false,"confidence":0.0-1.0,"reasoning":"brief explanation"}
        """

        let userPrompt = "\(context)\nPage content snippet:\n\(snippet)"

        store.aiCallCount += 1
        save()

        logger.log("AIChallengeSolver: requesting AI strategy for \(host) — type: \(challengeType.rawValue)", category: .evaluation, level: .info)

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: userPrompt) else {
            logger.log("AIChallengeSolver: AI call failed for \(host)", category: .evaluation, level: .warning)
            return nil
        }

        guard let parsed = parseAIResponse(response) else {
            logger.log("AIChallengeSolver: failed to parse AI response for \(host)", category: .evaluation, level: .warning)
            return nil
        }

        var updatedProfile = store.hostProfiles[host] ?? HostChallengeProfile()
        updatedProfile.aiRecommendedStrategy = parsed.primaryStrategy
        updatedProfile.aiRecommendedAt = Date()
        store.hostProfiles[host] = updatedProfile
        save()

        logger.log("AIChallengeSolver: AI recommends '\(parsed.primaryStrategy)' for \(host) (confidence: \(String(format: "%.0f%%", parsed.confidence * 100))) — \(parsed.reasoning)", category: .evaluation, level: .info)

        return parsed
    }

    private func parseAIResponse(_ response: String) -> AIBypassRecommendation? {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let primary = json["primaryStrategy"] as? String else {
            return nil
        }

        let fallbacks = json["fallbackStrategies"] as? [String] ?? []
        let waitTime = json["waitTimeMs"] as? Int ?? 3000
        let rotateProxy = json["shouldRotateProxy"] as? Bool ?? false
        let rotateFingerprint = json["shouldRotateFingerprint"] as? Bool ?? false
        let rotateURL = json["shouldRotateURL"] as? Bool ?? false
        let confidence = json["confidence"] as? Double ?? 0.5
        let reasoning = json["reasoning"] as? String ?? "AI recommendation"

        return AIBypassRecommendation(
            primaryStrategy: primary,
            fallbackStrategies: fallbacks,
            waitTimeMs: waitTime,
            shouldRotateProxy: rotateProxy,
            shouldRotateFingerprint: rotateFingerprint,
            shouldRotateURL: rotateURL,
            confidence: confidence,
            reasoning: reasoning
        )
    }

    // MARK: - Learned Recommendations

    private func buildLearnedRecommendation(
        host: String,
        challengeType: ChallengePageClassifier.ChallengeType,
        bestBypass: String,
        profile: HostChallengeProfile
    ) -> AIBypassRecommendation {
        let fallbacks = profile.bypassSuccessRates
            .filter { $0.key != bestBypass && $0.value.attempts >= 2 && $0.value.successRate >= 0.3 }
            .sorted { $0.value.successRate > $1.value.successRate }
            .prefix(2)
            .map { $0.key }

        let avgLatency = profile.bypassSuccessRates[bestBypass]?.averageLatencyMs ?? 3000
        let waitTime = max(1000, Int(avgLatency * 0.5))

        let shouldRotateProxy = challengeType == .temporaryBlock || challengeType == .rateLimit || profile.consecutiveFailures >= 3
        let shouldRotateFingerprint = challengeType == .cloudflareChallenge || profile.consecutiveFailures >= 2
        let shouldRotateURL = challengeType == .jsFailed || profile.consecutiveFailures >= 4

        let rate = profile.bypassSuccessRates[bestBypass]?.successRate ?? 0.5

        return AIBypassRecommendation(
            primaryStrategy: bestBypass,
            fallbackStrategies: Array(fallbacks),
            waitTimeMs: waitTime,
            shouldRotateProxy: shouldRotateProxy,
            shouldRotateFingerprint: shouldRotateFingerprint,
            shouldRotateURL: shouldRotateURL,
            confidence: rate,
            reasoning: "Learned from \(profile.encounterCount) encounters — best bypass: \(bestBypass) at \(String(format: "%.0f%%", rate * 100))"
        )
    }

    private func buildStaticRecommendation(
        challengeType: ChallengePageClassifier.ChallengeType,
        host: String
    ) -> AIBypassRecommendation {
        switch challengeType {
        case .rateLimit:
            return AIBypassRecommendation(
                primaryStrategy: "waitAndRetry",
                fallbackStrategies: ["rotateProxy", "switchNetwork"],
                waitTimeMs: 8000,
                shouldRotateProxy: true,
                shouldRotateFingerprint: false,
                shouldRotateURL: false,
                confidence: 0.5,
                reasoning: "Rate limit detected — wait and rotate IP"
            )
        case .captcha:
            return AIBypassRecommendation(
                primaryStrategy: "rotateProxy",
                fallbackStrategies: ["rotateFingerprint", "rotateURL"],
                waitTimeMs: 3000,
                shouldRotateProxy: true,
                shouldRotateFingerprint: true,
                shouldRotateURL: false,
                confidence: 0.4,
                reasoning: "CAPTCHA detected — rotate proxy and fingerprint"
            )
        case .temporaryBlock:
            return AIBypassRecommendation(
                primaryStrategy: "switchNetwork",
                fallbackStrategies: ["rotateProxy", "fullSessionReset"],
                waitTimeMs: 10000,
                shouldRotateProxy: true,
                shouldRotateFingerprint: true,
                shouldRotateURL: true,
                confidence: 0.4,
                reasoning: "IP block detected — full network rotation needed"
            )
        case .cloudflareChallenge:
            return AIBypassRecommendation(
                primaryStrategy: "rotateFingerprint",
                fallbackStrategies: ["rotateProxy", "fullSessionReset"],
                waitTimeMs: 5000,
                shouldRotateProxy: true,
                shouldRotateFingerprint: true,
                shouldRotateURL: false,
                confidence: 0.35,
                reasoning: "Cloudflare challenge — fingerprint rotation primary"
            )
        case .jsFailed:
            return AIBypassRecommendation(
                primaryStrategy: "rotateURL",
                fallbackStrategies: ["fullSessionReset", "changeDNS"],
                waitTimeMs: 3000,
                shouldRotateProxy: false,
                shouldRotateFingerprint: false,
                shouldRotateURL: true,
                confidence: 0.5,
                reasoning: "JS failure — try alternate URL"
            )
        case .maintenance:
            return AIBypassRecommendation(
                primaryStrategy: "waitAndRetry",
                fallbackStrategies: ["rotateURL"],
                waitTimeMs: 30000,
                shouldRotateProxy: false,
                shouldRotateFingerprint: false,
                shouldRotateURL: true,
                confidence: 0.3,
                reasoning: "Site maintenance — extended wait recommended"
            )
        case .accountDisabled:
            return AIBypassRecommendation(
                primaryStrategy: "abort",
                fallbackStrategies: [],
                waitTimeMs: 0,
                shouldRotateProxy: false,
                shouldRotateFingerprint: false,
                shouldRotateURL: false,
                confidence: 0.9,
                reasoning: "Account disabled — no bypass needed, classify and move on"
            )
        case .none, .unknown:
            return AIBypassRecommendation(
                primaryStrategy: "waitAndRetry",
                fallbackStrategies: ["rotateProxy"],
                waitTimeMs: 3000,
                shouldRotateProxy: false,
                shouldRotateFingerprint: false,
                shouldRotateURL: false,
                confidence: 0.3,
                reasoning: "Unknown challenge — cautious retry"
            )
        }
    }

    // MARK: - Helpers

    private func shouldRefreshAIStrategy(profile: HostChallengeProfile) -> Bool {
        guard let lastAI = profile.aiRecommendedAt else { return true }
        let minutesSinceAI = Date().timeIntervalSince(lastAI) / 60
        if minutesSinceAI > aiRefreshIntervalMinutes { return true }
        if profile.consecutiveFailures >= 5 { return true }
        return false
    }

    private func pruneProfile(_ profile: inout HostChallengeProfile) {
        let maxSignals = 40
        if profile.commonSignals.count > maxSignals {
            let sorted = profile.commonSignals.sorted { $0.value > $1.value }
            profile.commonSignals = Dictionary(uniqueKeysWithValues: Array(sorted.prefix(maxSignals)))
        }
        let maxBypasses = 20
        if profile.bypassSuccessRates.count > maxBypasses {
            let sorted = profile.bypassSuccessRates.sorted { $0.value.attempts > $1.value.attempts }
            profile.bypassSuccessRates = Dictionary(uniqueKeysWithValues: Array(sorted.prefix(maxBypasses)))
        }
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: persistenceKey)
        }
    }
}
