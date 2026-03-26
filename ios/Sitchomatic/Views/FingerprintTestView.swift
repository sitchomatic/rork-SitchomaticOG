import Foundation
import SwiftUI
import WebKit

@Observable
class FPTestSession: Identifiable {
    let id: UUID = UUID()
    let index: Int
    let profileSlot: Int
    let profileLabel: String
    var status: FPStatus = .pending
    var botDetected: Bool?
    var botKind: String?
    var suspectScore: Int = 0
    var componentResults: [String] = []
    var elapsedMs: Int = 0
    var webView: WKWebView?
    var startedAt: Date?

    nonisolated enum FPStatus: String, Sendable {
        case pending = "Pending"
        case loading = "Loading"
        case analyzing = "Analyzing"
        case passed = "Pass"
        case failed = "Fail"
        case error = "Error"
    }

    var passed: Bool { status == .passed }
    var scoreColor: Color {
        switch suspectScore {
        case 0: .green
        case 1...3: .green
        case 4...6: .yellow
        default: .red
        }
    }

    init(index: Int, profileSlot: Int, profileLabel: String) {
        self.index = index
        self.profileSlot = profileSlot
        self.profileLabel = profileLabel
    }
}

class FPTestMessageHandler: NSObject, WKScriptMessageHandler {
    let session: FPTestSession
    var onResult: ((FPTestSession) -> Void)?

    init(session: FPTestSession) {
        self.session = session
        super.init()
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in
            guard let dict = message.body as? [String: Any] else {
                session.status = .error
                session.componentResults = ["Invalid response from BotD"]
                onResult?(session)
                return
            }

            let bot = dict["bot"] as? Bool ?? false
            let botKind = dict["botKind"] as? String ?? "unknown"
            let components = dict["components"] as? [String] ?? []
            let score = dict["suspectScore"] as? Int ?? 0

            session.botDetected = bot
            session.botKind = botKind
            session.suspectScore = score
            session.componentResults = components

            if let started = session.startedAt {
                session.elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            }

            session.status = score <= 3 ? .passed : .failed
            onResult?(session)
        }
    }
}

struct FingerprintTestView: View {
    @State private var sessions: [FPTestSession] = []
    @State private var isRunning: Bool = false
    @State private var completedCount: Int = 0
    @State private var messageHandlers: [UUID: FPTestMessageHandler] = [:]
    @State private var batchSize: Int = 6
    @State private var timerTick: Int = 0
    @State private var elapsedTimer: Timer?
    @State private var currentPage: Int = 0

    private let stealth = PPSRStealthService.shared
    private let networkFactory = NetworkSessionFactory.shared
    private let deviceProxy = DeviceProxyService.shared
    private let proxyService = ProxyRotationService.shared
    private let logger = DebugLogger.shared
    private let sessionsPerPage = 6

    private var totalPages: Int {
        max(1, (sessions.count + sessionsPerPage - 1) / sessionsPerPage)
    }

    private var currentPageSessions: [FPTestSession] {
        guard !sessions.isEmpty else { return [] }
        let start = currentPage * sessionsPerPage
        let end = min(start + sessionsPerPage, sessions.count)
        guard start < sessions.count else { return [] }
        return Array(sessions[start..<end])
    }

    var body: some View {
        VStack(spacing: 0) {
            summaryBar
            controlBar

            if sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Fingerprint.com Test")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            cleanup()
        }
    }

    private var summaryBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                let passCount = sessions.filter({ $0.status == .passed }).count
                let failCount = sessions.filter({ $0.status == .failed }).count
                let errorCount = sessions.filter({ $0.status == .error }).count
                let runningCount = sessions.filter({ $0.status == .loading || $0.status == .analyzing }).count

                scorePill(count: passCount, label: "PASS", color: .green)
                scorePill(count: failCount, label: "FAIL", color: .red)
                scorePill(count: errorCount, label: "ERR", color: .orange)
                scorePill(count: runningCount, label: "RUN", color: .cyan)

                Spacer()

