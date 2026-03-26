import Foundation
import UIKit

#if canImport(FoundationModels)
import FoundationModels
#endif

nonisolated struct AIAnalysisPPSRResult: Sendable {
    let passed: Bool
    let declined: Bool
    let summary: String
    let confidence: Int
    let errorType: String
    let suggestedAction: String
}

nonisolated struct AIAnalysisLoginResult: Sendable {
    let loginSuccessful: Bool
    let hasError: Bool
    let errorText: String
    let accountDisabled: Bool
    let suggestedAction: String
    let confidence: Int
}

nonisolated struct AIFieldMappingResult: Sendable {
    let emailLabels: [String]
    let passwordLabels: [String]
    let buttonLabels: [String]
    let isStandard: Bool
    let confidence: Int
}

nonisolated struct AIFlowPredictionResult: Sendable {
    let nextAction: String
    let reason: String
    let shouldContinue: Bool
    let riskLevel: String
}

@MainActor
class OnDeviceAIService {
    static let shared = OnDeviceAIService()

    private let logger = DebugLogger.shared

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    func analyzePPSRResponse(pageContent: String) async -> AIAnalysisPPSRResult? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        guard SystemLanguageModel.default.isAvailable else {
            logger.log("OnDeviceAI: model not available on this device", category: .automation, level: .warning)
            return nil
        }

        let truncated = String(pageContent.prefix(2000))

