import Foundation
import WebKit
import UIKit

@MainActor
class FlowPlaybackEngine {
    static let shared = FlowPlaybackEngine()

    private let logger = DebugLogger.shared
    private let visionML = VisionMLService.shared
    private(set) var isPlaying: Bool = false
    private(set) var currentActionIndex: Int = 0
    private(set) var totalActions: Int = 0
    private var cancelled: Bool = false
    private(set) var lastPlaybackError: String?
    private(set) var failedActionIndices: [Int] = []
    private(set) var healedActionCount: Int = 0

    var progressFraction: Double {
        guard totalActions > 0 else { return 0 }
        return Double(currentActionIndex) / Double(totalActions)
    }

    func cancel() {
        cancelled = true
        isPlaying = false
    }

    func playFlow(
        _ flow: RecordedFlow,
        in webView: WKWebView,
        textboxValues: [String: String] = [:],
        startFromStep: Int = 0,
        onProgress: @escaping (Int, Int) -> Void,
        onComplete: @escaping (Bool) -> Void
    ) async {
        guard !flow.actions.isEmpty else {
            onComplete(false)
            return
        }

        let effectiveStart = max(0, min(startFromStep, flow.actions.count))

        isPlaying = true
        cancelled = false
        totalActions = flow.actions.count
        currentActionIndex = effectiveStart
        lastPlaybackError = nil
        failedActionIndices = []
        healedActionCount = 0

        let sessionId = "playback_\(flow.id.prefix(8))"
        logger.startSession(sessionId, category: .flowRecorder, message: "FlowPlayback: starting '\(flow.name)' from step \(effectiveStart) — \(flow.actions.count) actions")

        let profile = await PPSRStealthService.shared.nextProfile()
        let stealthJS = PPSRStealthService.shared.buildComprehensiveStealthJSPublic(profile: profile)
        do {
            _ = try await webView.evaluateJavaScript(stealthJS)
        } catch {
            logger.logError("FlowPlayback: stealth JS injection failed", error: error, category: .stealth, sessionId: sessionId)
        }

        for index in effectiveStart..<flow.actions.count {
            if cancelled { break }

            let action = flow.actions[index]
            currentActionIndex = index
            onProgress(index, flow.actions.count)

            if action.deltaFromPreviousMs > 0 {
                let delayMs = action.deltaFromPreviousMs
                let jitter = Double.random(in: -0.5...0.5)
                let finalDelay = max(1, delayMs + jitter)
                try? await Task.sleep(for: .milliseconds(Int(finalDelay)))
            }

            if cancelled { break }

            let success = await executeActionWithHealing(action, index: index, in: webView, textboxValues: textboxValues, sessionId: sessionId)
            if !success {
                failedActionIndices.append(index)
            }
        }

        currentActionIndex = flow.actions.count
        onProgress(flow.actions.count, flow.actions.count)
        isPlaying = false

        let success = !cancelled
        logger.endSession(sessionId, category: .flowRecorder, message: "FlowPlayback: \(success ? "completed" : "cancelled") — \(failedActionIndices.count) failed, \(healedActionCount) healed", level: success ? (failedActionIndices.isEmpty ? .success : .warning) : .warning)
        onComplete(success)
    }

    func testActionWithMethod(_ action: RecordedAction, method: ActionAutomationMethod, in webView: WKWebView, textboxValues: [String: String]) async -> Bool {
        switch method {
        case .humanClick:
            return await executeHumanTouchChainClick(action, in: webView)
        case .jsClick:
            return await executeJSClick(action, in: webView)
        case .pointerDispatch:
            return await executePointerDispatch(action, in: webView)
        case .formSubmit:
            return await executeFormSubmit(action, in: webView)
        case .enterKey:
            return await executeEnterKey(in: webView)
        case .ocrTextDetect:
            return await executeOCRClick(action, in: webView)
        case .coordinateClick:
            return await executeCoordinateClick(action, in: webView)
        case .visionMLDetect:
            return await executeVisionMLClick(action, in: webView)
        case .screenshotCropNav:
            return await executeScreenshotCropClick(action, in: webView)
        case .focusThenClick:
            return await executeFocusThenClick(action, in: webView)
        case .tabNavigation:
            return await executeTabNavigation(action, in: webView)
        case .nativeSetterFill:
            if let label = action.textboxLabel {
                let value = textboxValues[label] ?? action.textContent ?? ""
                return await executeNativeSetterFill(selector: action.targetSelector ?? "", value: value, in: webView)
            }
            return false
        case .execCommandInsert:
            if let label = action.textboxLabel {
                let value = textboxValues[label] ?? action.textContent ?? ""
                return await executeExecCommandInsert(value: value, in: webView)
            }
            return false
        case .mouseHoverThenClick:
            return await executeHoverThenClick(action, in: webView)
        }
    }

    // MARK: - Individual Method Implementations

