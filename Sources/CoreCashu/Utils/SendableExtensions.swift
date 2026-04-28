import Foundation
import P256K

// P256K 0.23+ declares Sendable conformances on its key types directly
// (KeyAgreement.PublicKey, Schnorr.XonlyKey, etc.). Earlier versions did not,
// so this file used to add a `@unchecked @retroactive Sendable` shim. Keeping
// this file as a documentation anchor in case we need to add bridging again.
