import AppKit

/// キーと修飾キーの組み合わせ。tmux のキー名 (`C-b` / `M-x` / `Space` / `Left` / `"` 等) と 1 対 1 に対応する
struct KeyStroke: Hashable, Sendable {
    /// 修飾キー。tmux が区別する Ctrl と Meta (macOS では Option) と、macOS のキーバインドで使う Shift・Command
    enum Modifier: Hashable, Sendable {
        case control
        case option
        case shift
        case command
    }

    /// 修飾キーを除いたキーの名前。文字キーはその文字 (大文字小文字を区別する)、特殊キーは tmux のキー名 (`Space` / `Enter` / `Escape` / `Tab` / `Left` / `Right` / `Up` / `Down` / `BSpace`)
    let key: String
    let modifiers: Set<Modifier>

    /// 下の failable init を定義すると memberwise initializer が生成されないため、同じ内容を書いている
    init(key: String, modifiers: Set<Modifier>) {
        self.key = key
        self.modifiers = modifiers
    }

    /// tmux の bind-key と同じキー名の表記。`C-` / `M-` / `S-` の接頭辞と、`Space` 等の特殊キー名を受け付ける。解釈できなければ nil
    init?(tmuxKeyName: String) {
        var rest = Substring(tmuxKeyName)
        var modifiers: Set<Modifier> = []
        while rest.count > 2, rest[rest.index(rest.startIndex, offsetBy: 1)] == "-" {
            switch rest.first {
            case "C":
                modifiers.insert(.control)
            case "M":
                modifiers.insert(.option)
            case "S":
                modifiers.insert(.shift)
            default:
                return nil
            }
            rest = rest.dropFirst(2)
        }
        guard !rest.isEmpty else {
            return nil
        }
        if rest.count == 1 {
            // Shift 付きの英字は NSEvent 側の表現 (大文字・Shift なし) に揃え、`S-x` と `X` を同じキーとして扱う
            if modifiers.contains(.shift), rest.first!.isLetter {
                self.key = rest.uppercased()
                modifiers.remove(.shift)
            } else {
                self.key = rest == " " ? KeyStroke.spaceKeyName : String(rest)
            }
        } else if KeyStroke.specialKeyNames.contains(String(rest)) {
            self.key = String(rest)
        } else {
            return nil
        }
        self.modifiers = modifiers
    }

    /// NSEvent が表しうるキーの候補。先頭が主な解釈 (`M-8` のように Option を修飾として持つ形)、続いて Option の変換で生成された文字
    /// (ドイツ語配列の Option+8 = `{` など) を Option なしの文字キーとして扱う形。バインドは先頭から順に照合する
    static func candidates(event: NSEvent) -> [KeyStroke] {
        guard let primary = KeyStroke(event: event) else {
            return []
        }
        guard event.modifierFlags.contains(.option), let produced = event.characters, produced.count == 1,
              let character = produced.first, !character.isLetter, !character.isWhitespace, !character.isNewline,
              character.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              produced != primary.key else {
            return [primary]
        }
        var modifiers = primary.modifiers
        modifiers.remove(.option)
        return [primary, KeyStroke(key: produced, modifiers: modifiers)]
    }

    /// NSEvent からの変換。文字キーは Shift を含めた入力文字で表し、Ctrl・Option の修飾だけを別に持つ
    /// (tmux が `%` を `S-5` ではなく `%` として扱うのに合わせる)。特殊キーは keyCode で判定する
    init?(event: NSEvent) {
        var modifiers: Set<Modifier> = []
        if event.modifierFlags.contains(.control) {
            modifiers.insert(.control)
        }
        if event.modifierFlags.contains(.option) {
            modifiers.insert(.option)
        }
        if event.modifierFlags.contains(.command) {
            modifiers.insert(.command)
        }
        if let specialKeyName = KeyStroke.specialKeyName(keyCode: event.keyCode) {
            if event.modifierFlags.contains(.shift) {
                modifiers.insert(.shift)
            }
            self.key = specialKeyName
            self.modifiers = modifiers
            return
        }
        // Ctrl や Option を押している間の characters は制御文字や記号に変換されるため、修飾キーを外した文字を使う
        guard let characters = event.charactersIgnoringModifiers, characters.count == 1,
              let character = characters.first, !character.isNewline else {
            return nil
        }
        // 英字の大小は実際に印字される文字に合わせる: charactersIgnoringModifiers は Shift だけを反映し Caps Lock を無視するため、
        // 小文字に戻してから Shift と Caps Lock の排他的論理和で大文字にする (Caps Lock 中の Shift + 英字は小文字)
        if character.isLetter {
            let base = String(character).lowercased()
            self.key = event.modifierFlags.contains(.shift) != event.modifierFlags.contains(.capsLock) ? base.uppercased() : base
        } else {
            self.key = String(character)
        }
        self.modifiers = modifiers
    }

