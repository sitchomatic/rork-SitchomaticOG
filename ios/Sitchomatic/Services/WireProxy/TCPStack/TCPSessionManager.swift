import Foundation

nonisolated enum TCPSessionState: String, Sendable {
    case closed
    case synSent
    case established
    case finWait1
    case finWait2
    case closeWait
    case lastAck
    case timeWait
}

nonisolated struct TCPSessionKey: Hashable, Sendable {
    let sourceIP: UInt32
    let sourcePort: UInt16
    let destinationIP: UInt32
    let destinationPort: UInt16
}

@MainActor
class TCPSession {
    let key: TCPSessionKey
    var state: TCPSessionState = .closed
    var localSeq: UInt32
    var localAck: UInt32 = 0
    var remoteWindowSize: UInt16 = 65535
    var sendBuffer: Data = Data()
    var receiveBuffer: Data = Data()
    var createdAt: Date = Date()
    var lastActivityAt: Date = Date()
    var onDataReceived: ((Data) -> Void)?
    var onConnectionEstablished: (() -> Void)?
    var onConnectionClosed: (() -> Void)?
    var onError: ((String) -> Void)?
    private var retransmitCount: Int = 0
    private let maxRetransmits: Int = 5

    init(key: TCPSessionKey) {
        self.key = key
        self.localSeq = UInt32.random(in: 1000...UInt32.max - 100000)
    }

    var isActive: Bool {
        state != .closed && state != .timeWait
    }

    var ageSeconds: TimeInterval {
        Date().timeIntervalSince(createdAt)
    }

    var idleSeconds: TimeInterval {
        Date().timeIntervalSince(lastActivityAt)
    }

    func touch() {
        lastActivityAt = Date()
    }

    func incrementRetransmit() -> Bool {
        retransmitCount += 1
        return retransmitCount <= maxRetransmits
    }

    func resetRetransmit() {
        retransmitCount = 0
    }
}

@MainActor
class TCPSessionManager {
    private var sessions: [TCPSessionKey: TCPSession] = [:]
    private let logger = DebugLogger.shared
    private var cleanupTimer: Timer?
    var sendPacketHandler: ((Data) -> Void)?

    private var localIP: UInt32 = 0
    private var nextLocalPort: UInt16 = 30000

    func configure(localIP: UInt32) {
        self.localIP = localIP
        startCleanupTimer()
    }

