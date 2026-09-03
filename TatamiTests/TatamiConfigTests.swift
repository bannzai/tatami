import Foundation
import Testing
@testable import Tatami

/// tatami.conf の行の解釈 (set / bind / unbind / source-file) と、解釈できない行を飛ばして残りを適用する挙動を検証する
struct TatamiConfigTests {
    /// source-file の読み込みをファイルアクセス無しで検証するための、パスと中身の対応
    private func includeResolver(files: [String: String]) -> (String) throws -> String {
        { path in
            guard let text = files[path] else {
                throw CocoaError(.fileNoSuchFile)
            }
            return text
        }
    }

    @Test func exampleConfigIsApplied() {
        var config = TatamiConfig()
        let errors = TatamiConfigParser.apply(text: """
            # Tatami の設定
            set -g prefix C-a

              # 行頭に空白のあるコメント
            set -g home https://example.com/start
            set -g search-engine https://duckduckgo.com/
            set -g user-agent "Mozilla/5.0 (Macintosh) Tatami/1.0"

            bind v split-window -v    # 複数トークンのコマンド
            bind o reload             # 既定のバインドを上書きする
            bind '"' kill-pane
            unbind z
            """, config: &config)
        #expect(errors.isEmpty)
        #expect(config.keyBindings.prefix == KeyStroke(tmuxKeyName: "C-a"))
        #expect(config.homeURL == URL(string: "https://example.com/start"))
        #expect(config.searchURL == URL(string: "https://duckduckgo.com/"))
        #expect(config.userAgent == "Mozilla/5.0 (Macintosh) Tatami/1.0")
        #expect(config.keyBindings.bindings[KeyStroke(tmuxKeyName: "v")!] == .splitWindowVertical)
        #expect(config.keyBindings.bindings[KeyStroke(tmuxKeyName: "o")!] == .reload)
        #expect(config.keyBindings.bindings[KeyStroke(tmuxKeyName: "\"")!] == .killPane)
        #expect(config.keyBindings.bindings[KeyStroke(tmuxKeyName: "z")!] == nil)
        // 触れていない既定のバインドはそのまま残る
        #expect(config.keyBindings.bindings[KeyStroke(tmuxKeyName: "%")!] == .splitWindowHorizontal)
    }

    @Test func emptyConfigKeepsDefaults() {
        var config = TatamiConfig()
        #expect(TatamiConfigParser.apply(text: "\n# コメントだけ\n\n", config: &config).isEmpty)
        #expect(config == TatamiConfig())
    }

    @Test func setWithoutGlobalFlagIsAccepted() {
        var config = TatamiConfig()
        #expect(TatamiConfigParser.apply(text: "set prefix M-a", config: &config).isEmpty)
        #expect(config.keyBindings.prefix == KeyStroke(tmuxKeyName: "M-a"))
    }

    @Test func unbindAllRemovesEveryBinding() {
        var config = TatamiConfig()
        #expect(TatamiConfigParser.apply(text: "unbind -a\nbind c new-window", config: &config).isEmpty)
        #expect(config.keyBindings.bindings == [KeyStroke(tmuxKeyName: "c")!: .newWindow])
        // prefix は unbind -a の対象ではない
        #expect(config.keyBindings.prefix == KeyBindingTable.default.prefix)
    }

    @Test func unbindingMissingKeyIsNotAnError() {
        var config = TatamiConfig()
        #expect(TatamiConfigParser.apply(text: "unbind F", config: &config).isEmpty)
    }

    @Test func rootBindingIsStoredSeparatelyFromPrefixBindings() {
        var config = TatamiConfig()
        #expect(TatamiConfigParser.apply(text: "bind -n C-t reload", config: &config).isEmpty)
        #expect(config.keyBindings.rootBindings[KeyStroke(tmuxKeyName: "C-t")!] == .reload)
        // prefix 側の同じキーのバインドには影響しない
        #expect(config.keyBindings.bindings[KeyStroke(tmuxKeyName: "C-t")!] == nil)
    }

