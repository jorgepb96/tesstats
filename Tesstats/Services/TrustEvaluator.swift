import Foundation
import Security
import CryptoKit

/// TLS trust policy shared by the MQTT client (Network.framework verify block) and
/// the REST client (URLSession challenge). Supports the public Let's Encrypt chain by
/// default, an explicitly user-accepted self-signed/custom-CA certificate, and optional
/// public-key SHA-256 pinning.
struct TrustConfig: Sendable, Equatable {
    var allowSelfSigned: Bool = false
    var pinnedPublicKeySHA256: String? = nil   // base64 of SHA-256 over the DER public key

    static let standard = TrustConfig()
}

enum TrustEvaluator {

    /// Evaluate a server trust against the policy. Returns true if the connection is acceptable.
    static func evaluate(_ trust: SecTrust, config: TrustConfig) -> Bool {
        // Pinning takes precedence — if a pin is configured it MUST match, regardless of CA.
        if let pin = config.pinnedPublicKeySHA256, !pin.isEmpty {
            return pinMatches(trust: trust, expectedBase64: pin)
        }

        var error: CFError?
        let valid = SecTrustEvaluateWithError(trust, &error)
        if valid { return true }

        // Default chain failed. Accept only if the user explicitly opted in to a custom cert.
        return config.allowSelfSigned
    }

    /// SHA-256 of the leaf certificate's public key, base64-encoded — useful to show the
    /// user a fingerprint they can verify and pin.
    static func leafPublicKeyFingerprint(_ trust: SecTrust) -> String? {
        guard let key = leafPublicKey(trust),
              let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        let digest = SHA256.hash(data: data)
        return Data(digest).base64EncodedString()
    }

    private static func pinMatches(trust: SecTrust, expectedBase64: String) -> Bool {
        guard let fingerprint = leafPublicKeyFingerprint(trust) else { return false }
        return fingerprint == expectedBase64
    }

    private static func leafPublicKey(_ trust: SecTrust) -> SecKey? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        return SecCertificateCopyKey(leaf)
    }
}
