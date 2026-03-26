import Foundation
import UIKit

nonisolated enum RunHealthDecision: String, Sendable, CaseIterable {
    case retry
    case wait
    case stop
    case manualReview
    case rotateInfra
    case continueMonitoring
}

nonisolated struct RunHealthInput: Sendable {
    let sessionId: String
    let logs: [String]
    let pageText: String?
    let screenshotAvailable: Bool
    let currentOutcome: String?
    let host: String?
    let attemptNumber: Int
    let elapsedMs: Int
}

nonisolated struct RunHealthResult: Sendable {
    let decision: RunHealthDecision
    let confidence: Double
    let reasoning: String
    let suggestedDelaySeconds: Double
    let escalationLevel: Int
    let metadata: [String: String]
    let timestamp: Date
}

nonisolated struct RunHealthAuditEntry: Codable, Sendable {
    let id: String
    let sessionId: String
    let decision: String
    let confidence: Double
    let reasoning: String
    let host: String
    let timestamp: Date
    let inputSummary: String
    let wasApproved: Bool
}

nonisolated struct RunHealthStore: Codable, Sendable {
    var auditLog: [RunHealthAuditEntry] = []
    var decisionCounts: [String: Int] = [:]
    var hostFailureStreaks: [String: Int] = [:]
    var totalAnalyses: Int = 0
    var lastAnalysisDate: Date?
}

@MainActor
class AIRunHealthAnalyzerTool {
    static let shared = AIRunHealthAnalyzerTool()

    private let logger = DebugLogger.shared
    private let persistKey = "AIRunHealthAnalyzerTool_v1"
    private let maxAuditEntries = 500
    private var store: RunHealthStore

    private(set) var lastResult: RunHealthResult?
    private(set) var isAnalyzing: Bool = false

    init() {
        if let data = UserDefaults.standard.data(forKey: persistKey),
           let decoded = try? JSONDecoder().decode(RunHealthStore.self, from: data) {
            self.store = decoded
        } else {
            self.store = RunHealthStore()
        }
    }

    func analyzeRunHealth(input: RunHealthInput) async -> RunHealthResult {
        isAnalyzing = true
        defer { isAnalyzing = false }

        logger.log("RunHealthAnalyzer: analyzing session \(input.sessionId) attempt #\(input.attemptNumber)", category: .automation, level: .info, sessionId: input.sessionId)

        let hostProfile = input.host.flatMap { AISessionHealthMonitorService.shared.profileFor(host: $0) }
        let hostStreak = input.host.flatMap { store.hostFailureStreaks[$0] } ?? 0

        let heuristicResult = heuristicAnalysis(input: input, hostProfile: hostProfile, hostStreak: hostStreak)

        if heuristicResult.confidence >= 0.8 {
            recordResult(input: input, result: heuristicResult, wasAI: false)
            lastResult = heuristicResult
            return heuristicResult
        }

        if let aiResult = await requestAIAnalysis(input: input, hostProfile: hostProfile, heuristicFallback: heuristicResult) {
            recordResult(input: input, result: aiResult, wasAI: true)
            lastResult = aiResult
            return aiResult
        }

        recordResult(input: input, result: heuristicResult, wasAI: false)
        lastResult = heuristicResult
        return heuristicResult
    }

    var auditLog: [RunHealthAuditEntry] { store.auditLog }
    var totalAnalyses: Int { store.totalAnalyses }
    var decisionBreakdown: [String: Int] { store.decisionCounts }

    func resetAll() {
        store = RunHealthStore()
        lastResult = nil
        save()
        logger.log("RunHealthAnalyzer: all data RESET", category: .automation, level: .warning)
    }

    // MARK: - Heuristic

    private func heuristicAnalysis(input: RunHealthInput, hostProfile: HostHealthProfile?, hostStreak: Int) -> RunHealthResult {
        let pageText = (input.pageText ?? "").lowercased()

        if pageText.contains("rate limit") || pageText.contains("too many requests") || pageText.contains("429") {
            return RunHealthResult(decision: .wait, confidence: 0.9, reasoning: "Rate limit detected in page content", suggestedDelaySeconds: 30, escalationLevel: 2, metadata: ["trigger": "rate_limit"], timestamp: Date())
        }

        if pageText.contains("blocked") || pageText.contains("banned") || pageText.contains("access denied") {
            return RunHealthResult(decision: .stop, confidence: 0.85, reasoning: "Block/ban detected in page content", suggestedDelaySeconds: 0, escalationLevel: 3, metadata: ["trigger": "blocked"], timestamp: Date())
        }

        if pageText.contains("captcha") || pageText.contains("challenge") || pageText.contains("verify you are human") {
            return RunHealthResult(decision: .rotateInfra, confidence: 0.8, reasoning: "Challenge page detected — rotate fingerprint/proxy", suggestedDelaySeconds: 5, escalationLevel: 2, metadata: ["trigger": "challenge"], timestamp: Date())
        }

        if let profile = hostProfile {
            if profile.consecutiveFailures >= 8 {
                return RunHealthResult(decision: .stop, confidence: 0.85, reasoning: "Host has \(profile.consecutiveFailures) consecutive failures — stop to prevent waste", suggestedDelaySeconds: 0, escalationLevel: 3, metadata: ["consecutiveFailures": "\(profile.consecutiveFailures)"], timestamp: Date())
            }

            if profile.consecutiveFailures >= 5 {
                return RunHealthResult(decision: .wait, confidence: 0.75, reasoning: "Host streak at \(profile.consecutiveFailures) — backoff recommended", suggestedDelaySeconds: Double(profile.consecutiveFailures) * 5.0, escalationLevel: 2, metadata: ["consecutiveFailures": "\(profile.consecutiveFailures)"], timestamp: Date())
            }

            if profile.timeoutRate > 0.5 && profile.totalSessions >= 5 {
                return RunHealthResult(decision: .rotateInfra, confidence: 0.7, reasoning: "High timeout rate (\(Int(profile.timeoutRate * 100))%) — rotate network", suggestedDelaySeconds: 3, escalationLevel: 2, metadata: ["timeoutRate": "\(Int(profile.timeoutRate * 100))"], timestamp: Date())
            }
        }

        if input.attemptNumber >= 4 {
            return RunHealthResult(decision: .manualReview, confidence: 0.6, reasoning: "Attempt #\(input.attemptNumber) with no clear signals — manual review recommended", suggestedDelaySeconds: 0, escalationLevel: 1, metadata: ["attempt": "\(input.attemptNumber)"], timestamp: Date())
        }

        if input.elapsedMs > 45000 {
            return RunHealthResult(decision: .retry, confidence: 0.6, reasoning: "Slow session (\(input.elapsedMs)ms) — retry with fresh session", suggestedDelaySeconds: 2, escalationLevel: 1, metadata: ["elapsedMs": "\(input.elapsedMs)"], timestamp: Date())
        }

        return RunHealthResult(decision: .retry, confidence: 0.5, reasoning: "No strong signal — default to retry", suggestedDelaySeconds: 1.5, escalationLevel: 0, metadata: [:], timestamp: Date())
    }

