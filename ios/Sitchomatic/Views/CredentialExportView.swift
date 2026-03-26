import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct CredentialExportView: View {
    let vm: LoginViewModel
    @State private var selectedFilter: LoginViewModel.CredentialExportFilter = .all
    @State private var exportFormat: ExportFormat = .text
    @State private var showCopiedToast: Bool = false
    @State private var showFileExporter: Bool = false
    @State private var exportDocument: CardExportDocument?

    nonisolated enum ExportFormat: String, CaseIterable, Sendable {
        case text = "Text (email:pass)"
        case csv = "CSV"
    }

    private var credCount: Int {
        switch selectedFilter {
        case .all: vm.credentials.count
        case .untested: vm.untestedCredentials.count
        case .working: vm.workingCredentials.count
        case .tempDisabled: vm.tempDisabledCredentials.count
        case .permDisabled: vm.permDisabledCredentials.count
        case .noAcc: vm.noAccCredentials.count
        case .unsure: vm.unsureCredentials.count
        }
    }

    var body: some View {
        List {
            Section("Filter") {
                Picker("Category", selection: $selectedFilter) {
                    ForEach(LoginViewModel.CredentialExportFilter.allCases, id: \.rawValue) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Text("Credentials")
                    Spacer()
                    Text("\(credCount)")
                        .font(.system(.body, design: .monospaced, weight: .bold))
                        .foregroundStyle(credCount > 0 ? .green : .secondary)
                }
            }

            Section("Format") {
                Picker("Format", selection: $exportFormat) {
                    ForEach(ExportFormat.allCases, id: \.rawValue) { fmt in
                        Text(fmt.rawValue).tag(fmt)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Button {
                    copyToClipboard()
                } label: {
                    HStack {
                        Spacer()
                        Label("Copy to Clipboard", systemImage: "doc.on.doc")
                            .font(.headline)
                        Spacer()
                    }
                }
                .disabled(credCount == 0)
                .listRowBackground(credCount > 0 ? Color.green : Color.green.opacity(0.3))
                .foregroundStyle(.white)

                Button {
                    exportToFile()
                } label: {
                    HStack {
                        Spacer()
                        Label("Export as File", systemImage: "square.and.arrow.up")
                            .font(.headline)
                        Spacer()
                    }
                }
                .disabled(credCount == 0)
                .listRowBackground(credCount > 0 ? Color.blue : Color.blue.opacity(0.3))
                .foregroundStyle(.white)
            }

            if credCount > 0 {
                Section("Preview (first 10)") {
                    let preview = exportFormat == .text
                        ? vm.exportCredentials(filter: selectedFilter)
                        : vm.exportCredentialsCSV(filter: selectedFilter)
                    let lines = preview.components(separatedBy: .newlines).prefix(10)
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Export Credentials")
        .overlay(alignment: .bottom) {
            if showCopiedToast {
                Text("Copied \(credCount) credentials")
                    .font(.subheadline.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(.green.gradient, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 20)
            }
        }
        .fileExporter(isPresented: $showFileExporter, document: exportDocument, contentType: exportFormat == .csv ? .commaSeparatedText : .plainText, defaultFilename: filename()) { result in
            switch result {
            case .success: vm.log("Exported \(credCount) credentials to file", level: .success)
            case .failure(let error): vm.log("Export failed: \(error.localizedDescription)", level: .error)
            }
        }
    }

    private func copyToClipboard() {
        let text = exportFormat == .text
            ? vm.exportCredentials(filter: selectedFilter)
            : vm.exportCredentialsCSV(filter: selectedFilter)
        UIPasteboard.general.string = text
        vm.log("Copied \(credCount) \(selectedFilter.rawValue.lowercased()) credentials to clipboard", level: .success)
        withAnimation(.spring(duration: 0.3)) { showCopiedToast = true }
        Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation { showCopiedToast = false } }
    }

    private func exportToFile() {
        let text = exportFormat == .text
            ? vm.exportCredentials(filter: selectedFilter)
            : vm.exportCredentialsCSV(filter: selectedFilter)
        exportDocument = CardExportDocument(text: text)
        showFileExporter = true
    }

    private func filename() -> String {
        let date = DateFormatters.fileStamp.string(from: Date())
        let ext = exportFormat == .csv ? "csv" : "txt"
        return "\(selectedFilter.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"))_creds_\(date).\(ext)"
    }
}
