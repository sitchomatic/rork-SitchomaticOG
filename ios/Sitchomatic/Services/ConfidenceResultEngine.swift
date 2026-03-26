import Foundation
import UIKit
import Vision

@MainActor
class ConfidenceResultEngine {
    static let shared = ConfidenceResultEngine()

    private let logger = DebugLogger.shared
    private let aiAnalyzer = AIConfidenceAnalyzerService.shared

    nonisolated struct ConfidenceResult: Sendable {
        let outcome: LoginOutcome
        let confidence: Double
        let compositeScore: Double
        let signalBreakdown: [SignalContribution]
        let reasoning: String
    }

    nonisolated struct SignalContribution: Sendable {
        let source: String
        let weight: Double
        let rawScore: Double
        let weightedScore: Double
        let detail: String
    }

    func evaluate(
        pageContent: String,
        currentURL: String,
        preLoginURL: String,
        pageTitle: String,
        welcomeTextFound: Bool,
        redirectedToHomepage: Bool,
        navigationDetected: Bool,
        contentChanged: Bool,
        responseTimeMs: Int,
        screenshot: UIImage? = nil,
        httpStatus: Int? = nil
    ) async -> ConfidenceResult {
        var contributions: [SignalContribution] = []

        let textSignal = evaluatePageText(pageContent: pageContent)
        contributions.append(textSignal)

        let urlSignal = evaluateURLChange(currentURL: currentURL, preLoginURL: preLoginURL)
        contributions.append(urlSignal)

        let domSignal = evaluateDOMMarkers(
            welcomeTextFound: welcomeTextFound,
            redirectedToHomepage: redirectedToHomepage,
            navigationDetected: navigationDetected,
            contentChanged: contentChanged
        )
        contributions.append(domSignal)

        let timingSignal = evaluateResponseTiming(responseTimeMs: responseTimeMs)
        contributions.append(timingSignal)

        if let screenshot {
            let ocrSignal = await evaluateScreenshotOCR(screenshot: screenshot)
            contributions.append(ocrSignal)
        }

        let httpSignal = evaluateHTTPStatus(httpStatus: httpStatus)
        contributions.append(httpSignal)

        let host = URL(string: currentURL)?.host ?? currentURL
        if let keywordBoost = aiAnalyzer.learnedKeywordBoost(host: host, pageContent: pageContent) {
            let boostSignal = SignalContribution(
                source: "AI_LEARNED_\(keywordBoost.outcome.uppercased())",
                weight: 0.15,
                rawScore: keywordBoost.boost / 0.15,
                weightedScore: keywordBoost.boost,
                detail: "AI learned keyword boost → \(keywordBoost.outcome)"
            )
            contributions.append(boostSignal)
        }

        let compositeScore = contributions.reduce(0.0) { $0 + $1.weightedScore }

        let successThreshold = 0.55
        let disabledThreshold = 0.4
        let incorrectThreshold = 0.3

        let successScore = contributions.filter { $0.source.hasPrefix("SUCCESS") || $0.detail.contains("success") }.reduce(0.0) { $0 + $1.weightedScore }
        let disabledScore = contributions.filter { $0.detail.contains("disabled") || $0.detail.contains("blocked") || $0.detail.contains("suspended") }.reduce(0.0) { $0 + $1.weightedScore }
        let incorrectScore = contributions.filter { $0.detail.contains("incorrect") || $0.detail.contains("invalid") || $0.detail.contains("wrong") }.reduce(0.0) { $0 + $1.weightedScore }
        let tempScore = contributions.filter { $0.detail.contains("temporarily") || $0.detail.contains("too many") }.reduce(0.0) { $0 + $1.weightedScore }

        var outcome: LoginOutcome
        var confidence: Double
        var reasoning: String

        if tempScore >= disabledThreshold {
            outcome = .tempDisabled
            confidence = min(1.0, tempScore / 0.8)
            reasoning = "TEMP DISABLED — composite temp score \(String(format: "%.2f", tempScore))"
        } else if disabledScore >= disabledThreshold && disabledScore > successScore {
            outcome = .permDisabled
            confidence = min(1.0, disabledScore / 0.8)
            reasoning = "PERM DISABLED — composite disabled score \(String(format: "%.2f", disabledScore))"
        } else if successScore >= successThreshold && successScore > incorrectScore && successScore > disabledScore {
            outcome = .success
            confidence = min(1.0, successScore / 0.8)
            reasoning = "SUCCESS — composite success score \(String(format: "%.2f", successScore))"
        } else if incorrectScore >= incorrectThreshold && incorrectScore > successScore {
            outcome = .noAcc
            confidence = min(1.0, incorrectScore / 0.6)
            reasoning = "NO ACC — composite incorrect score \(String(format: "%.2f", incorrectScore))"
        } else {
            outcome = .noAcc
            confidence = 0.3
            reasoning = "AMBIGUOUS — defaulting to noAcc (success:\(String(format: "%.2f", successScore)) incorrect:\(String(format: "%.2f", incorrectScore)) disabled:\(String(format: "%.2f", disabledScore)))"
        }

        if aiAnalyzer.shouldUseAIFallback(confidence: confidence) {
            let staticOutcomeStr = outcomeToString(outcome)
            logger.log("ConfidenceEngine: LOW CONFIDENCE \(String(format: "%.0f%%", confidence * 100)) — invoking AI fallback for \(host)", category: .evaluation, level: .warning)

            if let aiResult = await aiAnalyzer.analyzeWithAI(
                host: host,
                pageContent: pageContent,
                currentURL: currentURL,
                pageTitle: pageTitle,
                staticOutcome: staticOutcomeStr,
                staticConfidence: confidence
            ) {
                let aiOutcome = stringToOutcome(aiResult.outcome)
                if aiResult.confidence > confidence {
                    outcome = aiOutcome
                    confidence = aiResult.confidence
                    reasoning = "AI OVERRIDE — \(aiResult.reasoning) (static was \(staticOutcomeStr) @ \(String(format: "%.0f%%", confidence * 100)))"

                    let aiSignal = SignalContribution(
                        source: "AI_FALLBACK",
                        weight: 0.20,
                        rawScore: aiResult.confidence,
                        weightedScore: 0.20 * aiResult.confidence,
                        detail: "AI classified as \(aiResult.outcome): \(aiResult.reasoning)"
                    )
                    contributions.append(aiSignal)

                    aiAnalyzer.recordFeedback(
                        host: host,
                        predictedOutcome: aiResult.outcome,
                        actualOutcome: aiResult.outcome,
                        confidence: aiResult.confidence,
                        pageContent: pageContent,
                        newKeywords: aiResult.newKeywords
                    )

                    logger.log("ConfidenceEngine: AI upgraded \(staticOutcomeStr) → \(aiResult.outcome) (\(String(format: "%.0f%%", aiResult.confidence * 100)))", category: .evaluation, level: .success)
                } else {
                    logger.log("ConfidenceEngine: AI agreed with static or lower confidence — keeping \(staticOutcomeStr)", category: .evaluation, level: .debug)
                }
            }
        }

        logger.log("ConfidenceEngine: \(outcome) confidence=\(String(format: "%.0f%%", confidence * 100)) composite=\(String(format: "%.3f", compositeScore)) — \(reasoning)", category: .evaluation, level: outcome == .success ? .success : .info)

        return ConfidenceResult(
            outcome: outcome,
            confidence: confidence,
            compositeScore: compositeScore,
            signalBreakdown: contributions,
            reasoning: reasoning
        )
    }

