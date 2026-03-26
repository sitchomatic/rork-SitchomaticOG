import Foundation
import Observation
import Network

nonisolated enum NodeMavenProxyType: String, CaseIterable, Codable, Sendable {
    case residential = "residential"
    case mobile = "mobile"

    var label: String {
        switch self {
        case .residential: "Residential"
        case .mobile: "Mobile (4G/5G)"
        }
    }

    var icon: String {
        switch self {
        case .residential: "house.fill"
        case .mobile: "antenna.radiowaves.left.and.right"
        }
    }
}

nonisolated enum NodeMavenCountry: String, CaseIterable, Codable, Sendable {
    case au = "au"
    case us = "us"
    case uk = "uk"
    case de = "de"
    case ca = "ca"
    case fr = "fr"
    case jp = "jp"
    case random = ""

    var label: String {
        switch self {
        case .au: "Australia"
        case .us: "United States"
        case .uk: "United Kingdom"
        case .de: "Germany"
        case .ca: "Canada"
        case .fr: "France"
        case .jp: "Japan"
        case .random: "Random"
        }
    }

    var icon: String {
        switch self {
        case .au: "globe.asia.australia.fill"
        case .us: "flag.fill"
        case .uk, .de, .fr: "globe.europe.africa.fill"
        case .ca: "globe.americas.fill"
        case .jp: "globe.asia.australia.fill"
        case .random: "globe"
        }
    }

    var flagEmoji: String {
        switch self {
        case .au: "🇦🇺"
        case .us: "🇺🇸"
        case .uk: "🇬🇧"
        case .de: "🇩🇪"
        case .ca: "🇨🇦"
        case .fr: "🇫🇷"
        case .jp: "🇯🇵"
        case .random: "🌐"
        }
    }
}

nonisolated enum NodeMavenFilter: String, CaseIterable, Codable, Sendable {
    case low = "low"
    case medium = "medium"
    case high = "high"

    var label: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var detail: String {
        switch self {
        case .low: "Fastest, lower quality IPs"
        case .medium: "Balanced speed & quality"
        case .high: "Cleanest IPs, slower"
        }
    }
}

nonisolated enum NodeMavenSessionMode: String, CaseIterable, Codable, Sendable {
    case rotating = "rotating"
    case sticky = "sticky"

    var label: String {
        switch self {
        case .rotating: "Rotating"
        case .sticky: "Sticky"
        }
    }

    var detail: String {
        switch self {
        case .rotating: "New IP each request"
        case .sticky: "Same IP per session"
        }
    }
}

@Observable
@MainActor
class NodeMavenService {
    static let shared = NodeMavenService()

    static let gatewayHost = "gate.nodemaven.com"
    static let socks5Port = 1080
    static let httpPort = 8080

    static let mobileUsername = "Sitchmobile-country-au-type-mobile-filter-medium"
    static let residentialUsername = "Sitchomatic-country-au-filter-medium"
    static let hardcodedPassword = "Dada07077"

    private let logger = DebugLogger.shared

    var apiKey: String = "" { didSet { persist() } }
    var proxyUsername: String = "" { didSet { persist() } }
    var proxyPassword: String = "" { didSet { persist() } }
    var country: NodeMavenCountry = .au { didSet { persist() } }
    var proxyType: NodeMavenProxyType = .mobile { didSet { syncUsernameToProxyType(); persist() } }
    var filter: NodeMavenFilter = .medium { didSet { persist() } }
    var sessionMode: NodeMavenSessionMode = .sticky { didSet { persist() } }

    var isEnabled: Bool { !proxyUsername.isEmpty && !proxyPassword.isEmpty }

    var lastTestResult: String?
    var lastTestIP: String?
    var isTesting: Bool = false

    private var sessionCounter: Int = 0

    init() {
        load()
    }

    private func syncUsernameToProxyType() {
        let expected = proxyType == .mobile ? Self.mobileUsername : Self.residentialUsername
        if proxyUsername != expected {
            proxyUsername = expected
        }
    }

    func buildUsername(sessionId: String? = nil) -> String {
        let baseUsername: String
        if proxyType == .mobile {
            baseUsername = Self.mobileUsername
        } else {
            baseUsername = Self.residentialUsername
        }

        var parts = [baseUsername]

        if let sid = sessionId {
            parts.append("sid-\(sid)")
        } else if sessionMode == .sticky {
            sessionCounter += 1
            let sid = String(UUID().uuidString.prefix(12)).lowercased().replacingOccurrences(of: "-", with: "") + "\(sessionCounter)"
            parts.append("sid-\(sid)")
        }

        return parts.joined(separator: "-")
    }

