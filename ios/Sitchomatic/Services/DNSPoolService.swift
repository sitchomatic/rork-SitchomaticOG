import Foundation
@preconcurrency import Dispatch
@preconcurrency import Network
import os

nonisolated enum DNSProtocolType: String, Codable, Sendable, CaseIterable {
    case doh = "DoH"
    case dot = "DoT"
}

nonisolated enum DNSRegionPreference: String, Codable, Sendable, CaseIterable {
    case australian = "Australian"
    case worldwide = "Worldwide"
    case anycast = "Anycast"
    case multicast = "Multicast"
    case all = "All"

    var icon: String {
        switch self {
        case .australian: "flag.fill"
        case .worldwide: "globe"
        case .anycast: "antenna.radiowaves.left.and.right"
        case .multicast: "point.3.connected.trianglepath.dotted"
        case .all: "square.grid.3x3.fill"
        }
    }

    var matchingTags: Set<DNSRegionTag> {
        switch self {
        case .australian: [.au]
        case .worldwide: [.global, .anycast, .multicast]
        case .anycast: [.anycast]
        case .multicast: [.multicast, .anycast]
        case .all: DNSRegionTag.allSet
        }
    }
}

nonisolated enum DNSRegionTag: String, Codable, Sendable, CaseIterable {
    case au = "AU"
    case global = "Global"
    case anycast = "Anycast"
    case multicast = "Multicast"

    static let allSet: Set<DNSRegionTag> = Set(DNSRegionTag.allCases)
}

nonisolated struct DNSServerEntry: Sendable {
    let name: String
    let protocolType: DNSProtocolType
    let endpoint: String
    let port: UInt16
    let region: DNSRegionTag
    let isDefault: Bool

    var displayLabel: String {
        "\(name) [\(protocolType.rawValue)] (\(region.rawValue))"
    }
}

nonisolated struct ManagedDNSServer: Identifiable, Sendable {
    let id: UUID = UUID()
    let name: String
    let protocolType: DNSProtocolType
    let endpoint: String
    let port: UInt16
    let region: DNSRegionTag
    var isEnabled: Bool
    let isDefault: Bool
    var consecutiveFailures: Int = 0
    var lastTestLatencyMs: Int?
    var lastTestedAt: Date?
    var autoDisabled: Bool = false
    var lifetimeSuccesses: Int = 0
    var lifetimeFailures: Int = 0

    var displayLabel: String {
        "\(name) [\(protocolType.rawValue)]"
    }

    var regionLabel: String { region.rawValue }

    var successRate: Double {
        let total = lifetimeSuccesses + lifetimeFailures
        guard total > 0 else { return 0.5 }
        return Double(lifetimeSuccesses) / Double(total)
    }

    var isHealthy: Bool {
        isEnabled && !autoDisabled
    }
}

nonisolated struct DoHProvider: Sendable {
    let name: String
    let url: String
}

struct ManagedDoHProvider: Identifiable {
    let id: UUID = UUID()
    let name: String
    let url: String
    var isEnabled: Bool
    let isDefault: Bool
}

nonisolated struct DNSAnswer: Sendable {
    let ip: String
    let provider: String
    let latencyMs: Int
    let protocolUsed: DNSProtocolType
}

nonisolated struct DoHResponse: Codable, Sendable {
    let Status: Int?
    let Answer: [DoHAnswerEntry]?
}

nonisolated struct DoHAnswerEntry: Codable, Sendable {
    let name: String?
    let type: Int?
    let TTL: Int?
    let data: String?
}

@MainActor
class DNSPoolService {
    static let shared = DNSPoolService()

    private var serverIndex: Int = 0
    private let persistKey = "dns_pool_managed_v3"
    private let logger = DebugLogger.shared
    private let autoDisableThreshold: Int = 3
    private var resolveCache: [String: (answer: DNSAnswer, expiry: Date)] = [:]
    private let cacheTTL: TimeInterval = 120

    var regionPreference: DNSRegionPreference = .all {
        didSet { UserDefaults.standard.set(regionPreference.rawValue, forKey: "dns_pool_region_pref") }
    }
    var autoDisableEnabled: Bool = true {
        didSet { UserDefaults.standard.set(autoDisableEnabled, forKey: "dns_pool_auto_disable") }
    }

