import SwiftUI

struct UnifiedSessionFeedView: View {
    @State private var vm = UnifiedSessionViewModel.shared
    @State private var showImportSheet: Bool = false
    @State private var importText: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    statusHeader
                    concurrencyControl

                    if vm.sessions.isEmpty {
                        emptyState
                    } else {
                        statsRow

                        if !vm.activeSessions.isEmpty {
                            sessionSection(title: "Active", sessions: vm.activeSessions, color: .cyan, icon: "bolt.fill")
                        }
                        if !vm.successSessions.isEmpty {
                            sessionSection(title: "Success", sessions: vm.successSessions, color: .green, icon: "checkmark.circle.fill")
                        }
                        if !vm.permBannedSessions.isEmpty {
                            sessionSection(title: "Permanent Disable", sessions: vm.permBannedSessions, color: .red, icon: "lock.slash.fill")
                        }
                        if !vm.tempLockedSessions.isEmpty {
                            sessionSection(title: "Temp Disabled", sessions: vm.tempLockedSessions, color: .orange, icon: "clock.badge.exclamationmark")
                        }
                        if !vm.noAccountSessions.isEmpty {
                            sessionSection(title: "No Account", sessions: vm.noAccountSessions, color: .secondary, icon: "xmark.circle.fill")
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Unified Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImportSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            }
        }
        .withMainMenuButton()
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showImportSheet) {
            importSheet
        }
        .withBatchAlerts(
            showBatchResult: .constant(false),
            batchResult: nil,
            isRunning: $vm.isRunning,
            onDismissBatch: {}
        )
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

                VStack(alignment: .leading, spacing: 2) {
                    Text("Unified Session V4.1")
                        .font(.title3.bold())
                    Text("Joe Fortune + Ignition · Paired Testing")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if vm.isRunning {
                    ProgressView()
                        .tint(.cyan)
                }
            }

            if vm.isRunning && !vm.sessions.isEmpty {
                VStack(spacing: 4) {
                    ProgressView(value: vm.batchProgress)
                        .tint(.cyan)
                    HStack {
                        Text("\(vm.completedSessions.count)/\(vm.sessions.count) completed")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(vm.batchProgress * 100))%")
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(.cyan)
                            .contentTransition(.numericText())
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private var concurrencyControl: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.cyan)
                Text("CONCURRENT WORKERS")
                    .font(.system(.caption, design: .monospaced, weight: .heavy))
                    .foregroundStyle(.cyan)
                Spacer()
                Text("\(vm.maxConcurrency) worker\(vm.maxConcurrency == 1 ? "" : "s")")
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
                .disabled(vm.maxConcurrency <= 1)

                GeometryReader { geo in
                    let maxWorkers = 8
                    let filledWidth = geo.size.width * CGFloat(vm.maxConcurrency) / CGFloat(maxWorkers)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(.quaternarySystemFill))
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                LinearGradient(
                                    colors: [.green, .orange],
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
                .disabled(vm.maxConcurrency >= 8)
            }

            HStack(spacing: 10) {
                if vm.isRunning {
                    if vm.isPaused {
                        Button { vm.resumeBatch() } label: {
                            Label("Resume", systemImage: "play.fill")
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.green.opacity(0.15))
                                .foregroundStyle(.green)
                                .clipShape(.rect(cornerRadius: 10))
                        }
                    } else {
                        Button { vm.pauseBatch() } label: {
                            Label("Pause", systemImage: "pause.fill")
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.orange.opacity(0.15))
                                .foregroundStyle(.orange)
                                .clipShape(.rect(cornerRadius: 10))
                        }
                    }

                    Button { vm.stopBatch() } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.red.opacity(0.15))
                            .foregroundStyle(.red)
                            .clipShape(.rect(cornerRadius: 10))
                    }
                    .disabled(vm.isStopping)
                } else {
                    Button { vm.startBatch() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("START UNIFIED TEST")
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
                    .disabled(vm.sessions.isEmpty || vm.pendingSessions.isEmpty)
                    .sensoryFeedback(.impact(weight: .heavy), trigger: vm.isRunning)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
        .sensoryFeedback(.impact(weight: .medium), trigger: vm.maxConcurrency)
    }

    private var statsRow: some View {
        HStack(spacing: 8) {
            UnifiedMiniStat(value: "\(vm.successSessions.count)", label: "Success", color: .green, icon: "checkmark.circle.fill")
            UnifiedMiniStat(value: "\(vm.permBannedSessions.count)", label: "Perm", color: .red, icon: "lock.slash.fill")
            UnifiedMiniStat(value: "\(vm.tempLockedSessions.count)", label: "Temp", color: .orange, icon: "clock.badge.exclamationmark")
            UnifiedMiniStat(value: "\(vm.noAccountSessions.count)", label: "No Acc", color: .secondary, icon: "xmark.circle.fill")
        }
    }

    private func sessionSection(title: String, sessions: [DualSiteSession], color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(sessions.count)")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.12))
                    .clipShape(Capsule())
                    .foregroundStyle(color)
            }

            ForEach(sessions) { session in
                DualSessionRow(session: session)
            }
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

            Text("Unified Session Feed")
                .font(.title3.bold())
            Text("Import credentials to begin paired testing.\nEach credential tests Joe Fortune + Ignition simultaneously\nwith shared proxy & fingerprint identity.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("V4.1 — 4 concurrent workers · 4 attempts per site · Early-stop sync")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
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
}

struct DualSessionRow: View {
    let session: DualSiteSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.credential.email)
                        .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                        .lineLimit(1)
                    Text(session.credential.maskedPassword)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    classificationBadge
                    Text(session.formattedDuration)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            HStack(spacing: 8) {
                siteStatus(
                    icon: "suit.spade.fill",
                    name: "JOE",
                    color: .green,
                    attempts: session.joeAttempts.count,
                    maxAttempts: session.maxAttempts
                )

                siteStatus(
                    icon: "flame.fill",
                    name: "IGN",
                    color: .orange,
                    attempts: session.ignitionAttempts.count,
                    maxAttempts: session.maxAttempts
                )
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func siteStatus(icon: String, name: String, color: Color, attempts: Int, maxAttempts: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
            Text(name)
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(color)
            Spacer()
            HStack(spacing: 2) {
                ForEach(0..<maxAttempts, id: \.self) { i in
                    Circle()
                        .fill(i < attempts ? color : color.opacity(0.15))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(color.opacity(0.06))
        .clipShape(.rect(cornerRadius: 8))
    }

    private var classificationBadge: some View {
        let (text, color) = classificationInfo
        return Text(text)
            .font(.system(.caption2, design: .monospaced, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private var classificationInfo: (String, Color) {
        switch session.classification {
        case .validAccount: return ("SUCCESS", .green)
        case .permanentBan: return ("PERM BAN", .red)
        case .temporaryLock: return ("TEMP LOCK", .orange)
        case .noAccount: return ("NO ACC", .secondary)
        case .pending:
            if session.globalState == .active {
                return ("ACTIVE", .cyan)
            }
            return ("PENDING", .secondary)
        }
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
