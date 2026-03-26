import Foundation
import UIKit

@MainActor
class ConcurrentAutomationEngine {
    static let shared = ConcurrentAutomationEngine()

    private let logger = DebugLogger.shared
    private let coordinator = AIAutomationCoordinator.shared
    private let networkFactory = NetworkSessionFactory.shared
    private let urlCooldown = URLCooldownService.shared
    private let throttler = AutomationThrottler(maxConcurrency: 5)
    private let circuitBreaker = HostCircuitBreakerService.shared
    private let anomalyForecasting = AIAnomalyForecastingService.shared
    private let urlQualityScoring = URLQualityScoringService.shared
    private let aiCredentialPriority = AICredentialPriorityScoringService.shared
    private let proxyQualityDecay = ProxyQualityDecayService.shared
    private let preflightService = PreflightSmokeTestService.shared
    private let customTools = AICustomToolsCoordinator.shared
    private let liveSpeed = LiveSpeedAdaptationService.shared
    private let concurrencyGovernor = AIPredictiveConcurrencyGovernor.shared
    private let webViewMemoryManager = AIWebViewMemoryLifecycleManager.shared
    private let batchPreOptimizer = AIPredictiveBatchPreOptimizer.shared
    private let credentialTriage = AICredentialTriageService.shared
    private let adversarialSim = AIAdversarialSimulationEngine.shared
    private let swarmIntelligence = AISwarmIntelligenceService.shared

    private(set) var isRunning: Bool = false
    private var cancelFlag: Bool = false
    var onBatchStats: ((BatchLiveStats) -> Void)?

    private struct BatchState {
        var deadAccounts: Set<String> = []
        var deadCards: Set<String> = []
        var consecutiveConnectionFailures: Int = 0
        var recentOutcomeWindow: [Bool] = []
        var credentialRetryTracker: [String: Int] = [:]
        var consecutiveAllFailBatches: Int = 0
        var batchDeadline: Date?
        var rateLimitSignalCount: Int = 0
        var autoPauseTriggerCount: Int = 0
        var autoPaused: Bool = false

        var allLatencies: [Int] = []
        var successCount: Int = 0
        var failureCount: Int = 0
        var processed: Int = 0
        let startTime: Date = Date()

        let nodeMavenAutoRotateThreshold: Int = 3
        let maxCredentialRetries: Int = 3
        let maxAllFailBackoffMs: Int = 30000
        let autoPauseFailureThreshold: Double = 0.8
        let autoPauseWindowSize: Int = 10
        let autoPauseDurationSeconds: Int = 30
        let autoPauseEscalationFactor: Double = 0.6

        mutating func recordOutcome(success: Bool) {
            if success { successCount += 1 } else { failureCount += 1 }
            processed += 1
            recentOutcomeWindow.append(success)
        }

        mutating func recordLatency(_ latency: Int) {
            allLatencies.append(latency)
        }

        func computeLiveStats(total: Int) -> BatchLiveStats {
            let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
            let avgLatency = allLatencies.isEmpty ? 0 : allLatencies.reduce(0, +) / allLatencies.count
            let successRate = (successCount + failureCount) > 0 ? Double(successCount) / Double(successCount + failureCount) : 0
            let elapsedMinutes = max(0.01, Double(elapsedMs) / 60000.0)
            let throughput = Double(processed) / elapsedMinutes
            let remaining = processed > 0 ? Int(Double(total - processed) / max(0.01, throughput) * 60) : 0
            return BatchLiveStats(
                processed: processed, total: total,
                successCount: successCount, failureCount: failureCount,
                successRate: successRate, avgLatencyMs: avgLatency,
                throughputPerMinute: throughput,
                estimatedRemainingSeconds: remaining,
                elapsedMs: elapsedMs,
                deadAccountCount: deadAccounts.count,
                deadCardCount: deadCards.count
            )
        }

        var isBatchDeadlineExceeded: Bool {
            guard let deadline = batchDeadline else { return false }
            return Date() >= deadline
        }
    }

    func cancel() {
        cancelFlag = true
    }

    // MARK: - PPSR Batch

    func runConcurrentPPSRBatch(
        checks: [PPSRCheck],
        engine: PPSRAutomationEngine,
        maxConcurrency: Int = 5,
        timeout: TimeInterval = 90,
        onProgress: @escaping (Int, Int, CheckOutcome) -> Void
    ) async -> ConcurrentBatchResult<(String, CheckOutcome)> {
        isRunning = true
        cancelFlag = false
        var state = BatchState()
        let batchId = "concurrent_ppsr_\(UUID().uuidString.prefix(8))"

        let effectiveMax = await beginBatch(batchId: batchId, itemCount: checks.count, maxConcurrency: maxConcurrency, timeout: Double(checks.count) * timeout * 0.8, category: .ppsr)
        let timeout = TimeoutResolver.resolveAutomationTimeout(timeout)

        ScreenshotCacheService.shared.resetBatchCounter()
        let proxyOK = await performProxyPreCheck(batchId: batchId)
        if !proxyOK {
            logger.log("ConcurrentEngine: proxy pre-check FAILED — rotating proxy before batch", category: .network, level: .warning)
        }

        var allResults: [(String, CheckOutcome)] = []
        let batchSize = effectiveMax

        for batchStart in stride(from: 0, to: checks.count, by: batchSize) {
            if cancelFlag { break }
            if shouldAbortForMemory() { break }
            await updateThrottlerFromGovernor(requestedMax: batchSize)

            let batchEnd = min(batchStart + batchSize, checks.count)
            let batch = Array(checks[batchStart..<batchEnd])

            let batchResults: [(String, CheckOutcome, Int)] = await withTaskGroup(of: (String, CheckOutcome, Int).self) { group in
                for check in batch {
                    if self.cancelFlag { break }
                    let cardId = check.card.id
                    if state.deadCards.contains(cardId) {
                        self.logger.log("ConcurrentEngine: skipping dead card \(check.card.displayNumber)", category: .automation, level: .info)
                        continue
                    }
                    group.addTask {
                        guard !Task.isCancelled else { return (cardId, CheckOutcome.timeout, 0) }
                        let acquired = await self.throttler.acquire()
                        guard acquired, !Task.isCancelled else {
                            if acquired { await self.throttler.release(succeeded: false) }
                            return (cardId, CheckOutcome.timeout, 0)
                        }
                        let taskStart = Date()
                        let outcome = await engine.runCheck(check, timeout: timeout)
                        let latency = Int(Date().timeIntervalSince(taskStart) * 1000)
                        await self.throttler.release(succeeded: outcome == .pass)
                        return (cardId, outcome, latency)
                    }
                }
                var results: [(String, CheckOutcome, Int)] = []
                for await result in group {
                    results.append(result)
                    if self.cancelFlag { group.cancelAll(); break }
                }
                return results
            }

            for (cardId, outcome, latency) in batchResults {
                allResults.append((cardId, outcome))
                state.recordLatency(latency)
                let success = outcome == .pass
                state.recordOutcome(success: success)
                if outcome == .failInstitution {
                    state.deadCards.insert(cardId)
                    logger.log("ConcurrentEngine: card \(cardId) marked DEAD (failInstitution)", category: .automation, level: .warning)
                }
                concurrencyGovernor.feedOutcome(success: success)
                onProgress(state.processed, checks.count, outcome)
            }

            emitStatsIfNeeded(state: &state, total: checks.count)
            let didPause = await checkAutoPause(state: &state, total: checks.count)
            if didPause && cancelFlag { break }
            await applyThrottling(key: "ppsr_batch")
            await applyAdaptiveConcurrency(batchResults: batchResults.map { ($0.0, $0.1, $0.2) }, processed: state.processed, maxConcurrency: maxConcurrency, key: "ppsr_batch")
            await applyInterBatchCooldown(batchResults: batchResults.map { $0.1 == .pass }, hasMore: batchEnd < checks.count)
        }

        let result = finishBatch(batchId: batchId, state: state, maxConcurrency: maxConcurrency, allResults: allResults, category: .ppsr) { avgLatency in
            if allResults.count >= 3 {
                Task {
                    let mapped = allResults.map { (cardId: $0.0, outcome: "\($0.1)", latencyMs: avgLatency) }
                    let _ = await self.customTools.summarizeBatchPerformance(
                        batchId: batchId, results: mapped,
                        concurrency: maxConcurrency, proxyTarget: "ppsr",
                        networkMode: "default", stealthEnabled: engine.stealthEnabled,
                        fingerprintSpoofing: false, pageLoadTimeout: Int(timeout),
                        submitRetryCount: engine.retrySubmitOnFail ? 1 : 0
                    )
                }
            }
        }

        return result
    }

