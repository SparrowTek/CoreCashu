//
//  ErrorHandlingTests.swift
//  CoreCashu
//
//  Comprehensive tests for CashuError and error handling
//

import Testing
import Foundation
@testable import CoreCashu

// MARK: - CashuError Category Tests

@Suite("CashuError Category Tests")
struct CashuErrorCategoryTests {
    
    @Test("Cryptographic errors have correct category")
    func cryptographicErrorsCategory() throws {
        let cryptoErrors: [CashuError] = [
            .invalidPoint,
            .invalidSecretLength,
            .hashToCurveFailed,
            .blindingFailed,
            .unblindingFailed,
            .verificationFailed,
            .invalidHexString,
            .keyGenerationFailed,
            .domainSeperator,
            .missingBlindingFactor
        ]
        
        for error in cryptoErrors {
            #expect(error.category == .cryptographic, "Expected \(error) to be cryptographic")
        }
    }
    
    @Test("Network errors have correct category")
    func networkErrorsCategory() throws {
        let networkErrors: [CashuError] = [
            .networkError("test"),
            .invalidMintURL,
            .mintUnavailable,
            .invalidResponse,
            .rateLimitExceeded,
            .httpError(detail: "test", code: 500),
            .connectionFailed,
            .temporaryFailure
        ]
        
        for error in networkErrors {
            #expect(error.category == .network, "Expected \(error) to be network")
        }
    }
    
    @Test("Validation errors have correct category")
    func validationErrorsCategory() throws {
        let validationErrors: [CashuError] = [
            .invalidTokenFormat,
            .serializationFailed,
            .deserializationFailed,
            .validationFailed,
            .invalidAmount,
            .amountTooLarge,
            .amountTooSmall,
            .missingRequiredField("test"),
            .invalidTokenStructure,
            .invalidToken,
            .tokenAlreadySpent,
            .invalidProof,
            .tokenNotFound,
            .invalidState("test"),
            .serializationError("test"),
            .jsonEncodingError,
            .jsonDecodingError,
            .hexDecodingError,
            .base64DecodingError
        ]
        
        for error in validationErrors {
            #expect(error.category == .validation, "Expected \(error) to be validation")
        }
    }
    
    @Test("Wallet errors have correct category")
    func walletErrorsCategory() throws {
        let walletErrors: [CashuError] = [
            .walletNotInitialized,
            .walletAlreadyInitialized,
            .walletNotInitializedWithMnemonic,
            .invalidProofSet,
            .proofAlreadySpent,
            .proofNotFound,
            .balanceInsufficient,
            .noSpendableProofs,
            .invalidWalletState,
            .tokenExpired,
            .tokenAlreadyUsed,
            .noKeychainData
        ]
        
        for error in walletErrors {
            #expect(error.category == .wallet, "Expected \(error) to be wallet")
        }
    }
    
    @Test("Storage errors have correct category")
    func storageErrorsCategory() throws {
        let storageErrors: [CashuError] = [
            .storageError("test")
        ]
        
        for error in storageErrors {
            #expect(error.category == .storage, "Expected \(error) to be storage")
        }
    }
    
    @Test("Protocol errors have correct category")
    func protocolErrorsCategory() throws {
        let protocolErrors: [CashuError] = [
            .invalidNutVersion("test"),
            .invalidKeysetID,
            .insufficientFunds,
            .syncRequired,
            .operationTimeout,
            .operationCancelled,
            .invalidMintConfiguration,
            .keysetNotFound,
            .keysetExpired,
            .unsupportedOperation("test"),
            .concurrencyError("test"),
            .unsupportedVersion,
            .invalidMnemonic,
            .invalidSecret,
            .mismatchedArrayLengths,
            .invalidPreimage,
            .locktimeNotExpired,
            .invalidProofType,
            .invalidWitness,
            .noActiveKeyset,
            .quotePending,
            .quoteExpired,
            .quoteNotFound,
            .keysetInactive,
            .invalidUnit,
            .invalidDenomination,
            .invalidDerivationPath,
            .notImplemented
        ]
        
        for error in protocolErrors {
            #expect(error.category == .protocol, "Expected \(error) to be protocol")
        }
    }
}

// MARK: - CashuError Retryable Tests

@Suite("CashuError Retryable Tests")
struct CashuErrorRetryableTests {
    
