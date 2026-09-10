---
feature: oss_licenses
verification: manual
last_verified_commit: 7292310db19aa96ca431295a46cc1ca0f7a12cfe
last_verified_at: 2026-09-09
---

# OSS ライセンス QA

## 関連リンク

- 仕様なし QA: OSS ライセンス一覧追加の依頼と `Tatami/TatamiApp.swift` の実装に基づく
- 表示ライブラリ: https://github.com/cybozu/LicenseList

## 1. ライセンスの閲覧

- [x] **メニューから一覧を開く**: Tatami メニューの「OSS ライセンス」で専用ウィンドウが開き、LicenseList が表示される
  - 自動化: manual（macos-simtunnel のアクセシビリティ操作とスクリーンショットで確認）
  - 確認: 2026-09-09、コミット 7292310 のビルド済み Debug アプリでメニューから開き、ウィンドウ ID 指定の撮影で確認。リモート runner は PrepareLicenseList プラグイン検証で失敗したためローカルを使用
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

**確認日: 2026-09-09**
<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/2026/09/09/f5434cec-1b73-47fb-a344-5e54c128bc70-oss-license-window.png" width="320">

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