    // MARK: - Login Batch

    func runConcurrentLoginBatch(
        attempts: [LoginAttempt],
        urls: [URL],
        engine: LoginAutomationEngine,
        maxConcurrency: Int = 5,
        timeout: TimeInterval = 90,
        proxyTarget: ProxyRotationService.ProxyTarget = .joe,
        onProgress: @escaping (Int, Int, LoginOutcome) -> Void
    ) async -> ConcurrentBatchResult<(String, LoginOutcome)> {
        let attempts = prioritizeCredentials(attempts)

        isRunning = true
        cancelFlag = false
        var state = BatchState()
        let batchId = "concurrent_login_\(UUID().uuidString.prefix(8))"
        let maxBatchDuration: TimeInterval = max(300, Double(attempts.count) * timeout * 0.6)
        state.batchDeadline = Date().addingTimeInterval(maxBatchDuration)
        logger.log("ConcurrentEngine: batch deadline set to \(Int(maxBatchDuration))s from now", category: .automation, level: .info)

        let effectiveMax = await beginBatch(batchId: batchId, itemCount: attempts.count, maxConcurrency: maxConcurrency, timeout: maxBatchDuration * 1.2, category: .login)
        let timeout = TimeoutResolver.resolveAutomationTimeout(timeout)
        let proxyService = ProxyRotationService.shared
        let networkMode = proxyService.connectionMode(for: proxyTarget)
        let networkSummary = proxyService.networkSummary(for: proxyTarget)
        engine.proxyTarget = proxyTarget

        logger.startSession(batchId, category: .login, message: "ConcurrentEngine: starting \(attempts.count) login tests across \(urls.count) URLs | network=\(networkSummary) mode=\(networkMode.label) target=\(proxyTarget.rawValue)")

        ScreenshotCacheService.shared.resetBatchCounter()
        let stealthOn = engine.stealthEnabled
        let netConfig = networkFactory.appWideConfig(for: proxyTarget)
        WebViewPool.shared.preWarm(count: min(maxConcurrency, 3), stealthEnabled: stealthOn, networkConfig: netConfig, target: proxyTarget)

        let proxyOK = await performProxyPreCheck(batchId: batchId)
        if !proxyOK {
            logger.log("ConcurrentEngine: proxy pre-check FAILED for login batch — proceeding with caution", category: .network, level: .warning)
        }
        let wireProxyOK = await performWireProxyHealthGate(for: proxyTarget)
        if !wireProxyOK {
            logger.log("ConcurrentEngine: WireProxy health gate FAILED — batch proceeding with caution", category: .network, level: .critical)
        }

        let healthyURLs = await runPreflight(urls: urls, netConfig: netConfig, proxyTarget: proxyTarget, stealthEnabled: stealthOn)

        await runPreBatchAdversarialSim(host: healthyURLs.first?.host ?? urls.first?.host ?? "unknown", batchId: batchId)

        let swarmHost = healthyURLs.first?.host ?? urls.first?.host ?? "unknown"
        let swarmProfile = swarmIntelligence.registerSession(sessionId: batchId, host: swarmHost)
        _ = swarmProfile

        var allResults: [(String, LoginOutcome)] = []
        var carryOverIndices: [Int] = []
        let batchSize = effectiveMax

        for batchStart in stride(from: 0, to: attempts.count, by: batchSize) {
            if cancelFlag { break }
            if state.isBatchDeadlineExceeded {
                logger.log("ConcurrentEngine: BATCH DEADLINE EXCEEDED after \(Int(Date().timeIntervalSince(state.startTime)))s — stopping batch", category: .automation, level: .critical)
                cancelFlag = true
                await throttler.cancelAll()
                break
            }
            if shouldAbortForMemory() {
                PersistentFileStorageService.shared.forceSave()
                LoginViewModel.shared.persistCredentialsNow()
                break
            }
            await updateThrottlerFromGovernor(requestedMax: batchSize)

            let batchEnd = min(batchStart + batchSize, attempts.count)
            let batchIndices = Array(batchStart..<batchEnd)
            let effectiveURLs = resolveEffectiveURLs(indices: batchIndices, healthyURLs: healthyURLs)

            let batchResults = await runLoginTaskGroup(
                indices: batchIndices, attempts: attempts,
                effectiveURLs: effectiveURLs, healthyURLs: healthyURLs,
                engine: engine, timeout: timeout, state: state
            )

            let conclusive = batchResults.filter { isConclusiveOutcome($0.1) }
            let retryable = batchResults.filter { !isConclusiveOutcome($0.1) }

            for (username, outcome, latency, _) in conclusive {
                allResults.append((username, outcome))
                state.recordLatency(latency)
                let success = outcome == .success
                state.recordOutcome(success: success)
                let matchingURL = effectiveURLs[batchIndices.first ?? 0]?.absoluteString ?? ""
                urlCooldown.recordSuccess(for: matchingURL)
                credentialTriage.recordOutcome(username: username, outcome: "\(outcome)", latencyMs: latency)
                if outcome == .permDisabled {
                    state.deadAccounts.insert(username)
                    logger.log("ConcurrentEngine: account '\(username)' marked DEAD (permDisabled)", category: .automation, level: .warning)
                }
                state.consecutiveConnectionFailures = 0
                concurrencyGovernor.feedOutcome(success: success)
                swarmIntelligence.recordSessionOutcome(sessionId: batchId, success: success, latencyMs: latency)
                if success {
                    swarmIntelligence.broadcastSignal(sessionId: batchId, host: swarmHost, type: .successPattern, payload: ["username": username, "latencyMs": "\(latency)"], confidence: 0.8)
                } else if outcome == .redBannerError || outcome == .smsDetected {
                    swarmIntelligence.broadcastSignal(sessionId: batchId, host: swarmHost, type: .rateLimitHit, priority: .high, payload: ["outcome": "\(outcome)"], confidence: 0.9)
                }
                onProgress(state.processed, attempts.count, outcome)
            }

            let allRetryable = !batchResults.isEmpty && conclusive.isEmpty
            if allRetryable && !retryable.isEmpty && !cancelFlag {
                let retryResults = await retryAllFailedBatch(
                    retryable: retryable, attempts: attempts,
                    healthyURLs: healthyURLs, engine: engine,
                    timeout: timeout, proxyTarget: proxyTarget
                )
                for (username, outcome, latency, _) in retryResults {
                    allResults.append((username, outcome))
                    state.recordLatency(latency)
                    let success = outcome == .success
                    state.recordOutcome(success: success)
                    if outcome == .permDisabled { state.deadAccounts.insert(username) }
                    if outcome == .connectionFailure || outcome == .timeout {
                        state.consecutiveConnectionFailures += 1
                    } else {
                        state.consecutiveConnectionFailures = 0
                    }
                    let matchingURL = effectiveURLs[batchIndices.first ?? 0]?.absoluteString ?? ""
                    if outcome == .connectionFailure || outcome == .timeout {
                        urlCooldown.recordFailure(for: matchingURL)
                    } else {
                        urlCooldown.recordSuccess(for: matchingURL)
                    }
                    onProgress(state.processed, attempts.count, outcome)
                }
            } else if !retryable.isEmpty && !cancelFlag {
                processRetryableResults(
                    retryable: retryable, state: &state,
                    allResults: &allResults, carryOverIndices: &carryOverIndices,
                    attempts: attempts, total: attempts.count, onProgress: onProgress
                )
            }

            await handleAllFailBackoff(batchResults: batchResults, state: &state)
            await handleConnectionFailureRotation(state: &state, proxyTarget: proxyTarget)
            emitStatsIfNeeded(state: &state, total: attempts.count)

            let didPause = await checkAutoPause(state: &state, total: attempts.count)
            if didPause && cancelFlag { break }

            trackRateLimitSignals(batchResults: batchResults, state: &state)
            recordAnomalyMetrics(batchResults: batchResults, proxyTarget: proxyTarget, state: state)
            swarmIntelligence.runCoordinationCycle(host: swarmHost)
            await applyLiveSpeedAdaptation(batchResults: batchResults)
            await applyAnomalyForecastActions(healthyURLs: healthyURLs, proxyTarget: proxyTarget, maxConcurrency: maxConcurrency)

            if batchEnd < attempts.count && !cancelFlag {
                let cooldown = computeLoginCooldown(batchResults: batchResults, proxyTarget: proxyTarget, state: state)
                try? await Task.sleep(for: .milliseconds(cooldown))
            }
        }

        await processCarryOvers(
            carryOverIndices: carryOverIndices, attempts: attempts,
            healthyURLs: healthyURLs, engine: engine,
            timeout: timeout, proxyTarget: proxyTarget,
            state: &state, allResults: &allResults, onProgress: onProgress
        )

        let avgLatency = state.allLatencies.isEmpty ? 0 : state.allLatencies.reduce(0, +) / state.allLatencies.count
        let totalMs = Int(Date().timeIntervalSince(state.startTime) * 1000)
        concurrencyGovernor.stop()
        webViewMemoryManager.stop()
        AppStabilityCoordinator.shared.cancelTaskGroupWatchdog(id: batchId)

        let batchSuccessRate = (state.successCount + state.failureCount) > 0 ? Double(state.successCount) / Double(state.successCount + state.failureCount) : 0
        let challengeRate = 0.0
        for url in healthyURLs {
            batchPreOptimizer.recordBatchOutcome(
                host: url.host ?? "",
                successRate: batchSuccessRate,
                avgLatencyMs: avgLatency,
                challengeRate: challengeRate,
                concurrency: effectiveMax
            )
        }

        swarmIntelligence.unregisterSession(sessionId: batchId)
        logger.endSession(batchId, category: .login, message: "ConcurrentEngine: login batch complete — \(state.successCount) success, \(state.failureCount) fail, avgLatency=\(avgLatency)ms | network=\(networkSummary)")

        isRunning = false
        return ConcurrentBatchResult(
            results: allResults, totalTimeMs: totalMs,
            successCount: state.successCount, failureCount: state.failureCount,
            avgLatencyMs: avgLatency
        )
    }