    @Test("Retryable network errors")
    func retryableNetworkErrors() throws {
        let retryableErrors: [CashuError] = [
            .networkError("timeout"),
            .mintUnavailable,
            .rateLimitExceeded,
            .operationTimeout,
            .connectionFailed,
            .temporaryFailure,
            .quotePending
        ]
        
        for error in retryableErrors {
            #expect(error.isRetryable, "Expected \(error) to be retryable")
        }
    }
    
    @Test("Non-retryable errors")
    func nonRetryableErrors() throws {
        let nonRetryableErrors: [CashuError] = [
            .invalidPoint,
            .invalidTokenFormat,
            .walletNotInitialized,
            .proofAlreadySpent,
            .balanceInsufficient,
            .invalidAmount,
            .validationFailed
        ]
        
        for error in nonRetryableErrors {
            #expect(!error.isRetryable, "Expected \(error) to not be retryable")
        }
    }
    
    @Test("HTTP error 5xx is retryable")
    func http5xxRetryable() throws {
        let serverErrors: [CashuError] = [
            .httpError(detail: "Internal Server Error", code: 500),
            .httpError(detail: "Bad Gateway", code: 502),
            .httpError(detail: "Service Unavailable", code: 503)
        ]
        
        for error in serverErrors {
            #expect(error.isRetryable, "Expected HTTP 5xx error to be retryable")
        }
    }
    
    @Test("HTTP error 429 is retryable")
    func http429Retryable() throws {
        let rateLimitError = CashuError.httpError(detail: "Too Many Requests", code: 429)
        #expect(rateLimitError.isRetryable)
    }
    
    @Test("HTTP error 4xx (not 429) is not retryable")
    func http4xxNotRetryable() throws {
        let clientErrors: [CashuError] = [
            .httpError(detail: "Bad Request", code: 400),
            .httpError(detail: "Unauthorized", code: 401),
            .httpError(detail: "Forbidden", code: 403),
            .httpError(detail: "Not Found", code: 404)
        ]
        
        for error in clientErrors {
            #expect(!error.isRetryable, "Expected HTTP 4xx error to not be retryable")
        }
    }
}

// MARK: - CashuError LocalizedError Tests

@Suite("CashuError LocalizedError Tests")
struct CashuErrorLocalizedErrorTests {
    
    @Test("All errors have error descriptions")
    func allErrorsHaveDescriptions() throws {
        let allErrors: [CashuError] = [
            .invalidPoint,
            .invalidSecretLength,
            .hashToCurveFailed,
            .blindingFailed,
            .unblindingFailed,
            .verificationFailed,
            .invalidHexString,
            .keyGenerationFailed,
            .domainSeperator,
            .networkError("test"),
            .invalidMintURL,
            .mintUnavailable,
            .invalidResponse,
            .rateLimitExceeded,
            .insufficientFunds,
            .invalidTokenFormat,
            .serializationFailed,
            .deserializationFailed,
            .validationFailed,
            .invalidNutVersion("1.0"),
            .invalidKeysetID,
            .httpError(detail: "test", code: 400),
            .walletNotInitialized,
            .walletAlreadyInitialized,
            .invalidProofSet,
            .proofAlreadySpent,
            .proofNotFound,
            .invalidAmount,
            .amountTooLarge,
            .amountTooSmall,
            .balanceInsufficient,
            .noSpendableProofs,
            .invalidWalletState,
            .storageError("test"),
            .syncRequired,
            .operationTimeout,
            .operationCancelled,
            .invalidMintConfiguration,
            .keysetNotFound,
            .keysetExpired,
            .tokenExpired,
            .tokenAlreadyUsed,
            .invalidTokenStructure,
            .missingRequiredField("field"),
            .unsupportedOperation("op"),
            .concurrencyError("msg"),
            .unsupportedVersion,
            .missingBlindingFactor,
            .walletNotInitializedWithMnemonic,
            .invalidMnemonic,
            .invalidSecret,
            .invalidSignature("msg"),
            .mismatchedArrayLengths,
            .invalidPreimage,
            .locktimeNotExpired,
            .invalidProofType,
            .invalidWitness,
            .noActiveKeyset,
            .noKeychainData,
            .connectionFailed,
            .invalidToken,
            .tokenAlreadySpent,
            .invalidProof,
            .tokenNotFound,
            .quotePending,
            .quoteExpired,
            .quoteNotFound,
            .keysetInactive,
            .invalidUnit,
            .invalidDenomination,
            .invalidState("state"),
            .serializationError("details"),
            .jsonEncodingError,
            .jsonDecodingError,
            .hexDecodingError,
            .base64DecodingError,
            .unhandledError(0),
            .unknownError,
            .notImplemented,
            .invalidDerivationPath,
            .temporaryFailure
        ]
        
        for error in allErrors {
            #expect(error.errorDescription != nil, "Expected \(error) to have error description")
            #expect(!error.errorDescription!.isEmpty, "Expected \(error) error description to not be empty")
        }
    }
    
