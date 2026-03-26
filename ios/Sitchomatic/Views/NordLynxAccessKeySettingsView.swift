import SwiftUI

struct NordLynxAccessKeySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedKeyID: String = NordLynxConfigGeneratorService.selectedKeyID
    @State private var customKeyInput: String = ""
    @State private var customNameInput: String = ""
    @State private var showAddCustom: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var saved: Bool = false
    @State private var keyChangeBounce: Int = 0
    @State private var nordService = NordVPNService.shared

    private let tintColor = Color(red: 0.0, green: 0.78, blue: 1.0)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    activeKeyCard
                    tokenTestSection
                    keySelectionSection
                    if !showAddCustom {
                        addCustomKeyButton
                    }
                    if showAddCustom {
                        customKeyInputSection
                    }
                    infoSection
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .background(
                MeshGradient(
                    width: 3, height: 3,
                    points: [
                        [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                        [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                        [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                    ],
                    colors: [
                        .black, Color(red: 0.03, green: 0.05, blue: 0.15), .black,
                        Color(red: 0.0, green: 0.08, blue: 0.12), Color(red: 0.02, green: 0.06, blue: 0.18), Color(red: 0.0, green: 0.04, blue: 0.1),
                        .black, Color(red: 0.0, green: 0.06, blue: 0.1), .black
                    ]
                )
                .ignoresSafeArea()
            )
            .preferredColorScheme(.dark)
            .navigationTitle("Access Keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.secondary)
                }
            }
            .alert("Remove Custom Key?", isPresented: $showDeleteConfirmation) {
                Button("Remove", role: .destructive) {
                    removeCustomKey()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete your custom access key.")
            }
        }
    }

    private var activeKeyCard: some View {
        VStack(spacing: 12) {
            let hasValidPK = nordService.hasPrivateKey

            Image(systemName: hasValidPK ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(hasValidPK ? .green : .orange)
                .symbolEffect(.bounce, value: keyChangeBounce)

            let activeKey = NordLynxConfigGeneratorService.activeAccessKey
            Text("Active: \(activeKey.name)")
                .font(.headline)
                .foregroundStyle(.white)

            Text(maskedKey(activeKey.key))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if hasValidPK {
                Label("Private key obtained - WireGuard ready", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label("No private key - test your token below", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if saved {
                Label("Key switched successfully", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .animation(.spring(response: 0.4), value: saved)
    }

    private var tokenTestSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Token Verification", systemImage: "network.badge.shield.half.filled")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Button {
                Task { await nordService.testAccessToken() }
            } label: {
                HStack(spacing: 10) {
                    if nordService.isTestingToken {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.body.weight(.semibold))
                    }
                    Text(nordService.isTestingToken ? "Testing..." : "Test Token & Fetch Private Key")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(tintColor)
            .disabled(nordService.isTestingToken || !nordService.hasAccessKey)

            if let result = nordService.tokenTestResult {
                tokenResultView(result)
            }

            if nordService.isTokenExpired {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("Token Expired / Invalid")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                    }
                    Text("Your current token was rejected by NordVPN (401/403). You must generate a fresh token:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Link(destination: URL(string: "https://my.nordaccount.com/dashboard/nordvpn/manual-configuration/")!) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right.square")
                            Text("Open NordVPN Dashboard")
                                .fontWeight(.medium)
                        }
                        .font(.caption)
                        .foregroundStyle(tintColor)
                    }
                }
                .padding(12)
                .background(.red.opacity(0.08), in: .rect(cornerRadius: 10))
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
    }

    @ViewBuilder
    private func tokenResultView(_ result: NordVPNService.TokenTestResult) -> some View {
        switch result {
        case .success(let pkPrefix):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Token Valid!")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                    Text("Private key: \(pkPrefix)...")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(.green.opacity(0.08), in: .rect(cornerRadius: 10))

        case .expired:
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Token Expired (401)")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                    Text("Generate a new token from your NordVPN dashboard -> Manual Setup.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(.red.opacity(0.08), in: .rect(cornerRadius: 10))

        case .failed(let reason):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Test Failed")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(12)
            .background(.orange.opacity(0.08), in: .rect(cornerRadius: 10))
        }
    }

    private var keySelectionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Select Access Key", systemImage: "key.horizontal.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(NordLynxConfigGeneratorService.allAvailableKeys) { key in
                    keyRow(key)
                }
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
    }

    private func keyRow(_ key: NordLynxAccessKey) -> some View {
        let isSelected = selectedKeyID == key.id
        return Button {
            guard !isSelected else { return }
            withAnimation(.snappy(duration: 0.25)) {
                selectedKeyID = key.id
                NordLynxConfigGeneratorService.selectKey(key.id)
                keyChangeBounce += 1
            }
            showSavedFeedback()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isSelected ? tintColor : Color.white.opacity(0.08))
                        .frame(width: 36, height: 36)

                    if key.isPreset {
                        Text(String(key.name.prefix(1)).uppercased())
                            .font(.system(.subheadline, design: .default, weight: .bold))
                            .foregroundStyle(isSelected ? .black : .secondary)
                    } else {
                        Image(systemName: "key")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(isSelected ? .black : .secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(key.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)

                        if key.isPreset {
                            Text("PRESET")
                                .font(.system(.caption2, design: .default, weight: .bold))
                                .foregroundStyle(tintColor.opacity(0.8))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(tintColor.opacity(0.15), in: .capsule)
                        } else {
                            Text("CUSTOM")
                                .font(.system(.caption2, design: .default, weight: .bold))
                                .foregroundStyle(.orange.opacity(0.8))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.15), in: .capsule)
                        }
                    }

                    Text(maskedKey(key.key))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(tintColor)
                        .transition(.scale.combined(with: .opacity))
                }

                if !key.isPreset {
                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.red.opacity(0.7))
                            .padding(6)
                            .background(.red.opacity(0.1), in: .circle)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                isSelected ? tintColor.opacity(0.08) : Color.white.opacity(0.03),
                in: .rect(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? tintColor.opacity(0.3) : .clear, lineWidth: 1)
            )
        }
        .sensoryFeedback(.selection, trigger: selectedKeyID)
    }

    private var addCustomKeyButton: some View {
        Button {
            withAnimation(.spring(response: 0.4)) {
                showAddCustom = true
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(tintColor)
                Text("Add Custom Key")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        }
    }

    private var customKeyInputSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Add Custom Key", systemImage: "key.viewfinder")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        showAddCustom = false
                        customKeyInput = ""
                        customNameInput = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Key Name (e.g. Work, Personal)", text: $customNameInput)
                .font(.subheadline)
                .foregroundStyle(.white)
                .autocorrectionDisabled()
                .padding(12)
                .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 10))

            TextField("Paste your NordVPN access token...", text: $customKeyInput, axis: .vertical)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.white)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .lineLimit(3)
                .padding(12)
                .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 10))

            if !customKeyInput.isEmpty && !NordVPNService.isValidTokenFormat(customKeyInput) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text("Token looks invalid - NordVPN tokens are 64+ character alphanumeric strings")
                        .font(.caption2)
                }
                .foregroundStyle(.orange)
            }

            Button {
                saveCustomKey()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                    Text("Save & Activate")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(tintColor)
            .disabled(customKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("How NordVPN Authentication Works", systemImage: "info.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("You cannot use email/password directly.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Text("NordVPN requires an Access Token generated from their dashboard. This token is used to fetch your WireGuard private key via their API.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(.white.opacity(0.04), in: .rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 10) {
                Label("Steps to get your token", systemImage: "list.number")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)

                infoRow(number: "1", text: "Go to my.nordaccount.com and log in")
                infoRow(number: "2", text: "Navigate to NordVPN > Manual Setup")
                infoRow(number: "3", text: "Click \"Generate new token\"")
                infoRow(number: "4", text: "Copy the 64-char hex token")
                infoRow(number: "5", text: "Paste it here as a custom key")
                infoRow(number: "6", text: "Hit \"Test Token\" above to verify it works")
            }

            Link(destination: URL(string: "https://my.nordaccount.com/dashboard/nordvpn/manual-configuration/")!) {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                    Text("Open NordVPN Manual Setup")
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                }
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(tintColor.opacity(0.2), in: .rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(tintColor.opacity(0.3), lineWidth: 1)
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("What the token does:")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Token -> NordVPN API -> WireGuard Private Key -> Combined with server public keys -> Full WireGuard tunnel configs.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The API uses: Basic auth with token:YOUR_TOKEN -> returns nordlynx_private_key. Server IPs (not DNS hostnames) are used for WireGuard endpoints on port 51820.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(.white.opacity(0.04), in: .rect(cornerRadius: 10))
        }
        .padding(20)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
    }

    private func infoRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(tintColor)
                .frame(width: 20, height: 20)
                .background(tintColor.opacity(0.15), in: .circle)

            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 12 else { return String(repeating: "\u{2022}", count: key.count) }
        let prefix = key.prefix(6)
        let suffix = key.suffix(6)
        return "\(prefix)........\(suffix)"
    }

    private func saveCustomKey() {
        let name = customNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        NordLynxConfigGeneratorService.saveCustomKey(name: name.isEmpty ? "Custom" : name, key: customKeyInput)
        selectedKeyID = "custom"
        keyChangeBounce += 1
        showSavedFeedback()
        withAnimation(.spring(response: 0.3)) {
            showAddCustom = false
            customKeyInput = ""
            customNameInput = ""
        }
    }

    private func removeCustomKey() {
        NordLynxConfigGeneratorService.removeCustomKey()
        withAnimation(.snappy(duration: 0.25)) {
            selectedKeyID = NordLynxConfigGeneratorService.selectedKeyID
        }
        keyChangeBounce += 1
        showSavedFeedback()
    }

    private func showSavedFeedback() {
        withAnimation(.spring(response: 0.4)) {
            saved = true
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation {
                saved = false
            }
        }
    }
}
