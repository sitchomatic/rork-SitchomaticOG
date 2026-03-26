import Foundation

nonisolated struct ConcurrentBatchResult<T: Sendable>: Sendable {
    let results: [T]
    let totalTimeMs: Int
    let successCount: Int
    let failureCount: Int
    let avgLatencyMs: Int
}

nonisolated struct BatchLiveStats: Sendable {
    let processed: Int
    let total: Int
    let successCount: Int
    let failureCount: Int
    let successRate: Double
    let avgLatencyMs: Int
    let throughputPerMinute: Double
    let estimatedRemainingSeconds: Int
    let elapsedMs: Int
    let deadAccountCount: Int
    let deadCardCount: Int
}
