import Foundation
import WebKit

@MainActor
class FingerprintValidationService {
    static let shared = FingerprintValidationService()

    private(set) var lastScore: FingerprintScore?
    private(set) var scoreHistory: [FingerprintScore] = []
    private let logger = DebugLogger.shared

    struct FingerprintScore {
        let timestamp: Date
        let totalScore: Int
        let maxSafeScore: Int
        let signals: [String]
        let profileSeed: UInt32
        let passed: Bool

        var formattedScore: String {
            "\(totalScore)/\(maxSafeScore)"
        }

        var summary: String {
            passed ? "PASS (\(totalScore))" : "FAIL (\(totalScore)/\(maxSafeScore))"
        }
    }

    static let maxAcceptableScore = 12

    static let validationJS: String = """
    (function() {
        'use strict';
        var score = 0;
        var signals = [];

        // 1. WEBDRIVER CHECK (weight 7)
        try {
            if (navigator.webdriver === true) {
                score += 7;
                signals.push('+7 webdriver=true');
            }
            if (navigator.webdriver === undefined) {
                score += 3;
                signals.push('+3 webdriver=undefined (should be false)');
            }
        } catch(e) { signals.push('webdriver check error'); }

        // 2. WEBDRIVER GETTER TAMPERING CHECK
        try {
            var webdriverDesc = Object.getOwnPropertyDescriptor(navigator, 'webdriver');
            if (webdriverDesc && webdriverDesc.get) {
                var getStr = webdriverDesc.get.toString();
                if (getStr.indexOf('[native code]') === -1) {
                    score += 4;
                    signals.push('+4 webdriver getter not native');
                }
            }
        } catch(e) {}

        // 3. CANVAS CONSISTENCY
        try {
            var c1 = document.createElement('canvas');
            c1.width = 200; c1.height = 50;
            var ctx1 = c1.getContext('2d');
            ctx1.textBaseline = 'top';
            ctx1.font = '14px Arial';
            ctx1.fillStyle = '#f60';
            ctx1.fillRect(125, 1, 62, 20);
            ctx1.fillStyle = '#069';
            ctx1.fillText('FPTest', 2, 15);
            var d1 = c1.toDataURL();

            var c2 = document.createElement('canvas');
            c2.width = 200; c2.height = 50;
            var ctx2 = c2.getContext('2d');
            ctx2.textBaseline = 'top';
            ctx2.font = '14px Arial';
            ctx2.fillStyle = '#f60';
            ctx2.fillRect(125, 1, 62, 20);
            ctx2.fillStyle = '#069';
            ctx2.fillText('FPTest', 2, 15);
            var d2 = c2.toDataURL();

            if (d1 !== d2) {
                score += 5;
                signals.push('+5 canvas output inconsistent between calls');
            }
        } catch(e) { signals.push('canvas check error'); }

        // 4. WEBGL RENDERER VS UA COHERENCE
        try {
            var canvas = document.createElement('canvas');
            var gl = canvas.getContext('webgl') || canvas.getContext('experimental-webgl');
            if (gl) {
                var debugInfo = gl.getExtension('WEBGL_debug_renderer_info');
                if (debugInfo) {
                    var renderer = gl.getParameter(debugInfo.UNMASKED_RENDERER_WEBGL);
                    var vendor = gl.getParameter(debugInfo.UNMASKED_VENDOR_WEBGL);
                    var ua = navigator.userAgent;
                    if (ua.indexOf('Mac') !== -1 || ua.indexOf('iPhone') !== -1 || ua.indexOf('iPad') !== -1) {
                        if (vendor && vendor.indexOf('Apple') === -1 && vendor.indexOf('apple') === -1) {
                            score += 6;
                            signals.push('+6 WebGL vendor mismatch: ' + vendor + ' on Apple UA');
                        }
                    }
                    if (ua.indexOf('iPhone') !== -1 && renderer && renderer !== 'Apple GPU') {
                        score += 4;
                        signals.push('+4 WebGL renderer mismatch on iPhone');
                    }
                }
            }
        } catch(e) {}

        // 5. SCREEN/VIEWPORT VS DEVICE COHERENCE
        try {
            var sw = screen.width;
            var sh = screen.height;
            var dpr = window.devicePixelRatio;
            var ua = navigator.userAgent;
            var isMobile = ua.indexOf('Mobile') !== -1;
            var isIPad = ua.indexOf('iPad') !== -1;
            if (isMobile && !isIPad) {
                if (sw > 500 || sh > 1000) {
                    score += 3;
                    signals.push('+3 screen too large for mobile UA: ' + sw + 'x' + sh);
                }
                if (dpr < 1.5) {
                    score += 3;
                    signals.push('+3 DPR too low for mobile: ' + dpr);
                }
            }
        } catch(e) {}

        // 6. NAVIGATOR PROPERTY ENUMERATION CHECK (getter-based overrides only)
        try {
            var overriddenProps = ['webdriver', 'language', 'languages', 'platform',
                                   'hardwareConcurrency', 'deviceMemory', 'maxTouchPoints'];
            var suspiciousGetters = 0;
            for (var i = 0; i < overriddenProps.length; i++) {
                var desc = Object.getOwnPropertyDescriptor(navigator, overriddenProps[i]);
                if (desc && desc.get && !desc.set) {
                    var fnStr = desc.get.toString();
                    if (fnStr.indexOf('[native code]') === -1) {
                        suspiciousGetters++;
                    }
                }
            }
            if (suspiciousGetters >= 4) {
                score += 6;
                signals.push('+6 ' + suspiciousGetters + '/7 nav props have non-native getters');
            } else if (suspiciousGetters >= 2) {
                score += 3;
                signals.push('+3 ' + suspiciousGetters + '/7 nav props have non-native getters');
            }
        } catch(e) {}

        // 7. AUTOMATION FLAGS CHECK
        try {
            var autoFlags = ['__nightmare', '_phantom', 'callPhantom',
                            '__selenium_evaluate', '__selenium_unwrapped',
                            '__webdriver_evaluate', '__driver_evaluate',
                            '__webdriver_unwrapped', '__driver_unwrapped',
                            '_Selenium_IDE_Recorder', '_WEBDRIVER_ELEM_CACHE',
                            'ChromeDriverw'];
            for (var i = 0; i < autoFlags.length; i++) {
                if (window[autoFlags[i]] !== undefined) {
                    score += 7;
                    signals.push('+7 automation flag: ' + autoFlags[i]);
                    break;
                }
            }
            if (document.__webdriver_script_fn !== undefined ||
                document.$chrome_asyncScriptInfo !== undefined ||
                document.$cdc_asdjflasutopfhvcZLmcfl_ !== undefined) {
                score += 7;
                signals.push('+7 document automation flag');
            }
        } catch(e) {}

        // 8. PLUGINS CONSISTENCY
        try {
            var ua = navigator.userAgent;
            var isSafari = ua.indexOf('Safari') !== -1 && ua.indexOf('Chrome') === -1;
            if (isSafari && navigator.plugins && navigator.plugins.length > 5) {
                score += 2;
                signals.push('+2 Safari with ' + navigator.plugins.length + ' plugins (unusual)');
            }
        } catch(e) {}

        // 9. RECT NOISE CHECK
        try {
            var div = document.createElement('div');
            div.style.cssText = 'position:absolute;left:-9999px;width:100px;height:100px;';
            document.body.appendChild(div);
            var r1 = div.getBoundingClientRect();
            var r2 = div.getBoundingClientRect();
            document.body.removeChild(div);
            if (r1.x !== r2.x || r1.y !== r2.y || r1.width !== r2.width || r1.height !== r2.height) {
                score += 4;
                signals.push('+4 getBoundingClientRect inconsistent between calls');
            }
        } catch(e) {}

        if (signals.length === 0) signals.push('All checks clean');

        return JSON.stringify({
            score: score,
            maxSafe: \(maxAcceptableScore),
            signals: signals,
            passed: score <= \(maxAcceptableScore)
        });
    })();
    """

