import Foundation
import WebKit
import Network

nonisolated enum ActiveNetworkConfig: Sendable {
    case direct
    case socks5(ProxyConfig)
    case wireGuardDNS(WireGuardConfig)
    case openVPNProxy(OpenVPNConfig)

    var label: String {
        switch self {
        case .direct: "Direct"
        case .socks5(let p): "SOCKS5 \(p.displayString)"
        case .wireGuardDNS(let wg): "WG \(wg.displayString)"
        case .openVPNProxy(let ovpn): "OVPN \(ovpn.displayString)"
        }
    }

    var dnsServers: [String]? {
        switch self {
        case .wireGuardDNS(let wg):
            let raw = wg.interfaceDNS
            guard !raw.isEmpty else { return nil }
            return raw.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default:
            return nil
        }
    }

    var requiresProtectedRoute: Bool {
        switch self {
        case .direct:
            false
        case .socks5, .wireGuardDNS, .openVPNProxy:
            true
        }
    }
}

@MainActor
class NetworkSessionFactory {
    static let shared = NetworkSessionFactory()

    private let proxyService = ProxyRotationService.shared
    private let deviceProxy = DeviceProxyService.shared
    private let scoring = ProxyScoringService.shared
    private let resilience = NetworkResilienceService.shared
    private let logger = DebugLogger.shared
    private let aiProxyStrategy = AIProxyStrategyService.shared

    private var joeWGIndex: Int = 0
    private var ignitionWGIndex: Int = 0
    private var ppsrWGIndex: Int = 0

    private var joeOVPNIndex: Int = 0
    private var ignitionOVPNIndex: Int = 0
    private var ppsrOVPNIndex: Int = 0

    private let localProxy = LocalProxyServer.shared
    private let wireProxyBridge = WireProxyBridge.shared
    private let ovpnBridge = OpenVPNProxyBridge.shared

