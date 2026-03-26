import Foundation
import UIKit
import Vision

nonisolated enum CheckpointState: String, Codable, Sendable, CaseIterable {
    case loginPage
    case loginSubmitted
    case postLoginRedirect
    case dashboardReached
    case challengePage
    case errorPage
    case blankPage
    case ppserFormLoaded
    case ppsrSubmitted
    case ppsrResultPage
    case unknown
}

nonisolated enum VerificationVerdict: String, Codable, Sendable {
    case confirmed
    case mismatch
    case uncertain
    case stale
}

nonisolated struct CheckpointInput: Sendable {
    let flowName: String
    let expectedState: CheckpointState
    let pageText: String?
    let currentURL: String?
    let screenshot: UIImage?
    let extractedOCR: [String]
    let elapsedSinceLastCheckpoint: Int
    let sessionId: String
}

nonisolated struct CheckpointResult: Sendable {
    let verdict: VerificationVerdict
    let actualState: CheckpointState
    let confidence: Double
    let reasoning: String
    let signals: [String]
    let correctionSuggestion: String?
    let timestamp: Date
}

nonisolated struct CheckpointAuditEntry: Codable, Sendable {
    let id: String
    let flowName: String
    let expectedState: String
    let actualState: String
    let verdict: String
    let confidence: Double
    let reasoning: String
    let sessionId: String
    let timestamp: Date
}

nonisolated struct CheckpointStore: Codable, Sendable {
    var auditLog: [CheckpointAuditEntry] = []
    var verdictCounts: [String: Int] = [:]
    var flowAccuracy: [String: FlowAccuracyProfile] = [:]
    var totalVerifications: Int = 0
    var stateKeywordMap: [String: [String]] = [:]
}

nonisolated struct FlowAccuracyProfile: Codable, Sendable {
    var totalChecks: Int = 0
    var confirmedCount: Int = 0
    var mismatchCount: Int = 0
    var uncertainCount: Int = 0

    var accuracy: Double {
        guard totalChecks > 0 else { return 0.5 }
        return Double(confirmedCount) / Double(totalChecks)
    }
}

@MainActor
class AICheckpointVerificationTool {
    static let shared = AICheckpointVerificationTool()

    private let logger = DebugLogger.shared
    private let persistKey = "AICheckpointVerificationTool_v1"
    private let maxAuditEntries = 500
    private var store: CheckpointStore

    private(set) var lastResult: CheckpointResult?
    private(set) var isVerifying: Bool = false

    init() {
        if let data = UserDefaults.standard.data(forKey: persistKey),
           let decoded = try? JSONDecoder().decode(CheckpointStore.self, from: data) {
            self.store = decoded
        } else {
            self.store = CheckpointStore()
        }
    }

    func verifyCheckpoint(input: CheckpointInput) async -> CheckpointResult {
        isVerifying = true
        defer { isVerifying = false }

        logger.log("CheckpointVerifier: verifying \(input.expectedState.rawValue) for flow \(input.flowName)", category: .automation, level: .info, sessionId: input.sessionId)

        var ocrTexts = input.extractedOCR
        if ocrTexts.isEmpty, let screenshot = input.screenshot {
            ocrTexts = await extractOCR(from: screenshot)
        }

        let heuristicResult = heuristicVerification(input: input, ocrTexts: ocrTexts)

        if heuristicResult.confidence >= 0.85 {
            recordResult(input: input, result: heuristicResult, wasAI: false)
            lastResult = heuristicResult
            return heuristicResult
        }

        if let aiResult = await requestAIVerification(input: input, ocrTexts: ocrTexts, heuristicFallback: heuristicResult) {
            recordResult(input: input, result: aiResult, wasAI: true)
            lastResult = aiResult
            return aiResult
        }

        recordResult(input: input, result: heuristicResult, wasAI: false)
        lastResult = heuristicResult
        return heuristicResult
    }

    var auditLog: [CheckpointAuditEntry] { store.auditLog }
    var totalVerifications: Int { store.totalVerifications }
    var verdictBreakdown: [String: Int] { store.verdictCounts }
    var flowAccuracyProfiles: [String: FlowAccuracyProfile] { store.flowAccuracy }

    func resetAll() {
        store = CheckpointStore()
        lastResult = nil
        save()
        logger.log("CheckpointVerifier: all data RESET", category: .automation, level: .warning)
    }

    // MARK: - OCR

