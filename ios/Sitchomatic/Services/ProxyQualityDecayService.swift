import Foundation

actor ProxyQualityDecayService {
    static let shared = ProxyQualityDecayService()

    private let persistKey = "proxy_quality_decay_v2"
    private var proxyScores: [String: DecayingProxyScore] = [:]
    private let decayHalfLifeSeconds: TimeInterval = 1800
    private let maxRecentEntries: Int = 50

    init() {
        if let data = UserDefaults.standard.data(forKey: persistKey),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            for (id, values) in dict {
                var score = DecayingProxyScore(identifier: id)
                score.totalAttempts = values["totalAttempts"] as? Int ?? 0
                if let ts = values["lastUpdated"] as? TimeInterval {
                    score.lastUpdated = Date(timeIntervalSince1970: ts)
                }
                if let successArray = values["successes"] as? [[String: Any]] {
                    score.successes = successArray.compactMap { entry in
                        guard let ts = entry["ts"] as? TimeInterval,
                              let lat = entry["lat"] as? Int else { return nil }
                        return (Date(timeIntervalSince1970: ts), lat)
                    }
                }
                if let failureArray = values["failures"] as? [[String: Any]] {
                    score.failures = failureArray.compactMap { entry in
                        guard let ts = entry["ts"] as? TimeInterval,
                              let type = entry["type"] as? String else { return nil }
                        return (Date(timeIntervalSince1970: ts), type)
                    }
                }
                proxyScores[id] = score
            }
        } else {
            let oldKey = "proxy_quality_decay_v1"
            if let data = UserDefaults.standard.data(forKey: oldKey),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
                for (id, values) in dict {
                    var score = DecayingProxyScore(identifier: id)
                    score.totalAttempts = values["totalAttempts"] as? Int ?? 0
                    if let ts = values["lastUpdated"] as? TimeInterval {
                        score.lastUpdated = Date(timeIntervalSince1970: ts)
                    }
                    proxyScores[id] = score
                }
                UserDefaults.standard.removeObject(forKey: oldKey)
            }
        }
    }

    struct DecayingProxyScore {
        var identifier: String
        var successes: [(date: Date, latencyMs: Int)] = []
        var failures: [(date: Date, type: String)] = []
        var totalAttempts: Int = 0
        var lastUpdated: Date = .distantPast

        func weightedSuccessRate(halfLife: TimeInterval) -> Double {
            let now = Date()
            var weightedSuccess = 0.0
            var weightedTotal = 0.0

            for entry in successes.suffix(50) {
                let age = now.timeIntervalSince(entry.date)
                let weight = pow(0.5, age / halfLife)
                weightedSuccess += weight
                weightedTotal += weight
            }

            for entry in failures.suffix(50) {
                let age = now.timeIntervalSince(entry.date)
                let weight = pow(0.5, age / halfLife)
                weightedTotal += weight
            }

            guard weightedTotal > 0 else { return 0.5 }
            return weightedSuccess / weightedTotal
        }

        func weightedLatencyMs(halfLife: TimeInterval) -> Double {
            let now = Date()
            var weightedSum = 0.0
            var weightedCount = 0.0

            for entry in successes.suffix(30) {
                let age = now.timeIntervalSince(entry.date)
                let weight = pow(0.5, age / halfLife)
                weightedSum += Double(entry.latencyMs) * weight
                weightedCount += weight
            }

            return weightedCount > 0 ? weightedSum / weightedCount : 5000
        }

        func compositeScore(halfLife: TimeInterval) -> Double {
            let sr = weightedSuccessRate(halfLife: halfLife)
            let latency = weightedLatencyMs(halfLife: halfLife)
            let latencyScore = max(0, 1.0 - (latency / 15000.0))

            let now = Date()
            var recencyScore = 0.3
            if let lastSuccess = successes.last?.date {
                let ago = now.timeIntervalSince(lastSuccess)
                recencyScore = max(0, 1.0 - (ago / 7200.0))
            }

            let recentFailTypes = failures.suffix(5).map { $0.type }
            let consecutiveFailPenalty = recentFailTypes.allSatisfy({ !$0.isEmpty }) && recentFailTypes.count >= 3 ? 0.3 : 1.0

            return (sr * 0.45 + latencyScore * 0.30 + recencyScore * 0.25) * consecutiveFailPenalty
        }
    }

    func recordSuccess(proxyId: String, latencyMs: Int) {
        var score = proxyScores[proxyId] ?? DecayingProxyScore(identifier: proxyId)
        score.successes.append((Date(), latencyMs))
        score.totalAttempts += 1
        score.lastUpdated = Date()
        trimEntries(&score)
        proxyScores[proxyId] = score
        persistScores()
    }

    func recordFailure(proxyId: String, failureType: String) {
        var score = proxyScores[proxyId] ?? DecayingProxyScore(identifier: proxyId)
        score.failures.append((Date(), failureType))
        score.totalAttempts += 1
        score.lastUpdated = Date()
        trimEntries(&score)
        proxyScores[proxyId] = score
        persistScores()
    }

    func scoreFor(proxyId: String) -> Double {
        proxyScores[proxyId]?.compositeScore(halfLife: decayHalfLifeSeconds) ?? 0.5
    }

    func selectBestProxy(from proxyIds: [String]) -> String? {
        guard !proxyIds.isEmpty else { return nil }
        if proxyIds.count == 1 { return proxyIds.first }

        let scored = proxyIds.map { id -> (String, Double) in
            (id, scoreFor(proxyId: id))
        }

        let minFloor = 0.15
        let totalWeight = scored.reduce(0.0) { $0 + max($1.1, minFloor) }
        var random = Double.random(in: 0..<totalWeight)

        for (id, weight) in scored {
            random -= max(weight, minFloor)
            if random <= 0 { return id }
        }

        return proxyIds.last
    }

    func allScores() -> [(id: String, score: Double, attempts: Int, successRate: Int, avgLatency: Int)] {
        proxyScores.map { id, score in
            (id, score.compositeScore(halfLife: decayHalfLifeSeconds), score.totalAttempts, Int(score.weightedSuccessRate(halfLife: decayHalfLifeSeconds) * 100), Int(score.weightedLatencyMs(halfLife: decayHalfLifeSeconds)))
        }.sorted { $0.1 > $1.1 }
    }

    func isDemoted(proxyId: String, threshold: Double = 0.2) -> Bool {
        scoreFor(proxyId: proxyId) < threshold
    }

    func resetAll() {
        proxyScores.removeAll()
        persistScores()
        DebugLogger.logBackground("ProxyQualityDecay: all scores reset", category: .proxy, level: .info)
    }

    private func trimEntries(_ score: inout DecayingProxyScore) {
        if score.successes.count > maxRecentEntries {
            score.successes = Array(score.successes.suffix(maxRecentEntries))
        }
        if score.failures.count > maxRecentEntries {
            score.failures = Array(score.failures.suffix(maxRecentEntries))
        }
    }

    private func persistScores() {
        var dict: [String: [String: Any]] = [:]
        for (id, score) in proxyScores {
            let successEntries: [[String: Any]] = score.successes.suffix(maxRecentEntries).map { entry in
                ["ts": entry.date.timeIntervalSince1970, "lat": entry.latencyMs]
            }
            let failureEntries: [[String: Any]] = score.failures.suffix(maxRecentEntries).map { entry in
                ["ts": entry.date.timeIntervalSince1970, "type": entry.type]
            }
            dict[id] = [
                "totalAttempts": score.totalAttempts,
                "lastUpdated": score.lastUpdated.timeIntervalSince1970,
                "successes": successEntries,
                "failures": failureEntries,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            UserDefaults.standard.set(data, forKey: persistKey)
        }
    }

    private func loadScores() {
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            migrateFromV1()
            return
        }
        for (id, values) in dict {
            var score = DecayingProxyScore(identifier: id)
            score.totalAttempts = values["totalAttempts"] as? Int ?? 0
            if let ts = values["lastUpdated"] as? TimeInterval {
                score.lastUpdated = Date(timeIntervalSince1970: ts)
            }
            if let successArray = values["successes"] as? [[String: Any]] {
                score.successes = successArray.compactMap { entry in
                    guard let ts = entry["ts"] as? TimeInterval,
                          let lat = entry["lat"] as? Int else { return nil }
                    return (Date(timeIntervalSince1970: ts), lat)
                }
            }
            if let failureArray = values["failures"] as? [[String: Any]] {
                score.failures = failureArray.compactMap { entry in
                    guard let ts = entry["ts"] as? TimeInterval,
                          let type = entry["type"] as? String else { return nil }
                    return (Date(timeIntervalSince1970: ts), type)
                }
            }
            proxyScores[id] = score
        }
        let totalEntries = proxyScores.values.reduce(0) { $0 + $1.successes.count + $1.failures.count }
        DebugLogger.logBackground("ProxyQualityDecay: loaded \(proxyScores.count) proxies with \(totalEntries) history entries", category: .proxy, level: .info)
    }

    private func migrateFromV1() {
        let oldKey = "proxy_quality_decay_v1"
        guard let data = UserDefaults.standard.data(forKey: oldKey),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return }
        for (id, values) in dict {
            var score = DecayingProxyScore(identifier: id)
            score.totalAttempts = values["totalAttempts"] as? Int ?? 0
            if let ts = values["lastUpdated"] as? TimeInterval {
                score.lastUpdated = Date(timeIntervalSince1970: ts)
            }
            proxyScores[id] = score
        }
        persistScores()
        UserDefaults.standard.removeObject(forKey: oldKey)
        DebugLogger.logBackground("ProxyQualityDecay: migrated \(proxyScores.count) entries from v1 to v2", category: .proxy, level: .info)
    }
}
