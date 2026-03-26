import SwiftUI

struct NoticesView: View {
    let noticesService = NoticesService.shared
    @State private var filterSource: FailureNotice.Source?
    @State private var clearTrigger: Bool = false

    var filteredNotices: [FailureNotice] {
        if let source = filterSource {
            return noticesService.noticesForSource(source)
        }
        return noticesService.notices
    }

    var body: some View {
        List {
            if filteredNotices.isEmpty {
                EmptyStateView(
                    icon: "checkmark.seal.fill",
                    title: "No Failure Notices",
                    subtitle: "Unusual failures and auto-retries will appear here instead of interrupting your workflow.",
                    accentColor: .green
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    Picker("Filter", selection: $filterSource) {
                        Text("All").tag(FailureNotice.Source?.none)
                        Text("PPSR").tag(FailureNotice.Source?.some(.ppsr))
                        Text("Login").tag(FailureNotice.Source?.some(.login))
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    ForEach(filteredNotices) { notice in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(spacing: 4) {
                                Image(systemName: notice.autoRetried ? "arrow.triangle.2.circlepath.circle.fill" : "exclamationmark.triangle.fill")
                                    .font(.body)
                                    .foregroundStyle(notice.autoRetried ? .mint : .orange)
                                Text(notice.source.rawValue)
                                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                                    .foregroundStyle(notice.source == .ppsr ? .teal : .green)
                            }
                            .frame(width: 44)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(notice.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary)
                                HStack(spacing: 8) {
                                    Text(notice.formattedTime)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                    if notice.autoRetried {
                                        Text("AUTO-RETRIED")
                                            .font(.system(.caption2, design: .monospaced, weight: .heavy))
                                            .foregroundStyle(.mint)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.mint.opacity(0.12))
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    HStack {
                        Text("\(filteredNotices.count) Notice\(filteredNotices.count == 1 ? "" : "s")")
                        Spacer()
                    }
                }

                Section {
                    Button(role: .destructive) {
                        if let source = filterSource {
                            noticesService.clearNotices(for: source)
                        } else {
                            noticesService.clearNotices()
                        }
                        clearTrigger.toggle()
                    } label: {
                        Label("Clear \(filterSource?.rawValue ?? "All") Notices", systemImage: "trash")
                    }
                    .sensoryFeedback(.impact(weight: .medium), trigger: clearTrigger)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Notices")
        .navigationBarTitleDisplayMode(.large)
    }
}
