import Foundation
import WebKit

@MainActor
class SmartPageSettlementService {
    static let shared = SmartPageSettlementService()

    private let logger = DebugLogger.shared
    private var hostSettlementHistory: [String: [Int]] = [:]
    private let maxHistoryPerHost = 20

    struct SettlementResult {
        let settled: Bool
        let durationMs: Int
        let signals: SettlementSignals
        let reason: String
    }

    struct SettlementSignals {
        var readyStateComplete: Bool = false
        var networkIdle: Bool = false
        var domStable: Bool = false
        var animationsComplete: Bool = false
        var loginFormReady: Bool = false
    }

    private let injectionJS = """
    (function() {
        if (window.__settlementMonitor) return 'ALREADY_INJECTED';
        window.__settlementMonitor = {
            pendingXHR: 0,
            pendingFetch: 0,
            lastNetworkActivityMs: Date.now(),
            lastDOMMutationMs: Date.now(),
            mutationCount: 0
        };
        var m = window.__settlementMonitor;

        var origOpen = XMLHttpRequest.prototype.open;
        var origSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function() { return origOpen.apply(this, arguments); };
        XMLHttpRequest.prototype.send = function() {
            m.pendingXHR++;
            m.lastNetworkActivityMs = Date.now();
            this.addEventListener('loadend', function() {
                m.pendingXHR = Math.max(0, m.pendingXHR - 1);
                m.lastNetworkActivityMs = Date.now();
            });
            return origSend.apply(this, arguments);
        };

        var origFetch = window.fetch;
        window.fetch = function() {
            m.pendingFetch++;
            m.lastNetworkActivityMs = Date.now();
            return origFetch.apply(this, arguments).then(function(r) {
                m.pendingFetch = Math.max(0, m.pendingFetch - 1);
                m.lastNetworkActivityMs = Date.now();
                return r;
            }).catch(function(e) {
                m.pendingFetch = Math.max(0, m.pendingFetch - 1);
                m.lastNetworkActivityMs = Date.now();
                throw e;
            });
        };

        var observer = new MutationObserver(function(mutations) {
            m.lastDOMMutationMs = Date.now();
            m.mutationCount += mutations.length;
        });
        observer.observe(document.documentElement, {
            childList: true, subtree: true, attributes: true, characterData: true
        });

        return 'INJECTED';
    })();
    """

    private let pollJS = """
    (function() {
        var m = window.__settlementMonitor;
        if (!m) return JSON.stringify({error: 'no_monitor'});
        var now = Date.now();
        var pendingNet = m.pendingXHR + m.pendingFetch;
        var netIdleMs = pendingNet === 0 ? (now - m.lastNetworkActivityMs) : 0;
        var domIdleMs = now - m.lastDOMMutationMs;
        var animCount = 0;
        try { animCount = document.getAnimations ? document.getAnimations().length : 0; } catch(e) {}
        var readyState = document.readyState;

        var emailField = document.querySelector('#email')
            || document.querySelector('input[type="email"]')
            || document.querySelector('input[name="email"]')
            || document.querySelector('input[name="username"]')
            || document.querySelector('input[type="text"]');
        var passField = document.querySelector('#login-password')
            || document.querySelector('input[type="password"]');

        var formReady = false;
        if (emailField && passField) {
            var eStyle = window.getComputedStyle(emailField);
            var pStyle = window.getComputedStyle(passField);
            var eVisible = emailField.offsetParent !== null && eStyle.display !== 'none' && eStyle.visibility !== 'hidden';
            var pVisible = passField.offsetParent !== null && pStyle.display !== 'none' && pStyle.visibility !== 'hidden';
            formReady = eVisible && pVisible && !emailField.disabled && !passField.disabled;
        }

        return JSON.stringify({
            readyState: readyState,
            pendingNet: pendingNet,
            netIdleMs: netIdleMs,
            domIdleMs: domIdleMs,
            animCount: animCount,
            formReady: formReady,
            mutationCount: m.mutationCount
        });
    })();
    """

    func injectMonitor(executeJS: @escaping (String) async -> String?) async {
        _ = await executeJS(injectionJS)
    }

