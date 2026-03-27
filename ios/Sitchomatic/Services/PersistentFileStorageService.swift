import Foundation
import UIKit

class PersistentFileStorageService {
    static let shared = PersistentFileStorageService()

    private let rootFolder = "AppVault"
    private let fileManager = FileManager.default

    private var rootURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(rootFolder)
    }

    private var configURL: URL { rootURL.appendingPathComponent("config") }
    private var credentialsURL: URL { rootURL.appendingPathComponent("credentials") }
    private var cardsURL: URL { rootURL.appendingPathComponent("cards") }
    private var networkURL: URL { rootURL.appendingPathComponent("network") }
    private var screenshotsURL: URL { rootURL.appendingPathComponent("screenshots") }
    private var debugURL: URL { rootURL.appendingPathComponent("debug") }
    private var stateURL: URL { rootURL.appendingPathComponent("state") }
    private var flowsURL: URL { rootURL.appendingPathComponent("flows") }
    private var backupsURL: URL { rootURL.appendingPathComponent("backups") }

    private var allDirectories: [URL] {
        [rootURL, configURL, credentialsURL, cardsURL, networkURL, screenshotsURL, debugURL, stateURL, flowsURL, backupsURL]
    }

    private var lastSaveDate: Date?
    private let minSaveInterval: TimeInterval = 5

    init() {
        ensureDirectoryStructure()
    }

    private func ensureDirectoryStructure() {
        for dir in allDirectories {
            if !fileManager.fileExists(atPath: dir.path) {
                try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }

    // MARK: - Full State Save

    private var isSaving: Bool = false

    @MainActor func saveFullState() {
        if let last = lastSaveDate, Date().timeIntervalSince(last) < minSaveInterval { return }
        guard !isSaving else { return }
        lastSaveDate = Date()
        isSaving = true

        DebugLogger.logBackground("PersistentStorage: starting full state save", category: .persistence, level: .info)

        let configJSON = AppDataExportService.shared.exportJSON()
        let creds = LoginPersistenceService.shared.loadCredentials()
        let cards = PPSRPersistenceService.shared.loadCards()
        let flows = FlowPersistenceService.shared.loadFlows()
        let automationData = UserDefaults.standard.data(forKey: "automation_settings_v1")
        let logEntries = DebugLogger.shared.entries
        let proxyService = ProxyRotationService.shared
        let dnsService = PPSRDoHService.shared
        let urlService = LoginURLRotationService.shared

        var networkState = NetworkFileState()
        networkState.joeURLCount = urlService.joeURLs.count
        networkState.ignitionURLCount = urlService.ignitionURLs.count
        networkState.joeEnabledURLCount = urlService.joeURLs.filter(\.isEnabled).count
        networkState.ignitionEnabledURLCount = urlService.ignitionURLs.filter(\.isEnabled).count
        networkState.joeProxyCount = proxyService.savedProxies.count
        networkState.ignitionProxyCount = proxyService.ignitionProxies.count
        networkState.ppsrProxyCount = proxyService.ppsrProxies.count
        networkState.joeWGCount = proxyService.joeWGConfigs.count
        networkState.ignitionWGCount = proxyService.ignitionWGConfigs.count
        networkState.ppsrWGCount = proxyService.ppsrWGConfigs.count
        networkState.joeVPNCount = proxyService.joeVPNConfigs.count
        networkState.ignitionVPNCount = proxyService.ignitionVPNConfigs.count
        networkState.ppsrVPNCount = proxyService.ppsrVPNConfigs.count
        networkState.dnsCount = dnsService.managedProviders.count
        networkState.joeConnectionMode = proxyService.joeConnectionMode.rawValue
        networkState.ignitionConnectionMode = proxyService.ignitionConnectionMode.rawValue
        networkState.ppsrConnectionMode = proxyService.ppsrConnectionMode.rawValue
        networkState.networkRegion = proxyService.networkRegion.rawValue
        networkState.savedAt = Date().timeIntervalSince1970

        var appState = AppStateSnapshot()
        appState.activeAppMode = UserDefaults.standard.string(forKey: "activeAppMode") ?? ""
        appState.hasSelectedMode = UserDefaults.standard.bool(forKey: "hasSelectedMode")
        appState.productMode = UserDefaults.standard.string(forKey: "productMode") ?? ""
        appState.defaultSettingsApplied = UserDefaults.standard.bool(forKey: "default_settings_applied_v2")
        appState.savedAt = Date().timeIntervalSince1970
        appState.appVersion = currentAppVersion
        appState.buildNumber = currentBuildNumber

        let configDir = configURL
        let credDir = credentialsURL
        let cardDir = cardsURL
        let netDir = networkURL
        let dbgDir = debugURL
        let stDir = stateURL
        let flDir = flowsURL
        let ssDir = screenshotsURL
        let ts = fileTimestamp

        let credEntries = creds.map { cred in
            CredentialFileEntry(
                id: cred.id, username: cred.username, password: cred.password,
                status: cred.status.rawValue, addedAt: cred.addedAt.timeIntervalSince1970,
                notes: cred.notes, totalTests: cred.totalTests, successCount: cred.successCount,
                assignedPasswords: cred.assignedPasswords, nextPasswordIndex: cred.nextPasswordIndex
            )
        }
        let workingText = creds.filter { $0.isWorking }.map { $0.exportFormat }.joined(separator: "\n")
        let cardEntries = cards.map { card in
            CardFileEntry(
                id: card.id, number: card.number, brand: card.brand.rawValue,
                status: card.status.rawValue, addedAt: card.addedAt.timeIntervalSince1970,
                totalTests: card.testResults.count, successCount: card.testResults.filter(\.success).count
            )
        }

        Task.detached(priority: .utility) { [credEntries, workingText, cardEntries, flows, automationData, logEntries, networkState, appState, configJSON] in
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted

            try? configJSON.data(using: .utf8)?.write(to: configDir.appendingPathComponent("full_config.json"))
            try? configJSON.data(using: .utf8)?.write(to: configDir.appendingPathComponent("config_\(ts).json"))

            if !credEntries.isEmpty {
                if let data = try? JSONEncoder().encode(credEntries) {
                    try? data.write(to: credDir.appendingPathComponent("credentials.json"))
                }
                try? workingText.data(using: .utf8)?.write(to: credDir.appendingPathComponent("working.txt"))
            }

            if !cardEntries.isEmpty {
                if let data = try? JSONEncoder().encode(cardEntries) {
                    try? data.write(to: cardDir.appendingPathComponent("cards.json"))
                }
            }

            if let data = try? encoder.encode(networkState) {
                try? data.write(to: netDir.appendingPathComponent("network_state.json"))
            }

            if let aData = automationData {
                try? aData.write(to: configDir.appendingPathComponent("automation_settings.json"))
            }

            let recentErrors = logEntries.filter { $0.level >= .error }.prefix(500)
            let errorLines = recentErrors.map { "[\($0.level.rawValue)] [\($0.category.rawValue)] \(DateFormatters.fullTimestamp.string(from: $0.timestamp)) \($0.message)" }
            try? errorLines.joined(separator: "\n").data(using: .utf8)?.write(to: dbgDir.appendingPathComponent("errors.log"))

            let recentAll = logEntries.prefix(2000)
            let allLines = recentAll.map { "[\($0.level.rawValue)] [\($0.category.rawValue)] \(DateFormatters.fullTimestamp.string(from: $0.timestamp)) \($0.message)" }
            try? allLines.joined(separator: "\n").data(using: .utf8)?.write(to: dbgDir.appendingPathComponent("full_log.log"))

            if !flows.isEmpty, let data = try? JSONEncoder().encode(flows) {
                try? data.write(to: flDir.appendingPathComponent("recorded_flows.json"))
            }

            if let data = try? encoder.encode(appState) {
                try? data.write(to: stDir.appendingPathComponent("app_state.json"))
            }

            let manifest = ScreenshotManifest(savedAt: Date().timeIntervalSince1970, note: "Screenshots are stored in-memory during runtime.")
            if let data = try? JSONEncoder().encode(manifest) {
                try? data.write(to: ssDir.appendingPathComponent("manifest.json"))
            }

            await MainActor.run {
                PersistentFileStorageService.shared.isSaving = false
                PersistentFileStorageService.shared.pruneOldFiles(in: configDir, prefix: "config_", keepCount: 5)
                DebugLogger.shared.log("PersistentStorage: full state save complete (background)", category: .persistence, level: .success)
            }
        }
    }

    @MainActor func forceSave() {
        lastSaveDate = nil
        saveFullState()
    }

    // MARK: - Full State Restore

    @MainActor func restoreIfNeeded() -> Bool {
        let markerFile = stateURL.appendingPathComponent("restore_marker.json")
        let configFile = configURL.appendingPathComponent("full_config.json")

        guard fileManager.fileExists(atPath: configFile.path) else {
            DebugLogger.logBackground("PersistentStorage: no saved state found — fresh install", category: .persistence, level: .info)
            return false
        }

        let hasExistingData = LoginPersistenceService.shared.loadCredentials().count > 0
            || PPSRPersistenceService.shared.loadCards().count > 0

        if hasExistingData {
            if fileManager.fileExists(atPath: markerFile.path),
               let data = try? Data(contentsOf: markerFile),
               let marker = try? JSONDecoder().decode(RestoreMarker.self, from: data),
               marker.appVersion == currentAppVersion {
                DebugLogger.logBackground("PersistentStorage: current version data exists — skipping restore", category: .persistence, level: .info)
                return false
            }
        }

        DebugLogger.logBackground("PersistentStorage: restoring saved state from vault", category: .persistence, level: .info)

        let restored = restoreFromVault()

        let marker = RestoreMarker(appVersion: currentAppVersion, restoredAt: Date())
        if let data = try? JSONEncoder().encode(marker) {
            try? data.write(to: markerFile)
        }

        return restored
    }

    @MainActor private func restoreFromVault() -> Bool {
        let configFile = configURL.appendingPathComponent("full_config.json")
        guard let data = try? Data(contentsOf: configFile),
              let json = String(data: data, encoding: .utf8) else {
            DebugLogger.logBackground("PersistentStorage: failed to read config file", category: .persistence, level: .error)
            return false
        }

        let result = AppDataExportService.shared.importJSON(json)
        DebugLogger.logBackground("PersistentStorage: restore complete — \(result.summary)", category: .persistence, level: .success)

        restoreAppState()
        restoreDebugLogs()

        return true
    }

    // MARK: - Config Snapshot (Comprehensive JSON)

    @MainActor private func saveConfigSnapshot() {
        let json = AppDataExportService.shared.exportJSON()
        let file = configURL.appendingPathComponent("full_config.json")
        try? json.data(using: .utf8)?.write(to: file)

        let timestamped = configURL.appendingPathComponent("config_\(fileTimestamp).json")
        try? json.data(using: .utf8)?.write(to: timestamped)

        pruneOldFiles(in: configURL, prefix: "config_", keepCount: 5)
    }

    // MARK: - Credentials

    @MainActor private func saveCredentials() {
        let creds = LoginPersistenceService.shared.loadCredentials()
        guard !creds.isEmpty else { return }

        let exportable = creds.map { cred -> CredentialFileEntry in
            CredentialFileEntry(
                id: cred.id,
                username: cred.username,
                password: cred.password,
                status: cred.status.rawValue,
                addedAt: cred.addedAt.timeIntervalSince1970,
                notes: cred.notes,
                totalTests: cred.totalTests,
                successCount: cred.successCount,
                assignedPasswords: cred.assignedPasswords,
                nextPasswordIndex: cred.nextPasswordIndex
            )
        }

        let file = credentialsURL.appendingPathComponent("credentials.json")
        if let data = try? JSONEncoder().encode(exportable) {
            try? data.write(to: file)
        }

        let workingFile = credentialsURL.appendingPathComponent("working.txt")
        let working = creds.filter { $0.isWorking }.map { $0.exportFormat }.joined(separator: "\n")
        try? working.data(using: .utf8)?.write(to: workingFile)

        let allFile = credentialsURL.appendingPathComponent("all_credentials.txt")
        let all = creds.map { "\($0.exportFormat) | \($0.status.rawValue)" }.joined(separator: "\n")
        try? all.data(using: .utf8)?.write(to: allFile)
    }

    // MARK: - Cards

    @MainActor private func saveCards() {
        let cards = PPSRPersistenceService.shared.loadCards()
        guard !cards.isEmpty else { return }

        let exportable = cards.map { card -> CardFileEntry in
            CardFileEntry(
                id: card.id,
                number: card.number,
                brand: card.brand.rawValue,
                status: card.status.rawValue,
                addedAt: card.addedAt.timeIntervalSince1970,
                totalTests: card.testResults.count,
                successCount: card.testResults.filter(\.success).count
            )
        }

        let file = cardsURL.appendingPathComponent("cards.json")
        if let data = try? JSONEncoder().encode(exportable) {
            try? data.write(to: file)
        }
    }

    // MARK: - Network

    @MainActor private func saveNetworkConfigs() {
        let proxyService = ProxyRotationService.shared
        let dnsService = PPSRDoHService.shared
        let urlService = LoginURLRotationService.shared

        var networkState = NetworkFileState()
        networkState.joeURLCount = urlService.joeURLs.count
        networkState.ignitionURLCount = urlService.ignitionURLs.count
        networkState.joeEnabledURLCount = urlService.joeURLs.filter(\.isEnabled).count
        networkState.ignitionEnabledURLCount = urlService.ignitionURLs.filter(\.isEnabled).count
        networkState.joeProxyCount = proxyService.savedProxies.count
        networkState.ignitionProxyCount = proxyService.ignitionProxies.count
        networkState.ppsrProxyCount = proxyService.ppsrProxies.count
        networkState.joeWGCount = proxyService.joeWGConfigs.count
        networkState.ignitionWGCount = proxyService.ignitionWGConfigs.count
        networkState.ppsrWGCount = proxyService.ppsrWGConfigs.count
        networkState.joeVPNCount = proxyService.joeVPNConfigs.count
        networkState.ignitionVPNCount = proxyService.ignitionVPNConfigs.count
        networkState.ppsrVPNCount = proxyService.ppsrVPNConfigs.count
        networkState.dnsCount = dnsService.managedProviders.count
        networkState.joeConnectionMode = proxyService.joeConnectionMode.rawValue
        networkState.ignitionConnectionMode = proxyService.ignitionConnectionMode.rawValue
        networkState.ppsrConnectionMode = proxyService.ppsrConnectionMode.rawValue
        networkState.networkRegion = proxyService.networkRegion.rawValue
        networkState.savedAt = Date().timeIntervalSince1970

        let file = networkURL.appendingPathComponent("network_state.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(networkState) {
            try? data.write(to: file)
        }
    }

    // MARK: - Automation Settings

    private func saveAutomationSettings() {
        guard let data = UserDefaults.standard.data(forKey: "automation_settings_v1") else { return }
        let file = configURL.appendingPathComponent("automation_settings.json")
        try? data.write(to: file)
    }

    // MARK: - Debug Logs

    @MainActor private func saveDebugLogs() {
        let entries = DebugLogger.shared.entries

        let recentErrors = entries.filter { $0.level >= .error }.prefix(500)
        let errorLines = recentErrors.map { "[\($0.level.rawValue)] [\($0.category.rawValue)] \(DateFormatters.fullTimestamp.string(from: $0.timestamp)) \($0.message)" }
        let errorFile = debugURL.appendingPathComponent("errors.log")
        try? errorLines.joined(separator: "\n").data(using: .utf8)?.write(to: errorFile)

        let recentAll = entries.prefix(2000)
        let allLines = recentAll.map { "[\($0.level.rawValue)] [\($0.category.rawValue)] \(DateFormatters.fullTimestamp.string(from: $0.timestamp)) \($0.message)" }
        let allFile = debugURL.appendingPathComponent("full_log.log")
        try? allLines.joined(separator: "\n").data(using: .utf8)?.write(to: allFile)

        let diagnosticReport = DebugLogger.shared.exportDiagnosticReport()
        let diagFile = debugURL.appendingPathComponent("diagnostic_\(fileTimestamp).log")
        try? diagnosticReport.data(using: .utf8)?.write(to: diagFile)
        pruneOldFiles(in: debugURL, prefix: "diagnostic_", keepCount: 10)
    }

    private func restoreDebugLogs() {
        DebugLogger.logBackground("PersistentStorage: debug logs restored from vault", category: .persistence, level: .info)
    }

    // MARK: - Recorded Flows

    @MainActor private func saveRecordedFlows() {
        let flows = FlowPersistenceService.shared.loadFlows()
        guard !flows.isEmpty else { return }
        if let data = try? JSONEncoder().encode(flows) {
            let file = flowsURL.appendingPathComponent("recorded_flows.json")
            try? data.write(to: file)
        }
    }

    // MARK: - App State (UserDefaults keys & AppStorage)

    private func saveAppState() {
        var state = AppStateSnapshot()
        state.activeAppMode = UserDefaults.standard.string(forKey: "activeAppMode") ?? ""
        state.hasSelectedMode = UserDefaults.standard.bool(forKey: "hasSelectedMode")
        state.productMode = UserDefaults.standard.string(forKey: "productMode") ?? ""
        state.defaultSettingsApplied = UserDefaults.standard.bool(forKey: "default_settings_applied_v2")
        state.savedAt = Date().timeIntervalSince1970
        state.appVersion = currentAppVersion
        state.buildNumber = currentBuildNumber

        let file = stateURL.appendingPathComponent("app_state.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(state) {
            try? data.write(to: file)
        }
    }

    private func restoreAppState() {
        let file = stateURL.appendingPathComponent("app_state.json")
        guard let data = try? Data(contentsOf: file),
              let state = try? JSONDecoder().decode(AppStateSnapshot.self, from: data) else { return }

        if !state.activeAppMode.isEmpty {
            UserDefaults.standard.set(state.activeAppMode, forKey: "activeAppMode")
        }
        if state.defaultSettingsApplied {
            UserDefaults.standard.set(true, forKey: "default_settings_applied_v2")
        }
    }

    // MARK: - Screenshot Manifest

    private func saveScreenshotManifest() {
        let manifest = ScreenshotManifest(
            savedAt: Date().timeIntervalSince1970,
            note: "Screenshots are stored in-memory during runtime. This manifest tracks the last save time."
        )
        let file = screenshotsURL.appendingPathComponent("manifest.json")
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: file)
        }
    }

    func saveScreenshot(_ image: UIImage, name: String) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        let sanitized = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let file = screenshotsURL.appendingPathComponent("\(sanitized)_\(fileTimestamp).jpg")
        try? data.write(to: file)
        pruneOldFiles(in: screenshotsURL, prefix: "", keepCount: 200, extension: "jpg")
    }

    // MARK: - Manual Backup

    @MainActor func createBackup() -> URL? {
        forceSave()

        let backupName = "backup_\(fileTimestamp).json"
        let json = AppDataExportService.shared.exportJSON()
        let file = backupsURL.appendingPathComponent(backupName)

        guard let data = json.data(using: .utf8) else { return nil }
        do {
            try data.write(to: file)
            pruneOldFiles(in: backupsURL, prefix: "backup_", keepCount: 10)
            DebugLogger.logBackground("PersistentStorage: manual backup created — \(backupName)", category: .persistence, level: .success)
            return file
        } catch {
            let nsError = error as NSError
            var components: [String] = []
            components.append("[\(nsError.domain):\(nsError.code)] \(nsError.localizedDescription)")

            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                components.append("Underlying: [\(underlying.domain):\(underlying.code)] \(underlying.localizedDescription)")
            }

            let metadataPairs = nsError.userInfo
                .filter { $0.key != NSUnderlyingErrorKey }
                .map { "\($0.key)=\($0.value)" }

            if !metadataPairs.isEmpty {
                components.append("metadata: \(metadataPairs.joined(separator: ", "))")
            }

            let message = "PersistentStorage: backup creation failed — " + components.joined(separator: " | ")
            DebugLogger.logBackground(message, category: .persistence, level: .error)
            return nil
        }
    }

    func listBackups() -> [StoredFileInfo] {
        listFiles(in: backupsURL)
    }

    // MARK: - File Browser Data

    func getStorageSummary() -> StorageSummary {
        var summary = StorageSummary()
        summary.configFiles = listFiles(in: configURL)
        summary.credentialFiles = listFiles(in: credentialsURL)
        summary.cardFiles = listFiles(in: cardsURL)
        summary.networkFiles = listFiles(in: networkURL)
        summary.screenshotFiles = listFiles(in: screenshotsURL)
        summary.debugFiles = listFiles(in: debugURL)
        summary.stateFiles = listFiles(in: stateURL)
        summary.flowFiles = listFiles(in: flowsURL)
        summary.backupFiles = listFiles(in: backupsURL)
        summary.totalSize = calculateDirectorySize(rootURL)
        summary.lastSaved = lastSaveTimestamp()
        return summary
    }

    func listFiles(in directory: URL) -> [StoredFileInfo] {
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return [] }

        return contents.compactMap { url -> StoredFileInfo? in
            guard !url.hasDirectoryPath else { return nil }
            let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return StoredFileInfo(
                name: url.lastPathComponent,
                path: url.path,
                size: Int64(attrs?.fileSize ?? 0),
                modified: attrs?.contentModificationDate ?? Date(),
                url: url
            )
        }
        .sorted { $0.modified > $1.modified }
    }

    func readFileContent(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    func deleteFile(_ url: URL) -> Bool {
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    func shareFile(_ url: URL) -> URL { url }

    // MARK: - Helpers

    private var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var currentBuildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private var fileTimestamp: String {
        DateFormatters.fileStamp.string(from: Date())
    }

    private func lastSaveTimestamp() -> Date? {
        let configFile = configURL.appendingPathComponent("full_config.json")
        let attrs = try? fileManager.attributesOfItem(atPath: configFile.path)
        return attrs?[.modificationDate] as? Date
    }

    private func calculateDirectorySize(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    private func pruneOldFiles(in directory: URL, prefix: String, keepCount: Int, extension ext: String? = nil) {
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }

        let matching = contents.filter { url in
            let name = url.lastPathComponent
            let matchesPrefix = prefix.isEmpty || name.hasPrefix(prefix)
            let matchesExt = ext == nil || url.pathExtension == ext
            return matchesPrefix && matchesExt && !url.hasDirectoryPath
        }
        .sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return aDate > bDate
        }

        if matching.count > keepCount {
            for file in matching.dropFirst(keepCount) {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}

// MARK: - File Data Models

nonisolated struct RestoreMarker: Codable, Sendable {
    let appVersion: String
    let restoredAt: Date
}

nonisolated struct CredentialFileEntry: Codable, Sendable {
    let id: String
    let username: String
    let password: String
    let status: String
    let addedAt: TimeInterval
    let notes: String
    let totalTests: Int
    let successCount: Int
    let assignedPasswords: [String]
    let nextPasswordIndex: Int
}

nonisolated struct CardFileEntry: Codable, Sendable {
    let id: String
    let number: String
    let brand: String
    let status: String
    let addedAt: TimeInterval
    let totalTests: Int
    let successCount: Int
}

nonisolated struct NetworkFileState: Codable, Sendable {
    var joeURLCount: Int = 0
    var ignitionURLCount: Int = 0
    var joeEnabledURLCount: Int = 0
    var ignitionEnabledURLCount: Int = 0
    var joeProxyCount: Int = 0
    var ignitionProxyCount: Int = 0
    var ppsrProxyCount: Int = 0
    var joeWGCount: Int = 0
    var ignitionWGCount: Int = 0
    var ppsrWGCount: Int = 0
    var joeVPNCount: Int = 0
    var ignitionVPNCount: Int = 0
    var ppsrVPNCount: Int = 0
    var dnsCount: Int = 0
    var joeConnectionMode: String = ""
    var ignitionConnectionMode: String = ""
    var ppsrConnectionMode: String = ""
    var networkRegion: String = ""
    var savedAt: TimeInterval = 0
}

nonisolated struct AppStateSnapshot: Codable, Sendable {
    var activeAppMode: String = ""
    var hasSelectedMode: Bool = false
    var productMode: String = ""
    var defaultSettingsApplied: Bool = false
    var savedAt: TimeInterval = 0
    var appVersion: String = ""
    var buildNumber: String = ""
}

nonisolated struct ScreenshotManifest: Codable, Sendable {
    let savedAt: TimeInterval
    let note: String
}

struct StoredFileInfo: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int64
    let modified: Date
    let url: URL

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var formattedDate: String {
        DateFormatters.mediumDateTime.string(from: modified)
    }

    var fileExtension: String {
        url.pathExtension.lowercased()
    }

    var icon: String {
        switch fileExtension {
        case "json": "doc.text.fill"
        case "log": "doc.plaintext.fill"
        case "txt": "doc.fill"
        case "jpg", "jpeg", "png": "photo.fill"
        default: "doc.fill"
        }
    }
}

struct StorageSummary {
    var configFiles: [StoredFileInfo] = []
    var credentialFiles: [StoredFileInfo] = []
    var cardFiles: [StoredFileInfo] = []
    var networkFiles: [StoredFileInfo] = []
    var screenshotFiles: [StoredFileInfo] = []
    var debugFiles: [StoredFileInfo] = []
    var stateFiles: [StoredFileInfo] = []
    var flowFiles: [StoredFileInfo] = []
    var backupFiles: [StoredFileInfo] = []
    var totalSize: Int64 = 0
    var lastSaved: Date?

    var totalFileCount: Int {
        configFiles.count + credentialFiles.count + cardFiles.count + networkFiles.count + screenshotFiles.count + debugFiles.count + stateFiles.count + flowFiles.count + backupFiles.count
    }

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    var sections: [(title: String, icon: String, color: String, files: [StoredFileInfo])] {
        [
            ("Configuration", "gearshape.fill", "blue", configFiles),
            ("Credentials", "person.badge.key.fill", "green", credentialFiles),
            ("Cards", "creditcard.fill", "cyan", cardFiles),
            ("Network", "network", "orange", networkFiles),
            ("Screenshots", "camera.fill", "purple", screenshotFiles),
            ("Debug Logs", "doc.text.magnifyingglass", "red", debugFiles),
            ("App State", "cpu", "indigo", stateFiles),
            ("Recorded Flows", "record.circle.fill", "pink", flowFiles),
            ("Backups", "arrow.clockwise.icloud.fill", "teal", backupFiles),
        ]
    }
}
