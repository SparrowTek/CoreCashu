import Foundation
@preconcurrency import P256K
@testable import CoreCashu

/// In-process Cashu mint that conforms to ``Networking`` so it can be injected into
/// `CashuWallet` via the existing dependency-injection seam (CashuWallet+Configuration's
/// `networking` parameter).
///
/// Backed by real BDHKE crypto (the same `Mint` struct used in NUT00.swift), which means
/// signatures the wallet receives actually verify under the mint's public keys, and round-trip
/// proofs can be re-presented for swap/melt without the mock having to fake any cryptography.
///
/// State is held by an internal actor; the `Networking` adapter is a small `Sendable` shim that
/// forwards each `URLRequest` into the actor for handling.
///
/// Coverage:
/// - GET  /v1/info
/// - GET  /v1/keys
/// - GET  /v1/keys/{keyset_id}
/// - GET  /v1/keysets
/// - POST /v1/mint/quote/bolt11
/// - GET  /v1/mint/quote/bolt11/{id}
/// - POST /v1/mint/bolt11
/// - POST /v1/melt/quote/bolt11
/// - GET  /v1/melt/quote/bolt11/{id}
/// - POST /v1/melt/bolt11
/// - POST /v1/swap
/// - POST /v1/checkstate
public final class MockMint: Sendable {

    public struct Configuration: Sendable {
        public let unit: String
        /// Powers-of-two denominations the mint will sign for. Must be sorted ascending.
        public let denominations: [Int]
        /// Initial state of NUT-04. If `false`, mint quote/mint endpoints respond with 503.
        public let mintEnabled: Bool
        /// Initial state of NUT-05. If `false`, melt endpoints respond with 503.
        public let meltEnabled: Bool
        /// Auto-mark a mint quote as PAID immediately after issuance (for tests that don't
        /// want to flip the paid bit explicitly). Defaults to true.
        public let autoPayMintQuotes: Bool
        /// Mint name surfaced in /v1/info responses.
        public let name: String
        /// Optional NUTs to *exclude* from the `/v1/info` `nuts` map. Used by capability-gating
        /// tests that need to assert wallet-level operations refuse to execute when the mint
        /// does not advertise the NUT (e.g. P2PK or HTLC unavailable). The mint always
        /// advertises the required NUTs (1/2/3/4/5/6); excluding those is unsupported.
        public let advertisedNUTsExclude: Set<String>

