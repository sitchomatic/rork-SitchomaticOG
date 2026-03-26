import Foundation
import UIKit

nonisolated struct GovernorSnapshot: Sendable {
    let timestamp: Date
    let memoryMB: Int
    let memoryGrowthRate: Double
    let webViewCount: Int
    let failureRate: Double
    let consecutiveFailures: Int
    let stabilityScore: Double
    let recommendedConcurrency: Int
    let reasoning: String
}

nonisolated struct GovernorAdjustment: Codable, Sendable {
    let id: String
    let timestamp: Date
    let fromConcurrency: Int
    let toConcurrency: Int
    let memoryMB: Int
    let memoryGrowthRate: Double
    let webViewCount: Int
    let stabilityScore: Double
    let reasoning: String
    let wasAI: Bool
}

nonisolated struct GovernorStore: Codable, Sendable {
    var adjustments: [GovernorAdjustment] = []
    var totalAdjustments: Int = 0
    var totalAIAnalyses: Int = 0
    var hostMemoryProfiles: [String: Double] = [:]
}

@MainActor
class AIPredictiveConcurrencyGovernor {
    static let shared = AIPredictiveConcurrencyGovernor()

    private let logger = DebugLogger.shared
    private let crashProtection = CrashProtectionService.shared
    private let persistKey = "AIPredictiveConcurrencyGovernor_v1"
    private var store: GovernorStore
    private var monitorTask: Task<Void, Never>?
    private var isActive: Bool = false

    private var recentSnapshots: [GovernorSnapshot] = []
    private let maxSnapshots = 60
    private let checkIntervalSeconds: TimeInterval = 10
    private let aiAnalysisCooldownSeconds: TimeInterval = 60
    private var lastAIAnalysisTime: Date = .distantPast
    private var lastAdjustmentTime: Date = .distantPast

    private(set) var currentRecommendedConcurrency: Int = 5
    private(set) var currentStabilityScore: Double = 1.0
    private(set) var lastSnapshot: GovernorSnapshot?

    private let memoryLowThreshold = 800
    private let memoryMedThreshold = 1400
    private let memoryHighThreshold = 2000
    private let memoryEmergencyThreshold = 3000

    private let rampUpCooldownSeconds: TimeInterval = 30
    private var lastRampUpTime: Date = .distantPast
    private var consecutiveStableChecks: Int = 0
    private let stableChecksForRampUp: Int = 3

    var onConcurrencyChanged: ((Int, String) -> Void)?

    init() {
        if let data = UserDefaults.standard.data(forKey: persistKey),
           let decoded = try? JSONDecoder().decode(GovernorStore.self, from: data) {
            self.store = decoded
        } else {
            self.store = GovernorStore()
        }
    }

    func start(initialConcurrency: Int = 5) {
        guard !isActive else { return }
        isActive = true
        currentRecommendedConcurrency = initialConcurrency
        consecutiveStableChecks = 0
        startMonitoring()
        logger.log("ConcurrencyGovernor: started (initial=\(initialConcurrency))", category: .system, level: .info)
    }

    func stop() {
        isActive = false
        monitorTask?.cancel()
        monitorTask = nil
        recentSnapshots.removeAll()
        consecutiveStableChecks = 0
        logger.log("ConcurrencyGovernor: stopped", category: .system, level: .info)
    }

    func recommendConcurrency(requestedMax: Int) -> Int {
        return min(requestedMax, currentRecommendedConcurrency)
    }

    func recordHostMemoryImpact(host: String, estimatedMB: Double) {
        let existing = store.hostMemoryProfiles[host] ?? 0
        store.hostMemoryProfiles[host] = existing > 0 ? (existing * 0.7 + estimatedMB * 0.3) : estimatedMB
        save()
    }

    func estimatedMemoryForHost(_ host: String) -> Double {
        store.hostMemoryProfiles[host] ?? 80
    }