    func nextConfig(for target: ProxyRotationService.ProxyTarget) -> ActiveNetworkConfig {
        let mode = proxyService.unifiedConnectionMode

        if mode == .direct {
            logger.log("NetworkFactory: DIRECT mode (highest authority) — no proxy/tunnel for \(target.rawValue)", category: .network, level: .info)
            return .direct
        }

        let ipMode = deviceProxy.ipRoutingMode

        if ipMode == .appWideUnited, let config = deviceProxy.activeConfig {
            if deviceProxy.isWireProxyActive, localProxy.isRunning, localProxy.wireProxyMode {
                let localConfig = localProxy.localProxyConfig
                logger.log("NetworkFactory: united IP WireProxy tunnel → 127.0.0.1:\(localConfig.port) for \(target.rawValue)", category: .vpn, level: .debug)
                return .socks5(localConfig)
            }
            if deviceProxy.isOpenVPNBridgeActive, localProxy.isRunning, localProxy.openVPNProxyMode {
                let localConfig = localProxy.localProxyConfig
                logger.log("NetworkFactory: united IP OpenVPN handler → 127.0.0.1:\(localConfig.port) for \(target.rawValue)", category: .vpn, level: .debug)
                return .socks5(localConfig)
            }
            if let localConfig = deviceProxy.effectiveProxyConfig, localProxy.isRunning {
                logger.log("NetworkFactory: united IP local proxy 127.0.0.1:\(localConfig.port) → upstream \(config.label) for \(target.rawValue)", category: .network, level: .debug)
                return .socks5(localConfig)
            }
            logger.log("NetworkFactory: united IP → \(config.label) for \(target.rawValue)", category: .network, level: .debug)
            return config
        }

        if let perSessionConfig = deviceProxy.effectiveProxyConfig, localProxy.isRunning {
            logger.log("NetworkFactory: per-session tunnel active → 127.0.0.1:\(perSessionConfig.port) for \(target.rawValue)", category: .vpn, level: .debug)
            return .socks5(perSessionConfig)
        }
        logger.log("NetworkFactory: per-session \(mode.label) config for \(target.rawValue)", category: .network, level: .debug)

        switch mode {
        case .direct:
            return .direct

        case .dns:
            return .direct

        case .proxy:
            let allProxies = proxyService.proxies(for: target).filter { $0.isWorking || $0.lastTested == nil }
            let targetHost = hostForTarget(target)
            if let aiPick = aiProxyStrategy.bestProxy(for: targetHost, from: allProxies, target: target) {
                logger.log("NetworkFactory: AI-selected SOCKS5 \(aiPick.displayString) for \(target.rawValue)", category: .proxy, level: .debug)
                return .socks5(aiPick)
            }
            if let proxy = proxyService.nextWorkingProxy(for: target) {
                logger.log("NetworkFactory: assigned SOCKS5 \(proxy.displayString) for \(target.rawValue)", category: .proxy, level: .debug)
                return .socks5(proxy)
            }
            logger.log("NetworkFactory: no working SOCKS5 proxy for \(target.rawValue) — falling back to direct", category: .proxy, level: .warning)
            return .direct

        case .wireguard:
            if wireProxyBridge.isActive, localProxy.isRunning, localProxy.wireProxyMode {
                let localConfig = localProxy.localProxyConfig
                logger.log("NetworkFactory: WireProxy active → 127.0.0.1:\(localConfig.port) for \(target.rawValue)", category: .vpn, level: .debug)
                return .socks5(localConfig)
            }
            if let wg = nextWGConfig(for: target) {
                logger.log("NetworkFactory: assigned WG \(wg.displayString) for \(target.rawValue) — WireProxy not yet active", category: .vpn, level: .debug)
                return .wireGuardDNS(wg)
            }
            logger.log("NetworkFactory: no enabled WG config for \(target.rawValue) — falling back to OpenVPN", category: .vpn, level: .warning)
            if let ovpn = nextOVPNConfig(for: target) {
                logger.log("NetworkFactory: WG fallback → OVPN \(ovpn.displayString) for \(target.rawValue)", category: .vpn, level: .info)
                return .openVPNProxy(ovpn)
            }
            logger.log("NetworkFactory: no OVPN available for \(target.rawValue) — falling back to SOCKS5", category: .vpn, level: .warning)
            if let proxy = proxyService.nextWorkingProxy(for: target) {
                logger.log("NetworkFactory: WG fallback → SOCKS5 \(proxy.displayString) for \(target.rawValue)", category: .proxy, level: .info)
                return .socks5(proxy)
            }
            logger.log("NetworkFactory: no fallback available for \(target.rawValue) — using direct", category: .network, level: .warning)
            return .direct

        case .openvpn:
            if ovpnBridge.isActive, localProxy.isRunning, localProxy.openVPNProxyMode {
                let localConfig = localProxy.localProxyConfig
                logger.log("NetworkFactory: OpenVPN bridge active → 127.0.0.1:\(localConfig.port) for \(target.rawValue)", category: .vpn, level: .debug)
                return .socks5(localConfig)
            }
            if let ovpn = nextOVPNConfig(for: target) {
                logger.log("NetworkFactory: assigned OVPN \(ovpn.displayString) for \(target.rawValue)", category: .vpn, level: .debug)
                return .openVPNProxy(ovpn)
            }
            logger.log("NetworkFactory: no enabled OVPN config for \(target.rawValue) — falling back to SOCKS5", category: .vpn, level: .warning)
            if let proxy = proxyService.nextWorkingProxy(for: target) {
                logger.log("NetworkFactory: OVPN fallback → SOCKS5 \(proxy.displayString) for \(target.rawValue)", category: .proxy, level: .info)
                return .socks5(proxy)
            }
            logger.log("NetworkFactory: no fallback available for \(target.rawValue) — using direct", category: .network, level: .warning)
            return .direct

        case .nodeMaven:
            let nm = NodeMavenService.shared
            if let proxy = nm.generateProxyConfig() {
                logger.log("NetworkFactory: assigned NodeMaven proxy \(proxy.displayString) for \(target.rawValue)", category: .proxy, level: .debug)
                return .socks5(proxy)
            }
            logger.log("NetworkFactory: NodeMaven not configured for \(target.rawValue) — falling back to SOCKS5", category: .proxy, level: .warning)
            if let proxy = proxyService.nextWorkingProxy(for: target) {
                return .socks5(proxy)
            }
            return .direct

        case .hybrid:
            let hybridConfig = HybridNetworkingService.shared.nextHybridConfig(for: target)
            if case .direct = hybridConfig, Self.proxyRequiredTargets.contains(target) {
                logger.log("NetworkFactory: hybrid returned .direct for proxy-required \(target.rawValue) — applying fail-closed", category: .network, level: .error)
                return .socks5(failClosedProxy)
            }
            return hybridConfig
        }
    }

