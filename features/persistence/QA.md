---
feature: persistence
verification: manual
last_verified_commit: 57deef2d2255effb6e03c2eb84d4de8e066d4bdc
last_verified_at: 2026-09-01
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

- [x] **Cookie の永続化**: ページで Cookie を保存 (有効期限付き。https://httpbin.org/response-headers?Set-Cookie=qa%3Dpersist1%3B%20Max-Age%3D604800%3B%20Path%3D%2F ) → Tatami を終了・再起動 → 同サイトの https://httpbin.org/cookies で Cookie が残っている
  - 自動化: manual（macOS アプリのため osascript + screencapture で確認する。実サイトのログイン維持 (GitHub 等) は実アカウントを使うためユーザーの利用で代替し、QA では Cookie の残存で確認する）
  - `https://httpbin.org/cookies/set?qa=1` が発行するのは有効期限のない **セッション Cookie** で、再起動後に消えるのがブラウザとして正しい挙動（実測でも消えた）。永続化の確認には上記の `response-headers` で `Max-Age` 付きの Cookie を発行する

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **Cookie の永続化**: ページで Cookie を保存 (有効期限付き。https://httpbin.org/response-headers?Set-Cookie=qa%3Dpersist1%3B%20Max-Age%3D604800%3B%20Path%3D%2F ) → Tatami を終了・再起動 → 同サイトの https://httpbin.org/cookies で Cookie が残っている

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

再起動前 (`qa=persist1` が入っている):

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/5b45cf3d-3283-4c62-a440-bc785e0633cf.png" width="320">

`pkill -x Tatami` → 再起動後 (`qa=persist1` が残っている):

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/f96badc8-256f-483f-bcf5-d38911284b37.png" width="320">

</details>

</details>

---

## 2. セッションの保存と復元

- [x] **セッション復元**: ペインを分割して別々の URL を開き、ウィンドウ名を変更 → 終了・再起動 → ペイン構成・各 URL・ウィンドウ名が復元される
  - 自動化: manual（osascript + screencapture）
- [x] **detach**: `prefix + d` でウィンドウが閉じてもアプリは終了せず、再起動 (または Dock / `open` での再オープン) で同じセッションが復元される
  - 自動化: manual（osascript + screencapture）
  - 復元の確認に File > New Window (Cmd+N) は使わない (アプリ全体がハングする https://github.com/bannzai/tatami/issues/51 )。detach 後に `open <Tatami.app のパス>` を実行すると、プロセスを終了させずに同じセッションのウィンドウが戻る

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **セッション復元**: ペインを分割して別々の URL を開き、ウィンドウ名を変更 → 終了・再起動 → ペイン構成・各 URL・ウィンドウ名が復元される

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

再起動前 (ウィンドウ名 `qa-b2`、3 ペイン: httpbin.org/cookies・httpbin.org/html・example.com):

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/0fc16338-0298-4b90-a855-2d0279eb312f.png" width="320">

再起動後 (ウィンドウ名・ペイン構成・各 URL が復元されている):

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/cc04d588-1087-4eec-95cb-3a90671b9e41.png" width="320">

</details>

### **detach**: `prefix + d` でウィンドウが閉じてもアプリは終了せず、再起動 (または Dock / `open` での再オープン) で同じセッションが復元される

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

`prefix + d` の直後にウィンドウ数が 0 になる一方でプロセスは生存していた (`osascript ... count of windows` → `0`、`pgrep -x Tatami` → `3971`)。その後 `open` で再オープンした結果が下図で、PID は `3971` のまま (再起動していない) セッションがそのまま戻っている:

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/fdd6d4df-f524-4590-b306-d3f85d2fa7cf.png" width="320">

</details>

</details>

---

## 3. 履歴とブックマーク

- [x] **履歴の候補表示**: 一度開いた URL の一部をアドレスバーに入力すると候補に出て、↓ で選択して開ける
  - 自動化: manual（osascript + screencapture）
- [x] **ブックマーク**: `prefix + :` → `:bookmark` で登録し、`prefix + b` の一覧から選んで開ける (もう一度 `:bookmark` で解除)
  - 自動化: manual（同上）

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **履歴の候補表示**: 一度開いた URL の一部をアドレスバーに入力すると候補に出て、↓ で選択して開ける

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

`prefix + /` で `httpbin` と入力すると履歴の候補が並び、↓ 3 回で `https://httpbin.org/html` が選択される:

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/691f879c-25f6-4bb9-895d-1de9d804e557.png" width="320">

Enter でそのペインが選択した URL を開く:

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/b04759d5-bf8e-4c67-b57c-8c7c499a7c54.png" width="320">

</details>

### **ブックマーク**: `prefix + :` → `:bookmark` で登録し、`prefix + b` の一覧から選んで開ける (もう一度 `:bookmark` で解除)

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

`:bookmark` で登録 (status line に「ブックマークした」):

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/8c0a06a3-77cc-4072-afc9-11304fe6de72.png" width="320">

別の URL へ移動してから `prefix + b` で一覧が出る:

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/55c706fd-b30a-4e70-8301-6bea4b07fa33.png" width="320">

Enter で登録した URL が開く:

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/14eb9222-0492-4a48-be56-03acc8564edd.png" width="320">

もう一度 `:bookmark` で解除 (status line に「ブックマークを解除した」):

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/5db15a5f-02af-4c27-8b3c-7b56c1a65334.png" width="320">

</details>

</details>

---
