import Foundation
import CryptoKit

nonisolated struct HandshakeInitiation: Sendable {
    let senderIndex: UInt32
    let ephemeralPublic: Data
    let encryptedStatic: Data
    let encryptedTimestamp: Data
    let mac1: Data
    let mac2: Data
}

nonisolated struct HandshakeResponse: Sendable {
    let senderIndex: UInt32
    let receiverIndex: UInt32
    let ephemeralPublic: Data
    let encryptedNothing: Data
    let mac1: Data
    let mac2: Data
}

nonisolated struct SessionKeys: Sendable {
    let senderIndex: UInt32
    let receiverIndex: UInt32
    let sendingKey: Data
    let receivingKey: Data
    var sendingNonce: UInt64 = 0
    var receivingNonce: UInt64 = 0
    let createdAt: Date = Date()
}

nonisolated struct NoiseHandshake: Sendable {

    static func buildInitiation(
        staticPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Curve25519.KeyAgreement.PublicKey,
        preSharedKey: Data?
    ) -> (initiation: HandshakeInitiation, state: HandshakeState)? {
        let senderIndex = UInt32.random(in: 0...UInt32.max)
        let ephemeral = WireGuardCrypto.generateEphemeralKeyPair()

        var chainingKey = WireGuardCrypto.initialChainingKey
        var hash = WireGuardCrypto.initialHash

        hash = WireGuardCrypto.mixHash(hash, peerPublicKey.rawRepresentation)

        let ephemeralPub = ephemeral.publicKey.rawRepresentation
        chainingKey = WireGuardCrypto.kdf1(key: chainingKey, input: ephemeralPub)
        hash = WireGuardCrypto.mixHash(hash, ephemeralPub)

        guard let sharedEphPeer = WireGuardCrypto.dh(privateKey: ephemeral, publicKey: peerPublicKey) else { return nil }
        let (ck1, key1) = WireGuardCrypto.kdf2(key: chainingKey, input: sharedEphPeer)
        chainingKey = ck1

        let myStaticPub = staticPrivateKey.publicKey.rawRepresentation
        guard let encStatic = WireGuardCrypto.aead(key: key1, counter: 0, plaintext: myStaticPub, aad: hash) else { return nil }
        hash = WireGuardCrypto.mixHash(hash, encStatic)

        guard let sharedStaticPeer = WireGuardCrypto.dh(privateKey: staticPrivateKey, publicKey: peerPublicKey) else { return nil }
        let (ck2, key2) = WireGuardCrypto.kdf2(key: chainingKey, input: sharedStaticPeer)
        chainingKey = ck2

        let timestamp = WireGuardCrypto.tai64n()
        guard let encTimestamp = WireGuardCrypto.aead(key: key2, counter: 0, plaintext: timestamp, aad: hash) else { return nil }
        hash = WireGuardCrypto.mixHash(hash, encTimestamp)

        var msgData = Data()
        msgData.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
        appendLE32(&msgData, senderIndex)
        msgData.append(ephemeralPub)
        msgData.append(encStatic)
        msgData.append(encTimestamp)

        let mac1Key = Blake2s.hash(data: Data(WireGuardCrypto.labelMAC1.utf8) + peerPublicKey.rawRepresentation, outputLength: 32)
        let computedMac1 = WireGuardCrypto.mac(key: mac1Key, data: msgData)

        msgData.append(computedMac1)
        let computedMac2 = Data(repeating: 0, count: 16)
        msgData.append(computedMac2)

        let initiation = HandshakeInitiation(
            senderIndex: senderIndex,
            ephemeralPublic: ephemeralPub,
            encryptedStatic: encStatic,
            encryptedTimestamp: encTimestamp,
            mac1: computedMac1,
            mac2: computedMac2
        )

        let state = HandshakeState(
            senderIndex: senderIndex,
            staticPrivateKey: staticPrivateKey,
            ephemeralPrivateKey: ephemeral,
            chainingKey: chainingKey,
            hash: hash,
            peerPublicKey: peerPublicKey,
            preSharedKey: preSharedKey
        )

        return (initiation, state)
    }

    static func parseResponse(
        responseData: Data,
        state: HandshakeState
    ) -> SessionKeys? {
        guard responseData.count >= 92 else { return nil }

        let type = responseData[0]
        guard type == 0x02 else { return nil }

        let receiverSenderIndex = readLE32(responseData, offset: 4)
        let receiverReceiverIndex = readLE32(responseData, offset: 8)
        guard receiverReceiverIndex == state.senderIndex else { return nil }

        let respEphemeralPub = responseData[12..<44]
        guard let respEphKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: respEphemeralPub) else { return nil }

        var chainingKey = state.chainingKey
        var hash = state.hash

        chainingKey = WireGuardCrypto.kdf1(key: chainingKey, input: Data(respEphemeralPub))
        hash = WireGuardCrypto.mixHash(hash, Data(respEphemeralPub))

        guard let sharedEphEph = WireGuardCrypto.dh(privateKey: state.ephemeralPrivateKey, publicKey: respEphKey) else { return nil }
        let (ck1, _) = WireGuardCrypto.kdf2(key: chainingKey, input: sharedEphEph)
        chainingKey = ck1

        guard let sharedStaticEph = WireGuardCrypto.dh(
            privateKey: state.staticPrivateKey,
            publicKey: respEphKey
        ) else { return nil }
        let (ck2, _) = WireGuardCrypto.kdf2(key: chainingKey, input: sharedStaticEph)
        chainingKey = ck2

        let psk = state.preSharedKey ?? Data(repeating: 0, count: 32)
        let (ck3, tempKey, key3) = WireGuardCrypto.kdf3(key: chainingKey, input: psk)
        chainingKey = ck3
        hash = WireGuardCrypto.mixHash(hash, tempKey)

        let encNothing = responseData[44..<60]
        guard let _ = WireGuardCrypto.aeadDecrypt(key: key3, counter: 0, ciphertext: Data(encNothing), aad: hash) else {
            return nil
        }
        hash = WireGuardCrypto.mixHash(hash, Data(encNothing))

        let (sendKey, recvKey) = WireGuardCrypto.kdf2(key: chainingKey, input: Data())

        return SessionKeys(
            senderIndex: state.senderIndex,
            receiverIndex: receiverSenderIndex,
            sendingKey: sendKey,
            receivingKey: recvKey
        )
    }

    static func serializeInitiation(_ init_: HandshakeInitiation) -> Data {
        var data = Data()
        data.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
        appendLE32(&data, init_.senderIndex)
        data.append(init_.ephemeralPublic)
        data.append(init_.encryptedStatic)
        data.append(init_.encryptedTimestamp)
        data.append(init_.mac1)
        data.append(init_.mac2)
        return data
    }

    private static func appendLE32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func readLE32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) |
        (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) |
        (UInt32(data[offset + 3]) << 24)
    }
}

nonisolated struct HandshakeState: Sendable {
    let senderIndex: UInt32
    let staticPrivateKey: Curve25519.KeyAgreement.PrivateKey
    let ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey
    let chainingKey: Data
    let hash: Data
    let peerPublicKey: Curve25519.KeyAgreement.PublicKey
    let preSharedKey: Data?
}
