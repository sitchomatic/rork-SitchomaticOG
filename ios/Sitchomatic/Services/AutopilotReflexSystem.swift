import Foundation

nonisolated struct ReflexRule: Sendable {
    let id: String
    let signalType: AutopilotSignalType
    let minimumConfidence: Double
    let action: AutopilotAction
    let priority: AutopilotPriority
    let reasoning: String
    let parameters: [String: String]
    let cooldownMs: Int
    let maxFiringsPerSession: Int
    let requiresConsecutive: Int
}

nonisolated struct ReflexOutcome: Sendable {
    let action: AutopilotAction
    let priority: AutopilotPriority
    let confidence: Double
    let reasoning: String
    let parameters: [String: String]
}

@MainActor
class AutopilotReflexSystem {

    private struct ArmedReflex {
        let rule: ReflexRule
        var lastFired: Date = .distantPast
        var firings: Int = 0
        var consecutiveHits: Int = 0
    }

    private var armedReflexes: [String: [String: ArmedReflex]] = [:]
    private var actionSuccessRates: [String: (successes: Int, total: Int)] = [:]
    private var thresholdOverrides: [String: Double] = [:]

    private let hardcodedRules: [ReflexRule] = [
        ReflexRule(
            id: "reflex_challenge_instant_rotate",
            signalType: .challengeFormingDetected,
            minimumConfidence: 0.7,
            action: .preemptiveIPRotation,
            priority: .critical,
            reasoning: "Challenge forming — instant IP rotation before page renders",
            parameters: ["urgency": "immediate"],
            cooldownMs: 8000,
            maxFiringsPerSession: 4,
            requiresConsecutive: 1
        ),
        ReflexRule(
            id: "reflex_captcha_proxy_switch",
            signalType: .captchaFormingDetected,
            minimumConfidence: 0.65,
            action: .preemptiveProxySwitch,
            priority: .critical,
            reasoning: "CAPTCHA DOM insertion detected — proxy switch before challenge activates",
            parameters: ["urgency": "immediate"],
            cooldownMs: 12000,
            maxFiringsPerSession: 3,
            requiresConsecutive: 1
        ),
        ReflexRule(
            id: "reflex_webdriver_counter",
            signalType: .webDriverProbeDetected,
            minimumConfidence: 0.6,
            action: .injectCounterFingerprint,
            priority: .high,
            reasoning: "WebDriver property probe — injecting counter before result collected",
            parameters: ["target": "webdriver"],
            cooldownMs: 5000,
            maxFiringsPerSession: 8,
            requiresConsecutive: 1
        ),
        ReflexRule(
            id: "reflex_canvas_fp_rotate",
            signalType: .canvasProbeDetected,
            minimumConfidence: 0.65,
            action: .rotateFingerprint,
            priority: .high,
            reasoning: "Canvas fingerprint probe — rotating profile before hash collected",
            parameters: ["probeType": "canvas"],
            cooldownMs: 15000,
            maxFiringsPerSession: 3,
            requiresConsecutive: 1
        ),
        ReflexRule(
            id: "reflex_typing_adjust",
            signalType: .typingVelocityAnomaly,
            minimumConfidence: 0.55,
            action: .adjustTypingSpeed,
            priority: .high,
            reasoning: "Bot-like typing velocity detected — adjusting speed mid-keystroke",
            parameters: ["adjustment": "slow_25_percent"],
            cooldownMs: 4000,
            maxFiringsPerSession: 10,
            requiresConsecutive: 1
        ),
        ReflexRule(
            id: "reflex_ratelimit_throttle",
            signalType: .rateLimitSignal,
            minimumConfidence: 0.7,
            action: .throttleRequests,
            priority: .critical,
            reasoning: "Rate limit response — immediate request throttling",
            parameters: ["backoffMs": "5000"],
            cooldownMs: 20000,
            maxFiringsPerSession: 3,
            requiresConsecutive: 1
        ),
        ReflexRule(
            id: "reflex_fp_probe_counter",
            signalType: .fingerprintProbeDetected,
            minimumConfidence: 0.6,
            action: .injectCounterFingerprint,
            priority: .high,
            reasoning: "Fingerprint collection script detected — injecting spoof values",
            parameters: ["target": "fingerprint_api"],
            cooldownMs: 8000,
            maxFiringsPerSession: 5,
            requiresConsecutive: 1
        ),
        ReflexRule(
            id: "reflex_cookie_bomb_clear",
            signalType: .cookieBombDetected,
            minimumConfidence: 0.6,
            action: .preemptiveCookieClear,
            priority: .high,
            reasoning: "Tracking cookie payload detected — clearing before data exfiltration",
            parameters: ["scope": "session_cookies"],
            cooldownMs: 10000,
            maxFiringsPerSession: 4,
            requiresConsecutive: 1
        ),
        ReflexRule(
            id: "reflex_blank_dns_rotate",
            signalType: .blankPageDetected,
            minimumConfidence: 0.7,
            action: .rotateDNS,
            priority: .high,
            reasoning: "Blank page detected — rotating DNS to resolve potential blocking",
            parameters: ["action": "dns_rotate"],
            cooldownMs: 15000,
            maxFiringsPerSession: 3,
            requiresConsecutive: 2
        ),
        ReflexRule(
            id: "reflex_latency_proxy_switch",
            signalType: .proxyLatencySpike,
            minimumConfidence: 0.6,
            action: .preemptiveProxySwitch,
            priority: .medium,
            reasoning: "Proxy latency spike — switching to fresher proxy",
            parameters: ["reason": "latency_spike"],
            cooldownMs: 12000,
            maxFiringsPerSession: 4,
            requiresConsecutive: 2
        ),
        ReflexRule(
            id: "reflex_timing_slowdown",
            signalType: .timingAnomalyDetected,
            minimumConfidence: 0.5,
            action: .slowDownInteraction,
            priority: .medium,
            reasoning: "Timing pattern flagged — adding human-like pauses",
            parameters: ["extraDelayMs": "300"],
            cooldownMs: 8000,
            maxFiringsPerSession: 5,
            requiresConsecutive: 1
        ),
    ]

