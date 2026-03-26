import Foundation
import WebKit
import UIKit

@MainActor
class LoginWebSession: NSObject {
    private(set) var webView: WKWebView?
    private let sessionId: UUID = UUID()
    private var pageLoadContinuation: CheckedContinuation<Bool, Never>?
    private var isPageLoaded: Bool = false
    private var loadTimeoutTask: Task<Void, Never>?
    var stealthEnabled: Bool = false
    var speedMultiplier: Double = 1.0
    var blockImages: Bool = false
    var lastNavigationError: String?
    var lastHTTPStatusCode: Int?
    var networkConfig: ActiveNetworkConfig = .direct
    private var isProtectedRouteBlocked: Bool = false
    private var stealthProfile: PPSRStealthService.SessionProfile?
    private(set) var lastFingerprintScore: FingerprintValidationService.FingerprintScore?
    var onFingerprintLog: ((String, PPSRLogEntry.Level) -> Void)?
    private let logger = DebugLogger.shared

    private func resolvePageLoad(_ result: Bool, errorMessage: String? = nil) {
        guard let cont = pageLoadContinuation else { return }
        pageLoadContinuation = nil
        if let errorMessage {
            lastNavigationError = lastNavigationError ?? errorMessage
        }
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        cont.resume(returning: result)
    }

    static let targetURL = URL(string: "https://transact.ppsr.gov.au/CarCheck/")!
    private static let blockResourcesRuleListID = "SitchomaticBlockHeavyResources"
    private static let blockResourcesRuleListJSON = """
    [
      {
        "trigger": {
          "url-filter": ".*",
          "resource-type": ["image", "media", "font", "style-sheet"]
        },
        "action": {
          "type": "block"
        }
      }
    ]
    """

