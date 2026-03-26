import Foundation

@MainActor
class LoginPatternLearning {
    static let shared = LoginPatternLearning()

    private let persistenceKey = "LoginPatternLearningData"
    private let logger = DebugLogger.shared
    private let aiTiming = AITimingOptimizerService.shared
    private var data: LearningData

    private init() {
        if let saved = UserDefaults.standard.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode(LearningData.self, from: saved) {
            self.data = decoded
        } else {
            self.data = LearningData()
        }
    }

    func recordAttempt(
        url: String,
        pattern: LoginFormPattern,
        fillSuccess: Bool,
        submitSuccess: Bool,
        loginOutcome: String,
        responseTimeMs: Int,
        submitMethod: String
    ) {
        let host = extractHost(from: url)
        let record = AttemptRecord(
            pattern: pattern,
            fillSuccess: fillSuccess,
            submitSuccess: submitSuccess,
            loginOutcome: loginOutcome,
            responseTimeMs: responseTimeMs,
            submitMethod: submitMethod,
            timestamp: Date()
        )

        data.history.append(record)
        if data.history.count > 2000 {
            data.history.removeFirst(data.history.count - 2000)
        }

        var siteStats = data.sitePatternStats[host] ?? [:]
        var stats = siteStats[pattern.rawValue] ?? PatternStats()
        stats.totalAttempts += 1
        if fillSuccess { stats.fillSuccesses += 1 }
        if submitSuccess { stats.submitSuccesses += 1 }
        if loginOutcome == "success" { stats.loginSuccesses += 1 }
        stats.totalResponseTimeMs += responseTimeMs
        stats.lastUsed = Date()

        if loginOutcome == "success" {
            stats.consecutiveFailures = 0
            stats.weight = min(stats.weight + 0.15, 2.0)
        } else if !submitSuccess {
            stats.consecutiveFailures += 1
            stats.weight = max(stats.weight - 0.1, 0.1)
        } else if fillSuccess && submitSuccess {
            stats.weight = max(stats.weight - 0.02, 0.1)
        }

        siteStats[pattern.rawValue] = stats
        data.sitePatternStats[host] = siteStats

        save()

        logger.log(
            "PatternML: recorded \(pattern.rawValue) on \(host) — fill:\(fillSuccess) submit:\(submitSuccess) outcome:\(loginOutcome) weight:\(String(format: "%.2f", stats.weight))",
            category: .automation, level: .debug
        )
    }

    func bestPattern(for url: String) -> LoginFormPattern? {
        let host = extractHost(from: url)
        guard let siteStats = data.sitePatternStats[host] else { return nil }

        var candidates: [(LoginFormPattern, Double)] = []
        for pattern in LoginFormPattern.allCases {
            guard let stats = siteStats[pattern.rawValue], stats.totalAttempts >= 2 else { continue }

            let fillRate = Double(stats.fillSuccesses) / Double(stats.totalAttempts)
            let submitRate = Double(stats.submitSuccesses) / Double(stats.totalAttempts)
            let loginRate = Double(stats.loginSuccesses) / max(Double(stats.submitSuccesses), 1)
            let avgResponseSec = Double(stats.totalResponseTimeMs) / Double(stats.totalAttempts) / 1000.0
            let recencyBonus = min(1.0, max(0.0, 1.0 - (Date().timeIntervalSince(stats.lastUsed) / 86400.0)))

            let timingProfile = aiTiming.profileForHost(host)
            let timingBonus = timingProfile.totalSamples > 10 ? (1.0 - timingProfile.detectionRate) * 0.1 : 0.0

            let score = (fillRate * 0.2 + submitRate * 0.30 + loginRate * 0.3 + recencyBonus * 0.05 + timingBonus) * stats.weight
            let speedPenalty = avgResponseSec > 30 ? 0.9 : 1.0

            if stats.consecutiveFailures >= 5 { continue }

            candidates.append((pattern, score * speedPenalty))
        }

        guard !candidates.isEmpty else { return nil }
        candidates.sort { $0.1 > $1.1 }

        if candidates.count >= 2 && Double.random(in: 0...1) < 0.15 {
            return candidates[1].0
        }

        return candidates.first?.0
    }