        do {
            logger.log("OnDeviceAI: analyzing PPSR response (\(truncated.count) chars)", category: .automation, level: .debug)
            let session = LanguageModelSession(
                instructions: "You analyze PPSR vehicle check responses from Australia. Determine if the check passed or payment was declined. Respond with JSON containing: passed (bool), declined (bool), summary (string), confidence (0-100), errorType (string), suggestedAction (string)."
            )
            let response = try await session.respond(to: "Analyze this PPSR response:\n\n\(truncated)")
            let text = response.content

            let result = parseAIPPSRResponse(text, pageContent: truncated)
            logger.log("OnDeviceAI: PPSR analysis — passed:\(result.passed) declined:\(result.declined) confidence:\(result.confidence)%", category: .automation, level: result.passed ? .success : .warning)
            return result
        } catch {
            logger.logError("OnDeviceAI: PPSR analysis failed", error: error, category: .automation)
            return nil
        }
        #else
        return nil
        #endif
    }

    func analyzeLoginPage(pageContent: String, ocrTexts: [String]) async -> AIAnalysisLoginResult? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        guard SystemLanguageModel.default.isAvailable else { return nil }

        let truncatedContent = String(pageContent.prefix(1500))
        let ocrSummary = ocrTexts.prefix(30).joined(separator: " | ")

        do {
            let session = LanguageModelSession(
                instructions: "You analyze login pages for gambling/casino websites. Determine if login was successful, if errors are present, or if the account is disabled. Respond with JSON containing: loginSuccessful (bool), hasError (bool), errorText (string), accountDisabled (bool), suggestedAction (string), confidence (0-100)."
            )
            let prompt = "Page content:\n\(truncatedContent)\n\nOCR text:\n\(ocrSummary)"
            let response = try await session.respond(to: prompt)
            return parseAILoginResponse(response.content, pageContent: truncatedContent)
        } catch {
            logger.logError("OnDeviceAI: login analysis failed", error: error, category: .automation)
            return nil
        }
        #else
        return nil
        #endif
    }

    func mapOCRToFields(ocrTexts: [String]) async -> AIFieldMappingResult? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        guard SystemLanguageModel.default.isAvailable else { return nil }

        let textList = ocrTexts.prefix(40).joined(separator: "\n")

        do {
            let session = LanguageModelSession(
                instructions: "You analyze OCR text from login page screenshots. Identify email/username field labels, password field labels, and login button labels. Respond with JSON containing: emailFieldLabels ([string]), passwordFieldLabels ([string]), loginButtonLabels ([string]), isStandardLayout (bool), confidence (0-100)."
            )
            let response = try await session.respond(to: "Identify login form elements:\n\(textList)")
            return parseAIFieldMapping(response.content, ocrTexts: ocrTexts)
        } catch {
            logger.logError("OnDeviceAI: OCR field mapping failed", error: error, category: .automation)
            return nil
        }
        #else
        return nil
        #endif
    }

    func predictFlowOutcome(currentStep: String, pageContent: String, previousActions: [String]) async -> AIFlowPredictionResult? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        guard SystemLanguageModel.default.isAvailable else { return nil }

        let truncated = String(pageContent.prefix(1000))
        let recentActions = previousActions.suffix(5).joined(separator: "\n")

        do {
            let session = LanguageModelSession(
                instructions: "You predict next steps in automated web flows. Consider captchas, rate limiting, and errors. Respond with JSON: nextAction (string), reason (string), shouldContinue (bool), riskLevel (string)."
            )
            let prompt = "Current step: \(currentStep)\nRecent actions:\n\(recentActions)\nPage content:\n\(truncated)"
            let response = try await session.respond(to: prompt)
            return parseAIFlowPrediction(response.content)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    func generateVariantEmail(base: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        guard SystemLanguageModel.default.isAvailable else { return nil }

        do {
            let session = LanguageModelSession(
                instructions: "Generate a slight variation of the given email address using dot tricks or plus addressing. Return only the email."
            )
            let response = try await session.respond(to: "Create a variant of: \(base)")
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: - Response Parsing Fallbacks

    private func parseAIPPSRResponse(_ text: String, pageContent: String) -> AIAnalysisPPSRResult {
        let lower = text.lowercased()
        let contentLower = pageContent.lowercased()

        let passed = lower.contains("passed") || lower.contains("\"passed\": true") || lower.contains("\"passed\":true")
        let declined = lower.contains("declined") || lower.contains("\"declined\": true") || contentLower.contains("institution")

        let errorType: String
        if contentLower.contains("institution") { errorType = "institution_decline" }
        else if contentLower.contains("expired") { errorType = "expired_card" }
        else if contentLower.contains("insufficient") { errorType = "insufficient_funds" }
        else if declined { errorType = "institution_decline" }
        else { errorType = "none" }

        let suggestedAction: String
        if passed { suggestedAction = "proceed" }
        else if declined { suggestedAction = "rotate_card" }
        else { suggestedAction = "retry" }

        let confidence = (passed || declined) ? 75 : 40

        return AIAnalysisPPSRResult(
            passed: passed && !declined,
            declined: declined,
            summary: String(text.prefix(200)),
            confidence: confidence,
            errorType: errorType,
            suggestedAction: suggestedAction
        )
    }

    private func parseAILoginResponse(_ text: String, pageContent: String) -> AIAnalysisLoginResult {
        let lower = text.lowercased()
        let contentLower = pageContent.lowercased()

        let success = lower.contains("successful") || lower.contains("\"loginsuccessful\": true")
        let hasError = lower.contains("error") || contentLower.contains("incorrect") || contentLower.contains("invalid")
        let disabledPhrases = [
            "disabled", "blocked", "suspended", "banned", "locked",
            "deactivated", "restricted", "closed", "self-excluded",
            "account has been disabled", "has been disabled",
            "contact customer service", "contact support",
            "permanently banned", "blacklisted",
        ]
        let disabled = disabledPhrases.contains { contentLower.contains($0) || lower.contains($0) }

        let suggestedAction: String
        if success { suggestedAction = "login_success" }
        else if disabled { suggestedAction = "account_disabled" }
        else if hasError { suggestedAction = "wrong_credentials" }
        else { suggestedAction = "unknown" }

        return AIAnalysisLoginResult(
            loginSuccessful: success && !hasError,
            hasError: hasError,
            errorText: hasError ? String(text.prefix(100)) : "",
            accountDisabled: disabled,
            suggestedAction: suggestedAction,
            confidence: (success || disabled) ? 70 : 40
        )
    }

    private func parseAIFieldMapping(_ text: String, ocrTexts: [String]) -> AIFieldMappingResult {
        let emailKeywords = ["email", "username", "user name", "e-mail", "email address"]
        let passKeywords = ["password", "pass", "pin"]
        let buttonKeywords = ["log in", "login", "sign in", "submit", "enter"]

        let emailLabels = ocrTexts.filter { t in emailKeywords.contains(where: { t.lowercased().contains($0) }) }
        let passLabels = ocrTexts.filter { t in passKeywords.contains(where: { t.lowercased().contains($0) }) }
        let btnLabels = ocrTexts.filter { t in buttonKeywords.contains(where: { t.lowercased().contains($0) }) }

        return AIFieldMappingResult(
            emailLabels: emailLabels,
            passwordLabels: passLabels,
            buttonLabels: btnLabels,
            isStandard: !emailLabels.isEmpty && !passLabels.isEmpty,
            confidence: (!emailLabels.isEmpty && !passLabels.isEmpty) ? 70 : 30
        )
    }

    private func parseAIFlowPrediction(_ text: String) -> AIFlowPredictionResult {
        let lower = text.lowercased()
        let nextAction: String
        if lower.contains("click") { nextAction = "click" }
        else if lower.contains("type") { nextAction = "type" }
        else if lower.contains("wait") { nextAction = "wait" }
        else if lower.contains("submit") { nextAction = "submit" }
        else { nextAction = "unknown" }

        let shouldContinue = !lower.contains("abort") && !lower.contains("stop") && !lower.contains("critical")
        let riskLevel: String
        if lower.contains("critical") { riskLevel = "critical" }
        else if lower.contains("high") { riskLevel = "high" }
        else if lower.contains("medium") { riskLevel = "medium" }
        else { riskLevel = "low" }

        return AIFlowPredictionResult(
            nextAction: nextAction,
            reason: String(text.prefix(200)),
            shouldContinue: shouldContinue,
            riskLevel: riskLevel
        )
    }
}