    func validate(in webView: WKWebView, profileSeed: UInt32) async -> FingerprintScore {
        logger.startTimer(key: "fp_validate_\(profileSeed)")
        let result = await executeJS(validationJS(), in: webView)
        let elapsed = logger.stopTimer(key: "fp_validate_\(profileSeed)")

        guard let data = result?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let totalScore = json["score"] as? Int,
              let maxSafe = json["maxSafe"] as? Int,
              let signalArray = json["signals"] as? [String],
              let passed = json["passed"] as? Bool else {
            let fallback = FingerprintScore(
                timestamp: Date(), totalScore: 0, maxSafeScore: Self.maxAcceptableScore,
                signals: ["validation JS failed to execute"], profileSeed: profileSeed, passed: true
            )
            lastScore = fallback
            logger.log("Fingerprint: validation JS failed to execute (seed: \(profileSeed))", category: .fingerprint, level: .error, durationMs: elapsed, metadata: [
                "resultPreview": String((result ?? "nil").prefix(100))
            ])
            return fallback
        }

        let score = FingerprintScore(
            timestamp: Date(), totalScore: totalScore, maxSafeScore: maxSafe,
            signals: signalArray, profileSeed: profileSeed, passed: passed
        )
        lastScore = score
        scoreHistory.insert(score, at: 0)
        if scoreHistory.count > 50 { scoreHistory = Array(scoreHistory.prefix(50)) }

        logger.log("Fingerprint: \(passed ? "PASS" : "FAIL") score=\(totalScore)/\(maxSafe) signals=\(signalArray.count) seed=\(profileSeed)", category: .fingerprint, level: passed ? .success : .warning, durationMs: elapsed)

        if !passed {
            DeviceProxyService.shared.notifyFingerprintDetected()
        }

        return score
    }

    private func validationJS() -> String {
        return Self.validationJS
    }

    func clearHistory() {
        scoreHistory.removeAll()
        lastScore = nil
    }

    var averageScore: Double {
        guard !scoreHistory.isEmpty else { return 0 }
        let sum = scoreHistory.reduce(0) { $0 + $1.totalScore }
        return Double(sum) / Double(scoreHistory.count)
    }

    var passRate: Double {
        guard !scoreHistory.isEmpty else { return 1.0 }
        let passes = scoreHistory.filter(\.passed).count
        return Double(passes) / Double(scoreHistory.count)
    }

    var formattedPassRate: String {
        String(format: "%.0f%%", passRate * 100)
    }

    private func executeJS(_ js: String, in webView: WKWebView) async -> String? {
        do {
            let result = try await webView.evaluateJavaScript(js)
            if let str = result as? String { return str }
            if let num = result as? NSNumber { return "\(num)" }
            return nil
        } catch {
            return nil
        }
    }
}
