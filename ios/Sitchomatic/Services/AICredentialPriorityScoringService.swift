import Foundation

nonisolated struct CredentialOutcomeRecord: Codable, Sendable {
    let username: String
    let emailDomain: String
    let outcome: String
    let host: String
    let attemptNumber: Int
    let latencyMs: Int
    let wasChallenge: Bool
    let timestamp: Date
}

nonisolated struct CredentialPriorityProfile: Codable, Sendable {
    var username: String
    var emailDomain: String
    var totalAttempts: Int = 0
    var successCount: Int = 0
    var noAccCount: Int = 0
    var permDisabledCount: Int = 0
    var tempDisabledCount: Int = 0
    var unsureCount: Int = 0
    var connectionFailureCount: Int = 0
    var timeoutCount: Int = 0
    var challengeCount: Int = 0
    var totalLatencyMs: Int = 0
    var consecutiveFailures: Int = 0
    var lastOutcome: String?
    var lastTestedAt: Date?
    var aiPriorityScore: Double?

    var successRate: Double {
        guard totalAttempts > 0 else { return 0 }
        return Double(successCount) / Double(totalAttempts)
    }

    var avgLatencyMs: Int {
        guard totalAttempts > 0 else { return 0 }
        return totalLatencyMs / totalAttempts
    }

    var accountLikelihood: Double {
        if successCount > 0 { return 1.0 }
        if tempDisabledCount > 0 { return 0.85 }
        if permDisabledCount > 0 { return 0.7 }

        guard totalAttempts > 0 else { return 0.5 }

        if noAccCount >= 3 { return 0.05 }
        if noAccCount >= 2 { return 0.15 }

        if unsureCount > 0 && noAccCount == 0 { return 0.6 }

        let failRatio = Double(connectionFailureCount + timeoutCount) / Double(totalAttempts)
        if failRatio > 0.7 { return 0.4 }

        return 0.5
    }

    var priorityScore: Double {
        if let ai = aiPriorityScore { return ai }

        if successCount > 0 { return 0.05 }
        if permDisabledCount >= 2 { return 0.02 }
        if noAccCount >= 3 { return 0.03 }

        var score = accountLikelihood

        if tempDisabledCount > 0 { score += 0.15 }

        if totalAttempts == 0 { score = 0.5 }

        let staleness: Double
        if let last = lastTestedAt {
            let hoursSince = Date().timeIntervalSince(last) / 3600
            staleness = min(0.1, hoursSince * 0.01)
        } else {
            staleness = 0.1
        }
        score += staleness

        if consecutiveFailures >= 3 {
            score *= max(0.3, 1.0 - Double(consecutiveFailures) * 0.1)
        }

        return min(1.0, max(0.01, score))
    }
}

nonisolated struct EmailDomainStats: Codable, Sendable {
    var domain: String
    var totalCredentials: Int = 0
    var successCount: Int = 0
    var noAccCount: Int = 0
    var tempDisabledCount: Int = 0
    var permDisabledCount: Int = 0

    var successRate: Double {
        guard totalCredentials > 0 else { return 0 }
        return Double(successCount) / Double(totalCredentials)
    }

    var accountFoundRate: Double {
        guard totalCredentials > 0 else { return 0 }
        return Double(successCount + tempDisabledCount + permDisabledCount) / Double(totalCredentials)
    }
}

nonisolated struct CredentialPriorityStore: Codable, Sendable {
    var profiles: [String: CredentialPriorityProfile] = [:]
    var domainStats: [String: EmailDomainStats] = [:]
    var recentOutcomes: [CredentialOutcomeRecord] = []
    var lastGlobalAIAnalysis: Date = .distantPast
}

@MainActor
class AICredentialPriorityScoringService {
    static let shared = AICredentialPriorityScoringService()

    private let logger = DebugLogger.shared
    private let persistenceKey = "AICredentialPriorityScoringData_v1"
    private let maxOutcomes = 2000
    private let aiAnalysisThreshold = 50
    private let aiAnalysisCooldownSeconds: TimeInterval = 300
    private var store: CredentialPriorityStore

