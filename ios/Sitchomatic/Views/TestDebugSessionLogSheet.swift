import SwiftUI

struct TestDebugSessionLogSheet: View {
    let session: TestDebugSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sessionHeader
                    settingsCard
                    logEntries
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Session #\(session.index)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private var sessionHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: session.status.icon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(session.status.rawValue)
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundStyle(statusColor)

                Text(session.formattedDuration)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let img = session.finalScreenshot {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 48)
                    .clipShape(.rect(cornerRadius: 8))
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DIFFERENTIATOR")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(session.differentiator)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)

            if let err = session.errorMessage {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private var logEntries: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("LOG TRAIL")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(session.logs.count) entries")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if session.logs.isEmpty {
                Text("No log entries yet")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(session.logs) { entry in
                    logRow(entry)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private func logRow(_ entry: PPSRLogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.formattedTime)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 65, alignment: .leading)

            Circle()
                .fill(logLevelColor(entry.level))
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            Text(entry.message)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(logLevelColor(entry.level))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .queued: .secondary
        case .running: .blue
        case .success: .green
        case .failed, .connectionFailure: .red
        case .unsure: .yellow
        case .timeout: .orange
        }
    }

    private func logLevelColor(_ level: PPSRLogEntry.Level) -> Color {
        switch level {
        case .info: .primary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}
