import Foundation
import UIKit
import Vision

nonisolated enum AIDecision: String, Sendable {
    case proceed
    case retry
    case rotateCard
    case rotateProxy
    case rotateEmail
    case blacklistCard
    case waitAndRetry
    case manualReview
    case abort
    case switchPattern
    case deepScan
}

nonisolated struct AIAnalysisResult: Sendable {
    let decision: AIDecision
    let confidence: Double
    let reasoning: String
    let suggestedDelay: TimeInterval
    let fallbackDecision: AIDecision?
    let metadata: [String: String]
}

nonisolated struct BatchAnalytics: Sendable {
    let totalProcessed: Int
    let successRate: Double
    let avgLatencyMs: Int
    let failurePatterns: [String: Int]
    let hotCards: [String]
    let deadCards: [String]
    let suggestedConcurrency: Int
}

@MainActor
class AIAutomationCoordinator {
    static let shared = AIAutomationCoordinator()

    private let logger = DebugLogger.shared
    private let visionML = VisionMLService.shared
    private var decisionHistory: [(Date, AIDecision, String)] = []
    private var consecutiveFailures: Int = 0
    private var lastSuccessTime: Date?
    private var patternSuccessMap: [String: Int] = [:]
    private var patternFailureMap: [String: Int] = [:]

    var useDeepVision: Bool = true
    var useOnDeviceAI: Bool = true
    var adaptiveConcurrency: Bool = true
    var maxDecisionHistory: Int = 100

    func analyzeScreenshotForLogin(
        image: UIImage,
        viewportSize: CGSize,
        currentPattern: LoginFormPattern,
        attemptNumber: Int,
        sessionId: String
    ) async -> (detection: VisionMLService.LoginFieldDetection, decision: AIAnalysisResult) {
        let detection: VisionMLService.LoginFieldDetection
        if useDeepVision {
            detection = await visionML.deepDetectLoginElements(in: image, viewportSize: viewportSize)
        } else {
            detection = await visionML.detectLoginElements(in: image, viewportSize: viewportSize)
        }

        let decision = await makeLoginDecision(
            detection: detection,
            currentPattern: currentPattern,
            attemptNumber: attemptNumber,
            sessionId: sessionId
        )

        recordDecision(decision.decision, context: "login_\(currentPattern.rawValue)_attempt\(attemptNumber)")
        return (detection, decision)
    }

    func analyzePPSROutcome(
        pageContent: String,
        screenshot: UIImage?,
        checkOutcome: CheckOutcome,
        cardId: String,
        sessionId: String
    ) async -> AIAnalysisResult {
        var aiAnalysis: AIAnalysisPPSRResult?

        if useOnDeviceAI {
            aiAnalysis = await OnDeviceAIService.shared.analyzePPSRResponse(pageContent: pageContent)
        }

        if let ai = aiAnalysis {
            let decision = mapAISuggestionToDecision(ai.suggestedAction)
            let result = AIAnalysisResult(
                decision: decision,
                confidence: Double(ai.confidence) / 100.0,
                reasoning: "AI: \(ai.summary) [error:\(ai.errorType)]",
                suggestedDelay: delayForDecision(decision),
                fallbackDecision: fallbackForDecision(decision),
                metadata: [
                    "aiPassed": "\(ai.passed)",
                    "aiDeclined": "\(ai.declined)",
                    "aiErrorType": ai.errorType,
                    "aiConfidence": "\(ai.confidence)",
                    "cardId": cardId
                ]
            )
            recordDecision(result.decision, context: "ppsr_ai_\(cardId)")
            logger.log("AICoordinator: PPSR AI decision=\(result.decision.rawValue) confidence=\(ai.confidence)% reason=\(ai.summary)", category: .automation, level: .info, sessionId: sessionId)
            return result
        }

        let heuristicDecision = heuristicPPSRDecision(checkOutcome: checkOutcome, cardId: cardId)
        recordDecision(heuristicDecision.decision, context: "ppsr_heuristic_\(cardId)")
        return heuristicDecision
    }

