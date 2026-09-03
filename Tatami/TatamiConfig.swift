import Foundation

/// tatami.conf を適用した結果の設定値。解釈できなかった項目は既定値のまま残る (documents/PROJECT.md 機能要件 2)
struct TatamiConfig: Equatable {
    /// prefix キーとコマンドの対応 (`set -g prefix` / `bind` / `unbind`)
    var keyBindings = KeyBindingTable.default
    /// 新しいペインを開いた時に読み込む URL (`set -g home`)
    var homeURL = AddressInput.homeURL
    /// アドレスバーの入力が URL でない時に使う検索エンジン (`set -g search-engine`)
    var searchURL = AddressInput.defaultSearchURL
    /// WKWebView に設定する User-Agent (`set -g user-agent`)。nil は WebKit の既定 (Safari 相当) を使うことを表す
    var userAgent: String?
    /// パスワード生成の規則 (`set -g password-length` / `set -g password-symbols on|off`)
    var passwordGenerator = PasswordGenerator()
    /// 資格情報の自動ロックまでの秒数 (`set -g lock-timeout`)
    var lockTimeout = CredentialLockPolicy.defaultLockTimeout
    /// PR クリックのジャンプで open するターミナルのアプリ名 (`set -g terminal-app`)。
    /// nil はターミナルを開かない (open するターミナルはハードコードせず設定で指定する: issue #47 機能の方向 2)
    var terminalApp: String?
}

/// tatami.conf の 1 行を解釈できなかったこと。どこを直せばよいかが分からないと設定を書き直せないため、ファイル名と行番号を必ず持つ
struct TatamiConfigError: Error, CustomStringConvertible, Equatable {
    /// エラーの起きたファイルの表示名。source-file で読んだファイルは設定に書かれていたパス
    let fileName: String
    /// ファイル内の行番号 (1 始まり)
    let line: Int
    /// 何を直せばよいかを示す説明
    let message: String

    var description: String {
        "\(fileName):\(line): \(message)"
    }

    /// status line に出す 1 行のメッセージ。エラーを全部並べると 1 行に収まらないため、先頭だけを出して残りは件数で示す
    static func statusMessage(errors: [TatamiConfigError]) -> String? {
        guard let first = errors.first else {
            return nil
        }
        if errors.count == 1 {
            return first.description
        }
        return "\(first.description) (他 \(errors.count - 1) 件)"
    }
}

/// tatami.conf (`.tmux.conf` 風のテキスト) の解釈。ファイルアクセスを持たない純粋ロジックで、読み込みは TatamiConfigLoader が行う
enum TatamiConfigParser {
    /// source-file の入れ子の上限。循環 include (a が b を読み、b が a を読む) を検出する仕組みを持たないため深さで打ち切る。
    /// 共通の設定を数段読む程度の実用的な入れ子には十分な段数として 8 にしている
    private static let maxIncludeDepth = 8

    /// 1 行の解釈の失敗。ファイル名と行番号は呼び出し元の行ループが知っているため、ここではメッセージだけを運ぶ
    private struct LineError: Error {
        let message: String
    }

    /// text を 1 行ずつ解釈して config を更新し、解釈できなかった行を集めて返す。
    /// 1 行の書き間違いで設定全体が無効にならないよう、エラーの行は飛ばして残りを読み続ける。
    /// fileName はエラー表示に使う名前で、既定は設定ファイル名そのもの (documents/PROJECT.md の `~/.config/tatami/tatami.conf`)。
    /// includeResolver は source-file が読むファイルの中身を返す。nil ならファイルを読まずその行をエラーにする
    static func apply(
        text: String,
        config: inout TatamiConfig,
        fileName: String = "tatami.conf",
        includeResolver: ((String) throws -> String)? = nil,
        baseDirectory: String? = nil
    ) -> [TatamiConfigError] {
        apply(text: text, config: &config, fileName: fileName, includeResolver: includeResolver, baseDirectory: baseDirectory, includeDepth: 0)
    }

