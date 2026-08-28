import AppKit
import Foundation
import Observation

/// macOS のウィンドウ 1 つ分 (tmux の session に相当) の状態。複数の PaneWindow (tmux の window) と現在のウィンドウ、
/// アドレスバー・キーバインド・status line のプロンプトを持ち、メニューとキーバインドの宛先になる
@MainActor
@Observable
final class BrowserWindowModel {
    /// status line のプロンプト (tmux の command-prompt 相当)。rename-window / rename-session の入力に使う
    enum Prompt: Equatable {
        case renameWindow
        case renameSession
    }

    /// 一覧から選ぶ操作 (choose-window / choose-session)。表示中は j / k / 数字 / Enter / Escape をこの一覧の操作に使う
    enum Chooser: Equatable {
        case window
        /// 保存済みセッションの名前一覧
        case session([String])
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
    /// prefix キーとコマンドの対応。tatami.conf (#7) の読み込みで差し替える
    var keyBindings = KeyBindingTable.default
    /// prefix キーの 2 ストローク検出の状態。status line に prefix 待ちを表示するために公開する
    private(set) var prefixKeyState = PrefixKeyState.idle
    /// 表示中のプロンプト。nil なら通常表示
    private(set) var prompt: Prompt?
    /// rename-window のプロンプトを開いた時点のウィンドウ。プロンプト中にウィンドウを切り替えても、名前はこのウィンドウに付ける
    private var promptTargetWindow: PaneWindow?
    /// プロンプトの入力欄のテキスト
    var promptText = ""
    /// 表示中の一覧。nil なら通常表示
    private(set) var chooser: Chooser?
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

    /// 最後に表示していたセッション (無ければ tmux の既定と同じ "0") を復元して始める。読めなければ新規セッション
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
        windows = snapshot.windows.map { PaneWindow(snapshot: $0) }
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
        currentWindow.focusedPane.load(url: AddressInput.resolve(text: text))
        webContentFocusRequestCount += 1
    }

    /// 描画側から受け取ったペイン領域の大きさを全ウィンドウへ伝える (ポップアップの分割方向の判定に使う)
    func update(containerSize: CGSize) {
        for window in windows {
            window.containerSize = containerSize
        }
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

    /// プロンプトの入力を確定する。rename-window は空文字なら automatic-rename に戻す
    func commitPrompt() {
        switch prompt {
        case .renameWindow:
            (promptTargetWindow ?? currentWindow).renamedName = promptText.isEmpty ? nil : promptText
        case .renameSession:
            renameSession(newName: promptText)
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
        case nil:
            return []
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
        handle(keyStrokes: [keyStroke])
    }

    /// ウィンドウがキーウィンドウでなくなった時に prefix 待ちを取り消す (戻った後の最初のキーをコマンドとして消費しないため)
    func cancelPrefix() {
        prefixKeyState = prefixKeyState.cancelled
    }

    /// 1 つのキー入力の候補 (KeyStroke.candidates) をまとめて渡す。一覧やプロンプトのキー操作は主な解釈 (先頭の候補) で行う
    func handle(keyStrokes: [KeyStroke]) -> Bool {
        guard let keyStroke = keyStrokes.first else {
            return false
        }
        if chooser != nil {
            handleChooserKey(keyStroke: keyStroke)
            return true
        }
        let handled = prefixKeyState.handling(keyStrokes: keyStrokes, table: keyBindings)
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
        }
    }

    private func makeWindow() -> PaneWindow {
        let window = PaneWindow()
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
