import AppIntents
import SwiftUI

nonisolated struct CheckStatsIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Stats"
    static var description: IntentDescription = "View current card and credential statistics"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let stats = StatsTrackingService.shared
        let tested = stats.lifetimeTested
        let working = stats.lifetimeWorking
        let dead = stats.lifetimeDead
        let rate = stats.lifetimeSuccessRate

        let message = "Lifetime: \(tested) tested, \(working) working, \(dead) dead. Success rate: \(String(format: "%.0f%%", rate * 100))."
        return .result(dialog: "\(message)")
    }
}

nonisolated struct OpenPPSRModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Open PPSR Mode"
    static var description: IntentDescription = "Open the PPSR card testing mode"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("ppsr", forKey: "activeAppMode")
        return .result()
    }
}

nonisolated struct OpenJoeModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Joe Mode"
    static var description: IntentDescription = "Open the Joe Fortune login testing mode"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("joe", forKey: "activeAppMode")
        return .result()
    }
}

nonisolated struct OpenIgnitionModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Ignition Mode"
    static var description: IntentDescription = "Open the Ignition Casino login testing mode"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("ignition", forKey: "activeAppMode")
        return .result()
    }
}

nonisolated struct OpenNordConfigIntent: AppIntent {
    static var title: LocalizedStringResource = "Open NordLynx Config"
    static var description: IntentDescription = "Open the NordLynx VPN config generator"
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("nordConfig", forKey: "activeAppMode")
        return .result()
    }
}

nonisolated struct DualModeAppShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckStatsIntent(),
            phrases: [
                "Check stats in \(.applicationName)",
                "Show \(.applicationName) statistics"
            ],
            shortTitle: "Check Stats",
            systemImageName: "chart.bar.fill"
        )
        AppShortcut(
            intent: OpenPPSRModeIntent(),
            phrases: [
                "Open PPSR in \(.applicationName)",
                "Start PPSR mode in \(.applicationName)"
            ],
            shortTitle: "Open PPSR",
            systemImageName: "bolt.shield.fill"
        )
        AppShortcut(
            intent: OpenJoeModeIntent(),
            phrases: [
                "Open Joe mode in \(.applicationName)"
            ],
            shortTitle: "Open Joe",
            systemImageName: "flame.fill"
        )
        AppShortcut(
            intent: OpenIgnitionModeIntent(),
            phrases: [
                "Open Ignition mode in \(.applicationName)"
            ],
            shortTitle: "Open Ignition",
            systemImageName: "flame.circle.fill"
        )
        AppShortcut(
            intent: OpenNordConfigIntent(),
            phrases: [
                "Open NordLynx in \(.applicationName)"
            ],
            shortTitle: "NordLynx Config",
            systemImageName: "network"
        )
    }
}
