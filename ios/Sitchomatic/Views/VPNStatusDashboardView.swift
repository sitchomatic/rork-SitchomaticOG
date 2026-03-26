import SwiftUI

struct VPNStatusDashboardView: View {
    private let vpnTunnel = VPNTunnelManager.shared
    private let wgService = WireGuardTunnelService.shared
    private let deviceProxy = DeviceProxyService.shared
    @State private var refreshTick: Int = 0
    @State private var refreshTimer: Timer?

    var body: some View {
        List {
            tunnelStatusSection
            connectionStatsSection
            endpointTestSection
            connectionHistorySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("VPN Dashboard")
        .onAppear {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in refreshTick += 1 }
            }
        }
        .onDisappear { refreshTimer?.invalidate() }
    }

    private var tunnelStatusSection: some View {
        Section {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(tunnelStatusColor.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: tunnelStatusIcon)
                        .font(.title3.bold())
                        .foregroundStyle(tunnelStatusColor)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(vpnTunnel.statusDetail)
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text(vpnTunnel.status.rawValue)
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(tunnelStatusColor)
                        if vpnTunnel.isReconnecting {
                            Text("RECONNECTING")
                                .font(.system(.caption2, design: .monospaced, weight: .bold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                }
                Spacer()
                if vpnTunnel.isConnected {
                    let _ = refreshTick
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(vpnTunnel.uptimeString)
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(.green)
                        Text("uptime")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if vpnTunnel.isConnected {
                if let configName = vpnTunnel.activeConfigName {
                    HStack(spacing: 10) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Active Config")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(configName)
                                .font(.system(.caption, design: .monospaced, weight: .medium))
                                .lineLimit(1)
                        }
                        Spacer()
                        if let config = vpnTunnel.activeConfig {
                            Text("\(config.endpointHost):\(config.endpointPort)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.green)
                            Text("In")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(vpnTunnel.dataInLabel)
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.blue)
                            Text("Out")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(vpnTunnel.dataOutLabel)
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                    }
                    Spacer()
                }

                HStack(spacing: 12) {
                    Button {
                        vpnTunnel.disconnect(reason: "Manual disconnect")
                    } label: {
                        Label("Disconnect", systemImage: "stop.circle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                    }
                    Button {
                        Task { await vpnTunnel.removeConfiguration() }
                    } label: {
                        Label("Remove Config", systemImage: "trash")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error = vpnTunnel.lastError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }
            }

            if !vpnTunnel.isSupported {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                    Text("VPN tunnel requires a real device. Install via Rork App to use.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Image(systemName: "lock.shield.fill")
                Text("VPN Tunnel")
                Spacer()
                Text(vpnTunnel.status.rawValue.uppercased())
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(tunnelStatusColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(tunnelStatusColor.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
    }

    private var connectionStatsSection: some View {
        Section {
            let _ = refreshTick
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
            ], spacing: 12) {
                vpnStatCard(value: "\(vpnTunnel.connectionStats.totalConnections)", label: "Connections", color: .blue, icon: "link")
                vpnStatCard(value: "\(vpnTunnel.connectionStats.totalReconnects)", label: "Reconnects", color: .orange, icon: "arrow.clockwise")
                vpnStatCard(value: "\(vpnTunnel.connectionStats.totalErrors)", label: "Errors", color: .red, icon: "xmark.circle")
            }
            .padding(.vertical, 4)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
            ], spacing: 12) {
                vpnStatCard(value: "\(vpnTunnel.connectionStats.totalRotations)", label: "Rotations", color: .purple, icon: "arrow.triangle.2.circlepath")
                vpnStatCard(value: formatDuration(vpnTunnel.connectionStats.longestSessionSeconds), label: "Longest", color: .green, icon: "timer")
                vpnStatCard(value: "\(vpnTunnel.connectionStats.totalDisconnections)", label: "Disconnects", color: .secondary, icon: "xmark")
            }
            .padding(.vertical, 4)

            HStack(spacing: 16) {
                Toggle(isOn: Binding(
                    get: { vpnTunnel.autoReconnect },
                    set: { vpnTunnel.autoReconnect = $0 }
                )) {
                    Text("Auto-Reconnect")
                        .font(.subheadline)
                }
                .tint(.blue)
            }

            Toggle(isOn: Binding(
                get: { vpnTunnel.onDemandEnabled },
                set: { vpnTunnel.onDemandEnabled = $0 }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: "wifi")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Connect On Demand")
                            .font(.subheadline)
                        Text("Auto-connect on WiFi & Cellular")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.blue)
        } header: {
            HStack {
                Image(systemName: "chart.bar.fill")
                Text("Connection Statistics")
            }
        }
    }

    private var endpointTestSection: some View {
        Section {
            Button {
                let proxyService = ProxyRotationService.shared
                let configs = proxyService.wgConfigs(for: .joe).filter { $0.isEnabled }
                Task { await wgService.testAllEndpoints(configs) }
            } label: {
                HStack(spacing: 8) {
                    if wgService.isTestingEndpoints {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "network.badge.shield.half.filled")
                            .foregroundStyle(.blue)
                    }
                    Text("Test All WireGuard Endpoints")
                        .font(.subheadline.bold())
                    Spacer()
                    if !wgService.endpointResults.isEmpty {
                        Text("\(wgService.reachableCount)/\(wgService.endpointResults.count)")
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(wgService.reachableCount > 0 ? .green : .red)
                    }
                }
            }
            .disabled(wgService.isTestingEndpoints)

            if !wgService.endpointResults.isEmpty {
                if let best = wgService.bestEndpoint {
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                        Text("Best: \(best.config)")
                            .font(.system(.caption, design: .monospaced, weight: .medium))
                        Spacer()
                        Text("\(best.latencyMs)ms")
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(.green)
                    }
                }

                ForEach(wgService.endpointResults, id: \.config) { result in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(result.reachable ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                        Text(result.config)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        if result.reachable {
                            Text("\(result.latencyMs)ms")
                                .font(.system(.caption2, design: .monospaced, weight: .bold))
                                .foregroundStyle(.green)
                        } else {
                            Text("FAIL")
                                .font(.system(.caption2, design: .monospaced, weight: .bold))
                                .foregroundStyle(.red)
                        }
                        Text(":\(result.port)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                Button {
                    let proxyService = ProxyRotationService.shared
                    let configs = proxyService.wgConfigs(for: .joe).filter { $0.isEnabled }
                    Task { await wgService.connectBestEndpoint(configs) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(.blue)
                        Text("Connect to Best Endpoint")
                            .font(.caption.bold())
                    }
                }
            }
        } header: {
            HStack {
                Image(systemName: "globe")
                Text("Endpoint Testing")
            }
        }
    }

    @ViewBuilder
    private var connectionHistorySection: some View {
        let events = vpnTunnel.connectionStats.connectionHistory
        if !events.isEmpty {
            Section {
                ForEach(events.prefix(15), id: \.id) { event in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(eventColor(event.eventType))
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(event.eventType.rawValue)
                                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                                    .foregroundStyle(eventColor(event.eventType))
                                Text(event.configName)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                            }
                            Text(event.detail)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(event.timestamp, style: .time)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                HStack {
                    Image(systemName: "list.bullet.rectangle")
                    Text("Connection History (\(events.count))")
                }
            }
        }
    }

    private func vpnStatCard(value: String, label: String, color: Color, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color.opacity(0.7))
            Text(value)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(color.opacity(0.06))
        .clipShape(.rect(cornerRadius: 8))
    }

    private var tunnelStatusColor: Color {
        switch vpnTunnel.status {
        case .connected: .green
        case .connecting, .reasserting, .configuring: .orange
        case .disconnected, .disconnecting: .secondary
        case .error, .invalid: .red
        }
    }

    private var tunnelStatusIcon: String {
        switch vpnTunnel.status {
        case .connected: "lock.shield.fill"
        case .connecting, .configuring: "hourglass"
        case .disconnected: "lock.open"
        case .disconnecting: "xmark.shield"
        case .reasserting: "arrow.clockwise"
        case .error, .invalid: "exclamationmark.shield"
        }
    }

    private func eventColor(_ type: VPNConnectionEvent.EventType) -> Color {
        switch type {
        case .connected: .green
        case .disconnected: .secondary
        case .error: .red
        case .reconnect: .orange
        case .rotation: .purple
        case .failover: .red
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "--" }
        let hrs = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        if hrs > 0 { return "\(hrs)h\(mins)m" }
        return "\(mins)m"
    }
}
