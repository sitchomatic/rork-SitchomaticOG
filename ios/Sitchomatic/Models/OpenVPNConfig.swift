import Foundation

nonisolated struct OpenVPNConfig: Identifiable, Codable, Sendable {
    let id: UUID
    let fileName: String
    let remoteHost: String
    let remotePort: Int
    let proto: String
    let rawContent: String
    var isEnabled: Bool
    var importedAt: Date
    var lastTested: Date?
    var isReachable: Bool
    var failCount: Int
    var lastLatencyMs: Int?

    init(fileName: String, remoteHost: String, remotePort: Int, proto: String, rawContent: String) {
        self.id = UUID()
        self.fileName = fileName
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.proto = proto
        self.rawContent = rawContent
        self.isEnabled = true
        self.importedAt = Date()
        self.lastTested = nil
        self.isReachable = false
        self.failCount = 0
        self.lastLatencyMs = nil
    }

    var displayString: String {
        "\(remoteHost):\(remotePort) (\(proto))"
    }

    var statusLabel: String {
        if !isEnabled { return "Disabled" }
        if let _ = lastTested {
            return isReachable ? "Reachable" : "Unreachable"
        }
        return "Untested"
    }

    var uniqueKey: String {
        "\(remoteHost)|\(remotePort)|\(proto)"
    }

    var serverName: String {
        let host = remoteHost
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

    var nordCountryCode: String? {
        let host = remoteHost.lowercased()
        guard host.contains(".nordvpn.com") else { return nil }
        let prefix = host.replacingOccurrences(of: ".nordvpn.com", with: "")
        let letters = prefix.filter { $0.isLetter }
        guard letters.count >= 2 else { return nil }
        return String(letters.prefix(2)).uppercased()
    }

    var nordCountryId: Int? {
        guard let code = nordCountryCode else { return nil }
        return Self.nordCountryCodeToId[code]
    }

    private static let nordCountryCodeToId: [String: Int] = [
        "AL": 2, "AR": 10, "AU": 13, "AT": 14, "AZ": 15,
        "BE": 21, "BA": 27, "BR": 30, "BG": 33, "CA": 38,
        "CL": 43, "CO": 47, "CR": 52, "HR": 54, "CY": 56,
        "CZ": 57, "DK": 58, "EE": 68, "FI": 73, "FR": 74,
        "GE": 80, "DE": 81, "GR": 84, "HK": 97, "HU": 98,
        "IS": 99, "IN": 100, "ID": 101, "IE": 104, "IL": 105,
        "IT": 106, "JP": 108, "LV": 119, "LT": 125, "LU": 126,
        "MY": 131, "MX": 140, "MD": 142, "NL": 153, "NZ": 156,
        "MK": 128, "NO": 163, "PA": 170, "PE": 172, "PH": 174,
        "PL": 176, "PT": 177, "RO": 179, "RS": 192, "SG": 195,
        "SK": 196, "SI": 197, "ZA": 200, "KR": 114, "ES": 202,
        "SE": 208, "CH": 209, "TW": 211, "TH": 214, "TR": 220,
        "UA": 225, "AE": 226, "GB": 227, "US": 228, "VN": 234
    ]

    static func parse(fileName: String, content: String) -> OpenVPNConfig? {
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var host = ""
        var port = 1194
        var proto = "udp"
        var foundRemote = false

        for line in lines {
            let lower = line.lowercased()

            if lower.hasPrefix("remote ") && !foundRemote {
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 2 { host = parts[1] }
                if parts.count >= 3, let p = Int(parts[2]) { port = p }
                if parts.count >= 4 { proto = parts[3].lowercased() }
                foundRemote = true
            }

            if lower.hasPrefix("proto ") {
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 2 { proto = parts[1].lowercased() }
            }
        }

        guard !host.isEmpty else { return nil }

        return OpenVPNConfig(
            fileName: fileName,
            remoteHost: host,
            remotePort: port,
            proto: proto,
            rawContent: content
        )
    }
}
