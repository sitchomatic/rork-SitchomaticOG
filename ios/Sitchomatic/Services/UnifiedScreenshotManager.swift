import Foundation
import Observation
import UIKit
import SwiftUI

@Observable
@MainActor
class UnifiedScreenshotManager {
    static let shared = UnifiedScreenshotManager()

    var screenshots: [UnifiedScreenshot] = []
    var analysisStats: AnalysisStats = AnalysisStats()
    private let maxScreenshots: Int = 300
    private let visionCrop = VisionTextCropService.shared
    private let dedup = ScreenshotDedupService.shared
    private let logger = DebugLogger.shared

    struct AnalysisStats {
        var totalCaptured: Int = 0
        var totalAnalyzed: Int = 0
        var duplicatesSkipped: Int = 0
        var crucialDetections: Int = 0
        var smartCrops: Int = 0
        var outcomeBreakdown: [String: Int] = [:]
    }

    func addScreenshot(
        image: UIImage,
        sessionId: String,
        credentialEmail: String,
        site: String,
        step: ScreenshotStep,
        attemptNumber: Int,
        runVisionAnalysis: Bool = true
    ) async {
        analysisStats.totalCaptured += 1

        if dedup.isDuplicate(image) {
            analysisStats.duplicatesSkipped += 1
            logger.log("UnifiedScreenshots: duplicate skipped for \(credentialEmail) step=\(step.rawValue)", category: .screenshot, level: .trace)
            return
        }

        let compressed = compressImage(image)

        var analysis: VisionTextCropService.AnalysisResult?
        var cropResult: VisionTextCropService.CropResult?

        if runVisionAnalysis {
            analysisStats.totalAnalyzed += 1
            let analysisValue = await visionCrop.analyzeScreenshot(compressed)
            analysis = analysisValue

            if !analysisValue.crucialMatches.isEmpty {
                analysisStats.crucialDetections += 1
                let crop = await visionCrop.smartCrop(compressed, analysis: analysisValue)
                cropResult = crop
                if crop.cropRect != .zero {
                    analysisStats.smartCrops += 1
                }
            }

            let outcomeKey = analysisValue.detectedOutcome.rawValue
            analysisStats.outcomeBreakdown[outcomeKey, default: 0] += 1
        }

        let screenshot = UnifiedScreenshot(
            sessionId: sessionId,
            credentialEmail: credentialEmail,
            site: site,
            step: step,
            attemptNumber: attemptNumber,
            fullImage: compressed,
            croppedImage: cropResult?.croppedImage,
            detectedOutcome: analysis?.detectedOutcome ?? .unknown,
            crucialKeywords: analysis?.crucialMatches ?? [],
            allDetectedText: analysis?.allText ?? "",
            visionConfidence: analysis?.confidence ?? 0,
            analysisTimeMs: analysis?.processingTimeMs ?? 0
        )

        screenshots.insert(screenshot, at: 0)

        if screenshots.count > maxScreenshots {
            let overflow = screenshots.count - maxScreenshots
            screenshots.removeLast(overflow)
        }

        let crucialInfo = analysis?.crucialMatches.isEmpty == false ? " CRUCIAL:\(analysis!.crucialMatches.joined(separator: ","))" : ""
        logger.log("UnifiedScreenshots: captured \(step.rawValue) for \(credentialEmail) site=\(site) attempt=\(attemptNumber)\(crucialInfo)", category: .screenshot, level: crucialInfo.isEmpty ? .debug : .info)
    }

    func screenshotsForSession(_ sessionId: String) -> [UnifiedScreenshot] {
        screenshots.filter { $0.sessionId == sessionId }
    }

    func screenshotsForCredential(_ email: String) -> [UnifiedScreenshot] {
        screenshots.filter { $0.credentialEmail == email }
    }

    func crucialScreenshots() -> [UnifiedScreenshot] {
        screenshots.filter { !$0.crucialKeywords.isEmpty }
    }

    func screenshotsBySite(_ site: String) -> [UnifiedScreenshot] {
        screenshots.filter { $0.site == site }
    }

    func clearAll() {
        let count = screenshots.count
        screenshots.removeAll()
        dedup.resetAll()
        analysisStats = AnalysisStats()
        logger.log("UnifiedScreenshots: cleared \(count) screenshots", category: .screenshot, level: .info)
    }

    func clearForSession(_ sessionId: String) {
        screenshots.removeAll { $0.sessionId == sessionId }
    }

    func handleMemoryPressure() {
        let keep = min(screenshots.count, 100)
        if screenshots.count > keep {
            screenshots = Array(screenshots.prefix(keep))
        }
    }

