# 0002. データはすべて端末内 (Keychain + ローカルファイル) に置き、バックエンド・DB・Analytics を持たない

## Status
Accepted (2026-08-28)

補記 (2026-09-02): Password Manager は方向転換 (#47) により削除した (#49)。資格情報・Keychain に関する記述は削除前の状態を指す

## Context
Tatami は作者の手元で使う個人用ブラウザで、収益化しない。決めるべきは DB・ストレージ・ホスティング・認証・Analytics の構成。扱うデータはセッション (ペインツリー・URL)、設定、履歴・ブックマーク、そして Password Manager の資格情報で、ユーザー間で共有するものはない。

リポジトリは public で、秘匿情報をコミットしない前提がある。サーバーや外部 SaaS を持つと、その接続情報の管理が必要になる。

## Decision
- **資格情報 (パスワード・Passkey の秘密鍵)**: Keychain の自前アイテム。`kSecAttrSynchronizable` で iCloud 同期し、将来の iOS 版と同じストアを共有できるようにする。Passkey の秘密鍵は Secure Enclave で生成し、端末外に出さない
- **セッション・設定・履歴・ブックマーク**: `~/Library/Application Support/Tatami/` 配下のファイル (JSON) と `~/.config/tatami/tatami.conf`。サーバー DB・SwiftData は使わない (構造が単純で、テキストとして diff・バックアップできる方が個人ツールに向く)
- **ホスティング / バックエンド**: なし。法務ドキュメントと紹介ページは GitHub Pages (`docs/`) で配信する
- **認証**: なし (アカウントレス)。アンロックは Touch ID / ローカルパスワード
- **Analytics / クラッシュレポート**: 導入しない。Firebase / GCP を使わないため、GCP アラート・Slack 通知チャンネルの整備は対象外
- **CI / 動作確認**: public リポジトリのため GitHub Actions の macOS runner を無料で使える。PR ごとのビルド・テスト (`ci.yml`) と、simtunnel 経由の GUI 動作確認 (`macos-app-session.yml`) を macOS runner で行う

## Consequences

**良い点:**
- サーバー運用・認証・接続情報の管理がゼロになり、public リポジトリに秘匿情報を置く必要が構造的に生じない
- 「資格情報は端末と iCloud Keychain の外に出ない」とプライバシーポリシーで言い切れる
- セッション・設定がテキストファイルのため、手で編集・バックアップ・git 管理できる

**悪い点 / 引き受けるリスク:**
- 端末間の同期は資格情報 (iCloud Keychain) だけ。セッション・ブックマークの同期が欲しくなったら iCloud Drive へのファイル配置など別 ADR で決める
- 利用状況・クラッシュの計測がない。公開後に必要になれば導入を再検討する
