import Foundation
import Network
import Observation

nonisolated enum WireProxyStatus: String, Sendable {
    case stopped = "Stopped"
    case connecting = "Connecting"
    case established = "Established"
    case reconnecting = "Reconnecting"
    case failed = "Failed"
}

nonisolated struct WireProxyStats: Sendable {
    var tcpSessionsCreated: Int = 0
    var tcpSessionsActive: Int = 0
    var dnsQueriesTotal: Int = 0
    var dnsCacheHits: Int = 0
    var bytesUpstream: UInt64 = 0
    var bytesDownstream: UInt64 = 0
    var connectionsServed: Int = 0
    var connectionsFailed: Int = 0
    var handshakeLatencyMs: Int = 0
    var consecutiveHealthFailures: Int = 0
    var lastValidatedAt: Date?
    var resolutionSource: String = ""
    var serverLoad: Int = -1
    var apiReconnects: Int = 0
}

struct WireProxyTunnelSlot {
    let index: Int
    let config: WireGuardConfig
    let wgSession: WireGuardSession
    let tcpManager: TCPSessionManager
    let dnsResolver: TunnelDNSResolver
    var localIP: UInt32 = 0
    var isEstablished: Bool = false
    var serverName: String { config.serverName }
}

@Observable
@MainActor
class WireProxyBridge {
    static let shared = WireProxyBridge()

    private(set) var status: WireProxyStatus = .stopped
    private(set) var stats: WireProxyStats = WireProxyStats()
    private(set) var lastError: String?
    private(set) var connectedSince: Date?

    private let wgSession = WireGuardSession()
    private let tcpManager = TCPSessionManager()
    private let dnsResolver = TunnelDNSResolver()
    private let logger = DebugLogger.shared
    private let intel = NordServerIntelligence.shared

    private var activeConfig: WireGuardConfig?
    private var activeCountryId: Int?
    private var localIP: UInt32 = 0
    private var tunnelConnections: [UUID: WireProxyTunnelConnection] = [:]
    private var reconnectAttempts: Int = 0
    private let maxReconnectAttempts: Int = 5
    private var healthCheckTimer: Timer?
    private let healthCheckInterval: TimeInterval = 12
    private var pendingReconnectHosts: [(host: String, port: UInt16)] = []
    private var isReconnecting: Bool = false

    private(set) var tunnelSlots: [WireProxyTunnelSlot] = []
    private var nextSlotIndex: Int = 0
    private(set) var multiTunnelMode: Bool = false
    var activeTunnelCount: Int { tunnelSlots.filter(\.isEstablished).count }

    var isActive: Bool { status == .established }

