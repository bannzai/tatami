---
feature: navigation
verification: manual
last_verified_commit: null
last_verified_at: null
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

- [ ] **URL 遷移**: `prefix + /` → `https://example.com` + Enter でフォーカス中のペインが遷移し、アドレスバーとウィンドウ名が追従する
  - 自動化: manual（macOS アプリのため osascript のキー送信 + screencapture の目視で確認する）
- [ ] **入力の解決**: `example.com` (スキーム無し) は https で開き、`tmux split pane` (空白入り) は検索エンジンの結果ページで開く
  - 自動化: manual（同上）
- [ ] **空ページの表示**: フォーカス中のペインが about:blank の時、アドレスバーは「about:blank」ではなく空欄 + プレースホルダー表示になる
  - 自動化: manual（同上。検証済み実例: https://github.com/bannzai/tatami/pull/48#issuecomment-5481009154 ）

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **URL 遷移**: `prefix + /` → `https://example.com` + Enter でフォーカス中のペインが遷移し、アドレスバーとウィンドウ名が追従する

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **入力の解決**: `example.com` (スキーム無し) は https で開き、`tmux split pane` (空白入り) は検索エンジンの結果ページで開く

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **空ページの表示**: フォーカス中のペインが about:blank の時、アドレスバーは「about:blank」ではなく空欄 + プレースホルダー表示になる

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

</details>

---

## 2. ページ内の移動

- [ ] **リンククリック**: ページ内リンクのクリックで同じペインが遷移する (https://example.com の「Learn more」等)
  - 自動化: manual（osascript のマウスクリック + screencapture）
- [ ] **戻る・進む・再読み込み**: ツールバーの ← / → / ⟳ ボタンで履歴を移動・再読み込みできる
  - 自動化: manual（同上）
- [ ] **target=_blank**: `target=_blank` のリンクが新しいペインとして開き、別の macOS ウィンドウは増えない
  - 自動化: manual（同上。`data:text/html,<a target=_blank href=https://example.org>x</a>` か実サイトのリンクで確認）
- [ ] **ページ内検索**: `prefix + [` → 検索語 + Enter でヒットがハイライトされ、n / N で次・前へ移動、Escape で終了する
  - 自動化: manual（同上）
- [ ] **コマンドプロンプト**: `prefix + :` → `:open https://example.com` で遷移する
  - 自動化: manual（同上）

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **リンククリック**: ページ内リンクのクリックで同じペインが遷移する (https://example.com の「Learn more」等)

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **戻る・進む・再読み込み**: ツールバーの ← / → / ⟳ ボタンで履歴を移動・再読み込みできる

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **target=_blank**: `target=_blank` のリンクが新しいペインとして開き、別の macOS ウィンドウは増えない

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **ページ内検索**: `prefix + [` → 検索語 + Enter でヒットがハイライトされ、n / N で次・前へ移動、Escape で終了する

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **コマンドプロンプト**: `prefix + :` → `:open https://example.com` で遷移する

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

</details>

---
