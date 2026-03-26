import Foundation

@MainActor
class LoginCredentialManager {
    var credentials: [LoginCredential] = []

    private let persistence = LoginPersistenceService.shared
    private let blacklistService = BlacklistService.shared
    private let logger = DebugLogger.shared
    private var credentialsSaveTask: Task<Void, Never>?
    var onLog: ((String, PPSRLogEntry.Level) -> Void)?

    var workingCredentials: [LoginCredential] { credentials.filter { $0.status == .working } }
    var noAccCredentials: [LoginCredential] { credentials.filter { $0.status == .noAcc } }
    var permDisabledCredentials: [LoginCredential] { credentials.filter { $0.status == .permDisabled } }
    var tempDisabledCredentials: [LoginCredential] { credentials.filter { $0.status == .tempDisabled } }
    var unsureCredentials: [LoginCredential] { credentials.filter { $0.status == .unsure } }
    var untestedCredentials: [LoginCredential] { credentials.filter { $0.status == .untested } }
    var testingCredentials: [LoginCredential] { credentials.filter { $0.status == .testing } }

    func loadPersistedCredentials() {
        credentials = persistence.loadCredentials()
        if !credentials.isEmpty {
            onLog?("Restored \(credentials.count) credentials from storage", .info)
        }
    }

    func restoreTestQueueIfNeeded() {
        guard let queuedIds = persistence.loadTestQueue(), !queuedIds.isEmpty else { return }
        let idSet = Set(queuedIds)
        var restoredCount = 0
        for cred in credentials where idSet.contains(cred.id) {
            if cred.status == .testing {
                cred.status = .untested
                restoredCount += 1
            }
        }
        persistence.clearTestQueue()
        if restoredCount > 0 {
            onLog?("Restored \(restoredCount) interrupted test(s) back to queue", .warning)
            persistCredentials()
        }
    }

    func persistCredentials() {
        credentialsSaveTask?.cancel()
        credentialsSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            persistence.saveCredentials(credentials)
        }
    }

    func persistCredentialsNow() {
        credentialsSaveTask?.cancel()
        credentialsSaveTask = nil
        persistence.saveCredentials(credentials)
    }

    func smartImportCredentials(_ input: String) {
        logger.log("Smart import started (\(input.count) chars)", category: .persistence, level: .info)
        let parsed = LoginCredential.smartParse(input)
        let lines = input.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if parsed.isEmpty && !lines.isEmpty {
            for line in lines {
                onLog?("Could not parse: \(line)", .warning)
            }
            return
        }

        let permDisabledUsernames = Set(permDisabledCredentials.map(\.username))

        var added = 0
        var skippedBlacklist = 0
        for cred in parsed {
            if permDisabledUsernames.contains(cred.username) {
                onLog?("Skipped perm disabled: \(cred.username)", .warning)
                continue
            }
            if blacklistService.autoExcludeBlacklist && blacklistService.isBlacklisted(cred.username) {
                skippedBlacklist += 1
                continue
            }
            let isDuplicate = credentials.contains { $0.username == cred.username }
            if isDuplicate {
                onLog?("Skipped duplicate: \(cred.username)", .warning)
            } else {
                credentials.append(cred)
                added += 1
            }
        }

        if skippedBlacklist > 0 {
            onLog?("Skipped \(skippedBlacklist) blacklisted credential(s)", .warning)
        }

        if parsed.count > 0 {
            onLog?("Smart import: \(added) added from \(parsed.count) parsed (\(lines.count) lines)", .success)
            logger.log("Credential import: \(added) added, \(skippedBlacklist) blacklisted, from \(parsed.count) parsed", category: .persistence, level: .success)
        }
        persistCredentials()
    }

    func deleteCredential(_ cred: LoginCredential) {
        credentials.removeAll { $0.id == cred.id }
        onLog?("Removed credential: \(cred.username)", .info)
        persistCredentials()
    }

    func restoreCredential(_ cred: LoginCredential) {
        cred.status = .untested
        onLog?("Restored \(cred.username) to untested", .info)
        persistCredentials()
    }

    func purgePermDisabledCredentials() {
        let count = permDisabledCredentials.count
        credentials.removeAll { $0.status == .permDisabled }
        onLog?("Purged \(count) perm disabled credential(s)", .info)
        persistCredentials()
    }

    func purgeNoAccCredentials() {
        let count = noAccCredentials.count
        credentials.removeAll { $0.status == .noAcc }
        onLog?("Purged \(count) no-acc credential(s)", .info)
        persistCredentials()
    }

    func purgeUnsureCredentials() {
        let count = unsureCredentials.count
        credentials.removeAll { $0.status == .unsure }
        onLog?("Purged \(count) unsure credential(s)", .info)
        persistCredentials()
    }

    func requeueCredentialToBottom(_ credential: LoginCredential) {
        if let idx = credentials.firstIndex(where: { $0.id == credential.id }) {
            credentials.remove(at: idx)
            credentials.append(credential)
        }
    }

    func resetStuckTestingCredentials() -> Int {
        var resetCount = 0
        for cred in credentials where cred.status == .testing {
            cred.status = .untested
            resetCount += 1
        }
        return resetCount
    }

    func syncFromiCloud() {
        if let synced = persistence.syncFromiCloud() {
            let existingUsernames = Set(credentials.map(\.username))
            var added = 0
            for cred in synced where !existingUsernames.contains(cred.username) {
                credentials.append(cred)
                added += 1
            }
            if added > 0 {
                onLog?("iCloud sync: merged \(added) new credentials", .success)
                persistCredentials()
            } else {
                onLog?("iCloud sync: no new credentials found", .info)
            }
        }
    }

    func exportWorkingCredentials() -> String {
        workingCredentials.map(\.exportFormat).joined(separator: "\n")
    }

    func exportCredentials(filter: LoginViewModel.CredentialExportFilter) -> String {
        let creds: [LoginCredential]
        switch filter {
        case .all: creds = credentials
        case .untested: creds = untestedCredentials
        case .working: creds = workingCredentials
        case .tempDisabled: creds = tempDisabledCredentials
        case .permDisabled: creds = permDisabledCredentials
        case .noAcc: creds = noAccCredentials
        case .unsure: creds = unsureCredentials
        }
        return creds.map(\.exportFormat).joined(separator: "\n")
    }

    func exportCredentialsCSV(filter: LoginViewModel.CredentialExportFilter) -> String {
        let creds: [LoginCredential]
        switch filter {
        case .all: creds = credentials
        case .untested: creds = untestedCredentials
        case .working: creds = workingCredentials
        case .tempDisabled: creds = tempDisabledCredentials
        case .permDisabled: creds = permDisabledCredentials
        case .noAcc: creds = noAccCredentials
        case .unsure: creds = unsureCredentials
        }
        var csv = "Email,Password,Status,Tests,Success Rate\n"
        for cred in creds {
            csv += "\(cred.username),\(cred.password),\(cred.status.rawValue),\(cred.totalTests),\(String(format: "%.0f%%", cred.successRate * 100))\n"
        }
        return csv
    }

    func saveTestQueue() {
        persistence.saveTestQueue(credentialIds: credentials.filter { $0.status == .testing || $0.status == .untested }.map(\.id))
    }

    func saveTestQueue(ids: [String]) {
        persistence.saveTestQueue(credentialIds: ids)
    }

    func clearTestQueue() {
        persistence.clearTestQueue()
    }
}
