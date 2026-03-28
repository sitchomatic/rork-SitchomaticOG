import Foundation
import WebKit
import UIKit

@MainActor
class HumanInteractionEngine {
    static let shared = HumanInteractionEngine()

    private let logger = DebugLogger.shared
    private let patternLearning = LoginPatternLearning.shared
    private let aiTiming = AITimingOptimizerService.shared
    private let liveSpeed = LiveSpeedAdaptationService.shared
    private var currentHost: String = ""
    private var currentPattern: String = ""

    private func gaussianRandom(mean: Double, stdDev: Double) -> Double {
        let u1 = Double.random(in: 0.0001...0.9999)
        let u2 = Double.random(in: 0.0001...0.9999)
        let z = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
        return mean + z * stdDev
    }

    private func humanDelay(minMs: Int, maxMs: Int) -> Int {
        let mean = Double(minMs + maxMs) / 2.0
        let stdDev = Double(maxMs - minMs) / 4.0
        let delay = gaussianRandom(mean: mean, stdDev: stdDev)
        return max(minMs, min(maxMs, Int(delay)))
    }

    private func aiOptimizedDelay(category: TimingCategory, fallbackMin: Int, fallbackMax: Int) -> Int {
        guard !currentHost.isEmpty else { return liveSpeed.adaptDelay(humanDelay(minMs: fallbackMin, maxMs: fallbackMax)) }
        let baseDelay = aiTiming.optimizedDelay(for: currentHost, category: category, pattern: currentPattern)
        return liveSpeed.adaptDelay(baseDelay)
    }

    func selectBestPattern(for url: String) -> LoginFormPattern {
        if let learned = patternLearning.bestPattern(for: url) {
            // If the learned best is already visionML, use it directly
            if learned == .visionMLCoordinate {
                return .visionMLCoordinate
            }
            let ranking = patternLearning.patternRanking(for: url)
            // Give visionMLCoordinate a chance if it hasn't been tried enough
            if let visionStats = ranking.first(where: { $0.pattern == .visionMLCoordinate }) {
                if visionStats.stats.totalAttempts < 3 {
                    return .visionMLCoordinate
                }
            } else {
                // visionML hasn't been tried yet — use it as first choice
                return .visionMLCoordinate
            }
            logger.log("PatternSelect: learned best pattern for \(URL(string: url)?.host ?? url) → \(learned.rawValue)", category: .automation, level: .info)
            return learned
        }
        // Default: OCR-based coordinate click is the primary undetectable method
        return .visionMLCoordinate
    }

