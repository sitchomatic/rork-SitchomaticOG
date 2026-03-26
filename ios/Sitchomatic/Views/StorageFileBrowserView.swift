import SwiftUI
import UIKit

struct StorageFileBrowserView: View {
    @State private var summary: StorageSummary = StorageSummary()
    @State private var isLoading: Bool = true
    @State private var isSaving: Bool = false
    @State private var showBackupConfirm: Bool = false
    @State private var backupResult: String?
    @State private var selectedFile: StoredFileInfo?
    @State private var fileContent: String?
    @State private var showFileDetail: Bool = false
    @State private var showShareSheet: Bool = false
    @State private var shareURL: URL?

    private let storage = PersistentFileStorageService.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerCard
                actionBar
                storageBreakdown
                fileSections
            }
            .padding(.bottom, 30)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Vault")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        saveNow()
                    } label: {
                        Label("Save Now", systemImage: "arrow.down.doc.fill")
                    }

                    Button {
                        showBackupConfirm = true
                    } label: {
                        Label("Create Backup", systemImage: "arrow.clockwise.icloud.fill")
                    }

                    Divider()

                    Button {
                        refreshSummary()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.teal)
                }
            }
        }
        .task {
            refreshSummary()
        }
        .alert("Create Backup", isPresented: $showBackupConfirm) {
            Button("Create", role: .none) { createBackup() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will save a full snapshot of all app data to the vault.")
        }
        .alert("Backup", isPresented: .init(get: { backupResult != nil }, set: { if !$0 { backupResult = nil } })) {
            Button("OK") { backupResult = nil }
        } message: {
            Text(backupResult ?? "")
        }
        .sheet(isPresented: $showFileDetail) {
            if let file = selectedFile {
                FileDetailSheet(file: file, content: fileContent, onDelete: {
                    _ = storage.deleteFile(file.url)
                    showFileDetail = false
                    selectedFile = nil
                    fileContent = nil
                    refreshSummary()
                }, onShare: {
                    shareURL = file.url
                    showShareSheet = true
                })
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = shareURL {
                ShareSheet(activityItems: [url])
            }
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(.teal.opacity(0.15))
                        .frame(width: 52, height: 52)
                    Image(systemName: "externaldrive.fill.badge.checkmark")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.teal)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("App Vault")
                        .font(.system(size: 18, weight: .bold))

                    if let lastSaved = summary.lastSaved {
                        Text("Last saved \(lastSaved, style: .relative) ago")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No data saved yet")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(summary.formattedTotalSize)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(.teal)
                    Text("\(summary.totalFileCount) files")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 4) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green)
                Text("Survives app updates — stored in Documents")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                saveNow()
            } label: {
                HStack(spacing: 5) {
                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text("SAVE NOW")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                }
                .foregroundStyle(.teal)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.teal.opacity(0.12))
                .clipShape(.rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(isSaving)

            Button {
                showBackupConfirm = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise.icloud.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("BACKUP")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                }
                .foregroundStyle(.indigo)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.indigo.opacity(0.12))
                .clipShape(.rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Breakdown

    private var storageBreakdown: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
            ForEach(Array(summary.sections.enumerated()), id: \.offset) { _, section in
                if !section.files.isEmpty {
                    breakdownChip(title: section.title, icon: section.icon, count: section.files.count, color: colorForName(section.color))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func breakdownChip(title: String, icon: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
            Text("\(count)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
        .clipShape(.rect(cornerRadius: 8))
    }

    // MARK: - File Sections

    private var fileSections: some View {
        VStack(spacing: 0) {
            ForEach(Array(summary.sections.enumerated()), id: \.offset) { _, section in
                if !section.files.isEmpty {
                    fileSection(title: section.title, icon: section.icon, color: colorForName(section.color), files: section.files)
                }
            }
        }
    }

    private func fileSection(title: String, icon: String, color: Color, files: [StoredFileInfo]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(files.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ForEach(files) { file in
                Button {
                    selectedFile = file
                    fileContent = storage.readFileContent(file.url)
                    showFileDetail = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: file.icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(color.opacity(0.7))
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("\(file.formattedSize) — \(file.formattedDate)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if file.id != files.last?.id {
                    Divider()
                        .padding(.leading, 50)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .padding(.top, 6)
    }

    // MARK: - Actions

    private func refreshSummary() {
        isLoading = true
        summary = storage.getStorageSummary()
        isLoading = false
    }

    private func saveNow() {
        isSaving = true
        storage.forceSave()
        refreshSummary()
        isSaving = false
    }

    private func createBackup() {
        if let url = storage.createBackup() {
            backupResult = "Backup created: \(url.lastPathComponent)"
            refreshSummary()
        } else {
            backupResult = "Backup failed"
        }
    }

    private func colorForName(_ name: String) -> Color {
        switch name {
        case "blue": .blue
        case "green": .green
        case "cyan": .cyan
        case "orange": .orange
        case "purple": .purple
        case "red": .red
        case "indigo": .indigo
        case "pink": .pink
        case "teal": .teal
        default: .gray
        }
    }
}

// MARK: - File Detail Sheet

struct FileDetailSheet: View {
    let file: StoredFileInfo
    let content: String?
    let onDelete: () -> Void
    let onShare: () -> Void

    @State private var showDeleteConfirm: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fileInfoHeader

                    if let content, !content.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("CONTENTS")
                                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    UIPasteboard.general.string = content
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                            }

                            Text(content.prefix(50000))
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.tertiarySystemGroupedBackground))
                                .clipShape(.rect(cornerRadius: 10))
                        }
                    } else if file.fileExtension == "jpg" || file.fileExtension == "jpeg" || file.fileExtension == "png" {
                        if let data = try? Data(contentsOf: file.url), let uiImage = UIImage(data: data) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .clipShape(.rect(cornerRadius: 10))
                        }
                    } else {
                        Text("Binary file — cannot preview")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            onShare()
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }

                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert("Delete File", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    onDelete()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Are you sure you want to delete \(file.name)?")
            }
        }
    }

    private var fileInfoHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.teal.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: file.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.teal)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(file.name)
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(2)
                    Text(file.formattedDate)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(file.formattedSize)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(.teal)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
