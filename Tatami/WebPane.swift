import WebKit

/// 1 ペイン分の Web コンテンツ。WKWebView と、その URL / タイトル / 進捗の変化と新規ウィンドウ要求を受ける delegate をまとめて持つ。
/// ペインツリー (PaneTree) には識別子だけが載り、実体はこのクラスが PaneWindow に保持される
@MainActor
final class WebPane: NSObject, WKUIDelegate {
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
    /// KVO 監視。このインスタンスの寿命に合わせて解除する
    private var observations: [NSKeyValueObservation] = []

    /// configuration は window.open の要求 (createWebViewWith) で WebKit から渡されたものをそのまま使う必要があるため引数で受ける。
    /// 通常のペインは defaultConfiguration() (Cookie・ローカルストレージを永続化する WKWebsiteDataStore.default) を渡す
    init(id: PaneID, url: URL, configuration: WKWebViewConfiguration) {
        self.id = id
        self.url = url
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        // Chromium の DevTools 相当として Safari の Web Inspector を使えるようにする (ADR 0001)
        webView.isInspectable = true
        webView.uiDelegate = self
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
                }
            },
            webView.observe(\.title) { [weak self] _, _ in
                guard let self else {
                    return
                }
                Task { @MainActor in
                    self.onStateChange?()
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

    func load(url: URL) {
        webView.load(URLRequest(url: url))
    }

    /// ページのタイトル。無題なら nil
    var title: String? {
        webView.title.flatMap { $0.isEmpty ? nil : $0 }
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
}
