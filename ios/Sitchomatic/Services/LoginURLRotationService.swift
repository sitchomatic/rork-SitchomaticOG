import Foundation
import Observation

@Observable
@MainActor
class LoginURLRotationService {
    static let shared = LoginURLRotationService()

    var isIgnitionMode: Bool = false {
        didSet { persistState() }
    }

    private(set) var joeURLs: [RotatingURL] = []
    private(set) var ignitionURLs: [RotatingURL] = []
    private var joeIndex: Int = 0
    private var ignitionIndex: Int = 0

    private let persistKey = "login_url_rotation_state_v1"
    private let aiURLOptimizer = AILoginURLOptimizerService.shared

    static let directDNSSafeJoeDomains: Set<String> = [
        "joefortunepokies.win",
        "joefortune36.com",
        "joefortune24.com",
    ]

    var dontAutoDisableURLsForDirectDNS: Bool = false {
        didSet {
            UserDefaults.standard.set(dontAutoDisableURLsForDirectDNS, forKey: "dont_auto_disable_urls_direct_dns")
            if dontAutoDisableURLsForDirectDNS {
                restoreAutoDisabledURLs()
            }
        }
    }

    private var directDNSAutoDisabledJoeURLs: Set<String> = []
    private var directDNSAutoDisabledIgnitionURLs: Set<String> = []

    struct RotatingURL: Identifiable {
        let id: UUID = UUID()
        let urlString: String
        var isEnabled: Bool
        var lastFailure: Date?
        var failCount: Int
        var totalResponseTime: TimeInterval = 0
        var responseCount: Int = 0
        var successCount: Int = 0
        var totalAttempts: Int = 0

        var url: URL? { URL(string: urlString) }
        var host: String { URL(string: urlString)?.host ?? urlString }

        var averageResponseTime: TimeInterval {
            responseCount > 0 ? totalResponseTime / Double(responseCount) : .infinity
        }

        var successRate: Double {
            totalAttempts > 0 ? Double(successCount) / Double(totalAttempts) : 0.5
        }

        var performanceScore: Double {
            guard totalAttempts >= 2 else { return 0.5 }
            let speedScore: Double
            if averageResponseTime < 3 { speedScore = 1.0 }
            else if averageResponseTime < 6 { speedScore = 0.7 }
            else if averageResponseTime < 10 { speedScore = 0.4 }
            else { speedScore = 0.1 }
            return (successRate * 0.6) + (speedScore * 0.4)
        }

        var formattedAvgResponse: String {
            responseCount > 0 ? String(format: "%.1fs", averageResponseTime) : "—"
        }

        var formattedSuccessRate: String {
            totalAttempts > 0 ? String(format: "%.0f%%", successRate * 100) : "—"
        }
    }

    init() {
        joeURLs = Self.defaultJoeURLStrings.map { RotatingURL(urlString: $0, isEnabled: true, lastFailure: nil, failCount: 0) }
        ignitionURLs = Self.defaultIgnitionURLStrings.map { RotatingURL(urlString: $0, isEnabled: true, lastFailure: nil, failCount: 0) }
        dontAutoDisableURLsForDirectDNS = UserDefaults.standard.bool(forKey: "dont_auto_disable_urls_direct_dns")
        loadState()
    }

    static let joeBaseDomains: [String] = [
        "joefortune.eu",
        "joefortune.club",
        "joefortune.eu.com",
        "joefortune.lv",
        "joefortune.ooo",
        "joefortune24.com",
        "joefortune36.com",
        "joefortuneonlinepokies.com",
        "joefortuneonlinepokies.eu",
        "joefortuneonlinepokies.net",
        "joefortunepokies.com",
        "joefortunepokies.eu",
        "joefortunepokies.net",
        "joefortunepokies.win",
    ]

    static let defaultJoeURLStrings: [String] = joeBaseDomains.map { domain in
        return "https://\(domain)/login"
    }