    @Test func unbindWithRootFlagRemovesOnlyRootBinding() {
        var config = TatamiConfig()
        #expect(TatamiConfigParser.apply(text: """
            bind -n C-t reload
            unbind -n C-t
            """, config: &config).isEmpty)
        #expect(config.keyBindings.rootBindings.isEmpty)
        // prefix 側の既定バインドは残る
        #expect(!config.keyBindings.bindings.isEmpty)
    }

    @Test func unbindAllWithRootFlagClearsOnlyRootBindings() {
        var config = TatamiConfig()
        #expect(TatamiConfigParser.apply(text: """
            bind -n C-t reload
            unbind -a -n
            """, config: &config).isEmpty)
        #expect(config.keyBindings.rootBindings.isEmpty)
        #expect(!config.keyBindings.bindings.isEmpty)
    }

    @Test func brokenLinesAreReportedWithLineNumbersAndSkipped() {
        var config = TatamiConfig()
        let errors = TatamiConfigParser.apply(text: """
            set -g prefix Foo
            set -g home example.com
            set -g theme dark
            bind Foo reload
            bind r no-such-command
            bind -n Foo reload
            unbind Foo
            attach-session
            bind q "閉じていない
            set -g prefix C-a
            """, config: &config)
        #expect(errors.map(\.line) == [1, 2, 3, 4, 5, 6, 7, 8, 9])
        #expect(errors.map(\.description) == [
            "tatami.conf:1: キー名として解釈できない: Foo",
            "tatami.conf:2: URL として解釈できない: example.com",
            "tatami.conf:3: 知らないオプション: theme",
            "tatami.conf:4: キー名として解釈できない: Foo",
            "tatami.conf:5: コマンドとして解釈できない: no-such-command",
            "tatami.conf:6: キー名として解釈できない: Foo",
            "tatami.conf:7: キー名として解釈できない: Foo",
            "tatami.conf:8: 知らないコマンド: attach-session",
            "tatami.conf:9: クオートが閉じていない",
        ])
        // エラーの行を飛ばして最後の行まで読み続ける
        #expect(config.keyBindings.prefix == KeyStroke(tmuxKeyName: "C-a"))
        // 失敗した行の値は既定のまま残る
        #expect(config.homeURL == AddressInput.homeURL)
    }

    @Test func argumentCountsAreChecked() {
        var config = TatamiConfig()
        let errors = TatamiConfigParser.apply(text: """
            set -g home not a url
            bind x
            unbind x y
            source-file
            """, config: &config)
        #expect(errors.map(\.message) == [
            "set はオプション名と値の 2 つを取る",
            "bind はキーとコマンドを取る",
            "unbind はキーを 1 つ取る",
            "source-file はパスを 1 つ取る",
        ])
    }

    @Test func quotedTokensKeepSpacesAndEscapes() {
        var config = TatamiConfig()
        let errors = TatamiConfigParser.apply(text: #"""
            set -g user-agent "Tatami \"1.0\" \\ # not a comment"
            """#, config: &config)
        #expect(errors.isEmpty)
        #expect(config.userAgent == #"Tatami "1.0" \ # not a comment"#)
    }

    @Test func singleQuotedTokenKeepsBackslash() {
        var config = TatamiConfig()
        #expect(TatamiConfigParser.apply(text: #"set -g user-agent 'Tatami \1.0'"#, config: &config).isEmpty)
        #expect(config.userAgent == #"Tatami \1.0"#)
    }

    /// `#` はトークンの先頭にある時だけコメント。URL のフラグメントを壊さない
    @Test func hashInsideTokenIsNotAComment() {
        var config = TatamiConfig()
        #expect(TatamiConfigParser.apply(text: "set -g home https://example.com/#top   # ここはコメント", config: &config).isEmpty)
        #expect(config.homeURL == URL(string: "https://example.com/#top"))
    }

    @Test func sourceFileAppliesIncludedFileAndReportsItsLineNumbers() {
        var config = TatamiConfig()
        let errors = TatamiConfigParser.apply(
            text: "source-file /etc/tatami/common.conf\nbind c new-window",
            config: &config,
            includeResolver: includeResolver(files: [
                "/etc/tatami/common.conf": "set -g prefix C-t\nbind Foo reload\nbind r reload",
            ])
        )
        #expect(errors.map(\.description) == ["/etc/tatami/common.conf:2: キー名として解釈できない: Foo"])
        #expect(config.keyBindings.prefix == KeyStroke(tmuxKeyName: "C-t"))
        #expect(config.keyBindings.bindings[KeyStroke(tmuxKeyName: "r")!] == .reload)
        #expect(config.keyBindings.bindings[KeyStroke(tmuxKeyName: "c")!] == .newWindow)
    }

    @Test func sourceFileExpandsTildeInPath() {
        var config = TatamiConfig()
        let errors = TatamiConfigParser.apply(
            text: "source-file ~/.config/tatami/common.conf",
            config: &config,
            includeResolver: includeResolver(files: [
                "\(NSHomeDirectory())/.config/tatami/common.conf": "set -g prefix C-t",
            ])
        )
        #expect(errors.isEmpty)
        #expect(config.keyBindings.prefix == KeyStroke(tmuxKeyName: "C-t"))
    }

    @Test func circularSourceFileStopsAtDepthLimit() {
        var config = TatamiConfig()
        let errors = TatamiConfigParser.apply(
            text: "source-file /a.conf",
            config: &config,
            includeResolver: includeResolver(files: [
                "/a.conf": "source-file /b.conf",
                "/b.conf": "source-file /a.conf",
            ])
        )
        #expect(errors.count == 1)
        #expect(errors[0].line == 1)
        #expect(errors[0].message.hasPrefix("source-file の入れ子が深すぎる"))
    }

    @Test func sourceFileWithoutResolverIsAnError() {
        var config = TatamiConfig()
        #expect(TatamiConfigParser.apply(text: "source-file /a.conf", config: &config).map(\.message) == [
            "source-file を読み込めない: /a.conf",
        ])
    }

    @Test func sourceFileOfMissingFileIsAnError() {
        var config = TatamiConfig()
        let errors = TatamiConfigParser.apply(
            text: "source-file /a.conf",
            config: &config,
            includeResolver: includeResolver(files: [:])
        )
        #expect(errors.count == 1)
        #expect(errors[0].message.hasPrefix("source-file を読み込めない: /a.conf: "))
    }

    @Test func sourceFileCommandRoundTripsThroughTmuxName() {
        for command in [BrowserCommand.sourceFile(nil), .sourceFile("~/.config/tatami/tatami.conf")] {
            #expect(BrowserCommand(tmuxName: command.tmuxName) == command)
        }
        #expect(BrowserCommand.sourceFile(nil).tmuxName == "source-file")
        #expect(BrowserCommand.sourceFile("/a.conf").tmuxName == "source-file /a.conf")
    }

    @Test func sourceFileCanBeBound() {
        var config = TatamiConfig()
        #expect(TatamiConfigParser.apply(text: "bind R source-file\nbind S source-file /a.conf", config: &config).isEmpty)
        #expect(config.keyBindings.bindings[KeyStroke(tmuxKeyName: "R")!] == .sourceFile(nil))
        #expect(config.keyBindings.bindings[KeyStroke(tmuxKeyName: "S")!] == .sourceFile("/a.conf"))
    }

    @Test func statusMessageShowsFirstErrorAndRemainingCount() {
        let first = TatamiConfigError(fileName: "tatami.conf", line: 2, message: "知らないコマンド: foo")
        #expect(TatamiConfigError.statusMessage(errors: []) == nil)
        #expect(TatamiConfigError.statusMessage(errors: [first]) == "tatami.conf:2: 知らないコマンド: foo")
        #expect(TatamiConfigError.statusMessage(errors: [first, first, first]) == "tatami.conf:2: 知らないコマンド: foo (他 2 件)")
    }

    @Test func loaderReadsFileAndFollowsSourceFile() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appending(path: "tatami-config-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let fileURL = directoryURL.appending(path: "tatami.conf")
        // ファイルが無いのは設定していないだけなので、既定の設定とエラー無しになる
        let missing = TatamiConfigLoader.load(fileURL: fileURL)
        #expect(missing.config == TatamiConfig())
        #expect(missing.errors.isEmpty)

        let includedURL = directoryURL.appending(path: "common.conf")
        try "bind r reload\nbind Foo reload\n".write(to: includedURL, atomically: true, encoding: .utf8)
        try "set -g prefix C-a\nsource-file \(includedURL.path(percentEncoded: false))\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let loaded = TatamiConfigLoader.load(fileURL: fileURL)
        #expect(loaded.config.keyBindings.prefix == KeyStroke(tmuxKeyName: "C-a"))
        #expect(loaded.config.keyBindings.bindings[KeyStroke(tmuxKeyName: "r")!] == .reload)
        #expect(loaded.errors.map(\.description) == ["\(includedURL.path(percentEncoded: false)):2: キー名として解釈できない: Foo"])
    }

    @Test func defaultFileURLIsUnderConfigDirectory() {
        #expect(TatamiConfigLoader.defaultFileURL.path(percentEncoded: false) == "\(NSHomeDirectory())/.config/tatami/tatami.conf")
        #expect(TatamiConfigLoader.fileURL(path: "~/x.conf").path(percentEncoded: false) == "\(NSHomeDirectory())/x.conf")
    }

    @Test func httpURLsWithoutHostAreRejected() {
        var config = TatamiConfig()
        let errors = TatamiConfigParser.apply(text: "set -g home https://\nset -g search-engine http:/x\nset -g home about:blank", config: &config)
        #expect(errors.map(\.line) == [1, 2])
        #expect(errors.allSatisfy { $0.message.hasPrefix("URL にホストが無い") })
        #expect(config.homeURL == URL(string: "about:blank"))
    }

    @Test func explicitMissingFileIsReportedWhenRequired() {
        let fileURL = FileManager.default.temporaryDirectory.appending(path: "tatami-missing-\(UUID().uuidString).conf")
        let optional = TatamiConfigLoader.load(fileURL: fileURL)
        #expect(optional.errors.isEmpty)
        #expect(!optional.fileExists)
        let required = TatamiConfigLoader.load(fileURL: fileURL, requireFile: true)
        #expect(required.errors.count == 1)
        #expect(required.errors[0].message.hasPrefix("設定ファイルが無い"))
        #expect(!required.fileExists)
        #expect(!required.parsed)
    }

    @Test func unreadableFileIsNotParsed() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appending(path: "tatami-dir-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let result = TatamiConfigLoader.load(fileURL: directoryURL)
        #expect(result.fileExists)
        #expect(!result.parsed)
        #expect(result.errors.count == 1)
        #expect(result.errors[0].message.hasPrefix("設定ファイルを読み込めない"))
    }

    @Test func relativeSourceFileIsResolvedFromConfigDirectory() {
        var config = TatamiConfig()
        var requestedPaths: [String] = []
        let errors = TatamiConfigParser.apply(
            text: "source-file common.conf",
            config: &config,
            fileName: "tatami.conf",
            includeResolver: { path in
                requestedPaths.append(path)
                return "set -g prefix C-t"
            },
            baseDirectory: "/home/user/.config/tatami"
        )
        #expect(errors.isEmpty)
        #expect(requestedPaths == ["/home/user/.config/tatami/common.conf"])
        #expect(config.keyBindings.prefix == KeyStroke(tmuxKeyName: "C-t"))
        #expect(TatamiConfigParser.resolvedIncludePath(path: "/abs/x.conf", baseDirectory: "/base") == "/abs/x.conf")
        #expect(TatamiConfigParser.resolvedIncludePath(path: "x.conf", baseDirectory: nil) == "x.conf")
    }

    @Test func passwordGenerationSettings() {
        var config = TatamiConfig()
        let errors = TatamiConfigParser.apply(text: "set -g password-length 32\nset -g password-symbols off\nset -g password-length 3\nset -g password-symbols maybe\nset -g password-length 100000", config: &config)
        #expect(config.passwordGenerator == PasswordGenerator(length: 32, includesSymbols: false))
        #expect(errors.map(\.line) == [3, 4, 5])
    }

    @Test func loaderOverlaysExplicitFileOnBaseConfig() throws {
        let fileURL = FileManager.default.temporaryDirectory.appending(path: "tatami-extras-\(UUID().uuidString).conf")
        try "set -g user-agent TatamiTest/1.0".write(to: fileURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }
        var base = TatamiConfig()
        base.homeURL = URL(string: "https://example.com/")!
        // 明示したファイルは base へ重ねる (書かれていない項目を既定値へ戻さない)
        let overlaid = TatamiConfigLoader.load(fileURL: fileURL, requireFile: true, base: base)
        #expect(overlaid.config.homeURL == base.homeURL)
        #expect(overlaid.config.userAgent == "TatamiTest/1.0")
        // base 無しは既定値から作り直す
        let fresh = TatamiConfigLoader.load(fileURL: fileURL, requireFile: true)
        #expect(fresh.config.homeURL == TatamiConfig().homeURL)
    }
}