    func resetThrottler() async {
        await throttler.reset()
    }

    func getThrottlerStats() async -> (active: Int, maxConcurrency: Int, backoffMs: Int, consecutiveFailures: Int) {
        await throttler.currentStats()
    }

    // MARK: - Batch Lifecycle Helpers

    private func beginBatch(batchId: String, itemCount: Int, maxConcurrency: Int, timeout: TimeInterval, category: DebugLogCategory) async -> Int {
        concurrencyGovernor.resetOutcomeWindow()
        concurrencyGovernor.start(initialConcurrency: maxConcurrency)
        webViewMemoryManager.start()

        let stabilityCap = CrashProtectionService.shared.recommendedMaxConcurrency
        let governorCap = concurrencyGovernor.recommendConcurrency(requestedMax: maxConcurrency)
        let effectiveMax = min(maxConcurrency, stabilityCap, governorCap)
        if effectiveMax < maxConcurrency {
            logger.log("ConcurrentEngine: concurrency capped \(maxConcurrency) → \(effectiveMax) by stability monitor", category: .automation, level: .warning)
        }
        await throttler.updateMaxConcurrency(effectiveMax)

        AppStabilityCoordinator.shared.registerTaskGroupWatchdog(id: batchId, timeout: timeout) { [weak self] in
            self?.logger.log("ConcurrentEngine: batch watchdog FIRED — force cancelling", category: .automation, level: .critical)
            self?.cancel()
        }

        if category != .login {
            logger.startSession(batchId, category: category, message: "ConcurrentEngine: starting \(itemCount) checks, maxConcurrency=\(maxConcurrency)")
        }

        return effectiveMax
    }

