import Foundation

nonisolated struct FingerprintOutcome: Codable, Sendable {
    let profileIndex: Int
    let profileSeed: UInt32
    let host: String
    let detected: Bool
    let validationScore: Int
    let signals: [String]
    let loginSuccess: Bool
    let challengeTriggered: Bool
    let timestamp: Date
}

nonisolated struct FingerprintProfileStats: Codable, Sendable {
    var profileIndex: Int
    var profileSeed: UInt32
    var useCount: Int = 0
    var detectionCount: Int = 0
    var loginSuccessCount: Int = 0
    var challengeCount: Int = 0
    var totalValidationScore: Int = 0
    var signalFrequency: [String: Int] = [:]
    var hostDetections: [String: Int] = [:]
    var hostSuccesses: [String: Int] = [:]
    var lastUsed: Date?
    var lastDetected: Date?
    var aiRecommendedWeight: Double?
    var aiCooldownUntil: Date?

    var detectionRate: Double {
        guard useCount > 0 else { return 0 }
        return Double(detectionCount) / Double(useCount)
    }

    var successRate: Double {
        guard useCount > 0 else { return 0.5 }
        return Double(loginSuccessCount) / Double(useCount)
    }

    var avgValidationScore: Double {
        guard useCount > 0 else { return 0 }
        return Double(totalValidationScore) / Double(useCount)
    }

    var isCoolingDown: Bool {
        guard let until = aiCooldownUntil else { return false }
        return Date() < until
    }

    var compositeScore: Double {
        if isCoolingDown { return 0.01 }
        guard useCount >= 2 else { return 0.5 }

        let detectionPenalty = (1.0 - detectionRate) * 0.35
        let successBonus = successRate * 0.30
        let validationPenalty = max(0, 1.0 - (avgValidationScore / 12.0)) * 0.20
        let challengePenalty = useCount > 0 ? (1.0 - Double(challengeCount) / Double(useCount)) * 0.15 : 0.15

        let base = detectionPenalty + successBonus + validationPenalty + challengePenalty

        if let aiWeight = aiRecommendedWeight {
            return base * 0.55 + aiWeight * 0.45
        }
        return base
    }

    var topSignals: [(signal: String, count: Int)] {
        signalFrequency.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
    }

    func detectionRateForHost(_ host: String) -> Double {
        let detections = hostDetections[host] ?? 0
        let successes = hostSuccesses[host] ?? 0
        let total = detections + successes
        guard total > 0 else { return 0 }
        return Double(detections) / Double(total)
    }
}

nonisolated struct HostFingerprintPreference: Codable, Sendable {
    var host: String
    var preferredProfiles: [Int] = []
    var avoidProfiles: [Int] = []
    var detectionSignals: [String: Int] = [:]
    var totalTests: Int = 0
    var lastAIAnalysis: Date?
}

nonisolated struct FingerprintTuningStore: Codable, Sendable {
    var profileStats: [Int: FingerprintProfileStats] = [:]
    var hostPreferences: [String: HostFingerprintPreference] = [:]
    var recentOutcomes: [FingerprintOutcome] = []
    var lastGlobalAIAnalysis: Date = .distantPast
}

@MainActor
class AIFingerprintTuningService {
    static let shared = AIFingerprintTuningService()

    private let logger = DebugLogger.shared
    private let persistenceKey = "AIFingerprintTuningData_v1"
    private let maxOutcomes = 1000
    private let aiAnalysisThreshold = 25
    private let aiAnalysisCooldownSeconds: TimeInterval = 300
    private var store: FingerprintTuningStore


    private init() {
        if let saved = UserDefaults.standard.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode(FingerprintTuningStore.self, from: saved) {
            self.store = decoded
        } else {
            self.store = FingerprintTuningStore()
        }
    }