    static let defaultServers: [DNSServerEntry] = [
        DNSServerEntry(name: "Cloudflare", protocolType: .doh, endpoint: "https://cloudflare-dns.com/dns-query", port: 443, region: .anycast, isDefault: true),
        DNSServerEntry(name: "Cloudflare", protocolType: .dot, endpoint: "1.1.1.1", port: 853, region: .anycast, isDefault: true),
        DNSServerEntry(name: "Google", protocolType: .doh, endpoint: "https://dns.google/dns-query", port: 443, region: .anycast, isDefault: true),
        DNSServerEntry(name: "Google", protocolType: .dot, endpoint: "dns.google", port: 853, region: .anycast, isDefault: true),
        DNSServerEntry(name: "Quad9", protocolType: .doh, endpoint: "https://dns.quad9.net:5053/dns-query", port: 5053, region: .anycast, isDefault: true),
        DNSServerEntry(name: "Quad9", protocolType: .dot, endpoint: "dns.quad9.net", port: 853, region: .anycast, isDefault: true),
        DNSServerEntry(name: "Seby AU", protocolType: .doh, endpoint: "https://doh.seby.io/dns-query", port: 443, region: .au, isDefault: true),
        DNSServerEntry(name: "Seby AU", protocolType: .dot, endpoint: "dns.seby.io", port: 853, region: .au, isDefault: true),
        DNSServerEntry(name: "AdFilter Sydney", protocolType: .doh, endpoint: "https://syd.adfilter.net/dns-query", port: 443, region: .au, isDefault: true),
        DNSServerEntry(name: "AdFilter Adelaide", protocolType: .doh, endpoint: "https://adl.adfilter.net/dns-query", port: 443, region: .au, isDefault: true),
        DNSServerEntry(name: "NextDNS", protocolType: .doh, endpoint: "https://dns.nextdns.io/dns-query", port: 443, region: .multicast, isDefault: true),
        DNSServerEntry(name: "NextDNS", protocolType: .dot, endpoint: "dns.nextdns.io", port: 853, region: .multicast, isDefault: true),
        DNSServerEntry(name: "ControlD", protocolType: .doh, endpoint: "https://freedns.controld.com/p0", port: 443, region: .multicast, isDefault: true),
        DNSServerEntry(name: "Mullvad", protocolType: .doh, endpoint: "https://dns.mullvad.net/dns-query", port: 443, region: .global, isDefault: true),
        DNSServerEntry(name: "Mullvad", protocolType: .dot, endpoint: "dns.mullvad.net", port: 853, region: .global, isDefault: true),
        DNSServerEntry(name: "AdGuard", protocolType: .doh, endpoint: "https://dns.adguard-dns.com/dns-query", port: 443, region: .anycast, isDefault: true),
        DNSServerEntry(name: "AliDNS", protocolType: .doh, endpoint: "https://dns.alidns.com/dns-query", port: 443, region: .global, isDefault: true),
        DNSServerEntry(name: "Wikimedia", protocolType: .doh, endpoint: "https://wikimedia-dns.org/dns-query", port: 443, region: .global, isDefault: true),
        DNSServerEntry(name: "CleanBrowsing", protocolType: .dot, endpoint: "security-filter-dns.cleanbrowsing.org", port: 853, region: .global, isDefault: true),
        DNSServerEntry(name: "Quad9 AU", protocolType: .doh, endpoint: "https://dns11.quad9.net:5053/dns-query", port: 5053, region: .au, isDefault: true),
    ]

    var managedServers: [ManagedDNSServer] = []

    var activeServers: [ManagedDNSServer] {
        let enabled = managedServers.filter(\.isHealthy)
        let matchingTags = regionPreference.matchingTags
        if regionPreference == .all { return enabled }
        let regionFiltered = enabled.filter { matchingTags.contains($0.region) }
        return regionFiltered.isEmpty ? enabled : regionFiltered
    }

    var managedProviders: [ManagedDoHProvider] {
        managedServers.map {
            ManagedDoHProvider(
                name: $0.displayLabel,
                url: $0.protocolType == .doh ? $0.endpoint : "dot://\($0.endpoint):\($0.port)",
                isEnabled: $0.isHealthy,
                isDefault: $0.isDefault
            )
        }
    }

    var providers: [DoHProvider] {
        activeServers.filter { $0.protocolType == .doh }.map { DoHProvider(name: $0.name, url: $0.endpoint) }
    }

