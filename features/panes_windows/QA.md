---
feature: panes_windows
verification: manual
last_verified_commit: null
last_verified_at: null
---

# panes_windows QA

## 関連リンク

- 仕様: https://github.com/bannzai/tatami/blob/main/documents/PROJECT.md (コア体験の表・機能要件 1)
- 関連: https://github.com/bannzai/tatami/issues/47 (方向転換) / https://github.com/bannzai/tatami/issues/51 (File > New Window のハング)

## 仕様チェックリスト

| ID | 期待挙動 | 対応項目 |
|----|---------|---------|
| S1 | `prefix + "` で現在のペインを上下に分割し、新しいペインは空のページで開く | 上下分割 |
| S2 | `prefix + %` で現在のペインを左右に分割する | 左右分割 |
| S3 | 分割直後の空ページではアドレスバーへ自動フォーカスされ、そのまま URL を入力できる | 分割直後の入力 |
| S4 | `prefix + o` / `;` / `h j k l` / 矢印でペインのフォーカスを移動できる | フォーカス移動 |
| S5 | `prefix + x` でペインを閉じ、兄弟ペインが領域を引き継ぐ | ペインを閉じる |
| S6 | `prefix + z` でペインの zoom (全面表示) をトグルする | zoom |
| S7 | `prefix + {` / `}` でペインを入れ替える | ペインの入れ替え |
| S8 | `prefix + Space` でレイアウトを切り替える | レイアウト切り替え |
| S9 | `prefix + c` で新しいウィンドウ (タブ相当) を空ページ + アドレスバーフォーカスで開く | 新しいウィンドウ |
| S10 | `prefix + n` / `p` / `0-9` でウィンドウを移動・選択できる | ウィンドウの移動・選択 |
| S11 | `prefix + ,` / `&` / `w` でウィンドウの名前変更・閉じる・一覧ができる | ウィンドウの名前変更・閉じる・一覧 |
| S12 | File > New Window で別の macOS ウィンドウ (新しいセッション) が開く | macOS ウィンドウの追加 |

## 1. ペイン分割

- [ ] **上下分割**: `prefix + "` で現在のペインが上下に分割され、新しいペイン (下) が空ページでフォーカスされる
  - 自動化: manual（macOS アプリのため osascript のキー送信 + screencapture の目視で確認する）
- [ ] **左右分割**: `prefix + %` で現在のペインが左右に分割され、新しいペイン (右) が空ページでフォーカスされる
  - 自動化: manual（同上）
- [ ] **分割直後の入力**: 分割直後に prefix + / を押さずに `example.org` + Enter をタイプすると、アドレスバーに入力が入り新しいペインで開く
  - 自動化: manual（同上。検証済み実例: https://github.com/bannzai/tatami/pull/48#issuecomment-5481009154 ）

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **上下分割**: `prefix + "` で現在のペインが上下に分割され、新しいペイン (下) が空ページでフォーカスされる

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **左右分割**: `prefix + %` で現在のペインが左右に分割され、新しいペイン (右) が空ページでフォーカスされる

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **分割直後の入力**: 分割直後に prefix + / を押さずに `example.org` + Enter をタイプすると、アドレスバーに入力が入り新しいペインで開く

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

</details>

---

## 2. ペインのフォーカスと配置

- [ ] **フォーカス移動**: `prefix + o` で次のペインへ、`prefix + h/j/k/l` で方向指定でフォーカスが移る (青枠の追従で確認)
  - 自動化: manual（osascript + screencapture）
- [ ] **ペインの入れ替え**: `prefix + {` / `}` でフォーカス中のペインが隣と入れ替わる
  - 自動化: manual（同上）
- [ ] **zoom**: `prefix + z` でフォーカス中のペインが全面表示になり、もう一度で元に戻る
  - 自動化: manual（同上）
- [ ] **レイアウト切り替え**: `prefix + Space` で even-horizontal / even-vertical / tiled が順に切り替わる
  - 自動化: manual（同上）
- [ ] **ペインを閉じる**: `prefix + x` でフォーカス中のペインが閉じ、残りのペインが領域を引き継ぐ
  - 自動化: manual（同上）

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **フォーカス移動**: `prefix + o` で次のペインへ、`prefix + h/j/k/l` で方向指定でフォーカスが移る (青枠の追従で確認)

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **ペインの入れ替え**: `prefix + {` / `}` でフォーカス中のペインが隣と入れ替わる

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **zoom**: `prefix + z` でフォーカス中のペインが全面表示になり、もう一度で元に戻る

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **レイアウト切り替え**: `prefix + Space` で even-horizontal / even-vertical / tiled が順に切り替わる

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **ペインを閉じる**: `prefix + x` でフォーカス中のペインが閉じ、残りのペインが領域を引き継ぐ

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

</details>

---

## 3. ウィンドウ操作

- [ ] **新しいウィンドウ**: `prefix + c` で新しいウィンドウが空ページ + アドレスバーフォーカスで開き、status line の一覧に追加される
  - 自動化: manual（osascript + screencapture）
- [ ] **ウィンドウの移動・選択**: `prefix + n` / `p` で隣へ、`prefix + <番号>` で直接選択でき、status line の `*` が追従する
  - 自動化: manual（同上）
- [ ] **ウィンドウの名前変更・閉じる・一覧**: `prefix + ,` で名前変更、`prefix + w` で一覧から選択、`prefix + &` で閉じられる
  - 自動化: manual（同上）
- [ ] **macOS ウィンドウの追加**: File > New Window (Cmd+N) で別の macOS ウィンドウが新しいセッションで開く
  - 自動化: manual（同上）
  - ❌ 失敗: 保存済みセッションが大きいとアプリ全体がハングする。再現手順: ウィンドウ 8 個のセッションを復元した状態で Cmd+N。issue: https://github.com/bannzai/tatami/issues/51

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **新しいウィンドウ**: `prefix + c` で新しいウィンドウが空ページ + アドレスバーフォーカスで開き、status line の一覧に追加される

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **ウィンドウの移動・選択**: `prefix + n` / `p` で隣へ、`prefix + <番号>` で直接選択でき、status line の `*` が追従する

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **ウィンドウの名前変更・閉じる・一覧**: `prefix + ,` で名前変更、`prefix + w` で一覧から選択、`prefix + &` で閉じられる

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **macOS ウィンドウの追加**: File > New Window (Cmd+N) で別の macOS ウィンドウが新しいセッションで開く

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

</details>

---
