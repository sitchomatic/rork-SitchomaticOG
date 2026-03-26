import Foundation

@MainActor
class AIAnomalyForecastingService {
    static let shared = AIAnomalyForecastingService()

    private let logger = DebugLogger.shared

    private let knowledgeGraph = AIKnowledgeGraphService.shared

    private var latencyWindows: [String: RollingWindow] = [:]
    private var errorWindows: [String: RollingWindow] = [:]
    private var requestCounters: [String: RequestCounter] = [:]
    private var correlatedRegionFailures: [String: RegionFailureTracker] = [:]
    private var forecasts: [String: AnomalyForecast] = [:]

    private struct RollingWindow {
        var samples: [(timestamp: Date, value: Double)] = []
        let windowSeconds: TimeInterval

        init(windowSeconds: TimeInterval = 300) {
            self.windowSeconds = windowSeconds
        }

        mutating func add(_ value: Double) {
            let now = Date()
            samples.append((now, value))
            let cutoff = now.addingTimeInterval(-windowSeconds)
            samples.removeAll { $0.timestamp < cutoff }
        }

        var average: Double {
            guard !samples.isEmpty else { return 0 }
            return samples.map(\.value).reduce(0, +) / Double(samples.count)
        }

        var count: Int { samples.count }

        func averageForWindow(_ seconds: TimeInterval) -> Double {
            let cutoff = Date().addingTimeInterval(-seconds)
            let recent = samples.filter { $0.timestamp >= cutoff }
            guard !recent.isEmpty else { return 0 }
            return recent.map(\.value).reduce(0, +) / Double(recent.count)
        }

        func trend(shortWindow: TimeInterval = 60, longWindow: TimeInterval = 300) -> Double {
            let shortAvg = averageForWindow(shortWindow)
            let longAvg = averageForWindow(longWindow)
            guard longAvg > 0 else { return 0 }
            return (shortAvg - longAvg) / longAvg
        }
    }

    private struct RequestCounter {
        var timestamps: [Date] = []
        var blockTimestamps: [Date] = []
        let windowSeconds: TimeInterval = 300

        mutating func recordRequest() {
            let now = Date()
            timestamps.append(now)
            prune()
        }

        mutating func recordBlock() {
            let now = Date()
            blockTimestamps.append(now)
            prune()
        }

        mutating func prune() {
            let cutoff = Date().addingTimeInterval(-windowSeconds)
            timestamps.removeAll { $0 < cutoff }
            blockTimestamps.removeAll { $0 < cutoff }
        }

        var requestCount: Int { timestamps.count }
        var blockCount: Int { blockTimestamps.count }

        var predictedBlockThreshold: Int? {
            guard blockTimestamps.count >= 2 else { return nil }
            let sorted = blockTimestamps.sorted()
            var gaps: [Int] = []
            for i in 1..<sorted.count {
                let requestsBetween = timestamps.filter { $0 > sorted[i-1] && $0 <= sorted[i] }.count
                if requestsBetween > 0 {
                    gaps.append(requestsBetween)
                }
            }
            guard !gaps.isEmpty else { return nil }
            return gaps.reduce(0, +) / gaps.count
        }

        func requestsSinceLastBlock() -> Int {
            guard let lastBlock = blockTimestamps.max() else { return requestCount }
            return timestamps.filter { $0 > lastBlock }.count
        }
    }

    private struct RegionFailureTracker {
        var hostFailures: [String: Int] = [:]
        var lastUpdated: Date = Date()

        mutating func recordFailure(host: String) {
            hostFailures[host, default: 0] += 1
            lastUpdated = Date()
        }

        mutating func recordSuccess(host: String) {
            hostFailures[host] = max(0, (hostFailures[host] ?? 0) - 1)
            lastUpdated = Date()
        }

        var failingHostCount: Int {
            hostFailures.filter { $0.value >= 2 }.count
        }

        var isCorrelatedFailure: Bool {
            failingHostCount >= 2
        }
    }

