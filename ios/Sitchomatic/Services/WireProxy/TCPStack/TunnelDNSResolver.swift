import Foundation

@MainActor
class TunnelDNSResolver {
    private var dnsServers: [UInt32] = []
    private var cache: [String: (ip: UInt32, expiry: Date)] = [:]
    private let cacheTTL: TimeInterval = 300
    private let queryTimeoutSeconds: TimeInterval = 5
    private let maxRetries: Int = 2
    private let logger = DebugLogger.shared
    private var pendingQueries: [UInt16: (String, CheckedContinuation<UInt32?, Never>)] = [:]
    var sendPacketHandler: ((Data) -> Void)?
    private var sourceIP: UInt32 = 0
    private var nextQueryID: UInt16 = 1
    private var inflightHostnames: [String: Task<UInt32?, Never>] = [:]
    private var queryFrequency: [String: Int] = [:]
    private var backgroundRefreshTimer: Timer?
    private let backgroundRefreshInterval: TimeInterval = 120
    private let frequentQueryThreshold: Int = 3

    func configure(dnsServer: String, sourceIP: UInt32) {
        self.sourceIP = sourceIP

        let cloudflare = IPv4Packet.ipFromString("1.1.1.1") ?? 0x01010101
        let google = IPv4Packet.ipFromString("8.8.8.8") ?? 0x08080808

        var servers: [UInt32] = []

        if let tunnelIP = IPv4Packet.ipFromString(dnsServer) {
            servers.append(tunnelIP)
        }

        if !servers.contains(cloudflare) { servers.append(cloudflare) }
        if !servers.contains(google) { servers.append(google) }

        self.dnsServers = servers
        let serverNames = servers.map { formatDNSIP($0) }.joined(separator: " → ")
        logger.log("TunnelDNS: configured chain: \(serverNames)", category: .vpn, level: .info)
    }

    func resolve(_ hostname: String) async -> UInt32? {
        if let ip = IPv4Packet.ipFromString(hostname) {
            return ip
        }

        queryFrequency[hostname, default: 0] += 1

        if let cached = cache[hostname], cached.expiry > Date() {
            let remaining = cached.expiry.timeIntervalSinceNow
            if remaining < cacheTTL * 0.2 && queryFrequency[hostname, default: 0] >= frequentQueryThreshold {
                Task { @MainActor [weak self] in
                    _ = await self?.performResolve(hostname)
                }
            }
            return cached.ip
        }

        if let existingTask = inflightHostnames[hostname] {
            return await existingTask.value
        }

        let task = Task<UInt32?, Never> { @MainActor in
            return await self.performResolve(hostname)
        }
        inflightHostnames[hostname] = task
        let result = await task.value
        inflightHostnames.removeValue(forKey: hostname)
        return result
    }

