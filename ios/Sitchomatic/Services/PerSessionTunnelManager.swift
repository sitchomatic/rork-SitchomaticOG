import Foundation

@MainActor
class PerSessionTunnelManager {
    private let proxyService = ProxyRotationService.shared
    private let localProxy = LocalProxyServer.shared
    private let wireProxyBridge = WireProxyBridge.shared
    private let ovpnBridge = OpenVPNProxyBridge.shared
    private let configResolver: ProxyConfigResolver
    private let logger = DebugLogger.shared

    private(set) var wireProxyActive: Bool = false
    private(set) var wireProxyStarting: Bool = false
    private var wgConfig: WireGuardConfig?

    private(set) var openVPNActive: Bool = false
    private(set) var openVPNStarting: Bool = false
    private var ovpnConfig: OpenVPNConfig?

    private var healthTimer: Timer?
    private let healthCheckInterval: TimeInterval = 8
    private var consecutiveFailures: Int = 0
    private let maxAutoRecoveryAttempts: Int = 3

    init(configResolver: ProxyConfigResolver) {
        self.configResolver = configResolver
    }

    var tunnelCount: Int { wireProxyBridge.activeTunnelCount }
    var isMultiTunnelActive: Bool { wireProxyBridge.multiTunnelMode && wireProxyBridge.activeTunnelCount > 1 }

    var wireProxyConfigLabel: String? {
        wireProxyActive ? wgConfig?.serverName : nil
    }

    var openVPNConfigLabel: String? {
        openVPNActive ? ovpnConfig?.serverName : nil
    }

    var isTunnelHealthy: Bool {
        if wireProxyActive {
            return wireProxyBridge.isActive && localProxy.wireProxyMode && localProxy.isRunning
        }
        if openVPNActive {
            return ovpnBridge.isActive && localProxy.openVPNProxyMode && localProxy.isRunning
        }
        return false
    }

    // MARK: - WireGuard Per-Session

    func activateWireProxy(localProxyEnabled: Bool) {
        guard !wireProxyStarting else {
            logger.log("DeviceProxy: per-session WireProxy activation already in progress", category: .vpn, level: .debug)
            return
        }

        stopOpenVPN()

        let targets: [ProxyRotationService.ProxyTarget] = [.joe, .ignition, .ppsr]
        let allWG = configResolver.collectUniqueWG(targets: targets)
        guard !allWG.isEmpty else {
            logger.log("DeviceProxy: no WG configs available for per-session WireProxy", category: .vpn, level: .warning)
            return
        }

        wireProxyStarting = true
        wireProxyBridge.stop()
        localProxy.enableWireProxyMode(false)

        Task {
            await ensureLocalProxyReady(enabled: localProxyEnabled)

            if allWG.count >= 2 {
                let multiConfigs = Array(allWG.prefix(min(allWG.count, 6)))
                wgConfig = multiConfigs.first
                await wireProxyBridge.startMultiple(configs: multiConfigs)
                if wireProxyBridge.isActive {
                    wireProxyActive = true
                    localProxy.enableWireProxyMode(true)
                    consecutiveFailures = 0
                    startHealthMonitoring()
                    logger.log("DeviceProxy: per-session multi-tunnel WireProxy active → \(wireProxyBridge.activeTunnelCount)/\(multiConfigs.count) tunnels", category: .vpn, level: .success)
                } else {
                    logger.log("DeviceProxy: per-session multi-tunnel WireProxy failed — falling back to single", category: .vpn, level: .error)
                    await fallbackToSingleTunnel(allWG: allWG, localProxyEnabled: localProxyEnabled)
                }
            } else {
                await startSingleWGTunnel(allWG: allWG, localProxyEnabled: localProxyEnabled)
            }

            if !wireProxyActive {
                wgConfig = nil
                localProxy.enableWireProxyMode(false)
                logger.log("DeviceProxy: per-session WireProxy failed to start after all attempts", category: .vpn, level: .error)
            }
            wireProxyStarting = false
        }
    }

    func rotateWireProxy(localProxyEnabled: Bool) {
        guard wireProxyActive, !wireProxyStarting else { return }
        stopHealthMonitoring()
        wireProxyBridge.stop()
        localProxy.enableWireProxyMode(false)
        wireProxyActive = false
        activateWireProxy(localProxyEnabled: localProxyEnabled)
    }

    func stopWireProxy() {
        stopHealthMonitoring()
        wireProxyBridge.stop()
        localProxy.enableWireProxyMode(false)
        wireProxyActive = false
        wireProxyStarting = false
        wgConfig = nil
        consecutiveFailures = 0
        logger.log("DeviceProxy: per-session WireProxy stopped", category: .vpn, level: .info)
    }