    private static let proxyRequiredTargets: Set<ProxyRotationService.ProxyTarget> = [.joe, .ignition]

    func isDirectMode() -> Bool {
        proxyService.unifiedConnectionMode == .direct
    }

    func buildURLSessionConfiguration(for config: ActiveNetworkConfig, target: ProxyRotationService.ProxyTarget) -> URLSessionConfiguration {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = TimeoutResolver.resolveRequestTimeout(30)
        sessionConfig.timeoutIntervalForResource = TimeoutResolver.resolveResourceTimeout(60)
        sessionConfig.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        sessionConfig.httpShouldSetCookies = false
        sessionConfig.httpCookieAcceptPolicy = .never

        let resolvedConfig = resolveEffectiveConfig(config)
        applySOCKS5ToURLSession(sessionConfig, config: resolvedConfig, target: target)

        return sessionConfig
    }

    @discardableResult
    func configureWKWebView(config wkConfig: WKWebViewConfiguration, networkConfig: ActiveNetworkConfig, target: ProxyRotationService.ProxyTarget = .joe, bypassTunnel: Bool = false) -> Bool {
        let dataStore = wkConfig.websiteDataStore
        let resolvedConfig = bypassTunnel ? networkConfig : resolveEffectiveConfig(networkConfig)

        switch resolvedConfig {
        case .socks5(let proxy):
            applySOCKS5ToDataStore(dataStore, proxy: proxy)
            wkConfig.websiteDataStore = dataStore
            logger.log("WKWebView SOCKS5 ProxyConfiguration applied: \(proxy.displayString) (original: \(networkConfig.label))", category: .proxy, level: .info)
            return true

        case .wireGuardDNS(let wg):
            if !bypassTunnel, wireProxyBridge.isActive, localProxy.isRunning, localProxy.wireProxyMode {
                let localConfig = localProxy.localProxyConfig
                applySOCKS5ToDataStore(dataStore, proxy: localConfig)
                wkConfig.websiteDataStore = dataStore
                logger.log("WKWebView WG: \(wg.displayString) — routed via WireProxy local proxy 127.0.0.1:\(localConfig.port)", category: .vpn, level: .info)
                return true
            } else {
                logger.log("WKWebView WG: \(wg.displayString) — \(bypassTunnel ? "tunnel bypassed for per-session IP" : "WireProxy not active"), applying SOCKS5 fallback for IP protection", category: .vpn, level: .warning)
                if let fallbackProxy = proxyService.nextWorkingProxy(for: target) {
                    applySOCKS5ToDataStore(dataStore, proxy: fallbackProxy)
                    wkConfig.websiteDataStore = dataStore
                    logger.log("WKWebView WG: SOCKS5 fallback \(fallbackProxy.displayString) applied to WebView", category: .proxy, level: .info)
                    return true
                } else {
                    applySOCKS5ToDataStore(dataStore, proxy: failClosedProxy)
                    wkConfig.websiteDataStore = dataStore
                    logger.log("WKWebView WG: BLOCKED — no proxy available for \(target.rawValue), fail-closed proxy applied to prevent real IP leak", category: .vpn, level: .error)
                    return false
                }
            }

        case .openVPNProxy(let ovpn):
            if !bypassTunnel, ovpnBridge.isActive, localProxy.isRunning, localProxy.openVPNProxyMode {
                let localConfig = localProxy.localProxyConfig
                applySOCKS5ToDataStore(dataStore, proxy: localConfig)
                wkConfig.websiteDataStore = dataStore
                logger.log("WKWebView OVPN: \(ovpn.displayString) — routed via OpenVPN bridge 127.0.0.1:\(localConfig.port)", category: .vpn, level: .info)
                return true
            } else if ovpnBridge.isActive, let bridgeProxy = ovpnBridge.activeSOCKS5Proxy {
                applySOCKS5ToDataStore(dataStore, proxy: bridgeProxy)
                wkConfig.websiteDataStore = dataStore
                logger.log("WKWebView OVPN: \(ovpn.displayString) — direct bridge proxy \(bridgeProxy.displayString)", category: .vpn, level: .info)
                return true
            } else {
                logger.log("WKWebView OVPN: \(ovpn.displayString) — bridge not active, applying SOCKS5 fallback", category: .vpn, level: .warning)
                if let fallbackProxy = proxyService.nextWorkingProxy(for: target) {
                    applySOCKS5ToDataStore(dataStore, proxy: fallbackProxy)
                    wkConfig.websiteDataStore = dataStore
                    logger.log("WKWebView OVPN: SOCKS5 fallback \(fallbackProxy.displayString) applied to WebView", category: .proxy, level: .info)
                    return true
                } else {
                    applySOCKS5ToDataStore(dataStore, proxy: failClosedProxy)
                    wkConfig.websiteDataStore = dataStore
                    logger.log("WKWebView OVPN: BLOCKED — no proxy available for \(target.rawValue), fail-closed proxy applied", category: .vpn, level: .error)
                    return false
                }
            }

        case .direct:
            return true
        }
    }

