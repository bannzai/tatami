---
feature: platform
verification: manual
last_verified_commit: 72b7bead854a8e1fb1e7968d458a22e4325c42ac
last_verified_at: 2026-09-02
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
  - ❌ 失敗: 保存先の選択ダイアログが出ない。`~/Downloads` へ問い合わせなしで保存される (保存自体と status line の「ダウンロード完了: <パス>」表示は動く)。再現手順: `https://httpbin.org/bytes/2048` をアドレスバーから開く。初回のみ macOS の「"Tatami.app" から、"ダウンロード" フォルダ内のファイルへのアクセス権を求められています」ダイアログが出るので許可すると、そのまま `~/Downloads/2048` に保存される。PROJECT.md 機能要件 1「ダウンロードはユーザーの選んだ場所へ保存する」を満たしていない。issue: https://github.com/bannzai/tatami/issues/56
  - ダウンロードを起こす URL: `Content-Disposition: attachment` を付けただけの `https://httpbin.org/response-headers?...` は `application/json` として WKWebView がインライン表示するためダウンロードにならない。`application/octet-stream` を返す `https://httpbin.org/bytes/<N>` を使う
- [x] **証明書エラー**: https://expired.badssl.com/ を開くと証明書エラーが表示され、ページは黙って読み込まれない
  - 自動化: manual（osascript + screencapture）

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **ダウンロード**: ファイルのダウンロードで保存先の選択ダイアログが出て、選んだ場所に保存され、status line に進捗・完了が出る

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-02**

保存先の選択ダイアログの代わりに出る macOS の Downloads フォルダアクセス許可ダイアログ (初回のみ):

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260902/d665e75f-8024-44a7-bc60-8de9b869c08c.png" width="320">

許可後、`~/Downloads` に保存され status line に「ダウンロード完了: /Users/bannzai/Downloads/2048」が出る:

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260902/39c2a316-f53c-4fe0-8c52-a420cc32ba9b.png" width="320">

</details>

### **証明書エラー**: https://expired.badssl.com/ を開くと証明書エラーが表示され、ページは黙って読み込まれない

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-02**

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260902/3d1c6256-0d16-44e9-b23f-de0daa8665c6.png" width="320">

</details>

</details>

---

## 2. OS 連携

- [x] **他アプリからの URL**: Tatami 起動中に `open -a Tatami https://example.com` を実行すると、現在のウィンドウの新しいペインで開く
  - 自動化: manual（osascript + screencapture）
- [ ] **権限ダイアログ**: カメラ・マイク・位置情報を要求するページで権限ダイアログが出て、許可 / 拒否が反映される
  - 自動化: todo

#### 動作確認
<details>
<summary>動作確認エビデンス</summary>

### **他アプリからの URL**: Tatami 起動中に `open -a Tatami https://example.com` を実行すると、現在のウィンドウの新しいペインで開く

<details><summary>動作確認スクショ</summary>

**確認日: 2026-09-02**

左が実行前から開いていたペイン、右が `open -a Tatami https://example.com` で追加されたペイン (フォーカス付き)。ウィンドウは増えず、status line の現在ウィンドウ名が `example.com` に変わっている:

<img src="https://pub-7f3469dd3e2e445b9b8ec2d1381b5ea8.r2.dev/bannzai/tatami/20260902/14d3f16f-c225-483b-8418-0851bcf6f40d.png" width="320">

</details>

### **権限ダイアログ**: カメラ・マイク・位置情報を要求するページで権限ダイアログが出て、許可 / 拒否が反映される

<details><summary>動作確認スクショ</summary>

（未実行）

</details>

</details>

---
