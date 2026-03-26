@preconcurrency import Foundation
@preconcurrency import Network
import Observation

@Observable
@MainActor
class HybridNetworkingService {
    static let shared = HybridNetworkingService()

    private let proxyService = ProxyRotationService.shared
    private let aiStrategy = AIProxyStrategyService.shared
    private let intel = NordServerIntelligence.shared
    private let logger = DebugLogger.shared

    private var sessionIndex: Int = 0
    private var methodHealthScores: [HybridMethod: Double] = [:]
    private let persistKey = "hybrid_networking_health_v2"

    // MARK: - Circuit Breaker State

    private var circuitBreakers: [HybridMethod: CircuitBreakerState] = [:]
    private let circuitBreakerThreshold: Int = 5
    private let circuitBreakerCooldownSeconds: TimeInterval = 60
    private let halfOpenMaxProbes: Int = 2

    private struct CircuitBreakerState {
        var consecutiveFailures: Int = 0
        var state: CBState = .closed
        var lastTrippedAt: Date?
        var halfOpenProbes: Int = 0
        var totalTrips: Int = 0

        enum CBState: String {
            case closed
            case open
            case halfOpen
        }

        var isOpen: Bool { state == .open }
        var isClosed: Bool { state == .closed }
        var isHalfOpen: Bool { state == .halfOpen }
    }

    // MARK: - Preflight Probe State

    private var lastPreflightResults: [HybridMethod: PreflightResult] = [:]
    private var preflightInProgress: Bool = false

    private struct PreflightResult {
        let method: HybridMethod
        let alive: Bool
        let latencyMs: Int
        let timestamp: Date

        var isStale: Bool {
            Date().timeIntervalSince(timestamp) > 120
        }
    }

    // MARK: - Mid-Batch Reranking

    private var batchFailureCounts: [HybridMethod: Int] = [:]
    private var batchSuccessCounts: [HybridMethod: Int] = [:]
    private let rerankThreshold: Int = 3
    private var lastRerankTime: Date = .distantPast
    private var cachedRankedMethods: [HybridMethod] = []
    private var cachedRankTarget: ProxyRotationService.ProxyTarget?

    // MARK: - Sticky Session Preference

    private var stickyMethodPerHost: [String: HybridMethod] = [:]
    private let stickyDecayAfterSeconds: TimeInterval = 600
    private var stickyTimestamps: [String: Date] = [:]

    // MARK: - Health Score Decay

    private var lastDecayTime: Date = .distantPast
    private let decayIntervalSeconds: TimeInterval = 300
    private let decayFactor: Double = 0.92

    nonisolated enum HybridMethod: String, CaseIterable, Sendable {
        case wireProxy = "WireProxy"
        case nodeMaven = "NodeMaven"
        case openVPN = "OpenVPN"
        case socks5 = "SOCKS5"
        case httpsDOH = "HTTPS/DoH"

        var icon: String {
            switch self {
            case .wireProxy: "lock.trianglebadge.exclamationmark.fill"
            case .nodeMaven: "cloud.fill"
            case .openVPN: "shield.lefthalf.filled"
            case .socks5: "network"
            case .httpsDOH: "lock.shield.fill"
            }
        }

        var priority: Int {
            switch self {
            case .wireProxy: 0
            case .nodeMaven: 1
            case .openVPN: 2
            case .socks5: 3
            case .httpsDOH: 4
            }
        }
    }

    nonisolated struct HybridSessionAssignment: Sendable {
        let method: HybridMethod
        let config: ActiveNetworkConfig
        let label: String
        let circuitState: String
    }

    var lastAssignments: [HybridSessionAssignment] = []
    var isActive: Bool = false
    var methodStats: [HybridMethod: MethodStat] = [:]

    nonisolated struct MethodStat: Sendable {
        var attempts: Int = 0
        var successes: Int = 0
        var failures: Int = 0
        var consecutiveFailures: Int = 0
        var consecutiveSuccesses: Int = 0
        var avgLatencyMs: Int = 0
        var p95LatencyMs: Int = 0
        var timeouts: Int = 0
        var blocks: Int = 0
        var lastUsed: Date?
        var lastSuccess: Date?
        var lastFailure: Date?
        var latencySamples: [Int] = []

        var successRate: Double {
            guard attempts > 0 else { return 0.5 }
            return Double(successes) / Double(attempts)
        }

        var timeoutRate: Double {
            guard attempts > 0 else { return 0 }
            return Double(timeouts) / Double(attempts)
        }

        var blockRate: Double {
            guard attempts > 0 else { return 0 }
            return Double(blocks) / Double(attempts)
        }

        var isReliable: Bool {
            attempts >= 5 && successRate >= 0.6
        }

        var isDegraded: Bool {
            attempts >= 3 && (successRate < 0.3 || timeoutRate > 0.5)
        }
    }

