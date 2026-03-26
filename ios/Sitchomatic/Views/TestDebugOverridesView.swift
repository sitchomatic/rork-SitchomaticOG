import SwiftUI

struct TestDebugOverridesView: View {
    @Binding var overrides: TestDebugVariationOverrides
    @Environment(\.dismiss) private var dismiss

    @State private var pinNetwork: Bool = false
    @State private var selectedNetwork: ConnectionMode = .wireguard
    @State private var pinPattern: Bool = false
    @State private var selectedPattern: String = "TRUE DETECTION"
    @State private var pinStealth: Bool = false
    @State private var stealthOn: Bool = true
    @State private var pinHumanSim: Bool = false
    @State private var humanSimOn: Bool = true
    @State private var pinFingerprint: Bool = false
    @State private var fingerprintOn: Bool = true
    @State private var pinTrueDetection: Bool = false
    @State private var trueDetectionOn: Bool = true
    @State private var pinIsolation: Bool = false
    @State private var selectedIsolation: AutomationSettings.SessionIsolationMode = .full

    private let patterns = [
        "TRUE DETECTION", "Tab Navigation", "Click-Focus Sequential",
        "Calibrated Typing", "Calibrated Direct", "Form Submit Direct"
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    infoCard

                    overrideToggle(
                        "Network Mode", icon: "network", isPinned: $pinNetwork
                    ) {
                        Picker("Network", selection: $selectedNetwork) {
                            ForEach(ConnectionMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    overrideToggle(
                        "Pattern", icon: "list.bullet.rectangle", isPinned: $pinPattern
                    ) {
                        Picker("Pattern", selection: $selectedPattern) {
                            ForEach(patterns, id: \.self) { pat in
                                Text(pat).tag(pat)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    overrideToggle(
                        "TRUE DETECTION", icon: "target", isPinned: $pinTrueDetection
                    ) {
                        Toggle("Enabled", isOn: $trueDetectionOn)
                            .tint(.purple)
                    }

                    overrideToggle(
                        "Stealth JS", icon: "eye.slash.fill", isPinned: $pinStealth
                    ) {
                        Toggle("Enabled", isOn: $stealthOn)
                            .tint(.purple)
                    }

                    overrideToggle(
                        "Human Simulation", icon: "figure.walk", isPinned: $pinHumanSim
                    ) {
                        Toggle("Enabled", isOn: $humanSimOn)
                            .tint(.purple)
                    }

                    overrideToggle(
                        "Fingerprint Spoofing", icon: "hand.raised.fill", isPinned: $pinFingerprint
                    ) {
                        Toggle("Enabled", isOn: $fingerprintOn)
                            .tint(.purple)
                    }

                    overrideToggle(
                        "Session Isolation", icon: "lock.shield.fill", isPinned: $pinIsolation
                    ) {
                        Picker("Isolation", selection: $selectedIsolation) {
                            ForEach(AutomationSettings.SessionIsolationMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Pin Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear All") {
                        overrides = TestDebugVariationOverrides()
                        dismiss()
                    }
                    .font(.subheadline)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") {
                        applyOverrides()
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .onAppear { loadFromOverrides() }
        }
    }

    private var infoCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "pin.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.purple)
            Text("Pin specific settings to keep them fixed while everything else varies.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.08))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func overrideToggle<Content: View>(
        _ title: String, icon: String, isPinned: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isPinned.wrappedValue ? .purple : .secondary)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                Spacer()
                Toggle("", isOn: isPinned)
                    .labelsHidden()
                    .tint(.purple)
            }

            if isPinned.wrappedValue {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
        .animation(.spring(duration: 0.3), value: isPinned.wrappedValue)
    }

    private func loadFromOverrides() {
        if let net = overrides.pinConnectionMode {
            pinNetwork = true
            selectedNetwork = net
        }
        if let pat = overrides.pinPattern {
            pinPattern = true
            selectedPattern = pat
        }
        if let s = overrides.pinStealth {
            pinStealth = true
            stealthOn = s
        }
        if let h = overrides.pinHumanSim {
            pinHumanSim = true
            humanSimOn = h
        }
        if let f = overrides.pinFingerprint {
            pinFingerprint = true
            fingerprintOn = f
        }
        if let t = overrides.pinTrueDetection {
            pinTrueDetection = true
            trueDetectionOn = t
        }
        if let iso = overrides.pinSessionIsolation {
            pinIsolation = true
            selectedIsolation = iso
        }
    }

    private func applyOverrides() {
        overrides.pinConnectionMode = pinNetwork ? selectedNetwork : nil
        overrides.pinPattern = pinPattern ? selectedPattern : nil
        overrides.pinStealth = pinStealth ? stealthOn : nil
        overrides.pinHumanSim = pinHumanSim ? humanSimOn : nil
        overrides.pinFingerprint = pinFingerprint ? fingerprintOn : nil
        overrides.pinTrueDetection = pinTrueDetection ? trueDetectionOn : nil
        overrides.pinSessionIsolation = pinIsolation ? selectedIsolation : nil
    }
}
