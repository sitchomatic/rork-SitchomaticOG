import Foundation
import WebKit

nonisolated struct WebViewMemoryProfile: Codable, Sendable {
    let sessionId: String
    let host: String
    let memoryBeforeMB: Int
    let memoryAfterMB: Int
    let estimatedFootprintMB: Int
    let durationSeconds: Int
    let wasBloated: Bool
    let wasRecycled: Bool
    let timestamp: Date
}

nonisolated struct HostMemoryProfile: Codable, Sendable {
    var host: String
    var sampleCount: Int = 0
    var totalFootprintMB: Int = 0
    var peakFootprintMB: Int = 0
    var bloatCount: Int = 0
    var recycleCount: Int = 0
    var aiRiskScore: Double?
    var lastUpdated: Date = Date()

    var avgFootprintMB: Int {
        guard sampleCount > 0 else { return 0 }
        return totalFootprintMB / sampleCount
    }

    var bloatRate: Double {
        guard sampleCount > 0 else { return 0 }
        return Double(bloatCount) / Double(sampleCount)
    }
}

nonisolated struct MemoryLifecycleStore: Codable, Sendable {
    var hostProfiles: [String: HostMemoryProfile] = [:]
    var recentProfiles: [WebViewMemoryProfile] = []
    var totalTracked: Int = 0
    var totalBloatDetected: Int = 0
    var totalRecycled: Int = 0
    var totalAIAnalyses: Int = 0
}

@MainActor
class AIWebViewMemoryLifecycleManager {
    static let shared = AIWebViewMemoryLifecycleManager()

    private let logger = DebugLogger.shared
    private let crashProtection = CrashProtectionService.shared
    private let persistKey = "AIWebViewMemoryLifecycleManager_v1"
    private var store: MemoryLifecycleStore

    private var activeSessions: [String: ActiveWebViewSession] = [:]
    private var monitorTask: Task<Void, Never>?
    private var isActive: Bool = false

    private let bloatThresholdMB: Int = 150
    private let criticalBloatThresholdMB: Int = 250
    private let monitorIntervalSeconds: TimeInterval = 8
    private let maxRecentProfiles = 500
    private let aiAnalysisCooldownSeconds: TimeInterval = 120
    private var lastAIAnalysisTime: Date = .distantPast

    private struct ActiveWebViewSession {
        let sessionId: String
        let host: String
        let memoryAtStartMB: Int
        let startTime: Date
        weak var webView: WKWebView?
        var lastCheckMB: Int
        var checkCount: Int = 0
    }

    var onSessionRecycleNeeded: ((String) -> Void)?

    init() {
        if let data = UserDefaults.standard.data(forKey: persistKey),
           let decoded = try? JSONDecoder().decode(MemoryLifecycleStore.self, from: data) {
            self.store = decoded
        } else {
            self.store = MemoryLifecycleStore()
        }
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        startMonitoring()
        logger.log("WebViewMemoryManager: started (bloatThreshold=\(bloatThresholdMB)MB, criticalThreshold=\(criticalBloatThresholdMB)MB)", category: .system, level: .info)
    }

    func stop() {
        isActive = false
        monitorTask?.cancel()
        monitorTask = nil
        activeSessions.removeAll()
        logger.log("WebViewMemoryManager: stopped", category: .system, level: .info)
    }

    func trackSessionStart(sessionId: String, host: String, webView: WKWebView) {
        let memMB = crashProtection.currentMemoryUsageMB()
        activeSessions[sessionId] = ActiveWebViewSession(
            sessionId: sessionId,
            host: host,
            memoryAtStartMB: memMB,
            startTime: Date(),
            webView: webView,
            lastCheckMB: memMB
        )
    }

    func trackSessionEnd(sessionId: String) {
        guard let session = activeSessions.removeValue(forKey: sessionId) else { return }

        let memAfterMB = crashProtection.currentMemoryUsageMB()
        let footprint = max(0, memAfterMB - session.memoryAtStartMB)
        let activeSessCount = activeSessions.count
        let estimatedPerSession = activeSessCount > 0 ? footprint : footprint
        let duration = Int(Date().timeIntervalSince(session.startTime))
        let isBloated = estimatedPerSession > bloatThresholdMB

        let profile = WebViewMemoryProfile(
            sessionId: session.sessionId,
            host: session.host,
            memoryBeforeMB: session.memoryAtStartMB,
            memoryAfterMB: memAfterMB,
            estimatedFootprintMB: estimatedPerSession,
            durationSeconds: duration,
            wasBloated: isBloated,
            wasRecycled: false,
            timestamp: Date()
        )
        recordProfile(profile)

        AIPredictiveConcurrencyGovernor.shared.recordHostMemoryImpact(host: session.host, estimatedMB: Double(estimatedPerSession))

        if isBloated {
            AISessionHealthMonitorService.shared.recordSnapshot(SessionHealthSnapshot(
                sessionId: session.sessionId,
                host: session.host,
                urlString: "",
                pageLoadTimeMs: duration * 1000,
                outcome: "bloated_memory",
                wasTimeout: false,
                wasBlankPage: false,
                wasCrash: false,
                wasChallenge: false,
                wasConnectionFailure: false,
                fingerprintDetected: false,
                circuitBreakerOpen: false,
                consecutiveFailuresOnHost: 0,
                activeSessions: activeSessCount,
                timestamp: Date()
            ))
        }
    }

