import AppKit
import WebKit

/// 1 ペイン分の Web コンテンツ。WKWebView と、その URL / タイトル / 進捗の変化と新規ウィンドウ要求を受ける delegate をまとめて持つ。
/// ペインツリー (PaneTree) には識別子だけが載り、実体はこのクラスが PaneWindow に保持される
@MainActor
final class WebPane: NSObject, WKUIDelegate, WKNavigationDelegate {
    /// ペインツリー上の識別子
    let id: PaneID
    /// 表示に使う WebKit のビュー
    let webView: WKWebView
    /// 表示中の URL。ナビゲーション・リダイレクト・History API で更新される
    private(set) var url: URL
    /// url が変わった時の通知先 (アドレスバーの追随に使う)
    var onNavigate: ((URL) -> Void)?
    /// タイトル・読み込み進捗・戻る/進むの可否が変わった時の通知先 (ツールバーの表示更新に使う)
    var onStateChange: (() -> Void)?
    /// target="_blank" / window.open の要求先。渡した configuration で作った WKWebView を返すと、WebKit がその要求を新しいビューに読み込む
    var onCreateWebView: ((WKWebViewConfiguration) -> WKWebView?)?
    /// ページが window.close() を呼んだ時の通知先 (OAuth の完了画面など)。ペインを閉じる
    var onClose: (() -> Void)?
    /// 実際のナビゲーション (読み込み完了・History API の遷移) の通知先 (履歴の記録に使う)。URL とその時点のタイトル
    var onVisit: ((URL, String) -> Void)?
    /// 表示中のページのタイトルだけが変わった時の通知先 (履歴のタイトル更新。順序は変えない)
    var onTitleChange: ((URL, String) -> Void)?
    /// 証明書エラーの警告ページを表示している間 true。警告ページは履歴に残さない
    private var isShowingCertificateWarning = false
    /// セッションの復元による読み込みのナビゲーション。復元は新しい訪問ではないため、このナビゲーションの完了は履歴に記録しない
    /// (フラグではなくナビゲーションを持つことで、復元が終わる前にユーザーが開いた別ページの完了を復元扱いしない)
    private var restoringNavigation: WKNavigation?
    /// 復元後、復元直後の SPA の初期化による History API の遷移を訪問として記録しないための抑止。
    /// ユーザー起点のナビゲーション開始で解除するほか、復元の読み込み完了から一定時間で解除する (pushState だけで遷移する SPA でユーザー操作を記録するため)
    private var isSuppressingRestoredVisits = false
    /// 復元の読み込み完了後に抑止を続ける時間。SPA の初期化 (replaceState 等) は読み込み直後に集中するため、その後のユーザー操作を取りこぼさない短さにした
    private static let restoredVisitSuppressionGrace: Duration = .seconds(2)

    /// 表示中のページ (いずれかのフレーム) にパスワード欄があるか。注入スクリプトからの通知で更新する
    private(set) var hasLoginForm = false
    /// サインアップ / パスワード変更のフォーム (autocomplete=new-password かパスワード欄が 2 つ以上) があるか
    private(set) var hasNewPasswordForm = false
    /// ログインフォームが送信された時の通知先 (送信元フレームの URL・ユーザー名・パスワード・現在のパスワード (変更フォーム)・新規パスワードのフォームか)。
    /// 保存・更新の提案に使う。別オリジンの iframe からの送信を埋め込み元の資格情報として扱わないよう、URL はトップレベルではなくフレームのもの
    var onLoginSubmit: ((URL, String, String, String, Bool) -> Void)?