    private func startSingleWGTunnel(allWG: [WireGuardConfig], localProxyEnabled: Bool) async {
        guard !allWG.isEmpty else { return }
        let wg = allWG[0]
        wgConfig = wg
        await wireProxyBridge.start(with: wg)
        if wireProxyBridge.isActive {
            wireProxyActive = true
            localProxy.enableWireProxyMode(true)
            consecutiveFailures = 0
            startHealthMonitoring()
            logger.log("DeviceProxy: per-session WireProxy active → \(wg.serverName)", category: .vpn, level: .success)
        } else {
            logger.log("DeviceProxy: per-session WireProxy failed for \(wg.serverName) — retrying", category: .vpn, level: .error)
            await retryTunnel(type: .wireGuard, failedServer: wg.serverName, localProxyEnabled: localProxyEnabled)
        }
    }

    private func fallbackToSingleTunnel(allWG: [WireGuardConfig], localProxyEnabled: Bool) async {
        for wg in allWG {
            wireProxyBridge.stop()
            try? await Task.sleep(for: .seconds(0.3))
            await wireProxyBridge.start(with: wg)
            if wireProxyBridge.isActive {
                wgConfig = wg
                wireProxyActive = true
                localProxy.enableWireProxyMode(true)
                consecutiveFailures = 0
                startHealthMonitoring()
                logger.log("DeviceProxy: single-tunnel fallback succeeded → \(wg.serverName)", category: .vpn, level: .success)
                return
            }
        }
        localProxy.enableWireProxyMode(false)
        logger.log("DeviceProxy: all WG tunnel fallbacks failed", category: .vpn, level: .error)
    }

    // MARK: - OpenVPN Per-Session

    func activateOpenVPN(localProxyEnabled: Bool) {
        guard !openVPNStarting else {
            logger.log("DeviceProxy: per-session OpenVPN activation already in progress", category: .vpn, level: .debug)
            return
        }

        stopWireProxy()

        let targets: [ProxyRotationService.ProxyTarget] = [.joe, .ignition, .ppsr]
        let allOVPN = configResolver.collectUniqueOVPN(targets: targets)
        guard !allOVPN.isEmpty else {
            logger.log("DeviceProxy: no OVPN configs available for per-session OpenVPN", category: .vpn, level: .warning)
            return
        }

        openVPNStarting = true
        ovpnBridge.stop()
        localProxy.enableOpenVPNProxyMode(false)

        Task {
            await ensureLocalProxyReady(enabled: localProxyEnabled)

            let ovpn = allOVPN[0]
            ovpnConfig = ovpn
            await ovpnBridge.start(with: ovpn)
            if ovpnBridge.isActive {
                openVPNActive = true
                localProxy.enableOpenVPNProxyMode(true)
                consecutiveFailures = 0
                startHealthMonitoring()
                logger.log("DeviceProxy: per-session OpenVPN active → \(ovpn.serverName) via \(ovpnBridge.activeProxyLabel ?? "unknown")", category: .vpn, level: .success)
            } else {
                logger.log("DeviceProxy: per-session OpenVPN failed for \(ovpn.serverName) — retrying", category: .vpn, level: .error)
                await retryTunnel(type: .openVPN, failedServer: ovpn.serverName, localProxyEnabled: localProxyEnabled)
            }

            if !openVPNActive {
                ovpnConfig = nil
                localProxy.enableOpenVPNProxyMode(false)
                logger.log("DeviceProxy: per-session OpenVPN failed to start after all attempts", category: .vpn, level: .error)
            }
            openVPNStarting = false
        }
    }

    func rotateOpenVPN(localProxyEnabled: Bool) {
        guard openVPNActive, !openVPNStarting else { return }
        stopHealthMonitoring()
        ovpnBridge.stop()
        localProxy.enableOpenVPNProxyMode(false)
        openVPNActive = false
        activateOpenVPN(localProxyEnabled: localProxyEnabled)
    }

    func stopOpenVPN() {
        stopHealthMonitoring()
        ovpnBridge.stop()
        localProxy.enableOpenVPNProxyMode(false)
        openVPNActive = false
        openVPNStarting = false
        ovpnConfig = nil
        consecutiveFailures = 0
        logger.log("DeviceProxy: per-session OpenVPN stopped", category: .vpn, level: .info)
    }

    // MARK: - Health Monitoring

