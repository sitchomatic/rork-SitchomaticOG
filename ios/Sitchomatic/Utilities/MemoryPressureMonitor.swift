import Foundation
import UIKit

@MainActor
final class MemoryPressureMonitor {
    static let shared = MemoryPressureMonitor()

    private var observers: [() -> Void] = []
    private var isRegistered: Bool = false
    private var proactivePollingTask: Task<Void, Never>?
    private var consecutiveHighMemory: Int = 0
    private let warningThresholdMB: Int = 300
    private let criticalThresholdMB: Int = 450
    private let severeThresholdMB: Int = 600

    private var memoryTrend: [Int] = []
    private let trendWindowSize: Int = 10
    private var lastTierTriggered: MemoryTier = .normal
    private var tierEscalationCount: Int = 0

    nonisolated enum MemoryTier: Int, Sendable, Comparable {
        case normal = 0
        case elevated = 1
        case warning = 2
        case critical = 3
        case severe = 4

        nonisolated static func < (lhs: MemoryTier, rhs: MemoryTier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    func register() {
        guard !isRegistered else { return }
        isRegistered = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.handleMemoryWarning(tier: .critical)
            }
        }
        startProactivePolling()
    }

    func onMemoryWarning(_ handler: @escaping @MainActor () -> Void) {
        observers.append(handler)
    }

    private func handleMemoryWarning(tier: MemoryTier) {
        let tierLabel: String
        switch tier {
        case .normal: return
        case .elevated: tierLabel = "ELEVATED"
        case .warning: tierLabel = "WARNING"
        case .critical: tierLabel = "CRITICAL"
        case .severe: tierLabel = "SEVERE"
        }

        if tier > lastTierTriggered {
            tierEscalationCount += 1
        }
        lastTierTriggered = tier

        DebugLogger.shared.log("MEMORY \(tierLabel) — triggering \(observers.count) cleanup handlers (escalations: \(tierEscalationCount))", category: .system, level: tier >= .critical ? .critical : .warning)

        for handler in observers {
            handler()
        }

        if tier >= .severe {
            DebugLogger.shared.log("MemoryMonitor: SEVERE tier — additional aggressive cleanup", category: .system, level: .critical)
            WebViewPool.shared.emergencyPurgeAll()
            ScreenshotCacheService.shared.clearAll()
            URLCache.shared.removeAllCachedResponses()
            URLCache.shared.memoryCapacity = 0

            PersistentFileStorageService.shared.forceSave()
            LoginViewModel.shared.persistCredentialsNow()
            PPSRAutomationViewModel.shared.persistCardsNow()
        }
    }

    private func startProactivePolling() {
        proactivePollingTask?.cancel()
        proactivePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.computePollingInterval()
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }

                let mb = CrashProtectionService.shared.currentMemoryUsageMB()

                self.memoryTrend.append(mb)
                if self.memoryTrend.count > self.trendWindowSize {
                    self.memoryTrend.removeFirst(self.memoryTrend.count - self.trendWindowSize)
                }

                let tier = self.classifyMemoryTier(mb: mb)

                if mb > self.severeThresholdMB {
                    self.consecutiveHighMemory += 1
                    self.handleMemoryWarning(tier: .severe)
                } else if mb > self.criticalThresholdMB {
                    self.consecutiveHighMemory += 1
                    if self.consecutiveHighMemory >= 2 {
                        self.handleMemoryWarning(tier: .critical)
                    }
                } else if mb > self.warningThresholdMB {
                    self.consecutiveHighMemory += 1
                    if self.consecutiveHighMemory >= 3 {
                        self.handleMemoryWarning(tier: .warning)
                        self.consecutiveHighMemory = 0
                    }
                } else {
                    self.consecutiveHighMemory = 0
                    self.lastTierTriggered = .normal
                    self.tierEscalationCount = 0
                }

                if self.isMemoryTrendRising() && tier >= .warning {
                    DebugLogger.shared.log("MemoryMonitor: rising trend detected (\(self.memoryTrend.first ?? 0)MB → \(mb)MB over \(self.memoryTrend.count) samples)", category: .system, level: .warning)
                    if tier < .critical {
                        self.handleMemoryWarning(tier: .warning)
                    }
                }
            }
        }
    }

    private func computePollingInterval() -> TimeInterval {
        if consecutiveHighMemory > 3 { return 5 }
        if consecutiveHighMemory > 0 { return 10 }
        return 15
    }

    private func classifyMemoryTier(mb: Int) -> MemoryTier {
        if mb > severeThresholdMB { return .severe }
        if mb > criticalThresholdMB { return .critical }
        if mb > warningThresholdMB { return .warning }
        if mb > warningThresholdMB / 2 { return .elevated }
        return .normal
    }

    private func isMemoryTrendRising() -> Bool {
        guard memoryTrend.count >= 4 else { return false }
        let recent = memoryTrend.suffix(4)
        let pairs = zip(recent.dropLast(), recent.dropFirst())
        let increasingCount = pairs.filter { $0 < $1 }.count
        return increasingCount >= 3
    }

    var currentTier: MemoryTier {
        classifyMemoryTier(mb: CrashProtectionService.shared.currentMemoryUsageMB())
    }
}
