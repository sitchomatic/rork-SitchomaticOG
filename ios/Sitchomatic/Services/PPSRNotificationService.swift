import Foundation
import UserNotifications

@MainActor
class PPSRNotificationService {
    static let shared = PPSRNotificationService()

    private var isAuthorized: Bool = false

    func requestPermission() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                isAuthorized = granted
            } catch {
                isAuthorized = false
            }
        }
    }

    func sendConnectionFailure(detail: String) {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Connection Failure"
        content.body = detail
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func sendBatchComplete(working: Int, dead: Int, requeued: Int) {
        guard isAuthorized else { return }
        let total = working + dead + requeued
        let pct = total > 0 ? Int(Double(working) / Double(total) * 100) : 0
        let content = UNMutableNotificationContent()
        content.title = "Batch Complete"
        content.body = "\(working) alive (\(pct)%), \(dead) dead, \(requeued) requeued"
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func sendTestingPausedOrStopped(action: String) {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Testing \(action)"
        content.body = "Queue has been \(action.lowercased()) by user."
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
