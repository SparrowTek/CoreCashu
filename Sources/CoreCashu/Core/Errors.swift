//
//  Errors.swift
//  CashuKit
//
//  Created by Thomas Rademaker on 6/27/25.
//

import Foundation

/// Categories of errors for better handling
public enum CashuErrorCategory: String, Sendable {
    case cryptographic = "Cryptographic"
    case network = "Network"
    case validation = "Validation"
    case wallet = "Wallet"
    case storage = "Storage"
    case `protocol` = "Protocol"
}

/// Errors that can occur during Cashu operations
/// Structured context attached to ``CashuError/networkFailure(_:)``.
///
/// Generic `networkError(String)` strings are not enough for a caller that wants to retry
/// intelligently — was it a 5xx (transient, retry), a 4xx (permanent, fix the request), or a
/// transport error (transient, retry with backoff)? This wrapper carries the structured
/// pieces a retry layer or telemetry consumer actually needs.
///
/// - `message`: short human-readable summary.
/// - `httpStatus`: HTTP status code if the failure originated from a response, otherwise nil
///   (e.g., DNS failure, TLS handshake failure, timeout).
/// - `responseBody`: a *size-capped* prefix of the response body. Capped to avoid blowing up
///   logs and avoid leaking secrets in the rare case a mint includes them in error bodies.
/// - `underlying`: the lower-level `Error` that triggered this failure, when one exists.
///   Preserves type structure so a caller can pattern-match on `URLError`, `DecodingError`,
///   etc., instead of parsing strings.
public struct NetworkErrorContext: Sendable {
    /// Default cap for `responseBody` — 4 KiB is enough for diagnostics without leaking
    /// large payloads into log streams.
    public static let defaultResponseBodyCap: Int = 4_096

    public let message: String
    public let httpStatus: Int?
    public let responseBody: String?
    public let underlying: (any Error & Sendable)?

    public init(
        message: String,
        httpStatus: Int? = nil,
        responseBody: String? = nil,
        underlying: (any Error & Sendable)? = nil
    ) {
        self.message = message
        self.httpStatus = httpStatus
        self.responseBody = NetworkErrorContext.cap(responseBody)
        self.underlying = underlying
    }

    private static func cap(_ body: String?) -> String? {
        guard let body, body.count > defaultResponseBodyCap else { return body }
        return String(body.prefix(defaultResponseBodyCap)) + "…[truncated]"
    }
}

public enum CashuError: Error, Sendable {
    // Core cryptographic errors
    case invalidPoint
    case invalidSecretLength
    case hashToCurveFailed
    case blindingFailed
    case unblindingFailed
    case verificationFailed
    case invalidHexString
    case keyGenerationFailed
    case domainSeperator
    
    // Network and API errors
    case networkError(String)
    /// Structured network/HTTP failure carrying enough context for intelligent retry
    /// decisions and telemetry. Prefer this over `.networkError(String)` for new code.
    case networkFailure(NetworkErrorContext)
    case invalidMintURL
    case mintUnavailable
    case invalidResponse
    case rateLimitExceeded
    case insufficientFunds
    /// Wraps a lower-level `Error` so type information (e.g., `DecodingError`,
    /// `URLError`) is preserved instead of stringified.
    case wrappedFailure(message: String, underlying: any Error & Sendable)
    
    // Token and serialization errors
    case invalidTokenFormat
    case serializationFailed
    case deserializationFailed
    case validationFailed
    
    // NUT-specific errors
    case invalidNutVersion(String)
    case invalidKeysetID
    
    // HTTP API errors (following NUT-00 error format)
    case httpError(detail: String, code: Int)
    
