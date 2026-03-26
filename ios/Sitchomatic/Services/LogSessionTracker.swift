import Foundation

@MainActor
class LogSessionTracker {
    private var sessionTimers: [String: Date] = [:]
    private var stepTimers: [String: Date] = [:]

    func startTimer(key: String) { stepTimers[key] = Date() }

    func stopTimer(key: String) -> Int? {
        guard let start = stepTimers.removeValue(forKey: key) else { return nil }
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    func startSession(_ sessionId: String) {
        sessionTimers[sessionId] = Date()
    }

    func endSession(_ sessionId: String) -> Int? {
        sessionTimers.removeValue(forKey: sessionId).map { Int(Date().timeIntervalSince($0) * 1000) }
    }

    func reset() {
        sessionTimers.removeAll()
        stepTimers.removeAll()
    }
}
