import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
class RunCommandViewModel {
    static let shared = RunCommandViewModel()

    private let loginVM = LoginViewModel.shared
    private let ppsrVM = PPSRAutomationViewModel.shared

    var isExpanded: Bool = false
    var showFullSheet: Bool = false
    private var failurePulse: Bool = false

    enum ActiveMode: String {
        case login, ppsr, none
    }

    var activeMode: ActiveMode {
        if loginVM.isRunning { return .login }
        if ppsrVM.isRunning { return .ppsr }
        return .none
    }

    var isAnyRunning: Bool { activeMode != .none }

    var siteLabel: String {
        switch activeMode {
        case .login: loginVM.batchSiteLabel.isEmpty ? loginVM.siteMode.rawValue : loginVM.batchSiteLabel
        case .ppsr: "PPSR"
        case .none: ""
        }
    }

    var siteIcon: String {
        switch activeMode {
        case .login:
            switch loginVM.siteMode {
            case .joe: "suit.spade.fill"
            case .double: "arrow.triangle.branch"
            case .ignition: "flame.fill"
            }
        case .ppsr: "bolt.shield.fill"
        case .none: "circle"
        }
    }

    var siteColor: Color {
        switch activeMode {
        case .login:
            switch loginVM.siteMode {
            case .joe: .green
            case .double: .cyan
            case .ignition: .orange
            }
        case .ppsr: .teal
        case .none: .secondary
        }
    }

    var isPaused: Bool {
        switch activeMode {
        case .login: loginVM.isPaused
        case .ppsr: ppsrVM.isPaused
        case .none: false
        }
    }

    var isStopping: Bool {
        switch activeMode {
        case .login: loginVM.isStopping
        case .ppsr: ppsrVM.isStopping
        case .none: false
        }
    }

    var statusColor: Color {
        if isStopping { return .red }
        if isPaused { return .orange }
        return .green
    }

    var statusLabel: String {
        if isStopping { return "STOPPING" }
        if isPaused { return "PAUSED" }
        return "LIVE"
    }

    var completedCount: Int {
        switch activeMode {
        case .login: loginVM.batchCompletedCount
        case .ppsr: ppsrVM.batchCompletedCount
        case .none: 0
        }
    }

