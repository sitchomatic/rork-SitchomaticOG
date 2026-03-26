import Foundation

nonisolated struct GraphDecisionResult: Sendable {
    let action: AutopilotAction
    let priority: AutopilotPriority
    let confidence: Double
    let reasoning: String
    let parameters: [String: String]
}

@MainActor
class AutopilotDecisionGraph {

    private struct DecisionNode {
        let signalTypes: Set<AutopilotSignalType>
        let minSeverity: Double
        let minThreatLevel: Double
        let action: AutopilotAction
        let priority: AutopilotPriority
        let reasoning: String
        let cooldownSeconds: TimeInterval
        let maxActivationsPerSession: Int
        let requiredMode: AutopilotMode?
        let parameterGenerator: (@Sendable (AutopilotSignal, AutopilotSessionState) -> [String: String])?
    }

    private var nodes: [DecisionNode] = []
    private var lastActivation: [String: Date] = [:]
    private var activationCounts: [String: [String: Int]] = [:]

    init() {
        buildDecisionTree()
    }

    func evaluate(
        signal: AutopilotSignal,
        classification: SignalClassification,
        sessionState: AutopilotSessionState,
        mode: AutopilotMode,
        globalThreatLevel: Double
    ) -> GraphDecisionResult {
        for node in nodes {
            guard node.signalTypes.contains(signal.type) else { continue }
            guard classification.severity >= node.minSeverity else { continue }
            guard sessionState.threatLevel >= node.minThreatLevel || globalThreatLevel >= node.minThreatLevel else { continue }

            if let requiredMode = node.requiredMode {
                guard modeLevel(mode) >= modeLevel(requiredMode) else { continue }
            }

            let nodeKey = "\(node.action.rawValue)_\(node.signalTypes.map(\.rawValue).sorted().joined())"
            if let lastFire = lastActivation[nodeKey], Date().timeIntervalSince(lastFire) < node.cooldownSeconds {
                continue
            }

            let sessionActivations = activationCounts[sessionState.sessionId]?[nodeKey] ?? 0
            if sessionActivations >= node.maxActivationsPerSession {
                continue
            }

            let params = node.parameterGenerator?(signal, sessionState) ?? [:]

            lastActivation[nodeKey] = Date()
            activationCounts[sessionState.sessionId, default: [:]][nodeKey, default: 0] += 1

            return GraphDecisionResult(
                action: node.action,
                priority: node.priority,
                confidence: classification.severity,
                reasoning: node.reasoning,
                parameters: params
            )
        }

        return GraphDecisionResult(
            action: .noOp, priority: .low, confidence: 0,
            reasoning: "No matching decision node", parameters: [:]
        )
    }

    func clearSessionActivations(_ sessionId: String) {
        activationCounts.removeValue(forKey: sessionId)
    }

    private func modeLevel(_ mode: AutopilotMode) -> Int {
        switch mode {
        case .off: return 0
        case .passive: return 1
        case .active: return 2
        case .aggressive: return 3
        }
    }

