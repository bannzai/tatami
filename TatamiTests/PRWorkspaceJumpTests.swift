import Foundation
import Testing
@testable import Tatami

/// GitHubPullRequestLink.parse の対象判定
struct GitHubPullRequestLinkTests {
    @Test func pullRequestURLBecomesLink() {
        #expect(
            GitHubPullRequestLink.parse(url: URL(string: "https://github.com/bannzai/tatami/pull/57")!)
                == GitHubPullRequestLink(owner: "bannzai", repo: "tatami", number: 57)
        )
    }

    @Test func pullRequestTabURLBecomesSameLink() {
        #expect(
            GitHubPullRequestLink.parse(url: URL(string: "https://github.com/bannzai/tatami/pull/57/files")!)
                == GitHubPullRequestLink(owner: "bannzai", repo: "tatami", number: 57)
        )
    }

    @Test func nonPullRequestURLsAreNil() {
        // issue ページ・PR 一覧・別ホスト・番号でないパス・シェルへ埋め込めない owner は対象外
        #expect(GitHubPullRequestLink.parse(url: URL(string: "https://github.com/bannzai/tatami/issues/57")!) == nil)
        #expect(GitHubPullRequestLink.parse(url: URL(string: "https://github.com/bannzai/tatami/pulls")!) == nil)
        #expect(GitHubPullRequestLink.parse(url: URL(string: "https://example.com/bannzai/tatami/pull/57")!) == nil)
        #expect(GitHubPullRequestLink.parse(url: URL(string: "https://github.com/bannzai/tatami/pull/abc")!) == nil)
        #expect(GitHubPullRequestLink.parse(url: URL(string: "https://github.com/ban$(rm)zai/tatami/pull/57")!) == nil)
    }
}

/// PRWorkspaceJumper の純粋ロジック (再ジャンプ判定・スクリプトの組み立て)
struct PRWorkspaceJumperTests {
    private let link = GitHubPullRequestLink(owner: "bannzai", repo: "tatami", number: 57)

    @Test func jumpsWhenEnteringPullRequestFromOutside() {
        #expect(PRWorkspaceJumper.shouldJump(currentURL: URL(string: "https://github.com/bannzai/tatami/pulls"), destinationLink: link))
        #expect(PRWorkspaceJumper.shouldJump(currentURL: nil, destinationLink: link))
    }

    @Test func doesNotJumpWithinSamePullRequest() {
        #expect(!PRWorkspaceJumper.shouldJump(currentURL: URL(string: "https://github.com/bannzai/tatami/pull/57"), destinationLink: link))
    }

    @Test func jumpsBetweenDifferentPullRequests() {
        #expect(PRWorkspaceJumper.shouldJump(currentURL: URL(string: "https://github.com/bannzai/tatami/pull/56"), destinationLink: link))
    }

    @Test func shellQuotedEscapesSingleQuote() {
        #expect(PRWorkspaceJumper.shellQuoted(text: "it's") == "'it'\\''s'")
    }

    @Test func scriptTargetsRepoSessionAndHeadBranch() {
        let script = PRWorkspaceJumper.script(link: link, terminalApp: nil)
        #expect(script.contains("gh pr view 57 --repo 'bannzai/tatami' --json headRefName"))
        #expect(script.contains("session='tatami'"))
        #expect(script.contains("tmux switch-client"))
        // terminal-app 未設定ではターミナルを開かない
        #expect(!script.contains("open -a"))
    }

    @Test func scriptOpensConfiguredTerminal() {
        #expect(PRWorkspaceJumper.script(link: link, terminalApp: "Alacritty").contains("open -a 'Alacritty'"))
    }
}
