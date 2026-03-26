import Foundation

nonisolated struct NordLynxCountryResponse: Codable, Sendable, Identifiable {
    let id: Int
    let name: String
    let code: String
    let cities: [CityResponse]?

    nonisolated struct CityResponse: Codable, Sendable, Identifiable {
        let id: Int
        let name: String
        let dnsName: String?
        let hubScore: Int?
    }
}
