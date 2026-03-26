import Foundation
import UIKit

nonisolated struct EnrichedReplayStep: Identifiable, Sendable {
    let id: String
    let index: Int
    let timestamp: Date
    let elapsedMs: Int
    let action: String
    let detail: String
    let level: String
    let screenshotId: String?
    let pattern: String?
    let jsResult: String?
    let phase: String?
    let durationMs: Int?
}

nonisolated struct EnrichedSessionReplay: Identifiable, Sendable {
    let id: String
    let sessionId: String
    let startedAt: Date
    let completedAt: Date
    let targetURL: String
    let credential: String
    let outcome: String
    let totalDurationMs: Int
    let steps: [EnrichedReplayStep]
    let metadata: [String: String]
    let logEntries: [DebugLogEntry]
}

nonisolated struct TapHeatmapData: Sendable {
    let screenshotImage: UIImage
    let imageSize: CGSize
    let detectedFields: [DetectedElement]
    let detectedButtons: [DetectedElement]
    let tapPoints: [TapPoint]
    let ocrElements: [OCROverlayElement]
    let saliencyHotspots: [CGRect]

    nonisolated struct DetectedElement: Identifiable, Sendable {
        let id: String
        let label: String
        let boundingBox: CGRect
        let confidence: Float
        let elementType: ElementType

        nonisolated enum ElementType: String, Sendable {
            case emailField
            case passwordField
            case loginButton
            case inputField
            case button
            case label
            case unknown
        }
    }

    nonisolated struct TapPoint: Identifiable, Sendable {
        let id: String
        let coordinate: CGPoint
        let label: String
        let wasSuccessful: Bool
    }

    nonisolated struct OCROverlayElement: Identifiable, Sendable {
        let id: String
        let text: String
        let boundingBox: CGRect
        let confidence: Float
    }
}

@MainActor
class ReplayDebuggerService {
    static let shared = ReplayDebuggerService()

    private let logger = DebugLogger.shared
    private let screenshotCache = ScreenshotCacheService.shared
    private let replayLogger = SessionReplayLogger.shared

    func loadSavedReplays() -> [EnrichedSessionReplay] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("session_replays", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }

        let jsonFiles = files.filter { $0.pathExtension == "json" }
            .sorted { a, b in
                let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return aDate > bDate
            }

        var replays: [EnrichedSessionReplay] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for file in jsonFiles.prefix(50) {
            guard let data = try? Data(contentsOf: file),
                  let log = try? decoder.decode(SessionReplayLog.self, from: data) else { continue }

            let enriched = enrichReplayLog(log)
            replays.append(enriched)
        }

