---
feature: panes_windows
verification: manual
last_verified_commit: 54b761324d624f9d828d64c66d169464a900b4a6
last_verified_at: 2026-09-02
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
| S4 | `prefix + o` / `;` / `h j k l` / 矢印でペインのフォーカスを移動できる | フォーカス移動 / 直前ペイン・矢印キーのフォーカス移動 |
| S5 | `prefix + x` でペインを閉じ、兄弟ペインが領域を引き継ぐ | ペインを閉じる |
| S6 | `prefix + z` でペインの zoom (全面表示) をトグルする | zoom |
| S7 | `prefix + {` / `}` でペインを入れ替える | ペインの入れ替え / `prefix + }` の入れ替え |
| S8 | `prefix + Space` でレイアウトを切り替える | レイアウト切り替え |
| S9 | `prefix + c` で新しいウィンドウ (タブ相当) を空ページ + アドレスバーフォーカスで開く | 新しいウィンドウ |
| S10 | `prefix + n` / `p` / `0-9` でウィンドウを移動・選択できる | ウィンドウの移動・選択 / 0 以外の番号キーでのウィンドウ選択 |
| S11 | `prefix + ,` / `&` / `w` でウィンドウの名前変更・閉じる・一覧ができる | ウィンドウの名前変更・閉じる・一覧 |
| S12 | File > New Window で別の macOS ウィンドウ (新しいセッション) が開く | macOS ウィンドウの追加 |
| S13 | ペインの境界 (divider) をドラッグしてリサイズできる | ペインのドラッグリサイズ |
| S14 | `prefix + s` でセッションの一覧・選択、`prefix + $` でセッション名の変更ができる | セッションの一覧・選択と名前変更 |

## 1. ペイン分割

- [x] **上下分割**: `prefix + "` で現在のペインが上下に分割され、新しいペイン (下) が空ページでフォーカスされる
  - 自動化: manual（macOS アプリのため osascript のキー送信 + screencapture の目視で確認する）
- [x] **左右分割**: `prefix + %` で現在のペインが左右に分割され、新しいペイン (右) が空ページでフォーカスされる
  - 自動化: manual（同上）
- [x] **分割直後の入力**: 分割直後に prefix + / を押さずに `example.org` + Enter をタイプすると、アドレスバーに入力が入り新しいペインで開く
  - 自動化: manual（同上。検証済み実例: https://github.com/bannzai/tatami/pull/48#issuecomment-5481009154 ）

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **上下分割**: `prefix + "` で現在のペインが上下に分割され、新しいペイン (下) が空ページでフォーカスされる

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

分割前 (1 ペイン)

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/1efde99d-ba80-4204-89f0-e9d551ae8f57.png" width="320">

`prefix + "` の後。下に空ページのペインができ、青枠とアドレスバーのフォーカスがそちらへ移る

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/a83c150f-c126-4952-9f5f-bc172017993b.png" width="320">

</details>

### **左右分割**: `prefix + %` で現在のペインが左右に分割され、新しいペイン (右) が空ページでフォーカスされる

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

下のペインを `prefix + %` で左右に分割し、右の空ページがフォーカスされる

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/2018044e-4201-4cd5-a1a0-69ae7477a5f2.png" width="320">

</details>

### **分割直後の入力**: 分割直後に prefix + / を押さずに `example.org` + Enter をタイプすると、アドレスバーに入力が入り新しいペインで開く

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

分割直後にそのまま `example.org` と打って Enter すると、新しいペインが example.org を開く

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/5573dc7a-aae0-4bdf-a40a-53dd7575b173.png" width="320">

</details>

</details>

---

## 2. ペインのフォーカスと配置

- [x] **フォーカス移動**: `prefix + o` で次のペインへ、`prefix + h/j/k/l` で方向指定でフォーカスが移る (青枠の追従で確認)
  - 自動化: manual（osascript + screencapture）
  - どのペインがどれか分かるよう、`python3 -m http.server` で「PANE A」「PANE B」「PANE C」と大きく表示するだけのページを配って各ペインに割り当てると判定しやすい
- [ ] **直前ペイン・矢印キーのフォーカス移動**: `prefix + ;` で直前のペインへ、`prefix + 矢印` で方向指定でフォーカスが移る
  - 自動化: todo
  - 未検証: 検証済みは `o` と `h/j/k/l` のみで、`;` と各矢印キーのバインドは未確認
