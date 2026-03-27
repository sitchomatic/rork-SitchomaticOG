import Foundation

class SettingVariationGenerator {
    static let shared = SettingVariationGenerator()

    private let proxyService = ProxyRotationService.shared

    private let typingSpeeds: [(label: String, min: Int, max: Int)] = [
        ("Fast Typing", 40, 80),
        ("Medium Typing", 80, 150),
        ("Slow Typing", 150, 280),
        ("Very Slow Typing", 280, 450),
    ]

    private let patterns: [String] = [
        "TRUE DETECTION",
        "Tab Navigation",
        "Click-Focus Sequential",
        "Calibrated Typing",
        "Calibrated Direct",
        "Form Submit Direct",
    ]

    private let preSubmitDelays: [(label: String, ms: Int)] = [
        ("No PreSubmit Delay", 0),
        ("Short PreSubmit", 350),
        ("Medium PreSubmit", 800),
        ("Long PreSubmit", 1500),
    ]

    private let postSubmitDelays: [(label: String, ms: Int)] = [
        ("No PostSubmit Delay", 0),
        ("Short PostSubmit", 600),
        ("Medium PostSubmit", 1200),
        ("Long PostSubmit", 2000),
    ]

    private let pageLoadDelays: [(label: String, ms: Int)] = [
        ("No Page Delay", 0),
        ("Short Page Delay", 1000),
        ("Medium Page Delay", 2000),
        ("Long Page Delay", 4000),
    ]

    private let sessionIsolations: [(label: String, mode: AutomationSettings.SessionIsolationMode)] = [
        ("No Isolation", .none),
        ("Cookie Isolation", .cookies),
        ("Storage Isolation", .storage),
        ("Full Isolation", .full),
    ]

    func generateSessions(count: Int, mode: TestDebugVariationMode, site: TestDebugSite, overrides: TestDebugVariationOverrides = TestDebugVariationOverrides()) -> [TestDebugSession] {
        let raw: [TestDebugSession]
        switch mode {
        case .all:
            raw = generateAllVariations(count: count, site: site, overrides: overrides)
        case .network:
            raw = generateNetworkVariations(count: count, site: site, overrides: overrides)
        case .automation:
            raw = generateAutomationVariations(count: count, site: site, overrides: overrides)
        case .smartMatrix:
            raw = generateSmartMatrix(count: count, site: site, overrides: overrides)
        }
        return deduplicateSessions(raw)
    }

    private func deduplicateSessions(_ sessions: [TestDebugSession]) -> [TestDebugSession] {
        var seen = Set<String>()
        var result: [TestDebugSession] = []
        for session in sessions {
            let key = snapshotFingerprint(session.settingsSnapshot)
            if seen.contains(key) {
                let tweaked = tweakSnapshot(session.settingsSnapshot)
                let newKey = snapshotFingerprint(tweaked)
                if !seen.contains(newKey) {
                    seen.insert(newKey)
                    let newSession = TestDebugSession(
                        index: session.index,
                        differentiator: session.differentiator + " [tweaked]",
                        settingsSnapshot: tweaked
                    )
                    result.append(newSession)
                } else {
                    seen.insert(key + "_\(session.index)")
                    result.append(session)
                }
            } else {
                seen.insert(key)
                result.append(session)
            }
        }
        return result
    }

    private func snapshotFingerprint(_ s: TestDebugSettingsSnapshot) -> String {
        "\(s.connectionMode.rawValue)|\(s.wireGuardConfigIndex ?? -1)|\(s.pattern)|\(s.typingSpeedMinMs)-\(s.typingSpeedMaxMs)|\(s.stealthJSInjection)|\(s.humanMouseMovement)|\(s.fingerprintSpoofing)|\(s.trueDetectionEnabled)|\(s.tabBetweenFields)|\(s.pageLoadExtraDelayMs)|\(s.preSubmitDelayMs)|\(s.postSubmitDelayMs)|\(s.sessionIsolation.rawValue)"
    }

