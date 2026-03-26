import SwiftUI
import UIKit

struct CrashReportPopupView: View {
    let report: CrashReport
    let onDismiss: () -> Void
    let onSend: (String) -> Void

    @State private var showFullReport: Bool = false
    @State private var copied: Bool = false
    @State private var sending: Bool = false

    private var crashDate: Date {
        Date(timeIntervalSince1970: report.timestamp)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            ScrollView {
                VStack(spacing: 16) {
                    crashSummaryCard
                    diagnosticsCard
                    if !report.screenshotKeys.isEmpty {
                        screenshotInfoCard
                    }
                    actionsSection
                }
                .padding(20)
            }
        }
        .background(Color(.systemGroupedBackground))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(.red.opacity(0.15))
                    .frame(width: 56, height: 56)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating)
            }
            .padding(.top, 20)

            Text("Crash Detected")
                .font(.title3.bold())

            Text("The app crashed during your last session. Send this report to help diagnose the issue.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.bottom, 12)
    }

    private var crashSummaryCard: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Crash Summary", systemImage: "ladybug.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.red)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.red.opacity(0.08))

            VStack(spacing: 8) {
                summaryRow(label: "Signal", value: report.signal, color: .red)
                summaryRow(label: "Memory", value: "\(report.memoryMB)MB", color: report.memoryMB > 3000 ? .red : .orange)
                summaryRow(label: "Time", value: crashDate.formatted(.dateTime.month().day().hour().minute().second()), color: .secondary)
                summaryRow(label: "iOS", value: report.iosVersion, color: .secondary)
                summaryRow(label: "Device", value: report.deviceModel, color: .secondary)
                summaryRow(label: "App Version", value: report.appVersion, color: .secondary)
            }
            .padding(16)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var diagnosticsCard: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Crash Log", systemImage: "doc.text.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
                Spacer()
                Button {
                    showFullReport.toggle()
                } label: {
                    Text(showFullReport ? "Collapse" : "Expand")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.08))

            Text(showFullReport ? report.crashLog : String(report.crashLog.prefix(300)))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .lineLimit(showFullReport ? nil : 8)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var screenshotInfoCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.purple.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: "camera.fill")
                    .font(.caption)
                    .foregroundStyle(.purple)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(report.screenshotKeys.count) Screenshots Preserved")
                    .font(.subheadline.bold())
                Text("Debug screenshots from before the crash survived to disk")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var actionsSection: some View {
        VStack(spacing: 10) {
            Button {
                sending = true
                let reportText = CrashProtectionService.shared.generateCrashReportText()
                onSend(reportText)
                sending = false
            } label: {
                HStack {
                    Spacer()
                    if sending {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text("Send Crash Report")
                        .font(.headline)
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.vertical, 14)
                .background(Color.red.gradient, in: .rect(cornerRadius: 14))
            }

            Button {
                let reportText = CrashProtectionService.shared.generateCrashReportText()
                UIPasteboard.general.string = reportText
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                HStack {
                    Spacer()
                    Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
                    Text(copied ? "Copied!" : "Copy Report to Clipboard")
                        .font(.subheadline.bold())
                    Spacer()
                }
                .foregroundStyle(.orange)
                .padding(.vertical, 12)
                .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 12))
            }

            Button {
                onDismiss()
            } label: {
                Text("Dismiss")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    private func summaryRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(color)
        }
    }
}
