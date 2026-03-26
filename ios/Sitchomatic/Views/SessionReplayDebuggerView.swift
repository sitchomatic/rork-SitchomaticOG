import SwiftUI

struct SessionReplayDebuggerView: View {
    let vm: LoginViewModel
    @State private var replays: [EnrichedSessionReplay] = []
    @State private var selectedReplay: EnrichedSessionReplay?
    @State private var isLoading: Bool = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading session replays...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if replays.isEmpty {
                ContentUnavailableView(
                    "No Session Replays",
                    systemImage: "play.rectangle.on.rectangle",
                    description: Text("Run automation tests to capture session replays. Each test records a step-by-step timeline.")
                )
            } else {
                replayList
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Replay Debugger")
        .toolbar {
            if !replays.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            ReplayDebuggerService.shared.clearAllReplays()
                            replays = []
                        } label: {
                            Label("Clear All Replays", systemImage: "trash")
                        }
                        Button {
                            loadReplays()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .onAppear { loadReplays() }
        .sheet(item: $selectedReplay) { replay in
            NavigationStack {
                ReplayTimelineView(replay: replay)
            }
            .presentationDetents([.large])
        }
    }

    private var replayList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(replays) { replay in
                    Button { selectedReplay = replay } label: {
                        ReplaySessionCard(replay: replay)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
    }

    private func loadReplays() {
        isLoading = true
        let saved = ReplayDebuggerService.shared.loadSavedReplays()
        let active = ReplayDebuggerService.shared.loadActiveReplays()
        var combined = active + saved
        let seen = NSMutableSet()
        combined = combined.filter { replay in
            if seen.contains(replay.sessionId) { return false }
            seen.add(replay.sessionId)
            return true
        }
        replays = combined
        isLoading = false
    }
}

struct ReplaySessionCard: View {
    let replay: EnrichedSessionReplay

    private var outcomeColor: Color {
        switch replay.outcome.lowercased() {
        case "success": .green
        case "noacc", "no_acc": .orange
        case "permdisabled", "perm_disabled": .red
        case "tempdisabled", "temp_disabled": .yellow
        case "in_progress": .blue
        default: .secondary
        }
    }

    private var outcomeIcon: String {
        switch replay.outcome.lowercased() {
        case "success": "checkmark.circle.fill"
        case "noacc", "no_acc": "person.slash.fill"
        case "permdisabled", "perm_disabled": "lock.fill"
        case "tempdisabled", "temp_disabled": "clock.badge.exclamationmark"
        case "in_progress": "play.circle.fill"
        case "timeout": "hourglass"
        case "connectionfailure", "connection_failure": "wifi.slash"
        default: "questionmark.circle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: outcomeIcon)
                    .font(.title3)
                    .foregroundStyle(outcomeColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(replay.credential)
                        .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                        .lineLimit(1)
                    Text(replay.targetURL)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(replay.outcome.uppercased())
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(outcomeColor)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(outcomeColor.opacity(0.12))
                    .clipShape(Capsule())
            }

            HStack(spacing: 16) {
                Label("\(replay.steps.count) steps", systemImage: "list.number")
                Label(formatDuration(replay.totalDurationMs), systemImage: "stopwatch")
                Spacer()
                Text(DateFormatters.timeWithMillis.string(from: replay.startedAt))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)

            if !replay.logEntries.isEmpty {
                let errors = replay.logEntries.filter { $0.level >= .error }.count
                let warnings = replay.logEntries.filter { $0.level == .warning }.count
                HStack(spacing: 8) {
                    Label("\(replay.logEntries.count) logs", systemImage: "doc.text")
                    if errors > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            Text("\(errors)")
                        }
                    }
                    if warnings > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("\(warnings)")
                        }
                    }
                    Spacer()
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func formatDuration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1000.0
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(minutes)m \(secs)s"
    }
}

struct ReplayTimelineView: View {
    let replay: EnrichedSessionReplay
    @Environment(\.dismiss) private var dismiss
    @State private var currentStepIndex: Int = 0
    @State private var isPlaying: Bool = false
    @State private var playbackTask: Task<Void, Never>?
    @State private var showLogs: Bool = false
    @State private var showHeatmap: Bool = false
    @State private var heatmapScreenshot: PPSRDebugScreenshot?
    @State private var expandedSteps: Set<String> = []
    @State private var filterLevel: StepFilter = .all

    private enum StepFilter: String, CaseIterable {
        case all = "All"
        case errors = "Errors"
        case patterns = "Patterns"
        case phases = "Phases"
    }

    private var filteredSteps: [EnrichedReplayStep] {
        switch filterLevel {
        case .all: return replay.steps
        case .errors: return replay.steps.filter { $0.level == "error" || $0.level == "critical" || $0.level == "warning" }
        case .patterns: return replay.steps.filter { $0.pattern != nil }
        case .phases: return replay.steps.filter { $0.phase != nil }
        }
    }

