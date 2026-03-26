import Foundation
import Network
import Observation

@Observable
@MainActor
class NetworkRepairService {
    static let shared = NetworkRepairService()

    private(set) var isRepairing: Bool = false
    private(set) var repairPhase: RepairPhase = .idle
    private(set) var repairLog: [RepairLogEntry] = []
    private(set) var lastRepairResult: RepairResult?
    private(set) var lastRepairDate: Date?

    private let logger = DebugLogger.shared

    nonisolated enum RepairPhase: String, Sendable {
        case idle = "Idle"
        case stoppingBatches = "Stopping Active Batches"
        case tearingDownSessions = "Tearing Down Sessions"
        case stoppingLocalProxy = "Stopping Local Proxy"
        case tearingDownVPN = "Tearing Down VPN Tunnel"
        case flushingDNS = "Flushing DNS Cache"
        case resetCircuitBreakers = "Resetting Circuit Breakers"
        case resetThrottling = "Resetting Throttling"
        case rebuildingDNS = "Rebuilding DNS Pool"
        case restartingLocalProxy = "Restarting Local Proxy"
        case reconnectingVPN = "Reconnecting VPN"
        case healthCheck = "Running Health Check"
        case complete = "Complete"
        case failed = "Failed"

        var icon: String {
            switch self {
            case .idle: "circle"
            case .stoppingBatches: "stop.circle.fill"
            case .tearingDownSessions: "xmark.circle.fill"
            case .stoppingLocalProxy: "server.rack"
            case .tearingDownVPN: "shield.slash.fill"
            case .flushingDNS: "arrow.clockwise.circle.fill"
            case .resetCircuitBreakers: "bolt.trianglebadge.exclamationmark.fill"
            case .resetThrottling: "gauge.with.dots.needle.33percent"
            case .rebuildingDNS: "lock.shield.fill"
            case .restartingLocalProxy: "play.circle.fill"
            case .reconnectingVPN: "shield.lefthalf.filled"
            case .healthCheck: "stethoscope"
            case .complete: "checkmark.circle.fill"
            case .failed: "exclamationmark.triangle.fill"
            }
        }
    }

    nonisolated struct RepairLogEntry: Identifiable, Sendable {
        let id: UUID = UUID()
        let timestamp: Date = Date()
        let phase: RepairPhase
        let message: String
        let success: Bool
    }

    nonisolated struct RepairResult: Sendable {
        let timestamp: Date
        let totalDurationMs: Int
        let phasesCompleted: Int
        let phaseFailed: RepairPhase?
        let dnsHealthy: Int
        let dnsFailed: Int
        let networkHealthSummary: String
        let overallSuccess: Bool
    }

