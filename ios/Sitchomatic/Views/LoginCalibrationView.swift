import Foundation
import SwiftUI
import WebKit
import UIKit

struct LoginCalibrationView: View {
    let urlString: String
    var onComplete: ((LoginCalibrationService.URLCalibration) -> Void)?

    @State var calibrationStep: CalibrationStep = .loading
    @State private var emailMapping: LoginCalibrationService.ElementMapping?
    @State private var passwordMapping: LoginCalibrationService.ElementMapping?
    @State private var buttonMapping: LoginCalibrationService.ElementMapping?
    @State private var statusMessage: String = "Loading page..."
    @State private var pageLoaded: Bool = false
    @State private var webViewCoordinator: CalibrationWebViewCoordinator?
    @State private var showAutoProbeResult: Bool = false
    @State private var autoProbeSuccess: Bool = false
    @State private var probeDetail: String = ""
    @Environment(\.dismiss) private var dismiss

    enum CalibrationStep: String {
        case loading = "Loading Page"
        case autoProbing = "Auto-Detecting Elements"
        case tapEmail = "Tap the Email/Username Field"
        case tapPassword = "Tap the Password Field"
        case tapButton = "Tap the Login Button"
        case testFill = "Testing Fill..."
        case complete = "Calibration Complete"
        case failed = "Calibration Failed"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stepIndicator
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                statusBar

