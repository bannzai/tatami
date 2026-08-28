# 秘匿情報をリポジトリに入れない

本リポジトリは public で、OSS として公開する可能性がある。API キー・トークン・秘密鍵・署名証明書・個人情報 (電話番号・住所・個人メールアドレス) をコミット・PR body・issue・Actions ログに入れない。

- 環境固有の値は git 管理外のファイル (`.envrc`、`Config.local.xcconfig`) にだけ置く。`.gitignore` に登録済み
- GitHub Actions の Secrets は `TS_OIDC_CLIENT_ID` / `TS_OIDC_AUDIENCE` (Tailscale OIDC の識別子) だけを持つ。workflow に長期シークレットを渡さない
- `DEVELOPMENT_TEAM` (Team ID) と bundle id は署名済みアプリから読める公開識別子のため `project.pbxproj` に置いてよい
- commit・push の前に `bash ~/.claude/skills/github-repos-phone-number-check/scripts/check-diff-for-phone-numbers.sh --staged` / `--unpushed` で差分を点検する。承認境界は `~/.claude/CLAUDE.md`「自律性と確認の境界」が SSOT
- Password Manager の実装で扱うテスト用の資格情報は、`example.com` などの予約ドメインとダミー値だけを使い、実在のアカウントの値をフィクスチャに書かない

根拠: [ADR 0002](../../documents/adr/0002-local-only-no-backend.md) (秘匿情報を持つ外部サービスを構成に含めない決定)