    var totalCount: Int {
        switch activeMode {
        case .login: loginVM.batchTotalCount
        case .ppsr: ppsrVM.batchTotalCount
        case .none: 0
        }
    }

    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }

    var workingCount: Int {
        switch activeMode {
        case .login: loginVM.attempts.filter { $0.status.isTerminal && $0.credential.status == .working }.count
        case .ppsr: ppsrVM.workingCards.count
        case .none: 0
        }
    }

    var noAccCount: Int {
        switch activeMode {
        case .login: loginVM.attempts.filter { $0.status.isTerminal && $0.credential.status == .noAcc }.count
        case .ppsr: 0
        case .none: 0
        }
    }

    var tempDisCount: Int {
        switch activeMode {
        case .login: loginVM.attempts.filter { $0.status.isTerminal && $0.credential.status == .tempDisabled }.count
        case .ppsr: 0
        case .none: 0
        }
    }

    var permDisCount: Int {
        switch activeMode {
        case .login: loginVM.attempts.filter { $0.status.isTerminal && $0.credential.status == .permDisabled }.count
        case .ppsr: 0
        case .none: 0
        }
    }

    var failedCount: Int {
        switch activeMode {
        case .login: loginVM.batchFailCount
        case .ppsr: ppsrVM.deadCards.count
        case .none: 0
        }
    }

    var successRate: Double {
        guard completedCount > 0 else { return 0 }
        let successes: Int
        switch activeMode {
        case .login: successes = workingCount
        case .ppsr: successes = ppsrVM.workingCards.count
        case .none: successes = 0
        }
        return Double(successes) / Double(completedCount)
    }

    var elapsedString: String {
        let start: Date?
        switch activeMode {
        case .login: start = loginVM.batchStartTime
        case .ppsr: start = nil
        case .none: start = nil
        }
        guard let start else { return "--" }
        let elapsed = Date().timeIntervalSince(start)
        let mins = Int(elapsed) / 60
        let secs = Int(elapsed) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    var etaString: String {
        let start: Date?
        switch activeMode {
        case .login: start = loginVM.batchStartTime
        default: start = nil
        }
        guard let start, completedCount > 0 else { return "--" }
        let elapsed = Date().timeIntervalSince(start)
        let rate = elapsed / Double(completedCount)
        let remaining = rate * Double(max(0, totalCount - completedCount))
        let mins = Int(remaining) / 60
        let secs = Int(remaining) % 60
        return String(format: "~%d:%02d", mins, secs)
    }

    var maxConcurrency: Int {
        get {
            switch activeMode {
            case .login: loginVM.maxConcurrency
            case .ppsr: ppsrVM.maxConcurrency
            case .none: 4
            }
        }
        set {
            switch activeMode {
            case .login: loginVM.maxConcurrency = newValue
            case .ppsr: ppsrVM.maxConcurrency = newValue
            case .none: break
            }
        }
    }

    var activeSessionItems: [ActiveSessionItem] {
        switch activeMode {
        case .login:
            return loginVM.attempts
                .filter { !$0.status.isTerminal }
                .prefix(20)
                .map { attempt in
                    ActiveSessionItem(
                        id: attempt.id.uuidString,
                        label: attempt.credential.username,
                        statusText: attempt.status.rawValue,
                        statusIcon: attempt.status.icon,
                        elapsed: attempt.formattedDuration,
                        progress: attempt.status.progress,
                        isActive: !attempt.status.isTerminal
                    )
                }
        case .ppsr:
            return ppsrVM.checks
                .filter { !$0.status.isTerminal }
                .prefix(20)
                .map { check in
                    ActiveSessionItem(
                        id: check.id.uuidString,
                        label: "\(check.card.brand.rawValue) •••\(check.card.number.suffix(4))",
                        statusText: check.status.rawValue,
                        statusIcon: check.status.icon,
                        elapsed: check.formattedDuration,
                        progress: check.status.progress,
                        isActive: !check.status.isTerminal
                    )
                }
        case .none:
            return []
        }
    }

    var recentFailures: [RecentFailureItem] {
        switch activeMode {
        case .login:
            return loginVM.attempts
                .filter { $0.status == .failed }
                .prefix(5)
                .map { attempt in
                    RecentFailureItem(
                        id: attempt.id.uuidString,
                        label: attempt.credential.username,
                        reason: attempt.errorMessage ?? attempt.credential.status.rawValue,
                        resultStatus: attempt.credential.status.rawValue
                    )
                }
        case .ppsr:
            return ppsrVM.checks
                .filter { $0.status == .failed }
                .prefix(5)
                .map { check in
                    RecentFailureItem(
                        id: check.id.uuidString,
                        label: "\(check.card.brand.rawValue) •••\(check.card.number.suffix(4))",
                        reason: check.errorMessage ?? "Failed",
                        resultStatus: "Dead"
                    )
                }
        case .none:
            return []
        }
    }

    var hasFailureStreak: Bool {
        switch activeMode {
        case .login: loginVM.consecutiveConnectionFailures >= 3 || loginVM.consecutiveUnusualFailures >= 3
        case .ppsr: ppsrVM.consecutiveUnusualFailures >= 3 || ppsrVM.consecutiveConnectionFailures >= 3
        case .none: false
        }
    }

    var failureStreakMessage: String {
        switch activeMode {
        case .login:
            if loginVM.consecutiveConnectionFailures >= 3 {
                return "3+ connection failures — consider switching network mode or pausing."
            }
            return "Multiple unusual failures detected — check stealth settings."
        case .ppsr:
            if ppsrVM.consecutiveConnectionFailures >= 3 {
                return "3+ connection failures — check proxy/VPN or pause the batch."
            }
            return "Multiple failures — review network and stealth settings."
        case .none:
            return ""
        }
    }

    var networkModeLabel: String {
        switch activeMode {
        case .login:
            if loginVM.stealthEnabled { return "Stealth" }
            return "Standard"
        case .ppsr:
            if ppsrVM.stealthEnabled { return "Stealth" }
            return "Standard"
        case .none: return "--"
        }
    }

    func pauseQueue() {
        switch activeMode {
        case .login: loginVM.pauseQueue()
        case .ppsr: ppsrVM.pauseQueue()
        case .none: break
        }
    }

    func resumeQueue() {
        switch activeMode {
        case .login: loginVM.resumeQueue()
        case .ppsr: ppsrVM.resumeQueue()
        case .none: break
        }
    }

    func stopQueue() {
        switch activeMode {
        case .login: loginVM.stopQueue()
        case .ppsr: ppsrVM.stopQueue()
        case .none: break
        }
    }

    func navigateToActiveMode() {
        switch activeMode {
        case .login:
            UserDefaults.standard.set(ActiveAppMode.unifiedSession.rawValue, forKey: "activeAppMode")
        case .ppsr:
            UserDefaults.standard.set(ActiveAppMode.ppsr.rawValue, forKey: "activeAppMode")
        case .none: break
        }
    }
}

struct ActiveSessionItem: Identifiable {
    let id: String
    let label: String
    let statusText: String
    let statusIcon: String
    let elapsed: String
    let progress: Double
    let isActive: Bool
}

struct RecentFailureItem: Identifiable {
    let id: String
    let label: String
    let reason: String
    let resultStatus: String
}