    private func finishBatch<T>(batchId: String, state: BatchState, maxConcurrency: Int, allResults: [T], category: DebugLogCategory, postProcess: (Int) -> Void) -> ConcurrentBatchResult<T> {
        let totalMs = Int(Date().timeIntervalSince(state.startTime) * 1000)
        let avgLatency = state.allLatencies.isEmpty ? 0 : state.allLatencies.reduce(0, +) / state.allLatencies.count

        concurrencyGovernor.stop()
        webViewMemoryManager.stop()
        AppStabilityCoordinator.shared.cancelTaskGroupWatchdog(id: batchId)
        logger.endSession(batchId, category: category, message: "ConcurrentEngine: batch complete — \(state.successCount) pass, \(state.failureCount) fail, avgLatency=\(avgLatency)ms, total=\(totalMs)ms")

        postProcess(avgLatency)
        isRunning = false

        return ConcurrentBatchResult(
            results: allResults, totalTimeMs: totalMs,
            successCount: state.successCount, failureCount: state.failureCount,
            avgLatencyMs: avgLatency
        )
    }

    // MARK: - Shared Batch Loop Helpers

    private func shouldAbortForMemory() -> Bool {
        guard CrashProtectionService.shared.isMemoryDeathSpiral else { return false }
        logger.log("ConcurrentEngine: batch aborting — memory death spiral detected at \(CrashProtectionService.shared.currentMemoryUsageMB())MB", category: .automation, level: .critical)
        return true
    }

    private func updateThrottlerFromGovernor(requestedMax: Int) async {
        let currentCap = CrashProtectionService.shared.recommendedMaxConcurrency
        let governorCap = concurrencyGovernor.recommendConcurrency(requestedMax: requestedMax)
        let effectiveCap = min(currentCap, governorCap)
        let currentMax = await throttler.currentStats().maxConcurrency
        if effectiveCap < currentMax {
            await throttler.updateMaxConcurrency(effectiveCap)
            logger.log("ConcurrentEngine: stability+governor throttle \(currentMax) → \(effectiveCap)", category: .automation, level: .warning)
        }
    }

    private func emitStatsIfNeeded(state: inout BatchState, total: Int) {
        if state.processed % 2 == 0 || state.processed == total {
            onBatchStats?(state.computeLiveStats(total: total))
        }
    }

    private func checkAutoPause(state: inout BatchState, total: Int) async -> Bool {
        let windowToCheck = max(5, state.autoPauseWindowSize - (state.autoPauseTriggerCount * 2))
        let thresholdToUse = max(0.5, state.autoPauseFailureThreshold - (Double(state.autoPauseTriggerCount) * state.autoPauseEscalationFactor * 0.1))

        let failureRate = state.recentOutcomeWindow.count >= windowToCheck
            ? Double(state.recentOutcomeWindow.suffix(windowToCheck).filter { !$0 }.count) / Double(windowToCheck)
            : 0

        guard failureRate >= thresholdToUse && state.recentOutcomeWindow.count >= windowToCheck else {
            if state.recentOutcomeWindow.suffix(windowToCheck).filter({ $0 }).count > windowToCheck / 2 {
                state.autoPauseTriggerCount = max(0, state.autoPauseTriggerCount - 1)
            }
            return false
        }

        state.autoPauseTriggerCount += 1
        let escalatedDuration = min(120, state.autoPauseDurationSeconds + (state.autoPauseTriggerCount * 10))
        state.autoPaused = true
        logger.log("ConcurrentEngine: AUTO-PAUSED (#\(state.autoPauseTriggerCount)) — \(Int(failureRate * 100))% failure rate over last \(windowToCheck) attempts. Waiting \(escalatedDuration)s (threshold=\(Int(thresholdToUse * 100))%)", category: .automation, level: .critical)
        onBatchStats?(state.computeLiveStats(total: total))
        try? await Task.sleep(for: .seconds(escalatedDuration))
        state.recentOutcomeWindow = Array(state.recentOutcomeWindow.suffix(3))
        state.autoPaused = false
        logger.log("ConcurrentEngine: resuming after auto-pause #\(state.autoPauseTriggerCount)", category: .automation, level: .info)
        return true
    }

    private func applyThrottling(key: String) async {
        let throttleCheck = coordinator.shouldThrottle()
        if throttleCheck.shouldThrottle {
            logger.log("ConcurrentEngine: throttling for \(String(format: "%.1f", throttleCheck.waitSeconds))s", category: .automation, level: .warning)
            try? await Task.sleep(for: .seconds(throttleCheck.waitSeconds))
        }
        let anomalyThrottle = anomalyForecasting.shouldThrottleRequests(key: key)
        if anomalyThrottle.shouldThrottle {
            logger.log("ConcurrentEngine: anomaly forecasting throttle \(anomalyThrottle.delayMs)ms", category: .automation, level: .warning)
            try? await Task.sleep(for: .milliseconds(anomalyThrottle.delayMs))
        }
    }

    private func applyAdaptiveConcurrency(batchResults: [(String, CheckOutcome, Int)], processed: Int, maxConcurrency: Int, key: String) async {
        guard coordinator.adaptiveConcurrency && processed > 3 else { return }
        let recentOutcomes = batchResults.map { (cardId: $0.0, outcome: $0.1, latencyMs: $0.2) }
        let analytics = coordinator.computeBatchAnalytics(outcomes: recentOutcomes)
        let anomalyConcurrency = anomalyForecasting.recommendedConcurrency(key: key, currentMax: analytics.suggestedConcurrency)
        let finalConcurrency = min(analytics.suggestedConcurrency, anomalyConcurrency)
        if finalConcurrency != maxConcurrency {
            await throttler.updateMaxConcurrency(finalConcurrency)
            logger.log("ConcurrentEngine: adaptive concurrency → \(finalConcurrency) (anomaly: \(anomalyConcurrency))", category: .automation, level: .info)
        }
    }