    func recordOutcome(
        profileIndex: Int,
        profileSeed: UInt32,
        host: String,
        detected: Bool,
        validationScore: Int,
        signals: [String],
        loginSuccess: Bool,
        challengeTriggered: Bool
    ) {
        let outcome = FingerprintOutcome(
            profileIndex: profileIndex,
            profileSeed: profileSeed,
            host: host,
            detected: detected,
            validationScore: validationScore,
            signals: signals,
            loginSuccess: loginSuccess,
            challengeTriggered: challengeTriggered,
            timestamp: Date()
        )

        store.recentOutcomes.append(outcome)
        if store.recentOutcomes.count > maxOutcomes {
            store.recentOutcomes.removeFirst(store.recentOutcomes.count - maxOutcomes)
        }

        var stats = store.profileStats[profileIndex] ?? FingerprintProfileStats(profileIndex: profileIndex, profileSeed: profileSeed)
        stats.useCount += 1
        stats.totalValidationScore += validationScore
        stats.lastUsed = Date()

        if detected {
            stats.detectionCount += 1
            stats.lastDetected = Date()
            stats.hostDetections[host, default: 0] += 1
            for signal in signals {
                stats.signalFrequency[signal, default: 0] += 1
            }
        } else {
            stats.hostSuccesses[host, default: 0] += 1
        }

        if loginSuccess { stats.loginSuccessCount += 1 }
        if challengeTriggered { stats.challengeCount += 1 }

        if stats.detectionRate > 0.7 && stats.useCount >= 5 {
            let cooldownSeconds = min(600.0, Double(stats.detectionCount) * 20.0)
            stats.aiCooldownUntil = Date().addingTimeInterval(cooldownSeconds)
            logger.log("AIFingerprint: profile \(profileIndex) (seed \(profileSeed)) entering cooldown \(Int(cooldownSeconds))s — detection rate \(Int(stats.detectionRate * 100))%", category: .fingerprint, level: .warning)
        }

        store.profileStats[profileIndex] = stats

        var hostPref = store.hostPreferences[host] ?? HostFingerprintPreference(host: host)
        hostPref.totalTests += 1
        if detected {
            for signal in signals {
                hostPref.detectionSignals[signal, default: 0] += 1
            }
            if !hostPref.avoidProfiles.contains(profileIndex) && stats.detectionRateForHost(host) > 0.6 {
                hostPref.avoidProfiles.append(profileIndex)
                hostPref.preferredProfiles.removeAll { $0 == profileIndex }
            }
        } else if loginSuccess {
            if !hostPref.preferredProfiles.contains(profileIndex) {
                hostPref.preferredProfiles.append(profileIndex)
            }
            hostPref.avoidProfiles.removeAll { $0 == profileIndex }
        }
        store.hostPreferences[host] = hostPref

        save()


        let totalSamples = store.profileStats.values.reduce(0) { $0 + $1.useCount }
        if totalSamples >= aiAnalysisThreshold &&
           totalSamples % aiAnalysisThreshold == 0 &&
           Date().timeIntervalSince(store.lastGlobalAIAnalysis) > aiAnalysisCooldownSeconds {
            Task {
                await requestAIOptimization()
            }
        }
    }

    func recommendProfileIndex(for host: String, totalProfiles: Int) -> Int? {
        let hostPref = store.hostPreferences[host]
        let avoidSet = Set(hostPref?.avoidProfiles ?? [])

        let eligible = (0..<totalProfiles).filter { idx in
            !avoidSet.contains(idx) &&
            !(store.profileStats[idx]?.isCoolingDown ?? false)
        }

        guard !eligible.isEmpty else { return nil }

        if let preferred = hostPref?.preferredProfiles.filter({ eligible.contains($0) }),
           !preferred.isEmpty {
            let scored = preferred.map { idx -> (Int, Double) in
                let stats = store.profileStats[idx]
                return (idx, stats?.compositeScore ?? 0.5)
            }
            let totalWeight = scored.reduce(0.0) { $0 + max($1.1, 0.05) }
            var random = Double.random(in: 0..<totalWeight)
            for (idx, weight) in scored {
                random -= max(weight, 0.05)
                if random <= 0 { return idx }
            }
            return preferred.last
        }

        let scored = eligible.map { idx -> (Int, Double) in
            let stats = store.profileStats[idx]
            return (idx, stats?.compositeScore ?? 0.5)
        }

        let totalWeight = scored.reduce(0.0) { $0 + max($1.1, 0.05) }
        var random = Double.random(in: 0..<totalWeight)
        for (idx, weight) in scored {
            random -= max(weight, 0.05)
            if random <= 0 { return idx }
        }
        return eligible.randomElement()
    }

    func allProfileStats() -> [FingerprintProfileStats] {
        Array(store.profileStats.values).sorted { $0.compositeScore > $1.compositeScore }
    }

    func statsFor(profileIndex: Int) -> FingerprintProfileStats? {
        store.profileStats[profileIndex]
    }

    func hostPreference(for host: String) -> HostFingerprintPreference? {
        store.hostPreferences[host]
    }

    func allHostPreferences() -> [HostFingerprintPreference] {
        Array(store.hostPreferences.values).sorted { $0.totalTests > $1.totalTests }
    }

