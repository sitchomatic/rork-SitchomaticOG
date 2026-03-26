import Foundation
import Network
import CryptoKit
import Observation

nonisolated enum WGMessageType: UInt8, Sendable {
    case handshakeInitiation = 1
    case handshakeResponse = 2
    case cookieReply = 3
    case transportData = 4
}

nonisolated struct WGTransportPacket: Sendable {
    let receiverIndex: UInt32
    let counter: UInt64
    let encryptedPayload: Data

    func serialize() -> Data {
        var data = Data(capacity: 16 + encryptedPayload.count)
        data.append(0x04)
        data.append(contentsOf: [0x00, 0x00, 0x00])
        appendLE32(&data, receiverIndex)
        appendLE64(&data, counter)
        data.append(encryptedPayload)
        return data
    }

    static func parse(_ data: Data) -> WGTransportPacket? {
        guard data.count >= 16, data[0] == 0x04 else { return nil }
        let recvIdx = readLE32(data, offset: 4)
        let ctr = readLE64(data, offset: 8)
        let payload = data.count > 16 ? Data(data[16...]) : Data()
        return WGTransportPacket(receiverIndex: recvIdx, counter: ctr, encryptedPayload: payload)
    }

    private func appendLE32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private func appendLE64(_ data: inout Data, _ value: UInt64) {
        for i in 0..<8 {
            data.append(UInt8((value >> (i * 8)) & 0xFF))
        }
    }

    private static func readLE32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) |
        (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) |
        (UInt32(data[offset + 3]) << 24)
    }

    private static func readLE64(_ data: Data, offset: Int) -> UInt64 {
        var result: UInt64 = 0
        for i in 0..<8 {
            result |= UInt64(data[offset + i]) << (i * 8)
        }
        return result
    }
}

nonisolated enum WGSessionStatus: String, Sendable {
    case idle = "Idle"
    case handshaking = "Handshaking"
    case established = "Established"
    case rekeying = "Rekeying"
    case failed = "Failed"
}

nonisolated struct WGSessionStats: Sendable {
    var packetsSent: UInt64 = 0
    var packetsReceived: UInt64 = 0
    var bytesSent: UInt64 = 0
    var bytesReceived: UInt64 = 0
    var handshakeCount: Int = 0
    var lastHandshakeTime: Date?
    var lastPacketSentTime: Date?
    var lastPacketReceivedTime: Date?
}

@Observable
@MainActor
class WireGuardSession {
    private(set) var status: WGSessionStatus = .idle
    private(set) var sessionKeys: SessionKeys?
    private(set) var stats: WGSessionStats = WGSessionStats()
    private(set) var lastError: String?

    private var handshakeState: HandshakeState?
    private var udpConnection: NWConnection?
    private var keepaliveTimer: Timer?
    private var rekeyTimer: Timer?
    private let queue = DispatchQueue(label: "wg-session", qos: .userInitiated)
    private let logger = DebugLogger.shared

    var onPacketReceived: ((Data) -> Void)?

    private var staticPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var peerPublicKey: Curve25519.KeyAgreement.PublicKey?
    private var preSharedKey: Data?
    private var endpointHost: String = ""
    private var endpointPort: UInt16 = 0
    private var persistentKeepalive: Int = 0

