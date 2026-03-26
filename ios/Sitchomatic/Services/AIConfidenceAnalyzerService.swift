import Foundation

nonisolated struct HostKeywordProfile: Codable, Sendable {
    var successKeywords: [String: Int] = [:]
    var failKeywords: [String: Int] = [:]
    var disabledKeywords: [String: Int] = [:]
    var tempDisabledKeywords: [String: Int] = [:]
    var totalFeedback: Int = 0
    var lastUpdated: Date = .distantPast
}

nonisolated struct AIClassificationResult: Codable, Sendable {
    let outcome: String
    let confidence: Double
    let reasoning: String
    let newKeywords: [String]?
}

nonisolated struct ConfidenceFeedbackRecord: Codable, Sendable {
    let host: String
    let predictedOutcome: String
    let actualOutcome: String
    let confidence: Double
    let pageSnippet: String
    let timestamp: Date
}

nonisolated struct AIConfidenceStore: Codable, Sendable {
    var hostProfiles: [String: HostKeywordProfile] = [:]
    var feedbackHistory: [ConfidenceFeedbackRecord] = []
    var aiCallCount: Int = 0
    var aiCorrections: Int = 0
}

@MainActor
class AIConfidenceAnalyzerService {
    static let shared = AIConfidenceAnalyzerService()

    private let logger = DebugLogger.shared
    private let persistenceKey = "AIConfidenceAnalyzerData"
    private let maxFeedbackHistory = 500
    private let aiConfidenceThreshold = 0.45
    private var store: AIConfidenceStore

    private init() {
        if let saved = UserDefaults.standard.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode(AIConfidenceStore.self, from: saved) {
            self.store = decoded
        } else {
            self.store = AIConfidenceStore()
        }
    }

    func shouldUseAIFallback(confidence: Double) -> Bool {
        confidence < aiConfidenceThreshold
    }