    var currentProvider: DoHProvider {
        let dohServers = activeServers.filter { $0.protocolType == .doh }
        guard !dohServers.isEmpty else { return DoHProvider(name: "Cloudflare", url: "https://cloudflare-dns.com/dns-query") }
        let server = dohServers[serverIndex % dohServers.count]
        return DoHProvider(name: server.name, url: server.endpoint)
    }

    func nextProvider() -> DoHProvider {
        let provider = currentProvider
        serverIndex += 1
        return provider
    }

    init() {
        loadManagedServers()
        regionPreference = DNSRegionPreference(rawValue: UserDefaults.standard.string(forKey: "dns_pool_region_pref") ?? "All") ?? .all
        autoDisableEnabled = UserDefaults.standard.object(forKey: "dns_pool_auto_disable") as? Bool ?? true
    }

    // MARK: - Resolution (unified DoH + DoT)

    func resolveWithRotation(hostname: String) async -> DNSAnswer? {
        if let cached = resolveCache[hostname], cached.expiry > Date() {
            return cached.answer
        }

        var servers = activeServers
        if servers.isEmpty {
            logger.log("DNSPool: no active servers — falling back to all enabled servers", category: .dns, level: .error)
            servers = managedServers.filter(\.isEnabled)
            guard !servers.isEmpty else { return nil }
        }

        let sorted = servers.sorted { a, b in
            if a.consecutiveFailures != b.consecutiveFailures {
                return a.consecutiveFailures < b.consecutiveFailures
            }
            return a.successRate > b.successRate
        }

        let maxAttempts = min(sorted.count, 6)
        for attempt in 0..<maxAttempts {
            let server = sorted[attempt]
            serverIndex += 1

            let answer: DNSAnswer?
            switch server.protocolType {
            case .doh:
                answer = await resolveDoH(hostname: hostname, server: server)
            case .dot:
                answer = await resolveDoT(hostname: hostname, server: server)
            }

            if let answer {
                recordSuccess(serverId: server.id, latencyMs: answer.latencyMs)
                resolveCache[hostname] = (answer: answer, expiry: Date().addingTimeInterval(cacheTTL))
                if attempt > 0 {
                    logger.logHealing(category: .dns, originalError: "Previous DNS servers failed", healingAction: "Resolved via \(server.displayLabel) on attempt #\(attempt + 1)", succeeded: true, attemptNumber: attempt + 1)
                }
                return answer
            }

            recordFailure(serverId: server.id)
            logger.log("DNSPool: \(server.displayLabel) failed for \(hostname) (attempt \(attempt + 1)/\(maxAttempts))", category: .dns, level: .debug)
        }

        logger.log("DNSPool: all \(maxAttempts) attempts failed for \(hostname)", category: .dns, level: .error)
        return nil
    }

    func resolveWithFullFallback(hostname: String) async -> DNSAnswer? {
        if let answer = await resolveWithRotation(hostname: hostname) {
            return answer
        }

        logger.log("DNSPool: rotation exhausted, trying ALL servers for \(hostname)", category: .dns, level: .warning)

        let allEnabled = managedServers.filter(\.isEnabled)
        for server in allEnabled {
            let answer: DNSAnswer?
            switch server.protocolType {
            case .doh: answer = await resolveDoH(hostname: hostname, server: server)
            case .dot: answer = await resolveDoT(hostname: hostname, server: server)
            }
            if let answer {
                recordSuccess(serverId: server.id, latencyMs: answer.latencyMs)
                resolveCache[hostname] = (answer: answer, expiry: Date().addingTimeInterval(cacheTTL))
                logger.log("DNSPool: full-fallback resolved \(hostname) via \(server.displayLabel)", category: .dns, level: .success)
                return answer
            }
            recordFailure(serverId: server.id)
        }

        logger.log("DNSPool: TOTAL FAILURE — no server resolved \(hostname)", category: .dns, level: .critical)
        return nil
    }

    func resolve(hostname: String, using provider: DoHProvider) async -> DNSAnswer? {
        if let server = managedServers.first(where: { $0.endpoint == provider.url || $0.name == provider.name }) {
            switch server.protocolType {
            case .doh: return await resolveDoH(hostname: hostname, server: server)
            case .dot: return await resolveDoT(hostname: hostname, server: server)
            }
        }
        let synthetic = ManagedDNSServer(name: provider.name, protocolType: .doh, endpoint: provider.url, port: 443, region: .global, isEnabled: true, isDefault: false)
        return await resolveDoH(hostname: hostname, server: synthetic)
    }