    func shutdown() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        for session in sessions.values {
            session.state = .closed
            session.onConnectionClosed?()
        }
        sessions.removeAll()
    }

    func createSession(
        destinationIP: UInt32,
        destinationPort: UInt16
    ) -> TCPSession {
        let localPort = allocatePort()
        let key = TCPSessionKey(
            sourceIP: localIP,
            sourcePort: localPort,
            destinationIP: destinationIP,
            destinationPort: destinationPort
        )
        let session = TCPSession(key: key)
        sessions[key] = session
        logger.log("TCPSession: created \(formatKey(key))", category: .vpn, level: .debug)
        return session
    }

    func initiateConnection(_ session: TCPSession) {
        guard session.state == .closed else { return }

        session.state = .synSent
        session.touch()

        let synSegment = TCPSegment.build(
            sourcePort: session.key.sourcePort,
            destinationPort: session.key.destinationPort,
            sequenceNumber: session.localSeq,
            acknowledgmentNumber: 0,
            flags: .syn,
            windowSize: 65535,
            sourceIP: session.key.sourceIP,
            destinationIP: session.key.destinationIP
        )

        let ipPacket = IPv4Packet.build(
            sourceAddress: session.key.sourceIP,
            destinationAddress: session.key.destinationIP,
            protocolNumber: 6,
            payload: synSegment
        )

        session.localSeq = session.localSeq &+ 1
        sendPacketHandler?(ipPacket)
        logger.log("TCPSession: SYN sent \(formatKey(session.key))", category: .vpn, level: .debug)
    }

    func sendData(_ session: TCPSession, data: Data) {
        guard session.state == .established else { return }
        session.touch()

        let mss = 1360
        var offset = 0

        while offset < data.count {
            let chunkEnd = min(offset + mss, data.count)
            let chunk = Data(data[offset..<chunkEnd])

            let segment = TCPSegment.build(
                sourcePort: session.key.sourcePort,
                destinationPort: session.key.destinationPort,
                sequenceNumber: session.localSeq,
                acknowledgmentNumber: session.localAck,
                flags: [.ack, .psh],
                windowSize: 65535,
                payload: chunk,
                sourceIP: session.key.sourceIP,
                destinationIP: session.key.destinationIP
            )

            let ipPacket = IPv4Packet.build(
                sourceAddress: session.key.sourceIP,
                destinationAddress: session.key.destinationIP,
                protocolNumber: 6,
                payload: segment
            )

            session.localSeq = session.localSeq &+ UInt32(chunk.count)
            sendPacketHandler?(ipPacket)
            offset = chunkEnd
        }
    }

    func closeSession(_ session: TCPSession) {
        guard session.state == .established || session.state == .closeWait else { return }
        session.touch()

        let newState: TCPSessionState = session.state == .closeWait ? .lastAck : .finWait1
        session.state = newState

        let finSegment = TCPSegment.build(
            sourcePort: session.key.sourcePort,
            destinationPort: session.key.destinationPort,
            sequenceNumber: session.localSeq,
            acknowledgmentNumber: session.localAck,
            flags: [.fin, .ack],
            windowSize: 65535,
            sourceIP: session.key.sourceIP,
            destinationIP: session.key.destinationIP
        )

        let ipPacket = IPv4Packet.build(
            sourceAddress: session.key.sourceIP,
            destinationAddress: session.key.destinationIP,
            protocolNumber: 6,
            payload: finSegment
        )

        session.localSeq = session.localSeq &+ 1
        sendPacketHandler?(ipPacket)
        logger.log("TCPSession: FIN sent \(formatKey(session.key)) -> \(newState.rawValue)", category: .vpn, level: .debug)
    }

    func sendReset(_ session: TCPSession) {
        let rstSegment = TCPSegment.build(
            sourcePort: session.key.sourcePort,
            destinationPort: session.key.destinationPort,
            sequenceNumber: session.localSeq,
            acknowledgmentNumber: session.localAck,
            flags: [.rst, .ack],
            windowSize: 0,
            sourceIP: session.key.sourceIP,
            destinationIP: session.key.destinationIP
        )

        let ipPacket = IPv4Packet.build(
            sourceAddress: session.key.sourceIP,
            destinationAddress: session.key.destinationIP,
            protocolNumber: 6,
            payload: rstSegment
        )

        sendPacketHandler?(ipPacket)
        session.state = .closed
        session.onConnectionClosed?()
        sessions.removeValue(forKey: session.key)
    }

    func handleIncomingPacket(_ ipData: Data) {
        guard let ipPacket = IPv4Packet.parse(ipData) else { return }
        guard ipPacket.header.isTCP else {
            return
        }
        guard let tcp = TCPSegment.parse(ipPacket.payload) else { return }

        let incomingKey = TCPSessionKey(
            sourceIP: ipPacket.header.destinationAddress,
            sourcePort: tcp.header.destinationPort,
            destinationIP: ipPacket.header.sourceAddress,
            destinationPort: tcp.header.sourcePort
        )

        guard let session = sessions[incomingKey] else {
            return
        }

        session.touch()
        session.remoteWindowSize = tcp.header.windowSize

        if tcp.header.flags.contains(.rst) {
            logger.log("TCPSession: RST received \(formatKey(incomingKey))", category: .vpn, level: .warning)
            session.state = .closed
            session.onError?("Connection reset by peer")
            session.onConnectionClosed?()
            sessions.removeValue(forKey: incomingKey)
            return
        }

        switch session.state {
        case .synSent:
            handleSynSentResponse(session: session, tcp: tcp)
        case .established:
            handleEstablishedData(session: session, tcp: tcp, ipHeader: ipPacket.header)
        case .finWait1:
            handleFinWait1Response(session: session, tcp: tcp)
        case .finWait2:
            handleFinWait2Response(session: session, tcp: tcp)
        case .lastAck:
            handleLastAckResponse(session: session, tcp: tcp)
        case .closeWait:
            break
        default:
            break
        }
    }

    private func handleSynSentResponse(session: TCPSession, tcp: TCPSegment) {
        guard tcp.header.flags.contains(.syn), tcp.header.flags.contains(.ack) else {
            if tcp.header.flags.contains(.syn) {
                session.localAck = tcp.header.sequenceNumber &+ 1
                sendAck(session)
                return
            }
            return
        }

        session.localAck = tcp.header.sequenceNumber &+ 1
        session.state = .established
        session.resetRetransmit()

        sendAck(session)

        logger.log("TCPSession: ESTABLISHED \(formatKey(session.key))", category: .vpn, level: .info)
        session.onConnectionEstablished?()
    }

    private func handleEstablishedData(session: TCPSession, tcp: TCPSegment, ipHeader: IPv4Header) {
        if tcp.header.flags.contains(.fin) {
            session.localAck = tcp.header.sequenceNumber &+ UInt32(tcp.payload.count) &+ 1
            session.state = .closeWait
            sendAck(session)

            if !tcp.payload.isEmpty {
                session.onDataReceived?(tcp.payload)
            }

            session.state = .lastAck
            let finSegment = TCPSegment.build(
                sourcePort: session.key.sourcePort,
                destinationPort: session.key.destinationPort,
                sequenceNumber: session.localSeq,
                acknowledgmentNumber: session.localAck,
                flags: [.fin, .ack],
                windowSize: 65535,
                sourceIP: session.key.sourceIP,
                destinationIP: session.key.destinationIP
            )
            let ipPacket = IPv4Packet.build(
                sourceAddress: session.key.sourceIP,
                destinationAddress: session.key.destinationIP,
                protocolNumber: 6,
                payload: finSegment
            )
            session.localSeq = session.localSeq &+ 1
            sendPacketHandler?(ipPacket)
            return
        }

        if !tcp.payload.isEmpty {
            session.localAck = tcp.header.sequenceNumber &+ UInt32(tcp.payload.count)
            sendAck(session)
            session.onDataReceived?(tcp.payload)
        } else if tcp.header.flags.contains(.ack) {
            session.resetRetransmit()
        }
    }

    private func handleFinWait1Response(session: TCPSession, tcp: TCPSegment) {
        if tcp.header.flags.contains(.fin), tcp.header.flags.contains(.ack) {
            session.localAck = tcp.header.sequenceNumber &+ 1
            session.state = .timeWait
            sendAck(session)
            scheduleTimeWaitCleanup(session)
            session.onConnectionClosed?()
        } else if tcp.header.flags.contains(.ack) {
            session.state = .finWait2
        } else if tcp.header.flags.contains(.fin) {
            session.localAck = tcp.header.sequenceNumber &+ 1
            session.state = .timeWait
            sendAck(session)
            scheduleTimeWaitCleanup(session)
            session.onConnectionClosed?()
        }
    }

    private func handleFinWait2Response(session: TCPSession, tcp: TCPSegment) {
        if tcp.header.flags.contains(.fin) {
            session.localAck = tcp.header.sequenceNumber &+ 1
            session.state = .timeWait
            sendAck(session)
            scheduleTimeWaitCleanup(session)
            session.onConnectionClosed?()
        }
    }

    private func handleLastAckResponse(session: TCPSession, tcp: TCPSegment) {
        if tcp.header.flags.contains(.ack) {
            session.state = .closed
            session.onConnectionClosed?()
            sessions.removeValue(forKey: session.key)
            logger.log("TCPSession: CLOSED \(formatKey(session.key))", category: .vpn, level: .debug)
        }
    }

    private func sendAck(_ session: TCPSession) {
        let ackSegment = TCPSegment.build(
            sourcePort: session.key.sourcePort,
            destinationPort: session.key.destinationPort,
            sequenceNumber: session.localSeq,
            acknowledgmentNumber: session.localAck,
            flags: .ack,
            windowSize: 65535,
            sourceIP: session.key.sourceIP,
            destinationIP: session.key.destinationIP
        )

        let ipPacket = IPv4Packet.build(
            sourceAddress: session.key.sourceIP,
            destinationAddress: session.key.destinationIP,
            protocolNumber: 6,
            payload: ackSegment
        )

        sendPacketHandler?(ipPacket)
    }

    private func scheduleTimeWaitCleanup(_ session: TCPSession) {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sessions.removeValue(forKey: session.key)
            }
        }
    }

    private func allocatePort() -> UInt16 {
        let port = nextLocalPort
        nextLocalPort = nextLocalPort < 60000 ? nextLocalPort + 1 : 30000
        while sessions.keys.contains(where: { $0.sourcePort == nextLocalPort }) {
            nextLocalPort = nextLocalPort < 60000 ? nextLocalPort + 1 : 30000
        }
        return port
    }

    private func startCleanupTimer() {
        cleanupTimer?.invalidate()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cleanupStaleSessions()
            }
        }
    }

    private func cleanupStaleSessions() {
        let staleKeys = sessions.filter { $0.value.idleSeconds > 120 || ($0.value.state == .timeWait && $0.value.idleSeconds > 5) }.map { $0.key }
        for key in staleKeys {
            if let session = sessions[key] {
                if session.isActive {
                    sendReset(session)
                } else {
                    sessions.removeValue(forKey: key)
                }
            }
        }
        if !staleKeys.isEmpty {
            logger.log("TCPSession: cleaned up \(staleKeys.count) stale sessions (\(sessions.count) remaining)", category: .vpn, level: .debug)
        }
    }

    var activeSessionCount: Int { sessions.filter { $0.value.isActive }.count }
    var totalSessionCount: Int { sessions.count }

    private func formatKey(_ key: TCPSessionKey) -> String {
        let srcIP = "\((key.sourceIP >> 24) & 0xFF).\((key.sourceIP >> 16) & 0xFF).\((key.sourceIP >> 8) & 0xFF).\(key.sourceIP & 0xFF)"
        let dstIP = "\((key.destinationIP >> 24) & 0xFF).\((key.destinationIP >> 16) & 0xFF).\((key.destinationIP >> 8) & 0xFF).\(key.destinationIP & 0xFF)"
        return "\(srcIP):\(key.sourcePort) → \(dstIP):\(key.destinationPort)"
    }
}
