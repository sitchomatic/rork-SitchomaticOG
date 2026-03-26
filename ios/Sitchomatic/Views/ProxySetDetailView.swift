import SwiftUI
import UniformTypeIdentifiers

struct ProxySetDetailView: View {
    @Bindable var vm: ProxyManagerViewModel
    let setId: UUID
    @State private var showBulkImport: Bool = false
    @State private var bulkText: String = ""
    @State private var importResult: String?
    @State private var showFileImporter: Bool = false
    @State private var editingName: Bool = false
    @State private var nameField: String = ""

    private var currentSet: ProxySet? {
        vm.proxySets.first { $0.id == setId }
    }

    var body: some View {
        Group {
            if let set = currentSet {
                List {
                    headerSection(set)
                    itemsSection(set)
                    importSection(set)
                    dangerSection(set)
                }
                .listStyle(.insetGrouped)
                .navigationTitle(set.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            nameField = set.name
                            editingName = true
                        } label: {
                            Image(systemName: "pencil.circle")
                                .foregroundStyle(.teal)
                        }
                    }
                }
                .alert("Rename Set", isPresented: $editingName) {
                    TextField("Name", text: $nameField)
                    Button("Save") {
                        let trimmed = nameField.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            vm.updateSetName(setId, name: trimmed)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .sheet(isPresented: $showBulkImport) {
                    bulkImportSheet(set)
                }
                .fileImporter(
                    isPresented: $showFileImporter,
                    allowedContentTypes: fileTypes(for: set.type),
                    allowsMultipleSelection: true
                ) { result in
                    handleFileImport(result, set: set)
                }
            } else {
                ContentUnavailableView("Set Not Found", systemImage: "exclamationmark.triangle")
            }
        }
    }

    private func headerSection(_ set: ProxySet) -> some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(typeColor(set.type).opacity(0.15))
                        .frame(width: 50, height: 50)
                    Image(systemName: set.typeIcon)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(typeColor(set.type))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(set.type.rawValue)
                        .font(.headline)
                    HStack(spacing: 8) {
                        Text("\(set.items.count)/10 servers")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if set.isActive {
                            Text("ACTIVE")
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15), in: Capsule())
                        } else {
                            Text("DISABLED")
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                        }
                    }
                }

                Spacer()

                if set.isFull {
                    Text("FULL")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }

            Toggle(isOn: Binding(
                get: { set.isActive },
                set: { _ in vm.toggleSetActive(set) }
            )) {
                Label("Set Active", systemImage: "power")
                    .font(.subheadline)
            }
            .tint(.green)
        }
    }

    private func itemsSection(_ set: ProxySet) -> some View {
        Section {
            if set.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No servers yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Import proxies or config files below")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ForEach(set.items) { item in
                    HStack(spacing: 10) {
                        Button {
                            vm.toggleItemEnabled(setId, itemId: item.id)
                        } label: {
                            Image(systemName: item.isEnabled ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18))
                                .foregroundStyle(item.isEnabled ? Color.green : Color.gray.opacity(0.4))
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label)
                                .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                                .lineLimit(1)
                            Text(item.displayString)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if !item.isEnabled {
                            Text("OFF")
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            vm.removeItemFromSet(setId, itemId: item.id)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            Label("Servers (\(set.items.count)/10)", systemImage: "server.rack")
        }
    }

    private func importSection(_ set: ProxySet) -> some View {
        Section {
            if !set.isFull {
                switch set.type {
                case .socks5:
                    Button {
                        bulkText = ""
                        importResult = nil
                        showBulkImport = true
                    } label: {
                        Label("Bulk Import SOCKS5", systemImage: "doc.text")
                            .foregroundStyle(.blue)
                    }

                case .wireGuard:
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Import .conf Files", systemImage: "doc.badge.plus")
                            .foregroundStyle(.cyan)
                    }

                    Button {
                        bulkText = ""
                        importResult = nil
                        showBulkImport = true
                    } label: {
                        Label("Paste WireGuard Config", systemImage: "doc.on.clipboard")
                            .foregroundStyle(.cyan)
                    }

                case .openVPN:
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Import .ovpn Files", systemImage: "doc.badge.plus")
                            .foregroundStyle(.orange)
                    }

                    Button {
                        bulkText = ""
                        importResult = nil
                        showBulkImport = true
                    } label: {
                        Label("Paste OpenVPN Config", systemImage: "doc.on.clipboard")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let result = importResult {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.teal)
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Label("Import", systemImage: "square.and.arrow.down")
        } footer: {
            if set.isFull {
                Text("This set is full (10/10). Remove items to import more.")
            }
        }
    }

    private func dangerSection(_ set: ProxySet) -> some View {
        Section {
            Button(role: .destructive) {
                vm.deleteSet(set)
            } label: {
                Label("Delete Entire Set", systemImage: "trash.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private func bulkImportSheet(_ set: ProxySet) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $bulkText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal)

                if let result = importResult {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(result)
                            .font(.caption)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemGroupedBackground))
                }
            }
            .navigationTitle("Bulk Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showBulkImport = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        performBulkImport(set)
                    }
                    .disabled(bulkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationContentInteraction(.scrolls)
    }

    private func performBulkImport(_ set: ProxySet) {
        let text = bulkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        switch set.type {
        case .socks5:
            let result = vm.importSOCKS5Bulk(text, toSetId: setId)
            importResult = "Added \(result.added), skipped \(result.failed)"

        case .wireGuard:
            let count = vm.importWireGuardFile(text, fileName: "pasted_config.conf", toSetId: setId)
            importResult = "Imported \(count) WireGuard config(s)"

        case .openVPN:
            let success = vm.importOpenVPNFile(text, fileName: "pasted_config.ovpn", toSetId: setId)
            importResult = success ? "Imported 1 OpenVPN config" : "Failed to parse OpenVPN config"
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>, set: ProxySet) {
        guard case .success(let urls) = result else {
            importResult = "File import failed"
            return
        }

        var totalImported = 0
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }

            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let fileName = url.lastPathComponent

            switch set.type {
            case .wireGuard:
                totalImported += vm.importWireGuardFile(content, fileName: fileName, toSetId: setId)
            case .openVPN:
                if vm.importOpenVPNFile(content, fileName: fileName, toSetId: setId) {
                    totalImported += 1
                }
            case .socks5:
                break
            }
        }
        importResult = "Imported \(totalImported) config(s) from \(urls.count) file(s)"
    }

    private func fileTypes(for type: ProxySetType) -> [UTType] {
        switch type {
        case .socks5: [.plainText]
        case .wireGuard: [.plainText, UTType(filenameExtension: "conf") ?? .data]
        case .openVPN: [.plainText, UTType(filenameExtension: "ovpn") ?? .data]
        }
    }

    private func typeColor(_ type: ProxySetType) -> Color {
        switch type {
        case .socks5: .blue
        case .wireGuard: .cyan
        case .openVPN: .orange
        }
    }
}
