# 0001. macOS ネイティブ (Swift / SwiftUI + AppKit / WKWebView) で作り、Electron を採らない

## Status
Accepted (2026-08-28)

## Context
Tatami は tmux の操作体系で動く個人用ブラウザで、Password Manager を内蔵する (要件: https://github.com/bannzai/IdeaMemo/issues/191 )。企画段階の評価では Electron (Chromium + WebContentsView) が本命候補だった。ペインツリーの実装しやすさと、WebAuthn (Passkey) の API 層が Chromium に実装済みである点が理由だった。

一方で Password Manager の要件が固まり、バックエンドを Keychain (自前アイテム + iCloud 同期)、認証を Touch ID / Secure Enclave、OS 全体への自動入力を `ASCredentialProviderExtension` で提供することが決まった。これらはすべて Apple のネイティブ API で、Electron からは Node ネイティブモジュールの自作か Swift ヘルパープロセスとの IPC が必要になる。

作者の環境は macOS 26 で、動作確認の基盤 (simtunnel の macOS 版、`make macos` での `/Applications` 配置) も Xcode プロジェクトを前提に整っている。

## Decision
macOS ネイティブアプリとして作る。UI は SwiftUI を基本にし、ペインツリーの矩形配置とキーイベントの捕捉は AppKit (`NSViewRepresentable` / `NSEvent.addLocalMonitorForEvents`) で行う。Web コンテンツは `WKWebView` を使う。最小デプロイターゲットは macOS 26。

Password Manager の充填は WKWebView の Password AutoFill に頼らず (macOS の WKWebView では無効)、`WKUserScript` で注入した JavaScript がフォームを検出し、ネイティブ側の Keychain ストアと `WKScriptMessageHandler` で連携する。

Passkey は次の順で実現方法を検証する。(1) `navigator.credentials` を注入スクリプトで置き換え、Secure Enclave の鍵で署名する自前 authenticator を実装する。(2) それが成立しない場合は Apple の承認制 entitlement `com.apple.developer.web-browser.public-key-credential` を申請する。

## Consequences

**良い点:**
- Keychain・Touch ID・Secure Enclave・Credential Provider Extension・iCloud 同期を追加レイヤーなしで使える
- アプリのサイズと常駐メモリが Electron より小さく、既存の macOS 開発基盤 (Makefile・simtunnel・macos-install-app skill) をそのまま使える
- キーイベントをアプリ側で捕捉するため、どのサイト上でも prefix キーが効く

**悪い点 / 引き受けるリスク:**
- 任意サイトでの Passkey は WKWebView が標準ではサポートしない (Associated Domains 限定)。自前 authenticator の実装か entitlement 申請のどちらかが必須になる。自前 authenticator は WebAuthn 仕様 (CTAP 相当の attestation・assertion の組み立て) を自分で実装する負担を伴う
- Chrome 拡張は動かない。アドブロック・翻訳などは自作するか諦める
- WKWebView は Chromium に比べて開発者向け機能 (DevTools 相当) が弱い。Safari の Web Inspector を `isInspectable` で有効にして代替する
- Chromium ベースへ移る判断をした場合、ペインツリー・設定ファイル・Password Manager のストアはネイティブ側に残し、Web コンテンツ層だけを差し替える構造にしておく
