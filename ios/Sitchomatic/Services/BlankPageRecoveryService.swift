import Foundation
import UIKit
import WebKit

@MainActor
class BlankPageRecoveryService {
    static let shared = BlankPageRecoveryService()

    private let logger = DebugLogger.shared

    nonisolated enum RecoveryStep: String, Sendable {
        case waitAndRecheck = "Wait & Recheck"
        case changeURL = "Change URL"
        case changeDNS = "Change DNS"
        case changeFingerprint = "Change Fingerprint"
        case fullSessionReset = "Full Session Reset"
    }

    nonisolated struct RecoveryResult: Sendable {
        let recovered: Bool
        let stepUsed: RecoveryStep?
        let detail: String
        let attemptsUsed: Int
    }

    private func cancellationSafeSleep(milliseconds ms: Int) async {
        let start = Date()
        let target = TimeInterval(ms) / 1000.0
        while Date().timeIntervalSince(start) < target {
            let remaining = target - Date().timeIntervalSince(start)
            let chunk = min(remaining, 0.5)
            guard chunk > 0 else { break }
            do {
                try await Task.sleep(for: .seconds(chunk))
            } catch {
                let elapsed = Date().timeIntervalSince(start)
                if elapsed < target {
                    let spinEnd = start.addingTimeInterval(target)
                    while Date() < spinEnd {
                        try? await Task.sleep(for: .milliseconds(50))
                        if Date().timeIntervalSince(start) >= target { break }
                        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    }
                }
                return
            }
        }
    }

    private func cancellationSafeSleepSeconds(_ seconds: Int) async {
        await cancellationSafeSleep(milliseconds: seconds * 1000)
    }

    func waitForNonBlankLoginSession(
        session: LoginSiteWebSession,
        timeoutSeconds: Int = 20,
        sessionId: String,
        onLog: ((String, PPSRLogEntry.Level) -> Void)?
    ) async -> Bool {
        let start = Date()
        let maxWait = TimeInterval(timeoutSeconds)
        var checkCount = 0
        let pollIntervalMs = 2000

        while Date().timeIntervalSince(start) < maxWait {
            checkCount += 1
            if let screenshot = await session.captureScreenshot(), !BlankScreenshotDetector.isBlank(screenshot) {
                logger.log("BlankPageTimeout: page appeared after \(checkCount) checks (\(String(format: "%.1f", Date().timeIntervalSince(start)))s)", category: .automation, level: .success, sessionId: sessionId)
                return true
            }
            let elapsed = Int(Date().timeIntervalSince(start))
            onLog?("Blank page timeout: still blank after \(elapsed)s (check \(checkCount))...", .info)
            await cancellationSafeSleep(milliseconds: pollIntervalMs)
        }

        logger.log("BlankPageTimeout: page still blank after \(timeoutSeconds)s (\(checkCount) checks)", category: .automation, level: .error, sessionId: sessionId)
        onLog?("BLANK PAGE TIMEOUT: page remained blank for \(timeoutSeconds)s", .error)
        return false
    }

    func waitForNonBlankPPSRSession(
        session: LoginWebSession,
        timeoutSeconds: Int = 20,
        sessionId: String,
        onLog: ((String, PPSRLogEntry.Level) -> Void)?
    ) async -> Bool {
        let start = Date()
        let maxWait = TimeInterval(timeoutSeconds)
        var checkCount = 0
        let pollIntervalMs = 2000

        while Date().timeIntervalSince(start) < maxWait {
            checkCount += 1
            if let screenshot = await session.captureScreenshotWithCrop(cropRect: nil).full, !BlankScreenshotDetector.isBlank(screenshot) {
                logger.log("BlankPageTimeout(PPSR): page appeared after \(checkCount) checks (\(String(format: "%.1f", Date().timeIntervalSince(start)))s)", category: .automation, level: .success, sessionId: sessionId)
                return true
            }
            let elapsed = Int(Date().timeIntervalSince(start))
            onLog?("Blank page timeout: still blank after \(elapsed)s (check \(checkCount))...", .info)
            await cancellationSafeSleep(milliseconds: pollIntervalMs)
        }

        logger.log("BlankPageTimeout(PPSR): page still blank after \(timeoutSeconds)s (\(checkCount) checks)", category: .automation, level: .error, sessionId: sessionId)
        onLog?("BLANK PAGE TIMEOUT: page remained blank for \(timeoutSeconds)s", .error)
        return false
    }