    // MARK: - AI

    private func requestAIAnalysis(input: RunHealthInput, hostProfile: HostHealthProfile?, heuristicFallback: RunHealthResult) async -> RunHealthResult? {
        var data: [String: Any] = [
            "sessionId": input.sessionId,
            "attemptNumber": input.attemptNumber,
            "elapsedMs": input.elapsedMs,
            "screenshotAvailable": input.screenshotAvailable,
            "currentOutcome": input.currentOutcome ?? "unknown",
            "recentLogs": input.logs.suffix(15),
            "heuristicDecision": heuristicFallback.decision.rawValue,
            "heuristicConfidence": String(format: "%.2f", heuristicFallback.confidence),
        ]

        if let host = input.host { data["host"] = host }
        if let pageText = input.pageText { data["pageTextSnippet"] = String(pageText.prefix(800)) }

        if let profile = hostProfile {
            data["hostHealth"] = [
                "failureRate": Int(profile.failureRate * 100),
                "consecutiveFailures": profile.consecutiveFailures,
                "timeoutRate": Int(profile.timeoutRate * 100),
                "totalSessions": profile.totalSessions,
                "healthScore": String(format: "%.2f", profile.healthScore),
            ]
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return nil }

        let systemPrompt = """
        You are a run health analyzer for web automation sessions. Analyze the session data and return ONLY a JSON object: \
        {"decision":"retry|wait|stop|manualReview|rotateInfra|continueMonitoring","confidence":0.0-1.0,"reasoning":"...","suggestedDelaySeconds":0,"escalationLevel":0-3}. \
        Decision guide: retry=transient issue, wait=rate limited or backoff needed, stop=hard failure or repeated fails, \
        manualReview=ambiguous state, rotateInfra=detection/blocking, continueMonitoring=healthy. \
        escalationLevel: 0=info, 1=warning, 2=action needed, 3=critical. Return ONLY JSON.
        """

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: "Session data:\n\(jsonStr)") else { return nil }

        return parseAIResponse(response)
    }

    private func parseAIResponse(_ response: String) -> RunHealthResult? {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        guard let decisionStr = json["decision"] as? String,
              let decision = RunHealthDecision(rawValue: decisionStr) else { return nil }

        let confidence = (json["confidence"] as? Double) ?? 0.6
        let reasoning = (json["reasoning"] as? String) ?? "AI analysis"
        let delay = (json["suggestedDelaySeconds"] as? Double) ?? 0
        let escalation = (json["escalationLevel"] as? Int) ?? 1

        return RunHealthResult(decision: decision, confidence: min(1.0, max(0.0, confidence)), reasoning: reasoning, suggestedDelaySeconds: delay, escalationLevel: escalation, metadata: ["source": "ai"], timestamp: Date())
    }

    // MARK: - Recording

    private func recordResult(input: RunHealthInput, result: RunHealthResult, wasAI: Bool) {
        store.totalAnalyses += 1
        store.decisionCounts[result.decision.rawValue, default: 0] += 1
        store.lastAnalysisDate = Date()

        if result.decision == .stop || result.decision == .wait {
            if let host = input.host {
                store.hostFailureStreaks[host, default: 0] += 1
            }
        } else if result.decision == .continueMonitoring {
            if let host = input.host {
                store.hostFailureStreaks[host] = 0
            }
        }

        let entry = RunHealthAuditEntry(
            id: UUID().uuidString,
            sessionId: input.sessionId,
            decision: result.decision.rawValue,
            confidence: result.confidence,
            reasoning: result.reasoning,
            host: input.host ?? "unknown",
            timestamp: Date(),
            inputSummary: "attempt#\(input.attemptNumber) elapsed=\(input.elapsedMs)ms outcome=\(input.currentOutcome ?? "unknown")",
            wasApproved: true
        )

        store.auditLog.insert(entry, at: 0)
        if store.auditLog.count > maxAuditEntries {
            store.auditLog = Array(store.auditLog.prefix(maxAuditEntries))
        }

        save()

        let level: DebugLogLevel = result.escalationLevel >= 3 ? .critical : result.escalationLevel >= 2 ? .warning : .info
        logger.log("RunHealthAnalyzer: \(result.decision.rawValue) (conf=\(String(format: "%.0f%%", result.confidence * 100))) — \(result.reasoning) [ai=\(wasAI)]", category: .automation, level: level, sessionId: input.sessionId)
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: persistKey)
        }
    }
}