    func recordOutcomeFeedback(host: String, predictedOutcome: LoginOutcome, actualOutcome: LoginOutcome, confidence: Double, pageContent: String) {
        aiAnalyzer.recordFeedback(
            host: host,
            predictedOutcome: outcomeToString(predictedOutcome),
            actualOutcome: outcomeToString(actualOutcome),
            confidence: confidence,
            pageContent: pageContent
        )
    }

    private func outcomeToString(_ outcome: LoginOutcome) -> String {
        switch outcome {
        case .success: return "success"
        case .permDisabled: return "permDisabled"
        case .tempDisabled: return "tempDisabled"
        case .noAcc: return "noAcc"
        case .unsure: return "unsure"
        case .connectionFailure: return "connectionFailure"
        case .timeout: return "timeout"
        case .redBannerError: return "redBannerError"
        case .smsDetected: return "smsDetected"
        }
    }

    private func stringToOutcome(_ str: String) -> LoginOutcome {
        switch str.lowercased() {
        case "success": return .success
        case "permdisabled": return .permDisabled
        case "tempdisabled": return .tempDisabled
        case "noacc": return .noAcc
        case "unsure": return .unsure
        default: return .noAcc
        }
    }

    private func evaluatePageText(pageContent: String) -> SignalContribution {
        let content = pageContent.lowercased()
        let weight = 0.30

        let successMarkers = ["balance", "wallet", "my account", "logout", "dashboard"]
        let incorrectMarkers = ["incorrect password", "invalid credentials", "wrong password", "invalid email or password", "login failed", "authentication failed", "no account found", "account not found"]
        let disabledMarkers = ["account has been disabled", "account is disabled", "your account has been disabled", "your account is disabled", "account has been suspended", "permanently banned", "has been blocked", "account is closed", "self-excluded"]
        let tempMarkers = ["temporarily", "too many attempts", "try again later", "temporarily locked", "temporarily disabled"]

        for marker in successMarkers {
            if content.contains(marker) {
                return SignalContribution(source: "SUCCESS_TEXT", weight: weight, rawScore: 1.0, weightedScore: weight, detail: "success marker '\(marker)' found")
            }
        }

        for marker in tempMarkers {
            if content.contains(marker) {
                return SignalContribution(source: "TEMP_TEXT", weight: weight, rawScore: 0.9, weightedScore: weight * 0.9, detail: "temporarily blocked '\(marker)'")
            }
        }

        let instantPermDisabled = ["account has been disabled", "account is disabled", "your account has been disabled", "your account is disabled"]
        for marker in instantPermDisabled {
            if content.contains(marker) {
                return SignalContribution(source: "DISABLED_TEXT", weight: weight, rawScore: 1.0, weightedScore: weight * 1.0, detail: "100% perm disabled '\(marker)'")
            }
        }
        for marker in disabledMarkers {
            if content.contains(marker) {
                return SignalContribution(source: "DISABLED_TEXT", weight: weight, rawScore: 0.9, weightedScore: weight * 0.9, detail: "disabled marker '\(marker)'")
            }
        }

        for marker in incorrectMarkers {
            if content.contains(marker) {
                return SignalContribution(source: "INCORRECT_TEXT", weight: weight, rawScore: 0.8, weightedScore: weight * 0.8, detail: "incorrect marker '\(marker)'")
            }
        }

        return SignalContribution(source: "TEXT_NONE", weight: weight, rawScore: 0.0, weightedScore: 0.0, detail: "no text markers found")
    }

