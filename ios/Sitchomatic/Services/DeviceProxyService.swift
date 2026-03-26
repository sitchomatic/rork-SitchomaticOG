import Foundation
import Observation

@Observable
@MainActor
class DeviceProxyService {
    static let shared = DeviceProxyService()

    private let proxyService = ProxyRotationService.shared
    private let localProxy = LocalProxyServer.shared
    private let wireProxyBridge = WireProxyBridge.shared
    private let ovpnBridge = OpenVPNProxyBridge.shared
    private let resilience = NetworkResilienceService.shared
    private let intel = NordServerIntelligence.shared
    private let connectionPool = ProxyConnectionPool.shared
    private let healthMonitor = ProxyHealthMonitor.shared
    private let logger = DebugLogger.shared

    let configResolver = ProxyConfigResolver()
    private(set) var perSessionManager: PerSessionTunnelManager!
    private(set) var rotationManager: ProxyRotationManager!

    private let settingsKey = "device_proxy_settings_v2"
    private var isLoadingSettings: Bool = true

    var localProxyEnabled: Bool = true {
        didSet {
            guard !isLoadingSettings else { return }
            persistSettings()
            if isEnabled {
                localProxyEnabled ? localProxy.start() : localProxy.stop()
                rotationManager.syncLocalProxyUpstream(localProxyEnabled: localProxyEnabled)
            }
        }
    }

    var ipRoutingMode: IPRoutingMode = .appWideUnited {
        didSet {
            guard !isLoadingSettings else { return }
            persistSettings()
            if ipRoutingMode == .appWideUnited {
                perSessionManager.stopWireProxy()
                perSessionManager.stopOpenVPN()
                activateUnifiedMode()
            } else {
                deactivateUnifiedMode()
                activatePerSessionMode()
            }
        }
    }

    var rotationInterval: RotationInterval = .everyBatch {
        didSet { guard !isLoadingSettings else { return }; persistSettings(); restartRotationTimer() }
    }

    var rotateOnBatchStart: Bool = false {
        didSet { guard !isLoadingSettings else { return }; persistSettings() }
    }

    var rotateOnFingerprintDetection: Bool = true {
        didSet { guard !isLoadingSettings else { return }; persistSettings() }
    }

    var autoFailoverEnabled: Bool = true {
        didSet { guard !isLoadingSettings else { return }; persistSettings(); healthMonitor.autoFailoverEnabled = autoFailoverEnabled }
    }

    var healthCheckInterval: TimeInterval = 30 {
        didSet { guard !isLoadingSettings else { return }; persistSettings(); healthMonitor.checkIntervalSeconds = healthCheckInterval }
    }

    var maxFailuresBeforeRotation: Int = 3 {
        didSet { guard !isLoadingSettings else { return }; persistSettings(); healthMonitor.maxConsecutiveFailures = maxFailuresBeforeRotation }
    }

