# Tatami

tmux の操作体系 (prefix キー + 1 打鍵) で画面分割を扱う、macOS ネイティブの開発用ブラウザ。複数並列開発のコックピットとして使う。畳 = 部屋をタイリングするもの。

## 現在の状況

方向転換 ( https://github.com/bannzai/tatami/issues/47 ) により、普段使いブラウザではなく開発用ブラウザとして進化させる (普段使いは Chrome)。GitHub の効率的な移動と、PR から tmux の作業スペースへのジャンプが今後の中心。

- `prefix + "` / `prefix + %` でペインを上下・左右に分割し、`prefix + o` で次のペインへ。どのサイト上でも prefix が効く
- 設定は `~/.config/tatami/tatami.conf` (`.tmux.conf` 風)。例:

  ```conf
  set -g prefix C-t                                    # prefix の変更 (既定は C-b)
  set -g home https://www.google.com/                  # 新しいペインで開くページ (既定は空ページ)
  set -g search-engine https://duckduckgo.com/?q=      # アドレスバーの検索エンジン (既定は Google)
  bind v split-window -v                               # キーの割り当て変更。unbind <キー> / source-file <パス> も使える
  bind -n C-t reload                                   # prefix なしで直接効くバインド (解除は unbind -n <キー>)
  set -g terminal-app Alacritty                        # PR クリックのジャンプで open するターミナル (未設定なら開かない)
  ```
- GitHub の PR リンクをクリックすると、`gh` で head ブランチを調べ、リポジトリ名の tmux session の該当 window へジャンプする (window が無ければ既存の git worktree を探して `new-window`。session が無い時は status line に案内だけ出す)
- Password Manager は削除予定 ( https://github.com/bannzai/tatami/issues/49 )。削除前に `:export-passwords` (Chrome 互換 CSV) / `:export-cxf` で書き出せる。ただし Secure Enclave 保存の Passkey と署名カウンタが進んだ Passkey は CXF アーカイブに含まれない (完全なバックアップではない)。書き出したファイルは平文 (CSV にはパスワード、CXF の ZIP にはパスワードと Passkey の秘密鍵がそのまま入る) のため、共有領域や通常のバックアップに置かず、移行先へ取り込んだらすぐ削除する。Cookie / セッション永続化によるログイン状態の維持は残る

企画・要件・技術方針は [documents/PROJECT.md](documents/PROJECT.md)、設計判断は [documents/adr/](documents/adr/) を参照。

## 動作環境

- macOS 26 以上 / Xcode 26.5 以上

## ビルドと配置

```sh
make build-macos   # Debug ビルドだけ行う
make test          # ユニットテスト
make macos         # Release ビルドを /Applications/Tatami.app に配置する
```

署名は既定で作者の Apple Developer Team による自動署名になる。その Team に所属していない場合は `make macos DEVELOPMENT_TEAM=<自分の Team ID>` で自分の Team を使うか、`make macos SIGNING=adhoc` で証明書不要の ad-hoc 署名にする (Password Manager 削除 (#49) までの間は、Team 署名と ad-hoc 署名で資格情報の置き場所が異なり互いに読めない点に注意。切り替える前に `:export-passwords` で書き出し、切り替え後に `:import-passwords` で取り込む)。

## 公開ページ

- 紹介ページ: https://bannzai.github.io/tatami/
- [利用規約](docs/Terms-ja.md) / [プライバシーポリシー](docs/PrivacyPolicy-ja.md)

## 方針

収益化はせず、作者の手元のツールとして作る。公開する可能性があるため、秘匿情報 (API キー・トークン・個人情報) はリポジトリに一切含めない (`.claude/rules/no-secrets-in-repository.md`)。
