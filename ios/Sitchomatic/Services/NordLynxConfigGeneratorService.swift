import Foundation

nonisolated struct NordLynxConfigGeneratorService: Sendable {
    static let selectedKeyIDStorageKey = "nordlynx_selected_key_id"
    static let customKeyStorageKey = "nordlynx_custom_key"
    static let customKeyNameStorageKey = "nordlynx_custom_key_name"

    static var selectedKeyID: String {
        UserDefaults.standard.string(forKey: selectedKeyIDStorageKey) ?? NordLynxAccessKey.nick.id
    }

    static var activeAccessKey: NordLynxAccessKey {
        let keyID = selectedKeyID
        if let preset = NordLynxAccessKey.presets.first(where: { $0.id == keyID }) {
            return preset
        }
        if keyID == "custom" {
            let key = UserDefaults.standard.string(forKey: customKeyStorageKey) ?? ""
            let name = UserDefaults.standard.string(forKey: customKeyNameStorageKey) ?? "Custom"
            if !key.isEmpty {
                return NordLynxAccessKey(id: "custom", name: name, key: key, isPreset: false)
            }
        }
        return .nick
    }

    static var activePrivateKey: String {
        let activeProfile = UserDefaults.standard.string(forKey: "nordvpn_key_profile_v1") ?? "Nick"
        let profileKey = activeProfile == "Poli" ? "nordvpn_poli_private_key_v1" : "nordvpn_nick_private_key_v1"
        let profilePK = UserDefaults.standard.string(forKey: profileKey) ?? ""
        if !profilePK.isEmpty {
            return profilePK
        }
        let legacyPK = UserDefaults.standard.string(forKey: "nordvpn_private_key_v1") ?? ""
        if !legacyPK.isEmpty {
            return legacyPK
        }
        return activeAccessKey.key
    }

    static func selectKey(_ keyID: String) {
        UserDefaults.standard.set(keyID, forKey: selectedKeyIDStorageKey)
    }

    static func saveCustomKey(name: String, key: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        UserDefaults.standard.set(trimmedKey, forKey: customKeyStorageKey)
        UserDefaults.standard.set(trimmedName.isEmpty ? "Custom" : trimmedName, forKey: customKeyNameStorageKey)
        UserDefaults.standard.set("custom", forKey: selectedKeyIDStorageKey)
    }

    static func removeCustomKey() {
        UserDefaults.standard.removeObject(forKey: customKeyStorageKey)
        UserDefaults.standard.removeObject(forKey: customKeyNameStorageKey)
        if selectedKeyID == "custom" {
            selectKey(NordLynxAccessKey.nick.id)
        }
    }

    static var hasCustomKey: Bool {
        let key = UserDefaults.standard.string(forKey: customKeyStorageKey) ?? ""
        return !key.isEmpty
    }

    static var allAvailableKeys: [NordLynxAccessKey] {
        var keys = NordLynxAccessKey.presets
        if hasCustomKey {
            let key = UserDefaults.standard.string(forKey: customKeyStorageKey) ?? ""
            let name = UserDefaults.standard.string(forKey: customKeyNameStorageKey) ?? "Custom"
            keys.append(NordLynxAccessKey(id: "custom", name: name, key: key, isPreset: false))
        }
        return keys
    }

    private let service = NordLynxAPIService()

    func generate(from servers: [NordLynxServerResponse], vpnProtocol: NordLynxVPNProtocol) async throws -> [NordLynxGeneratedConfig] {
        switch vpnProtocol {
        case .wireguardUDP:
            return try generateWireGuard(from: servers)
        case .openvpnUDP, .openvpnTCP:
            return try await generateOpenVPN(from: servers, vpnProtocol: vpnProtocol)
        }
    }

    private func generateWireGuard(from servers: [NordLynxServerResponse]) throws -> [NordLynxGeneratedConfig] {
        let privateKey = Self.activePrivateKey
        var configs: [NordLynxGeneratedConfig] = []

        for server in servers {
            guard let publicKey = extractPublicKey(from: server, techIdentifier: "wireguard_udp") else {
                continue
            }

            let country = server.locations?.first?.country
            let countryName = country?.name ?? "Unknown"
            let countryCode = country?.code ?? ""
            let cityName = country?.city?.name ?? ""

            let content = "[Interface]\nPrivateKey = \(privateKey)\nAddress = 10.5.0.2/32\nDNS = 103.86.96.100, 103.86.99.100\n\n[Peer]\nPublicKey = \(publicKey)\nEndpoint = \(server.station):51820\nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 25"

            configs.append(NordLynxGeneratedConfig(
                hostname: server.hostname,
                stationIP: server.station,
                publicKey: publicKey,
                fileContent: content,
                fileName: "\(server.hostname).conf",
                countryName: countryName,
                countryCode: countryCode,
                cityName: cityName,
                serverLoad: server.load,
                vpnProtocol: .wireguardUDP,
                port: 51820
            ))
        }

        guard !configs.isEmpty else {
            throw NordLynxAPIError.noServersFound
        }

        return configs
    }

    private func generateOpenVPN(from servers: [NordLynxServerResponse], vpnProtocol: NordLynxVPNProtocol) async throws -> [NordLynxGeneratedConfig] {
        var configs: [NordLynxGeneratedConfig] = []

        try await withThrowingTaskGroup(of: NordLynxGeneratedConfig?.self) { group in
            for server in servers {
                group.addTask {
                    let country = server.locations?.first?.country
                    let countryName = country?.name ?? "Unknown"
                    let countryCode = country?.code ?? ""
                    let cityName = country?.city?.name ?? ""

                    do {
                        let ovpnContent = try await service.downloadOVPNConfig(
                            hostname: server.hostname,
                            vpnProtocol: vpnProtocol
                        )

                        let suffix = vpnProtocol == .openvpnTCP ? "tcp" : "udp"
                        let fileName = "\(server.hostname).\(suffix).ovpn"

                        return NordLynxGeneratedConfig(
                            hostname: server.hostname,
                            stationIP: server.station,
                            publicKey: "",
                            fileContent: ovpnContent,
                            fileName: fileName,
                            countryName: countryName,
                            countryCode: countryCode,
                            cityName: cityName,
                            serverLoad: server.load,
                            vpnProtocol: vpnProtocol,
                            port: vpnProtocol.defaultPort
                        )
                    } catch {
                        return nil
                    }
                }
            }

            for try await config in group {
                if let config {
                    configs.append(config)
                }
            }
        }

        configs.sort { $0.hostname < $1.hostname }

        guard !configs.isEmpty else {
            throw NordLynxAPIError.noServersFound
        }

        return configs
    }

    func saveToDocuments(_ configs: [NordLynxGeneratedConfig]) throws -> URL {
        let documentsURL = URL.documentsDirectory.appending(path: "NordLynx_Configs")

        if FileManager.default.fileExists(atPath: documentsURL.path()) {
            try FileManager.default.removeItem(at: documentsURL)
        }

        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)

        for config in configs {
            let fileURL = documentsURL.appending(path: config.fileName)
            try config.fileContent.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        return documentsURL
    }

    private func extractPublicKey(from server: NordLynxServerResponse, techIdentifier: String) -> String? {
        guard let technologies = server.technologies,
              let tech = technologies.first(where: { $0.identifier == techIdentifier }),
              let metadata = tech.metadata,
              let keyMeta = metadata.first(where: { $0.name == "public_key" }) else {
            return nil
        }
        return keyMeta.value
    }
}
