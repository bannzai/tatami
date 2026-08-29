import CryptoKit
import Foundation
import Testing
@testable import Tatami

struct WebAuthnTests {
    @Test func cborEncodesRFC8949Examples() {
        #expect(CBOR.encode(.unsigned(0)) == Data([0x00]))
        #expect(CBOR.encode(.unsigned(23)) == Data([0x17]))
        #expect(CBOR.encode(.unsigned(24)) == Data([0x18, 0x18]))
        #expect(CBOR.encode(.unsigned(1000)) == Data([0x19, 0x03, 0xe8]))
        #expect(CBOR.encode(.negative(-1)) == Data([0x20]))
        #expect(CBOR.encode(.negative(-7)) == Data([0x26]))
        #expect(CBOR.encode(.text("fmt")) == Data([0x63, 0x66, 0x6d, 0x74]))
        #expect(CBOR.encode(.bytes(Data([1, 2]))) == Data([0x42, 1, 2]))
        #expect(CBOR.encode(.array([.unsigned(1), .unsigned(2)])) == Data([0x82, 1, 2]))
        #expect(CBOR.encode(.map([(.unsigned(1), .unsigned(2))])) == Data([0xa1, 1, 2]))
        #expect(CBOR.encode(.bytes(Data(count: 300))).prefix(3) == Data([0x59, 0x01, 0x2c]))
    }

    @Test func base64urlRoundTrip() {
        let data = Data([0xfb, 0xff, 0x00, 0x3e])
        let text = WebAuthn.base64url(data)
        #expect(!text.contains("+") && !text.contains("/") && !text.contains("="))
        #expect(WebAuthn.data(base64url: text) == data)
    }

    @Test func rpIdValidation() {
        #expect(WebAuthn.isValidRpId("webauthn.io", originHost: "webauthn.io"))
        #expect(WebAuthn.isValidRpId("example.com", originHost: "login.example.com"))
        #expect(WebAuthn.isValidRpId("localhost", originHost: "localhost"))
        #expect(WebAuthn.isValidRpId("intranet", originHost: "intranet"))
        #expect(!WebAuthn.isValidRpId("login.example.com", originHost: "example.com"))
        #expect(!WebAuthn.isValidRpId("com", originHost: "example.com"))
        #expect(!WebAuthn.isValidRpId("evil.com", originHost: "example.com"))
    }

    @Test func trustworthyOrigins() {
        #expect(WebAuthn.isTrustworthyOrigin(URL(string: "https://example.com/")!))
        #expect(WebAuthn.isTrustworthyOrigin(URL(string: "http://localhost:8080/")!))
        #expect(WebAuthn.isTrustworthyOrigin(URL(string: "http://127.0.0.1/")!))
        #expect(!WebAuthn.isTrustworthyOrigin(URL(string: "http://example.com/")!))
        #expect(!WebAuthn.isTrustworthyOrigin(URL(string: "file:///tmp/a.html")!))
    }