    /// source-file のパスの解決。`~` を展開し、相対パスは baseDirectory (読み込み中の設定ファイルのディレクトリ) を基準にする。
    /// GUI から起動したアプリのカレントディレクトリは設定ファイルの場所と一致しないため、カレントディレクトリ基準にしない
    static func resolvedIncludePath(path: String, baseDirectory: String?) -> String {
        let expanded = expandedPath(path: path)
        guard !expanded.hasPrefix("/"), let baseDirectory else {
            return expanded
        }
        return NSString(string: baseDirectory).appendingPathComponent(expanded)
    }

    /// `~` から始まるパスの展開。tatami.conf の source-file と、コマンドからの再読込で同じ解釈にするためここに置く
    static func expandedPath(path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private static func apply(
        text: String,
        config: inout TatamiConfig,
        fileName: String,
        includeResolver: ((String) throws -> String)?,
        baseDirectory: String?,
        includeDepth: Int
    ) -> [TatamiConfigError] {
        var errors: [TatamiConfigError] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = index + 1
            guard let tokens = tokens(line: String(line)) else {
                errors.append(TatamiConfigError(fileName: fileName, line: lineNumber, message: "クオートが閉じていない"))
                continue
            }
            guard let commandName = tokens.first else {
                continue
            }
            let arguments = Array(tokens.dropFirst())
            // catch で LineError のメッセージを受け取るため、do の投げる型を明示する
            do throws(LineError) {
                switch commandName {
                case "set":
                    try applySet(arguments: arguments, config: &config)
                case "bind", "bind-key":
                    try applyBind(arguments: arguments, config: &config)
                case "unbind", "unbind-key":
                    try applyUnbind(arguments: arguments, config: &config)
                case "source-file":
                    errors += try applySourceFile(
                        arguments: arguments,
                        config: &config,
                        includeResolver: includeResolver,
                        baseDirectory: baseDirectory,
                        includeDepth: includeDepth
                    )
                default:
                    throw LineError(message: "知らないコマンド: \(commandName)")
                }
            } catch {
                errors.append(TatamiConfigError(fileName: fileName, line: lineNumber, message: error.message))
            }
        }
        return errors
    }

    /// `set -g prefix C-a` / `set prefix C-a` の形。`-g` (tmux の global) は Tatami の設定が 1 つしか無いため受け付けて無視する
    private static func applySet(arguments: [String], config: inout TatamiConfig) throws(LineError) {
        let values = arguments.first == "-g" ? Array(arguments.dropFirst()) : arguments
        guard values.count == 2 else {
            throw LineError(message: "set はオプション名と値の 2 つを取る")
        }
        switch values[0] {
        case "prefix":
            config.keyBindings.prefix = try keyStroke(tmuxKeyName: values[1])
        case "home":
            config.homeURL = try url(text: values[1])
        case "search-engine":
            config.searchURL = try url(text: values[1])
        case "user-agent":
            config.userAgent = values[1]
        case "terminal-app":
            config.terminalApp = values[1]
        case "password-length":
            guard let length = Int(values[1]), (PasswordGenerator.minimumLength...PasswordGenerator.maximumLength).contains(length) else {
                throw LineError(message: "password-length は \(PasswordGenerator.minimumLength) 以上 \(PasswordGenerator.maximumLength) 以下の整数: \(values[1])")
            }
            config.passwordGenerator.length = length
        case "lock-timeout":
            guard let seconds = Int(values[1]), (CredentialLockPolicy.minimumLockTimeout...CredentialLockPolicy.maximumLockTimeout).contains(seconds) else {
                throw LineError(message: "lock-timeout は \(CredentialLockPolicy.minimumLockTimeout) 以上 \(CredentialLockPolicy.maximumLockTimeout) 以下の秒数: \(values[1])")
            }
            config.lockTimeout = TimeInterval(seconds)
        case "password-symbols":
            switch values[1] {
            case "on":
                config.passwordGenerator.includesSymbols = true
            case "off":
                config.passwordGenerator.includesSymbols = false
            default:
                throw LineError(message: "password-symbols は on か off: \(values[1])")
            }
        default:
            throw LineError(message: "知らないオプション: \(values[0])")
        }
    }

