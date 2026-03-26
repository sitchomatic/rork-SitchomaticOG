# Remove Tier 1 — AI Bloat Services (6 systems, 18 files)

## What's being removed

The 6 Tier 1 AI systems that add complexity and memory overhead with near-zero real impact:

1. **AI Swarm Intelligence** — fake multi-session consensus voting (you run on 1 device with 2 URLs)
2. **AI Adversarial Simulation** — fake attack simulations against your own system, plus its dashboard and view model
3. **AI Knowledge Graph** — massive event store feeding all other AI services (2000+ events in UserDefaults)
4. **AI Anomaly Forecasting** — latency/error trend predictions (pointless for 2 fixed URLs)
5. **AI Predictive Route** — proxy protocol/region combo prediction by time-of-day
6. **AI Session Autopilot** — 20+ signal types, decision graph, reflex system, signal processor, action executor, and its dashboard

## Files to delete (18 total)

- **Services:** AISwarmIntelligenceService, AIAdversarialSimulationEngine, AIKnowledgeGraphService, AIAnomalyForecastingService, AIPredictiveRouteService, AISessionAutopilotEngine, AutopilotActionExecutor, AutopilotDecisionGraph, AutopilotReflexSystem, AutopilotSignalProcessor
- **Models:** SwarmIntelligenceModels, AdversarialSimulationModels, KnowledgeGraphModels
- **Views:** AdversarialSimulationView, AutopilotDashboardView, AIIntelligenceDashboardView
- **ViewModels:** AdversarialSimulationViewModel, AIIntelligenceDashboardViewModel

## Files to clean up (10 total)

References to these deleted services will be removed from:

- **ConcurrentAutomationEngine** — remove swarm, adversarial sim, and anomaly forecasting references
- **HybridNetworkingService** — remove predictive route and anomaly forecasting references
- **LoginAutomationEngine** — remove all autopilot session start/end/ingest calls and autopilot executor usage
- **NetworkResilienceService** — remove anomaly forecasting record calls
- **AdvancedSettingsView** — remove the "AI Intelligence Dashboard" and "Adversarial Simulation" navigation links
- **AISessionHealthMonitorService** — remove knowledge graph publish calls
- **AITimingOptimizerService** — remove knowledge graph references
- **AIFingerprintTuningService** — remove knowledge graph references
- **AIOutcomeRescueEngine** — remove knowledge graph references
- **AIProxyStrategyService** — remove knowledge graph references

## What stays the same

- All core automation logic (login testing, credential processing, result detection)
- All other services not in Tier 1
- The page-readiness detection system
- All existing UI screens except the 3 deleted dashboards

