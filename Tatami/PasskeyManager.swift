import AppKit
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
                    excludeCredentialIDs: (body["excludeCredentials"] as? [String] ?? []).compactMap(WebAuthn.data(base64url:)),
                    authenticatorAttachment: body["authenticatorAttachment"] as? String
                )
                // 鍵を作れない要求 (無効な rpId・非対応のアルゴリズム・exclude 済み) では本人確認のダイアログを出さない
                _ = try authenticator.validate(request: request, origin: origin)
                let userVerified = try await verifyUser(body: body, reason: "\(origin.host() ?? "") に Passkey を登録する")
                let response = try authenticator.makeCredential(request: request, origin: origin, userVerified: userVerified)
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
                let userVerified = try await verifyUser(body: body, reason: "\(passkey.rpId) の Passkey (\(passkey.userName)) でサインインする")
                let response = try authenticator.getAssertion(passkey: passkey, request: request, origin: origin, userVerified: userVerified)
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

    /// WebAuthn の要求ごとに利用者の操作を求める (資格情報の自動ロックとは独立。ページのスクリプトが操作なしに assertion を得られないようにする)。
    /// `discouraged` では確認ダイアログでの同意 (存在確認 UP のみ。UV フラグは立てない)、`preferred` / `required` では
    /// Touch ID / パスワードでこの要求のために本人確認し、成功した時だけ UV を立てる。拒否・失敗・キャンセルは NotAllowedError
    private static func verifyUser(body: [String: Any], reason: String) async throws -> Bool {
        if body["userVerification"] as? String == "discouraged" {
            guard confirmPresence(reason: reason) else {
                throw WebAuthnError(name: "NotAllowedError", description: "利用者が許可しなかった")
            }
            return false
        }
        do {
            try await CredentialLock.shared.authenticateNow(reason: reason)
        } catch {
            throw WebAuthnError(name: "NotAllowedError", description: "\(error)")
        }
        return true
    }

    /// 存在確認 (UP) のための同意ダイアログ。モーダルで表示し、「許可」で true
    private static func confirmPresence(reason: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Passkey を使う"
        alert.informativeText = reason
        alert.addButton(withTitle: "許可").setAccessibilityIdentifier("passkeyAllowButton")
        alert.addButton(withTitle: "キャンセル").setAccessibilityIdentifier("passkeyCancelButton")
        return alert.runModal() == .alertFirstButtonReturn
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
