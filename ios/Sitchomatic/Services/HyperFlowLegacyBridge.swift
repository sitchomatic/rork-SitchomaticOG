// HyperFlowLegacyBridge.swift
// Sitchomatic
//
// Compatibility bridge: provides the old class interfaces (LoginSiteWebSession,
// LoginWebSession, BPointWebSession, WebViewTracker, DeadSessionDetector,
// SessionActivityMonitor) backed by the new HyperFlow engine architecture.
//
// Each session now uses an ISOLATED WKProcessPool and nonPersistent
// WKWebsiteDataStore per instance, with WeakTrampolineProxy for message
// handlers — matching the AutomationPairSession isolation model.

import Foundation
import WebKit
import UIKit
import Vision

// NOTE: LoginTargetSite enum is defined in HyperFlowPairedTasks.swift

/// Shared constants for the legacy bridge layer.
private enum BridgeConstants {
    static let maxPageContentLength = 3000
    static let heartbeatTimeoutSeconds: TimeInterval = 15
}

// MARK: - 1. LoginSiteWebSession (HyperFlow-Backed)

/// Drop-in replacement for the legacy LoginSiteWebSession.
/// Creates an isolated WKProcessPool + nonPersistent WKWebsiteDataStore per
/// instance so that concurrent sessions never share cookies or storage.
@MainActor
class LoginSiteWebSession: NSObject {

    // MARK: Public Properties

    private(set) var webView: WKWebView?
    var stealthEnabled: Bool = false
    var lastNavigationError: String?
    var lastHTTPStatusCode: Int?
    var targetURL: URL
    var networkConfig: ActiveNetworkConfig = .direct
    var proxyTarget: ProxyRotationService.ProxyTarget = .joe
    private(set) var stealthProfile: PPSRStealthService.SessionProfile?
    private(set) var lastFingerprintScore: FingerprintValidationService.FingerprintScore?
    private(set) var activeProfileIndex: Int?
    var onFingerprintLog: ((String, PPSRLogEntry.Level) -> Void)?
    private(set) var navigationCount: Int = 0
    private(set) var processTerminated: Bool = false
    var onProcessTerminated: (() -> Void)?
    var monitoringSessionId: String?
    var fingerprintValidationEnabled: Bool = false

    // MARK: Private / Isolation State

    private let sessionId: UUID = UUID()
    private var trackerSessionId: String {
        sessionId.uuidString.prefix(8).lowercased() + "-" + (targetURL.host ?? "unknown")
    }

    /// Per-instance isolated process pool (HyperFlow architecture).
    private let isolatedProcessPool = WKProcessPool()
    /// Per-instance isolated data store (HyperFlow architecture).
    private let isolatedDataStore = WKWebsiteDataStore.nonPersistent()

    private var pageLoadContinuation: CheckedContinuation<Bool, Never>?
    private var isPageLoaded: Bool = false
    private var loadTimeoutTask: Task<Void, Never>?
    private var isProtectedRouteBlocked: Bool = false
    private let logger = DebugLogger.shared

    // MARK: Init

    init(targetURL: URL,
         networkConfig: ActiveNetworkConfig = .direct,
         proxyTarget: ProxyRotationService.ProxyTarget? = nil) {
        self.targetURL = targetURL
        self.networkConfig = networkConfig
        self.proxyTarget = proxyTarget ?? Self.inferProxyTarget(for: targetURL)
        super.init()
    }

    private static func inferProxyTarget(for targetURL: URL) -> ProxyRotationService.ProxyTarget {
        let host = targetURL.host?.lowercased() ?? ""
        if host.contains("ppsr") { return .ppsr }
        if host.contains("ignition") { return .ignition }
        return .joe
    }

    // MARK: Lifecycle

    func setUp(wipeAll: Bool = false) async {
        if wipeAll {
            await cleanIsolatedDataStore()
            HTTPCookieStorage.shared.removeCookies(since: .distantPast)
            URLCache.shared.removeAllCachedResponses()
        }

        if webView != nil {
            tearDown(wipeAll: false)
        }

        processTerminated = false

        let config = WKWebViewConfiguration()
        config.processPool = isolatedProcessPool
        config.websiteDataStore = isolatedDataStore
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let contentController = WKUserContentController()
        let proxy = WeakTrampolineProxy(target: self)
        contentController.add(proxy, name: "hyperflowBridge")
        config.userContentController = contentController

        let proxyApplied = NetworkSessionFactory.shared.configureWKWebView(
            config: config, networkConfig: networkConfig, target: proxyTarget
        )
        isProtectedRouteBlocked = networkConfig.requiresProtectedRoute && !proxyApplied
        if isProtectedRouteBlocked {
            lastNavigationError = "Protected route blocked — no proxy path available for \(proxyTarget.rawValue)"
            logger.log("LoginSiteWebSession[HF]: BLOCKED — no proxy available for \(proxyTarget.rawValue)",
                       category: .network, level: .error)
        }

        if stealthEnabled {
            let stealth = PPSRStealthService.shared
            let host = targetURL.host ?? ""
            let (profile, profileIdx) = await stealth.nextProfileForHost(host)
            self.stealthProfile = profile
            self.activeProfileIndex = profileIdx

            let userScript = stealth.createStealthUserScript(profile: profile)
            config.userContentController.addUserScript(userScript)

            let wv = WKWebView(
                frame: CGRect(x: 0, y: 0,
                              width: profile.viewport.width,
                              height: profile.viewport.height),
                configuration: config)
            wv.navigationDelegate = self
            wv.customUserAgent = profile.userAgent
            self.webView = wv
        } else {
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                               configuration: config)
            wv.navigationDelegate = self
            wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
            self.webView = wv
        }

        // Register with both the legacy tracker and the HyperFlow pool.
        WebViewTracker.shared.incrementActive(sessionId: trackerSessionId)
        if let wv = webView {
            WebViewPool.shared.mount(wv, for: sessionId)
        }

