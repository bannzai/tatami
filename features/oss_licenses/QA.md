---
feature: oss_licenses
verification: manual
last_verified_commit: null
last_verified_at: null
---

# OSS ライセンス QA

## 関連リンク

- 仕様なし QA: OSS ライセンス一覧追加の依頼と `Tatami/TatamiApp.swift` の実装に基づく
- 表示ライブラリ: https://github.com/cybozu/LicenseList

## 1. ライセンスの閲覧

- [ ] **メニューから一覧を開く**: Tatami メニューの「OSS ライセンス」で専用ウィンドウが開き、LicenseList が表示される
  - 自動化: manual（macos-simtunnel のアクセシビリティ操作とスクリーンショットで確認）
  - ⏭️ スキップ: ユーザーの指示により画面確認を省略したため未検証
- [ ] **本文と出典を読む**: LicenseList を選択するとライセンス本文とリポジトリへのリンクが表示され、一覧に戻れる
  - 自動化: manual（同上）
  - ⏭️ スキップ: ユーザーの指示により画面確認を省略したため未検証
- [ ] **ウィンドウを再利用する**: メニューの再選択でウィンドウが増殖せず、閉じた後もメニューから再表示できる
  - 自動化: manual（同上）
  - ⏭️ スキップ: ユーザーの指示により画面確認を省略したため未検証

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **メニューから一覧を開く**: Tatami メニューの「OSS ライセンス」で専用ウィンドウが開き、LicenseList が表示される

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **本文と出典を読む**: LicenseList を選択するとライセンス本文とリポジトリへのリンクが表示され、一覧に戻れる

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **ウィンドウを再利用する**: メニューの再選択でウィンドウが増殖せず、閉じた後もメニューから再表示できる

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

</details>

## セッション再開

```sh
cd /Users/bannzai/worktrees/bannzai/tatami/add-oss-license-page
codex resume 01a084dd-b838-74d2-92d5-c608b99abcd3
```
