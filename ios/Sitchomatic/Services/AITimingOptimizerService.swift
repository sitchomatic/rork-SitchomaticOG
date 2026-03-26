import Foundation

nonisolated enum TimingCategory: String, Codable, Sendable, CaseIterable {
    case keystrokeDelay = "keystroke"
    case interFieldPause = "interField"
    case preSubmitWait = "preSubmit"
    case postDOMPause = "postDOM"
    case thinkPause = "thinkPause"
    case preFocusPause = "preFocus"
}

nonisolated struct TimingBounds: Codable, Sendable {
    var minMs: Int
    var maxMs: Int

    var mean: Double { Double(minMs + maxMs) / 2.0 }
    var range: Int { maxMs - minMs }
}

nonisolated struct TimingSample: Codable, Sendable {
    let category: TimingCategory
    let actualMs: Int
    let fillSuccess: Bool
    let submitSuccess: Bool
    let detected: Bool
    let timestamp: Date
    let pattern: String
}

nonisolated struct TimingProfile: Codable, Sendable {
    var keystroke: TimingBounds = TimingBounds(minMs: 45, maxMs: 160)
    var interField: TimingBounds = TimingBounds(minMs: 200, maxMs: 600)
    var preSubmit: TimingBounds = TimingBounds(minMs: 300, maxMs: 700)
    var postDOM: TimingBounds = TimingBounds(minMs: 2000, maxMs: 4000)
    var thinkPause: TimingBounds = TimingBounds(minMs: 200, maxMs: 600)
    var preFocus: TimingBounds = TimingBounds(minMs: 150, maxMs: 400)
    var totalSamples: Int = 0
    var successfulSamples: Int = 0
    var detectedSamples: Int = 0
    var lastAIRecalibration: Date = .distantPast
    var lastUpdated: Date = .distantPast

    var fillRate: Double { totalSamples > 0 ? Double(successfulSamples) / Double(totalSamples) : 0 }
    var detectionRate: Double { totalSamples > 0 ? Double(detectedSamples) / Double(totalSamples) : 0 }

    func bounds(for category: TimingCategory) -> TimingBounds {
        switch category {
        case .keystrokeDelay: return keystroke
        case .interFieldPause: return interField
        case .preSubmitWait: return preSubmit
        case .postDOMPause: return postDOM
        case .thinkPause: return thinkPause
        case .preFocusPause: return preFocus
        }
    }

    mutating func setBounds(_ bounds: TimingBounds, for category: TimingCategory) {
        switch category {
        case .keystrokeDelay: keystroke = bounds
        case .interFieldPause: interField = bounds
        case .preSubmitWait: preSubmit = bounds
        case .postDOMPause: postDOM = bounds
        case .thinkPause: thinkPause = bounds
        case .preFocusPause: preFocus = bounds
        }
    }
}

nonisolated struct TimingStore: Codable, Sendable {
    var profiles: [String: TimingProfile] = [:]
    var recentSamples: [String: [TimingSample]] = [:]
}

@MainActor
class AITimingOptimizerService {
    static let shared = AITimingOptimizerService()

    private let logger = DebugLogger.shared
    private let persistenceKey = "AITimingOptimizerData"
    private let maxSamplesPerHost = 500
    private let aiRecalibrationThreshold = 50
    private var store: TimingStore

    private let knowledgeGraph = AIKnowledgeGraphService.shared

    private init() {
        if let saved = UserDefaults.standard.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode(TimingStore.self, from: saved) {
            self.store = decoded
        } else {
            self.store = TimingStore()
        }
    }

    func optimizedDelay(for host: String, category: TimingCategory, pattern: String) -> Int {
        let profile = store.profiles[host] ?? TimingProfile()
        let bounds = profile.bounds(for: category)

        let mean = bounds.mean
        let stdDev = Double(bounds.range) / 4.0
        let u1 = Double.random(in: 0.0001...0.9999)
        let u2 = Double.random(in: 0.0001...0.9999)
        let z = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
        let delay = mean + z * stdDev
        let clamped = max(Double(bounds.minMs), min(Double(bounds.maxMs), delay))
        let result = Int(clamped)

        if profile.totalSamples > 5 {
            logger.log(
                "AITiming: \(host) — \(category.rawValue) \(result)ms (learned from \(profile.totalSamples) samples, \(Int(profile.fillRate * 100))% fill rate)",
                category: .timing, level: .trace
            )
        }

        return result
    }

