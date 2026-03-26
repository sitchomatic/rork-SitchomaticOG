import SwiftUI

struct TestDebugCompareView: View {
    let runs: [TestDebugRunSummary]
    @State private var runAIndex: Int = 0
    @State private var runBIndex: Int = 1
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if runs.count < 2 {
                        emptyState
                    } else {
                        pickerSection
                        comparisonCards
                        sessionBreakdown
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Compare Runs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(.secondary)
            Text("Need at least 2 completed runs to compare")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Complete more test runs and they'll appear here for side-by-side comparison.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 40)
    }

    private var pickerSection: some View {
        HStack(spacing: 12) {
            runPicker(label: "RUN A", index: $runAIndex, color: .purple)
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.secondary)
            runPicker(label: "RUN B", index: $runBIndex, color: .blue)
        }
    }

    private func runPicker(label: String, index: Binding<Int>, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(color)

            Picker(label, selection: index) {
                ForEach(0..<runs.count, id: \.self) { i in
                    Text(runLabel(runs[i])).tag(i)
                }
            }
            .pickerStyle(.menu)
            .tint(color)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(color.opacity(0.08))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func runLabel(_ run: TestDebugRunSummary) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM d HH:mm"
        return "\(df.string(from: run.date)) (\(run.sessionCount)s)"
    }

    @ViewBuilder
    private var comparisonCards: some View {
        if runAIndex < runs.count, runBIndex < runs.count {
            let runA = runs[runAIndex]
            let runB = runs[runBIndex]

            VStack(spacing: 8) {
                comparisonRow("Success Rate", valueA: "\(runA.successCount)/\(runA.sessionCount)", valueB: "\(runB.successCount)/\(runB.sessionCount)", betterA: runA.successCount > runB.successCount)
                comparisonRow("Failed", valueA: "\(runA.failedCount)", valueB: "\(runB.failedCount)", betterA: runA.failedCount < runB.failedCount)
                comparisonRow("Unsure", valueA: "\(runA.unsureCount)", valueB: "\(runB.unsureCount)", betterA: runA.unsureCount < runB.unsureCount)
                comparisonRow("Timeouts", valueA: "\(runA.timeoutCount)", valueB: "\(runB.timeoutCount)", betterA: runA.timeoutCount < runB.timeoutCount)
                comparisonRow("Mode", valueA: runA.variationMode, valueB: runB.variationMode, betterA: false)
                comparisonRow("Site", valueA: runA.site, valueB: runB.site, betterA: false)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 14))
        }
    }

    private func comparisonRow(_ label: String, valueA: String, valueB: String, betterA: Bool) -> some View {
        HStack {
            Text(valueA)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(betterA ? .green : .primary)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Text(label)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 80)
                .multilineTextAlignment(.center)

            Text(valueB)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(!betterA && valueA != valueB ? .green : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var sessionBreakdown: some View {
        if runAIndex < runs.count, runBIndex < runs.count {
            let runA = runs[runAIndex]
            let runB = runs[runBIndex]

            VStack(alignment: .leading, spacing: 10) {
                Text("SESSION BREAKDOWN")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 4) {
                        Text("RUN A")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .foregroundStyle(.purple)
                        ForEach(runA.sessionSummaries) { s in
                            sessionSummaryRow(s)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Divider()

                    VStack(spacing: 4) {
                        Text("RUN B")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .foregroundStyle(.blue)
                        ForEach(runB.sessionSummaries) { s in
                            sessionSummaryRow(s)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 14))
        }
    }

    private func sessionSummaryRow(_ s: TestDebugSessionSummary) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(summaryStatusColor(s.status))
                .frame(width: 6, height: 6)
            Text("#\(s.index)")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            if let d = s.duration {
                Text(String(format: "%.0fs", d))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func summaryStatusColor(_ status: String) -> Color {
        switch status {
        case "Success": .green
        case "Failed", "Connection Failure": .red
        case "Unsure": .yellow
        case "Timeout": .orange
        default: .secondary
        }
    }
}