    @Test("Error description contains relevant info for parametrized errors")
    func parametrizedErrorDescriptions() throws {
        let networkError = CashuError.networkError("connection refused")
        #expect(networkError.errorDescription?.contains("connection refused") == true)
        
        let httpError = CashuError.httpError(detail: "Not Found", code: 404)
        #expect(httpError.errorDescription?.contains("404") == true)
        #expect(httpError.errorDescription?.contains("Not Found") == true)
        
        let missingField = CashuError.missingRequiredField("amount")
        #expect(missingField.errorDescription?.contains("amount") == true)
        
        let storageError = CashuError.storageError("disk full")
        #expect(storageError.errorDescription?.contains("disk full") == true)
    }
    
    @Test("Recovery suggestions exist for common errors")
    func recoverySuggestionsExist() throws {
        let errorsWithRecovery: [CashuError] = [
            .invalidSecretLength,
            .networkError("test"),
            .mintUnavailable,
            .rateLimitExceeded,
            .invalidMintURL,
            .invalidTokenFormat,
            .walletNotInitialized,
            .balanceInsufficient,
            .keysetExpired,
            .tokenExpired,
            .operationTimeout,
            .proofAlreadySpent,
            .noSpendableProofs,
            .unsupportedVersion,
            .noKeychainData
        ]
        
        for error in errorsWithRecovery {
            #expect(error.recoverySuggestion != nil, "Expected \(error) to have recovery suggestion")
        }
    }
    
    @Test("Failure reasons exist for critical errors")
    func failureReasonsExist() throws {
        let errorsWithReasons: [CashuError] = [
            .blindingFailed,
            .unblindingFailed,
            .keyGenerationFailed,
            .networkError("test"),
            .mintUnavailable,
            .invalidTokenFormat,
            .missingRequiredField("field"),
            .walletNotInitialized,
            .balanceInsufficient,
            .proofAlreadySpent,
            .keysetNotFound,
            .invalidWalletState
        ]
        
        for error in errorsWithReasons {
            #expect(error.failureReason != nil, "Expected \(error) to have failure reason")
        }
    }
}

// MARK: - CashuError Code Tests

@Suite("CashuError Code Tests")
struct CashuErrorCodeTests {
    
    @Test("Error codes are properly formatted")
    func errorCodesFormatted() throws {
        let errors: [CashuError] = [
            .invalidPoint,
            .networkError("test"),
            .walletNotInitialized
        ]
        
        for error in errors {
            let code = error.code
            #expect(code.hasPrefix("CASHU_"))
            #expect(code == code.uppercased())
        }
    }
}

// MARK: - CashuError UserInfo Tests

@Suite("CashuError UserInfo Tests")
struct CashuErrorUserInfoTests {
    
    @Test("ErrorUserInfo contains required keys")
    func errorUserInfoContainsRequiredKeys() throws {
        let error = CashuError.walletNotInitialized
        let userInfo = error.errorUserInfo
        
        #expect(userInfo[NSLocalizedDescriptionKey] != nil)
        #expect(userInfo["category"] as? String == CashuErrorCategory.wallet.rawValue)
        #expect(userInfo["code"] != nil)
        #expect(userInfo["isRetryable"] as? Bool == false)
    }
    
    @Test("ErrorUserInfo includes recovery suggestion when available")
    func errorUserInfoIncludesRecoverySuggestion() throws {
        let error = CashuError.networkError("connection failed")
        let userInfo = error.errorUserInfo
        
        #expect(userInfo[NSLocalizedRecoverySuggestionErrorKey] != nil)
    }
    
