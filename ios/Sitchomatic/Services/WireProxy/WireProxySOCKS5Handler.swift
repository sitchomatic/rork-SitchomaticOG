import Foundation
import Network

@MainActor
class WireProxySOCKS5Handler {
    let id: UUID
    private let clientConnection: NWConnection
    private let queue: DispatchQueue
    private weak var server: LocalProxyServer?
    private let logger = DebugLogger.shared

    private var isCancelled: Bool = false
    private var targetHost: String = ""
    private var targetPort: UInt16 = 0
    private var timeoutWork: DispatchWorkItem?
    private let timeoutSeconds: TimeInterval = 30

    init(id: UUID, clientConnection: NWConnection, queue: DispatchQueue, server: LocalProxyServer) {
        self.id = id
        self.clientConnection = clientConnection
        self.queue = queue
        self.server = server
    }

    func start() {
        startTimeout()

        clientConnection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                switch state {
                case .ready:
                    self.readSOCKS5Greeting()
                case .failed:
                    self.finish(error: true)
                case .cancelled:
                    self.finish(error: false)
                default:
                    break
                }
            }
        }
        clientConnection.start(queue: queue)
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelTimeout()
        clientConnection.cancel()
    }

    private func readSOCKS5Greeting() {
        server?.updateConnectionInfo(id: id, targetHost: "", targetPort: 0, state: .handshaking)

        clientConnection.receive(minimumIncompleteLength: 2, maximumLength: 257) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.finish(error: true); return }
                guard let data, data.count >= 2, data[0] == 0x05 else {
                    self.finish(error: true)
                    return
                }

                let response = Data([0x05, 0x00])
                self.clientConnection.send(content: response, completion: .contentProcessed { [weak self] sendError in
                    Task { @MainActor [weak self] in
                        guard let self, !self.isCancelled else { return }
                        if sendError != nil { self.finish(error: true); return }
                        self.readSOCKS5Request()
                    }
                })
            }
        }
    }

    private func readSOCKS5Request() {
        clientConnection.receive(minimumIncompleteLength: 4, maximumLength: 512) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.finish(error: true); return }
                guard let data, data.count >= 4, data[0] == 0x05, data[1] == 0x01 else {
                    self.sendSOCKS5Error(0x07)
                    return
                }

                let addressType = data[3]
                var host: String = ""
                var port: UInt16 = 0

                switch addressType {
                case 0x01:
                    guard data.count >= 10 else { self.finish(error: true); return }
                    host = "\(data[4]).\(data[5]).\(data[6]).\(data[7])"
                    port = UInt16(data[8]) << 8 | UInt16(data[9])

                case 0x03:
                    guard data.count >= 5 else { self.finish(error: true); return }
                    let domainLength = Int(data[4])
                    guard data.count >= 5 + domainLength + 2 else { self.finish(error: true); return }
                    host = String(data: data[5..<(5 + domainLength)], encoding: .utf8) ?? ""
                    let portOffset = 5 + domainLength
                    port = UInt16(data[portOffset]) << 8 | UInt16(data[portOffset + 1])

                case 0x04:
                    guard data.count >= 22 else { self.finish(error: true); return }
                    let ipv6Bytes = data[4..<20]
                    host = ipv6Bytes.map { String(format: "%02x", $0) }
                        .enumerated()
                        .reduce("") { result, pair in
                            let sep = (pair.offset > 0 && pair.offset % 2 == 0) ? ":" : ""
                            return result + sep + pair.element
                        }
                    port = UInt16(data[20]) << 8 | UInt16(data[21])

                default:
                    self.sendSOCKS5Error(0x08)
                    return
                }

                guard !host.isEmpty, port > 0 else {
                    self.sendSOCKS5Error(0x01)
                    return
                }

                self.targetHost = host
                self.targetPort = port
                self.cancelTimeout()
                self.handoffToWireProxyBridge()
            }
        }
    }

    private func handoffToWireProxyBridge() {
        let bridge = WireProxyBridge.shared
        guard bridge.isActive, let server else {
            sendSOCKS5Error(0x01)
            return
        }

        isCancelled = true
        cancelTimeout()

        bridge.handleSOCKS5Connection(
            id: id,
            clientConnection: clientConnection,
            targetHost: targetHost,
            targetPort: targetPort,
            queue: queue,
            server: server
        )
    }

    private func sendSOCKS5Error(_ rep: UInt8) {
        let response = Data([0x05, rep, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        clientConnection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finish(error: true)
            }
        })
    }

    private func finish(error: Bool) {
        guard !isCancelled else { return }
        isCancelled = true
        cancelTimeout()
        if error {
            clientConnection.cancel()
        }
        server?.connectionFinished(
            id: id,
            bytesRelayed: 0,
            bytesUp: 0,
            bytesDown: 0,
            hadError: error,
            errorType: error ? .handshake : .none,
            targetHost: targetHost
        )
        server?.tunnelConnectionFinished(id: id)
    }

    private func startTimeout() {
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
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
