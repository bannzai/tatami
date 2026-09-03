---
feature: pr_jump
verification: manual
last_verified_commit: null
last_verified_at: null
---

# pr_jump QA

## 関連リンク

- 仕様: https://github.com/bannzai/tatami/blob/main/documents/PROJECT.md (機能の方向 2「PR から作業スペースへのジャンプ」)
- 関連: https://github.com/bannzai/tatami/issues/47 (方向転換)

## 仕様チェックリスト

| ID | 期待挙動 | 対応項目 |
|----|---------|---------|
| S1 | GitHub の PR リンクのクリックで、リポジトリ名の tmux session の head ブランチ名の window へ移動する | 既存 window へのジャンプ |
| S2 | 該当 window が無ければ new-window で作る (既存の git worktree があればそのディレクトリで開く) | window が無い時の作成 |
| S3 | `set -g terminal-app` で指定したターミナルを open する。未設定なら開かない | terminal-app の反映 |
| S4 | リポジトリの tmux session が無い時はエラーにせず status line に案内を出す | session が無い時 |
| S5 | 同じ PR の中のタブ移動 (Conversation → Files changed 等) では再ジャンプしない | 同一 PR 内の抑止 |

## 1. ジャンプ

- [ ] **既存 window へのジャンプ**: PR 一覧から PR リンクをクリックすると、status line に「ジャンプ: <session> への tmux window (<branch>)」が出て、tmux の該当 window が選択される
  - 自動化: manual（osascript + screencapture。tmux 側は `tmux display-message -p '#{session_name}:#{window_name}'` で確認する）
  - 検証時は事前に `tmux display-message -p` で現在の session:window を控え、確認後に元へ戻す (ユーザーの tmux の状態を乱さない)
- [ ] **window が無い時の作成**: head ブランチに対応する window が無い PR で、worktree があればそのディレクトリを cwd に new-window される
  - 自動化: manual（同上。作った window は確認後に kill-window で片付ける）
- [ ] **terminal-app の反映**: `set -g terminal-app <アプリ>` を設定した時だけ、ジャンプでそのアプリが open される
  - 自動化: manual（一時 conf を `:source-file` で読ませて確認し、引数なしの `:source-file` で戻す）
- [ ] **session が無い時**: session の無いリポジトリの PR をクリックすると「tmux session がない: <リポジトリ>」が status line に出て、何も起きない
  - 自動化: manual
- [ ] **同一 PR 内の抑止**: PR ページ内で Files changed 等のタブへ移動しても再ジャンプしない (status line が変わらない)
  - 自動化: manual
