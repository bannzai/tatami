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
        let scheme = url.scheme?.lowercased() ?? ""
        // 既定ポートの明示 (https の 443・http の 80) は省略と同じオリジン
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        let port = url.port.flatMap { $0 == defaultPort ? nil : $0 }.map(String.init) ?? ""
        return "\(scheme)://\(url.host()?.lowercased() ?? ""):\(port)"
    }
    /// Web ページ内のテキスト入力 (input / textarea / contentEditable) にフォーカスがあるか。提案の y / n を横取りしないために使う
    private(set) var isEditingText = false
    /// 複数段階ログインの 1 段目で入力されたユーザー名と、そのオリジン。次の段で同じオリジンからパスワードだけが送信された時に関連付け、
    /// 別のサイトへ移った (オリジンが変わった) 時は使わない
    private(set) var pendingUsername: (username: String, origin: String)?
    /// 保留中のユーザー名を持ち越せる残りの文書遷移の回数。1 段目 → 2 段目のページ遷移 (1 回) だけを許し、
    /// それ以上の無関係な遷移では捨てる (別のパスワード専用フォームに古いユーザー名を付けない)
    private var pendingUsernameNavigationsRemaining = 0
    /// フレームごとの新規パスワード欄の有無。ペイン全体の有無はいずれかのフレームが true か
    private var newPasswordFrames: [String: WKFrameInfo] = [:]
    /// テキスト入力中のフレーム。いずれかのフレームで入力中ならペインとして入力中 (後から読み込まれた iframe の false で上書きしない)
    private var editingFrames: Set<String> = []
    /// 表示中の文書の世代。同じ URL への再読み込みや別文書への置換を検出するため、didCommit のたびに進める
    private(set) var documentGeneration = 0
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
                    // History API (同一文書) の遷移でも保留中のユーザー名の持ち越し回数を減らす (同一文書の別ルートへ無期限に残さない)。
                    // 通常の文書遷移は didCommit 側で数えるため、読み込み中の URL 変化はここでは数えない (二重に減らさない)
                    if !self.webView.isLoading {
                        self.consumePendingUsernameNavigation()
                    }
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
        // アドレスバーやブックマークからの読み込みは利用者の操作なので、復元に伴う訪問の抑止を終える
        isSuppressingRestoredVisits = false
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

    /// WebAuthn (Passkey) の要求の中継。返信付き handler で、ページの Promise に結果を返す
    private final class WebAuthnRelay: NSObject, WKScriptMessageHandlerWithReply {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
            guard message.name == WebAuthnScript.messageName, let body = message.body as? [String: Any] else {
                return (nil, "invalid message")
            }
            // オリジンはスクリプトの申告ではなく WebKit が持つフレームの security origin から決める。
            // 別オリジンの iframe からの要求は許さない (通常の WebAuthn は Permissions Policy の明示的な委譲が無ければ拒む。
            // 委譲の解釈は持たないため、トップレベルと同じオリジンのフレームだけを許す。clientDataJSON の crossOrigin は常に false で正しい)
            let frameOrigin = WebPane.originURL(frame: message.frameInfo)
            if !message.frameInfo.isMainFrame {
                guard let frameOrigin, let topURL = message.webView?.url, CredentialMatcher.sameOrigin(credentialURL: frameOrigin, pageURL: topURL) else {
                    return (["error": "別オリジンの iframe からの WebAuthn には対応しない", "name": "NotAllowedError"], nil)
                }
            }
            return (await PasskeyManager.handle(body: body, origin: frameOrigin), nil)
        }
    }

    private static let webAuthnRelay = WebAuthnRelay()

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
        // Passkey: ページの world で navigator.credentials を置き換える (ページのスクリプトから見える必要があるため専用 world ではない)
        controller.addUserScript(WebAuthnScript.makeUserScript())
        controller.addScriptMessageHandler(webAuthnRelay, contentWorld: .page, name: WebAuthnScript.messageName)
    }

    /// パスワード欄を検出したフレーム (フレームの URL ごと)。iframe 内のログインフォームにも充填できるよう、充填はこのフレームで実行する。
    /// フレームごとに持つのは、欄が消えた iframe の false 通知で他のフレームの欄を見失わないため
    private var loginFormFrames: [String: WKFrameInfo] = [:]

    /// 充填先のフレーム。トップレベルに欄があればそれを優先し、無ければ検出済みの iframe
    private var loginFormFrame: WKFrameInfo? {
        loginFormFrames.values.first(where: \.isMainFrame) ?? loginFormFrames.values.first
    }

    /// フレームのオリジンを表す URL。`about:blank` / `srcdoc` / `blob:` の iframe は request URL に host が無く親のオリジンを継承するため、
    /// WebKit が持つ security origin から組み立てる (sandbox で opaque なオリジンは host が空になり、照合に通らない)
    static func originURL(frame: WKFrameInfo) -> URL? {
        // request URL にホストがあっても sandbox で opaque になったフレームは security origin の host が空になる。
        // その場合は request URL へフォールバックせず拒否する (別オリジン扱いのフレームへ資格情報を渡さない)
        let origin = frame.securityOrigin
        guard !origin.host.isEmpty else {
            return nil
        }
        // IPv6 のホストは角括弧で囲まないと URL にならない
        let host = origin.host.contains(":") ? "[\(origin.host)]" : origin.host
        return URL(string: "\(origin.protocol)://\(host)\(origin.port == 0 ? "" : ":\(origin.port)")/")
    }

    /// 通知元フレームのページ URL。トップレベルは webView.url、iframe は request URL (http(s) のホストがある時)、
    /// 継承オリジン (`about:blank` / `srcdoc` / `blob:`) の iframe は security origin から組み立てたオリジン URL。
    /// スクリプトからの申告 (location.href) ではなく WebKit が持つフレーム情報だけを使う
    static func frameURL(message: WKScriptMessage) -> URL? {
        let frame = message.frameInfo
        if frame.isMainFrame {
            // 送信直後に History API やナビゲーションで URL が変わっていることがあるため、通知時点のフレームの URL を優先する
            if let url = frame.request.url, let host = url.host(), !host.isEmpty, WebPane.isWebPage(url: url) {
                return url
            }
            return message.webView?.url
        }
        if let url = frame.request.url, let host = url.host(), !host.isEmpty, WebPane.isWebPage(url: url) {
            return url
        }
        return originURL(frame: frame)
    }

    /// 資格情報の充填先フレーム。トップレベルに欄があればそれ、無ければ資格情報と同じオリジンの iframe (別オリジンの iframe には渡さない)。
    /// 該当が無ければ nil
    func loginFormFrame(credentialURL: URL) -> WKFrameInfo? {
        if let main = loginFormFrames.values.first(where: \.isMainFrame) {
            return main
        }
        return loginFormFrames.values.first { frame in
            WebPane.originURL(frame: frame).map { CredentialMatcher.sameOrigin(credentialURL: credentialURL, pageURL: $0) } ?? false
        }
    }

    /// 資格情報の充填先フレームのオリジン URL (トップレベルなら webView.url)。呼び出し側が資格情報と照合する
    func loginFormURL(credentialURL: URL) -> URL? {
        guard let frame = loginFormFrame(credentialURL: credentialURL) else {
            return nil
        }
        return frame.isMainFrame ? webView.url : WebPane.originURL(frame: frame)
    }

    /// フレームを識別するキー (WKFrameInfo は通知ごとに別インスタンスで届くため、スクリプトが注入コンテキストごとに付ける ID で対応付ける。
    /// 同じ URL の iframe が複数あっても区別できる。ID が無い通知は URL で代用する)
    private static func frameKey(message: WKScriptMessage) -> String {
        if let frameID = (message.body as? [String: Any])?["frameID"] as? String, !frameID.isEmpty {
            return frameID
        }
        return message.frameInfo.request.url?.absoluteString ?? (message.frameInfo.isMainFrame ? "main" : "frame")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == LoginFormScript.messageName, let body = message.body as? [String: Any] else {
            return
        }
        if body["gone"] as? Bool == true {
            // 破棄されるフレーム (pagehide) の状態を全て消す
            let key = WebPane.frameKey(message: message)
            loginFormFrames.removeValue(forKey: key)
            hasLoginForm = !loginFormFrames.isEmpty
            editingFrames.remove(key)
            isEditingText = !editingFrames.isEmpty
            if newPasswordFrames.removeValue(forKey: key) != nil, newPasswordFrames.isEmpty, hasNewPasswordForm {
                hasNewPasswordForm = false
                onNewPasswordFormChange?(false)
            }
            return
        }
        if let hasPassword = body["hasPassword"] as? Bool {
            if hasPassword {
                loginFormFrames[WebPane.frameKey(message: message)] = message.frameInfo
            } else {
                loginFormFrames.removeValue(forKey: WebPane.frameKey(message: message))
            }
            hasLoginForm = !loginFormFrames.isEmpty
        }
        if let hasNewPassword = body["hasNewPassword"] as? Bool {
            // フレームごとに保持し、いずれかのフレームにあればペイン全体としてある (遅れて読み込まれた iframe の false で消さない)
            let frameKey = WebPane.frameKey(message: message)
            if hasNewPassword {
                newPasswordFrames[frameKey] = message.frameInfo
            } else {
                newPasswordFrames.removeValue(forKey: frameKey)
            }
            // 生成提案を出すのは、生成値を実際に入れられるフレーム (トップレベル、またはトップレベルと同じオリジンの iframe) がある時だけ
            // (fillNewPassword の対象と揃える。別オリジンの iframe だけの登録フォームでは提案しても必ず失敗するため)
            let aggregated = newPasswordFrames.values.contains { frame in
                frame.isMainFrame || WebPane.originURL(frame: frame).flatMap { origin in webView.url.map { CredentialMatcher.sameOrigin(credentialURL: origin, pageURL: $0) } } == true
            }
            if aggregated != hasNewPasswordForm {
                hasNewPasswordForm = aggregated
                onNewPasswordFormChange?(aggregated)
            }
        }
        if let editing = body["editing"] as? Bool {
            if editing {
                editingFrames.insert(WebPane.frameKey(message: message))
            } else {
                editingFrames.remove(WebPane.frameKey(message: message))
            }
            isEditingText = !editingFrames.isEmpty
        }
        if let usernameOnly = body["usernameOnly"] as? String, !usernameOnly.isEmpty, let frameURL = WebPane.frameURL(message: message) {
            pendingUsername = (usernameOnly, WebPane.origin(url: frameURL))
            pendingUsernameNavigationsRemaining = 1
        }
        if body["submitted"] as? Bool == true, let password = body["password"] as? String, !password.isEmpty {
            // 送信元フレームの URL (スクリプトからの申告ではなく WebKit が持つフレーム情報) を使う
            guard let frameURL = WebPane.frameURL(message: message) else {
                return
            }
            var username = body["username"] as? String ?? ""
            // 保留中のユーザー名は同じオリジンの送信に使った時だけ消す (別オリジンの iframe の送信が先に来ても、本来の 2 段目のために残す)
            if username.isEmpty, let pendingUsername, pendingUsername.origin == WebPane.origin(url: frameURL) {
                username = pendingUsername.username
                self.pendingUsername = nil
            } else if pendingUsername?.origin == WebPane.origin(url: frameURL) {
                self.pendingUsername = nil
            }
            onLoginSubmit?(frameURL, username, password, body["currentPassword"] as? String ?? "", body["isNewPassword"] as? Bool ?? false)
        }
    }

    /// 生成したパスワードを、新規パスワード欄を検出したフレームの全てのパスワード欄 (新規と確認) に入れる。
    /// 新規パスワード欄を検出していなければ何もしない (通常のログイン欄へ生成値を入れて入力済みの値を上書きしない)
    func fillNewPassword(_ password: String) async throws -> Bool {
        // 検出済みのフレームを順に試し (トップレベル優先)、最初に充填できたフレームで成功とする
        // (トップレベルの登録フォームが画面外で充填できない時に、表示中の iframe の登録フォームを使えるように)。
        // 生成した値を別オリジンの iframe へ渡さないよう、iframe はトップレベルと同じオリジンのものだけを対象にする
        let frames = newPasswordFrames.values
            .filter { frame in frame.isMainFrame || WebPane.originURL(frame: frame).flatMap { origin in webView.url.map { CredentialMatcher.sameOrigin(credentialURL: origin, pageURL: $0) } } == true }
            .sorted { $0.isMainFrame && !$1.isMainFrame }
        for frame in frames {
            let result = try await webView.callAsyncJavaScript(
                "return window.__tatamiFillNewPassword(password);",
                arguments: ["password": password],
                in: frame,
                contentWorld: LoginFormScript.contentWorld
            )
            if result as? Bool == true {
                return true
            }
        }
        return false
    }

    /// 資格情報を表示中のページのログインフォームへ充填する。パスワード欄が無ければ false。
    /// 呼び出し側は直前に `loginFormURL` と資格情報を照合する (別オリジンの iframe が欄を持つ場合に渡さないため)
    func fill(credential: Credential) async throws -> Bool {
        guard let frame = loginFormFrame(credentialURL: credential.url) else {
            return false
        }
        let result = try await webView.callAsyncJavaScript(
            "return window.__tatamiFill(username, password);",
            arguments: ["username": credential.username, "password": credential.password],
            in: frame,
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
        // シートを開いた直後にそのまま入力できるよう、入力欄を initial first responder にする
        alert.window.initialFirstResponder = field
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
        isShowingCertificateWarning = false
        certificateFailedURL = nil
        certificateWarningNavigation = nil
    }

    /// 文書遷移 (commit) または History API の遷移を 1 回として数え、許した回数を超えたら保留中のユーザー名を捨てる
    private func consumePendingUsernameNavigation() {
        guard pendingUsername != nil else {
            return
        }
        pendingUsernameNavigationsRemaining -= 1
        if pendingUsernameNavigationsRemaining < 0 {
            pendingUsername = nil
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        documentGeneration += 1
        consumePendingUsernameNavigation()
        // 旧文書が破棄される時点 (commit) で、そのフレーム情報 (false 通知は届かない) と新規パスワード欄・編集中の状態を捨てる。
        // provisional で失敗したナビゲーション (DNS エラー等) では旧文書が残るため、開始時点では捨てない (ユーザー名はオリジンで照合するため残す)
        loginFormFrames.removeAll()
        hasLoginForm = false
        newPasswordFrames.removeAll()
        editingFrames.removeAll()
        isEditingText = false
        // 集約フラグも戻し、新文書の true が「変化なし」として捨てられないようにする
        if hasNewPasswordForm {
            hasNewPasswordForm = false
            onNewPasswordFormChange?(false)
        }
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
        // 復元に伴う自動遷移 (location 変更・meta refresh・認証リダイレクト) の完了は訪問として記録しない
        guard !isSuppressingRestoredVisits else {
            return
        }
        notifyVisitIfWebPage()
        // 読み込み中は title を nil にしているため、その間の document.title の変化は通知されない。完了時点の確定タイトルをここで通知する
        if let url = webView.url, isWebPage(url: url), !isShowingCertificateWarning, let title {
            onTitleChange?(url, title)
        }
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
        // 復元したページの自動遷移 (location 変更・meta refresh・認証リダイレクト) は復元の一部として履歴に記録しない。
        // 利用者の操作 (リンク・フォーム送信・戻る/進む・再読み込み) が起きた時点で抑止を終える
        switch navigationAction.navigationType {
        case .linkActivated, .formSubmitted, .formResubmitted, .backForward, .reload:
            isSuppressingRestoredVisits = false
        case .other:
            break
        @unknown default:
            break
        }
        // ダウンロードへの変換はトップレベルの操作に限る (隠し iframe からスクリプトで download 属性のリンクを起動して
        // Downloads へ大量保存させない。response 側の制限と同じ理由)
        if navigationAction.shouldPerformDownload {
            return (navigationAction.targetFrame?.isMainFrame == true ? .download : .cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.canShowMIMEType {
            return .allow
        }
        // 表示できない応答をダウンロードへ変えるのはトップレベル (利用者の操作で開いたもの) だけ。
        // 隠し iframe を量産して勝手に Downloads へ保存させる攻撃を防ぐため、サブフレームは中止する
        return navigationResponse.isForMainFrame ? .download : .cancel
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