    private func tweakSnapshot(_ s: TestDebugSettingsSnapshot) -> TestDebugSettingsSnapshot {
        let newMin = s.typingSpeedMinMs + Int.random(in: 10...30)
        let newMax = s.typingSpeedMaxMs + Int.random(in: 10...30)
        let newPreSubmit = s.preSubmitDelayMs + Int.random(in: 50...200)
        return TestDebugSettingsSnapshot(
            connectionMode: s.connectionMode,
            wireGuardConfigIndex: s.wireGuardConfigIndex,
            pattern: s.pattern,
            typingSpeedMinMs: newMin,
            typingSpeedMaxMs: newMax,
            stealthJSInjection: s.stealthJSInjection,
            humanMouseMovement: s.humanMouseMovement,
            humanScrollJitter: s.humanScrollJitter,
            viewportRandomization: s.viewportRandomization,
            fingerprintSpoofing: s.fingerprintSpoofing,
            trueDetectionEnabled: s.trueDetectionEnabled,
            tabBetweenFields: s.tabBetweenFields,
            pageLoadExtraDelayMs: s.pageLoadExtraDelayMs,
            preSubmitDelayMs: newPreSubmit,
            postSubmitDelayMs: s.postSubmitDelayMs,
            clearCookiesBetweenAttempts: s.clearCookiesBetweenAttempts,
            sessionIsolation: s.sessionIsolation,
            webViewPoolIndex: s.webViewPoolIndex
        )
    }

    private func applyOverrides(_ snapshot: TestDebugSettingsSnapshot, overrides: TestDebugVariationOverrides) -> TestDebugSettingsSnapshot {
        guard overrides.hasPins else { return snapshot }
        return TestDebugSettingsSnapshot(
            connectionMode: overrides.pinConnectionMode ?? snapshot.connectionMode,
            wireGuardConfigIndex: snapshot.wireGuardConfigIndex,
            pattern: overrides.pinPattern ?? snapshot.pattern,
            typingSpeedMinMs: overrides.pinTypingSpeed?.min ?? snapshot.typingSpeedMinMs,
            typingSpeedMaxMs: overrides.pinTypingSpeed?.max ?? snapshot.typingSpeedMaxMs,
            stealthJSInjection: overrides.pinStealth ?? snapshot.stealthJSInjection,
            humanMouseMovement: overrides.pinHumanSim ?? snapshot.humanMouseMovement,
            humanScrollJitter: overrides.pinHumanSim ?? snapshot.humanScrollJitter,
            viewportRandomization: snapshot.viewportRandomization,
            fingerprintSpoofing: overrides.pinFingerprint ?? snapshot.fingerprintSpoofing,
            trueDetectionEnabled: overrides.pinTrueDetection ?? snapshot.trueDetectionEnabled,
            tabBetweenFields: (overrides.pinPattern ?? snapshot.pattern) == "Tab Navigation",
            pageLoadExtraDelayMs: snapshot.pageLoadExtraDelayMs,
            preSubmitDelayMs: snapshot.preSubmitDelayMs,
            postSubmitDelayMs: snapshot.postSubmitDelayMs,
            clearCookiesBetweenAttempts: snapshot.clearCookiesBetweenAttempts,
            sessionIsolation: overrides.pinSessionIsolation ?? snapshot.sessionIsolation,
            webViewPoolIndex: snapshot.webViewPoolIndex
        )
    }

    private func availableConnectionModes() -> [(label: String, mode: ConnectionMode, wgIndex: Int?)] {
        var modes: [(label: String, mode: ConnectionMode, wgIndex: Int?)] = []

        let wgConfigs = proxyService.joeWGConfigs
        for i in 0..<min(wgConfigs.count, 24) {
            let wg = wgConfigs[i]
            modes.append(("WG #\(i + 1) \(wg.displayString)", .wireguard, i))
        }

        modes.append(("NodeMaven Residential", .nodeMaven, nil))
        modes.append(("NodeMaven Mobile", .nodeMaven, nil))
        modes.append(("DNS-over-HTTPS", .dns, nil))

        if !proxyService.savedProxies.isEmpty {
            modes.append(("SOCKS5 Proxy", .proxy, nil))
        }

        return modes
    }

