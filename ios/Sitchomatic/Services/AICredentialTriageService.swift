import Foundation

nonisolated struct TriagedCredentialQueue: Sendable {
    let orderedUsernames: [String]
    let domainSpreadMap: [String: [Int]]
    let similarityGroups: [[String]]
    let priorityTiers: [TriageTier]
    let totalCredentials: Int
    let estimatedHighValueCount: Int
    let triageReasoningLog: [String]
}

nonisolated enum TriageTier: String, Sendable {
    case highValue
    case untested
    case retest
    case lowPriority
    case exhausted
}

nonisolated struct CredentialTriageProfile: Codable, Sendable {
    var username: String
    var tier: String
    var domainGroup: String
    var similarityCluster: Int
    var spreadIndex: Int
    var priorityScore: Double
    var reasoning: String
}

nonisolated struct TriageStore: Codable, Sendable {
    var domainSuccessHistory: [String: DomainTriageStats] = [:]
    var similarityPatterns: [String: [String]] = [:]
    var midBatchReorderCount: Int = 0
    var totalTriages: Int = 0
    var lastAITriageAnalysis: Date = .distantPast

    struct DomainTriageStats: Codable, Sendable {
        var domain: String
        var testedCount: Int = 0
        var accountFoundCount: Int = 0
        var noAccCount: Int = 0
        var avgLatencyMs: Int = 5000
        var lastTestedAt: Date = .distantPast
        var consecutiveNoAcc: Int = 0

        var accountFoundRate: Double {
            guard testedCount > 0 else { return 0.5 }
            return Double(accountFoundCount) / Double(testedCount)
        }

        var isExhausted: Bool {
            consecutiveNoAcc >= 5 && testedCount >= 8
        }
    }
}

@MainActor
class AICredentialTriageService {
    static let shared = AICredentialTriageService()

    private let logger = DebugLogger.shared
    private let credentialPriority = AICredentialPriorityScoringService.shared
    private let persistKey = "AICredentialTriageService_v1"
    private(set) var store: TriageStore

    private init() {
        if let saved = UserDefaults.standard.data(forKey: persistKey),
           let decoded = try? JSONDecoder().decode(TriageStore.self, from: saved) {
            self.store = decoded
        } else {
            self.store = TriageStore()
        }
    }

    func triageAndOrder(credentials: [LoginCredential]) -> TriagedCredentialQueue {
        var log: [String] = []
        log.append("Triaging \(credentials.count) credentials")

        let tiered = assignTiers(credentials: credentials)
        log.append("Tiers: \(tiered.map { "\($0.key): \($0.value.count)" }.joined(separator: ", "))")

        let domainGroups = groupByDomain(credentials: credentials)
        log.append("Domain groups: \(domainGroups.count) unique domains")

        let similarityGroups = detectSimilarCredentials(credentials: credentials)
        if !similarityGroups.isEmpty {
            log.append("Similarity clusters: \(similarityGroups.count) groups of similar credentials")
        }

        let ordered = buildSpreadOrder(
            tiered: tiered,
            domainGroups: domainGroups,
            similarityGroups: similarityGroups,
            credentials: credentials
        )
        log.append("Final order: \(ordered.count) credentials with domain-spread interleaving")

        let spreadMap = buildDomainSpreadMap(ordered: ordered, credentials: credentials)
        let highValueCount = (tiered[.highValue]?.count ?? 0) + (tiered[.untested]?.count ?? 0)

        let tierList = ordered.map { username -> TriageTier in
            for (tier, usernames) in tiered {
                if usernames.contains(username) { return tier }
            }
            return .lowPriority
        }

        store.totalTriages += 1
        save()

        logger.log("CredentialTriage: \(ordered.count) creds ordered — \(highValueCount) high value, \(similarityGroups.count) similarity clusters, \(domainGroups.count) domains", category: .automation, level: .info)

        return TriagedCredentialQueue(
            orderedUsernames: ordered,
            domainSpreadMap: spreadMap,
            similarityGroups: similarityGroups,
            priorityTiers: tierList,
            totalCredentials: ordered.count,
            estimatedHighValueCount: highValueCount,
            triageReasoningLog: log
        )
    }