    private func startHealthMonitoring() {
        stopHealthMonitoring()
        healthTimer = Timer.scheduledTimer(withTimeInterval: healthCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPerSessionHealth()
            }
        }
    }

    private func stopHealthMonitoring() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func checkPerSessionHealth() {
        if wireProxyActive && !wireProxyStarting {
            let bridgeAlive = wireProxyBridge.isActive
            let localReady = localProxy.isRunning && localProxy.wireProxyMode

            if !bridgeAlive || !localReady {
                consecutiveFailures += 1
                logger.log("DeviceProxy: per-session WireProxy health FAIL (\(consecutiveFailures)/\(maxAutoRecoveryAttempts)) — bridge: \(bridgeAlive), localProxy: \(localReady)", category: .vpn, level: .warning)

                if consecutiveFailures >= maxAutoRecoveryAttempts {
                    logger.log("DeviceProxy: per-session WireProxy exceeded max recovery attempts — stopping", category: .vpn, level: .error)
                    stopWireProxy()
                    return
                }

                if !bridgeAlive {
                    attemptWireProxyRecovery()
                } else if !localReady {
                    repairLocalProxyState()
                }
            } else {
                if consecutiveFailures > 0 {
                    logger.log("DeviceProxy: per-session WireProxy health recovered after \(consecutiveFailures) failures", category: .vpn, level: .success)
                }
                consecutiveFailures = 0
            }
        }

        if openVPNActive && !openVPNStarting {
            let bridgeAlive = ovpnBridge.isActive
            let localReady = localProxy.isRunning && localProxy.openVPNProxyMode

            if !bridgeAlive || !localReady {
                consecutiveFailures += 1
                logger.log("DeviceProxy: per-session OpenVPN health FAIL (\(consecutiveFailures)/\(maxAutoRecoveryAttempts)) — bridge: \(bridgeAlive), localProxy: \(localReady)", category: .vpn, level: .warning)

                if consecutiveFailures >= maxAutoRecoveryAttempts {
                    logger.log("DeviceProxy: per-session OpenVPN exceeded max recovery attempts — stopping", category: .vpn, level: .error)
                    stopOpenVPN()
                    return
                }

                if !localReady {
                    repairLocalProxyState()
                }
            } else {
                if consecutiveFailures > 0 {
                    logger.log("DeviceProxy: per-session OpenVPN health recovered after \(consecutiveFailures) failures", category: .vpn, level: .success)
                }
                consecutiveFailures = 0
            }
        }
    }

    private func attemptWireProxyRecovery() {
        guard wireProxyActive, !wireProxyStarting else { return }
        wireProxyStarting = true
        logger.log("DeviceProxy: per-session WireProxy auto-recovery starting", category: .vpn, level: .info)

        Task {
            wireProxyBridge.stop()
            localProxy.enableWireProxyMode(false)
            try? await Task.sleep(for: .seconds(1.0))

            if let config = wgConfig {
                await wireProxyBridge.start(with: config)
                if wireProxyBridge.isActive {
                    localProxy.enableWireProxyMode(true)
                    consecutiveFailures = 0
                    logger.log("DeviceProxy: per-session WireProxy auto-recovery SUCCEEDED → \(config.serverName)", category: .vpn, level: .success)
                } else {
                    let targets: [ProxyRotationService.ProxyTarget] = [.joe, .ignition, .ppsr]
                    let allWG = configResolver.collectUniqueWG(targets: targets).filter { $0.serverName != config.serverName }
                    for alt in allWG.prefix(3) {
                        wireProxyBridge.stop()
                        try? await Task.sleep(for: .seconds(0.5))
                        await wireProxyBridge.start(with: alt)
                        if wireProxyBridge.isActive {
                            wgConfig = alt
                            localProxy.enableWireProxyMode(true)
                            consecutiveFailures = 0
                            logger.log("DeviceProxy: per-session WireProxy auto-recovery SUCCEEDED with alt → \(alt.serverName)", category: .vpn, level: .success)
                            wireProxyStarting = false
                            return
                        }
                    }
                    logger.log("DeviceProxy: per-session WireProxy auto-recovery FAILED — all servers exhausted", category: .vpn, level: .error)
                }
            }
            wireProxyStarting = false
        }
    }

    private func repairLocalProxyState() {
        if !localProxy.isRunning {
            localProxy.start()
            logger.log("DeviceProxy: repaired local proxy — restarted", category: .vpn, level: .info)
        }
        if wireProxyActive && wireProxyBridge.isActive && !localProxy.wireProxyMode {
            localProxy.enableWireProxyMode(true)
            logger.log("DeviceProxy: repaired local proxy — re-enabled wireProxyMode", category: .vpn, level: .info)
        }
        if openVPNActive && ovpnBridge.isActive && !localProxy.openVPNProxyMode {
            localProxy.enableOpenVPNProxyMode(true)
            logger.log("DeviceProxy: repaired local proxy — re-enabled openVPNProxyMode", category: .vpn, level: .info)
        }
    }

    // MARK: - Shared Retry

    private enum TunnelType { case wireGuard, openVPN }

    private func retryTunnel(type: TunnelType, failedServer: String, localProxyEnabled: Bool) async {
        let targets: [ProxyRotationService.ProxyTarget] = [.joe, .ignition, .ppsr]
        let label = type == .wireGuard ? "WireProxy" : "OpenVPN"

        switch type {
        case .wireGuard:
            let allWG = configResolver.collectUniqueWG(targets: targets)
            let candidates = allWG.filter { $0.serverName != failedServer }
            guard !candidates.isEmpty else {
                logger.log("DeviceProxy: no alternative WG configs for per-session retry", category: .vpn, level: .error)
                return
            }
            let maxRetries = min(candidates.count, 5)
            for i in 0..<maxRetries {
                let next = candidates[i % candidates.count]
                wgConfig = next
                wireProxyBridge.stop()
                try? await Task.sleep(for: .seconds(Double(i) * 0.5 + 0.5))
                await wireProxyBridge.start(with: next)
                if wireProxyBridge.isActive {
                    configResolver.advanceWGIndex(by: i + 1)
                    wireProxyActive = true
                    localProxy.enableWireProxyMode(true)
                    consecutiveFailures = 0
                    startHealthMonitoring()
                    logger.log("DeviceProxy: per-session \(label) retry succeeded → \(next.serverName) on attempt \(i + 1)/\(maxRetries)", category: .vpn, level: .success)
                    return
                }
                logger.log("DeviceProxy: per-session \(label) retry \(i + 1)/\(maxRetries) failed for \(next.serverName)", category: .vpn, level: .warning)
            }
            configResolver.advanceWGIndex(by: maxRetries)
            localProxy.enableWireProxyMode(false)

        case .openVPN:
            let allOVPN = configResolver.collectUniqueOVPN(targets: targets)
            let candidates = allOVPN.filter { $0.serverName != failedServer }
            guard !candidates.isEmpty else {
                logger.log("DeviceProxy: no alternative OVPN configs for per-session retry", category: .vpn, level: .error)
                return
            }
            let maxRetries = min(candidates.count, 5)
            for i in 0..<maxRetries {
                let next = candidates[i % candidates.count]
                ovpnConfig = next
                ovpnBridge.stop()
                try? await Task.sleep(for: .seconds(Double(i) * 0.5 + 0.5))
                await ovpnBridge.start(with: next)
                if ovpnBridge.isActive {
                    configResolver.advanceOVPNIndex(by: i + 1)
                    openVPNActive = true
                    localProxy.enableOpenVPNProxyMode(true)
                    consecutiveFailures = 0
                    startHealthMonitoring()
                    logger.log("DeviceProxy: per-session \(label) retry succeeded → \(next.serverName) on attempt \(i + 1)/\(maxRetries)", category: .vpn, level: .success)
                    return
                }
                logger.log("DeviceProxy: per-session \(label) retry \(i + 1)/\(maxRetries) failed for \(next.serverName)", category: .vpn, level: .warning)
            }
            configResolver.advanceOVPNIndex(by: maxRetries)
            localProxy.enableOpenVPNProxyMode(false)
        }

        logger.log("DeviceProxy: per-session \(label) all retries exhausted", category: .vpn, level: .error)
    }

    // MARK: - Reset

    func resetAll() {
        stopHealthMonitoring()
        wireProxyBridge.stop()
        ovpnBridge.stop()
        localProxy.enableWireProxyMode(false)
        localProxy.enableOpenVPNProxyMode(false)
        wireProxyActive = false
        wgConfig = nil
        openVPNActive = false
        ovpnConfig = nil
        openVPNStarting = false
        wireProxyStarting = false
        consecutiveFailures = 0
    }

    // MARK: - Helpers

    private func ensureLocalProxyReady(enabled: Bool) async {
        guard enabled else { return }
        if !localProxy.isRunning {
            localProxy.start()
        }
        for _ in 0..<10 {
            if localProxy.isRunning && localProxy.listeningPort > 0 { return }
            try? await Task.sleep(for: .seconds(0.2))
        }
        if localProxy.isRunning {
            logger.log("DeviceProxy: local proxy running on port \(localProxy.listeningPort)", category: .network, level: .debug)
        } else {
            logger.log("DeviceProxy: local proxy failed to start within timeout", category: .network, level: .error)
        }
    }
}