- [x] **ペインの入れ替え**: `prefix + {` でフォーカス中のペインが隣と入れ替わる (swapPaneUp)
  - 自動化: manual（同上）
- [ ] **`prefix + }` の入れ替え**: `prefix + }` で逆方向へ入れ替わり (swapPaneDown)、フォーカスも追従する
  - 自動化: todo
  - 未検証: 検証済みは `{` (swapPaneUp) のみで、別コマンドの `}` (swapPaneDown) は未確認
- [ ] **ペインのドラッグリサイズ**: ペインの境界 (divider) を水平・垂直にドラッグすると比率が変わり (PaneTree.resize)、再起動後も配置が復元される
  - 自動化: todo
  - 未検証: divider のドラッグ操作は未確認
- [x] **zoom**: `prefix + z` でフォーカス中のペインが全面表示になり、もう一度で元に戻る
  - 自動化: manual（同上）
- [x] **レイアウト切り替え**: `prefix + Space` で even-horizontal / even-vertical / tiled が順に切り替わる
  - 自動化: manual（同上）
- [x] **ペインを閉じる**: `prefix + x` でフォーカス中のペインが閉じ、残りのペインが領域を引き継ぐ
  - 自動化: manual（同上）

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **フォーカス移動**: `prefix + o` で次のペインへ、`prefix + h/j/k/l` で方向指定でフォーカスが移る (青枠の追従で確認)

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

`prefix + k` で上の PANE A にフォーカスがある状態

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/9d0aaee9-7790-4dcb-8c7e-0d28ca460da4.png" width="320">

`prefix + o` で次のペイン PANE B へ青枠が移る

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/023a4def-65a2-4178-b730-6cd124de620e.png" width="320">

`prefix + l` で右の PANE C へ移る

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/6dd463a1-8cfd-4ff0-a518-a5a93aaaf716.png" width="320">

</details>

### **ペインの入れ替え**: `prefix + {` / `}` でフォーカス中のペインが隣と入れ替わる

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

PANE C にフォーカスした状態で `prefix + {` を押すと、下段の左右 (PANE B と PANE C) が入れ替わり、フォーカスは PANE C に付いて移動する

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/c4406406-ea1d-4992-b7c9-41fa4d1675a1.png" width="320">

</details>

### **zoom**: `prefix + z` でフォーカス中のペインが全面表示になり、もう一度で元に戻る

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

`prefix + z` で PANE C が全面表示になる

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/97f4f081-3461-4fbb-bb32-2268e6520a2d.png" width="320">

もう一度の `prefix + z` で 3 ペインの配置に戻る

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/9d1b8619-6208-418d-83a0-e403822991a4.png" width="320">

</details>

### **レイアウト切り替え**: `prefix + Space` で even-horizontal / even-vertical / tiled が順に切り替わる

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

1 回目: 横並び (even-horizontal)

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/fb6ad027-ff18-4140-9e24-f7b55332a3ad.png" width="320">

2 回目: 縦並び (even-vertical)

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/2bd93c3e-22f8-4668-ba71-2a7bb8f5096a.png" width="320">

3 回目: tiled

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/80dfcda7-63be-40df-a583-537bf6b570aa.png" width="320">

</details>

### **ペインを閉じる**: `prefix + x` でフォーカス中のペインが閉じ、残りのペインが領域を引き継ぐ

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

PANE C を `prefix + x` で閉じると、残った PANE A と PANE B が領域を分け合う

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/2e9c01d2-67f6-4720-ab84-30afda0ceade.png" width="320">

</details>

</details>

---

## 3. ウィンドウ操作

- [x] **新しいウィンドウ**: `prefix + c` で新しいウィンドウが空ページ + アドレスバーフォーカスで開き、status line の一覧に追加される
  - 自動化: manual（osascript + screencapture）
- [x] **ウィンドウの移動・選択**: `prefix + n` / `p` で隣へ、`prefix + <番号>` で直接選択でき、status line の `*` が追従する
  - 自動化: manual（同上）
  - 番号キーの直接選択で検証済みなのは `prefix + 0` のみ
- [ ] **0 以外の番号キーでのウィンドウ選択**: `prefix + 1`〜`9` でも対応するウィンドウを直接選択できる
  - 自動化: todo
  - 未検証: 各数字は `KeyBindingTable.default` で別々の `selectWindow(index)` バインドとして登録されるため、`0` の合格だけでは 1〜9 の回帰を検出できない
