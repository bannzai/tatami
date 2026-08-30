import AppKit
import Foundation

/// アプリ全体で 1 つの Passkey authenticator と、ページからの要求 (message handler の body) の解釈。
/// 本人確認 (CredentialLock) を通してから鍵を使う
enum PasskeyManager {
    /// Passkey の保存先 (prefix + a の一覧と CXF の入出力からも使う)
    static let store: any PasskeyStore = {
        #if DEBUG
        // 開発中の動作確認で本物の Keychain に Passkey を書かないための切り替え (BrowserWindowModel の資格情報と同じ defaults キー)
        if UserDefaults.standard.bool(forKey: "TatamiUseInMemoryCredentialStore") {
            return InMemoryPasskeyStore()
        }
        #endif
        return KeychainPasskeyStore()
    }()

    static let authenticator = PasskeyAuthenticator(store: store)

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
                    challenge: try base64urlString(body, "challenge"),
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
                    challenge: try base64urlString(body, "challenge"),
                    allowCredentialIDs: (body["allowCredentials"] as? [String] ?? []).compactMap(WebAuthn.data(base64url:))
                )
                let candidates = try authenticator.candidates(request: request, origin: origin)
                guard let passkey = try choose(candidates: candidates, origin: origin, timeout: timeout(body: body)) else {
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
            case "discard":
                // ページ側で abort された create の結果。RP に渡っていない鍵なので削除する (無ければ何もしない)
                try authenticator.discard(credentialID: try data(body, "id"), origin: origin)
                return [:]
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

    /// 同じ RP の Passkey が複数ある時は、アカウントをポップアップで選ばせる。1 件ならそのまま、0 件なら nil。
    /// キャンセルと期限切れは NotAllowedError
    private static func choose(candidates: [Passkey], origin: URL, timeout: TimeInterval?) throws -> Passkey? {
        guard candidates.count > 1 else {
            return candidates.first
        }
        let alert = NSAlert()
        alert.messageText = "Passkey を選ぶ"
        alert.informativeText = "\(origin.host() ?? "") に複数の Passkey がある"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        for passkey in candidates {
            popup.addItem(withTitle: chooserTitle(passkey: passkey))
        }
        popup.setAccessibilityIdentifier("passkeyChooserPopup")
        alert.accessoryView = popup
        alert.addButton(withTitle: "選ぶ").setAccessibilityIdentifier("passkeyChooseButton")
        alert.addButton(withTitle: "キャンセル").setAccessibilityIdentifier("passkeyChooserCancelButton")
        // RP が期限を指定している場合、放置されたポップアップで要求が終わらないと再試行や別の認証手段へ進めないため、
        // 期限でモーダルを終える (alert を捕まえずに済むよう NSApplication で終える。表示中の window は runModal から戻る時に閉じる)
        let expiration = timeout.map { seconds -> DispatchWorkItem in
            let item = DispatchWorkItem {
                MainActor.assumeIsolated {
                    NSApplication.shared.abortModal()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
            return item
        }
        let response = alert.runModal()
        expiration?.cancel()
        guard response == .alertFirstButtonReturn else {
            throw WebAuthnError(name: "NotAllowedError", description: response == .abort ? "選択の期限が切れた" : "利用者がキャンセルした")
        }
        return candidates[popup.indexOfSelectedItem]
    }

    /// 選択ポップアップの 1 行。同じ RP に userName が同じ Passkey が複数あると (CXF からの取り込みで起きる) どれを選ぶか
    /// 判断できないため、表示名と credential ID の先頭を添えて一意に見分けられるようにする
    private static func chooserTitle(passkey: Passkey) -> String {
        let name = passkey.userName.isEmpty ? passkey.userDisplayName : passkey.userName
        let displayName = passkey.userDisplayName.isEmpty || passkey.userDisplayName == name ? "" : " (\(passkey.userDisplayName))"
        // credential ID は RP が発行する不透明な識別子。先頭 8 文字あれば同名の候補を見分けられる
        return "\(name.isEmpty ? "名前なし" : name)\(displayName) — \(WebAuthn.base64url(passkey.credentialID).prefix(8))"
    }

    /// 選択ポップアップを閉じる期限 (秒)。RP の `publicKey.timeout` (ミリ秒) を、
    /// WebAuthn L3 5.1.4 がクライアントに推奨する丸め範囲 (本人確認を伴う要求で 30〜600 秒) に収めて使う
    private static func timeout(body: [String: Any]) -> TimeInterval? {
        guard let milliseconds = (body["timeout"] as? NSNumber)?.doubleValue, milliseconds > 0 else {
            return nil
        }
        return min(max(milliseconds / 1000, 30), 600)
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

    /// base64url であることを検証した生文字列 (clientDataJSON へ埋め込む challenge 等。復号値でなく元の文字列が必要な場面で使う)
    private static func base64urlString(_ body: [String: Any], _ key: String) throws -> String {
        let value = try string(body, key)
        guard WebAuthn.data(base64url: value) != nil else {
            throw WebAuthnError(name: "TypeError", description: "\(key) が base64url でない")
        }
        return value
    }
}
