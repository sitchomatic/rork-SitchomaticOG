import Foundation
@preconcurrency import NetworkExtension
import Network
import Observation

nonisolated enum VPNTunnelStatus: String, Sendable {
    case disconnected = "Disconnected"
    case connecting = "Connecting"
    case connected = "Connected"
    case disconnecting = "Disconnecting"
    case reasserting = "Reasserting"
    case invalid = "Invalid"
    case configuring = "Configuring"
    case error = "Error"
}

nonisolated struct VPNConnectionStats: Sendable {
    var totalConnections: Int = 0
    var totalDisconnections: Int = 0
    var totalErrors: Int = 0
    var totalReconnects: Int = 0
    var totalRotations: Int = 0
    var longestSessionSeconds: TimeInterval = 0
    var lastConnectedConfig: String?
    var lastDisconnectReason: String?
    var connectionHistory: [VPNConnectionEvent] = []
}

nonisolated struct VPNConnectionEvent: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let configName: String
    let eventType: EventType
    let detail: String

    nonisolated enum EventType: String, Sendable {
        case connected = "Connected"
        case disconnected = "Disconnected"
        case error = "Error"
        case reconnect = "Reconnect"
        case rotation = "Rotation"
        case failover = "Failover"
    }

    init(id: UUID = UUID(), timestamp: Date = Date(), configName: String, eventType: EventType, detail: String) {
        self.id = id
        self.timestamp = timestamp
        self.configName = configName
        self.eventType = eventType
        self.detail = detail
    }
}

@Observable
@MainActor
class VPNTunnelManager {
    static let shared = VPNTunnelManager()

    private(set) var status: VPNTunnelStatus = .disconnected
    private(set) var connectedSince: Date?
    private(set) var activeConfigName: String?
    private(set) var activeConfig: WireGuardConfig?
    private(set) var lastError: String?
    private(set) var isSupported: Bool = false
    private(set) var statusDetail: String = "Not configured"
    private(set) var connectionStats: VPNConnectionStats = VPNConnectionStats()
    private(set) var dataIn: UInt64 = 0
    private(set) var dataOut: UInt64 = 0
    private(set) var isReconnecting: Bool = false

    var autoReconnect: Bool = true {
        didSet { persistSettings() }
    }
    var vpnEnabled: Bool = false {
        didSet { persistSettings() }
    }
    var reconnectDelaySeconds: TimeInterval = 2 {
        didSet { persistSettings() }
    }
    var maxReconnectAttempts: Int = 3 {
        didSet { persistSettings() }
    }
    var killSwitchEnabled: Bool = false {
        didSet {
            persistSettings()
            if let manager { updateTunnelSettings(manager) }
        }
    }
    var onDemandEnabled: Bool = false {
        didSet {
            persistSettings()
            if let manager { updateOnDemandRules(manager) }
        }
    }
    var includeAllNetworks: Bool = true {
        didSet {
            persistSettings()
            if let manager { updateTunnelSettings(manager) }
        }
    }
    var excludeLocalNetworks: Bool = true {
        didSet {
            persistSettings()
            if let manager { updateTunnelSettings(manager) }
        }
    }

    private var manager: NETunnelProviderManager?
    private var statusObserver: Any?
    private let logger = DebugLogger.shared
    private let settingsKey = "vpn_tunnel_settings_v2"
    private let providerBundleID: String
    private var reconnectAttempts: Int = 0
    private var reconnectTimer: Timer?
    private var dataPollingTimer: Timer?
    private var pendingReconnectConfig: WireGuardConfig?
    private var disconnectReason: String = ""

    init() {
        let mainBundleID = Bundle.main.bundleIdentifier ?? "app.rork.ve5l1conjgc135kle8kuj"
        providerBundleID = "\(mainBundleID).PacketTunnel"
        loadSettings()
        checkSupport()
    }