    func resolveEffectiveConfigPublic(_ config: ActiveNetworkConfig) -> ActiveNetworkConfig {
        resolveEffectiveConfig(config)
    }

    private func resolveEffectiveConfig(_ config: ActiveNetworkConfig) -> ActiveNetworkConfig {
        switch config {
        case .socks5:
            return config
        case .wireGuardDNS:
            if wireProxyBridge.isActive, localProxy.isRunning, localProxy.wireProxyMode {
                return .socks5(localProxy.localProxyConfig)
            }
            if localProxy.isRunning, localProxy.upstreamProxy != nil {
                return .socks5(localProxy.localProxyConfig)
            }
            return config
        case .openVPNProxy:
            if ovpnBridge.isActive, localProxy.isRunning, localProxy.openVPNProxyMode {
                return .socks5(localProxy.localProxyConfig)
            }
            if ovpnBridge.isActive, let bridgeProxy = ovpnBridge.activeSOCKS5Proxy {
                return .socks5(bridgeProxy)
            }
            return config
        case .direct:
            return config
        }
    }

    func buildProxiedDataStore(for networkConfig: ActiveNetworkConfig, target: ProxyRotationService.ProxyTarget) -> WKWebsiteDataStore {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let resolvedConfig = resolveEffectiveConfig(networkConfig)

        switch resolvedConfig {
        case .socks5(let proxy):
            applySOCKS5ToDataStore(dataStore, proxy: proxy)
            logger.log("DataStore SOCKS5 proxy applied: \(proxy.displayString)", category: .proxy, level: .debug)

        case .wireGuardDNS(let wg):
            if wireProxyBridge.isActive, localProxy.isRunning, localProxy.wireProxyMode {
                let localConfig = localProxy.localProxyConfig
                applySOCKS5ToDataStore(dataStore, proxy: localConfig)
                logger.log("DataStore WG: routed via WireProxy 127.0.0.1:\(localConfig.port)", category: .vpn, level: .debug)
            } else if let fallbackProxy = proxyService.nextWorkingProxy(for: target) {
                applySOCKS5ToDataStore(dataStore, proxy: fallbackProxy)
                logger.log("DataStore WG: SOCKS5 fallback \(fallbackProxy.displayString) applied", category: .proxy, level: .info)
            } else {
                applySOCKS5ToDataStore(dataStore, proxy: failClosedProxy)
                logger.log("DataStore WG: no proxy available — fail-closed proxy applied", category: .vpn, level: .error)
            }

        case .openVPNProxy(let ovpn):
            if ovpnBridge.isActive, localProxy.isRunning, localProxy.openVPNProxyMode {
                let localConfig = localProxy.localProxyConfig
                applySOCKS5ToDataStore(dataStore, proxy: localConfig)
                logger.log("DataStore OVPN: routed via OpenVPN bridge 127.0.0.1:\(localConfig.port) for \(ovpn.displayString)", category: .vpn, level: .debug)
            } else if ovpnBridge.isActive, let bridgeProxy = ovpnBridge.activeSOCKS5Proxy {
                applySOCKS5ToDataStore(dataStore, proxy: bridgeProxy)
                logger.log("DataStore OVPN: direct bridge proxy \(bridgeProxy.displayString) for \(ovpn.displayString)", category: .vpn, level: .debug)
            } else if let fallbackProxy = proxyService.nextWorkingProxy(for: target) {
                applySOCKS5ToDataStore(dataStore, proxy: fallbackProxy)
                logger.log("DataStore OVPN: SOCKS5 fallback \(fallbackProxy.displayString) applied for \(ovpn.displayString)", category: .proxy, level: .info)
            } else {
                applySOCKS5ToDataStore(dataStore, proxy: failClosedProxy)
                logger.log("DataStore OVPN: no proxy available — fail-closed proxy applied", category: .vpn, level: .error)
            }

        case .direct:
            break
        }

        return dataStore
    }

