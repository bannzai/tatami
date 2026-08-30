import CryptoKit
import Foundation

/// WebAuthn (Passkey) の自前 authenticator の純粋ロジック。WKWebView は任意サイトの WebAuthn を扱えない (Associated Domains 限定) ため、
/// `navigator.credentials` を注入スクリプトで置き換え、ここで attestation / assertion を組み立てる (スパイク #18。設計の前提は documents/PROJECT.md 技術リスク)
enum WebAuthn {
    /// 登録時に登録するアルゴリズム。ES256 (COSE -7) だけに対応する (Secure Enclave / CryptoKit の P-256)
    static let es256Algorithm = -7
    /// AAGUID。自前 authenticator の識別子で、attestation が "none" のため検証には使われない。ゼロは「識別しない」を表す慣例
    static let aaguid = Data(repeating: 0, count: 16)

    /// base64url (パディング無し)。WebAuthn の JSON 表現 (challenge・id・レスポンス) はこの形で受け渡す
    nonisolated static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func data(base64url text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    /// clientDataJSON。RP はこの JSON の hash に署名されていることを確かめるため、ここで組み立てた文字列をそのまま渡す
    static func clientDataJSON(type: String, challenge: String, origin: String) -> Data {
        // 文字列補間だと challenge / origin に含まれる `"` などが JSON 構造を壊し、重複キーを差し込む余地を与える。
        // JSONSerialization にエスケープさせて構造を保つ (challenge は呼び出し前に base64url であることを検証済み)
        let object: [String: Any] = ["type": type, "challenge": challenge, "origin": origin, "crossOrigin": false]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// 公開鍵の COSE_Key (EC2, P-256, ES256)。CTAP2 の canonical CBOR の順序 (1, 3, -1, -2, -3) で並べる
    static func coseKey(publicKeyX963: Data) -> Data {
        // X9.63 の非圧縮形式は 0x04 || x (32) || y (32)
        let x = publicKeyX963.subdata(in: 1..<33)
        let y = publicKeyX963.subdata(in: 33..<65)
        return CBOR.encode(.map([
            (.unsigned(1), .unsigned(2)),
            (.unsigned(3), .negative(Int64(es256Algorithm))),
            (.negative(-1), .unsigned(1)),
            (.negative(-2), .bytes(x)),
            (.negative(-3), .bytes(y)),
        ]))
    }

    /// 登録時の authenticatorData: rpIdHash (32) | flags | signCount (4, BE) | aaguid (16) | credentialIdLength (2, BE) | credentialId | COSE 公開鍵
    static func attestedAuthenticatorData(rpId: String, credentialID: Data, publicKeyX963: Data, userVerified: Bool) -> Data {
        var data = Data(SHA256.hash(data: Data(rpId.utf8)))
        data.append(flags(userVerified: userVerified, attested: true))
        data.append(contentsOf: [0, 0, 0, 0])
        data.append(aaguid)
        data.append(contentsOf: [UInt8(credentialID.count >> 8), UInt8(credentialID.count & 0xff)])
        data.append(credentialID)
        data.append(coseKey(publicKeyX963: publicKeyX963))
        return data
    }

    /// 認証時の authenticatorData: rpIdHash (32) | flags | signCount (4, BE)
    static func assertionAuthenticatorData(rpId: String, signCount: UInt32, userVerified: Bool) -> Data {
        var data = Data(SHA256.hash(data: Data(rpId.utf8)))
        data.append(flags(userVerified: userVerified, attested: false))
        data.append(contentsOf: [UInt8(signCount >> 24), UInt8((signCount >> 16) & 0xff), UInt8((signCount >> 8) & 0xff), UInt8(signCount & 0xff)])
        return data
    }

    /// flags: UP (0x01) | UV (0x04) | AT (0x40)。BE (backup eligible) / BS は付けない (端末内の鍵で、同期しない)
    static func flags(userVerified: Bool, attested: Bool) -> UInt8 {
        0x01 | (userVerified ? 0x04 : 0) | (attested ? 0x40 : 0)
    }

    /// attestationObject (fmt "none")。canonical CBOR の順序 (fmt, attStmt, authData)
    static func attestationObject(authenticatorData: Data) -> Data {
        CBOR.encode(.map([
            (.text("fmt"), .text("none")),
            (.text("attStmt"), .map([])),
            (.text("authData"), .bytes(authenticatorData)),
        ]))
    }

    /// 署名対象: authenticatorData || SHA-256(clientDataJSON)
    static func signedData(authenticatorData: Data, clientDataJSON: Data) -> Data {
        authenticatorData + Data(SHA256.hash(data: clientDataJSON))
    }

    /// rpId がオリジンに対して有効か (WebAuthn の「registrable domain suffix」)。オリジンのホストと同じか、ホストの親ドメインで、
    /// かつ公開サフィックス (com・co.jp 等) そのものではないこと
    static func isValidRpId(_ rpId: String, originHost: String, rules: PublicSuffixList.Rules = PublicSuffixList.bundled) -> Bool {
        let rp = rpId.lowercased()
        let host = originHost.lowercased()
        guard !rp.isEmpty else {
            return false
        }
        // ホストそのもの (effective domain) は PSL に無いドメイン (社内ドメイン・localhost) でも有効
        if host == rp {
            return true
        }
        // 親ドメインを指す場合だけ、公開サフィックス (com・co.jp 等) そのものでないことを PSL で確かめる
        return host.hasSuffix("." + rp) && rules.registrableDomain(host: rp) != nil
    }

    /// WebAuthn を許す「信頼できる」オリジンか。https と、ローカル開発用の localhost / 127.0.0.1 だけ
    /// (平文 http のページは改ざんされ得るため、既存 Passkey の assertion を要求させない)
    static func isTrustworthyOrigin(_ url: URL) -> Bool {
        guard let rawHost = url.host()?.lowercased(), !rawHost.isEmpty else {
            return false
        }
        switch url.scheme?.lowercased() {
        case "https":
            return true
        case "http":
            // URL.host() は IPv6 を角括弧なし (`::1`) で返すため、角括弧付きの表記も剥がしてから比べる
            let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
            if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" {
                return true
            }
            return isIPv4Loopback(host)
        default:
            return false
        }
    }

    /// Secure Contexts 仕様は 127.0.0.0/8 全体を potentially trustworthy とみなすため、127.0.0.1 だけでなく範囲で判定する
    private static func isIPv4Loopback(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 127
    }

    /// rp.id は Unicode 表記 (`例え.テスト`) でも来るため、比較・保存・rpIdHash の前に IDNA の ASCII 形 (A-label) に揃える
    static func normalizedRpId(_ rpId: String?) -> String? {
        guard let rpId, !rpId.isEmpty else { return nil }
        if let url = URL(string: "https://\(rpId)"), let host = CredentialMatcher.host(url: url) {
            return host
        }
        return rpId.lowercased()
    }
}

/// WebAuthn が要求する最小限の CBOR エンコーダ (RFC 8949)。デコードは RP 側で行うため持たない
indirect enum CBOR: Equatable {
    case unsigned(UInt64)
    /// 負の整数 (値そのもの。エンコードは -1 - n)
    case negative(Int64)
    case bytes(Data)
    case text(String)
    case array([CBOR])
    /// キーの順序は呼び出し側が canonical に並べる
    case map([(CBOR, CBOR)])

    static func == (lhs: CBOR, rhs: CBOR) -> Bool {
        encode(lhs) == encode(rhs)
    }

    static func encode(_ value: CBOR) -> Data {
        var out = Data()
        append(value, to: &out)
        return out
    }

    private static func append(_ value: CBOR, to out: inout Data) {
        switch value {
        case .unsigned(let n):
            appendHead(major: 0, value: n, to: &out)
        case .negative(let n):
            precondition(n < 0)
            appendHead(major: 1, value: UInt64(-1 - n), to: &out)
        case .bytes(let data):
            appendHead(major: 2, value: UInt64(data.count), to: &out)
            out.append(data)
        case .text(let text):
            let data = Data(text.utf8)
            appendHead(major: 3, value: UInt64(data.count), to: &out)
            out.append(data)
        case .array(let items):
            appendHead(major: 4, value: UInt64(items.count), to: &out)
            for item in items {
                append(item, to: &out)
            }
        case .map(let pairs):
            appendHead(major: 5, value: UInt64(pairs.count), to: &out)
            for (key, item) in pairs {
                append(key, to: &out)
                append(item, to: &out)
            }
        }
    }

    private static func appendHead(major: UInt8, value: UInt64, to out: inout Data) {
        let type = major << 5
        switch value {
        case 0..<24:
            out.append(type | UInt8(value))
        case 24..<0x100:
            out.append(type | 24)
            out.append(UInt8(value))
        case 0x100..<0x10000:
            out.append(type | 25)
            out.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xff)])
        case 0x10000..<0x1_0000_0000:
            out.append(type | 26)
            out.append(contentsOf: (0..<4).reversed().map { UInt8((value >> (8 * UInt64($0))) & 0xff) })
        default:
            out.append(type | 27)
            out.append(contentsOf: (0..<8).reversed().map { UInt8((value >> (8 * UInt64($0))) & 0xff) })
        }
    }
}

