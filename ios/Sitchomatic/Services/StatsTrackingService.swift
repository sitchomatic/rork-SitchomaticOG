import Foundation

@MainActor
class StatsTrackingService {
    static let shared = StatsTrackingService()

    private let storageKey = "lifetime_stats_v1"

    private(set) var lifetimeTested: Int = 0
    private(set) var lifetimeWorking: Int = 0
    private(set) var lifetimeDead: Int = 0
    private(set) var lifetimeRequeued: Int = 0
    private(set) var totalBatches: Int = 0
    private(set) var totalTestDuration: TimeInterval = 0
    private(set) var dailyCounts: [String: Int] = [:]

    init() {
        loadStats()
    }

    func recordBatchResult(working: Int, dead: Int, requeued: Int, duration: TimeInterval) {
        lifetimeWorking += working
        lifetimeDead += dead
        lifetimeRequeued += requeued
        lifetimeTested += working + dead + requeued
        totalBatches += 1
        totalTestDuration += duration

        let dayKey = Self.dayKey(for: Date())
        dailyCounts[dayKey, default: 0] += working + dead + requeued

        pruneOldDailyCounts()
        saveStats()
    }

    func recordSingleTest(working: Bool, duration: TimeInterval) {
        lifetimeTested += 1
        if working { lifetimeWorking += 1 } else { lifetimeDead += 1 }
        totalTestDuration += duration

        let dayKey = Self.dayKey(for: Date())
        dailyCounts[dayKey, default: 0] += 1

        saveStats()
    }

    var lifetimeSuccessRate: Double {
        guard lifetimeTested > 0 else { return 0 }
        return Double(lifetimeWorking) / Double(lifetimeTested)
    }

    var averageTestDuration: TimeInterval {
        guard lifetimeTested > 0 else { return 0 }
        return totalTestDuration / Double(lifetimeTested)
    }

    var testsToday: Int {
        dailyCounts[Self.dayKey(for: Date())] ?? 0
    }

    var averageTestsPerDay: Double {
        guard !dailyCounts.isEmpty else { return 0 }
        let total = dailyCounts.values.reduce(0, +)
        return Double(total) / Double(dailyCounts.count)
    }

    var last7DaysCounts: [(day: String, count: Int)] {
        let cal = Calendar.current
        return (0..<7).reversed().map { offset in
            let date = cal.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let key = Self.dayKey(for: date)
            let shortDay = Self.shortDayFormatter.string(from: date)
            return (day: shortDay, count: dailyCounts[key] ?? 0)
        }
    }

    func resetStats() {
        lifetimeTested = 0
        lifetimeWorking = 0
        lifetimeDead = 0
        lifetimeRequeued = 0
        totalBatches = 0
        totalTestDuration = 0
        dailyCounts.removeAll()
        saveStats()
    }

    private func pruneOldDailyCounts() {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let cutoffKey = Self.dayKey(for: cutoff)
        dailyCounts = dailyCounts.filter { $0.key >= cutoffKey }
    }

    private static func dayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    private func saveStats() {
        let dict: [String: Any] = [
            "lifetimeTested": lifetimeTested,
            "lifetimeWorking": lifetimeWorking,
            "lifetimeDead": lifetimeDead,
            "lifetimeRequeued": lifetimeRequeued,
            "totalBatches": totalBatches,
            "totalTestDuration": totalTestDuration,
            "dailyCounts": dailyCounts,
        ]
        UserDefaults.standard.set(dict, forKey: storageKey)
    }

    private func loadStats() {
        guard let dict = UserDefaults.standard.dictionary(forKey: storageKey) else { return }
        lifetimeTested = dict["lifetimeTested"] as? Int ?? 0
        lifetimeWorking = dict["lifetimeWorking"] as? Int ?? 0
        lifetimeDead = dict["lifetimeDead"] as? Int ?? 0
        lifetimeRequeued = dict["lifetimeRequeued"] as? Int ?? 0
        totalBatches = dict["totalBatches"] as? Int ?? 0
        totalTestDuration = dict["totalTestDuration"] as? TimeInterval ?? 0
        dailyCounts = dict["dailyCounts"] as? [String: Int] ?? [:]
    }
}
