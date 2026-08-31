---
feature: persistence
verification: manual
last_verified_commit: null
last_verified_at: null
---

# persistence QA

## 関連リンク

- 仕様: https://github.com/bannzai/tatami/blob/main/documents/PROJECT.md (機能要件 1「Cookie・ローカルストレージは永続化する」・コア体験「セッションはローカルに保存し、次回起動で復元する」)
- 関連: https://github.com/bannzai/tatami/issues/47 (Cookie / セッション永続化は方向転換後も残す機能)

## 仕様チェックリスト

| ID | 期待挙動 | 対応項目 |
|----|---------|---------|
| S1 | Cookie が再起動後も残り、ログイン状態が維持される | Cookie の永続化 |
| S2 | ペインツリー・各ペインの URL・ウィンドウ名が再起動後に復元される | セッション復元 |
| S3 | `prefix + d` (detach) でウィンドウを隠してもセッションが残り、再起動で復元される | detach |
| S4 | 訪問したページが履歴に残り、アドレスバーの候補に出る | 履歴の候補表示 |
| S5 | ブックマークを登録でき、`prefix + b` の一覧から開ける | ブックマーク |

## 1. Cookie とログイン状態

- [ ] **Cookie の永続化**: ページで Cookie を保存 (例: https://httpbin.org/cookies/set?qa=1 ) → Tatami を終了・再起動 → 同サイトの https://httpbin.org/cookies で Cookie が残っている
  - 自動化: manual（macOS アプリのため osascript + screencapture で確認する。実サイトのログイン維持 (GitHub 等) は実アカウントを使うためユーザーの利用で代替し、QA では Cookie の残存で確認する）

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **Cookie の永続化**: ページで Cookie を保存 (例: https://httpbin.org/cookies/set?qa=1 ) → Tatami を終了・再起動 → 同サイトの https://httpbin.org/cookies で Cookie が残っている

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

</details>

---

## 2. セッションの保存と復元

- [ ] **セッション復元**: ペインを分割して別々の URL を開き、ウィンドウ名を変更 → 終了・再起動 → ペイン構成・各 URL・ウィンドウ名が復元される
  - 自動化: manual（osascript + screencapture）
- [ ] **detach**: `prefix + d` でウィンドウが閉じてもアプリは終了せず、再起動 (または File > New Window) で同じセッションが復元される
  - 自動化: todo

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **セッション復元**: ペインを分割して別々の URL を開き、ウィンドウ名を変更 → 終了・再起動 → ペイン構成・各 URL・ウィンドウ名が復元される

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **detach**: `prefix + d` でウィンドウが閉じてもアプリは終了せず、再起動 (または File > New Window) で同じセッションが復元される

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

</details>

---

## 3. 履歴とブックマーク

- [ ] **履歴の候補表示**: 一度開いた URL の一部をアドレスバーに入力すると候補に出て、↓ で選択して開ける
  - 自動化: manual（osascript + screencapture）
- [ ] **ブックマーク**: `prefix + :` → `:bookmark` で登録し、`prefix + b` の一覧から選んで開ける (もう一度 `:bookmark` で解除)
  - 自動化: manual（同上）

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **履歴の候補表示**: 一度開いた URL の一部をアドレスバーに入力すると候補に出て、↓ で選択して開ける

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **ブックマーク**: `prefix + :` → `:bookmark` で登録し、`prefix + b` の一覧から選んで開ける (もう一度 `:bookmark` で解除)

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

</details>

---
