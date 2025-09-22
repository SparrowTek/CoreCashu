import Foundation
@preconcurrency import P256K

/// Cashu assumes P256K public keys are immutable data wrappers, so we can safely
/// treat them as Sendable across concurrency domains.
extension P256K.KeyAgreement.PublicKey: @unchecked @retroactive Sendable {}
