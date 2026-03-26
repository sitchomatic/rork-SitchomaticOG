import Foundation
import UIKit
import Vision

nonisolated struct RescueSignalBundle: Codable, Sendable {
    let host: String
    let sessionId: String
    let originalOutcome: String
    let originalConfidence: Double
    let pageContent: String
    let currentURL: String
    let preLoginURL: String
    let pageTitle: String
    let ocrText: String?
    let httpStatus: Int?
    let latencyMs: Int
    let redirectChain: [String]
    let cookieCount: Int
    let hadContentChange: Bool
    let hadNavigation: Bool
    let hadRedirect: Bool
    let welcomeTextFound: Bool
    let errorBannerDetected: Bool
    let timestamp: Date
}

nonisolated struct RescueResult: Sendable {
    let rescued: Bool
    let newOutcome: String
    let newConfidence: Double
    let reasoning: String
    let signalsUsed: [String]
}

nonisolated struct RescueHistoryRecord: Codable, Sendable {
    let host: String
    let originalOutcome: String
    let rescuedOutcome: String
    let originalConfidence: Double
    let rescuedConfidence: Double
    let reasoning: String
    let timestamp: Date
    let wasCorrect: Bool?
}

nonisolated struct RescueStore: Codable, Sendable {
    var history: [RescueHistoryRecord] = []
    var totalRescueAttempts: Int = 0
    var successfulRescues: Int = 0
    var rescueThreshold: Double = 0.60
    var hostRescueStats: [String: HostRescueStats] = [:]
    var lastThresholdCalibration: Date = .distantPast
}

nonisolated struct HostRescueStats: Codable, Sendable {
    var totalAttempts: Int = 0
    var successfulRescues: Int = 0
    var failedRescues: Int = 0
    var rescuedAsSuccess: Int = 0
    var rescuedAsNoAcc: Int = 0
    var rescuedAsDisabled: Int = 0
    var avgConfidenceGain: Double = 0
}

@MainActor
class AIOutcomeRescueEngine {
    static let shared = AIOutcomeRescueEngine()

    private let logger = DebugLogger.shared
    private let persistenceKey = "AIOutcomeRescueEngine_v1"
    private let maxHistory = 1000
    private let calibrationCooldownSeconds: TimeInterval = 1800
    private var store: RescueStore

    private let knowledgeGraph = AIKnowledgeGraphService.shared

    private init() {
        if let saved = UserDefaults.standard.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode(RescueStore.self, from: saved) {
            self.store = decoded
        } else {
            self.store = RescueStore()
        }
    }

    var rescueThreshold: Double { store.rescueThreshold }

    func shouldAttemptRescue(outcome: String, confidence: Double) -> Bool {
        let rescuableOutcomes: Set<String> = ["unsure", "timeout", "connectionFailure", "noAcc"]
        guard rescuableOutcomes.contains(outcome) else { return false }

        if outcome == "timeout" || outcome == "connectionFailure" {
            return true
        }

        return confidence < store.rescueThreshold
    }

