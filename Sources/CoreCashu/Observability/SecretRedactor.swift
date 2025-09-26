import Foundation

/// Protocol for redacting sensitive information from logs
public protocol SecretRedactor: Sendable {
    /// Redact sensitive information from a string
    func redact(_ value: String) -> String

    /// Redact sensitive information from metadata
    func redactMetadata(_ metadata: [String: Any]) -> [String: Any]
}

/// Default implementation of secret redactor
public struct DefaultSecretRedactor: SecretRedactor {

    /// Patterns to detect sensitive information
    private let patterns: [RedactionPattern]

    /// Redaction patterns for common sensitive data
    public enum RedactionPattern: Sendable {
        case mnemonic           // BIP39 mnemonic phrases
        case privateKey         // Private keys (hex)
        case seed              // Seeds (hex)
        case token             // Cashu tokens
        case secret            // BDHKE secrets
        case proof             // Proof data
        case witness           // Witness data
        case preimage          // HTLC preimages
        case customRegex(String) // Custom regex pattern

        var regex: String {
            switch self {
            case .mnemonic:
                // Matches sequences of BIP39 words
                return #"\b(\w+\s+){11,23}\w+\b"#
            case .privateKey:
                // Matches 64 hex characters (32 bytes)
                return #"\b[a-fA-F0-9]{64}\b"#
            case .seed:
                // Matches hex seeds of various lengths
                return #"\b[a-fA-F0-9]{32,128}\b"#
            case .token:
                // Matches cashu token prefixes
                return #"cashu[A-Za-z0-9+/]+=*"#
            case .secret:
                // Matches secret-like patterns
                return #"secret:[a-fA-F0-9]{32,}"#
            case .proof:
                // Matches proof data patterns
                return #"\"C\":\"[a-fA-F0-9]{64,}\""#
            case .witness:
                // Matches witness signatures
                return #"witness[\":\s]*[a-fA-F0-9]{64,}"#
            case .preimage:
                // Matches preimage patterns
                return #"preimage[\":\s]*[a-fA-F0-9]{32,}"#
            case .customRegex(let pattern):
                return pattern
            }
        }
    }

    /// Sensitive keys in metadata that should be redacted
    private let sensitiveKeys = Set([
        "mnemonic", "seed", "privateKey", "private_key",
        "secret", "token", "proof", "witness", "preimage",
        "password", "passphrase", "api_key", "apiKey",
        "authorization", "signature"
    ])

    /// Exact match sensitive keys (typically single letter crypto params)
    private let exactMatchKeys = Set(["C", "s", "r"])

    public init(patterns: [RedactionPattern] = [.mnemonic, .privateKey, .seed, .token, .secret, .proof, .witness, .preimage]) {
        self.patterns = patterns
    }

    public func redact(_ value: String) -> String {
        var redacted = value

        // Apply each redaction pattern
        for pattern in patterns {
            do {
                let regex = try NSRegularExpression(pattern: pattern.regex, options: [.caseInsensitive])
                let range = NSRange(location: 0, length: redacted.utf16.count)

                redacted = regex.stringByReplacingMatches(
                    in: redacted,
                    options: [],
                    range: range,
                    withTemplate: "[REDACTED]"
                )
            } catch {
                // If regex fails, continue with other patterns
                continue
            }
        }

        return redacted
    }

    public func redactMetadata(_ metadata: [String: Any]) -> [String: Any] {
        var redacted: [String: Any] = [:]

        for (key, value) in metadata {
            let lowercaseKey = key.lowercased()

            // Check if key contains sensitive information
            let isSensitiveKey = sensitiveKeys.contains(where: { sensitiveKey in
                lowercaseKey.contains(sensitiveKey.lowercased())
            }) || exactMatchKeys.contains(key)

            if isSensitiveKey {
                redacted[key] = "[REDACTED]"
            } else if let stringValue = value as? String {
                // Redact string values that might contain secrets
                redacted[key] = redact(stringValue)
            } else if let dictValue = value as? [String: Any] {
                // Recursively redact nested dictionaries
                redacted[key] = redactMetadata(dictValue)
            } else if let arrayValue = value as? [Any] {
                // Redact array elements
                redacted[key] = arrayValue.map { element -> Any in
                    if let stringElement = element as? String {
                        return redact(stringElement)
                    } else if let dictElement = element as? [String: Any] {
                        return redactMetadata(dictElement)
                    }
                    return element
                }
            } else {
                // Keep non-sensitive values as-is
                redacted[key] = value
            }
        }

        return redacted
    }
}

/// No-op redactor for testing or when redaction is disabled
public struct NoOpRedactor: SecretRedactor {
    public init() {}

    public func redact(_ value: String) -> String {
        value
    }

    public func redactMetadata(_ metadata: [String: Any]) -> [String: Any] {
        metadata
    }
}