    private func applyInterBatchCooldown(batchResults: [Bool], hasMore: Bool) async {
        guard hasMore && !cancelFlag else { return }
        let batchSuccessRate = batchResults.isEmpty ? 0.5 : Double(batchResults.filter { $0 }.count) / Double(batchResults.count)
        let cooldown: Int
        if batchSuccessRate > 0.8 {
            cooldown = Int.random(in: 150...400)
        } else if batchSuccessRate < 0.3 {
            cooldown = Int.random(in: 1200...2500)
            logger.log("ConcurrentEngine: low success rate (\(Int(batchSuccessRate * 100))%) — extended cooldown \(cooldown)ms", category: .automation, level: .warning)
        } else {
            cooldown = Int.random(in: 300...800)
        }
        try? await Task.sleep(for: .milliseconds(cooldown))
    }

    // MARK: - Login-Specific Helpers

    private func prioritizeCredentials(_ attempts: [LoginAttempt]) -> [LoginAttempt] {
        let triaged = credentialTriage.triageAndOrder(credentials: attempts.map { $0.credential })
        let order = Dictionary(uniqueKeysWithValues: triaged.orderedUsernames.enumerated().map { ($1, $0) })
        let result = attempts.sorted { a, b in
            (order[a.credential.username] ?? Int.max) < (order[b.credential.username] ?? Int.max)
        }
        logger.log("ConcurrentEngine: credentials reordered by AI triage — \(triaged.estimatedHighValueCount) high value, \(triaged.similarityGroups.count) similarity clusters", category: .automation, level: .info)
        for line in triaged.triageReasoningLog {
            logger.log("  Triage: \(line)", category: .automation, level: .info)
        }
        return result
    }

    private func runPreflight(urls: [URL], netConfig: ActiveNetworkConfig, proxyTarget: ProxyRotationService.ProxyTarget, stealthEnabled: Bool) async -> [URL] {
        let result = await preflightService.runPreflightForAllURLs(
            urls: urls, networkConfig: netConfig,
            proxyTarget: proxyTarget, stealthEnabled: stealthEnabled, timeout: 12
        )
        if result.healthyURLs.isEmpty {
            logger.log("ConcurrentEngine: ALL URLs failed preflight — using original list with caution", category: .automation, level: .critical)
            return urls
        }
        for failed in result.failedURLs {
            logger.log("ConcurrentEngine: preflight SKIP \(failed.url.host ?? "") — \(failed.reason)", category: .automation, level: .warning)
        }
        logger.log("ConcurrentEngine: preflight passed \(result.healthyURLs.count)/\(urls.count) URLs in \(result.totalMs)ms", category: .automation, level: .success)
        return result.healthyURLs
    }

    private func resolveEffectiveURLs(indices: [Int], healthyURLs: [URL]) -> [Int: URL] {
        var result: [Int: URL] = [:]
        for index in indices {
            let url = healthyURLs[index % healthyURLs.count]
            let urlHost = url.host ?? ""
            if urlCooldown.isAutoDisabled(url.absoluteString) {
                logger.log("ConcurrentEngine: URL \(urlHost) is AUTO-DISABLED — skipping", category: .network, level: .warning)
                result[index] = healthyURLs.first { !urlCooldown.isAutoDisabled($0.absoluteString) && !urlCooldown.isOnCooldown($0.absoluteString) && $0 != url } ?? url
            } else if urlCooldown.isOnCooldown(url.absoluteString) {
                let remaining = Int(urlCooldown.cooldownRemaining(url.absoluteString))
                logger.log("ConcurrentEngine: URL \(urlHost) on cooldown (\(remaining)s left) — rotating", category: .network, level: .warning)
                result[index] = healthyURLs.first { !urlCooldown.isOnCooldown($0.absoluteString) && !urlCooldown.isAutoDisabled($0.absoluteString) && $0 != url } ?? url
            } else if !circuitBreaker.shouldAllow(host: urlHost) {
                let remaining = Int(circuitBreaker.cooldownRemaining(host: urlHost))
                logger.log("ConcurrentEngine: URL \(urlHost) circuit OPEN (\(remaining)s left) — rotating", category: .network, level: .warning)
                result[index] = healthyURLs.first { circuitBreaker.shouldAllow(host: $0.host ?? "") && !urlCooldown.isOnCooldown($0.absoluteString) && $0 != url } ?? url
            } else {
                result[index] = url
            }
        }
        return result
    }

    private func runLoginTaskGroup(
        indices: [Int], attempts: [LoginAttempt],
        effectiveURLs: [Int: URL], healthyURLs: [URL],
        engine: LoginAutomationEngine, timeout: TimeInterval,
        state: BatchState
    ) async -> [(String, LoginOutcome, Int, Int)] {
        await withTaskGroup(of: (String, LoginOutcome, Int, Int).self) { group in
            for index in indices {
                if self.cancelFlag { break }
                let attempt = attempts[index]
                let effectiveURL = effectiveURLs[index] ?? healthyURLs[index % healthyURLs.count]
                let username = attempt.credential.username
                if state.deadAccounts.contains(username) {
                    self.logger.log("ConcurrentEngine: skipping dead account \(username)", category: .automation, level: .info)
                    continue
                }
                group.addTask {
                    guard !Task.isCancelled else { return (username, LoginOutcome.timeout, 0, index) }
                    let acquired = await self.throttler.acquire()
                    guard acquired, !Task.isCancelled else {
                        if acquired { await self.throttler.release(succeeded: false) }
                        return (username, LoginOutcome.timeout, 0, index)
                    }
                    let taskStart = Date()
                    let outcome = await engine.runLoginTest(attempt, targetURL: effectiveURL, timeout: timeout)
                    let latency = Int(Date().timeIntervalSince(taskStart) * 1000)
                    await self.throttler.release(succeeded: outcome == .success)
                    return (username, outcome, latency, index)
                }
            }
            var results: [(String, LoginOutcome, Int, Int)] = []
            for await result in group {
                results.append(result)
                if self.cancelFlag { group.cancelAll(); break }
            }
            return results
        }
    }

