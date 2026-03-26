import Foundation
import Network
import Observation

nonisolated struct NetworkTruthSnapshot: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let routeType: String
    let exitIP: String?
    let tunnelActive: Bool
    let proxyHost: String?
    let proxyPort: Int?
    let dnsMode: String
    let wireProxyActive: Bool
    let wireProxyStatus: String
    let localProxyRunning: Bool
    let localProxyPort: UInt16
    let ipRoutingMode: String
    let connectionMode: String
    let activeEndpoint: String?
    let latencyMs: Int?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        routeType: String,
        exitIP: String? = nil,
        tunnelActive: Bool = false,
        proxyHost: String? = nil,
        proxyPort: Int? = nil,
        dnsMode: String = "System",
        wireProxyActive: Bool = false,
        wireProxyStatus: String = "Stopped",
        localProxyRunning: Bool = false,
        localProxyPort: UInt16 = 0,
        ipRoutingMode: String = "Per-Session",
        connectionMode: String = "Direct",
        activeEndpoint: String? = nil,
        latencyMs: Int? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.routeType = routeType
        self.exitIP = exitIP
        self.tunnelActive = tunnelActive
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.dnsMode = dnsMode
        self.wireProxyActive = wireProxyActive
        self.wireProxyStatus = wireProxyStatus
        self.localProxyRunning = localProxyRunning
        self.localProxyPort = localProxyPort
        self.ipRoutingMode = ipRoutingMode
        self.connectionMode = connectionMode
        self.activeEndpoint = activeEndpoint
        self.latencyMs = latencyMs
    }
}

@Observable
@MainActor
class NetworkTruthService {
    static let shared = NetworkTruthService()

    private(set) var currentSnapshot: NetworkTruthSnapshot = NetworkTruthSnapshot(routeType: "Unknown")
    private(set) var snapshotHistory: [NetworkTruthSnapshot] = []
    private(set) var lastRefreshed: Date?
    private(set) var isProbing: Bool = false