    private func executeHumanTouchChainClick(_ action: RecordedAction, in webView: WKWebView) async -> Bool {
        guard let pos = action.mousePosition else { return false }
        let js = """
        (function(){
            var el = document.elementFromPoint(\(pos.x), \(pos.y));
            if (!el) return 'NO_ELEMENT';
            try {
                el.dispatchEvent(new PointerEvent('pointerover',{bubbles:true,clientX:\(pos.x),clientY:\(pos.y),pointerId:1,pointerType:'touch'}));
                el.dispatchEvent(new PointerEvent('pointerenter',{bubbles:false,clientX:\(pos.x),clientY:\(pos.y),pointerId:1,pointerType:'touch'}));
                el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y),pointerId:1,pointerType:'touch',button:0,buttons:1}));
                el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y),button:0,buttons:1}));
                el.focus();
                el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y),pointerId:1,pointerType:'touch',button:0}));
                el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y),button:0}));
                el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y),button:0}));
                if (typeof el.click === 'function') el.click();
                if (el.tagName === 'BUTTON' || el.type === 'submit') {
                    var form = el.closest('form');
                    if (form) { try { form.requestSubmit(); } catch(e) { form.submit(); } }
                }
                if (el.tagName === 'A' && el.href) { window.location.href = el.href; }
                return 'OK';
            } catch(e) { return 'ERROR:' + e.message; }
        })()
        """
        let result = await safeEvalJS(js, in: webView)
        return result == "OK"
    }

    private func executeJSClick(_ action: RecordedAction, in webView: WKWebView) async -> Bool {
        guard let pos = action.mousePosition else { return false }
        let js = """
        (function(){
            var el = document.elementFromPoint(\(pos.x), \(pos.y));
            if (!el) return 'NO_ELEMENT';
            try { el.click(); return 'OK'; } catch(e) { return 'ERROR:' + e.message; }
        })()
        """
        let result = await safeEvalJS(js, in: webView)
        return result == "OK"
    }

    private func executePointerDispatch(_ action: RecordedAction, in webView: WKWebView) async -> Bool {
        guard let pos = action.mousePosition else { return false }
        let js = """
        (function(){
            var el = document.elementFromPoint(\(pos.x), \(pos.y));
            if (!el) return 'NO_ELEMENT';
            try {
                var touch = new Touch({identifier:Date.now(),target:el,clientX:\(pos.x),clientY:\(pos.y),pageX:\(pos.viewportX),pageY:\(pos.viewportY)});
                el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[touch],targetTouches:[touch],changedTouches:[touch]}));
                el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[touch]}));
                el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y)}));
                return 'OK';
            } catch(e) {
                el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y),pointerId:1,pointerType:'touch'}));
                el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y),pointerId:1,pointerType:'touch'}));
                el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y)}));
                return 'FALLBACK';
            }
        })()
        """
        let result = await safeEvalJS(js, in: webView)
        return result == "OK" || result == "FALLBACK"
    }

    private func executeFormSubmit(_ action: RecordedAction, in webView: WKWebView) async -> Bool {
        let js = """
        (function(){
            var forms = document.querySelectorAll('form');
            if (forms.length === 0) return 'NO_FORM';
            var form = forms[0];
            try {
                if (form.requestSubmit) { form.requestSubmit(); }
                else { form.submit(); }
                return 'OK';
            } catch(e) { return 'ERROR:' + e.message; }
        })()
        """
        let result = await safeEvalJS(js, in: webView)
        return result == "OK"
    }

    private func executeEnterKey(in webView: WKWebView) async -> Bool {
        let js = """
        (function(){
            var el = document.activeElement || document.body;
            el.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
            el.dispatchEvent(new KeyboardEvent('keypress',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
            el.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
            var form = el.closest ? el.closest('form') : null;
            if (form) { try { form.requestSubmit(); } catch(e) { form.submit(); } }
            return 'OK';
        })()
        """
        let result = await safeEvalJS(js, in: webView)
        return result == "OK"
    }

    private func executeOCRClick(_ action: RecordedAction, in webView: WKWebView) async -> Bool {
        guard let screenshot = await captureWebViewScreenshot(webView) else { return false }
        let viewportSize = webView.frame.size.width > 0 ? webView.frame.size : CGSize(width: 390, height: 844)

        let searchTerms = [
            action.textboxLabel,
            action.textContent,
            action.targetTagName
        ].compactMap { $0 }.filter { !$0.isEmpty }

        for term in searchTerms {
            let hit = await visionML.findTextOnScreen(term, in: screenshot, viewportSize: viewportSize)
            if let hit {
                let js = buildVisionClickJS(x: hit.pixelCoordinate.x, y: hit.pixelCoordinate.y)
                let result = await safeEvalJS(js, in: webView)
                if result?.hasPrefix("CLICKED") == true { return true }
            }
        }

        let buttonTexts = ["Log in", "Login", "Sign in", "Submit", "Continue", "Next", "Enter", "Go"]
        for text in buttonTexts {
            let hit = await visionML.findTextOnScreen(text, in: screenshot, viewportSize: viewportSize)
            if let hit {
                let js = buildVisionClickJS(x: hit.pixelCoordinate.x, y: hit.pixelCoordinate.y)
                let result = await safeEvalJS(js, in: webView)
                if result?.hasPrefix("CLICKED") == true { return true }
            }
        }

        return false
    }

    private func executeCoordinateClick(_ action: RecordedAction, in webView: WKWebView) async -> Bool {
        guard let pos = action.mousePosition else { return false }
        let js = """
        (function(){
            var el = document.elementFromPoint(\(pos.x), \(pos.y));
            if (!el) return 'NO_ELEMENT';
            el.focus();
            el.click();
            return 'OK';
        })()
        """
        let result = await safeEvalJS(js, in: webView)
        return result == "OK"
    }

