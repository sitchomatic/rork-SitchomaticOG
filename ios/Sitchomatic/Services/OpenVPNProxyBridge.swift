@preconcurrency import Foundation
@preconcurrency import Network
import Observation

nonisolated enum OpenVPNBridgeStatus: String, Sendable {
    case stopped = "Stopped"
    case connecting = "Connecting"
    case established = "Established"
    case reconnecting = "Reconnecting"
    case failed = "Failed"
}

nonisolated struct OpenVPNBridgeStats: Sendable {
    var connectionsServed: Int = 0
    var connectionsFailed: Int = 0
    var bytesUpstream: UInt64 = 0
    var bytesDownstream: UInt64 = 0
    var handshakeLatencyMs: Int = 0
    var lastValidatedAt: Date?
    var consecutiveFailures: Int = 0
    var resolutionSource: String = ""
    var endpointPoolSize: Int = 0
    var activeEndpointIndex: Int = 0
    var poolRotations: Int = 0
    var intelServerLoad: Int = -1
    var tcpSessionsCreated: Int = 0
    var tcpSessionsActive: Int = 0
    var dnsQueriesTotal: Int = 0
    var apiReconnects: Int = 0
}

@Observable
@MainActor
class OpenVPNProxyBridge {
    static let shared = OpenVPNProxyBridge()

    private(set) var status: OpenVPNBridgeStatus = .stopped
    private(set) var stats: OpenVPNBridgeStats = OpenVPNBridgeStats()
    private(set) var lastError: String?
    private(set) var connectedSince: Date?
    private(set) var activeConfig: OpenVPNConfig?
    private(set) var activeSOCKS5Proxy: ProxyConfig?
    private(set) var activeWGConfig: WireGuardConfig?

    private let wgSession = WireGuardSession()
    private let tcpManager = TCPSessionManager()
    private let dnsResolver = TunnelDNSResolver()
    private let logger = DebugLogger.shared
    private let intel = NordServerIntelligence.shared

    private var localIP: UInt32 = 0
    private var activeCountryId: Int?
    private var tunnelConnections: [UUID: OpenVPNTunnelConnection] = [:]
    private var healthCheckTimer: Timer?
    private let healthCheckInterval: TimeInterval = 12
    private var reconnectAttempts: Int = 0
    private let maxReconnectAttempts: Int = 5
    private var isReconnecting: Bool = false

    var isActive: Bool { status == .established }

    var activeEndpointCount: Int {
        isActive ? 1 : 0
    }

    // MARK: - Start

    func start(with config: OpenVPNConfig) async {
        guard status == .stopped || status == .failed else { return }

        activeConfig = config
        activeCountryId = config.nordCountryId
        status = .connecting
        lastError = nil
        reconnectAttempts = 0

        let startTime = CFAbsoluteTimeGetCurrent()

        guard let wgConfig = await resolveWireGuardConfig(for: config) else {
            status = .failed
            lastError = "Could not resolve WireGuard server for \(config.serverName)"
            logger.log("OpenVPNBridge: FAILED — no WireGuard server found for country \(config.nordCountryCode ?? "unknown")", category: .vpn, level: .error)
            return
        }

        activeWGConfig = wgConfig
        let success = await startWireGuardTunnel(wgConfig)
        let latencyMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

        if success {
            status = .established
            connectedSince = Date()
            stats.handshakeLatencyMs = latencyMs
            stats.lastValidatedAt = Date()
            stats.consecutiveFailures = 0
            stats.resolutionSource = "WG-tunnel(\(wgConfig.serverName))"
            stats.endpointPoolSize = 1
            stats.intelServerLoad = intel.serverHealth(hostname: wgConfig.endpointHost)?.load ?? -1
            dnsResolver.startBackgroundRefresh()
            intel.recordSuccess(hostname: wgConfig.endpointHost, latencyMs: latencyMs)
            intel.startMonitoring()
            startHealthCheck()
            logger.log("OpenVPNBridge: ESTABLISHED via WG tunnel → \(wgConfig.peerEndpoint) for OVPN region \(config.serverName) (\(latencyMs)ms)", category: .vpn, level: .success)
        } else {
            if reconnectAttempts < maxReconnectAttempts {
                logger.log("OpenVPNBridge: initial tunnel failed for \(wgConfig.serverName) — trying alternate server", category: .vpn, level: .warning)
                intel.recordFailure(hostname: wgConfig.endpointHost)
                await retryWithAlternateServer(config: config)
            } else {
                status = .failed
                lastError = wgSession.lastError ?? "WireGuard tunnel handshake timeout"
                logger.log("OpenVPNBridge: FAILED — \(lastError ?? "unknown error")", category: .vpn, level: .error)
            }
        }
    }