    func buildURLSessionProxyConfiguration(for config: ActiveNetworkConfig, target: ProxyRotationService.ProxyTarget) -> URLSessionConfiguration {
        buildURLSessionConfiguration(for: config, target: target)
    }

    func preflightProxyCheck(for config: ActiveNetworkConfig, target: ProxyRotationService.ProxyTarget) async -> ActiveNetworkConfig {
        let resolved = resolveEffectiveConfig(config)
        guard case .socks5(let proxy) = resolved else { return config }

        let startTime = CFAbsoluteTimeGetCurrent()
        let alive = await quickSOCKS5Handshake(host: proxy.host, port: UInt16(proxy.port))
        let latencyMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

        if alive {
            scoring.recordSuccess(proxyId: proxy.id, latencyMs: latencyMs)
            logger.log("Preflight: proxy \(proxy.displayString) is alive (\(latencyMs)ms)", category: .proxy, level: .debug)
            return config
        }

        scoring.recordFailure(proxyId: proxy.id)
        logger.log("Preflight: proxy \(proxy.displayString) DEAD — rotating to next for \(target.rawValue)", category: .proxy, level: .warning)
        proxyService.markProxyFailed(proxy)

        let workingProxies = proxyService.proxies(for: target).filter { $0.isWorking || $0.lastTested == nil }
        if let scoredReplacement = scoring.bestProxy(from: workingProxies) {
            let replStartTime = CFAbsoluteTimeGetCurrent()
            let replacementAlive = await quickSOCKS5Handshake(host: scoredReplacement.host, port: UInt16(scoredReplacement.port))
            let replLatency = Int((CFAbsoluteTimeGetCurrent() - replStartTime) * 1000)

            if replacementAlive {
                scoring.recordSuccess(proxyId: scoredReplacement.id, latencyMs: replLatency)
                logger.log("Preflight: scored replacement \(scoredReplacement.displayString) is alive (\(replLatency)ms)", category: .proxy, level: .info)
                return .socks5(scoredReplacement)
            }
            scoring.recordFailure(proxyId: scoredReplacement.id)
            proxyService.markProxyFailed(scoredReplacement)
        }

        if let fallback = proxyService.nextWorkingProxy(for: target) {
            let fbStartTime = CFAbsoluteTimeGetCurrent()
            let fbAlive = await quickSOCKS5Handshake(host: fallback.host, port: UInt16(fallback.port))
            let fbLatency = Int((CFAbsoluteTimeGetCurrent() - fbStartTime) * 1000)
            if fbAlive {
                scoring.recordSuccess(proxyId: fallback.id, latencyMs: fbLatency)
                return .socks5(fallback)
            }
            scoring.recordFailure(proxyId: fallback.id)
            proxyService.markProxyFailed(fallback)
        }

        logger.log("Preflight: no working proxy found for \(target.rawValue) — returning original config", category: .proxy, level: .error)
        return config
    }

    func appWideConfig(for target: ProxyRotationService.ProxyTarget) -> ActiveNetworkConfig {
        if proxyService.unifiedConnectionMode == .direct {
            logger.log("NetworkFactory: appWideConfig → DIRECT mode (highest authority) for \(target.rawValue)", category: .network, level: .info)
            return .direct
        }
        let deviceProxy = DeviceProxyService.shared
        if deviceProxy.ipRoutingMode == .appWideUnited, let config = deviceProxy.activeConfig {
            logger.log("NetworkFactory: appWideConfig → united IP \(config.label) for \(target.rawValue)", category: .network, level: .debug)
            return config
        }
        if let perSessionConfig = deviceProxy.effectiveProxyConfig, localProxy.isRunning {
            logger.log("NetworkFactory: appWideConfig → per-session tunnel 127.0.0.1:\(perSessionConfig.port) for \(target.rawValue)", category: .vpn, level: .debug)
            return .socks5(perSessionConfig)
        }
        return nextConfig(for: target)
    }

