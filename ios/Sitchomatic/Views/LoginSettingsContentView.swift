import SwiftUI

struct LoginSettingsContentView: View {
    @Bindable var vm: LoginViewModel
    @State private var showDebugScreenshots: Bool = false
    @State private var showSelectTesting: Bool = false
    @State private var selectedCredentialIds: Set<String> = []

    private var accentColor: Color {
        vm.isIgnitionMode ? .orange : .green
    }

    var body: some View {
        List {
            quickActionsSection
            autoRetrySection
            blacklistSection
            stealthSection
            concurrencySection
            debugSection
            appearanceSection
            iCloudSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Advanced Settings")
        .sheet(isPresented: $showDebugScreenshots) {
            NavigationStack {
                LoginDebugScreenshotsView(vm: vm)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { showDebugScreenshots = false }
                        }
                    }
            }
            .presentationDetents([.large])
        }
    }

    private var quickActionsSection: some View {
        Section {
            if !vm.untestedCredentials.isEmpty {
                Button {
                    vm.testAllUntested()
                } label: {
                    HStack { Spacer(); Label("Test All Untested (\(vm.untestedCredentials.count))", systemImage: "play.fill").font(.headline); Spacer() }
                }
                .disabled(vm.isRunning)
                .listRowBackground(vm.isRunning ? accentColor.opacity(0.4) : accentColor)
                .foregroundStyle(.white)
                .sensoryFeedback(.impact(weight: .heavy), trigger: vm.isRunning)
            }

            Button {
                selectedCredentialIds = Set(vm.untestedCredentials.map(\.id))
                showSelectTesting = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checklist").foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Select Testing").font(.body)
                        Text("Choose specific credentials to test").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(vm.isRunning || vm.untestedCredentials.isEmpty)
        } header: {
            Text("Quick Actions")
        }
        .sheet(isPresented: $showSelectTesting) {
            selectTestingSheet
        }
    }

    private var autoRetrySection: some View {
        Section {
            Toggle(isOn: $vm.autoRetryEnabled) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(.mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-Retry Failed").font(.body)
                        Text("Requeue timeout/connection failures with backoff").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.mint)
            .sensoryFeedback(.impact(weight: .light), trigger: vm.autoRetryEnabled)

            if vm.autoRetryEnabled {
                Stepper(value: $vm.autoRetryMaxAttempts, in: 1...5) {
                    HStack(spacing: 10) {
                        Image(systemName: "number.circle").foregroundStyle(.mint)
                        Text("Max Retries: \(vm.autoRetryMaxAttempts)")
                    }
                }
            }
        } header: {
            Text("Auto-Retry")
        } footer: {
            Text(vm.autoRetryEnabled ? "Credentials that fail due to timeout or connection issues will be automatically retried up to \(vm.autoRetryMaxAttempts) time(s) with increasing delay." : "Enable to automatically retry credentials that fail due to network issues.")
        }
    }

    private var stealthSection: some View {
        Section {
            Toggle(isOn: $vm.stealthEnabled) {
                HStack(spacing: 10) {
                    Image(systemName: "eye.slash.fill").foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ultra Stealth Mode").font(.body)
                        Text("Rotating user agents, fingerprints & viewports").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.purple)
            .sensoryFeedback(.impact(weight: .light), trigger: vm.stealthEnabled)
        } header: {
            Text("Stealth")
        } footer: {
            Text(vm.stealthEnabled ? "Each session uses a unique browser identity. Complete history wipe between tests." : "Enable to rotate browser fingerprints across sessions.")
        }
    }

    private var concurrencySection: some View {
        Section {
            Picker("Max Sessions", selection: $vm.maxConcurrency) {
                ForEach(1...8, id: \.self) { n in Text("\(n)").tag(n) }
            }
            .pickerStyle(.menu)
            .disabled(vm.isSlowDebugModeEnabled)

            if vm.isSlowDebugModeEnabled {
                Label("Slow Debug Mode from Automation Config forces 1 active session.", systemImage: "tortoise.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text("Test Timeout")
                Spacer()
                Picker("Timeout", selection: Binding(
                    get: { Int(vm.testTimeout) },
                    set: { vm.testTimeout = TimeInterval($0) }
                )) {
                    Text("90s").tag(90)
                    Text("120s").tag(120)
                    Text("150s").tag(150)
                }
                .pickerStyle(.menu)
            }
        } header: {
            Text("Concurrency")
        } footer: {
            Text("Configured max: \(vm.maxConcurrency). Active max: \(vm.effectiveMaxConcurrency). Timeout per test: \(Int(vm.testTimeout))s.")
        }
    }

    private var debugSection: some View {
        Section {
            Toggle(isOn: $vm.debugMode) {
                HStack(spacing: 10) {
                    Image(systemName: "ladybug.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Debug Mode").font(.body)
                        Text("Captures screenshots + detailed evaluation per test").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.orange)

            if vm.debugMode {
                Button { showDebugScreenshots = true } label: {
                    HStack {
                        Image(systemName: "photo.stack").foregroundStyle(.orange)
                        Text("Debug Screenshots").foregroundStyle(.primary)
                        Spacer()
                        Text("\(vm.debugScreenshots.count)").font(.system(.caption, design: .monospaced, weight: .bold)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }

                if !vm.debugScreenshots.isEmpty {
                    let passCount = vm.debugScreenshots.filter({ $0.effectiveResult == .markedPass }).count
                    let failCount = vm.debugScreenshots.filter({ $0.effectiveResult == .markedFail }).count
                    let unknownCount = vm.debugScreenshots.filter({ $0.effectiveResult == .none }).count
                    HStack(spacing: 12) {
                        if passCount > 0 {
                            Label("\(passCount) pass", systemImage: "checkmark.circle.fill")
                                .font(.caption.bold()).foregroundStyle(.green)
                        }
                        if failCount > 0 {
                            Label("\(failCount) fail", systemImage: "xmark.circle.fill")
                                .font(.caption.bold()).foregroundStyle(.red)
                        }
                        if unknownCount > 0 {
                            Label("\(unknownCount) uncertain", systemImage: "questionmark.circle.fill")
                                .font(.caption.bold()).foregroundStyle(.orange)
                        }
                        Spacer()
                    }

                    Button(role: .destructive) { vm.clearDebugScreenshots() } label: { Label("Clear All Screenshots", systemImage: "trash") }
                }
            }
        } header: {
            Text("Debug")
        } footer: {
            if vm.debugMode {
                Text("Screenshots are always captured for session previews. Debug mode adds them to the Debug tab for review and correction.")
            }
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker(selection: $vm.appearanceMode) {
                ForEach(AppAppearanceMode.allCases, id: \.self) { mode in
                    Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                }
            } label: {
                HStack(spacing: 10) { Image(systemName: "paintbrush.fill").foregroundStyle(.purple); Text("Appearance") }
            }

            if vm.isIgnitionMode {
                HStack(spacing: 10) {
                    Image(systemName: "moon.fill").foregroundStyle(.orange)
                    Text("Ignition Dark Mode")
                    Spacer()
                    Text("Active").font(.caption.bold()).foregroundStyle(.orange)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.orange.opacity(0.12)).clipShape(Capsule())
                }
            }
        } header: {
            Text("Appearance")
        } footer: {
            if vm.isIgnitionMode {
                Text("Dark mode is forced while in Ignition mode.")
            }
        }
    }

    private var iCloudSection: some View {
        Section {
            Button { vm.syncFromiCloud() } label: {
                HStack(spacing: 10) { Image(systemName: "icloud.and.arrow.down").foregroundStyle(.blue); Text("Sync from iCloud") }
            }
            Button {
                vm.persistCredentials()
                vm.log("Forced save to local + iCloud", level: .success)
            } label: {
                HStack(spacing: 10) { Image(systemName: "icloud.and.arrow.up").foregroundStyle(.blue); Text("Force Save to iCloud") }
            }
        } header: {
            Text("iCloud Sync")
        }
    }

    private var blacklistSection: some View {
        Section {
            Toggle(isOn: Bindable(vm.blacklistService).autoExcludeBlacklist) {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.slash.fill").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-Exclude Blacklist").font(.body)
                        Text("Skip blacklisted accounts during import").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.red)

            Toggle(isOn: Bindable(vm.blacklistService).autoBlacklistNoAcc) {
                HStack(spacing: 10) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-Blacklist No Account").font(.body)
                        Text("Add no-acc results to blacklist automatically").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.orange)

            HStack(spacing: 10) {
                Image(systemName: "hand.raised.slash.fill").foregroundStyle(.red)
                Text("Blacklisted")
                Spacer()
                Text("\(vm.blacklistService.blacklistedEmails.count)")
                    .font(.system(.caption, design: .monospaced, weight: .bold)).foregroundStyle(.secondary)
            }
        } header: {
            Text("Blacklist")
        } footer: {
            Text("Blacklisted emails are excluded from import queues. Manage the full blacklist in the More tab.")
        }
    }

    private var selectTestingSheet: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button("Select All") {
                            selectedCredentialIds = Set(vm.untestedCredentials.map(\.id))
                        }
                        Spacer()
                        Button("Deselect All") {
                            selectedCredentialIds.removeAll()
                        }
                    }
                    .font(.subheadline.bold())
                }
                Section {
                    ForEach(vm.untestedCredentials) { cred in
                        Button {
                            if selectedCredentialIds.contains(cred.id) {
                                selectedCredentialIds.remove(cred.id)
                            } else {
                                selectedCredentialIds.insert(cred.id)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedCredentialIds.contains(cred.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedCredentialIds.contains(cred.id) ? accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cred.username)
                                        .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(cred.maskedPassword)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                            }
                        }
                    }
                } header: {
                    Text("\(selectedCredentialIds.count) of \(vm.untestedCredentials.count) selected")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Select Credentials")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showSelectTesting = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Test \(selectedCredentialIds.count)") {
                        showSelectTesting = false
                        vm.testSelectedCredentials(ids: selectedCredentialIds)
                    }
                    .disabled(selectedCredentialIds.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: "10.1")
            LabeledContent("Engine", value: "WKWebView Live")
            LabeledContent("Storage", value: "Local + iCloud")
            LabeledContent("Stealth") { Text(vm.stealthEnabled ? "Ultra Stealth" : "Standard").foregroundStyle(vm.stealthEnabled ? .purple : .secondary) }
            LabeledContent("Mode") {
                Text("Unified Sessions V4.1")
                    .foregroundStyle(.cyan)
            }
            LabeledContent("Session Wipe") { Text("Full — cookies, cache, storage").foregroundStyle(.cyan) }
            Button(role: .destructive) { vm.clearAll() } label: { Label("Clear Session History", systemImage: "trash") }
        } header: {
            Text("About")
        }
    }
}