    func start(with config: WireGuardConfig) async {
        guard status == .stopped || status == .failed else { return }

        activeConfig = config
        activeCountryId = extractNordCountryId(from: config)
        status = .connecting
        lastError = nil
        reconnectAttempts = 0

        let startTime = CFAbsoluteTimeGetCurrent()

        let address = config.interfaceAddress.split(separator: "/").first.map(String.init) ?? config.interfaceAddress
        guard let ip = IPv4Packet.ipFromString(address) else {
            status = .failed
            lastError = "Invalid interface address: \(config.interfaceAddress)"
            return
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
            status = .failed
            lastError = wgSession.lastError ?? "Configuration failed"
            logger.log("WireProxyBridge: configuration failed - \(lastError ?? "")", category: .vpn, level: .error)
            return
        }

        await wgSession.connect()

        try? await Task.sleep(for: .seconds(3))

        let latencyMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

        if wgSession.isEstablished {
            status = .established
            connectedSince = Date()
            reconnectAttempts = 0
            stats.handshakeLatencyMs = latencyMs
            stats.lastValidatedAt = Date()
            stats.resolutionSource = "config(\(config.serverName))"
            stats.serverLoad = intel.serverHealth(hostname: config.endpointHost)?.load ?? -1
            dnsResolver.startBackgroundRefresh()
            intel.recordSuccess(hostname: config.endpointHost, latencyMs: latencyMs)
            intel.startMonitoring()
            logger.log("WireProxyBridge: tunnel ESTABLISHED via \(config.peerEndpoint) (\(latencyMs)ms)", category: .vpn, level: .success)

            let dnsOK = await dnsResolver.verifyDNS()
            if !dnsOK {
                logger.log("WireProxyBridge: DNS verification failed — retrying with backoff", category: .vpn, level: .warning)
                for dnsRetry in 1...3 {
                    try? await Task.sleep(for: .seconds(Double(dnsRetry) * 1.5))
                    let retryOK = await dnsResolver.verifyDNS()
                    if retryOK {
                        logger.log("WireProxyBridge: DNS resolved on retry \(dnsRetry)", category: .vpn, level: .success)
                        break
                    }
                    if dnsRetry == 3 {
                        logger.log("WireProxyBridge: DNS still failing after 3 retries — tunnel may have limited connectivity", category: .vpn, level: .error)
                    }
                }
            }

            startHealthCheck()
        } else {
            logger.log("WireProxyBridge: initial handshake failed — retrying with extended wait", category: .vpn, level: .warning)
            try? await Task.sleep(for: .seconds(3))
            if wgSession.isEstablished {
                status = .established
                connectedSince = Date()
                reconnectAttempts = 0
                stats.handshakeLatencyMs = latencyMs
                stats.lastValidatedAt = Date()
                stats.resolutionSource = "config(\(config.serverName))-extended"
                dnsResolver.startBackgroundRefresh()
                intel.recordSuccess(hostname: config.endpointHost, latencyMs: latencyMs)
                intel.startMonitoring()
                logger.log("WireProxyBridge: tunnel ESTABLISHED on extended wait via \(config.peerEndpoint)", category: .vpn, level: .success)
                startHealthCheck()
            } else {
                intel.recordFailure(hostname: config.endpointHost)
                status = .failed
                lastError = wgSession.lastError ?? "Handshake timeout"
                logger.log("WireProxyBridge: tunnel failed - \(lastError ?? "")", category: .vpn, level: .error)
            }
        }
    }

    func stop() {
        stopHealthCheck()
        dnsResolver.stopBackgroundRefresh()

        for conn in tunnelConnections.values {
            conn.cancel()
        }
        tunnelConnections.removeAll()
        pendingReconnectHosts.removeAll()

        tcpManager.shutdown()
        dnsResolver.clearCache()
        wgSession.disconnect()

        for slot in tunnelSlots {
            slot.dnsResolver.stopBackgroundRefresh()
            slot.tcpManager.shutdown()
            slot.dnsResolver.clearCache()
            slot.wgSession.disconnect()
        }
        tunnelSlots.removeAll()
        nextSlotIndex = 0
        multiTunnelMode = false

        status = .stopped
        connectedSince = nil
        activeConfig = nil
        activeCountryId = nil
        isReconnecting = false
        stats = WireProxyStats()
        logger.log("WireProxyBridge: stopped", category: .vpn, level: .info)
    }

