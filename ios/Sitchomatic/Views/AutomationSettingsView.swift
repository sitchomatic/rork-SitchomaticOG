import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum AutomationFileImportType {
    case vpn, wireGuard
}

struct AutomationSettingsView: View {
    @Bindable var vm: LoginViewModel
    @State private var showFlowAssignment: Bool = false
    @State private var showPatternReorder: Bool = false
    @State private var showButtonTextEditor: Bool = false
    @State private var showMFAKeywordEditor: Bool = false
    @State private var showCaptchaKeywordEditor: Bool = false
    @State private var showTemplates: Bool = false
    @State private var showSuccessMarkerEditor: Bool = false
    @State private var showTerminalKeywordEditor: Bool = false
    @State private var showErrorBannerEditor: Bool = false
    @State private var showCalibrationSheet: Bool = false
    @State private var calibrationURL: String = ""
    @State private var isAutoCalibrating: Bool = false
    @State private var autoCalibrationLog: [String] = []
    @State private var showProxyImport: Bool = false
    @State private var proxyBulkText: String = ""
    @State private var proxyImportReport: ProxyRotationService.ImportReport?
    @State private var isTestingProxies: Bool = false
    @State private var isTestingVPNConfigs: Bool = false
    @State private var isTestingWGConfigs: Bool = false
    @State private var activeFileImportType: AutomationFileImportType?

    private let calibrationService = LoginCalibrationService.shared
    private let proxyService = ProxyRotationService.shared

    private var accentColor: Color {
        vm.isIgnitionMode ? .orange : .green
    }

    @State private var autoSaveEnabled: Bool = true
    @State private var lastSaveTime: Date? = nil
    @State private var showSavedToast: Bool = false

    private var automationSettingsHash: String {
        (try? String(data: JSONEncoder().encode(vm.automationSettings), encoding: .utf8)) ?? ""
    }

