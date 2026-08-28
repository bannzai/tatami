import Foundation
import Observation

/// macOS のウィンドウ 1 つ分 (tmux の session に相当) の状態。複数の PaneWindow (tmux の window) と現在のウィンドウ、
/// アドレスバー・キーバインド・status line のプロンプトを持ち、メニューとキーバインドの宛先になる
@MainActor
@Observable
final class BrowserWindowModel {
    /// status line のプロンプト (tmux の command-prompt 相当)。rename-window の入力に使う
    enum Prompt: Equatable {
        case renameWindow
    }

    /// tmux の既定のセッション名と同じ 0 から始める。セッション管理 (#6) で名前を付けられるようにする
    private(set) var sessionName = "0"
    /// tmux の window の一覧。添字がウィンドウ番号 (0 始まり)
    private(set) var windows: [PaneWindow]
    /// 表示中のウィンドウの添字
    private(set) var currentWindowIndex = 0
    /// last-window で戻る先。閉じられていたら nil
    private(set) var previousWindowIndex: Int?
    /// アドレスバーに入力中のテキスト。フォーカス中のペインの URL に追随する
    var addressText = ""
    /// prefix キーとコマンドの対応。tatami.conf (#7) の読み込みで差し替える
    var keyBindings = KeyBindingTable.default
    /// prefix キーの 2 ストローク検出の状態。status line に prefix 待ちを表示するために公開する
    private(set) var prefixKeyState = PrefixKeyState.idle
    /// 表示中のプロンプト。nil なら通常表示
    private(set) var prompt: Prompt?
    /// プロンプトの入力欄のテキスト
    var promptText = ""
    /// choose-window の一覧を表示中かどうか。表示中は j / k / 数字 / Enter / Escape をこの一覧の操作に使う
    private(set) var isChoosingWindow = false
    /// choose-window の一覧で選択中の添字
    private(set) var chooserSelectionIndex = 0
    /// アドレスバーへのフォーカス要求。回数を増やすことで同じ要求を続けて出せる (View 側が onChange で拾う)
    private(set) var addressBarFocusRequestCount = 0
    /// フォーカス中のペインの表示状態 (タイトル・進捗・戻る/進む) の更新回数。View がこれを読むことで再描画される
    private(set) var focusedPaneStateVersion = 0

    init() {
        windows = []
        windows = [makeWindow()]
        addressText = currentWindow.focusedPane.url.absoluteString
    }

    /// 表示中のウィンドウ
    var currentWindow: PaneWindow {
        windows[currentWindowIndex]
    }

    /// ウィンドウのタイトルバーに出す、フォーカス中のページのタイトル
    var focusedPageTitle: String {
        _ = focusedPaneStateVersion
        return currentWindow.focusedPane.title ?? "Tatami"
    }

    /// フォーカス中のペインの読み込み進捗 (0...1)。読み込み中でなければ nil
    var focusedPaneProgress: Double? {
        _ = focusedPaneStateVersion
        let webView = currentWindow.focusedPane.webView
        return webView.isLoading ? webView.estimatedProgress : nil
    }

    var canGoBack: Bool {
        _ = focusedPaneStateVersion
        return currentWindow.focusedPane.webView.canGoBack
    }

    var canGoForward: Bool {
        _ = focusedPaneStateVersion
        return currentWindow.focusedPane.webView.canGoForward
    }

    /// status line の左側の表示
    var statusLineText: String {
        StatusLine.text(sessionName: sessionName, windowNames: windows.map(\.name), currentWindowIndex: currentWindowIndex)
    }

    /// アドレスバーの入力をフォーカス中のペインで開く
    func navigate(text: String) {
        currentWindow.focusedPane.load(url: AddressInput.resolve(text: text))
    }

    /// 他アプリから渡された URL をフォーカス中のペインで開く
    func open(url: URL) {
        addressText = url.absoluteString
        currentWindow.focusedPane.load(url: url)
    }

    /// アドレスバーへフォーカスを移す (prefix + /)
    func focusAddressBar() {
        addressBarFocusRequestCount += 1
    }

    func goBack() {
        currentWindow.focusedPane.webView.goBack()
    }

    func goForward() {
        currentWindow.focusedPane.webView.goForward()
    }

    func reload() {
        currentWindow.focusedPane.webView.reload()
    }

    /// 新しいウィンドウを末尾に作って表示する (prefix + c)
    func newWindow() {
        windows.append(makeWindow())
        select(windowIndex: windows.count - 1)
    }

    /// 次のウィンドウへ (prefix + n)。末尾の次は先頭
    func nextWindow() {
        select(windowIndex: (currentWindowIndex + 1) % windows.count)
    }

    /// 前のウィンドウへ (prefix + p)。先頭の前は末尾
    func previousWindow() {
        select(windowIndex: (currentWindowIndex - 1 + windows.count) % windows.count)
    }

    /// 直前に表示していたウィンドウへ (prefix + l 相当。tmux の last-window)
    func lastWindow() {
        guard let previousWindowIndex else {
            return
        }
        select(windowIndex: previousWindowIndex)
    }

