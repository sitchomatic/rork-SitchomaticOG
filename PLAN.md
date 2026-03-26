# Delete WebViewPool & Add Smart Fingerprint Reuse

## Summary

Delete the WebViewPool entirely. Replace it with a lightweight active-count tracker (diagnostics only) and a smart fingerprint reuse system that remembers which stealth profiles led to successful outcomes and prioritises them.

---

## Part 1: Delete WebViewPool

- **Delete** `WebViewPool.swift` (410 lines — pooling, pre-warming, leak detection, stale reaping all gone)
- **Create** `WebViewTracker.swift` — a tiny service (~40 lines) with:
  - Active WebView count (increment on create, decrement on teardown)
  - Process termination counter
  - Diagnostic summary string
  - `reset()` for emergency cleanup
  - No pooling, no pre-warming, no background tasks, no leak detection loops

---

## Part 2: Update All References (~20 files)

Each file that currently calls `WebViewPool.shared` gets a minimal replacement:

- **AppStabilityCoordinator** — `WebViewPool.shared.activeCount` → `WebViewTracker.shared.activeCount`; remove `forceResetCount()`, `handleMemoryPressure()`, `drainPreWarmed()` calls
- **CrashProtectionService** — same pattern: use tracker for count, remove pool cleanup calls
- **AIPredictiveConcurrencyGovernor** — `.activeCount` → tracker
- **ConcurrentAutomationEngine** — remove `preWarm()` call entirely
- **WebViewCrashRecoveryService** — `reportProcessTermination()` → tracker
- **LoginSiteWebSession** — `reportProcessTermination()` → tracker; add `WebViewTracker.shared.incrementActive()` on setUp, `decrementActive()` on tearDown
- **LoginViewModel** — `forceResetCount()` → `WebViewTracker.shared.reset()`
- **PPSRAutomationViewModel** — same
- **SitchomaticApp** — remove `WebViewPool.shared.handleMemoryPressure()` from memory handler
- **MemoryPressureMonitor** — remove `emergencyPurgeAll()` call
- **NetworkRepairService** — remove `emergencyPurgeAll()` call
- **AutomationActor** — remove stored `webViewPool` reference

---

## Part 3: Smart Fingerprint Reuse

Replace the old pool settings with an intelligent fingerprint reuse system:

- **Rename** `useWebViewPoolFingerprints` → `smartFingerprintReuse` (defaults `true`)
- **Remove** `reuseWebViewPoolSize` (no longer relevant — there's no pool size)
- **Create** `FingerprintSuccessTracker` (~80 lines) — a small service that:
  - Records which `PPSRStealthService` profile index was used for each session outcome
  - Tracks success rate per profile index (success / permBan / tempLock / noAccount / timeout)
  - When `smartFingerprintReuse` is enabled, `PPSRStealthService.nextProfile()` prioritises profiles with higher historical success rates instead of round-robin
  - Persists the success stats to UserDefaults so they survive app restarts
  - Falls back to round-robin when no stats exist yet
- **Update UI** in AutomationSettingsView:
  - Replace "WebView Pool: 24" stepper → removed entirely
  - Replace "WebView Pool Fingerprints" toggle → "Smart Fingerprint Reuse" toggle with subtitle "Prioritise fingerprint profiles with higher success rates"
- **Update UI** in FlowEditingStudioView:
  - Same toggle rename

---

## What Stays Untouched

- **PPSRStealthService** — all 10 trusted fingerprint profiles stay exactly as-is
- **LoginSiteWebSession** — still creates WebViews directly with stealth profiles (the core creation path doesn't change)
- **DualSiteWorkerService** — unchanged
- **UnifiedSessionViewModel** — unchanged
- **AdaptiveConcurrencyEngine** — unchanged
- All PPSR/CarCheck functionality — untouched
- No MainActor changes on other services (conservative scope)

