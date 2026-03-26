import Foundation
import Observation
import UIKit

nonisolated enum TestDebugSite: String, CaseIterable, Sendable {
    case joe = "Joe Fortune"
    case ignition = "Ignition Casino"

    var targetSite: LoginTargetSite {
        switch self {
        case .joe: .joefortune
        case .ignition: .ignition
        }
    }

    var icon: String {
        switch self {
        case .joe: "suit.spade.fill"
        case .ignition: "flame.fill"
        }
    }

    var accentColor: String {
        switch self {
        case .joe: "green"
        case .ignition: "orange"
        }
    }
}

nonisolated enum TestDebugSessionCount: Int, CaseIterable, Sendable {
    case twentyFour = 24
    case fortyEight = 48
    case ninetySix = 96

    var label: String { "\(rawValue)" }
}

nonisolated enum TestDebugVariationMode: String, CaseIterable, Sendable {
    case all = "All"
    case network = "Network Focus"
    case automation = "Automation Focus"
    case smartMatrix = "Smart Matrix"

    var icon: String {
        switch self {
        case .all: "square.grid.3x3.fill"
        case .network: "network"
        case .automation: "gearshape.2.fill"
        case .smartMatrix: "chart.bar.xaxis"
        }
    }

    var subtitle: String {
        switch self {
        case .all: "Vary everything"
        case .network: "WireGuard, proxies, DNS, NodeMaven"
        case .automation: "Patterns, typing, delays, stealth"
        case .smartMatrix: "One variable at a time"
        }
    }
}

nonisolated enum TestDebugSessionStatus: String, Sendable {
    case queued = "Queued"
    case running = "Running"
    case success = "Success"
    case failed = "Failed"
    case unsure = "Unsure"
    case timeout = "Timeout"
    case connectionFailure = "Connection Failure"

    var isTerminal: Bool {
        switch self {
        case .queued, .running: false
        default: true
        }
    }

    var isSuccess: Bool { self == .success }

    var icon: String {
        switch self {
        case .queued: "circle.dashed"
        case .running: "circle.dotted"
        case .success: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .unsure: "questionmark.circle.fill"
        case .timeout: "clock.badge.exclamationmark"
        case .connectionFailure: "wifi.slash"
        }
    }

    var color: String {
        switch self {
        case .queued: "secondary"
        case .running: "blue"
        case .success: "green"
        case .failed: "red"
        case .unsure: "yellow"
        case .timeout: "orange"
        case .connectionFailure: "red"
        }
    }
}

@Observable
class TestDebugSession: Identifiable {
    let id: String
    let index: Int
    let differentiator: String
    let settingsSnapshot: TestDebugSettingsSnapshot
    var status: TestDebugSessionStatus = .queued
    var startedAt: Date?
    var completedAt: Date?
    var finalScreenshot: UIImage?
    var errorMessage: String?
    var logs: [PPSRLogEntry] = []
    var webViewIndex: Int = 0

    var duration: TimeInterval? {
        guard let start = startedAt else { return nil }
        let end = completedAt ?? Date()
        return end.timeIntervalSince(start)
    }

    var formattedDuration: String {
        guard let d = duration else { return "—" }
        return String(format: "%.1fs", d)
    }

    init(index: Int, differentiator: String, settingsSnapshot: TestDebugSettingsSnapshot) {
        self.id = UUID().uuidString
        self.index = index
        self.differentiator = differentiator
        self.settingsSnapshot = settingsSnapshot
    }
}

