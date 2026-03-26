import Foundation

nonisolated enum RequeuePriority: Int, Comparable, Sendable {
    case high = 0
    case medium = 1
    case low = 2

    nonisolated static func < (lhs: RequeuePriority, rhs: RequeuePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

nonisolated struct RequeueEntry: Sendable {
    let credentialId: String
    let username: String
    let priority: RequeuePriority
    let reason: String
    let suggestDifferentProxy: Bool
    let requeueCount: Int
}

actor RequeuePriorityService {
    static let shared = RequeuePriorityService()

    private var requeueCounts: [String: Int] = [:]
    private var detectionCounts: [String: Int] = [:]
    private let maxRequeueCount: Int = 3
    private let maxDetectionBeforeDeprioritize: Int = 2

    func prioritize(credentialId: String, username: String, outcome: LoginOutcome) -> RequeueEntry? {
        let count = (requeueCounts[credentialId] ?? 0) + 1
        requeueCounts[credentialId] = count

        if count > maxRequeueCount {
            DebugLogger.logBackground("RequeuePriority: \(username) exceeded max requeue count (\(maxRequeueCount)) — dropping", category: .automation, level: .warning)
            return nil
        }

        var priority: RequeuePriority
        let reason: String
        let suggestProxy: Bool

        switch outcome {
        case .timeout:
            priority = .high
            reason = "timeout (likely transient)"
            suggestProxy = false
        case .connectionFailure:
            priority = .medium
            reason = "connection failure"
            suggestProxy = true
        case .redBannerError:
            let detCount = (detectionCounts[credentialId] ?? 0) + 1
            detectionCounts[credentialId] = detCount
            if detCount >= maxDetectionBeforeDeprioritize {
                priority = .low
                reason = "red banner error (\(detCount)x detected — deprioritized, site actively detecting)"
            } else {
                priority = .medium
                reason = "red banner error — proxy+URL rotation+30s cooldown needed"
            }
            suggestProxy = true
        case .smsDetected:
            let detCount = (detectionCounts[credentialId] ?? 0) + 1
            detectionCounts[credentialId] = detCount
            if detCount >= maxDetectionBeforeDeprioritize {
                priority = .low
                reason = "SMS notification (\(detCount)x detected — deprioritized, Ignition 2FA triggered)"
            } else {
                priority = .high
                reason = "SMS notification (Ignition) — burn session+proxy+URL+60s cooldown needed"
            }
            suggestProxy = true
        case .unsure:
            priority = .low
            reason = "unsure result"
            suggestProxy = false
        default:
            return nil
        }

        DebugLogger.logBackground("RequeuePriority: \(username) → \(priority) (\(reason)) requeue #\(count)", category: .automation, level: .info)
        return RequeueEntry(
            credentialId: credentialId,
            username: username,
            priority: priority,
            reason: reason,
            suggestDifferentProxy: suggestProxy,
            requeueCount: count
        )
    }

    var cooldownSeconds: TimeInterval {
        0
    }

    nonisolated func cooldownForOutcome(_ outcome: LoginOutcome) -> TimeInterval {
        switch outcome {
        case .redBannerError: return 30
        case .smsDetected: return 60
        default: return 0
        }
    }

    func detectionCount(for credentialId: String) -> Int {
        detectionCounts[credentialId] ?? 0
    }

    nonisolated func sortByPriority(_ entries: [RequeueEntry]) -> [RequeueEntry] {
        entries.sorted { a, b in
            if a.priority != b.priority {
                return a.priority < b.priority
            }
            return a.requeueCount < b.requeueCount
        }
    }

    func resetCounts() {
        requeueCounts.removeAll()
        detectionCounts.removeAll()
    }

    func requeueCount(for credentialId: String) -> Int {
        requeueCounts[credentialId] ?? 0
    }
}
