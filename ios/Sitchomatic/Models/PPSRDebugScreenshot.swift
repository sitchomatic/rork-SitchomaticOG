import Foundation
import Observation
import UIKit

nonisolated enum UserResultOverride: String, Sendable {
    case none
    case markedPass
    case markedFail
}

@Observable
class PPSRDebugScreenshot: Identifiable {
    let id: String
    let timestamp: Date
    let stepName: String
    let cardDisplayNumber: String
    let cardId: String
    let vin: String
    let email: String
    let image: UIImage
    var croppedImage: UIImage?
    var note: String
    var autoDetectedResult: AutoDetectedResult = .unknown
    var userOverride: UserResultOverride = .none
    var userNote: String = ""

    nonisolated enum AutoDetectedResult: String, Sendable {
        case pass
        case fail
        case unknown
    }

    var albumKey: String {
        "\(cardId.isEmpty ? cardDisplayNumber : cardId)"
    }

    var albumTitle: String {
        cardDisplayNumber
    }

    var effectiveResult: UserResultOverride {
        if userOverride != .none { return userOverride }
        switch autoDetectedResult {
        case .pass: return .markedPass
        case .fail: return .markedFail
        case .unknown: return .none
        }
    }

    var displayImage: UIImage {
        croppedImage ?? image
    }

    init(stepName: String, cardDisplayNumber: String, cardId: String = "", vin: String, email: String = "", image: UIImage, croppedImage: UIImage? = nil, note: String = "", autoDetectedResult: AutoDetectedResult = .unknown) {
        self.id = UUID().uuidString
        self.timestamp = Date()
        self.stepName = stepName
        self.cardDisplayNumber = cardDisplayNumber
        self.cardId = cardId
        self.vin = vin
        self.email = email
        self.image = image
        self.croppedImage = croppedImage
        self.note = note
        self.autoDetectedResult = autoDetectedResult
    }

    var formattedTime: String {
        DateFormatters.timeOnly.string(from: timestamp)
    }

    var hasUserOverride: Bool {
        userOverride != .none
    }

    var overrideLabel: String {
        switch userOverride {
        case .none: "Auto"
        case .markedPass: "Marked Pass"
        case .markedFail: "Marked Fail"
        }
    }
}