    private func executeVisionMLClick(_ action: RecordedAction, in webView: WKWebView) async -> Bool {
        guard let screenshot = await captureWebViewScreenshot(webView) else { return false }
        let viewportSize = webView.frame.size.width > 0 ? webView.frame.size : CGSize(width: 390, height: 844)
        let detection = await visionML.detectLoginElements(in: screenshot, viewportSize: viewportSize)

        if action.type == .click || action.type == .mouseDown {
            if let btn = detection.loginButton {
                let js = buildVisionClickJS(x: btn.pixelCoordinate.x, y: btn.pixelCoordinate.y)
                let result = await safeEvalJS(js, in: webView)
                return result?.hasPrefix("CLICKED") == true
            }
        }

        if let label = action.textboxLabel?.lowercased() {
            if label.contains("email") || label.contains("user") {
                if let field = detection.emailField {
                    let js = buildVisionClickJS(x: field.pixelCoordinate.x, y: field.pixelCoordinate.y)
                    _ = await safeEvalJS(js, in: webView)
                    return true
                }
            }
            if label.contains("pass") {
                if let field = detection.passwordField {
                    let js = buildVisionClickJS(x: field.pixelCoordinate.x, y: field.pixelCoordinate.y)
                    _ = await safeEvalJS(js, in: webView)
                    return true
                }
            }
        }

        return false
    }

    private func executeScreenshotCropClick(_ action: RecordedAction, in webView: WKWebView) async -> Bool {
        guard let pos = action.mousePosition else { return false }
        guard let screenshot = await captureWebViewScreenshot(webView) else { return false }

        let cropSize: CGFloat = 60
        let rect = CGRect(
            x: max(0, pos.x - cropSize / 2),
            y: max(0, pos.y - cropSize / 2),
            width: cropSize,
            height: cropSize
        )

        guard let cgImage = screenshot.cgImage,
              let cropped = cgImage.cropping(to: rect) else { return false }

        let viewportSize = webView.frame.size.width > 0 ? webView.frame.size : CGSize(width: 390, height: 844)
        let croppedImage = UIImage(cgImage: cropped)

        let allText = await visionML.recognizeAllText(in: croppedImage)
        if !allText.isEmpty {
            let bestText = allText.first?.text ?? ""
            let hit = await visionML.findTextOnScreen(bestText, in: screenshot, viewportSize: viewportSize)
            if let hit {
                let js = buildVisionClickJS(x: hit.pixelCoordinate.x, y: hit.pixelCoordinate.y)
                let result = await safeEvalJS(js, in: webView)
                return result?.hasPrefix("CLICKED") == true
            }
        }

        let js = buildVisionClickJS(x: pos.x, y: pos.y)
        let result = await safeEvalJS(js, in: webView)
        return result?.hasPrefix("CLICKED") == true
    }

    private func executeFocusThenClick(_ action: RecordedAction, in webView: WKWebView) async -> Bool {
        guard let pos = action.mousePosition else { return false }
        let js = """
        (function(){
            var el = document.elementFromPoint(\(pos.x), \(pos.y));
            if (!el) return 'NO_ELEMENT';
            el.focus();
            el.dispatchEvent(new Event('focus',{bubbles:true}));
            el.dispatchEvent(new Event('focusin',{bubbles:true}));
            el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y)}));
            if (typeof el.click === 'function') el.click();
            return 'OK';
        })()
        """
        let result = await safeEvalJS(js, in: webView)
        return result == "OK"
    }

    private func executeTabNavigation(_ action: RecordedAction, in webView: WKWebView) async -> Bool {
        let js = """
        (function(){
            var el = document.activeElement || document.body;
            for (var i = 0; i < 20; i++) {
                el.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',code:'Tab',keyCode:9,which:9,bubbles:true}));
                el.dispatchEvent(new KeyboardEvent('keyup',{key:'Tab',code:'Tab',keyCode:9,which:9,bubbles:true}));
                el = document.activeElement;
                if (el && (el.tagName === 'BUTTON' || el.type === 'submit')) {
                    el.click();
                    return 'CLICKED_AFTER_' + i + '_TABS';
                }
            }
            return 'NO_BUTTON_FOUND';
        })()
        """
        let result = await safeEvalJS(js, in: webView)
        return result?.hasPrefix("CLICKED") == true
    }