    func preflightResolve(hostname: String) async -> (provider: String, ip: String, latencyMs: Int)? {
        if let answer = await resolveWithFullFallback(hostname: hostname) {
            return (provider: answer.provider, ip: answer.ip, latencyMs: answer.latencyMs)
        }
        return nil
    }

    func preflightTestAllActive(hostname: String = "cloudflare.com") async -> (healthy: Int, failed: Int, autoDisabledDuringTest: [String]) {
        let servers = activeServers
        var healthy = 0
        var failed = 0
        var disabled: [String] = []

        for server in servers {
            let answer = await testServer(server, hostname: hostname)
            if answer != nil {
                healthy += 1
            } else {
                failed += 1
                if let idx = managedServers.firstIndex(where: { $0.id == server.id }), managedServers[idx].autoDisabled {
                    disabled.append(server.displayLabel)
                }
            }
        }

        logger.log("DNSPool: preflight test — \(healthy) healthy, \(failed) failed, \(disabled.count) auto-disabled", category: .dns, level: healthy > 0 ? .success : .error)
        return (healthy, failed, disabled)
    }

    func invalidateCache() {
        resolveCache.removeAll()
    }

    func invalidateCache(for hostname: String) {
        resolveCache.removeValue(forKey: hostname)
    }

    // MARK: - DoH Resolution

