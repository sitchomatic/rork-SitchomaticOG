import SwiftUI

struct AutomationToolsMenuView: View {
    let vm: LoginViewModel

    private var accentColor: Color {
        vm.isIgnitionMode ? .orange : .green
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    FlowRecorderView()
                } label: {
                    toolRow(
                        icon: "record.circle",
                        title: "Record Login Flow",
                        subtitle: "Record & replay human login patterns",
                        color: .red
                    )
                }

                NavigationLink {
                    SavedFlowsView(vm: FlowRecorderViewModel())
                } label: {
                    let flowCount = FlowPersistenceService.shared.loadFlows().count
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.indigo.opacity(0.12))
                                .frame(width: 40, height: 40)
                            Image(systemName: "tray.full.fill")
                                .font(.body)
                                .foregroundStyle(.indigo)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Saved Flows").font(.subheadline.bold())
                            Text("\(flowCount) recorded login patterns").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Label("Flow Recording", systemImage: "waveform.path")
            } footer: {
                Text("Record human login interactions and replay them for automation calibration.")
            }

            Section {
                NavigationLink {
                    DebugLoginButtonView(vm: vm)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.red.opacity(0.12))
                                .frame(width: 40, height: 40)
                            Image(systemName: "target")
                                .font(.body)
                                .foregroundStyle(.red)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Login Button Detection").font(.subheadline.bold())
                            Text("\(DebugLoginButtonService.shared.configs.count) saved configs")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if DebugLoginButtonService.shared.configs.values.contains(where: { $0.userConfirmed }) {
                            Text("ACTIVE")
                                .font(.system(.caption2, design: .monospaced, weight: .heavy))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.green.opacity(0.12)).clipShape(Capsule())
                        }
                    }
                }
            } header: {
                Label("Button Detection", systemImage: "hand.tap.fill")
            } footer: {
                Text("Debug and calibrate login button detection for specific sites.")
            }

            Section {
                NavigationLink {
                    AutomationSettingsView(vm: vm)
                } label: {
                    toolRow(
                        icon: "slider.horizontal.3",
                        title: "Full Automation Config",
                        subtitle: "Every facet of automation flow control",
                        color: .teal
                    )
                }
            } header: {
                Label("Advanced Configuration", systemImage: "gearshape.2.fill")
            } footer: {
                Text("URL calibration, TRUE DETECTION protocol, pattern strategies, and all automation parameters.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Automation Tools")
    }

    private func toolRow(icon: String, title: String, subtitle: String, color: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