    func attemptRescue(bundle: RescueSignalBundle) async -> RescueResult {
        store.totalRescueAttempts += 1

        var hostStats = store.hostRescueStats[bundle.host] ?? HostRescueStats()
        hostStats.totalAttempts += 1

        logger.log("OutcomeRescue: attempting rescue for \(bundle.host) — original=\(bundle.originalOutcome) confidence=\(String(format: "%.0f%%", bundle.originalConfidence * 100))", category: .evaluation, level: .info)

        let localResult = performLocalSignalAnalysis(bundle: bundle)
        if localResult.rescued && localResult.newConfidence >= 0.70 {
            logger.log("OutcomeRescue: LOCAL rescue → \(localResult.newOutcome) (\(String(format: "%.0f%%", localResult.newConfidence * 100))) — \(localResult.reasoning)", category: .evaluation, level: .success)
            recordRescue(bundle: bundle, result: localResult, hostStats: &hostStats)
            store.hostRescueStats[bundle.host] = hostStats
            save()
            return localResult
        }

        let aiResult = await performAIRescue(bundle: bundle)
        if let aiResult, aiResult.rescued {
            logger.log("OutcomeRescue: AI rescue → \(aiResult.newOutcome) (\(String(format: "%.0f%%", aiResult.newConfidence * 100))) — \(aiResult.reasoning)", category: .evaluation, level: .success)
            recordRescue(bundle: bundle, result: aiResult, hostStats: &hostStats)
            store.hostRescueStats[bundle.host] = hostStats
            save()
            return aiResult
        }

        let mergedResult: RescueResult
        if localResult.rescued {
            mergedResult = localResult
            recordRescue(bundle: bundle, result: localResult, hostStats: &hostStats)
        } else {
            mergedResult = RescueResult(rescued: false, newOutcome: bundle.originalOutcome, newConfidence: bundle.originalConfidence, reasoning: "Rescue failed — insufficient signals", signalsUsed: [])
        }

        store.hostRescueStats[bundle.host] = hostStats
        save()

        if Date().timeIntervalSince(store.lastThresholdCalibration) > calibrationCooldownSeconds {
            calibrateThreshold()
        }

        return mergedResult
    }

