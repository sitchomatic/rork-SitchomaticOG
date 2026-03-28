import Foundation
import WebKit

// MARK: - WebKit Stealth Mutation Engine

/// Manages a pool of fully isolated, anti-fingerprint-hardened WKWebViews.
///
/// Each spawned WebView receives:
/// - A unique `WKProcessPool` to prevent cross-tab fingerprinting via shared workers
/// - A non-persistent `WKWebsiteDataStore` for cookie/storage isolation
/// - Pre-injected JavaScript that spoofs `navigator.webdriver`, canvas, audio,
///   hardware concurrency, and device memory before any page content loads
/// - Randomized viewport dimensions to defeat viewport-based fingerprinting
///
/// This replaces the `WebViewPool` in the old `HyperFlowEngine.swift` and
/// consolidates stealth logic from `PPSRStealthService`, `FingerprintValidationService`,
/// and `AntiBotDetectionService` into a single `@MainActor` engine.
@MainActor
final class WebKitMutationEngine: Sendable {
    static let shared = WebKitMutationEngine()

    // MARK: - State

    private var activePool: [UUID: WKWebView] = [:]

    // MARK: - WebView Lifecycle

    /// Creates a fully isolated, stealth-hardened WebView with unique fingerprint.
    ///
    /// - Parameters:
    ///   - id: Unique identifier for this WebView session
    ///   - settings: Automation settings controlling stealth behavior
    ///   - profile: Stealth identity profile providing randomized seeds
    /// - Returns: A configured WKWebView ready for automation
    func spawnIsolatedWebView(
        id: UUID,
        settings: AutomationSettings,
        profile: StealthIdentityActor.IdentityProfile
    ) -> WKWebView {
        let config = WKWebViewConfiguration()

        // 1. Strict Process Isolation: Unique process pool per WebView prevents
        //    cross-tab fingerprinting via shared worker tracking or indexedDB leaks.
        config.processPool = WKProcessPool()
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()

        // 2. Inject stealth scripts before any page content loads
        let stealthScript = buildStealthScript(settings: settings, profile: profile)
        let userScript = WKUserScript(
            source: stealthScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(userScript)

        // 3. Configure WebView with randomized viewport
        let viewport = randomizeViewport(settings: settings, profile: profile)
        let webView = WKWebView(frame: viewport, configuration: config)

        // 4. User-Agent spoofing
        webView.customUserAgent = generateMobileUserAgent(profile: profile)
        webView.isOpaque = false // Avoids headless detection via opacity checks

        activePool[id] = webView
        return webView
    }

    /// Retrieves an active WebView by session ID.
    func webView(for id: UUID) -> WKWebView? {
        activePool[id]
    }

    /// Destroys a WebView session and releases all associated resources.
    func destroyWebView(id: UUID) {
        guard let webView = activePool.removeValue(forKey: id) else { return }
        webView.stopLoading()
        webView.configuration.userContentController.removeAllUserScripts()
        webView.loadHTMLString("", baseURL: nil)
    }

    /// Destroys all active WebViews (e.g., on batch completion).
    func destroyAll() {
        for (id, _) in activePool {
            destroyWebView(id: id)
        }
    }

    /// Returns the count of currently active WebViews.
    var activeCount: Int { activePool.count }

    // MARK: - Stealth Script Generation

    /// Builds the comprehensive anti-fingerprinting JavaScript payload.
    ///
    /// Injected at `.atDocumentStart` before any page scripts execute.
    /// All overrides use `Object.defineProperty` with non-configurable descriptors
    /// to resist detection via property enumeration.
    private func buildStealthScript(
        settings: AutomationSettings,
        profile: StealthIdentityActor.IdentityProfile
    ) -> String {
        var script = """
        // === Sitchomatic Stealth Layer (Injected at document start) ===

        // 1. Overwrite webdriver flag — the #1 automation detection signal
        Object.defineProperty(navigator, 'webdriver', {
            get: () => false,
            configurable: false,
            enumerable: true
        });

        // 2. Spoof hardware properties to match a real mobile device
        Object.defineProperty(navigator, 'hardwareConcurrency', {
            get: () => \(profile.hardwareConcurrency),
            configurable: false
        });
        Object.defineProperty(navigator, 'deviceMemory', {
            get: () => \(profile.deviceMemoryGB),
            configurable: false
        });

        // 3. Spoof language to match identity profile
        Object.defineProperty(navigator, 'language', {
            get: () => '\(profile.languageCode)',
            configurable: false
        });
        Object.defineProperty(navigator, 'languages', {
            get: () => ['\(profile.languageCode)', 'en'],
            configurable: false
        });

        // 4. Remove common automation artifacts from window/document
        (function() {
            const automationKeys = [
                '__nightmare', '_phantom', '__webdriver_evaluate',
                '__selenium_evaluate', '__webdriver_script_fn',
                '__webdriver_script_func', '__webdriver_unwrapped',
                '__driver_evaluate', '__driver_unwrapped',
                '_Selenium_IDE_Recorder', 'callSelenium',
                '_selenium', 'calledSelenium',
                '__fxdriver_evaluate', '__fxdriver_unwrapped'
            ];
            automationKeys.forEach(key => {
                try { delete window[key]; } catch(e) {}
                try { delete document[key]; } catch(e) {}
            });
        })();

        // 5. Spoof plugins to look like real Safari
        Object.defineProperty(navigator, 'plugins', {
            get: () => [1, 2, 3],
            configurable: false
        });
        """

        // Canvas noise injection — subtle RGBA perturbation to defeat hash-based fingerprinting
        if settings.canvasNoise {
            script += """

            // 6. Canvas fingerprint poisoning
            (function() {
                const seed = \(profile.canvasNoiseSeed);
                function seededRandom(s) {
                    let x = Math.sin(s) * 10000;
                    return x - Math.floor(x);
                }
                let callCount = 0;

                const origGetContext = HTMLCanvasElement.prototype.getContext;
                HTMLCanvasElement.prototype.getContext = function(type, attrs) {
                    const ctx = origGetContext.call(this, type, attrs);
                    if (type === '2d' && ctx) {
                        const origFillText = ctx.fillText.bind(ctx);
                        ctx.fillText = function(...args) {
                            callCount++;
                            const noise = seededRandom(seed + callCount);
                            const r = Math.floor(noise * 5);
                            const g = Math.floor(seededRandom(seed + callCount + 1) * 5);
                            const b = Math.floor(seededRandom(seed + callCount + 2) * 5);
                            ctx.fillStyle = 'rgba(' + r + ',' + g + ',' + b + ',0.01)';
                            return origFillText(...args);
                        };
                        const origGetImageData = ctx.getImageData.bind(ctx);
                        ctx.getImageData = function(...args) {
                            const imageData = origGetImageData(...args);
                            for (let i = 0; i < imageData.data.length; i += 4) {
                                imageData.data[i] += Math.floor(seededRandom(seed + i) * 2);
                            }
                            return imageData;
                        };
                    }
                    return ctx;
                };

                const origToDataURL = HTMLCanvasElement.prototype.toDataURL;
                HTMLCanvasElement.prototype.toDataURL = function(...args) {
                    const ctx = this.getContext('2d');
                    if (ctx) {
                        callCount++;
                        ctx.fillStyle = 'rgba(' + Math.floor(seededRandom(seed + callCount) * 3) + ',0,0,0.003)';
                        ctx.fillRect(0, 0, 1, 1);
                    }
                    return origToDataURL.apply(this, args);
                };
            })();
            """
        }

        // WebGL vendor/renderer spoofing
        script += """

        // 7. WebGL vendor/renderer spoofing
        (function() {
            const origGetParameter = WebGLRenderingContext.prototype.getParameter;
            WebGLRenderingContext.prototype.getParameter = function(param) {
                const ext = this.getExtension('WEBGL_debug_renderer_info');
                if (ext) {
                    if (param === ext.UNMASKED_VENDOR_WEBGL) return '\(profile.webGLVendor)';
                    if (param === ext.UNMASKED_RENDERER_WEBGL) return '\(profile.webGLRenderer)';
                }
                return origGetParameter.call(this, param);
            };
        })();
        """

        return script
    }

    // MARK: - Viewport Randomization

    private func randomizeViewport(
        settings: AutomationSettings,
        profile: StealthIdentityActor.IdentityProfile
    ) -> CGRect {
        let baseWidth = settings.mobileViewportWidth
        let baseHeight = settings.mobileViewportHeight
        let jitterX = settings.viewportRandomization ? Int.random(in: -10...10) : 0
        let jitterY = settings.viewportRandomization ? Int.random(in: -20...20) : 0
        return CGRect(
            x: 0,
            y: 0,
            width: max(320, baseWidth + jitterX),
            height: max(480, baseHeight + jitterY)
        )
    }

    // MARK: - User-Agent Generation

    // MARK: - User-Agent Constants

    /// Centralized version constants for user-agent generation.
    /// Update these when new iOS/Safari versions are released.
    private enum UserAgentVersions {
        static let safariWebKit = ["605.1.15", "604.1.34", "605.1.33"]
        static let iosVersions = ["17_4_1", "17_3_1", "17_2", "16_7_5", "17_5"]
        static let safariBrowserVersion = "17.4"
        static let mobileBuild = "15E148"
    }

    private func generateMobileUserAgent(profile: StealthIdentityActor.IdentityProfile) -> String {
        let safariVersion = UserAgentVersions.safariWebKit.randomElement() ?? "605.1.15"
        let iosVersion = UserAgentVersions.iosVersions.randomElement() ?? "17_4_1"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(iosVersion) like Mac OS X) AppleWebKit/\(safariVersion) (KHTML, like Gecko) Version/\(UserAgentVersions.safariBrowserVersion) Mobile/\(UserAgentVersions.mobileBuild) Safari/\(safariVersion)"
    }
}
