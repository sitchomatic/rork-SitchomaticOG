import SwiftUI
import UIKit

struct BlacklistView: View {
    let vm: LoginViewModel
    @State private var showImportSheet: Bool = false
    @State private var importText: String = ""
    @State private var searchText: String = ""
    @State private var showCopiedToast: Bool = false

    private var filteredEntries: [BlacklistEntry] {
        if searchText.isEmpty { return vm.blacklistService.blacklistedEmails }
        return vm.blacklistService.blacklistedEmails.filter {
            $0.email.localizedStandardContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if vm.blacklistService.blacklistedEmails.isEmpty {
                ContentUnavailableView("No Blacklisted Accounts", systemImage: "hand.raised.slash.fill", description: Text("Blacklisted emails/credentials will be excluded from import and testing queues."))
            } else {
                statusBar
                entryList
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Blacklist")
        .searchable(text: $searchText, prompt: "Search blacklist...")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showImportSheet = true } label: {
                        Label("Import Emails", systemImage: "doc.on.clipboard.fill")
                    }
                    if !vm.blacklistService.blacklistedEmails.isEmpty {
                        Button { copyBlacklist() } label: {
                            Label("Copy All", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) { vm.blacklistService.clearBlacklist() } label: {
                            Label("Clear Blacklist", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showImportSheet) { importSheet }
        .overlay(alignment: .bottom) {
            if showCopiedToast {
                Text("Copied to clipboard")
                    .font(.subheadline.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(.green.gradient, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 20)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.slash.fill").foregroundStyle(.red)
            Text("\(vm.blacklistService.blacklistedEmails.count) blacklisted").font(.subheadline.bold())
            Spacer()
            Toggle("Auto-Exclude", isOn: Bindable(vm.blacklistService).autoExcludeBlacklist)
                .labelsHidden()
                .tint(.red)
        }
        .padding(.horizontal).padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var entryList: some View {
        List {
            Section {
                Toggle(isOn: Bindable(vm.blacklistService).autoExcludeBlacklist) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-Exclude Blacklist").font(.subheadline.bold())
                        Text("Skip blacklisted accounts during import").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .tint(.red)

                Toggle(isOn: Bindable(vm.blacklistService).autoBlacklistNoAcc) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-Blacklist No Account").font(.subheadline.bold())
                        Text("Add credentials found to be no-acc to blacklist").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .tint(.orange)
            }

            Section("Blacklisted Emails (\(filteredEntries.count))") {
                ForEach(filteredEntries) { entry in
                    HStack(spacing: 12) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.email)
                                .font(.system(.subheadline, design: .monospaced, weight: .medium))
                                .lineLimit(1)
                            HStack(spacing: 8) {
                                if !entry.reason.isEmpty {
                                    Text(entry.reason).font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(entry.formattedDate).font(.caption2).foregroundStyle(.quaternary)
                            }
                        }
                        Spacer()
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            vm.blacklistService.removeFromBlacklist(entry)
                        } label: { Label("Remove", systemImage: "trash") }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func copyBlacklist() {
        UIPasteboard.general.string = vm.blacklistService.exportBlacklist()
        withAnimation(.spring(duration: 0.3)) { showCopiedToast = true }
        Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation { showCopiedToast = false } }
    }

    private var importSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Import to Blacklist").font(.headline)
                    Text("Paste emails, one per line. These will be excluded from future imports and queues.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TextEditor(text: $importText)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden).padding(10)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 10)).frame(minHeight: 200)
                    .overlay(alignment: .topLeading) {
                        if importText.isEmpty {
                            Text("user@email.com\nanother@email.com")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.quaternary)
                                .padding(.horizontal, 14).padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }

                HStack {
                    let lineCount = importText.components(separatedBy: .newlines)
                        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
                    if lineCount > 0 {
                        Text("\(lineCount) email\(lineCount == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        if let clipboard = UIPasteboard.general.string, !clipboard.isEmpty {
                            importText = clipboard
                        }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard").font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered).tint(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Import Blacklist").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showImportSheet = false; importText = "" }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        vm.blacklistService.importBlacklist(importText, reason: "Manual import")
                        vm.log("Imported emails to blacklist", level: .success)
                        showImportSheet = false
                        importText = ""
                    }
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }
}
