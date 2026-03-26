import SwiftUI

struct PPSRConsoleView: View {
    let vm: PPSRAutomationViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Circle().fill(.orange).frame(width: 10, height: 10)
                    Circle().fill(.green).frame(width: 10, height: 10)
                }
                Spacer()
                Text("\(vm.globalLogs.count) entries")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground))

            Group {
                if vm.globalLogs.isEmpty {
                    ContentUnavailableView("No Logs", systemImage: "terminal", description: Text("Console output will appear here as checks run."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(vm.globalLogs) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(entry.formattedTime).foregroundStyle(.tertiary)
                                    Text("[\(entry.level.rawValue)]").foregroundStyle(levelColor(entry.level)).frame(width: 42, alignment: .leading)
                                    Text(entry.message).foregroundStyle(.primary)
                                }
                                .font(.system(.caption, design: .monospaced))
                                .padding(.horizontal)
                                .padding(.vertical, 3)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Console")
    }

    private func levelColor(_ level: PPSRLogEntry.Level) -> Color {
        switch level {
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}