    /// 番号でウィンドウを選ぶ (prefix + 0-9)。無い番号なら何もしない
    func select(windowIndex: Int) {
        guard windows.indices.contains(windowIndex), windowIndex != currentWindowIndex else {
            return
        }
        previousWindowIndex = currentWindowIndex
        currentWindowIndex = windowIndex
        syncAddressTextToFocusedPane()
        focusedPaneStateVersion += 1
    }

    /// 表示中のウィンドウを閉じる (prefix + &)。最後の 1 つを閉じた時は空のウィンドウに置き換え、セッションは残す
    func killCurrentWindow() {
        windows.remove(at: currentWindowIndex)
        if windows.isEmpty {
            windows = [makeWindow()]
        }
        previousWindowIndex = nil
        currentWindowIndex = min(currentWindowIndex, windows.count - 1)
        syncAddressTextToFocusedPane()
    }

    /// rename-window のプロンプトを開く (prefix + ,)。現在の名前を初期値にする
    func beginRenameWindow() {
        promptText = currentWindow.name
        prompt = .renameWindow
    }

    /// プロンプトの入力を確定する。rename-window は空文字なら automatic-rename に戻す
    func commitPrompt() {
        switch prompt {
        case .renameWindow:
            currentWindow.renamedName = promptText.isEmpty ? nil : promptText
        case nil:
            break
        }
        prompt = nil
    }

    func cancelPrompt() {
        prompt = nil
    }

    /// ウィンドウ一覧 (prefix + w) を開く
    func beginChooseWindow() {
        chooserSelectionIndex = currentWindowIndex
        isChoosingWindow = true
    }

    /// ウィンドウ一覧のキー操作。一覧を閉じるまで他のキーは消費する
    func handleChooserKey(keyStroke: KeyStroke) {
        switch keyStroke.key {
        case "j", "Down":
            chooserSelectionIndex = (chooserSelectionIndex + 1) % windows.count
        case "k", "Up":
            chooserSelectionIndex = (chooserSelectionIndex - 1 + windows.count) % windows.count
        case "Enter":
            isChoosingWindow = false
            select(windowIndex: chooserSelectionIndex)
        case "Escape", "q":
            isChoosingWindow = false
        default:
            if let number = Int(keyStroke.key), windows.indices.contains(number) {
                isChoosingWindow = false
                select(windowIndex: number)
            }
        }
    }

    /// フォーカス中のペインを閉じる。ウィンドウの最後の 1 枚ならウィンドウごと閉じる (tmux の kill-pane と同じ)
    func closeFocusedPane() {
        if !currentWindow.closeFocusedPane() {
            killCurrentWindow()
        }
    }

    /// キー入力を prefix キーの検出に通し、アプリが消費したかどうかを返す。true なら Web ページへ渡さない
    func handle(keyStroke: KeyStroke) -> Bool {
        if isChoosingWindow {
            handleChooserKey(keyStroke: keyStroke)
            return true
        }
        let handled = prefixKeyState.handling(keyStroke: keyStroke, table: keyBindings)
        prefixKeyState = handled.state
        switch handled.outcome {
        case .passThrough:
            return false
        case .consume:
            return true
        case .perform(let command):
            perform(command: command)
            return true
        }
    }

    /// キーバインド (と後続のコマンドプロンプト) から呼ばれる操作の入口
    func perform(command: BrowserCommand) {
        switch command {
        case .splitWindowHorizontal:
            currentWindow.split(axis: .horizontal)
        case .splitWindowVertical:
            currentWindow.split(axis: .vertical)
        case .killPane:
            closeFocusedPane()
        case .selectPaneNext:
            currentWindow.focusNext()
        case .selectPaneLast:
            currentWindow.focusLastPane()
        case .selectPaneLeft:
            currentWindow.focus(direction: .left)
        case .selectPaneDown:
            currentWindow.focus(direction: .down)
        case .selectPaneUp:
            currentWindow.focus(direction: .up)
        case .selectPaneRight:
            currentWindow.focus(direction: .right)
        case .resizePaneZoom:
            currentWindow.toggleZoom()
        case .swapPaneUp:
            currentWindow.swapWithPrevious()
        case .swapPaneDown:
            currentWindow.swapWithNext()
        case .nextLayout:
            currentWindow.applyNextLayout()
        case .newWindow:
            newWindow()
        case .nextWindow:
            nextWindow()
        case .previousWindow:
            previousWindow()
        case .lastWindow:
            lastWindow()
        case .selectWindow(let index):
            select(windowIndex: index)
        case .renameWindow:
            beginRenameWindow()
        case .killWindow:
            killCurrentWindow()
        case .chooseWindow:
            beginChooseWindow()
        case .omnibox:
            focusAddressBar()
        case .goBack:
            goBack()
        case .goForward:
            goForward()
        case .reload:
            reload()
        }
    }

    private func makeWindow() -> PaneWindow {
        let window = PaneWindow()
        window.onFocusedURLChange = { [weak self, weak window] navigatedURL in
            guard let self, let window, currentWindow === window else {
                return
            }
            addressText = navigatedURL.absoluteString
            focusedPaneStateVersion += 1
        }
        window.onFocusedPaneStateChange = { [weak self, weak window] in
            guard let self, let window, currentWindow === window else {
                return
            }
            focusedPaneStateVersion += 1
        }
        return window
    }

    private func syncAddressTextToFocusedPane() {
        addressText = currentWindow.focusedPane.url.absoluteString
    }
}
