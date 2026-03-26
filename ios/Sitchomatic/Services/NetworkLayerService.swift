import Foundation
import Network
import Observation

@Observable
@MainActor
class NetworkLayerService {
    static let shared = NetworkLayerService()

    private let proxyService = ProxyRotationService.shared
    private let protocolTester = VPNProtocolTestService.shared
    private let vpnTunnel = VPNTunnelManager.shared
    private let logger = DebugLogger.shared

    var lastHealthCheck: Date?
    var wgHealthy: Bool = false
    var ovpnHealthy: Bool = false
    var socks5Healthy: Bool = false
    var directHealthy: Bool = true

    var activeMode: ConnectionMode = .wireguard
    var fallbackLog: [String] = []

    func resolveActiveConfig(for target: ProxyRotationService.ProxyTarget) async -> ActiveNetworkConfig {
        if vpnTunnel.isConnected {
            logger.log("NetworkLayer: device-wide VPN active — returning direct for \(target.rawValue)", category: .vpn, level: .debug)
            return .direct
        }

        let preferredMode = proxyService.connectionMode(for: target)
        activeMode = preferredMode

        switch preferredMode {
        case .wireguard:
            if let config = await resolveWireGuard(for: target) { return config }
            addFallbackLog("WireGuard unavailable for \(target.rawValue), trying OpenVPN")
            if let config = await resolveOpenVPN(for: target) { return config }
            addFallbackLog("OpenVPN unavailable for \(target.rawValue), trying SOCKS5")
            if let config = resolveSOCKS5(for: target) { return config }
            addFallbackLog("All network modes failed for \(target.rawValue), using Direct")
            return .direct

        case .openvpn:
            if let config = await resolveOpenVPN(for: target) { return config }
            addFallbackLog("OpenVPN unavailable for \(target.rawValue), trying SOCKS5")
            if let config = resolveSOCKS5(for: target) { return config }
            addFallbackLog("SOCKS5 unavailable for \(target.rawValue), trying WireGuard")
            if let config = await resolveWireGuard(for: target) { return config }
            addFallbackLog("All network modes failed for \(target.rawValue), using Direct")
            return .direct

        case .proxy:
            if let config = resolveSOCKS5(for: target) { return config }
            addFallbackLog("SOCKS5 unavailable for \(target.rawValue), using Direct")
            return .direct

        case .direct:
            return .direct

        case .dns:
            return .direct

        case .nodeMaven:
            let nm = NodeMavenService.shared
            if let proxy = nm.generateProxyConfig() { return .socks5(proxy) }
            addFallbackLog("NodeMaven not configured for \(target.rawValue), trying SOCKS5")
            if let config = resolveSOCKS5(for: target) { return config }
            addFallbackLog("All network modes failed for \(target.rawValue), using Direct")
            return .direct

        case .hybrid:
            return HybridNetworkingService.shared.nextHybridConfig(for: target)
        }
    }

    var wgHealthResults: [String: Bool] = [:]
    var ovpnHealthResults: [String: Bool] = [:]

