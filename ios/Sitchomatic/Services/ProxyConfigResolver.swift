import Foundation

@MainActor
class ProxyConfigResolver {
    private let proxyService = ProxyRotationService.shared
    private let aiProxyStrategy = AIProxyStrategyService.shared
    private let logger = DebugLogger.shared

    private var wgIndex: Int = 0
    private var ovpnIndex: Int = 0
    private var socks5Index: Int = 0

    func resetIndexes() {
        wgIndex = 0
        ovpnIndex = 0
        socks5Index = 0
    }

    func advanceOVPNIndex(by amount: Int) {
        ovpnIndex += amount
    }

    func advanceWGIndex(by amount: Int) {
        wgIndex += amount
    }

    func resolveNextConfig() -> ActiveNetworkConfig {
        let targets: [ProxyRotationService.ProxyTarget] = [.joe, .ignition, .ppsr]
        let preferredMode = proxyService.unifiedConnectionMode

        let allWG = collectUniqueWG(targets: targets)
        let allOVPN = collectUniqueOVPN(targets: targets)
        let allProxies = collectUniqueProxies(targets: targets)

        let orderedResolvers: [() -> ActiveNetworkConfig?]
        switch preferredMode {
        case .wireguard:
            orderedResolvers = [{ self.nextFromWG(allWG) }, { self.nextFromOVPN(allOVPN) }, { self.nextFromSOCKS5(allProxies) }]
        case .openvpn:
            orderedResolvers = [{ self.nextFromOVPN(allOVPN) }, { self.nextFromWG(allWG) }, { self.nextFromSOCKS5(allProxies) }]
        case .proxy:
            orderedResolvers = [{ self.nextFromSOCKS5(allProxies) }, { self.nextFromWG(allWG) }, { self.nextFromOVPN(allOVPN) }]
        case .direct:
            return .direct
        case .dns:
            orderedResolvers = [{ self.nextFromSOCKS5(allProxies) }, { self.nextFromWG(allWG) }, { self.nextFromOVPN(allOVPN) }]
        case .nodeMaven:
            let nmResolver: () -> ActiveNetworkConfig? = {
                if let proxy = NodeMavenService.shared.generateProxyConfig() { return .socks5(proxy) }
                return nil
            }
            orderedResolvers = [nmResolver, { self.nextFromSOCKS5(allProxies) }, { self.nextFromWG(allWG) }, { self.nextFromOVPN(allOVPN) }]
        case .hybrid:
            return HybridNetworkingService.shared.nextHybridConfig(for: .joe)
        }

        for resolver in orderedResolvers {
            if let result = resolver() { return result }
        }
        return .direct
    }

    func collectUniqueWG(targets: [ProxyRotationService.ProxyTarget]) -> [WireGuardConfig] {
        var all: [WireGuardConfig] = []
        for t in targets { all.append(contentsOf: proxyService.wgConfigs(for: t).filter { $0.isEnabled }) }
        return Array(Dictionary(grouping: all, by: \.uniqueKey).compactMapValues(\.first).values)
    }

    func collectUniqueOVPN(targets: [ProxyRotationService.ProxyTarget]) -> [OpenVPNConfig] {
        var all: [OpenVPNConfig] = []
        for t in targets { all.append(contentsOf: proxyService.vpnConfigs(for: t).filter { $0.isEnabled }) }
        return Array(Dictionary(grouping: all, by: \.uniqueKey).compactMapValues(\.first).values)
    }

    private func collectUniqueProxies(targets: [ProxyRotationService.ProxyTarget]) -> [ProxyConfig] {
        var all: [ProxyConfig] = []
        for t in targets { all.append(contentsOf: proxyService.proxies(for: t)) }
        return Array(Dictionary(grouping: all, by: \.id).compactMapValues(\.first).values)
    }

    private func nextFromWG(_ configs: [WireGuardConfig]) -> ActiveNetworkConfig? {
        guard !configs.isEmpty else { return nil }
        if let aiPick = aiRankedWGConfig(from: configs) {
            logger.log("DeviceProxy: AI-ranked WG \(aiPick.displayString)", category: .vpn, level: .debug)
            return .wireGuardDNS(aiPick)
        }
        let config = configs[wgIndex % configs.count]
        wgIndex += 1
        return .wireGuardDNS(config)
    }

    private func aiRankedWGConfig(from configs: [WireGuardConfig]) -> WireGuardConfig? {
        guard configs.count > 1 else { return nil }
        let host = "unified"
        var scored: [(WireGuardConfig, Double)] = []
        for wg in configs {
            let key = "wg_\(wg.uniqueKey)"
            let profiles = aiProxyStrategy.proxyPerformanceSummary(for: host)
            if let match = profiles.first(where: { $0.proxyId == key }) {
                scored.append((wg, match.score))
            } else {
                scored.append((wg, 0.5))
            }
        }
        scored.sort { $0.1 > $1.1 }
        let topCount = max(1, min(3, scored.count))
        return Array(scored.prefix(topCount)).randomElement()?.0
    }

    private func nextFromOVPN(_ configs: [OpenVPNConfig]) -> ActiveNetworkConfig? {
        guard !configs.isEmpty else { return nil }
        let config = configs[ovpnIndex % configs.count]
        ovpnIndex += 1
        return .openVPNProxy(config)
    }

    private func nextFromSOCKS5(_ proxies: [ProxyConfig]) -> ActiveNetworkConfig? {
        let working = proxies.filter { $0.isWorking || $0.lastTested == nil }
        if !working.isEmpty {
            if let aiPick = aiProxyStrategy.bestProxy(for: "unified", from: working, target: .joe) {
                logger.log("DeviceProxy: AI-selected SOCKS5 \(aiPick.displayString)", category: .proxy, level: .debug)
                return .socks5(aiPick)
            }
            let proxy = working[socks5Index % working.count]
            socks5Index += 1
            return .socks5(proxy)
        }
        guard !proxies.isEmpty else { return nil }
        let proxy = proxies[socks5Index % proxies.count]
        socks5Index += 1
        return .socks5(proxy)
    }
}
