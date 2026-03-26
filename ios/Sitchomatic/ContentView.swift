import SwiftUI

struct ContentView: View {
    @State private var vm = PPSRAutomationViewModel.shared
    @State private var selectedTab: AppTab = .dashboard

    nonisolated enum AppTab: String, Sendable {
        case dashboard, savedCards, workingCards, sessions, settings
    }

    private var settingsHash: String {
        "\(vm.appearanceMode.rawValue)-\(vm.testEmail)-\(vm.debugMode)-\(vm.maxConcurrency)-\(vm.useEmailRotation)-\(vm.stealthEnabled)-\(vm.retrySubmitOnFail)-\(vm.autoRetryEnabled)-\(vm.autoRetryMaxAttempts)"
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Dashboard", systemImage: "bolt.shield.fill", value: .dashboard) {
                NavigationStack {
                    VStack(spacing: 0) {
                        UnifiedIPBannerView()
                        LoginDashboardView(vm: vm)
                            .withPPSRCardNavigation(cards: vm.cards, vm: vm)
                    }
                }
                .withMainMenuButton()
            }

            Tab("Cards", systemImage: "creditcard.fill", value: .savedCards) {
                NavigationStack {
                    SavedCredentialsView(vm: vm)
                        .withPPSRCardNavigation(cards: vm.cards, vm: vm)
                }
                .withMainMenuButton()
            }

            Tab("Working", systemImage: "checkmark.shield.fill", value: .workingCards) {
                NavigationStack {
                    WorkingLoginsView(vm: vm)
                        .withPPSRCardNavigation(cards: vm.cards, vm: vm)
                }
                .withMainMenuButton()
            }

            Tab("Sessions", systemImage: "rectangle.stack", value: .sessions) {
                NavigationStack {
                    LoginSessionMonitorView(vm: vm)
                }
                .withMainMenuButton()
            }

            Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                NavigationStack {
                    PPSRSettingsView(vm: vm)
                }
                .withMainMenuButton()
            }
        }
        .tint(.teal)
        .preferredColorScheme(vm.appearanceMode.colorScheme)
        .onChange(of: settingsHash) { _, _ in
            vm.persistSettings()
        }
        .withBatchAlerts(
            showBatchResult: $vm.showBatchResultPopup,
            batchResult: vm.lastBatchResult,
            isRunning: $vm.isRunning,
            onDismissBatch: { vm.showBatchResultPopup = false }
        )
    }
}
