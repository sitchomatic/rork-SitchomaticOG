import Foundation
import Observation

@Observable
class AdversarialSimulationViewModel {
    var isRunning: Bool = false
    var selectedDifficulty: AdversarialDifficulty = .intermediate
    var selectedHost: String = ""
    var latestSuite: SimulationSuite?
    var allSuites: [SimulationSuite] = []
    var autoHealingActions: [AutoHealingAction] = []
    var availableHosts: [String] = []
    var scenarioLibrary: [AdversarialScenario] = []

    private let engine = AIAdversarialSimulationEngine.shared
    private let knowledgeGraph = AIKnowledgeGraphService.shared

    func load() {
        scenarioLibrary = engine.getScenarioLibrary()
        allSuites = engine.getAllSuites(limit: 20)
        availableHosts = knowledgeGraph.getAllMonitoredHosts()
        if selectedHost.isEmpty, let first = availableHosts.first {
            selectedHost = first
        }
        if !selectedHost.isEmpty {
            latestSuite = engine.getLatestSuite(host: selectedHost)
            autoHealingActions = engine.getPendingHealingActions(host: selectedHost)
        }
    }

    func runSimulation() async {
        guard !selectedHost.isEmpty, !isRunning else { return }
        isRunning = true
        let suite = await engine.runSimulation(
            host: selectedHost,
            difficulty: selectedDifficulty
        )
        latestSuite = suite
        allSuites = engine.getAllSuites(limit: 20)
        autoHealingActions = engine.getPendingHealingActions(host: selectedHost)
        isRunning = false
    }

    func revertHealingAction(_ action: AutoHealingAction) {
        engine.markHealingActionReverted(id: action.id)
        autoHealingActions = engine.getPendingHealingActions(host: selectedHost)
    }

    func resetAll() {
        engine.resetAll()
        latestSuite = nil
        allSuites = []
        autoHealingActions = []
    }

    func selectHost(_ host: String) {
        selectedHost = host
        latestSuite = engine.getLatestSuite(host: host)
        autoHealingActions = engine.getPendingHealingActions(host: host)
    }

    var scenariosForDifficulty: [AdversarialScenario] {
        engine.getScenariosForDifficulty(selectedDifficulty)
    }

    var totalSimulations: Int {
        engine.store.totalSimulationsRun
    }
}