    var body: some View {
        List {
            autoSaveSection
            templateQuickSection
            trueDetectionSection
            urlCalibrationSection
            pageLoadingSection
            fieldDetectionSection
            cookieConsentSection
            credentialEntrySection
            formInteractionSection
            fallbackButtonSection
            patternStrategySection
            submitBehaviorSection
            timeDelaysSection
            postSubmitEvalSection
            mfaHandlingSection
            captchaHandlingSection
            retryRequeueSection
            errorClassificationSection
            sessionManagementSection
            stealthSection
            humanSimulationSection
            viewportWindowSection
            screenshotDebugSection
            concurrencySection
            urlRotationSection
            blacklistSection
            flowAssignmentSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Automation Config")
        .onChange(of: automationSettingsHash) { _, _ in
            if autoSaveEnabled {
                vm.persistAutomationSettings()
                lastSaveTime = Date()
                withAnimation(.spring(duration: 0.3)) { showSavedToast = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    withAnimation { showSavedToast = false }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showSavedToast {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Auto-saved")
                        .font(.subheadline.bold())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.green.gradient, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $showTemplates) {
            NavigationStack { AutomationTemplateView(vm: vm) }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: $showFlowAssignment) {
            NavigationStack { URLFlowAssignmentView(vm: vm) }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: $showPatternReorder) {
            NavigationStack { PatternPriorityView(settings: $vm.automationSettings) }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: $showButtonTextEditor) {
            NavigationStack { KeywordListEditor(title: "Button Text Matches", keywords: $vm.automationSettings.loginButtonTextMatches) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: $showMFAKeywordEditor) {
            NavigationStack { KeywordListEditor(title: "MFA Keywords", keywords: $vm.automationSettings.mfaKeywords) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: $showCaptchaKeywordEditor) {
            NavigationStack { KeywordListEditor(title: "CAPTCHA Keywords", keywords: $vm.automationSettings.captchaKeywords) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: $showSuccessMarkerEditor) {
            NavigationStack { KeywordListEditor(title: "Success Markers", keywords: $vm.automationSettings.trueDetectionSuccessMarkers) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: $showTerminalKeywordEditor) {
            NavigationStack { KeywordListEditor(title: "Terminal Keywords", keywords: $vm.automationSettings.trueDetectionTerminalKeywords) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: $showErrorBannerEditor) {
            NavigationStack { KeywordListEditor(title: "Error Banner Selectors", keywords: $vm.automationSettings.trueDetectionErrorBannerSelectors) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: $showCalibrationSheet) {
            if !calibrationURL.isEmpty {
                LoginCalibrationView(urlString: calibrationURL) { cal in
                    vm.log("Calibration saved for \(cal.urlPattern)", level: .success)
                }
            }
        }
        .sheet(isPresented: $showProxyImport) {
            unifiedProxyImportSheet
        }
        .fileImporter(
            isPresented: Binding(
                get: { activeFileImportType != nil },
                set: { if !$0 { activeFileImportType = nil } }
            ),
            allowedContentTypes: [.data, .plainText],
            allowsMultipleSelection: true
        ) { result in
            switch activeFileImportType {
            case .vpn: handleVPNFileImport(result)
            case .wireGuard: handleWGFileImport(result)
            case .none: break
            }
        }
    }

    // MARK: - Auto-Save

    private var autoSaveSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: autoSaveEnabled ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle")
                    .font(.title3)
                    .foregroundStyle(autoSaveEnabled ? .green : .secondary)
                    .symbolEffect(.pulse, isActive: autoSaveEnabled)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-Save")
                        .font(.subheadline.weight(.bold))
                    if let lastSave = lastSaveTime {
                        Text("Last saved: \(lastSave, style: .relative) ago")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Saves all settings after every change")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: $autoSaveEnabled)
                    .labelsHidden()
                    .tint(.green)
            }

            if !autoSaveEnabled {
                Button {
                    vm.persistAutomationSettings()
                    vm.persistSettings()
                    lastSaveTime = Date()
                    withAnimation(.spring(duration: 0.3)) { showSavedToast = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        withAnimation { showSavedToast = false }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down.fill")
                        Text("Save Now")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(accentColor)
                    .foregroundStyle(.white)
                    .clipShape(.rect(cornerRadius: 10))
                }
                .sensoryFeedback(.success, trigger: lastSaveTime)
            }
        } header: {
            Label("Persistence", systemImage: "externaldrive.fill")
        }
    }

    // MARK: - Templates

    private var templateQuickSection: some View {
        Section {
            Button {
                showTemplates = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.purple)
                        .frame(width: 36, height: 36)
                        .background(.purple.opacity(0.12))
                        .clipShape(.rect(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automation Templates")
                            .font(.subheadline.weight(.bold))
                        Text("\(AutomationTemplate.builtInTemplates.count) built-in + custom presets")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Label("Quick Apply", systemImage: "bolt.fill")
        } footer: {
            Text("Apply a pre-configured template for TRUE DETECTION, Vision ML, Coordinate, Stealth, Speed, or Resilient automation.")
        }
    }

    // MARK: - TRUE DETECTION

    private var trueDetectionSection: some View {
        Section {
            Toggle(isOn: $vm.automationSettings.trueDetectionEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TRUE DETECTION")
                        .font(.headline)
                    Text("Hardcoded Interaction Protocol — bypasses all DOM detection")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(accentColor)

            if vm.automationSettings.trueDetectionEnabled {
                Toggle("Always First Priority", isOn: $vm.automationSettings.trueDetectionPriority)
                    .tint(accentColor)

                Group {
                    Stepper("Hard Pause: \(vm.automationSettings.trueDetectionHardPauseMs)ms", value: $vm.automationSettings.trueDetectionHardPauseMs, in: 1000...8000, step: 500)
                    Stepper("Click Count: \(vm.automationSettings.trueDetectionTripleClickCount)", value: $vm.automationSettings.trueDetectionTripleClickCount, in: 1...10)
                    Stepper("Click Delay: \(vm.automationSettings.trueDetectionTripleClickDelayMs)ms", value: $vm.automationSettings.trueDetectionTripleClickDelayMs, in: 200...3000, step: 100)
                    Stepper("Submit Cycles: \(vm.automationSettings.trueDetectionSubmitCycleCount)", value: $vm.automationSettings.trueDetectionSubmitCycleCount, in: 1...8)
                    Stepper("Button Recovery Timeout: \(vm.automationSettings.trueDetectionButtonRecoveryTimeoutMs)ms", value: $vm.automationSettings.trueDetectionButtonRecoveryTimeoutMs, in: 2000...30000, step: 1000)
                    Stepper("Max Attempts: \(vm.automationSettings.trueDetectionMaxAttempts)", value: $vm.automationSettings.trueDetectionMaxAttempts, in: 1...10)
                    Stepper("Post-Click Wait: \(vm.automationSettings.trueDetectionPostClickWaitMs)ms", value: $vm.automationSettings.trueDetectionPostClickWaitMs, in: 500...5000, step: 250)
                    Stepper("Cooldown: \(vm.automationSettings.trueDetectionCooldownMinutes) min", value: $vm.automationSettings.trueDetectionCooldownMinutes, in: 1...60)
                }

                selectorField("Email Selector", placeholder: "#email", binding: $vm.automationSettings.trueDetectionEmailSelector)
                selectorField("Password Selector", placeholder: "#login-password", binding: $vm.automationSettings.trueDetectionPasswordSelector)
                selectorField("Submit Selector", placeholder: "#login-submit", binding: $vm.automationSettings.trueDetectionSubmitSelector)

                Button {
                    showSuccessMarkerEditor = true
                } label: {
                    keywordRow("Success Markers", count: vm.automationSettings.trueDetectionSuccessMarkers.count)
                }

                Button {
                    showTerminalKeywordEditor = true
                } label: {
                    keywordRow("Terminal Keywords", count: vm.automationSettings.trueDetectionTerminalKeywords.count)
                }

                Button {
                    showErrorBannerEditor = true
                } label: {
                    keywordRow("Error Banner Selectors", count: vm.automationSettings.trueDetectionErrorBannerSelectors.count)
                }

                Toggle("No Proxy Rotation", isOn: $vm.automationSettings.trueDetectionNoProxyRotation)
                    .tint(accentColor)
                Toggle("Strict Waits", isOn: $vm.automationSettings.trueDetectionStrictWaits)
                    .tint(accentColor)
                Toggle("Ignore Placeholders", isOn: $vm.automationSettings.trueDetectionIgnorePlaceholders)
                    .tint(accentColor)
                Toggle("Ignore XPaths", isOn: $vm.automationSettings.trueDetectionIgnoreXPaths)
                    .tint(accentColor)
                Toggle("Ignore Class Names", isOn: $vm.automationSettings.trueDetectionIgnoreClassNames)
                    .tint(accentColor)
            }
        } header: {
            HStack {
                Image(systemName: "shield.checkered")
                Text("TRUE DETECTION Protocol")
            }
        } footer: {
            Text("Triple-Wait → #email → #login-password → Triple-Click #login-submit. Success = balance/wallet/my account/logout. No DOM guessing.")
        }
    }

    // MARK: - URL Calibration (True Detection)

    private var urlCalibrationSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "target").foregroundStyle(accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("URL Calibration").font(.body)
                    Text("\(calibrationService.calibratedURLCount) of \(vm.urlRotation.activeURLs.count) URLs calibrated").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if calibrationService.calibratedURLCount > 0 {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Button {
                guard !isAutoCalibrating else { return }
                isAutoCalibrating = true
                autoCalibrationLog = []
                vm.log("Starting bulk auto-calibration with TRUE DETECTION...")
                Task {
                    let urls = vm.urlRotation.enabledURLs
                    for (index, rotUrl) in urls.enumerated() {
                        guard let url = rotUrl.url else { continue }
                        let msg = "[\(index + 1)/\(urls.count)] Probing \(rotUrl.host)..."
                        autoCalibrationLog.append(msg)
                        vm.log(msg)

                        let session = LoginSiteWebSession(targetURL: url)
                        session.stealthEnabled = vm.stealthEnabled
                        session.setUp(wipeAll: true)
                        let loaded = await session.loadPage(timeout: AutomationSettings.minimumTimeoutSeconds)
                        if loaded {
                            if let cal = await session.autoCalibrate() {
                                calibrationService.saveCalibration(cal, forURL: url.absoluteString)
                                let detail = "\(rotUrl.host): email=\(cal.emailField?.cssSelector ?? "?") btn=\(cal.loginButton?.cssSelector ?? "?")"
                                autoCalibrationLog.append("  \u{2705} \(detail)")
                                vm.log("Calibrated \(rotUrl.host)", level: .success)
                            } else {
                                autoCalibrationLog.append("  \u{274C} \(rotUrl.host): probe failed")
                                vm.log("Calibration failed for \(rotUrl.host)", level: .warning)
                            }
                        } else {
                            autoCalibrationLog.append("  \u{274C} \(rotUrl.host): page load failed")
                            vm.log("Page load failed for \(rotUrl.host)", level: .warning)
                        }
                        session.tearDown(wipeAll: true)
                    }
                    isAutoCalibrating = false
                    vm.log("Bulk calibration complete: \(calibrationService.calibratedURLCount) calibrated", level: .success)
                }
            } label: {
                HStack(spacing: 10) {
                    if isAutoCalibrating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "wand.and.stars").foregroundStyle(accentColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-Calibrate All URLs").font(.subheadline.bold())
                        Text(isAutoCalibrating ? "Probing \(autoCalibrationLog.count) URLs..." : "TRUE DETECTION probe on all enabled URLs")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .disabled(isAutoCalibrating)

            ForEach(vm.urlRotation.enabledURLs.prefix(5), id: \.id) { rotUrl in
                Button {
                    calibrationURL = rotUrl.urlString
                    showCalibrationSheet = true
                } label: {
                    HStack(spacing: 8) {
                        let hasCal = calibrationService.calibrationFor(url: rotUrl.urlString)?.isCalibrated == true
                        Image(systemName: hasCal ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(hasCal ? .green : .secondary)
                            .font(.caption)
                        Text(rotUrl.host)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Text("Calibrate")
                            .font(.caption2)
                            .foregroundStyle(accentColor)
                    }
                }
            }

            if calibrationService.totalCalibrations > 0 {
                Button(role: .destructive) {
                    calibrationService.deleteAll()
                    vm.log("All calibrations deleted", level: .warning)
                } label: {
                    Label("Clear All Calibrations", systemImage: "trash")
                        .font(.subheadline)
                }
            }
        } header: {
            HStack {
                Image(systemName: "shield.checkered")
                Text("URL Calibration + TRUE DETECTION")
            }
        } footer: {
            Text("Calibrates CSS selectors (#email, #login-password, #login-submit) per URL using TRUE DETECTION probing. Success validated by balance/wallet/my account/logout markers.")
        }
    }

    // MARK: - Unified Network

    private var unifiedNetworkSection: some View {
        Group {
            Section {
                if vm.isIgnitionMode {
                    HStack(spacing: 10) {
                        Image(systemName: proxyService.networkRegion == .usa ? "flag.fill" : "globe.asia.australia.fill")
                            .foregroundStyle(proxyService.networkRegion == .usa ? .blue : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ignition Region").font(.body)
                            Text("Ignition connections use \(proxyService.networkRegion.label) configs").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { proxyService.networkRegion },
                            set: { proxyService.networkRegion = $0 }
                        )) {
                            Text("USA").tag(NetworkRegion.usa)
                            Text("AU").tag(NetworkRegion.au)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                    }
                    .sensoryFeedback(.impact(weight: .medium), trigger: proxyService.networkRegion)
                }

                Picker(selection: Binding(
                    get: { proxyService.unifiedConnectionMode },
                    set: { proxyService.setUnifiedConnectionMode($0) }
                )) {
                    ForEach(ConnectionMode.allCases, id: \.self) { mode in
                        Label(mode.label, systemImage: mode.icon).tag(mode)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "network").foregroundStyle(.blue)
                        Text("Connection Mode")
                    }
                }
                .pickerStyle(.menu)
                .sensoryFeedback(.impact(weight: .medium), trigger: proxyService.unifiedConnectionMode)

                Button {
                    proxyService.syncAllNetworkConfigsAcrossTargets()
                    vm.log("Synced all network configs across Joe/Ignition/PPSR", level: .success)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sync All Targets").font(.subheadline.bold())
                            Text("Apply unified configs to Joe, Ignition & PPSR").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .sensoryFeedback(.success, trigger: proxyService.unifiedConnectionMode)
            } header: {
                HStack {
                    Image(systemName: "network.badge.shield.half.filled")
                    Text("Unified Network")
                    Spacer()
                    Text(proxyService.unifiedConnectionMode.label)
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(unifiedModeColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(unifiedModeColor.opacity(0.12))
                        .clipShape(Capsule())
                }
            } footer: {
                Text("One set of network configs applied to all modes (Joe Fortune, Ignition, PPSR). Region toggle selects USA or AU proxy/VPN endpoints.")
            }

            if proxyService.unifiedConnectionMode == .proxy {
                unifiedProxySection
            } else if proxyService.unifiedConnectionMode == .openvpn {
                unifiedOpenVPNSection
            } else if proxyService.unifiedConnectionMode == .wireguard {
                unifiedWireGuardSection
            } else if proxyService.unifiedConnectionMode == .nodeMaven {
                nodeMavenStatusSection
            } else {
                unifiedDNSSection
            }
        }
    }

    private var unifiedModeColor: Color {
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

    private var nodeMavenStatusSection: some View {
        Section {
            let nm = NodeMavenService.shared
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.teal.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.teal)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("NodeMaven Proxy").font(.subheadline.bold())
                    Text(nm.statusSummary)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if nm.isEnabled {
                    Text(nm.shortStatus)
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.teal)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.teal.opacity(0.12)).clipShape(Capsule())
                } else {
                    Text("NOT SET")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.orange.opacity(0.12)).clipShape(Capsule())
                }
            }

            if !nm.isEnabled {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                    Text("Configure NodeMaven credentials in Network Settings to use this mode.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        } header: {
            Label("NodeMaven", systemImage: "cloud.fill")
        } footer: {
            Text("NodeMaven generates dynamic proxy credentials per session. Configure country, type, and quality in Network Settings.")
        }
    }

    private var unifiedProxySection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "network").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SOCKS5 Proxies").font(.body)
                    Text("\(proxyService.unifiedProxies.count) proxies loaded").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                unifiedProxyBadge
            }

            Button { showProxyImport = true } label: {
                Label("Import Proxies", systemImage: "doc.on.clipboard.fill")
            }

            if !proxyService.unifiedProxies.isEmpty {
                Button {
                    guard !isTestingProxies else { return }
                    isTestingProxies = true
                    Task {
                        vm.log("Testing all \(proxyService.unifiedProxies.count) unified proxies...")
                        await proxyService.testAllUnifiedProxies()
                        let working = proxyService.unifiedProxies.filter(\.isWorking).count
                        vm.log("Proxy test: \(working)/\(proxyService.unifiedProxies.count) working", level: .success)
                        isTestingProxies = false
                    }
                } label: {
                    HStack {
                        Label("Test All Proxies", systemImage: "antenna.radiowaves.left.and.right")
                        if isTestingProxies { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isTestingProxies)

                Button {
                    let exported = proxyService.exportProxies(target: .joe)
                    UIPasteboard.general.string = exported
                    vm.log("Exported \(proxyService.unifiedProxies.count) proxies to clipboard", level: .success)
                } label: {
                    Label("Export to Clipboard", systemImage: "doc.on.doc")
                }

                let deadCount = proxyService.unifiedProxies.filter({ !$0.isWorking && $0.lastTested != nil }).count
                if deadCount > 0 {
                    Button(role: .destructive) {
                        proxyService.removeDead(forIgnition: false)
                        proxyService.syncProxiesAcrossTargets()
                        vm.log("Removed \(deadCount) dead proxies")
                    } label: {
                        Label("Remove \(deadCount) Dead", systemImage: "xmark.circle")
                    }
                }

                Button(role: .destructive) {
                    proxyService.clearAllUnifiedProxies()
                    vm.log("Cleared all unified proxies")
                } label: {
                    Label("Clear All Proxies", systemImage: "trash")
                }
            }
        } header: {
            Label("Unified SOCKS5 Proxies", systemImage: "network")
        }
    }

    @ViewBuilder
    private var unifiedProxyBadge: some View {
        let proxies = proxyService.unifiedProxies
        if !proxies.isEmpty {
            HStack(spacing: 4) {
                let working = proxies.filter(\.isWorking).count
                if working > 0 {
                    Text("\(working) ok")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.green)
                }
                let dead = proxies.filter({ !$0.isWorking && $0.lastTested != nil }).count
                if dead > 0 {
                    Text("\(dead) dead")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color(.tertiarySystemFill)).clipShape(Capsule())
        }
    }

    private var unifiedOpenVPNSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenVPN Configs").font(.body)
                    Text("\(proxyService.unifiedVPNConfigs.count) configs loaded").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                let enabledCount = proxyService.unifiedVPNConfigs.filter(\.isEnabled).count
                if enabledCount > 0 {
                    Text("\(enabledCount) active")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.indigo)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.indigo.opacity(0.12)).clipShape(Capsule())
                }
            }

            Button { activeFileImportType = .vpn } label: {
                Label("Import .ovpn Files", systemImage: "doc.badge.plus")
            }

            if !proxyService.unifiedVPNConfigs.isEmpty {
                Button {
                    guard !isTestingVPNConfigs else { return }
                    isTestingVPNConfigs = true
                    Task {
                        vm.log("Testing \(proxyService.unifiedVPNConfigs.count) unified OpenVPN configs...")
                        await proxyService.testAllUnifiedVPNConfigs()
                        let reachable = proxyService.unifiedVPNConfigs.filter(\.isReachable).count
                        vm.log("OpenVPN test: \(reachable)/\(proxyService.unifiedVPNConfigs.count) reachable", level: .success)
                        isTestingVPNConfigs = false
                    }
                } label: {
                    HStack {
                        Label("Test All OpenVPN", systemImage: "antenna.radiowaves.left.and.right")
                        if isTestingVPNConfigs { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isTestingVPNConfigs)

                ForEach(proxyService.unifiedVPNConfigs) { vpn in
                    HStack(spacing: 8) {
                        Image(systemName: vpn.isEnabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(vpn.isEnabled ? .indigo : .secondary)
                            .onTapGesture {
                                proxyService.toggleVPNConfig(vpn, target: .joe, enabled: !vpn.isEnabled)
                                proxyService.syncVPNConfigsAcrossTargets()
                            }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(vpn.fileName)
                                .font(.system(.caption, design: .monospaced, weight: .medium)).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(vpn.displayString)
                                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                                Text(vpn.statusLabel)
                                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                                    .foregroundStyle(vpn.isReachable ? .green : (vpn.lastTested != nil ? .red : .gray))
                                if let latency = vpn.lastLatencyMs {
                                    Text("\(latency)ms")
                                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        Spacer()
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            proxyService.removeVPNConfig(vpn, target: .joe)
                            proxyService.syncVPNConfigsAcrossTargets()
                            vm.log("Removed VPN: \(vpn.fileName)")
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }

                let unreachableCount = proxyService.unifiedVPNConfigs.filter({ !$0.isReachable && $0.lastTested != nil }).count
                if unreachableCount > 0 {
                    Button(role: .destructive) {
                        proxyService.removeUnreachableVPNConfigs(target: .joe)
                        proxyService.syncVPNConfigsAcrossTargets()
                        vm.log("Removed \(unreachableCount) unreachable OpenVPN configs")
                    } label: {
                        Label("Remove \(unreachableCount) Unreachable", systemImage: "xmark.circle")
                    }
                }

                Button(role: .destructive) {
                    proxyService.clearAllUnifiedVPNConfigs()
                    vm.log("Cleared all unified OpenVPN configs")
                } label: {
                    Label("Clear All Configs", systemImage: "trash")
                }
            }
        } header: {
            Label("Unified OpenVPN", systemImage: "shield.lefthalf.filled")
        }
    }

    private var unifiedWireGuardSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "lock.trianglebadge.exclamationmark.fill").foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("WireGuard Configs").font(.body)
                    Text("\(proxyService.unifiedWGConfigs.count) configs loaded").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                let enabledCount = proxyService.unifiedWGConfigs.filter(\.isEnabled).count
                if enabledCount > 0 {
                    Text("\(enabledCount) active")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.purple.opacity(0.12)).clipShape(Capsule())
                }
            }

            Button { activeFileImportType = .wireGuard } label: {
                Label("Import .conf Files", systemImage: "doc.badge.plus")
            }

            if !proxyService.unifiedWGConfigs.isEmpty {
                Button {
                    guard !isTestingWGConfigs else { return }
                    isTestingWGConfigs = true
                    Task {
                        vm.log("Testing \(proxyService.unifiedWGConfigs.count) unified WireGuard configs...")
                        await proxyService.testAllUnifiedWGConfigs()
                        let reachable = proxyService.unifiedWGConfigs.filter(\.isReachable).count
                        vm.log("WireGuard test: \(reachable)/\(proxyService.unifiedWGConfigs.count) reachable", level: .success)
                        isTestingWGConfigs = false
                    }
                } label: {
                    HStack {
                        Label("Test All WireGuard", systemImage: "antenna.radiowaves.left.and.right")
                        if isTestingWGConfigs { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isTestingWGConfigs)

                ForEach(proxyService.unifiedWGConfigs) { wg in
                    HStack(spacing: 8) {
                        Image(systemName: wg.isEnabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(wg.isEnabled ? .purple : .secondary)
                            .onTapGesture {
                                proxyService.toggleWGConfig(wg, target: .joe, enabled: !wg.isEnabled)
                                proxyService.syncWGConfigsAcrossTargets()
                            }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(wg.fileName)
                                .font(.system(.caption, design: .monospaced, weight: .medium)).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(wg.displayString)
                                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                                Text(wg.statusLabel)
                                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                                    .foregroundStyle(wg.isReachable ? .green : (wg.lastTested != nil ? .red : .gray))
                            }
                        }
                        Spacer()
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            proxyService.removeWGConfig(wg, target: .joe)
                            proxyService.syncWGConfigsAcrossTargets()
                            vm.log("Removed WireGuard: \(wg.fileName)")
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }

                let unreachableWGCount = proxyService.unifiedWGConfigs.filter({ !$0.isReachable && $0.lastTested != nil }).count
                if unreachableWGCount > 0 {
                    Button(role: .destructive) {
                        proxyService.removeUnreachableWGConfigs(target: .joe)
                        proxyService.syncWGConfigsAcrossTargets()
                        vm.log("Removed \(unreachableWGCount) unreachable WireGuard configs")
                    } label: {
                        Label("Remove \(unreachableWGCount) Unreachable", systemImage: "xmark.circle")
                    }
                }

                Button(role: .destructive) {
                    proxyService.clearAllUnifiedWGConfigs()
                    vm.log("Cleared all unified WireGuard configs")
                } label: {
                    Label("Clear All Configs", systemImage: "trash")
                }
            }
        } header: {
            Label("Unified WireGuard", systemImage: "lock.trianglebadge.exclamationmark.fill")
        }
    }

    private var unifiedDNSSection: some View {
        Section {
            let enabled = PPSRDoHService.shared.managedProviders.filter(\.isEnabled).count
            let total = PPSRDoHService.shared.managedProviders.count
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill").foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DoH DNS Rotation").font(.body)
                    Text("\(enabled)/\(total) providers enabled").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } header: {
            Label("Unified DNS", systemImage: "lock.shield.fill")
        } footer: {
            Text("DNS-over-HTTPS rotation is managed globally. Configure providers in the Network settings page.")
        }
    }

    private var unifiedProxyImportSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle().fill(.blue).frame(width: 10, height: 10)
                        Text("Import Unified SOCKS5 Proxies").font(.headline)
                    }
                    Text("Imported proxies are synced across all targets (Joe, Ignition, PPSR).").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Button {
                        if let clipboard = UIPasteboard.general.string, !clipboard.isEmpty {
                            proxyBulkText = clipboard
                        }
                    } label: {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard").font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    Spacer()
                    let lineCount = proxyBulkText.components(separatedBy: .newlines).filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count
                    if lineCount > 0 {
                        Text("\(lineCount) lines").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }

                TextEditor(text: $proxyBulkText)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden).padding(10)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 10)).frame(minHeight: 200)
                    .overlay(alignment: .topLeading) {
                        if proxyBulkText.isEmpty {
                            Text("Paste SOCKS5 proxies here...\n\n127.0.0.1:1080\nuser:pass@proxy.com:9050")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.quaternary)
                                .padding(.horizontal, 14).padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }

                if let report = proxyImportReport {
                    HStack(spacing: 12) {
                        if report.added > 0 {
                            Label("\(report.added) added", systemImage: "checkmark.circle.fill").font(.caption.bold()).foregroundStyle(.green)
                        }
                        if report.duplicates > 0 {
                            Label("\(report.duplicates) duplicates", systemImage: "arrow.triangle.2.circlepath").font(.caption.bold()).foregroundStyle(.orange)
                        }
                        if !report.failed.isEmpty {
                            Label("\(report.failed.count) failed", systemImage: "xmark.circle.fill").font(.caption.bold()).foregroundStyle(.red)
                        }
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Import Proxies").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showProxyImport = false
                        proxyBulkText = ""
                        proxyImportReport = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        let report = proxyService.importUnifiedProxy(proxyBulkText)
                        proxyImportReport = report
                        if report.added > 0 {
                            vm.log("Imported \(report.added) unified SOCKS5 proxies", level: .success)
                        }
                        proxyBulkText = ""
                        if report.failed.isEmpty && report.added > 0 {
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                showProxyImport = false
                                proxyImportReport = nil
                            }
                        }
                    }
                    .disabled(proxyBulkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    private func handleVPNFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var imported = 0
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                if let data = try? Data(contentsOf: url),
                   let content = String(data: data, encoding: .utf8) {
                    let fileName = url.lastPathComponent
                    if let config = OpenVPNConfig.parse(fileName: fileName, content: content) {
                        proxyService.importUnifiedVPNConfig(config)
                        imported += 1
                    } else {
                        vm.log("Failed to parse: \(fileName)", level: .warning)
                    }
                }
            }
            if imported > 0 {
                vm.log("Imported \(imported) OpenVPN config(s) to all targets", level: .success)
            }
        case .failure(let error):
            vm.log("VPN import error: \(error.localizedDescription)", level: .error)
        }
    }

    private func handleWGFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var parsed: [WireGuardConfig] = []
            var failedFiles: [String] = []
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else {
                    failedFiles.append(url.lastPathComponent)
                    continue
                }
                defer { url.stopAccessingSecurityScopedResource() }
                if let data = try? Data(contentsOf: url),
                   let content = String(data: data, encoding: .utf8) {
                    let fileName = url.lastPathComponent
                    let configs = WireGuardConfig.parseMultiple(fileName: fileName, content: content)
                    if configs.isEmpty {
                        if let single = WireGuardConfig.parse(fileName: fileName, content: content) {
                            parsed.append(single)
                        } else {
                            failedFiles.append(fileName)
                        }
                    } else {
                        parsed.append(contentsOf: configs)
                    }
                } else {
                    failedFiles.append(url.lastPathComponent)
                }
            }
            if !parsed.isEmpty {
                let report = proxyService.importUnifiedWGConfigs(parsed)
                vm.log("WireGuard import: \(report.added) added, \(report.duplicates) duplicates — synced to all targets", level: .success)
            }
            for name in failedFiles {
                vm.log("Failed to parse WireGuard: \(name)", level: .warning)
            }
        case .failure(let error):
            vm.log("WireGuard import error: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Page Loading

    private var pageLoadingSection: some View {
        Section {
            HStack {
                Image(systemName: "globe").foregroundStyle(.blue)
                Text("Page Load Timeout")
                Spacer()
                Picker("", selection: Binding(
                    get: { Int(vm.automationSettings.pageLoadTimeout) },
                    set: { vm.automationSettings.pageLoadTimeout = TimeInterval($0) }
                )) {
                    Text("90s").tag(90)
                    Text("120s").tag(120)
                    Text("150s").tag(150)
                    Text("180s").tag(180)
                }
                .pickerStyle(.menu)
            }
            Stepper("Load Retries: \(vm.automationSettings.pageLoadRetries)", value: $vm.automationSettings.pageLoadRetries, in: 1...10)
            HStack {
                Text("Retry Backoff")
                Spacer()
                Picker("", selection: $vm.automationSettings.retryBackoffMultiplier) {
                    Text("1.0x").tag(1.0)
                    Text("1.5x").tag(1.5)
                    Text("2.0x").tag(2.0)
                    Text("3.0x").tag(3.0)
                }
                .pickerStyle(.menu)
            }
            Stepper("JS Render Wait: \(vm.automationSettings.waitForJSRenderMs)ms", value: $vm.automationSettings.waitForJSRenderMs, in: 1000...15000, step: 500)
            Toggle(isOn: $vm.automationSettings.fullSessionResetOnFinalRetry) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Full Reset on Final Retry")
                    Text("Destroy and rebuild WKWebView on last attempt").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(accentColor)
        } header: {
            Label("Page Loading", systemImage: "globe")
        }
    }

    // MARK: - Field Detection

    private var fieldDetectionSection: some View {
        Section {
            Toggle(isOn: $vm.automationSettings.fieldVerificationEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Field Verification")
                    Text("Verify email/password fields exist before filling").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(accentColor)

            if vm.automationSettings.fieldVerificationEnabled {
                Stepper("Timeout: \(Int(vm.automationSettings.fieldVerificationTimeout))s", value: $vm.automationSettings.fieldVerificationTimeout, in: 90...300, step: 15)
            }

            Toggle(isOn: $vm.automationSettings.autoCalibrationEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-Calibration")
                    Text("Probe page to map field positions").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(accentColor)

            Toggle(isOn: $vm.automationSettings.visionMLCalibrationFallback) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vision ML Fallback")
                    Text("Screenshot OCR if calibration fails").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(.purple)

            HStack {
                Text("Confidence Threshold")
                Spacer()
                Text("\(Int(vm.automationSettings.calibrationConfidenceThreshold * 100))%")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $vm.automationSettings.calibrationConfidenceThreshold, in: 0.3...1.0, step: 0.05)
                .tint(accentColor)
        } header: {
            Label("Field Detection", systemImage: "textformat.alt")
        }
    }

    // MARK: - Cookie

    private var cookieConsentSection: some View {
        Section {
            Toggle(isOn: $vm.automationSettings.dismissCookieNotices) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dismiss Cookie Notices")
                    Text("Auto-dismiss GDPR/cookie banners").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(accentColor)

            if vm.automationSettings.dismissCookieNotices {
                Stepper("Post-Dismiss Delay: \(vm.automationSettings.cookieDismissDelayMs)ms", value: $vm.automationSettings.cookieDismissDelayMs, in: 100...2000, step: 100)
            }
        } header: {
            Label("Cookie / Consent", systemImage: "hand.raised.fill")
        }
    }

    // MARK: - Credential Entry

    private var credentialEntrySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Typing Speed Range").font(.subheadline)
                HStack {
                    Text("\(vm.automationSettings.typingSpeedMinMs)ms").font(.system(.caption, design: .monospaced))
                    Spacer()
                    Text("\(vm.automationSettings.typingSpeedMaxMs)ms").font(.system(.caption, design: .monospaced))
                }
                .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    VStack(alignment: .leading) {
                        Text("Min").font(.caption2).foregroundStyle(.tertiary)
                        Stepper("\(vm.automationSettings.typingSpeedMinMs)", value: $vm.automationSettings.typingSpeedMinMs, in: 10...200, step: 10).labelsHidden()
                    }
                    VStack(alignment: .leading) {
                        Text("Max").font(.caption2).foregroundStyle(.tertiary)
                        Stepper("\(vm.automationSettings.typingSpeedMaxMs)", value: $vm.automationSettings.typingSpeedMaxMs, in: 50...500, step: 10).labelsHidden()
                    }
                }
            }

            Toggle(isOn: $vm.automationSettings.typingJitterEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Typing Jitter")
                    Text("Gaussian randomization on keystroke timing").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(accentColor)

            Toggle(isOn: $vm.automationSettings.occasionalBackspaceEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Occasional Backspace")
                    Text("Simulate human typos with correction").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(accentColor)

            if vm.automationSettings.occasionalBackspaceEnabled {
                HStack {
                    Text("Backspace Probability")
                    Spacer()
                    Text("\(Int(vm.automationSettings.backspaceProbability * 100))%")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $vm.automationSettings.backspaceProbability, in: 0.01...0.15, step: 0.01)
                    .tint(accentColor)
            }

            Stepper("Focus Delay: \(vm.automationSettings.fieldFocusDelayMs)ms", value: $vm.automationSettings.fieldFocusDelayMs, in: 50...2000, step: 50)
            Stepper("Inter-Field Delay: \(vm.automationSettings.interFieldDelayMs)ms", value: $vm.automationSettings.interFieldDelayMs, in: 100...3000, step: 50)
        } header: {
            Label("Credential Entry", systemImage: "keyboard")
        }
    }

    // MARK: - Form Interaction

    private var formInteractionSection: some View {
        Section {
            Toggle(isOn: $vm.automationSettings.clearFieldsBeforeTyping) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clear Fields Before Typing")
                    Text("Remove existing content before entering credentials").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(accentColor)

            if vm.automationSettings.clearFieldsBeforeTyping {
                Picker("Clear Method", selection: $vm.automationSettings.clearFieldMethod) {
                    ForEach(AutomationSettings.FieldClearMethod.allCases, id: \.self) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
            }

            Toggle("Tab Between Fields", isOn: $vm.automationSettings.tabBetweenFields).tint(accentColor)
            Toggle("Click Field Before Typing", isOn: $vm.automationSettings.clickFieldBeforeTyping).tint(accentColor)

            Toggle(isOn: $vm.automationSettings.verifyFieldValueAfterTyping) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verify Value After Typing")
                    Text("Read back field value to confirm input").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(accentColor)

            if vm.automationSettings.verifyFieldValueAfterTyping {
                Toggle("Retype on Failure", isOn: $vm.automationSettings.retypeOnVerificationFailure).tint(.orange)
                if vm.automationSettings.retypeOnVerificationFailure {
                    Stepper("Max Retype: \(vm.automationSettings.maxRetypeAttempts)", value: $vm.automationSettings.maxRetypeAttempts, in: 1...5)
                }
            }

            Toggle(isOn: $vm.automationSettings.autoDetectRememberMe) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Detect \"Remember Me\"")
                    Text("Find and interact with remember-me checkboxes").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(accentColor)

            if vm.automationSettings.autoDetectRememberMe {
                Toggle("Uncheck Remember Me", isOn: $vm.automationSettings.uncheckRememberMe).tint(.orange)
            }

            Toggle("Dismiss Autofill Suggestions", isOn: $vm.automationSettings.dismissAutofillSuggestions).tint(accentColor)
            Toggle("Handle Password Managers", isOn: $vm.automationSettings.handlePasswordManagers).tint(accentColor)
        } header: {
            Label("Form Interaction", systemImage: "rectangle.and.pencil.and.ellipsis")
        }
    }

    // MARK: - Fallback Button Detection

    private var fallbackButtonSection: some View {
        Group {
            if !vm.automationSettings.trueDetectionEnabled {
                Section {
                    Picker("Detection Mode", selection: $vm.automationSettings.loginButtonDetectionMode) {
                        ForEach(AutomationSettings.ButtonDetectionMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }

                    Picker("Click Method", selection: $vm.automationSettings.loginButtonClickMethod) {
                        ForEach(AutomationSettings.ButtonClickMethod.allCases, id: \.self) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }

                    Button { showButtonTextEditor = true } label: {
                        keywordRow("Button Text Matches", count: vm.automationSettings.loginButtonTextMatches.count)
                    }

                    HStack {
                        Text("Confidence Threshold")
                        Spacer()
                        Text("\(Int(vm.automationSettings.loginButtonConfidenceThreshold * 100))%")
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $vm.automationSettings.loginButtonConfidenceThreshold, in: 0.2...1.0, step: 0.05)
                        .tint(accentColor)

                    Stepper("Max Candidates: \(vm.automationSettings.loginButtonMaxCandidates)", value: $vm.automationSettings.loginButtonMaxCandidates, in: 1...15)
                    Stepper("Min Size: \(vm.automationSettings.loginButtonMinSizePx)px", value: $vm.automationSettings.loginButtonMinSizePx, in: 5...80, step: 5)
                } header: {
                    Label("Button Detection (Fallback)", systemImage: "hand.tap.fill")
                } footer: {
                    Text("Only used when TRUE DETECTION is disabled. Vision ML uses screenshots, Coordinate uses pixel positions.")
                }
            }

            Section {
                Toggle(isOn: $vm.automationSettings.loginButtonScrollIntoView) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scroll Into View")
                        Text("Scroll page to make button visible").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .tint(accentColor)

                Toggle(isOn: $vm.automationSettings.loginButtonWaitForEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wait for Enabled")
                        Text("Wait until button is not disabled").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .tint(accentColor)

                if vm.automationSettings.loginButtonWaitForEnabled {
                    Stepper("Enabled Timeout: \(vm.automationSettings.loginButtonWaitForEnabledTimeoutMs)ms", value: $vm.automationSettings.loginButtonWaitForEnabledTimeoutMs, in: 90_000...300_000, step: 15_000)
                }

                Toggle("Visibility Check", isOn: $vm.automationSettings.loginButtonVisibilityCheck).tint(accentColor)

                Toggle(isOn: $vm.automationSettings.loginButtonHoverBeforeClick) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hover Before Click")
                        Text("Simulate mouse hover to trigger hover states").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .tint(accentColor)

                if vm.automationSettings.loginButtonHoverBeforeClick {
                    Stepper("Hover Duration: \(vm.automationSettings.loginButtonHoverDurationMs)ms", value: $vm.automationSettings.loginButtonHoverDurationMs, in: 50...1000, step: 50)
                }

                Toggle(isOn: $vm.automationSettings.loginButtonDoubleClickGuard) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Double-Click Guard")
                        Text("Prevent accidental duplicate submissions").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .tint(.orange)

                Toggle(isOn: $vm.automationSettings.loginButtonClickOffsetJitter) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Click Offset Jitter")
                        Text("Randomize click position within button bounds").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .tint(accentColor)

                if vm.automationSettings.loginButtonClickOffsetJitter {
                    Stepper("Max Offset: \(vm.automationSettings.loginButtonClickOffsetMaxPx)px", value: $vm.automationSettings.loginButtonClickOffsetMaxPx, in: 1...20)
                }

                Stepper("Pre-Click Delay: \(vm.automationSettings.loginButtonPreClickDelayMs)ms", value: $vm.automationSettings.loginButtonPreClickDelayMs, in: 0...2000, step: 50)
                Stepper("Post-Click Delay: \(vm.automationSettings.loginButtonPostClickDelayMs)ms", value: $vm.automationSettings.loginButtonPostClickDelayMs, in: 0...3000, step: 50)
            } header: {
                Label("Click Behavior", systemImage: "cursorarrow.click.2")
            }

            Section {
                Toggle("Enter Key Fallback", isOn: $vm.automationSettings.loginButtonEnterKeyFallback).tint(.orange)
                Toggle("Form Submit Fallback", isOn: $vm.automationSettings.loginButtonFormSubmitFallback).tint(.orange)
                Toggle("Vision ML Fallback", isOn: $vm.automationSettings.loginButtonVisionMLFallback).tint(.cyan)
                Toggle("OCR Text Fallback", isOn: $vm.automationSettings.loginButtonOCRFallback).tint(.cyan)
                Toggle("Coordinate Fallback", isOn: $vm.automationSettings.loginButtonCoordinateFallback).tint(.cyan)
            } header: {
                Label("Fallback Chain", systemImage: "arrow.triangle.branch")
            } footer: {
                Text("Non-selector fallbacks: Vision ML → OCR → Coordinate Tap. All avoid DOM queries detectable by anti-bot systems.")
            }
        }
    }

    // MARK: - Pattern Strategy

    private var patternStrategySection: some View {
        Section {
            Stepper("Max Submit Cycles: \(vm.automationSettings.maxSubmitCycles)", value: $vm.automationSettings.maxSubmitCycles, in: 1...10)

            Toggle(isOn: $vm.automationSettings.preferCalibratedPatternsFirst) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prefer Calibrated Patterns")
                    Text("Try calibrated coordinates before generic").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(accentColor)

            Toggle(isOn: $vm.automationSettings.patternLearningEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pattern Learning")
                    Text("Remember which patterns work per URL").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(.purple)

            Button { showPatternReorder = true } label: {
                HStack {
                    Image(systemName: "list.number").foregroundStyle(accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pattern Priority Order")
                        Text("\(vm.automationSettings.enabledPatterns.count) enabled, \(vm.automationSettings.patternPriorityOrder.count) ordered").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }

            Group {
                Toggle("Vision ML Click", isOn: $vm.automationSettings.fallbackToVisionMLClick).tint(.purple)
                Toggle("OCR Click", isOn: $vm.automationSettings.fallbackToOCRClick).tint(.indigo)
                Toggle("Coordinate Click", isOn: $vm.automationSettings.fallbackToCoordinateClick).tint(.cyan)
                Toggle(isOn: $vm.automationSettings.fallbackToLegacyFill) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Legacy DOM Fill (Detectable)")
                        Text("Direct DOM manipulation — detectable by anti-bot").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .tint(.red)
            }
        } header: {
            Label("Pattern Strategy & Fallbacks", systemImage: "wand.and.rays")
        } footer: {
            Text("Controls form-filling patterns and fallback chain. Cycles retry with different strategies if prior ones fail.")
        }
    }

    // MARK: - Submit Behavior

    private var submitBehaviorSection: some View {
        Section {
            Stepper("Submit Retries: \(vm.automationSettings.submitRetryCount)", value: $vm.automationSettings.submitRetryCount, in: 1...10)
            Stepper("Retry Delay: \(vm.automationSettings.submitRetryDelayMs)ms", value: $vm.automationSettings.submitRetryDelayMs, in: 200...5000, step: 200)
            HStack {
                Text("Wait for Response")
                Spacer()
                Picker("", selection: $vm.automationSettings.waitForResponseSeconds) {
                    Text("90s").tag(90.0)
                    Text("120s").tag(120.0)
                    Text("150s").tag(150.0)
                }
                .pickerStyle(.menu)
            }
            Toggle(isOn: $vm.automationSettings.rapidPollEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rapid Result Poll")
                    Text("Fast-check for success markers after submit").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(accentColor)

            if vm.automationSettings.rapidPollEnabled {
                Stepper("Poll Interval: \(vm.automationSettings.rapidPollIntervalMs)ms", value: $vm.automationSettings.rapidPollIntervalMs, in: 50...1000, step: 50)
            }
        } header: {
            Label("Submit Behavior", systemImage: "paperplane.fill")
        }
    }

    // MARK: - Time Delays

    private var timeDelaysSection: some View {
        Group {
            Section {
                Stepper("Pre-Navigation: \(vm.automationSettings.preNavigationDelayMs)ms", value: $vm.automationSettings.preNavigationDelayMs, in: 0...3000, step: 50)
                Stepper("Post-Navigation: \(vm.automationSettings.postNavigationDelayMs)ms", value: $vm.automationSettings.postNavigationDelayMs, in: 0...5000, step: 100)
                Stepper("Page Stabilization: \(vm.automationSettings.pageStabilizationDelayMs)ms", value: $vm.automationSettings.pageStabilizationDelayMs, in: 0...5000, step: 100)
                Stepper("AJAX Settle: \(vm.automationSettings.ajaxSettleDelayMs)ms", value: $vm.automationSettings.ajaxSettleDelayMs, in: 0...5000, step: 100)
                Stepper("DOM Mutation: \(vm.automationSettings.domMutationSettleMs)ms", value: $vm.automationSettings.domMutationSettleMs, in: 0...3000, step: 100)
                Stepper("Animation Settle: \(vm.automationSettings.animationSettleDelayMs)ms", value: $vm.automationSettings.animationSettleDelayMs, in: 0...3000, step: 100)
                Stepper("Redirect Follow: \(vm.automationSettings.redirectFollowDelayMs)ms", value: $vm.automationSettings.redirectFollowDelayMs, in: 0...3000, step: 100)
            } header: {
                Label("Navigation Delays", systemImage: "clock.arrow.circlepath")
            }

            Section {
                Stepper("Pre-Typing: \(vm.automationSettings.preTypingDelayMs)ms", value: $vm.automationSettings.preTypingDelayMs, in: 0...3000, step: 50)
                Stepper("Post-Typing: \(vm.automationSettings.postTypingDelayMs)ms", value: $vm.automationSettings.postTypingDelayMs, in: 0...3000, step: 50)
                Stepper("Pre-Submit: \(vm.automationSettings.preSubmitDelayMs)ms", value: $vm.automationSettings.preSubmitDelayMs, in: 0...5000, step: 50)
                Stepper("Post-Submit: \(vm.automationSettings.postSubmitDelayMs)ms", value: $vm.automationSettings.postSubmitDelayMs, in: 0...5000, step: 100)
                Stepper("Between Attempts: \(vm.automationSettings.betweenAttemptsDelayMs)ms", value: $vm.automationSettings.betweenAttemptsDelayMs, in: 0...10000, step: 250)
                Stepper("Between Credentials: \(vm.automationSettings.betweenCredentialsDelayMs)ms", value: $vm.automationSettings.betweenCredentialsDelayMs, in: 0...10000, step: 250)
            } header: {
                Label("Action Delays", systemImage: "timer")
            }

            Section {
                Stepper("Global Pre-Action: \(vm.automationSettings.globalPreActionDelayMs)ms", value: $vm.automationSettings.globalPreActionDelayMs, in: 0...5000, step: 50)
                Stepper("Global Post-Action: \(vm.automationSettings.globalPostActionDelayMs)ms", value: $vm.automationSettings.globalPostActionDelayMs, in: 0...5000, step: 50)
                Stepper("CAPTCHA Detection: \(vm.automationSettings.captchaDetectionDelayMs)ms", value: $vm.automationSettings.captchaDetectionDelayMs, in: 500...10000, step: 250)
                Stepper("Error Recovery: \(vm.automationSettings.errorRecoveryDelayMs)ms", value: $vm.automationSettings.errorRecoveryDelayMs, in: 0...10000, step: 250)
                Stepper("Session Cooldown: \(vm.automationSettings.sessionCooldownDelayMs)ms", value: $vm.automationSettings.sessionCooldownDelayMs, in: 0...30000, step: 500)
                Stepper("Proxy Rotation: \(vm.automationSettings.proxyRotationDelayMs)ms", value: $vm.automationSettings.proxyRotationDelayMs, in: 0...10000, step: 250)
                Stepper("VPN Reconnect: \(vm.automationSettings.vpnReconnectDelayMs)ms", value: $vm.automationSettings.vpnReconnectDelayMs, in: 0...15000, step: 500)

                Toggle(isOn: $vm.automationSettings.delayRandomizationEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delay Randomization")
                        Text("Add \u{00B1}variance to all delays").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .tint(accentColor)

                if vm.automationSettings.delayRandomizationEnabled {
                    Stepper("Randomization: \u{00B1}\(vm.automationSettings.delayRandomizationPercent)%", value: $vm.automationSettings.delayRandomizationPercent, in: 5...75, step: 5)
                }
            } header: {
                Label("System & Recovery Delays", systemImage: "gauge.with.dots.needle.33percent")
            }
        }
    }

    // MARK: - Post-Submit

    private var postSubmitEvalSection: some View {
        Section {
            Toggle("Redirect Detection", isOn: $vm.automationSettings.redirectDetection).tint(accentColor)
            Toggle("Error Banner Detection", isOn: $vm.automationSettings.errorBannerDetection).tint(accentColor)
            Toggle("Content Change Detection", isOn: $vm.automationSettings.contentChangeDetection).tint(accentColor)
            Toggle("Capture Page Content", isOn: $vm.automationSettings.capturePageContent).tint(accentColor)
            Picker("Evaluation Strictness", selection: $vm.automationSettings.evaluationStrictness) {
                ForEach(AutomationSettings.EvaluationStrictness.allCases, id: \.self) { level in
                    Text(level.rawValue).tag(level)
                }
            }
        } header: {
            Label("Post-Submit Evaluation", systemImage: "checklist.checked")
        } footer: {
            Text("Success is validated by TRUE DETECTION markers (balance/wallet/my account/logout) and redirect detection. \"Welcome\" text is a secondary indicator only.")
        }
    }

    // MARK: - MFA

    private var mfaHandlingSection: some View {
        Section {
            Toggle(isOn: $vm.automationSettings.mfaDetectionEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MFA Detection")
                    Text("Detect two-factor prompts after login").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(accentColor)

            if vm.automationSettings.mfaDetectionEnabled {
                Stepper("Wait Timeout: \(vm.automationSettings.mfaWaitTimeoutSeconds)s", value: $vm.automationSettings.mfaWaitTimeoutSeconds, in: 90...300, step: 15)
                Toggle("Auto-Skip MFA", isOn: $vm.automationSettings.mfaAutoSkip).tint(.orange)
                Toggle("Mark as Temp Disabled", isOn: $vm.automationSettings.mfaMarkAsTempDisabled).tint(.orange)

                Button { showMFAKeywordEditor = true } label: {
                    keywordRow("MFA Keywords", count: vm.automationSettings.mfaKeywords.count)
                }
            }
        } header: {
            Label("MFA / 2FA Handling", systemImage: "lock.shield.fill")
        }
    }

    // MARK: - CAPTCHA

    private var captchaHandlingSection: some View {
        Section {
            Toggle(isOn: $vm.automationSettings.captchaDetectionEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CAPTCHA Detection")
                    Text("Detect reCAPTCHA, hCaptcha, and other challenges").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(accentColor)

            if vm.automationSettings.captchaDetectionEnabled {
                Toggle("Auto-Skip on CAPTCHA", isOn: $vm.automationSettings.captchaAutoSkip).tint(.orange)
                Toggle("Mark as Failed", isOn: $vm.automationSettings.captchaMarkAsFailed).tint(.red)
                Stepper("Wait Timeout: \(vm.automationSettings.captchaWaitTimeoutSeconds)s", value: $vm.automationSettings.captchaWaitTimeoutSeconds, in: 90...300, step: 15)
                Toggle("Iframe Detection", isOn: $vm.automationSettings.captchaIframeDetection).tint(.purple)
                Toggle("Image Detection", isOn: $vm.automationSettings.captchaImageDetection).tint(.purple)

                Button { showCaptchaKeywordEditor = true } label: {
                    keywordRow("CAPTCHA Keywords", count: vm.automationSettings.captchaKeywords.count)
                }
            }
        } header: {
            Label("CAPTCHA Handling", systemImage: "puzzlepiece.fill")
        }
    }

    // MARK: - Retry / Requeue

    private var retryRequeueSection: some View {
        Section {
            Toggle("Requeue on Timeout", isOn: $vm.automationSettings.requeueOnTimeout).tint(accentColor)
            Toggle("Requeue on Connection Failure", isOn: $vm.automationSettings.requeueOnConnectionFailure).tint(accentColor)
            Toggle("Requeue on Unsure", isOn: $vm.automationSettings.requeueOnUnsure).tint(accentColor)
            Toggle("Requeue on Red Banner", isOn: $vm.automationSettings.requeueOnRedBanner).tint(accentColor)
            Stepper("Max Requeue Count: \(vm.automationSettings.maxRequeueCount)", value: $vm.automationSettings.maxRequeueCount, in: 0...20)

            VStack(alignment: .leading, spacing: 4) {
                Stepper("Min Attempts Before No Acc: \(vm.automationSettings.minAttemptsBeforeNoAcc)", value: $vm.automationSettings.minAttemptsBeforeNoAcc, in: 3...8)
                Text("Minimum full login attempts before declaring No Account. Temp disabled = account exists.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Cycle Pause Range").font(.subheadline)
                HStack(spacing: 12) {
                    VStack(alignment: .leading) {
                        Text("Min").font(.caption2).foregroundStyle(.tertiary)
                        Stepper("\(vm.automationSettings.cyclePauseMinMs)ms", value: $vm.automationSettings.cyclePauseMinMs, in: 100...5000, step: 100)
                    }
                    VStack(alignment: .leading) {
                        Text("Max").font(.caption2).foregroundStyle(.tertiary)
                        Stepper("\(vm.automationSettings.cyclePauseMaxMs)ms", value: $vm.automationSettings.cyclePauseMaxMs, in: 200...10000, step: 100)
                    }
                }
            }
        } header: {
            Label("Retry / Requeue", systemImage: "arrow.counterclockwise")
        }
    }

    // MARK: - Error Classification

    private var errorClassificationSection: some View {
        Section {
            Toggle("Network Error Auto-Retry", isOn: $vm.automationSettings.networkErrorAutoRetry).tint(accentColor)
            Toggle("SSL Error Auto-Retry", isOn: $vm.automationSettings.sslErrorAutoRetry).tint(accentColor)
            Toggle(isOn: $vm.automationSettings.http403MarkAsBlocked) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("HTTP 403 → Blocked")
                    Text("Treat 403 as IP/account blocked").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(.red)
            Stepper("HTTP 429 Retry: \(vm.automationSettings.http429RetryAfterSeconds)s", value: $vm.automationSettings.http429RetryAfterSeconds, in: 90...300, step: 15)
            Toggle("HTTP 5xx Auto-Retry", isOn: $vm.automationSettings.http5xxAutoRetry).tint(accentColor)
            Toggle("Connection Reset Retry", isOn: $vm.automationSettings.connectionResetAutoRetry).tint(accentColor)
            Toggle("DNS Failure Retry", isOn: $vm.automationSettings.dnsFailureAutoRetry).tint(accentColor)
            Toggle(isOn: $vm.automationSettings.classifyUnknownAsUnsure) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unknown → Unsure")
                    Text("Classify unrecognized errors as unsure").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(.orange)
        } header: {
            Label("Error Classification", systemImage: "exclamationmark.triangle.fill")
        }
    }

    // MARK: - Session Management

    private var sessionManagementSection: some View {
        Section {
            Picker("Session Isolation", selection: $vm.automationSettings.sessionIsolation) {
                ForEach(AutomationSettings.SessionIsolationMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            Toggle("Clear Cookies", isOn: $vm.automationSettings.clearCookiesBetweenAttempts).tint(accentColor)
            Toggle("Clear Local Storage", isOn: $vm.automationSettings.clearLocalStorageBetweenAttempts).tint(accentColor)
            Toggle("Clear Session Storage", isOn: $vm.automationSettings.clearSessionStorageBetweenAttempts).tint(accentColor)
            Toggle("Clear Cache", isOn: $vm.automationSettings.clearCacheBetweenAttempts).tint(accentColor)
            Toggle("Clear IndexedDB", isOn: $vm.automationSettings.clearIndexedDBBetweenAttempts).tint(accentColor)

            Toggle(isOn: $vm.automationSettings.freshWebViewPerAttempt) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fresh WebView Per Attempt")
                    Text("Destroy and recreate WKWebView each credential").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(.orange)

            if !vm.automationSettings.freshWebViewPerAttempt {
                Stepper("WebView Pool: \(vm.automationSettings.reuseWebViewPoolSize)", value: $vm.automationSettings.reuseWebViewPoolSize, in: 1...24)
            }
            Stepper("Memory Limit: \(vm.automationSettings.webViewMemoryLimitMB)MB", value: $vm.automationSettings.webViewMemoryLimitMB, in: 256...6144, step: 256)
            Toggle("JavaScript Enabled", isOn: $vm.automationSettings.webViewJSEnabled).tint(accentColor)
            Toggle("Image Loading", isOn: $vm.automationSettings.webViewImageLoadingEnabled).tint(accentColor)
        } header: {
            Label("Session Management", systemImage: "server.rack")
        }
    }

    // MARK: - Stealth

    private var stealthSection: some View {
        Section {
            Toggle("Stealth JS Injection", isOn: $vm.automationSettings.stealthJSInjection).tint(.purple)
            Toggle("FP Validation (on login)", isOn: $vm.automationSettings.fingerprintValidationEnabled).tint(.purple)
            Toggle("Fingerprint Spoofing", isOn: $vm.automationSettings.fingerprintSpoofing).tint(.purple)
            Toggle("User-Agent Rotation", isOn: $vm.automationSettings.userAgentRotation).tint(.purple)
            Toggle("Viewport Randomization", isOn: $vm.automationSettings.viewportRandomization).tint(.purple)
            Toggle("WebGL Noise", isOn: $vm.automationSettings.webGLNoise).tint(.purple)
            Toggle("Canvas Noise", isOn: $vm.automationSettings.canvasNoise).tint(.purple)
            Toggle("AudioContext Noise", isOn: $vm.automationSettings.audioContextNoise).tint(.purple)
            Toggle("Timezone Spoof", isOn: $vm.automationSettings.timezoneSpoof).tint(.purple)
            Toggle("Language Spoof", isOn: $vm.automationSettings.languageSpoof).tint(.purple)
        } header: {
            Label("Stealth & Anti-Fingerprint", systemImage: "eye.slash.fill")
        } footer: {
            Text("Individual stealth techniques. All enabled by default for maximum anti-bot evasion.")
        }
    }

    // MARK: - Human Simulation

    private var humanSimulationSection: some View {
        Section {
            Toggle("Human Mouse Movement", isOn: $vm.automationSettings.humanMouseMovement).tint(accentColor)
            Toggle("Human Scroll Jitter", isOn: $vm.automationSettings.humanScrollJitter).tint(accentColor)
            Toggle("Random Pre-Action Pause", isOn: $vm.automationSettings.randomPreActionPause).tint(accentColor)

            if vm.automationSettings.randomPreActionPause {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pre-Action Pause Range").font(.subheadline)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading) {
                            Text("Min").font(.caption2).foregroundStyle(.tertiary)
                            Stepper("\(vm.automationSettings.preActionPauseMinMs)ms", value: $vm.automationSettings.preActionPauseMinMs, in: 0...1000, step: 10)
                        }
                        VStack(alignment: .leading) {
                            Text("Max").font(.caption2).foregroundStyle(.tertiary)
                            Stepper("\(vm.automationSettings.preActionPauseMaxMs)ms", value: $vm.automationSettings.preActionPauseMaxMs, in: 50...2000, step: 10)
                        }
                    }
                }
            }

            Toggle(isOn: $vm.automationSettings.gaussianTimingDistribution) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gaussian Timing")
                    Text("Bell-curve randomization instead of uniform").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(accentColor)
        } header: {
            Label("Human Simulation", systemImage: "figure.walk")
        }
    }

    // MARK: - Viewport

    private var viewportWindowSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { vm.automationSettings.useWebViewPoolFingerprints },
                set: { newValue in
                    vm.automationSettings.useWebViewPoolFingerprints = newValue
                    if newValue { vm.automationSettings.randomizeViewportSize = false }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("WebView Pool Fingerprints")
                    Text("Use trusted fingerprint pool for viewport & UA").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(.purple)

            Stepper("Width: \(vm.automationSettings.viewportWidth)px", value: $vm.automationSettings.viewportWidth, in: 320...2560, step: 10)
            Stepper("Height: \(vm.automationSettings.viewportHeight)px", value: $vm.automationSettings.viewportHeight, in: 480...1440, step: 10)

            Toggle(isOn: Binding(
                get: { vm.automationSettings.randomizeViewportSize },
                set: { newValue in
                    vm.automationSettings.randomizeViewportSize = newValue
                    if newValue { vm.automationSettings.useWebViewPoolFingerprints = false }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Randomize Viewport")
                    Text("Add random variance per session").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(accentColor)

            if vm.automationSettings.randomizeViewportSize {
                Stepper("Variance: \u{00B1}\(vm.automationSettings.viewportSizeVariancePx)px", value: $vm.automationSettings.viewportSizeVariancePx, in: 10...200, step: 10)
            }

            HStack {
                Text("Device Scale")
                Spacer()
                Picker("", selection: $vm.automationSettings.deviceScaleFactor) {
                    Text("1x").tag(1.0)
                    Text("2x").tag(2.0)
                    Text("3x").tag(3.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            Toggle(isOn: $vm.automationSettings.mobileViewportEmulation) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mobile Viewport Emulation")
                    Text("Emulate a mobile device").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(.purple)

            if vm.automationSettings.mobileViewportEmulation {
                Stepper("Mobile Width: \(vm.automationSettings.mobileViewportWidth)px", value: $vm.automationSettings.mobileViewportWidth, in: 320...430, step: 5)
                Stepper("Mobile Height: \(vm.automationSettings.mobileViewportHeight)px", value: $vm.automationSettings.mobileViewportHeight, in: 568...932, step: 5)
            }
        } header: {
            Label("Viewport & Window", systemImage: "rectangle.dashed")
        }
    }

    // MARK: - Screenshot

    private var screenshotDebugSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { vm.automationSettings.slowDebugMode },
                set: { vm.automationSettings.slowDebugMode = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Slow Debug Mode")
                    Text("Capture a screenshot every 2 seconds and force 1 session").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(.orange)
            Toggle("Screenshot Every Evaluation", isOn: $vm.automationSettings.screenshotOnEveryEval).tint(.orange)
            Toggle("Screenshot on Failure", isOn: $vm.automationSettings.screenshotOnFailure).tint(.orange)
            Toggle("Screenshot on Success", isOn: $vm.automationSettings.screenshotOnSuccess).tint(.orange)
            Stepper("Max Retention: \(vm.automationSettings.maxScreenshotRetention)", value: $vm.automationSettings.maxScreenshotRetention, in: 50...2000, step: 50)
        } header: {
            Label("Screenshot / Debug", systemImage: "camera.viewfinder")
        }
    }

    // MARK: - Concurrency

    private var concurrencySection: some View {
        Section {
            Stepper("Max Concurrency: \(vm.automationSettings.slowDebugMode ? 1 : vm.automationSettings.maxConcurrency)", value: $vm.automationSettings.maxConcurrency, in: 1...16)
                .disabled(vm.automationSettings.slowDebugMode)
            if vm.automationSettings.slowDebugMode {
                Label("Slow Debug Mode overrides concurrency to 1 session.", systemImage: "tortoise.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Stepper("Batch Start Delay: \(vm.automationSettings.batchDelayBetweenStartsMs)ms", value: $vm.automationSettings.batchDelayBetweenStartsMs, in: 0...5000, step: 100)
            Toggle(isOn: $vm.automationSettings.connectionTestBeforeBatch) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connection Test Before Batch")
                    Text("Verify connectivity before starting").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(accentColor)
        } header: {
            Label("Concurrency", systemImage: "square.stack.3d.up.fill")
        }
    }

    // MARK: - Network

    private var networkSection: some View {
        Section {
            Toggle(isOn: $vm.automationSettings.useAssignedNetworkForTests) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use Assigned Network")
                    Text("Tests use the mode's configured proxy/VPN/DNS").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(.blue)
            Toggle("Proxy Rotate on Disabled", isOn: $vm.automationSettings.proxyRotateOnDisabled).tint(.blue)
            Toggle("Proxy Rotate on Failure", isOn: $vm.automationSettings.proxyRotateOnFailure).tint(.blue)
            Toggle("DNS Rotate Per Request", isOn: $vm.automationSettings.dnsRotatePerRequest).tint(.cyan)
            Toggle("VPN Config Rotation", isOn: $vm.automationSettings.vpnConfigRotation).tint(.indigo)
        } header: {
            Label("Network Per-Mode", systemImage: "network")
        }
    }

    // MARK: - URL Rotation

    private var urlRotationSection: some View {
        Section {
            Toggle("URL Rotation", isOn: $vm.automationSettings.urlRotationEnabled).tint(accentColor)
            Stepper("Disable After \(vm.automationSettings.disableURLAfterConsecutiveFailures) Failures", value: $vm.automationSettings.disableURLAfterConsecutiveFailures, in: 1...10)
            HStack {
                Text("Re-Enable After")
                Spacer()
                Picker("", selection: Binding(
                    get: { Int(vm.automationSettings.reEnableURLAfterSeconds) },
                    set: { vm.automationSettings.reEnableURLAfterSeconds = TimeInterval($0) }
                )) {
                    Text("1 min").tag(60)
                    Text("5 min").tag(300)
                    Text("15 min").tag(900)
                    Text("30 min").tag(1800)
                    Text("Never").tag(0)
                }
                .pickerStyle(.menu)
            }
            Toggle("Prefer Fastest URL", isOn: $vm.automationSettings.preferFastestURL).tint(accentColor)
            Toggle(isOn: $vm.automationSettings.smartURLSelection) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart URL Selection")
                    Text("Combine success rate + speed for priority").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .tint(.purple)
        } header: {
            Label("URL Rotation", systemImage: "arrow.triangle.2.circlepath")
        }
    }

    // MARK: - Blacklist

    private var blacklistSection: some View {
        Section {
            Toggle("Auto-Blacklist No Account", isOn: $vm.automationSettings.autoBlacklistNoAcc).tint(.red)
            Toggle("Auto-Blacklist Perm Disabled", isOn: $vm.automationSettings.autoBlacklistPermDisabled).tint(.red)
            Toggle("Auto-Exclude on Import", isOn: $vm.automationSettings.autoExcludeBlacklist).tint(.orange)
        } header: {
            Label("Blacklist / Auto-Actions", systemImage: "hand.raised.slash.fill")
        }
    }

    // MARK: - Flow Assignment

    private var flowAssignmentSection: some View {
        Section {
            let assignmentCount = vm.automationSettings.urlFlowAssignments.count
            Button { showFlowAssignment = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "record.circle").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("URL Flow Assignments")
                        Text("\(assignmentCount) URL\(assignmentCount == 1 ? "" : "s") with assigned flows").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }

            if !vm.automationSettings.urlFlowAssignments.isEmpty {
                ForEach(vm.automationSettings.urlFlowAssignments) { assignment in
                    HStack(spacing: 8) {
                        Image(systemName: "link").font(.caption).foregroundStyle(.indigo)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(assignment.urlPattern)
                                .font(.system(.caption, design: .monospaced, weight: .medium))
                                .lineLimit(1)
                            Text("→ \(assignment.flowName)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if assignment.overridePatternStrategy {
                            Text("OVERRIDE")
                                .font(.system(.caption2, design: .monospaced, weight: .bold))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 4).padding(.vertical, 2)
                                .background(Color.red.opacity(0.12)).clipShape(Capsule())
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            vm.automationSettings.urlFlowAssignments.removeAll { $0.id == assignment.id }
                            vm.persistAutomationSettings()
                        } label: { Label("Remove", systemImage: "trash") }
                    }
                }
            }

            Button(role: .destructive) {
                vm.automationSettings = AutomationSettings()
                vm.persistAutomationSettings()
            } label: {
                Label("Reset All to Defaults", systemImage: "arrow.counterclockwise")
            }
            .sensoryFeedback(.warning, trigger: vm.automationSettings.trueDetectionEnabled)
        } header: {
            Label("Recorded Flow Overrides", systemImage: "record.circle")
        } footer: {
            Text("Assign a recorded flow to specific URLs. The flow overrides the normal pattern strategy for that URL.")
        }
    }

    // MARK: - Helpers

    private func selectorField(_ label: String, placeholder: String, binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: binding)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func keywordRow(_ title: String, count: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text("\(count) configured").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Pattern Priority View

struct PatternPriorityView: View {
    @Binding var settings: AutomationSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(settings.patternPriorityOrder, id: \.self) { name in
                    HStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.secondary)
                        Text(name)
                            .font(.system(.subheadline, design: .monospaced))
                        Spacer()
                        let isEnabled = settings.enabledPatterns.contains(name)
                        Button {
                            if isEnabled {
                                settings.enabledPatterns.removeAll { $0 == name }
                            } else {
                                settings.enabledPatterns.append(name)
                            }
                        } label: {
                            Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isEnabled ? .green : .secondary)
                        }
                    }
                }
                .onMove { source, destination in
                    settings.patternPriorityOrder.move(fromOffsets: source, toOffset: destination)
                }
            } header: {
                Text("Drag to reorder. Tap circle to enable/disable.")
            } footer: {
                Text("Patterns are tried in this order. Disabled patterns are skipped.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Pattern Priority")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
        }
        .environment(\.editMode, .constant(.active))
    }
}

// MARK: - URL Flow Assignment View

struct URLFlowAssignmentView: View {
    let vm: LoginViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedURL: String = ""
    @State private var selectedFlowId: String = ""
    @State private var overridePattern: Bool = true
    @State private var overrideTyping: Bool = false
    @State private var overrideStealth: Bool = false
    @State private var overrideSubmit: Bool = false

    private var availableFlows: [RecordedFlow] {
        FlowPersistenceService.shared.loadFlows()
    }

    private var availableURLs: [LoginURLRotationService.RotatingURL] {
        vm.urlRotation.activeURLs
    }

    var body: some View {
        List {
            Section {
                Picker("URL", selection: $selectedURL) {
                    Text("Select URL…").tag("")
                    ForEach(availableURLs, id: \.id) { url in
                        Text(url.host)
                            .font(.system(.caption, design: .monospaced))
                            .tag(url.urlString)
                    }
                }
                Picker("Recorded Flow", selection: $selectedFlowId) {
                    Text("Select Flow…").tag("")
                    ForEach(availableFlows) { flow in
                        Text("\(flow.name) (\(flow.actionCount) actions)")
                            .tag(flow.id)
                    }
                }
            } header: {
                Text("New Assignment")
            }

            Section {
                Toggle("Override Pattern Strategy", isOn: $overridePattern).tint(.red)
                Toggle("Override Typing Speed", isOn: $overrideTyping).tint(.orange)
                Toggle("Override Stealth Settings", isOn: $overrideStealth).tint(.purple)
                Toggle("Override Submit Behavior", isOn: $overrideSubmit).tint(.blue)
            } header: {
                Text("Override Scope")
            }

            Section {
                Button {
                    guard !selectedURL.isEmpty, !selectedFlowId.isEmpty else { return }
                    let flowName = availableFlows.first(where: { $0.id == selectedFlowId })?.name ?? "Unknown"
                    vm.automationSettings.urlFlowAssignments.removeAll { $0.urlPattern == selectedURL }
                    let assignment = URLFlowAssignment(
                        urlPattern: selectedURL,
                        flowId: selectedFlowId,
                        flowName: flowName,
                        overridePatternStrategy: overridePattern,
                        overrideTypingSpeed: overrideTyping,
                        overrideStealthSettings: overrideStealth,
                        overrideSubmitBehavior: overrideSubmit
                    )
                    vm.automationSettings.urlFlowAssignments.append(assignment)
                    vm.persistAutomationSettings()
                    vm.log("Assigned flow '\(flowName)' to \(selectedURL)", level: .success)
                    dismiss()
                } label: {
                    HStack {
                        Spacer()
                        Label("Assign Flow", systemImage: "link.badge.plus").font(.headline)
                        Spacer()
                    }
                }
                .disabled(selectedURL.isEmpty || selectedFlowId.isEmpty)
                .listRowBackground(selectedURL.isEmpty || selectedFlowId.isEmpty ? Color.green.opacity(0.3) : Color.green)
                .foregroundStyle(.white)
                .sensoryFeedback(.success, trigger: vm.automationSettings.urlFlowAssignments.count)
            }

            if !vm.automationSettings.urlFlowAssignments.isEmpty {
                Section("Existing Assignments") {
                    ForEach(vm.automationSettings.urlFlowAssignments) { assignment in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(assignment.urlPattern)
                                .font(.system(.caption, design: .monospaced, weight: .bold))
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                                Text(assignment.flowName).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 4) {
                                if assignment.overridePatternStrategy { overrideBadge("Pattern", color: .red) }
                                if assignment.overrideTypingSpeed { overrideBadge("Typing", color: .orange) }
                                if assignment.overrideStealthSettings { overrideBadge("Stealth", color: .purple) }
                                if assignment.overrideSubmitBehavior { overrideBadge("Submit", color: .blue) }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                vm.automationSettings.urlFlowAssignments.removeAll { $0.id == assignment.id }
                                vm.persistAutomationSettings()
                            } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Flow Assignments")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
        }
    }

    private func overrideBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.12)).clipShape(Capsule())
    }
}

// MARK: - Keyword List Editor

struct KeywordListEditor: View {
    let title: String
    @Binding var keywords: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var newKeyword: String = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Add keyword…", text: $newKeyword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        let trimmed = newKeyword.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty, !keywords.contains(trimmed) else { return }
                        keywords.append(trimmed)
                        newKeyword = ""
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section {
                if keywords.isEmpty {
                    Text("No keywords configured")
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    ForEach(keywords, id: \.self) { keyword in
                        Text(keyword)
                            .font(.system(.subheadline, design: .monospaced))
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    keywords.removeAll { $0 == keyword }
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                    .onMove { source, destination in
                        keywords.move(fromOffsets: source, toOffset: destination)
                    }
                }
            } header: {
                Text("\(keywords.count) keyword\(keywords.count == 1 ? "" : "s")")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
    }
}
