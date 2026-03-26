import Foundation
import Network

nonisolated struct VPNProtocolTestResult: Sendable {
    let reachable: Bool
    let protocolValidated: Bool
    let latencyMs: Int
    let detail: String
    let dnsResolved: Bool
    let portOpen: Bool
}

final class VPNProtocolTestService: @unchecked Sendable {
    static let shared = VPNProtocolTestService()

    nonisolated func testWireGuardEndpoint(_ config: WireGuardConfig) async -> VPNProtocolTestResult {
        let host = config.endpointHost
        let port = config.endpointPort
        let start = Date()

        let dnsOk = await resolveHost(host)
        if !dnsOk {
            let dohOk = await resolveHostViaDoH(host)
            if !dohOk {
                return VPNProtocolTestResult(
                    reachable: false, protocolValidated: false,
                    latencyMs: elapsed(start), detail: "DNS resolution failed (system + DoH)",
                    dnsResolved: false, portOpen: false
                )
            }
        }

        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            let udpResult = await testWireGuardUDPHandshake(host: host, port: UInt16(port))
            let latency = elapsed(start)

            if udpResult.portOpen && udpResult.protocolValidated {
                return VPNProtocolTestResult(
                    reachable: true, protocolValidated: true,
                    latencyMs: latency, detail: "WG handshake initiation OK in \(latency)ms (attempt \(attempt))",
                    dnsResolved: true, portOpen: true
                )
            }

            if udpResult.portOpen {
                return VPNProtocolTestResult(
                    reachable: true, protocolValidated: false,
                    latencyMs: latency, detail: "UDP port open but WG handshake not validated (attempt \(attempt))",
                    dnsResolved: true, portOpen: true
                )
            }

            if attempt < maxAttempts {
                try? await Task.sleep(for: .milliseconds(500 * attempt))
            }
        }

        let tcpFallback = await testTCPPort(host: host, port: port, timeout: 10)
        let finalLatency = elapsed(start)

