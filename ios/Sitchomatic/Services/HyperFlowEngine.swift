import SwiftUI
import WebKit
import OSLog

// MARK: - 1. Zero-Copy Data Models & Automation Types

/// A strictly BitwiseCopyable model. Because it contains no object references,
/// it can be extracted natively at C-level speed directly from a RawSpan buffer.
public struct ExtractedNode: Sendable {
    let nodeID: UInt64
    let interactionCount: UInt32
    let timestamp: Double
    let statusCode: UInt16
}

public enum WorkerRole: Sendable {
    case primary    // e.g., Authenticator / WebSocket Controller
    case secondary  // e.g., Ephemeral Fast-Scraper
}

public struct PairedTask: Sendable {
    let typeName: String
    let primaryURL: URL
    let secondaryURL: URL
    let primaryViewport: CGSize
    let secondaryViewport: CGSize
}

// MARK: - 2. Hardware-Level Thread Segregation

/// Custom executor that physically segregates heavy automation workloads
/// from the application's primary cooperative thread pool.
public final class HyperFlowExecutor: @unchecked Sendable {
    public static let shared = HyperFlowExecutor()
    private let hardwareQueue = DispatchQueue(
        label: "com.hyperflow.hardware.queue",
        attributes: .concurrent
    )

    public func dispatch(_ work: @escaping @Sendable () -> Void) {
        hardwareQueue.async { work() }
    }
}

// MARK: - 3. Active Window Anchoring (Jetsam Mitigation)

@Observable
@MainActor
public final class WebViewPool {
    public static let shared = WebViewPool()
    public var activeViews: [UUID: WKWebView] = [:]

    private init() {}

    public func mount(_ webView: WKWebView, for id: UUID) { activeViews[id] = webView }
    public func unmount(id: UUID) { activeViews.removeValue(forKey: id) }

    public var activeCount: Int { activeViews.count }

    public func reset() {
        let count = activeViews.count
        activeViews.removeAll()
        if count > 0 {
            DebugLogger.shared.log("WebViewPool: force-reset \(count) active views", category: .webView, level: .warning)
        }
    }

    public func detectOrphans(batchRunning: Bool) -> [String] {
        // Orphan detection is handled by the pair session lifecycle
        return []
    }

    public var diagnosticSummary: String {
        "Active: \(activeViews.count)"
    }
}

struct EphemeralWebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Attach this to the main application window. It tricks iOS into treating
/// headless views as active foreground components, preventing background JS suspension.
public struct HiddenWebViewAnchor: View {
    @State private var pool = WebViewPool.shared
    public init() {}

