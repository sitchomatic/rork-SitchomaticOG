import SwiftUI

struct AdversarialSimulationView: View {
    @State private var vm = AdversarialSimulationViewModel()

    var body: some View {
        List {
            controlSection
            if let suite = vm.latestSuite {
                overviewSection(suite)
                resultsSection(suite)
            }
            if !vm.autoHealingActions.isEmpty {
                healingSection
            }
            historySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Adversarial Sim")
        .onAppear { vm.load() }
        .refreshable { vm.load() }
    }

    private var controlSection: some View {
        Section {
            if vm.availableHosts.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(.secondary)
                    Text("No monitored hosts yet — run a batch first")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("Target Host", selection: $vm.selectedHost) {
                    ForEach(vm.availableHosts, id: \.self) { host in
                        Text(host).tag(host)
                    }
                }
                .onChange(of: vm.selectedHost) { _, newHost in
                    vm.selectHost(newHost)
                }
            }

            Picker("Difficulty", selection: $vm.selectedDifficulty) {
                ForEach(AdversarialDifficulty.allCases, id: \.self) { diff in
                    Text(diff.label).tag(diff)
                }
            }

            HStack {
                Text("Scenarios at this level")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(vm.scenariosForDifficulty.count)")
                    .font(.subheadline.bold())
                    .foregroundStyle(.teal)
            }

            Button {
                Task { await vm.runSimulation() }
            } label: {
                HStack {
                    if vm.isRunning {
                        ProgressView()
                            .controlSize(.small)
                        Text("Running Simulation...")
                    } else {
                        Image(systemName: "bolt.shield.fill")
                        Text("Run Adversarial Simulation")
                    }
                }
                .frame(maxWidth: .infinity)
                .font(.headline)
            }
            .disabled(vm.isRunning || vm.selectedHost.isEmpty)
            .tint(.teal)
        } header: {
            Label("Simulation Control", systemImage: "shield.checkered")
        }
    }

    private func overviewSection(_ suite: SimulationSuite) -> some View {
        Section {
            HStack(spacing: 16) {
                verdictBadge(suite.overallVerdict)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Overall Score")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Int(suite.overallScore * 100))%")
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(colorForVerdict(suite.overallVerdict))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text("\(suite.scenariosPassed)/\(suite.scenariosRun)")
                            .font(.subheadline.bold().monospacedDigit())
                    }
                    Text("\(suite.durationMs)ms")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if suite.overallVerdict == .critical || suite.overallVerdict == .failed {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(suite.overallVerdict == .critical
                         ? "Critical vulnerabilities detected — auto-healing queued"
                         : "Failed scenarios detected — review recommendations")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Label("Latest Results", systemImage: "chart.bar.doc.horizontal")
                Spacer()
                Text(suite.host)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resultsSection(_ suite: SimulationSuite) -> some View {
        Section {
            ForEach(suite.results) { result in
                DisclosureGroup {
                    resultDetail(result)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: result.verdict.icon)
                            .foregroundStyle(colorForVerdict(result.verdict))
                            .font(.body)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.scenarioName)
                                .font(.subheadline.bold())
                            HStack(spacing: 8) {
                                Text(result.difficulty.label)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(colorForDifficulty(result.difficulty).opacity(0.15))
                                    .foregroundStyle(colorForDifficulty(result.difficulty))
                                    .clipShape(.capsule)
                                Text("Evasion \(Int(result.evasionScore * 100))%")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } header: {
            Label("Scenario Results", systemImage: "list.bullet.clipboard")
        }
    }

    private func resultDetail(_ result: SimulationResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !result.detectedSignals.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Detected Signals")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 4) {
                        ForEach(result.detectedSignals, id: \.self) { signal in
                            Text(signal)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.red.opacity(0.1))
                                .foregroundStyle(.red)
                                .clipShape(.capsule)
                        }
                    }
                }
            }

            if !result.recommendations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recommendations")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(result.recommendations) { rec in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(colorForPriority(rec.priority))
                                .frame(width: 6, height: 6)
                                .padding(.top, 5)
                            Text(rec.action)
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }

            HStack(spacing: 16) {
                statPill("Detection", "\(Int(result.detectionRate * 100))%", .red)
                statPill("Latency", "\(result.latencyMs)ms", .blue)
                statPill("Duration", "\(result.durationMs)ms", .purple)
            }
        }
        .padding(.vertical, 4)
    }

    private var healingSection: some View {
        Section {
            ForEach(vm.autoHealingActions) { action in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(.teal)
                            .font(.caption)
                        Text(action.settingKey)
                            .font(.subheadline.bold())
                        Spacer()
                        Button("Revert") {
                            vm.revertHealingAction(action)
                        }
                        .font(.caption)
                        .tint(.orange)
                    }
                    Text(action.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Label(action.oldValue, systemImage: "arrow.left")
                            .font(.caption2)
                            .foregroundStyle(.red)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Label(action.newValue, systemImage: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Label("Auto-Healing Actions", systemImage: "wand.and.stars")
        }
    }

    private var historySection: some View {
        Section {
            if vm.allSuites.isEmpty {
                Text("No simulation history yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.allSuites) { suite in
                    HStack(spacing: 12) {
                        Image(systemName: suite.overallVerdict.icon)
                            .foregroundStyle(colorForVerdict(suite.overallVerdict))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suite.host)
                                .font(.subheadline.bold())
                            Text("\(suite.difficulty.label) • \(suite.scenariosPassed)/\(suite.scenariosRun) passed • \(Int(suite.overallScore * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(suite.timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            HStack {
                Text("Total simulations run")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(vm.totalSimulations)")
                    .font(.caption.bold().monospacedDigit())
            }

            if !vm.allSuites.isEmpty {
                Button(role: .destructive) {
                    vm.resetAll()
                } label: {
                    Label("Reset All Simulation Data", systemImage: "trash")
                        .font(.subheadline)
                }
            }
        } header: {
            Label("History", systemImage: "clock.arrow.circlepath")
        }
    }

    private func verdictBadge(_ verdict: SimulationVerdict) -> some View {
        ZStack {
            Circle()
                .fill(colorForVerdict(verdict).opacity(0.12))
                .frame(width: 48, height: 48)
            Image(systemName: verdict.icon)
                .font(.title3)
                .foregroundStyle(colorForVerdict(verdict))
        }
    }

    private func statPill(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func colorForVerdict(_ verdict: SimulationVerdict) -> Color {
        switch verdict {
        case .passed: return .green
        case .marginal: return .yellow
        case .failed: return .orange
        case .critical: return .red
        }
    }

    private func colorForDifficulty(_ diff: AdversarialDifficulty) -> Color {
        switch diff {
        case .basic: return .green
        case .intermediate: return .blue
        case .advanced: return .orange
        case .expert: return .red
        }
    }

    private func colorForPriority(_ priority: SimulationRecommendation.RecommendationPriority) -> Color {
        switch priority {
        case .low: return .gray
        case .medium: return .blue
        case .high: return .orange
        case .critical: return .red
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            guard index < subviews.count else { break }
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}
