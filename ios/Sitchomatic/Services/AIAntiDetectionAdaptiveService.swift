import Foundation

nonisolated struct DetectionEvent: Codable, Sendable {
    let host: String
    let urlString: String
    let eventType: String
    let signals: [String]
    let fingerprintScore: Int
    let outcome: String
    let profileIndex: Int?
    let proxyType: String
    let timestamp: Date
}

nonisolated struct DetectionPattern: Codable, Sendable {
    var patternId: String
    var signals: [String]
    var occurrenceCount: Int = 0
    var hostOccurrences: [String: Int] = [:]
    var firstSeen: Date
    var lastSeen: Date
    var isNew: Bool { Date().timeIntervalSince(firstSeen) < 3600 }
    var frequency: Double = 0

    var affectedHosts: Int { hostOccurrences.count }
    var primaryHost: String? {
        hostOccurrences.max(by: { $0.value < $1.value })?.key
    }
}

nonisolated struct AdaptiveStrategy: Codable, Sendable {
    var strategyId: String
    var trigger: String
    var action: String
    var parameter: String
    var activatedCount: Int = 0
    var successCount: Int = 0
    var lastActivated: Date?
    var aiGenerated: Bool = false

    var effectivenessRate: Double {
        guard activatedCount > 0 else { return 0.5 }
        return Double(successCount) / Double(activatedCount)
    }
}

nonisolated struct HostDetectionProfile: Codable, Sendable {
    var host: String
    var totalDetections: Int = 0
    var recentDetectionRate: Double = 0
    var topSignals: [String: Int] = [:]
    var activeStrategies: [String] = []
    var detectionTrend: String = "stable"
    var lastAnalysis: Date?
    var aiRecommendations: [String] = []

    var isEscalating: Bool { detectionTrend == "escalating" }
    var isImproving: Bool { detectionTrend == "improving" }
}

nonisolated struct AntiDetectionStore: Codable, Sendable {
    var recentEvents: [DetectionEvent] = []
    var patterns: [String: DetectionPattern] = [:]
    var strategies: [String: AdaptiveStrategy] = [:]
    var hostProfiles: [String: HostDetectionProfile] = [:]
    var globalDetectionRate: Double = 0
    var lastGlobalAIAnalysis: Date = .distantPast
    var adaptiveMode: String = "normal"
}

@MainActor
class AIAntiDetectionAdaptiveService {
    static let shared = AIAntiDetectionAdaptiveService()

    private let logger = DebugLogger.shared
    private let persistenceKey = "AIAntiDetectionAdaptiveData_v1"
    private let maxEvents = 1500
    private let aiAnalysisThreshold = 20
    private let aiAnalysisCooldownSeconds: TimeInterval = 240
    private let escalationThreshold = 0.4
    private var store: AntiDetectionStore

    private init() {
        if let saved = UserDefaults.standard.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode(AntiDetectionStore.self, from: saved) {
            self.store = decoded
        } else {
            self.store = AntiDetectionStore()
        }
    }

    func recordDetectionEvent(
        host: String,
        urlString: String,
        eventType: String,
        signals: [String],
        fingerprintScore: Int,
        outcome: String,
        profileIndex: Int?,
        proxyType: String
    ) {
        let event = DetectionEvent(
            host: host,
            urlString: urlString,
            eventType: eventType,
            signals: signals,
            fingerprintScore: fingerprintScore,
            outcome: outcome,
            profileIndex: profileIndex,
            proxyType: proxyType,
            timestamp: Date()
        )

        store.recentEvents.append(event)
        if store.recentEvents.count > maxEvents {
            store.recentEvents.removeFirst(store.recentEvents.count - maxEvents)
        }

        updatePatterns(event: event)
        updateHostProfile(event: event)
        updateGlobalDetectionRate()

        save()

        let totalEvents = store.recentEvents.count
        if totalEvents >= aiAnalysisThreshold &&
           totalEvents % aiAnalysisThreshold == 0 &&
           Date().timeIntervalSince(store.lastGlobalAIAnalysis) > aiAnalysisCooldownSeconds {
            Task {
                await requestAIAnalysis()
            }
        }

        checkForEscalation(host: host)
    }