        public init(
            unit: String = "sat",
            denominations: [Int] = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192],
            mintEnabled: Bool = true,
            meltEnabled: Bool = true,
            autoPayMintQuotes: Bool = true,
            name: String = "MockMint",
            advertisedNUTsExclude: Set<String> = []
        ) {
            self.unit = unit
            self.denominations = denominations
            self.mintEnabled = mintEnabled
            self.meltEnabled = meltEnabled
            self.autoPayMintQuotes = autoPayMintQuotes
            self.name = name
            self.advertisedNUTsExclude = advertisedNUTsExclude
        }
    }

    public let configuration: Configuration
    /// Active keyset id, derived from the public-key map per NUT-02.
    public let keysetID: String
    /// Public-key hex per amount (compressed, 66 hex chars).
    public let publicKeysHex: [Int: String]

    private let state: State

    /// Swap the shared `CashuEnvironment.current.routerDelegate` for a permissive variant so
    /// integration tests don't trip over the production rate limiter. Idempotent, safe to call
    /// from setUp blocks. Mock-mint instances rely on this; if a test doesn't construct one,
    /// it can call this helper directly.
    @CashuActor
    public static func installTestRouterDelegate() {
        let delegate = CashuRouterDelegate(policy: .testPermissive)
        CashuEnvironment.current.setRouterDelegate(delegate)
    }

    public init(configuration: Configuration = Configuration()) async throws {
        await Self.installTestRouterDelegate()
        self.configuration = configuration

        // Generate one keypair per supported amount.
        var keypairs: [Int: MintKeypair] = [:]
        var pubHex: [Int: String] = [:]
        for amount in configuration.denominations {
            let kp = try MintKeypair()
            keypairs[amount] = kp
            pubHex[amount] = kp.publicKey.dataRepresentation.hexString
        }
        self.publicKeysHex = pubHex

        // Build the amount→hex map and derive a NUT-02 keyset id.
        var keyMap: [String: String] = [:]
        for (amount, hex) in pubHex {
            keyMap[String(amount)] = hex
        }
        self.keysetID = KeysetID.deriveKeysetID(from: keyMap)

        self.state = State(
            keysetID: self.keysetID,
            keypairs: keypairs,
            keyMap: keyMap,
            configuration: configuration
        )
    }

    // MARK: - Public test affordances

    /// Mark a previously-issued mint quote as paid so the wallet's mint call succeeds.
    public func markMintQuotePaid(_ quoteID: String) async {
        await state.markMintQuotePaid(quoteID)
    }

    /// Force a melt quote into the given state for tests that want to drive specific paths.
    public func setMeltQuoteState(_ quoteID: String, to newState: MeltQuoteState) async {
        await state.setMeltQuoteState(quoteID, to: newState)
    }

    /// Number of mint quotes issued. Useful for "did the wallet call the mint?" assertions.
    public func mintQuoteCount() async -> Int { await state.mintQuoteCount() }

    /// Number of swap requests served.
    public func swapCount() async -> Int { await state.swapCount() }

    /// Number of melt requests served.
    public func meltCount() async -> Int { await state.meltCount() }

    /// Set the spent state for a specific Y (used to test the wallet's read-spent path).
    public func markYSpent(_ Y: String) async { await state.markYSpent(Y) }

    /// Returns whether the given proof has been seen by the mint as spent.
    public func isProofSpent(_ proof: Proof) async throws -> Bool {
        let Y = try proof.calculateY()
        return await state.isYSpent(Y)
    }

    /// `Networking` adapter for injection into `CashuWallet`.
    public var networking: any Networking { Adapter(state: state) }

    // MARK: - Networking adapter

    private struct Adapter: Networking {
        let state: State
        func data(for request: URLRequest, delegate: (any URLSessionTaskDelegate)?) async throws -> (Data, URLResponse) {
            try await state.handle(request: request)
        }
    }

    // MARK: - State actor

    fileprivate actor State {
        private let keysetID: String
        private let keypairs: [Int: MintKeypair]
        private let keyMap: [String: String]
        private let configuration: Configuration

        private var mintQuotes: [String: MintQuote] = [:]
        private var meltQuotes: [String: MeltQuote] = [:]
        private var spentYs: Set<String> = []
        private var seenIdempotencyKeys: [String: Data] = [:]
        private var quoteCounter: Int = 0
        private(set) var swapTotal: Int = 0
        private(set) var meltTotal: Int = 0

        /// NUT-09 restore-cache: every (B_, BlindSignature) we've ever signed, keyed by the
        /// blinded-message hex (`B_` field). The wallet sends the deterministic outputs back and
        /// we return every match. Real mints persist this in their own database.
        private var signedOutputs: [String: (output: BlindedMessage, signature: BlindSignature)] = [:]

        init(keysetID: String, keypairs: [Int: MintKeypair], keyMap: [String: String], configuration: Configuration) {
            self.keysetID = keysetID
            self.keypairs = keypairs
            self.keyMap = keyMap
            self.configuration = configuration
        }

        private struct MintQuote: Sendable {
            var id: String
            var amount: Int
            var unit: String
            var paid: Bool
            var issued: Bool
            var expiry: Int
            var paymentRequest: String
        }

        private struct MeltQuote: Sendable {
            var id: String
            var paymentRequest: String
            var amount: Int
            var unit: String
            var feeReserve: Int
            var state: MeltQuoteState
            var expiry: Int
        }

        // MARK: - Public actor API

        func markMintQuotePaid(_ id: String) {
            if var quote = mintQuotes[id] {
                quote.paid = true
                mintQuotes[id] = quote
            }
        }

        func setMeltQuoteState(_ id: String, to newState: MeltQuoteState) {
            if var quote = meltQuotes[id] {
                quote.state = newState
                meltQuotes[id] = quote
            }
        }

        func mintQuoteCount() -> Int { mintQuotes.count }
        func swapCount() -> Int { swapTotal }
        func meltCount() -> Int { meltTotal }

        func markYSpent(_ Y: String) { spentYs.insert(Y.lowercased()) }
        func isYSpent(_ Y: String) -> Bool { spentYs.contains(Y.lowercased()) }

        // MARK: - Request dispatch

        func handle(request: URLRequest) async throws -> (Data, URLResponse) {
            guard let url = request.url else {
                return reply(status: 400, body: errorBody(detail: "missing URL"))
            }
            let method = (request.httpMethod ?? "GET").uppercased()

            // Cache idempotent POSTs by Idempotency-Key, even though the wallet doesn't currently
            // re-send. Mirrors NUT-19 and lets us write deterministic regression tests later.
            let idempotencyKey = request.value(forHTTPHeaderField: "Idempotency-Key").map { method + ":" + url.path + ":" + $0 }
            if method == "POST", let key = idempotencyKey, let cached = seenIdempotencyKeys[key] {
                return reply(status: 200, body: cached)
            }

            let path = url.path
            let segments = path.split(separator: "/").map(String.init)

            do {
                let body = try await dispatch(method: method, segments: segments, request: request)
                if method == "POST", let key = idempotencyKey { seenIdempotencyKeys[key] = body }
                return reply(status: 200, body: body)
            } catch let handlerError as HandlerError {
                return reply(status: handlerError.status, body: errorBody(detail: handlerError.detail))
            }
        }

        private func dispatch(method: String, segments: [String], request: URLRequest) async throws -> Data {
            switch (method, segments) {
            case ("GET", ["v1", "info"]):
                return try infoBody()
            case ("GET", ["v1", "keys"]):
                return try activeKeysBody()
            case ("GET", ["v1", "keysets"]):
                return try keysetsBody()
            case ("POST", ["v1", "mint", "quote", "bolt11"]):
                try requireMintEnabled()
                return try encode(try mintQuote(requestBody: try requireBody(request: request)))
            case ("POST", ["v1", "mint", "bolt11"]):
                try requireMintEnabled()
                return try encode(try mintExecute(requestBody: try requireBody(request: request)))
            case ("POST", ["v1", "melt", "quote", "bolt11"]):
                try requireMeltEnabled()
                return try encode(try meltQuote(requestBody: try requireBody(request: request)))
            case ("POST", ["v1", "melt", "bolt11"]):
                try requireMeltEnabled()
                return try encode(try meltExecute(requestBody: try requireBody(request: request)))
            case ("POST", ["v1", "swap"]):
                return try encode(try swap(requestBody: try requireBody(request: request)))
            case ("POST", ["v1", "checkstate"]):
                return try encode(try checkState(requestBody: try requireBody(request: request)))
            case ("POST", ["v1", "restore"]):
                return try encode(try restoreHandler(requestBody: try requireBody(request: request)))
            default:
                break
            }

            // Variable-arity routes (paths with trailing IDs).
            if method == "GET", segments.count == 3, segments[0] == "v1", segments[1] == "keys" {
                return try keysForKeyset(id: segments[2])
            }
            if method == "GET", segments.count == 5, segments[0] == "v1", segments[1] == "mint",
               segments[2] == "quote", segments[3] == "bolt11" {
                let quoteID = segments[4]
                guard let quote = mintQuotes[quoteID] else {
                    throw HandlerError(status: 404, detail: "unknown quote \(quoteID)")
                }
                return try encode(mintQuoteResponse(from: quote))
            }
            if method == "GET", segments.count == 5, segments[0] == "v1", segments[1] == "melt",
               segments[2] == "quote", segments[3] == "bolt11" {
                let quoteID = segments[4]
                guard let quote = meltQuotes[quoteID] else {
                    throw HandlerError(status: 404, detail: "unknown quote \(quoteID)")
                }
                return try encode(meltQuoteResponse(from: quote))
            }
            throw HandlerError(status: 404, detail: "unhandled \(method) /\(segments.joined(separator: "/"))")
        }

        private func requireMintEnabled() throws {
            guard configuration.mintEnabled else {
                throw HandlerError(status: 503, detail: "mint disabled")
            }
        }

        private func requireMeltEnabled() throws {
            guard configuration.meltEnabled else {
                throw HandlerError(status: 503, detail: "melt disabled")
            }
        }

        // MARK: - Endpoint handlers

        private func infoBody() throws -> Data {
            let methods: [[String: Any]] = [[
                "method": "bolt11",
                "unit": configuration.unit
            ]]

            var nuts: [String: Any] = [
                "1": ["supported": true],
                "2": ["supported": true],
                "3": ["supported": true],
                "4": [
                    "methods": methods,
                    "disabled": !configuration.mintEnabled
                ],
                "5": [
                    "methods": methods,
                    "disabled": !configuration.meltEnabled
                ],
                "6": ["supported": true],
                "7": ["supported": true],
                "8": ["supported": true],
                "9": ["supported": true],
                "10": ["supported": true],
                "11": ["supported": true],
                "12": ["supported": true],
                "14": ["supported": true]
            ]
            for excluded in configuration.advertisedNUTsExclude {
                nuts.removeValue(forKey: excluded)
            }

            let info: [String: Any] = [
                "name": configuration.name,
                "pubkey": "02" + String(repeating: "ab", count: 32),
                "version": "MockMint/0.1.0",
                "description": "Mock mint for CoreCashu integration tests",
                "nuts": nuts
            ]
            return try JSONSerialization.data(withJSONObject: info, options: [])
        }

        private func activeKeysBody() throws -> Data {
            let keyset = Keyset(id: keysetID, unit: configuration.unit, keys: keyMap)
            return try encode(GetKeysResponse(keysets: [keyset]))
        }

        private func keysForKeyset(id: String) throws -> Data {
            // Currently only one keyset is served; if the requested id matches, return it.
            // Otherwise, return an empty list (the spec lets the wallet decide what to do).
            let keysets: [Keyset] = id == keysetID ? [Keyset(id: keysetID, unit: configuration.unit, keys: keyMap)] : []
            return try encode(GetKeysResponse(keysets: keysets))
        }

        private func keysetsBody() throws -> Data {
            let info = KeysetInfo(id: keysetID, unit: configuration.unit, active: true, inputFeePpk: 0)
            return try encode(GetKeysetsResponse(keysets: [info]))
        }

        private func mintQuote(requestBody: Data) throws -> MintQuoteResponse {
            let req = try JSONDecoder.cashuDecoder.decode(MintQuoteRequest.self, from: requestBody)
            guard req.unit == configuration.unit else {
                throw HandlerError(status: 400, detail: "unit mismatch: expected \(configuration.unit), got \(req.unit)")
            }
            guard let amount = req.amount, amount > 0 else {
                throw HandlerError(status: 400, detail: "amount required")
            }
            quoteCounter += 1
            let id = "mint_quote_\(quoteCounter)"
            // Mock invoices must be valid Bech32-charset strings (NUTValidation rejects
            // anything else). The "lnbc" prefix plus amount plus the suffix `q1` plus a
            // bech32-encoded counter satisfies the wallet's invoice validator.
            let invoice = "lnbc\(amount)q1\(bech32Counter(quoteCounter))"
            let quote = MintQuote(
                id: id,
                amount: amount,
                unit: req.unit,
                paid: configuration.autoPayMintQuotes,
                issued: false,
                expiry: Int(Date().timeIntervalSince1970) + 3600,
                paymentRequest: invoice
            )
            mintQuotes[id] = quote
            return mintQuoteResponse(from: quote)
        }

        private func mintQuoteResponse(from quote: MintQuote) -> MintQuoteResponse {
            let state: String
            if quote.issued { state = "ISSUED" }
            else if quote.paid { state = "PAID" }
            else { state = "UNPAID" }
            return MintQuoteResponse(
                quote: quote.id,
                request: quote.paymentRequest,
                unit: quote.unit,
                paid: quote.paid,
                expiry: quote.expiry,
                state: state
            )
        }

        private func mintExecute(requestBody: Data) throws -> MintResponse {
            let req = try JSONDecoder.cashuDecoder.decode(MintRequest.self, from: requestBody)
            guard var quote = mintQuotes[req.quote] else {
                throw HandlerError(status: 404, detail: "unknown quote")
            }
            guard quote.paid else {
                throw HandlerError(status: 400, detail: "quote not paid")
            }
            guard !quote.issued else {
                throw HandlerError(status: 400, detail: "quote already issued")
            }
            let totalOut = req.outputs.reduce(0) { $0 + $1.amount }
            guard totalOut == quote.amount else {
                throw HandlerError(status: 400, detail: "output total \(totalOut) != quote amount \(quote.amount)")
            }
            let signatures = try sign(outputs: req.outputs)
            quote.issued = true
            mintQuotes[req.quote] = quote
            return MintResponse(signatures: signatures)
        }

        private func meltQuote(requestBody: Data) throws -> PostMeltQuoteResponse {
            let req = try JSONDecoder.cashuDecoder.decode(PostMeltQuoteRequest.self, from: requestBody)
            guard !req.request.isEmpty, req.unit == configuration.unit else {
                throw HandlerError(status: 400, detail: "invalid melt quote request")
            }
            // Pull a fake amount out of the invoice string for deterministic tests.
            // Format: "lnbcmock<amount><suffix>" — falls back to 100 if absent.
            let amount = parseAmountFromInvoice(req.request) ?? 100
            quoteCounter += 1
            let id = "melt_quote_\(quoteCounter)"
            let quote = MeltQuote(
                id: id,
                paymentRequest: req.request,
                amount: amount,
                unit: req.unit,
                feeReserve: 0,
                state: .unpaid,
                expiry: Int(Date().timeIntervalSince1970) + 3600
            )
            meltQuotes[id] = quote
            return meltQuoteResponse(from: quote)
        }

        private func meltQuoteResponse(from quote: MeltQuote) -> PostMeltQuoteResponse {
            return PostMeltQuoteResponse(
                quote: quote.id,
                amount: quote.amount,
                unit: quote.unit,
                state: quote.state,
                expiry: quote.expiry,
                feeReserve: quote.feeReserve
            )
        }

        private func meltExecute(requestBody: Data) throws -> PostMeltResponse {
            let req = try JSONDecoder.cashuDecoder.decode(PostMeltRequest.self, from: requestBody)
            guard var quote = meltQuotes[req.quote] else {
                throw HandlerError(status: 404, detail: "unknown melt quote")
            }
            guard quote.state == .unpaid else {
                throw HandlerError(status: 400, detail: "melt already \(quote.state.rawValue.lowercased())")
            }
            let inputTotal = req.inputs.reduce(0) { $0 + $1.amount }
            let needed = quote.amount + quote.feeReserve
            guard inputTotal >= needed else {
                throw HandlerError(status: 400, detail: "inputs \(inputTotal) < needed \(needed)")
            }
            // Verify and consume each input.
            for proof in req.inputs {
                try verifyAndConsume(proof: proof)
            }
            // No fee return for now; if outputs are provided, we sign them but with zero amount each.
            let change: [BlindSignature]?
            if let outputs = req.outputs, !outputs.isEmpty {
                // For the simple mock we never actually return change — fee reserve is zero.
                change = []
            } else {
                change = nil
            }
            quote.state = .paid
            meltQuotes[req.quote] = quote
            meltTotal += 1
            return PostMeltResponse(state: .paid, change: change)
        }

        private func swap(requestBody: Data) throws -> PostSwapResponse {
            let req = try JSONDecoder.cashuDecoder.decode(PostSwapRequest.self, from: requestBody)
            let inputTotal = req.inputs.reduce(0) { $0 + $1.amount }
            let outputTotal = req.outputs.reduce(0) { $0 + $1.amount }
            guard inputTotal == outputTotal else {
                throw HandlerError(status: 400, detail: "input total \(inputTotal) != output total \(outputTotal)")
            }
            for proof in req.inputs {
                try verifyAndConsume(proof: proof)
            }
            let signatures = try sign(outputs: req.outputs)
            swapTotal += 1
            return PostSwapResponse(signatures: signatures)
        }

        private func checkState(requestBody: Data) throws -> PostCheckStateResponse {
            let req = try JSONDecoder.cashuDecoder.decode(PostCheckStateRequest.self, from: requestBody)
            let states = req.Ys.map { Y -> ProofStateInfo in
                let isSpent = spentYs.contains(Y.lowercased())
                return ProofStateInfo(Y: Y, state: isSpent ? .spent : .unspent, witness: nil)
            }
            return PostCheckStateResponse(states: states)
        }

        // MARK: - Helpers

        private func sign(outputs: [BlindedMessage]) throws -> [BlindSignature] {
            try outputs.map { message in
                guard let outputID = message.id else {
                    throw HandlerError(status: 400, detail: "missing output id")
                }
                guard outputID == keysetID else {
                    throw HandlerError(status: 400, detail: "unknown keyset \(outputID)")
                }
                guard let keypair = keypairs[message.amount] else {
                    throw HandlerError(status: 400, detail: "unsupported denomination \(message.amount)")
                }
                guard let blindData = Data(hexString: message.B_) else {
                    throw HandlerError(status: 400, detail: "B_ is not hex")
                }
                let mint = Mint(privateKey: keypair.privateKey)
                let blindSignatureData = try mint.signBlindedMessage(blindData)
                let signature = BlindSignature(amount: message.amount, id: keysetID, C_: blindSignatureData.hexString, dleq: nil)
                // NUT-09: persist (output, signature) so a future /v1/restore can find it.
                signedOutputs[message.B_] = (message, signature)
                return signature
            }
        }

        // NUT-09 restore: return the matching (output, signature) tuples for every input output
        // we've signed before. The order of outputs is preserved per spec.
        private func restoreHandler(requestBody: Data) throws -> PostRestoreResponse {
            let req = try JSONDecoder.cashuDecoder.decode(PostRestoreRequest.self, from: requestBody)
            var matchedOutputs: [BlindedMessage] = []
            var matchedSignatures: [BlindSignature] = []
            for output in req.outputs {
                if let pair = signedOutputs[output.B_] {
                    matchedOutputs.append(pair.output)
                    matchedSignatures.append(pair.signature)
                }
            }
            return PostRestoreResponse(outputs: matchedOutputs, signatures: matchedSignatures)
        }

        private func verifyAndConsume(proof: Proof) throws {
            guard proof.id == keysetID else {
                throw HandlerError(status: 400, detail: "proof from unknown keyset \(proof.id)")
            }
            guard let keypair = keypairs[proof.amount] else {
                throw HandlerError(status: 400, detail: "no key for amount \(proof.amount)")
            }
            guard let signatureData = Data(hexString: proof.C) else {
                throw HandlerError(status: 400, detail: "C is not hex")
            }

            // For BDHKE proofs (no spending condition), verify k * H_to_C(secret) == C against the
            // raw secret string. For NUT-10 well-known secrets (P2PK, HTLC, …) the cleartext
            // secret IS the JSON well-known string, but H_to_C is applied to that JSON exactly,
            // so this same check still works.
            let mint = Mint(privateKey: keypair.privateKey)
            guard try mint.verifyToken(secret: proof.secret, signature: signatureData) else {
                throw HandlerError(status: 400, detail: "invalid proof signature")
            }
            let Y = try proof.calculateY().lowercased()
            if spentYs.contains(Y) {
                throw HandlerError(status: 400, detail: "proof already spent")
            }
            spentYs.insert(Y)
        }

        private func parseAmountFromInvoice(_ invoice: String) -> Int? {
            // Mock invoices look like "lnbc<amount>q1<id>" (issued by `mintQuote`). Extract the
            // run of digits immediately after the `lnbc` / `lntb` / `lnbcrt` prefix.
            let prefixes = ["lnbcrt", "lnbc", "lntb"]
            guard let prefix = prefixes.first(where: { invoice.hasPrefix($0) }) else { return nil }
            let suffix = invoice.dropFirst(prefix.count)
            let digits = suffix.prefix { $0.isNumber }
            return Int(String(digits))
        }

        private func bech32Counter(_ value: Int) -> String {
            let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
            if value == 0 { return String(alphabet[0]) }
            var n = value
            var chars: [Character] = []
            while n > 0 {
                chars.append(alphabet[n % alphabet.count])
                n /= alphabet.count
            }
            return String(chars.reversed())
        }

        private func requireBody(request: URLRequest) throws -> Data {
            if let body = request.httpBody { return body }
            if let stream = request.httpBodyStream {
                return Data(reading: stream)
            }
            throw HandlerError(status: 400, detail: "missing request body")
        }

        private func encode<T: Encodable>(_ value: T) throws -> Data {
            // Use the default encoder (no `convertToSnakeCase`) because the response models
            // already declare explicit `CodingKeys` for any snake_case fields. Applying the
            // global strategy clobbers properties like `C_` and `B_` (turning them into `c_`
            // and `b_`), which then fail to decode on the wallet side.
            try JSONEncoder().encode(value)
        }

        private func errorBody(detail: String) -> Data {
            let payload: [String: Any] = ["detail": detail]
            return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        }

        private func reply(status: Int, body: Data) -> (Data, URLResponse) {
            let response = HTTPURLResponse(
                url: URL(string: "https://mock.mint")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (body, response)
        }

        private struct HandlerError: Error {
            let status: Int
            let detail: String
        }
    }
}

private extension Data {
    init(reading stream: InputStream) {
        self.init()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            self.append(buffer, count: read)
        }
    }
}
