import Foundation
import UIKit

nonisolated enum CustomToolType: String, Codable, Sendable, CaseIterable {
    case runHealthAnalyzer = "Run Health Analyzer"
    case checkpointVerification = "Checkpoint Verification"
    case batchInsightTuning = "Batch Insight & Tuning"

    var icon: String {
        switch self {
        case .runHealthAnalyzer: "heart.text.clipboard"
        case .checkpointVerification: "checkmark.shield"
        case .batchInsightTuning: "chart.bar.doc.horizontal"
        }
    }

    var color: String {
        switch self {
        case .runHealthAnalyzer: "red"
        case .checkpointVerification: "blue"
        case .batchInsightTuning: "purple"
        }
    }

    var description: String {
        switch self {
        case .runHealthAnalyzer: "Analyzes failed/stalled runs and returns retry/wait/stop/manual decisions"
        case .checkpointVerification: "Verifies automation reached the expected screen state"
        case .batchInsightTuning: "Finds failure patterns across batches and recommends config tuning"
        }
    }
}

nonisolated struct CustomToolExecution: Codable, Sendable, Identifiable {
    let id: String
    let toolType: String
    let sessionId: String
    let decision: String
    let confidence: Double
    let reasoning: String
    let timestamp: Date
    let durationMs: Int
    let wasApproved: Bool
}

nonisolated struct CustomToolStats: Sendable {
    let totalExecutions: Int
    let avgConfidence: Double
    let toolBreakdown: [String: Int]
    let recentExecutions: [CustomToolExecution]
    let isHealthy: Bool
}

nonisolated struct CoordinatorStore: Codable, Sendable {
    var executions: [CustomToolExecution] = []
    var toolCallCounts: [String: Int] = [:]
    var totalExecutions: Int = 0
    var approvalGateEnabled: Bool = true
    var autoApproveThreshold: Double = 0.8
}

@MainActor
class AICustomToolsCoordinator {
    static let shared = AICustomToolsCoordinator()

    private let logger = DebugLogger.shared
    private let persistKey = "AICustomToolsCoordinator_v1"
    private let maxExecutions = 300
    private var store: CoordinatorStore

    let runHealthAnalyzer = AIRunHealthAnalyzerTool.shared
    let checkpointVerifier = AICheckpointVerificationTool.shared
    let batchInsightTuning = AIBatchInsightTuningTool.shared

    var approvalGateEnabled: Bool {
        get { store.approvalGateEnabled }
        set { store.approvalGateEnabled = newValue; save() }
    }

    var autoApproveThreshold: Double {
        get { store.autoApproveThreshold }
        set { store.autoApproveThreshold = newValue; save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: persistKey),
           let decoded = try? JSONDecoder().decode(CoordinatorStore.self, from: data) {
            self.store = decoded
        } else {
            self.store = CoordinatorStore()
        }
    }

    // MARK: - Run Health Analyzer

    func analyzeRunHealth(
        sessionId: String,
        logs: [String],
        pageText: String?,
        screenshotAvailable: Bool,
        currentOutcome: String?,
        host: String?,
        attemptNumber: Int,
        elapsedMs: Int
    ) async -> RunHealthResult {
        let start = Date()
        let input = RunHealthInput(
            sessionId: sessionId,
            logs: logs,
            pageText: pageText,
            screenshotAvailable: screenshotAvailable,
            currentOutcome: currentOutcome,
            host: host,
            attemptNumber: attemptNumber,
            elapsedMs: elapsedMs
        )

        let result = await runHealthAnalyzer.analyzeRunHealth(input: input)
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        let approved = shouldAutoApprove(confidence: result.confidence, isStateChanging: result.decision == .stop || result.decision == .rotateInfra)

        recordExecution(
            toolType: .runHealthAnalyzer,
            sessionId: sessionId,
            decision: result.decision.rawValue,
            confidence: result.confidence,
            reasoning: result.reasoning,
            durationMs: durationMs,
            wasApproved: approved
        )

        return result
    }

    // MARK: - Checkpoint Verification