    private func retryAllFailedBatch(
        retryable: [(String, LoginOutcome, Int, Int)],
        attempts: [LoginAttempt], healthyURLs: [URL],
        engine: LoginAutomationEngine, timeout: TimeInterval,
        proxyTarget: ProxyRotationService.ProxyTarget
    ) async -> [(String, LoginOutcome, Int, Int)] {
        logger.log("ConcurrentEngine: ALL \(retryable.count) sessions in batch need retry — rotating IP and retrying batch", category: .network, level: .critical)
        await rotateIPAndWaitForReady(for: proxyTarget)

        return await withTaskGroup(of: (String, LoginOutcome, Int, Int).self) { group in
            for (_, _, _, originalIndex) in retryable {
                if self.cancelFlag { break }
                let attempt = attempts[originalIndex]
                let retryURL = healthyURLs[originalIndex % healthyURLs.count]
                let username = attempt.credential.username
                group.addTask {
                    guard !Task.isCancelled else { return (username, LoginOutcome.timeout, 0, originalIndex) }
                    let acquired = await self.throttler.acquire()
                    guard acquired, !Task.isCancelled else {
                        if acquired { await self.throttler.release(succeeded: false) }
                        return (username, LoginOutcome.timeout, 0, originalIndex)
                    }
                    let taskStart = Date()
                    let outcome = await engine.runLoginTest(attempt, targetURL: retryURL, timeout: timeout)
                    let latency = Int(Date().timeIntervalSince(taskStart) * 1000)
                    await self.throttler.release(succeeded: outcome == .success)
                    return (username, outcome, latency, originalIndex)
                }
            }
            var results: [(String, LoginOutcome, Int, Int)] = []
            for await result in group {
                results.append(result)
                if self.cancelFlag { group.cancelAll(); break }
            }
            return results
        }
    }

    private func processRetryableResults(
        retryable: [(String, LoginOutcome, Int, Int)],
        state: inout BatchState, allResults: inout [(String, LoginOutcome)],
        carryOverIndices: inout [Int], attempts: [LoginAttempt],
        total: Int, onProgress: @escaping (Int, Int, LoginOutcome) -> Void
    ) {
        var eligible: [Int] = []
        for (username, _, _, originalIndex) in retryable {
            let currentRetries = state.credentialRetryTracker[username] ?? 0
            if currentRetries >= state.maxCredentialRetries {
                logger.log("ConcurrentEngine: credential '\(username)' exhausted \(state.maxCredentialRetries) retries — marking as final failure", category: .automation, level: .warning)
                allResults.append((username, .unsure))
                state.recordOutcome(success: false)
                onProgress(state.processed, total, .unsure)
            } else {
                state.credentialRetryTracker[username] = currentRetries + 1
                eligible.append(originalIndex)
            }
        }
        if !eligible.isEmpty {
            logger.log("ConcurrentEngine: \(eligible.count) sessions inconclusive — carrying over (\(retryable.count - eligible.count) exhausted retries)", category: .network, level: .warning)
            carryOverIndices.append(contentsOf: eligible)
        }
    }

    private func handleAllFailBackoff(batchResults: [(String, LoginOutcome, Int, Int)], state: inout BatchState) async {
        let batchAllFailed = !batchResults.isEmpty && batchResults.allSatisfy({ !isConclusiveOutcome($0.1) })
        if batchAllFailed {
            state.consecutiveAllFailBatches += 1
            let backoffMs = min(state.maxAllFailBackoffMs, 2000 * (1 << min(state.consecutiveAllFailBatches - 1, 4)))
            logger.log("ConcurrentEngine: consecutive all-fail batch #\(state.consecutiveAllFailBatches) — exponential backoff \(backoffMs)ms before next batch", category: .network, level: .critical)
            try? await Task.sleep(for: .milliseconds(backoffMs))
        } else if batchResults.contains(where: { isConclusiveOutcome($0.1) }) {
            state.consecutiveAllFailBatches = 0
        }
    }

    private func handleConnectionFailureRotation(state: inout BatchState, proxyTarget: ProxyRotationService.ProxyTarget) async {
        guard state.consecutiveConnectionFailures >= state.nodeMavenAutoRotateThreshold else { return }
        if NodeMavenService.shared.isEnabled {
            logger.log("ConcurrentEngine: \(state.consecutiveConnectionFailures) consecutive connection failures — rotating NodeMaven IP", category: .network, level: .warning)
            let _ = NodeMavenService.shared.generateProxyConfig(sessionId: "autorotate_\(Int(Date().timeIntervalSince1970))")
        } else {
            logger.log("ConcurrentEngine: \(state.consecutiveConnectionFailures) consecutive connection failures — forcing IP rotation", category: .network, level: .warning)
            await rotateIPAndWaitForReady(for: proxyTarget)
        }
        state.consecutiveConnectionFailures = 0
    }

    private func trackRateLimitSignals(batchResults: [(String, LoginOutcome, Int, Int)], state: inout BatchState) {
        let rateLimitResults = batchResults.filter { $0.1 == .redBannerError || $0.1 == .smsDetected }
        if !rateLimitResults.isEmpty {
            state.rateLimitSignalCount += rateLimitResults.count
        }
    }

    private func recordAnomalyMetrics(batchResults: [(String, LoginOutcome, Int, Int)], proxyTarget: ProxyRotationService.ProxyTarget, state: BatchState) {
        let forecastKey = "login_\(proxyTarget.rawValue)"
        for (_, outcome, latency, _) in batchResults {
            anomalyForecasting.recordLatency(key: forecastKey, latencyMs: latency)
            if outcome == .success {
                anomalyForecasting.recordSuccess(key: forecastKey)
            } else {
                anomalyForecasting.recordError(key: forecastKey, isRateLimit: outcome == .redBannerError || outcome == .smsDetected)
            }
            let isSuccess = outcome == .success || outcome == .noAcc || outcome == .permDisabled || outcome == .tempDisabled
            liveSpeed.recordLatency(
                latencyMs: latency, success: isSuccess,
                wasTimeout: outcome == .timeout,
                wasConnectionFailure: outcome == .connectionFailure
            )
        }
    }

    private func applyLiveSpeedAdaptation(batchResults: [(String, LoginOutcome, Int, Int)]) async {
        if let concurrencyDelta = liveSpeed.currentConcurrencyRecommendation, concurrencyDelta != 0 {
            let currentMax = await throttler.currentStats().maxConcurrency
            let newMax = max(1, min(10, currentMax + concurrencyDelta))
            if newMax != currentMax {
                await throttler.updateMaxConcurrency(newMax)
                logger.log("ConcurrentEngine: LiveSpeed concurrency \(currentMax) → \(newMax) (\(liveSpeed.lastAdaptationReason))", category: .automation, level: .info)
            }
        }
    }

