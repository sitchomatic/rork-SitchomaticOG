import Foundation
import WebKit
import UIKit

nonisolated enum AutomationTaskType: String, Sendable {
    case loginTest = "Login Test"
    case ppsrCheck = "PPSR Check"
    case flowPlayback = "Flow Playback"
    case visionCalibration = "Vision Calibration"
}

nonisolated enum AutomationTaskStatus: String, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
    case retrying
}

nonisolated struct AutomationTaskResult: Sendable {
    let taskId: String
    let taskType: AutomationTaskType
    let status: AutomationTaskStatus
    let durationMs: Int
    let message: String
    let retryCount: Int
}

@MainActor
class AutomationActor {
    static let shared = AutomationActor()

    private let logger = DebugLogger.shared
    private let visionML = VisionMLService.shared
    private let webViewPool = WebViewPool.shared

    private(set) var activeTasks: Int = 0
    private(set) var completedTasks: Int = 0
    private(set) var failedTasks: Int = 0
    private(set) var totalTasksQueued: Int = 0
    var maxConcurrency: Int = 5
    var defaultRetryCount: Int = 2
    var retryBackoffBaseMs: Int = 1000

    var isAtCapacity: Bool { activeTasks >= maxConcurrency }

    func runBatchLoginTests(
        attempts: [LoginAttempt],
        urls: [URL],
        stealthEnabled: Bool,
        timeout: TimeInterval = 90,
        onProgress: @escaping (Int, Int, LoginOutcome) -> Void
    ) async -> [LoginOutcome] {
        let batchId = "batch_\(UUID().uuidString.prefix(8))"
        let timeout = TimeoutResolver.resolveAutomationTimeout(timeout)
        logger.startSession(batchId, category: .automation, message: "AutomationActor: batch login — \(attempts.count) attempts across \(urls.count) URLs, maxConcurrency=\(maxConcurrency)")
        totalTasksQueued += attempts.count

        var outcomes: [LoginOutcome] = Array(repeating: .unsure, count: attempts.count)
        let engine = LoginAutomationEngine()
        engine.stealthEnabled = stealthEnabled

        let batchSize = maxConcurrency
        let maxRetries = defaultRetryCount
        let backoffBase = retryBackoffBaseMs
        var processed = 0

        for batchStart in stride(from: 0, to: attempts.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, attempts.count)
            let batch = Array(batchStart..<batchEnd)

            for _ in batch {
                activeTasks += 1
            }

            var batchResults: [(Int, LoginOutcome)] = []
            for index in batch {
                let attempt = attempts[index]
                let url = urls[index % urls.count]

                var outcome: LoginOutcome = .unsure
                var retries = 0

                while retries <= maxRetries {
                    outcome = await engine.runLoginTest(attempt, targetURL: url, timeout: timeout)

                    if outcome != .connectionFailure && outcome != .timeout {
                        break
                    }

                    retries += 1
                    if retries <= maxRetries {
                        let backoff = backoffBase * (1 << (retries - 1))
                        logger.log("AutomationActor: retry \(retries)/\(maxRetries) for \(attempt.credential.username) after \(backoff)ms", category: .automation, level: .warning)
                        try? await Task.sleep(for: .milliseconds(backoff))
                    }
                }

                if outcome == .connectionFailure || outcome == .timeout {
                    failedTasks += 1
                } else {
                    completedTasks += 1
                }

                activeTasks -= 1
                batchResults.append((index, outcome))
            }

            for (index, outcome) in batchResults {
                outcomes[index] = outcome
                processed += 1
                onProgress(processed, attempts.count, outcome)
            }

            if batchEnd < attempts.count {
                let cooldown = Int.random(in: 500...1500)
                try? await Task.sleep(for: .milliseconds(cooldown))
            }
        }

