import Foundation
import WebKit
import UIKit
import Vision

@MainActor
class ChallengePageClassifier {
    static let shared = ChallengePageClassifier()

    private let logger = DebugLogger.shared
    private let aiSolver = AIChallengePageSolverService.shared

    nonisolated enum ChallengeType: String, Sendable {
        case none
        case rateLimit
        case captcha
        case temporaryBlock
        case accountDisabled
        case maintenance
        case jsFailed
        case cloudflareChallenge
        case unknown
    }

    nonisolated struct ClassificationResult: Sendable {
        let type: ChallengeType
        let confidence: Double
        let signals: [String]
        let suggestedAction: SuggestedAction
        let aiBypassRecommendation: AIBypassRecommendation?
    }

    nonisolated enum SuggestedAction: String, Sendable {
        case proceed
        case waitAndRetry
        case rotateProxy
        case rotateURL
        case abort
        case switchNetwork
    }

    func classify(
        session: LoginSiteWebSession,
        screenshot: UIImage? = nil
    ) async -> ClassificationResult {
        var signals: [String] = []
        var scores: [ChallengeType: Double] = [:]

        let pageContent = await session.getPageContent() ?? ""
        let contentLower = pageContent.lowercased()
        let currentURL = await session.getCurrentURL()
        let httpStatus = session.lastHTTPStatusCode

        classifyFromDOM(contentLower: contentLower, url: currentURL, signals: &signals, scores: &scores)
        classifyFromHTTPStatus(httpStatus: httpStatus, signals: &signals, scores: &scores)
        classifyFromURL(url: currentURL, signals: &signals, scores: &scores)

        if let screenshot {
            await classifyFromOCR(screenshot: screenshot, signals: &signals, scores: &scores)
        }

        classifyJSHealth(contentLower: contentLower, pageLength: pageContent.count, signals: &signals, scores: &scores)

        let bestType = scores.max(by: { $0.value < $1.value })
        let finalType = bestType?.value ?? 0 >= 0.3 ? (bestType?.key ?? .none) : .none
        let confidence = bestType?.value ?? 0

        let action = suggestedAction(for: finalType)

        var aiRecommendation: AIBypassRecommendation? = nil
        if finalType != .none {
            logger.log("ChallengeClassifier: detected \(finalType.rawValue) (confidence: \(String(format: "%.0f%%", confidence * 100))) — \(signals.prefix(3).joined(separator: ", "))", category: .evaluation, level: .warning)

            let host = extractHost(from: currentURL)
            if !aiSolver.isHostInCooldown(host) {
                aiRecommendation = await aiSolver.recommendBypass(
                    host: host,
                    challengeType: finalType,
                    signals: signals,
                    confidence: confidence,
                    pageContent: pageContent
                )
            } else {
                logger.log("ChallengeClassifier: host \(host) in AI cooldown (\(Int(aiSolver.cooldownRemaining(host)))s remaining)", category: .evaluation, level: .info)
            }
        }

        return ClassificationResult(type: finalType, confidence: confidence, signals: signals, suggestedAction: action, aiBypassRecommendation: aiRecommendation)
    }

    private func classifyFromDOM(contentLower: String, url: String, signals: inout [String], scores: inout [ChallengeType: Double]) {
        let rateLimitTerms: [(String, Double)] = [
            ("rate limit", 0.8), ("too many requests", 0.9), ("429", 0.7),
            ("slow down", 0.6), ("request limit", 0.7), ("throttled", 0.7),
            ("too many attempts", 0.75), ("exceeded.*limit", 0.7),
        ]
        for (term, weight) in rateLimitTerms {
            if contentLower.contains(term) {
                scores[.rateLimit, default: 0] += weight
                signals.append("DOM_RATE_LIMIT: '\(term)'")
            }
        }

        let captchaTerms: [(String, Double)] = [
            ("captcha", 0.9), ("recaptcha", 0.95), ("hcaptcha", 0.95),
            ("verify you are human", 0.9), ("verify you're human", 0.9),
            ("i'm not a robot", 0.85), ("challenge-platform", 0.8),
            ("turnstile", 0.85), ("cf-turnstile", 0.9),
            ("g-recaptcha", 0.95), ("data-sitekey", 0.85),
        ]
        for (term, weight) in captchaTerms {
            if contentLower.contains(term) {
                scores[.captcha, default: 0] += weight
                signals.append("DOM_CAPTCHA: '\(term)'")
            }
        }

        let blockTerms: [(String, Double)] = [
            ("access denied", 0.8), ("forbidden", 0.7), ("blocked", 0.6),
            ("ip.*blocked", 0.85), ("your ip", 0.5), ("temporarily blocked", 0.85),
            ("banned", 0.7), ("blacklisted", 0.75),
        ]
        for (term, weight) in blockTerms {
            if contentLower.contains(term) {
                scores[.temporaryBlock, default: 0] += weight
                signals.append("DOM_BLOCK: '\(term)'")
            }
        }

        let disabledTerms: [(String, Double)] = [
            ("account.*disabled", 0.9), ("account.*suspended", 0.9),
            ("account.*closed", 0.85), ("permanently.*disabled", 0.95),
            ("self-excluded", 0.8), ("contact customer", 0.5),
        ]
        for (term, weight) in disabledTerms {
            if contentLower.contains(term) {
                scores[.accountDisabled, default: 0] += weight
                signals.append("DOM_DISABLED: '\(term)'")
            }
        }

        let maintenanceTerms: [(String, Double)] = [
            ("maintenance", 0.8), ("under maintenance", 0.9),
            ("temporarily unavailable", 0.8), ("be right back", 0.6),
            ("scheduled maintenance", 0.9), ("service unavailable", 0.7),
            ("site is down", 0.8), ("experiencing issues", 0.5),
        ]
        for (term, weight) in maintenanceTerms {
            if contentLower.contains(term) {
                scores[.maintenance, default: 0] += weight
                signals.append("DOM_MAINTENANCE: '\(term)'")
            }
        }

        let cloudflarTerms: [(String, Double)] = [
            ("cloudflare", 0.7), ("checking your browser", 0.85),
            ("ray id", 0.8), ("please wait", 0.3),
            ("just a moment", 0.7), ("ddos protection", 0.8),
            ("performance & security by cloudflare", 0.9),
        ]
        for (term, weight) in cloudflarTerms {
            if contentLower.contains(term) {
                scores[.cloudflareChallenge, default: 0] += weight
                signals.append("DOM_CF: '\(term)'")
            }
        }
    }