    private func applyAnomalyForecastActions(healthyURLs: [URL], proxyTarget: ProxyRotationService.ProxyTarget, maxConcurrency: Int) async {
        let forecast = anomalyForecasting.forecast(key: "login_\(proxyTarget.rawValue)")
        if forecast.softBreakRecommended {
            for url in healthyURLs {
                if let host = url.host { circuitBreaker.applySoftBreak(host: host) }
            }
        }
        if let reduction = forecast.concurrencyReduction, reduction > 0 {
            let newMax = max(1, maxConcurrency - reduction)
            await throttler.updateMaxConcurrency(newMax)
            logger.log("ConcurrentEngine: anomaly forecast reducing concurrency to \(newMax)", category: .automation, level: .warning)
        }
    }

    private func computeLoginCooldown(batchResults: [(String, LoginOutcome, Int, Int)], proxyTarget: ProxyRotationService.ProxyTarget, state: BatchState) -> Int {
        let anomalyThrottle = anomalyForecasting.shouldThrottleRequests(key: "login_\(proxyTarget.rawValue)")
        let batchSuccessRate = batchResults.isEmpty ? 0.5 : Double(batchResults.filter { $0.1 == .success }.count) / Double(batchResults.count)
        let rateLimitMultiplier = state.rateLimitSignalCount > 3 ? 2.5 : (state.rateLimitSignalCount > 0 ? 1.5 : 1.0)
        let baseCooldown: Int
        if anomalyThrottle.shouldThrottle {
            baseCooldown = anomalyThrottle.delayMs
        } else if batchSuccessRate > 0.8 {
            baseCooldown = Int(Double(Int.random(in: 250...600)) * rateLimitMultiplier)
        } else if batchSuccessRate < 0.3 {
            baseCooldown = Int(Double(Int.random(in: 1500...3000)) * rateLimitMultiplier)
            logger.log("ConcurrentEngine: low login success rate (\(Int(batchSuccessRate * 100))%) — extended cooldown \(baseCooldown)ms (rateLimitSignals=\(state.rateLimitSignalCount))", category: .automation, level: .warning)
        } else {
            baseCooldown = Int(Double(Int.random(in: 500...1200)) * rateLimitMultiplier)
        }
        let adapted = liveSpeed.adaptDelay(baseCooldown)
        if adapted != baseCooldown {
            logger.log("ConcurrentEngine: LiveSpeed adapted cooldown \(baseCooldown)ms → \(adapted)ms (\(String(format: "%.2f", liveSpeed.currentSpeedMultiplier))x)", category: .timing, level: .debug)
        }
        return adapted
    }

    private func processCarryOvers(
        carryOverIndices: [Int], attempts: [LoginAttempt],
        healthyURLs: [URL], engine: LoginAutomationEngine,
        timeout: TimeInterval, proxyTarget: ProxyRotationService.ProxyTarget,
        state: inout BatchState, allResults: inout [(String, LoginOutcome)],
        onProgress: @escaping (Int, Int, LoginOutcome) -> Void
    ) async {
        let deduped = Array(Set(carryOverIndices)).sorted { a, b in
            (state.credentialRetryTracker[attempts[a].credential.username] ?? 0) <
            (state.credentialRetryTracker[attempts[b].credential.username] ?? 0)
        }
        guard !deduped.isEmpty && !cancelFlag else { return }

        let eligible = deduped.filter { index in
            let username = attempts[index].credential.username
            let retries = state.credentialRetryTracker[username] ?? 0
            if retries >= state.maxCredentialRetries {
                logger.log("ConcurrentEngine: carry-over credential '\(username)' exhausted retries — skipping", category: .automation, level: .warning)
                allResults.append((username, .unsure))
                state.recordOutcome(success: false)
                onProgress(state.processed, attempts.count, .unsure)
                return false
            }
            return !state.deadAccounts.contains(username)
        }
        guard !eligible.isEmpty else { return }

        logger.log("ConcurrentEngine: processing \(eligible.count) prioritized carry-over sessions (\(deduped.count - eligible.count) exhausted/dead)", category: .automation, level: .info)
        await rotateIPAndWaitForReady(for: proxyTarget)

        let results: [(String, LoginOutcome, Int)] = await withTaskGroup(of: (String, LoginOutcome, Int).self) { group in
            for index in eligible {
                if self.cancelFlag { break }
                let attempt = attempts[index]
                let retryURL = healthyURLs[index % healthyURLs.count]
                let username = attempt.credential.username
                if state.deadAccounts.contains(username) { continue }
                group.addTask {
                    guard !Task.isCancelled else { return (username, LoginOutcome.timeout, 0) }
                    let acquired = await self.throttler.acquire()
                    guard acquired, !Task.isCancelled else {
                        if acquired { await self.throttler.release(succeeded: false) }
                        return (username, LoginOutcome.timeout, 0)
                    }
                    let taskStart = Date()
                    let outcome = await engine.runLoginTest(attempt, targetURL: retryURL, timeout: timeout)
                    let latency = Int(Date().timeIntervalSince(taskStart) * 1000)
                    await self.throttler.release(succeeded: outcome == .success)
                    return (username, outcome, latency)
                }
            }
            var results: [(String, LoginOutcome, Int)] = []
            for await result in group {
                results.append(result)
                if self.cancelFlag { group.cancelAll(); break }
            }
            return results
        }

        for (username, outcome, latency) in results {
            allResults.append((username, outcome))
            state.recordLatency(latency)
            state.recordOutcome(success: outcome == .success)
            if outcome == .permDisabled { state.deadAccounts.insert(username) }
            onProgress(state.processed, attempts.count, outcome)
        }
    }

    // MARK: - Network Helpers

    private func rotateIP(for target: ProxyRotationService.ProxyTarget) {
        let deviceProxy = DeviceProxyService.shared
        if deviceProxy.isEnabled {
            deviceProxy.rotateNow(reason: "Batch connection failure — IP rotation")
            logger.log("ConcurrentEngine: rotated united IP (DeviceProxy) for \(target.rawValue)", category: .network, level: .warning)
            return
        }
        if NodeMavenService.shared.isEnabled {
            let _ = NodeMavenService.shared.generateProxyConfig(sessionId: "batch_rotate_\(Int(Date().timeIntervalSince1970))")
            logger.log("ConcurrentEngine: rotated NodeMaven session IP for \(target.rawValue)", category: .network, level: .warning)
            return
        }
        let proxyService = ProxyRotationService.shared
        let mode = proxyService.connectionMode(for: target)
        switch mode {
        case .wireguard:
            let _ = proxyService.nextReachableWGConfig(for: target)
            logger.log("ConcurrentEngine: rotated to next WireGuard IP for \(target.rawValue)", category: .network, level: .warning)
        case .openvpn:
            let _ = proxyService.nextReachableOVPNConfig(for: target)
            logger.log("ConcurrentEngine: rotated to next OpenVPN IP for \(target.rawValue)", category: .network, level: .warning)
        case .proxy:
            let _ = proxyService.nextWorkingProxy(for: target)
            logger.log("ConcurrentEngine: rotated to next SOCKS5 IP for \(target.rawValue)", category: .network, level: .warning)
        case .direct, .dns, .nodeMaven:
            logger.log("ConcurrentEngine: no IP pool to rotate for mode \(mode.label) on \(target.rawValue)", category: .network, level: .warning)
        case .hybrid:
            HybridNetworkingService.shared.resetBatch()
            logger.log("ConcurrentEngine: hybrid mode — reset and re-assigned for \(target.rawValue)", category: .network, level: .warning)
        }
    }

