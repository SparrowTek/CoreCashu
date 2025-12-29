//
//  NUT06Tests.swift
//  CoreCashu
//
//  Tests for NUT-06: Mint Information
//

import Testing
import Foundation
@testable import CoreCashu

// MARK: - NUT-06: Mint Information Tests

@Suite("NUT-06 Tests")
struct NUT06Tests {
    
    // MARK: - NutValue Tests
    
    @Test("NutValue string case")
    func nutValueStringCase() throws {
        let value = NutValue.string("1.0")
        #expect(value.stringValue == "1.0")
        #expect(value.dictionaryValue == nil)
    }
    
    @Test("NutValue dictionary case")
    func nutValueDictionaryCase() throws {
        let dict: [String: AnyCodable] = ["supported": AnyCodable(anyValue: true)!]
        let value = NutValue.dictionary(dict)
        #expect(value.stringValue == nil)
        #expect(value.dictionaryValue != nil)
    }
    
    @Test("NutValue JSON encoding/decoding string")
    func nutValueStringCoding() throws {
        let value = NutValue.string("1.0")
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(NutValue.self, from: data)
        
        #expect(decoded.stringValue == "1.0")
    }
    
    @Test("NutValue JSON encoding/decoding dictionary")
    func nutValueDictionaryCoding() throws {
        let json = """
        {"supported": true, "methods": ["bolt11"]}
        """
        let data = json.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(NutValue.self, from: data)
        
        #expect(decoded.dictionaryValue != nil)
    }
    
    // MARK: - MintContact Tests
    
    @Test("MintContact initialization")
    func mintContactInitialization() throws {
        let contact = MintContact(method: "email", info: "admin@mint.example.com")
        #expect(contact.method == "email")
        #expect(contact.info == "admin@mint.example.com")
    }
    
    @Test("MintContact JSON round trip")
    func mintContactCoding() throws {
        let contact = MintContact(method: "twitter", info: "@cashu_mint")
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(contact)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MintContact.self, from: data)
        