    func attemptRecoveryForLoginSession(
        session: LoginSiteWebSession,
        settings: AutomationSettings,
        proxyTarget: ProxyRotationService.ProxyTarget,
        sessionId: String,
        onLog: ((String, PPSRLogEntry.Level) -> Void)?
    ) async -> RecoveryResult {
        guard settings.blankPageRecoveryEnabled else {
            return RecoveryResult(recovered: false, stepUsed: nil, detail: "Blank page recovery disabled", attemptsUsed: 0)
        }

        let steps = buildFallbackChain(settings: settings)
        guard !steps.isEmpty else {
            return RecoveryResult(recovered: false, stepUsed: nil, detail: "No fallback steps enabled", attemptsUsed: 0)
        }

        logger.log("BlankPageRecovery: starting fallback chain (\(steps.count) steps) for session \(sessionId)", category: .automation, level: .info, sessionId: sessionId)
        onLog?("BLANK PAGE RECOVERY: starting \(steps.count)-step fallback chain...", .warning)

        var attemptCount = 0

        for step in steps {
            if Task.isCancelled {
                logger.log("BlankPageRecovery: task cancelled — aborting recovery chain at step \(attemptCount)", category: .automation, level: .warning, sessionId: sessionId)
                onLog?("Recovery cancelled by parent task", .warning)
                return RecoveryResult(recovered: false, stepUsed: nil, detail: "Cancelled by parent task", attemptsUsed: attemptCount)
            }

            attemptCount += 1
            if attemptCount > settings.blankPageMaxFallbackAttempts { break }

            if attemptCount > 1 {
                logger.log("BlankPageRecovery: cooldown before step \(attemptCount)", category: .automation, level: .debug, sessionId: sessionId)
                await cancellationSafeSleepSeconds(2)
            }

            logger.log("BlankPageRecovery: step \(attemptCount)/\(steps.count) — \(step.rawValue)", category: .automation, level: .info, sessionId: sessionId)
            onLog?("Recovery step \(attemptCount): \(step.rawValue)...", .info)

            switch step {
            case .waitAndRecheck:
                let recovered = await performWaitAndRecheck(
                    session: session,
                    recheckIntervalMs: settings.blankPageRecheckIntervalMs,
                    totalWaitSeconds: settings.blankPageWaitThresholdSeconds,
                    sessionId: sessionId,
                    onLog: onLog
                )
                if recovered {
                    onLog?("Recovery SUCCESS on step \(attemptCount): page loaded after extended wait", .success)
                    return RecoveryResult(recovered: true, stepUsed: .waitAndRecheck, detail: "Page loaded after extended wait", attemptsUsed: attemptCount)
                }

            case .changeURL:
                let recovered = await performChangeURL(
                    session: session,
                    proxyTarget: proxyTarget,
                    settings: settings,
                    sessionId: sessionId,
                    onLog: onLog
                )
                if recovered {
                    onLog?("Recovery SUCCESS on step \(attemptCount): loaded after URL change", .success)
                    return RecoveryResult(recovered: true, stepUsed: .changeURL, detail: "Loaded after URL rotation", attemptsUsed: attemptCount)
                }

            case .changeDNS:
                let recovered = await performChangeDNS(
                    session: session,
                    settings: settings,
                    sessionId: sessionId,
                    onLog: onLog
                )
                if recovered {
                    onLog?("Recovery SUCCESS on step \(attemptCount): loaded after DNS change", .success)
                    return RecoveryResult(recovered: true, stepUsed: .changeDNS, detail: "Loaded after DNS rotation", attemptsUsed: attemptCount)
                }

            case .changeFingerprint:
                let recovered = await performChangeFingerprint(
                    session: session,
                    sessionId: sessionId,
                    onLog: onLog
                )
                if recovered {
                    onLog?("Recovery SUCCESS on step \(attemptCount): loaded after fingerprint change", .success)
                    return RecoveryResult(recovered: true, stepUsed: .changeFingerprint, detail: "Loaded after fingerprint rotation", attemptsUsed: attemptCount)
                }

            case .fullSessionReset:
                let recovered = await performFullSessionReset(
                    session: session,
                    settings: settings,
                    sessionId: sessionId,
                    onLog: onLog
                )
                if recovered {
                    onLog?("Recovery SUCCESS on step \(attemptCount): loaded after full session reset", .success)
                    return RecoveryResult(recovered: true, stepUsed: .fullSessionReset, detail: "Loaded after full session + network reset", attemptsUsed: attemptCount)
                }
            }
        }

        onLog?("BLANK PAGE RECOVERY FAILED after \(attemptCount) steps — all fallbacks exhausted", .error)
        logger.log("BlankPageRecovery: ALL FALLBACKS EXHAUSTED after \(attemptCount) steps", category: .automation, level: .error, sessionId: sessionId)
        return RecoveryResult(recovered: false, stepUsed: nil, detail: "All \(attemptCount) fallback steps exhausted", attemptsUsed: attemptCount)
    }

