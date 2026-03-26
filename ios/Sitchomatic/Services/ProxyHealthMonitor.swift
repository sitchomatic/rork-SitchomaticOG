@preconcurrency import Foundation
@preconcurrency import Network
import Observation

nonisolated struct UpstreamHealthStatus: Sendable {
    var isHealthy: Bool = false
    var lastChecked: Date?
    var latencyMs: Int?
    var consecutiveFailures: Int = 0
    var totalChecks: Int = 0
    var totalFailures: Int = 0
    var lastFailureReason: String?
}

nonisolated struct ProxyHealthEvent: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let upstream: String
    let isHealthy: Bool
    let latencyMs: Int?
    let detail: String

    init(id: UUID = UUID(), timestamp: Date = Date(), upstream: String, isHealthy: Bool, latencyMs: Int? = nil, detail: String) {
        self.id = id
        self.timestamp = timestamp
        self.upstream = upstream
        self.isHealthy = isHealthy
        self.latencyMs = latencyMs
        self.detail = detail
    }
}

@Observable
@MainActor
class ProxyHealthMonitor {
    static let shared = ProxyHealthMonitor()

    private(set) var upstreamHealth: UpstreamHealthStatus = UpstreamHealthStatus()
    private(set) var isMonitoring: Bool = false
    private(set) var healthLog: [ProxyHealthEvent] = []

    var checkIntervalSeconds: TimeInterval = 30
    var maxConsecutiveFailures: Int = 3
    var healthCheckTimeoutSeconds: TimeInterval = 10
    var autoFailoverEnabled: Bool = true {
        didSet { persistSettings() }
    }

    private var monitorTimer: Timer?
    private let logger = DebugLogger.shared
    private let queue = DispatchQueue(label: "proxy-health-monitor", qos: .utility)
    private let settingsKey = "proxy_health_monitor_v1"

    private var currentUpstream: ProxyConfig?
    private var onFailoverNeeded: (() -> Void)?

    init() {
        loadSettings()
    }

    func startMonitoring(upstream: ProxyConfig?, onFailover: @escaping () -> Void) {
        stopMonitoring()
        currentUpstream = upstream
        onFailoverNeeded = onFailover
        isMonitoring = true
        upstreamHealth = UpstreamHealthStatus()

        guard upstream != nil else {
            upstreamHealth.isHealthy = true
            logger.log("HealthMonitor: no upstream — direct mode, marked healthy", category: .proxy, level: .info)
            return
        }

        scheduleHealthCheck()
        Task { await performHealthCheck() }

        logger.log("HealthMonitor: started monitoring upstream \(upstream?.displayString ?? "direct") every \(Int(checkIntervalSeconds))s", category: .proxy, level: .info)
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        isMonitoring = false
        onFailoverNeeded = nil
        logger.log("HealthMonitor: stopped", category: .proxy, level: .info)
    }

    func updateUpstream(_ upstream: ProxyConfig?) {
        currentUpstream = upstream
        upstreamHealth = UpstreamHealthStatus()
        if isMonitoring {
            Task { await performHealthCheck() }
        }
    }

    func forceCheck() async {
        await performHealthCheck()
    }

