import Foundation
import UIKit
import WebKit

@MainActor
class BPointAutomationEngine {
    private var activeSessions: Int = 0
    let maxConcurrency: Int = 8
    var debugMode: Bool = false
    var stealthEnabled: Bool = false
    var speedMultiplier: Double = 1.0
    var screenshotCropRect: CGRect = .zero
    private let logger = DebugLogger.shared
    private let billerPool = BPointBillerPoolService.shared
    var onScreenshot: ((PPSRDebugScreenshot) -> Void)?
    var onConnectionFailure: ((String) -> Void)?
    var onUnusualFailure: ((String) -> Void)?
    var onLog: ((String, PPSRLogEntry.Level) -> Void)?
    var onBillerBlacklisted: ((String, String) -> Void)?
    private let dohService = PPSRDoHService.shared
    private let networkFactory = NetworkSessionFactory.shared

    var canStartSession: Bool { activeSessions < maxConcurrency }

    func runPreTestNetworkCheck() async -> (passed: Bool, detail: String) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        let urlSession = URLSession(configuration: config)
        defer { urlSession.invalidateAndCancel() }

        var request = URLRequest(url: BPointBillerPoolService.billerLookupURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await urlSession.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode < 500 { return (true, "BPoint pre-test OK: HTTP \(http.statusCode)") }
                return (false, "BPoint pre-test failed: HTTP \(http.statusCode)")
            }
            return (true, "BPoint pre-test OK")
        } catch {
            return (false, "BPoint pre-test failed: \(error.localizedDescription)")
        }
    }

    func runCheck(_ check: PPSRCheck, chargeAmount: Double, timeout: TimeInterval = 90, skipPreTest: Bool = false) async -> CheckOutcome {
        let timeout = TimeoutResolver.resolveAutomationTimeout(timeout)
        activeSessions += 1
        defer { activeSessions -= 1 }

        let sessionId = "bpoint_\(check.card.displayNumber.suffix(8))_\(UUID().uuidString.prefix(6))"
        check.startedAt = Date()

        logger.startSession(sessionId, category: .ppsr, message: "Starting BPoint pool check for \(check.card.brand) \(check.card.displayNumber) — $\(String(format: "%.2f", chargeAmount))")
        logger.log("Config: timeout=\(Int(timeout))s stealth=\(stealthEnabled) amount=$\(String(format: "%.2f", chargeAmount)) pool=\(billerPool.activeBillerCount)/\(billerPool.totalBillerCount)", category: .ppsr, level: .debug, sessionId: sessionId)

        if !skipPreTest {
            let preCheck = await runPreTestNetworkCheck()
            if !preCheck.passed {
                check.logs.append(PPSRLogEntry(message: "PRE-TEST FAILED: \(preCheck.detail)", level: .error))
                failCheck(check, message: "Pre-test network check failed: \(preCheck.detail)")
                onConnectionFailure?(preCheck.detail)
                return .connectionFailure
            }
            check.logs.append(PPSRLogEntry(message: preCheck.detail, level: .success))
        }

        guard !billerPool.poolExhausted else {
            failCheck(check, message: "Biller pool exhausted — all billers blacklisted")
            onUnusualFailure?("BPoint biller pool exhausted")
            return .connectionFailure
        }

        let session = BPointWebSession()
        session.stealthEnabled = stealthEnabled
        session.speedMultiplier = speedMultiplier
        session.blockImages = speedMultiplier <= 0.5
        session.networkConfig = networkFactory.appWideConfig(for: .ppsr)

        session.onFingerprintLog = { [weak self] msg, level in
            check.logs.append(PPSRLogEntry(message: msg, level: level))
            self?.onLog?(msg, level)
        }
        session.setUp()
        defer {
            session.tearDown()
            logger.log("BPoint session tearDown", category: .webView, level: .trace, sessionId: sessionId)
        }

        logger.startTimer(key: sessionId)
        let deadline = Date().addingTimeInterval(timeout)
        let outcome: CheckOutcome = await performBPointPoolCheck(session: session, check: check, chargeAmount: chargeAmount, sessionId: sessionId, deadline: deadline)
        let totalMs = logger.stopTimer(key: sessionId)

        if outcome == .timeout {
            check.status = .failed
            check.errorMessage = "BPoint test timed out after \(Int(timeout))s"
            check.completedAt = Date()
            check.logs.append(PPSRLogEntry(message: "TIMEOUT: BPoint test exceeded \(Int(timeout))s limit", level: .warning))
            logger.log("TIMEOUT after \(Int(timeout))s for \(check.card.displayNumber)", category: .ppsr, level: .error, sessionId: sessionId, durationMs: totalMs)
            onUnusualFailure?("BPoint timeout for \(check.card.displayNumber)")
        }

        logger.endSession(sessionId, category: .ppsr, message: "BPoint check COMPLETE: \(outcome) for \(check.card.displayNumber)", level: outcome == .pass ? .success : outcome == .failInstitution ? .warning : .error)
        return outcome
    }

    private func isTimedOut(_ deadline: Date) -> Bool {
        Date() >= deadline
    }

    private func performBPointPoolCheck(session: BPointWebSession, check: PPSRCheck, chargeAmount: Double, sessionId: String, deadline: Date) async -> CheckOutcome {
        let amountStr = String(format: "%.2f", chargeAmount)
        let isVisa = check.card.number.hasPrefix("4")
        let brandName = isVisa ? "Visa" : "Mastercard"
        var billerAttempt = 0
        let maxBillerAttempts = min(billerPool.activeBillerCount, 50)
        var triedBillers: Set<String> = []

        while billerAttempt < maxBillerAttempts && !isTimedOut(deadline) {
            billerAttempt += 1

            guard let billerCode = billerPool.getRandomActiveBiller() else {
                check.logs.append(PPSRLogEntry(message: "Pool exhausted after \(billerAttempt - 1) attempts", level: .error))
                failCheck(check, message: "Biller pool exhausted")
                return .connectionFailure
            }

            if triedBillers.contains(billerCode) { continue }
            triedBillers.insert(billerCode)

            check.logs.append(PPSRLogEntry(message: "Biller attempt \(billerAttempt): code \(billerCode)", level: .info))
            logger.log("Phase: BILLER ATTEMPT \(billerAttempt) — code \(billerCode)", category: .automation, level: .info, sessionId: sessionId)

            advanceTo(.fillingVIN, check: check, message: "Loading biller lookup page (attempt \(billerAttempt))...")

            if stealthEnabled && billerAttempt == 1 {
                await performDoHPreflight(check: check, sessionId: sessionId)
            }

            var loaded = false
            for loadAttempt in 1...2 {
                if billerAttempt == 1 && loadAttempt == 1 {
                    loaded = await session.loadBillerLookupPage(timeout: AutomationSettings.minimumTimeoutSeconds)
                } else {
                    session.tearDown()
                    session.stealthEnabled = stealthEnabled
                    session.speedMultiplier = speedMultiplier
                    session.blockImages = speedMultiplier <= 0.5
                    session.setUp()
                    loaded = await session.loadBillerLookupPage(timeout: AutomationSettings.minimumTimeoutSeconds)
                }
                if loaded { break }
                check.logs.append(PPSRLogEntry(message: "Lookup page load attempt \(loadAttempt)/2 failed", level: .warning))
            }

            guard loaded else {
                let errorDetail = session.lastNavigationError ?? "Unknown error"
                check.logs.append(PPSRLogEntry(message: "Failed to load biller lookup page — \(errorDetail)", level: .error))
                if billerAttempt == 1 {
                    failCheck(check, message: "FATAL: Failed to load biller lookup page — \(errorDetail)")
                    onConnectionFailure?("BPoint lookup page failed: \(errorDetail)")
                    return .connectionFailure
                }
                continue
            }

            guard !isTimedOut(deadline) else { return .timeout }
            await speedDelay(seconds: 1)

            advanceTo(.fillingVIN, check: check, message: "Entering biller code: \(billerCode)")
            let searchResult = await session.enterBillerCodeAndSearch(billerCode)
            if !searchResult.success {
                check.logs.append(PPSRLogEntry(message: "Biller search failed: \(searchResult.detail)", level: .warning))
                blacklistBiller(billerCode, reason: "Biller search failed: \(searchResult.detail)")
                continue
            }
            check.logs.append(PPSRLogEntry(message: "Biller search: \(searchResult.detail)", level: .success))

            guard !isTimedOut(deadline) else { return .timeout }

            let contentChanged = await session.waitForContentChange(timeout: 10)
            if !contentChanged {
                check.logs.append(PPSRLogEntry(message: "No content change after biller search — blacklisting \(billerCode)", level: .warning))
                blacklistBiller(billerCode, reason: "No content change after search")
                continue
            }
            await speedDelay(seconds: 1.5)

            let validationCheck1 = await session.checkForValidationErrors()
            if validationCheck1.hasErrors {
                check.logs.append(PPSRLogEntry(message: "Validation errors on biller form: \(validationCheck1.detail) — blacklisting \(billerCode)", level: .warning))
                blacklistBiller(billerCode, reason: "Form validation error: \(validationCheck1.detail)")
                continue
            }

            guard !isTimedOut(deadline) else { return .timeout }

            advanceTo(.submittingSearch, check: check, message: "Auto-filling form fields for biller \(billerCode)...")
            let fillResult = await session.fillAllFormFields(amount: amountStr)
            if !fillResult.success {
                check.logs.append(PPSRLogEntry(message: "Form fill failed: \(fillResult.detail) — blacklisting \(billerCode)", level: .warning))
                blacklistBiller(billerCode, reason: "Form fill failed: \(fillResult.detail)")
                continue
            }
            check.logs.append(PPSRLogEntry(message: "Form filled: \(fillResult.detail)", level: .success))

            await speedDelay(seconds: 1)

            let validationCheck2 = await session.checkForValidationErrors()
            if validationCheck2.hasErrors {
                check.logs.append(PPSRLogEntry(message: "Post-fill validation errors: \(validationCheck2.detail) — blacklisting \(billerCode)", level: .warning))
                blacklistBiller(billerCode, reason: "Post-fill validation: \(validationCheck2.detail)")
                continue
            }

            guard !isTimedOut(deadline) else { return .timeout }

            advanceTo(.submittingSearch, check: check, message: "Selecting card brand: \(brandName)")
            logger.log("Phase: SELECT CARD BRAND — \(brandName)", category: .automation, level: .info, sessionId: sessionId)

            var brandClicked = false
            for attempt in 1...3 {
                let brandResult = await session.clickCardBrandLogo(isVisa: isVisa)
                if brandResult.success {
                    check.logs.append(PPSRLogEntry(message: "\(brandName) selected: \(brandResult.detail)", level: .success))
                    brandClicked = true
                    break
                }
                check.logs.append(PPSRLogEntry(message: "\(brandName) click attempt \(attempt)/3 failed: \(brandResult.detail)", level: .warning))
                if attempt < 3 { await speedDelay(seconds: 1) }
            }

            if !brandClicked {
                check.logs.append(PPSRLogEntry(message: "Could not click \(brandName) logo — attempting to proceed anyway", level: .warning))
            }

            guard !isTimedOut(deadline) else { return .timeout }
            await speedDelay(seconds: 2)

            let remainingForNav = max(5, deadline.timeIntervalSinceNow - 5)
            let navigated = await waitForBPointNavigation(session: session, timeout: min(TimeoutResolver.resolveAutomationTimeout(15), remainingForNav))
            if navigated {
                check.logs.append(PPSRLogEntry(message: "Navigated to payment page after brand selection", level: .success))
            } else {
                check.logs.append(PPSRLogEntry(message: "No navigation after brand click — checking if payment fields visible", level: .warning))
            }

            guard !isTimedOut(deadline) else { return .timeout }
            await speedDelay(seconds: 2)

            let emailDetected = await session.detectEmailFieldOnPaymentPage()
            if emailDetected {
                check.logs.append(PPSRLogEntry(message: "Email field detected on payment page — blacklisting \(billerCode)", level: .warning))
                blacklistBiller(billerCode, reason: "Email field required on payment page")
                continue
            }

            let validationCheck3 = await session.checkForValidationErrors()
            if validationCheck3.hasErrors {
                check.logs.append(PPSRLogEntry(message: "Payment page has validation errors: \(validationCheck3.detail) — blacklisting \(billerCode)", level: .warning))
                blacklistBiller(billerCode, reason: "Payment page errors: \(validationCheck3.detail)")
                continue
            }

            check.logs.append(PPSRLogEntry(message: "Biller \(billerCode) passed all checks — proceeding to card entry", level: .success))
            await captureScreenshotForCheck(session: session, check: check, step: "payment_page", note: "Payment page loaded (biller \(billerCode))", autoResult: .unknown)

            return await performCardEntryAndSubmit(session: session, check: check, sessionId: sessionId, deadline: deadline)
        }

        if isTimedOut(deadline) { return .timeout }

        failCheck(check, message: "All biller attempts exhausted (\(billerAttempt) tried)")
        onUnusualFailure?("BPoint all \(billerAttempt) biller attempts failed for \(check.card.displayNumber)")
        return .connectionFailure
    }

    private func performCardEntryAndSubmit(session: BPointWebSession, check: PPSRCheck, sessionId: String, deadline: Date) async -> CheckOutcome {
        logger.log("Phase: FILL PAYMENT DETAILS", category: .automation, level: .info, sessionId: sessionId)
        advanceTo(.enteringPayment, check: check, message: "Filling card: \(check.card.brand) \(check.card.displayNumber)")

        guard !isTimedOut(deadline) else { return .timeout }
        let cardResult = await retryFill(session: session, check: check, fieldName: "Card Number") {
            await session.fillCardNumber(check.card.number)
        }
        guard cardResult else {
            await captureScreenshotForCheck(session: session, check: check, step: "card_fill_failed", note: "Card fill failed", autoResult: .unsure)
            return .connectionFailure
        }
        await speedDelay(milliseconds: 300)

        let expiryStr = "\(check.expiryMonth)/\(check.expiryYear)"
        let expiryResult = await session.fillExpiry(expiryStr)
        if expiryResult.success {
            check.logs.append(PPSRLogEntry(message: "Expiry filled as combined: \(expiryStr)", level: .success))
        } else {
            let monthResult = await retryFill(session: session, check: check, fieldName: "Exp Month") {
                await session.fillExpMonth(check.expiryMonth)
            }
            guard monthResult else { return .connectionFailure }

            let yearResult = await retryFill(session: session, check: check, fieldName: "Exp Year") {
                await session.fillExpYear(check.expiryYear)
            }
            guard yearResult else { return .connectionFailure }
        }
        await speedDelay(milliseconds: 200)

        let cvvResult = await retryFill(session: session, check: check, fieldName: "CVV") {
            await session.fillCVV(check.cvv)
        }
        guard cvvResult else {
            await captureScreenshotForCheck(session: session, check: check, step: "cvv_fill_failed", note: "CVV fill failed", autoResult: .unsure)
            return .connectionFailure
        }
        guard !isTimedOut(deadline) else { return .timeout }
        await speedDelay(milliseconds: 500)

        await captureScreenshotForCheck(session: session, check: check, step: "pre_submit", note: "Card details filled — pre-submit", autoResult: .unknown)

        guard !isTimedOut(deadline) else { return .timeout }
        logger.log("Phase: SUBMIT PAYMENT", category: .automation, level: .info, sessionId: sessionId)
        advanceTo(.processingPayment, check: check, message: "Submitting payment...")

        var submitResult: (success: Bool, detail: String) = (false, "")
        for attempt in 1...3 {
            submitResult = await session.clickSubmitPayment()
            if submitResult.success {
                check.logs.append(PPSRLogEntry(message: "Submit: \(submitResult.detail)", level: .success))
                break
            }
            check.logs.append(PPSRLogEntry(message: "Submit attempt \(attempt)/3 failed: \(submitResult.detail)", level: .warning))
            if attempt < 3 { await speedDelay(seconds: Double(attempt)) }
        }

        guard submitResult.success else {
            failCheck(check, message: "SUBMIT FAILED after 3 attempts: \(submitResult.detail)")
            await captureScreenshotForCheck(session: session, check: check, step: "submit_failed", note: "Submit failed", autoResult: .unsure)
            return .connectionFailure
        }

        let preSubmitURL = session.webView?.url?.absoluteString ?? ""
        let remainingForPostNav = max(5, deadline.timeIntervalSinceNow - 3)
        let postNavigated = await waitForBPointNavigation(session: session, timeout: min(TimeoutResolver.resolveAutomationTimeout(15), remainingForPostNav))
        if !postNavigated {
            check.logs.append(PPSRLogEntry(message: "Page did not navigate after submit — checking content", level: .warning))
        }
        await speedDelay(seconds: 2)

        let postSubmitURL = session.webView?.url?.absoluteString ?? ""
        let urlChanged = postSubmitURL != preSubmitURL
        if urlChanged {
            check.logs.append(PPSRLogEntry(message: "REDIRECT: \(preSubmitURL) → \(postSubmitURL)", level: .info))
        }

        var pageContent = await session.getPageContent() ?? ""
        var contentLower = pageContent.lowercased()
        let currentURL = session.webView?.url?.absoluteString ?? ""

        var evaluation = evaluateBPointResponse(contentLower: contentLower, pageContent: pageContent, currentURL: currentURL, urlChanged: urlChanged)

        if evaluation.outcome == .uncertain {
            check.logs.append(PPSRLogEntry(message: "Initial eval uncertain — polling for result (up to 10s)...", level: .warning))
            for pollIdx in 1...5 {
                await speedDelay(seconds: 2)
                let pollContent = await session.getPageContent() ?? ""
                let pollLower = pollContent.lowercased()
                let pollURL = session.webView?.url?.absoluteString ?? ""
                let pollURLChanged = pollURL != preSubmitURL

                let pollEval = evaluateBPointResponse(contentLower: pollLower, pageContent: pollContent, currentURL: pollURL, urlChanged: pollURLChanged)
                check.logs.append(PPSRLogEntry(message: "Poll \(pollIdx)/5: score=\(pollEval.score) outcome=\(pollEval.outcome)", level: .info))

                if pollEval.outcome != .uncertain {
                    evaluation = pollEval
                    pageContent = pollContent
                    contentLower = pollLower
                    break
                }
            }
        }

        check.responseSnippet = String(pageContent.prefix(500))

        let autoResult: PPSRDebugScreenshot.AutoDetectedResult
        switch evaluation.outcome {
        case .failInstitution: autoResult = .noAcc
        case .pass: autoResult = .success
        default: autoResult = .unknown
        }
        await captureScreenshotForCheck(session: session, check: check, step: "post_submit_result", note: "Score: \(evaluation.score) | \(evaluation.reason)", autoResult: autoResult)

        advanceTo(.confirmingReport, check: check, message: "Evaluating BPoint response...")
        check.logs.append(PPSRLogEntry(
            message: "Evaluation: \(evaluation.outcome) (score: \(evaluation.score)) — \(evaluation.reason)",
            level: { switch evaluation.outcome { case .pass: return PPSRLogEntry.Level.success; case .uncertain: return .warning; default: return .error } }()
        ))

        switch evaluation.outcome {
        case .failInstitution:
            failCheck(check, message: "Declined: \(evaluation.reason)")
            return .failInstitution
        case .pass:
            advanceTo(.completed, check: check, message: "PASS — \(evaluation.reason)")
            check.completedAt = Date()
            return .pass
        default:
            check.status = .failed
            check.errorMessage = "Uncertain BPoint result — \(evaluation.reason). Auto-requeuing."
            check.completedAt = Date()
            onUnusualFailure?("BPoint uncertain for \(check.card.displayNumber): \(String(pageContent.prefix(200)))")
            return .uncertain
        }
    }

    private func blacklistBiller(_ code: String, reason: String) {
        billerPool.blacklistBiller(code: code, reason: reason)
        onBillerBlacklisted?(code, reason)
    }

    private struct BPointEvaluation {
        let outcome: CheckOutcome
        let score: Int
        let reason: String
    }

    private func evaluateBPointResponse(contentLower: String, pageContent: String, currentURL: String = "", urlChanged: Bool = false) -> BPointEvaluation {
        var failScore: Int = 0
        var passScore: Int = 0
        var failSignals: [String] = []
        var passSignals: [String] = []

        let strongFailTerms: [(String, Int)] = [
            ("declined", 50), ("transaction declined", 50), ("payment declined", 45),
            ("card declined", 45), ("do not honour", 40), ("insufficient funds", 35),
            ("invalid card", 40), ("expired card", 35), ("lost card", 30), ("stolen card", 30),
            ("unable to process", 35), ("not approved", 40), ("bank declined", 45),
            ("transaction failed", 40), ("payment unsuccessful", 40), ("card not accepted", 35),
        ]
        for (term, weight) in strongFailTerms {
            if contentLower.contains(term) {
                failScore += weight
                failSignals.append("+\(weight) '\(term)'")
            }
        }

        let weakFailTerms: [(String, Int)] = [
            ("error", 10), ("fail", 12), ("unsuccessful", 15), ("rejected", 15), ("invalid", 10),
        ]
        for (term, weight) in weakFailTerms {
            if contentLower.contains(term) {
                failScore += weight
                failSignals.append("+\(weight) '\(term)'")
            }
        }

        let strongPassTerms: [(String, Int)] = [
            ("approved", 50), ("transaction approved", 55), ("payment successful", 50),
            ("payment accepted", 45), ("receipt number", 40), ("transaction complete", 45),
            ("payment confirmed", 45), ("thank you for your payment", 50),
            ("payment has been processed", 45),
        ]
        for (term, weight) in strongPassTerms {
            if contentLower.contains(term) {
                passScore += weight
                passSignals.append("+\(weight) '\(term)'")
            }
        }

        let weakPassTerms: [(String, Int)] = [
            ("receipt", 10), ("confirmation", 8), ("thank you", 8), ("success", 10), ("processed", 8),
        ]
        for (term, weight) in weakPassTerms {
            if contentLower.contains(term) {
                passScore += weight
                passSignals.append("+\(weight) '\(term)'")
            }
        }

        if urlChanged {
            let urlLower = currentURL.lowercased()
            if urlLower.contains("receipt") || urlLower.contains("confirm") || urlLower.contains("success") {
                passScore += 20
                passSignals.append("+20 'redirect to receipt'")
            }
            if urlLower.contains("error") || urlLower.contains("declined") || urlLower.contains("fail") {
                failScore += 15
                failSignals.append("+15 'redirect to error'")
            }
        }

        let passThreshold = 30
        let failThreshold = 25

        if failScore >= failThreshold && failScore > passScore {
            let topSignals = failSignals.prefix(3).joined(separator: ", ")
            return BPointEvaluation(outcome: .failInstitution, score: failScore, reason: "Declined [\(topSignals)]")
        }
        if passScore >= passThreshold && passScore > failScore {
            let topSignals = passSignals.prefix(3).joined(separator: ", ")
            return BPointEvaluation(outcome: .pass, score: passScore, reason: "Approved [\(topSignals)]")
        }

        let snippet = String(pageContent.prefix(150)).replacingOccurrences(of: "\n", with: " ")
        return BPointEvaluation(outcome: .uncertain, score: max(failScore, passScore), reason: "No clear signals (pass:\(passScore) fail:\(failScore)) \"\(snippet)\"")
    }

    private func retryFill(
        session: BPointWebSession,
        check: PPSRCheck,
        fieldName: String,
        fill: () async -> (success: Bool, detail: String)
    ) async -> Bool {
        for attempt in 1...3 {
            let result = await fill()
            if result.success {
                check.logs.append(PPSRLogEntry(message: "\(fieldName): \(result.detail)", level: .success))
                return true
            }
            check.logs.append(PPSRLogEntry(message: "\(fieldName) attempt \(attempt)/3 FAILED: \(result.detail)", level: .warning))
            if attempt < 3 {
                let baseMs = 500 * (1 << (attempt - 1))
                let jitter = Int.random(in: 0...Int(Double(baseMs) * 0.3))
                await speedDelay(milliseconds: baseMs + jitter)
            }
        }
        failCheck(check, message: "\(fieldName) FILL FAILED after 3 attempts")
        return false
    }

    private func advanceTo(_ status: PPSRCheckStatus, check: PPSRCheck, message: String) {
        check.status = status
        check.logs.append(PPSRLogEntry(message: message, level: status == .completed ? .success : .info))
    }

    private func speedDelay(seconds: Double) async {
        let adjusted = max(0.05, seconds * speedMultiplier)
        try? await Task.sleep(for: .seconds(adjusted))
    }

    private func speedDelay(milliseconds: Int) async {
        let adjusted = max(50, Int(Double(milliseconds) * speedMultiplier))
        try? await Task.sleep(for: .milliseconds(adjusted))
    }

    private func failCheck(_ check: PPSRCheck, message: String) {
        check.status = .failed
        check.errorMessage = message
        check.completedAt = Date()
        check.logs.append(PPSRLogEntry(message: "ERROR: \(message)", level: .error))
    }

    private func captureScreenshotForCheck(session: BPointWebSession, check: PPSRCheck, step: String, note: String, autoResult: PPSRDebugScreenshot.AutoDetectedResult = .unknown) async {
        let cropRect = screenshotCropRect == .zero ? nil : screenshotCropRect
        let result = await session.captureScreenshotWithCrop(cropRect: cropRect)
        guard let fullImage = result.full else { return }
        check.responseSnapshot = fullImage

        let compressed: UIImage
        if let jpegData = fullImage.jpegData(compressionQuality: 0.3), let ci = UIImage(data: jpegData) {
            compressed = ci
        } else {
            compressed = fullImage
        }
        var compressedCrop: UIImage?
        if let cropped = result.cropped, let jpegData = cropped.jpegData(compressionQuality: 0.4), let ci = UIImage(data: jpegData) {
            compressedCrop = ci
        }
        let screenshot = PPSRDebugScreenshot(
            stepName: step, cardDisplayNumber: check.card.displayNumber, cardId: check.card.id,
            vin: check.vin, email: check.email, image: compressed, croppedImage: compressedCrop,
            note: note, autoDetectedResult: autoResult
        )
        check.screenshotIds.append(screenshot.id)
        onScreenshot?(screenshot)
    }

    private func waitForBPointNavigation(session: BPointWebSession, timeout: TimeInterval) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(for: .milliseconds(200))
            let currentURL = session.webView?.url?.absoluteString ?? ""
            if !currentURL.isEmpty { return true }
        }
        return false
    }

    private func performDoHPreflight(check: PPSRCheck, sessionId: String) async {
        guard let host = BPointBillerPoolService.billerLookupURL.host else { return }
        let provider = dohService.currentProvider
        check.logs.append(PPSRLogEntry(message: "DoH preflight: resolving \(host) via \(provider.name)", level: .info))
        if let result = await dohService.preflightResolve(hostname: host) {
            check.logs.append(PPSRLogEntry(message: "DoH resolved: \(result.ip) via \(result.provider) in \(result.latencyMs)ms", level: .success))
        } else {
            check.logs.append(PPSRLogEntry(message: "DoH preflight failed — falling back to system DNS", level: .warning))
        }
    }
}