        logger.log("LoginSiteWebSession[HF]: setUp (network=\(networkConfig.label), target=\(proxyTarget.rawValue), isolated=true)",
                   category: .webView, level: .debug)
    }

    func tearDown(wipeAll: Bool = false) {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil

        if let wv = webView {
            wv.stopLoading()
            if wipeAll {
                wv.configuration.websiteDataStore.removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                    modifiedSince: .distantPast) { }
                wv.configuration.userContentController.removeAllUserScripts()
                wv.configuration.userContentController.removeScriptMessageHandler(forName: "hyperflowBridge")
            }
            wv.navigationDelegate = nil
        }

        if webView != nil {
            WebViewTracker.shared.decrementActive(sessionId: trackerSessionId)
            WebViewPool.shared.unmount(id: sessionId)
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

    // MARK: Navigation

    func loadPage(timeout: TimeInterval = 60) async -> Bool {
        guard let webView else {
            lastNavigationError = "WebView not initialized"
            return false
        }
        guard !isProtectedRouteBlocked else { return false }

        isPageLoaded = false
        lastNavigationError = nil
        lastHTTPStatusCode = nil

        if let existingCont = pageLoadContinuation {
            pageLoadContinuation = nil
            existingCont.resume(returning: false)
        }

        let request = URLRequest(url: targetURL,
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: timeout)
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
            await injectFingerprint()
            try? await Task.sleep(for: .milliseconds(1500))
            await waitForDOMReady(timeout: 10)
            let _ = await validateFingerprint()
        }

        return loaded
    }

    // MARK: JavaScript Execution

    func evaluateJS(_ js: String) async -> Any? {
        guard let webView else { return nil }
        do {
            let result = try await webView.evaluateJavaScript(js)
            if let sid = monitoringSessionId {
                SessionActivityMonitor.shared.recordJSResponse(sessionId: sid)
            }
            return result
        } catch {
            return nil
        }
    }

    func executeJS(_ js: String) async -> String? {
        guard let webView else { return nil }
        do {
            let result = try await webView.evaluateJavaScript(js)
            if let sid = monitoringSessionId {
                SessionActivityMonitor.shared.recordJSResponse(sessionId: sid)
            }
            if let str = result as? String { return str }
            if let num = result as? NSNumber { return "\(num)" }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: Page Content & Screenshots

    func getPageContent() async -> String? {
        await executeJS("document.body ? document.body.innerText.substring(0, \(BridgeConstants.maxPageContentLength)) : ''")
    }

    func captureScreenshot() async -> UIImage? {
        guard let webView else { return nil }
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }
        return await RenderStableScreenshotService.shared.captureStableScreenshot(from: webView)
    }

    // MARK: Form Filling

    func fillEmailField(value: String) async -> Bool {
        let result = await fillUsername(value)
        return result.success
    }

    func fillPasswordField(value: String) async -> Bool {
        let result = await fillPassword(value)
        return result.success
    }

    func clickLoginButton() async -> Bool {
        let result = await clickLoginButtonInternal()
        return result.success
    }

    // MARK: Internal Form Helpers

    private let findFieldJS = """
    function findField(strategies) {
        for (var i = 0; i < strategies.length; i++) {
            var s = strategies[i];
            var el = null;
            try {
                if (s.type === 'id') { el = document.getElementById(s.value); }
                else if (s.type === 'name') { var els = document.getElementsByName(s.value); if (els.length > 0) el = els[0]; }
                else if (s.type === 'placeholder') { el = document.querySelector('input[placeholder*="' + s.value + '"]'); }
                else if (s.type === 'label') {
                    var labels = document.querySelectorAll('label');
                    for (var j = 0; j < labels.length; j++) {
                        var txt = (labels[j].textContent || '').trim().toLowerCase();
                        if (txt.indexOf(s.value.toLowerCase()) !== -1) {
                            var forId = labels[j].getAttribute('for');
                            if (forId) { el = document.getElementById(forId); } else { el = labels[j].querySelector('input'); }
                            if (el) break;
                        }
                    }
                }
                else if (s.type === 'css') { el = document.querySelector(s.value); }
                else if (s.type === 'ariaLabel') { el = document.querySelector('[aria-label*="' + s.value + '"]'); }
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
            var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (ns && ns.set) { ns.set.call(el, ''); } else { el.value = ''; }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            if (ns && ns.set) { ns.set.call(el, '\(escaped)'); } else { el.value = '\(escaped)'; }
            el.dispatchEvent(new Event('focus', {bubbles: true}));
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            el.dispatchEvent(new Event('blur', {bubbles: true}));
            return el.value === '\(escaped)' ? 'OK' : 'VALUE_MISMATCH';
        })();
        """
    }

    private func classifyFillResult(_ result: String?, fieldName: String) -> (success: Bool, detail: String) {
        switch result {
        case "OK":           return (true, "\(fieldName) filled successfully")
        case "VALUE_MISMATCH": return (true, "\(fieldName) filled but value verification mismatch")
        case "NOT_FOUND":    return (false, "\(fieldName) selector NOT_FOUND")
        case nil:            return (false, "\(fieldName) JS execution returned nil")
        default:             return (false, "\(fieldName) unexpected result: '\(result ?? "")'")
        }
    }

    func fillUsername(_ username: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"email"},{"type":"id","value":"username"},{"type":"id","value":"loginEmail"},
            {"type":"name","value":"email"},{"type":"name","value":"username"},
            {"type":"placeholder","value":"Email"},{"type":"placeholder","value":"email"},{"type":"placeholder","value":"Username"},
            {"type":"label","value":"email"},{"type":"label","value":"username"},
            {"type":"css","value":"input[type='email']"},{"type":"css","value":"input[type='text']:first-of-type"},
            {"type":"ariaLabel","value":"email"},{"type":"ariaLabel","value":"username"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: username))
        return classifyFillResult(result, fieldName: "Username/Email")
    }

    func fillPassword(_ password: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"password"},{"type":"id","value":"loginPassword"},
            {"type":"name","value":"password"},
            {"type":"placeholder","value":"Password"},{"type":"placeholder","value":"password"},
            {"type":"label","value":"password"},
            {"type":"css","value":"input[type='password']"},
            {"type":"ariaLabel","value":"password"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: password))
        return classifyFillResult(result, fieldName: "Password")
    }

    private func clickLoginButtonInternal() async -> (success: Bool, detail: String) {
        let js = """
        (function() {
            var selectors = [
                'button[type="submit"]', 'input[type="submit"]',
                'button.login-button', '#loginButton', '#login-btn',
                'button:not([type])', 'a.login'
            ];
            for (var i = 0; i < selectors.length; i++) {
                var el = document.querySelector(selectors[i]);
                if (el && !el.disabled) {
                    el.click();
                    return 'CLICKED';
                }
            }
            return 'NOT_FOUND';
        })();
        """
        let result = await executeJS(js)
        if result == "CLICKED" {
            return (true, "Login button clicked")
        }
        return (false, "Login button not found")
    }

    // MARK: Fingerprint

    func injectFingerprint() async {
        guard stealthEnabled, stealthProfile != nil else { return }
        let js = PPSRStealthService.shared.fingerprintJS()
        _ = await executeJS(js)
    }

    func validateFingerprint(maxRetries: Int = 2) async -> Bool {
        guard fingerprintValidationEnabled, stealthEnabled,
              let wv = webView, let profile = stealthProfile else { return true }

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
                let newProfile = await stealth.nextProfile()
                self.stealthProfile = newProfile
                webView?.customUserAgent = newProfile.userAgent
                let newJS = stealth.createStealthUserScript(profile: newProfile)
                webView?.configuration.userContentController.removeAllUserScripts()
                webView?.configuration.userContentController.addUserScript(newJS)
                _ = await executeJS(PPSRStealthService.shared.buildComprehensiveStealthJSPublic(profile: newProfile))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        onFingerprintLog?("FP validation failed after \(maxRetries) profile rotations — proceeding with caution", .error)
        return false
    }

    // MARK: Page Inspection

    func getCurrentURL() async -> String {
        await executeJS("window.location.href") ?? ""
    }

    func getPageTitle() async -> String {
        await executeJS("document.title") ?? ""
    }

    func dismissCookieNotices() async {
        let js = """
        (function() {
            var terms = ['accept','agree','got it','i understand','ok','close','dismiss','allow all','accept all','consent'];
            var btns = document.querySelectorAll('button, a, [role="button"], input[type="button"], input[type="submit"]');
            for (var i = 0; i < btns.length; i++) {
                var txt = (btns[i].textContent || btns[i].value || '').replace(/[\\s]+/g,' ').toLowerCase().trim();
                if (txt.length > 60) continue;
                for (var t = 0; t < terms.length; t++) {
                    if (txt.indexOf(terms[t]) !== -1) { btns[i].click(); return 'DISMISSED'; }
                }
            }
            var overlays = document.querySelectorAll('[class*="cookie"], [class*="consent"], [class*="gdpr"], [id*="cookie"], [id*="consent"], [id*="gdpr"]');
            for (var j = 0; j < overlays.length; j++) {
                var closeBtn = overlays[j].querySelector('button, [role="button"], .close');
                if (closeBtn) { closeBtn.click(); return 'DISMISSED_OVERLAY'; }
            }
            return 'NONE_FOUND';
        })();
        """
        _ = await executeJS(js)
    }

    func fillForgotPasswordEmail(_ email: String) async -> (success: Bool, detail: String) {
        let escaped = email.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
            var selectors = ['input[type="email"]', 'input[name*="email" i]', 'input[id*="email" i]', 'input[placeholder*="email" i]', 'input[type="text"]'];
            for (var i = 0; i < selectors.length; i++) {
                var el = document.querySelector(selectors[i]);
                if (el) {
                    el.focus();
                    var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                    if (ns && ns.set) { ns.set.call(el, '\(escaped)'); } else { el.value = '\(escaped)'; }
                    el.dispatchEvent(new Event('input', {bubbles: true}));
                    el.dispatchEvent(new Event('change', {bubbles: true}));
                    el.dispatchEvent(new Event('blur', {bubbles: true}));
                    return 'OK';
                }
            }
            return 'NO_FIELD';
        })()
        """
        let result = await executeJS(js)
        if result == "OK" {
            return (success: true, detail: "Email filled")
        }
        return (success: false, detail: result ?? "No email field found")
    }

    func clickForgotPasswordSubmit() async -> (success: Bool, detail: String) {
        let js = """
        (function() {
            var selectors = ['button[type="submit"]', 'input[type="submit"]', 'button.submit', '#submit'];
            var terms = ['submit', 'send', 'reset', 'continue', 'next'];
            for (var i = 0; i < selectors.length; i++) {
                var el = document.querySelector(selectors[i]);
                if (el) { el.click(); return 'CLICKED:' + (el.tagName || 'unknown'); }
            }
            var allBtns = document.querySelectorAll('button, [role="button"], a.button');
            for (var j = 0; j < allBtns.length; j++) {
                var txt = (allBtns[j].textContent || '').toLowerCase().trim();
                for (var t = 0; t < terms.length; t++) {
                    if (txt.indexOf(terms[t]) !== -1) {
                        allBtns[j].click();
                        return 'CLICKED:' + txt;
                    }
                }
            }
            return 'NO_BUTTON';
        })()
        """
        let result = await executeJS(js)
        if let result, result.hasPrefix("CLICKED:") {
            return (success: true, detail: result)
        }
        return (success: false, detail: result ?? "No submit button found")
    }

    func verifyLoginFieldsExist() async -> (found: Int, missing: [String]) {
        let js = """
        (function() {
            var missing = [];
            var found = 0;
            var emailSelectors = ['input[type="email"]','input[name="email"]','input[name="username"]','#email','#username','#loginEmail','input[autocomplete="email"]','input[autocomplete="username"]'];
            var passSelectors = ['input[type="password"]','input[name="password"]','#password','#loginPassword','input[autocomplete="current-password"]'];
            var emailFound = false;
            for (var i = 0; i < emailSelectors.length; i++) {
                if (document.querySelector(emailSelectors[i])) { emailFound = true; break; }
            }
            if (emailFound) { found++; } else { missing.push('email/username'); }
            var passFound = false;
            for (var j = 0; j < passSelectors.length; j++) {
                if (document.querySelector(passSelectors[j])) { passFound = true; break; }
            }
            if (passFound) { found++; } else { missing.push('password'); }
            return JSON.stringify({found: found, missing: missing});
        })();
        """
        guard let raw = await executeJS(js),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (found: 0, missing: ["email/username", "password"])
        }
        let found = json["found"] as? Int ?? 0
        let missing = json["missing"] as? [String] ?? []
        return (found: found, missing: missing)
    }

    func waitForFullPageReadiness(host: String, sessionId: String, maxTimeoutMs: Int) async -> (ready: Bool, durationMs: Int, reason: String, jsSettled: Bool, formReady: Bool, buttonReady: Bool) {
        let settlement = SmartPageSettlementService.shared
        let result = await settlement.waitForSettlement(
            executeJS: { [weak self] js in await self?.executeJS(js) },
            host: host,
            sessionId: sessionId,
            maxTimeoutMs: maxTimeoutMs
        )
        return (
            ready: result.settled,
            durationMs: result.durationMs,
            reason: result.reason,
            jsSettled: result.signals.readyStateComplete && result.signals.domStable,
            formReady: result.signals.loginFormReady,
            buttonReady: result.signals.loginFormReady
        )
    }

    func autoCalibrate() async -> LoginCalibrationService.URLCalibration? {
        let js = """
        (function() {
            var emailSelectors = ['input[type="email"]','input[name="email"]','input[name="username"]','#email','#username','#loginEmail','input[autocomplete="email"]','input[autocomplete="username"]','input[type="text"]:first-of-type'];
            var passSelectors = ['input[type="password"]','input[name="password"]','#password','#loginPassword','input[autocomplete="current-password"]'];
            var btnSelectors = ['button[type="submit"]','input[type="submit"]','#login-submit','#loginButton','button.login-button'];
            var loginTerms = ['log in','login','sign in','signin','submit'];
            function bestSelector(el) {
                if (el.id) return '#' + el.id;
                if (el.name) return el.tagName.toLowerCase() + '[name="' + el.name + '"]';
                if (el.type) return el.tagName.toLowerCase() + '[type="' + el.type + '"]';
                return el.tagName.toLowerCase();
            }
            var emailEl = null; var emailCSS = null;
            for (var i = 0; i < emailSelectors.length; i++) {
                var e = document.querySelector(emailSelectors[i]);
                if (e && !e.disabled) { emailEl = e; emailCSS = emailSelectors[i]; break; }
            }
            var passEl = null; var passCSS = null;
            for (var j = 0; j < passSelectors.length; j++) {
                var p = document.querySelector(passSelectors[j]);
                if (p && !p.disabled) { passEl = p; passCSS = passSelectors[j]; break; }
            }
            var btnEl = null; var btnCSS = null;
            for (var k = 0; k < btnSelectors.length; k++) {
                var b = document.querySelector(btnSelectors[k]);
                if (b && !b.disabled) { btnEl = b; btnCSS = btnSelectors[k]; break; }
            }
            if (!btnEl) {
                var allBtns = document.querySelectorAll('button, input[type="submit"], [role="button"]');
                for (var m = 0; m < allBtns.length; m++) {
                    var txt = (allBtns[m].textContent || allBtns[m].value || '').replace(/[\\s]+/g,' ').toLowerCase().trim();
                    if (txt.length > 50) continue;
                    for (var t = 0; t < loginTerms.length; t++) {
                        if (txt.indexOf(loginTerms[t]) !== -1) { btnEl = allBtns[m]; btnCSS = bestSelector(allBtns[m]); break; }
                    }
                    if (btnEl) break;
                }
            }
            return JSON.stringify({
                emailCSS: emailCSS, emailTag: emailEl ? emailEl.tagName : null,
                emailType: emailEl ? (emailEl.type||'') : null, emailPlaceholder: emailEl ? (emailEl.placeholder||'') : null,
                passCSS: passCSS, passTag: passEl ? passEl.tagName : null,
                btnCSS: btnCSS, btnTag: btnEl ? btnEl.tagName : null, btnText: btnEl ? (btnEl.textContent||btnEl.value||'').trim() : null
            });
        })();
        """
        guard let raw = await executeJS(js),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let emailCSS = json["emailCSS"] as? String
        let passCSS = json["passCSS"] as? String
        let btnCSS = json["btnCSS"] as? String
        guard emailCSS != nil || passCSS != nil || btnCSS != nil else { return nil }

        let emailMapping: LoginCalibrationService.ElementMapping? = emailCSS.map {
            LoginCalibrationService.ElementMapping(
                cssSelector: $0,
                tagName: json["emailTag"] as? String,
                inputType: json["emailType"] as? String,
                placeholder: json["emailPlaceholder"] as? String
            )
        }
        let passMapping: LoginCalibrationService.ElementMapping? = passCSS.map {
            LoginCalibrationService.ElementMapping(cssSelector: $0, tagName: json["passTag"] as? String, inputType: "password")
        }
        let btnMapping: LoginCalibrationService.ElementMapping? = btnCSS.map {
            LoginCalibrationService.ElementMapping(cssSelector: $0, tagName: json["btnTag"] as? String, nearbyText: json["btnText"] as? String)
        }
        return LoginCalibrationService.URLCalibration(
            urlPattern: targetURL.absoluteString,
            emailField: emailMapping,
            passwordField: passMapping,
            loginButton: btnMapping
        )
    }

    func executeHumanPattern(
        _ pattern: LoginFormPattern,
        username: String,
        password: String,
        sessionId: String
    ) async -> (overallSuccess: Bool, usernameFilled: Bool, passwordFilled: Bool, submitTriggered: Bool, summary: String) {
        let engine = HumanInteractionEngine.shared
        let result = await engine.executePattern(
            pattern,
            username: username,
            password: password,
            executeJS: { [weak self] js in await self?.executeJS(js) },
            sessionId: sessionId,
            targetURL: targetURL.absoluteString
        )
        return (
            overallSuccess: result.overallSuccess,
            usernameFilled: result.usernameFilled,
            passwordFilled: result.passwordFilled,
            submitTriggered: result.submitTriggered,
            summary: result.summary
        )
    }

    func getFieldValues() async -> (email: String, password: String) {
        let js = """
        (function() {
            var emailSelectors = ['input[type="email"]','input[name="email"]','input[name="username"]','#email','#username','#loginEmail','input[autocomplete="email"]','input[autocomplete="username"]','input[type="text"]:first-of-type'];
            var passSelectors = ['input[type="password"]','input[name="password"]','#password','#loginPassword','input[autocomplete="current-password"]'];
            var emailVal = '';
            for (var i = 0; i < emailSelectors.length; i++) {
                var e = document.querySelector(emailSelectors[i]);
                if (e && e.value) { emailVal = e.value; break; }
            }
            var passVal = '';
            for (var j = 0; j < passSelectors.length; j++) {
                var p = document.querySelector(passSelectors[j]);
                if (p && p.value) { passVal = p.value; break; }
            }
            return JSON.stringify({email: emailVal, password: passVal});
        })();
        """
        guard let raw = await executeJS(js),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (email: "", password: "")
        }
        return (email: json["email"] as? String ?? "", password: json["password"] as? String ?? "")
    }

    func clearAllInputFields() async {
        let js = """
        (function() {
            var inputs = document.querySelectorAll('input[type="text"], input[type="email"], input[type="password"], input[type="tel"], input[type="search"], input:not([type])');
            var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            for (var i = 0; i < inputs.length; i++) {
                inputs[i].focus();
                if (ns && ns.set) { ns.set.call(inputs[i], ''); } else { inputs[i].value = ''; }
                inputs[i].dispatchEvent(new Event('input', {bubbles: true}));
                inputs[i].dispatchEvent(new Event('change', {bubbles: true}));
            }
            return 'CLEARED';
        })();
        """
        _ = await executeJS(js)
    }

    func fillUsernameCalibrated(_ username: String, calibration: LoginCalibrationService.URLCalibration?) async -> (success: Bool, detail: String) {
        if let selector = calibration?.emailField?.cssSelector, !selector.isEmpty {
            let escaped = username.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            let js = """
            (function() {
                var el = document.querySelector('\(selector)');
                if (!el) return 'NOT_FOUND';
                el.focus();
                var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                if (ns && ns.set) { ns.set.call(el, ''); } else { el.value = ''; }
                el.dispatchEvent(new Event('input', {bubbles: true}));
                if (ns && ns.set) { ns.set.call(el, '\(escaped)'); } else { el.value = '\(escaped)'; }
                el.dispatchEvent(new Event('focus', {bubbles: true}));
                el.dispatchEvent(new Event('input', {bubbles: true}));
                el.dispatchEvent(new Event('change', {bubbles: true}));
                el.dispatchEvent(new Event('blur', {bubbles: true}));
                return el.value === '\(escaped)' ? 'OK' : 'VALUE_MISMATCH';
            })();
            """
            let result = await executeJS(js)
            return classifyFillResult(result, fieldName: "Username(calibrated:\(selector))")
        }
        return await fillUsername(username)
    }

    func fillPasswordCalibrated(_ password: String, calibration: LoginCalibrationService.URLCalibration?) async -> (success: Bool, detail: String) {
        if let selector = calibration?.passwordField?.cssSelector, !selector.isEmpty {
            let escaped = password.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            let js = """
            (function() {
                var el = document.querySelector('\(selector)');
                if (!el) return 'NOT_FOUND';
                el.focus();
                var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                if (ns && ns.set) { ns.set.call(el, ''); } else { el.value = ''; }
                el.dispatchEvent(new Event('input', {bubbles: true}));
                if (ns && ns.set) { ns.set.call(el, '\(escaped)'); } else { el.value = '\(escaped)'; }
                el.dispatchEvent(new Event('focus', {bubbles: true}));
                el.dispatchEvent(new Event('input', {bubbles: true}));
                el.dispatchEvent(new Event('change', {bubbles: true}));
                el.dispatchEvent(new Event('blur', {bubbles: true}));
                return el.value === '\(escaped)' ? 'OK' : 'VALUE_MISMATCH';
            })();
            """
            let result = await executeJS(js)
            return classifyFillResult(result, fieldName: "Password(calibrated:\(selector))")
        }
        return await fillPassword(password)
    }

    func captureButtonFingerprint(sessionId: String) async -> SmartButtonRecoveryService.ButtonFingerprint? {
        await SmartButtonRecoveryService.shared.captureFingerprint(
            executeJS: { [weak self] js in await self?.executeJS(js) },
            sessionId: sessionId
        )
    }

    func clickLoginButtonCalibrated(calibration: LoginCalibrationService.URLCalibration?) async -> (success: Bool, detail: String) {
        if let selector = calibration?.loginButton?.cssSelector, !selector.isEmpty {
            let js = """
            (function() {
                var el = document.querySelector('\(selector)');
                if (el && !el.disabled) { el.click(); return 'CLICKED_CALIBRATED'; }
                return 'NOT_FOUND';
            })();
            """
            let result = await executeJS(js)
            if result == "CLICKED_CALIBRATED" {
                return (true, "Login button clicked via calibrated selector '\(selector)'")
            }
        }
        return await clickLoginButtonInternal()
    }

    func ocrClickLoginButton() async -> (success: Bool, detail: String) {
        guard let screenshot = await captureScreenshot(),
              let cgImage = screenshot.cgImage else {
            return (false, "OCR: could not capture screenshot")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return (false, "OCR: Vision request failed — \(error.localizedDescription)")
        }
        guard let observations = request.results else {
            return (false, "OCR: no text observations")
        }
        let loginTerms = ["log in", "login", "sign in", "signin", "submit"]
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let text = candidate.string.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            for term in loginTerms {
                if text.contains(term) {
                    let box = obs.boundingBox
                    let centerX = box.origin.x + box.width / 2
                    let centerY = 1.0 - (box.origin.y + box.height / 2)
                    let viewSize = webView?.frame.size ?? CGSize(width: 390, height: 844)
                    let tapX = centerX * viewSize.width
                    let tapY = centerY * viewSize.height
                    let tapJS = """
                    (function() {
                        var el = document.elementFromPoint(\(tapX), \(tapY));
                        if (el) { el.click(); return 'OCR_CLICKED:' + (el.textContent||'').trim().substring(0,30); }
                        return 'OCR_NO_ELEMENT';
                    })();
                    """
                    let tapResult = await executeJS(tapJS)
                    if let tapResult, tapResult.hasPrefix("OCR_CLICKED") {
                        return (true, "OCR clicked '\(text)' at (\(Int(tapX)),\(Int(tapY))): \(tapResult)")
                    }
                }
            }
        }
        return (false, "OCR: no login button text found in \(observations.count) observations")
    }

    func rapidWelcomePoll(timeout: TimeInterval, originalURL: String) async -> (welcomeTextFound: Bool, redirectedToHomepage: Bool, navigationDetected: Bool, errorBannerDetected: Bool, smsNotificationDetected: Bool, finalPageContent: String, finalURL: String) {
        let start = Date()
        var welcomeTextFound = false
        var redirectedToHomepage = false
        var navigationDetected = false
        var errorBannerDetected = false
        var smsNotificationDetected = false
        var finalPageContent = ""
        var finalURL = ""

        let pollJS = """
        (function() {
            var body = (document.body ? document.body.innerText : '').substring(0, 3000).toLowerCase();
            var url = window.location.href;
            var welcomeTerms = ['welcome','dashboard','my account','home','logged in','success','hello'];
            var errorTerms = ['invalid','incorrect','wrong password','failed','error','try again','denied','expired'];
            var smsTerms = ['verification code','sms','two-factor','2fa','mfa','one-time','otp','authenticator'];
            var hasWelcome = false;
            for (var i = 0; i < welcomeTerms.length; i++) { if (body.indexOf(welcomeTerms[i]) !== -1) { hasWelcome = true; break; } }
            var hasError = false;
            for (var j = 0; j < errorTerms.length; j++) { if (body.indexOf(errorTerms[j]) !== -1) { hasError = true; break; } }
            var hasSMS = false;
            for (var k = 0; k < smsTerms.length; k++) { if (body.indexOf(smsTerms[k]) !== -1) { hasSMS = true; break; } }
            return JSON.stringify({welcome: hasWelcome, error: hasError, sms: hasSMS, url: url, content: body.substring(0, 1500)});
        })();
        """

        while Date().timeIntervalSince(start) < timeout {
            guard let raw = await executeJS(pollJS),
                  let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            let currentURL = json["url"] as? String ?? ""
            finalURL = currentURL
            finalPageContent = json["content"] as? String ?? ""
            welcomeTextFound = json["welcome"] as? Bool ?? false
            errorBannerDetected = json["error"] as? Bool ?? false
            smsNotificationDetected = json["sms"] as? Bool ?? false
            navigationDetected = !currentURL.isEmpty && currentURL != originalURL
            if let origHost = URL(string: originalURL)?.host,
               let curHost = URL(string: currentURL)?.host,
               curHost == origHost {
                let origPath = URL(string: originalURL)?.path ?? ""
                let curPath = URL(string: currentURL)?.path ?? ""
                redirectedToHomepage = curPath != origPath && (curPath == "/" || curPath.contains("home") || curPath.contains("dashboard") || curPath.contains("account"))
            }
            if welcomeTextFound || redirectedToHomepage || navigationDetected || errorBannerDetected || smsNotificationDetected {
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return (welcomeTextFound: welcomeTextFound, redirectedToHomepage: redirectedToHomepage, navigationDetected: navigationDetected, errorBannerDetected: errorBannerDetected, smsNotificationDetected: smsNotificationDetected, finalPageContent: finalPageContent, finalURL: finalURL)
    }

    func captureScreenshotFast() async -> UIImage? {
        guard let webView, webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: Int(webView.bounds.width))
        return try? await webView.takeSnapshot(configuration: config)
    }

    func injectSettlementMonitor() async {
        await SmartPageSettlementService.shared.injectMonitor(
            executeJS: { [weak self] js in await self?.executeJS(js) }
        )
    }

    func waitForButtonReadyForNextAttempt(
        originalFingerprint: SmartButtonRecoveryService.ButtonFingerprint?,
        host: String,
        sessionId: String,
        maxTimeoutMs: Int
    ) async -> (ready: Bool, durationMs: Int, reason: String, recoveredFromFingerprint: Bool) {
        if let fingerprint = originalFingerprint {
            let result = await SmartButtonRecoveryService.shared.waitForRecovery(
                originalFingerprint: fingerprint,
                executeJS: { [weak self] js in await self?.executeJS(js) },
                host: host,
                sessionId: sessionId,
                maxTimeoutMs: maxTimeoutMs
            )
            return (ready: result.recovered, durationMs: result.durationMs, reason: result.reason, recoveredFromFingerprint: true)
        }
        let start = Date()
        let timeoutSec = Double(maxTimeoutMs) / 1000.0
        while Date().timeIntervalSince(start) < timeoutSec {
            let isReady = await checkLoginButtonReadiness()
            if isReady {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                return (ready: true, durationMs: ms, reason: "Button clickable (no fingerprint)", recoveredFromFingerprint: false)
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        return (ready: false, durationMs: ms, reason: "Timeout waiting for button readiness", recoveredFromFingerprint: false)
    }

    func checkLoginButtonReadiness() async -> Bool {
        let js = """
        (function() {
            var  = ['button[type="submit"]','input[type="submit"]','#login-submit','#loginButton','button.login-button'];
            var loginTerms = ['log in','login','sign in','signin','submit'];
            var btn = null;
            for (var i = 0; i < selectors.length; i++) {
                var el = document.querySelector(selectors[i]);
                if (el) { btn = el; break; }
            }
            if (!btn) {
                var allBtns = document.querySelectorAll('button, [role="button"]');
                for (var j = 0; j < allBtns.length; j++) {
                    var txt = (allBtns[j].textContent||allBtns[j].value||'').replace(/[\\s]+/g,' ').toLowerCase().trim();
                    for (var t = 0; t < loginTerms.length; t++) {
                        if (txt.indexOf(loginTerms[t]) !== -1) { btn = allBtns[j]; break; }
                    }
                    if (btn) break;
                }
            }
            if (!btn) return 'NO_BUTTON';
            var style = window.getComputedStyle(btn);
            if (btn.disabled) return 'DISABLED';
            if (style.pointerEvents === 'none') return 'POINTER_NONE';
            if (parseFloat(style.opacity) < 0.5) return 'LOW_OPACITY';
            return 'READY';
        })();
        """
        let result = await executeJS(js)
        return result == "READY"
    }

    // MARK: Utilities

    func getViewportSize() -> CGSize {
        webView?.frame.size ?? CGSize(width: 390, height: 844)
    }

    private func waitForDOMReady(timeout: TimeInterval) async {
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

    private func cleanIsolatedDataStore() async {
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            isolatedDataStore.removeData(ofTypes: allTypes, modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
    }

    func clearPasswordFieldOnly() async {
        let js = """
        (function() {
            var el = document.querySelector('input[type="password"]');
            if (!el) return 'NOT_FOUND';
            var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (ns && ns.set) { ns.set.call(el, ''); } else { el.value = ''; }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            return 'CLEARED';
        })();
        """
        _ = await executeJS(js)
    }

    func clearEmailFieldOnly() async {
        let js = """
        (function() {
            var selectors = ['input[type="email"]','input[type="text"]','input[name*="email" i]','input[name*="user" i]','input[id*="email" i]','input[id*="user" i]'];
            var el = null;
            for (var i = 0; i < selectors.length; i++) { el = document.querySelector(selectors[i]); if (el) break; }
            if (!el) return 'NOT_FOUND';
            var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (ns && ns.set) { ns.set.call(el, ''); } else { el.value = ''; }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            return 'CLEARED';
        })();
        """
        _ = await executeJS(js)
    }

    func trueDetectionFillPassword(_ password: String) async -> (success: Bool, detail: String) {
        let escaped = password.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
            var el = document.querySelector('input[type="password"]');
            if (!el) return 'NOT_FOUND';
            el.focus();
            var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (ns && ns.set) { ns.set.call(el, '\(escaped)'); } else { el.value = '\(escaped)'; }
            el.dispatchEvent(new Event('focus', {bubbles: true}));
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            el.dispatchEvent(new Event('blur', {bubbles: true}));
            return el.value === '\(escaped)' ? 'OK' : 'VALUE_MISMATCH';
        })();
        """
        let result = await executeJS(js)
        return classifyFillResult(result, fieldName: "Password(trueDetection)")
    }

    func trueDetectionFillEmail(_ email: String) async -> (success: Bool, detail: String) {
        let escaped = email.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
            var selectors = ['input[type="email"]','input[type="text"]','input[name*="email" i]','input[name*="user" i]','input[id*="email" i]','input[id*="user" i]'];
            var el = null;
            for (var i = 0; i < selectors.length; i++) { el = document.querySelector(selectors[i]); if (el) break; }
            if (!el) return 'NOT_FOUND';
            el.focus();
            var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (ns && ns.set) { ns.set.call(el, '\(escaped)'); } else { el.value = '\(escaped)'; }
            el.dispatchEvent(new Event('focus', {bubbles: true}));
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            el.dispatchEvent(new Event('blur', {bubbles: true}));
            return el.value === '\(escaped)' ? 'OK' : 'VALUE_MISMATCH';
        })();
        """
        let result = await executeJS(js)
        return classifyFillResult(result, fieldName: "Email(trueDetection)")
    }

    func trueDetectionTripleClickSubmit() async -> (success: Bool, detail: String) {
        let js = """
        (function() {
            var selectors = ['button[type="submit"]','input[type="submit"]','#login-submit','#loginButton','button.login-button'];
            var loginTerms = ['log in','login','sign in','signin','submit'];
            var btn = null;
            for (var i = 0; i < selectors.length; i++) { var el = document.querySelector(selectors[i]); if (el) { btn = el; break; } }
            if (!btn) {
                var allBtns = document.querySelectorAll('button, [role="button"]');
                for (var j = 0; j < allBtns.length; j++) {
                    var txt = (allBtns[j].textContent||allBtns[j].value||'').replace(/[\\s]+/g,' ').toLowerCase().trim();
                    for (var t = 0; t < loginTerms.length; t++) { if (txt.indexOf(loginTerms[t]) !== -1) { btn = allBtns[j]; break; } }
                    if (btn) break;
                }
            }
            if (!btn) return 'NOT_FOUND';
            btn.click(); btn.click(); btn.click();
            return 'TRIPLE_CLICKED';
        })();
        """
        let result = await executeJS(js)
        if result == "TRIPLE_CLICKED" {
            return (true, "Login button triple-clicked via trueDetection")
        }
        return (false, "trueDetection submit failed: \(result ?? "nil")")
    }

    func pressEnterOnPasswordField() async -> (success: Bool, detail: String) {
        let js = """
        (function() {
            var el = document.querySelector('input[type="password"]');
            if (!el) return 'NOT_FOUND';
            el.focus();
            var ev = new KeyboardEvent('keydown', {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true});
            el.dispatchEvent(ev);
            var ev2 = new KeyboardEvent('keypress', {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true});
            el.dispatchEvent(ev2);
            var ev3 = new KeyboardEvent('keyup', {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true});
            el.dispatchEvent(ev3);
            var form = el.closest('form');
            if (form) { form.dispatchEvent(new Event('submit', {bubbles: true, cancelable: true})); }
            return 'ENTER_PRESSED';
        })();
        """
        let result = await executeJS(js)
        if result == "ENTER_PRESSED" {
            return (true, "Enter pressed on password field")
        }
        return (false, "pressEnter failed: \(result ?? "nil")")
    }

    func trueDetectionValidateSuccess() async -> (success: Bool, detail: String) {
        let js = """
        (function() {
            var body = (document.body ? document.body.innerText : '').toLowerCase();
            var url = window.location.href.toLowerCase();
            var successMarkers = ['balance','wallet','my account','logout','dashboard','deposit','welcome'];
            for (var i = 0; i < successMarkers.length; i++) {
                if (body.indexOf(successMarkers[i]) !== -1) return 'SUCCESS:' + successMarkers[i];
            }
            if (url.indexOf('/login') === -1 && url.indexOf('/signin') === -1 && url.indexOf('error') === -1) {
                if (body.indexOf('balance') !== -1 || body.indexOf('wallet') !== -1) return 'SUCCESS:url+content';
            }
            return 'NO_SUCCESS_MARKERS';
        })();
        """
        let result = await executeJS(js)
        if let result, result.hasPrefix("SUCCESS:") {
            return (true, "trueDetection validated success: \(result)")
        }
        return (false, "trueDetection validation: \(result ?? "nil")")
    }
}

// MARK: - LoginSiteWebSession + WKNavigationDelegate

extension LoginSiteWebSession: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.isPageLoaded = true
            self.navigationCount += 1
            if let sid = self.monitoringSessionId {
                SessionActivityMonitor.shared.recordNavigation(sessionId: sid)
            }
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

    nonisolated func webView(_ webView: WKWebView,
                              decidePolicyFor navigationResponse: WKNavigationResponse,
                              decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            Task { @MainActor in
                self.lastHTTPStatusCode = httpResponse.statusCode
            }
        }
        decisionHandler(.allow)
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.processTerminated = true
            WebViewTracker.shared.reportProcessTermination()
            self.onProcessTerminated?()
            self.resolvePageLoad(false, errorMessage: "WebContent process terminated")
        }
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
        return "Navigation error: \(error.localizedDescription)"
    }
}

// MARK: - LoginSiteWebSession + WKScriptMessageHandler

extension LoginSiteWebSession: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                            didReceive message: WKScriptMessage) {
        // Bridge messages forwarded from the HyperFlow content controller.
    }
}

// MARK: - 2. LoginWebSession (HyperFlow-Backed)

/// Drop-in replacement for the legacy LoginWebSession used by PPSRAutomationEngine.
/// Isolated WKProcessPool + nonPersistent WKWebsiteDataStore per instance.
@MainActor
class LoginWebSession: NSObject {

    // MARK: Public Properties

    private(set) var webView: WKWebView?
    var stealthEnabled: Bool = false
    var speedMultiplier: Double = 1.0
    var blockImages: Bool = false
    var lastNavigationError: String?
    var lastHTTPStatusCode: Int?
    var networkConfig: ActiveNetworkConfig = .direct
    private(set) var stealthProfile: PPSRStealthService.SessionProfile?
    private(set) var lastFingerprintScore: FingerprintValidationService.FingerprintScore?
    var onFingerprintLog: ((String, PPSRLogEntry.Level) -> Void)?

    static let targetURL = URL(string: "https://transact.ppsr.gov.au/CarCheck/")!

    // MARK: Private / Isolation State

    private let sessionId: UUID = UUID()
    private let isolatedProcessPool = WKProcessPool()
    private let isolatedDataStore = WKWebsiteDataStore.nonPersistent()

    private var pageLoadContinuation: CheckedContinuation<Bool, Never>?
    private var isPageLoaded: Bool = false
    private var loadTimeoutTask: Task<Void, Never>?
    private var isProtectedRouteBlocked: Bool = false
    private let logger = DebugLogger.shared

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

    // MARK: Lifecycle

    func setUp() {
        logger.log("LoginWebSession[HF]: setUp (stealth=\(stealthEnabled), network=\(networkConfig.label), isolated=true)",
                   category: .webView, level: .debug)
        if webView != nil {
            tearDown()
        }

        let config = WKWebViewConfiguration()
        config.processPool = isolatedProcessPool
        config.websiteDataStore = isolatedDataStore
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let contentController = WKUserContentController()
        let trampolineProxy = WeakTrampolineProxy(target: self)
        contentController.add(trampolineProxy, name: "hyperflowBridge")

        if let blockScript = blockImagesScript {
            contentController.addUserScript(blockScript)
        }
        config.userContentController = contentController

        installBlockContentRules(on: contentController)

        let proxyApplied = NetworkSessionFactory.shared.configureWKWebView(
            config: config, networkConfig: networkConfig, target: .ppsr
        )
        isProtectedRouteBlocked = networkConfig.requiresProtectedRoute && !proxyApplied
        if isProtectedRouteBlocked {
            lastNavigationError = "Protected PPSR route blocked — no proxy path available"
            logger.log("LoginWebSession[HF]: BLOCKED — no proxy available for PPSR",
                       category: .network, level: .error)
        }

        if stealthEnabled {
            let stealth = PPSRStealthService.shared
            let profile = stealth.nextProfileSync()
            self.stealthProfile = profile

            let userScript = stealth.createStealthUserScript(profile: profile)
            config.userContentController.addUserScript(userScript)

            let wv = WKWebView(
                frame: CGRect(x: 0, y: 0,
                              width: profile.viewport.width,
                              height: profile.viewport.height),
                configuration: config)
            wv.navigationDelegate = self
            wv.customUserAgent = profile.userAgent
            self.webView = wv
        } else {
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                               configuration: config)
            wv.navigationDelegate = self
            wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
            self.webView = wv
        }

        if let wv = webView {
            WebViewPool.shared.mount(wv, for: sessionId)
        }
    }

    func tearDown() {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        if let wv = webView {
            wv.stopLoading()
            wv.configuration.websiteDataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast) { }
            wv.configuration.userContentController.removeAllUserScripts()
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "hyperflowBridge")
            wv.navigationDelegate = nil
        }
        if webView != nil {
            WebViewPool.shared.unmount(id: sessionId)
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

    // MARK: Navigation

    func loadPage(timeout: TimeInterval = 60) async -> Bool {
        guard let webView else {
            lastNavigationError = "WebView not initialized"
            return false
        }
        guard !isProtectedRouteBlocked else { return false }

        logger.startTimer(key: "loginWebSession_load")
        isPageLoaded = false
        lastNavigationError = nil
        lastHTTPStatusCode = nil

        if let existingCont = pageLoadContinuation {
            pageLoadContinuation = nil
            existingCont.resume(returning: false)
        }

        let request = URLRequest(url: Self.targetURL,
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: timeout)
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
            logger.log("LoginWebSession[HF]: page loaded in \(loadMs ?? 0)ms",
                       category: .webView, level: .success, durationMs: loadMs)
            await injectFingerprint()
            try? await Task.sleep(for: .milliseconds(1500))
            await waitForDOMReady(timeout: 10)
            let _ = await validateFingerprint()
        } else {
            logger.log("LoginWebSession[HF]: page load FAILED — \(lastNavigationError ?? "unknown")",
                       category: .webView, level: .error, durationMs: loadMs)
        }

        return loaded
    }

    // MARK: JavaScript

    func evaluateJavaScript(_ js: String) async -> Any? {
        guard let webView else { return nil }
        do {
            return try await webView.evaluateJavaScript(js)
        } catch {
            return nil
        }
    }

    private func executeJS(_ js: String) async -> String? {
        guard let webView else {
            logger.log("LoginWebSession[HF]: executeJS — webView nil", category: .webView, level: .warning)
            return nil
        }
        do {
            let result = try await webView.evaluateJavaScript(js)
            if let str = result as? String { return str }
            if let num = result as? NSNumber { return "\(num)" }
            return nil
        } catch {
            logger.logError("LoginWebSession[HF]: JS eval failed", error: error, category: .webView, metadata: [
                "jsPrefix": String(js.prefix(60))
            ])
            return nil
        }
    }

    // MARK: Page Content & Screenshots

    func getPageContent() async -> String? {
        await executeJS("document.body ? document.body.innerText.substring(0, \(BridgeConstants.maxPageContentLength)) : ''")
    }

    func captureScreenshot() async -> UIImage? {
        guard let webView else { return nil }
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        return try? await webView.takeSnapshot(configuration: config)
    }

    func captureScreenshotWithCrop(cropRect: CGRect?) async -> (full: UIImage?, cropped: UIImage?) {
        let full = await captureScreenshot()
        guard let full, let cropRect, cropRect != .zero else { return (full, nil) }
        let cropped = cropImage(full, to: cropRect)
        return (full, cropped)
    }

    // MARK: PPSR-Specific Form Filling

    func waitForAppReady(timeout: TimeInterval = 90) async -> (ready: Bool, fieldsFound: Int, detail: String) {
        let start = Date()
        var lastFieldCount = 0
        var lastDetail = "Waiting for app to initialize..."
        var stableCount = 0
        let requiredStableCycles = 2

        while Date().timeIntervalSince(start) < timeout {
            let checkJS = """
            (function() {
                var result = { ready: false, fieldsFound: 0, loading: false, detail: '' };
                var allInputs = document.querySelectorAll('input, select, textarea');
                result.inputCount = allInputs.length;
                \(findFieldJS)
                var fieldDefs = {
                    'vin': [{"type":"id","value":"vin"},{"type":"name","value":"vin"},{"type":"placeholder","value":"Enter VIN"},{"type":"css","value":"input[type='text']:first-of-type"}],
                    'email': [{"type":"id","value":"email"},{"type":"name","value":"email"},{"type":"css","value":"input[type='email']"}],
                    'cardNumber': [{"type":"id","value":"cardNumber"},{"type":"name","value":"cardNumber"},{"type":"css","value":"input[autocomplete='cc-number']"}],
                    'expMonth': [{"type":"id","value":"expMonth"},{"type":"name","value":"expMonth"},{"type":"css","value":"input[autocomplete='cc-exp-month']"}],
                    'expYear': [{"type":"id","value":"expYear"},{"type":"name","value":"expYear"},{"type":"css","value":"input[autocomplete='cc-exp-year']"}],
                    'cvv': [{"type":"id","value":"cvv"},{"type":"name","value":"cvv"},{"type":"css","value":"input[autocomplete='cc-csc']"}]
                };
                var found = 0;
                var foundFields = [];
                for (var name in fieldDefs) {
                    var el = findField(fieldDefs[name]);
                    if (el) { found++; foundFields.push(name); }
                }
                result.fieldsFound = found;
                if (found >= 3) {
                    result.ready = true;
                    result.detail = 'Form ready with ' + found + '/6 fields: ' + foundFields.join(', ');
                } else {
                    result.detail = found > 0 ? 'Partial: ' + found + '/6 fields' : 'No fields found yet';
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
            let detail = json["detail"] as? String ?? "Unknown state"

            lastFieldCount = fieldsFound
            lastDetail = detail

            if isReady {
                stableCount += 1
                if stableCount >= requiredStableCycles {
                    return (true, fieldsFound, detail)
                }
                try? await Task.sleep(for: .milliseconds(500))
                continue
            } else {
                stableCount = 0
            }

            try? await Task.sleep(for: .seconds(1))
        }

        return (lastFieldCount >= 3, lastFieldCount, "Timeout: \(lastDetail)")
    }

    private let findFieldJS = """
    function findField(strategies) {
        for (var i = 0; i < strategies.length; i++) {
            var s = strategies[i];
            var el = null;
            try {
                if (s.type === 'id') { el = document.getElementById(s.value); }
                else if (s.type === 'name') { var els = document.getElementsByName(s.value); if (els.length > 0) el = els[0]; }
                else if (s.type === 'placeholder') {
                    el = document.querySelector('input[placeholder*="' + s.value + '"]');
                    if (!el) el = document.querySelector('textarea[placeholder*="' + s.value + '"]');
                }
                else if (s.type === 'label') {
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
                }
                else if (s.type === 'css') { el = document.querySelector(s.value); }
                else if (s.type === 'ariaLabel') { el = document.querySelector('[aria-label*="' + s.value + '"]'); }
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
            var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (ns && ns.set) { ns.set.call(el, '\(escaped)'); } else { el.value = '\(escaped)'; }
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

    private func classifyFillResult(_ result: String?, fieldName: String) -> (success: Bool, detail: String) {
        switch result {
        case "OK":           return (true, "\(fieldName) filled successfully")
        case "VALUE_MISMATCH": return (true, "\(fieldName) filled but value verification mismatch")
        case "NOT_FOUND":    return (false, "\(fieldName) selector NOT_FOUND")
        case nil:            return (false, "\(fieldName) JS execution returned nil")
        default:             return (false, "\(fieldName) unexpected result: '\(result ?? "")'")
        }
    }

    func fillVIN(_ vin: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"vin"},{"type":"id","value":"vehicleId"},{"type":"id","value":"VIN"},
            {"type":"name","value":"vin"},{"type":"name","value":"vehicleId"},
            {"type":"placeholder","value":"Enter VIN"},{"type":"placeholder","value":"VIN"},
            {"type":"label","value":"Enter VIN"},{"type":"label","value":"VIN"},
            {"type":"ariaLabel","value":"VIN"},
            {"type":"css","value":"input[type='text']:first-of-type"},{"type":"css","value":"input[data-field='vin']"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: vin))
        return classifyFillResult(result, fieldName: "VIN")
    }

    func fillEmail(_ email: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"email"},{"type":"name","value":"email"},
            {"type":"placeholder","value":"email"},
            {"type":"css","value":"input[type='email']"},
            {"type":"label","value":"email"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: email))
        return classifyFillResult(result, fieldName: "Email")
    }

    func fillCardNumber(_ number: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"cardNumber"},{"type":"name","value":"cardNumber"},
            {"type":"placeholder","value":"card number"},
            {"type":"css","value":"input[autocomplete='cc-number']"},
            {"type":"label","value":"card number"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: number))
        return classifyFillResult(result, fieldName: "Card Number")
    }

    func fillExpMonth(_ month: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"expMonth"},{"type":"name","value":"expMonth"},
            {"type":"placeholder","value":"MM"},{"type":"label","value":"month"},
            {"type":"css","value":"input[autocomplete='cc-exp-month']"},
            {"type":"css","value":"select[autocomplete='cc-exp-month']"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: month))
        return classifyFillResult(result, fieldName: "Exp Month")
    }

    func fillExpYear(_ year: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"expYear"},{"type":"name","value":"expYear"},
            {"type":"placeholder","value":"YY"},{"type":"label","value":"year"},
            {"type":"css","value":"input[autocomplete='cc-exp-year']"},
            {"type":"css","value":"select[autocomplete='cc-exp-year']"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: year))
        return classifyFillResult(result, fieldName: "Exp Year")
    }

    func fillCVV(_ cvv: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"cvv"},{"type":"name","value":"cvv"},
            {"type":"placeholder","value":"CVV"},
            {"type":"css","value":"input[autocomplete='cc-csc']"},
            {"type":"label","value":"cvv"},{"type":"label","value":"security code"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: cvv))
        return classifyFillResult(result, fieldName: "CVV")
    }

    func clickShowMyResults() async -> (success: Bool, detail: String) {
        let js = """
        (function() {
            var selectors = [
                'button[type="submit"]', 'input[type="submit"]',
                'button.btn-primary', '#submitButton',
                'button:contains("Show")', 'button:contains("Search")',
                'button:not([type])'
            ];
            for (var i = 0; i < selectors.length; i++) {
                try {
                    var el = document.querySelector(selectors[i]);
                    if (el && !el.disabled) { el.click(); return 'CLICKED'; }
                } catch(e) {}
            }
            var buttons = document.querySelectorAll('button, input[type="submit"]');
            for (var j = 0; j < buttons.length; j++) {
                var txt = (buttons[j].textContent || buttons[j].value || '').toLowerCase();
                if (txt.indexOf('show') !== -1 || txt.indexOf('search') !== -1 || txt.indexOf('result') !== -1) {
                    buttons[j].click();
                    return 'CLICKED_TEXT';
                }
            }
            return 'NOT_FOUND';
        })();
        """
        let result = await executeJS(js)
        if let result, result.hasPrefix("CLICKED") {
            return (true, "Show My Results clicked via: \(result)")
        }
        return (false, "Submit button not found")
    }

    // MARK: Stealth Profile

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
                let stealth = PPSRStealthService.shared
                let newProfile = await stealth.nextProfile()
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

    // MARK: Internals

    private var blockImagesScript: WKUserScript? {
        guard blockImages else { return nil }
        return WKUserScript(source: """
        (function() {
            var style = document.createElement('style');
            style.textContent = 'img, video, audio, source, svg, picture, iframe, object, embed, canvas { display: none !important; visibility: hidden !important; }';
            (document.head || document.documentElement).appendChild(style);
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
        ) { ruleList, _ in
            if let ruleList {
                contentController.add(ruleList)
            }
        }
    }

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

    private func waitForDOMReady(timeout: TimeInterval) async {
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

    private func cropImage(_ image: UIImage, to rect: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let scale = image.scale
        let scaledRect = CGRect(x: rect.origin.x * scale, y: rect.origin.y * scale,
                                width: rect.width * scale, height: rect.height * scale)
        guard let cropped = cgImage.cropping(to: scaledRect) else { return nil }
        return UIImage(cgImage: cropped, scale: scale, orientation: image.imageOrientation)
    }

    // MARK: Additional PPSR Methods

    func checkForIframes() async -> Bool {
        guard let wv = webView else { return false }
        let js = "(function(){ return document.querySelectorAll('iframe').length > 0 ? 'true' : 'false'; })()"
        do {
            let result = try await wv.evaluateJavaScript(js) as? String
            return result == "true"
        } catch { return false }
    }

    func dumpPageStructure() async -> String? {
        guard let wv = webView else { return nil }
        let js = """
        (function(){
            function walk(el, depth) {
                if (depth > 4) return '';
                var tag = el.tagName || '';
                var id = el.id ? '#' + el.id : '';
                var cls = el.className && typeof el.className === 'string' ? '.' + el.className.split(' ').join('.') : '';
                var prefix = '  '.repeat(depth);
                var line = prefix + tag.toLowerCase() + id + cls + '\\n';
                for (var i = 0; i < el.children.length && i < 20; i++) {
                    line += walk(el.children[i], depth + 1);
                }
                return line;
            }
            return walk(document.body || document.documentElement, 0).substring(0, 5000);
        })()
        """
        do {
            return try await wv.evaluateJavaScript(js) as? String
        } catch { return nil }
    }

    func verifyFieldsExist() async -> Bool {
        guard let wv = webView else { return false }
        let js = """
        (function(){
            var vin = document.querySelector('input[name*="vin" i], input[id*="vin" i], input[placeholder*="vin" i], input[aria-label*="vin" i]');
            return vin ? 'true' : 'false';
        })()
        """
        do {
            let result = try await wv.evaluateJavaScript(js) as? String
            return result == "true"
        } catch { return false }
    }

    func waitForNavigation(timeout: TimeInterval = 30) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if isPageLoaded { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return isPageLoaded
    }

    func getPageTitle() async -> String {
        webView?.title ?? ""
    }

    func getCurrentURL() async -> String {
        webView?.url?.absoluteString ?? ""
    }
}

// MARK: - LoginWebSession + WKNavigationDelegate

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

    nonisolated func webView(_ webView: WKWebView,
                              decidePolicyFor navigationResponse: WKNavigationResponse,
                              decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            Task { @MainActor in self.lastHTTPStatusCode = httpResponse.statusCode }
        }
        decisionHandler(.allow)
    }

    nonisolated func webView(_ webView: WKWebView,
                              decidePolicyFor navigationAction: WKNavigationAction,
                              decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
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
            default: return "Network error (\(nsError.code)): \(nsError.localizedDescription)"
            }
        }
        return "Navigation error: \(error.localizedDescription)"
    }
}