    // MARK: - Fail-Closed Proxy

    private var failClosedProxy: ProxyConfig {
        ProxyConfig(host: "127.0.0.1", port: 9)
    }

    init() {
        loadHealthScores()
        loadCircuitBreakers()
    }

    // MARK: - Public API

    func nextHybridConfig(for target: ProxyRotationService.ProxyTarget) -> ActiveNetworkConfig {
        applyHealthDecayIfNeeded()

        let methods = availableMethodsRankedByAI(for: target)
        guard !methods.isEmpty else {
            logger.log("Hybrid: no methods available for \(target.rawValue)", category: .network, level: .error)
            return failClosedConfigForTarget(target)
        }

        let host = hostForTarget(target)
        let method = selectMethodWithExploration(methods: methods, host: host)
        sessionIndex += 1

        let config = resolveConfig(for: method, target: target)

        let validatedConfig = validateConfig(config, method: method, target: target)

        let cb = circuitBreakers[method] ?? CircuitBreakerState()
        let assignment = HybridSessionAssignment(
            method: method,
            config: validatedConfig,
            label: "\(method.rawValue) [CB:\(cb.state.rawValue)]",
            circuitState: cb.state.rawValue
        )
        lastAssignments.append(assignment)
        if lastAssignments.count > 100 { lastAssignments.removeFirst(lastAssignments.count - 100) }

        logger.log("Hybrid: session \(sessionIndex) → \(method.rawValue) (\(validatedConfig.label)) CB:\(cb.state.rawValue) for \(target.rawValue)", category: .network, level: .info)
        return validatedConfig
    }

    func assignConfigsForBatch(count: Int, target: ProxyRotationService.ProxyTarget) -> [ActiveNetworkConfig] {
        isActive = true
        lastAssignments.removeAll()
        sessionIndex = 0
        batchFailureCounts.removeAll()
        batchSuccessCounts.removeAll()
        cachedRankedMethods.removeAll()
        cachedRankTarget = nil
        lastRerankTime = .distantPast

        applyHealthDecayIfNeeded()
        transitionHalfOpenBreakers()

        let methods = availableMethodsRankedByAI(for: target)
        guard !methods.isEmpty else {
            let failClosed = failClosedConfigForTarget(target)
            return Array(repeating: failClosed, count: count)
        }

        var configs: [ActiveNetworkConfig] = []
        let host = hostForTarget(target)

        for _ in 0..<count {
            let method = selectMethodWithExploration(methods: methods, host: host)
            let config = resolveConfig(for: method, target: target)
            let validated = validateConfig(config, method: method, target: target)
            configs.append(validated)

            let cb = circuitBreakers[method] ?? CircuitBreakerState()
            let assignment = HybridSessionAssignment(
                method: method,
                config: validated,
                label: method.rawValue,
                circuitState: cb.state.rawValue
            )
            lastAssignments.append(assignment)
            sessionIndex += 1
        }

        let distribution = Dictionary(grouping: lastAssignments, by: \.method).mapValues(\.count)
        let distLabel = distribution.sorted(by: { $0.key.priority < $1.key.priority }).map { "\($0.key.rawValue):\($0.value)" }.joined(separator: " ")
        logger.log("Hybrid: batch assigned \(count) sessions — \(distLabel)", category: .network, level: .success)

        return configs
    }

    func recordOutcome(method: HybridMethod, success: Bool, latencyMs: Int, hostname: String? = nil, region: String = "auto", wasBlocked: Bool = false, wasTimeout: Bool = false) {
        var stat = methodStats[method] ?? MethodStat()
        stat.attempts += 1
        if success {
            stat.successes += 1
            stat.consecutiveSuccesses += 1
            stat.consecutiveFailures = 0
            stat.lastSuccess = Date()
        } else {
            stat.failures += 1
            stat.consecutiveFailures += 1
            stat.consecutiveSuccesses = 0
            stat.lastFailure = Date()
        }
        if wasTimeout { stat.timeouts += 1 }
        if wasBlocked { stat.blocks += 1 }

        stat.latencySamples.append(latencyMs)
        if stat.latencySamples.count > 50 {
            stat.latencySamples = Array(stat.latencySamples.suffix(50))
        }
        let sorted = stat.latencySamples.sorted()
        stat.p95LatencyMs = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]

        let prevTotal = stat.avgLatencyMs * max(1, stat.attempts - 1)
        stat.avgLatencyMs = (prevTotal + latencyMs) / stat.attempts
        stat.lastUsed = Date()
        methodStats[method] = stat

        let score = calculateHealthScore(for: stat)
        methodHealthScores[method] = score

        updateCircuitBreaker(method: method, success: success)

        if success, let host = hostname {
            stickyMethodPerHost[host] = method
            stickyTimestamps[host] = Date()
        }