    private let deviceProxy = DeviceProxyService.shared
    private let localProxy = LocalProxyServer.shared
    private let wireProxyBridge = WireProxyBridge.shared
    private let proxyService = ProxyRotationService.shared
    private let logger = DebugLogger.shared
    private var refreshTimer: Timer?
    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "network-truth-monitor", qos: .utility)
    private(set) var isNetworkAvailable: Bool = true
    private(set) var networkInterfaceType: String = "unknown"
    private(set) var lastPathChange: Date?
    private var batchActive: Bool = false
    private var adaptiveInterval: TimeInterval = 5
    private let batchActiveInterval: TimeInterval = 3
    private let idleInterval: TimeInterval = 10

    func startMonitoring(interval: TimeInterval = 5) {
        stopMonitoring()
        adaptiveInterval = interval
        refreshSnapshot()

        pathMonitor = NWPathMonitor()
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasAvailable = self.isNetworkAvailable
                self.isNetworkAvailable = path.status == .satisfied
                self.lastPathChange = Date()

                if path.usesInterfaceType(.wifi) {
                    self.networkInterfaceType = "WiFi"
                } else if path.usesInterfaceType(.cellular) {
                    self.networkInterfaceType = "Cellular"
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self.networkInterfaceType = "Ethernet"
                } else {
                    self.networkInterfaceType = "Other"
                }

                if wasAvailable != self.isNetworkAvailable {
                    self.logger.log("NetworkTruth: path changed — available=\(self.isNetworkAvailable) interface=\(self.networkInterfaceType)", category: .network, level: self.isNetworkAvailable ? .info : .critical)
                    self.refreshSnapshot()
                }
            }
        }
        pathMonitor?.start(queue: monitorQueue)

        refreshTimer = Timer.scheduledTimer(withTimeInterval: adaptiveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSnapshot()
            }
        }
    }

    func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    func setBatchActive(_ active: Bool) {
        batchActive = active
        let newInterval = active ? batchActiveInterval : idleInterval
        if abs(newInterval - adaptiveInterval) > 0.5 {
            adaptiveInterval = newInterval
            refreshTimer?.invalidate()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: adaptiveInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshSnapshot()
                }
            }
            logger.log("NetworkTruth: monitoring interval adjusted to \(Int(adaptiveInterval))s (batchActive=\(active))", category: .network, level: .debug)
        }
    }

    func refreshSnapshot() {
        let routeType: String
        let proxyHost: String?
        var proxyPort: Int?
        let tunnelActive: Bool
        let dnsMode: String
        let connectionModeLabel: String
        let activeEndpoint: String?

        let wpActive = wireProxyBridge.isActive
        let wpStatus = wireProxyBridge.status.rawValue
        let lpRunning = localProxy.isRunning
        let lpPort = localProxy.listeningPort

        if deviceProxy.isEnabled, let config = deviceProxy.activeConfig {
            activeEndpoint = deviceProxy.activeEndpointLabel
            switch config {
            case .socks5(let proxy):
                if deviceProxy.isWireProxyActive && lpRunning && localProxy.wireProxyMode {
                    routeType = "WireGuard → WireProxy → SOCKS5"
                    proxyHost = "127.0.0.1"
                    proxyPort = Int(lpPort)
                    tunnelActive = true
                    dnsMode = "Tunnel DNS"
                    connectionModeLabel = "WireGuard (via WireProxy)"
                } else if lpRunning {
                    routeType = "SOCKS5 → Local Proxy"
                    proxyHost = proxy.host
                    proxyPort = proxy.port
                    tunnelActive = false
                    dnsMode = "System"
                    connectionModeLabel = "SOCKS5"
                } else {
                    routeType = "SOCKS5 Direct"
                    proxyHost = proxy.host
                    proxyPort = proxy.port
                    tunnelActive = false
                    dnsMode = "System"
                    connectionModeLabel = "SOCKS5"
                }
            case .wireGuardDNS(let wg):
                if wpActive && lpRunning && localProxy.wireProxyMode {
                    routeType = "WireGuard → WireProxy Tunnel"
                    proxyHost = "127.0.0.1"
                    proxyPort = Int(lpPort)
                    tunnelActive = true
                    dnsMode = wg.interfaceDNS.isEmpty ? "System" : "WG DNS: \(wg.interfaceDNS)"
                    connectionModeLabel = "WireGuard"
                } else {
                    routeType = "WireGuard DNS-only"
                    proxyHost = nil
                    proxyPort = nil
                    tunnelActive = false
                    dnsMode = wg.interfaceDNS.isEmpty ? "System" : "WG DNS: \(wg.interfaceDNS)"
                    connectionModeLabel = "WireGuard (DNS)"
                }
            case .openVPNProxy(let ovpn):
                routeType = "OpenVPN"
                proxyHost = ovpn.remoteHost
                proxyPort = ovpn.remotePort
                tunnelActive = false
                dnsMode = "VPN DNS"
                connectionModeLabel = "OpenVPN"
            case .direct:
                routeType = "Direct"
                proxyHost = nil
                proxyPort = nil
                tunnelActive = false
                dnsMode = "System"
                connectionModeLabel = "Direct"
            }
        } else {
            activeEndpoint = nil
            let defaultTarget: ProxyRotationService.ProxyTarget = .joe
            let mode = proxyService.connectionMode(for: defaultTarget)

            switch mode {
            case .direct:
                routeType = "Direct (No Proxy)"
                proxyHost = nil
                proxyPort = nil
                tunnelActive = false
                dnsMode = "System"
                connectionModeLabel = "Direct"
            case .dns:
                routeType = "Direct (DNS)"
                proxyHost = nil
                proxyPort = nil
                tunnelActive = false
                dnsMode = "Custom DNS"
                connectionModeLabel = "DNS"
            case .proxy:
                routeType = "SOCKS5 Per-Session"
                proxyHost = nil
                proxyPort = nil
                tunnelActive = false
                dnsMode = "System"
                connectionModeLabel = "SOCKS5 Proxy"
            case .wireguard:
                if wpActive && lpRunning && localProxy.wireProxyMode {
                    routeType = "WireGuard → WireProxy Per-Session"
                    proxyHost = "127.0.0.1"
                    proxyPort = Int(lpPort)
                    tunnelActive = true
                    dnsMode = "Tunnel DNS"
                    connectionModeLabel = "WireGuard (WireProxy)"
                } else {
                    routeType = "WireGuard Per-Session"
                    proxyHost = nil
                    proxyPort = nil
                    tunnelActive = false
                    dnsMode = "WG DNS"
                    connectionModeLabel = "WireGuard"
                }
            case .openvpn:
                routeType = "OpenVPN Per-Session"
                proxyHost = nil
                proxyPort = nil
                tunnelActive = false
                dnsMode = "VPN DNS"
                connectionModeLabel = "OpenVPN"
            case .nodeMaven:
                routeType = "NodeMaven Per-Session"
                proxyHost = nil
                proxyPort = nil
                tunnelActive = false
                dnsMode = "System"
                connectionModeLabel = "NodeMaven"
            case .hybrid:
                routeType = "Hybrid (1 per method)"
                proxyHost = nil
                proxyPort = nil
                tunnelActive = false
                dnsMode = "Mixed"
                connectionModeLabel = "Hybrid"
            }
        }

        let snapshot = NetworkTruthSnapshot(
            routeType: routeType,
            tunnelActive: tunnelActive,
            proxyHost: proxyHost,
            proxyPort: proxyPort,
            dnsMode: dnsMode,
            wireProxyActive: wpActive,
            wireProxyStatus: wpStatus,
            localProxyRunning: lpRunning,
            localProxyPort: lpPort,
            ipRoutingMode: deviceProxy.ipRoutingMode.shortLabel,
            connectionMode: connectionModeLabel,
            activeEndpoint: activeEndpoint
        )

        currentSnapshot = snapshot
        lastRefreshed = Date()

        snapshotHistory.insert(snapshot, at: 0)
        if snapshotHistory.count > 50 {
            snapshotHistory = Array(snapshotHistory.prefix(50))
        }
    }

    func probeExitIP() async {
        isProbing = true
        defer { isProbing = false }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10

        if localProxy.isRunning {
            let localConfig = localProxy.localProxyConfig
            var proxyDict: [String: Any] = [
                "SOCKSEnable": 1,
                "SOCKSProxy": localConfig.host,
                "SOCKSPort": localConfig.port,
            ]
            if let u = localConfig.username { proxyDict["SOCKSUser"] = u }
            if let p = localConfig.password { proxyDict["SOCKSPassword"] = p }
            config.connectionProxyDictionary = proxyDict
        }

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let endpoints = [
            "https://api.ipify.org?format=text",
            "https://ifconfig.me/ip",
            "https://checkip.amazonaws.com",
        ]

        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !ip.isEmpty, ip.count < 50 else { continue }

                var updated = currentSnapshot
                updated = NetworkTruthSnapshot(
                    id: updated.id,
                    timestamp: updated.timestamp,
                    routeType: updated.routeType,
                    exitIP: ip,
                    tunnelActive: updated.tunnelActive,
                    proxyHost: updated.proxyHost,
                    proxyPort: updated.proxyPort,
                    dnsMode: updated.dnsMode,
                    wireProxyActive: updated.wireProxyActive,
                    wireProxyStatus: updated.wireProxyStatus,
                    localProxyRunning: updated.localProxyRunning,
                    localProxyPort: updated.localProxyPort,
                    ipRoutingMode: updated.ipRoutingMode,
                    connectionMode: updated.connectionMode,
                    activeEndpoint: updated.activeEndpoint,
                    latencyMs: updated.latencyMs
                )
                currentSnapshot = updated
                logger.log("NetworkTruth: exit IP resolved → \(ip) via \(endpoint)", category: .network, level: .info)
                return
            } catch {
                continue
            }
        }

        logger.log("NetworkTruth: exit IP probe failed — all endpoints unreachable", category: .network, level: .warning)
    }
}