    /// tmux と同じ表記 (`C-b` / `M-Space`)。status line の表示に使う
    var tmuxKeyName: String {
        let prefixes = [
            modifiers.contains(.control) ? "C-" : "",
            modifiers.contains(.option) ? "M-" : "",
            modifiers.contains(.shift) && KeyStroke.specialKeyNames.contains(key) ? "S-" : "",
        ]
        return prefixes.joined() + key
    }

    private static let spaceKeyName = "Space"
    private static let specialKeyNames: Set<String> = [spaceKeyName, "Enter", "Escape", "Tab", "Left", "Right", "Up", "Down", "BSpace"]

    /// 特殊キーの keyCode (Carbon の kVK_* の値。文字キーと違いキーボードレイアウトに依存しない)
    private static func specialKeyName(keyCode: UInt16) -> String? {
        switch keyCode {
        case 0x31:
            return spaceKeyName
        case 0x24, 0x4C:
            // 0x4C はテンキーの Enter。Return と同じキーとして扱う
            return "Enter"
        case 0x35:
            return "Escape"
        case 0x30:
            return "Tab"
        case 0x7B:
            return "Left"
        case 0x7C:
            return "Right"
        case 0x7E:
            return "Up"
        case 0x7D:
            return "Down"
        case 0x33:
            return "BSpace"
        default:
            return nil
        }
    }
}

/// キーバインドから呼び出せる操作。tatami.conf の bind-key はこの tmux コマンド名を右辺に書く
enum BrowserCommand: Hashable, Sendable {
    case splitWindowHorizontal
    case splitWindowVertical
    case killPane
    case selectPaneNext
    case selectPaneLast
    case selectPaneLeft
    case selectPaneDown
    case selectPaneUp
    case selectPaneRight
    case resizePaneZoom
    case swapPaneUp
    case swapPaneDown
    case nextLayout
    case newWindow
    case nextWindow
    case previousWindow
    case lastWindow
    /// 番号でウィンドウを選ぶ
    case selectWindow(Int)
    case renameWindow
    case killWindow
    case chooseWindow
    /// アドレスバーへフォーカスを移す (prefix + /。tmux には無い Tatami 固有のコマンド)
    case omnibox
    case goBack
    case goForward
    case reload

    /// tmux のコマンド名。tatami.conf の表記と status line の表示に使う
    var tmuxName: String {
        switch self {
        case .splitWindowHorizontal:
            return "split-window -h"
        case .splitWindowVertical:
            return "split-window -v"
        case .killPane:
            return "kill-pane"
        case .selectPaneNext:
            return "select-pane -t :.+"
        case .selectPaneLast:
            return "last-pane"
        case .selectPaneLeft:
            return "select-pane -L"
        case .selectPaneDown:
            return "select-pane -D"
        case .selectPaneUp:
            return "select-pane -U"
        case .selectPaneRight:
            return "select-pane -R"
        case .resizePaneZoom:
            return "resize-pane -Z"
        case .swapPaneUp:
            return "swap-pane -U"
        case .swapPaneDown:
            return "swap-pane -D"
        case .nextLayout:
            return "next-layout"
        case .newWindow:
            return "new-window"
        case .nextWindow:
            return "next-window"
        case .previousWindow:
            return "previous-window"
        case .lastWindow:
            return "last-window"
        case .selectWindow(let index):
            return "select-window -t \(index)"
        case .renameWindow:
            return "rename-window"
        case .killWindow:
            return "kill-window"
        case .chooseWindow:
            return "choose-window"
        case .omnibox:
            return "omnibox"
        case .goBack:
            return "back"
        case .goForward:
            return "forward"
        case .reload:
            return "reload"
        }
    }

    /// tmux のコマンド名からの変換。空白の連続は 1 つに正規化する。知らないコマンドは nil
    init?(tmuxName: String) {
        let normalized = tmuxName.split(separator: " ").joined(separator: " ")
        if let match = normalized.wholeMatch(of: /select-window -t (\d+)/), let index = Int(match.1) {
            self = .selectWindow(index)
            return
        }
        guard let command = BrowserCommand.fixedCommands.first(where: { $0.tmuxName == normalized }) else {
            return nil
        }
        self = command
    }

