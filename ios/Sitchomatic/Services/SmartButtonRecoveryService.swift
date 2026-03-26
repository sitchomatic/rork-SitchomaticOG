import Foundation
import WebKit

@MainActor
class SmartButtonRecoveryService {
    static let shared = SmartButtonRecoveryService()

    private let logger = DebugLogger.shared
    private var hostRecoveryHistory: [String: [Int]] = [:]
    private let maxHistoryPerHost = 20

    struct ButtonFingerprint {
        let bgColor: String
        let textContent: String
        let width: Double
        let height: Double
        let opacity: Double
        let borderColor: String
        let cursor: String
        let pointerEvents: String
        let disabled: Bool
    }

    struct RecoveryResult {
        let recovered: Bool
        let durationMs: Int
        let reason: String
        let intermediateStates: [String]
    }

    private let captureJS = """
    (function() {
        var loginTerms = ['log in','login','sign in','signin'];
        var btns = document.querySelectorAll('button, input[type="submit"], a.btn, [role="button"], #login-submit');
        var btn = document.querySelector('#login-submit');
        if (!btn) {
            for (var i = 0; i < btns.length; i++) {
                var text = (btns[i].textContent || btns[i].value || '').replace(/[\\s]+/g,' ').toLowerCase().trim();
                if (text.length > 50) continue;
                for (var t = 0; t < loginTerms.length; t++) {
                    if (text === loginTerms[t] || (text.indexOf(loginTerms[t]) !== -1 && text.length < 25)) { btn = btns[i]; break; }
                }
                if (btn) break;
            }
        }
        if (!btn) {
            btn = document.querySelector('button[type="submit"]') || document.querySelector('input[type="submit"]');
        }
        if (!btn) return JSON.stringify({found: false});
        var style = window.getComputedStyle(btn);
        return JSON.stringify({
            found: true,
            bgColor: style.backgroundColor,
            textContent: (btn.textContent || btn.value || '').replace(/[\\s]+/g,' ').trim().substring(0, 50),
            width: btn.getBoundingClientRect().width,
            height: btn.getBoundingClientRect().height,
            opacity: parseFloat(style.opacity),
            borderColor: style.borderColor,
            cursor: style.cursor,
            pointerEvents: style.pointerEvents,
            disabled: btn.disabled || false
        });
    })();
    """

    func captureFingerprint(executeJS: @escaping (String) async -> String?, sessionId: String) async -> ButtonFingerprint? {
        guard let raw = await executeJS(captureJS),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let found = json["found"] as? Bool, found else {
            logger.log("ButtonRecovery: could not capture fingerprint — button not found", category: .automation, level: .warning, sessionId: sessionId)
            return nil
        }

        let fp = ButtonFingerprint(
            bgColor: json["bgColor"] as? String ?? "",
            textContent: json["textContent"] as? String ?? "",
            width: json["width"] as? Double ?? 0,
            height: json["height"] as? Double ?? 0,
            opacity: json["opacity"] as? Double ?? 1.0,
            borderColor: json["borderColor"] as? String ?? "",
            cursor: json["cursor"] as? String ?? "",
            pointerEvents: json["pointerEvents"] as? String ?? "auto",
            disabled: json["disabled"] as? Bool ?? false
        )
        logger.log("ButtonRecovery: captured fingerprint — text='\(fp.textContent)' bg=\(fp.bgColor) opacity=\(String(format: "%.2f", fp.opacity))", category: .automation, level: .trace, sessionId: sessionId)
        return fp
    }