    func extractOCRText(from screenshot: UIImage) async -> String? {
        guard let cgImage = screenshot.cgImage else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.recognitionLanguages = ["en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results else { return nil }
        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    func globalStats() -> (totalAttempts: Int, successfulRescues: Int, rescueRate: Double, threshold: Double) {
        let rate = store.totalRescueAttempts > 0 ? Double(store.successfulRescues) / Double(store.totalRescueAttempts) : 0
        return (store.totalRescueAttempts, store.successfulRescues, rate, store.rescueThreshold)
    }

    func hostStats(for host: String) -> HostRescueStats? {
        store.hostRescueStats[host]
    }

    func resetAll() {
        store = RescueStore()
        save()
    }

    private func performLocalSignalAnalysis(bundle: RescueSignalBundle) -> RescueResult {
        let content = bundle.pageContent.lowercased()
        let url = bundle.currentURL.lowercased()
        let ocrLower = bundle.ocrText?.lowercased() ?? ""
        let allText = content + " " + ocrLower

        var signals: [String] = []
        var successScore: Double = 0
        var disabledScore: Double = 0
        var noAccScore: Double = 0
        var tempDisabledScore: Double = 0

        let successMarkers = ["balance", "wallet", "my account", "logout", "dashboard", "deposit", "withdraw", "my profile"]
        for marker in successMarkers {
            if allText.contains(marker) {
                successScore += 0.25
                signals.append("success_marker_\(marker)")
            }
        }

        if bundle.hadRedirect && !url.contains("/login") && !url.contains("/signin") {
            successScore += 0.20
            signals.append("redirect_away_from_login")
        }

        if bundle.cookieCount > 5 {
            successScore += 0.10
            signals.append("multiple_cookies_set(\(bundle.cookieCount))")
        }

        if bundle.welcomeTextFound {
            successScore += 0.15
            signals.append("welcome_text_detected")
        }

        let disabledMarkers = ["disabled", "suspended", "banned", "blocked", "closed", "self-excluded", "permanently"]
        for marker in disabledMarkers {
            if allText.contains(marker) {
                disabledScore += 0.20
                signals.append("disabled_marker_\(marker)")
            }
        }

        let tempMarkers = ["temporarily", "too many attempts", "try again later", "temporarily locked", "cooldown"]
        for marker in tempMarkers {
            if allText.contains(marker) {
                tempDisabledScore += 0.25
                signals.append("temp_disabled_marker_\(marker)")
            }
        }

        let noAccMarkers = ["incorrect", "invalid", "wrong password", "not found", "login failed", "authentication failed"]
        for marker in noAccMarkers {
            if allText.contains(marker) {
                noAccScore += 0.20
                signals.append("noAcc_marker_\(marker)")
            }
        }

        if !ocrLower.isEmpty {
            let ocrSuccessTerms = ["balance", "wallet", "my account", "logout"]
            for term in ocrSuccessTerms {
                if ocrLower.contains(term) && !signals.contains("success_marker_\(term)") {
                    successScore += 0.15
                    signals.append("ocr_success_\(term)")
                }
            }
        }

        let scores: [(String, Double)] = [
            ("success", successScore),
            ("permDisabled", disabledScore),
            ("tempDisabled", tempDisabledScore),
            ("noAcc", noAccScore)
        ]

        guard let best = scores.max(by: { $0.1 < $1.1 }), best.1 >= 0.30 else {
            return RescueResult(rescued: false, newOutcome: bundle.originalOutcome, newConfidence: bundle.originalConfidence, reasoning: "No strong signals found", signalsUsed: signals)
        }

        let newConfidence = min(0.95, best.1 + 0.10)
        guard newConfidence > bundle.originalConfidence else {
            return RescueResult(rescued: false, newOutcome: bundle.originalOutcome, newConfidence: bundle.originalConfidence, reasoning: "Local analysis did not improve confidence", signalsUsed: signals)
        }

        return RescueResult(
            rescued: true,
            newOutcome: best.0,
            newConfidence: newConfidence,
            reasoning: "Local multi-signal rescue: \(signals.count) signals → \(best.0)",
            signalsUsed: signals
        )
    }

    private func performAIRescue(bundle: RescueSignalBundle) async -> RescueResult? {
        let snippet = String(bundle.pageContent.prefix(2000))
        let ocrSnippet = String((bundle.ocrText ?? "").prefix(1000))

        var contextData: [String: Any] = [
            "host": bundle.host,
            "originalOutcome": bundle.originalOutcome,
            "originalConfidence": bundle.originalConfidence,
            "currentURL": bundle.currentURL,
            "preLoginURL": bundle.preLoginURL,
            "pageTitle": bundle.pageTitle,
            "latencyMs": bundle.latencyMs,
            "cookieCount": bundle.cookieCount,
            "hadRedirect": bundle.hadRedirect,
            "hadNavigation": bundle.hadNavigation,
            "hadContentChange": bundle.hadContentChange,
            "welcomeTextFound": bundle.welcomeTextFound,
            "errorBannerDetected": bundle.errorBannerDetected,
        ]
        if let status = bundle.httpStatus { contextData["httpStatus"] = status }
        if !bundle.redirectChain.isEmpty { contextData["redirectChain"] = bundle.redirectChain }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: contextData),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return nil }

        let systemPrompt = """
        You rescue ambiguous login automation outcomes by deep cross-referencing multiple signals. \
        The original classifier returned a low-confidence or ambiguous result. \
        Analyze ALL signals (page content, URL, OCR text, redirects, cookies, timing) to determine the TRUE outcome. \
        Possible outcomes: "success" (confirmed logged in), "permDisabled" (permanently disabled/suspended), \
        "tempDisabled" (temporarily locked), "noAcc" (wrong credentials), "unsure" (cannot determine). \
        Return ONLY a JSON object: {"rescued":true/false,"outcome":"...","confidence":0.0-1.0,"reasoning":"brief explanation","signalsUsed":["signal1","signal2"]}. \
        Set rescued=true ONLY if you are MORE confident than the original classifier. \
        Return ONLY the JSON.
        """

        let userPrompt = """
        Context:\n\(jsonStr)
        
        Page content (first 2000 chars):\n\(snippet)
        
        OCR text from screenshot:\n\(ocrSnippet)
        """

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: userPrompt) else {
            return nil
        }

