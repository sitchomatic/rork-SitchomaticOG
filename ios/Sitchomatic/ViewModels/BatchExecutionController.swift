import Foundation

@MainActor
protocol BatchExecutionController: AnyObject {
    var isRunning: Bool { get set }
    var isPaused: Bool { get set }
    var isStopping: Bool { get set }
    var pauseCountdown: Int { get set }
    var batchTotalCount: Int { get set }
    var batchCompletedCount: Int { get set }
    var activeTestCount: Int { get set }
    var maxConcurrency: Int { get set }
    var autoRetryEnabled: Bool { get set }
    var autoRetryMaxAttempts: Int { get set }
    var consecutiveUnusualFailures: Int { get set }
    var showBatchResultPopup: Bool { get set }
    var lastBatchResult: BatchResult? { get set }

    func pauseQueue()
    func resumeQueue()
    func stopQueue()
    func stopAfterCurrent()
    func log(_ message: String, level: PPSRLogEntry.Level)
}

extension BatchExecutionController {
    var batchProgress: Double {
        guard batchTotalCount > 0 else { return 0 }
        return Double(batchCompletedCount) / Double(batchTotalCount)
    }
}

@MainActor
class BatchStateManager {
    var isRunning: Bool = false
    var isPaused: Bool = false
    var isStopping: Bool = false
    var pauseCountdown: Int = 0
    var batchTotalCount: Int = 0
    var batchCompletedCount: Int = 0
    var activeTestCount: Int = 0
    var showBatchResultPopup: Bool = false
    var lastBatchResult: BatchResult?
    var autoRetryEnabled: Bool = true
    var autoRetryMaxAttempts: Int = 3
    var autoRetryBackoffCounts: [String: Int] = [:]
    var consecutiveUnusualFailures: Int = 0
    var consecutiveConnectionFailures: Int = 0

    private var pauseCountdownTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var batchTask: Task<Void, Never>?

    var batchProgress: Double {
        guard batchTotalCount > 0 else { return 0 }
        return Double(batchCompletedCount) / Double(batchTotalCount)
    }

    func prepareBatch(count: Int) {
        isRunning = true
        isPaused = false
        isStopping = false
        batchTotalCount = count
        batchCompletedCount = 0
        autoRetryBackoffCounts.removeAll()
    }

    func finalizeBatch() -> Bool {
        cancelPauseCountdown()
        stopHeartbeatMonitor()
        let stoppedEarly = isStopping
        isRunning = false
        isPaused = false
        pauseCountdown = 0
        activeTestCount = 0
        isStopping = false
        return stoppedEarly
    }

    func pauseQueue(onLog: @escaping (String, PPSRLogEntry.Level) -> Void) {
        isPaused = true
        pauseCountdown = 60
        onLog("Queue paused for 60 seconds — all sessions frozen, auto-resume in 60s", .warning)
        startPauseCountdown(onLog: onLog)
    }

    func resumeQueue(onLog: @escaping (String, PPSRLogEntry.Level) -> Void) {
        cancelPauseCountdown()
        isPaused = false
        pauseCountdown = 0
        onLog("Queue resumed", .info)
    }

    func stopQueue(onLog: @escaping (String, PPSRLogEntry.Level) -> Void) {
        cancelPauseCountdown()
        isStopping = true
        isPaused = false
        pauseCountdown = 0
        onLog("Stopping queue — current batch sessions completing, no new batches will be added", .warning)
    }

    func stopAfterCurrent(onLog: @escaping (String, PPSRLogEntry.Level) -> Void) {
        cancelPauseCountdown()
        isStopping = true
        isPaused = false
        pauseCountdown = 0
        onLog("Stopping after current batch due to unusual failures...", .warning)
    }

    func storeBatchTask(_ task: Task<Void, Never>) {
        batchTask = task
    }

    func startHeartbeatMonitor(
        sessionHeartbeatTimeout: TimeInterval,
        checkStuckSessions: @escaping () -> Int,
        onLog: @escaping (String, PPSRLogEntry.Level) -> Void
    ) {
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            while !Task.isCancelled && self.isRunning {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, self.isRunning else { break }
                let stuckCount = checkStuckSessions()
                if stuckCount > 0 {
                    onLog("Heartbeat: force-terminated \(stuckCount) stuck session(s) (>\(Int(sessionHeartbeatTimeout))s)", .warning)
                }
            }
        }
    }

    func stopHeartbeatMonitor() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func startPauseCountdown(onLog: @escaping (String, PPSRLogEntry.Level) -> Void) {
        pauseCountdownTask?.cancel()
        pauseCountdownTask = Task {
            for tick in stride(from: 59, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if !self.isPaused { return }
                self.pauseCountdown = tick
            }
            guard !Task.isCancelled, self.isPaused else { return }
            self.isPaused = false
            self.pauseCountdown = 0
            onLog("Pause timer expired — queue auto-resumed", .info)
        }
    }

    func cancelPauseCountdown() {
        pauseCountdownTask?.cancel()
        pauseCountdownTask = nil
    }
}
