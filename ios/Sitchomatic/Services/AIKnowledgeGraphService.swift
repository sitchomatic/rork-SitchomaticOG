import Foundation

@MainActor
class AIKnowledgeGraphService {
    static let shared = AIKnowledgeGraphService()

    private let logger = DebugLogger.shared
    private let persistenceKey = "AIKnowledgeGraph_v2"
    private let maxEvents = 2000
    private let maxCorrelations = 200
    private let eventExpirySeconds: TimeInterval = 48 * 3600
    private let pruneIntervalSeconds: TimeInterval = 1800
    private let correlationCooldownSeconds: TimeInterval = 600
    private let intelligenceCacheTTL: TimeInterval = 300

    private(set) var store: KnowledgeGraphStore

    private var domainSubscribers: [KnowledgeDomain: [(KnowledgeEvent) -> Void]] = [:]

    private init() {
        if let saved = UserDefaults.standard.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode(KnowledgeGraphStore.self, from: saved) {
            self.store = decoded
        } else {
            self.store = KnowledgeGraphStore()
        }
        pruneIfNeeded()
    }

    func publishEvent(
        source: String,
        host: String,
        domain: KnowledgeDomain,
        type: KnowledgeEventType,
        severity: KnowledgeSeverity = .medium,
        confidence: Double,
        payload: [String: String],
        summary: String,
        ttlSeconds: TimeInterval? = nil
    ) {
        let ttl = ttlSeconds ?? eventExpirySeconds
        let event = KnowledgeEvent(
            sourceService: source,
            host: host,
            domain: domain,
            eventType: type,
            severity: severity,
            confidence: confidence,
            payload: payload,
            summary: summary,
            timestamp: Date(),
            expiresAt: Date().addingTimeInterval(ttl)
        )

        store.events.append(event)
        store.totalEventsPublished += 1

        if store.events.count > maxEvents {
            store.events.removeFirst(store.events.count - maxEvents)
        }

        invalidateIntelligenceCache(for: host)

        if let subscribers = domainSubscribers[domain] {
            for callback in subscribers {
                callback(event)
            }
        }

        if severity == .critical || severity == .high {
            logger.log("KnowledgeGraph: [\(severity.rawValue.uppercased())] \(source) → \(domain.rawValue): \(summary)", category: .automation, level: .info)
        }

        pruneIfNeeded()
        save()
    }

    func subscribe(to domain: KnowledgeDomain, handler: @escaping (KnowledgeEvent) -> Void) {
        domainSubscribers[domain, default: []].append(handler)
    }

    func getHostIntelligence(host: String) -> UnifiedHostIntelligence {
        if let cached = store.hostIntelligenceCache[host], !cached.isStale {
            return cached
        }

        let intel = computeHostIntelligence(host: host)
        store.hostIntelligenceCache[host] = intel
        save()
        return intel
    }

    func getRecentEvents(domain: KnowledgeDomain? = nil, host: String? = nil, limit: Int = 50) -> [KnowledgeEvent] {
        var filtered = store.events.filter { !$0.isExpired }
        if let domain { filtered = filtered.filter { $0.domain == domain } }
        if let host { filtered = filtered.filter { $0.host == host } }
        return Array(filtered.sorted { $0.timestamp > $1.timestamp }.prefix(limit))
    }

    func getCorrelations(host: String? = nil) -> [KnowledgeCorrelation] {
        if let host {
            return store.correlations.filter { $0.host == host }
        }
        return store.correlations
    }

    func getAllMonitoredHosts() -> [String] {
        let hosts = Set(store.events.filter { !$0.isExpired }.map(\.host))
        return hosts.sorted()
    }

    func getHostIntelligenceForAll() -> [UnifiedHostIntelligence] {
        getAllMonitoredHosts().map { getHostIntelligence(host: $0) }
    }

    func getDomainEventCounts() -> [KnowledgeDomain: Int] {
        var counts: [KnowledgeDomain: Int] = [:]
        for event in store.events where !event.isExpired {
            counts[event.domain, default: 0] += 1
        }
        return counts
    }

    func getRecentHighSeverityEvents(limit: Int = 20) -> [KnowledgeEvent] {
        store.events
            .filter { !$0.isExpired && ($0.severity == .high || $0.severity == .critical) }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }

