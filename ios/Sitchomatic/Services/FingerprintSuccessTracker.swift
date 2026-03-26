import Foundation

nonisolated struct FingerprintSuccessStats: Codable, Sendable {
    var profileIndex: Int
    var successCount: Int = 0
    var permBanCount: Int = 0
    var tempLockCount: Int = 0
    var noAccountCount: Int = 0
    var timeoutCount: Int = 0
    var connectionFailureCount: Int = 0

    var totalAttempts: Int {
        successCount + permBanCount + tempLockCount + noAccountCount + timeoutCount + connectionFailureCount
    }

    var conclusiveCount: Int {
        successCount + permBanCount + tempLockCount + noAccountCount
    }

    var successRate: Double {
        guard conclusiveCount > 0 else { return 0 }
        return Double(successCount) / Double(conclusiveCount)
    }

    var conclusiveRate: Double {
        guard totalAttempts > 0 else { return 0 }
        return Double(conclusiveCount) / Double(totalAttempts)
    }

    var score: Double {
        guard totalAttempts >= 3 else { return 0.5 }
        let conclusive = conclusiveRate
        let timeoutPenalty = totalAttempts > 0 ? Double(timeoutCount + connectionFailureCount) / Double(totalAttempts) : 0
        return conclusive - (timeoutPenalty * 0.3)
    }
}

nonisolated struct FingerprintStatsStore: Codable, Sendable {
    var profiles: [Int: FingerprintSuccessStats] = [:]
    var totalRecorded: Int = 0
}

nonisolated enum FingerprintSessionOutcome: Sendable {
    case success
    case permBan
    case tempLock
    case noAccount
    case timeout
    case connectionFailure
}

actor FingerprintSuccessTracker {
    static let shared = FingerprintSuccessTracker()

    private let persistKey = "FingerprintSuccessTracker_v1"
    private var store: FingerprintStatsStore

    init() {
        if let data = UserDefaults.standard.data(forKey: persistKey),
           let decoded = try? JSONDecoder().decode(FingerprintStatsStore.self, from: data) {
            self.store = decoded
        } else {
            self.store = FingerprintStatsStore()
        }
    }

    func recordOutcome(profileIndex: Int, outcome: FingerprintSessionOutcome) {
        var stats = store.profiles[profileIndex] ?? FingerprintSuccessStats(profileIndex: profileIndex)

        switch outcome {
        case .success: stats.successCount += 1
        case .permBan: stats.permBanCount += 1
        case .tempLock: stats.tempLockCount += 1
        case .noAccount: stats.noAccountCount += 1
        case .timeout: stats.timeoutCount += 1
        case .connectionFailure: stats.connectionFailureCount += 1
        }

        store.profiles[profileIndex] = stats
        store.totalRecorded += 1
        save()
    }

    func bestProfileIndex(excluding: Set<Int> = [], totalProfiles: Int = 10) -> Int? {
        let candidates = store.profiles.values
            .filter { !excluding.contains($0.profileIndex) && $0.totalAttempts >= 3 }
            .sorted { $0.score > $1.score }

        return candidates.first?.score ?? 0 > 0.3 ? candidates.first?.profileIndex : nil
    }

    func rankedProfileIndices(totalProfiles: Int = 10) -> [Int] {
        let scored = (0..<totalProfiles).map { idx -> (Int, Double) in
            let stats = store.profiles[idx]
            let score = stats?.score ?? 0.5
            return (idx, score)
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    func stats(for profileIndex: Int) -> FingerprintSuccessStats? {
        store.profiles[profileIndex]
    }

    var allStats: [FingerprintSuccessStats] {
        store.profiles.values.sorted { $0.profileIndex < $1.profileIndex }
    }

    func resetStats() {
        store = FingerprintStatsStore()
        save()
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: persistKey)
        }
    }
}