    private func evaluateURLChange(currentURL: String, preLoginURL: String) -> SignalContribution {
        let weight = 0.25
        let currentLower = currentURL.lowercased()
        let preLower = preLoginURL.lowercased()

        if !currentLower.contains("/login") && !currentLower.contains("/signin") && currentLower != preLower {
            return SignalContribution(source: "SUCCESS_URL", weight: weight, rawScore: 1.0, weightedScore: weight, detail: "success redirected away from login")
        }
        if currentLower.contains("/login") || currentLower.contains("/signin") {
            return SignalContribution(source: "URL_STILL_LOGIN", weight: weight, rawScore: 0.0, weightedScore: 0.0, detail: "still on login page")
        }
        return SignalContribution(source: "URL_AMBIGUOUS", weight: weight, rawScore: 0.1, weightedScore: weight * 0.1, detail: "url ambiguous")
    }

    private func evaluateDOMMarkers(welcomeTextFound: Bool, redirectedToHomepage: Bool, navigationDetected: Bool, contentChanged: Bool) -> SignalContribution {
        let weight = 0.20
        var raw = 0.0

        if redirectedToHomepage { raw += 0.5 }
        if welcomeTextFound { raw += 0.3 }
        if navigationDetected { raw += 0.1 }
        if contentChanged { raw += 0.1 }
        raw = min(1.0, raw)

        let detail = "welcome=\(welcomeTextFound) redirect=\(redirectedToHomepage) nav=\(navigationDetected) changed=\(contentChanged)"

        if raw >= 0.5 {
            return SignalContribution(source: "SUCCESS_DOM", weight: weight, rawScore: raw, weightedScore: weight * raw, detail: "success \(detail)")
        }
        return SignalContribution(source: "DOM_WEAK", weight: weight, rawScore: raw, weightedScore: weight * raw, detail: detail)
    }

