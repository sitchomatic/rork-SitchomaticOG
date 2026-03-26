import Foundation
import SwiftUI
import WebKit
import UIKit

struct FlowRecorderWebView: UIViewRepresentable {
    let url: URL
    let isRecording: Bool
    let onActionsReceived: ([RecordedAction]) -> Void
    let onPageLoaded: (String) -> Void
    let webViewRef: (WKWebView) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let contentController = WKUserContentController()

        let stealth = PPSRStealthService.shared
        let profile = stealth.nextProfileSync()
        let stealthScript = WKUserScript(
            source: stealth.buildComprehensiveStealthJSPublic(profile: profile),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(stealthScript)

        let recorderScript = WKUserScript(
            source: Self.recorderInjectionJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(recorderScript)

        contentController.add(context.coordinator, name: "flowRecorder")

        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = profile.userAgent
        webView.navigationDelegate = context.coordinator

        context.coordinator.webView = webView
        webViewRef(webView)

        DebugLogger.shared.log("FlowRecorderWebView: created webView, loading \(url.absoluteString)", category: .flowRecorder, level: .info, metadata: [
            "url": url.absoluteString,
            "userAgent": profile.userAgent.prefix(60).description
        ])

        let request = URLRequest(url: url)
        webView.load(request)

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if isRecording {
            webView.evaluateJavaScript("window.__flowRecorder && window.__flowRecorder.start();", completionHandler: nil)
        } else {
            webView.evaluateJavaScript("window.__flowRecorder && window.__flowRecorder.stop();", completionHandler: nil)
        }
    }

    static var recorderInjectionJS: String {
        """
        (function() {
            'use strict';
            if (window.__flowRecorder) return;

            var recording = false;
            var actions = [];
            var lastTimestamp = 0;
            var textboxCounter = 0;
            var textboxMap = {};
            var flushInterval = null;
            var mouseDownTime = 0;
            var errorCount = 0;

            function getSelector(el) {
                if (!el || el === document || el === document.documentElement) return 'html';
                if (el.id) return '#' + el.id;
                if (el === document.body) return 'body';
                var path = [];
                var current = el;
                while (current && current !== document.body && path.length < 5) {
                    var tag = current.tagName ? current.tagName.toLowerCase() : '';
                    if (!tag) break;
                    if (current.id) { path.unshift('#' + current.id); break; }
                    var classes = current.className && typeof current.className === 'string'
                        ? '.' + current.className.trim().split(/\\s+/).slice(0,2).join('.')
                        : '';
                    var nth = '';
                    if (current.parentElement) {
                        var siblings = current.parentElement.children;
                        var sameTag = 0; var idx = 0;
                        for (var i = 0; i < siblings.length; i++) {
                            if (siblings[i].tagName === current.tagName) {
                                sameTag++;
                                if (siblings[i] === current) idx = sameTag;
                            }
                        }
                        if (sameTag > 1) nth = ':nth-of-type(' + idx + ')';
                    }
                    path.unshift(tag + classes + nth);
                    current = current.parentElement;
                }
                return path.join(' > ');
            }

            function getTextboxLabel(el) {
                var sel = getSelector(el);
                if (textboxMap[sel]) return textboxMap[sel];
                textboxCounter++;
                var label = 'textbox' + textboxCounter + 'entry';
                textboxMap[sel] = label;
                return label;
            }

            function isTextInput(el) {
                if (!el || !el.tagName) return false;
                var tag = el.tagName.toLowerCase();
                if (tag === 'textarea') return true;
                if (tag === 'input') {
                    var t = (el.type || 'text').toLowerCase();
                    return ['text','email','password','search','tel','url','number'].indexOf(t) !== -1;
                }
                return el.contentEditable === 'true';
            }

            function now() { return performance.now(); }

            function record(type, evt, extra) {
                if (!recording) return;
                try {
                    var ts = now();
                    var delta = lastTimestamp > 0 ? ts - lastTimestamp : 0;
                    lastTimestamp = ts;

                    var action = {
                        id: Date.now().toString(36) + Math.random().toString(36).substr(2,5),
                        type: type,
                        timestampMs: ts,
                        deltaFromPreviousMs: delta
                    };

                    if (evt && typeof evt.clientX === 'number') {
                        action.mousePosition = {
                            x: evt.clientX,
                            y: evt.clientY,
                            viewportX: evt.pageX || evt.clientX,
                            viewportY: evt.pageY || evt.clientY
                        };
                    }

                    if (evt && evt.deltaX !== undefined) {
                        action.scrollDeltaX = evt.deltaX;
                        action.scrollDeltaY = evt.deltaY;
                    }

                    if (evt && evt.key !== undefined) {
                        action.keyCode = evt.keyCode;
                        action.key = evt.key;
                        action.code = evt.code;
                        action.charCode = evt.charCode;
                        action.shiftKey = evt.shiftKey;
                        action.ctrlKey = evt.ctrlKey;
                        action.altKey = evt.altKey;
                        action.metaKey = evt.metaKey;
                    }

                    if (evt && evt.target) {
                        action.targetSelector = getSelector(evt.target);
                        action.targetTagName = evt.target.tagName ? evt.target.tagName.toLowerCase() : '';
                        action.targetType = evt.target.type || '';
                        if (isTextInput(evt.target)) {
                            action.textboxLabel = getTextboxLabel(evt.target);
                        }
                    }

                    if (evt && evt.button !== undefined) {
                        action.button = evt.button;
                        action.buttons = evt.buttons;
                    }

                    action.isTrusted = evt ? evt.isTrusted : true;

                    if (extra) {
                        for (var k in extra) { action[k] = extra[k]; }
                    }

                    actions.push(action);
                } catch(e) {
                    errorCount++;
                    if (errorCount <= 5) {
                        try {
                            window.webkit.messageHandlers.flowRecorder.postMessage(JSON.stringify({
                                type: 'error',
                                message: 'Record error: ' + e.message,
                                errorCount: errorCount
                            }));
                        } catch(e2) {}
                    }
                }
            }

            function onMouseMove(e) { record('mouseMove', e); }
            function onMouseDown(e) { mouseDownTime = now(); record('mouseDown', e); }
            function onMouseUp(e) {
                var hold = mouseDownTime > 0 ? now() - mouseDownTime : 0;
                record('mouseUp', e, { holdDurationMs: hold });
                mouseDownTime = 0;
            }
            function onClick(e) { record('click', e); }
            function onDblClick(e) { record('doubleClick', e); }
            function onScroll(e) { record('scroll', e); }
            function onKeyDown(e) {
                if (isTextInput(e.target)) {
                    record('keyDown', e, { textboxLabel: getTextboxLabel(e.target) });
                } else {
                    record('keyDown', e);
                }
            }
            function onKeyUp(e) { record('keyUp', e); }
            function onKeyPress(e) { record('keyPress', e); }
            function onFocus(e) { record('focus', e); }
            function onBlur(e) { record('blur', e); }
            function onInput(e) {
                var extra = {};
                if (isTextInput(e.target)) {
                    extra.textboxLabel = getTextboxLabel(e.target);
                    extra.textContent = e.target.value || '';
                }
                record('input', e, extra);
            }
            function onTouchStart(e) {
                if (e.touches && e.touches.length > 0) {
                    var t = e.touches[0];
                    record('touchStart', { clientX: t.clientX, clientY: t.clientY, pageX: t.pageX, pageY: t.pageY, target: e.target, isTrusted: e.isTrusted });
                }
            }
            function onTouchEnd(e) {
                if (e.changedTouches && e.changedTouches.length > 0) {
                    var t = e.changedTouches[0];
                    record('touchEnd', { clientX: t.clientX, clientY: t.clientY, pageX: t.pageX, pageY: t.pageY, target: e.target, isTrusted: e.isTrusted });
                }
            }
            function onTouchMove(e) {
                if (e.touches && e.touches.length > 0) {
                    var t = e.touches[0];
                    record('touchMove', { clientX: t.clientX, clientY: t.clientY, pageX: t.pageX, pageY: t.pageY, target: e.target, isTrusted: e.isTrusted });
                }
            }

            function flush() {
                if (actions.length === 0) return;
                var batch = actions.splice(0, actions.length);
                try {
                    window.webkit.messageHandlers.flowRecorder.postMessage(JSON.stringify({
                        type: 'actions',
                        actions: batch
                    }));
                } catch(e) {
                    errorCount++;
                    actions = batch.concat(actions);
                    if (errorCount <= 3) {
                        try {
                            window.webkit.messageHandlers.flowRecorder.postMessage(JSON.stringify({
                                type: 'error',
                                message: 'Flush failed: ' + e.message + ' (batch size: ' + batch.length + ')',
                                errorCount: errorCount
                            }));
                        } catch(e2) {}
                    }
                }
            }

            function attachListeners() {
                var opts = { capture: true, passive: true };
                document.addEventListener('mousemove', onMouseMove, opts);
                document.addEventListener('mousedown', onMouseDown, opts);
                document.addEventListener('mouseup', onMouseUp, opts);
                document.addEventListener('click', onClick, opts);
                document.addEventListener('dblclick', onDblClick, opts);
                document.addEventListener('wheel', onScroll, { capture: true, passive: true });
                document.addEventListener('keydown', onKeyDown, opts);
                document.addEventListener('keyup', onKeyUp, opts);
                document.addEventListener('keypress', onKeyPress, opts);
                document.addEventListener('focus', onFocus, { capture: true, passive: true });
                document.addEventListener('blur', onBlur, { capture: true, passive: true });
                document.addEventListener('input', onInput, opts);
                document.addEventListener('touchstart', onTouchStart, opts);
                document.addEventListener('touchend', onTouchEnd, opts);
                document.addEventListener('touchmove', onTouchMove, opts);
            }

            function detachListeners() {
                var opts = { capture: true };
                document.removeEventListener('mousemove', onMouseMove, opts);
                document.removeEventListener('mousedown', onMouseDown, opts);
                document.removeEventListener('mouseup', onMouseUp, opts);
                document.removeEventListener('click', onClick, opts);
                document.removeEventListener('dblclick', onDblClick, opts);
                document.removeEventListener('wheel', onScroll, opts);
                document.removeEventListener('keydown', onKeyDown, opts);
                document.removeEventListener('keyup', onKeyUp, opts);
                document.removeEventListener('keypress', onKeyPress, opts);
                document.removeEventListener('focus', onFocus, opts);
                document.removeEventListener('blur', onBlur, opts);
                document.removeEventListener('input', onInput, opts);
                document.removeEventListener('touchstart', onTouchStart, opts);
                document.removeEventListener('touchend', onTouchEnd, opts);
                document.removeEventListener('touchmove', onTouchMove, opts);
            }

            window.__flowRecorder = {
                start: function() {
                    if (recording) return;
                    recording = true;
                    actions = [];
                    lastTimestamp = 0;
                    textboxCounter = 0;
                    textboxMap = {};
                    mouseDownTime = 0;
                    errorCount = 0;
                    attachListeners();
                    flushInterval = setInterval(flush, 500);
                    try {
                        window.webkit.messageHandlers.flowRecorder.postMessage(JSON.stringify({
                            type: 'status', status: 'recording_started'
                        }));
                    } catch(e) {}
                },
                stop: function() {
                    if (!recording) return;
                    recording = false;
                    detachListeners();
                    flush();
                    if (flushInterval) { clearInterval(flushInterval); flushInterval = null; }
                    try {
                        window.webkit.messageHandlers.flowRecorder.postMessage(JSON.stringify({
                            type: 'status', status: 'recording_stopped',
                            textboxMap: textboxMap,
                            errorCount: errorCount
                        }));
                    } catch(e) {}
                },
                isRecording: function() { return recording; },
                getTextboxMap: function() { return textboxMap; },
                getActionCount: function() { return actions.length; },
                getErrorCount: function() { return errorCount; }
            };
        })();
        """
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: FlowRecorderWebView
        weak var webView: WKWebView?
        private let logger = DebugLogger.shared
        private var navigationStartTime: Date?
        private var retryCount: Int = 0
        private let maxRetries: Int = 3

        init(parent: FlowRecorderWebView) {
            self.parent = parent
        }

        nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "flowRecorder", let body = message.body as? String else { return }
            Task { @MainActor in
                self.handleMessage(body)
            }
        }

        func handleMessage(_ body: String) {
            guard let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                logger.log("FlowRecorderWebView: received unparseable message (\(body.prefix(100)))", category: .flowRecorder, level: .warning)
                return
            }

            if type == "error" {
                let errorMessage = json["message"] as? String ?? "unknown"
                let errorCount = json["errorCount"] as? Int ?? 0
                logger.log("FlowRecorderWebView: JS error #\(errorCount) — \(errorMessage)", category: .flowRecorder, level: .error)
                return
            }

            if type == "status" {
                let status = json["status"] as? String ?? "unknown"
                let jsErrors = json["errorCount"] as? Int ?? 0
                logger.log("FlowRecorderWebView: status=\(status) jsErrors=\(jsErrors)", category: .flowRecorder, level: .debug)
                return
            }

            if type == "actions", let actionsArray = json["actions"] as? [[String: Any]] {
                var parseErrors = 0
                let decoded = actionsArray.compactMap { dict -> RecordedAction? in
                    guard let actionType = dict["type"] as? String,
                          let raType = RecordedActionType(rawValue: actionType),
                          let ts = dict["timestampMs"] as? Double else {
                        parseErrors += 1
                        return nil
                    }

                    var mousePos: RecordedMousePosition?
                    if let mp = dict["mousePosition"] as? [String: Any],
                       let x = mp["x"] as? Double, let y = mp["y"] as? Double {
                        mousePos = RecordedMousePosition(
                            x: x, y: y,
                            viewportX: mp["viewportX"] as? Double ?? x,
                            viewportY: mp["viewportY"] as? Double ?? y
                        )
                    }

                    return RecordedAction(
                        id: dict["id"] as? String ?? UUID().uuidString,
                        type: raType,
                        timestampMs: ts,
                        deltaFromPreviousMs: dict["deltaFromPreviousMs"] as? Double ?? 0,
                        mousePosition: mousePos,
                        scrollDeltaX: dict["scrollDeltaX"] as? Double,
                        scrollDeltaY: dict["scrollDeltaY"] as? Double,
                        keyCode: dict["keyCode"] as? Int,
                        key: dict["key"] as? String,
                        code: dict["code"] as? String,
                        charCode: dict["charCode"] as? Int,
                        targetSelector: dict["targetSelector"] as? String,
                        targetTagName: dict["targetTagName"] as? String,
                        targetType: dict["targetType"] as? String,
                        textboxLabel: dict["textboxLabel"] as? String,
                        textContent: dict["textContent"] as? String,
                        button: dict["button"] as? Int,
                        buttons: dict["buttons"] as? Int,
                        holdDurationMs: dict["holdDurationMs"] as? Double,
                        isTrusted: dict["isTrusted"] as? Bool,
                        shiftKey: dict["shiftKey"] as? Bool,
                        ctrlKey: dict["ctrlKey"] as? Bool,
                        altKey: dict["altKey"] as? Bool,
                        metaKey: dict["metaKey"] as? Bool
                    )
                }

                if parseErrors > 0 {
                    logger.log("FlowRecorderWebView: \(parseErrors)/\(actionsArray.count) actions failed to parse", category: .flowRecorder, level: .warning)
                }

                parent.onActionsReceived(decoded)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                let pageTitle = webView.title ?? webView.url?.absoluteString ?? "Unknown"
                let elapsed = self.navigationStartTime.map { Int(Date().timeIntervalSince($0) * 1000) }
                self.logger.log("FlowRecorderWebView: page loaded — \(pageTitle)", category: .webView, level: .success, durationMs: elapsed, metadata: [
                    "url": webView.url?.absoluteString ?? "N/A"
                ])
                self.retryCount = 0
                self.parent.onPageLoaded(pageTitle)

                if self.parent.isRecording {
                    webView.evaluateJavaScript(FlowRecorderWebView.recorderInjectionJS, completionHandler: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        webView.evaluateJavaScript("window.__flowRecorder && window.__flowRecorder.start();", completionHandler: nil)
                    }
                }
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                let nsError = error as NSError
                if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
                self.logger.logError("FlowRecorderWebView: navigation failed", error: error, category: .webView, metadata: [
                    "url": webView.url?.absoluteString ?? "N/A"
                ])
                self.attemptRetry(webView: webView, error: error)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                let nsError = error as NSError
                if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
                self.logger.logError("FlowRecorderWebView: provisional navigation failed", error: error, category: .webView, metadata: [
                    "url": webView.url?.absoluteString ?? "N/A"
                ])
                self.attemptRetry(webView: webView, error: error)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                self.navigationStartTime = Date()
                self.logger.log("FlowRecorderWebView: navigation started — \(webView.url?.absoluteString ?? "N/A")", category: .webView, level: .debug)
            }
        }

