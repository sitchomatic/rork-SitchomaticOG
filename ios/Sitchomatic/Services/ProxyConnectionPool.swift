import Foundation
import Network
import Observation

nonisolated struct PooledConnectionInfo: Sendable {
    let id: UUID
    let targetHost: String
    let targetPort: UInt16
    let routeKey: String
    let createdAt: Date
    var lastUsedAt: Date
    var bytesTransferred: UInt64
    var isIdle: Bool
    var lastKeepaliveAt: Date?
    var keepaliveFailures: Int = 0
}

@Observable
@MainActor
class ProxyConnectionPool {
    static let shared = ProxyConnectionPool()

    private(set) var pooledConnections: [UUID: PooledConnectionInfo] = [:]
    private(set) var totalPoolHits: Int = 0
    private(set) var totalPoolMisses: Int = 0
    private(set) var totalEvictions: Int = 0

    var maxPoolSize: Int = 20
    var idleTimeoutSeconds: TimeInterval = 60
    var connectionTTLSeconds: TimeInterval = 300
    var keepaliveIntervalSeconds: TimeInterval = 15
    var maxKeepaliveFailures: Int = 2

    private var upstreamConnections: [UUID: NWConnection] = [:]
    private var cleanupTimer: Timer?
    private var keepaliveTimer: Timer?
    private let logger = DebugLogger.shared
    private let queue = DispatchQueue(label: "proxy-connection-pool", qos: .userInitiated)

    private var cleanupTimerStarted = false
    private var prewarmTasks: [UUID: Task<Void, Never>] = [:]

    init() {}

    private func makePoolKey(targetHost: String, targetPort: UInt16, upstream: ProxyConfig?) -> String {
        if let upstream {
            return "upstream:\(upstream.id.uuidString)->\(targetHost):\(targetPort)"
        }
        return "direct:\(targetHost):\(targetPort)"
    }

