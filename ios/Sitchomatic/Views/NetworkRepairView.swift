import SwiftUI

struct NetworkRepairView: View {
    @State private var showConfirmation: Bool = false

    var body: some View {
        NetworkRepairContentView(showConfirmation: $showConfirmation)
            .listStyle(.insetGrouped)
            .navigationTitle("Network Repair")
            .confirmationDialog(
                "Repair Network?",
                isPresented: $showConfirmation,
                titleVisibility: .visible
            ) {
                Button("Repair Now", role: .destructive) {
                    Task { await NetworkRepairService.shared.repairNetwork() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will stop all active batches, tear down every network connection (proxy, VPN, DNS, sessions), then rebuild and reconnect everything from scratch.")
            }
    }
}

private struct NetworkRepairContentView: View {
    @Binding var showConfirmation: Bool

    private var isRepairing: Bool { NetworkRepairService.shared.isRepairing }
    private var phase: NetworkRepairService.RepairPhase { NetworkRepairService.shared.repairPhase }
    private var lastResult: NetworkRepairService.RepairResult? { NetworkRepairService.shared.lastRepairResult }
    private var lastDate: Date? { NetworkRepairService.shared.lastRepairDate }

    var body: some View {
        List {
            statusSection

            if isRepairing {
                liveProgressSection
            }

            if let result = lastResult {
                resultSection(result)
            }

            logSection

            actionSection
        }
    }

    private var statusSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: statusIcon)
                        .font(.title3.bold())
                        .foregroundStyle(statusColor)
                        .symbolEffect(.pulse, isActive: isRepairing)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if isRepairing {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(phase.rawValue)
                        .font(.system(.subheadline, design: .monospaced, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Label("Status", systemImage: "waveform.path.ecg")
        }
    }

    private var liveProgressSection: some View {
        Section {
            RepairLogListView()
        } header: {
            Label("Live Progress", systemImage: "bolt.horizontal.fill")
        }
    }

    private func resultSection(_ result: NetworkRepairService.RepairResult) -> some View {
        Section {
            LabeledContent("Duration") {
                Text("\(result.totalDurationMs)ms")
                    .font(.system(.subheadline, design: .monospaced, weight: .bold))
                    .foregroundStyle(result.overallSuccess ? .green : .red)
            }
            LabeledContent("Phases Completed") {
                Text("\(result.phasesCompleted)/11")
                    .font(.system(.subheadline, design: .monospaced))
            }
            LabeledContent("DNS Healthy") {
                Text("\(result.dnsHealthy)")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(result.dnsHealthy > 0 ? .green : .red)
            }
            LabeledContent("DNS Failed") {
                Text("\(result.dnsFailed)")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(result.dnsFailed > 0 ? .orange : .green)
            }
            if !result.networkHealthSummary.isEmpty {
                LabeledContent("Network") {
                    Text(result.networkHealthSummary)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            if let failed = result.phaseFailed {
                LabeledContent("Failed At") {
                    Text(failed.rawValue)
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Label(result.overallSuccess ? "Last Repair — Success" : "Last Repair — Failed", systemImage: result.overallSuccess ? "checkmark.seal.fill" : "xmark.seal.fill")
        }
    }

    private var logSection: some View {
        Section {
            RepairLogDetailView()
        } header: {
            Label("Repair Log", systemImage: "doc.text.fill")
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                showConfirmation = true
            } label: {
                HStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.body.bold())
                        Text("Repair Network")
                            .font(.headline)
                    }
                    .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(
                isRepairing ? Color.gray : Color.orange
            )
            .disabled(isRepairing)
        } footer: {
            Text("Tears down all connections (proxy, VPN, DNS, sessions, WebViews), resets circuit breakers and throttling, then rebuilds everything. Active batches will be stopped.")
        }
    }

    private var statusColor: Color {
        if isRepairing { return .orange }
        if let result = lastResult {
            return result.overallSuccess ? .green : .red
        }
        return .blue
    }

    private var statusIcon: String {
        if isRepairing { return "arrow.triangle.2.circlepath" }
        if let result = lastResult {
            return result.overallSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        }
        return "network"
    }

    private var statusTitle: String {
        if isRepairing { return "Repairing..." }
        if let result = lastResult {
            return result.overallSuccess ? "Network Healthy" : "Last Repair Failed"
        }
        return "Network Ready"
    }

    private var statusSubtitle: String {
        if isRepairing { return phase.rawValue }
        if let date = lastDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Last repair: \(formatter.localizedString(for: date, relativeTo: Date()))"
        }
        return "No repairs performed this session"
    }
}

private struct RepairLogListView: View {
    var body: some View {
        let entries = Array(NetworkRepairService.shared.repairLog)
        if entries.isEmpty {
            Text("Waiting for repair phases...")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(entry.success ? .green : .red)
                        .font(.caption)
                    Text(entry.message)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }
        }
    }
}

private struct RepairLogDetailView: View {
    var body: some View {
        let entries = Array(NetworkRepairService.shared.repairLog)
        if entries.isEmpty {
            Text("No repair log entries")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 8) {
                    Image(systemName: entry.phase.icon)
                        .font(.caption2)
                        .foregroundStyle(entry.success ? .green : .red)
                        .frame(width: 18)
                    Text(entry.message)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(entry.success ? Color.primary : Color.red)
                }
            }
        }
    }
}
