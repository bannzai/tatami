# Tatami

tmux の操作体系で画面分割 (ペイン) を扱う、macOS ネイティブの個人用ブラウザ。畳 = 部屋をタイリングするもの、のメタファー。

- 企画の起点: https://github.com/bannzai/IdeaMemo/issues/191 (アイデア・実現性評価・命名の全経緯)
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

### 3. ブラウザとしての生活品質

- 既定ブラウザとして登録できる (Info.plist の `CFBundleURLTypes` で http / https を宣言し、`NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` で登録する。macOS 12+。ユーザー確認ダイアログが出る)
- 他アプリからの URL オープンを新しいペイン / ウィンドウで受ける
- ページ内検索、履歴、ブックマーク (最小構成)、証明書エラーの表示、メディア / 位置情報などの権限ダイアログ
- Google アカウント系のログインが「安全でないブラウザ」判定を受ける場合は User-Agent を調整する

## 技術方針

- **macOS ネイティブ (Swift / SwiftUI + AppKit / WKWebView)**。Electron ではなくネイティブを選ぶ理由と引き受けるリスクは [ADR 0001](adr/0001-native-macos-app-with-wkwebview.md)
- macOS 26 以上専用 (作者の環境と GitHub Actions の `macos-26` runner に合わせる)。iOS 版は将来の検討事項
- バックエンド・DB・Analytics を持たない。データはすべて端末内 (ローカルファイル)。詳細は [ADR 0002](adr/0002-local-only-no-backend.md)
- `Tatami.xcodeproj` を構成の唯一の正とし、XcodeGen は初期作成にだけ使って `project.yml` は残さない ([ADR 0003](adr/0003-manage-xcode-project-directly.md))
- 動作確認は public リポジトリの利点を活かし、GitHub Actions の macOS runner 上で simtunnel (`/macos-simtunnel` skill) を通じて行える。ローカルでは `make macos` で `/Applications/Tatami.app` に配置して常用する

## 技術リスクと調査結果 (2026-08-28)

| リスク | 調査結果 | 対策 |
| --- | --- | --- |
| 既定ブラウザ登録 | `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` はユーザー確認ダイアログを伴う。http と https は個別に設定できない | 設定画面から登録ボタンで呼び出す。確認ダイアログは受け入れる |
| Chrome 拡張エコシステムが使えない | 仕様として受け入れる | アドブロック・翻訳は将来の検討枠。コンテンツブロッカーは `WKContentRuleList` で最小限を実装できる |

## やらないこと

- 収益化 (課金・広告・サブスクリプション)
- アカウント・サーバー同期
- Chrome 拡張の実行互換
- Windows / Linux 対応
- App Store 配布 (手元では `make macos` で配置する。公開する場合は GitHub Releases の DMG を検討する)

## 参考

- 分割ブラウザの比較: https://dev.to/warren_allen/best-browser-split-screen-extensions-for-2026-a-practical-guide-5ge8
- Zen Browser vs Vivaldi: https://supasidebar.com/blog/zen-browser-vs-vivaldi-2026
- 既定ブラウザの設定 API: https://developer.apple.com/documentation/appkit/nsworkspace/setdefaultapplication(at:toopenurlswithscheme:completion:)