    func configure(
        privateKey: String,
        peerPublicKey peerPubKey: String,
        preSharedKey psk: String?,
        endpoint: String,
        keepalive: Int
    ) -> Bool {
        let trimmedPriv = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPub = peerPubKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedPriv.isEmpty else {
            lastError = "Private key is empty"
            logger.log("WGSession: private key is empty", category: .vpn, level: .error)
            return false
        }

        guard Data(base64Encoded: trimmedPriv) != nil else {
            lastError = "Private key is not valid base64 (length: \(trimmedPriv.count))"
            logger.log("WGSession: private key base64 decode failed (\(trimmedPriv.count) chars)", category: .vpn, level: .error)
            return false
        }

        guard let privKey = WireGuardCrypto.privateKey(from: trimmedPriv) else {
            lastError = "Private key invalid Curve25519 key (decoded \(Data(base64Encoded: trimmedPriv)?.count ?? 0) bytes, need 32)"
            logger.log("WGSession: private key Curve25519 init failed - decoded \(Data(base64Encoded: trimmedPriv)?.count ?? 0) bytes", category: .vpn, level: .error)
            return false
        }

        guard !trimmedPub.isEmpty else {
            lastError = "Peer public key is empty"
            logger.log("WGSession: peer public key is empty", category: .vpn, level: .error)
            return false
        }

        guard let pubKey = WireGuardCrypto.peerPublicKey(from: trimmedPub) else {
            lastError = "Peer public key invalid (length: \(trimmedPub.count), decoded: \(Data(base64Encoded: trimmedPub)?.count ?? 0) bytes)"
            logger.log("WGSession: peer public key Curve25519 init failed", category: .vpn, level: .error)
            return false
        }

        staticPrivateKey = privKey
        peerPublicKey = pubKey

        if let psk, !psk.isEmpty {
            let trimmedPSK = psk.trimmingCharacters(in: .whitespacesAndNewlines)
            if let pskData = Data(base64Encoded: trimmedPSK), pskData.count == 32 {
                preSharedKey = pskData
            } else {
                logger.log("WGSession: preshared key decode failed or wrong size, ignoring", category: .vpn, level: .warning)
                preSharedKey = nil
            }
        }

        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmedEndpoint.split(separator: ":")
        guard parts.count >= 2, let lastPart = parts.last, let port = UInt16(lastPart) else {
            lastError = "Invalid endpoint format: \(endpoint)"
            logger.log("WGSession: invalid endpoint format '\(endpoint)'", category: .vpn, level: .error)
            return false
        }
        endpointHost = parts.dropLast().joined(separator: ":")
        endpointPort = port
        persistentKeepalive = keepalive

        logger.log("WGSession: configured for \(endpointHost):\(endpointPort)", category: .vpn, level: .info)
        return true
    }

