import Foundation
import SwiftUI

@MainActor
class PPSRSettingsManager {
    var testEmail: String = "dev@test.ppsr.gov.au"
    var maxConcurrency: Int = 8
    var debugMode: Bool = true
    var appearanceMode: AppAppearanceMode = .dark
    var useEmailRotation: Bool = true
    var stealthEnabled: Bool = true
    var retrySubmitOnFail: Bool = false
    var screenshotCropRect: CGRect = .zero
    var testTimeout: TimeInterval = 90

    private let persistence = PPSRPersistenceService.shared
    private let emailRotation = PPSREmailRotationService.shared
    private var settingsSaveTask: Task<Void, Never>?
    var onLog: ((String, PPSRLogEntry.Level) -> Void)?

    func loadPersistedSettings() {
        if let settings = persistence.loadSettings() {
            testEmail = settings.email
            maxConcurrency = settings.maxConcurrency
            debugMode = settings.debugMode
            if let mode = AppAppearanceMode(rawValue: settings.appearanceMode) {
                appearanceMode = mode
            }
            useEmailRotation = settings.useEmailRotation
            stealthEnabled = settings.stealthEnabled
            retrySubmitOnFail = settings.retrySubmitOnFail
            if let rect = settings.screenshotCropRect {
                screenshotCropRect = rect
            }
        }
    }

    func persistSettings() {
        settingsSaveTask?.cancel()
        settingsSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            persistence.saveSettings(
                email: testEmail,
                maxConcurrency: maxConcurrency,
                debugMode: debugMode,
                appearanceMode: appearanceMode.rawValue,
                useEmailRotation: useEmailRotation,
                stealthEnabled: stealthEnabled,
                retrySubmitOnFail: retrySubmitOnFail,
                screenshotCropRect: screenshotCropRect
            )
        }
    }

    func resolveEmail() -> String {
        if useEmailRotation, let rotated = emailRotation.nextEmail() {
            return rotated
        }
        return testEmail
    }

    func importEmails(_ text: String) -> Int {
        let count = emailRotation.importFromCSV(text)
        onLog?("Imported \(count) emails for rotation", .success)
        return count
    }

    func clearRotationEmails() {
        emailRotation.clear()
        onLog?("Cleared email rotation list", .info)
    }

    func resetRotationEmailsToDefault() {
        emailRotation.resetToDefault()
        onLog?("Reset email list to default (\(emailRotation.count) emails)", .success)
    }

    var rotationEmailCount: Int { emailRotation.count }
    var rotationEmails: [String] { emailRotation.emails }
}