        return VPNProtocolTestResult(
            reachable: tcpFallback, protocolValidated: false,
            latencyMs: finalLatency,
            detail: tcpFallback ? "TCP fallback reachable (UDP blocked) in \(finalLatency)ms" : "Endpoint unreachable after \(maxAttempts) UDP attempts + TCP fallback",
            dnsResolved: true, portOpen: tcpFallback
        )
    }

    nonisolated func testOpenVPNEndpoint(_ config: OpenVPNConfig) async -> VPNProtocolTestResult {
        let host = config.remoteHost
        let port = config.remotePort
        let proto = config.proto
        let start = Date()

        let dnsOk = await resolveHost(host)
        if !dnsOk {
            let dohOk = await resolveHostViaDoH(host)
            if !dohOk {
                return VPNProtocolTestResult(
                    reachable: false, protocolValidated: false,
                    latencyMs: elapsed(start), detail: "DNS resolution failed (system + DoH)",
                    dnsResolved: false, portOpen: false
                )
            }
        }

        if proto == "tcp" {
            let result = await testOpenVPNTCPHandshake(host: host, port: UInt16(port))
            let latency = elapsed(start)

            if result.protocolValidated {
                return VPNProtocolTestResult(
                    reachable: true, protocolValidated: true,
                    latencyMs: latency, detail: "OpenVPN TCP handshake OK in \(latency)ms",
                    dnsResolved: true, portOpen: true
                )
            }

            if result.portOpen {
                return VPNProtocolTestResult(
                    reachable: true, protocolValidated: false,
                    latencyMs: latency, detail: "TCP port open but OpenVPN handshake not validated",
                    dnsResolved: true, portOpen: true
                )
            }

            return VPNProtocolTestResult(
                reachable: false, protocolValidated: false,
                latencyMs: latency, detail: "TCP connection failed to \(host):\(port)",
                dnsResolved: true, portOpen: false
            )
        } else {
            let result = await testOpenVPNUDPHandshake(host: host, port: UInt16(port))
            let latency = elapsed(start)

            return VPNProtocolTestResult(
                reachable: result.portOpen, protocolValidated: result.protocolValidated,
                latencyMs: latency,
                detail: result.protocolValidated ? "OpenVPN UDP handshake OK in \(latency)ms" : (result.portOpen ? "UDP reachable but OpenVPN not validated" : "UDP endpoint unreachable"),
                dnsResolved: true, portOpen: result.portOpen
            )
        }
    }

    // MARK: - WireGuard UDP Handshake

    private nonisolated func testWireGuardUDPHandshake(host: String, port: UInt16) async -> (portOpen: Bool, protocolValidated: Bool) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return (false, false)
        }

        return await withCheckedContinuation { continuation in
            let params = NWParameters.udp
            params.requiredInterfaceType = .other
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: nwPort,
                using: params
            )
            let guard_ = ContinuationGuard()
            let queue = DispatchQueue(label: "wg.handshake.\(host).\(port).\(UUID().uuidString.prefix(6))")

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let handshakeInit = Self.buildWireGuardHandshakeInit()
                    connection.send(content: handshakeInit, completion: .contentProcessed { sendError in
                        if sendError != nil {
                            if guard_.tryConsume() {
                                connection.cancel()
                                continuation.resume(returning: (true, false))
                            }
                            return
                        }

                        connection.receiveMessage { data, _, _, recvError in
                            if guard_.tryConsume() {
                                connection.cancel()
                                if let data = data, !data.isEmpty {
                                    let validated = data.count >= 4 && data[0] == 0x02
                                    continuation.resume(returning: (true, validated))
                                } else if recvError == nil {
                                    continuation.resume(returning: (true, false))
                                } else {
                                    continuation.resume(returning: (true, false))
                                }
                            }
                        }
                    })
                case .failed(let error):
                    if guard_.tryConsume() {
                        let posixCode = (error as NSError).code
                        let portLikelyOpen = posixCode == 61 || posixCode == 54
                        continuation.resume(returning: (portLikelyOpen, false))
                    }
                case .cancelled:
                    if guard_.tryConsume() {
                        continuation.resume(returning: (false, false))
                    }
                case .waiting:
                    break
                default:
                    break
                }
            }

            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 10) {
                if guard_.tryConsume() {
                    connection.cancel()
                    continuation.resume(returning: (false, false))
                }
            }
        }
    }

    private nonisolated static func buildWireGuardHandshakeInit() -> Data {
        var data = Data(count: 148)
        data[0] = 0x01
        data[1] = 0x00
        data[2] = 0x00
        data[3] = 0x00
        let senderIndex = UInt32.random(in: 1...UInt32.max)
        withUnsafeBytes(of: senderIndex.littleEndian) { bytes in
            data.replaceSubrange(4..<8, with: bytes)
        }
        for i in 8..<148 {
            data[i] = UInt8.random(in: 0...255)
        }
        return data
    }

    // MARK: - OpenVPN TCP Handshake

    private nonisolated func testOpenVPNTCPHandshake(host: String, port: UInt16) async -> (portOpen: Bool, protocolValidated: Bool) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return (false, false)
        }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: nwPort,
                using: .tcp
            )
            let guard_ = ContinuationGuard()
            let queue = DispatchQueue(label: "ovpn.tcp.\(host).\(port)")

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let resetPacket = Self.buildOpenVPNResetPacket()
                    var lengthPrefix = Data(count: 2)
                    let len = UInt16(resetPacket.count)
                    lengthPrefix[0] = UInt8(len >> 8)
                    lengthPrefix[1] = UInt8(len & 0xFF)
                    var payload = lengthPrefix
                    payload.append(resetPacket)

                    connection.send(content: payload, completion: .contentProcessed { sendError in
                        if sendError != nil {
                            if guard_.tryConsume() {
                                connection.cancel()
                                continuation.resume(returning: (true, false))
                            }
                            return
                        }

                        connection.receive(minimumIncompleteLength: 2, maximumLength: 1024) { data, _, _, recvError in
                            if guard_.tryConsume() {
                                connection.cancel()
                                if let data = data, data.count >= 2 {
                                    let validated = Self.validateOpenVPNResponse(data)
                                    continuation.resume(returning: (true, validated))
                                } else if recvError == nil {
                                    continuation.resume(returning: (true, false))
                                } else {
                                    continuation.resume(returning: (true, false))
                                }
                            }
                        }
                    })
                case .failed, .cancelled:
                    if guard_.tryConsume() {
                        continuation.resume(returning: (false, false))
                    }
                default:
                    break
                }
            }

            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 8) {
                if guard_.tryConsume() {
                    connection.cancel()
                    continuation.resume(returning: (false, false))
                }
            }
        }
    }

    // MARK: - OpenVPN UDP Handshake

    private nonisolated func testOpenVPNUDPHandshake(host: String, port: UInt16) async -> (portOpen: Bool, protocolValidated: Bool) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return (false, false)
        }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: nwPort,
                using: .udp
            )
            let guard_ = ContinuationGuard()
            let queue = DispatchQueue(label: "ovpn.udp.\(host).\(port)")

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let resetPacket = Self.buildOpenVPNResetPacket()
                    connection.send(content: resetPacket, completion: .contentProcessed { sendError in
                        if sendError != nil {
                            if guard_.tryConsume() {
                                connection.cancel()
                                continuation.resume(returning: (true, false))
                            }
                            return
                        }

                        connection.receiveMessage { data, _, _, _ in
                            if guard_.tryConsume() {
                                connection.cancel()
                                if let data = data, !data.isEmpty {
                                    let validated = Self.validateOpenVPNResponse(data)
                                    continuation.resume(returning: (true, validated))
                                } else {
                                    continuation.resume(returning: (true, false))
                                }
                            }
                        }
                    })
                case .failed, .cancelled:
                    if guard_.tryConsume() {
                        continuation.resume(returning: (false, false))
                    }
                default:
                    break
                }
            }

            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 6) {
                if guard_.tryConsume() {
                    connection.cancel()
                    continuation.resume(returning: (false, false))
                }
            }
        }
    }

    private nonisolated static func buildOpenVPNResetPacket() -> Data {
        var data = Data()
        data.append(0x38)
        let sessionId = (0..<8).map { _ in UInt8.random(in: 0...255) }
        data.append(contentsOf: sessionId)
        data.append(0x00)
        let packetId = Data([0x00, 0x00, 0x00, 0x00])
        data.append(packetId)
        return data
    }

    private nonisolated static func validateOpenVPNResponse(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let opcode = data[0] >> 3
        return opcode == 0x08 || opcode == 0x07 || opcode == 0x04
    }

    // MARK: - DNS Resolution

    private nonisolated func resolveHost(_ host: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let hostRef = CFHostCreateWithName(nil, host as CFString).takeRetainedValue()
            var resolved = DarwinBoolean(false)
            CFHostStartInfoResolution(hostRef, .addresses, nil)
            let addresses = CFHostGetAddressing(hostRef, &resolved)
            if resolved.boolValue, let addrs = addresses?.takeUnretainedValue() as? [Data], !addrs.isEmpty {
                continuation.resume(returning: true)
            } else {
                continuation.resume(returning: false)
            }
        }
    }

    private nonisolated func resolveHostViaDoH(_ host: String) async -> Bool {
        let dohEndpoints = [
            "https://cloudflare-dns.com/dns-query?name=\(host)&type=A",
            "https://dns.google/dns-query?name=\(host)&type=A",
            "https://dns.quad9.net:5053/dns-query?name=\(host)&type=A"
        ]

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        for urlString in dohEndpoints {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 6
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let answers = json["Answer"] as? [[String: Any]], !answers.isEmpty {
                        return true
                    }
                }
            } catch {
                continue
            }
        }
        return false
    }

    private nonisolated func testTCPPort(host: String, port: Int, timeout: Double) async -> Bool {
        guard port > 0, port <= 65535, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: nwPort,
                using: .tcp
            )
            let guard_ = ContinuationGuard()
            let queue = DispatchQueue(label: "tcp.test.\(host).\(port)")

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if guard_.tryConsume() {
                        connection.cancel()
                        continuation.resume(returning: true)
                    }
                case .failed, .cancelled:
                    if guard_.tryConsume() {
                        continuation.resume(returning: false)
                    }
                default:
                    break
                }
            }

            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout) {
                if guard_.tryConsume() {
                    connection.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private nonisolated func elapsed(_ start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
