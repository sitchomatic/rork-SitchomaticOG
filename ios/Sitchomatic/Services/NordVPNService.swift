import Foundation
import Observation

nonisolated struct NordVPNServer: Codable, Sendable {
    let id: Int
    let hostname: String
    let station: String
    let load: Int
    let locations: [NordLocation]?
    let technologies: [NordTechnology]?

    var publicKey: String? {
        technologies?.first(where: { $0.identifier == "wireguard_udp" })?
            .metadata?.first?.value
    }

    var hasOpenVPNTCP: Bool {
        technologies?.contains(where: { $0.identifier == "openvpn_tcp" }) ?? false
    }

    var hasOpenVPNUDP: Bool {
        technologies?.contains(where: { $0.identifier == "openvpn_udp" }) ?? false
    }

    var city: String? {
        locations?.first?.country?.city?.name
    }

    var country: String? {
        locations?.first?.country?.name
    }

    var tcpOVPNDownloadURL: URL? {
        URL(string: "https://downloads.nordcdn.com/configs/files/ovpn_tcp/servers/\(hostname).tcp.ovpn")
    }

    var udpOVPNDownloadURL: URL? {
        URL(string: "https://downloads.nordcdn.com/configs/files/ovpn_udp/servers/\(hostname).udp.ovpn")
    }
}

nonisolated struct NordLocation: Codable, Sendable {
    let country: NordCountry?
}

nonisolated struct NordCountry: Codable, Sendable {
    let name: String?
    let city: NordCity?
}

nonisolated struct NordCity: Codable, Sendable {
    let name: String?
}

nonisolated struct NordTechnology: Codable, Sendable {
    let id: Int?
    let identifier: String?
    let metadata: [NordMetadata]?
}

nonisolated struct NordMetadata: Codable, Sendable {
    let name: String?
    let value: String?
}

nonisolated struct NordCredentials: Codable, Sendable {
    let nordlynx_private_key: String?
    let username: String?
    let password: String?
}

nonisolated enum NordKeyProfile: String, CaseIterable, Codable, Sendable {
    case nick = "Nick"
    case poli = "Poli"

    var hardcodedAccessKey: String {
        switch self {
        case .nick: kDefaultNickKey
        case .poli: kDefaultPoliKey
        }
    }
}

@Observable
@MainActor
class NordVPNService {
    static let shared = NordVPNService()

    var accessKey: String = ""
    var privateKey: String = ""
    var serviceUsername: String = ""
    var servicePassword: String = ""
    var isLoadingServers: Bool = false
    var isLoadingKey: Bool = false
    var lastError: String?
    var recommendedServers: [NordVPNServer] = []
    var lastFetched: Date?
    var activeKeyProfile: NordKeyProfile = .nick
    var hasSelectedProfile: Bool = false

    var hasServiceCredentials: Bool { !serviceUsername.isEmpty && !servicePassword.isEmpty }

    private let accessKeyPersistKey = "nordvpn_access_key_v1"
    private let privateKeyPersistKey = "nordvpn_private_key_v1"
    private let keyProfilePersistKey = "nordvpn_key_profile_v1"
    private let nickPrivateKeyPersistKey = "nordvpn_nick_private_key_v1"
    private let poliPrivateKeyPersistKey = "nordvpn_poli_private_key_v1"
    private let serviceUsernamePersistKey = "nordvpn_service_username_v1"
    private let servicePasswordPersistKey = "nordvpn_service_password_v1"
    private let profileStorageSeedKey = "profile_network_storage_seed_v2"
    private let profileStorageSeedVersion = "2"
    private let logger = DebugLogger.shared
    private let serverCacheKey = "nordvpn_server_cache_v1"
    private let serverCacheTimestampKey = "nordvpn_server_cache_ts_v1"
    private let serverCacheMaxAge: TimeInterval = 3600

    init() {
        if let profileRaw = UserDefaults.standard.string(forKey: keyProfilePersistKey),
           let profile = NordKeyProfile(rawValue: profileRaw) {
            activeKeyProfile = profile
            hasSelectedProfile = true
        }
        accessKey = NordVPNKeyStore.shared.keyForProfile(activeKeyProfile)
        privateKey = UserDefaults.standard.string(forKey: privateKeyPersistKey(for: activeKeyProfile)) ?? ""
        serviceUsername = UserDefaults.standard.string(forKey: serviceUsernamePersistKey) ?? ""
        servicePassword = UserDefaults.standard.string(forKey: servicePasswordPersistKey) ?? ""
    }

