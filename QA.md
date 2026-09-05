---
feature: _root
verification: manual
last_verified_commit: 54b761324d624f9d828d64c66d169464a900b4a6
last_verified_at: 2026-09-02
---

# QA 全体ガイド

## 対象環境

- ローカルの macOS (作者機)。Debug ビルドの `tmp/DerivedData/Build/Products/Debug/Tatami.app` を対象にする
- バックエンドを持たないアプリのため環境の切り替えは無い。確認に使う外部サイトは example.com / example.org / httpbin.org / badssl.com などの中立サイトに限る (ユーザーの実アカウント・実セッションの内容をスクリーンショットに写さない)
- 検索語の解決 (検索エンジンで開く挙動) の確認に限り、固定の技術的な検索語 (例: `tmux split pane`) を既定の検索エンジンへ送ってよい (ユーザーの実閲覧内容や個人情報を含む語は送らない)

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

### File > New Window (Cmd+N) はハングする (2026-09-01、2026-09-02 に修正 #55 後も再現)

- 事象: 保存済みセッションが大きいと Cmd+N でアプリ全体が無応答になる ( https://github.com/bannzai/tatami/issues/51 )
- 2026-09-02 の再検証 ( https://github.com/bannzai/tatami/pull/55 マージ済みの Debug ビルド、ウィンドウ 10 個のセッション) でも再現した。新しい macOS ウィンドウは開かず、`tell application "Tatami" to activate` が -1712 で返らなくなり、キー入力にも反応しなくなる。ただし `sample` の main thread は `_DPSNextEvent` で待機しており、9-01 の「main thread がブロックする」形とはスタックが異なる (`tmp/qa/hang-b3-01.txt`)
- 対処: QA では Cmd+N を送らない。復旧は `pkill -9 -x Tatami` → 再起動

### System Events の keystroke が届かなくなることがある (2026-09-02)

- 事象: `tell application "System Events" to keystroke ...` を送っても Tatami に文字が入らない状態になる。Tatami は frontmost で、`click` (CGEvent のマウスイベント) と AX 参照は効くのに、文字入力だけが入らない。Secure Input も IME も無効で、原因は特定できていない
- 対処: CGEvent のキーコード送出に切り替える。`tmp/qa/keys.swift` を `swiftc -O tmp/qa/keys.swift -o tmp/qa/keys` でビルドし、`keys type <文字列>` (US 配列の仮想キーコードで送る) / `keys code <キーコード> [cmd|ctrl|shift|opt]` を使う。prefix は `keys code 17 ctrl` → delay → 後続キー
- `keys text` (CGEvent の `keyboardSetUnicodeString` 方式) はアドレスバーに届かないことがあるため、`keys type` (キーコード方式) を使う

### アドレスバーへの入力中に activate してはいけない (2026-09-02)

- 事象: アドレスバーに URL を入力してから撮影・確認のために `tell application "Tatami" to activate` を挟むと、入力内容が元の URL に巻き戻る。`tmp/qa/win.sh` と `tmp/qa/type.sh` が内部で activate するため、これらを入力の途中に挟むと失敗する
- 対処: 入力から Enter までの間は activate を挟まない。撮影はウィンドウ矩形を固定した `screencapture -x -R<x,y,w,h>` (`tmp/qa/shot2.sh`) で行う
- AX で `set value of <アドレスバー> to "<URL>"` すると表示は変わるが SwiftUI の binding に伝わらず、Enter では元の URL に遷移する。入力は必ずキーイベントで行う

### AppleEvent タイムアウトはハングのシグナル (2026-09-01)

- 事象: `tell application "Tatami" to activate` が -1712 でタイムアウトする時、アプリの main thread がブロックしている
- 対処: `sample Tatami 2` で main thread のスタックを取ってから `pkill -9` する

## 横断確認項目

- [ ] **起動と復元**: `make build-macos` の成果物が起動し、前回のセッションが復元され、status line にエラーが出ていない
  - 自動化: manual（osascript + screencapture）
  - 未検証: Password Manager 削除 (PR #57) 後の再検証は未実施。削除は起動経路・メニュー・status line・prefix 操作に触れるため、削除後のビルドで本項目と各 feature の回帰確認を夜間 QA で実施する (前回検証は削除前の 2026-09-01)
- [ ] **prefix が任意サイトで効く**: 実サイト (github.com 等の入力欄があるページ) 上でも prefix + キーがページに吸われず動作する
  - 自動化: manual（同上）
  - 未検証: 同上 (PR #57 後の再検証は未実施)
  - 確認に使うサイトは duckduckgo.com の検索結果ページ (`https://duckduckgo.com/?q=...`) にする。ページ内の検索入力欄にフォーカスを置き、サイト側のサジェストが開いた状態で prefix + キーが効くかを見る

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **起動と復元**: `make build-macos` の成果物が起動し、前回のセッションが復元され、status line にエラーが出ていない

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-02**

セッション `work` のウィンドウ 0〜7 が復元され、status line にエラー表示が無い (ユーザーの閲覧内容を写さないよう status line だけを切り出している):

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260902/7658d0b6-eb92-43b6-aa59-4cb27c19d8f9.png" width="320">

</details>

### **prefix が任意サイトで効く**: 実サイト (github.com 等の入力欄があるページ) 上でも prefix + キーがページに吸われず動作する

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-02**

duckduckgo.com の検索結果ページで、ページ内の検索入力欄にフォーカスを置いて `qa` をタイプした状態 (入力がページ側に入り、サイトのサジェストが開いている):

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260902/8b347234-efe3-405c-9760-9a2bda77718f.png" width="320">

その状態で prefix + `"` を送ると、ページに吸われず上下分割が実行され、新しい空ペインがフォーカスされる:

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260902/89f22d39-19c4-4f83-a39f-429cfde2e6ba.png" width="320">

</details>

</details>

## 機能別 QA.md

- [features/panes_windows/QA.md](features/panes_windows/QA.md) — ペイン分割・フォーカス・ウィンドウ操作
- [features/navigation/QA.md](features/navigation/QA.md) — アドレスバー・遷移・target=_blank・ページ内検索
- [features/persistence/QA.md](features/persistence/QA.md) — Cookie・セッション復元・履歴・ブックマーク
- [features/config/QA.md](features/config/QA.md) — tatami.conf の反映・再読込
- [features/platform/QA.md](features/platform/QA.md) — ダウンロード・証明書エラー・OS 連携
- [features/pr_jump/QA.md](features/pr_jump/QA.md) — PR クリックから tmux 作業スペースへのジャンプ

## QA 対象外

- Password Manager (資格情報の保存・充填・Passkey・CSV/CXF・Credential Provider Extension): 方向転換で削除予定のため QA 項目を作らない ( https://github.com/bannzai/tatami/issues/49 )
- 既定ブラウザ登録 (`:set-default-browser`): OS の確認ダイアログとユーザー環境の既定変更を伴い、QA での反復実行に向かない。普段使いは Chrome のため優先度も低い (#47)
- ソースは `Tatami/` のフラット構成で features ディレクトリを持たない。`features/` は QA ドキュメント専用のディレクトリで、コード変更と feature の対応は run-qa 実行時に diff の内容から判断する