                Text("\(completedCount)/\(sessions.count)")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .animation(.snappy, value: timerTick)

            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
        }
    }

    private func scorePill(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                .foregroundStyle(color.opacity(0.6))
        }
    }

    private var controlBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if isRunning {
                    Button {
                        stopTest()
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
                        launchTest()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text("TEST ALL \(stealth.profileCount) PROFILES")
                                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(Capsule())
                    }
                    .sensoryFeedback(.impact(weight: .heavy), trigger: isRunning)
                }

                Spacer()

                if sessions.count > sessionsPerPage {
                    fpPaginationControls
                }

                HStack(spacing: 6) {
                    Text("BATCH")
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $batchSize) {
                        Text("4").tag(4)
                        Text("6").tag(6)
                        Text("8").tag(8)
                        Text("12").tag(12)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }

                if !sessions.isEmpty {
                    Button {
                        cleanup()
                        sessions.removeAll()
                        messageHandlers.removeAll()
                        completedCount = 0
                        currentPage = 0
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .background(.white.opacity(0.06))
                            .clipShape(Circle())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)

            Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
        }
    }

    private var fpPaginationControls: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.snappy) {
                    currentPage = max(0, currentPage - 1)
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(currentPage > 0 ? .purple : .secondary.opacity(0.3))
            }
            .disabled(currentPage == 0)

            Text("\(currentPage + 1)/\(totalPages)")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(.purple)

            Button {
                withAnimation(.snappy) {
                    currentPage = min(totalPages - 1, currentPage + 1)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(currentPage < totalPages - 1 ? .purple : .secondary.opacity(0.3))
            }
            .disabled(currentPage >= totalPages - 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.purple.opacity(0.1))
        .clipShape(Capsule())
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "fingerprint")
                .font(.system(size: 52))
                .foregroundStyle(
                    LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .symbolEffect(.pulse.byLayer, options: .repeating)

            Text("Fingerprint.com Bot Detection")
                .font(.title2.bold())

            Text("Tests each stealth profile against fingerprint.com's\nopen-source BotD library to verify bot detection\nscores are 3 or lower (undetectable).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                infoRow(icon: "person.2.fill", label: "Profiles", value: "\(stealth.profileCount)")
                infoRow(icon: "target", label: "Target Score", value: "\u{2264} 3")
                infoRow(icon: "shield.checkered", label: "IP Mode", value: deviceProxy.ipRoutingMode.shortLabel)
                infoRow(icon: "network", label: "Connection", value: proxyService.connectionMode(for: .joe).label)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 12))
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.purple)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
        }
    }

    private var sessionList: some View {
        List {
            ForEach(currentPageSessions) { session in
                FPSessionRow(session: session, timerTick: timerTick)
                    .listRowBackground(Color(.secondarySystemGroupedBackground))
            }
        }
        .listStyle(.insetGrouped)
    }

    private func launchTest() {
        cleanup()
        sessions.removeAll()
        messageHandlers.removeAll()
        completedCount = 0
        isRunning = true
        timerTick = 0
        currentPage = 0

        let totalProfiles = stealth.profileCount

        for i in 0..<totalProfiles {
            let profile = stealth.profileForSlot(i)
            let label = profileDescription(profile, slot: i)
            let session = FPTestSession(index: i + 1, profileSlot: i, profileLabel: label)
            sessions.append(session)
        }

        logger.log("FingerprintTest: launching \(totalProfiles) profile tests in batches of \(batchSize)", category: .fingerprint, level: .info)

        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                timerTick += 1
                let allDone = sessions.allSatisfy { s in
                    s.status == .passed || s.status == .failed || s.status == .error
                }
                if allDone && isRunning {
                    elapsedTimer?.invalidate()
                    isRunning = false
                    let passed = sessions.filter(\.passed).count
                    let avgScore = sessions.isEmpty ? 0 : sessions.reduce(0) { $0 + $1.suspectScore } / sessions.count
                    logger.log("FingerprintTest: complete \u{2014} \(passed)/\(totalProfiles) passed, avg score: \(avgScore)", category: .fingerprint, level: passed == totalProfiles ? .success : .warning)
                }
            }
        }

        launchNextBatch()
    }

    private func launchNextBatch() {
        let pending = sessions.filter { $0.status == .pending }
        let running = sessions.filter { $0.status == .loading || $0.status == .analyzing }

        let slotsAvailable = batchSize - running.count
        guard slotsAvailable > 0 else { return }

        let tolaunch = Array(pending.prefix(slotsAvailable))
        for session in tolaunch {
            session.status = .loading
            session.startedAt = Date()
            createAndTestWebView(for: session)
        }
    }

    private func createAndTestWebView(for session: FPTestSession) {
        let profile = stealth.profileForSlot(session.profileSlot)

        let wkConfig = WKWebViewConfiguration()
        wkConfig.websiteDataStore = .nonPersistent()
        wkConfig.preferences.javaScriptCanOpenWindowsAutomatically = true
        wkConfig.defaultWebpagePreferences.allowsContentJavaScript = true

        let stealthScript = stealth.createStealthUserScript(profile: profile)
        wkConfig.userContentController.addUserScript(stealthScript)

        let handler = FPTestMessageHandler(session: session)
        handler.onResult = { completedSession in
            self.completedCount = self.sessions.filter { s in
                s.status == .passed || s.status == .failed || s.status == .error
            }.count
            self.cleanupWebView(for: completedSession)
            self.launchNextBatch()
        }
        wkConfig.userContentController.add(handler, name: "fpResult")
        messageHandlers[session.id] = handler

        let appWideNet = networkFactory.appWideConfig(for: .joe)
        networkFactory.configureWKWebView(config: wkConfig, networkConfig: appWideNet, target: .joe)

        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: CGSize(width: profile.viewport.width, height: profile.viewport.height)),
            configuration: wkConfig
        )
        webView.customUserAgent = profile.userAgent
        session.webView = webView

        let html = buildTestHTML()
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com"))

        logger.log("FingerprintTest: P\(session.index) loading BotD test \u{2014} \(session.profileLabel)", category: .fingerprint, level: .debug)
    }

    private func buildTestHTML() -> String {
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>BotD Test</title></head><body>
        <p id="status">Loading BotD...</p>
        <script>
        (async function() {
            try {
                document.getElementById('status').textContent = 'Loading BotD library...';
                var module = await import('https://openfpcdn.io/botd/v2');
                var botd = await module.load();
                document.getElementById('status').textContent = 'Running detection...';
                var result = await botd.detect();

                var score = 0;
                var components = [];

                if (result.bot) {
                    score += 7;
                    components.push('+7 bot detected: ' + (result.botKind || 'unknown'));
                }

                // Additional client-side checks matching FP suspect score weights
                // Check webdriver
                if (navigator.webdriver === true) {
                    score += 7;
                    components.push('+7 webdriver=true');
                }

                // Check property tampering (matches FP Anti-detect Browser weight=8)
                var tamperCount = 0;
                var propsToCheck = ['webdriver','language','languages','platform','hardwareConcurrency','deviceMemory','maxTouchPoints'];
                for (var i = 0; i < propsToCheck.length; i++) {
                    try {
                        var desc = Object.getOwnPropertyDescriptor(navigator, propsToCheck[i]);
                        if (desc && desc.get) {
                            var fnStr = desc.get.toString();
                            if (fnStr.indexOf('[native code]') === -1) {
                                tamperCount++;
                            }
                        }
                    } catch(e) {}
                }
                if (tamperCount >= 3) {
                    score += Math.min(tamperCount, 4);
                    components.push('+' + Math.min(tamperCount, 4) + ' property tampering (' + tamperCount + '/7 non-native)');
                }

                // Check automation flags
                var autoFlags = ['__nightmare','_phantom','callPhantom','__selenium_evaluate','__webdriver_evaluate'];
                for (var j = 0; j < autoFlags.length; j++) {
                    if (window[autoFlags[j]] !== undefined) {
                        score += 7;
                        components.push('+7 automation flag: ' + autoFlags[j]);
                        break;
                    }
                }

                // Incognito heuristic (FP weight=4) — check storage quota
                try {
                    if (navigator.storage && navigator.storage.estimate) {
                        var est = await navigator.storage.estimate();
                        if (est.quota && est.quota < 120000000) {
                            score += 4;
                            components.push('+4 possible incognito (low storage quota)');
                        }
                    }
                } catch(e) {}

                // Canvas consistency check
                try {
                    var c1 = document.createElement('canvas');
                    c1.width = 200; c1.height = 50;
                    var ctx1 = c1.getContext('2d');
                    ctx1.textBaseline = 'top';
                    ctx1.font = '14px Arial';
                    ctx1.fillStyle = '#f60';
                    ctx1.fillRect(125, 1, 62, 20);
                    ctx1.fillStyle = '#069';
                    ctx1.fillText('BotDTest', 2, 15);
                    var d1 = c1.toDataURL();
                    var c2 = document.createElement('canvas');
                    c2.width = 200; c2.height = 50;
                    var ctx2 = c2.getContext('2d');
                    ctx2.textBaseline = 'top';
                    ctx2.font = '14px Arial';
                    ctx2.fillStyle = '#f60';
                    ctx2.fillRect(125, 1, 62, 20);
                    ctx2.fillStyle = '#069';
                    ctx2.fillText('BotDTest', 2, 15);
                    var d2 = c2.toDataURL();
                    if (d1 !== d2) {
                        score += 3;
                        components.push('+3 canvas inconsistency');
                    }
                } catch(e) {}

                if (components.length === 0) {
                    components.push('All checks clean');
                }

                document.getElementById('status').textContent = 'Score: ' + score + (score <= 3 ? ' PASS' : ' FAIL');

                window.webkit.messageHandlers.fpResult.postMessage({
                    bot: result.bot || false,
                    botKind: result.botKind || 'none',
                    suspectScore: score,
                    components: components
                });
            } catch(err) {
                document.getElementById('status').textContent = 'Error: ' + err.message;
                window.webkit.messageHandlers.fpResult.postMessage({
                    bot: false,
                    botKind: 'error',
                    suspectScore: -1,
                    components: ['BotD load error: ' + err.message]
                });
            }
        })();
        </script></body></html>
        """
    }

    private func profileDescription(_ profile: PPSRStealthService.SessionProfile, slot: Int) -> String {
        let device: String
        let vp = profile.viewport
        switch (vp.width, vp.height) {
        case (440, 956): device = "iPhone 16 Pro Max"
        case (430, 932): device = "iPhone 16 Plus"
        case (402, 874): device = "iPhone 16 Pro"
        case (420, 912): device = "iPhone Air"
        case (393, 852): device = "iPhone 15/16"
        case (390, 844): device = "iPhone 14/13/12"
        case (428, 926): device = "iPhone 13 Pro Max"
        case (834, 1194): device = "iPad Pro 11\""
        case (1440, 900): device = "MacBook Air"
        case (1512, 982): device = "MacBook Pro"
        default: device = "Device \(vp.width)x\(vp.height)"
        }

        let os = profile.userAgent.contains("Version/26.0") ? "iOS 26" :
                 profile.userAgent.contains("18_4") ? "iOS 18.4" :
                 profile.userAgent.contains("18_3") ? "iOS 18.3" :
                 profile.userAgent.contains("18_2") ? "iOS 18.2" :
                 profile.userAgent.contains("18_1") ? "iOS 18.1" :
                 profile.userAgent.contains("17_7") ? "iOS 17.7" :
                 profile.userAgent.contains("17_6") ? "iOS 17.6" :
                 profile.userAgent.contains("17_5") ? "iOS 17.5" :
                 profile.userAgent.contains("17_4") ? "iOS 17.4" :
                 profile.userAgent.contains("14_7") ? "macOS 14.7" :
                 profile.userAgent.contains("10_15") ? "macOS 13.6" :
                 profile.userAgent.contains("OS 18_4") && profile.platform == "iPad" ? "iPadOS 18.4" : "Unknown"

        return "\(device) \u{2022} \(os) \u{2022} \(profile.language)"
    }

    private func stopTest() {
        isRunning = false
        elapsedTimer?.invalidate()
        for session in sessions where session.status == .loading || session.status == .analyzing || session.status == .pending {
            session.status = .error
            session.componentResults = ["Stopped by user"]
            cleanupWebView(for: session)
        }
        logger.log("FingerprintTest: stopped by user", category: .fingerprint, level: .warning)
    }

    private func cleanupWebView(for session: FPTestSession) {
        session.webView?.stopLoading()
        if let handler = messageHandlers[session.id] {
            session.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "fpResult")
            messageHandlers.removeValue(forKey: session.id)
            _ = handler
        }
        session.webView?.navigationDelegate = nil
        session.webView = nil
    }

    private func cleanup() {
        elapsedTimer?.invalidate()
        isRunning = false
        for session in sessions {
            cleanupWebView(for: session)
        }
    }
}

struct FPSessionRow: View {
    let session: FPTestSession
    let timerTick: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(statusColor.opacity(0.12))
                        .frame(width: 44, height: 44)

                    if session.status == .loading || session.status == .analyzing {
                        ProgressView().controlSize(.small).tint(statusColor)
                    } else {
                        VStack(spacing: 2) {
                            Text("P\(session.index)")
                                .font(.system(size: 12, weight: .black, design: .monospaced))
                                .foregroundStyle(statusColor)
                            if session.status == .passed || session.status == .failed {
                                Text("\(session.suspectScore)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(session.scoreColor)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(session.profileLabel)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .lineLimit(1)

                        Spacer()

                        Text(session.status.rawValue)
                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                            .foregroundStyle(statusColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(statusColor.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    if session.status == .passed || session.status == .failed || session.status == .error {
                        HStack(spacing: 8) {
                            HStack(spacing: 3) {
                                Image(systemName: "target")
                                    .font(.system(size: 9, weight: .bold))
                                Text("Score: \(session.suspectScore)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                            }
                            .foregroundStyle(session.scoreColor)

                            if let bot = session.botDetected {
                                HStack(spacing: 3) {
                                    Image(systemName: bot ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                                        .font(.system(size: 9, weight: .bold))
                                    Text(bot ? "BOT" : "HUMAN")
                                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                }
                                .foregroundStyle(bot ? .red : .green)
                            }

                            if session.elapsedMs > 0 {
                                Text("\(session.elapsedMs)ms")
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !session.componentResults.isEmpty && (session.status == .passed || session.status == .failed || session.status == .error) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(session.componentResults.enumerated()), id: \.offset) { _, component in
                                Text(component)
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .foregroundStyle(component.hasPrefix("+") ? .orange : .secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch session.status {
        case .pending: .secondary
        case .loading: .cyan
        case .analyzing: .purple
        case .passed: .green
        case .failed: .red
        case .error: .orange
        }
    }
}
