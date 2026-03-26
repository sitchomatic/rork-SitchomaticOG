@preconcurrency import Foundation
@preconcurrency import Network
import Observation

nonisolated struct NordServerHealth: Sendable {
    let hostname: String
    let station: String
    let load: Int
    let countryId: Int
    let countryCode: String
    let hasWireGuard: Bool
    let hasOpenVPN: Bool
    let hasSOCKS5: Bool
    let publicKey: String?
    let fetchedAt: Date
    var consecutiveFailures: Int = 0
    var lastFailedAt: Date?
    var lastSucceededAt: Date?
    var avgLatencyMs: Int = 0
    var totalConnections: Int = 0

    var isBlacklisted: Bool {
        guard consecutiveFailures >= 3 else { return false }
        guard let lastFailed = lastFailedAt else { return false }
        let cooldown: TimeInterval = min(Double(consecutiveFailures) * 60, 600)
        return Date().timeIntervalSince(lastFailed) < cooldown
    }

    var healthScore: Double {
        if isBlacklisted { return 0 }
        let loadScore = max(0, 1.0 - Double(load) / 100.0) * 0.40
        let failScore = max(0, 1.0 - Double(consecutiveFailures) / 5.0) * 0.30
        let latencyScore = avgLatencyMs > 0 ? max(0, 1.0 - Double(avgLatencyMs) / 10000.0) * 0.20 : 0.15
        let freshnessScore: Double
        if let lastSuccess = lastSucceededAt {
            freshnessScore = max(0, 1.0 - Date().timeIntervalSince(lastSuccess) / 3600.0) * 0.10
        } else {
            freshnessScore = 0.05
        }
        return loadScore + failScore + latencyScore + freshnessScore
    }
}

nonisolated struct NordRegionPool: Sendable {
    let countryId: Int
    let countryCode: String
    var servers: [NordServerHealth]
    var lastRefreshedAt: Date
    var nextRoundRobinIndex: Int = 0

    var activeServers: [NordServerHealth] {
        servers.filter { !$0.isBlacklisted }.sorted { $0.healthScore > $1.healthScore }
    }

    var hasHealthyServers: Bool {
        !activeServers.isEmpty
    }

    var isStale: Bool {
        Date().timeIntervalSince(lastRefreshedAt) > 300
    }
}

@Observable
@MainActor
class NordServerIntelligence {
    static let shared = NordServerIntelligence()

    private(set) var regionPools: [Int: NordRegionPool] = [:]
    private(set) var lastGlobalRefresh: Date?
    private(set) var isRefreshing: Bool = false
    private(set) var totalServersTracked: Int = 0
    private(set) var blacklistedCount: Int = 0

    private let logger = DebugLogger.shared
    private let nordService = NordVPNService.shared
    private let apiService = NordLynxAPIService()
    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 300
    private let maxServersPerRegion = 10

