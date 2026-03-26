import Foundation
import WebKit

@MainActor
class WebViewPool {
    static let shared = WebViewPool()

    private var inUseCount: Int = 0
    private let logger = DebugLogger.shared
    private(set) var processTerminationCount: Int = 0
    private let networkFactory = NetworkSessionFactory.shared
    private var preWarmedViews: [WKWebView] = []
    private let maxPreWarmed: Int = 3
    private(set) var preWarmCount: Int = 0
    private let hardCapActiveWebViews: Int = 12
    private var leakDetectionTask: Task<Void, Never>?
    private var peakActiveCount: Int = 0
    private var totalCreated: Int = 0
    private var totalReleased: Int = 0
    private var staleSessionReaperTask: Task<Void, Never>?
    private var trackedSessions: [String: TrackedWebView] = [:]
    private let staleSessionTimeoutSeconds: TimeInterval = 300
    private var consecutiveProcessTerminations: Int = 0
    private var lastProcessTerminationTime: Date = .distantPast

    private struct TrackedWebView {
        let id: String
        let createdAt: Date
        weak var webView: WKWebView?
    }

    var activeCount: Int { inUseCount }
    var preWarmedCount: Int { preWarmedViews.count }

    func preWarm(count: Int = 2, stealthEnabled: Bool = true, networkConfig: ActiveNetworkConfig = .direct, target: ProxyRotationService.ProxyTarget = .joe) {
        guard inUseCount + preWarmedViews.count < hardCapActiveWebViews else {
            logger.log("WebViewPool: pre-warm BLOCKED — at hard cap (\(inUseCount) active + \(preWarmedViews.count) pre-warmed >= \(hardCapActiveWebViews))", category: .webView, level: .warning)
            return
        }

        if CrashProtectionService.shared.shouldReduceConcurrency {
            logger.log("WebViewPool: pre-warm SKIPPED — memory pressure active", category: .webView, level: .warning)
            return
        }

        let toCreate = min(count, maxPreWarmed - preWarmedViews.count, hardCapActiveWebViews - inUseCount - preWarmedViews.count)
        guard toCreate > 0 else { return }

        for _ in 0..<toCreate {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.preferences.javaScriptCanOpenWindowsAutomatically = true
            config.defaultWebpagePreferences.allowsContentJavaScript = true

            let _ = networkFactory.configureWKWebView(config: config, networkConfig: networkConfig, target: target)

            let wv: WKWebView
            if stealthEnabled {
                let stealth = PPSRStealthService.shared
                let profile = stealth.nextProfile()
                let userScript = stealth.createStealthUserScript(profile: profile)
                config.userContentController.addUserScript(userScript)
                wv = WKWebView(frame: CGRect(origin: .zero, size: CGSize(width: profile.viewport.width, height: profile.viewport.height)), configuration: config)
                wv.customUserAgent = profile.userAgent
            } else {
                wv = WKWebView(frame: CGRect(origin: .zero, size: CGSize(width: 390, height: 844)), configuration: config)
                wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
            }
            preWarmedViews.append(wv)
        }
        preWarmCount += toCreate
        totalCreated += toCreate
        logger.log("WebViewPool: pre-warmed \(toCreate) WebViews (pool: \(preWarmedViews.count))", category: .webView, level: .info)
    }

    func acquirePreWarmed() -> WKWebView? {
        guard !preWarmedViews.isEmpty else { return nil }
        let wv = preWarmedViews.removeFirst()
        inUseCount += 1
        peakActiveCount = max(peakActiveCount, inUseCount)
        let trackId = "pw_\(UUID().uuidString.prefix(8))"
        trackedSessions[trackId] = TrackedWebView(id: trackId, createdAt: Date(), webView: wv)
        logger.log("WebViewPool: acquired pre-warmed WebView (remaining: \(preWarmedViews.count), active: \(inUseCount))", category: .webView, level: .trace)
        startLeakDetectionIfNeeded()
        startStaleSessionReaperIfNeeded()
        return wv
    }

    func drainPreWarmed() {
        for wv in preWarmedViews {
            wv.stopLoading()
            wv.configuration.userContentController.removeAllUserScripts()
        }
        let count = preWarmedViews.count
        preWarmedViews.removeAll()
        if count > 0 {
            logger.log("WebViewPool: drained \(count) pre-warmed WebViews", category: .webView, level: .debug)
        }
    }