        return parseAIRescueResponse(response, bundle: bundle)
    }

    private func parseAIRescueResponse(_ response: String, bundle: RescueSignalBundle) -> RescueResult? {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rescued = json["rescued"] as? Bool else {
            logger.log("OutcomeRescue: failed to parse AI response", category: .evaluation, level: .warning)
            return nil
        }

        guard rescued,
              let outcome = json["outcome"] as? String,
              let confidence = json["confidence"] as? Double else {
            return RescueResult(rescued: false, newOutcome: bundle.originalOutcome, newConfidence: bundle.originalConfidence, reasoning: "AI declined rescue", signalsUsed: [])
        }

        guard confidence > bundle.originalConfidence else {
            return RescueResult(rescued: false, newOutcome: bundle.originalOutcome, newConfidence: bundle.originalConfidence, reasoning: "AI confidence not higher than original", signalsUsed: [])
        }

        let reasoning = json["reasoning"] as? String ?? "AI rescue"
        let signalsUsed = json["signalsUsed"] as? [String] ?? []

        return RescueResult(
            rescued: true,
            newOutcome: outcome,
            newConfidence: min(0.95, confidence),
            reasoning: "AI rescue: \(reasoning)",
            signalsUsed: signalsUsed
        )
    }

    private func recordRescue(bundle: RescueSignalBundle, result: RescueResult, hostStats: inout HostRescueStats) {
        store.successfulRescues += 1
        hostStats.successfulRescues += 1

        switch result.newOutcome {
        case "success": hostStats.rescuedAsSuccess += 1
        case "noAcc": hostStats.rescuedAsNoAcc += 1
        case "permDisabled", "tempDisabled": hostStats.rescuedAsDisabled += 1
        default: break
        }

        let gain = result.newConfidence - bundle.originalConfidence
        let prevAvg = hostStats.avgConfidenceGain
        hostStats.avgConfidenceGain = prevAvg + (gain - prevAvg) / Double(hostStats.successfulRescues)

        let record = RescueHistoryRecord(
            host: bundle.host,
            originalOutcome: bundle.originalOutcome,
            rescuedOutcome: result.newOutcome,
            originalConfidence: bundle.originalConfidence,
            rescuedConfidence: result.newConfidence,
            reasoning: result.reasoning,
            timestamp: Date(),
            wasCorrect: nil
        )
        store.history.append(record)
        if store.history.count > maxHistory {
            store.history.removeFirst(store.history.count - maxHistory)
        }

        publishRescueToKnowledgeGraph(bundle: bundle, result: result)
    }

    private func calibrateThreshold() {
        let recent = store.history.suffix(100)
        guard recent.count >= 20 else { return }

        let rescueRate = Double(store.successfulRescues) / max(1, Double(store.totalRescueAttempts))

        if rescueRate > 0.5 {
            store.rescueThreshold = min(0.75, store.rescueThreshold + 0.02)
        } else if rescueRate < 0.2 {
            store.rescueThreshold = max(0.40, store.rescueThreshold - 0.02)
        }

        store.lastThresholdCalibration = Date()
        save()

        logger.log("OutcomeRescue: calibrated threshold → \(String(format: "%.2f", store.rescueThreshold)) (rescue rate: \(String(format: "%.0f%%", rescueRate * 100)))", category: .evaluation, level: .info)
    }

    private func publishRescueToKnowledgeGraph(bundle: RescueSignalBundle, result: RescueResult) {
        let severity: KnowledgeSeverity = result.rescued ? .medium : .low

        let payload: [String: String] = [
            "rescued": "\(result.rescued)",
            "originalOutcome": bundle.originalOutcome,
            "newOutcome": result.newOutcome,
            "originalConfidence": String(format: "%.2f", bundle.originalConfidence),
            "newConfidence": String(format: "%.2f", result.newConfidence),
            "signalsUsed": result.signalsUsed.joined(separator: ","),
        ]

        let summary = result.rescued
            ? "Rescue \(bundle.originalOutcome)→\(result.newOutcome) on \(bundle.host) (\(Int(result.newConfidence * 100))%)"
            : "Rescue failed on \(bundle.host) — \(bundle.originalOutcome) unchanged"

        knowledgeGraph.publishEvent(
            source: "AIOutcomeRescue",
            host: bundle.host,
            domain: .rescue,
            type: .rescueOutcome,
            severity: severity,
            confidence: result.newConfidence,
            payload: payload,
            summary: summary
        )
    }

    func getTransferLearningRescueInsight(for host: String) -> (rescueRate: Double, commonOutcomes: [String])? {
        let intel = knowledgeGraph.getHostIntelligence(host: host)
        guard intel.rescueAttempts > 0 else { return nil }
        return (intel.rescueSuccessRate, intel.commonRescueOutcomes)
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: persistenceKey)
        }
    }
}
