import Foundation

actor AdaptiveRetryService {
    static let shared = AdaptiveRetryService()

    private var siteOutcomeHistory: [String: SiteOutcomeTracker] = [:]
    private let historyWindowSize: Int = 30

    private struct SiteOutcomeTracker {
        var outcomes: [(category: FailureCategory, timestamp: Date)] = []
        var totalAttempts: Int = 0

        func dominantCategory(windowSize: Int) -> FailureCategory? {
            let recent = outcomes.suffix(windowSize)
            guard recent.count >= 5 else { return nil }
            var counts: [FailureCategory: Int] = [:]
            for entry in recent {
                counts[entry.category, default: 0] += 1
            }
            guard let (topCategory, topCount) = counts.max(by: { $0.value < $1.value }) else { return nil }
            let dominanceRatio = Double(topCount) / Double(recent.count)
            return dominanceRatio >= 0.5 ? topCategory : nil
        }

        func recentFailureRate(windowSize: Int) -> Double {
            let recent = outcomes.suffix(windowSize)
            guard !recent.isEmpty else { return 0 }
            let failures = recent.filter { $0.category != .unknown }.count
            return Double(failures) / Double(recent.count)
        }
    }

    nonisolated enum FailureCategory: String, Sendable {
        case timeout
        case idleTimeout
        case connectionFailure
        case fieldDetectionMiss
        case submitNoOp
        case disabledAccount
        case rateLimited
        case blankPage
        case captcha
        case unknown
    }

    nonisolated struct RetryPolicy: Sendable {
        let maxRetries: Int
        let baseDelayMs: Int
        let backoffMultiplier: Double
        let shouldRotateURL: Bool
        let shouldRotateProxy: Bool
        let shouldRecycleWebView: Bool
        let shouldSwitchPattern: Bool
    }

    func recordSiteOutcome(host: String, category: FailureCategory) {
        var tracker = siteOutcomeHistory[host] ?? SiteOutcomeTracker()
        tracker.outcomes.append((category, Date()))
        tracker.totalAttempts += 1
        if tracker.outcomes.count > historyWindowSize * 2 {
            tracker.outcomes = Array(tracker.outcomes.suffix(historyWindowSize))
        }
        siteOutcomeHistory[host] = tracker
    }

    func adaptedPolicyFor(_ category: FailureCategory, host: String? = nil) -> RetryPolicy {
        let basePolicy = policyFor(category)
        guard let host, let tracker = siteOutcomeHistory[host] else { return basePolicy }

        let dominant = tracker.dominantCategory(windowSize: historyWindowSize)
        let failureRate = tracker.recentFailureRate(windowSize: historyWindowSize)

        var adjustedMaxRetries = basePolicy.maxRetries
        var adjustedBaseDelay = basePolicy.baseDelayMs
        var adjustedRotateProxy = basePolicy.shouldRotateProxy
        var adjustedRotateURL = basePolicy.shouldRotateURL

        if dominant == .rateLimited || dominant == .captcha {
            adjustedMaxRetries = max(1, basePolicy.maxRetries - 1)
            adjustedBaseDelay = Int(Double(basePolicy.baseDelayMs) * 2.0)
            adjustedRotateProxy = true
            adjustedRotateURL = true
            DebugLogger.logBackground("AdaptiveRetry: site \(host) has dominant \(dominant?.rawValue ?? "") pattern — increased delay to \(adjustedBaseDelay)ms, forcing rotation", category: .automation, level: .info)
        } else if dominant == .connectionFailure && failureRate > 0.7 {
            adjustedRotateProxy = true
            adjustedBaseDelay = Int(Double(basePolicy.baseDelayMs) * 1.5)
            DebugLogger.logBackground("AdaptiveRetry: site \(host) has high connection failure rate (\(Int(failureRate * 100))%) — forcing proxy rotation", category: .automation, level: .info)
        } else if failureRate < 0.2 && tracker.totalAttempts > 10 {
            adjustedBaseDelay = max(200, basePolicy.baseDelayMs / 2)
        }

        return RetryPolicy(
            maxRetries: adjustedMaxRetries,
            baseDelayMs: adjustedBaseDelay,
            backoffMultiplier: basePolicy.backoffMultiplier,
            shouldRotateURL: adjustedRotateURL,
            shouldRotateProxy: adjustedRotateProxy,
            shouldRecycleWebView: basePolicy.shouldRecycleWebView,
            shouldSwitchPattern: basePolicy.shouldSwitchPattern
        )
    }

    nonisolated func policyFor(_ category: FailureCategory) -> RetryPolicy {
        switch category {
        case .idleTimeout:
            return RetryPolicy(
                maxRetries: 3,
                baseDelayMs: 1000,
                backoffMultiplier: 1.0,
                shouldRotateURL: true,
                shouldRotateProxy: true,
                shouldRecycleWebView: true,
                shouldSwitchPattern: false
            )
        case .timeout:
            return RetryPolicy(
                maxRetries: 2,
                baseDelayMs: 2000,
                backoffMultiplier: 2.0,
                shouldRotateURL: true,
                shouldRotateProxy: false,
                shouldRecycleWebView: true,
                shouldSwitchPattern: false
            )
        case .connectionFailure:
            return RetryPolicy(
                maxRetries: 3,
                baseDelayMs: 1500,
                backoffMultiplier: 1.5,
                shouldRotateURL: true,
                shouldRotateProxy: true,
                shouldRecycleWebView: true,
                shouldSwitchPattern: false
            )
        case .fieldDetectionMiss:
            return RetryPolicy(
                maxRetries: 2,
                baseDelayMs: 1000,
                backoffMultiplier: 1.5,
                shouldRotateURL: false,
                shouldRotateProxy: false,
                shouldRecycleWebView: false,
                shouldSwitchPattern: true
            )
        case .submitNoOp:
            return RetryPolicy(
                maxRetries: 3,
                baseDelayMs: 800,
                backoffMultiplier: 1.5,
                shouldRotateURL: false,
                shouldRotateProxy: false,
                shouldRecycleWebView: false,
                shouldSwitchPattern: true
            )
        case .disabledAccount:
            return RetryPolicy(
                maxRetries: 0,
                baseDelayMs: 0,
                backoffMultiplier: 1.0,
                shouldRotateURL: false,
                shouldRotateProxy: false,
                shouldRecycleWebView: false,
                shouldSwitchPattern: false
            )
        case .rateLimited:
            return RetryPolicy(
                maxRetries: 2,
                baseDelayMs: 15000,
                backoffMultiplier: 2.0,
                shouldRotateURL: true,
                shouldRotateProxy: true,
                shouldRecycleWebView: true,
                shouldSwitchPattern: false
            )
        case .blankPage:
            return RetryPolicy(
                maxRetries: 2,
                baseDelayMs: 3000,
                backoffMultiplier: 2.0,
                shouldRotateURL: true,
                shouldRotateProxy: false,
                shouldRecycleWebView: true,
                shouldSwitchPattern: false
            )
        case .captcha:
            return RetryPolicy(
                maxRetries: 1,
                baseDelayMs: 10000,
                backoffMultiplier: 2.0,
                shouldRotateURL: true,
                shouldRotateProxy: true,
                shouldRecycleWebView: true,
                shouldSwitchPattern: false
            )
        case .unknown:
            return RetryPolicy(
                maxRetries: 1,
                baseDelayMs: 2000,
                backoffMultiplier: 1.5,
                shouldRotateURL: false,
                shouldRotateProxy: false,
                shouldRecycleWebView: false,
                shouldSwitchPattern: true
            )
        }
    }

    nonisolated func delayForRetry(policy: RetryPolicy, attempt: Int) -> Int {
        let delay = Double(policy.baseDelayMs) * pow(policy.backoffMultiplier, Double(attempt))
        let jitter = Double.random(in: 0.0...0.3) * delay
        return Int(delay + jitter)
    }

    nonisolated func categorizeOutcome(_ outcome: LoginOutcome, challengeType: ChallengePageClassifier.ChallengeType? = nil, fieldDetectionFailed: Bool = false, submitFailed: Bool = false, isIdleTimeout: Bool = false) -> FailureCategory {
        if let challenge = challengeType {
            switch challenge {
            case .rateLimit: return .rateLimited
            case .captcha, .cloudflareChallenge: return .captcha
            case .temporaryBlock: return .rateLimited
            case .accountDisabled: return .disabledAccount
            case .maintenance: return .connectionFailure
            case .jsFailed: return .blankPage
            case .none, .unknown: break
            }
        }

        switch outcome {
        case .timeout: return isIdleTimeout ? .idleTimeout : .timeout
        case .connectionFailure: return fieldDetectionFailed ? .fieldDetectionMiss : .connectionFailure
        case .permDisabled, .tempDisabled: return .disabledAccount
        case .redBannerError: return .rateLimited
        case .smsDetected: return .rateLimited
        case .noAcc:
            if submitFailed { return .submitNoOp }
            return .unknown
        case .unsure:
            if submitFailed { return .submitNoOp }
            if fieldDetectionFailed { return .fieldDetectionMiss }
            return .unknown
        case .success: return .unknown
        }
    }

    nonisolated func shouldRetry(category: FailureCategory, currentAttempt: Int) -> Bool {
        let policy = policyFor(category)
        return currentAttempt < policy.maxRetries
    }

    func logRetryDecision(category: FailureCategory, attempt: Int, sessionId: String, host: String? = nil) {
        let policy = host != nil ? adaptedPolicyFor(category, host: host) : policyFor(category)
        let willRetry = attempt < policy.maxRetries
        let delay = willRetry ? delayForRetry(policy: policy, attempt: attempt) : 0
        DebugLogger.logBackground("AdaptiveRetry: \(category.rawValue) attempt \(attempt)/\(policy.maxRetries) — \(willRetry ? "retrying in \(delay)ms" : "NO MORE RETRIES") rotateURL=\(policy.shouldRotateURL) rotateProxy=\(policy.shouldRotateProxy) recycleWV=\(policy.shouldRecycleWebView) switchPattern=\(policy.shouldSwitchPattern)", category: .automation, level: willRetry ? .info : .warning)
    }

    func resetSiteHistory() {
        siteOutcomeHistory.removeAll()
        DebugLogger.logBackground("AdaptiveRetry: site outcome history cleared", category: .automation, level: .info)
    }
}