    func runHealthCheck(for target: ProxyRotationService.ProxyTarget) async {
        logger.log("NetworkLayer: starting health check for \(target.rawValue)", category: .network, level: .info)

        wgHealthResults.removeAll()
        let wgConfigs = proxyService.wgConfigs(for: target).filter { $0.isEnabled }
        if wgConfigs.isEmpty {
            wgHealthy = false
        } else {
            var anyWGHealthy = false
            for wg in wgConfigs {
                let result = await protocolTester.testWireGuardEndpoint(wg)
                wgHealthResults[wg.displayString] = result.reachable
                if result.reachable { anyWGHealthy = true }
                logger.log("NetworkLayer: WG \(wg.displayString) — \(result.reachable ? "OK" : "FAIL") (\(result.detail))", category: .vpn, level: result.reachable ? .success : .warning)
            }
            wgHealthy = anyWGHealthy
        }

        ovpnHealthResults.removeAll()
        let ovpnConfigs = proxyService.vpnConfigs(for: target).filter { $0.isEnabled }
        if ovpnConfigs.isEmpty {
            ovpnHealthy = false
        } else {
            var anyOVPNHealthy = false
            for ovpn in ovpnConfigs {
                let result = await protocolTester.testOpenVPNEndpoint(ovpn)
                ovpnHealthResults[ovpn.displayString] = result.reachable
                if result.reachable { anyOVPNHealthy = true }
                logger.log("NetworkLayer: OVPN \(ovpn.displayString) — \(result.reachable ? "OK" : "FAIL") (\(result.detail))", category: .vpn, level: result.reachable ? .success : .warning)
            }
            ovpnHealthy = anyOVPNHealthy
        }

        let proxies = proxyService.proxies(for: target)
        socks5Healthy = proxies.contains { $0.isWorking }

        directHealthy = true
        lastHealthCheck = Date()

        let wgPass = wgHealthResults.values.filter { $0 }.count
        let ovpnPass = ovpnHealthResults.values.filter { $0 }.count
        logger.log("NetworkLayer: health check complete — WG:\(wgPass)/\(wgConfigs.count) OVPN:\(ovpnPass)/\(ovpnConfigs.count) SOCKS5:\(socks5Healthy) Direct:\(directHealthy)", category: .network, level: .info)
    }

    var healthSummary: String {
        var parts: [String] = []
        if wgHealthy { parts.append("WG ✓") } else { parts.append("WG ✗") }
        if ovpnHealthy { parts.append("OVPN ✓") } else { parts.append("OVPN ✗") }
        if socks5Healthy { parts.append("SOCKS5 ✓") } else { parts.append("SOCKS5 ✗") }
        parts.append("Direct ✓")
        return parts.joined(separator: " | ")
    }

    // MARK: - Private Resolvers

    private func resolveWireGuard(for target: ProxyRotationService.ProxyTarget) async -> ActiveNetworkConfig? {
        let configs = proxyService.wgConfigs(for: target).filter { $0.isEnabled }
        for config in configs {
            let result = await protocolTester.testWireGuardEndpoint(config)
            if result.reachable {
                logger.log("NetworkLayer: WG resolved \(config.displayString) for \(target.rawValue)", category: .vpn, level: .debug)
                return .wireGuardDNS(config)
            }
        }
        return nil
    }

    private func resolveOpenVPN(for target: ProxyRotationService.ProxyTarget) async -> ActiveNetworkConfig? {
        let configs = proxyService.vpnConfigs(for: target).filter { $0.isEnabled }
        for config in configs {
            let result = await protocolTester.testOpenVPNEndpoint(config)
            if result.reachable {
                logger.log("NetworkLayer: OVPN resolved \(config.displayString) for \(target.rawValue)", category: .vpn, level: .debug)
                return .openVPNProxy(config)
            }
        }
        return nil
    }

    private func resolveSOCKS5(for target: ProxyRotationService.ProxyTarget) -> ActiveNetworkConfig? {
        if let proxy = proxyService.nextWorkingProxy(for: target) {
            logger.log("NetworkLayer: SOCKS5 resolved \(proxy.displayString) for \(target.rawValue)", category: .proxy, level: .debug)
            return .socks5(proxy)
        }
        return nil
    }

    private let fallbackLogKey = "network_layer_fallback_log_v1"

    private func addFallbackLog(_ message: String) {
        let entry = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)"
        fallbackLog.insert(entry, at: 0)
        if fallbackLog.count > 100 { fallbackLog = Array(fallbackLog.prefix(100)) }
        persistFallbackLog()
        logger.log("NetworkLayer: \(message)", category: .network, level: .warning)
    }

    private func persistFallbackLog() {
        UserDefaults.standard.set(fallbackLog, forKey: fallbackLogKey)
    }

    func loadFallbackLog() {
        if let saved = UserDefaults.standard.stringArray(forKey: fallbackLogKey) {
            fallbackLog = saved
        }
    }

    func clearFallbackLog() {
        fallbackLog.removeAll()
        UserDefaults.standard.removeObject(forKey: fallbackLogKey)
    }
}
