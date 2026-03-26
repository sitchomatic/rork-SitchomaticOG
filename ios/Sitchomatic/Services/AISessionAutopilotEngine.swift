import Foundation
import WebKit
import UIKit

nonisolated enum AutopilotMode: String, Codable, Sendable {
    case off
    case passive
    case active
    case aggressive
}

nonisolated enum AutopilotSignalType: String, Codable, Sendable {
    case pageLoadStarted
    case pageLoadComplete
    case domMutation
    case networkRequestFired
    case networkResponseReceived
    case challengeFormingDetected
    case fingerprintProbeDetected
    case typingVelocityAnomaly
    case rateLimitSignal
    case blankPageDetected
    case redirectDetected
    case jsErrorDetected
    case connectionDegraded
    case proxyLatencySpike
    case cookieBombDetected
    case canvasProbeDetected
    case webDriverProbeDetected
    case timingAnomalyDetected
    case httpStatusAnomaly
    case captchaFormingDetected
    case sessionHealthDegraded
}

nonisolated enum AutopilotAction: String, Codable, Sendable {
    case noOp
    case preemptiveProxySwitch
    case preemptiveIPRotation
    case adjustTypingSpeed
    case injectCounterFingerprint
    case pauseAndWait
    case throttleRequests
    case rotateDNS
    case rotateFingerprint
    case rotateURL
    case fullSessionReset
    case abortSession
    case switchInteractionPattern
    case injectDecoyTraffic
    case adjustViewport
    case slowDownInteraction
    case speedUpInteraction
    case preemptiveCookieClear
    case escalateToAI
}