    func acquire(stealthEnabled: Bool = false, viewportSize: CGSize = CGSize(width: 390, height: 844), networkConfig: ActiveNetworkConfig = .direct, target: ProxyRotationService.ProxyTarget = .joe) async -> WKWebView {
        if CrashProtectionService.shared.isMemoryEmergency {
            logger.log("WebViewPool: memory EMERGENCY before acquire — draining all and forcing cleanup", category: .webView, level: .critical)
            drainPreWarmed()
            reapStaleSessions()
            reapDeallocatedSessions()
            URLCache.shared.removeAllCachedResponses()
            let recovered = await CrashProtectionService.shared.waitForMemoryToDrop(timeout: 15)
            if !recovered {
                logger.log("WebViewPool: memory still emergency after 15s wait — proceeding with extreme caution", category: .webView, level: .critical)
            }
        } else if CrashProtectionService.shared.isMemoryCritical {
            logger.log("WebViewPool: memory CRITICAL before acquire — draining pre-warmed and reaping stale", category: .webView, level: .critical)
            drainPreWarmed()
            reapStaleSessions()
            reapDeallocatedSessions()
            let recovered = await CrashProtectionService.shared.waitForMemoryToDrop(timeout: 10)
            if !recovered {
                logger.log("WebViewPool: memory still critical after 10s wait — proceeding cautiously", category: .webView, level: .critical)
            }
        } else if !CrashProtectionService.shared.isMemorySafeForNewSession {
            logger.log("WebViewPool: memory HIGH before acquire — trying pre-warmed first", category: .webView, level: .warning)
            if let preWarmed = acquirePreWarmed() {
                return preWarmed
            }
            let _ = await CrashProtectionService.shared.waitForMemoryToDrop(timeout: 5)
        }

        if inUseCount >= hardCapActiveWebViews {
            logger.log("WebViewPool: HARD CAP reached (\(inUseCount)/\(hardCapActiveWebViews)) — waiting for release before creating new WebView", category: .webView, level: .critical)

            reapStaleSessions()

            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(500))
                if inUseCount < hardCapActiveWebViews { break }
            }
            if inUseCount >= hardCapActiveWebViews {
                logger.log("WebViewPool: HARD CAP still reached after 15s wait — force-draining pre-warmed and proceeding", category: .webView, level: .critical)
                drainPreWarmed()

                reapDeallocatedSessions()
            }
        }

        var effectiveConfig = networkConfig
        if case .socks5 = networkFactory.resolveEffectiveConfigPublic(networkConfig) {
            effectiveConfig = await networkFactory.preflightProxyCheck(for: networkConfig, target: target)
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let proxyApplied = networkFactory.configureWKWebView(config: config, networkConfig: effectiveConfig, target: target)
        if !proxyApplied {
            logger.log("WebViewPool: BLOCKED — no proxy available for \(target.rawValue), WebView created but may use real IP", category: .webView, level: .error)
        }

        let trackId = "acq_\(UUID().uuidString.prefix(8))"

        if stealthEnabled {
            let stealth = PPSRStealthService.shared
            let profile = stealth.nextProfile()
            let userScript = stealth.createStealthUserScript(profile: profile)
            config.userContentController.addUserScript(userScript)

            let wv = WKWebView(frame: CGRect(origin: .zero, size: CGSize(width: profile.viewport.width, height: profile.viewport.height)), configuration: config)
            wv.customUserAgent = profile.userAgent
            inUseCount += 1
            totalCreated += 1
            peakActiveCount = max(peakActiveCount, inUseCount)
            trackedSessions[trackId] = TrackedWebView(id: trackId, createdAt: Date(), webView: wv)
            logger.log("WebViewPool: acquired stealth WKWebView network=\(effectiveConfig.label) (active:\(inUseCount))", category: .webView, level: .trace)
            startLeakDetectionIfNeeded()
            startStaleSessionReaperIfNeeded()
            return wv
        }

        let wv = WKWebView(frame: CGRect(origin: .zero, size: viewportSize), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        inUseCount += 1
        totalCreated += 1
        peakActiveCount = max(peakActiveCount, inUseCount)
        trackedSessions[trackId] = TrackedWebView(id: trackId, createdAt: Date(), webView: wv)
        logger.log("WebViewPool: created WKWebView network=\(effectiveConfig.label) (active:\(inUseCount))", category: .webView, level: .trace)
        startLeakDetectionIfNeeded()
        startStaleSessionReaperIfNeeded()
        return wv
    }

    func acquireSync(stealthEnabled: Bool = false, viewportSize: CGSize = CGSize(width: 390, height: 844), networkConfig: ActiveNetworkConfig = .direct, target: ProxyRotationService.ProxyTarget = .joe) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let proxyApplied = networkFactory.configureWKWebView(config: config, networkConfig: networkConfig, target: target)
        if !proxyApplied {
            logger.log("WebViewPool: BLOCKED — no proxy available for \(target.rawValue), WebView created but may use real IP", category: .webView, level: .error)
        }

        let trackId = "sync_\(UUID().uuidString.prefix(8))"

        if stealthEnabled {
            let stealth = PPSRStealthService.shared
            let profile = stealth.nextProfile()
            let userScript = stealth.createStealthUserScript(profile: profile)
            config.userContentController.addUserScript(userScript)

            let wv = WKWebView(frame: CGRect(origin: .zero, size: CGSize(width: profile.viewport.width, height: profile.viewport.height)), configuration: config)
            wv.customUserAgent = profile.userAgent
            inUseCount += 1
            totalCreated += 1
            peakActiveCount = max(peakActiveCount, inUseCount)
            trackedSessions[trackId] = TrackedWebView(id: trackId, createdAt: Date(), webView: wv)
            logger.log("WebViewPool: acquired stealth WKWebView network=\(networkConfig.label) (active:\(inUseCount))", category: .webView, level: .trace)
            startLeakDetectionIfNeeded()
            startStaleSessionReaperIfNeeded()
            return wv
        }

        let wv = WKWebView(frame: CGRect(origin: .zero, size: viewportSize), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        inUseCount += 1
        totalCreated += 1
        peakActiveCount = max(peakActiveCount, inUseCount)
        trackedSessions[trackId] = TrackedWebView(id: trackId, createdAt: Date(), webView: wv)
        logger.log("WebViewPool: created WKWebView network=\(networkConfig.label) (active:\(inUseCount))", category: .webView, level: .trace)
        startLeakDetectionIfNeeded()
        startStaleSessionReaperIfNeeded()
        return wv
    }

    func release(_ webView: WKWebView, wipeData: Bool = true) {
        guard inUseCount > 0 else {
            logger.log("WebViewPool: release called but inUseCount already 0 — possible double-release (created:\(totalCreated) released:\(totalReleased))", category: .webView, level: .warning)
            safeCleanupWebView(webView, wipeData: wipeData)
            return
        }
        inUseCount -= 1
        totalReleased += 1

        let matchingKey = trackedSessions.first(where: { $0.value.webView === webView })?.key
        if let key = matchingKey {
            trackedSessions.removeValue(forKey: key)
        }

        safeCleanupWebView(webView, wipeData: wipeData)
        logger.log("WebViewPool: released (active:\(inUseCount))", category: .webView, level: .trace)
    }

    private func safeCleanupWebView(_ webView: WKWebView, wipeData: Bool) {
        webView.stopLoading()
        if wipeData {
            let dataStore = webView.configuration.websiteDataStore
            dataStore.proxyConfigurations = []
            dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) { }
            webView.configuration.userContentController.removeAllUserScripts()
            HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        }
        webView.navigationDelegate = nil
    }

    func handleMemoryPressure() {
        let drained = preWarmedViews.count
        drainPreWarmed()
        reapStaleSessions()
        reapDeallocatedSessions()
        if drained > 0 {
            logger.log("WebViewPool: memory pressure — drained \(drained) pre-warmed views (\(inUseCount) active)", category: .webView, level: .warning)
        } else {
            logger.log("WebViewPool: memory pressure noted (\(inUseCount) active, 0 pre-warmed)", category: .webView, level: .warning)
        }
    }

    func emergencyPurgeAll() {
        let drained = preWarmedViews.count
        drainPreWarmed()
        reapStaleSessions()
        reapDeallocatedSessions()
        logger.log("WebViewPool: EMERGENCY PURGE — drained \(drained) pre-warmed, \(inUseCount) still active (will be cleaned on release)", category: .webView, level: .critical)
        if inUseCount > hardCapActiveWebViews {
            logger.log("WebViewPool: inUseCount (\(inUseCount)) exceeds hard cap — possible leak detected (created:\(totalCreated) released:\(totalReleased))", category: .webView, level: .critical)
            forceResetCount()
        }
    }

    func reportProcessTermination() {
        processTerminationCount += 1
        let now = Date()
        let timeSinceLast = now.timeIntervalSince(lastProcessTerminationTime)
        lastProcessTerminationTime = now

        if timeSinceLast < 30 {
            consecutiveProcessTerminations += 1
        } else {
            consecutiveProcessTerminations = 1
        }

        logger.log("WebViewPool: WebKit content process terminated (total: \(processTerminationCount), consecutive: \(consecutiveProcessTerminations))", category: .webView, level: .error)

        if consecutiveProcessTerminations >= 3 {
            logger.log("WebViewPool: \(consecutiveProcessTerminations) rapid process terminations — draining all pre-warmed and clearing caches", category: .webView, level: .critical)
            drainPreWarmed()
            URLCache.shared.removeAllCachedResponses()

            AppAlertManager.shared.pushCritical(
                source: .webView,
                title: "WebView Instability",
                message: "\(consecutiveProcessTerminations) WebKit crashes in rapid succession. Pre-warmed views drained to stabilize."
            )
            consecutiveProcessTerminations = 0
        } else {
            AppAlertManager.shared.pushWarning(
                source: .webView,
                title: "WebView Crash",
                message: "A WebKit content process was terminated. The session will be retried automatically."
            )
        }
    }

    func forceResetCount() {
        let oldCount = inUseCount
        inUseCount = 0
        trackedSessions.removeAll()
        logger.log("WebViewPool: force-reset inUseCount from \(oldCount) to 0 (created:\(totalCreated) released:\(totalReleased))", category: .webView, level: .warning)
    }

    private func reapStaleSessions() {
        let now = Date()
        var reaped = 0
        for (key, tracked) in trackedSessions {
            let age = now.timeIntervalSince(tracked.createdAt)
            if age > staleSessionTimeoutSeconds {
                if let wv = tracked.webView {
                    safeCleanupWebView(wv, wipeData: true)
                }
                trackedSessions.removeValue(forKey: key)
                if inUseCount > 0 { inUseCount -= 1 }
                totalReleased += 1
                reaped += 1
            }
        }
        if reaped > 0 {
            logger.log("WebViewPool: reaped \(reaped) stale sessions (>\(Int(staleSessionTimeoutSeconds))s old, active:\(inUseCount))", category: .webView, level: .warning)
        }
    }

    private func reapDeallocatedSessions() {
        var reaped = 0
        for (key, tracked) in trackedSessions {
            if tracked.webView == nil {
                trackedSessions.removeValue(forKey: key)
                if inUseCount > 0 { inUseCount -= 1 }
                totalReleased += 1
                reaped += 1
            }
        }
        if reaped > 0 {
            logger.log("WebViewPool: reaped \(reaped) deallocated session references (active:\(inUseCount))", category: .webView, level: .warning)
        }
    }

    private func startStaleSessionReaperIfNeeded() {
        guard staleSessionReaperTask == nil else { return }
        staleSessionReaperTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(90))
                guard !Task.isCancelled, let self else { return }
                self.reapStaleSessions()
                self.reapDeallocatedSessions()
                if self.trackedSessions.isEmpty && self.inUseCount == 0 {
                    self.staleSessionReaperTask = nil
                    return
                }
            }
        }
    }

    private func startLeakDetectionIfNeeded() {
        guard leakDetectionTask == nil else { return }
        leakDetectionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                if self.inUseCount > 0 && !LoginViewModel.shared.isRunning && !PPSRAutomationViewModel.shared.isRunning {
                    self.logger.log("WebViewPool: LEAK DETECTED — \(self.inUseCount) active WebViews but no batch running (created:\(self.totalCreated) released:\(self.totalReleased)). Resetting count.", category: .webView, level: .error)
                    self.reapDeallocatedSessions()
                    if self.inUseCount > 0 {
                        self.forceResetCount()
                    }
                }
                if self.inUseCount == 0 {
                    self.leakDetectionTask = nil
                    return
                }
            }
        }
    }

    var diagnosticSummary: String {
        "Active: \(inUseCount)/\(hardCapActiveWebViews) | PreWarmed: \(preWarmedViews.count) | Tracked: \(trackedSessions.count) | Peak: \(peakActiveCount) | Created: \(totalCreated) | Released: \(totalReleased) | Crashes: \(processTerminationCount)"
    }
}
