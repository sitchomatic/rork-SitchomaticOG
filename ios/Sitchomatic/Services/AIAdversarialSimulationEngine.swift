import Foundation

@MainActor
class AIAdversarialSimulationEngine {
    static let shared = AIAdversarialSimulationEngine()

    private let logger = DebugLogger.shared
    private let knowledgeGraph = AIKnowledgeGraphService.shared
    private let persistenceKey = "AIAdversarialSimulation_v1"

    private(set) var store: AdversarialSimulationStore
    private(set) var isRunning: Bool = false

    private init() {
        if let saved = UserDefaults.standard.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode(AdversarialSimulationStore.self, from: saved) {
            self.store = decoded
        } else {
            self.store = AdversarialSimulationStore()
        }
    }

    private let scenarioLibrary: [AdversarialScenario] = [
        AdversarialScenario(
            type: .timingDetection,
            difficulty: .basic,
            name: "Keystroke Cadence Check",
            description: "Tests if keystroke timing appears robotic or unnaturally uniform",
            expectedSignals: ["uniform_keystroke", "zero_variance", "instant_typing"],
            thresholds: .init(maxAcceptableDetectionRate: 0.15, minRequiredEvasionScore: 0.85, maxLatencyMs: 200, maxRetries: 0),
            weight: 1.0
        ),
        AdversarialScenario(
            type: .timingDetection,
            difficulty: .advanced,
            name: "Behavioral Timing Analysis",
            description: "Advanced timing detection using inter-field delays and pre-submit hesitation patterns",
            expectedSignals: ["linear_inter_field", "no_hesitation", "predictable_cadence", "mouse_teleport"],
            thresholds: .init(maxAcceptableDetectionRate: 0.10, minRequiredEvasionScore: 0.90, maxLatencyMs: 500, maxRetries: 1),
            weight: 1.5
        ),
        AdversarialScenario(
            type: .fingerprintDetection,
            difficulty: .basic,
            name: "Canvas Fingerprint Probe",
            description: "Checks if canvas fingerprint is consistent and non-default",
            expectedSignals: ["default_canvas", "missing_webgl", "headless_ua"],
            thresholds: .init(maxAcceptableDetectionRate: 0.20, minRequiredEvasionScore: 0.80, maxLatencyMs: 100, maxRetries: 0),
            weight: 1.0
        ),
        AdversarialScenario(
            type: .fingerprintDetection,
            difficulty: .advanced,
            name: "Deep Fingerprint Consistency",
            description: "Cross-references multiple fingerprint vectors for inconsistencies",
            expectedSignals: ["screen_mismatch", "timezone_mismatch", "language_mismatch", "plugin_anomaly", "webrtc_leak"],
            thresholds: .init(maxAcceptableDetectionRate: 0.08, minRequiredEvasionScore: 0.92, maxLatencyMs: 300, maxRetries: 1),
            weight: 2.0
        ),
        AdversarialScenario(
            type: .fingerprintDetection,
            difficulty: .expert,
            name: "JS Environment Integrity",
            description: "Detects patched browser APIs, prototype tampering, and automation markers",
            expectedSignals: ["navigator_tampered", "prototype_modified", "automation_flag", "devtools_detected", "stacktrace_anomaly"],
            thresholds: .init(maxAcceptableDetectionRate: 0.05, minRequiredEvasionScore: 0.95, maxLatencyMs: 150, maxRetries: 0),
            weight: 2.5
        ),
        AdversarialScenario(
            type: .proxyBlocking,
            difficulty: .basic,
            name: "IP Reputation Check",
            description: "Tests if the current proxy IP is flagged in common blocklists",
            expectedSignals: ["ip_blacklisted", "datacenter_ip", "vpn_detected"],
            thresholds: .init(maxAcceptableDetectionRate: 0.20, minRequiredEvasionScore: 0.80, maxLatencyMs: 2000, maxRetries: 2),
            weight: 1.0
        ),
        AdversarialScenario(
            type: .proxyBlocking,
            difficulty: .intermediate,
            name: "Geo-Consistency Verification",
            description: "Checks if proxy location matches timezone, language, and locale signals",
            expectedSignals: ["geo_tz_mismatch", "geo_lang_mismatch", "geo_locale_mismatch"],
            thresholds: .init(maxAcceptableDetectionRate: 0.12, minRequiredEvasionScore: 0.88, maxLatencyMs: 1500, maxRetries: 1),
            weight: 1.5
        ),
        AdversarialScenario(
            type: .challengePage,
            difficulty: .intermediate,
            name: "CAPTCHA Detection Resilience",
            description: "Simulates encountering various CAPTCHA and challenge page types",
            expectedSignals: ["captcha_present", "js_challenge", "turnstile_detected", "recaptcha_v3"],
            thresholds: .init(maxAcceptableDetectionRate: 0.30, minRequiredEvasionScore: 0.70, maxLatencyMs: 5000, maxRetries: 3),
            weight: 1.5
        ),
        AdversarialScenario(
            type: .rateLimiting,
            difficulty: .intermediate,
            name: "Rate Limit Boundary Test",
            description: "Probes request frequency thresholds to find rate limit boundaries",
            expectedSignals: ["429_response", "soft_block", "increasing_latency", "connection_reset"],
            thresholds: .init(maxAcceptableDetectionRate: 0.25, minRequiredEvasionScore: 0.75, maxLatencyMs: 3000, maxRetries: 2),
            weight: 1.0
        ),
        AdversarialScenario(
            type: .rateLimiting,
            difficulty: .expert,
            name: "Distributed Rate Limit Evasion",
            description: "Tests coordinated multi-proxy request distribution to avoid aggregate rate limits",
            expectedSignals: ["aggregate_block", "session_correlation", "ip_rotation_detected"],
            thresholds: .init(maxAcceptableDetectionRate: 0.10, minRequiredEvasionScore: 0.90, maxLatencyMs: 4000, maxRetries: 1),
            weight: 2.0
        ),
        AdversarialScenario(
            type: .behavioralAnalysis,
            difficulty: .advanced,
            name: "Mouse Movement Naturalism",
            description: "Evaluates whether mouse/pointer movement patterns appear human-like",
            expectedSignals: ["linear_movement", "instant_teleport", "no_micro_jitter", "uniform_velocity"],
            thresholds: .init(maxAcceptableDetectionRate: 0.10, minRequiredEvasionScore: 0.90, maxLatencyMs: 300, maxRetries: 0),
            weight: 1.5
        ),
        AdversarialScenario(
            type: .headerInspection,
            difficulty: .basic,
            name: "Request Header Consistency",
            description: "Validates HTTP headers match expected browser signature",
            expectedSignals: ["missing_accept", "wrong_encoding", "bot_ua_substring", "missing_referer"],
            thresholds: .init(maxAcceptableDetectionRate: 0.15, minRequiredEvasionScore: 0.85, maxLatencyMs: 100, maxRetries: 0),
            weight: 1.0
        ),
        AdversarialScenario(
            type: .cookieTracking,
            difficulty: .intermediate,
            name: "Cookie Lifecycle Tracking",
            description: "Tests if session cookies are properly maintained and not prematurely cleared",
            expectedSignals: ["missing_session_cookie", "cookie_mismatch", "expired_token", "duplicate_session"],
            thresholds: .init(maxAcceptableDetectionRate: 0.15, minRequiredEvasionScore: 0.85, maxLatencyMs: 200, maxRetries: 1),
            weight: 1.0
        ),
        AdversarialScenario(
            type: .jsEnvironmentProbe,
            difficulty: .expert,
            name: "WebDriver & Automation Detection",
            description: "Probes for WebDriver, CDP, and automation framework fingerprints",
            expectedSignals: ["webdriver_present", "cdp_detected", "phantom_objects", "selenium_traces", "puppeteer_markers"],
            thresholds: .init(maxAcceptableDetectionRate: 0.05, minRequiredEvasionScore: 0.95, maxLatencyMs: 100, maxRetries: 0),
            weight: 2.5
        ),
        AdversarialScenario(
            type: .compositeDefense,
            difficulty: .expert,
            name: "Full-Stack Defense Simulation",
            description: "Combined multi-layer detection simulating enterprise-grade anti-bot defense",
            expectedSignals: ["multi_vector_correlation", "behavioral_score_low", "fingerprint_inconsistent", "timing_anomaly", "proxy_flagged"],
            thresholds: .init(maxAcceptableDetectionRate: 0.08, minRequiredEvasionScore: 0.92, maxLatencyMs: 5000, maxRetries: 2),
            weight: 3.0
        ),
    ]