    func connect() async {
        guard let staticPrivateKey, let peerPublicKey else {
            lastError = "Not configured"
            status = .failed
            return
        }

        status = .handshaking

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(endpointHost),
            port: NWEndpoint.Port(integerLiteral: endpointPort)
        )
        let conn = NWConnection(to: endpoint, using: .udp)
        udpConnection = conn

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.performHandshake(staticPrivateKey: staticPrivateKey, peerPublicKey: peerPublicKey)
                case .failed(let error):
                    self.status = .failed
                    self.lastError = "UDP connection failed: \(error.localizedDescription)"
                    self.logger.log("WGSession: UDP failed - \(error)", category: .vpn, level: .error)
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)
    }

    func disconnect() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        rekeyTimer?.invalidate()
        rekeyTimer = nil
        udpConnection?.cancel()
        udpConnection = nil
        sessionKeys = nil
        handshakeState = nil
        status = .idle
        logger.log("WGSession: disconnected", category: .vpn, level: .info)
    }

    func sendPacket(_ ipPacket: Data) {
        guard var keys = sessionKeys, status == .established else { return }

        let counter = keys.sendingNonce
        keys.sendingNonce += 1
        sessionKeys = keys

        guard let encrypted = WireGuardCrypto.aead(
            key: keys.sendingKey,
            counter: counter,
            plaintext: ipPacket,
            aad: Data()
        ) else {
            logger.log("WGSession: encrypt failed", category: .vpn, level: .error)
            return
        }

        let packet = WGTransportPacket(
            receiverIndex: keys.receiverIndex,
            counter: counter,
            encryptedPayload: encrypted
        )

        udpConnection?.send(content: packet.serialize(), completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.logger.log("WGSession: send failed - \(error)", category: .vpn, level: .error)
                } else {
                    self.stats.packetsSent += 1
                    self.stats.bytesSent += UInt64(ipPacket.count)
                    self.stats.lastPacketSentTime = Date()
                }
            }
        })
    }

    private func performHandshake(staticPrivateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Curve25519.KeyAgreement.PublicKey) {
        guard let result = NoiseHandshake.buildInitiation(
            staticPrivateKey: staticPrivateKey,
            peerPublicKey: peerPublicKey,
            preSharedKey: preSharedKey
        ) else {
            status = .failed
            lastError = "Failed to build handshake initiation"
            logger.log("WGSession: handshake build failed", category: .vpn, level: .error)
            return
        }

        handshakeState = result.state
        let initiationData = NoiseHandshake.serializeInitiation(result.initiation)

        udpConnection?.send(content: initiationData, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.status = .failed
                    self.lastError = "Handshake send failed: \(error.localizedDescription)"
                    return
                }
                self.logger.log("WGSession: handshake initiation sent (\(initiationData.count) bytes)", category: .vpn, level: .info)
                self.receiveHandshakeResponse()
            }
        })
    }

    private func receiveHandshakeResponse() {
        udpConnection?.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    self.status = .failed
                    self.lastError = "Handshake receive failed: \(error.localizedDescription)"
                    return
                }

                guard let data else {
                    self.status = .failed
                    self.lastError = "No handshake response data"
                    return
                }

                guard let state = self.handshakeState else {
                    self.status = .failed
                    self.lastError = "No handshake state"
                    return
                }

                if data.count >= 1 && data[0] == WGMessageType.cookieReply.rawValue {
                    self.logger.log("WGSession: received cookie reply, retry needed", category: .vpn, level: .warning)
                    self.status = .failed
                    self.lastError = "Server sent cookie reply (rate limited)"
                    return
                }

                guard let keys = NoiseHandshake.parseResponse(responseData: data, state: state) else {
                    self.status = .failed
                    self.lastError = "Failed to parse handshake response"
                    self.logger.log("WGSession: handshake response parse failed (\(data.count) bytes, type: \(data[0]))", category: .vpn, level: .error)
                    return
                }

                self.sessionKeys = keys
                self.handshakeState = nil
                self.status = .established
                self.stats.handshakeCount += 1
                self.stats.lastHandshakeTime = Date()
                self.logger.log("WGSession: ESTABLISHED (sender: \(keys.senderIndex), receiver: \(keys.receiverIndex))", category: .vpn, level: .success)

                self.startKeepalive()
                self.startRekeyTimer()
                self.startReceiving()

                self.sendKeepalive()
            }
        }
    }

    private func startReceiving() {
        guard status == .established else { return }

        udpConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, self.status == .established else { return }

                if let data, !data.isEmpty {
                    self.handleIncomingPacket(data)
                }

                if error == nil {
                    self.startReceiving()
                }
            }
        }
    }

    private func handleIncomingPacket(_ data: Data) {
        guard data.count >= 16, data[0] == WGMessageType.transportData.rawValue else { return }

        guard let packet = WGTransportPacket.parse(data) else { return }
        guard var keys = sessionKeys else { return }

        guard let decrypted = WireGuardCrypto.aeadDecrypt(
            key: keys.receivingKey,
            counter: packet.counter,
            ciphertext: packet.encryptedPayload,
            aad: Data()
        ) else {
            logger.log("WGSession: decrypt failed (counter: \(packet.counter))", category: .vpn, level: .warning)
            return
        }

        if packet.counter > keys.receivingNonce {
            keys.receivingNonce = packet.counter
            sessionKeys = keys
        }

        stats.packetsReceived += 1
        stats.bytesReceived += UInt64(decrypted.count)
        stats.lastPacketReceivedTime = Date()

        if !decrypted.isEmpty {
            onPacketReceived?(decrypted)
        }
    }

    private func sendKeepalive() {
        guard status == .established else { return }
        sendPacket(Data())
    }

    private func startKeepalive() {
        keepaliveTimer?.invalidate()
        guard persistentKeepalive > 0 else { return }

        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(persistentKeepalive), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sendKeepalive()
            }
        }
    }

    private func startRekeyTimer() {
        rekeyTimer?.invalidate()
        rekeyTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.status == .established else { return }
                self.logger.log("WGSession: rekey timer fired, initiating new handshake", category: .vpn, level: .info)
                self.status = .rekeying
                if let privKey = self.staticPrivateKey, let pubKey = self.peerPublicKey {
                    self.performHandshake(staticPrivateKey: privKey, peerPublicKey: pubKey)
                }
            }
        }
    }

    var isEstablished: Bool { status == .established }

    var uptimeSeconds: TimeInterval {
        guard let lastHandshake = stats.lastHandshakeTime else { return 0 }
        return Date().timeIntervalSince(lastHandshake)
    }
}