// MARK: - LoginWebSession + WKScriptMessageHandler

extension LoginWebSession: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                            didReceive message: WKScriptMessage) {
        // Bridge messages from HyperFlow content controller.
    }
}

// MARK: - 3. BPointWebSession (HyperFlow-Backed)

/// Drop-in replacement for the legacy BPointWebSession used by BPointAutomationEngine.
/// Isolated WKProcessPool + nonPersistent WKWebsiteDataStore per instance.
@MainActor
class BPointWebSession: NSObject {

    // MARK: Public Properties

    private(set) var webView: WKWebView?
    var stealthEnabled: Bool = false
    var speedMultiplier: Double = 1.0
    var blockImages: Bool = false
    var lastNavigationError: String?
    var lastHTTPStatusCode: Int?
    var networkConfig: ActiveNetworkConfig = .direct
    var onFingerprintLog: ((String, PPSRLogEntry.Level) -> Void)?

    static let targetURL = URL(string: "https://www.bpoint.com.au/payments/DepartmentOfFinance")!
    static let billerLookupURL = URL(string: "https://www.bpoint.com.au/payments/billpayment/Payment/Index")!

    // MARK: Private / Isolation State

    private let sessionId: UUID = UUID()
    private let isolatedProcessPool = WKProcessPool()
    private let isolatedDataStore = WKWebsiteDataStore.nonPersistent()

