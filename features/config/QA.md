---
feature: config
verification: manual
last_verified_commit: 57deef2d2255effb6e03c2eb84d4de8e066d4bdc
last_verified_at: 2026-09-01
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

- [x] **prefix の変更**: `set -g prefix C-t` を書いた状態で起動すると C-t が prefix になり、既定の C-b は効かない
  - 自動化: manual（macOS アプリのため osascript のキー送信 + screencapture の目視で確認する）
- [x] **エラー行の表示**: 解釈できない行 (例: `set -g theme dark`) を書いて起動すると status line に `tatami.conf:<行>: ...` が出て、他の行は適用されている
  - 自動化: manual（同上）
  - ユーザーの実 conf を書き換えないため、起動時ではなく一時ファイル (`set -g theme dark` + `set -g home https://example.org/` の 2 行) を `:source-file <絶対パス>` で読ませて確認した。エラー表示の経路は起動時と同じ (`TatamiConfigStore.reload`)

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **prefix の変更**: `set -g prefix C-t` を書いた状態で起動すると C-t が prefix になり、既定の C-b は効かない

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

既定の C-b + `"` はペイン分割にならない (何も起きない)

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/3cdf29de-4e26-4d33-b7f4-3bf4fc220979.png" width="320">

conf の C-t + `"` で上下に分割される

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/d8b9429a-8049-4c94-8a2e-9762564d002d.png" width="320">

</details>

### **エラー行の表示**: 解釈できない行 (例: `set -g theme dark`) を書いて起動すると status line に `tatami.conf:<行>: ...` が出て、他の行は適用されている

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

status line に `err.conf:2: 知らないオプション: theme` が赤字で出る

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/d6d62d15-c999-4efb-9659-9ad3c0015f97.png" width="320">

同じファイルの 3 行目 `set -g home https://example.org/` は適用されており、新しいペインが example.org で開く

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/fe49e7a0-1794-4cd7-ba0e-3be4af71f84a.png" width="320">

</details>

</details>

---

## 2. 再読込と反映

- [x] **bind / unbind**: `bind r reload` を追記して `:source-file` すると prefix + r で再読み込みが動き、`unbind r` の再読込で無効になる
  - 自動化: manual（osascript + screencapture）
  - 再読み込みが起きたかは https://httpbin.org/uuid を開いて UUID が変わるかで判定する
- [x] **source-file**: `prefix + :` → `:source-file` が既定の tatami.conf を読み直し、変更が即座に反映される
  - 自動化: manual（同上）
- [x] **home と search-engine**: `set -g home` を設定して再読込すると以後の新しいペインがそのページで開き、`set -g search-engine` が検索語の遷移先に使われる
  - 自動化: manual（同上。確認後は設定を元に戻す）
  - 検索語の遷移先は `set -g search-engine https://httpbin.org/get` にして、httpbin のエコー (`"args": {"q": ...}`) で確認する。実在の検索エンジンへ問い合わせずに済む

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **bind / unbind**: `bind r reload` を追記して `:source-file` すると prefix + r で再読み込みが動き、`unbind r` の再読込で無効になる

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

`bind r reload` を読ませた後の prefix + r で UUID が `83c7822e-...` から `80edf9f8-...` へ変わる (再読み込みされた)

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/38f28365-fead-4e9d-b8e9-038157ee6da5.png" width="320">

`unbind r` を読ませた後の prefix + r では UUID が `80edf9f8-...` のまま変わらない (無効になった)

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/bacc18ca-6939-420c-9f42-f08b9ce8e424.png" width="320">

</details>

### **source-file**: `prefix + :` → `:source-file` が既定の tatami.conf を読み直し、変更が即座に反映される

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

一時 conf で `home` を example.org にした状態から引数なしの `:source-file` を実行すると、以後の新しいペインが既定の空ページに戻る

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/c32fec67-3a55-45b5-af97-03af0793ed67.png" width="320">

</details>

### **home と search-engine**: `set -g home` を設定して再読込すると以後の新しいペインがそのページで開き、`set -g search-engine` が検索語の遷移先に使われる

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

`set -g home https://example.org/` の再読込後、新しいペインが example.org で開く

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/fe49e7a0-1794-4cd7-ba0e-3be4af71f84a.png" width="320">

`set -g search-engine https://httpbin.org/get` の再読込後、検索語「tatami split pane」が `https://httpbin.org/get?q=tatami%20split%20pane` へ遷移する

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/05c3d919-91b6-40d9-94c2-d16e46c38ca3.png" width="320">

</details>

</details>

---
