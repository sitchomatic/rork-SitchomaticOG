import Foundation

nonisolated enum NordLynxVPNProtocol: String, CaseIterable, Sendable, Identifiable {
    case wireguardUDP = "wireguard_udp"
    case openvpnUDP = "openvpn_udp"
    case openvpnTCP = "openvpn_tcp"

    nonisolated var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wireguardUDP: "WireGuard (UDP)"
        case .openvpnUDP: "OpenVPN (UDP)"
        case .openvpnTCP: "OpenVPN (TCP)"
        }
    }

    var shortName: String {
        switch self {
        case .wireguardUDP: "WireGuard"
        case .openvpnUDP: "OpenVPN UDP"
        case .openvpnTCP: "OpenVPN TCP"
        }
    }

    var icon: String {
        switch self {
        case .wireguardUDP: "bolt.shield.fill"
        case .openvpnUDP: "lock.shield.fill"
        case .openvpnTCP: "lock.shield.fill"
        }
    }

    var fileExtension: String {
        switch self {
        case .wireguardUDP: "conf"
        case .openvpnUDP, .openvpnTCP: "ovpn"
        }
    }

    var defaultPort: Int {
        switch self {
        case .wireguardUDP: 51820
        case .openvpnUDP: 1194
        case .openvpnTCP: 443
        }
    }

    var isOpenVPN: Bool {
        switch self {
        case .openvpnUDP, .openvpnTCP: true
        case .wireguardUDP: false
        }
    }

    var transportProtocol: String {
        switch self {
        case .wireguardUDP, .openvpnUDP: "udp"
        case .openvpnTCP: "tcp"
        }
    }

    var ovpnConfigPath: String {
        switch self {
        case .openvpnUDP: "ovpn_udp"
        case .openvpnTCP: "ovpn_tcp"
        case .wireguardUDP: ""
        }
    }
}
