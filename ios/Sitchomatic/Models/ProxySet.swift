import Foundation

nonisolated enum ProxySetType: String, CaseIterable, Codable, Sendable {
    case socks5 = "SOCKS5 Proxy"
    case wireGuard = "WireGuard Config"
    case openVPN = "OpenVPN Config"

    var icon: String {
        switch self {
        case .socks5: "network"
        case .wireGuard: "lock.trianglebadge.exclamationmark.fill"
        case .openVPN: "shield.lefthalf.filled"
        }
    }

    var color: String {
        switch self {
        case .socks5: "blue"
        case .wireGuard: "cyan"
        case .openVPN: "orange"
        }
    }

    var maxItems: Int { 10 }
}

nonisolated struct ProxySetItem: Identifiable, Codable, Sendable {
    let id: UUID
    var label: String
    var host: String
    var port: Int
    var isEnabled: Bool
    var rawContent: String?

    init(id: UUID = UUID(), label: String, host: String, port: Int, isEnabled: Bool = true, rawContent: String? = nil) {
        self.id = id
        self.label = label
        self.host = host
        self.port = port
        self.isEnabled = isEnabled
        self.rawContent = rawContent
    }

    var displayString: String {
        "\(host):\(port)"
    }

    static func fromProxyConfig(_ proxy: ProxyConfig) -> ProxySetItem {
        ProxySetItem(
            label: proxy.displayString,
            host: proxy.host,
            port: proxy.port,
            rawContent: nil
        )
    }

    static func fromWireGuardConfig(_ wg: WireGuardConfig) -> ProxySetItem {
        ProxySetItem(
            label: wg.serverName,
            host: wg.endpointHost,
            port: wg.endpointPort,
            rawContent: wg.rawContent
        )
    }

    static func fromOpenVPNConfig(_ ovpn: OpenVPNConfig) -> ProxySetItem {
        ProxySetItem(
            label: ovpn.serverName,
            host: ovpn.remoteHost,
            port: ovpn.remotePort,
            rawContent: ovpn.rawContent
        )
    }
}

nonisolated struct ProxySet: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var type: ProxySetType
    var items: [ProxySetItem]
    var createdAt: Date
    var isActive: Bool

    init(id: UUID = UUID(), name: String, type: ProxySetType, items: [ProxySetItem] = [], createdAt: Date = Date(), isActive: Bool = true) {
        self.id = id
        self.name = name
        self.type = type
        self.items = items
        self.createdAt = createdAt
        self.isActive = isActive
    }

    var enabledItemCount: Int {
        items.filter(\.isEnabled).count
    }

    var typeIcon: String { type.icon }

    var summary: String {
        "\(enabledItemCount)/\(items.count) active"
    }

    var isFull: Bool {
        items.count >= type.maxItems
    }
}
