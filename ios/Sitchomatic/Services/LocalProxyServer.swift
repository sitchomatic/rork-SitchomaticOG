import Foundation
import Network
import Observation

nonisolated struct LocalProxyStats: Sendable {
    var activeConnections: Int = 0
    var totalConnections: Int = 0
    var bytesRelayed: UInt64 = 0
    var bytesUploaded: UInt64 = 0
    var bytesDownloaded: UInt64 = 0
    var upstreamErrors: Int = 0
    var connectionErrors: Int = 0
    var handshakeErrors: Int = 0
    var relayErrors: Int = 0
    var lastConnectionTime: Date?
    var peakActiveConnections: Int = 0
    var averageConnectionDurationMs: Double = 0
    var startedAt: Date?
}

nonisolated struct ActiveConnectionInfo: Identifiable, Sendable {
    let id: UUID
    let targetHost: String
    let targetPort: UInt16
    let connectedAt: Date
    var bytesRelayed: UInt64
    var state: ConnectionState

    nonisolated enum ConnectionState: String, Sendable {
        case handshaking = "Handshaking"
        case relaying = "Relaying"
        case closing = "Closing"
    }
}

nonisolated enum ConnectionErrorType: Sendable {
    case none
    case connection
    case handshake
    case relay
}

@Observable
@MainActor
class LocalProxyServer {
    static let shared = LocalProxyServer()

    private(set) var isRunning: Bool = false
    private(set) var listeningPort: UInt16 = 0
    private(set) var stats: LocalProxyStats = LocalProxyStats()
    private(set) var statusMessage: String = "Stopped"
    private(set) var upstreamLabel: String = "None"
    private(set) var activeConnectionDetails: [UUID: ActiveConnectionInfo] = [:]
    private(set) var recentCompletedHosts: [String] = []

    var upstreamProxy: ProxyConfig?
    var maxConcurrentConnections: Int = 500
    var connectionTimeoutSeconds: TimeInterval = 30
    var enableConnectionPooling: Bool = true
    private(set) var wireProxyMode: Bool = false
    private(set) var openVPNProxyMode: Bool = false

    private var listener: NWListener?
    private var connections: [UUID: LocalProxyConnection] = [:]
    private var tunnelConnections: [UUID: WireProxySOCKS5Handler] = [:]
    private var ovpnConnections: [UUID: OpenVPNSOCKS5Handler] = [:]
    private let queue = DispatchQueue(label: "local-proxy-server", qos: .userInitiated)
    private let logger = DebugLogger.shared
    private let preferredPort: UInt16 = 18080
    private let healthMonitor = ProxyHealthMonitor.shared
    private let connectionPool = ProxyConnectionPool.shared
    private var connectionDurations: [TimeInterval] = []
    private var rejectedConnections: Int = 0

    private let portRetryRange: [UInt16] = [18080, 18081, 18082, 18083, 18084, 18090, 18100]

    func start() {
        guard !isRunning else { return }

        for port in portRetryRange {
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                params.requiredInterfaceType = .loopback

                let nwListener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
                self.listener = nwListener

                nwListener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor [weak self] in
                        self?.handleListenerState(state)
                    }
                }

                nwListener.newConnectionHandler = { [weak self] nwConnection in
                    Task { @MainActor [weak self] in
                        self?.handleNewConnection(nwConnection)
                    }
                }