    private var pageLoadContinuation: CheckedContinuation<Bool, Never>?
    private var isPageLoaded: Bool = false
    private var loadTimeoutTask: Task<Void, Never>?
    private var isProtectedRouteBlocked: Bool = false
    private var stealthProfile: PPSRStealthService.SessionProfile?
    private let logger = DebugLogger.shared

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

    // MARK: Lifecycle

    func setUp() {
        logger.log("BPointWebSession[HF]: setUp (stealth=\(stealthEnabled), network=\(networkConfig.label), isolated=true)",
                   category: .webView, level: .debug)
        if webView != nil { tearDown() }

        let config = WKWebViewConfiguration()
        config.processPool = isolatedProcessPool
        config.websiteDataStore = isolatedDataStore
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let contentController = WKUserContentController()
        let trampolineProxy = WeakTrampolineProxy(target: self)
        contentController.add(trampolineProxy, name: "hyperflowBridge")

        if blockImages {
            let blockScript = WKUserScript(source: """
            (function() {
                var style = document.createElement('style');
                style.textContent = 'img, video, audio, source, svg, picture, iframe, object, embed, canvas { display: none !important; visibility: hidden !important; }';
                (document.head || document.documentElement).appendChild(style);
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            contentController.addUserScript(blockScript)
        }
        config.userContentController = contentController
        installBlockContentRules(on: contentController)

        let proxyApplied = NetworkSessionFactory.shared.configureWKWebView(
            config: config, networkConfig: networkConfig, target: .ppsr
        )
        isProtectedRouteBlocked = networkConfig.requiresProtectedRoute && !proxyApplied
        if isProtectedRouteBlocked {
            lastNavigationError = "Protected BPoint route blocked — no proxy path available"
            logger.log("BPointWebSession[HF]: BLOCKED — no proxy available", category: .network, level: .error)
        }

        if stealthEnabled {
            let stealth = PPSRStealthService.shared
            let profile = stealth.nextProfileSync()
            self.stealthProfile = profile
            let userScript = stealth.createStealthUserScript(profile: profile)
            config.userContentController.addUserScript(userScript)
            let wv = WKWebView(
                frame: CGRect(x: 0, y: 0,
                              width: profile.viewport.width,
                              height: profile.viewport.height),
                configuration: config)
            wv.navigationDelegate = self
            wv.customUserAgent = profile.userAgent
            self.webView = wv
        } else {
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                               configuration: config)
            wv.navigationDelegate = self
            wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
            self.webView = wv
        }

        if let wv = webView {
            WebViewPool.shared.mount(wv, for: sessionId)
        }
    }

    func tearDown() {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        if let wv = webView {
            wv.stopLoading()
            wv.configuration.websiteDataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast) { }
            wv.configuration.userContentController.removeAllUserScripts()
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "hyperflowBridge")
            wv.navigationDelegate = nil
        }
        if webView != nil {
            WebViewPool.shared.unmount(id: sessionId)
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

    // MARK: Navigation

    func loadPage(timeout: TimeInterval = 60) async -> Bool {
        guard let webView else {
            lastNavigationError = "WebView not initialized"
            return false
        }
        guard !isProtectedRouteBlocked else { return false }

        logger.startTimer(key: "bpointWebSession_load")
        isPageLoaded = false
        lastNavigationError = nil
        lastHTTPStatusCode = nil

        if let existingCont = pageLoadContinuation {
            pageLoadContinuation = nil
            existingCont.resume(returning: false)
        }

        let request = URLRequest(url: Self.targetURL,
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: timeout)
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
            logger.log("BPointWebSession[HF]: page loaded in \(loadMs ?? 0)ms",
                       category: .webView, level: .success, durationMs: loadMs)
            if stealthEnabled, let profile = stealthProfile {
                _ = await executeJS(PPSRStealthService.shared.fingerprintJS())
                try? await Task.sleep(for: .milliseconds(1500))
            }
            await waitForDOMReady(timeout: 10)
        } else {
            logger.log("BPointWebSession[HF]: page load FAILED — \(lastNavigationError ?? "unknown")",
                       category: .webView, level: .error, durationMs: loadMs)
        }
        return loaded
    }

    func loadURL(_ url: URL, timeout: TimeInterval = 90) async -> Bool {
        guard let webView else { return false }
        isPageLoaded = false
        lastNavigationError = nil

        if let existingCont = pageLoadContinuation {
            pageLoadContinuation = nil
            existingCont.resume(returning: false)
        }

        let request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: timeout)
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
            await waitForDOMReady(timeout: 10)
        }
        return loaded
    }

    func loadBillerLookupPage(timeout: TimeInterval = 90) async -> Bool {
        await loadURL(Self.billerLookupURL, timeout: timeout)
    }

    // MARK: JavaScript

    func executeJS(_ js: String) async -> String? {
        guard let webView else { return nil }
        do {
            let result = try await webView.evaluateJavaScript(js)
            if let str = result as? String { return str }
            if let num = result as? NSNumber { return "\(num)" }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: Page Content & Screenshots

    func getPageContent() async -> String? {
        await executeJS("document.body ? document.body.innerText.substring(0, \(BridgeConstants.maxPageContentLength)) : ''")
    }

    func captureScreenshot() async -> UIImage? {
        guard let webView else { return nil }
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        return try? await webView.takeSnapshot(configuration: config)
    }

    func captureScreenshotWithCrop(cropRect: CGRect?) async -> (full: UIImage?, cropped: UIImage?) {
        let full = await captureScreenshot()
        guard let full, let cropRect, cropRect != .zero else { return (full, nil) }
        let cropped = cropImage(full, to: cropRect)
        return (full, cropped)
    }

    // MARK: BPoint Form Filling

    private let findFieldJS = """
    function findField(strategies) {
        for (var i = 0; i < strategies.length; i++) {
            var s = strategies[i];
            var el = null;
            try {
                if (s.type === 'id') { el = document.getElementById(s.value); }
                else if (s.type === 'name') { var els = document.getElementsByName(s.value); if (els.length > 0) el = els[0]; }
                else if (s.type === 'placeholder') {
                    el = document.querySelector('input[placeholder*="' + s.value + '"]');
                    if (!el) el = document.querySelector('textarea[placeholder*="' + s.value + '"]');
                }
                else if (s.type === 'label') {
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
                }
                else if (s.type === 'css') { el = document.querySelector(s.value); }
                else if (s.type === 'ariaLabel') { el = document.querySelector('[aria-label*="' + s.value + '"]'); }
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
            var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (ns && ns.set) { ns.set.call(el, '\(escaped)'); } else { el.value = '\(escaped)'; }
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

    private func classifyFillResult(_ result: String?, fieldName: String) -> (success: Bool, detail: String) {
        switch result {
        case "OK":           return (true, "\(fieldName) filled successfully")
        case "VALUE_MISMATCH": return (true, "\(fieldName) filled but value verification mismatch")
        case "NOT_FOUND":    return (false, "\(fieldName) selector NOT_FOUND")
        case nil:            return (false, "\(fieldName) JS execution returned nil")
        default:             return (false, "\(fieldName) unexpected result: '\(result ?? "")'")
        }
    }

    func fillReferenceNumber(_ ref: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"BillerCode"},{"type":"id","value":"billerCode"},
            {"type":"id","value":"Reference1"},{"type":"id","value":"reference1"},
            {"type":"name","value":"BillerCode"},{"type":"name","value":"Reference1"},
            {"type":"placeholder","value":"Reference"},
            {"type":"label","value":"reference"},
            {"type":"css","value":"input[type='text']:first-of-type"},
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
            {"type":"id","value":"PaymentAmount"},
            {"type":"name","value":"Amount"},{"type":"name","value":"PaymentAmount"},
            {"type":"placeholder","value":"Amount"},{"type":"placeholder","value":"0.00"},
            {"type":"label","value":"amount"},
            {"type":"css","value":"#Amount"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: amount))
        return classifyFillResult(result, fieldName: "Amount")
    }

    func clickCardBrandLogo(isVisa: Bool) async -> (success: Bool, detail: String) {
        let brandName = isVisa ? "visa" : "mastercard"
        let js = """
        (function() {
            var selectors = [
                'div.\(brandName)', '.\(brandName)',
                '[data-type="\(brandName)"]',
                '[aria-label="\(isVisa ? "Visa" : "MasterCard")"]',
                '[title="\(isVisa ? "Visa" : "MasterCard")"]'
            ];
            for (var i = 0; i < selectors.length; i++) {
                try {
                    var el = document.querySelector(selectors[i]);
                    if (el) { el.click(); return 'CLICKED'; }
                } catch(e) {}
            }
            return 'NOT_FOUND';
        })();
        """

        for attempt in 1...3 {
            let result = await executeJS(js)
            if let result, result != "NOT_FOUND" {
                return (true, "\(isVisa ? "Visa" : "Mastercard") clicked (attempt \(attempt))")
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
            {"type":"id","value":"CardNumber"},{"type":"id","value":"cardNumber"},
            {"type":"name","value":"CardNumber"},
            {"type":"placeholder","value":"Card Number"},
            {"type":"css","value":"input[autocomplete='cc-number']"},
            {"type":"css","value":"#CardNumber"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: number))
        return classifyFillResult(result, fieldName: "Card Number")
    }

    func fillExpiry(_ expiry: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"ExpiryDate"},{"type":"id","value":"expiry"},
            {"type":"name","value":"ExpiryDate"},
            {"type":"placeholder","value":"MM/YY"},
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
            {"type":"id","value":"ExpiryMonth"},{"type":"id","value":"expMonth"},
            {"type":"name","value":"ExpiryMonth"},
            {"type":"placeholder","value":"MM"},
            {"type":"css","value":"input[autocomplete='cc-exp-month']"},
            {"type":"css","value":"select[autocomplete='cc-exp-month']"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: month))
        return classifyFillResult(result, fieldName: "Exp Month")
    }

    func fillExpYear(_ year: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"ExpiryYear"},{"type":"id","value":"expYear"},
            {"type":"name","value":"ExpiryYear"},
            {"type":"placeholder","value":"YY"},
            {"type":"css","value":"input[autocomplete='cc-exp-year']"},
            {"type":"css","value":"select[autocomplete='cc-exp-year']"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: year))
        return classifyFillResult(result, fieldName: "Exp Year")
    }

    func fillCVV(_ cvv: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"CVN"},{"type":"id","value":"cvv"},
            {"type":"name","value":"CVN"},
            {"type":"placeholder","value":"CVV"},
            {"type":"css","value":"input[autocomplete='cc-csc']"},
            {"type":"css","value":"#CVN"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: cvv))
        return classifyFillResult(result, fieldName: "CVV")
    }

    func clickSubmitPayment() async -> (success: Bool, detail: String) {
        let js = """
        (function() {
            var selectors = [
                'button[type="submit"]', 'input[type="submit"]',
                '#submitButton', '.submit-button',
                'button.btn-primary'
            ];
            for (var i = 0; i < selectors.length; i++) {
                try {
                    var el = document.querySelector(selectors[i]);
                    if (el && !el.disabled) { el.click(); return 'CLICKED'; }
                } catch(e) {}
            }
            var buttons = document.querySelectorAll('button, input[type="submit"]');
            for (var j = 0; j < buttons.length; j++) {
                var txt = (buttons[j].textContent || buttons[j].value || '').toLowerCase();
                if (txt.indexOf('submit') !== -1 || txt.indexOf('pay') !== -1 || txt.indexOf('proceed') !== -1) {
                    buttons[j].click();
                    return 'CLICKED_TEXT';
                }
            }
            return 'NOT_FOUND';
        })();
        """
        let result = await executeJS(js)
        if let result, result.hasPrefix("CLICKED") {
            return (true, "Submit payment clicked via: \(result)")
        }
        return (false, "Submit button not found")
    }

    func enterBillerCodeAndSearch(_ code: String) async -> (success: Bool, detail: String) {
        let fillResult = await fillReferenceNumber(code)
        guard fillResult.success else { return fillResult }

        let searchJS = """
        (function() {
            var btn = document.querySelector('button[type="submit"]') ||
                      document.querySelector('input[type="submit"]') ||
                      document.querySelector('#searchButton') ||
                      document.querySelector('.search-button');
            if (btn) { btn.click(); return 'SEARCHED'; }
            return 'NO_SEARCH_BUTTON';
        })();
        """
        let result = await executeJS(searchJS)
        if result == "SEARCHED" {
            return (true, "Biller code entered and search initiated")
        }
        return (true, "Biller code entered but search button not found")
    }

    func detectFormFields() async -> (textFieldCount: Int, hasAmountField: Bool, detail: String) {
        let js = """
        (function() {
            var inputs = document.querySelectorAll('input[type="text"], input[type="number"], input:not([type])');
            var hasAmount = false;
            for (var i = 0; i < inputs.length; i++) {
                var id = (inputs[i].id || '').toLowerCase();
                var name = (inputs[i].name || '').toLowerCase();
                if (id.indexOf('amount') !== -1 || name.indexOf('amount') !== -1) hasAmount = true;
            }
            return JSON.stringify({ count: inputs.length, hasAmount: hasAmount });
        })();
        """
        guard let result = await executeJS(js),
              let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (0, false, "Detection failed")
        }
        let count = json["count"] as? Int ?? 0
        let hasAmount = json["hasAmount"] as? Bool ?? false
        return (count, hasAmount, "Found \(count) text fields, amount=\(hasAmount)")
    }

    func fillAllFormFields(amount: String) async -> (success: Bool, detail: String) {
        let amountResult = await fillAmount(amount)
        return amountResult
    }

    func checkForValidationErrors() async -> (hasErrors: Bool, detail: String) {
        let js = """
        (function() {
            var errors = document.querySelectorAll(
                '.validation-summary-errors, .field-validation-error, .error-message, ' +
                '.alert-danger, .has-error, [class*="error"], [class*="invalid"]'
            );
            var visible = [];
            for (var i = 0; i < errors.length; i++) {
                var el = errors[i];
                var style = window.getComputedStyle(el);
                if (style.display !== 'none' && style.visibility !== 'hidden' && el.textContent.trim().length > 0) {
                    visible.push(el.textContent.trim().substring(0, 100));
                }
            }
            return JSON.stringify({ hasErrors: visible.length > 0, errors: visible });
        })();
        """
        guard let result = await executeJS(js),
              let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, "Validation check failed")
        }
        let hasErrors = json["hasErrors"] as? Bool ?? false
        let errors = json["errors"] as? [String] ?? []
        let detail = hasErrors ? "Errors: \(errors.prefix(3).joined(separator: "; "))" : "No validation errors"
        return (hasErrors, detail)
    }

    // MARK: Internals

    private func installBlockContentRules(on contentController: WKUserContentController) {
        guard blockImages else { return }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: Self.blockResourcesRuleListID,
            encodedContentRuleList: Self.blockResourcesRuleListJSON
        ) { ruleList, _ in
            if let ruleList {
                contentController.add(ruleList)
            }
        }
    }

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

    private func waitForDOMReady(timeout: TimeInterval) async {
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

    private func cropImage(_ image: UIImage, to rect: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let scale = image.scale
        let scaledRect = CGRect(x: rect.origin.x * scale, y: rect.origin.y * scale,
                                width: rect.width * scale, height: rect.height * scale)
        guard let cropped = cgImage.cropping(to: scaledRect) else { return nil }
        return UIImage(cgImage: cropped, scale: scale, orientation: image.imageOrientation)
    }

    func detectEmailFieldOnPaymentPage() async -> Bool {
        guard let wv = webView else { return false }
        let js = "(function(){ var el = document.querySelector('input[type=\"email\"], input[name*=\"email\" i], input[id*=\"email\" i]'); return el ? 'true' : 'false'; })()"
        do {
            let result = try await wv.evaluateJavaScript(js) as? String
            return result == "true"
        } catch { return false }
    }

    func waitForContentChange(timeout: TimeInterval = 10) async -> Bool {
        guard let wv = webView else { return false }
        let initialContent = try? await wv.evaluateJavaScript("document.body.innerText.length") as? Int
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(for: .milliseconds(500))
            let currentContent = try? await wv.evaluateJavaScript("document.body.innerText.length") as? Int
            if currentContent != initialContent { return true }
        }
        return false
    }

    func getCurrentURL() async -> String {
        webView?.url?.absoluteString ?? ""
    }

    func waitForNavigation(timeout: TimeInterval = 30) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if isPageLoaded { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return isPageLoaded
    }
}

