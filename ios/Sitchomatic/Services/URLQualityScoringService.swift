import Foundation

actor URLQualityScoringService {
    static let shared = URLQualityScoringService()

    private let persistKey = "url_quality_scoring_v2"
    private var urlScores: [String: URLQualityScore] = [:]
    private let decayHalfLifeSeconds: TimeInterval = 3600

    init() {
        if let data = UserDefaults.standard.data(forKey: persistKey),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            for (host, values) in dict {
                var score = URLQualityScore(host: host)
                score.totalAttempts = values["totalAttempts"] as? Int ?? 0
                score.blankPageCount = values["blankPageCount"] as? Int ?? 0
                score.loginSuccessCount = values["loginSuccessCount"] as? Int ?? 0
                if let ts = values["lastUpdated"] as? TimeInterval {
                    score.lastUpdated = Date(timeIntervalSince1970: ts)
                }
                urlScores[host] = score
            }
        }
    }

    struct URLQualityScore {
        var host: String
        var recentLatencies: [TimestampedValue] = []
        var recentFailures: [TimestampedFailure] = []
        var recentSuccesses: [Date] = []
        var blankPageCount: Int = 0
        var loginSuccessCount: Int = 0
        var totalAttempts: Int = 0
        var lastUpdated: Date = .distantPast

        struct TimestampedValue {
            let value: Int
            let timestamp: Date
        }

        struct TimestampedFailure {
            let type: String
            let timestamp: Date
        }

        var weightedSuccessRate: Double {
            guard totalAttempts > 0 else { return 0.5 }
            let now = Date()
            let halfLife: TimeInterval = 3600

            var weightedSuccess = 0.0
            var weightedTotal = 0.0

            for date in recentSuccesses.suffix(50) {
                let age = now.timeIntervalSince(date)
                let weight = pow(0.5, age / halfLife)
                weightedSuccess += weight
                weightedTotal += weight
            }

            for failure in recentFailures.suffix(50) {
                let age = now.timeIntervalSince(failure.timestamp)
                let weight = pow(0.5, age / halfLife)
                weightedTotal += weight
            }

            guard weightedTotal > 0 else { return 0.5 }
            return weightedSuccess / weightedTotal
        }

        var averageLatencyMs: Double {
            let recent = recentLatencies.suffix(20)
            guard !recent.isEmpty else { return 5000 }
            let now = Date()
            let halfLife: TimeInterval = 1800

            var weightedSum = 0.0
            var weightedCount = 0.0

            for entry in recent {
                let age = now.timeIntervalSince(entry.timestamp)
                let weight = pow(0.5, age / halfLife)
                weightedSum += Double(entry.value) * weight
                weightedCount += weight
            }

            return weightedCount > 0 ? weightedSum / weightedCount : 5000
        }

        var blankPageRate: Double {
            guard totalAttempts > 0 else { return 0 }
            return Double(blankPageCount) / Double(totalAttempts)
        }

        var loginSuccessRate: Double {
            guard totalAttempts > 0 else { return 0 }
            return Double(loginSuccessCount) / Double(totalAttempts)
        }

        var compositeScore: Double {
            let successWeight = 0.35
            let latencyWeight = 0.25
            let blankPageWeight = 0.20
            let loginSuccessWeight = 0.20

            let sr = weightedSuccessRate
            let latencyScore = max(0, 1.0 - (averageLatencyMs / 15000.0))
            let blankPenalty = 1.0 - blankPageRate
            let loginBonus = loginSuccessRate

            return (sr * successWeight) + (latencyScore * latencyWeight) + (blankPenalty * blankPageWeight) + (loginBonus * loginSuccessWeight)
        }
    }

    func recordSuccess(urlString: String, latencyMs: Int) {
        let host = extractHost(from: urlString)
        var score = urlScores[host] ?? URLQualityScore(host: host)
        score.totalAttempts += 1
        score.recentSuccesses.append(Date())
        score.recentLatencies.append(.init(value: latencyMs, timestamp: Date()))
        score.lastUpdated = Date()
        trimEntries(&score)
        urlScores[host] = score
        persistScores()
    }

    func recordFailure(urlString: String, failureType: String) {
        let host = extractHost(from: urlString)
        var score = urlScores[host] ?? URLQualityScore(host: host)
        score.totalAttempts += 1
        score.recentFailures.append(.init(type: failureType, timestamp: Date()))
        score.lastUpdated = Date()
        trimEntries(&score)
        urlScores[host] = score
        persistScores()
    }

    func recordBlankPage(urlString: String) {
        let host = extractHost(from: urlString)
        var score = urlScores[host] ?? URLQualityScore(host: host)
        score.blankPageCount += 1
        score.lastUpdated = Date()
        urlScores[host] = score
        persistScores()
    }

    func recordLoginSuccess(urlString: String) {
        let host = extractHost(from: urlString)
        var score = urlScores[host] ?? URLQualityScore(host: host)
        score.loginSuccessCount += 1
        score.lastUpdated = Date()
        urlScores[host] = score
        persistScores()
    }

    func selectBestURL(from urls: [URL]) -> URL? {
        guard !urls.isEmpty else { return nil }
        if urls.count == 1 { return urls.first }

        let scored = urls.map { url -> (URL, Double) in
            let host = url.host ?? url.absoluteString
            let score = urlScores[host]?.compositeScore ?? 0.5
            return (url, score)
        }

        let totalWeight = scored.reduce(0.0) { $0 + max($1.1, 0.05) }
        var random = Double.random(in: 0..<totalWeight)

        for (url, weight) in scored {
            random -= max(weight, 0.05)
            if random <= 0 {
                return url
            }
        }

        return urls.last
    }

    func scoreFor(urlString: String) -> Double {
        let host = extractHost(from: urlString)
        return urlScores[host]?.compositeScore ?? 0.5
    }

    func allScores() -> [(host: String, score: Double, attempts: Int, successRate: Int, avgLatency: Int)] {
        urlScores.map { host, score in
            (host, score.compositeScore, score.totalAttempts, Int(score.weightedSuccessRate * 100), Int(score.averageLatencyMs))
        }.sorted { $0.1 > $1.1 }
    }

    func resetAll() {
        urlScores.removeAll()
        persistScores()
        DebugLogger.logBackground("URLQualityScoring: all scores reset", category: .network, level: .info)
    }

    private func trimEntries(_ score: inout URLQualityScore) {
        if score.recentLatencies.count > 100 {
            score.recentLatencies = Array(score.recentLatencies.suffix(50))
        }
        if score.recentFailures.count > 100 {
            score.recentFailures = Array(score.recentFailures.suffix(50))
        }
        if score.recentSuccesses.count > 100 {
            score.recentSuccesses = Array(score.recentSuccesses.suffix(50))
        }
    }

    private func extractHost(from url: String) -> String {
        URL(string: url)?.host ?? url
    }

    private func persistScores() {
        var dict: [String: [String: Any]] = [:]
        for (host, score) in urlScores {
            dict[host] = [
                "totalAttempts": score.totalAttempts,
                "blankPageCount": score.blankPageCount,
                "loginSuccessCount": score.loginSuccessCount,
                "lastUpdated": score.lastUpdated.timeIntervalSince1970,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            UserDefaults.standard.set(data, forKey: persistKey)
        }
    }

    private func loadScores() {
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return }
        for (host, values) in dict {
            var score = URLQualityScore(host: host)
            score.totalAttempts = values["totalAttempts"] as? Int ?? 0
            score.blankPageCount = values["blankPageCount"] as? Int ?? 0
            score.loginSuccessCount = values["loginSuccessCount"] as? Int ?? 0
            if let ts = values["lastUpdated"] as? TimeInterval {
                score.lastUpdated = Date(timeIntervalSince1970: ts)
            }
            urlScores[host] = score
        }
    }
}
