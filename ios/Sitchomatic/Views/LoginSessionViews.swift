import SwiftUI
import UIKit

struct LoginSessionMonitorContentView: View {
    let vm: LoginViewModel
    @State private var selectedAttempt: LoginAttempt?
    @State private var filterStatus: FilterOption = .all
    @State private var viewMode: ViewMode = .list

    nonisolated enum FilterOption: String, CaseIterable, Identifiable, Sendable {
        case all = "All"
        case active = "Active"
        case working = "Working"
        case noAcc = "No Acc"
        case tempDisabled = "Temp Dis"
        case permDisabled = "Perm Dis"
        case unsure = "Unsure"
        var id: String { rawValue }

        var color: Color {
            switch self {
            case .all: .primary
            case .active: .blue
            case .working: .green
            case .noAcc: .red
            case .tempDisabled: .orange
            case .permDisabled: .purple
            case .unsure: .yellow
            }
        }
    }

    private var filteredAttempts: [LoginAttempt] {
        switch filterStatus {
        case .all: vm.attempts
        case .active: vm.attempts.filter { !$0.status.isTerminal }
        case .working: vm.attempts.filter { $0.status.isTerminal && $0.credential.status == .working }
        case .noAcc: vm.attempts.filter { $0.status.isTerminal && $0.credential.status == .noAcc }
        case .tempDisabled: vm.attempts.filter { $0.status.isTerminal && $0.credential.status == .tempDisabled }
        case .permDisabled: vm.attempts.filter { $0.status.isTerminal && $0.credential.status == .permDisabled }
        case .unsure: vm.attempts.filter { $0.status.isTerminal && ($0.credential.status == .unsure || $0.credential.status == .untested) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            if filteredAttempts.isEmpty {
                ContentUnavailableView("No Sessions", systemImage: "rectangle.stack", description: Text("Test credentials to see sessions here."))
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
                ViewModeToggle(mode: $viewMode, accentColor: .green)
            }
        }
        .sheet(item: $selectedAttempt) { attempt in
            LoginSessionDetailSheet(attempt: attempt)
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FilterOption.allCases) { option in
                    LoginSessionFilterChip(title: option.rawValue, count: countFor(option), isSelected: filterStatus == option, color: option.color) {
                        withAnimation(.snappy) { filterStatus = option }
                    }
                }
            }
            .padding(.horizontal).padding(.vertical, 10)
        }
    }

    private func countFor(_ option: FilterOption) -> Int {
        switch option {
        case .all: vm.attempts.count
        case .active: vm.activeAttempts.count
        case .working: vm.attempts.filter { $0.status.isTerminal && $0.credential.status == .working }.count
        case .noAcc: vm.attempts.filter { $0.status.isTerminal && $0.credential.status == .noAcc }.count
        case .tempDisabled: vm.attempts.filter { $0.status.isTerminal && $0.credential.status == .tempDisabled }.count
        case .permDisabled: vm.attempts.filter { $0.status.isTerminal && $0.credential.status == .permDisabled }.count
        case .unsure: vm.attempts.filter { $0.status.isTerminal && ($0.credential.status == .unsure || $0.credential.status == .untested) }.count
        }
    }

    private var sessionListView: some View {
        List(filteredAttempts) { attempt in
            Button { selectedAttempt = attempt } label: { LoginSessionRow(attempt: attempt) }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
        }
        .listStyle(.insetGrouped)
    }

    private var sessionTileGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(filteredAttempts) { attempt in
                    Button { selectedAttempt = attempt } label: {
                        let latestScreenshot = attempt.responseSnapshot ?? vm.screenshotsForAttempt(attempt).first?.image
                        ScreenshotTileView(
                            screenshot: latestScreenshot,
                            title: attempt.credential.username,
                            subtitle: "S\(attempt.sessionIndex) · \(attempt.formattedDuration)",
                            statusColor: attemptStatusColor(attempt),
                            statusText: attemptStatusLabel(attempt),
                            badge: attempt.hasScreenshot ? "📷" : nil
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }

    private func attemptStatusColor(_ attempt: LoginAttempt) -> Color {
        guard attempt.status.isTerminal else { return .blue }
        switch attempt.credential.status {
        case .working: return .green
        case .noAcc: return .red
        case .permDisabled: return .purple
        case .tempDisabled: return .orange
        case .unsure, .untested: return .yellow
        case .testing: return .blue
        }
    }

    private func attemptStatusLabel(_ attempt: LoginAttempt) -> String {
        guard attempt.status.isTerminal else { return attempt.status.rawValue }
        return attempt.credential.status.rawValue
    }
}

struct LoginSessionFilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    var color: Color = .green
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
            .background(isSelected ? color : Color(.tertiarySystemFill))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct LoginSessionRow: View {
    let attempt: LoginAttempt

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if let snapshot = attempt.responseSnapshot {
                    Color.clear.frame(width: 48, height: 48)
                        .overlay { Image(uiImage: snapshot).resizable().aspectRatio(contentMode: .fill).allowsHitTesting(false) }
                        .clipShape(.rect(cornerRadius: 6))
                } else {
                    Image(systemName: attempt.status.icon)
                        .foregroundStyle(statusColor)
                        .symbolEffect(.pulse, isActive: !attempt.status.isTerminal)
                        .frame(width: 48, height: 48)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(attempt.credential.username)
                        .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.primary).lineLimit(1)
                    if let snippet = attempt.responseSnippet {
                        Text(snippet.prefix(60))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary).lineLimit(1)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("S\(attempt.sessionIndex)")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(.rect(cornerRadius: 4)).foregroundStyle(.primary)
                    if attempt.hasScreenshot {
                        Image(systemName: "camera.fill")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            if !attempt.status.isTerminal {
                ProgressView(value: attempt.status.progress).tint(.green)
            }

            HStack {
                Text(displayStatus).font(.caption).foregroundStyle(statusColor)
                Spacer()
                Label(attempt.formattedDuration, systemImage: "timer")
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        guard attempt.status.isTerminal else {
            return attempt.status == .queued ? .secondary : .blue
        }
        switch attempt.credential.status {
        case .working: return .green
        case .noAcc: return .red
        case .permDisabled: return .purple
        case .tempDisabled: return .orange
        case .unsure, .untested: return .yellow
        case .testing: return .blue
        }
    }

    private var displayStatus: String {
        guard attempt.status.isTerminal else { return attempt.status.rawValue }
        return attempt.credential.status.rawValue
    }
}

struct LoginSessionDetailSheet: View {
    let attempt: LoginAttempt
    @State private var showFullScreenshot: Bool = false

    var body: some View {
        NavigationStack {
            List {
                if let snapshot = attempt.responseSnapshot {
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
                    LabeledContent("Username") {
                        Text(attempt.credential.username).font(.system(.caption, design: .monospaced))
                    }
                    LabeledContent("Status") {
                        HStack(spacing: 4) {
                            Image(systemName: attempt.status.icon)
                            Text(attempt.status.isTerminal ? attempt.credential.status.rawValue : attempt.status.rawValue)
                        }
                        .foregroundStyle(statusColorForDetail)
                    }
                    LabeledContent("Session", value: "S\(attempt.sessionIndex)")
                    LabeledContent("Duration", value: attempt.formattedDuration)
                    if let url = attempt.detectedURL {
                        LabeledContent("Final URL") {
                            Text(url).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }

                if let error = attempt.errorMessage {
                    Section("Error") {
                        Text(error).font(.system(.body, design: .monospaced)).foregroundStyle(.red)
                    }
                }

                if let snippet = attempt.responseSnippet {
                    Section("Response Preview") {
                        Text(snippet)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(8)
                    }
                }

                Section("Execution Log") {
                    if attempt.logs.isEmpty {
                        Text("No log entries").foregroundStyle(.secondary)
                    } else {
                        ForEach(attempt.logs) { entry in
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
            .navigationTitle("Session Detail").navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showFullScreenshot) {
                if let snapshot = attempt.responseSnapshot {
                    FullScreenshotView(image: snapshot)
                }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    private var statusColorForDetail: Color {
        guard attempt.status.isTerminal else { return .blue }
        switch attempt.credential.status {
        case .working: return .green
        case .noAcc: return .red
        case .permDisabled: return .purple
        case .tempDisabled: return .orange
        case .unsure, .untested: return .yellow
        case .testing: return .blue
        }
    }

    private func logColor(_ level: PPSRLogEntry.Level) -> Color {
        switch level { case .info: .blue; case .success: .green; case .warning: .orange; case .error: .red }
    }
}

struct FullScreenshotView: View {
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