    func recordSample(
        host: String,
        category: TimingCategory,
        actualMs: Int,
        fillSuccess: Bool,
        submitSuccess: Bool,
        detected: Bool,
        pattern: String
    ) {
        let sample = TimingSample(
            category: category,
            actualMs: actualMs,
            fillSuccess: fillSuccess,
            submitSuccess: submitSuccess,
            detected: detected,
            timestamp: Date(),
            pattern: pattern
        )

        var samples = store.recentSamples[host] ?? []
        samples.append(sample)
        if samples.count > maxSamplesPerHost {
            samples.removeFirst(samples.count - maxSamplesPerHost)
        }
        store.recentSamples[host] = samples

        var profile = store.profiles[host] ?? TimingProfile()
        profile.totalSamples += 1
        if fillSuccess { profile.successfulSamples += 1 }
        if detected { profile.detectedSamples += 1 }
        profile.lastUpdated = Date()

        updateBounds(profile: &profile, category: category, actualMs: actualMs, success: fillSuccess && submitSuccess, detected: detected)

        store.profiles[host] = profile
        save()

        publishTimingToKnowledgeGraph(host: host, category: category, actualMs: actualMs, fillSuccess: fillSuccess, submitSuccess: submitSuccess, detected: detected, profile: profile)

        let newAttemptsSinceAI = profile.totalSamples - Int(profile.lastAIRecalibration.timeIntervalSince1970 == Date.distantPast.timeIntervalSince1970 ? 0 : Double(profile.totalSamples) * 0.8)
        if profile.totalSamples >= aiRecalibrationThreshold &&
            profile.totalSamples % aiRecalibrationThreshold == 0 {
            Task {
                await requestAIRecalibration(host: host)
            }
        }
    }

    func recordPatternTimingOutcome(
        url: String,
        pattern: LoginFormPattern,
        keystrokeDelayMs: Int,
        interFieldPauseMs: Int,
        preSubmitWaitMs: Int,
        fillSuccess: Bool,
        submitSuccess: Bool,
        detected: Bool
    ) {
        let host = extractHost(from: url)

        recordSample(host: host, category: .keystrokeDelay, actualMs: keystrokeDelayMs, fillSuccess: fillSuccess, submitSuccess: submitSuccess, detected: detected, pattern: pattern.rawValue)
        recordSample(host: host, category: .interFieldPause, actualMs: interFieldPauseMs, fillSuccess: fillSuccess, submitSuccess: submitSuccess, detected: detected, pattern: pattern.rawValue)
        recordSample(host: host, category: .preSubmitWait, actualMs: preSubmitWaitMs, fillSuccess: fillSuccess, submitSuccess: submitSuccess, detected: detected, pattern: pattern.rawValue)
    }

    func profileForHost(_ host: String) -> TimingProfile {
        store.profiles[host] ?? TimingProfile()
    }

    func allProfiles() -> [String: TimingProfile] {
        store.profiles
    }

    func resetHost(_ host: String) {
        store.profiles.removeValue(forKey: host)
        store.recentSamples.removeValue(forKey: host)
        save()
        logger.log("AITiming: reset all timing data for \(host)", category: .timing, level: .warning)
    }

    func resetAll() {
        store = TimingStore()
        save()
        logger.log("AITiming: all timing data RESET", category: .timing, level: .warning)
    }

