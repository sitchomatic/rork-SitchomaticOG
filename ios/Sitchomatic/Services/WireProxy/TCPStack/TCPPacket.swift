import Foundation

nonisolated struct TCPFlags: OptionSet, Sendable {
    let rawValue: UInt8

    static let fin = TCPFlags(rawValue: 0x01)
    static let syn = TCPFlags(rawValue: 0x02)
    static let rst = TCPFlags(rawValue: 0x04)
    static let psh = TCPFlags(rawValue: 0x08)
    static let ack = TCPFlags(rawValue: 0x10)
    static let urg = TCPFlags(rawValue: 0x20)

    var description: String {
        var parts: [String] = []
        if contains(.syn) { parts.append("SYN") }
        if contains(.ack) { parts.append("ACK") }
        if contains(.fin) { parts.append("FIN") }
        if contains(.rst) { parts.append("RST") }
        if contains(.psh) { parts.append("PSH") }
        if contains(.urg) { parts.append("URG") }
        return parts.joined(separator: "|")
    }
}

nonisolated struct TCPHeader: Sendable {
    let sourcePort: UInt16
    let destinationPort: UInt16
    let sequenceNumber: UInt32
    let acknowledgmentNumber: UInt32
    let dataOffset: UInt8
    let flags: TCPFlags
    let windowSize: UInt16
    let checksum: UInt16
    let urgentPointer: UInt16

    var headerLength: Int { Int(dataOffset) * 4 }
}

nonisolated struct TCPSegment: Sendable {
    let header: TCPHeader
    let payload: Data

    static func parse(_ data: Data) -> TCPSegment? {
        guard data.count >= 20 else { return nil }

        let dataOffset = data[12] >> 4
        let headerLen = Int(dataOffset) * 4
        guard headerLen >= 20, data.count >= headerLen else { return nil }

        let flagsByte = data[13]

        let header = TCPHeader(
            sourcePort: readBE16(data, offset: 0),
            destinationPort: readBE16(data, offset: 2),
            sequenceNumber: readBE32(data, offset: 4),
            acknowledgmentNumber: readBE32(data, offset: 8),
            dataOffset: dataOffset,
            flags: TCPFlags(rawValue: flagsByte & 0x3F),
            windowSize: readBE16(data, offset: 14),
            checksum: readBE16(data, offset: 16),
            urgentPointer: readBE16(data, offset: 18)
        )

        let payload = data.count > headerLen ? Data(data[headerLen...]) : Data()
        return TCPSegment(header: header, payload: payload)
    }

    static func build(
        sourcePort: UInt16,
        destinationPort: UInt16,
        sequenceNumber: UInt32,
        acknowledgmentNumber: UInt32,
        flags: TCPFlags,
        windowSize: UInt16 = 65535,
        payload: Data = Data(),
        sourceIP: UInt32,
        destinationIP: UInt32
    ) -> Data {
        let dataOffset: UInt8 = 5
        let headerLen = Int(dataOffset) * 4

        var segment = Data(capacity: headerLen + payload.count)

        appendBE16(&segment, sourcePort)
        appendBE16(&segment, destinationPort)
        appendBE32(&segment, sequenceNumber)
        appendBE32(&segment, acknowledgmentNumber)
        segment.append(dataOffset << 4)
        segment.append(flags.rawValue)
        appendBE16(&segment, windowSize)
        appendBE16(&segment, 0)
        appendBE16(&segment, 0)

        segment.append(payload)

        let checksum = tcpChecksum(
            segment: segment,
            sourceIP: sourceIP,
            destinationIP: destinationIP
        )
        segment[16] = UInt8(checksum >> 8)
        segment[17] = UInt8(checksum & 0xFF)

        return segment
    }

    static func tcpChecksum(segment: Data, sourceIP: UInt32, destinationIP: UInt32) -> UInt16 {
        var pseudoHeader = Data(capacity: 12 + segment.count)

        appendBE32(&pseudoHeader, sourceIP)
        appendBE32(&pseudoHeader, destinationIP)
        pseudoHeader.append(0)
        pseudoHeader.append(6)
        appendBE16(&pseudoHeader, UInt16(segment.count))

        pseudoHeader.append(segment)

        return IPv4Packet.ipChecksum(pseudoHeader)
    }
}
