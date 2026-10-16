import Foundation
import CryptoKit
import CommonCrypto

// Password-based encryption for configuration backups. The threat model: the exported file
// may end up in iCloud Drive, an email, AirDrop, etc., so it must be unreadable without the
// user's password — even to us. We use the standard construction:
//   • PBKDF2-HMAC-SHA256 (high iteration count) to stretch the password into a 256-bit key,
//     with a random per-file salt so identical passwords never produce the same key.
//   • AES-256-GCM (authenticated encryption) so a wrong password — or any tampering — fails
//     to decrypt rather than yielding garbage. There is no recovery without the password.

enum BackupCryptoError: Error, LocalizedError {
    case wrongPassword
    case malformed
    case kdfFailed

    var errorDescription: String? {
        switch self {
        case .wrongPassword: L("Wrong password — the backup couldn't be decrypted.")
        case .malformed: L("This file isn't a valid encrypted Tesstats backup.")
        case .kdfFailed: L("Couldn't derive the encryption key.")
        }
    }
}

/// On-disk container for an encrypted backup. Only ciphertext, a random salt and the KDF
/// parameters are stored — never the password or the plaintext. `Data` fields serialize as
/// base64 in JSON.
struct EncryptedBackup: Codable, Sendable {
    var format = EncryptedBackup.magic
    var version = 1
    var kdf = "pbkdf2-hmac-sha256"
    var cipher = "aes-256-gcm"
    var iterations: Int
    var salt: Data
    /// AES-GCM combined box: nonce (12B) ‖ ciphertext ‖ tag (16B).
    var ciphertext: Data

    static let magic = "tesstats.encrypted-backup"

    /// Recommended PBKDF2 work factor (OWASP 2023 guidance for HMAC-SHA256).
    static let defaultIterations = 210_000

    func encoded() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(self)) ?? Data()
    }

    /// Detect and decode the encrypted container (returns nil if the data isn't one).
    static func decode(_ data: Data) -> EncryptedBackup? {
        guard let backup = try? JSONDecoder().decode(EncryptedBackup.self, from: data),
              backup.format == EncryptedBackup.magic else { return nil }
        return backup
    }
}

enum BackupCrypto {

    // MARK: - Public API

    /// Encrypt arbitrary plaintext (the ConfigBackup JSON) under a password.
    static func encrypt(_ plaintext: Data, password: String) throws -> EncryptedBackup {
        let salt = randomBytes(16)
        let iterations = EncryptedBackup.defaultIterations
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw BackupCryptoError.malformed }
        return EncryptedBackup(iterations: iterations, salt: salt, ciphertext: combined)
    }

    /// Decrypt a container with a password. Throws `.wrongPassword` on any auth failure.
    static func decrypt(_ backup: EncryptedBackup, password: String) throws -> Data {
        guard backup.format == EncryptedBackup.magic, backup.version == 1,
              backup.kdf == "pbkdf2-hmac-sha256", backup.cipher == "aes-256-gcm",
              backup.salt.count == 16, (1...2_000_000).contains(backup.iterations) else {
            throw BackupCryptoError.malformed
        }
        let key = try deriveKey(password: password, salt: backup.salt, iterations: backup.iterations)
        let box: AES.GCM.SealedBox
        do { box = try AES.GCM.SealedBox(combined: backup.ciphertext) }
        catch { throw BackupCryptoError.malformed }
        do { return try AES.GCM.open(box, using: key) }
        catch { throw BackupCryptoError.wrongPassword }   // GCM tag mismatch ⇒ bad key/tamper
    }

    // MARK: - Internals

    private static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int32 in
            salt.withUnsafeBytes { (saltPtr: UnsafeRawBufferPointer) -> Int32 in
                passwordData.withUnsafeBytes { (pwPtr: UnsafeRawBufferPointer) -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.baseAddress?.assumingMemoryBound(to: CChar.self),
                        passwordData.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        out.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32)
                }
            }
        }
        guard status == kCCSuccess else { throw BackupCryptoError.kdfFailed }
        return SymmetricKey(data: derived)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        if result != errSecSuccess {
            // Extremely unlikely; fall back to a non-crypto source rather than crash.
            for i in 0..<count { data[i] = UInt8.random(in: 0...255) }
        }
        return data
    }
}