    func attemptRecoveryForPPSRSession(
        session: LoginWebSession,
        settings: AutomationSettings,
        sessionId: String,
        onLog: ((String, PPSRLogEntry.Level) -> Void)?
    ) async -> RecoveryResult {
        guard settings.blankPageRecoveryEnabled else {
            return RecoveryResult(recovered: false, stepUsed: nil, detail: "Blank page recovery disabled", attemptsUsed: 0)
        }

        let steps = buildFallbackChain(settings: settings)
        guard !steps.isEmpty else {
            return RecoveryResult(recovered: false, stepUsed: nil, detail: "No fallback steps enabled", attemptsUsed: 0)
        }

        logger.log("BlankPageRecovery(PPSR): starting fallback chain (\(steps.count) steps)", category: .automation, level: .info, sessionId: sessionId)
        onLog?("BLANK PAGE RECOVERY: starting \(steps.count)-step fallback chain...", .warning)

        var attemptCount = 0

        for step in steps {
            if Task.isCancelled {
                logger.log("BlankPageRecovery(PPSR): task cancelled — aborting", category: .automation, level: .warning, sessionId: sessionId)
                return RecoveryResult(recovered: false, stepUsed: nil, detail: "Cancelled by parent task", attemptsUsed: attemptCount)
            }

            attemptCount += 1
            if attemptCount > settings.blankPageMaxFallbackAttempts { break }

            if attemptCount > 1 {
                await cancellationSafeSleepSeconds(2)
            }

            logger.log("BlankPageRecovery(PPSR): step \(attemptCount)/\(steps.count) — \(step.rawValue)", category: .automation, level: .info, sessionId: sessionId)
            onLog?("Recovery step \(attemptCount): \(step.rawValue)...", .info)

            switch step {
            case .waitAndRecheck:
                let recovered = await performWaitAndRecheckPPSR(
                    session: session,
                    recheckIntervalMs: settings.blankPageRecheckIntervalMs,
                    totalWaitSeconds: settings.blankPageWaitThresholdSeconds,
                    sessionId: sessionId,
                    onLog: onLog
                )
                if recovered {
                    onLog?("Recovery SUCCESS: page loaded after extended wait", .success)
                    return RecoveryResult(recovered: true, stepUsed: .waitAndRecheck, detail: "Page loaded after extended wait", attemptsUsed: attemptCount)
                }

            case .changeURL:
                onLog?("Recovery: URL change not applicable for PPSR (fixed URL) — skipping", .info)

            case .changeDNS:
                let recovered = await performChangeDNSPPSR(
                    session: session,
                    settings: settings,
                    sessionId: sessionId,
                    onLog: onLog
                )
                if recovered {
                    onLog?("Recovery SUCCESS: loaded after DNS change", .success)
                    return RecoveryResult(recovered: true, stepUsed: .changeDNS, detail: "Loaded after DNS rotation", attemptsUsed: attemptCount)
                }

            case .changeFingerprint:
                let recovered = await performChangeFingerprintPPSR(
                    session: session,
                    sessionId: sessionId,
                    onLog: onLog
                )
                if recovered {
                    onLog?("Recovery SUCCESS: loaded after fingerprint change", .success)
                    return RecoveryResult(recovered: true, stepUsed: .changeFingerprint, detail: "Loaded after fingerprint rotation", attemptsUsed: attemptCount)
                }

            case .fullSessionReset:
                let recovered = await performFullSessionResetPPSR(
                    session: session,
                    settings: settings,
                    sessionId: sessionId,
                    onLog: onLog
                )
                if recovered {
                    onLog?("Recovery SUCCESS: loaded after full session reset", .success)
                    return RecoveryResult(recovered: true, stepUsed: .fullSessionReset, detail: "Loaded after full session reset", attemptsUsed: attemptCount)
                }
            }
        }

        onLog?("BLANK PAGE RECOVERY FAILED after \(attemptCount) steps", .error)
        return RecoveryResult(recovered: false, stepUsed: nil, detail: "All \(attemptCount) fallback steps exhausted", attemptsUsed: attemptCount)
    }