/// 保存する Passkey。秘密鍵は Secure Enclave が使える環境ではその dataRepresentation (SE の外では使えない)、
/// 使えない環境 (VM・GitHub Actions runner) では CryptoKit の P-256 秘密鍵の生表現。どちらも Keychain に置く
struct Passkey: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let rpId: String
    /// RP へ返す credential id (ランダム 32 バイト)
    let credentialID: Data
    let userHandle: Data
    let userName: String
    let userDisplayName: String
    let privateKey: Data
    let isSecureEnclave: Bool
    /// 公開鍵 (X9.63 非圧縮)
    let publicKeyX963: Data
    var signCount: UInt32
    let createdAt: Date
}

/// Passkey の保存先。Keychain 実装とユニットテスト用のメモリ実装
protocol PasskeyStore {
    func all() throws -> [Passkey]
    func save(passkey: Passkey) throws
    func delete(id: UUID) throws
}

final class InMemoryPasskeyStore: PasskeyStore {
    private var storage: [UUID: Passkey] = [:]

    func all() throws -> [Passkey] {
        storage.values.sorted { $0.createdAt > $1.createdAt }
    }

    func save(passkey: Passkey) throws {
        storage[passkey.id] = passkey
    }

    func delete(id: UUID) throws {
        storage[id] = nil
    }
}