    private func checkSupport() {
        #if targetEnvironment(simulator)
        isSupported = false
        statusDetail = "VPN requires a real device"
        #else
        isSupported = true
        statusDetail = "Ready"
        #endif
    }

    func loadExistingManager() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            if let existing = managers.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleID
            }) {
                self.manager = existing
                updateStatusFromManager(existing)
                observeStatus(existing)
                logger.log("VPNTunnel: loaded existing manager - \(existing.localizedDescription ?? "unnamed")", category: .vpn, level: .info)
            } else if let first = managers.first {
                self.manager = first
                updateStatusFromManager(first)
                observeStatus(first)
                logger.log("VPNTunnel: loaded first available manager", category: .vpn, level: .info)
            } else {
                statusDetail = "No VPN configuration"
                logger.log("VPNTunnel: no existing managers found", category: .vpn, level: .info)
            }
        } catch {
            lastError = error.localizedDescription
            logger.log("VPNTunnel: failed to load managers - \(error)", category: .vpn, level: .error)
        }
    }

    func configureAndConnect(with wgConfig: WireGuardConfig) async {
        guard isSupported else {
            lastError = "VPN not supported on simulator"
            status = .error
            statusDetail = "Install on real device via Rork App"
            return
        }

        if (status == .connecting || status == .connected) && activeConfigName == wgConfig.fileName {
            logger.log("VPNTunnel: skipping connect — already \(status.rawValue) to \(wgConfig.fileName)", category: .vpn, level: .debug)
            return
        }

        status = .configuring
        activeConfigName = wgConfig.fileName
        activeConfig = wgConfig
        statusDetail = "Configuring \(wgConfig.fileName)..."
        reconnectAttempts = 0

        do {
            let tunnelManager: NETunnelProviderManager
            if let existing = manager {
                tunnelManager = existing
            } else {
                tunnelManager = NETunnelProviderManager()
            }

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = providerBundleID
            proto.serverAddress = wgConfig.endpointHost
            proto.providerConfiguration = [
                "wgQuickConfig": wgConfig.rawContent,
                "endpoint": wgConfig.peerEndpoint,
                "dns": wgConfig.interfaceDNS,
                "mtu": String(wgConfig.interfaceMTU ?? 1420),
                "privateKey": wgConfig.interfacePrivateKey,
                "publicKey": wgConfig.peerPublicKey,
                "address": wgConfig.interfaceAddress,
                "allowedIPs": wgConfig.peerAllowedIPs,
            ]
            if let psk = wgConfig.peerPreSharedKey, !psk.isEmpty {
                proto.providerConfiguration?["presharedKey"] = psk
            }
            if let keepalive = wgConfig.peerPersistentKeepalive {
                proto.providerConfiguration?["persistentKeepalive"] = String(keepalive)
            }
            proto.disconnectOnSleep = false

            if includeAllNetworks {
                proto.includeAllNetworks = true
                proto.excludeLocalNetworks = excludeLocalNetworks
            }

            tunnelManager.protocolConfiguration = proto
            tunnelManager.localizedDescription = "WireGuard - \(wgConfig.serverName)"
            tunnelManager.isEnabled = true

            if onDemandEnabled {
                updateOnDemandRules(tunnelManager)
            }

            try await tunnelManager.saveToPreferences()
            try await tunnelManager.loadFromPreferences()

            self.manager = tunnelManager
            observeStatus(tunnelManager)

            try tunnelManager.connection.startVPNTunnel(options: [
                "activationAttemptId": UUID().uuidString as NSString
            ])

            status = .connecting
            statusDetail = "Connecting to \(wgConfig.serverName)..."
            connectionStats.totalConnections += 1
            logger.log("VPNTunnel: starting tunnel to \(wgConfig.displayString)", category: .vpn, level: .info)

        } catch {
            status = .error
            lastError = error.localizedDescription
            statusDetail = "Error: \(error.localizedDescription)"
            connectionStats.totalErrors += 1
            addEvent(configName: wgConfig.fileName, type: .error, detail: error.localizedDescription)
            logger.log("VPNTunnel: failed to configure/connect - \(error)", category: .vpn, level: .error)

            if autoReconnect && reconnectAttempts < maxReconnectAttempts {
                scheduleReconnect(with: wgConfig)
            }
        }
    }

    func disconnect(reason: String = "User requested") {
        disconnectReason = reason
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        isReconnecting = false

        guard let manager else {
            status = .disconnected
            return
        }

        status = .disconnecting
        statusDetail = "Disconnecting..."
        manager.connection.stopVPNTunnel()
        connectionStats.totalDisconnections += 1
        stopDataPolling()
        logger.log("VPNTunnel: disconnect requested (\(reason))", category: .vpn, level: .info)
    }

    func reconnectWithConfig(_ wgConfig: WireGuardConfig) async {
        disconnect(reason: "Reconnecting to new config")
        try? await Task.sleep(for: .seconds(reconnectDelaySeconds))
        await configureAndConnect(with: wgConfig)
        connectionStats.totalReconnects += 1
        addEvent(configName: wgConfig.fileName, type: .reconnect, detail: "Reconnected")
    }

    func rotateToConfig(_ wgConfig: WireGuardConfig) async {
        disconnect(reason: "Rotating to \(wgConfig.fileName)")
        try? await Task.sleep(for: .seconds(reconnectDelaySeconds))
        await configureAndConnect(with: wgConfig)
        connectionStats.totalRotations += 1
        addEvent(configName: wgConfig.fileName, type: .rotation, detail: "Rotated from \(activeConfigName ?? "none")")
    }

    func failoverToConfig(_ wgConfig: WireGuardConfig) async {
        disconnect(reason: "Failover to \(wgConfig.fileName)")
        try? await Task.sleep(for: .seconds(1))
        await configureAndConnect(with: wgConfig)
        addEvent(configName: wgConfig.fileName, type: .failover, detail: "Upstream failed, switching to \(wgConfig.fileName)")
    }

    func removeConfiguration() async {
        guard let manager else { return }
        do {
            try await manager.removeFromPreferences()
            self.manager = nil
            status = .disconnected
            activeConfigName = nil
            activeConfig = nil
            connectedSince = nil
            statusDetail = "Configuration removed"
            stopDataPolling()
            logger.log("VPNTunnel: configuration removed", category: .vpn, level: .info)
        } catch {
            lastError = error.localizedDescription
            logger.log("VPNTunnel: failed to remove config - \(error)", category: .vpn, level: .error)
        }
    }

    func testEndpointReachability(_ wgConfig: WireGuardConfig) async -> (reachable: Bool, latencyMs: Int) {
        let host = wgConfig.endpointHost
        let port = UInt16(wgConfig.endpointPort)
        let start = CFAbsoluteTimeGetCurrent()

        return await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port))
            let connection = NWConnection(to: endpoint, using: .udp)
            let queue = DispatchQueue(label: "vpn-endpoint-test")

            let guard_ = ContinuationGuard()
            let timeoutWork = DispatchWorkItem {
                if guard_.tryConsume() {
                    connection.cancel()
                    continuation.resume(returning: (false, 0))
                }
            }
            queue.asyncAfter(deadline: .now() + 5, execute: timeoutWork)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if guard_.tryConsume() {
                        timeoutWork.cancel()
                        let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                        connection.cancel()
                        continuation.resume(returning: (true, elapsed))
                    }
                case .failed:
                    if guard_.tryConsume() {
                        timeoutWork.cancel()
                        connection.cancel()
                        continuation.resume(returning: (false, 0))
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    var isConnected: Bool {
        status == .connected
    }

    var isActive: Bool {
        status == .connected || status == .connecting || status == .reasserting
    }

    var uptimeString: String {
        guard let since = connectedSince else { return "--:--" }
        let elapsed = Int(Date().timeIntervalSince(since))
        let hrs = elapsed / 3600
        let mins = (elapsed % 3600) / 60
        let secs = elapsed % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }

    var currentSessionDuration: TimeInterval {
        guard let since = connectedSince else { return 0 }
        return Date().timeIntervalSince(since)
    }

    var dataInLabel: String { formatDataSize(dataIn) }
    var dataOutLabel: String { formatDataSize(dataOut) }

    private func formatDataSize(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
    }

    private func scheduleReconnect(with wgConfig: WireGuardConfig) {
        reconnectAttempts += 1
        isReconnecting = true
        let delay = reconnectDelaySeconds * Double(reconnectAttempts)
        statusDetail = "Reconnecting in \(Int(delay))s (attempt \(reconnectAttempts)/\(maxReconnectAttempts))..."

        logger.log("VPNTunnel: scheduling reconnect attempt \(reconnectAttempts)/\(maxReconnectAttempts) in \(Int(delay))s", category: .vpn, level: .warning)

        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isReconnecting else { return }
                self.isReconnecting = false
                await self.configureAndConnect(with: wgConfig)
            }
        }
    }

    private func startDataPolling() {
        dataPollingTimer?.invalidate()
        dataPollingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollDataCounters()
            }
        }
    }

    private func stopDataPolling() {
        dataPollingTimer?.invalidate()
        dataPollingTimer = nil
    }

    private func pollDataCounters() {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        do {
            try session.sendProviderMessage("stats".data(using: .utf8)!) { [weak self] response in
                Task { @MainActor [weak self] in
                    guard let self, let response else { return }
                    if response.count >= 16 {
                        self.dataIn = response.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt64.self) }
                        self.dataOut = response.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
                    }
                }
            }
        } catch {
            logger.log("VPNTunnel: stats message failed: \(error.localizedDescription)", category: .vpn, level: .debug)
        }
    }

    private func updateOnDemandRules(_ tunnelManager: NETunnelProviderManager) {
        if onDemandEnabled {
            let wifiRule = NEOnDemandRuleConnect()
            wifiRule.interfaceTypeMatch = .wiFi
            let cellularRule = NEOnDemandRuleConnect()
            cellularRule.interfaceTypeMatch = .cellular
            tunnelManager.onDemandRules = [wifiRule, cellularRule]
            tunnelManager.isOnDemandEnabled = true
        } else {
            tunnelManager.isOnDemandEnabled = false
            tunnelManager.onDemandRules = []
        }

        Task {
            try? await tunnelManager.saveToPreferences()
        }
    }

    private func updateTunnelSettings(_ tunnelManager: NETunnelProviderManager) {
        guard let proto = tunnelManager.protocolConfiguration as? NETunnelProviderProtocol else { return }

        if includeAllNetworks {
            proto.includeAllNetworks = true
            proto.excludeLocalNetworks = excludeLocalNetworks
        } else {
            proto.includeAllNetworks = false
            proto.excludeLocalNetworks = false
        }

        if killSwitchEnabled {
            proto.includeAllNetworks = true
            proto.excludeLocalNetworks = excludeLocalNetworks
        }

        tunnelManager.protocolConfiguration = proto

        Task {
            try? await tunnelManager.saveToPreferences()
            logger.log("VPNTunnel: updated tunnel settings (includeAll: \(includeAllNetworks), excludeLocal: \(excludeLocalNetworks), killSwitch: \(killSwitchEnabled))", category: .vpn, level: .info)
        }
    }

    private func addEvent(configName: String, type: VPNConnectionEvent.EventType, detail: String) {
        let event = VPNConnectionEvent(configName: configName, eventType: type, detail: detail)
        connectionStats.connectionHistory.insert(event, at: 0)
        if connectionStats.connectionHistory.count > 30 {
            connectionStats.connectionHistory = Array(connectionStats.connectionHistory.prefix(30))
        }
    }

    private func observeStatus(_ manager: NETunnelProviderManager) {
        if let existing = statusObserver {
            NotificationCenter.default.removeObserver(existing)
        }

        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateStatusFromManager(manager)
            }
        }
    }

    private func updateStatusFromManager(_ manager: NETunnelProviderManager) {
        let vpnStatus = manager.connection.status
        switch vpnStatus {
        case .invalid:
            status = .invalid
            statusDetail = "Invalid configuration"
            connectedSince = nil
            stopDataPolling()
        case .disconnected:
            let wasConnected = status == .connected || status == .reasserting
            status = .disconnected
            statusDetail = "Disconnected"

            if wasConnected {
                if let since = connectedSince {
                    let sessionDuration = Date().timeIntervalSince(since)
                    if sessionDuration > connectionStats.longestSessionSeconds {
                        connectionStats.longestSessionSeconds = sessionDuration
                    }
                }
                addEvent(configName: activeConfigName ?? "unknown", type: .disconnected, detail: disconnectReason.isEmpty ? "Disconnected" : disconnectReason)
                disconnectReason = ""

                if autoReconnect && !isReconnecting && reconnectAttempts < maxReconnectAttempts, let config = activeConfig {
                    scheduleReconnect(with: config)
                }
            }

            connectedSince = nil
            stopDataPolling()
        case .connecting:
            status = .connecting
            statusDetail = "Connecting..."
        case .connected:
            status = .connected
            connectedSince = manager.connection.connectedDate
            statusDetail = "Connected to \(activeConfigName ?? "VPN")"
            reconnectAttempts = 0
            isReconnecting = false
            reconnectTimer?.invalidate()
            reconnectTimer = nil
            connectionStats.lastConnectedConfig = activeConfigName
            addEvent(configName: activeConfigName ?? "unknown", type: .connected, detail: "Connected successfully")
            startDataPolling()
            logger.log("VPNTunnel: CONNECTED - \(activeConfigName ?? "unknown")", category: .vpn, level: .success)
        case .reasserting:
            status = .reasserting
            statusDetail = "Reasserting connection..."
        case .disconnecting:
            status = .disconnecting
            statusDetail = "Disconnecting..."
        @unknown default:
            status = .disconnected
            statusDetail = "Unknown state"
        }
    }

    private func persistSettings() {
        let dict: [String: Any] = [
            "autoReconnect": autoReconnect,
            "vpnEnabled": vpnEnabled,
            "reconnectDelay": reconnectDelaySeconds,
            "maxReconnectAttempts": maxReconnectAttempts,
            "killSwitch": killSwitchEnabled,
            "onDemand": onDemandEnabled,
            "includeAllNetworks": includeAllNetworks,
            "excludeLocalNetworks": excludeLocalNetworks,
        ]
        UserDefaults.standard.set(dict, forKey: settingsKey)
    }

    private func loadSettings() {
        let key = settingsKey
        let fallbackKey = "vpn_tunnel_settings_v1"
        let dict = UserDefaults.standard.dictionary(forKey: key) ?? UserDefaults.standard.dictionary(forKey: fallbackKey)
        guard let dict else { return }
        if let ar = dict["autoReconnect"] as? Bool { autoReconnect = ar }
        if let ve = dict["vpnEnabled"] as? Bool { vpnEnabled = ve }
        if let rd = dict["reconnectDelay"] as? TimeInterval { reconnectDelaySeconds = rd }
        if let mr = dict["maxReconnectAttempts"] as? Int { maxReconnectAttempts = mr }
        if let ks = dict["killSwitch"] as? Bool { killSwitchEnabled = ks }
        if let od = dict["onDemand"] as? Bool { onDemandEnabled = od }
        if let ian = dict["includeAllNetworks"] as? Bool { includeAllNetworks = ian }
        if let eln = dict["excludeLocalNetworks"] as? Bool { excludeLocalNetworks = eln }
    }

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
