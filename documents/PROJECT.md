# Tatami

tmux の操作体系で画面分割を扱う、macOS ネイティブの開発用ブラウザ。複数並列開発のコックピットとして使う。畳 = 部屋をタイリングするもの、のメタファー。

- 企画の起点: https://github.com/bannzai/IdeaMemo/issues/191 (旧方針までの経緯)
- 方向転換の決定と経緯: https://github.com/bannzai/tatami/issues/47 (普段使いブラウザ → 開発用ブラウザ)
- 普段使いのブラウザは Chrome。Tatami は開発中の GitHub まわりの移動・閲覧に特化する
- 収益化はしない。リポジトリは public とし、秘匿情報 (API キー・トークン・個人情報) を一切コミットしない (`.claude/rules/no-secrets-in-repository.md`)

## コンセプト

複数並列開発中の「この window では何をしていたっけ」を無くす。GitHub issue に要件を書き、issue 単位の tmux window / git worktree で実装する運用と、ブラウザ側の issue / PR 閲覧との行き来コストをゼロにする。

- 差別化の核は **prefix キー方式の tmux 操作体系** (据え置き)。どのサイト上でも prefix が確実に効き、tmux ユーザーが指の記憶のまま操作できる
- Tatami はネイティブアプリとして tmux と並置する。tmux pane 内に内部ブラウザを埋め込む方向の検証は bannzai/castle 側の issue で行う (Tatami である必要がない環境・ツーリングの検証のため)
- 既存資産の温存は判断基準にしない。最高の DX を基準にする

## 対象ユーザー

作者本人 (tmux 常用・複数プロダクトの並列開発)。一般向けの機能 (同期アカウント・拡張機能ストア等) は作らない。

## 機能の方向 (#47)

1. **GitHub を効率よく移動できるブラウザ**: 画面分割・タブ (window)・omnibox・履歴を tmux like のショートカットで操作する (実装済みの基盤をそのまま使う)
2. **PR から作業スペースへのジャンプ**: GitHub 上の PR をクリックしたらターミナルを open し、tmux 操作で該当の作業スペースへ飛ぶ
   - `gh pr view <PR> --json headRefName` で PR の head ブランチ名 (例: issue-47) を取得する
   - リポジトリ名で `tmux switch-client` し、ブランチ名に該当する window があればそこへ移動、なければ `tmux new-window` で作る (既存の git worktree があれば restore する)
   - リポジトリの session が存在しない場合の挙動は未決 (TODO。エラーにはしない)
   - open するターミナルはハードコードせず `tatami.conf` で設定可能にする (現在は Alacritty。ターミナル乗り換えの要否は castle 側の検証 issue の結論に従う)
3. **夜間 E2E テストの継続**: QA を夜間に回し、普通のブラウザとしての基本要件 (URL 遷移・戻る/進む・target=_blank・ログインセッション維持・セッション復元・分割/zoom・prefix が任意サイトで効く) を守り続ける

検討枠 (優先度は上記の後): iOS Simulator の動画ストリーミング表示、進行中の PR / issue の一覧、ブラウザ上の選択テキストを Claude Code へ共有する仕組み

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
| `prefix + b` | ブックマークの一覧 | 追加 |

セッション (ペインツリー・各ペインの URL・ウィンドウ名) はローカルに保存し、次回起動で復元する。

## 機能要件

### 1. ペインとウィンドウ (実装済み)

- ペインは tmux と同じ二分木 (binary split) で管理し、リサイズ・入れ替え・zoom・レイアウト切り替えを持つ
- 各ペインは独立した Web コンテンツ (WKWebView) で、URL バー・戻る/進む/再読み込みを持つ
- `target=_blank` や `window.open` は新しいペインとして開く (別ウィンドウを増やさない)
- ダウンロードはユーザーの選んだ場所へ保存する (WKDownload)。保存先の選択は未実装で、現状は Downloads ディレクトリ固定 ( https://github.com/bannzai/tatami/issues/56 )
- Cookie・ローカルストレージは永続化する (WKWebsiteDataStore.default)。GitHub 等のログイン状態を再起動後も保つ

### 2. 設定ファイル (実装済み)

- `~/.config/tatami/tatami.conf` を起動時と `:source-file` で読む。`set -g prefix C-a` / `bind` / `unbind` の tmux 風文法
- 既定のホームページ・検索エンジン・User-Agent もここで設定する
- PR ジャンプで open するターミナルの指定もここに追加する (機能の方向 2)

### 3. ブラウザとしての生活品質

- 他アプリからの URL オープンを新しいペインで受ける、ページ内検索、履歴、ブックマーク (最小構成)、証明書エラーの表示、メディア / 位置情報などの権限ダイアログ (実装済み)
- 既定ブラウザ登録 (`:set-default-browser`) は実装済みだが、普段使いは Chrome のため常用しない。強化もしない

## 技術方針

- **macOS ネイティブ (Swift / SwiftUI + AppKit / WKWebView)**。Electron ではなくネイティブを選ぶ理由と引き受けるリスクは [ADR 0001](adr/0001-native-macos-app-with-wkwebview.md)
- macOS 26 以上専用 (作者の環境と GitHub Actions の `macos-26` runner に合わせる)
- バックエンド・DB・Analytics を持たない。データはすべて端末内。Password Manager の削除 (#49) が完了するまでは資格情報を Keychain に保存し、一部は iCloud Keychain と同期する。削除完了後はローカルファイルのみになる。詳細は [ADR 0002](adr/0002-local-only-no-backend.md)
- `Tatami.xcodeproj` を構成の唯一の正とし、XcodeGen は使わない ([ADR 0003](adr/0003-manage-xcode-project-directly.md))
- 動作確認は public リポジトリの利点を活かし、GitHub Actions の macOS runner 上で simtunnel (`/macos-simtunnel` skill) を通じて行える。ローカルでは `make macos` で `/Applications/Tatami.app` に配置する

## やらないこと

- Password Manager (方向転換で削除する: https://github.com/bannzai/tatami/issues/49 。Cookie / セッション永続化によるログイン維持は残す)
- 収益化 (課金・広告・サブスクリプション)
- アカウント・サーバー同期
- Chrome 拡張の実行互換
- Windows / Linux 対応
- App Store 配布 (手元では `make macos` で配置する。公開する場合は GitHub Releases の DMG を検討する)
- 普段使いブラウザとしての一般機能の拡充 (既定ブラウザ登録まわりの強化等)
