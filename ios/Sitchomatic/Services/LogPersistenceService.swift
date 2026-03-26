import Foundation
import UIKit

@MainActor
class LogPersistenceService {
    private let criticalLogKey = "debug_critical_logs_v1"

    let persistentLogURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("debug_log_latest.txt")
    }()

    let logArchiveDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("LogArchive", isDirectory: true)
    }()

    private var diskFlushTask: Task<Void, Never>?

    init() {
        try? FileManager.default.createDirectory(at: logArchiveDirectory, withIntermediateDirectories: true)
    }

    func persistLatestLog(entries: [DebugLogEntry], totalLogged: Int, errorCount: Int, warningCount: Int) {
        let tail = Array(entries.prefix(1000))
        guard !tail.isEmpty else { return }
        let lines = tail.reversed().map(\.exportLine).joined(separator: "\n")
        let header = "=== PERSISTED DEBUG LOG (last \(tail.count) entries) ===\nTimestamp: \(DateFormatters.fullTimestamp.string(from: Date()))\nTotal logged: \(totalLogged) | In-memory: \(entries.count) | Errors: \(errorCount) | Warnings: \(warningCount)\n===\n\n"
        try? (header + lines).write(to: persistentLogURL, atomically: true, encoding: .utf8)
    }

    func loadPersistedLatestLog() -> String {
        (try? String(contentsOf: persistentLogURL, encoding: .utf8)) ?? "No persisted log found."
    }

    func persistCriticalEntries(entries: [DebugLogEntry]) {
        let criticals = Array(entries.filter { $0.level >= .error }.prefix(200))
        if let data = try? JSONEncoder().encode(criticals) {
            UserDefaults.standard.set(data, forKey: criticalLogKey)
        }
    }

    func loadPersistedCriticalLogs() -> [DebugLogEntry] {
        guard let data = UserDefaults.standard.data(forKey: criticalLogKey) else { return [] }
        return (try? JSONDecoder().decode([DebugLogEntry].self, from: data)) ?? []
    }

    func scheduleDiskFlush(entries evicted: [DebugLogEntry]) {
        guard diskFlushTask == nil else { return }
        let toFlush = evicted
        let archiveDir = logArchiveDirectory
        diskFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            let lines = toFlush.map(\.exportLine).joined(separator: "\n")
            let fileName = "log_\(DateFormatters.fileStamp.string(from: Date())).txt"
            let fileURL = archiveDir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: fileURL.path()) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    handle.seekToEndOfFile()
                    if let data = ("\n" + lines).data(using: .utf8) { handle.write(data) }
                    handle.closeFile()
                }
            } else {
                try? lines.write(to: fileURL, atomically: true, encoding: .utf8)
            }
            self?.pruneArchiveFiles(in: archiveDir)
            self?.diskFlushTask = nil
        }
    }

    func flushAllToDisk(entries: [DebugLogEntry], totalLogged: Int, errorCount: Int, warningCount: Int) {
        let allLines = entries.reversed().map(\.exportLine).joined(separator: "\n")
        let fileName = "log_flush_\(DateFormatters.fileStamp.string(from: Date())).txt"
        let fileURL = logArchiveDirectory.appendingPathComponent(fileName)
        try? allLines.write(to: fileURL, atomically: true, encoding: .utf8)
        pruneArchiveFiles(in: logArchiveDirectory)
        persistLatestLog(entries: entries, totalLogged: totalLogged, errorCount: errorCount, warningCount: warningCount)
    }

    func loadArchivedLogFiles() -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logArchiveDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return files.filter { $0.pathExtension == "txt" }.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return aDate > bDate
        }
    }

    func loadArchivedEntries(from url: URL, limit: Int = 500) -> String {
        (try? String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").suffix(limit).joined(separator: "\n")) ?? ""
    }

    var archiveFileCount: Int { loadArchivedLogFiles().count }

    func exportLogToFile(content: String) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileName = "debug_log_\(DateFormatters.exportTimestamp.string(from: Date()).replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ":", with: "-")).txt"
        let fileURL = tempDir.appendingPathComponent(fileName)
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    func exportDiagnosticReportToFile(content: String) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileName = "diagnostic_report_\(DateFormatters.exportTimestamp.string(from: Date()).replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ":", with: "-")).txt"
        let fileURL = tempDir.appendingPathComponent(fileName)
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func pruneArchiveFiles(in directory: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let logFiles = files.filter { $0.pathExtension == "txt" }.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return aDate < bDate
        }
        let maxArchiveFiles = 20
        if logFiles.count > maxArchiveFiles {
            for file in logFiles.prefix(logFiles.count - maxArchiveFiles) {
                try? fm.removeItem(at: file)
            }
        }
    }
}
