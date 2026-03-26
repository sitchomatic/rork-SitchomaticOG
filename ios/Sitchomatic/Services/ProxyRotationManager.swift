import Foundation

@MainActor
class ProxyRotationManager {
    private let configResolver: ProxyConfigResolver
    private let localProxy = LocalProxyServer.shared
    private let wireProxyBridge = WireProxyBridge.shared
    private let ovpnBridge = OpenVPNProxyBridge.shared
    private let proxyService = ProxyRotationService.shared
    private let resilience = NetworkResilienceService.shared
    private let connectionPool = ProxyConnectionPool.shared
    private let logger = DebugLogger.shared

    private var rotationTimer: Timer?

    private(set) var rotationLog: [RotationLogEntry] = []
    private(set) var nextRotationDate: Date?
    private(set) var isRotating: Bool = false
    private(set) var failoverCount: Int = 0

    private(set) var activeConfig: ActiveNetworkConfig?
    private(set) var activeEndpointLabel: String?
    private(set) var activeConnectionType: String = "None"
    private(set) var activeSince: Date?
    private(set) var isActive: Bool = false

    init(configResolver: ProxyConfigResolver) {
        self.configResolver = configResolver
    }

    var secondsUntilRotation: Int? {
        guard let next = nextRotationDate else { return nil }
        return max(0, Int(next.timeIntervalSinceNow))
    }

    var rotationCountdownLabel: String {
        guard let seconds = secondsUntilRotation else { return "--:--" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var isWireProxyCompatibleMode: Bool { proxyService.unifiedConnectionMode == .wireguard }
    var isOpenVPNProxyCompatibleMode: Bool { proxyService.unifiedConnectionMode == .openvpn }

    // MARK: - Rotation

    func performRotation(reason: String, rotationInterval: RotationInterval) {
        isRotating = true
        let previousLabel = activeEndpointLabel ?? "None"

        stopActiveTunnels()

        let config = configResolver.resolveNextConfig()
        applyConfig(config)

        rotationLog.insert(RotationLogEntry(fromLabel: previousLabel, toLabel: activeEndpointLabel ?? "Unknown", reason: reason), at: 0)
        if rotationLog.count > 20 { rotationLog = Array(rotationLog.prefix(20)) }
        if let interval = rotationInterval.seconds { nextRotationDate = Date().addingTimeInterval(interval) }

        resilience.resetBackoff()

        if case .socks5(let proxy) = config {
            resilience.startVerificationLoop(expectedProxy: proxy)
            connectionPool.prewarmConnections(count: 2, upstream: proxy)
        } else {
            resilience.stopVerificationLoop()
        }

        isRotating = false
        logger.log("DeviceProxy: rotated to \(activeEndpointLabel ?? "Unknown") (reason: \(reason))", category: .network, level: .info)
    }

    func handleFailover(autoFailoverEnabled: Bool, onRotate: @escaping (String) -> Void) {
        guard autoFailoverEnabled else { return }
        if resilience.shouldThrottleFailover() {
            logger.log("DeviceProxy: FAILOVER throttled — backoff \(String(format: "%.1f", resilience.failoverBackoffSeconds))s remaining", category: .proxy, level: .warning)
            return
        }
        let backoffDelay = resilience.calculateBackoffDelay()
        failoverCount += 1
        logger.log("DeviceProxy: FAILOVER triggered (count: \(failoverCount), backoff: \(String(format: "%.1f", backoffDelay))s) - upstream dead, rotating to next", category: .proxy, level: .error)
        Task {
            try? await Task.sleep(for: .seconds(backoffDelay))
            onRotate("Failover (upstream dead, attempt \(self.failoverCount))")
        }
    }

    // MARK: - Timer

    func restartRotationTimer(ipRoutingMode: IPRoutingMode, rotationInterval: RotationInterval, onRotate: @escaping (String) -> Void) {
        invalidateTimer()
        guard ipRoutingMode == .appWideUnited, let interval = rotationInterval.seconds else { return }
        nextRotationDate = Date().addingTimeInterval(interval)
        rotationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                onRotate("Timer (\(self?.rotationCountdownLabel ?? ""))")
            }
        }
    }

