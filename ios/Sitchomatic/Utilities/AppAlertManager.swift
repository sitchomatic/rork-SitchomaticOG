import Foundation
import Observation
import SwiftUI

nonisolated enum AppAlertSeverity: String, Sendable {
    case info
    case warning
    case critical
}

nonisolated enum AppAlertSource: String, Sendable {
    case proxy
    case vpn
    case wireProxy
    case automation
    case network
    case webView
    case system
}

struct AppAlert: Identifiable {
    let id: UUID = UUID()
    let timestamp: Date = Date()
    let severity: AppAlertSeverity
    let source: AppAlertSource
    let title: String
    let message: String
    let retryAction: (@MainActor () async -> Void)?
    var isDismissed: Bool = false

    init(severity: AppAlertSeverity, source: AppAlertSource, title: String, message: String, retryAction: (@MainActor () async -> Void)? = nil) {
        self.severity = severity
        self.source = source
        self.title = title
        self.message = message
        self.retryAction = retryAction
    }
}

@Observable
@MainActor
final class AppAlertManager {
    static let shared = AppAlertManager()

    private(set) var alerts: [AppAlert] = []
    private let maxAlerts: Int = 50

    var activeAlerts: [AppAlert] {
        alerts.filter { !$0.isDismissed }
    }

    var hasActiveAlerts: Bool {
        alerts.contains { !$0.isDismissed }
    }

    var latestAlert: AppAlert? {
        activeAlerts.first
    }

    func push(_ alert: AppAlert) {
        alerts.insert(alert, at: 0)
        if alerts.count > maxAlerts {
            alerts.removeLast(alerts.count - maxAlerts)
        }
    }

    func pushInfo(source: AppAlertSource, title: String, message: String) {
        push(AppAlert(severity: .info, source: source, title: title, message: message))
    }

    func pushWarning(source: AppAlertSource, title: String, message: String, retryAction: (@MainActor () async -> Void)? = nil) {
        push(AppAlert(severity: .warning, source: source, title: title, message: message, retryAction: retryAction))
    }

    func pushCritical(source: AppAlertSource, title: String, message: String, retryAction: (@MainActor () async -> Void)? = nil) {
        push(AppAlert(severity: .critical, source: source, title: title, message: message, retryAction: retryAction))
    }

    func dismiss(_ alertId: UUID) {
        if let idx = alerts.firstIndex(where: { $0.id == alertId }) {
            alerts[idx].isDismissed = true
        }
    }

    func dismissAll() {
        for i in alerts.indices {
            alerts[i].isDismissed = true
        }
    }

    func clearAll() {
        alerts.removeAll()
    }
}