    // MARK: - Stop

    func stop() {
        stopHealthCheck()
        dnsResolver.stopBackgroundRefresh()

        for conn in tunnelConnections.values {
            conn.cancel()
        }
        tunnelConnections.removeAll()

        tcpManager.shutdown()
        dnsResolver.clearCache()
        wgSession.disconnect()

        status = .stopped
        connectedSince = nil
        activeConfig = nil
        activeWGConfig = nil
        activeSOCKS5Proxy = nil
        activeCountryId = nil
        localIP = 0
        isReconnecting = false
        stats = OpenVPNBridgeStats()
        logger.log("OpenVPNBridge: stopped", category: .vpn, level: .info)
    }

    // MARK: - Reconnect

    func reconnectPreservingSessions() async {
        guard let config = activeConfig, !isReconnecting else { return }
        isReconnecting = true
        status = .reconnecting

        let preservedStats = stats
        logger.log("OpenVPNBridge: reconnecting with preserved stats", category: .vpn, level: .warning)

        for conn in tunnelConnections.values {
            conn.cancel()
        }
        tunnelConnections.removeAll()
        tcpManager.shutdown()
        dnsResolver.stopBackgroundRefresh()
        wgSession.disconnect()

        let jitter = Double.random(in: 0...1.0)
        let backoffDelay = min(Double(reconnectAttempts + 1) * 1.5 + jitter, 10.0)
        try? await Task.sleep(for: .seconds(backoffDelay))

        reconnectAttempts += 1
        isReconnecting = false

        if let countryId = activeCountryId, reconnectAttempts >= 1 {
            let failedHost = activeWGConfig?.endpointHost ?? ""
            if let freshServer = await intel.bestWireGuardServer(forCountryId: countryId, excluding: [failedHost]),
               let freshConfig = intel.generateWireGuardConfig(from: freshServer) {
                stats = preservedStats
                stats.apiReconnects += 1
                logger.log("OpenVPNBridge: NordIntel found fresh server \(freshServer.hostname) (load: \(freshServer.load)%) — replacing \(failedHost)", category: .vpn, level: .info)
                activeWGConfig = freshConfig
                let success = await startWireGuardTunnel(freshConfig)
                if success {
                    status = .established
                    stats.lastValidatedAt = Date()
                    stats.consecutiveFailures = 0
                    stats.resolutionSource = "WG-tunnel(\(freshServer.hostname), load:\(freshServer.load)%)"
                    stats.intelServerLoad = freshServer.load
                    dnsResolver.startBackgroundRefresh()
                    intel.recordSuccess(hostname: freshServer.hostname, latencyMs: 0)
                    startHealthCheck()
                    logger.log("OpenVPNBridge: reconnect SUCCEEDED via \(freshServer.hostname)", category: .vpn, level: .success)
                    return
                }
            }
        }

        await start(with: config)

        if status != .established && reconnectAttempts < maxReconnectAttempts {
            await reconnectPreservingSessions()
        }
    }

    func invalidateRegionCache() {
        logger.log("OpenVPNBridge: region cache cleared (no-op with WG tunnel mode)", category: .vpn, level: .debug)
    }

    // MARK: - Connection Handling

    func handleSOCKS5Connection(
        id: UUID,
        clientConnection: NWConnection,
        targetHost: String,
        targetPort: UInt16,
        queue: DispatchQueue,
        server: LocalProxyServer
    ) {
        guard status == .established else {
            logger.log("OpenVPNBridge: rejecting connection — tunnel not established", category: .vpn, level: .warning)
            return
        }

        stats.connectionsServed += 1

        let tunnelConn = OpenVPNTunnelConnection(
            id: id,
            clientConnection: clientConnection,
            targetHost: targetHost,
            targetPort: targetPort,
            queue: queue,
            server: server,
            bridge: self
        )

        tunnelConnections[id] = tunnelConn
        tunnelConn.start()
    }

    func createTCPSession(destinationIP: UInt32, destinationPort: UInt16) -> TCPSession {
        stats.tcpSessionsCreated += 1
        stats.tcpSessionsActive = tcpManager.activeSessionCount + 1
        return tcpManager.createSession(destinationIP: destinationIP, destinationPort: destinationPort)
    }

    func initiateConnection(_ session: TCPSession) {
        tcpManager.initiateConnection(session)
    }

    func sendData(_ session: TCPSession, data: Data) {
        stats.bytesUpstream += UInt64(data.count)
        tcpManager.sendData(session, data: data)
    }

    func closeSession(_ session: TCPSession) {
        tcpManager.closeSession(session)
        stats.tcpSessionsActive = tcpManager.activeSessionCount
    }