        logger.endSession(batchId, category: .automation, message: "AutomationActor: batch complete — \(completedTasks) ok, \(failedTasks) failed out of \(attempts.count)")
        return outcomes
    }

    func runVisionCalibrateAndLogin(
        attempt: LoginAttempt,
        session: LoginSiteWebSession,
        sessionId: String
    ) async -> LoginOutcome {
        activeTasks += 1
        defer { activeTasks -= 1 }

        guard let screenshot = await session.captureScreenshot() else {
            logger.log("AutomationActor: vision calibrate failed — no screenshot", category: .automation, level: .error, sessionId: sessionId)
            return .connectionFailure
        }

        let viewportSize = CGSize(width: 390, height: 844)
        let detection = await visionML.detectLoginElements(in: screenshot, viewportSize: viewportSize)

        logger.log("AutomationActor: vision detection — email:\(detection.emailField != nil) pass:\(detection.passwordField != nil) btn:\(detection.loginButton != nil) confidence:\(String(format: "%.0f%%", detection.confidence * 100))", category: .automation, level: detection.confidence > 0.5 ? .success : .warning, sessionId: sessionId)

        if let emailHit = detection.emailField {
            let clickEmailJS = buildCoordinateClickJS(x: emailHit.pixelCoordinate.x, y: emailHit.pixelCoordinate.y)
            _ = await session.executeJS(clickEmailJS)
            try? await Task.sleep(for: .milliseconds(300))

            let typeEmailJS = buildDirectTypeJS(text: attempt.credential.username)
            _ = await session.executeJS(typeEmailJS)
            try? await Task.sleep(for: .milliseconds(200))
        }

        if let passHit = detection.passwordField {
            let clickPassJS = buildCoordinateClickJS(x: passHit.pixelCoordinate.x, y: passHit.pixelCoordinate.y)
            _ = await session.executeJS(clickPassJS)
            try? await Task.sleep(for: .milliseconds(300))

            let typePassJS = buildDirectTypeJS(text: attempt.credential.password)
            _ = await session.executeJS(typePassJS)
            try? await Task.sleep(for: .milliseconds(200))
        }

        if let btnHit = detection.loginButton {
            let clickBtnJS = buildCoordinateClickJS(x: btnHit.pixelCoordinate.x, y: btnHit.pixelCoordinate.y)
            _ = await session.executeJS(clickBtnJS)
            try? await Task.sleep(for: .milliseconds(2000))
        }

        if let postScreenshot = await session.captureScreenshot() {
            let indicators = await visionML.detectSuccessIndicators(in: postScreenshot)
            if indicators.welcomeFound {
                logger.log("AutomationActor: vision login SUCCESS — \(indicators.context ?? "")", category: .automation, level: .success, sessionId: sessionId)
                completedTasks += 1
                return .success
            }
            if indicators.errorFound {
                logger.log("AutomationActor: vision login detected error — \(indicators.context ?? "")", category: .automation, level: .warning, sessionId: sessionId)
            }
        }

        return .unsure
    }

    func visionFindAndClick(text: String, in session: LoginSiteWebSession, sessionId: String) async -> Bool {
        guard let screenshot = await session.captureScreenshot() else { return false }

        let viewportSize = CGSize(width: 390, height: 844)
        let hit = await visionML.findTextOnScreen(text, in: screenshot, viewportSize: viewportSize)

        guard let hit else {
            logger.log("AutomationActor: vision click — '\(text)' not found", category: .automation, level: .warning, sessionId: sessionId)
            return false
        }

        let js = buildCoordinateClickJS(x: hit.pixelCoordinate.x, y: hit.pixelCoordinate.y)
        let result = await session.executeJS(js)
        let success = result != nil
        logger.log("AutomationActor: vision click '\(text)' at (\(Int(hit.pixelCoordinate.x)),\(Int(hit.pixelCoordinate.y))) — \(success ? "OK" : "FAIL")", category: .automation, level: success ? .debug : .warning, sessionId: sessionId)
        return success
    }

    func resetCounters() {
        activeTasks = 0
        completedTasks = 0
        failedTasks = 0
        totalTasksQueued = 0
    }

    private func buildCoordinateClickJS(x: CGFloat, y: CGFloat) -> String {
        """
        (function(){
            var el = document.elementFromPoint(\(Int(x)), \(Int(y)));
            if (!el) return 'NO_ELEMENT';
            try {
                el.focus();
                el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:\(Int(x)),clientY:\(Int(y)),pointerId:1,pointerType:'touch'}));
                el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:\(Int(x)),clientY:\(Int(y))}));
                el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:\(Int(x)),clientY:\(Int(y)),pointerId:1,pointerType:'touch'}));
                el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:\(Int(x)),clientY:\(Int(y))}));
                el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(Int(x)),clientY:\(Int(y))}));
                if (typeof el.click === 'function') el.click();
                return 'CLICKED:' + el.tagName;
            } catch(e) { return 'ERROR:' + e.message; }
        })()
        """
    }

    private func buildDirectTypeJS(text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return """
        (function(){
            var el = document.activeElement;
            if (!el || el === document.body) return 'NO_ACTIVE';
            el.value = '';
            var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, '\(escaped)'); }
            else { el.value = '\(escaped)'; }
            el.dispatchEvent(new Event('input', {bubbles:true}));
            el.dispatchEvent(new Event('change', {bubbles:true}));
            return el.value.length > 0 ? 'TYPED' : 'EMPTY';
        })()
        """
    }
}
