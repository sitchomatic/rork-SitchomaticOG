import Foundation
import Network

@MainActor
class WireProxyMultiTunnelConnection: WireProxyTunnelConnection {
    private let slot: WireProxyTunnelSlot
    private var mtTcpSession: TCPSession?
    private var mtIsCancelled: Bool = false
    private var mtBytesUploaded: UInt64 = 0
    private var mtBytesDownloaded: UInt64 = 0
    private var mtHadError: Bool = false
    private var mtTimeoutWork: DispatchWorkItem?
    private let mtTimeoutSeconds: TimeInterval = 30
    private let mtClientConnection: NWConnection
    private let mtTargetHost: String
    private let mtTargetPort: UInt16
    private let mtQueue: DispatchQueue
    private weak var mtServer: LocalProxyServer?
    private weak var mtBridge: WireProxyBridge?
    private let mtLogger = DebugLogger.shared
    private let mtId: UUID

    init(
        id: UUID,
        clientConnection: NWConnection,
        targetHost: String,
        targetPort: UInt16,
        queue: DispatchQueue,
        server: LocalProxyServer,
        bridge: WireProxyBridge,
        slot: WireProxyTunnelSlot
    ) {
        self.slot = slot
        self.mtId = id
        self.mtClientConnection = clientConnection
        self.mtTargetHost = targetHost
        self.mtTargetPort = targetPort
        self.mtQueue = queue
        self.mtServer = server
        self.mtBridge = bridge
        super.init(
            id: id,
            clientConnection: clientConnection,
            targetHost: targetHost,
            targetPort: targetPort,
            queue: queue,
            server: server,
            bridge: bridge
        )
    }

    override func start() {
        mtServer?.updateConnectionInfo(id: mtId, targetHost: mtTargetHost, targetPort: mtTargetPort, state: .handshaking)
        startMTTimeout()

        Task {
            await resolveAndConnectViaSlot()
        }
    }

    override func cancel() {
        guard !mtIsCancelled else { return }
        mtIsCancelled = true
        cancelMTTimeout()
        mtClientConnection.cancel()
        if let session = mtTcpSession {
            mtBridge?.resetMultiTunnelSession(session, slot: slot)
        }
    }

    private func resolveAndConnectViaSlot() async {
        guard !mtIsCancelled, let bridge = mtBridge else { finishMT(error: true); return }

        guard let destinationIP = await bridge.resolveMultiTunnelHostname(mtTargetHost, slot: slot) else {
            mtLogger.log("WireProxyMT: DNS resolve failed for \(mtTargetHost) on slot \(slot.index)", category: .vpn, level: .error)
            sendMTSOCKS5Error(0x04)
            return
        }

        guard !mtIsCancelled else { return }

        let session = bridge.createMultiTunnelTCPSession(slot: slot, destinationIP: destinationIP, destinationPort: mtTargetPort)
        self.mtTcpSession = session

        session.onConnectionEstablished = { [weak self] in
            guard let self, !self.mtIsCancelled else { return }
            self.cancelMTTimeout()
            self.sendMTSOCKS5Success()
        }

        session.onDataReceived = { [weak self] data in
            guard let self, !self.mtIsCancelled else { return }
            self.mtBytesDownloaded += UInt64(data.count)
            self.mtServer?.updateConnectionBytes(id: self.mtId, bytes: self.mtBytesUploaded + self.mtBytesDownloaded)
            self.sendMTToClient(data)
        }

        session.onConnectionClosed = { [weak self] in
            guard let self, !self.mtIsCancelled else { return }
            self.finishMT(error: false)
        }

        session.onError = { [weak self] error in
            guard let self, !self.mtIsCancelled else { return }
            self.mtLogger.log("WireProxyMT: TCP error for \(self.mtTargetHost):\(self.mtTargetPort) slot \(self.slot.index) - \(error)", category: .vpn, level: .error)
            self.finishMT(error: true)
        }

        bridge.initiateMultiTunnelConnection(session, slot: slot)
        mtLogger.log("WireProxyMT: connecting \(mtTargetHost):\(mtTargetPort) via slot \(slot.index) (\(slot.serverName))", category: .vpn, level: .debug)
    }

    private func sendMTSOCKS5Success() {
        let response = Data([0x05, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        mtClientConnection.send(content: response, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, !self.mtIsCancelled else { return }
                if error != nil {
                    self.finishMT(error: true)
                    return
                }
                self.mtServer?.updateConnectionInfo(id: self.mtId, targetHost: self.mtTargetHost, targetPort: self.mtTargetPort, state: .relaying)
                self.startMTReadingFromClient()
            }
        })
    }

    private func sendMTSOCKS5Error(_ rep: UInt8) {
        let response = Data([0x05, rep, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        mtClientConnection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finishMT(error: true)
            }
        })
    }

    private func startMTReadingFromClient() {
        guard !mtIsCancelled else { return }

        mtClientConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.mtIsCancelled else { return }

                if let data, !data.isEmpty {
                    self.mtBytesUploaded += UInt64(data.count)
                    self.mtServer?.updateConnectionBytes(id: self.mtId, bytes: self.mtBytesUploaded + self.mtBytesDownloaded)

                    if let session = self.mtTcpSession {
                        self.mtBridge?.sendMultiTunnelData(session, data: data, slot: self.slot)
                    }

                    self.startMTReadingFromClient()
                } else if isComplete || error != nil {
                    if let session = self.mtTcpSession {
                        self.mtBridge?.closeMultiTunnelSession(session, slot: self.slot)
                    }
                } else {
                    self.startMTReadingFromClient()
                }
            }
        }
    }

    private func sendMTToClient(_ data: Data) {
        guard !mtIsCancelled else { return }

        mtClientConnection.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, !self.mtIsCancelled else { return }
                if error != nil {
                    self.mtHadError = true
                    if let session = self.mtTcpSession {
                        self.mtBridge?.resetMultiTunnelSession(session, slot: self.slot)
                    }
                    self.finishMT(error: true)
                }
            }
        })
    }

    private func finishMT(error: Bool) {
        guard !mtIsCancelled else { return }
        mtIsCancelled = true
        cancelMTTimeout()
        mtHadError = error || mtHadError
        mtClientConnection.cancel()

        let totalBytes = mtBytesUploaded + mtBytesDownloaded
        mtServer?.connectionFinished(
            id: mtId,
            bytesRelayed: totalBytes,
            bytesUp: mtBytesUploaded,
            bytesDown: mtBytesDownloaded,
            hadError: mtHadError,
            errorType: mtHadError ? .relay : .none,
            targetHost: mtTargetHost
        )
        mtBridge?.connectionFinished(id: mtId, hadError: mtHadError)
    }

    private func startMTTimeout() {
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.mtIsCancelled else { return }
                self.mtLogger.log("WireProxyMT: timeout for \(self.mtTargetHost):\(self.mtTargetPort) slot \(self.slot.index)", category: .vpn, level: .warning)
                self.finishMT(error: true)
            }
        }
        mtTimeoutWork = work
        mtQueue.asyncAfter(deadline: .now() + mtTimeoutSeconds, execute: work)
    }

    private func cancelMTTimeout() {
        mtTimeoutWork?.cancel()
        mtTimeoutWork = nil
    }
}
