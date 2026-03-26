import Foundation

@MainActor
class MemoryMonitor {
    struct Thresholds {
        let softMB: Int = 1500
        let highMB: Int = 2500
        let criticalMB: Int = 4000
        let emergencyMB: Int = 5000
    }

    let thresholds = Thresholds()

    private(set) var growthRateMBPerSecond: Double = 0
    private(set) var deathSpiralDetected: Bool = false
    private(set) var preemptiveThrottleActive: Bool = false
    private(set) var consecutiveCriticalChecks: Int = 0

    private var history: [(timestamp: Date, mb: Int)] = []
    private let historyMaxCount: Int = 30
    private var lastCheckTime: Date = Date()
    private var lastCheckMB: Int = 0

    enum MemoryLevel {
        case normal
        case soft
        case high
        case critical
        case emergency
    }

    func update() -> (level: MemoryLevel, mb: Int) {
        let now = Date()
        let usedMB = Self.currentUsageMB()

        let timeDelta = now.timeIntervalSince(lastCheckTime)
        if timeDelta > 0 {
            growthRateMBPerSecond = Double(usedMB - lastCheckMB) / timeDelta
        }
        lastCheckTime = now
        lastCheckMB = usedMB

        history.append((now, usedMB))
        if history.count > historyMaxCount {
            history.removeFirst(history.count - historyMaxCount)
        }

        checkDeathSpiral(currentMB: usedMB)
        checkRunawayGrowth(currentMB: usedMB)

        let level: MemoryLevel
        if usedMB > thresholds.emergencyMB {
            consecutiveCriticalChecks += 1
            level = .emergency
        } else if usedMB > thresholds.criticalMB {
            consecutiveCriticalChecks += 1
            level = .critical
        } else if usedMB > thresholds.highMB {
            consecutiveCriticalChecks = max(0, consecutiveCriticalChecks - 1)
            preemptiveThrottleActive = false
            level = .high
        } else if usedMB > thresholds.softMB {
            consecutiveCriticalChecks = 0
            preemptiveThrottleActive = false
            deathSpiralDetected = false
            level = .soft
        } else {
            consecutiveCriticalChecks = 0
            preemptiveThrottleActive = false
            deathSpiralDetected = false
            level = .normal
        }

        return (level, usedMB)
    }

    var shouldEscalateToCritical: Bool {
        consecutiveCriticalChecks >= 3
    }

    static func currentUsageMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size / (1024 * 1024))
    }

    var adaptiveCheckInterval: TimeInterval {
        if lastCheckMB > thresholds.criticalMB || deathSpiralDetected { return 2 }
        if lastCheckMB > thresholds.highMB { return 3 }
        if lastCheckMB > thresholds.softMB { return 5 }
        return 10
    }

    var shouldReduceConcurrency: Bool {
        lastCheckMB > thresholds.highMB || deathSpiralDetected || preemptiveThrottleActive
    }

    var recommendedMaxConcurrency: Int {
        if lastCheckMB > thresholds.criticalMB || deathSpiralDetected { return 1 }
        if lastCheckMB > thresholds.highMB || preemptiveThrottleActive { return 2 }
        if lastCheckMB > thresholds.softMB { return 3 }
        return 5
    }

    private func checkDeathSpiral(currentMB: Int) {
        guard history.count >= 5 else { return }
        let recent = history.suffix(5)
        let allIncreasing = zip(recent.dropLast(), recent.dropFirst()).allSatisfy { $0.mb < $1.mb }
        guard let first = recent.first, let last = recent.last else { return }
        let totalGrowth = last.mb - first.mb
        let timeSpan = last.timestamp.timeIntervalSince(first.timestamp)

        if allIncreasing && totalGrowth > 500 && timeSpan > 0 {
            let ratePerMin = Double(totalGrowth) / (timeSpan / 60.0)
            if ratePerMin > 200 {
                deathSpiralDetected = true
            }
        }
    }

    private func checkRunawayGrowth(currentMB: Int) {
        guard growthRateMBPerSecond > 50 && currentMB > thresholds.softMB else { return }
        preemptiveThrottleActive = true
    }
}