/// WebAuthn の処理で起きたエラー。ページへは DOMException の name (NotAllowedError 等) と説明を返す
struct WebAuthnError: Error, CustomStringConvertible, Equatable {
    /// DOMException の name
    let name: String
    let description: String
}

/// `navigator.credentials.create / get` の要求を処理する authenticator。鍵の生成・署名と Passkey の保存を行う
final class PasskeyAuthenticator {
    private let store: any PasskeyStore
    /// Secure Enclave を使うか。テストと VM (runner) では使えないため、ソフトウェア鍵にフォールバックする
    private let usesSecureEnclave: Bool

    init(store: any PasskeyStore, usesSecureEnclave: Bool = SecureEnclave.isAvailable) {
        self.store = store
        self.usesSecureEnclave = usesSecureEnclave
    }

    /// `navigator.credentials.create` の publicKey オプション (注入スクリプトが base64url に直列化したもの)
    struct CreateRequest {
        var rpId: String?
        var userID: Data
        var userName: String
        var userDisplayName: String
        var challenge: String
        var algorithms: [Int]
        var excludeCredentialIDs: [Data]
        /// authenticatorSelection.authenticatorAttachment。この authenticator は platform なので cross-platform の要求には応じない
        var authenticatorAttachment: String?
    }

    struct CreateResponse {
        var credentialID: Data
        var clientDataJSON: Data
        var attestationObject: Data
        var authenticatorData: Data
        var publicKeyDER: Data
    }

    struct GetRequest {
        var rpId: String?
        var challenge: String
        var allowCredentialIDs: [Data]
    }

