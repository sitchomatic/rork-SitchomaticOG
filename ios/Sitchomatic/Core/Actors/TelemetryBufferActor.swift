import Foundation
import os

// MARK: - Telemetry Buffer Actor

/// High-performance telemetry collector using `OSAllocatedUnfairLock`
/// for nanosecond-level safe writes from any isolation domain.
///
/// Replaces scattered `StatsTrackingService` and `TaskMetricsCollectionService`
/// state mutations with a single lock-protected buffer that can accept
/// telemetry events from actors, `@MainActor`, and `nonisolated` contexts
/// without requiring `await`.
///
/// The `OSAllocatedUnfairLock` (iOS 16+) provides:
/// - No heap allocation for the lock itself (OS-allocated)
/// - No priority inversion (unfair scheduling)
/// - Nanosecond acquisition in uncontended cases
/// - Safe use from any Swift concurrency context
public actor TelemetryBufferActor {
    public static let shared = TelemetryBufferActor()

    // MARK: - Metric Types

    public enum MetricCategory: String, Sendable, CaseIterable {
        case packetsSent
        case packetsReceived
        case bytesTransferred
        case loginAttempts
        case loginSuccesses
        case loginFailures
        case proxyRotations
        case fingerprintChecks
        case fingerprintFailures
        case domParseOperations
        case webViewSpawns
        case captchaChallenges
        case tunnelReconnects
    }

    /// A single telemetry event — pure value type for zero-cost transfer.
    public struct TelemetryEvent: Sendable {
        public let category: MetricCategory
        public let value: Int64
        public let timestamp: Date

        public init(category: MetricCategory, value: Int64 = 1, timestamp: Date = Date()) {
            self.category = category
            self.value = value
            self.timestamp = timestamp
        }
    }

    /// Aggregated metrics snapshot.
    public struct MetricsSnapshot: Sendable {
        public let counters: [MetricCategory: Int64]
        public let eventCount: Int
        public let oldestEvent: Date?
        public let newestEvent: Date?
    }

    // MARK: - Lock-Protected Buffer

    /// The lock-protected buffer uses `OSAllocatedUnfairLock` for writes
    /// that can happen from any thread/actor without `await`.
    private let buffer = OSAllocatedUnfairLock(initialState: [TelemetryEvent]())
    private let counters = OSAllocatedUnfairLock(initialState: [MetricCategory: Int64]())

    private let maxBufferSize = 10_000

    // MARK: - Recording (Lock-Based, No Await Required)

    /// Records a telemetry event using the unfair lock.
    /// This method is `nonisolated` so it can be called from any context
    /// without awaiting actor isolation — critical for hot-path metrics
    /// like packet counting.
    nonisolated public func record(_ event: TelemetryEvent) {
        counters.withLock { state in
            state[event.category, default: 0] += event.value
        }
        buffer.withLock { state in
            state.append(event)
            // Ring-buffer behavior: drop oldest when full
            if state.count > maxBufferSize {
                state.removeFirst(state.count - maxBufferSize)
            }
        }
    }

    /// Convenience: record a simple counter increment.
    nonisolated public func increment(_ category: MetricCategory, by value: Int64 = 1) {
        record(TelemetryEvent(category: category, value: value))
    }

    // MARK: - Reading (Actor-Isolated)

    /// Returns a snapshot of all aggregated counters.
    public func snapshot() -> MetricsSnapshot {
        let currentCounters = counters.withLock { $0 }
        let events = buffer.withLock { $0 }
        return MetricsSnapshot(
            counters: currentCounters,
            eventCount: events.count,
            oldestEvent: events.first?.timestamp,
            newestEvent: events.last?.timestamp
        )
    }

    /// Returns the current value for a specific metric.
    nonisolated public func counter(for category: MetricCategory) -> Int64 {
        counters.withLock { $0[category, default: 0] }
    }

    /// Returns recent events matching a category, newest first.
    public func recentEvents(category: MetricCategory, limit: Int = 100) -> [TelemetryEvent] {
        buffer.withLock { state in
            state.filter { $0.category == category }
                .suffix(limit)
                .reversed()
        }
    }

    /// Flushes the event buffer while preserving counters.
    public func flushBuffer() {
        buffer.withLock { $0.removeAll() }
    }

    /// Resets all telemetry state.
    public func resetAll() {
        buffer.withLock { $0.removeAll() }
        counters.withLock { $0.removeAll() }
    }

    // MARK: - AsyncStream for Real-Time Dashboard

    /// Provides a periodic metrics stream for the dashboard UI.
    /// Emits snapshots at the specified interval with backpressure support.
    public func metricsStream(interval: Duration = .seconds(1)) -> AsyncStream<MetricsSnapshot> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    let snap = await self.snapshot()
                    continuation.yield(snap)
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
