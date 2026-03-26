import Foundation
import Network

@MainActor
class WireProxyTunnelConnection {
    let id: UUID
    private let clientConnection: NWConnection
    let targetHost: String
    let targetPort: UInt16
    private let queue: DispatchQueue
    private weak var server: LocalProxyServer?
    private weak var bridge: WireProxyBridge?
    private let logger = DebugLogger.shared

    private var tcpSession: TCPSession?
    private var isCancelled: Bool = false
    private var bytesUploaded: UInt64 = 0
    private var bytesDownloaded: UInt64 = 0
    private var hadError: Bool = false
    private var timeoutWork: DispatchWorkItem?
    private let timeoutSeconds: TimeInterval = 30

    init(
        id: UUID,
        clientConnection: NWConnection,
        targetHost: String,
        targetPort: UInt16,
        queue: DispatchQueue,
        server: LocalProxyServer,
        bridge: WireProxyBridge
    ) {
        self.id = id
        self.clientConnection = clientConnection
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.queue = queue
        self.server = server
        self.bridge = bridge
    }

    func start() {
        server?.updateConnectionInfo(id: id, targetHost: targetHost, targetPort: targetPort, state: .handshaking)
        startTimeout()

        Task {
            await resolveAndConnect()
        }
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelTimeout()
        clientConnection.cancel()
        if let session = tcpSession {
            bridge?.resetSession(session)
        }
    }

    private func resolveAndConnect() async {
        guard !isCancelled, let bridge else { finish(error: true); return }

        guard let destinationIP = await bridge.resolveHostname(targetHost) else {
            logger.log("WireProxyTunnel: DNS resolve failed for \(targetHost)", category: .vpn, level: .error)
            sendSOCKS5Error(0x04)
            return
        }

        guard !isCancelled else { return }

        let session = bridge.createTCPSession(destinationIP: destinationIP, destinationPort: targetPort)
        self.tcpSession = session

        session.onConnectionEstablished = { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.cancelTimeout()
            self.sendSOCKS5Success()
        }

        session.onDataReceived = { [weak self] data in
            guard let self, !self.isCancelled else { return }
            self.bytesDownloaded += UInt64(data.count)
            self.server?.updateConnectionBytes(id: self.id, bytes: self.bytesUploaded + self.bytesDownloaded)
            self.sendToClient(data)
        }

        session.onConnectionClosed = { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.finish(error: false)
        }

        session.onError = { [weak self] error in
            guard let self, !self.isCancelled else { return }
            self.logger.log("WireProxyTunnel: TCP error for \(self.targetHost):\(self.targetPort) - \(error)", category: .vpn, level: .error)
            self.finish(error: true)
        }

        bridge.initiateConnection(session)
        logger.log("WireProxyTunnel: connecting to \(targetHost):\(targetPort) via WG tunnel", category: .vpn, level: .debug)
    }

    private func sendSOCKS5Success() {
        let response = Data([0x05, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        clientConnection.send(content: response, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil {
                    self.finish(error: true)
                    return
                }
                self.server?.updateConnectionInfo(id: self.id, targetHost: self.targetHost, targetPort: self.targetPort, state: .relaying)
                self.startReadingFromClient()
            }
        })
    }

    private func sendSOCKS5Error(_ rep: UInt8) {
        let response = Data([0x05, rep, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        clientConnection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finish(error: true)
            }
        })
    }

    private func startReadingFromClient() {
        guard !isCancelled else { return }

        clientConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }

                if let data, !data.isEmpty {
                    self.bytesUploaded += UInt64(data.count)
                    self.server?.updateConnectionBytes(id: self.id, bytes: self.bytesUploaded + self.bytesDownloaded)

                    if let session = self.tcpSession {
                        self.bridge?.sendData(session, data: data)
                    }

                    self.startReadingFromClient()
                } else if isComplete || error != nil {
                    if let session = self.tcpSession {
                        self.bridge?.closeSession(session)
                    }
                } else {
                    self.startReadingFromClient()
                }
            }
        }
    }

    private func sendToClient(_ data: Data) {
        guard !isCancelled else { return }

        clientConnection.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil {
                    self.hadError = true
                    if let session = self.tcpSession {
                        self.bridge?.resetSession(session)
                    }
                    self.finish(error: true)
                }
            }
        })
    }

    private func finish(error: Bool) {
        guard !isCancelled else { return }
        isCancelled = true
        cancelTimeout()
        hadError = error || hadError
        clientConnection.cancel()

        let totalBytes = bytesUploaded + bytesDownloaded
        server?.connectionFinished(
            id: id,
            bytesRelayed: totalBytes,
            bytesUp: bytesUploaded,
            bytesDown: bytesDownloaded,
            hadError: hadError,
            errorType: hadError ? .relay : .none,
            targetHost: targetHost
        )
        bridge?.connectionFinished(id: id, hadError: hadError)
    }

    private func startTimeout() {
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                self.logger.log("WireProxyTunnel: timeout for \(self.targetHost):\(self.targetPort)", category: .vpn, level: .warning)
                self.finish(error: true)
            }
        }
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: work)
    }

    private func cancelTimeout() {
        timeoutWork?.cancel()
        timeoutWork = nil
    }
}