    func waitForSettlement(
        executeJS: @escaping (String) async -> String?,
        host: String,
        sessionId: String,
        maxTimeoutMs: Int = 15000,
        networkIdleThresholdMs: Int = 500,
        domStableThresholdMs: Int = 400
    ) async -> SettlementResult {
        let start = Date()
        var signals = SettlementSignals()
        var lastPollResult: [String: Any] = [:]

        let learnedAvgMs = averageSettlementMs(for: host)
        let effectiveTimeout = learnedAvgMs > 0 ? min(maxTimeoutMs, learnedAvgMs * 3) : maxTimeoutMs

        logger.log("PageSettlement: waiting for \(host) (maxTimeout=\(effectiveTimeout)ms, learned=\(learnedAvgMs)ms)", category: .automation, level: .trace, sessionId: sessionId)

        while true {
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            if elapsedMs >= effectiveTimeout {
                let reason = buildTimeoutReason(signals, lastPollResult)
                logger.log("PageSettlement: TIMEOUT after \(elapsedMs)ms — \(reason)", category: .automation, level: .warning, sessionId: sessionId)
                return SettlementResult(settled: false, durationMs: elapsedMs, signals: signals, reason: "Timeout: \(reason)")
            }

            guard let raw = await executeJS(pollJS),
                  let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            lastPollResult = json

            if json["error"] != nil {
                await injectMonitor(executeJS: executeJS)
                try? await Task.sleep(for: .milliseconds(300))
                continue
            }

            let readyState = json["readyState"] as? String ?? ""
            let pendingNet = json["pendingNet"] as? Int ?? 0
            let netIdleMs = json["netIdleMs"] as? Int ?? 0
            let domIdleMs = json["domIdleMs"] as? Int ?? 0
            let animCount = json["animCount"] as? Int ?? 0
            let formReady = json["formReady"] as? Bool ?? false

            signals.readyStateComplete = readyState == "complete"
            signals.networkIdle = pendingNet == 0 && netIdleMs >= networkIdleThresholdMs
            signals.domStable = domIdleMs >= domStableThresholdMs
            signals.animationsComplete = animCount == 0
            signals.loginFormReady = formReady

            if signals.readyStateComplete && signals.networkIdle && signals.domStable && signals.animationsComplete && signals.loginFormReady {
                let finalMs = Int(Date().timeIntervalSince(start) * 1000)
                recordSettlement(host: host, durationMs: finalMs)
                logger.log("PageSettlement: SETTLED in \(finalMs)ms — all signals green", category: .automation, level: .success, sessionId: sessionId)
                return SettlementResult(settled: true, durationMs: finalMs, signals: signals, reason: "All signals settled")
            }

            if elapsedMs > 5000 && signals.readyStateComplete && signals.loginFormReady && (signals.networkIdle || signals.domStable) {
                let finalMs = Int(Date().timeIntervalSince(start) * 1000)
                recordSettlement(host: host, durationMs: finalMs)
                let partial = "Partial settle: form ready + \(signals.networkIdle ? "netIdle" : "domStable")"
                logger.log("PageSettlement: \(partial) in \(finalMs)ms", category: .automation, level: .info, sessionId: sessionId)
                return SettlementResult(settled: true, durationMs: finalMs, signals: signals, reason: partial)
            }

            if elapsedMs > 8000 && signals.loginFormReady {
                let finalMs = Int(Date().timeIntervalSince(start) * 1000)
                recordSettlement(host: host, durationMs: finalMs)
                logger.log("PageSettlement: form ready after \(finalMs)ms — proceeding despite pending signals", category: .automation, level: .info, sessionId: sessionId)
                return SettlementResult(settled: true, durationMs: finalMs, signals: signals, reason: "Form ready, proceeding after extended wait")
            }

            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func buildTimeoutReason(_ signals: SettlementSignals, _ poll: [String: Any]) -> String {
        var missing: [String] = []
        if !signals.readyStateComplete { missing.append("readyState=\(poll["readyState"] as? String ?? "?")") }
        if !signals.networkIdle { missing.append("net=\(poll["pendingNet"] as? Int ?? -1) pending") }
        if !signals.domStable { missing.append("domIdle=\(poll["domIdleMs"] as? Int ?? -1)ms") }
        if !signals.animationsComplete { missing.append("anims=\(poll["animCount"] as? Int ?? -1)") }
        if !signals.loginFormReady { missing.append("formNotReady") }
        return missing.isEmpty ? "unknown" : missing.joined(separator: ", ")
    }

    private func recordSettlement(host: String, durationMs: Int) {
        var history = hostSettlementHistory[host] ?? []
        history.append(durationMs)
        if history.count > maxHistoryPerHost { history.removeFirst() }
        hostSettlementHistory[host] = history
    }

    func averageSettlementMs(for host: String) -> Int {
        guard let history = hostSettlementHistory[host], !history.isEmpty else { return 0 }
        return history.reduce(0, +) / history.count
    }
}
