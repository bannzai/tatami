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
        /// 表示中のページに合う資格情報の一覧 (パスワードの後に Passkey)。パスワードを選ぶと候補を作ったペインへ充填する
        /// (充填時にそのペインの URL と再照合する)。Passkey はサイトのサインインボタンから使うため、選んでもその案内を出すだけ
        case credential([Credential], passkeys: [Passkey], pane: WebPane)
    }

    /// 最後に表示していたセッション名の保存先。次回起動時にこのセッションを復元する
    private static let lastSessionNameKey = "lastSessionName"
    /// 復元したペインの読み込みを activate() まで遅らせている間 true。表示されないモデル (重複セッションの判定で捨てられる等) が通信を始めないようにする
    private var hasPendingRestoredLoad = false
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
    /// Web コンテンツへフォーカスが移るのを待っている検索語 (find プロンプトの確定で設定し、webContentDidFocus で実行する)
    private var pendingFindText: String?
    /// 履歴の上限。tmux の history-limit に合わせる意図はなく、上下キーで辿れる現実的な量として選んだ
    private static let commandHistoryLimit = 100
    /// 表示中の一覧。nil なら通常表示
    private(set) var chooser: Chooser?
    /// status line に出す提案 (y で承認・n / Escape で却下)
    enum Proposal: Equatable {
        /// 未保存の資格情報を保存する
        case save(url: URL, username: String, password: String)
        /// 既存の資格情報のパスワードを更新する
        case update(credential: Credential, password: String)
        /// サインアップ用のパスワード欄に強いパスワードを生成して入れる
        case generatePassword

        var text: String {
            switch self {
            case .save(let url, let username, _):
                return "\(url.host() ?? "") の \(username.isEmpty ? "(ユーザー名なし)" : username) のパスワードを保存する? (y/n)"
            case .update(let credential, _):
                return "\(credential.host) の \(credential.username) のパスワードを更新する? (y/n)"
            case .generatePassword:
                return "強いパスワードを生成して入れる? (y/n)"
            }
        }
    }

    /// 表示中の提案。nil なら無し
    private(set) var proposal: Proposal?
    /// 提案の対象ペイン。生成したパスワードの充填先になる
    private var proposalPane: WebPane?
    /// 提案を出した時のペインの URL。別のページへ移った後に承認しても、そのページへ充填・保存しない
    private var proposalURL: URL?
    /// 生成提案を出した時点の文書の世代。同じ URL の別文書 (再読み込み・DOM の置換) へ生成値を入れないために持つ
    private var proposalGeneration: Int?
    /// 履歴とブックマーク (アプリ全体で 1 つの BrowsingDataStore を参照する)
    var browsingData: BrowsingData {
        BrowsingDataStore.shared.data
    }
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
    /// 未保存の変更を最初に予約した時刻。maxSaveDelay の判定に使い、保存で nil に戻す
    @ObservationIgnored private var firstScheduledAt: ContinuousClock.Instant?
    /// 変更が続いても保存を待たせる上限。クラッシュ時に失う操作を数秒分に抑える値として選んだ
    private static let maxSaveDelay: Duration = .seconds(5)
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

    /// 資格情報の保存先。既定は Keychain で、ユニットテストからはメモリ実装に差し替える。
    /// Debug と Release で Keychain の領域が分かれる扱いは KeychainCredentialStore.sharedAccessGroup が持つ
    @ObservationIgnored private let credentialStore: any CredentialStore
    /// 資格情報のロック状態。充填・一覧・エクスポートの前に本人確認を求める。既定はアプリ全体で共有する 1 つの状態
    @ObservationIgnored private let credentialLock: CredentialLock
    /// アプリのアクティブ化の購読 (自動入力候補の再同期用。deactivate で解除する)
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    /// ロック通知の購読 (deactivate で解除する)
    @ObservationIgnored private var lockObservation: (any NSObjectProtocol)?

    /// tatami.conf を読んでから、最後に表示していたセッション (無ければ tmux の既定と同じ "0") を復元して始める。読めなければ新規セッション。
    /// credentialStore の既定 (Keychain) を引数の既定値ではなく本体で作るのは、既定値の式が nonisolated な文脈で評価され、
    /// @MainActor の KeychainCredentialStore を呼べないため
    init(credentialStore: (any CredentialStore)? = nil, credentialLock: CredentialLock? = nil) {
        // credentialStore と同じ理由で、共有のロック状態も本体で解決する
        self.credentialLock = credentialLock ?? CredentialLock.shared
        #if DEBUG
        // 開発中の動作確認で本物の Keychain (iCloud 同期) にダミーの資格情報を書かないための切り替え。
        // `defaults write com.bannzai.Tatami TatamiUseInMemoryCredentialStore -bool YES` で有効になる (Debug ビルドのみ)
        let debugStore: (any CredentialStore)? = UserDefaults.standard.bool(forKey: "TatamiUseInMemoryCredentialStore") ? InMemoryCredentialStore() : nil
        self.credentialStore = credentialStore ?? debugStore ?? KeychainCredentialStore()
        #else
        self.credentialStore = credentialStore ?? KeychainCredentialStore()
        #endif
        windows = []
        // 旧版や壊れた defaults で無効な名前 (`../work` 等) が残っていると以後の保存が全て失敗するため、有効な名前へ戻す
        let storedName = UserDefaults.standard.string(forKey: BrowserWindowModel.lastSessionNameKey) ?? "0"
        let name = SessionStore.isValidName(storedName) ? storedName : "0"
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
        self.credentialLock.apply(lockTimeout: config.lockTimeout)
    }

    /// 画面に表示された時に呼ぶ。以後の変更を保存の対象にし、終了時は debounce を待たずに保存する
    func activate() {
        guard !isActive else {
            return
        }
        isActive = true
        // 拡張が充填する候補は OS 側に保持されるため、起動時と、別の Mac からの iCloud 同期を受けた可能性があるアクティブ化のたびに
        // ストアの内容と揃える
        syncCredentialIdentities()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncCredentialIdentities()
            }
        }
        // ロックされたら、本人確認後にだけ見せる候補一覧を閉じる (別ウィンドウの :lock や自動ロックでも)。
        // init では stored property の初期化が終わる前に self を捕捉できないため、ここで購読する
        lockObservation = NotificationCenter.default.addObserver(forName: CredentialLock.didLockNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closeCredentialChooserIfLocked()
            }
        }
        if BrowserWindowModel.openSessionNames.contains(sessionName) {
            // 既に別のウィンドウが開いているセッション (File > New Window で同じ lastSessionName を復元した場合) は、未使用の番号の新しいセッションにする
            // 一覧が読めない (権限・I/O エラー) 時に既存の番号を選んで上書きしないよう、候補ごとにファイルの非存在も確認する
            let usedNames = BrowserWindowModel.openSessionNames.union((try? SessionStore.sessionNames()) ?? [])
            sessionName = (0...).lazy.map(String.init).first { !usedNames.contains($0) && !SessionStore.fileExists(name: $0) }!
            windows = [makeWindow()]
            currentWindowIndex = 0
            previousWindowIndex = nil
            syncAddressTextToFocusedPane()
        }
        BrowserWindowModel.openSessionNames.insert(sessionName)
        BrowserWindowModel.activeModels.add(self)
        // ダウンロードはアプリ全体で 1 つの DownloadManager が持ち、表示中の全ウィンドウの status line に出す
        DownloadManager.shared.subscribe(model: self)
        if hasPendingRestoredLoad {
            hasPendingRestoredLoad = false
            for window in windows {
                window.loadRestoredPanes()
            }
        }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.saveNow()
                BrowsingDataStore.shared.saveNow()
            }
        }
    }

    /// macOS のウィンドウが閉じられた時 (閉じるボタン・⌘W) に呼ぶ。保存してセッションを解放し、後から別のウィンドウで開き直せるようにする
    func deactivate() {
        guard isActive else {
            return
        }
        saveNow()
        BrowsingDataStore.shared.saveNow()
        BrowserWindowModel.openSessionNames.remove(sessionName)
        BrowserWindowModel.activeModels.remove(self)
        DownloadManager.shared.unsubscribe(model: self)
        if let lockObservation {
            NotificationCenter.default.removeObserver(lockObservation)
            self.lockObservation = nil
        }
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
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
        // 連続する変更 (replaceState を繰り返すページ等) で debounce が延び続けても、最大待ち時間を超えたら保存する
        let now = ContinuousClock.now
        if let firstScheduledAt, now - firstScheduledAt >= BrowserWindowModel.maxSaveDelay {
            saveNow()
            return
        }
        if firstScheduledAt == nil {
            firstScheduledAt = now
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

    /// ダウンロードの進捗などを status line に出す (DownloadManager から)
    func showDownloadMessage(_ message: String) {
        statusMessage = message
    }

    /// すぐに保存する (detach やウィンドウを閉じる時)。失敗は status line に出し、false を返す
    @discardableResult
    func saveNow() -> Bool {
        guard isActive else {
            return false
        }
        saveTask?.cancel()
        firstScheduledAt = nil
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
        hasPendingRestoredLoad = false
        for window in windows {
            window.loadRestoredPanes()
        }
        syncAddressTextToFocusedPane()
        focusedPaneStateVersion += 1
        saveNow()
    }

    /// セッションの名前を変える (prefix + $)。保存ファイルも改名する。使えない名前・同名が既にある・保存できない時は変えずにエラーを表示する
    func renameSession(newName: String) {
        guard newName != sessionName else {
            return
        }
        let existingNames: [String]
        do {
            existingNames = try SessionStore.sessionNames()
        } catch {
            statusMessage = "セッション一覧を読めない: \(error)"
            return
        }
        guard SessionStore.isValidName(newName), !existingNames.contains(newName),
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
        // ファイルは改名済みのため、この保存に失敗しても次回起動が新しい名前を復元できるよう復元先の名前だけは更新する
        if !saveNow() {
            UserDefaults.standard.set(sessionName, forKey: BrowserWindowModel.lastSessionNameKey)
        }
    }

    /// 要求した名前で復元する。改名直後の終了などでファイル内の name が古いままでも、ファイル名 (= 選んだ名前) を正とする
    private func restore(snapshot: SessionSnapshot, name: String) {
        sessionName = name
        windows = snapshot.windows.map { PaneWindow(snapshot: $0, homeURL: config.homeURL, userAgent: config.userAgent) }
        hasPendingRestoredLoad = !windows.isEmpty
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

    /// アドレスバーへフォーカスを移す (prefix + /)。一覧やプロンプトが開いていると通常のキーがそちらへ吸われるため先に閉じる
    func focusAddressBar() {
        chooser = nil
        cancelPrompt()
        cancelPrefix()
        addressBarFocusRequestCount += 1
    }

    func goBack() {
        currentWindow.focusedPane.webView.goBack()
    }

    func goForward() {
        currentWindow.focusedPane.webView.goForward()
    }

    func reload() {
        currentWindow.focusedPane.reload()
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
        // 非表示のウィンドウで検出した登録フォームの生成提案は、表示された時に出す
        evaluateNewPasswordProposal()
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
        // 表示されたウィンドウで検出済みの登録フォームの生成提案を出す (select(windowIndex:) と同じ)
        evaluateNewPasswordProposal()
    }

    /// rename-window のプロンプトを開く (prefix + ,)。現在の名前を初期値にする
    func beginRenameWindow() {
        // メニューから開いた時に prefix 待ちや一覧が残っていると、名前の最初の文字がコマンドや一覧の操作として消費されるため取り消す
        cancelPrefix()
        chooser = nil
        promptTargetWindow = currentWindow
        promptText = currentWindow.name
        prompt = .renameWindow
    }

    /// rename-session のプロンプトを開く (prefix + $)
    func beginRenameSession() {
        cancelPrefix()
        chooser = nil
        promptText = sessionName
        prompt = .renameSession
    }

    /// ページ内検索のプロンプトを開く (prefix + [)。前回の語を初期値にする
    func beginFindPrompt() {
        cancelPrefix()
        chooser = nil
        promptText = lastFindText
        prompt = .find
    }

    /// アドレスバーを編集中かどうか。View がフォーカス状態から設定する。編集中は find モードの n / N / Escape を消費しない
    var isAddressBarEditing = false

    /// 検索結果を次へ (n) / 前へ (N)
    func findNext(backwards: Bool) {
        guard !lastFindText.isEmpty else {
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        // 末尾の一致から n (先頭から N) でページの反対側へ折り返す (ブラウザと vi の反復検索と同じ)
        configuration.wraps = true
        findGeneration += 1
        let generation = findGeneration
        let text = lastFindText
        let webView = currentWindow.focusedPane.webView
        webView.find(text, configuration: configuration) { [weak self, weak webView] result in
            // 完了までに find モードを抜けた・別の語で検索した・ペインが移った場合は古い結果を捨てる
            guard let self, generation == findGeneration, let webView, currentWindow.focusedPane.webView === webView, !result.matchFound else {
                return
            }
            statusMessage = "見つからない: \(text)"
        }
    }

    /// コマンドプロンプトを開く (prefix + :)
    func beginCommandPrompt() {
        // prefix 待ちや一覧が残っていると最初の文字がそちらに消費されるため、コマンドプロンプトを排他的な入力状態にする
        cancelPrefix()
        chooser = nil
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
    /// それ以外に `open <url>`・`find <text>`・`import-passwords <path>`・`export-passwords <path>` を持つ。
    /// 未知のコマンドや解釈できない行は status line に表示する
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
        case "generate-password":
            generatePassword()
        case "find":
            lastFindText = arguments.joined(separator: " ")
            isFindModeActive = !lastFindText.isEmpty
            // find プロンプトと同じく、コマンドプロンプトを閉じて Web コンテンツへフォーカスが移った後に検索する
            pendingFindText = lastFindText
        case "import-passwords":
            guard !arguments.isEmpty else {
                statusMessage = "import-passwords は CSV のパスを取る"
                return
            }
            importPasswords(path: arguments.joined(separator: " "))
        case "export-passwords":
            guard !arguments.isEmpty else {
                statusMessage = "export-passwords は CSV のパスを取る"
                return
            }
            let path = arguments.joined(separator: " ")
            withUnlockedCredentials(reason: "資格情報を CSV に書き出す") { [weak self] in
                self?.exportPasswords(path: path)
            }
        case "export-cxf":
            guard !arguments.isEmpty else {
                statusMessage = "export-cxf は ZIP のパスを取る"
                return
            }
            let path = arguments.joined(separator: " ")
            withUnlockedCredentials(reason: "資格情報と Passkey を CXF に書き出す") { [weak self] in
                self?.exportCXF(path: path)
            }
        case "import-cxf":
            guard !arguments.isEmpty else {
                statusMessage = "import-cxf は ZIP (または index.json) のパスを取る"
                return
            }
            importCXF(path: arguments.joined(separator: " "))
        case "lock":
            credentialLock.lock()
            statusMessage = "資格情報をロックした"
        case "source-file":
            // キーバインドからの実行と同じ経路 (既定値から読み直して差し替える)。引数なしは既定ファイル
            perform(command: .sourceFile(arguments.isEmpty ? nil : arguments.joined(separator: " ")))
        case "set", "bind", "bind-key", "unbind", "unbind-key":
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

    /// コマンドの引数のパスを解決する。`~` を展開し、相対パスは GUI アプリのカレントディレクトリ (利用者から見えず不安定) ではなく
    /// ホームディレクトリを基準にする
    static func commandFileURL(path: String) -> URL {
        URL(filePath: TatamiConfigParser.expandedPath(path: path), directoryHint: .notDirectory, relativeTo: FileManager.default.homeDirectoryForCurrentUser).absoluteURL
    }

    /// FIDO Credential Exchange Format (ZIP) に資格情報とソフトウェア鍵の Passkey を書き出す。平文のため既存ファイルには書かない (CSV と同じ)
    private func exportCXF(path: String) {
        let fileURL = BrowserWindowModel.commandFileURL(path: path)
        let filePath = fileURL.path(percentEncoded: false)
        guard !FileManager.default.fileExists(atPath: filePath) else {
            statusMessage = "エクスポート: すでにファイルがある: \(filePath)"
            return
        }
        do {
            let exported = try CXF.exportArchive(credentials: try credentialStore.all(), passkeys: try PasskeyManager.store.all(), exporter: "Tatami", now: Date())
            let descriptor = Darwin.open(filePath, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: exported.data)
                try handle.close()
            } catch {
                // 書きかけの平文ファイルを残さない (残すと次回の書き出しも「すでにファイルがある」で止まる)
                try? FileManager.default.removeItem(at: fileURL)
                throw error
            }
            let skipped = exported.result.skippedSecureEnclavePasskeys > 0 ? "・Secure Enclave の Passkey \(exported.result.skippedSecureEnclavePasskeys) 件は書き出せない" : ""
            statusMessage = "CXF に書き出した: 資格情報 \(exported.result.credentials) 件・Passkey \(exported.result.passkeys) 件\(skipped): \(filePath)"
        } catch {
            statusMessage = "エクスポートに失敗: \(error)"
        }
    }

    /// CXF を読み、資格情報 (CSV と同じ突き合わせ) と Passkey (同じ rpId・credentialId が無ければ追加) を取り込む
    private func importCXF(path: String) {
        var savedCredentials = 0
        var savedPasskeys = 0
        // 途中で失敗しても確定済みの資格情報は OS の自動入力候補に反映する
        defer {
            if savedCredentials > 0 {
                syncCredentialIdentities()
            }
        }
        do {
            let imported = try CXF.importArchive(data: try Data(contentsOf: BrowserWindowModel.commandFileURL(path: path)), now: Date())
            let existing = try credentialStore.all()
            // CXF にメモは無いため note を nil (既存のメモを保つ) にして CSV と同じ突き合わせにかける
            let rows = imported.credentials.map { PasswordCSV.Row(name: $0.host, url: $0.url.absoluteString, username: $0.username, password: $0.password, note: nil) }
            let merged = PasswordImporter.merge(rows: rows, existing: existing, now: Date())
            let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var seenIDs = Set<UUID>()
            for credential in merged.credentials where seenIDs.insert(credential.id).inserted && existingByID[credential.id] != credential {
                try credentialStore.save(credential: credential)
                savedCredentials += 1
            }
            // 同じアーカイブ内の重複も 1 件だけにする
            var knownPasskeys = Set(try PasskeyManager.store.all().map { "\($0.rpId)\n\(WebAuthn.base64url($0.credentialID))" })
            for passkey in imported.passkeys where knownPasskeys.insert("\(passkey.rpId)\n\(WebAuthn.base64url(passkey.credentialID))").inserted {
                try PasskeyManager.store.save(passkey: passkey)
                savedPasskeys += 1
            }
            statusMessage = "CXF を取り込んだ: 資格情報 追加 \(merged.added)・更新 \(merged.updated)・変更なし \(merged.unchanged)・Passkey 追加 \(savedPasskeys)・読み飛ばし \(imported.skipped + merged.skipped)"
        } catch {
            statusMessage = "インポートに失敗 (資格情報 \(savedCredentials) 件・Passkey \(savedPasskeys) 件は保存済み): \(error)"
        }
    }

    /// Chrome 互換 CSV を読み、既存の資格情報に取り込む。同じファイルを何度取り込んでも重複しない (PasswordImporter.merge が冪等)
    private func importPasswords(path: String) {
        let fileURL = BrowserWindowModel.commandFileURL(path: path)
        do {
            let existing = try credentialStore.all()
            let result = PasswordImporter.merge(
                rows: try PasswordCSV.parse(text: String(contentsOf: fileURL, encoding: .utf8)),
                existing: existing,
                now: Date()
            )
            // id は資格情報ごとに一意だが、万一重複しても落ちないよう先に現れた側を残す
            let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // 保存対象も id ごとに先頭の 1 件に限る (同じ id の後続要素で更新済みの項目を戻さない)
            var seenIDs = Set<UUID>()
            let changed = result.credentials.filter { seenIDs.insert($0.id).inserted && existingByID[$0.id] != $0 }
            var saved = 0
            for credential in changed {
                do {
                    try credentialStore.save(credential: credential)
                    saved += 1
                } catch {
                    // Keychain への保存は 1 件ずつ確定するためロールバックできない。途中まで反映したことを件数で明示する
                    statusMessage = "インポートを途中で中断: \(saved)/\(changed.count) 件を保存した後に失敗: \(error)"
                    // 確定済みの分は OS の候補にも反映する (1 件ごとではなく最後に 1 回)
                    syncCredentialIdentities()
                    return
                }
            }
            statusMessage = "インポート: 追加 \(result.added)・更新 \(result.updated)・変更なし \(result.unchanged)・読み飛ばし \(result.skipped)"
            if saved > 0 {
                syncCredentialIdentities()
            }
        } catch {
            statusMessage = "インポートに失敗: \(error)"
        }
    }

    /// 資格情報を Chrome 互換 CSV に書き出す。書き出したファイルは平文のため、既存のファイルには追記も上書きもせずエラーにする
    private func exportPasswords(path: String) {
        let fileURL = BrowserWindowModel.commandFileURL(path: path)
        let filePath = fileURL.path(percentEncoded: false)
        guard !FileManager.default.fileExists(atPath: filePath) else {
            statusMessage = "エクスポート: すでにファイルがある: \(filePath)"
            return
        }
        do {
            let exportable = PasswordImporter.exportable(credentials: try credentialStore.all())
            let credentials = exportable.rows
            let text = PasswordCSV.serialize(rows: PasswordImporter.rows(credentials: credentials))
            // 事前確認から書き込みまでの間に他のプロセスが同じパスを作っても上書きしないよう排他的に新規作成し、
            // 作成時点から本人だけが読める権限 (0600) にする (後から権限を落とすと、その間に開かれたディスクリプタから読めてしまう)
            let descriptor = Darwin.open(filePath, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: Data(text.utf8))
                try handle.close()
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                throw error
            }
            let excludedNote = exportable.excluded > 0 ? "・ホストの無い URL の \(exportable.excluded) 件は対象外" : ""
            statusMessage = "エクスポート: \(filePath) に \(credentials.count) 件\(excludedNote)。このファイルは削除するまで平文で残る"
        } catch {
            statusMessage = "エクスポートに失敗: \(error)"
        }
    }

    /// 検索の世代。完了が遅れて届いた古い検索の結果で、後の検索やペイン移動後の status line を上書きしないために数える
    private var findGeneration = 0

    /// ページ内検索 (find)。空文字なら検索の強調を消す。結果が無ければ status line に知らせる
    func find(text: String) {
        let webView = currentWindow.focusedPane.webView
        // 空文字は検索の解除。保留中の検索の完了で古い結果を表示しないよう世代も進める
        findGeneration += 1
        guard !text.isEmpty else {
            webView.evaluateJavaScript("window.getSelection().removeAllRanges()")
            return
        }
        let generation = findGeneration
        webView.find(text) { [weak self, weak webView] result in
            // 完了までにペインやウィンドウが移っていたら、古い WebView の結果で status line を更新しない
            guard let self, generation == findGeneration, let webView, currentWindow.focusedPane.webView === webView, !result.matchFound else {
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
            closePrompt(refocusWebContent: false)
            execute(commandLine: commandLine)
            // 実行したコマンドが次のプロンプトを開いた時はそちらへ入力を残し、開かなかった時だけ Web コンテンツへフォーカスを戻す
            if prompt == nil {
                webContentFocusRequestCount += 1
            }
            scheduleSave()
            return
        case .find:
            lastFindText = promptText
            isFindModeActive = !promptText.isEmpty
            // 入力欄が first responder のままだと検索結果の選択が WKWebView に反映されないため、プロンプトを閉じて
            // Web コンテンツへフォーカスが実際に移った後 (webContentDidFocus) に検索する
            pendingFindText = promptText
        case nil:
            break
        }
        closePrompt()
        scheduleSave()
    }

    func cancelPrompt() {
        guard prompt != nil else {
            return
        }
        closePrompt()
    }

    /// PaneContainer が Web コンテンツを first responder にした直後に呼ばれる。フォーカス待ちの検索をここで実行する
    func webContentDidFocus() {
        guard let text = pendingFindText else {
            return
        }
        pendingFindText = nil
        // SwiftUI の更新中に状態を変えないよう、次のターンで検索する (フォーカス自体は既に移っている)
        Task { @MainActor [weak self] in
            self?.find(text: text)
        }
    }

    /// プロンプトを閉じ、対象への参照を解放し、キー入力の宛先を Web コンテンツへ戻す (消えた入力欄からは自動で戻らない)
    private func closePrompt(refocusWebContent: Bool = true) {
        prompt = nil
        promptTargetWindow = nil
        if refocusWebContent {
            webContentFocusRequestCount += 1
        }
    }

    /// ウィンドウ一覧 (prefix + w) を開く
    func beginChooseWindow() {
        // 一覧と名前変更のプロンプトは排他にする (両方が開くと入力の宛先が曖昧になる)
        cancelPrompt()
        cancelPrefix()
        chooserSelectionIndex = currentWindowIndex
        chooser = .window
    }

    /// セッション一覧 (prefix + s) を開く。現在のセッションも保存して一覧に含める
    func beginChooseSession() {
        cancelPrompt()
        cancelPrefix()
        saveNow()
        let names: [String]
        do {
            names = try SessionStore.sessionNames()
        } catch {
            statusMessage = "セッション一覧を読めない: \(error)"
            return
        }
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
        case .credential(let credentials, let passkeys, _):
            return credentials.map { "\($0.username)  \($0.host)" } + passkeys.map { "\($0.userName)  \($0.rpId)  (Passkey)" }
        case nil:
            return []
        }
    }

    /// ログインフォームの送信を受けて、保存・更新の提案を出す。同じ内容が保存済みなら何もしない
    private func handleLoginSubmit(pane: WebPane, frameURL: URL, username: String, password: String, currentPassword: String, isNewPassword: Bool) {
        guard WebPane.isWebPage(url: frameURL), let host = CredentialMatcher.host(url: frameURL), !host.isEmpty else {
            return
        }
        let existing: [Credential]
        do {
            // 更新対象は同じオリジン (scheme・host・ポート) の項目に限る (http 用や別ポート用の項目を上書きしない)。
            // ホストは IDNA の ASCII 形で照合する (Unicode 表記で保存した項目と punycode で届くフレームの URL を同じホストとして扱う)
            existing = try credentialStore.all().filter {
                CredentialMatcher.host(url: $0.url) == host && $0.url.scheme?.lowercased() == frameURL.scheme?.lowercased()
                    && CredentialMatcher.matches(credentialURL: $0.url, pageURL: frameURL)
            }
        } catch {
            statusMessage = "資格情報を読めない: \(error)"
            return
        }
        // ユーザー名の無い変更フォーム (現在・新規・確認だけ) では、現在のパスワードが一致する既存の項目を更新対象にする。
        // 同じ現在のパスワードを使う項目が複数あればどのアカウントか判別できないため、更新を提案しない (誤った項目を上書きしない)
        let byCurrentPassword = username.isEmpty && !currentPassword.isEmpty
            ? existing.filter { $0.password.unicodeScalars.elementsEqual(currentPassword.unicodeScalars) }
            : []
        // ユーザー名も正規化形だけが違う値を別アカウントとして扱う (PasswordImporter.matchKey と同じ) ため、スカラー値で比較する
        // ユーザー名が空の送信では、変更フォーム (isNewPassword) なら現在のパスワードが一意に一致する項目だけを使い、
        // 通常のパスワード専用ログインならユーザー名の無い項目が 1 件だけあればそれを照合する (正しいパスワードの再送信で重複保存しない)
        let unnamed = existing.filter(\.username.isEmpty)
        let matched = username.isEmpty
            ? (isNewPassword ? (byCurrentPassword.count == 1 ? byCurrentPassword[0] : nil) : (unnamed.count == 1 ? unnamed[0] : nil))
            : existing.first(where: { $0.username.unicodeScalars.elementsEqual(username.unicodeScalars) })
        if username.isEmpty, byCurrentPassword.count > 1 {
            statusMessage = "現在のパスワードが同じ項目が複数あるため更新を提案しない"
            return
        }
        if let same = matched {
            // 正規化形だけが違う値は別のパスワードとして扱う (サーバーが受け取るバイト列が異なる) ため、スカラー値で比較する
            guard !same.password.unicodeScalars.elementsEqual(password.unicodeScalars) else {
                // 保存済みの正しいパスワードで送り直した時は、その前の誤ったパスワードの提案を残さない
                if proposalPane === pane {
                    dismissProposal()
                }
                return
            }
            proposalPane = pane
            proposalURL = pane.url
            proposal = .update(credential: same, password: password)
        } else {
            proposalPane = pane
            proposalURL = pane.url
            proposal = .save(url: frameURL, username: username, password: password)
        }
    }

    /// フォーカスが移った時に、そのペインで検出済みのサインアップ用の欄について生成の提案を評価する
    /// (バックグラウンドで読み込まれたページは検出時の通知が捨てられているため)
    private func evaluateNewPasswordProposal() {
        let pane = currentWindow.focusedPane
        guard pane.hasNewPasswordForm, proposal == nil else {
            return
        }
        proposalPane = pane
        proposalURL = pane.url
        proposalGeneration = pane.documentGeneration
        proposal = .generatePassword
    }

    /// サインアップ用のパスワード欄が現れた時に、生成の提案を出す (既に提案中なら出さない)
    private func handleNewPasswordForm(pane: WebPane, hasNewPasswordForm: Bool) {
        // 欄が消えた (モーダルを閉じた・SPA がログインフォームへ置き換えた) 時は、そのペインの生成提案を取り下げる
        if !hasNewPasswordForm, proposal == .generatePassword, proposalPane === pane {
            dismissProposal()
            return
        }
        guard hasNewPasswordForm, proposal == nil, pane === currentWindow.focusedPane else {
            return
        }
        proposalPane = pane
        proposalURL = pane.url
        proposalGeneration = pane.documentGeneration
        proposal = .generatePassword
    }

    /// 提案を承認する (y)
    func acceptProposal() {
        guard let proposal else {
            return
        }
        let pane = proposalPane
        let url = proposalURL
        let generation = proposalGeneration
        self.proposal = nil
        proposalPane = nil
        proposalURL = nil
        proposalGeneration = nil
        defer {
            reevaluateAfterResolving(proposal: proposal)
        }
        // 保存・更新の提案は送信時に捕捉済みの値なので、送信後の遷移 (ダッシュボードへのリダイレクト等) の後でも承認できる。
        // ページの同一性を確かめるのは、現在の文書へ充填する生成提案だけ
        switch proposal {
        case .save(let url, let username, let password):
            do {
                try credentialStore.save(credential: Credential(id: UUID(), url: url, username: username, password: password, note: "", updatedAt: Date()))
                syncCredentialIdentities()
                statusMessage = "保存した: \(username)"
            } catch {
                statusMessage = "保存に失敗: \(error)"
            }
        case .update(var credential, let password):
            credential.password = password
            credential.updatedAt = Date()
            do {
                try credentialStore.save(credential: credential)
                syncCredentialIdentities()
                statusMessage = "更新した: \(credential.username)"
            } catch {
                statusMessage = "更新に失敗: \(error)"
            }
        case .generatePassword:
            let password = config.passwordGenerator.generate()
            guard let pane else {
                return
            }
            // 提案を出した後に別のページや同じ URL の別文書へ移っていたり、対象のペインが閉じられていたら、そのフォームへは入れない
            // 別のペイン・ウィンドウへフォーカスを移した後の y で、見えていない元のペインへ入れない
            guard pane === currentWindow.focusedPane, pane.url == url, pane.documentGeneration == generation else {
                statusMessage = "ページが変わったため提案を取り消した"
                return
            }
            Task { @MainActor [weak self] in
                // 非同期に入るまでに文書が置き換わっていることがあるため、JavaScript を呼ぶ直前にも世代を確かめる
                guard pane.documentGeneration == generation else {
                    self?.statusMessage = "ページが変わったため提案を取り消した"
                    return
                }
                do {
                    let filled = try await pane.fillNewPassword(password)
                    self?.statusMessage = filled ? "生成したパスワードを入れた (送信後に保存を提案する)" : "パスワード欄が見つからない"
                } catch {
                    self?.statusMessage = "充填に失敗: \(error)"
                }
            }
        }
    }

    /// 提案を却下する (n / Escape)
    func dismissProposal() {
        let resolved = proposal
        proposal = nil
        proposalPane = nil
        proposalURL = nil
        proposalGeneration = nil
        reevaluateAfterResolving(proposal: resolved)
    }

    /// 保存・更新の提案が片付いた後、その間に捨てた新規パスワード欄の通知を補うため現在のペインを評価し直す
    /// (生成提案そのものの解決後は、同じ欄について即座に再提案しない)
    private func reevaluateAfterResolving(proposal resolved: Proposal?) {
        switch resolved {
        case .save, .update:
            evaluateNewPasswordProposal()
        case .generatePassword, nil:
            break
        }
    }

    /// パスワードを生成してサインアップ用の欄に入れる (`:generate-password`)。欄が無ければ status line に知らせる
    func generatePassword() {
        proposalPane = currentWindow.focusedPane
        proposalURL = currentWindow.focusedPane.url
        proposalGeneration = currentWindow.focusedPane.documentGeneration
        proposal = .generatePassword
        acceptProposal()
    }

    /// 資格情報がロック中なら Touch ID / パスワードで本人確認してから action を実行する。確認中はキー入力を受け付けられるよう、
    /// 待つ間も UI を止めない (非同期)。失敗・キャンセルは status line に出して何もしない
    private func withUnlockedCredentials(reason: String, action: @escaping @MainActor () -> Void) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                try await credentialLock.ensureUnlocked(reason: reason)
                // 本人確認の間にウィンドウが閉じられていたら (deactivate 済み)、閉じたペインへの充填や書き出しを行わない
                guard isActive else {
                    return
                }
                action()
            } catch {
                statusMessage = "\(error)"
            }
        }
    }

    /// ストアの内容を OS の自動入力候補 (Credential Provider Extension が充填する) に反映する。保存・更新・インポートの後と起動時に呼ぶ
    private func syncCredentialIdentities() {
        let store = credentialStore
        Task {
            await CredentialIdentityRegistrar.sync(store: store)
        }
    }

    /// ロックされた時に、表示中の資格情報の候補一覧を閉じる
    private func closeCredentialChooserIfLocked() {
        if case .credential = chooser {
            chooser = nil
            statusMessage = "資格情報がロックされたため一覧を閉じた"
        }
    }

    /// 資格情報がロックされているか (status line の表示用)
    var isCredentialLocked: Bool {
        credentialLock.isLocked
    }

    /// 表示中のページに合う資格情報を探して充填する (prefix + a)。1 件なら即充填し、複数なら一覧から選ぶ。ロック中は先に本人確認する
    func fillCredential() {
        cancelPrompt()
        cancelPrefix()
        // 前の候補一覧が残っていると、別ペインの充填後に古い一覧から更に充填できてしまうため閉じる
        chooser = nil
        let pane = currentWindow.focusedPane
        let host = pane.url.host()?.lowercased() ?? ""
        guard !host.isEmpty else {
            statusMessage = "このページには充填できない: \(pane.url.absoluteString)"
            return
        }
        // 本人確認の間に別のページへ移っていたら、確認した時のサイトとは別のページへ充填しない
        let url = pane.url
        let generation = pane.documentGeneration
        withUnlockedCredentials(reason: "\(host) の資格情報を充填する") { [weak self] in
            guard pane.url == url, pane.documentGeneration == generation else {
                self?.statusMessage = "ページが変わったため充填しない: \(pane.url.host() ?? pane.url.absoluteString)"
                return
            }
            self?.presentCredentialCandidates(pane: pane, host: host)
        }
    }

    /// アンロック後に候補を探し、1 件なら充填・複数なら一覧を出す
    private func presentCredentialCandidates(pane: WebPane, host: String) {
        let candidates: [Credential]
        let passkeys: [Passkey]
        do {
            candidates = CredentialMatcher.candidates(credentials: try credentialStore.all(), pageURL: pane.url)
            // 同じ RP (rpId がホストかその親) の Passkey も並べる。WebAuthn を拒む (https でない) ページでは使えないため出さない
            passkeys = WebAuthn.isTrustworthyOrigin(pane.url) ? try PasskeyManager.store.all().filter { WebAuthn.isValidRpId($0.rpId, originHost: host) } : []
        } catch {
            statusMessage = "資格情報を読めない: \(error)"
            return
        }
        switch (candidates.count, passkeys.count) {
        case (0, 0):
            statusMessage = "\(host) の資格情報は無い"
        case (1, 0):
            // 候補の取得で本人確認したばかりなので、もう一度は求めない (lock-timeout 0 では fill の再確認が二重になるため)
            fillUnlocked(credential: candidates[0], pane: pane)
        default:
            chooserSelectionIndex = 0
            chooser = .credential(candidates, passkeys: passkeys, pane: pane)
        }
    }

    /// 資格情報を候補を作ったペインのログインフォームへ充填する。一覧を開いている間にリダイレクトやペインの切替が起きても
    /// 別のサイトへ渡さないよう、実行直前にそのペインの現在の URL と再照合する
    private func fill(credential: Credential, pane: WebPane) {
        // 一覧を開いたまま自動ロックの時刻を過ぎていることがあるため、充填の直前にも確認する (アンロック中なら即実行)。
        // 本人確認の間に同じ URL の別文書や別ページへ移っていたら、確認した時とは別のフォームへ充填しない
        let url = pane.url
        let generation = pane.documentGeneration
        withUnlockedCredentials(reason: "\(credential.username) を充填する") { [weak self] in
            guard pane.url == url, pane.documentGeneration == generation else {
                self?.statusMessage = "ページが変わったため充填しない: \(pane.url.host() ?? pane.url.absoluteString)"
                return
            }
            self?.fillUnlocked(credential: credential, pane: pane)
        }
    }

    /// アンロック確認後の充填本体
    private func fillUnlocked(credential: Credential, pane: WebPane) {
        // 候補元のペインが閉じられていたら (別のペインが表示されていて誤認しやすい) 充填しない
        guard windows.contains(where: { $0.panes[pane.id] === pane }) else {
            statusMessage = "ペインが閉じられたため充填しない"
            return
        }
        guard CredentialMatcher.matches(credentialURL: credential.url, pageURL: pane.url) else {
            statusMessage = "ページが変わったため充填しない: \(pane.url.host() ?? pane.url.absoluteString)"
            return
        }
        Task { @MainActor [weak self] in
            // 非同期に入るまでにリダイレクトや History API の遷移・ペインの破棄 (window.close 等) が起きていることがあるため、
            // JavaScript を呼ぶ直前にペインの所属とトップレベルの URL を改めて照合する。
            // 充填先の iframe は資格情報と同じオリジンのものを WebPane が選ぶ (別オリジンの iframe には渡さない)
            guard let self else {
                return
            }
            guard windows.contains(where: { $0.panes[pane.id] === pane }),
                  CredentialMatcher.matches(credentialURL: credential.url, pageURL: pane.url),
                  let frameURL = pane.loginFormURL(credentialURL: credential.url),
                  CredentialMatcher.matches(credentialURL: credential.url, pageURL: frameURL) else {
                statusMessage = "ページが変わったため充填しない: \(pane.url.host() ?? pane.url.absoluteString)"
                return
            }
            do {
                let filled = try await pane.fill(credential: credential)
                statusMessage = filled ? "充填した: \(credential.username)" : "ログインフォームが見つからない"
            } catch {
                statusMessage = "充填に失敗: \(error)"
            }
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
        guard WebPane.isWebPage(url: pane.url) else {
            statusMessage = "このページはブックマークできない: \(pane.url.absoluteString)"
            return
        }
        if browsingData.isBookmarked(url: pane.url) {
            BrowsingDataStore.shared.removeBookmark(url: pane.url)
            statusMessage = "ブックマークを解除した: \(pane.url.absoluteString)"
        } else {
            // 読み込み中はタイトルが未確定のためホスト名を仮に入れ、確定したら置き換える
            BrowsingDataStore.shared.addBookmark(url: pane.url, title: pane.title ?? pane.url.host() ?? pane.url.absoluteString, isTitleProvisional: pane.title == nil)
            statusMessage = "ブックマークした: \(pane.url.absoluteString)"
        }
    }

    /// ブックマークの一覧を開く (prefix + b)
    func beginChooseBookmark() {
        cancelPrompt()
        cancelPrefix()
        chooserSelectionIndex = 0
        chooser = .bookmark
    }

    /// 訪問を履歴に記録する
    private func recordVisit(url: URL, title: String) {
        // 表示されなかったモデル (SwiftUI が作って捨てた @State の初期値等) の初期読み込みを履歴にしない
        guard isActive else {
            return
        }
        BrowsingDataStore.shared.recordVisit(url: url, title: title)
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
            BrowsingDataStore.shared.removeBookmark(url: browsingData.bookmarks[chooserSelectionIndex].url)
            chooserSelectionIndex = min(chooserSelectionIndex, max(browsingData.bookmarks.count - 1, 0))
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
            webContentFocusRequestCount += 1
        case .credential(let credentials, let passkeys, let pane):
            if credentials.indices.contains(index) {
                fill(credential: credentials[index], pane: pane)
            } else if passkeys.indices.contains(index - credentials.count) {
                // Passkey はページの navigator.credentials.get からしか使えない (アプリ側から署名を押し込む経路は無い)
                statusMessage = "Passkey (\(passkeys[index - credentials.count].userName)) はサイトのサインインボタンから使う"
            }
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
        // プロンプト (コマンド・名前変更) の入力中は prefix も含めて全てのキーを入力欄へ渡す (prefix と同じ文字を入力できるように)
        if prompt != nil {
            return false
        }
        // 提案の表示中は y / n / Escape だけを受け、他のキーは通常どおり (提案は残る)。アドレスバーや Web ページの入力中は横取りしない
        if proposal != nil, !isAddressBarEditing, !currentWindow.focusedPane.isEditingText, keyStroke.modifiers.isEmpty {
            switch keyStroke.key {
            case "y":
                acceptProposal()
                return true
            case "n", "Escape":
                dismissProposal()
                return true
            default:
                break
            }
        }
        if chooser != nil {
            // ⌘Q などの macOS のショートカットは横取りせず通常のイベント処理へ渡す
            if keyStroke.modifiers.contains(.command) {
                return false
            }
            handleChooserKey(keyStroke: keyStroke)
            return true
        }
        // find モード: n / N で次 / 前へ、Escape で抜ける。それ以外のキー (prefix を含む) は通常どおり扱う
        if isFindModeActive, prompt == nil, !isAddressBarEditing, prefixKeyState == .idle, keyStroke.modifiers.isEmpty {
            switch keyStroke.key {
            case "n":
                findNext(backwards: false)
                return true
            case "N":
                findNext(backwards: true)
                return true
            case "Escape":
                isFindModeActive = false
                findGeneration += 1
                find(text: "")
                return true
            default:
                break
            }
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
        case .selectPanePrevious:
            currentWindow.focusPrevious()
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
        case .fillCredential:
            fillCredential()
        case .sourceFile(let path):
            // 相対パスは設定ファイルのディレクトリを基準にする (GUI から起動したアプリのカレントディレクトリは当てにならない)
            reload(
                configFileURL: path.map { URL(filePath: TatamiConfigParser.resolvedIncludePath(path: $0, baseDirectory: TatamiConfigLoader.defaultFileURL.deletingLastPathComponent().path(percentEncoded: false))) } ?? TatamiConfigLoader.defaultFileURL,
                requireFile: path != nil
            )
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
        // 自動ロックまでの時間は共有のロック状態に反映する (:set / :source-file で変えた値を次の操作から使う)
        credentialLock.apply(lockTimeout: config.lockTimeout)
        for model in BrowserWindowModel.activeModels.allObjects {
            // 旧設定の prefix で始めた入力が新しい対応表で実行されないよう prefix 待ちも解除する
            model.cancelPrefix()
            // 起動時や前回の読み込みのエラー表示を全ウィンドウで今回の結果に置き換える (成功したら消す)
            model.statusMessage = TatamiConfigError.statusMessage(errors: errors)
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
            evaluateNewPasswordProposal()
        }
        window.onContentChange = { [weak self] in
            self?.scheduleSave()
        }
        window.onVisit = { [weak self] url, title in
            self?.recordVisit(url: url, title: title)
        }
        window.onTitleChange = { url, title in
            BrowsingDataStore.shared.updateTitle(url: url, title: title)
        }
        window.onLoginSubmit = { [weak self] pane, frameURL, username, password, currentPassword, isNewPassword in
            self?.handleLoginSubmit(pane: pane, frameURL: frameURL, username: username, password: password, currentPassword: currentPassword, isNewPassword: isNewPassword)
        }
        window.onNewPasswordFormChange = { [weak self] pane, hasNewPasswordForm in
            self?.handleNewPasswordForm(pane: pane, hasNewPasswordForm: hasNewPasswordForm)
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
