import Foundation

@MainActor
class BatchPresetService {
    static let shared = BatchPresetService()

    private let storageKey = "batch_presets_v1"

    func savePresets(_ presets: [BatchPreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func loadPresets() -> [BatchPreset] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let presets = try? JSONDecoder().decode([BatchPreset].self, from: data) else {
            return defaultPresets()
        }
        return presets.map { preset in
            var normalized = preset
            normalized.testTimeout = TimeoutResolver.resolveAutomationTimeout(normalized.testTimeout)
            return normalized
        }
    }

    private func defaultPresets() -> [BatchPreset] {
        [
            BatchPreset(name: "Fast & Aggressive", maxConcurrency: 8, stealthEnabled: false, useEmailRotation: true, retrySubmitOnFail: false, testTimeout: 90),
            BatchPreset(name: "Slow & Stealthy", maxConcurrency: 2, stealthEnabled: true, useEmailRotation: true, retrySubmitOnFail: true, testTimeout: 120),
            BatchPreset(name: "Balanced", maxConcurrency: 4, stealthEnabled: true, useEmailRotation: false, retrySubmitOnFail: false, testTimeout: 90),
        ]
    }
}
