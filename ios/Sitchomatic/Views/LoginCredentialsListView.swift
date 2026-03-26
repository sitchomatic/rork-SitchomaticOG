import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct LoginCredentialsListView: View {
    let vm: LoginViewModel
    @State private var showImportSheet: Bool = false
    @State private var importText: String = ""
    @State private var searchText: String = ""
    @State private var sortOption: SortOption = {
        if let raw = UserDefaults.standard.string(forKey: "login_cred_sort_option"),
           let opt = SortOption(rawValue: raw) { return opt }
        return .dateAdded
    }()
    @State private var sortAscending: Bool = UserDefaults.standard.bool(forKey: "login_cred_sort_ascending")
    @State private var filterStatus: CredentialStatus? = nil
    @State private var bulkText: String = ""
    @State private var showBulkImport: Bool = false
    @State private var bulkImportResult: String? = nil
    @State private var viewMode: ViewMode = .list

    nonisolated enum SortOption: String, CaseIterable, Identifiable, Sendable {
        case dateAdded = "Date Added"
        case lastTest = "Last Test"
        case successRate = "Success Rate"
        case totalTests = "Total Tests"
        case username = "Username"
        var id: String { rawValue }
    }

    private var filteredCredentials: [LoginCredential] {
        var result = vm.credentials
        if !searchText.isEmpty {
            result = result.filter {
                $0.username.localizedStandardContains(searchText) ||
                $0.notes.localizedStandardContains(searchText)
            }
        }
        if let status = filterStatus { result = result.filter { $0.status == status } }

        result.sort { a, b in
            let comparison: Bool
            switch sortOption {
            case .dateAdded: comparison = a.addedAt > b.addedAt
            case .lastTest: comparison = (a.lastTestedAt ?? .distantPast) > (b.lastTestedAt ?? .distantPast)
            case .successRate: comparison = a.successRate > b.successRate
            case .totalTests: comparison = a.totalTests > b.totalTests
            case .username: comparison = a.username < b.username
            }
            return sortAscending ? !comparison : comparison
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            sortFilterBar
            if showBulkImport { bulkImportBox }
            if viewMode == .tile {
                credentialsTileGrid
            } else {
                credentialsList
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Credentials")
        .searchable(text: $searchText, prompt: "Search credentials...")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    CredentialGroupsView(vm: vm)
                } label: {
                    Image(systemName: "folder.fill")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ViewModeToggle(mode: $viewMode, accentColor: .green)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.snappy) { showBulkImport.toggle() }
                } label: {
                    Image(systemName: showBulkImport ? "rectangle.and.pencil.and.ellipsis" : "doc.on.clipboard")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImportSheet = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showImportSheet) { importSheet }
        .onChange(of: sortOption) { _, newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: "login_cred_sort_option")
        }
        .onChange(of: sortAscending) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "login_cred_sort_ascending")
        }
    }

    private var bulkImportBox: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Bulk Import", systemImage: "doc.on.clipboard.fill")
                    .font(.subheadline.bold())
                Spacer()
                if let result = bulkImportResult {
                    Text(result)
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                Button { withAnimation(.snappy) { showBulkImport = false; bulkText = ""; bulkImportResult = nil } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                ForEach(["user:pass", "user;pass", "user,pass"], id: \.self) { fmt in
                    Text(fmt)
                        .font(.system(.caption2, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(Capsule())
                }
                Spacer()
            }
            .foregroundStyle(.secondary)

            TextEditor(text: $bulkText)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 10))
                .frame(height: 120)
                .overlay(alignment: .topLeading) {
                    if bulkText.isEmpty {
                        Text("Paste credentials here...\nOne per line: user:pass")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.quaternary)
                            .padding(.horizontal, 14).padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 12) {
                let lineCount = bulkText.components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
                if lineCount > 0 {
                    Text("\(lineCount) line\(lineCount == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if let clipboardString = UIPasteboard.general.string, !clipboardString.isEmpty {
                        bulkText = clipboardString
                    }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(.secondary)

                Button {
                    let before = vm.credentials.count
                    vm.smartImportCredentials(bulkText)
                    let added = vm.credentials.count - before
                    withAnimation(.snappy) {
                        bulkImportResult = "\(added) added"
                    }
                    bulkText = ""
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation(.snappy) { bulkImportResult = nil }
                    }
                } label: {
                    Label("Import", systemImage: "arrow.down.doc.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(bulkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var sortFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(SortOption.allCases) { option in
                        Button {
                            withAnimation(.snappy) {
                                if sortOption == option { sortAscending.toggle() }
                                else { sortOption = option; sortAscending = false }
                            }
                        } label: {
                            HStack {
                                Text(option.rawValue)
                                if sortOption == option { Image(systemName: sortAscending ? "chevron.up" : "chevron.down") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down").font(.caption2)
                        Text(sortOption.rawValue).font(.subheadline.weight(.medium))
                        Image(systemName: sortAscending ? "chevron.up" : "chevron.down").font(.caption2)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.green.opacity(0.15)).foregroundStyle(.green).clipShape(Capsule())
                }

                Text("\(filteredCredentials.count) credentials")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color(.tertiarySystemFill)).clipShape(Capsule())

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        LoginFilterChip(title: "All", isSelected: filterStatus == nil) { withAnimation(.snappy) { filterStatus = nil } }
                        LoginFilterChip(title: "Working", isSelected: filterStatus == .working) { withAnimation(.snappy) { filterStatus = .working } }
                        LoginFilterChip(title: "Untested", isSelected: filterStatus == .untested) { withAnimation(.snappy) { filterStatus = .untested } }
                        LoginFilterChip(title: "No Acc", isSelected: filterStatus == .noAcc) { withAnimation(.snappy) { filterStatus = .noAcc } }
                        LoginFilterChip(title: "Perm Dis", isSelected: filterStatus == .permDisabled) { withAnimation(.snappy) { filterStatus = .permDisabled } }
                        LoginFilterChip(title: "Temp Dis", isSelected: filterStatus == .tempDisabled) { withAnimation(.snappy) { filterStatus = .tempDisabled } }
                        LoginFilterChip(title: "Unsure", isSelected: filterStatus == .unsure) { withAnimation(.snappy) { filterStatus = .unsure } }
                    }
                }
            }
            .padding(.horizontal).padding(.vertical, 10)
        }
    }

    private var credentialsList: some View {
        Group {
            if filteredCredentials.isEmpty {
                if vm.credentials.isEmpty {
                    EmptyStateView(
                        icon: "person.badge.key.fill",
                        title: "No Credentials",
                        subtitle: "Import credentials to get started.",
                        accentColor: .green,
                        actionTitle: "Import Credentials",
                        action: { showImportSheet = true },
                        tips: [
                            EmptyStateTip(icon: "doc.on.clipboard", text: "Paste in user:pass, user;pass, or user,pass format"),
                            EmptyStateTip(icon: "list.bullet", text: "One credential per line for bulk import"),
                            EmptyStateTip(icon: "arrow.triangle.2.circlepath", text: "Duplicates are automatically excluded")
                        ]
                    )
                } else {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "No Matches",
                        subtitle: "Try adjusting your filters or search terms.",
                        accentColor: .secondary
                    )
                }
            } else {
                List {
                    ForEach(Array(filteredCredentials.prefix(500))) { cred in
                        NavigationLink(value: cred.id) {
                            LoginSavedCredRow(credential: cred)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { vm.deleteCredential(cred) } label: { Label("Delete", systemImage: "trash") }
                            Button { vm.testSingleCredential(cred) } label: { Label("Test", systemImage: "play.fill") }.tint(.green)
                        }
                        .listRowBackground(Color(.secondarySystemGroupedBackground))
                    }
                    if filteredCredentials.count > 500 {
                        HStack {
                            Spacer()
                            Text("Showing 500 of \(filteredCredentials.count) — use search to narrow results")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private var credentialsTileGrid: some View {
        Group {
            if filteredCredentials.isEmpty {
                if vm.credentials.isEmpty {
                    EmptyStateView(
                        icon: "person.badge.key.fill",
                        title: "No Credentials",
                        subtitle: "Import credentials to get started.",
                        accentColor: .green,
                        actionTitle: "Import Credentials",
                        action: { showImportSheet = true },
                        tips: [
                            EmptyStateTip(icon: "doc.on.clipboard", text: "Paste in user:pass, user;pass, or user,pass format"),
                            EmptyStateTip(icon: "list.bullet", text: "One credential per line for bulk import"),
                            EmptyStateTip(icon: "arrow.triangle.2.circlepath", text: "Duplicates are automatically excluded")
                        ]
                    )
                } else {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "No Matches",
                        subtitle: "Try adjusting your filters or search terms.",
                        accentColor: .secondary
                    )
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(filteredCredentials) { cred in
                            NavigationLink(value: cred.id) {
                                let screenshot = vm.screenshotsForCredential(cred.id).first?.image
                                ScreenshotTileView(
                                    screenshot: screenshot,
                                    title: cred.username,
                                    subtitle: cred.maskedPassword,
                                    statusColor: credTileStatusColor(cred.status),
                                    statusText: cred.status.rawValue,
                                    badge: cred.totalTests > 0 ? "\(cred.successCount)/\(cred.totalTests)" : nil
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 32)
                }
            }
        }
    }

    private func credTileStatusColor(_ status: CredentialStatus) -> Color {
        switch status {
        case .working: .green
        case .noAcc: .red
        case .permDisabled: .red.opacity(0.7)
        case .tempDisabled: .orange
        case .unsure: .yellow
        case .testing: .green
        case .untested: .secondary
        }
    }

    private var importSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Smart Import").font(.headline)
                    Text("Paste login credentials in common formats. One per line.")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Supported formats:").font(.caption.bold()).foregroundStyle(.secondary)
                        Group {
                            Text("user@email.com:password123")
                            Text("user@email.com;password123")
                            Text("user@email.com,password123")
                            Text("user@email.com|password123")
                        }
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TextEditor(text: $importText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden).padding(12)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 10)).frame(minHeight: 180)
                Spacer()
            }
            .padding()
            .navigationTitle("Import Credentials").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showImportSheet = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        vm.smartImportCredentials(importText)
                        importText = ""
                        showImportSheet = false
                    }
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }
}

struct LoginSavedCredRow: View {
    let credential: LoginCredential

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(statusColor.opacity(0.12)).frame(width: 40, height: 40)
                Image(systemName: "person.fill").font(.title3.bold()).foregroundStyle(statusColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(credential.username)
                    .font(.system(.subheadline, design: .monospaced, weight: .semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    Text(credential.maskedPassword)
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                    if credential.totalTests > 0 {
                        Text("\(credential.successCount)/\(credential.totalTests)")
                            .font(.caption2.bold())
                            .foregroundStyle(credential.lastTestSuccess == true ? .green : .red)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 3) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(credential.status.rawValue)
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(statusColor)
                }
                if credential.status == .testing { ProgressView().controlSize(.small).tint(.green) }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch credential.status {
        case .working: .green
        case .noAcc: .red
        case .permDisabled: .red.opacity(0.7)
        case .tempDisabled: .orange
        case .unsure: .yellow
        case .testing: .green
        case .untested: .secondary
        }
    }
}

struct LoginFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(isSelected ? Color.green : Color(.tertiarySystemFill))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
