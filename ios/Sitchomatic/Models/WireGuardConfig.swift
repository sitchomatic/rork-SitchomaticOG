import Foundation

nonisolated struct WireGuardConfig: Identifiable, Codable, Sendable {
    let id: UUID
    let fileName: String
    let interfaceAddress: String
    let interfacePrivateKey: String
    let interfaceDNS: String
    let interfaceMTU: Int?
    let peerPublicKey: String
    let peerPreSharedKey: String?
    let peerEndpoint: String
    let peerAllowedIPs: String
    let peerPersistentKeepalive: Int?
    let rawContent: String
    var isEnabled: Bool
    var importedAt: Date
    var lastTested: Date?
    var isReachable: Bool
    var failCount: Int

    init(
        id: UUID = UUID(),
        fileName: String,
        interfaceAddress: String,
        interfacePrivateKey: String,
        interfaceDNS: String,
        interfaceMTU: Int? = nil,
        peerPublicKey: String,
        peerPreSharedKey: String? = nil,
        peerEndpoint: String,
        peerAllowedIPs: String,
        peerPersistentKeepalive: Int? = nil,
        rawContent: String,
        isEnabled: Bool = true,
        importedAt: Date = Date(),
        lastTested: Date? = nil,
        isReachable: Bool = false,
        failCount: Int = 0
    ) {
        self.id = id
        self.fileName = fileName
        self.interfaceAddress = interfaceAddress
        self.interfacePrivateKey = interfacePrivateKey
        self.interfaceDNS = interfaceDNS
        self.interfaceMTU = interfaceMTU
        self.peerPublicKey = peerPublicKey
        self.peerPreSharedKey = peerPreSharedKey
        self.peerEndpoint = peerEndpoint
        self.peerAllowedIPs = peerAllowedIPs
        self.peerPersistentKeepalive = peerPersistentKeepalive
        self.rawContent = rawContent
        self.isEnabled = isEnabled
        self.importedAt = importedAt
        self.lastTested = lastTested
        self.isReachable = isReachable
        self.failCount = failCount
    }

    var endpointHost: String {
        let cleaned = peerEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colonRange = cleaned.range(of: ":", options: .backwards) {
            let potentialPort = String(cleaned[colonRange.upperBound...])
            if Int(potentialPort) != nil {
                return String(cleaned[cleaned.startIndex..<colonRange.lowerBound])
            }
        }
        return cleaned
    }

    var endpointPort: Int {
        let cleaned = peerEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colonRange = cleaned.range(of: ":", options: .backwards) {
            let potentialPort = String(cleaned[colonRange.upperBound...])
            if let port = Int(potentialPort) { return port }
        }
        return 51820
    }

    var displayString: String {
        "\(endpointHost):\(endpointPort)"
    }

    var serverName: String {
        let host = endpointHost
        if host.contains(".nordvpn.com") {
            return host.replacingOccurrences(of: ".nordvpn.com", with: "")
        }
        if host.contains(".") {
            let parts = host.components(separatedBy: ".")
            if parts.count >= 2 {
                return parts[0]
            }
        }
        return host
    }

    var statusLabel: String {
        if !isEnabled { return "Disabled" }
        if let _ = lastTested {
            return isReachable ? "Reachable" : "Unreachable"
        }
        return "Untested"
    }

    var uniqueKey: String {
        "\(peerPublicKey)|\(peerEndpoint)"
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        interfaceAddress = try container.decode(String.self, forKey: .interfaceAddress)
        interfacePrivateKey = try container.decode(String.self, forKey: .interfacePrivateKey)
        interfaceDNS = try container.decode(String.self, forKey: .interfaceDNS)
        interfaceMTU = try container.decodeIfPresent(Int.self, forKey: .interfaceMTU)
        peerPublicKey = try container.decode(String.self, forKey: .peerPublicKey)
        peerPreSharedKey = try container.decodeIfPresent(String.self, forKey: .peerPreSharedKey)
        peerEndpoint = try container.decode(String.self, forKey: .peerEndpoint)
        peerAllowedIPs = try container.decode(String.self, forKey: .peerAllowedIPs)
        peerPersistentKeepalive = try container.decodeIfPresent(Int.self, forKey: .peerPersistentKeepalive)
        rawContent = try container.decode(String.self, forKey: .rawContent)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        lastTested = try container.decodeIfPresent(Date.self, forKey: .lastTested)
        isReachable = try container.decode(Bool.self, forKey: .isReachable)
        failCount = try container.decodeIfPresent(Int.self, forKey: .failCount) ?? 0
    }

    static func parse(fileName: String, content: String) -> WireGuardConfig? {
        let rawLines = content.components(separatedBy: .newlines)

        var address = ""
        var privateKey = ""
        var dns = ""
        var mtu: Int?
        var publicKey = ""
        var preSharedKey: String?
        var endpoint = ""
        var allowedIPs = "0.0.0.0/0"
        var keepalive: Int?

        var inInterface = false
        var inPeer = false

        for rawLine in rawLines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }

            let lower = line.lowercased()
            if lower == "[interface]" || lower.hasPrefix("[interface]") {
                inInterface = true
                inPeer = false
                continue
            }
            if lower == "[peer]" || lower.hasPrefix("[peer]") {
                inInterface = false
                inPeer = true
                continue
            }

            guard let eqIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

            guard !value.isEmpty else { continue }

            if inInterface {
                switch key {
                case "address":
                    address = value
                case "privatekey":
                    privateKey = value
                case "dns":
                    dns = value
                case "mtu":
                    mtu = Int(value)
                default:
                    break
                }
            } else if inPeer {
                switch key {
                case "publickey":
                    publicKey = value
                case "presharedkey":
                    preSharedKey = value
                case "endpoint":
                    endpoint = value
                case "allowedips":
                    allowedIPs = value
                case "persistentkeepalive":
                    keepalive = Int(value)
                default:
                    break
                }
            }
        }

        guard !privateKey.isEmpty else { return nil }
        guard !publicKey.isEmpty else { return nil }
        guard !endpoint.isEmpty else { return nil }

        if address.isEmpty { address = "10.5.0.2/32" }

        return WireGuardConfig(
            fileName: fileName,
            interfaceAddress: address,
            interfacePrivateKey: privateKey,
            interfaceDNS: dns,
            interfaceMTU: mtu,
            peerPublicKey: publicKey,
            peerPreSharedKey: preSharedKey,
            peerEndpoint: endpoint,
            peerAllowedIPs: allowedIPs,
            peerPersistentKeepalive: keepalive,
            rawContent: content
        )
    }

    static func parseMultiple(fileName: String, content: String) -> [WireGuardConfig] {
        var configs: [WireGuardConfig] = []

        let rawLines = content.components(separatedBy: .newlines)

        var address = ""
        var privateKey = ""
        var dns = ""
        var mtu: Int?

        var peers: [(publicKey: String, preSharedKey: String?, endpoint: String, allowedIPs: String, keepalive: Int?)] = []
        var currentPeerPublicKey = ""
        var currentPeerPreSharedKey: String?
        var currentPeerEndpoint = ""
        var currentPeerAllowedIPs = "0.0.0.0/0"
        var currentPeerKeepalive: Int?

        var inInterface = false
        var inPeer = false

        func flushPeer() {
            if !currentPeerPublicKey.isEmpty && !currentPeerEndpoint.isEmpty {
                peers.append((currentPeerPublicKey, currentPeerPreSharedKey, currentPeerEndpoint, currentPeerAllowedIPs, currentPeerKeepalive))
            }
            currentPeerPublicKey = ""
            currentPeerPreSharedKey = nil
            currentPeerEndpoint = ""
            currentPeerAllowedIPs = "0.0.0.0/0"
            currentPeerKeepalive = nil
        }

        for rawLine in rawLines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }

            let lower = line.lowercased()
            if lower == "[interface]" || lower.hasPrefix("[interface]") {
                if inPeer { flushPeer() }
                inInterface = true
                inPeer = false
                continue
            }
            if lower == "[peer]" || lower.hasPrefix("[peer]") {
                if inPeer { flushPeer() }
                inInterface = false
                inPeer = true
                continue
            }

            guard let eqIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            if inInterface {
                switch key {
                case "address": address = value
                case "privatekey": privateKey = value
                case "dns": dns = value
                case "mtu": mtu = Int(value)
                default: break
                }
            } else if inPeer {
                switch key {
                case "publickey": currentPeerPublicKey = value
                case "presharedkey": currentPeerPreSharedKey = value
                case "endpoint": currentPeerEndpoint = value
                case "allowedips": currentPeerAllowedIPs = value
                case "persistentkeepalive": currentPeerKeepalive = Int(value)
                default: break
                }
            }
        }
        if inPeer { flushPeer() }

        if peers.isEmpty { return [] }
        if privateKey.isEmpty { return [] }
        if address.isEmpty { address = "10.5.0.2/32" }

        for (index, peer) in peers.enumerated() {
            let suffix = peers.count > 1 ? " [\(index + 1)]" : ""
            let config = WireGuardConfig(
                fileName: "\(fileName)\(suffix)",
                interfaceAddress: address,
                interfacePrivateKey: privateKey,
                interfaceDNS: dns,
                interfaceMTU: mtu,
                peerPublicKey: peer.publicKey,
                peerPreSharedKey: peer.preSharedKey,
                peerEndpoint: peer.endpoint,
                peerAllowedIPs: peer.allowedIPs,
                peerPersistentKeepalive: peer.keepalive,
                rawContent: content
            )
            configs.append(config)
        }

        return configs
    }
}
