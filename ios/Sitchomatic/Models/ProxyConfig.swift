import Foundation

nonisolated struct ProxyConfig: Identifiable, Codable, Sendable {
    let id: UUID
    let host: String
    let port: Int
    let username: String?
    let password: String?
    var lastTested: Date?
    var isWorking: Bool
    var failCount: Int

    init(id: UUID = UUID(), host: String, port: Int, username: String? = nil, password: String? = nil) {
        self.id = id
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.lastTested = nil
        self.isWorking = false
        self.failCount = 0
    }

    var socks5URL: URL? {
        var components = URLComponents()
        components.scheme = "socks5"
        components.host = host
        components.port = port
        if let username { components.user = username }
        if let password { components.password = password }
        return components.url
    }

    var displayString: String {
        if let u = username {
            return "\(u)@\(host):\(port)"
        }
        return "\(host):\(port)"
    }

    var statusLabel: String {
        if lastTested == nil { return "Untested" }
        if isWorking { return "Working" }
        return "Failed (\(failCount))"
    }
}