    nonisolated struct AnomalyForecast: Sendable {
        let key: String
        let timestamp: Date
        let latencyTrend: Double
        let errorTrend: Double
        let predictedRateLimitIn: Int?
        let correlatedRegionFailure: Bool
        let recommendedAction: RecommendedAction
        let softBreakRecommended: Bool
        let concurrencyReduction: Int?

        nonisolated enum RecommendedAction: String, Sendable {
            case none
            case reduceConcurrency
            case rotateProxy
            case softBreak
            case regionFailover
            case throttleRequests
        }
    }

    func recordLatency(key: String, latencyMs: Int) {
        if latencyWindows[key] == nil {
            latencyWindows[key] = RollingWindow(windowSeconds: 900)
        }
        latencyWindows[key]?.add(Double(latencyMs))
    }

    func recordError(key: String, isRateLimit: Bool = false) {
        if errorWindows[key] == nil {
            errorWindows[key] = RollingWindow(windowSeconds: 300)
        }
        errorWindows[key]?.add(1.0)

        if requestCounters[key] == nil {
            requestCounters[key] = RequestCounter()
        }
        if isRateLimit {
            requestCounters[key]?.recordBlock()
        }
    }

    func recordSuccess(key: String) {
        if errorWindows[key] == nil {
            errorWindows[key] = RollingWindow(windowSeconds: 300)
        }
        errorWindows[key]?.add(0.0)

        if requestCounters[key] == nil {
            requestCounters[key] = RequestCounter()
        }
        requestCounters[key]?.recordRequest()
    }

    func recordRegionOutcome(region: String, host: String, success: Bool) {
        if correlatedRegionFailures[region] == nil {
            correlatedRegionFailures[region] = RegionFailureTracker()
        }
        if success {
            correlatedRegionFailures[region]?.recordSuccess(host: host)
        } else {
            correlatedRegionFailures[region]?.recordFailure(host: host)
        }
    }

    func forecast(key: String, region: String? = nil) -> AnomalyForecast {
        if let cached = forecasts[key], Date().timeIntervalSince(cached.timestamp) < 5 {
            return cached
        }

        let latencyTrend = latencyWindows[key]?.trend(shortWindow: 60, longWindow: 300) ?? 0
        let errorTrend = errorWindows[key]?.trend(shortWindow: 30, longWindow: 120) ?? 0

        let counter = requestCounters[key]
        let predictedBlockIn = counter?.predictedBlockThreshold
        let requestsSinceBlock = counter?.requestsSinceLastBlock() ?? 0

        var nearRateLimit: Int? = nil
        if let threshold = predictedBlockIn, threshold > 0 {
            let remaining = threshold - requestsSinceBlock
            if remaining > 0 && remaining < 10 {
                nearRateLimit = remaining
            }
        }

        let correlatedFailure: Bool
        if let region {
            correlatedFailure = correlatedRegionFailures[region]?.isCorrelatedFailure ?? false
        } else {
            correlatedFailure = false
        }

        let action: AnomalyForecast.RecommendedAction
        let softBreak: Bool
        var concurrencyReduction: Int? = nil

        if correlatedFailure {
            action = .regionFailover
            softBreak = true
            concurrencyReduction = 2
        } else if let remaining = nearRateLimit, remaining <= 5 {
            action = .throttleRequests
            softBreak = false
            concurrencyReduction = 1
        } else if latencyTrend > 0.5 {
            action = .reduceConcurrency
            softBreak = latencyTrend > 0.8
            concurrencyReduction = latencyTrend > 1.0 ? 3 : (latencyTrend > 0.7 ? 2 : 1)
        } else if errorTrend > 0.4 {
            action = .softBreak
            softBreak = true
            concurrencyReduction = 2
        } else if latencyTrend > 0.3 || errorTrend > 0.2 {
            action = .rotateProxy
            softBreak = false
        } else {
            action = .none
            softBreak = false
        }

        let result = AnomalyForecast(
            key: key,
            timestamp: Date(),
            latencyTrend: latencyTrend,
            errorTrend: errorTrend,
            predictedRateLimitIn: nearRateLimit,
            correlatedRegionFailure: correlatedFailure,
            recommendedAction: action,
            softBreakRecommended: softBreak,
            concurrencyReduction: concurrencyReduction
        )

        forecasts[key] = result

        if action != .none {
            logger.log("AnomalyForecast: \(key) → \(action.rawValue) (latTrend=\(String(format: "%.2f", latencyTrend)) errTrend=\(String(format: "%.2f", errorTrend)) rl=\(nearRateLimit.map(String.init) ?? "n/a") correlated=\(correlatedFailure))", category: .network, level: action == .regionFailover ? .critical : .warning)

            publishAnomalyToKnowledgeGraph(key: key, forecast: result)
        }

        return result
    }