    func repairNetwork() async {
        guard !isRepairing else {
            logger.log("NetworkRepair: already in progress — skipping", category: .network, level: .warning)
            return
        }

        isRepairing = true
        repairLog.removeAll()
        let startTime = CFAbsoluteTimeGetCurrent()
        var phasesCompleted = 0
        var failedPhase: RepairPhase?

        logger.log("NetworkRepair: === FULL NETWORK REPAIR STARTED ===", category: .network, level: .critical)

        DebugLogger.shared.flushAllToDisk()
        PersistentFileStorageService.shared.forceSave()

        do {
            try await executePhase(.stoppingBatches) {
                if LoginViewModel.shared.isRunning {
                    LoginViewModel.shared.emergencyStop()
                    self.logger.log("NetworkRepair: stopped login batch", category: .network, level: .warning)
                }
                if PPSRAutomationViewModel.shared.isRunning {
                    PPSRAutomationViewModel.shared.emergencyStop()
                    self.logger.log("NetworkRepair: stopped PPSR batch", category: .network, level: .warning)
                }
                DeadSessionDetector.shared.stopAllWatchdogs()
            }
            phasesCompleted += 1

            try await executePhase(.tearingDownSessions) {
                NetworkResilienceService.shared.invalidateSharedSessions()
                URLCache.shared.removeAllCachedResponses()
                URLSession.shared.reset {}
                WebViewPool.shared.emergencyPurgeAll()
                self.logger.log("NetworkRepair: all URL sessions invalidated, WebView pool purged", category: .network, level: .info)
            }
            phasesCompleted += 1

            try await executePhase(.stoppingLocalProxy) {
                let localProxy = LocalProxyServer.shared
                if localProxy.isRunning {
                    localProxy.stop()
                    try? await Task.sleep(for: .milliseconds(500))
                    self.logger.log("NetworkRepair: local proxy server stopped", category: .network, level: .info)
                }
            }
            phasesCompleted += 1

            try await executePhase(.tearingDownVPN) {
                let tunnel = VPNTunnelManager.shared
                if tunnel.status == .connected || tunnel.status == .connecting {
                    tunnel.disconnect(reason: "Network repair")
                    try? await Task.sleep(for: .seconds(1))
                    self.logger.log("NetworkRepair: VPN tunnel disconnected", category: .vpn, level: .info)
                }
                NetworkResilienceService.shared.stopVerificationLoop()
                self.logger.log("NetworkRepair: verification loop stopped", category: .network, level: .info)
            }
            phasesCompleted += 1

            try await executePhase(.flushingDNS) {
                DNSPoolService.shared.invalidateCache()
                self.logger.log("NetworkRepair: DNS cache flushed", category: .dns, level: .info)
            }
            phasesCompleted += 1

            try await executePhase(.resetCircuitBreakers) {
                HostCircuitBreakerService.shared.resetAll()
                self.logger.log("NetworkRepair: circuit breakers reset", category: .network, level: .info)
            }
            phasesCompleted += 1

            try await executePhase(.resetThrottling) {
                let resilience = NetworkResilienceService.shared
                resilience.resetThrottling()
                resilience.resetBackoff()
                resilience.resetDNSHealth()
                self.logger.log("NetworkRepair: throttling & backoff reset", category: .network, level: .info)
            }
            phasesCompleted += 1

            try await executePhase(.rebuildingDNS) {
                DNSPoolService.shared.resetAutoDisabled()
                let (healthy, failed, _) = await DNSPoolService.shared.preflightTestAllActive()
                self.logger.log("NetworkRepair: DNS pool rebuilt — healthy:\(healthy) failed:\(failed)", category: .dns, level: healthy > 0 ? .success : .error)
            }
            phasesCompleted += 1

            try await executePhase(.restartingLocalProxy) {
                let deviceProxy = DeviceProxyService.shared
                if deviceProxy.isEnabled {
                    let localProxy = LocalProxyServer.shared
                    localProxy.upstreamProxy = deviceProxy.effectiveProxyConfig
                    localProxy.start()
                    try? await Task.sleep(for: .milliseconds(500))
                    self.logger.log("NetworkRepair: local proxy restarted on :\(localProxy.listeningPort)", category: .network, level: .success)
                }
            }
            phasesCompleted += 1

            try await executePhase(.reconnectingVPN) {
                let tunnel = VPNTunnelManager.shared
                if tunnel.vpnEnabled, let config = tunnel.activeConfig {
                    await tunnel.configureAndConnect(with: config)
                    try? await Task.sleep(for: .seconds(2))
                    let connected = tunnel.status == .connected
                    self.logger.log("NetworkRepair: VPN reconnect \(connected ? "succeeded" : "pending")", category: .vpn, level: connected ? .success : .warning)
                }
            }
            phasesCompleted += 1

            var healthSummary = ""
            try await executePhase(.healthCheck) {
                let (dnsHealthy, dnsFailed, _) = await DNSPoolService.shared.preflightTestAllActive()
                let networkLayer = NetworkLayerService.shared
                await networkLayer.runHealthCheck(for: .joe)
                healthSummary = networkLayer.healthSummary
                self.logger.log("NetworkRepair: health check — DNS(\(dnsHealthy)ok/\(dnsFailed)fail) Network: \(healthSummary)", category: .network, level: .success)
            }
            phasesCompleted += 1

            let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            let (dnsH, dnsF, _) = await DNSPoolService.shared.preflightTestAllActive()

            let result = RepairResult(
                timestamp: Date(),
                totalDurationMs: elapsed,
                phasesCompleted: phasesCompleted,
                phaseFailed: nil,
                dnsHealthy: dnsH,
                dnsFailed: dnsF,
                networkHealthSummary: healthSummary,
                overallSuccess: true
            )
            lastRepairResult = result
            lastRepairDate = Date()
            repairPhase = .complete

            logger.log("NetworkRepair: === REPAIR COMPLETE in \(elapsed)ms — \(phasesCompleted) phases OK ===", category: .network, level: .success)

            AppAlertManager.shared.pushInfo(
                source: .network,
                title: "Network Repaired",
                message: "All network protocols restarted successfully in \(elapsed)ms. DNS: \(dnsH) healthy."
            )

        } catch {
            failedPhase = repairPhase
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

            let result = RepairResult(
                timestamp: Date(),
                totalDurationMs: elapsed,
                phasesCompleted: phasesCompleted,
                phaseFailed: failedPhase,
                dnsHealthy: 0,
                dnsFailed: 0,
                networkHealthSummary: "Repair failed at \(failedPhase?.rawValue ?? "unknown")",
                overallSuccess: false
            )
            lastRepairResult = result
            lastRepairDate = Date()
            repairPhase = .failed

            logger.log("NetworkRepair: === REPAIR FAILED at phase '\(failedPhase?.rawValue ?? "?")' after \(elapsed)ms — \(error.localizedDescription) ===", category: .network, level: .critical)

            AppAlertManager.shared.pushCritical(
                source: .network,
                title: "Network Repair Failed",
                message: "Failed at: \(failedPhase?.rawValue ?? "unknown"). \(error.localizedDescription)"
            )
        }

        isRepairing = false
    }

    private func executePhase(_ phase: RepairPhase, action: @MainActor () async throws -> Void) async throws {
        repairPhase = phase
        let start = CFAbsoluteTimeGetCurrent()
        do {
            try await action()
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            repairLog.append(RepairLogEntry(phase: phase, message: "\(phase.rawValue) completed in \(ms)ms", success: true))
        } catch {
            repairLog.append(RepairLogEntry(phase: phase, message: "\(phase.rawValue) FAILED: \(error.localizedDescription)", success: false))
            throw error
        }
    }
}