    private init() {
        if let saved = UserDefaults.standard.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode(CredentialPriorityStore.self, from: saved) {
            self.store = decoded
        } else {
            self.store = CredentialPriorityStore()
        }
    }

    func recordOutcome(
        username: String,
        outcome: String,
        host: String,
        latencyMs: Int,
        wasChallenge: Bool
    ) {
        let domain = extractDomain(from: username)
        let attemptNum = (store.profiles[username]?.totalAttempts ?? 0) + 1

        let record = CredentialOutcomeRecord(
            username: username,
            emailDomain: domain,
            outcome: outcome,
            host: host,
            attemptNumber: attemptNum,
            latencyMs: latencyMs,
            wasChallenge: wasChallenge,
            timestamp: Date()
        )

        store.recentOutcomes.append(record)
        if store.recentOutcomes.count > maxOutcomes {
            store.recentOutcomes.removeFirst(store.recentOutcomes.count - maxOutcomes)
        }

        var profile = store.profiles[username] ?? CredentialPriorityProfile(username: username, emailDomain: domain)
        profile.totalAttempts += 1
        profile.totalLatencyMs += latencyMs
        profile.lastOutcome = outcome
        profile.lastTestedAt = Date()

        switch outcome {
        case "success":
            profile.successCount += 1
            profile.consecutiveFailures = 0
        case "noAcc":
            profile.noAccCount += 1
            profile.consecutiveFailures = 0
        case "permDisabled":
            profile.permDisabledCount += 1
            profile.consecutiveFailures = 0
        case "tempDisabled":
            profile.tempDisabledCount += 1
            profile.consecutiveFailures = 0
        case "unsure":
            profile.unsureCount += 1
            profile.consecutiveFailures += 1
        case "connectionFailure":
            profile.connectionFailureCount += 1
            profile.consecutiveFailures += 1
        case "timeout":
            profile.timeoutCount += 1
            profile.consecutiveFailures += 1
        default:
            profile.consecutiveFailures += 1
        }

        if wasChallenge { profile.challengeCount += 1 }

        store.profiles[username] = profile

        var domainStat = store.domainStats[domain] ?? EmailDomainStats(domain: domain)
        if attemptNum == 1 { domainStat.totalCredentials += 1 }
        switch outcome {
        case "success": domainStat.successCount += 1
        case "noAcc": domainStat.noAccCount += 1
        case "tempDisabled": domainStat.tempDisabledCount += 1
        case "permDisabled": domainStat.permDisabledCount += 1
        default: break
        }
        store.domainStats[domain] = domainStat

        save()

        let totalRecords = store.recentOutcomes.count
        if totalRecords >= aiAnalysisThreshold &&
           totalRecords % aiAnalysisThreshold == 0 &&
           Date().timeIntervalSince(store.lastGlobalAIAnalysis) > aiAnalysisCooldownSeconds {
            Task {
                await requestAIOptimization()
            }
        }
    }

    func sortedCredentials(_ usernames: [String]) -> [String] {
        usernames.sorted { a, b in
            let scoreA = store.profiles[a]?.priorityScore ?? 0.5
            let scoreB = store.profiles[b]?.priorityScore ?? 0.5
            return scoreA > scoreB
        }
    }

    func priorityScore(for username: String) -> Double {
        store.profiles[username]?.priorityScore ?? 0.5
    }

    func profileFor(username: String) -> CredentialPriorityProfile? {
        store.profiles[username]
    }

    func domainStatsFor(_ domain: String) -> EmailDomainStats? {
        store.domainStats[domain]
    }

    func topDomains(limit: Int = 10) -> [(domain: String, accountRate: Int, total: Int)] {
        store.domainStats.values
            .filter { $0.totalCredentials >= 3 }
            .sorted { $0.accountFoundRate > $1.accountFoundRate }
            .prefix(limit)
            .map { ($0.domain, Int($0.accountFoundRate * 100), $0.totalCredentials) }
    }