    private nonisolated func resolveDoH(hostname: String, server: ManagedDNSServer) async -> DNSAnswer? {
        guard var components = URLComponents(string: server.endpoint) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "name", value: hostname),
            URLQueryItem(name: "type", value: "A"),
        ]
        guard let url = components.url else { return nil }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let latency = Int(Date().timeIntervalSince(start) * 1000)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            guard !data.isEmpty else { return nil }

            let decoded = try JSONDecoder().decode(DoHResponse.self, from: data)
            guard decoded.Status == 0 || decoded.Status == nil else { return nil }
            guard let answers = decoded.Answer,
                  let aRecord = answers.first(where: { $0.type == 1 }),
                  let ip = aRecord.data, !ip.isEmpty else { return nil }

            return DNSAnswer(ip: ip, provider: server.displayLabel, latencyMs: latency, protocolUsed: .doh)
        } catch {
            return nil
        }
    }

    // MARK: - DoT Resolution (DNS over TLS) — safe single-resume continuation

    private nonisolated func resolveDoT(hostname: String, server: ManagedDNSServer) async -> DNSAnswer? {
        let start = Date()
        let queryPacket = buildDNSQuery(hostname: hostname)

        let host = NWEndpoint.Host(server.endpoint)
        let port = NWEndpoint.Port(rawValue: server.port) ?? NWEndpoint.Port(rawValue: 853)!
        let tlsOptions = NWProtocolTLS.Options()
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 8

        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        let connection = NWConnection(host: host, port: port, using: params)

        let resumed = UnsafeSendableBox(false)

        return await withCheckedContinuation { continuation in
            func safeResume(_ value: DNSAnswer?) {
                if !resumed.value {
                    resumed.value = true
                    continuation.resume(returning: value)
                }
            }

            let timeoutItem = DispatchWorkItem { [weak connection] in
                connection?.cancel()
                safeResume(nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeoutItem)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var lengthPrefixed = Data()
                    let len = UInt16(queryPacket.count)
                    lengthPrefixed.append(UInt8(len >> 8))
                    lengthPrefixed.append(UInt8(len & 0xFF))
                    lengthPrefixed.append(queryPacket)

                    connection.send(content: lengthPrefixed, completion: .contentProcessed({ sendError in
                        if sendError != nil {
                            timeoutItem.cancel()
                            connection.cancel()
                            safeResume(nil)
                            return
                        }

                        connection.receive(minimumIncompleteLength: 2, maximumLength: 4096) { data, _, _, recvError in
                            timeoutItem.cancel()
                            defer { connection.cancel() }

                            guard recvError == nil, let data, data.count > 2 else {
                                safeResume(nil)
                                return
                            }

                            let responseLen = Int(data[0]) << 8 | Int(data[1])
                            let dnsData: Data
                            if data.count >= responseLen + 2 {
                                dnsData = data.subdata(in: 2..<(2 + responseLen))
                            } else {
                                dnsData = data.subdata(in: 2..<data.count)
                            }

                            if let ip = self.parseDNSResponseForA(dnsData) {
                                let latency = Int(Date().timeIntervalSince(start) * 1000)
                                safeResume(DNSAnswer(ip: ip, provider: server.displayLabel, latencyMs: latency, protocolUsed: .dot))
                            } else {
                                safeResume(nil)
                            }
                        }
                    }))

                case .failed, .cancelled:
                    timeoutItem.cancel()
                    safeResume(nil)

                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private nonisolated func buildDNSQuery(hostname: String) -> Data {
        var packet = Data()
        let txid: UInt16 = UInt16.random(in: 0...UInt16.max)
        packet.append(UInt8(txid >> 8))
        packet.append(UInt8(txid & 0xFF))
        packet.append(contentsOf: [0x01, 0x00])
        packet.append(contentsOf: [0x00, 0x01])
        packet.append(contentsOf: [0x00, 0x00])
        packet.append(contentsOf: [0x00, 0x00])
        packet.append(contentsOf: [0x00, 0x00])

        let labels = hostname.split(separator: ".")
        for label in labels {
            let bytes = Array(label.utf8)
            packet.append(UInt8(bytes.count))
            packet.append(contentsOf: bytes)
        }
        packet.append(0x00)

        packet.append(contentsOf: [0x00, 0x01])
        packet.append(contentsOf: [0x00, 0x01])

        return packet
    }

    private nonisolated func parseDNSResponseForA(_ data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let flags = UInt16(data[2]) << 8 | UInt16(data[3])
        let rcode = flags & 0x0F
        guard rcode == 0 else { return nil }

        let ancount = Int(UInt16(data[6]) << 8 | UInt16(data[7]))
        guard ancount > 0 else { return nil }

        var offset = 12
        while offset < data.count && data[offset] != 0 {
            if data[offset] & 0xC0 == 0xC0 { offset += 2; break }
            offset += Int(data[offset]) + 1
        }
        if offset < data.count && data[offset] == 0 { offset += 1 }
        offset += 4

        for _ in 0..<ancount {
            guard offset + 2 <= data.count else { return nil }
            if data[offset] & 0xC0 == 0xC0 {
                offset += 2
            } else {
                while offset < data.count && data[offset] != 0 {
                    offset += Int(data[offset]) + 1
                }
                offset += 1
            }

            guard offset + 10 <= data.count else { return nil }
            let rtype = Int(UInt16(data[offset]) << 8 | UInt16(data[offset + 1]))
            let rdlength = Int(UInt16(data[offset + 8]) << 8 | UInt16(data[offset + 9]))
            offset += 10

            if rtype == 1 && rdlength == 4 && offset + 4 <= data.count {
                return "\(data[offset]).\(data[offset+1]).\(data[offset+2]).\(data[offset+3])"
            }
            offset += rdlength
        }
        return nil
    }

    // MARK: - Health Tracking & Auto-Disable

    private func recordSuccess(serverId: UUID, latencyMs: Int) {
        guard let idx = managedServers.firstIndex(where: { $0.id == serverId }) else { return }
        managedServers[idx].consecutiveFailures = 0
        managedServers[idx].lastTestLatencyMs = latencyMs
        managedServers[idx].lastTestedAt = Date()
        managedServers[idx].lifetimeSuccesses += 1
    }

    private func recordFailure(serverId: UUID) {
        guard let idx = managedServers.firstIndex(where: { $0.id == serverId }) else { return }
        managedServers[idx].consecutiveFailures += 1
        managedServers[idx].lastTestedAt = Date()
        managedServers[idx].lifetimeFailures += 1

        if autoDisableEnabled && managedServers[idx].consecutiveFailures >= autoDisableThreshold && !managedServers[idx].autoDisabled {
            managedServers[idx].autoDisabled = true
            persistManagedServers()
            logger.log("DNSPool: auto-disabled \(managedServers[idx].displayLabel) after \(autoDisableThreshold) consecutive failures — saved", category: .dns, level: .warning)
        }
    }

    func testServer(_ server: ManagedDNSServer, hostname: String = "cloudflare.com") async -> DNSAnswer? {
        let answer: DNSAnswer?
        switch server.protocolType {
        case .doh: answer = await resolveDoH(hostname: hostname, server: server)
        case .dot: answer = await resolveDoT(hostname: hostname, server: server)
        }
        if let answer {
            recordSuccess(serverId: server.id, latencyMs: answer.latencyMs)
        } else {
            recordFailure(serverId: server.id)
        }
        return answer
    }

    func testAllServers(hostname: String = "cloudflare.com") async -> [(server: ManagedDNSServer, passed: Bool, latencyMs: Int?)] {
        var results: [(server: ManagedDNSServer, passed: Bool, latencyMs: Int?)] = []
        for server in managedServers {
            let answer = await testServer(server, hostname: hostname)
            results.append((server: server, passed: answer != nil, latencyMs: answer?.latencyMs))
        }
        return results
    }

    func testAllAndAutoDisable(hostname: String = "cloudflare.com") async -> (results: [(server: ManagedDNSServer, passed: Bool, latencyMs: Int?)], disabledCount: Int) {
        var results: [(server: ManagedDNSServer, passed: Bool, latencyMs: Int?)] = []
        var disabledCount = 0
        let serversToTest = managedServers.filter { $0.isEnabled && !$0.autoDisabled }
        for server in serversToTest {
            let answer = await testServer(server, hostname: hostname)
            let passed = answer != nil
            results.append((server: server, passed: passed, latencyMs: answer?.latencyMs))
            if !passed, let idx = managedServers.firstIndex(where: { $0.id == server.id }) {
                if !managedServers[idx].autoDisabled {
                    managedServers[idx].autoDisabled = true
                    disabledCount += 1
                    logger.log("DNSPool: auto-disabled \(server.displayLabel) — failed test", category: .dns, level: .warning)
                }
            }
        }
        for server in managedServers.filter(\.autoDisabled) {
            results.append((server: server, passed: false, latencyMs: nil))
        }
        persistManagedServers()
        logger.log("DNSPool: Test All complete — \(results.filter(\.passed).count) passed, \(disabledCount) newly auto-disabled, \(managedServers.filter(\.autoDisabled).count) total disabled", category: .dns, level: disabledCount == 0 ? .success : .warning)
        return (results, disabledCount)
    }

    func resetAutoDisabled() {
        for i in managedServers.indices {
            managedServers[i].autoDisabled = false
            managedServers[i].consecutiveFailures = 0
        }
        persistManagedServers()
        logger.log("DNSPool: reset all auto-disabled servers", category: .dns, level: .info)
    }

    // MARK: - Management

    func toggleServer(id: UUID, enabled: Bool) {
        if let idx = managedServers.firstIndex(where: { $0.id == id }) {
            managedServers[idx].isEnabled = enabled
            if enabled { managedServers[idx].autoDisabled = false; managedServers[idx].consecutiveFailures = 0 }
            persistManagedServers()
        }
    }

    func toggleProvider(id: UUID, enabled: Bool) {
        toggleServer(id: id, enabled: enabled)
    }

    func addServer(name: String, protocolType: DNSProtocolType, endpoint: String, port: UInt16, region: DNSRegionTag) -> Bool {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !managedServers.contains(where: { $0.endpoint == trimmed && $0.protocolType == protocolType }) else { return false }
        managedServers.append(ManagedDNSServer(name: name, protocolType: protocolType, endpoint: trimmed, port: port, region: region, isEnabled: true, isDefault: false))
        persistManagedServers()
        return true
    }

    func addProvider(name: String, url: String) -> Bool {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedURL.hasPrefix("dot://") {
            let parts = trimmedURL.replacingOccurrences(of: "dot://", with: "").components(separatedBy: ":")
            guard let host = parts.first, !host.isEmpty else { return false }
            let port = parts.count > 1 ? UInt16(parts[1]) ?? 853 : 853
            return addServer(name: name, protocolType: .dot, endpoint: host, port: port, region: .global)
        }
        return addServer(name: name, protocolType: .doh, endpoint: trimmedURL, port: 443, region: .global)
    }

    func bulkImportProviders(_ text: String) -> (added: Int, duplicates: Int, invalid: Int) {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var added = 0, duplicates = 0, invalid = 0
        for line in lines {
            let parts = line.components(separatedBy: "|")
            let urlStr: String
            let nameStr: String
            if parts.count >= 2 {
                nameStr = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                urlStr = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                urlStr = line
                nameStr = URL(string: line)?.host ?? "Custom"
            }
            if urlStr.hasPrefix("dot://") || urlStr.hasPrefix("https://") {
                if addProvider(name: nameStr, url: urlStr) { added += 1 } else { duplicates += 1 }
            } else {
                invalid += 1
            }
        }
        return (added, duplicates, invalid)
    }

    func deleteServer(id: UUID) {
        managedServers.removeAll { $0.id == id }
        persistManagedServers()
    }

    func deleteProvider(id: UUID) { deleteServer(id: id) }

    func resetToDefaults() {
        managedServers = Self.defaultServers.map {
            ManagedDNSServer(name: $0.name, protocolType: $0.protocolType, endpoint: $0.endpoint, port: $0.port, region: $0.region, isEnabled: true, isDefault: $0.isDefault)
        }
        resolveCache.removeAll()
        persistManagedServers()
    }

    func enableAll() {
        for i in managedServers.indices {
            managedServers[i].isEnabled = true
            managedServers[i].autoDisabled = false
            managedServers[i].consecutiveFailures = 0
        }
        persistManagedServers()
    }

    func resetRotation() { serverIndex = 0 }

    var providerCount: Int { activeServers.count }
    var allProviderNames: [String] { activeServers.map(\.displayLabel) }

    var poolSummary: String {
        let total = managedServers.count
        let enabled = managedServers.filter(\.isEnabled).count
        let autoOff = managedServers.filter(\.autoDisabled).count
        let doh = activeServers.filter { $0.protocolType == .doh }.count
        let dot = activeServers.filter { $0.protocolType == .dot }.count
        let regionTag = regionPreference.rawValue
        return "\(enabled)/\(total) active (DoH:\(doh) DoT:\(dot)) [\(regionTag)]" + (autoOff > 0 ? " [\(autoOff) auto-disabled]" : "")
    }

    var healthReport: String {
        let healthy = managedServers.filter(\.isHealthy).count
        let disabled = managedServers.filter(\.autoDisabled).count
        let manualOff = managedServers.filter { !$0.isEnabled }.count
        let avgLatency: Int
        let tested = managedServers.compactMap(\.lastTestLatencyMs)
        avgLatency = tested.isEmpty ? 0 : tested.reduce(0, +) / tested.count
        return "Healthy:\(healthy) AutoOff:\(disabled) ManualOff:\(manualOff) AvgLatency:\(avgLatency)ms"
    }

    // MARK: - Persistence

    private func persistManagedServers() {
        let data = managedServers.map { server -> [String: String] in
            [
                "name": server.name,
                "protocol": server.protocolType.rawValue,
                "endpoint": server.endpoint,
                "port": String(server.port),
                "region": server.region.rawValue,
                "enabled": server.isEnabled ? "1" : "0",
                "default": server.isDefault ? "1" : "0",
                "autoDisabled": server.autoDisabled ? "1" : "0",
                "consecutiveFailures": String(server.consecutiveFailures),
                "lifetimeSuccesses": String(server.lifetimeSuccesses),
                "lifetimeFailures": String(server.lifetimeFailures),
            ]
        }
        UserDefaults.standard.set(data, forKey: persistKey)
    }

    private func loadManagedServers() {
        if let saved = UserDefaults.standard.array(forKey: persistKey) as? [[String: String]], !saved.isEmpty {
            managedServers = saved.map { dict in
                var server = ManagedDNSServer(
                    name: dict["name"] ?? "Unknown",
                    protocolType: DNSProtocolType(rawValue: dict["protocol"] ?? "DoH") ?? .doh,
                    endpoint: dict["endpoint"] ?? "",
                    port: UInt16(dict["port"] ?? "443") ?? 443,
                    region: DNSRegionTag(rawValue: dict["region"] ?? "Global") ?? .global,
                    isEnabled: dict["enabled"] == "1",
                    isDefault: dict["default"] == "1"
                )
                server.autoDisabled = dict["autoDisabled"] == "1"
                server.consecutiveFailures = Int(dict["consecutiveFailures"] ?? "0") ?? 0
                server.lifetimeSuccesses = Int(dict["lifetimeSuccesses"] ?? "0") ?? 0
                server.lifetimeFailures = Int(dict["lifetimeFailures"] ?? "0") ?? 0
                return server
            }
        } else {
            managedServers = Self.defaultServers.map {
                ManagedDNSServer(name: $0.name, protocolType: $0.protocolType, endpoint: $0.endpoint, port: $0.port, region: $0.region, isEnabled: true, isDefault: $0.isDefault)
            }
            persistManagedServers()
        }
    }
}

typealias PPSRDoHService = DNSPoolService

nonisolated final class UnsafeSendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