    private var currentStep: EnrichedReplayStep? {
        guard currentStepIndex >= 0, currentStepIndex < filteredSteps.count else { return nil }
        return filteredSteps[currentStepIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            sessionHeader
            Divider()
            playbackControls
            Divider()
            filterBar
            Divider()
            timelineContent
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Session Timeline")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { stopPlayback(); dismiss() }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showLogs.toggle()
                } label: {
                    Image(systemName: "doc.text")
                }
            }
        }
        .sheet(isPresented: $showLogs) {
            NavigationStack {
                ReplayLogListView(entries: replay.logEntries)
            }
            .presentationDetents([.medium, .large])
        }
        .onDisappear { stopPlayback() }
    }

    private var sessionHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(replay.credential)
                        .font(.system(.subheadline, design: .monospaced, weight: .bold))
                    Text(replay.targetURL)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(replay.outcome.uppercased())
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(outcomeColor)
                    Text(formatDuration(replay.totalDurationMs))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if let step = currentStep {
                HStack(spacing: 6) {
                    Circle()
                        .fill(levelColor(step.level))
                        .frame(width: 8, height: 8)
                    Text("Step \(currentStepIndex + 1)/\(filteredSteps.count)")
                        .font(.system(.caption2, design: .monospaced, weight: .medium))
                    Text("•")
                        .foregroundStyle(.quaternary)
                    Text("+\(formatDuration(step.elapsedMs))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let pattern = step.pattern {
                        Text("•")
                            .foregroundStyle(.quaternary)
                        Text(pattern)
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(.cyan)
                    }
                    Spacer()
                }
            }

            ProgressView(value: Double(currentStepIndex + 1), total: Double(max(filteredSteps.count, 1)))
                .tint(outcomeColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var playbackControls: some View {
        HStack(spacing: 20) {
            Button {
                currentStepIndex = 0
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title3)
            }
            .disabled(currentStepIndex == 0)

            Button {
                if currentStepIndex > 0 { currentStepIndex -= 1 }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title3)
            }
            .disabled(currentStepIndex == 0)

            Button {
                if isPlaying {
                    stopPlayback()
                } else {
                    startPlayback()
                }
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(outcomeColor)
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: isPlaying)

            Button {
                if currentStepIndex < filteredSteps.count - 1 { currentStepIndex += 1 }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
            }
            .disabled(currentStepIndex >= filteredSteps.count - 1)

            Button {
                currentStepIndex = filteredSteps.count - 1
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title3)
            }
            .disabled(currentStepIndex >= filteredSteps.count - 1)
        }
        .padding(.vertical, 10)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(StepFilter.allCases, id: \.self) { filter in
                    Button {
                        withAnimation(.snappy) {
                            filterLevel = filter
                            currentStepIndex = 0
                        }
                    } label: {
                        Text(filter.rawValue)
                            .font(.system(.caption, design: .monospaced, weight: filterLevel == filter ? .bold : .medium))
                            .foregroundStyle(filterLevel == filter ? .white : .secondary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(filterLevel == filter ? outcomeColor : Color(.tertiarySystemGroupedBackground))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .contentMargins(.vertical, 8)
    }

    private var timelineContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredSteps.enumerated()), id: \.element.id) { index, step in
                        ReplayStepRow(
                            step: step,
                            isCurrent: index == currentStepIndex,
                            isExpanded: expandedSteps.contains(step.id),
                            onTap: { currentStepIndex = index },
                            onToggleExpand: {
                                withAnimation(.snappy) {
                                    if expandedSteps.contains(step.id) {
                                        expandedSteps.remove(step.id)
                                    } else {
                                        expandedSteps.insert(step.id)
                                    }
                                }
                            }
                        )
                        .id(step.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: currentStepIndex) { _, newValue in
                if newValue < filteredSteps.count {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(filteredSteps[newValue].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func startPlayback() {
        isPlaying = true
        playbackTask = Task {
            while !Task.isCancelled && currentStepIndex < filteredSteps.count - 1 {
                let nextIndex = currentStepIndex + 1
                let currentMs = filteredSteps[currentStepIndex].elapsedMs
                let nextMs = filteredSteps[nextIndex].elapsedMs
                let delayMs = max(200, min(nextMs - currentMs, 3000))
                try? await Task.sleep(for: .milliseconds(delayMs))
                if Task.isCancelled { break }
                currentStepIndex = nextIndex
            }
            isPlaying = false
        }
    }

    private func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
    }

    private var outcomeColor: Color {
        switch replay.outcome.lowercased() {
        case "success": .green
        case "noacc", "no_acc": .orange
        case "permdisabled", "perm_disabled": .red
        case "in_progress": .blue
        default: .secondary
        }
    }

    private func levelColor(_ level: String) -> Color {
        switch level.lowercased() {
        case "error", "critical": .red
        case "warning": .orange
        case "success", "ok": .green
        case "debug": .purple
        default: .blue
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1000.0
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(minutes)m \(secs)s"
    }
}

struct ReplayStepRow: View {
    let step: EnrichedReplayStep
    let isCurrent: Bool
    let isExpanded: Bool
    let onTap: () -> Void
    let onToggleExpand: () -> Void

    private var levelColor: Color {
        switch step.level.lowercased() {
        case "error", "critical": .red
        case "warning": .orange
        case "success", "ok": .green
        case "debug": .purple
        default: .blue
        }
    }

    private var actionIcon: String {
        let action = step.action.lowercased()
        if action.contains("page_load") { return "globe" }
        if action.contains("cookie") { return "shield.lefthalf.filled" }
        if action.contains("field") || action.contains("fill") || action.contains("credential") { return "text.cursor" }
        if action.contains("submit") || action.contains("click") { return "hand.tap.fill" }
        if action.contains("poll") || action.contains("wait") { return "hourglass" }
        if action.contains("evaluate") || action.contains("eval") { return "doc.text.magnifyingglass" }
        if action.contains("complete") { return "checkmark.circle.fill" }
        if action.contains("pattern") { return "wand.and.stars" }
        if action.contains("screenshot") { return "camera.fill" }
        if action.contains("calibrat") { return "scope" }
        if action.contains("blank") { return "rectangle.dashed" }
        if action.contains("fail") || action.contains("error") { return "xmark.circle.fill" }
        if action.contains("init") { return "play.fill" }
        return "circle.fill"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 0) {
                timelineGutter
                stepContent
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(isCurrent ? levelColor.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
    }

    private var timelineGutter: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(isCurrent ? levelColor : Color(.separator))
                .frame(width: isCurrent ? 3 : 1, height: 8)
            ZStack {
                Circle()
                    .fill(isCurrent ? levelColor : Color(.separator))
                    .frame(width: isCurrent ? 28 : 20, height: isCurrent ? 28 : 20)
                Image(systemName: actionIcon)
                    .font(.system(size: isCurrent ? 12 : 9, weight: .bold))
                    .foregroundStyle(isCurrent ? .white : .secondary)
            }
            Rectangle()
                .fill(isCurrent ? levelColor : Color(.separator))
                .frame(width: isCurrent ? 3 : 1)
                .frame(maxHeight: .infinity)
        }
        .frame(width: 32)
        .padding(.trailing, 10)
    }

    private var stepContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(step.action.replacingOccurrences(of: "_", with: " ").uppercased())
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(isCurrent ? levelColor : .secondary)

                Spacer()

                Text("+\(formatElapsed(step.elapsedMs))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)

                if step.durationMs != nil || step.pattern != nil || step.jsResult != nil {
                    Button(action: onToggleExpand) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Text(step.detail)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .lineLimit(isExpanded ? nil : 2)

            if let pattern = step.pattern {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 9))
                    Text(pattern)
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                }
                .foregroundStyle(.cyan)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.cyan.opacity(0.1))
                .clipShape(Capsule())
            }

            if isExpanded {
                expandedContent
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let durationMs = step.durationMs {
                HStack(spacing: 4) {
                    Image(systemName: "stopwatch").font(.caption2)
                    Text("Duration: \(formatElapsed(durationMs))")
                        .font(.system(.caption2, design: .monospaced))
                }
                .foregroundStyle(.orange)
            }

            if let jsResult = step.jsResult {
                VStack(alignment: .leading, spacing: 2) {
                    Text("JS Result:")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.purple)
                    Text(jsResult)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.purple.opacity(0.06))
                .clipShape(.rect(cornerRadius: 6))
            }

            if let phase = step.phase {
                HStack(spacing: 4) {
                    Image(systemName: "flag.fill").font(.caption2)
                    Text("Phase: \(phase)")
                        .font(.system(.caption2, design: .monospaced))
                }
                .foregroundStyle(.indigo)
            }

            if let screenshotId = step.screenshotId {
                HStack(spacing: 4) {
                    Image(systemName: "camera.fill").font(.caption2)
                    Text("Screenshot: \(screenshotId)")
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(.green)
            }
        }
        .padding(.top, 4)
    }

    private func formatElapsed(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1000.0
        return String(format: "%.1fs", seconds)
    }
}

struct ReplayLogListView: View {
    let entries: [DebugLogEntry]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(entryColor(entry.level))
                            .frame(width: 8, height: 8)
                        Text(entry.level.rawValue)
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(entryColor(entry.level))
                        Text(entry.category.rawValue)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.formattedTime)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Text(entry.message)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(4)
                    if let detail = entry.detail {
                        Text(detail)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let durationMs = entry.durationMs {
                        Text("\(durationMs)ms")
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
            }
        }
        .listStyle(.plain)
        .navigationTitle("Session Logs (\(entries.count))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func entryColor(_ level: DebugLogLevel) -> Color {
        switch level {
        case .trace: .gray
        case .debug: .purple
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .error: .red
        case .critical: .red
        }
    }
}
