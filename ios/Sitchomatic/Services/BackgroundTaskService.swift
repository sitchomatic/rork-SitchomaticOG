import BackgroundTasks
import UIKit
import ActivityKit

@MainActor
class BackgroundTaskService {
    static let shared = BackgroundTaskService()
    static let batchProcessingIdentifier = "Sitchomatic.ios77.batchProcessing"

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundMonitorTimer: Timer?
    private var isInBackground: Bool = false

    func beginExtendedBackgroundExecution(reason: String) {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: reason) { [weak self] in
            self?.handleBackgroundTimeExpiring()
        }
        DebugLogger.shared.log("Background execution started: \(reason)", category: .system, level: .info)
        startBackgroundMonitoring()
    }

    func endExtendedBackgroundExecution() {
        guard backgroundTask != .invalid else { return }
        stopBackgroundMonitoring()
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        DebugLogger.shared.log("Background execution ended", category: .system, level: .info)
    }

    var isRunningInBackground: Bool {
        backgroundTask != .invalid
    }

    var remainingBackgroundTime: TimeInterval {
        UIApplication.shared.backgroundTimeRemaining
    }

    func handleAppDidEnterBackground() {
        isInBackground = true
        let vm = RunCommandViewModel.shared

        if vm.isAnyRunning {
            beginExtendedBackgroundExecution(reason: "Batch processing in progress")

            let siteMode: String
            switch vm.activeMode {
            case .login:
                let loginVM = LoginViewModel.shared
                switch loginVM.siteMode {
                case .joe: siteMode = "joe"
                case .ignition: siteMode = "ignition"
                case .double: siteMode = "double"
                }
            case .ppsr: siteMode = "ppsr"
            case .none: siteMode = "none"
            }

            LiveActivityService.shared.startActivity(
                siteLabel: vm.siteLabel,
                siteMode: siteMode,
                totalCount: vm.totalCount
            )
        }
    }

    func handleAppWillEnterForeground() {
        isInBackground = false
        LiveActivityService.shared.endActivity()

        if isRunningInBackground {
            endExtendedBackgroundExecution()
        }
    }

    func handleBatchStarted() {
        if isInBackground {
            let vm = RunCommandViewModel.shared
            let siteMode: String
            switch vm.activeMode {
            case .login:
                let loginVM = LoginViewModel.shared
                switch loginVM.siteMode {
                case .joe: siteMode = "joe"
                case .ignition: siteMode = "ignition"
                case .double: siteMode = "double"
                }
            case .ppsr: siteMode = "ppsr"
            case .none: siteMode = "none"
            }

            LiveActivityService.shared.startActivity(
                siteLabel: vm.siteLabel,
                siteMode: siteMode,
                totalCount: vm.totalCount
            )

            if !isRunningInBackground {
                beginExtendedBackgroundExecution(reason: "Batch processing started while backgrounded")
            }
        }
    }

    func handleBatchEnded() {
        LiveActivityService.shared.endActivity()
    }

    private func handleBackgroundTimeExpiring() {
        DebugLogger.shared.log("Background time expiring — persisting state", category: .system, level: .warning)

        PersistentFileStorageService.shared.forceSave()
        DebugLogger.shared.persistLatestLog()
        LoginViewModel.shared.persistCredentialsNow()
        PPSRAutomationViewModel.shared.persistCardsNow()

        LiveActivityService.shared.updateActivity()

        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        stopBackgroundMonitoring()
    }

    private func startBackgroundMonitoring() {
        stopBackgroundMonitoring()
        backgroundMonitorTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkBackgroundState()
            }
        }
    }

    private func stopBackgroundMonitoring() {
        backgroundMonitorTimer?.invalidate()
        backgroundMonitorTimer = nil
    }

    private func checkBackgroundState() {
        let remaining = remainingBackgroundTime
        let vm = RunCommandViewModel.shared

        if remaining < 30 && remaining != .greatestFiniteMagnitude {
            DebugLogger.shared.log("Background time low: \(Int(remaining))s remaining", category: .system, level: .warning)

            PersistentFileStorageService.shared.forceSave()
            LoginViewModel.shared.persistCredentialsNow()
            PPSRAutomationViewModel.shared.persistCardsNow()
        }

        if !vm.isAnyRunning && isRunningInBackground {
            endExtendedBackgroundExecution()
            LiveActivityService.shared.endActivity()
        }
    }
}
