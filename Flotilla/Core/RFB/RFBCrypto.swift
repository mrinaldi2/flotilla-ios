import CommonCrypto
import CryptoKit
import Foundation

/// The two sign-ins macOS Screen Sharing accepts from third-party viewers.
enum RFBCrypto {
    /// Security type 30, "Mac authentication": Diffie-Hellman agrees a key,
    /// MD5 of the shared secret keys AES-128-ECB, which carries the macOS
    /// user name and password. Returns what the client sends back.
    static func appleResponse(generator: [UInt8], prime: [UInt8], serverKey: [UInt8],
                              username: String, password: String) throws -> [UInt8] {
        let length = prime.count
        // A 256-bit private exponent is the usual strength for this group and
        // makes the two exponentiations about four times faster than a full-size one.
        var secretExponent = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, secretExponent.count, &secretExponent) == errSecSuccess else {
            throw RFBError.auth("Could not generate a key.")
        }
        let modulus = BigUInt(bytes: prime)
        let publicKey = BigUInt(bytes: generator).power(secretExponent, modulus: modulus).bytes(length: length)
        let shared = BigUInt(bytes: serverKey).power(secretExponent, modulus: modulus).bytes(length: length)
        let key = Array(Insecure.MD5.hash(data: Data(shared)))

        var credentials = [UInt8](repeating: 0, count: 128)
        _ = SecRandomCopyBytes(kSecRandomDefault, 128, &credentials)
        for (offset, text) in [(0, username), (64, password)] {
            let bytes = Array(text.utf8.prefix(63))
            credentials.replaceSubrange(offset..<offset + bytes.count, with: bytes)
            credentials[offset + bytes.count] = 0
        }
        let sealed = try ecb(credentials, key: key, algorithm: CCAlgorithm(kCCAlgorithmAES), keySize: kCCKeySizeAES128)
        return sealed + publicKey
    }

    /// Security type 2, classic VNC: DES of the challenge with the password,
    /// each key byte bit-reversed as the protocol has always done.
    static func vncResponse(challenge: [UInt8], password: String) throws -> [UInt8] {
        var key = Array(password.utf8.prefix(8))
        key += [UInt8](repeating: 0, count: 8 - key.count)
        key = key.map { byte in
            var reversed: UInt8 = 0
            for bit in 0..<8 where byte & (1 << bit) != 0 { reversed |= 1 << (7 - bit) }
            return reversed
        }
        return try ecb(challenge, key: key, algorithm: CCAlgorithm(kCCAlgorithmDES), keySize: kCCKeySizeDES)
    }

    private static func ecb(_ input: [UInt8], key: [UInt8], algorithm: CCAlgorithm, keySize: Int) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count + 16)
        var written = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), algorithm, CCOptions(kCCOptionECBMode),
                             key, keySize, nil, input, input.count, &output, output.count, &written)
        guard status == kCCSuccess else { throw RFBError.auth("Encryption failed (\(status)).") }
        return Array(output.prefix(written))
    }
}
