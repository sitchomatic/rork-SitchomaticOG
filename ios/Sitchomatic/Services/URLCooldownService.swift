import Foundation

actor URLCooldownService {
    static let shared = URLCooldownService()

    private var cooldowns: [String: CooldownEntry] = [:]
    private var urlStats: [String: URLSuccessStats] = [:]
    private var disabledURLs: Set<String> = []

    var defaultCooldownSeconds: TimeInterval = 60
    var maxConsecutiveFailuresBeforeCooldown: Int = 2
    var autoDisableThreshold: Double = 0.2
    var autoDisableMinAttempts: Int = 10

    private struct CooldownEntry {
        var consecutiveFailures: Int = 0
        var cooldownUntil: Date?
        var lastFailure: Date?
    }

    private struct URLSuccessStats {
        var successes: Int = 0
        var failures: Int = 0
        var totalAttempts: Int { successes + failures }
        var successRate: Double { totalAttempts > 0 ? Double(successes) / Double(totalAttempts) : 0 }
        var recentResults: [Bool] = []
        var disabledAt: Date?

        mutating func record(success: Bool) {
            if success { successes += 1 } else { failures += 1 }
            recentResults.append(success)
            if recentResults.count > 20 {
                recentResults.removeFirst()
            }
        }

        var rollingSuccessRate: Double {
            guard !recentResults.isEmpty else { return 0 }
            return Double(recentResults.filter { $0 }.count) / Double(recentResults.count)
        }
    }

    func recordFailure(for url: String) {
        let host = extractHost(from: url)
        var entry = cooldowns[host] ?? CooldownEntry()
        entry.consecutiveFailures += 1
        entry.lastFailure = Date()

        if entry.consecutiveFailures >= maxConsecutiveFailuresBeforeCooldown {
            entry.cooldownUntil = Date().addingTimeInterval(defaultCooldownSeconds)
            DebugLogger.logBackground("URLCooldown: \(host) placed on \(Int(defaultCooldownSeconds))s cooldown after \(entry.consecutiveFailures) consecutive failures", category: .network, level: .warning)
        }

        cooldowns[host] = entry

        var stats = urlStats[host] ?? URLSuccessStats()
        stats.record(success: false)
        urlStats[host] = stats

        if stats.totalAttempts >= autoDisableMinAttempts && stats.rollingSuccessRate < autoDisableThreshold && !disabledURLs.contains(host) {
            disabledURLs.insert(host)
            urlStats[host]?.disabledAt = Date()
            DebugLogger.logBackground("URLCooldown: AUTO-DISABLED \(host) — rolling success rate \(Int(stats.rollingSuccessRate * 100))% over \(stats.totalAttempts) attempts", category: .network, level: .critical)
        }
    }

    func recordSuccess(for url: String) {
        let host = extractHost(from: url)
        cooldowns[host] = nil

        var stats = urlStats[host] ?? URLSuccessStats()
        stats.record(success: true)
        urlStats[host] = stats
    }

    func isOnCooldown(_ url: String) -> Bool {
        let host = extractHost(from: url)
        guard var entry = cooldowns[host], let until = entry.cooldownUntil else { return false }
        if Date() >= until {
            entry.cooldownUntil = nil
            entry.consecutiveFailures = 0
            cooldowns[host] = entry
            return false
        }
        return true
    }

    func cooldownRemaining(_ url: String) -> TimeInterval {
        let host = extractHost(from: url)
        guard let entry = cooldowns[host], let until = entry.cooldownUntil else { return 0 }
        return max(0, until.timeIntervalSince(Date()))
    }

    func isAutoDisabled(_ url: String) -> Bool {
        disabledURLs.contains(extractHost(from: url))
    }

    func reEnableURL(_ url: String) {
        let host = extractHost(from: url)
        disabledURLs.remove(host)
        urlStats[host]?.recentResults.removeAll()
        urlStats[host]?.disabledAt = nil
        DebugLogger.logBackground("URLCooldown: re-enabled \(host)", category: .network, level: .info)
    }

    func disabledURLsList() -> [(host: String, successRate: Int, attempts: Int, disabledSince: Date?)] {
        disabledURLs.compactMap { host in
            guard let stats = urlStats[host] else { return nil }
            return (host, Int(stats.rollingSuccessRate * 100), stats.totalAttempts, stats.disabledAt)
        }.sorted { $0.attempts > $1.attempts }
    }

    func urlSuccessRate(for url: String) -> (rate: Double, attempts: Int)? {
        let host = extractHost(from: url)
        guard let stats = urlStats[host], stats.totalAttempts > 0 else { return nil }
        return (stats.rollingSuccessRate, stats.totalAttempts)
    }

    func allURLStats() -> [(host: String, successRate: Int, attempts: Int, disabled: Bool)] {
        urlStats.map { host, stats in
            (host, Int(stats.rollingSuccessRate * 100), stats.totalAttempts, disabledURLs.contains(host))
        }.sorted { $0.attempts > $1.attempts }
    }

    func clearAll() {
        cooldowns.removeAll()
        urlStats.removeAll()
        disabledURLs.removeAll()
        DebugLogger.logBackground("URLCooldown: all cooldowns and stats cleared", category: .network, level: .info)
    }

    func activeCooldowns() -> [(host: String, remainingSeconds: Int, failures: Int)] {
        var result: [(host: String, remainingSeconds: Int, failures: Int)] = []
        for (host, entry) in cooldowns {
            guard let until = entry.cooldownUntil, Date() < until else { continue }
            let remaining = Int(until.timeIntervalSince(Date()))
            result.append((host, remaining, entry.consecutiveFailures))
        }
        return result.sorted { $0.remainingSeconds > $1.remainingSeconds }
    }

    private func extractHost(from url: String) -> String {
        if let u = URL(string: url) { return u.host ?? url }
        return url
    }
}