    /// `bind <key> <command...>` の形。コマンドは空白 1 つで連結して BrowserCommand の tmux 名として解釈する。
    /// `bind -n` (prefix を押さずに効くバインド) は、キー入力が prefix の 2 ストローク検出だけを通る作りのため未対応。
    /// 対応する時は PrefixKeyState の idle 状態にも照合先を持たせる
    private static func applyBind(arguments: [String], config: inout TatamiConfig) throws(LineError) {
        if arguments.first == "-n" {
            throw LineError(message: "prefix なしのバインド (bind -n) は未対応")
        }
        guard arguments.count >= 2 else {
            throw LineError(message: "bind はキーとコマンドを取る")
        }
        let commandName = arguments.dropFirst().joined(separator: " ")
        guard let command = BrowserCommand(tmuxName: commandName) else {
            throw LineError(message: "コマンドとして解釈できない: \(commandName)")
        }
        config.keyBindings.bindings[try keyStroke(tmuxKeyName: arguments[0])] = command
    }

    /// `unbind <key>` と、全バインドを消す `unbind -a` の形
    private static func applyUnbind(arguments: [String], config: inout TatamiConfig) throws(LineError) {
        if arguments == ["-a"] {
            config.keyBindings.bindings.removeAll()
            return
        }
        guard arguments.count == 1 else {
            throw LineError(message: "unbind はキーを 1 つ取る")
        }
        // 無いキーの unbind を成功扱いにするのは tmux と同じ。設定を書く側が既定のバインドの有無を気にしなくてよくなる
        config.keyBindings.bindings[try keyStroke(tmuxKeyName: arguments[0])] = nil
    }

    /// `source-file <path>` の形。読んだ内容をその場で適用し、エラーは読んだファイルの中の行番号で返す
    private static func applySourceFile(
        arguments: [String],
        config: inout TatamiConfig,
        includeResolver: ((String) throws -> String)?,
        baseDirectory: String?,
        includeDepth: Int
    ) throws(LineError) -> [TatamiConfigError] {
        guard arguments.count == 1 else {
            throw LineError(message: "source-file はパスを 1 つ取る")
        }
        let path = resolvedIncludePath(path: arguments[0], baseDirectory: baseDirectory)
        guard includeDepth < maxIncludeDepth else {
            throw LineError(message: "source-file の入れ子が深すぎる (\(maxIncludeDepth) 段で打ち切る): \(path)")
        }
        guard let includeResolver else {
            throw LineError(message: "source-file を読み込めない: \(path)")
        }
        let text: String
        do {
            text = try includeResolver(path)
        } catch {
            throw LineError(message: "source-file を読み込めない: \(path): \(error)")
        }
        return apply(
            text: text,
            config: &config,
            fileName: path,
            includeResolver: includeResolver,
            baseDirectory: NSString(string: path).deletingLastPathComponent,
            includeDepth: includeDepth + 1
        )
    }

    private static func keyStroke(tmuxKeyName: String) throws(LineError) -> KeyStroke {
        guard let keyStroke = KeyStroke(tmuxKeyName: tmuxKeyName) else {
            throw LineError(message: "キー名として解釈できない: \(tmuxKeyName)")
        }
        return keyStroke
    }

    /// スキームを持つ URL だけを受け付ける。`example.com` のようなスキーム無しの文字列も URL(string:) は返すが、
    /// 相対 URL として読み込みに失敗するため設定を読んだ時点で弾く。http / https はホストも必須 (`https://` や `http:/x` は読み込みエラーになる)。
    /// `about:blank` のような非 HTTP の URL はホストを求めない
    private static func url(text: String) throws(LineError) -> URL {
        guard let url = URL(string: text), let scheme = url.scheme else {
            throw LineError(message: "URL として解釈できない: \(text)")
        }
        if ["http", "https"].contains(scheme.lowercased()), (url.host() ?? "").isEmpty {
            throw LineError(message: "URL にホストが無い: \(text)")
        }
        return url
    }

