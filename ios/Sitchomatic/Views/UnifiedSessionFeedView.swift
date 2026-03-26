import SwiftUI
import UIKit

struct UnifiedSessionFeedView: View {
    @State private var vm = UnifiedSessionViewModel.shared
    @State private var screenshotManager = UnifiedScreenshotManager.shared
    @State private var showImportSheet: Bool = false
    @State private var showImportFromLogin: Bool = false
    @State private var importText: String = ""
    @State private var filterOption: SessionFilterOption = .all
    @State private var selectedSession: DualSiteSession?
    @State private var showExportSheet: Bool = false
    @State private var showClearConfirm: Bool = false
    @State private var showLogSheet: Bool = false
    @State private var activeTab: DashboardTab = .sessions

    nonisolated enum DashboardTab: String, CaseIterable, Sendable {
        case sessions = "Sessions"
        case screenshots = "Screenshots"
    }

    nonisolated enum SessionFilterOption: String, CaseIterable, Identifiable, Sendable {
        case all = "All"
        case active = "Active"
        case success = "Success"
        case permBan = "Perm Dis"
        case tempLock = "Temp Dis"
        case noAccount = "No Acc"
        case unsure = "Unsure"
        var id: String { rawValue }

        var color: Color {
            switch self {
            case .all: .primary
            case .active: .cyan
            case .success: .green
            case .permBan: .red
            case .tempLock: .orange
            case .noAccount: .secondary
            case .unsure: .yellow
            }
        }

        var matchingSiteResult: SiteResult? {
            switch self {
            case .all, .active: nil
            case .success: .success
            case .permBan: .permDisabled
            case .tempLock: .tempDisabled
            case .noAccount: .noAccount
            case .unsure: .unsure
            }
        }
    }

    private var filteredSessions: [DualSiteSession] {
        switch filterOption {
        case .all: return vm.sessions
        case .active: return vm.activeSessions
        default:
            guard let target = filterOption.matchingSiteResult else { return vm.sessions }
            return vm.sessions.filter { $0.hasSiteResult(target) }
        }
    }

