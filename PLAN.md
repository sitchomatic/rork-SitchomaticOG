# Remove Tier 4 & General UI Cleanup

## What's being removed (Tier 4 — 6 files)

1. **AI Insights Dashboard** — ViewModel + View showing system health, detection patterns, credential insights from deleted services
2. **AI Pattern Discovery Dashboard** — ViewModel + View showing host combos, time heatmaps, proxy trends, convergence data
3. **AI Session Pre-Conditioning Service** — Generates "recipes" (best proxy, stealth seed, timing profile) per host before each session
4. **AI Outcome Rescue Engine** — Re-analyzes unsure outcomes using OCR, page signals, and AI to reclassify results

## Files to delete (6)

- **Services:** AISessionPreConditioningService, AIOutcomeRescueEngine
- **Views:** AIInsightsDashboardView, AIPatternDiscoveryDashboardView
- **ViewModels:** AIInsightsViewModel, AIPatternDiscoveryViewModel

## Files to clean up (3)

- **LoginMoreMenuView** — Remove the "AI Insights" and "Pattern Discovery" navigation links from the Intelligence section. Keep the "Custom AI Tools" link if it still has a valid service behind it.
- **LoginAutomationEngine** — Remove `aiPreConditioning` and `aiOutcomeRescue` properties. Remove all pre-conditioning recipe usage (lines ~106-112) and outcome rescue logic (lines ~388-430). The outcome just flows through directly without rescue attempts.
- **PPSRAutomationEngine** — Remove `aiOutcomeRescue` and `aiPreConditioning` properties. Remove rescue attempt logic (lines ~480-503). The evaluation result is used directly.

## General UI cleanup

- Check the Intelligence section in LoginMoreMenuView — if only "Custom AI Tools" remains, keep the section; if empty, remove the entire section
- Verify no orphaned references remain from all previous tier removals
- Ensure the app builds cleanly