    func getScenarioLibrary() -> [AdversarialScenario] {
        scenarioLibrary
    }

    func getScenariosForType(_ type: AdversarialScenarioType) -> [AdversarialScenario] {
        scenarioLibrary.filter { $0.type == type }
    }

    func getScenariosForDifficulty(_ difficulty: AdversarialDifficulty) -> [AdversarialScenario] {
        scenarioLibrary.filter { $0.difficulty == difficulty }
    }

    func runSimulation(
        host: String,
        difficulty: AdversarialDifficulty = .intermediate,
        scenarioTypes: [AdversarialScenarioType]? = nil
    ) async -> SimulationSuite {
        guard !isRunning else {
            logger.log("AdversarialSim: simulation already running, skipping", category: .automation, level: .warning)
            return createEmptySuite(host: host, difficulty: difficulty)
        }

        isRunning = true
        let suiteStart = Date()
        logger.log("AdversarialSim: starting \(difficulty.label) simulation for \(host)", category: .automation, level: .info)

        let scenarios: [AdversarialScenario]
        if let types = scenarioTypes {
            scenarios = scenarioLibrary.filter { types.contains($0.type) && $0.difficulty.multiplier <= difficulty.multiplier }
        } else {
            scenarios = scenarioLibrary.filter { $0.difficulty.multiplier <= difficulty.multiplier }
        }

        let intel = knowledgeGraph.getHostIntelligence(host: host)
        var results: [SimulationResult] = []

        for scenario in scenarios {
            let result = await runScenario(scenario, host: host, intel: intel)
            results.append(result)

            publishResultToKnowledgeGraph(result, host: host)
        }

        let overallScore = computeOverallScore(results: results)
        let overallVerdict = computeOverallVerdict(score: overallScore, results: results)
        let passed = results.filter { $0.verdict == .passed || $0.verdict == .marginal }.count
        let durationMs = Int(Date().timeIntervalSince(suiteStart) * 1000)

        let suite = SimulationSuite(
            host: host,
            difficulty: difficulty,
            results: results,
            overallScore: overallScore,
            overallVerdict: overallVerdict,
            timestamp: Date(),
            durationMs: durationMs,
            scenariosRun: results.count,
            scenariosPassed: passed
        )

        store.suites.insert(suite, at: 0)
        if store.suites.count > store.maxStoredSuites {
            store.suites = Array(store.suites.prefix(store.maxStoredSuites))
        }
        store.lastRunPerHost[host] = Date()
        store.totalSimulationsRun += results.count
        save()

        let healingActions = generateAutoHealingActions(from: results, host: host)
        if !healingActions.isEmpty {
            store.autoHealingActions.append(contentsOf: healingActions)
            if store.autoHealingActions.count > 200 {
                store.autoHealingActions = Array(store.autoHealingActions.suffix(200))
            }
            save()
        }

        isRunning = false

        logger.log("AdversarialSim: completed \(results.count) scenarios for \(host) — score \(String(format: "%.0f%%", overallScore * 100)) verdict \(overallVerdict.label)", category: .automation, level: .info)

        return suite
    }

