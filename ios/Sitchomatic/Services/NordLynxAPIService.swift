import Foundation

nonisolated enum NordLynxAPIError: Error, LocalizedError, Sendable {
    case invalidURL
    case networkError(Int)
    case connectionFailed(String)
    case decodingError(String)
    case noServersFound
    case noPublicKey(String)
    case timeout
    case ovpnDownloadFailed(String)
    case allRetriesFailed(Int)
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid API URL."
        case .networkError(let statusCode):
            "Server returned HTTP \(statusCode). Try again later."
        case .connectionFailed(let reason):
            "Connection failed: \(reason)"
        case .decodingError(let detail):
            "Failed to parse server data: \(detail)"
        case .noServersFound:
            "No servers returned. Try fewer configs or a different filter."
        case .noPublicKey(let hostname):
            "No WireGuard key found for \(hostname)."
        case .timeout:
            "Request timed out. Check your connection."
        case .ovpnDownloadFailed(let hostname):
            "Failed to download OpenVPN config for \(hostname)."
        case .allRetriesFailed(let attempts):
            "All \(attempts) retry attempts failed. Check your connection."
        case .rateLimited:
            "Rate limited by NordVPN API. Please wait and try again."
        }
    }
}

nonisolated struct NordLynxAPIService: Sendable {
    private static let baseURL = "https://api.nordvpn.com/v1/servers/recommendations"
    private static let countriesURL = "https://api.nordvpn.com/v1/servers/countries"
    private static let ovpnBaseURL = "https://downloads.nordcdn.com/configs/files"

    private static let maxRetries = 3
    private static let retryBaseDelay: TimeInterval = 1.0

    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private var session: URLSession { Self.sharedSession }

    func fetchCountries() async throws -> [NordLynxCountryResponse] {
        guard let url = URL(string: Self.countriesURL) else {
            throw NordLynxAPIError.invalidURL
        }

        let data = try await performRequestWithRetry(url: url)

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            var countries = try decoder.decode([NordLynxCountryResponse].self, from: data)
            countries.sort { $0.name < $1.name }
            return countries
        } catch let error as DecodingError {
            throw NordLynxAPIError.decodingError(decodingDetail(error))
        }
    }

    func fetchServers(limit: Int, countryId: Int? = nil, vpnProtocol: NordLynxVPNProtocol = .wireguardUDP) async throws -> [NordLynxServerResponse] {
        let clampedLimit = max(1, min(50, limit))
        var components = URLComponents(string: Self.baseURL)
        components?.queryItems = [
            URLQueryItem(name: "limit", value: "\(clampedLimit)"),
            URLQueryItem(name: "filters[servers_technologies][identifier]", value: vpnProtocol.rawValue)
        ]
        if let countryId {
            components?.queryItems?.append(URLQueryItem(name: "filters[country_id]", value: "\(countryId)"))
        }

        guard let url = components?.url else {
            throw NordLynxAPIError.invalidURL
        }

        let data = try await performRequestWithRetry(url: url)

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode([NordLynxServerResponse].self, from: data)
        } catch let error as DecodingError {
            throw NordLynxAPIError.decodingError(decodingDetail(error))
        }
    }

    func downloadOVPNConfig(hostname: String, vpnProtocol: NordLynxVPNProtocol) async throws -> String {
        let suffix = vpnProtocol == .openvpnTCP ? "tcp" : "udp"
        let urlString = "\(Self.ovpnBaseURL)/\(vpnProtocol.ovpnConfigPath)/servers/\(hostname).\(suffix).ovpn"

        guard let url = URL(string: urlString) else {
            throw NordLynxAPIError.invalidURL
        }

        let data = try await performRequestWithRetry(url: url)

        guard let content = String(data: data, encoding: .utf8), !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NordLynxAPIError.ovpnDownloadFailed(hostname)
        }

        return content
    }

    private func performRequestWithRetry(url: URL) async throws -> Data {
        var lastError: (any Error)?

        for attempt in 0..<Self.maxRetries {
            try Task.checkCancellation()

            do {
                let (data, response) = try await performRequest(url: url)
                try validateResponse(response)

                guard !data.isEmpty else {
                    throw NordLynxAPIError.connectionFailed("Empty response body.")
                }

                return data
            } catch let error as NordLynxAPIError where isRetryable(error) {
                lastError = error
                if attempt < Self.maxRetries - 1 {
                    let delay = Self.retryBaseDelay * pow(2.0, Double(attempt))
                    let jitter = Double.random(in: 0...0.5)
                    try await Task.sleep(for: .seconds(delay + jitter))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw error
            }
        }

        if let lastError {
            throw lastError
        }
        throw NordLynxAPIError.allRetriesFailed(Self.maxRetries)
    }

    private func isRetryable(_ error: NordLynxAPIError) -> Bool {
        switch error {
        case .timeout, .rateLimited:
            true
        case .networkError(let code):
            code == 429 || code >= 500
        case .connectionFailed(let reason):
            !reason.contains("expired") && !reason.contains("denied") && !reason.contains("not found")
        default:
            false
        }
    }

    private func performRequest(url: URL) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(from: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw NordLynxAPIError.timeout
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw NordLynxAPIError.connectionFailed("No internet connection.")
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw NordLynxAPIError.connectionFailed(error.localizedDescription)
        }
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NordLynxAPIError.connectionFailed("Invalid response type.")
        }
        switch httpResponse.statusCode {
        case 200...299:
            return
        case 401:
            throw NordLynxAPIError.connectionFailed("Access token expired or invalid. Generate a new token from NordVPN dashboard → Manual Setup.")
        case 403:
            throw NordLynxAPIError.connectionFailed("Access denied. Subscription may have expired or token lacks permissions.")
        case 404:
            throw NordLynxAPIError.connectionFailed("Endpoint not found (404). NordVPN API may have changed.")
        case 429:
            throw NordLynxAPIError.rateLimited
        default:
            throw NordLynxAPIError.networkError(httpResponse.statusCode)
        }
    }

    private func decodingDetail(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _):
            "Missing key: \(key.stringValue)"
        case .typeMismatch(let type, let context):
            "Type mismatch for \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .dataCorrupted(let context):
            "Corrupted data at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        default:
            error.localizedDescription
        }
    }
}
