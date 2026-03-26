import SwiftUI

struct LoginDashboardView: View {
    @Bindable var vm: PPSRAutomationViewModel
    @State private var binFilter: String = ""
    @State private var showBINFilter: Bool = false
    @State private var showPurgeDeadConfirm: Bool = false

    private var filteredUntestedCards: [PPSRCard] {
        let cards = vm.untestedCards
        if binFilter.isEmpty { return cards }
        return cards.filter { $0.binPrefix.hasPrefix(binFilter) }
    }

    private var availableQueuedBINs: [String] {
        Set(vm.untestedCards.map(\.binPrefix)).sorted()
    }

    @State private var showStatsPanel: Bool = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                statusHeader
                if showStatsPanel {
                    lifetimeStatsCard
                }
                if vm.connectionStatus == .error || vm.diagnosticReport != nil {
                    connectionDiagnosticsCard
                }
                if vm.isRunning {
                    testingBanner
                    queueControls
                }
                if vm.stealthEnabled {
                    stealthBadge
                }
                testControlsCard
                statsRow
                if !vm.untestedCards.isEmpty {
                    queuedCardsSection
                }
                if !vm.testingCards.isEmpty {
                    cardSection(title: "Testing Now", cards: vm.testingCards, color: .teal, icon: "arrow.triangle.2.circlepath")
                }
                if !vm.deadCards.isEmpty {
                    deadCardsSection
                }
                if vm.cards.isEmpty {
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { withAnimation(.snappy) { showStatsPanel.toggle() } } label: {
                    Image(systemName: showStatsPanel ? "chart.bar.fill" : "chart.bar")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { withAnimation(.snappy) { showBINFilter.toggle() } } label: {
                    Image(systemName: showBINFilter ? "number.circle.fill" : "number.circle")
                }
            }
        }
        .task {
            await vm.testConnection()
        }
    }

    private var gatewayColor: Color {
        switch vm.activeGateway {
        case .ppsr: .teal
        case .bpoint: .indigo
        }
    }

    private var statusHeader: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: vm.activeGateway.icon)
                    .font(.system(size: 32))
                    .foregroundStyle(gatewayColor)
                    .symbolEffect(.pulse, isActive: vm.isRunning)

                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.activeGateway.displayName)
                        .font(.title3.bold())
                    Text(vm.activeGateway.baseURL.replacingOccurrences(of: "https://", with: ""))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                connectionBadge
            }

            gatewayPicker

            if vm.activeGateway.requiresChargeAmount {
                chargeAmountPicker
            }

            speedToggle
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private var speedToggle: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.needle.fill")
                    .font(.caption)
                    .foregroundStyle(speedToggleColor)
                Text("Automation Speed")
                    .font(.caption.bold())
                Spacer()
                if vm.speedMultiplier.blocksImages {
                    Text("No images")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 6) {
                ForEach(PPSRAutomationViewModel.SpeedMultiplier.allCases) { speed in
                    Button {
                        withAnimation(.snappy) { vm.speedMultiplier = speed }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: speed.icon)
                                .font(.system(size: 12))
                            Text(speed.rawValue)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(vm.speedMultiplier == speed ? speedColor(for: speed) : Color(.tertiarySystemGroupedBackground))
                        .foregroundStyle(vm.speedMultiplier == speed ? .white : .primary)
                        .clipShape(.rect(cornerRadius: 8))
                    }
                    .disabled(vm.isRunning)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: vm.speedMultiplier.rawValue)
    }

    private var speedToggleColor: Color {
        speedColor(for: vm.speedMultiplier)
    }

    private func speedColor(for speed: PPSRAutomationViewModel.SpeedMultiplier) -> Color {
        switch speed {
        case .half: .blue
        case .normal: .green
        case .fast: .yellow
        case .turbo: .orange
        case .max: .red
        }
    }

    private var gatewayPicker: some View {
        HStack(spacing: 8) {
            ForEach(TestGateway.allCases) { gw in
                Button {
                    withAnimation(.snappy) { vm.activeGateway = gw }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: gw.icon)
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(gw.rawValue)
                                .font(.caption.bold())
                            Text(gw.subtitle)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(vm.activeGateway == gw ? .white.opacity(0.7) : .secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 8)
                    .background(vm.activeGateway == gw ? gatewayButtonColor(gw) : Color(.tertiarySystemGroupedBackground))
                    .foregroundStyle(vm.activeGateway == gw ? .white : .primary)
                    .clipShape(.rect(cornerRadius: 10))
                }
                .disabled(vm.isRunning)
            }
        }
        .sensoryFeedback(.selection, trigger: vm.activeGateway.rawValue)
    }

    private func gatewayButtonColor(_ gw: TestGateway) -> Color {
        switch gw {
        case .ppsr: .teal
        case .bpoint: .indigo
        }
    }

    private var chargeAmountPicker: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.indigo)
                Text("Charge Amount")
                    .font(.caption.bold())
                Spacer()
                Text("±$10 variance")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(ChargeAmountTier.allCases) { tier in
                    Button {
                        withAnimation(.snappy) { vm.chargeAmountTier = tier }
                    } label: {
                        VStack(spacing: 3) {
                            Text(tier.rawValue)
                                .font(.system(.subheadline, design: .monospaced, weight: .bold))
                            Text(tier.displayRange)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(vm.chargeAmountTier == tier ? .white.opacity(0.7) : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(vm.chargeAmountTier == tier ? Color.indigo : Color(.tertiarySystemGroupedBackground))
                        .foregroundStyle(vm.chargeAmountTier == tier ? .white : .primary)
                        .clipShape(.rect(cornerRadius: 10))
                    }
                    .disabled(vm.isRunning)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: vm.chargeAmountTier.rawValue)
    }

    private var connectionBadge: some View {
        Button {
            Task { await vm.testConnection() }
        } label: {
            HStack(spacing: 4) {
                if vm.connectionStatus == .connecting || vm.isDiagnosticRunning {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 7, height: 7)
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

    private var stealthBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash.fill")
                .font(.caption)
                .foregroundStyle(.purple)
            Text("Ultra Stealth Mode")
                .font(.caption.bold())
                .foregroundStyle(.purple)
            Spacer()
            Text("Rotating UA + Fingerprints")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.purple.opacity(0.08))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var testingBanner: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(.teal)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Testing in Progress")
                            .font(.subheadline.bold())
                            .foregroundStyle(.teal)
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
                    Text("\(vm.activeChecks.count) active · \(vm.untestedCards.count) queued · \(vm.testingCards.count) testing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if vm.batchTotalCount > 0 {
                VStack(spacing: 4) {
                    ProgressView(value: vm.batchProgress)
                        .tint(.teal)
                    HStack {
                        Text("\(vm.batchCompletedCount)/\(vm.batchTotalCount) completed")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(vm.batchProgress * 100))%")
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(.teal)
                            .contentTransition(.numericText())
                    }
                }
            }
        }
        .padding(14)
        .background(Color.teal.opacity(0.08))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var queueControls: some View {
        HStack(spacing: 10) {
            if vm.isPaused {
                Button {
                    vm.resumeQueue()
                } label: {
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
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.15))
                    .foregroundStyle(.green)
                    .clipShape(.rect(cornerRadius: 12))
                }
            } else {
                Button {
                    vm.pauseQueue()
                } label: {
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

            Button {
                vm.stopQueue()
            } label: {
                VStack(spacing: 4) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.subheadline.bold())
                    Text("Finish current batch")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.red.opacity(0.15))
                .foregroundStyle(.red)
                .clipShape(.rect(cornerRadius: 12))
            }
            .disabled(vm.isStopping)
            .sensoryFeedback(.warning, trigger: vm.isStopping)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            MiniStat(value: "\(vm.workingCards.count)", label: "Working", color: .green, icon: "checkmark.circle.fill")
            MiniStat(value: "\(vm.untestedCards.count)", label: "Queued", color: .secondary, icon: "clock")
            MiniStat(value: "\(vm.deadCards.count)", label: "Dead", color: .red, icon: "xmark.circle.fill")
            MiniStat(value: "\(vm.cards.count)", label: "Total", color: .blue, icon: "creditcard.fill")
        }
    }

    private var queuedCardsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "clock.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Queued \u{2014} Untested")
                    .font(.headline)
                Spacer()
                Text("\(filteredUntestedCards.count)")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
                    .foregroundStyle(.secondary)
            }

            if showBINFilter {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "number").foregroundStyle(.teal)
                        TextField("Filter by BIN", text: $binFilter)
                            .font(.system(.body, design: .monospaced))
                            .keyboardType(.numberPad)
                        if !binFilter.isEmpty {
                            Button { withAnimation(.snappy) { binFilter = "" } } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 10))

                    if !availableQueuedBINs.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                FilterChipSmall(title: "All", isSelected: binFilter.isEmpty) {
                                    withAnimation(.snappy) { binFilter = "" }
                                }
                                ForEach(availableQueuedBINs, id: \.self) { bin in
                                    FilterChipSmall(title: bin, isSelected: binFilter == bin) {
                                        withAnimation(.snappy) { binFilter = bin }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            ForEach(Array(filteredUntestedCards.prefix(50))) { card in
                NavigationLink(value: card.id) {
                    CardRow(card: card, accentColor: .secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func cardSection(title: String, cards: [PPSRCard], color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(cards.count)")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.12))
                    .clipShape(Capsule())
                    .foregroundStyle(color)
            }

            ForEach(cards) { card in
                NavigationLink(value: card.id) {
                    CardRow(card: card, accentColor: color)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var deadCardsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "trash.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                Text("Dead Cards")
                    .font(.headline)
                Spacer()
                Text("\(vm.deadCards.count)")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.12))
                    .clipShape(Capsule())
                    .foregroundStyle(.red)

                Button {
                    showPurgeDeadConfirm = true
                } label: {
                    Text("Purge All")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
                .alert("Purge Dead Cards", isPresented: $showPurgeDeadConfirm) {
                    Button("Purge \(vm.deadCards.count)", role: .destructive) { vm.purgeDeadCards() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will permanently remove \(vm.deadCards.count) dead card(s). This cannot be undone.")
                }
            }

            ForEach(vm.deadCards) { card in
                NavigationLink(value: card.id) {
                    CardRow(card: card, accentColor: .red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var connectionDiagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: vm.connectionStatus == .error ? "exclamationmark.triangle.fill" : "stethoscope")
                    .font(.title3)
                    .foregroundStyle(vm.connectionStatus == .error ? .red : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.connectionStatus == .error ? "Connection Issue Detected" : "Connection Diagnostics")
                        .font(.subheadline.bold())
                    if let health = vm.lastHealthCheck {
                        Text(health.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if vm.connectionStatus == .error {
                        Text(connectionGuidance)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                if vm.isDiagnosticRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let report = vm.diagnosticReport {
                VStack(spacing: 6) {
                    ForEach(report.steps) { step in
                        HStack(spacing: 8) {
                            Image(systemName: stepIcon(step.status))
                                .font(.caption)
                                .foregroundStyle(stepColor(step.status))
                                .frame(width: 16)
                            Text(step.name)
                                .font(.system(.caption, design: .monospaced, weight: .semibold))
                                .frame(width: 110, alignment: .leading)
                            Text(step.detail)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer()
                            if let ms = step.latencyMs {
                                Text("\(ms)ms")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Text(report.recommendation)
                    .font(.caption)
                    .foregroundStyle(report.overallHealthy ? .green : .orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((report.overallHealthy ? Color.green : Color.orange).opacity(0.08))
                    .clipShape(.rect(cornerRadius: 8))
            }

            HStack(spacing: 10) {
                Button {
                    Task { await vm.runFullDiagnostic() }
                } label: {
                    Label(vm.isDiagnosticRunning ? "Running..." : "Run Diagnostics", systemImage: "stethoscope")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.12))
                        .foregroundStyle(.blue)
                        .clipShape(.rect(cornerRadius: 10))
                }
                .disabled(vm.isDiagnosticRunning)

                Button {
                    Task { await vm.testConnection() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.green.opacity(0.12))
                        .foregroundStyle(.green)
                        .clipShape(.rect(cornerRadius: 10))
                }
                .disabled(vm.connectionStatus == .connecting)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private var connectionGuidance: String {
        if let report = vm.diagnosticReport {
            let failedSteps = report.steps.filter { $0.status == .failed }
            if failedSteps.contains(where: { $0.name == "System DNS" }) {
                return "DNS resolution failed — try enabling Stealth Mode or switching to a different network."
            }
            if failedSteps.contains(where: { $0.detail.contains("403") || $0.detail.contains("blocked") }) {
                return "Server may be blocking requests — enable Stealth Mode and reduce concurrency."
            }
            if failedSteps.contains(where: { $0.detail.contains("timed out") }) {
                return "Connection timed out — check your internet or try a different proxy/VPN."
            }
            if failedSteps.contains(where: { $0.detail.contains("CAPTCHA") }) {
                return "CAPTCHA detected — enable Stealth Mode and set concurrency to 1."
            }
        }
        if vm.consecutiveConnectionFailures >= 3 {
            return "Multiple failures detected — try switching networks or checking proxy settings."
        }
        return "Run diagnostics to identify the issue."
    }

    private func stepIcon(_ status: DiagnosticStep.StepStatus) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .running: "arrow.triangle.2.circlepath"
        case .pending: "circle"
        }
    }

    private func stepColor(_ status: DiagnosticStep.StepStatus) -> Color {
        switch status {
        case .passed: .green
        case .failed: .red
        case .warning: .orange
        case .running: .blue
        case .pending: .secondary
        }
    }

    private var testControlsCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.subheadline)
                    .foregroundStyle(.teal)
                Text("Sessions")
                    .font(.subheadline.bold())
                Spacer()
                Picker("", selection: $vm.maxConcurrency) {
                    ForEach(1...8, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .pickerStyle(.menu)
                .tint(.teal)
            }

            HStack(spacing: 12) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.subheadline)
                    .foregroundStyle(.teal)
                Text("Test Order")
                    .font(.subheadline.bold())
                Spacer()
                Menu {
                    ForEach(PPSRAutomationViewModel.CardSortOption.allCases) { option in
                        Button {
                            withAnimation(.snappy) {
                                if vm.cardSortOption == option { vm.cardSortAscending.toggle() }
                                else { vm.cardSortOption = option; vm.cardSortAscending = false }
                            }
                        } label: {
                            HStack {
                                Text(option.rawValue)
                                if vm.cardSortOption == option {
                                    Image(systemName: vm.cardSortAscending ? "chevron.up" : "chevron.down")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(vm.cardSortOption.rawValue)
                            .font(.subheadline.weight(.medium))
                        Image(systemName: vm.cardSortAscending ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.teal)
                }
            }

            if !vm.untestedCards.isEmpty && !vm.isRunning {
                Button {
                    vm.testAllUntested()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("Test All Untested (\(vm.untestedCards.count))")
                            .fontWeight(.semibold)
                        if vm.activeGateway == .bpoint {
                            Text("via BPoint")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(gatewayColor)
                    .foregroundStyle(.white)
                    .clipShape(.rect(cornerRadius: 12))
                }
                .sensoryFeedback(.impact(weight: .heavy), trigger: vm.isRunning)
            }
        }
        .sensoryFeedback(.success, trigger: vm.workingCards.count)
        .sensoryFeedback(.error, trigger: vm.deadCards.count)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private var lifetimeStatsCard: some View {
        let stats = vm.statsService
        return VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.subheadline)
                    .foregroundStyle(.teal)
                Text("Lifetime Statistics")
                    .font(.headline)
                Spacer()
                Text("\(stats.totalBatches) batches")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                LifetimeStatPill(value: "\(stats.lifetimeTested)", label: "Tested", color: .blue)
                LifetimeStatPill(value: "\(stats.lifetimeWorking)", label: "Working", color: .green)
                LifetimeStatPill(value: "\(stats.lifetimeDead)", label: "Dead", color: .red)
            }

            HStack(spacing: 8) {
                LifetimeStatPill(value: String(format: "%.0f%%", stats.lifetimeSuccessRate * 100), label: "Success Rate", color: stats.lifetimeSuccessRate >= 0.5 ? .green : .orange)
                LifetimeStatPill(value: String(format: "%.1fs", stats.averageTestDuration), label: "Avg Duration", color: .purple)
                LifetimeStatPill(value: "\(stats.testsToday)", label: "Today", color: .teal)
            }

            if !stats.last7DaysCounts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last 7 Days")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(stats.last7DaysCounts, id: \.day) { item in
                            VStack(spacing: 4) {
                                let maxCount = max(stats.last7DaysCounts.map(\.count).max() ?? 1, 1)
                                let barHeight = max(4, CGFloat(item.count) / CGFloat(maxCount) * 40)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(item.count > 0 ? Color.teal : Color(.tertiarySystemFill))
                                    .frame(height: barHeight)
                                Text(item.day)
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 56)
                }
            }

            HStack(spacing: 6) {
                Text(String(format: "%.1f cards/day avg", stats.averageTestsPerDay))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(stats.lifetimeRequeued) requeued lifetime")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "creditcard.trianglebadge.exclamationmark")
                .font(.system(size: 52))
                .foregroundStyle(.teal.opacity(0.5))
                .symbolEffect(.pulse.byLayer, options: .repeating)
            Text("No Cards Added")
                .font(.title3.bold())
            Text("Go to Cards tab to import.\nSupports many formats automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

struct LifetimeStatPill: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(.subheadline, design: .monospaced, weight: .bold))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.08))
        .clipShape(.rect(cornerRadius: 8))
    }
}

struct MiniStat: View {
    let value: String
    let label: String
    let color: Color
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text(value)
                .font(.system(.title3, design: .monospaced, weight: .bold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }
}

struct CardRow: View {
    let card: PPSRCard
    let accentColor: Color

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(brandColor.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: card.brand.iconName)
                    .font(.title3)
                    .foregroundStyle(brandColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(card.brand.rawValue)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Text(card.number)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(card.formattedExpiry)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if card.totalTests > 0 {
                        Text("\(card.successCount)/\(card.totalTests) passed")
                            .font(.caption2)
                            .foregroundStyle(card.status == .working ? .green : .red)
                    }
                }
            }

            Spacer()

            if card.status == .testing {
                ProgressView()
                    .tint(.teal)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var brandColor: Color {
        switch card.brand {
        case .visa: .blue
        case .mastercard: .orange
        case .amex: .green
        case .jcb: .red
        case .discover: .purple
        case .dinersClub: .indigo
        case .unionPay: .teal
        case .unknown: .secondary
        }
    }
}