        batchFailureCounts[method, default: 0] += success ? 0 : 1
        batchSuccessCounts[method, default: 0] += success ? 1 : 0
        checkMidBatchRerank()

        persistHealthScores()
        persistCircuitBreakers()

        if let host = hostname {
            if success {
                intel.recordSuccess(hostname: host, latencyMs: latencyMs)
            } else {
                intel.recordFailure(hostname: host)
            }

        }

        if stat.isDegraded {
            logger.log("Hybrid: \(method.rawValue) DEGRADED — SR:\(Int(stat.successRate * 100))% TO:\(Int(stat.timeoutRate * 100))% after \(stat.attempts) attempts", category: .network, level: .warning)
        }
    }

    func resetBatch() {
        isActive = false
        lastAssignments.removeAll()
        sessionIndex = 0
        batchFailureCounts.removeAll()
        batchSuccessCounts.removeAll()
        cachedRankedMethods.removeAll()
        cachedRankTarget = nil
        lastRerankTime = .distantPast
    }

    func preflightProbeAllMethods(for target: ProxyRotationService.ProxyTarget) async {
        guard !preflightInProgress else { return }
        preflightInProgress = true
        defer { preflightInProgress = false }

        let methods = availableMethodsRaw(for: target)
        logger.log("Hybrid: preflight probing \(methods.count) methods for \(target.rawValue)", category: .network, level: .info)

        await withTaskGroup(of: PreflightResult.self) { group in
            for method in methods {
                group.addTask { [self] in
                    await self.probeMethod(method, target: target)
                }
            }
            for await result in group {
                lastPreflightResults[result.method] = result
                if !result.alive {
                    logger.log("Hybrid: preflight DEAD — \(result.method.rawValue) for \(target.rawValue)", category: .network, level: .warning)
                } else {
                    logger.log("Hybrid: preflight OK — \(result.method.rawValue) \(result.latencyMs)ms", category: .network, level: .debug)
                }
            }
        }

        let alive = lastPreflightResults.values.filter(\.alive).count
        let dead = lastPreflightResults.values.filter { !$0.alive }.count
        logger.log("Hybrid: preflight complete — \(alive) alive, \(dead) dead", category: .network, level: alive > 0 ? .success : .error)
    }

    func resetCircuitBreakers() {
        circuitBreakers.removeAll()
        persistCircuitBreakers()
        logger.log("Hybrid: all circuit breakers reset", category: .network, level: .info)
    }

    func resetStickyPreferences() {
        stickyMethodPerHost.removeAll()
        stickyTimestamps.removeAll()
        logger.log("Hybrid: sticky method preferences cleared", category: .network, level: .info)
    }

    func forceMethod(_ method: HybridMethod, for target: ProxyRotationService.ProxyTarget) -> ActiveNetworkConfig {
        var cb = circuitBreakers[method] ?? CircuitBreakerState()
        cb.state = .closed
        cb.consecutiveFailures = 0
        circuitBreakers[method] = cb

        let config = resolveConfig(for: method, target: target)
        logger.log("Hybrid: FORCED \(method.rawValue) → \(config.label) (circuit breaker reset)", category: .network, level: .info)
        return config
    }

    // MARK: - Summary

    var hybridSummary: String {
        let methods = HybridMethod.allCases.filter { methodHealthScores[$0] != nil }
        if methods.isEmpty { return "No data" }
        return methods.sorted(by: { $0.priority < $1.priority }).map { m in
            let score = Int((methodHealthScores[m] ?? 0.5) * 100)
            let cb = circuitBreakers[m]
            let cbLabel = cb?.isOpen == true ? " [OPEN]" : (cb?.isHalfOpen == true ? " [HALF]" : "")
            return "\(m.rawValue):\(score)%\(cbLabel)"
        }.joined(separator: " | ")
    }

    var circuitBreakerSummary: String {
        let active = circuitBreakers.filter { $0.value.isOpen || $0.value.isHalfOpen }
        if active.isEmpty { return "All closed" }
        return active.map { "\($0.key.rawValue):\($0.value.state.rawValue) (trips:\($0.value.totalTrips))" }.joined(separator: ", ")
    }

    var methodReliability: [(method: HybridMethod, stat: MethodStat, score: Double, cbState: String)] {
        HybridMethod.allCases.compactMap { method in
            guard let stat = methodStats[method] else { return nil }
            let score = methodHealthScores[method] ?? 0.5
            let cbState = circuitBreakers[method]?.state.rawValue ?? "closed"
            return (method, stat, score, cbState)
        }.sorted { $0.score > $1.score }
    }

    // MARK: - Circuit Breaker Logic

    private func updateCircuitBreaker(method: HybridMethod, success: Bool) {
        var cb = circuitBreakers[method] ?? CircuitBreakerState()

        switch cb.state {
        case .closed:
            if success {
                cb.consecutiveFailures = max(0, cb.consecutiveFailures - 1)
            } else {
                cb.consecutiveFailures += 1
                if cb.consecutiveFailures >= circuitBreakerThreshold {
                    cb.state = .open
                    cb.lastTrippedAt = Date()
                    cb.totalTrips += 1
                    logger.log("Hybrid: CIRCUIT BREAKER TRIPPED for \(method.rawValue) — \(cb.consecutiveFailures) consecutive failures (trip #\(cb.totalTrips))", category: .network, level: .error)
                }
            }

        case .open:
            break

        case .halfOpen:
            cb.halfOpenProbes += 1
            if success {
                cb.state = .closed
                cb.consecutiveFailures = 0
                cb.halfOpenProbes = 0
                logger.log("Hybrid: circuit breaker CLOSED for \(method.rawValue) — half-open probe succeeded", category: .network, level: .success)
            } else if cb.halfOpenProbes >= halfOpenMaxProbes {
                cb.state = .open
                cb.lastTrippedAt = Date()
                cb.totalTrips += 1
                cb.halfOpenProbes = 0
                logger.log("Hybrid: circuit breaker RE-TRIPPED for \(method.rawValue) — half-open probes failed (trip #\(cb.totalTrips))", category: .network, level: .error)
            }
        }

        circuitBreakers[method] = cb
    }

    private func transitionHalfOpenBreakers() {
        let now = Date()
        for (method, var cb) in circuitBreakers {
            if cb.isOpen, let tripped = cb.lastTrippedAt, now.timeIntervalSince(tripped) >= circuitBreakerCooldownSeconds {
                cb.state = .halfOpen
                cb.halfOpenProbes = 0
                circuitBreakers[method] = cb
                logger.log("Hybrid: circuit breaker → HALF-OPEN for \(method.rawValue) (cooldown expired)", category: .network, level: .info)
            }
        }
    }

    private func isMethodAvailable(_ method: HybridMethod) -> Bool {
        let cb = circuitBreakers[method] ?? CircuitBreakerState()
        if cb.isOpen {
            if let tripped = cb.lastTrippedAt, Date().timeIntervalSince(tripped) >= circuitBreakerCooldownSeconds {
                var updated = cb
                updated.state = .halfOpen
                updated.halfOpenProbes = 0
                circuitBreakers[method] = updated
                return true
            }
            return false
        }
        return true
    }

    // MARK: - Method Selection with Exploration

    private func selectMethodWithExploration(methods: [HybridMethod], host: String) -> HybridMethod {
        if let stickyTimestamp = stickyTimestamps[host],
           Date().timeIntervalSince(stickyTimestamp) < stickyDecayAfterSeconds,
           let sticky = stickyMethodPerHost[host],
           methods.contains(sticky),
           isMethodAvailable(sticky) {
            let stat = methodStats[sticky]
            if stat?.isReliable == true {
                return sticky
            }
        }

        let explorationRate: Double = 0.15
        if Double.random(in: 0..<1) < explorationRate, methods.count > 1 {
            let nonTop = Array(methods.dropFirst())
            if let explored = nonTop.randomElement() {
                logger.log("Hybrid: exploration pick → \(explored.rawValue) (bypassing top-ranked \(methods.first?.rawValue ?? "?"))", category: .network, level: .debug)
                return explored
            }
        }

        return methods[sessionIndex % methods.count]
    }

    // MARK: - Config Validation

    private func validateConfig(_ config: ActiveNetworkConfig, method: HybridMethod, target: ProxyRotationService.ProxyTarget) -> ActiveNetworkConfig {
        switch config {
        case .direct:
            if targetRequiresProxy(target) {
                logger.log("Hybrid: FAIL-CLOSED — \(method.rawValue) resolved to .direct for proxy-required \(target.rawValue), blocking", category: .network, level: .error)
                return failClosedConfigForTarget(target)
            }
            return config

        case .socks5(let proxy):
            if proxy.host == "127.0.0.1" && proxy.port == 9 {
                return config
            }
            if proxy.host.isEmpty || proxy.port <= 0 || proxy.port > 65535 {
                logger.log("Hybrid: INVALID proxy config \(proxy.host):\(proxy.port) from \(method.rawValue) — fail-closed", category: .network, level: .error)
                return failClosedConfigForTarget(target)
            }
            return config

        case .wireGuardDNS, .openVPNProxy:
            return config
        }
    }

    private func failClosedConfigForTarget(_ target: ProxyRotationService.ProxyTarget) -> ActiveNetworkConfig {
        if targetRequiresProxy(target) {
            let cascaded = cascadeFallbackProxy(target: target)
            if case .direct = cascaded {
                logger.log("Hybrid: ABSOLUTE FAIL-CLOSED — no proxy found for \(target.rawValue), applying dead-end proxy to prevent IP leak", category: .network, level: .critical)
                return .socks5(failClosedProxy)
            }
            return cascaded
        }
        return .direct
    }

    // MARK: - Mid-Batch Reranking

    private func checkMidBatchRerank() {
        guard isActive else { return }

        let timeSinceRerank = Date().timeIntervalSince(lastRerankTime)
        guard timeSinceRerank > 15 else { return }

        var needsRerank = false
        for (method, failures) in batchFailureCounts {
            let successes = batchSuccessCounts[method, default: 0]
            let total = failures + successes
            if total >= rerankThreshold && failures > successes * 2 {
                needsRerank = true
                logger.log("Hybrid: mid-batch rerank triggered — \(method.rawValue) failing (\(failures)F/\(successes)S)", category: .network, level: .warning)
                break
            }
        }

        if needsRerank {
            cachedRankedMethods.removeAll()
            cachedRankTarget = nil
            lastRerankTime = Date()
        }
    }

    // MARK: - Health Score Decay

    private func applyHealthDecayIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastDecayTime) >= decayIntervalSeconds else { return }
        lastDecayTime = now

        var decayed = false
        for (method, score) in methodHealthScores {
            let stat = methodStats[method]
            if let lastUsed = stat?.lastUsed, now.timeIntervalSince(lastUsed) > 600 {
                let newScore = score * decayFactor
                if abs(newScore - score) > 0.01 {
                    methodHealthScores[method] = newScore
                    decayed = true
                }
            }
        }

        for (host, timestamp) in stickyTimestamps {
            if now.timeIntervalSince(timestamp) > stickyDecayAfterSeconds {
                stickyMethodPerHost.removeValue(forKey: host)
                stickyTimestamps.removeValue(forKey: host)
            }
        }

        if decayed {
            persistHealthScores()
            logger.log("Hybrid: health scores decayed for stale methods", category: .network, level: .trace)
        }
    }

    // MARK: - Preflight Probing

    nonisolated private func probeMethod(_ method: HybridMethod, target: ProxyRotationService.ProxyTarget) async -> PreflightResult {
        let start = CFAbsoluteTimeGetCurrent()

        switch method {
        case .socks5:
            let proxies = await MainActor.run { proxyService.proxies(for: target).filter { $0.isWorking || $0.lastTested == nil } }
            guard let proxy = proxies.first else {
                return PreflightResult(method: method, alive: false, latencyMs: 0, timestamp: Date())
            }
            let alive = await quickSOCKS5Handshake(host: proxy.host, port: UInt16(proxy.port))
            let latencyMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            return PreflightResult(method: method, alive: alive, latencyMs: latencyMs, timestamp: Date())

        case .wireProxy:
            let isActive = await MainActor.run { WireProxyBridge.shared.isActive && LocalProxyServer.shared.isRunning }
            if isActive {
                let localPort = await MainActor.run { UInt16(LocalProxyServer.shared.localProxyConfig.port) }
                let alive = await quickSOCKS5Handshake(host: "127.0.0.1", port: localPort)
                let latencyMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                return PreflightResult(method: method, alive: alive, latencyMs: latencyMs, timestamp: Date())
            }
            let hasConfigs = await MainActor.run { !proxyService.wgConfigs(for: target).filter({ $0.isEnabled }).isEmpty }
            return PreflightResult(method: method, alive: hasConfigs, latencyMs: 0, timestamp: Date())

        case .openVPN:
            let isActive = await MainActor.run { OpenVPNProxyBridge.shared.isActive }
            if isActive {
                if await MainActor.run(body: { LocalProxyServer.shared.isRunning && LocalProxyServer.shared.openVPNProxyMode }) {
                    let localPort = await MainActor.run { UInt16(LocalProxyServer.shared.localProxyConfig.port) }
                    let alive = await quickSOCKS5Handshake(host: "127.0.0.1", port: localPort)
                    let latencyMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                    return PreflightResult(method: method, alive: alive, latencyMs: latencyMs, timestamp: Date())
                }
                if let bridgeProxy = await MainActor.run(body: { OpenVPNProxyBridge.shared.activeSOCKS5Proxy }) {
                    let alive = await quickSOCKS5Handshake(host: bridgeProxy.host, port: UInt16(bridgeProxy.port))
                    let latencyMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                    return PreflightResult(method: method, alive: alive, latencyMs: latencyMs, timestamp: Date())
                }
            }
            let hasConfigs = await MainActor.run { !proxyService.vpnConfigs(for: target).filter({ $0.isEnabled }).isEmpty }
            return PreflightResult(method: method, alive: hasConfigs, latencyMs: 0, timestamp: Date())

        case .nodeMaven:
            let enabled = await MainActor.run { NodeMavenService.shared.isEnabled }
            return PreflightResult(method: method, alive: enabled, latencyMs: 0, timestamp: Date())

        case .httpsDOH:
            return PreflightResult(method: method, alive: true, latencyMs: 0, timestamp: Date())
        }
    }

    nonisolated private func quickSOCKS5Handshake(host: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port))
            let connection = NWConnection(to: endpoint, using: .tcp)
            let queue = DispatchQueue(label: "hybrid-preflight-\(host)-\(port)")
            var completed = false
            let lock = NSLock()

            func finish(_ result: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !completed else { return }
                completed = true
                continuation.resume(returning: result)
            }

            let timeoutWork = DispatchWorkItem { [weak connection] in
                connection?.cancel()
                finish(false)
            }
            queue.asyncAfter(deadline: .now() + 2.0, execute: timeoutWork)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let greeting = Data([0x05, 0x01, 0x00])
                    connection.send(content: greeting, completion: .contentProcessed { sendError in
                        if sendError != nil {
                            timeoutWork.cancel()
                            connection.cancel()
                            finish(false)
                            return
                        }
                        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { data, _, _, recvError in
                            timeoutWork.cancel()
                            connection.cancel()
                            if recvError != nil {
                                finish(false)
                                return
                            }
                            guard let data, data.count >= 2, data[0] == 0x05 else {
                                finish(false)
                                return
                            }
                            finish(true)
                        }
                    })
                case .failed, .cancelled:
                    timeoutWork.cancel()
                    connection.cancel()
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    // MARK: - Proxy Required

    private static let proxyRequiredTargets: Set<ProxyRotationService.ProxyTarget> = [.joe, .ignition]

    private func targetRequiresProxy(_ target: ProxyRotationService.ProxyTarget) -> Bool {
        Self.proxyRequiredTargets.contains(target)
    }

    // MARK: - Available Methods (Raw + Ranked)

    private func availableMethodsRaw(for target: ProxyRotationService.ProxyTarget) -> [HybridMethod] {
        var available: [HybridMethod] = []

        let wgConfigs = proxyService.wgConfigs(for: target).filter { $0.isEnabled }
        if !wgConfigs.isEmpty { available.append(.wireProxy) }

        if NodeMavenService.shared.isEnabled { available.append(.nodeMaven) }

        let ovpnConfigs = proxyService.vpnConfigs(for: target).filter { $0.isEnabled }
        if !ovpnConfigs.isEmpty { available.append(.openVPN) }

        let socks5 = proxyService.proxies(for: target).filter { $0.isWorking || $0.lastTested == nil }
        if !socks5.isEmpty { available.append(.socks5) }

        if !targetRequiresProxy(target) {
            available.append(.httpsDOH)
        } else if available.isEmpty {
            logger.log("Hybrid: \(target.rawValue) requires proxy but none available — HTTPS/DoH fallback forced (will likely fail)", category: .network, level: .critical)
            available.append(.httpsDOH)
        }

        return available
    }

    private func availableMethodsRankedByAI(for target: ProxyRotationService.ProxyTarget) -> [HybridMethod] {
        if let cached = cachedRankTarget, cached == target, !cachedRankedMethods.isEmpty,
           Date().timeIntervalSince(lastRerankTime) < 30 {
            return cachedRankedMethods
        }

        var available = availableMethodsRaw(for: target)

        available = available.filter { isMethodAvailable($0) }

        if available.isEmpty {
            transitionHalfOpenBreakers()
            available = availableMethodsRaw(for: target).filter { isMethodAvailable($0) }
        }

        if available.isEmpty {
            let raw = availableMethodsRaw(for: target)
            if !raw.isEmpty {
                logger.log("Hybrid: all methods circuit-broken — resetting least-tripped breaker", category: .network, level: .warning)
                let leastTripped = raw.min { (circuitBreakers[$0]?.totalTrips ?? 0) < (circuitBreakers[$1]?.totalTrips ?? 0) }
                if let method = leastTripped {
                    circuitBreakers[method] = CircuitBreakerState()
                    available = [method]
                }
            }
        }

        guard !available.isEmpty else {
            return []
        }

        let prefilteredByPreflight = available.filter { method in
            guard let result = lastPreflightResults[method], !result.isStale else { return true }
            return result.alive
        }
        let effective = prefilteredByPreflight.isEmpty ? available : prefilteredByPreflight

        let finalRanked = effective.sorted { a, b in
            let scoreA = methodHealthScores[a] ?? 0.5
            let scoreB = methodHealthScores[b] ?? 0.5
            if abs(scoreA - scoreB) < 0.05 {
                return a.priority < b.priority
            }
            return scoreA > scoreB
        }

        cachedRankedMethods = finalRanked
        cachedRankTarget = target
        if lastRerankTime == .distantPast { lastRerankTime = Date() }
        let cbInfo = circuitBreakers.filter { $0.value.isOpen || $0.value.isHalfOpen }
        if !cbInfo.isEmpty {
            logger.log("Hybrid: circuit-broken: \(cbInfo.map { "\($0.key.rawValue):\($0.value.state.rawValue)" }.joined(separator: ", "))", category: .network, level: .warning)
        }
        logger.log("Hybrid: \(finalRanked.count) methods ranked — \(finalRanked.map(\.rawValue).joined(separator: ", "))", category: .network, level: .debug)
        return finalRanked
    }

    // MARK: - Config Resolution

    private func resolveConfig(for method: HybridMethod, target: ProxyRotationService.ProxyTarget) -> ActiveNetworkConfig {
        let needsProxy = targetRequiresProxy(target)

        switch method {
        case .wireProxy:
            let wireProxyBridge = WireProxyBridge.shared
            let localProxy = LocalProxyServer.shared
            if wireProxyBridge.isActive, localProxy.isRunning, localProxy.wireProxyMode {
                return .socks5(localProxy.localProxyConfig)
            }
            let configs = proxyService.wgConfigs(for: target).filter { $0.isEnabled }
            let healthResults = NetworkLayerService.shared.wgHealthResults
            let healthyConfigs = configs.filter { healthResults[$0.displayString] != false }
            let pool = healthyConfigs.isEmpty ? configs : healthyConfigs
            if let wg = scoredPick(from: pool) {
                return .wireGuardDNS(wg)
            }
            if needsProxy { return cascadeFallbackProxy(target: target) }
            return .direct

        case .nodeMaven:
            if let proxy = NodeMavenService.shared.generateProxyConfig(sessionId: "hybrid_\(Int(Date().timeIntervalSince1970))_\(sessionIndex)") {
                return .socks5(proxy)
            }
            if needsProxy { return cascadeFallbackProxy(target: target) }
            return .direct

        case .openVPN:
            let ovpnBridge = OpenVPNProxyBridge.shared
            let localProxy = LocalProxyServer.shared
            if ovpnBridge.isActive, localProxy.isRunning, localProxy.openVPNProxyMode {
                return .socks5(localProxy.localProxyConfig)
            }
            if ovpnBridge.isActive, let bridgeProxy = ovpnBridge.activeSOCKS5Proxy {
                return .socks5(bridgeProxy)
            }
            let configs = proxyService.vpnConfigs(for: target).filter { $0.isEnabled }
            let healthResults = NetworkLayerService.shared.ovpnHealthResults
            let healthyConfigs = configs.filter { healthResults[$0.displayString] != false }
            let pool = healthyConfigs.isEmpty ? configs : healthyConfigs
            if let ovpn = scoredPick(from: pool) {
                return .openVPNProxy(ovpn)
            }
            if needsProxy { return cascadeFallbackProxy(target: target) }
            return .direct

        case .socks5:
            let proxies = proxyService.proxies(for: target).filter { $0.isWorking || $0.lastTested == nil }
            let host = hostForTarget(target)
            if let aiPick = aiStrategy.bestProxy(for: host, from: proxies, target: target) {
                return .socks5(aiPick)
            }
            if let proxy = proxies.randomElement() {
                return .socks5(proxy)
            }
            if needsProxy { return cascadeFallbackProxy(target: target) }
            return .direct

        case .httpsDOH:
            return .direct
        }
    }

    private func scoredPick<T>(from configs: [T]) -> T? {
        guard !configs.isEmpty else { return nil }
        if configs.count == 1 { return configs[0] }
        let topCount = max(1, min(3, configs.count))
        return Array(configs.prefix(topCount)).randomElement()
    }

    private func cascadeFallbackProxy(target: ProxyRotationService.ProxyTarget) -> ActiveNetworkConfig {
        let localProxy = LocalProxyServer.shared

        if WireProxyBridge.shared.isActive, localProxy.isRunning, localProxy.wireProxyMode {
            logger.log("Hybrid: cascade fallback → WireProxy for \(target.rawValue)", category: .network, level: .info)
            return .socks5(localProxy.localProxyConfig)
        }

        if OpenVPNProxyBridge.shared.isActive, localProxy.isRunning, localProxy.openVPNProxyMode {
            logger.log("Hybrid: cascade fallback → OpenVPN for \(target.rawValue)", category: .network, level: .info)
            return .socks5(localProxy.localProxyConfig)
        }

        if NodeMavenService.shared.isEnabled,
           let proxy = NodeMavenService.shared.generateProxyConfig(sessionId: "cascade_\(Int(Date().timeIntervalSince1970))") {
            logger.log("Hybrid: cascade fallback → NodeMaven for \(target.rawValue)", category: .network, level: .info)
            return .socks5(proxy)
        }

        let socks5 = proxyService.proxies(for: target).filter { $0.isWorking || $0.lastTested == nil }
        if let proxy = socks5.randomElement() {
            logger.log("Hybrid: cascade fallback → SOCKS5 \(proxy.displayString) for \(target.rawValue)", category: .network, level: .info)
            return .socks5(proxy)
        }

        let wgConfigs = proxyService.wgConfigs(for: target).filter { $0.isEnabled }
        if let wg = wgConfigs.randomElement() {
            logger.log("Hybrid: cascade fallback → WireGuard config for \(target.rawValue)", category: .network, level: .info)
            return .wireGuardDNS(wg)
        }

        let ovpnConfigs = proxyService.vpnConfigs(for: target).filter { $0.isEnabled }
        if let ovpn = ovpnConfigs.randomElement() {
            logger.log("Hybrid: cascade fallback → OpenVPN config for \(target.rawValue)", category: .network, level: .info)
            return .openVPNProxy(ovpn)
        }

        logger.log("Hybrid: TOTAL CASCADE FAILURE for \(target.rawValue) — no proxy available anywhere", category: .network, level: .critical)
        return .direct
    }

    private func hostForTarget(_ target: ProxyRotationService.ProxyTarget) -> String {
        TargetHostResolver.hostname(for: target)
    }

    // MARK: - Health Score

    private func calculateHealthScore(for stat: MethodStat) -> Double {
        let successScore = stat.successRate * 0.40
        let latencyScore = max(0, 1.0 - (Double(stat.avgLatencyMs) / 15000.0)) * 0.20
        let timeoutPenalty = (1.0 - stat.timeoutRate) * 0.10
        let blockPenalty = (1.0 - stat.blockRate) * 0.10

        let recencyBase: Double
        if let last = stat.lastUsed {
            let ageSeconds = Date().timeIntervalSince(last)
            recencyBase = max(0, 1.0 - (ageSeconds / 3600.0))
        } else {
            recencyBase = 0.5
        }
        let recencyScore = recencyBase * 0.10

        let confidenceScore = min(Double(stat.attempts), 5.0) / 5.0 * 0.05

        let stabilityScore: Double
        if stat.consecutiveFailures > 0 {
            stabilityScore = max(0, 1.0 - (Double(stat.consecutiveFailures) / 5.0)) * 0.05
        } else {
            stabilityScore = min(1.0, Double(stat.consecutiveSuccesses) / 5.0) * 0.05
        }

        return min(1.0, max(0, successScore + latencyScore + timeoutPenalty + blockPenalty + recencyScore + confidenceScore + stabilityScore))
    }

    // MARK: - Persistence

    private func persistHealthScores() {
        var dict: [String: Double] = [:]
        for (method, score) in methodHealthScores {
            dict[method.rawValue] = score
        }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: persistKey)
        }
    }

    private func loadHealthScores() {
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let dict = try? JSONDecoder().decode([String: Double].self, from: data) else {
            if let legacyData = UserDefaults.standard.data(forKey: "hybrid_networking_health_v1"),
               let legacyDict = try? JSONDecoder().decode([String: Double].self, from: legacyData) {
                for (key, score) in legacyDict {
                    if let method = HybridMethod(rawValue: key) {
                        methodHealthScores[method] = score
                    }
                }
                persistHealthScores()
                UserDefaults.standard.removeObject(forKey: "hybrid_networking_health_v1")
            }
            return
        }
        for (key, score) in dict {
            if let method = HybridMethod(rawValue: key) {
                methodHealthScores[method] = score
            }
        }
    }

    private let cbPersistKey = "hybrid_circuit_breakers_v1"

    private func persistCircuitBreakers() {
        var dict: [String: [String: Any]] = [:]
        for (method, cb) in circuitBreakers {
            dict[method.rawValue] = [
                "consecutiveFailures": cb.consecutiveFailures,
                "state": cb.state.rawValue,
                "totalTrips": cb.totalTrips,
                "lastTripped": cb.lastTrippedAt?.timeIntervalSince1970 ?? 0
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            UserDefaults.standard.set(data, forKey: cbPersistKey)
        }
    }

    private func loadCircuitBreakers() {
        guard let data = UserDefaults.standard.data(forKey: cbPersistKey),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return }
        for (key, values) in dict {
            guard let method = HybridMethod(rawValue: key) else { continue }
            var cb = CircuitBreakerState()
            cb.consecutiveFailures = values["consecutiveFailures"] as? Int ?? 0
            cb.totalTrips = values["totalTrips"] as? Int ?? 0
            if let stateStr = values["state"] as? String, let state = CircuitBreakerState.CBState(rawValue: stateStr) {
                cb.state = state
            }
            if let ts = values["lastTripped"] as? TimeInterval, ts > 0 {
                cb.lastTrippedAt = Date(timeIntervalSince1970: ts)
            }
            if cb.isOpen, let tripped = cb.lastTrippedAt, Date().timeIntervalSince(tripped) > circuitBreakerCooldownSeconds * 3 {
                cb.state = .closed
                cb.consecutiveFailures = 0
            }
            circuitBreakers[method] = cb
        }
    }
}
