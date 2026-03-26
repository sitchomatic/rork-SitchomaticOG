import Foundation

nonisolated struct SessionHealthSnapshot: Codable, Sendable {
    let sessionId: String
    let host: String
    let urlString: String
    let pageLoadTimeMs: Int
    let outcome: String
    let wasTimeout: Bool
    let wasBlankPage: Bool
    let wasCrash: Bool
    let wasChallenge: Bool
    let wasConnectionFailure: Bool
    let fingerprintDetected: Bool
    let circuitBreakerOpen: Bool
    let consecutiveFailuresOnHost: Int
    let activeSessions: Int
    let timestamp: Date
}

nonisolated struct HostHealthProfile: Codable, Sendable {
    var host: String
    var totalSessions: Int = 0
    var successCount: Int = 0
    var timeoutCount: Int = 0
    var blankPageCount: Int = 0
    var crashCount: Int = 0
    var challengeCount: Int = 0
    var connectionFailureCount: Int = 0
    var consecutiveFailures: Int = 0
    var peakConsecutiveFailures: Int = 0
    var totalPageLoadMs: Int = 0
    var recentOutcomes: [String] = []
    var lastSuccessAt: Date?
    var lastFailureAt: Date?
    var aiHealthScore: Double?
    var aiRecommendation: String?
    var lastAIAnalysis: Date?

    var failureRate: Double {
        guard totalSessions > 0 else { return 0 }
        return 1.0 - (Double(successCount) / Double(totalSessions))
    }

    var avgPageLoadMs: Int {
        guard totalSessions > 0 else { return 0 }
        return totalPageLoadMs / totalSessions
    }

    var timeoutRate: Double {
        guard totalSessions > 0 else { return 0 }
        return Double(timeoutCount) / Double(totalSessions)
    }

    var blankPageRate: Double {
        guard totalSessions > 0 else { return 0 }
        return Double(blankPageCount) / Double(totalSessions)
    }

    var crashRate: Double {
        guard totalSessions > 0 else { return 0 }
        return Double(crashCount) / Double(totalSessions)
    }

    var recentFailureStreak: Int {
        var streak = 0
        for outcome in recentOutcomes.reversed() {
            if outcome != "success" && outcome != "noAcc" && outcome != "permDisabled" && outcome != "tempDisabled" {
                streak += 1
            } else {
                break
            }
        }
        return streak
    }

    var healthScore: Double {
        if let ai = aiHealthScore { return ai }

        guard totalSessions >= 3 else { return 0.5 }

        let successScore = (1.0 - failureRate) * 0.30
        let streakPenalty = max(0, 1.0 - Double(consecutiveFailures) * 0.15) * 0.20
        let timeoutPenalty = (1.0 - timeoutRate) * 0.15
        let blankPenalty = (1.0 - blankPageRate) * 0.15
        let crashPenalty = (1.0 - crashRate) * 0.10
        let latencyScore = max(0, 1.0 - (Double(avgPageLoadMs) / 30000.0)) * 0.10

        return successScore + streakPenalty + timeoutPenalty + blankPenalty + crashPenalty + latencyScore
    }
}

nonisolated enum SessionHealthRisk: String, Codable, Sendable {
    case low
    case moderate
    case high
    case critical
}

nonisolated struct SessionHealthPrediction: Sendable {
    let risk: SessionHealthRisk
    let failureProbability: Double
    let recommendation: String
    let shouldAbort: Bool
    let suggestedAction: String
}

nonisolated struct SessionHealthStore: Codable, Sendable {
    var hostProfiles: [String: HostHealthProfile] = [:]
    var recentSnapshots: [SessionHealthSnapshot] = []
    var globalConsecutiveFailures: Int = 0
    var globalSuccessCount: Int = 0
    var globalFailureCount: Int = 0
    var lastGlobalAIAnalysis: Date = .distantPast
}

@MainActor
class AISessionHealthMonitorService {
    static let shared = AISessionHealthMonitorService()

    private let logger = DebugLogger.shared
    private let persistenceKey = "AISessionHealthMonitorData_v1"
    private let maxSnapshots = 1500
    private let maxRecentOutcomes = 30
    private let aiAnalysisThreshold = 40
    private let aiAnalysisCooldownSeconds: TimeInterval = 300
    private var store: SessionHealthStore

    private init() {
        if let saved = UserDefaults.standard.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode(SessionHealthStore.self, from: saved) {
            self.store = decoded
        } else {
            self.store = SessionHealthStore()
        }
    }