    struct GetResponse {
        var credentialID: Data
        var clientDataJSON: Data
        var authenticatorData: Data
        var signature: Data
        var userHandle: Data
    }

    /// 登録要求の検証 (本人確認の前に行い、鍵を作れない要求で確認ダイアログを出さない)。有効なら rpId を返す
    func validate(request: CreateRequest, origin: URL) throws -> String {
        let rpId = try validatedRpId(rpId: request.rpId, origin: origin)
        guard (1...64).contains(request.userID.count) else {
            throw WebAuthnError(name: "TypeError", description: "user.id は 1〜64 バイトでなければならない")
        }
        guard request.algorithms.contains(WebAuthn.es256Algorithm) else {
            throw WebAuthnError(name: "NotSupportedError", description: "ES256 以外のアルゴリズムには対応しない")
        }
        if request.authenticatorAttachment == "cross-platform" {
            throw WebAuthnError(name: "NotAllowedError", description: "セキュリティキー (cross-platform) の要求にはこの authenticator では応じない")
        }
        if try store.all().contains(where: { $0.rpId == rpId && request.excludeCredentialIDs.contains($0.credentialID) }) {
            throw WebAuthnError(name: "InvalidStateError", description: "この RP に登録済みの Passkey がある")
        }
        return rpId
    }

    /// オリジンが信頼できること (https / localhost) と rpId の有効性を確かめ、既定 (オリジンのホスト) を補った rpId を返す
    private func validatedRpId(rpId requested: String?, origin: URL) throws -> String {
        guard WebAuthn.isTrustworthyOrigin(origin), let host = CredentialMatcher.host(url: origin) else {
            throw WebAuthnError(name: "SecurityError", description: "信頼できないオリジン (https でない): \(origin.absoluteString)")
        }
        let rpId = WebAuthn.normalizedRpId(requested) ?? host
        guard WebAuthn.isValidRpId(rpId, originHost: host) else {
            throw WebAuthnError(name: "SecurityError", description: "rpId がオリジンに対して無効: \(rpId)")
        }
        return rpId
    }

