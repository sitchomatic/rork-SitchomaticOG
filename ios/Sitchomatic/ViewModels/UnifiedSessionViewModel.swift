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
    let adaptiveEngine = AdaptiveConcurrencyEngine.shared
    var config: UnifiedSystemConfig = .defaultConfig
    var stealthEnabled: Bool = true
    var globalLogs: [PPSRLogEntry] = []
    var showBatchResultPopup: Bool = false
    var batchStartTime: Date?
    var pauseCountdown: Int = 0
    private var pauseCountdownTask: Task<Void, Never>?
    private var batchTask: Task<Void, Never>?
    private var forceStopTask: Task<Void, Never>?
    private let worker = DualSiteWorkerService.shared
    private let logger = DebugLogger.shared
    private let notifications = PPSRNotificationService.shared
    private let backgroundService = BackgroundTaskService.shared
    private let persistenceKey = "unified_sessions_v1"
    private var saveDebouncerTask: Task<Void, Never>?

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
        sessions.filter { !$0.isTerminal }
    }

    var queuedSessions: [DualSiteSession] {
        sessions.filter { $0.globalState == .active && $0.currentAttempt == 0 }
    }

    var batchProgress: Double {
        guard !sessions.isEmpty else { return 0 }
        let terminal = sessions.filter(\.isTerminal).count
        return Double(terminal) / Double(sessions.count)
    }

    var batchElapsed: String {
        guard let start = batchStartTime else { return "—" }
        let d = Date().timeIntervalSince(start)
        if d < 60 { return String(format: "%.0fs", d) }
        return String(format: "%.0fm %02.0fs", (d / 60).rounded(.down), d.truncatingRemainder(dividingBy: 60))
    }

    var activeWorkerCount: Int {
        sessions.filter { $0.globalState == .active && $0.currentAttempt > 0 }.count
    }

    init() {
        loadPersistedSessions()
    }

    func importCredentials(_ text: String) {
        let parsed = LoginCredential.smartParse(text)
        guard !parsed.isEmpty else {
            log("Import failed — no valid email:password lines found", level: .warning)
            return
        }

        let existingEmails = Set(sessions.map { $0.credential.email.lowercased() })
        var added = 0

        for cred in parsed {
            let email = cred.username.lowercased()
            guard !existingEmails.contains(email) else { continue }

            let sessionCred = SessionCredential(
                id: UUID().uuidString,
                email: cred.username,
                password: cred.password
            )
            let identity = generateIdentity()
            let session = DualSiteSession.create(credential: sessionCred, identity: identity)
            sessions.append(session)
            added += 1
        }

        log("Imported \(added) credential(s) from \(parsed.count) parsed (\(sessions.count) total)", level: .success)
        persistSessions()
    }

    func importFromLoginVM() {
        let loginVM = LoginViewModel.shared
        let untested = loginVM.untestedCredentials
        guard !untested.isEmpty else {
            log("No untested credentials in Login VM to import", level: .warning)
            return
        }

        let existingEmails = Set(sessions.map { $0.credential.email.lowercased() })
        var added = 0

        for cred in untested {
            let email = cred.username.lowercased()
            guard !existingEmails.contains(email) else { continue }

            let sessionCred = SessionCredential(
                id: cred.id,
                email: cred.username,
                password: cred.password
            )
            let identity = generateIdentity()
            let session = DualSiteSession.create(credential: sessionCred, identity: identity)
            sessions.append(session)
            added += 1
        }

        log("Imported \(added) credential(s) from Login VM (\(sessions.count) total)", level: .success)
        persistSessions()
    }

    func startBatch() {
        let toTest = sessions.filter { !$0.isTerminal }
        guard !toTest.isEmpty else {
            log("No sessions to test", level: .warning)
            return
        }

        isPaused = false
        isStopping = false
        isRunning = true
        batchStartTime = Date()
        backgroundService.beginExtendedBackgroundExecution(reason: "Unified dual-site batch test")

        adaptiveEngine.start(cap: adaptiveEngine.maxCap)

        log("Starting unified batch: \(toTest.count) sessions, AI adaptive (cap \(adaptiveEngine.maxCap)), stealth: \(stealthEnabled ? "ON" : "OFF")", level: .info)
        logger.log("UNIFIED BATCH START: \(toTest.count) sessions, adaptive cap=\(adaptiveEngine.maxCap)", category: .login, level: .info)

        batchTask = Task {
            await withTaskGroup(of: Void.self) { group in
                var running = 0
                var sessionIndex = 0

                while sessionIndex < self.sessions.count && !self.isStopping && !Task.isCancelled {
                    let idx = sessionIndex

                    guard !self.sessions[idx].isTerminal else {
                        sessionIndex += 1
                        continue
                    }

                    if CrashProtectionService.shared.isMemoryEmergency {
                        self.log("Memory EMERGENCY — auto-stopping unified batch", level: .error)
                        self.isStopping = true
                        break
                    }

                    if !CrashProtectionService.shared.isMemorySafeForNewSession {
                        self.log("Memory pressure — waiting before spawning next unified session", level: .warning)
                        let recovered = await CrashProtectionService.shared.waitForMemoryToDrop(timeout: 15)
                        if !recovered || Task.isCancelled {
                            self.isStopping = true
                            break
                        }
                    }

                    while self.isPaused && !self.isStopping && !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    guard !self.isStopping && !Task.isCancelled else { break }

                    let currentLiveConcurrency = self.adaptiveEngine.liveConcurrency
                    if running >= currentLiveConcurrency {
                        await group.next()
                        running -= 1
                    }

                    running += 1
                    sessionIndex += 1

                    let sessionSnapshot = self.sessions[idx]
                    let workerConfig = self.config
                    let workerStealth = self.stealthEnabled

                    group.addTask { @MainActor in
                        var session = sessionSnapshot
                        let startTime = Date()
                        let result = await self.worker.runDualSiteSession(
                            session: &session,
                            config: workerConfig,
                            stealthEnabled: workerStealth,
                            onUpdate: { updated in
                                if let i = self.sessions.firstIndex(where: { $0.id == updated.id }) {
                                    self.sessions[i] = updated
                                }
                            },
                            onLog: { msg, level in
                                self.log(msg, level: level)
                            }
                        )

                        if let i = self.sessions.firstIndex(where: { $0.id == result.session.id }) {
                            self.sessions[i] = result.session
                        }

                        let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
                        let isConclusive = result.session.isTerminal
                        let isTimeout = !isConclusive && result.session.globalState == .active
                        self.adaptiveEngine.recordOutcome(
                            conclusive: isConclusive,
                            timeout: isTimeout,
                            connectionFailure: false,
                            latencyMs: latencyMs
                        )

                        self.persistSessions()
                    }
                }

                await group.waitForAll()
            }

            finalizeBatch()
        }
    }

    func stopBatch() {
        cancelPauseCountdown()
        isStopping = true
        isPaused = false
        pauseCountdown = 0
        log("Stopping unified batch — waiting for active workers to finish", level: .warning)
        startForceStopTimer()
    }

    func pauseBatch() {
        isPaused = true
        pauseCountdown = 60
        log("Unified batch paused for 60s", level: .warning)
        startPauseCountdown()
    }

    func resumeBatch() {
        cancelPauseCountdown()
        isPaused = false
        pauseCountdown = 0
        log("Unified batch resumed", level: .info)
    }

    func clearSessions() {
        guard !isRunning else {
            log("Cannot clear sessions while batch is running", level: .warning)
            return
        }
        sessions.removeAll()
        persistSessions()
        log("All sessions cleared", level: .info)
    }

    func clearCompleted() {
        sessions.removeAll { $0.isTerminal }
        persistSessions()
        log("Completed sessions cleared", level: .info)
    }

    func resetSession(_ session: DualSiteSession) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let cred = sessions[idx].credential
        let identity = generateIdentity()
        sessions[idx] = DualSiteSession.create(credential: cred, identity: identity)
        persistSessions()
        log("Reset session for \(cred.email)", level: .info)
    }

    func removeSession(_ session: DualSiteSession) {
        sessions.removeAll { $0.id == session.id }
        persistSessions()
    }

    func sessionsWithSiteResult(_ result: SiteResult) -> [DualSiteSession] {
        sessions.filter { $0.hasSiteResult(result) }
    }

    func exportResults() -> String {
        var lines: [String] = ["email,joe_result,ignition_result,paired_result,ocr_status,joe_attempts,ign_attempts,duration,identity_action"]
        for session in sessions where session.isTerminal {
            let ocrStatus = session.pairedOCRStatus ?? "—"
            lines.append("\(session.credential.email),\(session.joeSiteResult.shortLabel),\(session.ignitionSiteResult.shortLabel),\(session.pairedBadgeText),\(ocrStatus),\(session.joeAttempts.count),\(session.ignitionAttempts.count),\(session.formattedDuration),\(session.identityAction.rawValue)")
        }
        return lines.joined(separator: "\n")
    }

    func exportByClassification(_ classification: SessionClassification) -> String {
        sessions
            .filter { $0.classification == classification }
            .map { "\($0.credential.email):\($0.credential.password)" }
            .joined(separator: "\n")
    }

    func exportBySiteResult(_ result: SiteResult) -> String {
        sessions
            .filter { $0.hasSiteResult(result) }
            .map { "\($0.credential.email):\($0.credential.password)" }
            .joined(separator: "\n")
    }

    private func finalizeBatch() {
        let success = sessionsWithSiteResult(.success).count
        let perm = sessionsWithSiteResult(.permDisabled).count
        let temp = sessionsWithSiteResult(.tempDisabled).count
        let noAcc = sessionsWithSiteResult(.noAccount).count

        cancelPauseCountdown()
        forceStopTask?.cancel()
        forceStopTask = nil
        isRunning = false
        isPaused = false
        isStopping = false
        pauseCountdown = 0
        batchStartTime = nil

        adaptiveEngine.stop()
        backgroundService.endExtendedBackgroundExecution()

        log("Unified batch complete: \(success) success, \(perm) perm banned, \(temp) temp locked, \(noAcc) no account", level: .success)
        logger.log("UNIFIED BATCH COMPLETE: success=\(success) perm=\(perm) temp=\(temp) noAcc=\(noAcc)", category: .login, level: .success)

        notifications.sendBatchComplete(working: success, dead: perm + noAcc, requeued: temp)
        showBatchResultPopup = true
        persistSessions()
    }

    private func startForceStopTimer() {
        forceStopTask?.cancel()
        forceStopTask = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            guard isRunning || isStopping else { return }
            log("Force-stop: unified batch did not finish within 30s — cancelling", level: .error)
            batchTask?.cancel()
            finalizeBatch()
        }
    }

    private func startPauseCountdown() {
        cancelPauseCountdown()
        pauseCountdownTask = Task {
            while pauseCountdown > 0 && isPaused && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                pauseCountdown -= 1
            }
            if isPaused && !Task.isCancelled {
                resumeBatch()
            }
        }
    }

    private func cancelPauseCountdown() {
        pauseCountdownTask?.cancel()
        pauseCountdownTask = nil
    }

    func log(_ message: String, level: PPSRLogEntry.Level = .info) {
        let entry = PPSRLogEntry(message: message, level: level)
        globalLogs.insert(entry, at: 0)
        if globalLogs.count > 500 {
            globalLogs = Array(globalLogs.prefix(400))
        }
    }

    private func generateIdentity() -> SessionIdentity {
        let stealth = PPSRStealthService.shared
        let profile = stealth.nextProfileSync()
        let proxyService = ProxyRotationService.shared
        let proxy = proxyService.nextWorkingProxy(for: .joe)

        return SessionIdentity(
            proxyAddress: proxy?.displayString ?? "direct",
            userAgent: profile.userAgent,
            viewport: "\(Int(profile.viewport.width))x\(Int(profile.viewport.height))",
            canvasFingerprint: "canvas_\(profile.seed)"
        )
    }

    private func persistSessions() {
        saveDebouncerTask?.cancel()
        saveDebouncerTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            if let data = try? JSONEncoder().encode(self.sessions) {
                UserDefaults.standard.set(data, forKey: self.persistenceKey)
            }
        }
    }

    func persistSessionsNow() {
        saveDebouncerTask?.cancel()
        saveDebouncerTask = nil
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
        }
    }

    private func loadPersistedSessions() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let loaded = try? JSONDecoder().decode([DualSiteSession].self, from: data) else { return }
        sessions = loaded
        var resetCount = 0
        for i in sessions.indices where sessions[i].globalState == .active && sessions[i].currentAttempt > 0 {
            sessions[i].globalState = .active
            sessions[i].currentAttempt = 0
            resetCount += 1
        }
        if resetCount > 0 {
            log("Restored \(sessions.count) sessions, reset \(resetCount) interrupted", level: .warning)
        }
    }

    func handleMemoryPressure() {
        if globalLogs.count > 100 {
            globalLogs = Array(globalLogs.prefix(80))
        }
    }

    func emergencyStop() {
        logger.log("UnifiedSessionViewModel: EMERGENCY STOP triggered", category: .system, level: .critical)
        batchTask?.cancel()
        batchTask = nil
        finalizeBatch()
        DeadSessionDetector.shared.stopAllWatchdogs()
        SessionActivityMonitor.shared.stopAll()
        WebViewTracker.shared.reset()
    }
}
