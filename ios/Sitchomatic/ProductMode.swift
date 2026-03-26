import SwiftUI

nonisolated enum ProductMode: String, CaseIterable, Sendable {
    case ppsr = "PPSR CarCheck"

    var title: String { rawValue }

    var isLoginMode: Bool { false }

    var baseURL: String {
        switch self {
        case .ppsr: return "https://transact.ppsr.gov.au/CarCheck/"
        }
    }
}
