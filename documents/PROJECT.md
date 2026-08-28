# Tatami

tmux の操作体系で画面分割 (ペイン) を扱う、macOS ネイティブの個人用ブラウザ。畳 = 部屋をタイリングするもの、のメタファー。

- 企画の起点: https://github.com/bannzai/IdeaMemo/issues/191 (アイデア・実現性評価・命名・Password Manager 要件の全経緯)
- 収益化はしない。作者の手元で常用するツールとして作り、後から OSS として公開する可能性がある。そのためリポジトリは最初から public とし、秘匿情報 (API キー・トークン・個人情報) を一切コミットしない (`.claude/rules/no-secrets-in-repository.md`)

## コンセプト

差別化の核は「分割表示」ではなく **prefix キー方式の tmux 操作体系**。分割表示だけなら Zen Browser / Vivaldi が既に実現しており、Chrome もネイティブ分割を開発中。tmux ユーザーが指の記憶のままブラウザを操作できることに価値を置く。

- 一言説明: 「tmux のキーバインドで動くブラウザ」
- どのサイト上でも prefix が確実に効く (アプリ側でキーを捕捉する。Chrome Extension 方式の `chrome://` やストア上で効かない穴を作らない)
- 設定は `~/.config/tatami/tatami.conf` のテキストファイル (`.tmux.conf` 風)。キーバインドと既定値をここで上書きする

## 対象ユーザー

作者本人 (tmux 常用、Chrome からの移行を検討中)。公開した場合の想定ユーザーも「tmux を日常的に使う開発者」に限定し、一般向けの機能 (同期アカウント・拡張機能ストア等) は作らない。

## コア体験 (キーバインドの既定値)

prefix の既定は tmux と同じ `Ctrl+b`。すべて `tatami.conf` で変更できる。

| キー | 動作 | tmux との対応 |
| --- | --- | --- |
| `prefix + "` | 現在のペインを上下に分割 (新しいペインは空のページ) | 同じ |
| `prefix + %` | 現在のペインを左右に分割 | 同じ |
| `prefix + o` | 次のペインへフォーカス | 同じ |
| `prefix + ;` | 直前のペインへフォーカス | 同じ |
| `prefix + h/j/k/l`, `prefix + 矢印` | 方向でペインを選ぶ | vi 風の追加 |
| `prefix + x` | ペインを閉じる | 同じ |
| `prefix + z` | ペインの zoom (全面表示) を切り替える | 同じ |
| `prefix + {` / `}` | ペインの入れ替え | 同じ |
| `prefix + Space` | レイアウトの切り替え (even-horizontal / even-vertical / tiled) | 同じ |
| `prefix + c` | 新しいウィンドウ (ブラウザのタブ相当) | 同じ |
| `prefix + n` / `p` / `0-9` | ウィンドウの移動・選択 | 同じ |
| `prefix + ,` / `&` / `w` | ウィンドウの名前変更・閉じる・一覧 | 同じ |
| `prefix + s` / `$` | セッションの一覧・名前変更 | 同じ |
| `prefix + d` | セッションを閉じずにウィンドウを隠す (再起動後も復元) | detach |
| `prefix + :` | コマンドプロンプト (`:open <url>`, `:find <text>`, `:bind`, `:source-file` 等) | 同じ |
| `prefix + /` | URL・検索語の入力 (omnibox) | 追加 |
| `prefix + [` | ページ内検索 | copy-mode の読み替え |
| `prefix + a` | 資格情報の検索・充填 (Password Manager) | 追加 |

セッション (ペインツリー・各ペインの URL・ウィンドウ名) はローカルに保存し、次回起動で復元する。

## 機能要件

### 1. ペインとウィンドウ (MVP の中核)

- ペインは tmux と同じ二分木 (binary split) で管理し、リサイズ・入れ替え・zoom・レイアウト切り替えを持つ
- 各ペインは独立した Web コンテンツ (WKWebView) で、URL バー・戻る/進む/再読み込みを持つ
- `target=_blank` や `window.open` は新しいペインとして開く (別ウィンドウを増やさない)
- ダウンロードはユーザーの選んだ場所へ保存する (WKDownload)
- Cookie・ローカルストレージは永続化する (WKWebsiteDataStore.default)。ログイン状態を再起動後も保つ

### 2. 設定ファイル

- `~/.config/tatami/tatami.conf` を起動時と `:source-file` で読む。`set -g prefix C-a` / `bind -n ...` / `unbind` の tmux 風文法
- 既定のホームページ・検索エンジン・User-Agent もここで設定する

### 3. Password Manager (内蔵。要件の SSOT は https://github.com/bannzai/IdeaMemo/issues/191#issuecomment-5449063461 )