    // MARK: - Fallback Chain Builder

    private func buildFallbackChain(settings: AutomationSettings) -> [RecoveryStep] {
        var steps: [RecoveryStep] = []
        if settings.blankPageFallback1_WaitAndRecheck { steps.append(.waitAndRecheck) }
        if settings.blankPageFallback2_ChangeURL { steps.append(.changeURL) }
        if settings.blankPageFallback3_ChangeDNS { steps.append(.changeDNS) }
        if settings.blankPageFallback4_ChangeFingerprint { steps.append(.changeFingerprint) }
        if settings.blankPageFallback5_FullSessionReset { steps.append(.fullSessionReset) }
        return steps
    }

    // MARK: - Login Session Fallbacks

    private func performWaitAndRecheck(
        session: LoginSiteWebSession,
        recheckIntervalMs: Int,
        totalWaitSeconds: Int,
        sessionId: String,
        onLog: ((String, PPSRLogEntry.Level) -> Void)?
    ) async -> Bool {
        let start = Date()
        let maxWait = TimeInterval(totalWaitSeconds)
        var checkCount = 0
        let safeInterval = max(recheckIntervalMs, 500)

        while Date().timeIntervalSince(start) < maxWait {
            if Task.isCancelled { return false }
            await cancellationSafeSleep(milliseconds: safeInterval)
            checkCount += 1

            if let screenshot = await session.captureScreenshot(), !BlankScreenshotDetector.isBlank(screenshot) {
                logger.log("BlankPageRecovery: page appeared after \(checkCount) rechecks (\(String(format: "%.1f", Date().timeIntervalSince(start)))s)", category: .automation, level: .success, sessionId: sessionId)
                return true
            }

            let elapsed = Int(Date().timeIntervalSince(start))
            onLog?("Still blank after \(elapsed)s (check \(checkCount))...", .info)
        }

        logger.log("BlankPageRecovery: waitAndRecheck exhausted (\(totalWaitSeconds)s, \(checkCount) checks)", category: .automation, level: .warning, sessionId: sessionId)
        return false
    }

    private func performChangeURL(
        session: LoginSiteWebSession,
        proxyTarget: ProxyRotationService.ProxyTarget,
        settings: AutomationSettings,
        sessionId: String,
        onLog: ((String, PPSRLogEntry.Level) -> Void)?
    ) async -> Bool {
        let urlService = LoginURLRotationService.shared
        urlService.isIgnitionMode = (proxyTarget == .ignition)

        guard let targetURL = urlService.nextURL() else {
            onLog?("No alternate URL available for rotation", .warning)
            return false
        }

        onLog?("Rotating to URL: \(targetURL.host ?? targetURL.absoluteString)", .info)
        logger.log("BlankPageRecovery: rotating URL to \(targetURL.absoluteString)", category: .automation, level: .info, sessionId: sessionId)

        session.targetURL = targetURL
        let loaded = await session.loadPage(timeout: settings.pageLoadTimeout)
        guard loaded else { return false }

        await cancellationSafeSleepSeconds(3)

        if let screenshot = await session.captureScreenshot(), !BlankScreenshotDetector.isBlank(screenshot) {
            return true
        }
        return false
    }