        return replays
    }

    func loadActiveReplays() -> [EnrichedSessionReplay] {
        replayLogger.exportAllActive().map { enrichReplayLog($0) }
    }

    private func enrichReplayLog(_ log: SessionReplayLog) -> EnrichedSessionReplay {
        let sessionLogs = logger.entriesForSession(log.sessionId)

        var steps: [EnrichedReplayStep] = []
        for (index, event) in log.events.enumerated() {
            let pattern = extractPattern(from: event)
            let jsResult = extractJSResult(from: event, sessionLogs: sessionLogs)
            let phase = extractPhase(from: event)
            let stepDuration = extractStepDuration(from: event, sessionLogs: sessionLogs)

            steps.append(EnrichedReplayStep(
                id: "\(log.sessionId)_\(index)",
                index: index,
                timestamp: event.timestamp,
                elapsedMs: event.elapsedMs,
                action: event.action,
                detail: event.detail,
                level: event.level,
                screenshotId: event.screenshotId,
                pattern: pattern,
                jsResult: jsResult,
                phase: phase,
                durationMs: stepDuration
            ))
        }

        return EnrichedSessionReplay(
            id: log.sessionId,
            sessionId: log.sessionId,
            startedAt: log.startedAt,
            completedAt: log.completedAt,
            targetURL: log.targetURL,
            credential: log.credential,
            outcome: log.outcome,
            totalDurationMs: log.totalDurationMs,
            steps: steps,
            metadata: log.metadata,
            logEntries: sessionLogs
        )
    }

    private func extractPattern(from event: SessionReplayEvent) -> String? {
        let detail = event.detail.lowercased()
        if detail.contains("pattern") {
            let patterns = ["TRUE DETECTION", "Calibrated Typing", "Calibrated Direct", "Tab Navigation",
                          "React Native Setter", "Form Submit Direct", "Coordinate Click",
                          "Vision ML Coordinate", "Click-Focus Sequential", "ExecCommand Insert",
                          "Slow Deliberate Typer", "Mobile Touch Burst"]
            for p in patterns {
                if event.detail.contains(p) { return p }
            }
        }
        if event.action.contains("pattern") { return event.detail }
        return nil
    }

    private func extractJSResult(from event: SessionReplayEvent, sessionLogs: [DebugLogEntry]) -> String? {
        if event.action.contains("js_result") || event.action.contains("evaluate") {
            return event.detail
        }
        let nearbyLogs = sessionLogs.filter { abs($0.timestamp.timeIntervalSince(event.timestamp)) < 0.5 }
        for log in nearbyLogs {
            if log.message.contains("JS:") || log.message.contains("evaluateJavaScript") {
                return log.detail ?? log.message
            }
        }
        return nil
    }

    private func extractPhase(from event: SessionReplayEvent) -> String? {
        let phaseActions = ["page_load", "page_loaded", "cookie_dismiss", "field_verify",
                          "fill_credentials", "submit", "poll_result", "evaluate", "complete",
                          "page_load_failed", "blank_page", "calibrate"]
        for phase in phaseActions {
            if event.action.contains(phase) { return phase }
        }
        return nil
    }

    private func extractStepDuration(from event: SessionReplayEvent, sessionLogs: [DebugLogEntry]) -> Int? {
        let nearbyLogs = sessionLogs.filter { abs($0.timestamp.timeIntervalSince(event.timestamp)) < 1.0 }
        return nearbyLogs.compactMap(\.durationMs).first
    }

    func screenshotForStep(_ step: EnrichedReplayStep) -> UIImage? {
        guard let screenshotId = step.screenshotId else { return nil }
        return screenshotCache.retrieve(forKey: screenshotId)
    }

    func screenshotForKey(_ key: String) -> UIImage? {
        screenshotCache.retrieve(forKey: key)
    }

    func buildHeatmapData(for image: UIImage, tapCoordinates: [(point: CGPoint, label: String, success: Bool)] = []) async -> TapHeatmapData {
        let visionML = VisionMLService.shared
        let viewportSize = CGSize(width: 390, height: 844)
        let detection = await visionML.detectLoginElements(in: image, viewportSize: viewportSize)
        let allText = detection.allText
        let rectangles = await visionML.detectRectangularRegions(in: image)

        var detectedFields: [TapHeatmapData.DetectedElement] = []
        var detectedButtons: [TapHeatmapData.DetectedElement] = []

        if let ef = detection.emailField {
            detectedFields.append(TapHeatmapData.DetectedElement(
                id: "email_\(ef.label)", label: "Email: \(ef.label)",
                boundingBox: ef.boundingBox, confidence: ef.confidence, elementType: .emailField))
        }
        if let pf = detection.passwordField {
            detectedFields.append(TapHeatmapData.DetectedElement(
                id: "pass_\(pf.label)", label: "Password: \(pf.label)",
                boundingBox: pf.boundingBox, confidence: pf.confidence, elementType: .passwordField))
        }
        if let lb = detection.loginButton {
            detectedButtons.append(TapHeatmapData.DetectedElement(
                id: "btn_\(lb.label)", label: "Button: \(lb.label)",
                boundingBox: lb.boundingBox, confidence: lb.confidence, elementType: .loginButton))
        }

        for rect in rectangles {
            let imageSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
            let widthRatio = rect.width / imageSize.width
            let heightRatio = rect.height / imageSize.height
            let aspectRatio = rect.width / max(rect.height, 1)

            let type: TapHeatmapData.DetectedElement.ElementType
            if widthRatio > 0.4 && heightRatio < 0.08 && aspectRatio > 4 {
                type = .inputField
            } else if widthRatio > 0.2 && widthRatio < 0.6 && heightRatio < 0.06 && aspectRatio > 2.5 {
                type = .button
            } else {
                type = .unknown
            }

            if type != .unknown {
                let existing = detectedFields + detectedButtons
                let isDuplicate = existing.contains { $0.boundingBox.intersects(rect) }
                if !isDuplicate {
                    let element = TapHeatmapData.DetectedElement(
                        id: "rect_\(UUID().uuidString.prefix(6))", label: type.rawValue,
                        boundingBox: rect, confidence: 0.5, elementType: type)
                    if type == .inputField { detectedFields.append(element) }
                    else { detectedButtons.append(element) }
                }
            }
        }

        let tapPoints = tapCoordinates.enumerated().map { index, tap in
            TapHeatmapData.TapPoint(
                id: "tap_\(index)", coordinate: tap.point,
                label: tap.label, wasSuccessful: tap.success)
        }

        let ocrElements = allText.map { element in
            TapHeatmapData.OCROverlayElement(
                id: "ocr_\(UUID().uuidString.prefix(6))",
                text: element.text, boundingBox: element.boundingBox, confidence: element.confidence)
        }

        return TapHeatmapData(
            screenshotImage: image,
            imageSize: CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale),
            detectedFields: detectedFields,
            detectedButtons: detectedButtons,
            tapPoints: tapPoints,
            ocrElements: ocrElements,
            saliencyHotspots: [])
    }

    func deleteReplay(sessionId: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("session_replays", isDirectory: true)
        let file = dir.appendingPathComponent("\(sessionId).json")
        try? FileManager.default.removeItem(at: file)
    }

    func clearAllReplays() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("session_replays", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
