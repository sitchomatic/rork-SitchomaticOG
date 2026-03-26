import Foundation
import Observation
import UIKit
import SwiftUI

nonisolated enum UserResultOverride: String, Sendable, CaseIterable {
    case none
    case success
    case noAcc
    case permDisabled
    case tempDisabled
    case unsure

    var displayLabel: String {
        switch self {
        case .none: "Auto"
        case .success: "Success"
        case .noAcc: "No Acc"
        case .permDisabled: "Perm Disabled"
        case .tempDisabled: "Temp Disabled"
        case .unsure: "Unsure"
        }
    }

    var color: SwiftUI.Color {
        switch self {
        case .none: .gray
        case .success: .green
        case .noAcc: .secondary
        case .permDisabled: .red
        case .tempDisabled: .orange
        case .unsure: .yellow
        }
    }

    var icon: String {
        switch self {
        case .none: "questionmark.circle"
        case .success: "checkmark.circle.fill"
        case .noAcc: "xmark.circle.fill"
        case .permDisabled: "lock.slash.fill"
        case .tempDisabled: "clock.badge.exclamationmark"
        case .unsure: "questionmark.diamond.fill"
        }
    }

    static var overrideable: [UserResultOverride] {
        [.success, .noAcc, .permDisabled, .tempDisabled, .unsure]
    }
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
    var site: String = ""
    var autoDetectedResult: AutoDetectedResult = .unknown
    var userOverride: UserResultOverride = .none
    var userNote: String = ""
    var correctionReason: String = ""

    nonisolated enum AutoDetectedResult: String, Sendable {
        case success
        case noAcc
        case permDisabled
        case tempDisabled
        case unsure
        case unknown

        var displayLabel: String {
            switch self {
            case .success: "Success"
            case .noAcc: "No Acc"
            case .permDisabled: "Perm Disabled"
            case .tempDisabled: "Temp Disabled"
            case .unsure: "Unsure"
            case .unknown: "Unknown"
            }
        }

        var toOverride: UserResultOverride {
            switch self {
            case .success: .success
            case .noAcc: .noAcc
            case .permDisabled: .permDisabled
            case .tempDisabled: .tempDisabled
            case .unsure: .unsure
            case .unknown: .none
            }
        }
    }

    var albumKey: String {
        "\(cardId.isEmpty ? cardDisplayNumber : cardId)"
    }

    var albumTitle: String {
        cardDisplayNumber
    }

    var effectiveResult: UserResultOverride {
        if userOverride != .none { return userOverride }
        return autoDetectedResult.toOverride
    }

    var displayImage: UIImage {
        croppedImage ?? image
    }

    var isJoe: Bool { site.lowercased().contains("joe") }
    var isIgnition: Bool { site.lowercased().contains("ign") }
    var siteLabel: String { isJoe ? "Joe" : isIgnition ? "Ignition" : "Unknown" }
    var siteIcon: String { isJoe ? "suit.spade.fill" : isIgnition ? "flame.fill" : "globe" }
    var siteColor: SwiftUI.Color { isJoe ? .green : isIgnition ? .orange : .gray }

    init(stepName: String, cardDisplayNumber: String, cardId: String = "", vin: String, email: String = "", image: UIImage, croppedImage: UIImage? = nil, note: String = "", site: String = "", autoDetectedResult: AutoDetectedResult = .unknown) {
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
        self.site = site
        self.autoDetectedResult = autoDetectedResult
    }

    var formattedTime: String {
        DateFormatters.timeOnly.string(from: timestamp)
    }

    var hasUserOverride: Bool {
        userOverride != .none
    }

    var overrideLabel: String {
        userOverride == .none ? "Auto" : "Override: \(userOverride.displayLabel)"
    }
}