nonisolated struct TestDebugSettingsSnapshot: Sendable {
    let connectionMode: ConnectionMode
    let wireGuardConfigIndex: Int?
    let pattern: String
    let typingSpeedMinMs: Int
    let typingSpeedMaxMs: Int
    let stealthJSInjection: Bool
    let humanMouseMovement: Bool
    let humanScrollJitter: Bool
    let viewportRandomization: Bool
    let fingerprintSpoofing: Bool
    let trueDetectionEnabled: Bool
    let tabBetweenFields: Bool
    let pageLoadExtraDelayMs: Int
    let preSubmitDelayMs: Int
    let postSubmitDelayMs: Int
    let clearCookiesBetweenAttempts: Bool
    let sessionIsolation: AutomationSettings.SessionIsolationMode
    let webViewPoolIndex: Int

    func toAutomationSettings(base: AutomationSettings) -> AutomationSettings {
        var s = base
        s.typingSpeedMinMs = typingSpeedMinMs
        s.typingSpeedMaxMs = typingSpeedMaxMs
        s.stealthJSInjection = stealthJSInjection
        s.humanMouseMovement = humanMouseMovement
        s.humanScrollJitter = humanScrollJitter
        s.viewportRandomization = viewportRandomization
        s.fingerprintSpoofing = fingerprintSpoofing
        s.trueDetectionEnabled = trueDetectionEnabled
        s.tabBetweenFields = tabBetweenFields
        s.pageLoadExtraDelayMs = pageLoadExtraDelayMs
        s.preSubmitDelayMs = preSubmitDelayMs
        s.postSubmitDelayMs = postSubmitDelayMs
        s.clearCookiesBetweenAttempts = clearCookiesBetweenAttempts
        s.sessionIsolation = sessionIsolation
        if trueDetectionEnabled {
            s.patternPriorityOrder = ["TRUE DETECTION"] + s.patternPriorityOrder.filter { $0 != "TRUE DETECTION" }
        } else {
            s.patternPriorityOrder = [pattern] + s.patternPriorityOrder.filter { $0 != pattern }
        }
        return s
    }

    @MainActor
    func buildNetworkConfig(proxyTarget: ProxyRotationService.ProxyTarget) -> ActiveNetworkConfig {
        let proxyService = ProxyRotationService.shared
        let nodeMaven = NodeMavenService.shared

        switch connectionMode {
        case .wireguard:
            let configs = proxyTarget == .ignition ? proxyService.ignitionWGConfigs : proxyService.joeWGConfigs
            if let idx = wireGuardConfigIndex, idx < configs.count {
                return .wireGuardDNS(configs[idx])
            }
            if let first = configs.first {
                return .wireGuardDNS(first)
            }
            return .direct

        case .nodeMaven:
            if let proxy = nodeMaven.generateProxyConfigForSession(webViewPoolIndex) {
                return .socks5(proxy)
            }
            return .direct

        case .proxy:
            if let proxy = proxyService.nextWorkingProxy(for: proxyTarget) {
                return .socks5(proxy)
            }
            return .direct

        case .direct:
            return .direct

        case .dns:
            return .direct

        case .openvpn:
            return .direct

        case .hybrid:
            return HybridNetworkingService.shared.nextHybridConfig(for: proxyTarget)
        }
    }
}

nonisolated struct TestDebugVariationOverrides: Sendable {
    var pinConnectionMode: ConnectionMode?
    var pinPattern: String?
    var pinStealth: Bool?
    var pinHumanSim: Bool?
    var pinFingerprint: Bool?
    var pinTypingSpeed: (min: Int, max: Int)?
    var pinSessionIsolation: AutomationSettings.SessionIsolationMode?
    var pinTrueDetection: Bool?

    var hasPins: Bool {
        pinConnectionMode != nil || pinPattern != nil || pinStealth != nil ||
        pinHumanSim != nil || pinFingerprint != nil || pinTypingSpeed != nil ||
        pinSessionIsolation != nil || pinTrueDetection != nil
    }

    var summary: String {
        var parts: [String] = []
        if let mode = pinConnectionMode { parts.append("Net: \(mode.rawValue)") }
        if let pat = pinPattern { parts.append("Pat: \(pat)") }
        if let s = pinStealth { parts.append("Stealth: \(s ? "ON" : "OFF")") }
        if let h = pinHumanSim { parts.append("Human: \(h ? "ON" : "OFF")") }
        if let t = pinTrueDetection { parts.append("TrueDet: \(t ? "ON" : "OFF")") }
        if let iso = pinSessionIsolation { parts.append("Iso: \(iso.rawValue)") }
        return parts.isEmpty ? "None" : parts.joined(separator: ", ")
    }
}

nonisolated struct TestDebugCredentialEntry: Sendable {
    let email: String
    let password: String

    var isValid: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

nonisolated struct TestDebugRunSummary: Sendable, Identifiable {
    let id: String
    let date: Date
    let site: String
    let sessionCount: Int
    let variationMode: String
    let successCount: Int
    let failedCount: Int
    let unsureCount: Int
    let timeoutCount: Int
    let totalDuration: TimeInterval
    let sessionSummaries: [TestDebugSessionSummary]
}

nonisolated struct TestDebugSessionSummary: Sendable, Identifiable {
    let id: String
    let index: Int
    let differentiator: String
    let status: String
    let duration: TimeInterval?
    let errorMessage: String?
}
