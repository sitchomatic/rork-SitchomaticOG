import Foundation
import Observation

@Observable
@MainActor
class SessionRecoveryService {
    static let shared = SessionRecoveryService()

    private let storageKey = "session_recovery_batch_v1"
    private let logger = DebugLogger.shared
    private let deviceProxy = DeviceProxyService.shared
    private let wireProxyBridge = WireProxyBridge.shared
    private let localProxy = LocalProxyServer.shared
    private let proxyService = ProxyRotationService.shared

    private(set) var activeBatch: SessionRecoveryBatch?
    private(set) var lastRecoveredBatch: SessionRecoveryBatch?
    private(set) var hasRecoverableBatch: Bool = false

    init() {
        loadPersistedBatch()
    }

    func beginBatch(credentials: [LoginCredential], siteMode: String, targetURL: URL) {
        let snapshots = credentials.enumerated().map { index, cred in
            buildSnapshot(
                credential: cred,
                targetURL: targetURL.absoluteString,
                sessionIndex: index,
                batchPosition: index,
                batchTotal: credentials.count
            )
        }

        activeBatch = SessionRecoveryBatch(
            snapshots: snapshots,
            siteMode: siteMode,
            totalCredentials: credentials.count,
            completedCount: 0
        )

        persistBatch()
        logger.log("SessionRecovery: batch started — \(credentials.count) credentials, site=\(siteMode)", category: .persistence, level: .info)
    }

    func updateSnapshot(
        credentialId: String,
        chosenPattern: String? = nil,
        retriesUsed: Int? = nil,
        lastScreenshotHash: String? = nil,
        lastFailureReason: String? = nil,
        lastFailureOutcome: String? = nil
    ) {
        guard let batch = activeBatch else { return }

        let networkSnapshot = captureNetworkState()

        var snapshots = batch.snapshots
        guard let idx = snapshots.firstIndex(where: { $0.credentialId == credentialId }) else { return }

        snapshots[idx] = snapshots[idx].withUpdate(
            chosenPattern: chosenPattern,
            retriesUsed: retriesUsed,
            lastScreenshotHash: lastScreenshotHash,
            networkMode: networkSnapshot.networkMode,
            proxyHost: .some(networkSnapshot.proxyHost),
            proxyPort: .some(networkSnapshot.proxyPort),
            tunnelActive: networkSnapshot.tunnelActive,
            wireProxyActive: networkSnapshot.wireProxyActive,
            lastFailureReason: .some(lastFailureReason),
            lastFailureOutcome: .some(lastFailureOutcome)
        )

        activeBatch = SessionRecoveryBatch(
            batchId: batch.batchId,
            startedAt: batch.startedAt,
            snapshots: snapshots,
            siteMode: batch.siteMode,
            totalCredentials: batch.totalCredentials,
            completedCount: batch.completedCount
        )

        persistBatch()
    }

    func markCompleted(credentialId: String) {
        guard let batch = activeBatch else { return }

        var snapshots = batch.snapshots
        snapshots.removeAll { $0.credentialId == credentialId }

        let newCompleted = batch.completedCount + 1
        activeBatch = SessionRecoveryBatch(
            batchId: batch.batchId,
            startedAt: batch.startedAt,
            snapshots: snapshots,
            siteMode: batch.siteMode,
            totalCredentials: batch.totalCredentials,
            completedCount: newCompleted
        )

        persistBatch()
    }

    func endBatch() {
        activeBatch = nil
        clearPersistedBatch()
        hasRecoverableBatch = false
        logger.log("SessionRecovery: batch ended — persisted state cleared", category: .persistence, level: .info)
    }

    func recoverBatch() -> SessionRecoveryBatch? {
        guard let batch = activeBatch, !batch.snapshots.isEmpty else {
            hasRecoverableBatch = false
            return nil
        }
        lastRecoveredBatch = batch
        logger.log("SessionRecovery: recovering batch — \(batch.snapshots.count) pending snapshots from \(batch.totalCredentials) total", category: .persistence, level: .warning)
        return batch
    }

    func dismissRecovery() {
        lastRecoveredBatch = nil
        endBatch()
    }

    func pendingSnapshots() -> [SessionRecoverySnapshot] {
        activeBatch?.snapshots ?? []
    }

    func snapshotFor(credentialId: String) -> SessionRecoverySnapshot? {
        activeBatch?.snapshots.first { $0.credentialId == credentialId }
    }

