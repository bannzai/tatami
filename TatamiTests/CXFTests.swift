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
        let credential = Credential(id: UUID(), url: URL(string: "https://example.com/login")!, username: "alice", password: "dummy-alice", note: "予備のメモ", updatedAt: now)
        let key = P256.Signing.PrivateKey()
        let passkey = Passkey(id: UUID(), rpId: "example.com", credentialID: Data([1, 2, 3]), userHandle: Data([9]), userName: "alice", userDisplayName: "Alice",
                              privateKey: key.rawRepresentation, isSecureEnclave: false, publicKeyX963: key.publicKey.x963Representation, signCount: 0, createdAt: now,
                              isBackupEligible: false)
        let sePasskey = Passkey(id: UUID(), rpId: "example.org", credentialID: Data([4]), userHandle: Data([8]), userName: "bob", userDisplayName: "Bob",
                                privateKey: Data([0]), isSecureEnclave: true, publicKeyX963: key.publicKey.x963Representation, signCount: 0, createdAt: now,
                                isBackupEligible: false)
        // 旧スキーマで署名カウンタが進んだソフトウェア鍵は CXF で持ち出せない (移行先で 0 に戻ると RP に複製とみなされる)
        let usedPasskey = Passkey(id: UUID(), rpId: "example.com", credentialID: Data([5]), userHandle: Data([9]), userName: "alice", userDisplayName: "Alice",
                                  privateKey: key.rawRepresentation, isSecureEnclave: false, publicKeyX963: key.publicKey.x963Representation, signCount: 3, createdAt: now,
                                  isBackupEligible: false)
        let exported = try CXF.exportArchive(credentials: [credential], passkeys: [passkey, sePasskey, usedPasskey], exporter: "Tatami", now: now)
        #expect(exported.result == CXF.ExportResult(credentials: 1, passkeys: 1, skippedSecureEnclavePasskeys: 1, excludedCredentials: 0, brokenPasskeys: 0, usedCounterPasskeys: 1))
        let json = try #require(try ZIPArchive.entries(data: exported.data).first).data
        let header = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        // Tatami が書き出した Passkey は登録時の BE (ローカル作成は false) を往復で保つ
        let roundTrip = try CXF.importArchive(data: exported.data, now: now)
        // note credential を持つ item はメモの有無を区別できる (メモ付きなので「メモ無し」には入らない)
        #expect(roundTrip.credentialIDsWithoutNote.isEmpty)
        #expect(roundTrip.passkeys.map(\.isBackupEligible) == [false])
        #expect(roundTrip.credentials.map(\.updatedAt) == [now])
        #expect(header["version"] as? Int == CXF.version)
        #expect(header["exporter"] as? String == "Tatami")
        // 秘密鍵は CXF が要求する PKCS#8 の PrivateKeyInfo で書き出す
        let exportedKeyText = try #require(passkeyCredential(header: header)["key"] as? String)
        let exportedKey = try #require(WebAuthn.data(base64url: exportedKeyText))
        #expect(exportedKey.range(of: CXFTests.pkcs8P256Prefix) != nil)
        let imported = try CXF.importArchive(data: exported.data, now: now)
        #expect(imported.skipped == 0)
        #expect(imported.credentials.map(\.username) == ["alice"])
        #expect(imported.credentials[0].url == credential.url)
        #expect(imported.credentials[0].password == "dummy-alice")
        // メモも CXF の note として往復する
        #expect(imported.credentials[0].note == "予備のメモ")
        #expect(imported.passkeys.count == 1)
        #expect(imported.passkeys[0].rpId == "example.com")
        #expect(imported.passkeys[0].credentialID == Data([1, 2, 3]))
        #expect(imported.passkeys[0].userHandle == Data([9]))
        #expect(imported.passkeys[0].privateKey == key.rawRepresentation)
        #expect(imported.passkeys[0].publicKeyX963 == key.publicKey.x963Representation)
        #expect(imported.passkeys[0].createdAt == now)
    }

    @Test func exportExcludesHostlessCredentialsAndUnreadablePasskeys() throws {
        let credential = Credential(id: UUID(), url: URL(string: "https://example.com/login")!, username: "alice", password: "dummy-alice", note: "", updatedAt: now)
        let hostless = Credential(id: UUID(), url: URL(string: "about:blank")!, username: "bob", password: "dummy-bob", note: "", updatedAt: now)
        let broken = Passkey(id: UUID(), rpId: "example.net", credentialID: Data([5]), userHandle: Data([6]), userName: "carol", userDisplayName: "Carol",
                             privateKey: Data([0]), isSecureEnclave: false, publicKeyX963: Data([0]), signCount: 0, createdAt: now, isBackupEligible: false)
        let exported = try CXF.exportJSON(credentials: [credential, hostless], passkeys: [broken], exporter: "Tatami", now: now)
        #expect(exported.result == CXF.ExportResult(credentials: 1, passkeys: 0, skippedSecureEnclavePasskeys: 0, excludedCredentials: 1, brokenPasskeys: 1))
        let header = try #require(try JSONSerialization.jsonObject(with: exported.data) as? [String: Any])
        // CXF の Timestamp はミリ秒
        #expect(header["timestamp"] as? Int == 1_700_000_000_000)
        #expect(firstItem(header: header)["creationAt"] as? Int == 1_700_000_000_000)
    }

    @Test func importSkipsUnsupportedTypesAndAcceptsRawJSON() throws {
        let json = """
        {"version":0,"exporter":"other","timestamp":1700000000000,"accounts":[{"id":"YQ","userName":"","email":"","collections":[],"items":[
          {"id":"MQ","creationAt":1700000000000,"modifiedAt":1700000000000,"type":"login","title":"example.net","credentials":[
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
        // 版が違う・欠けている、パスワードが欠けている
        #expect(throws: CXFError.self) {
            try CXF.importArchive(data: Data(json.replacingOccurrences(of: "\"version\":0", with: "\"version\":7").utf8), now: now)
        }
        let missingPassword = json.replacingOccurrences(of: ",\"password\":{\"fieldType\":\"concealed-string\",\"value\":\"dummy-carol\"}", with: "")
        let skipped = try CXF.importArchive(data: Data(missingPassword.utf8), now: now)
        #expect(skipped.credentials.isEmpty)
        #expect(skipped.skipped == 2)
    }

    @Test func importCountsItemsWithoutCredentialsArrayAsSkipped() throws {
        let json = """
        {"version":0,"exporter":"other","timestamp":1700000000000,"accounts":[{"id":"YQ","userName":"","email":"","collections":[],"items":[
          {"id":"MQ","creationAt":1700000000000,"modifiedAt":1700000000000,"type":"login","title":"example.net"},
          {"id":"Mg","creationAt":1700000000000,"modifiedAt":1700000000000,"type":"login","title":"example.org","credentials":["読めない要素"]}
        ]}]}
        """
        let imported = try CXF.importArchive(data: Data(json.utf8), now: now)
        #expect(imported.credentials.isEmpty)
        #expect(imported.skipped == 2)
    }

    @Test func basicAuthImportsEveryOriginAndKeepsNote() throws {
        let imported = try CXF.importArchive(data: itemJSON(title: "example.com", credentials: """
        {"type":"basic-auth","urls":["https://example.com/login","https://example.com/signin","https://old.example.net/"],"username":"alice","password":"dummy-alice"},
        {"type":"note","content":{"fieldType":"string","value":"予備のメモ"}}
        """), now: now)
        // 同じオリジンは 1 件にまとめ、別オリジンはそれぞれ候補に出せるよう資格情報にする
        #expect(imported.credentials.map { $0.url.absoluteString } == ["https://example.com/login", "https://old.example.net/"])
        #expect(imported.credentials.allSatisfy { $0.note == "予備のメモ" })
        #expect(imported.credentials[0].updatedAt == now)
        #expect(imported.skipped == 0)
    }

    @Test func titleIsUsedOnlyWhenItIsABareHostname() throws {
        let basicAuth = """
        {"type":"basic-auth","username":"alice","password":"dummy-alice"}
        """
        let fallback = try CXF.importArchive(data: itemJSON(title: "Example.COM", credentials: basicAuth), now: now)
        #expect(fallback.credentials.map { $0.url.absoluteString } == ["https://example.com/"])
        // userinfo を含む表示名は example.com の資格情報として保存してしまうため読み飛ばす
        for title in ["alice@example.com", "example.com/login", "example.com:8443"] {
            let skipped = try CXF.importArchive(data: itemJSON(title: title, credentials: basicAuth), now: now)
            #expect(skipped.credentials.isEmpty)
            #expect(skipped.skipped == 1)
        }
    }

    @Test func passkeyImportValidatesFields() throws {
        let key = P256.Signing.PrivateKey()
        let encodedKey = WebAuthn.base64url(key.derRepresentation)
        func passkeyJSON(rpId: String, credentialId: String, userHandle: String) -> Data {
            itemJSON(title: "example.com", credentials: """
            {"type":"passkey","rpId":"\(rpId)","credentialId":"\(credentialId)","userHandle":"\(userHandle)","userName":"alice","userDisplayName":"Alice","key":"\(encodedKey)"}
            """)
        }
        let imported = try CXF.importArchive(data: passkeyJSON(rpId: "Example.COM", credentialId: "AQID", userHandle: "CQ"), now: now)
        // 照合は rpId の完全一致で行うため、正規形 (小文字) にそろえて保存する
        #expect(imported.passkeys.map(\.rpId) == ["example.com"])
        #expect(imported.passkeys[0].privateKey == key.rawRepresentation)
        // 移行元で BE を立てて登録されている可能性があるため、取り込んだ鍵は BE を維持する
        #expect(imported.passkeys[0].isBackupEligible)
        #expect(imported.passkeys[0].createdAt == now)
        for invalid in [passkeyJSON(rpId: "example.com", credentialId: "", userHandle: "CQ"),
                        passkeyJSON(rpId: "example.com", credentialId: "AQID", userHandle: ""),
                        passkeyJSON(rpId: "https://example.com", credentialId: "AQID", userHandle: "CQ"),
                        passkeyJSON(rpId: "example.com:8443", credentialId: "AQID", userHandle: "CQ"),
                        passkeyJSON(rpId: "example.com/login", credentialId: "AQID", userHandle: "CQ")] {
            let skipped = try CXF.importArchive(data: invalid, now: now)
            #expect(skipped.passkeys.isEmpty)
            #expect(skipped.skipped == 1)
        }
    }

    /// PKCS#8 PrivateKeyInfo (RFC 5208) の P-256 用の先頭: INTEGER 0 と AlgorithmIdentifier (id-ecPublicKey + prime256v1)
    private static let pkcs8P256Prefix = Data([
        0x02, 0x01, 0x00,
        0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
    ])

    @Test func cryptoKitDERRepresentationIsPKCS8() throws {
        // CryptoKit の derRepresentation は SEC1 の ECPrivateKey ではなく PKCS#8 の PrivateKeyInfo で、CXF が要求する形式と同じ。
        // 秘密鍵の交換をこの表現のまま行ってよい根拠として固定する
        let key = P256.Signing.PrivateKey()
        #expect(key.derRepresentation.range(of: CXFTests.pkcs8P256Prefix) != nil)
        #expect(key.pemRepresentation.hasPrefix("-----BEGIN PRIVATE KEY-----"))
    }

    @Test func corruptedArchivesFailWithoutTrapping() throws {
        let archive = ZIPArchive.make(entries: [("index.json", Data("{\"version\":0,\"accounts\":[]}".utf8))])
        // 途中で切れた ZIP
        #expect(throws: CXFError.self) {
            try ZIPArchive.entries(data: archive.prefix(archive.count - 30))
        }
        // データが書き換わった ZIP (CRC 不一致)
        var tampered = archive
        tampered[40] ^= 0x01
        #expect(throws: CXFError.self) {
            try ZIPArchive.entries(data: tampered)
        }
    }

    @Test func endOfCentralDirectoryIsFoundBehindAnArchiveComment() throws {
        var archive = ZIPArchive.make(entries: [("index.json", Data("{}".utf8))])
        // アーカイブコメントに EOCD のシグネチャを含める。単純な後方検索ではコメント内の偽の候補を拾う
        let comment = Data([0x50, 0x4b, 0x05, 0x06]) + Data(repeating: 0xff, count: 20)
        archive[archive.count - 2] = UInt8(comment.count)
        archive[archive.count - 1] = 0
        archive.append(comment)
        #expect(try ZIPArchive.entries(data: archive).map(\.data) == [Data("{}".utf8)])
    }

    @Test func deflateEntriesAreBoundedAndAllowEmptyContent() throws {
        // 圧縮方式だけ deflate (8) に書き換えた、展開後 0 バイトのエントリ。他ツールが空のファイルをこの形で書くことがある
        let name = "empty.bin"
        var empty = ZIPArchive.make(entries: [(name, Data())])
        empty[8] = 8
        empty[30 + name.count + 10] = 8
        #expect(try ZIPArchive.entries(data: empty).map(\.data) == [Data()])
        // 圧縮データが空なのに展開後サイズを申告するエントリは、展開に失敗したものとして扱う (トラップしない)
        var emptyInput = empty
        emptyInput[30 + name.count + 24] = 100
        #expect(throws: CXFError.self) {
            try ZIPArchive.entries(data: emptyInput)
        }
        // 中央ディレクトリの自己申告どおりに確保すると数十バイトの ZIP で 4 GiB を要求できるため、上限と圧縮比で拒む
        var oversized = empty
        for offset in 0..<4 {
            oversized[30 + name.count + 24 + offset] = 0xff
        }
        #expect(throws: CXFError.self) {
            try ZIPArchive.entries(data: oversized)
        }
    }

    /// items が 1 件だけの CXF。title と credentials だけを差し替えて検証に使う
    private func itemJSON(title: String, credentials: String) -> Data {
        Data("""
        {"version":0,"exporter":"other","timestamp":1700000000000,"accounts":[{"id":"YQ","userName":"","email":"","collections":[],"items":[
          {"id":"MQ","creationAt":1700000000000,"modifiedAt":1700000000000,"type":"login","title":"\(title)","credentials":[\(credentials)]}
        ]}]}
        """.utf8)
    }

    private func firstItem(header: [String: Any]) -> [String: Any] {
        ((header["accounts"] as? [[String: Any]])?.first?["items"] as? [[String: Any]])?.first ?? [:]
    }

    private func passkeyCredential(header: [String: Any]) -> [String: Any] {
        let items = (header["accounts"] as? [[String: Any]])?.first?["items"] as? [[String: Any]] ?? []
        return items.flatMap { $0["credentials"] as? [[String: Any]] ?? [] }.first { $0["type"] as? String == "passkey" } ?? [:]
    }

    @Test func importDistinguishesMissingNoteFromEmptyNote() throws {
        func json(credentials: String) -> Data {
            Data("""
            {"version":0,"exporter":"x","timestamp":0,"accounts":[{"id":"YQ","userName":"","email":"","collections":[],"items":[{"id":"YQ","creationAt":0,"modifiedAt":0,"type":"login","title":"example.com","credentials":[\(credentials)]}]}]}
            """.utf8)
        }
        let basic = """
        {"type":"basic-auth","urls":["https://example.com"],"username":{"fieldType":"string","value":"alice"},"password":{"fieldType":"concealed-string","value":"dummy"}}
        """
        let missing = try CXF.importJSON(data: json(credentials: basic), now: now)
        #expect(missing.credentialIDsWithoutNote == Set(missing.credentials.map(\.id)))
        let empty = try CXF.importJSON(data: json(credentials: basic + ",{\"type\":\"note\",\"content\":{\"fieldType\":\"string\",\"value\":\"\"}}"), now: now)
        #expect(empty.credentialIDsWithoutNote.isEmpty)
        #expect(empty.credentials.map(\.note) == [""])
        // content を読めない note は「無い」扱い (既存のメモを消さない)
        let unreadable = try CXF.importJSON(data: json(credentials: basic + ",{\"type\":\"note\",\"content\":{\"fieldType\":\"string\"}}"), now: now)
        #expect(unreadable.credentialIDsWithoutNote == Set(unreadable.credentials.map(\.id)))
    }

    @Test func storedEntryRejectsMismatchedSizes() throws {
        var zip = ZIPArchive.make(entries: [("index.json", Data("{}".utf8))])
        // 中央ディレクトリの展開後サイズ (uncompressed) を書き換えて、圧縮サイズと食い違わせる
        let central = try #require(zip.range(of: Data([0x50, 0x4b, 0x01, 0x02])))
        zip[central.lowerBound + 24] = 1
        #expect(throws: CXFError.self) {
            try ZIPArchive.entries(data: zip)
        }
    }
}