    private func updateBounds(profile: inout TimingProfile, category: TimingCategory, actualMs: Int, success: Bool, detected: Bool) {
        var bounds = profile.bounds(for: category)
        let learningRate = 0.08

        if detected {
            let slowDown = Int(Double(bounds.range) * 0.15)
            bounds.minMs = min(bounds.minMs + slowDown, bounds.maxMs - 20)
            bounds.maxMs = min(bounds.maxMs + slowDown, absoluteMax(for: category))
            logger.log("AITiming: DETECTED on \(category.rawValue) at \(actualMs)ms → slowing to \(bounds.minMs)-\(bounds.maxMs)ms", category: .timing, level: .warning)
        } else if success {
            let currentMean = bounds.mean
            let drift = Double(actualMs) - currentMean
            let adjustedMean = currentMean + drift * learningRate

            let halfRange = Double(bounds.range) / 2.0
            bounds.minMs = max(absoluteMin(for: category), Int(adjustedMean - halfRange))
            bounds.maxMs = min(absoluteMax(for: category), Int(adjustedMean + halfRange))

            if bounds.range > 30 {
                bounds.minMs += 1
                bounds.maxMs -= 1
            }
        } else {
            let widen = max(5, Int(Double(bounds.range) * 0.05))
            bounds.minMs = max(absoluteMin(for: category), bounds.minMs - widen)
            bounds.maxMs = min(absoluteMax(for: category), bounds.maxMs + widen)
        }

        if bounds.maxMs <= bounds.minMs {
            bounds.maxMs = bounds.minMs + 20
        }

        profile.setBounds(bounds, for: category)
    }

    private func absoluteMin(for category: TimingCategory) -> Int {
        switch category {
        case .keystrokeDelay: return 15
        case .interFieldPause: return 80
        case .preSubmitWait: return 100
        case .postDOMPause: return 500
        case .thinkPause: return 50
        case .preFocusPause: return 50
        }
    }

    private func absoluteMax(for category: TimingCategory) -> Int {
        switch category {
        case .keystrokeDelay: return 500
        case .interFieldPause: return 2000
        case .preSubmitWait: return 3000
        case .postDOMPause: return 8000
        case .thinkPause: return 2000
        case .preFocusPause: return 1500
        }
    }

    private func requestAIRecalibration(host: String) async {
        guard let samples = store.recentSamples[host], samples.count >= 20 else { return }

        var summaryByCategory: [String: [String: Any]] = [:]
        for category in TimingCategory.allCases {
            let catSamples = samples.filter { $0.category == category }
            guard !catSamples.isEmpty else { continue }

            let successSamples = catSamples.filter { $0.fillSuccess && $0.submitSuccess }
            let failSamples = catSamples.filter { !$0.fillSuccess || !$0.submitSuccess }
            let detectedSamples = catSamples.filter { $0.detected }

            let avgSuccess = successSamples.isEmpty ? 0 : successSamples.map(\.actualMs).reduce(0, +) / successSamples.count
            let avgFail = failSamples.isEmpty ? 0 : failSamples.map(\.actualMs).reduce(0, +) / failSamples.count
            let avgDetected = detectedSamples.isEmpty ? 0 : detectedSamples.map(\.actualMs).reduce(0, +) / detectedSamples.count

            let profile = store.profiles[host] ?? TimingProfile()
            let currentBounds = profile.bounds(for: category)

            summaryByCategory[category.rawValue] = [
                "currentMin": currentBounds.minMs,
                "currentMax": currentBounds.maxMs,
                "totalSamples": catSamples.count,
                "successCount": successSamples.count,
                "failCount": failSamples.count,
                "detectedCount": detectedSamples.count,
                "avgSuccessMs": avgSuccess,
                "avgFailMs": avgFail,
                "avgDetectedMs": avgDetected,
            ]
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: summaryByCategory),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

        let systemPrompt = """
        You optimize timing delays for web automation to avoid anti-bot detection. \
        Analyze the timing data and return ONLY a JSON object with recommended min/max millisecond bounds \
        for each category. Format: {"keystroke":{"min":N,"max":N},"interField":{"min":N,"max":N},"preSubmit":{"min":N,"max":N},"postDOM":{"min":N,"max":N},"thinkPause":{"min":N,"max":N},"preFocus":{"min":N,"max":N}}. \
        If detection rate is high for a category, increase delays. If success rate is high and no detections, \
        you can tighten the range. Stay within human-realistic bounds. Return ONLY the JSON.
        """

        let userPrompt = "Host: \(host)\nTiming data:\n\(jsonStr)"

        logger.log("AITiming: requesting AI recalibration for \(host) (\(samples.count) samples)", category: .timing, level: .info)

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: userPrompt) else {
            logger.log("AITiming: AI recalibration failed for \(host) — no response", category: .timing, level: .warning)
            return
        }

