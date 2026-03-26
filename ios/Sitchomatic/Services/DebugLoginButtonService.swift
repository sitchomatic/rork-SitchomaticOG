import Foundation
import UIKit
import WebKit

@MainActor
class DebugLoginButtonService {
    static let shared = DebugLoginButtonService()

    private let persistKey = "debug_login_button_configs_v1"
    private let logger = DebugLogger.shared
    private(set) var configs: [String: DebugLoginButtonConfig] = [:]

    var onAttemptUpdate: ((DebugClickAttempt) -> Void)?
    var onLog: ((String, PPSRLogEntry.Level) -> Void)?
    var isRunning: Bool = false
    var currentAttemptIndex: Int = 0
    var totalMethods: Int { DebugClickJSFactory.allTextBasedMethods().count }
    var shouldStop: Bool = false

    init() {
        load()
    }

    // MARK: - Config Lookup

    func configFor(url: String) -> DebugLoginButtonConfig? {
        let host = extractHost(from: url)
        if let exact = configs[host] { return exact }
        for (key, config) in configs {
            if host.contains(key) || key.contains(host) { return config }
        }
        return nil
    }

    func hasSuccessfulMethod(for url: String) -> Bool {
        configFor(url: url)?.successfulMethod != nil
    }

    func saveConfig(_ config: DebugLoginButtonConfig, forURL url: String) {
        let host = extractHost(from: url)
        configs[host] = config
        persist()
        logger.log("DebugLoginButton: saved config for \(host) — method: \(config.successfulMethod?.methodName ?? "none")", category: .automation, level: .success)
    }

    func deleteConfig(forURL url: String) {
        let host = extractHost(from: url)
        configs.removeValue(forKey: host)
        persist()
    }

    func cloneConfig(from sourceURL: String, to targetURLs: [String]) {
        guard let source = configFor(url: sourceURL) else { return }
        for target in targetURLs {
            let host = extractHost(from: target)
            var copy = source
            copy.id = UUID().uuidString
            copy.urlPattern = host
            copy.userConfirmed = false
            copy.testedAt = Date()
            configs[host] = copy
        }
        persist()
        onLog?("Cloned login button config from \(extractHost(from: sourceURL)) to \(targetURLs.count) URLs", .success)
    }

    // MARK: - Full Debug Scan

    func runFullDebugScan(
        session: LoginSiteWebSession,
        targetURL: URL,
        buttonLocation: DebugLoginButtonConfig.ButtonLocation?
    ) async -> [DebugClickAttempt] {
        isRunning = true
        shouldStop = false
        currentAttemptIndex = 0

        let urlString = targetURL.absoluteString
        let host = extractHost(from: urlString)

        let textMethods = DebugClickJSFactory.allTextBasedMethods()
        let locationMethods: [DebugClickJSFactory.ClickMethod]
        if let loc = buttonLocation {
            locationMethods = DebugClickJSFactory.locationBasedMethods(cx: Int(loc.absoluteX), cy: Int(loc.absoluteY))
        } else {
            locationMethods = []
        }
        let allMethods = textMethods + locationMethods

        logger.log("DebugLoginButton: starting full scan with \(allMethods.count) methods for \(host)", category: .automation, level: .info)
        onLog?("Starting Debug Login Button scan: \(allMethods.count) methods to try", .info)

        let preContent = await session.getPageContent()
        let preURL = await session.getCurrentURL()
        var attempts: [DebugClickAttempt] = []

        for (index, method) in allMethods.enumerated() {
            if shouldStop { break }

            currentAttemptIndex = index
            var attempt = DebugClickAttempt(
                index: index,
                methodName: method.name,
                jsSnippet: String(method.js.prefix(200))
            )
            attempt.status = .running
            onAttemptUpdate?(attempt)

            logger.log("DebugLoginButton: [\(index + 1)/\(allMethods.count)] trying '\(method.name)'", category: .automation, level: .debug)

            let startTime = Date()

            await session.dismissCookieNotices()
            try? await Task.sleep(for: .milliseconds(100))

            let result = await session.executeJS(method.js)
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)

            attempt.durationMs = elapsed
            attempt.resultDetail = result ?? "nil"

            try? await Task.sleep(for: .milliseconds(500))

            let postContent = await session.getPageContent()
            let postURL = await session.getCurrentURL()
            let contentChanged = postContent != preContent
            let urlChanged = postURL != preURL
            let buttonStateChanged = await checkButtonStateChanged(session: session)

            let autoDetectedSuccess = contentChanged || urlChanged || buttonStateChanged ||
                (result?.contains("CLICKED") == true || result?.contains("OK") == true || result?.contains("CONFIRMED") == true)

            if autoDetectedSuccess {
                attempt.status = .success
                attempt.resultDetail += " | content_changed=\(contentChanged) url_changed=\(urlChanged) btn_state=\(buttonStateChanged)"

                logger.log("DebugLoginButton: AUTO-DETECTED SUCCESS with '\(method.name)' — \(attempt.resultDetail)", category: .automation, level: .success)
                onLog?("AUTO-DETECTED: '\(method.name)' appears to have worked!", .success)

                var config = configs[host] ?? DebugLoginButtonConfig(urlPattern: host)
                config.successfulMethod = DebugLoginButtonConfig.ClickMethodResult(
                    methodName: method.name,
                    methodIndex: index,
                    jsCode: method.js,
                    resultDetail: attempt.resultDetail,
                    responseTimeMs: elapsed
                )
                config.buttonLocation = buttonLocation
                config.totalAttempts = index + 1
                config.successfulAttemptIndex = index
                config.testedAt = Date()
                saveConfig(config, forURL: urlString)
            } else {
                attempt.status = .failed
                logger.log("DebugLoginButton: [\(index + 1)] '\(method.name)' — no effect detected", category: .automation, level: .trace)
            }

            attempts.append(attempt)
            onAttemptUpdate?(attempt)

            if autoDetectedSuccess { break }

            if index < allMethods.count - 1 {
                try? await Task.sleep(for: .milliseconds(300))
                if contentChanged || urlChanged {
                    logger.log("DebugLoginButton: page changed, reloading before next attempt", category: .automation, level: .debug)
                    let reloaded = await session.loadPage(timeout: AutomationSettings.minimumTimeoutSeconds)
                    if !reloaded { break }
                    try? await Task.sleep(for: .milliseconds(1000))
                }
            }
        }

