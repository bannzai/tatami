import Compression
import CryptoKit
import Foundation

/// FIDO Credential Exchange Format (CXF) のインポート / エクスポート (要件: documents/PROJECT.md 機能要件 3)。
/// ファイルは `index.json` を含む ZIP。パスワードは `basic-auth` (メモは同じ item の `note`)、Passkey は `passkey`
/// (秘密鍵は PKCS#8 の PrivateKeyInfo を base64url) として表す。
/// Secure Enclave の鍵は取り出せないため、エクスポートできるのはソフトウェア鍵の Passkey だけ
enum CXF {
    /// 出力する Header.version。参照した仕様 (CXF v1.0 working draft 2024-10-03) の値
    static let version = 0

    /// エクスポートの結果。書き出せなかった項目は利用者に件数で知らせる
    struct ExportResult: Equatable {
        var credentials: Int
        var passkeys: Int
        var skippedSecureEnclavePasskeys: Int
        /// ホストを持たない URL (about:blank・file: 等) のため除外した資格情報。再インポートで読み飛ばされるので書き出さない
        var excludedCredentials: Int
        /// 秘密鍵を復元できず書き出せなかった Passkey (旧スキーマ・破損した Keychain 項目)
        var brokenPasskeys: Int
    }

    /// インポートの結果
    struct ImportResult: Equatable {
        var credentials: [Credential]
        var passkeys: [Passkey]
        /// 対応しない種類 (totp 等) や読めない項目の数
        var skipped: Int
        /// `note` credential を持たない item から作った資格情報の id。取り込み時に既存のメモを残すため、空のメモが明示された item と区別する
        var credentialIDsWithoutNote: Set<UUID> = []
    }