    func reconnectPreservingSessions() async {
        guard let config = activeConfig, !isReconnecting else { return }
        isReconnecting = true
        status = .reconnecting

        pendingReconnectHosts = tunnelConnections.values.map { ($0.targetHost, $0.targetPort) }
        let preservedStats = stats

        logger.log("WireProxyBridge: reconnecting — preserving \(pendingReconnectHosts.count) session targets", category: .vpn, level: .warning)

        for conn in tunnelConnections.values {
            conn.cancel()
        }
        tunnelConnections.removeAll()
        tcpManager.shutdown()
        wgSession.disconnect()

        let jitter = Double.random(in: 0...1.0)
        let backoffDelay = min(Double(reconnectAttempts + 1) * 1.5 + jitter, 10.0)
        try? await Task.sleep(for: .seconds(backoffDelay))

        if let countryId = activeCountryId, reconnectAttempts >= 1 {
            let failedHost = config.endpointHost
            intel.recordFailure(hostname: failedHost)
            logger.log("WireProxyBridge: attempting NordIntel API-driven reconnect for country \(countryId), excluding \(failedHost)", category: .vpn, level: .info)

            if let freshServer = await intel.bestWireGuardServer(forCountryId: countryId, excluding: [failedHost]),
               let freshConfig = intel.generateWireGuardConfig(from: freshServer) {
                stats.apiReconnects += 1
                logger.log("WireProxyBridge: NordIntel found fresh server \(freshServer.hostname) (load: \(freshServer.load)%) — replacing \(failedHost)", category: .vpn, level: .info)
                activeConfig = freshConfig
                isReconnecting = false
                await start(with: freshConfig)
                if status == .established {
                    stats = preservedStats
                    stats.apiReconnects += 1
                    stats.resolutionSource = "NordIntel(\(freshServer.hostname), load:\(freshServer.load)%)"
                    stats.serverLoad = freshServer.load
                    pendingReconnectHosts.removeAll()
                    return
                }
                isReconnecting = true
            }
        }

        let reconnectConfig = activeConfig ?? config
        let address = reconnectConfig.interfaceAddress.split(separator: "/").first.map(String.init) ?? reconnectConfig.interfaceAddress
        guard let ip = IPv4Packet.ipFromString(address) else {
            status = .failed
            lastError = "Invalid interface address on reconnect"
            isReconnecting = false
            return
        }
        localIP = ip

        tcpManager.configure(localIP: localIP)
        tcpManager.sendPacketHandler = { [weak self] packet in
            self?.wgSession.sendPacket(packet)
        }

        wgSession.onPacketReceived = { [weak self] ipData in
            self?.handleTunnelPacket(ipData)
        }

        let configured = wgSession.configure(
            privateKey: reconnectConfig.interfacePrivateKey,
            peerPublicKey: reconnectConfig.peerPublicKey,
            preSharedKey: reconnectConfig.peerPreSharedKey,
            endpoint: reconnectConfig.peerEndpoint,
            keepalive: reconnectConfig.peerPersistentKeepalive ?? 25
        )

        guard configured else {
            status = .failed
            lastError = "Reconnect configuration failed"
            isReconnecting = false
            return
        }

        await wgSession.connect()
        try? await Task.sleep(for: .seconds(3))

        if !wgSession.isEstablished {
            try? await Task.sleep(for: .seconds(3))
        }

        if wgSession.isEstablished {
            status = .established
            stats = preservedStats
            reconnectAttempts = 0
            stats.lastValidatedAt = Date()
            stats.consecutiveHealthFailures = 0
            dnsResolver.startBackgroundRefresh()
            startHealthCheck()
            intel.recordSuccess(hostname: reconnectConfig.endpointHost, latencyMs: 0)

            logger.log("WireProxyBridge: reconnect SUCCEEDED — tunnel re-established, \(pendingReconnectHosts.count) sessions were active", category: .vpn, level: .success)
            pendingReconnectHosts.removeAll()
        } else {
            reconnectAttempts += 1
            intel.recordFailure(hostname: reconnectConfig.endpointHost)
            if reconnectAttempts < maxReconnectAttempts {
                logger.log("WireProxyBridge: reconnect attempt \(reconnectAttempts)/\(maxReconnectAttempts) failed, retrying...", category: .vpn, level: .warning)
                isReconnecting = false
                await reconnectPreservingSessions()
                return
            }
            status = .failed
            lastError = "Reconnect failed after \(maxReconnectAttempts) attempts"
            logger.log("WireProxyBridge: reconnect FAILED after \(maxReconnectAttempts) attempts", category: .vpn, level: .error)
        }

        isReconnecting = false
    }

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

        if multiTunnelMode {
            var anyDown = false
            for (i, slot) in tunnelSlots.enumerated() where slot.isEstablished {
                if !slot.wgSession.isEstablished {
                    logger.log("WireProxyBridge: health check — slot \(i) (\(slot.serverName)) DOWN — attempting API-driven slot reconnect", category: .vpn, level: .error)
                    tunnelSlots[i].isEstablished = false
                    anyDown = true
                    intel.recordFailure(hostname: slot.config.endpointHost)
                    Task {
                        await self.reconnectSlotWithIntel(i)
                    }
                }
            }
            let activeCount = tunnelSlots.filter(\.isEstablished).count
            if activeCount == 0 {
                stats.consecutiveHealthFailures += 1
                logger.log("WireProxyBridge: all multi-tunnel slots DOWN (consecutive: \(stats.consecutiveHealthFailures)) — initiating full reconnect", category: .vpn, level: .error)
                Task { await reconnectPreservingSessions() }
            } else {
                stats.consecutiveHealthFailures = 0
                stats.lastValidatedAt = Date()
                if anyDown {
                    logger.log("WireProxyBridge: \(activeCount)/\(tunnelSlots.count) slots still active", category: .vpn, level: .warning)
                }
            }
            return
        }