    private func runScenario(
        _ scenario: AdversarialScenario,
        host: String,
        intel: UnifiedHostIntelligence
    ) async -> SimulationResult {
        let start = Date()

        let (detectedSignals, evasionScore) = evaluateScenario(scenario, intel: intel)
        let detectionRate = detectedSignals.isEmpty ? 0 : Double(detectedSignals.count) / Double(scenario.expectedSignals.count)

        let baseLatency = estimateLatency(for: scenario, intel: intel)

        let verdict: SimulationVerdict
        if detectionRate <= scenario.thresholds.maxAcceptableDetectionRate && evasionScore >= scenario.thresholds.minRequiredEvasionScore {
            verdict = .passed
        } else if detectionRate <= scenario.thresholds.maxAcceptableDetectionRate * 1.5 && evasionScore >= scenario.thresholds.minRequiredEvasionScore * 0.9 {
            verdict = .marginal
        } else if detectionRate >= 0.6 || evasionScore < 0.5 {
            verdict = .critical
        } else {
            verdict = .failed
        }

        let recommendations = generateRecommendations(for: scenario, detectedSignals: detectedSignals, intel: intel)
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        return SimulationResult(
            scenarioId: scenario.id,
            scenarioType: scenario.type,
            scenarioName: scenario.name,
            difficulty: scenario.difficulty,
            verdict: verdict,
            detectedSignals: detectedSignals,
            evasionScore: evasionScore,
            detectionRate: detectionRate,
            latencyMs: baseLatency,
            retryCount: 0,
            recommendations: recommendations,
            timestamp: Date(),
            durationMs: durationMs,
            host: host
        )
    }

