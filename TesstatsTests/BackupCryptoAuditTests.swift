import XCTest
@testable import Tesstats

final class BackupCryptoAuditTests: XCTestCase {
    func testEncryptedBackupRoundTripWrongPasswordAndTampering() throws {
        let plaintext = Data("{\"setting\":\"auditoría\"}".utf8)
        let backup = try BackupCrypto.encrypt(plaintext, password: "test-only-password")
        let decoded = try XCTUnwrap(EncryptedBackup.decode(backup.encoded()))
        XCTAssertEqual(try BackupCrypto.decrypt(decoded, password: "test-only-password"), plaintext)
        XCTAssertThrowsError(try BackupCrypto.decrypt(decoded, password: "wrong-password"))
        var tampered = decoded
        tampered.ciphertext[tampered.ciphertext.count - 1] ^= 1
        XCTAssertThrowsError(try BackupCrypto.decrypt(tampered, password: "test-only-password"))
        XCTAssertFalse(String(decoding: backup.encoded(), as: UTF8.self).contains("test-only-password"))
    }

    func testMalformedKDFParametersFailBeforeIntegerConversionOrExpensiveWork() throws {
        let valid = try BackupCrypto.encrypt(Data("test".utf8), password: "test")
        for iterations in [-1, 0, 2_000_001, Int.max] {
            var invalid = valid
            invalid.iterations = iterations
            XCTAssertThrowsError(try BackupCrypto.decrypt(invalid, password: "test"))
        }
        var invalid = valid
        invalid.version = 99
        XCTAssertThrowsError(try BackupCrypto.decrypt(invalid, password: "test"))
        invalid = valid
        invalid.salt = Data()
        XCTAssertThrowsError(try BackupCrypto.decrypt(invalid, password: "test"))
    }
}
