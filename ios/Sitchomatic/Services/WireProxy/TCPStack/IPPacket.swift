import Foundation

nonisolated struct IPv4Header: Sendable {
    let version: UInt8
    let ihl: UInt8
    let dscp: UInt8
    let totalLength: UInt16
    let identification: UInt16
    let flags: UInt8
    let fragmentOffset: UInt16
    let ttl: UInt8
    let protocolNumber: UInt8
    let headerChecksum: UInt16
    let sourceAddress: UInt32
    let destinationAddress: UInt32

    var headerLength: Int { Int(ihl) * 4 }

    var sourceIP: String {
        "\((sourceAddress >> 24) & 0xFF).\((sourceAddress >> 16) & 0xFF).\((sourceAddress >> 8) & 0xFF).\(sourceAddress & 0xFF)"
    }

    var destinationIP: String {
        "\((destinationAddress >> 24) & 0xFF).\((destinationAddress >> 16) & 0xFF).\((destinationAddress >> 8) & 0xFF).\(destinationAddress & 0xFF)"
    }

    var isTCP: Bool { protocolNumber == 6 }
    var isUDP: Bool { protocolNumber == 17 }
}

nonisolated struct IPv4Packet: Sendable {
    let header: IPv4Header
    let payload: Data

    static func parse(_ data: Data) -> IPv4Packet? {
        guard data.count >= 20 else { return nil }

        let versionIHL = data[0]
        let version = versionIHL >> 4
        guard version == 4 else { return nil }

        let ihl = versionIHL & 0x0F
        let headerLen = Int(ihl) * 4
        guard headerLen >= 20, data.count >= headerLen else { return nil }

        let totalLength = readBE16(data, offset: 2)
        guard data.count >= Int(totalLength) else { return nil }

        let header = IPv4Header(
            version: version,
            ihl: ihl,
            dscp: data[1],
            totalLength: totalLength,
            identification: readBE16(data, offset: 4),
            flags: data[6] >> 5,
            fragmentOffset: readBE16(data, offset: 6) & 0x1FFF,
            ttl: data[8],
            protocolNumber: data[9],
            headerChecksum: readBE16(data, offset: 10),
            sourceAddress: readBE32(data, offset: 12),
            destinationAddress: readBE32(data, offset: 16)
        )

        let payloadStart = headerLen
        let payloadEnd = Int(totalLength)
        let payload = payloadEnd > payloadStart ? Data(data[payloadStart..<payloadEnd]) : Data()

        return IPv4Packet(header: header, payload: payload)
    }

    static func build(
        sourceAddress: UInt32,
        destinationAddress: UInt32,
        protocolNumber: UInt8,
        payload: Data,
        identification: UInt16 = UInt16.random(in: 0...UInt16.max),
        ttl: UInt8 = 64,
        dontFragment: Bool = true
    ) -> Data {
        let headerLength: UInt8 = 5
        let totalLength = UInt16(headerLength) * 4 + UInt16(payload.count)
        let flags: UInt8 = dontFragment ? 0x02 : 0x00

        var packet = Data(capacity: Int(totalLength))

        packet.append((4 << 4) | headerLength)
        packet.append(0x00)
        appendBE16(&packet, totalLength)
        appendBE16(&packet, identification)
        let flagsFragment = UInt16(flags) << 13
        appendBE16(&packet, flagsFragment)
        packet.append(ttl)
        packet.append(protocolNumber)
        appendBE16(&packet, 0)
        appendBE32(&packet, sourceAddress)
        appendBE32(&packet, destinationAddress)

        let checksum = ipChecksum(Data(packet[0..<20]))
        packet[10] = UInt8(checksum >> 8)
        packet[11] = UInt8(checksum & 0xFF)

        packet.append(payload)
        return packet
    }

    static func ipFromString(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        guard let a = UInt32(parts[0]), let b = UInt32(parts[1]),
              let c = UInt32(parts[2]), let d = UInt32(parts[3]) else { return nil }
        guard a <= 255, b <= 255, c <= 255, d <= 255 else { return nil }
        return (a << 24) | (b << 16) | (c << 8) | d
    }

    static func ipChecksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i < data.count - 1 {
            sum += UInt32(data[i]) << 8 | UInt32(data[i + 1])
            i += 2
        }
        if data.count % 2 != 0 {
            sum += UInt32(data[data.count - 1]) << 8
        }
        while sum > 0xFFFF {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum)
    }
}

nonisolated func readBE16(_ data: Data, offset: Int) -> UInt16 {
    UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
}

nonisolated func readBE32(_ data: Data, offset: Int) -> UInt32 {
    UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 |
    UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
}

nonisolated func appendBE16(_ data: inout Data, _ value: UInt16) {
    data.append(UInt8(value >> 8))
    data.append(UInt8(value & 0xFF))
}

nonisolated func appendBE32(_ data: inout Data, _ value: UInt32) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}