    // Wallet-specific errors
    case walletNotInitialized
    case walletAlreadyInitialized
    case walletNotInitializedWithMnemonic
    case invalidProofSet
    case proofAlreadySpent
    case proofNotFound
    case invalidAmount
    case amountTooLarge
    case amountTooSmall
    case balanceInsufficient
    case noSpendableProofs
    case invalidWalletState
    case storageError(String)
    case syncRequired
    case operationTimeout
    case operationCancelled
    case invalidMintConfiguration
    case keysetNotFound
    case keysetExpired
    case tokenExpired
    case tokenAlreadyUsed
    case invalidTokenStructure
    case missingRequiredField(String)
    case unsupportedOperation(String)
    case concurrencyError(String)
    case unsupportedVersion
    case missingBlindingFactor
    case noKeychainData
    
    // NUT-13 specific errors
    case invalidMnemonic
    case invalidSecret
    case invalidSignature(String)
    case mismatchedArrayLengths
    case invalidSpendingCondition(String)

    // NUT-14 specific errors
    case invalidPreimage
    case locktimeNotExpired
    case invalidProofType
    case invalidWitness
    case noActiveKeyset
    
    // Additional errors for user-friendly error system
    case connectionFailed
    case invalidToken
    case tokenAlreadySpent
    case invalidProof
    case tokenNotFound
    case quotePending
    case quoteExpired
    case quoteNotFound
    case keysetInactive
    case invalidUnit
    case invalidDenomination
    case invalidState(String)
    case serializationError(String)
    case jsonEncodingError
    case jsonDecodingError
    case hexDecodingError
    case base64DecodingError
    /// Wraps an Apple `OSStatus`-like integer code without depending on the Apple-only
    /// `OSStatus` typealias (which doesn't exist on Linux). Phase 8.13.
    case unhandledError(Int32)
    case unknownError
    case notImplemented
    case invalidDerivationPath
    case temporaryFailure
}

// MARK: - HTTP Error Response (NUT-00 Specification)

/// HTTP error response structure as defined in NUT-00
/// Used when mints respond with HTTP status code 400 and error details
public struct CashuHTTPError: CashuCodabale, Error, Sendable {
    /// Error message
    public let detail: String
    /// Error code
    public let code: Int
    
    public init(detail: String, code: Int) {
        self.detail = detail
        self.code = code
    }
}

// MARK: - Error Extensions

// MARK: - Error Category

extension CashuError {
    /// The category of this error
    public var category: CashuErrorCategory {
        switch self {
        case .invalidPoint, .invalidSecretLength, .hashToCurveFailed, .blindingFailed,
             .unblindingFailed, .verificationFailed, .invalidHexString, .keyGenerationFailed,
             .invalidSignature, .domainSeperator, .missingBlindingFactor:
            return .cryptographic
            
        case .networkError, .networkFailure, .invalidMintURL, .mintUnavailable, .invalidResponse,
             .rateLimitExceeded, .httpError:
            return .network
            
        case .invalidTokenFormat, .serializationFailed, .deserializationFailed,
             .validationFailed, .invalidAmount, .amountTooLarge, .amountTooSmall,
             .missingRequiredField, .invalidTokenStructure:
            return .validation
            
        case .walletNotInitialized, .walletAlreadyInitialized, .walletNotInitializedWithMnemonic,
             .invalidProofSet, .proofAlreadySpent, .proofNotFound, .balanceInsufficient, 
             .noSpendableProofs, .invalidWalletState, .tokenExpired, .tokenAlreadyUsed,
             .noKeychainData:
            return .wallet
            
        case .storageError:
            return .storage
            
        case .invalidNutVersion, .invalidKeysetID, .insufficientFunds,
             .syncRequired, .operationTimeout, .operationCancelled, .invalidMintConfiguration,
             .keysetNotFound, .keysetExpired, .unsupportedOperation, .concurrencyError,
             .unsupportedVersion, .invalidMnemonic, .invalidSecret,
             .mismatchedArrayLengths, .invalidSpendingCondition, .invalidPreimage,
             .locktimeNotExpired, .invalidProofType, .invalidWitness, .noActiveKeyset,
             .quotePending, .quoteExpired, .quoteNotFound, .keysetInactive,
             .invalidUnit, .invalidDenomination, .invalidDerivationPath,
             .notImplemented:
            return .`protocol`
            
        case .connectionFailed, .temporaryFailure:
            return .network
            
        case .invalidToken, .tokenAlreadySpent, .invalidProof, .tokenNotFound,
             .invalidState, .serializationError, .jsonEncodingError, .jsonDecodingError,
             .hexDecodingError, .base64DecodingError, .wrappedFailure:
            return .validation
            
        case .unhandledError, .unknownError:
            return .wallet
        }
    }
    
