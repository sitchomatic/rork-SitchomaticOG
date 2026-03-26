import Foundation

nonisolated enum PPSRCheckStatus: String, Sendable, CaseIterable, Identifiable {
    case queued = "Queued"
    case fillingVIN = "Filling VIN"
    case submittingSearch = "Submitting Search"
    case processingResults = "Processing Results"
    case enteringPayment = "Entering Payment"
    case processingPayment = "Processing Payment"
    case confirmingReport = "Confirming Report"
    case completed = "Completed"
    case failed = "Failed"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .queued: "clock"
        case .fillingVIN: "text.cursor"
        case .submittingSearch: "magnifyingglass"
        case .processingResults: "doc.text.magnifyingglass"
        case .enteringPayment: "creditcard"
        case .processingPayment: "arrow.triangle.2.circlepath"
        case .confirmingReport: "checkmark.seal"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    var isTerminal: Bool {
        self == .completed || self == .failed
    }

    var progress: Double {
        switch self {
        case .queued: 0.0
        case .fillingVIN: 0.15
        case .submittingSearch: 0.30
        case .processingResults: 0.45
        case .enteringPayment: 0.60
        case .processingPayment: 0.75
        case .confirmingReport: 0.90
        case .completed: 1.0
        case .failed: 0.0
        }
    }
}
