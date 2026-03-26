import SwiftUI

struct AICustomToolsDashboardView: View {
    @State private var stats: CustomToolStats?
    @State private var runHealthAudit: [RunHealthAuditEntry] = []
    @State private var checkpointAudit: [CheckpointAuditEntry] = []
    @State private var batchAudit: [BatchInsightAuditEntry] = []
    @State private var showResetConfirmation: Bool = false
    @State private var selectedTool: CustomToolType?

    private let coordinator = AICustomToolsCoordinator.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                overviewCard
                toolCardsSection
                if let selectedTool {
                    toolDetailSection(selectedTool)
                }
                recentExecutionsSection
                settingsSection
                resetSection
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
        .navigationTitle("Custom AI Tools")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { refresh() }
        .refreshable { refresh() }
        .alert("Reset All Custom Tools?", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                coordinator.resetAll()
                refresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears all audit logs, learned data, and statistics across all 3 custom tools.")
        }
    }

    private func refresh() {
        stats = coordinator.stats()
        runHealthAudit = coordinator.runHealthAnalyzer.auditLog
        checkpointAudit = coordinator.checkpointVerifier.auditLog
        batchAudit = coordinator.batchInsightTuning.auditLog
    }

    // MARK: - Overview

    private var overviewCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.indigo)
                Text("AI Custom Tools")
                    .font(.title3.bold())
                Spacer()
                if let stats {
                    statusBadge(stats.isHealthy)
                }
            }

            if let stats {
                HStack(spacing: 0) {
                    overviewStat("Executions", value: "\(stats.totalExecutions)", color: .blue)
                    Divider().frame(height: 32)
                    overviewStat("Avg Conf", value: String(format: "%.0f%%", stats.avgConfidence * 100), color: stats.avgConfidence > 0.6 ? .green : .orange)
                    Divider().frame(height: 32)
                    overviewStat("Tools Active", value: "\(stats.toolBreakdown.count)/3", color: .purple)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    private func overviewStat(_ label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func statusBadge(_ isHealthy: Bool) -> some View {
        Text(isHealthy ? "HEALTHY" : "DEGRADED")
            .font(.system(.caption2, design: .monospaced, weight: .heavy))
            .foregroundStyle(isHealthy ? .green : .orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((isHealthy ? Color.green : Color.orange).opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Tool Cards

    private var toolCardsSection: some View {
        VStack(spacing: 12) {
            ForEach(CustomToolType.allCases, id: \.rawValue) { tool in
                Button {
                    withAnimation(.spring(duration: 0.3)) {
                        selectedTool = selectedTool == tool ? nil : tool
                    }
                } label: {
                    toolCard(tool)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toolCard(_ tool: CustomToolType) -> some View {
        let count = stats?.toolBreakdown[tool.rawValue] ?? 0
        let isSelected = selectedTool == tool

        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(toolColor(tool).opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: tool.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(toolColor(tool))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(tool.rawValue)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Text(tool.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(count)")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(toolColor(tool))
                Text("calls")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(isSelected ? toolColor(tool).opacity(0.06) : Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? toolColor(tool).opacity(0.3) : .clear, lineWidth: 1.5)
        )
    }

    // MARK: - Tool Detail

    @ViewBuilder
    private func toolDetailSection(_ tool: CustomToolType) -> some View {
        switch tool {
        case .runHealthAnalyzer:
            runHealthDetailView
        case .checkpointVerification:
            checkpointDetailView
        case .batchInsightTuning:
            batchInsightDetailView
        }
    }

    private var runHealthDetailView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Run Health Analyzer", systemImage: "heart.text.clipboard")
                .font(.headline)
                .foregroundStyle(.red)

            let analyzer = coordinator.runHealthAnalyzer
            HStack(spacing: 16) {
                miniStat("Total", "\(analyzer.totalAnalyses)", .blue)
                let breakdown = analyzer.decisionBreakdown
                miniStat("Retries", "\(breakdown["retry"] ?? 0)", .orange)
                miniStat("Stops", "\(breakdown["stop"] ?? 0)", .red)
                miniStat("Waits", "\(breakdown["wait"] ?? 0)", .yellow)
            }

            if !runHealthAudit.isEmpty {
                Text("Recent Decisions")
                    .font(.subheadline.bold())
                    .padding(.top, 4)

                ForEach(Array(runHealthAudit.prefix(5).enumerated()), id: \.offset) { _, entry in
                    auditRow(
                        decision: entry.decision,
                        confidence: entry.confidence,
                        reasoning: entry.reasoning,
                        host: entry.host,
                        timestamp: entry.timestamp,
                        color: runHealthColor(entry.decision)
                    )
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    private var checkpointDetailView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Checkpoint Verification", systemImage: "checkmark.shield")
                .font(.headline)
                .foregroundStyle(.blue)

            let verifier = coordinator.checkpointVerifier
            HStack(spacing: 16) {
                miniStat("Total", "\(verifier.totalVerifications)", .blue)
                let breakdown = verifier.verdictBreakdown
                miniStat("Confirmed", "\(breakdown["confirmed"] ?? 0)", .green)
                miniStat("Mismatch", "\(breakdown["mismatch"] ?? 0)", .red)
                miniStat("Uncertain", "\(breakdown["uncertain"] ?? 0)", .orange)
            }

            let profiles = verifier.flowAccuracyProfiles
            if !profiles.isEmpty {
                Text("Flow Accuracy")
                    .font(.subheadline.bold())
                    .padding(.top, 4)

                ForEach(Array(profiles.prefix(5)), id: \.key) { flowName, profile in
                    HStack {
                        Text(flowName)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int(profile.accuracy * 100))%")
                            .font(.caption.bold())
                            .foregroundStyle(profile.accuracy > 0.7 ? .green : profile.accuracy > 0.4 ? .orange : .red)
                        Text("\(profile.totalChecks) checks")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !checkpointAudit.isEmpty {
                Text("Recent Verifications")
                    .font(.subheadline.bold())
                    .padding(.top, 4)

                ForEach(Array(checkpointAudit.prefix(5).enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(verdictColor(entry.verdict))
                            .frame(width: 8, height: 8)
                        Text(entry.flowName)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text(entry.verdict.uppercased())
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(verdictColor(entry.verdict))
                        Text("\(Int(entry.confidence * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    private var batchInsightDetailView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Batch Insight & Tuning", systemImage: "chart.bar.doc.horizontal")
                .font(.headline)
                .foregroundStyle(.purple)

            let insight = coordinator.batchInsightTuning
            HStack(spacing: 16) {
                miniStat("Batches", "\(insight.totalAnalyses)", .blue)
                miniStat("Avg SR", String(format: "%.0f%%", insight.averageSuccessRate * 100), insight.averageSuccessRate > 0.5 ? .green : .orange)
            }

            let patterns = insight.recurringPatterns.sorted { $0.value > $1.value }.prefix(5)
            if !patterns.isEmpty {
                Text("Recurring Failure Patterns")
                    .font(.subheadline.bold())
                    .padding(.top, 4)

                ForEach(Array(patterns.enumerated()), id: \.offset) { _, pattern in
                    HStack {
                        Text(pattern.key)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text("\(pattern.value)x")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                    }
                }
            }

            if !batchAudit.isEmpty {
                Text("Recent Batch Analyses")
                    .font(.subheadline.bold())
                    .padding(.top, 4)

                ForEach(Array(batchAudit.prefix(5).enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 8) {
                        Text(entry.grade)
                            .font(.system(.caption, design: .rounded, weight: .black))
                            .foregroundStyle(gradeColor(entry.grade))
                            .frame(width: 20)
                        Text(entry.batchId.suffix(8))
                            .font(.caption.monospaced())
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int(entry.successRate * 100))%")
                            .font(.caption.bold())
                            .foregroundStyle(entry.successRate > 0.7 ? .green : entry.successRate > 0.4 ? .orange : .red)
                        Text("\(entry.totalItems) items")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    // MARK: - Recent Executions

    private var recentExecutionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Recent Executions", systemImage: "clock.arrow.circlepath")
                .font(.headline)

            if let stats, !stats.recentExecutions.isEmpty {
                ForEach(Array(stats.recentExecutions.prefix(8).enumerated()), id: \.offset) { _, exec in
                    HStack(spacing: 8) {
                        Image(systemName: iconForToolType(exec.toolType))
                            .font(.caption)
                            .foregroundStyle(colorForToolType(exec.toolType))
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(exec.decision)
                                .font(.caption.bold())
                                .foregroundStyle(.primary)
                            Text(exec.reasoning)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(Int(exec.confidence * 100))%")
                                .font(.caption2.bold())
                                .foregroundStyle(exec.confidence > 0.7 ? .green : .orange)
                            Text("\(exec.durationMs)ms")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }

                        if exec.wasApproved {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                }
            } else {
                Text("No executions yet. Tools activate automatically during automation runs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Tool Settings", systemImage: "gearshape")
                .font(.headline)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Approval Gate")
                        .font(.subheadline)
                    Text("Require high confidence for state-changing actions")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { coordinator.approvalGateEnabled },
                    set: { coordinator.approvalGateEnabled = $0 }
                ))
                .labelsHidden()
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-Approve Threshold")
                        .font(.subheadline)
                    Text("Min confidence for auto-approving actions: \(Int(coordinator.autoApproveThreshold * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Stepper("", value: Binding(
                    get: { coordinator.autoApproveThreshold },
                    set: { coordinator.autoApproveThreshold = $0 }
                ), in: 0.5...1.0, step: 0.05)
                .labelsHidden()
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 16))
    }

    // MARK: - Reset

    private var resetSection: some View {
        Button(role: .destructive) {
            showResetConfirmation = true
        } label: {
            Label("Reset All Custom Tools", systemImage: "trash")
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }

    // MARK: - Helpers

    private func auditRow(decision: String, confidence: Double, reasoning: String, host: String, timestamp: Date, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(decision.uppercased())
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(color)
                    Text(host)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(reasoning)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(Int(confidence * 100))%")
                .font(.caption2.bold())
                .foregroundStyle(confidence > 0.7 ? .green : .orange)
        }
    }

    private func miniStat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func toolColor(_ tool: CustomToolType) -> Color {
        switch tool {
        case .runHealthAnalyzer: .red
        case .checkpointVerification: .blue
        case .batchInsightTuning: .purple
        }
    }

    private func runHealthColor(_ decision: String) -> Color {
        switch decision {
        case "retry": return .orange
        case "wait": return .yellow
        case "stop": return .red
        case "manualReview": return .purple
        case "rotateInfra": return .blue
        case "continueMonitoring": return .green
        default: return .secondary
        }
    }

    private func verdictColor(_ verdict: String) -> Color {
        switch verdict {
        case "confirmed": return .green
        case "mismatch": return .red
        case "uncertain": return .orange
        case "stale": return .yellow
        default: return .secondary
        }
    }

    private func gradeColor(_ grade: String) -> Color {
        switch grade {
        case "A": return .green
        case "B": return .blue
        case "C": return .orange
        case "D": return .red
        case "F": return .red
        default: return .secondary
        }
    }

    private func iconForToolType(_ type: String) -> String {
        if type.contains("Health") { return "heart.text.clipboard" }
        if type.contains("Checkpoint") { return "checkmark.shield" }
        if type.contains("Batch") { return "chart.bar.doc.horizontal" }
        return "wrench"
    }

    private func colorForToolType(_ type: String) -> Color {
        if type.contains("Health") { return .red }
        if type.contains("Checkpoint") { return .blue }
        if type.contains("Batch") { return .purple }
        return .secondary
    }
}
