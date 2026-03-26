import SwiftUI
import WebKit
import UIKit

@Observable
class IPScoreSession: Identifiable {
    let id: UUID = UUID()
    let index: Int
    var url: URL = URL(string: "https://thisismyip.com")!
    var isLoading: Bool = true
    var currentURL: String = ""
    var pageTitle: String = ""
    var assignedVPNServer: String?
    var assignedVPNIP: String?
    var assignedVPNCountry: String?
    var assignedProxy: String?
    var networkLabel: String = "Direct"
    var startedAt: Date = Date()
    var detectedIP: String?
    var status: SessionStatus = .loading
    var networkConfig: ActiveNetworkConfig = .direct
    var webView: WKWebView?
    var currentSiteIndex: Int = 0
    var usedSite: String = "thisismyip.com"
    var screenshot: UIImage?
    var detectedIPFromPage: String?
    var tunnelSlotLabel: String?

    nonisolated static let fallbackURLs: [URL] = [
        URL(string: "https://thisismyip.com")!,
        URL(string: "https://ipscore.io")!,
        URL(string: "https://whatismyipaddress.com")!,
    ]

    nonisolated static let siteLabels: [String] = [
        "thisismyip.com",
        "ipscore.io",
        "whatismyipaddress.com",
    ]

    nonisolated enum SessionStatus: String, Sendable {
        case loading = "Loading"
        case loaded = "Loaded"
        case failed = "Failed"
        case retrying = "Retrying"
    }

    var elapsedSeconds: Int {
        Int(Date().timeIntervalSince(startedAt))
    }

    init(index: Int) {
        self.index = index
    }

    func tryNextFallback() -> Bool {
        let nextIndex = currentSiteIndex + 1
        guard nextIndex < IPScoreSession.fallbackURLs.count else { return false }
        currentSiteIndex = nextIndex
        url = IPScoreSession.fallbackURLs[nextIndex]
        usedSite = IPScoreSession.siteLabels[nextIndex]
        status = .retrying
        isLoading = true
        return true
    }
}

class IPScoreWebViewDelegate: NSObject, WKNavigationDelegate {
    let session: IPScoreSession
    private var timeoutTask: Task<Void, Never>?
    private var fallbackTimeoutTask: Task<Void, Never>?
    var onNeedRetry: (() -> Void)?

    init(session: IPScoreSession) {
        self.session = session
        super.init()
        startFallbackTimeout()
        startFinalTimeout()
    }