    func analyzeLoginOutcome(
        pageContent: String,
        screenshot: UIImage?,
        loginOutcome: LoginOutcome,
        username: String,
        sessionId: String
    ) async -> AIAnalysisResult {
        if useOnDeviceAI, let screenshot {
            let ocrTexts = await visionML.recognizeAllText(in: screenshot).map { $0.text }
            if let ai = await OnDeviceAIService.shared.analyzeLoginPage(pageContent: pageContent, ocrTexts: ocrTexts) {
                let decision: AIDecision
                switch ai.suggestedAction {
                case "login_success": decision = .proceed
                case "account_disabled": decision = .blacklistCard
                case "wrong_credentials": decision = .switchPattern
                case "captcha_detected": decision = .waitAndRetry
                case "retry_login": decision = .retry
                default: decision = .manualReview
                }

                let result = AIAnalysisResult(
                    decision: decision,
                    confidence: Double(ai.confidence) / 100.0,
                    reasoning: "AI Login: success=\(ai.loginSuccessful) error=\(ai.hasError) disabled=\(ai.accountDisabled) — \(ai.errorText)",
                    suggestedDelay: ai.accountDisabled ? 0 : (decision == .waitAndRetry ? 5.0 : 1.0),
                    fallbackDecision: .retry,
                    metadata: [
                        "aiSuccess": "\(ai.loginSuccessful)",
                        "aiDisabled": "\(ai.accountDisabled)",
                        "aiError": ai.errorText,
                        "username": username
                    ]
                )
                recordDecision(result.decision, context: "login_ai_\(username.prefix(12))")
                return result
            }
        }

        return heuristicLoginDecision(loginOutcome: loginOutcome, username: username)
    }

    func recommendPattern(for url: String, previousAttempts: [(LoginFormPattern, Bool)]) -> LoginFormPattern {
        var scores: [LoginFormPattern: Double] = [:]

        for pattern in LoginFormPattern.allCases {
            let successKey = "\(url)_\(pattern.rawValue)_success"
            let failKey = "\(url)_\(pattern.rawValue)_fail"
            let successes = Double(patternSuccessMap[successKey] ?? 0)
            let failures = Double(patternFailureMap[failKey] ?? 0)
            let total = successes + failures
            if total > 0 {
                scores[pattern] = successes / total
            } else {
                scores[pattern] = 0.5
            }
        }

        for (pattern, succeeded) in previousAttempts {
            let key = pattern
            let current = scores[key] ?? 0.5
            scores[key] = succeeded ? min(1.0, current + 0.15) : max(0, current - 0.2)
        }

        let best = scores.max(by: { $0.value < $1.value })
        let recommended = best?.key ?? .visionMLCoordinate

        logger.log("AICoordinator: pattern recommendation for \(url) → \(recommended.rawValue) (score: \(String(format: "%.2f", best?.value ?? 0)))", category: .automation, level: .debug)
        return recommended
    }

    func recordPatternOutcome(url: String, pattern: LoginFormPattern, succeeded: Bool) {
        let key = "\(url)_\(pattern.rawValue)_\(succeeded ? "success" : "fail")"
        if succeeded {
            patternSuccessMap[key, default: 0] += 1
            consecutiveFailures = 0
            lastSuccessTime = Date()
        } else {
            patternFailureMap[key, default: 0] += 1
            consecutiveFailures += 1
        }
    }

    func computeBatchAnalytics(
        outcomes: [(cardId: String, outcome: CheckOutcome, latencyMs: Int)]
    ) -> BatchAnalytics {
        let total = outcomes.count
        guard total > 0 else {
            return BatchAnalytics(totalProcessed: 0, successRate: 0, avgLatencyMs: 0, failurePatterns: [:], hotCards: [], deadCards: [], suggestedConcurrency: 3)
        }

        let successes = outcomes.filter { $0.outcome == .pass }.count
        let successRate = Double(successes) / Double(total)
        let avgLatency = outcomes.map(\.latencyMs).reduce(0, +) / total

        var failurePatterns: [String: Int] = [:]
        for o in outcomes where o.outcome != .pass {
            let key: String
            switch o.outcome {
            case .failInstitution: key = "institution_decline"
            case .connectionFailure: key = "connection_failure"
            case .timeout: key = "timeout"
            case .uncertain: key = "uncertain"
            default: key = "unknown"
            }
            failurePatterns[key, default: 0] += 1
        }

        let hotCards = outcomes.filter { $0.outcome == .pass }.map(\.cardId)
        let deadCards = outcomes.filter { $0.outcome == .failInstitution }.map(\.cardId)

        let suggestedConcurrency: Int
        if successRate > 0.7 {
            suggestedConcurrency = min(8, 5)
        } else if successRate > 0.4 {
            suggestedConcurrency = 3
        } else {
            suggestedConcurrency = 2
        }

        return BatchAnalytics(
            totalProcessed: total,
            successRate: successRate,
            avgLatencyMs: avgLatency,
            failurePatterns: failurePatterns,
            hotCards: hotCards,
            deadCards: deadCards,
            suggestedConcurrency: suggestedConcurrency
        )
    }