        isRunning = false
        currentAttemptIndex = 0

        let successCount = attempts.filter { $0.status == .success || $0.status == .userConfirmed }.count
        logger.log("DebugLoginButton: scan complete — \(attempts.count) tried, \(successCount) detected success", category: .automation, level: successCount > 0 ? .success : .warning)
        onLog?("Debug scan complete: \(attempts.count) methods tried, \(successCount) possible successes", successCount > 0 ? .success : .warning)

        return attempts
    }

    // MARK: - User Confirmation & Replay

    func confirmUserSuccess(attempt: DebugClickAttempt, session: LoginSiteWebSession, targetURL: URL, buttonLocation: DebugLoginButtonConfig.ButtonLocation?) {
        let urlString = targetURL.absoluteString
        let host = extractHost(from: urlString)

        let allMethods = DebugClickJSFactory.allTextBasedMethods()
        let locMethods: [DebugClickJSFactory.ClickMethod]
        if let loc = buttonLocation {
            locMethods = DebugClickJSFactory.locationBasedMethods(cx: Int(loc.absoluteX), cy: Int(loc.absoluteY))
        } else {
            locMethods = []
        }
        let method = (allMethods + locMethods).first { $0.name == attempt.methodName }

        var config = configs[host] ?? DebugLoginButtonConfig(urlPattern: host)
        config.successfulMethod = DebugLoginButtonConfig.ClickMethodResult(
            methodName: attempt.methodName,
            methodIndex: attempt.index,
            jsCode: method?.js ?? "",
            resultDetail: "USER CONFIRMED: \(attempt.resultDetail)",
            responseTimeMs: attempt.durationMs
        )
        config.buttonLocation = buttonLocation
        config.totalAttempts = attempt.index + 1
        config.successfulAttemptIndex = attempt.index
        config.userConfirmed = true
        config.testedAt = Date()
        saveConfig(config, forURL: urlString)

        logger.log("DebugLoginButton: USER CONFIRMED '\(attempt.methodName)' for \(host)", category: .automation, level: .success)
        onLog?("User confirmed: '\(attempt.methodName)' saved for \(host)", .success)
    }

    func replaySuccessfulMethod(session: LoginSiteWebSession, url: String) async -> (success: Bool, detail: String) {
        guard let config = configFor(url: url), let method = config.successfulMethod else {
            return (false, "No saved debug login button method for this URL")
        }

        logger.log("DebugLoginButton: replaying '\(method.methodName)' for \(extractHost(from: url))", category: .automation, level: .info)

        let result = await session.executeJS(method.jsCode)
        let success = result != nil && result?.contains("NOT_FOUND") != true && result?.contains("NO_ELEMENT") != true

        if success {
            logger.log("DebugLoginButton: replay SUCCESS — \(result ?? "")", category: .automation, level: .success)
        } else {
            logger.log("DebugLoginButton: replay FAILED — \(result ?? "nil")", category: .automation, level: .warning)
        }

        return (success, "DebugBtn replay '\(method.methodName)': \(result ?? "nil")")
    }

    func stop() {
        shouldStop = true
    }

    // MARK: - Button State Detection

    private func checkButtonStateChanged(session: LoginSiteWebSession) async -> Bool {
        let result = await session.executeJS(DebugClickJSFactory.buttonStateCheckJS)
        return result?.hasPrefix("CHANGED") == true
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: persistKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let decoded = try? JSONDecoder().decode([String: DebugLoginButtonConfig].self, from: data) else { return }
        configs = decoded
    }

    private func extractHost(from url: String) -> String {
        URL(string: url)?.host ?? url
    }
}