    func startBackgroundRefresh() {
        backgroundRefreshTimer?.invalidate()
        backgroundRefreshTimer = Timer.scheduledTimer(withTimeInterval: backgroundRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshFrequentEntries()
            }
        }
    }

    func stopBackgroundRefresh() {
        backgroundRefreshTimer?.invalidate()
        backgroundRefreshTimer = nil
    }

    private func refreshFrequentEntries() {
        let frequentHosts = queryFrequency.filter { $0.value >= frequentQueryThreshold }.map { $0.key }
        guard !frequentHosts.isEmpty else { return }

        let hostsNearExpiry = frequentHosts.filter { hostname in
            guard let cached = cache[hostname] else { return true }
            return cached.expiry.timeIntervalSinceNow < cacheTTL * 0.3
        }

        guard !hostsNearExpiry.isEmpty else { return }

        logger.log("TunnelDNS: background refreshing \(hostsNearExpiry.count) frequent entries", category: .vpn, level: .debug)

        for hostname in hostsNearExpiry.prefix(5) {
            Task { @MainActor [weak self] in
                _ = await self?.performResolve(hostname)
            }
        }
    }

    private func performResolve(_ hostname: String) async -> UInt32? {
        cache.removeValue(forKey: hostname)

        for (serverIndex, server) in dnsServers.enumerated() {
            for attempt in 0..<maxRetries {
                if attempt > 0 {
                    try? await Task.sleep(for: .milliseconds(200 * attempt))
                }
                if let result = await sendDNSQuery(hostname: hostname, dnsServer: server) {
                    return result
                }
            }
            if serverIndex < dnsServers.count - 1 {
                logger.log("TunnelDNS: \(formatDNSIP(server)) failed for \(hostname), trying next", category: .vpn, level: .warning)
            }
        }

        if let systemResult = await systemDNSResolve(hostname) {
            logger.log("TunnelDNS: system DNS resolved \(hostname) → \(formatDNSIP(systemResult))", category: .vpn, level: .info)
            cache[hostname] = (ip: systemResult, expiry: Date().addingTimeInterval(cacheTTL))
            return systemResult
        }

        logger.log("TunnelDNS: all DNS tiers exhausted for \(hostname)", category: .vpn, level: .error)
        return nil
    }

    private func systemDNSResolve(_ hostname: String) async -> UInt32? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let host = CFHostCreateWithName(nil, hostname as CFString).takeRetainedValue()
                var resolved = DarwinBoolean(false)
                CFHostStartInfoResolution(host, .addresses, nil)
                guard let addresses = CFHostGetAddressing(host, &resolved)?.takeUnretainedValue() as? [Data],
                      resolved.boolValue else {
                    continuation.resume(returning: nil)
                    return
                }
                for addrData in addresses {
                    if addrData.count >= MemoryLayout<sockaddr_in>.size {
                        let result: UInt32? = addrData.withUnsafeBytes { ptr in
                            guard let base = ptr.baseAddress,
                                  base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family == AF_INET else { return nil }
                            let raw = base.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
                            let a = UInt32(raw & 0xFF)
                            let b = UInt32((raw >> 8) & 0xFF)
                            let c = UInt32((raw >> 16) & 0xFF)
                            let d = UInt32((raw >> 24) & 0xFF)
                            return (a << 24) | (b << 16) | (c << 8) | d
                        }
                        if let ip = result {
                            continuation.resume(returning: ip)
                            return
                        }
                    }
                }
                continuation.resume(returning: nil)
            }
        }
    }

    private func sendDNSQuery(hostname: String, dnsServer: UInt32) async -> UInt32? {
        let queryID = nextQueryID
        nextQueryID = nextQueryID &+ 1
        if nextQueryID == 0 { nextQueryID = 1 }

        let dnsQuery = buildDNSQuery(id: queryID, hostname: hostname)
        let udpPacket = buildUDPPacket(
            sourceIP: sourceIP,
            destinationIP: dnsServer,
            sourcePort: 10000 + queryID,
            destinationPort: 53,
            payload: dnsQuery
        )

        let ipPacket = IPv4Packet.build(
            sourceAddress: sourceIP,
            destinationAddress: dnsServer,
            protocolNumber: 17,
            payload: udpPacket
        )

        return await withCheckedContinuation { continuation in
            pendingQueries[queryID] = (hostname, continuation)
            sendPacketHandler?(ipPacket)

            let capturedTimeout = self.queryTimeoutSeconds
            let capturedHostname = hostname
            let capturedDNSServer = dnsServer
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(capturedTimeout))
                guard let self else { return }
                if let pending = self.pendingQueries.removeValue(forKey: queryID) {
                    self.logger.log("TunnelDNS: timeout resolving \(capturedHostname) via \(self.formatDNSIP(capturedDNSServer)) after \(Int(capturedTimeout))s", category: .vpn, level: .warning)
                    pending.1.resume(returning: nil)
                }
            }
        }
    }

    func handleIncomingPacket(_ ipData: Data) {
        guard let ipPacket = IPv4Packet.parse(ipData) else { return }
        guard ipPacket.header.isUDP else { return }
        guard ipPacket.payload.count >= 8 else { return }

        let srcPort = readBE16(ipPacket.payload, offset: 0)
        guard srcPort == 53 else { return }

        let udpPayload = Data(ipPacket.payload[8...])
        guard udpPayload.count >= 12 else { return }

        let queryID = readBE16(udpPayload, offset: 0)
        let flags = readBE16(udpPayload, offset: 2)
        let isResponse = (flags & 0x8000) != 0
        let rcode = flags & 0x000F

        guard isResponse else { return }

        guard let (hostname, continuation) = pendingQueries.removeValue(forKey: queryID) else { return }

        guard rcode == 0 else {
            logger.log("TunnelDNS: DNS error rcode=\(rcode) for \(hostname) from \(ipPacket.header.sourceIP)", category: .vpn, level: .warning)
            continuation.resume(returning: nil)
            return
        }

        let anCount = Int(readBE16(udpPayload, offset: 6))

        if anCount == 0 {
            logger.log("TunnelDNS: empty answer (0 records) for \(hostname) from \(ipPacket.header.sourceIP)", category: .vpn, level: .warning)
            continuation.resume(returning: nil)
            return
        }

        if let ip = parseDNSResponseForA(udpPayload) {
            cache[hostname] = (ip: ip, expiry: Date().addingTimeInterval(cacheTTL))
            let ipStr = "\((ip >> 24) & 0xFF).\((ip >> 16) & 0xFF).\((ip >> 8) & 0xFF).\(ip & 0xFF)"
            logger.log("TunnelDNS: resolved \(hostname) → \(ipStr) via \(ipPacket.header.sourceIP)", category: .vpn, level: .debug)
            continuation.resume(returning: ip)
        } else {
            logger.log("TunnelDNS: no A record in \(anCount) answers for \(hostname) from \(ipPacket.header.sourceIP)", category: .vpn, level: .warning)
            continuation.resume(returning: nil)
        }
    }

    func clearCache() {
        cache.removeAll()
        queryFrequency.removeAll()
        for (queryID, pending) in pendingQueries {
            pending.1.resume(returning: nil)
            pendingQueries.removeValue(forKey: queryID)
        }
        inflightHostnames.removeAll()
        stopBackgroundRefresh()
    }

    var cacheSize: Int { cache.count }

    private func formatDNSIP(_ ip: UInt32) -> String {
        "\((ip >> 24) & 0xFF).\((ip >> 16) & 0xFF).\((ip >> 8) & 0xFF).\(ip & 0xFF)"
    }

    private func buildDNSQuery(id: UInt16, hostname: String) -> Data {
        var query = Data()

        appendBE16(&query, id)
        appendBE16(&query, 0x0100)
        appendBE16(&query, 1)
        appendBE16(&query, 0)
        appendBE16(&query, 0)
        appendBE16(&query, 0)

        let labels = hostname.split(separator: ".")
        for label in labels {
            let bytes = Array(label.utf8)
            query.append(UInt8(bytes.count))
            query.append(contentsOf: bytes)
        }
        query.append(0x00)

        appendBE16(&query, 1)
        appendBE16(&query, 1)

        return query
    }

    private func parseDNSResponseForA(_ data: Data) -> UInt32? {
        guard data.count >= 12 else { return nil }

        let qdCount = Int(readBE16(data, offset: 4))
        let anCount = Int(readBE16(data, offset: 6))

        var offset = 12

        for _ in 0..<qdCount {
            offset = skipDNSName(data, offset: offset)
            guard offset >= 0 else { return nil }
            offset += 4
            guard offset <= data.count else { return nil }
        }

        for _ in 0..<anCount {
            let nameEnd = skipDNSName(data, offset: offset)
            guard nameEnd >= 0, nameEnd + 10 <= data.count else { return nil }
            offset = nameEnd

            let recordType = readBE16(data, offset: offset)
            let recordClass = readBE16(data, offset: offset + 2)
            offset += 8
            let rdLength = Int(readBE16(data, offset: offset))
            offset += 2

            guard offset + rdLength <= data.count else { return nil }

            if recordType == 1 && recordClass == 1 && rdLength == 4 {
                return readBE32(data, offset: offset)
            }

            offset += rdLength
        }

        return nil
    }

    private func skipDNSName(_ data: Data, offset: Int) -> Int {
        var pos = offset
        guard pos < data.count else { return -1 }

        while pos < data.count {
            let len = Int(data[pos])
            if len == 0 {
                return pos + 1
            }
            if (len & 0xC0) == 0xC0 {
                guard pos + 1 < data.count else { return -1 }
                return pos + 2
            }
            pos += 1 + len
            guard pos <= data.count else { return -1 }
        }
        return -1
    }

    private func buildUDPPacket(sourceIP: UInt32, destinationIP: UInt32, sourcePort: UInt16, destinationPort: UInt16, payload: Data) -> Data {
        let udpLength = UInt16(8 + payload.count)
        var udp = Data(capacity: Int(udpLength))

        appendBE16(&udp, sourcePort)
        appendBE16(&udp, destinationPort)
        appendBE16(&udp, udpLength)
        appendBE16(&udp, 0)

        udp.append(payload)

        var pseudoHeader = Data(capacity: 12 + udp.count)
        appendBE32(&pseudoHeader, sourceIP)
        appendBE32(&pseudoHeader, destinationIP)
        pseudoHeader.append(0)
        pseudoHeader.append(17)
        appendBE16(&pseudoHeader, udpLength)
        pseudoHeader.append(udp)

        let checksum = IPv4Packet.ipChecksum(pseudoHeader)
        udp[6] = UInt8(checksum >> 8)
        udp[7] = UInt8(checksum & 0xFF)

        return udp
    }

    func verifyDNS() async -> Bool {
        let testDomain = "nordvpn.com"
        if let _ = await resolve(testDomain) {
            logger.log("TunnelDNS: verification PASSED — resolved \(testDomain)", category: .vpn, level: .success)
            cache.removeValue(forKey: testDomain)
            return true
        }
        logger.log("TunnelDNS: verification FAILED — could not resolve \(testDomain)", category: .vpn, level: .error)
        return false
    }
}
