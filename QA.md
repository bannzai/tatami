---
feature: _root
verification: manual
last_verified_commit: null
last_verified_at: null
---

# QA 全体ガイド

## 対象環境

- ローカルの macOS (作者機)。Debug ビルドの `tmp/DerivedData/Build/Products/Debug/Tatami.app` を対象にする
- バックエンドを持たないアプリのため環境の切り替えは無い。確認に使う外部サイトは example.com / example.org / httpbin.org / badssl.com などの中立サイトに限る (ユーザーの実アカウント・実セッションの内容をスクリーンショットに写さない)

## 起動方法

```sh
make build-macos                                            # ビルド (ログ検証は CLAUDE.md の検証方法に従う)
pkill -x Tatami; open tmp/DerivedData/Build/Products/Debug/Tatami.app
```

- QA 終了時は必ず `pkill -x Tatami` 後に `open /Applications/Tatami.app` で普段使いの Release 版へ戻す
- 夜間 (0:30〜7:00) に実行する。日中はユーザーが画面を使っているため GUI を奪わない (リポジトリ CLAUDE.md「タスクの進め方」)

## ログイン方法

- ログインが要る QA 項目は無い。Cookie の永続化は httpbin.org の Cookie 残存で確認する (実サイトのログイン維持はユーザーの利用で代替)

## 動作確認手段

- macOS アプリのため mobile-mcp / maestro は使わない。osascript (System Events のキー送信) + `screencapture -R<x,y,w,h>` (ウィンドウ領域の切り出し) で操作・撮影し、スクリーンショットは gh-r2-image でアップロードして QA.md に記録する
- ウィンドウ領域は `tell application "System Events" to tell process "Tatami" to get position/size of front window` で取得する
- prefix はユーザーの実運用 conf (`~/.config/tatami/tatami.conf`) の `C-t` を前提にする

### 再現が難しい操作の手順

- ペイン分割: `keystroke "t" using control down` → delay 0.4 → `keystroke "\""` (上下) / `keystroke "%"` (左右)
- ウィンドウ選択: prefix → 数字キー。status line の `*` が現在ウィンドウ
- 再読み込みが起きたかの判定: https://httpbin.org/uuid を開き、表示される UUID が変わるかを見る
- ユーザーの実 conf を書き換えずに設定を試す: 一時ファイルに設定を書き、`prefix + :` → `:source-file <絶対パス>` で重ねて適用する。引数なしの `:source-file` で既定の `~/.config/tatami/tatami.conf` から読み直して元に戻す
- httpbin.org の応答 (`/get` 等) には `"origin"` としてグローバル IP が載る。撮影範囲をその行の手前までに切る (`screencapture -R<x>,<y>,<w>,<h>` の h を縮める)
- Web ページ内のリンク・要素のクリック: osascript の `click at {x, y}` は AX アクションのため WKWebView に効かない。CGEvent (`mouseMoved` → `leftMouseDown` → `leftMouseUp`) を送る小さな Swift コマンドを `swiftc` でビルドして使う
- `target=_blank` などページを用意して確かめる項目: `python3 -m http.server <ポート>` でローカルに立て、`localhost:<ポート>/<ファイル>` で開く。`data:` URL はアドレスバーの解決 (`AddressInput.resolve`) で URL 扱いにならないため使えない

## 実行ナレッジ

### File > New Window (Cmd+N) はハングする (2026-09-01)

- 事象: 保存済みセッションが大きいと Cmd+N でアプリ全体が無応答になる ( https://github.com/bannzai/tatami/issues/51 )
- 対処: QA では Cmd+N を送らない。復旧は `pkill -9 -x Tatami` → 再起動。修正されたら本知見を消す

### AppleEvent タイムアウトはハングのシグナル (2026-09-01)

- 事象: `tell application "Tatami" to activate` が -1712 でタイムアウトする時、アプリの main thread がブロックしている
- 対処: `sample Tatami 2` で main thread のスタックを取ってから `pkill -9` する

## 横断確認項目

- [ ] **起動と復元**: `make build-macos` の成果物が起動し、前回のセッションが復元され、status line にエラーが出ていない
  - 自動化: manual（osascript + screencapture）
- [ ] **prefix が任意サイトで効く**: 実サイト (github.com 等の入力欄があるページ) 上でも prefix + キーがページに吸われず動作する
  - 自動化: manual（同上）

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **起動と復元**: `make build-macos` の成果物が起動し、前回のセッションが復元され、status line にエラーが出ていない

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **prefix が任意サイトで効く**: 実サイト (github.com 等の入力欄があるページ) 上でも prefix + キーがページに吸われず動作する

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

</details>

## 機能別 QA.md

- [features/panes_windows/QA.md](features/panes_windows/QA.md) — ペイン分割・フォーカス・ウィンドウ操作
- [features/navigation/QA.md](features/navigation/QA.md) — アドレスバー・遷移・target=_blank・ページ内検索
- [features/persistence/QA.md](features/persistence/QA.md) — Cookie・セッション復元・履歴・ブックマーク
- [features/config/QA.md](features/config/QA.md) — tatami.conf の反映・再読込
- [features/platform/QA.md](features/platform/QA.md) — ダウンロード・証明書エラー・OS 連携

## QA 対象外

- Password Manager (資格情報の保存・充填・Passkey・CSV/CXF・Credential Provider Extension): 方向転換で削除予定のため QA 項目を作らない ( https://github.com/bannzai/tatami/issues/49 )
- 既定ブラウザ登録 (`:set-default-browser`): OS の確認ダイアログとユーザー環境の既定変更を伴い、QA での反復実行に向かない。普段使いは Chrome のため優先度も低い (#47)
- ソースは `Tatami/` のフラット構成で features ディレクトリを持たない。`features/` は QA ドキュメント専用のディレクトリで、コード変更と feature の対応は run-qa 実行時に diff の内容から判断する