    private func generateAllVariations(count: Int, site: TestDebugSite, overrides: TestDebugVariationOverrides = TestDebugVariationOverrides()) -> [TestDebugSession] {
        var sessions: [TestDebugSession] = []
        let netModes = availableConnectionModes()
        let poolSize = 24

        for i in 0..<count {
            let net = netModes[i % netModes.count]
            let pattern = patterns[i % patterns.count]
            let speed = typingSpeeds[i % typingSpeeds.count]
            let preSubmit = preSubmitDelays[(i / 2) % preSubmitDelays.count]
            let postSubmit = postSubmitDelays[(i / 3) % postSubmitDelays.count]
            let pageDelay = pageLoadDelays[(i / 4) % pageLoadDelays.count]
            let isolation = sessionIsolations[(i / 6) % sessionIsolations.count]
            let useTrueDetection = pattern == "TRUE DETECTION"
            let humanSim = (i % 3) != 2
            let stealth = (i % 4) != 3
            let viewport = (i % 5) != 4
            let fingerprint = (i % 3) != 0

            var parts: [String] = []
            parts.append(net.label)
            parts.append(pattern)
            parts.append(speed.label)
            if humanSim { parts.append("HumanSim") }
            if stealth { parts.append("Stealth") }
            parts.append(isolation.label)

            let snapshot = TestDebugSettingsSnapshot(
                connectionMode: net.mode,
                wireGuardConfigIndex: net.wgIndex,
                pattern: pattern,
                typingSpeedMinMs: speed.min,
                typingSpeedMaxMs: speed.max,
                stealthJSInjection: stealth,
                humanMouseMovement: humanSim,
                humanScrollJitter: humanSim,
                viewportRandomization: viewport,
                fingerprintSpoofing: fingerprint,
                trueDetectionEnabled: useTrueDetection,
                tabBetweenFields: pattern == "Tab Navigation",
                pageLoadExtraDelayMs: pageDelay.ms,
                preSubmitDelayMs: preSubmit.ms,
                postSubmitDelayMs: postSubmit.ms,
                clearCookiesBetweenAttempts: isolation.mode != .none,
                sessionIsolation: isolation.mode,
                webViewPoolIndex: i % poolSize
            )

            let finalSnapshot = applyOverrides(snapshot, overrides: overrides)
            let finalParts = buildDifferentiatorParts(finalSnapshot, overrides: overrides, baseParts: parts)
            sessions.append(TestDebugSession(index: i + 1, differentiator: finalParts.joined(separator: " + "), settingsSnapshot: finalSnapshot))
        }

        return sessions
    }

    private func generateNetworkVariations(count: Int, site: TestDebugSite, overrides: TestDebugVariationOverrides = TestDebugVariationOverrides()) -> [TestDebugSession] {
        var sessions: [TestDebugSession] = []
        let netModes = availableConnectionModes()
        let poolSize = 24

        let basePattern = "TRUE DETECTION"

        for i in 0..<count {
            let net = netModes[i % netModes.count]
            let isolation = sessionIsolations[(i / netModes.count) % sessionIsolations.count]

            let parts: [String] = [net.label, isolation.label]

            let snapshot = TestDebugSettingsSnapshot(
                connectionMode: net.mode,
                wireGuardConfigIndex: net.wgIndex,
                pattern: basePattern,
                typingSpeedMinMs: 80,
                typingSpeedMaxMs: 150,
                stealthJSInjection: true,
                humanMouseMovement: true,
                humanScrollJitter: true,
                viewportRandomization: false,
                fingerprintSpoofing: true,
                trueDetectionEnabled: true,
                tabBetweenFields: false,
                pageLoadExtraDelayMs: 2000,
                preSubmitDelayMs: 350,
                postSubmitDelayMs: 600,
                clearCookiesBetweenAttempts: true,
                sessionIsolation: isolation.mode,
                webViewPoolIndex: i % poolSize
            )

            let finalSnapshot = applyOverrides(snapshot, overrides: overrides)
            let finalParts = buildDifferentiatorParts(finalSnapshot, overrides: overrides, baseParts: parts)
            sessions.append(TestDebugSession(index: i + 1, differentiator: finalParts.joined(separator: " + "), settingsSnapshot: finalSnapshot))
        }

        return sessions
    }

