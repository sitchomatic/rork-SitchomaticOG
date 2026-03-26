import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct LoginNetworkSettingsView: View {
    @Bindable var vm: LoginViewModel
    @State private var showURLManager: Bool = false
    @State private var isValidatingURLs: Bool = false

    private var accentColor: Color {
        vm.isIgnitionMode ? .orange : .green
    }

    var body: some View {
        List {
            deviceNetworkLink
            urlRotationSection
            urlValidationSection
            endpointSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("URLs & Endpoint")
        .sheet(isPresented: $showURLManager) { urlManagerSheet }
    }

    // MARK: - Device Network Link

    private var deviceNetworkLink: some View {
        Section {
            NavigationLink {
                DeviceNetworkSettingsView()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "network.badge.shield.half.filled")
                            .font(.body)
                            .foregroundStyle(.blue)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Device Network Settings").font(.subheadline.bold())
                        Text("Proxy, VPN, WireGuard, DNS — applies to all modes")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ProxyRotationService.shared.unifiedConnectionMode.label)
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.blue.opacity(0.12)).clipShape(Capsule())
                }
            }
        } footer: {
            Text("Network configs are now device-wide. Changes apply to Joe, Ignition & PPSR.")
        }
    }

    // MARK: - URL Rotation

    private var urlRotationSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("URL Rotation").font(.body)
                    Text("\(vm.urlRotation.enabledURLs.count) of \(vm.urlRotation.activeURLs.count) URLs enabled").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(vm.isIgnitionMode ? "Ignition" : "Joe")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(accentColor.opacity(0.12)).clipShape(Capsule())
            }

            Button { showURLManager = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "list.bullet").foregroundStyle(accentColor)
                    Text("Manage URLs")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }

            Button {
                vm.urlRotation.enableAllURLs()
                vm.log("Re-enabled all URLs", level: .success)
            } label: {
                Label("Re-enable All URLs", systemImage: "arrow.counterclockwise")
            }
        } header: {
            Text("URL Rotation")
        } footer: {
            Text("Each test uses the next enabled URL in rotation. Failed URLs are auto-disabled after 2 consecutive failures.")
        }
    }

    // MARK: - URL Validation

    private var urlValidationSection: some View {
        Section {
            Button {
                guard !isValidatingURLs else { return }
                isValidatingURLs = true
                vm.log("Validating Joe Fortune URLs (static → www fallback)...")
                Task {
                    await vm.urlRotation.validateAndUpdateJoeURLs()
                    let enabled = vm.urlRotation.joeURLs.filter(\.isEnabled).count
                    vm.log("Joe URL validation complete: \(enabled)/\(vm.urlRotation.joeURLs.count) active", level: .success)
                    isValidatingURLs = false
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill").font(.title3).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Validate Joe URLs").font(.subheadline.bold())
                        Text("Prefer static.* subdomain, fallback to www.*").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isValidatingURLs {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(isValidatingURLs)
        } header: {
            Text("URL Validation")
        }
    }

    // MARK: - Endpoint

    private var endpointSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Target") {
                    HStack(spacing: 4) {
                        Circle().fill(endpointColor).frame(width: 6, height: 6)
                        Text(vm.connectionStatus == .connected ? "Live" : vm.connectionStatus.rawValue)
                            .font(.system(.body, design: .monospaced)).foregroundStyle(endpointColor)
                    }
                }
                LabeledContent("Site") { Text(vm.urlRotation.currentSiteName).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                LabeledContent("URLs") { Text("\(vm.urlRotation.enabledURLs.count) active").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                LabeledContent("Timeout") { Text("\(Int(vm.testTimeout))s per test").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
            }

            Button {
                Task { await vm.testConnection() }
            } label: {
                HStack {
                    if vm.connectionStatus == .connecting { ProgressView().controlSize(.small) }
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text(vm.connectionStatus == .connecting ? "Testing..." : "Test Connection")
                }
            }
            .disabled(vm.connectionStatus == .connecting)
        } header: {
            Text("Live Endpoint")
        }
    }

    private var endpointColor: Color {
        switch vm.connectionStatus {
        case .connected: .green; case .connecting: .orange; case .disconnected: .secondary; case .error: .red
        }
    }

    // MARK: - URL Manager Sheet

    @State private var urlViewingIgnition: Bool = false
    @State private var showURLImportBox: Bool = false
    @State private var urlImportText: String = ""

    private var urlManagerSheet: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 0) {
                        Button {
                            withAnimation(.spring(duration: 0.3)) { urlViewingIgnition = false }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "suit.spade.fill")
                                Text("Joe").font(.subheadline.bold())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(!urlViewingIgnition ? Color.green : Color(.tertiarySystemFill))
                            .foregroundStyle(!urlViewingIgnition ? .white : .secondary)
                        }
                        .clipShape(.rect(cornerRadii: .init(topLeading: 10, bottomLeading: 10)))

                        Button {
                            withAnimation(.spring(duration: 0.3)) { urlViewingIgnition = true }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "flame.fill")
                                Text("Ignition").font(.subheadline.bold())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(urlViewingIgnition ? Color.orange : Color(.tertiarySystemFill))
                            .foregroundStyle(urlViewingIgnition ? .white : .secondary)
                        }
                        .clipShape(.rect(cornerRadii: .init(bottomTrailing: 10, topTrailing: 10)))
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                if showURLImportBox {
                    Section("Import URLs") {
                        TextEditor(text: $urlImportText)
                            .font(.system(.callout, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(.rect(cornerRadius: 8))
                            .frame(minHeight: 100)
                            .overlay(alignment: .topLeading) {
                                if urlImportText.isEmpty {
                                    Text("One URL per line...\nhttps://domain.com/login")
                                        .font(.system(.callout, design: .monospaced))
                                        .foregroundStyle(.quaternary)
                                        .padding(.horizontal, 12).padding(.vertical, 16)
                                        .allowsHitTesting(false)
                                }
                            }

                        HStack {
                            Button {
                                if let clip = UIPasteboard.general.string { urlImportText = clip }
                            } label: {
                                Label("Paste", systemImage: "doc.on.clipboard").font(.caption)
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            Spacer()
                            Button {
                                let result = vm.urlRotation.bulkImportURLs(urlImportText, forIgnition: urlViewingIgnition)
                                vm.log("URL import: \(result.added) added, \(result.duplicates) dupes, \(result.invalid) invalid", level: result.added > 0 ? .success : .warning)
                                urlImportText = ""
                                if result.added > 0 {
                                    withAnimation(.snappy) { showURLImportBox = false }
                                }
                            } label: {
                                Label("Import", systemImage: "arrow.down.doc.fill").font(.caption.bold())
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(urlViewingIgnition ? .orange : .green)
                            .disabled(urlImportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }

                let urlList = urlViewingIgnition ? vm.urlRotation.ignitionURLs : vm.urlRotation.joeURLs
                Section {
                    ForEach(urlList) { urlEntry in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(urlEntry.isEnabled ? (urlViewingIgnition ? Color.orange : Color.green) : Color.red.opacity(0.5))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(urlEntry.host)
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundStyle(urlEntry.isEnabled ? .primary : .secondary)
                                    .strikethrough(!urlEntry.isEnabled)
                                HStack(spacing: 6) {
                                    if urlEntry.failCount > 0 {
                                        Text("\(urlEntry.failCount) fails").font(.caption2).foregroundStyle(.red)
                                    }
                                    if urlEntry.totalAttempts > 0 {
                                        Text(urlEntry.formattedSuccessRate).font(.caption2).foregroundStyle(.secondary)
                                        Text(urlEntry.formattedAvgResponse).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            Spacer()
                            Button {
                                vm.urlRotation.toggleURL(id: urlEntry.id, enabled: !urlEntry.isEnabled)
                            } label: {
                                Image(systemName: urlEntry.isEnabled ? "checkmark.circle.fill" : "xmark.circle")
                                    .foregroundStyle(urlEntry.isEnabled ? .green : .red.opacity(0.5))
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                vm.urlRotation.deleteURL(id: urlEntry.id)
                                vm.log("Deleted URL: \(urlEntry.host)")
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                } header: {
                    let enabled = urlList.filter(\.isEnabled).count
                    Text("\(urlViewingIgnition ? "Ignition" : "Joe") URLs (\(enabled)/\(urlList.count))")
                }

                Section {
                    Button {
                        withAnimation(.snappy) { showURLImportBox.toggle() }
                    } label: {
                        Label(showURLImportBox ? "Hide Import" : "Import URLs", systemImage: "plus.circle.fill")
                    }
                    Button {
                        vm.urlRotation.enableAllURLs()
                        vm.log("Re-enabled all URLs", level: .success)
                    } label: {
                        Label("Re-enable All", systemImage: "arrow.counterclockwise")
                    }
                    Button {
                        vm.urlRotation.resetPerformanceStats()
                        vm.log("Reset URL performance stats")
                    } label: {
                        Label("Reset Stats", systemImage: "chart.bar.xaxis")
                    }
                    Button {
                        vm.urlRotation.resetToDefaults(forIgnition: urlViewingIgnition)
                        vm.log("Reset \(urlViewingIgnition ? "Ignition" : "Joe") URLs to defaults", level: .success)
                    } label: {
                        Label("Reset to Defaults", systemImage: "arrow.uturn.backward")
                    }
                    if !urlList.isEmpty {
                        Button(role: .destructive) {
                            vm.urlRotation.deleteAllURLs(forIgnition: urlViewingIgnition)
                            vm.log("Deleted all \(urlViewingIgnition ? "Ignition" : "Joe") URLs")
                        } label: {
                            Label("Delete All \(urlViewingIgnition ? "Ignition" : "Joe") URLs", systemImage: "trash")
                        }
                    }
                } header: {
                    Text("Actions")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("URL Manager").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showURLManager = false } }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }
}
