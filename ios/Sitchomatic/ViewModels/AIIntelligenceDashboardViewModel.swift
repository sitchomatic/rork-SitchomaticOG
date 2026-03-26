import Foundation
import Observation

@Observable
class AIIntelligenceDashboardViewModel {
    var selectedHost: String = ""
    var availableHosts: [String] = []
    var hostIntelligence: UnifiedHostIntelligence?
    var allHostIntelligence: [UnifiedHostIntelligence] = []
    var domainEventCounts: [KnowledgeDomain: Int] = [:]
    var recentHighSeverityEvents: [KnowledgeEvent] = []
    var correlations: [KnowledgeCorrelation] = []
    var totalEvents: Int = 0
    var totalPublished: Int = 0

    var latestSimSuite: SimulationSuite?
    var recentSimSuites: [SimulationSuite] = []
    var pendingHealingActions: [AutoHealingAction] = []

    var swarmSummary: SwarmHostSummary?
    var swarmProfiles: [SessionStrategyProfile] = []
    var swarmConsensus: [SwarmConsensus] = []
    var totalSwarmSignals: Int = 0
    var totalSwarmConsensus: Int = 0

    private let knowledgeGraph = AIKnowledgeGraphService.shared
    private let adversarialEngine = AIAdversarialSimulationEngine.shared
    private let swarmService = AISwarmIntelligenceService.shared

    func load() {
        availableHosts = knowledgeGraph.getAllMonitoredHosts()
        if selectedHost.isEmpty, let first = availableHosts.first {
            selectedHost = first
        }
        allHostIntelligence = knowledgeGraph.getHostIntelligenceForAll()
        domainEventCounts = knowledgeGraph.getDomainEventCounts()
        recentHighSeverityEvents = knowledgeGraph.getRecentHighSeverityEvents(limit: 15)
        totalEvents = knowledgeGraph.totalActiveEvents
        totalPublished = knowledgeGraph.totalEventsPublished
        correlations = knowledgeGraph.getCorrelations()

        recentSimSuites = adversarialEngine.getAllSuites(limit: 10)

        let store = swarmService.store
        totalSwarmSignals = store.totalSignalsBroadcast
        totalSwarmConsensus = store.totalConsensusReached
        swarmProfiles = store.activeProfiles
        swarmConsensus = store.consensusHistory.suffix(10).reversed()

        selectHost(selectedHost)
    }

    func selectHost(_ host: String) {
        selectedHost = host
        guard !host.isEmpty else { return }
        hostIntelligence = knowledgeGraph.getHostIntelligence(host: host)
        correlations = knowledgeGraph.getCorrelations(host: host)
        latestSimSuite = adversarialEngine.getLatestSuite(host: host)
        pendingHealingActions = adversarialEngine.getPendingHealingActions(host: host)
        swarmSummary = swarmService.swarmSummary(for: host)
    }
}