    func invalidateTimer() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        nextRotationDate = nil
    }

    // MARK: - Upstream Sync

    func syncLocalProxyUpstream(localProxyEnabled: Bool) {
        guard localProxyEnabled else { localProxy.updateUpstream(nil); return }
        switch activeConfig {
        case .socks5(let proxy):
            localProxy.enableWireProxyMode(false)
            localProxy.enableOpenVPNProxyMode(false)
            localProxy.updateUpstream(proxy)
        case .wireGuardDNS:
            localProxy.enableOpenVPNProxyMode(false)
            guard isWireProxyCompatibleMode else {
                wireProxyBridge.stop()
                localProxy.enableWireProxyMode(false)
                localProxy.updateUpstream(nil)
                return
            }
            syncWireProxyTunnel()
        case .openVPNProxy(let ovpn):
            localProxy.enableWireProxyMode(false)
            syncOpenVPNProxyBridge(ovpn)
        default:
            localProxy.enableWireProxyMode(false)
            localProxy.enableOpenVPNProxyMode(false)
            localProxy.updateUpstream(nil)
        }
    }

    // MARK: - WireGuard Tunnel Sync

    func syncWireProxyTunnel() {
        guard isWireProxyCompatibleMode,
              case .wireGuardDNS(let wg) = activeConfig else {
            wireProxyBridge.stop()
            localProxy.enableWireProxyMode(false)
            return
        }
        if wireProxyBridge.isActive { wireProxyBridge.stop() }
        Task {
            await wireProxyBridge.start(with: wg)
            if wireProxyBridge.isActive {
                localProxy.enableWireProxyMode(true)
                logger.log("DeviceProxy: WireProxy tunnel active for \(wg.serverName)", category: .vpn, level: .success)
            } else {
                localProxy.enableWireProxyMode(false)
                logger.log("DeviceProxy: WireProxy tunnel failed for \(wg.serverName) — retrying with next config", category: .vpn, level: .error)
                await retryTunnelWithNextConfig(type: .wireGuard, failedServer: wg.serverName)
            }
        }
    }

    func syncOpenVPNProxyBridge(_ config: OpenVPNConfig) {
        if ovpnBridge.isActive { ovpnBridge.stop() }
        Task {
            await ovpnBridge.start(with: config)
            if ovpnBridge.isActive {
                localProxy.enableOpenVPNProxyMode(true)
                logger.log("DeviceProxy: OpenVPN bridge active → \(ovpnBridge.activeProxyLabel ?? "unknown") for \(config.serverName), handler mode enabled", category: .vpn, level: .success)
            } else {
                localProxy.enableOpenVPNProxyMode(false)
                logger.log("DeviceProxy: OpenVPN bridge failed for \(config.serverName) — retrying with next config", category: .vpn, level: .error)
                await retryTunnelWithNextConfig(type: .openVPN, failedServer: config.serverName)
            }
        }
    }

    // MARK: - Config Rotation for Specific Tunnels

    func rotateWireProxyConfig() {
        wireProxyBridge.stop()
        localProxy.enableWireProxyMode(false)
        let config = configResolver.resolveNextConfig()
        applyConfig(config)
        if case .wireGuardDNS(let wg) = config {
            Task {
                await wireProxyBridge.start(with: wg)
                if wireProxyBridge.isActive {
                    localProxy.enableWireProxyMode(true)
                    logger.log("DeviceProxy: WireProxy rotated to \(wg.serverName)", category: .vpn, level: .success)
                } else {
                    localProxy.enableWireProxyMode(false)
                    logger.log("DeviceProxy: WireProxy rotation failed for \(wg.serverName)", category: .vpn, level: .error)
                }
            }
        } else {
            logger.log("DeviceProxy: WireProxy rotation landed on non-WG config, tunnel stopped", category: .vpn, level: .warning)
        }
    }

    // MARK: - State Reset

    func resetState() {
        activeConfig = nil
        activeEndpointLabel = nil
        activeConnectionType = "None"
        activeSince = nil
        isActive = false
        rotationLog.removeAll()
        configResolver.resetIndexes()
    }

    func stopActiveTunnels() {
        if wireProxyBridge.isActive {
            wireProxyBridge.stop()
            localProxy.enableWireProxyMode(false)
        }
        if ovpnBridge.isActive {
            ovpnBridge.stop()
            localProxy.enableOpenVPNProxyMode(false)
        }
    }

    // MARK: - Private

    private func applyConfig(_ config: ActiveNetworkConfig) {
        activeConfig = config
        activeSince = Date()
        isActive = true
        switch config {
        case .wireGuardDNS(let wg):
            activeEndpointLabel = "WG: \(wg.fileName)"; activeConnectionType = "WireGuard"
        case .openVPNProxy(let ovpn):
            activeEndpointLabel = "OVPN: \(ovpn.fileName)"; activeConnectionType = "OpenVPN"
        case .socks5(let proxy):
            activeEndpointLabel = "SOCKS5: \(proxy.displayString)"; activeConnectionType = "SOCKS5"
        case .direct:
            activeEndpointLabel = "Direct"; activeConnectionType = "Direct"
        }
    }

    private enum TunnelType { case wireGuard, openVPN }

    private func retryTunnelWithNextConfig(type: TunnelType, failedServer: String) async {
        let targets: [ProxyRotationService.ProxyTarget] = [.joe, .ignition, .ppsr]
        let label = type == .wireGuard ? "WireProxy" : "OpenVPN"

        switch type {
        case .wireGuard:
            let candidates = configResolver.collectUniqueWG(targets: targets).filter { $0.serverName != failedServer }
            guard !candidates.isEmpty else {
                logger.log("DeviceProxy: no alternative WG configs for retry", category: .vpn, level: .error)
                return
            }
            let maxRetries = min(candidates.count, 4)
            for attempt in 0..<maxRetries {
                let nextWG = candidates[attempt % candidates.count]
                activeConfig = .wireGuardDNS(nextWG)
                activeEndpointLabel = "WG: \(nextWG.fileName)"
                activeConnectionType = "WireGuard"
                wireProxyBridge.stop()
                try? await Task.sleep(for: .seconds(Double(attempt) * 0.5 + 0.5))
                await wireProxyBridge.start(with: nextWG)
                if wireProxyBridge.isActive {
                    configResolver.advanceWGIndex(by: attempt + 1)
                    localProxy.enableWireProxyMode(true)
                    logger.log("DeviceProxy: \(label) retry succeeded with \(nextWG.serverName) on attempt \(attempt + 1)/\(maxRetries)", category: .vpn, level: .success)
                    return
                }
                logger.log("DeviceProxy: \(label) retry attempt \(attempt + 1)/\(maxRetries) failed for \(nextWG.serverName)", category: .vpn, level: .warning)
            }
            configResolver.advanceWGIndex(by: maxRetries)
            localProxy.enableWireProxyMode(false)

        case .openVPN:
            let candidates = configResolver.collectUniqueOVPN(targets: targets).filter { $0.serverName != failedServer }
            guard !candidates.isEmpty else {
                logger.log("DeviceProxy: no alternative OVPN configs for retry", category: .vpn, level: .error)
                return
            }
            let maxRetries = min(candidates.count, 4)
            for attempt in 0..<maxRetries {
                let nextOVPN = candidates[attempt % candidates.count]
                activeConfig = .openVPNProxy(nextOVPN)
                activeEndpointLabel = "OVPN: \(nextOVPN.fileName)"
                activeConnectionType = "OpenVPN"
                ovpnBridge.stop()
                try? await Task.sleep(for: .seconds(Double(attempt) * 0.5 + 0.5))
                await ovpnBridge.start(with: nextOVPN)
                if ovpnBridge.isActive {
                    configResolver.advanceOVPNIndex(by: attempt + 1)
                    localProxy.enableOpenVPNProxyMode(true)
                    logger.log("DeviceProxy: \(label) retry succeeded with \(nextOVPN.serverName) on attempt \(attempt + 1)/\(maxRetries)", category: .vpn, level: .success)
                    return
                }
                logger.log("DeviceProxy: \(label) retry attempt \(attempt + 1)/\(maxRetries) failed for \(nextOVPN.serverName)", category: .vpn, level: .warning)
            }
            configResolver.advanceOVPNIndex(by: maxRetries)
            localProxy.enableOpenVPNProxyMode(false)
        }

        logger.log("DeviceProxy: \(label) all retry attempts exhausted", category: .vpn, level: .error)
    }
}