    private func startFallbackTimeout() {
        fallbackTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.session.status == .loading || self.session.status == .retrying else { return }
            if self.session.tryNextFallback() {
                self.onNeedRetry?()
                self.startFallbackTimeout()
            }
        }
    }

    private func startFinalTimeout() {
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard let self, self.session.status == .loading || self.session.status == .retrying else { return }
            self.session.status = .failed
            self.session.isLoading = false
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.timeoutTask?.cancel()
            self.fallbackTimeoutTask?.cancel()
            self.session.status = .loaded
            self.session.isLoading = false
            self.session.pageTitle = webView.title ?? ""
            self.session.currentURL = webView.url?.absoluteString ?? ""
            self.captureScreenshot(webView)
        }
    }

    private func captureScreenshot(_ webView: WKWebView) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let config = WKSnapshotConfiguration()
            config.rect = webView.bounds
            if let image = try? await webView.takeSnapshot(configuration: config) {
                self.session.screenshot = image
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.session.tryNextFallback() {
                self.onNeedRetry?()
            } else {
                self.timeoutTask?.cancel()
                self.fallbackTimeoutTask?.cancel()
                self.session.status = .failed
                self.session.isLoading = false
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.session.tryNextFallback() {
                self.onNeedRetry?()
            } else {
                self.timeoutTask?.cancel()
                self.fallbackTimeoutTask?.cancel()
                self.session.status = .failed
                self.session.isLoading = false
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        .allow
    }

    deinit {
        timeoutTask?.cancel()
        fallbackTimeoutTask?.cancel()
    }
}

struct IPScoreTestView: View {
    @State private var sessions: [IPScoreSession] = []
    @State private var isRunning: Bool = false
    @State private var viewMode: ViewMode = .list
    @State private var showNetworkSheet: Bool = false
    @State private var elapsedTimer: Timer?
    @State private var timerTick: Int = 0
    @State private var delegates: [UUID: IPScoreWebViewDelegate] = [:]
    @State private var showFingerprintTest: Bool = false
    @State private var currentPage: Int = 0

    private let proxyService = ProxyRotationService.shared
    private let nordService = NordVPNService.shared
    private let networkFactory = NetworkSessionFactory.shared
    private let deviceProxy = DeviceProxyService.shared
    private let logger = DebugLogger.shared
    private let sessionsPerPage = 6

    private var totalPages: Int {
        max(1, (sessions.count + sessionsPerPage - 1) / sessionsPerPage)
    }

    private var currentPageSessions: [IPScoreSession] {
        guard !sessions.isEmpty else { return [] }
        let start = currentPage * sessionsPerPage
        let end = min(start + sessionsPerPage, sessions.count)
        guard start < sessions.count else { return [] }
        return Array(sessions[start..<end])
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                if sessions.isEmpty {
                    emptyState
                } else if viewMode == .list {
                    sessionListView
                } else {
                    sessionTileView
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("IP Score Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    MainMenuButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if !sessions.isEmpty {
                            ViewModeToggle(mode: $viewMode, accentColor: .indigo)
                        }
                        NavigationLink(destination: FingerprintTestView()) {
                            Image(systemName: "fingerprint")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.purple)
                        }
                        Button {
                            showNetworkSheet = true
                        } label: {
                            Image(systemName: "network")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.indigo)
                        }
                    }
                }
            }
            .sheet(isPresented: $showNetworkSheet) {
                networkInfoSheet
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear {
            elapsedTimer?.invalidate()
            cleanupWebViews()
        }
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                let loadedCount = sessions.filter({ $0.status == .loaded }).count
                let failedCount = sessions.filter({ $0.status == .failed }).count
                let loadingCount = sessions.filter({ $0.status == .loading || $0.status == .retrying }).count

                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("\(loadedCount)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green)
                    Text("OK")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.green.opacity(0.6))
                }

                HStack(spacing: 6) {
                    Circle().fill(.yellow).frame(width: 7, height: 7)
                    Text("\(loadingCount)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.yellow)
                    Text("LOAD")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.yellow.opacity(0.6))
                }

                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("\(failedCount)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.red)
                    Text("FAIL")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.6))
                }

                Spacer()

                let mode = proxyService.connectionMode(for: .joe)
                HStack(spacing: 4) {
                    Image(systemName: mode.icon)
                        .font(.system(size: 10, weight: .bold))
                    Text(mode.label)
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                }
                .foregroundStyle(.indigo.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.indigo.opacity(0.1))
                .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentTransition(.numericText())
            .animation(.snappy, value: timerTick)

            if deviceProxy.isEnabled {
                HStack(spacing: 6) {
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.cyan)
                    Text("UNITED IP")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.cyan)
                    if let endpoint = deviceProxy.activeEndpointLabel {
                        Text(endpoint)
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.cyan.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.cyan.opacity(0.08))
            } else if deviceProxy.isMultiTunnelActive {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.mint)
                    Text("MULTI-TUNNEL")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.mint)
                    Text("\(deviceProxy.perSessionTunnelCount) IPs")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.mint.opacity(0.7))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.mint.opacity(0.08))
            }

            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)

            HStack(spacing: 10) {
                if isRunning {
                    Button {
                        stopSessions()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("STOP")
                                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        }
                        .foregroundStyle(.red)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.red.opacity(0.12))
                        .clipShape(Capsule())
                    }
                } else {
                    Button {
                        launchSessions()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text("LAUNCH 6 SESSIONS")
                                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            LinearGradient(colors: [.indigo, .cyan], startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(Capsule())
                    }
                    .sensoryFeedback(.impact(weight: .heavy), trigger: isRunning)
                }

                Spacer()

                if sessions.count > sessionsPerPage {
                    paginationControls
                }

                if !sessions.isEmpty {
                    Button {
                        cleanupWebViews()
                        sessions.removeAll()
                        delegates.removeAll()
                        isRunning = false
                        currentPage = 0
                        elapsedTimer?.invalidate()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 10, weight: .bold))
                            Text("CLEAR")
                                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.06))
                        .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }

    private var paginationControls: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.snappy) {
                    currentPage = max(0, currentPage - 1)
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(currentPage > 0 ? .indigo : .secondary.opacity(0.3))
            }
            .disabled(currentPage == 0)

            Text("\(currentPage + 1)/\(totalPages)")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(.indigo)

            Button {
                withAnimation(.snappy) {
                    currentPage = min(totalPages - 1, currentPage + 1)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(currentPage < totalPages - 1 ? .indigo : .secondary.opacity(0.3))
            }
            .disabled(currentPage >= totalPages - 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.indigo.opacity(0.1))
        .clipShape(Capsule())
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.system(size: 52))
                .foregroundStyle(
                    LinearGradient(colors: [.indigo, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .symbolEffect(.pulse.byLayer, options: .repeating)

            Text("IP Score Test")
                .font(.title2.bold())

            Text("Launch 6 concurrent sessions to verify\neach uses a different proxy or VPN address.\nFallback: thisismyip.com \u{2192} ipscore.io \u{2192} whatismyipaddress.com")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                networkInfoRow(icon: proxyService.connectionMode(for: .joe).icon, label: "Mode", value: proxyService.connectionMode(for: .joe).label)
                networkInfoRow(icon: "server.rack", label: "Nord Servers", value: "\(nordService.recommendedServers.count) loaded")
                networkInfoRow(icon: "network", label: "Proxies", value: "\(proxyService.savedProxies.count) configured")
                networkInfoRow(icon: "lock.shield.fill", label: "WireGuard", value: "\(proxyService.joeWGConfigs.count) configs")
                networkInfoRow(icon: "shield.checkered", label: "IP Routing", value: deviceProxy.ipRoutingMode.shortLabel)
                if deviceProxy.isMultiTunnelActive {
                    networkInfoRow(icon: "arrow.triangle.branch", label: "Multi-Tunnel", value: "\(deviceProxy.perSessionTunnelCount) active")
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 12))
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func networkInfoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.indigo)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    private var sessionListView: some View {
        List {
            ForEach(currentPageSessions) { session in
                IPScoreSessionRow(session: session, timerTick: timerTick)
                    .listRowBackground(Color(.secondarySystemGroupedBackground))
            }
        }
        .listStyle(.insetGrouped)
    }

    private var sessionTileView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(currentPageSessions) { session in
                    IPScoreSessionTile(session: session, timerTick: timerTick)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }

    private var networkInfoSheet: some View {
        NavigationStack {
            List {
                Section("Connection Mode") {
                    LabeledContent("Joe") { Text(proxyService.networkSummary(for: .joe)) }
                    LabeledContent("Ignition") { Text(proxyService.networkSummary(for: .ignition)) }
                }

                if deviceProxy.isEnabled {
                    Section("United IP") {
                        LabeledContent("Status") {
                            Text(deviceProxy.isActive ? "Active" : "Inactive")
                                .foregroundStyle(deviceProxy.isActive ? .green : .red)
                        }
                        if let label = deviceProxy.activeEndpointLabel {
                            LabeledContent("Endpoint") { Text(label) }
                        }
                        LabeledContent("Rotation") { Text(deviceProxy.rotationInterval.label) }
                        LabeledContent("Rotations") { Text("\(deviceProxy.rotationLog.count)") }
                    }
                }

                if deviceProxy.isMultiTunnelActive {
                    Section("Multi-Tunnel WireProxy") {
                        LabeledContent("Active Tunnels") {
                            Text("\(deviceProxy.perSessionTunnelCount)")
                                .foregroundStyle(.mint)
                        }
                        ForEach(Array(WireProxyBridge.shared.tunnelSlots.enumerated()), id: \.offset) { i, slot in
                            HStack {
                                Circle()
                                    .fill(slot.isEstablished ? .green : .red)
                                    .frame(width: 6, height: 6)
                                Text("Slot \(i)")
                                    .font(.system(.caption, design: .monospaced, weight: .bold))
                                Spacer()
                                Text(slot.serverName)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("NordVPN") {
                    LabeledContent("Profile") { Text(nordService.activeKeyProfile.rawValue) }
                    LabeledContent("Servers Loaded") { Text("\(nordService.recommendedServers.count)") }
                    LabeledContent("Has Private Key") { Text(nordService.hasPrivateKey ? "Yes" : "No").foregroundStyle(nordService.hasPrivateKey ? .green : .red) }
                }

                Section("Proxies") {
                    LabeledContent("SOCKS5") { Text("\(proxyService.savedProxies.count)") }
                    LabeledContent("Working") { Text("\(proxyService.savedProxies.filter(\.isWorking).count)") }
                }

                Section("VPN Configs") {
                    LabeledContent("OpenVPN") { Text("\(proxyService.joeVPNConfigs.count)") }
                    LabeledContent("WireGuard") { Text("\(proxyService.joeWGConfigs.count)") }
                }

                if !sessions.isEmpty {
                    Section("Session Network Assignments") {
                        ForEach(sessions) { session in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("S\(session.index)")
                                        .font(.system(.caption, design: .monospaced, weight: .bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.indigo.opacity(0.15))
                                        .clipShape(.rect(cornerRadius: 4))
                                    Text(session.networkLabel)
                                        .font(.system(.caption, design: .monospaced))
                                    Spacer()
                                    Text(session.usedSite)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.cyan)
                                }
                                if let server = session.assignedVPNServer {
                                    Text(server)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                if let ip = session.assignedVPNIP {
                                    Text(ip)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.indigo)
                                }
                                if let tunnel = session.tunnelSlotLabel {
                                    Text(tunnel)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.mint)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Network Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showNetworkSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func launchSessions() {
        cleanupWebViews()
        sessions.removeAll()
        delegates.removeAll()
        isRunning = true
        timerTick = 0
        currentPage = 0

        let connectionMode = proxyService.connectionMode(for: .joe)

        for i in 0..<sessionsPerPage {
            let session = IPScoreSession(index: i + 1)
            assignNetworkToSession(session, index: i, mode: connectionMode)
            sessions.append(session)
            createAndLoadWebView(for: session)
        }

        logger.log("IPScoreTest: launched \(sessionsPerPage) concurrent sessions - mode: \(connectionMode.label), app-wide united IP: \(deviceProxy.isEnabled), multi-tunnel: \(deviceProxy.isMultiTunnelActive)", category: .automation, level: .info)

        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                timerTick += 1
                let allDone = sessions.allSatisfy { $0.status != .loading && $0.status != .retrying }
                if allDone {
                    elapsedTimer?.invalidate()
                    isRunning = false
                    let loaded = sessions.filter { $0.status == .loaded }.count
                    let failed = sessions.filter { $0.status == .failed }.count
                    logger.log("IPScoreTest: all sessions complete - \(loaded) loaded, \(failed) failed", category: .automation, level: loaded == sessions.count ? .success : .warning)
                }
            }
        }
    }

    private func createAndLoadWebView(for session: IPScoreSession) {
        let wkConfig = WKWebViewConfiguration()
        wkConfig.websiteDataStore = .nonPersistent()

        let appWideNet = networkFactory.appWideConfig(for: .joe)
        if case .direct = appWideNet {
            networkFactory.configureWKWebView(config: wkConfig, networkConfig: session.networkConfig, target: .joe, bypassTunnel: true)
        } else {
            networkFactory.configureWKWebView(config: wkConfig, networkConfig: appWideNet, target: .joe)
        }

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 414, height: 896), configuration: wkConfig)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

        let delegate = IPScoreWebViewDelegate(session: session)
        delegate.onNeedRetry = { [weak webView, weak session] in
            guard let webView, let session else { return }
            let request = URLRequest(url: session.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: TimeoutResolver.resolveRequestTimeout(30))
            webView.load(request)
            self.logger.log("IPScoreTest: S\(session.index) retrying with \(session.usedSite)", category: .automation, level: .info)
        }
        webView.navigationDelegate = delegate
        delegates[session.id] = delegate
        session.webView = webView

        let request = URLRequest(url: session.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: TimeoutResolver.resolveRequestTimeout(30))
        webView.load(request)

        logger.log("IPScoreTest: S\(session.index) loading \(session.usedSite) via \(session.networkConfig.label)", category: .automation, level: .debug)
    }

    private func assignNetworkToSession(_ session: IPScoreSession, index: Int, mode: ConnectionMode) {
        let appNetConfig = networkFactory.appWideConfig(for: .joe)
        if case .direct = appNetConfig {
            // fall through to per-mode assignment below
        } else {
            session.networkConfig = appNetConfig
            session.networkLabel = "App-Wide: \(appNetConfig.label)"
            if case .wireGuardDNS(let wg) = appNetConfig {
                session.assignedVPNServer = wg.fileName
                session.assignedVPNIP = wg.peerEndpoint
            } else if case .openVPNProxy(let ovpn) = appNetConfig {
                session.assignedVPNServer = ovpn.fileName
                session.assignedVPNIP = ovpn.remoteHost
            } else if case .socks5(let proxy) = appNetConfig {
                session.assignedProxy = proxy.displayString
            }
            return
        }

        switch mode {
        case .direct:
            session.networkLabel = "Direct (No Proxy)"
            session.networkConfig = .direct

        case .proxy:
            if let proxy = proxyService.nextWorkingProxy(for: .joe) {
                session.assignedProxy = proxy.displayString
                session.networkLabel = "SOCKS5 \(proxy.host):\(proxy.port)"
                session.networkConfig = .socks5(proxy)
            } else if !proxyService.savedProxies.isEmpty {
                let proxy = proxyService.savedProxies[index % proxyService.savedProxies.count]
                session.assignedProxy = proxy.displayString
                session.networkLabel = "SOCKS5 \(proxy.host):\(proxy.port)"
                session.networkConfig = .socks5(proxy)
            } else {
                session.networkLabel = "Direct (no proxies)"
                session.networkConfig = .direct
            }

        case .wireguard:
            if let wg = proxyService.nextEnabledWGConfig(for: .joe) {
                session.assignedVPNServer = wg.fileName
                session.assignedVPNIP = wg.peerEndpoint
                session.networkLabel = "WG \(wg.fileName)"
                session.networkConfig = .wireGuardDNS(wg)
                if let server = nordService.recommendedServers.first(where: { $0.hostname == wg.fileName }) {
                    session.assignedVPNCountry = server.country
                }
                if deviceProxy.isMultiTunnelActive {
                    let bridge = WireProxyBridge.shared
                    if let slot = bridge.nextTunnelSlot() {
                        session.tunnelSlotLabel = "Tunnel \(slot.index): \(slot.serverName)"
                    }
                }
            } else {
                session.networkLabel = "WG (none available)"
                session.networkConfig = .direct
            }

        case .openvpn:
            if let ovpn = proxyService.nextEnabledOVPNConfig(for: .joe) {
                session.assignedVPNServer = ovpn.fileName
                session.assignedVPNIP = ovpn.remoteHost
                session.networkLabel = "OVPN \(ovpn.fileName)"
                session.networkConfig = .openVPNProxy(ovpn)
                if let server = nordService.recommendedServers.first(where: { $0.hostname == ovpn.remoteHost || $0.hostname == ovpn.fileName }) {
                    session.assignedVPNCountry = server.country
                }
            } else {
                session.networkLabel = "OVPN (none available)"
                session.networkConfig = .direct
            }

        case .dns:
            if !nordService.recommendedServers.isEmpty {
                let server = nordService.recommendedServers[index % nordService.recommendedServers.count]
                session.assignedVPNServer = server.hostname
                session.assignedVPNIP = server.station
                session.assignedVPNCountry = server.country
                session.networkLabel = "Nord \(server.hostname.prefix(20))"
            } else {
                session.networkLabel = "Direct"
            }
            session.networkConfig = .direct

        case .nodeMaven:
            let nm = NodeMavenService.shared
            if let proxy = nm.generateProxyConfigForSession(index) {
                session.assignedProxy = proxy.displayString
                session.networkLabel = "NodeMaven \(nm.country.flagEmoji)"
                session.networkConfig = .socks5(proxy)
            } else {
                session.networkLabel = "NodeMaven (not configured)"
                session.networkConfig = .direct
            }

        case .hybrid:
            let hybridConfig = HybridNetworkingService.shared.nextHybridConfig(for: .joe)
            session.networkLabel = "Hybrid \(hybridConfig.label)"
            session.networkConfig = hybridConfig
        }
    }

    private func stopSessions() {
        isRunning = false
        elapsedTimer?.invalidate()
        for session in sessions where session.status == .loading || session.status == .retrying {
            session.status = .failed
            session.webView?.stopLoading()
        }
        logger.log("IPScoreTest: sessions stopped by user", category: .automation, level: .warning)
    }

    private func cleanupWebViews() {
        for session in sessions {
            session.webView?.stopLoading()
            session.webView?.navigationDelegate = nil
            session.webView = nil
        }
        delegates.removeAll()
    }
}

struct IPScoreSessionRow: View {
    let session: IPScoreSession
    let timerTick: Int

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if let screenshot = session.screenshot {
                    Color(.secondarySystemGroupedBackground)
                        .frame(width: 56, height: 44)
                        .overlay {
                            Image(uiImage: screenshot)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .allowsHitTesting(false)
                        }
                        .clipShape(.rect(cornerRadius: 8))
                        .overlay(alignment: .bottomTrailing) {
                            Text("S\(session.index)")
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(statusColor.opacity(0.8))
                                .clipShape(.rect(cornerRadius: 3))
                                .offset(x: 2, y: 2)
                        }
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(statusColor.opacity(0.12))
                            .frame(width: 56, height: 44)
                        if session.status == .loading || session.status == .retrying {
                            ProgressView().controlSize(.mini).tint(statusColor)
                        } else {
                            Text("S\(session.index)")
                                .font(.system(size: 14, weight: .black, design: .monospaced))
                                .foregroundStyle(statusColor)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(session.usedSite)
                            .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                        Text(session.status.rawValue)
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(statusColor)
                    }

                    Text(session.networkLabel)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let server = session.assignedVPNServer {
                        HStack(spacing: 4) {
                            Image(systemName: "shield.checkered")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.indigo)
                            Text("Nord: \(server)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.indigo.opacity(0.8))
                            if let country = session.assignedVPNCountry {
                                Text("(\(country))")
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.indigo.opacity(0.5))
                            }
                        }
                        .lineLimit(1)
                    }

                    if let ip = session.assignedVPNIP {
                        HStack(spacing: 4) {
                            Image(systemName: "globe")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.cyan.opacity(0.7))
                            Text(ip)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.cyan.opacity(0.7))
                        }
                    }

                    if let proxy = session.assignedProxy {
                        HStack(spacing: 4) {
                            Image(systemName: "network")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.orange.opacity(0.7))
                            Text(proxy)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.orange.opacity(0.7))
                        }
                        .lineLimit(1)
                    }

                    if let tunnel = session.tunnelSlotLabel {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.mint.opacity(0.7))
                            Text(tunnel)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.mint.opacity(0.7))
                        }
                        .lineLimit(1)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    if session.status == .loading || session.status == .retrying {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.indigo)
                    } else {
                        Image(systemName: session.status == .loaded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(statusColor)
                    }
                    Text("\(session.elapsedSeconds)s")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }

            if session.status == .loading || session.status == .retrying {
                ProgressView(value: min(Double(session.elapsedSeconds) / 30.0, 0.95))
                    .tint(session.status == .retrying ? .orange : .indigo)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch session.status {
        case .loading: .indigo
        case .loaded: .green
        case .failed: .red
        case .retrying: .orange
        }
    }
}