    private func generateAutomationVariations(count: Int, site: TestDebugSite, overrides: TestDebugVariationOverrides = TestDebugVariationOverrides()) -> [TestDebugSession] {
        var sessions: [TestDebugSession] = []
        let poolSize = 24
        let defaultMode = proxyService.unifiedConnectionMode
        let wgIndex: Int? = defaultMode == .wireguard ? 0 : nil

        for i in 0..<count {
            let pattern = patterns[i % patterns.count]
            let speed = typingSpeeds[(i / patterns.count) % typingSpeeds.count]
            let preSubmit = preSubmitDelays[(i / (patterns.count * 2)) % preSubmitDelays.count]
            let postSubmit = postSubmitDelays[(i / (patterns.count * 3)) % postSubmitDelays.count]
            let useTrueDetection = pattern == "TRUE DETECTION"
            let humanSim = (i % 3) != 2
            let stealth = (i % 4) != 3
            let fingerprint = (i % 3) != 0

            var parts: [String] = [pattern, speed.label]
            if humanSim { parts.append("HumanSim") }
            if stealth { parts.append("Stealth") }
            if fingerprint { parts.append("FP Spoof") }
            parts.append(preSubmit.label)

            let snapshot = TestDebugSettingsSnapshot(
                connectionMode: defaultMode,
                wireGuardConfigIndex: wgIndex,
                pattern: pattern,
                typingSpeedMinMs: speed.min,
                typingSpeedMaxMs: speed.max,
                stealthJSInjection: stealth,
                humanMouseMovement: humanSim,
                humanScrollJitter: humanSim,
                viewportRandomization: false,
                fingerprintSpoofing: fingerprint,
                trueDetectionEnabled: useTrueDetection,
                tabBetweenFields: pattern == "Tab Navigation",
                pageLoadExtraDelayMs: 2000,
                preSubmitDelayMs: preSubmit.ms,
                postSubmitDelayMs: postSubmit.ms,
                clearCookiesBetweenAttempts: true,
                sessionIsolation: .full,
                webViewPoolIndex: i % poolSize
            )

            let finalSnapshot = applyOverrides(snapshot, overrides: overrides)
            let finalParts = buildDifferentiatorParts(finalSnapshot, overrides: overrides, baseParts: parts)
            sessions.append(TestDebugSession(index: i + 1, differentiator: finalParts.joined(separator: " + "), settingsSnapshot: finalSnapshot))
        }

        return sessions
    }

