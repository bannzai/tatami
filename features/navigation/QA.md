---
feature: navigation
verification: manual
last_verified_commit: 57deef2d2255effb6e03c2eb84d4de8e066d4bdc
last_verified_at: 2026-09-01
---

# navigation QA

## 関連リンク

- 仕様: https://github.com/bannzai/tatami/blob/main/documents/PROJECT.md (コア体験の表・機能要件 1)
- 関連: https://github.com/bannzai/tatami/pull/48 (空ページのアドレスバー挙動)

## 仕様チェックリスト

| ID | 期待挙動 | 対応項目 |
|----|---------|---------|
| S1 | `prefix + /` でアドレスバーへフォーカスし、URL を入力すると遷移する | URL 遷移 |
| S2 | スキーム無しのホスト (`example.com`) は https を補って開き、検索語は検索エンジンで開く | 入力の解決 |
| S3 | 空ページ (about:blank) ではアドレスバーが空欄になる | 空ページの表示 |
| S4 | 戻る・進む・再読み込みが動く | 戻る・進む・再読み込み |
| S5 | ページ内のリンククリックで同じペインが遷移する | リンククリック |
| S6 | `target=_blank` / `window.open` は新しいペインとして開き、別ウィンドウを増やさない | target=_blank |
| S7 | `prefix + [` でページ内検索が開き、ヒットへ移動できる | ページ内検索 |
| S8 | `prefix + :` のコマンドプロンプトから `:open <url>` で遷移できる | コマンドプロンプト |

## 1. アドレスバーと遷移

- [x] **URL 遷移**: `prefix + /` → `https://example.com` + Enter でフォーカス中のペインが遷移し、アドレスバーとウィンドウ名が追従する
  - 自動化: manual（macOS アプリのため osascript のキー送信 + screencapture の目視で確認する）
- [x] **入力の解決**: `example.com` (スキーム無し) は https で開き、`tmux split pane` (空白入り) は検索エンジンの結果ページで開く
  - 自動化: manual（同上）
- [x] **空ページの表示**: フォーカス中のペインが about:blank の時、アドレスバーは「about:blank」ではなく空欄 + プレースホルダー表示になる
  - 自動化: manual（同上。検証済み実例: https://github.com/bannzai/tatami/pull/48#issuecomment-5481009154 ）

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **URL 遷移**: `prefix + /` → `https://example.com` + Enter でフォーカス中のペインが遷移し、アドレスバーとウィンドウ名が追従する

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

アドレスバーが `https://example.com/`、status line のウィンドウ名が `8:example.com` に追従する

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/c54f3da0-ba50-473d-8043-d55da74ec392.png" width="320">

</details>

### **入力の解決**: `example.com` (スキーム無し) は https で開き、`tmux split pane` (空白入り) は検索エンジンの結果ページで開く

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

`example.org` の入力が `https://example.org/` として開く

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/ecb71081-3a42-4fb8-b63b-e4f073897343.png" width="320">

`tmux split pane` は既定の検索エンジンの `https://www.google.com/search?q=tmux%20split%20pane` で開く

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/baba8e31-13e4-4568-9254-572f431e4492.png" width="320">

</details>

### **空ページの表示**: フォーカス中のペインが about:blank の時、アドレスバーは「about:blank」ではなく空欄 + プレースホルダー表示になる

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

`prefix + c` で開いた空ページのアドレスバーがプレースホルダー「URL または検索語」の空欄になる

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/cd5f51f1-c3c8-4d4f-acaf-3fee325d750f.png" width="320">

</details>

</details>

---

## 2. ページ内の移動