    private var blockImagesScript: WKUserScript? {
        guard blockImages else { return nil }
        return WKUserScript(source: """
        (function() {
            var style = document.createElement('style');
            style.textContent = 'img, video, audio, source, svg, picture, iframe, object, embed, canvas, [style*="background-image"], link[rel="stylesheet"], style { display: none !important; visibility: hidden !important; } * { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif !important; }';
            (document.head || document.documentElement).appendChild(style);
            var observer = new MutationObserver(function(mutations) {
                mutations.forEach(function(m) {
                    m.addedNodes.forEach(function(node) {
                        if (!node || !node.tagName) return;
                        var tag = node.tagName.toUpperCase();
                        if (tag === 'IMG' || tag === 'VIDEO' || tag === 'AUDIO' || tag === 'SOURCE' || tag === 'SVG' || tag === 'PICTURE' || tag === 'IFRAME' || tag === 'OBJECT' || tag === 'EMBED' || tag === 'CANVAS') {
                            node.style.display = 'none';
                            if (tag === 'IMG' || tag === 'VIDEO' || tag === 'AUDIO' || tag === 'SOURCE') {
                                try { node.src = ''; } catch (e) {}
                            }
                        }
                        if (tag === 'LINK' && ((node.rel || '').toLowerCase() === 'stylesheet' || ((node.as || '').toLowerCase() === 'font'))) {
                            try { node.href = 'about:blank'; } catch (e) {}
                            try { node.remove(); } catch (e) {}
                        }
                        if (tag === 'STYLE') {
                            try { node.textContent = ''; } catch (e) {}
                        }
                    });
                });
            });
            observer.observe(document.documentElement, { childList: true, subtree: true });
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    private func installActiveUserScripts(stealthScript: WKUserScript?) {
        guard let contentController = webView?.configuration.userContentController else { return }
        contentController.removeAllUserScripts()
        if let blockScript = blockImagesScript {
            contentController.addUserScript(blockScript)
        }
        if let stealthScript {
            contentController.addUserScript(stealthScript)
        }
    }

    private func installBlockContentRules(on contentController: WKUserContentController) {
        guard blockImages else { return }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: Self.blockResourcesRuleListID,
            encodedContentRuleList: Self.blockResourcesRuleListJSON
        ) { [weak self] ruleList, error in
            guard let self else { return }
            if let ruleList {
                contentController.add(ruleList)
            } else if let error {
                self.logger.log("LoginWebSession: failed to compile block content rules (\(error.localizedDescription))", category: .webView, level: .warning)
            }
        }
    }

    func setUp() {
        logger.log("LoginWebSession: setUp (stealth=\(stealthEnabled), network=\(networkConfig.label))", category: .webView, level: .debug)
        if webView != nil {
            tearDown()
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        if let blockScript = blockImagesScript {
            config.userContentController.addUserScript(blockScript)
        }
        installBlockContentRules(on: config.userContentController)

        let proxyApplied = NetworkSessionFactory.shared.configureWKWebView(config: config, networkConfig: networkConfig, target: .ppsr)
        isProtectedRouteBlocked = networkConfig.requiresProtectedRoute && !proxyApplied
        if isProtectedRouteBlocked {
            lastNavigationError = "Protected PPSR route blocked — no proxy path available"
            logger.log("LoginWebSession: BLOCKED — no proxy available for PPSR, refusing to load on real IP", category: .network, level: .error)
        }

        if stealthEnabled {
            let stealth = PPSRStealthService.shared
            let profile = stealth.nextProfile()
            self.stealthProfile = profile

            let userScript = stealth.createStealthUserScript(profile: profile)
            config.userContentController.addUserScript(userScript)

            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: profile.viewport.width, height: profile.viewport.height), configuration: config)
            webView.navigationDelegate = self
            webView.customUserAgent = profile.userAgent
            self.webView = webView
        } else {
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
            webView.navigationDelegate = self
            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
            self.webView = webView
        }
    }

    func tearDown() {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        if let wv = webView {
            wv.stopLoading()
            wv.configuration.websiteDataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) { }
            wv.configuration.userContentController.removeAllUserScripts()
            wv.navigationDelegate = nil
        }
        webView = nil
        isPageLoaded = false
        isProtectedRouteBlocked = false
        lastNavigationError = nil
        lastHTTPStatusCode = nil
        if let cont = pageLoadContinuation {
            pageLoadContinuation = nil
            cont.resume(returning: false)
        }
    }

    func applyNewStealthProfile(userAgent: String, userScript: WKUserScript) {
        webView?.customUserAgent = userAgent
        installActiveUserScripts(stealthScript: userScript)
    }

    func injectFingerprint() async {
        guard stealthEnabled, stealthProfile != nil else { return }
        let js = PPSRStealthService.shared.fingerprintJS()
        _ = await executeJS(js)
    }

    func validateFingerprint(maxRetries: Int = 2) async -> Bool {
        guard stealthEnabled, let wv = webView, let profile = stealthProfile else { return true }

        for attempt in 0..<maxRetries {
            let score = await FingerprintValidationService.shared.validate(in: wv, profileSeed: profile.seed)
            lastFingerprintScore = score

            if score.passed {
                onFingerprintLog?("FP score PASS: \(score.totalScore)/\(score.maxSafeScore) (seed: \(profile.seed))", .success)
                return true
            }

            let signalSummary = score.signals.prefix(3).joined(separator: ", ")
            onFingerprintLog?("FP score FAIL attempt \(attempt + 1): \(score.totalScore)/\(score.maxSafeScore) [\(signalSummary)]", .warning)

            if attempt < maxRetries - 1 {
                onFingerprintLog?("Rotating stealth profile to reduce FP score...", .info)
                let stealth = PPSRStealthService.shared
                let newProfile = stealth.nextProfile()
                self.stealthProfile = newProfile
                webView?.customUserAgent = newProfile.userAgent
                let newJS = stealth.createStealthUserScript(profile: newProfile)
                installActiveUserScripts(stealthScript: newJS)
                _ = await executeJS(PPSRStealthService.shared.buildComprehensiveStealthJSPublic(profile: newProfile))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        onFingerprintLog?("FP validation failed after \(maxRetries) profile rotations — proceeding with caution", .error)
        return false
    }

    func loadPage(timeout: TimeInterval = 90) async -> Bool {
        let timeout = TimeoutResolver.resolvePageLoadTimeout(timeout)
        guard let webView else {
            lastNavigationError = "WebView not initialized"
            logger.log("LoginWebSession: loadPage failed — webView nil", category: .webView, level: .error)
            return false
        }
        guard !isProtectedRouteBlocked else {
            logger.log("LoginWebSession: loadPage blocked — protected route has no safe proxy path", category: .network, level: .error)
            return false
        }
        logger.startTimer(key: "loginWebSession_load")
        isPageLoaded = false
        lastNavigationError = nil
        lastHTTPStatusCode = nil

        if let existingCont = pageLoadContinuation {
            pageLoadContinuation = nil
            existingCont.resume(returning: false)
        }

        let request = URLRequest(url: Self.targetURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        webView.load(request)

        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.pageLoadContinuation = continuation

            self.loadTimeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeout))
                await MainActor.run {
                    self.resolvePageLoad(false, errorMessage: "Page load timed out after \(Int(timeout))s")
                }
            }
        }

        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil

        let loadMs = logger.stopTimer(key: "loginWebSession_load")
        if loaded {
            logger.log("LoginWebSession: page loaded in \(loadMs ?? 0)ms", category: .webView, level: .success, durationMs: loadMs)
            await injectFingerprint()
            try? await Task.sleep(for: .milliseconds(1500))
            await waitForDOMReady(timeout: TimeoutResolver.resolveAutomationTimeout(10))
            let _ = await validateFingerprint()
        } else {
            logger.log("LoginWebSession: page load FAILED — \(lastNavigationError ?? "unknown")", category: .webView, level: .error, durationMs: loadMs, metadata: [
                "error": lastNavigationError ?? "timeout",
                "httpStatus": lastHTTPStatusCode.map { "\($0)" } ?? "N/A"
            ])
        }

        return loaded
    }

    private func waitForDOMReady(timeout: TimeInterval) async {
        let timeout = TimeoutResolver.resolveAutomationTimeout(timeout)
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let ready = await executeJS("document.readyState") ?? ""
            if ready == "complete" || ready == "interactive" {
                try? await Task.sleep(for: .milliseconds(500))
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    func waitForAppReady(timeout: TimeInterval = 90) async -> (ready: Bool, fieldsFound: Int, detail: String) {
        let timeout = TimeoutResolver.resolveAutomationTimeout(timeout)
        let start = Date()
        var lastFieldCount = 0
        var lastDetail = "Waiting for app to initialize..."
        var stableCount = 0
        let requiredStableCycles = 2

        logger.log("waitForAppReady: starting (timeout=\(Int(timeout))s)", category: .automation, level: .debug)

        while Date().timeIntervalSince(start) < timeout {
            let checkJS = """
            (function() {
                var result = { ready: false, fieldsFound: 0, loading: false, detail: '', inputCount: 0, bodyLength: 0 };
                result.bodyLength = document.body ? document.body.innerText.length : 0;

                var loadingIndicators = [
                    'app is loading', 'please wait', 'loading...', 'loading…',
                    'initializing', 'just a moment', 'one moment', 'spinner'
                ];
                var bodyText = (document.body ? document.body.innerText : '').toLowerCase();
                for (var i = 0; i < loadingIndicators.length; i++) {
                    if (bodyText.indexOf(loadingIndicators[i]) !== -1) {
                        result.loading = true;
                        result.detail = 'Loading indicator detected: ' + loadingIndicators[i];
                        break;
                    }
                }

                var spinners = document.querySelectorAll(
                    '.spinner, .loading, .loader, [class*="spinner"], [class*="loading"], [class*="loader"], ' +
                    '.progress, [role="progressbar"], .app-loading, .splash, [class*="splash"], ' +
                    '.preloader, [class*="preload"], .initial-load, [class*="initializ"]'
                );
                for (var s = 0; s < spinners.length; s++) {
                    var el = spinners[s];
                    var style = window.getComputedStyle(el);
                    if (style.display !== 'none' && style.visibility !== 'hidden' && style.opacity !== '0') {
                        result.loading = true;
                        result.detail = 'Visible spinner/loader element found: ' + (el.className || el.tagName);
                        break;
                    }
                }

                var allInputs = document.querySelectorAll('input, select, textarea');
                result.inputCount = allInputs.length;

                \(findFieldJS)
                var fieldDefs = {
                    'vin': [{"type":"id","value":"vin"},{"type":"name","value":"vin"},{"type":"placeholder","value":"Enter VIN"},{"type":"label","value":"VIN"},{"type":"css","value":"input[type='text']:first-of-type"}],
                    'email': [{"type":"id","value":"email"},{"type":"name","value":"email"},{"type":"placeholder","value":"email"},{"type":"css","value":"input[type='email']"}],
                    'cardNumber': [{"type":"id","value":"cardNumber"},{"type":"name","value":"cardNumber"},{"type":"placeholder","value":"card number"},{"type":"css","value":"input[autocomplete='cc-number']"}],
                    'expMonth': [{"type":"id","value":"expMonth"},{"type":"name","value":"expMonth"},{"type":"placeholder","value":"MM"},{"type":"css","value":"input[autocomplete='cc-exp-month']"}],
                    'expYear': [{"type":"id","value":"expYear"},{"type":"name","value":"expYear"},{"type":"placeholder","value":"YY"},{"type":"css","value":"input[autocomplete='cc-exp-year']"}],
                    'cvv': [{"type":"id","value":"cvv"},{"type":"name","value":"cvv"},{"type":"placeholder","value":"CVV"},{"type":"css","value":"input[autocomplete='cc-csc']"}]
                };
                var found = 0;
                var foundFields = [];
                for (var name in fieldDefs) {
                    var el = findField(fieldDefs[name]);
                    if (el) { found++; foundFields.push(name); }
                }
                result.fieldsFound = found;

                if (!result.loading && found >= 3) {
                    result.ready = true;
                    result.detail = 'Form ready with ' + found + '/6 fields: ' + foundFields.join(', ');
                } else if (!result.ready) {
                    if (result.loading) {
                        // detail already set
                    } else if (found > 0) {
                        result.detail = 'Partial form: ' + found + '/6 fields found (' + foundFields.join(', ') + ') — waiting for more';
                    } else if (result.inputCount > 0) {
                        result.detail = 'Page has ' + result.inputCount + ' inputs but no PPSR fields matched yet';
                    } else {
                        result.detail = 'No form elements found yet (body length: ' + result.bodyLength + ')';
                    }
                }

                return JSON.stringify(result);
            })();
            """

            guard let resultStr = await executeJS(checkJS),
                  let data = resultStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            let isReady = json["ready"] as? Bool ?? false
            let fieldsFound = json["fieldsFound"] as? Int ?? 0
            let isLoading = json["loading"] as? Bool ?? false
            let detail = json["detail"] as? String ?? "Unknown state"

            lastFieldCount = fieldsFound
            lastDetail = detail

            if isReady {
                stableCount += 1
                if stableCount >= requiredStableCycles {
                    logger.log("waitForAppReady: READY — \(detail) (\(String(format: "%.1f", Date().timeIntervalSince(start)))s)", category: .automation, level: .success)
                    return (true, fieldsFound, detail)
                }
                try? await Task.sleep(for: .milliseconds(500))
                continue
            } else {
                stableCount = 0
            }

            if isLoading {
                logger.log("waitForAppReady: app still loading — \(detail)", category: .automation, level: .trace)
            }

            let elapsed = Date().timeIntervalSince(start)
            let pollInterval: TimeInterval = elapsed < 5 ? 0.8 : (elapsed < 15 ? 1.5 : 2.0)
            try? await Task.sleep(for: .seconds(pollInterval))
        }

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
        logger.log("waitForAppReady: TIMEOUT after \(elapsed)s — fields=\(lastFieldCount) detail=\(lastDetail)", category: .automation, level: .warning)
        return (lastFieldCount >= 3, lastFieldCount, "Timeout after \(elapsed)s: \(lastDetail)")
    }

    private let findFieldJS = """
    function findField(strategies) {
        for (var i = 0; i < strategies.length; i++) {
            var s = strategies[i];
            var el = null;
            try {
                if (s.type === 'id') {
                    el = document.getElementById(s.value);
                } else if (s.type === 'name') {
                    var els = document.getElementsByName(s.value);
                    if (els.length > 0) el = els[0];
                } else if (s.type === 'placeholder') {
                    el = document.querySelector('input[placeholder*="' + s.value + '"]');
                    if (!el) el = document.querySelector('textarea[placeholder*="' + s.value + '"]');
                } else if (s.type === 'label') {
                    var labels = document.querySelectorAll('label');
                    for (var j = 0; j < labels.length; j++) {
                        var txt = (labels[j].textContent || '').trim().toLowerCase();
                        if (txt.indexOf(s.value.toLowerCase()) !== -1) {
                            var forId = labels[j].getAttribute('for');
                            if (forId) {
                                el = document.getElementById(forId);
                            } else {
                                el = labels[j].querySelector('input, textarea, select');
                            }
                            if (el) break;
                        }
                    }
                } else if (s.type === 'css') {
                    el = document.querySelector(s.value);
                } else if (s.type === 'ariaLabel') {
                    el = document.querySelector('[aria-label*="' + s.value + '"]');
                } else if (s.type === 'xpath') {
                    var xr = document.evaluate(s.value, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
                    el = xr.singleNodeValue;
                }
            } catch(e) {}
            if (el && !el.disabled && el.offsetParent !== null) return el;
            if (el && !el.disabled) return el;
        }
        return null;
    }
    """

    private func fillFieldJS(strategies: String, value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
        (function() {
            \(findFieldJS)
            var el = findField(\(strategies));
            if (!el) return 'NOT_FOUND';
            el.focus();
            el.value = '';
            var nativeInputValueSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (nativeInputValueSetter && nativeInputValueSetter.set) {
                nativeInputValueSetter.set.call(el, '\(escaped)');
            } else {
                el.value = '\(escaped)';
            }
            el.dispatchEvent(new Event('focus', {bubbles: true}));
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            el.dispatchEvent(new Event('blur', {bubbles: true}));
            if (el.value === '\(escaped)') return 'OK';
            el.value = '\(escaped)';
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            return el.value === '\(escaped)' ? 'OK' : 'VALUE_MISMATCH';
        })();
        """
    }

    func fillVIN(_ vin: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"vin"},{"type":"id","value":"vehicleId"},{"type":"id","value":"VIN"},
            {"type":"name","value":"vin"},{"type":"name","value":"vehicleId"},{"type":"name","value":"VIN"},
            {"type":"placeholder","value":"Enter VIN"},{"type":"placeholder","value":"VIN"},
            {"type":"label","value":"Enter VIN"},{"type":"label","value":"VIN"},{"type":"label","value":"Vehicle"},
            {"type":"ariaLabel","value":"VIN"},{"type":"ariaLabel","value":"Vehicle"},
            {"type":"css","value":"input[type='text']:first-of-type"},{"type":"css","value":"input[data-field='vin']"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: vin))
        return classifyFillResult(result, fieldName: "VIN")
    }