    /// Whether this error is retryable
    public var isRetryable: Bool {
        switch self {
        case .networkError, .mintUnavailable, .rateLimitExceeded, .operationTimeout,
             .connectionFailed, .temporaryFailure, .quotePending:
            return true
        case .httpError(_, let code):
            return code >= 500 || code == 429
        case .networkFailure(let context):
            // Same retry rules as raw HTTP errors: 5xx and 429 are transient; missing status
            // typically means the request never landed (DNS/TLS/timeout) — also transient.
            guard let status = context.httpStatus else { return true }
            return status >= 500 || status == 429
        default:
            return false
        }
    }
    
    /// Error code for debugging
    public var code: String {
        let mirror = Mirror(reflecting: self)
        return "CASHU_\(String(describing: mirror.children.first?.label ?? "UNKNOWN").uppercased())"
    }
}

// MARK: - LocalizedError Conformance

extension CashuError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        // Core cryptographic errors
        case .invalidPoint:
            return "Invalid elliptic curve point"
        case .invalidSecretLength:
            return "Invalid secret length"
        case .hashToCurveFailed:
            return "Hash-to-curve operation failed"
        case .blindingFailed:
            return "Blinding operation failed"
        case .unblindingFailed:
            return "Unblinding operation failed"
        case .verificationFailed:
            return "Signature verification failed"
        case .invalidHexString:
            return "Invalid hexadecimal string"
        case .keyGenerationFailed:
            return "Key generation failed"
        case .domainSeperator:
            return "Domain separator error"
            
        // Network and API errors
        case .networkError(let message):
            return "Network error: \(message)"
        case .networkFailure(let context):
            var parts = ["Network failure: \(context.message)"]
            if let status = context.httpStatus { parts.append("status=\(status)") }
            if let body = context.responseBody, !body.isEmpty { parts.append("body=\(body)") }
            if let underlying = context.underlying { parts.append("underlying=\(type(of: underlying))") }
            return parts.joined(separator: " ")
        case .wrappedFailure(let message, let underlying):
            return "\(message) (underlying \(type(of: underlying)): \(underlying.localizedDescription))"
        case .invalidMintURL:
            return "Invalid mint URL"
        case .mintUnavailable:
            return "Mint is unavailable"
        case .invalidResponse:
            return "Invalid response from mint"
        case .rateLimitExceeded:
            return "Rate limit exceeded"
        case .insufficientFunds:
            return "Insufficient funds"
            
        // Token and serialization errors
        case .invalidTokenFormat:
            return "Invalid token format"
        case .serializationFailed:
            return "Serialization failed"
        case .deserializationFailed:
            return "Deserialization failed"
        case .validationFailed:
            return "Validation failed"
            
        // NUT-specific errors
        case .invalidNutVersion(let version):
            return "Invalid NUT version: \(version)"
        case .invalidKeysetID:
            return "Invalid keyset ID"
            
        // HTTP API errors
        case .httpError(let detail, let code):
            return "HTTP error \(code): \(detail)"
            
        // Wallet-specific errors
        case .walletNotInitialized:
            return "Wallet not initialized"
        case .walletAlreadyInitialized:
            return "Wallet already initialized"
        case .invalidProofSet:
            return "Invalid proof set"
        case .proofAlreadySpent:
            return "Proof already spent"
        case .proofNotFound:
            return "Proof not found"
        case .invalidAmount:
            return "Invalid amount"
        case .amountTooLarge:
            return "Amount too large"
        case .amountTooSmall:
            return "Amount too small"
        case .balanceInsufficient:
            return "Insufficient balance"
        case .noSpendableProofs:
            return "No spendable proofs available"
        case .invalidWalletState:
            return "Invalid wallet state"
        case .storageError(let message):
            return "Storage error: \(message)"
        case .syncRequired:
            return "Wallet sync required"
        case .operationTimeout:
            return "Operation timed out"
        case .operationCancelled:
            return "Operation cancelled"
        case .invalidMintConfiguration:
            return "Invalid mint configuration"
        case .keysetNotFound:
            return "Keyset not found"
        case .keysetExpired:
            return "Keyset expired"
        case .tokenExpired:
            return "Token expired"
        case .tokenAlreadyUsed:
            return "Token already used"
        case .invalidTokenStructure:
            return "Invalid token structure"
        case .missingRequiredField(let field):
            return "Missing required field: \(field)"
        case .unsupportedOperation(let operation):
            return "Unsupported operation: \(operation)"
        case .concurrencyError(let message):
            return "Concurrency error: \(message)"
        case .unsupportedVersion:
            return "Unsupported version"
        case .missingBlindingFactor:
            return "Missing blinding factor for DLEQ proof verification"
        case .walletNotInitializedWithMnemonic:
            return "Wallet was not initialized with a mnemonic phrase"
        case .invalidMnemonic:
            return "Invalid mnemonic phrase"
        case .invalidSecret:
            return "Invalid secret"
        case .invalidSignature(let message):
            return "Invalid signature: \(message)"
        case .mismatchedArrayLengths:
            return "Mismatched array lengths"
        case .invalidSpendingCondition(let detail):
            return "Invalid spending condition: \(detail)"
            
        // NUT-14 errors
        case .invalidPreimage:
            return "Invalid preimage: must be 32 bytes"
        case .locktimeNotExpired:
            return "HTLC locktime has not expired yet"
        case .invalidProofType:
            return "Proof is not an HTLC type"
        case .invalidWitness:
            return "Invalid witness data for HTLC proof"
        case .noActiveKeyset:
            return "No active keyset found for mint"
        case .noKeychainData:
            return "No wallet data found in keychain"
            
        // Additional errors
        case .connectionFailed:
            return "Connection failed"
        case .invalidToken:
            return "Invalid token"
        case .tokenAlreadySpent:
            return "Token already spent"
        case .invalidProof:
            return "Invalid proof"
        case .tokenNotFound:
            return "Token not found"
        case .quotePending:
            return "Quote is pending"
        case .quoteExpired:
            return "Quote has expired"
        case .quoteNotFound:
            return "Quote not found"
        case .keysetInactive:
            return "Keyset is inactive"
        case .invalidUnit:
            return "Invalid unit"
        case .invalidDenomination:
            return "Invalid denomination"
        case .invalidState(let state):
            return "Invalid state: \(state)"
        case .serializationError(let details):
            return "Serialization error: \(details)"
        case .jsonEncodingError:
            return "JSON encoding error"
        case .jsonDecodingError:
            return "JSON decoding error"
        case .hexDecodingError:
            return "Hex decoding error"
        case .base64DecodingError:
            return "Base64 decoding error"
        case .unhandledError(let status):
            return "Unhandled error with status: \(status)"
        case .unknownError:
            return "Unknown error occurred"
        case .notImplemented:
            return "Feature not implemented"
        case .invalidDerivationPath:
            return "Invalid derivation path"
        case .temporaryFailure:
            return "Temporary failure, please retry"
        }
    }
}

