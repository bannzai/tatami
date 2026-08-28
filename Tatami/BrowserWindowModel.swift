import AppKit
import Foundation
import Observation
import WebKit

/// macOS のウィンドウ 1 つ分 (tmux の session に相当) の状態。複数の PaneWindow (tmux の window) と現在のウィンドウ、
/// アドレスバー・キーバインド・status line のプロンプトを持ち、メニューとキーバインドの宛先になる
@MainActor
@Observable
final class BrowserWindowModel {
    /// status line のプロンプト (tmux の command-prompt 相当)。rename-window / rename-session の入力に使う
    enum Prompt: Equatable {
        case renameWindow
        case renameSession
        /// `:` から始まるコマンドの入力 (prefix + :)
        case command
        /// ページ内検索の語の入力 (prefix + [)
        case find
    }

    /// 一覧から選ぶ操作 (choose-window / choose-session / ブックマーク)。表示中は j / k / 数字 / Enter / Escape をこの一覧の操作に使う
    enum Chooser: Equatable {
        case window
        /// 保存済みセッションの名前一覧
        case session([String])
        /// ブックマークの一覧。x で選択中の項目を削除する
        case bookmark
    }

    /// 最後に表示していたセッション名の保存先。次回起動時にこのセッションを復元する
    private static let lastSessionNameKey = "lastSessionName"
    /// 表示中 (activate 済み) のモデルが開いているセッション名。同じセッションを別々のモデルで同時に開くと、古い側の保存が新しい状態を上書きするため、
    /// 2 つ目以降は新しいセッションで始める
    private static var openSessionNames: Set<String> = []
    /// 保存の debounce 間隔。連続する操作 (リサイズのドラッグ等) をまとめつつ、クラッシュしても直近の状態が残る程度に短くする
    private static let saveDelay: Duration = .milliseconds(500)

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
    /// 表示中 (activate 済み) の全モデル。設定の再読込を全ウィンドウのペインへ反映するために使う
    private static let activeModels = NSHashTable<BrowserWindowModel>.weakObjects()

    /// tatami.conf の内容。アプリ全体で共有し、起動時と source-file の実行で読み直す
    var config: TatamiConfig {
        TatamiConfigStore.shared.config
    }
    /// prefix キーとコマンドの対応
    var keyBindings: KeyBindingTable {
        config.keyBindings
    }
    /// prefix キーの 2 ストローク検出の状態。status line に prefix 待ちを表示するために公開する
    private(set) var prefixKeyState = PrefixKeyState.idle
    /// 表示中のプロンプト。nil なら通常表示
    private(set) var prompt: Prompt?
    /// rename-window のプロンプトを開いた時点のウィンドウ。プロンプト中にウィンドウを切り替えても、名前はこのウィンドウに付ける
    private var promptTargetWindow: PaneWindow?
    /// プロンプトの入力欄のテキスト
    var promptText = ""
    /// コマンドプロンプトで実行した行の履歴 (古い順)。上下キーで辿る
    private(set) var commandHistory: [String] = []
    /// 履歴を辿っている位置。`commandHistory.count` は「入力中の新しい行」を表す
    private var commandHistoryIndex = 0
    /// 履歴を辿り始める前に入力していたテキスト。末尾まで戻った時に復元する
    private var commandDraft = ""
    /// 直近のページ内検索の語。find モードで n / N がこれを使う
    private(set) var lastFindText = ""
    /// ページ内検索の結果を n / N で辿っている状態。Escape で抜ける
    private(set) var isFindModeActive = false
    /// 履歴の上限。tmux の history-limit に合わせる意図はなく、上下キーで辿れる現実的な量として選んだ
    private static let commandHistoryLimit = 100
    /// 表示中の一覧。nil なら通常表示
    private(set) var chooser: Chooser?
    /// 履歴とブックマーク (アプリ全体で 1 つ)
    private(set) var browsingData = BrowsingStore.loadOrEmpty()
    /// 履歴の保存の debounce タスク
    @ObservationIgnored private var browsingSaveTask: Task<Void, Never>?
    /// アドレスバーの候補で選択中の添字。nil なら未選択 (入力そのものを開く)
    private(set) var addressSuggestionIndex: Int?
    /// 一覧で選択中の添字
    private(set) var chooserSelectionIndex = 0
    /// detach の要求回数。View が onChange で拾って macOS のウィンドウを閉じる
    private(set) var detachRequestCount = 0
    /// status line に出す直近のエラー (保存の失敗など)。次の操作で消える
    private(set) var statusMessage: String?
    /// debounce 中の保存タスク
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// アプリ終了通知の監視
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    /// 画面に表示されて操作の対象になっているかどうか。SwiftUI は @State の初期値を複数回作ることがあり、
    /// 表示されなかったインスタンスが保存を行うと直前の状態を初期状態で上書きしてしまうため、activate() 後だけ保存する
    @ObservationIgnored private var isActive = false
    /// アドレスバーへのフォーカス要求。回数を増やすことで同じ要求を続けて出せる (View 側が onChange で拾う)
    private(set) var addressBarFocusRequestCount = 0
    /// フォーカス中のペインの Web コンテンツを first responder にする要求。アドレスバーからの送信後に使う
    private(set) var webContentFocusRequestCount = 0
    /// フォーカス中のペインの表示状態 (タイトル・進捗・戻る/進む) の更新回数。View がこれを読むことで再描画される
    private(set) var focusedPaneStateVersion = 0

