import Foundation

nonisolated struct NordLynxServerResponse: Codable, Sendable {
    let id: Int
    let name: String
    let hostname: String
    let station: String
    let load: Int
    let technologies: [Technology]?
    let locations: [ServerLocation]?
    let flag: String?

    nonisolated struct Technology: Codable, Sendable {
        let identifier: String
        let metadata: [Metadata]?
    }

    nonisolated struct Metadata: Codable, Sendable {
        let name: String
        let value: String
    }

    nonisolated struct ServerLocation: Codable, Sendable {
        let country: Country?
    }

    nonisolated struct Country: Codable, Sendable {
        let name: String
        let code: String
        let city: City?
    }

    nonisolated struct City: Codable, Sendable {
        let name: String
    }
}