    private func countFor(_ option: SessionFilterOption) -> Int {
        switch option {
        case .all: return vm.sessions.count
        case .active: return vm.activeSessions.count
        default:
            guard let target = option.matchingSiteResult else { return 0 }
            return vm.sessions.filter { $0.hasSiteResult(target) }.count
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                dashboardTabPicker

                switch activeTab {
                case .sessions:
                    sessionsContent
                case .screenshots:
                    UnifiedScreenshotFeedView()
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Login Testing")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { showLogSheet = true } label: {
                            Label("View Logs", systemImage: "doc.text")
                        }
                        if !vm.completedSessions.isEmpty {
                            Button { showExportSheet = true } label: {
                                Label("Export Results", systemImage: "square.and.arrow.up")
                            }
                        }
                        if !vm.completedSessions.isEmpty {
                            Button { vm.clearCompleted() } label: {
                                Label("Clear Completed", systemImage: "trash")
                            }
                        }
                        if !vm.sessions.isEmpty {
                            Button(role: .destructive) { showClearConfirm = true } label: {
                                Label("Clear All", systemImage: "trash.fill")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showImportSheet = true } label: {
                            Label("Paste Credentials", systemImage: "doc.on.clipboard")
                        }
                        Button { showImportFromLogin = true } label: {
                            Label("Import from Login VM", systemImage: "arrow.down.circle")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
        }
        .withMainMenuButton()
        .preferredColorScheme(.dark)
        .sensoryFeedback(.selection, trigger: activeTab.rawValue)
        .sheet(item: $selectedSession) { session in
            UnifiedSessionDetailSheet(session: session, vm: vm)
        }
        .sheet(isPresented: $showImportSheet) {
            importSheet
        }
        .sheet(isPresented: $showLogSheet) {
            unifiedLogSheet
        }
        .sheet(isPresented: $showExportSheet) {
            exportSheet
        }
        .alert("Import from Login VM?", isPresented: $showImportFromLogin) {
            Button("Import") { vm.importFromLoginVM() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will import all untested credentials from the Login Credentials list into the unified session queue.")
        }
        .alert("Clear All Sessions?", isPresented: $showClearConfirm) {
            Button("Clear All", role: .destructive) { vm.clearSessions() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all \(vm.sessions.count) session(s). This cannot be undone.")
        }
        .onChange(of: vm.isRunning) { _, newValue in
            UIApplication.shared.isIdleTimerDisabled = newValue
        }
    }

    private var dashboardTabPicker: some View {
        HStack(spacing: 0) {
            ForEach(DashboardTab.allCases, id: \.rawValue) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { activeTab = tab }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab == .sessions ? "rectangle.stack" : "camera.viewfinder")
                            .font(.system(size: 12, weight: .bold))
                        Text(tab.rawValue)
                            .font(.system(.caption, design: .monospaced, weight: .heavy))
                        if tab == .screenshots && screenshotManager.screenshots.count > 0 {
                            Text("\(screenshotManager.screenshots.count)")
                                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(activeTab == tab ? .white.opacity(0.2) : .primary.opacity(0.08))
                                .clipShape(Capsule())
                                .contentTransition(.numericText())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(activeTab == tab ? tabColor(tab) : Color(.tertiarySystemGroupedBackground))
                    .foregroundStyle(activeTab == tab ? .white : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(.rect(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func tabColor(_ tab: DashboardTab) -> Color {
        switch tab {
        case .sessions: .cyan.opacity(0.8)
        case .screenshots: .indigo.opacity(0.8)
        }
    }

    private var sessionsContent: some View {
        VStack(spacing: 0) {
            if !vm.sessions.isEmpty {
                filterBar
            }

            ScrollView {
                LazyVStack(spacing: 12) {
                    statusHeader

                    if vm.isRunning {
                        AdaptiveConcurrencyDashboardView(engine: vm.adaptiveEngine)
                        batchProgressCard
                        batchControls
                    }

                    if !vm.isRunning {
                        concurrencyCapControl
                    }

                    if vm.sessions.isEmpty {
                        emptyState
                    } else {
                        statsRow

                        ForEach(filteredSessions, id: \.id) { session in
                            Button { selectedSession = session } label: {
                                PairedSessionTile(session: session)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SessionFilterOption.allCases) { option in
                    LoginSessionFilterChip(
                        title: option.rawValue,
                        count: countFor(option),
                        isSelected: filterOption == option,
                        color: option.color
                    ) {
                        withAnimation(.snappy) { filterOption = option }
                    }
                }
            }
            .padding(.horizontal).padding(.vertical, 10)
        }
    }

    private var statusHeader: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(colors: [.green.opacity(0.3), .orange.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 48, height: 48)
                    HStack(spacing: 2) {
                        Image(systemName: "suit.spade.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.green)
                        Image(systemName: "flame.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                }
                .symbolEffect(.pulse, options: .repeating.speed(0.3), isActive: vm.isRunning)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Login Testing V4.1")
                        .font(.title3.bold())
                    HStack(spacing: 4) {
                        Text("Joe Fortune + Ignition")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if vm.stealthEnabled {
                            Text("STEALTH")
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                .foregroundStyle(.purple)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.purple.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                }

                Spacer()

                if vm.isRunning {
                    VStack(spacing: 2) {
                        Text("\(vm.activeWorkerCount)")
                            .font(.system(.title2, design: .monospaced, weight: .bold))
                            .foregroundStyle(.cyan)
                            .contentTransition(.numericText())
                        Text("active")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Toggle(isOn: $vm.stealthEnabled) {
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.purple)
                    Text("Stealth Mode")
                        .font(.caption.bold())
                }
            }
            .tint(.purple)
            .disabled(vm.isRunning)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private var batchProgressCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(.cyan)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Testing in Progress")
                            .font(.subheadline.bold())
                            .foregroundStyle(.cyan)
                        if vm.isPaused {
                            Text(vm.pauseCountdown > 0 ? "PAUSED \(vm.pauseCountdown)s" : "PAUSED")
                                .font(.system(.caption2, design: .monospaced, weight: .heavy))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .clipShape(Capsule())
                                .contentTransition(.numericText(value: Double(vm.pauseCountdown)))
                                .animation(.snappy, value: vm.pauseCountdown)
                        }
                        if vm.isStopping {
                            Text("STOPPING")
                                .font(.system(.caption2, design: .monospaced, weight: .heavy))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                    Text("\(vm.adaptiveEngine.liveConcurrency)/\(vm.adaptiveEngine.maxCap) AI · \(vm.queuedSessions.count) queued · \(vm.completedSessions.count) done")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(spacing: 4) {
                ProgressView(value: vm.batchProgress)
                    .tint(.cyan)
                HStack {
                    Text("\(vm.completedSessions.count)/\(vm.sessions.count)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(vm.batchElapsed)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(Int(vm.batchProgress * 100))%")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.cyan)
                        .contentTransition(.numericText())
                }
            }
        }
        .padding(14)
        .background(Color.cyan.opacity(0.06))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var batchControls: some View {
        HStack(spacing: 10) {
            if vm.isPaused {
                Button { vm.resumeBatch() } label: {
                    VStack(spacing: 4) {
                        Label("Resume", systemImage: "play.fill")
                            .font(.subheadline.bold())
                        if vm.pauseCountdown > 0 {
                            Text("Auto in \(vm.pauseCountdown)s")
                                .font(.system(.caption2, design: .monospaced))
                                .contentTransition(.numericText(value: Double(vm.pauseCountdown)))
                                .animation(.snappy, value: vm.pauseCountdown)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.15))
                    .foregroundStyle(.green)
                    .clipShape(.rect(cornerRadius: 12))
                }
            } else {
                Button { vm.pauseBatch() } label: {
                    Label("Pause 60s", systemImage: "pause.fill")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(.rect(cornerRadius: 12))
                }
                .disabled(vm.isStopping)
            }

            Button { vm.stopBatch() } label: {
                VStack(spacing: 4) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.subheadline.bold())
                    Text("Finish active")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.red.opacity(0.15))
                .foregroundStyle(.red)
                .clipShape(.rect(cornerRadius: 12))
            }
            .disabled(vm.isStopping)
        }
    }

    private var concurrencyCapControl: some View {
        VStack(spacing: 10) {
            ConcurrencyCapSelector(engine: vm.adaptiveEngine, isRunning: vm.isRunning)

            Button { vm.startBatch() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text("START LOGIN TEST")
                        .font(.system(.caption, design: .monospaced, weight: .heavy))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(colors: [.green, .orange], startPoint: .leading, endPoint: .trailing)
                )
                .foregroundStyle(.black)
                .clipShape(.rect(cornerRadius: 10))
            }
            .disabled(vm.pendingSessions.isEmpty)
            .sensoryFeedback(.impact(weight: .heavy), trigger: vm.isRunning)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 8) {
            UnifiedMiniStat(value: "\(vm.sessionsWithSiteResult(.success).count)", label: "Success", color: .green, icon: "checkmark.circle.fill")
            UnifiedMiniStat(value: "\(vm.sessionsWithSiteResult(.permDisabled).count)", label: "Perm", color: .red, icon: "lock.slash.fill")
            UnifiedMiniStat(value: "\(vm.sessionsWithSiteResult(.tempDisabled).count)", label: "Temp", color: .orange, icon: "clock.badge.exclamationmark")
            UnifiedMiniStat(value: "\(vm.sessionsWithSiteResult(.noAccount).count)", label: "No Acc", color: .secondary, icon: "xmark.circle.fill")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            HStack(spacing: 4) {
                Image(systemName: "suit.spade.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.green.opacity(0.4))
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white.opacity(0.2))
                Image(systemName: "flame.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange.opacity(0.4))
            }
            .symbolEffect(.pulse.byLayer, options: .repeating)

            Text("Login Testing")
                .font(.title3.bold())
            Text("Import credentials to begin paired testing.\nEach credential tests Joe Fortune + Ignition simultaneously\nwith shared proxy & fingerprint identity.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("V4.1 — AI adaptive · 4 attempts · Early-stop sync")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)

            HStack(spacing: 12) {
                Button { showImportSheet = true } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .font(.caption.bold())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(.rect(cornerRadius: 10))
                }

                Button { showImportFromLogin = true } label: {
                    Label("From Login VM", systemImage: "arrow.down.circle")
                        .font(.caption.bold())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(.rect(cornerRadius: 10))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var importSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Paste credentials (email:password per line)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $importText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 150)
                    .padding(8)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 10))

                Button {
                    vm.importCredentials(importText)
                    importText = ""
                    showImportSheet = false
                } label: {
                    Text("Import")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            LinearGradient(colors: [.green, .orange], startPoint: .leading, endPoint: .trailing)
                        )
                        .foregroundStyle(.black)
                        .clipShape(.rect(cornerRadius: 12))
                }
                .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .navigationTitle("Import Credentials")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showImportSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var unifiedLogSheet: some View {
        NavigationStack {
            List(vm.globalLogs) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Text(entry.formattedTime)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 70, alignment: .leading)
                    Text(entry.level.rawValue)
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(logColor(entry.level))
                        .frame(width: 36)
                    Text(entry.message)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .navigationTitle("Unified Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showLogSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    private var exportSheet: some View {
        NavigationStack {
            List {
                Section("Export All Results") {
                    Button {
                        UIPasteboard.general.string = vm.exportResults()
                        showExportSheet = false
                    } label: {
                        Label("Copy CSV to Clipboard", systemImage: "doc.on.doc")
                    }
                }

                Section("Export by Site Result") {
                    ForEach([SiteResult.success, .permDisabled, .tempDisabled, .noAccount, .unsure], id: \.rawValue) { result in
                        let matching = vm.sessionsWithSiteResult(result)
                        if !matching.isEmpty {
                            Button {
                                UIPasteboard.general.string = vm.exportBySiteResult(result)
                                showExportSheet = false
                            } label: {
                                Label("\(result.shortLabel) (\(matching.count))", systemImage: result.icon)
                                    .foregroundStyle(result.color)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showExportSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func logColor(_ level: PPSRLogEntry.Level) -> Color {
        switch level {
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

struct PairedSessionTile: View {
    let session: DualSiteSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                pairedIcon
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.credential.email)
                        .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(session.credential.maskedPassword)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    pairedBadge
                    if session.isTerminal {
                        Text(session.formattedDuration)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    } else if session.currentAttempt > 0 {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Attempt \(session.currentAttempt)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.cyan)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            HStack(spacing: 8) {
                siteProgressBar(
                    icon: "suit.spade.fill",
                    name: "JOE",
                    color: .green,
                    result: session.joeSiteResult,
                    attempts: session.joeAttempts,
                    maxAttempts: session.maxAttempts
                )

                siteProgressBar(
                    icon: "flame.fill",
                    name: "IGN",
                    color: .orange,
                    result: session.ignitionSiteResult,
                    attempts: session.ignitionAttempts,
                    maxAttempts: session.maxAttempts
                )
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            if !session.identity.proxyAddress.isEmpty && session.identity.proxyAddress != "direct" {
                HStack(spacing: 6) {
                    Image(systemName: "network")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Text(session.identity.proxyAddress.prefix(30))
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(session.identity.viewport)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.quaternary)
                    Text(session.identityAction.rawValue)
                        .font(.system(size: 7, weight: .heavy, design: .monospaced))
                        .foregroundStyle(session.identityAction == .burn ? .red : .green)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func siteProgressBar(icon: String, name: String, color: Color, result: SiteResult, attempts: [SiteAttemptResult], maxAttempts: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
            Text(name)
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(color)
            if result.isTerminal {
                Text(result.shortLabel)
                    .font(.system(size: 7, weight: .heavy, design: .monospaced))
                    .foregroundStyle(result.color)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(result.color.opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()
            HStack(spacing: 3) {
                ForEach(0..<maxAttempts, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i < attempts.count ? color : color.opacity(0.12))
                        .frame(width: 14, height: 6)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(color.opacity(0.06))
        .clipShape(.rect(cornerRadius: 8))
    }

    private var pairedIcon: some View {
        Group {
            if !session.isTerminal {
                ZStack {
                    Circle()
                        .fill(session.currentAttempt > 0 ? Color.cyan.opacity(0.15) : Color(.tertiarySystemFill))
                    Image(systemName: session.currentAttempt > 0 ? "bolt.fill" : "clock")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(session.currentAttempt > 0 ? .cyan : .secondary)
                }
            } else {
                let highest = session.highestPriorityResult
                ZStack {
                    if session.hasMixedResults {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [session.joeSiteResult.color.opacity(0.2), session.ignitionSiteResult.color.opacity(0.2)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    } else {
                        Circle()
                            .fill(highest.color.opacity(0.15))
                    }
                    Image(systemName: highest.icon)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(highest.color)
                }
            }
        }
    }

    @ViewBuilder
    private var pairedBadge: some View {
        if !session.isTerminal {
            let isActive = session.globalState == .active && session.currentAttempt > 0
            Text(isActive ? "TESTING" : "QUEUED")
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(isActive ? .cyan : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background((isActive ? Color.cyan : Color.secondary).opacity(0.12))
                .clipShape(Capsule())
        } else if session.hasMixedResults {
            SplitColorBadge(
                joeResult: session.joeSiteResult,
                ignitionResult: session.ignitionSiteResult
            )
        } else {
            let result = session.highestPriorityResult
            Text(result.pluralLabel)
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(result.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(result.color.opacity(0.12))
                .clipShape(Capsule())
        }
    }
}

struct SplitColorBadge: View {
    let joeResult: SiteResult
    let ignitionResult: SiteResult

    var body: some View {
        HStack(spacing: 0) {
            Text(joeResult.shortLabel)
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(joeResult.color)
                .padding(.leading, 7)
                .padding(.trailing, 3)
                .padding(.vertical, 3)
                .background(joeResult.color.opacity(0.12))

            Rectangle()
                .fill(.quaternary)
                .frame(width: 1)
                .padding(.vertical, 2)

            Text(ignitionResult.shortLabel)
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(ignitionResult.color)
                .padding(.leading, 3)
                .padding(.trailing, 7)
                .padding(.vertical, 3)
                .background(ignitionResult.color.opacity(0.12))
        }
        .clipShape(Capsule())
    }
}

struct UnifiedSessionDetailSheet: View {
    let session: DualSiteSession
    let vm: UnifiedSessionViewModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        siteResultPill(icon: "suit.spade.fill", name: "Joe", result: session.joeSiteResult, siteColor: .green)
                        siteResultPill(icon: "flame.fill", name: "Ignition", result: session.ignitionSiteResult, siteColor: .orange)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }

                Section("Credential") {
                    LabeledContent("Email") {
                        Text(session.credential.email)
                            .font(.system(.caption, design: .monospaced))
                    }
                    LabeledContent("Password") {
                        Text(session.credential.maskedPassword)
                            .font(.system(.caption, design: .monospaced))
                    }
                    LabeledContent("Paired Result") {
                        Text(session.pairedBadgeText)
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(session.highestPriorityResult.color)
                    }
                    LabeledContent("Duration", value: session.formattedDuration)
                    LabeledContent("Identity Action") {
                        Text(session.identityAction.rawValue)
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(session.identityAction == .burn ? .red : .green)
                    }
                }

                Section("Identity") {
                    LabeledContent("Proxy") {
                        Text(session.identity.proxyAddress)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Viewport") {
                        Text(session.identity.viewport)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Canvas") {
                        Text(session.identity.canvasFingerprint)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Joe Fortune — \(session.joeSiteResult.shortLabel) (\(session.joeAttempts.count)/\(session.maxAttempts))") {
                    if session.joeAttempts.isEmpty {
                        Text("No attempts yet").foregroundStyle(.secondary)
                    } else {
                        ForEach(session.joeAttempts, id: \.attemptNumber) { attempt in
                            attemptRow(attempt, color: .green)
                        }
                    }
                }

                Section("Ignition — \(session.ignitionSiteResult.shortLabel) (\(session.ignitionAttempts.count)/\(session.maxAttempts))") {
                    if session.ignitionAttempts.isEmpty {
                        Text("No attempts yet").foregroundStyle(.secondary)
                    } else {
                        ForEach(session.ignitionAttempts, id: \.attemptNumber) { attempt in
                            attemptRow(attempt, color: .orange)
                        }
                    }
                }

                if session.isTerminal {
                    Section {
                        Button {
                            vm.resetSession(session)
                        } label: {
                            Label("Reset & Requeue", systemImage: "arrow.counterclockwise")
                        }

                        Button(role: .destructive) {
                            vm.removeSession(session)
                        } label: {
                            Label("Remove Session", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Session Detail")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    private func siteResultPill(icon: String, name: String, result: SiteResult, siteColor: Color) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(siteColor)
                Text(name)
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(siteColor)
            }
            HStack(spacing: 5) {
                Image(systemName: result.icon)
                    .font(.system(size: 11, weight: .bold))
                Text(result.shortLabel)
                    .font(.system(.caption2, design: .monospaced, weight: .heavy))
            }
            .foregroundStyle(result.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(result.color.opacity(0.12))
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func attemptRow(_ attempt: SiteAttemptResult, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("#\(attempt.attemptNumber)")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(color)
                Spacer()
                Text("\(attempt.durationMs)ms")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Text(attempt.responseText)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

struct UnifiedMiniStat: View {
    let value: String
    let label: String
    let color: Color
    let icon: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text(value)
                .font(.system(.subheadline, design: .monospaced, weight: .bold))
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }
}