        if wgSession.isEstablished {
            stats.lastValidatedAt = Date()
            stats.consecutiveHealthFailures = 0
        } else {
            stats.consecutiveHealthFailures += 1
            if let config = activeConfig {
                intel.recordFailure(hostname: config.endpointHost)
            }
            logger.log("WireProxyBridge: health check detected tunnel DOWN (consecutive: \(stats.consecutiveHealthFailures)) — initiating reconnect", category: .vpn, level: .error)
            Task {
                await reconnectPreservingSessions()
            }
        }
    }

    private func reconnectSlotWithIntel(_ index: Int) async {
        guard index < tunnelSlots.count else { return }
        let slot = tunnelSlots[index]
        let failedHost = slot.config.endpointHost

        slot.wgSession.disconnect()
        slot.tcpManager.shutdown()
        try? await Task.sleep(for: .seconds(2))

        if let countryId = activeCountryId {
            let existingHosts = Set(tunnelSlots.map(\.config.endpointHost))
            if let freshServer = await intel.bestWireGuardServer(forCountryId: countryId, excluding: existingHosts),
               let freshConfig = intel.generateWireGuardConfig(from: freshServer) {
                logger.log("WireProxyBridge: NordIntel replacing slot \(index) (\(failedHost)) with \(freshServer.hostname) (load: \(freshServer.load)%)", category: .vpn, level: .info)
                stats.apiReconnects += 1
                await connectSlot(index, config: freshConfig)
                return
            }
        }

        await connectSlot(index, config: slot.config)
    }

    private func connectSlot(_ index: Int, config: WireGuardConfig) async {
        guard index < tunnelSlots.count else { return }

        let address = config.interfaceAddress.split(separator: "/").first.map(String.init) ?? config.interfaceAddress
        guard let ip = IPv4Packet.ipFromString(address) else { return }

        let slot = tunnelSlots[index]
        slot.tcpManager.configure(localIP: ip)
        let slotSession = slot.wgSession
        slot.tcpManager.sendPacketHandler = { packet in
            slotSession.sendPacket(packet)
        }
        slot.wgSession.onPacketReceived = { [weak self, index] ipData in
            self?.handleMultiTunnelPacket(ipData, slotIndex: index)
        }

        let configured = slot.wgSession.configure(
            privateKey: config.interfacePrivateKey,
            peerPublicKey: config.peerPublicKey,
            preSharedKey: config.peerPreSharedKey,
            endpoint: config.peerEndpoint,
            keepalive: config.peerPersistentKeepalive ?? 25
        )
        guard configured else {
            logger.log("WireProxyBridge: slot \(index) reconnect config failed for \(config.serverName)", category: .vpn, level: .error)
            return
        }

        await slot.wgSession.connect()
        try? await Task.sleep(for: .seconds(3))

        if slot.wgSession.isEstablished {
            tunnelSlots[index].isEstablished = true
            slot.dnsResolver.startBackgroundRefresh()
            intel.recordSuccess(hostname: config.endpointHost, latencyMs: 0)
            logger.log("WireProxyBridge: slot \(index) (\(config.serverName)) RECONNECTED", category: .vpn, level: .success)
        } else {
            intel.recordFailure(hostname: config.endpointHost)
            logger.log("WireProxyBridge: slot \(index) (\(config.serverName)) reconnect FAILED", category: .vpn, level: .error)
        }
    }

    func startMultiple(configs: [WireGuardConfig]) async {
        guard status == .stopped || status == .failed else { return }
        guard configs.count > 1 else {
            if let first = configs.first {
                await start(with: first)
            }
            return
        }

        status = .connecting
        lastError = nil
        reconnectAttempts = 0
        multiTunnelMode = true
        tunnelSlots.removeAll()
        nextSlotIndex = 0

        logger.log("WireProxyBridge: starting multi-tunnel with \(configs.count) WG configs", category: .vpn, level: .info)

        for (i, config) in configs.enumerated() {
            let session = WireGuardSession()
            let tcp = TCPSessionManager()
            let dns = TunnelDNSResolver()

            let address = config.interfaceAddress.split(separator: "/").first.map(String.init) ?? config.interfaceAddress
            guard let ip = IPv4Packet.ipFromString(address) else {
                logger.log("WireProxyBridge: slot \(i) invalid address: \(config.interfaceAddress)", category: .vpn, level: .error)
                continue
            }

            tcp.configure(localIP: ip)
            tcp.sendPacketHandler = { [weak session] packet in
                session?.sendPacket(packet)
            }

            let dnsServer = config.interfaceDNS.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "1.1.1.1"
            dns.configure(dnsServer: dnsServer, sourceIP: ip)
            dns.sendPacketHandler = { [weak session] packet in
                session?.sendPacket(packet)
            }

            session.onPacketReceived = { [weak self, i] ipData in
                self?.handleMultiTunnelPacket(ipData, slotIndex: i)
            }

            let configured = session.configure(
                privateKey: config.interfacePrivateKey,
                peerPublicKey: config.peerPublicKey,
                preSharedKey: config.peerPreSharedKey,
                endpoint: config.peerEndpoint,
                keepalive: config.peerPersistentKeepalive ?? 25
            )

            guard configured else {
                logger.log("WireProxyBridge: slot \(i) config failed for \(config.serverName)", category: .vpn, level: .error)
                continue
            }

            var slot = WireProxyTunnelSlot(
                index: i,
                config: config,
                wgSession: session,
                tcpManager: tcp,
                dnsResolver: dns,
                localIP: ip
            )

            await session.connect()
            try? await Task.sleep(for: .seconds(3))

            if session.isEstablished {
                slot.isEstablished = true
                dns.startBackgroundRefresh()
                logger.log("WireProxyBridge: slot \(i) ESTABLISHED → \(config.peerEndpoint) (\(config.serverName))", category: .vpn, level: .success)
            } else {
                logger.log("WireProxyBridge: slot \(i) FAILED for \(config.serverName) — \(session.lastError ?? "timeout")", category: .vpn, level: .error)
            }

            tunnelSlots.append(slot)
        }

        let established = tunnelSlots.filter(\.isEstablished).count
        if established > 0 {
            status = .established
            connectedSince = Date()
            startHealthCheck()
            logger.log("WireProxyBridge: multi-tunnel ready — \(established)/\(configs.count) tunnels active", category: .vpn, level: .success)
        } else {
            status = .failed
            lastError = "All \(configs.count) tunnel slots failed to establish"
            logger.log("WireProxyBridge: multi-tunnel FAILED — 0/\(configs.count) established", category: .vpn, level: .error)
        }
    }

    func nextTunnelSlot() -> WireProxyTunnelSlot? {
        let established = tunnelSlots.filter(\.isEstablished)
        guard !established.isEmpty else { return nil }
        let slot = established[nextSlotIndex % established.count]
        nextSlotIndex += 1
        return slot
    }

    private func handleMultiTunnelPacket(_ ipData: Data, slotIndex: Int) {
        guard slotIndex < tunnelSlots.count else { return }
        guard let ipPacket = IPv4Packet.parse(ipData) else { return }

        let slot = tunnelSlots[slotIndex]
        if ipPacket.header.isUDP {
            slot.dnsResolver.handleIncomingPacket(ipData)
            return
        }
        if ipPacket.header.isTCP {
            stats.bytesDownstream += UInt64(ipData.count)
            slot.tcpManager.handleIncomingPacket(ipData)
            return
        }
    }

    func handleSOCKS5Connection(
        id: UUID,
        clientConnection: NWConnection,
        targetHost: String,
        targetPort: UInt16,
        queue: DispatchQueue,
        server: LocalProxyServer
    ) {
        guard status == .established else {
            logger.log("WireProxyBridge: rejecting connection - tunnel not established", category: .vpn, level: .warning)
            return
        }

        stats.connectionsServed += 1

        if multiTunnelMode, let slot = nextTunnelSlot() {
            let tunnelConn = WireProxyMultiTunnelConnection(
                id: id,
                clientConnection: clientConnection,
                targetHost: targetHost,
                targetPort: targetPort,
                queue: queue,
                server: server,
                bridge: self,
                slot: slot
            )
            tunnelConnections[id] = tunnelConn
            tunnelConn.start()
            logger.log("WireProxyBridge: routed \(targetHost) → slot \(slot.index) (\(slot.serverName))", category: .vpn, level: .debug)
            return
        }

        let tunnelConn = WireProxyTunnelConnection(
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

    func createMultiTunnelTCPSession(slot: WireProxyTunnelSlot, destinationIP: UInt32, destinationPort: UInt16) -> TCPSession {
        stats.tcpSessionsCreated += 1
        stats.tcpSessionsActive += 1
        return slot.tcpManager.createSession(destinationIP: destinationIP, destinationPort: destinationPort)
    }

    func initiateMultiTunnelConnection(_ session: TCPSession, slot: WireProxyTunnelSlot) {
        slot.tcpManager.initiateConnection(session)
    }

    func sendMultiTunnelData(_ session: TCPSession, data: Data, slot: WireProxyTunnelSlot) {
        stats.bytesUpstream += UInt64(data.count)
        slot.tcpManager.sendData(session, data: data)
    }

    func closeMultiTunnelSession(_ session: TCPSession, slot: WireProxyTunnelSlot) {
        slot.tcpManager.closeSession(session)
        stats.tcpSessionsActive = max(0, stats.tcpSessionsActive - 1)
    }

    func resetMultiTunnelSession(_ session: TCPSession, slot: WireProxyTunnelSlot) {
        slot.tcpManager.sendReset(session)
        stats.tcpSessionsActive = max(0, stats.tcpSessionsActive - 1)
    }

    func resolveMultiTunnelHostname(_ hostname: String, slot: WireProxyTunnelSlot) async -> UInt32? {
        stats.dnsQueriesTotal += 1
        return await slot.dnsResolver.resolve(hostname)
    }

    var wgSessionStatus: WGSessionStatus { wgSession.status }
    var wgSessionStats: WGSessionStats { wgSession.stats }
    var dnsCacheSize: Int { dnsResolver.cacheSize }
    var reconnectCount: Int { reconnectAttempts }

    var uptimeString: String {
        guard let since = connectedSince else { return "--:--" }
        let elapsed = Int(Date().timeIntervalSince(since))
        let hrs = elapsed / 3600
        let mins = (elapsed % 3600) / 60
        let secs = elapsed % 60
        if hrs > 0 { return String(format: "%d:%02d:%02d", hrs, mins, secs) }
        return String(format: "%d:%02d", mins, secs)
    }

    var resolutionSourceLabel: String {
        stats.resolutionSource.isEmpty ? "—" : stats.resolutionSource
    }

    var statusLabel: String {
        guard let config = activeConfig else { return status.rawValue }
        let loadInfo = stats.serverLoad >= 0 ? " (load: \(stats.serverLoad)%)" : ""
        return "\(status.rawValue) → \(config.serverName)\(loadInfo)"
    }

    // MARK: - Nord Country Extraction

    private func extractNordCountryId(from config: WireGuardConfig) -> Int? {
        let host = config.endpointHost.lowercased()
        guard host.contains(".nordvpn.com") || host.contains("nord") else { return nil }
        let prefix = host.replacingOccurrences(of: ".nordvpn.com", with: "")
        let letters = prefix.filter { $0.isLetter }
        guard letters.count >= 2 else { return nil }
        let code = String(letters.prefix(2)).uppercased()
        return Self.nordCountryCodeToId[code]
    }

    private static let nordCountryCodeToId: [String: Int] = [
        "AL": 2, "AR": 10, "AU": 13, "AT": 14, "AZ": 15,
        "BE": 21, "BA": 27, "BR": 30, "BG": 33, "CA": 38,
        "CL": 43, "CO": 47, "CR": 52, "HR": 54, "CY": 56,
        "CZ": 57, "DK": 58, "EE": 68, "FI": 73, "FR": 74,
        "GE": 80, "DE": 81, "GR": 84, "HK": 97, "HU": 98,
        "IS": 99, "IN": 100, "ID": 101, "IE": 104, "IL": 105,
        "IT": 106, "JP": 108, "LV": 119, "LT": 125, "LU": 126,
        "MY": 131, "MX": 140, "MD": 142, "NL": 153, "NZ": 156,
        "MK": 128, "NO": 163, "PA": 170, "PE": 172, "PH": 174,
        "PL": 176, "PT": 177, "RO": 179, "RS": 192, "SG": 195,
        "SK": 196, "SI": 197, "ZA": 200, "KR": 114, "ES": 202,
        "SE": 208, "CH": 209, "TW": 211, "TH": 214, "TR": 220,
        "UA": 225, "AE": 226, "GB": 227, "US": 228, "VN": 234
    ]
}