    func recordSnapshot(_ snapshot: SessionHealthSnapshot) {
        store.recentSnapshots.append(snapshot)
        if store.recentSnapshots.count > maxSnapshots {
            store.recentSnapshots.removeFirst(store.recentSnapshots.count - maxSnapshots)
        }

        let host = snapshot.host
        var profile = store.hostProfiles[host] ?? HostHealthProfile(host: host)
        profile.totalSessions += 1
        profile.totalPageLoadMs += snapshot.pageLoadTimeMs

        let isSuccess = snapshot.outcome == "success" || snapshot.outcome == "noAcc" || snapshot.outcome == "permDisabled" || snapshot.outcome == "tempDisabled"

        if isSuccess {
            profile.successCount += 1
            profile.consecutiveFailures = 0
            profile.lastSuccessAt = Date()
            store.globalConsecutiveFailures = 0
            store.globalSuccessCount += 1
        } else {
            profile.consecutiveFailures += 1
            profile.peakConsecutiveFailures = max(profile.peakConsecutiveFailures, profile.consecutiveFailures)
            profile.lastFailureAt = Date()
            store.globalConsecutiveFailures += 1
            store.globalFailureCount += 1
        }

        if snapshot.wasTimeout { profile.timeoutCount += 1 }
        if snapshot.wasBlankPage { profile.blankPageCount += 1 }
        if snapshot.wasCrash { profile.crashCount += 1 }
        if snapshot.wasChallenge { profile.challengeCount += 1 }
        if snapshot.wasConnectionFailure { profile.connectionFailureCount += 1 }

        profile.recentOutcomes.append(snapshot.outcome)
        if profile.recentOutcomes.count > maxRecentOutcomes {
            profile.recentOutcomes.removeFirst(profile.recentOutcomes.count - maxRecentOutcomes)
        }

        store.hostProfiles[host] = profile
        save()


        let totalSessions = store.hostProfiles.values.reduce(0) { $0 + $1.totalSessions }
        if totalSessions >= aiAnalysisThreshold &&
           totalSessions % aiAnalysisThreshold == 0 &&
           Date().timeIntervalSince(store.lastGlobalAIAnalysis) > aiAnalysisCooldownSeconds {
            Task {
                await requestAIHealthAnalysis()
            }
        }
    }

    func predictHealth(for host: String, activeSessions: Int) -> SessionHealthPrediction {
        let profile = store.hostProfiles[host]

        guard let profile, profile.totalSessions >= 3 else {
            return SessionHealthPrediction(
                risk: .low,
                failureProbability: 0.2,
                recommendation: "Insufficient data — proceeding normally",
                shouldAbort: false,
                suggestedAction: "proceed"
            )
        }

        var failureProb = profile.failureRate

        if profile.consecutiveFailures >= 3 {
            failureProb += Double(profile.consecutiveFailures) * 0.08
        }

        if profile.timeoutRate > 0.4 {
            failureProb += 0.15
        }

        if profile.blankPageRate > 0.3 {
            failureProb += 0.10
        }

        if store.globalConsecutiveFailures >= 5 {
            failureProb += 0.20
        }

        if activeSessions >= 6 {
            failureProb += Double(activeSessions - 5) * 0.05
        }

        if let lastSuccess = profile.lastSuccessAt {
            let minutesSinceSuccess = Date().timeIntervalSince(lastSuccess) / 60
            if minutesSinceSuccess > 10 {
                failureProb += min(0.15, minutesSinceSuccess * 0.01)
            }
        }

        failureProb = min(0.95, failureProb)

        let risk: SessionHealthRisk
        let recommendation: String
        let shouldAbort: Bool
        let suggestedAction: String

        switch failureProb {
        case 0..<0.3:
            risk = .low
            recommendation = "Host healthy — proceeding normally"
            shouldAbort = false
            suggestedAction = "proceed"
        case 0.3..<0.55:
            risk = .moderate
            recommendation = "Elevated failure risk — consider reducing concurrency"
            shouldAbort = false
            suggestedAction = "reduceConcurrency"
        case 0.55..<0.8:
            risk = .high
            recommendation = "High failure risk — recommend URL rotation or pause"
            shouldAbort = false
            suggestedAction = "rotateURL"
        default:
            risk = .critical
            recommendation = "Critical failure risk — recommend pausing this host"
            shouldAbort = profile.consecutiveFailures >= 8
            suggestedAction = "pause"
        }

        if let aiRec = profile.aiRecommendation {
            return SessionHealthPrediction(
                risk: risk,
                failureProbability: failureProb,
                recommendation: aiRec,
                shouldAbort: shouldAbort,
                suggestedAction: suggestedAction
            )
        }

        return SessionHealthPrediction(
            risk: risk,
            failureProbability: failureProb,
            recommendation: recommendation,
            shouldAbort: shouldAbort,
            suggestedAction: suggestedAction
        )
    }