    private func scheduleHealthCheck() {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: checkIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performHealthCheck()
            }
        }
    }

    private func performHealthCheck() async {
        guard let upstream = currentUpstream else {
            upstreamHealth.isHealthy = true
            upstreamHealth.lastChecked = Date()
            return
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let result = await testSOCKS5Connectivity(host: upstream.host, port: UInt16(upstream.port), username: upstream.username, password: upstream.password)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let latencyMs = Int(elapsed * 1000)

        upstreamHealth.totalChecks += 1
        upstreamHealth.lastChecked = Date()
        upstreamHealth.latencyMs = latencyMs

        if result.success {
            upstreamHealth.isHealthy = true
            upstreamHealth.consecutiveFailures = 0
            upstreamHealth.lastFailureReason = nil

            let event = ProxyHealthEvent(
                upstream: upstream.displayString,
                isHealthy: true,
                latencyMs: latencyMs,
                detail: "OK (\(latencyMs)ms)"
            )
            appendEvent(event)
        } else {
            upstreamHealth.consecutiveFailures += 1
            upstreamHealth.totalFailures += 1
            upstreamHealth.lastFailureReason = result.error

            let event = ProxyHealthEvent(
                upstream: upstream.displayString,
                isHealthy: false,
                latencyMs: nil,
                detail: result.error ?? "Connection failed"
            )
            appendEvent(event)

            logger.log("HealthMonitor: upstream \(upstream.displayString) FAILED (\(upstreamHealth.consecutiveFailures)/\(maxConsecutiveFailures)) — \(result.error ?? "unknown")", category: .proxy, level: .warning)

            if upstreamHealth.consecutiveFailures >= maxConsecutiveFailures {
                upstreamHealth.isHealthy = false
                if autoFailoverEnabled {
                    logger.log("HealthMonitor: upstream DEAD after \(maxConsecutiveFailures) failures — triggering failover", category: .proxy, level: .error)
                    onFailoverNeeded?()
                }
            }
        }
    }

    private func testSOCKS5Connectivity(host: String, port: UInt16, username: String?, password: String?) async -> (success: Bool, error: String?) {
        let handshakeResult = await testSOCKS5Handshake(host: host, port: port)
        guard handshakeResult.success else { return handshakeResult }

        let httpResult = await testHTTPViaSocks5(host: host, port: port, username: username, password: password)
        return httpResult
    }

    private func testSOCKS5Handshake(host: String, port: UInt16) async -> (success: Bool, error: String?) {
        let timeout = self.healthCheckTimeoutSeconds
        let testQueue = self.queue
        return await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port))
            let connection = NWConnection(to: endpoint, using: .tcp)

            let completedBox = UnsafeSendableBox(false)
            let timeoutWork = DispatchWorkItem { [weak connection] in
                guard !completedBox.value else { return }
                completedBox.value = true
                connection?.cancel()
                continuation.resume(returning: (false, "Timeout (\(Int(timeout))s)"))
            }
            testQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let greeting = Data([0x05, 0x01, 0x00])
                    connection.send(content: greeting, completion: .contentProcessed { sendError in
                        if let sendError {
                            guard !completedBox.value else { return }
                            completedBox.value = true
                            timeoutWork.cancel()
                            connection.cancel()
                            continuation.resume(returning: (false, "Send failed: \(sendError.localizedDescription)"))
                            return
                        }
                        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { data, _, _, recvError in
                            guard !completedBox.value else { return }
                            completedBox.value = true
                            timeoutWork.cancel()
                            connection.cancel()

                            if let recvError {
                                continuation.resume(returning: (false, "Recv failed: \(recvError.localizedDescription)"))
                                return
                            }
                            guard let data, data.count >= 2, data[0] == 0x05 else {
                                continuation.resume(returning: (false, "Invalid SOCKS5 response"))
                                return
                            }
                            continuation.resume(returning: (true, nil))
                        }
                    })

                case .failed(let error):
                    guard !completedBox.value else { return }
                    completedBox.value = true
                    timeoutWork.cancel()
                    connection.cancel()
                    continuation.resume(returning: (false, "Connection failed: \(error.localizedDescription)"))

                case .cancelled:
                    guard !completedBox.value else { return }
                    completedBox.value = true
                    timeoutWork.cancel()
                    continuation.resume(returning: (false, "Cancelled"))

                default:
                    break
                }
            }
            connection.start(queue: testQueue)
        }
    }

    private nonisolated func testHTTPViaSocks5(host: String, port: UInt16, username: String?, password: String?) async -> (success: Bool, error: String?) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        var proxyDict: [String: Any] = [
            "SOCKSEnable": 1,
            "SOCKSProxy": host,
            "SOCKSPort": Int(port),
        ]
        if let u = username { proxyDict["SOCKSUser"] = u }
        if let p = password { proxyDict["SOCKSPassword"] = p }
        config.connectionProxyDictionary = proxyDict

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        guard let url = URL(string: "https://api.ipify.org?format=json") else {
            return (false, "Invalid test URL")
        }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 8
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty {
                return (true, nil)
            }
            return (false, "HTTP status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        } catch {
            return (false, "HTTP test failed: \(error.localizedDescription)")
        }
    }

    private func appendEvent(_ event: ProxyHealthEvent) {
        healthLog.insert(event, at: 0)
        if healthLog.count > 50 {
            healthLog = Array(healthLog.prefix(50))
        }
    }

    var healthSummary: String {
        if !isMonitoring { return "Not monitoring" }
        guard let upstream = currentUpstream else { return "Direct (no upstream)" }
        if upstreamHealth.isHealthy {
            let latency = upstreamHealth.latencyMs.map { "\($0)ms" } ?? "--"
            return "\(upstream.displayString) — Healthy (\(latency))"
        }
        return "\(upstream.displayString) — UNHEALTHY (\(upstreamHealth.consecutiveFailures) fails)"
    }

    var averageLatencyMs: Int? {
        let recentHealthy = healthLog.prefix(10).filter { $0.isHealthy }
        guard !recentHealthy.isEmpty else { return nil }
        let totalLatency = recentHealthy.compactMap { $0.latencyMs }.reduce(0, +)
        let count = recentHealthy.compactMap { $0.latencyMs }.count
        guard count > 0 else { return nil }
        return totalLatency / count
    }

    var successRate: Double {
        guard upstreamHealth.totalChecks > 0 else { return 0 }
        return Double(upstreamHealth.totalChecks - upstreamHealth.totalFailures) / Double(upstreamHealth.totalChecks) * 100
    }

    private func persistSettings() {
        let dict: [String: Any] = [
            "autoFailover": autoFailoverEnabled,
            "checkInterval": checkIntervalSeconds,
            "maxFailures": maxConsecutiveFailures,
        ]
        UserDefaults.standard.set(dict, forKey: settingsKey)
    }

    private func loadSettings() {
        guard let dict = UserDefaults.standard.dictionary(forKey: settingsKey) else { return }
        if let af = dict["autoFailover"] as? Bool { autoFailoverEnabled = af }
        if let ci = dict["checkInterval"] as? TimeInterval { checkIntervalSeconds = ci }
        if let mf = dict["maxFailures"] as? Int { maxConsecutiveFailures = mf }
    }
}