        applyAIRecalibration(host: host, response: response)
    }

    private func applyAIRecalibration(host: String, response: String) {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Int]] else {
            logger.log("AITiming: failed to parse AI recalibration response for \(host)", category: .timing, level: .warning)
            return
        }

        var profile = store.profiles[host] ?? TimingProfile()
        var applied = 0

        for category in TimingCategory.allCases {
            guard let rec = json[category.rawValue],
                  let newMin = rec["min"],
                  let newMax = rec["max"],
                  newMin > 0, newMax > newMin,
                  newMin >= absoluteMin(for: category),
                  newMax <= absoluteMax(for: category) else { continue }

            let currentBounds = profile.bounds(for: category)

            let blendedMin = (currentBounds.minMs + newMin) / 2
            let blendedMax = (currentBounds.maxMs + newMax) / 2

            profile.setBounds(TimingBounds(minMs: blendedMin, maxMs: blendedMax), for: category)
            applied += 1

            logger.log(
                "AITiming: AI recal \(host) \(category.rawValue): \(currentBounds.minMs)-\(currentBounds.maxMs) → \(blendedMin)-\(blendedMax)ms",
                category: .timing, level: .info
            )
        }

        profile.lastAIRecalibration = Date()
        store.profiles[host] = profile
        save()

        logger.log("AITiming: AI recalibration applied \(applied)/\(TimingCategory.allCases.count) categories for \(host)", category: .timing, level: .success)
    }

    private func publishTimingToKnowledgeGraph(host: String, category: TimingCategory, actualMs: Int, fillSuccess: Bool, submitSuccess: Bool, detected: Bool, profile: TimingProfile) {
        let severity: KnowledgeSeverity = detected ? .high : (fillSuccess && submitSuccess ? .low : .medium)

        let payload: [String: String] = [
            "category": category.rawValue,
            "actualMs": "\(actualMs)",
            "fillSuccess": "\(fillSuccess)",
            "submitSuccess": "\(submitSuccess)",
            "detected": "\(detected)",
            "fillRate": String(format: "%.0f", profile.fillRate * 100),
            "detectionRate": String(format: "%.0f", profile.detectionRate * 100),
            "keystrokeMs": "\(profile.keystroke.minMs)-\(profile.keystroke.maxMs)",
            "interFieldMs": "\(profile.interField.minMs)-\(profile.interField.maxMs)",
            "preSubmitMs": "\(profile.preSubmit.minMs)-\(profile.preSubmit.maxMs)",
        ]

        let summary = detected
            ? "Timing detected on \(host) \(category.rawValue) at \(actualMs)ms"
            : "Timing \(fillSuccess ? "ok" : "fail") on \(host) \(category.rawValue) \(actualMs)ms"

        knowledgeGraph.publishEvent(
            source: "AITimingOptimizer",
            host: host,
            domain: .timing,
            type: detected ? .threatSignal : .performanceMetric,
            severity: severity,
            confidence: 0.80,
            payload: payload,
            summary: summary
        )
    }

    func getTransferLearningTimingHints(for host: String) -> TimingBounds? {
        let intel = knowledgeGraph.getHostIntelligence(host: host)
        guard intel.eventCount >= 5, intel.timingProfile.fillRate > 0 else { return nil }
        return TimingBounds(
            minMs: intel.timingProfile.optimalKeystrokeMs - 20,
            maxMs: intel.timingProfile.optimalKeystrokeMs + 40
        )
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: persistenceKey)
        }
    }

    private func extractHost(from url: String) -> String {
        if let u = URL(string: url) { return u.host ?? url }
        return url
    }
}