    private func executeNativeSetterFill(selector: String, value: String, in webView: WKWebView) async -> Bool {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let selEscaped = selector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function(){
            var el = document.querySelector('\(selEscaped)') || document.activeElement;
            if (!el || el === document.body) return 'NO_ELEMENT';
            el.focus();
            el.value = '';
            var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (ns && ns.set) { ns.set.call(el, '\(escaped)'); } else { el.value = '\(escaped)'; }
            el.dispatchEvent(new InputEvent('input', {bubbles:true, inputType:'insertText', data:'\(escaped)'}));
            el.dispatchEvent(new Event('change', {bubbles:true}));
            return el.value.length > 0 ? 'OK' : 'EMPTY';
        })()
        """
        let result = await safeEvalJS(js, in: webView)
        return result == "OK"
    }

    private func executeExecCommandInsert(value: String, in webView: WKWebView) async -> Bool {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function(){
            var el = document.activeElement;
            if (!el || el === document.body) return 'NO_ELEMENT';
            el.focus();
            el.value = '';
            try { document.execCommand('insertText', false, '\(escaped)'); return el.value.length > 0 ? 'OK' : 'EMPTY'; }
            catch(e) { return 'ERROR:' + e.message; }
        })()
        """
        let result = await safeEvalJS(js, in: webView)
        return result == "OK"
    }

    private func executeHoverThenClick(_ action: RecordedAction, in webView: WKWebView) async -> Bool {
        guard let pos = action.mousePosition else { return false }
        let js = """
        (function(){
            var el = document.elementFromPoint(\(pos.x), \(pos.y));
            if (!el) return 'NO_ELEMENT';
            el.dispatchEvent(new MouseEvent('mouseenter',{bubbles:false,clientX:\(pos.x),clientY:\(pos.y)}));
            el.dispatchEvent(new MouseEvent('mouseover',{bubbles:true,clientX:\(pos.x),clientY:\(pos.y)}));
            el.dispatchEvent(new MouseEvent('mousemove',{bubbles:true,clientX:\(pos.x),clientY:\(pos.y)}));
            return 'HOVERED';
        })()
        """
        _ = await safeEvalJS(js, in: webView)
        try? await Task.sleep(for: .milliseconds(200))

        let clickJS = """
        (function(){
            var el = document.elementFromPoint(\(pos.x), \(pos.y));
            if (!el) return 'NO_ELEMENT';
            el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y),button:0,buttons:1}));
            el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y),button:0}));
            el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y),button:0}));
            if (typeof el.click === 'function') el.click();
            return 'OK';
        })()
        """
        let result = await safeEvalJS(clickJS, in: webView)
        return result == "OK"
    }

    // MARK: - Flow Optimization

    func optimizeFlow(_ flow: RecordedFlow, settings: FlowOptimizationSettings) -> RecordedFlow {
        var optimized = flow

        if settings.stripRedundantMouseMoves {
            var kept: [RecordedAction] = []
            var consecutiveMoves = 0
            for action in optimized.actions {
                if action.type == .mouseMove {
                    consecutiveMoves += 1
                    if consecutiveMoves % max(1, settings.mouseMoveSampleRate) == 0 {
                        kept.append(action)
                    }
                } else {
                    consecutiveMoves = 0
                    kept.append(action)
                }
            }
            optimized.actions = kept
        }

        if settings.capMaxDelay > 0 {
            for i in 0..<optimized.actions.count {
                if optimized.actions[i].deltaFromPreviousMs > settings.capMaxDelay {
                    optimized.actions[i] = rebuildAction(optimized.actions[i], delta: settings.capMaxDelay)
                }
            }
        }

        if settings.enforceMinDelay > 0 {
            for i in 0..<optimized.actions.count {
                if optimized.actions[i].deltaFromPreviousMs > 0 && optimized.actions[i].deltaFromPreviousMs < settings.enforceMinDelay {
                    optimized.actions[i] = rebuildAction(optimized.actions[i], delta: settings.enforceMinDelay)
                }
            }
        }

        if settings.addTimingVariance {
            let variance = settings.variancePercent / 100.0
            for i in 0..<optimized.actions.count {
                let base = optimized.actions[i].deltaFromPreviousMs
                if base > 0 {
                    let jitter = base * Double.random(in: -variance...variance)
                    optimized.actions[i] = rebuildAction(optimized.actions[i], delta: max(1, base + jitter))
                }
            }
        }

        if settings.applyTimeScale != 1.0 {
            for i in 0..<optimized.actions.count {
                let scaled = optimized.actions[i].deltaFromPreviousMs * settings.applyTimeScale
                optimized.actions[i] = rebuildAction(optimized.actions[i], delta: max(1, scaled))
            }
        }

        if settings.addHumanPauses {
            var withPauses: [RecordedAction] = []
            for (i, action) in optimized.actions.enumerated() {
                if i > 0 && (action.type == .click || action.type == .input || action.type == .textboxEntry) {
                    let pauseMs = Double.random(in: settings.humanPauseMinMs...settings.humanPauseMaxMs)
                    let pauseAction = RecordedAction(
                        type: .pause,
                        timestampMs: action.timestampMs - pauseMs,
                        deltaFromPreviousMs: pauseMs
                    )
                    withPauses.append(pauseAction)
                }
                withPauses.append(action)
            }
            optimized.actions = withPauses
        }

        if settings.gaussianDistribution {
            for i in 0..<optimized.actions.count {
                let base = optimized.actions[i].deltaFromPreviousMs
                if base > 10 {
                    let u1 = Double.random(in: 0.0001...1.0)
                    let u2 = Double.random(in: 0.0001...1.0)
                    let gaussian = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
                    let stddev = base * 0.15
                    let adjusted = max(1, base + gaussian * stddev)
                    optimized.actions[i] = rebuildAction(optimized.actions[i], delta: adjusted)
                }
            }
        }

        optimized.actionCount = optimized.actions.count
        optimized.totalDurationMs = optimized.actions.reduce(0) { $0 + $1.deltaFromPreviousMs }
        return optimized
    }

    // MARK: - Execute with Healing

    private func executeActionWithHealing(_ action: RecordedAction, index: Int, in webView: WKWebView, textboxValues: [String: String], sessionId: String) async -> Bool {
        let result = await executeAction(action, in: webView, textboxValues: textboxValues, sessionId: sessionId)
        if result { return true }

        if action.type == .click || action.type == .mouseDown || action.type == .mouseUp {
            if let pos = action.mousePosition {
                let healResult = await healClickAction(pos: pos, in: webView)
                if healResult {
                    healedActionCount += 1
                    return true
                }
            }
        }

        if action.type == .input || action.type == .textboxEntry {
            if let sel = action.targetSelector, let label = action.textboxLabel {
                let value = textboxValues[label] ?? action.textContent ?? ""
                let healResult = await healInputAction(selector: sel, value: value, in: webView)
                if healResult {
                    healedActionCount += 1
                    return true
                }
            }
        }

        if action.type == .focus {
            if let sel = action.targetSelector {
                let healResult = await healFocusAction(selector: sel, in: webView)
                if healResult {
                    healedActionCount += 1
                    return true
                }
            }
        }

        let visionHealed = await healWithVision(action, index: index, in: webView, textboxValues: textboxValues, sessionId: sessionId)
        if visionHealed {
            healedActionCount += 1
            return true
        }

        return false
    }

    private func healWithVision(_ action: RecordedAction, index: Int, in webView: WKWebView, textboxValues: [String: String], sessionId: String) async -> Bool {
        guard let screenshot = await captureWebViewScreenshot(webView) else { return false }
        let viewportSize = webView.frame.size.width > 0 ? webView.frame.size : CGSize(width: 390, height: 844)

        if action.type == .click || action.type == .mouseDown || action.type == .mouseUp {
            if let label = action.textboxLabel ?? action.targetTagName {
                let hit = await visionML.findTextOnScreen(label, in: screenshot, viewportSize: viewportSize)
                if let hit {
                    let js = buildVisionClickJS(x: hit.pixelCoordinate.x, y: hit.pixelCoordinate.y)
                    let result = await safeEvalJS(js, in: webView)
                    return result?.hasPrefix("CLICKED") == true || result == "HEALED"
                }
            }

            let detection = await visionML.detectLoginElements(in: screenshot, viewportSize: viewportSize)
            if let btnHit = detection.loginButton {
                let js = buildVisionClickJS(x: btnHit.pixelCoordinate.x, y: btnHit.pixelCoordinate.y)
                let result = await safeEvalJS(js, in: webView)
                return result?.hasPrefix("CLICKED") == true || result == "HEALED"
            }
        }

        if action.type == .input || action.type == .textboxEntry || action.type == .focus {
            if let label = action.textboxLabel {
                let detection = await visionML.detectLoginElements(in: screenshot, viewportSize: viewportSize)
                let lowerLabel = label.lowercased()

                var targetCoord: CGPoint?
                if lowerLabel.contains("email") || lowerLabel.contains("user") {
                    targetCoord = detection.emailField?.pixelCoordinate
                } else if lowerLabel.contains("pass") {
                    targetCoord = detection.passwordField?.pixelCoordinate
                }

                if let coord = targetCoord {
                    let clickJS = buildVisionClickJS(x: coord.x, y: coord.y)
                    _ = await safeEvalJS(clickJS, in: webView)
                    try? await Task.sleep(for: .milliseconds(200))

                    if action.type == .input || action.type == .textboxEntry {
                        let value = textboxValues[label] ?? action.textContent ?? ""
                        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                        let typeJS = """
                        (function(){
                            var el = document.activeElement;
                            if (!el || el === document.body) return 'NO_ACTIVE';
                            el.value = '';
                            var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                            if (ns && ns.set) { ns.set.call(el, '\(escaped)'); } else { el.value = '\(escaped)'; }
                            el.dispatchEvent(new Event('input', {bubbles:true}));
                            el.dispatchEvent(new Event('change', {bubbles:true}));
                            return el.value.length > 0 ? 'TYPED' : 'EMPTY';
                        })()
                        """
                        let result = await safeEvalJS(typeJS, in: webView)
                        return result == "TYPED"
                    }
                    return true
                }
            }
        }

        return false
    }

    private func buildVisionClickJS(x: CGFloat, y: CGFloat) -> String {
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
                if (el.tagName === 'A' && el.href) { window.location.href = el.href; }
                if (el.tagName === 'BUTTON' || el.type === 'submit') {
                    var form = el.closest('form');
                    if (form) form.requestSubmit ? form.requestSubmit() : form.submit();
                }
                return 'CLICKED:' + el.tagName;
            } catch(e) { return 'ERROR:' + e.message; }
        })()
        """
    }

    private func captureWebViewScreenshot(_ webView: WKWebView) async -> UIImage? {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: Int(webView.frame.width))
        do {
            return try await webView.takeSnapshot(configuration: config)
        } catch {
            return nil
        }
    }

    private func healClickAction(pos: RecordedMousePosition, in webView: WKWebView) async -> Bool {
        let js = """
        (function(){
            var el = document.elementFromPoint(\(pos.x), \(pos.y));
            if (!el) return 'NO_ELEMENT';
            try {
                el.focus();
                el.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y),pointerId:1,pointerType:'touch'}));
                el.dispatchEvent(new MouseEvent('mousedown', {bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y)}));
                el.dispatchEvent(new PointerEvent('pointerup', {bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y),pointerId:1,pointerType:'touch'}));
                el.dispatchEvent(new MouseEvent('mouseup', {bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y)}));
                el.dispatchEvent(new MouseEvent('click', {bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y)}));
                if (typeof el.click === 'function') el.click();
                if (el.tagName === 'A' && el.href) { window.location.href = el.href; }
                if (el.tagName === 'BUTTON' || el.type === 'submit') {
                    var form = el.closest('form');
                    if (form) form.requestSubmit ? form.requestSubmit() : form.submit();
                }
                return 'HEALED';
            } catch(e) { return 'ERROR:' + e.message; }
        })()
        """
        let result = await safeEvalJS(js, in: webView)
        return result == "HEALED"
    }

    private func healInputAction(selector: String, value: String, in webView: WKWebView) async -> Bool {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let selEscaped = selector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function(){
            var el = document.querySelector('\(selEscaped)');
            if (!el) {
                el = document.activeElement;
                if (!el || el === document.body) {
                    var inputs = document.querySelectorAll('input:not([type=hidden]), textarea');
                    for (var i = 0; i < inputs.length; i++) {
                        if (!inputs[i].value || inputs[i].value.length === 0) { el = inputs[i]; break; }
                    }
                }
            }
            if (!el || el === document.body) return 'NO_ELEMENT';
            try {
                el.focus();
                el.value = '';
                var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                if (ns && ns.set) { ns.set.call(el, '\(escaped)'); } else { el.value = '\(escaped)'; }
                el.dispatchEvent(new Event('focus', {bubbles:true}));
                el.dispatchEvent(new InputEvent('input', {bubbles:true, inputType:'insertText', data:'\(escaped)'}));
                el.dispatchEvent(new Event('change', {bubbles:true}));
                return el.value === '\(escaped)' ? 'HEALED' : 'VALUE_MISMATCH';
            } catch(e) { return 'ERROR:' + e.message; }
        })()
        """
        let result = await safeEvalJS(js, in: webView)
        return result == "HEALED" || result == "VALUE_MISMATCH"
    }

    private func healFocusAction(selector: String, in webView: WKWebView) async -> Bool {
        let selEscaped = selector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function(){
            var el = document.querySelector('\(selEscaped)');
            if (!el) {
                var all = document.querySelectorAll('input, textarea, select, button, [tabindex]');
                if (all.length > 0) { el = all[0]; }
            }
            if (!el) return 'NO_ELEMENT';
            try {
                el.focus();
                el.dispatchEvent(new Event('focus', {bubbles:true}));
                el.dispatchEvent(new Event('focusin', {bubbles:true}));
                return 'HEALED';
            } catch(e) { return 'ERROR:' + e.message; }
        })()
        """
        let result = await safeEvalJS(js, in: webView)
        return result == "HEALED"
    }

    private func executeAction(_ action: RecordedAction, in webView: WKWebView, textboxValues: [String: String], sessionId: String) async -> Bool {
        switch action.type {
        case .mouseMove:
            guard let pos = action.mousePosition else { return true }
            let js = """
            (function(){
                var el = document.elementFromPoint(\(pos.x), \(pos.y));
                if (el) {
                    el.dispatchEvent(new MouseEvent('mousemove', {
                        bubbles: true, cancelable: true,
                        clientX: \(pos.x), clientY: \(pos.y)
                    }));
                    return 'OK';
                }
                return 'NO_ELEMENT';
            })()
            """
            let result = await safeEvalJS(js, in: webView)
            return result != nil

        case .mouseDown:
            guard let pos = action.mousePosition else { return true }
            let btn = action.button ?? 0
            let js = """
            (function(){
                var el = document.elementFromPoint(\(pos.x), \(pos.y));
                if (el) {
                    el.dispatchEvent(new PointerEvent('pointerdown', {
                        bubbles: true, cancelable: true,
                        clientX: \(pos.x), clientY: \(pos.y),
                        pointerId: 1, pointerType: 'mouse', button: \(btn), buttons: 1
                    }));
                    el.dispatchEvent(new MouseEvent('mousedown', {
                        bubbles: true, cancelable: true,
                        clientX: \(pos.x), clientY: \(pos.y),
                        button: \(btn), buttons: 1
                    }));
                    return 'OK';
                }
                return 'NO_ELEMENT';
            })()
            """
            let result = await safeEvalJS(js, in: webView)
            return result == "OK"

        case .mouseUp:
            guard let pos = action.mousePosition else { return true }
            let btn = action.button ?? 0
            let js = """
            (function(){
                var el = document.elementFromPoint(\(pos.x), \(pos.y));
                if (el) {
                    el.dispatchEvent(new PointerEvent('pointerup', {
                        bubbles: true, cancelable: true,
                        clientX: \(pos.x), clientY: \(pos.y),
                        pointerId: 1, pointerType: 'mouse', button: \(btn)
                    }));
                    el.dispatchEvent(new MouseEvent('mouseup', {
                        bubbles: true, cancelable: true,
                        clientX: \(pos.x), clientY: \(pos.y),
                        button: \(btn)
                    }));
                    return 'OK';
                }
                return 'NO_ELEMENT';
            })()
            """
            let result = await safeEvalJS(js, in: webView)
            return result == "OK"

        case .click:
            guard let pos = action.mousePosition else { return true }
            let btn = action.button ?? 0
            let js = """
            (function(){
                var el = document.elementFromPoint(\(pos.x), \(pos.y));
                if (el) {
                    el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y),pointerId:1,pointerType:'mouse',button:\(btn),buttons:1}));
                    el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y),button:\(btn),buttons:1}));
                    el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y),pointerId:1,pointerType:'mouse',button:\(btn)}));
                    el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y),button:\(btn)}));
                    el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y),button:\(btn)}));
                    if (typeof el.click === 'function') el.click();
                    return 'OK';
                }
                return 'NO_ELEMENT';
            })()
            """
            let result = await safeEvalJS(js, in: webView)
            return result == "OK"

        case .doubleClick:
            guard let pos = action.mousePosition else { return true }
            let js = """
            (function(){
                var el = document.elementFromPoint(\(pos.x), \(pos.y));
                if (el) {
                    el.dispatchEvent(new MouseEvent('dblclick', {bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y)}));
                    return 'OK';
                }
                return 'NO_ELEMENT';
            })()
            """
            let result = await safeEvalJS(js, in: webView)
            return result == "OK"

        case .scroll:
            let dx = action.scrollDeltaX ?? 0
            let dy = action.scrollDeltaY ?? 0
            let js = """
            (function(){
                window.scrollBy({ left: \(dx), top: \(dy), behavior: 'auto' });
                document.dispatchEvent(new WheelEvent('wheel', {
                    bubbles: true, cancelable: true,
                    deltaX: \(dx), deltaY: \(dy), deltaMode: 0
                }));
                return 'OK';
            })()
            """
            _ = await safeEvalJS(js, in: webView)
            return true

        case .keyDown, .keyPress, .keyUp:
            let eventName: String
            switch action.type {
            case .keyDown: eventName = "keydown"
            case .keyPress: eventName = "keypress"
            case .keyUp: eventName = "keyup"
            default: return true
            }

            if let label = action.textboxLabel, action.type == .keyDown {
                if let _ = textboxValues[label] {
                    if let key = action.key, key.count == 1 {
                        return true
                    }
                }
            }

            let key = (action.key ?? "").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\\", with: "\\\\")
            let code = (action.code ?? "").replacingOccurrences(of: "'", with: "\\'")
            let kc = action.keyCode ?? 0
            let shift = action.shiftKey ?? false
            let ctrl = action.ctrlKey ?? false
            let alt = action.altKey ?? false
            let meta = action.metaKey ?? false

            let targetJS: String
            if let sel = action.targetSelector {
                let escaped = sel.replacingOccurrences(of: "'", with: "\\'")
                targetJS = "document.querySelector('\(escaped)') || document.activeElement || document.body"
            } else {
                targetJS = "document.activeElement || document.body"
            }

            let js = """
            (function(){
                var el = \(targetJS);
                if (el) {
                    el.dispatchEvent(new KeyboardEvent('\(eventName)', {
                        key: '\(key)', code: '\(code)',
                        keyCode: \(kc), which: \(kc), charCode: \(action.charCode ?? 0),
                        bubbles: true, cancelable: true,
                        shiftKey: \(shift), ctrlKey: \(ctrl), altKey: \(alt), metaKey: \(meta)
                    }));
                    return 'OK';
                }
                return 'NO_ELEMENT';
            })()
            """
            _ = await safeEvalJS(js, in: webView)
            return true

        case .input:
            if let label = action.textboxLabel, let sel = action.targetSelector {
                let value: String
                if let replacement = textboxValues[label] {
                    value = replacement
                } else {
                    value = action.textContent ?? ""
                }
                let escaped = value.replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\\", with: "\\\\")
                let selEscaped = sel.replacingOccurrences(of: "'", with: "\\'")
                let js = """
                (function(){
                    var el = document.querySelector('\(selEscaped)') || document.activeElement;
                    if (el) {
                        var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                        if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, '\(escaped)'); }
                        else { el.value = '\(escaped)'; }
                        el.dispatchEvent(new InputEvent('input', {bubbles:true,inputType:'insertText',data:'\(escaped)'}));
                        el.dispatchEvent(new Event('change', {bubbles:true}));
                        return el.value === '\(escaped)' ? 'OK' : 'VALUE_MISMATCH';
                    }
                    return 'NO_ELEMENT';
                })()
                """
                let result = await safeEvalJS(js, in: webView)
                return result == "OK" || result == "VALUE_MISMATCH"
            }
            return true

        case .focus:
            if let sel = action.targetSelector {
                let escaped = sel.replacingOccurrences(of: "'", with: "\\'")
                let js = """
                (function(){
                    var el = document.querySelector('\(escaped)');
                    if (el) { el.focus(); el.dispatchEvent(new Event('focus',{bubbles:true})); return 'OK'; }
                    return 'NO_ELEMENT';
                })()
                """
                let result = await safeEvalJS(js, in: webView)
                return result == "OK"
            }
            return true

        case .blur:
            if let sel = action.targetSelector {
                let escaped = sel.replacingOccurrences(of: "'", with: "\\'")
                let js = """
                (function(){
                    var el = document.querySelector('\(escaped)');
                    if (el) { el.blur(); el.dispatchEvent(new Event('blur',{bubbles:true})); return 'OK'; }
                    return 'NO_ELEMENT';
                })()
                """
                _ = await safeEvalJS(js, in: webView)
            }
            return true

        case .touchStart, .touchEnd, .touchMove:
            guard let pos = action.mousePosition else { return true }
            let touchEventName: String
            let pointerEventName: String
            switch action.type {
            case .touchStart:
                touchEventName = "touchstart"
                pointerEventName = "pointerdown"
            case .touchEnd:
                touchEventName = "touchend"
                pointerEventName = "pointerup"
            case .touchMove:
                touchEventName = "touchmove"
                pointerEventName = "pointermove"
            default: return true
            }
            let isTouchEnd = action.type == .touchEnd ? "true" : "false"
            let js = """
            (function(){
                var el = document.elementFromPoint(\(pos.x), \(pos.y));
                if (el) {
                    try {
                        var t = new Touch({identifier:Date.now(),target:el,clientX:\(pos.x),clientY:\(pos.y),pageX:\(pos.viewportX),pageY:\(pos.viewportY)});
                        var touches = \(isTouchEnd) ? [] : [t];
                        el.dispatchEvent(new TouchEvent('\(touchEventName)',{bubbles:true,cancelable:true,touches:touches,targetTouches:touches,changedTouches:[t]}));
                        return 'OK';
                    } catch(e) {
                        el.dispatchEvent(new PointerEvent('\(pointerEventName)',{bubbles:true,cancelable:true,clientX:\(pos.x),clientY:\(pos.y),pointerId:1,pointerType:'touch'}));
                        return 'FALLBACK';
                    }
                }
                return 'NO_ELEMENT';
            })()
            """
            _ = await safeEvalJS(js, in: webView)
            return true

        case .textboxEntry:
            if let label = action.textboxLabel, let sel = action.targetSelector {
                let value = textboxValues[label] ?? action.textContent ?? ""
                let typeResult = await typeHumanLike(value, selector: sel, in: webView, sessionId: sessionId)
                return typeResult
            }
            return true

        case .pageLoad, .navigationStart, .pause:
            return true
        }
    }

    private func typeHumanLike(_ text: String, selector: String, in webView: WKWebView, sessionId: String) async -> Bool {
        let escaped = selector.replacingOccurrences(of: "'", with: "\\'")
        let focusJS = """
        (function(){
            var el = document.querySelector('\(escaped)');
            if (el) { el.focus(); el.value = ''; el.dispatchEvent(new Event('focus',{bubbles:true})); return 'OK'; }
            return 'NOT_FOUND';
        })()
        """
        let focusResult = await safeEvalJS(focusJS, in: webView)
        if focusResult == "NOT_FOUND" { return false }

        for char in text {
            let charStr = String(char).replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\\", with: "\\\\")
            let kc = charKeyCode(char)
            let js = """
            (function(){
                var el = document.activeElement;
                if (!el) return 'NO_ACTIVE';
                el.dispatchEvent(new KeyboardEvent('keydown',{key:'\(charStr)',keyCode:\(kc),which:\(kc),bubbles:true,cancelable:true}));
                var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value');
                var nv = (el.value||'')+'\(charStr)';
                if(ns&&ns.set){ns.set.call(el,nv);}else{el.value=nv;}
                el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:'\(charStr)'}));
                el.dispatchEvent(new KeyboardEvent('keyup',{key:'\(charStr)',keyCode:\(kc),which:\(kc),bubbles:true}));
                return 'OK';
            })()
            """
            _ = await safeEvalJS(js, in: webView)
            let delay = Int.random(in: 35...180)
            try? await Task.sleep(for: .milliseconds(delay))
        }
        return true
    }

    private func safeEvalJS(_ js: String, in webView: WKWebView) async -> String? {
        do {
            let result = try await webView.evaluateJavaScript(js)
            if let str = result as? String { return str }
            if let num = result as? NSNumber { return "\(num)" }
            return nil
        } catch {
            return nil
        }
    }

    private func charKeyCode(_ char: Character) -> Int {
        let s = String(char).uppercased()
        guard let ascii = s.unicodeScalars.first?.value else { return 0 }
        if ascii >= 65 && ascii <= 90 { return Int(ascii) }
        if ascii >= 48 && ascii <= 57 { return Int(ascii) }
        switch char {
        case "@": return 50
        case ".": return 190
        case "-": return 189
        case "_": return 189
        default: return Int(ascii)
        }
    }

    private func rebuildAction(_ a: RecordedAction, delta: Double) -> RecordedAction {
        RecordedAction(
            id: a.id, type: a.type, timestampMs: a.timestampMs, deltaFromPreviousMs: delta,
            mousePosition: a.mousePosition, scrollDeltaX: a.scrollDeltaX, scrollDeltaY: a.scrollDeltaY,
            keyCode: a.keyCode, key: a.key, code: a.code, charCode: a.charCode,
            targetSelector: a.targetSelector, targetTagName: a.targetTagName, targetType: a.targetType,
            textboxLabel: a.textboxLabel, textContent: a.textContent,
            button: a.button, buttons: a.buttons, holdDurationMs: a.holdDurationMs,
            isTrusted: a.isTrusted, shiftKey: a.shiftKey, ctrlKey: a.ctrlKey, altKey: a.altKey, metaKey: a.metaKey
        )
    }
}

nonisolated struct FlowOptimizationSettings: Sendable {
    var stripRedundantMouseMoves: Bool = true
    var mouseMoveSampleRate: Int = 5
    var capMaxDelay: Double = 3000
    var enforceMinDelay: Double = 10
    var addTimingVariance: Bool = true
    var variancePercent: Double = 20
    var applyTimeScale: Double = 1.0
    var addHumanPauses: Bool = false
    var humanPauseMinMs: Double = 50
    var humanPauseMaxMs: Double = 300
    var gaussianDistribution: Bool = true
}
