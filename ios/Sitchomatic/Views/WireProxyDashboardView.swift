import SwiftUI

struct WireProxyDashboardView: View {
    private let bridge = WireProxyBridge.shared
    private let localProxy = LocalProxyServer.shared
    private let deviceProxy = DeviceProxyService.shared
    @State private var refreshTick: Int = 0
    @State private var refreshTimer: Timer?

    var body: some View {
        List {
            tunnelOverviewSection
            wgSessionSection
            bridgeStatsSection
            tcpSessionsSection
            localProxyIntegrationSection
            actionsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("WireGuard Tunnel")
        .onAppear {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in refreshTick += 1 }
            }
        }
        .onDisappear { refreshTimer?.invalidate() }
    }

    private var tunnelOverviewSection: some View {
        Section {
            let _ = refreshTick
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(tunnelColor.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: tunnelIcon)
                        .font(.title3.bold())
                        .foregroundStyle(tunnelColor)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(tunnelTitle)
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text(bridge.status.rawValue)
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(tunnelColor)
                        if bridge.isActive {
                            Text("TUNNEL")
                                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.green)
                                .clipShape(Capsule())
                        }
                    }
                }
                Spacer()
                if bridge.isActive {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(bridge.uptimeString)
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(.green)
                        Text("uptime")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if let error = bridge.lastError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }
            }

            if bridge.isActive {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ], spacing: 12) {
                    statCard(value: formatBytes(bridge.stats.bytesUpstream), label: "Upstream", color: .blue, icon: "arrow.up")
                    statCard(value: formatBytes(bridge.stats.bytesDownstream), label: "Downstream", color: .green, icon: "arrow.down")
                    statCard(value: "\(bridge.stats.connectionsServed)", label: "Served", color: .cyan, icon: "link")
                }
                .padding(.vertical, 4)

                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ], spacing: 12) {
                    statCard(value: "\(bridge.stats.tcpSessionsActive)", label: "TCP Active", color: .purple, icon: "point.3.connected.trianglepath.dotted")
                    statCard(value: "\(bridge.stats.tcpSessionsCreated)", label: "TCP Total", color: .indigo, icon: "number")
                    statCard(value: "\(bridge.stats.connectionsFailed)", label: "Failed", color: bridge.stats.connectionsFailed > 0 ? .red : .secondary, icon: "xmark.circle")
                }
                .padding(.vertical, 4)
            }
        } header: {
            HStack {
                Image(systemName: "lock.shield.fill")
                Text("WireGuard Tunnel")
                Spacer()
                Text(bridge.status.rawValue.uppercased())
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(tunnelColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(tunnelColor.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
    }

    private var wgSessionSection: some View {
        Section {
            let _ = refreshTick
            let sessionStatus = bridge.wgSessionStatus
            let sessionStats = bridge.wgSessionStats

            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(wgStatusColor(sessionStatus).opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(wgStatusColor(sessionStatus))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("WireGuard Session")
                        .font(.subheadline.bold())
                    Text(sessionStatus.rawValue)
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(wgStatusColor(sessionStatus))
                }
                Spacer()
                if sessionStats.handshakeCount > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(sessionStats.handshakeCount)")
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(.purple)
                        Text("handshakes")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Packets Sent")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(sessionStats.packetsSent)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(.blue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Packets Recv")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(sessionStats.packetsReceived)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bytes Sent")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(formatBytes(sessionStats.bytesSent))
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bytes Recv")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(formatBytes(sessionStats.bytesReceived))
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                }
            }

            if let lastHandshake = sessionStats.lastHandshakeTime {
                HStack(spacing: 8) {
                    Image(systemName: "hand.wave.fill")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                    Text("Last handshake: \(lastHandshake.formatted(.relative(presentation: .numeric)))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 16) {
                if let lastSent = sessionStats.lastPacketSentTime {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last Sent")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(lastSent, style: .time)
                            .font(.system(.caption2, design: .monospaced))
                    }
                }
                if let lastRecv = sessionStats.lastPacketReceivedTime {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last Recv")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(lastRecv, style: .time)
                            .font(.system(.caption2, design: .monospaced))
                    }
                }
                Spacer()
            }
        } header: {
            HStack {
                Image(systemName: "lock.fill")
                Text("WireGuard Session")
            }
        }
    }

    private var bridgeStatsSection: some View {
        Section {
            let _ = refreshTick

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("DNS Queries")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(bridge.stats.dnsQueriesTotal)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(.cyan)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("DNS Cache Hits")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(bridge.stats.dnsCacheHits)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cache Size")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(bridge.dnsCacheSize)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                }
                Spacer()
                if bridge.stats.dnsQueriesTotal > 0 {
                    let hitRate = bridge.stats.dnsCacheHits > 0 ? Double(bridge.stats.dnsCacheHits) / Double(bridge.stats.dnsQueriesTotal) * 100 : 0
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Hit Rate")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.0f%%", hitRate))
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(hitRate > 50 ? .green : .orange)
                    }
                }
            }
        } header: {
            HStack {
                Image(systemName: "globe")
                Text("DNS & Bridge Stats")
            }
        }
    }

    @ViewBuilder
    private var tcpSessionsSection: some View {
        let _ = refreshTick
        Section {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Active Sessions")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(bridge.stats.tcpSessionsActive)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(.purple)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Created Total")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(bridge.stats.tcpSessionsCreated)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connections")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(bridge.stats.connectionsServed)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(.cyan)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Failed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(bridge.stats.connectionsFailed)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(bridge.stats.connectionsFailed > 0 ? .red : .primary)
                }
            }

            if bridge.stats.connectionsServed > 0 {
                let successRate = bridge.stats.connectionsFailed < bridge.stats.connectionsServed
                    ? Double(bridge.stats.connectionsServed - bridge.stats.connectionsFailed) / Double(bridge.stats.connectionsServed) * 100
                    : 0
                HStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.caption2)
                        .foregroundStyle(successRate > 80 ? .green : .orange)
                    Text("Success Rate: \(String(format: "%.1f%%", successRate))")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(successRate > 80 ? .green : .orange)
                    Spacer()
                }
            }
        } header: {
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                Text("TCP Session Manager")
            }
        }
    }

    private var localProxyIntegrationSection: some View {
        Section {
            let _ = refreshTick
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(localProxy.wireProxyMode ? Color.green.opacity(0.15) : Color.gray.opacity(0.1))
                        .frame(width: 36, height: 36)
                    Image(systemName: "server.rack")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(localProxy.wireProxyMode ? .green : .secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local Proxy Routing")
                        .font(.subheadline.bold())
                    Text(localProxy.wireProxyMode ? "All traffic → WireProxy tunnel" : "Standard upstream routing")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(localProxy.wireProxyMode ? "TUNNEL" : "STANDARD")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(localProxy.wireProxyMode ? .green : .secondary)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background((localProxy.wireProxyMode ? Color.green : Color.gray).opacity(0.1))
                    .clipShape(Capsule())
            }

            if localProxy.isRunning {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Listening")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("127.0.0.1:\(localProxy.listeningPort)")
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(.cyan)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Active")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(localProxy.stats.activeConnections)")
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Total")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(localProxy.stats.totalConnections)")
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                    }
                    Spacer()
                    Text(formatBytes(localProxy.stats.bytesRelayed))
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.green)
                }
            }
        } header: {
            HStack {
                Image(systemName: "arrow.triangle.branch")
                Text("Local Proxy Integration")
            }
        }
    }

    private var actionsSection: some View {
        Section {
            if bridge.isActive {
                Button(role: .destructive) {
                    deviceProxy.stopWireProxy()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.circle.fill")
                            .foregroundStyle(.red)
                        Text("Stop WireGuard Tunnel")
                            .font(.subheadline.bold())
                        Spacer()
                    }
                }

                Button {
                    deviceProxy.reconnectWireProxy()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundStyle(.orange)
                        Text("Reconnect Tunnel")
                            .font(.subheadline.bold())
                        Spacer()
                    }
                }
            } else {
                Button {
                    deviceProxy.reconnectWireProxy()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.circle.fill")
                            .foregroundStyle(.green)
                        Text("Start WireGuard Tunnel")
                            .font(.subheadline.bold())
                        Spacer()
                    }
                }
            }
        } header: {
            HStack {
                Image(systemName: "gearshape")
                Text("Actions")
            }
        } footer: {
            Text("Routes all SOCKS5 traffic through an encrypted WireGuard tunnel. No NetworkExtension or VPN profile required.")
        }
    }

    private func statCard(value: String, label: String, color: Color, icon: String) -> some View {
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

    private var tunnelColor: Color {
        switch bridge.status {
        case .established: .green
        case .connecting, .reconnecting: .orange
        case .stopped: .secondary
        case .failed: .red
        }
    }

    private var tunnelIcon: String {
        switch bridge.status {
        case .established: "shield.checkered"
        case .connecting: "hourglass"
        case .reconnecting: "arrow.clockwise"
        case .stopped: "shield.slash"
        case .failed: "exclamationmark.shield"
        }
    }

    private var tunnelTitle: String {
        switch bridge.status {
        case .established: "Tunnel Active"
        case .connecting: "Connecting..."
        case .reconnecting: "Reconnecting..."
        case .stopped: "Tunnel Stopped"
        case .failed: "Tunnel Failed"
        }
    }

    private func wgStatusColor(_ status: WGSessionStatus) -> Color {
        switch status {
        case .established: .green
        case .handshaking, .rekeying: .orange
        case .idle: .secondary
        case .failed: .red
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
    }
}
