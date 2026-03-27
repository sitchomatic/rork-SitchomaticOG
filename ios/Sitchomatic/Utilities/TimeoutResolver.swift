import Foundation

@MainActor
enum TimeoutResolver {
    private static var cachedSettings: AutomationSettings?
    private static var cachedSettingsTimestamp: Date = .distantPast

    static var shared: AutomationSettings {
        let now = Date()
        if let cached = cachedSettings, now.timeIntervalSince(cachedSettingsTimestamp) < 5.0 {
            return cached
        }
        let settings: AutomationSettings
        if let data = UserDefaults.standard.data(forKey: "automation_settings_v1"),
           let loaded = try? JSONDecoder().decode(AutomationSettings.self, from: data) {
            settings = loaded.normalizedTimeouts()
        } else {
            settings = AutomationSettings().normalizedTimeouts()
        }
        cachedSettings = settings
        cachedSettingsTimestamp = now
        return settings
    }

    /// Clears the cached automation settings. Call this when automation settings are
    /// updated (e.g., saved to UserDefaults) to ensure the next access retrieves fresh data.
    static func invalidateCache() {
        cachedSettings = nil
        cachedSettingsTimestamp = .distantPast
    }

    static var userTestTimeout: TimeInterval {
        if let data = UserDefaults.standard.data(forKey: "login_settings_v2"),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let t = dict["testTimeout"] as? TimeInterval {
            return max(t, AutomationSettings.minimumTimeoutSeconds)
        }
        return AutomationSettings.minimumTimeoutSeconds
    }

    static func resolveRequestTimeout(_ hardcoded: TimeInterval) -> TimeInterval {
        let pageLoad = shared.pageLoadTimeout
        if pageLoad > 0 {
            return max(pageLoad, AutomationSettings.minimumTimeoutSeconds)
        }
        return max(hardcoded, AutomationSettings.minimumTimeoutSeconds)
    }

    static func resolveResourceTimeout(_ hardcoded: TimeInterval) -> TimeInterval {
        let pageLoad = shared.pageLoadTimeout
        if pageLoad > 0 {
            return max(pageLoad, AutomationSettings.minimumTimeoutSeconds) + 30
        }
        return max(hardcoded, AutomationSettings.minimumTimeoutSeconds) + 30
    }

    static func resolvePageLoadTimeout(_ hardcoded: TimeInterval) -> TimeInterval {
        let pageLoad = shared.pageLoadTimeout
        if pageLoad > 0 {
            return max(pageLoad, AutomationSettings.minimumTimeoutSeconds)
        }
        return max(hardcoded, AutomationSettings.minimumTimeoutSeconds)
    }

    static func resolveHeartbeatTimeout(_ hardcoded: TimeInterval) -> TimeInterval {
        let pageLoad = shared.pageLoadTimeout
        let effective = pageLoad > 0 ? pageLoad : hardcoded
        return max(effective, AutomationSettings.minimumTimeoutSeconds) + 30
    }

    static func resolveTestTimeout(_ hardcoded: TimeInterval, userSetting: TimeInterval) -> TimeInterval {
        let pageLoad = shared.pageLoadTimeout
        if userSetting > 0 {
            return max(userSetting, AutomationSettings.minimumTimeoutSeconds)
        }
        if pageLoad > 0 {
            return max(max(hardcoded, pageLoad), AutomationSettings.minimumTimeoutSeconds)
        }
        return max(hardcoded, AutomationSettings.minimumTimeoutSeconds)
    }

    static func resolveAutoHealCap(_ currentTimeout: TimeInterval) -> TimeInterval {
        let pageLoad = shared.pageLoadTimeout
        if pageLoad > 0 {
            return max(max(currentTimeout, pageLoad), AutomationSettings.minimumTimeoutSeconds)
        }
        return max(currentTimeout, AutomationSettings.minimumTimeoutSeconds)
    }

    static func resolveAutomationTimeout(_ hardcoded: TimeInterval) -> TimeInterval {
        max(hardcoded, AutomationSettings.minimumTimeoutSeconds)
    }

    static func resolveAutomationMilliseconds(_ hardcoded: Int) -> Int {
        max(hardcoded, AutomationSettings.minimumTimeoutMilliseconds)
    }

    static func resolveAdaptiveTimeout(sessionId: String, hardcoded: TimeInterval) -> TimeInterval {
        let activityMonitor = SessionActivityMonitor.shared
        let hasActivity = activityMonitor.hasActivity(sessionId: sessionId)
        if hasActivity {
            return max(SessionActivityMonitor.activeTimeoutSeconds, AutomationSettings.minimumTimeoutSeconds)
        }
        return max(hardcoded, AutomationSettings.minimumTimeoutSeconds)
    }

    nonisolated enum TimeoutReason: Sendable {
        case activeTimeout
        case idleTimeout(secondsIdle: TimeInterval)
        case hardTimeout
    }

    static func evaluateTimeoutReason(sessionId: String, elapsed: TimeInterval) -> TimeoutReason? {
        let activityMonitor = SessionActivityMonitor.shared
        let idleStatus = activityMonitor.checkIdleStatus(sessionId: sessionId)

        switch idleStatus {
        case .idle(let secondsIdle):
            if secondsIdle >= SessionActivityMonitor.idleThresholdSeconds {
                return .idleTimeout(secondsIdle: secondsIdle)
            }
        case .active:
            if elapsed >= SessionActivityMonitor.activeTimeoutSeconds {
                return .activeTimeout
            }
        case .noSession:
            if elapsed >= AutomationSettings.minimumTimeoutSeconds {
                return .hardTimeout
            }
        }
        return nil
    }
}