- [x] **リンククリック**: ページ内リンクのクリックで同じペインが遷移する (https://example.com の「Learn more」等)
  - 自動化: manual（osascript のマウスクリック + screencapture）
  - osascript の `click at {x, y}` は AX アクションのため WKWebView のリンクに効かない。CGEvent で実マウスイベントを送る (root QA.md「再現が難しい操作の手順」参照)
- [x] **戻る・進む・再読み込み**: ツールバーの ← / → / ⟳ ボタンで履歴を移動・再読み込みできる
  - 自動化: manual（同上）
- [x] **target=_blank**: `target=_blank` のリンクが新しいペインとして開き、別の macOS ウィンドウは増えない
  - 自動化: manual（同上）
  - 確認用ページは `python3 -m http.server 8731` でローカルに立て、`localhost:8731/blank.html` で開く。`data:` URL はアドレスバーの解決で URL 扱いにならないため使えない
- [x] **ページ内検索**: `prefix + [` → 検索語 + Enter でヒットがハイライトされ、n / N で次・前へ移動、Escape で終了する
  - 自動化: manual（同上）
  - ⚠️ 入力欄にフォーカスが入らないことがある (下記「プロンプトの入力欄にフォーカスが入らない」)。その場合は status line の入力欄をクリックしてから入力する
- [x] **コマンドプロンプト**: `prefix + :` → `:open https://example.com` で遷移する
  - 自動化: manual（同上）
  - ⚠️ 同上のフォーカス問題が起きることがある

### ❌ プロンプトの入力欄にフォーカスが入らない (2026-09-01 に発見、issue: https://github.com/bannzai/tatami/issues/52 )

- 事象: `prefix + :` / `prefix + [` でプロンプトが開いても status line の入力欄がキーボードフォーカスを取らないことがある。この状態では入力した文字がどこにも入らず、Escape でプロンプトを閉じることもできない。さらにツールバーのボタン (← / → / ⟳) にフォーカスリングが残っているため、Enter や Space がそのボタンの再実行になり、意図しない履歴移動・再読み込みが起きる
- 再現手順: ツールバーの ← / → / ⟳ をクリックした後に `prefix + :` を押し、そのまま文字を打つ。入力欄が空のままなら再現している
- 回避: status line の入力欄を直接クリックしてから入力する。ウィンドウを `prefix + c` で作り直すとフォーカスは正常に戻る
- 同じ事象を `prefix + ,` (rename-window) でも確認した。プロンプトは開いて現在の名前が入っているが、打った文字が入らずツールバーの ← にフォーカスリングが残っている

  <img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/8e9cb62b-1607-4132-b7a9-74c9ee679449.png" width="320">
- 影響: 上の「ページ内検索」「コマンドプロンプト」の機能自体は入力欄にフォーカスがある状態では期待どおり動作する

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **リンククリック**: ページ内リンクのクリックで同じペインが遷移する (https://example.com の「Learn more」等)

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

example.com の「Learn more」をクリックすると同じペインが www.iana.org へ遷移する

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/9f94b97b-7b2a-4d32-8afb-d8bec8b78450.png" width="320">

</details>

### **戻る・進む・再読み込み**: ツールバーの ← / → / ⟳ ボタンで履歴を移動・再読み込みできる

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

← で iana.org から example.com へ戻る

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/f74fb1e2-7e2b-42e0-a260-4d82ccd0ee23.png" width="320">

→ で iana.org へ進む

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/24f64142-2c4c-4ae7-9640-9d21bedeedea.png" width="320">

⟳ の前後で httpbin.org/uuid の UUID が `f928a7e4-...` から `ce289324-...` へ変わる

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/0decbf06-bd4a-4ae7-9944-31bbf0e7521e.png" width="320">
<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/19d037fa-c69b-433e-b3f7-b4636d7dea64.png" width="320">

</details>

### **target=_blank**: `target=_blank` のリンクが新しいペインとして開き、別の macOS ウィンドウは増えない

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

クリック前 (ローカルの確認用ページ 1 ペイン)

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/c2d8c093-a1e5-4d36-878d-aa7e470327a9.png" width="320">

クリック後、example.org が右の新しいペインで開く。`System Events` が数える Tatami の macOS ウィンドウ数はクリック前後とも 1 のまま

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/af1c32c3-e380-4b05-b819-1d317c2129a2.png" width="320">

</details>

### **ページ内検索**: `prefix + [` → 検索語 + Enter でヒットがハイライトされ、n / N で次・前へ移動、Escape で終了する

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

「domain」で検索し、1 件目 (見出しの Domain) がハイライトされる

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/edbce1b5-b0f7-44f8-bfd2-f1532b6875cb.png" width="320">

n で 2 件目 (本文の domain) へ移動

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/5caefb4f-0828-4a65-bfae-a66a6d8eeeb4.png" width="320">

N で 1 件目へ戻る

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/a3486040-f0c6-4371-af18-7c0d16d871a5.png" width="320">

Escape でハイライトが消える

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/dacf57a4-835c-43b6-b977-e204171f0d2c.png" width="320">

</details>

### **コマンドプロンプト**: `prefix + :` → `:open https://example.com` で遷移する

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

Google 検索結果を表示していたペインが `:open https://example.com` で example.com へ遷移する

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/0ab577c6-6c9f-43b2-bca9-5510d6677acf.png" width="320">

</details>

</details>

---
