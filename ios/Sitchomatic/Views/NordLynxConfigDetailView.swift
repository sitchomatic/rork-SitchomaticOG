import SwiftUI
import UIKit

struct NordLynxConfigDetailView: View {
    let config: NordLynxGeneratedConfig
    @Environment(\.dismiss) private var dismiss
    @State private var copied: Bool = false

    private var flagEmoji: String {
        guard config.countryCode.count == 2 else { return "🌐" }
        let base: UInt32 = 127397
        return config.countryCode.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(base + $0.value)
        }.map { String($0) }.joined()
    }

    private var loadColor: Color {
        switch config.serverLoad {
        case 0..<30: .green
        case 30..<60: .yellow
        case 60..<80: .orange
        default: .red
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    serverHeader
                    metadataGrid
                    configPreview
                    actionButtons
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(config.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    private var serverHeader: some View {
        HStack(spacing: 14) {
            Text(flagEmoji)
                .font(.system(size: 40))

            VStack(alignment: .leading, spacing: 4) {
                Text(config.hostname)
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(.primary)

                HStack(spacing: 8) {
                    if !config.countryName.isEmpty && config.countryName != "Unknown" {
                        Text(config.countryName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !config.cityName.isEmpty {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.quaternary)
                        Text(config.cityName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private var metadataGrid: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                infoTile(title: "Protocol", value: config.vpnProtocol.shortName, icon: config.vpnProtocol.icon, tintColor: config.vpnProtocol.isOpenVPN ? .orange : .cyan)
                infoTile(title: "Port", value: "\(config.port)", icon: "network")
            }
            HStack(spacing: 10) {
                infoTile(title: "Endpoint", value: config.stationIP, icon: "globe")
                infoTile(title: "Load", value: "\(config.serverLoad)%", icon: "gauge.with.dots.needle.33percent", tintColor: loadColor)
            }
        }
    }

    private func infoTile(title: String, value: String, icon: String, tintColor: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(.footnote, design: .monospaced, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))
    }

    private var configPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Configuration File", systemImage: "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(config.fileContent)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))
                .textSelection(.enabled)
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                UIPasteboard.general.string = config.fileContent
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied!" : "Copy Config", systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.bordered)
            .tint(copied ? .green : .cyan)
            .sensoryFeedback(.success, trigger: copied)

            if let url = configFileURL {
                ShareLink(item: url) {
                    Label("Share Config File", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
            }
        }
    }

    private var configFileURL: URL? {
        let folderURL = URL.documentsDirectory.appending(path: "NordLynx_Configs")
        let fileURL = folderURL.appending(path: config.fileName)
        return FileManager.default.fileExists(atPath: fileURL.path()) ? fileURL : nil
    }
}