    private let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    func startMonitoring() {
        stopMonitoring()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshStaleRegions()
            }
        }
        logger.log("NordIntel: monitoring started (interval: \(Int(refreshInterval))s)", category: .vpn, level: .info)
    }

    func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func bestServer(forCountryId countryId: Int, protocol proto: NordIntelProtocol, excluding: Set<String> = []) async -> NordServerHealth? {
        if let pool = regionPools[countryId], pool.hasHealthyServers, !pool.isStale {
            let candidates = pool.activeServers.filter { server in
                !excluding.contains(server.hostname) && matchesProtocol(server, proto: proto)
            }
            if let best = candidates.first {
                return best
            }
        }

        await refreshRegion(countryId: countryId, proto: proto)

        guard let pool = regionPools[countryId] else { return nil }
        return pool.activeServers.first { server in
            !excluding.contains(server.hostname) && matchesProtocol(server, proto: proto)
        }
    }

    func bestServers(forCountryId countryId: Int, protocol proto: NordIntelProtocol, count: Int, excluding: Set<String> = []) async -> [NordServerHealth] {
        if let pool = regionPools[countryId], pool.hasHealthyServers, !pool.isStale {
            let candidates = pool.activeServers.filter { !excluding.contains($0.hostname) && matchesProtocol($0, proto: proto) }
            if candidates.count >= count {
                return Array(candidates.prefix(count))
            }
        }

        await refreshRegion(countryId: countryId, proto: proto)

        guard let pool = regionPools[countryId] else { return [] }
        return Array(pool.activeServers.filter { !excluding.contains($0.hostname) && matchesProtocol($0, proto: proto) }.prefix(count))
    }

    func recordSuccess(hostname: String, latencyMs: Int) {
        for (countryId, var pool) in regionPools {
            if let idx = pool.servers.firstIndex(where: { $0.hostname == hostname }) {
                pool.servers[idx].consecutiveFailures = 0
                pool.servers[idx].lastSucceededAt = Date()
                pool.servers[idx].totalConnections += 1
                let prev = pool.servers[idx].avgLatencyMs
                let total = pool.servers[idx].totalConnections
                pool.servers[idx].avgLatencyMs = total > 1 ? (prev * (total - 1) + latencyMs) / total : latencyMs
                regionPools[countryId] = pool
                return
            }
        }
    }

    func recordFailure(hostname: String) {
        for (countryId, var pool) in regionPools {
            if let idx = pool.servers.firstIndex(where: { $0.hostname == hostname }) {
                pool.servers[idx].consecutiveFailures += 1
                pool.servers[idx].lastFailedAt = Date()
                regionPools[countryId] = pool
                updateBlacklistCount()
                logger.log("NordIntel: \(hostname) failure #\(pool.servers[idx].consecutiveFailures)\(pool.servers[idx].isBlacklisted ? " — BLACKLISTED" : "")", category: .vpn, level: .warning)
                return
            }
        }
    }

    func clearBlacklist() {
        for (countryId, var pool) in regionPools {
            for idx in pool.servers.indices {
                pool.servers[idx].consecutiveFailures = 0
                pool.servers[idx].lastFailedAt = nil
            }
            regionPools[countryId] = pool
        }
        blacklistedCount = 0
        logger.log("NordIntel: blacklist cleared", category: .vpn, level: .info)
    }

    func clearAll() {
        regionPools.removeAll()
        totalServersTracked = 0
        blacklistedCount = 0
        lastGlobalRefresh = nil
        logger.log("NordIntel: all data cleared", category: .vpn, level: .info)
    }

    func regionPool(forCountryId countryId: Int) -> NordRegionPool? {
        regionPools[countryId]
    }

    func serverHealth(hostname: String) -> NordServerHealth? {
        for pool in regionPools.values {
            if let server = pool.servers.first(where: { $0.hostname == hostname }) {
                return server
            }
        }
        return nil
    }

    func nextRoundRobin(forCountryId countryId: Int, protocol proto: NordIntelProtocol) async -> NordServerHealth? {
        guard var pool = regionPools[countryId], pool.hasHealthyServers else {
            return await bestServer(forCountryId: countryId, protocol: proto)
        }
        let candidates = pool.activeServers.filter { matchesProtocol($0, proto: proto) }
        guard !candidates.isEmpty else { return nil }
        let idx = pool.nextRoundRobinIndex % candidates.count
        pool.nextRoundRobinIndex = idx + 1
        regionPools[countryId] = pool
        return candidates[idx]
    }

    // MARK: - Refresh

    private func refreshRegion(countryId: Int, proto: NordIntelProtocol) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let technology: String
        switch proto {
        case .wireGuard: technology = "wireguard_udp"
        case .openVPN: technology = "openvpn_tcp"
        case .socks5: technology = "socks"
        case .any: technology = "wireguard_udp"
        }

        var components = URLComponents(string: "https://api.nordvpn.com/v1/servers/recommendations")
        components?.queryItems = [
            URLQueryItem(name: "filters[servers_technologies][identifier]", value: technology),
            URLQueryItem(name: "filters[country_id]", value: "\(countryId)"),
            URLQueryItem(name: "limit", value: "\(maxServersPerRegion)")
        ]

        guard let url = components?.url else { return }

        do {
            let (data, response) = try await sharedSession.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                logger.log("NordIntel: refresh HTTP \(code) for country \(countryId)", category: .vpn, level: .warning)
                return
            }

            let decoder = JSONDecoder()
            let servers = try decoder.decode([NordVPNServer].self, from: data)

            let countryCode = servers.first.flatMap { extractCountryCode(from: $0.hostname) } ?? "??"

            let healthEntries: [NordServerHealth] = servers.map { server in
                let existing = regionPools[countryId]?.servers.first(where: { $0.hostname == server.hostname })
                return NordServerHealth(
                    hostname: server.hostname,
                    station: server.station,
                    load: server.load,
                    countryId: countryId,
                    countryCode: countryCode,
                    hasWireGuard: server.publicKey != nil,
                    hasOpenVPN: server.hasOpenVPNTCP || server.hasOpenVPNUDP,
                    hasSOCKS5: server.technologies?.contains(where: { $0.identifier == "socks" }) ?? false,
                    publicKey: server.publicKey,
                    fetchedAt: Date(),
                    consecutiveFailures: existing?.consecutiveFailures ?? 0,
                    lastFailedAt: existing?.lastFailedAt,
                    lastSucceededAt: existing?.lastSucceededAt,
                    avgLatencyMs: existing?.avgLatencyMs ?? 0,
                    totalConnections: existing?.totalConnections ?? 0
                )
            }

            regionPools[countryId] = NordRegionPool(
                countryId: countryId,
                countryCode: countryCode,
                servers: healthEntries,
                lastRefreshedAt: Date(),
                nextRoundRobinIndex: regionPools[countryId]?.nextRoundRobinIndex ?? 0
            )

            updateCounts()
            logger.log("NordIntel: refreshed country \(countryId) (\(countryCode)) — \(healthEntries.count) servers, best load: \(healthEntries.min(by: { $0.load < $1.load })?.load ?? -1)%", category: .vpn, level: .success)
        } catch {
            logger.log("NordIntel: refresh failed for country \(countryId) — \(error.localizedDescription)", category: .vpn, level: .warning)
        }
    }

    private func refreshStaleRegions() async {
        let staleIds = regionPools.filter { $0.value.isStale }.map(\.key)
        guard !staleIds.isEmpty else { return }
        logger.log("NordIntel: refreshing \(staleIds.count) stale regions", category: .vpn, level: .debug)
        for id in staleIds {
            await refreshRegion(countryId: id, proto: .any)
        }
        lastGlobalRefresh = Date()
    }

    // MARK: - SOCKS5 Resolution for OpenVPN Bridge

    func resolveSOCKS5Proxy(forCountryId countryId: Int, excluding: Set<String> = []) async -> (proxy: ProxyConfig, hostname: String, source: String)? {
        let username = nordService.serviceUsername
        let password = nordService.servicePassword
        let authUser: String? = username.isEmpty ? nil : username
        let authPass: String? = password.isEmpty ? nil : password

        if let servers = await bestServers(forCountryId: countryId, protocol: .socks5, count: 3, excluding: excluding) as [NordServerHealth]? {
            for server in servers {
                let proxy = ProxyConfig(host: server.hostname, port: 1080, username: authUser, password: authPass)
                let startTime = CFAbsoluteTimeGetCurrent()
                let (alive, validated) = await validateSOCKS5(proxy)
                let latencyMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

                if alive && (validated || !nordService.hasServiceCredentials) {
                    recordSuccess(hostname: server.hostname, latencyMs: latencyMs)
                    return (proxy, server.hostname, "NordIntel(\(server.hostname), load:\(server.load)%)")
                }
                recordFailure(hostname: server.hostname)

                let stationProxy = ProxyConfig(host: server.station, port: 1080, username: authUser, password: authPass)
                let (stationAlive, stationValidated) = await validateSOCKS5(stationProxy)
                if stationAlive && (stationValidated || !nordService.hasServiceCredentials) {
                    recordSuccess(hostname: server.hostname, latencyMs: latencyMs)
                    return (stationProxy, server.hostname, "NordIntel-station(\(server.station), load:\(server.load)%)")
                }
            }
        }

        return nil
    }

    func resolveMultipleSOCKS5(forCountryId countryId: Int, count: Int) async -> [(proxy: ProxyConfig, hostname: String, source: String)] {
        let username = nordService.serviceUsername
        let password = nordService.servicePassword
        let authUser: String? = username.isEmpty ? nil : username
        let authPass: String? = password.isEmpty ? nil : password

        let servers = await bestServers(forCountryId: countryId, protocol: .socks5, count: count * 2)
        var results: [(proxy: ProxyConfig, hostname: String, source: String)] = []
        var tried: Set<String> = []

        for server in servers where results.count < count {
            guard !tried.contains(server.hostname) else { continue }
            tried.insert(server.hostname)

            let proxy = ProxyConfig(host: server.hostname, port: 1080, username: authUser, password: authPass)
            let startTime = CFAbsoluteTimeGetCurrent()
            let (alive, validated) = await validateSOCKS5(proxy)
            let latencyMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

            if alive && (validated || !nordService.hasServiceCredentials) {
                recordSuccess(hostname: server.hostname, latencyMs: latencyMs)
                results.append((proxy, server.hostname, "NordIntel(\(server.hostname), load:\(server.load)%)"))
            } else {
                recordFailure(hostname: server.hostname)
            }
        }

        return results
    }

    // MARK: - WireGuard Resolution

    func bestWireGuardServer(forCountryId countryId: Int, excluding: Set<String> = []) async -> NordServerHealth? {
        await bestServer(forCountryId: countryId, protocol: .wireGuard, excluding: excluding)
    }

    func generateWireGuardConfig(from server: NordServerHealth) -> WireGuardConfig? {
        guard let publicKey = server.publicKey, !publicKey.isEmpty else { return nil }
        let privateKey = nordService.privateKey
        guard !privateKey.isEmpty else { return nil }

        let endpoint = "\(server.station):51820"
        let rawContent = "[Interface]\nPrivateKey = \(privateKey)\nAddress = 10.5.0.2/32\nDNS = 103.86.96.100, 103.86.99.100\n\n[Peer]\nPublicKey = \(publicKey)\nAllowedIPs = 0.0.0.0/0\nEndpoint = \(endpoint)\nPersistentKeepalive = 25"

        return WireGuardConfig(
            fileName: server.hostname,
            interfaceAddress: "10.5.0.2/32",
            interfacePrivateKey: privateKey,
            interfaceDNS: "103.86.96.100, 103.86.99.100",
            interfaceMTU: nil,
            peerPublicKey: publicKey,
            peerPreSharedKey: nil,
            peerEndpoint: endpoint,
            peerAllowedIPs: "0.0.0.0/0",
            peerPersistentKeepalive: 25,
            rawContent: rawContent
        )
    }

    // MARK: - SOCKS5 Validation

    nonisolated private func validateSOCKS5(_ proxy: ProxyConfig) async -> (alive: Bool, validated: Bool) {
        await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(proxy.host),
                port: NWEndpoint.Port(integerLiteral: UInt16(proxy.port))
            )
            let connection = NWConnection(to: endpoint, using: .tcp)
            let queue = DispatchQueue(label: "nord-intel-validate.\(UUID().uuidString.prefix(6))")
            var completed = false
            let lock = NSLock()

            func finish(_ result: (alive: Bool, validated: Bool)) {
                lock.lock()
                defer { lock.unlock() }
                guard !completed else { return }
                completed = true
                continuation.resume(returning: result)
            }

            let timeoutWork = DispatchWorkItem { [weak connection] in
                connection?.cancel()
                finish((false, false))
            }
            queue.asyncAfter(deadline: .now() + 5, execute: timeoutWork)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var greeting: Data
                    if proxy.username != nil {
                        greeting = Data([0x05, 0x02, 0x00, 0x02])
                    } else {
                        greeting = Data([0x05, 0x01, 0x00])
                    }

                    connection.send(content: greeting, completion: .contentProcessed { sendError in
                        if sendError != nil {
                            timeoutWork.cancel()
                            connection.cancel()
                            finish((true, false))
                            return
                        }

                        connection.receive(minimumIncompleteLength: 2, maximumLength: 16) { data, _, _, recvError in
                            if recvError != nil {
                                timeoutWork.cancel()
                                connection.cancel()
                                finish((true, false))
                                return
                            }
                            guard let data, data.count >= 2, data[0] == 0x05 else {
                                timeoutWork.cancel()
                                connection.cancel()
                                finish((true, false))
                                return
                            }
                            let authMethod = data[1]
                            if authMethod == 0x02, let username = proxy.username, let password = proxy.password {
                                var authPacket = Data([0x01])
                                let uBytes = Array(username.utf8)
                                authPacket.append(UInt8(uBytes.count))
                                authPacket.append(contentsOf: uBytes)
                                let pBytes = Array(password.utf8)
                                authPacket.append(UInt8(pBytes.count))
                                authPacket.append(contentsOf: pBytes)

                                connection.send(content: authPacket, completion: .contentProcessed { authSendError in
                                    if authSendError != nil {
                                        timeoutWork.cancel()
                                        connection.cancel()
                                        finish((true, false))
                                        return
                                    }
                                    connection.receive(minimumIncompleteLength: 2, maximumLength: 4) { authData, _, _, authRecvError in
                                        timeoutWork.cancel()
                                        connection.cancel()
                                        if authRecvError != nil {
                                            finish((true, false))
                                            return
                                        }
                                        guard let authData, authData.count >= 2 else {
                                            finish((true, false))
                                            return
                                        }
                                        finish((true, authData[1] == 0x00))
                                    }
                                })
                            } else if authMethod == 0x00 {
                                timeoutWork.cancel()
                                connection.cancel()
                                finish((true, true))
                            } else if authMethod == 0xFF {
                                timeoutWork.cancel()
                                connection.cancel()
                                finish((true, false))
                            } else {
                                timeoutWork.cancel()
                                connection.cancel()
                                finish((true, true))
                            }
                        }
                    })

                case .failed:
                    timeoutWork.cancel()
                    connection.cancel()
                    finish((false, false))
                case .cancelled:
                    timeoutWork.cancel()
                    finish((false, false))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    // MARK: - Helpers

    private func matchesProtocol(_ server: NordServerHealth, proto: NordIntelProtocol) -> Bool {
        switch proto {
        case .wireGuard: return server.hasWireGuard
        case .openVPN: return server.hasOpenVPN
        case .socks5: return server.hasSOCKS5 || true
        case .any: return true
        }
    }

    private func extractCountryCode(from hostname: String) -> String? {
        let lower = hostname.lowercased()
        guard lower.contains(".nordvpn.com") else { return nil }
        let prefix = lower.replacingOccurrences(of: ".nordvpn.com", with: "")
        let letters = prefix.filter { $0.isLetter }
        guard letters.count >= 2 else { return nil }
        return String(letters.prefix(2)).uppercased()
    }

    private func updateCounts() {
        totalServersTracked = regionPools.values.reduce(0) { $0 + $1.servers.count }
        updateBlacklistCount()
    }

    private func updateBlacklistCount() {
        blacklistedCount = regionPools.values.reduce(0) { $0 + $1.servers.filter(\.isBlacklisted).count }
    }

    nonisolated enum NordIntelProtocol: String, Sendable {
        case wireGuard
        case openVPN
        case socks5
        case any
    }

    var summary: String {
        let regions = regionPools.count
        let active = regionPools.values.reduce(0) { $0 + $1.activeServers.count }
        return "\(regions) regions, \(totalServersTracked) servers (\(active) active, \(blacklistedCount) blacklisted)"
    }
}
