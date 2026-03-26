import Foundation
import Network

@MainActor
class LocalProxyConnection {
    let id: UUID
    private let clientConnection: NWConnection
    private var upstreamConnection: NWConnection?
    private let upstream: ProxyConfig?
    private let queue: DispatchQueue
    private weak var server: LocalProxyServer?
    private let timeoutSeconds: TimeInterval
    private let connectionPool = ProxyConnectionPool.shared

    private var bytesRelayed: UInt64 = 0
    private var bytesUploaded: UInt64 = 0
    private var bytesDownloaded: UInt64 = 0
    private var hadError: Bool = false
    private var isCancelled: Bool = false
    private var errorType: ConnectionErrorType = .none
    private var targetHost: String = ""
    private var targetPort: UInt16 = 0
    private var timeoutWork: DispatchWorkItem?
    private var pooledConnectionId: UUID?
    private var authRetryCount: Int = 0
    private let maxAuthRetries: Int = 2
    private var upstreamHalfClosed: Bool = false
    private var clientHalfClosed: Bool = false

    init(id: UUID, clientConnection: NWConnection, upstream: ProxyConfig?, queue: DispatchQueue, server: LocalProxyServer, timeoutSeconds: TimeInterval = 30) {
        self.id = id
        self.clientConnection = clientConnection
        self.upstream = upstream
        self.queue = queue
        self.server = server
        self.timeoutSeconds = timeoutSeconds
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
                    self.errorType = .connection
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
        upstreamConnection?.cancel()
    }

    private func finish(error: Bool) {
        guard !isCancelled else { return }
        isCancelled = true
        cancelTimeout()
        hadError = error || hadError
        clientConnection.cancel()
        if let poolId = pooledConnectionId {
            connectionPool.releaseConnection(id: poolId, hadError: hadError)
            pooledConnectionId = nil
        } else {
            if upstream != nil {
                connectionPool.recordUpstreamConnectionFinished(hadError: hadError)
            }
            upstreamConnection?.cancel()
        }
        server?.connectionFinished(
            id: id,
            bytesRelayed: bytesRelayed,
            bytesUp: bytesUploaded,
            bytesDown: bytesDownloaded,
            hadError: hadError,
            errorType: errorType,
            targetHost: targetHost
        )
    }