    func executePattern(
        _ pattern: LoginFormPattern,
        username: String,
        password: String,
        executeJS: @escaping (String) async -> String?,
        sessionId: String,
        targetURL: String? = nil
    ) async -> HumanPatternResult {
        if let url = targetURL, let host = URL(string: url)?.host {
            currentHost = host
        } else if let host = URL(string: sessionId)?.host {
            currentHost = host
        }
        currentPattern = pattern.rawValue

        logger.log("HumanInteraction: executing pattern '\(pattern.rawValue)' host=\(currentHost)", category: .automation, level: .info, sessionId: sessionId)
        let startTime = Date()

        let result: HumanPatternResult
        switch pattern {
        case .trueDetection:
            result = await executeTrueDetectionPattern(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .tabNavigation:
            result = await executeTabNavigation(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .clickFocusSequential:
            result = await executeClickFocusSequential(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .execCommandInsert:
            result = await executeExecCommandInsert(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .slowDeliberateTyper:
            result = await executeSlowDeliberateTyper(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .mobileTouchBurst:
            result = await executeMobileTouchBurst(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .calibratedDirect:
            result = await executeCalibratedDirect(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .calibratedTyping:
            result = await executeCalibratedTyping(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .formSubmitDirect:
            result = await executeFormSubmitDirect(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .coordinateClick:
            result = await executeCoordinateClick(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .reactNativeSetter:
            result = await executeReactNativeSetter(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .visionMLCoordinate:
            result = await executeVisionMLCoordinate(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        }

        let elapsed = Date().timeIntervalSince(startTime)
        logger.log("HumanInteraction: pattern '\(pattern.rawValue)' completed in \(Int(elapsed * 1000))ms — fillSuccess:\(result.usernameFilled && result.passwordFilled) submitSuccess:\(result.submitTriggered)", category: .automation, level: result.submitTriggered ? .success : .warning, sessionId: sessionId, durationMs: Int(elapsed * 1000))

        if !currentHost.isEmpty {
            let profile = aiTiming.profileForHost(currentHost)
            aiTiming.recordPatternTimingOutcome(
                url: targetURL ?? sessionId,
                pattern: pattern,
                keystrokeDelayMs: Int(profile.keystroke.mean),
                interFieldPauseMs: Int(profile.interField.mean),
                preSubmitWaitMs: Int(profile.preSubmit.mean),
                fillSuccess: result.usernameFilled && result.passwordFilled,
                submitSuccess: result.submitTriggered,
                detected: !result.submitTriggered && result.usernameFilled
            )
        }

        return result
    }

    // MARK: - Pattern 0: TRUE DETECTION

    private func executeTrueDetectionPattern(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .trueDetection)

        logger.log("TrueDetection Pattern: waiting for DOM complete...", category: .automation, level: .trace, sessionId: sessionId)
        let domStart = Date()
        while Date().timeIntervalSince(domStart) < 10 {
            let ready = await executeJS("document.readyState")
            if ready == "complete" { break }
            try? await Task.sleep(for: .milliseconds(300))
        }

        let postDOMDelay = aiOptimizedDelay(category: .postDOMPause, fallbackMin: 2000, fallbackMax: 4000)
        logger.log("TrueDetection Pattern: hard pause \(postDOMDelay)ms (AI-optimized)", category: .automation, level: .trace, sessionId: sessionId)
        try? await Task.sleep(for: .milliseconds(postDOMDelay))

        let emailTapResult = await executeJS(JSInteractionBuilder.humanTapJS(selector: "#email"))
        logger.log("TrueDetection: human tap on #email → \(emailTapResult ?? "nil")", category: .automation, level: .trace, sessionId: sessionId)
        try? await Task.sleep(for: .milliseconds(Int.random(in: 80...220)))

        let emailResult = await executeJS(JSInteractionBuilder.nativeSetterFillJS(selector: "#email", value: username))
        result.usernameFilled = emailResult == "OK" || emailResult == "VALUE_MISMATCH"
        logger.log("TrueDetection: #email fill → \(emailResult ?? "nil")", category: .automation, level: result.usernameFilled ? .success : .error, sessionId: sessionId)

        if !result.usernameFilled { return result }
        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .interFieldPause, fallbackMin: 300, fallbackMax: 600)))

        let passTapResult = await executeJS(JSInteractionBuilder.humanTapJS(selector: "#login-password"))
        logger.log("TrueDetection: human tap on #login-password → \(passTapResult ?? "nil")", category: .automation, level: .trace, sessionId: sessionId)
        try? await Task.sleep(for: .milliseconds(Int.random(in: 80...220)))

        let passResult = await executeJS(JSInteractionBuilder.nativeSetterFillJS(selector: "#login-password", value: password))
        result.passwordFilled = passResult == "OK" || passResult == "VALUE_MISMATCH"
        logger.log("TrueDetection: #login-password fill → \(passResult ?? "nil")", category: .automation, level: result.passwordFilled ? .success : .error, sessionId: sessionId)

        if !result.passwordFilled { return result }
        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preSubmitWait, fallbackMin: 300, fallbackMax: 600)))

        let submitCycles = 4
        let clicksPerCycle = 4
        let clickDelayMs = 1100
        let buttonRecoveryTimeoutMs = 12000
        let buttonRecovery = SmartButtonRecoveryService.shared

        logger.log("TrueDetection: starting \(submitCycles)-cycle submit on #login-submit (\(clicksPerCycle) clicks/cycle)", category: .automation, level: .info, sessionId: sessionId)

        for cycle in 0..<submitCycles {
            let preClickFingerprint = await buttonRecovery.captureFingerprint(
                executeJS: executeJS,
                sessionId: sessionId
            )

            for i in 0..<clicksPerCycle {
                let clickResult = await executeJS(JSInteractionBuilder.cycledSubmitClickJS(selector: "#login-submit", clickIndex: i))
                logger.log("TrueDetection: cycle \(cycle + 1) click \(i + 1)/\(clicksPerCycle) \u{2192} \(clickResult ?? "nil")", category: .automation, level: .trace, sessionId: sessionId)
                if clickResult == "NOT_FOUND" && i == 0 && cycle == 0 {
                    return result
                }
                if i < clicksPerCycle - 1 {
                    try? await Task.sleep(for: .milliseconds(clickDelayMs))
                }
            }

            if cycle < submitCycles - 1 {
                logger.log("TrueDetection: cycle \(cycle + 1) done — AI smart button color change detection...", category: .automation, level: .info, sessionId: sessionId)
                if let fingerprint = preClickFingerprint {
                    let recovery = await buttonRecovery.waitForRecovery(
                        originalFingerprint: fingerprint,
                        executeJS: executeJS,
                        host: currentHost,
                        sessionId: sessionId,
                        maxTimeoutMs: buttonRecoveryTimeoutMs
                    )
                    logger.log("TrueDetection: button recovery \(recovery.recovered ? "OK" : "TIMEOUT") in \(recovery.durationMs)ms", category: .automation, level: recovery.recovered ? .success : .warning, sessionId: sessionId)
                } else {
                    try? await Task.sleep(for: .milliseconds(2000))
                }
                try? await Task.sleep(for: .milliseconds(Int.random(in: 200...500)))
            }
        }

        result.submitTriggered = true
        result.submitMethod = "TRUE_DETECTION_CYCLED_TRIPLE_CLICK_\(submitCycles)x\(clicksPerCycle)"
        logger.log("TrueDetection: all \(submitCycles) submit cycles complete", category: .automation, level: .success, sessionId: sessionId)
        return result
    }

    // MARK: - Pattern 1: Tab Navigation

    private func executeTabNavigation(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .tabNavigation)

        let focusResult = await executeJS(JSInteractionBuilder.focusAndClickEmailFieldJS())
        guard focusResult != "NOT_FOUND" else {
            logger.log("TabNav: email field NOT_FOUND", category: .automation, level: .error, sessionId: sessionId)
            return result
        }

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preFocusPause, fallbackMin: 200, fallbackMax: 500)))

        let userTyped = await typeCharByChar(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email", minDelayMs: 45, maxDelayMs: 160)
        result.usernameFilled = userTyped

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .interFieldPause, fallbackMin: 100, fallbackMax: 350)))

