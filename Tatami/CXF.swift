import Compression
import CryptoKit
import Foundation

/// FIDO Credential Exchange Format (CXF) のインポート / エクスポート (要件: documents/PROJECT.md 機能要件 3)。
/// ファイルは `index.json` を含む ZIP。パスワードは `basic-auth`、Passkey は `passkey` (秘密鍵は PKCS#8 を base64url) として表す。
/// Secure Enclave の鍵は取り出せないため、エクスポートできるのはソフトウェア鍵の Passkey だけ
enum CXF {
    /// 出力する Header.version。参照した仕様 (CXF v1.0 working draft 2024-10-03) の値
    static let version = 0

    /// エクスポートの結果。Secure Enclave の Passkey は含められないため件数で知らせる
    struct ExportResult: Equatable {
        var credentials: Int
        var passkeys: Int
        var skippedSecureEnclavePasskeys: Int
    }

    /// インポートの結果
    struct ImportResult: Equatable {
        var credentials: [Credential]
        var passkeys: [Passkey]
        /// 対応しない種類 (totp・note 等) や読めない項目の数
        var skipped: Int
    }

    /// index.json の内容 (ZIP に入れる前)
    static func exportJSON(credentials: [Credential], passkeys: [Passkey], exporter: String, now: Date) throws -> (data: Data, result: ExportResult) {
        var items: [[String: Any]] = []
        for credential in credentials {
            items.append([
                "id": WebAuthn.base64url(Data(credential.id.uuidString.utf8)),
                "creationAt": Int(credential.updatedAt.timeIntervalSince1970),
                "modifiedAt": Int(credential.updatedAt.timeIntervalSince1970),
                "type": "login",
                "title": credential.host.isEmpty ? credential.url.absoluteString : credential.host,
                "credentials": [[
                    "type": "basic-auth",
                    "urls": [credential.url.absoluteString],
                    "username": ["fieldType": "string", "value": credential.username],
                    "password": ["fieldType": "concealed-string", "value": credential.password],
                ] as [String: Any]],
            ])
        }
        var exported = 0
        var skipped = 0
        for passkey in passkeys {
            guard !passkey.isSecureEnclave else {
                skipped += 1
                continue
            }
            let key = try P256.Signing.PrivateKey(rawRepresentation: passkey.privateKey)
            exported += 1
            items.append([
                "id": WebAuthn.base64url(Data(passkey.id.uuidString.utf8)),
                "creationAt": Int(passkey.createdAt.timeIntervalSince1970),
                "modifiedAt": Int(passkey.createdAt.timeIntervalSince1970),
                "type": "login",
                "title": passkey.rpId,
                "credentials": [[
                    "type": "passkey",
                    "credentialId": WebAuthn.base64url(passkey.credentialID),
                    "rpId": passkey.rpId,
                    "userName": passkey.userName,
                    "userDisplayName": passkey.userDisplayName,
                    "userHandle": WebAuthn.base64url(passkey.userHandle),
                    "key": WebAuthn.base64url(key.derRepresentation),
                ] as [String: Any]],
            ])
        }
        let header: [String: Any] = [
            "version": version,
            "exporter": exporter,
            "timestamp": Int(now.timeIntervalSince1970),
            "accounts": [[
                "id": WebAuthn.base64url(Data("tatami".utf8)),
                "userName": "",
                "email": "",
                "collections": [] as [Any],
                "items": items,
            ] as [String: Any]],
        ]
        let data = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        return (data, ExportResult(credentials: credentials.count, passkeys: exported, skippedSecureEnclavePasskeys: skipped))
    }

    /// ZIP (index.json を stored で格納) を作る
    static func exportArchive(credentials: [Credential], passkeys: [Passkey], exporter: String, now: Date) throws -> (data: Data, result: ExportResult) {
        let json = try exportJSON(credentials: credentials, passkeys: passkeys, exporter: exporter, now: now)
        return (ZIPArchive.make(entries: [("index.json", json.data)]), json.result)
    }