    func dynamicReorder(
        remaining: [LoginCredential],
        recentOutcomes: [(username: String, outcome: String, latencyMs: Int)]
    ) -> [LoginCredential] {
        guard remaining.count > 3 else { return remaining }

        var domainRecentSuccess: [String: Int] = [:]
        var domainRecentFail: [String: Int] = [:]

        for outcome in recentOutcomes.suffix(20) {
            let domain = extractDomain(from: outcome.username)
            if outcome.outcome == "success" || outcome.outcome == "tempDisabled" {
                domainRecentSuccess[domain, default: 0] += 1
            } else if outcome.outcome == "noAcc" {
                domainRecentFail[domain, default: 0] += 1
            }
        }

        let reordered = remaining.sorted { a, b in
            let domA = extractDomain(from: a.username)
            let domB = extractDomain(from: b.username)

            let successA = domainRecentSuccess[domA, default: 0]
            let successB = domainRecentSuccess[domB, default: 0]
            let failA = domainRecentFail[domA, default: 0]
            let failB = domainRecentFail[domB, default: 0]

            let scoreA = Double(successA) * 2.0 - Double(failA) * 0.5 + (credentialPriority.priorityScore(for: a.username))
            let scoreB = Double(successB) * 2.0 - Double(failB) * 0.5 + (credentialPriority.priorityScore(for: b.username))

            return scoreA > scoreB
        }

        let domainSpread = applyDomainSpreading(reordered)

        store.midBatchReorderCount += 1
        save()

        logger.log("CredentialTriage: mid-batch reorder applied to \(remaining.count) remaining credentials", category: .automation, level: .info)

        return domainSpread
    }

    func recordOutcome(username: String, outcome: String, latencyMs: Int) {
        let domain = extractDomain(from: username)
        var stats = store.domainSuccessHistory[domain] ?? TriageStore.DomainTriageStats(domain: domain)
        stats.testedCount += 1
        stats.avgLatencyMs = (stats.avgLatencyMs * (stats.testedCount - 1) + latencyMs) / stats.testedCount
        stats.lastTestedAt = Date()

        switch outcome {
        case "success", "tempDisabled", "permDisabled":
            stats.accountFoundCount += 1
            stats.consecutiveNoAcc = 0
        case "noAcc":
            stats.noAccCount += 1
            stats.consecutiveNoAcc += 1
        default:
            break
        }

        store.domainSuccessHistory[domain] = stats
        save()
    }

    func domainRankings() -> [(domain: String, accountRate: Int, tested: Int, exhausted: Bool)] {
        store.domainSuccessHistory.values
            .filter { $0.testedCount >= 2 }
            .sorted { $0.accountFoundRate > $1.accountFoundRate }
            .map { ($0.domain, Int($0.accountFoundRate * 100), $0.testedCount, $0.isExhausted) }
    }

    func triageSummary() -> (totalTriages: Int, midBatchReorders: Int, domainsTracked: Int, exhaustedDomains: Int) {
        let exhausted = store.domainSuccessHistory.values.filter { $0.isExhausted }.count
        return (store.totalTriages, store.midBatchReorderCount, store.domainSuccessHistory.count, exhausted)
    }

    func requestAITriageAnalysis(credentials: [LoginCredential]) async -> [String] {
        guard credentials.count >= 10 else { return [] }
        guard Date().timeIntervalSince(store.lastAITriageAnalysis) > 300 else { return [] }

        var domainCounts: [String: Int] = [:]
        for cred in credentials {
            let domain = extractDomain(from: cred.username)
            domainCounts[domain, default: 0] += 1
        }

        let domainData = domainCounts.sorted { $0.value > $1.value }.prefix(15).map { domain, count -> [String: Any] in
            let stats = store.domainSuccessHistory[domain]
            return [
                "domain": domain,
                "credentialCount": count,
                "accountFoundRate": stats.map { Int($0.accountFoundRate * 100) } ?? -1,
                "tested": stats?.testedCount ?? 0,
                "exhausted": stats?.isExhausted ?? false,
                "consecutiveNoAcc": stats?.consecutiveNoAcc ?? 0,
            ] as [String: Any]
        }

        let statusBreakdown: [String: Int] = [
            "untested": credentials.filter { $0.status == .untested }.count,
            "working": credentials.filter { $0.status == .working }.count,
            "noAcc": credentials.filter { $0.status == .noAcc }.count,
            "unsure": credentials.filter { $0.status == .unsure }.count,
            "tempDisabled": credentials.filter { $0.status == .tempDisabled }.count,
            "permDisabled": credentials.filter { $0.status == .permDisabled }.count,
        ]

        let combined: [String: Any] = [
            "totalCredentials": credentials.count,
            "domains": domainData,
            "statusBreakdown": statusBreakdown,
            "totalDomainsTracked": store.domainSuccessHistory.count,
            "exhaustedDomains": store.domainSuccessHistory.values.filter { $0.isExhausted }.count,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: combined),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return [] }

