import Foundation
import UIKit
import Observation

@Observable
@MainActor
class EvidenceBundleService {
    static let shared = EvidenceBundleService()

    var bundles: [EvidenceBundle] = []
    private let screenshotCache = ScreenshotCacheService.shared
    private let logger = DebugLogger.shared

    var totalCount: Int { bundles.count }
    var exportedCount: Int { bundles.filter { $0.isExported }.count }

    func createBundle(from attempt: LoginAttempt) {
        let bundle = EvidenceBundle(
            credentialId: attempt.credential.id,
            username: attempt.credential.username,
            password: attempt.credential.password,
            resultStatus: attempt.credential.status,
            outcome: outcomeFromStatus(attempt.credential.status),
            confidence: attempt.confidenceScore ?? 0,
            signalBreakdown: attempt.confidenceSignals,
            reasoning: attempt.confidenceReasoning ?? "",
            testedURL: attempt.detectedURL ?? "",
            networkMode: attempt.networkModeLabel ?? "Standard",
            vpnServer: attempt.assignedVPNServer,
            vpnIP: attempt.assignedVPNIP,
            vpnCountry: attempt.assignedVPNCountry,
            screenshotIds: attempt.screenshotIds,
            logs: attempt.logs,
            replayLog: attempt.replayLog,
            retryCount: attempt.credential.fullLoginAttemptCount,
            totalDurationMs: Int((attempt.duration ?? 0) * 1000),
            startedAt: attempt.startedAt ?? Date(),
            completedAt: attempt.completedAt ?? Date()
        )
        bundles.insert(bundle, at: 0)
        logger.log("EvidenceBundle: Created for \(attempt.credential.username) — \(bundle.outcomeLabel)", category: .evaluation, level: .info)
    }

    func generateExport(_ bundle: EvidenceBundle) -> EvidenceBundleExport {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return EvidenceBundleExport(
            bundleId: bundle.id.uuidString,
            exportedAt: iso.string(from: Date()),
            credential: .init(
                username: bundle.username,
                password: bundle.password,
                credentialId: bundle.credentialId
            ),
            result: .init(
                status: bundle.resultStatus.rawValue,
                outcome: bundle.outcomeLabel,
                confidence: bundle.confidence,
                reasoning: bundle.reasoning
            ),
            network: .init(
                mode: bundle.networkMode,
                testedURL: bundle.testedURL,
                vpnServer: bundle.vpnServer,
                vpnIP: bundle.vpnIP,
                vpnCountry: bundle.vpnCountry
            ),
            aiAnalysis: .init(
                signals: bundle.signalBreakdown.map {
                    .init(source: $0.source, weight: $0.weight, rawScore: $0.rawScore, weightedScore: $0.weightedScore, detail: $0.detail)
                }
            ),
            timeline: .init(
                startedAt: iso.string(from: bundle.startedAt),
                completedAt: iso.string(from: bundle.completedAt),
                totalDurationMs: bundle.totalDurationMs,
                retryCount: bundle.retryCount
            ),
            logs: bundle.logs.map {
                .init(timestamp: iso.string(from: $0.timestamp), level: $0.level.rawValue, message: $0.message)
            },
            replayEvents: bundle.replayLog?.events.map {
                .init(elapsedMs: $0.elapsedMs, action: $0.action, detail: $0.detail, level: $0.level)
            }
        )
    }

    func exportAsJSON(_ bundle: EvidenceBundle) -> Data? {
        let export = generateExport(bundle)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(export)
    }

    func exportBatchAsJSON(_ selectedBundles: [EvidenceBundle]) -> Data? {
        let exports = selectedBundles.map { generateExport($0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(exports)
    }

    func exportAsText(_ bundle: EvidenceBundle) -> String {
        var lines: [String] = []
        lines.append("═══════════════════════════════════════")
        lines.append("  EVIDENCE BUNDLE: \(bundle.id.uuidString.prefix(8))")
        lines.append("═══════════════════════════════════════")
        lines.append("")
        lines.append("▸ CREDENTIAL")
        lines.append("  Username: \(bundle.username)")
        lines.append("  Password: \(bundle.password)")
        lines.append("  ID:       \(bundle.credentialId)")
        lines.append("")
        lines.append("▸ RESULT")
        lines.append("  Status:     \(bundle.resultStatus.rawValue)")
        lines.append("  Outcome:    \(bundle.outcomeLabel)")
        lines.append("  Confidence: \(String(format: "%.0f%%", bundle.confidence * 100))")
        lines.append("  Reasoning:  \(bundle.reasoning)")
        lines.append("")
        lines.append("▸ NETWORK")
        lines.append("  Mode:    \(bundle.networkMode)")
        lines.append("  URL:     \(bundle.testedURL)")
        if let server = bundle.vpnServer { lines.append("  Server:  \(server)") }
        if let ip = bundle.vpnIP { lines.append("  IP:      \(ip)") }
        if let country = bundle.vpnCountry { lines.append("  Country: \(country)") }
        lines.append("")
        lines.append("▸ TIMELINE")
        let iso = ISO8601DateFormatter()
        lines.append("  Started:  \(iso.string(from: bundle.startedAt))")
        lines.append("  Ended:    \(iso.string(from: bundle.completedAt))")
        lines.append("  Duration: \(bundle.durationFormatted)")
        lines.append("  Retries:  \(bundle.retryCount)")
        lines.append("")
        lines.append("▸ AI SIGNALS (\(bundle.signalBreakdown.count))")
        for signal in bundle.signalBreakdown {
            lines.append("  [\(signal.source)] w:\(String(format: "%.2f", signal.weight)) raw:\(String(format: "%.2f", signal.rawScore)) → \(String(format: "%.3f", signal.weightedScore)) | \(signal.detail)")
        }
        lines.append("")
        lines.append("▸ LOGS (\(bundle.logs.count))")
        for log in bundle.logs.prefix(30) {
            lines.append("  [\(log.level.rawValue)] \(log.formattedTime) \(log.message)")
        }
        if bundle.logs.count > 30 {
            lines.append("  ... +\(bundle.logs.count - 30) more")
        }
        if let replay = bundle.replayLog {
            lines.append("")
            lines.append("▸ REPLAY (\(replay.events.count) events, \(replay.totalDurationMs)ms)")
            for event in replay.events.suffix(20) {
                lines.append("  +\(event.elapsedMs)ms [\(event.action)] \(event.detail)")
            }
        }
        lines.append("")
        lines.append("═══════════════════════════════════════")
        return lines.joined(separator: "\n")
    }

    func markExported(_ bundle: EvidenceBundle) {
        bundle.isExported = true
        bundle.exportedAt = Date()
    }

    func clearExported() {
        bundles.removeAll { $0.isExported }
    }

    func clearAll() {
        bundles.removeAll()
    }

    func screenshotImages(for bundle: EvidenceBundle) -> [UIImage] {
        bundle.screenshotIds.compactMap { screenshotCache.retrieve(forKey: $0) }
    }

    private func outcomeFromStatus(_ status: CredentialStatus) -> LoginOutcome {
        switch status {
        case .working: .success
        case .noAcc: .noAcc
        case .tempDisabled: .tempDisabled
        case .permDisabled: .permDisabled
        case .unsure: .unsure
        case .untested, .testing: .unsure
        }
    }
}