    /// scheme + host + port のオリジン文字列
    static func origin(url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "")://\(url.host()?.lowercased() ?? ""):\(url.port.map(String.init) ?? "")"
    }
    /// Web ページ内のテキスト入力 (input / textarea / contentEditable) にフォーカスがあるか。提案の y / n を横取りしないために使う
    private(set) var isEditingText = false
    /// 複数段階ログインの 1 段目で入力されたユーザー名と、そのオリジン。次の段で同じオリジンからパスワードだけが送信された時に関連付け、
    /// 別のサイトへ移った (オリジンが変わった) 時は使わない
    private(set) var pendingUsername: (username: String, origin: String)?
    /// フレームごとの新規パスワード欄の有無。ペイン全体の有無はいずれかのフレームが true か
    private var newPasswordFrames: Set<String> = []
    /// サインアップ用のパスワード欄が現れた / 消えた時の通知先
    var onNewPasswordFormChange: ((Bool) -> Void)?

    /// KVO 監視。このインスタンスの寿命に合わせて解除する
    private var observations: [NSKeyValueObservation] = []

    /// configuration は window.open の要求 (createWebViewWith) で WebKit から渡されたものをそのまま使う必要があるため引数で受ける。
    /// 通常のペインは defaultConfiguration() (Cookie・ローカルストレージを永続化する WKWebsiteDataStore.default) を渡す。
    /// userAgent は tatami.conf の `set -g user-agent` の値で、nil なら WebKit の既定をそのまま使う
    init(id: PaneID, url: URL, userAgent: String?, configuration: WKWebViewConfiguration) {
        self.id = id
        self.url = url
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        // Chromium の DevTools 相当として Safari の Web Inspector を使えるようにする (ADR 0001)
        webView.isInspectable = true
        webView.customUserAgent = userAgent
        webView.uiDelegate = self
        webView.navigationDelegate = self
        // ログインフォームの検出と充填のスクリプトを専用の content world に注入する (documentStart・全フレーム)
        // window.open で渡される configuration は元のビューの userContentController を引き継ぐ。同名 handler の重複登録は例外になるため、
        // controller ごとに 1 度だけ登録し、中継先は最後に登録したペインではなく controller を共有する各ペインへ配る
        WebPane.register(pane: self, in: configuration.userContentController)
        // History API (pushState / replaceState) は navigation delegate を通らないため、url プロパティの変化を監視する。
        // observation をこのインスタンスが所有するため、クロージャからは弱参照にして循環参照を避ける
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, change in
                guard let self, let changedURL = change.newValue ?? nil else {
                    return
                }
                Task { @MainActor in
                    self.url = changedURL
                    self.onNavigate?(changedURL)
                    // History API (pushState / replaceState) の遷移は didFinish が来ないため、読み込み中でなければここで訪問として記録する。
                    // 同じターンで pushState が続くと後の KVO で webView.url が進んでいるため、捕捉した changedURL を記録する
                    if !self.webView.isLoading, !self.isSuppressingRestoredVisits {
                        self.notifyVisitIfWebPage(url: changedURL)
                    }
                }
            },
            webView.observe(\.title) { [weak self] _, _ in
                guard let self else {
                    return
                }
                Task { @MainActor in
                    self.onStateChange?()
                    // 読み込み完了後にタイトルが決まるページや、未読件数をタイトルに出すページのために、履歴のタイトルだけを更新する (順序と訪問日時は変えない)
                    if let url = self.webView.url, self.isWebPage(url: url), !self.isShowingCertificateWarning, let title = self.title {
                        self.onTitleChange?(url, title)
                    }
                }
            },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in
                guard let self else {
                    return
                }
                Task { @MainActor in
                    self.onStateChange?()
                }
            },
            webView.observe(\.isLoading) { [weak self] _, _ in
                guard let self else {
                    return
                }
                Task { @MainActor in
                    self.onStateChange?()
                }
            },
            // history.pushState で forward 履歴が消えるなど、URL・タイトル・読み込み状態が変わらずに可否だけ変わる場合があるため個別に監視する
            webView.observe(\.canGoBack) { [weak self] _, _ in
                guard let self else {
                    return
                }
                Task { @MainActor in
                    self.onStateChange?()
                }
            },
            webView.observe(\.canGoForward) { [weak self] _, _ in
                guard let self else {
                    return
                }
                Task { @MainActor in
                    self.onStateChange?()
                }
            },
        ]
    }

    /// ログイン状態を再起動後も保つため、永続化される既定のデータストアを使う (documents/PROJECT.md 機能要件 1)
    static func defaultConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        return configuration
    }

    /// 初期 URL の読み込み。window.open で作られたペインは WebKit 側が要求を読み込むため、呼び出し側が通常のペインにだけ使う
    func loadInitialURL() {
        webView.load(URLRequest(url: url))
    }

    /// セッション復元による読み込み。完了しても履歴には記録しない
    func loadRestoredURL() {
        isSuppressingRestoredVisits = true
        restoringNavigation = webView.load(URLRequest(url: url))
    }

    func load(url: URL) {
        webView.load(URLRequest(url: url))
    }

    /// 証明書エラーで表示できなかった URL。警告ページを表示している間だけ持ち、再読み込みで警告 HTML ではなくこの URL へ再接続する
    private var certificateFailedURL: URL?

    /// 再読み込み。証明書の警告ページを表示中は元の URL へ再接続する (証明書や時刻を直した後に再試行できる)
    func reload() {
        if let certificateFailedURL {
            webView.load(URLRequest(url: certificateFailedURL))
        } else {
            webView.reload()
        }
    }

    /// ページのタイトル。無題なら nil。読み込み中は前のページのタイトルが残っていて現在の URL に属さないため nil
    var title: String? {
        guard !webView.isLoading else {
            return nil
        }
        return webView.title.flatMap { $0.isEmpty ? nil : $0 }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        onCreateWebView?(configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        onClose?()
    }

    /// WKUserContentController が handler を強参照して WebPane と循環するのを避けるための弱参照の中継。
    /// 1 つの controller を複数の WKWebView (window.open で開いたペイン) が共有するため、メッセージは送信元の WebView を持つペインへ届ける
    private final class ScriptMessageRelay: NSObject, WKScriptMessageHandler {
        let panes = NSHashTable<WebPane>.weakObjects()

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let webView = message.webView, let pane = panes.allObjects.first(where: { $0.webView === webView }) else {
                return
            }
            pane.userContentController(userContentController, didReceive: message)
        }
    }

    /// controller ごとの中継。同じ controller に 2 回 add すると WebKit が例外を投げるため、ここで 1 度だけ登録する。
    /// キーは controller の弱参照 (解放後にアドレスが再利用されても古い中継を共有済みと誤認しない)
    private static let relays = NSMapTable<WKUserContentController, ScriptMessageRelay>.weakToStrongObjects()

    private static func register(pane: WebPane, in controller: WKUserContentController) {
        if let relay = relays.object(forKey: controller) {
            relay.panes.add(pane)
            return
        }
        let relay = ScriptMessageRelay()
        relay.panes.add(pane)
        relays.setObject(relay, forKey: controller)
        controller.addUserScript(LoginFormScript.makeUserScript())
        controller.add(relay, contentWorld: LoginFormScript.contentWorld, name: LoginFormScript.messageName)
    }

    /// パスワード欄を検出したフレーム。iframe 内のログインフォームにも充填できるよう、充填はこのフレームで実行する
    private var loginFormFrame: WKFrameInfo?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == LoginFormScript.messageName, let body = message.body as? [String: Any] else {
            return
        }
        if body["hasPassword"] as? Bool == true {
            loginFormFrame = message.frameInfo
        }
        if let hasPassword = body["hasPassword"] as? Bool {
            hasLoginForm = hasPassword
        }
        if let hasNewPassword = body["hasNewPassword"] as? Bool {
            // フレームごとに保持し、いずれかのフレームにあればペイン全体としてある (遅れて読み込まれた iframe の false で消さない)
            let frameKey = message.frameInfo.request.url?.absoluteString ?? (message.frameInfo.isMainFrame ? "main" : "frame")
            if hasNewPassword {
                newPasswordFrames.insert(frameKey)
            } else {
                newPasswordFrames.remove(frameKey)
            }
            let aggregated = !newPasswordFrames.isEmpty
            if aggregated != hasNewPasswordForm {
                hasNewPasswordForm = aggregated
                onNewPasswordFormChange?(aggregated)
            }
        }
        if let editing = body["editing"] as? Bool {
            isEditingText = editing
        }
        if let usernameOnly = body["usernameOnly"] as? String, !usernameOnly.isEmpty, let frameURL = message.frameInfo.request.url {
            pendingUsername = (usernameOnly, WebPane.origin(url: frameURL))
        }
        if body["submitted"] as? Bool == true, let password = body["password"] as? String, !password.isEmpty {
            // 送信元フレームの URL (スクリプトからの申告ではなく WebKit が持つフレーム情報) を使う
            let frameURL = message.frameInfo.request.url ?? (body["frameURL"] as? String).flatMap(URL.init(string:)) ?? webView.url
            guard let frameURL else {
                return
            }
            var username = body["username"] as? String ?? ""
            if username.isEmpty, let pendingUsername, pendingUsername.origin == WebPane.origin(url: frameURL) {
                username = pendingUsername.username
            }
            pendingUsername = nil
            onLoginSubmit?(frameURL, username, password, body["currentPassword"] as? String ?? "", body["isNewPassword"] as? Bool ?? false)
        }
    }

    /// 生成したパスワードをページの全てのパスワード欄 (新規と確認) に入れる
    func fillNewPassword(_ password: String) async throws -> Bool {
        let result = try await webView.callAsyncJavaScript(
            "return window.__tatamiFillNewPassword(password);",
            arguments: ["password": password],
            in: loginFormFrame,
            contentWorld: LoginFormScript.contentWorld
        )
        return result as? Bool ?? false
    }

    /// パスワード欄を検出したフレームの URL (無ければトップレベル)。充填先のオリジンの照合に使う
    var loginFormURL: URL? {
        loginFormFrame?.request.url ?? webView.url
    }

    /// 資格情報を表示中のページのログインフォームへ充填する。パスワード欄が無ければ false。
    /// 呼び出し側は直前に `loginFormURL` と資格情報を照合する (別オリジンの iframe が欄を持つ場合に渡さないため)
    func fill(credential: Credential) async throws -> Bool {
        let result = try await webView.callAsyncJavaScript(
            "return window.__tatamiFill(username, password);",
            arguments: ["username": credential.username, "password": credential.password],
            in: loginFormFrame,
            contentWorld: LoginFormScript.contentWorld
        )
        return result as? Bool ?? false
    }

    // MARK: JavaScript のダイアログ (alert / confirm / prompt) をネイティブのシートで出す

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? ""
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        WebPane.identify(alert: alert, prefix: "jsAlert")
        _ = await run(alert: alert)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? ""
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        WebPane.identify(alert: alert, prefix: "jsConfirm")
        return await run(alert: alert) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? ""
        alert.informativeText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultText ?? "")
        // 入力欄の幅。NSAlert の本文幅に合わせた値で、これより狭いと URL などの長い入力が読めない
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.setAccessibilityIdentifier("jsPromptField")
        alert.accessoryView = field
        WebPane.identify(alert: alert, prefix: "jsPrompt")
        return await run(alert: alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// WebDriverAgentMac からダイアログのボタンを特定できるよう、`<prefix>Button-<番号>` の識別子を付ける (0 が既定のボタン)
    private static func identify(alert: NSAlert, prefix: String) {
        for (index, button) in alert.buttons.enumerated() {
            button.setAccessibilityIdentifier("\(prefix)Button-\(index)")
        }
    }

    /// カメラ・マイクの権限要求 (WKUIDelegate)。ユーザーがダイアログで許可した時だけ通す。
    /// 位置情報は macOS の WKWebView が CoreLocation の許可ダイアログを自前で出すため、ここでは扱わない
    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        let alert = NSAlert()
        alert.messageText = "\(origin.host) が\(WebPane.mediaCaptureName(type: type))の使用を求めています"
        alert.addButton(withTitle: "許可")
        alert.addButton(withTitle: "拒否")
        WebPane.identify(alert: alert, prefix: "mediaPermission")
        return await run(alert: alert) == .alertFirstButtonReturn ? .grant : .deny
    }

    private static func mediaCaptureName(type: WKMediaCaptureType) -> String {
        switch type {
        case .camera:
            return "カメラ"
        case .microphone:
            return "マイク"
        case .cameraAndMicrophone:
            return "カメラとマイク"
        @unknown default:
            return "メディア"
        }
    }

    /// ウィンドウがあればシートで、無ければモーダルで出す
    private func run(alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = webView.window else {
            return alert.runModal()
        }
        return await alert.beginSheetModal(for: window)
    }

    // MARK: ナビゲーション (証明書エラーの警告ページ・ダウンロードの判定・履歴)

    /// 警告 HTML 自体の読み込み。この開始と完了では証明書エラーの状態を解除しない
    private var certificateWarningNavigation: WKNavigation?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard navigation !== certificateWarningNavigation else {
            return
        }
        // 復元のナビゲーション以外 (ユーザー起点) が始まったら、復元に付随する遷移の抑止を終える
        if navigation !== restoringNavigation {
            isSuppressingRestoredVisits = false
        }
        // 別のページへ移る時は、前のページで集めた新規パスワード欄の状態を捨てる (ユーザー名はオリジンで照合するため残す)
        newPasswordFrames.removeAll()
        isShowingCertificateWarning = false
        certificateFailedURL = nil
        certificateWarningNavigation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let restoringNavigation, navigation === restoringNavigation {
            self.restoringNavigation = nil
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: WebPane.restoredVisitSuppressionGrace)
                self?.isSuppressingRestoredVisits = false
            }
            return
        }
        restoringNavigation = nil
        notifyVisitIfWebPage()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if navigation === restoringNavigation {
            restoringNavigation = nil
            isSuppressingRestoredVisits = false
        }
    }

    private func isWebPage(url: URL) -> Bool {
        WebPane.isWebPage(url: url)
    }

    /// http / https のページか。スキームは大小文字を区別しない (`HTTPS://example.com` も有効な URL)
    static func isWebPage(url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    /// http / https のページだけを履歴に記録する (about:blank・証明書の警告ページ・セッション復元の読み込みは記録しない)
    private func notifyVisitIfWebPage(url: URL? = nil) {
        guard let url = url ?? webView.url, isWebPage(url: url), !isShowingCertificateWarning else {
            return
        }
        onVisit?(url, title ?? url.host() ?? url.absoluteString)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        (navigationAction.shouldPerformDownload ? .download : .allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    /// 証明書エラー (信頼できない・期限切れ・ホスト名不一致等) は WebKit が既定で通さない。その時は白紙ではなく警告ページを出す。
    /// 例外的に通す手段は持たない (作者の用途では自己署名の開発サーバーは http で使う)
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if navigation === restoringNavigation {
            restoringNavigation = nil
            isSuppressingRestoredVisits = false
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain, WebPane.certificateErrorCodes.contains(nsError.code),
              let failedURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL else {
            return
        }
        // baseURL に失敗した URL を渡し、アドレスバーにそのままの URL が残るようにする (再読み込みで再試行できる)。警告ページは履歴に記録しない
        isShowingCertificateWarning = true
        certificateFailedURL = failedURL
        certificateWarningNavigation = webView.loadHTMLString(WebPane.certificateWarningHTML(url: failedURL, message: nsError.localizedDescription), baseURL: failedURL)
    }

    /// NSURLError の証明書関連のコード (-1200 SecureConnectionFailed 〜 -1206 ClientCertificateRequired)
    private static let certificateErrorCodes: Set<Int> = [
        NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
        NSURLErrorClientCertificateRequired,
    ]

    private static func certificateWarningHTML(url: URL, message: String) -> String {
        let escapedURL = url.absoluteString.replacingOccurrences(of: "<", with: "&lt;")
        let escapedMessage = message.replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html><meta charset="utf-8"><title>接続は安全ではありません</title>
        <body style="font-family: -apple-system, sans-serif; margin: 48px; color: #222">
        <h1 style="font-size: 20px">接続は安全ではありません</h1>
        <p>\(escapedURL) の証明書を検証できなかったため、ページを表示しませんでした。</p>
        <p style="color: #666">\(escapedMessage)</p>
        </body>
        """
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download: download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download: download)
    }
}
