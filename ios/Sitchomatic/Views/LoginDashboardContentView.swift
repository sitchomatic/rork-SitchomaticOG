import SwiftUI

struct LoginDashboardContentView: View {
    let vm: LoginViewModel
    @State private var showSelectTesting: Bool = false
    @State private var selectedCredentialIds: Set<String> = []
    @State private var showPurgeNoAccConfirm: Bool = false
    @State private var showPurgePermDisabledConfirm: Bool = false
    @State private var showPurgeUnsureConfirm: Bool = false
    @State private var proxyService = ProxyRotationService.shared

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                statusHeader
                NetworkTruthPanelView()
                if vm.isIgnitionMode {
                    regionToggle
                }
                dashboardActionButtons
                if vm.isRunning {
                    testingBanner
                    queueControls
                }
                if vm.stealthEnabled {
                    stealthBadge
                }
                statsRow
                if !vm.untestedCredentials.isEmpty {
                    credentialSection(title: "Queued — Untested", creds: Array(vm.untestedCredentials.prefix(50)), color: .secondary, icon: "clock.fill")
                }
                if !vm.testingCredentials.isEmpty {
                    credentialSection(title: "Testing Now", creds: vm.testingCredentials, color: .green, icon: "arrow.triangle.2.circlepath")
                }
                if !vm.noAccCredentials.isEmpty {
                    noAccSection
                }
                if !vm.permDisabledCredentials.isEmpty {
                    permDisabledSection
                }
                if !vm.tempDisabledCredentials.isEmpty {
                    tempDisabledSection
                }
                if !vm.unsureCredentials.isEmpty {
                    unsureSection
                }
                if vm.credentials.isEmpty {
                    emptyState
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Dashboard")
        .refreshable {
            await vm.testConnection()
        }
        .task {
            await vm.testConnection()
        }
    }

