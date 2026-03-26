import Foundation
import SwiftUI
import WebKit
import UIKit

struct SplitWebViewRepresentable: UIViewRepresentable {
    let url: URL
    let stealthEnabled: Bool
    let automationSettings: AutomationSettings
    @Binding var isLoading: Bool
    @Binding var pageTitle: String
    @Binding var currentURL: String
    var onWebViewCreated: ((WKWebView) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        var stealthProfile: PPSRStealthService.SessionProfile?
        if stealthEnabled && automationSettings.stealthJSInjection {
            let stealth = PPSRStealthService.shared
            stealth.applySettings(automationSettings)
            let profile = stealth.nextProfile()
            stealthProfile = profile
            let userScript = stealth.createStealthUserScript(profile: profile)
            config.userContentController.addUserScript(userScript)
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        if let profile = stealthProfile {
            webView.customUserAgent = profile.userAgent
        } else if automationSettings.userAgentRotation {
            webView.customUserAgent = PPSRStealthService.shared.nextUserAgent()
        }

        context.coordinator.webView = webView
        context.coordinator.automationSettings = automationSettings
        context.coordinator.startObserving()

        let request = URLRequest(url: url)
        webView.load(request)

        Task { @MainActor in
            onWebViewCreated?(webView)
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: SplitWebViewRepresentable
        weak var webView: WKWebView?
        var automationSettings: AutomationSettings = AutomationSettings()
        private var titleObservation: NSKeyValueObservation?
        private var urlObservation: NSKeyValueObservation?
        private var loadingObservation: NSKeyValueObservation?

        init(parent: SplitWebViewRepresentable) {
            self.parent = parent
        }

        func startObserving() {
            guard let webView else { return }

            loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                let loading = wv.isLoading
                guard let self else { return }
                Task { @MainActor [weak self] in
                    self?.parent.isLoading = loading
                }
            }

            titleObservation = webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                let title = wv.title ?? ""
                guard let self else { return }
                Task { @MainActor [weak self] in
                    self?.parent.pageTitle = title
                }
            }

            urlObservation = webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                let urlString = wv.url?.host ?? wv.url?.absoluteString ?? ""
                guard let self else { return }
                Task { @MainActor [weak self] in
                    self?.parent.currentURL = urlString
                }
            }
        }

        nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                parent.isLoading = false
                parent.pageTitle = webView.title ?? ""
                parent.currentURL = webView.url?.host ?? ""

                if parent.automationSettings.dismissCookieNotices {
                    let cookieJS = """
                    (function(){
                        var selectors = ['[class*="cookie"]','[id*="cookie"]','[class*="consent"]','[id*="consent"]','[class*="gdpr"]','[class*="notice"]','[class*="banner"]'];
                        selectors.forEach(function(s){
                            document.querySelectorAll(s).forEach(function(el){
                                var r=el.getBoundingClientRect();
                                if(r.height>20&&r.height<300){el.style.display='none';}
                            });
                        });
                        var btns=document.querySelectorAll('button,a,[role="button"]');
                        var acceptTerms=['accept','agree','got it','ok','i understand','allow','consent','continue'];
                        btns.forEach(function(b){
                            var t=(b.textContent||'').toLowerCase().trim();
                            if(acceptTerms.some(function(at){return t.indexOf(at)!==-1&&t.length<40;})){try{b.click();}catch(e){}}
                        });
                    })();
                    """
                    _ = try? await webView.evaluateJavaScript(cookieJS)
                }
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                parent.isLoading = false
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                parent.isLoading = false
            }
        }
    }
}