nonisolated enum AutopilotPriority: Int, Codable, Sendable, Comparable {
    case low = 0
    case medium = 1
    case high = 2
    case critical = 3
    case emergency = 4

    nonisolated static func < (lhs: AutopilotPriority, rhs: AutopilotPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

nonisolated struct AutopilotSignal: Sendable {
    let type: AutopilotSignalType
    let sessionId: String
    let host: String
    let timestamp: Date
    let confidence: Double
    let metadata: [String: String]
    let rawData: String?
}

nonisolated struct AutopilotDecision: Sendable {
    let action: AutopilotAction
    let priority: AutopilotPriority
    let confidence: Double
    let reasoning: String
    let triggerSignal: AutopilotSignalType
    let parameters: [String: String]
    let timestamp: Date
    let sessionId: String
    let latencyMs: Int
}

nonisolated struct AutopilotSessionState: Sendable {
    let sessionId: String
    var host: String
    var signalHistory: [AutopilotSignal] = []
    var decisionHistory: [AutopilotDecision] = []
    var activeReflexes: [String] = []
    var threatLevel: Double = 0
    var proxyRotationCount: Int = 0
    var fingerprintRotationCount: Int = 0
    var patternSwitchCount: Int = 0
    var totalInterventions: Int = 0
    var startTime: Date = Date()
    var lastSignalTime: Date?
    var lastDecisionTime: Date?
    var isActive: Bool = true

    var sessionDurationMs: Int {
        Int(Date().timeIntervalSince(startTime) * 1000)
    }

    var signalsPerSecond: Double {
        let elapsed = max(1.0, Date().timeIntervalSince(startTime))
        return Double(signalHistory.count) / elapsed
    }

    var interventionRate: Double {
        guard !decisionHistory.isEmpty else { return 0 }
        return Double(decisionHistory.filter { $0.action != .noOp }.count) / Double(decisionHistory.count)
    }

    mutating func recordSignal(_ signal: AutopilotSignal) {
        signalHistory.append(signal)
        lastSignalTime = signal.timestamp
        if signalHistory.count > 200 {
            signalHistory.removeFirst(signalHistory.count - 200)
        }
    }

    mutating func recordDecision(_ decision: AutopilotDecision) {
        decisionHistory.append(decision)
        lastDecisionTime = decision.timestamp
        if decision.action != .noOp {
            totalInterventions += 1
        }
        if decision.action == .preemptiveProxySwitch || decision.action == .preemptiveIPRotation {
            proxyRotationCount += 1
        }
        if decision.action == .rotateFingerprint || decision.action == .injectCounterFingerprint {
            fingerprintRotationCount += 1
        }
        if decision.action == .switchInteractionPattern {
            patternSwitchCount += 1
        }
        if decisionHistory.count > 100 {
            decisionHistory.removeFirst(decisionHistory.count - 100)
        }
    }
}

nonisolated struct AutopilotGlobalStats: Codable, Sendable {
    var totalSessionsMonitored: Int = 0
    var totalSignalsProcessed: Int = 0
    var totalDecisionsMade: Int = 0
    var totalInterventions: Int = 0
    var totalPreemptiveActions: Int = 0
    var successfulInterventions: Int = 0
    var failedInterventions: Int = 0
    var avgDecisionLatencyMs: Double = 0
    var signalTypeFrequency: [String: Int] = [:]
    var actionTypeFrequency: [String: Int] = [:]
    var threatLevelHistory: [Double] = []
    var lastAIAnalysis: Date = .distantPast
}

@MainActor
class AISessionAutopilotEngine {
    static let shared = AISessionAutopilotEngine()

    private let logger = DebugLogger.shared
    private let sessionHealth = AISessionHealthMonitorService.shared
    private let antiDetection = AIAntiDetectionAdaptiveService.shared
    private let challengeSolver = AIChallengePageSolverService.shared
    private let timingOptimizer = AITimingOptimizerService.shared
    private let fingerprintTuning = AIFingerprintTuningService.shared
    private let persistenceKey = "AISessionAutopilotStats_v1"

    private(set) var mode: AutopilotMode = .active
    private(set) var activeSessions: [String: AutopilotSessionState] = [:]
    private(set) var globalStats: AutopilotGlobalStats
    private let signalProcessor = AutopilotSignalProcessor()
    private let decisionGraph = AutopilotDecisionGraph()
    let reflexSystem = AutopilotReflexSystem()
    private var aiAnalysisCooldown: Date = .distantPast
    private let aiAnalysisInterval: TimeInterval = 180

    var isEnabled: Bool { mode != .off }
    var activeSessionCount: Int { activeSessions.count }

    var globalThreatLevel: Double {
        guard !activeSessions.isEmpty else { return 0 }
        return activeSessions.values.reduce(0.0) { $0 + $1.threatLevel } / Double(activeSessions.count)
    }

    private init() {
        if let saved = UserDefaults.standard.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode(AutopilotGlobalStats.self, from: saved) {
            self.globalStats = decoded
        } else {
            self.globalStats = AutopilotGlobalStats()
        }
    }

    func setMode(_ newMode: AutopilotMode) {
        let oldMode = mode
        mode = newMode
        logger.log("Autopilot: mode changed \(oldMode.rawValue) -> \(newMode.rawValue)", category: .automation, level: .info)
    }

    func startSession(id: String, host: String) {
        guard isEnabled else { return }
        var state = AutopilotSessionState(sessionId: id, host: host)
        state.isActive = true
        activeSessions[id] = state
        globalStats.totalSessionsMonitored += 1
        reflexSystem.armReflexes(for: id, host: host, mode: mode)
        logger.log("Autopilot: session STARTED \(id) on \(host) [mode=\(mode.rawValue)]", category: .automation, level: .info)
    }

    func endSession(id: String) {
        guard var state = activeSessions[id] else { return }
        state.isActive = false
        let duration = state.sessionDurationMs
        let interventions = state.totalInterventions
        let signals = state.signalHistory.count
        reflexSystem.disarmReflexes(for: id)
        activeSessions.removeValue(forKey: id)
        logger.log("Autopilot: session ENDED \(id) — \(duration)ms, \(signals) signals, \(interventions) interventions", category: .automation, level: .info)
        save()
    }

    @discardableResult
    func ingestSignal(_ signal: AutopilotSignal) -> AutopilotDecision {
        guard isEnabled, var state = activeSessions[signal.sessionId] else {
            return AutopilotDecision(
                action: .noOp, priority: .low, confidence: 0, reasoning: "Session not tracked",
                triggerSignal: signal.type, parameters: [:], timestamp: Date(),
                sessionId: signal.sessionId, latencyMs: 0
            )
        }

        let decisionStart = Date()
        state.recordSignal(signal)
        globalStats.totalSignalsProcessed += 1
        globalStats.signalTypeFrequency[signal.type.rawValue, default: 0] += 1

        let classification = signalProcessor.classify(signal: signal, sessionState: state, mode: mode)
        state.threatLevel = signalProcessor.computeThreatLevel(for: state)

        let reflexDecision = reflexSystem.checkReflexTrigger(signal: signal, sessionState: state, mode: mode)
        if let reflex = reflexDecision, reflex.priority >= .high {
            let latency = Int(Date().timeIntervalSince(decisionStart) * 1000)
            let finalDecision = AutopilotDecision(
                action: reflex.action, priority: reflex.priority, confidence: reflex.confidence,
                reasoning: "[REFLEX] \(reflex.reasoning)", triggerSignal: signal.type,
                parameters: reflex.parameters, timestamp: Date(),
                sessionId: signal.sessionId, latencyMs: latency
            )
            state.recordDecision(finalDecision)
            activeSessions[signal.sessionId] = state
            globalStats.totalDecisionsMade += 1
            globalStats.totalInterventions += 1
            globalStats.totalPreemptiveActions += 1
            globalStats.actionTypeFrequency[finalDecision.action.rawValue, default: 0] += 1
            logger.log("Autopilot: REFLEX \(finalDecision.action.rawValue) on \(signal.sessionId) — \(finalDecision.reasoning) [\(latency)ms]", category: .automation, level: .warning)
            return finalDecision
        }

        let graphDecision = decisionGraph.evaluate(
            signal: signal,
            classification: classification,
            sessionState: state,
            mode: mode,
            globalThreatLevel: globalThreatLevel
        )

        let latency = Int(Date().timeIntervalSince(decisionStart) * 1000)
        let finalDecision = AutopilotDecision(
            action: graphDecision.action, priority: graphDecision.priority,
            confidence: graphDecision.confidence, reasoning: graphDecision.reasoning,
            triggerSignal: signal.type, parameters: graphDecision.parameters,
            timestamp: Date(), sessionId: signal.sessionId, latencyMs: latency
        )

        state.recordDecision(finalDecision)
        activeSessions[signal.sessionId] = state
        globalStats.totalDecisionsMade += 1
        if finalDecision.action != .noOp {
            globalStats.totalInterventions += 1
            globalStats.actionTypeFrequency[finalDecision.action.rawValue, default: 0] += 1
        }

        updateDecisionLatencyAverage(latency)

        if finalDecision.action != .noOp {
            logger.log("Autopilot: \(finalDecision.action.rawValue) on \(signal.sessionId) [p=\(finalDecision.priority.rawValue) c=\(String(format: "%.0f%%", finalDecision.confidence * 100))] — \(finalDecision.reasoning) [\(latency)ms]", category: .automation, level: finalDecision.priority >= .high ? .warning : .info)
        }

        if shouldRequestAIAnalysis() {
            Task { await requestAIStrategicAnalysis() }
        }

        return finalDecision
    }

    func ingestPageLoadEvent(sessionId: String, host: String, url: String, httpStatus: Int, loadTimeMs: Int) {
        guard isEnabled else { return }
        var metadata: [String: String] = ["url": url, "httpStatus": "\(httpStatus)", "loadTimeMs": "\(loadTimeMs)"]
        let signalType: AutopilotSignalType
        var confidence = 0.5

        if httpStatus == 429 || httpStatus == 503 {
            signalType = .rateLimitSignal
            confidence = 0.9
            metadata["reason"] = "HTTP \(httpStatus)"
        } else if httpStatus >= 400 {
            signalType = .httpStatusAnomaly
            confidence = 0.7
        } else if loadTimeMs > 15000 {
            signalType = .connectionDegraded
            confidence = 0.6
            metadata["reason"] = "Slow load \(loadTimeMs)ms"
        } else {
            signalType = .pageLoadComplete
            confidence = 0.3
        }

        let signal = AutopilotSignal(
            type: signalType, sessionId: sessionId, host: host,
            timestamp: Date(), confidence: confidence, metadata: metadata, rawData: nil
        )
        ingestSignal(signal)
    }

    func ingestDOMMutation(sessionId: String, host: String, mutationType: String, elementInfo: String) {
        guard isEnabled else { return }
        let signalType: AutopilotSignalType
        var confidence = 0.4
        var metadata: [String: String] = ["mutationType": mutationType, "element": elementInfo]

        let lower = elementInfo.lowercased()
        if lower.contains("captcha") || lower.contains("recaptcha") || lower.contains("hcaptcha") || lower.contains("turnstile") {
            signalType = .captchaFormingDetected
            confidence = 0.85
            metadata["captchaType"] = "detected_in_dom"
        } else if lower.contains("challenge") || lower.contains("verify") || lower.contains("cf-") || lower.contains("__cf_") {
            signalType = .challengeFormingDetected
            confidence = 0.7
        } else if lower.contains("canvas") && lower.contains("toDataURL") {
            signalType = .canvasProbeDetected
            confidence = 0.75
        } else if lower.contains("webdriver") || lower.contains("__selenium") || lower.contains("_phantom") || lower.contains("callPhantom") {
            signalType = .webDriverProbeDetected
            confidence = 0.9
        } else {
            signalType = .domMutation
            confidence = 0.2
        }

        let signal = AutopilotSignal(
            type: signalType, sessionId: sessionId, host: host,
            timestamp: Date(), confidence: confidence, metadata: metadata, rawData: nil
        )
        ingestSignal(signal)
    }

    func ingestNetworkEvent(sessionId: String, host: String, url: String, method: String, statusCode: Int?, latencyMs: Int?) {
        guard isEnabled else { return }
        let lower = url.lowercased()
        var signalType: AutopilotSignalType = .networkResponseReceived
        var confidence = 0.3
        var metadata: [String: String] = ["requestURL": String(url.prefix(200)), "method": method]
        if let sc = statusCode { metadata["statusCode"] = "\(sc)" }
        if let lat = latencyMs { metadata["latencyMs"] = "\(lat)" }

        if lower.contains("fingerprint") || lower.contains("fp.js") || lower.contains("botd") || lower.contains("incapsula") {
            signalType = .fingerprintProbeDetected
            confidence = 0.8
        } else if lower.contains("captcha") || lower.contains("recaptcha") || lower.contains("hcaptcha") {
            signalType = .captchaFormingDetected
            confidence = 0.75
        } else if statusCode == 429 || statusCode == 503 {
            signalType = .rateLimitSignal
            confidence = 0.85
        } else if let lat = latencyMs, lat > 10000 {
            signalType = .proxyLatencySpike
            confidence = 0.6
        }

        let signal = AutopilotSignal(
            type: signalType, sessionId: sessionId, host: host,
            timestamp: Date(), confidence: confidence, metadata: metadata, rawData: nil
        )
        ingestSignal(signal)
    }

    func ingestJSEvent(sessionId: String, host: String, eventType: String, detail: String) {
        guard isEnabled else { return }
        let lower = detail.lowercased()
        var signalType: AutopilotSignalType = .jsErrorDetected
        var confidence = 0.4

        if lower.contains("navigator.webdriver") || lower.contains("automation") {
            signalType = .webDriverProbeDetected
            confidence = 0.9
        } else if lower.contains("canvas") || lower.contains("toDataURL") || lower.contains("getImageData") {
            signalType = .canvasProbeDetected
            confidence = 0.7
        } else if lower.contains("fingerprint") || lower.contains("fp2") {
            signalType = .fingerprintProbeDetected
            confidence = 0.8
        } else if eventType == "timing_anomaly" {
            signalType = .timingAnomalyDetected
            confidence = 0.65
        } else if eventType == "typing_velocity" {
            signalType = .typingVelocityAnomaly
            confidence = 0.7
        }

        let signal = AutopilotSignal(
            type: signalType, sessionId: sessionId, host: host,
            timestamp: Date(), confidence: confidence,
            metadata: ["eventType": eventType, "detail": String(detail.prefix(500))],
            rawData: nil
        )
        ingestSignal(signal)
    }

    func ingestBlankPageDetected(sessionId: String, host: String) {
        guard isEnabled else { return }
        let signal = AutopilotSignal(
            type: .blankPageDetected, sessionId: sessionId, host: host,
            timestamp: Date(), confidence: 0.9,
            metadata: ["source": "blankScreenDetector"], rawData: nil
        )
        ingestSignal(signal)
    }

    func ingestRedirectDetected(sessionId: String, host: String, fromURL: String, toURL: String) {
        guard isEnabled else { return }
        let signal = AutopilotSignal(
            type: .redirectDetected, sessionId: sessionId, host: host,
            timestamp: Date(), confidence: 0.6,
            metadata: ["fromURL": String(fromURL.prefix(200)), "toURL": String(toURL.prefix(200))],
            rawData: nil
        )
        ingestSignal(signal)
    }

    func recordInterventionOutcome(sessionId: String, action: AutopilotAction, success: Bool) {
        if success {
            globalStats.successfulInterventions += 1
        } else {
            globalStats.failedInterventions += 1
        }
        reflexSystem.recordOutcome(action: action, success: success)
        save()
    }

    func sessionState(for id: String) -> AutopilotSessionState? {
        activeSessions[id]
    }

    func allActiveSessions() -> [AutopilotSessionState] {
        Array(activeSessions.values).sorted { $0.threatLevel > $1.threatLevel }
    }

    func topThreats(limit: Int = 5) -> [(sessionId: String, threat: Double, lastSignal: AutopilotSignalType?)] {
        activeSessions.values
            .sorted { $0.threatLevel > $1.threatLevel }
            .prefix(limit)
            .map { (sessionId: $0.sessionId, threat: $0.threatLevel, lastSignal: $0.signalHistory.last?.type) }
    }

    func resetStats() {
        globalStats = AutopilotGlobalStats()
        save()
        logger.log("Autopilot: global stats RESET", category: .automation, level: .warning)
    }

    private func shouldRequestAIAnalysis() -> Bool {
        guard globalStats.totalSignalsProcessed > 50 else { return false }
        guard Date().timeIntervalSince(aiAnalysisCooldown) > aiAnalysisInterval else { return false }
        guard globalThreatLevel > 0.4 || globalStats.totalSignalsProcessed % 200 == 0 else { return false }
        return true
    }

    private func requestAIStrategicAnalysis() async {
        aiAnalysisCooldown = Date()
        let sessionSummaries: [[String: Any]] = activeSessions.values.prefix(10).map { state in
            [
                "sessionId": state.sessionId,
                "host": state.host,
                "threatLevel": String(format: "%.2f", state.threatLevel),
                "totalSignals": state.signalHistory.count,
                "interventions": state.totalInterventions,
                "proxyRotations": state.proxyRotationCount,
                "fpRotations": state.fingerprintRotationCount,
                "durationMs": state.sessionDurationMs,
                "signalsPerSec": String(format: "%.2f", state.signalsPerSecond),
                "recentSignals": state.signalHistory.suffix(5).map { $0.type.rawValue },
                "recentActions": state.decisionHistory.suffix(5).map { $0.action.rawValue },
            ]
        }

        let globalData: [String: Any] = [
            "totalSessions": globalStats.totalSessionsMonitored,
            "totalSignals": globalStats.totalSignalsProcessed,
            "totalInterventions": globalStats.totalInterventions,
            "preemptiveActions": globalStats.totalPreemptiveActions,
            "successfulInterventions": globalStats.successfulInterventions,
            "failedInterventions": globalStats.failedInterventions,
            "avgDecisionLatencyMs": Int(globalStats.avgDecisionLatencyMs),
            "globalThreatLevel": String(format: "%.2f", globalThreatLevel),
            "topSignalTypes": Dictionary(globalStats.signalTypeFrequency.sorted { $0.value > $1.value }.prefix(8).map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a }),
            "topActions": Dictionary(globalStats.actionTypeFrequency.sorted { $0.value > $1.value }.prefix(8).map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a }),
        ]

        let combined: [String: Any] = [
            "sessions": sessionSummaries,
            "global": globalData,
            "mode": mode.rawValue,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: combined),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

        let systemPrompt = """
        You are the strategic AI brain of a real-time session autopilot for web automation. \
        Analyze live session telemetry and recommend strategic adjustments. \
        Return ONLY a JSON object: {"globalMode":"passive|active|aggressive","sessionActions":[{"sessionId":"...","action":"...","parameter":"...","reason":"..."}],"reflexTuning":[{"signalType":"...","newThreshold":0.0-1.0,"newAction":"..."}],"strategicInsights":["..."]}. \
        Focus on: which sessions need immediate intervention, whether the global threat level warrants mode escalation, \
        and which reflex thresholds should be tuned based on recent false positive/negative patterns. \
        Return ONLY the JSON.
        """

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: "Autopilot telemetry:\n\(jsonStr)") else {
            logger.log("Autopilot: AI strategic analysis failed — no response", category: .automation, level: .warning)
            return
        }

        applyAIStrategicAnalysis(response: response)
        globalStats.lastAIAnalysis = Date()
        save()
    }

    private func applyAIStrategicAnalysis(response: String) {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.log("Autopilot: failed to parse AI strategic response", category: .automation, level: .warning)
            return
        }

        if let newMode = json["globalMode"] as? String, let parsed = AutopilotMode(rawValue: newMode) {
            if parsed != mode {
                logger.log("Autopilot: AI recommends mode change \(mode.rawValue) -> \(parsed.rawValue)", category: .automation, level: .warning)
                mode = parsed
            }
        }

        if let reflexTuning = json["reflexTuning"] as? [[String: Any]] {
            for tuning in reflexTuning {
                if let signalType = tuning["signalType"] as? String,
                   let threshold = tuning["newThreshold"] as? Double {
                    reflexSystem.updateThreshold(for: signalType, threshold: threshold)
                    logger.log("Autopilot: AI tuned reflex for \(signalType) -> threshold \(String(format: "%.2f", threshold))", category: .automation, level: .info)
                }
            }
        }

        if let insights = json["strategicInsights"] as? [String] {
            for insight in insights.prefix(5) {
                logger.log("Autopilot: AI insight — \(insight)", category: .automation, level: .info)
            }
        }

        logger.log("Autopilot: AI strategic analysis applied", category: .automation, level: .success)
    }

    private func updateDecisionLatencyAverage(_ newLatency: Int) {
        let n = Double(globalStats.totalDecisionsMade)
        globalStats.avgDecisionLatencyMs = (globalStats.avgDecisionLatencyMs * (n - 1) + Double(newLatency)) / n
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(globalStats) {
            UserDefaults.standard.set(encoded, forKey: persistenceKey)
        }
    }
}
