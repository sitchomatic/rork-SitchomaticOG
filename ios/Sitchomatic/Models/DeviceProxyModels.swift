import Foundation

nonisolated enum RotationInterval: String, CaseIterable, Codable, Sendable {
    case everyBatch = "Every Batch"
    case every1Min = "Every 1 Minute"
    case every3Min = "Every 3 Minutes"
    case every5Min = "Every 5 Minutes"
    case every7Min = "Every 7 Minutes"
    case every10Min = "Every 10 Minutes"
    case every15Min = "Every 15 Minutes"

    var seconds: TimeInterval? {
        switch self {
        case .everyBatch: nil
        case .every1Min: 60
        case .every3Min: 180
        case .every5Min: 300
        case .every7Min: 420
        case .every10Min: 600
        case .every15Min: 900
        }
    }

    var label: String { rawValue }

    var icon: String {
        switch self {
        case .everyBatch: "arrow.triangle.2.circlepath"
        case .every1Min: "1.circle.fill"
        case .every3Min: "3.circle.fill"
        case .every5Min: "5.circle.fill"
        case .every7Min: "7.circle.fill"
        case .every10Min: "10.circle.fill"
        case .every15Min: "15.circle.fill"
        }
    }
}

nonisolated enum IPRoutingMode: String, CaseIterable, Codable, Sendable {
    case separatePerSession = "Separate IP per Session"
    case appWideUnited = "App-Wide United IP"

    var label: String { rawValue }

    var icon: String {
        switch self {
        case .separatePerSession: "arrow.triangle.branch"
        case .appWideUnited: "shield.checkered"
        }
    }

    var shortLabel: String {
        switch self {
        case .separatePerSession: "Per-Session"
        case .appWideUnited: "United IP"
        }
    }
}

nonisolated struct RotationLogEntry: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let fromLabel: String
    let toLabel: String
    let reason: String

    init(id: UUID = UUID(), timestamp: Date = Date(), fromLabel: String, toLabel: String, reason: String) {
        self.id = id
        self.timestamp = timestamp
        self.fromLabel = fromLabel
        self.toLabel = toLabel
        self.reason = reason
    }
}
