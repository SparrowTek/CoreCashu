//
//  MintResponseDecodingTests.swift
//  CoreCashu
//
//  Regression tests decoding verbatim mint JSON (snake_case, as sent on the wire)
//  through the same decoder the NetworkRouter uses. Guards against a key-strategy
//  regression where `convertFromSnakeCase` rewrote JSON keys before the DTOs'
//  explicit CodingKeys were matched, silently nil-ing fields such as
//  `fee_reserve` and `input_fee_ppk` and mangling `MintInfo.nuts` payload keys.
//

import Testing
import Foundation
@testable import CoreCashu

@Suite("Mint response wire-format decoding")
struct MintResponseDecodingTests {

    private let decoder = JSONDecoder.cashuDecoder

    @Test
    func meltQuoteResponseKeepsFeeReserve() throws {
        let json = Data("""
        {
            "quote": "TRmjduhIsPxd9YWKZikuRi6g",
            "amount": 10,
            "unit": "sat",
            "state": "UNPAID",
            "expiry": 1701704757,
            "fee_reserve": 2
        }
        """.utf8)

        let response = try decoder.decode(PostMeltQuoteResponse.self, from: json)
        #expect(response.feeReserve == 2)
        #expect(response.totalAmountWithFeeReserve == 12)
        #expect(response.supportsFeeReturn)
    }

    @Test
    func keysetsResponseKeepsInputFeePpk() throws {
        let json = Data("""
        {
            "keysets": [
                {
                    "id": "0088553333AABBCC",
                    "unit": "sat",
                    "active": true,
                    "input_fee_ppk": 100
                }
            ]
        }
        """.utf8)

        let response = try decoder.decode(GetKeysetsResponse.self, from: json)
        #expect(response.keysets.first?.inputFeePpk == 100)
    }

    @Test
    func mintInfoKeepsSnakeCaseFieldsAndNutSettings() throws {
        let json = Data("""
        {
            "name": "Bob's Cashu mint",
            "pubkey": "0283bf290884eed3a7ca2663fc0260de2e2064d6b355ea13f98dec004b7a7ead99",
            "version": "Nutshell/0.15.0",
            "description": "The short mint description",
            "description_long": "A longer mint description that can be a long piece of text.",
            "icon_url": "https://mint.host/icon.jpg",
            "tos_url": "https://mint.host/tos",
            "nuts": {
                "4": {
                    "methods": [
                        {"method": "bolt11", "unit": "sat", "min_amount": 0, "max_amount": 10000}
                    ],
                    "disabled": false
                },
                "5": {
                    "methods": [
                        {"method": "bolt11", "unit": "sat", "min_amount": 100, "max_amount": 10000}
                    ],
                    "disabled": false
                }
            }
        }
        """.utf8)

        let info = try decoder.decode(MintInfo.self, from: json)
        #expect(info.descriptionLong == "A longer mint description that can be a long piece of text.")
        #expect(info.iconURL == "https://mint.host/icon.jpg")
        #expect(info.tosURL == "https://mint.host/tos")

        let mintSettings = try #require(info.getNUT04Settings())
        #expect(mintSettings.methods.first?.minAmount == 0)
        #expect(mintSettings.methods.first?.maxAmount == 10000)

        let meltSettings = try #require(info.getNUT05Settings())
        #expect(meltSettings.methods.first?.minAmount == 100)
        #expect(meltSettings.methods.first?.maxAmount == 10000)
        #expect(info.supportsBasicOperations())
    }

    @Test
    func routerDefaultDecoderMatchesWireFormat() throws {
        let json = Data("""
        {"quote": "q", "amount": 1, "unit": "sat", "state": "PAID", "expiry": 1, "fee_reserve": 3}
        """.utf8)

        // Same construction path as NetworkRouter's fallback decoder.
        let response = try JSONDecoder().decode(PostMeltQuoteResponse.self, from: json)
        #expect(response.feeReserve == 3)
    }
}