    func resetRotationIndexes() {
        joeWGIndex = 0
        ignitionWGIndex = 0
        ppsrWGIndex = 0
        joeOVPNIndex = 0
        ignitionOVPNIndex = 0
        ppsrOVPNIndex = 0
    }

    // MARK: - Private Helpers

    private func applySOCKS5ToDataStore(_ dataStore: WKWebsiteDataStore, proxy: ProxyConfig) {
        dataStore.proxyConfigurations = [makeSOCKS5ProxyConfiguration(proxy: proxy)]
    }

    private func applySOCKS5ToURLSession(_ sessionConfig: URLSessionConfiguration, config: ActiveNetworkConfig, target: ProxyRotationService.ProxyTarget) {
        switch config {
        case .direct:
            break

        case .socks5(let proxy):
            applySOCKS5Dict(to: sessionConfig, proxy: proxy)
            logger.log("URLSession configured with SOCKS5: \(proxy.displayString)", category: .proxy, level: .trace)

        case .wireGuardDNS(let wg):
            if wireProxyBridge.isActive, localProxy.isRunning, localProxy.wireProxyMode {
                let localConfig = localProxy.localProxyConfig
                applySOCKS5Dict(to: sessionConfig, proxy: localConfig)
                logger.log("URLSession WG: routed via WireProxy local proxy 127.0.0.1:\(localConfig.port)", category: .vpn, level: .info)
            } else {
                logger.log("URLSession WG: \(wg.displayString) — WireProxy not active, applying SOCKS5 fallback", category: .vpn, level: .warning)
                if let fallbackProxy = proxyService.nextWorkingProxy(for: target) {
                    applySOCKS5Dict(to: sessionConfig, proxy: fallbackProxy)
                    logger.log("URLSession WG: SOCKS5 fallback \(fallbackProxy.displayString) for \(target.rawValue)", category: .proxy, level: .info)
                } else {
                    applySOCKS5Dict(to: sessionConfig, proxy: failClosedProxy)
                    logger.log("URLSession WG: no SOCKS5 fallback for \(target.rawValue) — fail-closed proxy applied to block real IP traffic", category: .vpn, level: .error)
                }
            }

        case .openVPNProxy(let ovpn):
            if ovpnBridge.isActive, localProxy.isRunning, localProxy.openVPNProxyMode {
                let localConfig = localProxy.localProxyConfig
                applySOCKS5Dict(to: sessionConfig, proxy: localConfig)
                logger.log("URLSession OVPN: routed via OpenVPN bridge 127.0.0.1:\(localConfig.port) for \(ovpn.remoteHost)", category: .vpn, level: .info)
            } else if ovpnBridge.isActive, let bridgeProxy = ovpnBridge.activeSOCKS5Proxy {
                applySOCKS5Dict(to: sessionConfig, proxy: bridgeProxy)
                logger.log("URLSession OVPN: direct bridge proxy \(bridgeProxy.displayString) for \(ovpn.remoteHost)", category: .vpn, level: .info)
            } else {
                logger.log("URLSession OVPN: \(ovpn.remoteHost):\(ovpn.remotePort) — bridge not active, applying SOCKS5 fallback", category: .vpn, level: .warning)
                if let fallbackProxy = proxyService.nextWorkingProxy(for: target) {
                    applySOCKS5Dict(to: sessionConfig, proxy: fallbackProxy)
                    logger.log("URLSession OVPN: SOCKS5 fallback \(fallbackProxy.displayString) for \(target.rawValue)", category: .proxy, level: .info)
                } else {
                    applySOCKS5Dict(to: sessionConfig, proxy: failClosedProxy)
                    logger.log("URLSession OVPN: no fallback for \(target.rawValue) — fail-closed proxy applied", category: .vpn, level: .error)
                }
            }
        }
    }

    private var failClosedProxy: ProxyConfig {
        ProxyConfig(host: "127.0.0.1", port: 9)
    }

