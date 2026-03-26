import Foundation

nonisolated enum TestGateway: String, CaseIterable, Identifiable, Sendable, Codable {
    case ppsr = "PPSR"
    case bpoint = "BPoint"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ppsr: "PPSR CarCheck"
        case .bpoint: "BPoint Gov"
        }
    }

    var subtitle: String {
        switch self {
        case .ppsr: "VIN + $2 charge"
        case .bpoint: "Variable charge"
        }
    }

    var icon: String {
        switch self {
        case .ppsr: "car.side.fill"
        case .bpoint: "building.columns.fill"
        }
    }

    var color: String {
        switch self {
        case .ppsr: "teal"
        case .bpoint: "indigo"
        }
    }

    var baseURL: String {
        switch self {
        case .ppsr: "https://transact.ppsr.gov.au/CarCheck/"
        case .bpoint: "https://www.bpoint.com.au/payments/DepartmentOfFinance"
        }
    }

    var requiresVIN: Bool { self == .ppsr }
    var requiresEmail: Bool { self == .ppsr }
    var requiresChargeAmount: Bool { self == .bpoint }
}

nonisolated enum ChargeAmountTier: String, CaseIterable, Identifiable, Sendable, Codable {
    case low = "$100"
    case medium = "$200"
    case high = "$500"

    var id: String { rawValue }

    var baseAmount: Double {
        switch self {
        case .low: 100.0
        case .medium: 200.0
        case .high: 500.0
        }
    }

    var variance: Double { 10.0 }

    func randomizedAmount() -> Double {
        let offset = Double.random(in: -variance...variance)
        return (baseAmount + offset).rounded(toPlaces: 2)
    }

    var displayRange: String {
        let lo = Int(baseAmount - variance)
        let hi = Int(baseAmount + variance)
        return "$\(lo)–$\(hi)"
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let multiplier = pow(10.0, Double(places))
        return (self * multiplier).rounded() / multiplier
    }
}