    /// 登録。検証 → 鍵の生成 → 保存 → attestation ("none") の組み立て。同じ RP・同じ userHandle の既存 Passkey は、
    /// 新しい項目の保存に成功してから削除する (保存に失敗した時に既存の鍵を失わない)
    func makeCredential(request: CreateRequest, origin: URL, userVerified: Bool) throws -> CreateResponse {
        let rpId = try validate(request: request, origin: origin)
        let key = try makeKey()
        var credentialID = Data(count: 32)
        let randomStatus = credentialID.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw WebAuthnError(name: "UnknownError", description: "乱数の生成に失敗: \(randomStatus)")
        }
        let passkey = Passkey(
            id: UUID(), rpId: rpId, credentialID: credentialID, userHandle: request.userID, userName: request.userName,
            userDisplayName: request.userDisplayName, privateKey: key.privateKey, isSecureEnclave: key.isSecureEnclave,
            publicKeyX963: key.publicKeyX963, signCount: 0, createdAt: Date()
        )
        try store.save(passkey: passkey)
        // 同じ RP・userHandle の旧 Passkey は自動削除しない。ページが返り値を RP に登録できたか (ネットワーク/サーバー検証の成否)
        // はローカルからは分からず、削除してから登録が失敗すると旧鍵も新鍵も使えずログイン不能になるため。整理は明示的な操作で行う
        let authenticatorData = WebAuthn.attestedAuthenticatorData(rpId: rpId, credentialID: credentialID, publicKeyX963: key.publicKeyX963, userVerified: userVerified)
        return CreateResponse(
            credentialID: credentialID,
            clientDataJSON: WebAuthn.clientDataJSON(type: "webauthn.create", challenge: request.challenge, origin: PasskeyAuthenticator.originString(url: origin)),
            attestationObject: WebAuthn.attestationObject(authenticatorData: authenticatorData),
            authenticatorData: authenticatorData,
            publicKeyDER: key.publicKeyDER
        )
    }

    /// この RP で使える Passkey (allowCredentials があればその中のもの)。複数ある場合は呼び出し側が選ばせる
    func candidates(request: GetRequest, origin: URL) throws -> [Passkey] {
        let rpId = try validatedRpId(rpId: request.rpId, origin: origin)
        return try store.all().filter { $0.rpId == rpId && (request.allowCredentialIDs.isEmpty || request.allowCredentialIDs.contains($0.credentialID)) }
    }

    /// 認証。署名カウンタを進めて保存し、assertion を返す。カウンタは本人確認の待機中に別の要求が進めていることがあるため、
    /// 署名の直前にストアの最新値を読み直してから増やす (同期的に読み取り → 増分 → 保存まで行い、要求ごとに直列になる)
    /// abort された create の結果を捨てる。credentialID はネイティブが生成した 32 バイトの乱数で、削除は作成元オリジンの RP に属する項目に限る
    func discard(credentialID: Data, origin: URL) throws {
        let host = CredentialMatcher.host(url: origin) ?? ""
        for passkey in try store.all() where passkey.credentialID == credentialID && WebAuthn.isValidRpId(passkey.rpId, originHost: host) {
            try store.delete(id: passkey.id)
        }
    }

    func getAssertion(passkey selected: Passkey, request: GetRequest, origin: URL, userVerified: Bool) throws -> GetResponse {
        guard let passkey = try store.all().first(where: { $0.id == selected.id }) else {
            throw WebAuthnError(name: "NotAllowedError", description: "Passkey が削除された")
        }
        var updated = passkey
        updated.signCount &+= 1
        let authenticatorData = WebAuthn.assertionAuthenticatorData(rpId: passkey.rpId, signCount: updated.signCount, userVerified: userVerified)
        let clientDataJSON = WebAuthn.clientDataJSON(type: "webauthn.get", challenge: request.challenge, origin: PasskeyAuthenticator.originString(url: origin))
        let signature = try sign(passkey: passkey, data: WebAuthn.signedData(authenticatorData: authenticatorData, clientDataJSON: clientDataJSON))
        try store.save(passkey: updated)
        return GetResponse(credentialID: passkey.credentialID, clientDataJSON: clientDataJSON, authenticatorData: authenticatorData, signature: signature, userHandle: passkey.userHandle)
    }

    /// WebAuthn の origin 文字列 (scheme://host[:port]。既定ポートは省略)
    static func originString(url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        let port = url.port.flatMap { $0 == defaultPort ? nil : $0 }.map { ":\($0)" } ?? ""
        // IDN はオリジンのシリアライズでも A-label (punycode) にそろえる。encodedHost は IPv6 を角括弧付きで返すため一旦剥がす
        let rawHost = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.encodedHost ?? url.host())?.lowercased() ?? ""
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        // IPv6 は角括弧付きが正規の serialized origin
        return "\(scheme)://\(host.contains(":") ? "[\(host)]" : host)\(port)"
    }

    private struct GeneratedKey {
        var privateKey: Data
        var isSecureEnclave: Bool
        var publicKeyX963: Data
        var publicKeyDER: Data
    }

    private func makeKey() throws -> GeneratedKey {
        if usesSecureEnclave {
            let key = try SecureEnclave.P256.Signing.PrivateKey()
            return GeneratedKey(privateKey: key.dataRepresentation, isSecureEnclave: true, publicKeyX963: key.publicKey.x963Representation, publicKeyDER: key.publicKey.derRepresentation)
        }
        let key = P256.Signing.PrivateKey()
        return GeneratedKey(privateKey: key.rawRepresentation, isSecureEnclave: false, publicKeyX963: key.publicKey.x963Representation, publicKeyDER: key.publicKey.derRepresentation)
    }

    /// ECDSA (P-256, SHA-256) の DER 署名
    private func sign(passkey: Passkey, data: Data) throws -> Data {
        if passkey.isSecureEnclave {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: passkey.privateKey).signature(for: data).derRepresentation
        }
        return try P256.Signing.PrivateKey(rawRepresentation: passkey.privateKey).signature(for: data).derRepresentation
    }
}