    func shouldThrottle() -> (shouldThrottle: Bool, waitSeconds: Double) {
        if consecutiveFailures >= 5 {
            let backoff = min(30.0, pow(2.0, Double(consecutiveFailures - 4)))
            return (true, backoff)
        }
        return (false, 0)
    }

    func resetState() {
        decisionHistory.removeAll()
        consecutiveFailures = 0
        lastSuccessTime = nil
        patternSuccessMap.removeAll()
        patternFailureMap.removeAll()
    }

    // MARK: - Private

    private func makeLoginDecision(
        detection: VisionMLService.LoginFieldDetection,
        currentPattern: LoginFormPattern,
        attemptNumber: Int,
        sessionId: String
    ) async -> AIAnalysisResult {
        let hasEmail = detection.emailField != nil
        let hasPassword = detection.passwordField != nil
        let hasButton = detection.loginButton != nil

        if hasEmail && hasPassword && hasButton {
            return AIAnalysisResult(
                decision: .proceed,
                confidence: detection.confidence,
                reasoning: "All login elements detected via \(detection.method)",
                suggestedDelay: 0.3,
                fallbackDecision: nil,
                metadata: ["method": detection.method, "aiEnhanced": "\(detection.aiEnhanced)"]
            )
        }

        if hasEmail && hasPassword && !hasButton {
            return AIAnalysisResult(
                decision: .proceed,
                confidence: detection.confidence * 0.8,
                reasoning: "Email+password found, button missing — will use Enter key or form submit",
                suggestedDelay: 0.5,
                fallbackDecision: .switchPattern,
                metadata: ["method": detection.method, "missingButton": "true"]
            )
        }

        if attemptNumber < 3 {
            return AIAnalysisResult(
                decision: .retry,
                confidence: 0.3,
                reasoning: "Insufficient elements detected (\(detection.allText.count) OCR) — retry with page reload",
                suggestedDelay: Double(attemptNumber) * 2.0,
                fallbackDecision: .switchPattern,
                metadata: ["ocrCount": "\(detection.allText.count)", "instances": "\(detection.instanceMaskRegions.count)"]
            )
        }

        if attemptNumber >= 3 {
            return AIAnalysisResult(
                decision: .switchPattern,
                confidence: 0.5,
                reasoning: "Multiple attempts failed — switching interaction pattern",
                suggestedDelay: 3.0,
                fallbackDecision: .deepScan,
                metadata: ["currentPattern": currentPattern.rawValue]
            )
        }

        return AIAnalysisResult(
            decision: .manualReview,
            confidence: 0.1,
            reasoning: "Unable to resolve login elements after exhaustive attempts",
            suggestedDelay: 0,
            fallbackDecision: .abort,
            metadata: [:]
        )
    }

    private func heuristicPPSRDecision(checkOutcome: CheckOutcome, cardId: String) -> AIAnalysisResult {
        switch checkOutcome {
        case .pass:
            return AIAnalysisResult(decision: .proceed, confidence: 0.9, reasoning: "PPSR check passed", suggestedDelay: 0, fallbackDecision: nil, metadata: ["cardId": cardId])
        case .failInstitution:
            consecutiveFailures += 1
            return AIAnalysisResult(decision: consecutiveFailures > 3 ? .blacklistCard : .rotateCard, confidence: 0.8, reasoning: "Institution decline — \(consecutiveFailures) consecutive", suggestedDelay: 2.0, fallbackDecision: .blacklistCard, metadata: ["cardId": cardId])
        case .connectionFailure:
            return AIAnalysisResult(decision: .rotateProxy, confidence: 0.7, reasoning: "Connection failure — rotate proxy/DNS", suggestedDelay: 3.0, fallbackDecision: .waitAndRetry, metadata: ["cardId": cardId])
        case .timeout:
            return AIAnalysisResult(decision: .waitAndRetry, confidence: 0.6, reasoning: "Timeout — exponential backoff", suggestedDelay: 5.0, fallbackDecision: .rotateProxy, metadata: ["cardId": cardId])
        case .uncertain:
            return AIAnalysisResult(decision: .deepScan, confidence: 0.4, reasoning: "Uncertain outcome — needs deep vision scan", suggestedDelay: 1.0, fallbackDecision: .retry, metadata: ["cardId": cardId])
        }
    }