    private func evaluateResponseTiming(responseTimeMs: Int) -> SignalContribution {
        let weight = 0.05
        if responseTimeMs < 1000 {
            return SignalContribution(source: "TIMING_FAST", weight: weight, rawScore: 0.3, weightedScore: weight * 0.3, detail: "fast response \(responseTimeMs)ms — possibly no server processing")
        }
        if responseTimeMs > 30000 {
            return SignalContribution(source: "TIMING_SLOW", weight: weight, rawScore: 0.1, weightedScore: weight * 0.1, detail: "very slow \(responseTimeMs)ms — possible timeout issue")
        }
        return SignalContribution(source: "TIMING_NORMAL", weight: weight, rawScore: 0.5, weightedScore: weight * 0.5, detail: "normal timing \(responseTimeMs)ms")
    }

    private func evaluateScreenshotOCR(screenshot: UIImage) async -> SignalContribution {
        let weight = 0.15
        guard let cgImage = screenshot.cgImage else {
            return SignalContribution(source: "OCR_FAIL", weight: weight, rawScore: 0.0, weightedScore: 0.0, detail: "no cgImage")
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.recognitionLanguages = ["en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return SignalContribution(source: "OCR_ERROR", weight: weight, rawScore: 0.0, weightedScore: 0.0, detail: "OCR failed: \(error.localizedDescription)")
        }

        guard let observations = request.results else {
            return SignalContribution(source: "OCR_EMPTY", weight: weight, rawScore: 0.0, weightedScore: 0.0, detail: "no OCR results")
        }

        let allText = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()

        let successOCR = ["balance", "wallet", "my account", "logout"]
        for term in successOCR {
            if allText.contains(term) {
                return SignalContribution(source: "SUCCESS_OCR", weight: weight, rawScore: 0.9, weightedScore: weight * 0.9, detail: "success OCR '\(term)'")
            }
        }

        let smsOCR = ["sms", "text message", "verification code", "verify your phone", "send code", "enter code", "phone verification"]
        for term in smsOCR {
            if allText.contains(term) {
                return SignalContribution(source: "SMS_OCR", weight: weight, rawScore: 0.85, weightedScore: weight * 0.85, detail: "sms notification OCR '\(term)'")
            }
        }

        let disabledOCR = ["disabled", "suspended", "banned", "blocked", "closed"]
        for term in disabledOCR {
            if allText.contains(term) {
                return SignalContribution(source: "DISABLED_OCR", weight: weight, rawScore: 0.8, weightedScore: weight * 0.8, detail: "disabled OCR '\(term)'")
            }
        }

        let incorrectOCR = ["incorrect", "invalid", "wrong", "failed", "error"]
        for term in incorrectOCR {
            if allText.contains(term) {
                return SignalContribution(source: "INCORRECT_OCR", weight: weight, rawScore: 0.6, weightedScore: weight * 0.6, detail: "incorrect OCR '\(term)'")
            }
        }

        return SignalContribution(source: "OCR_NONE", weight: weight, rawScore: 0.0, weightedScore: 0.0, detail: "no OCR signals")
    }

    private func evaluateHTTPStatus(httpStatus: Int?) -> SignalContribution {
        let weight = 0.05
        guard let status = httpStatus else {
            return SignalContribution(source: "HTTP_NONE", weight: weight, rawScore: 0.0, weightedScore: 0.0, detail: "no HTTP status")
        }
        if status >= 200 && status < 300 {
            return SignalContribution(source: "HTTP_OK", weight: weight, rawScore: 0.5, weightedScore: weight * 0.5, detail: "HTTP \(status)")
        }
        if status == 429 {
            return SignalContribution(source: "HTTP_429", weight: weight, rawScore: 0.0, weightedScore: 0.0, detail: "rate limited HTTP 429")
        }
        if status >= 500 {
            return SignalContribution(source: "HTTP_5XX", weight: weight, rawScore: 0.0, weightedScore: 0.0, detail: "server error HTTP \(status)")
        }
        return SignalContribution(source: "HTTP_OTHER", weight: weight, rawScore: 0.2, weightedScore: weight * 0.2, detail: "HTTP \(status)")
    }
}
