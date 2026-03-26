import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ConsolidatedImportExportView: View {
    @State private var showExportSheet: Bool = false
    @State private var showImportSheet: Bool = false
    @State private var showImportFilePicker: Bool = false
    @State private var showFileExporter: Bool = false
    @State private var exportedJSON: String = ""
    @State private var importConfigText: String = ""
    @State private var importResult: AppDataExportService.ImportResult?
    @State private var showImportFileImporter: Bool = false
    @State private var exportDocument: CardExportDocument?
    @State private var showCopiedToast: Bool = false
    @State private var dataSummary: (credentials: Int, cards: Int, urls: Int, proxies: Int, vpns: Int, wgs: Int, dns: Int, blacklist: Int, emails: Int, flows: Int, buttonConfigs: Int)?
    @State private var nordService = NordVPNService.shared
    @State private var proxyService = ProxyRotationService.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            List {
                summarySection
                exportSection
                importSection
            }
            .listStyle(.insetGrouped)

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
        .navigationTitle("Import / Export")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshSummary() }
        .onChange(of: nordService.activeKeyProfile) { _, _ in refreshSummary() }
        .onChange(of: proxyService.joeWGConfigs.count) { _, _ in refreshSummary() }
        .onChange(of: proxyService.joeVPNConfigs.count) { _, _ in refreshSummary() }
        .sheet(isPresented: $showExportSheet) { exportConfigSheet }
        .sheet(isPresented: $showImportSheet) { importConfigSheet }
        .fileExporter(isPresented: $showFileExporter, document: exportDocument, contentType: .plainText, defaultFilename: "full_backup_\(dateStamp()).txt") { result in
            switch result {
            case .success: showToast()
            case .failure: break
            }
        }
        .fileImporter(isPresented: $showImportFilePicker, allowedContentTypes: [.json, .plainText], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
                    importConfigText = text
                    importResult = nil
                    showImportSheet = true
                }
            case .failure: break
            }
        }
    }

    private func refreshSummary() {
        dataSummary = AppDataExportService.shared.exportDataSummary()
    }

    private var currentProfileCounts: ProfileStorageCounts {
        proxyService.storageCounts(for: nordService.activeKeyProfile)
    }

    private var allProfileCounts: ProfileStorageCounts {
        proxyService.allProfileStorageCounts()
    }

    private var profileTint: Color {
        nordService.activeKeyProfile == .nick ? .blue : .purple
    }

    // MARK: - Summary

    private var summarySection: some View {
        Section {
            if let s = dataSummary {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Label("Current Profile", systemImage: "person.crop.circle.fill")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(nordService.activeKeyProfile.rawValue)
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(profileTint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(profileTint.opacity(0.14))
                            .clipShape(Capsule())
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        storageSummaryCell("Current WireGuard", count: currentProfileCounts.wireGuard, icon: "network.badge.shield.half.filled", color: .teal)
                        storageSummaryCell("Current VPN", count: currentProfileCounts.openVPN, icon: "lock.shield.fill", color: .indigo)
                        storageSummaryCell("All Profiles WG", count: allProfileCounts.wireGuard, icon: "person.2.fill", color: .cyan)
                        storageSummaryCell("All Profiles VPN", count: allProfileCounts.openVPN, icon: "externaldrive.fill", color: .orange)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        summaryCell("Credentials", count: s.credentials, icon: "person.fill", color: .green)
                        summaryCell("Cards", count: s.cards, icon: "creditcard.fill", color: .orange)
                        summaryCell("URLs", count: s.urls, icon: "link", color: .blue)
                        summaryCell("Proxies", count: s.proxies, icon: "shield.fill", color: .purple)
                        summaryCell("VPNs", count: s.vpns, icon: "lock.shield.fill", color: .indigo)
                        summaryCell("WireGuard", count: s.wgs, icon: "network.badge.shield.half.filled", color: .teal)
                        summaryCell("DNS", count: s.dns, icon: "globe", color: .cyan)
                        summaryCell("Blacklist", count: s.blacklist, icon: "hand.raised.slash.fill", color: .red)
                        summaryCell("Emails", count: s.emails, icon: "envelope.fill", color: .mint)
                        summaryCell("Flows", count: s.flows, icon: "record.circle", color: .pink)
                        summaryCell("Btn Configs", count: s.buttonConfigs, icon: "target", color: .orange)
                    }
                }
                .padding(.vertical, 4)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        } header: {
            Label("Data Overview", systemImage: "chart.bar.fill")
        } footer: {
            Text("The profile badge and current VPN/WireGuard counts reflect the selected Nick or Poli profile. Hard storage totals include both profiles. All of the above plus automation settings, app preferences, sort order, and crop regions are included in every export.")
        }
    }

    private func storageSummaryCell(_ label: String, count: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count)")
                    .font(.system(.headline, design: .monospaced, weight: .bold))
                    .foregroundStyle(.primary)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.08))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func summaryCell(_ label: String, count: Int, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(color)
            Text("\(count)")
                .font(.system(.title3, design: .monospaced, weight: .bold))
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    // MARK: - Export

    private var exportSection: some View {
        Section {
            Button {
                exportedJSON = AppDataExportService.shared.exportJSON()
                showExportSheet = true
            } label: {
                exportRow(icon: "eye.fill", title: "Preview & Copy JSON", subtitle: "View full backup, copy to clipboard", color: .blue)
            }

            Button {
                let json = AppDataExportService.shared.exportJSON()
                exportDocument = CardExportDocument(text: json)
                showFileExporter = true
            } label: {
                exportRow(icon: "square.and.arrow.up.fill", title: "Export to File", subtitle: "Save comprehensive .json backup", color: .teal)
            }

            Button {
                let json = AppDataExportService.shared.exportJSON()
                UIPasteboard.general.string = json
                showToast()
            } label: {
                exportRow(icon: "doc.on.doc.fill", title: "Quick Copy to Clipboard", subtitle: "Copy full JSON backup instantly", color: .indigo)
            }
        } header: {
            Label("Export", systemImage: "square.and.arrow.up")
        } footer: {
            Text("Exports everything: credentials, cards, URLs, proxies, VPN/WG configs, DNS servers, blacklist, email rotation list, recorded flows, debug button configs, automation settings, app settings, sort order, and crop regions.")
        }
    }

    // MARK: - Import

    private var importSection: some View {
        Section {
            Button {
                importConfigText = ""
                importResult = nil
                showImportSheet = true
            } label: {
                exportRow(icon: "square.and.arrow.down.fill", title: "Import from Paste / Text", subtitle: "Paste exported JSON to restore", color: .green)
            }

            Button {
                showImportFilePicker = true
            } label: {
                exportRow(icon: "folder.badge.plus", title: "Import from File", subtitle: "Load a .json config file", color: .orange)
            }
        } header: {
            Label("Import", systemImage: "square.and.arrow.down")
        } footer: {
            Text("Import merges data without overwriting — duplicates are excluded automatically. Supports both v1.0 and v2.0 export formats.")
        }
    }

    private func exportRow(icon: String, title: String, subtitle: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3).foregroundStyle(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Export Sheet

    private var exportConfigSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = exportedJSON
                        showToast()
                    } label: {
                        Label("Copy to Clipboard", systemImage: "doc.on.doc.fill")
                            .font(.subheadline.bold())
                    }
                    .buttonStyle(.borderedProminent).tint(.blue)

                    Spacer()

                    let byteCount = exportedJSON.utf8.count
                    Text(byteCount > 1024 ? "\(byteCount / 1024)KB" : "\(byteCount)B")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                ScrollView {
                    Text(exportedJSON)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(.rect(cornerRadius: 10))
                }
                .padding(.horizontal)
            }
            .padding(.top)
            .navigationTitle("Export Preview").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showExportSheet = false } }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    // MARK: - Import Sheet

    private var importConfigSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    Button {
                        if let clip = UIPasteboard.general.string { importConfigText = clip }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard").font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.small)

                    Button { showImportFileImporter = true } label: {
                        Label("Load File", systemImage: "folder").font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.small)

                    Spacer()

                    let byteCount = importConfigText.utf8.count
                    if byteCount > 0 {
                        Text(byteCount > 1024 ? "\(byteCount / 1024)KB" : "\(byteCount)B")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)

                TextEditor(text: $importConfigText)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden).padding(10)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 10)).frame(minHeight: 180)
                    .overlay(alignment: .topLeading) {
                        if importConfigText.isEmpty {
                            Text("Paste exported JSON config here...")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.quaternary)
                                .padding(.horizontal, 14).padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal)

                if let result = importResult {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(result.summary)
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(.green)
                        if !result.errors.isEmpty {
                            ForEach(result.errors, id: \.self) { error in
                                Text(error)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Import Config").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showImportSheet = false; importConfigText = ""; importResult = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        let result = AppDataExportService.shared.importJSON(importConfigText)
                        importResult = result
                        if result.errors.isEmpty {
                            refreshSummary()
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                showImportSheet = false
                                importConfigText = ""
                                importResult = nil
                            }
                        }
                    }
                    .disabled(importConfigText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fileImporter(isPresented: $showImportFileImporter, allowedContentTypes: [.json, .plainText], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    guard url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
                        importConfigText = text
                    }
                case .failure: break
                }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    // MARK: - Helpers

    private func showToast() {
        withAnimation(.spring(duration: 0.3)) { showCopiedToast = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { showCopiedToast = false }
        }
    }

    private func dateStamp() -> String {
        DateFormatters.fileStamp.string(from: Date())
    }
}