// MARK: - BPointWebSession + WKNavigationDelegate

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

    nonisolated func webView(_ webView: WKWebView,
                              decidePolicyFor navigationResponse: WKNavigationResponse,
                              decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            Task { @MainActor in self.lastHTTPStatusCode = httpResponse.statusCode }
        }
        decisionHandler(.allow)
    }

    nonisolated func webView(_ webView: WKWebView,
                              decidePolicyFor navigationAction: WKNavigationAction,
                              decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }
}

// MARK: - BPointWebSession + WKScriptMessageHandler

extension BPointWebSession: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                            didReceive message: WKScriptMessage) {
        // Bridge messages from HyperFlow content controller.
    }
}

// MARK: - 4. WebViewTracker Compatibility Bridge

/// Maps the legacy WebViewTracker interface to WebViewPool.shared from HyperFlow.
/// Maintains the full old API surface while delegating pool management to WebViewPool.
@MainActor
class WebViewTracker {
    static let shared = WebViewTracker()

    private(set) var activeCount: Int = 0
    private(set) var totalCreated: Int = 0
    private(set) var totalReleased: Int = 0
    private(set) var processTerminationCount: Int = 0
    private(set) var peakActiveCount: Int = 0
    private var activeSessions: [String: Date] = [:]
    private var orphanDetectionCount: Int = 0

