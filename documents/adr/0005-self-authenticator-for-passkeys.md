# 0005. Passkey は navigator.credentials の置き換えによる自前 authenticator で実装する

日付: 2026-08-29

## 状況

WKWebView は任意サイトの WebAuthn を標準では扱えない (Associated Domains 限定)。任意サイトで動かすには Apple の承認制 entitlement `com.apple.developer.web-browser.public-key-credential` が必要になる (documents/PROJECT.md 技術リスク)。スパイク (#18) で、`navigator.credentials.create / get` を注入スクリプトで置き換えて自前の authenticator に転送する方式が成立するかを実測した。

## 決定

自前 authenticator で行く (go)。entitlement の申請は行わない。

- `navigator.credentials` をページの world に注入した WKUserScript で置き換え、要求を返信付きの script message handler (`WKScriptMessageHandlerWithReply`) へ渡す。ArrayBuffer は base64url の文字列で受け渡し、`PublicKeyCredential` / `AuthenticatorAttestationResponse` / `AuthenticatorAssertionResponse` の prototype を継承した own property のオブジェクトを返す
- 鍵は Secure Enclave の P-256 (`SecureEnclave.P256.Signing.PrivateKey`)。Secure Enclave が無い環境 (VM・GitHub Actions runner) では CryptoKit のソフトウェア鍵にフォールバックする
- attestation は "none"、アルゴリズムは ES256 だけ。authenticatorData・COSE 鍵・attestationObject は自前の最小 CBOR エンコーダで組み立てる
- 利用者の確認は要求ごとに行う (資格情報の自動ロックの状態とは独立。ページのスクリプトが操作なしに assertion を得られないようにする)。RP の `userVerification` が `preferred` / `required` なら Touch ID / パスワードでこの要求のために本人確認して UV を立て、`discouraged` なら同意ダイアログでの存在確認 (UP) だけで UV は立てない
- 受け付けるオリジンは https (と localhost)。別オリジンの iframe からの要求は拒む (Permissions Policy の委譲は解釈しない)
- Passkey は資格情報と違い、共有 access group にも iCloud 同期にも乗せない (Secure Enclave の鍵は端末固有)
- Passkey は資格情報と別の Keychain service に保存する (`KeychainPasskeyStore`)
- 対応しないもの: `cross-platform` (セキュリティキー) の要求、conditional mediation、attestation "direct"。`timeout` の期限切れと同一 rpId の複数 Passkey の選択は #19

## 実測 (2026-08-29, GitHub Actions macos-26 runner + simtunnel, Debug ad-hoc 署名)

- https://webauthn.io で Register → 「Success! Now try to authenticate...」、Authenticate → `/profile` へ遷移 (登録とログインの両方がサーバー側の検証を通過)。runner には Secure Enclave が無いためソフトウェア鍵の経路。本人確認は runner のパスワードを操作できないため `userVerification=discouraged` で省いた
- 所要: スパイクの実装は約 1 日分の作業。詰まった点は (1) Swift の複数行文字列の中の正規表現のエスケープ (`/\\//g` が JS では `/\\/` ÷ `g` になり `Can't find variable: g`)、(2) ネイティブ prototype の getter は `Object.assign` で上書きできず own property を `defineProperty` で定義する必要があった、の 2 つ
- 未検証: Secure Enclave の鍵での実サイト検証 (作者の Mac でのみ可能)、conditional mediation (autofill UI)、同一 rpId の複数 Passkey の選択 UI。これらは #19 で扱う

## 結果

- 任意サイトで Passkey が使える。entitlement の承認待ちと審査を避けられる
- ページのスクリプトから見える `navigator.credentials` を置き換えるため、ページ側が `instanceof` や prototype を厳密に検査する場合の互換性は都度対応が必要になる
- 自前 authenticator は AAGUID がゼロで attestation "none" のため、attestation を要求する RP (`attestation: "direct"` を必須にするサイト) では登録できない。個人用ブラウザの割り切りとして受け入れる
