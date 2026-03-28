import Foundation

// MARK: - Network State Global Actor

/// Global actor that serves as the single source of truth for all VPN/proxy
/// network state across the application.
///
/// Replaces the scattered state management previously split between
/// `NordVPNService`, `VPNTunnelManager`, `ProxyRotationService`, and
/// `NetworkTruthService` with a unified, actor-isolated domain.
///
/// All network identity reads/writes are serialized through this actor,
/// eliminating data races between the automation engine, tunnel engine,
/// and UI layer.
@globalActor
public actor NetworkStateActor {
    public static let shared = NetworkStateActor()

    // MARK: - Connection State

    public enum ConnectionStatus: String, Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case error
    }

    public enum TunnelProtocol: String, Sendable, Codable {
        case wireGuard
        case openVPN
        case socks5
        case none
    }

    public struct NetworkIdentity: Sendable {
        public let externalIP: String
        public let tunnelProtocol: TunnelProtocol
        public let serverLocation: String
        public let proxyChainActive: Bool
        public let latencyMs: Int
        public let timestamp: Date

        public init(
            externalIP: String,
            tunnelProtocol: TunnelProtocol = .none,
            serverLocation: String = "",
            proxyChainActive: Bool = false,
            latencyMs: Int = 0,
            timestamp: Date = Date()
        ) {
            self.externalIP = externalIP
            self.tunnelProtocol = tunnelProtocol
            self.serverLocation = serverLocation
            self.proxyChainActive = proxyChainActive
            self.latencyMs = latencyMs
            self.timestamp = timestamp
        }
    }

    // MARK: - State

    private var currentStatus: ConnectionStatus = .disconnected
    private var currentIdentity: NetworkIdentity?
    private var activeTunnelConfig: TunnelConfig?
    private var connectionHistory: [NetworkIdentity] = []
    private var statusContinuations: [UUID: AsyncStream<ConnectionStatus>.Continuation] = [:]

    private let maxHistorySize = 50

    // MARK: - Public API

    /// Returns the current connection status.
    public func status() -> ConnectionStatus {
        currentStatus
    }

    /// Returns the current network identity (external IP, protocol, etc.).
    public func identity() -> NetworkIdentity? {
        currentIdentity
    }

    /// Updates the connection status and notifies all observers.
    public func updateStatus(_ newStatus: ConnectionStatus) {
        currentStatus = newStatus
        for (_, continuation) in statusContinuations {
            continuation.yield(newStatus)
        }
    }

    /// Updates the current network identity after a tunnel connects.
    public func updateIdentity(_ identity: NetworkIdentity) {
        currentIdentity = identity
        connectionHistory.append(identity)
        if connectionHistory.count > maxHistorySize {
            connectionHistory.removeFirst(connectionHistory.count - maxHistorySize)
        }
    }

    /// Stores the active tunnel configuration.
    public func setTunnelConfig(_ config: TunnelConfig?) {
        activeTunnelConfig = config
    }

    /// Returns the active tunnel configuration.
    public func tunnelConfig() -> TunnelConfig? {
        activeTunnelConfig
    }

    /// Clears all state on disconnect.
    public func clearState() {
        currentStatus = .disconnected
        currentIdentity = nil
        activeTunnelConfig = nil
        for (_, continuation) in statusContinuations {
            continuation.yield(.disconnected)
        }
    }

    /// Returns a history of recent network identities for diagnostics.
    public func recentHistory() -> [NetworkIdentity] {
        connectionHistory
    }

    // MARK: - AsyncStream for Status Observation

    /// Provides a backpressure-aware stream of connection status changes.
    /// UI ViewModels subscribe to this stream for reactive updates.
    public func statusStream() -> AsyncStream<ConnectionStatus> {
        let id = UUID()
        return AsyncStream { continuation in
            statusContinuations[id] = continuation
            continuation.yield(currentStatus)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { [weak self] in
                    await self?.removeContinuation(id: id)
                }
            }
        }
    }

    private func removeContinuation(id: UUID) {
        statusContinuations.removeValue(forKey: id)
    }
}