    private func applySOCKS5Dict(to sessionConfig: URLSessionConfiguration, proxy: ProxyConfig) {
        var proxyDict: [String: Any] = [
            "SOCKSEnable": 1,
            "SOCKSProxy": proxy.host,
            "SOCKSPort": proxy.port,
        ]
        if let u = proxy.username { proxyDict["SOCKSUser"] = u }
        if let p = proxy.password { proxyDict["SOCKSPassword"] = p }
        sessionConfig.connectionProxyDictionary = proxyDict
        sessionConfig.proxyConfigurations = [makeSOCKS5ProxyConfiguration(proxy: proxy)]
    }

    private func makeSOCKS5ProxyConfiguration(proxy: ProxyConfig) -> ProxyConfiguration {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(proxy.host),
            port: NWEndpoint.Port(integerLiteral: UInt16(proxy.port))
        )
        var proxyConfig = ProxyConfiguration(socksv5Proxy: endpoint)
        proxyConfig.allowFailover = false
        if let u = proxy.username, let p = proxy.password {
            proxyConfig.applyCredential(username: u, password: p)
        }
        return proxyConfig
    }

    nonisolated private func quickSOCKS5Handshake(host: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port))
            let connection = NWConnection(to: endpoint, using: .tcp)
            let queue = DispatchQueue(label: "preflight-socks5")
            var completed = false
            let lock = NSLock()

            func finish(_ result: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !completed else { return }
                completed = true
                continuation.resume(returning: result)
            }

            let timeoutWork = DispatchWorkItem { [weak connection] in
                connection?.cancel()
                finish(false)
            }
            queue.asyncAfter(deadline: .now() + 2.5, execute: timeoutWork)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let greeting = Data([0x05, 0x01, 0x00])
                    connection.send(content: greeting, completion: .contentProcessed { sendError in
                        if sendError != nil {
                            timeoutWork.cancel()
                            connection.cancel()
                            finish(false)
                            return
                        }
                        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { data, _, _, recvError in
                            timeoutWork.cancel()
                            connection.cancel()
                            if recvError != nil {
                                finish(false)
                                return
                            }
                            guard let data, data.count >= 2, data[0] == 0x05 else {
                                finish(false)
                                return
                            }
                            finish(true)
                        }
                    })
                case .failed:
                    timeoutWork.cancel()
                    connection.cancel()
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func hostForTarget(_ target: ProxyRotationService.ProxyTarget) -> String {
        TargetHostResolver.hostname(for: target)
    }

    // MARK: - WireGuard Rotation

    private func nextWGConfig(for target: ProxyRotationService.ProxyTarget) -> WireGuardConfig? {
        let networkLayer = NetworkLayerService.shared
        let configs = proxyService.wgConfigs(for: target).filter { $0.isEnabled }.filter { config in
            if let result = networkLayer.wgHealthResults[config.displayString] {
                return result
            }
            return true
        }
        guard !configs.isEmpty else { return nil }

        let index: Int
        switch target {
        case .joe:
            index = joeWGIndex % configs.count
            joeWGIndex = index + 1
        case .ignition:
            index = ignitionWGIndex % configs.count
            ignitionWGIndex = index + 1
        case .ppsr:
            index = ppsrWGIndex % configs.count
            ppsrWGIndex = index + 1
        }

        return configs[index]
    }

    // MARK: - OpenVPN Rotation

    private func nextOVPNConfig(for target: ProxyRotationService.ProxyTarget) -> OpenVPNConfig? {
        let networkLayer = NetworkLayerService.shared
        let configs = proxyService.vpnConfigs(for: target).filter { $0.isEnabled }.filter { config in
            if let result = networkLayer.ovpnHealthResults[config.displayString] {
                return result
            }
            return true
        }
        guard !configs.isEmpty else { return nil }

        let index: Int
        switch target {
        case .joe:
            index = joeOVPNIndex % configs.count
            joeOVPNIndex = index + 1
        case .ignition:
            index = ignitionOVPNIndex % configs.count
            ignitionOVPNIndex = index + 1
        case .ppsr:
            index = ppsrOVPNIndex % configs.count
            ppsrOVPNIndex = index + 1
        }

        return configs[index]
    }
}