    func generateProxyConfig(sessionId: String? = nil) -> ProxyConfig? {
        guard isEnabled else { return nil }
        let username = buildUsername(sessionId: sessionId)
        return ProxyConfig(
            host: Self.gatewayHost,
            port: Self.socks5Port,
            username: username,
            password: proxyPassword
        )
    }

    func generateProxyConfigForSession(_ index: Int) -> ProxyConfig? {
        let sid = "s\(index)_\(String(UUID().uuidString.prefix(8)).lowercased())"
        return generateProxyConfig(sessionId: sid)
    }

    func testConnection() async {
        guard isEnabled else {
            lastTestResult = "Missing credentials"
            return
        }

        isTesting = true
        defer { isTesting = false }

        let testSid = "test_\(Int(Date().timeIntervalSince1970))"
        guard let proxy = generateProxyConfig(sessionId: testSid) else {
            lastTestResult = "Failed to generate proxy config"
            return
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20

        var proxyDict: [String: Any] = [
            "SOCKSEnable": 1,
            "SOCKSProxy": proxy.host,
            "SOCKSPort": proxy.port,
        ]
        if let u = proxy.username { proxyDict["SOCKSUser"] = u }
        if let p = proxy.password { proxyDict["SOCKSPassword"] = p }
        config.connectionProxyDictionary = proxyDict

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        do {
            guard let url = URL(string: "https://api.ipify.org?format=json") else {
                lastTestResult = "Invalid test URL"
                return
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ip = json["ip"] as? String {
                lastTestIP = ip
                lastTestResult = "Connected — IP: \(ip)"
                logger.log("NodeMaven: test passed — IP: \(ip), country: \(country.label), type: \(proxyType.label), filter: \(filter.label)", category: .proxy, level: .success)
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                lastTestResult = "HTTP \(code)"
                logger.log("NodeMaven: test failed — HTTP \(code)", category: .proxy, level: .error)
            }
        } catch {
            lastTestResult = "Error: \(error.localizedDescription)"
            logger.log("NodeMaven: test failed — \(error.localizedDescription)", category: .proxy, level: .error)
        }
    }

    var statusSummary: String {
        guard isEnabled else { return "Not configured" }
        return "\(country.flagEmoji) \(country.label) · \(proxyType.label) · \(filter.label) quality"
    }

    var shortStatus: String {
        guard isEnabled else { return "OFF" }
        return "\(country.flagEmoji) \(proxyType.label)"
    }

    // MARK: - Persistence

    private let persistKey = "nodemaven_config_v1"

    private func persist() {
        let dict: [String: String] = [
            "apiKey": apiKey,
            "proxyUsername": proxyUsername,
            "proxyPassword": proxyPassword,
            "country": country.rawValue,
            "proxyType": proxyType.rawValue,
            "filter": filter.rawValue,
            "sessionMode": sessionMode.rawValue,
        ]
        UserDefaults.standard.set(dict, forKey: persistKey)
    }

    private func load() {
        guard let dict = UserDefaults.standard.dictionary(forKey: persistKey) as? [String: String] else {
            applyDefaults()
            return
        }
        apiKey = dict["apiKey"] ?? ""
        proxyUsername = dict["proxyUsername"] ?? Self.mobileUsername
        proxyPassword = dict["proxyPassword"] ?? Self.hardcodedPassword
        if proxyUsername.isEmpty { proxyUsername = Self.mobileUsername }
        if proxyPassword.isEmpty { proxyPassword = Self.hardcodedPassword }
        if let c = dict["country"], let v = NodeMavenCountry(rawValue: c) { country = v }
        if let t = dict["proxyType"], let v = NodeMavenProxyType(rawValue: t) { proxyType = v }
        if let f = dict["filter"], let v = NodeMavenFilter(rawValue: f) { filter = v }
        if let s = dict["sessionMode"], let v = NodeMavenSessionMode(rawValue: s) { sessionMode = v }
    }

    private func applyDefaults() {
        apiKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ0b2tlbl90eXBlIjoiYWNjZXNzIiwiZXhwIjoxNzczMzg2MjQyLCJpYXQiOjE3NzMzODQ0NDIsImp0aSI6Ijc3NGJiOTg4MTVmYjQ0ODY5MzhiOTJlZjFhMjViZTBiIiwidXNlcl9pZCI6IjkyMjUwMzFkLWVlOGQtNDMwZS1hOTE4LTE5MmE4NmUyNzUwMyJ9.ckJ_8Q6Et_yufcKFsVT3MB180Usrwi4NoOVaeh3hJ9o"
        proxyUsername = Self.mobileUsername
        proxyPassword = Self.hardcodedPassword
        country = .au
        proxyType = .mobile
        filter = .medium
        sessionMode = .sticky
        persist()
        logger.log("NodeMaven: applied default config — AU mobile, medium filter, sticky sessions", category: .proxy, level: .info)
    }
}
