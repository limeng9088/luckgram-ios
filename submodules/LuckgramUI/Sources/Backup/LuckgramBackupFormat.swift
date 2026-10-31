import Foundation
import CommonCrypto
import CryptoKit
import Security

/// Luckgram 10: the `.luckgram-backup` file. Identical on Android
/// (`org.telegram.luckgram.backup.LuckgramBackupFormat`); see docs/backup-format.md in luckgram-specs.
///
///     file      = UTF-8 JSON {"format":"luckgram-backup","version":1,"kdf":"pbkdf2-sha256",
///                 "iterations":600000,"salt":b64(16),"nonce":b64(12),"ciphertext":b64(ct || tag16)}
///     key       = PBKDF2-HMAC-SHA256(UTF-8 password, salt, iterations, 32 bytes)
///     cipher    = AES-256-GCM, 128-bit tag, AAD = ASCII "luckgram-backup/1"
///     plaintext = UTF-8 JSON {"accounts":[{"user_id":"123","dc_id":2,"auth_key":b64(256),
///                 "server_salt":"-42","name":"Work"}]}
public enum LuckgramBackupFormat {
    public static let fileExtension = "luckgram-backup"
    public static let format = "luckgram-backup"
    public static let version = 1
    public static let kdf = "pbkdf2-sha256"
    public static let iterations = 600_000
    public static let minPasswordLength = 8
    private static let maxIterations = 10_000_000
    private static let saltLength = 16
    private static let nonceLength = 12
    private static let tagLength = 16
    private static let aad = Data("luckgram-backup/1".utf8)

    public struct Account {
        public let userId: Int64
        public let dcId: Int32
        public fileprivate(set) var authKey: Data
        public let serverSalt: Int64
        public let name: String

        public init(userId: Int64, dcId: Int32, authKey: Data, serverSalt: Int64, name: String?) {
            self.userId = userId
            self.dcId = dcId
            self.authKey = authKey
            self.serverSalt = serverSalt
            self.name = name ?? ""
        }

        /// Overwrites this copy of the key (best effort: `Data` may have been copied before).
        public mutating func wipe() {
            self.authKey.resetBytes(in: 0 ..< self.authKey.count)
        }
    }

    public enum DecodeError: Error {
        /// Not a Luckgram backup, an unknown version, or a damaged file.
        case format
        /// Wrong password (or a damaged ciphertext: GCM cannot tell them apart).
        case wrongPassword
    }

    // MARK: - Encode / decode

    public static func encrypt(accounts: [Account], password: String) throws -> Data {
        return try self.encrypt(accounts: accounts, password: password, salt: randomBytes(saltLength), nonce: randomBytes(nonceLength), iterations: iterations)
    }

    /// With fixed salt and nonce; only tests use this directly.
    static func encrypt(accounts: [Account], password: String, salt: Data, nonce: Data, iterations: Int) throws -> Data {
        var plaintext = try self.plaintext(accounts: accounts)
        defer {
            plaintext.resetBytes(in: 0 ..< plaintext.count)
        }
        var key = try self.deriveKey(password: password, salt: salt, iterations: iterations)
        defer {
            key.resetBytes(in: 0 ..< key.count)
        }
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        let file: [String: Any] = [
            "format": format,
            "version": version,
            "kdf": kdf,
            "iterations": iterations,
            "salt": salt.base64EncodedString(),
            "nonce": nonce.base64EncodedString(),
            "ciphertext": (sealed.ciphertext + sealed.tag).base64EncodedString()
        ]
        return try JSONSerialization.data(withJSONObject: file, options: [.sortedKeys])
    }

    public static func decrypt(fileData: Data, password: String) throws -> [Account] {
        guard let file = (try? JSONSerialization.jsonObject(with: fileData)) as? [String: Any],
              file["format"] as? String == format else {
            throw DecodeError.format
        }
        guard (file["version"] as? NSNumber)?.intValue == version, file["kdf"] as? String == kdf,
              let iterations = (file["iterations"] as? NSNumber)?.intValue,
              let saltString = file["salt"] as? String, let salt = Data(base64Encoded: saltString),
              let nonceString = file["nonce"] as? String, let nonce = Data(base64Encoded: nonceString),
              let ciphertextString = file["ciphertext"] as? String, let combined = Data(base64Encoded: ciphertextString),
              iterations >= 1, iterations <= maxIterations, salt.count >= 8, nonce.count == nonceLength, combined.count >= tagLength else {
            throw DecodeError.format
        }
        var key = try self.deriveKey(password: password, salt: salt, iterations: iterations)
        defer {
            key.resetBytes(in: 0 ..< key.count)
        }
        var plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: combined.prefix(combined.count - tagLength), tag: combined.suffix(tagLength))
            plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
        } catch {
            throw DecodeError.wrongPassword
        }
        defer {
            plaintext.resetBytes(in: 0 ..< plaintext.count)
        }
        return try self.parse(plaintext: plaintext)
    }

    // MARK: - Plaintext

    private static func plaintext(accounts: [Account]) throws -> Data {
        let items: [[String: Any]] = accounts.map { account in
            return [
                "user_id": "\(account.userId)",
                "dc_id": Int(account.dcId),
                "auth_key": account.authKey.base64EncodedString(),
                "server_salt": "\(account.serverSalt)",
                "name": account.name
            ]
        }
        return try JSONSerialization.data(withJSONObject: ["accounts": items], options: [])
    }

    private static func parse(plaintext: Data) throws -> [Account] {
        guard let root = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any],
              let items = root["accounts"] as? [[String: Any]] else {
            throw DecodeError.format
        }
        var result: [Account] = []
        for item in items {
            guard let userIdString = item["user_id"] as? String, let userId = Int64(userIdString), userId > 0,
                  let dcId = (item["dc_id"] as? NSNumber)?.int32Value, dcId > 0,
                  let keyString = item["auth_key"] as? String, let authKey = Data(base64Encoded: keyString), authKey.count == 256 else {
                throw DecodeError.format
            }
            let serverSalt = (item["server_salt"] as? String).flatMap { Int64($0) } ?? 0
            result.append(Account(userId: userId, dcId: dcId, authKey: authKey, serverSalt: serverSalt, name: item["name"] as? String))
        }
        return result
    }

    // MARK: - Crypto helpers

    static func deriveKey(password: String, salt: Data, iterations: Int) throws -> Data {
        var passwordBytes = Array(password.utf8)
        if passwordBytes.isEmpty {
            throw DecodeError.wrongPassword
        }
        defer {
            for i in 0 ..< passwordBytes.count {
                passwordBytes[i] = 0
            }
        }
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { keyBytes -> Int32 in
            return salt.withUnsafeBytes { saltBytes -> Int32 in
                return passwordBytes.withUnsafeBufferPointer { passwordPointer -> Int32 in
                    return passwordPointer.baseAddress!.withMemoryRebound(to: Int8.self, capacity: passwordBytes.count) { password in
                        return CCKeyDerivationPBKDF(
                            CCPBKDFAlgorithm(kCCPBKDF2),
                            password, passwordBytes.count,
                            saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                            UInt32(iterations),
                            keyBytes.bindMemory(to: UInt8.self).baseAddress, 32
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw DecodeError.format
        }
        return key
    }

    private static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            return SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        precondition(status == errSecSuccess)
        return data
    }
}