    func globalHealthScore() -> Double {
        let profiles = store.hostProfiles.values.filter { $0.totalSessions >= 3 }
        guard !profiles.isEmpty else { return 0.5 }
        return profiles.reduce(0.0) { $0 + $1.healthScore } / Double(profiles.count)
    }

    func hostHealthSummary() -> [(host: String, health: Double, sessions: Int, failureRate: Int, streak: Int, risk: SessionHealthRisk)] {
        store.hostProfiles.values.map { profile in
            let prediction = predictHealth(for: profile.host, activeSessions: 0)
            return (
                host: profile.host,
                health: profile.healthScore,
                sessions: profile.totalSessions,
                failureRate: Int(profile.failureRate * 100),
                streak: profile.consecutiveFailures,
                risk: prediction.risk
            )
        }.sorted { $0.health < $1.health }
    }

    func profileFor(host: String) -> HostHealthProfile? {
        store.hostProfiles[host]
    }

    func resetHost(_ host: String) {
        store.hostProfiles.removeValue(forKey: host)
        store.recentSnapshots.removeAll { $0.host == host }
        save()
        logger.log("AISessionHealth: reset data for \(host)", category: .automation, level: .warning)
    }

    func resetAll() {
        store = SessionHealthStore()
        save()
        logger.log("AISessionHealth: all data RESET", category: .automation, level: .warning)
    }

    private func requestAIHealthAnalysis() async {
        let profiles = store.hostProfiles.values.filter { $0.totalSessions >= 5 }
        guard profiles.count >= 1 else { return }

        var summaryData: [[String: Any]] = []
        for p in profiles {
            summaryData.append([
                "host": p.host,
                "totalSessions": p.totalSessions,
                "failureRate": Int(p.failureRate * 100),
                "timeoutRate": Int(p.timeoutRate * 100),
                "blankPageRate": Int(p.blankPageRate * 100),
                "crashRate": Int(p.crashRate * 100),
                "avgPageLoadMs": p.avgPageLoadMs,
                "consecutiveFailures": p.consecutiveFailures,
                "peakConsecutiveFailures": p.peakConsecutiveFailures,
                "recentStreak": p.recentFailureStreak,
                "recentOutcomes": Array(p.recentOutcomes.suffix(10)),
                "currentHealth": String(format: "%.3f", p.healthScore),
            ])
        }

        let globalData: [String: Any] = [
            "globalConsecutiveFailures": store.globalConsecutiveFailures,
            "globalSuccessRate": store.globalSuccessCount + store.globalFailureCount > 0
                ? Int(Double(store.globalSuccessCount) / Double(store.globalSuccessCount + store.globalFailureCount) * 100) : 50,
        ]

        let combined: [String: Any] = [
            "hosts": summaryData,
            "global": globalData,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: combined),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

        let systemPrompt = """
        You analyze session health telemetry for web automation targeting casino login pages. \
        Analyze the host health data and return ONLY a JSON array of objects with health assessments. \
        Format: [{"host":"...","healthScore":0.0-1.0,"recommendation":"...","action":"proceed|reduceConcurrency|rotateURL|pause|resetSession"}]. \
        Consider failure streaks, timeout patterns, blank page frequency, and recent outcome trends. \
        Hosts with degrading patterns should get lower scores and actionable recommendations. \
        Hosts recovering from failures should get encouraging assessments. \
        Return ONLY the JSON array.
        """

        let userPrompt = "Session health data:\n\(jsonStr)"

        logger.log("AISessionHealth: requesting AI analysis for \(profiles.count) hosts", category: .automation, level: .info)

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: userPrompt) else {
            logger.log("AISessionHealth: AI analysis failed — no response", category: .automation, level: .warning)
            return
        }

        applyAIAnalysis(response: response)
        store.lastGlobalAIAnalysis = Date()
        save()
    }

    private func applyAIAnalysis(response: String) {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            logger.log("AISessionHealth: failed to parse AI response", category: .automation, level: .warning)
            return
        }

        var applied = 0
        for entry in json {
            guard let host = entry["host"] as? String,
                  let healthScore = entry["healthScore"] as? Double else { continue }

            guard var profile = store.hostProfiles[host] else { continue }

            profile.aiHealthScore = max(0.01, min(1.0, healthScore))
            profile.aiRecommendation = entry["recommendation"] as? String
            profile.lastAIAnalysis = Date()

            store.hostProfiles[host] = profile
            applied += 1

            logger.log("AISessionHealth: \(host) health → \(String(format: "%.3f", healthScore)) — \(profile.aiRecommendation ?? "no rec")", category: .automation, level: .info)
        }

        logger.log("AISessionHealth: AI analysis applied to \(applied)/\(json.count) hosts", category: .automation, level: .success)
    }


    private func save() {
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: persistenceKey)
        }
    }
}