                nwListener.start(queue: queue)
                isRunning = true
                stats.startedAt = Date()
                statusMessage = "Starting on :\(port)..."
                logger.log("LocalProxy: starting on port \(port)", category: .network, level: .info)
                return
            } catch {
                logger.log("LocalProxy: port \(port) unavailable — \(error.localizedDescription)", category: .network, level: .warning)
                continue
            }
        }

        statusMessage = "Failed: all ports unavailable"
        logger.log("LocalProxy: failed to start — all ports in range unavailable", category: .network, level: .error)
    }

    func stop() {
        healthMonitor.stopMonitoring()
        connectionPool.drainPool()

        listener?.cancel()
        listener = nil

        for conn in connections.values {
            conn.cancel()
        }
        connections.removeAll()
        for conn in tunnelConnections.values {
            conn.cancel()
        }
        tunnelConnections.removeAll()
        for conn in ovpnConnections.values {
            conn.cancel()
        }
        ovpnConnections.removeAll()
        activeConnectionDetails.removeAll()

        isRunning = false
        listeningPort = 0
        wireProxyMode = false
        openVPNProxyMode = false
        statusMessage = "Stopped"
        stats = LocalProxyStats()
        connectionDurations.removeAll()
        rejectedConnections = 0
        recentCompletedHosts.removeAll()
        logger.log("LocalProxy: stopped", category: .network, level: .info)
    }

    func enableWireProxyMode(_ enabled: Bool) {
        wireProxyMode = enabled
        if enabled {
            openVPNProxyMode = false
            upstreamLabel = "WireProxy (WG Tunnel)"
            logger.log("LocalProxy: WireProxy tunnel mode ENABLED", category: .vpn, level: .info)
        } else {
            if !openVPNProxyMode {
                upstreamLabel = upstreamProxy?.displayString ?? "None (direct)"
            }
            logger.log("LocalProxy: WireProxy tunnel mode DISABLED", category: .vpn, level: .info)
        }
    }

    func enableOpenVPNProxyMode(_ enabled: Bool) {
        openVPNProxyMode = enabled
        if enabled {
            wireProxyMode = false
            upstreamLabel = "OpenVPN Bridge (SOCKS5)"
            logger.log("LocalProxy: OpenVPN proxy bridge mode ENABLED", category: .vpn, level: .info)
        } else {
            if !wireProxyMode {
                upstreamLabel = upstreamProxy?.displayString ?? "None (direct)"
            }
            logger.log("LocalProxy: OpenVPN proxy bridge mode DISABLED", category: .vpn, level: .info)
        }
    }

    func updateUpstream(_ proxy: ProxyConfig?) {
        let previousProxy = upstreamProxy
        upstreamProxy = proxy

        if let proxy {
            upstreamLabel = proxy.displayString
            logger.log("LocalProxy: upstream changed to \(proxy.displayString)", category: .proxy, level: .info)
        } else {
            upstreamLabel = "None (direct)"
            logger.log("LocalProxy: upstream cleared to direct", category: .proxy, level: .info)
        }

        if enableConnectionPooling && (previousProxy?.host != proxy?.host || previousProxy?.port != proxy?.port) {
            connectionPool.drainPool()
            logger.log("LocalProxy: upstream changed - connection pool drained", category: .proxy, level: .debug)
        }

        healthMonitor.updateUpstream(proxy)
    }

    func startHealthMonitoring(onFailover: @escaping () -> Void) {
        healthMonitor.startMonitoring(upstream: upstreamProxy, onFailover: onFailover)
    }

    func stopHealthMonitoring() {
        healthMonitor.stopMonitoring()
    }

    var localProxyConfig: ProxyConfig {
        ProxyConfig(host: "127.0.0.1", port: Int(listeningPort == 0 ? preferredPort : listeningPort))
    }

    func connectionFinished(id: UUID, bytesRelayed: UInt64, bytesUp: UInt64, bytesDown: UInt64, hadError: Bool, errorType: ConnectionErrorType, targetHost: String) {
        let resilience = NetworkResilienceService.shared

        if let info = activeConnectionDetails[id] {
            let duration = Date().timeIntervalSince(info.connectedAt)
            connectionDurations.append(duration)
            if connectionDurations.count > 100 {
                connectionDurations = Array(connectionDurations.suffix(100))
            }
            stats.averageConnectionDurationMs = connectionDurations.reduce(0, +) / Double(connectionDurations.count) * 1000

            let latencyMs = Int(duration * 1000)
            resilience.recordLatencySample(latencyMs: latencyMs, hadError: hadError)
        }

        if bytesRelayed > 0 {
            resilience.recordBandwidthSample(bytes: bytesRelayed)
        }

        connections.removeValue(forKey: id)
        activeConnectionDetails.removeValue(forKey: id)
        stats.activeConnections = connections.count
        stats.bytesRelayed += bytesRelayed
        stats.bytesUploaded += bytesUp
        stats.bytesDownloaded += bytesDown

        if hadError {
            stats.upstreamErrors += 1
            switch errorType {
            case .connection: stats.connectionErrors += 1
            case .handshake: stats.handshakeErrors += 1
            case .relay: stats.relayErrors += 1
            case .none: break
            }
        }

        if !targetHost.isEmpty {
            recentCompletedHosts.insert(targetHost, at: 0)
            if recentCompletedHosts.count > 20 {
                recentCompletedHosts = Array(recentCompletedHosts.prefix(20))
            }
        }
    }

    func updateConnectionInfo(id: UUID, targetHost: String, targetPort: UInt16, state: ActiveConnectionInfo.ConnectionState) {
        if var info = activeConnectionDetails[id] {
            info.state = state
            activeConnectionDetails[id] = info
        } else {
            activeConnectionDetails[id] = ActiveConnectionInfo(
                id: id,
                targetHost: targetHost,
                targetPort: targetPort,
                connectedAt: Date(),
                bytesRelayed: 0,
                state: state
            )
        }
    }

    func updateConnectionBytes(id: UUID, bytes: UInt64) {
        if var info = activeConnectionDetails[id] {
            info.bytesRelayed = bytes
            activeConnectionDetails[id] = info
        }
    }

    var uptimeString: String {
        guard let started = stats.startedAt else { return "--:--" }
        let elapsed = Int(Date().timeIntervalSince(started))
        let hrs = elapsed / 3600
        let mins = (elapsed % 3600) / 60
        let secs = elapsed % 60
        if hrs > 0 { return String(format: "%d:%02d:%02d", hrs, mins, secs) }
        return String(format: "%d:%02d", mins, secs)
    }

    var throughputLabel: String {
        guard let started = stats.startedAt else { return "0 B/s" }
        let elapsed = max(1, Date().timeIntervalSince(started))
        let bps = Double(stats.bytesRelayed) / elapsed
        return formatBytesPerSecond(bps)
    }

    var errorRate: Double {
        guard stats.totalConnections > 0 else { return 0 }
        return Double(stats.upstreamErrors) / Double(stats.totalConnections) * 100
    }

    private func formatBytesPerSecond(_ bps: Double) -> String {
        if bps < 1024 { return String(format: "%.0f B/s", bps) }
        if bps < 1024 * 1024 { return String(format: "%.1f KB/s", bps / 1024) }
        return String(format: "%.1f MB/s", bps / (1024 * 1024))
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port {
                listeningPort = port.rawValue
            }
            isRunning = true
            statusMessage = "Running on :\(listeningPort)"
            logger.log("LocalProxy: listening on port \(listeningPort)", category: .network, level: .success)

        case .failed(let error):
            isRunning = false
            statusMessage = "Failed: \(error.localizedDescription)"
            logger.log("LocalProxy: listener failed - \(error)", category: .network, level: .error)
            listener?.cancel()
            listener = nil

        case .cancelled:
            isRunning = false
            statusMessage = "Stopped"

        default:
            break
        }
    }

    private func handleNewConnection(_ nwConnection: NWConnection) {
        let totalActive = connections.count + tunnelConnections.count + ovpnConnections.count
        if totalActive >= maxConcurrentConnections {
            rejectedConnections += 1
            nwConnection.cancel()
            logger.log("LocalProxy: rejected connection - at max capacity (\(maxConcurrentConnections))", category: .network, level: .warning)
            return
        }

        let id = UUID()
        stats.totalConnections += 1
        stats.lastConnectionTime = Date()

        if wireProxyMode && WireProxyBridge.shared.isActive {
            let tunnelConn = WireProxySOCKS5Handler(
                id: id,
                clientConnection: nwConnection,
                queue: queue,
                server: self
            )
            tunnelConnections[id] = tunnelConn
            stats.activeConnections = connections.count + tunnelConnections.count + ovpnConnections.count
            if stats.activeConnections > stats.peakActiveConnections {
                stats.peakActiveConnections = stats.activeConnections
            }
            tunnelConn.start()
        } else if openVPNProxyMode && OpenVPNProxyBridge.shared.isActive {
            let ovpnConn = OpenVPNSOCKS5Handler(
                id: id,
                clientConnection: nwConnection,
                queue: queue,
                server: self
            )
            ovpnConnections[id] = ovpnConn
            stats.activeConnections = connections.count + tunnelConnections.count + ovpnConnections.count
            if stats.activeConnections > stats.peakActiveConnections {
                stats.peakActiveConnections = stats.activeConnections
            }
            ovpnConn.start()
        } else {
            let connection = LocalProxyConnection(
                id: id,
                clientConnection: nwConnection,
                upstream: upstreamProxy,
                queue: queue,
                server: self,
                timeoutSeconds: connectionTimeoutSeconds
            )
            connections[id] = connection
            stats.activeConnections = connections.count + tunnelConnections.count + ovpnConnections.count
            if stats.activeConnections > stats.peakActiveConnections {
                stats.peakActiveConnections = stats.activeConnections
            }
            connection.start()
        }
    }

    func tunnelConnectionFinished(id: UUID) {
        tunnelConnections.removeValue(forKey: id)
        ovpnConnections.removeValue(forKey: id)
        stats.activeConnections = connections.count + tunnelConnections.count + ovpnConnections.count
    }
}