struct IPScoreSessionTile: View {
    let session: IPScoreSession
    let timerTick: Int

    var body: some View {
        VStack(spacing: 0) {
            screenshotArea

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("S\(session.index)")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.12))
                        .clipShape(.rect(cornerRadius: 4))

                    Text(session.usedSite)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.cyan.opacity(0.8))
                        .lineLimit(1)

                    Spacer()

                    Text("\(session.elapsedSeconds)s")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }

                Text(session.networkLabel)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let server = session.assignedVPNServer {
                    HStack(spacing: 3) {
                        Image(systemName: "shield.checkered")
                            .font(.system(size: 7, weight: .bold))
                        Text(String(server.prefix(18)))
                            .font(.system(size: 7, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.indigo.opacity(0.8))
                    .lineLimit(1)
                }

                if let proxy = session.assignedProxy {
                    HStack(spacing: 3) {
                        Image(systemName: "network")
                            .font(.system(size: 7, weight: .bold))
                        Text(proxy)
                            .font(.system(size: 7, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.orange.opacity(0.7))
                    .lineLimit(1)
                }

                if let tunnel = session.tunnelSlotLabel {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 7, weight: .bold))
                        Text(tunnel)
                            .font(.system(size: 7, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.mint.opacity(0.7))
                    .lineLimit(1)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadii: .init(bottomLeading: 12, bottomTrailing: 12)))
        }
    }

    private var screenshotArea: some View {
        Group {
            if let screenshot = session.screenshot {
                Color(.secondarySystemGroupedBackground)
                    .frame(height: 110)
                    .overlay {
                        Image(uiImage: screenshot)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .allowsHitTesting(false)
                    }
                    .clipShape(.rect(cornerRadii: .init(topLeading: 12, topTrailing: 12)))
                    .overlay(alignment: .topTrailing) {
                        statusBadge
                            .padding(6)
                    }
            } else {
                Color(.tertiarySystemFill)
                    .frame(height: 110)
                    .overlay {
                        if session.status == .loading || session.status == .retrying {
                            VStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.indigo)
                                Text(session.status == .retrying ? "Retrying..." : "Loading...")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        } else if session.status == .failed {
                            VStack(spacing: 6) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.red.opacity(0.6))
                                Text("Failed")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.red.opacity(0.6))
                            }
                        } else {
                            Image(systemName: "photo")
                                .font(.title2)
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .clipShape(.rect(cornerRadii: .init(topLeading: 12, topTrailing: 12)))
                    .overlay(alignment: .topTrailing) {
                        statusBadge
                            .padding(6)
                    }
            }
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 3) {
            Circle().fill(statusColor).frame(width: 5, height: 5)
            Text(session.status.rawValue)
                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    private var statusColor: Color {
        switch session.status {
        case .loading: .indigo
        case .loaded: .green
        case .failed: .red
        case .retrying: .orange
        }
    }
}
