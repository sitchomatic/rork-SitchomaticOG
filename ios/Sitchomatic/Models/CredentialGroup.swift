import Foundation
import SwiftUI

nonisolated enum GroupColor: String, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        }
    }

    var label: String { rawValue.capitalized }
}

nonisolated enum GroupSize: Int, CaseIterable, Sendable {
    case twenty = 20
    case fifty = 50
    case hundred = 100
    case twoHundred = 200
    case threeHundred = 300
    case fiveHundred = 500

    var label: String { "\(rawValue)" }
}

nonisolated struct CredentialGroup: Identifiable, Codable, Sendable {
    let id: String
    var name: String
    var color: GroupColor
    var credentialIds: [String]
    var createdAt: Date

    var count: Int { credentialIds.count }

    init(id: String = UUID().uuidString, name: String, color: GroupColor, credentialIds: [String] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.color = color
        self.credentialIds = credentialIds
        self.createdAt = createdAt
    }
}
