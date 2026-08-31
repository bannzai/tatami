---
feature: platform
verification: manual
last_verified_commit: null
last_verified_at: null
---

# platform QA

## 関連リンク

- 仕様: https://github.com/bannzai/tatami/blob/main/documents/PROJECT.md (機能要件 1「ダウンロード」・機能要件 4「ブラウザとしての生活品質」)
- 関連: https://github.com/bannzai/tatami/issues/47 (方向転換後も残す基本機能)

## 仕様チェックリスト

| ID | 期待挙動 | 対応項目 |
|----|---------|---------|
| S1 | ダウンロードは保存先を選んで保存され、進捗・完了が status line に出る | ダウンロード |
| S2 | 証明書エラーのサイトはエラーが表示され、黙って読み込まれない | 証明書エラー |
| S3 | 他アプリから渡された URL (`open -a Tatami <url>`) が新しいペインで開く | 他アプリからの URL |
| S4 | メディア・位置情報などの権限要求でダイアログが出る | 権限ダイアログ |

## 1. ダウンロードとエラー表示

- [ ] **ダウンロード**: ファイルのダウンロードで保存先の選択ダイアログが出て、選んだ場所に保存され、status line に進捗・完了が出る
  - 自動化: manual（保存ダイアログの操作が必要なため osascript + screencapture で確認する）
- [ ] **証明書エラー**: https://expired.badssl.com/ を開くと証明書エラーが表示され、ページは黙って読み込まれない
  - 自動化: manual（osascript + screencapture）

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **ダウンロード**: ファイルのダウンロードで保存先の選択ダイアログが出て、選んだ場所に保存され、status line に進捗・完了が出る

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **証明書エラー**: https://expired.badssl.com/ を開くと証明書エラーが表示され、ページは黙って読み込まれない

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

</details>

---

## 2. OS 連携

- [ ] **他アプリからの URL**: Tatami 起動中に `open -a Tatami https://example.com` を実行すると、現在のウィンドウの新しいペインで開く
  - 自動化: manual（osascript + screencapture）
- [ ] **権限ダイアログ**: カメラ・マイク・位置情報を要求するページで権限ダイアログが出て、許可 / 拒否が反映される
  - 自動化: todo

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **他アプリからの URL**: Tatami 起動中に `open -a Tatami https://example.com` を実行すると、現在のウィンドウの新しいペインで開く

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

### **権限ダイアログ**: カメラ・マイク・位置情報を要求するページで権限ダイアログが出て、許可 / 拒否が反映される

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

</details>

---