    /// 1 行をシェル風の空白区切りのトークンに分ける。`"..."` は `\"` と `\\` のエスケープを解いた値、`'...'` は書いたままの値になる。
    /// `#` はトークンの先頭にある時だけ行末までのコメントにする (URL のフラグメント `https://example.com/#top` を壊さないため)。
    /// クオートが閉じていない行は解釈できないため nil
    static func tokens(line: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        let characters = Array(line)
        var index = characters.startIndex
        while index < characters.endIndex {
            let character = characters[index]
            if character.isWhitespace {
                if hasCurrent {
                    tokens.append(current)
                    current = ""
                    hasCurrent = false
                }
                index += 1
                continue
            }
            if character == "#", !hasCurrent {
                break
            }
            if character == "\"" || character == "'" {
                guard let quoted = quotedValue(characters: characters, index: &index, quote: character) else {
                    return nil
                }
                current += quoted
                hasCurrent = true
                continue
            }
            current.append(character)
            hasCurrent = true
            index += 1
        }
        if hasCurrent {
            tokens.append(current)
        }
        return tokens
    }

    /// 開きクオートの位置から閉じクオートまでの値。index は閉じクオートの次に進む。閉じていなければ nil。
    /// エスケープを解くのはダブルクオートだけで、シングルクオートは tmux と同じく中身をそのまま値にする
    private static func quotedValue(characters: [Character], index: inout Int, quote: Character) -> String? {
        var value = ""
        index += 1
        while index < characters.endIndex {
            let character = characters[index]
            if quote == "\"", character == "\\", index + 1 < characters.endIndex,
               characters[index + 1] == "\"" || characters[index + 1] == "\\" {
                value.append(characters[index + 1])
                index += 2
                continue
            }
            if character == quote {
                index += 1
                return value
            }
            value.append(character)
            index += 1
        }
        return nil
    }
}

/// tatami.conf の読み込み。ファイルアクセスの副作用を持つ薄い層で、行の解釈は TatamiConfigParser に任せる
enum TatamiConfigLoader {
    /// 設定ファイルの既定の場所。XDG Base Directory 風に `~/.config` 配下へ置くと決めている (documents/PROJECT.md 機能要件 2)
    static let defaultFileURL = fileURL(path: "~/.config/tatami/tatami.conf")

    /// `~` から始まるパスを展開したファイル URL。設定に書くパスと `:source-file` の引数を同じ解釈にする
    static func fileURL(path: String) -> URL {
        URL(filePath: TatamiConfigParser.expandedPath(path: path))
    }

    /// 読み込みの結果。parsed が false (ファイルが無い・読めない) なら config は既定値のままで、呼び出し側は現在の設定を維持する
    struct LoadResult {
        let config: TatamiConfig
        let errors: [TatamiConfigError]
        let fileExists: Bool
        /// ファイルを読んで行の解釈まで行えたか (行ごとのエラーがあっても true)
        let parsed: Bool
    }

    /// 設定ファイルを読んで適用する。既定ファイルが無いのは「設定していない」だけなのでエラーにしないが、
    /// `source-file <path>` のように明示したファイルが無いのは書き間違いのため requireFile でエラーにする
    /// base は解釈の起点になる設定。既定ファイルの再読込は nil (既定値から作り直す)、設定内・コマンドの `source-file <path>` は
    /// 現在の設定 (明示した補助ファイルを現在の設定へ重ね、書かれていない項目を既定値へ戻さない)
    static func load(fileURL: URL = defaultFileURL, requireFile: Bool = false, base: TatamiConfig? = nil) -> LoadResult {
        var config = base ?? TatamiConfig()
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            let errors = requireFile ? [TatamiConfigError(fileName: fileURL.lastPathComponent, line: 1, message: "設定ファイルが無い: \(fileURL.path(percentEncoded: false))")] : []
            return LoadResult(config: config, errors: errors, fileExists: false, parsed: false)
        }
        let text: String
        do {
            text = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            // ファイル全体が読めない失敗は行を特定できないため、設定を書いた人が最初に見る 1 行目として報告する
            return LoadResult(config: config, errors: [TatamiConfigError(fileName: fileURL.lastPathComponent, line: 1, message: "設定ファイルを読み込めない: \(error)")], fileExists: true, parsed: false)
        }
        let errors = TatamiConfigParser.apply(
            text: text,
            config: &config,
            fileName: fileURL.lastPathComponent,
            includeResolver: { path in
                try String(contentsOf: URL(filePath: path), encoding: .utf8)
            },
            baseDirectory: fileURL.deletingLastPathComponent().path(percentEncoded: false)
        )
        return LoadResult(config: config, errors: errors, fileExists: true, parsed: true)
    }
}
