import CryptoKit
import Foundation
import Testing
@testable import Tatami

struct CXFTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func zipRoundTripAndCRC() throws {
        // CRC-32 の既知の値 ("123456789" → 0xcbf43926)
        #expect(ZIPArchive.crc32(Data("123456789".utf8)) == 0xcbf43926)
        let archive = ZIPArchive.make(entries: [("index.json", Data("{}".utf8)), ("documents/a.txt", Data("hello".utf8))])
        let entries = try ZIPArchive.entries(data: archive)
        #expect(entries.map(\.name) == ["index.json", "documents/a.txt"])
        #expect(entries[1].data == Data("hello".utf8))
    }

    @Test func exportAndImportRoundTrip() throws {
        let credential = Credential(id: UUID(), url: URL(string: "https://example.com/login")!, username: "alice", password: "dummy-alice", note: "", updatedAt: now)
        let key = P256.Signing.PrivateKey()
        let passkey = Passkey(id: UUID(), rpId: "example.com", credentialID: Data([1, 2, 3]), userHandle: Data([9]), userName: "alice", userDisplayName: "Alice",
                              privateKey: key.rawRepresentation, isSecureEnclave: false, publicKeyX963: key.publicKey.x963Representation, signCount: 0, createdAt: now)
        let sePasskey = Passkey(id: UUID(), rpId: "example.org", credentialID: Data([4]), userHandle: Data([8]), userName: "bob", userDisplayName: "Bob",
                                privateKey: Data([0]), isSecureEnclave: true, publicKeyX963: key.publicKey.x963Representation, signCount: 0, createdAt: now)
        let exported = try CXF.exportArchive(credentials: [credential], passkeys: [passkey, sePasskey], exporter: "Tatami", now: now)
        #expect(exported.result == CXF.ExportResult(credentials: 1, passkeys: 1, skippedSecureEnclavePasskeys: 1))
        let json = try #require(try ZIPArchive.entries(data: exported.data).first).data
        let header = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(header["version"] as? Int == CXF.version)
        #expect(header["exporter"] as? String == "Tatami")
        let imported = try CXF.importArchive(data: exported.data, now: now)
        #expect(imported.skipped == 0)
        #expect(imported.credentials.map(\.username) == ["alice"])
        #expect(imported.credentials[0].url == credential.url)
        #expect(imported.credentials[0].password == "dummy-alice")
        #expect(imported.passkeys.count == 1)
        #expect(imported.passkeys[0].rpId == "example.com")
        #expect(imported.passkeys[0].credentialID == Data([1, 2, 3]))
        #expect(imported.passkeys[0].userHandle == Data([9]))
        #expect(imported.passkeys[0].privateKey == key.rawRepresentation)
        #expect(imported.passkeys[0].publicKeyX963 == key.publicKey.x963Representation)
    }

    @Test func importSkipsUnsupportedTypesAndAcceptsRawJSON() throws {
        let json = """
        {"version":0,"exporter":"other","timestamp":1,"accounts":[{"id":"YQ","userName":"","email":"","collections":[],"items":[
          {"id":"MQ","creationAt":1,"modifiedAt":1,"type":"login","title":"example.net","credentials":[
            {"type":"basic-auth","urls":["https://example.net/"],"username":{"fieldType":"string","value":"carol"},"password":{"fieldType":"concealed-string","value":"dummy-carol"}},
            {"type":"totp","secret":"ABCD","period":30,"digits":6,"username":"carol","algorithm":"sha1"}
          ]}
        ]}]}
        """
        let imported = try CXF.importArchive(data: Data(json.utf8), now: now)
        #expect(imported.credentials.map(\.username) == ["carol"])
        #expect(imported.passkeys.isEmpty)
        #expect(imported.skipped == 1)
        #expect(throws: CXFError.self) {
            try CXF.importArchive(data: Data("{}".utf8), now: now)
        }
    }
}
