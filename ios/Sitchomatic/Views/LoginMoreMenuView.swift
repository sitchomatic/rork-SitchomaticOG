import SwiftUI

struct LoginMoreMenuView: View {
    let vm: LoginViewModel
    private let proxyService = ProxyRotationService.shared

    var body: some View {
        List {
            connectionModeSection
            aiInsightsSection
            automationToolsSection
            urlsAndEndpointSection
            advancedSettingsSection
            accountToolsSection
            dataSection
            debugSection
            settingsAndTestingLinkSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("More")
    }

    private var aiInsightsSection: some View {
        Section {
            NavigationLink {
                AICustomToolsDashboardView()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.indigo.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.body)
                            .foregroundStyle(.indigo)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Custom AI Tools").font(.subheadline.bold())
                        Text("Run health, checkpoint verification, batch tuning")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let toolStats = AICustomToolsCoordinator.shared.stats()
                    if toolStats.totalExecutions > 0 {
                        Text("\(toolStats.totalExecutions)")
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(.indigo)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.indigo.opacity(0.12)).clipShape(Capsule())
                    }
                }
            }

            NavigationLink {
                AIInsightsDashboardView()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.teal.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "brain.head.profile.fill")
                            .font(.body)
                            .foregroundStyle(.teal)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI Insights").font(.subheadline.bold())
                        Text("Dashboard, health, detection patterns & AI analysis")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let mode = AIAntiDetectionAdaptiveService.shared.currentAdaptiveMode()
                    Text(mode.uppercased())
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(mode == "defensive" ? .red : mode == "cautious" ? .orange : .green)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((mode == "defensive" ? Color.red : mode == "cautious" ? Color.orange : Color.green).opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            NavigationLink {
                AIPatternDiscoveryDashboardView()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.purple.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "brain")
                            .font(.body)
                            .foregroundStyle(.purple)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pattern Discovery").font(.subheadline.bold())
                        Text("Best combos, time heatmaps, proxy trends & convergence")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let graphStats = AIReinforcementInteractionGraph.shared.hostStats()
                    let converged = graphStats.filter { $0.converged }.count
                    if !graphStats.isEmpty {
                        Text("\(converged)/\(graphStats.count)")
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.purple.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }
        } header: {
            Label("Intelligence", systemImage: "sparkles")
        } footer: {
            Text("AI-powered system health, detection patterns, credential insights, and optimization recommendations.")
        }
    }

    private var automationToolsSection: some View {
        Section {
            NavigationLink {
                AutomationToolsMenuView(vm: vm)
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.red.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.body)
                            .foregroundStyle(.red)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automation Tools").font(.subheadline.bold())
                        Text("Flow recorder, button detection, calibration")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let flowCount = FlowPersistenceService.shared.loadFlows().count
                    if flowCount > 0 {
                        Text("\(flowCount) flows")
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.red.opacity(0.12)).clipShape(Capsule())
                    }
                }
            }
        } header: {
            Label("Automation", systemImage: "gearshape.2.fill")
        } footer: {
            Text("Record flows, debug login buttons, and calibrate automation for specific sites.")
        }
    }

    private var urlsAndEndpointSection: some View {
        Section {
            NavigationLink {
                LoginNetworkSettingsView(vm: vm)
            } label: {
                moreRow(icon: "arrow.triangle.2.circlepath", title: "URLs & Endpoint", subtitle: "URL rotation, validation & connectivity", color: .green)
            }
        }
    }

    private var advancedSettingsSection: some View {
        Section {
            NavigationLink {
                LoginSettingsContentView(vm: vm)
            } label: {
                moreRow(icon: "gearshape.fill", title: "Advanced Settings", subtitle: "Stealth, concurrency, debug & more", color: .secondary)
            }
        }
    }

    private var accountToolsSection: some View {
        Section("Account Tools") {
            NavigationLink {
                CheckDisabledAccountsView(vm: vm)
            } label: {
                moreRow(icon: "magnifyingglass.circle.fill", title: "Check Disabled Accounts", subtitle: "Fast forgot-password check", color: .orange)
            }

            NavigationLink {
                TempDisabledAccountsView(vm: vm)
            } label: {
                moreRow(icon: "clock.badge.exclamationmark", title: "Temp Disabled Accounts", subtitle: "\(vm.tempDisabledCredentials.count) accounts", color: .orange)
            }
        }
    }

    private var dataSection: some View {
        Section("Data") {
            NavigationLink {
                BlacklistView(vm: vm)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "hand.raised.slash.fill")
                        .font(.title3).foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Blacklist").font(.subheadline.bold())
                        Text("\(vm.blacklistService.blacklistedEmails.count) blacklisted").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if vm.blacklistService.autoExcludeBlacklist {
                        Text("AUTO")
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.red.opacity(0.12)).clipShape(Capsule())
                    }
                }
            }

            NavigationLink {
                CredentialExportView(vm: vm)
            } label: {
                moreRow(icon: "square.and.arrow.up.fill", title: "Export Credentials", subtitle: "Text or CSV by category", color: .blue)
            }
        }
    }

    @ViewBuilder
    private var debugSection: some View {
        if vm.debugMode {
            Section("Debug") {
                NavigationLink {
                    LoginDebugScreenshotsView(vm: vm)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "ladybug.fill")
                            .font(.title3).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Debug Screenshots").font(.subheadline.bold())
                            Text("\(vm.debugScreenshots.count) screenshots captured").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !vm.debugScreenshots.isEmpty {
                            let passCount = vm.debugScreenshots.filter({ $0.effectiveResult == .markedPass }).count
                            let failCount = vm.debugScreenshots.filter({ $0.effectiveResult == .markedFail }).count
                            HStack(spacing: 4) {
                                if passCount > 0 {
                                    Text("\(passCount)").font(.system(.caption2, design: .monospaced, weight: .bold)).foregroundStyle(.green)
                                }
                                if failCount > 0 {
                                    Text("\(failCount)").font(.system(.caption2, design: .monospaced, weight: .bold)).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }

                NavigationLink {
                    SessionReplayDebuggerView(vm: vm)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "play.rectangle.on.rectangle.fill")
                            .font(.title3).foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Replay Debugger").font(.subheadline.bold())
                            Text("Step-by-step session timeline with screenshots & logs")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                NavigationLink {
                    TapHeatmapOverlayView(vm: vm)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "viewfinder.rectangular")
                            .font(.title3).foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tap Heatmap").font(.subheadline.bold())
                            Text("Vision field/button detection overlay on screenshots")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !vm.debugScreenshots.isEmpty {
                            Text("\(vm.debugScreenshots.count)")
                                .font(.system(.caption2, design: .monospaced, weight: .bold))
                                .foregroundStyle(.cyan)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.cyan.opacity(0.12)).clipShape(Capsule())
                        }
                    }
                }
            }
        }
    }

    private var settingsAndTestingLinkSection: some View {
        Section {
            Button {
                UserDefaults.standard.set(ActiveAppMode.settingsAndTesting.rawValue, forKey: "activeAppMode")
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "gearshape.2.fill")
                            .font(.body)
                            .foregroundStyle(.blue)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Settings & Testing").font(.subheadline.bold())
                        Text("Super Test, IP Score, Nord Config, Debug, Import/Export")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.forward.circle.fill")
                        .font(.title3).foregroundStyle(.blue)
                }
            }
        } header: {
            Label("Global", systemImage: "globe")
        } footer: {
            Text("Device-wide settings, testing tools, diagnostics, and data management.")
        }
    }

    private var connectionModeSection: some View {
        Section {
            Picker(selection: Binding(
                get: { proxyService.unifiedConnectionMode },
                set: { proxyService.setUnifiedConnectionMode($0) }
            )) {
                ForEach(ConnectionMode.allCases, id: \.self) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "network.badge.shield.half.filled").foregroundStyle(.blue)
                    Text("Connection Mode")
                }
            }
            .pickerStyle(.menu)
            .sensoryFeedback(.impact(weight: .medium), trigger: proxyService.unifiedConnectionMode)

            HStack(spacing: 10) {
                Image(systemName: proxyService.unifiedConnectionMode.icon)
                    .foregroundStyle(connectionModeColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Active Mode").font(.subheadline.bold())
                    Text("All targets use \(proxyService.unifiedConnectionMode.label)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(proxyService.unifiedConnectionMode.label)
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(connectionModeColor)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(connectionModeColor.opacity(0.12)).clipShape(Capsule())
            }
        } header: {
            HStack {
                Image(systemName: "network.badge.shield.half.filled")
                Text("Connection Mode")
                Spacer()
                Text(proxyService.unifiedConnectionMode.label)
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(connectionModeColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(connectionModeColor.opacity(0.12))
                    .clipShape(Capsule())
            }
        } footer: {
            Text("Switching modes applies globally to Joe Fortune, Ignition, and PPSR.")
        }
    }

    private var connectionModeColor: Color {
        switch proxyService.unifiedConnectionMode {
        case .direct: .green
        case .proxy: .blue
        case .openvpn: .indigo
        case .wireguard: .purple
        case .dns: .cyan
        case .nodeMaven: .teal
        case .hybrid: .mint
        }
    }

    private func moreRow(icon: String, title: String, subtitle: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
