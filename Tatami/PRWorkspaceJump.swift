import Foundation

/// GitHub の PR ページを指す URL の分解結果。PR クリックで tmux の作業スペースへジャンプする機能 (issue #47 機能の方向 2) が使う
struct GitHubPullRequestLink: Equatable {
    /// リポジトリの owner (`github.com/<owner>/<repo>/pull/<番号>` の `<owner>`)
    let owner: String
    /// リポジトリ名
    let repo: String
    /// PR 番号
    let number: Int

    /// github.com の PR ページ (`…/pull/<番号>` と、その配下の Files changed 等のタブ) を分解する。PR ページ以外は nil。
    /// owner / repo は GitHub の命名で使える英数字と `_` `-` `.` だけを受け付ける
    /// (URL 由来の値をシェルのスクリプトへ埋め込むため、それ以外の文字を含むものは PR ページとして扱わない)
    static func parse(url: URL) -> GitHubPullRequestLink? {
        guard let host = url.host()?.lowercased(), host == "github.com" || host == "www.github.com" else {
            return nil
        }
        // pathComponents は ["/", owner, repo, "pull", number, ...]
        let components = url.pathComponents
        guard components.count >= 5, components[3] == "pull", let number = Int(components[4]), number > 0 else {
            return nil
        }
        let nameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
        let owner = components[1]
        let repo = components[2]
        guard !owner.isEmpty, !repo.isEmpty,
              owner.unicodeScalars.allSatisfy({ nameCharacters.contains($0) }),
              repo.unicodeScalars.allSatisfy({ nameCharacters.contains($0) }) else {
            return nil
        }
        return GitHubPullRequestLink(owner: owner, repo: repo, number: number)
    }
}

/// PR クリックから tmux の作業スペースへのジャンプ (issue #47 機能の方向 2)。
/// gh で PR の head ブランチを調べ、リポジトリ名の tmux session の該当 window へ移動する。
/// スクリプトの組み立ては純粋ロジックとしてテストし、実行 (Process) は run が担う
enum PRWorkspaceJumper {
    /// 同じ PR の中のタブ移動 (Conversation → Files changed 等) で再ジャンプしないよう、別の PR へ入る時だけ true
    static func shouldJump(currentURL: URL?, destinationLink: GitHubPullRequestLink) -> Bool {
        guard let currentURL, let currentLink = GitHubPullRequestLink.parse(url: currentURL) else {
            return true
        }
        return currentLink != destinationLink
    }

    /// シェルへ安全に埋め込むためのシングルクオート化 (`'` は `'\''` に置き換える)
    static func shellQuoted(text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// ジャンプ全体を行うシェルスクリプト。login shell (`zsh -lc`) で実行する前提
    /// (GUI アプリの PATH には homebrew の gh・tmux が無いため)。
    /// 標準出力の最終行を status line に表示するため、結果は echo で返す。
    /// tmux session はリポジトリ名、window はブランチ名で探す (ユーザーの tmux-issue-setup 運用の対応関係)。
    /// session が無い場合の挙動は未決のため、エラーにせず案内だけ出す (TODO: issue #47)。
    /// terminalApp が nil の時はターミナルを開かない (open するターミナルは tatami.conf で設定し、ハードコードしない: issue #47)
    static func script(link: GitHubPullRequestLink, terminalApp: String?) -> String {
        let repoQuoted = shellQuoted(text: link.repo)
        let slugQuoted = shellQuoted(text: "\(link.owner)/\(link.repo)")
        let openTerminal = terminalApp.map { "open -a \(shellQuoted(text: $0))\n" } ?? ""
        return """
        set -u
        branch=$(gh pr view \(link.number) --repo \(slugQuoted) --json headRefName --jq .headRefName) || { echo "gh で head ブランチを取得できない: \(link.owner)/\(link.repo)#\(link.number)"; exit 1; }
        session=\(repoQuoted)
        if ! tmux has-session -t "=$session" 2>/dev/null; then
          echo "tmux session がない: $session"
          exit 0
        fi
        window=$(tmux list-windows -t "=$session" -F '#{window_index} #{window_name}' | awk -v b="$branch" '$2 == b {print $1; exit}')
        if [ -n "$window" ]; then
          tmux select-window -t "=$session:$window"
        else
          repo_dir="$(ghq root 2>/dev/null || echo "$HOME/ghq")/github.com/\(link.owner)/\(link.repo)"
          worktree=$(git -C "$repo_dir" worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$branch" '/^worktree /{w=$2} $0 == "branch " b {print w; exit}')
          if [ -n "$worktree" ]; then
            tmux new-window -t "=$session:" -n "$branch" -c "$worktree"
          else
            tmux new-window -t "=$session:" -n "$branch"
          fi
        fi
        client=$(tmux list-clients -F '#{client_tty}' 2>/dev/null | head -n 1)
        if [ -n "$client" ]; then
          tmux switch-client -c "$client" -t "=$session"
        fi
        \(openTerminal)echo "ジャンプ: $session への tmux window ($branch)"
        """
    }

    /// スクリプトを login shell で実行し、標準出力 (標準エラーを合流) の最終行を返す。status line への表示に使う。
    /// 何も出力せず終了した場合は nil
    nonisolated static func run(script: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8)?
                    .split(separator: "\n").last.map(String.init))
            }
            do {
                try process.run()
            } catch {
                // run が投げた時は terminationHandler が呼ばれないため、ここで一度だけ resume する
                continuation.resume(returning: "ジャンプの実行に失敗: \(error.localizedDescription)")
            }
        }
    }
}