    func runCorrelationAnalysis() {
        guard Date().timeIntervalSince(store.lastCorrelationAnalysis) > correlationCooldownSeconds else { return }

        let hosts = getAllMonitoredHosts()
        var newCorrelations: [KnowledgeCorrelation] = []

        for host in hosts {
            let hostEvents = store.events.filter { $0.host == host && !$0.isExpired }
            guard hostEvents.count >= 10 else { continue }

            let domainGroups = Dictionary(grouping: hostEvents, by: \.domain)
            let domains = Array(domainGroups.keys)

            for i in 0..<domains.count {
                for j in (i + 1)..<domains.count {
                    let domainA = domains[i]
                    let domainB = domains[j]
                    let eventsA = domainGroups[domainA] ?? []
                    let eventsB = domainGroups[domainB] ?? []

                    guard eventsA.count >= 3 && eventsB.count >= 3 else { continue }

                    let score = computeTemporalCorrelation(eventsA: eventsA, eventsB: eventsB)
                    guard score >= 0.3 else { continue }

                    let description = describeCorrelation(domainA: domainA, domainB: domainB, score: score, host: host)

                    let correlation = KnowledgeCorrelation(
                        host: host,
                        domainA: domainA,
                        domainB: domainB,
                        correlationScore: score,
                        description: description,
                        sampleSize: eventsA.count + eventsB.count,
                        discoveredAt: Date(),
                        lastConfirmed: Date()
                    )
                    newCorrelations.append(correlation)
                }
            }
        }

        store.correlations = Array(newCorrelations.sorted { $0.correlationScore > $1.correlationScore }.prefix(maxCorrelations))
        store.lastCorrelationAnalysis = Date()
        save()

        logger.log("KnowledgeGraph: correlation analysis complete — \(newCorrelations.count) correlations across \(hosts.count) hosts", category: .automation, level: .info)
    }

    func resetAll() {
        store = KnowledgeGraphStore()
        domainSubscribers = [:]
        save()
        logger.log("KnowledgeGraph: full reset", category: .automation, level: .info)
    }

    var totalActiveEvents: Int {
        store.events.filter { !$0.isExpired }.count
    }

    var totalEventsPublished: Int {
        store.totalEventsPublished
    }

    private func computeHostIntelligence(host: String) -> UnifiedHostIntelligence {
        let hostEvents = store.events.filter { $0.host == host && !$0.isExpired }
        var intel = UnifiedHostIntelligence(host: host)
        intel.eventCount = hostEvents.count
        intel.lastComputed = Date()

        let detectionEvents = hostEvents.filter { $0.domain == .detection }
        if !detectionEvents.isEmpty {
            let highSeverityCount = detectionEvents.filter { $0.severity == .high || $0.severity == .critical }.count
            intel.detectionThreatLevel = min(1.0, Double(highSeverityCount) / max(1.0, Double(detectionEvents.count)) + Double(detectionEvents.count) / 100.0)

            if let latest = detectionEvents.last {
                intel.detectionTrend = latest.payload["trend"] ?? "stable"
            }

            var signalCounts: [String: Int] = [:]
            for e in detectionEvents {
                if let signals = e.payload["signals"] {
                    for s in signals.components(separatedBy: ",") {
                        let trimmed = s.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { signalCounts[trimmed, default: 0] += 1 }
                    }
                }
            }
            intel.topDetectionSignals = signalCounts.sorted { $0.value > $1.value }.prefix(5).map(\.key)
            intel.activeStrategies = detectionEvents.compactMap { $0.payload["strategy"] }.uniqued()
        }

        let proxyEvents = hostEvents.filter { $0.domain == .proxy }
        if !proxyEvents.isEmpty {
            let blockEvents = proxyEvents.filter { $0.payload["blocked"] == "true" }
            intel.proxyBlockRate = Double(blockEvents.count) / Double(proxyEvents.count)

            let latencies = proxyEvents.compactMap { Int($0.payload["latencyMs"] ?? "") }
            if !latencies.isEmpty {
                intel.proxyAvgLatencyMs = latencies.reduce(0, +) / latencies.count
            }

            var proxyScores: [String: Int] = [:]
            for e in proxyEvents where e.payload["success"] == "true" {
                if let pid = e.payload["proxyId"] { proxyScores[pid, default: 0] += 1 }
            }
            intel.bestProxyIds = proxyScores.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        }

        let timingEvents = hostEvents.filter { $0.domain == .timing }
        if !timingEvents.isEmpty {
            let detected = timingEvents.filter { $0.payload["detected"] == "true" }
            intel.timingDetectionRate = Double(detected.count) / Double(timingEvents.count)

            if let latest = timingEvents.last {
                intel.timingProfile.optimalKeystrokeMs = Int(latest.payload["keystrokeMs"] ?? "") ?? 80
                intel.timingProfile.optimalInterFieldMs = Int(latest.payload["interFieldMs"] ?? "") ?? 350
                intel.timingProfile.optimalPreSubmitMs = Int(latest.payload["preSubmitMs"] ?? "") ?? 500
                intel.timingProfile.fillRate = Double(latest.payload["fillRate"] ?? "") ?? 0
            }
        }

        let fpEvents = hostEvents.filter { $0.domain == .fingerprint }
        if !fpEvents.isEmpty {
            let detected = fpEvents.filter { $0.payload["detected"] == "true" }
            intel.fingerprintDetectionRate = Double(detected.count) / Double(fpEvents.count)

            let preferred = fpEvents.compactMap { Int($0.payload["preferredProfile"] ?? "") }
            intel.preferredFingerprintIndices = Array(Set(preferred)).sorted()

            var sigCounts: [String: Int] = [:]
            for e in fpEvents {
                if let sigs = e.payload["signals"] {
                    for s in sigs.components(separatedBy: ",") {
                        let trimmed = s.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { sigCounts[trimmed, default: 0] += 1 }
                    }
                }
            }
            intel.fingerprintTopSignals = sigCounts.sorted { $0.value > $1.value }.prefix(5).map(\.key)
        }

        let credEvents = hostEvents.filter { $0.domain == .credential }
        if !credEvents.isEmpty {
            let successes = credEvents.filter { $0.payload["accountFound"] == "true" }
            intel.credentialDomainSuccessRate = Double(successes.count) / Double(credEvents.count)

            intel.credentialExhaustedDomains = credEvents
                .filter { $0.payload["exhausted"] == "true" }
                .compactMap { $0.payload["domain"] }
                .uniqued()
            intel.credentialHighValueDomains = credEvents
                .filter { $0.payload["highValue"] == "true" }
                .compactMap { $0.payload["domain"] }
                .uniqued()
        }

        let rescueEvents = hostEvents.filter { $0.domain == .rescue }
        if !rescueEvents.isEmpty {
            let rescued = rescueEvents.filter { $0.payload["rescued"] == "true" }
            intel.rescueSuccessRate = Double(rescued.count) / Double(rescueEvents.count)
            intel.rescueAttempts = rescueEvents.count
            intel.commonRescueOutcomes = rescueEvents.compactMap { $0.payload["newOutcome"] }.uniqued()
        }

        let anomalyEvents = hostEvents.filter { $0.domain == .anomaly }
        if !anomalyEvents.isEmpty {
            let critical = anomalyEvents.filter { $0.severity == .critical || $0.severity == .high }
            intel.anomalyRiskLevel = Double(critical.count) / Double(anomalyEvents.count)
            intel.anomalyForecast = anomalyEvents.last?.payload["forecast"] ?? "stable"
            intel.anomalyAlerts = anomalyEvents.filter { $0.severity == .high || $0.severity == .critical }.suffix(3).map(\.summary)
        }

        let interactionEvents = hostEvents.filter { $0.domain == .interaction }
        if !interactionEvents.isEmpty {
            let successes = interactionEvents.filter { $0.payload["success"] == "true" }
            intel.interactionSuccessRate = Double(successes.count) / Double(interactionEvents.count)
            intel.interactionBestPattern = interactionEvents.last?.payload["bestPattern"]
        }

        intel.overallDifficultyScore = computeDifficultyScore(intel: intel)
        intel.correlations = store.correlations.filter { $0.host == host }

        return intel
    }