    private func privateKeyPersistKey(for profile: NordKeyProfile) -> String {
        switch profile {
        case .nick:
            nickPrivateKeyPersistKey
        case .poli:
            poliPrivateKeyPersistKey
        }
    }

    private func persistCurrentPrivateKey() {
        guard !privateKey.isEmpty else { return }
        UserDefaults.standard.set(privateKey, forKey: privateKeyPersistKey(for: activeKeyProfile))
        UserDefaults.standard.set(privateKey, forKey: privateKeyPersistKey)
    }

    private func activateProfile(_ profile: NordKeyProfile, persistSelection: Bool) {
        activeKeyProfile = profile
        accessKey = NordVPNKeyStore.shared.keyForProfile(profile)
        privateKey = UserDefaults.standard.string(forKey: privateKeyPersistKey(for: profile)) ?? ""
        if persistSelection {
            UserDefaults.standard.set(profile.rawValue, forKey: keyProfilePersistKey)
        }
        UserDefaults.standard.set(accessKey, forKey: accessKeyPersistKey)
    }

    func switchProfile(_ profile: NordKeyProfile, triggerAutoPopulate: Bool = true) {
        guard activeKeyProfile != profile || !hasSelectedProfile else { return }

        persistCurrentPrivateKey()
        activateProfile(profile, persistSelection: true)
        hasSelectedProfile = true

        recommendedServers.removeAll()
        lastError = nil
        autoPopulateError = nil

        ProxyRotationService.shared.reloadForActiveProfile()
        NetworkSessionFactory.shared.resetRotationIndexes()
        DeviceProxyService.shared.handleProfileSwitch()

        logger.log("NordVPN: switched to \(profile.rawValue) profile — key=\(accessKey.prefix(8))... pk=\(privateKey.isEmpty ? "EMPTY" : "SET") — all configs reloaded", category: .vpn, level: .success)

        if triggerAutoPopulate {
            Task {
                await autoPopulateConfigs(forceRefresh: false)
            }
        }
    }

    func setAccessKey(_ key: String) {
        accessKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        NordVPNKeyStore.shared.updateKey(accessKey, for: activeKeyProfile)
        UserDefaults.standard.set(accessKey, forKey: accessKeyPersistKey)
    }

    func setPrivateKey(_ key: String) {
        privateKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(privateKey, forKey: privateKeyPersistKey(for: activeKeyProfile))
        UserDefaults.standard.set(privateKey, forKey: privateKeyPersistKey)
    }

    var hasAccessKey: Bool { !accessKey.isEmpty }
    var hasPrivateKey: Bool { !privateKey.isEmpty }

    func storeServiceCredentials(_ creds: NordCredentials) {
        if let u = creds.username, !u.isEmpty {
            serviceUsername = u
            UserDefaults.standard.set(u, forKey: serviceUsernamePersistKey)
        }
        if let p = creds.password, !p.isEmpty {
            servicePassword = p
            UserDefaults.standard.set(p, forKey: servicePasswordPersistKey)
        }
    }

    private let maxRetryAttempts = 3
    private let retryBaseDelay: TimeInterval = 2
    private let expectedWireGuardConfigCount = 24
    private let expectedOpenVPNConfigCount = 10