    init() {
        let resolver = configResolver
        perSessionManager = PerSessionTunnelManager(configResolver: resolver)
        rotationManager = ProxyRotationManager(configResolver: resolver)
        loadSettings()
        isLoadingSettings = false
        healthMonitor.autoFailoverEnabled = autoFailoverEnabled
        healthMonitor.checkIntervalSeconds = healthCheckInterval
        healthMonitor.maxConsecutiveFailures = maxFailuresBeforeRotation
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.cleanupStaleTunnelsOnLaunch()
            if self.ipRoutingMode == .appWideUnited {
                self.activateUnifiedMode()
            } else {
                self.activatePerSessionMode()
            }
        }
    }

    // MARK: - Computed — State Passthrough

    var isEnabled: Bool { ipRoutingMode == .appWideUnited }
    var isVPNActive: Bool { false }

    var activeConfig: ActiveNetworkConfig? { rotationManager.activeConfig }
    var activeEndpointLabel: String? { rotationManager.activeEndpointLabel }
    var activeConnectionType: String { rotationManager.activeConnectionType }
    var activeSince: Date? { rotationManager.activeSince }
    var isActive: Bool { rotationManager.isActive }
    var isRotating: Bool { rotationManager.isRotating }
    var rotationLog: [RotationLogEntry] { rotationManager.rotationLog }
    var nextRotationDate: Date? { rotationManager.nextRotationDate }
    var failoverCount: Int { rotationManager.failoverCount }
    var secondsUntilRotation: Int? { rotationManager.secondsUntilRotation }
    var rotationCountdownLabel: String { rotationManager.rotationCountdownLabel }

    // MARK: - Computed — Tunnel Visibility

    var isWireProxyCompatibleMode: Bool { proxyService.unifiedConnectionMode == .wireguard }
    var isOpenVPNProxyCompatibleMode: Bool { proxyService.unifiedConnectionMode == .openvpn }
    var isOpenVPNBridgeActive: Bool { ovpnBridge.isActive }
    var openVPNBridgeStatus: OpenVPNBridgeStatus { ovpnBridge.status }
    var openVPNBridgeStats: OpenVPNBridgeStats { ovpnBridge.stats }
    var isWireProxyActive: Bool { wireProxyBridge.isActive }
    var wireProxyStatus: WireProxyStatus { wireProxyBridge.status }
    var wireProxyStats: WireProxyStats { wireProxyBridge.stats }

    var shouldShowWireProxySection: Bool {
        isWireProxyCompatibleMode || perSessionManager.wireProxyActive || wireProxyBridge.isActive
    }
    var shouldShowOpenVPNSection: Bool {
        isOpenVPNProxyCompatibleMode || perSessionManager.openVPNActive || ovpnBridge.isActive
    }
    var shouldShowWireProxyDashboard: Bool { shouldShowWireProxySection && wireProxyBridge.isActive }
    var shouldShowOpenVPNDashboard: Bool { shouldShowOpenVPNSection && ovpnBridge.isActive }

    var canManageWireProxyTunnel: Bool {
        guard shouldShowWireProxySection else { return false }
        if isEnabled { guard case .wireGuardDNS = activeConfig else { return false }; return true }
        return perSessionManager.wireProxyActive
    }

    var canManageOpenVPNBridge: Bool {
        guard shouldShowOpenVPNSection else { return false }
        if isEnabled { guard case .openVPNProxy = activeConfig else { return false }; return true }
        return perSessionManager.openVPNActive
    }

    // MARK: - Computed — Per-Session Passthrough

    var perSessionWireProxyActive: Bool { perSessionManager.wireProxyActive }
    var perSessionWireProxyStarting: Bool { perSessionManager.wireProxyStarting }
    var perSessionOpenVPNActive: Bool { perSessionManager.openVPNActive }
    var perSessionOpenVPNStarting: Bool { perSessionManager.openVPNStarting }
    var perSessionTunnelCount: Int { perSessionManager.tunnelCount }
    var isMultiTunnelActive: Bool { perSessionManager.isMultiTunnelActive }

    var wireProxyActiveConfigLabel: String? {
        if isEnabled, case .wireGuardDNS(let wg) = activeConfig { return wg.serverName }
        return perSessionManager.wireProxyConfigLabel
    }

    var openVPNActiveConfigLabel: String? {
        if isEnabled, case .openVPNProxy(let ovpn) = activeConfig { return ovpn.serverName }
        return perSessionManager.openVPNConfigLabel
    }

    var isPerSessionTunnelStarting: Bool {
        perSessionManager.wireProxyStarting || perSessionManager.openVPNStarting
    }

    var effectiveProxyConfig: ProxyConfig? {
        if ipRoutingMode == .appWideUnited, isActive, localProxyEnabled, localProxy.isRunning {
            switch activeConfig {
            case .socks5: return localProxy.localProxyConfig
            case .wireGuardDNS:
                return (isWireProxyCompatibleMode && wireProxyBridge.isActive) ? localProxy.localProxyConfig : nil
            case .openVPNProxy:
                return (ovpnBridge.isActive && localProxy.openVPNProxyMode) ? localProxy.localProxyConfig : nil
            case .direct, .none: return nil
            }
        }
        if ipRoutingMode == .separatePerSession, localProxyEnabled, localProxy.isRunning {
            if perSessionManager.wireProxyActive, wireProxyBridge.isActive, localProxy.wireProxyMode {
                return localProxy.localProxyConfig
            }
            if perSessionManager.openVPNActive, ovpnBridge.isActive, localProxy.openVPNProxyMode {
                return localProxy.localProxyConfig
            }
        }
        return nil
    }

    // MARK: - Public Actions

    func cancel() {}

    func rotateNow(reason: String = "Manual") {
        rotationManager.performRotation(reason: reason, rotationInterval: rotationInterval)
        rotationManager.syncLocalProxyUpstream(localProxyEnabled: localProxyEnabled)
    }

    func notifyBatchStart() {
        if isEnabled {
            if rotateOnBatchStart || rotationInterval == .everyBatch {
                rotateNow(reason: "Batch Start")
            }
            return
        }
        guard rotateOnBatchStart else { return }
        if perSessionManager.wireProxyActive {
            perSessionManager.rotateWireProxy(localProxyEnabled: localProxyEnabled)
            logger.log("DeviceProxy: per-session WireGuard rotated on batch start", category: .vpn, level: .info)
        }
        if perSessionManager.openVPNActive {
            perSessionManager.rotateOpenVPN(localProxyEnabled: localProxyEnabled)
            logger.log("DeviceProxy: per-session OpenVPN rotated on batch start", category: .vpn, level: .info)
        }
        if proxyService.unifiedConnectionMode == .hybrid {
            HybridNetworkingService.shared.resetBatch()
            logger.log("DeviceProxy: hybrid mode reset for new batch", category: .network, level: .info)
        }
        NetworkSessionFactory.shared.resetRotationIndexes()
        logger.log("DeviceProxy: per-session rotation indexes reset on batch start (mode: \(proxyService.unifiedConnectionMode.label))", category: .network, level: .info)
    }

    func notifyFingerprintDetected() {
        guard isEnabled, rotateOnFingerprintDetection else { return }
        rotateNow(reason: "Fingerprint Detected")
    }

    func handleUnifiedConnectionModeChange() {
        let mode = proxyService.unifiedConnectionMode

        if mode != .wireguard {
            wireProxyBridge.stop()
            localProxy.enableWireProxyMode(false)
            perSessionManager.stopWireProxy()
            logger.log("DeviceProxy: force-stopped all WireProxy/WireGuard for mode change → \(mode.label)", category: .vpn, level: .info)
        }
        if mode != .openvpn {
            ovpnBridge.stop()
            localProxy.enableOpenVPNProxyMode(false)
            perSessionManager.stopOpenVPN()
            logger.log("DeviceProxy: force-stopped all OpenVPN for mode change → \(mode.label)", category: .vpn, level: .info)
        }
        if mode == .direct || mode == .dns {
            localProxy.stop()
            logger.log("DeviceProxy: stopped local proxy — no tunnel/proxy needed for \(mode.label)", category: .network, level: .info)
        }
        isEnabled ? rotateNow(reason: "Connection Mode Changed") : activatePerSessionMode()
    }

    // MARK: - Tunnel Management

    func reconnectWireProxy() {
        if !isEnabled && (perSessionManager.wireProxyActive || perSessionManager.wireProxyStarting) {
            perSessionManager.stopWireProxy()
            logger.log("DeviceProxy: WireProxy reconnect requested (per-session)", category: .vpn, level: .info)
            perSessionManager.activateWireProxy(localProxyEnabled: localProxyEnabled)
            return
        }
        guard canManageWireProxyTunnel else { return }
        wireProxyBridge.stop()
        localProxy.enableWireProxyMode(false)
        logger.log("DeviceProxy: WireProxy reconnect requested", category: .vpn, level: .info)
        rotationManager.syncWireProxyTunnel()
    }

    func stopWireProxy() {
        wireProxyBridge.stop()
        localProxy.enableWireProxyMode(false)
        if !isEnabled { perSessionManager.stopWireProxy() }
        logger.log("DeviceProxy: WireProxy manually stopped", category: .vpn, level: .info)
    }

    func reconnectOpenVPN() {
        if !isEnabled && (perSessionManager.openVPNActive || perSessionManager.openVPNStarting) {
            perSessionManager.stopOpenVPN()
            logger.log("DeviceProxy: OpenVPN reconnect requested (per-session)", category: .vpn, level: .info)
            perSessionManager.activateOpenVPN(localProxyEnabled: localProxyEnabled)
            return
        }
        guard canManageOpenVPNBridge else { return }
        ovpnBridge.stop()
        localProxy.enableOpenVPNProxyMode(false)
        logger.log("DeviceProxy: OpenVPN reconnect requested", category: .vpn, level: .info)
        if case .openVPNProxy(let ovpn) = activeConfig {
            rotationManager.syncOpenVPNProxyBridge(ovpn)
        }
    }

    func stopOpenVPN() {
        ovpnBridge.stop()
        localProxy.enableOpenVPNProxyMode(false)
        if !isEnabled { perSessionManager.stopOpenVPN() }
        logger.log("DeviceProxy: OpenVPN manually stopped", category: .vpn, level: .info)
    }

    func activatePerSessionWireProxy() {
        guard !isEnabled else { return }
        perSessionManager.activateWireProxy(localProxyEnabled: localProxyEnabled)
    }

    func activatePerSessionOpenVPN() {
        guard !isEnabled else { return }
        perSessionManager.activateOpenVPN(localProxyEnabled: localProxyEnabled)
    }

    func rotatePerSessionWireProxy() {
        guard !isEnabled else { return }
        perSessionManager.rotateWireProxy(localProxyEnabled: localProxyEnabled)
    }

    func rotatePerSessionOpenVPN() {
        guard !isEnabled else { return }
        perSessionManager.rotateOpenVPN(localProxyEnabled: localProxyEnabled)
    }

    func rotateWireProxyConfig() {
        if !isEnabled && perSessionManager.wireProxyActive {
            perSessionManager.rotateWireProxy(localProxyEnabled: localProxyEnabled)
            return
        }
        guard canManageWireProxyTunnel else { return }
        rotationManager.rotateWireProxyConfig()
    }

    func handleProfileSwitch() {
        perSessionManager.resetAll()
        localProxy.updateUpstream(nil)
        intel.clearAll()
        rotationManager.resetState()

        if ipRoutingMode == .appWideUnited {
            rotateNow(reason: "Profile Switch")
        } else {
            activatePerSessionMode()
        }
        let profile = NordVPNService.shared.activeKeyProfile
        logger.log("DeviceProxy: profile switched to \(profile.rawValue) — tunnel stopped, state reset, configs reloaded", category: .network, level: .success)
    }

    private func cleanupStaleTunnelsOnLaunch() {
        let mode = proxyService.unifiedConnectionMode
        var didClean = false

        if mode != .wireguard {
            if wireProxyBridge.isActive || localProxy.wireProxyMode {
                wireProxyBridge.stop()
                localProxy.enableWireProxyMode(false)
                didClean = true
            }
        }
        if mode != .openvpn {
            if ovpnBridge.isActive || localProxy.openVPNProxyMode {
                ovpnBridge.stop()
                localProxy.enableOpenVPNProxyMode(false)
                didClean = true
            }
        }
        if mode == .direct {
            if localProxy.isRunning {
                localProxy.stop()
                didClean = true
            }
        }
        if didClean {
            logger.log("DeviceProxy: launch cleanup — killed stale tunnels/bridges for mode \(mode.label)", category: .vpn, level: .warning)
        }
    }

    func forceStopAllTunnels() {
        wireProxyBridge.stop()
        ovpnBridge.stop()
        localProxy.enableWireProxyMode(false)
        localProxy.enableOpenVPNProxyMode(false)
        perSessionManager.stopWireProxy()
        perSessionManager.stopOpenVPN()
        rotationManager.stopActiveTunnels()
        logger.log("DeviceProxy: force-stopped ALL tunnels/proxies/bridges", category: .vpn, level: .info)
    }

    // MARK: - Mode Activation

    private func activateUnifiedMode() {
        if localProxyEnabled { localProxy.start() }
        resilience.resetBackoff()
        intel.startMonitoring()
        rotateNow(reason: "Activated")
        restartRotationTimer()

        localProxy.startHealthMonitoring { [weak self] in
            Task { @MainActor [weak self] in self?.handleUpstreamFailover() }
        }

        if case .socks5(let proxy) = activeConfig {
            resilience.startVerificationLoop(expectedProxy: proxy)
        }
        connectionPool.prewarmConnections(count: 3, upstream: localProxy.upstreamProxy)
        logger.log("DeviceProxy: App-Wide United IP ENABLED (localProxy: \(localProxyEnabled), autoFailover: \(autoFailoverEnabled))", category: .network, level: .info)
    }

    private func deactivateUnifiedMode() {
        rotationManager.invalidateTimer()
        rotationManager.resetState()
        rotationManager.stopActiveTunnels()
        localProxy.stop()
        intel.stopMonitoring()
        resilience.stopVerificationLoop()
        resilience.resetBackoff()
        resilience.resetThrottling()
        logger.log("DeviceProxy: App-Wide United IP DISABLED", category: .network, level: .info)
    }

    private func activatePerSessionMode() {
        let mode = proxyService.unifiedConnectionMode

        if mode != .wireguard {
            if perSessionManager.wireProxyActive || perSessionManager.wireProxyStarting || wireProxyBridge.isActive {
                wireProxyBridge.stop()
                localProxy.enableWireProxyMode(false)
                perSessionManager.stopWireProxy()
                logger.log("DeviceProxy: stopping stale WireProxy/WireGuard (mode now: \(mode.label))", category: .vpn, level: .info)
            }
        }
        if mode != .openvpn {
            if perSessionManager.openVPNActive || perSessionManager.openVPNStarting || ovpnBridge.isActive {
                ovpnBridge.stop()
                localProxy.enableOpenVPNProxyMode(false)
                perSessionManager.stopOpenVPN()
                logger.log("DeviceProxy: stopping stale OpenVPN (mode now: \(mode.label))", category: .vpn, level: .info)
            }
        }

        switch mode {
        case .direct:
            localProxy.stop()
            logger.log("DeviceProxy: DIRECT mode — no proxy/tunnel, bypassing all network layers", category: .network, level: .info)

        case .wireguard:
            if !perSessionManager.wireProxyActive && !perSessionManager.wireProxyStarting {
                perSessionManager.activateWireProxy(localProxyEnabled: localProxyEnabled)
            } else if perSessionManager.wireProxyActive && !perSessionManager.isTunnelHealthy {
                logger.log("DeviceProxy: per-session WireProxy unhealthy — reactivating", category: .vpn, level: .warning)
                perSessionManager.stopWireProxy()
                perSessionManager.activateWireProxy(localProxyEnabled: localProxyEnabled)
            }

        case .openvpn:
            if !perSessionManager.openVPNActive && !perSessionManager.openVPNStarting {
                perSessionManager.activateOpenVPN(localProxyEnabled: localProxyEnabled)
            } else if perSessionManager.openVPNActive && !perSessionManager.isTunnelHealthy {
                logger.log("DeviceProxy: per-session OpenVPN unhealthy — reactivating", category: .vpn, level: .warning)
                perSessionManager.stopOpenVPN()
                perSessionManager.activateOpenVPN(localProxyEnabled: localProxyEnabled)
            }

        case .proxy, .dns, .nodeMaven, .hybrid:
            NetworkSessionFactory.shared.resetRotationIndexes()
            logger.log("DeviceProxy: per-session mode active for \(mode.label) — each session gets its own IP from the pool", category: .network, level: .info)
        }
    }

    // MARK: - Failover & Timer

    private func handleUpstreamFailover() {
        guard isEnabled else { return }
        rotationManager.handleFailover(autoFailoverEnabled: autoFailoverEnabled) { [weak self] reason in
            self?.rotateNow(reason: reason)
        }
    }

    private func restartRotationTimer() {
        rotationManager.restartRotationTimer(ipRoutingMode: ipRoutingMode, rotationInterval: rotationInterval) { [weak self] reason in
            self?.rotateNow(reason: reason)
        }
    }

    // MARK: - Persistence

    private func persistSettings() {
        let dict: [String: Any] = [
            "ipRoutingMode": ipRoutingMode.rawValue,
            "interval": rotationInterval.rawValue,
            "rotateOnBatch": rotateOnBatchStart,
            "rotateOnFingerprint": rotateOnFingerprintDetection,
            "localProxy": localProxyEnabled,
            "autoFailover": autoFailoverEnabled,
            "healthCheckInterval": healthCheckInterval,
            "maxFailures": maxFailuresBeforeRotation,
        ]
        UserDefaults.standard.set(dict, forKey: settingsKey)
    }

    private func loadSettings() {
        let dict = UserDefaults.standard.dictionary(forKey: settingsKey) ?? UserDefaults.standard.dictionary(forKey: "device_proxy_settings_v1")
        guard let dict else { return }
        if let modeRaw = dict["ipRoutingMode"] as? String, let mode = IPRoutingMode(rawValue: modeRaw) {
            ipRoutingMode = mode
        } else if let enabled = dict["enabled"] as? Bool {
            ipRoutingMode = enabled ? .appWideUnited : .separatePerSession
        }
        if let interval = dict["interval"] as? String, let parsed = RotationInterval(rawValue: interval) { rotationInterval = parsed }
        if let batch = dict["rotateOnBatch"] as? Bool { rotateOnBatchStart = batch }
        if let fp = dict["rotateOnFingerprint"] as? Bool { rotateOnFingerprintDetection = fp }
        if let lp = dict["localProxy"] as? Bool { localProxyEnabled = lp }
        if let af = dict["autoFailover"] as? Bool { autoFailoverEnabled = af }
        if let hci = dict["healthCheckInterval"] as? TimeInterval { healthCheckInterval = hci }
        if let mf = dict["maxFailures"] as? Int { maxFailuresBeforeRotation = mf }
    }
}
