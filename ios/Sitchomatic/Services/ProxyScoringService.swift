import Foundation

nonisolated struct ProxyScore: Sendable {
    let proxyId: UUID
    var successCount: Int = 0
    var failureCount: Int = 0
    var totalLatencyMs: Int = 0
    var recentLatencies: [Int] = []
    var lastSuccessAt: Date?
    var lastFailureAt: Date?
    var consecutiveFailures: Int = 0

    var successRate: Double {
        let total = successCount + failureCount
        guard total > 0 else { return 0.5 }
        return Double(successCount) / Double(total)
    }

    var averageLatencyMs: Int {
        guard !recentLatencies.isEmpty else { return 500 }
        return recentLatencies.reduce(0, +) / recentLatencies.count
    }

    var weightedScore: Double {
        let srWeight = 0.5
        let latencyWeight = 0.3
        let recencyWeight = 0.2

        let srScore = successRate

        let maxAcceptableLatency = 5000.0
        let latencyScore = max(0, 1.0 - (Double(averageLatencyMs) / maxAcceptableLatency))

        var recencyScore = 0.5
        if let lastSuccess = lastSuccessAt {
            let secondsAgo = Date().timeIntervalSince(lastSuccess)
            recencyScore = max(0, 1.0 - (secondsAgo / 3600.0))
        }

        let penaltyFactor = consecutiveFailures >= 3 ? 0.1 : (consecutiveFailures >= 2 ? 0.5 : 1.0)

        return (srScore * srWeight + latencyScore * latencyWeight + recencyScore * recencyWeight) * penaltyFactor
    }
}

actor ProxyScoringService {
    static let shared = ProxyScoringService()

    private(set) var scores: [UUID: ProxyScore] = [:]
    private let persistKey = "proxy_scoring_v1"
    private let maxRecentLatencies = 20

    init() {
        if let data = UserDefaults.standard.data(forKey: persistKey),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for dict in array {
                guard let idStr = dict["id"] as? String, let id = UUID(uuidString: idStr) else { continue }
                var score = ProxyScore(proxyId: id)
                score.successCount = dict["successCount"] as? Int ?? 0
                score.failureCount = dict["failureCount"] as? Int ?? 0
                score.totalLatencyMs = dict["totalLatencyMs"] as? Int ?? 0
                score.recentLatencies = dict["recentLatencies"] as? [Int] ?? []
                score.consecutiveFailures = dict["consecutiveFailures"] as? Int ?? 0
                if let ts = dict["lastSuccessAt"] as? TimeInterval, ts > 0 {
                    score.lastSuccessAt = Date(timeIntervalSince1970: ts)
                }
                if let ts = dict["lastFailureAt"] as? TimeInterval, ts > 0 {
                    score.lastFailureAt = Date(timeIntervalSince1970: ts)
                }
                scores[id] = score
            }
        }
    }

    func recordSuccess(proxyId: UUID, latencyMs: Int) {
        var score = scores[proxyId] ?? ProxyScore(proxyId: proxyId)
        score.successCount += 1
        score.lastSuccessAt = Date()
        score.consecutiveFailures = 0
        score.recentLatencies.append(latencyMs)
        if score.recentLatencies.count > maxRecentLatencies {
            score.recentLatencies.removeFirst()
        }
        score.totalLatencyMs += latencyMs
        scores[proxyId] = score
        persistScores()
    }

    func recordFailure(proxyId: UUID) {
        var score = scores[proxyId] ?? ProxyScore(proxyId: proxyId)
        score.failureCount += 1
        score.lastFailureAt = Date()
        score.consecutiveFailures += 1
        scores[proxyId] = score
        persistScores()
    }

    func bestProxy(from proxies: [ProxyConfig]) -> ProxyConfig? {
        guard !proxies.isEmpty else { return nil }

        let scored = proxies.map { proxy -> (ProxyConfig, Double) in
            let score = scores[proxy.id]?.weightedScore ?? 0.5
            return (proxy, score)
        }

        let sorted = scored.sorted { $0.1 > $1.1 }

        let topCount = max(1, min(3, sorted.count))
        let topCandidates = Array(sorted.prefix(topCount))
        let totalWeight = topCandidates.reduce(0.0) { $0 + $1.1 }

        guard totalWeight > 0 else {
            return proxies.randomElement()
        }

        let random = Double.random(in: 0..<totalWeight)
        var cumulative = 0.0
        for (proxy, weight) in topCandidates {
            cumulative += weight
            if random < cumulative {
                return proxy
            }
        }

        return topCandidates.last?.0 ?? proxies.first
    }

    func scoreLabel(for proxyId: UUID) -> String {
        guard let score = scores[proxyId] else { return "No data" }
        let pct = Int(score.successRate * 100)
        let avg = score.averageLatencyMs
        return "\(pct)% success, \(avg)ms avg"
    }

    func resetScores() {
        scores.removeAll()
        persistScores()
        DebugLogger.logBackground("ProxyScoring: all scores reset", category: .proxy, level: .info)
    }

    func resetScore(for proxyId: UUID) {
        scores.removeValue(forKey: proxyId)
        persistScores()
    }

    private func persistScores() {
        let encoded = scores.map { (key, value) -> [String: Any] in
            [
                "id": key.uuidString,
                "successCount": value.successCount,
                "failureCount": value.failureCount,
                "totalLatencyMs": value.totalLatencyMs,
                "recentLatencies": value.recentLatencies,
                "consecutiveFailures": value.consecutiveFailures,
                "lastSuccessAt": value.lastSuccessAt?.timeIntervalSince1970 ?? 0,
                "lastFailureAt": value.lastFailureAt?.timeIntervalSince1970 ?? 0,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: encoded) {
            UserDefaults.standard.set(data, forKey: persistKey)
        }
    }

    private func loadScores() {
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        for dict in array {
            guard let idStr = dict["id"] as? String, let id = UUID(uuidString: idStr) else { continue }
            var score = ProxyScore(proxyId: id)
            score.successCount = dict["successCount"] as? Int ?? 0
            score.failureCount = dict["failureCount"] as? Int ?? 0
            score.totalLatencyMs = dict["totalLatencyMs"] as? Int ?? 0
            score.recentLatencies = dict["recentLatencies"] as? [Int] ?? []
            score.consecutiveFailures = dict["consecutiveFailures"] as? Int ?? 0
            if let ts = dict["lastSuccessAt"] as? TimeInterval, ts > 0 {
                score.lastSuccessAt = Date(timeIntervalSince1970: ts)
            }
            if let ts = dict["lastFailureAt"] as? TimeInterval, ts > 0 {
                score.lastFailureAt = Date(timeIntervalSince1970: ts)
            }
            scores[id] = score
        }
    }
}
