import Foundation
import WebKit

@MainActor
class PreflightSmokeTestService {
    static let shared = PreflightSmokeTestService()

    private let logger = DebugLogger.shared
    private let metricsService = TaskMetricsCollectionService.shared

    nonisolated struct SmokeTestResult: Sendable {
        let passed: Bool
        let latencyMs: Int
        let httpStatus: Int?
        let pageLoaded: Bool
        let fieldsDetected: Bool
        let networkBottleneck: String?
        let proxyWorking: Bool
        let detail: String
    }

    func runPreflightTest(
        targetURL: URL,
        networkConfig: ActiveNetworkConfig,
        proxyTarget: ProxyRotationService.ProxyTarget,
        stealthEnabled: Bool = false,
        timeout: TimeInterval = 15
    ) async -> SmokeTestResult {
        let startTime = Date()
        _ = "preflight_\(UUID().uuidString.prefix(6))"

        logger.log("Preflight: starting smoke test → \(targetURL.host ?? targetURL.absoluteString) network=\(networkConfig.label)", category: .automation, level: .info)

        let probeMetrics = await metricsService.probeURL(targetURL.absoluteString, timeout: 8)
        let proxyWorking = probeMetrics.success
        let networkBottleneck = probeMetrics.success ? nil : probeMetrics.bottleneck

        if !proxyWorking {
            let totalMs = Int(Date().timeIntervalSince(startTime) * 1000)
            logger.log("Preflight: network probe FAILED — \(probeMetrics.bottleneck) in \(totalMs)ms", category: .network, level: .error)
            return SmokeTestResult(
                passed: false,
                latencyMs: totalMs,
                httpStatus: probeMetrics.httpStatus,
                pageLoaded: false,
                fieldsDetected: false,
                networkBottleneck: networkBottleneck,
                proxyWorking: false,
                detail: "Network probe failed: \(probeMetrics.bottleneck)"
            )
        }

        let session = LoginSiteWebSession(targetURL: targetURL, networkConfig: networkConfig, proxyTarget: proxyTarget)
        session.stealthEnabled = stealthEnabled
        await session.setUp(wipeAll: true)
        defer { session.tearDown(wipeAll: true) }

        let loaded = await session.loadPage(timeout: timeout)
        if !loaded {
            let totalMs = Int(Date().timeIntervalSince(startTime) * 1000)
            let error = session.lastNavigationError ?? "Unknown load failure"
            logger.log("Preflight: page load FAILED — \(error) in \(totalMs)ms", category: .webView, level: .error)
            return SmokeTestResult(
                passed: false,
                latencyMs: totalMs,
                httpStatus: session.lastHTTPStatusCode,
                pageLoaded: false,
                fieldsDetected: false,
                networkBottleneck: networkBottleneck,
                proxyWorking: proxyWorking,
                detail: "Page load failed: \(error)"
            )
        }

        let verification = await session.verifyLoginFieldsExist()
        let fieldsOK = verification.found >= 2

        let challengeCheck = await ChallengePageClassifier.shared.classify(session: session)
        if challengeCheck.type != .none {
            let totalMs = Int(Date().timeIntervalSince(startTime) * 1000)
            logger.log("Preflight: challenge detected — \(challengeCheck.type.rawValue) (confidence: \(String(format: "%.0f%%", challengeCheck.confidence * 100)))", category: .evaluation, level: .warning)
            return SmokeTestResult(
                passed: false,
                latencyMs: totalMs,
                httpStatus: session.lastHTTPStatusCode,
                pageLoaded: true,
                fieldsDetected: fieldsOK,
                networkBottleneck: nil,
                proxyWorking: proxyWorking,
                detail: "Challenge page detected: \(challengeCheck.type.rawValue) — action: \(challengeCheck.suggestedAction.rawValue)"
            )
        }

        let totalMs = Int(Date().timeIntervalSince(startTime) * 1000)
        let passed = loaded && fieldsOK

        logger.log("Preflight: \(passed ? "PASSED" : "PARTIAL") in \(totalMs)ms — page=\(loaded) fields=\(fieldsOK) (\(verification.found)/2)", category: .automation, level: passed ? .success : .warning)

        return SmokeTestResult(
            passed: passed,
            latencyMs: totalMs,
            httpStatus: session.lastHTTPStatusCode,
            pageLoaded: loaded,
            fieldsDetected: fieldsOK,
            networkBottleneck: nil,
            proxyWorking: proxyWorking,
            detail: passed ? "All preflight checks passed (\(totalMs)ms)" : "Page loaded but only \(verification.found)/2 fields found. Missing: \(verification.missing.joined(separator: ", "))"
        )
    }

    nonisolated struct MultiURLPreflightResult: Sendable {
        let healthyURLs: [URL]
        let failedURLs: [(url: URL, reason: String)]
        let totalMs: Int
    }

    func runPreflightForAllURLs(
        urls: [URL],
        networkConfig: ActiveNetworkConfig,
        proxyTarget: ProxyRotationService.ProxyTarget,
        stealthEnabled: Bool = false,
        timeout: TimeInterval = 12
    ) async -> MultiURLPreflightResult {
        let startTime = Date()
        guard !urls.isEmpty else {
            return MultiURLPreflightResult(healthyURLs: [], failedURLs: [], totalMs: 0)
        }

        logger.log("Preflight: testing \(urls.count) URLs in parallel", category: .automation, level: .info)

        let results: [(URL, Bool, String)] = await withTaskGroup(of: (URL, Bool, String).self) { group in
            for url in urls {
                group.addTask {
                    let probeResult = await self.metricsService.probeURL(url.absoluteString, timeout: 8)
                    if probeResult.success {
                        return (url, true, "OK (\(probeResult.totalMs)ms)")
                    } else {
                        return (url, false, probeResult.bottleneck)
                    }
                }
            }
            var collected: [(URL, Bool, String)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        let healthy = results.filter { $0.1 }.map { $0.0 }
        let failed = results.filter { !$0.1 }.map { (url: $0.0, reason: $0.2) }
        let totalMs = Int(Date().timeIntervalSince(startTime) * 1000)

        for (url, ok, detail) in results {
            let host = url.host ?? url.absoluteString
            logger.log("Preflight: \(host) — \(ok ? "HEALTHY" : "FAILED: \(detail)")", category: .automation, level: ok ? .success : .warning)
        }

        logger.log("Preflight: \(healthy.count)/\(urls.count) URLs healthy in \(totalMs)ms", category: .automation, level: healthy.count == urls.count ? .success : .warning)

        return MultiURLPreflightResult(healthyURLs: healthy, failedURLs: failed, totalMs: totalMs)
    }

    func runQuickNetworkProbe(proxyConfig: ProxyConfig? = nil) async -> (ok: Bool, latencyMs: Int, detail: String) {
        let testURL = "https://api.ipify.org?format=json"
        let metrics = await metricsService.probeURL(testURL, proxyConfig: proxyConfig, timeout: 8)

        if metrics.success {
            return (true, metrics.totalMs, "Network probe OK in \(metrics.totalMs)ms")
        } else {
            return (false, metrics.totalMs, "Network probe failed: \(metrics.bottleneck)")
        }
    }
}