    private func generateSmartMatrix(count: Int, site: TestDebugSite, overrides: TestDebugVariationOverrides = TestDebugVariationOverrides()) -> [TestDebugSession] {
        var sessions: [TestDebugSession] = []
        let poolSize = 24
        let defaultMode = proxyService.unifiedConnectionMode
        let wgIndex: Int? = defaultMode == .wireguard ? 0 : nil
        var idx = 0

        let baseSnapshot = TestDebugSettingsSnapshot(
            connectionMode: defaultMode,
            wireGuardConfigIndex: wgIndex,
            pattern: "TRUE DETECTION",
            typingSpeedMinMs: 80,
            typingSpeedMaxMs: 150,
            stealthJSInjection: true,
            humanMouseMovement: true,
            humanScrollJitter: true,
            viewportRandomization: false,
            fingerprintSpoofing: true,
            trueDetectionEnabled: true,
            tabBetweenFields: false,
            pageLoadExtraDelayMs: 2000,
            preSubmitDelayMs: 350,
            postSubmitDelayMs: 600,
            clearCookiesBetweenAttempts: true,
            sessionIsolation: .full,
            webViewPoolIndex: 0
        )

        func addSession(differentiator: String, snapshot: TestDebugSettingsSnapshot) {
            guard idx < count else { return }
            let s = snapshot
            let session = TestDebugSession(index: idx + 1, differentiator: "CONTROL: " + differentiator, settingsSnapshot: TestDebugSettingsSnapshot(
                connectionMode: s.connectionMode,
                wireGuardConfigIndex: s.wireGuardConfigIndex,
                pattern: s.pattern,
                typingSpeedMinMs: s.typingSpeedMinMs,
                typingSpeedMaxMs: s.typingSpeedMaxMs,
                stealthJSInjection: s.stealthJSInjection,
                humanMouseMovement: s.humanMouseMovement,
                humanScrollJitter: s.humanScrollJitter,
                viewportRandomization: s.viewportRandomization,
                fingerprintSpoofing: s.fingerprintSpoofing,
                trueDetectionEnabled: s.trueDetectionEnabled,
                tabBetweenFields: s.tabBetweenFields,
                pageLoadExtraDelayMs: s.pageLoadExtraDelayMs,
                preSubmitDelayMs: s.preSubmitDelayMs,
                postSubmitDelayMs: s.postSubmitDelayMs,
                clearCookiesBetweenAttempts: s.clearCookiesBetweenAttempts,
                sessionIsolation: s.sessionIsolation,
                webViewPoolIndex: idx % poolSize
            ))
            sessions.append(session)
            idx += 1
        }

        addSession(differentiator: "Baseline (TRUE DETECTION + defaults)", snapshot: baseSnapshot)

        for pattern in patterns where pattern != "TRUE DETECTION" && idx < count {
            let snap = TestDebugSettingsSnapshot(
                connectionMode: baseSnapshot.connectionMode,
                wireGuardConfigIndex: baseSnapshot.wireGuardConfigIndex,
                pattern: pattern,
                typingSpeedMinMs: baseSnapshot.typingSpeedMinMs,
                typingSpeedMaxMs: baseSnapshot.typingSpeedMaxMs,
                stealthJSInjection: baseSnapshot.stealthJSInjection,
                humanMouseMovement: baseSnapshot.humanMouseMovement,
                humanScrollJitter: baseSnapshot.humanScrollJitter,
                viewportRandomization: baseSnapshot.viewportRandomization,
                fingerprintSpoofing: baseSnapshot.fingerprintSpoofing,
                trueDetectionEnabled: false,
                tabBetweenFields: pattern == "Tab Navigation",
                pageLoadExtraDelayMs: baseSnapshot.pageLoadExtraDelayMs,
                preSubmitDelayMs: baseSnapshot.preSubmitDelayMs,
                postSubmitDelayMs: baseSnapshot.postSubmitDelayMs,
                clearCookiesBetweenAttempts: baseSnapshot.clearCookiesBetweenAttempts,
                sessionIsolation: baseSnapshot.sessionIsolation,
                webViewPoolIndex: idx % poolSize
            )
            addSession(differentiator: "Pattern: \(pattern)", snapshot: snap)
        }

        for speed in typingSpeeds where idx < count {
            let snap = TestDebugSettingsSnapshot(
                connectionMode: baseSnapshot.connectionMode,
                wireGuardConfigIndex: baseSnapshot.wireGuardConfigIndex,
                pattern: baseSnapshot.pattern,
                typingSpeedMinMs: speed.min,
                typingSpeedMaxMs: speed.max,
                stealthJSInjection: baseSnapshot.stealthJSInjection,
                humanMouseMovement: baseSnapshot.humanMouseMovement,
                humanScrollJitter: baseSnapshot.humanScrollJitter,
                viewportRandomization: baseSnapshot.viewportRandomization,
                fingerprintSpoofing: baseSnapshot.fingerprintSpoofing,
                trueDetectionEnabled: baseSnapshot.trueDetectionEnabled,
                tabBetweenFields: baseSnapshot.tabBetweenFields,
                pageLoadExtraDelayMs: baseSnapshot.pageLoadExtraDelayMs,
                preSubmitDelayMs: baseSnapshot.preSubmitDelayMs,
                postSubmitDelayMs: baseSnapshot.postSubmitDelayMs,
                clearCookiesBetweenAttempts: baseSnapshot.clearCookiesBetweenAttempts,
                sessionIsolation: baseSnapshot.sessionIsolation,
                webViewPoolIndex: idx % poolSize
            )
            addSession(differentiator: "Typing: \(speed.label)", snapshot: snap)
        }

        for stealth in [true, false] where idx < count {
            let snap = TestDebugSettingsSnapshot(
                connectionMode: baseSnapshot.connectionMode,
                wireGuardConfigIndex: baseSnapshot.wireGuardConfigIndex,
                pattern: baseSnapshot.pattern,
                typingSpeedMinMs: baseSnapshot.typingSpeedMinMs,
                typingSpeedMaxMs: baseSnapshot.typingSpeedMaxMs,
                stealthJSInjection: stealth,
                humanMouseMovement: baseSnapshot.humanMouseMovement,
                humanScrollJitter: baseSnapshot.humanScrollJitter,
                viewportRandomization: baseSnapshot.viewportRandomization,
                fingerprintSpoofing: stealth,
                trueDetectionEnabled: baseSnapshot.trueDetectionEnabled,
                tabBetweenFields: baseSnapshot.tabBetweenFields,
                pageLoadExtraDelayMs: baseSnapshot.pageLoadExtraDelayMs,
                preSubmitDelayMs: baseSnapshot.preSubmitDelayMs,
                postSubmitDelayMs: baseSnapshot.postSubmitDelayMs,
                clearCookiesBetweenAttempts: baseSnapshot.clearCookiesBetweenAttempts,
                sessionIsolation: baseSnapshot.sessionIsolation,
                webViewPoolIndex: idx % poolSize
            )
            addSession(differentiator: "Stealth: \(stealth ? "ON" : "OFF")", snapshot: snap)
        }

        for human in [true, false] where idx < count {
            let snap = TestDebugSettingsSnapshot(
                connectionMode: baseSnapshot.connectionMode,
                wireGuardConfigIndex: baseSnapshot.wireGuardConfigIndex,
                pattern: baseSnapshot.pattern,
                typingSpeedMinMs: baseSnapshot.typingSpeedMinMs,
                typingSpeedMaxMs: baseSnapshot.typingSpeedMaxMs,
                stealthJSInjection: baseSnapshot.stealthJSInjection,
                humanMouseMovement: human,
                humanScrollJitter: human,
                viewportRandomization: baseSnapshot.viewportRandomization,
                fingerprintSpoofing: baseSnapshot.fingerprintSpoofing,
                trueDetectionEnabled: baseSnapshot.trueDetectionEnabled,
                tabBetweenFields: baseSnapshot.tabBetweenFields,
                pageLoadExtraDelayMs: baseSnapshot.pageLoadExtraDelayMs,
                preSubmitDelayMs: baseSnapshot.preSubmitDelayMs,
                postSubmitDelayMs: baseSnapshot.postSubmitDelayMs,
                clearCookiesBetweenAttempts: baseSnapshot.clearCookiesBetweenAttempts,
                sessionIsolation: baseSnapshot.sessionIsolation,
                webViewPoolIndex: idx % poolSize
            )
            addSession(differentiator: "HumanSim: \(human ? "ON" : "OFF")", snapshot: snap)
        }

        let netModes = availableConnectionModes()
        for net in netModes where idx < count {
            let snap = TestDebugSettingsSnapshot(
                connectionMode: net.mode,
                wireGuardConfigIndex: net.wgIndex,
                pattern: baseSnapshot.pattern,
                typingSpeedMinMs: baseSnapshot.typingSpeedMinMs,
                typingSpeedMaxMs: baseSnapshot.typingSpeedMaxMs,
                stealthJSInjection: baseSnapshot.stealthJSInjection,
                humanMouseMovement: baseSnapshot.humanMouseMovement,
                humanScrollJitter: baseSnapshot.humanScrollJitter,
                viewportRandomization: baseSnapshot.viewportRandomization,
                fingerprintSpoofing: baseSnapshot.fingerprintSpoofing,
                trueDetectionEnabled: baseSnapshot.trueDetectionEnabled,
                tabBetweenFields: baseSnapshot.tabBetweenFields,
                pageLoadExtraDelayMs: baseSnapshot.pageLoadExtraDelayMs,
                preSubmitDelayMs: baseSnapshot.preSubmitDelayMs,
                postSubmitDelayMs: baseSnapshot.postSubmitDelayMs,
                clearCookiesBetweenAttempts: baseSnapshot.clearCookiesBetweenAttempts,
                sessionIsolation: baseSnapshot.sessionIsolation,
                webViewPoolIndex: idx % poolSize
            )
            addSession(differentiator: "Network: \(net.label)", snapshot: snap)
        }

        while idx < count {
            let allVars = generateAllVariations(count: count - idx, site: site)
            for s in allVars {
                guard idx < count else { break }
                let remapped = TestDebugSession(index: idx + 1, differentiator: s.differentiator, settingsSnapshot: s.settingsSnapshot)
                sessions.append(remapped)
                idx += 1
            }
        }

        return sessions
    }

    private func buildDifferentiatorParts(_ snapshot: TestDebugSettingsSnapshot, overrides: TestDebugVariationOverrides, baseParts: [String]) -> [String] {
        guard overrides.hasPins else { return baseParts }
        var parts = baseParts
        if let pinNet = overrides.pinConnectionMode {
            parts = parts.filter { !$0.contains("WG #") && !$0.contains("NodeMaven") && !$0.contains("DNS") && !$0.contains("SOCKS5") }
            parts.insert("[PIN: \(pinNet.rawValue)]", at: 0)
        }
        if let pinPat = overrides.pinPattern {
            parts = parts.filter { !patterns.contains($0) }
            parts.append("[PIN: \(pinPat)]")
        }
        if overrides.pinTrueDetection != nil {
            parts.append("[PIN: TD=\(snapshot.trueDetectionEnabled ? "ON" : "OFF")]")
        }
        return parts
    }
}