// MARK: - Error Customization

extension CashuError {
    public var recoverySuggestion: String? {
        switch self {
        // Cryptographic errors
        case .invalidSecretLength:
            return "Ensure the secret has the correct length for the cryptographic operation"
        case .hashToCurveFailed:
            return "Verify the input data is properly formatted"
        case .verificationFailed:
            return "Ensure you're using the correct keyset and the proof hasn't been tampered with"
        case .invalidHexString:
            return "Provide a valid hexadecimal string (0-9, A-F)"
            
        // Network errors
        case .networkError:
            return "Check your network connection and try again"
        case .mintUnavailable:
            return "Try again later or use a different mint"
        case .rateLimitExceeded:
            return "Wait a moment before trying again"
        case .invalidMintURL:
            return "Verify the mint URL is correct and includes the protocol (https://)"
        case .httpError(_, let code) where code == 429:
            return "You're making too many requests. Please wait before trying again"
        case .httpError(_, let code) where code >= 500:
            return "The mint is experiencing issues. Try again later"
            
        // Validation errors
        case .invalidTokenFormat:
            return "Ensure the token follows the Cashu token format specification"
        case .validationFailed:
            return "Check that all required fields are present and properly formatted"
        case .amountTooLarge:
            return "Use a smaller amount or split into multiple transactions"
        case .amountTooSmall:
            return "Use a larger amount that meets the minimum requirement"
            
        // Wallet errors
        case .walletNotInitialized:
            return "Initialize the wallet before performing operations"
        case .syncRequired:
            return "Sync the wallet with the mint to get the latest state"
        case .balanceInsufficient:
            return "Add more funds to your wallet or use a smaller amount"
        case .keysetExpired:
            return "Sync the wallet to get updated keysets from the mint"
        case .tokenExpired:
            return "Request a new token as this one has expired"
        case .operationTimeout:
            return "Check your connection and try the operation again"
        case .proofAlreadySpent:
            return "This proof has been used. Sync your wallet to update your balance"
        case .noSpendableProofs:
            return "Consolidate your proofs or add more funds to your wallet"
        case .unsupportedVersion:
            return "Update your wallet software to support this version"
        case .noKeychainData:
            return "Initialize a new wallet or restore from a mnemonic phrase"
            
        default:
            return nil
        }
    }
    
