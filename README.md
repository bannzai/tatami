# Tatami

tmux の操作体系 (prefix キー + 1 打鍵) で画面分割を扱う、macOS ネイティブの個人用ブラウザ。畳 = 部屋をタイリングするもの。

## 現在の実装状況

MVP ロードマップ (https://github.com/bannzai/tatami/issues/20 ) の子 issue はすべて実装済み。実サイトでの検証と細部の調整を続けている。

- `prefix + "` / `prefix + %` でペインを上下・左右に分割し、`prefix + o` で次のペインへ。どのサイト上でも prefix が効く
- 設定は `~/.config/tatami/tatami.conf` (`.tmux.conf` 風)。例:

  ```conf
  set -g prefix C-t                                    # prefix の変更 (既定は C-b)
  set -g home https://www.google.com/                  # 新しいペインで開くページ (既定は空ページ)
  set -g search-engine https://duckduckgo.com/?q=      # アドレスバーの検索エンジン (既定は Google)
  bind v split-window -v                               # キーの割り当て変更。unbind <キー> / source-file <パス> も使える
  ```

企画・要件・技術方針は [documents/PROJECT.md](documents/PROJECT.md)、設計判断は [documents/adr/](documents/adr/) を参照。

## 動作環境

- macOS 26 以上 / Xcode 26.5 以上

## ビルドと配置

```sh
make build-macos   # Debug ビルドだけ行う
make test          # ユニットテスト
make macos         # Release ビルドを /Applications/Tatami.app に配置する
```

署名は既定で作者の Apple Developer Team による自動署名になる。その Team に所属していない場合は `make macos DEVELOPMENT_TEAM=<自分の Team ID>` で自分の Team を使うか、`make macos SIGNING=adhoc` で証明書不要の ad-hoc 署名にする。

## 公開ページ

- 紹介ページ: https://bannzai.github.io/tatami/
- [利用規約](docs/Terms-ja.md) / [プライバシーポリシー](docs/PrivacyPolicy-ja.md)

## 方針

収益化はせず、作者の手元のツールとして作る。公開する可能性があるため、秘匿情報 (API キー・トークン・個人情報) はリポジトリに一切含めない (`.claude/rules/no-secrets-in-repository.md`)。
