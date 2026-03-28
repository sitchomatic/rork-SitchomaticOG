import Foundation

// MARK: - Swift 6.2 Zero-Copy IP Packet Primitive

/// A lightweight, register-transferable IP packet header.
///
/// By conforming to `BitwiseCopyable`, the Swift 6.2 compiler moves this struct
/// between actors via CPU registers, avoiding ARC heap allocations entirely.
/// Only fixed-size primitive fields are stored; the raw buffer is processed
/// in-place via `UnsafeRawBufferPointer` at parse time and not retained.
@frozen
public struct IPPacketHeader: Sendable {
    public let version: UInt8
    public let headerLength: UInt8
    public let protocolType: UInt8
    public let totalLength: UInt16
    public let sourceIP: UInt32
    public let destIP: UInt32
    public let ttl: UInt8
    public let checksum: UInt16

    /// Parses an IP packet header directly from a raw kernel buffer.
    /// Uses `@inline(__always)` to eliminate function-call overhead on the hot path.
    @inline(__always)
    public init?(rawBuffer: UnsafeRawBufferPointer) {
        guard rawBuffer.count >= 20 else { return nil }

        let versionIHL = rawBuffer[0]
        self.version = versionIHL >> 4
        self.headerLength = (versionIHL & 0x0F) * 4

        guard self.version == 4, self.headerLength >= 20 else { return nil }

        self.protocolType = rawBuffer[9]
        self.totalLength = UInt16(rawBuffer[2]) << 8 | UInt16(rawBuffer[3])
        self.ttl = rawBuffer[8]
        self.checksum = UInt16(rawBuffer[10]) << 8 | UInt16(rawBuffer[11])

        self.sourceIP = UInt32(rawBuffer[12]) << 24
            | UInt32(rawBuffer[13]) << 16
            | UInt32(rawBuffer[14]) << 8
            | UInt32(rawBuffer[15])

        self.destIP = UInt32(rawBuffer[16]) << 24
            | UInt32(rawBuffer[17]) << 16
            | UInt32(rawBuffer[18]) << 8
            | UInt32(rawBuffer[19])
    }

    /// Human-readable source IP in dotted-decimal notation.
    public var sourceIPString: String {
        "\(sourceIP >> 24 & 0xFF).\(sourceIP >> 16 & 0xFF).\(sourceIP >> 8 & 0xFF).\(sourceIP & 0xFF)"
    }

    /// Human-readable destination IP in dotted-decimal notation.
    public var destIPString: String {
        "\(destIP >> 24 & 0xFF).\(destIP >> 16 & 0xFF).\(destIP >> 8 & 0xFF).\(destIP & 0xFF)"
    }

    /// Protocol name for logging.
    public var protocolName: String {
        switch protocolType {
        case 6: return "TCP"
        case 17: return "UDP"
        case 1: return "ICMP"
        default: return "Unknown(\(protocolType))"
        }
    }
}

// MARK: - Zero-Copy Packet Processing Utilities

/// Processes raw packet data without heap allocation using closure-based access.
/// The buffer is never copied; the closure operates directly on the kernel memory.
@inline(__always)
public func withPacketHeader<R>(
    _ data: Data,
    body: (IPPacketHeader) throws -> R
) rethrows -> R? {
    return try data.withUnsafeBytes { rawBuffer -> R? in
        guard let header = IPPacketHeader(rawBuffer: rawBuffer) else {
            return nil
        }
        return try body(header)
    }
}

/// Extracts the payload portion of a raw IP packet without copying.
/// Returns a `Data` slice pointing into the original buffer.
@inline(__always)
public func extractPayload(from data: Data) -> Data? {
    return data.withUnsafeBytes { rawBuffer -> Data? in
        guard let header = IPPacketHeader(rawBuffer: rawBuffer) else {
            return nil
        }
        let payloadStart = Int(header.headerLength)
        let payloadLength = Int(header.totalLength) - payloadStart
        guard payloadStart <= data.count, payloadStart + payloadLength <= data.count else {
            return nil
        }
        return data[payloadStart ..< payloadStart + payloadLength]
    }
}

/// Validates an IP header checksum in zero-copy fashion.
@inline(__always)
public func validateChecksum(_ data: Data) -> Bool {
    return data.withUnsafeBytes { rawBuffer -> Bool in
        guard rawBuffer.count >= 20 else { return false }
        let ihl = Int(rawBuffer[0] & 0x0F) * 4
        guard ihl >= 20, ihl <= rawBuffer.count else { return false }

        var sum: UInt32 = 0
        for i in stride(from: 0, to: ihl, by: 2) {
            let word = UInt32(rawBuffer[i]) << 8 | UInt32(rawBuffer[i + 1])
            sum += word
        }
        // Fold 32-bit sum into 16-bit
        while sum > 0xFFFF {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return UInt16(~sum & 0xFFFF) == 0
    }
}
