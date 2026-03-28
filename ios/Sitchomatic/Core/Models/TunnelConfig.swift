import Foundation

/// Swift 6.2 Sendable configuration for WireGuard/NordLynx tunnels.
/// All fields are value types, ensuring zero-cost Sendable conformance.
public struct TunnelConfig: Sendable, Codable, Equatable {
    public let serverAddress: String
    public let serverPort: UInt16
    public let privateKey: String
    public let publicKey: String
    public let presharedKey: String?
    public let dns: [String]
    public let mtu: UInt16
    public let allowedIPs: [String]
    public let keepAlive: UInt16

    public init(
        serverAddress: String,
        serverPort: UInt16 = 51820,
        privateKey: String,
        publicKey: String,
        presharedKey: String? = nil,
        dns: [String] = ["1.1.1.1", "8.8.8.8"],
        mtu: UInt16 = 1280,
        allowedIPs: [String] = ["0.0.0.0/0"],
        keepAlive: UInt16 = 25
    ) {
        self.serverAddress = serverAddress
        self.serverPort = serverPort
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.presharedKey = presharedKey
        self.dns = dns
        self.mtu = mtu
        self.allowedIPs = allowedIPs
        self.keepAlive = keepAlive
    }
}