    func isHostHighRisk(_ host: String) -> Bool {
        guard let profile = store.hostProfiles[host] else { return false }
        if let aiScore = profile.aiRiskScore, aiScore > 0.7 { return true }
        return profile.bloatRate > 0.4 && profile.sampleCount >= 3
    }

    func recommendedTimeoutForHost(_ host: String, defaultTimeout: TimeInterval) -> TimeInterval {
        guard let profile = store.hostProfiles[host], profile.sampleCount >= 3 else {
            return defaultTimeout
        }
        if profile.bloatRate > 0.5 {
            return defaultTimeout * 0.6
        }
        if profile.bloatRate > 0.3 {
            return defaultTimeout * 0.8
        }
        return defaultTimeout
    }

    func hostMemorySummary() -> [(host: String, avgMB: Int, bloatRate: Int, samples: Int, risk: String)] {
        store.hostProfiles.values.map { profile in
            let risk: String
            if let ai = profile.aiRiskScore {
                risk = ai > 0.7 ? "HIGH" : (ai > 0.4 ? "MODERATE" : "LOW")
            } else {
                risk = profile.bloatRate > 0.4 ? "HIGH" : (profile.bloatRate > 0.2 ? "MODERATE" : "LOW")
            }
            return (
                host: profile.host,
                avgMB: profile.avgFootprintMB,
                bloatRate: Int(profile.bloatRate * 100),
                samples: profile.sampleCount,
                risk: risk
            )
        }.sorted { $0.bloatRate > $1.bloatRate }
    }

    func resetAll() {
        store = MemoryLifecycleStore()
        activeSessions.removeAll()
        save()
        logger.log("WebViewMemoryManager: RESET", category: .system, level: .warning)
    }

