import Foundation

@MainActor
class AISwarmIntelligenceService {
    static let shared = AISwarmIntelligenceService()

    private let logger = DebugLogger.shared
    private let knowledgeGraph = AIKnowledgeGraphService.shared
    private let persistenceKey = "AISwarmIntelligence_v1"
    private let coordinationIntervalSeconds: TimeInterval = 10
    private let signalTTLDefault: TimeInterval = 300
    private let consensusThreshold: Double = 0.6
    private let minVotersForConsensus: Int = 2

    private(set) var store: SwarmCoordinationState

    private var signalSubscribers: [(SwarmSignal) -> Void] = []

    private init() {
        if let saved = UserDefaults.standard.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode(SwarmCoordinationState.self, from: saved) {
            self.store = decoded
        } else {
            self.store = SwarmCoordinationState()
        }
        pruneExpiredSignals()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(data, forKey: persistenceKey)
        }
    }

    func registerSession(sessionId: String, host: String, role: SessionRole = .worker) -> SessionStrategyProfile {
        if let existing = store.activeProfiles.first(where: { $0.sessionId == sessionId }) {
            return existing
        }

        var profile = SessionStrategyProfile(sessionId: sessionId, host: host, role: role)

        let intel = knowledgeGraph.getHostIntelligence(host: host)
        if !intel.bestProxyIds.isEmpty {
            profile.preferredProxyIds = intel.bestProxyIds
        }
        profile.optimalKeystrokeMs = intel.timingProfile.optimalKeystrokeMs
        profile.optimalInterFieldMs = intel.timingProfile.optimalInterFieldMs
        profile.optimalPreSubmitMs = intel.timingProfile.optimalPreSubmitMs
        if !intel.preferredFingerprintIndices.isEmpty {
            profile.preferredFingerprintIndex = intel.preferredFingerprintIndices.first ?? 0
        }

        store.activeProfiles.append(profile)
        if store.activeProfiles.count > store.maxProfiles {
            store.activeProfiles.removeFirst(store.activeProfiles.count - store.maxProfiles)
        }

        logger.log("Swarm: registered session \(sessionId.prefix(8)) as \(role.rawValue) for \(host)", category: .automation, level: .info)
        save()
        return profile
    }

    func unregisterSession(sessionId: String) {
        store.activeProfiles.removeAll { $0.sessionId == sessionId }
        store.pendingSignals.removeAll { $0.sessionId == sessionId }
        store.recentVotes.removeAll { $0.sessionId == sessionId }
        logger.log("Swarm: unregistered session \(sessionId.prefix(8))", category: .automation, level: .info)
        save()
    }

    func broadcastSignal(
        sessionId: String,
        host: String,
        type: SwarmSignalType,
        priority: SwarmSignalPriority = .normal,
        payload: [String: String],
        confidence: Double
    ) {
        let signal = SwarmSignal(
            sessionId: sessionId,
            host: host,
            signalType: type,
            priority: priority,
            payload: payload,
            confidence: confidence,
            timestamp: Date(),
            ttlSeconds: signalTTLDefault
        )

        store.pendingSignals.append(signal)
        store.totalSignalsBroadcast += 1

        if store.pendingSignals.count > store.maxPendingSignals {
            store.pendingSignals.removeFirst(store.pendingSignals.count - store.maxPendingSignals)
        }

        for subscriber in signalSubscribers {
            subscriber(signal)
        }

        publishSignalToKnowledgeGraph(signal)

        if priority == .urgent || priority == .high {
            logger.log("Swarm: [\(priority.rawValue.uppercased())] \(type.rawValue) from \(sessionId.prefix(8)) → \(host)", category: .automation, level: .info)
        }

        save()
    }

    func subscribeToSignals(handler: @escaping (SwarmSignal) -> Void) {
        signalSubscribers.append(handler)
    }

    func consumeSignals(forSession sessionId: String, host: String) -> [SwarmSignal] {
        pruneExpiredSignals()
        return store.pendingSignals.filter { $0.sessionId != sessionId && $0.host == host && !$0.isExpired }
    }

    func recordSessionOutcome(sessionId: String, success: Bool, latencyMs: Int) {
        guard let index = store.activeProfiles.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        store.activeProfiles[index].recordOutcome(success: success, latencyMs: latencyMs)
        save()
    }

    func recordDetectionEvent(sessionId: String) {
        guard let index = store.activeProfiles.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        store.activeProfiles[index].detectionEvents += 1
        save()
    }

    func castVote(
        sessionId: String,
        host: String,
        strategyKey: String,
        strategyValue: String,
        confidence: Double,
        evidence: String
    ) {
        let vote = SwarmStrategyVote(
            sessionId: sessionId,
            host: host,
            strategyKey: strategyKey,
            strategyValue: strategyValue,
            confidence: confidence,
            evidence: evidence,
            timestamp: Date()
        )
        store.recentVotes.append(vote)
        if store.recentVotes.count > store.maxVotes {
            store.recentVotes.removeFirst(store.recentVotes.count - store.maxVotes)
        }
        save()
    }

    func resolveConsensus(host: String) -> [SwarmConsensus] {
        let hostVotes = store.recentVotes.filter { $0.host == host && Date().timeIntervalSince($0.timestamp) < 600 }

        let grouped = Dictionary(grouping: hostVotes, by: { $0.strategyKey })
        var results: [SwarmConsensus] = []

        for (key, votes) in grouped {
            let valueCounts = Dictionary(grouping: votes, by: { $0.strategyValue })
            guard let (bestValue, bestVotes) = valueCounts.max(by: { $0.value.count < $1.value.count }) else { continue }

            let agreementRate = Double(bestVotes.count) / Double(votes.count)
            let avgConfidence = bestVotes.map(\.confidence).reduce(0, +) / Double(bestVotes.count)

            guard agreementRate >= consensusThreshold && votes.count >= minVotersForConsensus else { continue }

            let consensus = SwarmConsensus(
                host: host,
                strategyKey: key,
                consensusValue: bestValue,
                agreementRate: agreementRate,
                voterCount: votes.count,
                confidence: avgConfidence,
                decidedAt: Date()
            )
            results.append(consensus)
        }

        for consensus in results {
            if !store.consensusHistory.contains(where: { $0.host == consensus.host && $0.strategyKey == consensus.strategyKey && Date().timeIntervalSince($0.decidedAt) < 300 }) {
                store.consensusHistory.append(consensus)
                store.totalConsensusReached += 1
            }
        }

        if store.consensusHistory.count > store.maxConsensusHistory {
            store.consensusHistory.removeFirst(store.consensusHistory.count - store.maxConsensusHistory)
        }

        save()
        return results
    }

    func assignRoles(host: String) {
        let hostProfiles = store.activeProfiles.filter { $0.host == host }
        guard hostProfiles.count >= 2 else { return }

        let sorted = hostProfiles.sorted { $0.effectivenessScore > $1.effectivenessScore }

        for (i, profile) in sorted.enumerated() {
            guard let idx = store.activeProfiles.firstIndex(where: { $0.sessionId == profile.sessionId }) else { continue }

            if i == 0 && profile.totalAttempts < 5 {
                store.activeProfiles[idx].role = .scout
            } else if i == sorted.count - 1 && profile.totalAttempts >= 3 {
                store.activeProfiles[idx].role = .validator
            } else {
                store.activeProfiles[idx].role = .worker
            }
        }

        logger.log("Swarm: reassigned roles for \(host) across \(hostProfiles.count) sessions", category: .automation, level: .info)
        save()
    }

    func getOptimalStrategy(forSession sessionId: String, host: String) -> SessionStrategyProfile? {
        guard var profile = store.activeProfiles.first(where: { $0.sessionId == sessionId }) else { return nil }

        let consensus = resolveConsensus(host: host)
        for c in consensus where c.isStrong {
            switch c.strategyKey {
            case "keystrokeMs":
                if let val = Int(c.consensusValue) { profile.optimalKeystrokeMs = val }
            case "interFieldMs":
                if let val = Int(c.consensusValue) { profile.optimalInterFieldMs = val }
            case "preSubmitMs":
                if let val = Int(c.consensusValue) { profile.optimalPreSubmitMs = val }
            case "fingerprintIndex":
                if let val = Int(c.consensusValue) { profile.preferredFingerprintIndex = val }
            case "proxyId":
                if !profile.preferredProxyIds.contains(c.consensusValue) {
                    profile.preferredProxyIds.insert(c.consensusValue, at: 0)
                    if profile.preferredProxyIds.count > 5 {
                        profile.preferredProxyIds = Array(profile.preferredProxyIds.prefix(5))
                    }
                }
            default:
                break
            }
        }

        let peerSignals = consumeSignals(forSession: sessionId, host: host)
        for signal in peerSignals where signal.confidence >= 0.7 {
            switch signal.signalType {
            case .timingDiscovery:
                if let ks = signal.payload["keystrokeMs"], let val = Int(ks) {
                    profile.optimalKeystrokeMs = val
                }
                if let ifm = signal.payload["interFieldMs"], let val = Int(ifm) {
                    profile.optimalInterFieldMs = val
                }
            case .proxyQuality:
                if let proxyId = signal.payload["proxyId"], let quality = signal.payload["quality"], Double(quality) ?? 0 > 0.7 {
                    if !profile.preferredProxyIds.contains(proxyId) {
                        profile.preferredProxyIds.insert(proxyId, at: 0)
                    }
                }
            case .detectionAlert:
                if let fpIdx = signal.payload["avoidFingerprintIndex"], let val = Int(fpIdx) {
                    if profile.preferredFingerprintIndex == val {
                        profile.preferredFingerprintIndex = (val + 1) % 10
                    }
                }
            default:
                break
            }
        }

        if let idx = store.activeProfiles.firstIndex(where: { $0.sessionId == sessionId }) {
            store.activeProfiles[idx] = profile
        }

        return profile
    }

    func runCoordinationCycle(host: String) {
        guard Date().timeIntervalSince(store.lastCoordinationCycle) >= coordinationIntervalSeconds else { return }
        store.lastCoordinationCycle = Date()

        pruneExpiredSignals()
        assignRoles(host: host)
        let consensus = resolveConsensus(host: host)

        for c in consensus where c.isStrong {
            knowledgeGraph.publishEvent(
                source: "SwarmIntelligence",
                host: host,
                domain: .interaction,
                type: .strategyOutcome,
                severity: .medium,
                confidence: c.confidence,
                payload: [
                    "strategyKey": c.strategyKey,
                    "consensusValue": c.consensusValue,
                    "agreementRate": String(format: "%.2f", c.agreementRate),
                    "voterCount": "\(c.voterCount)"
                ],
                summary: "Swarm consensus: \(c.strategyKey)=\(c.consensusValue) (agreement: \(Int(c.agreementRate * 100))%)"
            )
        }

        logger.log("Swarm: coordination cycle for \(host) — \(consensus.count) consensus decisions", category: .automation, level: .info)
        save()
    }

    func activeSessionCount(for host: String) -> Int {
        store.activeProfiles.filter { $0.host == host }.count
    }

    func swarmSummary(for host: String) -> SwarmHostSummary {
        let profiles = store.activeProfiles.filter { $0.host == host }
        let avgSuccess = profiles.isEmpty ? 0 : profiles.map(\.successRate).reduce(0, +) / Double(profiles.count)
        let avgEffectiveness = profiles.isEmpty ? 0 : profiles.map(\.effectivenessScore).reduce(0, +) / Double(profiles.count)
        let roleBreakdown = Dictionary(grouping: profiles, by: { $0.role }).mapValues(\.count)
        let recentConsensus = store.consensusHistory.filter { $0.host == host }.suffix(5)

        return SwarmHostSummary(
            host: host,
            activeSessions: profiles.count,
            avgSuccessRate: avgSuccess,
            avgEffectiveness: avgEffectiveness,
            roleBreakdown: roleBreakdown,
            recentConsensus: Array(recentConsensus),
            totalSignals: store.totalSignalsBroadcast,
            totalConsensus: store.totalConsensusReached
        )
    }

    private func publishSignalToKnowledgeGraph(_ signal: SwarmSignal) {
        let domain: KnowledgeDomain
        switch signal.signalType {
        case .proxyQuality: domain = .proxy
        case .timingDiscovery: domain = .timing
        case .fingerprintResult: domain = .fingerprint
        case .detectionAlert: domain = .detection
        case .challengeEncountered: domain = .challenge
        case .rateLimitHit: domain = .anomaly
        case .successPattern, .failurePattern: domain = .interaction
        case .hostDifficultyUpdate: domain = .health
        case .strategyRecommendation: domain = .rescue
        }

        let severity: KnowledgeSeverity = signal.priority == .urgent ? .critical : signal.priority == .high ? .high : .medium

        knowledgeGraph.publishEvent(
            source: "SwarmIntelligence",
            host: signal.host,
            domain: domain,
            type: .patternDiscovery,
            severity: severity,
            confidence: signal.confidence,
            payload: signal.payload,
            summary: "Swarm signal: \(signal.signalType.rawValue) from session \(signal.sessionId.prefix(8))",
            ttlSeconds: signal.ttlSeconds
        )
    }

    private func pruneExpiredSignals() {
        store.pendingSignals.removeAll { $0.isExpired }
        store.recentVotes.removeAll { Date().timeIntervalSince($0.timestamp) > 600 }
    }

    func resetAll() {
        store = SwarmCoordinationState()
        save()
        logger.log("Swarm: all data reset", category: .automation, level: .warning)
    }
}

nonisolated struct SwarmHostSummary: Sendable {
    let host: String
    let activeSessions: Int
    let avgSuccessRate: Double
    let avgEffectiveness: Double
    let roleBreakdown: [SessionRole: Int]
    let recentConsensus: [SwarmConsensus]
    let totalSignals: Int
    let totalConsensus: Int
}
