import Foundation
import SwiftUI

@MainActor
class LoginSettingsManager {
    var debugMode: Bool = false
    var stealthEnabled: Bool = true
    var targetSite: LoginTargetSite = .joefortune
    var appearanceMode: AppAppearanceMode = .dark
    var testTimeout: TimeInterval = 90
    var maxConcurrency: Int = 8
    var savedCropRect: CGRect? = nil
    var automationSettings: AutomationSettings = AutomationSettings()
    var doubleSiteMode: Bool = false
    var siteMode: LoginViewModel.SiteMode = .joe

    let urlRotation = LoginURLRotationService.shared

    private let persistence = LoginPersistenceService.shared
    private var settingsSaveTask: Task<Void, Never>?
    private let automationSettingsKey = "automation_settings_v1"
    var onLog: ((String, PPSRLogEntry.Level) -> Void)?

    var isIgnitionMode: Bool {
        get { urlRotation.isIgnitionMode }
        set {
            urlRotation.isIgnitionMode = newValue
            targetSite = newValue ? .ignition : .joefortune
            persistSettings()
        }
    }

    var effectiveColorScheme: ColorScheme? {
        if isIgnitionMode { return .dark }
        return appearanceMode.colorScheme
    }

    func setSiteMode(_ mode: LoginViewModel.SiteMode) {
        siteMode = mode
        switch mode {
        case .joe:
            isIgnitionMode = false
            doubleSiteMode = false
        case .double:
            doubleSiteMode = true
        case .ignition:
            isIgnitionMode = true
            doubleSiteMode = false
        }
        persistSettings()
    }

    func loadPersistedSettings() {
        if let settings = persistence.loadSettings() {
            if let site = LoginTargetSite(rawValue: settings.targetSite) {
                targetSite = site
            }
            maxConcurrency = settings.maxConcurrency
            debugMode = settings.debugMode
            if let mode = AppAppearanceMode(rawValue: settings.appearanceMode) {
                appearanceMode = mode
            }
            stealthEnabled = settings.stealthEnabled
            testTimeout = max(settings.testTimeout, AutomationSettings.minimumTimeoutSeconds)
        }
        loadCropRect()
        loadAutomationSettings()
    }

    func persistSettings() {
        settingsSaveTask?.cancel()
        settingsSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            persistence.saveSettings(
                targetSite: targetSite.rawValue,
                maxConcurrency: maxConcurrency,
                debugMode: debugMode,
                appearanceMode: appearanceMode.rawValue,
                stealthEnabled: stealthEnabled,
                testTimeout: testTimeout
            )
        }
    }

    func persistAutomationSettings() {
        automationSettings = automationSettings.normalizedTimeouts()
        PPSRStealthService.shared.applySettings(automationSettings)
        if let data = try? JSONEncoder().encode(automationSettings) {
            UserDefaults.standard.set(data, forKey: automationSettingsKey)
        }
    }

    func loadAutomationSettings() {
        if let data = UserDefaults.standard.data(forKey: automationSettingsKey),
           let loaded = try? JSONDecoder().decode(AutomationSettings.self, from: data) {
            automationSettings = loaded.normalizedTimeouts()
        }
        PPSRStealthService.shared.applySettings(automationSettings)
    }

    func flowAssignment(for urlString: String) -> URLFlowAssignment? {
        automationSettings.urlFlowAssignments.first { assignment in
            urlString.localizedStandardContains(assignment.urlPattern) ||
            assignment.urlPattern.localizedStandardContains(urlString)
        }
    }

    func saveCropRect(_ rect: CGRect) {
        savedCropRect = rect
        let dict: [String: Double] = [
            "x": rect.origin.x,
            "y": rect.origin.y,
            "w": rect.size.width,
            "h": rect.size.height,
        ]
        UserDefaults.standard.set(dict, forKey: "login_crop_rect_v1")
        onLog?("Saved crop region: \(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height))", .info)
    }

    func clearCropRect() {
        savedCropRect = nil
        UserDefaults.standard.removeObject(forKey: "login_crop_rect_v1")
        onLog?("Cleared crop region", .info)
    }

    private func loadCropRect() {
        guard let dict = UserDefaults.standard.dictionary(forKey: "login_crop_rect_v1"),
              let x = dict["x"] as? Double,
              let y = dict["y"] as? Double,
              let w = dict["w"] as? Double,
              let h = dict["h"] as? Double else { return }
        savedCropRect = CGRect(x: x, y: y, width: w, height: h)
    }

    func getNextTestURL() -> URL {
        if let rotatedURL = urlRotation.nextURL() {
            return rotatedURL
        }
        return targetSite.url
    }

    func getNextTestURL(forSite site: LoginTargetSite) -> URL {
        let wasIgnition = urlRotation.isIgnitionMode
        urlRotation.isIgnitionMode = (site == .ignition)
        let url = urlRotation.nextURL() ?? site.url
        urlRotation.isIgnitionMode = wasIgnition
        return url
    }
}