    var adjustmentHistory: [GovernorAdjustment] { Array(store.adjustments.prefix(30)) }
    var totalAdjustments: Int { store.totalAdjustments }

    func resetAll() {
        store = GovernorStore()
        currentRecommendedConcurrency = 5
        currentStabilityScore = 1.0
        recentSnapshots.removeAll()
        consecutiveStableChecks = 0
        save()
        logger.log("ConcurrencyGovernor: RESET", category: .system, level: .warning)
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isActive else { return }
                let interval = self.computeCheckInterval()
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, self.isActive else { return }
                await self.performCheck()
            }
        }
    }

    private func computeCheckInterval() -> TimeInterval {
        let memMB = crashProtection.currentMemoryUsageMB()
        if memMB > memoryHighThreshold || crashProtection.isMemoryDeathSpiral { return 5 }
        if memMB > memoryMedThreshold { return 8 }
        return checkIntervalSeconds
    }

    private func performCheck() async {
        let memMB = crashProtection.currentMemoryUsageMB()
        let growthRate = crashProtection.currentGrowthRateMBPerSec
        let webViewCount = WebViewPool.shared.activeCount
        let loginRunning = LoginViewModel.shared.isRunning
        let ppsrRunning = PPSRAutomationViewModel.shared.isRunning

        guard loginRunning || ppsrRunning else {
            if currentRecommendedConcurrency < 5 {
                currentRecommendedConcurrency = 5
                currentStabilityScore = 1.0
                consecutiveStableChecks = 0
            }
            return
        }

        let failureRate = computeRecentFailureRate()
        let consecutiveFailures = computeConsecutiveFailures()
        let stabilityScore = computeStabilityScore(
            memoryMB: memMB,
            growthRate: growthRate,
            webViewCount: webViewCount,
            failureRate: failureRate,
            consecutiveFailures: consecutiveFailures
        )
        currentStabilityScore = stabilityScore

        let heuristicConcurrency = heuristicRecommendation(
            memoryMB: memMB,
            growthRate: growthRate,
            webViewCount: webViewCount,
            stabilityScore: stabilityScore,
            failureRate: failureRate
        )

        let snapshot = GovernorSnapshot(
            timestamp: Date(),
            memoryMB: memMB,
            memoryGrowthRate: growthRate,
            webViewCount: webViewCount,
            failureRate: failureRate,
            consecutiveFailures: consecutiveFailures,
            stabilityScore: stabilityScore,
            recommendedConcurrency: heuristicConcurrency,
            reasoning: ""
        )
        recentSnapshots.append(snapshot)
        if recentSnapshots.count > maxSnapshots {
            recentSnapshots.removeFirst(recentSnapshots.count - maxSnapshots)
        }
        lastSnapshot = snapshot

        var finalConcurrency = heuristicConcurrency
        var reasoning = heuristicReasoning(memoryMB: memMB, growthRate: growthRate, stabilityScore: stabilityScore, recommendation: heuristicConcurrency)
        var wasAI = false

        let shouldRequestAI = stabilityScore < 0.6
            && Date().timeIntervalSince(lastAIAnalysisTime) > aiAnalysisCooldownSeconds
            && recentSnapshots.count >= 5

        if shouldRequestAI {
            if let aiResult = await requestAIAnalysis(currentConcurrency: currentRecommendedConcurrency, heuristicSuggestion: heuristicConcurrency) {
                finalConcurrency = aiResult.concurrency
                reasoning = aiResult.reasoning
                wasAI = true
                lastAIAnalysisTime = Date()
                store.totalAIAnalyses += 1
            }
        }

        if stabilityScore > 0.75 {
            consecutiveStableChecks += 1
        } else {
            consecutiveStableChecks = 0
        }

        if finalConcurrency > currentRecommendedConcurrency {
            let canRampUp = consecutiveStableChecks >= stableChecksForRampUp
                && Date().timeIntervalSince(lastRampUpTime) > rampUpCooldownSeconds
            if canRampUp {
                finalConcurrency = min(finalConcurrency, currentRecommendedConcurrency + 1)
                lastRampUpTime = Date()
                consecutiveStableChecks = 0
            } else {
                finalConcurrency = currentRecommendedConcurrency
            }
        }

        finalConcurrency = max(1, min(10, finalConcurrency))

        if finalConcurrency != currentRecommendedConcurrency {
            let old = currentRecommendedConcurrency
            currentRecommendedConcurrency = finalConcurrency
            lastAdjustmentTime = Date()

            let adjustment = GovernorAdjustment(
                id: UUID().uuidString,
                timestamp: Date(),
                fromConcurrency: old,
                toConcurrency: finalConcurrency,
                memoryMB: memMB,
                memoryGrowthRate: growthRate,
                webViewCount: webViewCount,
                stabilityScore: stabilityScore,
                reasoning: reasoning,
                wasAI: wasAI
            )
            store.adjustments.insert(adjustment, at: 0)
            if store.adjustments.count > 200 {
                store.adjustments = Array(store.adjustments.prefix(200))
            }
            store.totalAdjustments += 1
            save()

            let level: DebugLogLevel = finalConcurrency < old ? .warning : .info
            logger.log("ConcurrencyGovernor: \(old) → \(finalConcurrency) (stability=\(String(format: "%.2f", stabilityScore)) mem=\(memMB)MB growth=\(String(format: "%.1f", growthRate))MB/s wv=\(webViewCount) ai=\(wasAI)) — \(reasoning)", category: .system, level: level)

            onConcurrencyChanged?(finalConcurrency, reasoning)
        }
    }

    private func computeStabilityScore(memoryMB: Int, growthRate: Double, webViewCount: Int, failureRate: Double, consecutiveFailures: Int) -> Double {
        var score = 1.0

        if memoryMB > memoryEmergencyThreshold {
            score -= 0.5
        } else if memoryMB > memoryHighThreshold {
            score -= 0.3
        } else if memoryMB > memoryMedThreshold {
            score -= 0.15
        } else if memoryMB > memoryLowThreshold {
            score -= 0.05
        }

        if growthRate > 30 {
            score -= 0.3
        } else if growthRate > 15 {
            score -= 0.15
        } else if growthRate > 5 {
            score -= 0.05
        } else if growthRate < -5 {
            score += 0.05
        }

        if webViewCount > 8 {
            score -= 0.2
        } else if webViewCount > 5 {
            score -= 0.1
        }

        score -= failureRate * 0.2
        score -= Double(min(consecutiveFailures, 5)) * 0.04

        if crashProtection.isMemoryDeathSpiral {
            score -= 0.4
        }
        if crashProtection.isPreemptiveThrottleActive {
            score -= 0.15
        }

        return max(0.0, min(1.0, score))
    }

    private func heuristicRecommendation(memoryMB: Int, growthRate: Double, webViewCount: Int, stabilityScore: Double, failureRate: Double) -> Int {
        if crashProtection.isMemoryDeathSpiral || memoryMB > memoryEmergencyThreshold {
            return 1
        }

        if memoryMB > memoryHighThreshold || (growthRate > 20 && memoryMB > memoryMedThreshold) {
            return 2
        }

        if stabilityScore < 0.3 {
            return 1
        }
        if stabilityScore < 0.5 {
            return 2
        }
        if stabilityScore < 0.65 {
            return 3
        }
        if stabilityScore < 0.8 {
            return 4
        }

        let predictedMB30s = Double(memoryMB) + growthRate * 30.0
        if predictedMB30s > Double(memoryHighThreshold) {
            return max(2, Int(stabilityScore * 5))
        }

        return 5
    }

    private func heuristicReasoning(memoryMB: Int, growthRate: Double, stabilityScore: Double, recommendation: Int) -> String {
        if crashProtection.isMemoryDeathSpiral {
            return "Death spiral detected — emergency minimum concurrency"
        }
        if memoryMB > memoryEmergencyThreshold {
            return "Emergency memory threshold exceeded (\(memoryMB)MB)"
        }
        if memoryMB > memoryHighThreshold {
            return "High memory pressure (\(memoryMB)MB)"
        }
        if growthRate > 20 && memoryMB > memoryMedThreshold {
            return "Rapid memory growth (\(String(format: "%.0f", growthRate))MB/s at \(memoryMB)MB)"
        }
        if stabilityScore < 0.5 {
            return "Low stability score (\(String(format: "%.2f", stabilityScore)))"
        }
        let predicted = Double(memoryMB) + growthRate * 30.0
        if predicted > Double(memoryHighThreshold) {
            return "Predicted memory in 30s: \(Int(predicted))MB — preemptive reduction"
        }
        return "Stability score \(String(format: "%.2f", stabilityScore)) — recommendation \(recommendation)"
    }

    private var outcomeWindow: [Bool] = []

    func feedOutcome(success: Bool) {
        outcomeWindow.append(success)
        if outcomeWindow.count > 50 {
            outcomeWindow.removeFirst(outcomeWindow.count - 50)
        }
    }

    func resetOutcomeWindow() {
        outcomeWindow.removeAll()
    }

    private func computeRecentFailureRate() -> Double {
        let recent = outcomeWindow.suffix(20)
        guard !recent.isEmpty else { return 0 }
        return Double(recent.filter { !$0 }.count) / Double(recent.count)
    }

    private func computeConsecutiveFailures() -> Int {
        var streak = 0
        for outcome in outcomeWindow.reversed() {
            if !outcome { streak += 1 } else { break }
        }
        return streak
    }

    private func requestAIAnalysis(currentConcurrency: Int, heuristicSuggestion: Int) async -> (concurrency: Int, reasoning: String)? {
        let recent = recentSnapshots.suffix(10)
        var snapshotData: [[String: Any]] = []
        for s in recent {
            snapshotData.append([
                "memoryMB": s.memoryMB,
                "growthRate": String(format: "%.1f", s.memoryGrowthRate),
                "webViews": s.webViewCount,
                "failureRate": String(format: "%.0f%%", s.failureRate * 100),
                "stability": String(format: "%.2f", s.stabilityScore),
            ])
        }

        let context: [String: Any] = [
            "currentConcurrency": currentConcurrency,
            "heuristicSuggestion": heuristicSuggestion,
            "deathSpiral": crashProtection.isMemoryDeathSpiral,
            "throttleActive": crashProtection.isPreemptiveThrottleActive,
            "recentSnapshots": snapshotData,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: context),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return nil }

        let systemPrompt = """
        You manage concurrency for web automation sessions to prevent app crashes. \
        Analyze memory trends, WebView counts, and failure rates. Return ONLY JSON: \
        {"concurrency":1-10,"reasoning":"..."}. \
        Priority: prevent crashes > maintain throughput. \
        If memory is growing fast, reduce aggressively. If stable and low failure rate, allow gradual increase. \
        Never recommend more than heuristicSuggestion + 1. Return ONLY JSON.
        """

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: "Session data:\n\(jsonStr)") else { return nil }

        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let concurrency = json["concurrency"] as? Int else { return nil }

        let reasoning = (json["reasoning"] as? String) ?? "AI analysis"
        return (max(1, min(10, concurrency)), reasoning)
    }

    var diagnosticSummary: String {
        let mem = crashProtection.currentMemoryUsageMB()
        let wv = WebViewPool.shared.activeCount
        return "Governor: conc=\(currentRecommendedConcurrency) stability=\(String(format: "%.2f", currentStabilityScore)) mem=\(mem)MB wv=\(wv) adjustments=\(store.totalAdjustments) ai=\(store.totalAIAnalyses)"
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: persistKey)
        }
    }
}
