import SwiftUI
import Combine
import UIKit

struct DebugLogView: View {
    private let logger = DebugLogger.shared
    @State private var selectedCategories: Set<DebugLogCategory> = Set(DebugLogCategory.allCases)
    @State private var selectedLevel: DebugLogLevel = .trace
    @State private var searchText: String = ""
    @State private var selectedSessionId: String? = nil
    @State private var showFilterSheet: Bool = false
    @State private var showExportSheet: Bool = false
    @State private var showStatsSheet: Bool = false
    @State private var exportText: String = ""
    @State private var autoScroll: Bool = true
    @State private var shareFileURL: URL?
    @State private var showSessionPicker: Bool = false
    @State private var refreshTrigger: Int = 0

    private var filteredEntries: [DebugLogEntry] {
        var result = logger.entries
        result = result.filter { selectedCategories.contains($0.category) }
        result = result.filter { $0.level >= selectedLevel }
        if let sid = selectedSessionId {
            result = result.filter { $0.sessionId == sid }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.message.localizedStandardContains(query) ||
                ($0.detail?.localizedStandardContains(query) ?? false) ||
                ($0.sessionId?.localizedStandardContains(query) ?? false)
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            logList
            bottomBar
        }
        .navigationTitle("Debug Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showStatsSheet = true } label: {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 14))
                }

                Button { showFilterSheet = true } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 14))
                        .symbolVariant(selectedCategories.count < DebugLogCategory.allCases.count || selectedLevel != .trace ? .fill : .none)
                }

                Menu {
                    Button { exportFullLog() } label: {
                        Label("Export Full Log", systemImage: "doc.text")
                    }
                    Button { exportFilteredLog() } label: {
                        Label("Export Filtered Log", systemImage: "doc.text.magnifyingglass")
                    }
                    Divider()
                    Button { exportAsFile() } label: {
                        Label("Export as File", systemImage: "square.and.arrow.up")
                    }
                    Button { exportDiagnosticAsFile() } label: {
                        Label("Export Diagnostic Report", systemImage: "stethoscope")
                    }
                    Divider()
                    Button(role: .destructive) {
                        logger.clearAll()
                        refreshTrigger += 1
                    } label: {
                        Label("Clear All Logs", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search logs...")
        .sheet(isPresented: $showFilterSheet) { filterSheet }
        .sheet(isPresented: $showExportSheet) { exportSheet }
        .sheet(isPresented: $showStatsSheet) { statsSheet }
        .sheet(isPresented: $showSessionPicker) { sessionPickerSheet }
        .sheet(isPresented: Binding(
            get: { shareFileURL != nil },
            set: { if !$0 { shareFileURL = nil } }
        )) {
            if let url = shareFileURL {
                ShareSheetView(items: [url])
            }
        }
        .onReceive(logger.didChange.throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)) { _ in
            refreshTrigger += 1
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                levelPill

                if let sid = selectedSessionId {
                    Button {
                        selectedSessionId = nil
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                                .font(.system(size: 9))
                            Text(sid.prefix(16))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 9))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                    }
                } else {
                    Button { showSessionPicker = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                                .font(.system(size: 9))
                            Text("Session")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.tertiarySystemFill))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                    }
                }

                Divider().frame(height: 16)

                ForEach(DebugLogCategory.allCases) { cat in
                    Button {
                        if selectedCategories.contains(cat) {
                            selectedCategories.remove(cat)
                        } else {
                            selectedCategories.insert(cat)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: cat.icon)
                                .font(.system(size: 8))
                            Text(cat.rawValue)
                                .font(.system(size: 9, weight: .medium))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(selectedCategories.contains(cat) ? categoryColor(cat).opacity(0.15) : Color(.tertiarySystemFill))
                        .foregroundStyle(selectedCategories.contains(cat) ? categoryColor(cat) : .secondary)
                        .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var levelPill: some View {
        Menu {
            ForEach(DebugLogLevel.allCases, id: \.rawValue) { level in
                Button {
                    selectedLevel = level
                } label: {
                    HStack {
                        Text("\(level.emoji) \(level.rawValue)")
                        if level == selectedLevel {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(selectedLevel.emoji)
                    .font(.system(size: 9))
                Text("≥ \(selectedLevel.rawValue)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(levelColor(selectedLevel).opacity(0.15))
            .foregroundStyle(levelColor(selectedLevel))
            .clipShape(Capsule())
        }
    }

    private var logList: some View {
        let _ = refreshTrigger
        let entries = filteredEntries
        return Group {
            if entries.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(logger.entries.isEmpty ? "No logs yet" : "No logs match filters")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !logger.entries.isEmpty {
                        Button("Reset Filters") {
                            selectedCategories = Set(DebugLogCategory.allCases)
                            selectedLevel = .trace
                            selectedSessionId = nil
                            searchText = ""
                        }
                        .font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(entries) { entry in
                            DebugLogEntryRow(entry: entry) {
                                selectedSessionId = entry.sessionId
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .defaultScrollAnchor(.top)
            }
        }
    }

    private var bottomBar: some View {
        let _ = refreshTrigger
        return HStack(spacing: 12) {
            HStack(spacing: 4) {
                Circle()
                    .fill(logger.isRecording ? .green : .red)
                    .frame(width: 6, height: 6)
                Text(logger.isRecording ? "Recording" : "Paused")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text("\(filteredEntries.count)/\(logger.entryCount)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            if logger.errorCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                    Text("\(logger.errorCount)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }

            if logger.warningCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text("\(logger.warningCount)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }

            Button {
                logger.isRecording.toggle()
            } label: {
                Image(systemName: logger.isRecording ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(logger.isRecording ? .orange : .green)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private var filterSheet: some View {
        NavigationStack {
            List {
                Section("Minimum Log Level") {
                    ForEach(DebugLogLevel.allCases, id: \.rawValue) { level in
                        Button {
                            selectedLevel = level
                        } label: {
                            HStack {
                                Text(level.emoji)
                                Text(level.rawValue)
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                                if level == selectedLevel {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }

                Section("Categories") {
                    HStack {
                        Button("All") { selectedCategories = Set(DebugLogCategory.allCases) }
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("None") { selectedCategories.removeAll() }
                            .font(.subheadline.weight(.semibold))
                    }
                    ForEach(DebugLogCategory.allCases) { cat in
                        Toggle(isOn: Binding(
                            get: { selectedCategories.contains(cat) },
                            set: { on in
                                if on { selectedCategories.insert(cat) }
                                else { selectedCategories.remove(cat) }
                            }
                        )) {
                            HStack(spacing: 8) {
                                Image(systemName: cat.icon)
                                    .foregroundStyle(categoryColor(cat))
                                    .frame(width: 20)
                                Text(cat.rawValue)
                            }
                        }
                    }
                }

                Section("Max Entries") {
                    Stepper("Keep \(logger.maxEntries) entries", value: Binding(
                        get: { logger.maxEntries },
                        set: { logger.maxEntries = $0 }
                    ), in: 1000...50000, step: 1000)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showFilterSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var exportSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text("\(exportText.components(separatedBy: "\n").count) lines")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    ShareLink(item: exportText) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                ScrollView {
                    Text(exportText)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .textSelection(.enabled)
                }
                .background(Color(.secondarySystemBackground))
            }
            .navigationTitle("Log Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { showExportSheet = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = exportText
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
    }

    private var statsSheet: some View {
        NavigationStack {
            List {
                Section("Overview") {
                    StatRow(label: "Total Entries", value: "\(logger.entryCount)")
                    StatRow(label: "Errors", value: "\(logger.errorCount)", color: .red)
                    StatRow(label: "Warnings", value: "\(logger.warningCount)", color: .orange)
                    StatRow(label: "Active Sessions", value: "\(logger.uniqueSessionIds.count)")
                }

                Section("By Level") {
                    let breakdown = logger.levelBreakdown
                    ForEach(Array(breakdown.enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(item.level.emoji)
                            Text(item.level.rawValue)
                                .font(.body.monospaced())
                            Spacer()
                            Text("\(item.count)")
                                .font(.body.monospaced().weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("By Category") {
                    let catBreakdown = logger.categoryBreakdown
                    ForEach(Array(catBreakdown.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            Image(systemName: item.category.icon)
                                .foregroundStyle(categoryColor(item.category))
                                .frame(width: 20)
                            Text(item.category.rawValue)
                            Spacer()
                            Text("\(item.count)")
                                .font(.body.monospaced().weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Log Statistics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showStatsSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var sessionPickerSheet: some View {
        NavigationStack {
            List {
                let sessions = logger.uniqueSessionIds
                if sessions.isEmpty {
                    Text("No sessions recorded yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessions, id: \.self) { sid in
                        Button {
                            selectedSessionId = sid
                            showSessionPicker = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(sid)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.primary)
                                let count = logger.entriesForSession(sid).count
                                Text("\(count) entries")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showSessionPicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func exportAsFile() {
        if let url = logger.exportLogToFile() {
            shareFileURL = url
        }
    }

    private func exportDiagnosticAsFile() {
        if let url = logger.exportDiagnosticReportToFile() {
            shareFileURL = url
        }
    }

    private func exportFullLog() {
        exportText = logger.exportFullLog()
        showExportSheet = true
    }

    private func exportFilteredLog() {
        let cats = selectedCategories.count < DebugLogCategory.allCases.count ? selectedCategories : nil
        exportText = logger.exportFilteredLog(
            categories: cats,
            minLevel: selectedLevel != .trace ? selectedLevel : nil,
            sessionId: selectedSessionId
        )
        showExportSheet = true
    }

    private func categoryColor(_ cat: DebugLogCategory) -> Color {
        switch cat.color {
        case "blue": .blue
        case "green": .green
        case "cyan": .cyan
        case "purple": .purple
        case "orange": .orange
        case "red": .red
        case "indigo": .indigo
        case "teal": .teal
        case "mint": .mint
        case "pink": .pink
        case "gray": .gray
        case "brown": .brown
        case "yellow": .yellow
        default: .secondary
        }
    }

    private func levelColor(_ level: DebugLogLevel) -> Color {
        switch level {
        case .trace: .gray
        case .debug: .blue
        case .info: .primary
        case .success: .green
        case .warning: .orange
        case .error: .red
        case .critical: .red
        }
    }
}

struct DebugLogEntryRow: View {
    let entry: DebugLogEntry
    var onSessionTap: (() -> Void)? = nil

    @State private var expanded: Bool = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                expanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 4) {
                    Text(entry.formattedTime)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 62, alignment: .leading)

                    levelIndicator

                    Text(entry.category.rawValue)
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(categoryColor(entry.category).opacity(0.8))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(categoryColor(entry.category).opacity(0.1))
                        .clipShape(.rect(cornerRadius: 2))

                    if let ms = entry.durationMs {
                        Text("\(ms)ms")
                            .font(.system(size: 7, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ms > 5000 ? .red : ms > 2000 ? .orange : .green)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(.rect(cornerRadius: 2))
                    }

                    Spacer()
                }

                Text(entry.message)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(levelTextColor)
                    .lineLimit(expanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if expanded {
                    expandedContent
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let detail = entry.detail {
                Text(detail)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if let sid = entry.sessionId {
                Button {
                    onSessionTap?()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "link")
                            .font(.system(size: 8))
                        Text(sid)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.blue)
                }
            }

            if let meta = entry.metadata, !meta.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(meta.keys.sorted()), id: \.self) { key in
                        HStack(spacing: 4) {
                            Text(key)
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(meta[key] ?? "")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(4)
                .background(Color(.tertiarySystemFill))
                .clipShape(.rect(cornerRadius: 4))
            }

            HStack {
                Text(entry.fullTimestamp)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    UIPasteboard.general.string = entry.exportLine
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 2)
    }

    private var levelIndicator: some View {
        let color: Color = {
            switch entry.level {
            case .trace: .gray
            case .debug: .blue
            case .info: .primary
            case .success: .green
            case .warning: .orange
            case .error: .red
            case .critical: .red
            }
        }()

        return Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .padding(.top, 2)
    }

    private var levelTextColor: Color {
        switch entry.level {
        case .trace: .secondary
        case .debug: .primary.opacity(0.7)
        case .info: .primary
        case .success: .green
        case .warning: .orange
        case .error: .red
        case .critical: .red
        }
    }

    private var rowBackground: Color {
        switch entry.level {
        case .error, .critical: .red.opacity(0.04)
        case .warning: .orange.opacity(0.03)
        case .success: .green.opacity(0.03)
        default: .clear
        }
    }

    private func categoryColor(_ cat: DebugLogCategory) -> Color {
        switch cat.color {
        case "blue": .blue
        case "green": .green
        case "cyan": .cyan
        case "purple": .purple
        case "orange": .orange
        case "red": .red
        case "indigo": .indigo
        case "teal": .teal
        case "mint": .mint
        case "pink": .pink
        case "gray": .gray
        case "brown": .brown
        case "yellow": .yellow
        default: .secondary
        }
    }
}

private struct StatRow: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.body.monospaced().weight(.semibold))
                .foregroundStyle(color)
        }
    }
}