        let systemPrompt = """
        You analyze credential queue data for optimal batch ordering. \
        Based on domain performance, credential status distribution, and exhaustion patterns, \
        provide 3-5 specific credential ordering recommendations. \
        Return ONLY a JSON array of strings: ["recommendation1", "recommendation2", ...]. \
        Focus on: which domains to prioritize, which to skip, optimal domain spreading strategy, \
        and any patterns that suggest credential quality issues.
        """

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: "Credential triage data:\n\(jsonStr)") else {
            return []
        }

        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }

        store.lastAITriageAnalysis = Date()
        save()

        return arr
    }

    func resetAll() {
        store = TriageStore()
        save()
        logger.log("CredentialTriage: all data RESET", category: .automation, level: .warning)
    }

    private func assignTiers(credentials: [LoginCredential]) -> [TriageTier: [String]] {
        var tiers: [TriageTier: [String]] = [
            .highValue: [], .untested: [], .retest: [], .lowPriority: [], .exhausted: []
        ]

        for cred in credentials {
            let domain = extractDomain(from: cred.username)
            let domainStats = store.domainSuccessHistory[domain]

            if domainStats?.isExhausted == true && cred.status == .noAcc {
                tiers[.exhausted]?.append(cred.username)
            } else if cred.status == .working {
                tiers[.lowPriority]?.append(cred.username)
            } else if cred.status == .permDisabled && cred.testResults.count >= 2 {
                tiers[.lowPriority]?.append(cred.username)
            } else if cred.status == .noAcc && cred.testResults.count >= 3 {
                tiers[.exhausted]?.append(cred.username)
            } else if cred.status == .untested {
                let domainRate = domainStats?.accountFoundRate ?? 0.5
                if domainRate > 0.3 {
                    tiers[.highValue]?.append(cred.username)
                } else {
                    tiers[.untested]?.append(cred.username)
                }
            } else if cred.status == .tempDisabled || cred.status == .unsure {
                tiers[.highValue]?.append(cred.username)
            } else {
                tiers[.retest]?.append(cred.username)
            }
        }

        for tier in tiers.keys {
            tiers[tier] = tiers[tier]?.sorted { a, b in
                credentialPriority.priorityScore(for: a) > credentialPriority.priorityScore(for: b)
            }
        }

        return tiers
    }

    private func groupByDomain(credentials: [LoginCredential]) -> [String: [String]] {
        var groups: [String: [String]] = [:]
        for cred in credentials {
            let domain = extractDomain(from: cred.username)
            groups[domain, default: []].append(cred.username)
        }
        return groups
    }

    private func detectSimilarCredentials(credentials: [LoginCredential]) -> [[String]] {
        var clusters: [[String]] = []
        var processed: Set<String> = []

        let sorted = credentials.sorted { $0.username < $1.username }

        for i in 0..<sorted.count {
            guard !processed.contains(sorted[i].username) else { continue }
            var cluster: [String] = [sorted[i].username]
            let baseLocal = localPart(sorted[i].username)

            for j in (i+1)..<sorted.count {
                guard !processed.contains(sorted[j].username) else { continue }
                let otherLocal = localPart(sorted[j].username)

                if areSimilar(baseLocal, otherLocal) {
                    cluster.append(sorted[j].username)
                    processed.insert(sorted[j].username)
                }
            }

            if cluster.count >= 2 {
                clusters.append(cluster)
                processed.insert(sorted[i].username)
            }
        }

        return clusters
    }

    private func buildSpreadOrder(
        tiered: [TriageTier: [String]],
        domainGroups: [String: [String]],
        similarityGroups: [[String]],
        credentials: [LoginCredential]
    ) -> [String] {
        let tierOrder: [TriageTier] = [.highValue, .untested, .retest, .lowPriority, .exhausted]
        var allOrdered: [String] = []

        for tier in tierOrder {
            let tierCreds = tiered[tier] ?? []
            if tierCreds.isEmpty { continue }
            let spread = spreadByDomain(tierCreds)
            allOrdered.append(contentsOf: spread)
        }

        let similarUsernames = Set(similarityGroups.flatMap { $0 })
        var finalOrder: [String] = []
        var lastDomain = ""
        var similarCooldowns: [String: Int] = [:]

        for username in allOrdered {
            let domain = extractDomain(from: username)

            if domain == lastDomain && finalOrder.count > 1 {
                let insertIdx = min(finalOrder.count, finalOrder.count - 1 + Int.random(in: 1...3))
                finalOrder.insert(username, at: min(insertIdx, finalOrder.count))
            } else if similarUsernames.contains(username) {
                let clusterKey = similarityGroups.first { $0.contains(username) }?.first ?? username
                let cooldown = similarCooldowns[clusterKey, default: 0]
                if cooldown > 0 {
                    let skipAhead = min(finalOrder.count, finalOrder.count - 1 + cooldown)
                    finalOrder.insert(username, at: min(skipAhead, finalOrder.count))
                } else {
                    finalOrder.append(username)
                }
                similarCooldowns[clusterKey] = Int.random(in: 2...5)
            } else {
                finalOrder.append(username)
            }

            lastDomain = domain

            for key in Array(similarCooldowns.keys) {
                if let value = similarCooldowns[key], value > 0 {
                    similarCooldowns[key] = value - 1
                }
            }
        }

        return finalOrder
    }

    private func spreadByDomain(_ usernames: [String]) -> [String] {
        var domainQueues: [String: [String]] = [:]
        for username in usernames {
            let domain = extractDomain(from: username)
            domainQueues[domain, default: []].append(username)
        }

        let sortedDomains = domainQueues.keys.sorted { a, b in
            let rateA = store.domainSuccessHistory[a]?.accountFoundRate ?? 0.5
            let rateB = store.domainSuccessHistory[b]?.accountFoundRate ?? 0.5
            return rateA > rateB
        }

        var result: [String] = []
        var domainIdx: [String: Int] = [:]
        var remaining = usernames.count

        while remaining > 0 {
            for domain in sortedDomains {
                let idx = domainIdx[domain, default: 0]
                guard let queue = domainQueues[domain], idx < queue.count else { continue }
                result.append(queue[idx])
                domainIdx[domain] = idx + 1
                remaining -= 1
            }
        }

        return result
    }

    private func applyDomainSpreading(_ credentials: [LoginCredential]) -> [LoginCredential] {
        let ordered = spreadByDomain(credentials.map { $0.username })
        let lookup = Dictionary(uniqueKeysWithValues: credentials.map { ($0.username, $0) })
        return ordered.compactMap { lookup[$0] }
    }

    private func buildDomainSpreadMap(ordered: [String], credentials: [LoginCredential]) -> [String: [Int]] {
        var map: [String: [Int]] = [:]
        for (idx, username) in ordered.enumerated() {
            let domain = extractDomain(from: username)
            map[domain, default: []].append(idx)
        }
        return map
    }

    private func localPart(_ email: String) -> String {
        guard let atIdx = email.firstIndex(of: "@") else { return email }
        return String(email[..<atIdx]).lowercased()
    }

    private func areSimilar(_ a: String, _ b: String) -> Bool {
        if a == b { return false }
        let cleanA = a.filter { $0.isLetter }
        let cleanB = b.filter { $0.isLetter }
        if cleanA == cleanB { return true }
        if a.count > 3 && b.count > 3 {
            let prefixLen = min(a.count, b.count, 6)
            if a.prefix(prefixLen) == b.prefix(prefixLen) { return true }
        }
        let distance = levenshteinDistance(a, b)
        let maxLen = max(a.count, b.count)
        return maxLen > 0 && Double(distance) / Double(maxLen) < 0.25
    }

    private func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count
        guard m > 0 else { return n }
        guard n > 0 else { return m }
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        for i in 1...m {
            for j in 1...n {
                let cost = aChars[i-1] == bChars[j-1] ? 0 : 1
                dp[i][j] = min(dp[i-1][j] + 1, dp[i][j-1] + 1, dp[i-1][j-1] + cost)
            }
        }
        return dp[m][n]
    }

    private func extractDomain(from email: String) -> String {
        guard let atIndex = email.firstIndex(of: "@") else { return "unknown" }
        return String(email[email.index(after: atIndex)...]).lowercased()
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: persistKey)
        }
    }
}