    func fillEmail(_ email: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"email"},{"type":"id","value":"emailAddress"},{"type":"id","value":"Email"},
            {"type":"name","value":"email"},{"type":"name","value":"emailAddress"},
            {"type":"placeholder","value":"Enter your email"},{"type":"placeholder","value":"Email"},
            {"type":"label","value":"email"},{"type":"ariaLabel","value":"email"},
            {"type":"css","value":"input[type='email']"},{"type":"css","value":"input[autocomplete='email']"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: email))
        return classifyFillResult(result, fieldName: "Email")
    }

    func fillCardNumber(_ number: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"cardNumber"},{"type":"id","value":"card-number"},{"type":"id","value":"ccNumber"},
            {"type":"name","value":"cardNumber"},{"type":"name","value":"card-number"},
            {"type":"placeholder","value":"Enter card number"},{"type":"placeholder","value":"Card Number"},
            {"type":"label","value":"card number"},{"type":"ariaLabel","value":"card number"},
            {"type":"css","value":"input[autocomplete='cc-number']"},{"type":"css","value":"input[inputmode='numeric']"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: number))
        return classifyFillResult(result, fieldName: "Card Number")
    }

    func fillExpMonth(_ month: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"expMonth"},{"type":"id","value":"exp-month"},{"type":"id","value":"expiryMonth"},
            {"type":"name","value":"expMonth"},{"type":"name","value":"exp-month"},
            {"type":"placeholder","value":"MM"},{"type":"label","value":"MM"},{"type":"label","value":"month"},
            {"type":"ariaLabel","value":"MM"},{"type":"css","value":"input[autocomplete='cc-exp-month']"},
            {"type":"css","value":"select[autocomplete='cc-exp-month']"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: month))
        if result == "OK" { return (true, "Exp Month filled via input") }
        if result == "VALUE_MISMATCH" { return (true, "Exp Month filled (value mismatch)") }

        let selectResult = await executeJS(fillSelectJS(strategies: strategies, value: month))
        if selectResult == "OK" { return (true, "Exp Month filled via select dropdown") }
        return (false, "Exp Month selector failed: input '\(result ?? "nil")', select '\(selectResult ?? "nil")'")
    }

    func fillExpYear(_ year: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"expYear"},{"type":"id","value":"exp-year"},{"type":"id","value":"expiryYear"},
            {"type":"name","value":"expYear"},{"type":"name","value":"exp-year"},
            {"type":"placeholder","value":"YY"},{"type":"label","value":"YY"},{"type":"label","value":"year"},
            {"type":"ariaLabel","value":"YY"},{"type":"css","value":"input[autocomplete='cc-exp-year']"},
            {"type":"css","value":"select[autocomplete='cc-exp-year']"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: year))
        if result == "OK" { return (true, "Exp Year filled via input") }
        if result == "VALUE_MISMATCH" { return (true, "Exp Year filled (value mismatch)") }

        let selectResult = await executeJS(fillSelectJS(strategies: strategies, value: year))
        if selectResult == "OK" { return (true, "Exp Year filled via select dropdown") }
        return (false, "Exp Year selector failed: input '\(result ?? "nil")', select '\(selectResult ?? "nil")'")
    }

    func fillCVV(_ cvv: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"cvv"},{"type":"id","value":"cvc"},{"type":"id","value":"securityCode"},
            {"type":"name","value":"cvv"},{"type":"name","value":"cvc"},
            {"type":"placeholder","value":"Enter card CVV"},{"type":"placeholder","value":"CVV"},
            {"type":"label","value":"CVV"},{"type":"label","value":"CVC"},
            {"type":"ariaLabel","value":"CVV"},{"type":"css","value":"input[autocomplete='cc-csc']"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: cvv))
        return classifyFillResult(result, fieldName: "CVV")
    }

    private func fillSelectJS(strategies: String, value: String) -> String {
        return """
        (function() {
            \(findFieldJS)
            var el = findField(\(strategies));
            if (!el || el.tagName !== 'SELECT') return 'NOT_SELECT';
            var opts = el.options;
            for (var i = 0; i < opts.length; i++) {
                if (opts[i].value === '\(value)' || opts[i].textContent.trim() === '\(value)') {
                    el.selectedIndex = i;
                    el.dispatchEvent(new Event('change', {bubbles: true}));
                    return 'OK';
                }
            }
            return 'OPTION_NOT_FOUND';
        })();
        """
    }

    func clickShowMyResults() async -> (success: Bool, detail: String) {
        let findBtnJS = """
        (function() {
            function humanClick(el, tag) {
                el.scrollIntoView({behavior:'instant',block:'center'});
                var r = el.getBoundingClientRect();
                var cx = r.left + r.width * (0.3 + Math.random() * 0.4);
                var cy = r.top + r.height * (0.3 + Math.random() * 0.4);
                el.dispatchEvent(new PointerEvent('pointerover',{bubbles:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse'}));
                el.dispatchEvent(new MouseEvent('mouseover',{bubbles:true,clientX:cx,clientY:cy}));
                el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0,buttons:1}));
                el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0,buttons:1}));
                el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0}));
                el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0}));
                el.click();
                if (el.focus) el.focus();
                return tag;
            }
            var strategies = [
                function() {
                    var el = document.querySelector('button[data-type="submit"]') || document.querySelector('input[data-type="submit"]');
                    if (el) return humanClick(el, 'DATA_TYPE_SUBMIT');
                    return null;
                },
                function() {
                    var btns = document.querySelectorAll('button, input[type="submit"], a.btn, [role="button"], a[href*="submit"]');
                    for (var i = 0; i < btns.length; i++) {
                        var text = (btns[i].textContent || btns[i].value || '').toLowerCase().trim();
                        if (text.indexOf('show my results') !== -1) return humanClick(btns[i], 'TEXT_EXACT');
                    }
                    return null;
                },
                function() {
                    var btns = document.querySelectorAll('button, input[type="submit"], a.btn, [role="button"]');
                    for (var i = 0; i < btns.length; i++) {
                        var text = (btns[i].textContent || btns[i].value || '').toLowerCase().trim();
                        if (text.indexOf('show') !== -1 && text.indexOf('result') !== -1) return humanClick(btns[i], 'TEXT_PARTIAL');
                    }
                    return null;
                },
                function() {
                    var el = document.querySelector('[aria-label*="show" i][aria-label*="result" i]') ||
                             document.querySelector('[title*="show" i][title*="result" i]');
                    if (el) return humanClick(el, 'ARIA_TITLE');
                    return null;
                },
                function() {
                    var btn = document.getElementById('submit') || document.getElementById('Submit') ||
                             document.getElementById('btnSubmit') || document.getElementById('btn-submit');
                    if (btn) return humanClick(btn, 'ID_SUBMIT');
                    return null;
                },
                function() {
                    var el = document.querySelector('button.btn-primary[type="submit"]') ||
                             document.querySelector('button.btn-primary') ||
                             document.querySelector('input.btn-primary[type="submit"]');
                    if (el) return humanClick(el, 'BTN_PRIMARY');
                    return null;
                },
                function() {
                    var btns = document.querySelectorAll('button[type="submit"], input[type="submit"]');
                    if (btns.length > 0) return humanClick(btns[btns.length - 1], 'LAST_SUBMIT');
                    return null;
                },
                function() {
                    var forms = document.querySelectorAll('form');
                    if (forms.length > 0) { forms[0].submit(); return 'FORM_SUBMITTED'; }
                    return null;
                }
            ];
            for (var i = 0; i < strategies.length; i++) {
                try {
                    var result = strategies[i]();
                    if (result) return result;
                } catch(e) {}
            }
            return 'NOT_FOUND';
        })();
        """

        for attempt in 1...3 {
            let result = await executeJS(findBtnJS)
            if let result, result != "NOT_FOUND" {
                return (true, "Submit clicked via: \(result) (attempt \(attempt))")
            }
            if attempt < 3 {
                let backoff = Double(attempt) * max(0.5, 1.0 * speedMultiplier)
                try? await Task.sleep(for: .seconds(backoff))
            }
        }
        return (false, "Submit button not found after 3 attempts")
    }

    func verifyFieldsExist() async -> (found: Int, missing: [String], details: [String: String]) {
        let js = """
        (function() {
            \(findFieldJS)
            var fieldDefs = {
                'vin': [{"type":"id","value":"vin"},{"type":"name","value":"vin"},{"type":"placeholder","value":"Enter VIN"},{"type":"label","value":"VIN"},{"type":"css","value":"input[type='text']:first-of-type"}],
                'email': [{"type":"id","value":"email"},{"type":"name","value":"email"},{"type":"placeholder","value":"email"},{"type":"css","value":"input[type='email']"}],
                'cardNumber': [{"type":"id","value":"cardNumber"},{"type":"name","value":"cardNumber"},{"type":"placeholder","value":"card number"},{"type":"css","value":"input[autocomplete='cc-number']"}],
                'expMonth': [{"type":"id","value":"expMonth"},{"type":"name","value":"expMonth"},{"type":"placeholder","value":"MM"},{"type":"css","value":"input[autocomplete='cc-exp-month']"}],
                'expYear': [{"type":"id","value":"expYear"},{"type":"name","value":"expYear"},{"type":"placeholder","value":"YY"},{"type":"css","value":"input[autocomplete='cc-exp-year']"}],
                'cvv': [{"type":"id","value":"cvv"},{"type":"name","value":"cvv"},{"type":"placeholder","value":"CVV"},{"type":"css","value":"input[autocomplete='cc-csc']"}]
            };
            var found = 0; var missing = []; var details = {};
            for (var name in fieldDefs) {
                var el = findField(fieldDefs[name]);
                if (el) { found++; details[name] = 'found:' + (el.id || el.name || el.placeholder || el.tagName).substring(0, 30); }
                else { missing.push(name); details[name] = 'missing'; }
            }
            return JSON.stringify({found: found, missing: missing, details: details});
        })();
        """
        guard let result = await executeJS(js),
              let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let found = json["found"] as? Int,
              let missing = json["missing"] as? [String],
              let details = json["details"] as? [String: String] else {
            return (0, ["vin", "email", "cardNumber", "expMonth", "expYear", "cvv"], [:])
        }
        return (found, missing, details)
    }

    func dumpPageStructure() async -> String {
        let js = """
        (function() {
            var info = {};
            info.title = document.title;
            info.url = window.location.href;
            info.readyState = document.readyState;
            var inputs = document.querySelectorAll('input, select, textarea');
            info.inputCount = inputs.length;
            info.inputs = [];
            for (var i = 0; i < Math.min(inputs.length, 20); i++) {
                var inp = inputs[i];
                info.inputs.push({tag: inp.tagName, type: inp.type || '', id: inp.id || '', name: inp.name || '', placeholder: inp.placeholder || ''});
            }
            var buttons = document.querySelectorAll('button, input[type="submit"], [role="button"]');
            info.buttonCount = buttons.length;
            info.iframeCount = document.querySelectorAll('iframe').length;
            var bodyText = (document.body ? document.body.innerText : '').substring(0, 500);
            info.bodyPreview = bodyText;
            return JSON.stringify(info);
        })();
        """
        return await executeJS(js) ?? "{}"
    }

    func captureScreenshot() async -> UIImage? {
        guard let webView else { return nil }
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }
        if webView.url == nil && !webView.isLoading {
            return nil
        }
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        do {
            return try await webView.takeSnapshot(configuration: config)
        } catch {
            return nil
        }
    }

    func captureScreenshotWithCrop(cropRect: CGRect?) async -> (full: UIImage?, cropped: UIImage?) {
        guard let fullImage = await captureScreenshot() else { return (nil, nil) }
        guard let cropRect, cropRect != .zero else { return (fullImage, nil) }

        let scale = fullImage.scale
        let scaledRect = CGRect(
            x: cropRect.origin.x * scale,
            y: cropRect.origin.y * scale,
            width: cropRect.size.width * scale,
            height: cropRect.size.height * scale
        )
        if let cgImage = fullImage.cgImage?.cropping(to: scaledRect) {
            let cropped = UIImage(cgImage: cgImage, scale: scale, orientation: fullImage.imageOrientation)
            return (fullImage, cropped)
        }
        return (fullImage, nil)
    }

    func getPageTitle() async -> String {
        await executeJS("document.title") ?? "Unknown"
    }

    func getCurrentURL() async -> String {
        webView?.url?.absoluteString ?? "N/A"
    }

    func waitForNavigation(timeout: TimeInterval = 90) async -> Bool {
        let timeout = TimeoutResolver.resolveAutomationTimeout(timeout)
        let start = Date()
        let originalURL = webView?.url?.absoluteString ?? ""
        let originalBody = await executeJS("document.body ? document.body.innerText.substring(0, 200) : ''") ?? ""

        while Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(for: .milliseconds(750))

            let currentURL = webView?.url?.absoluteString ?? ""
            if currentURL != originalURL && !currentURL.isEmpty {
                try? await Task.sleep(for: .milliseconds(1500))
                return true
            }

            let bodyText = await executeJS("document.body ? document.body.innerText.substring(0, 500) : ''") ?? ""
            if bodyText != originalBody && bodyText.count > 50 {
                let bodyLower = bodyText.lowercased()
                let indicators = ["result", "report", "success", "confirmation", "receipt", "institution", "invalid", "declined", "fail"]
                for indicator in indicators {
                    if bodyLower.contains(indicator) {
                        try? await Task.sleep(for: .milliseconds(1000))
                        return true
                    }
                }
            }
        }
        return false
    }

    func getPageContent() async -> String {
        await executeJS("document.body ? document.body.innerText.substring(0, 3000) : ''") ?? ""
    }

    func checkForIframes() async -> Int {
        let result = await executeJS("document.querySelectorAll('iframe').length")
        return Int(result ?? "0") ?? 0
    }

    private func classifyFillResult(_ result: String?, fieldName: String) -> (success: Bool, detail: String) {
        switch result {
        case "OK":
            return (true, "\(fieldName) filled successfully")
        case "VALUE_MISMATCH":
            return (true, "\(fieldName) filled but value verification mismatch")
        case "NOT_FOUND":
            return (false, "\(fieldName) selector NOT_FOUND")
        case nil:
            return (false, "\(fieldName) JS execution returned nil")
        default:
            return (false, "\(fieldName) unexpected result: '\(result ?? "")'")
        }
    }

    private func executeJS(_ js: String) async -> String? {
        guard let webView else {
            logger.log("LoginWebSession: executeJS — webView nil", category: .webView, level: .warning)
            return nil
        }
        do {
            let result = try await webView.evaluateJavaScript(js)
            if let str = result as? String {
                return str
            }
            if let num = result as? NSNumber {
                return "\(num)"
            }
            return nil
        } catch {
            logger.logError("LoginWebSession: JS eval failed", error: error, category: .webView, metadata: [
                "jsPrefix": String(js.prefix(60))
            ])
            return nil
        }
    }
}