    private func isRetryableError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        return false
    }

    private func isRetryableHTTPStatus(_ code: Int) -> Bool {
        code == 429 || code == 502 || code == 503 || code == 504
    }

    nonisolated enum TokenTestResult: Sendable {
        case success(privateKeyPrefix: String)
        case failed(reason: String)
        case expired

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }
    }

    static func isValidTokenFormat(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.count >= 32 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    func testAccessToken() async {
        guard hasAccessKey else {
            tokenTestResult = .failed(reason: "No access token set. Generate one from NordVPN dashboard → Manual Setup.")
            return
        }

        guard Self.isValidTokenFormat(accessKey) else {
            tokenTestResult = .failed(reason: "Token format looks invalid. NordVPN tokens are 64+ character hex strings. Go to my.nordaccount.com → Manual Setup to generate a real token.")
            return
        }

        isTestingToken = true
        tokenTestResult = nil
        defer { isTestingToken = false }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        guard let url = URL(string: "https://api.nordvpn.com/v1/users/services/credentials") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let credentials = "token:\(accessKey)"
        if let credData = credentials.data(using: .utf8) {
            request.setValue("Basic \(credData.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200:
                    if let creds = try? JSONDecoder().decode(NordCredentials.self, from: data),
                       let pk = creds.nordlynx_private_key, !pk.isEmpty {
                        setPrivateKey(pk)
                        storeServiceCredentials(creds)
                        isTokenExpired = false
                        tokenTestResult = .success(privateKeyPrefix: String(pk.prefix(8)))
                        logger.log("NordVPN: token test SUCCESS — private key obtained, service creds \(hasServiceCredentials ? "SET" : "EMPTY")", category: .vpn, level: .success)
                    } else {
                        let body = String(data: data, encoding: .utf8) ?? ""
                        tokenTestResult = .failed(reason: "API returned 200 but no nordlynx_private_key in response. Body: \(body.prefix(200))")
                        logger.log("NordVPN: token test — 200 but no private key", category: .vpn, level: .error)
                    }
                case 401:
                    isTokenExpired = true
                    tokenTestResult = .expired
                    logger.log("NordVPN: token test — 401 Unauthorized (token expired/invalid)", category: .vpn, level: .error)
                case 403:
                    isTokenExpired = true
                    tokenTestResult = .failed(reason: "403 Forbidden — subscription may be expired or token lacks permissions.")
                    logger.log("NordVPN: token test — 403 Forbidden", category: .vpn, level: .error)
                default:
                    let body = String(data: data, encoding: .utf8) ?? ""
                    tokenTestResult = .failed(reason: "HTTP \(http.statusCode): \(body.prefix(200))")
                    logger.log("NordVPN: token test — HTTP \(http.statusCode)", category: .vpn, level: .error)
                }
            }
        } catch {
            tokenTestResult = .failed(reason: "Network error: \(error.localizedDescription)")
            logger.logError("NordVPN: token test network error", error: error, category: .vpn)
        }
    }

    func fetchPrivateKey() async {
        guard hasAccessKey else {
            lastError = "No access key configured"
            return
        }

        isLoadingKey = true
        lastError = nil
        defer { isLoadingKey = false }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        guard let url = URL(string: "https://api.nordvpn.com/v1/users/services/credentials") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let credentials = "token:\(accessKey)"
        if let credData = credentials.data(using: .utf8) {
            request.setValue("Basic \(credData.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }

        for attempt in 1...maxRetryAttempts {
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    if isRetryableHTTPStatus(http.statusCode) && attempt < maxRetryAttempts {
                        logger.log("NordVPN: fetchPrivateKey HTTP \(http.statusCode) — retry \(attempt)/\(maxRetryAttempts)", category: .vpn, level: .warning)
                        try? await Task.sleep(for: .seconds(retryBaseDelay * Double(attempt)))
                        continue
                    }
                    switch http.statusCode {
                    case 401:
                        lastError = "Access token expired or invalid. Generate a new token from NordVPN dashboard → Manual Setup."
                        isTokenExpired = true
                    case 403:
                        lastError = "Access denied. Your NordVPN subscription may have expired or the token lacks permissions."
                        isTokenExpired = true
                    case 404:
                        lastError = "Credentials endpoint not found (HTTP 404). NordVPN may have updated their API."
                    case 429:
                        lastError = "Rate limited by NordVPN. Wait a minute and try again."
                    default:
                        lastError = "API returned HTTP \(http.statusCode)"
                    }
                    logger.log("NordVPN: fetchPrivateKey failed — HTTP \(http.statusCode): \(body.prefix(200))", category: .vpn, level: .error, metadata: ["statusCode": "\(http.statusCode)"])
                    return
                }
                let creds = try JSONDecoder().decode(NordCredentials.self, from: data)
                storeServiceCredentials(creds)
                if let pk = creds.nordlynx_private_key, !pk.isEmpty {
                    setPrivateKey(pk)
                    isTokenExpired = false
                    logger.log("NordVPN: private key fetched successfully\(attempt > 1 ? " (attempt \(attempt))" : ""), service creds \(hasServiceCredentials ? "SET" : "EMPTY")", category: .vpn, level: .success)
                } else {
                    lastError = "No private key in response. Token may not have NordLynx access."
                    logger.log("NordVPN: response missing nordlynx_private_key", category: .vpn, level: .error)
                }
                return
            } catch let retryError where isRetryableError(retryError) && attempt < maxRetryAttempts {
                logger.log("NordVPN: fetchPrivateKey transient error — retry \(attempt)/\(maxRetryAttempts)", category: .vpn, level: .warning)
                try? await Task.sleep(for: .seconds(retryBaseDelay * Double(attempt)))
                continue
            } catch let error as URLError where error.code == .timedOut {
                lastError = "Request timed out. Check your connection and try again."
                logger.logError("NordVPN: fetchPrivateKey timeout", error: error, category: .vpn)
                return
            } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
                lastError = "No internet connection."
                logger.logError("NordVPN: fetchPrivateKey no network", error: error, category: .vpn)
                return
            } catch {
                lastError = "Failed to fetch key: \(error.localizedDescription)"
                logger.logError("NordVPN: fetchPrivateKey network error", error: error, category: .vpn)
                return
            }
        }
    }

    var isTokenExpired: Bool = UserDefaults.standard.bool(forKey: "nordvpn_token_expired_v1") {
        didSet { UserDefaults.standard.set(isTokenExpired, forKey: "nordvpn_token_expired_v1") }
    }
    var isTestingToken: Bool = false
    var tokenTestResult: TokenTestResult?
    var isDownloadingOVPN: Bool = false
    var ovpnDownloadProgress: String = ""
    var isAutoPopulating: Bool = false
    var autoPopulateProgress: String = ""
    var autoPopulateError: String?

    func fetchRecommendedServers(country: String? = nil, limit: Int = 10, technology: String = "openvpn_tcp") async {
        isLoadingServers = true
        lastError = nil
        defer { isLoadingServers = false }

        var components = URLComponents(string: "https://api.nordvpn.com/v1/servers/recommendations")
        components?.queryItems = [
            URLQueryItem(name: "filters[servers_technologies][identifier]", value: technology),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        if let country = country {
            components?.queryItems?.append(URLQueryItem(name: "filters[country_id]", value: country))
        }

        guard let url = components?.url else {
            lastError = "Invalid API URL"
            return
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        for attempt in 1...maxRetryAttempts {
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse {
                    if isRetryableHTTPStatus(http.statusCode) && attempt < maxRetryAttempts {
                        logger.log("NordVPN: fetchServers HTTP \(http.statusCode) — retry \(attempt)/\(maxRetryAttempts)", category: .vpn, level: .warning)
                        try? await Task.sleep(for: .seconds(retryBaseDelay * Double(attempt)))
                        continue
                    }
                    switch http.statusCode {
                    case 200:
                        break
                    case 404:
                        lastError = "Server endpoint not found (HTTP 404). NordVPN API may have changed."
                        logger.log("NordVPN: fetchServers 404 — endpoint may be deprecated", category: .vpn, level: .error)
                        let cached = loadCachedServers()
                        if !cached.isEmpty {
                            recommendedServers = cached
                            lastError = (lastError ?? "") + " Using cached servers."
                        }
                        return
                    case 429:
                        lastError = "Rate limited by NordVPN. Wait a minute and try again."
                        logger.log("NordVPN: fetchServers rate limited", category: .vpn, level: .warning)
                        let cached = loadCachedServers()
                        if !cached.isEmpty {
                            recommendedServers = cached
                            lastError = (lastError ?? "") + " Using cached servers."
                        }
                        return
                    default:
                        lastError = "API returned HTTP \(http.statusCode)"
                        logger.log("NordVPN: fetchServers failed — HTTP \(http.statusCode)", category: .vpn, level: .error)
                        return
                    }
                }
                let servers = try JSONDecoder().decode([NordVPNServer].self, from: data)
                recommendedServers = servers
                lastFetched = Date()
                cacheServers(servers)
                logger.log("NordVPN: fetched \(servers.count) servers (tech: \(technology))\(attempt > 1 ? " (attempt \(attempt))" : "")", category: .vpn, level: .success)
                return
            } catch is DecodingError {
                lastError = "Failed to parse server response. API format may have changed."
                logger.log("NordVPN: server response decoding failed", category: .vpn, level: .error)
                let cached = loadCachedServers()
                if !cached.isEmpty {
                    recommendedServers = cached
                    lastError = (lastError ?? "") + " Using cached servers."
                }
                return
            } catch let retryError where isRetryableError(retryError) && attempt < maxRetryAttempts {
                logger.log("NordVPN: fetchServers transient error — retry \(attempt)/\(maxRetryAttempts)", category: .vpn, level: .warning)
                try? await Task.sleep(for: .seconds(retryBaseDelay * Double(attempt)))
                continue
            } catch let error as URLError where error.code == .timedOut {
                lastError = "Request timed out. Check your connection."
                let cached = loadCachedServers()
                if !cached.isEmpty {
                    recommendedServers = cached
                    lastError = (lastError ?? "") + " Using cached servers."
                }
                logger.logError("NordVPN: fetchServers timeout", error: error, category: .vpn)
                return
            } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
                lastError = "No internet connection."
                let cached = loadCachedServers()
                if !cached.isEmpty {
                    recommendedServers = cached
                    lastError = (lastError ?? "") + " Using cached servers."
                }
                logger.logError("NordVPN: fetchServers no network", error: error, category: .vpn)
                return
            } catch {
                let cached = loadCachedServers()
                if !cached.isEmpty {
                    recommendedServers = cached
                    lastFetched = Date()
                    lastError = "Using cached servers (API unavailable)"
                    logger.log("NordVPN: API failed, loaded \(cached.count) cached servers", category: .vpn, level: .warning)
                } else {
                    lastError = "Failed to fetch servers: \(error.localizedDescription)"
                    logger.logError("NordVPN: fetchServers error (no cache)", error: error, category: .vpn)
                }
                return
            }
        }
    }

    func downloadOVPNConfig(from server: NordVPNServer, proto: NordOVPNProto = .tcp) async -> OpenVPNConfig? {
        let downloadURL: URL?
        switch proto {
        case .tcp: downloadURL = server.tcpOVPNDownloadURL
        case .udp: downloadURL = server.udpOVPNDownloadURL
        }

        guard let url = downloadURL else {
            logger.log("NordVPN: no download URL for \(server.hostname) (\(proto.rawValue))", category: .vpn, level: .error)
            return nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                logger.log("NordVPN: OVPN download HTTP \(http.statusCode) for \(server.hostname)", category: .vpn, level: .error)
                return nil
            }
            guard let content = String(data: data, encoding: .utf8), !content.isEmpty else {
                logger.log("NordVPN: OVPN download empty/non-UTF8 for \(server.hostname)", category: .vpn, level: .error)
                return nil
            }
            let fileName = "\(server.hostname).\(proto == .tcp ? "tcp" : "udp").ovpn"
            let parsed = OpenVPNConfig.parse(fileName: fileName, content: content)
            if parsed != nil {
                logger.log("NordVPN: downloaded \(fileName) (\(data.count) bytes)", category: .vpn, level: .success)
            } else {
                logger.log("NordVPN: OVPN parse failed for \(fileName) (\(data.count) bytes)", category: .vpn, level: .error)
            }
            return parsed
        } catch {
            logger.logError("NordVPN: OVPN download error for \(server.hostname)", error: error, category: .vpn)
            return nil
        }
    }

    func downloadAllTCPConfigs(for servers: [NordVPNServer], target: ProxyRotationService.ProxyTarget) async -> (imported: Int, failed: Int) {
        isDownloadingOVPN = true
        ovpnDownloadProgress = "0/\(servers.count)"
        defer {
            isDownloadingOVPN = false
            ovpnDownloadProgress = ""
        }

        let proxyService = ProxyRotationService.shared
        var imported = 0
        var failed = 0

        for (index, server) in servers.enumerated() {
            ovpnDownloadProgress = "\(index + 1)/\(servers.count)"
            if let config = await downloadOVPNConfig(from: server, proto: .tcp) {
                proxyService.importVPNConfig(config, for: target)
                imported += 1
            } else {
                failed += 1
            }
        }

        return (imported, failed)
    }

    func fetchAndDownloadTCPServers(country: String? = nil, limit: Int = 10, target: ProxyRotationService.ProxyTarget) async -> (imported: Int, failed: Int) {
        await fetchRecommendedServers(country: country, limit: limit, technology: "openvpn_tcp")
        guard !recommendedServers.isEmpty else {
            return (0, 0)
        }
        return await downloadAllTCPConfigs(for: recommendedServers, target: target)
    }

    func ensureProfileNetworkPoolsReady() async -> Bool {
        let proxyService = ProxyRotationService.shared
        let nickCounts = proxyService.storageCounts(for: .nick)
        let poliCounts = proxyService.storageCounts(for: .poli)
        let seedVersion = UserDefaults.standard.string(forKey: profileStorageSeedKey)

        let needsRefresh = seedVersion != profileStorageSeedVersion
            || nickCounts.wireGuard != expectedWireGuardConfigCount
            || nickCounts.openVPN != expectedOpenVPNConfigCount
            || poliCounts.wireGuard != expectedWireGuardConfigCount
            || poliCounts.openVPN != expectedOpenVPNConfigCount

        guard needsRefresh else { return hasSelectedProfile }

        let originalProfile = activeKeyProfile
        let originalProfileRaw = UserDefaults.standard.string(forKey: keyProfilePersistKey)

        logger.log("NordVPN: rebuilding profile network pools in hard storage", category: .vpn, level: .info)

        for profile in NordKeyProfile.allCases {
            await rebuildNetworkPool(for: profile)
        }

        persistCurrentPrivateKey()
        let restoredProfile: NordKeyProfile?
        if let originalProfileRaw, let profileToRestore = NordKeyProfile(rawValue: originalProfileRaw) {
            restoredProfile = profileToRestore
            activateProfile(profileToRestore, persistSelection: true)
        } else {
            restoredProfile = nil
            activateProfile(originalProfile, persistSelection: false)
            UserDefaults.standard.removeObject(forKey: keyProfilePersistKey)
        }

        ProxyRotationService.shared.reloadForActiveProfile()
        NetworkSessionFactory.shared.resetRotationIndexes()
        DeviceProxyService.shared.handleProfileSwitch()
        UserDefaults.standard.set(profileStorageSeedVersion, forKey: profileStorageSeedKey)
        return restoredProfile != nil
    }

    private func rebuildNetworkPool(for profile: NordKeyProfile) async {
        persistCurrentPrivateKey()
        activateProfile(profile, persistSelection: true)

        let proxyService = ProxyRotationService.shared
        proxyService.clearUnifiedNetworkConfigs(for: profile)
        recommendedServers.removeAll()
        lastError = nil
        autoPopulateError = nil

        if privateKey.isEmpty {
            await fetchPrivateKey()
        }

        guard hasPrivateKey else {
            autoPopulateError = "Failed to fetch private key for \(profile.rawValue)."
            logger.log("NordVPN: profile pool rebuild aborted — no private key for \(profile.rawValue)", category: .vpn, level: .error)
            return
        }

        await fetchRecommendedServers(limit: expectedWireGuardConfigCount, technology: "wireguard_udp")
        let wireGuardConfigs = recommendedServers.prefix(expectedWireGuardConfigCount).compactMap { server in
            generateWireGuardConfig(from: server)
        }
        proxyService.replaceUnifiedWGConfigs(Array(wireGuardConfigs), for: profile)

        await fetchRecommendedServers(limit: expectedOpenVPNConfigCount, technology: "openvpn_tcp")
        var openVPNConfigs: [OpenVPNConfig] = []
        for server in recommendedServers.prefix(expectedOpenVPNConfigCount) {
            if let config = await downloadOVPNConfig(from: server, proto: .tcp) {
                openVPNConfigs.append(config)
            }
        }
        proxyService.replaceUnifiedVPNConfigs(openVPNConfigs, for: profile)

        logger.log("NordVPN: rebuilt \(profile.rawValue) storage — \(wireGuardConfigs.count) WG, \(openVPNConfigs.count) OVPN", category: .vpn, level: .success)
    }

    func generateWireGuardConfig(from server: NordVPNServer) -> WireGuardConfig? {
        guard let publicKey = server.publicKey, !publicKey.isEmpty else { return nil }
        guard hasPrivateKey else { return nil }

        let endpoint = "\(server.station):51820"
        let rawContent = "[Interface]\nPrivateKey = \(privateKey)\nAddress = 10.5.0.2/32\nDNS = 103.86.96.100, 103.86.99.100\n\n[Peer]\nPublicKey = \(publicKey)\nAllowedIPs = 0.0.0.0/0\nEndpoint = \(endpoint)\nPersistentKeepalive = 25"

        return WireGuardConfig(
            fileName: server.hostname,
            interfaceAddress: "10.5.0.2/32",
            interfacePrivateKey: privateKey,
            interfaceDNS: "103.86.96.100, 103.86.99.100",
            interfaceMTU: nil,
            peerPublicKey: publicKey,
            peerPreSharedKey: nil,
            peerEndpoint: endpoint,
            peerAllowedIPs: "0.0.0.0/0",
            peerPersistentKeepalive: 25,
            rawContent: rawContent
        )
    }

    func generateOpenVPNEndpoint(from server: NordVPNServer, proto: String = "tcp", port: Int = 443) -> OpenVPNConfig {
        let rawContent = "client\ndev tun\nproto \(proto)\nremote \(server.hostname) \(port)\nresolv-retry infinite\nnobind\npersist-key\npersist-tun\nremote-cert-tls server\ncipher AES-256-GCM\nauth SHA512\nverb 3"

        return OpenVPNConfig(
            fileName: server.hostname,
            remoteHost: server.hostname,
            remotePort: port,
            proto: proto,
            rawContent: rawContent
        )
    }

    func fetchRecommendedServers(countryId: Int, technology: String, limit: Int = 3) async -> [NordVPNServer] {
        var components = URLComponents(string: "https://api.nordvpn.com/v1/servers/recommendations")
        components?.queryItems = [
            URLQueryItem(name: "filters[servers_technologies][identifier]", value: technology),
            URLQueryItem(name: "filters[country_id]", value: "\(countryId)"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]

        guard let url = components?.url else { return [] }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                logger.log("NordVPN: fetch \(technology) HTTP \(http.statusCode) for country \(countryId)", category: .vpn, level: .warning)
                return []
            }
            let servers = try JSONDecoder().decode([NordVPNServer].self, from: data)
            logger.log("NordVPN: fetched \(servers.count) \(technology) servers for country \(countryId)", category: .vpn, level: .success)
            return servers
        } catch {
            logger.log("NordVPN: fetch \(technology) failed for country \(countryId) — \(error.localizedDescription)", category: .vpn, level: .warning)
            return []
        }
    }

    func fetchSOCKS5Servers(countryId: Int, limit: Int = 3) async -> [NordVPNServer] {
        var components = URLComponents(string: "https://api.nordvpn.com/v1/servers/recommendations")
        components?.queryItems = [
            URLQueryItem(name: "filters[servers_technologies][identifier]", value: "socks"),
            URLQueryItem(name: "filters[country_id]", value: "\(countryId)"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]

        guard let url = components?.url else { return [] }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                logger.log("NordVPN: SOCKS5 fetch HTTP \(http.statusCode) for country \(countryId)", category: .vpn, level: .warning)
                return []
            }
            let servers = try JSONDecoder().decode([NordVPNServer].self, from: data)
            logger.log("NordVPN: fetched \(servers.count) SOCKS5 servers for country \(countryId)", category: .vpn, level: .success)
            return servers
        } catch {
            logger.log("NordVPN: SOCKS5 fetch failed for country \(countryId) — \(error.localizedDescription)", category: .vpn, level: .warning)
            return []
        }
    }

    // MARK: - Auto-Populate Configs

    func autoPopulateConfigs(forceRefresh: Bool = false) async {
        let proxyService = ProxyRotationService.shared
        let profileAtStart = activeKeyProfile
        let hasWG = !proxyService.joeWGConfigs.isEmpty
        let hasOVPN = !proxyService.joeVPNConfigs.isEmpty

        if !forceRefresh && hasWG && hasOVPN {
            logger.log("NordVPN: auto-populate skipped for \(profileAtStart.rawValue) — configs exist (WG: \(proxyService.joeWGConfigs.count), OVPN: \(proxyService.joeVPNConfigs.count))", category: .vpn, level: .info)
            return
        }

        guard !isAutoPopulating else {
            logger.log("NordVPN: auto-populate already in progress", category: .vpn, level: .warning)
            return
        }

        isAutoPopulating = true
        autoPopulateProgress = "[\(profileAtStart.rawValue)] Fetching private key..."
        autoPopulateError = nil
        defer {
            isAutoPopulating = false
            autoPopulateProgress = ""
        }

        guard activeKeyProfile == profileAtStart else {
            logger.log("NordVPN: auto-populate aborted — profile changed during setup", category: .vpn, level: .warning)
            return
        }

        if privateKey.isEmpty {
            await fetchPrivateKey()
            guard hasPrivateKey else {
                autoPopulateError = "Failed to fetch private key for \(profileAtStart.rawValue)."
                logger.log("NordVPN: auto-populate aborted — no private key for \(profileAtStart.rawValue)", category: .vpn, level: .error)
                return
            }
        }

        guard activeKeyProfile == profileAtStart else {
            logger.log("NordVPN: auto-populate aborted — profile switched mid-fetch", category: .vpn, level: .warning)
            return
        }

        let wgCount = expectedWireGuardConfigCount
        let ovpnCount = expectedOpenVPNConfigCount

        autoPopulateProgress = "[\(profileAtStart.rawValue)] Fetching WireGuard servers..."
        logger.log("NordVPN: auto-populate starting — \(wgCount) WG + \(ovpnCount) OVPN for \(profileAtStart.rawValue) (key: \(accessKey.prefix(8))...)", category: .vpn, level: .info)

        if forceRefresh || !hasWG {
            await fetchRecommendedServers(limit: wgCount, technology: "wireguard_udp")

            guard activeKeyProfile == profileAtStart else {
                logger.log("NordVPN: auto-populate aborted — profile switched during WG fetch", category: .vpn, level: .warning)
                return
            }

            let wgServers = recommendedServers

            if wgServers.isEmpty {
                autoPopulateError = "No WireGuard servers found."
                logger.log("NordVPN: auto-populate — no WG servers returned", category: .vpn, level: .error)
            } else {
                var wgConfigs: [WireGuardConfig] = []
                for (index, server) in wgServers.enumerated() {
                    autoPopulateProgress = "[\(profileAtStart.rawValue)] WG \(index + 1)/\(wgServers.count)..."
                    if let config = generateWireGuardConfig(from: server) {
                        wgConfigs.append(config)
                    }
                }

                if !wgConfigs.isEmpty {
                    if forceRefresh {
                        proxyService.clearAllUnifiedWGConfigs()
                    }
                    let report = proxyService.importUnifiedWGConfigs(wgConfigs)
                    logger.log("NordVPN: [\(profileAtStart.rawValue)] WG — added \(report.added), duplicates \(report.duplicates)", category: .vpn, level: .success)
                }
            }
        }

        guard activeKeyProfile == profileAtStart else {
            logger.log("NordVPN: auto-populate aborted — profile switched before OVPN phase", category: .vpn, level: .warning)
            return
        }

        if forceRefresh || !hasOVPN {
            autoPopulateProgress = "[\(profileAtStart.rawValue)] Fetching OpenVPN servers..."
            await fetchRecommendedServers(limit: ovpnCount, technology: "openvpn_tcp")

            guard activeKeyProfile == profileAtStart else {
                logger.log("NordVPN: auto-populate aborted — profile switched during OVPN fetch", category: .vpn, level: .warning)
                return
            }

            let ovpnServers = recommendedServers

            if ovpnServers.isEmpty {
                let existingError = autoPopulateError ?? ""
                autoPopulateError = existingError.isEmpty ? "No OpenVPN servers found." : existingError + " No OpenVPN servers found."
                logger.log("NordVPN: auto-populate — no OVPN servers returned", category: .vpn, level: .error)
            } else {
                var importedOVPN = 0
                var failedOVPN = 0

                for (index, server) in ovpnServers.enumerated() {
                    guard activeKeyProfile == profileAtStart else {
                        logger.log("NordVPN: auto-populate aborted — profile switched during OVPN download", category: .vpn, level: .warning)
                        return
                    }
                    autoPopulateProgress = "[\(profileAtStart.rawValue)] OVPN \(index + 1)/\(ovpnServers.count)..."
                    if let config = await downloadOVPNConfig(from: server, proto: .tcp) {
                        proxyService.importUnifiedVPNConfig(config)
                        importedOVPN += 1
                    } else {
                        failedOVPN += 1
                    }
                }

                logger.log("NordVPN: [\(profileAtStart.rawValue)] OVPN — imported \(importedOVPN), failed \(failedOVPN)", category: .vpn, level: importedOVPN > 0 ? .success : .error)
            }
        }

        let finalWG = proxyService.joeWGConfigs.count
        let finalOVPN = proxyService.joeVPNConfigs.count
        autoPopulateProgress = "[\(profileAtStart.rawValue)] Done — \(finalWG) WG, \(finalOVPN) OVPN"
        logger.log("NordVPN: auto-populate complete for \(profileAtStart.rawValue) — \(finalWG) WG, \(finalOVPN) OVPN configs ready", category: .vpn, level: .success)
    }

    private func cacheServers(_ servers: [NordVPNServer]) {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: serverCacheKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: serverCacheTimestampKey)
        }
    }

    private func loadCachedServers() -> [NordVPNServer] {
        let ts = UserDefaults.standard.double(forKey: serverCacheTimestampKey)
        guard ts > 0 else { return [] }
        let age = Date().timeIntervalSince1970 - ts
        guard age < serverCacheMaxAge else { return [] }
        guard let data = UserDefaults.standard.data(forKey: serverCacheKey) else { return [] }
        return (try? JSONDecoder().decode([NordVPNServer].self, from: data)) ?? []
    }
}

nonisolated enum NordOVPNProto: String, Sendable {
    case tcp
    case udp
}
