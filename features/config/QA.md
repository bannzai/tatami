---
feature: config
verification: manual
last_verified_commit: null
last_verified_at: null
---

# config QA

## 関連リンク

- 仕様: https://github.com/bannzai/tatami/blob/main/documents/PROJECT.md (機能要件 2「設定ファイル」)
- 関連: https://github.com/bannzai/tatami/pull/48 (tatami.conf の実運用開始)

## 仕様チェックリスト

| ID | 期待挙動 | 対応項目 |
|----|---------|---------|
| S1 | 起動時に `~/.config/tatami/tatami.conf` が読まれ、`set -g prefix` が反映される | prefix の変更 |
| S2 | `bind` / `unbind` でキー割り当てを変更できる | bind / unbind |
| S3 | `:source-file` で設定を再読込できる | source-file |
| S4 | 解釈できない行はファイル名 + 行番号付きで status line にエラー表示され、残りの行は適用される | エラー行の表示 |
| S5 | `set -g home` / `set -g search-engine` が新しいペイン・検索に反映される | home と search-engine |

## 1. 起動時の反映

- [ ] **prefix の変更**: `set -g prefix C-t` を書いた状態で起動すると C-t が prefix になり、既定の C-b は効かない
  - 自動化: manual（macOS アプリのため osascript のキー送信 + screencapture の目視で確認する）
- [ ] **エラー行の表示**: 解釈できない行 (例: `set -g theme dark`) を書いて起動すると status line に `tatami.conf:<行>: ...` が出て、他の行は適用されている
  - 自動化: manual（同上）

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **prefix の変更**: `set -g prefix C-t` を書いた状態で起動すると C-t が prefix になり、既定の C-b は効かない

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **エラー行の表示**: 解釈できない行 (例: `set -g theme dark`) を書いて起動すると status line に `tatami.conf:<行>: ...` が出て、他の行は適用されている

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

</details>

---

## 2. 再読込と反映

- [ ] **bind / unbind**: `bind r reload` を追記して `:source-file` すると prefix + r で再読み込みが動き、`unbind r` の再読込で無効になる
  - 自動化: manual（osascript + screencapture）
- [ ] **source-file**: `prefix + :` → `:source-file` が既定の tatami.conf を読み直し、変更が即座に反映される
  - 自動化: manual（同上）
- [ ] **home と search-engine**: `set -g home` を設定して再読込すると以後の新しいペインがそのページで開き、`set -g search-engine` が検索語の遷移先に使われる
  - 自動化: manual（同上。確認後は設定を元に戻す）

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **bind / unbind**: `bind r reload` を追記して `:source-file` すると prefix + r で再読み込みが動き、`unbind r` の再読込で無効になる

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **source-file**: `prefix + :` → `:source-file` が既定の tatami.conf を読み直し、変更が即座に反映される

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **home と search-engine**: `set -g home` を設定して再読込すると以後の新しいペインがそのページで開き、`set -g search-engine` が検索語の遷移先に使われる

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

</details>

---
