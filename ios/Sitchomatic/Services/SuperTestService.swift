import Foundation
import Observation
import SwiftUI
import WebKit

nonisolated enum SuperTestConnectionType: String, CaseIterable, Sendable, Identifiable {
    case fingerprint = "Fingerprint"
    case wireproxyWebView = "WireProxy WebView"
    case joeURLs = "Joe URLs"
    case ignitionURLs = "Ignition URLs"
    case ppsrConnection = "PPSR"
    case dnsServers = "DNS Servers"
    case socks5Proxies = "SOCKS5 Proxies"
    case openvpnProfiles = "OpenVPN"
    case wireguardProfiles = "WireGuard"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .fingerprint: "fingerprint"
        case .wireproxyWebView: "globe.badge.chevron.backward"
        case .joeURLs: "suit.spade.fill"
        case .ignitionURLs: "flame.fill"
        case .ppsrConnection: "car.side.fill"
        case .dnsServers: "lock.shield.fill"
        case .socks5Proxies: "network"
        case .openvpnProfiles: "shield.lefthalf.filled"
        case .wireguardProfiles: "lock.trianglebadge.exclamationmark.fill"
        }
    }

    var color: Color {
        switch self {
        case .fingerprint: .purple
        case .wireproxyWebView: .teal
        case .joeURLs: .green
        case .ignitionURLs: .orange
        case .ppsrConnection: .cyan
        case .dnsServers: .blue
        case .socks5Proxies: .red
        case .openvpnProfiles: .indigo
        case .wireguardProfiles: .purple
        }
    }
}

nonisolated enum SuperTestPhase: String, Sendable, CaseIterable, Identifiable {
    case idle = "Idle"
    case fingerprint = "Fingerprint Detection"
    case wireproxyWebView = "WireProxy WebView"
    case joeURLs = "Joe Fortune URLs"
    case ignitionURLs = "Ignition URLs"
    case ppsrConnection = "PPSR Connection"
    case dnsServers = "DNS Servers"
    case socks5Proxies = "SOCKS5 Proxies"
    case openvpnProfiles = "OpenVPN Profiles"
    case wireguardProfiles = "WireGuard Profiles"
    case complete = "Complete"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .idle: "circle"
        case .fingerprint: "fingerprint"
        case .wireproxyWebView: "globe.badge.chevron.backward"
        case .joeURLs: "suit.spade.fill"
        case .ignitionURLs: "flame.fill"
        case .ppsrConnection: "car.side.fill"
        case .dnsServers: "lock.shield.fill"
        case .socks5Proxies: "network"
        case .openvpnProfiles: "shield.lefthalf.filled"
        case .wireguardProfiles: "lock.trianglebadge.exclamationmark.fill"
        case .complete: "checkmark.seal.fill"
        }
    }

    var color: String {
        switch self {
        case .idle: "secondary"
        case .fingerprint: "purple"
        case .wireproxyWebView: "teal"
        case .joeURLs: "green"
        case .ignitionURLs: "orange"
        case .ppsrConnection: "cyan"
        case .dnsServers: "blue"
        case .socks5Proxies: "red"
        case .openvpnProfiles: "indigo"
        case .wireguardProfiles: "purple"
        case .complete: "green"
        }
    }
}

nonisolated struct SuperTestItemResult: Identifiable, Sendable {
    let id: UUID
    let name: String
    let category: SuperTestPhase
    let passed: Bool
    let latencyMs: Int?
    let detail: String
    let timestamp: Date

    init(name: String, category: SuperTestPhase, passed: Bool, latencyMs: Int? = nil, detail: String) {
        self.id = UUID()
        self.name = name
        self.category = category
        self.passed = passed
        self.latencyMs = latencyMs
        self.detail = detail
        self.timestamp = Date()
    }
}

nonisolated enum DiagnosticSeverity: String, Sendable {
    case critical
    case warning
    case info
    case success
}

nonisolated struct DiagnosticFinding: Identifiable, Sendable {
    let id: UUID
    let severity: DiagnosticSeverity
    let title: String
    let explanation: String
    let fixAction: String?
    let autoFixAvailable: Bool
    let category: SuperTestPhase

    init(severity: DiagnosticSeverity, title: String, explanation: String, fixAction: String? = nil, autoFixAvailable: Bool = false, category: SuperTestPhase) {
        self.id = UUID()
        self.severity = severity
        self.title = title
        self.explanation = explanation
        self.fixAction = fixAction
        self.autoFixAvailable = autoFixAvailable
        self.category = category
    }
}

nonisolated struct SuperTestReport: Sendable {
    let results: [SuperTestItemResult]
    let fingerprintScore: Int?
    let fingerprintPassed: Bool
    let totalTested: Int
    let totalPassed: Int
    let totalFailed: Int
    let totalDisabled: Int
    let totalEnabled: Int
    let duration: TimeInterval
    let timestamp: Date
    let diagnostics: [DiagnosticFinding]

    var passRate: Double {
        guard totalTested > 0 else { return 0 }
        return Double(totalPassed) / Double(totalTested)
    }

    var formattedPassRate: String {
        String(format: "%.0f%%", passRate * 100)
    }

    var formattedDuration: String {
        if duration < 60 { return String(format: "%.1fs", duration) }
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return "\(mins)m \(secs)s"
    }

    var criticalCount: Int { diagnostics.filter { $0.severity == .critical }.count }
    var warningCount: Int { diagnostics.filter { $0.severity == .warning }.count }
    var autoFixableCount: Int { diagnostics.filter { $0.autoFixAvailable }.count }
}

@Observable
@MainActor
class SuperTestService {
    static let shared = SuperTestService()
    private let logger = DebugLogger.shared

    var isRunning: Bool = false
    var currentPhase: SuperTestPhase = .idle
    var progress: Double = 0
    var currentItem: String = ""
    var results: [SuperTestItemResult] = []
    var logs: [PPSRLogEntry] = []
    var lastReport: SuperTestReport?
    var phaseProgress: [SuperTestPhase: (total: Int, done: Int)] = [:]

    var selectedConnectionTypes: Set<SuperTestConnectionType> = Set(SuperTestConnectionType.allCases)
    var diagnosticFindings: [DiagnosticFinding] = []
    var autoRepairLog: [String] = []
    var isAutoRepairing: Bool = false

    private var testTask: Task<Void, Never>?

    private let urlRotation = LoginURLRotationService.shared
    private let proxyService = ProxyRotationService.shared
    private let dohService = PPSRDoHService.shared
    private let diagnostics = PPSRConnectionDiagnosticService.shared
    private let protocolTester = VPNProtocolTestService.shared

    private let networkFactory = NetworkSessionFactory.shared
    private let deviceProxy = DeviceProxyService.shared
    private let wireProxyBridge = WireProxyBridge.shared
    private let localProxy = LocalProxyServer.shared

    var phaseSummary: [(phase: SuperTestPhase, passed: Int, failed: Int)] {
        let phases = enabledPhases.isEmpty
            ? [SuperTestPhase.fingerprint, .wireproxyWebView, .joeURLs, .ignitionURLs, .ppsrConnection, .dnsServers, .socks5Proxies, .openvpnProfiles, .wireguardProfiles]
            : enabledPhases
        return phases.map { phase in
            let phaseResults = results.filter { $0.category == phase }
            let passed = phaseResults.filter(\.passed).count
            let failed = phaseResults.filter { !$0.passed }.count
            return (phase, passed, failed)
        }
    }