    /// ZIP または生の index.json を読む
    static func importArchive(data: Data, now: Date) throws -> ImportResult {
        let json: Data
        if data.starts(with: [0x50, 0x4b]) {
            guard let entry = try ZIPArchive.entries(data: data).first(where: { $0.name == "index.json" || $0.name.hasSuffix("/index.json") }) else {
                throw CXFError(description: "ZIP に index.json が無い")
            }
            json = entry.data
        } else {
            json = data
        }
        return try importJSON(data: json, now: now)
    }

    static func importJSON(data: Data, now: Date) throws -> ImportResult {
        guard let header = try JSONSerialization.jsonObject(with: data) as? [String: Any], let accounts = header["accounts"] as? [[String: Any]] else {
            throw CXFError(description: "CXF の形式でない (accounts が無い)")
        }
        guard let fileVersion = header["version"] as? Int, fileVersion == version else {
            throw CXFError(description: "対応しない CXF の版: \(header["version"] ?? "無し") (対応: \(version))")
        }
        var result = ImportResult(credentials: [], passkeys: [], skipped: 0)
        for account in accounts {
            for item in account["items"] as? [[String: Any]] ?? [] {
                let title = item["title"] as? String ?? ""
                for credential in item["credentials"] as? [[String: Any]] ?? [] {
                    switch credential["type"] as? String {
                    case "basic-auth":
                        // urls の中からホストを持つ最初の URL を使い、無ければ title をホストとみなす
                        let urls = (credential["urls"] as? [String] ?? []).compactMap(URL.init(string:)).filter { $0.host().map { !$0.isEmpty } ?? false }
                        guard let url = urls.first ?? URL(string: "https://\(title)/"), url.host().map({ !$0.isEmpty }) ?? false,
                              let username = editableValue(credential["username"]), let password = editableValue(credential["password"]) else {
                            result.skipped += 1
                            continue
                        }
                        result.credentials.append(Credential(id: UUID(), url: url, username: username, password: password, note: "", updatedAt: now))
                    case "passkey":
                        guard let rpId = credential["rpId"] as? String, !rpId.isEmpty,
                              let credentialID = (credential["credentialId"] as? String).flatMap(WebAuthn.data(base64url:)),
                              let userHandle = (credential["userHandle"] as? String).flatMap(WebAuthn.data(base64url:)),
                              let keyDER = (credential["key"] as? String).flatMap(WebAuthn.data(base64url:)),
                              let key = try? P256.Signing.PrivateKey(derRepresentation: keyDER) else {
                            result.skipped += 1
                            continue
                        }
                        result.passkeys.append(Passkey(
                            id: UUID(), rpId: rpId, credentialID: credentialID, userHandle: userHandle,
                            userName: credential["userName"] as? String ?? "", userDisplayName: credential["userDisplayName"] as? String ?? "",
                            privateKey: key.rawRepresentation, isSecureEnclave: false, publicKeyX963: key.publicKey.x963Representation,
                            signCount: 0, createdAt: now
                        ))
                    default:
                        result.skipped += 1
                    }
                }
            }
        }
        return result
    }

    /// EditableField (`{fieldType, value}`) か、素の文字列。欠落や読めない形は nil (その項目は読み飛ばす)
    private static func editableValue(_ value: Any?) -> String? {
        if let field = value as? [String: Any] {
            return field["value"] as? String
        }
        return value as? String
    }
}

/// CXF の読み書きのエラー
struct CXFError: Error, CustomStringConvertible, Equatable {
    let description: String
}

/// CXF のコンテナに使う最小限の ZIP (書き込みは stored、読み取りは stored と deflate)。外部ライブラリを持たないため自前で持つ
enum ZIPArchive {
    struct Entry: Equatable {
        let name: String
        let data: Data
    }

