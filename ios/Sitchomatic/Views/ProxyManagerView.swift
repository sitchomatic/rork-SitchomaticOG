import SwiftUI
import UniformTypeIdentifiers

private enum PMFileImportType {
    case vpn, wireGuard
}

struct ProxyManagerView: View {
    @State private var vm = ProxyManagerViewModel()
    @State private var showNewSetSheet: Bool = false
    @State private var newSetName: String = ""
    @State private var newSetType: ProxySetType = .socks5
    @State private var activeFileImportType: PMFileImportType?
    @State private var isTestingVPNConfigs: Bool = false
    @State private var isTestingWGConfigs: Bool = false

    private let proxyService = ProxyRotationService.shared
    private let nordService = NordVPNService.shared
    private let logger = DebugLogger.shared

    var body: some View {
        List {
            overviewSection
            autoPopulateSetsSection
            if vm.canUseOnePerSet {
                sessionRoutingSection
            }
            proxySetsSection
            if !vm.proxySets.isEmpty {
                quickStatsSection
            }
            nordVPNSection
            openVPNConfigsSection
            wireGuardConfigsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Proxy Manager")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newSetName = ""
                    newSetType = .socks5
                    showNewSetSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.teal)
                }
            }
        }
        .sheet(isPresented: $showNewSetSheet) {
            newSetSheetContent
        }
        .fileImporter(
            isPresented: Binding(
                get: { activeFileImportType != nil },
                set: { if !$0 { activeFileImportType = nil } }
            ),
            allowedContentTypes: [.data, .plainText],
            allowsMultipleSelection: true
        ) { result in
            switch activeFileImportType {
            case .vpn: handleVPNFileImport(result)
            case .wireGuard: handleWGFileImport(result)
            case .none: break
            }
        }
    }

    private func log(_ message: String, level: DebugLogLevel = .info) {
        logger.log(message, category: .network, level: level)
    }

    private var overviewSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(colors: [.teal, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 48, height: 48)
                    Image(systemName: "server.rack")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(vm.proxySets.count) Proxy Sets")
                        .font(.headline)
                    Text("\(vm.totalItemsCount) total servers · \(vm.activeSetsCount) active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if vm.canUseOnePerSet {
                    VStack(spacing: 2) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.green)
                        Text("4+ sets")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green.opacity(0.8))
                    }
                }
            }
            .listRowBackground(Color(.secondarySystemGroupedBackground))
        }
    }

    private var sessionRoutingSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { vm.useOneServerPerSet },
                set: { newValue in
                    vm.useOneServerPerSet = newValue
                }
            )) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.purple.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.purple)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("1 Server Per Set")
                            .font(.subheadline.bold())
                        Text("Each concurrent session uses a different set")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.purple)

            if vm.useOneServerPerSet {
                let activeSets = vm.proxySets.filter(\.isActive)
                ForEach(Array(activeSets.enumerated()), id: \.element.id) { index, set in
                    HStack(spacing: 10) {
                        Text("Session \(index + 1)")
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(sessionColor(index), in: Capsule())

                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        Image(systemName: set.typeIcon)
                            .font(.caption)
                            .foregroundStyle(typeColor(set.type))

                        Text(set.name)
                            .font(.subheadline)
                            .lineLimit(1)

                        Spacer()

                        Text(set.summary)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Label("Session Routing", systemImage: "arrow.triangle.swap")
        } footer: {
            Text("When enabled, each concurrent session draws from a separate proxy set. Requires 4+ active sets.")
        }
    }

    private var proxySetsSection: some View {
        Section {
            if vm.proxySets.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No Proxy Sets")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Tap + to create a set and import proxies, WireGuard, or OpenVPN configs.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ForEach(vm.proxySets) { set in
                    NavigationLink {
                        ProxySetDetailView(vm: vm, setId: set.id)
                    } label: {
                        proxySetRow(set)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            vm.deleteSet(set)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            vm.toggleSetActive(set)
                        } label: {
                            Label(
                                set.isActive ? "Disable" : "Enable",
                                systemImage: set.isActive ? "pause.circle" : "play.circle"
                            )
                        }
                        .tint(set.isActive ? .orange : .green)
                    }
                }
            }
        } header: {
            Label("Proxy Sets", systemImage: "rectangle.stack.fill")
        } footer: {
            if !vm.proxySets.isEmpty {
                Text("Each set holds up to 10 items of a single type. Swipe to enable/disable or delete.")
            }
        }
    }

    private var quickStatsSection: some View {
        Section {
            let socks5Count = vm.proxySets.filter { $0.type == .socks5 }.count
            let wgCount = vm.proxySets.filter { $0.type == .wireGuard }.count
            let ovpnCount = vm.proxySets.filter { $0.type == .openVPN }.count

            HStack {
                statBadge(count: socks5Count, label: "SOCKS5", icon: "network", color: .blue)
                Spacer()
                statBadge(count: wgCount, label: "WireGuard", icon: "lock.trianglebadge.exclamationmark.fill", color: .cyan)
                Spacer()
                statBadge(count: ovpnCount, label: "OpenVPN", icon: "shield.lefthalf.filled", color: .orange)
            }
            .padding(.vertical, 4)
        } header: {
            Label("Breakdown", systemImage: "chart.bar.fill")
        }
    }

    // MARK: - Auto-Populate Proxy Sets

    private var autoPopulateSetsSection: some View {
        Section {
            Button {
                guard !vm.isAutoPopulatingSets else { return }
                Task { await vm.autoPopulateProxySetsForAllProfiles() }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .frame(width: 40, height: 40)
                        if vm.isAutoPopulatingSets {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "bolt.shield.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Auto-Populate All Sets")
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Text(vm.isAutoPopulatingSets ? vm.autoPopulateSetsProgress : "10 WG + 10 OVPN per profile")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !vm.isAutoPopulatingSets {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .disabled(vm.isAutoPopulatingSets)

            if vm.isAutoPopulatingSets {
                Button {
                    guard !vm.isAutoPopulatingSets else { return }
                    Task { await vm.autoPopulateProxySetsForAllProfiles(forceRefresh: true) }
                } label: {
                    Label("Force Refresh All Sets", systemImage: "arrow.clockwise")
                }
                .disabled(true)
            } else {
                Button {
                    Task { await vm.autoPopulateProxySetsForAllProfiles(forceRefresh: true) }
                } label: {
                    Label("Force Refresh All Sets", systemImage: "arrow.clockwise")
                        .foregroundStyle(.orange)
                }
            }

            if let error = vm.autoPopulateSetsError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            HStack {
                Label("Auto-Populate", systemImage: "wand.and.stars")
                Spacer()
                ForEach(NordKeyProfile.allCases, id: \.self) { profile in
                    Text(profile.rawValue)
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.indigo)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.indigo.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        } footer: {
            Text("Fetches 10 WireGuard + 10 OpenVPN configs for each profile (Nick & Poli) using their NordVPN access keys, and creates proxy sets automatically.")
        }
    }

    // MARK: - NordVPN Integration

    private var nordVPNSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "shield.checkered").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NordVPN Integration").font(.body)
                    Text("Profile: \(nordService.activeKeyProfile.rawValue)")
                        .font(.caption2).foregroundStyle(.green)
                }
                Spacer()
                if nordService.hasPrivateKey {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "key.horizontal.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Active Key").font(.caption.bold())
                    Text(String(nordService.accessKey.prefix(12)) + "...")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(nordService.activeKeyProfile.rawValue)
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(.indigo)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.indigo.opacity(0.12)).clipShape(Capsule())
            }

            if !nordService.hasPrivateKey {
                Button {
                    Task { await nordService.fetchPrivateKey() }
                } label: {
                    HStack {
                        if nordService.isLoadingKey { ProgressView().controlSize(.small) }
                        Label("Fetch WireGuard Private Key", systemImage: "key.fill")
                    }
                }
                .disabled(nordService.isLoadingKey)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "key.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Private Key").font(.caption.bold())
                        Text(String(nordService.privateKey.prefix(12)) + "...")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Ready").font(.caption2.bold()).foregroundStyle(.green)
                }

                Button {
                    Task { await nordService.fetchPrivateKey() }
                } label: {
                    HStack {
                        if nordService.isLoadingKey { ProgressView().controlSize(.small) }
                        Label("Re-fetch Private Key", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(nordService.isLoadingKey)
            }

            Button {
                Task { await nordService.fetchRecommendedServers(limit: 10, technology: "openvpn_tcp") }
            } label: {
                HStack {
                    if nordService.isLoadingServers { ProgressView().controlSize(.small) }
                    Label("Fetch TCP Servers", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(nordService.isLoadingServers)

            if nordService.hasPrivateKey {
                Button {
                    Task { await nordService.fetchRecommendedServers(limit: 10, technology: "wireguard_udp") }
                } label: {
                    HStack {
                        if nordService.isLoadingServers { ProgressView().controlSize(.small) }
                        Label("Fetch WireGuard Servers", systemImage: "lock.fill")
                    }
                }
                .disabled(nordService.isLoadingServers)
            }

            if !nordService.recommendedServers.isEmpty {
                Button {
                    guard !nordService.isDownloadingOVPN else { return }
                    Task {
                        let result = await nordService.downloadAllTCPConfigs(for: nordService.recommendedServers, target: .joe)
                        proxyService.syncVPNConfigsAcrossTargets()
                        log("NordVPN TCP: \(result.imported) imported, \(result.failed) failed -> all targets", level: result.imported > 0 ? .success : .error)
                    }
                } label: {
                    HStack(spacing: 10) {
                        if nordService.isDownloadingOVPN {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.doc.fill").foregroundStyle(.indigo)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Download All TCP .ovpn").font(.subheadline.bold())
                            Text(nordService.isDownloadingOVPN ? "Downloading \(nordService.ovpnDownloadProgress)..." : "\(nordService.recommendedServers.count) servers available")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .disabled(nordService.isDownloadingOVPN)

                if nordService.hasPrivateKey {
                    Button {
                        var imported = 0
                        for server in nordService.recommendedServers {
                            if let wg = nordService.generateWireGuardConfig(from: server) {
                                proxyService.importWGConfig(wg, for: .joe)
                                imported += 1
                            }
                        }
                        proxyService.syncWGConfigsAcrossTargets()
                        log("Generated \(imported) WireGuard configs -> all targets", level: imported > 0 ? .success : .error)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "lock.shield.fill").foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Generate All WireGuard").font(.subheadline.bold())
                                Text("\(nordService.recommendedServers.count) servers -> WG configs")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }

                ForEach(nordService.recommendedServers, id: \.id) { server in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.hostname)
                                .font(.system(.caption, design: .monospaced, weight: .medium))
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                if let city = server.city {
                                    Text(city).font(.caption2).foregroundStyle(.secondary)
                                }
                                Text("Load: \(server.load)%")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(server.load < 30 ? .green : (server.load < 70 ? .orange : .red))
                            }
                        }
                        Spacer()
                        Menu {
                            Button {
                                Task {
                                    if let config = await nordService.downloadOVPNConfig(from: server, proto: .tcp) {
                                        proxyService.importVPNConfig(config, for: .joe)
                                        proxyService.syncVPNConfigsAcrossTargets()
                                        log("Imported TCP .ovpn: \(server.hostname) -> all targets", level: .success)
                                    }
                                }
                            } label: { Label("TCP .ovpn -> All", systemImage: "shield.lefthalf.filled") }
                            if nordService.hasPrivateKey, server.publicKey != nil {
                                Divider()
                                Button {
                                    if let wgConfig = nordService.generateWireGuardConfig(from: server) {
                                        proxyService.importWGConfig(wgConfig, for: .joe)
                                        proxyService.syncWGConfigsAcrossTargets()
                                        log("Imported WG: \(server.hostname) -> all targets", level: .success)
                                    }
                                } label: { Label("WireGuard -> All", systemImage: "lock.fill") }
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                        }
                    }
                }
            }

            if nordService.isTokenExpired {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Access Token Expired")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                    }
                    Text("Your NordVPN access token is no longer valid. Go to your NordVPN account dashboard -> Manual Setup to generate a new one, then update it in NordLynx Access Key Settings.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if let error = nordService.lastError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            HStack {
                Text("NordVPN")
                Spacer()
                if nordService.isTokenExpired {
                    Text("Token Expired")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                } else {
                    Text(nordService.activeKeyProfile.rawValue)
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.indigo)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.indigo.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        } footer: {
            Text("Switch profiles from the Main Menu. Each profile has its own proxy configs, WireGuard configs, and private keys.")
        }
    }

    // MARK: - OpenVPN Configs

    private var openVPNConfigsSection: some View {
        Section {
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

            Button { activeFileImportType = .vpn } label: {
                Label("Import .ovpn Files", systemImage: "doc.badge.plus")
            }

            if !proxyService.unifiedVPNConfigs.isEmpty {
                Button {
                    guard !isTestingVPNConfigs else { return }
                    isTestingVPNConfigs = true
                    Task {
                        log("Testing \(proxyService.unifiedVPNConfigs.count) OpenVPN configs...")
                        await proxyService.testAllUnifiedVPNConfigs()
                        let reachable = proxyService.unifiedVPNConfigs.filter(\.isReachable).count
                        log("OpenVPN test: \(reachable)/\(proxyService.unifiedVPNConfigs.count) reachable", level: .success)
                        isTestingVPNConfigs = false
                    }
                } label: {
                    HStack {
                        Label("Test All OpenVPN", systemImage: "antenna.radiowaves.left.and.right")
                        if isTestingVPNConfigs { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isTestingVPNConfigs)

                ForEach(proxyService.unifiedVPNConfigs) { vpn in
                    HStack(spacing: 8) {
                        Image(systemName: vpn.isEnabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(vpn.isEnabled ? .indigo : .secondary)
                            .onTapGesture {
                                proxyService.toggleVPNConfig(vpn, target: .joe, enabled: !vpn.isEnabled)
                                proxyService.syncVPNConfigsAcrossTargets()
                            }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(vpn.fileName)
                                .font(.system(.caption, design: .monospaced, weight: .medium)).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(vpn.displayString)
                                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                                Text(vpn.statusLabel)
                                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                                    .foregroundStyle(vpn.isReachable ? .green : (vpn.lastTested != nil ? .red : .gray))
                                if let latency = vpn.lastLatencyMs {
                                    Text("\(latency)ms")
                                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        Spacer()
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            proxyService.removeVPNConfig(vpn, target: .joe)
                            proxyService.syncVPNConfigsAcrossTargets()
                            log("Removed VPN: \(vpn.fileName)")
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }

                let unreachableCount = proxyService.unifiedVPNConfigs.filter({ !$0.isReachable && $0.lastTested != nil }).count
                if unreachableCount > 0 {
                    Button(role: .destructive) {
                        proxyService.removeUnreachableVPNConfigs(target: .joe)
                        proxyService.syncVPNConfigsAcrossTargets()
                        log("Removed \(unreachableCount) unreachable OpenVPN configs")
                    } label: {
                        Label("Remove \(unreachableCount) Unreachable", systemImage: "xmark.circle")
                    }
                }

                Button(role: .destructive) {
                    proxyService.clearAllUnifiedVPNConfigs()
                    log("Cleared all OpenVPN configs")
                } label: {
                    Label("Clear All Configs", systemImage: "trash")
                }
            }
        } header: {
            Label("OpenVPN", systemImage: "shield.lefthalf.filled")
        }
    }

    // MARK: - WireGuard Configs

    private var wireGuardConfigsSection: some View {
        Section {
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

            Button { activeFileImportType = .wireGuard } label: {
                Label("Import .conf Files", systemImage: "doc.badge.plus")
            }

            if !proxyService.unifiedWGConfigs.isEmpty {
                Button {
                    guard !isTestingWGConfigs else { return }
                    isTestingWGConfigs = true
                    Task {
                        log("Testing \(proxyService.unifiedWGConfigs.count) WireGuard configs...")
                        await proxyService.testAllUnifiedWGConfigs()
                        let reachable = proxyService.unifiedWGConfigs.filter(\.isReachable).count
                        log("WireGuard test: \(reachable)/\(proxyService.unifiedWGConfigs.count) reachable", level: .success)
                        isTestingWGConfigs = false
                    }
                } label: {
                    HStack {
                        Label("Test All WireGuard", systemImage: "antenna.radiowaves.left.and.right")
                        if isTestingWGConfigs { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isTestingWGConfigs)

                ForEach(proxyService.unifiedWGConfigs) { wg in
                    HStack(spacing: 8) {
                        Image(systemName: wg.isEnabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(wg.isEnabled ? .purple : .secondary)
                            .onTapGesture {
                                proxyService.toggleWGConfig(wg, target: .joe, enabled: !wg.isEnabled)
                                proxyService.syncWGConfigsAcrossTargets()
                            }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(wg.fileName)
                                .font(.system(.caption, design: .monospaced, weight: .medium)).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(wg.displayString)
                                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                                Text(wg.statusLabel)
                                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                                    .foregroundStyle(wg.isReachable ? .green : (wg.lastTested != nil ? .red : .gray))
                            }
                        }
                        Spacer()
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            proxyService.removeWGConfig(wg, target: .joe)
                            proxyService.syncWGConfigsAcrossTargets()
                            log("Removed WireGuard: \(wg.fileName)")
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }

                let unreachableWGCount = proxyService.unifiedWGConfigs.filter({ !$0.isReachable && $0.lastTested != nil }).count
                if unreachableWGCount > 0 {
                    Button(role: .destructive) {
                        proxyService.removeUnreachableWGConfigs(target: .joe)
                        proxyService.syncWGConfigsAcrossTargets()
                        log("Removed \(unreachableWGCount) unreachable WireGuard configs")
                    } label: {
                        Label("Remove \(unreachableWGCount) Unreachable", systemImage: "xmark.circle")
                    }
                }

                Button(role: .destructive) {
                    proxyService.clearAllUnifiedWGConfigs()
                    log("Cleared all WireGuard configs")
                } label: {
                    Label("Clear All Configs", systemImage: "trash")
                }
            }
        } header: {
            Label("WireGuard", systemImage: "lock.trianglebadge.exclamationmark.fill")
        }
    }

    // MARK: - Row Helpers

    private func proxySetRow(_ set: ProxySet) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(typeColor(set.type).opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: set.typeIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(typeColor(set.type))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(set.name)
                        .font(.subheadline.bold())
                        .lineLimit(1)

                    if !set.isActive {
                        Text("OFF")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                    }
                }

                HStack(spacing: 8) {
                    Text(set.type.rawValue)
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(typeColor(set.type))

                    Text("·")
                        .foregroundStyle(.tertiary)

                    Text(set.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if set.isFull {
                Text("FULL")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.12), in: Capsule())
            } else {
                Text("\(set.items.count)/10")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statBadge(count: Int, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
                Text("\(count)")
                    .font(.system(.title3, design: .monospaced, weight: .bold))
                    .foregroundStyle(.primary)
            }
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var newSetSheetContent: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Set Name", text: $newSetName)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Name")
                }

                Section {
                    Picker("Type", selection: $newSetType) {
                        ForEach(ProxySetType.allCases, id: \.self) { type in
                            Label(type.rawValue, systemImage: type.icon)
                                .tag(type)
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Connection Type")
                } footer: {
                    Text("Each set can only contain one type. You can import up to 10 items per set.")
                }
            }
            .navigationTitle("New Proxy Set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showNewSetSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let name = newSetName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        vm.createSet(name: name, type: newSetType)
                        showNewSetSheet = false
                    }
                    .disabled(newSetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func typeColor(_ type: ProxySetType) -> Color {
        switch type {
        case .socks5: .blue
        case .wireGuard: .cyan
        case .openVPN: .orange
        }
    }

    private func sessionColor(_ index: Int) -> Color {
        let colors: [Color] = [.blue, .purple, .teal, .orange, .green, .pink, .indigo, .cyan]
        return colors[index % colors.count]
    }

    // MARK: - File Handlers

    private func handleVPNFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var imported = 0
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                if let data = try? Data(contentsOf: url),
                   let content = String(data: data, encoding: .utf8) {
                    let fileName = url.lastPathComponent
                    if let config = OpenVPNConfig.parse(fileName: fileName, content: content) {
                        proxyService.importUnifiedVPNConfig(config)
                        imported += 1
                    } else {
                        log("Failed to parse: \(fileName)", level: .warning)
                    }
                }
            }
            if imported > 0 {
                log("Imported \(imported) OpenVPN config(s) -> all targets", level: .success)
            }
        case .failure(let error):
            log("VPN import error: \(error.localizedDescription)", level: .error)
        }
    }

    private func handleWGFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var parsed: [WireGuardConfig] = []
            var failedFiles: [String] = []
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else {
                    failedFiles.append(url.lastPathComponent)
                    continue
                }
                defer { url.stopAccessingSecurityScopedResource() }
                if let data = try? Data(contentsOf: url),
                   let content = String(data: data, encoding: .utf8) {
                    let fileName = url.lastPathComponent
                    let configs = WireGuardConfig.parseMultiple(fileName: fileName, content: content)
                    if configs.isEmpty {
                        if let single = WireGuardConfig.parse(fileName: fileName, content: content) {
                            parsed.append(single)
                        } else {
                            failedFiles.append(fileName)
                        }
                    } else {
                        parsed.append(contentsOf: configs)
                    }
                } else {
                    failedFiles.append(url.lastPathComponent)
                }
            }
            if !parsed.isEmpty {
                let report = proxyService.importUnifiedWGConfigs(parsed)
                log("WireGuard import: \(report.added) added, \(report.duplicates) duplicates -> all targets", level: .success)
            }
            for name in failedFiles {
                log("Failed to parse WireGuard: \(name)", level: .warning)
            }
        case .failure(let error):
            log("WireGuard import error: \(error.localizedDescription)", level: .error)
        }
    }
}
