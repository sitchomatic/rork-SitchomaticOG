import Foundation
import WebKit
import UIKit

@MainActor
class BPointWebSession: NSObject {
    private(set) var webView: WKWebView?
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

    static let targetURL = URL(string: "https://www.bpoint.com.au/payments/DepartmentOfFinance")!
    static let billerLookupURL = URL(string: "https://www.bpoint.com.au/payments/billpayment/Payment/Index")!
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
                self.logger.log("BPointWebSession: failed to compile block content rules (\(error.localizedDescription))", category: .webView, level: .warning)
            }
        }
    }

    func setUp() {
        logger.log("BPointWebSession: setUp (stealth=\(stealthEnabled), network=\(networkConfig.label))", category: .webView, level: .debug)
        if webView != nil { tearDown() }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        if blockImages {
            let blockScript = WKUserScript(source: """
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
            config.userContentController.addUserScript(blockScript)
        }
        installBlockContentRules(on: config.userContentController)

        let proxyApplied = NetworkSessionFactory.shared.configureWKWebView(config: config, networkConfig: networkConfig, target: .ppsr)
        isProtectedRouteBlocked = networkConfig.requiresProtectedRoute && !proxyApplied
        if isProtectedRouteBlocked {
            lastNavigationError = "Protected BPoint route blocked — no proxy path available"
            logger.log("BPointWebSession: BLOCKED — no proxy available", category: .network, level: .error)
        }

        if stealthEnabled {
            let stealth = PPSRStealthService.shared
            let profile = stealth.nextProfileSync()
            self.stealthProfile = profile
            let userScript = stealth.createStealthUserScript(profile: profile)
            config.userContentController.addUserScript(userScript)
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: profile.viewport.width, height: profile.viewport.height), configuration: config)
            wv.navigationDelegate = self
            wv.customUserAgent = profile.userAgent
            self.webView = wv
        } else {
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
            wv.navigationDelegate = self
            wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
            self.webView = wv
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

    func loadPage(timeout: TimeInterval = 90) async -> Bool {
        let timeout = TimeoutResolver.resolvePageLoadTimeout(timeout)
        guard let webView else {
            lastNavigationError = "WebView not initialized"
            return false
        }
        guard !isProtectedRouteBlocked else {
            logger.log("BPointWebSession: loadPage blocked — protected route", category: .network, level: .error)
            return false
        }
        logger.startTimer(key: "bpointWebSession_load")
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

        let loadMs = logger.stopTimer(key: "bpointWebSession_load")
        if loaded {
            logger.log("BPointWebSession: page loaded in \(loadMs ?? 0)ms", category: .webView, level: .success, durationMs: loadMs)
            if stealthEnabled, let profile = stealthProfile {
                _ = await executeJS(PPSRStealthService.shared.fingerprintJS())
                _ = try? await Task.sleep(for: .milliseconds(1500))
            }
            await waitForDOMReady(timeout: TimeoutResolver.resolveAutomationTimeout(10))
        } else {
            logger.log("BPointWebSession: page load FAILED — \(lastNavigationError ?? "unknown")", category: .webView, level: .error, durationMs: loadMs)
        }
        return loaded
    }

    func loadURL(_ url: URL, timeout: TimeInterval = 90) async -> Bool {
        let timeout = TimeoutResolver.resolvePageLoadTimeout(timeout)
        guard let webView else { return false }
        isPageLoaded = false
        lastNavigationError = nil

        if let existingCont = pageLoadContinuation {
            pageLoadContinuation = nil
            existingCont.resume(returning: false)
        }

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
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

        if loaded {
            await waitForDOMReady(timeout: TimeoutResolver.resolveAutomationTimeout(10))
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
                            if (forId) { el = document.getElementById(forId); }
                            else { el = labels[j].querySelector('input, textarea, select'); }
                            if (el) break;
                        }
                    }
                } else if (s.type === 'css') {
                    el = document.querySelector(s.value);
                } else if (s.type === 'ariaLabel') {
                    el = document.querySelector('[aria-label*="' + s.value + '"]');
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

    func fillReferenceNumber(_ ref: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"BillerCode"},{"type":"id","value":"billerCode"},
            {"type":"id","value":"Reference1"},{"type":"id","value":"reference1"},
            {"type":"name","value":"BillerCode"},{"type":"name","value":"Reference1"},
            {"type":"placeholder","value":"Reference"},{"type":"placeholder","value":"reference"},
            {"type":"label","value":"reference"},{"type":"label","value":"Reference Number"},
            {"type":"css","value":"input[type='text']:first-of-type"},
            {"type":"css","value":"input.form-control:first-of-type"},
            {"type":"css","value":"#Crn1"},{"type":"id","value":"Crn1"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: ref))
        return classifyFillResult(result, fieldName: "Reference Number")
    }

    func fillAmount(_ amount: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"Amount"},{"type":"id","value":"amount"},
            {"type":"id","value":"PaymentAmount"},{"type":"id","value":"paymentAmount"},
            {"type":"name","value":"Amount"},{"type":"name","value":"PaymentAmount"},
            {"type":"placeholder","value":"Amount"},{"type":"placeholder","value":"0.00"},
            {"type":"label","value":"amount"},{"type":"label","value":"Amount"},
            {"type":"css","value":"input[type='text']:nth-of-type(2)"},
            {"type":"css","value":"input.form-control:last-of-type"},
            {"type":"css","value":"#Amount"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: amount))
        return classifyFillResult(result, fieldName: "Amount")
    }

    func clickCardBrandLogo(isVisa: Bool) async -> (success: Bool, detail: String) {
        let brandName = isVisa ? "visa" : "mastercard"
        let altBrandName = isVisa ? "visa" : "master"
        let titleName = isVisa ? "Visa" : "MasterCard"
        let js = """
        (function() {
            function humanClick(el, tag) {
                el.scrollIntoView({behavior:'instant',block:'center'});
                var r = el.getBoundingClientRect();
                var cx = r.left + r.width * (0.3 + Math.random() * 0.4);
                var cy = r.top + r.height * (0.3 + Math.random() * 0.4);
                el.dispatchEvent(new PointerEvent('pointerover',{bubbles:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse'}));
                el.dispatchEvent(new MouseEvent('mouseover',{bubbles:true,clientX:cx,clientY:cy}));
                el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0,buttons:1}));
                el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0,buttons:1}));
                el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0}));
                el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
                el.click();
                if (el.focus) el.focus();
                return tag;
            }
            var strategies = [
                function() {
                    var el = document.querySelector('div.\(brandName)') || document.querySelector('.\(brandName)');
                    if (el) return humanClick(el, 'CLASS_DIV');
                    return null;
                },
                function() {
                    var el = document.querySelector('[data-type="\(brandName)"]');
                    if (el) return humanClick(el, 'DATA_TYPE');
                    return null;
                },
                function() {
                    var el = document.querySelector('[aria-label="\(titleName)"]') || document.querySelector('[aria-label="\(brandName)"]');
                    if (el) return humanClick(el, 'ARIA_LABEL');
                    return null;
                },
                function() {
                    var el = document.querySelector('[title="\(titleName)"]') || document.querySelector('[title="\(brandName)"]');
                    if (el) return humanClick(el, 'TITLE');
                    return null;
                },
                function() {
                    var imgs = document.querySelectorAll('img');
                    for (var i = 0; i < imgs.length; i++) {
                        var src = (imgs[i].src || '').toLowerCase();
                        var alt = (imgs[i].alt || '').toLowerCase();
                        var title = (imgs[i].title || '').toLowerCase();
                        if (src.indexOf('\(brandName)') !== -1 || alt.indexOf('\(brandName)') !== -1 || title.indexOf('\(brandName)') !== -1 ||
                            src.indexOf('\(altBrandName)') !== -1 || alt.indexOf('\(altBrandName)') !== -1) {
                            var parent = imgs[i].parentElement;
                            if (parent && (parent.tagName === 'A' || parent.tagName === 'BUTTON' || parent.onclick || parent.getAttribute('role') === 'button' || parent.getAttribute('tabindex'))) {
                                return humanClick(parent, 'IMG_PARENT');
                            }
                            return humanClick(imgs[i], 'IMG_DIRECT');
                        }
                    }
                    return null;
                },
                function() {
                    var all = document.querySelectorAll('div, a, button, span, [role="button"], label, [tabindex]');
                    for (var i = 0; i < all.length; i++) {
                        var cls = (all[i].className || '').toLowerCase();
                        var id = (all[i].id || '').toLowerCase();
                        var dt = (all[i].getAttribute('data-type') || '').toLowerCase();
                        var text = (all[i].textContent || '').toLowerCase().trim();
                        if (cls.indexOf('\(brandName)') !== -1 || id.indexOf('\(brandName)') !== -1 || dt.indexOf('\(brandName)') !== -1 ||
                            cls.indexOf('\(altBrandName)') !== -1 || text === '\(brandName)' || text === '\(altBrandName)') {
                            return humanClick(all[i], 'GENERIC_MATCH');
                        }
                    }
                    return null;
                },
                function() {
                    var radios = document.querySelectorAll('input[type="radio"]');
                    for (var i = 0; i < radios.length; i++) {
                        var lbl = radios[i].closest('label') || document.querySelector('label[for="' + radios[i].id + '"]');
                        var labelText = lbl ? (lbl.textContent || '').toLowerCase() : '';
                        var val = (radios[i].value || '').toLowerCase();
                        if (val.indexOf('\(brandName)') !== -1 || labelText.indexOf('\(brandName)') !== -1 ||
                            val.indexOf('\(altBrandName)') !== -1 || labelText.indexOf('\(altBrandName)') !== -1) {
                            radios[i].checked = true;
                            radios[i].dispatchEvent(new Event('change', {bubbles: true}));
                            return humanClick(radios[i], 'RADIO');
                        }
                    }
                    return null;
                }
            ];
            for (var i = 0; i < strategies.length; i++) {
                var result = strategies[i]();
                if (result) return result;
            }
            return 'NOT_FOUND';
        })();
        """

        for attempt in 1...3 {
            let result = await executeJS(js)
            if let result, result != "NOT_FOUND" {
                return (true, "\(isVisa ? "Visa" : "Mastercard") clicked via: \(result) (attempt \(attempt))")
            }
            if attempt < 3 {
                let backoff = Double(attempt) * max(0.5, 1.0 * speedMultiplier)
                try? await Task.sleep(for: .seconds(backoff))
            }
        }
        return (false, "\(isVisa ? "Visa" : "Mastercard") not found after 3 attempts")
    }

    func fillCardNumber(_ number: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"CardNumber"},{"type":"id","value":"cardNumber"},{"type":"id","value":"card-number"},
            {"type":"name","value":"CardNumber"},{"type":"name","value":"cardNumber"},{"type":"name","value":"card_number"},
            {"type":"placeholder","value":"Card Number"},{"type":"placeholder","value":"card number"},
            {"type":"label","value":"card number"},{"type":"ariaLabel","value":"card number"},
            {"type":"css","value":"input[autocomplete='cc-number']"},
            {"type":"css","value":"input[inputmode='numeric']"},
            {"type":"css","value":"#CardNumber"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: number))
        return classifyFillResult(result, fieldName: "Card Number")
    }

    func fillExpiry(_ expiry: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"ExpiryDate"},{"type":"id","value":"expiry"},{"type":"id","value":"Expiry"},
            {"type":"name","value":"ExpiryDate"},{"type":"name","value":"expiry"},
            {"type":"placeholder","value":"MM/YY"},{"type":"placeholder","value":"Expiry"},
            {"type":"label","value":"expiry"},{"type":"label","value":"Expiry Date"},
            {"type":"css","value":"input[autocomplete='cc-exp']"},
            {"type":"css","value":"#ExpiryDate"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: expiry))
        return classifyFillResult(result, fieldName: "Expiry")
    }

    func fillExpMonth(_ month: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"ExpiryMonth"},{"type":"id","value":"expMonth"},{"type":"id","value":"exp-month"},
            {"type":"name","value":"ExpiryMonth"},{"type":"name","value":"expMonth"},
            {"type":"placeholder","value":"MM"},{"type":"label","value":"month"},
            {"type":"css","value":"input[autocomplete='cc-exp-month']"},
            {"type":"css","value":"select[autocomplete='cc-exp-month']"},
            {"type":"css","value":"#ExpiryMonth"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: month))
        if result == "OK" || result == "VALUE_MISMATCH" { return (true, "Exp Month filled") }
        let selectResult = await executeJS(fillSelectJS(strategies: strategies, value: month))
        if selectResult == "OK" { return (true, "Exp Month filled via select") }
        return (false, "Exp Month fill failed: \(result ?? "nil")")
    }

    func fillExpYear(_ year: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"ExpiryYear"},{"type":"id","value":"expYear"},{"type":"id","value":"exp-year"},
            {"type":"name","value":"ExpiryYear"},{"type":"name","value":"expYear"},
            {"type":"placeholder","value":"YY"},{"type":"label","value":"year"},
            {"type":"css","value":"input[autocomplete='cc-exp-year']"},
            {"type":"css","value":"select[autocomplete='cc-exp-year']"},
            {"type":"css","value":"#ExpiryYear"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: year))
        if result == "OK" || result == "VALUE_MISMATCH" { return (true, "Exp Year filled") }
        let selectResult = await executeJS(fillSelectJS(strategies: strategies, value: year))
        if selectResult == "OK" { return (true, "Exp Year filled via select") }
        return (false, "Exp Year fill failed: \(result ?? "nil")")
    }

    func fillCVV(_ cvv: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"Cvn"},{"type":"id","value":"cvv"},{"type":"id","value":"cvc"},{"type":"id","value":"SecurityCode"},
            {"type":"name","value":"Cvn"},{"type":"name","value":"cvv"},{"type":"name","value":"cvc"},
            {"type":"placeholder","value":"CVV"},{"type":"placeholder","value":"CVC"},{"type":"placeholder","value":"CVN"},
            {"type":"label","value":"CVV"},{"type":"label","value":"CVC"},{"type":"label","value":"security code"},
            {"type":"css","value":"input[autocomplete='cc-csc']"},
            {"type":"css","value":"#Cvn"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: cvv))
        return classifyFillResult(result, fieldName: "CVV")
    }

    func clickSubmitPayment() async -> (success: Bool, detail: String) {
        let js = """
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
                    var btns = document.querySelectorAll('button, input[type="submit"], a.btn, [role="button"]');
                    for (var i = 0; i < btns.length; i++) {
                        var text = (btns[i].textContent || btns[i].value || '').toLowerCase().trim();
                        if (text.indexOf('pay now') !== -1 || text.indexOf('submit payment') !== -1 || text.indexOf('make payment') !== -1 || text.indexOf('proceed') !== -1) {
                            return humanClick(btns[i], 'PAY_TEXT');
                        }
                    }
                    return null;
                },
                function() {
                    var btns = document.querySelectorAll('button[type="submit"], input[type="submit"]');
                    for (var i = 0; i < btns.length; i++) {
                        var text = (btns[i].textContent || btns[i].value || '').toLowerCase().trim();
                        if (text.indexOf('pay') !== -1 || text.indexOf('submit') !== -1) {
                            return humanClick(btns[i], 'SUBMIT_TEXT');
                        }
                    }
                    return null;
                },
                function() {
                    var btns = document.querySelectorAll('button[type="submit"], input[type="submit"]');
                    if (btns.length > 0) return humanClick(btns[btns.length - 1], 'LAST_SUBMIT');
                    return null;
                },
                function() {
                    var forms = document.querySelectorAll('form');
                    if (forms.length > 0) { forms[forms.length - 1].submit(); return 'FORM_SUBMITTED'; }
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
            let result = await executeJS(js)
            if let result, result != "NOT_FOUND" {
                return (true, "Payment submit clicked: \(result) (attempt \(attempt))")
            }
            if attempt < 3 {
                let backoff = Double(attempt) * max(0.5, 1.0 * speedMultiplier)
                try? await Task.sleep(for: .seconds(backoff))
            }
        }
        return (false, "Submit payment button not found after 3 attempts")
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

    func loadBillerLookupPage(timeout: TimeInterval = 90) async -> Bool {
        let timeout = TimeoutResolver.resolvePageLoadTimeout(timeout)
        guard let webView else {
            lastNavigationError = "WebView not initialized"
            return false
        }
        guard !isProtectedRouteBlocked else {
            logger.log("BPointWebSession: loadBillerLookup blocked — protected route", category: .network, level: .error)
            return false
        }
        isPageLoaded = false
        lastNavigationError = nil
        lastHTTPStatusCode = nil

        if let existingCont = pageLoadContinuation {
            pageLoadContinuation = nil
            existingCont.resume(returning: false)
        }

        let request = URLRequest(url: Self.billerLookupURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        webView.load(request)

        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.pageLoadContinuation = continuation
            self.loadTimeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeout))
                await MainActor.run {
                    self.resolvePageLoad(false, errorMessage: "Biller lookup page timed out after \(Int(timeout))s")
                }
            }
        }
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil

        if loaded {
            if stealthEnabled {
                _ = await executeJS(PPSRStealthService.shared.fingerprintJS())
                try? await Task.sleep(for: .milliseconds(500))
            }
            await waitForDOMReady(timeout: TimeoutResolver.resolveAutomationTimeout(10))
        }
        return loaded
    }

    func enterBillerCodeAndSearch(_ code: String) async -> (success: Bool, detail: String) {
        let escaped = code.replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
            var input = document.querySelector('input[name="BillerCode"]')
                     || document.querySelector('input[id="BillerCode"]')
                     || document.querySelector('input[placeholder*="iller"]')
                     || document.querySelector('input[type="text"]');
            if (!input) return 'INPUT_NOT_FOUND';
            input.focus();
            var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(input, '\(escaped)'); }
            else { input.value = '\(escaped)'; }
            input.dispatchEvent(new Event('focus', {bubbles: true}));
            input.dispatchEvent(new Event('input', {bubbles: true}));
            input.dispatchEvent(new Event('change', {bubbles: true}));
            input.dispatchEvent(new Event('blur', {bubbles: true}));

            var btn = null;
            var allBtns = document.querySelectorAll('button, input[type="submit"], a.btn, [role="button"]');
            for (var i = 0; i < allBtns.length; i++) {
                var txt = (allBtns[i].textContent || allBtns[i].value || '').toLowerCase().trim();
                if (txt.indexOf('find') !== -1 || txt.indexOf('search') !== -1 || txt.indexOf('look') !== -1 || txt.indexOf('go') !== -1) {
                    btn = allBtns[i]; break;
                }
            }
            if (!btn) {
                var submits = document.querySelectorAll('button[type="submit"], input[type="submit"]');
                if (submits.length > 0) btn = submits[0];
            }
            if (!btn) {
                var forms = document.querySelectorAll('form');
                if (forms.length > 0) { forms[0].submit(); return 'FORM_SUBMITTED'; }
                return 'BTN_NOT_FOUND';
            }
            btn.click();
            return 'CLICKED';
        })();
        """
        let result = await executeJS(js)
        if let result, result == "CLICKED" || result == "FORM_SUBMITTED" {
            return (true, "Biller code \(code) entered and search triggered: \(result)")
        }
        return (false, "Biller lookup failed: \(result ?? "nil")")
    }

    func detectFormFields() async -> (textFieldCount: Int, hasAmountField: Bool, detail: String) {
        let js = """
        (function() {
            var allInputs = document.querySelectorAll('input[type="text"], input[type="number"], input:not([type])');
            var textFields = [];
            var amountField = false;
            for (var i = 0; i < allInputs.length; i++) {
                var inp = allInputs[i];
                if (inp.offsetParent === null && !inp.offsetWidth) continue;
                if (inp.disabled || inp.readOnly) continue;
                var id = (inp.id || '').toLowerCase();
                var name = (inp.name || '').toLowerCase();
                var placeholder = (inp.placeholder || '').toLowerCase();
                var label = '';
                if (inp.id) {
                    var lbl = document.querySelector('label[for="' + inp.id + '"]');
                    if (lbl) label = (lbl.textContent || '').toLowerCase().trim();
                }
                if (!lbl) {
                    var parent = inp.closest('label, .form-group, .field-group, div');
                    if (parent) {
                        var parentLabel = parent.querySelector('label, .label, span');
                        if (parentLabel) label = (parentLabel.textContent || '').toLowerCase().trim();
                    }
                }
                var isAmount = id.indexOf('amount') !== -1 || name.indexOf('amount') !== -1
                    || placeholder.indexOf('amount') !== -1 || placeholder.indexOf('0.00') !== -1
                    || label.indexOf('amount') !== -1 || id.indexOf('payment') !== -1;
                if (isAmount) { amountField = true; continue; }
                var isHidden = inp.type === 'hidden';
                if (isHidden) continue;
                textFields.push({id: inp.id || '', name: inp.name || '', idx: i});
            }
            return JSON.stringify({count: textFields.length, hasAmount: amountField, fields: textFields});
        })();
        """
        let result = await executeJS(js) ?? "{}"
        if let data = result.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let count = json["count"] as? Int ?? 0
            let hasAmount = json["hasAmount"] as? Bool ?? false
            return (count, hasAmount, "Detected \(count) text fields, amount field: \(hasAmount)")
        }
        return (0, false, "Failed to parse form structure")
    }

    func fillAllFormFields(amount: String) async -> (success: Bool, detail: String) {
        let amountEscaped = amount.replacingOccurrences(of: "'", with: "\\'")
        var allValues: [String] = []
        for _ in 0..<10 {
            let val = BPointBillerPoolService.generateRandomFieldValue()
            allValues.append(val.replacingOccurrences(of: "'", with: "\\'"))
        }
        let valuesJSON = "[" + allValues.map { "'\($0)'" }.joined(separator: ",") + "]"

        let js = """
        (function() {
            var values = \(valuesJSON);
            var allInputs = document.querySelectorAll('input[type="text"], input[type="number"], input:not([type])');
            var filled = 0;
            var amountFilled = false;
            var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            function setVal(el, val) {
                el.focus();
                if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, val); }
                else { el.value = val; }
                el.dispatchEvent(new Event('focus', {bubbles: true}));
                el.dispatchEvent(new Event('input', {bubbles: true}));
                el.dispatchEvent(new Event('change', {bubbles: true}));
                el.dispatchEvent(new Event('blur', {bubbles: true}));
            }
            for (var i = 0; i < allInputs.length; i++) {
                var inp = allInputs[i];
                if (inp.offsetParent === null && !inp.offsetWidth) continue;
                if (inp.disabled || inp.readOnly) continue;
                if (inp.type === 'hidden') continue;
                var id = (inp.id || '').toLowerCase();
                var name = (inp.name || '').toLowerCase();
                var placeholder = (inp.placeholder || '').toLowerCase();
                var label = '';
                if (inp.id) {
                    var lbl = document.querySelector('label[for="' + inp.id + '"]');
                    if (lbl) label = (lbl.textContent || '').toLowerCase().trim();
                }
                var isCard = id.indexOf('card') !== -1 || name.indexOf('card') !== -1
                    || id.indexOf('cvv') !== -1 || id.indexOf('cvn') !== -1 || id.indexOf('cvc') !== -1
                    || id.indexOf('expir') !== -1 || name.indexOf('expir') !== -1
                    || id.indexOf('secur') !== -1 || name.indexOf('secur') !== -1;
                if (isCard) continue;
                var isAmount = id.indexOf('amount') !== -1 || name.indexOf('amount') !== -1
                    || placeholder.indexOf('amount') !== -1 || placeholder.indexOf('0.00') !== -1
                    || label.indexOf('amount') !== -1 || id.indexOf('paymentamount') !== -1;
                if (isAmount) {
                    setVal(inp, '\(amountEscaped)');
                    amountFilled = true;
                    continue;
                }
                var val = values[filled % values.length];
                setVal(inp, val);
                filled++;
            }
            return JSON.stringify({filled: filled, amountFilled: amountFilled});
        })();
        """
        let result = await executeJS(js) ?? "{}"
        if let data = result.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let filled = json["filled"] as? Int ?? 0
            let amountFilled = json["amountFilled"] as? Bool ?? false
            if filled == 0 && !amountFilled {
                return (false, "No fields filled")
            }
            return (true, "Filled \(filled) text fields, amount: \(amountFilled)")
        }
        return (false, "Failed to fill form fields")
    }

    func checkForValidationErrors() async -> (hasErrors: Bool, detail: String) {
        let js = """
        (function() {
            var errors = [];
            var errorEls = document.querySelectorAll('.field-validation-error, .validation-summary-errors, .error-message, .text-danger, .invalid-feedback, [class*="error"], [class*="Error"]');
            for (var i = 0; i < errorEls.length; i++) {
                var el = errorEls[i];
                var text = (el.textContent || '').trim();
                if (text.length > 0 && text.length < 200 && el.offsetParent !== null) {
                    errors.push(text);
                }
            }
            var redSpans = document.querySelectorAll('span[style*="color"], span[style*="red"], div[style*="red"]');
            for (var i = 0; i < redSpans.length; i++) {
                var text = (redSpans[i].textContent || '').trim();
                if (text.length > 0 && text.length < 200) {
                    var style = window.getComputedStyle(redSpans[i]);
                    if (style.color === 'rgb(255, 0, 0)' || style.color.indexOf('red') !== -1
                        || style.color === 'rgb(220, 53, 69)' || style.color === 'rgb(169, 68, 66)') {
                        errors.push(text);
                    }
                }
            }
            var unique = [];
            for (var i = 0; i < errors.length; i++) {
                if (unique.indexOf(errors[i]) === -1) unique.push(errors[i]);
            }
            return JSON.stringify({hasErrors: unique.length > 0, errors: unique.slice(0, 5)});
        })();
        """
        let result = await executeJS(js) ?? "{}"
        if let data = result.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let hasErrors = json["hasErrors"] as? Bool ?? false
            let errors = json["errors"] as? [String] ?? []
            let detail = hasErrors ? errors.joined(separator: "; ") : "No validation errors"
            return (hasErrors, detail)
        }
        return (false, "Could not check for errors")
    }

    func detectEmailFieldOnPaymentPage() async -> (hasEmail: Bool, detail: String) {
        let js = """
        (function() {
            var inputs = document.querySelectorAll('input[type="email"], input[type="text"], input:not([type])');
            for (var i = 0; i < inputs.length; i++) {
                var inp = inputs[i];
                if (inp.offsetParent === null && !inp.offsetWidth) continue;
                if (inp.disabled) continue;
                var id = (inp.id || '').toLowerCase();
                var name = (inp.name || '').toLowerCase();
                var placeholder = (inp.placeholder || '').toLowerCase();
                var autocomplete = (inp.getAttribute('autocomplete') || '').toLowerCase();
                var label = '';
                if (inp.id) {
                    var lbl = document.querySelector('label[for="' + inp.id + '"]');
                    if (lbl) label = (lbl.textContent || '').toLowerCase().trim();
                }
                if (inp.type === 'email') return JSON.stringify({hasEmail: true, reason: 'type=email field found'});
                if (autocomplete === 'email') return JSON.stringify({hasEmail: true, reason: 'autocomplete=email'});
                if (id.indexOf('email') !== -1 || name.indexOf('email') !== -1)
                    return JSON.stringify({hasEmail: true, reason: 'email in id/name: ' + (id || name)});
                if (placeholder.indexOf('email') !== -1 || placeholder.indexOf('e-mail') !== -1)
                    return JSON.stringify({hasEmail: true, reason: 'email in placeholder'});
                if (label.indexOf('email') !== -1 || label.indexOf('e-mail') !== -1)
                    return JSON.stringify({hasEmail: true, reason: 'email in label: ' + label});
            }
            return JSON.stringify({hasEmail: false, reason: 'no email field detected'});
        })();
        """
        let result = await executeJS(js) ?? "{}"
        if let data = result.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let hasEmail = json["hasEmail"] as? Bool ?? false
            let reason = json["reason"] as? String ?? ""
            return (hasEmail, reason)
        }
        return (false, "Could not detect email field")
    }

    func waitForContentChange(timeout: TimeInterval = 15) async -> Bool {
        let timeout = TimeoutResolver.resolveAutomationTimeout(timeout)
        let start = Date()
        let originalBody = await executeJS("document.body ? document.body.innerText.substring(0, 300) : ''") ?? ""
        let originalURL = webView?.url?.absoluteString ?? ""

        while Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(for: .milliseconds(750))
            let currentURL = webView?.url?.absoluteString ?? ""
            if currentURL != originalURL && !currentURL.isEmpty {
                try? await Task.sleep(for: .milliseconds(1000))
                return true
            }
            let bodyText = await executeJS("document.body ? document.body.innerText.substring(0, 500) : ''") ?? ""
            if bodyText != originalBody && bodyText.count > 30 {
                try? await Task.sleep(for: .milliseconds(500))
                return true
            }
        }
        return false
    }

    func getPageContent() async -> String {
        await executeJS("document.body ? document.body.innerText.substring(0, 3000) : ''") ?? ""
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
                let indicators = ["receipt", "success", "approved", "declined", "transaction", "processed", "do not honour", "insufficient"]
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

    func captureScreenshot() async -> UIImage? {
        guard let webView else { return nil }
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }
        if webView.url == nil && !webView.isLoading { return nil }
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        do { return try await webView.takeSnapshot(configuration: config) }
        catch {
            logger.log("BPointWebSession: screenshot capture failed: \(error.localizedDescription)", category: .screenshot, level: .warning)
            return nil
        }
    }

    func captureScreenshotWithCrop(cropRect: CGRect?) async -> (full: UIImage?, cropped: UIImage?) {
        guard let fullImage = await captureScreenshot() else { return (nil, nil) }
        guard let cropRect, cropRect != .zero else { return (fullImage, nil) }
        let scale = fullImage.scale
        let scaledRect = CGRect(x: cropRect.origin.x * scale, y: cropRect.origin.y * scale, width: cropRect.size.width * scale, height: cropRect.size.height * scale)
        if let cgImage = fullImage.cgImage?.cropping(to: scaledRect) {
            let cropped = UIImage(cgImage: cgImage, scale: scale, orientation: fullImage.imageOrientation)
            return (fullImage, cropped)
        }
        return (fullImage, nil)
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

    private func classifyFillResult(_ result: String?, fieldName: String) -> (success: Bool, detail: String) {
        switch result {
        case "OK": return (true, "\(fieldName) filled successfully")
        case "VALUE_MISMATCH": return (true, "\(fieldName) filled but value verification mismatch")
        case "NOT_FOUND": return (false, "\(fieldName) selector NOT_FOUND")
        case nil: return (false, "\(fieldName) JS execution returned nil")
        default: return (false, "\(fieldName) unexpected result: '\(result ?? "")'")
        }
    }

    func executeJS(_ js: String) async -> String? {
        guard let webView else { return nil }
        do {
            let result = try await webView.evaluateJavaScript(js)
            if let str = result as? String { return str }
            if let num = result as? NSNumber { return "\(num)" }
            return nil
        } catch {
            logger.logError("BPointWebSession: JS eval failed", error: error, category: .webView, metadata: ["jsPrefix": String(js.prefix(60))])
            return nil
        }
    }
}

extension BPointWebSession: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.isPageLoaded = true
            self.resolvePageLoad(true)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.lastNavigationError = error.localizedDescription
            self.resolvePageLoad(false)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.lastNavigationError = error.localizedDescription
            self.resolvePageLoad(false)
        }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            Task { @MainActor in self.lastHTTPStatusCode = httpResponse.statusCode }
        }
        decisionHandler(.allow)
    }
}