    static let defaultIgnitionURLStrings: [String] = [
        "https://static.ignitioncasino.lat/?overlay=login",
        "https://static.ignitioncasino.cool/?overlay=login",
        "https://static.ignitioncasino.fun/?overlay=login",
        "https://static.ignitioncasino.ooo/?overlay=login",
        "https://static.ignition231.com/?overlay=login",
        "https://static.ignition165.com/?overlay=login",
        "https://static.ignition551.com/?overlay=login",

        "https://static.ignitioncasino.lv/?overlay=login",
        "https://static.ignitioncasino.eu/?overlay=login",
        "https://static.ignitioncasino.eu.com/?overlay=login",
    ]

    var activeURLs: [RotatingURL] {
        isIgnitionMode ? ignitionURLs : joeURLs
    }

    var enabledURLs: [RotatingURL] {
        activeURLs.filter(\.isEnabled)
    }

    var currentSiteName: String {
        isIgnitionMode ? "Ignition Casino" : "Joe Fortune"
    }

    var currentIcon: String {
        isIgnitionMode ? "flame.fill" : "suit.spade.fill"
    }

    func nextURL() -> URL? {
        let urls = enabledURLs
        guard !urls.isEmpty else { return nil }

        let urlStrings = urls.compactMap { $0.urlString }
        let hasAIData = urls.contains { aiURLOptimizer.profileFor(urlString: $0.urlString) != nil }

        if hasAIData, let aiSelected = aiURLOptimizer.selectBestURL(from: urlStrings) {
            return URL(string: aiSelected)
        }

        let hasPerformanceData = urls.contains { $0.totalAttempts >= 2 }

        if hasPerformanceData {
            return weightedRandomURL(from: urls)
        }

        if isIgnitionMode {
            ignitionIndex = ignitionIndex % urls.count
            let url = urls[ignitionIndex].url
            ignitionIndex += 1
            return url
        } else {
            joeIndex = joeIndex % urls.count
            let url = urls[joeIndex].url
            joeIndex += 1
            return url
        }
    }

