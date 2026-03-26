import Foundation

nonisolated struct NordLynxGeneratedConfig: Identifiable, Sendable {
    let id = UUID()
    let hostname: String
    let stationIP: String
    let publicKey: String
    let fileContent: String
    let fileName: String
    let countryName: String
    let countryCode: String
    let cityName: String
    let serverLoad: Int
    let vpnProtocol: NordLynxVPNProtocol
    let port: Int
}