    func analyzeWithAI(
        host: String,
        pageContent: String,
        currentURL: String,
        pageTitle: String,
        staticOutcome: String,
        staticConfidence: Double
    ) async -> AIClassificationResult? {
        let snippet = String(pageContent.prefix(3000))
        let profile = store.hostProfiles[host]

        var contextInfo = "Host: \(host)\nURL: \(currentURL)\nTitle: \(pageTitle)\n"
        contextInfo += "Static classifier said: \(staticOutcome) (confidence: \(String(format: "%.0f%%", staticConfidence * 100)))\n"

        if let profile, profile.totalFeedback > 0 {
            let topSuccess = profile.successKeywords.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key)(\($0.value))" }.joined(separator: ", ")
            let topFail = profile.failKeywords.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key)(\($0.value))" }.joined(separator: ", ")
            let topDisabled = profile.disabledKeywords.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key)(\($0.value))" }.joined(separator: ", ")
            contextInfo += "Learned success keywords: \(topSuccess)\n"
            contextInfo += "Learned fail keywords: \(topFail)\n"
            contextInfo += "Learned disabled keywords: \(topDisabled)\n"
        }

        let systemPrompt = """
        You classify login attempt outcomes for online casino websites (JoeFortune, Ignition Casino). \
        Analyze the page content and return ONLY a JSON object. \
        Possible outcomes: "success" (logged in), "permDisabled" (account permanently disabled/suspended/closed), \
        "tempDisabled" (temporarily locked due to too many attempts), "noAcc" (wrong password or no account), \
        "unsure" (cannot determine). \
        Also identify any new keywords from this page that indicate the outcome. \
        Format: {"outcome":"...","confidence":0.0-1.0,"reasoning":"brief explanation","newKeywords":["keyword1","keyword2"]}. \
        Return ONLY the JSON.
        """

        let userPrompt = "\(contextInfo)\nPage content:\n\(snippet)"

        logger.log("AIConfidence: requesting AI analysis for \(host) (static: \(staticOutcome) @ \(String(format: "%.0f%%", staticConfidence * 100)))", category: .evaluation, level: .info)

        store.aiCallCount += 1
        save()

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: userPrompt) else {
            logger.log("AIConfidence: AI call failed for \(host)", category: .evaluation, level: .warning)
            return nil
        }

        return parseAIResponse(response, host: host)
    }

    func learnedKeywordBoost(host: String, pageContent: String) -> (outcome: String, boost: Double)? {
        guard let profile = store.hostProfiles[host], profile.totalFeedback >= 3 else { return nil }

        let content = pageContent.lowercased()
        var scores: [String: Double] = [:]

        for (keyword, count) in profile.successKeywords {
            if content.contains(keyword.lowercased()) {
                let weight = min(Double(count) / Double(profile.totalFeedback), 0.3)
                scores["success", default: 0] += weight
            }
        }
        for (keyword, count) in profile.disabledKeywords {
            if content.contains(keyword.lowercased()) {
                let weight = min(Double(count) / Double(profile.totalFeedback), 0.3)
                scores["permDisabled", default: 0] += weight
            }
        }
        for (keyword, count) in profile.tempDisabledKeywords {
            if content.contains(keyword.lowercased()) {
                let weight = min(Double(count) / Double(profile.totalFeedback), 0.3)
                scores["tempDisabled", default: 0] += weight
            }
        }
        for (keyword, count) in profile.failKeywords {
            if content.contains(keyword.lowercased()) {
                let weight = min(Double(count) / Double(profile.totalFeedback), 0.3)
                scores["noAcc", default: 0] += weight
            }
        }

        guard let best = scores.max(by: { $0.value < $1.value }), best.value >= 0.05 else { return nil }

        logger.log("AIConfidence: learned keyword boost for \(host) → \(best.key) +\(String(format: "%.2f", best.value))", category: .evaluation, level: .debug)
        return (best.key, best.value)
    }

    func recordFeedback(
        host: String,
        predictedOutcome: String,
        actualOutcome: String,
        confidence: Double,
        pageContent: String,
        newKeywords: [String]? = nil
    ) {
        let record = ConfidenceFeedbackRecord(
            host: host,
            predictedOutcome: predictedOutcome,
            actualOutcome: actualOutcome,
            confidence: confidence,
            pageSnippet: String(pageContent.prefix(500)),
            timestamp: Date()
        )

        store.feedbackHistory.append(record)
        if store.feedbackHistory.count > maxFeedbackHistory {
            store.feedbackHistory.removeFirst(store.feedbackHistory.count - maxFeedbackHistory)
        }

        if predictedOutcome != actualOutcome {
            store.aiCorrections += 1
        }

        var profile = store.hostProfiles[host] ?? HostKeywordProfile()
        profile.totalFeedback += 1
        profile.lastUpdated = Date()

        let content = pageContent.lowercased()
        let words = extractSignificantPhrases(from: content)

        switch actualOutcome {
        case "success":
            for word in words { profile.successKeywords[word, default: 0] += 1 }
        case "permDisabled":
            for word in words { profile.disabledKeywords[word, default: 0] += 1 }
        case "tempDisabled":
            for word in words { profile.tempDisabledKeywords[word, default: 0] += 1 }
        case "noAcc":
            for word in words { profile.failKeywords[word, default: 0] += 1 }
        default:
            break
        }

        if let newKeywords, !newKeywords.isEmpty {
            switch actualOutcome {
            case "success":
                for kw in newKeywords { profile.successKeywords[kw.lowercased(), default: 0] += 2 }
            case "permDisabled":
                for kw in newKeywords { profile.disabledKeywords[kw.lowercased(), default: 0] += 2 }
            case "tempDisabled":
                for kw in newKeywords { profile.tempDisabledKeywords[kw.lowercased(), default: 0] += 2 }
            case "noAcc":
                for kw in newKeywords { profile.failKeywords[kw.lowercased(), default: 0] += 2 }
            default:
                break
            }
        }

        pruneProfile(&profile)
        store.hostProfiles[host] = profile
        save()

        logger.log("AIConfidence: feedback recorded for \(host) — predicted:\(predictedOutcome) actual:\(actualOutcome) match:\(predictedOutcome == actualOutcome)", category: .evaluation, level: predictedOutcome == actualOutcome ? .debug : .warning)
    }

    func statsForHost(_ host: String) -> HostKeywordProfile? {
        store.hostProfiles[host]
    }

    func globalStats() -> (aiCalls: Int, corrections: Int, feedbackCount: Int, hostsTracked: Int) {
        (store.aiCallCount, store.aiCorrections, store.feedbackHistory.count, store.hostProfiles.count)
    }

    func resetHost(_ host: String) {
        store.hostProfiles.removeValue(forKey: host)
        save()
    }

    func resetAll() {
        store = AIConfidenceStore()
        save()
    }

    private func parseAIResponse(_ response: String, host: String) -> AIClassificationResult? {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outcome = json["outcome"] as? String,
              let confidence = json["confidence"] as? Double else {
            logger.log("AIConfidence: failed to parse AI response for \(host)", category: .evaluation, level: .warning)
            return nil
        }

        let reasoning = json["reasoning"] as? String ?? "no reasoning"
        let newKeywords = json["newKeywords"] as? [String]

        logger.log("AIConfidence: AI says \(outcome) (\(String(format: "%.0f%%", confidence * 100))) for \(host) — \(reasoning)", category: .evaluation, level: .info)

        return AIClassificationResult(outcome: outcome, confidence: confidence, reasoning: reasoning, newKeywords: newKeywords)
    }

    private func extractSignificantPhrases(from content: String) -> [String] {
        let loginPhrases = [
            "incorrect password", "invalid credentials", "wrong password",
            "account has been disabled", "account has been suspended",
            "temporarily locked", "too many attempts", "try again later",
            "balance", "wallet", "my account", "logout", "dashboard",
            "welcome back", "successfully logged", "account not found",
            "permanently banned", "self-excluded", "account is closed",
            "temporarily disabled", "login failed", "authentication failed",
            "sms verification", "verification code", "phone verification"
        ]

        var found: [String] = []
        for phrase in loginPhrases {
            if content.contains(phrase) {
                found.append(phrase)
            }
        }
        return found
    }

    private func pruneProfile(_ profile: inout HostKeywordProfile) {
        let maxKeywords = 50
        if profile.successKeywords.count > maxKeywords {
            let sorted = profile.successKeywords.sorted { $0.value > $1.value }
            profile.successKeywords = Dictionary(uniqueKeysWithValues: Array(sorted.prefix(maxKeywords)))
        }
        if profile.failKeywords.count > maxKeywords {
            let sorted = profile.failKeywords.sorted { $0.value > $1.value }
            profile.failKeywords = Dictionary(uniqueKeysWithValues: Array(sorted.prefix(maxKeywords)))
        }
        if profile.disabledKeywords.count > maxKeywords {
            let sorted = profile.disabledKeywords.sorted { $0.value > $1.value }
            profile.disabledKeywords = Dictionary(uniqueKeysWithValues: Array(sorted.prefix(maxKeywords)))
        }
        if profile.tempDisabledKeywords.count > maxKeywords {
            let sorted = profile.tempDisabledKeywords.sorted { $0.value > $1.value }
            profile.tempDisabledKeywords = Dictionary(uniqueKeysWithValues: Array(sorted.prefix(maxKeywords)))
        }
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: persistenceKey)
        }
    }
}