    func patternRanking(for url: String) -> [(pattern: LoginFormPattern, score: Double, stats: PatternStats)] {
        let host = extractHost(from: url)
        guard let siteStats = data.sitePatternStats[host] else { return [] }

        var results: [(pattern: LoginFormPattern, score: Double, stats: PatternStats)] = []
        for pattern in LoginFormPattern.allCases {
            guard let stats = siteStats[pattern.rawValue] else { continue }
            let fillRate = Double(stats.fillSuccesses) / max(Double(stats.totalAttempts), 1)
            let submitRate = Double(stats.submitSuccesses) / max(Double(stats.totalAttempts), 1)
            let loginRate = Double(stats.loginSuccesses) / max(Double(stats.submitSuccesses), 1)
            let score = (fillRate * 0.2 + submitRate * 0.35 + loginRate * 0.3) * stats.weight
            results.append((pattern, score, stats))
        }
        results.sort { $0.score > $1.score }
        return results
    }

    func globalStats() -> [String: Any] {
        let total = data.history.count
        let fillSuccesses = data.history.filter { $0.fillSuccess }.count
        let submitSuccesses = data.history.filter { $0.submitSuccess }.count
        let loginSuccesses = data.history.filter { $0.loginOutcome == "success" }.count
        var patternCounts: [String: Int] = [:]
        for record in data.history {
            patternCounts[record.pattern.rawValue, default: 0] += 1
        }
        return [
            "totalAttempts": total,
            "fillSuccessRate": total > 0 ? Double(fillSuccesses) / Double(total) : 0,
            "submitSuccessRate": total > 0 ? Double(submitSuccesses) / Double(total) : 0,
            "loginSuccessRate": total > 0 ? Double(loginSuccesses) / Double(total) : 0,
            "patternDistribution": patternCounts,
            "sitesTracked": data.sitePatternStats.count,
        ]
    }

    func resetLearning() {
        data = LearningData()
        save()
        logger.log("PatternML: all learning data RESET", category: .automation, level: .warning)
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: persistenceKey)
        }
    }

    private func extractHost(from url: String) -> String {
        if let u = URL(string: url) {
            return u.host ?? url
        }
        return url
    }

    // MARK: - Data Types

    nonisolated struct PatternStats: Codable, Sendable {
        var totalAttempts: Int = 0
        var fillSuccesses: Int = 0
        var submitSuccesses: Int = 0
        var loginSuccesses: Int = 0
        var totalResponseTimeMs: Int = 0
        var consecutiveFailures: Int = 0
        var weight: Double = 1.0
        var lastUsed: Date = .distantPast

        var fillRate: Double { totalAttempts > 0 ? Double(fillSuccesses) / Double(totalAttempts) : 0 }
        var submitRate: Double { totalAttempts > 0 ? Double(submitSuccesses) / Double(totalAttempts) : 0 }
        var loginRate: Double { submitSuccesses > 0 ? Double(loginSuccesses) / Double(submitSuccesses) : 0 }
        var avgResponseMs: Int { totalAttempts > 0 ? totalResponseTimeMs / totalAttempts : 0 }
    }

    nonisolated private struct AttemptRecord: Codable, Sendable {
        let pattern: LoginFormPattern
        let fillSuccess: Bool
        let submitSuccess: Bool
        let loginOutcome: String
        let responseTimeMs: Int
        let submitMethod: String
        let timestamp: Date
    }

    nonisolated private struct LearningData: Codable, Sendable {
        var history: [AttemptRecord] = []
        var sitePatternStats: [String: [String: PatternStats]] = [:]
    }
}
