import Foundation
import Network
import Observation

@Observable
@MainActor
class NetworkResilienceService {
    static let shared = NetworkResilienceService()

    private(set) var failClosedVerificationActive: Bool = false
    private(set) var lastVerificationResult: VerificationResult?
    private(set) var verificationLog: [VerificationResult] = []
    private(set) var bandwidthEstimateBps: Double = 0
    private(set) var isThrottled: Bool = false
    private(set) var currentConcurrencyLimit: Int = 4
    private(set) var failoverBackoffSeconds: TimeInterval = 0
    private(set) var proxyBandwidthEstimates: [String: ProxyBandwidthEstimate] = [:]
    private(set) var regionLatencies: [String: RegionLatencyProfile] = [:]

    var enableFailClosedVerification: Bool = true
    var verificationIntervalSeconds: TimeInterval = 60
    var bandwidthSampleWindowSeconds: TimeInterval = 10
    var throttleLatencyThresholdMs: Int = 3000
    var throttleErrorRateThreshold: Double = 0.5
    var minConcurrency: Int = 1
    var maxConcurrency: Int = 8

    private var verificationTimer: Timer?
    private var bandwidthSamples: [(timestamp: Date, bytes: UInt64)] = []
    private var failoverAttemptCount: Int = 0
    private var lastFailoverAttempt: Date?
    private let logger = DebugLogger.shared

    struct ProxyBandwidthEstimate {
        var samples: [(timestamp: Date, bytes: UInt64, durationMs: Int)] = []
        var estimatedBps: Double = 0
        var lastUpdated: Date = .distantPast

        mutating func addSample(bytes: UInt64, durationMs: Int) {
            let now = Date()
            samples.append((now, bytes, durationMs))
            let cutoff = now.addingTimeInterval(-120)
            samples.removeAll { $0.timestamp < cutoff }
            recalculate()
            lastUpdated = now
        }

        private mutating func recalculate() {
            guard !samples.isEmpty else { estimatedBps = 0; return }
            let totalBytes = samples.reduce(UInt64(0)) { $0 + $1.bytes }
            let totalMs = samples.reduce(0) { $0 + $1.durationMs }
            guard totalMs > 0 else { estimatedBps = 0; return }
            estimatedBps = Double(totalBytes) / (Double(totalMs) / 1000.0)
        }

        var label: String {
            if estimatedBps < 1024 { return String(format: "%.0f B/s", estimatedBps) }
            if estimatedBps < 1024 * 1024 { return String(format: "%.1f KB/s", estimatedBps / 1024) }
            return String(format: "%.1f MB/s", estimatedBps / (1024 * 1024))
        }
    }

    struct RegionLatencyProfile {
        var region: String
        var samples: [(timestamp: Date, latencyMs: Int)] = []
        var avgLatencyMs: Double = 0
        var lastProbed: Date = .distantPast

        mutating func addSample(latencyMs: Int) {
            let now = Date()
            samples.append((now, latencyMs))
            let cutoff = now.addingTimeInterval(-600)
            samples.removeAll { $0.timestamp < cutoff }
            recalculate()
            lastProbed = now
        }

        private mutating func recalculate() {
            guard !samples.isEmpty else { avgLatencyMs = 9999; return }
            let recent = samples.suffix(10)
            avgLatencyMs = Double(recent.reduce(0) { $0 + $1.latencyMs }) / Double(recent.count)
        }
    }

    nonisolated struct VerificationResult: Identifiable, Sendable {
        let id: UUID
        let timestamp: Date
        let intendedProxy: String
        let detectedIP: String
        let isLeaking: Bool
        let latencyMs: Int

        init(id: UUID = UUID(), timestamp: Date = Date(), intendedProxy: String, detectedIP: String, isLeaking: Bool, latencyMs: Int) {
            self.id = id
            self.timestamp = timestamp
            self.intendedProxy = intendedProxy
            self.detectedIP = detectedIP
            self.isLeaking = isLeaking
            self.latencyMs = latencyMs
        }
    }

    init() {}

    // MARK: - Fail-Closed Proxy Verification Loop (Item 10)