    /// index.json の内容 (ZIP に入れる前)
    static func exportJSON(credentials: [Credential], passkeys: [Passkey], exporter: String, now: Date) throws -> (data: Data, result: ExportResult) {
        var items: [[String: Any]] = []
        let exportable = PasswordImporter.exportable(credentials: credentials)
        for credential in exportable.rows {
            var itemCredentials: [[String: Any]] = [[
                "type": "basic-auth",
                "urls": [credential.url.absoluteString],
                "username": ["fieldType": "string", "value": credential.username],
                "password": ["fieldType": "concealed-string", "value": credential.password],
            ]]
            if !credential.note.isEmpty {
                itemCredentials.append(["type": "note", "content": ["fieldType": "string", "value": credential.note]])
            }
            items.append([
                "id": WebAuthn.base64url(Data(credential.id.uuidString.utf8)),
                "creationAt": milliseconds(date: credential.updatedAt),
                "modifiedAt": milliseconds(date: credential.updatedAt),
                "type": "login",
                "title": credential.host,
                "credentials": itemCredentials,
            ])
        }
        var exportedPasskeys = 0
        var skippedSecureEnclave = 0
        var brokenPasskeys = 0
        for passkey in passkeys {
            guard !passkey.isSecureEnclave else {
                skippedSecureEnclave += 1
                continue
            }
            // 壊れた 1 件のために資格情報ごと書き出せなくならないよう、鍵を復元できない項目は件数で知らせて飛ばす
            guard let key = try? P256.Signing.PrivateKey(rawRepresentation: passkey.privateKey) else {
                brokenPasskeys += 1
                continue
            }
            exportedPasskeys += 1
            items.append([
                "id": WebAuthn.base64url(Data(passkey.id.uuidString.utf8)),
                "creationAt": milliseconds(date: passkey.createdAt),
                "modifiedAt": milliseconds(date: passkey.createdAt),
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
                    // CXF に BE の項目は無い。Tatami 同士の往復で登録時の BE (ローカル作成は 0) を保つための独自キー
                    "x-tatami-backupEligible": passkey.isBackupEligible,
                ] as [String: Any]],
            ])
        }
        let header: [String: Any] = [
            "version": version,
            "exporter": exporter,
            "timestamp": milliseconds(date: now),
            "accounts": [[
                "id": WebAuthn.base64url(Data("tatami".utf8)),
                "userName": "",
                "email": "",
                "collections": [] as [Any],
                "items": items,
            ] as [String: Any]],
        ]
        let data = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        return (data, ExportResult(
            credentials: exportable.rows.count, passkeys: exportedPasskeys, skippedSecureEnclavePasskeys: skippedSecureEnclave,
            excludedCredentials: exportable.excluded, brokenPasskeys: brokenPasskeys
        ))
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
                // credentials が無い・要素が辞書でない item は中身が分からない。黙って落とすと利用者が欠落に気付けないため読み飛ばしに数える
                guard let itemCredentials = item["credentials"] as? [[String: Any]] else {
                    result.skipped += 1
                    continue
                }
                importItem(item: item, credentials: itemCredentials, now: now, result: &result)
            }
        }
        return result
    }

    /// CXF の 1 item を読む。メモ (`note`) は同じ item のパスワードに付けるため、種類ごとの処理より先に取り出す
    private static func importItem(item: [String: Any], credentials: [[String: Any]], now: Date, result: inout ImportResult) {
        let title = item["title"] as? String ?? ""
        let createdAt = date(milliseconds: item["creationAt"]) ?? now
        let updatedAt = date(milliseconds: item["modifiedAt"]) ?? createdAt
        let noteCredential = credentials.first { $0["type"] as? String == "note" }
        let note = noteCredential.flatMap { editableValue($0["content"]) } ?? ""
        var appliedNote = false
        for credential in credentials {
            switch credential["type"] as? String {
            case "basic-auth":
                guard let username = editableValue(credential["username"]), let password = editableValue(credential["password"]) else {
                    result.skipped += 1
                    continue
                }
                let urls = importableURLs(rawURLs: credential["urls"] as? [String] ?? [], title: title)
                guard !urls.isEmpty else {
                    result.skipped += 1
                    continue
                }
                appliedNote = true
                for url in urls {
                    let credentialID = UUID()
                    if noteCredential == nil {
                        result.credentialIDsWithoutNote.insert(credentialID)
                    }
                    result.credentials.append(Credential(id: credentialID, url: url, username: username, password: password, note: note, updatedAt: updatedAt))
                }
            case "passkey":
                guard let passkey = importedPasskey(credential: credential, createdAt: createdAt) else {
                    result.skipped += 1
                    continue
                }
                result.passkeys.append(passkey)
            case "note":
                continue
            default:
                result.skipped += 1
            }
        }
        // メモだけの item や、パスワードを読めずメモの行き先が無くなった item は、メモを落としたことを件数で知らせる
        if !note.isEmpty && !appliedNote {
            result.skipped += 1
        }
    }

    /// CXF の passkey を Tatami の Passkey にする。認証で使えない値 (照合できない rpId・空の credential ID 等) は nil にして読み飛ばす
    private static func importedPasskey(credential: [String: Any], createdAt: Date) -> Passkey? {
        // 認証時の候補は rpId の完全一致で選ぶため、保存する前にホスト名の正規形 (小文字・IDNA の A-label) に揃える。
        // スキーム・userinfo・ポート・パスを含む値はどのオリジンにも一致せず使えないので受け付けない
        guard let rpId = hostname(rawHost: credential["rpId"] as? String ?? ""),
              let credentialID = (credential["credentialId"] as? String).flatMap(WebAuthn.data(base64url:)), !credentialID.isEmpty,
              let userHandle = (credential["userHandle"] as? String).flatMap(WebAuthn.data(base64url:)),
              // user handle は WebAuthn (6.3.2) が 1〜64 バイトと定める。空だと RP がアカウントを特定できない
              (1...64).contains(userHandle.count),
              // CXF の `key` は PKCS#8 の PrivateKeyInfo。CryptoKit の derRepresentation と同じ形式のためそのまま読める
              let key = (credential["key"] as? String).flatMap(WebAuthn.data(base64url:)).flatMap({ try? P256.Signing.PrivateKey(derRepresentation: $0) }) else {
            return nil
        }
        return Passkey(
            id: UUID(), rpId: rpId, credentialID: credentialID, userHandle: userHandle,
            userName: credential["userName"] as? String ?? "", userDisplayName: credential["userDisplayName"] as? String ?? "",
            privateKey: key.rawRepresentation, isSecureEnclave: false, publicKeyX963: key.publicKey.x963Representation,
            signCount: 0, createdAt: createdAt,
            // 移行元 (同期するパスワードマネージャー) は BE を立てて登録していることがあり、assertion で BE=0 に戻すと
            // 登録時との一致を検証する RP に拒まれる (WebAuthn L3 6.1.3)。Tatami が書き出した値があればそれを優先する
            isBackupEligible: credential["x-tatami-backupEligible"] as? Bool ?? true
        )
    }

    /// 取り込む URL。1 件の basic-auth が複数のオリジンを持つ場合、どのサイトでも候補に出るようそれぞれを資格情報にする
    /// (同じオリジンの重複は 1 件にまとめる)。urls から 1 つも読めない時だけ、表示名の title をホスト名とみなす
    private static func importableURLs(rawURLs: [String], title: String) -> [URL] {
        var seenOrigins: Set<String> = []
        var urls: [URL] = []
        for url in rawURLs.compactMap(URL.init(string:)) {
            guard let host = CredentialMatcher.host(url: url), !host.isEmpty else {
                continue
            }
            if seenOrigins.insert("\(url.scheme?.lowercased() ?? "")://\(host)\(url.port.map { ":\($0)" } ?? "")").inserted {
                urls.append(url)
            }
        }
        if urls.isEmpty, let host = hostname(rawHost: title), let url = URL(string: "https://\(host)/") {
            urls.append(url)
        }
        return urls
    }

    /// ホスト名として妥当なら正規形 (小文字・IDNA の A-label) を返す。
    /// userinfo を含む表示名 (`alice@example.com`) をそのまま URL にすると Foundation は `https://example.com/` と解釈するため、
    /// 本来サイト情報の無い資格情報を別のサイトのものとして保存してしまう。ホスト名に使える文字だけを受け付けて防ぐ
    private static func hostname(rawHost: String) -> String? {
        guard !rawHost.isEmpty, rawHost.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) else {
            return nil
        }
        return URL(string: "https://\(rawHost)/").flatMap { CredentialMatcher.host(url: $0) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// CXF の Timestamp は Unix epoch からのミリ秒
    private static func milliseconds(date: Date) -> Int {
        Int(date.timeIntervalSince1970 * 1000)
    }

    /// CXF の Timestamp (ミリ秒) を Date にする。ミリ秒でなく秒で書く実装の値をそのまま受け取ると 1970 年台の日時になり、
    /// 候補の並び (作成日時の降順) が崩れる。Web の資格情報が存在し得る 2000 年から 100 年先までの範囲だけを受け取り、
    /// 外れた値は呼び出し側の既定 (取り込んだ日時) に任せる
    private static func date(milliseconds: Any?) -> Date? {
        guard let value = (milliseconds as? NSNumber)?.doubleValue else {
            return nil
        }
        let seconds = value / 1000
        guard seconds >= 946_684_800, seconds <= 4_100_000_000 else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
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
    /// 展開後の合計サイズの上限。CXF は資格情報の JSON だけを入れるコンテナで、数万件でも数十 MB には届かない。
    /// 細工されたアーカイブで確保を要求されるメモリを抑えるために設ける
    static let maximumUncompressedSize = 64 * 1024 * 1024
    /// 圧縮サイズに対する展開後サイズの上限。deflate の理論上の最大比 (約 1032 倍) に収まらない値は中央ディレクトリの偽装とみなす
    static let maximumCompressionRatio = 1032

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
        guard let eocdOffset = endOfCentralDirectoryOffset(data: data) else {
            throw CXFError(description: "ZIP の終端レコードが無い")
        }
        // 途中で切れた・細工された ZIP で範囲外アクセス (トラップ) にならないよう、各ヘッダの読み取り前に範囲を確かめる
        let count = Int(read16(data, eocdOffset + 10))
        var offset = Int(read32(data, eocdOffset + 16))
        var totalUncompressed = 0
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
            totalUncompressed += uncompressed
            // 展開後のサイズは中央ディレクトリの自己申告のため、バッファを確保する前に上限と圧縮比で検査する
            guard totalUncompressed <= maximumUncompressedSize, uncompressed <= max(compressed, 1) * maximumCompressionRatio else {
                throw CXFError(description: "ZIP のエントリ \(name) の展開後のサイズが大きすぎる")
            }
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

    /// EOCD (終端レコード) の位置。アーカイブコメントに `PK\x05\x06` が含まれると単純な後方検索は偽の候補を拾うため、
    /// コメント長がちょうどファイル末尾までを指す候補だけを本物とみなす。
    /// コメントは ZIP の仕様で 65535 バイトまでのため、探索はレコード 22 バイトを足した範囲に限る
    private static func endOfCentralDirectoryOffset(data: Data) -> Int? {
        guard data.count >= 22 else {
            return nil
        }
        for offset in stride(from: data.count - 22, through: max(data.count - 22 - 65535, 0), by: -1) where read32(data, offset) == 0x06054b50 {
            if offset + 22 + Int(read16(data, offset + 20)) == data.count {
                return offset
            }
        }
        return nil
    }

    private static func inflate(_ data: Data, expected: Int) throws -> Data {
        // 展開後が空のエントリ (他ツールが作る空のディレクトリ等) は、デコーダーを呼ばずに空データとして扱う。
        // 1 バイトのバッファを渡すと 0 バイトの書き込みでも NUL 1 バイトが残り、CRC 検証が必ず失敗する
        guard expected > 0 else {
            return Data()
        }
        // 空の入力は baseAddress が nil になり、nil の unwrap でトラップする
        guard !data.isEmpty else {
            throw CXFError(description: "ZIP の圧縮データが空")
        }
        var output = Data(count: expected)
        let written = output.withUnsafeMutableBytes { outBuffer in
            data.withUnsafeBytes { inBuffer in
                compression_decode_buffer(outBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), expected, inBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count, nil, COMPRESSION_ZLIB)
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
