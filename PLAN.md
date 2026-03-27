# Comprehensive Stability Overhaul

## Overview

A thorough stability overhaul addressing crash prevention, memory management, Task lifecycle, WebView leak prevention, and redundant system coordination.

---

### 1. Fix WebView Leak Prevention

**Problem:** `WebViewTracker` count can drift if `setUp()` is called without matching `tearDown()`, or if exceptions occur between increment/decrement. The `reset()` method paper-covers this.

- Add a `deinit`-safe guard pattern so `tearDown()` is always called before a new `setUp()` in `LoginSiteWebSession`
- Ensure the existing continuation (`pageLoadContinuation`) is always safely resolved before creating a new one — preventing double-resume crashes
- Add tracking of session IDs in `WebViewTracker` (not just a count) so leaked sessions can be identified by name

### 2. Fix Task Cancellation Swallowing

**Problem:** Many `Task {}` blocks use `try? await Task.sleep()` which silently swallows `CancellationError`, causing zombie tasks that keep running after stop/emergency.

- In `BlankPageRecoveryService.cancellationSafeSleep`: remove the spin-wait loop that actively resists cancellation — this fights structured concurrency and keeps dead sessions alive
- In all batch loops (`LoginViewModel`, `PPSRAutomationViewModel`, `UnifiedSessionViewModel`): add explicit `Task.isCancelled` checks after each `try? await Task.sleep()` call
- In heartbeat monitors, force-stop timers, and pause countdowns: ensure tasks exit cleanly on cancellation

### 3. Eliminate Duplicate Lifecycle Persistence

**Problem:** `SitchomaticApp` handles `willResignActive`, `didEnterBackground`, `willEnterForeground` AND `AppStabilityCoordinator` registers identical observers — causing double persistence calls and wasted I/O.

- Remove the duplicate lifecycle observers from `AppStabilityCoordinator` — let `SitchomaticApp` be the single source of truth for lifecycle events
- Keep `AppStabilityCoordinator` focused on health monitoring and watchdogs only
- Add a `willTerminate` handler in `SitchomaticApp` (currently only in coordinator)

### 4. Consolidate Overlapping Memory Monitors

**Problem:** 5 concurrent polling loops monitor memory: `CrashProtectionService` (adaptive trim + continuous log flush), `MemoryPressureMonitor` (proactive polling), `AppStabilityCoordinator` (health check + periodic save). They overlap significantly and sometimes trigger the same cleanup twice.

- Make `CrashProtectionService` the single memory authority — it already has the most sophisticated escalation tiers
- Have `MemoryPressureMonitor` only listen for the OS `didReceiveMemoryWarning` notification (remove its proactive polling loop)
- Have `AppStabilityCoordinator` only run its health check for WebView leak detection and watchdog cleanup — remove its memory pressure handling
- This reduces 5 polling loops to 2 (CrashProtection adaptive + stability health check)

### 5. Harden Batch Emergency Stop

**Problem:** `emergencyStop()` cancels the batch task and calls `forceFinalizeBatch()`, but the cancelled task's `withTaskGroup` may still have child tasks running that hold WebViews.

- In `emergencyStop()` for all 3 ViewModels: after cancelling the batch task, add a brief delay then force-clean any remaining WebViews via `WebViewTracker`
- Add `DeadSessionDetector.shared.stopAllWatchdogs()` to all emergency stop paths (currently only in `CrashProtectionService`)
- Ensure `SessionActivityMonitor.shared.stopAll()` is called on emergency stop to clear stale session tracking

### 6. Fix Auto-Retry Fire-and-Forget Task

**Problem:** In `LoginViewModel.finalizeBatch()`, auto-retry creates an untracked `Task {}` that sleeps then starts a new batch. This task is never cancelled if the user manually starts a new batch.

- Store the auto-retry task reference so it can be cancelled when a new batch starts or when `stopQueue()` / `emergencyStop()` is called
- Add a guard to prevent auto-retry from starting if a batch is already running

### 7. Improve Log Buffer Management

**Problem:** `globalLogs` arrays in all 3 ViewModels grow to 1500/500 entries. During heavy batches, the array churn (insert at 0, remove from end) causes O(n) copies.

- Reduce `globalLogs` cap to 800 for Login/PPSR and 300 for Unified during active batches (restore on batch end)
- During memory pressure, aggressively trim logs to 200

### 8. Harden Screenshot Cache Memory Safety

**Problem:** `ScreenshotCacheService.store()` compresses images synchronously on main actor, creating memory spikes when screenshots arrive rapidly during batches.

- Add a guard that skips memory cache entirely when `CrashProtectionService.isMemoryCritical` — write directly to disk only
- Add rate limiting: if more than 5 screenshots arrive within 1 second, start dropping to disk-only mode automatically

### 9. Fix `running` Counter Drift in Unified Batch

**Problem:** In `UnifiedSessionViewModel.startBatch()`, the `running` variable is decremented inside the `group.addTask` closure (`running = max(0, running - 1)`) AND by `await group.next()`. This can cause the counter to go negative or miss decrements.

- Remove the `running -= 1` inside the task closure — only use `await group.next()` for tracking, matching the pattern already used correctly in `LoginViewModel`

### 10. Add Graceful Shutdown on Terminate Notification

**Problem:** The `willTerminateNotification` handler in `AppStabilityCoordinator` wraps persistence in `Task { @MainActor in ... }` — but during termination, the app may not survive long enough for the task to execute.

- Move termination handling to `SitchomaticApp` and call persistence methods synchronously (they're already on MainActor)
- Ensure all in-flight batch tasks are cancelled on terminate

---

### Files Modified

- `SitchomaticApp.swift` — add terminate handler, remove duplicate lifecycle overlap
- `AppStabilityCoordinator.swift` — remove duplicate lifecycle observers, simplify to health-check-only
- `MemoryPressureMonitor.swift` — remove proactive polling, keep OS notification only
- `CrashProtectionService.swift` — minor: merge continuous log flush into adaptive memory loop
- `LoginViewModel.swift` — fix auto-retry tracking, add cancellation guards, improve emergency stop
- `PPSRAutomationViewModel.swift` — add cancellation guards, improve emergency stop
- `UnifiedSessionViewModel.swift` — fix running counter drift, add cancellation guards
- `LoginSiteWebSession.swift` — harden setUp/tearDown lifecycle
- `WebViewTracker.swift` — add session ID tracking for leak diagnostics
- `BlankPageRecoveryService.swift` — fix cancellation-resistant sleep
- `ScreenshotCacheService.swift` — add critical memory guard and rate limiting
- `DeadSessionDetector.swift` — no changes, already well-structured
- `SessionActivityMonitor.swift` — no changes needed