        #expect(decoded.method == "twitter")
        #expect(decoded.info == "@cashu_mint")
    }
    
    // MARK: - MintInfo Tests
    
    @Test("MintInfo minimal initialization")
    func mintInfoMinimalInit() throws {
        let info = MintInfo(name: "Test Mint", pubkey: "0123456789abcdef")
        #expect(info.name == "Test Mint")
        #expect(info.pubkey == "0123456789abcdef")
        #expect(info.version == nil)
        #expect(info.description == nil)
    }
    
    @Test("MintInfo full initialization")
    func mintInfoFullInit() throws {
        let contact = MintContact(method: "email", info: "test@example.com")
        let info = MintInfo(
            name: "Full Mint",
            pubkey: "abc123",
            version: "Nutshell/0.15.0",
            description: "A test mint",
            descriptionLong: "This is a longer description",
            contact: [contact],
            motd: "Welcome!",
            iconURL: "https://example.com/icon.png",
            urls: ["https://mint.example.com"],
            time: 1703865600,
            tosURL: "https://example.com/tos"
        )
        
        #expect(info.name == "Full Mint")
        #expect(info.version == "Nutshell/0.15.0")
        #expect(info.contact?.count == 1)
        #expect(info.motd == "Welcome!")
        #expect(info.iconURL == "https://example.com/icon.png")
        #expect(info.urls?.contains("https://mint.example.com") == true)
        #expect(info.time == 1703865600)
        #expect(info.tosURL == "https://example.com/tos")
    }
    
    @Test("MintInfo supportsNUT")
    func mintInfoSupportsNUT() throws {
        let nuts: [String: NutValue] = [
            "4": .string("supported"),
            "5": .string("supported")
        ]
        let info = MintInfo(name: "Test", pubkey: "abc", nuts: nuts)
        
        #expect(info.supportsNUT("4"))
        #expect(info.supportsNUT("5"))
        #expect(!info.supportsNUT("99"))
    }
    
    @Test("MintInfo getSupportedNUTs")
    func mintInfoGetSupportedNUTs() throws {
        let nuts: [String: NutValue] = [
            "1": .string("supported"),
            "4": .string("supported"),
            "5": .string("supported")
        ]
        let info = MintInfo(name: "Test", pubkey: "abc", nuts: nuts)
        
        let supported = info.getSupportedNUTs()
        #expect(supported.contains("1"))
        #expect(supported.contains("4"))
        #expect(supported.contains("5"))
    }
    
    @Test("MintInfo serverTime")
    func mintInfoServerTime() throws {
        let timestamp = 1703865600
        let info = MintInfo(name: "Test", pubkey: "abc", time: timestamp)
        
        #expect(info.serverTime != nil)
        #expect(info.serverTime?.timeIntervalSince1970 == Double(timestamp))
    }
    
    @Test("MintInfo isValid")
    func mintInfoIsValid() throws {
        let validInfo = MintInfo(name: "Test Mint", pubkey: "0123456789")
        #expect(validInfo.isValid())
        
        let invalidName = MintInfo(name: nil, pubkey: "0123456789")
        #expect(!invalidName.isValid())
        
        let invalidPubkey = MintInfo(name: "Test", pubkey: nil)
        #expect(!invalidPubkey.isValid())
        
        let emptyName = MintInfo(name: "", pubkey: "0123456789")
        #expect(!emptyName.isValid())
    }
    
    @Test("MintInfo JSON decoding")
    func mintInfoJSONDecoding() throws {
        let json = """
        {
            "name": "Test Mint",
            "pubkey": "0398bc95e0eb90fc0cfb12d6d90cb91c1f9d6b21a3beb14cc5e3e3e741e",
            "version": "Nutshell/0.15.0",
            "description": "A test mint for testing",
            "description_long": "This is a longer description of the mint",
            "contact": [{"method": "email", "info": "admin@mint.com"}],
            "motd": "Welcome to our mint!",
            "icon_url": "https://example.com/icon.png",
            "urls": ["https://mint.example.com"],
            "time": 1703865600,
            "tos_url": "https://example.com/tos"
        }
        """
        
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let mintInfo = try decoder.decode(MintInfo.self, from: data)
        
        #expect(mintInfo.name == "Test Mint")
        #expect(mintInfo.version == "Nutshell/0.15.0")
        #expect(mintInfo.descriptionLong == "This is a longer description of the mint")
        #expect(mintInfo.contact?.first?.method == "email")
        #expect(mintInfo.motd == "Welcome to our mint!")
        #expect(mintInfo.iconURL == "https://example.com/icon.png")
    }
    
    // MARK: - NUT05Settings Tests
    
    @Test("NUT05Settings initialization")
    func nut05SettingsInit() throws {
        let method = MeltMethodSetting(method: "bolt11", unit: "sat", minAmount: 1, maxAmount: 100000)
        let settings = NUT05Settings(methods: [method], disabled: false)
        
        #expect(settings.methods.count == 1)
        #expect(!settings.disabled)
    }
    
    @Test("NUT05Settings isSupported")
    func nut05SettingsIsSupported() throws {
        let method = MeltMethodSetting(method: "bolt11", unit: "sat")
        let settings = NUT05Settings(methods: [method], disabled: false)
        
        #expect(settings.isSupported(method: "bolt11", unit: "sat"))
        #expect(!settings.isSupported(method: "bolt11", unit: "usd"))
        #expect(!settings.isSupported(method: "unknown", unit: "sat"))
    }
    
    @Test("NUT05Settings disabled blocks all")
    func nut05SettingsDisabled() throws {
        let method = MeltMethodSetting(method: "bolt11", unit: "sat")
        let settings = NUT05Settings(methods: [method], disabled: true)
        
        #expect(!settings.isSupported(method: "bolt11", unit: "sat"))
    }
    
    @Test("NUT05Settings supportedMethods and units")
    func nut05SettingsSupportedMethodsAndUnits() throws {
        let methods = [
            MeltMethodSetting(method: "bolt11", unit: "sat"),
            MeltMethodSetting(method: "bolt11", unit: "usd"),
            MeltMethodSetting(method: "onchain", unit: "sat")
        ]
        let settings = NUT05Settings(methods: methods)
        
        #expect(settings.supportedMethods.contains("bolt11"))
        #expect(settings.supportedMethods.contains("onchain"))
        #expect(settings.supportedUnits.contains("sat"))
        #expect(settings.supportedUnits.contains("usd"))
    }
    
    // MARK: - MintCapabilities Tests
    
    @Test("MintCapabilities from MintInfo")
    func mintCapabilitiesFromMintInfo() throws {
        let nuts: [String: NutValue] = [
            "3": .dictionary(["supported": AnyCodable(anyValue: true)!]),
            "7": .dictionary(["supported": AnyCodable(anyValue: true)!]),
            "9": .dictionary(["supported": AnyCodable(anyValue: true)!])
        ]
        let contact = MintContact(method: "email", info: "test@example.com")
        let info = MintInfo(
            name: "Test Mint",
            pubkey: "abc123",
            contact: [contact],
            nuts: nuts,
            motd: "Hello",
            iconURL: "https://example.com/icon.png",
            tosURL: "https://example.com/tos"
        )
        
        let capabilities = MintCapabilities(from: info)
        
        #expect(capabilities.supportsSwapping)
        #expect(capabilities.supportsStateCheck)
        #expect(capabilities.supportsRestoreSignatures)
        #expect(capabilities.hasContactInfo)
        #expect(capabilities.hasTermsOfService)
        #expect(capabilities.hasIcon)
        #expect(capabilities.messageOfTheDay == "Hello")
    }
    
    @Test("MintCapabilities summary")
    func mintCapabilitiesSummary() throws {
        let capabilities = MintCapabilities(
            supportedNUTs: ["1", "2", "3", "4", "5"],
            supportsMinting: true,
            supportsMelting: true,
            supportsSwapping: true,
            supportsStateCheck: false,
            supportsRestoreSignatures: false,
            mintMethods: ["bolt11"],
            meltMethods: ["bolt11"],
            supportedUnits: ["sat"],
            hasContactInfo: true,
            hasTermsOfService: false,
            hasIcon: true,
            messageOfTheDay: nil
        )
        
        let summary = capabilities.summary
        #expect(summary.contains("Minting"))
        #expect(summary.contains("Melting"))
        #expect(summary.contains("Swapping"))
        #expect(!summary.contains("State Check"))
    }
    
    @Test("MintCapabilities supportsBasicWalletOperations")
    func mintCapabilitiesBasicOperations() throws {
        let fullCapabilities = MintCapabilities(
            supportedNUTs: [],
            supportsMinting: true,
            supportsMelting: true,
            supportsSwapping: true,
            supportsStateCheck: false,
            supportsRestoreSignatures: false,
            mintMethods: [],
            meltMethods: [],
            supportedUnits: [],
            hasContactInfo: false,
            hasTermsOfService: false,
            hasIcon: false,
            messageOfTheDay: nil
        )
        #expect(fullCapabilities.supportsBasicWalletOperations)
        
        let partialCapabilities = MintCapabilities(
            supportedNUTs: [],
            supportsMinting: true,
            supportsMelting: false,
            supportsSwapping: true,
            supportsStateCheck: false,
            supportsRestoreSignatures: false,
            mintMethods: [],
            meltMethods: [],
            supportedUnits: [],
            hasContactInfo: false,
            hasTermsOfService: false,
            hasIcon: false,
            messageOfTheDay: nil
        )
        #expect(!partialCapabilities.supportsBasicWalletOperations)
    }
    
    // MARK: - VersionInfo Tests
    
    @Test("VersionInfo parsing standard format")
    func versionInfoStandardFormat() throws {
        let versionInfo = VersionInfo(from: "Nutshell/0.15.0")
        
        #expect(versionInfo.implementation == "Nutshell")
        #expect(versionInfo.version == "0.15.0")
        #expect(versionInfo.rawVersion == "Nutshell/0.15.0")
    }
    
    @Test("VersionInfo parsing version only")
    func versionInfoVersionOnly() throws {
        let versionInfo = VersionInfo(from: "1.2.3")
        
        #expect(versionInfo.implementation == nil)
        #expect(versionInfo.version == "1.2.3")
    }
    
    @Test("VersionInfo comparison")
    func versionInfoComparison() throws {
        let v1 = VersionInfo(from: "Nutshell/0.15.0")
        let v2 = VersionInfo(from: "Nutshell/0.14.0")
        let v3 = VersionInfo(from: "Nutshell/0.15.1")
        
        #expect(v1.isNewer(than: v2))
        #expect(!v1.isNewer(than: v3))
        #expect(!v2.isNewer(than: v1))
    }
    
    @Test("VersionInfo comparison different lengths")
    func versionInfoComparisonDifferentLengths() throws {
        let v1 = VersionInfo(from: "1.0")
        let v2 = VersionInfo(from: "1.0.1")
        
        #expect(v2.isNewer(than: v1))
        #expect(!v1.isNewer(than: v2))
    }
    
    // MARK: - MintURL Tests
    
    @Test("MintURL initialization")
    func mintURLInitialization() throws {
        let httpsURL = MintURL(url: "https://mint.example.com", type: .https)
        #expect(httpsURL.type == .https)
        #expect(httpsURL.url == "https://mint.example.com")
    }
    
    @Test("MintURLType priority")
    func mintURLTypePriority() throws {
        #expect(MintURLType.https.priority > MintURLType.tor.priority)
        #expect(MintURLType.tor.priority > MintURLType.http.priority)
        #expect(MintURLType.http.priority > MintURLType.unknown.priority)
    }
    
    // MARK: - MintMetadata Tests
    
    @Test("MintMetadata from MintInfo")
    func mintMetadataFromMintInfo() throws {
        let contact = MintContact(method: "email", info: "admin@mint.com")
        let info = MintInfo(
            name: "Test Mint",
            pubkey: "abc",
            version: "Nutshell/0.15.0",
            description: "A test mint",
            descriptionLong: "This is a longer description",
            contact: [contact],
            motd: "Welcome",
            iconURL: "https://example.com/icon.png",
            urls: ["https://mint.example.com", "http://mintx.onion"],
            time: 1703865600,
            tosURL: "https://example.com/tos"
        )
        
        let metadata = MintMetadata(from: info)
        
        #expect(metadata.name == "Test Mint")
        #expect(metadata.description == "A test mint")
        #expect(metadata.longDescription == "This is a longer description")
        #expect(metadata.contactInfo["email"] == "admin@mint.com")
        #expect(metadata.versionInfo?.implementation == "Nutshell")
        #expect(metadata.versionInfo?.version == "0.15.0")
        #expect(metadata.urls.count == 2)
        #expect(metadata.operationalStatus == "Welcome")
    }
    
    @Test("MintMetadata URL type detection")
    func mintMetadataURLTypeDetection() throws {
        let info = MintInfo(
            name: "Test",
            pubkey: "abc",
            urls: ["https://mint.example.com", "http://unsafe.mint.com", "http://mint.onion"]
        )
        
        let metadata = MintMetadata(from: info)
        
        let httpsURL = metadata.urls.first { $0.url == "https://mint.example.com" }
        #expect(httpsURL?.type == .https)
        
        let httpURL = metadata.urls.first { $0.url == "http://unsafe.mint.com" }
        #expect(httpURL?.type == .http)
        
        let torURL = metadata.urls.first { $0.url.contains(".onion") }
        #expect(torURL?.type == .tor)
    }
    
    // MARK: - NUTConfiguration Tests
    
    @Test("NUTConfiguration initialization")
    func nutConfigurationInit() throws {
        let config = NUTConfiguration(
            version: "1.0",
            settings: ["maxAmount": 100000],
            enabled: true
        )
        
        #expect(config.version == "1.0")
        #expect(config.enabled)
        #expect(config.settings != nil)
    }
    
    @Test("NUTConfiguration disabled")
    func nutConfigurationDisabled() throws {
        let config = NUTConfiguration(
            version: nil,
            settings: nil,
            enabled: false
        )
        
        #expect(!config.enabled)
        #expect(config.version == nil)
        #expect(config.settings == nil)
    }
    
    // MARK: - MintOperationalStatus Tests
    
    @Test("MintOperationalStatus initialization")
    func mintOperationalStatusInit() throws {
        let status = MintOperationalStatus(
            isOperational: true,
            lastUpdated: Date(),
            messageOfTheDay: "All systems go!",
            supportedOperations: "Minting, Melting, Swapping",
            hasTermsOfService: true,
            hasContactInfo: true
        )
        
        #expect(status.isOperational)
        #expect(status.statusDescription == "Operational")
        #expect(status.messageOfTheDay == "All systems go!")
    }
    
    @Test("MintOperationalStatus not operational")
    func mintOperationalStatusNotOperational() throws {
        let status = MintOperationalStatus(
            isOperational: false,
            lastUpdated: Date(),
            messageOfTheDay: nil,
            supportedOperations: "",
            hasTermsOfService: false,
            hasContactInfo: false
        )
        
        #expect(!status.isOperational)
        #expect(status.statusDescription == "Limited functionality")
    }
    
    // MARK: - MintInfo Helper Method Tests
    
    @Test("MintInfo supportsRestoreSignatures")
    func mintInfoSupportsRestoreSignatures() throws {
        let nuts: [String: NutValue] = [
            "9": .dictionary(["supported": AnyCodable(anyValue: true)!])
        ]
        let info = MintInfo(name: "Test", pubkey: "abc", nuts: nuts)
        
        #expect(info.supportsRestoreSignatures())
    }
    
    @Test("MintInfo supportsSpendingConditions")
    func mintInfoSupportsSpendingConditions() throws {
        let nuts: [String: NutValue] = [
            "10": .dictionary(["supported": AnyCodable(anyValue: true)!])
        ]
        let info = MintInfo(name: "Test", pubkey: "abc", nuts: nuts)
        
        #expect(info.supportsSpendingConditions())
    }
    
    @Test("MintInfo supportsP2PK")
    func mintInfoSupportsP2PK() throws {
        let nuts: [String: NutValue] = [
            "11": .dictionary(["supported": AnyCodable(anyValue: true)!])
        ]
        let info = MintInfo(name: "Test", pubkey: "abc", nuts: nuts)
        
        #expect(info.supportsP2PK())
    }
    
    @Test("MintInfo supportsOfflineSignatureValidation")
    func mintInfoSupportsOfflineSignatureValidation() throws {
        let nuts: [String: NutValue] = [
            "12": .dictionary(["supported": AnyCodable(anyValue: true)!])
        ]
        let info = MintInfo(name: "Test", pubkey: "abc", nuts: nuts)
        
        #expect(info.supportsOfflineSignatureValidation())
    }
    
    @Test("MintInfo getAllNUTsStatus")
    func mintInfoGetAllNUTsStatus() throws {
        let nuts: [String: NutValue] = [
            "1": .dictionary(["supported": AnyCodable(anyValue: true)!]),
            "7": .dictionary(["supported": AnyCodable(anyValue: false)!]),
            "9": .string("supported")
        ]
        let info = MintInfo(name: "Test", pubkey: "abc", nuts: nuts)
        
        let status = info.getAllNUTsStatus()
        
        #expect(status["1"] == true)
        #expect(status["7"] == false)
        #expect(status["9"] == true)  // String values default to supported
    }
}