    private func heuristicLoginDecision(loginOutcome: LoginOutcome, username: String) -> AIAnalysisResult {
        switch loginOutcome {
        case .success:
            return AIAnalysisResult(decision: .proceed, confidence: 0.95, reasoning: "Login successful", suggestedDelay: 0, fallbackDecision: nil, metadata: ["username": username])
        case .permDisabled:
            return AIAnalysisResult(decision: .blacklistCard, confidence: 0.9, reasoning: "Account permanently disabled", suggestedDelay: 0, fallbackDecision: nil, metadata: ["username": username])
        case .tempDisabled:
            return AIAnalysisResult(decision: .waitAndRetry, confidence: 0.8, reasoning: "Account temporarily disabled", suggestedDelay: 60.0, fallbackDecision: .abort, metadata: ["username": username])
        case .noAcc:
            return AIAnalysisResult(decision: .blacklistCard, confidence: 0.85, reasoning: "Account does not exist", suggestedDelay: 0, fallbackDecision: nil, metadata: ["username": username])
        case .connectionFailure:
            return AIAnalysisResult(decision: .rotateProxy, confidence: 0.7, reasoning: "Connection failure during login", suggestedDelay: 3.0, fallbackDecision: .waitAndRetry, metadata: ["username": username])
        case .timeout:
            return AIAnalysisResult(decision: .waitAndRetry, confidence: 0.6, reasoning: "Login timeout", suggestedDelay: 5.0, fallbackDecision: .rotateProxy, metadata: ["username": username])
        case .redBannerError:
            return AIAnalysisResult(decision: .switchPattern, confidence: 0.7, reasoning: "Red banner error — try different pattern", suggestedDelay: 2.0, fallbackDecision: .retry, metadata: ["username": username])
        case .smsDetected:
            return AIAnalysisResult(decision: .rotateProxy, confidence: 0.85, reasoning: "SMS notification on Ignition — burn session, rotate IP/webview", suggestedDelay: 2.0, fallbackDecision: .switchPattern, metadata: ["username": username])
        case .unsure:
            return AIAnalysisResult(decision: .deepScan, confidence: 0.3, reasoning: "Unclear login result — deep scan needed", suggestedDelay: 1.0, fallbackDecision: .retry, metadata: ["username": username])
        }
    }

    private func mapAISuggestionToDecision(_ suggestion: String) -> AIDecision {
        switch suggestion {
        case "proceed": return .proceed
        case "retry": return .retry
        case "rotate_card": return .rotateCard
        case "rotate_proxy": return .rotateProxy
        case "rotate_email": return .rotateEmail
        case "blacklist_card": return .blacklistCard
        case "wait_and_retry": return .waitAndRetry
        case "manual_review": return .manualReview
        default: return .retry
        }
    }

    private func delayForDecision(_ decision: AIDecision) -> TimeInterval {
        switch decision {
        case .proceed: return 0.3
        case .retry: return 1.5
        case .rotateCard, .rotateProxy, .rotateEmail: return 2.0
        case .blacklistCard: return 0
        case .waitAndRetry: return 5.0
        case .manualReview: return 0
        case .abort: return 0
        case .switchPattern: return 1.0
        case .deepScan: return 0.5
        }
    }

    private func fallbackForDecision(_ decision: AIDecision) -> AIDecision? {
        switch decision {
        case .retry: return .switchPattern
        case .switchPattern: return .deepScan
        case .deepScan: return .manualReview
        case .waitAndRetry: return .rotateProxy
        case .rotateProxy: return .waitAndRetry
        default: return nil
        }
    }

    private func recordDecision(_ decision: AIDecision, context: String) {
        decisionHistory.append((Date(), decision, context))
        if decisionHistory.count > maxDecisionHistory {
            decisionHistory.removeFirst(decisionHistory.count - maxDecisionHistory)
        }
    }
}