        func attemptRetry(webView: WKWebView, error: Error) {
            let classified = logger.classifyNetworkError(error)
            guard classified.isRetryable && retryCount < maxRetries else {
                if retryCount >= maxRetries {
                    logger.logHealing(category: .webView, originalError: error.localizedDescription, healingAction: "Max retries (\(maxRetries)) exhausted", succeeded: false, attemptNumber: retryCount)
                }
                return
            }

            retryCount += 1
            let backoff = min(1000 * retryCount, 5000)
            logger.logHealing(category: .webView, originalError: classified.userMessage, healingAction: "Retrying navigation (attempt #\(retryCount), backoff \(backoff)ms)", succeeded: true, attemptNumber: retryCount)

            DispatchQueue.main.asyncAfter(deadline: .now() + Double(backoff) / 1000.0) { [weak self] in
                guard let self, let url = self.parent.url as URL? else { return }
                self.logger.log("FlowRecorderWebView: retry #\(self.retryCount) loading \(url.absoluteString)", category: .webView, level: .info)
                webView.load(URLRequest(url: url))
            }
        }

        nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
        }

        nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let httpResponse = navigationResponse.response as? HTTPURLResponse {
                Task { @MainActor in
                    let statusCode = httpResponse.statusCode
                    if statusCode >= 400 {
                        self.logger.log("FlowRecorderWebView: HTTP \(statusCode) for \(httpResponse.url?.absoluteString ?? "N/A")", category: .webView, level: statusCode >= 500 ? .error : .warning, metadata: [
                            "statusCode": "\(statusCode)",
                            "url": httpResponse.url?.absoluteString ?? "N/A"
                        ])
                    }
                }
            }
            decisionHandler(.allow)
        }
    }
}
