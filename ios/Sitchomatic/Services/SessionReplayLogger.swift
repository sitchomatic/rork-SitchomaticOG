import Foundation

nonisolated struct SessionReplayEvent: Codable, Sendable {
    let timestamp: Date
    let elapsedMs: Int
    let action: String
    let detail: String
    let level: String
    let screenshotId: String?
}

nonisolated struct SessionReplayLog: Codable, Sendable {
    let sessionId: String
    let startedAt: Date
    let completedAt: Date
    let targetURL: String
    let credential: String
    let outcome: String
    let totalDurationMs: Int
    let events: [SessionReplayEvent]
    let metadata: [String: String]
}

@MainActor
class SessionReplayLogger {
    static let shared = SessionReplayLogger()

    private var activeSessions: [String: ActiveReplay] = [:]
    private let logger = DebugLogger.shared

    private struct ActiveReplay {
        let startTime: Date
        let targetURL: String
        let credential: String
        var events: [SessionReplayEvent] = []
        var metadata: [String: String] = [:]
    }

    func startSession(id: String, targetURL: String, credential: String) {
        activeSessions[id] = ActiveReplay(
            startTime: Date(),
            targetURL: targetURL,
            credential: credential
        )
    }

    func log(sessionId: String, action: String, detail: String, level: String = "info", screenshotId: String? = nil) {
        guard var session = activeSessions[sessionId] else { return }
        let elapsed = Int(Date().timeIntervalSince(session.startTime) * 1000)
        session.events.append(SessionReplayEvent(
            timestamp: Date(),
            elapsedMs: elapsed,
            action: action,
            detail: detail,
            level: level,
            screenshotId: screenshotId
        ))
        activeSessions[sessionId] = session
    }

    func addMetadata(sessionId: String, key: String, value: String) {
        activeSessions[sessionId]?.metadata[key] = value
    }

    func endSession(id: String, outcome: String) -> SessionReplayLog? {
        guard let session = activeSessions.removeValue(forKey: id) else { return nil }
        let now = Date()
        let totalMs = Int(now.timeIntervalSince(session.startTime) * 1000)
        return SessionReplayLog(
            sessionId: id,
            startedAt: session.startTime,
            completedAt: now,
            targetURL: session.targetURL,
            credential: session.credential,
            outcome: outcome,
            totalDurationMs: totalMs,
            events: session.events,
            metadata: session.metadata
        )
    }

    func exportAsJSON(_ log: SessionReplayLog) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(log)
    }

    func exportAllActive() -> [SessionReplayLog] {
        var logs: [SessionReplayLog] = []
        for (id, session) in activeSessions {
            let now = Date()
            let totalMs = Int(now.timeIntervalSince(session.startTime) * 1000)
            logs.append(SessionReplayLog(
                sessionId: id,
                startedAt: session.startTime,
                completedAt: now,
                targetURL: session.targetURL,
                credential: session.credential,
                outcome: "in_progress",
                totalDurationMs: totalMs,
                events: session.events,
                metadata: session.metadata
            ))
        }
        return logs
    }

    var activeSessionCount: Int { activeSessions.count }
}