    func credentialSummary() -> (total: Int, tested: Int, untested: Int, highPriority: Int, lowPriority: Int) {
        let profiles = store.profiles.values
        let tested = profiles.filter { $0.totalAttempts > 0 }.count
        let untested = profiles.filter { $0.totalAttempts == 0 }.count
        let highPriority = profiles.filter { $0.priorityScore > 0.6 }.count
        let lowPriority = profiles.filter { $0.priorityScore < 0.1 }.count
        return (profiles.count, tested, untested, highPriority, lowPriority)
    }

    func resetCredential(_ username: String) {
        store.profiles.removeValue(forKey: username)
        store.recentOutcomes.removeAll { $0.username == username }
        save()
    }

    func resetAll() {
        store = CredentialPriorityStore()
        save()
        logger.log("AICredentialPriority: all data RESET", category: .automation, level: .warning)
    }

    private func requestAIOptimization() async {
        let domainData = store.domainStats.values
            .filter { $0.totalCredentials >= 3 }
            .sorted { $0.totalCredentials > $1.totalCredentials }
            .prefix(20)

        guard !domainData.isEmpty else { return }

        var summaryData: [[String: Any]] = []
        for d in domainData {
            summaryData.append([
                "domain": d.domain,
                "totalCredentials": d.totalCredentials,
                "successRate": Int(d.successRate * 100),
                "accountFoundRate": Int(d.accountFoundRate * 100),
                "noAccCount": d.noAccCount,
                "tempDisabledCount": d.tempDisabledCount,
                "permDisabledCount": d.permDisabledCount,
            ])
        }

        let outcomeSummary: [String: Int] = [
            "totalProfiles": store.profiles.count,
            "withSuccess": store.profiles.values.filter { $0.successCount > 0 }.count,
            "withTempDisabled": store.profiles.values.filter { $0.tempDisabledCount > 0 }.count,
            "withPermDisabled": store.profiles.values.filter { $0.permDisabledCount > 0 }.count,
            "withNoAcc": store.profiles.values.filter { $0.noAccCount > 0 }.count,
            "untestedCount": store.profiles.values.filter { $0.totalAttempts == 0 }.count,
        ]

        let combined: [String: Any] = [
            "domains": summaryData,
            "outcomes": outcomeSummary,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: combined),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

        let systemPrompt = """
        You analyze credential testing data for casino account discovery. \
        Based on email domain patterns and outcome distributions, return a JSON array ranking email domains by priority. \
        Format: [{"domain":"...","priorityMultiplier":0.1-2.0,"reasoning":"..."}]. \
        Domains with higher account-found rates (success + temp disabled + perm disabled) should get higher multipliers. \
        Domains with mostly "no account" results should get lower multipliers. \
        Consider that some domains are more commonly used for casino accounts than others. \
        Return ONLY the JSON array.
        """

        let userPrompt = "Credential testing data:\n\(jsonStr)"

        logger.log("AICredentialPriority: requesting AI optimization for \(domainData.count) domains", category: .automation, level: .info)

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: userPrompt) else {
            logger.log("AICredentialPriority: AI optimization failed — no response", category: .automation, level: .warning)
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
            logger.log("AICredentialPriority: failed to parse AI response", category: .automation, level: .warning)
            return
        }

        var applied = 0
        for entry in json {
            guard let domain = entry["domain"] as? String,
                  let multiplier = entry["priorityMultiplier"] as? Double else { continue }

            let clampedMultiplier = max(0.1, min(2.0, multiplier))

            for (username, var profile) in store.profiles where profile.emailDomain == domain {
                let baseScore = profile.priorityScore
                profile.aiPriorityScore = min(1.0, max(0.01, baseScore * clampedMultiplier))
                store.profiles[username] = profile
            }

            applied += 1
            logger.log("AICredentialPriority: domain \(domain) multiplier → \(String(format: "%.2f", clampedMultiplier))", category: .automation, level: .info)
        }

        logger.log("AICredentialPriority: AI optimization applied to \(applied) domains", category: .automation, level: .success)
    }

    private func extractDomain(from email: String) -> String {
        guard let atIndex = email.firstIndex(of: "@") else { return "unknown" }
        return String(email[email.index(after: atIndex)...]).lowercased()
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: persistenceKey)
        }
    }
}