    static func make(entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let offset = UInt32(out.count)
            out.append(le32(0x04034b50))
            out.append(le16(20)) // version needed
            out.append(le16(0)) // flags
            out.append(le16(0)) // method: stored
            out.append(le16(0)); out.append(le16(0)) // time, date
            out.append(le32(crc))
            out.append(le32(UInt32(entry.data.count)))
            out.append(le32(UInt32(entry.data.count)))
            out.append(le16(UInt16(name.count)))
            out.append(le16(0))
            out.append(name)
            out.append(entry.data)
            central.append(le32(0x02014b50))
            central.append(le16(20)); central.append(le16(20)); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0))
            central.append(le32(crc))
            central.append(le32(UInt32(entry.data.count)))
            central.append(le32(UInt32(entry.data.count)))
            central.append(le16(UInt16(name.count)))
            central.append(le16(0)); central.append(le16(0)); central.append(le16(0)); central.append(le16(0))
            central.append(le32(0))
            central.append(le32(offset))
            central.append(name)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(le32(0x06054b50))
        out.append(le16(0)); out.append(le16(0))
        out.append(le16(UInt16(entries.count))); out.append(le16(UInt16(entries.count)))
        out.append(le32(UInt32(central.count)))
        out.append(le32(centralOffset))
        out.append(le16(0))
        return out
    }

    static func entries(data: Data) throws -> [Entry] {
        // EOCD を末尾から探す
        guard data.count >= 22, let eocd = data.lastRange(of: Data([0x50, 0x4b, 0x05, 0x06]))?.lowerBound else {
            throw CXFError(description: "ZIP の終端レコードが無い")
        }
        // 途中で切れた・細工された ZIP で範囲外アクセス (トラップ) にならないよう、各ヘッダの読み取り前に範囲を確かめる
        let eocdOffset = eocd - data.startIndex
        guard eocdOffset + 22 <= data.count else {
            throw CXFError(description: "ZIP の終端レコードが途中で切れている")
        }
        let count = Int(read16(data, eocdOffset + 10))
        var offset = Int(read32(data, eocdOffset + 16))
        var result: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= data.count, read32(data, offset) == 0x02014b50 else {
                throw CXFError(description: "ZIP の中央ディレクトリが壊れている")
            }
            let method = read16(data, offset + 10)
            let crc = read32(data, offset + 16)
            let compressed = Int(read32(data, offset + 20))
            let uncompressed = Int(read32(data, offset + 24))
            let nameLength = Int(read16(data, offset + 28))
            let extraLength = Int(read16(data, offset + 30))
            let commentLength = Int(read16(data, offset + 32))
            let localOffset = Int(read32(data, offset + 42))
            guard offset + 46 + nameLength + extraLength + commentLength <= data.count else {
                throw CXFError(description: "ZIP の中央ディレクトリが途中で切れている")
            }
            let name = String(decoding: data[(data.startIndex + offset + 46)..<(data.startIndex + offset + 46 + nameLength)], as: UTF8.self)
            offset += 46 + nameLength + extraLength + commentLength
            guard localOffset + 30 <= data.count, read32(data, localOffset) == 0x04034b50 else {
                throw CXFError(description: "ZIP のローカルヘッダが壊れている")
            }
            let localNameLength = Int(read16(data, localOffset + 26))
            let localExtraLength = Int(read16(data, localOffset + 28))
            let start = localOffset + 30 + localNameLength + localExtraLength
            guard start <= data.count, compressed <= data.count - start else {
                throw CXFError(description: "ZIP のデータが途中で切れている")
            }
            let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + compressed))
            let content: Data
            switch method {
            case 0:
                content = raw
            case 8:
                content = try inflate(raw, expected: uncompressed)
            default:
                throw CXFError(description: "対応しない ZIP の圧縮方式: \(method)")
            }
            // 転送・保存中の破損で壊れた値を資格情報として取り込まないよう、展開後のデータを中央ディレクトリの CRC-32 と照合する
            guard crc32(content) == crc else {
                throw CXFError(description: "ZIP のエントリ \(name) の CRC が一致しない")
            }
            result.append(Entry(name: name, data: content))
        }
        return result
    }

    private static func inflate(_ data: Data, expected: Int) throws -> Data {
        let capacity = max(expected, 1)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { outBuffer in
            data.withUnsafeBytes { inBuffer in
                compression_decode_buffer(outBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity, inBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expected else {
            throw CXFError(description: "ZIP の展開に失敗")
        }
        return output
    }

    private static func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xff), UInt8(value >> 8)])
    }

    private static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8(value >> 24)])
    }

    private static func read16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[data.startIndex + offset + $1]) << (8 * UInt32($1))) }
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xedb88320 ^ (c >> 1) : c >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(UInt32(0xffffffff)) { crc, byte in crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
    }
}