    func armReflexes(for sessionId: String, host: String, mode: AutopilotMode) {
        var armed: [String: ArmedReflex] = [:]
        for rule in hardcodedRules {
            let effectiveConfidence = thresholdOverrides[rule.signalType.rawValue] ?? rule.minimumConfidence
            var adjustedRule = rule
            if effectiveConfidence != rule.minimumConfidence {
                adjustedRule = ReflexRule(
                    id: rule.id, signalType: rule.signalType,
                    minimumConfidence: effectiveConfidence,
                    action: rule.action, priority: rule.priority,
                    reasoning: rule.reasoning, parameters: rule.parameters,
                    cooldownMs: rule.cooldownMs,
                    maxFiringsPerSession: rule.maxFiringsPerSession,
                    requiresConsecutive: rule.requiresConsecutive
                )
            }
            armed[rule.id] = ArmedReflex(rule: adjustedRule)
        }
        armedReflexes[sessionId] = armed
    }

    func disarmReflexes(for sessionId: String) {
        armedReflexes.removeValue(forKey: sessionId)
    }

    func checkReflexTrigger(
        signal: AutopilotSignal,
        sessionState: AutopilotSessionState,
        mode: AutopilotMode
    ) -> ReflexOutcome? {
        guard var reflexes = armedReflexes[signal.sessionId] else { return nil }

        var bestMatch: (id: String, reflex: ArmedReflex, confidence: Double)?

        for (id, var reflex) in reflexes {
            guard reflex.rule.signalType == signal.type else { continue }
            guard signal.confidence >= reflex.rule.minimumConfidence else {
                reflex.consecutiveHits = 0
                reflexes[id] = reflex
                continue
            }
            guard reflex.firings < reflex.rule.maxFiringsPerSession else { continue }

            let now = Date()
            let cooldownExpired = now.timeIntervalSince(reflex.lastFired) * 1000 >= Double(reflex.rule.cooldownMs)
            guard cooldownExpired else { continue }

            reflex.consecutiveHits += 1
            reflexes[id] = reflex

            guard reflex.consecutiveHits >= reflex.rule.requiresConsecutive else { continue }

            let effectiveConfidence = signal.confidence * modeMultiplier(mode)
            if bestMatch == nil || effectiveConfidence > (bestMatch?.confidence ?? 0) {
                bestMatch = (id, reflex, effectiveConfidence)
            }
        }

        armedReflexes[signal.sessionId] = reflexes

        guard var (matchId, matchReflex, matchConfidence) = bestMatch else { return nil }
        guard var sessionReflexes = armedReflexes[signal.sessionId] else { return nil }

        matchReflex.lastFired = Date()
        matchReflex.firings += 1
        matchReflex.consecutiveHits = 0
        sessionReflexes[matchId] = matchReflex
        armedReflexes[signal.sessionId] = sessionReflexes

        var params = matchReflex.rule.parameters
        params["sessionId"] = signal.sessionId
        params["host"] = signal.host
        params["signalConfidence"] = String(format: "%.2f", signal.confidence)
        params["reflexFiring"] = "\(matchReflex.firings)"

        return ReflexOutcome(
            action: matchReflex.rule.action,
            priority: matchReflex.rule.priority,
            confidence: min(1.0, matchConfidence),
            reasoning: matchReflex.rule.reasoning,
            parameters: params
        )
    }

    func recordOutcome(action: AutopilotAction, success: Bool) {
        var stats = actionSuccessRates[action.rawValue] ?? (successes: 0, total: 0)
        stats.total += 1
        if success { stats.successes += 1 }
        actionSuccessRates[action.rawValue] = stats
    }

    func updateThreshold(for signalType: String, threshold: Double) {
        thresholdOverrides[signalType] = max(0.1, min(0.95, threshold))
    }

    func reflexStats() -> [(action: String, successRate: Double, totalFirings: Int)] {
        actionSuccessRates.map { (key, value) in
            let rate = value.total > 0 ? Double(value.successes) / Double(value.total) : 0
            return (action: key, successRate: rate, totalFirings: value.total)
        }.sorted { $0.totalFirings > $1.totalFirings }
    }

    func armedReflexCount(for sessionId: String) -> Int {
        armedReflexes[sessionId]?.count ?? 0
    }

    private func modeMultiplier(_ mode: AutopilotMode) -> Double {
        switch mode {
        case .off: return 0
        case .passive: return 0.7
        case .active: return 1.0
        case .aggressive: return 1.3
        }
    }
}
