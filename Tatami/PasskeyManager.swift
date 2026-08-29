import Foundation

/// アプリ全体で 1 つの Passkey authenticator と、ページからの要求 (message handler の body) の解釈。
/// 本人確認 (CredentialLock) を通してから鍵を使う
enum PasskeyManager {
    static let authenticator: PasskeyAuthenticator = {
        #if DEBUG
        // 開発中の動作確認で本物の Keychain に Passkey を書かないための切り替え (BrowserWindowModel の資格情報と同じ defaults キー)
        if UserDefaults.standard.bool(forKey: "TatamiUseInMemoryCredentialStore") {
            return PasskeyAuthenticator(store: InMemoryPasskeyStore())
        }
        #endif
        return PasskeyAuthenticator(store: KeychainPasskeyStore())
    }()

    /// ページからの要求を処理し、注入スクリプトへ返す辞書 (成功なら各フィールドの base64url、失敗なら error / name) を作る
    static func handle(body: [String: Any], origin: URL?) async -> [String: Any] {
        do {
            guard let origin else {
                throw WebAuthnError(name: "SecurityError", description: "フレームのオリジンが不明")
            }
            switch body["op"] as? String {
            case "create":
                let request = PasskeyAuthenticator.CreateRequest(
                    rpId: body["rpId"] as? String,
                    userID: try data(body, "userId"),
                    userName: body["userName"] as? String ?? "",
                    userDisplayName: body["userDisplayName"] as? String ?? "",
                    challenge: try string(body, "challenge"),
                    algorithms: (body["algorithms"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue },
                    excludeCredentialIDs: (body["excludeCredentials"] as? [String] ?? []).compactMap(WebAuthn.data(base64url:))
                )
                try await CredentialLock.shared.ensureUnlocked(reason: "\(origin.host() ?? "") に Passkey を登録する")
                let response = try authenticator.makeCredential(request: request, origin: origin, userVerified: true)
                return [
                    "id": WebAuthn.base64url(response.credentialID),
                    "clientDataJSON": WebAuthn.base64url(response.clientDataJSON),
                    "attestationObject": WebAuthn.base64url(response.attestationObject),
                    "authenticatorData": WebAuthn.base64url(response.authenticatorData),
                    "publicKeyDER": WebAuthn.base64url(response.publicKeyDER),
                ]
            case "get":
                let request = PasskeyAuthenticator.GetRequest(
                    rpId: body["rpId"] as? String,
                    challenge: try string(body, "challenge"),
                    allowCredentialIDs: (body["allowCredentials"] as? [String] ?? []).compactMap(WebAuthn.data(base64url:))
                )
                let candidates = try authenticator.candidates(request: request, origin: origin)
                // スパイクでは最新の 1 件を使う。同じ RP の複数 Passkey の選択 UI は #19 で扱う
                guard let passkey = candidates.first else {
                    throw WebAuthnError(name: "NotAllowedError", description: "このサイトの Passkey は無い")
                }
                try await CredentialLock.shared.ensureUnlocked(reason: "\(passkey.rpId) の Passkey (\(passkey.userName)) でサインインする")
                let response = try authenticator.getAssertion(passkey: passkey, request: request, origin: origin, userVerified: true)
                return [
                    "id": WebAuthn.base64url(response.credentialID),
                    "clientDataJSON": WebAuthn.base64url(response.clientDataJSON),
                    "authenticatorData": WebAuthn.base64url(response.authenticatorData),
                    "signature": WebAuthn.base64url(response.signature),
                    "userHandle": WebAuthn.base64url(response.userHandle),
                ]
            default:
                throw WebAuthnError(name: "NotSupportedError", description: "不明な要求")
            }
        } catch let error as WebAuthnError {
            return ["error": error.description, "name": error.name]
        } catch {
            return ["error": "\(error)", "name": "NotAllowedError"]
        }
    }

    private static func string(_ body: [String: Any], _ key: String) throws -> String {
        guard let value = body[key] as? String, !value.isEmpty else {
            throw WebAuthnError(name: "TypeError", description: "\(key) が無い")
        }
        return value
    }

    private static func data(_ body: [String: Any], _ key: String) throws -> Data {
        guard let value = WebAuthn.data(base64url: try string(body, key)) else {
            throw WebAuthnError(name: "TypeError", description: "\(key) が base64url でない")
        }
        return value
    }
}