    func recommendStrategy(for host: String) -> (action: String, parameter: String, reason: String)? {
        guard let profile = store.hostProfiles[host] else { return nil }

        if let aiRec = profile.aiRecommendations.first {
            return (action: "aiRecommended", parameter: aiRec, reason: "AI recommendation for \(host)")
        }

        if profile.isEscalating && profile.totalDetections >= 5 {
            let topSignal = profile.topSignals.max(by: { $0.value < $1.value })?.key ?? "unknown"

            if topSignal.contains("webdriver") || topSignal.contains("automation") {
                return (action: "rotateFingerprint", parameter: "high", reason: "Escalating webdriver/automation detection on \(host)")
            }
            if topSignal.contains("canvas") || topSignal.contains("WebGL") {
                return (action: "rotateFingerprint", parameter: "medium", reason: "Canvas/WebGL inconsistency detected on \(host)")
            }
            if topSignal.contains("timing") || topSignal.contains("velocity") {
                return (action: "slowDown", parameter: "50", reason: "Timing/velocity detection on \(host)")
            }
            if topSignal.contains("rate") || topSignal.contains("429") {
                return (action: "cooldown", parameter: "60", reason: "Rate limiting detected on \(host)")
            }

            return (action: "fullRotation", parameter: "all", reason: "Escalating detection pattern on \(host) — top signal: \(topSignal)")
        }

        if profile.recentDetectionRate > 0.6 {
            return (action: "pause", parameter: "30", reason: "High detection rate (\(Int(profile.recentDetectionRate * 100))%) on \(host)")
        }

        return nil
    }

    func currentAdaptiveMode() -> String {
        store.adaptiveMode
    }

    func globalDetectionRate() -> Double {
        store.globalDetectionRate
    }

    func hostProfile(for host: String) -> HostDetectionProfile? {
        store.hostProfiles[host]
    }

    func allHostProfiles() -> [HostDetectionProfile] {
        Array(store.hostProfiles.values).sorted { $0.totalDetections > $1.totalDetections }
    }

    func activePatterns() -> [DetectionPattern] {
        store.patterns.values
            .filter { $0.occurrenceCount >= 3 }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    func newPatterns(withinHours: Double = 1) -> [DetectionPattern] {
        let cutoff = Date().addingTimeInterval(-withinHours * 3600)
        return store.patterns.values
            .filter { $0.firstSeen > cutoff }
            .sorted { $0.occurrenceCount > $1.occurrenceCount }
    }

    func recordStrategyOutcome(strategyId: String, success: Bool) {
        guard var strategy = store.strategies[strategyId] else { return }
        strategy.activatedCount += 1
        if success { strategy.successCount += 1 }
        strategy.lastActivated = Date()
        store.strategies[strategyId] = strategy
        save()
    }

    func resetHost(_ host: String) {
        store.hostProfiles.removeValue(forKey: host)
        store.recentEvents.removeAll { $0.host == host }
        save()
        logger.log("AIAntiDetection: reset data for \(host)", category: .automation, level: .warning)
    }

    func resetAll() {
        store = AntiDetectionStore()
        save()
        logger.log("AIAntiDetection: all data RESET", category: .automation, level: .warning)
    }

    private func updatePatterns(event: DetectionEvent) {
        guard !event.signals.isEmpty else { return }

        let patternKey = event.signals.sorted().joined(separator: "|")
        var pattern = store.patterns[patternKey] ?? DetectionPattern(
            patternId: patternKey,
            signals: event.signals,
            firstSeen: Date(),
            lastSeen: Date()
        )

        pattern.occurrenceCount += 1
        pattern.lastSeen = Date()
        pattern.hostOccurrences[event.host, default: 0] += 1

        let windowEvents = store.recentEvents.suffix(100)
        let matchCount = windowEvents.filter { $0.signals.sorted().joined(separator: "|") == patternKey }.count
        pattern.frequency = Double(matchCount) / Double(max(1, windowEvents.count))

        store.patterns[patternKey] = pattern

        if pattern.isNew && pattern.occurrenceCount >= 3 {
            logger.log("AIAntiDetection: NEW PATTERN detected — \(event.signals.joined(separator: ", ")) (seen \(pattern.occurrenceCount)x across \(pattern.affectedHosts) hosts)", category: .automation, level: .warning)
        }
    }

    private func updateHostProfile(event: DetectionEvent) {
        let host = event.host
        var profile = store.hostProfiles[host] ?? HostDetectionProfile(host: host)

        let isDetection = event.eventType == "detection" || event.fingerprintScore > 12 || event.eventType == "challenge"
        if isDetection {
            profile.totalDetections += 1
        }

        for signal in event.signals {
            profile.topSignals[signal, default: 0] += 1
        }

        let hostEvents = store.recentEvents.filter { $0.host == host }.suffix(20)
        let detectionCount = hostEvents.filter {
            $0.eventType == "detection" || $0.fingerprintScore > 12 || $0.eventType == "challenge"
        }.count
        let previousRate = profile.recentDetectionRate
        profile.recentDetectionRate = hostEvents.isEmpty ? 0 : Double(detectionCount) / Double(hostEvents.count)

        if profile.recentDetectionRate > previousRate + 0.15 && profile.totalDetections >= 5 {
            profile.detectionTrend = "escalating"
        } else if profile.recentDetectionRate < previousRate - 0.15 {
            profile.detectionTrend = "improving"
        } else {
            profile.detectionTrend = "stable"
        }

        store.hostProfiles[host] = profile
    }

    private func updateGlobalDetectionRate() {
        let recentEvents = store.recentEvents.suffix(100)
        guard !recentEvents.isEmpty else { return }
        let detections = recentEvents.filter {
            $0.eventType == "detection" || $0.fingerprintScore > 12 || $0.eventType == "challenge"
        }.count
        store.globalDetectionRate = Double(detections) / Double(recentEvents.count)

        if store.globalDetectionRate > 0.6 {
            store.adaptiveMode = "defensive"
        } else if store.globalDetectionRate > 0.3 {
            store.adaptiveMode = "cautious"
        } else {
            store.adaptiveMode = "normal"
        }
    }

    private func checkForEscalation(host: String) {
        guard let profile = store.hostProfiles[host], profile.isEscalating else { return }

        if let rec = recommendStrategy(for: host) {
            logger.log("AIAntiDetection: ESCALATION on \(host) — recommending \(rec.action): \(rec.reason)", category: .automation, level: .critical)
        }
    }

    private func requestAIAnalysis() async {
        let profiles = store.hostProfiles.values.filter { $0.totalDetections >= 3 }
        guard !profiles.isEmpty else { return }

        var hostData: [[String: Any]] = []
        for p in profiles.sorted(by: { $0.totalDetections > $1.totalDetections }).prefix(15) {
            hostData.append([
                "host": p.host,
                "totalDetections": p.totalDetections,
                "detectionRate": Int(p.recentDetectionRate * 100),
                "trend": p.detectionTrend,
                "topSignals": p.topSignals.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key)(\($0.value))" },
                "activeStrategies": p.activeStrategies,
            ])
        }

        let newPatterns = self.newPatterns(withinHours: 2).prefix(10)
        var patternData: [[String: Any]] = []
        for p in newPatterns {
            patternData.append([
                "signals": p.signals,
                "occurrences": p.occurrenceCount,
                "hosts": p.affectedHosts,
                "frequency": String(format: "%.2f", p.frequency),
            ])
        }

        let combined: [String: Any] = [
            "hosts": hostData,
            "newPatterns": patternData,
            "globalDetectionRate": Int(store.globalDetectionRate * 100),
            "adaptiveMode": store.adaptiveMode,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: combined),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

        let systemPrompt = """
        You analyze anti-bot detection patterns for web automation targeting casino login pages. \
        Based on the detection data, return ONLY a JSON object with adaptive recommendations. \
        Format: {"mode":"normal|cautious|defensive","hostActions":[{"host":"...","action":"rotateFingerprint|slowDown|cooldown|rotateProxy|fullRotation|pause","parameter":"...","reason":"..."}],"globalRecommendations":["..."]}.  \
        Consider escalating hosts need immediate action. New patterns indicate evolving anti-bot measures. \
        High global detection rates mean the overall approach needs adjustment. \
        Be specific about which signals to address and what parameters to adjust. \
        Return ONLY the JSON object.
        """

        let userPrompt = "Anti-detection telemetry:\n\(jsonStr)"

        logger.log("AIAntiDetection: requesting AI analysis for \(profiles.count) hosts, \(newPatterns.count) new patterns", category: .automation, level: .info)

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: userPrompt) else {
            logger.log("AIAntiDetection: AI analysis failed — no response", category: .automation, level: .warning)
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.log("AIAntiDetection: failed to parse AI response", category: .automation, level: .warning)
            return
        }