    private func performChangeDNS(
        session: LoginSiteWebSession,
        settings: AutomationSettings,
        sessionId: String,
        onLog: ((String, PPSRLogEntry.Level) -> Void)?
    ) async -> Bool {
        let dohService = PPSRDoHService.shared
        let newProvider = dohService.nextProvider()
        onLog?("Rotated DNS to: \(newProvider.name)", .info)
        logger.log("BlankPageRecovery: rotated DNS to \(newProvider.name)", category: .dns, level: .info, sessionId: sessionId)

        let loaded = await session.loadPage(timeout: settings.pageLoadTimeout)
        guard loaded else { return false }

        await cancellationSafeSleepSeconds(3)

        if let screenshot = await session.captureScreenshot(), !BlankScreenshotDetector.isBlank(screenshot) {
            return true
        }
        return false
    }

    private func performChangeFingerprint(
        session: LoginSiteWebSession,
        sessionId: String,
        onLog: ((String, PPSRLogEntry.Level) -> Void)?
    ) async -> Bool {
        let stealth = PPSRStealthService.shared
        let newProfile = stealth.nextProfile()
        session.webView?.customUserAgent = newProfile.userAgent

        let newJS = stealth.createStealthUserScript(profile: newProfile)
        session.webView?.configuration.userContentController.removeAllUserScripts()
        session.webView?.configuration.userContentController.addUserScript(newJS)

        onLog?("Rotated fingerprint profile (seed: \(newProfile.seed))", .info)
        logger.log("BlankPageRecovery: rotated fingerprint to seed \(newProfile.seed)", category: .stealth, level: .info, sessionId: sessionId)

        let loaded = await session.loadPage(timeout: AutomationSettings.minimumTimeoutSeconds)
        guard loaded else { return false }

        await cancellationSafeSleepSeconds(3)

        if let screenshot = await session.captureScreenshot(), !BlankScreenshotDetector.isBlank(screenshot) {
            return true
        }
        return false
    }

    private func performFullSessionReset(
        session: LoginSiteWebSession,
        settings: AutomationSettings,
        sessionId: String,
        onLog: ((String, PPSRLogEntry.Level) -> Void)?
    ) async -> Bool {
        if Task.isCancelled {
            logger.log("BlankPageRecovery: skipping full session reset — task cancelled", category: .automation, level: .warning, sessionId: sessionId)
            return false
        }

        onLog?("Full session reset: tearing down and rebuilding WebView + network...", .info)
        logger.log("BlankPageRecovery: performing full session reset", category: .automation, level: .info, sessionId: sessionId)

        let networkFactory = NetworkSessionFactory.shared
        let newConfig = networkFactory.appWideConfig(for: session.proxyTarget)
        session.networkConfig = newConfig

        session.tearDown(wipeAll: true)

        await cancellationSafeSleepSeconds(1)

        session.stealthEnabled = true
        session.setUp(wipeAll: true)

        await cancellationSafeSleep(milliseconds: 500)

        onLog?("Session rebuilt with network: \(newConfig.label)", .info)

        let loaded = await session.loadPage(timeout: settings.pageLoadTimeout)
        guard loaded else { return false }

        await cancellationSafeSleepSeconds(4)

        if let screenshot = await session.captureScreenshot(), !BlankScreenshotDetector.isBlank(screenshot) {
            return true
        }
        return false
    }

    // MARK: - PPSR Session Fallbacks