    func pingURL(_ urlString: String, timeout: TimeInterval = 8) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode >= 300 && http.statusCode < 400 {
                    return false
                }
                return http.statusCode >= 200 && http.statusCode < 400
            }
            return false
        } catch {
            return false
        }
    }

    func resolveJoeURL(baseDomain: String) async -> String? {
        let baseURL = "https://\(baseDomain)/login"
        if await pingURL(baseURL) {
            return baseURL
        }
        let wwwURL = "https://www.\(baseDomain)/login"
        if await pingURL(wwwURL) {
            return wwwURL
        }
        return nil
    }

    func validateAndUpdateJoeURLs() async {
        var updated = 0
        var disabled = 0
        for i in joeURLs.indices {
            let urlStr = joeURLs[i].urlString
            guard let url = URL(string: urlStr), let host = url.host else { continue }

            let baseDomain: String
            if host.hasPrefix("www.") {
                baseDomain = String(host.dropFirst(4))
            } else {
                baseDomain = host
            }

            let baseURL = "https://\(baseDomain)/login"
            if await pingURL(baseURL) {
                if joeURLs[i].urlString != baseURL {
                    joeURLs[i] = RotatingURL(urlString: baseURL, isEnabled: true, lastFailure: nil, failCount: 0)
                    updated += 1
                }
                continue
            }

            let wwwURL = "https://www.\(baseDomain)/login"
            if await pingURL(wwwURL) {
                if joeURLs[i].urlString != wwwURL {
                    joeURLs[i] = RotatingURL(urlString: wwwURL, isEnabled: true, lastFailure: nil, failCount: 0)
                    updated += 1
                }
                continue
            }

            joeURLs[i].isEnabled = false
            disabled += 1
        }
        if updated > 0 || disabled > 0 {
            persistState()
        }
    }

    private func weightedRandomURL(from urls: [RotatingURL]) -> URL? {
        let scores = urls.map { max($0.performanceScore, 0.05) }
        let totalWeight = scores.reduce(0, +)
        var random = Double.random(in: 0..<totalWeight)

        for (index, score) in scores.enumerated() {
            random -= score
            if random <= 0 {
                return urls[index].url
            }
        }
        return urls.last?.url
    }

    func reportFailure(urlString: String) {
        if let idx = joeURLs.firstIndex(where: { $0.urlString == urlString }) {
            joeURLs[idx].failCount += 1
            joeURLs[idx].lastFailure = Date()
            joeURLs[idx].totalAttempts += 1
            if joeURLs[idx].failCount >= 2 {
                joeURLs[idx].isEnabled = false
            }
        }
        if let idx = ignitionURLs.firstIndex(where: { $0.urlString == urlString }) {
            ignitionURLs[idx].failCount += 1
            ignitionURLs[idx].lastFailure = Date()
            ignitionURLs[idx].totalAttempts += 1
            if ignitionURLs[idx].failCount >= 2 {
                ignitionURLs[idx].isEnabled = false
            }
        }
        persistState()
    }

    func reportSuccess(urlString: String) {
        if let idx = joeURLs.firstIndex(where: { $0.urlString == urlString }) {
            joeURLs[idx].failCount = 0
            joeURLs[idx].successCount += 1
            joeURLs[idx].totalAttempts += 1
        }
        if let idx = ignitionURLs.firstIndex(where: { $0.urlString == urlString }) {
            ignitionURLs[idx].failCount = 0
            ignitionURLs[idx].successCount += 1
            ignitionURLs[idx].totalAttempts += 1
        }
    }

    func reportResponseTime(urlString: String, duration: TimeInterval) {
        if let idx = joeURLs.firstIndex(where: { $0.urlString == urlString }) {
            joeURLs[idx].totalResponseTime += duration
            joeURLs[idx].responseCount += 1
        }
        if let idx = ignitionURLs.firstIndex(where: { $0.urlString == urlString }) {
            ignitionURLs[idx].totalResponseTime += duration
            ignitionURLs[idx].responseCount += 1
        }
    }

    func resetPerformanceStats() {
        for i in joeURLs.indices {
            joeURLs[i].totalResponseTime = 0
            joeURLs[i].responseCount = 0
            joeURLs[i].successCount = 0
            joeURLs[i].totalAttempts = 0
        }
        for i in ignitionURLs.indices {
            ignitionURLs[i].totalResponseTime = 0
            ignitionURLs[i].responseCount = 0
            ignitionURLs[i].successCount = 0
            ignitionURLs[i].totalAttempts = 0
        }
        persistState()
    }

    func toggleURL(id: UUID, enabled: Bool) {
        if let idx = joeURLs.firstIndex(where: { $0.id == id }) {
            joeURLs[idx].isEnabled = enabled
            joeURLs[idx].failCount = enabled ? 0 : joeURLs[idx].failCount
        }
        if let idx = ignitionURLs.firstIndex(where: { $0.id == id }) {
            ignitionURLs[idx].isEnabled = enabled
            ignitionURLs[idx].failCount = enabled ? 0 : ignitionURLs[idx].failCount
        }
        persistState()
    }

    func enableAllURLs() {
        for i in joeURLs.indices {
            joeURLs[i].isEnabled = true
            joeURLs[i].failCount = 0
            joeURLs[i].lastFailure = nil
        }
        for i in ignitionURLs.indices {
            ignitionURLs[i].isEnabled = true
            ignitionURLs[i].failCount = 0
            ignitionURLs[i].lastFailure = nil
        }
        persistState()
    }

    func addURL(_ urlString: String, forIgnition: Bool) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else { return false }
        if forIgnition {
            guard !ignitionURLs.contains(where: { $0.urlString == trimmed }) else { return false }
            ignitionURLs.append(RotatingURL(urlString: trimmed, isEnabled: true, lastFailure: nil, failCount: 0))
        } else {
            guard !joeURLs.contains(where: { $0.urlString == trimmed }) else { return false }
            joeURLs.append(RotatingURL(urlString: trimmed, isEnabled: true, lastFailure: nil, failCount: 0))
        }
        persistState()
        return true
    }

    func bulkImportURLs(_ text: String, forIgnition: Bool) -> (added: Int, duplicates: Int, invalid: Int) {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var added = 0
        var duplicates = 0
        var invalid = 0
        for line in lines {
            var urlStr = line
            if !urlStr.hasPrefix("http") { urlStr = "https://" + urlStr }
            guard URL(string: urlStr) != nil else { invalid += 1; continue }
            let existing = forIgnition ? ignitionURLs : joeURLs
            if existing.contains(where: { $0.urlString == urlStr }) {
                duplicates += 1
                continue
            }
            let entry = RotatingURL(urlString: urlStr, isEnabled: true, lastFailure: nil, failCount: 0)
            if forIgnition { ignitionURLs.append(entry) } else { joeURLs.append(entry) }
            added += 1
        }
        if added > 0 { persistState() }
        return (added, duplicates, invalid)
    }

    func deleteURL(id: UUID) {
        joeURLs.removeAll { $0.id == id }
        ignitionURLs.removeAll { $0.id == id }
        persistState()
    }

    func deleteAllURLs(forIgnition: Bool) {
        if forIgnition {
            ignitionURLs.removeAll()
        } else {
            joeURLs.removeAll()
        }
        persistState()
    }

    func resetToDefaults(forIgnition: Bool) {
        if forIgnition {
            ignitionURLs = Self.defaultIgnitionURLStrings.map { RotatingURL(urlString: $0, isEnabled: true, lastFailure: nil, failCount: 0) }
        } else {
            joeURLs = Self.defaultJoeURLStrings.map { RotatingURL(urlString: $0, isEnabled: true, lastFailure: nil, failCount: 0) }
        }
        persistState()
    }

    var topPerformingURLs: [RotatingURL] {
        enabledURLs.filter { $0.totalAttempts >= 2 }.sorted { $0.performanceScore > $1.performanceScore }
    }

    var aiRankedURLs: [(url: String, score: Double, attempts: Int, successRate: Int, avgLatency: Int, blocked: Int)] {
        let urlStrings = enabledURLs.map { $0.urlString }
        return aiURLOptimizer.rankedURLs(from: urlStrings)
    }

    func aiProfileFor(urlString: String) -> URLPerformanceProfile? {
        aiURLOptimizer.profileFor(urlString: urlString)
    }

    func resetAIURLData() {
        aiURLOptimizer.resetAll()
    }

    func applyDirectDNSAutoDisable() {
        guard !dontAutoDisableURLsForDirectDNS else { return }
        directDNSAutoDisabledJoeURLs.removeAll()
        directDNSAutoDisabledIgnitionURLs.removeAll()

        for i in joeURLs.indices {
            let host = extractBaseDomain(from: joeURLs[i].urlString)
            if !Self.directDNSSafeJoeDomains.contains(host) && joeURLs[i].isEnabled {
                joeURLs[i].isEnabled = false
                directDNSAutoDisabledJoeURLs.insert(joeURLs[i].urlString)
            }
        }

        for i in ignitionURLs.indices {
            if ignitionURLs[i].isEnabled {
                ignitionURLs[i].isEnabled = false
                directDNSAutoDisabledIgnitionURLs.insert(ignitionURLs[i].urlString)
            }
        }

        let joeDisabled = directDNSAutoDisabledJoeURLs.count
        let ignDisabled = directDNSAutoDisabledIgnitionURLs.count
        if joeDisabled > 0 || ignDisabled > 0 {
            persistState()
        }
    }

    func restoreAutoDisabledURLs() {
        var restored = 0
        for urlStr in directDNSAutoDisabledJoeURLs {
            if let idx = joeURLs.firstIndex(where: { $0.urlString == urlStr }) {
                joeURLs[idx].isEnabled = true
                joeURLs[idx].failCount = 0
                restored += 1
            }
        }
        for urlStr in directDNSAutoDisabledIgnitionURLs {
            if let idx = ignitionURLs.firstIndex(where: { $0.urlString == urlStr }) {
                ignitionURLs[idx].isEnabled = true
                ignitionURLs[idx].failCount = 0
                restored += 1
            }
        }
        directDNSAutoDisabledJoeURLs.removeAll()
        directDNSAutoDisabledIgnitionURLs.removeAll()
        if restored > 0 { persistState() }
    }

    var isDirectDNSAutoDisableActive: Bool {
        !directDNSAutoDisabledJoeURLs.isEmpty || !directDNSAutoDisabledIgnitionURLs.isEmpty
    }

    var directDNSAutoDisabledCount: Int {
        directDNSAutoDisabledJoeURLs.count + directDNSAutoDisabledIgnitionURLs.count
    }

    func isDirectDNSAutoDisabled(urlString: String) -> Bool {
        directDNSAutoDisabledJoeURLs.contains(urlString) || directDNSAutoDisabledIgnitionURLs.contains(urlString)
    }

    private func extractBaseDomain(from urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else { return urlString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func persistState() {
        var disabledJoe: [String] = []
        for u in joeURLs where !u.isEnabled { disabledJoe.append(u.urlString) }
        var disabledIgnition: [String] = []
        for u in ignitionURLs where !u.isEnabled { disabledIgnition.append(u.urlString) }

        var perfJoe: [String: [String: Double]] = [:]
        for u in joeURLs where u.totalAttempts > 0 {
            perfJoe[u.urlString] = [
                "totalResponseTime": u.totalResponseTime,
                "responseCount": Double(u.responseCount),
                "successCount": Double(u.successCount),
                "totalAttempts": Double(u.totalAttempts),
            ]
        }
        var perfIgnition: [String: [String: Double]] = [:]
        for u in ignitionURLs where u.totalAttempts > 0 {
            perfIgnition[u.urlString] = [
                "totalResponseTime": u.totalResponseTime,
                "responseCount": Double(u.responseCount),
                "successCount": Double(u.successCount),
                "totalAttempts": Double(u.totalAttempts),
            ]
        }

        let dict: [String: Any] = [
            "isIgnitionMode": isIgnitionMode,
            "disabledJoe": disabledJoe,
            "disabledIgnition": disabledIgnition,
            "perfJoe": perfJoe,
            "perfIgnition": perfIgnition,
        ]
        UserDefaults.standard.set(dict, forKey: persistKey)
    }

    private func loadState() {
        guard let dict = UserDefaults.standard.dictionary(forKey: persistKey) else { return }
        if let mode = dict["isIgnitionMode"] as? Bool { isIgnitionMode = mode }
        if let disabled = dict["disabledJoe"] as? [String] {
            for url in disabled {
                if let idx = joeURLs.firstIndex(where: { $0.urlString == url }) {
                    joeURLs[idx].isEnabled = false
                }
            }
        }
        if let disabled = dict["disabledIgnition"] as? [String] {
            for url in disabled {
                if let idx = ignitionURLs.firstIndex(where: { $0.urlString == url }) {
                    ignitionURLs[idx].isEnabled = false
                }
            }
        }
        if let perfJoe = dict["perfJoe"] as? [String: [String: Double]] {
            for (urlStr, stats) in perfJoe {
                if let idx = joeURLs.firstIndex(where: { $0.urlString == urlStr }) {
                    joeURLs[idx].totalResponseTime = stats["totalResponseTime"] ?? 0
                    joeURLs[idx].responseCount = Int(stats["responseCount"] ?? 0)
                    joeURLs[idx].successCount = Int(stats["successCount"] ?? 0)
                    joeURLs[idx].totalAttempts = Int(stats["totalAttempts"] ?? 0)
                }
            }
        }
        if let perfIgnition = dict["perfIgnition"] as? [String: [String: Double]] {
            for (urlStr, stats) in perfIgnition {
                if let idx = ignitionURLs.firstIndex(where: { $0.urlString == urlStr }) {
                    ignitionURLs[idx].totalResponseTime = stats["totalResponseTime"] ?? 0
                    ignitionURLs[idx].responseCount = Int(stats["responseCount"] ?? 0)
                    ignitionURLs[idx].successCount = Int(stats["successCount"] ?? 0)
                    ignitionURLs[idx].totalAttempts = Int(stats["totalAttempts"] ?? 0)
                }
            }
        }
    }
}
