import Foundation
import CryptoKit

nonisolated struct WireGuardCrypto: Sendable {

    static let construction = "Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s"
    static let identifier = "WireGuard v1 zx2c4 Jason@zx2c4.com"
    static let labelMAC1 = "mac1----"
    static let labelCookie = "cookie--"

    static var constructionHash: Data {
        Blake2s.hash(data: Data(construction.utf8), outputLength: 32)
    }

    static var identifierHash: Data {
        Blake2s.hash(data: Data(identifier.utf8), outputLength: 32)
    }

    static var initialChainingKey: Data {
        constructionHash
    }

    static var initialHash: Data {
        Blake2s.hash(data: constructionHash + Data(identifier.utf8), outputLength: 32)
    }

    static func hmacBlake2s(key: Data, data: Data) -> Data {
        let blockSize = 64
        var keyPadded: Data
        if key.count > blockSize {
            keyPadded = Blake2s.hash(data: key, outputLength: 32)
        } else {
            keyPadded = key
        }
        while keyPadded.count < blockSize {
            keyPadded.append(0)
        }

        var ipad = Data(repeating: 0x36, count: blockSize)
        var opad = Data(repeating: 0x5c, count: blockSize)
        for i in 0..<blockSize {
            ipad[i] ^= keyPadded[i]
            opad[i] ^= keyPadded[i]
        }

        let inner = Blake2s.hash(data: ipad + data, outputLength: 32)
        return Blake2s.hash(data: opad + inner, outputLength: 32)
    }

    static func kdf1(key: Data, input: Data) -> Data {
        let t0 = hmacBlake2s(key: key, data: input)
        let t1 = hmacBlake2s(key: t0, data: Data([0x01]))
        return t1
    }

    static func kdf2(key: Data, input: Data) -> (Data, Data) {
        let t0 = hmacBlake2s(key: key, data: input)
        let t1 = hmacBlake2s(key: t0, data: Data([0x01]))
        let t2 = hmacBlake2s(key: t0, data: t1 + Data([0x02]))
        return (t1, t2)
    }

    static func kdf3(key: Data, input: Data) -> (Data, Data, Data) {
        let t0 = hmacBlake2s(key: key, data: input)
        let t1 = hmacBlake2s(key: t0, data: Data([0x01]))
        let t2 = hmacBlake2s(key: t0, data: t1 + Data([0x02]))
        let t3 = hmacBlake2s(key: t0, data: t2 + Data([0x03]))
        return (t1, t2, t3)
    }

    static func mac(key: Data, data: Data) -> Data {
        Blake2s.keyedHash(key: key, data: data, outputLength: 16)
    }

    static func tai64n() -> Data {
        let now = Date()
        let seconds = UInt64(now.timeIntervalSince1970) + 4611686018427387914
        let nanos = UInt32((now.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)) * 1_000_000_000)

        var result = Data(count: 12)
        for i in 0..<8 {
            result[i] = UInt8((seconds >> (56 - i * 8)) & 0xFF)
        }
        for i in 0..<4 {
            result[8 + i] = UInt8((nanos >> (24 - i * 8)) & 0xFF)
        }
        return result
    }

    static func dh(privateKey: Curve25519.KeyAgreement.PrivateKey, publicKey: Curve25519.KeyAgreement.PublicKey) -> Data? {
        try? privateKey.sharedSecretFromKeyAgreement(with: publicKey).withUnsafeBytes { Data($0) }
    }

    static func aead(key: Data, counter: UInt64, plaintext: Data, aad: Data) -> Data? {
        guard key.count == 32 else { return nil }
        let symmetricKey = SymmetricKey(data: key)

        var nonceBytes = Data(count: 12)
        for i in 0..<8 {
            nonceBytes[4 + i] = UInt8((counter >> (i * 8)) & 0xFF)
        }

        guard let nonce = try? ChaChaPoly.Nonce(data: nonceBytes) else { return nil }

        do {
            let sealedBox = try ChaChaPoly.seal(plaintext, using: symmetricKey, nonce: nonce, authenticating: aad)
            return sealedBox.ciphertext + sealedBox.tag
        } catch {
            return nil
        }
    }

    static func aeadDecrypt(key: Data, counter: UInt64, ciphertext: Data, aad: Data) -> Data? {
        guard key.count == 32, ciphertext.count >= 16 else { return nil }
        let symmetricKey = SymmetricKey(data: key)

        var nonceBytes = Data(count: 12)
        for i in 0..<8 {
            nonceBytes[4 + i] = UInt8((counter >> (i * 8)) & 0xFF)
        }

        guard let nonce = try? ChaChaPoly.Nonce(data: nonceBytes) else { return nil }

        let ct = ciphertext.prefix(ciphertext.count - 16)
        let tag = ciphertext.suffix(16)

        do {
            let sealedBox = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
            return try ChaChaPoly.open(sealedBox, using: symmetricKey, authenticating: aad)
        } catch {
            return nil
        }
    }

    static func generateEphemeralKeyPair() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    static func publicKey(from privateKeyBase64: String) -> Curve25519.KeyAgreement.PublicKey? {
        guard let keyData = Data(base64Encoded: privateKeyBase64) else { return nil }
        guard let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData) else { return nil }
        return privateKey.publicKey
    }

    static func privateKey(from base64: String) -> Curve25519.KeyAgreement.PrivateKey? {
        guard let keyData = Data(base64Encoded: base64) else { return nil }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData)
    }

    static func peerPublicKey(from base64: String) -> Curve25519.KeyAgreement.PublicKey? {
        guard let keyData = Data(base64Encoded: base64) else { return nil }
        return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
    }

    static func mixHash(_ hash: Data, _ data: Data) -> Data {
        Blake2s.hash(data: hash + data, outputLength: 32)
    }
}