    func topDetectionSignals(limit: Int = 10) -> [(signal: String, count: Int)] {
        var combined: [String: Int] = [:]
        for stats in store.profileStats.values {
            for (signal, count) in stats.signalFrequency {
                combined[signal, default: 0] += count
            }
        }
        return combined.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) }
    }

    func clearCooldown(profileIndex: Int) {
        guard var stats = store.profileStats[profileIndex] else { return }
        stats.aiCooldownUntil = nil
        store.profileStats[profileIndex] = stats
        save()
    }

    func resetProfile(_ profileIndex: Int) {
        store.profileStats.removeValue(forKey: profileIndex)
        for host in store.hostPreferences.keys {
            store.hostPreferences[host]?.preferredProfiles.removeAll { $0 == profileIndex }
            store.hostPreferences[host]?.avoidProfiles.removeAll { $0 == profileIndex }
        }
        save()
    }

    func resetAll() {
        store = FingerprintTuningStore()
        save()
        logger.log("AIFingerprint: all tuning data RESET", category: .fingerprint, level: .warning)
    }

    private func requestAIOptimization() async {
        let profiles = store.profileStats.values.filter { $0.useCount >= 3 }
        guard profiles.count >= 2 else { return }

        var summaryData: [[String: Any]] = []
        for p in profiles {
            summaryData.append([
                "profileIndex": p.profileIndex,
                "seed": p.profileSeed,
                "uses": p.useCount,
                "detectionRate": Int(p.detectionRate * 100),
                "successRate": Int(p.successRate * 100),
                "avgValidationScore": String(format: "%.1f", p.avgValidationScore),
                "challengeRate": p.useCount > 0 ? Int(Double(p.challengeCount) / Double(p.useCount) * 100) : 0,
                "topSignals": p.topSignals.prefix(3).map { "\($0.signal)(\($0.count))" },
                "currentScore": String(format: "%.3f", p.compositeScore),
            ])
        }

        var hostData: [[String: Any]] = []
        for (host, pref) in store.hostPreferences where pref.totalTests >= 3 {
            hostData.append([
                "host": host,
                "tests": pref.totalTests,
                "preferred": pref.preferredProfiles,
                "avoid": pref.avoidProfiles,
                "topSignals": pref.detectionSignals.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key)(\($0.value))" },
            ])
        }

        let summary: [String: Any] = [
            "profiles": summaryData,
            "hosts": hostData,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: summary),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

        let systemPrompt = """
        You optimize browser fingerprint profile selection for web automation targeting casino login pages. \
        Analyze the profile performance data and return ONLY a JSON array of objects with recommended weights and cooldowns. \
        Format: [{"profileIndex":N,"weight":0.0-1.0,"cooldownSeconds":0}]. \
        Higher weight = more likely to be selected. Set cooldownSeconds > 0 for profiles with high detection rates. \
        Prioritize profiles with low detection rates, high login success rates, and low validation scores. \
        Profiles that trigger specific detection signals frequently should be deprioritized or cooled down. \
        Consider per-host preferences — some profiles work better on certain hosts. \
        Return ONLY the JSON array.
        """

        let userPrompt = "Fingerprint profile data:\n\(jsonStr)"

        logger.log("AIFingerprint: requesting AI optimization for \(profiles.count) profiles", category: .fingerprint, level: .info)

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: userPrompt) else {
            logger.log("AIFingerprint: AI optimization failed — no response", category: .fingerprint, level: .warning)
            return
        }

        applyAIOptimization(response: response)
        store.lastGlobalAIAnalysis = Date()
        save()
    }

    private func applyAIOptimization(response: String) {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            logger.log("AIFingerprint: failed to parse AI response", category: .fingerprint, level: .warning)
            return
        }

        var applied = 0
        for entry in json {
            guard let idx = entry["profileIndex"] as? Int,
                  let weight = entry["weight"] as? Double else { continue }

            guard var stats = store.profileStats[idx] else { continue }

            let clampedWeight = max(0.01, min(1.0, weight))
            stats.aiRecommendedWeight = clampedWeight

            if let cooldown = entry["cooldownSeconds"] as? Int, cooldown > 0 {
                stats.aiCooldownUntil = Date().addingTimeInterval(Double(cooldown))
                logger.log("AIFingerprint: AI cooldown \(cooldown)s for profile \(idx)", category: .fingerprint, level: .warning)
            }

            store.profileStats[idx] = stats
            applied += 1

            logger.log("AIFingerprint: profile \(idx) weight → \(String(format: "%.3f", clampedWeight))", category: .fingerprint, level: .info)
        }

        logger.log("AIFingerprint: AI optimization applied to \(applied)/\(json.count) profiles", category: .fingerprint, level: .success)
    }



    private func save() {
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: persistenceKey)
        }
    }
}