    @Test func createIsValidatedBeforeKeyGeneration() throws {
        let store = InMemoryPasskeyStore()
        let authenticator = PasskeyAuthenticator(store: store, usesSecureEnclave: false)
        let origin = URL(string: "https://example.com")!
        let base = PasskeyAuthenticator.CreateRequest(rpId: nil, userID: Data([1]), userName: "a", userDisplayName: "A", challenge: "YQ", algorithms: [-7], excludeCredentialIDs: [], authenticatorAttachment: nil)
        var crossPlatform = base
        crossPlatform.authenticatorAttachment = "cross-platform"
        #expect(throws: WebAuthnError.self) {
            try authenticator.validate(request: crossPlatform, origin: origin)
        }
        var rsaOnly = base
        rsaOnly.algorithms = [-257]
        #expect(throws: WebAuthnError.self) {
            try authenticator.validate(request: rsaOnly, origin: origin)
        }
        #expect(throws: WebAuthnError.self) {
            try authenticator.validate(request: base, origin: URL(string: "http://example.com")!)
        }
        #expect(try authenticator.validate(request: base, origin: origin) == "example.com")
        #expect(try store.all().isEmpty)
        // 同じ RP・同じ userHandle の再登録では、新しい項目を保存してから古い項目を消す
        let first = try authenticator.makeCredential(request: base, origin: origin, userVerified: true)
        let second = try authenticator.makeCredential(request: base, origin: origin, userVerified: true)
        let remaining = try store.all()
        #expect(remaining.count == 1)
        #expect(remaining[0].credentialID == second.credentialID)
        #expect(remaining[0].credentialID != first.credentialID)
    }

    @Test func makeCredentialProducesVerifiableAttestation() throws {
        let store = InMemoryPasskeyStore()
        let authenticator = PasskeyAuthenticator(store: store, usesSecureEnclave: false)
        let origin = URL(string: "https://webauthn.io")!
        let request = PasskeyAuthenticator.CreateRequest(rpId: nil, userID: Data([1, 2, 3]), userName: "alice", userDisplayName: "Alice", challenge: "Y2hhbGxlbmdl", algorithms: [-7, -257], excludeCredentialIDs: [], authenticatorAttachment: nil)
        let response = try authenticator.makeCredential(request: request, origin: origin, userVerified: true)
        let passkeys = try store.all()
        #expect(passkeys.count == 1)
        #expect(passkeys[0].rpId == "webauthn.io")
        #expect(response.credentialID.count == 32)
        // authenticatorData: rpIdHash | flags (UP|UV|AT = 0x45) | signCount 0 | aaguid | credId
        let rpIdHash = Data(SHA256.hash(data: Data("webauthn.io".utf8)))
        #expect(response.authenticatorData.prefix(32) == rpIdHash)
        #expect(response.authenticatorData[32] == 0x45)
        #expect(response.authenticatorData.subdata(in: 33..<37) == Data([0, 0, 0, 0]))
        #expect(response.authenticatorData.subdata(in: 53..<55) == Data([0, 32]))
        #expect(response.authenticatorData.subdata(in: 55..<87) == response.credentialID)
        // attestationObject は fmt "none" の map で始まり、authData をそのまま含む
        let attestationHead = Data([0xa3, 0x63, 0x66, 0x6d, 0x74, 0x64, 0x6e, 0x6f, 0x6e, 0x65])
        #expect(response.attestationObject.prefix(10) == attestationHead)
        #expect(response.attestationObject.range(of: response.authenticatorData) != nil)
        let clientData = try #require(try JSONSerialization.jsonObject(with: response.clientDataJSON) as? [String: Any])
        #expect(clientData["type"] as? String == "webauthn.create")
        #expect(clientData["origin"] as? String == "https://webauthn.io")
        #expect(clientData["challenge"] as? String == "Y2hhbGxlbmdl")
        // 公開鍵 (DER) と COSE の x / y が一致する
        let publicKey = try P256.Signing.PublicKey(derRepresentation: response.publicKeyDER)
        #expect(publicKey.x963Representation == passkeys[0].publicKeyX963)
        // 同じ RP で excludeCredentials に含まれていれば登録を拒む
        let excluded = PasskeyAuthenticator.CreateRequest(rpId: nil, userID: Data([9]), userName: "bob", userDisplayName: "Bob", challenge: "eA", algorithms: [-7], excludeCredentialIDs: [response.credentialID], authenticatorAttachment: nil)
        #expect(throws: WebAuthnError.self) {
            try authenticator.makeCredential(request: excluded, origin: origin, userVerified: true)
        }
    }

    @Test func assertionSignatureVerifiesWithRegisteredPublicKey() throws {
        let store = InMemoryPasskeyStore()
        let authenticator = PasskeyAuthenticator(store: store, usesSecureEnclave: false)
        let origin = URL(string: "https://login.example.com:8443")!
        let created = try authenticator.makeCredential(
            request: PasskeyAuthenticator.CreateRequest(rpId: "example.com", userID: Data([7]), userName: "alice", userDisplayName: "Alice", challenge: "YQ", algorithms: [-7], excludeCredentialIDs: [], authenticatorAttachment: nil),
            origin: origin,
            userVerified: true
        )
        let request = PasskeyAuthenticator.GetRequest(rpId: "example.com", challenge: "Yg", allowCredentialIDs: [created.credentialID])
        let candidates = try authenticator.candidates(request: request, origin: origin)
        #expect(candidates.count == 1)
        let assertion = try authenticator.getAssertion(passkey: candidates[0], request: request, origin: origin, userVerified: true)
        #expect(assertion.authenticatorData[32] == 0x05)
        #expect(assertion.authenticatorData.suffix(4) == Data([0, 0, 0, 1]))
        #expect(assertion.userHandle == Data([7]))
        let clientData = try #require(try JSONSerialization.jsonObject(with: assertion.clientDataJSON) as? [String: Any])
        #expect(clientData["origin"] as? String == "https://login.example.com:8443")
        let publicKey = try P256.Signing.PublicKey(derRepresentation: created.publicKeyDER)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: assertion.signature)
        #expect(publicKey.isValidSignature(signature, for: WebAuthn.signedData(authenticatorData: assertion.authenticatorData, clientDataJSON: assertion.clientDataJSON)))
        // 署名カウンタが保存される
        #expect(try store.all()[0].signCount == 1)
        // allowCredentials に無い id では候補が無い
        let none = try authenticator.candidates(request: PasskeyAuthenticator.GetRequest(rpId: "example.com", challenge: "Yg", allowCredentialIDs: [Data([0])]), origin: origin)
        #expect(none.isEmpty)
    }

    @Test func originStringBracketsIPv6() {
        #expect(PasskeyAuthenticator.originString(url: URL(string: "https://[2001:db8::1]/")!) == "https://[2001:db8::1]")
        #expect(PasskeyAuthenticator.originString(url: URL(string: "https://example.com:443/")!) == "https://example.com")
        #expect(PasskeyAuthenticator.originString(url: URL(string: "https://example.com:8443/")!) == "https://example.com:8443")
    }
}