    /// 引数を持たないコマンドの一覧 (tmuxName からの逆引き用)
    private static let fixedCommands: [BrowserCommand] = [
        .splitWindowHorizontal, .splitWindowVertical, .killPane, .selectPaneNext, .selectPaneLast,
        .selectPaneLeft, .selectPaneDown, .selectPaneUp, .selectPaneRight, .resizePaneZoom,
        .swapPaneUp, .swapPaneDown, .nextLayout, .newWindow, .nextWindow, .previousWindow, .lastWindow,
        .renameWindow, .killWindow, .chooseWindow, .omnibox, .goBack, .goForward, .reload,
    ]
}

/// prefix キーと、prefix の後に押すキーからコマンドへの対応表。tatami.conf の set -g prefix / bind / unbind がこれを書き換える
struct KeyBindingTable: Equatable, Sendable {
    /// 2 ストロークの 1 打目。既定は tmux と同じ C-b (documents/PROJECT.md)
    var prefix: KeyStroke
    /// prefix の後のキーとコマンドの対応
    var bindings: [KeyStroke: BrowserCommand]

    /// documents/PROJECT.md「コア体験」の既定値
    static let `default` = KeyBindingTable(
        prefix: KeyStroke(tmuxKeyName: "C-b")!,
        bindings: Dictionary(uniqueKeysWithValues: [
            ("\"", BrowserCommand.splitWindowVertical),
            ("%", .splitWindowHorizontal),
            ("x", .killPane),
            ("o", .selectPaneNext),
            (";", .selectPaneLast),
            ("h", .selectPaneLeft),
            ("j", .selectPaneDown),
            ("k", .selectPaneUp),
            ("l", .selectPaneRight),
            ("Left", .selectPaneLeft),
            ("Down", .selectPaneDown),
            ("Up", .selectPaneUp),
            ("Right", .selectPaneRight),
            ("z", .resizePaneZoom),
            ("{", .swapPaneUp),
            ("}", .swapPaneDown),
            ("Space", .nextLayout),
            ("c", .newWindow),
            ("n", .nextWindow),
            ("p", .previousWindow),
            (",", .renameWindow),
            ("&", .killWindow),
            ("w", .chooseWindow),
            ("/", .omnibox),
        ].map { (KeyStroke(tmuxKeyName: $0.0)!, $0.1) } + (0...9).map { (KeyStroke(tmuxKeyName: String($0))!, BrowserCommand.selectWindow($0)) })
    )
}

/// prefix キーの 2 ストローク検出。キー入力を 1 つずつ受け取り、状態の遷移と入力の扱いを返す純粋ロジック
enum PrefixKeyState: Equatable, Sendable {
    /// 通常状態。prefix 以外のキーはそのまま Web ページへ渡す
    case idle
    /// prefix を受け取り、次のキー (コマンド) を待っている
    case awaitingCommand

    /// 1 つのキー入力に対する扱い
    enum Outcome: Equatable, Sendable {
        /// このアプリでは扱わず Web ページへ渡す
        case passThrough
        /// アプリが消費し Web ページへ渡さない (prefix 自体・未定義のキー・取り消し)
        case consume
        /// コマンドを実行する
        case perform(BrowserCommand)
    }

    /// prefix 待ちの取り消しは tmux と同じく Escape で行う。バインドされていないキーと同じく消費して idle に戻るため、特別な分岐は持たない
    func handling(keyStroke: KeyStroke, table: KeyBindingTable) -> (state: PrefixKeyState, outcome: Outcome) {
        handling(keyStrokes: [keyStroke], table: table)
    }

    /// 1 つのキー入力の候補 (KeyStroke.candidates) を先頭から照合する。prefix の判定と bind の検索の両方で、先に一致した候補を使う
    func handling(keyStrokes: [KeyStroke], table: KeyBindingTable) -> (state: PrefixKeyState, outcome: Outcome) {
        switch self {
        case .idle:
            return keyStrokes.contains(table.prefix) ? (.awaitingCommand, .consume) : (.idle, .passThrough)
        case .awaitingCommand:
            // 設定で Escape にコマンドを割り当てた場合はそれを優先し、未設定の時だけ取り消しとして扱う (どちらも消費して idle に戻る)
            guard let command = keyStrokes.lazy.compactMap({ table.bindings[$0] }).first else {
                return (.idle, .consume)
            }
            return (.idle, .perform(command))
        }
    }

    /// prefix 待ちを取り消す (ウィンドウがキーウィンドウでなくなった時など)
    var cancelled: PrefixKeyState {
        .idle
    }
}