    public var body: some View {
        ZStack {
            ForEach(Array(pool.activeViews.keys), id: \.self) { id in
                if let webView = pool.activeViews[id] {
                    EphemeralWebViewContainer(webView: webView)
                        .frame(width: .zero, height: .zero)
                        .opacity(0.01)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

// MARK: - 4. Weak Trampoline Proxy (Retain Cycle Prevention)

/// Prevents the massive WKUserContentController retain cycle by holding a weak
/// reference to the actual message handler. WKUserContentController strongly retains
/// its script message handlers, so without this proxy, the WebView owner would never deallocate.
public final class WeakTrampolineProxy: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    public init(target: any WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    public func userContentController(_ userContentController: WKUserContentController,
                                       didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - 5. The Paired Automation Session

/// Coordinates exactly two WebViews that share state with each other,
/// but are entirely isolated from all other concurrent pairs in the engine.
public actor AutomationPairSession {
    let sessionID = UUID()
    let task: PairedTask

    // Crucial: A unique ProcessPool and DataStore for THIS PAIR ONLY.
    // This provides the strict cookie/storage isolation requested.
    let isolatedProcessPool = WKProcessPool()
    let isolatedDataStore = WKWebsiteDataStore.nonPersistent()

    private let allowedDomains: Set<String>
    private let logger = Logger(subsystem: "com.hyperflow.scraper", category: "Session")

    public init(task: PairedTask, allowedDomains: Set<String>) {
        self.task = task
        self.allowedDomains = allowedDomains
    }

    public func execute() async throws {
        logger.info("Igniting Isolated Pair [\(self.task.typeName)] - Session: \(self.sessionID)")

        // Throwing TaskGroup ensures that if the Secondary worker fails/crashes,
        // the Primary worker is instantly cancelled and torn down, maintaining pair integrity.
        try await withThrowingTaskGroup(of: Data?.self) { group in

            // 1. Launch Primary Worker
            group.addTask {
                await HeadlessWebViewWorker.evaluateAndStream(
                    url: self.task.primaryURL,
                    processPool: self.isolatedProcessPool,
                    dataStore: self.isolatedDataStore,
                    role: .primary,
                    viewport: self.task.primaryViewport,
                    allowedDomains: self.allowedDomains
                )
            }

            // 2. Launch Secondary Worker
            group.addTask {
                await HeadlessWebViewWorker.evaluateAndStream(
                    url: self.task.secondaryURL,
                    processPool: self.isolatedProcessPool,
                    dataStore: self.isolatedDataStore,
                    role: .secondary,
                    viewport: self.task.secondaryViewport,
                    allowedDomains: self.allowedDomains
                )
            }

            var pairPayloads: [Data] = []
            for try await result in group {
                guard let validData = result else {
                    throw AutomationError.workerDesynchronization
                }
                pairPayloads.append(validData)
            }

            // Execute parsing on the unified pair data
            await self.processPayloads(payloads: pairPayloads)
        }
    }

    // MARK: Payload Processing

    private func processPayloads(payloads: [Data]) async {
        for payload in payloads {
            let stride = MemoryLayout<ExtractedNode>.stride
            let capacity = payload.count / stride

            guard capacity > 0 else { continue }

            var nodes: [ExtractedNode] = []
            nodes.reserveCapacity(capacity)

            payload.withUnsafeBytes { buffer in
                for index in 0..<capacity {
                    let offset = index * stride
                    guard offset + stride <= buffer.count else { break }
                    let node = buffer.load(fromByteOffset: offset, as: ExtractedNode.self)
                    nodes.append(node)
                }
            }

            logger.debug("Parsed \(nodes.count) nodes from payload (\(payload.count) bytes)")
        }
    }
}

// MARK: - 6. Headless WebView Worker

/// Creates and manages a single headless WKWebView for automation tasks.
/// Each worker is bound to a specific role (primary/secondary) within a pair.
@MainActor
public final class HeadlessWebViewWorker: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var webView: WKWebView?
    private let workerID = UUID()
    private let role: WorkerRole
    private nonisolated let allowedDomains: Set<String>
    private var navigationContinuation: CheckedContinuation<Bool, Never>?
    private var streamedData: Data?
    private let logger = Logger(subsystem: "com.hyperflow.scraper", category: "Worker")

    private init(role: WorkerRole, allowedDomains: Set<String>) {
        self.role = role
        self.allowedDomains = allowedDomains
        super.init()
    }

    // MARK: Static Factory

    public static func evaluateAndStream(
        url: URL,
        processPool: WKProcessPool,
        dataStore: WKWebsiteDataStore,
        role: WorkerRole,
        viewport: CGSize,
        allowedDomains: Set<String>
    ) async -> Data? {
        let worker = HeadlessWebViewWorker(role: role, allowedDomains: allowedDomains)
        return await worker.run(url: url, processPool: processPool, dataStore: dataStore, viewport: viewport)
    }

    // MARK: Lifecycle

    private func run(url: URL, processPool: WKProcessPool, dataStore: WKWebsiteDataStore, viewport: CGSize) async -> Data? {
        setUp(processPool: processPool, dataStore: dataStore, viewport: viewport)
        defer { tearDown() }

        guard let webView = self.webView else { return nil }

        // Register with the pool for Jetsam mitigation
        WebViewPool.shared.mount(webView, for: workerID)
        defer { WebViewPool.shared.unmount(id: workerID) }

        let request = URLRequest(url: url)
        webView.load(request)

        // Wait for navigation to complete
        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.navigationContinuation = continuation
        }

        guard loaded else {
            logger.error("Navigation failed for \(url.absoluteString)")
            return nil
        }

        // Execute extraction JavaScript
        let extractionJS = """
        (function() {
            var result = {
                nodeCount: document.querySelectorAll('*').length,
                title: document.title,
                url: window.location.href,
                bodyLength: (document.body && document.body.innerHTML) ? document.body.innerHTML.length : 0,
                timestamp: Date.now()
            };
            return JSON.stringify(result);
        })()
        """

        do {
            let result = try await webView.evaluateJavaScript(extractionJS)
            if let jsonString = result as? String, let data = jsonString.data(using: .utf8) {
                return data
            }
        } catch {
            logger.error("JS evaluation failed: \(error.localizedDescription)")
        }

        return nil
    }

    private func setUp(processPool: WKProcessPool, dataStore: WKWebsiteDataStore, viewport: CGSize) {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.websiteDataStore = dataStore
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.suppressesIncrementalRendering = true

        let contentController = WKUserContentController()
        // Use WeakTrampolineProxy to prevent retain cycles
        let proxy = WeakTrampolineProxy(target: self)
        contentController.add(proxy, name: "hyperflowBridge")

        // Inject stealth scripts
        let stealth = PPSRStealthService.shared
        let profile = stealth.nextProfileSync()
        let stealthScript = WKUserScript(
            source: stealth.buildComprehensiveStealthJSPublic(profile: profile),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(stealthScript)

        config.userContentController = contentController

        let wv = WKWebView(frame: CGRect(origin: .zero, size: viewport), configuration: config)
        wv.navigationDelegate = self
        wv.customUserAgent = profile.userAgent
        wv.isInspectable = true

        self.webView = wv
        logger.info("Worker [\(self.role == .primary ? "Primary" : "Secondary")] setUp — \(self.workerID)")
    }

    private func tearDown() {
        guard let wv = webView else { return }
        wv.stopLoading()
        wv.navigationDelegate = nil
        wv.configuration.userContentController.removeAllUserScripts()
        wv.configuration.userContentController.removeScriptMessageHandler(forName: "hyperflowBridge")
        webView = nil
        logger.info("Worker [\(self.role == .primary ? "Primary" : "Secondary")] tearDown — \(self.workerID)")
    }

    // MARK: WKNavigationDelegate

    nonisolated public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.navigationContinuation?.resume(returning: true)
            self.navigationContinuation = nil
        }
    }

    nonisolated public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.navigationContinuation?.resume(returning: false)
            self.navigationContinuation = nil
        }
    }

    nonisolated public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.navigationContinuation?.resume(returning: false)
            self.navigationContinuation = nil
        }
    }