    private func buildDecisionTree() {
        nodes = [
            DecisionNode(
                signalTypes: [.challengeFormingDetected],
                minSeverity: 0.6, minThreatLevel: 0.0,
                action: .preemptiveIPRotation,
                priority: .critical,
                reasoning: "Challenge page forming — preemptive IP rotation before page fully loads",
                cooldownSeconds: 15, maxActivationsPerSession: 3,
                requiredMode: .active,
                parameterGenerator: { signal, state in
                    ["host": signal.host, "trigger": "challenge_forming", "rotationCount": "\(state.proxyRotationCount)"]
                }
            ),

            DecisionNode(
                signalTypes: [.captchaFormingDetected],
                minSeverity: 0.5, minThreatLevel: 0.0,
                action: .preemptiveProxySwitch,
                priority: .critical,
                reasoning: "CAPTCHA element detected in DOM — preemptive proxy switch before challenge activates",
                cooldownSeconds: 20, maxActivationsPerSession: 3,
                requiredMode: .active,
                parameterGenerator: { signal, state in
                    var params = ["host": signal.host, "trigger": "captcha_forming"]
                    if state.proxyRotationCount >= 2 {
                        params["escalate"] = "rotateFingerprint"
                    }
                    return params
                }
            ),

            DecisionNode(
                signalTypes: [.webDriverProbeDetected],
                minSeverity: 0.5, minThreatLevel: 0.0,
                action: .injectCounterFingerprint,
                priority: .high,
                reasoning: "WebDriver probe detected — injecting counter-fingerprint to mask automation",
                cooldownSeconds: 10, maxActivationsPerSession: 5,
                requiredMode: .passive,
                parameterGenerator: { signal, _ in
                    ["probeType": "webdriver", "host": signal.host, "detail": signal.metadata["detail"] ?? ""]
                }
            ),

            DecisionNode(
                signalTypes: [.fingerprintProbeDetected, .canvasProbeDetected],
                minSeverity: 0.5, minThreatLevel: 0.2,
                action: .rotateFingerprint,
                priority: .high,
                reasoning: "Fingerprint/canvas probe detected — rotating fingerprint profile before results collected",
                cooldownSeconds: 25, maxActivationsPerSession: 3,
                requiredMode: .active,
                parameterGenerator: { signal, state in
                    ["probeType": signal.type.rawValue, "host": signal.host, "currentFPRotations": "\(state.fingerprintRotationCount)"]
                }
            ),

            DecisionNode(
                signalTypes: [.typingVelocityAnomaly],
                minSeverity: 0.4, minThreatLevel: 0.0,
                action: .adjustTypingSpeed,
                priority: .medium,
                reasoning: "Typing velocity flagged as non-human — adjusting speed to match learned profile",
                cooldownSeconds: 8, maxActivationsPerSession: 6,
                requiredMode: .passive,
                parameterGenerator: { signal, _ in
                    let currentSpeed = signal.metadata["currentSpeedMs"] ?? "80"
                    let targetSpeed = max(90, (Int(currentSpeed) ?? 80) + Int.random(in: 15...40))
                    return ["targetKeystrokeMs": "\(targetSpeed)", "host": signal.host, "jitter": "\(Int.random(in: 10...30))"]
                }
            ),

            DecisionNode(
                signalTypes: [.timingAnomalyDetected],
                minSeverity: 0.4, minThreatLevel: 0.15,
                action: .slowDownInteraction,
                priority: .medium,
                reasoning: "Timing anomaly detected — slowing interaction cadence to appear more natural",
                cooldownSeconds: 12, maxActivationsPerSession: 4,
                requiredMode: .passive,
                parameterGenerator: { signal, _ in
                    ["slowdownPercent": "\(Int.random(in: 20...50))", "host": signal.host]
                }
            ),

            DecisionNode(
                signalTypes: [.rateLimitSignal],
                minSeverity: 0.5, minThreatLevel: 0.0,
                action: .throttleRequests,
                priority: .high,
                reasoning: "Rate limit signal detected — throttling requests and switching proxy",
                cooldownSeconds: 30, maxActivationsPerSession: 3,
                requiredMode: .passive,
                parameterGenerator: { signal, state in
                    let backoffMs = min(10000, 2000 * (1 + state.proxyRotationCount))
                    return ["backoffMs": "\(backoffMs)", "host": signal.host, "httpStatus": signal.metadata["httpStatus"] ?? ""]
                }
            ),

            DecisionNode(
                signalTypes: [.blankPageDetected],
                minSeverity: 0.5, minThreatLevel: 0.0,
                action: .rotateDNS,
                priority: .high,
                reasoning: "Blank page detected — rotating DNS and waiting for recovery",
                cooldownSeconds: 20, maxActivationsPerSession: 3,
                requiredMode: .active,
                parameterGenerator: { signal, _ in
                    ["host": signal.host, "recoveryAction": "dns_rotation"]
                }
            ),

            DecisionNode(
                signalTypes: [.connectionDegraded, .proxyLatencySpike],
                minSeverity: 0.4, minThreatLevel: 0.2,
                action: .preemptiveProxySwitch,
                priority: .medium,
                reasoning: "Connection degraded or proxy latency spike — preemptive proxy switch",
                cooldownSeconds: 15, maxActivationsPerSession: 4,
                requiredMode: .active,
                parameterGenerator: { signal, _ in
                    ["reason": signal.type.rawValue, "latencyMs": signal.metadata["latencyMs"] ?? "", "host": signal.host]
                }
            ),

            DecisionNode(
                signalTypes: [.cookieBombDetected],
                minSeverity: 0.5, minThreatLevel: 0.0,
                action: .preemptiveCookieClear,
                priority: .high,
                reasoning: "Cookie bomb detected — clearing cookies before tracking payload activates",
                cooldownSeconds: 15, maxActivationsPerSession: 3,
                requiredMode: .passive,
                parameterGenerator: { signal, _ in
                    ["host": signal.host]
                }
            ),

            DecisionNode(
                signalTypes: [.httpStatusAnomaly],
                minSeverity: 0.5, minThreatLevel: 0.3,
                action: .rotateURL,
                priority: .medium,
                reasoning: "HTTP status anomaly — rotating to alternate URL",
                cooldownSeconds: 20, maxActivationsPerSession: 3,
                requiredMode: .active,
                parameterGenerator: { signal, _ in
                    ["httpStatus": signal.metadata["httpStatus"] ?? "", "host": signal.host]
                }
            ),

            DecisionNode(
                signalTypes: [.redirectDetected],
                minSeverity: 0.5, minThreatLevel: 0.4,
                action: .pauseAndWait,
                priority: .medium,
                reasoning: "Suspicious redirect — pausing to evaluate before continuing",
                cooldownSeconds: 10, maxActivationsPerSession: 4,
                requiredMode: .passive,
                parameterGenerator: { signal, _ in
                    ["fromURL": signal.metadata["fromURL"] ?? "", "toURL": signal.metadata["toURL"] ?? "", "waitMs": "2000"]
                }
            ),

            DecisionNode(
                signalTypes: [.sessionHealthDegraded],
                minSeverity: 0.6, minThreatLevel: 0.5,
                action: .fullSessionReset,
                priority: .critical,
                reasoning: "Session health critically degraded — full session reset with new identity",
                cooldownSeconds: 60, maxActivationsPerSession: 1,
                requiredMode: .aggressive,
                parameterGenerator: { signal, state in
                    ["host": signal.host, "threatLevel": String(format: "%.2f", state.threatLevel), "interventions": "\(state.totalInterventions)"]
                }
            ),

            DecisionNode(
                signalTypes: [.challengeFormingDetected, .captchaFormingDetected, .rateLimitSignal],
                minSeverity: 0.8, minThreatLevel: 0.7,
                action: .abortSession,
                priority: .emergency,
                reasoning: "Multiple critical signals with extreme threat — aborting session to prevent blacklisting",
                cooldownSeconds: 5, maxActivationsPerSession: 1,
                requiredMode: .aggressive,
                parameterGenerator: { signal, state in
                    ["host": signal.host, "threatLevel": String(format: "%.2f", state.threatLevel), "reason": "threat_overload"]
                }
            ),

            DecisionNode(
                signalTypes: [.fingerprintProbeDetected, .webDriverProbeDetected],
                minSeverity: 0.7, minThreatLevel: 0.5,
                action: .switchInteractionPattern,
                priority: .high,
                reasoning: "Detection probes active — switching interaction pattern to evade behavioral profiling",
                cooldownSeconds: 30, maxActivationsPerSession: 2,
                requiredMode: .active,
                parameterGenerator: { signal, state in
                    ["currentPatternSwitches": "\(state.patternSwitchCount)", "host": signal.host]
                }
            ),

            DecisionNode(
                signalTypes: [.jsErrorDetected],
                minSeverity: 0.5, minThreatLevel: 0.3,
                action: .escalateToAI,
                priority: .medium,
                reasoning: "JS error during session — escalating to AI for deeper analysis",
                cooldownSeconds: 30, maxActivationsPerSession: 2,
                requiredMode: .active,
                parameterGenerator: { signal, _ in
                    ["errorDetail": signal.metadata["detail"] ?? "", "host": signal.host]
                }
            ),
        ]
    }
}