    func incrementActive(sessionId: String = "unknown") {
        activeCount += 1
        totalCreated += 1
        activeSessions[sessionId] = Date()
        peakActiveCount = max(peakActiveCount, activeCount)
    }

    func decrementActive(sessionId: String = "unknown") {
        guard activeCount > 0 else {
            DebugLogger.shared.log("WebViewTracker[HF]: decrementActive called with count=0 (session: \(sessionId))",
                                   category: .webView, level: .warning)
            return
        }
        activeCount -= 1
        totalReleased += 1
        activeSessions.removeValue(forKey: sessionId)
    }

    func reportProcessTermination() {
        processTerminationCount += 1
    }

    func reset() {
        let leaked = activeSessions
        activeCount = 0
        activeSessions.removeAll()
        // Also reset the HyperFlow pool.
        WebViewPool.shared.reset()
        if !leaked.isEmpty {
            let sessionList = leaked.keys.prefix(10).joined(separator: ", ")
            DebugLogger.shared.log("WebViewTracker[HF]: force-reset \(leaked.count) leaked sessions [\(sessionList)]",
                                   category: .webView, level: .warning)
        }
    }

    func detectOrphans(batchRunning: Bool) -> [String] {
        guard !batchRunning, !activeSessions.isEmpty else { return [] }
        let now = Date()
        let orphanThreshold: TimeInterval = 120
        let orphans = activeSessions.filter { now.timeIntervalSince($0.value) > orphanThreshold }
        if !orphans.isEmpty {
            orphanDetectionCount += 1
            let sessionList = orphans.keys.prefix(5).joined(separator: ", ")
            DebugLogger.shared.log("WebViewTracker[HF]: \(orphans.count) orphaned WebViews detected [\(sessionList)]",
                                   category: .webView, level: .error)
        }
        return Array(orphans.keys)
    }