    private func classifyFromHTTPStatus(httpStatus: Int?, signals: inout [String], scores: inout [ChallengeType: Double]) {
        guard let status = httpStatus else { return }
        switch status {
        case 429:
            scores[.rateLimit, default: 0] += 0.9
            signals.append("HTTP_429")
        case 403:
            scores[.temporaryBlock, default: 0] += 0.6
            signals.append("HTTP_403")
        case 503:
            scores[.maintenance, default: 0] += 0.5
            signals.append("HTTP_503")
        case 502:
            scores[.maintenance, default: 0] += 0.4
            signals.append("HTTP_502")
        case 500:
            scores[.maintenance, default: 0] += 0.3
            signals.append("HTTP_500")
        default:
            break
        }
    }

    private func classifyFromURL(url: String, signals: inout [String], scores: inout [ChallengeType: Double]) {
        let urlLower = url.lowercased()
        if urlLower.contains("challenge") || urlLower.contains("captcha") {
            scores[.captcha, default: 0] += 0.6
            signals.append("URL_CHALLENGE")
        }
        if urlLower.contains("blocked") || urlLower.contains("denied") {
            scores[.temporaryBlock, default: 0] += 0.5
            signals.append("URL_BLOCKED")
        }
        if urlLower.contains("maintenance") || urlLower.contains("down") {
            scores[.maintenance, default: 0] += 0.5
            signals.append("URL_MAINTENANCE")
        }
    }

    private func classifyFromOCR(screenshot: UIImage, signals: inout [String], scores: inout [ChallengeType: Double]) async {
        guard let cgImage = screenshot.cgImage else { return }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.recognitionLanguages = ["en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return
        }

        guard let observations = request.results else { return }

        let allText = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()

        let ocrCaptchaTerms = ["captcha", "verify", "human", "robot", "challenge"]
        for term in ocrCaptchaTerms {
            if allText.contains(term) {
                scores[.captcha, default: 0] += 0.4
                signals.append("OCR_CAPTCHA: '\(term)'")
            }
        }

        let ocrBlockTerms = ["blocked", "denied", "forbidden", "banned"]
        for term in ocrBlockTerms {
            if allText.contains(term) {
                scores[.temporaryBlock, default: 0] += 0.4
                signals.append("OCR_BLOCK: '\(term)'")
            }
        }

        let ocrMaintenanceTerms = ["maintenance", "unavailable", "down"]
        for term in ocrMaintenanceTerms {
            if allText.contains(term) {
                scores[.maintenance, default: 0] += 0.3
                signals.append("OCR_MAINTENANCE: '\(term)'")
            }
        }
    }

    private func classifyJSHealth(contentLower: String, pageLength: Int, signals: inout [String], scores: inout [ChallengeType: Double]) {
        if pageLength < 100 {
            scores[.jsFailed, default: 0] += 0.5
            signals.append("JS_TINY_PAGE: \(pageLength) chars")
        }
        if contentLower.contains("javascript is required") || contentLower.contains("enable javascript") {
            scores[.jsFailed, default: 0] += 0.8
            signals.append("JS_REQUIRED")
        }
        if contentLower.contains("noscript") && pageLength < 500 {
            scores[.jsFailed, default: 0] += 0.4
            signals.append("JS_NOSCRIPT_ONLY")
        }
    }

    private func extractHost(from url: String) -> String {
        URL(string: url)?.host ?? url
    }

    private func suggestedAction(for type: ChallengeType) -> SuggestedAction {
        switch type {
        case .none: return .proceed
        case .rateLimit: return .waitAndRetry
        case .captcha: return .rotateProxy
        case .temporaryBlock: return .switchNetwork
        case .accountDisabled: return .abort
        case .maintenance: return .waitAndRetry
        case .jsFailed: return .rotateURL
        case .cloudflareChallenge: return .rotateProxy
        case .unknown: return .waitAndRetry
        }
    }
}