    var enabledPhases: [SuperTestPhase] {
        var phases: [SuperTestPhase] = []
        if selectedConnectionTypes.contains(.fingerprint) { phases.append(.fingerprint) }
        if selectedConnectionTypes.contains(.wireproxyWebView) { phases.append(.wireproxyWebView) }
        if selectedConnectionTypes.contains(.joeURLs) { phases.append(.joeURLs) }
        if selectedConnectionTypes.contains(.ignitionURLs) { phases.append(.ignitionURLs) }
        if selectedConnectionTypes.contains(.ppsrConnection) { phases.append(.ppsrConnection) }
        if selectedConnectionTypes.contains(.dnsServers) { phases.append(.dnsServers) }
        if selectedConnectionTypes.contains(.socks5Proxies) { phases.append(.socks5Proxies) }
        if selectedConnectionTypes.contains(.openvpnProfiles) { phases.append(.openvpnProfiles) }
        if selectedConnectionTypes.contains(.wireguardProfiles) { phases.append(.wireguardProfiles) }
        return phases
    }

    private func runPreTestNetworkCheck() async -> (passed: Bool, detail: String) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: URL(string: "https://api.ipify.org?format=json")!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ip = json["ip"] as? String {
                    return (true, "Network OK — IP: \(ip)")
                }
                return (true, "Network OK — HTTP 200")
            }
            return (false, "Network check failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        } catch {
            return (false, "Network check failed: \(error.localizedDescription)")
        }
    }

    func startSuperTest() {
        guard !isRunning else { return }

        isRunning = true
        currentPhase = .idle
        progress = 0
        results.removeAll()
        logs.removeAll()
        phaseProgress.removeAll()
        currentItem = ""

        let activeTypes = selectedConnectionTypes
        let typeNames = activeTypes.map(\.rawValue).sorted().joined(separator: ", ")
        addLog("SUPER TEST — Starting with: \(typeNames)")
        logger.startSession("supertest", category: .superTest, message: "SUPER TEST starting with: \(typeNames)")

        let startTime = Date()
        let totalPhases = max(activeTypes.count, 1)

        testTask = Task {
            addLog("Running pre-test network check...")
            let preCheck = await runPreTestNetworkCheck()
            if !preCheck.passed {
                addLog("PRE-TEST FAILED: \(preCheck.detail) — aborting super test", level: .error)
                logger.log("Super Test pre-test FAILED: \(preCheck.detail)", category: .superTest, level: .error, sessionId: "supertest")
                finalize(startTime: startTime)
                return
            }
            addLog("Pre-test passed: \(preCheck.detail)", level: .success)
            var completed = 0

            if activeTypes.contains(.fingerprint) {
                await runFingerprintTest()
                completed += 1
                updateProgress(Double(completed) / Double(totalPhases))
                if Task.isCancelled { finalize(startTime: startTime); return }
            }

            if activeTypes.contains(.wireproxyWebView) {
                await runWireProxyWebViewTest()
                completed += 1
                updateProgress(Double(completed) / Double(totalPhases))
                if Task.isCancelled { finalize(startTime: startTime); return }
            }

            if activeTypes.contains(.joeURLs) {
                await runJoeURLTests()
                completed += 1
                updateProgress(Double(completed) / Double(totalPhases))
                if Task.isCancelled { finalize(startTime: startTime); return }
            }

            if activeTypes.contains(.ignitionURLs) {
                await runIgnitionURLTests()
                completed += 1
                updateProgress(Double(completed) / Double(totalPhases))
                if Task.isCancelled { finalize(startTime: startTime); return }
            }

            if activeTypes.contains(.ppsrConnection) {
                await runPPSRConnectionTest()
                completed += 1
                updateProgress(Double(completed) / Double(totalPhases))
                if Task.isCancelled { finalize(startTime: startTime); return }
            }

            if activeTypes.contains(.dnsServers) {
                await runDNSServerTests()
                completed += 1
                updateProgress(Double(completed) / Double(totalPhases))
                if Task.isCancelled { finalize(startTime: startTime); return }
            }

            if activeTypes.contains(.socks5Proxies) {
                await runSOCKS5ProxyTests()
                completed += 1
                updateProgress(Double(completed) / Double(totalPhases))
                if Task.isCancelled { finalize(startTime: startTime); return }
            }

            if activeTypes.contains(.openvpnProfiles) {
                await runOpenVPNProfileTests()
                completed += 1
                updateProgress(Double(completed) / Double(totalPhases))
                if Task.isCancelled { finalize(startTime: startTime); return }
            }

            if activeTypes.contains(.wireguardProfiles) {
                await runWireGuardProfileTests()
                completed += 1
                updateProgress(Double(completed) / Double(totalPhases))
            }

            finalize(startTime: startTime)
        }
    }

    func stopSuperTest() {
        testTask?.cancel()
        testTask = nil
        isRunning = false
        currentPhase = .idle
        currentItem = ""
        addLog("SUPER TEST — Stopped by user", level: .warning)
        logger.endSession("supertest", category: .superTest, message: "SUPER TEST stopped by user", level: .warning)
    }

    private func finalize(startTime: Date) {
        let duration = Date().timeIntervalSince(startTime)
        let totalTested = results.count
        let totalPassed = results.filter(\.passed).count
        let totalFailed = results.filter { !$0.passed }.count

        let fingerprintResults = results.filter { $0.category == .fingerprint }
        let fpScore = fingerprintResults.first.flatMap(\.latencyMs)
        let fpPassed = fingerprintResults.first?.passed ?? false

        let disabledCount = countDisabledItems()
        let enabledCount = countEnabledItems()

        diagnosticFindings = generateDiagnostics()

        lastReport = SuperTestReport(
            results: results,
            fingerprintScore: fpScore,
            fingerprintPassed: fpPassed,
            totalTested: totalTested,
            totalPassed: totalPassed,
            totalFailed: totalFailed,
            totalDisabled: disabledCount,
            totalEnabled: enabledCount,
            duration: duration,
            timestamp: Date(),
            diagnostics: diagnosticFindings
        )

        currentPhase = .complete
        progress = 1.0
        currentItem = ""
        isRunning = false

        let diagSummary = diagnosticFindings.isEmpty ? "no issues" : "\(diagnosticFindings.filter { $0.severity == .critical }.count) critical, \(diagnosticFindings.filter { $0.severity == .warning }.count) warnings, \(diagnosticFindings.filter { $0.autoFixAvailable }.count) auto-fixable"
        addLog("SUPER TEST COMPLETE — \(totalPassed)/\(totalTested) passed, \(totalFailed) failed, \(disabledCount) auto-disabled — Diagnostics: \(diagSummary)", level: .success)
        logger.endSession("supertest", category: .superTest, message: "SUPER TEST COMPLETE: \(totalPassed)/\(totalTested) passed, \(totalFailed) failed, diag: \(diagSummary)", level: totalFailed == 0 ? .success : .warning)
    }

    private func countDisabledItems() -> Int {
        results.filter { !$0.passed }.count
    }

    private func countEnabledItems() -> Int {
        results.filter(\.passed).count
    }

    // MARK: - Fingerprint Detection Test

    private func runFingerprintTest() async {
        currentPhase = .fingerprint
        currentItem = "Fingerprint.com Detection Test"
        phaseProgress[.fingerprint] = (total: 2, done: 0)
        addLog("Phase 1: Fingerprint & Headless Detection")
        logger.log("Phase 1: Fingerprint & Headless Detection", category: .superTest, level: .info, sessionId: "supertest")

        let webViewScore = await runWebViewFingerprintTest()
        phaseProgress[.fingerprint] = (total: 2, done: 1)

        let headlessScore = await runHeadlessDetectionTest()
        phaseProgress[.fingerprint] = (total: 2, done: 2)

        let avgScore = (webViewScore + headlessScore) / 2
        let passed = avgScore <= FingerprintValidationService.maxAcceptableScore

        results.append(SuperTestItemResult(
            name: "WebView Fingerprint Score",
            category: .fingerprint,
            passed: webViewScore <= FingerprintValidationService.maxAcceptableScore,
            latencyMs: webViewScore,
            detail: "Score: \(webViewScore)/\(FingerprintValidationService.maxAcceptableScore) — \(webViewScore <= FingerprintValidationService.maxAcceptableScore ? "CLEAN" : "DETECTED")"
        ))

        results.append(SuperTestItemResult(
            name: "Headless/Bot Detection",
            category: .fingerprint,
            passed: headlessScore <= FingerprintValidationService.maxAcceptableScore,
            latencyMs: headlessScore,
            detail: "Score: \(headlessScore)/\(FingerprintValidationService.maxAcceptableScore) — \(headlessScore <= FingerprintValidationService.maxAcceptableScore ? "CLEAN" : "DETECTED")"
        ))

        addLog("Fingerprint: WebView=\(webViewScore), Headless=\(headlessScore), Overall: \(passed ? "PASS" : "FAIL")", level: passed ? .success : .error)
    }

    private func runWebViewFingerprintTest() async -> Int {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 414, height: 896), configuration: config)

        let request = URLRequest(url: URL(string: "about:blank")!)
        webView.load(request)
        try? await Task.sleep(for: .milliseconds(500))

        let fpService = FingerprintValidationService.shared
        let score = await fpService.validate(in: webView, profileSeed: UInt32.random(in: 0...UInt32.max))
        return score.totalScore
    }

    private func runHeadlessDetectionTest() async -> Int {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 414, height: 896), configuration: config)

        let request = URLRequest(url: URL(string: "about:blank")!)
        webView.load(request)
        try? await Task.sleep(for: .milliseconds(500))

        let headlessJS = """
        (function() {
            var score = 0;
            var signals = [];
            try { if (navigator.webdriver) { score += 7; signals.push('webdriver'); } } catch(e) {}
            try { if (!window.chrome && navigator.userAgent.indexOf('Chrome') !== -1) { score += 5; signals.push('chrome_mismatch'); } } catch(e) {}
            try { if (navigator.languages === undefined || navigator.languages.length === 0) { score += 4; signals.push('no_languages'); } } catch(e) {}
            try { if (navigator.plugins === undefined || navigator.plugins.length === 0) { score += 2; signals.push('no_plugins'); } } catch(e) {}
            try {
                var c = document.createElement('canvas');
                var gl = c.getContext('webgl');
                if (!gl) { score += 3; signals.push('no_webgl'); }
            } catch(e) {}
            try { if (navigator.permissions) {
                // sync check only
            }} catch(e) {}
            try {
                var autoFlags = ['__nightmare', '_phantom', 'callPhantom', '__selenium_evaluate', '__webdriver_evaluate'];
                for (var i = 0; i < autoFlags.length; i++) {
                    if (window[autoFlags[i]] !== undefined) { score += 7; signals.push('auto_flag:' + autoFlags[i]); break; }
                }
            } catch(e) {}
            return JSON.stringify({score: score, signals: signals});
        })();
        """

        do {
            let result = try await webView.evaluateJavaScript(headlessJS)
            if let str = result as? String,
               let data = str.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let score = json["score"] as? Int {
                return score
            }
        } catch {
            logger.log("SuperTest: JS score evaluation failed, using fallback score 0", category: .superTest, level: .debug)
        }

        return 0
    }

    // MARK: - Joe Fortune URL Tests (2 Random Sample)

    private func runJoeURLTests() async {
        currentPhase = .joeURLs
        let allURLs = urlRotation.joeURLs
        let sampleURLs = pickRandomSample(from: allURLs, count: 2)
        let total = sampleURLs.count
        phaseProgress[.joeURLs] = (total: total, done: 0)
        addLog("Phase: Testing \(total) random Joe Fortune URLs (of \(allURLs.count) total)")
        logger.log("Testing \(total) random Joe Fortune URLs (of \(allURLs.count) total)", category: .superTest, level: .info, sessionId: "supertest")

        for (index, rotatingURL) in sampleURLs.enumerated() {
            if Task.isCancelled { return }
            currentItem = rotatingURL.host
            logger.startTimer(key: "supertest_joe_\(index)")
            let result = await pingURL(rotatingURL.urlString, name: rotatingURL.host, category: .joeURLs)
            let pingMs = logger.stopTimer(key: "supertest_joe_\(index)")
            results.append(result)

            if result.passed {
                urlRotation.toggleURL(id: rotatingURL.id, enabled: true)
                logger.log("Joe URL PASS: \(rotatingURL.host) \(result.detail)", category: .url, level: .success, sessionId: "supertest", durationMs: pingMs)
            } else {
                urlRotation.toggleURL(id: rotatingURL.id, enabled: false)
                addLog("Auto-disabled Joe URL: \(rotatingURL.host)", level: .warning)
                logger.log("Joe URL FAIL (auto-disabled): \(rotatingURL.host) \(result.detail)", category: .url, level: .warning, sessionId: "supertest", durationMs: pingMs)
            }

            phaseProgress[.joeURLs] = (total: total, done: index + 1)
        }

        let passed = results.filter { $0.category == .joeURLs && $0.passed }.count
        addLog("Joe URLs: \(passed)/\(total) passed", level: passed > 0 ? .success : .error)
    }

    // MARK: - Ignition URL Tests (2 Random Sample)

    private func runIgnitionURLTests() async {
        currentPhase = .ignitionURLs
        let allURLs = urlRotation.ignitionURLs
        let sampleURLs = pickRandomSample(from: allURLs, count: 2)
        let total = sampleURLs.count
        phaseProgress[.ignitionURLs] = (total: total, done: 0)
        addLog("Phase: Testing \(total) random Ignition URLs (of \(allURLs.count) total)")
        logger.log("Testing \(total) random Ignition URLs (of \(allURLs.count) total)", category: .superTest, level: .info, sessionId: "supertest")

        for (index, rotatingURL) in sampleURLs.enumerated() {
            if Task.isCancelled { return }
            currentItem = rotatingURL.host
            logger.startTimer(key: "supertest_ign_\(index)")
            let result = await pingURL(rotatingURL.urlString, name: rotatingURL.host, category: .ignitionURLs)
            let pingMs = logger.stopTimer(key: "supertest_ign_\(index)")
            results.append(result)

            if result.passed {
                urlRotation.toggleURL(id: rotatingURL.id, enabled: true)
                logger.log("Ignition URL PASS: \(rotatingURL.host)", category: .url, level: .success, sessionId: "supertest", durationMs: pingMs)
            } else {
                urlRotation.toggleURL(id: rotatingURL.id, enabled: false)
                addLog("Auto-disabled Ignition URL: \(rotatingURL.host)", level: .warning)
                logger.log("Ignition URL FAIL (auto-disabled): \(rotatingURL.host)", category: .url, level: .warning, sessionId: "supertest", durationMs: pingMs)
            }

            phaseProgress[.ignitionURLs] = (total: total, done: index + 1)
        }

        let passed = results.filter { $0.category == .ignitionURLs && $0.passed }.count
        addLog("Ignition URLs: \(passed)/\(total) passed", level: passed > 0 ? .success : .error)
    }

    // MARK: - WireProxy WebView Test

    private func runWireProxyWebViewTest() async {
        currentPhase = .wireproxyWebView
        currentItem = "WireProxy WebView Connectivity"
        let testCount = 3
        phaseProgress[.wireproxyWebView] = (total: testCount, done: 0)
        addLog("Phase: WireProxy WebView Test — verifying WebView traffic routes through WireProxy")
        logger.log("WireProxy WebView Test starting", category: .superTest, level: .info, sessionId: "supertest")

        let wireProxyActive = wireProxyBridge.isActive && localProxy.isRunning && localProxy.wireProxyMode
        results.append(SuperTestItemResult(
            name: "WireProxy Tunnel Status",
            category: .wireproxyWebView,
            passed: wireProxyActive,
            detail: wireProxyActive ? "WireProxy tunnel established, local proxy on :\(localProxy.listeningPort)" : "WireProxy tunnel NOT active — WebView traffic will NOT be proxied"
        ))
        phaseProgress[.wireproxyWebView] = (total: testCount, done: 1)

        if !wireProxyActive {
            addLog("WireProxy not active — attempting to start", level: .warning)
            if deviceProxy.isEnabled {
                deviceProxy.reconnectWireProxy()
                try? await Task.sleep(for: .seconds(4))
            }
        }

        let tunnelReady = wireProxyBridge.isActive && localProxy.isRunning && localProxy.wireProxyMode

        let webViewIPResult = await testWebViewIPViaWireProxy(tunnelReady: tunnelReady)
        results.append(webViewIPResult)
        phaseProgress[.wireproxyWebView] = (total: testCount, done: 2)

        let webViewLoadResult = await testWebViewLoadViaWireProxy(tunnelReady: tunnelReady)
        results.append(webViewLoadResult)
        phaseProgress[.wireproxyWebView] = (total: testCount, done: 3)

        let passed = results.filter { $0.category == .wireproxyWebView && $0.passed }.count
        addLog("WireProxy WebView: \(passed)/\(testCount) passed", level: passed == testCount ? .success : (passed > 0 ? .warning : .error))
    }

    private func testWebViewIPViaWireProxy(tunnelReady: Bool) async -> SuperTestItemResult {
        guard tunnelReady else {
            return SuperTestItemResult(
                name: "WebView IP via WireProxy",
                category: .wireproxyWebView,
                passed: false,
                detail: "Skipped — WireProxy tunnel not active"
            )
        }

        let networkConfig: ActiveNetworkConfig = .socks5(localProxy.localProxyConfig)
        let wkConfig = WKWebViewConfiguration()
        wkConfig.websiteDataStore = .nonPersistent()
        let applied = networkFactory.configureWKWebView(config: wkConfig, networkConfig: networkConfig, target: .joe)
        guard applied else {
            return SuperTestItemResult(
                name: "WebView IP via WireProxy",
                category: .wireproxyWebView,
                passed: false,
                detail: "Failed to apply proxy config to WKWebView"
            )
        }

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 414, height: 896), configuration: wkConfig)
        let start = Date()

        let ipCheckURL = URL(string: "https://api.ipify.org?format=json")!
        let request = URLRequest(url: ipCheckURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        webView.load(request)

        var attempts = 0
        var pageContent: String?
        while attempts < 30 {
            try? await Task.sleep(for: .milliseconds(500))
            attempts += 1
            if let content = try? await webView.evaluateJavaScript("document.body?.innerText || ''") as? String, !content.isEmpty {
                pageContent = content
                break
            }
        }

        let latency = Int(Date().timeIntervalSince(start) * 1000)

        guard let content = pageContent, !content.isEmpty else {
            return SuperTestItemResult(
                name: "WebView IP via WireProxy",
                category: .wireproxyWebView,
                passed: false,
                latencyMs: latency,
                detail: "WebView failed to load IP check page in \(latency)ms"
            )
        }

        if let data = content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ip = json["ip"] as? String {
            logger.log("WireProxy WebView IP: \(ip) in \(latency)ms", category: .superTest, level: .success, sessionId: "supertest", durationMs: latency)
            return SuperTestItemResult(
                name: "WebView IP via WireProxy",
                category: .wireproxyWebView,
                passed: true,
                latencyMs: latency,
                detail: "IP: \(ip) via WireProxy in \(latency)ms"
            )
        }

        return SuperTestItemResult(
            name: "WebView IP via WireProxy",
            category: .wireproxyWebView,
            passed: true,
            latencyMs: latency,
            detail: "WebView loaded via WireProxy in \(latency)ms (response: \(content.prefix(80)))"
        )
    }

    private func testWebViewLoadViaWireProxy(tunnelReady: Bool) async -> SuperTestItemResult {
        guard tunnelReady else {
            return SuperTestItemResult(
                name: "WebView Page Load via WireProxy",
                category: .wireproxyWebView,
                passed: false,
                detail: "Skipped — WireProxy tunnel not active"
            )
        }

        let networkConfig: ActiveNetworkConfig = .socks5(localProxy.localProxyConfig)
        let wkConfig = WKWebViewConfiguration()
        wkConfig.websiteDataStore = .nonPersistent()
        let applied = networkFactory.configureWKWebView(config: wkConfig, networkConfig: networkConfig, target: .joe)
        guard applied else {
            return SuperTestItemResult(
                name: "WebView Page Load via WireProxy",
                category: .wireproxyWebView,
                passed: false,
                detail: "Failed to apply proxy config"
            )
        }

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 414, height: 896), configuration: wkConfig)
        let start = Date()

        let testURL = URL(string: "https://httpbin.org/get")!
        let request = URLRequest(url: testURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        webView.load(request)

        var attempts = 0
        var pageLoaded = false
        while attempts < 30 {
            try? await Task.sleep(for: .milliseconds(500))
            attempts += 1
            if let done = try? await webView.evaluateJavaScript("document.readyState") as? String, done == "complete" {
                pageLoaded = true
                break
            }
        }

        let latency = Int(Date().timeIntervalSince(start) * 1000)

        if pageLoaded {
            let bodyText = (try? await webView.evaluateJavaScript("document.body?.innerText || ''") as? String) ?? ""
            let hasOrigin = bodyText.contains("origin")
            logger.log("WireProxy WebView page load OK in \(latency)ms", category: .superTest, level: .success, sessionId: "supertest", durationMs: latency)
            return SuperTestItemResult(
                name: "WebView Page Load via WireProxy",
                category: .wireproxyWebView,
                passed: true,
                latencyMs: latency,
                detail: "httpbin.org loaded in \(latency)ms\(hasOrigin ? " (origin IP confirmed)" : "")"
            )
        }

        return SuperTestItemResult(
            name: "WebView Page Load via WireProxy",
            category: .wireproxyWebView,
            passed: false,
            latencyMs: latency,
            detail: "Page failed to load via WireProxy in \(latency)ms"
        )
    }

    // MARK: - PPSR Connection Test

    private func runPPSRConnectionTest() async {
        currentPhase = .ppsrConnection
        currentItem = "transact.ppsr.gov.au"
        phaseProgress[.ppsrConnection] = (total: 3, done: 0)
        addLog("Phase 4: Testing PPSR Connection")
        logger.log("Phase 4: Testing PPSR Connection", category: .superTest, level: .info, sessionId: "supertest")

        let healthCheck = await diagnostics.quickHealthCheck()
        phaseProgress[.ppsrConnection] = (total: 3, done: 1)

        results.append(SuperTestItemResult(
            name: "PPSR Health Check",
            category: .ppsrConnection,
            passed: healthCheck.healthy,
            detail: healthCheck.detail
        ))

        let dnsAnswer = await dohService.resolveWithRotation(hostname: "transact.ppsr.gov.au")
        phaseProgress[.ppsrConnection] = (total: 3, done: 2)

        results.append(SuperTestItemResult(
            name: "PPSR DNS Resolution",
            category: .ppsrConnection,
            passed: dnsAnswer != nil,
            latencyMs: dnsAnswer?.latencyMs,
            detail: dnsAnswer.map { "Resolved via \($0.provider) → \($0.ip)" } ?? "DNS resolution failed"
        ))

        let sslResult = await testSSL("transact.ppsr.gov.au")
        phaseProgress[.ppsrConnection] = (total: 3, done: 3)

        results.append(SuperTestItemResult(
            name: "PPSR SSL/TLS",
            category: .ppsrConnection,
            passed: sslResult.0,
            latencyMs: sslResult.1,
            detail: sslResult.2
        ))

        let passed = results.filter { $0.category == .ppsrConnection && $0.passed }.count
        addLog("PPSR: \(passed)/3 checks passed", level: passed == 3 ? .success : (passed > 0 ? .warning : .error))
    }

    // MARK: - DNS Server Tests

    private func runDNSServerTests() async {
        currentPhase = .dnsServers
        let providers = dohService.managedProviders
        let total = providers.count
        phaseProgress[.dnsServers] = (total: total, done: 0)
        addLog("Phase 5: Testing \(total) DNS Servers")
        logger.log("Phase 5: Testing \(total) DNS Servers", category: .superTest, level: .info, sessionId: "supertest")

        for (index, provider) in providers.enumerated() {
            if Task.isCancelled { return }
            currentItem = provider.name

            let dohProvider = DoHProvider(name: provider.name, url: provider.url)
            let answer = await dohService.resolve(hostname: "transact.ppsr.gov.au", using: dohProvider)
            let passed = answer != nil

            results.append(SuperTestItemResult(
                name: provider.name,
                category: .dnsServers,
                passed: passed,
                latencyMs: answer?.latencyMs,
                detail: passed ? "Resolved → \(answer?.ip ?? "?") in \(answer?.latencyMs ?? 0)ms" : "Resolution failed"
            ))

            dohService.toggleProvider(id: provider.id, enabled: passed)
            if !passed {
                addLog("Auto-disabled DNS: \(provider.name)", level: .warning)
                logger.log("DNS FAIL (auto-disabled): \(provider.name)", category: .dns, level: .warning, sessionId: "supertest")
            } else {
                logger.log("DNS PASS: \(provider.name) \(answer?.ip ?? "?") in \(answer?.latencyMs ?? 0)ms", category: .dns, level: .success, sessionId: "supertest", durationMs: answer?.latencyMs)
            }

            phaseProgress[.dnsServers] = (total: total, done: index + 1)
        }

        let passedCount = results.filter { $0.category == .dnsServers && $0.passed }.count
        addLog("DNS Servers: \(passedCount)/\(total) passed", level: passedCount > 0 ? .success : .error)
    }

    // MARK: - SOCKS5 Proxy Tests

    private func runSOCKS5ProxyTests() async {
        logger.log("Phase 6: Testing SOCKS5 Proxies", category: .superTest, level: .info, sessionId: "supertest")
        currentPhase = .socks5Proxies
        let allProxies: [(proxy: ProxyConfig, target: ProxyRotationService.ProxyTarget)] =
            proxyService.savedProxies.map { ($0, .joe) } +
            proxyService.ignitionProxies.map { ($0, .ignition) } +
            proxyService.ppsrProxies.map { ($0, .ppsr) }

        let total = allProxies.count
        phaseProgress[.socks5Proxies] = (total: total, done: 0)
        addLog("Phase 6: Testing \(total) SOCKS5 Proxies")

        if total == 0 {
            addLog("No SOCKS5 proxies configured — skipping", level: .warning)
            return
        }

        let maxConcurrent = 5
        var index = 0

        await withTaskGroup(of: (ProxyConfig, ProxyRotationService.ProxyTarget, Bool, Int).self) { group in
            var launched = 0

            for (proxy, target) in allProxies {
                if Task.isCancelled { return }

                if launched >= maxConcurrent {
                    if let result = await group.next() {
                        processProxyResult(result)
                        index += 1
                        phaseProgress[.socks5Proxies] = (total: total, done: index)
                    }
                }

                currentItem = proxy.displayString
                group.addTask {
                    let (passed, latency) = await self.testProxy(proxy)
                    return (proxy, target, passed, latency)
                }
                launched += 1
            }

            for await result in group {
                processProxyResult(result)
                index += 1
                phaseProgress[.socks5Proxies] = (total: total, done: index)
            }
        }

        let passedCount = results.filter { $0.category == .socks5Proxies && $0.passed }.count
        addLog("SOCKS5 Proxies: \(passedCount)/\(total) passed", level: passedCount > 0 ? .success : .error)
    }

    private func processProxyResult(_ result: (ProxyConfig, ProxyRotationService.ProxyTarget, Bool, Int)) {
        let (proxy, target, passed, latency) = result
        let targetLabel: String
        switch target {
        case .joe: targetLabel = "Joe"
        case .ignition: targetLabel = "Ignition"
        case .ppsr: targetLabel = "PPSR"
        }

        results.append(SuperTestItemResult(
            name: "\(proxy.displayString) [\(targetLabel)]",
            category: .socks5Proxies,
            passed: passed,
            latencyMs: passed ? latency : nil,
            detail: passed ? "Connected in \(latency)ms" : "Connection failed"
        ))

        if passed {
            proxyService.markProxyWorking(proxy)
            logger.log("Proxy PASS: \(proxy.displayString) [\(targetLabel)] in \(latency)ms", category: .proxy, level: .success, sessionId: "supertest", durationMs: latency)
        } else {
            proxyService.markProxyFailed(proxy)
            addLog("Auto-failed proxy: \(proxy.displayString) [\(targetLabel)]", level: .warning)
            logger.log("Proxy FAIL: \(proxy.displayString) [\(targetLabel)]", category: .proxy, level: .warning, sessionId: "supertest")
        }
    }

    // MARK: - OpenVPN Profile Tests

    private func runOpenVPNProfileTests() async {
        logger.log("Phase 7: Testing OpenVPN Profiles", category: .superTest, level: .info, sessionId: "supertest")
        currentPhase = .openvpnProfiles
        let allVPN: [(config: OpenVPNConfig, target: ProxyRotationService.ProxyTarget)] =
            proxyService.joeVPNConfigs.map { ($0, .joe) } +
            proxyService.ignitionVPNConfigs.map { ($0, .ignition) } +
            proxyService.ppsrVPNConfigs.map { ($0, .ppsr) }

        let total = allVPN.count
        phaseProgress[.openvpnProfiles] = (total: total, done: 0)
        addLog("Phase 7: Testing \(total) OpenVPN Profiles")

        if total == 0 {
            addLog("No OpenVPN profiles configured — skipping", level: .warning)
            return
        }

        let maxConcurrent = 6
        var index = 0

        await withTaskGroup(of: (OpenVPNConfig, ProxyRotationService.ProxyTarget, Bool, Int).self) { group in
            var launched = 0

            for (vpnConfig, target) in allVPN {
                if Task.isCancelled { return }

                if launched >= maxConcurrent {
                    if let result = await group.next() {
                        processVPNResult(result)
                        index += 1
                        phaseProgress[.openvpnProfiles] = (total: total, done: index)
                    }
                }

                currentItem = vpnConfig.displayString
                group.addTask {
                    let result = await self.protocolTester.testOpenVPNEndpoint(vpnConfig)
                    return (vpnConfig, target, result.reachable, result.latencyMs)
                }
                launched += 1
            }

            for await result in group {
                processVPNResult(result)
                index += 1
                phaseProgress[.openvpnProfiles] = (total: total, done: index)
            }
        }

        let passedCount = results.filter { $0.category == .openvpnProfiles && $0.passed }.count
        addLog("OpenVPN: \(passedCount)/\(total) passed", level: passedCount > 0 ? .success : .error)
    }

    private func processVPNResult(_ result: (OpenVPNConfig, ProxyRotationService.ProxyTarget, Bool, Int)) {
        let (vpnConfig, target, passed, latency) = result
        let targetLabel: String
        switch target {
        case .joe: targetLabel = "Joe"
        case .ignition: targetLabel = "Ignition"
        case .ppsr: targetLabel = "PPSR"
        }

        results.append(SuperTestItemResult(
            name: "\(vpnConfig.displayString) [\(targetLabel)]",
            category: .openvpnProfiles,
            passed: passed,
            latencyMs: passed ? latency : nil,
            detail: passed ? "OpenVPN protocol handshake OK in \(latency)ms" : "OpenVPN endpoint unreachable or protocol validation failed"
        ))

        proxyService.markVPNConfigReachable(vpnConfig, target: target, reachable: passed, latencyMs: passed ? latency : nil)
        if !passed {
            addLog("Auto-disabled VPN: \(vpnConfig.fileName) [\(targetLabel)]", level: .warning)
            logger.log("VPN FAIL (auto-disabled): \(vpnConfig.fileName) [\(targetLabel)]", category: .vpn, level: .warning, sessionId: "supertest")
        } else {
            logger.log("VPN PASS: \(vpnConfig.fileName) [\(targetLabel)] in \(latency)ms", category: .vpn, level: .success, sessionId: "supertest", durationMs: latency)
        }
    }

    // MARK: - WireGuard Profile Tests

    private func runWireGuardProfileTests() async {
        logger.log("Phase 8: Testing WireGuard Profiles", category: .superTest, level: .info, sessionId: "supertest")
        currentPhase = .wireguardProfiles
        let allWG: [(config: WireGuardConfig, target: ProxyRotationService.ProxyTarget)] =
            proxyService.joeWGConfigs.map { ($0, .joe) } +
            proxyService.ignitionWGConfigs.map { ($0, .ignition) } +
            proxyService.ppsrWGConfigs.map { ($0, .ppsr) }

        let total = allWG.count
        phaseProgress[.wireguardProfiles] = (total: total, done: 0)
        addLog("Phase 8: Testing \(total) WireGuard Profiles")

        if total == 0 {
            addLog("No WireGuard profiles configured — skipping", level: .warning)
            return
        }

        let maxConcurrent = 8
        var index = 0

        await withTaskGroup(of: (WireGuardConfig, ProxyRotationService.ProxyTarget, Bool, Int).self) { group in
            var launched = 0

            for (wgConfig, target) in allWG {
                if Task.isCancelled { return }

                if launched >= maxConcurrent {
                    if let result = await group.next() {
                        processWGResult(result)
                        index += 1
                        phaseProgress[.wireguardProfiles] = (total: total, done: index)
                    }
                }

                currentItem = wgConfig.displayString
                group.addTask {
                    let result = await self.protocolTester.testWireGuardEndpoint(wgConfig)
                    return (wgConfig, target, result.reachable, result.latencyMs)
                }
                launched += 1
            }

            for await result in group {
                processWGResult(result)
                index += 1
                phaseProgress[.wireguardProfiles] = (total: total, done: index)
            }
        }

        let passedCount = results.filter { $0.category == .wireguardProfiles && $0.passed }.count
        addLog("WireGuard: \(passedCount)/\(total) passed", level: passedCount > 0 ? .success : .error)
    }

    private func processWGResult(_ result: (WireGuardConfig, ProxyRotationService.ProxyTarget, Bool, Int)) {
        let (wgConfig, target, reachable, latency) = result
        let targetLabel: String
        switch target {
        case .joe: targetLabel = "Joe"
        case .ignition: targetLabel = "Ignition"
        case .ppsr: targetLabel = "PPSR"
        }

        results.append(SuperTestItemResult(
            name: "\(wgConfig.displayString) [\(targetLabel)]",
            category: .wireguardProfiles,
            passed: reachable,
            latencyMs: reachable ? latency : nil,
            detail: reachable ? "WG UDP handshake validated in \(latency)ms" : "WG endpoint unreachable (UDP handshake + TCP fallback failed)"
        ))

        proxyService.markWGConfigReachable(wgConfig, target: target, reachable: reachable)
        if !reachable {
            addLog("Auto-disabled WG: \(wgConfig.fileName) [\(targetLabel)]", level: .warning)
            logger.log("WG FAIL (auto-disabled): \(wgConfig.fileName) [\(targetLabel)]", category: .vpn, level: .warning, sessionId: "supertest")
        } else {
            logger.log("WG PASS: \(wgConfig.fileName) [\(targetLabel)] in \(latency)ms", category: .vpn, level: .success, sessionId: "supertest", durationMs: latency)
        }
    }

    // MARK: - Utility Methods

    private func pingURL(_ urlString: String, name: String, category: SuperTestPhase) async -> SuperTestItemResult {
        guard let url = URL(string: urlString) else {
            logger.log("SuperTest pingURL: invalid URL '\(urlString)'", category: .superTest, level: .error, sessionId: "supertest")
            return SuperTestItemResult(name: name, category: category, passed: false, detail: "Invalid URL")
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 12)
        request.httpMethod = "HEAD"
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")

        let start = Date()
        do {
            let (_, response) = try await session.data(for: request)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            if let http = response as? HTTPURLResponse {
                let passed = http.statusCode >= 200 && http.statusCode < 400
                if !passed {
                    logger.log("SuperTest pingURL: \(name) HTTP \(http.statusCode)", category: .superTest, level: .warning, sessionId: "supertest", durationMs: latency, metadata: [
                        "url": urlString, "statusCode": "\(http.statusCode)"
                    ])
                }
                return SuperTestItemResult(
                    name: name,
                    category: category,
                    passed: passed,
                    latencyMs: latency,
                    detail: "HTTP \(http.statusCode) in \(latency)ms"
                )
            }
            return SuperTestItemResult(name: name, category: category, passed: true, latencyMs: latency, detail: "Response in \(latency)ms")
        } catch {
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let classified = logger.classifyNetworkError(error)
            logger.logError("SuperTest pingURL: \(name) failed", error: error, category: .superTest, sessionId: "supertest", metadata: [
                "url": urlString, "isRetryable": "\(classified.isRetryable)", "latency": "\(latency)ms"
            ])
            if classified.isRetryable {
                logger.logHealing(category: .superTest, originalError: classified.userMessage, healingAction: "Retrying \(name) with GET fallback", succeeded: false, sessionId: "supertest")
                var getRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
                getRequest.httpMethod = "GET"
                getRequest.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
                do {
                    let (_, retryResponse) = try await session.data(for: getRequest)
                    let retryLatency = Int(Date().timeIntervalSince(start) * 1000)
                    if let http = retryResponse as? HTTPURLResponse {
                        let passed = http.statusCode >= 200 && http.statusCode < 400
                        if passed {
                            logger.logHealing(category: .superTest, originalError: classified.userMessage, healingAction: "GET fallback succeeded for \(name) (HTTP \(http.statusCode))", succeeded: true, durationMs: retryLatency, sessionId: "supertest")
                        }
                        return SuperTestItemResult(name: name, category: category, passed: passed, latencyMs: retryLatency, detail: "HTTP \(http.statusCode) in \(retryLatency)ms (GET retry)")
                    }
                } catch {
                    logger.logHealing(category: .superTest, originalError: classified.userMessage, healingAction: "GET retry also failed for \(name)", succeeded: false, sessionId: "supertest")
                }
            }
            return SuperTestItemResult(name: name, category: category, passed: false, latencyMs: latency, detail: classified.userMessage)
        }
    }

    private nonisolated func testProxy(_ proxy: ProxyConfig) async -> (Bool, Int) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15

        var proxyDict: [String: Any] = [
            "SOCKSEnable": 1,
            "SOCKSProxy": proxy.host,
            "SOCKSPort": proxy.port,
        ]
        if let u = proxy.username { proxyDict["SOCKSUser"] = u }
        if let p = proxy.password { proxyDict["SOCKSPassword"] = p }
        config.connectionProxyDictionary = proxyDict

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let start = Date()
        let testURLs = ["https://api.ipify.org?format=json", "https://httpbin.org/ip", "https://ifconfig.me/ip"]
        for urlString in testURLs {
            guard let url = URL(string: urlString) else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 10
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty {
                    let latency = Int(Date().timeIntervalSince(start) * 1000)
                    return (true, latency)
                }
            } catch {
                continue
            }
        }
        return (false, 0)
    }

    private func testSSL(_ host: String) async -> (Bool, Int, String) {
        let start = Date()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: URL(string: "https://\(host)")!)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (_, response) = try await session.data(for: request)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            if let http = response as? HTTPURLResponse {
                logger.log("SuperTest SSL: \(host) TLS OK (HTTP \(http.statusCode)) in \(latency)ms", category: .network, level: .success, sessionId: "supertest", durationMs: latency)
                return (true, latency, "TLS OK (HTTP \(http.statusCode)) in \(latency)ms")
            }
            return (true, latency, "TLS handshake OK in \(latency)ms")
        } catch {
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            logger.logError("SuperTest SSL: \(host) failed", error: error, category: .network, sessionId: "supertest")
            return (false, latency, "SSL failed: \(error.localizedDescription)")
        }
    }



    private func updateProgress(_ value: Double) {
        progress = value
    }

    private func addLog(_ message: String, level: PPSRLogEntry.Level = .info) {
        logs.insert(PPSRLogEntry(message: message, level: level), at: 0)
        if logs.count > 500 { logs = Array(logs.prefix(500)) }
    }

    private func pickRandomSample(from urls: [LoginURLRotationService.RotatingURL], count: Int) -> [LoginURLRotationService.RotatingURL] {
        guard urls.count > count else { return urls }
        var shuffled = urls
        shuffled.shuffle()
        return Array(shuffled.prefix(count))
    }

    // MARK: - Smart Diagnostics Engine

    private func generateDiagnostics() -> [DiagnosticFinding] {
        var findings: [DiagnosticFinding] = []

        let wireProxyResults = results.filter { $0.category == .wireproxyWebView }
        let wireProxyFailed = wireProxyResults.filter { !$0.passed }
        if !wireProxyResults.isEmpty && wireProxyFailed.count == wireProxyResults.count {
            let tunnelStatus = wireProxyResults.first(where: { $0.name.contains("Tunnel Status") })
            if tunnelStatus?.passed == false {
                findings.append(DiagnosticFinding(
                    severity: .critical,
                    title: "WireProxy Tunnel Not Established",
                    explanation: "The WireGuard tunnel failed to connect. All WebView traffic through WireProxy will fail. This usually means the WireGuard private key is invalid, the server endpoint is unreachable, or the handshake timed out.",
                    fixAction: "Restart WireProxy tunnel with a different server",
                    autoFixAvailable: true,
                    category: .wireproxyWebView
                ))
            } else {
                findings.append(DiagnosticFinding(
                    severity: .critical,
                    title: "WireProxy DNS Resolution Failing",
                    explanation: "The tunnel is established but DNS queries through it are failing. This means the DNS server configured in the WireGuard config (usually NordVPN's 103.86.96.100) is not responding through the tunnel. Traffic cannot resolve hostnames.",
                    fixAction: "Rotate to a different WireGuard server",
                    autoFixAvailable: true,
                    category: .wireproxyWebView
                ))
            }
        } else if wireProxyFailed.count == 1 && wireProxyResults.count == 3 {
            findings.append(DiagnosticFinding(
                severity: .warning,
                title: "WireProxy Partially Working",
                explanation: "Some WireProxy tests passed but \(wireProxyFailed.first?.name ?? "one test") failed. The tunnel may be slow or the DNS cache needs warming up. This is usually transient.",
                fixAction: nil,
                autoFixAvailable: false,
                category: .wireproxyWebView
            ))
        }

        let dnsResults = results.filter { $0.category == .dnsServers }
        let dnsFailed = dnsResults.filter { !$0.passed }
        if !dnsResults.isEmpty {
            if dnsFailed.count == dnsResults.count {
                findings.append(DiagnosticFinding(
                    severity: .critical,
                    title: "All DNS Servers Failed",
                    explanation: "No DNS-over-HTTPS providers responded. This means the device may not have internet access, or all DoH endpoints are blocked. PPSR VIN lookups will fail without working DNS.",
                    fixAction: "Check internet connection and try adding new DoH providers",
                    autoFixAvailable: false,
                    category: .dnsServers
                ))
            } else if dnsFailed.count > dnsResults.count / 2 {
                findings.append(DiagnosticFinding(
                    severity: .warning,
                    title: "Majority of DNS Servers Failed",
                    explanation: "\(dnsFailed.count) of \(dnsResults.count) DNS providers failed. Only \(dnsResults.count - dnsFailed.count) are working. Failed providers have been auto-disabled. Consider adding backup DNS providers.",
                    fixAction: nil,
                    autoFixAvailable: false,
                    category: .dnsServers
                ))
            }
        }

        let proxyResults = results.filter { $0.category == .socks5Proxies }
        let proxyFailed = proxyResults.filter { !$0.passed }
        if !proxyResults.isEmpty && proxyFailed.count == proxyResults.count {
            findings.append(DiagnosticFinding(
                severity: .critical,
                title: "All SOCKS5 Proxies Failed",
                explanation: "No SOCKS5 proxy could establish a connection and return an IP. This means either all proxies are down, credentials are wrong, or the proxy servers are blocking connections. WebView sessions in proxy mode will fall back to direct (IP exposed).",
                fixAction: "Switch to WireGuard mode which doesn't need SOCKS5 proxies",
                autoFixAvailable: true,
                category: .socks5Proxies
            ))
        } else if !proxyResults.isEmpty && proxyFailed.count > 0 {
            let failRate = Double(proxyFailed.count) / Double(proxyResults.count) * 100
            if failRate > 50 {
                findings.append(DiagnosticFinding(
                    severity: .warning,
                    title: "High Proxy Failure Rate (\(Int(failRate))%)",
                    explanation: "\(proxyFailed.count) of \(proxyResults.count) proxies failed. Failed proxies have been marked as down. The remaining \(proxyResults.count - proxyFailed.count) working proxies will be used for rotation.",
                    fixAction: nil,
                    autoFixAvailable: false,
                    category: .socks5Proxies
                ))
            }
        }

        let wgResults = results.filter { $0.category == .wireguardProfiles }
        let wgFailed = wgResults.filter { !$0.passed }
        if !wgResults.isEmpty {
            if wgFailed.count == wgResults.count {
                findings.append(DiagnosticFinding(
                    severity: .critical,
                    title: "All WireGuard Endpoints Unreachable",
                    explanation: "None of the \(wgResults.count) WireGuard servers responded to handshake probes. This could mean: (1) The NordVPN private key is expired or invalid, (2) NordVPN is blocking this IP, or (3) UDP port 51820 is blocked by the network.",
                    fixAction: "Re-fetch NordVPN credentials and repopulate configs",
                    autoFixAvailable: true,
                    category: .wireguardProfiles
                ))
            } else if wgFailed.count > wgResults.count / 2 {
                findings.append(DiagnosticFinding(
                    severity: .warning,
                    title: "Many WireGuard Endpoints Failing (\(wgFailed.count)/\(wgResults.count))",
                    explanation: "More than half of WireGuard endpoints failed. \(wgResults.count - wgFailed.count) are still working. Failed endpoints have been auto-disabled and won't be selected for tunneling.",
                    fixAction: nil,
                    autoFixAvailable: false,
                    category: .wireguardProfiles
                ))
            }
        }

        let vpnResults = results.filter { $0.category == .openvpnProfiles }
        let vpnFailed = vpnResults.filter { !$0.passed }
        if !vpnResults.isEmpty && vpnFailed.count == vpnResults.count {
            findings.append(DiagnosticFinding(
                severity: .critical,
                title: "All OpenVPN Endpoints Unreachable",
                explanation: "None of the \(vpnResults.count) OpenVPN servers responded. The .ovpn config files may be outdated, or TCP port 443 is blocked. OpenVPN mode will not work.",
                fixAction: "Repopulate OpenVPN configs from NordVPN",
                autoFixAvailable: true,
                category: .openvpnProfiles
            ))
        }

        let joeResults = results.filter { $0.category == .joeURLs }
        let joeFailed = joeResults.filter { !$0.passed }
        if !joeResults.isEmpty && joeFailed.count == joeResults.count {
            findings.append(DiagnosticFinding(
                severity: .critical,
                title: "All Joe Fortune URLs Unreachable",
                explanation: "None of the tested Joe Fortune URLs responded with HTTP 2xx/3xx. The domains may be geo-blocked, the site could be down, or your network/proxy is blocking them.",
                fixAction: "Check if you need to switch to AU region or try a different proxy",
                autoFixAvailable: false,
                category: .joeURLs
            ))
        }

        let ignResults = results.filter { $0.category == .ignitionURLs }
        let ignFailed = ignResults.filter { !$0.passed }
        if !ignResults.isEmpty && ignFailed.count == ignResults.count {
            findings.append(DiagnosticFinding(
                severity: .critical,
                title: "All Ignition URLs Unreachable",
                explanation: "None of the tested Ignition URLs responded. Make sure region is set to AU for Ignition and verify your proxy/VPN can reach Australian servers.",
                fixAction: "Verify region is set to AU",
                autoFixAvailable: false,
                category: .ignitionURLs
            ))
        }

        let fpResults = results.filter { $0.category == .fingerprint }
        let fpFailed = fpResults.filter { !$0.passed }
        if !fpFailed.isEmpty {
            let scores = fpResults.compactMap { $0.latencyMs }
            let maxScore = scores.max() ?? 0
            findings.append(DiagnosticFinding(
                severity: .warning,
                title: "Fingerprint Detection Score Too High (\(maxScore))",
                explanation: "Your WebView fingerprint score exceeds the safe threshold. This means automation detection services may flag your sessions. The anti-bot patches may need updating, or the WebView configuration needs adjusting.",
                fixAction: nil,
                autoFixAvailable: false,
                category: .fingerprint
            ))
        }

        if findings.isEmpty && !results.isEmpty {
            findings.append(DiagnosticFinding(
                severity: .success,
                title: "All Systems Healthy",
                explanation: "All tested components are working correctly. No issues detected.",
                fixAction: nil,
                autoFixAvailable: false,
                category: .complete
            ))
        }

        return findings
    }

    // MARK: - Auto-Repair

    func runAutoRepair() {
        guard !isAutoRepairing, let report = lastReport else { return }
        isAutoRepairing = true
        autoRepairLog.removeAll()

        let fixable = report.diagnostics.filter { $0.autoFixAvailable }
        guard !fixable.isEmpty else {
            autoRepairLog.append("No auto-fixable issues found")
            isAutoRepairing = false
            return
        }

        addLog("AUTO-REPAIR — Starting repair for \(fixable.count) issues", level: .info)

        Task {
            for finding in fixable {
                if Task.isCancelled { break }

                switch finding.category {
                case .wireproxyWebView:
                    await repairWireProxy(finding)
                case .socks5Proxies:
                    await repairProxyMode(finding)
                case .wireguardProfiles:
                    await repairWireGuardConfigs(finding)
                case .openvpnProfiles:
                    await repairOpenVPNConfigs(finding)
                default:
                    autoRepairLog.append("[\(finding.category.rawValue)] No automatic repair available")
                }
            }

            addLog("AUTO-REPAIR — Completed \(autoRepairLog.count) actions", level: .success)
            isAutoRepairing = false
        }
    }

    private func repairWireProxy(_ finding: DiagnosticFinding) async {
        autoRepairLog.append("[WireProxy] Stopping current tunnel...")
        deviceProxy.stopWireProxy()
        try? await Task.sleep(for: .seconds(1))

        autoRepairLog.append("[WireProxy] Rotating to next WireGuard config...")
        deviceProxy.rotateWireProxyConfig()
        try? await Task.sleep(for: .seconds(5))

        if wireProxyBridge.isActive {
            autoRepairLog.append("[WireProxy] ✓ Tunnel re-established successfully")
            addLog("AUTO-REPAIR: WireProxy tunnel re-established", level: .success)
        } else {
            autoRepairLog.append("[WireProxy] ✗ Tunnel still failing — try switching to a different connection mode")
            addLog("AUTO-REPAIR: WireProxy repair failed — tunnel won't establish", level: .error)
        }
    }

    private func repairProxyMode(_ finding: DiagnosticFinding) async {
        autoRepairLog.append("[Proxies] All SOCKS5 proxies failed — switching to WireGuard mode...")
        proxyService.setUnifiedConnectionMode(.wireguard)
        try? await Task.sleep(for: .seconds(1))

        if deviceProxy.ipRoutingMode == .appWideUnited {
            deviceProxy.rotateNow(reason: "Auto-repair: switched to WireGuard")
            try? await Task.sleep(for: .seconds(4))
        }

        autoRepairLog.append("[Proxies] ✓ Switched to WireGuard mode")
        addLog("AUTO-REPAIR: Switched from Proxy to WireGuard mode", level: .success)
    }

    private func repairWireGuardConfigs(_ finding: DiagnosticFinding) async {
        autoRepairLog.append("[WireGuard] Requesting config repopulation from NordVPN...")
        let nordVPN = NordVPNService.shared
        await nordVPN.autoPopulateConfigs(forceRefresh: true)
        try? await Task.sleep(for: .seconds(2))

        let newWGCount = proxyService.joeWGConfigs.count + proxyService.ignitionWGConfigs.count + proxyService.ppsrWGConfigs.count
        if newWGCount > 0 {
            autoRepairLog.append("[WireGuard] ✓ Repopulated \(newWGCount) WireGuard configs")
            addLog("AUTO-REPAIR: Repopulated \(newWGCount) WireGuard configs", level: .success)
        } else {
            autoRepairLog.append("[WireGuard] ✗ Repopulation failed — check NordVPN credentials")
            addLog("AUTO-REPAIR: WireGuard repopulation failed", level: .error)
        }
    }

    private func repairOpenVPNConfigs(_ finding: DiagnosticFinding) async {
        autoRepairLog.append("[OpenVPN] Requesting config repopulation from NordVPN...")
        let nordVPN = NordVPNService.shared
        await nordVPN.autoPopulateConfigs(forceRefresh: true)
        try? await Task.sleep(for: .seconds(2))

        let newVPNCount = proxyService.joeVPNConfigs.count + proxyService.ignitionVPNConfigs.count + proxyService.ppsrVPNConfigs.count
        if newVPNCount > 0 {
            autoRepairLog.append("[OpenVPN] ✓ Repopulated \(newVPNCount) OpenVPN configs")
            addLog("AUTO-REPAIR: Repopulated \(newVPNCount) OpenVPN configs", level: .success)
        } else {
            autoRepairLog.append("[OpenVPN] ✗ Repopulation failed — check NordVPN credentials")
            addLog("AUTO-REPAIR: OpenVPN repopulation failed", level: .error)
        }
    }
}