    private func evaluateScenario(
        _ scenario: AdversarialScenario,
        intel: UnifiedHostIntelligence
    ) -> (detectedSignals: [String], evasionScore: Double) {
        var detected: [String] = []
        var baseScore: Double = 1.0

        switch scenario.type {
        case .timingDetection:
            let tp = intel.timingProfile
            if tp.optimalKeystrokeMs < 40 {
                detected.append("instant_typing")
                baseScore -= 0.3
            }
            if tp.optimalInterFieldMs < 100 {
                detected.append("linear_inter_field")
                baseScore -= 0.2
            }
            if tp.optimalPreSubmitMs < 200 {
                detected.append("no_hesitation")
                baseScore -= 0.15
            }
            if tp.fillRate > 0.95 {
                detected.append("predictable_cadence")
                baseScore -= 0.1
            }
            if intel.timingDetectionRate > 0.3 {
                baseScore -= intel.timingDetectionRate * 0.3
            }

        case .fingerprintDetection:
            if intel.fingerprintDetectionRate > 0.2 {
                baseScore -= intel.fingerprintDetectionRate * 0.4
            }
            for signal in intel.fingerprintTopSignals {
                if scenario.expectedSignals.contains(signal) {
                    detected.append(signal)
                    baseScore -= 0.15
                }
            }
            if intel.preferredFingerprintIndices.isEmpty {
                detected.append("default_canvas")
                baseScore -= 0.1
            }

        case .proxyBlocking:
            if intel.proxyBlockRate > 0.3 {
                detected.append("ip_blacklisted")
                baseScore -= intel.proxyBlockRate * 0.5
            }
            if intel.proxyAvgLatencyMs > 2000 {
                detected.append("datacenter_ip")
                baseScore -= 0.15
            }
            if intel.bestProxyIds.isEmpty {
                detected.append("vpn_detected")
                baseScore -= 0.1
            }

        case .challengePage:
            let challengeEvents = knowledgeGraph.getRecentEvents(domain: .challenge, host: intel.host, limit: 20)
            let challengeRate = challengeEvents.isEmpty ? 0 : Double(challengeEvents.filter { $0.payload["triggered"] == "true" }.count) / Double(max(1, challengeEvents.count))
            if challengeRate > 0.2 {
                detected.append("captcha_present")
                baseScore -= challengeRate * 0.4
            }
            if challengeRate > 0.4 {
                detected.append("js_challenge")
                baseScore -= 0.2
            }

        case .rateLimiting:
            let anomalyForecast = intel.anomalyForecast
            if anomalyForecast == "degrading" {
                detected.append("increasing_latency")
                baseScore -= 0.2
            }
            if intel.anomalyRiskLevel > 0.5 {
                detected.append("soft_block")
                baseScore -= intel.anomalyRiskLevel * 0.3
            }

        case .behavioralAnalysis:
            if intel.interactionSuccessRate < 0.7 {
                detected.append("linear_movement")
                baseScore -= (1.0 - intel.interactionSuccessRate) * 0.3
            }
            if intel.timingDetectionRate > 0.2 {
                detected.append("uniform_velocity")
                baseScore -= 0.15
            }

        case .headerInspection:
            let detectionEvents = knowledgeGraph.getRecentEvents(domain: .detection, host: intel.host, limit: 10)
            let headerSignals = detectionEvents.flatMap { ($0.payload["signals"] ?? "").components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            for signal in scenario.expectedSignals {
                if headerSignals.contains(signal) {
                    detected.append(signal)
                    baseScore -= 0.2
                }
            }

        case .cookieTracking:
            if intel.rescueAttempts > 5 && intel.rescueSuccessRate < 0.5 {
                detected.append("missing_session_cookie")
                baseScore -= 0.2
            }

        case .jsEnvironmentProbe:
            for signal in intel.topDetectionSignals {
                if scenario.expectedSignals.contains(signal) {
                    detected.append(signal)
                    baseScore -= 0.25
                }
            }
            if intel.detectionThreatLevel > 0.6 {
                baseScore -= 0.2
            }

        case .compositeDefense:
            if intel.detectionThreatLevel > 0.4 {
                detected.append("behavioral_score_low")
                baseScore -= intel.detectionThreatLevel * 0.2
            }
            if intel.fingerprintDetectionRate > 0.15 {
                detected.append("fingerprint_inconsistent")
                baseScore -= 0.15
            }
            if intel.timingDetectionRate > 0.15 {
                detected.append("timing_anomaly")
                baseScore -= 0.15
            }
            if intel.proxyBlockRate > 0.2 {
                detected.append("proxy_flagged")
                baseScore -= 0.1
            }
            if detected.count >= 3 {
                detected.append("multi_vector_correlation")
                baseScore -= 0.2
            }
        }

        let difficultyPenalty = (scenario.difficulty.multiplier - 1.0) * 0.05
        baseScore -= difficultyPenalty

        let finalScore = max(0, min(1.0, baseScore))
        return (detected, finalScore)
    }

    private func estimateLatency(for scenario: AdversarialScenario, intel: UnifiedHostIntelligence) -> Int {
        var base = intel.proxyAvgLatencyMs > 0 ? intel.proxyAvgLatencyMs : 150
        switch scenario.type {
        case .proxyBlocking: base += 300
        case .challengePage: base += 1000
        case .rateLimiting: base += 500
        case .compositeDefense: base += 800
        default: break
        }
        return base
    }

    private func generateRecommendations(
        for scenario: AdversarialScenario,
        detectedSignals: [String],
        intel: UnifiedHostIntelligence
    ) -> [SimulationRecommendation] {
        guard !detectedSignals.isEmpty else { return [] }
        var recs: [SimulationRecommendation] = []

        for signal in detectedSignals {
            switch signal {
            case "instant_typing", "uniform_keystroke", "zero_variance":
                recs.append(SimulationRecommendation(
                    domain: "timing",
                    action: "Increase keystroke delay variance to 60-120ms with gaussian jitter",
                    priority: .high,
                    settingKey: "keystrokeDelayMs",
                    suggestedValue: "80"
                ))
            case "linear_inter_field", "no_hesitation":
                recs.append(SimulationRecommendation(
                    domain: "timing",
                    action: "Add natural inter-field pauses with random hesitation patterns",
                    priority: .medium,
                    settingKey: "interFieldDelayMs",
                    suggestedValue: "400"
                ))
            case "predictable_cadence":
                recs.append(SimulationRecommendation(
                    domain: "timing",
                    action: "Introduce micro-pauses and variable typing speed within each field",
                    priority: .medium,
                    settingKey: nil,
                    suggestedValue: nil
                ))
            case "default_canvas", "missing_webgl":
                recs.append(SimulationRecommendation(
                    domain: "fingerprint",
                    action: "Enable canvas/WebGL fingerprint spoofing with realistic noise injection",
                    priority: .high,
                    settingKey: "fingerprintSpoofing",
                    suggestedValue: "true"
                ))
            case "screen_mismatch", "timezone_mismatch", "language_mismatch":
                recs.append(SimulationRecommendation(
                    domain: "fingerprint",
                    action: "Ensure fingerprint vectors are mutually consistent (screen, timezone, language)",
                    priority: .critical,
                    settingKey: nil,
                    suggestedValue: nil
                ))
            case "ip_blacklisted":
                recs.append(SimulationRecommendation(
                    domain: "proxy",
                    action: "Rotate to residential proxy pool — current IP is flagged",
                    priority: .critical,
                    settingKey: "proxyType",
                    suggestedValue: "residential"
                ))
            case "datacenter_ip":
                recs.append(SimulationRecommendation(
                    domain: "proxy",
                    action: "Switch from datacenter to residential or ISP proxies",
                    priority: .high,
                    settingKey: nil,
                    suggestedValue: nil
                ))
            case "geo_tz_mismatch", "geo_lang_mismatch", "geo_locale_mismatch":
                recs.append(SimulationRecommendation(
                    domain: "proxy",
                    action: "Match proxy geo-location with browser timezone and language settings",
                    priority: .high,
                    settingKey: nil,
                    suggestedValue: nil
                ))
            case "captcha_present", "js_challenge", "turnstile_detected":
                recs.append(SimulationRecommendation(
                    domain: "challenge",
                    action: "Enable challenge page solver or reduce request frequency to avoid triggers",
                    priority: .high,
                    settingKey: nil,
                    suggestedValue: nil
                ))
            case "429_response", "soft_block", "increasing_latency":
                recs.append(SimulationRecommendation(
                    domain: "rate_limit",
                    action: "Reduce concurrency and add exponential backoff between requests",
                    priority: .high,
                    settingKey: "maxConcurrency",
                    suggestedValue: "2"
                ))
            case "linear_movement", "instant_teleport", "uniform_velocity":
                recs.append(SimulationRecommendation(
                    domain: "interaction",
                    action: "Enable bezier curve mouse movement with velocity variation",
                    priority: .medium,
                    settingKey: nil,
                    suggestedValue: nil
                ))
            case "webdriver_present", "cdp_detected", "automation_flag", "selenium_traces", "puppeteer_markers":
                recs.append(SimulationRecommendation(
                    domain: "environment",
                    action: "Patch navigator.webdriver and remove automation framework artifacts",
                    priority: .critical,
                    settingKey: nil,
                    suggestedValue: nil
                ))
            case "navigator_tampered", "prototype_modified", "stacktrace_anomaly":
                recs.append(SimulationRecommendation(
                    domain: "environment",
                    action: "Use native property descriptors instead of JS overrides to avoid prototype tampering detection",
                    priority: .critical,
                    settingKey: nil,
                    suggestedValue: nil
                ))
            case "multi_vector_correlation":
                recs.append(SimulationRecommendation(
                    domain: "composite",
                    action: "Multiple detection vectors correlating — consider full profile rotation and session reset",
                    priority: .critical,
                    settingKey: nil,
                    suggestedValue: nil
                ))
            default:
                break
            }
        }

        return recs
    }

    private func generateAutoHealingActions(from results: [SimulationResult], host: String) -> [AutoHealingAction] {
        var actions: [AutoHealingAction] = []

        for result in results where result.verdict == .critical || result.verdict == .failed {
            for rec in result.recommendations {
                guard let settingKey = rec.settingKey, let suggestedValue = rec.suggestedValue else { continue }
                let action = AutoHealingAction(
                    host: host,
                    scenarioType: result.scenarioType,
                    settingKey: settingKey,
                    oldValue: "current",
                    newValue: suggestedValue,
                    reason: "\(result.scenarioName): \(rec.action)",
                    timestamp: Date()
                )
                actions.append(action)
            }
        }

        if !actions.isEmpty {
            logger.log("AdversarialSim: generated \(actions.count) auto-healing actions for \(host)", category: .automation, level: .info)
        }

        return actions
    }

    private func computeOverallScore(results: [SimulationResult]) -> Double {
        guard !results.isEmpty else { return 1.0 }
        let totalWeight = results.reduce(0.0) { sum, r in
            let scenario = scenarioLibrary.first { $0.id == r.scenarioId }
            return sum + (scenario?.weight ?? 1.0)
        }
        guard totalWeight > 0 else { return 1.0 }

        let weightedScore = results.reduce(0.0) { sum, r in
            let scenario = scenarioLibrary.first { $0.id == r.scenarioId }
            return sum + r.evasionScore * (scenario?.weight ?? 1.0)
        }
        return weightedScore / totalWeight
    }

    private func computeOverallVerdict(score: Double, results: [SimulationResult]) -> SimulationVerdict {
        let criticalCount = results.filter { $0.verdict == .critical }.count
        let failedCount = results.filter { $0.verdict == .failed }.count

        if criticalCount >= 2 || score < 0.5 { return .critical }
        if criticalCount >= 1 || failedCount >= 3 || score < 0.65 { return .failed }
        if failedCount >= 1 || score < 0.8 { return .marginal }
        return .passed
    }

    private func publishResultToKnowledgeGraph(_ result: SimulationResult, host: String) {
        let severity: KnowledgeSeverity
        switch result.verdict {
        case .critical: severity = .critical
        case .failed: severity = .high
        case .marginal: severity = .medium
        case .passed: severity = .low
        }

        var payload: [String: String] = [
            "scenarioType": result.scenarioType.rawValue,
            "difficulty": result.difficulty.rawValue,
            "verdict": result.verdict.rawValue,
            "evasionScore": String(format: "%.2f", result.evasionScore),
            "detectionRate": String(format: "%.2f", result.detectionRate),
            "signals": result.detectedSignals.joined(separator: ","),
        ]
        if !result.recommendations.isEmpty {
            payload["topRecommendation"] = result.recommendations.first?.action ?? ""
        }

        knowledgeGraph.publishEvent(
            source: "AIAdversarialSimulation",
            host: host,
            domain: .detection,
            type: .strategyOutcome,
            severity: severity,
            confidence: 0.85,
            payload: payload,
            summary: "Sim[\(result.scenarioName)] \(result.verdict.label) — evasion \(String(format: "%.0f%%", result.evasionScore * 100)) detection \(String(format: "%.0f%%", result.detectionRate * 100))"
        )
    }

    func shouldRunSimulation(host: String, cooldownMinutes: Int = 30) -> Bool {
        guard let lastRun = store.lastRunPerHost[host] else { return true }
        return Date().timeIntervalSince(lastRun) > Double(cooldownMinutes) * 60
    }

    func getLatestSuite(host: String) -> SimulationSuite? {
        store.suites.first { $0.host == host }
    }

    func getAllSuites(limit: Int = 20) -> [SimulationSuite] {
        Array(store.suites.prefix(limit))
    }

    func getAutoHealingActions(host: String? = nil) -> [AutoHealingAction] {
        if let host {
            return store.autoHealingActions.filter { $0.host == host }
        }
        return store.autoHealingActions
    }

    func getPendingHealingActions(host: String) -> [AutoHealingAction] {
        store.autoHealingActions.filter { $0.host == host && !$0.reverted }
    }

    func markHealingActionReverted(id: String) {
        if let index = store.autoHealingActions.firstIndex(where: { $0.id == id }) {
            store.autoHealingActions[index].reverted = true
            save()
        }
    }

    func resetAll() {
        store = AdversarialSimulationStore()
        save()
        logger.log("AdversarialSim: full reset", category: .automation, level: .info)
    }

    private func createEmptySuite(host: String, difficulty: AdversarialDifficulty) -> SimulationSuite {
        SimulationSuite(
            host: host,
            difficulty: difficulty,
            results: [],
            overallScore: 0,
            overallVerdict: .failed,
            timestamp: Date(),
            durationMs: 0,
            scenariosRun: 0,
            scenariosPassed: 0
        )
    }

    private func save() {
        if let data = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
        }
    }
}
