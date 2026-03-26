import Foundation

actor HostCircuitBreakerService {
    static let shared = HostCircuitBreakerService()

    private var hostStates: [String: CircuitState] = [:]

    private let failureThreshold: Int = 3
    private let baseCooldownSeconds: TimeInterval = 30
    private let halfOpenMaxProbes: Int = 2
    private let timeoutWeight: Int = 2
    private let rateLimitWeight: Int = 3

    private let cooldownByFailureType: [FailureType: TimeInterval] = [
        .timeout: 20,
        .connectionError: 25,
        .rateLimited429: 90,
        .serverError5xx: 45,
        .blankPage: 15,
        .generic: 30
    ]

    nonisolated enum BreakerStatus: String, Sendable {
        case closed
        case softBreak
        case open
        case halfOpen
    }

    private let softBreakThreshold: Int = 4

    private struct CircuitState {
        var status: BreakerStatus = .closed
        var failureCount: Int = 0
        var weightedFailureScore: Int = 0
        var openedAt: Date?
        var halfOpenProbes: Int = 0
        var lastFailureType: FailureType?
        var consecutiveTrips: Int = 0
        var effectiveCooldown: TimeInterval = 30
        var softBreakAt: Date?

        var isTripped: Bool {
            switch status {
            case .open:
                return true
            case .halfOpen, .closed, .softBreak:
                return false
            }
        }
    }

    nonisolated enum FailureType: String, Sendable {
        case timeout
        case connectionError
        case rateLimited429
        case serverError5xx
        case blankPage
        case generic
    }

    func isSoftBreak(host: String, path: String? = nil) -> Bool {
        let key = circuitKey(host: host, path: path)
        return hostStates[key]?.status == .softBreak
    }

    func applySoftBreak(host: String, path: String? = nil) {
        let key = circuitKey(host: host, path: path)
        var state = hostStates[key] ?? CircuitState()
        if state.status == .closed {
            state.status = .softBreak
            state.softBreakAt = Date()
            hostStates[key] = state
            DebugLogger.logBackground("CircuitBreaker: \(key) → SOFT BREAK (50% traffic reduction)", category: .network, level: .warning)
        }
    }

    func liftSoftBreak(host: String, path: String? = nil) {
        let key = circuitKey(host: host, path: path)
        guard var state = hostStates[key], state.status == .softBreak else { return }
        state.status = .closed
        state.softBreakAt = nil
        state.weightedFailureScore = max(0, state.weightedFailureScore - 2)
        hostStates[key] = state
        DebugLogger.logBackground("CircuitBreaker: \(key) SOFT BREAK → CLOSED", category: .network, level: .success)
    }

    func shouldAllow(host: String, path: String? = nil) -> Bool {
        let key = circuitKey(host: host, path: path)
        guard var state = hostStates[key] else { return true }

        switch state.status {
        case .closed:
            return true
        case .softBreak:
            return Bool.random()
        case .open:
            if let opened = state.openedAt, Date().timeIntervalSince(opened) >= state.effectiveCooldown {
                state.status = .halfOpen
                state.halfOpenProbes = 0
                hostStates[key] = state
                DebugLogger.logBackground("CircuitBreaker: \(key) → HALF-OPEN (cooldown expired)", category: .network, level: .info)
                return true
            }
            return false
        case .halfOpen:
            if state.halfOpenProbes < halfOpenMaxProbes {
                return true
            }
            return false
        }
    }

    func recordFailure(host: String, path: String? = nil, type: FailureType) {
        let key = circuitKey(host: host, path: path)
        var state = hostStates[key] ?? CircuitState()

        let weight: Int
        switch type {
        case .timeout: weight = timeoutWeight
        case .rateLimited429: weight = rateLimitWeight
        case .serverError5xx: weight = 2
        case .blankPage: weight = 1
        case .connectionError: weight = 2
        case .generic: weight = 1
        }

        state.failureCount += 1
        state.weightedFailureScore += weight
        state.lastFailureType = type

        if state.status == .halfOpen {
            state.consecutiveTrips += 1
            state.status = .open
            state.openedAt = Date()
            state.halfOpenProbes = 0
            state.effectiveCooldown = computeCooldown(for: type, consecutiveTrips: state.consecutiveTrips)
            DebugLogger.logBackground("CircuitBreaker: \(key) HALF-OPEN → OPEN (probe failed: \(type.rawValue)) cooldown=\(Int(state.effectiveCooldown))s (trip #\(state.consecutiveTrips))", category: .network, level: .warning)
        } else if state.weightedFailureScore >= softBreakThreshold && state.status == .closed {
            state.status = .softBreak
            state.softBreakAt = Date()
            hostStates[key] = state
            DebugLogger.logBackground("CircuitBreaker: \(key) → SOFT BREAK — weighted score \(state.weightedFailureScore), reducing traffic 50%", category: .network, level: .warning)
            return
        } else if state.weightedFailureScore >= failureThreshold * 2 {
            state.consecutiveTrips += 1
            state.status = .open
            state.openedAt = Date()
            state.effectiveCooldown = computeCooldown(for: type, consecutiveTrips: state.consecutiveTrips)
            DebugLogger.logBackground("CircuitBreaker: \(key) TRIPPED OPEN — weighted score \(state.weightedFailureScore), \(state.failureCount) failures, last: \(type.rawValue), cooldown=\(Int(state.effectiveCooldown))s", category: .network, level: .critical)
        }

        hostStates[key] = state
    }

    func recordSuccess(host: String, path: String? = nil) {
        let key = circuitKey(host: host, path: path)
        guard var state = hostStates[key] else { return }

        if state.status == .halfOpen {
            state.halfOpenProbes += 1
            if state.halfOpenProbes >= halfOpenMaxProbes {
                state.status = .closed
                state.failureCount = 0
                state.weightedFailureScore = 0
                state.openedAt = nil
                state.halfOpenProbes = 0
                state.consecutiveTrips = 0
                state.effectiveCooldown = baseCooldownSeconds
                DebugLogger.logBackground("CircuitBreaker: \(key) HALF-OPEN → CLOSED (probes succeeded)", category: .network, level: .success)
            }
        } else {
            state.failureCount = max(0, state.failureCount - 1)
            state.weightedFailureScore = max(0, state.weightedFailureScore - 1)
        }

        hostStates[key] = state
    }

    func status(for host: String, path: String? = nil) -> BreakerStatus {
        let key = circuitKey(host: host, path: path)
        return hostStates[key]?.status ?? .closed
    }

    func cooldownRemaining(host: String, path: String? = nil) -> TimeInterval {
        let key = circuitKey(host: host, path: path)
        guard let state = hostStates[key], state.status == .open, let opened = state.openedAt else { return 0 }
        return max(0, state.effectiveCooldown - Date().timeIntervalSince(opened))
    }

    func allOpenCircuits() -> [(key: String, failureCount: Int, remainingSeconds: Int, lastFailure: String)] {
        hostStates.compactMap { key, state in
            guard state.status == .open || state.status == .halfOpen || state.status == .softBreak else { return nil }
            let remaining = state.openedAt.map { Int(max(0, state.effectiveCooldown - Date().timeIntervalSince($0))) } ?? 0
            return (key, state.failureCount, remaining, state.lastFailureType?.rawValue ?? "unknown")
        }.sorted { $0.remainingSeconds > $1.remainingSeconds }
    }

    func resetCircuit(host: String, path: String? = nil) {
        let key = circuitKey(host: host, path: path)
        hostStates.removeValue(forKey: key)
        DebugLogger.logBackground("CircuitBreaker: \(key) manually RESET", category: .network, level: .info)
    }

    func resetAll() {
        hostStates.removeAll()
        DebugLogger.logBackground("CircuitBreaker: all circuits RESET", category: .network, level: .info)
    }

    private func computeCooldown(for failureType: FailureType, consecutiveTrips: Int) -> TimeInterval {
        let typeCooldown = cooldownByFailureType[failureType] ?? baseCooldownSeconds
        let escalationMultiplier = min(4.0, pow(1.5, Double(max(0, consecutiveTrips - 1))))
        let cooldown = typeCooldown * escalationMultiplier
        let maxCooldown: TimeInterval = 300
        return min(maxCooldown, cooldown)
    }

    private func circuitKey(host: String, path: String?) -> String {
        if let path, !path.isEmpty {
            return "\(host)\(path)"
        }
        return host
    }
}