    private var statusHeader: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: vm.urlRotation.currentIcon)
                    .font(.system(size: 32))
                    .foregroundStyle(vm.isIgnitionMode ? .orange : .green)
                    .symbolEffect(.pulse, isActive: vm.isRunning)

                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.urlRotation.currentSiteName)
                        .font(.title3.bold())
                    Text("\(vm.urlRotation.enabledURLs.count)/\(vm.urlRotation.activeURLs.count) URLs active")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                connectionBadge
            }

            multiSessionControl
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private var multiSessionControl: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.cyan)
                Text("MULTI SESSION TEST")
                    .font(.system(.caption, design: .monospaced, weight: .heavy))
                    .foregroundStyle(.cyan)
                Spacer()
                Text("\(vm.effectiveMaxConcurrency) session\(vm.effectiveMaxConcurrency == 1 ? "" : "s")")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.cyan.opacity(0.12))
                    .clipShape(Capsule())
            }

            HStack(spacing: 6) {
                Button {
                    withAnimation(.spring(duration: 0.25)) {
                        vm.maxConcurrency = max(1, vm.maxConcurrency - 1)
                    }
                } label: {
                    Image(systemName: "minus")
                        .font(.caption.bold())
                        .frame(width: 32, height: 32)
                        .background(Color(.tertiarySystemFill))
                        .foregroundStyle(.primary)
                        .clipShape(.rect(cornerRadius: 8))
                }
                .disabled(vm.maxConcurrency <= 1 || vm.isSlowDebugModeEnabled)

                GeometryReader { geo in
                    let maxSessions = 8
                    let filledWidth = geo.size.width * CGFloat(vm.effectiveMaxConcurrency) / CGFloat(maxSessions)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(.quaternarySystemFill))
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                LinearGradient(
                                    colors: [.cyan, .cyan.opacity(0.7)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: filledWidth)
                    }
                }
                .frame(height: 32)

                Button {
                    withAnimation(.spring(duration: 0.25)) {
                        vm.maxConcurrency = min(8, vm.maxConcurrency + 1)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.bold())
                        .frame(width: 32, height: 32)
                        .background(Color(.tertiarySystemFill))
                        .foregroundStyle(.primary)
                        .clipShape(.rect(cornerRadius: 8))
                }
                .disabled(vm.maxConcurrency >= 8 || vm.isSlowDebugModeEnabled)
            }
            if vm.isSlowDebugModeEnabled {
                Label("Slow Debug Mode is active — login automation is locked to 1 session.", systemImage: "tortoise.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(Color.cyan.opacity(0.06))
        .clipShape(.rect(cornerRadius: 10))
        .sensoryFeedback(.impact(weight: .medium), trigger: vm.effectiveMaxConcurrency)
    }

    private var connectionBadge: some View {
        Button {
            Task { await vm.testConnection() }
        } label: {
            HStack(spacing: 4) {
                if vm.connectionStatus == .connecting {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(connectionColor).frame(width: 7, height: 7)
                }
                Text(vm.connectionStatus == .connecting ? "Testing..." : vm.connectionStatus.rawValue)
                    .font(.caption2.bold())
                    .foregroundStyle(connectionColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(connectionColor.opacity(0.12))
            .clipShape(Capsule())
        }
        .sensoryFeedback(.impact(weight: .light), trigger: vm.connectionStatus.rawValue)
    }

    private var connectionColor: Color {
        switch vm.connectionStatus {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .secondary
        case .error: .red
        }
    }

    private var accentColor: Color {
        vm.isIgnitionMode ? .orange : .green
    }

    private var regionToggle: some View {
        HStack(spacing: 12) {
            Image(systemName: proxyService.networkRegion == .usa ? "flag.fill" : "globe.asia.australia.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(proxyService.networkRegion == .usa ? .blue : .orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Region")
                    .font(.subheadline.bold())
                Text(proxyService.networkRegion.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
        .sensoryFeedback(.impact(weight: .medium), trigger: proxyService.networkRegion)
    }

    private var stealthBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash.fill").font(.caption).foregroundStyle(.purple)
            Text("Ultra Stealth + Full Wipe").font(.caption.bold()).foregroundStyle(.purple)
            Spacer()
            Text("Rotating UA + Fingerprints").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.purple.opacity(0.08))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var testingBanner: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().tint(accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Testing in Progress").font(.subheadline.bold()).foregroundStyle(accentColor)
                        if vm.isPaused {
                            Text(vm.pauseCountdown > 0 ? "PAUSED \(vm.pauseCountdown)s" : "PAUSED")
                                .font(.system(.caption2, design: .monospaced, weight: .heavy))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15)).clipShape(Capsule())
                                .contentTransition(.numericText(value: Double(vm.pauseCountdown)))
                                .animation(.snappy, value: vm.pauseCountdown)
                        }
                        if vm.isStopping {
                            Text("STOPPING")
                                .font(.system(.caption2, design: .monospaced, weight: .heavy))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.red.opacity(0.15)).clipShape(Capsule())
                        }
                    }
                    Text("\(vm.activeAttempts.count) active · \(vm.untestedCredentials.count) queued · \(vm.testingCredentials.count) testing")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if vm.batchTotalCount > 0 {
                VStack(spacing: 4) {
                    ProgressView(value: vm.batchProgress)
                        .tint(accentColor)
                    HStack {
                        Text("\(vm.batchCompletedCount)/\(vm.batchTotalCount) completed")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(vm.batchProgress * 100))%")
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(accentColor)
                            .contentTransition(.numericText())
                    }
                }
            }
        }
        .padding(14)
        .background(Color.green.opacity(0.08))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var queueControls: some View {
        HStack(spacing: 10) {
            if vm.isPaused {
                Button { vm.resumeQueue() } label: {
                    VStack(spacing: 4) {
                        Label("Resume Now", systemImage: "play.fill")
                            .font(.subheadline.bold())
                        if vm.pauseCountdown > 0 {
                            Text("Auto-resume in \(vm.pauseCountdown)s")
                                .font(.system(.caption2, design: .monospaced))
                                .contentTransition(.numericText(value: Double(vm.pauseCountdown)))
                                .animation(.snappy, value: vm.pauseCountdown)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Color.green.opacity(0.15)).foregroundStyle(.green).clipShape(.rect(cornerRadius: 12))
                }
            } else {
                Button { vm.pauseQueue() } label: {
                    Label("Pause 60s", systemImage: "pause.fill")
                        .font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.orange.opacity(0.15)).foregroundStyle(.orange).clipShape(.rect(cornerRadius: 12))
                }
                .disabled(vm.isStopping)
            }
            Button { vm.stopQueue() } label: {
                VStack(spacing: 4) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.subheadline.bold())
                    Text("Finish current batch")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Color.red.opacity(0.15)).foregroundStyle(.red).clipShape(.rect(cornerRadius: 12))
            }
            .disabled(vm.isStopping)
            .sensoryFeedback(.warning, trigger: vm.isStopping)
        }
    }

    private var statsRow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                LoginMiniStat(value: "\(vm.workingCredentials.count)", label: "Working", color: .green, icon: "checkmark.circle.fill")
                LoginMiniStat(value: "\(vm.untestedCredentials.count)", label: "Queued", color: .secondary, icon: "clock")
                LoginMiniStat(value: "\(vm.noAccCredentials.count)", label: "No Acc", color: .red, icon: "xmark.circle.fill")
            }
            HStack(spacing: 10) {
                LoginMiniStat(value: "\(vm.permDisabledCredentials.count)", label: "Perm Dis", color: .red.opacity(0.7), icon: "lock.slash.fill")
                LoginMiniStat(value: "\(vm.tempDisabledCredentials.count)", label: "Temp Dis", color: .orange, icon: "clock.badge.exclamationmark")
                LoginMiniStat(value: "\(vm.unsureCredentials.count)", label: "Unsure", color: .yellow, icon: "questionmark.circle.fill")
            }
            HStack(spacing: 10) {
                LoginMiniStat(value: "\(vm.credentials.count)", label: "Total", color: .blue, icon: "person.2.fill")
            }
        }
    }

    private func credentialSection(title: String, creds: [LoginCredential], color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.subheadline).foregroundStyle(color)
                Text(title).font(.headline)
                Spacer()
                Text("\(creds.count)")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(color.opacity(0.12)).clipShape(Capsule()).foregroundStyle(color)
            }
            ForEach(creds) { cred in
                LoginCredentialRow(credential: cred, accentColor: color)
            }
        }
    }

    private var noAccSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill").font(.subheadline).foregroundStyle(.red)
                Text("No Account").font(.headline)
                Spacer()
                Text("\(vm.noAccCredentials.count)")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.red.opacity(0.12)).clipShape(Capsule()).foregroundStyle(.red)
                Button { showPurgeNoAccConfirm = true } label: {
                    Text("Purge All").font(.caption.bold()).foregroundStyle(.red)
                }
                .alert("Purge No Account", isPresented: $showPurgeNoAccConfirm) {
                    Button("Purge \(vm.noAccCredentials.count)", role: .destructive) { vm.purgeNoAccCredentials() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will permanently remove \(vm.noAccCredentials.count) credential(s) with no account. This cannot be undone.")
                }
            }
            ForEach(vm.noAccCredentials) { cred in
                LoginCredentialRow(credential: cred, accentColor: .red)
            }
        }
    }

    private var permDisabledSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "lock.slash.fill").font(.subheadline).foregroundStyle(.red.opacity(0.7))
                Text("Perm Disabled").font(.headline)
                Spacer()
                Text("\(vm.permDisabledCredentials.count)")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.red.opacity(0.08)).clipShape(Capsule()).foregroundStyle(.red.opacity(0.7))
                Button { showPurgePermDisabledConfirm = true } label: {
                    Text("Purge").font(.caption.bold()).foregroundStyle(.red.opacity(0.7))
                }
                .alert("Purge Perm Disabled", isPresented: $showPurgePermDisabledConfirm) {
                    Button("Purge \(vm.permDisabledCredentials.count)", role: .destructive) { vm.purgePermDisabledCredentials() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will permanently remove \(vm.permDisabledCredentials.count) permanently disabled credential(s). This cannot be undone.")
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red.opacity(0.7))
                Text("Permanently disabled/blacklisted. Excluded from queue.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.04)).clipShape(.rect(cornerRadius: 8))
            ForEach(vm.permDisabledCredentials) { cred in
                LoginCredentialRow(credential: cred, accentColor: .red.opacity(0.7))
            }
        }
    }

    private var tempDisabledSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.exclamationmark").font(.subheadline).foregroundStyle(.orange)
                Text("Temp Disabled").font(.headline)
                Spacer()
                Text("\(vm.tempDisabledCredentials.count)")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12)).clipShape(Capsule()).foregroundStyle(.orange)
            }
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill").font(.caption2).foregroundStyle(.orange)
                Text("Temporarily locked. Assign passwords in Temp Disabled tab.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.06)).clipShape(.rect(cornerRadius: 8))
            ForEach(vm.tempDisabledCredentials) { cred in
                LoginCredentialRow(credential: cred, accentColor: .orange)
            }
        }
    }

    private var unsureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill").font(.subheadline).foregroundStyle(.yellow)
                Text("Unsure").font(.headline)
                Spacer()
                Text("\(vm.unsureCredentials.count)")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.yellow.opacity(0.12)).clipShape(Capsule()).foregroundStyle(.yellow)
                Button { showPurgeUnsureConfirm = true } label: {
                    Text("Purge").font(.caption.bold()).foregroundStyle(.yellow)
                }
                .alert("Purge Unsure", isPresented: $showPurgeUnsureConfirm) {
                    Button("Purge \(vm.unsureCredentials.count)", role: .destructive) { vm.purgeUnsureCredentials() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will permanently remove \(vm.unsureCredentials.count) unsure credential(s). This cannot be undone.")
                }
            }
            ForEach(vm.unsureCredentials) { cred in
                LoginCredentialRow(credential: cred, accentColor: .yellow)
            }
        }
    }

    private var dashboardActionButtons: some View {
        HStack(spacing: 10) {
            Button {
                vm.testAllUntested()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text("Test All Untested")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(vm.isRunning ? accentColor.opacity(0.3) : accentColor)
                .foregroundStyle(.white)
                .clipShape(.rect(cornerRadius: 12))
            }
            .disabled(vm.isRunning || vm.untestedCredentials.isEmpty)
            .sensoryFeedback(.impact(weight: .heavy), trigger: vm.isRunning)

            Button {
                selectedCredentialIds = Set(vm.untestedCredentials.map(\.id))
                showSelectTesting = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checklist")
                    Text("Select Testing")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(.tertiarySystemFill))
                .foregroundStyle(.primary)
                .clipShape(.rect(cornerRadius: 12))
            }
            .disabled(vm.isRunning || vm.untestedCredentials.isEmpty)
        }
        .sheet(isPresented: $showSelectTesting) {
            selectTestingSheet
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

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 52))
                .foregroundStyle(accentColor.opacity(0.5))
                .symbolEffect(.pulse.byLayer, options: .repeating)
            Text("No Credentials Added")
                .font(.title3.bold())
            Text("Go to Credentials tab to import.\nSupports email:password format.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 48)
    }
}

