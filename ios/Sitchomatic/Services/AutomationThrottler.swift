import Foundation

actor AutomationThrottler {
    private var activeCount: Int = 0
    private var maxConcurrency: Int
    private var backoffMs: Int = 0
    private var consecutiveFailures: Int = 0
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var isCancelled: Bool = false

    init(maxConcurrency: Int = 5) {
        self.maxConcurrency = maxConcurrency
    }

    func acquire() async -> Bool {
        guard !isCancelled else { return false }
        if activeCount < maxConcurrency {
            activeCount += 1
        } else {
            let acquired = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(continuation)
                }
            }
            guard acquired, !isCancelled else { return false }
        }
        if backoffMs > 0 {
            try? await Task.sleep(for: .milliseconds(backoffMs))
        }
        return !isCancelled
    }

    func release(succeeded: Bool) {
        activeCount = max(0, activeCount - 1)
        if succeeded {
            consecutiveFailures = 0
            backoffMs = max(0, backoffMs - 200)
        } else {
            consecutiveFailures += 1
            backoffMs = min(10000, 500 * (1 << min(consecutiveFailures, 5)))
        }
        resumeNextWaiterIfPossible()
    }

    private func resumeNextWaiterIfPossible() {
        while !waiters.isEmpty && activeCount < maxConcurrency {
            activeCount += 1
            let next = waiters.removeFirst()
            next.resume(returning: true)
        }
    }

    func updateMaxConcurrency(_ newMax: Int) {
        let old = maxConcurrency
        maxConcurrency = max(1, min(10, newMax))
        if maxConcurrency > old {
            resumeNextWaiterIfPossible()
        }
    }

    func currentStats() -> (active: Int, maxConcurrency: Int, backoffMs: Int, consecutiveFailures: Int) {
        (activeCount, maxConcurrency, backoffMs, consecutiveFailures)
    }

    func reset() {
        activeCount = 0
        backoffMs = 0
        consecutiveFailures = 0
        isCancelled = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: false)
        }
    }

    func cancelAll() {
        isCancelled = true
        activeCount = 0
        backoffMs = 0
        consecutiveFailures = 0
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: false)
        }
    }
}
