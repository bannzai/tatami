# Tatami

tmux の操作体系 (prefix キー + 1 打鍵) で画面分割を扱う、macOS ネイティブの個人用ブラウザ。畳 = 部屋をタイリングするもの。

## 現在の実装状況

開発中。現時点の実装はアドレスバー + WKWebView 1 枚の最小構成で、以下は設計済みの予定機能。進捗はロードマップ issue (https://github.com/bannzai/tatami/issues/20 ) を参照。

- (予定) `prefix + "` / `prefix + %` でペインを上下・左右に分割し、`prefix + o` で次のペインへ。どのサイト上でも prefix が効く
- (予定) 設定は `~/.config/tatami/tatami.conf` (`.tmux.conf` 風)
- (予定) Password Manager を内蔵する (Keychain バックエンド・Chrome 互換 CSV の入出力・Credential Provider Extension・Passkey)

企画・要件・技術方針は [documents/PROJECT.md](documents/PROJECT.md)、設計判断は [documents/adr/](documents/adr/) を参照。

## 動作環境

- macOS 26 以上 / Xcode 26.5 以上

## ビルドと配置

```sh
make build-macos   # Debug ビルドだけ行う
make test          # ユニットテスト
make macos         # Release ビルドを /Applications/Tatami.app に配置する
```

署名は既定で作者の Apple Developer Team による自動署名になる。その Team に所属していない場合は `make macos DEVELOPMENT_TEAM=<自分の Team ID>` で自分の Team を使うか、`make macos SIGNING=adhoc` で証明書不要の ad-hoc 署名にする。Team 署名で保存した Password Manager の資格情報は ad-hoc 署名のビルドからは読めない (Keychain の共有 access group が無いため) ので、Team 署名から ad-hoc へ切り替える前に `:export-passwords` で書き出す。

## 公開ページ

- 紹介ページ: https://bannzai.github.io/tatami/
- [利用規約](docs/Terms-ja.md) / [プライバシーポリシー](docs/PrivacyPolicy-ja.md)

## 方針

収益化はせず、作者の手元のツールとして作る。公開する可能性があるため、秘匿情報 (API キー・トークン・個人情報) はリポジトリに一切含めない (`.claude/rules/no-secrets-in-repository.md`)。