    private func rotateIPAndWaitForReady(for target: ProxyRotationService.ProxyTarget) async {
        rotateIP(for: target)
        let maxProbeAttempts = 10
        let probeIntervalMs = 500
        for attempt in 1...maxProbeAttempts {
            let probeOK = await quickIPProbe()
            if probeOK {
                logger.log("ConcurrentEngine: post-rotation probe succeeded on attempt \(attempt) (\(attempt * probeIntervalMs)ms)", category: .network, level: .success)
                return
            }
            try? await Task.sleep(for: .milliseconds(probeIntervalMs))
        }
        logger.log("ConcurrentEngine: post-rotation probe failed after \(maxProbeAttempts) attempts — falling back to 3000ms wait", category: .network, level: .warning)
        try? await Task.sleep(for: .milliseconds(3000))
    }

    private nonisolated func quickIPProbe() async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "https://api.ipify.org?format=json") else { return false }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty { return true }
            return false
        } catch {
            return false
        }
    }

    private func isConclusiveOutcome(_ outcome: LoginOutcome) -> Bool {
        switch outcome {
        case .success, .tempDisabled, .permDisabled, .noAcc: return true
        case .connectionFailure, .timeout, .unsure, .redBannerError, .smsDetected: return false
        }
    }

    private func performWireProxyHealthGate(for target: ProxyRotationService.ProxyTarget) async -> Bool {
        let proxyService = ProxyRotationService.shared
        let mode = proxyService.connectionMode(for: target)
        guard mode == .wireguard else { return true }

        let wireProxyBridge = WireProxyBridge.shared
        let localProxy = LocalProxyServer.shared
        guard wireProxyBridge.isActive || localProxy.wireProxyMode else {
            logger.log("ConcurrentEngine: WireGuard mode but WireProxy not active — skipping health gate", category: .network, level: .info)
            return true
        }

        guard wireProxyBridge.isActive else { return true }

        let probeOK = await quickIPProbe()
        if probeOK {
            logger.log("ConcurrentEngine: WireProxy health gate PASSED", category: .network, level: .success)
            return true
        }

        logger.log("ConcurrentEngine: WireProxy health gate FAILED — attempting tunnel restart", category: .network, level: .warning)
        let configs = proxyService.wgConfigs(for: target).filter { $0.isEnabled }
        if let firstConfig = configs.first {
            wireProxyBridge.stop()
            try? await Task.sleep(for: .seconds(1))
            await wireProxyBridge.start(with: firstConfig)
            try? await Task.sleep(for: .seconds(2))
            if wireProxyBridge.isActive {
                let retryProbe = await quickIPProbe()
                if retryProbe {
                    logger.log("ConcurrentEngine: WireProxy health gate PASSED after restart", category: .network, level: .success)
                    return true
                }
            }
        }
        logger.log("ConcurrentEngine: WireProxy health gate FAILED after restart attempt — proceeding with caution", category: .network, level: .critical)
        return false
    }

    private func runPreBatchAdversarialSim(host: String, batchId: String) async {
        guard adversarialSim.shouldRunSimulation(host: host, cooldownMinutes: 15) else {
            logger.log("ConcurrentEngine: adversarial sim skipped for \(host) — cooldown active", category: .automation, level: .debug)
            return
        }
        logger.log("ConcurrentEngine: running pre-batch adversarial simulation for \(host)", category: .automation, level: .info)
        let suite = await adversarialSim.runSimulation(host: host, difficulty: .intermediate, scenarioTypes: [.timingDetection, .fingerprintDetection, .proxyBlocking, .rateLimiting])
        if suite.overallVerdict == .critical {
            logger.log("ConcurrentEngine: adversarial sim CRITICAL for \(host) — score \(String(format: "%.0f%%", suite.overallScore * 100)). Auto-healing actions queued.", category: .automation, level: .critical)
        } else if suite.overallVerdict == .failed {
            logger.log("ConcurrentEngine: adversarial sim FAILED for \(host) — score \(String(format: "%.0f%%", suite.overallScore * 100))", category: .automation, level: .warning)
        } else {
            logger.log("ConcurrentEngine: adversarial sim \(suite.overallVerdict.label) for \(host) — score \(String(format: "%.0f%%", suite.overallScore * 100))", category: .automation, level: .info)
        }
    }

    private func performProxyPreCheck(batchId: String) async -> Bool {
        logger.log("ConcurrentEngine: running proxy pre-check...", category: .network, level: .info)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 8
        sessionConfig.timeoutIntervalForResource = 10

        let deviceProxy = DeviceProxyService.shared
        if deviceProxy.isEnabled, let netConfig = deviceProxy.activeConfig {
            if case .socks5(let proxy) = netConfig {
                var proxyDict: [String: Any] = [
                    "SOCKSEnable": 1,
                    "SOCKSProxy": proxy.host,
                    "SOCKSPort": proxy.port,
                ]
                if let u = proxy.username { proxyDict["SOCKSUser"] = u }
                if let p = proxy.password { proxyDict["SOCKSPassword"] = p }
                sessionConfig.connectionProxyDictionary = proxyDict
            }
        }

        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "https://api.ipify.org?format=json") else { return true }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ip = json["ip"] as? String {
                    logger.log("ConcurrentEngine: proxy pre-check PASSED — IP: \(ip)", category: .network, level: .success)
                }
                return true
            }
            logger.log("ConcurrentEngine: proxy pre-check got HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)", category: .network, level: .warning)
            return false
        } catch {
            logger.log("ConcurrentEngine: proxy pre-check FAILED — \(error.localizedDescription)", category: .network, level: .error)
            return false
        }
    }
}
