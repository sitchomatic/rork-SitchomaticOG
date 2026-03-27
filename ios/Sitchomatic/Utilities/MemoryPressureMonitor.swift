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
            ScreenshotCacheService.shared.clearAll()
            URLCache.shared.removeAllCachedResponses()
            URLCache.shared.memoryCapacity = 0

            PersistentFileStorageService.shared.forceSave()
            LoginViewModel.shared.persistCredentialsNow()
            PPSRAutomationViewModel.shared.persistCardsNow()
        }
    }

    private func classifyMemoryTier(mb: Int) -> MemoryTier {
        if mb > severeThresholdMB { return .severe }
        if mb > criticalThresholdMB { return .critical }
        if mb > warningThresholdMB { return .warning }
        if mb > warningThresholdMB / 2 { return .elevated }
        return .normal
    }

    var currentTier: MemoryTier {
        classifyMemoryTier(mb: CrashProtectionService.shared.currentMemoryUsageMB())
    }
}