    var diagnosticSummary: String {
        let active = activeSessions.count
        let hosts = store.hostProfiles.count
        let bloated = store.totalBloatDetected
        let recycled = store.totalRecycled
        return "WVMemory: active=\(active) hosts=\(hosts) bloated=\(bloated) recycled=\(recycled) ai=\(store.totalAIAnalyses)"
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isActive else { return }
                try? await Task.sleep(for: .seconds(self.monitorIntervalSeconds))
                guard !Task.isCancelled, self.isActive else { return }
                self.checkActiveSessions()
            }
        }
    }

    private func checkActiveSessions() {
        guard !activeSessions.isEmpty else { return }

        let currentMB = crashProtection.currentMemoryUsageMB()
        var sessionsToRecycle: [String] = []

        for (sessionId, session) in activeSessions {
            guard session.webView != nil else {
                activeSessions.removeValue(forKey: sessionId)
                continue
            }

            let elapsed = Date().timeIntervalSince(session.startTime)
            let memGrowth = currentMB - session.memoryAtStartMB
            let perSessionEstimate = activeSessions.count > 1 ? memGrowth / activeSessions.count : memGrowth

            activeSessions[sessionId]?.lastCheckMB = currentMB
            activeSessions[sessionId]?.checkCount += 1

            if perSessionEstimate > criticalBloatThresholdMB {
                logger.log("WebViewMemoryManager: CRITICAL BLOAT on \(session.host) session \(sessionId) — est \(perSessionEstimate)MB after \(Int(elapsed))s", category: .system, level: .critical)
                sessionsToRecycle.append(sessionId)
            } else if perSessionEstimate > bloatThresholdMB && elapsed > 30 {
                logger.log("WebViewMemoryManager: bloat detected on \(session.host) session \(sessionId) — est \(perSessionEstimate)MB after \(Int(elapsed))s", category: .system, level: .warning)
                sessionsToRecycle.append(sessionId)
            }
        }

        for sessionId in sessionsToRecycle {
            guard let session = activeSessions[sessionId] else { continue }

            if let webView = session.webView {
                injectTeardownScript(webView: webView, sessionId: sessionId)
            }

            store.totalRecycled += 1
            var hostProfile = store.hostProfiles[session.host] ?? HostMemoryProfile(host: session.host)
            hostProfile.recycleCount += 1
            store.hostProfiles[session.host] = hostProfile
            save()

            onSessionRecycleNeeded?(sessionId)

            logger.log("WebViewMemoryManager: flagged \(sessionId) (\(session.host)) for recycle", category: .system, level: .warning)
        }

        let shouldAnalyzeAI = store.totalTracked > 0
            && store.totalTracked % 20 == 0
            && Date().timeIntervalSince(lastAIAnalysisTime) > aiAnalysisCooldownSeconds
            && store.hostProfiles.values.contains(where: { $0.sampleCount >= 5 })

        if shouldAnalyzeAI {
            Task {
                await requestAIAnalysis()
            }
        }
    }

    private func injectTeardownScript(webView: WKWebView, sessionId: String) {
        let script = """
        (function() {
            try {
                var imgs = document.querySelectorAll('img, video, canvas, iframe');
                for (var i = 0; i < imgs.length; i++) {
                    if (imgs[i].tagName === 'IMG') { imgs[i].src = ''; }
                    else if (imgs[i].tagName === 'VIDEO') { imgs[i].pause(); imgs[i].src = ''; }
                    else if (imgs[i].tagName === 'IFRAME') { imgs[i].src = 'about:blank'; }
                    else if (imgs[i].tagName === 'CANVAS') {
                        var ctx = imgs[i].getContext('2d');
                        if (ctx) ctx.clearRect(0, 0, imgs[i].width, imgs[i].height);
                    }
                }
                var intervals = [];
                var oldSetInterval = window.setInterval;
                window.setInterval = function() { return 0; };
                for (var j = 1; j < 10000; j++) { clearInterval(j); clearTimeout(j); }
                window.setInterval = oldSetInterval;
                if (window.gc) window.gc();
            } catch(e) {}
        })();
        """
        webView.evaluateJavaScript(script) { _, _ in }
        logger.log("WebViewMemoryManager: injected teardown script for \(sessionId)", category: .webView, level: .debug)
    }

    private func recordProfile(_ profile: WebViewMemoryProfile) {
        store.totalTracked += 1
        if profile.wasBloated { store.totalBloatDetected += 1 }

        store.recentProfiles.append(profile)
        if store.recentProfiles.count > maxRecentProfiles {
            store.recentProfiles.removeFirst(store.recentProfiles.count - maxRecentProfiles)
        }

        var hostProfile = store.hostProfiles[profile.host] ?? HostMemoryProfile(host: profile.host)
        hostProfile.sampleCount += 1
        hostProfile.totalFootprintMB += profile.estimatedFootprintMB
        hostProfile.peakFootprintMB = max(hostProfile.peakFootprintMB, profile.estimatedFootprintMB)
        if profile.wasBloated { hostProfile.bloatCount += 1 }
        hostProfile.lastUpdated = Date()
        store.hostProfiles[profile.host] = hostProfile

        save()

        if profile.wasBloated {
            logger.log("WebViewMemoryManager: bloat recorded for \(profile.host) — \(profile.estimatedFootprintMB)MB footprint in \(profile.durationSeconds)s (bloatRate=\(Int(hostProfile.bloatRate * 100))%)", category: .system, level: .warning)
        }
    }

    private func requestAIAnalysis() async {
        lastAIAnalysisTime = Date()
        store.totalAIAnalyses += 1

        let profiles = store.hostProfiles.values.filter { $0.sampleCount >= 5 }
        guard !profiles.isEmpty else { return }

        var hostData: [[String: Any]] = []
        for p in profiles {
            hostData.append([
                "host": p.host,
                "avgFootprintMB": p.avgFootprintMB,
                "peakMB": p.peakFootprintMB,
                "bloatRate": Int(p.bloatRate * 100),
                "recycleCount": p.recycleCount,
                "samples": p.sampleCount,
            ])
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: ["hosts": hostData]),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

        let systemPrompt = """
        You analyze WebView memory footprints for web automation. \
        Each host has memory usage data from multiple sessions. \
        Return ONLY a JSON array: [{"host":"...","riskScore":0.0-1.0,"recommendation":"..."}]. \
        riskScore > 0.7 means the host consistently causes memory bloat and should have reduced concurrency. \
        riskScore < 0.3 means the host is memory-efficient. \
        Consider peak memory, bloat rate, and average footprint. Return ONLY JSON.
        """

        guard let response = await RorkToolkitService.shared.generateText(systemPrompt: systemPrompt, userPrompt: "WebView memory data:\n\(jsonStr)") else {
            logger.log("WebViewMemoryManager: AI analysis failed — no response", category: .system, level: .warning)
            return
        }

        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            logger.log("WebViewMemoryManager: failed to parse AI response", category: .system, level: .warning)
            return
        }

        var applied = 0
        for entry in json {
            guard let host = entry["host"] as? String,
                  let riskScore = entry["riskScore"] as? Double else { continue }
            guard var profile = store.hostProfiles[host] else { continue }
            profile.aiRiskScore = max(0, min(1.0, riskScore))
            store.hostProfiles[host] = profile
            applied += 1
            logger.log("WebViewMemoryManager: AI risk \(host) → \(String(format: "%.2f", riskScore))", category: .system, level: .info)
        }

        save()
        logger.log("WebViewMemoryManager: AI analysis applied to \(applied)/\(json.count) hosts", category: .system, level: .success)
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(encoded, forKey: persistKey)
        }
    }
}