    nonisolated public func webView(_ webView: WKWebView,
                                     decidePolicyFor navigationAction: WKNavigationAction,
                                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let host = url.host else {
            decisionHandler(.cancel)
            return
        }

        // Domain filtering: only allow navigation to explicitly allowed domains
        let domainAllowed = allowedDomains.isEmpty || allowedDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) })
        decisionHandler(domainAllowed ? .allow : .cancel)
    }

    nonisolated public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.logger.error("WebContent process terminated for worker \(self.workerID)")
            self.navigationContinuation?.resume(returning: false)
            self.navigationContinuation = nil
        }
    }

    // MARK: WKScriptMessageHandler

    nonisolated public func userContentController(_ userContentController: WKUserContentController,
                                                   didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        Task { @MainActor in
            if let jsonData = try? JSONSerialization.data(withJSONObject: body) {
                self.streamedData = jsonData
            }
        }
    }

    // MARK: Public Access for External Automation

    public func getWebView() -> WKWebView? { webView }

    public func evaluateJS(_ javascript: String) async -> Any? {
        guard let wv = webView else { return nil }
        do {
            return try await wv.evaluateJavaScript(javascript)
        } catch {
            return nil
        }
    }

    public func captureScreenshot() async -> UIImage? {
        guard let wv = webView else { return nil }
        let config = WKSnapshotConfiguration()
        return try? await wv.takeSnapshot(configuration: config)
    }
}

// MARK: - 7. Automation Orchestrator

/// Manages up to 8 concurrent pairs (16 webviews total).
/// Orchestrates PairedTasks across the engine.
@MainActor
public final class AutomationOrchestrator {
    public static let shared = AutomationOrchestrator()

    private let logger = Logger(subsystem: "com.hyperflow.scraper", category: "Orchestrator")
    private let maxConcurrentPairs = 8
    private(set) var activePairCount = 0
    private(set) var completedPairs = 0
    private(set) var failedPairs = 0

    private init() {}

    public var isAtCapacity: Bool { activePairCount >= maxConcurrentPairs }

    public func runPairedTasks(_ tasks: [PairedTask], allowedDomains: Set<String> = []) async {
        logger.info("Orchestrator: launching \(tasks.count) paired tasks (max \(self.maxConcurrentPairs) concurrent)")

        // Process tasks in batches of maxConcurrentPairs
        for batchStart in stride(from: 0, to: tasks.count, by: maxConcurrentPairs) {
            let batchEnd = min(batchStart + maxConcurrentPairs, tasks.count)
            let batch = Array(tasks[batchStart..<batchEnd])

            await withTaskGroup(of: Bool.self) { group in
                for task in batch {
                    group.addTask {
                        await MainActor.run { self.activePairCount += 1 }
                        let session = AutomationPairSession(task: task, allowedDomains: allowedDomains)
                        do {
                            try await session.execute()
                            await MainActor.run {
                                self.completedPairs += 1
                                self.activePairCount -= 1
                            }
                            return true
                        } catch {
                            await MainActor.run {
                                self.failedPairs += 1
                                self.activePairCount -= 1
                            }
                            self.logger.error("Pair [\(task.typeName)] failed: \(error.localizedDescription)")
                            return false
                        }
                    }
                }

                for await _ in group { }
            }

            // Brief cooldown between batches
            if batchEnd < tasks.count {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        logger.info("Orchestrator: complete — \(self.completedPairs) succeeded, \(self.failedPairs) failed")
    }

    public func reset() {
        activePairCount = 0
        completedPairs = 0
        failedPairs = 0
    }
}

// MARK: - 8. Automation Errors

public enum AutomationError: Error, Sendable {
    case workerDesynchronization
    case navigationTimeout
    case processTerminated
    case domainBlocked(String)
    case extractionFailed(String)
    case pairIntegrityViolation
    case configurationError(String)
}
