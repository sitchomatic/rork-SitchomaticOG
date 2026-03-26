import SwiftUI

struct ProxyStatusDashboardView: View {
    private let localProxy = LocalProxyServer.shared
    private let healthMonitor = ProxyHealthMonitor.shared
    private let connectionPool = ProxyConnectionPool.shared
    private let deviceProxy = DeviceProxyService.shared
    @State private var refreshTick: Int = 0
    @State private var refreshTimer: Timer?

    var body: some View {
        List {
            serverOverviewSection
            healthMonitorSection
            connectionPoolSection
            activeConnectionsSection
            errorBreakdownSection
            healthLogSection
            recentHostsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Proxy Dashboard")
        .onAppear {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in refreshTick += 1 }
            }
        }
        .onDisappear { refreshTimer?.invalidate() }
    }

    private var serverOverviewSection: some View {
        Section {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(localProxy.isRunning ? Color.green.opacity(0.15) : Color.red.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: localProxy.isRunning ? "server.rack" : "xmark.circle")
                        .font(.title3.bold())
                        .foregroundStyle(localProxy.isRunning ? .green : .red)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(localProxy.isRunning ? "Wireproxy Active" : "Wireproxy Stopped")
                        .font(.headline)
                    if localProxy.isRunning {
                        Text("127.0.0.1:\(localProxy.listeningPort)")
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(.cyan)
                    }
                }
                Spacer()
                if localProxy.isRunning {
                    let _ = refreshTick
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(localProxy.uptimeString)
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(.green)
                        Text("uptime")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if localProxy.isRunning {
                let _ = refreshTick
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ], spacing: 12) {
                    statCard(value: "\(localProxy.stats.activeConnections)", label: "Active", color: .cyan, icon: "link")
                    statCard(value: "\(localProxy.stats.totalConnections)", label: "Total", color: .blue, icon: "number")
                    statCard(value: "\(localProxy.stats.peakActiveConnections)", label: "Peak", color: .purple, icon: "chart.bar.fill")
                }
                .padding(.vertical, 4)

                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ], spacing: 12) {
                    statCard(value: formatBytes(localProxy.stats.bytesRelayed), label: "Relayed", color: .green, icon: "arrow.up.arrow.down")
                    statCard(value: localProxy.throughputLabel, label: "Avg Rate", color: .orange, icon: "speedometer")
                    statCard(value: String(format: "%.0f%%", localProxy.errorRate), label: "Error Rate", color: localProxy.errorRate > 10 ? .red : .secondary, icon: "exclamationmark.triangle")
                }
                .padding(.vertical, 4)

                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.arrow.down.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Upstream")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(localProxy.upstreamLabel)
                            .font(.system(.caption, design: .monospaced, weight: .medium))
                            .lineLimit(1)
                    }
                    Spacer()
                    if localProxy.stats.averageConnectionDurationMs > 0 {
                        Text(String(format: "%.0fms avg", localProxy.stats.averageConnectionDurationMs))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            HStack {
                Image(systemName: "server.rack")
                Text("Local Proxy Server")
                Spacer()
                if localProxy.isRunning {
                    Text("RUNNING")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        }
    }

    private var healthMonitorSection: some View {
        Section {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(healthStatusColor.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: healthStatusIcon)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(healthStatusColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Upstream Health")
                        .font(.subheadline.bold())
                    Text(healthMonitor.healthSummary)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if healthMonitor.isMonitoring {
                    let _ = refreshTick
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(healthMonitor.upstreamHealth.isHealthy ? "HEALTHY" : "UNHEALTHY")
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(healthMonitor.upstreamHealth.isHealthy ? .green : .red)
                        if let latency = healthMonitor.upstreamHealth.latencyMs {
                            Text("\(latency)ms")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background((healthMonitor.upstreamHealth.isHealthy ? Color.green : Color.red).opacity(0.08))
                    .clipShape(.rect(cornerRadius: 6))
                }
            }

            if healthMonitor.isMonitoring {
                let _ = refreshTick
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Checks")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(healthMonitor.upstreamHealth.totalChecks)")
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Failures")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(healthMonitor.upstreamHealth.totalFailures)")
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(healthMonitor.upstreamHealth.totalFailures > 0 ? .orange : .primary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Success Rate")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f%%", healthMonitor.successRate))
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(healthMonitor.successRate > 90 ? .green : (healthMonitor.successRate > 50 ? .orange : .red))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Avg Latency")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(healthMonitor.averageLatencyMs.map { "\($0)ms" } ?? "--")
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                    }
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Consecutive Fails")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(healthMonitor.upstreamHealth.consecutiveFailures)/\(healthMonitor.maxConsecutiveFailures)")
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(healthMonitor.upstreamHealth.consecutiveFailures > 0 ? .orange : .green)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Failovers")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(deviceProxy.failoverCount)")
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(deviceProxy.failoverCount > 0 ? .red : .primary)
                    }
                    Spacer()
                    if let lastChecked = healthMonitor.upstreamHealth.lastChecked {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Last Check")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(lastChecked, style: .time)
                                .font(.system(.caption2, design: .monospaced))
                        }
                    }
                }

                Button {
                    Task { await healthMonitor.forceCheck() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "heart.text.square")
                            .font(.caption)
                        Text("Force Health Check")
                            .font(.caption.bold())
                    }
                }
            }

            Toggle(isOn: Binding(
                get: { deviceProxy.autoFailoverEnabled },
                set: { deviceProxy.autoFailoverEnabled = $0 }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Auto-Failover")
                            .font(.subheadline)
                        Text("Auto-rotate when upstream dies")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.orange)
        } header: {
            HStack {
                Image(systemName: "heart.text.square")
                Text("Health Monitor")
                Spacer()
                if healthMonitor.isMonitoring {
                    Text("ACTIVE")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        }
    }

    private var connectionPoolSection: some View {
        Section {
            let _ = refreshTick
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pool Size")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(connectionPool.pooledConnections.count)/\(connectionPool.maxPoolSize)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Active")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(connectionPool.activeCount)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(.cyan)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Idle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(connectionPool.idleCount)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Utilization")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f%%", connectionPool.poolUtilization))
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                }
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hits")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(connectionPool.totalPoolHits)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Misses")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(connectionPool.totalPoolMisses)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hit Rate")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f%%", connectionPool.hitRate))
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(connectionPool.hitRate > 50 ? .green : .orange)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Evictions")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(connectionPool.totalEvictions)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                }
            }

            Button(role: .destructive) {
                connectionPool.drainPool()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.caption)
                    Text("Drain Pool")
                        .font(.caption.bold())
                }
            }
        } header: {
            HStack {
                Image(systemName: "square.stack.3d.up")
                Text("Connection Pool")
            }
        }
    }

    @ViewBuilder
    private var activeConnectionsSection: some View {
        let _ = refreshTick
        let activeConns = Array(localProxy.activeConnectionDetails.values).sorted { $0.connectedAt > $1.connectedAt }

        if !activeConns.isEmpty {
            Section {
                ForEach(activeConns) { conn in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(conn.state == .relaying ? .green : .orange)
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(conn.targetHost):\(conn.targetPort)")
                                .font(.system(.caption, design: .monospaced, weight: .medium))
                                .lineLimit(1)
                            HStack(spacing: 8) {
                                Text(conn.state.rawValue)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(conn.state == .relaying ? .green : .orange)
                                Text(conn.connectedAt, style: .relative)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Text(formatBytes(conn.bytesRelayed))
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(.cyan)
                    }
                }
            } header: {
                HStack {
                    Image(systemName: "link")
                    Text("Active Connections (\(activeConns.count))")
                }
            }
        }
    }

    private var errorBreakdownSection: some View {
        Section {
            let _ = refreshTick
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connection")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(localProxy.stats.connectionErrors)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(localProxy.stats.connectionErrors > 0 ? .red : .primary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Handshake")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(localProxy.stats.handshakeErrors)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(localProxy.stats.handshakeErrors > 0 ? .orange : .primary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Relay")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(localProxy.stats.relayErrors)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(localProxy.stats.relayErrors > 0 ? .yellow : .primary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Total Errors")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(localProxy.stats.upstreamErrors)")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(localProxy.stats.upstreamErrors > 0 ? .red : .green)
                }
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uploaded")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.blue)
                        Text(formatBytes(localProxy.stats.bytesUploaded))
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloaded")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.green)
                        Text(formatBytes(localProxy.stats.bytesDownloaded))
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                    }
                }
                Spacer()
            }
        } header: {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                Text("Error Breakdown & Bandwidth")
            }
        }
    }

    @ViewBuilder
    private var healthLogSection: some View {
        if !healthMonitor.healthLog.isEmpty {
            Section {
                let logItems = Array(healthMonitor.healthLog.prefix(10))
                ForEach(logItems, id: \.id) { event in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(event.isHealthy ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.detail)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(event.isHealthy ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))
                                .lineLimit(1)
                            Text(event.timestamp, style: .time)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if let latency = event.latencyMs {
                            Text("\(latency)ms")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                HStack {
                    Image(systemName: "list.bullet.rectangle")
                    Text("Health Log")
                }
            }
        }
    }

    @ViewBuilder
    private var recentHostsSection: some View {
        if !localProxy.recentCompletedHosts.isEmpty {
            Section {
                ForEach(Array(localProxy.recentCompletedHosts.prefix(10).enumerated()), id: \.offset) { _, host in
                    Text(host)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } header: {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Recent Hosts")
                }
            }
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

    private var healthStatusColor: Color {
        if !healthMonitor.isMonitoring { return .secondary }
        return healthMonitor.upstreamHealth.isHealthy ? .green : .red
    }

    private var healthStatusIcon: String {
        if !healthMonitor.isMonitoring { return "heart.slash" }
        return healthMonitor.upstreamHealth.isHealthy ? "heart.fill" : "heart.slash.fill"
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
    }
}