    func resetSession(_ session: TCPSession) {
        tcpManager.sendReset(session)
        stats.tcpSessionsActive = tcpManager.activeSessionCount
    }

    func resolveHostname(_ hostname: String) async -> UInt32? {
        stats.dnsQueriesTotal += 1
        return await dnsResolver.resolve(hostname)
    }

    func connectionFinished(id: UUID, hadError: Bool) {
        tunnelConnections.removeValue(forKey: id)
        if hadError {
            stats.connectionsFailed += 1
        }
        stats.tcpSessionsActive = tcpManager.activeSessionCount
    }

    // MARK: - Legacy Compat (used by callers that haven't been updated)

    func nextEndpoint() -> ProxyConfig? { nil }
    func recordEndpointServed(proxy: ProxyConfig) { stats.connectionsServed += 1 }
    func recordEndpointFailed(proxy: ProxyConfig) { stats.connectionsFailed += 1; stats.consecutiveFailures += 1 }
    func recordConnectionServed() { stats.connectionsServed += 1 }
    func recordConnectionFailed() { stats.connectionsFailed += 1; stats.consecutiveFailures += 1 }
    func recordBytes(up: UInt64, down: UInt64) { stats.bytesUpstream += up; stats.bytesDownstream += down }

    // MARK: - WireGuard Tunnel Setup

    private func startWireGuardTunnel(_ config: WireGuardConfig) async -> Bool {
        let address = config.interfaceAddress.split(separator: "/").first.map(String.init) ?? config.interfaceAddress
        guard let ip = IPv4Packet.ipFromString(address) else {
            lastError = "Invalid interface address: \(config.interfaceAddress)"
            return false
        }
        localIP = ip

        tcpManager.configure(localIP: localIP)
        tcpManager.sendPacketHandler = { [weak self] packet in
            self?.wgSession.sendPacket(packet)
        }

        let dnsServer = config.interfaceDNS.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "1.1.1.1"
        dnsResolver.configure(dnsServer: dnsServer, sourceIP: localIP)
        dnsResolver.sendPacketHandler = { [weak self] packet in
            self?.wgSession.sendPacket(packet)
        }

        wgSession.onPacketReceived = { [weak self] ipData in
            self?.handleTunnelPacket(ipData)
        }

        let configured = wgSession.configure(
            privateKey: config.interfacePrivateKey,
            peerPublicKey: config.peerPublicKey,
            preSharedKey: config.peerPreSharedKey,
            endpoint: config.peerEndpoint,
            keepalive: config.peerPersistentKeepalive ?? 25
        )

        guard configured else {
            lastError = wgSession.lastError ?? "Configuration failed"
            return false
        }

        await wgSession.connect()
        try? await Task.sleep(for: .seconds(3))

        if wgSession.isEstablished {
            return true
        }

        try? await Task.sleep(for: .seconds(3))
        return wgSession.isEstablished
    }

    private func handleTunnelPacket(_ ipData: Data) {
        guard let ipPacket = IPv4Packet.parse(ipData) else { return }

        if ipPacket.header.isUDP {
            dnsResolver.handleIncomingPacket(ipData)
            return
        }

        if ipPacket.header.isTCP {
            stats.bytesDownstream += UInt64(ipData.count)
            tcpManager.handleIncomingPacket(ipData)
            return
        }
    }

    // MARK: - WireGuard Server Resolution

    private func resolveWireGuardConfig(for config: OpenVPNConfig) async -> WireGuardConfig? {
        guard let countryId = config.nordCountryId else {
            logger.log("OpenVPNBridge: cannot determine country from OVPN config \(config.fileName)", category: .vpn, level: .error)
            return nil
        }

        if let server = await intel.bestWireGuardServer(forCountryId: countryId),
           let wgConfig = intel.generateWireGuardConfig(from: server) {
            logger.log("OpenVPNBridge: resolved WG server \(server.hostname) (load: \(server.load)%) for country \(countryId)", category: .vpn, level: .info)
            return wgConfig
        }

        let nordService = NordVPNService.shared
        let servers = await nordService.fetchRecommendedServers(countryId: countryId, technology: "wireguard_udp", limit: 3)
        for server in servers {
            if let publicKey = server.publicKey {
                let privateKey = nordService.privateKey
                guard !privateKey.isEmpty else {
                    logger.log("OpenVPNBridge: no NordVPN private key available", category: .vpn, level: .error)
                    return nil
                }
                let endpoint = "\(server.station):51820"
                let rawContent = "[Interface]\nPrivateKey = \(privateKey)\nAddress = 10.5.0.2/32\nDNS = 103.86.96.100, 103.86.99.100\n\n[Peer]\nPublicKey = \(publicKey)\nAllowedIPs = 0.0.0.0/0\nEndpoint = \(endpoint)\nPersistentKeepalive = 25"

                let wgConfig = WireGuardConfig(
                    fileName: server.hostname,
                    interfaceAddress: "10.5.0.2/32",
                    interfacePrivateKey: privateKey,
                    interfaceDNS: "103.86.96.100, 103.86.99.100",
                    interfaceMTU: nil,
                    peerPublicKey: publicKey,
                    peerPreSharedKey: nil,
                    peerEndpoint: endpoint,
                    peerAllowedIPs: "0.0.0.0/0",
                    peerPersistentKeepalive: 25,
                    rawContent: rawContent
                )
                logger.log("OpenVPNBridge: resolved WG config from NordAPI for \(server.hostname)", category: .vpn, level: .info)
                return wgConfig
            }
        }

        logger.log("OpenVPNBridge: no WireGuard servers found for country \(countryId)", category: .vpn, level: .error)
        return nil
    }

