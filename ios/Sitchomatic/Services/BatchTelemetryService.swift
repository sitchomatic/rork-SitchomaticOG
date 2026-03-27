import Foundation

@MainActor
class BatchTelemetryService {
    static let shared = BatchTelemetryService()

    private let logger = DebugLogger.shared
    private let persistKey = "batch_telemetry_v1"
    private(set) var batchRecords: [BatchRecord] = []
    private let maxRecords: Int = 100

    struct BatchRecord: Identifiable {
        let id: UUID
        let batchId: String
        let startedAt: Date
        var completedAt: Date?
        var totalItems: Int
        var processedItems: Int
        var successCount: Int
        var failureCount: Int
        var connectionFailures: Int
        var timeouts: Int
        var rateLimitHits: Int
        var avgLatencyMs: Int
        var ipRotations: Int
        var autoPauseTriggers: Int
        var proxyTarget: String
        var networkMode: String

        var durationSeconds: Int {
            Int((completedAt ?? Date()).timeIntervalSince(startedAt))
        }

        var successRate: Double {
            let total = successCount + failureCount
            guard total > 0 else { return 0 }
            return Double(successCount) / Double(total)
        }

        var throughputPerMinute: Double {
            let minutes = max(0.01, Double(durationSeconds) / 60.0)
            return Double(processedItems) / minutes
        }
    }

    private var activeBatch: BatchRecord?

    func startBatch(batchId: String, totalItems: Int, proxyTarget: String, networkMode: String) {
        activeBatch = BatchRecord(
            id: UUID(),
            batchId: batchId,
            startedAt: Date(),
            totalItems: totalItems,
            processedItems: 0,
            successCount: 0,
            failureCount: 0,
            connectionFailures: 0,
            timeouts: 0,
            rateLimitHits: 0,
            avgLatencyMs: 0,
            ipRotations: 0,
            autoPauseTriggers: 0,
            proxyTarget: proxyTarget,
            networkMode: networkMode
        )
    }

    func recordOutcome(success: Bool, latencyMs: Int, isConnectionFailure: Bool = false, isTimeout: Bool = false, isRateLimit: Bool = false) {
        guard activeBatch != nil else { return }
        activeBatch?.processedItems += 1
        if success {
            activeBatch?.successCount += 1
        } else {
            activeBatch?.failureCount += 1
        }
        if isConnectionFailure { activeBatch?.connectionFailures += 1 }
        if isTimeout { activeBatch?.timeouts += 1 }
        if isRateLimit { activeBatch?.rateLimitHits += 1 }

        if let processed = activeBatch?.processedItems, processed > 0 {
            let totalLatency = (activeBatch?.avgLatencyMs ?? 0) * (processed - 1) + latencyMs
            activeBatch?.avgLatencyMs = totalLatency / processed
        }
    }

    func recordIPRotation() {
        activeBatch?.ipRotations += 1
    }

    func recordAutoPause() {
        activeBatch?.autoPauseTriggers += 1
    }

    func endBatch() {
        guard var batch = activeBatch else { return }
        batch.completedAt = Date()
        batchRecords.insert(batch, at: 0)
        if batchRecords.count > maxRecords {
            batchRecords = Array(batchRecords.prefix(maxRecords))
        }
        persistRecords()

        logger.log("Telemetry: batch \(batch.batchId) complete — \(batch.successCount)/\(batch.processedItems) success (\(Int(batch.successRate * 100))%), \(batch.durationSeconds)s, \(String(format: "%.1f", batch.throughputPerMinute))/min, \(batch.ipRotations) rotations, \(batch.autoPauseTriggers) pauses", category: .automation, level: .info)

        activeBatch = nil
    }

    var currentBatch: BatchRecord? { activeBatch }

    func trendAnalysis(lastN: Int = 10) -> TrendAnalysis {
        let recent = Array(batchRecords.prefix(lastN))
        guard recent.count >= 2 else {
            return TrendAnalysis(successRateTrend: .stable, throughputTrend: .stable, latencyTrend: .stable, avgSuccessRate: recent.first?.successRate ?? 0, avgThroughput: recent.first?.throughputPerMinute ?? 0, avgLatencyMs: recent.first?.avgLatencyMs ?? 0)
        }

        let halfPoint = recent.count / 2
        let recentHalf = Array(recent.prefix(halfPoint))
        let olderHalf = Array(recent.suffix(from: halfPoint))

        let recentSR = recentHalf.isEmpty ? 0 : recentHalf.reduce(0.0) { $0 + $1.successRate } / Double(recentHalf.count)
        let olderSR = olderHalf.isEmpty ? 0 : olderHalf.reduce(0.0) { $0 + $1.successRate } / Double(olderHalf.count)

        let recentTP = recentHalf.isEmpty ? 0 : recentHalf.reduce(0.0) { $0 + $1.throughputPerMinute } / Double(recentHalf.count)
        let olderTP = olderHalf.isEmpty ? 0 : olderHalf.reduce(0.0) { $0 + $1.throughputPerMinute } / Double(olderHalf.count)

        let recentLat = recentHalf.isEmpty ? 0 : recentHalf.reduce(0) { $0 + $1.avgLatencyMs } / recentHalf.count
        let olderLat = olderHalf.isEmpty ? 0 : olderHalf.reduce(0) { $0 + $1.avgLatencyMs } / olderHalf.count

        let srDelta = recentSR - olderSR
        let tpDelta = recentTP - olderTP
        let latDelta = recentLat - olderLat

        return TrendAnalysis(
            successRateTrend: srDelta > 0.05 ? .improving : (srDelta < -0.05 ? .declining : .stable),
            throughputTrend: tpDelta > 1.0 ? .improving : (tpDelta < -1.0 ? .declining : .stable),
            latencyTrend: latDelta > 500 ? .declining : (latDelta < -500 ? .improving : .stable),
            avgSuccessRate: recentSR,
            avgThroughput: recentTP,
            avgLatencyMs: recentLat
        )
    }

