import SwiftUI
import UIKit

struct LoginSessionMonitorView: View {
    let vm: PPSRAutomationViewModel
    @State private var selectedCheck: PPSRCheck?
    @State private var filterStatus: FilterOption = .all
    @State private var viewMode: ViewMode = .list

    nonisolated enum FilterOption: String, CaseIterable, Identifiable, Sendable {
        case all = "All"
        case active = "Active"
        case completed = "Passed"
        case failed = "Failed"
        var id: String { rawValue }
    }

    private var filteredChecks: [PPSRCheck] {
        switch filterStatus {
        case .all: vm.checks
        case .active: vm.checks.filter { !$0.status.isTerminal }
        case .completed: vm.completedChecks
        case .failed: vm.failedChecks
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            if filteredChecks.isEmpty {
                ContentUnavailableView("No Sessions", systemImage: "rectangle.stack", description: Text("Test cards from the Cards tab to see sessions here."))
            } else if viewMode == .tile {
                sessionTileGrid
            } else {
                sessionListView
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Sessions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ViewModeToggle(mode: $viewMode, accentColor: .teal)
            }
        }
        .sheet(item: $selectedCheck) { check in
            SessionDetailSheet(check: check)
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FilterOption.allCases) { option in
                    FilterChip(title: option.rawValue, count: countFor(option), isSelected: filterStatus == option) {
                        withAnimation(.snappy) { filterStatus = option }
                    }
                }
            }
            .padding(.horizontal).padding(.vertical, 10)
        }
    }

    private func countFor(_ option: FilterOption) -> Int {
        switch option {
        case .all: vm.checks.count
        case .active: vm.activeChecks.count
        case .completed: vm.completedChecks.count
        case .failed: vm.failedChecks.count
        }
    }

    private var sessionListView: some View {
        List(filteredChecks) { check in
            Button { selectedCheck = check } label: { SessionRowView(check: check) }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
        }
        .listStyle(.insetGrouped)
    }

    private var sessionTileGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(filteredChecks) { check in
                    Button { selectedCheck = check } label: {
                        ScreenshotTileView(
                            screenshot: check.responseSnapshot,
                            title: "\(check.card.brand.rawValue) \(check.card.number.suffix(4))",
                            subtitle: "S\(check.sessionIndex) \u{00b7} \(check.formattedDuration)",
                            statusColor: checkStatusColor(check.status),
                            statusText: check.status.rawValue,
                            badge: !check.screenshotIds.isEmpty ? "\u{1f4f7}" : nil
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }

    private func checkStatusColor(_ status: PPSRCheckStatus) -> Color {
        switch status {
        case .completed: .green
        case .failed: .red
        case .queued: .secondary
        default: .teal
        }
    }
}

struct FilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                if count > 0 {
                    Text("\(count)").font(.system(.caption2, design: .monospaced, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(isSelected ? Color.white.opacity(0.25) : Color(.tertiarySystemFill))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(isSelected ? Color.teal : Color(.tertiarySystemFill))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SessionRowView: View {
    let check: PPSRCheck

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if let snapshot = check.responseSnapshot {
                    Color.clear.frame(width: 48, height: 48)
                        .overlay { Image(uiImage: snapshot).resizable().aspectRatio(contentMode: .fill).allowsHitTesting(false) }
                        .clipShape(.rect(cornerRadius: 6))
                } else {
                    Image(systemName: check.status.icon)
                        .foregroundStyle(statusColor)
                        .symbolEffect(.pulse, isActive: !check.status.isTerminal)
                        .frame(width: 48, height: 48)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(check.card.brand.rawValue).font(.subheadline.bold()).foregroundStyle(.primary)
                        Text(check.card.number).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let snippet = check.responseSnippet {
                        Text(snippet.prefix(60))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary).lineLimit(1)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("S\(check.sessionIndex)")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(.rect(cornerRadius: 4)).foregroundStyle(.primary)
                    if !check.screenshotIds.isEmpty {
                        Image(systemName: "camera.fill")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            if !check.status.isTerminal {
                ProgressView(value: check.status.progress).tint(.teal)
            }

            HStack {
                Text(check.status.rawValue).font(.caption).foregroundStyle(statusColor)
                Spacer()
                Label(check.formattedDuration, systemImage: "timer")
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch check.status {
        case .completed: .green; case .failed: .red; case .queued: .secondary; default: .teal
        }
    }
}

struct SessionDetailSheet: View {
    let check: PPSRCheck
    @State private var showFullScreenshot: Bool = false

    var body: some View {
        NavigationStack {
            List {
                if let snapshot = check.responseSnapshot {
                    Section("Screenshot") {
                        Button { showFullScreenshot = true } label: {
                            Image(uiImage: snapshot)
                                .resizable().aspectRatio(contentMode: .fit)
                                .clipShape(.rect(cornerRadius: 8))
                                .frame(maxHeight: 200)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }

                Section("Details") {
                    LabeledContent("Card") {
                        HStack(spacing: 4) {
                            Image(systemName: check.card.brand.iconName).foregroundStyle(.secondary)
                            Text("\(check.card.brand.rawValue) \(check.card.number)").font(.system(.caption, design: .monospaced))
                        }
                    }
                    LabeledContent("Status") {
                        HStack(spacing: 4) {
                            Image(systemName: check.status.icon)
                            Text(check.status.rawValue)
                        }
                        .foregroundStyle(check.status == .completed ? .green : check.status == .failed ? .red : .teal)
                    }
                    LabeledContent("Session", value: "S\(check.sessionIndex)")
                    LabeledContent("Duration", value: check.formattedDuration)
                }

                if let error = check.errorMessage {
                    Section("Error") {
                        Text(error).font(.system(.body, design: .monospaced)).foregroundStyle(.red)
                    }
                }

                if let snippet = check.responseSnippet {
                    Section("Response Preview") {
                        Text(snippet)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(8)
                    }
                }

                Section("Execution Log") {
                    if check.logs.isEmpty {
                        Text("No log entries").foregroundStyle(.secondary)
                    } else {
                        ForEach(check.logs) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.formattedTime).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 80, alignment: .leading)
                                Text(entry.level.rawValue).font(.system(.caption2, design: .monospaced, weight: .bold))
                                    .foregroundStyle(logColor(entry.level)).frame(width: 36)
                                Text(entry.message).font(.system(.caption, design: .monospaced)).foregroundStyle(.primary)
                            }
                            .listRowSeparator(.hidden)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Session Detail")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showFullScreenshot) {
                if let snapshot = check.responseSnapshot {
                    PPSRFullScreenshotView(image: snapshot)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    private func logColor(_ level: PPSRLogEntry.Level) -> Color {
        switch level { case .info: .blue; case .success: .green; case .warning: .orange; case .error: .red }
    }
}

struct PPSRFullScreenshotView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
            .background(.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}