    private func retryWithAlternateServer(config: OpenVPNConfig) async {
        guard let countryId = config.nordCountryId else { return }
        let failedHost = activeWGConfig?.endpointHost ?? ""

        for attempt in 1...3 {
            reconnectAttempts += 1
            try? await Task.sleep(for: .seconds(Double(attempt) * 0.5 + 0.5))

            if let server = await intel.bestWireGuardServer(forCountryId: countryId, excluding: [failedHost]),
               let wgConfig = intel.generateWireGuardConfig(from: server) {
                activeWGConfig = wgConfig
                let success = await startWireGuardTunnel(wgConfig)
                if success {
                    let latencyMs = stats.handshakeLatencyMs
                    status = .established
                    connectedSince = Date()
                    stats.lastValidatedAt = Date()
                    stats.consecutiveFailures = 0
                    stats.resolutionSource = "WG-tunnel(\(server.hostname), load:\(server.load)%)"
                    stats.intelServerLoad = server.load
                    stats.apiReconnects += 1
                    dnsResolver.startBackgroundRefresh()
                    intel.recordSuccess(hostname: server.hostname, latencyMs: latencyMs)
                    intel.startMonitoring()
                    startHealthCheck()
                    logger.log("OpenVPNBridge: retry \(attempt) SUCCEEDED via \(server.hostname)", category: .vpn, level: .success)
                    return
                }
                intel.recordFailure(hostname: server.hostname)
            }
        }

        status = .failed
        lastError = "All WireGuard server alternatives exhausted for \(config.serverName)"
        logger.log("OpenVPNBridge: FAILED after all retries — \(lastError ?? "unknown error")", category: .vpn, level: .error)
    }

    // MARK: - Health Check

    private func startHealthCheck() {
        stopHealthCheck()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: healthCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkTunnelHealth()
            }
        }
    }

    private func stopHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }

    private func checkTunnelHealth() {
        guard status == .established else { return }

        if wgSession.isEstablished {
            stats.lastValidatedAt = Date()
            stats.consecutiveFailures = 0
        } else {
            stats.consecutiveFailures += 1
            if let wgConfig = activeWGConfig {
                intel.recordFailure(hostname: wgConfig.endpointHost)
            }
            logger.log("OpenVPNBridge: health check detected tunnel DOWN (consecutive: \(stats.consecutiveFailures))", category: .vpn, level: .error)
            Task {
                await reconnectPreservingSessions()
            }
        }
    }

    // MARK: - Display

    var uptimeString: String {
        guard let since = connectedSince else { return "--:--" }
        let elapsed = Int(Date().timeIntervalSince(since))
        let hrs = elapsed / 3600
        let mins = (elapsed % 3600) / 60
        let secs = elapsed % 60
        if hrs > 0 { return String(format: "%d:%02d:%02d", hrs, mins, secs) }
        return String(format: "%d:%02d", mins, secs)
    }

    var statusLabel: String {
        guard let wgConfig = activeWGConfig else { return status.rawValue }
        let loadInfo = stats.intelServerLoad >= 0 ? " (load: \(stats.intelServerLoad)%)" : ""
        return "\(status.rawValue) → \(wgConfig.serverName)\(loadInfo)"
    }

    var activeProxyLabel: String? {
        guard let wgConfig = activeWGConfig else { return nil }
        return "WG:\(wgConfig.serverName)"
    }

    var resolutionSourceLabel: String {
        stats.resolutionSource.isEmpty ? "—" : stats.resolutionSource
    }

    var poolSummary: String {
        guard isActive, let wgConfig = activeWGConfig else { return "No tunnel" }
        let loadStr = stats.intelServerLoad >= 0 ? " load:\(stats.intelServerLoad)%" : ""
        return "WG tunnel → \(wgConfig.serverName)\(loadStr)"
    }
}