    public var failureReason: String? {
        switch self {
        // Cryptographic errors
        case .blindingFailed:
            return "The blinding factor could not be applied to the message"
        case .unblindingFailed:
            return "The blind signature could not be converted to a valid signature"
        case .keyGenerationFailed:
            return "Cryptographic keys could not be generated"
            
        // Network errors
        case .networkError:
            return "Network communication failed"
        case .mintUnavailable:
            return "Mint server is not responding"
        case .httpError(_, let code) where code == 404:
            return "The requested endpoint does not exist"
        case .httpError(_, let code) where code == 401:
            return "Authentication failed or required"
            
        // Validation errors
        case .invalidTokenFormat:
            return "Token format does not match expected structure"
        case .missingRequiredField:
            return "A required field is not present in the data"
            
        // Wallet errors
        case .walletNotInitialized:
            return "Wallet operations require initialization"
        case .balanceInsufficient:
            return "Not enough funds available for this operation"
        case .proofAlreadySpent:
            return "Proof has already been redeemed at the mint"
        case .keysetNotFound:
            return "The mint's signing keys are not available"
        case .invalidWalletState:
            return "The wallet is in an inconsistent state"
            
        default:
            return nil
        }
    }
    
    /// User info dictionary for NSError bridging
    public var errorUserInfo: [String: Any] {
        var userInfo: [String: Any] = [:]
        
        if let description = errorDescription {
            userInfo[NSLocalizedDescriptionKey] = description
        }
        
        if let reason = failureReason {
            userInfo[NSLocalizedFailureReasonErrorKey] = reason
        }
        
        if let suggestion = recoverySuggestion {
            userInfo[NSLocalizedRecoverySuggestionErrorKey] = suggestion
        }
        
        userInfo["category"] = category.rawValue
        userInfo["code"] = code
        userInfo["isRetryable"] = isRetryable
        
        return userInfo
    }
}