    func startVerificationLoop(expectedProxy: ProxyConfig?) {
        stopVerificationLoop()
        guard enableFailClosedVerification, let proxy = expectedProxy else { return }

        failClosedVerificationActive = true
        logger.log("Resilience: fail-closed verification loop started for \(proxy.displayString)", category: .proxy, level: .info)

        Task { await performVerification(expectedProxy: proxy) }

        verificationTimer = Timer.scheduledTimer(withTimeInterval: verificationIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performVerification(expectedProxy: proxy)
            }
        }
    }

    func stopVerificationLoop() {
        verificationTimer?.invalidate()
        verificationTimer = nil
        failClosedVerificationActive = false
    }

    private nonisolated func performVerification(expectedProxy: ProxyConfig) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        var proxyDict: [String: Any] = [
            "SOCKSEnable": 1,
            "SOCKSProxy": expectedProxy.host,
            "SOCKSPort": expectedProxy.port,
        ]
        if let u = expectedProxy.username { proxyDict["SOCKSUser"] = u }
        if let p = expectedProxy.password { proxyDict["SOCKSPassword"] = p }
        config.connectionProxyDictionary = proxyDict

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let directConfig = URLSessionConfiguration.ephemeral
        directConfig.timeoutIntervalForRequest = 8
        let directSession = URLSession(configuration: directConfig)
        defer { directSession.invalidateAndCancel() }

        guard let url = URL(string: "https://api.ipify.org?format=json") else { return }

        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 6
            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

            let (proxiedData, _) = try await session.data(for: req)
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let latencyMs = Int(elapsed * 1000)

            let proxiedIP = parseIPFromJSON(proxiedData)

            var directReq = URLRequest(url: url)
            directReq.timeoutInterval = 6
            directReq.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (directData, _) = try await directSession.data(for: directReq)
            let directIP = parseIPFromJSON(directData)

            let isLeaking = !proxiedIP.isEmpty && !directIP.isEmpty && proxiedIP == directIP

            let result = VerificationResult(
                intendedProxy: expectedProxy.displayString,
                detectedIP: proxiedIP,
                isLeaking: isLeaking,
                latencyMs: latencyMs
            )

            await MainActor.run {
                self.lastVerificationResult = result
                self.verificationLog.insert(result, at: 0)
                if self.verificationLog.count > 30 {
                    self.verificationLog = Array(self.verificationLog.prefix(30))
                }

                if isLeaking {
                    self.logger.log("Resilience: IP LEAK DETECTED — proxied=\(proxiedIP) direct=\(directIP) via \(expectedProxy.displayString)", category: .proxy, level: .error)
                }
            }
        } catch {
            let result = VerificationResult(
                intendedProxy: expectedProxy.displayString,
                detectedIP: "error",
                isLeaking: false,
                latencyMs: 0
            )
            await MainActor.run {
                self.lastVerificationResult = result
            }
        }
    }

    private nonisolated func parseIPFromJSON(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = json["ip"] as? String else {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return ip
    }

    // MARK: - Exponential Backoff with Jitter (Item 7)

    func calculateBackoffDelay() -> TimeInterval {
        let baseDelay: TimeInterval = 1.0
        let maxDelay: TimeInterval = 60.0
        let exponentialDelay = baseDelay * pow(2.0, Double(failoverAttemptCount))
        let cappedDelay = min(exponentialDelay, maxDelay)
        let jitter = Double.random(in: 0...(cappedDelay * 0.3))
        let finalDelay = cappedDelay + jitter

        failoverBackoffSeconds = finalDelay
        failoverAttemptCount += 1
        lastFailoverAttempt = Date()

        logger.log("Resilience: backoff delay=\(String(format: "%.1f", finalDelay))s (attempt \(failoverAttemptCount), jitter=\(String(format: "%.1f", jitter))s)", category: .proxy, level: .debug)

        return finalDelay
    }

    func resetBackoff() {
        failoverAttemptCount = 0
        failoverBackoffSeconds = 0
        lastFailoverAttempt = nil
    }

    func shouldThrottleFailover() -> Bool {
        guard let last = lastFailoverAttempt else { return false }
        return Date().timeIntervalSince(last) < failoverBackoffSeconds
    }

    // MARK: - Per-Proxy Bandwidth Estimation

    func recordProxyBandwidth(proxyId: String, bytes: UInt64, durationMs: Int) {
        var estimate = proxyBandwidthEstimates[proxyId] ?? ProxyBandwidthEstimate()
        estimate.addSample(bytes: bytes, durationMs: durationMs)
        proxyBandwidthEstimates[proxyId] = estimate
    }

    func proxyBandwidthLabel(proxyId: String) -> String {
        proxyBandwidthEstimates[proxyId]?.label ?? "unknown"
    }

    func proxyBandwidthBps(proxyId: String) -> Double {
        proxyBandwidthEstimates[proxyId]?.estimatedBps ?? 0
    }

    func rankProxiesByBandwidth(proxyIds: [String]) -> [String] {
        proxyIds.sorted { a, b in
            let bwA = proxyBandwidthEstimates[a]?.estimatedBps ?? 0
            let bwB = proxyBandwidthEstimates[b]?.estimatedBps ?? 0
            return bwA > bwB
        }
    }

    // MARK: - Geographic Latency Routing

    func recordRegionLatency(region: String, latencyMs: Int) {
        var profile = regionLatencies[region] ?? RegionLatencyProfile(region: region)
        profile.addSample(latencyMs: latencyMs)
        regionLatencies[region] = profile
    }

    func bestRegion() -> String? {
        guard !regionLatencies.isEmpty else { return nil }
        let valid = regionLatencies.filter { !$0.value.samples.isEmpty }
        guard !valid.isEmpty else { return nil }
        return valid.min(by: { $0.value.avgLatencyMs < $1.value.avgLatencyMs })?.key
    }

    func regionLatencySummary() -> [(region: String, avgMs: Int, sampleCount: Int)] {
        regionLatencies.map { key, profile in
            (key, Int(profile.avgLatencyMs), profile.samples.count)
        }.sorted { $0.avgMs < $1.avgMs }
    }

    func probeRegionLatency(region: String, proxyConfig: ProxyConfig? = nil) async -> Int {
        let testURL = "https://api.ipify.org?format=json"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10

        if let proxy = proxyConfig {
            var proxyDict: [String: Any] = [
                "SOCKSEnable": 1,
                "SOCKSProxy": proxy.host,
                "SOCKSPort": proxy.port,
            ]
            if let u = proxy.username { proxyDict["SOCKSUser"] = u }
            if let p = proxy.password { proxyDict["SOCKSPassword"] = p }
            config.connectionProxyDictionary = proxyDict
        }

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        guard let url = URL(string: testURL) else { return 9999 }
        let start = CFAbsoluteTimeGetCurrent()
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                let latencyMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                recordRegionLatency(region: region, latencyMs: latencyMs)
                return latencyMs
            }
        } catch {
            logger.log("NetworkResilience: probe failed for region \(region): \(error.localizedDescription)", category: .network, level: .debug)
        }
        return 9999
    }

    func probeAllRegions(proxiesByRegion: [String: ProxyConfig?]) async -> String? {
        let results = await withTaskGroup(of: (String, Int).self) { group in
            for (region, proxy) in proxiesByRegion {
                group.addTask {
                    let latency = await self.probeRegionLatency(region: region, proxyConfig: proxy)
                    return (region, latency)
                }
            }
            var collected: [(String, Int)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        for (region, latency) in results {
            logger.log("Resilience: region \(region) latency=\(latency)ms", category: .network, level: latency < 3000 ? .info : .warning)
        }

        let best = results.filter { $0.1 < 9999 }.min(by: { $0.1 < $1.1 })
        if let best {
            logger.log("Resilience: best region=\(best.0) (\(best.1)ms)", category: .network, level: .success)
        }
        return best?.0
    }

    // MARK: - Bandwidth-Aware Concurrency Throttling

    func recordBandwidthSample(bytes: UInt64) {
        let now = Date()
        bandwidthSamples.append((timestamp: now, bytes: bytes))

        let cutoff = now.addingTimeInterval(-bandwidthSampleWindowSeconds)
        bandwidthSamples.removeAll { $0.timestamp < cutoff }

        recalculateBandwidth()
    }

    func recordLatencySample(latencyMs: Int, hadError: Bool, hostname: String? = nil) {
        if hadError || latencyMs > throttleLatencyThresholdMs {
            if currentConcurrencyLimit > minConcurrency {
                currentConcurrencyLimit = max(minConcurrency, currentConcurrencyLimit - 1)
                isThrottled = true
                logger.log("Resilience: throttled concurrency to \(currentConcurrencyLimit) (latency=\(latencyMs)ms, error=\(hadError))", category: .network, level: .warning)
            }
        } else if latencyMs < throttleLatencyThresholdMs / 2 && !hadError {
            if currentConcurrencyLimit < maxConcurrency {
                currentConcurrencyLimit = min(maxConcurrency, currentConcurrencyLimit + 1)
                if currentConcurrencyLimit >= maxConcurrency {
                    isThrottled = false
                }
                logger.log("Resilience: scaled concurrency to \(currentConcurrencyLimit) (latency=\(latencyMs)ms)", category: .network, level: .debug)
            }
        }
    }

    func resetThrottling() {
        currentConcurrencyLimit = maxConcurrency
        isThrottled = false
        bandwidthSamples.removeAll()
        bandwidthEstimateBps = 0
    }

    private func recalculateBandwidth() {
        guard bandwidthSamples.count >= 2 else {
            bandwidthEstimateBps = 0
            return
        }

        let totalBytes = bandwidthSamples.reduce(UInt64(0)) { $0 + $1.bytes }
        guard let first = bandwidthSamples.first, let last = bandwidthSamples.last else {
            bandwidthEstimateBps = 0
            return
        }
        let timeSpan = last.timestamp.timeIntervalSince(first.timestamp)

        guard timeSpan > 0 else {
            bandwidthEstimateBps = 0
            return
        }

        bandwidthEstimateBps = Double(totalBytes) / timeSpan
    }

    var bandwidthLabel: String {
        if bandwidthEstimateBps < 1024 { return String(format: "%.0f B/s", bandwidthEstimateBps) }
        if bandwidthEstimateBps < 1024 * 1024 { return String(format: "%.1f KB/s", bandwidthEstimateBps / 1024) }
        return String(format: "%.1f MB/s", bandwidthEstimateBps / (1024 * 1024))
    }

    // MARK: - DNS Failover Strategy (delegated to DNSPoolService)

    private let dnsPool = DNSPoolService.shared
    private(set) var activeDNSResolver: String = "Cloudflare"

    func resolveDNS(hostname: String) async -> String? {
        if let answer = await dnsPool.resolveWithFullFallback(hostname: hostname) {
            if activeDNSResolver != answer.provider {
                activeDNSResolver = answer.provider
                logger.log("Resilience: DNS failover — now using \(answer.provider) [\(answer.protocolUsed.rawValue)]", category: .network, level: .info)
            }
            return answer.ip
        }
        logger.log("Resilience: all DNS pool servers failed for \(hostname)", category: .network, level: .error)
        return nil
    }

    func preflightDNSCheck(hostnames: [String]) async -> (healthy: Int, failed: Int) {
        let (healthy, failed, _) = await dnsPool.preflightTestAllActive()
        for hostname in hostnames {
            let _ = await dnsPool.resolveWithFullFallback(hostname: hostname)
        }
        return (healthy, failed)
    }

    func preflightDNSCheckDetailed(hostnames: [String]) async -> (healthy: Int, failed: Int, autoDisabled: [String]) {
        let (healthy, failed, autoDisabled) = await dnsPool.preflightTestAllActive()
        for hostname in hostnames {
            let _ = await dnsPool.resolveWithFullFallback(hostname: hostname)
        }
        return (healthy, failed, autoDisabled)
    }

    func dnsResolverStatus() -> [(label: String, healthy: Bool)] {
        dnsPool.managedServers.map { server in
            (server.displayLabel, server.isHealthy)
        }
    }

    func resetDNSHealth() {
        dnsPool.resetAutoDisabled()
        dnsPool.invalidateCache()
        activeDNSResolver = dnsPool.activeServers.first?.displayLabel ?? "Cloudflare"
        logger.log("Resilience: DNS pool health reset", category: .network, level: .info)
    }

    // MARK: - Connection Multiplexing Awareness

    private var hostSessionMap: [String: URLSession] = [:]
    private var hostSessionAccessOrder: [String] = []
    private let maxSharedSessions: Int = 10

    func sharedSession(for host: String, proxyConfig: ProxyConfig? = nil) -> URLSession {
        let key: String
        if let proxy = proxyConfig {
            key = "\(host)_\(proxy.host):\(proxy.port)"
        } else {
            key = host
        }

        if let existing = hostSessionMap[key] {
            hostSessionAccessOrder.removeAll { $0 == key }
            hostSessionAccessOrder.append(key)
            return existing
        }

        if hostSessionMap.count >= maxSharedSessions {
            if let lruKey = hostSessionAccessOrder.first {
                hostSessionMap[lruKey]?.invalidateAndCancel()
                hostSessionMap.removeValue(forKey: lruKey)
                hostSessionAccessOrder.removeFirst()
            }
        }

        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = TimeoutResolver.resolveRequestTimeout(30)
        config.timeoutIntervalForResource = TimeoutResolver.resolveResourceTimeout(60)
        config.httpShouldUsePipelining = true

        if let proxy = proxyConfig {
            var proxyDict: [String: Any] = [
                "SOCKSEnable": 1,
                "SOCKSProxy": proxy.host,
                "SOCKSPort": proxy.port,
            ]
            if let u = proxy.username { proxyDict["SOCKSUser"] = u }
            if let p = proxy.password { proxyDict["SOCKSPassword"] = p }
            config.connectionProxyDictionary = proxyDict
        }

        let session = URLSession(configuration: config)
        hostSessionMap[key] = session
        hostSessionAccessOrder.append(key)
        logger.log("Resilience: created shared TLS session for \(key) (pool: \(hostSessionMap.count)/\(maxSharedSessions))", category: .network, level: .debug)
        return session
    }

    func invalidateSharedSessions() {
        for (_, session) in hostSessionMap {
            session.invalidateAndCancel()
        }
        hostSessionMap.removeAll()
        hostSessionAccessOrder.removeAll()
        logger.log("Resilience: all shared TLS sessions invalidated", category: .network, level: .info)
    }

    var sharedSessionCount: Int { hostSessionMap.count }
}
