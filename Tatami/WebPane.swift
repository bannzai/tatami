import WebKit

/// 1 ペイン分の Web コンテンツ。WKWebView と、その URL 変化・新規ウィンドウ要求を受ける delegate をまとめて持つ。
/// ペインツリー (PaneTree) には識別子だけが載り、実体はこのクラスが BrowserWindowModel に保持される
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
    /// webView.url の KVO 監視。このインスタンスの寿命に合わせて解除する
    private var urlObservation: NSKeyValueObservation?

    init(id: PaneID, url: URL) {
        self.id = id
        self.url = url
        self.webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()
        // Chromium の DevTools 相当として Safari の Web Inspector を使えるようにする (ADR 0001)
        webView.isInspectable = true
        webView.uiDelegate = self
        // History API (pushState / replaceState) は navigation delegate を通らないため、url プロパティの変化を監視する。
        // observation をこのインスタンスが所有するため、クロージャからは弱参照にして循環参照を避ける
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, change in
            guard let self, let changedURL = change.newValue ?? nil else {
                return
            }
            Task { @MainActor in
                self.url = changedURL
                self.onNavigate?(changedURL)
            }
        }
        webView.load(URLRequest(url: url))
    }

    func load(url: URL) {
        webView.load(URLRequest(url: url))
    }

    /// target="_blank" や window.open の新規ウィンドウ要求は、新ペインで開く実装 (#5) までは現在のペインで開く。
    /// nil を返すと WebKit は新しい WKWebView を作らない
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }
}
