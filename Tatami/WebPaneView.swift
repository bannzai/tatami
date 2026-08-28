import SwiftUI
import WebKit

/// WKWebView を SwiftUI に載せる 1 ペイン分の Web コンテンツ。
/// SwiftUI 側からのナビゲーション要求 (request) が変わった時だけ読み込み、ページ内のリンク遷移で変わった webView.url は上書きしない
struct WebPaneView: NSViewRepresentable {
    /// SwiftUI 側からの 1 回のナビゲーション要求。id で要求ごとに区別するため、同じ URL を続けて要求しても再読み込みできる
    struct NavigationRequest: Equatable {
        /// 要求を一意にする識別子。生成のたびに新しい値になる
        let id = UUID()
        /// 読み込む URL
        let url: URL
    }

    /// SwiftUI 側が表示を要求するナビゲーション
    let request: NavigationRequest
    /// 表示中の URL が変わった時 (ナビゲーション・リダイレクト・History API) に SwiftUI 側へ返す
    let onNavigate: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onNavigate: onNavigate)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        // Chromium の DevTools 相当として Safari の Web Inspector を使えるようにする (ADR 0001)
        webView.isInspectable = true
        webView.uiDelegate = context.coordinator
        // History API (pushState / replaceState) は navigation delegate を通らないため、url プロパティの変化を監視する
        context.coordinator.urlObservation = webView.observe(\.url, options: [.new]) { _, change in
            if let changedURL = change.newValue ?? nil {
                Task { @MainActor in
                    context.coordinator.onNavigate(changedURL)
                }
            }
        }
        load(request: request, into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.handledRequestID != request.id {
            load(request: request, into: webView, coordinator: context.coordinator)
        }
    }

    private func load(request: NavigationRequest, into webView: WKWebView, coordinator: Coordinator) {
        coordinator.handledRequestID = request.id
        webView.load(URLRequest(url: request.url))
    }

    /// SwiftUI 側が最後に処理した要求を覚えて再描画のたびに同じ要求を再読み込みしないようにし、
    /// WKWebView の URL 変化と新規ウィンドウ要求を受ける
    final class Coordinator: NSObject, WKUIDelegate {
        /// 最後に load した NavigationRequest の id
        var handledRequestID: UUID?
        /// webView.url の KVO 監視。Coordinator の寿命に合わせて解除する
        var urlObservation: NSKeyValueObservation?
        /// URL 変化の通知先
        let onNavigate: (URL) -> Void

        /// SwiftUI 側のクロージャを受け取るため memberwise init ではなく init を書く (NSObject のサブクラス)
        init(onNavigate: @escaping (URL) -> Void) {
            self.onNavigate = onNavigate
        }

        /// target="_blank" や window.open の新規ウィンドウ要求は、ペイン分割が実装されるまで現在のペインで開く。
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
}