    private func computeDifficultyScore(intel: UnifiedHostIntelligence) -> Double {
        var score = 0.0
        var weights = 0.0

        let detectionW = 0.30
        score += intel.detectionThreatLevel * detectionW
        weights += detectionW

        let proxyW = 0.15
        score += intel.proxyBlockRate * proxyW
        weights += proxyW

        let fpW = 0.20
        score += intel.fingerprintDetectionRate * fpW
        weights += fpW

        let timingW = 0.10
        score += intel.timingDetectionRate * timingW
        weights += timingW

        let anomalyW = 0.10
        score += intel.anomalyRiskLevel * anomalyW
        weights += anomalyW

        let credW = 0.10
        score += (1.0 - intel.credentialDomainSuccessRate) * credW
        weights += credW

        let rescueW = 0.05
        let rescuePenalty = intel.rescueAttempts > 0 ? (1.0 - intel.rescueSuccessRate) : 0
        score += rescuePenalty * rescueW
        weights += rescueW

        return weights > 0 ? min(1.0, score / weights) : 0
    }

    private func computeTemporalCorrelation(eventsA: [KnowledgeEvent], eventsB: [KnowledgeEvent]) -> Double {
        let windowSeconds: TimeInterval = 300
        var coOccurrences = 0

        for eventA in eventsA {
            let hasNearbyB = eventsB.contains { abs($0.timestamp.timeIntervalSince(eventA.timestamp)) < windowSeconds }
            if hasNearbyB { coOccurrences += 1 }
        }

        let maxPossible = max(eventsA.count, 1)
        return Double(coOccurrences) / Double(maxPossible)
    }

    private func describeCorrelation(domainA: KnowledgeDomain, domainB: KnowledgeDomain, score: Double, host: String) -> String {
        let strength = score >= 0.7 ? "Strong" : score >= 0.5 ? "Moderate" : "Weak"
        return "\(strength) correlation between \(domainA.rawValue) and \(domainB.rawValue) events on \(host) (\(Int(score * 100))%)"
    }

    private func invalidateIntelligenceCache(for host: String) {
        store.hostIntelligenceCache.removeValue(forKey: host)
    }

    private func pruneIfNeeded() {
        guard Date().timeIntervalSince(store.lastPruneDate) > pruneIntervalSeconds else { return }

        let before = store.events.count
        store.events.removeAll { $0.isExpired }

        if store.events.count > maxEvents {
            store.events.removeFirst(store.events.count - maxEvents)
        }

        store.hostIntelligenceCache = [:]
        store.lastPruneDate = Date()

        let pruned = before - store.events.count
        if pruned > 0 {
            logger.log("KnowledgeGraph: pruned \(pruned) expired events", category: .automation, level: .debug)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