- 外部の拡張機能に依存しない独自ストア。バックエンドは Keychain (自前アイテム、`kSecAttrSynchronizable` で iCloud 同期)
- Chrome 互換 CSV (`name, url, username, password, note`) のインポート / エクスポート。「いつでも Chrome / Safari / Bitwarden / 1Password に戻れる」を担保する
- ログインフォーム送信の検出 → 保存・更新の提案。サインアップフォーム検出 → 強いパスワードの生成・提案
- 1 ドメインに複数資格情報を持てるデータモデルと候補選択 UI (`prefix + a`)
- Touch ID / パスワードでのアンロックと一定時間での自動ロック
- Credential Provider Extension (`ASCredentialProviderExtension`) を同梱し、Safari を含む OS 全体が Tatami のストアから自動入力できるようにする
- Passkey (WebAuthn) 対応。FIDO Credential Exchange Format (CXF) での import / export を前提に設計する
- 検討枠 (優先度低): TOTP、クリップボードの自動クリア、漏洩チェック (HIBP k-匿名 API)

### 4. ブラウザとしての生活品質

- 既定ブラウザとして登録できる (Info.plist の `CFBundleURLTypes` で http / https を宣言し、`NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` で登録する。macOS 12+。ユーザー確認ダイアログが出る)
- 他アプリからの URL オープンを新しいペイン / ウィンドウで受ける
- ページ内検索、履歴、ブックマーク (最小構成)、証明書エラーの表示、メディア / 位置情報などの権限ダイアログ
- Google アカウント系のログインが「安全でないブラウザ」判定を受ける場合は User-Agent を調整する

## 技術方針

- **macOS ネイティブ (Swift / SwiftUI + AppKit / WKWebView)**。Electron ではなくネイティブを選ぶ理由と引き受けるリスクは [ADR 0001](adr/0001-native-macos-app-with-wkwebview.md)
- macOS 26 以上専用 (作者の環境と GitHub Actions の `macos-26` runner に合わせる)。iOS 版は将来の検討事項とし、Keychain のストアを共有できる形にだけしておく
- バックエンド・DB・Analytics を持たない。データはすべて端末内 (Keychain とローカルファイル)。詳細は [ADR 0002](adr/0002-local-only-no-backend.md)
- `Tatami.xcodeproj` を構成の唯一の正とし、XcodeGen は初期作成にだけ使って `project.yml` は残さない ([ADR 0003](adr/0003-manage-xcode-project-directly.md))
- 動作確認は public リポジトリの利点を活かし、GitHub Actions の macOS runner 上で simtunnel (`/macos-simtunnel` skill) を通じて行える。ローカルでは `make macos` で `/Applications/Tatami.app` に配置して常用する

## 技術リスクと調査結果 (2026-08-28)

| リスク | 調査結果 | 対策 |
| --- | --- | --- |
| WKWebView で OS の Password AutoFill が動かない | macOS の WKWebView では Password AutoFill が無効 (Safari / SFSafariViewController 限定) | もともと自前のフォーム検出と充填 (JavaScript 注入) で設計している。影響なし |
| WKWebView で任意サイトの Passkey (WebAuthn) が動かない | WKWebView の WebAuthn は Associated Domains (自アプリのドメイン) に限定される。任意サイトで動かすには Apple の承認制 entitlement `com.apple.developer.web-browser.public-key-credential` が必要 (Apple Developer Forums thread 774904 の報告) | 第一候補: `navigator.credentials` を WKUserScript で置き換え、Secure Enclave の鍵で署名する自前 authenticator を実装する (entitlement 不要)。第二候補: entitlement を申請する。どちらで行くかは実装前のスパイクで決める (ロードマップの子 issue) |
| Credential Provider Extension の対応範囲 | macOS 13+ でシステム設定から第三者アプリを自動入力プロバイダに指定できる。Passkey のプロバイダは macOS 14+ | 最小デプロイターゲットが macOS 26 のため制約なし |
| 既定ブラウザ登録 | `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` はユーザー確認ダイアログを伴う。http と https は個別に設定できない | 設定画面から登録ボタンで呼び出す。確認ダイアログは受け入れる |
| Chrome 拡張エコシステムが使えない | 仕様として受け入れる (Password Manager を内蔵するのはこの弱点の解消のため) | アドブロック・翻訳は将来の検討枠。コンテンツブロッカーは `WKContentRuleList` で最小限を実装できる |

## やらないこと

- 収益化 (課金・広告・サブスクリプション)
- アカウント・サーバー同期 (iCloud Keychain 同期は Apple の仕組みに乗るだけ)
- Chrome 拡張の実行互換
- Windows / Linux 対応
- App Store 配布 (手元では `make macos` で配置する。公開する場合は GitHub Releases の DMG を検討する)

## 参考

- 分割ブラウザの比較: https://dev.to/warren_allen/best-browser-split-screen-extensions-for-2026-a-practical-guide-5ge8
- Zen Browser vs Vivaldi: https://supasidebar.com/blog/zen-browser-vs-vivaldi-2026
- Chrome のパスワードエクスポート形式: https://support.google.com/chrome/answer/13068232?hl=en
- macOS の Passkey 対応状況: https://passkeys.dev/docs/reference/macos/
- WKWebView ベースのブラウザでの WebAuthn: https://developer.apple.com/forums/thread/774904
- Credential Provider Extension: https://support.apple.com/guide/security/credential-provider-extensions-sec6319ac7b9/web
- 既定ブラウザの設定 API: https://developer.apple.com/documentation/appkit/nsworkspace/setdefaultapplication(at:toopenurlswithscheme:completion:)
