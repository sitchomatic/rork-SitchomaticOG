import Foundation

nonisolated struct BINAPIResponse: Codable, Sendable {
    let valid: Bool?
    let card: BINCardInfo?
    let issuer: BINIssuerInfo?
    let country: BINCountryInfo?
}

nonisolated struct BINCardInfo: Codable, Sendable {
    let bin: String?
    let scheme: String?
    let type: String?
    let category: String?
}

nonisolated struct BINIssuerInfo: Codable, Sendable {
    let name: String?
    let url: String?
    let tel: String?
}

nonisolated struct BINCountryInfo: Codable, Sendable {
    let name: String?
    let alpha_2_code: String?
}

actor BINLookupService {
    static let shared = BINLookupService()
    private var cache: [String: PPSRBINData] = [:]
    private var inFlight: [String: Task<PPSRBINData, Never>] = [:]

    private let lookupURLs: [String] = [
        "https://api.freebinchecker.com/bin/",
        "https://lookup.binlist.net/",
    ]

    func lookup(bin: String) async -> PPSRBINData {
        let prefix = String(bin.prefix(6))
        if let cached = cache[prefix] {
            return cached
        }

        if let existing = inFlight[prefix] {
            return await existing.value
        }

        let task = Task<PPSRBINData, Never> {
            var data = PPSRBINData(bin: prefix)

            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 10
            config.waitsForConnectivity = false
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }

            for baseURL in lookupURLs {
                guard let url = URL(string: "\(baseURL)\(prefix)") else { continue }

                do {
                    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8)
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    let (responseData, response) = try await session.data(for: request)

                    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200, !responseData.isEmpty else {
                        continue
                    }

                    let decoded = try JSONDecoder().decode(BINAPIResponse.self, from: responseData)

                    data = PPSRBINData(
                        bin: prefix,
                        scheme: decoded.card?.scheme ?? "",
                        type: decoded.card?.type ?? "",
                        category: decoded.card?.category ?? "",
                        issuer: decoded.issuer?.name ?? "",
                        country: decoded.country?.name ?? "",
                        countryCode: decoded.country?.alpha_2_code ?? "",
                        isLoaded: true
                    )

                    return data
                } catch {
                    continue
                }
            }

            return data
        }

        inFlight[prefix] = task
        let result = await task.value
        cache[prefix] = result
        inFlight.removeValue(forKey: prefix)
        return result
    }
}