    var activeSessionIds: [String] {
        Array(activeSessions.keys)
    }

    var diagnosticSummary: String {
        "Active: \(activeCount) | Peak: \(peakActiveCount) | Created: \(totalCreated) | Released: \(totalReleased) | Crashes: \(processTerminationCount) | Pool: \(WebViewPool.shared.activeCount)"
    }
}

// MARK: - 5. DeadSessionDetector Compatibility Bridge

/// Preserves the full DeadSessionDetector API. Uses SessionActivityMonitor for
/// idle detection and JS heartbeat checks for liveness.
@MainActor
class DeadSessionDetector {
    static let shared = DeadSessionDetector()

    private let logger = DebugLogger.shared
    private let activityMonitor = SessionActivityMonitor.shared
    private let heartbeatTimeoutSeconds: TimeInterval = BridgeConstants.heartbeatTimeoutSeconds
    private var activeWatchdogs: [String: Task<Void, Never>] = [:]
    private var sessionStartTimes: [String: Date] = [:]

    func isSessionAlive(_ webView: WKWebView?, sessionId: String = "") async -> Bool {
        guard let webView else {
            logger.log("DeadSessionDetector[HF]: webView is nil — session dead",
                       category: .webView, level: .warning, sessionId: sessionId)
            return false
        }

        let alive = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    let result = try await webView.evaluateJavaScript("'heartbeat_ok'")
                    return (result as? String) == "heartbeat_ok"
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(self.heartbeatTimeoutSeconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        if alive {
            activityMonitor.recordJSResponse(sessionId: sessionId)
        } else {
            logger.log("DeadSessionDetector[HF]: session HUNG — no JS response in \(Int(heartbeatTimeoutSeconds))s",
                       category: .webView, level: .error, sessionId: sessionId)
        }

        return alive
    }

    func checkAndRecover(
        webView: WKWebView?,
        sessionId: String,
        onRecovery: () async -> Void
    ) async -> Bool {
        let alive = await isSessionAlive(webView, sessionId: sessionId)
        if !alive {
            logger.log("DeadSessionDetector[HF]: triggering recovery for session \(sessionId)",
                       category: .webView, level: .warning, sessionId: sessionId)
            await onRecovery()
            return true
        }
        return false
    }

    func startWatchdog(
        sessionId: String,
        timeout: TimeInterval,
        checkInterval: TimeInterval = 10,
        webViewProvider: @escaping @MainActor () -> WKWebView?,
        onTimeout: @escaping @MainActor () async -> Void
    ) {
        stopWatchdog(sessionId: sessionId)
        sessionStartTimes[sessionId] = Date()
        activityMonitor.startMonitoring(sessionId: sessionId)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(timeout)

            while !Task.isCancelled && Date() < deadline {
                try? await Task.sleep(for: .seconds(checkInterval))
                guard !Task.isCancelled else { return }

                let elapsed = Date().timeIntervalSince(self.sessionStartTimes[sessionId] ?? Date())
                let remaining = timeout - elapsed

                let idleStatus = self.activityMonitor.checkIdleStatus(sessionId: sessionId)
                if case .idle(let secondsIdle) = idleStatus,
                   secondsIdle >= SessionActivityMonitor.idleThresholdSeconds {
                    self.logger.log("DeadSessionDetector[HF]: IDLE TIMEOUT for \(sessionId) — \(Int(secondsIdle))s idle",
                                   category: .webView, level: .error, sessionId: sessionId)
                    await onTimeout()
                    self.cleanupWatchdog(sessionId: sessionId)
                    return
                }

                if remaining <= 0 {
                    self.logger.log("DeadSessionDetector[HF]: watchdog TIMEOUT for \(sessionId) after \(Int(elapsed))s",
                                   category: .webView, level: .critical, sessionId: sessionId)
                    await onTimeout()
                    self.cleanupWatchdog(sessionId: sessionId)
                    return
                }

                if remaining < timeout * 0.3 {
                    let webView = webViewProvider()
                    let alive = await self.isSessionAlive(webView, sessionId: sessionId)
                    if !alive {
                        self.logger.log("DeadSessionDetector[HF]: HUNG session \(sessionId) — early timeout",
                                       category: .webView, level: .error, sessionId: sessionId)
                        await onTimeout()
                        self.cleanupWatchdog(sessionId: sessionId)
                        return
                    }
                }
            }

            self.cleanupWatchdog(sessionId: sessionId)
        }

        activeWatchdogs[sessionId] = task
    }