    func prewarmConnections(count: Int, upstream: ProxyConfig?, targetHost: String = "warmup", targetPort: UInt16 = 443) {
        guard count > 0 else { return }

        if let upstream {
            let qualityScore = ProxyQualityDecayService.shared.scoreFor(proxyId: upstream.id.uuidString)
            if qualityScore < 0.2 {
                logger.log("ConnectionPool: prewarm SKIPPED — proxy \(upstream.displayString) is demoted (score: \(String(format: "%.2f", qualityScore)))", category: .proxy, level: .warning)
                return
            }
        }

        let toWarm = min(count, maxPoolSize - pooledConnections.count)
        guard toWarm > 0 else {
            logger.log("ConnectionPool: prewarm skipped — pool at capacity", category: .proxy, level: .debug)
            return
        }

        logger.log("ConnectionPool: pre-warming \(toWarm) connections via \(upstream?.displayString ?? "direct")", category: .proxy, level: .info)

        for i in 0..<toWarm {
            let taskId = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(50 * i))
                self.acquireUpstream(targetHost: targetHost, targetPort: targetPort, upstream: upstream) { [weak self] conn, poolId in
                    guard let self else { return }
                    if let poolId {
                        self.releaseConnection(id: poolId, hadError: false)
                        self.logger.log("ConnectionPool: pre-warmed connection \(poolId.uuidString.prefix(8))", category: .proxy, level: .trace)
                    }
                }
                self.prewarmTasks.removeValue(forKey: taskId)
            }
            prewarmTasks[taskId] = task
        }
    }

    func acquireUpstream(targetHost: String, targetPort: UInt16, upstream: ProxyConfig?, completion: @escaping (NWConnection?, UUID?) -> Void) {
        if !cleanupTimerStarted {
            cleanupTimerStarted = true
            startCleanupTimer()
            startKeepaliveTimer()
        }
        let poolKey = makePoolKey(targetHost: targetHost, targetPort: targetPort, upstream: upstream)

        for (id, info) in pooledConnections where info.isIdle && info.routeKey == poolKey {
            if let conn = upstreamConnections[id], conn.state == .ready {
                var updated = info
                updated.lastUsedAt = Date()
                updated.isIdle = false
                pooledConnections[id] = updated
                totalPoolHits += 1
                logger.log("ConnectionPool: HIT for \(poolKey) (id: \(id.uuidString.prefix(8)))", category: .proxy, level: .trace)
                completion(conn, id)
                return
            } else {
                evictConnection(id: id, reason: "stale")
            }
        }

        totalPoolMisses += 1
        if upstream != nil {
            totalUpstreamConnections += 1
        }

        if pooledConnections.count >= maxPoolSize {
            evictOldest()
        }

        let id = UUID()
        let info = PooledConnectionInfo(
            id: id,
            targetHost: targetHost,
            targetPort: targetPort,
            routeKey: poolKey,
            createdAt: Date(),
            lastUsedAt: Date(),
            bytesTransferred: 0,
            isIdle: false
        )
        pooledConnections[id] = info

        if let upstream {
            let proxyEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(upstream.host),
                port: NWEndpoint.Port(integerLiteral: UInt16(upstream.port))
            )
            let conn = NWConnection(to: proxyEndpoint, using: .tcp)
            upstreamConnections[id] = conn

            conn.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .ready:
                        completion(conn, id)
                    case .failed:
                        self?.evictConnection(id: id, reason: "connect failed")
                        completion(nil, nil)
                    default:
                        break
                    }
                }
            }
            conn.start(queue: queue)
        } else {
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(targetHost),
                port: NWEndpoint.Port(integerLiteral: targetPort)
            )
            let conn = NWConnection(to: endpoint, using: .tcp)
            upstreamConnections[id] = conn

            conn.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .ready:
                        completion(conn, id)
                    case .failed:
                        self?.evictConnection(id: id, reason: "direct connect failed")
                        completion(nil, nil)
                    default:
                        break
                    }
                }
            }
            conn.start(queue: queue)
        }
    }

    func releaseConnection(id: UUID, hadError: Bool) {
        if hadError {
            evictConnection(id: id, reason: "error")
            return
        }

        guard var info = pooledConnections[id] else { return }

        if let conn = upstreamConnections[id], conn.state == .ready {
            info.isIdle = true
            info.lastUsedAt = Date()
            pooledConnections[id] = info
            logger.log("ConnectionPool: released \(id.uuidString.prefix(8)) back to pool (idle)", category: .proxy, level: .trace)
        } else {
            evictConnection(id: id, reason: "not ready on release")
        }
    }

    func recordBytesTransferred(id: UUID, bytes: UInt64) {
        guard var info = pooledConnections[id] else { return }
        info.bytesTransferred += bytes
        pooledConnections[id] = info
    }

    func drainPool() {
        for task in prewarmTasks.values { task.cancel() }
        prewarmTasks.removeAll()
        for (id, _) in upstreamConnections {
            upstreamConnections[id]?.cancel()
        }
        upstreamConnections.removeAll()
        pooledConnections.removeAll()
        totalPoolHits = 0
        totalPoolMisses = 0
        totalEvictions = 0
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        cleanupTimerStarted = false
        logger.log("ConnectionPool: drained all connections", category: .proxy, level: .info)
    }

    var poolUtilization: Double {
        guard maxPoolSize > 0 else { return 0 }
        return Double(pooledConnections.count) / Double(maxPoolSize) * 100
    }

    var hitRate: Double {
        let total = totalPoolHits + totalPoolMisses
        guard total > 0 else { return 0 }
        return Double(totalPoolHits) / Double(total) * 100
    }

    private(set) var totalUpstreamConnections: Int = 0

    func recordUpstreamConnectionCreated() {
        totalUpstreamConnections += 1
        totalPoolMisses += 1
    }

    func recordUpstreamConnectionFinished(hadError: Bool) {
        if hadError { totalEvictions += 1 }
    }

    var activeCount: Int {
        pooledConnections.values.filter { !$0.isIdle }.count
    }

    var idleCount: Int {
        pooledConnections.values.filter { $0.isIdle }.count
    }

    private func evictConnection(id: UUID, reason: String) {
        upstreamConnections[id]?.cancel()
        upstreamConnections.removeValue(forKey: id)
        pooledConnections.removeValue(forKey: id)
        totalEvictions += 1
        logger.log("ConnectionPool: evicted \(id.uuidString.prefix(8)) (\(reason))", category: .proxy, level: .trace)
    }

    private func evictOldest() {
        let qualityDecay = ProxyQualityDecayService.shared
        let idleConnections = pooledConnections.filter { $0.value.isIdle }

        if !idleConnections.isEmpty {
            let scored = idleConnections.map { (id, info) -> (UUID, Double, Date) in
                let proxyId = "\(info.targetHost):\(info.targetPort)"
                let score = qualityDecay.scoreFor(proxyId: proxyId)
                return (id, score, info.lastUsedAt)
            }.sorted { a, b in
                if abs(a.1 - b.1) > 0.1 { return a.1 < b.1 }
                return a.2 < b.2
            }

            if let worst = scored.first {
                evictConnection(id: worst.0, reason: "pool full — evicting lowest-quality idle (score: \(String(format: "%.2f", worst.1)))")
                return
            }
        }

        let allSorted = pooledConnections.sorted { $0.value.lastUsedAt < $1.value.lastUsedAt }
        if let oldest = allSorted.first {
            evictConnection(id: oldest.key, reason: "pool full — evicting oldest active")
        }
    }

    func evictDemotedConnections(qualityThreshold: Double = 0.2) {
        let qualityDecay = ProxyQualityDecayService.shared
        var evicted = 0
        for (id, info) in pooledConnections where info.isIdle {
            let proxyId = "\(info.targetHost):\(info.targetPort)"
            let score = qualityDecay.scoreFor(proxyId: proxyId)
            if score < qualityThreshold {
                evictConnection(id: id, reason: "demoted proxy (score: \(String(format: "%.2f", score)))")
                evicted += 1
            }
        }
        if evicted > 0 {
            logger.log("ConnectionPool: evicted \(evicted) demoted proxy connections", category: .proxy, level: .info)
        }
    }

    private func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cleanupExpiredConnections()
            }
        }
    }

    private func startKeepaliveTimer() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: keepaliveIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.probeIdleConnections()
            }
        }
    }

    private func probeIdleConnections() {
        let idleIds = pooledConnections.filter { $0.value.isIdle }.map { $0.key }
        guard !idleIds.isEmpty else { return }

        for id in idleIds {
            guard let conn = upstreamConnections[id] else {
                evictConnection(id: id, reason: "keepalive: connection missing")
                continue
            }

            switch conn.state {
            case .ready:
                var info = pooledConnections[id]
                info?.lastKeepaliveAt = Date()
                info?.keepaliveFailures = 0
                if let info { pooledConnections[id] = info }
            case .failed, .cancelled:
                evictConnection(id: id, reason: "keepalive: connection \(conn.state)")
            case .waiting, .preparing:
                guard var existingInfo = pooledConnections[id] else { continue }
                existingInfo.keepaliveFailures += 1
                if existingInfo.keepaliveFailures >= maxKeepaliveFailures {
                    evictConnection(id: id, reason: "keepalive: stuck in \(conn.state) for \(existingInfo.keepaliveFailures) checks")
                } else {
                    pooledConnections[id] = existingInfo
                }
            default:
                break
            }
        }
    }

    private func cleanupExpiredConnections() {
        let now = Date()
        var toEvict: [UUID] = []

        for (id, info) in pooledConnections {
            if info.isIdle && now.timeIntervalSince(info.lastUsedAt) > idleTimeoutSeconds {
                toEvict.append(id)
            } else if now.timeIntervalSince(info.createdAt) > connectionTTLSeconds {
                if info.isIdle {
                    toEvict.append(id)
                }
            }
        }

        for id in toEvict {
            evictConnection(id: id, reason: "expired")
        }

        if !toEvict.isEmpty {
            logger.log("ConnectionPool: cleanup evicted \(toEvict.count) expired connections (pool: \(pooledConnections.count)/\(maxPoolSize))", category: .proxy, level: .debug)
        }
    }
}
