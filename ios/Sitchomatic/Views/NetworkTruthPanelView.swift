import SwiftUI

struct NetworkTruthPanelView: View {
    @State private var truthService = NetworkTruthService.shared
    @State private var showHistory: Bool = false
    @State private var expanded: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if expanded {
                Divider()
                    .padding(.horizontal, 12)
                routeDetails
            }
        }
        .background(backgroundGradient)
        .clipShape(.rect(cornerRadius: 12))
        .onAppear { truthService.startMonitoring(interval: 5) }
        .onDisappear { truthService.stopMonitoring() }
        .sheet(isPresented: $showHistory) { historySheet }
    }

    private var headerRow: some View {
        Button {
            withAnimation(.spring(duration: 0.25)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(0.6), radius: 3)

                Image(systemName: routeIcon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(statusColor)

                Text("NETWORK TRUTH")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(statusColor)

                Spacer()

                if truthService.isProbing {
                    ProgressView()
                        .scaleEffect(0.6)
                }

                Text(truthService.currentSnapshot.routeType)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var routeDetails: some View {
        VStack(spacing: 6) {
            let snap = truthService.currentSnapshot

            truthRow(icon: "arrow.triangle.branch", label: "Routing", value: snap.ipRoutingMode, color: .cyan)
            truthRow(icon: "network", label: "Mode", value: snap.connectionMode, color: .blue)

            if let endpoint = snap.activeEndpoint {
                truthRow(icon: "point.3.connected.trianglepath.dotted", label: "Endpoint", value: endpoint, color: .purple)
            }

            if let host = snap.proxyHost {
                let portStr = snap.proxyPort.map { ":\($0)" } ?? ""
                truthRow(icon: "server.rack", label: "Proxy", value: "\(host)\(portStr)", color: .orange)
            }

            truthRow(icon: "tunnel.fill", label: "Tunnel", value: snap.tunnelActive ? "ACTIVE" : "None", color: snap.tunnelActive ? .green : .secondary)

            if snap.wireProxyActive || snap.wireProxyStatus != "Stopped" {
                truthRow(icon: "shield.lefthalf.filled", label: "WireProxy", value: snap.wireProxyStatus, color: snap.wireProxyActive ? .green : .yellow)
            }

            truthRow(icon: "externaldrive.connected.to.line.below", label: "Local Proxy", value: snap.localProxyRunning ? ":\(snap.localProxyPort)" : "Off", color: snap.localProxyRunning ? .mint : .secondary)

            truthRow(icon: "globe", label: "DNS", value: snap.dnsMode, color: .indigo)

            if let ip = snap.exitIP {
                truthRow(icon: "mappin.and.ellipse", label: "Exit IP", value: ip, color: .green)
            }

            HStack(spacing: 8) {
                Button {
                    truthService.refreshSnapshot()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.cyan)

                Button {
                    Task { await truthService.probeExitIP() }
                } label: {
                    Label("Probe IP", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.orange)
                .disabled(truthService.isProbing)

                Spacer()

                Button {
                    showHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.secondary)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func truthRow(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 14)
            Text(label)
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
        }
    }

    private var backgroundGradient: some ShapeStyle {
        Color(.secondarySystemGroupedBackground)
    }

    private var statusColor: Color {
        let snap = truthService.currentSnapshot
        if snap.tunnelActive { return .green }
        if snap.proxyHost != nil { return .cyan }
        if snap.wireProxyActive { return .green }
        return .orange
    }

    private var routeIcon: String {
        let snap = truthService.currentSnapshot
        if snap.tunnelActive { return "lock.shield.fill" }
        if snap.wireProxyActive { return "shield.lefthalf.filled" }
        if snap.proxyHost != nil { return "server.rack" }
        return "network"
    }

    private var historySheet: some View {
        NavigationStack {
            List {
                ForEach(truthService.snapshotHistory) { snap in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(snap.routeType)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                            Spacer()
                            Text(snap.timestamp, style: .time)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Text(snap.connectionMode)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.cyan)
                            if let host = snap.proxyHost {
                                Text("\(host)\(snap.proxyPort.map { ":\($0)" } ?? "")")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.orange)
                            }
                            if let ip = snap.exitIP {
                                Text(ip)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.green)
                            }
                        }
                        HStack(spacing: 8) {
                            if snap.tunnelActive {
                                Text("TUNNEL")
                                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                    .foregroundStyle(.green)
                            }
                            if snap.wireProxyActive {
                                Text("WIREPROXY")
                                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                    .foregroundStyle(.mint)
                            }
                            Text(snap.dnsMode)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Network History")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

struct NetworkTruthCompactView: View {
    @State private var truthService = NetworkTruthService.shared

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)

            Image(systemName: "network")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(statusColor)

            Text(truthService.currentSnapshot.routeType)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let host = truthService.currentSnapshot.proxyHost {
                Text(host)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if truthService.currentSnapshot.tunnelActive {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.green)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(statusColor.opacity(0.06))
        .onAppear { truthService.startMonitoring(interval: 8) }
        .onDisappear { truthService.stopMonitoring() }
    }

    private var statusColor: Color {
        let snap = truthService.currentSnapshot
        if snap.tunnelActive { return .green }
        if snap.proxyHost != nil { return .cyan }
        return .orange
    }
}
