import SwiftUI
import WebKit

/// WKWebView を SwiftUI に載せる 1 ペイン分の Web コンテンツ。
/// SwiftUI 側から渡された url が変わった時だけ読み込み、ページ内のリンク遷移で変わった webView.url は上書きしない
struct WebPaneView: NSViewRepresentable {
    /// SwiftUI 側が表示を要求する URL
    let url: URL
    /// ナビゲーション完了時に実際に表示している URL を SwiftUI 側へ返す
    let onNavigate: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onNavigate: onNavigate)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        // Chromium の DevTools 相当として Safari の Web Inspector を使えるようにする (ADR 0001)
        webView.isInspectable = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        load(url: url, into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.requestedURL != url {
            load(url: url, into: webView, coordinator: context.coordinator)
        }
    }

    private func load(url: URL, into webView: WKWebView, coordinator: Coordinator) {
        coordinator.requestedURL = url
        webView.load(URLRequest(url: url))
    }

    /// SwiftUI 側が最後に要求した URL を覚えて再描画のたびに同じ URL を再読み込みしないようにし、
    /// WKWebView からのナビゲーション通知と新規ウィンドウ要求を受ける
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        /// 最後に load した URL
        var requestedURL: URL?
        /// ナビゲーション完了時の通知先
        let onNavigate: (URL) -> Void

        /// SwiftUI 側のクロージャを受け取るため memberwise init ではなく init を書く (NSObject のサブクラス)
        init(onNavigate: @escaping (URL) -> Void) {
            self.onNavigate = onNavigate
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if let committedURL = webView.url {
                onNavigate(committedURL)
            }
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
