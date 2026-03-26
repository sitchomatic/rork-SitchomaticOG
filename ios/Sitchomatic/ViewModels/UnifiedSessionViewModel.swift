import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
class UnifiedSessionViewModel {
    static let shared = UnifiedSessionViewModel()

    var sessions: [DualSiteSession] = []
    var isRunning: Bool = false
    var isPaused: Bool = false
    var isStopping: Bool = false
    var maxConcurrency: Int = 4
    var config: UnifiedSystemConfig = .defaultConfig

    var activeSessions: [DualSiteSession] {
        sessions.filter { $0.globalState == .active }
    }

    var completedSessions: [DualSiteSession] {
        sessions.filter { $0.isTerminal }
    }

    var successSessions: [DualSiteSession] {
        sessions.filter { $0.classification == .validAccount }
    }

    var permBannedSessions: [DualSiteSession] {
        sessions.filter { $0.classification == .permanentBan }
    }

    var tempLockedSessions: [DualSiteSession] {
        sessions.filter { $0.classification == .temporaryLock }
    }

    var noAccountSessions: [DualSiteSession] {
        sessions.filter { $0.classification == .noAccount }
    }

    var pendingSessions: [DualSiteSession] {
        sessions.filter { $0.classification == .pending && !$0.isTerminal }
    }

    var batchProgress: Double {
        guard !sessions.isEmpty else { return 0 }
        let terminal = sessions.filter(\.isTerminal).count
        return Double(terminal) / Double(sessions.count)
    }

    func startBatch() {
        // TODO: Implement V4.1 worker loop
    }

    func stopBatch() {
        // TODO: Implement graceful stop
    }

    func pauseBatch() {
        // TODO: Implement pause
    }

    func resumeBatch() {
        // TODO: Implement resume
    }

    func importCredentials(_ text: String) {
        // TODO: Parse email:password lines into SessionCredential
    }

    func clearSessions() {
        sessions.removeAll()
    }
}
