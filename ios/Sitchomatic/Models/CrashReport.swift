import Foundation

nonisolated struct CrashReport: Codable, Sendable {
    let signal: String
    let memoryMB: Int
    let timestamp: TimeInterval
    let crashLog: String
    let diagnosticLog: String
    let iosVersion: String
    let deviceModel: String
    let appVersion: String
    let screenshotKeys: [String]

    var formattedReport: String {
        let crashDate = Date(timeIntervalSince1970: timestamp)
        return """
        ========================================
        CRASH REPORT FOR RORK
        ========================================
        Signal: \(signal)
        Memory at Crash: \(memoryMB)MB
        Crash Time: \(crashDate)
        iOS Version: \(iosVersion)
        Device: \(deviceModel)
        App Version: \(appVersion)
        Screenshots Preserved: \(screenshotKeys.count)

        === CRASH LOG ===
        \(crashLog)

        === PRE-CRASH DIAGNOSTICS ===
        \(diagnosticLog)
        ========================================
        END OF CRASH REPORT
        ========================================
        """
    }
}