        if let mode = json["mode"] as? String {
            store.adaptiveMode = mode
            logger.log("AIAntiDetection: AI adaptive mode → \(mode)", category: .automation, level: .info)
        }

        if let hostActions = json["hostActions"] as? [[String: Any]] {
            for entry in hostActions {
                guard let host = entry["host"] as? String,
                      let action = entry["action"] as? String else { continue }

                let param = entry["parameter"] as? String ?? ""
                let reason = entry["reason"] as? String ?? "AI recommendation"

                let strategyId = "\(host)_\(action)_\(Int(Date().timeIntervalSince1970))"
                let strategy = AdaptiveStrategy(
                    strategyId: strategyId,
                    trigger: "ai_analysis",
                    action: action,
                    parameter: param,
                    aiGenerated: true
                )
                store.strategies[strategyId] = strategy

                if var profile = store.hostProfiles[host] {
                    profile.aiRecommendations = ["\(action):\(param)"]
                    profile.activeStrategies.append(strategyId)
                    if profile.activeStrategies.count > 5 {
                        profile.activeStrategies.removeFirst(profile.activeStrategies.count - 5)
                    }
                    profile.lastAnalysis = Date()
                    store.hostProfiles[host] = profile
                }

                logger.log("AIAntiDetection: AI strategy for \(host) → \(action)(\(param)) — \(reason)", category: .automation, level: .info)
            }
        }

        if let globalRecs = json["globalRecommendations"] as? [String] {
            for rec in globalRecs {
                logger.log("AIAntiDetection: AI global rec → \(rec)", category: .automation, level: .info)
            }
        }

        logger.log("AIAntiDetection: AI analysis applied successfully", category: .automation, level: .success)
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: persistenceKey)
        }
    }
}
