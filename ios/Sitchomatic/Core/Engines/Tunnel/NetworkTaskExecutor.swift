import Foundation

// MARK: - Swift 6.2 Custom Task Executor for Network Fast Lane

/// A pinned, high-priority thread pool dedicated to tunneling and proxy operations.
///
/// When the `AutomationEngine` parses massive DOM trees, standard Swift Tasks
/// saturate the cooperative thread pool, starving VPN packet processing.
/// `NetworkTaskExecutor` isolates network-critical work onto its own concurrent
/// dispatch queue at `.userInteractive` QoS, preventing packet drops.
///
/// Usage with Swift 6.2 Task executor affinity:
/// ```swift
/// Task(executorPreference: NetworkTaskExecutor.shared) {
///     await engine.routePackets(packets)
/// }
/// ```
public final class NetworkTaskExecutor: @unchecked Sendable {
    public static let shared = NetworkTaskExecutor()

    private let queue: DispatchQueue

    private init() {
        self.queue = DispatchQueue(
            label: "com.sitchomatic.network.fastlane",
            qos: .userInteractive,
            attributes: .concurrent
        )
    }

    /// Enqueues a unit of work onto the dedicated network thread pool.
    /// Uses the high-priority concurrent queue to ensure tunnel packets
    /// are never starved by DOM parsing or JS evaluation work.
    public func enqueue(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    /// Executes async work on the network fast lane and returns the result.
    /// Bridges structured concurrency to the dedicated dispatch queue.
    public func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async rethrows -> T {
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                Task {
                    do {
                        let result = try await work()
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}

// MARK: - Convenience Extension

extension NetworkTaskExecutor {
    /// Returns the shared network lane executor for use with Task executor preferences.
    public static var networkLane: NetworkTaskExecutor { .shared }
}
