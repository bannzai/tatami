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
    /// GitHub の PR ページへのリンクをクリックした時の通知先 (tmux の作業スペースへのジャンプ: issue #47)
    var onPullRequestLinkActivated: ((GitHubPullRequestLink) -> Void)?
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
        // PR ページへのリンククリックで tmux の作業スペースへジャンプする (issue #47)。同じ PR の中のタブ移動では再ジャンプしない
        if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame?.isMainFrame == true,
           let destinationURL = navigationAction.request.url,
           let link = GitHubPullRequestLink.parse(url: destinationURL),
           PRWorkspaceJumper.shouldJump(currentURL: webView.url, destinationLink: link) {
            onPullRequestLinkActivated?(link)
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