    nonisolated enum Trend: String, Sendable {
        case improving
        case stable
        case declining
    }

    struct TrendAnalysis {
        let successRateTrend: Trend
        let throughputTrend: Trend
        let latencyTrend: Trend
        let avgSuccessRate: Double
        let avgThroughput: Double
        let avgLatencyMs: Int
    }

    func aggregateStats() -> AggregateStats {
        let total = batchRecords.count
        let totalItems = batchRecords.reduce(0) { $0 + $1.processedItems }
        let totalSuccess = batchRecords.reduce(0) { $0 + $1.successCount }
        let totalRotations = batchRecords.reduce(0) { $0 + $1.ipRotations }
        let totalPauses = batchRecords.reduce(0) { $0 + $1.autoPauseTriggers }
        let totalConnFails = batchRecords.reduce(0) { $0 + $1.connectionFailures }
        let totalTimeouts = batchRecords.reduce(0) { $0 + $1.timeouts }
        let totalRateLimits = batchRecords.reduce(0) { $0 + $1.rateLimitHits }
        let avgSR = total > 0 ? batchRecords.reduce(0.0) { $0 + $1.successRate } / Double(total) : 0

        return AggregateStats(
            totalBatches: total,
            totalItems: totalItems,
            totalSuccess: totalSuccess,
            overallSuccessRate: avgSR,
            totalIPRotations: totalRotations,
            totalAutoPauses: totalPauses,
            totalConnectionFailures: totalConnFails,
            totalTimeouts: totalTimeouts,
            totalRateLimitHits: totalRateLimits
        )
    }

    struct AggregateStats {
        let totalBatches: Int
        let totalItems: Int
        let totalSuccess: Int
        let overallSuccessRate: Double
        let totalIPRotations: Int
        let totalAutoPauses: Int
        let totalConnectionFailures: Int
        let totalTimeouts: Int
        let totalRateLimitHits: Int
    }

    func clearHistory() {
        batchRecords.removeAll()
        persistRecords()
        logger.log("Telemetry: batch history cleared", category: .automation, level: .info)
    }

    private func persistRecords() {
        let encoded: [[String: Any]] = batchRecords.prefix(maxRecords).map { record in
            [
                "batchId": record.batchId,
                "startedAt": record.startedAt.timeIntervalSince1970,
                "completedAt": record.completedAt?.timeIntervalSince1970 ?? 0,
                "totalItems": record.totalItems,
                "processedItems": record.processedItems,
                "successCount": record.successCount,
                "failureCount": record.failureCount,
                "connectionFailures": record.connectionFailures,
                "timeouts": record.timeouts,
                "rateLimitHits": record.rateLimitHits,
                "avgLatencyMs": record.avgLatencyMs,
                "ipRotations": record.ipRotations,
                "autoPauseTriggers": record.autoPauseTriggers,
                "proxyTarget": record.proxyTarget,
                "networkMode": record.networkMode,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: encoded) {
            UserDefaults.standard.set(data, forKey: persistKey)
        }
    }

    init() {
        loadRecords()
    }

    private func loadRecords() {
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        batchRecords = array.compactMap { dict -> BatchRecord? in
            guard let batchId = dict["batchId"] as? String,
                  let startTs = dict["startedAt"] as? TimeInterval else { return nil }
            let completedTs = dict["completedAt"] as? TimeInterval
            return BatchRecord(
                id: UUID(),
                batchId: batchId,
                startedAt: Date(timeIntervalSince1970: startTs),
                completedAt: completedTs.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                totalItems: dict["totalItems"] as? Int ?? 0,
                processedItems: dict["processedItems"] as? Int ?? 0,
                successCount: dict["successCount"] as? Int ?? 0,
                failureCount: dict["failureCount"] as? Int ?? 0,
                connectionFailures: dict["connectionFailures"] as? Int ?? 0,
                timeouts: dict["timeouts"] as? Int ?? 0,
                rateLimitHits: dict["rateLimitHits"] as? Int ?? 0,
                avgLatencyMs: dict["avgLatencyMs"] as? Int ?? 0,
                ipRotations: dict["ipRotations"] as? Int ?? 0,
                autoPauseTriggers: dict["autoPauseTriggers"] as? Int ?? 0,
                proxyTarget: dict["proxyTarget"] as? String ?? "",
                networkMode: dict["networkMode"] as? String ?? ""
            )
        }
        logger.log("Telemetry: loaded \(batchRecords.count) batch records", category: .automation, level: .info)
    }
}