                CalibrationWebViewRepresentable(
                    urlString: urlString,
                    onPageLoaded: handlePageLoaded,
                    onElementTapped: handleElementTapped,
                    onCoordinator: { webViewCoordinator = $0 }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomBar
                    .padding(16)
            }
            .navigationTitle("Calibrate URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if calibrationStep == .complete {
                        Button("Save") { saveCalibration() }
                            .fontWeight(.semibold)
                    }
                }
            }
            .alert("Auto-Probe Result", isPresented: $showAutoProbeResult) {
                Button("Use Auto-Detected") { advanceToComplete() }
                    .disabled(!autoProbeSuccess)
                Button("Manual Calibration") { calibrationStep = .tapEmail }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(probeDetail)
            }
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            stepDot(active: calibrationStep == .tapEmail, done: emailMapping != nil, label: "Email")
            stepConnector(done: emailMapping != nil)
            stepDot(active: calibrationStep == .tapPassword, done: passwordMapping != nil, label: "Password")
            stepConnector(done: passwordMapping != nil)
            stepDot(active: calibrationStep == .tapButton, done: buttonMapping != nil, label: "Button")
        }
    }

    private func stepDot(active: Bool, done: Bool, label: String) -> some View {
        VStack(spacing: 4) {
            Circle()
                .fill(done ? Color.green : active ? Color.blue : Color(.tertiaryLabel))
                .frame(width: 12, height: 12)
                .overlay {
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            Text(label)
                .font(.caption2)
                .foregroundStyle(active ? .primary : .secondary)
        }
    }

    private func stepConnector(done: Bool) -> some View {
        Rectangle()
            .fill(done ? Color.green : Color(.tertiaryLabel))
            .frame(height: 2)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 16)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if calibrationStep == .loading || calibrationStep == .autoProbing || calibrationStep == .testFill {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
            }
            Text(calibrationStep.rawValue)
                .font(.subheadline.weight(.medium))
            Spacer()
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private var statusIcon: String {
        switch calibrationStep {
        case .tapEmail: return "envelope.fill"
        case .tapPassword: return "lock.fill"
        case .tapButton: return "hand.tap.fill"
        case .complete: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        default: return "circle"
        }
    }

    private var statusColor: Color {
        switch calibrationStep {
        case .complete: return .green
        case .failed: return .red
        default: return .blue
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            if calibrationStep == .tapEmail || calibrationStep == .tapPassword || calibrationStep == .tapButton {
                Text("Tap directly on the \(elementName) in the page above")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                if canGoBack {
                    Button {
                        goBack()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                }

                if calibrationStep == .tapEmail || calibrationStep == .tapPassword || calibrationStep == .tapButton {
                    Button {
                        skipStep()
                    } label: {
                        Text("Skip (use auto)")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }

                Spacer()

                if pageLoaded && calibrationStep == .loading {
                    Button {
                        runAutoProbe()
                    } label: {
                        Label("Auto-Detect", systemImage: "wand.and.stars")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                }

                if calibrationStep == .failed {
                    Button {
                        calibrationStep = .tapEmail
                        statusMessage = ""
                    } label: {
                        Label("Retry Manual", systemImage: "arrow.counterclockwise")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var elementName: String {
        switch calibrationStep {
        case .tapEmail: return "email/username field"
        case .tapPassword: return "password field"
        case .tapButton: return "login button"
        default: return "element"
        }
    }

    private var canGoBack: Bool {
        calibrationStep == .tapPassword || calibrationStep == .tapButton
    }

    private func goBack() {
        switch calibrationStep {
        case .tapPassword:
            emailMapping = nil
            calibrationStep = .tapEmail
        case .tapButton:
            passwordMapping = nil
            calibrationStep = .tapPassword
        default: break
        }
    }

    private func skipStep() {
        switch calibrationStep {
        case .tapEmail:
            emailMapping = LoginCalibrationService.ElementMapping(cssSelector: "input[type='email'], input[type='text']")
            calibrationStep = .tapPassword
        case .tapPassword:
            passwordMapping = LoginCalibrationService.ElementMapping(cssSelector: "input[type='password']")
            calibrationStep = .tapButton
        case .tapButton:
            buttonMapping = LoginCalibrationService.ElementMapping(cssSelector: "button[type='submit'], button")
            advanceToComplete()
        default: break
        }
    }

    private func handlePageLoaded() {
        pageLoaded = true
        statusMessage = "Page loaded — ready to calibrate"
        if calibrationStep == .loading {
            runAutoProbe()
        }
    }

    private func runAutoProbe() {
        calibrationStep = .autoProbing
        statusMessage = "Probing DOM structure..."
        Task {
            guard let coordinator = webViewCoordinator else {
                calibrationStep = .tapEmail
                statusMessage = "Auto-probe unavailable"
                return
            }
            let result = await coordinator.runDeepDOMProbe()
            if let emailSel = result.emailSelector, let passwordSel = result.passwordSelector, let buttonSel = result.buttonSelector {
                emailMapping = LoginCalibrationService.ElementMapping(
                    cssSelector: emailSel,
                    fallbackSelectors: result.emailFallbacks,
                    tagName: "INPUT",
                    inputType: "email"
                )
                passwordMapping = LoginCalibrationService.ElementMapping(
                    cssSelector: passwordSel,
                    fallbackSelectors: result.passwordFallbacks,
                    tagName: "INPUT",
                    inputType: "password"
                )
                buttonMapping = LoginCalibrationService.ElementMapping(
                    cssSelector: buttonSel,
                    fallbackSelectors: result.buttonFallbacks,
                    nearbyText: result.buttonText
                )
                autoProbeSuccess = true
                probeDetail = "Found all 3 elements:\n• Email: \(emailSel)\n• Password: \(passwordSel)\n• Button: \(result.buttonText ?? buttonSel)"
            } else {
                autoProbeSuccess = false
                var missing: [String] = []
                if result.emailSelector == nil { missing.append("email") }
                if result.passwordSelector == nil { missing.append("password") }
                if result.buttonSelector == nil { missing.append("login button") }
                probeDetail = "Could not auto-detect: \(missing.joined(separator: ", "))\n\nUse manual calibration to tap each element."
            }
            showAutoProbeResult = true
        }
    }

    private func handleElementTapped(_ info: TappedElementInfo) {
        let mapping = LoginCalibrationService.ElementMapping(
            cssSelector: info.bestSelector,
            fallbackSelectors: info.fallbackSelectors,
            coordinates: CGPoint(x: info.x, y: info.y),
            tagName: info.tagName,
            inputType: info.inputType,
            placeholder: info.placeholder,
            ariaLabel: info.ariaLabel,
            nearbyText: info.nearbyText
        )

        switch calibrationStep {
        case .tapEmail:
            emailMapping = mapping
            statusMessage = "Email field: \(info.bestSelector)"
            calibrationStep = .tapPassword
        case .tapPassword:
            passwordMapping = mapping
            statusMessage = "Password field: \(info.bestSelector)"
            calibrationStep = .tapButton
        case .tapButton:
            buttonMapping = mapping
            statusMessage = "Login button: \(info.nearbyText ?? info.bestSelector)"
            advanceToComplete()
        default: break
        }
    }

    private func advanceToComplete() {
        calibrationStep = .complete
        statusMessage = "All elements mapped — tap Save"
    }

    private func saveCalibration() {
        let cal = LoginCalibrationService.URLCalibration(
            urlPattern: URL(string: urlString)?.host ?? urlString,
            emailField: emailMapping,
            passwordField: passwordMapping,
            loginButton: buttonMapping,
            calibratedAt: Date()
        )
        LoginCalibrationService.shared.saveCalibration(cal, forURL: urlString)

        let allJoeURLs = LoginURLRotationService.defaultJoeURLStrings
        let allIgnitionURLs = LoginURLRotationService.defaultIgnitionURLStrings
        let isJoe = allJoeURLs.contains(where: { $0.contains(URL(string: urlString)?.host ?? "") })
        let targets = isJoe ? allJoeURLs : allIgnitionURLs
        LoginCalibrationService.shared.propagateCalibration(from: urlString, to: targets)

        onComplete?(cal)
        dismiss()
    }
}

struct TappedElementInfo {
    let x: Double
    let y: Double
    let tagName: String
    let inputType: String?
    let bestSelector: String
    let fallbackSelectors: [String]
    let placeholder: String?
    let ariaLabel: String?
    let nearbyText: String?
}

struct DOMProbeResult {
    let emailSelector: String?
    let emailFallbacks: [String]
    let passwordSelector: String?
    let passwordFallbacks: [String]
    let buttonSelector: String?
    let buttonFallbacks: [String]
    let buttonText: String?
    let pageStructureHash: String?
}

@MainActor
class CalibrationWebViewCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var webView: WKWebView?
    var onPageLoaded: (() -> Void)?
    var onElementTapped: ((TappedElementInfo) -> Void)?
    var calibrationStep: Binding<CalibrationStep>?
    private var pageLoadContinuation: CheckedContinuation<Bool, Never>?

    nonisolated enum CalibrationStep: String {
        case loading, autoProbing, tapEmail, tapPassword, tapButton, testFill, complete, failed
    }

    @discardableResult
    func setupWebView(urlString: String) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let tapScript = WKUserScript(source: Self.tapInterceptJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(tapScript)
        config.userContentController.add(self, name: "calibrationTap")

        let stealth = PPSRStealthService.shared
        let profile = stealth.nextProfile()
        let stealthScript = stealth.createStealthUserScript(profile: profile)
        config.userContentController.addUserScript(stealthScript)

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.navigationDelegate = self
        wv.customUserAgent = profile.userAgent
        self.webView = wv

        if let url = URL(string: urlString) {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
            wv.load(request)
        }

        return wv
    }

    static let tapInterceptJS = """
    (function() {
        document.addEventListener('click', function(e) {
            e.preventDefault();
            e.stopPropagation();
            e.stopImmediatePropagation();

            var el = e.target;
            var info = {
                x: e.clientX,
                y: e.clientY,
                tagName: el.tagName || '',
                inputType: el.type || null,
                id: el.id || '',
                name: el.name || '',
                className: (el.className && typeof el.className === 'string') ? el.className : '',
                placeholder: el.placeholder || null,
                ariaLabel: el.getAttribute('aria-label') || null,
                textContent: (el.textContent || '').trim().substring(0, 50),
                parentTag: el.parentElement ? el.parentElement.tagName : '',
                parentId: el.parentElement ? (el.parentElement.id || '') : '',
                parentClass: el.parentElement ? ((el.parentElement.className && typeof el.parentElement.className === 'string') ? el.parentElement.className : '') : '',
                dataAttrs: {}
            };
            for (var i = 0; i < el.attributes.length; i++) {
                var attr = el.attributes[i];
                if (attr.name.startsWith('data-')) {
                    info.dataAttrs[attr.name] = attr.value;
                }
            }
            window.webkit.messageHandlers.calibrationTap.postMessage(JSON.stringify(info));
        }, true);

        document.addEventListener('touchend', function(e) {
            if (e.touches.length === 0 && e.changedTouches.length > 0) {
                var touch = e.changedTouches[0];
                var el = document.elementFromPoint(touch.clientX, touch.clientY);
                if (!el) return;
                var info = {
                    x: touch.clientX,
                    y: touch.clientY,
                    tagName: el.tagName || '',
                    inputType: el.type || null,
                    id: el.id || '',
                    name: el.name || '',
                    className: (el.className && typeof el.className === 'string') ? el.className : '',
                    placeholder: el.placeholder || null,
                    ariaLabel: el.getAttribute('aria-label') || null,
                    textContent: (el.textContent || '').trim().substring(0, 50),
                    parentTag: el.parentElement ? el.parentElement.tagName : '',
                    parentId: el.parentElement ? (el.parentElement.id || '') : '',
                    parentClass: el.parentElement ? ((el.parentElement.className && typeof el.parentElement.className === 'string') ? el.parentElement.className : '') : '',
                    dataAttrs: {}
                };
                for (var i = 0; i < el.attributes.length; i++) {
                    var attr = el.attributes[i];
                    if (attr.name.startsWith('data-')) {
                        info.dataAttrs[attr.name] = attr.value;
                    }
                }
                window.webkit.messageHandlers.calibrationTap.postMessage(JSON.stringify(info));
            }
        }, true);
    })();
    """

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "calibrationTap" else { return }
        guard let body = message.body as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let x = json["x"] as? Double ?? 0
        let y = json["y"] as? Double ?? 0
        let tagName = json["tagName"] as? String ?? ""
        let inputType = json["inputType"] as? String
        let id = json["id"] as? String ?? ""
        let name = json["name"] as? String ?? ""
        let className = json["className"] as? String ?? ""
        let placeholder = json["placeholder"] as? String
        let ariaLabel = json["ariaLabel"] as? String
        let textContent = json["textContent"] as? String
        let parentId = json["parentId"] as? String ?? ""
        let parentClass = json["parentClass"] as? String ?? ""

        var bestSelector = ""
        var fallbacks: [String] = []

        if !id.isEmpty {
            bestSelector = "#\(id)"
        } else if !name.isEmpty {
            bestSelector = "\(tagName.lowercased())[name='\(name)']"
        } else if let iType = inputType, !iType.isEmpty {
            bestSelector = "input[type='\(iType)']"
        }

        if let p = placeholder, !p.isEmpty {
            fallbacks.append("\(tagName.lowercased())[placeholder*='\(p.prefix(20))']")
        }
        if let aria = ariaLabel, !aria.isEmpty {
            fallbacks.append("[aria-label*='\(aria.prefix(20))']")
        }
        if !className.isEmpty {
            let firstClass = className.components(separatedBy: " ").first(where: { !$0.isEmpty }) ?? ""
            if !firstClass.isEmpty {
                fallbacks.append(".\(firstClass)")
            }
        }
        if !parentId.isEmpty {
            fallbacks.append("#\(parentId) \(tagName.lowercased())")
        }

        if bestSelector.isEmpty && !fallbacks.isEmpty {
            bestSelector = fallbacks.removeFirst()
        }
        if bestSelector.isEmpty {
            bestSelector = tagName.lowercased()
        }

        let info = TappedElementInfo(
            x: x, y: y,
            tagName: tagName,
            inputType: inputType,
            bestSelector: bestSelector,
            fallbackSelectors: fallbacks,
            placeholder: placeholder,
            ariaLabel: ariaLabel,
            nearbyText: textContent
        )

        Task { @MainActor in
            self.onElementTapped?(info)
        }
    }

    func runDeepDOMProbe() async -> DOMProbeResult {
        guard let wv = webView else {
            return DOMProbeResult(emailSelector: nil, emailFallbacks: [], passwordSelector: nil, passwordFallbacks: [], buttonSelector: nil, buttonFallbacks: [], buttonText: nil, pageStructureHash: nil)
        }

        let probeJS = """
        (function() {
            var result = {email: null, emailFallbacks: [], password: null, passwordFallbacks: [], button: null, buttonFallbacks: [], buttonText: null, hash: ''};

            // Email field detection
            var emailStrategies = [
                function() { return document.querySelector('input[type="email"]'); },
                function() { return document.querySelector('input[autocomplete="email"]'); },
                function() { return document.querySelector('input[autocomplete="username"]'); },
                function() { return document.querySelector('input[name="email"]'); },
                function() { return document.querySelector('input[name="username"]'); },
                function() { return document.querySelector('input[name="login"]'); },
                function() { return document.querySelector('input[id="email"]'); },
                function() { return document.querySelector('input[id="username"]'); },
                function() { return document.querySelector('input[id="login-email"]'); },
                function() { return document.querySelector('input[id="loginEmail"]'); },
                function() { return document.querySelector('input[placeholder*="Email" i]'); },
                function() { return document.querySelector('input[placeholder*="email" i]'); },
                function() { return document.querySelector('input[placeholder*="Username" i]'); },
                function() { return document.querySelector('input[placeholder*="Login" i]'); },
                function() { return document.querySelector('input[aria-label*="email" i]'); },
                function() { return document.querySelector('input[aria-label*="username" i]'); },
                function() {
                    var forms = document.querySelectorAll('form');
                    for (var f = 0; f < forms.length; f++) {
                        var passField = forms[f].querySelector('input[type="password"]');
                        if (passField) {
                            var textInputs = forms[f].querySelectorAll('input[type="text"], input[type="email"], input:not([type])');
                            for (var i = 0; i < textInputs.length; i++) {
                                if (textInputs[i] !== passField) return textInputs[i];
                            }
                        }
                    }
                    return null;
                },
                function() { return document.querySelector('form input[type="text"]'); },
                function() { return document.querySelector('input[type="text"]'); }
            ];

            for (var i = 0; i < emailStrategies.length; i++) {
                try {
                    var el = emailStrategies[i]();
                    if (el && !el.disabled && (el.offsetParent !== null || el.offsetWidth > 0)) {
                        result.email = buildSelector(el);
                        result.emailFallbacks = buildFallbacks(el);
                        break;
                    }
                } catch(e) {}
            }

            // Password field detection
            var passStrategies = [
                function() { return document.querySelector('input[type="password"]'); },
                function() { return document.querySelector('input[autocomplete="current-password"]'); },
                function() { return document.querySelector('input[name="password"]'); },
                function() { return document.querySelector('input[id="password"]'); },
                function() { return document.querySelector('input[placeholder*="Password" i]'); },
                function() { return document.querySelector('input[placeholder*="password" i]'); }
            ];

            for (var i = 0; i < passStrategies.length; i++) {
                try {
                    var el = passStrategies[i]();
                    if (el && !el.disabled && (el.offsetParent !== null || el.offsetWidth > 0)) {
                        result.password = buildSelector(el);
                        result.passwordFallbacks = buildFallbacks(el);
                        break;
                    }
                } catch(e) {}
            }

            // Login button detection
            var loginTerms = ['log in', 'login', 'sign in', 'signin'];
            var btnStrategies = [
                function() {
                    var allBtn = document.querySelectorAll('button, input[type="submit"], a[role="button"], [role="button"]');
                    for (var i = 0; i < allBtn.length; i++) {
                        var text = (allBtn[i].textContent || allBtn[i].value || '').replace(/[\\s]+/g, ' ').toLowerCase().trim();
                        if (text.length > 50) continue;
                        for (var t = 0; t < loginTerms.length; t++) {
                            if (text === loginTerms[t]) {
                                result.buttonText = (allBtn[i].textContent || allBtn[i].value || '').trim().substring(0, 30);
                                return allBtn[i];
                            }
                        }
                    }
                    return null;
                },
                function() {
                    var allBtn = document.querySelectorAll('button, input[type="submit"], a, [role="button"], span, div');
                    for (var i = 0; i < allBtn.length; i++) {
                        var text = (allBtn[i].textContent || allBtn[i].value || '').replace(/[\\s]+/g, ' ').toLowerCase().trim();
                        if (text.length > 30) continue;
                        for (var t = 0; t < loginTerms.length; t++) {
                            if (text.indexOf(loginTerms[t]) !== -1) {
                                result.buttonText = (allBtn[i].textContent || allBtn[i].value || '').trim().substring(0, 30);
                                return allBtn[i];
                            }
                        }
                    }
                    return null;
                },
                function() {
                    var selectors = [
                        '[class*="login"][class*="btn"]', '[class*="login"][class*="button"]',
                        '[class*="sign"][class*="btn"]', '[class*="submit"][class*="btn"]',
                        '#loginButton', '#loginBtn', '#login-button', '#btn-login',
                        '#signInButton', '#submitBtn', 'button.login', 'button.signin',
                        '[data-action="login"]', '[data-action="signin"]',
                        '[aria-label*="Log In"]', '[aria-label*="Login"]', '[aria-label*="Sign In"]'
                    ];
                    for (var s = 0; s < selectors.length; s++) {
                        try {
                            var el = document.querySelector(selectors[s]);
                            if (el) {
                                result.buttonText = (el.textContent || el.value || '').trim().substring(0, 30);
                                return el;
                            }
                        } catch(e) {}
                    }
                    return null;
                },
                function() {
                    var forms = document.querySelectorAll('form');
                    for (var f = 0; f < forms.length; f++) {
                        if (forms[f].querySelector('input[type="password"]')) {
                            var btn = forms[f].querySelector('button[type="submit"]') || forms[f].querySelector('input[type="submit"]') || forms[f].querySelector('button');
                            if (btn) {
                                result.buttonText = (btn.textContent || btn.value || '').trim().substring(0, 30);
                                return btn;
                            }
                        }
                    }
                    return null;
                },
                function() {
                    var btn = document.querySelector('button[type="submit"]') || document.querySelector('input[type="submit"]');
                    if (btn) result.buttonText = (btn.textContent || btn.value || '').trim().substring(0, 30);
                    return btn;
                }
            ];

            for (var i = 0; i < btnStrategies.length; i++) {
                try {
                    var el = btnStrategies[i]();
                    if (el) {
                        result.button = buildSelector(el);
                        result.buttonFallbacks = buildFallbacks(el);
                        break;
                    }
                } catch(e) {}
            }

            var inputs = document.querySelectorAll('input, button, select, textarea, [role="button"]');
            var hashParts = [];
            for (var i = 0; i < Math.min(inputs.length, 30); i++) {
                hashParts.push(inputs[i].tagName + ':' + (inputs[i].type || '') + ':' + (inputs[i].id || '').substring(0, 10));
            }
            result.hash = hashParts.join('|');

            return JSON.stringify(result);

            function buildSelector(el) {
                if (el.id) return '#' + el.id;
                if (el.name) return el.tagName.toLowerCase() + '[name="' + el.name + '"]';
                if (el.type && el.tagName === 'INPUT') return 'input[type="' + el.type + '"]';
                if (el.placeholder) return el.tagName.toLowerCase() + '[placeholder*="' + el.placeholder.substring(0, 15) + '"]';
                if (el.getAttribute('aria-label')) return '[aria-label*="' + el.getAttribute('aria-label').substring(0, 15) + '"]';
                var cls = (el.className && typeof el.className === 'string') ? el.className.trim().split(/\\s+/)[0] : '';
                if (cls) return el.tagName.toLowerCase() + '.' + cls;
                return el.tagName.toLowerCase();
            }

            function buildFallbacks(el) {
                var fb = [];
                if (el.id) fb.push('#' + el.id);
                if (el.name) fb.push(el.tagName.toLowerCase() + '[name="' + el.name + '"]');
                if (el.type && el.tagName === 'INPUT') fb.push('input[type="' + el.type + '"]');
                if (el.placeholder) fb.push('[placeholder*="' + el.placeholder.substring(0, 15) + '"]');
                if (el.getAttribute('aria-label')) fb.push('[aria-label*="' + el.getAttribute('aria-label').substring(0, 15) + '"]');
                var cls = (el.className && typeof el.className === 'string') ? el.className.trim().split(/\\s+/)[0] : '';
                if (cls) fb.push('.' + cls);
                return fb;
            }
        })();
        """

        do {
            let resultRaw = try await wv.evaluateJavaScript(probeJS)
            guard let resultStr = resultRaw as? String,
                  let resultData = resultStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
                return DOMProbeResult(emailSelector: nil, emailFallbacks: [], passwordSelector: nil, passwordFallbacks: [], buttonSelector: nil, buttonFallbacks: [], buttonText: nil, pageStructureHash: nil)
            }

            return DOMProbeResult(
                emailSelector: json["email"] as? String,
                emailFallbacks: json["emailFallbacks"] as? [String] ?? [],
                passwordSelector: json["password"] as? String,
                passwordFallbacks: json["passwordFallbacks"] as? [String] ?? [],
                buttonSelector: json["button"] as? String,
                buttonFallbacks: json["buttonFallbacks"] as? [String] ?? [],
                buttonText: json["buttonText"] as? String,
                pageStructureHash: json["hash"] as? String
            )
        } catch {
            return DOMProbeResult(emailSelector: nil, emailFallbacks: [], passwordSelector: nil, passwordFallbacks: [], buttonSelector: nil, buttonFallbacks: [], buttonText: nil, pageStructureHash: nil)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.onPageLoaded?()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.onPageLoaded?()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.onPageLoaded?()
        }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(.allow)
    }
}

struct CalibrationWebViewRepresentable: UIViewRepresentable {
    let urlString: String
    var onPageLoaded: () -> Void
    var onElementTapped: (TappedElementInfo) -> Void
    var onCoordinator: (CalibrationWebViewCoordinator) -> Void

    func makeCoordinator() -> CalibrationWebViewCoordinator {
        let coordinator = CalibrationWebViewCoordinator()
        coordinator.onPageLoaded = onPageLoaded
        coordinator.onElementTapped = onElementTapped
        return coordinator
    }

    func makeUIView(context: Context) -> WKWebView {
        let wv = context.coordinator.setupWebView(urlString: urlString)
        Task { @MainActor in
            onCoordinator(context.coordinator)
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.onElementTapped = onElementTapped
    }
}
