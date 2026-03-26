import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DeviceNetworkSettingsView: View {
    @State private var showDNSManager: Bool = false
    @State private var showProxyImport: Bool = false
    @State private var proxyBulkText: String = ""
    @State private var proxyImportReport: ProxyRotationService.ImportReport?
    @State private var isTestingProxies: Bool = false

    private let proxyService = ProxyRotationService.shared
    private let deviceProxy = DeviceProxyService.shared
    private let localProxy = LocalProxyServer.shared
    private let healthMonitor = ProxyHealthMonitor.shared
    private let wireProxyBridge = WireProxyBridge.shared
    private let logger = DebugLogger.shared
    @State private var rotationTimerTick: Int = 0
    @State private var rotationTickTimer: Timer?

    var body: some View {
        List {
            deviceWideBanner
            ipRoutingSection
            if deviceProxy.isEnabled {
                unitedIPOptionsSection
            }
            proxyManagerLinkSection
            if isTunnelRelevantMode {
                tunnelServerSection
            }
            if LoginURLRotationService.shared.isIgnitionMode {
                ignitionRegionSection
            }
            endpointConfigSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Network Settings")
        .onAppear {
            rotationTickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in rotationTimerTick += 1 }
            }
        }
        .onDisappear { rotationTickTimer?.invalidate() }
        .sheet(isPresented: $showDNSManager) { dnsManagerSheet }
        .sheet(isPresented: $showProxyImport) { proxyImportSheet }
    }

    private func log(_ message: String, level: DebugLogLevel = .info) {
        logger.log(message, category: .network, level: level)
    }

    // MARK: - Device Wide Banner

    private var deviceWideBanner: some View {
        Section {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Device-Wide Network")
                        .font(.subheadline.bold())
                    Text("Applies to Joe Fortune, Ignition & PPSR")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(proxyService.unifiedConnectionMode.label)
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(modeColor)
                    Text(proxyService.networkRegion.rawValue)
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(proxyService.networkRegion == .usa ? .blue : .orange)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(modeColor.opacity(0.08))
                .clipShape(.rect(cornerRadius: 8))
            }
        } footer: {
            Text("All network configurations are shared across every mode in this app. Changing settings here affects Joe Fortune, Ignition, and PPSR simultaneously.")
        }
    }

    // MARK: - IP Routing Mode

    private var ipRoutingSection: some View {
        Section {
            Picker("IP Routing", selection: Binding(
                get: { deviceProxy.ipRoutingMode },
                set: { deviceProxy.ipRoutingMode = $0 }
            )) {
                ForEach(IPRoutingMode.allCases, id: \.self) { mode in
                    Text(mode.shortLabel).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("IP Routing")
            .sensoryFeedback(.impact(weight: .heavy), trigger: deviceProxy.ipRoutingMode)

            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(deviceProxy.isEnabled ? Color.cyan.opacity(0.15) : Color.gray.opacity(0.1))
                        .frame(width: 36, height: 36)
                    Image(systemName: deviceProxy.ipRoutingMode.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(deviceProxy.isEnabled ? .cyan : .secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(deviceProxy.ipRoutingMode.label)
                        .font(.subheadline.bold())
                    Text(deviceProxy.isEnabled ? "One shared IP for the whole app with scheduled rotation." : "Each web session gets its own IP from the \(proxyService.unifiedConnectionMode.label) pool.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 2)

            if deviceProxy.isEnabled && deviceProxy.isActive {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(deviceProxy.isRotating ? .yellow : .green)
                            .frame(width: 8, height: 8)
                        Text(deviceProxy.isRotating ? "Rotating..." : "Active")
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(deviceProxy.isRotating ? .yellow : .green)
                        Spacer()
                        Text(deviceProxy.activeConnectionType)
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(.cyan)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.cyan.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    if let label = deviceProxy.activeEndpointLabel {
                        HStack(spacing: 6) {
                            Image(systemName: "globe")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.cyan.opacity(0.7))
                            Text(label)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                    }

                    HStack(spacing: 12) {
                        if let since = deviceProxy.activeSince {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .font(.system(size: 9, weight: .bold))
                                Text("Connected \(since.formatted(.relative(presentation: .numeric)))")
                                    .font(.system(.caption2, design: .monospaced))
                            }
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if deviceProxy.rotationInterval != .everyBatch {
                            let _ = rotationTimerTick
                            HStack(spacing: 4) {
                                Image(systemName: "timer")
                                    .font(.system(size: 9, weight: .bold))
                                Text("Next: \(deviceProxy.rotationCountdownLabel)")
                                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                            }
                            .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            HStack {
                Image(systemName: deviceProxy.ipRoutingMode.icon)
                Text("IP Routing")
                Spacer()
                Text(deviceProxy.ipRoutingMode.shortLabel)
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(deviceProxy.isEnabled ? .cyan : .secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((deviceProxy.isEnabled ? Color.cyan : Color.gray).opacity(0.12))
                    .clipShape(Capsule())
            }
        } footer: {
            if deviceProxy.isEnabled {
                Text("App-Wide United IP: the entire app shares one IP that auto-rotates on a schedule.")
            } else {
                Text("Separate IP per Session: each web session gets its own IP from the config pool.")
            }
        }
    }

    // MARK: - United IP Options (only when app-wide mode)

    private var unitedIPOptionsSection: some View {
        Section {
            Picker(selection: Binding(
                get: { deviceProxy.rotationInterval },
                set: { deviceProxy.rotationInterval = $0 }
            )) {
                ForEach(RotationInterval.allCases, id: \.self) { interval in
                    Label(interval.label, systemImage: interval.icon).tag(interval)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.cyan)
                    Text("Rotation Interval")
                }
            }
            .pickerStyle(.menu)
            .sensoryFeedback(.impact(weight: .medium), trigger: deviceProxy.rotationInterval)

            Toggle(isOn: Binding(
                get: { deviceProxy.rotateOnBatchStart },
                set: { deviceProxy.rotateOnBatchStart = $0 }
            )) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise.circle")
                        .foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Rotate on Batch Start")
                            .font(.subheadline)
                        Text("New IP each batch/auto cycle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.cyan)

            Toggle(isOn: Binding(
                get: { deviceProxy.rotateOnFingerprintDetection },
                set: { deviceProxy.rotateOnFingerprintDetection = $0 }
            )) {
                HStack(spacing: 10) {
                    Image(systemName: "fingerprint")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Rotate on Fingerprint")
                            .font(.subheadline)
                        Text("Auto-rotate when IP fingerprinting detected")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.cyan)

            Toggle(isOn: Binding(
                get: { deviceProxy.autoFailoverEnabled },
                set: { deviceProxy.autoFailoverEnabled = $0 }
            )) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Auto-Failover")
                            .font(.subheadline)
                        Text("Rotate when upstream dies")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.orange)

            Button {
                deviceProxy.rotateNow(reason: "Manual")
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.cyan)
                    Text("Rotate Now")
                        .font(.subheadline.bold())
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .sensoryFeedback(.impact(weight: .heavy), trigger: deviceProxy.rotationLog.count)

            if !deviceProxy.rotationLog.isEmpty {
                DisclosureGroup {
                    ForEach(deviceProxy.rotationLog) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(entry.reason)
                                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                                    .foregroundStyle(.cyan)
                                Spacer()
                                Text(entry.timestamp, style: .time)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            HStack(spacing: 4) {
                                Text(entry.fromLabel)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.tertiary)
                                Text(entry.toLabel)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.primary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle")
                            .foregroundStyle(.cyan)
                        Text("Rotation Log (\(deviceProxy.rotationLog.count))")
                            .font(.subheadline)
                    }
                }
            }
        } header: {
            HStack {
                Image(systemName: "shield.checkered")
                Text("United IP Rotation")
                Spacer()
                if deviceProxy.isActive {
                    Text("ACTIVE")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.cyan.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        } footer: {
            Text("Controls for the app-wide united IP rotation schedule, batch triggers, and failover.")
        }
    }

    // MARK: - Tunnel Server (WireGuard / OpenVPN)

    private var tunnelServerSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { deviceProxy.localProxyEnabled },
                set: { deviceProxy.localProxyEnabled = $0 }
            )) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(localProxy.isRunning ? Color.green.opacity(0.15) : Color.gray.opacity(0.1))
                            .frame(width: 36, height: 36)
                        Image(systemName: "server.rack")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(localProxy.isRunning ? .green : .secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("WireProxy Server")
                            .font(.subheadline.bold())
                        Text("On-device SOCKS5 tunnel forwarder")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.green)

            if deviceProxy.localProxyEnabled {
                HStack(spacing: 10) {
                    Circle()
                        .fill(localProxy.isRunning ? .green : .red)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localProxy.statusMessage)
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(localProxy.isRunning ? .green : .red)
                        if localProxy.isRunning {
                            Text("127.0.0.1:\(localProxy.listeningPort)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if localProxy.isRunning {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(localProxy.stats.activeConnections) active")
                                .font(.system(.caption2, design: .monospaced, weight: .bold))
                                .foregroundStyle(.cyan)
                            Text("\(localProxy.stats.totalConnections) total")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                if localProxy.isRunning {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 12, weight: .bold))
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
                        Text(formatBytes(localProxy.stats.bytesRelayed))
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.green.opacity(0.1))
                            .clipShape(Capsule())
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "heart.text.square")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(healthMonitor.upstreamHealth.isHealthy ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Health")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(healthMonitor.isMonitoring ? (healthMonitor.upstreamHealth.isHealthy ? "Healthy" : "Unhealthy (\(healthMonitor.upstreamHealth.consecutiveFailures) fails)") : "Not monitoring")
                                .font(.system(.caption, design: .monospaced, weight: .medium))
                                .foregroundStyle(healthMonitor.upstreamHealth.isHealthy ? .green : .orange)
                        }
                        Spacer()
                        if let latency = healthMonitor.upstreamHealth.latencyMs {
                            Text("\(latency)ms")
                                .font(.system(.caption2, design: .monospaced, weight: .bold))
                                .foregroundStyle(.cyan)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color.cyan.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }

                    if localProxy.stats.upstreamErrors > 0 {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Text("\(localProxy.stats.upstreamErrors) errors (conn: \(localProxy.stats.connectionErrors), hs: \(localProxy.stats.handshakeErrors), relay: \(localProxy.stats.relayErrors))")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.orange)
                        }
                    }

                    if deviceProxy.failoverCount > 0 {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.caption2)
                                .foregroundStyle(.red)
                            Text("\(deviceProxy.failoverCount) auto-failovers triggered")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                    }

                    NavigationLink {
                        ProxyStatusDashboardView()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chart.bar.xaxis")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.cyan)
                            Text("Proxy Dashboard")
                                .font(.subheadline.bold())
                            Spacer()
                            Text("\(localProxy.stats.activeConnections) conn")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                if deviceProxy.shouldShowWireProxyDashboard {
                    NavigationLink {
                        WireProxyDashboardView()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.purple)
                            Text("WireGuard Tunnel")
                                .font(.subheadline.bold())
                            Spacer()
                            Text(deviceProxy.isEnabled ? "UNITED" : "PER-SESSION")
                                .font(.system(.caption2, design: .monospaced, weight: .bold))
                                .foregroundStyle(.purple)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.purple.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                }

                if !deviceProxy.isEnabled && deviceProxy.perSessionWireProxyActive {
                    if let serverName = deviceProxy.wireProxyActiveConfigLabel {
                        HStack(spacing: 8) {
                            Image(systemName: "globe")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.purple.opacity(0.7))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Per-Session WG Tunnel")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(serverName)
                                    .font(.system(.caption, design: .monospaced, weight: .medium))
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                deviceProxy.rotatePerSessionWireProxy()
                            } label: {
                                Label("Rotate", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.system(.caption2, weight: .bold))
                            }
                            .buttonStyle(.bordered)
                            .tint(.purple)
                            .controlSize(.small)
                        }
                    }
                } else if !deviceProxy.isEnabled && deviceProxy.isWireProxyCompatibleMode && !deviceProxy.perSessionWireProxyActive {
                    Button {
                        deviceProxy.activatePerSessionWireProxy()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.purple)
                            Text("Start Per-Session WireProxy")
                                .font(.subheadline.bold())
                            Spacer()
                        }
                    }
                    .tint(.purple)
                }

                if !deviceProxy.isEnabled && deviceProxy.perSessionOpenVPNActive {
                    if let serverName = deviceProxy.openVPNActiveConfigLabel {
                        HStack(spacing: 8) {
                            Image(systemName: "globe")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.indigo.opacity(0.7))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Per-Session OVPN Tunnel")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(serverName)
                                    .font(.system(.caption, design: .monospaced, weight: .medium))
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                deviceProxy.rotatePerSessionOpenVPN()
                            } label: {
                                Label("Rotate", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.system(.caption2, weight: .bold))
                            }
                            .buttonStyle(.bordered)
                            .tint(.indigo)
                            .controlSize(.small)
                        }
                    }
                } else if !deviceProxy.isEnabled && deviceProxy.isOpenVPNProxyCompatibleMode && !deviceProxy.perSessionOpenVPNActive {
                    Button {
                        deviceProxy.activatePerSessionOpenVPN()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.indigo)
                            Text("Start Per-Session OpenVPN")
                                .font(.subheadline.bold())
                            Spacer()
                        }
                    }
                    .tint(.indigo)
                }
            }
        } header: {
            HStack {
                Image(systemName: "server.rack")
                Text("WireProxy Server")
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
        } footer: {
            if deviceProxy.isEnabled {
                Text("Routes all app traffic through an encrypted tunnel via localhost SOCKS5.")
            } else if deviceProxy.perSessionWireProxyActive || deviceProxy.perSessionOpenVPNActive {
                Text("Per-session tunnel active — each session gets its own IP. Tap Rotate to switch server.")
            } else {
                Text("Routes traffic through a shared on-device SOCKS5 tunnel. Enable the toggle to activate.")
            }
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
    }

    // MARK: - Proxy Manager Link

    private var proxyManagerLinkSection: some View {
        Section {
            NavigationLink {
                ProxyManagerView()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.teal.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "server.rack")
                            .font(.body)
                            .foregroundStyle(.teal)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Proxy Manager").font(.subheadline.bold())
                        Text("Sets, import, routing & config management")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let vm = ProxyManagerViewModel()
                    Text("\(vm.proxySets.count) sets")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.teal)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.teal.opacity(0.12)).clipShape(Capsule())
                }
            }
        } header: {
            Label("Proxy Manager", systemImage: "server.rack")
        } footer: {
            Text("Manage proxy sets, import configs, and configure session routing.")
        }
    }

    // MARK: - Ignition Region

    private var ignitionRegionSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: proxyService.networkRegion == .usa ? "flag.fill" : "globe.asia.australia.fill")
                    .foregroundStyle(proxyService.networkRegion == .usa ? .blue : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ignition Region").font(.body)
                    Text("Select USA or AU for Ignition proxy/VPN endpoints")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: Binding(
                    get: { proxyService.networkRegion },
                    set: { proxyService.networkRegion = $0 }
                )) {
                    Text("USA").tag(NetworkRegion.usa)
                    Text("AU").tag(NetworkRegion.au)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: proxyService.networkRegion)
        } header: {
            Label("Ignition Region", systemImage: "globe")
        } footer: {
            Text("Only Ignition uses this region toggle. Joe Fortune and PPSR share the same configs regardless of region.")
        }
    }



    // MARK: - Endpoint Config

    @ViewBuilder
    private var endpointConfigSection: some View {
        switch proxyService.unifiedConnectionMode {
        case .direct: directDNSURLSection
        case .proxy: proxySection
        case .openvpn: openVPNSummarySection
        case .wireguard: wireGuardSummarySection
        case .dns:
            dnsSection
            directDNSURLSection
        case .nodeMaven: nodeMavenSection
        case .hybrid: hybridInfoSection
        }
    }

    private var directDNSURLSection: some View {
        let urlService = LoginURLRotationService.shared
        return Section {
            Toggle(isOn: Binding(
                get: { urlService.dontAutoDisableURLsForDirectDNS },
                set: { newValue in
                    urlService.dontAutoDisableURLsForDirectDNS = newValue
                    if !newValue {
                        urlService.applyDirectDNSAutoDisable()
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Don't auto disable any URLs for Direct/DNS")
                        .font(.subheadline)
                    if urlService.isDirectDNSAutoDisableActive {
                        Text("\(urlService.directDNSAutoDisabledCount) URLs auto-disabled")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .tint(.orange)

            if !urlService.dontAutoDisableURLsForDirectDNS {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Safe Domains for Direct/DNS", systemImage: "checkmark.shield.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                    ForEach(Array(LoginURLRotationService.directDNSSafeJoeDomains.sorted()), id: \.self) { domain in
                        HStack(spacing: 6) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 4))
                                .foregroundStyle(.green)
                            Text(domain)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                    }
                    Text("All other Joe/Ignition URLs are auto-disabled on Direct/DNS to prevent resolution failures.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Label("Direct/DNS URL Protection", systemImage: "shield.lefthalf.filled")
        }
    }

    private var proxySection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "network").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SOCKS5 Proxies").font(.body)
                    Text("\(proxyService.unifiedProxies.count) proxies loaded")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                proxyBadge
            }

            Button { showProxyImport = true } label: {
                Label("Import Proxies", systemImage: "doc.on.clipboard.fill")
            }

            if !proxyService.unifiedProxies.isEmpty {
                Button {
                    guard !isTestingProxies else { return }
                    isTestingProxies = true
                    Task {
                        log("Testing all \(proxyService.unifiedProxies.count) proxies...")
                        await proxyService.testAllUnifiedProxies()
                        let working = proxyService.unifiedProxies.filter(\.isWorking).count
                        log("Proxy test: \(working)/\(proxyService.unifiedProxies.count) working", level: .success)
                        isTestingProxies = false
                    }
                } label: {
                    HStack {
                        Label("Test All Proxies", systemImage: "antenna.radiowaves.left.and.right")
                        if isTestingProxies { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isTestingProxies)

                Button {
                    let exported = proxyService.exportProxies(target: .joe)
                    UIPasteboard.general.string = exported
                    log("Exported \(proxyService.unifiedProxies.count) proxies to clipboard", level: .success)
                } label: {
                    Label("Export to Clipboard", systemImage: "doc.on.doc")
                }

                let deadCount = proxyService.unifiedProxies.filter({ !$0.isWorking && $0.lastTested != nil }).count
                if deadCount > 0 {
                    Button(role: .destructive) {
                        proxyService.removeDead(forIgnition: false)
                        proxyService.syncProxiesAcrossTargets()
                        log("Removed \(deadCount) dead proxies")
                    } label: {
                        Label("Remove \(deadCount) Dead", systemImage: "xmark.circle")
                    }
                }

                Button(role: .destructive) {
                    proxyService.clearAllUnifiedProxies()
                    log("Cleared all proxies")
                } label: {
                    Label("Clear All Proxies", systemImage: "trash")
                }
            }
        } header: {
            Label("SOCKS5 Proxies", systemImage: "network")
        }
    }

    @ViewBuilder
    private var proxyBadge: some View {
        let proxies = proxyService.unifiedProxies
        if !proxies.isEmpty {
            HStack(spacing: 4) {
                let working = proxies.filter(\.isWorking).count
                if working > 0 {
                    Text("\(working) ok")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.green)
                }
                let dead = proxies.filter({ !$0.isWorking && $0.lastTested != nil }).count
                if dead > 0 {
                    Text("\(dead) dead")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color(.tertiarySystemFill)).clipShape(Capsule())
        }
    }

    private var openVPNSummarySection: some View {
        Section {
            NavigationLink {
                ProxyManagerView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "shield.lefthalf.filled").foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenVPN Configs").font(.body)
                        Text("\(proxyService.unifiedVPNConfigs.count) configs loaded")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let enabledCount = proxyService.unifiedVPNConfigs.filter(\.isEnabled).count
                    if enabledCount > 0 {
                        Text("\(enabledCount) active")
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(.indigo)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.indigo.opacity(0.12)).clipShape(Capsule())
                    }
                }
            }
        } header: {
            Label("OpenVPN", systemImage: "shield.lefthalf.filled")
        } footer: {
            Text("Manage OpenVPN configs in Proxy Manager.")
        }
    }

    private var wireGuardSummarySection: some View {
        Section {
            NavigationLink {
                ProxyManagerView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "lock.trianglebadge.exclamationmark.fill").foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("WireGuard Configs").font(.body)
                        Text("\(proxyService.unifiedWGConfigs.count) configs loaded")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let enabledCount = proxyService.unifiedWGConfigs.filter(\.isEnabled).count
                    if enabledCount > 0 {
                        Text("\(enabledCount) active")
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.purple.opacity(0.12)).clipShape(Capsule())
                    }
                }
            }
        } header: {
            Label("WireGuard", systemImage: "lock.trianglebadge.exclamationmark.fill")
        } footer: {
            Text("Manage WireGuard configs in Proxy Manager.")
        }
    }

    private var dnsSection: some View {
        Section {
            let enabled = PPSRDoHService.shared.managedProviders.filter(\.isEnabled).count
            let total = PPSRDoHService.shared.managedProviders.count
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill").foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DoH DNS Rotation").font(.body)
                    Text("\(enabled)/\(total) providers enabled · rotates each request")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }

            Button { showDNSManager = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "server.rack").foregroundStyle(.cyan)
                    Text("Manage DNS Servers")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
        } header: {
            Label("DNS-over-HTTPS", systemImage: "lock.shield.fill")
        } footer: {
            Text("DNS-over-HTTPS rotation is shared across all targets.")
        }
    }

    // MARK: - Helpers

    private var isTunnelRelevantMode: Bool {
        let mode = proxyService.unifiedConnectionMode
        return mode == .wireguard || mode == .openvpn || mode == .hybrid
    }

    private var modeColor: Color {
        switch proxyService.unifiedConnectionMode {
        case .direct: .green
        case .proxy: .blue
        case .openvpn: .indigo
        case .wireguard: .purple
        case .dns: .cyan
        case .nodeMaven: .teal
        case .hybrid: .mint
        }
    }

    // MARK: - Hybrid Info

    private var hybridInfoSection: some View {
        Section {
            let hybrid = HybridNetworkingService.shared

            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.mint.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "rectangle.3.group.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.mint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hybrid Networking").font(.subheadline.bold())
                    Text("1 session per networking method")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if hybrid.isActive {
                    Text("ACTIVE")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.mint)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.mint.opacity(0.12)).clipShape(Capsule())
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("How it works")
                    .font(.caption.bold())
                    .foregroundStyle(.mint)
                Text("Each concurrent session uses a different networking method: WireProxy, NodeMaven, OpenVPN, SOCKS5. HTTPS/DoH is used as a 5th fallback if needed. AI ranks methods by health scores.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            ForEach(HybridNetworkingService.HybridMethod.allCases, id: \.rawValue) { method in
                let available = isMethodAvailable(method)
                HStack(spacing: 8) {
                    Image(systemName: method.icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(available ? .mint : .secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(method.rawValue)
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(available ? .primary : .secondary)
                        if let stat = hybrid.methodStats[method] {
                            Text("\(stat.attempts) attempts, \(Int(stat.successRate * 100))% SR, ~\(stat.avgLatencyMs)ms")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Circle()
                        .fill(available ? Color.green : Color.red.opacity(0.5))
                        .frame(width: 6, height: 6)
                }
            }

            if !hybrid.hybridSummary.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.purple)
                    Text("AI Health: \(hybrid.hybridSummary)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Image(systemName: "rectangle.3.group.fill")
                Text("Hybrid Mode")
                Spacer()
                Text("1-PER-METHOD")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(.mint)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.mint.opacity(0.12))
                    .clipShape(Capsule())
            }
        } footer: {
            Text("Hybrid mode distributes sessions across all available networking methods. AI monitors health and adjusts method priority.")
        }
    }

    private func isMethodAvailable(_ method: HybridNetworkingService.HybridMethod) -> Bool {
        switch method {
        case .wireProxy:
            return !proxyService.joeWGConfigs.filter({ $0.isEnabled }).isEmpty
        case .nodeMaven:
            return NodeMavenService.shared.isEnabled
        case .openVPN:
            return !proxyService.joeVPNConfigs.filter({ $0.isEnabled }).isEmpty
        case .socks5:
            return !proxyService.savedProxies.filter({ $0.isWorking || $0.lastTested == nil }).isEmpty
        case .httpsDOH:
            return true
        }
    }

    // MARK: - NodeMaven

    private var nodeMavenSection: some View {
        Section {
            let nm = NodeMavenService.shared

            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.teal.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.teal)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("NodeMaven Proxy").font(.subheadline.bold())
                    Text(nm.statusSummary)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if nm.isEnabled {
                    Text(nm.shortStatus)
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.teal)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.teal.opacity(0.12)).clipShape(Capsule())
                }
            }

            if nm.proxyUsername.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Credentials Required")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                    }
                    Text("Enter your NodeMaven proxy username and password from the dashboard Proxy Setup section.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "person.fill").foregroundStyle(.teal).font(.caption)
                    TextField("Proxy Username", text: Binding(
                        get: { nm.proxyUsername },
                        set: { nm.proxyUsername = $0 }
                    ))
                    .font(.system(.callout, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                }
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(.teal).font(.caption)
                    SecureField("Proxy Password", text: Binding(
                        get: { nm.proxyPassword },
                        set: { nm.proxyPassword = $0 }
                    ))
                    .font(.system(.callout, design: .monospaced))
                }
            }

            Picker(selection: Binding(
                get: { nm.country },
                set: { nm.country = $0 }
            )) {
                ForEach(NodeMavenCountry.allCases, id: \.self) { c in
                    Label("\(c.flagEmoji) \(c.label)", systemImage: c.icon).tag(c)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "globe").foregroundStyle(.teal)
                    Text("Country")
                }
            }
            .pickerStyle(.menu)

            Picker(selection: Binding(
                get: { nm.proxyType },
                set: { nm.proxyType = $0 }
            )) {
                ForEach(NodeMavenProxyType.allCases, id: \.self) { t in
                    Label(t.label, systemImage: t.icon).tag(t)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: nm.proxyType.icon).foregroundStyle(.teal)
                    Text("Proxy Type")
                }
            }
            .pickerStyle(.menu)

            Picker(selection: Binding(
                get: { nm.filter },
                set: { nm.filter = $0 }
            )) {
                ForEach(NodeMavenFilter.allCases, id: \.self) { f in
                    Text(f.label).tag(f)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("IP Quality Filter")
                        Text(nm.filter.detail)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .pickerStyle(.menu)

            Picker(selection: Binding(
                get: { nm.sessionMode },
                set: { nm.sessionMode = $0 }
            )) {
                ForEach(NodeMavenSessionMode.allCases, id: \.self) { s in
                    Text(s.label).tag(s)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Session Mode")
                        Text(nm.sessionMode.detail)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .pickerStyle(.menu)

            if nm.isEnabled {
                Button {
                    Task { await nm.testConnection() }
                } label: {
                    HStack(spacing: 8) {
                        if nm.isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.teal)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Test Connection").font(.subheadline.bold())
                            if let result = nm.lastTestResult {
                                Text(result)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(result.contains("Connected") ? .green : .red)
                            }
                        }
                        Spacer()
                    }
                }
                .disabled(nm.isTesting)
                .sensoryFeedback(.impact(weight: .medium), trigger: nm.isTesting)
            }

            if nm.isEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.teal.opacity(0.7))
                            .font(.caption2)
                        Text("Preview Username")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                    }
                    Text(nm.buildUsername(sessionId: "preview123"))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 4)
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "key.horizontal.fill").foregroundStyle(.orange).font(.caption)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("API Key").font(.caption.bold())
                            if !nm.apiKey.isEmpty {
                                Text(String(nm.apiKey.prefix(20)) + "...")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    TextField("JWT API Key", text: Binding(
                        get: { nm.apiKey },
                        set: { nm.apiKey = $0 }
                    ))
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                    HStack(spacing: 6) {
                        Image(systemName: "server.rack").foregroundStyle(.secondary).font(.caption2)
                        Text("Gateway: \(NodeMavenService.gatewayHost):1080 (SOCKS5)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape").foregroundStyle(.teal)
                    Text("Advanced")
                }
            }
        } header: {
            HStack {
                Image(systemName: "cloud.fill")
                Text("NodeMaven")
                Spacer()
                if NodeMavenService.shared.isEnabled {
                    Text(NodeMavenService.shared.shortStatus)
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.teal)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.teal.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        } footer: {
            Text("NodeMaven residential & mobile proxy network. 30M+ IPs across 164+ countries. Proxy type (residential/mobile) is configured in your NodeMaven dashboard.")
        }
    }

    // MARK: - Sheets

    private var proxyImportSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle().fill(.blue).frame(width: 10, height: 10)
                        Text("Import SOCKS5 Proxies").font(.headline)
                    }
                    Text("Imported proxies are synced across all targets.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Button {
                        if let clipboard = UIPasteboard.general.string, !clipboard.isEmpty {
                            proxyBulkText = clipboard
                        }
                    } label: {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard").font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    Spacer()
                    let lineCount = proxyBulkText.components(separatedBy: .newlines).filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count
                    if lineCount > 0 {
                        Text("\(lineCount) lines").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }

                TextEditor(text: $proxyBulkText)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden).padding(10)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 10)).frame(minHeight: 200)
                    .overlay(alignment: .topLeading) {
                        if proxyBulkText.isEmpty {
                            Text("Paste SOCKS5 proxies here...\n\n127.0.0.1:1080\nuser:pass@proxy.com:9050")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.quaternary)
                                .padding(.horizontal, 14).padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }

                if let report = proxyImportReport {
                    HStack(spacing: 12) {
                        if report.added > 0 {
                            Label("\(report.added) added", systemImage: "checkmark.circle.fill").font(.caption.bold()).foregroundStyle(.green)
                        }
                        if report.duplicates > 0 {
                            Label("\(report.duplicates) duplicates", systemImage: "arrow.triangle.2.circlepath").font(.caption.bold()).foregroundStyle(.orange)
                        }
                        if !report.failed.isEmpty {
                            Label("\(report.failed.count) failed", systemImage: "xmark.circle.fill").font(.caption.bold()).foregroundStyle(.red)
                        }
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Import Proxies").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showProxyImport = false
                        proxyBulkText = ""
                        proxyImportReport = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        let report = proxyService.importUnifiedProxy(proxyBulkText)
                        proxyImportReport = report
                        if report.added > 0 {
                            log("Imported \(report.added) SOCKS5 proxies → all targets", level: .success)
                        }
                        proxyBulkText = ""
                        if report.failed.isEmpty && report.added > 0 {
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                showProxyImport = false
                                proxyImportReport = nil
                            }
                        }
                    }
                    .disabled(proxyBulkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    @State private var dnsImportText: String = ""
    @State private var showDNSImport: Bool = false
    @State private var newDNSName: String = ""
    @State private var newDNSURL: String = ""
    @State private var isTestingDNS: Bool = false
    @State private var dnsTestResults: [(name: String, endpoint: String, passed: Bool, latencyMs: Int?)] = []
    @State private var dnsAutoDisabledCount: Int = 0

    private var dnsManagerSheet: some View {
        NavigationStack {
            List {
                if showDNSImport {
                    Section("Import DNS Servers") {
                        Text("One per line. Format: Name|URL or just URL")
                            .font(.caption2).foregroundStyle(.secondary)

                        TextEditor(text: $dnsImportText)
                            .font(.system(.callout, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(.rect(cornerRadius: 8))
                            .frame(minHeight: 80)
                            .overlay(alignment: .topLeading) {
                                if dnsImportText.isEmpty {
                                    Text("Custom|https://dns.example.com/dns-query\nhttps://dns.other.com/dns-query")
                                        .font(.system(.callout, design: .monospaced))
                                        .foregroundStyle(.quaternary)
                                        .padding(.horizontal, 12).padding(.vertical, 16)
                                        .allowsHitTesting(false)
                                }
                            }

                        HStack {
                            Button {
                                if let clip = UIPasteboard.general.string { dnsImportText = clip }
                            } label: {
                                Label("Paste", systemImage: "doc.on.clipboard").font(.caption)
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            Spacer()
                            Button {
                                let result = PPSRDoHService.shared.bulkImportProviders(dnsImportText)
                                log("DNS import: \(result.added) added, \(result.duplicates) dupes, \(result.invalid) invalid", level: result.added > 0 ? .success : .warning)
                                dnsImportText = ""
                                if result.added > 0 { withAnimation(.snappy) { showDNSImport = false } }
                            } label: {
                                Label("Import", systemImage: "arrow.down.doc.fill").font(.caption.bold())
                            }
                            .buttonStyle(.borderedProminent).tint(.cyan)
                            .disabled(dnsImportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    Section("Add Single Server") {
                        TextField("Name", text: $newDNSName)
                            .font(.system(.body, design: .monospaced))
                        TextField("https://dns.example.com/dns-query", text: $newDNSURL)
                            .font(.system(.callout, design: .monospaced))
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        Button {
                            if PPSRDoHService.shared.addProvider(name: newDNSName, url: newDNSURL) {
                                log("Added DNS provider: \(newDNSName)", level: .success)
                                newDNSName = ""
                                newDNSURL = ""
                            }
                        } label: {
                            Label("Add Server", systemImage: "plus.circle.fill")
                        }
                        .disabled(newDNSName.trimmingCharacters(in: .whitespaces).isEmpty || newDNSURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                let enabled = PPSRDoHService.shared.managedProviders.filter(\.isEnabled).count
                Section {
                    ForEach(PPSRDoHService.shared.managedProviders) { provider in
                        HStack(spacing: 10) {
                            Button {
                                PPSRDoHService.shared.toggleProvider(id: provider.id, enabled: !provider.isEnabled)
                            } label: {
                                Image(systemName: provider.isEnabled ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(provider.isEnabled ? .cyan : .secondary)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(provider.name).font(.system(.subheadline, design: .monospaced, weight: .medium))
                                    if provider.isDefault {
                                        Text("DEFAULT")
                                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                                            .foregroundStyle(.cyan.opacity(0.7))
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(Color.cyan.opacity(0.1)).clipShape(Capsule())
                                    }
                                }
                                Text(provider.url.replacingOccurrences(of: "https://", with: ""))
                                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Spacer()
                            if let result = dnsTestResults.first(where: { $0.name == provider.name }) {
                                if result.passed {
                                    HStack(spacing: 3) {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                                        if let ms = result.latencyMs {
                                            Text("\(ms)ms")
                                                .font(.system(.caption2, design: .monospaced, weight: .medium))
                                                .foregroundStyle(ms < 200 ? .green : (ms < 500 ? .orange : .red))
                                        }
                                    }
                                } else {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                PPSRDoHService.shared.deleteProvider(id: provider.id)
                                log("Deleted DNS provider: \(provider.name)")
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                } header: {
                    Text("DNS Servers (\(enabled)/\(PPSRDoHService.shared.managedProviders.count))")
                }

                Section {
                    Button {
                        withAnimation(.snappy) { showDNSImport.toggle() }
                    } label: {
                        Label(showDNSImport ? "Hide Import" : "Import / Add Servers", systemImage: "plus.circle.fill")
                    }
                    Button {
                        isTestingDNS = true
                        dnsTestResults = []
                        dnsAutoDisabledCount = 0
                        Task {
                            let outcome = await PPSRDoHService.shared.testAllAndAutoDisable()
                            dnsTestResults = outcome.results.map { (name: $0.server.displayLabel, endpoint: $0.server.endpoint, passed: $0.passed, latencyMs: $0.latencyMs) }
                            dnsAutoDisabledCount = outcome.disabledCount
                            isTestingDNS = false
                            let passed = outcome.results.filter(\.passed).count
                            let total = outcome.results.count
                            if outcome.disabledCount > 0 {
                                log("DNS test: \(passed)/\(total) passed, \(outcome.disabledCount) auto-disabled", level: passed > 0 ? .warning : .error)
                            } else {
                                log("DNS test complete: \(passed)/\(total) servers passed", level: passed > 0 ? .success : .error)
                            }
                        }
                    } label: {
                        HStack {
                            Label("Test All & Auto-Disable Failed", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            if isTestingDNS {
                                ProgressView()
                            } else if !dnsTestResults.isEmpty {
                                let passed = dnsTestResults.filter(\.passed).count
                                Text("\(passed)/\(dnsTestResults.count)")
                                    .font(.system(.caption, design: .monospaced, weight: .bold))
                                    .foregroundStyle(passed == dnsTestResults.count ? .green : (passed > 0 ? .orange : .red))
                            }
                        }
                    }
                    .disabled(isTestingDNS)
                    if dnsAutoDisabledCount > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                            Text("\(dnsAutoDisabledCount) server\(dnsAutoDisabledCount == 1 ? "" : "s") auto-disabled due to test failure")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        PPSRDoHService.shared.enableAll()
                        log("Enabled all DNS providers", level: .success)
                    } label: {
                        Label("Enable All", systemImage: "checkmark.circle")
                    }
                    Button {
                        PPSRDoHService.shared.resetToDefaults()
                        log("Reset DNS providers to defaults", level: .success)
                    } label: {
                        Label("Reset to Defaults", systemImage: "arrow.uturn.backward")
                    }
                } header: {
                    Text("Actions")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("DNS Manager").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showDNSManager = false } }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }
}