    private func buildSnapshot(credential: LoginCredential, targetURL: String, sessionIndex: Int, batchPosition: Int, batchTotal: Int) -> SessionRecoverySnapshot {
        let networkState = captureNetworkState()

        return SessionRecoverySnapshot(
            credentialId: credential.id,
            username: credential.username,
            targetURL: targetURL,
            networkMode: networkState.networkMode,
            proxyHost: networkState.proxyHost,
            proxyPort: networkState.proxyPort,
            tunnelActive: networkState.tunnelActive,
            wireProxyActive: networkState.wireProxyActive,
            ipRoutingMode: deviceProxy.ipRoutingMode.shortLabel,
            sessionIndex: sessionIndex,
            batchPosition: batchPosition,
            batchTotal: batchTotal
        )
    }

    private struct NetworkState {
        let networkMode: String
        let proxyHost: String?
        let proxyPort: Int?
        let tunnelActive: Bool
        let wireProxyActive: Bool
    }

    private func captureNetworkState() -> NetworkState {
        let wpActive = wireProxyBridge.isActive
        let lpRunning = localProxy.isRunning
        let lpPort = localProxy.listeningPort

        if deviceProxy.isEnabled, let config = deviceProxy.activeConfig {
            switch config {
            case .socks5(let proxy):
                if deviceProxy.isWireProxyActive && lpRunning && localProxy.wireProxyMode {
                    return NetworkState(networkMode: "WireGuard→WireProxy", proxyHost: "127.0.0.1", proxyPort: Int(lpPort), tunnelActive: true, wireProxyActive: true)
                } else if lpRunning {
                    return NetworkState(networkMode: "SOCKS5→LocalProxy", proxyHost: proxy.host, proxyPort: proxy.port, tunnelActive: false, wireProxyActive: false)
                } else {
                    return NetworkState(networkMode: "SOCKS5", proxyHost: proxy.host, proxyPort: proxy.port, tunnelActive: false, wireProxyActive: false)
                }
            case .wireGuardDNS(_):
                if wpActive && lpRunning && localProxy.wireProxyMode {
                    return NetworkState(networkMode: "WireGuard→WireProxy", proxyHost: "127.0.0.1", proxyPort: Int(lpPort), tunnelActive: true, wireProxyActive: true)
                } else {
                    return NetworkState(networkMode: "WireGuard(DNS)", proxyHost: nil, proxyPort: nil, tunnelActive: false, wireProxyActive: false)
                }
            case .openVPNProxy(let ovpn):
                return NetworkState(networkMode: "OpenVPN", proxyHost: ovpn.remoteHost, proxyPort: ovpn.remotePort, tunnelActive: false, wireProxyActive: false)
            case .direct:
                return NetworkState(networkMode: "Direct", proxyHost: nil, proxyPort: nil, tunnelActive: false, wireProxyActive: false)
            }
        }

        let mode = proxyService.connectionMode(for: .joe)
        switch mode {
        case .direct: return NetworkState(networkMode: "Direct", proxyHost: nil, proxyPort: nil, tunnelActive: false, wireProxyActive: false)
        case .dns: return NetworkState(networkMode: "DNS", proxyHost: nil, proxyPort: nil, tunnelActive: false, wireProxyActive: false)
        case .proxy: return NetworkState(networkMode: "SOCKS5", proxyHost: nil, proxyPort: nil, tunnelActive: false, wireProxyActive: false)
        case .wireguard:
            if wpActive && lpRunning && localProxy.wireProxyMode {
                return NetworkState(networkMode: "WireGuard→WireProxy", proxyHost: "127.0.0.1", proxyPort: Int(lpPort), tunnelActive: true, wireProxyActive: true)
            }
            return NetworkState(networkMode: "WireGuard", proxyHost: nil, proxyPort: nil, tunnelActive: false, wireProxyActive: wpActive)
        case .openvpn: return NetworkState(networkMode: "OpenVPN", proxyHost: nil, proxyPort: nil, tunnelActive: false, wireProxyActive: false)
        case .nodeMaven: return NetworkState(networkMode: "NodeMaven", proxyHost: nil, proxyPort: nil, tunnelActive: false, wireProxyActive: false)
        case .hybrid: return NetworkState(networkMode: "Hybrid", proxyHost: nil, proxyPort: nil, tunnelActive: false, wireProxyActive: false)
        }
    }

    private func persistBatch() {
        guard let batch = activeBatch else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(batch) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func clearPersistedBatch() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private func loadPersistedBatch() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            hasRecoverableBatch = false
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let batch = try? decoder.decode(SessionRecoveryBatch.self, from: data),
           !batch.snapshots.isEmpty {
            activeBatch = batch
            hasRecoverableBatch = true
            logger.log("SessionRecovery: found recoverable batch — \(batch.snapshots.count) pending from \(batch.totalCredentials) total", category: .persistence, level: .warning)
        } else {
            hasRecoverableBatch = false
        }
    }
}