- [ ] **セッションの一覧・選択と名前変更**: `prefix + s` でセッション一覧から選択でき、`prefix + $` でセッション名を変更できる (chooseSession / renameSession)
  - 自動化: todo
  - 未検証: セッション操作はこれまでの QA で未実施
- [x] **ウィンドウの名前変更・閉じる・一覧**: `prefix + ,` で名前変更、`prefix + w` で一覧から選択、`prefix + &` で閉じられる
  - 自動化: manual（同上）
  - ⚠️ `prefix + ,` の rename-window プロンプトも、navigation feature に記録した「プロンプトの入力欄にフォーカスが入らない」事象が起きる。status line の入力欄をクリック → Cmd+A → 入力で回避した (features/navigation/QA.md 参照。issue: https://github.com/bannzai/tatami/issues/52 、修正 PR: https://github.com/bannzai/tatami/pull/54 )
- [ ] **macOS ウィンドウの追加**: File > New Window (Cmd+N) で別の macOS ウィンドウが新しいセッションで開く
  - 自動化: manual（同上）
  - ❌ 失敗: 保存済みセッションが大きいとアプリ全体がハングする。再現手順: ウィンドウ 8 個のセッションを復元した状態で Cmd+N。issue: https://github.com/bannzai/tatami/issues/51
  - ❌ 修正 https://github.com/bannzai/tatami/pull/55 のマージ後 (2026-09-02、ウィンドウ 10 個のセッション) も再現。新しい macOS ウィンドウは開かず、`tell application "Tatami" to activate` が -1712 でタイムアウトし、その後は prefix + キーにも反応しなくなる。`pkill -9 -x Tatami` → 再起動で復旧。9-01 と違い `sample` の main thread は `_DPSNextEvent` で待機しており、main thread のブロックとは別の要因の可能性がある (スタック: `tmp/qa/hang-b3-01.txt`)。issue #51 の再オープン要否は呼び出し元が判断する

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **新しいウィンドウ**: `prefix + c` で新しいウィンドウが空ページ + アドレスバーフォーカスで開き、status line の一覧に追加される

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

`prefix + c` で `9:blank*` が status line に加わり、空ページ + アドレスバーフォーカスで開く

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/68ac7144-2ffc-4b28-9e2a-82ec8c78a13c.png" width="320">

</details>

### **ウィンドウの移動・選択**: `prefix + n` / `p` で隣へ、`prefix + <番号>` で直接選択でき、status line の `*` が追従する

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

`prefix + p` でウィンドウ 9 から 8 へ (`8:localhost*`)

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/0cf3f58d-80f2-44ed-87ed-d9a3d12bebf9.png" width="320">

`prefix + n` で 9 へ戻る (`9:localhost*`)

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/9b2c0821-d5cc-4c39-8335-401abc8aafce.png" width="320">

`prefix + 0` で番号指定の直接選択 (`0:example.org*`)

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/624dc685-0b41-4205-9f93-516e34701ad2.png" width="320">

</details>

### **ウィンドウの名前変更・閉じる・一覧**: `prefix + ,` で名前変更、`prefix + w` で一覧から選択、`prefix + &` で閉じられる

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-01**

`prefix + ,` で `qa-renamed` に変更し、status line が `9:qa-renamed*` になる

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/2cc50071-2d28-4aee-a2c4-ce74b75b152d.png" width="320">

`prefix + w` の一覧。現在のウィンドウ `(9) qa-renamed` が選択状態で表示される

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/03e3ec90-854e-4305-97cf-0af7612e9369.png" width="320">

一覧で 8 を押すとウィンドウ 8 へ切り替わる

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/c6ca1fe2-1ab4-419c-b532-97a6bd909bc4.png" width="320">

`prefix + &` で `9:qa-renamed` が一覧から消える

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260901/528742ad-ac50-4adf-abff-007d12936c85.png" width="320">

</details>

### **macOS ウィンドウの追加**: File > New Window (Cmd+N) で別の macOS ウィンドウが新しいセッションで開く

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-02**（修正 #55 マージ後の再検証。失敗）

Cmd+N を送って 5 秒後の状態。新しい macOS ウィンドウは開かず、直前の画面のまま固まっている (この後 prefix + `%` を送っても分割されなかった):

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260902/f660e705-6407-4ddf-9eaf-70617956f21e.png" width="320">

</details>

</details>

---