    private func performWaitAndRecheckPPSR(
        session: LoginWebSession,
        recheckIntervalMs: Int,
        totalWaitSeconds: Int,
        sessionId: String,
        onLog: ((String, PPSRLogEntry.Level) -> Void)?
    ) async -> Bool {
        let start = Date()
        let maxWait = TimeInterval(totalWaitSeconds)
        var checkCount = 0
        let safeInterval = max(recheckIntervalMs, 500)

        while Date().timeIntervalSince(start) < maxWait {
            if Task.isCancelled { return false }
            await cancellationSafeSleep(milliseconds: safeInterval)
            checkCount += 1

            if let screenshot = await session.captureScreenshotWithCrop(cropRect: nil).full, !BlankScreenshotDetector.isBlank(screenshot) {
                logger.log("BlankPageRecovery(PPSR): page appeared after \(checkCount) rechecks", category: .automation, level: .success, sessionId: sessionId)
                return true
            }

            let elapsed = Int(Date().timeIntervalSince(start))
            onLog?("Still blank after \(elapsed)s (check \(checkCount))...", .info)
        }

        return false
    }

    private func performChangeDNSPPSR(
        session: LoginWebSession,
        settings: AutomationSettings,
        sessionId: String,
        onLog: ((String, PPSRLogEntry.Level) -> Void)?
    ) async -> Bool {
        let dohService = PPSRDoHService.shared
        let newProvider = dohService.nextProvider()
        onLog?("Rotated DNS to: \(newProvider.name)", .info)
        logger.log("BlankPageRecovery(PPSR): rotated DNS to \(newProvider.name)", category: .dns, level: .info, sessionId: sessionId)

        let loaded = await session.loadPage(timeout: AutomationSettings.minimumTimeoutSeconds)
        guard loaded else { return false }

        await cancellationSafeSleepSeconds(3)

        if let screenshot = await session.captureScreenshotWithCrop(cropRect: nil).full, !BlankScreenshotDetector.isBlank(screenshot) {
            return true
        }
        return false
    }

    private func performChangeFingerprintPPSR(
        session: LoginWebSession,
        sessionId: String,
        onLog: ((String, PPSRLogEntry.Level) -> Void)?
    ) async -> Bool {
        let stealth = PPSRStealthService.shared
        let newProfile = stealth.nextProfile()

        let newJS = stealth.createStealthUserScript(profile: newProfile)
        session.applyNewStealthProfile(userAgent: newProfile.userAgent, userScript: newJS)

        onLog?("Rotated fingerprint profile (seed: \(newProfile.seed))", .info)
        logger.log("BlankPageRecovery(PPSR): rotated fingerprint to seed \(newProfile.seed)", category: .stealth, level: .info, sessionId: sessionId)

        let loaded = await session.loadPage(timeout: AutomationSettings.minimumTimeoutSeconds)
        guard loaded else { return false }

        await cancellationSafeSleepSeconds(3)

        if let screenshot = await session.captureScreenshotWithCrop(cropRect: nil).full, !BlankScreenshotDetector.isBlank(screenshot) {
            return true
        }
        return false
    }

    private func performFullSessionResetPPSR(
        session: LoginWebSession,
        settings: AutomationSettings,
        sessionId: String,
        onLog: ((String, PPSRLogEntry.Level) -> Void)?
    ) async -> Bool {
        if Task.isCancelled {
            logger.log("BlankPageRecovery(PPSR): skipping full session reset — task cancelled", category: .automation, level: .warning, sessionId: sessionId)
            return false
        }

        onLog?("Full session reset: tearing down and rebuilding WebView...", .info)
        logger.log("BlankPageRecovery(PPSR): performing full session reset", category: .automation, level: .info, sessionId: sessionId)

        let networkFactory = NetworkSessionFactory.shared
        let newConfig = networkFactory.appWideConfig(for: .ppsr)
        session.networkConfig = newConfig

        session.tearDown()

        await cancellationSafeSleepSeconds(1)

        session.stealthEnabled = true
        session.setUp()

        await cancellationSafeSleep(milliseconds: 500)

        onLog?("Session rebuilt with network: \(newConfig.label)", .info)

        let loaded = await session.loadPage(timeout: AutomationSettings.minimumTimeoutSeconds)
        guard loaded else { return false }

        await cancellationSafeSleepSeconds(4)

        if let screenshot = await session.captureScreenshotWithCrop(cropRect: nil).full, !BlankScreenshotDetector.isBlank(screenshot) {
            return true
        }
        return false
    }
}