extension LoginWebSession: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.isPageLoaded = true
            self.resolvePageLoad(true)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.lastNavigationError = self.classifyNavigationError(error)
            self.resolvePageLoad(false)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.lastNavigationError = self.classifyNavigationError(error)
            self.resolvePageLoad(false)
        }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            Task { @MainActor in
                self.lastHTTPStatusCode = httpResponse.statusCode
            }
        }
        decisionHandler(.allow)
    }

    private func classifyNavigationError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet: return "No internet connection"
            case NSURLErrorTimedOut: return "Connection timed out"
            case NSURLErrorCannotFindHost: return "DNS resolution failed"
            case NSURLErrorCannotConnectToHost: return "Cannot connect to server"
            case NSURLErrorNetworkConnectionLost: return "Network connection lost"
            case NSURLErrorDNSLookupFailed: return "DNS lookup failed"
            case NSURLErrorSecureConnectionFailed: return "SSL/TLS handshake failed"
            default: return "Network error (\(nsError.code)): \(nsError.localizedDescription)"
            }
        }
        if nsError.domain == "WebKitErrorDomain" {
            switch nsError.code {
            case 102: return "Frame load interrupted"
            case 101: return "Request cancelled"
            default: return "WebKit error (\(nsError.code)): \(nsError.localizedDescription)"
            }
        }
        return "Navigation error: \(error.localizedDescription)"
    }
}