    private func startTimeout() {
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                self.errorType = .connection
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

    private func resetTimeout() {
        cancelTimeout()
        startTimeout()
    }

    private func readSOCKS5Greeting() {
        server?.updateConnectionInfo(id: id, targetHost: "", targetPort: 0, state: .handshaking)

        clientConnection.receive(minimumIncompleteLength: 2, maximumLength: 257) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil {
                    self.errorType = .handshake
                    self.finish(error: true)
                    return
                }
                guard let data, data.count >= 2 else {
                    self.errorType = .handshake
                    self.finish(error: true)
                    return
                }

                let version = data[0]
                guard version == 0x05 else {
                    self.errorType = .handshake
                    self.finish(error: true)
                    return
                }

                let response = Data([0x05, 0x00])
                self.clientConnection.send(content: response, completion: .contentProcessed { [weak self] sendError in
                    Task { @MainActor [weak self] in
                        guard let self, !self.isCancelled else { return }
                        if sendError != nil {
                            self.errorType = .handshake
                            self.finish(error: true)
                            return
                        }
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
                if error != nil {
                    self.errorType = .handshake
                    self.finish(error: true)
                    return
                }
                guard let data, data.count >= 4 else {
                    self.errorType = .handshake
                    self.finish(error: true)
                    return
                }

                guard data[0] == 0x05, data[1] == 0x01 else {
                    self.sendSOCKS5Error(0x07)
                    return
                }

                let addressType = data[3]
                var host: String = ""
                var port: UInt16 = 0

                switch addressType {
                case 0x01:
                    guard data.count >= 10 else { self.errorType = .handshake; self.finish(error: true); return }
                    host = "\(data[4]).\(data[5]).\(data[6]).\(data[7])"
                    port = UInt16(data[8]) << 8 | UInt16(data[9])

                case 0x03:
                    guard data.count >= 5 else { self.errorType = .handshake; self.finish(error: true); return }
                    let domainLength = Int(data[4])
                    guard data.count >= 5 + domainLength + 2 else { self.errorType = .handshake; self.finish(error: true); return }
                    host = String(data: data[5..<(5 + domainLength)], encoding: .utf8) ?? ""
                    let portOffset = 5 + domainLength
                    port = UInt16(data[portOffset]) << 8 | UInt16(data[portOffset + 1])

                case 0x04:
                    guard data.count >= 22 else { self.errorType = .handshake; self.finish(error: true); return }
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
                self.server?.updateConnectionInfo(id: self.id, targetHost: host, targetPort: port, state: .handshaking)
                self.connectToTarget(host: host, port: port, addressType: addressType)
            }
        }
    }

    private func connectToTarget(host: String, port: UInt16, addressType: UInt8) {
        if let upstream {
            connectViaUpstream(upstream, targetHost: host, targetPort: port, addressType: addressType)
        } else {
            connectDirect(host: host, port: port, addressType: addressType)
        }
    }

    private func connectDirect(host: String, port: UInt16, addressType: UInt8) {
        connectionPool.acquireUpstream(targetHost: host, targetPort: port, upstream: nil) { [weak self] conn, poolId in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else {
                    if let poolId { self?.connectionPool.releaseConnection(id: poolId, hadError: true) }
                    return
                }
                if let conn, let poolId {
                    self.upstreamConnection = conn
                    self.pooledConnectionId = poolId
                    self.sendSOCKS5Success(addressType: addressType)
                } else {
                    self.errorType = .connection
                    self.sendSOCKS5Error(0x05)
                }
            }
        }
    }

    private func connectViaUpstream(_ proxy: ProxyConfig, targetHost: String, targetPort: UInt16, addressType: UInt8) {
        connectionPool.acquireUpstream(targetHost: targetHost, targetPort: targetPort, upstream: proxy) { [weak self] conn, poolId in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else {
                    if let poolId { self?.connectionPool.releaseConnection(id: poolId, hadError: true) }
                    return
                }
                if let conn, let poolId {
                    self.upstreamConnection = conn
                    self.pooledConnectionId = poolId
                    self.performUpstreamSOCKS5Handshake(proxy: proxy, targetHost: targetHost, targetPort: targetPort, addressType: addressType)
                } else {
                    self.errorType = .connection
                    self.sendSOCKS5Error(0x05)
                }
            }
        }
    }

    private func performUpstreamSOCKS5Handshake(proxy: ProxyConfig, targetHost: String, targetPort: UInt16, addressType: UInt8) {
        guard let upstreamConnection, !isCancelled else { return }

        let needsAuth = proxy.username != nil && proxy.password != nil
        let greeting: Data
        if needsAuth {
            greeting = Data([0x05, 0x02, 0x00, 0x02])
        } else {
            greeting = Data([0x05, 0x01, 0x00])
        }

        upstreamConnection.send(content: greeting, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.errorType = .handshake; self.sendSOCKS5Error(0x01); return }
                self.readUpstreamGreetingResponse(proxy: proxy, targetHost: targetHost, targetPort: targetPort, addressType: addressType)
            }
        })
    }

    private func readUpstreamGreetingResponse(proxy: ProxyConfig, targetHost: String, targetPort: UInt16, addressType: UInt8) {
        guard let upstreamConnection, !isCancelled else { return }

        upstreamConnection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.errorType = .handshake; self.sendSOCKS5Error(0x01); return }
                guard let data, data.count == 2, data[0] == 0x05 else {
                    self.errorType = .handshake
                    self.sendSOCKS5Error(0x01)
                    return
                }

                let method = data[1]
                if method == 0x02, let username = proxy.username, let password = proxy.password {
                    self.performUpstreamAuth(username: username, password: password, targetHost: targetHost, targetPort: targetPort, addressType: addressType)
                } else if method == 0x00 {
                    self.sendUpstreamConnectRequest(targetHost: targetHost, targetPort: targetPort, addressType: addressType)
                } else {
                    self.errorType = .handshake
                    self.sendSOCKS5Error(0x01)
                }
            }
        }
    }

    private func performUpstreamAuth(username: String, password: String, targetHost: String, targetPort: UInt16, addressType: UInt8) {
        guard let upstreamConnection, !isCancelled else { return }

        let usernameBytes = Array(username.utf8)
        let passwordBytes = Array(password.utf8)
        var authData = Data([0x01, UInt8(usernameBytes.count)])
        authData.append(contentsOf: usernameBytes)
        authData.append(UInt8(passwordBytes.count))
        authData.append(contentsOf: passwordBytes)

        upstreamConnection.send(content: authData, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.errorType = .handshake; self.sendSOCKS5Error(0x01); return }
                self.readUpstreamAuthResponse(targetHost: targetHost, targetPort: targetPort, addressType: addressType)
            }
        })
    }

    private func readUpstreamAuthResponse(targetHost: String, targetPort: UInt16, addressType: UInt8) {
        guard let upstreamConnection, !isCancelled else { return }

        upstreamConnection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.errorType = .handshake; self.sendSOCKS5Error(0x01); return }
                guard let data, data.count == 2, data[1] == 0x00 else {
                    if self.authRetryCount < self.maxAuthRetries, let proxy = self.upstream {
                        self.authRetryCount += 1
                        self.upstreamConnection?.cancel()
                        self.upstreamConnection = nil
                        self.retryUpstreamWithNoAuth(proxy: proxy, targetHost: targetHost, targetPort: targetPort, addressType: addressType)
                        return
                    }
                    self.errorType = .handshake
                    self.sendSOCKS5Error(0x01)
                    return
                }
                self.sendUpstreamConnectRequest(targetHost: targetHost, targetPort: targetPort, addressType: addressType)
            }
        }
    }

    private func retryUpstreamWithNoAuth(proxy: ProxyConfig, targetHost: String, targetPort: UInt16, addressType: UInt8) {
        if let poolId = pooledConnectionId {
            connectionPool.releaseConnection(id: poolId, hadError: true)
            pooledConnectionId = nil
        }
        connectionPool.recordUpstreamConnectionCreated()

        let proxyEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(proxy.host),
            port: NWEndpoint.Port(integerLiteral: UInt16(proxy.port))
        )
        let conn = NWConnection(to: proxyEndpoint, using: .tcp)
        self.upstreamConnection = conn

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                switch state {
                case .ready:
                    let noAuthGreeting = Data([0x05, 0x01, 0x00])
                    conn.send(content: noAuthGreeting, completion: .contentProcessed { [weak self] error in
                        Task { @MainActor [weak self] in
                            guard let self, !self.isCancelled else { return }
                            if error != nil { self.errorType = .handshake; self.sendSOCKS5Error(0x01); return }
                            self.readUpstreamGreetingResponse(proxy: proxy, targetHost: targetHost, targetPort: targetPort, addressType: addressType)
                        }
                    })
                case .failed:
                    self.errorType = .connection
                    self.sendSOCKS5Error(0x05)
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)
    }

    private func sendUpstreamConnectRequest(targetHost: String, targetPort: UInt16, addressType: UInt8) {
        guard let upstreamConnection, !isCancelled else { return }

        var request = Data([0x05, 0x01, 0x00, 0x03])
        let hostBytes = Array(targetHost.utf8)
        request.append(UInt8(hostBytes.count))
        request.append(contentsOf: hostBytes)
        request.append(UInt8(targetPort >> 8))
        request.append(UInt8(targetPort & 0xFF))

        upstreamConnection.send(content: request, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.errorType = .handshake; self.sendSOCKS5Error(0x01); return }
                self.readUpstreamConnectResponse(addressType: addressType)
            }
        })
    }

    private func readUpstreamConnectResponse(addressType: UInt8) {
        guard let upstreamConnection, !isCancelled else { return }

        upstreamConnection.receive(minimumIncompleteLength: 4, maximumLength: 512) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.errorType = .handshake; self.sendSOCKS5Error(0x01); return }
                guard let data, data.count >= 4, data[0] == 0x05, data[1] == 0x00 else {
                    let rep = (data != nil && (data?.count ?? 0) >= 2) ? (data?[1] ?? UInt8(0x01)) : UInt8(0x01)
                    self.errorType = .handshake
                    self.sendSOCKS5Error(rep)
                    return
                }
                self.sendSOCKS5Success(addressType: addressType)
            }
        }
    }

    private func sendSOCKS5Success(addressType: UInt8) {
        cancelTimeout()

        let response = Data([0x05, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        clientConnection.send(content: response, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.finish(error: true); return }
                self.server?.updateConnectionInfo(id: self.id, targetHost: self.targetHost, targetPort: self.targetPort, state: .relaying)
                self.startRelaying()
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

    private func startRelaying() {
        relayData(from: clientConnection, to: upstreamConnection, label: "up", isUpload: true)
        relayData(from: upstreamConnection, to: clientConnection, label: "down", isUpload: false)
    }

    private func relayData(from source: NWConnection?, to destination: NWConnection?, label: String, isUpload: Bool) {
        guard let source, let destination, !isCancelled else { return }

        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }

                if let data, !data.isEmpty {
                    let count = UInt64(data.count)
                    self.bytesRelayed += count
                    if isUpload {
                        self.bytesUploaded += count
                    } else {
                        self.bytesDownloaded += count
                    }
                    self.server?.updateConnectionBytes(id: self.id, bytes: self.bytesRelayed)

                    destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                        Task { @MainActor [weak self] in
                            guard let self, !self.isCancelled else { return }
                            if sendError != nil {
                                self.errorType = .relay
                                self.finish(error: true)
                                return
                            }
                            if isComplete {
                                self.handleHalfClose(isUpload: isUpload, destination: destination)
                            } else {
                                self.relayData(from: source, to: destination, label: label, isUpload: isUpload)
                            }
                        }
                    })
                } else if isComplete {
                    self.handleHalfClose(isUpload: isUpload, destination: destination)
                } else if error != nil {
                    self.errorType = .relay
                    self.finish(error: true)
                } else {
                    self.relayData(from: source, to: destination, label: label, isUpload: isUpload)
                }
            }
        }
    }

    private func handleHalfClose(isUpload: Bool, destination: NWConnection) {
        if isUpload {
            clientHalfClosed = true
        } else {
            upstreamHalfClosed = true
        }

        destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if self.clientHalfClosed && self.upstreamHalfClosed {
                    self.finish(error: false)
                }
            }
        })
    }
}