    func verifyCheckpoint(
        flowName: String,
        expectedState: CheckpointState,
        pageText: String?,
        currentURL: String?,
        screenshot: UIImage?,
        extractedOCR: [String],
        elapsedSinceLastCheckpoint: Int,
        sessionId: String
    ) async -> CheckpointResult {
        let start = Date()
        let input = CheckpointInput(
            flowName: flowName,
            expectedState: expectedState,
            pageText: pageText,
            currentURL: currentURL,
            screenshot: screenshot,
            extractedOCR: extractedOCR,
            elapsedSinceLastCheckpoint: elapsedSinceLastCheckpoint,
            sessionId: sessionId
        )

        let result = await checkpointVerifier.verifyCheckpoint(input: input)
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        recordExecution(
            toolType: .checkpointVerification,
            sessionId: sessionId,
            decision: result.verdict.rawValue,
            confidence: result.confidence,
            reasoning: result.reasoning,
            durationMs: durationMs,
            wasApproved: true
        )

        return result
    }

    // MARK: - Batch Insight

    func summarizeBatchPerformance(
        batchId: String,
        results: [(cardId: String, outcome: String, latencyMs: Int)],
        concurrency: Int,
        proxyTarget: String,
        networkMode: String,
        stealthEnabled: Bool,
        fingerprintSpoofing: Bool,
        pageLoadTimeout: Int,
        submitRetryCount: Int
    ) async -> BatchInsightResult {
        let start = Date()
        let settings = BatchSettingsSnapshot(
            concurrency: concurrency,
            proxyTarget: proxyTarget,
            networkMode: networkMode,
            stealthEnabled: stealthEnabled,
            fingerprintSpoofing: fingerprintSpoofing,
            pageLoadTimeout: pageLoadTimeout,
            submitRetryCount: submitRetryCount
        )
        let input = BatchInsightInput(batchId: batchId, results: results, settingsSnapshot: settings)

        let result = await batchInsightTuning.summarizeBatchPerformance(input: input)
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        recordExecution(
            toolType: .batchInsightTuning,
            sessionId: batchId,
            decision: result.overallGrade,
            confidence: result.confidence,
            reasoning: result.summary,
            durationMs: durationMs,
            wasApproved: true
        )

        return result
    }

    // MARK: - Stats

    func stats() -> CustomToolStats {
        let recentExecs = Array(store.executions.prefix(20))
        let avgConf = store.executions.isEmpty ? 0 : store.executions.prefix(50).reduce(0.0) { $0 + $1.confidence } / Double(min(50, store.executions.count))
        let isHealthy = avgConf > 0.5 || store.totalExecutions < 5

        return CustomToolStats(
            totalExecutions: store.totalExecutions,
            avgConfidence: avgConf,
            toolBreakdown: store.toolCallCounts,
            recentExecutions: recentExecs,
            isHealthy: isHealthy
        )
    }

    func resetAll() {
        runHealthAnalyzer.resetAll()
        checkpointVerifier.resetAll()
        batchInsightTuning.resetAll()
        store = CoordinatorStore()
        save()
        logger.log("CustomToolsCoordinator: ALL tools reset", category: .automation, level: .warning)
    }

    // MARK: - Private

    private func shouldAutoApprove(confidence: Double, isStateChanging: Bool) -> Bool {
        guard store.approvalGateEnabled else { return true }
        if isStateChanging { return confidence >= store.autoApproveThreshold }
        return true
    }

    private func recordExecution(toolType: CustomToolType, sessionId: String, decision: String, confidence: Double, reasoning: String, durationMs: Int, wasApproved: Bool) {
        store.totalExecutions += 1
        store.toolCallCounts[toolType.rawValue, default: 0] += 1

        let execution = CustomToolExecution(
            id: UUID().uuidString,
            toolType: toolType.rawValue,
            sessionId: sessionId,
            decision: decision,
            confidence: confidence,
            reasoning: reasoning,
            timestamp: Date(),
            durationMs: durationMs,
            wasApproved: wasApproved
        )

        store.executions.insert(execution, at: 0)
        if store.executions.count > maxExecutions {
            store.executions = Array(store.executions.prefix(maxExecutions))
        }

        save()
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: persistKey)
        }
    }
}