    /// tatami.conf を読んでから、最後に表示していたセッション (無ければ tmux の既定と同じ "0") を復元して始める。読めなければ新規セッション
    init() {
        windows = []
        let name = UserDefaults.standard.string(forKey: BrowserWindowModel.lastSessionNameKey) ?? "0"
        do {
            if let snapshot = try SessionStore.load(name: name) {
                restore(snapshot: snapshot, name: name)
            } else {
                sessionName = name
                windows = [makeWindow()]
            }
        } catch {
            NSLog("セッションの読み込みに失敗 (新規セッションで始める): %@", String(describing: error))
            sessionName = name
            windows = [makeWindow()]
        }
        addressText = currentWindow.focusedPane.url.absoluteString
        statusMessage = TatamiConfigError.statusMessage(errors: TatamiConfigStore.shared.loadErrors)
    }

    /// 画面に表示された時に呼ぶ。以後の変更を保存の対象にし、終了時は debounce を待たずに保存する
    func activate() {
        guard !isActive else {
            return
        }
        isActive = true
        if BrowserWindowModel.openSessionNames.contains(sessionName) {
            // 既に別のウィンドウが開いているセッション (File > New Window で同じ lastSessionName を復元した場合) は、未使用の番号の新しいセッションにする
            let usedNames = BrowserWindowModel.openSessionNames.union(SessionStore.sessionNames())
            sessionName = (0...).lazy.map(String.init).first { !usedNames.contains($0) }!
            windows = [makeWindow()]
            currentWindowIndex = 0
            previousWindowIndex = nil
            syncAddressTextToFocusedPane()
        }
        BrowserWindowModel.openSessionNames.insert(sessionName)
        BrowserWindowModel.activeModels.add(self)
        // ダウンロードはアプリ全体で 1 つの DownloadManager が持つ。表示中のウィンドウの status line に出す
        DownloadManager.shared.onMessage = { [weak self] message in
            self?.statusMessage = message
        }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.saveNow()
            }
        }
    }

    /// macOS のウィンドウが閉じられた時 (閉じるボタン・⌘W) に呼ぶ。保存してセッションを解放し、後から別のウィンドウで開き直せるようにする
    func deactivate() {
        guard isActive else {
            return
        }
        saveNow()
        BrowserWindowModel.openSessionNames.remove(sessionName)
        BrowserWindowModel.activeModels.remove(self)
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        terminationObserver = nil
        isActive = false
    }

    /// 保存用の内容
    var snapshot: SessionSnapshot {
        SessionSnapshot(name: sessionName, windows: windows.map(\.snapshot), currentWindowIndex: currentWindowIndex)
    }

    /// 変更のたびに呼び、少し待ってから保存する。保存の失敗はログに出すだけで操作は止めない
    func scheduleSave() {
        guard isActive else {
            return
        }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: BrowserWindowModel.saveDelay)
            guard !Task.isCancelled, let self else {
                return
            }
            saveNow()
        }
    }

    /// すぐに保存する (detach やウィンドウを閉じる時)。失敗は status line に出し、false を返す
    @discardableResult
    func saveNow() -> Bool {
        guard isActive else {
            return false
        }
        saveTask?.cancel()
        do {
            try SessionStore.save(snapshot: snapshot)
            UserDefaults.standard.set(sessionName, forKey: BrowserWindowModel.lastSessionNameKey)
            return true
        } catch {
            statusMessage = "セッションの保存に失敗: \(error)"
            return false
        }
    }

    /// セッションを保存してウィンドウを閉じる (prefix + d)。保存できなければ閉じずにエラーを表示する
    func detach() {
        guard saveNow() else {
            return
        }
        BrowserWindowModel.openSessionNames.remove(sessionName)
        detachRequestCount += 1
    }

    /// 保存済みのセッションを開く (choose-session の確定)。現在のセッションを保存できなければ切り替えない。
    /// 別のウィンドウが開いているセッションは開かない (同じセッションを 2 つのモデルで持たない)
    func attach(sessionName name: String) {
        guard name != sessionName, !BrowserWindowModel.openSessionNames.contains(name) else {
            return
        }
        guard saveNow() else {
            return
        }
        let loaded: SessionSnapshot
        do {
            guard let snapshot = try SessionStore.load(name: name) else {
                return
            }
            loaded = snapshot
        } catch {
            statusMessage = "セッションの読み込みに失敗: \(error)"
            return
        }
        BrowserWindowModel.openSessionNames.remove(sessionName)
        restore(snapshot: loaded, name: name)
        BrowserWindowModel.openSessionNames.insert(sessionName)
        syncAddressTextToFocusedPane()
        focusedPaneStateVersion += 1
        saveNow()
    }

    /// セッションの名前を変える (prefix + $)。保存ファイルも改名する。使えない名前・同名が既にある・保存できない時は変えずにエラーを表示する
    func renameSession(newName: String) {
        guard newName != sessionName else {
            return
        }
        guard SessionStore.isValidName(newName), !SessionStore.sessionNames().contains(newName),
              !BrowserWindowModel.openSessionNames.contains(newName) else {
            statusMessage = "その名前は使えない: \(newName)"
            return
        }
        guard saveNow() else {
            return
        }
        do {
            try SessionStore.rename(name: sessionName, newName: newName)
        } catch {
            statusMessage = "セッションの改名に失敗: \(error)"
            return
        }
        BrowserWindowModel.openSessionNames.remove(sessionName)
        sessionName = newName
        BrowserWindowModel.openSessionNames.insert(sessionName)
        saveNow()
    }

    /// 要求した名前で復元する。改名直後の終了などでファイル内の name が古いままでも、ファイル名 (= 選んだ名前) を正とする
    private func restore(snapshot: SessionSnapshot, name: String) {
        sessionName = name
        windows = snapshot.windows.map { PaneWindow(snapshot: $0, homeURL: config.homeURL, userAgent: config.userAgent) }
        if windows.isEmpty {
            windows = [makeWindow()]
        }
        for window in windows {
            attachCallbacks(window: window)
        }
        currentWindowIndex = min(max(snapshot.currentWindowIndex, 0), windows.count - 1)
        previousWindowIndex = nil
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

    /// どのウィンドウかを問わず、フォーカス中ペインの URL が変わった回数。automatic-rename の名前は WebPane.url (Observation の対象外) から
    /// 決まるため、これを読む View がバックグラウンドのウィンドウの名前の変化でも再描画されるようにする
    private(set) var windowNamesVersion = 0

    /// status line の左側の表示
    var statusLineText: String {
        _ = windowNamesVersion
        return StatusLine.text(sessionName: sessionName, windowNames: windows.map(\.name), currentWindowIndex: currentWindowIndex)
    }

    /// アドレスバーの入力をフォーカス中のペインで開き、キー入力の宛先を Web コンテンツへ戻す
    func navigate(text: String) {
        currentWindow.focusedPane.load(url: AddressInput.resolve(text: text, searchURL: config.searchURL))
        webContentFocusRequestCount += 1
    }

    /// 描画側から受け取ったペイン領域の大きさを全ウィンドウへ伝える (ポップアップの分割方向の判定に使う)
    func update(containerSize: CGSize) {
        for window in windows {
            window.containerSize = containerSize
        }
    }

    /// 他アプリから渡された URL を、現在のウィンドウの新しいペインで開く
    func open(url: URL) {
        currentWindow.openInNewPane(url: url)
        addressText = url.absoluteString
        focusedPaneStateVersion += 1
        scheduleSave()
    }

    /// Tatami を既定のブラウザにする (`:set-default-browser`)。macOS の確認ダイアログを経て登録され、https を指定すると http も切り替わる。
    /// 結果は status line に出す
    func setAsDefaultBrowser() {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "https") { [weak self] error in
            guard let self else {
                return
            }
            let message = error.map { "既定のブラウザに設定できなかった: \($0.localizedDescription)" } ?? "Tatami を既定のブラウザにした"
            Task { @MainActor in
                self.statusMessage = message
            }
        }
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
        scheduleSave()
    }

    /// 表示中のウィンドウを閉じる (prefix + &)。最後の 1 つを閉じた時は空のウィンドウに置き換え、セッションは残す
    func killCurrentWindow() {
        let closingIndex = currentWindowIndex
        // 閉じるウィンドウが名前変更の対象なら入力先が無くなるためプロンプトを閉じ、一覧は添字がずれるため閉じる
        if promptTargetWindow === currentWindow {
            cancelPrompt()
        }
        chooser = nil
        windows.remove(at: closingIndex)
        if windows.isEmpty {
            windows = [makeWindow()]
        }
        // 直前のウィンドウが生きていれば last-window の戻り先として残し、閉じた位置より後ろなら添字を詰める
        if let previous = previousWindowIndex {
            previousWindowIndex = previous == closingIndex ? nil : (previous > closingIndex ? previous - 1 : previous)
        }
        currentWindowIndex = min(closingIndex, windows.count - 1)
        syncAddressTextToFocusedPane()
    }

    /// rename-window のプロンプトを開く (prefix + ,)。現在の名前を初期値にする
    func beginRenameWindow() {
        promptTargetWindow = currentWindow
        promptText = currentWindow.name
        prompt = .renameWindow
    }

    /// rename-session のプロンプトを開く (prefix + $)
    func beginRenameSession() {
        promptText = sessionName
        prompt = .renameSession
    }

    /// ページ内検索のプロンプトを開く (prefix + [)。前回の語を初期値にする
    func beginFindPrompt() {
        promptText = lastFindText
        prompt = .find
    }

    /// 検索結果を次へ (n) / 前へ (N)
    func findNext(backwards: Bool) {
        guard !lastFindText.isEmpty else {
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        // 末尾の一致から n (先頭から N) でページの反対側へ折り返す (ブラウザと vi の反復検索と同じ)
        configuration.wraps = true
        currentWindow.focusedPane.webView.find(lastFindText, configuration: configuration) { [weak self] result in
            if !result.matchFound {
                self?.statusMessage = "見つからない: \(self?.lastFindText ?? "")"
            }
        }
    }

    /// コマンドプロンプトを開く (prefix + :)
    func beginCommandPrompt() {
        promptText = ""
        commandHistoryIndex = commandHistory.count
        commandDraft = ""
        prompt = .command
    }

    /// コマンドプロンプトで履歴を 1 つ古い方へ辿る (上キー)
    func recallOlderCommand() {
        guard prompt == .command, commandHistoryIndex > 0 else {
            return
        }
        if commandHistoryIndex == commandHistory.count {
            commandDraft = promptText
        }
        commandHistoryIndex -= 1
        promptText = commandHistory[commandHistoryIndex]
    }

    /// コマンドプロンプトで履歴を 1 つ新しい方へ辿る (下キー)。末尾まで戻ると入力中だった行に戻る
    func recallNewerCommand() {
        guard prompt == .command, commandHistoryIndex < commandHistory.count else {
            return
        }
        commandHistoryIndex += 1
        promptText = commandHistoryIndex == commandHistory.count ? commandDraft : commandHistory[commandHistoryIndex]
    }

    /// コマンドプロンプトの 1 行を実行する。キーバインドと同じコマンド表 (BrowserCommand) と、tatami.conf と同じ設定行 (set / bind / unbind / source-file) を使い、
    /// それ以外に `open <url>` と `find <text>` を持つ。未知のコマンドや解釈できない行は status line に表示する
    func execute(commandLine: String) {
        let line = commandLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else {
            return
        }
        commandHistory.append(line)
        if commandHistory.count > BrowserWindowModel.commandHistoryLimit {
            commandHistory.removeFirst(commandHistory.count - BrowserWindowModel.commandHistoryLimit)
        }
        guard let tokens = TatamiConfigParser.tokens(line: line), let name = tokens.first else {
            statusMessage = "command-prompt: クオートが閉じていない"
            return
        }
        let arguments = Array(tokens.dropFirst())
        switch name {
        case "open":
            guard !arguments.isEmpty else {
                statusMessage = "open は URL または検索語を取る"
                return
            }
            let text = arguments.joined(separator: " ")
            addressText = text
            navigate(text: text)
        case "bookmark":
            toggleBookmark()
        case "find":
            lastFindText = arguments.joined(separator: " ")
            isFindModeActive = !lastFindText.isEmpty
            find(text: lastFindText)
        case "source-file" where arguments.isEmpty:
            perform(command: .sourceFile(nil))
        case "set", "bind", "bind-key", "unbind", "unbind-key", "source-file":
            let errors = TatamiConfigStore.shared.apply(line: line)
            applyConfigToAllWindows()
            statusMessage = TatamiConfigError.statusMessage(errors: errors)
        case "rename-window" where !arguments.isEmpty:
            currentWindow.renamedName = arguments.joined(separator: " ")
            scheduleSave()
        case "rename-session" where !arguments.isEmpty:
            renameSession(newName: arguments.joined(separator: " "))
        default:
            guard let command = BrowserCommand(tmuxName: tokens.joined(separator: " ")) else {
                statusMessage = "知らないコマンド: \(line)"
                return
            }
            perform(command: command)
        }
    }

    /// 検索の世代。完了が遅れて届いた古い検索の結果で、後の検索やペイン移動後の status line を上書きしないために数える
    private var findGeneration = 0

    /// ページ内検索 (find)。空文字なら検索の強調を消す。結果が無ければ status line に知らせる
    func find(text: String) {
        let webView = currentWindow.focusedPane.webView
        guard !text.isEmpty else {
            webView.evaluateJavaScript("window.getSelection().removeAllRanges()")
            return
        }
        findGeneration += 1
        let generation = findGeneration
        webView.find(text) { [weak self] result in
            guard let self, generation == findGeneration, !result.matchFound else {
                return
            }
            statusMessage = "見つからない: \(text)"
        }
    }

    /// プロンプトの入力を確定する。rename-window は空文字なら automatic-rename に戻す
    func commitPrompt() {
        switch prompt {
        case .renameWindow:
            (promptTargetWindow ?? currentWindow).renamedName = promptText.isEmpty ? nil : promptText
        case .renameSession:
            renameSession(newName: promptText)
        case .command:
            // 実行するコマンドが次のプロンプト (rename-window 等) を開くことがあるため、先にこのプロンプトを閉じてから実行する
            let commandLine = promptText
            closePrompt()
            execute(commandLine: commandLine)
            scheduleSave()
            return
        case .find:
            lastFindText = promptText
            isFindModeActive = !promptText.isEmpty
            // 入力欄が first responder のままだと検索結果の選択が WKWebView に反映されないため、プロンプトを閉じて Web コンテンツへフォーカスが戻った後に検索する
            let text = promptText
            Task { @MainActor [weak self] in
                self?.find(text: text)
            }
        case nil:
            break
        }
        closePrompt()
        scheduleSave()
    }

    func cancelPrompt() {
        closePrompt()
    }

    /// プロンプトを閉じ、対象への参照を解放し、キー入力の宛先を Web コンテンツへ戻す (消えた入力欄からは自動で戻らない)
    private func closePrompt() {
        prompt = nil
        promptTargetWindow = nil
        webContentFocusRequestCount += 1
    }

    /// ウィンドウ一覧 (prefix + w) を開く
    func beginChooseWindow() {
        chooserSelectionIndex = currentWindowIndex
        chooser = .window
    }

    /// セッション一覧 (prefix + s) を開く。現在のセッションも保存して一覧に含める
    func beginChooseSession() {
        saveNow()
        let names = SessionStore.sessionNames()
        chooserSelectionIndex = names.firstIndex(of: sessionName) ?? 0
        chooser = .session(names)
    }

    /// 一覧に出す項目名
    var chooserItems: [String] {
        switch chooser {
        case .window:
            return windows.map(\.name)
        case .session(let names):
            return names
        case .bookmark:
            return browsingData.bookmarks.map { "\($0.title)  \($0.url.absoluteString)" }
        case nil:
            return []
        }
    }

    /// アドレスバーの入力に対する候補
    var addressSuggestions: [BrowsingData.Suggestion] {
        browsingData.suggestions(prefix: addressText)
    }

    /// 候補を上下キーで選ぶ。nil (未選択) → 0 → … → 末尾 → nil と巡回する
    func moveAddressSuggestion(delta: Int) {
        let count = addressSuggestions.count
        guard count > 0 else {
            addressSuggestionIndex = nil
            return
        }
        switch (addressSuggestionIndex, delta) {
        case (nil, let d) where d > 0:
            addressSuggestionIndex = 0
        case (nil, _):
            addressSuggestionIndex = count - 1
        case (let index?, let d):
            let next = index + d
            addressSuggestionIndex = (0..<count).contains(next) ? next : nil
        }
    }

    /// アドレスバーの入力を開く。候補を選んでいればその URL、そうでなければ入力そのものを解決する
    func submitAddressBar() {
        if let index = addressSuggestionIndex, addressSuggestions.indices.contains(index) {
            let url = addressSuggestions[index].url
            addressText = url.absoluteString
            addressSuggestionIndex = nil
            currentWindow.focusedPane.load(url: url)
            webContentFocusRequestCount += 1
            return
        }
        addressSuggestionIndex = nil
        navigate(text: addressText)
    }

    /// 入力が変わったら候補の選択を解除する
    func addressTextDidChange() {
        addressSuggestionIndex = nil
    }

    /// 表示中のページをブックマークする (`:bookmark`)。既にあれば解除する (トグル)
    func toggleBookmark() {
        let pane = currentWindow.focusedPane
        guard let scheme = pane.url.scheme, scheme == "http" || scheme == "https" else {
            statusMessage = "このページはブックマークできない: \(pane.url.absoluteString)"
            return
        }
        if browsingData.isBookmarked(url: pane.url) {
            browsingData.removeBookmark(url: pane.url)
            statusMessage = "ブックマークを解除した: \(pane.url.absoluteString)"
        } else {
            browsingData.addBookmark(url: pane.url, title: pane.title ?? pane.url.host() ?? pane.url.absoluteString, date: Date())
            statusMessage = "ブックマークした: \(pane.url.absoluteString)"
        }
        scheduleBrowsingSave()
    }

    /// ブックマークの一覧を開く (prefix + b)
    func beginChooseBookmark() {
        chooserSelectionIndex = 0
        chooser = .bookmark
    }

    /// 訪問を履歴に記録する
    private func recordVisit(url: URL, title: String) {
        browsingData.recordVisit(url: url, title: title, date: Date())
        scheduleBrowsingSave()
    }

    /// 履歴・ブックマークの保存。セッションと同じ間隔で debounce する
    private func scheduleBrowsingSave() {
        browsingSaveTask?.cancel()
        browsingSaveTask = Task { [weak self] in
            try? await Task.sleep(for: BrowserWindowModel.saveDelay)
            guard !Task.isCancelled, let self else {
                return
            }
            do {
                try BrowsingStore.save(data: browsingData)
            } catch {
                statusMessage = "履歴の保存に失敗: \(error)"
            }
        }
    }

    /// 一覧のキー操作。一覧を閉じるまで他のキーは消費する
    func handleChooserKey(keyStroke: KeyStroke) {
        let count = chooserItems.count
        switch keyStroke.key {
        case "j", "Down":
            chooserSelectionIndex = (chooserSelectionIndex + 1) % max(count, 1)
        case "k", "Up":
            chooserSelectionIndex = (chooserSelectionIndex - 1 + count) % max(count, 1)
        case "Enter":
            confirmChooser(index: chooserSelectionIndex)
        case "Escape", "q":
            chooser = nil
        case "x" where chooser == .bookmark:
            guard browsingData.bookmarks.indices.contains(chooserSelectionIndex) else {
                return
            }
            browsingData.removeBookmark(url: browsingData.bookmarks[chooserSelectionIndex].url)
            chooserSelectionIndex = min(chooserSelectionIndex, max(browsingData.bookmarks.count - 1, 0))
            scheduleBrowsingSave()
            if browsingData.bookmarks.isEmpty {
                chooser = nil
            }
        default:
            if let number = Int(keyStroke.key), number < count {
                confirmChooser(index: number)
            }
        }
    }

    private func confirmChooser(index: Int) {
        let selected = chooser
        chooser = nil
        switch selected {
        case .window:
            select(windowIndex: index)
        case .session(let names):
            guard names.indices.contains(index) else {
                return
            }
            attach(sessionName: names[index])
        case .bookmark:
            guard browsingData.bookmarks.indices.contains(index) else {
                return
            }
            let url = browsingData.bookmarks[index].url
            addressText = url.absoluteString
            currentWindow.focusedPane.load(url: url)
        case nil:
            break
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
        if chooser != nil {
            handleChooserKey(keyStroke: keyStroke)
            return true
        }
        // find モード: n / N で次 / 前へ、Escape で抜ける。それ以外のキー (prefix を含む) は通常どおり扱う
        if isFindModeActive, prompt == nil, prefixKeyState == .idle, keyStroke.modifiers.isEmpty {
            switch keyStroke.key {
            case "n":
                findNext(backwards: false)
                return true
            case "N":
                findNext(backwards: true)
                return true
            case "Escape":
                isFindModeActive = false
                find(text: "")
                return true
            default:
                break
            }
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

    /// キーバインド・メニュー (と後続のコマンドプロンプト) から呼ばれる操作の入口。状態が変わる操作はここを通るので、保存の予約もここで行う
    func perform(command: BrowserCommand) {
        statusMessage = nil
        defer {
            scheduleSave()
        }
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
        case .detachClient:
            detach()
        case .chooseSession:
            beginChooseSession()
        case .renameSession:
            beginRenameSession()
        case .commandPrompt:
            beginCommandPrompt()
        case .findPrompt:
            beginFindPrompt()
        case .setDefaultBrowser:
            setAsDefaultBrowser()
        case .chooseBookmark:
            beginChooseBookmark()
        case .sourceFile(let path):
            reload(configFileURL: path.map { TatamiConfigLoader.fileURL(path: $0) } ?? TatamiConfigLoader.defaultFileURL, requireFile: path != nil)
        }
    }

    /// tatami.conf を読み直して設定を差し替える (source-file)。解釈できなかった行は飛ばし、読めた分だけを反映して status line に知らせる。
    /// 設定はアプリ全体で共有しているため、開いている全ウィンドウのペインへ反映する
    private func reload(configFileURL: URL, requireFile: Bool) {
        let errors = TatamiConfigStore.shared.reload(fileURL: configFileURL, requireFile: requireFile)
        applyConfigToAllWindows()
        statusMessage = TatamiConfigError.statusMessage(errors: errors)
    }

    /// 共有の設定を、表示中の全ウィンドウのペインへ反映する
    private func applyConfigToAllWindows() {
        for model in BrowserWindowModel.activeModels.allObjects {
            for window in model.windows {
                window.apply(homeURL: model.config.homeURL, userAgent: model.config.userAgent)
            }
        }
    }

    private func makeWindow() -> PaneWindow {
        let window = PaneWindow(homeURL: config.homeURL, userAgent: config.userAgent)
        attachCallbacks(window: window)
        return window
    }

    private func attachCallbacks(window: PaneWindow) {
        window.onFocusedURLChange = { [weak self, weak window] navigatedURL in
            guard let self, let window else {
                return
            }
            windowNamesVersion += 1
            guard currentWindow === window else {
                return
            }
            addressText = navigatedURL.absoluteString
            focusedPaneStateVersion += 1
            scheduleSave()
        }
        window.onContentChange = { [weak self] in
            self?.scheduleSave()
        }
        window.onVisit = { [weak self] url, title in
            self?.recordVisit(url: url, title: title)
        }
        window.onFocusedPaneStateChange = { [weak self, weak window] in
            guard let self, let window, currentWindow === window else {
                return
            }
            focusedPaneStateVersion += 1
        }
    }

    private func syncAddressTextToFocusedPane() {
        addressText = currentWindow.focusedPane.url.absoluteString
    }
}