    func stopWatchdog(sessionId: String) {
        if let existing = activeWatchdogs[sessionId] {
            existing.cancel()
            cleanupWatchdog(sessionId: sessionId)
        }
    }

    func stopAllWatchdogs() {
        for (sessionId, task) in activeWatchdogs {
            task.cancel()
            sessionStartTimes.removeValue(forKey: sessionId)
            activityMonitor.stopMonitoring(sessionId: sessionId)
        }
        activeWatchdogs.removeAll()
        logger.log("DeadSessionDetector[HF]: all watchdogs stopped", category: .webView, level: .info)
    }

    var activeWatchdogCount: Int {
        activeWatchdogs.count
    }

    func activeWatchdogSessions() -> [(sessionId: String, elapsedSeconds: Int)] {
        sessionStartTimes.compactMap { sessionId, startTime in
            guard activeWatchdogs[sessionId] != nil else { return nil }
            return (sessionId, Int(Date().timeIntervalSince(startTime)))
        }.sorted { $0.elapsedSeconds > $1.elapsedSeconds }
    }

    private func cleanupWatchdog(sessionId: String) {
        activeWatchdogs.removeValue(forKey: sessionId)
        sessionStartTimes.removeValue(forKey: sessionId)
        activityMonitor.stopMonitoring(sessionId: sessionId)
    }
}

// MARK: - 6. SessionActivityMonitor Compatibility Bridge

/// Full-fidelity reproduction of the SessionActivityMonitor API.
@MainActor
class SessionActivityMonitor {
    static let shared = SessionActivityMonitor()

    private let logger = DebugLogger.shared
    private var sessions: [String: SessionActivity] = [:]

    private struct SessionActivity {
        var lastActivityAt: Date
        var navigationEvents: Int = 0
        var resourceLoads: Int = 0
        var jsResponses: Int = 0
        var domChanges: Int = 0
        var hasEverHadActivity: Bool = false

        var totalEvents: Int {
            navigationEvents + resourceLoads + jsResponses + domChanges
        }

        var secondsSinceLastActivity: TimeInterval {
            Date().timeIntervalSince(lastActivityAt)
        }
    }

    static let activeTimeoutSeconds: TimeInterval = 180
    static let idleThresholdSeconds: TimeInterval = 15
    static let idleRetryDelaySeconds: TimeInterval = 1

    func startMonitoring(sessionId: String) {
        sessions[sessionId] = SessionActivity(lastActivityAt: Date())
    }

    func stopMonitoring(sessionId: String) {
        sessions.removeValue(forKey: sessionId)
    }

    func recordNavigation(sessionId: String) {
        guard var activity = sessions[sessionId] else { return }
        activity.lastActivityAt = Date()
        activity.navigationEvents += 1
        activity.hasEverHadActivity = true
        sessions[sessionId] = activity
    }

    func recordResourceLoad(sessionId: String) {
        guard var activity = sessions[sessionId] else { return }
        activity.lastActivityAt = Date()
        activity.resourceLoads += 1
        activity.hasEverHadActivity = true
        sessions[sessionId] = activity
    }

    func recordJSResponse(sessionId: String) {
        guard var activity = sessions[sessionId] else { return }
        activity.lastActivityAt = Date()
        activity.jsResponses += 1
        activity.hasEverHadActivity = true
        sessions[sessionId] = activity
    }

    func recordDOMChange(sessionId: String) {
        guard var activity = sessions[sessionId] else { return }
        activity.lastActivityAt = Date()
        activity.domChanges += 1
        activity.hasEverHadActivity = true
        sessions[sessionId] = activity
    }

    func recordActivity(sessionId: String) {
        guard var activity = sessions[sessionId] else { return }
        activity.lastActivityAt = Date()
        activity.hasEverHadActivity = true
        sessions[sessionId] = activity
    }

    func hasActivity(sessionId: String) -> Bool {
        guard let activity = sessions[sessionId] else { return false }
        return activity.hasEverHadActivity
    }

    func isIdle(sessionId: String) -> Bool {
        guard let activity = sessions[sessionId] else { return true }
        return activity.secondsSinceLastActivity >= Self.idleThresholdSeconds
    }

    func secondsSinceLastActivity(sessionId: String) -> TimeInterval {
        guard let activity = sessions[sessionId] else { return .infinity }
        return activity.secondsSinceLastActivity
    }

    nonisolated enum IdleCheckResult: Sendable {
        case active
        case idle(secondsIdle: TimeInterval)
        case noSession
    }

    func checkIdleStatus(sessionId: String) -> IdleCheckResult {
        guard let activity = sessions[sessionId] else { return .noSession }
        let idle = activity.secondsSinceLastActivity
        if idle >= Self.idleThresholdSeconds && !activity.hasEverHadActivity {
            return .idle(secondsIdle: idle)
        }
        if activity.hasEverHadActivity && idle >= Self.idleThresholdSeconds {
            return .idle(secondsIdle: idle)
        }
        return .active
    }

    func stopAll() {
        sessions.removeAll()
    }

    func summary(sessionId: String) -> String {
        guard let activity = sessions[sessionId] else { return "no session" }
        return "nav:\(activity.navigationEvents) res:\(activity.resourceLoads) js:\(activity.jsResponses) dom:\(activity.domChanges) idle:\(Int(activity.secondsSinceLastActivity))s"
    }
}