struct LoginMiniStat: View {
    let value: String
    let label: String
    let color: Color
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(color)
            Text(value).font(.system(.title3, design: .monospaced, weight: .bold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }
}

struct LoginCredentialRow: View {
    let credential: LoginCredential
    let accentColor: Color

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(accentColor.opacity(0.12)).frame(width: 38, height: 38)
                Image(systemName: "person.fill").font(.title3).foregroundStyle(accentColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(credential.username)
                    .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.primary).lineLimit(1)
                HStack(spacing: 8) {
                    Text(credential.maskedPassword)
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                    if credential.totalTests > 0 {
                        Text("\(credential.successCount)/\(credential.totalTests) passed")
                            .font(.caption2)
                            .foregroundStyle(credential.status == .working ? .green : .red)
                    }
                }
            }
            Spacer()
            if credential.status == .testing {
                ProgressView().tint(.green)
            } else {
                HStack(spacing: 3) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(credential.status.rawValue).font(.system(.caption2, design: .monospaced)).foregroundStyle(statusColor)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var statusColor: Color {
        switch credential.status {
        case .working: .green
        case .noAcc: .red
        case .permDisabled: .red.opacity(0.7)
        case .tempDisabled: .orange
        case .unsure: .yellow
        case .testing: .green
        case .untested: .secondary
        }
    }
}