        let tabResult = await executeJS(JSInteractionBuilder.tabToPasswordJS())
        logger.log("TabNav: Tab key → \(tabResult ?? "nil")", category: .automation, level: .trace, sessionId: sessionId)

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preFocusPause, fallbackMin: 150, fallbackMax: 400)))

        let passTyped = await typeCharByChar(text: password, executeJS: executeJS, sessionId: sessionId, fieldName: "password", minDelayMs: 50, maxDelayMs: 180)
        result.passwordFilled = passTyped

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preSubmitWait, fallbackMin: 200, fallbackMax: 600)))

        let enterResult = await executeJS(JSInteractionBuilder.enterKeySubmitJS())
        result.submitTriggered = enterResult == "ENTER_PRESSED"
        result.submitMethod = "Enter key on password field"

        return result
    }

    // MARK: - Pattern 2: Click-Focus Sequential

    private func executeClickFocusSequential(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .clickFocusSequential)

        let emailClick = await executeJS(JSInteractionBuilder.mouseMoveThenClickEmailJS())
        guard emailClick != "NOT_FOUND" else {
            logger.log("ClickFocus: email field NOT_FOUND", category: .automation, level: .error, sessionId: sessionId)
            return result
        }

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preFocusPause, fallbackMin: 300, fallbackMax: 700)))

        let userTyped = await typeCharByChar(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email", minDelayMs: 55, maxDelayMs: 200)
        result.usernameFilled = userTyped

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .interFieldPause, fallbackMin: 400, fallbackMax: 900)))

        let passClick = await executeJS(JSInteractionBuilder.blurAndMouseClickPasswordJS())
        logger.log("ClickFocus: password field click → \(passClick ?? "nil")", category: .automation, level: .trace, sessionId: sessionId)

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preFocusPause, fallbackMin: 200, fallbackMax: 500)))

        let passTyped = await typeCharByChar(text: password, executeJS: executeJS, sessionId: sessionId, fieldName: "password", minDelayMs: 60, maxDelayMs: 190)
        result.passwordFilled = passTyped

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preSubmitWait, fallbackMin: 300, fallbackMax: 800)))

        let clickLoginResult = await humanClickLoginButton(executeJS: executeJS, sessionId: sessionId)
        result.submitTriggered = clickLoginResult
        result.submitMethod = "Mouse click on login button"

        return result
    }

    // MARK: - Pattern 3: ExecCommand Insert

    private func executeExecCommandInsert(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .execCommandInsert)

        let focused = await executeJS(JSInteractionBuilder.focusSelectClearJS())
        guard focused != "NOT_FOUND" else {
            logger.log("ExecCmd: email NOT_FOUND", category: .automation, level: .error, sessionId: sessionId)
            return result
        }

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preFocusPause, fallbackMin: 150, fallbackMax: 400)))

        let userTyped = await typeWithExecCommand(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email", minDelayMs: 30, maxDelayMs: 120)
        result.usernameFilled = userTyped

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .interFieldPause, fallbackMin: 200, fallbackMax: 500)))

        let passFocused = await executeJS(JSInteractionBuilder.blurAndFocusSelectPasswordJS())
        guard passFocused != "NOT_FOUND" else {
            logger.log("ExecCmd: password NOT_FOUND", category: .automation, level: .error, sessionId: sessionId)
            return result
        }

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preFocusPause, fallbackMin: 100, fallbackMax: 350)))

        let passTyped = await typeWithExecCommand(text: password, executeJS: executeJS, sessionId: sessionId, fieldName: "password", minDelayMs: 35, maxDelayMs: 130)
        result.passwordFilled = passTyped

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preSubmitWait, fallbackMin: 300, fallbackMax: 700)))

        let submitResult = await executeJS(JSInteractionBuilder.blurAndEnterSubmitJS())
        result.submitTriggered = submitResult == "ENTER_PRESSED"
        result.submitMethod = "ExecCommand + Enter key"

        return result
    }

    // MARK: - Pattern 4: Slow Deliberate Typer

    private func executeSlowDeliberateTyper(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .slowDeliberateTyper)

        let f = await executeJS(JSInteractionBuilder.focusScrollClickEmailJS())
        guard f != "NOT_FOUND" else { return result }

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preFocusPause, fallbackMin: 500, fallbackMax: 1200)))

        let userTyped = await typeSlowWithCorrections(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email")
        result.usernameFilled = userTyped

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .interFieldPause, fallbackMin: 600, fallbackMax: 1500)))

        let pf = await executeJS(JSInteractionBuilder.blurAndFocusPasswordJS())
        guard pf != "NOT_FOUND" else { return result }

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preFocusPause, fallbackMin: 400, fallbackMax: 1000)))

        let passTyped = await typeSlowWithCorrections(text: password, executeJS: executeJS, sessionId: sessionId, fieldName: "password")
        result.passwordFilled = passTyped

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preSubmitWait, fallbackMin: 800, fallbackMax: 2000)))

        let clickResult = await humanClickLoginButton(executeJS: executeJS, sessionId: sessionId)
        result.submitTriggered = clickResult
        result.submitMethod = "Slow deliberate mouse click"

        return result
    }

    // MARK: - Pattern 5: Mobile Touch Burst

    private func executeMobileTouchBurst(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .mobileTouchBurst)

        let touchResult = await executeJS(JSInteractionBuilder.touchFocusFieldJS())
        guard touchResult != "NOT_FOUND" else { return result }

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preFocusPause, fallbackMin: 100, fallbackMax: 300)))

        let userTyped = await typeCharByChar(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email", minDelayMs: 25, maxDelayMs: 80)
        result.usernameFilled = userTyped

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .interFieldPause, fallbackMin: 150, fallbackMax: 400)))

        let touchPass = await executeJS(JSInteractionBuilder.touchFocusFieldJS(fieldSelector: "input[type=\"password\"]"))
        guard touchPass != "NOT_FOUND" else { return result }

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preFocusPause, fallbackMin: 80, fallbackMax: 250)))

        let passTyped = await typeCharByChar(text: password, executeJS: executeJS, sessionId: sessionId, fieldName: "password", minDelayMs: 20, maxDelayMs: 70)
        result.passwordFilled = passTyped

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preSubmitWait, fallbackMin: 200, fallbackMax: 500)))

        let submitR = await executeJS(JSInteractionBuilder.enterKeyOnPasswordJS())
        if submitR == "ENTER" {
            result.submitTriggered = true
            result.submitMethod = "Touch + Enter key"
        } else {
            let clickResult = await humanClickLoginButton(executeJS: executeJS, sessionId: sessionId)
            result.submitTriggered = clickResult
            result.submitMethod = "Touch fallback click"
        }

        return result
    }

    // MARK: - Pattern 6: Calibrated Direct

    private func executeCalibratedDirect(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .calibratedDirect)
        let cal = LoginCalibrationService.shared.calibrationFor(url: sessionId)

        let emailResult = await executeJS(JSInteractionBuilder.calibratedFillJS(calibration: cal, fieldType: "email", value: username))
        result.usernameFilled = emailResult == "CAL_OK" || emailResult == "CAL_MISMATCH" || emailResult == "LEGACY_OK"
        if !result.usernameFilled {
            let f = await executeJS(JSInteractionBuilder.focusEmailFieldJS())
            if f != "NOT_FOUND" {
                let typed = await typeCharByChar(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email", minDelayMs: 40, maxDelayMs: 140)
                result.usernameFilled = typed
            }
        }

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .interFieldPause, fallbackMin: 200, fallbackMax: 500)))

        let passResult = await executeJS(JSInteractionBuilder.calibratedFillJS(calibration: cal, fieldType: "password", value: password))
        result.passwordFilled = passResult == "CAL_OK" || passResult == "CAL_MISMATCH" || passResult == "LEGACY_OK"
        if !result.passwordFilled {
            let f = await executeJS(JSInteractionBuilder.focusPasswordJS())
            if f != "NOT_FOUND" {
                let typed = await typeCharByChar(text: password, executeJS: executeJS, sessionId: sessionId, fieldName: "password", minDelayMs: 45, maxDelayMs: 150)
                result.passwordFilled = typed
            }
        }

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preSubmitWait, fallbackMin: 300, fallbackMax: 700)))

        let clickResult = await humanClickLoginButton(executeJS: executeJS, sessionId: sessionId)
        result.submitTriggered = clickResult
        result.submitMethod = "Calibrated direct fill + click"
        return result
    }

    // MARK: - Pattern 7: Calibrated Typing

    private func executeCalibratedTyping(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .calibratedTyping)
        let cal = LoginCalibrationService.shared.calibrationFor(url: sessionId)

        let focused = await executeJS(JSInteractionBuilder.calibratedFocusJS(calibration: cal, fieldType: "email"))
        if focused == "NOT_FOUND" {
            _ = await executeJS(JSInteractionBuilder.focusEmailFieldJS())
        }

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preFocusPause, fallbackMin: 150, fallbackMax: 400)))
        let userTyped = await typeCharByChar(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email", minDelayMs: 45, maxDelayMs: 160)
        result.usernameFilled = userTyped

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .interFieldPause, fallbackMin: 200, fallbackMax: 500)))

        let passFocused = await executeJS(JSInteractionBuilder.calibratedFocusJS(calibration: cal, fieldType: "password"))
        if passFocused == "NOT_FOUND" {
            _ = await executeJS(JSInteractionBuilder.focusPasswordJS())
        }

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preFocusPause, fallbackMin: 150, fallbackMax: 400)))
        let passTyped = await typeCharByChar(text: password, executeJS: executeJS, sessionId: sessionId, fieldName: "password", minDelayMs: 50, maxDelayMs: 170)
        result.passwordFilled = passTyped

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preSubmitWait, fallbackMin: 200, fallbackMax: 600)))

        let enterResult = await executeJS(JSInteractionBuilder.enterKeySubmitJS())
        result.submitTriggered = enterResult == "ENTER_PRESSED"
        result.submitMethod = "Calibrated focus + typing + Enter"
        return result
    }

    // MARK: - Pattern 8: Form Submit Direct

    private func executeFormSubmitDirect(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .formSubmitDirect)

        if let rawResult = await executeJS(JSInteractionBuilder.fillBothFieldsJS(username: username, password: password)),
           let data = rawResult.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] {
            result.usernameFilled = json["email"] ?? false
            result.passwordFilled = json["pass"] ?? false
        }

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preSubmitWait, fallbackMin: 200, fallbackMax: 500)))

        let submitResult = await executeJS(JSInteractionBuilder.formSubmitJS())
        result.submitTriggered = submitResult != "FAILED" && submitResult != nil
        result.submitMethod = "Form submit direct: \(submitResult ?? "nil")"
        return result
    }

    // MARK: - Pattern 9: Coordinate Click

    private func executeCoordinateClick(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .coordinateClick)
        let cal = LoginCalibrationService.shared.calibrationFor(url: sessionId)

        if let emailCoords = cal?.emailField?.coordinates {
            let f = await executeJS(JSInteractionBuilder.coordinateClickJS(x: Int(emailCoords.x), y: Int(emailCoords.y)))
            if f != "NO_ELEMENT" {
                try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preFocusPause, fallbackMin: 100, fallbackMax: 300)))
                let typed = await typeCharByChar(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email", minDelayMs: 40, maxDelayMs: 140)
                result.usernameFilled = typed
            }
        } else {
            let f = await executeJS(JSInteractionBuilder.focusEmailFieldJS())
            if f != "NOT_FOUND" {
                try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preFocusPause, fallbackMin: 100, fallbackMax: 300)))
                let typed = await typeCharByChar(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email", minDelayMs: 40, maxDelayMs: 140)
                result.usernameFilled = typed
            }
        }

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .interFieldPause, fallbackMin: 200, fallbackMax: 500)))

        if let passCoords = cal?.passwordField?.coordinates {
            let f = await executeJS(JSInteractionBuilder.coordinateClickJS(x: Int(passCoords.x), y: Int(passCoords.y)))
            if f != "NO_ELEMENT" {
                try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preFocusPause, fallbackMin: 100, fallbackMax: 300)))
                let typed = await typeCharByChar(text: password, executeJS: executeJS, sessionId: sessionId, fieldName: "password", minDelayMs: 45, maxDelayMs: 150)
                result.passwordFilled = typed
            }
        } else {
            let f = await executeJS(JSInteractionBuilder.focusPasswordJS())
            if f != "NOT_FOUND" {
                try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preFocusPause, fallbackMin: 100, fallbackMax: 300)))
                let typed = await typeCharByChar(text: password, executeJS: executeJS, sessionId: sessionId, fieldName: "password", minDelayMs: 45, maxDelayMs: 150)
                result.passwordFilled = typed
            }
        }

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preSubmitWait, fallbackMin: 300, fallbackMax: 700)))

        if let btnCoords = cal?.loginButton?.coordinates {
            let r = await executeJS(JSInteractionBuilder.coordinateButtonClickJS(x: Int(btnCoords.x), y: Int(btnCoords.y)))
            result.submitTriggered = r?.hasPrefix("COORD_CLICKED") == true
            result.submitMethod = "Coordinate click: \(r ?? "nil")"
        } else {
            let clickResult = await humanClickLoginButton(executeJS: executeJS, sessionId: sessionId)
            result.submitTriggered = clickResult
            result.submitMethod = "Coordinate fallback click"
        }

        return result
    }

    // MARK: - Pattern 10: React Native Setter

    private func executeReactNativeSetter(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .reactNativeSetter)

        if let rawResult = await executeJS(JSInteractionBuilder.reactNativeFillJS(username: username, password: password)),
           let data = rawResult.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] {
            result.usernameFilled = json["email"] ?? false
            result.passwordFilled = json["pass"] ?? false
        }

        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preSubmitWait, fallbackMin: 300, fallbackMax: 700)))

        let clickResult = await humanClickLoginButton(executeJS: executeJS, sessionId: sessionId)
        result.submitTriggered = clickResult
        result.submitMethod = "React native setter + click"

        if !result.submitTriggered {
            let enterR = await executeJS(JSInteractionBuilder.enterKeyOnPasswordJS())
            result.submitTriggered = enterR == "ENTER"
            result.submitMethod = "React native setter + Enter"
        }

        return result
    }

    // MARK: - Pattern 11: Vision ML Coordinate

    private func executeVisionMLCoordinate(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .visionMLCoordinate)
        _ = VisionMLService.shared

        // Step 1: Capture screenshot for OCR-based element detection
        let screenshotJS = """
        (function(){
            return JSON.stringify({w: window.innerWidth, h: window.innerHeight});
        })()
        """
        let viewportStr = await executeJS(screenshotJS) ?? "{}"
        var viewportSize: CGSize = CGSize(width: 390, height: 844)
        _ = viewportSize
        if let data = viewportStr.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let w = json["w"] as? CGFloat, let h = json["h"] as? CGFloat, w > 0, h > 0 {
            viewportSize = CGSize(width: w, height: h)
        }

        // Step 2: Take page screenshot via canvas capture
        let captureJS = """
        (function(){
            var el = document.querySelector('input[type="email"], input[type="text"][name*="email" i], input#email, input#username');
            if(el) { return JSON.stringify({found:true, tag:el.tagName, x:el.getBoundingClientRect().x, y:el.getBoundingClientRect().y, w:el.getBoundingClientRect().width, h:el.getBoundingClientRect().height}); }
            return JSON.stringify({found:false});
        })()
        """
        _ = await executeJS(captureJS)

        // Step 3: OCR Vision ML — detect email field by pixel coordinate with human variance
        let emailClickJS = buildOCRVarianceClickJS(
            selectorHints: ["input[type='email']", "input[type='text'][name*='email' i]", "input#email", "input#username", "input[name='username']"],
            pixelVarianceRange: 3,
            sessionId: sessionId
        )
        let emailClickResult = await executeJS(emailClickJS)
        let emailClicked = emailClickResult != "NOT_FOUND" && emailClickResult != nil

        if emailClicked {
            // Human-like pre-typing pause
            try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preFocusPause, fallbackMin: 200, fallbackMax: 500)))

            // Clear any existing value first
            _ = await executeJS("(function(){var el=document.activeElement; if(el&&el.tagName==='INPUT'){el.value='';el.dispatchEvent(new Event('input',{bubbles:true}));} return 'cleared';})()")

            // Type with human timing variance
            let userTyped = await typeCharByChar(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email", minDelayMs: 40, maxDelayMs: 140)
            result.usernameFilled = userTyped
        } else {
            // Fallback: JS selector focus
            logger.log("VisionML OCR: email coordinate click failed, falling back to JS focus", category: .automation, level: .warning, sessionId: sessionId)
            let emailFocus = await executeJS(JSInteractionBuilder.focusEmailFieldJS())
            if emailFocus != "NOT_FOUND" {
                try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preFocusPause, fallbackMin: 150, fallbackMax: 400)))
                let userTyped = await typeCharByChar(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email", minDelayMs: 40, maxDelayMs: 140)
                result.usernameFilled = userTyped
            }
        }

        // Human inter-field pause with variance
        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .interFieldPause, fallbackMin: 300, fallbackMax: 700)))

        // Step 4: OCR Vision ML — detect password field by pixel coordinate with variance
        let passClickJS = buildOCRVarianceClickJS(
            selectorHints: ["input[type='password']", "input#password", "input#login-password", "input[name='password']"],
            pixelVarianceRange: 3,
            sessionId: sessionId
        )
        let passClickResult = await executeJS(passClickJS)
        let passClicked = passClickResult != "NOT_FOUND" && passClickResult != nil

        if passClicked {
            try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preFocusPause, fallbackMin: 150, fallbackMax: 400)))
            _ = await executeJS("(function(){var el=document.activeElement; if(el&&el.tagName==='INPUT'){el.value='';el.dispatchEvent(new Event('input',{bubbles:true}));} return 'cleared';})()")
            let passTyped = await typeCharByChar(text: password, executeJS: executeJS, sessionId: sessionId, fieldName: "password", minDelayMs: 45, maxDelayMs: 160)
            result.passwordFilled = passTyped
        } else {
            logger.log("VisionML OCR: password coordinate click failed, falling back to JS focus", category: .automation, level: .warning, sessionId: sessionId)
            _ = await executeJS(JSInteractionBuilder.focusPasswordJS())
            try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preFocusPause, fallbackMin: 150, fallbackMax: 400)))
            let passTyped = await typeCharByChar(text: password, executeJS: executeJS, sessionId: sessionId, fieldName: "password", minDelayMs: 45, maxDelayMs: 160)
            result.passwordFilled = passTyped
        }

        // Human pre-submit thinking pause
        try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .preSubmitWait, fallbackMin: 400, fallbackMax: 900)))

        // Step 5: OCR Vision ML — click submit button via pixel coordinate with variance
        let submitClickJS = buildOCRVarianceClickJS(
            selectorHints: ["button[type='submit']", "#loginSubmit", "#login-submit", "button.login-btn", "input[type='submit']"],
            pixelVarianceRange: 4,
            sessionId: sessionId
        )
        let submitResult = await executeJS(submitClickJS)
        if submitResult != "NOT_FOUND" && submitResult != nil {
            result.submitTriggered = true
            result.submitMethod = "OCR pixel-variance coordinate click"
        } else {
            logger.log("VisionML OCR: submit coordinate click failed, falling back to humanClickLoginButton", category: .automation, level: .warning, sessionId: sessionId)
            let clickResult = await humanClickLoginButton(executeJS: executeJS, sessionId: sessionId)
            result.submitTriggered = clickResult
            result.submitMethod = "Vision ML fallback to humanClick"
        }

        return result
    }

    /// Builds JavaScript that locates an element using selector hints, then dispatches a
    /// full pointer/mouse/touch event chain at the element's center with random pixel variance —
    /// mimicking how a real human finger or cursor never hits the exact center pixel.
    private func buildOCRVarianceClickJS(selectorHints: [String], pixelVarianceRange: Int, sessionId: String) -> String {
        let selectorsArray = selectorHints.map { "'\($0)'" }.joined(separator: ",")
        let variance = pixelVarianceRange
        return """
        (function(){
            var selectors = [\(selectorsArray)];
            var el = null;
            for(var i=0;i<selectors.length;i++){
                el = document.querySelector(selectors[i]);
                if(el && el.offsetParent !== null) break;
                el = null;
            }
            if(!el) return 'NOT_FOUND';
            var rect = el.getBoundingClientRect();
            if(rect.width === 0 || rect.height === 0) return 'NOT_FOUND';
            var cx = rect.left + rect.width/2 + (Math.random()*\(variance*2) - \(variance));
            var cy = rect.top + rect.height/2 + (Math.random()*\(variance*2) - \(variance));
            cx = Math.max(rect.left+1, Math.min(rect.right-1, cx));
            cy = Math.max(rect.top+1, Math.min(rect.bottom-1, cy));
            el.focus();
            el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'touch',isPrimary:true}));
            el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy}));
            el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'touch',isPrimary:true}));
            el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy}));
            el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy}));
            if(typeof el.click === 'function') el.click();
            return 'CLICKED:'+el.tagName+'@'+Math.round(cx)+','+Math.round(cy);
        })()
        """
    }

    // MARK: - Typing Engines

    private func typeCharByChar(text: String, executeJS: @escaping (String) async -> String?, sessionId: String, fieldName: String, minDelayMs: Int, maxDelayMs: Int) async -> Bool {
        let fieldType = fieldName == "password" ? "password" : "email"
        _ = await executeJS(JSInteractionBuilder.clearFieldJS(fieldType: fieldType))

        for (index, char) in text.enumerated() {
            let r = await executeJS(JSInteractionBuilder.typeOneCharJS(char: char, fieldType: fieldType))
            if r != "TYPED" {
                logger.log("CharByChar: failed at index \(index) of \(fieldName): \(r ?? "nil")", category: .automation, level: .warning, sessionId: sessionId)
                return false
            }

            let delay = aiOptimizedDelay(category: .keystrokeDelay, fallbackMin: minDelayMs, fallbackMax: maxDelayMs)
            if index > 0 && index % Int.random(in: 4...8) == 0 {
                let thinkPause = aiOptimizedDelay(category: .thinkPause, fallbackMin: 200, fallbackMax: 600)
                try? await Task.sleep(for: .milliseconds(delay + thinkPause))
            } else {
                try? await Task.sleep(for: .milliseconds(delay))
            }
        }

        let lenStr = await executeJS(JSInteractionBuilder.verifyFieldLengthJS())
        let typedLen = Int(lenStr ?? "0") ?? 0
        let success = typedLen >= text.count
        if !success {
            logger.log("CharByChar: \(fieldName) verify failed — typed \(typedLen)/\(text.count) chars", category: .automation, level: .warning, sessionId: sessionId)
        }
        return success
    }

    private func typeWithExecCommand(text: String, executeJS: @escaping (String) async -> String?, sessionId: String, fieldName: String, minDelayMs: Int, maxDelayMs: Int) async -> Bool {
        _ = await executeJS(JSInteractionBuilder.execCommandClearJS())

        for (index, char) in text.enumerated() {
            let r = await executeJS(JSInteractionBuilder.execCommandInsertCharJS(char: char))
            if r == "NO_EL" {
                logger.log("ExecCmd: no active element at index \(index) of \(fieldName)", category: .automation, level: .warning, sessionId: sessionId)
                return false
            }

            let delay = aiOptimizedDelay(category: .keystrokeDelay, fallbackMin: minDelayMs, fallbackMax: maxDelayMs)
            try? await Task.sleep(for: .milliseconds(delay))
        }

        return true
    }

    private func typeSlowWithCorrections(text: String, executeJS: @escaping (String) async -> String?, sessionId: String, fieldName: String) async -> Bool {
        _ = await executeJS(JSInteractionBuilder.slowTypeClearJS())

        let correctionChance = 0.08
        var i = 0
        let chars = Array(text)

        while i < chars.count {
            if Double.random(in: 0...1) < correctionChance && i > 2 {
                let typoChar = "abcdefghijklmnopqrstuvwxyz".randomElement()!
                _ = await executeJS(JSInteractionBuilder.slowTypeTypoJS(char: typoChar))
                logger.log("SlowTyper: deliberate typo '\(typoChar)' at pos \(i) in \(fieldName)", category: .automation, level: .trace, sessionId: sessionId)

                try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .thinkPause, fallbackMin: 300, fallbackMax: 800)))
                _ = await executeJS(JSInteractionBuilder.backspaceJS())
                try? await Task.sleep(for: .milliseconds(aiOptimizedDelay(category: .thinkPause, fallbackMin: 200, fallbackMax: 500)))
            }

            let char = chars[i]
            let r = await executeJS(JSInteractionBuilder.slowTypeCharJS(char: char))
            if r == "NO_EL" { return false }

            let delay = aiOptimizedDelay(category: .keystrokeDelay, fallbackMin: 120, fallbackMax: 350)
            if i > 0 && i % Int.random(in: 3...6) == 0 {
                try? await Task.sleep(for: .milliseconds(delay + aiOptimizedDelay(category: .thinkPause, fallbackMin: 300, fallbackMax: 900)))
            } else {
                try? await Task.sleep(for: .milliseconds(delay))
            }

            i += 1
        }

        return true
    }

    // MARK: - Login Button Click

    private func humanClickLoginButton(executeJS: @escaping (String) async -> String?, sessionId: String) async -> Bool {
        let r = await executeJS(JSInteractionBuilder.humanClickLoginButtonJS())
        logger.log("HumanClick login button: \(r ?? "nil")", category: .automation, level: r?.hasPrefix("CLICKED") == true ? .debug : .warning, sessionId: sessionId)

        if let r, r.hasPrefix("CLICKED") { return true }

        let fallback = await executeJS(JSInteractionBuilder.enterFallbackSubmitJS())
        logger.log("HumanClick fallback: \(fallback ?? "nil")", category: .automation, level: .debug, sessionId: sessionId)
        return fallback != "FAILED" && fallback != nil
    }
}