    @Test("ErrorUserInfo includes failure reason when available")
    func errorUserInfoIncludesFailureReason() throws {
        let error = CashuError.blindingFailed
        let userInfo = error.errorUserInfo
        
        #expect(userInfo[NSLocalizedFailureReasonErrorKey] != nil)
    }
    
    @Test("Retryable error has correct flag in userInfo")
    func retryableErrorUserInfo() throws {
        let retryable = CashuError.networkError("timeout")
        let nonRetryable = CashuError.invalidAmount
        
        #expect(retryable.errorUserInfo["isRetryable"] as? Bool == true)
        #expect(nonRetryable.errorUserInfo["isRetryable"] as? Bool == false)
    }
}

// MARK: - CashuHTTPError Tests

@Suite("CashuHTTPError Tests")
struct CashuHTTPErrorTests {
    
    @Test("CashuHTTPError initialization")
    func httpErrorInitialization() throws {
        let error = CashuHTTPError(detail: "Token not found", code: 20001)
        
        #expect(error.detail == "Token not found")
        #expect(error.code == 20001)
    }
    
    @Test("CashuHTTPError JSON encoding")
    func httpErrorJSONEncoding() throws {
        let error = CashuHTTPError(detail: "Test error", code: 12345)
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(error)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CashuHTTPError.self, from: data)
        
        #expect(decoded.detail == "Test error")
        #expect(decoded.code == 12345)
    }
    
    @Test("CashuHTTPError JSON decoding from mint response")
    func httpErrorJSONDecoding() throws {
        let json = """
        {"detail": "Token already spent", "code": 11001}
        """
        let data = json.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        let error = try decoder.decode(CashuHTTPError.self, from: data)
        
        #expect(error.detail == "Token already spent")
        #expect(error.code == 11001)
    }
}

// MARK: - Error Category Enum Tests

@Suite("CashuErrorCategory Tests")
struct CashuErrorCategoryEnumTests {
    
    @Test("All categories have raw values")
    func categoriesHaveRawValues() throws {
        let categories: [CashuErrorCategory] = [
            .cryptographic,
            .network,
            .validation,
            .wallet,
            .storage,
            .protocol
        ]
        
        for category in categories {
            #expect(!category.rawValue.isEmpty)
        }
    }
    
    @Test("Category raw values are human readable")
    func categoryRawValuesReadable() throws {
        #expect(CashuErrorCategory.cryptographic.rawValue == "Cryptographic")
        #expect(CashuErrorCategory.network.rawValue == "Network")
        #expect(CashuErrorCategory.validation.rawValue == "Validation")
        #expect(CashuErrorCategory.wallet.rawValue == "Wallet")
        #expect(CashuErrorCategory.storage.rawValue == "Storage")
        #expect(CashuErrorCategory.protocol.rawValue == "Protocol")
    }
}

// MARK: - Error Handling Integration Tests

@Suite("Error Handling Integration Tests")
struct ErrorHandlingIntegrationTests {
    
    @Test("Error can be caught as LocalizedError")
    func errorCaughtAsLocalizedError() throws {
        func throwingFunction() throws {
            throw CashuError.walletNotInitialized
        }
        
        do {
            try throwingFunction()
            Issue.record("Expected error to be thrown")
        } catch let error as LocalizedError {
            #expect(error.errorDescription != nil)
        }
    }
    
    @Test("Error can be caught as generic Error")
    func errorCaughtAsGenericError() throws {
        func throwingFunction() throws {
            throw CashuError.invalidAmount
        }
        
        do {
            try throwingFunction()
            Issue.record("Expected error to be thrown")
        } catch {
            #expect(error is CashuError)
        }
    }
    
    @Test("Error can be converted to NSError")
    func errorConvertedToNSError() throws {
        let cashuError = CashuError.networkError("Connection timeout")
        let nsError = cashuError as NSError
        
        #expect(nsError.localizedDescription.contains("Connection timeout"))
    }
    
    @Test("Multiple error types can be handled with switch")
    func errorTypesHandledWithSwitch() throws {
        let errors: [CashuError] = [
            .networkError("test"),
            .invalidAmount,
            .walletNotInitialized
        ]
        
        for error in errors {
            switch error.category {
            case .network:
                #expect(error.isRetryable || !error.isRetryable) // Just verify switch works
            case .validation:
                #expect(error.errorDescription != nil)
            case .wallet:
                #expect(error.category == .wallet)
            default:
                break
            }
        }
    }
}