    func waitForRecovery(
        originalFingerprint: ButtonFingerprint,
        executeJS: @escaping (String) async -> String?,
        host: String,
        sessionId: String,
        maxTimeoutMs: Int = 12000
    ) async -> RecoveryResult {
        let start = Date()
        var intermediateStates: [String] = []
        let loadingTerms = ["loading", "please wait", "submitting", "processing", "wait", "signing in", "logging in"]

        let learnedAvgMs = averageRecoveryMs(for: host)
        let effectiveTimeout = learnedAvgMs > 0 ? min(maxTimeoutMs, max(learnedAvgMs * 3, 3000)) : maxTimeoutMs

        logger.log("ButtonRecovery: waiting for recovery on \(host) (maxTimeout=\(effectiveTimeout)ms, learned=\(learnedAvgMs)ms)", category: .automation, level: .trace, sessionId: sessionId)

        var sawLoadingState = false

        while true {
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            if elapsedMs >= effectiveTimeout {
                logger.log("ButtonRecovery: TIMEOUT after \(elapsedMs)ms — proceeding anyway", category: .automation, level: .warning, sessionId: sessionId)
                return RecoveryResult(recovered: false, durationMs: elapsedMs, reason: "Timeout after \(elapsedMs)ms", intermediateStates: intermediateStates)
            }

            guard let raw = await executeJS(captureJS),
                  let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let found = json["found"] as? Bool, found else {
                try? await Task.sleep(for: .milliseconds(300))
                continue
            }

            let currentText = (json["textContent"] as? String ?? "").lowercased()
            let currentOpacity = json["opacity"] as? Double ?? 1.0
            let currentPointer = json["pointerEvents"] as? String ?? "auto"
            let currentDisabled = json["disabled"] as? Bool ?? false
            let currentBg = json["bgColor"] as? String ?? ""
            let currentCursor = json["cursor"] as? String ?? ""

            let isLoading = loadingTerms.contains { currentText.contains($0) }
            let isTranslucent = currentOpacity < 0.7
            let isDisabledState = currentDisabled || currentPointer == "none"
            let isWaitCursor = currentCursor == "wait" || currentCursor == "progress"

            if isLoading || isTranslucent || isDisabledState || isWaitCursor {
                let state = "[\(elapsedMs)ms] loading=\(isLoading) translucent=\(isTranslucent) disabled=\(isDisabledState) waitCursor=\(isWaitCursor) text='\(currentText.prefix(30))'"
                if !intermediateStates.contains(state) {
                    intermediateStates.append(state)
                }
                sawLoadingState = true
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }

            let bgMatch = currentBg == originalFingerprint.bgColor || originalFingerprint.bgColor.isEmpty
            let textMatch = normalizeButtonText(currentText) == normalizeButtonText(originalFingerprint.textContent.lowercased())
            let opacityMatch = abs(currentOpacity - originalFingerprint.opacity) < 0.15
            let notDisabled = !currentDisabled && currentPointer != "none"

            if bgMatch && textMatch && opacityMatch && notDisabled {
                let finalMs = Int(Date().timeIntervalSince(start) * 1000)
                recordRecovery(host: host, durationMs: finalMs)
                logger.log("ButtonRecovery: RECOVERED in \(finalMs)ms — all signals match original", category: .automation, level: .success, sessionId: sessionId)
                return RecoveryResult(recovered: true, durationMs: finalMs, reason: "Full recovery — matches original fingerprint", intermediateStates: intermediateStates)
            }

            if sawLoadingState && notDisabled && opacityMatch {
                let finalMs = Int(Date().timeIntervalSince(start) * 1000)
                recordRecovery(host: host, durationMs: finalMs)
                let detail = "Partial recovery after loading state — enabled+visible (bg:\(bgMatch) text:\(textMatch))"
                logger.log("ButtonRecovery: \(detail) in \(finalMs)ms", category: .automation, level: .info, sessionId: sessionId)
                return RecoveryResult(recovered: true, durationMs: finalMs, reason: detail, intermediateStates: intermediateStates)
            }

            if elapsedMs > 3000 && notDisabled && currentOpacity > 0.8 {
                let finalMs = Int(Date().timeIntervalSince(start) * 1000)
                recordRecovery(host: host, durationMs: finalMs)
                logger.log("ButtonRecovery: button appears ready after \(finalMs)ms (not exact match but clickable)", category: .automation, level: .info, sessionId: sessionId)
                return RecoveryResult(recovered: true, durationMs: finalMs, reason: "Button clickable after extended check", intermediateStates: intermediateStates)
            }

            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private func normalizeButtonText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    private func recordRecovery(host: String, durationMs: Int) {
        var history = hostRecoveryHistory[host] ?? []
        history.append(durationMs)
        if history.count > maxHistoryPerHost { history.removeFirst() }
        hostRecoveryHistory[host] = history
    }

    func averageRecoveryMs(for host: String) -> Int {
        guard let history = hostRecoveryHistory[host], !history.isEmpty else { return 0 }
        return history.reduce(0, +) / history.count
    }
}
