import Foundation
import WebKit

// MARK: - JavaScript Injector (nonisolated Bridge)

/// Provides thread-safe JavaScript evaluation bridges between actor-isolated
/// automation engines and `@MainActor`-bound WKWebView instances.
///
/// All public methods are `nonisolated` to allow calling from any actor or
/// task context. The actual WKWebView JavaScript evaluation is dispatched
/// to `@MainActor` internally, bridging the isolation boundary cleanly.
///
/// This replaces scattered JS evaluation patterns found in
/// `LoginJSBuilder`, `JSInteractionBuilder`, and `DebugClickJSFactory`
/// with a unified injection API.
public struct JavaScriptInjector: Sendable {

    public init() {}

    // MARK: - Core Evaluation

    /// Evaluates JavaScript on a WKWebView from any isolation context.
    /// Dispatches to `@MainActor` internally for thread safety.
    ///
    /// - Parameters:
    ///   - script: The JavaScript source to evaluate
    ///   - webView: The target WKWebView (must be accessed on MainActor)
    /// - Returns: The JavaScript evaluation result, or nil
    @MainActor
    public func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    /// Evaluates JavaScript and returns a typed String result.
    @MainActor
    public func evaluateString(_ script: String, in webView: WKWebView) async -> String? {
        return try? await evaluate(script, in: webView) as? String
    }

    /// Evaluates JavaScript and returns a typed Bool result.
    @MainActor
    public func evaluateBool(_ script: String, in webView: WKWebView) async -> Bool {
        return (try? await evaluate(script, in: webView) as? Bool) ?? false
    }

    // MARK: - Stealth Injection Helpers

    /// Injects a stealth script that hides the `webdriver` navigator property.
    @MainActor
    public func injectWebDriverHide(in webView: WKWebView) async {
        let script = """
        Object.defineProperty(navigator, 'webdriver', {
            get: () => false,
            configurable: false,
            enumerable: true
        });
        """
        _ = try? await evaluate(script, in: webView)
    }

    /// Injects custom CSS to hide automation-related UI artifacts.
    @MainActor
    public func injectStealthCSS(in webView: WKWebView) async {
        let script = """
        (function() {
            const style = document.createElement('style');
            style.textContent = `
                [data-selenium], [data-webdriver], .automation-overlay { display: none !important; }
            `;
            (document.head || document.documentElement).appendChild(style);
        })();
        """
        _ = try? await evaluate(script, in: webView)
    }

    // MARK: - DOM Interaction Helpers

    /// Clicks an element by CSS selector using a synthesized event chain.
    /// Dispatches pointer, mouse, and click events in the correct order
    /// to defeat event-listener-based bot detection.
    @MainActor
    public func clickElement(selector: String, in webView: WKWebView) async -> Bool {
        let script = """
        (function() {
            const el = document.querySelector('\(selector.replacingOccurrences(of: "'", with: "\\'"))');
            if (!el) return false;
            const rect = el.getBoundingClientRect();
            const x = rect.left + rect.width / 2;
            const y = rect.top + rect.height / 2;
            const events = ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'];
            events.forEach(type => {
                el.dispatchEvent(new PointerEvent(type, {
                    bubbles: true, cancelable: true, view: window,
                    clientX: x, clientY: y, pointerId: 1, pointerType: 'touch'
                }));
            });
            return true;
        })();
        """
        return await evaluateBool(script, in: webView)
    }

    /// Fills a text field by selector using native input setter + event dispatch.
    /// Uses the property descriptor pattern to trigger React/Angular change detection.
    @MainActor
    public func fillField(selector: String, value: String, in webView: WKWebView) async -> Bool {
        let escapedValue = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        let script = """
        (function() {
            const el = document.querySelector('\(selector.replacingOccurrences(of: "'", with: "\\'"))');
            if (!el) return false;
            el.focus();
            const nativeInputValueSetter = Object.getOwnPropertyDescriptor(
                window.HTMLInputElement.prototype, 'value'
            ).set;
            nativeInputValueSetter.call(el, '\(escapedValue)');
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return true;
        })();
        """
        return await evaluateBool(script, in: webView)
    }

    /// Extracts the full DOM HTML for parsing by DualFindEngine.
    @MainActor
    public func extractDOM(in webView: WKWebView) async -> String? {
        return await evaluateString("document.documentElement.outerHTML", in: webView)
    }

    /// Checks if a page has finished loading (document.readyState === 'complete').
    @MainActor
    public func isPageReady(in webView: WKWebView) async -> Bool {
        return await evaluateBool("document.readyState === 'complete'", in: webView)
    }
}