    private func compressImage(_ image: UIImage) -> UIImage {
        if let jpegData = image.jpegData(compressionQuality: 0.4), let compressed = UIImage(data: jpegData) {
            return compressed
        }
        return image
    }
}

@Observable
class UnifiedScreenshot: Identifiable {
    let id: String
    let timestamp: Date
    let sessionId: String
    let credentialEmail: String
    let site: String
    let step: ScreenshotStep
    let attemptNumber: Int
    let fullImage: UIImage
    let croppedImage: UIImage?
    let detectedOutcome: VisionTextCropService.DetectedOutcome
    let crucialKeywords: [String]
    let allDetectedText: String
    let visionConfidence: Double
    let analysisTimeMs: Int
    var userOverride: UserResultOverride = .none

    var displayImage: UIImage {
        croppedImage ?? fullImage
    }

    var hasCrop: Bool {
        croppedImage != nil
    }

    var isCrucial: Bool {
        !crucialKeywords.isEmpty
    }

    var outcomeColor: SwiftUI.Color {
        switch detectedOutcome {
        case .success: .green
        case .incorrectPassword: .secondary
        case .permDisabled: .red
        case .tempDisabled: .orange
        case .smsVerification: .purple
        case .errorBanner: .red
        case .unknown: .gray
        }
    }

    var outcomeLabel: String {
        switch detectedOutcome {
        case .success: "SUCCESS"
        case .incorrectPassword: "INCORRECT"
        case .permDisabled: "PERM DISABLED"
        case .tempDisabled: "TEMP DISABLED"
        case .smsVerification: "SMS"
        case .errorBanner: "ERROR"
        case .unknown: "UNKNOWN"
        }
    }

    var formattedTime: String {
        DateFormatters.timeOnly.string(from: timestamp)
    }

    init(
        sessionId: String,
        credentialEmail: String,
        site: String,
        step: ScreenshotStep,
        attemptNumber: Int,
        fullImage: UIImage,
        croppedImage: UIImage?,
        detectedOutcome: VisionTextCropService.DetectedOutcome,
        crucialKeywords: [String],
        allDetectedText: String,
        visionConfidence: Double,
        analysisTimeMs: Int
    ) {
        self.id = UUID().uuidString
        self.timestamp = Date()
        self.sessionId = sessionId
        self.credentialEmail = credentialEmail
        self.site = site
        self.step = step
        self.attemptNumber = attemptNumber
        self.fullImage = fullImage
        self.croppedImage = croppedImage
        self.detectedOutcome = detectedOutcome
        self.crucialKeywords = crucialKeywords
        self.allDetectedText = allDetectedText
        self.visionConfidence = visionConfidence
        self.analysisTimeMs = analysisTimeMs
    }
}

nonisolated enum ScreenshotStep: String, Sendable {
    case pageLoad = "page_load"
    case fieldsDetected = "fields_detected"
    case preTyping = "pre_typing"
    case postTyping = "post_typing"
    case preClick = "pre_click"
    case postClick = "post_click"
    case loadingState = "loading_state"
    case settlementWait = "settlement_wait"
    case responseDetected = "response_detected"
    case crucialResponse = "crucial_response"
    case terminalState = "terminal_state"
    case successDetected = "success_detected"
    case errorBanner = "error_banner"
    case smsDetected = "sms_detected"
    case postAttempt = "post_attempt"
    case finalState = "final_state"
    case recoveryAttempt = "recovery_attempt"
    case blankPage = "blank_page"

    var displayName: String {
        rawValue.replacingOccurrences(of: "_", with: " ").uppercased()
    }

    var icon: String {
        switch self {
        case .pageLoad: "globe"
        case .fieldsDetected: "text.cursor"
        case .preTyping: "keyboard"
        case .postTyping: "checkmark.rectangle"
        case .preClick: "hand.tap"
        case .postClick: "hand.tap.fill"
        case .loadingState: "hourglass"
        case .settlementWait: "clock.arrow.circlepath"
        case .responseDetected: "text.magnifyingglass"
        case .crucialResponse: "exclamationmark.triangle.fill"
        case .terminalState: "stop.circle.fill"
        case .successDetected: "checkmark.circle.fill"
        case .errorBanner: "exclamationmark.octagon.fill"
        case .smsDetected: "message.fill"
        case .postAttempt: "arrow.clockwise"
        case .finalState: "flag.checkered"
        case .recoveryAttempt: "arrow.triangle.2.circlepath"
        case .blankPage: "rectangle.dashed"
        }
    }

    var isCritical: Bool {
        switch self {
        case .crucialResponse, .terminalState, .successDetected, .errorBanner, .smsDetected: true
        default: false
        }
    }
}
