import Foundation

nonisolated struct InterventionRecord: Codable, Sendable {
    let host: String
    let pageContentSnippet: String
    let currentURL: String
    let originalClassification: String
    let userCorrectedOutcome: String
    let actionTaken: String
    let timestamp: Date
}

nonisolated struct InterventionPattern: Codable, Sendable {
    var keywords: [String: Int] = [:]
    var urlPatterns: [String: Int] = [:]
    var correctionCount: Int = 0
    var lastUpdated: Date = .distantPast
}

nonisolated struct InterventionLearningStore: Codable, Sendable {
    var records: [InterventionRecord] = []
    var outcomePatterns: [String: InterventionPattern] = [:]
    var autoHealRules: [String: String] = [:]
    var totalCorrections: Int = 0
    var totalAutoHeals: Int = 0
}

@MainActor
class UserInterventionLearningService {
    static let shared = UserInterventionLearningService()

    private let persistenceKey = "UserInterventionLearning_v1"
    private let maxRecords = 500
    private let logger = DebugLogger.shared
    private var store: InterventionLearningStore

    private init() {
        if let data = UserDefaults.standard.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode(InterventionLearningStore.self, from: data) {
            self.store = decoded
        } else {
            self.store = InterventionLearningStore()
        }
    }

    func recordCorrection(
        host: String,
        pageContent: String,
        currentURL: String,
        originalClassification: String,
        userCorrectedOutcome: String,
        actionTaken: String
    ) {
        let snippet = String(pageContent.prefix(1000))

        let record = InterventionRecord(
            host: host,
            pageContentSnippet: snippet,
            currentURL: currentURL,
            originalClassification: originalClassification,
            userCorrectedOutcome: userCorrectedOutcome,
            actionTaken: actionTaken,
            timestamp: Date()
        )
        store.records.append(record)
        if store.records.count > maxRecords {
            store.records.removeFirst(store.records.count - maxRecords)
        }
        store.totalCorrections += 1

        updatePatterns(host: host, pageContent: snippet, currentURL: currentURL, correctedOutcome: userCorrectedOutcome)

        let confidenceEngine = ConfidenceResultEngine.shared
        let originalLoginOutcome = mapStringToOutcome(originalClassification)
        let correctedLoginOutcome = mapStringToOutcome(userCorrectedOutcome)
        confidenceEngine.recordOutcomeFeedback(
            host: host,
            predictedOutcome: originalLoginOutcome,
            actualOutcome: correctedLoginOutcome,
            confidence: 0.3,
            pageContent: snippet
        )

        persist()
        logger.log("InterventionLearning: Recorded correction \(originalClassification) → \(userCorrectedOutcome) for \(host) (total: \(store.totalCorrections))", category: .evaluation, level: .info)
    }

    func suggestAutoHeal(host: String, pageContent: String, currentURL: String) -> (outcome: String, confidence: Double)? {
        let contentLower = pageContent.lowercased()

        for (outcome, pattern) in store.outcomePatterns {
            guard pattern.correctionCount >= 3 else { continue }

            var matchScore = 0
            var totalKeywords = 0
            for (keyword, count) in pattern.keywords where count >= 2 {
                totalKeywords += 1
                if contentLower.contains(keyword) {
                    matchScore += count
                }
            }

            guard totalKeywords > 0 else { continue }
            let keywordMatch = Double(matchScore) / Double(pattern.keywords.values.reduce(0, +))

            if keywordMatch > 0.4 {
                let confidence = min(0.95, 0.5 + (keywordMatch * 0.3) + (min(Double(pattern.correctionCount), 20.0) / 40.0))
                store.totalAutoHeals += 1
                persist()
                logger.log("InterventionLearning: Auto-heal suggestion for \(host) → \(outcome) (confidence: \(String(format: "%.0f%%", confidence * 100)), based on \(pattern.correctionCount) corrections)", category: .evaluation, level: .info)
                return (outcome, confidence)
            }
        }
        return nil
    }

    var totalCorrections: Int { store.totalCorrections }
    var totalAutoHeals: Int { store.totalAutoHeals }
    var recordCount: Int { store.records.count }

    func recentCorrections(limit: Int = 20) -> [InterventionRecord] {
        Array(store.records.suffix(limit).reversed())
    }

    func resetAll() {
        store = InterventionLearningStore()
        persist()
    }

    private func updatePatterns(host: String, pageContent: String, currentURL: String, correctedOutcome: String) {
        var pattern = store.outcomePatterns[correctedOutcome] ?? InterventionPattern()

        let words = pageContent.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count >= 4 && $0.count <= 40 }

        let significantWords = Set(words).subtracting(["https", "http", "this", "that", "with", "from", "have", "been", "your", "will", "please"])
        for word in significantWords.prefix(30) {
            pattern.keywords[word, default: 0] += 1
        }

        if let urlHost = URL(string: currentURL)?.host {
            pattern.urlPatterns[urlHost, default: 0] += 1
        }

        pattern.correctionCount += 1
        pattern.lastUpdated = Date()

        store.outcomePatterns[correctedOutcome] = pattern
    }

    private func mapStringToOutcome(_ str: String) -> LoginOutcome {
        switch str.lowercased() {
        case "success": .success
        case "noaccount", "noacc": .noAcc
        case "disabled", "permdisabled": .permDisabled
        case "tempdisabled": .tempDisabled
        default: .unsure
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
        }
    }
}