    func shouldThrottleRequests(key: String) -> (shouldThrottle: Bool, delayMs: Int) {
        let f = forecast(key: key)
        switch f.recommendedAction {
        case .throttleRequests:
            return (true, 2000)
        case .softBreak:
            return (true, 3000)
        case .regionFailover:
            return (true, 5000)
        default:
            return (false, 0)
        }
    }

    func recommendedConcurrency(key: String, currentMax: Int) -> Int {
        let f = forecast(key: key)
        guard let reduction = f.concurrencyReduction else { return currentMax }
        return max(1, currentMax - reduction)
    }

    func isRegionDegraded(_ region: String) -> Bool {
        correlatedRegionFailures[region]?.isCorrelatedFailure ?? false
    }

    func degradedRegions() -> [String] {
        correlatedRegionFailures.filter { $0.value.isCorrelatedFailure }.map(\.key)
    }

    func summary(key: String) -> String {
        let f = forecast(key: key)
        let latAvg = Int(latencyWindows[key]?.averageForWindow(60) ?? 0)
        let errCount = errorWindows[key]?.count ?? 0
        return "lat:\(latAvg)ms err:\(errCount) trend:\(String(format: "%.1f", f.latencyTrend)) action:\(f.recommendedAction.rawValue)"
    }

    func resetAll() {
        latencyWindows.removeAll()
        errorWindows.removeAll()
        requestCounters.removeAll()
        correlatedRegionFailures.removeAll()
        forecasts.removeAll()
    }

    func reset(key: String) {
        latencyWindows.removeValue(forKey: key)
        errorWindows.removeValue(forKey: key)
        requestCounters.removeValue(forKey: key)
        forecasts.removeValue(forKey: key)
    }

    private func publishAnomalyToKnowledgeGraph(key: String, forecast: AnomalyForecast) {
        let severity: KnowledgeSeverity
        switch forecast.recommendedAction {
        case .regionFailover: severity = .critical
        case .softBreak: severity = .high
        case .reduceConcurrency, .throttleRequests: severity = .medium
        case .rotateProxy: severity = .medium
        case .none: severity = .low
        }

        var payload: [String: String] = [
            "action": forecast.recommendedAction.rawValue,
            "latencyTrend": String(format: "%.2f", forecast.latencyTrend),
            "errorTrend": String(format: "%.2f", forecast.errorTrend),
            "correlatedRegionFailure": "\(forecast.correlatedRegionFailure)",
            "softBreakRecommended": "\(forecast.softBreakRecommended)",
            "forecast": forecast.recommendedAction == .none ? "stable" : "degrading",
        ]
        if let rl = forecast.predictedRateLimitIn { payload["predictedRateLimitIn"] = "\(rl)" }
        if let cr = forecast.concurrencyReduction { payload["concurrencyReduction"] = "\(cr)" }

        let host = key.components(separatedBy: "|").first ?? key

        let summary = "Anomaly on \(key): \(forecast.recommendedAction.rawValue) — latTrend \(String(format: "%.1f", forecast.latencyTrend)), errTrend \(String(format: "%.1f", forecast.errorTrend))"

        knowledgeGraph.publishEvent(
            source: "AIAnomalyForecasting",
            host: host,
            domain: .anomaly,
            type: .anomalyAlert,
            severity: severity,
            confidence: 0.75,
            payload: payload,
            summary: summary
        )
    }
}