    private func extractOCR(from image: UIImage) async -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let texts = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: texts)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }

    // MARK: - Heuristic

    private func heuristicVerification(input: CheckpointInput, ocrTexts: [String]) -> CheckpointResult {
        let pageText = (input.pageText ?? "").lowercased()
        let ocrJoined = ocrTexts.joined(separator: " ").lowercased()
        let combined = pageText + " " + ocrJoined
        let url = (input.currentURL ?? "").lowercased()

        var signals: [String] = []
        let detectedState = detectState(combined: combined, url: url, signals: &signals)

        if input.elapsedSinceLastCheckpoint > 60000 {
            signals.append("stale_checkpoint_>60s")
            return CheckpointResult(verdict: .stale, actualState: detectedState, confidence: 0.6, reasoning: "Checkpoint data is stale (\(input.elapsedSinceLastCheckpoint)ms since last check)", signals: signals, correctionSuggestion: "Re-capture page state before verifying", timestamp: Date())
        }

        if detectedState == input.expectedState {
            let confidence = min(0.95, 0.6 + Double(signals.count) * 0.08)
            return CheckpointResult(verdict: .confirmed, actualState: detectedState, confidence: confidence, reasoning: "State matches expected: \(signals.joined(separator: ", "))", signals: signals, correctionSuggestion: nil, timestamp: Date())
        }

        if detectedState == .unknown {
            return CheckpointResult(verdict: .uncertain, actualState: .unknown, confidence: 0.3, reasoning: "Could not determine page state from content/OCR", signals: signals, correctionSuggestion: "Increase wait time or capture new screenshot", timestamp: Date())
        }

        let suggestion: String
        switch detectedState {
        case .challengePage: suggestion = "Challenge detected — needs bypass before continuing flow"
        case .errorPage: suggestion = "Error page — check credentials or retry"
        case .blankPage: suggestion = "Blank page — WebView may have crashed or page failed to load"
        default: suggestion = "Expected \(input.expectedState.rawValue) but found \(detectedState.rawValue)"
        }

        return CheckpointResult(verdict: .mismatch, actualState: detectedState, confidence: 0.7, reasoning: "State mismatch: expected \(input.expectedState.rawValue), detected \(detectedState.rawValue)", signals: signals, correctionSuggestion: suggestion, timestamp: Date())
    }

    private func detectState(combined: String, url: String, signals: inout [String]) -> CheckpointState {
        let loginKeywords = ["log in", "login", "sign in", "username", "email address", "password"]
        let dashboardKeywords = ["dashboard", "my account", "balance", "deposit", "lobby", "home"]
        let challengeKeywords = ["captcha", "challenge", "verify you are human", "cloudflare", "just a moment"]
        let errorKeywords = ["error", "incorrect", "invalid", "wrong password", "access denied", "something went wrong"]
        let blankIndicators = combined.trimmingCharacters(in: .whitespacesAndNewlines).count < 20
        let ppsrFormKeywords = ["vin", "vehicle identification", "ppsr", "registration number", "check vehicle"]
        let ppsrResultKeywords = ["certificate", "encumbrance", "stolen", "written-off", "no interest found", "security interest"]

        if blankIndicators {
            signals.append("blank_content")
            return .blankPage
        }

        if challengeKeywords.contains(where: { combined.contains($0) }) {
            signals.append("challenge_keywords_found")
            return .challengePage
        }

        if errorKeywords.filter({ combined.contains($0) }).count >= 2 {
            signals.append("multiple_error_keywords")
            return .errorPage
        }

        if ppsrResultKeywords.contains(where: { combined.contains($0) }) {
            signals.append("ppsr_result_keywords")
            return .ppsrResultPage
        }

        if ppsrFormKeywords.contains(where: { combined.contains($0) }) {
            signals.append("ppsr_form_keywords")
            return .ppserFormLoaded
        }

        if dashboardKeywords.filter({ combined.contains($0) }).count >= 2 {
            signals.append("dashboard_keywords_found")
            return .dashboardReached
        }

        if url.contains("dashboard") || url.contains("lobby") || url.contains("account") || url.contains("home") {
            signals.append("dashboard_url_pattern")
            return .postLoginRedirect
        }

        if loginKeywords.filter({ combined.contains($0) }).count >= 2 {
            signals.append("login_keywords_found")
            return .loginPage
        }

        if url.contains("login") || url.contains("signin") || url.contains("auth") {
            signals.append("login_url_pattern")
            return .loginPage
        }

        return .unknown
    }

    // MARK: - AI

    private func requestAIVerification(input: CheckpointInput, ocrTexts: [String], heuristicFallback: CheckpointResult) async -> CheckpointResult? {
        var data: [String: Any] = [
            "flowName": input.flowName,
            "expectedState": input.expectedState.rawValue,
            "heuristicVerdict": heuristicFallback.verdict.rawValue,
            "heuristicActualState": heuristicFallback.actualState.rawValue,
            "heuristicConfidence": String(format: "%.2f", heuristicFallback.confidence),
            "signals": heuristicFallback.signals,
            "ocrTexts": Array(ocrTexts.prefix(20)),
            "elapsedMs": input.elapsedSinceLastCheckpoint,
        ]

        if let pageText = input.pageText { data["pageTextSnippet"] = String(pageText.prefix(800)) }
        if let url = input.currentURL { data["currentURL"] = url }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return nil }

        let systemPrompt = """
        You verify automation workflow checkpoints. Given expected page state and actual page content/OCR, determine if the automation \
        reached the correct screen. Return ONLY JSON: \
        {"verdict":"confirmed|mismatch|uncertain|stale","actualState":"loginPage|loginSubmitted|postLoginRedirect|dashboardReached|challengePage|errorPage|blankPage|ppserFormLoaded|ppsrSubmitted|ppsrResultPage|unknown", \
        "confidence":0.0-1.0,"reasoning":"...","correctionSuggestion":"...or null"}. \
        States: loginPage=form visible, dashboardReached=post-login content, challengePage=captcha/block, errorPage=error messages, blankPage=empty. Return ONLY JSON.
        """

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: "Checkpoint data:\n\(jsonStr)") else { return nil }

        return parseAIResponse(response, expectedState: input.expectedState)
    }

    private func parseAIResponse(_ response: String, expectedState: CheckpointState) -> CheckpointResult? {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        guard let verdictStr = json["verdict"] as? String,
              let verdict = VerificationVerdict(rawValue: verdictStr) else { return nil }

        let actualStateStr = json["actualState"] as? String ?? "unknown"
        let actualState = CheckpointState(rawValue: actualStateStr) ?? .unknown
        let confidence = (json["confidence"] as? Double) ?? 0.6
        let reasoning = (json["reasoning"] as? String) ?? "AI verification"
        let correction = json["correctionSuggestion"] as? String

        return CheckpointResult(verdict: verdict, actualState: actualState, confidence: min(1.0, max(0.0, confidence)), reasoning: reasoning, signals: ["ai_analysis"], correctionSuggestion: correction, timestamp: Date())
    }

    // MARK: - Recording

    private func recordResult(input: CheckpointInput, result: CheckpointResult, wasAI: Bool) {
        store.totalVerifications += 1
        store.verdictCounts[result.verdict.rawValue, default: 0] += 1

        var profile = store.flowAccuracy[input.flowName] ?? FlowAccuracyProfile()
        profile.totalChecks += 1
        switch result.verdict {
        case .confirmed: profile.confirmedCount += 1
        case .mismatch: profile.mismatchCount += 1
        case .uncertain, .stale: profile.uncertainCount += 1
        }
        store.flowAccuracy[input.flowName] = profile

        let entry = CheckpointAuditEntry(
            id: UUID().uuidString,
            flowName: input.flowName,
            expectedState: input.expectedState.rawValue,
            actualState: result.actualState.rawValue,
            verdict: result.verdict.rawValue,
            confidence: result.confidence,
            reasoning: result.reasoning,
            sessionId: input.sessionId,
            timestamp: Date()
        )

        store.auditLog.insert(entry, at: 0)
        if store.auditLog.count > maxAuditEntries {
            store.auditLog = Array(store.auditLog.prefix(maxAuditEntries))
        }

        save()

        let level: DebugLogLevel = result.verdict == .mismatch ? .warning : result.verdict == .confirmed ? .success : .info
        logger.log("CheckpointVerifier: \(result.verdict.rawValue) — expected \(input.expectedState.rawValue) actual \(result.actualState.rawValue) (conf=\(String(format: "%.0f%%", result.confidence * 100))) [ai=\(wasAI)]", category: .automation, level: level, sessionId: input.sessionId)
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: persistKey)
        }
    }
}
